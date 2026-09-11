package codebuddy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
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

func TestRewriteSessionID(t *testing.T) {
	in := `{"sessionId":"old-id","type":"user","message":{"content":"hi"}}` + "\n" +
		`{"sessionId":"old-id","type":"assistant","message":{"content":"hello"}}` + "\n"
	out := RewriteSessionID(in, "new-id")
	if strings.Contains(out, "old-id") {
		t.Errorf("RewriteSessionID left old id: %q", out)
	}
	want := 2
	if got := strings.Count(out, `"sessionId":"new-id"`); got != want {
		t.Errorf("RewriteSessionID replaced %d sessionIds, want %d: %q", got, want, out)
	}
	// A sessionId with surrounding whitespace is still rewritten.
	inSpaced := `{"sessionId" : "abc","type":"user"}` + "\n"
	outSpaced := RewriteSessionID(inSpaced, "xyz")
	if !strings.Contains(outSpaced, `"sessionId":"xyz"`) {
		t.Errorf("RewriteSessionID did not handle spaced field: %q", outSpaced)
	}
}

func TestCodebuddySessionFileAndClaudeSessionFile(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cb := CodebuddySessionFile("/Users/limanshiang/dev/x", "abc")
	wantCB := filepath.Join(home, ".codebuddy", "projects", "Users-limanshiang-dev-x", "abc.jsonl")
	if cb != wantCB {
		t.Errorf("CodebuddySessionFile = %q, want %q", cb, wantCB)
	}

	cl := ClaudeSessionFile("/Users/limanshiang/dev/x", "abc")
	wantCL := filepath.Join(home, ".claude", "projects", "-Users-limanshiang-dev-x", "abc.jsonl")
	if cl != wantCL {
		t.Errorf("ClaudeSessionFile = %q, want %q", cl, wantCL)
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
	// conversation is written again after launch but no NEW file is created.
	// The lookup must fall back to the most recently modified file that was
	// touched AFTER the launch (the resumed conversation), NOT a file that was
	// only touched before the launch (another session's earlier work).
	dir := t.TempDir()
	mk := func(name string) {
		if err := os.WriteFile(filepath.Join(dir, name+".jsonl"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("fresh-idle") // codebuddy's launch-time placeholder
	time.Sleep(20 * time.Millisecond)
	mk("old-resumed") // the conversation the user will /resume to
	time.Sleep(20 * time.Millisecond)

	// The agent launches now; the user then /resume's old-resumed, which is
	// written again AFTER launch. old-resumed becomes the most recently
	// modified file after the boundary.
	launch := time.Now()
	time.Sleep(10 * time.Millisecond)
	p := filepath.Join(dir, "old-resumed.jsonl")
	if err := os.Chtimes(p, time.Now(), time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}

	got := latestSessionFile(dir, &launch)
	if got != "old-resumed" {
		t.Errorf("latestSessionFile = %q, want %q (resumed conversation modified after launch)", got, "old-resumed")
	}
}

func TestLatestSessionFileIgnoresPreLaunchActivity(t *testing.T) {
	// A fresh agent launched and the user did NOTHING — no new file created,
	// no existing file touched after launch. There is no conversation for this
	// session yet; the lookup MUST NOT fall back to a file whose only activity
	// happened before the launch (another session's earlier conversation),
	// otherwise a restart would resume someone else's work.
	dir := t.TempDir()
	mk := func(name string) {
		if err := os.WriteFile(filepath.Join(dir, name+".jsonl"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("other-session-skills") // active BEFORE this agent launched
	time.Sleep(20 * time.Millisecond)
	launch := time.Now()
	time.Sleep(10 * time.Millisecond)

	if got := latestSessionFile(dir, &launch); got != "" {
		t.Errorf("latestSessionFile = %q, want %q (nothing active after launch)", got, "")
	}
}

// --- SessionHasAssistant / fileHasAssistant (session-valid fast path) ---

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestFileHasAssistant(t *testing.T) {
	dir := t.TempDir()

	// Assistant in the first few lines → true.
	withAssistant := filepath.Join(dir, "with.jsonl")
	writeFile(t, withAssistant,
		`{"type":"message","role":"user","cwd":"/x"}`+"\n"+
			`{"type":"message","role":"assistant","cwd":"/x"}`+"\n")
	if !fileHasAssistant(withAssistant) {
		t.Error("file with assistant message: got false, want true")
	}

	// No assistant at all → false (user-only / metrics-only files).
	userOnly := filepath.Join(dir, "user.jsonl")
	writeFile(t, userOnly,
		`{"type":"message","role":"user"}`+"\n"+
			`{"type":"turn-metrics"}`+"\n")
	if fileHasAssistant(userOnly) {
		t.Error("user-only file: got true, want false")
	}

	// Empty file → false.
	empty := filepath.Join(dir, "empty.jsonl")
	writeFile(t, empty, "")
	if fileHasAssistant(empty) {
		t.Error("empty file: got true, want false")
	}

	// Missing file → false (no panic).
	if fileHasAssistant(filepath.Join(dir, "missing.jsonl")) {
		t.Error("missing file: got true, want false")
	}

	// Assistant deep in the file (after large noise lines) → true.
	deep := filepath.Join(dir, "deep.jsonl")
	var b strings.Builder
	b.WriteString(`{"type":"message","role":"user"}` + "\n")
	for i := 0; i < 500; i++ {
		b.WriteString(`{"type":"progress","padding":"` + strings.Repeat("x", 2000) + `"}` + "\n")
	}
	b.WriteString(`{"type":"message","role":"assistant"}` + "\n")
	writeFile(t, deep, b.String())
	if !fileHasAssistant(deep) {
		t.Error("assistant after 500 noise lines: got false, want true")
	}
}

func TestSessionHasAssistantLocatesFileWithoutScan(t *testing.T) {
	// SessionHasAssistant must find a conversation JSONL by filename under
	// ~/.codebuddy/projects/<dir>/<id>.jsonl WITHOUT triggering a full
	// ScanAll — a cold-cache rescan on machines with 100MB+ conversations
	// used to exceed the request timeout and made resumes fall back to a
	// fresh (empty) conversation.
	home := t.TempDir()
	t.Setenv("HOME", home)
	InvalidateCache()

	id := "11111111-2222-3333-4444-555555555555"
	projDir := filepath.Join(home, ".codebuddy", "projects", "Volumes-Dev-proj")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(projDir, id+".jsonl"),
		`{"type":"message","role":"user","sessionId":"`+id+`"}`+"\n"+
			`{"type":"message","role":"assistant","sessionId":"`+id+`"}`+"\n")

	if !SessionHasAssistant(id) {
		t.Error("SessionHasAssistant(existing conversation) = false, want true")
	}

	// A user-only conversation (no assistant) is not resumable.
	emptyID := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	writeFile(t, filepath.Join(projDir, emptyID+".jsonl"),
		`{"type":"message","role":"user","sessionId":"`+emptyID+`"}`+"\n")
	if SessionHasAssistant(emptyID) {
		t.Error("SessionHasAssistant(user-only conversation) = true, want false")
	}

	// Unknown id → false, no panic.
	if SessionHasAssistant("99999999-8888-7777-6666-555555555555") {
		t.Error("SessionHasAssistant(unknown id) = true, want false")
	}

	// Malformed JSONL line inside the file must not break the scan.
	brokenID := "bbbbbbbb-cccc-dddd-eeee-ffff00001111"
	writeFile(t, filepath.Join(projDir, brokenID+".jsonl"),
		"not-json\n"+`{"type":"message","role":"assistant"}`+"\n")
	if !SessionHasAssistant(brokenID) {
		t.Error("SessionHasAssistant(file with broken first line) = false, want true")
	}
}

// --- streaming cwd localization ---

func TestLocalizeSessionCwdFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "conv.jsonl")
	// Second line deliberately has no trailing newline.
	body := `{"type":"user","cwd":"/Users/someone-else","content":"hi"}` + "\n" +
		`{"type":"message","cwd":"/Users/someone-else","content":"bye"}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	changed, err := LocalizeSessionCwdFile(path, "/tmp/proj")
	if err != nil {
		t.Fatalf("LocalizeSessionCwdFile: %v", err)
	}
	if !changed {
		t.Fatal("expected changed=true")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"type":"user","cwd":"/tmp/proj","content":"hi"}` + "\n" +
		`{"type":"message","cwd":"/tmp/proj","content":"bye"}`
	if string(got) != want {
		t.Errorf("content mismatch:\n got %q\nwant %q", got, want)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Errorf("temp file left behind: %v", entries)
	}

	// Second pass: already localized -> no write at all.
	before, _ := os.Stat(path)
	changed, err = LocalizeSessionCwdFile(path, "/tmp/proj")
	if err != nil || changed {
		t.Errorf("expected no-op, got changed=%v err=%v", changed, err)
	}
	after, _ := os.Stat(path)
	if !before.ModTime().Equal(after.ModTime()) {
		t.Error("file was rewritten even though nothing needed localizing")
	}
}

func TestLocalizeSessionCwdFileMatchesInMemoryRewrite(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "big.jsonl")
	var b strings.Builder
	for i := 0; i < 20000; i++ { // ~5MB, exercises the streaming path
		b.WriteString(`{"type":"message","cwd":"/Users/someone-else","content":"line"}` + "\n")
	}
	b.WriteString(`{"type":"message","cwd":"/tmp/proj","content":"tail"}` + "\n")
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	changed, err := LocalizeSessionCwdFile(path, "/tmp/proj")
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if want := RewriteSessionCwd(b.String(), "/tmp/proj"); string(got) != want {
		t.Error("streaming rewrite differs from the in-memory rewrite")
	}
	if strings.Contains(string(got), "/Users/someone-else") {
		t.Error("foreign cwd survived")
	}
	if !strings.Contains(string(got), `"content":"tail"`) {
		t.Error("tail line was damaged")
	}
}

func TestLocalizeSessionCwdFileMissingFile(t *testing.T) {
	if _, err := LocalizeSessionCwdFile(filepath.Join(t.TempDir(), "nope.jsonl"), "/tmp/proj"); !os.IsNotExist(err) {
		t.Errorf("expected not-exist error, got %v", err)
	}
}
