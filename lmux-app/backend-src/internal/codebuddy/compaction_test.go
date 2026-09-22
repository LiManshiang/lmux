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

// The manual /compact shape, copied from a real conversation: the compaction
// pseudo-agent's ASSISTANT record carries the summary, and the CLI's second
// slicer — getCompactHistory — cuts at a record like this rather than at a user
// message. A scan that only knows about the user shape finds nothing here, which
// is how a conversation that had been /compact'ed kept its whole file.
const manualCompactSummary = `{"id":"b2","timestamp":200,"type":"message","role":"assistant","content":[{"providerData":{"annotations":[]},"type":"output_text","text":"<conversation_history_summary>\n<summary>\n1. Primary Request and Intent:\nRework the report page\n</summary>\n</conversation_history_summary>"}],"providerData":{"agent":"compact","compactType":"user-command","isCompactInternal":true,"isCompacted":true,"isSummary":true},"sessionId":"s1","cwd":"/tmp/proj"}`

// The instruction the pseudo-agent is given just before it writes that summary:
// a user message from the same agent, carrying no summary of its own. It is not
// a boundary, and cutting at it would drop the summary right behind it.
const manualCompactPrompt = `{"id":"b1","timestamp":199,"type":"message","role":"user","content":[{"type":"input_text","text":"**IMPORTANT CONSTRAINTS:**\n- Do NOT use any tools\n- Your ONLY output should be the <conversation_history_summary> structure"}],"providerData":{"agent":"compact"},"sessionId":"s1","cwd":"/tmp/proj"}`

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

// The manual /compact shape: the boundary is an assistant message written by the
// compaction pseudo-agent, and the summary in its body is what the model starts
// from. Cutting anywhere before this record is correct; cutting at it is the
// point.
func TestCompactionBaseManualCompact(t *testing.T) {
	dir := t.TempDir()
	body := strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"early work"}],"timestamp":1}`,
		`{"type":"summary","summary":"Redesigning the report page","providerData":{"source":"pre-compact"},"timestamp":2}`,
		manualCompactPrompt,
		manualCompactSummary,
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"carry on"}],"timestamp":201}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "conv.jsonl", body)
	want := int64(bytes.Index([]byte(body), []byte(manualCompactSummary)))

	base, err := CompactionBase("codebuddy", path)
	if err != nil {
		t.Fatalf("CompactionBase: %v", err)
	}
	if base != want {
		t.Errorf("base = %d, want %d (the assistant summary record)", base, want)
	}

	// The prompt record just above it must not be mistaken for the cut.
	if promptOffset := int64(bytes.Index([]byte(body), []byte(manualCompactPrompt))); base == promptOffset {
		t.Error("base landed on the compaction instruction; cutting there drops the summary")
	}
}

// The CLI applies getCompactHistory and then filterBeforeCompactedMessage, so the
// live history starts at whichever cut is later. Whichever order the two shapes
// appear in, the base is the later record — not simply the one of a given kind.
func TestCompactionBaseTakesTheLaterOfTheTwoCompactionShapes(t *testing.T) {
	pre := `{"type":"message","role":"user","content":[{"type":"input_text","text":"early work"}],"timestamp":1}`
	post := `{"type":"message","role":"assistant","content":"carrying on","timestamp":300}`

	cases := []struct {
		name   string
		record []string
		want   string
	}{
		{
			name:   "a user boundary, then a manual compact",
			record: []string{summaryBoundary, manualCompactSummary},
			want:   manualCompactSummary,
		},
		{
			name:   "a manual compact, then a user boundary",
			record: []string{manualCompactSummary, summaryBoundary},
			want:   summaryBoundary,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			body := strings.Join(append(append([]string{pre}, tc.record...), post, ""), "\n")
			path := writeTempJSONL(t, dir, "conv.jsonl", body)
			want := int64(bytes.Index([]byte(body), []byte(tc.want)))

			base, err := CompactionBase("codebuddy", path)
			if err != nil {
				t.Fatalf("CompactionBase: %v", err)
			}
			if base != want {
				t.Errorf("base = %d, want %d", base, want)
			}
		})
	}
}

func TestPruneToCompactionBaseManualCompact(t *testing.T) {
	dir := t.TempDir()
	pre := `{"type":"message","role":"user","content":[{"type":"input_text","text":"early work"}],"timestamp":1}` + "\n" +
		manualCompactPrompt + "\n"
	body := strings.Join([]string{
		strings.TrimSuffix(pre, "\n"),
		manualCompactSummary,
		`{"type":"message","role":"assistant","content":"carrying on","timestamp":300}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "conv.jsonl", body)
	base := int64(len(pre))

	outcome, err := PruneToCompactionBase("codebuddy", path, "no-such-session")
	if err != nil {
		t.Fatalf("PruneToCompactionBase: %v", err)
	}
	if !outcome.Pruned || outcome.Base != base {
		t.Fatalf("Pruned/base = %v/%d, want true/%d", outcome.Pruned, outcome.Base, base)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != body[base:] {
		t.Error("content mismatch after pruning a manual-compact conversation")
	}
	// The result starts at its own boundary, so a second pass does nothing.
	again, err := PruneToCompactionBase("codebuddy", path, "no-such-session")
	if err != nil {
		t.Fatalf("second prune: %v", err)
	}
	if again.Pruned {
		t.Error("the pruned file was not a fixed point")
	}
}

// --- reporting a compaction this scan cannot place ---

// unknownShape is a compaction written the way a newer agent version might write
// it: same field vocabulary, a record the predicates do not cut at — a summary
// on an assistant message from an agent that is not the one they know.
const unknownShape = `{"id":"z1","timestamp":400,"type":"message","role":"assistant","content":[{"type":"output_text","text":"<conversation_history_summary>\n<summary>\nRework the report page\n</summary>\n</conversation_history_summary>"}],"providerData":{"agent":"context-compactor","compactType":"auto-manual","isSummary":true,"isCompacted":true},"sessionId":"s1","cwd":"/tmp/proj"}`

// The case the flag exists for: the conversation was compacted, and nothing can
// be trimmed. Before this, that was indistinguishable from "never compacted" and
// went unreported — which is how a manually compacted session stayed at 26 MB
// through a release.
func TestScanCompactionFlagsACompactionItCannotPlace(t *testing.T) {
	dir := t.TempDir()
	body := strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"early work"}],"timestamp":1}`,
		unknownShape,
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"carry on"}],"timestamp":401}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	info, err := ScanCompaction("codebuddy", path)
	if err != nil {
		t.Fatalf("ScanCompaction: %v", err)
	}
	if info.Base != 0 {
		t.Errorf("base = %d, want 0 — the scan must not guess a cut it cannot place", info.Base)
	}
	if !info.UnplacedCompaction {
		t.Error("the compaction went unreported, which is the silent case this flag exists for")
	}
}

// A cut the scan can place explains every marker before it, so doubt raised
// earlier is dropped — everything before the cut is dead either way.
func TestScanCompactionForgetsAnUnplacedCompactionOnceACutIsFound(t *testing.T) {
	dir := t.TempDir()
	body := strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"early work"}],"timestamp":1}`,
		unknownShape,
		summaryBoundary,
		continuePrompt,
		`{"type":"message","role":"assistant","content":"carrying on","timestamp":500}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	info, err := ScanCompaction("codebuddy", path)
	if err != nil {
		t.Fatalf("ScanCompaction: %v", err)
	}
	if want := int64(bytes.Index([]byte(body), []byte(summaryBoundary))); info.Base != want {
		t.Errorf("base = %d, want %d", info.Base, want)
	}
	if info.UnplacedCompaction {
		t.Error("flagged a compaction that sits before a cut the scan did place")
	}
}

// The other half of the signal: a cut it can place, and then a later compaction
// it cannot. Trimming to the first is safe but leaves part of the saving behind,
// and that is worth saying rather than silently doing half the job.
func TestScanCompactionFlagsAMissedSavingAfterAKnownCut(t *testing.T) {
	dir := t.TempDir()
	body := strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"early work"}],"timestamp":1}`,
		summaryBoundary,
		continuePrompt,
		unknownShape,
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"carry on"}],"timestamp":501}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	info, err := ScanCompaction("codebuddy", path)
	if err != nil {
		t.Fatalf("ScanCompaction: %v", err)
	}
	if want := int64(bytes.Index([]byte(body), []byte(summaryBoundary))); info.Base != want {
		t.Errorf("base = %d, want %d (the cut it could place)", info.Base, want)
	}
	if !info.UnplacedCompaction {
		t.Error("a compaction after the cut went unreported: the trim stops short of what is dead")
	}
}

// Nothing here may raise the flag. Most of these pass the marker gate and get
// parsed, so the guard is the evidence test itself, not the cheap substring
// screen.
func TestScanCompactionDoesNotFlagThese(t *testing.T) {
	cases := []struct {
		name string
		line string
		why  string
	}{
		{
			name: "ordinary conversation",
			line: `{"type":"message","role":"user","content":[{"type":"input_text","text":"cd /tmp/proj"}],"timestamp":1}`,
			why:  "no compaction markers at all",
		},
		{
			name: "periodic summary row",
			line: `{"type":"summary","summary":"Optimizing the pipeline","providerData":{"source":"periodic"},"timestamp":2}`,
			why:  "only a pre-compact row is written by a compaction",
		},
		{
			name: "continue prompt",
			line: continuePrompt,
			why:  "follows a cut and carries no markers of its own",
		},
		{
			name: "point-in-time recovery",
			line: `{"type":"message","role":"user","providerData":{"isPtlRecovery":true,"isCompacted":true,"isSummary":true},"timestamp":9}`,
			why:  "understood, and deliberately not a boundary",
		},
		{
			name: "media body recovery",
			line: `{"type":"message","role":"user","providerData":{"isMediaBodyRecovery":true,"isCompacted":true},"timestamp":9}`,
			why:  "same, for media bodies",
		},
		{
			name: "prose about the format",
			line: `{"type":"message","role":"user","content":[{"type":"input_text","text":"the file holds <conversation_history_summary> and a compactType field, and the agent is called compact"}],"timestamp":9}`,
			why:  "conversations about compaction are not compactions — this is why only providerData counts",
		},
		{
			name: "tool output about the format",
			line: `{"type":"function_call_result","name":"Bash","status":"completed","output":{"type":"text","text":"grep isSummary: 3 matches, compactType: 1 match"},"timestamp":9}`,
			why:  "not a message",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := writeTempJSONL(t, dir, "conv.jsonl", tc.line+"\n")

			info, err := ScanCompaction("codebuddy", path)
			if err != nil {
				t.Fatalf("ScanCompaction: %v", err)
			}
			if info.Base != 0 {
				t.Fatalf("base = %d, want 0", info.Base)
			}
			if info.UnplacedCompaction {
				t.Errorf("flagged: %s", tc.why)
			}
		})
	}
}

// A file that already starts at its own cut has nothing before it to drop, so
// there is nothing to report — the pruned file must stay a fixed point here too,
// or every sync after a prune would warn about it.
func TestScanCompactionDoesNotFlagAnAlreadyTrimmedFile(t *testing.T) {
	dir := t.TempDir()
	path := writeTempJSONL(t, dir, "conv.jsonl", summaryBoundary+"\n"+continuePrompt+"\n")

	info, err := ScanCompaction("codebuddy", path)
	if err != nil {
		t.Fatalf("ScanCompaction: %v", err)
	}
	if info.Base != 0 || info.UnplacedCompaction {
		t.Errorf("base/unplaced = %d/%v, want 0/false", info.Base, info.UnplacedCompaction)
	}
}

// The prune is where the signal reaches a caller, so it has to survive the
// early return taken when there is nothing to trim.
func TestPruneToCompactionBaseReportsAnUnplaceableCompaction(t *testing.T) {
	dir := t.TempDir()
	body := strings.Join([]string{
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"early work"}],"timestamp":1}`,
		unknownShape,
		`{"type":"message","role":"user","content":[{"type":"input_text","text":"carry on"}],"timestamp":401}`,
		"",
	}, "\n")
	path := writeTempJSONL(t, dir, "conv.jsonl", body)

	outcome, err := PruneToCompactionBase("codebuddy", path, "no-such-session")
	if err != nil {
		t.Fatalf("PruneToCompactionBase: %v", err)
	}
	if outcome.Pruned {
		t.Error("Pruned = true, but there is no cut to trim to")
	}
	if !outcome.UnplacedCompaction {
		t.Error("UnplacedCompaction = false; the caller has no way to report the miss")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != body {
		t.Error("the conversation was rewritten despite nothing being prunable")
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
			name: "assistant message without the compact agent",
			line: `{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<summary>done</summary>"}],"providerData":{"isCompacted":true,"isSummary":true},"timestamp":9}`,
			why:  "an assistant record is a boundary only when the compaction pseudo-agent wrote it and its body carries the summary",
		},
		{
			name: "compaction instruction",
			line: manualCompactPrompt,
			why:  "the prompt that asks for the summary; the summary record follows it, and the CLI cuts there",
		},
		{
			name: "compact agent with no summary body",
			line: `{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I have summarized the conversation above."}],"providerData":{"agent":"compact","compactType":"user-command"},"timestamp":9}`,
			why:  "getCompactHistory requires the summary structure in the text, not just the agent name",
		},
		{
			name: "empty summary structure",
			line: `{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<summary></summary>"}],"providerData":{"agent":"compact","compactType":"user-command"},"timestamp":9}`,
			why:  "the CLI's [+?] needs content between the tags, so an empty one is not its cut",
		},
		{
			name: "summary structure in a user message from the compact agent",
			line: `{"type":"message","role":"user","content":[{"type":"input_text","text":"<summary>text</summary>"}],"providerData":{"agent":"compact"},"timestamp":9}`,
			why:  "getCompactHistory only scans assistant records; the user predicate excludes the compact agent",
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

	// The manual /compact shape: the cut record is an assistant message, so the
	// first-line check has to accept that shape too or the prune is refused.
	manualLive := manualCompactSummary + "\n" +
		`{"type":"message","role":"assistant","content":"carrying on","timestamp":300}` + "\n"
	manualBody := `{"type":"message","role":"user","content":[{"type":"input_text","text":"early work"}],"timestamp":1}` + "\n" + manualLive
	manualOriginal := writeTempJSONL(t, dir, "manual.jsonl", manualBody)
	manualCut := int64(len(manualBody) - len(manualLive))
	manualGood := writeTempJSONL(t, dir, "manualgood.jsonl", manualBody[manualCut:])
	if err := verifyPruned(manualGood, manualOriginal); err != nil {
		t.Errorf("verifyPruned rejected a correct manual-compact cut: %v", err)
	}
}
