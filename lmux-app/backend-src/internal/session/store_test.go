package session

import (
	"os"
	"path/filepath"
	"testing"
)

func TestClearAgentBinding(t *testing.T) {
	store, err := NewStore(filepath.Join(t.TempDir(), "sessions.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	m := NewManager(store)

	// Create validates that the project directory exists, so use real ones.
	dirA, dirB := t.TempDir(), t.TempDir()
	first, err := m.Create(CreateRequest{ProjectDir: dirA, Name: "a", CBCSessionID: "conv-1"})
	if err != nil {
		t.Fatal(err)
	}
	second, err := m.Create(CreateRequest{ProjectDir: dirB, Name: "b", CBCSessionID: "conv-2"})
	if err != nil {
		t.Fatal(err)
	}

	n, err := store.ClearAgentBinding("conv-1")
	if err != nil {
		t.Fatalf("ClearAgentBinding: %v", err)
	}
	if n != 1 {
		t.Errorf("detached = %d, want 1", n)
	}

	got, err := m.Get(first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.CBCSessionID != "" {
		t.Errorf("session still bound to %q", got.CBCSessionID)
	}

	// Only the matching session is touched.
	other, err := m.Get(second.ID)
	if err != nil {
		t.Fatal(err)
	}
	if other.CBCSessionID != "conv-2" {
		t.Errorf("unrelated session = %q, want conv-2", other.CBCSessionID)
	}

	// Unknown and empty ids are no-ops, not errors.
	if n, err := store.ClearAgentBinding("nobody"); err != nil || n != 0 {
		t.Errorf("unknown id: n = %d, err = %v", n, err)
	}
	if n, err := store.ClearAgentBinding(""); err != nil || n != 0 {
		t.Errorf("empty id: n = %d, err = %v", n, err)
	}
}

func TestResolveProjectDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, "work"), 0o755); err != nil {
		t.Fatal(err)
	}

	// "~" is expanded, because the value comes from a text field where a user
	// writes a path the way a shell takes it — and a stored "~/x" would name a
	// project folder nothing else could reproduce.
	got, err := ResolveProjectDir("~/work")
	if err != nil {
		t.Fatalf("ResolveProjectDir(~/work): %v", err)
	}
	if want := filepath.Join(home, "work"); got != want {
		t.Errorf("got %q, want %q", got, want)
	}

	// A trailing slash is the same directory, not a different one: the folder
	// the conversation is stored under is derived from this string.
	slashed, err := ResolveProjectDir(home + "/work/")
	if err != nil {
		t.Fatalf("ResolveProjectDir(%q): %v", home+"/work/", err)
	}
	if slashed != filepath.Join(home, "work") {
		t.Errorf("trailing slash gave %q, want it cleaned", slashed)
	}

	if _, err := ResolveProjectDir(filepath.Join(home, "nope")); err == nil {
		t.Error("a directory that does not exist must be rejected")
	}
	if _, err := ResolveProjectDir(filepath.Join(home, "work", "..", "work")); err != nil {
		t.Errorf("an unnormalised but valid path: %v", err)
	}
}
