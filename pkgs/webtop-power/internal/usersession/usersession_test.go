package usersession

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseUnitList(t *testing.T) {
	out := "app-firefox@1.service loaded active running Firefox\n\nplasma-kwin_wayland.service loaded active running KWin\n"
	if got := parseUnitList(out); len(got) != 2 || got[0] != "app-firefox@1.service" || got[1] != "plasma-kwin_wayland.service" {
		t.Fatalf("%q", got)
	}
}

func TestLookIn(t *testing.T) {
	dir := t.TempDir()
	tool := filepath.Join(dir, "tool")
	if err := os.WriteFile(tool, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	path := "/nonexistent" + string(os.PathListSeparator) + dir
	for name, want := range map[string]string{"tool": tool, "missing": "missing", "/abs/tool": "/abs/tool"} {
		if got := lookIn(path, name); got != want {
			t.Errorf("lookIn(%q) = %q, want %q", name, got, want)
		}
	}
}
