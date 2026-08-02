package codebuddy

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// SessionInfo is a lightweight summary extracted from a CodeBuddy session JSONL.
type SessionInfo struct {
	SessionID string `json:"session_id"`
	CWD       string `json:"cwd"`
	AiTitle   string `json:"ai_title"`
	Timestamp int64  `json:"timestamp"`
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
func ScanAll() ([]SessionInfo, error) {
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
	return all, nil
}

// GetSessionByID looks up a single session by its CodeBuddy session ID.
func GetSessionByID(sessionID string) (*SessionInfo, error) {
	sessions, err := ScanAll()
	if err != nil {
		return nil, err
	}
	for _, s := range sessions {
		if s.SessionID == sessionID {
			return &s, nil
		}
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

		// track latest timestamp
		if entry.Timestamp > info.Timestamp {
			info.Timestamp = entry.Timestamp
		}
	}

	if info.SessionID == "" {
		return info, fmt.Errorf("no session ID found in %s", path)
	}

	return info, nil
}
