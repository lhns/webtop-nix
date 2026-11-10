// Command webtop-power is Sleep and the session save of a containerized desktop:
//
//	webtop-power suspend       systemd-suspend's ExecStart: freeze the session until the next web
//	                           client; with WEBTOP_SUSPEND_MODE=poweroff, or when freezing fails,
//	                           mark and power off instead
//	webtop-power thaw          thaw whatever Sleep froze (idempotent)
//	webtop-power save-session  save the Plasma session before an external stop
//
// Settings come from the environment of the unit (services.webtop.sleep, sessionSave):
//
//	WEBTOP_SUSPEND_MODE     "freeze" or "poweroff"
//	WEBTOP_HTTP_PORT        Selkies' port (wake detection)
//	WEBTOP_UID              the desktop user's uid
//	WEBTOP_POWER_STATE_DIR  state directory, /run/webtop
//	WEBTOP_SLEEP_HOOKS      file with one command per line, each run with "asleep" / "awake" appended
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/lhns/webtop-nix/pkgs/webtop-power/internal/freeze"
	"github.com/lhns/webtop-nix/pkgs/webtop-power/internal/selkies"
	"github.com/lhns/webtop-nix/pkgs/webtop-power/internal/session"
	"github.com/lhns/webtop-nix/pkgs/webtop-power/internal/state"
	"github.com/lhns/webtop-nix/pkgs/webtop-power/internal/usersession"
)

const hookTimeout = 10 * time.Second

type config struct {
	stateDir string
	uid      uint32
	port     int
	mode     string
	hooks    []string
}

func fromEnv(getenv func(string) string) config {
	str := func(k, def string) string {
		if v := strings.TrimSpace(getenv(k)); v != "" {
			return v
		}
		return def
	}
	num := func(k string, def int) int {
		if n, err := strconv.Atoi(str(k, "")); err == nil && n > 0 {
			return n
		}
		return def
	}
	c := config{
		stateDir: str("WEBTOP_POWER_STATE_DIR", "/run/webtop"),
		uid:      uint32(num("WEBTOP_UID", 1000)),
		port:     num("WEBTOP_HTTP_PORT", 8082),
		mode:     "freeze",
	}
	// "poweroff" only when asked for; anything else freezes.
	if strings.EqualFold(str("WEBTOP_SUSPEND_MODE", ""), "poweroff") {
		c.mode = "poweroff"
	}
	if f := str("WEBTOP_SLEEP_HOOKS", ""); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			log.Printf("hooks: %v", err)
		}
		for _, l := range strings.Split(string(b), "\n") {
			if l = strings.TrimSpace(l); l != "" {
				c.hooks = append(c.hooks, l)
			}
		}
	}
	return c
}

func main() {
	log.SetFlags(0) // the journal timestamps
	cfg := fromEnv(os.Getenv)
	if len(os.Args) != 2 {
		usage()
	}
	switch os.Args[1] {
	case "suspend":
		os.Exit(suspend(cfg))
	case "thaw":
		thaw(cfg)
	case "save-session":
		session.Run(cfg.stateDir)
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: webtop-power suspend | thaw | save-session")
	os.Exit(2)
}

// suspend blocks while the session is frozen and returns 0 on wake, so systemd and logind
// run their normal resume. If freezing is off or fails, it powers off like a suspend used to.
func suspend(cfg config) int {
	if cfg.mode == "freeze" {
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
		defer stop()
		err := (&freeze.Sleeper{
			Freezer:  newFreezer(cfg),
			Sessions: selkies.Sessions(cfg.port),
			Poll:     500 * time.Millisecond,
			Notify: func(asleep bool) {
				if asleep {
					runHooks(cfg.hooks, "asleep")
				} else {
					runHooks(cfg.hooks, "awake")
				}
			},
		}).Run(ctx)
		if err == nil {
			return 0
		}
		log.Printf("suspend: freeze failed, powering off instead: %v", err)
	}
	return suspendPoweroff(cfg)
}

func newFreezer(cfg config) *freeze.Freezer {
	return &freeze.Freezer{Ctl: freeze.UserCtl{User: usersession.LookupUser(cfg.uid)}, StateDir: cfg.stateDir}
}

// runHooks runs each hook with the state appended, best effort and bounded: a hook must not hold
// up the sleep or the wake.
func runHooks(hooks []string, st string) {
	for _, h := range hooks {
		ctx, cancel := context.WithTimeout(context.Background(), hookTimeout)
		cmd := exec.CommandContext(ctx, "/bin/sh", "-c", h+` "$0"`, st)
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			log.Printf("suspend: hook %q %s: %v", h, st, err)
		}
		cancel()
	}
}

func thaw(cfg config) {
	if err := newFreezer(cfg).Thaw(context.Background()); err != nil {
		log.Printf("thaw: %v", err) // never block the shutdown
	}
}

func suspendPoweroff(cfg config) int {
	if err := state.WriteAtomic(filepath.Join(cfg.stateDir, state.StopReason), []byte("suspend\n")); err != nil {
		log.Printf("suspend: %v", err)
		return 1
	}
	// Start the target via the manager: logind refuses poweroff while this
	// suspend operation is still in progress.
	cmd := exec.Command("systemctl", "start", "--no-block", "--job-mode=replace-irreversibly", "poweroff.target")
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		log.Printf("suspend: systemctl start poweroff.target: %v", err)
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		return 1
	}
	return 0
}
