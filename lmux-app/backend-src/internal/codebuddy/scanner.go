package codebuddy

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// SessionInfo is a lightweight summary extracted from a CodeBuddy session JSONL.
type SessionInfo struct {
	SessionID string `json:"session_id"`
	CWD       string `json:"cwd"`
	AiTitle   string `json:"ai_title"`
	Timestamp int64  `json:"timestamp"`
	// HasAssistant records whether the session ever received an assistant
	// reply. Sessions with only user messages (e.g. one started then
	// immediately resumed away from) are not real conversations and should
	// not be picked as the "recent" session.
	HasAssistant bool `json:"-"`
}

// Cache for scanned sessions to avoid repeated file I/O.
var (
	cacheMu        sync.RWMutex
	cachedSessions []SessionInfo
	sessionByID    map[string]SessionInfo
	cacheValid     bool
	cacheTime      time.Time
)

const cacheTTL = 30 * time.Second

// InvalidateCache forces a re-scan on the next call.
func InvalidateCache() {
	cacheMu.Lock()
	cacheValid = false
	cacheMu.Unlock()
}

// ScanDir scans the CodeBuddy sessions directory and returns all found sessions.
// The sessionsDir is typically ~/.codebuddy/projects/Users-{username}/
func ScanDir(sessionsDir string) ([]SessionInfo, error) {
	entries, err := os.ReadDir(sessionsDir)
	if err != nil {
		return nil, fmt.Errorf("read sessions dir %s: %w", sessionsDir, err)
	}

	var sessions []SessionInfo
	seen := map[string]bool{}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(entry.Name(), ".jsonl") {
			continue
		}

		path := filepath.Join(sessionsDir, entry.Name())
		info, err := parseJSONL(path)
		if err != nil {
			// skip files we can't parse
			continue
		}
		if info.SessionID == "" {
			continue
		}
		if seen[info.SessionID] {
			continue
		}
		seen[info.SessionID] = true
		sessions = append(sessions, info)
	}

	return sessions, nil
}

// DefaultSessionsDir returns the default CodeBuddy sessions directory.
func DefaultSessionsDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codebuddy", "projects")
}

// FindUserSessionsDir finds the session directories under the projects root
// for the current user.
func FindUserSessionsDirs() ([]string, error) {
	root := DefaultSessionsDir()
	if root == "" {
		return nil, fmt.Errorf("cannot determine home directory")
	}

	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", root, err)
	}

	var dirs []string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dirs = append(dirs, filepath.Join(root, entry.Name()))
	}
	return dirs, nil
}

// ScanAll scans all user session directories and returns combined results.
// Results are cached to avoid repeated file I/O.
func ScanAll() ([]SessionInfo, error) {
	cacheMu.RLock()
	if cacheValid && time.Since(cacheTime) < cacheTTL {
		result := cachedSessions
		cacheMu.RUnlock()
		return result, nil
	}
	cacheMu.RUnlock()

	cacheMu.Lock()
	defer cacheMu.Unlock()

	// Double-check after acquiring write lock
	if cacheValid && time.Since(cacheTime) < cacheTTL {
		return cachedSessions, nil
	}

	dirs, err := FindUserSessionsDirs()
	if err != nil {
		return nil, err
	}

	var all []SessionInfo
	for _, dir := range dirs {
		sessions, err := ScanDir(dir)
		if err != nil {
			continue
		}
		all = append(all, sessions...)
	}

	cachedSessions = all
	sessionByID = make(map[string]SessionInfo, len(all))
	for _, s := range all {
		sessionByID[s.SessionID] = s
	}
	cacheValid = true
	cacheTime = time.Now()
	return all, nil
}

// GetSessionByID looks up a single session by its CodeBuddy session ID.
func GetSessionByID(sessionID string) (*SessionInfo, error) {
	// Ensure cache is populated.
	_, err := ScanAll()
	if err != nil {
		return nil, err
	}

	cacheMu.RLock()
	defer cacheMu.RUnlock()
	if info, ok := sessionByID[sessionID]; ok {
		return &info, nil
	}
	return nil, fmt.Errorf("session %s not found", sessionID)
}

func parseJSONL(path string) (SessionInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return SessionInfo{}, err
	}
	defer f.Close()

	var info SessionInfo
	scanner := bufio.NewScanner(f)
	// increase buffer for long JSON lines
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		var entry struct {
			SessionID string `json:"sessionId"`
			CWD       string `json:"cwd"`
			Timestamp int64  `json:"timestamp"`
			Type      string `json:"type"`
			Role      string `json:"role"`
			AiTitle   string `json:"aiTitle"`
		}
		if err := json.Unmarshal(line, &entry); err != nil {
			continue
		}

		// fill in SessionID and CWD from the first record
		if info.SessionID == "" && entry.SessionID != "" {
			info.SessionID = entry.SessionID
		}
		if info.CWD == "" && entry.CWD != "" {
			info.CWD = entry.CWD
		}

		// use the last ai-title entry
		if entry.Type == "ai-title" && entry.AiTitle != "" {
			info.AiTitle = entry.AiTitle
		}

		// a real conversation has at least one assistant reply
		if entry.Type == "message" && entry.Role == "assistant" {
			info.HasAssistant = true
		}

		// track latest timestamp (scan the whole file so Timestamp reflects
		// the last activity, not wherever an early break happened)
		if entry.Timestamp > info.Timestamp {
			info.Timestamp = entry.Timestamp
		}
	}

	if info.SessionID == "" {
		return info, fmt.Errorf("no session ID found in %s", path)
	}

	return info, nil
}

// FindRecentSessionForProject returns the most recently created codebuddy
// conversation in a project directory, or "" when there is none. It includes
// empty sessions: a freshly launched codebuddy creates a 0-byte JSONL before
// any message, and resuming it behaves like a new conversation.
func FindRecentSessionForProject(projectDir string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	encoded := strings.TrimPrefix(projectDir, "/")
	encoded = strings.ReplaceAll(encoded, "/", "-")
	return findRecentCached(filepath.Join(home, ".codebuddy", "projects", encoded), nil)
}

// FindRecentSessionForProjectAfter returns the most recently created codebuddy
// conversation ID created after the given time, or "" when there is none.
func FindRecentSessionForProjectAfter(projectDir string, after time.Time) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	encoded := strings.TrimPrefix(projectDir, "/")
	encoded = strings.ReplaceAll(encoded, "/", "-")
	return findRecentCached(filepath.Join(home, ".codebuddy", "projects", encoded), &after)
}

// ContextWindowTokens is the context window for the default model
// (deepseek-v4-flash). Used to render the conversation context usage
// percentage. CodeBuddy's model metadata reports contextWindow:1e6.
const ContextWindowTokens int64 = 1_000_000

// encodeClaudeProjectDir converts a filesystem path to claude's project
// directory name, e.g. /Users/limanshiang -> -Users-limanshiang.
func encodeClaudeProjectDir(dir string) string {
	return strings.ReplaceAll(dir, "/", "-")
}

// creationTime returns a file's creation (birth) time. Used to pick the
// session the user most recently started, rather than the one most recently
// written to (a long-lived session is touched on every run).
func creationTime(path string) time.Time {
	var st syscall.Stat_t
	if err := syscall.Stat(path, &st); err != nil {
		return time.Time{}
	}
	return time.Unix(st.Birthtimespec.Sec, st.Birthtimespec.Nsec)
}

// latestSessionFile picks the conversation that a freshly launched agent is
// actually using, or "" when there is none.
//
// Two cases are handled:
//
//  1. Fresh launch: the agent creates a NEW conversation file right at start.
//     With `after` (the agent process start time) set, we return the file
//     created AT/after that time with the EARLIEST creation time — each agent
//     binds to its own new conversation. Taking the newest file here is wrong:
//     when two sessions both launch codebuddy, the active one's conversation
//     is newer, so the idle session silently binds to the OTHER session's
//     conversation.
//
//  2. /resume inside the agent: `codebuddy` then `/resume <old-id>` switches
//     the live conversation WITHOUT changing argv and WITHOUT creating a new
//     file — the resumed (old) file is simply written again. In that case no
//     file was created at/after `after`, so we fall back to the file with the
//     most recent MODIFICATION time (the live conversation).
func latestSessionFile(dir string, after *time.Time) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	var closestCreated string
	var closestCreatedDelta time.Duration
	var newestModified string
	var newestModifiedTime time.Time
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		p := filepath.Join(dir, e.Name())
		var st syscall.Stat_t
		if err := syscall.Stat(p, &st); err != nil {
			continue
		}
		modified := time.Unix(st.Mtimespec.Sec, st.Mtimespec.Nsec)
		created := time.Unix(st.Birthtimespec.Sec, st.Birthtimespec.Nsec)
		name := strings.TrimSuffix(e.Name(), ".jsonl")

		if modified.After(newestModifiedTime) {
			newestModified = name
			newestModifiedTime = modified
		}
		// Fresh launch: the agent creates its own conversation at process
		// start, so the file with creation time CLOSEST to (but at/after) the
		// process start is the one this agent made. A second agent launched a
		// moment later gets its own, slightly later file.
		//
		// Deliberately NOT filtered by file size: codebuddy's /model, /skills
		// and friends run without writing conversation content, so the "used"
		// conversation of that session is a 0-byte file. Preferring non-empty
		// files makes every session grab the project's ONE non-empty
		// conversation (e.g. the "hello" session) and all of them cross-bind to
		// it. The file this process created — empty or not — is the one this
		// session owns.
		if after != nil && !created.Before(*after) {
			delta := created.Sub(*after)
			if closestCreated == "" || delta < closestCreatedDelta {
				closestCreated = name
				closestCreatedDelta = delta
			}
		}
	}
	// Case 1: a conversation was created at/after the launch — that is this
	// agent's own fresh conversation.
	if closestCreated != "" {
		return closestCreated
	}
	// Case 2: no file was created at/after launch — the agent resumed an
	// existing conversation (`codebuddy` then `/resume <old-id>`, or lmux
	// itself launched it with `--resume`). The live conversation is the most
	// recently modified file.
	return newestModified
}

// Recent find-session results are cached briefly: the sidebar queries context
// on a timer, and re-scanning every project directory each time is wasteful.
// A short TTL is fine because resuming a just-started session is rare within
// a few seconds of a scan.
var sessionFindCache struct {
	sync.Mutex
	m map[string]cachedFind
}

type cachedFind struct {
	sessionID string
	at        time.Time
}

const findCacheTTL = 3 * time.Second

// ClearFindSessionCache drops all cached find-session results. Called when
// sessions are created/deleted so a fresh session isn't shadowed by a cached
// result.
func ClearFindSessionCache() {
	sessionFindCache.Lock()
	defer sessionFindCache.Unlock()
	sessionFindCache.m = nil
}

func cachedFindSession(dir string) (string, bool) {
	sessionFindCache.Lock()
	defer sessionFindCache.Unlock()
	if c, ok := sessionFindCache.m[dir]; ok && time.Since(c.at) < findCacheTTL {
		return c.sessionID, true
	}
	return "", false
}

func rememberFindSession(dir, sessionID string) {
	sessionFindCache.Lock()
	defer sessionFindCache.Unlock()
	if sessionFindCache.m == nil {
		sessionFindCache.m = make(map[string]cachedFind)
	}
	sessionFindCache.m[dir] = cachedFind{sessionID: sessionID, at: time.Now()}
}

func findRecentCached(dir string, after *time.Time) string {
	// Time-scoped lookups must be exact (the caller wants the conversation a
	// just-started agent created), so skip the cache for them.
	if after == nil {
		if id, ok := cachedFindSession(dir); ok {
			return id
		}
	}
	id := latestSessionFile(dir, after)
	if after == nil {
		rememberFindSession(dir, id)
	}
	return id
}

// FindRecentClaudeSession returns the most recently created claude
// conversation ID for a project directory, or "" when there is none.
func FindRecentClaudeSession(projectDir string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	projDir := filepath.Join(home, ".claude", "projects", encodeClaudeProjectDir(projectDir))
	return findRecentCached(projDir, nil)
}

// FindRecentClaudeSessionAfter returns the most recently created claude
// conversation ID created after the given time (agent process start), or ""
// when there is none. Scopes a fresh launch to the conversation it created.
func FindRecentClaudeSessionAfter(projectDir string, after time.Time) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	projDir := filepath.Join(home, ".claude", "projects", encodeClaudeProjectDir(projectDir))
	return findRecentCached(projDir, &after)
}

// GetClaudeContextTokens estimates the conversation context size (tokens)
// for a claude session. claude's JSONL has no usage counters, so we estimate
// from the message text length (~2 chars per token for mixed CJK/Latin).
func GetClaudeContextTokens(projectDir, sessionID string) int64 {
	home, err := os.UserHomeDir()
	if err != nil {
		return 0
	}
	dir := filepath.Join(home, ".claude", "projects", encodeClaudeProjectDir(projectDir))
	data, err := os.ReadFile(filepath.Join(dir, sessionID+".jsonl"))
	if err != nil {
		return 0
	}
	var totalChars int64
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry struct {
			Message *struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal([]byte(line), &entry) != nil || entry.Message == nil {
			continue
		}
		totalChars += estimateContentChars(entry.Message.Content)
	}
	return totalChars / 2
}

// estimateContentChars returns the character count of a claude message
// content field, which may be a plain string or an array of blocks.
func estimateContentChars(raw json.RawMessage) int64 {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return int64(len([]rune(s)))
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) == nil {
		var n int64
		for _, p := range parts {
			if p.Type == "text" {
				n += int64(len([]rune(p.Text)))
			}
		}
		return n
	}
	return 0
}

// GetSessionContextTokens returns the accumulated input tokens (the current
// conversation context size) for a session, read from the latest message
// usage record in its JSONL.
func GetSessionContextTokens(sessionID string) (int64, error) {
	tokens, _, err := GetSessionContext(sessionID)
	return tokens, err
}

// GetSessionContext returns the accumulated input tokens and the model ID
// from the latest message usage record of a session.
func GetSessionContext(sessionID string) (int64, string, error) {
	input, _, _, model, err := GetSessionUsage(sessionID)
	return input, model, err
}

// GetSessionUsage returns the latest accumulated input tokens, cached input
// tokens, summed output tokens, and the model ID for a session, read from its
// JSONL (same source as the context percentage, so it stays live).
func GetSessionUsage(sessionID string) (input, cacheRead, output int64, model string, err error) {
	dirs, err := FindUserSessionsDirs()
	if err != nil {
		return 0, 0, 0, "", err
	}
	var filePath string
	for _, dir := range dirs {
		p := filepath.Join(dir, sessionID+".jsonl")
		if _, err := os.Stat(p); err == nil {
			filePath = p
			break
		}
	}
	if filePath == "" {
		return 0, 0, 0, "", fmt.Errorf("JSONL for session %s not found", sessionID)
	}
	return lastUsageInfo(filePath)
}

// lastUsageInfo reads the tail of a JSONL file and returns the latest
// accumulated input tokens, cached tokens, summed output tokens, and model
// from the most recent message usage records.
func lastUsageInfo(path string) (input, cacheRead, output int64, model string, err error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, 0, "", err
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		return 0, 0, 0, "", err
	}
	size := stat.Size()

	const tailSize = int64(4 * 1024 * 1024) // scan up to 4MB from the end
	readStart := size - tailSize
	if readStart < 0 {
		readStart = 0
	}
	buf := make([]byte, size-readStart)
	if _, err := f.ReadAt(buf, readStart); err != nil && err != io.EOF {
		return 0, 0, 0, "", err
	}

	lines := strings.Split(string(buf), "\n")
	first := true
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		var entry struct {
			Type         string `json:"type"`
			ProviderData *struct {
				Model          string `json:"model"`
				RequestModelID string `json:"requestModelId"`
			} `json:"providerData"`
			Message struct {
				Usage *struct {
					InputTokens          int64 `json:"input_tokens"`
					OutputTokens         int64 `json:"output_tokens"`
					CacheReadInputTokens int64 `json:"cache_read_input_tokens"`
				} `json:"usage"`
			} `json:"message"`
		}
		if json.Unmarshal([]byte(line), &entry) != nil {
			continue
		}
		// Match ANY record carrying message.usage, not just type=="message".
		// codebuddy writes the latest accumulated input_tokens on
		// function_call records too (and a long-running conversation is
		// frequently topped off by a tool call), so filtering to messages
		// returned a stale percentage that never moved.
		if entry.Message.Usage != nil {
			u := entry.Message.Usage
			output += u.OutputTokens
			if first {
				first = false
				input = u.InputTokens
				cacheRead = u.CacheReadInputTokens
				if entry.ProviderData != nil {
					model = entry.ProviderData.RequestModelID
					if model == "" {
						model = entry.ProviderData.Model
					}
				}
			}
		}
	}
	if first {
		return 0, 0, 0, "", fmt.Errorf("no message usage found in %s", path)
	}
	return input, cacheRead, output, model, nil
}

// GetSessionCreditUsage estimates the total credit (platform cost units) spent
// by a codebuddy session, from its JSONL usage records (same live source as
// the context percentage). Input tokens are the latest accumulated value,
// outputs are summed, and prices come from the model's cost table.
func GetSessionCreditUsage(sessionID string) (float64, error) {
	input, _, output, model, err := GetSessionUsage(sessionID)
	if err != nil {
		return 0, err
	}
	cost := CostForModel(model)
	// Count full input tokens (cached reads are discounted on the platform,
	// but counting them keeps the figure visible and growing with the
	// conversation).
	credit := float64(input)/1e6*cost.Input +
		float64(output)/1e6*cost.Output
	return credit, nil
}
