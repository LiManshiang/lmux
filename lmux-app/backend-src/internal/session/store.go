package session

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// Store provides persistent storage for session metadata.
type Store struct {
	db *sql.DB
}

// NewStore opens (or creates) the SQLite store at the given path.
func NewStore(dbPath string) (*Store, error) {
	dir := filepath.Dir(dbPath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, fmt.Errorf("create db dir: %w", err)
	}

	db, err := sql.Open("sqlite3", dbPath+"?_journal_mode=WAL")
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping db: %w", err)
	}

	if err := migrate(db); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}

	return &Store{db: db}, nil
}

// Close closes the database connection.
func (s *Store) Close() error {
	return s.db.Close()
}

// DefaultDBPath returns the default database path.
func DefaultDBPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".lmux", "sessions.db")
}

func migrate(db *sql.DB) error {
	query := `
	CREATE TABLE IF NOT EXISTS sessions (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		project_dir TEXT NOT NULL,
		cbc_session_id TEXT DEFAULT '',
		agent_type TEXT DEFAULT 'codebuddy',
		status TEXT NOT NULL DEFAULT 'stopped',
		ai_title TEXT DEFAULT '',
		git_branch TEXT DEFAULT '',
		pid INTEGER DEFAULT 0,
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
	CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at);
	`
	_, err := db.Exec(query)
	if err != nil {
		return err
	}

	// Migration: add agent_type column if upgrading from older schema.
	var version int
	db.QueryRow("PRAGMA user_version").Scan(&version)
	if version < 1 {
		db.Exec("ALTER TABLE sessions ADD COLUMN agent_type TEXT DEFAULT 'codebuddy'")
		db.Exec("PRAGMA user_version = 1")
	}
	return nil
}

// Save inserts or updates a session record.
func (s *Store) Save(sess *Session) error {
	sess.UpdatedAt = time.Now()
	query := `
	INSERT INTO sessions (id, name, project_dir, cbc_session_id,
		agent_type, status, ai_title, git_branch, pid, created_at, updated_at)
	VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(id) DO UPDATE SET
		name=excluded.name,
		project_dir=excluded.project_dir,
		cbc_session_id=excluded.cbc_session_id,
		agent_type=excluded.agent_type,
		status=excluded.status,
		ai_title=excluded.ai_title,
		git_branch=excluded.git_branch,
		pid=excluded.pid,
		updated_at=excluded.updated_at
	`
	_, err := s.db.Exec(query,
		sess.ID, sess.Name, sess.ProjectDir, sess.CBCSessionID,
		sess.AgentType, string(sess.Status), sess.AiTitle, sess.GitBranch,
		sess.Pid, sess.CreatedAt, sess.UpdatedAt,
	)
	return err
}

// Get retrieves a session by ID.
func (s *Store) Get(id string) (*Session, error) {
	query := `SELECT id, name, project_dir, cbc_session_id,
		agent_type, status, ai_title, git_branch, pid, created_at, updated_at
		FROM sessions WHERE id = ?`
	row := s.db.QueryRow(query, id)
	return scanSession(row)
}

// List returns all sessions ordered by updated_at descending.
func (s *Store) List() ([]*Session, error) {
	query := `SELECT id, name, project_dir, cbc_session_id,
		agent_type, status, ai_title, git_branch, pid, created_at, updated_at
		FROM sessions ORDER BY updated_at DESC`
	rows, err := s.db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var sessions []*Session
	for rows.Next() {
		sess, err := scanSessionFromRows(rows)
		if err != nil {
			return nil, err
		}
		sessions = append(sessions, sess)
	}
	return sessions, rows.Err()
}

// ListSummaries returns lightweight session summaries for the polling path,
// selecting only the fields actually used by the frontend.
func (s *Store) ListSummaries() ([]Summary, error) {
	query := `SELECT id, name, project_dir, cbc_session_id,
		agent_type, status, ai_title, git_branch
		FROM sessions ORDER BY updated_at DESC`
	rows, err := s.db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var summaries []Summary
	for rows.Next() {
		var sm Summary
		var statusStr string
		var cbcID, agentType, aiTitle, gitBranch sql.NullString
		if err := rows.Scan(&sm.ID, &sm.Name, &sm.ProjectDir,
			&cbcID, &agentType, &statusStr, &aiTitle, &gitBranch); err != nil {
			return nil, err
		}
		sm.CBCSessionID = cbcID.String
		sm.AgentType = agentType.String
		sm.Status = Status(statusStr)
		sm.AiTitle = aiTitle.String
		sm.GitBranch = gitBranch.String
		summaries = append(summaries, sm)
	}
	return summaries, rows.Err()
}

// Delete removes a session by ID.
func (s *Store) Delete(id string) error {
	_, err := s.db.Exec(`DELETE FROM sessions WHERE id = ?`, id)
	return err
}

// ListByStatus returns sessions filtered by status.
func (s *Store) ListByStatus(status Status) ([]*Session, error) {
	query := `SELECT id, name, project_dir, cbc_session_id,
		agent_type, status, ai_title, git_branch, pid, created_at, updated_at
		FROM sessions WHERE status = ? ORDER BY updated_at DESC`
	rows, err := s.db.Query(query, string(status))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var sessions []*Session
	for rows.Next() {
		sess, err := scanSessionFromRows(rows)
		if err != nil {
			return nil, err
		}
		sessions = append(sessions, sess)
	}
	return sessions, rows.Err()
}

func scanSession(row *sql.Row) (*Session, error) {
	sess := &Session{}
	var status string
	err := row.Scan(
		&sess.ID, &sess.Name, &sess.ProjectDir, &sess.CBCSessionID,
		&sess.AgentType, &status, &sess.AiTitle, &sess.GitBranch,
		&sess.Pid, &sess.CreatedAt, &sess.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	sess.Status = Status(status)
	return sess, nil
}

func scanSessionFromRows(rows *sql.Rows) (*Session, error) {
	sess := &Session{}
	var status string
	err := rows.Scan(
		&sess.ID, &sess.Name, &sess.ProjectDir, &sess.CBCSessionID,
		&sess.AgentType, &status, &sess.AiTitle, &sess.GitBranch,
		&sess.Pid, &sess.CreatedAt, &sess.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	sess.Status = Status(status)
	return sess, nil
}
