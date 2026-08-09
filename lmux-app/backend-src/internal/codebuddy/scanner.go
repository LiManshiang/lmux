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

// FindRecentSessionForProject scans all codebuddy session directories
// and returns the most recent session ID for the given project directory.
// Returns empty string if no matching session is found.
func FindRecentSessionForProject(projectDir string) string {
	sessions, err := ScanAll()
	if err != nil {
		return ""
	}

	var best SessionInfo
	for _, s := range sessions {
		if s.CWD == projectDir && s.HasAssistant && s.Timestamp > best.Timestamp {
			best = s
		}
	}
	return best.SessionID
}

// ContextWindowTokens is the context window for the default model
// (deepseek-v4-flash). Used to render the conversation context usage
// percentage. CodeBuddy's model metadata reports contextWindow:1e6.
const ContextWindowTokens int64 = 1_000_000

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
		if entry.Type == "message" && entry.Message.Usage != nil {
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
