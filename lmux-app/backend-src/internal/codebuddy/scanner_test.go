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

	got := FindRecentSessionForProject("/Users/limanshiang")
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

	got := FindRecentClaudeSession("/Users/limanshiang")
	if got != "new" {
		t.Errorf("FindRecentClaudeSession = %q, want %q", got, "new")
	}
}

func TestLastUsageInfoPicksFunctionCallTokens(t *testing.T) {
	// Regression: codebuddy writes the latest accumulated input_tokens on
	// function_call records too. Filtering to type=="message" returned a
	// stale percentage that never moved as the conversation grew.
	dir := t.TempDir()
	path := filepath.Join(dir, "s.jsonl")
	var lines []string
	write := func(typ string, input, output int64) {
		rec := map[string]interface{}{
			"type": typ,
			"message": map[string]interface{}{
				"usage": map[string]interface{}{
					"input_tokens":          input,
					"output_tokens":         output,
					"cache_read_input_tokens": 0,
				},
			},
		}
		b, _ := json.Marshal(rec)
		lines = append(lines, string(b))
	}
	write("message", 300000, 500)
	write("function_call", 316750, 300)
	if err := os.WriteFile(path, []byte(lines[0]+"\n"+lines[1]+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	input, _, output, _, err := lastUsageInfo(path)
	if err != nil {
		t.Fatal(err)
	}
	if input != 316750 {
		t.Errorf("input = %d, want 316750 (latest function_call usage)", input)
	}
	if output != 800 {
		t.Errorf("output = %d, want 800 (both records summed)", output)
	}
}

func TestLatestSessionFilePrefersRecentlyModified(t *testing.T) {
	// A user can `/resume` to an OLD conversation from inside a freshly
	// launched agent. That conversation's file gets written again, so it is
	// "active" even though its creation time is long past. Modification time
	// must win over creation time, otherwise the resumed conversation is never
	// picked and the session binds to the wrong (fresh) one.
	dir := t.TempDir()
	mk := func(name string) {
		if err := os.WriteFile(filepath.Join(dir, name+".jsonl"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("fresh-idle")        // newest creation time
	time.Sleep(20 * time.Millisecond)
	oldResumed := filepath.Join(dir, "old-resumed.jsonl")
	if err := os.WriteFile(oldResumed, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	// Touch the old conversation so it is the most recently modified.
	if err := os.Chtimes(oldResumed, time.Now(), time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}

	got := latestSessionFile(dir, nil)
	if got != "old-resumed" {
		t.Errorf("latestSessionFile = %q, want %q (most recently modified)", got, "old-resumed")
	}
}

func TestLatestSessionFileFreshBindsOwnEarliestCreated(t *testing.T) {
	// Two sessions both launch codebuddy in the same project. Each agent
	// creates its own empty conversation right at its process start. The
	// boundary lookup must return the conversation created at/after that
	// session's own start time with the EARLIEST creation time — otherwise the
	// idle session binds to the active one's newer conversation and both
	// sessions resume the same hello conversation.
	dir := t.TempDir()
	mk := func(name string) {
		if err := os.WriteFile(filepath.Join(dir, name+".jsonl"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("idle-fresh") // created first
	time.Sleep(20 * time.Millisecond)
	mk("active-hello") // created second

	after := time.Now().Add(-time.Hour)
	got := latestSessionFile(dir, &after)
	if got != "idle-fresh" {
		t.Errorf("latestSessionFile(after) = %q, want %q (own earliest-created conversation)", got, "idle-fresh")
	}
}

func TestLatestSessionFileOwnsOwnFileNotOthersNonEmpty(t *testing.T) {
	// Three sessions run codebuddy in the same project. The "hello" session
	// wrote content; the /model and /skills sessions ran commands that write
	// nothing, so their conversations are 0-byte files created right at their
	// own launch. Each session must bind to ITS OWN file (the one whose
	// creation is closest to its own process start) — never to another
	// session's non-empty conversation, otherwise every session restores the
	// same "hello" dialog.
	dir := t.TempDir()
	mk := func(name string, content []byte) {
		if err := os.WriteFile(filepath.Join(dir, name+".jsonl"), content, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("idle-fresh", nil) // /model session's own empty file
	time.Sleep(20 * time.Millisecond)
	mk("hello", []byte("x")) // another session's non-empty conversation

	after := time.Now().Add(-time.Hour)
	got := latestSessionFile(dir, &after)
	if got != "idle-fresh" {
		t.Errorf("latestSessionFile = %q, want %q (own file wins over other session's non-empty)", got, "idle-fresh")
	}
}

func TestLatestSessionFileNanosecondBoundary(t *testing.T) {
	// Two agents launched back-to-back, possibly within the same wall-clock
	// second. The boundary carries sub-second precision (proc_pidinfo
	// microseconds in Swift, preserved through the handler as nanoseconds).
	// Each agent must bind to its OWN file — the one created at/after its
	// start with creation time closest to it — even though both files were
	// created within the same second. A second-truncated boundary would make
	// both agents eligible for both files and grab whichever came first.
	dir := t.TempDir()
	mk := func(name string) {
		if err := os.WriteFile(filepath.Join(dir, name+".jsonl"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("session-a")
	time.Sleep(5 * time.Millisecond)
	mk("session-b")

	// Exact creation times from the filesystem.
	ca := creationTime(filepath.Join(dir, "session-a.jsonl"))
	cb := creationTime(filepath.Join(dir, "session-b.jsonl"))
	if ca.After(cb) {
		t.Fatalf("expected session-a created before session-b")
	}

	// Session A's boundary: exactly at its own file's creation time — a
	// freshly launched agent created this file at start. session-a qualifies
	// (created >= start) and is the closest; session-b is ~5ms away.
	aStart := ca
	if got := latestSessionFile(dir, &aStart); got != "session-a" {
		t.Errorf("session A binds %q, want %q", got, "session-a")
	}

	// Session B's boundary: exactly at its own creation. session-a was
	// created strictly before, so only session-b qualifies.
	bStart := cb
	if got := latestSessionFile(dir, &bStart); got != "session-b" {
		t.Errorf("session B binds %q, want %q", got, "session-b")
	}
}

func TestLatestSessionFileResumeFallsBackToRecentlyModified(t *testing.T) {
	// A user launches codebuddy fresh, then `/resume <old-id>` — the old
	// conversation is written again but no NEW file is created at/after the
	// launch. The lookup must fall back to the most recently modified file
	// (the resumed conversation), NOT return an unrelated older file.
	dir := t.TempDir()
	mk := func(name string) {
		if err := os.WriteFile(filepath.Join(dir, name+".jsonl"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("old-resumed") // the conversation the user will /resume to
	time.Sleep(20 * time.Millisecond)
	mk("fresh-idle") // codebuddy's launch-time placeholder

	// Touch old-resumed so it is the most recently modified.
	p := filepath.Join(dir, "old-resumed.jsonl")
	if err := os.Chtimes(p, time.Now(), time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}

	// Boundary AFTER both files were created: no new file at/after launch,
	// so the live (most recently modified) conversation wins.
	after := time.Now().Add(1 * time.Hour)
	got := latestSessionFile(dir, &after)
	if got != "old-resumed" {
		t.Errorf("latestSessionFile(after in future) = %q, want %q (most recently modified)", got, "old-resumed")
	}
}
