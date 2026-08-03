package session

import "time"

// Status represents the current state of a session.
type Status string

const (
	StatusRunning Status = "running"
	StatusStopped Status = "stopped"
	StatusCrashed Status = "crashed"
)

// Session represents a managed agent session.
type Session struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	ProjectDir   string    `json:"project_dir"`
	CBCSessionID string    `json:"cbc_session_id,omitempty"`
	AgentType    string    `json:"agent_type,omitempty"`
	Status       Status    `json:"status"`
	AiTitle      string    `json:"ai_title,omitempty"`
	GitBranch    string    `json:"git_branch,omitempty"`
	Pid          int       `json:"pid"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// CreateRequest is used to create a new session.
type CreateRequest struct {
	ProjectDir   string `json:"project_dir"`
	Name         string `json:"name,omitempty"`
	CBCSessionID string `json:"cbc_session_id,omitempty"`
	AgentType    string `json:"agent_type,omitempty"`
}

// RenameRequest is used to rename a session.
type RenameRequest struct {
	Name string `json:"name"`
}

// Summary is a lightweight view of a session for list display.
type Summary struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	ProjectDir     string `json:"project_dir"`
	CBCSessionID   string `json:"cbc_session_id,omitempty"`
	AgentType      string `json:"agent_type,omitempty"`
	Status         Status `json:"status"`
	AiTitle        string `json:"ai_title,omitempty"`
	GitBranch      string `json:"git_branch,omitempty"`
	NeedsAttention bool   `json:"needs_attention"`
}
