package codebuddy

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// ConversationSummary is one raw agent conversation (a JSONL file) for the
// Agent browser. It is the filesystem-level view — independent of lmux's own
// session records, so conversations that were never opened in lmux are still
// browsable and resumable on any machine that has the JSONL.
type ConversationSummary struct {
	Agent     string `json:"agent"`
	SessionID string `json:"id"`
	AITitle   string `json:"ai_title"`
	Summary   string `json:"summary"`
	CWD       string `json:"cwd"`
	// FileRel is the conversation file's path relative to the agent projects
	// root (e.g. "Users-limanshiang/<id>.jsonl"). The file's directory is the
	// encoded project it was launched under, which can differ from CWD once the
	// agent cd'd elsewhere — so previews and restores locate files via FileRel.
	FileRel string `json:"file_rel"`
	Size    int64  `json:"size"`
	MTime   int64  `json:"mtime"` // unix seconds (file mod time)
}

type conversationsCacheEntry struct {
	agent      string
	projectDir string
	at         time.Time
	items      []ConversationSummary
}

var (
	conversationsMu    sync.Mutex
	conversationsCache conversationsCacheEntry
)

const conversationsCacheTTL = 5 * time.Second

// ListConversations returns conversation summaries for agent ("codebuddy",
// "claude", or "" for both). projectDir filters to one project directory; ""
// scans every project directory under the agent's projects root.
//
// Performance: only the file head (64KB) and tail (64KB) are read, so large
// JSONL histories cost the same as small ones. Results are cached 5s.
func ListConversations(agent, projectDir string) ([]ConversationSummary, error) {
	conversationsMu.Lock()
	if time.Since(conversationsCache.at) < conversationsCacheTTL &&
		conversationsCache.agent == agent &&
		conversationsCache.projectDir == projectDir {
		items := conversationsCache.items
		conversationsMu.Unlock()
		return items, nil
	}
	conversationsMu.Unlock()

	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}

	var out []ConversationSummary
	type rootSpec struct {
		agentName string
		root      string
	}
	var roots []rootSpec
	if agent == "" || agent == "codebuddy" {
		roots = append(roots, rootSpec{"codebuddy", filepath.Join(home, ".codebuddy", "projects")})
	}
	if agent == "" || agent == "claude" {
		roots = append(roots, rootSpec{"claude", filepath.Join(home, ".claude", "projects")})
	}
	for _, spec := range roots {
		items, err := scanProjectRoot(spec.agentName, spec.root, projectDir)
		if err != nil {
			return nil, err
		}
		out = append(out, items...)
	}

	sort.Slice(out, func(i, j int) bool { return out[i].MTime > out[j].MTime })

	conversationsMu.Lock()
	conversationsCache = conversationsCacheEntry{agent: agent, projectDir: projectDir, at: time.Now(), items: out}
	conversationsMu.Unlock()
	return out, nil
}

func scanProjectRoot(agentName, root, projectDir string) ([]ConversationSummary, error) {
	// Determine the project directories to scan. When projectDir is given we
	// scan only its encoded directory; otherwise every top-level directory.
	// Only files directly under a project dir (depth 1) are conversations —
	// deeper JSONL (subagents/, task sub-conversations) is agent-internal and
	// is not browsable as a top-level conversation.
	var dirs []string
	if projectDir != "" {
		enc := encodeAgentProjectDir(agentName, projectDir)
		if enc == "" {
			return nil, nil
		}
		dirs = []string{filepath.Join(root, enc)}
	} else {
		entries, err := os.ReadDir(root)
		if err != nil {
			if os.IsNotExist(err) {
				return nil, nil
			}
			return nil, fmt.Errorf("scan %s: %w", root, err)
		}
		for _, e := range entries {
			if e.IsDir() {
				dirs = append(dirs, filepath.Join(root, e.Name()))
			}
		}
	}

	var out []ConversationSummary
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || filepath.Ext(e.Name()) != ".jsonl" {
				continue
			}
			path := filepath.Join(dir, e.Name())
			info, err := e.Info()
			if err != nil {
				continue
			}
			item := probeJSONL(path, agentName, info.Size())
			if item.SessionID == "" {
				continue
			}
			if rel, err := filepath.Rel(root, path); err == nil {
				item.FileRel = rel
			}
			item.Size = info.Size()
			item.MTime = info.ModTime().Unix()
			out = append(out, item)
		}
	}
	return out, nil
}

func encodeAgentProjectDir(agentName, projectDir string) string {
	switch agentName {
	case "claude":
		return encodeClaudeProjectDir(projectDir)
	default:
		return encodeCodebuddyProjectDir(projectDir)
	}
}

// findConversationFile returns the on-disk path of an agent conversation by
// scanning the top-level encoded project directories for "<id>.jsonl".
func findConversationFile(agent, sessionID string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	var root string
	if agent == "claude" {
		root = filepath.Join(home, ".claude", "projects")
	} else {
		root = filepath.Join(home, ".codebuddy", "projects")
	}
	target := sessionID + ".jsonl"

	entries, err := os.ReadDir(root)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		p := filepath.Join(root, e.Name(), target)
		if info, err := os.Stat(p); err == nil && info.Mode().IsRegular() {
			return p
		}
	}
	// Some setups keep files directly in the root.
	direct := filepath.Join(root, target)
	if info, err := os.Stat(direct); err == nil && info.Mode().IsRegular() {
		return direct
	}
	return ""
}

// probeJSONL reads a small head/tail window and extracts a conversation's id,
// ai-title, summary and cwd without parsing the whole (potentially huge) file.
func probeJSONL(path, agentName string, size int64) ConversationSummary {
	const window = 64 << 10
	var conv ConversationSummary
	conv.Agent = agentName

	regions := []struct {
		off int64
		n   int64
	}{}
	head := size
	if head > window {
		head = window
	}
	regions = append(regions, struct {
		off int64
		n   int64
	}{0, head})
	if size > window+window {
		regions = append(regions, struct {
			off int64
			n   int64
		}{size - window, window})
	}

	f, err := os.Open(path)
	if err != nil {
		return conv
	}
	defer f.Close()

	// Probes run head first, then tail; later observations override (the tail
	// holds the newest ai-title / summary for append-only JSONL).
	processRegion := func(buf []byte) {
		start := 0
		for i := 0; i <= len(buf); i++ {
			if i == len(buf) || buf[i] == '\n' {
				line := bytes.TrimSpace(buf[start:i])
				if len(line) > 0 {
					observeJSONLLine(agentName, line, &conv)
				}
				start = i + 1
			}
		}
	}
	for _, region := range regions {
		buf := make([]byte, region.n)
		if _, err := f.ReadAt(buf, region.off); err != nil {
			continue
		}
		processRegion(buf)
		if conv.SessionID != "" && conv.CWD == "" && agentName == "claude" {
			// claude usually records cwd on the first user row; keep probing.
		}
	}
	return conv
}

// MessageRow is one readable user/assistant message for the Agent browser's
// conversation preview.
type MessageRow struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

// PreviewConversation returns the most recent plain-text user/assistant
// messages of a conversation (tool calls/results and reasoning filtered out),
// read from the JSONL tail so huge files stay cheap.
//
// The file is located by scanning the agent's project directories for the id
// — the conversation's cwd can wander after cd, so directory-encoded-from-cwd
// lookups miss many files.
func PreviewConversation(agent, sessionID string) []MessageRow {
	path := findConversationFile(agent, sessionID)
	if path == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return nil
	}
	// 512KB covers a full recent turn (user + tool rounds + assistant reply);
	// 128KB often misses the last user message entirely.
	const tailSize = 512 << 10
	off := st.Size() - tailSize
	if off < 0 {
		off = 0
	}
	buf := make([]byte, tailSize)
	n, err := f.ReadAt(buf, off)
	if err != nil && n == 0 {
		return nil
	}
	buf = buf[:n]

	const maxRows = 14
	var rows []MessageRow
	appendRow := func(role, text string) {
		text = strings.TrimSpace(text)
		if text == "" {
			return
		}
		if len(text) > 600 {
			text = text[:600] + "…"
		}
		rows = append(rows, MessageRow{Role: role, Text: text})
		if len(rows) > maxRows {
			rows = rows[len(rows)-maxRows:]
		}
	}

	start := 0
	for i := 0; i <= len(buf); i++ {
		if i == len(buf) || buf[i] == '\n' {
			line := bytes.TrimSpace(buf[start:i])
			if len(line) > 0 {
				observePreviewLine(agent, line, appendRow)
			}
			start = i + 1
		}
	}
	return rows
}

func observePreviewLine(agent string, line []byte, appendRow func(role, text string)) {
	if agent == "claude" {
		var row struct {
			Type    string `json:"type"`
			Message struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(line, &row) != nil {
			return
		}
		if row.Type != "user" && row.Type != "assistant" {
			return
		}
		role := row.Type
		var text string
		// content is either a plain string or an array of blocks.
		var s string
		if json.Unmarshal(row.Message.Content, &s) == nil {
			text = s
		} else {
			var blocks []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}
			if json.Unmarshal(row.Message.Content, &blocks) == nil {
				for _, b := range blocks {
					if b.Type == "text" && b.Text != "" {
						text += b.Text + "\n"
					}
				}
			}
		}
		if text != "" {
			appendRow(role, text)
		}
		return
	}

	// codebuddy rows.
	var row struct {
		Type    string `json:"type"`
		Role    string `json:"role"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if json.Unmarshal(line, &row) != nil {
		return
	}
	if row.Type != "message" {
		return
	}
	if row.Role != "user" && row.Role != "assistant" {
		return
	}
	var text string
	for _, b := range row.Content {
		// codebuddy text blocks: "text" (older), "output_text" (assistant) and
		// "input_text" (user) in newer files — all carry readable text.
		if (b.Type == "text" || b.Type == "output_text" || b.Type == "input_text") && b.Text != "" {
			text += b.Text + "\n"
		}
	}
	if text != "" {
		appendRow(row.Role, text)
	}
}

// observeJSONLLine parses one line, updating conv in place. Handles both
// codebuddy and claude JSONL row shapes.
func observeJSONLLine(agentName string, line []byte, conv *ConversationSummary) {
	var row map[string]interface{}
	if err := json.Unmarshal(line, &row); err != nil {
		return
	}

	// Shared row-level fields.
	if sid, ok := row["sessionId"].(string); ok && sid != "" && conv.SessionID == "" {
		conv.SessionID = sid
	}
	if cwd, ok := row["cwd"].(string); ok && cwd != "" && conv.CWD == "" {
		conv.CWD = cwd
	}

	typ, _ := row["type"].(string)
	if agentName == "codebuddy" {
		switch typ {
		case "ai-title":
			if t, ok := row["aiTitle"].(string); ok && t != "" {
				conv.AITitle = t
			}
		case "summary":
			if s, ok := row["summary"].(string); ok && s != "" {
				conv.Summary = s
			}
		}
	} else if agentName == "claude" {
		if typ == "last-prompt" {
			if p, ok := row["lastPrompt"].(string); ok && p != "" {
				conv.Summary = p // newest wins (append-only file)
			}
		}
	}
}
