// Package usersession runs systemctl as the desktop user.
package usersession

import (
	"context"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const systemctlTimeout = 5 * time.Second

// User is the desktop user. systemctl runs as this user without PAM (unlike
// `systemctl -M user@.host`, which opens a login session per call) and talks
// to the user manager's private socket under XDG_RUNTIME_DIR.
type User struct {
	UID, GID uint32
	Name     string // login name; empty if unknown
	Home     string // empty if unknown
}

// LookupUser resolves the account with the given uid, falling back to gid 100.
func LookupUser(uid uint32) User {
	u := User{UID: uid, GID: 100}
	if r, err := user.LookupId(strconv.FormatUint(uint64(uid), 10)); err == nil {
		if gid, err := strconv.ParseUint(r.Gid, 10, 32); err == nil {
			u = User{UID: uid, GID: uint32(gid), Name: r.Username, Home: r.HomeDir}
		}
	}
	return u
}

// Systemctl runs `systemctl --user args...` as the user, bounded by a timeout.
func (u User) Systemctl(ctx context.Context, args ...string) ([]byte, error) {
	return u.exec(ctx, systemctlTimeout, "systemctl", append([]string{"--user"}, args...)...)
}

// ActiveUnits lists the user manager's active services and scopes.
func (u User) ActiveUnits(ctx context.Context) ([]string, error) {
	out, err := u.Systemctl(ctx, "list-units", "--plain", "--no-legend", "--no-pager",
		"--type=service,scope", "--state=active")
	if err != nil {
		return nil, err
	}
	return parseUnitList(string(out)), nil
}

// parseUnitList takes the unit names from `systemctl list-units --plain --no-legend` output.
func parseUnitList(out string) []string {
	var names []string
	for _, l := range strings.Split(out, "\n") {
		if f := strings.Fields(l); len(f) > 0 {
			names = append(names, f[0])
		}
	}
	return names
}

// sessionPath is the PATH of commands run as the desktop user.
const sessionPath = "/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"

// lookIn finds name in path. exec.Command searches the process's own PATH, not cmd.Env's, and the
// unit does not have the system profile on it. Not found: name, so exec reports the error.
func lookIn(path, name string) string {
	if strings.Contains(name, "/") {
		return name
	}
	for _, dir := range filepath.SplitList(path) {
		p := filepath.Join(dir, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p
		}
	}
	return name
}

func (u User) exec(ctx context.Context, timeout time.Duration, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, lookIn(sessionPath, name), args...)
	runtimeDir := "/run/user/" + strconv.FormatUint(uint64(u.UID), 10)
	cmd.Env = []string{
		"XDG_RUNTIME_DIR=" + runtimeDir,
		"DBUS_SESSION_BUS_ADDRESS=unix:path=" + runtimeDir + "/bus",
		"PATH=" + sessionPath,
	}
	setCredential(cmd, u.UID, u.GID)
	return cmd.Output()
}
