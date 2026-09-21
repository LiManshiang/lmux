package codebuddy

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// boundaryRecord is the shape /compact and automatic compaction leave behind:
// a user message carrying the summarized history.
const summaryBoundary = `{"id":"a1","timestamp":100,"type":"message","role":"user","logicalParentId":"p1","content":[{"type":"input_text","text":"<conversation_history_summary>\nSummary:\n…\n</conversation_history_summary>"}],"providerData":{"skipRun":false,"compactType":"emergency-auto","isCompactInternal":true,"isCompacted":true,"isSummary":true},"sessionId":"s1","cwd":"/tmp/proj"}`

// The continuation prompt the CLI injects right after the boundary. It is a
// user message with compact markers but is NOT the boundary — cutting here would
// drop the summary the model is supposed to start from.
const continuePrompt = `{"id":"a2","logicalParentId":"a1","timestamp":101,"type":"message","role":"user","content":[{"type":"input_text","text":"Please continue with the conversation based on the summarized context above. Maintain the same level of detail and helpfulness as before the summarization."}],"providerData":{"skipRun":false,"isCompactInternal":true,"agent":"cli"},"sessionId":"s1","cwd":"/tmp/proj"}`

func TestCompactionBaseNoCompaction(t *testing.T) {
	dir := t.TempDir()
	path := writeTempJSONL(t, dir, "conv.jsonl", strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"cd /tmp/proj"}],"timestamp":1}`,
		`{"type":"summary","summary":"Designing the parser","providerData":{"source":"periodic"},"timestamp":2}`,
		`{"type":"message","role":"assistant","content":"working on it","timestamp":3}`,
		"",
	}, "\n"))

	base, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if base != 0 {
		t.Errorf("base = %d, want 0 for a conversation that was never compacted", base)
	}
}

func TestCompactionBaseIsLastBoundary(t *testing.T) {
	dir := t.TempDir()
	body := strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"first"}],"timestamp":1}`,
		`{"type":"message","role":"user","providerData":{"compactType":"manual","isCompactInternal":true,"isCompacted":true,"isSummary":true},"timestamp":2}`,
		`{"type":"message","role":"assistant","content":"ok","timestamp":3}`,
		summaryBoundary,
		continuePrompt,
		`{"type":"message","role":"assistant","content":"carrying on","timestamp":4}`,
		"",
	}, "\n")

	path := writeTempJSONL(t, dir, "conv.jsonl", body)
	want := int64(bytes.Index([]byte(body), []byte(summaryBoundary)))

	base, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if base != want {
		t.Errorf("base = %d, want %d (the last boundary, not the first)", base, want)
	}
}

// Everything here must NOT move the base. Each entry is a record that either
// carries compaction-shaped fields or merely mentions compaction in its body.
func TestCompactionBaseRejectsNonBoundaries(t *testing.T) {
	cases := []struct {
		name string
		line string
		why  string
	}{
		{
			name: "continue prompt",
			line: continuePrompt,
			why:  "the continuation prompt follows the boundary; cutting at it drops the summary",
		},
		{
			name: "ptl recovery",
			line: `{"type":"message","role":"user","providerData":{"isPtlRecovery":true,"isCompacted":true,"isSummary":true},"timestamp":9}`,
			why:  "a point-in-time recovery re-sends an earlier message",
		},
		{
			name: "media body recovery",
			line: `{"type":"message","role":"user","providerData":{"isMediaBodyRecovery":true,"isCompacted":true},"timestamp":9}`,
			why:  "same, for media bodies",
		},
		{
			name: "assistant message",
			line: `{"type":"message","role":"assistant","providerData":{"isCompacted":true,"isSummary":true},"timestamp":9}`,
			why:  "a boundary is a user message",
		},
		{
			name: "compaction pseudo-agent",
			line: `{"type":"message","role":"user","providerData":{"agent":"compact","compactType":"manual"},"timestamp":9}`,
			why:  "the compaction agent's own record is not a user boundary",
		},
		{
			name: "pre-compact summary row",
			line: `{"type":"summary","summary":"Optimizing the pipeline","providerData":{"source":"pre-compact"},"timestamp":9}`,
			why:  "the CLI does not treat a summary row as a message; cutting here would drop records the model still reads",
		},
		{
			name: "prose mentioning compaction",
			line: `{"type":"message","role":"user","content":[{"type":"input_text","text":"please compact the class registry"}],"timestamp":9}`,
			why:  "no compaction flags at all",
		},
		{
			name: "tool output mentioning compaction",
			line: `{"type":"function_call_result","name":"Bash","status":"completed","output":{"type":"text","text":"Compact registry audit: 80 classes"},"timestamp":9}`,
			why:  "not a message",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			body := tc.line + "\n"
			path := writeTempJSONL(t, dir, "conv.jsonl", body)

			base, err := CompactionBase("codebuddy", path)
			if err != nil {
				t.Fatalf("CompactionBase: %v", err)
			}
			if base != 0 {
				t.Errorf("base = %d, want 0: %s", base, tc.why)
			}
		})
	}
}

func TestCompactionBaseCompactTypeOnly(t *testing.T) {
	// The CLI also accepts a user message whose providerData carries a
	// compactType string. Both compaction markers on this machine's
	// conversations set isCompacted/isSummary as well, so this branch is
	// defence in depth — but it must still work on its own.
	dir := t.TempDir()
	head := `{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}],"timestamp":1}`
	boundary := `{"type":"message","role":"user","providerData":{"agent":"cli","compactType":"manual"},"timestamp":9}`
	body := head + "\n" + boundary + "\n"
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	base, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if want := int64(len(head) + 1); base != want {
		t.Errorf("base = %d, want %d", base, want)
	}
}

func TestCompactionBaseHandlesOversizedRecords(t *testing.T) {
	// A single record can inline megabytes of tool output. A bufio.Scanner
	// would stop with ErrTooLong and silently truncate the scan here.
	dir := t.TempDir()
	huge := `{"type":"function_call_result","name":"Bash","output":{"type":"text","text":"` +
		strings.Repeat("x", 300<<10) + `"},"timestamp":1}`
	body := strings.Join([]string{
		huge,
		summaryBoundary,
		`{"type":"message","role":"assistant","content":"resumed","timestamp":2}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	want := int64(bytes.Index([]byte(body), []byte(summaryBoundary)))
	base, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if base != want {
		t.Errorf("base = %d, want %d — the boundary after the oversized record was missed", base, want)
	}
}

func TestCompactionBaseIgnoresMalformedLines(t *testing.T) {
	dir := t.TempDir()
	// A half-written record (the CLI died mid-append) sits between the
	// boundary and the tail. It must not shift the base.
	body := strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}],"timestamp":1}`,
		summaryBoundary,
		`{"type":"message","role":"assistant","cont`,
		`{"type":"message","role":"assistant","content":"after","timestamp":3}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	want := int64(bytes.Index([]byte(body), []byte(summaryBoundary)))
	base, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if base != want {
		t.Errorf("base = %d, want %d", base, want)
	}
}

func TestCompactionBaseWithoutTrailingNewline(t *testing.T) {
	dir := t.TempDir()
	// The boundary is the last record and the file does not end in a newline.
	body := `{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}],"timestamp":1}` + "\n" + summaryBoundary
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	base, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if want := int64(bytes.Index([]byte(body), []byte(summaryBoundary))); base != want {
		t.Errorf("base = %d, want %d", base, want)
	}
}

func TestCompactionBaseIsIdempotentOnTrimmedFile(t *testing.T) {
	// A conversation already imported from a trimmed sync copy starts at its
	// boundary. The base must come back 0 — not the continuation prompt's
	// offset — so "mirror content == local[base:]" holds unchanged on both
	// sides and the next export appends instead of rebuilding.
	dir := t.TempDir()
	body := summaryBoundary + "\n" + continuePrompt + "\n"
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	base, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if base != 0 {
		t.Errorf("base = %d, want 0 when the boundary is the first record", base)
	}
}

func TestCompactionBaseOtherAgents(t *testing.T) {
	dir := t.TempDir()
	path := writeTempJSONL(t, dir, "conv.jsonl", summaryBoundary+"\n")

	base, err := CompactionBase("claude", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if base != 0 {
		t.Errorf("base = %d, want 0 for a non-codebuddy agent", base)
	}
}

func TestCompactionBaseMissingFile(t *testing.T) {
	_, err := CompactionBase("codebuddy", filepath.Join(t.TempDir(), "nope.jsonl"))
	if err == nil {
		t.Fatal("expected an error for a missing conversation")
	}
}

func TestCompactionBaseEmptyFile(t *testing.T) {
	dir := t.TempDir()
	path := writeTempJSONL(t, dir, "empty.jsonl", "")

	base, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if base != 0 {
		t.Errorf("base = %d, want 0", base)
	}
	if info, err := os.Stat(path); err != nil || info.Size() != 0 {
		t.Errorf("empty file was modified: %v", err)
	}
}

// --- pruning to the boundary ---

// prunableBody returns a conversation whose live half starts at the boundary,
// plus the offset that boundary sits at.
func prunableBody() (body string, base int64) {
	pre := `{"type":"message","role":"user","content":[{"type":"input_text","text":"early work"}],"timestamp":1}` + "\n"
	body = strings.Join([]string{
		pre + summaryBoundary,
		continuePrompt,
		`{"type":"message","role":"assistant","content":"carrying on","timestamp":4}`,
		"",
	}, "\n")
	return body, int64(len(pre))
}

func TestPruneToCompactionBaseTrimsTheDeadPrefix(t *testing.T) {
	dir := t.TempDir()
	body, base := prunableBody()
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	outcome, err := PruneToCompactionBase("codebuddy", path, "no-such-session")
	if err != nil {
		t.Fatalf("PruneToCompactionBase: %v", err)
	}
	if !outcome.Pruned {
		t.Fatal("Pruned = false, want true")
	}
	if outcome.Base != base || outcome.RemovedBytes != base {
		t.Errorf("base/removed = %d/%d, want %d", outcome.Base, outcome.RemovedBytes, base)
	}
	if outcome.Size != int64(len(body))-base {
		t.Errorf("size = %d, want %d", outcome.Size, int64(len(body))-base)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != body[base:] {
		t.Errorf("content mismatch after pruning")
	}
	if info, err := os.Stat(path); err != nil || info.Size() != outcome.Size {
		t.Errorf("on-disk size = %v, want %d", info, outcome.Size)
	}
	// The result now starts at its own boundary, so the file is a fixed point.
	again, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase after pruning: %v", err)
	}
	if again != 0 {
		t.Errorf("base after pruning = %d, want 0", again)
	}
	// No temp file left behind.
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Errorf("temp file left behind: %v", entries)
	}
}

func TestPruneToCompactionBaseLeavesUncompactedConversationsAlone(t *testing.T) {
	dir := t.TempDir()
	body := strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}],"timestamp":1}`,
		`{"type":"message","role":"assistant","content":"ok","timestamp":2}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	outcome, err := PruneToCompactionBase("codebuddy", path, "no-such-session")
	if err != nil {
		t.Fatalf("PruneToCompactionBase: %v", err)
	}
	if outcome.Pruned {
		t.Error("Pruned = true for a conversation that was never compacted")
	}
	got, _ := os.ReadFile(path)
	if string(got) != body {
		t.Error("the conversation was rewritten even though nothing was prunable")
	}
}

func TestPruneToCompactionBaseIsANoOpWhenAlreadyTrimmed(t *testing.T) {
	dir := t.TempDir()
	// A conversation imported from a trimmed sync copy: the boundary is already
	// the first record, so the base is 0 and there is nothing before it.
	path := writeTempJSONL(t, dir, "conv.jsonl", summaryBoundary+"\n"+continuePrompt+"\n")

	outcome, err := PruneToCompactionBase("codebuddy", path, "no-such-session")
	if err != nil {
		t.Fatalf("PruneToCompactionBase: %v", err)
	}
	if outcome.Pruned {
		t.Error("Pruned = true for an already-trimmed conversation")
	}
}

func TestPruneToCompactionBaseMissingFile(t *testing.T) {
	if _, err := PruneToCompactionBase("codebuddy", filepath.Join(t.TempDir(), "nope.jsonl"), "x"); err == nil {
		t.Fatal("expected an error for a missing conversation")
	}
}

// The one guard that cannot be simulated away: a live agent holds the file, and
// rewriting it would leave that process appending to a deleted inode.
func TestPruneToCompactionBaseRefusesWhileAnAgentHoldsIt(t *testing.T) {
	dir := t.TempDir()
	body, _ := prunableBody()
	path := writeTempJSONL(t, dir, "conv.jsonl", body)
	const sessionID = "11111111-2222-3333-4444-555555555555"

	// A process whose argv names this conversation, the way the CLI does when it
	// resumes one. `exec -a` sets argv[0], and ps prints the joined argv.
	holder := exec.Command("/bin/bash", "-c", `exec -a "codebuddy --resume `+sessionID+`" sleep 30`)
	if err := holder.Start(); err != nil {
		t.Skipf("cannot spawn a process to hold the conversation: %v", err)
	}
	defer func() {
		_ = holder.Process.Kill()
		_, _ = holder.Process.Wait()
	}()

	deadline := time.Now().Add(5 * time.Second)
	for !ConversationInUse(sessionID) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !ConversationInUse(sessionID) {
		t.Skip("the spawned process never reached the process table")
	}

	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	outcome, err := PruneToCompactionBase("codebuddy", path, sessionID)
	if !errors.Is(err, ErrConversationInUse) {
		t.Fatalf("err = %v, want ErrConversationInUse", err)
	}
	if outcome.Pruned {
		t.Error("Pruned = true while an agent held the conversation")
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Error("the conversation changed even though the prune was refused")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Errorf("temp file left behind: %v", entries)
	}
}

// verifyPruned is what stands between a mis-measured offset and a conversation
// that starts mid-record. Both of its checks, and the case that passes.
func TestVerifyPruned(t *testing.T) {
	dir := t.TempDir()
	body, base := prunableBody()
	original := writeTempJSONL(t, dir, "conv.jsonl", body)

	good := writeTempJSONL(t, dir, "good.jsonl", body[base:])
	if err := verifyPruned(good, original); err != nil {
		t.Errorf("verifyPruned rejected a correct cut: %v", err)
	}

	// Starts mid-record: not a boundary line at all.
	midRecord := writeTempJSONL(t, dir, "mid.jsonl", body[base-10:])
	if err := verifyPruned(midRecord, original); err == nil {
		t.Error("verifyPruned accepted a cut that starts mid-record")
	}

	// Starts at a boundary but ends somewhere else: the copy is short.
	truncated := writeTempJSONL(t, dir, "short.jsonl", strings.TrimSuffix(body[base:], "carrying on\",\"timestamp\":4}\n"))
	if err := verifyPruned(truncated, original); err == nil {
		t.Error("verifyPruned accepted a copy that does not reach the end")
	}

	// An empty candidate has no boundary to show.
	empty := writeTempJSONL(t, dir, "empty.jsonl", "")
	if err := verifyPruned(empty, original); err == nil {
		t.Error("verifyPruned accepted an empty candidate")
	}

	// Longer than the comparison window, so both reads are the last 64 KB of a
	// file rather than the whole file — the other branch of the overlap rule.
	pad := strings.Repeat("y", 100<<10)
	live := summaryBoundary + "\n" + continuePrompt + "\n"
	longBody := `{"type":"message","role":"user","content":[{"type":"input_text","text":"` + pad + `"}],"timestamp":1}` + "\n" + live
	longOriginal := writeTempJSONL(t, dir, "long.jsonl", longBody)
	longCut := int64(len(longBody) - len(live))
	longGood := writeTempJSONL(t, dir, "longgood.jsonl", longBody[longCut:])
	if err := verifyPruned(longGood, longOriginal); err != nil {
		t.Errorf("verifyPruned rejected a correct cut of an over-window file: %v", err)
	}
	longBad := writeTempJSONL(t, dir, "longbad.jsonl", longBody[longCut:len(longBody)-1]+"Z")
	if err := verifyPruned(longBad, longOriginal); err == nil {
		t.Error("verifyPruned accepted an over-window copy whose end differs")
	}
}
