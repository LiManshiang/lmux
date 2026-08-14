package codebuddy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestEncodeClaudeProjectDir(t *testing.T) {
	cases := map[string]string{
		"/Users/limanshiang": "-Users-limanshiang",
		"/a/b/c":             "-a-b-c",
		"relative":           "relative",
	}
	for in, want := range cases {
		if got := encodeClaudeProjectDir(in); got != want {
			t.Errorf("encodeClaudeProjectDir(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEstimateContentChars(t *testing.T) {
	// Plain string content.
	if n := estimateContentChars(json.RawMessage(`"hello"`)); n != 5 {
		t.Errorf("string content: got %d, want 5", n)
	}
	// Array of blocks; non-text blocks are ignored.
	arr := json.RawMessage(`[{"type":"text","text":"abc"},{"type":"image"},{"type":"text","text":"de"}]`)
	if n := estimateContentChars(arr); n != 5 {
		t.Errorf("array content: got %d, want 5", n)
	}
	// Invalid JSON -> 0.
	if n := estimateContentChars(json.RawMessage(`not-json`)); n != 0 {
		t.Errorf("invalid content: got %d, want 0", n)
	}
}

func TestGetClaudeContextTokens(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	projDir := filepath.Join(home, ".claude", "projects", "-Users-limanshiang")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// 5 chars -> ~2 tokens (chars/2).
	content := `{"message":{"content":"hello"}}` + "\n"
	if err := os.WriteFile(filepath.Join(projDir, "s1.jsonl"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := GetClaudeContextTokens("/Users/limanshiang", "s1"); got != 2 {
		t.Errorf("GetClaudeContextTokens = %d, want 2", got)
	}
}

func TestFindRecentSessionForProjectUsesCreationTime(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".codebuddy", "projects", "Users-limanshiang")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Write the older session first, then the newer one, so its creation time
	// is later even though both get touched by WriteFile.
	old := filepath.Join(dir, "old-session.jsonl")
	newer := filepath.Join(dir, "new-session.jsonl")
	if err := os.WriteFile(old, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)
	if err := os.WriteFile(newer, []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := FindRecentSessionForProject("/Users/limanshiang", time.Time{})
	if got != "new-session" {
		t.Errorf("FindRecentSessionForProject = %q, want %q", got, "new-session")
	}
}

func TestFindRecentClaudeSessionUsesCreationTime(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".claude", "projects", "-Users-limanshiang")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "old.jsonl"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)
	if err := os.WriteFile(filepath.Join(dir, "new.jsonl"), []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := FindRecentClaudeSession("/Users/limanshiang", time.Time{})
	if got != "new" {
		t.Errorf("FindRecentClaudeSession = %q, want %q", got, "new")
	}
}
