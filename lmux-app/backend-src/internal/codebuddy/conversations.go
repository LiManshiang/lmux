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
	Size      int64  `json:"size"`
	MTime     int64  `json:"mtime"` // unix seconds (file mod time)
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
	// Restrict to one encoded directory when projectDir is given.
	var walkDir string
	if projectDir != "" {
		enc := encodeAgentProjectDir(agentName, projectDir)
		if enc == "" {
			return nil, nil
		}
		walkDir = filepath.Join(root, enc)
	} else {
		walkDir = root
	}

	var out []ConversationSummary
	err := filepath.WalkDir(walkDir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // skip unreadable entries
		}
		if d.IsDir() {
			return nil
		}
		if filepath.Ext(d.Name()) != ".jsonl" {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		item := probeJSONL(path, agentName, info.Size())
		if item.SessionID == "" {
			return nil
		}
		item.Size = info.Size()
		item.MTime = info.ModTime().Unix()
		out = append(out, item)
		return nil
	})
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("scan %s: %w", walkDir, err)
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
func PreviewConversation(agent, projectDir, sessionID string) []MessageRow {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	var root, enc string
	if agent == "claude" {
		root = ".claude"
		enc = encodeClaudeProjectDir(projectDir)
	} else {
		root = ".codebuddy"
		enc = encodeCodebuddyProjectDir(projectDir)
	}
	path := filepath.Join(home, root, "projects", enc, sessionID+".jsonl")
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return nil
	}
	const tailSize = 128 << 10
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
		if b.Type == "text" && b.Text != "" {
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
