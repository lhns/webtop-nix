package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestFromEnv(t *testing.T) {
	env := map[string]string{}
	get := func(k string) string { return env[k] }

	c := fromEnv(get)
	if c.mode != "freeze" || c.port != 8082 || c.uid != 1000 || c.stateDir != "/run/webtop" || c.hooks != nil {
		t.Fatalf("defaults: %+v", c)
	}
	env["WEBTOP_SUSPEND_MODE"] = "PowerOff"
	env["WEBTOP_HTTP_PORT"] = "8080"
	env["WEBTOP_UID"] = "1234"
	hooks := filepath.Join(t.TempDir(), "hooks")
	os.WriteFile(hooks, []byte("/bin/a --x\n\n  /bin/b  \n"), 0o644)
	env["WEBTOP_SLEEP_HOOKS"] = hooks
	c = fromEnv(get)
	if c.mode != "poweroff" || c.port != 8080 || c.uid != 1234 || !reflect.DeepEqual(c.hooks, []string{"/bin/a --x", "/bin/b"}) {
		t.Fatalf("set: %+v", c)
	}
	env["WEBTOP_SUSPEND_MODE"] = "whatever"
	if fromEnv(get).mode != "freeze" {
		t.Fatal("an unknown mode must freeze")
	}
}

func TestRunHooksAppendsStateAndSurvivesFailure(t *testing.T) {
	if _, err := os.Stat("/bin/sh"); err != nil {
		t.Skip("no /bin/sh")
	}
	out := filepath.Join(t.TempDir(), "out")
	runHooks([]string{"false", "echo >> " + out}, "asleep")
	runHooks([]string{"echo >> " + out}, "awake")
	b, _ := os.ReadFile(out)
	if string(b) != "asleep\nawake\n" {
		t.Fatalf("hooks wrote %q", b)
	}
}

// A freeze that cannot start (no Selkies to watch) falls back to a poweroff: the marker the session
// save and the consumer's power hook read, and the poweroff target started.
func TestFailedFreezeFallsBackToPoweroff(t *testing.T) {
	if _, err := os.Stat("/bin/sh"); err != nil {
		t.Skip("no /bin/sh")
	}
	bin, dir := t.TempDir(), t.TempDir()
	log := filepath.Join(bin, "log")
	os.WriteFile(filepath.Join(bin, "systemctl"), []byte("#!/bin/sh\necho \"$@\" > "+log+"\n"), 0o755)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	// Port 1: nothing listens, so the sleeper fails before freezing anything.
	if rc := suspend(config{stateDir: dir, uid: 1000, port: 1, mode: "freeze"}); rc != 0 {
		t.Fatalf("suspend returned %d", rc)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "stop-reason")); string(b) != "suspend\n" {
		t.Fatalf("stop-reason = %q", b)
	}
	if b, _ := os.ReadFile(log); !strings.Contains(string(b), "start --no-block --job-mode=replace-irreversibly poweroff.target") {
		t.Fatalf("systemctl called with %q", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "frozen-units")); err == nil {
		t.Fatal("something was left frozen")
	}
}
