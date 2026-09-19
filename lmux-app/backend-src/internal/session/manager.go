package session

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
	"lmux/cbsm/internal/codebuddy"
)

// ResolveProjectDir turns a requested directory into the absolute path a
// session stores, or fails when it is not an existing directory.
//
// "~" is expanded here rather than left to the caller: the value arrives from a
// text field in the app, where a user writes a path the way a shell takes it,
// and a stored "~/x" would name a project folder nothing else could reproduce —
// the conversation and its records would disagree about where they belong. Abs
// also cleans the path, so a trailing slash is not a different directory from
// the same path without one.
//
// Exported because the edit path has to know the stored value *before* it makes
// the update: changing the directory moves the conversation to it.
func ResolveProjectDir(dir string) (string, error) {
	abs, err := filepath.Abs(codebuddy.ExpandHome(dir))
	if err != nil {
		return "", fmt.Errorf("resolve project dir: %w", err)
	}
	if info, err := os.Stat(abs); err != nil || !info.IsDir() {
		return "", fmt.Errorf("directory does not exist: %s", abs)
	}
	return abs, nil
}

// AdoptWorkDir records the directory a session's agent went to work in, the
// first time that is known, and reports whether it changed anything.
//
// A session is created somewhere — often just the home directory — and the
// first thing its agent does is cd into the project the session is actually
// about. That directory is what the session's directory should be, and the
// agent's own history is the only record of it (nothing tracks the agent's
// current directory: the process cwd never moves and the records keep the
// launch directory).
//
// Only the first determination counts. Once a person has set the directory by
// hand the answer is theirs and this does nothing, which is also why the flag
// exists: without it, re-inferring from the agent's history would eventually
// overwrite a hand-made choice.
//
// The conversation itself is not moved here. Its file follows the directory
// when the session is next prepared for launch — the only moment nothing is
// writing to it.
func (m *Manager) AdoptWorkDir(id, dir string) (*Session, bool, error) {
	sess, err := m.store.Get(id)
	if err != nil {
		return nil, false, err
	}
	if sess.DirByHand || dir == "" {
		return sess, false, nil
	}
	absDir, err := ResolveProjectDir(dir)
	if err != nil {
		return sess, false, nil // a directory that is gone is not a home for the session
	}
	if absDir == sess.ProjectDir {
		return sess, false, nil
	}
	sess.ProjectDir = absDir
	sess.GitBranch = getGitBranch(absDir)
	if err := m.store.Save(sess); err != nil {
		return nil, false, fmt.Errorf("save session: %w", err)
	}
	return sess, true, nil
}

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

	absDir, err := ResolveProjectDir(req.ProjectDir)
	if err != nil {
		return nil, err
	}

	name := req.Name
	if name == "" {
		name = filepath.Base(absDir)
	}

	id := uuid.New().String()
	cbcID := req.CBCSessionID

	aiTitle := ""
	if req.CBCSessionID != "" {
		if info, err := codebuddy.GetSessionByID(req.CBCSessionID); err == nil {
			aiTitle = info.AiTitle
		}
	}

	agentType := req.AgentType
	if agentType == "" {
		agentType = "codebuddy"
	}

	sess := &Session{
		ID:           id,
		Name:         name,
		ProjectDir:   absDir,
		CBCSessionID: cbcID,
		AgentType:    agentType,
		Status:       StatusStopped,
		AiTitle:      aiTitle,
		GitBranch:    getGitBranch(absDir),
		CreatedAt:    time.Now(),
		UpdatedAt:    time.Now(),
	}

	if err := m.store.Save(sess); err != nil {
		return nil, fmt.Errorf("save session: %w", err)
	}

	// Invalidate scanner cache so newly created sessions are visible.
	codebuddy.InvalidateCache()

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
	return m.store.Delete(id)
}

// UpdateStatus updates the session status and PID.
func (m *Manager) UpdateStatus(id string, status Status, pid int) error {
	sess, err := m.store.Get(id)
	if err != nil {
		return err
	}
	sess.Status = status
	sess.Pid = pid
	return m.store.Save(sess)
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

// Update applies optional field updates to an existing session. Only the
// provided (non-nil) fields are changed; the others keep their current
// values. A provided project_dir must resolve to an existing directory (same
// validation as Create), and the git branch is recomputed for the new path.
func (m *Manager) Update(id string, req UpdateRequest) (*Session, error) {
	sess, err := m.store.Get(id)
	if err != nil {
		return nil, err
	}

	if req.Name != nil {
		sess.Name = *req.Name
	}

	if req.ProjectDir != nil {
		absDir, err := ResolveProjectDir(*req.ProjectDir)
		if err != nil {
			return nil, err
		}
		sess.ProjectDir = absDir
		sess.GitBranch = getGitBranch(absDir)
		// A person chose this. Nothing infers the directory after that: the
		// agent's own cd's stop counting, or the next one would quietly undo
		// the choice.
		sess.DirByHand = true
	}

	if req.CBCSessionID != nil {
		sess.CBCSessionID = *req.CBCSessionID
	}

	if err := m.store.Save(sess); err != nil {
		return nil, fmt.Errorf("save session: %w", err)
	}
	return sess, nil
}

// ClearAgentBinding detaches sessions bound to a conversation that no longer
// exists on disk (see Store.ClearAgentBinding).
func (m *Manager) ClearAgentBinding(agentSessionID string) (int, error) {
	return m.store.ClearAgentBinding(agentSessionID)
}

// Get returns a session by ID.
func (m *Manager) Get(id string) (*Session, error) {
	return m.store.Get(id)
}

// FindByCBCSessionID returns the first session bound to an agent conversation
// ID, or an error when none exists.
func (m *Manager) FindByCBCSessionID(cbcID string) (*Session, error) {
	return m.store.FindByCBCSessionID(cbcID)
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
		if info.CWD == "" {
			continue
		}
		if existingIDs[info.SessionID] {
			continue
		}
		if _, err := os.Stat(info.CWD); os.IsNotExist(err) {
			continue
		}

		name := filepath.Base(info.CWD)
		if info.AiTitle != "" {
			name = name + " - " + info.AiTitle
		}

		sess, err := m.Create(CreateRequest{
			ProjectDir:   info.CWD,
			Name:         name,
			CBCSessionID: info.SessionID,
		})
		if err != nil {
			continue
		}
		restored = append(restored, sess)
	}

	return restored, nil
}

// Summaries returns lightweight summaries for all sessions.
func (m *Manager) Summaries() ([]Summary, error) {
	return m.store.ListSummaries()
}

func getGitBranch(dir string) string {
	cmd := exec.Command("git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	branch := strings.TrimSpace(string(out))
	if branch == "HEAD" {
		return ""
	}
	return branch
}

// SetCBCSessionID sets the codebuddy session ID for an existing session.
func (m *Manager) SetCBCSessionID(id, cbcSessionID string) error {
	sess, err := m.store.Get(id)
	if err != nil {
		return err
	}
	sess.CBCSessionID = cbcSessionID
	return m.store.Save(sess)
}

// SetPinned toggles the pinned (starred) flag that keeps a session at the
// top of the sidebar.
func (m *Manager) SetPinned(id string, pinned bool) (*Session, error) {
	sess, err := m.store.Get(id)
	if err != nil {
		return nil, err
	}
	sess.Pinned = pinned
	if err := m.store.Save(sess); err != nil {
		return nil, err
	}
	return sess, nil
}

// Save persists an existing session record (name, project dir, agent type,
// etc. may have been modified in place).
func (m *Manager) Save(sess *Session) error {
	return m.store.Save(sess)
}
