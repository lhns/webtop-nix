package main

import (
	"os"
	"path/filepath"
	"reflect"
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
