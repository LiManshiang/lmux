package session

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/manshiangli/cbsm/internal/codebuddy"
)

// Manager orchestrates session lifecycle.
type Manager struct {
	store *Store
}

// NewManager creates a new session manager.
func NewManager(store *Store) *Manager {
	return &Manager{store: store}
}

// Create creates a new session record. The actual process is spawned by the SwiftTerm frontend.
func (m *Manager) Create(req CreateRequest) (*Session, error) {
	if req.ProjectDir == "" {
		return nil, fmt.Errorf("project_dir is required")
	}

	absDir, err := filepath.Abs(req.ProjectDir)
	if err != nil {
		return nil, fmt.Errorf("resolve project dir: %w", err)
	}

	if info, err := os.Stat(absDir); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("directory does not exist: %s", absDir)
	}

	name := req.Name
	if name == "" {
		name = filepath.Base(absDir)
	}

	id := uuid.New().String()
	cbcID := req.CBCSessionID
	if cbcID == "" {
		cbcID = uuid.New().String()
	}

	aiTitle := ""
	if req.CBCSessionID != "" {
		if info, err := codebuddy.GetSessionByID(req.CBCSessionID); err == nil {
			aiTitle = info.AiTitle
		}
	}

	sess := &Session{
		ID:           id,
		Name:         name,
		ProjectDir:   absDir,
		CBCSessionID: cbcID,
		TmuxSession:  "", // no longer using tmux
		Status:       StatusStopped,
		AiTitle:      aiTitle,
		GitBranch:    getGitBranch(absDir),
		CreatedAt:    time.Now(),
		UpdatedAt:    time.Now(),
	}

	if err := m.store.Save(sess); err != nil {
		return nil, fmt.Errorf("save session: %w", err)
	}

	return sess, nil
}

// Stop marks a session as stopped.
func (m *Manager) Stop(id string) error {
	sess, err := m.store.Get(id)
	if err != nil {
		return err
	}
	sess.Status = StatusStopped
	sess.Pid = 0
	return m.store.Save(sess)
}

// Delete removes a session entirely.
func (m *Manager) Delete(id string) error {
	m.Stop(id)
	return m.store.Delete(id)
}

// Rename updates the session's display name.
func (m *Manager) Rename(id, name string) (*Session, error) {
	sess, err := m.store.Get(id)
	if err != nil {
		return nil, err
	}
	sess.Name = name
	if err := m.store.Save(sess); err != nil {
		return nil, err
	}
	return sess, nil
}

// Get returns a session by ID.
func (m *Manager) Get(id string) (*Session, error) {
	return m.store.Get(id)
}

// List returns all sessions.
func (m *Manager) List() ([]*Session, error) {
	return m.store.List()
}

// RestoreAll scans for historical CBC sessions and creates records for them.
func (m *Manager) RestoreAll() ([]*Session, error) {
	existing, err := m.store.List()
	if err != nil {
		return nil, err
	}
	existingIDs := map[string]bool{}
	for _, s := range existing {
		existingIDs[s.CBCSessionID] = true
	}

	cbcSessions, err := codebuddy.ScanAll()
	if err != nil {
		return nil, fmt.Errorf("scan cbc sessions: %w", err)
	}

	var restored []*Session
	for _, info := range cbcSessions {
		if info.CWD == "" { continue }
		if existingIDs[info.SessionID] { continue }
		if _, err := os.Stat(info.CWD); os.IsNotExist(err) { continue }

		name := filepath.Base(info.CWD)
		if info.AiTitle != "" {
			name = name + " - " + info.AiTitle
		}

		sess, err := m.Create(CreateRequest{
			ProjectDir:   info.CWD,
			Name:         name,
			CBCSessionID: info.SessionID,
		})
		if err != nil { continue }
		restored = append(restored, sess)
	}

	return restored, nil
}

// Summaries returns lightweight summaries for all sessions.
func (m *Manager) Summaries() ([]Summary, error) {
	sessions, err := m.List()
	if err != nil {
		return nil, err
	}
	summaries := make([]Summary, len(sessions))
	for i, s := range sessions {
		summaries[i] = Summary{
			ID:           s.ID,
			Name:         s.Name,
			ProjectDir:   s.ProjectDir,
			CBCSessionID: s.CBCSessionID,
			Status:       s.Status,
			AiTitle:      s.AiTitle,
			GitBranch:    s.GitBranch,
		}
	}
	return summaries, nil
}

func getGitBranch(dir string) string {
	cmd := exec.Command("git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	branch := strings.TrimSpace(string(out))
	if branch == "HEAD" { return "" }
	return branch
}
