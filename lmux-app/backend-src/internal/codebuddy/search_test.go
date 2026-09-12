package codebuddy

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// resetConversationsCache clears ListConversations' 5s memo so each test sees
// only the history it just wrote. Same package, so the private state is fair
// game — otherwise tests would read each other's results.
func resetConversationsCache() {
	conversationsMu.Lock()
	conversationsCache = conversationsCacheEntry{}
	conversationsMu.Unlock()
}

// writeConversation creates one codebuddy JSONL under a temp HOME and returns
// its path. Lines are written verbatim so tests control the exact record shapes.
func writeConversation(t *testing.T, home, projectDir, id string, lines []string, mtime time.Time) string {
	t.Helper()
	dir := filepath.Join(home, ".codebuddy", "projects", encodeCodebuddyProjectDir(projectDir))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, id+".jsonl")
	// Real records carry sessionId on every line, and probeJSONL (used by
	// ListConversations) needs it to recognise the file as a conversation.
	prefixed := make([]string, 0, len(lines))
	for _, l := range lines {
		prefixed = append(prefixed, strings.Replace(l, "{", fmt.Sprintf(`{"sessionId":%q,`, id), 1))
	}
	if err := os.WriteFile(path, []byte(strings.Join(prefixed, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	return path
}

func userLine(text string) string {
	return fmt.Sprintf(`{"type":"message","role":"user","content":[{"type":"input_text","text":%q}]}`, text)
}

func assistantLine(text string) string {
	return fmt.Sprintf(`{"type":"message","role":"assistant","content":[{"type":"output_text","text":%q}]}`, text)
}

func TestSearchConversationsFindsChineseAndSkipsNoise(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	writeConversation(t, home, "/tmp/proj", "c1", []string{
		userLine("帮我写一个登录脚本"),
		`{"type":"function_call","name":"Write","arguments":{"path":"login.py"}}`,
		`{"type":"reasoning","text":"用户想要一个登录脚本，登录逻辑要注意密码哈希"}`,
		assistantLine("登录脚本已经写好了"),
	}, time.Now())

	res, _ := SearchConversations(context.Background(), SearchOptions{Query: "登录"})

	if len(res.Groups) != 1 {
		t.Fatalf("groups = %d, want 1", len(res.Groups))
	}
	g := res.Groups[0]
	// user + assistant messages match; the function_call/reasoning lines are
	// filtered by observePreviewLine, so they never produce hits.
	if len(g.Hits) != 2 {
		t.Fatalf("hits = %d, want 2 (%+v)", len(g.Hits), g.Hits)
	}
	for _, h := range g.Hits {
		if !strings.Contains(h.Snippet, "登录") {
			t.Errorf("snippet missing keyword: %q", h.Snippet)
		}
		if !utf8.ValidString(h.Snippet) {
			t.Errorf("snippet split a multi-byte rune: %q", h.Snippet)
		}
	}
	if res.ScannedConvos != 1 || res.TimedOut || res.Truncated {
		t.Errorf("unexpected result meta: %+v", res)
	}
}

func TestSearchConversationsSnippetWindow(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	prefix := strings.Repeat("前", 100)
	suffix := strings.Repeat("后", 100)
	writeConversation(t, home, "/tmp/proj", "c1", []string{
		userLine(prefix + "关键词" + suffix),
	}, time.Now())

	res, _ := SearchConversations(context.Background(), SearchOptions{Query: "关键词"})
	if len(res.Groups) != 1 || len(res.Groups[0].Hits) != 1 {
		t.Fatalf("expected one hit, got %+v", res.Groups)
	}
	snippet := res.Groups[0].Hits[0].Snippet

	if !strings.Contains(snippet, "关键词") {
		t.Fatalf("snippet lost the match: %q", snippet)
	}
	if !strings.HasPrefix(snippet, "…") || !strings.HasSuffix(snippet, "…") {
		t.Errorf("long text on both sides should be elided: %q", snippet)
	}
	// 60 runes before + 3 for the keyword + 90 after, plus two ellipses.
	if got := utf8.RuneCountInString(snippet); got > 156 {
		t.Errorf("snippet too long: %d runes", got)
	}
	if !utf8.ValidString(snippet) {
		t.Errorf("invalid UTF-8: %q", snippet)
	}
}

func TestSearchConversationsRangeFilter(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	writeConversation(t, home, "/tmp/proj", "recent", []string{userLine("近期会话里有目标词")}, time.Now())
	writeConversation(t, home, "/tmp/proj", "ancient",
		[]string{userLine("老会话里也有目标词")}, time.Now().AddDate(0, 0, -200))

	// Default window: the 200-day-old conversation is out of range.
	res, _ := SearchConversations(context.Background(), SearchOptions{Query: "目标词"})
	if len(res.Groups) != 1 || res.Groups[0].Conversation.SessionID != "recent" {
		t.Fatalf("default range should only match the recent conversation: %+v", res.Groups)
	}

	// All lifts the window.
	resAll, _ := SearchConversations(context.Background(), SearchOptions{Query: "目标词", All: true})
	if len(resAll.Groups) != 2 {
		t.Fatalf("All should match both conversations, got %d", len(resAll.Groups))
	}
}

func TestSearchConversationsMaxHitsTruncates(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	var lines []string
	for i := 0; i < 6; i++ {
		lines = append(lines, userLine(fmt.Sprintf("第 %d 个包含命中词的消息", i)))
	}
	writeConversation(t, home, "/tmp/proj", "c1", lines, time.Now())

	res, _ := SearchConversations(context.Background(), SearchOptions{Query: "命中词", MaxHits: 2})
	if !res.Truncated {
		t.Errorf("expected Truncated with MaxHits=2, got %+v", res)
	}
	total := 0
	for _, g := range res.Groups {
		total += len(g.Hits)
	}
	if total != 2 {
		t.Errorf("hits = %d, want exactly 2", total)
	}
}

func TestSearchConversationsConcurrentFilesStayOrdered(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	now := time.Now()
	for i := 0; i < 12; i++ {
		// c00 is the newest (mtime desc puts it first), c11 the oldest.
		writeConversation(t, home, "/tmp/proj",
			fmt.Sprintf("c%02d", i),
			[]string{userLine("并发搜索关键词")},
			now.Add(-time.Duration(i)*time.Minute))
	}

	res, _ := SearchConversations(context.Background(), SearchOptions{Query: "并发搜索关键词", Workers: 4})
	if len(res.Groups) != 12 {
		t.Fatalf("groups = %d, want 12", len(res.Groups))
	}
	// Results must follow the candidate order (mtime desc), not completion order.
	for i, g := range res.Groups {
		want := fmt.Sprintf("c%02d", i)
		if g.Conversation.SessionID != want {
			t.Fatalf("group %d = %s, want %s (order must follow mtime desc)", i, g.Conversation.SessionID, want)
		}
	}
	if res.ScannedConvos != 12 {
		t.Errorf("scanned = %d, want 12", res.ScannedConvos)
	}
}

func TestSearchConversationsHonoursCancelledContext(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetConversationsCache()

	writeConversation(t, home, "/tmp/proj", "c1", []string{userLine("取消测试关键词")}, time.Now())

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res, _ := SearchConversations(ctx, SearchOptions{Query: "取消测试关键词"})
	if len(res.Groups) != 0 {
		t.Errorf("cancelled search should return no groups, got %d", len(res.Groups))
	}
}

func TestSearchConversationsEmptyQuery(t *testing.T) {
	res, _ := SearchConversations(context.Background(), SearchOptions{Query: "   "})
	if len(res.Groups) != 0 || res.ScannedConvos != 0 {
		t.Errorf("blank query should do nothing: %+v", res)
	}
}

func TestSnippetAroundBoundaries(t *testing.T) {
	// Match at the very start: nothing to elide before it.
	if got := snippetAround("hello world", 0, 5, 60, 90); got != "hello world" {
		t.Errorf("start match = %q", got)
	}
	// Match at the very end: nothing to elide after it.
	if got := snippetAround("say hello", 4, 5, 60, 90); got != "say hello" {
		t.Errorf("end match = %q", got)
	}
	// No context available at all.
	if got := snippetAround("命中", 0, len("命中"), 60, 90); got != "命中" {
		t.Errorf("no-context = %q", got)
	}
	// Multi-byte: the window counts runes, and must never split one.
	prefix := strings.Repeat("中", 100)
	suffix := strings.Repeat("文", 100)
	s := prefix + "命中" + suffix
	got := snippetAround(s, len(prefix), len("命中"), 60, 90)
	if !utf8.ValidString(got) {
		t.Fatalf("invalid UTF-8: %q", got)
	}
	if !strings.Contains(got, "命中") {
		t.Fatalf("lost the match: %q", got)
	}
	if !strings.HasPrefix(got, "…") || !strings.HasSuffix(got, "…") {
		t.Errorf("both sides should be elided: %q", got)
	}
	// 60 runes before + 2 for the match + 90 after + two ellipses.
	if n := utf8.RuneCountInString(got); n != 60+2+90+2 {
		t.Errorf("window = %d runes, want %d", n, 60+2+90+2)
	}
}

func TestAgentProjectsRoot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	if got, want := agentProjectsRoot("claude"), filepath.Join(home, ".claude", "projects"); got != want {
		t.Errorf("claude root = %q, want %q", got, want)
	}
	// Everything else means codebuddy — including an agent name we have never
	// seen, which is the documented behaviour.
	for _, agent := range []string{"codebuddy", "", "some-future-agent"} {
		if got, want := agentProjectsRoot(agent), filepath.Join(home, ".codebuddy", "projects"); got != want {
			t.Errorf("root(%q) = %q, want %q", agent, got, want)
		}
	}
}

func TestGetSessionUsageFullForClaude(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	dir := filepath.Join(home, ".claude", "projects", "tmp-proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	line := `{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn",` +
		`"usage":{"input_tokens":777,"output_tokens":5,"cache_read_input_tokens":0}}}`
	if err := os.WriteFile(filepath.Join(dir, "claude-conv.jsonl"), []byte(line+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	u, err := GetSessionUsageFullFor("claude", "claude-conv")
	if err != nil {
		t.Fatalf("GetSessionUsageFullFor(claude): %v", err)
	}
	if u.Input != 777 {
		t.Errorf("input = %d, want 777", u.Input)
	}
	if u.Activity.LastRecordType != "assistant" || u.Activity.LastStatus != "end_turn" {
		t.Errorf("activity = %+v, want assistant/end_turn", u.Activity)
	}
	if !u.Activity.Awaiting(time.Now().Add(time.Hour)) {
		t.Error("a settled claude turn should read as awaiting input")
	}

	// The codebuddy root must not see it.
	if _, err := GetSessionUsageFullFor("codebuddy", "claude-conv"); err == nil {
		t.Error("codebuddy lookup should not find a claude conversation")
	}
}
