package codebuddy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
		"",
	}, "\n"))
	data, _ := os.ReadFile(path)
	var rows []MessageRow
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		observePreviewLine("codebuddy", []byte(line), func(role, text string) {
			rows = append(rows, MessageRow{Role: role, Text: text})
		})
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %+v, want 2", rows)
	}
	if rows[0].Role != "user" || strings.TrimSpace(rows[0].Text) != "hello old" {
		t.Fatalf("row0 = %+v", rows[0])
	}
	if rows[1].Role != "assistant" || strings.TrimSpace(rows[1].Text) != "answer new" {
		t.Fatalf("row1 = %+v", rows[1])
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
