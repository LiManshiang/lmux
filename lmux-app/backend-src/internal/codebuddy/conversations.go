package codebuddy

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
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

	// A conversation can exist under several files (e.g. a restored copy next
	// to the original). Keep the newest per agent+id so the browser never
	// shows duplicate rows (which also made a SwiftUI List highlight several
	// rows sharing one tag).
	out = dedupeConversations(out)

	sort.Slice(out, func(i, j int) bool { return out[i].MTime > out[j].MTime })

	conversationsMu.Lock()
	conversationsCache = conversationsCacheEntry{agent: agent, projectDir: projectDir, at: time.Now(), items: out}
	conversationsMu.Unlock()
	return out, nil
}

// dedupeConversations keeps only the newest entry per agent+id.
func dedupeConversations(items []ConversationSummary) []ConversationSummary {
	byKey := make(map[string]ConversationSummary, len(items))
	for _, c := range items {
		key := c.Agent + "|" + c.SessionID
		if prev, ok := byKey[key]; !ok || c.MTime > prev.MTime {
			byKey[key] = c
		}
	}
	out := make([]ConversationSummary, 0, len(byKey))
	for _, c := range byKey {
		out = append(out, c)
	}
	return out
}

// FilterBoundConversations drops conversations whose session id is in `bound`
// (i.e. already attached to an lmux session) and returns how many were hidden.
func FilterBoundConversations(convs []ConversationSummary, bound map[string]bool) (visible []ConversationSummary, hidden int) {
	visible = make([]ConversationSummary, 0, len(convs))
	for _, c := range convs {
		if bound[c.SessionID] {
			hidden++
			continue
		}
		visible = append(visible, c)
	}
	return visible, hidden
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
	return findConversationInRoot(root, sessionID)
}

// DeleteConversation removes one conversation's JSONL from this machine and
// returns the path that was removed.
//
// The file is located through findConversationFile, so only paths inside the
// agent's projects root can ever be touched. Deletion stays local on purpose:
// the sync layer only adds or overwrites, so a conversation deleted here is
// not removed from other machines (and could be pushed back by one).
func DeleteConversation(agent, sessionID string) (string, error) {
	if sessionID == "" {
		return "", fmt.Errorf("empty session id")
	}
	path := findConversationFile(agent, sessionID)
	if path == "" {
		return "", fmt.Errorf("conversation %s not found", sessionID)
	}
	if err := os.Remove(path); err != nil {
		return "", err
	}
	// The conversation list is memoised for 5s and the scanner keeps parsed
	// summaries; drop both so the row disappears immediately.
	conversationsMu.Lock()
	conversationsCache = conversationsCacheEntry{}
	conversationsMu.Unlock()
	InvalidateCache()
	return path, nil
}

// findConversationInRoot looks for "<sessionID>.jsonl" directly under one of
// the root's subdirectories (or the root itself).
func findConversationInRoot(root, sessionID string) string {
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

// ConversationLocation is where a conversation's JSONL actually is, and the
// directory it belongs to.
type ConversationLocation struct {
	Path string `json:"path"`
	// ProjectDir is a real path for the directory the conversation belongs to,
	// or "" when the conversation's own records do not let one be derived.
	ProjectDir string `json:"project_dir"`
	// Matches reports whether the project directory the caller passed in is
	// that directory. It is answered by comparison rather than by deriving a
	// path, so it stays exact even when a path cannot be derived at all.
	// Vacuously true when the caller passed no directory.
	Matches bool `json:"matches"`
}

// LocateConversation reports where a conversation's file is, and whether a
// given project directory is one the agent would find it from.
//
// The agent resolves `--resume <id>` inside the project folder derived from its
// working directory, and lmux derives the same folder from a session's
// project_dir. A session pointing anywhere else cannot resume: the agent prints
// "No conversation found with session ID", and lmux's own export and
// localize-cwd paths report the file as missing.
func LocateConversation(agent, sessionID, projectDir string) (ConversationLocation, bool) {
	path := findConversationFile(agent, sessionID)
	if path == "" {
		return ConversationLocation{}, false
	}
	folder := filepath.Base(filepath.Dir(path))
	return ConversationLocation{
		Path:       path,
		ProjectDir: conversationProjectDir(path, agent, folder),
		// Answered by looking where the agent would look, not by comparing with
		// the copy that was found above: the same conversation can exist in
		// more than one project folder (a session resumed from a second
		// directory leaves a second file), and the caller's directory is
		// correct if the file is in *its* folder — whichever copy happened to
		// be found first is not the question.
		Matches: projectDir == "" || isFile(AgentSessionFile(agent, projectDir, sessionID)),
	}, true
}

// AgentSessionFile returns the path a conversation must have for the agent to
// find it when launched in projectDir — the folder name is the project
// directory encoded, and the encoding differs per agent. Empty when either the
// directory or the conversation id is missing; an unknown agent is treated as
// codebuddy, matching the rest of this package.
func AgentSessionFile(agent, projectDir, sessionID string) string {
	if projectDir == "" || sessionID == "" {
		return ""
	}
	if agent == "claude" {
		return ClaudeSessionFile(projectDir, sessionID)
	}
	return CodebuddySessionFile(projectDir, sessionID)
}

func isFile(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// conversationProjectDir derives a real path for the directory a conversation
// belongs to, or "" when its records do not pin one down.
//
// A conversation that has lived on two machines records both paths: the old one
// on everything written before the move and the current one after. Only the
// path that reproduces the file's own folder name is the right answer, and the
// earlier records are not automatically it — a conversation started under
// /Users/old and continued under /Volumes/new keeps the old path at the front
// of the file. Head and tail are therefore both sampled: the head holds the
// launch directory in the ordinary case, the tail the newer path after a move.
//
// A candidate has to be an existing directory to be offered, since a path that
// is not there cannot be the directory a session resumes from.
func conversationProjectDir(path, agent, folder string) string {
	seen := make(map[string]bool)
	var candidates []string
	collect := func(raw []byte) {
		for _, m := range cwdFieldRE.FindAllSubmatch(raw, -1) {
			c := string(m[1])
			if c != "" && !seen[c] {
				seen[c] = true
				candidates = append(candidates, c)
			}
		}
	}
	collect(readEdge(path, 0))
	collect(readEdge(path, -1))

	for _, c := range candidates {
		if encodeAgentProjectDir(agent, c) != folder {
			continue
		}
		if info, err := os.Stat(c); err == nil && info.IsDir() {
			return c
		}
	}
	// Nothing reproduced the folder name. One candidate is still better than
	// nothing when it is a directory that exists — a conversation whose file
	// was moved or renamed by hand looks like this — but a guess between
	// several would be a coin flip, and there is no suggestion then.
	if len(candidates) == 1 {
		if info, err := os.Stat(candidates[0]); err == nil && info.IsDir() {
			return candidates[0]
		}
	}
	return ""
}

// readEdge returns a bounded chunk from one end of a file: from the start when
// offset is 0, from the end when it is -1. Both ends matter here and neither
// may be the whole file — a conversation can be hundreds of megabytes.
func readEdge(path string, offset int64) []byte {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	const chunkSize = 64 << 10
	if offset < 0 {
		st, err := f.Stat()
		if err != nil {
			return nil
		}
		offset = st.Size() - chunkSize
		if offset < 0 {
			offset = 0
		}
	}
	buf := make([]byte, chunkSize)
	n, err := f.ReadAt(buf, offset)
	if err != nil && err != io.EOF {
		return nil
	}
	return buf[:n]
}

// ConversationInUse reports whether a live agent has this conversation loaded —
// a process running with `--resume <id>` or `--session-id <id>`.
//
// The session store cannot answer this. Nothing ever sets a session's status to
// running, so a session whose agent is working still reads as stopped, and both
// guards that trusted it were dead code. Nothing may rewrite or move a
// conversation a live agent holds: the agent resolves its file from the
// directory it was launched in, so it keeps writing where it started while the
// history it loaded has gone somewhere else.
//
// A process table that cannot be read counts as "in use": refusing an edit that
// would have been safe costs a retry, while splitting a conversation costs the
// work.
func ConversationInUse(sessionID string) bool {
	if sessionID == "" {
		return false
	}
	out, err := exec.Command("ps", "-Ao", "command=").Output()
	if err != nil {
		return true
	}
	return commandLineHoldsConversation(string(out), sessionID)
}

// commandLineHoldsConversation matches the flags the CLI takes a conversation id
// in, so a command that merely mentions the id — a grep, an editor, a shell
// history line — is not mistaken for an agent holding it. The id has to end
// where the flag's argument ends.
func commandLineHoldsConversation(psOutput, sessionID string) bool {
	for _, line := range strings.Split(psOutput, "\n") {
		for _, flag := range []string{"--resume ", "--session-id "} {
			needle := flag + sessionID
			i := strings.Index(line, needle)
			if i < 0 {
				continue
			}
			switch rest := line[i+len(needle):]; {
			case rest == "", rest[0] == ' ', rest[0] == '"', rest[0] == '\'':
				return true
			}
		}
	}
	return false
}

// ErrConversationMissing reports that no conversation file carries the id, so
// there is nothing to move. A session can outlive its conversation (deleted, or
// bound to an id that was never stored here), and callers need to tell that
// apart from a move that failed.
var ErrConversationMissing = errors.New("conversation not found on this machine")

// MoveConversation relocates a conversation so the agent still finds it from a
// new project directory, rewriting the cwd its records carry.
//
// A session's directory and the folder its conversation is stored in are the
// same thing to the agent: it resolves `--resume <id>` inside the folder named
// after the directory it was launched in. Nothing in the store records that
// link — the folder's name *is* the link — so changing the directory a session
// works in has to take the conversation along, or the next resume fails with
// "No conversation found with session ID".
//
// The records' cwd is rewritten as well. The CLI may or may not consult it, but
// lmux does: the Agent browser resumes a conversation using the cwd it reads
// from the file, and the work-directory lookup answers from it, so a moved
// conversation still claiming the old directory would be pulled back there the
// moment either was used.
//
// The new copy is written in full — streamed, cwd rewritten, renamed into place
// — before the original is touched, so any failure leaves the conversation
// exactly where it was.
func MoveConversation(agent, sessionID, fromDir, toDir string) (string, error) {
	if sessionID == "" {
		return "", fmt.Errorf("no conversation bound to this session")
	}
	if toDir == "" {
		return "", fmt.Errorf("no target directory")
	}
	dst := AgentSessionFile(agent, toDir, sessionID)
	if dst == "" {
		return "", fmt.Errorf("cannot resolve the conversation path for %s", toDir)
	}
	src := AgentSessionFile(agent, fromDir, sessionID)
	if !isFile(src) {
		// The directory the session currently claims does not hold it — it may
		// sit under another project folder (resumed from elsewhere, imported, or
		// left behind by an earlier edit). Move the copy that is really there
		// instead of assuming where it should be.
		src = findConversationFile(agent, sessionID)
	}
	switch {
	case src == "":
		return "", fmt.Errorf("%s: %w", sessionID, ErrConversationMissing)
	case src == dst:
		return dst, nil // already where it belongs
	case isFile(dst):
		return "", fmt.Errorf("a different conversation with this ID is already stored for %s", toDir)
	}
	if ConversationInUse(sessionID) {
		return "", fmt.Errorf("a running agent still has this conversation open; stop it first")
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", err
	}
	if err := rewriteCwdFile(src, dst, toDir); err != nil {
		return "", err
	}
	moveSidecar(src, dst)
	if err := os.Remove(src); err != nil {
		return "", fmt.Errorf("the conversation was copied to %s but the original could not be removed: %w", dst, err)
	}
	return dst, nil
}

// moveSidecar carries the conversation's tool-results directory — the spillover
// its records reference when an output was too large to inline — to the new
// project folder. Best effort: the conversation itself is already complete, and
// a missing sidecar costs a preview, not the history.
//
// Runs after the new copy is complete and before the original is removed, so a
// failure late in the move costs the stale original its sidecar rather than
// costing the live copy anything.
func moveSidecar(src, dst string) {
	from := filepath.Join(filepath.Dir(src), strings.TrimSuffix(filepath.Base(src), filepath.Ext(src)))
	to := filepath.Join(filepath.Dir(dst), strings.TrimSuffix(filepath.Base(dst), filepath.Ext(dst)))
	if from == to {
		return
	}
	if info, err := os.Stat(from); err != nil || !info.IsDir() {
		return
	}
	if _, err := os.Stat(to); err == nil {
		return // something is already there; leave both alone
	}
	_ = os.Rename(from, to)
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
