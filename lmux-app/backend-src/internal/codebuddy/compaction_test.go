package codebuddy

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
