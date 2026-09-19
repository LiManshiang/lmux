package codebuddy

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeTempJSONL(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProbeJSONLCodebuddy(t *testing.T) {
	dir := t.TempDir()
	content := strings.Join([]string{
		`{"type":"message","role":"user","sessionId":"cbc-1","cwd":"/tmp/proj","content":[{"type":"text","text":"hello"}],"timestamp":1}`,
		`{"type":"message","role":"assistant","sessionId":"cbc-1","cwd":"/tmp/proj","timestamp":2}`,
		`{"type":"ai-title","aiTitle":"Fix the parser","timestamp":3}`,
		`{"type":"summary","summary":"早期摘要","timestamp":4}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "cbc-1.jsonl", content)
	info, _ := os.Stat(path)

	conv := probeJSONL(path, "codebuddy", info.Size())
	if conv.SessionID != "cbc-1" {
		t.Fatalf("session id = %q", conv.SessionID)
	}
	if conv.CWD != "/tmp/proj" {
		t.Fatalf("cwd = %q", conv.CWD)
	}
	if conv.AITitle != "Fix the parser" {
		t.Fatalf("ai_title = %q", conv.AITitle)
	}
	if conv.Summary != "早期摘要" {
		t.Fatalf("summary = %q", conv.Summary)
	}
}

func TestProbeJSONLCodebuddyTailOverrides(t *testing.T) {
	dir := t.TempDir()
	var b strings.Builder
	// Fill well past the 64KB head window, then append title + summary so they
	// only live in the tail window.
	pad := strings.Repeat("x", 70<<10)
	b.WriteString(`{"type":"message","role":"user","sessionId":"cbc-9","cwd":"/p","content":[{"type":"text","text":"start"}]}` + "\n")
	b.WriteString(`{"type":"ai-title","aiTitle":"OLD"}` + "\n")
	for i := 0; i < 900; i++ {
		b.WriteString(`{"type":"message","role":"assistant","content":[{"type":"text","text":"` + pad + `"}],"timestamp":9}` + "\n")
	}
	b.WriteString(`{"type":"ai-title","aiTitle":"NEW TITLE"}` + "\n")
	b.WriteString(`{"type":"summary","summary":"尾段摘要"}` + "\n")

	path := writeTempJSONL(t, dir, "cbc-9.jsonl", b.String())
	info, _ := os.Stat(path)
	conv := probeJSONL(path, "codebuddy", info.Size())
	if conv.SessionID != "cbc-9" {
		t.Fatalf("session id = %q", conv.SessionID)
	}
	if conv.AITitle != "NEW TITLE" {
		t.Fatalf("ai_title should come from tail window, got %q", conv.AITitle)
	}
	if conv.Summary != "尾段摘要" {
		t.Fatalf("summary = %q", conv.Summary)
	}
	if conv.CWD != "/p" {
		t.Fatalf("cwd = %q", conv.CWD)
	}
}

func TestProbeJSONLClaude(t *testing.T) {
	dir := t.TempDir()
	content := strings.Join([]string{
		`{"type":"mode","mode":"default","sessionId":"cl-1"}`,
		`{"type":"user","sessionId":"cl-1","cwd":"/claude/proj","message":{"role":"user","content":"do the thing"}}`,
		`{"type":"assistant","sessionId":"cl-1","cwd":"/claude/proj","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}`,
		`{"type":"last-prompt","sessionId":"cl-1","lastPrompt":"do the thing once more"}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "cl-1.jsonl", content)
	info, _ := os.Stat(path)

	conv := probeJSONL(path, "claude", info.Size())
	if conv.SessionID != "cl-1" {
		t.Fatalf("session id = %q", conv.SessionID)
	}
	if conv.CWD != "/claude/proj" {
		t.Fatalf("cwd = %q", conv.CWD)
	}
	if conv.Summary != "do the thing once more" {
		t.Fatalf("summary = %q", conv.Summary)
	}
}

func TestPreviewCodebuddyOutputTextBlocks(t *testing.T) {
	dir := t.TempDir()
	path := writeTempJSONL(t, dir, "p.jsonl", strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"text","text":"hello old"}]}`,
		`{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer new"}]}`,
		`{"type":"function_call","name":"Bash"}`,
		`{"type":"function_call_result","output":{"type":"text","text":"tool noise"}}`,
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"follow up"}]}`,
		"",
	}, "\n"))
	data, _ := os.ReadFile(path)
	var rows []MessageRow
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		observePreviewLine("codebuddy", []byte(line), func(role, text string) {
			rows = append(rows, MessageRow{Role: role, Text: text})
		})
	}
	if len(rows) != 3 {
		t.Fatalf("rows = %+v, want 3", rows)
	}
	if rows[0].Role != "user" || strings.TrimSpace(rows[0].Text) != "hello old" {
		t.Fatalf("row0 = %+v", rows[0])
	}
	if rows[1].Role != "assistant" || strings.TrimSpace(rows[1].Text) != "answer new" {
		t.Fatalf("row1 = %+v", rows[1])
	}
	if rows[2].Role != "user" || strings.TrimSpace(rows[2].Text) != "follow up" {
		t.Fatalf("row2 = %+v", rows[2])
	}
}

func TestScanProjectRootFiltered(t *testing.T) {
	root := t.TempDir()
	// Two encoded project dirs under the root.
	encA := encodeCodebuddyProjectDir("/machines/home/dev-a")
	encB := encodeCodebuddyProjectDir("/machines/home/dev-b")
	if err := os.MkdirAll(filepath.Join(root, encA), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, encB), 0o755); err != nil {
		t.Fatal(err)
	}
	writeTempJSONL(t, filepath.Join(root, encA), "aaa.jsonl",
		`{"type":"message","role":"user","sessionId":"aaa","cwd":"/machines/home/dev-a","timestamp":1}`+"\n")
	writeTempJSONL(t, filepath.Join(root, encB), "bbb.jsonl",
		`{"type":"message","role":"user","sessionId":"bbb","cwd":"/machines/home/dev-b","timestamp":2}`+"\n")

	// Unfiltered: both dirs scanned.
	all, err := scanProjectRoot("codebuddy", root, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 {
		t.Fatalf("unfiltered found %d conversations, want 2", len(all))
	}

	// Filtered to dev-a: only aaa.
	onlyA, err := scanProjectRoot("codebuddy", root, "/machines/home/dev-a")
	if err != nil {
		t.Fatal(err)
	}
	if len(onlyA) != 1 || onlyA[0].SessionID != "aaa" {
		t.Fatalf("filtered = %+v", onlyA)
	}
}

func TestDedupeConversationsKeepsNewest(t *testing.T) {
	items := []ConversationSummary{
		{Agent: "codebuddy", SessionID: "same", MTime: 100},
		{Agent: "codebuddy", SessionID: "same", MTime: 300},
		{Agent: "codebuddy", SessionID: "other", MTime: 200},
		{Agent: "claude", SessionID: "same", MTime: 500}, // different agent keeps both
	}
	got := dedupeConversations(items)
	if len(got) != 3 {
		t.Fatalf("len = %d, want 3 (%+v)", len(got), got)
	}
	// codebuddy|same must be the 300 entry.
	for _, c := range got {
		if c.Agent == "codebuddy" && c.SessionID == "same" && c.MTime != 300 {
			t.Fatalf("duplicate not newest: %+v", c)
		}
	}
}

func TestFilterBoundConversations(t *testing.T) {
	convs := []ConversationSummary{
		{Agent: "codebuddy", SessionID: "a", MTime: 1},
		{Agent: "codebuddy", SessionID: "b", MTime: 2},
		{Agent: "claude", SessionID: "c", MTime: 3},
	}
	bound := map[string]bool{"b": true}
	visible, hidden := FilterBoundConversations(convs, bound)
	if hidden != 1 || len(visible) != 2 {
		t.Fatalf("hidden=%d visible=%d, want 1/2", hidden, len(visible))
	}
	for _, c := range visible {
		if c.SessionID == "b" {
			t.Fatalf("bound session leaked through: %+v", c)
		}
	}
}

func TestPreviewClaudeRows(t *testing.T) {
	dir := t.TempDir()
	path := writeTempJSONL(t, dir, "cl-p.jsonl", strings.Join([]string{
		`{"type":"user","sessionId":"cl","message":{"role":"user","content":"plain string ask"}}`,
		`{"type":"assistant","sessionId":"cl","message":{"role":"assistant","content":[{"type":"text","text":"blocks reply"},{"type":"tool_use","name":"Bash","input":{}}]}}`,
		`{"type":"user","sessionId":"cl","message":{"role":"user","content":[{"type":"text","text":"second ask"}]}}`,
		`{"type":"last-prompt","lastPrompt":"second ask"}`,
		"",
	}, "\n"))
	data, _ := os.ReadFile(path)
	var rows []MessageRow
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		observePreviewLine("claude", []byte(line), func(role, text string) {
			rows = append(rows, MessageRow{Role: role, Text: text})
		})
	}
	if len(rows) != 3 {
		t.Fatalf("rows = %+v, want 3", rows)
	}
	if rows[0].Role != "user" || strings.TrimSpace(rows[0].Text) != "plain string ask" {
		t.Fatalf("row0 = %+v", rows[0])
	}
	if rows[1].Role != "assistant" || !strings.Contains(rows[1].Text, "blocks reply") {
		t.Fatalf("row1 = %+v", rows[1])
	}
	if rows[1].Role == "assistant" && strings.Contains(rows[1].Text, "Bash") {
		t.Fatalf("tool_use leaked into assistant text: %+v", rows[1])
	}
	if rows[2].Role != "user" || strings.TrimSpace(rows[2].Text) != "second ask" {
		t.Fatalf("row2 = %+v", rows[2])
	}
}

func TestFindConversationInRoot(t *testing.T) {
	root := t.TempDir()
	encA := filepath.Join(root, "dir-a")
	encB := filepath.Join(root, "dir-b")
	if err := os.MkdirAll(encA, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(encB, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTempJSONL(t, encA, "id-x.jsonl", "{}")
	writeTempJSONL(t, encB, "id-y.jsonl", "{}")
	// A conversation id must be found wherever it lives.
	if p := findConversationInRoot(root, "id-x"); p == "" || p != filepath.Join(encA, "id-x.jsonl") {
		t.Fatalf("id-x found at %q", p)
	}
	if p := findConversationInRoot(root, "id-y"); p == "" {
		t.Fatalf("id-y not found")
	}
	if p := findConversationInRoot(root, "missing"); p != "" {
		t.Fatalf("missing returned %q", p)
	}
}

func TestLocateConversationDerivesProjectDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	// The launch directory has to exist for it to be offered as a suggestion.
	live := filepath.Join(t.TempDir(), "live")
	if err := os.MkdirAll(live, 0o755); err != nil {
		t.Fatal(err)
	}

	// Ordinary case: the file sits under the encoded launch directory and every
	// record agrees on it.
	lines := []string{
		`{"type":"message","role":"user","cwd":"` + live + `","content":[{"type":"input_text","text":"hi"}]}`,
		`{"type":"message","role":"assistant","cwd":"` + live + `","content":[{"type":"output_text","text":"ok"}]}`,
	}
	path := writeConversation(t, home, live, "conv-1", lines, time.Now())
	loc, ok := LocateConversation("codebuddy", "conv-1", live)
	if !ok {
		t.Fatal("LocateConversation did not find the conversation")
	}
	if loc.Path != path {
		t.Errorf("path = %q, want %q", loc.Path, path)
	}
	if loc.ProjectDir != live {
		t.Errorf("project dir = %q, want %q", loc.ProjectDir, live)
	}
	if !loc.Matches {
		t.Error("the directory the caller passed is the one holding the file")
	}
	if other, _ := LocateConversation("codebuddy", "conv-1", "/somewhere/else"); other.Matches {
		t.Error("an unrelated directory must not match")
	}
	if any, _ := LocateConversation("codebuddy", "conv-1", ""); !any.Matches {
		t.Error("with no directory to compare there is nothing to contradict")
	}

	// A conversation moved to another machine keeps the old path at the front
	// of the file and the current one after it. The folder the file sits in
	// decides which is right, so the earlier answer must not win by being
	// first.
	moved := []string{
		`{"type":"message","role":"user","cwd":"/Users/gone","content":[{"type":"input_text","text":"old"}]}`,
		`{"type":"message","role":"assistant","cwd":"` + live + `","content":[{"type":"output_text","text":"new"}]}`,
	}
	writeConversation(t, home, live, "conv-2", moved, time.Now())
	loc2, _ := LocateConversation("codebuddy", "conv-2", live)
	if loc2.ProjectDir != live {
		t.Errorf("project dir = %q, want the live path %q, not the stale one from the head", loc2.ProjectDir, live)
	}

	// Two paths, neither naming the file's folder, and neither can be offered:
	// a suggestion would be a guess between them.
	ambiguous := []string{
		`{"type":"message","role":"user","cwd":"/Users/one","content":[{"type":"input_text","text":"a"}]}`,
		`{"type":"message","role":"assistant","cwd":"/Users/two","content":[{"type":"output_text","text":"b"}]}`,
	}
	writeConversation(t, home, "/tmp/elsewhere", "conv-3", ambiguous, time.Now())
	loc3, _ := LocateConversation("codebuddy", "conv-3", "/Users/one")
	if loc3.ProjectDir != "" {
		t.Errorf("project dir = %q, want empty when no recorded path explains the folder", loc3.ProjectDir)
	}
	// The caller's directory is still answered exactly: it is compared against
	// where the agent would look, so a missing suggestion costs no accuracy.
	if loc3.Matches {
		t.Error("/Users/one does not hold the conversation file")
	}

	// A conversation can exist in more than one project folder (resuming it
	// from a second directory leaves a second file). Whether a directory works
	// is decided by the file being in *that* directory, not by which copy the
	// lookup happened to return first.
	second := filepath.Join(t.TempDir(), "second")
	if err := os.MkdirAll(second, 0o755); err != nil {
		t.Fatal(err)
	}
	writeConversation(t, home, second, "conv-4", []string{userLine("copy")}, time.Now())
	writeConversation(t, home, live, "conv-4", []string{userLine("copy")}, time.Now())
	for _, dir := range []string{live, second} {
		got, _ := LocateConversation("codebuddy", "conv-4", dir)
		if !got.Matches {
			t.Errorf("matches = false for %q, which does hold a copy of the conversation", dir)
		}
	}

	if _, ok := LocateConversation("codebuddy", "nope", "/tmp"); ok {
		t.Error("an unknown id must not resolve")
	}
}

func TestDeleteConversation(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	path := writeConversation(t, home, "/tmp/proj", "doomed", []string{userLine("将被删除")}, time.Now())

	list, err := ListConversations("codebuddy", "")
	if err != nil || len(list) != 1 {
		t.Fatalf("setup: list = %d, err = %v", len(list), err)
	}

	removed, err := DeleteConversation("codebuddy", "doomed")
	if err != nil {
		t.Fatalf("DeleteConversation: %v", err)
	}
	if removed != path {
		t.Errorf("removed = %q, want %q", removed, path)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("file still exists after delete")
	}

	// The 5s list memo must have been dropped along with the file.
	after, err := ListConversations("codebuddy", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 0 {
		t.Errorf("list still reports %d conversations after delete", len(after))
	}

	// A second delete is a not-found, not a silent success.
	if _, err := DeleteConversation("codebuddy", "doomed"); err == nil {
		t.Error("expected an error deleting a missing conversation")
	}
	if _, err := DeleteConversation("codebuddy", ""); err == nil {
		t.Error("expected an error for an empty session id")
	}
}

func TestMoveConversationRelocatesAndRewritesCwd(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	from := filepath.Join(t.TempDir(), "from")
	to := filepath.Join(t.TempDir(), "to")
	for _, d := range []string{from, to} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	lines := []string{
		`{"type":"message","role":"user","cwd":"` + from + `","content":[{"type":"input_text","text":"hi"}]}`,
		`{"type":"message","role":"assistant","cwd":"` + from + `","content":[{"type":"output_text","text":"ok"}]}`,
	}
	oldPath := writeConversation(t, home, from, "conv-1", lines, time.Now())
	// A sidecar the records reference when an output was too large to inline.
	sidecar := filepath.Join(filepath.Dir(oldPath), "conv-1", "tool-results")
	if err := os.MkdirAll(sidecar, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sidecar, "out.txt"), []byte("kept"), 0o644); err != nil {
		t.Fatal(err)
	}

	moved, err := MoveConversation("codebuddy", "conv-1", from, to)
	if err != nil {
		t.Fatalf("MoveConversation: %v", err)
	}

	// It has to land where the agent would look for it when launched in `to`.
	if want := AgentSessionFile("codebuddy", to, "conv-1"); moved != want {
		t.Errorf("moved to %q, want %q", moved, want)
	}
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Error("the original is still there; a move should not leave two copies")
	}
	body, err := os.ReadFile(moved)
	if err != nil {
		t.Fatal(err)
	}
	// Both the folder and the recorded cwd name the new directory: the folder is
	// what the agent looks in, the cwd is what lmux reads back for the Agent
	// browser and the work-directory lookup.
	if bytes.Contains(body, []byte(from)) {
		t.Errorf("records still name the old directory:\n%s", body)
	}
	if !bytes.Contains(body, []byte(`"cwd":"`+to+`"`)) {
		t.Errorf("records do not name the new directory:\n%s", body)
	}
	if got, err := os.ReadFile(filepath.Join(filepath.Dir(moved), "conv-1", "tool-results", "out.txt")); err != nil || string(got) != "kept" {
		t.Errorf("tool-results sidecar did not come along: %v %q", err, got)
	}

	// A second conversation already stored under the target must not be
	// clobbered by a move.
	writeConversation(t, home, to, "conv-2", []string{userLine("already here")}, time.Now())
	writeConversation(t, home, from, "conv-2", []string{userLine("the one being moved")}, time.Now())
	if _, err := MoveConversation("codebuddy", "conv-2", from, to); err == nil {
		t.Error("expected the move to refuse rather than overwrite an existing conversation")
	}
	if _, err := os.Stat(AgentSessionFile("codebuddy", from, "conv-2")); err != nil {
		t.Error("a refused move must leave the source in place")
	}

	// Moving to where it already is changes nothing and is not an error.
	if _, err := MoveConversation("codebuddy", "conv-1", to, to); err != nil {
		t.Errorf("moving into its own directory: %v", err)
	}
}

func TestCommandLineHoldsConversation(t *testing.T) {
	const id = "01a0a887-b17b-7efa-9a03-10d1db068381"

	// ps shows argv, and a shell strips quotes before a command reaches it, so
	// the id is always bare here — quoted or not at the prompt.
	inUse := []string{
		"node /x/bin/codebuddy-code --permission-mode auto -y --resume " + id,
		"/usr/bin/login -flp me /bin/bash -c exec -l node /x/bin/codebuddy-code --resume " + id,
		"node /x/codebuddy-code --resume " + id + " --continue",
	}
	for _, line := range inUse {
		if !commandLineHoldsConversation(line, id) {
			t.Errorf("missed an agent holding the conversation:\n  %s", line)
		}
	}

	// Merely mentioning the id is not holding it: a search, an editor, a shell
	// history line. Nor is a longer id that starts with the same characters —
	// these would otherwise block an edit for no reason.
	notInUse := []string{
		"",
		"grep -r " + id + " /Users/x/.codebuddy",
		"vi " + id + ".jsonl",
		"node /x/codebuddy-code --resume " + id + "-extra",
		"node /x/codebuddy-code --resume 01a0a887-b17b-7efa-9a03-10d1db068380",
		"node /x/codebuddy-code --resume ",
	}
	for _, line := range notInUse {
		if commandLineHoldsConversation(line, id) {
			t.Errorf("false positive:\n  %s", line)
		}
	}
}

func TestConversationSuccessorFollowsAClearedConversation(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	dir := filepath.Join(t.TempDir(), "proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 9, 19, 21, 27, 44, 0, time.Local)

	// A conversation that is still going: the successor rule must say nothing.
	writeTimedConversation(t, home, dir, "live", []int64{base.UnixMilli(), base.UnixMilli() + 1000})
	if got := ConversationSuccessor("codebuddy", dir, "live"); got != "" {
		t.Errorf("a conversation with no successor returned %q", got)
	}

	// /clear: the old conversation stops and the new one begins 29 ms later,
	// exactly as observed on this machine.
	writeTimedConversation(t, home, dir, "old", []int64{base.UnixMilli() - 5000, base.UnixMilli()})
	writeTimedConversation(t, home, dir, "new", []int64{base.UnixMilli() + 29, base.UnixMilli() + 4000})
	if got := ConversationSuccessor("codebuddy", dir, "old"); got != "new" {
		t.Errorf("successor = %q, want \"new\"", got)
	}

	// Another session's conversation that happens to be written in the same
	// folder is not a successor: it did not begin the instant this one ended.
	writeTimedConversation(t, home, dir, "other", []int64{base.UnixMilli() + 60_000})
	if got := ConversationSuccessor("codebuddy", dir, "old"); got != "new" {
		t.Errorf("a later conversation was taken as the successor: %q", got)
	}
	// …and a conversation that began *before* this one ended is not one either.
	writeTimedConversation(t, home, dir, "earlier", []int64{base.UnixMilli() - 1000})
	if got := ConversationSuccessor("codebuddy", dir, "old"); got != "new" {
		t.Errorf("an earlier conversation was taken as the successor: %q", got)
	}

	if got := ConversationSuccessor("codebuddy", dir, "missing"); got != "" {
		t.Errorf("an unknown conversation returned %q", got)
	}
}

// writeTimedConversation writes a conversation whose records carry the given
// timestamps, so the successor rule can be exercised on its real input.
func writeTimedConversation(t *testing.T, home, projectDir, id string, stamps []int64) {
	t.Helper()
	lines := make([]string, 0, len(stamps))
	for i, ts := range stamps {
		lines = append(lines, fmt.Sprintf(
			`{"sessionId":%q,"type":"message","role":"user","timestamp":%d,"content":[{"type":"input_text","text":"m%d"}]}`,
			id, ts, i))
	}
	writeConversation(t, home, projectDir, id, lines, time.Now())
}
