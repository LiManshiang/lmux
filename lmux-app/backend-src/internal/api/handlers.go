package api

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"lmux/cbsm/internal/codebuddy"
	"lmux/cbsm/internal/session"
)

type Handler struct {
	mgr *session.Manager
}

func NewHandler(mgr *session.Manager) *Handler {
	return &Handler{mgr: mgr}
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *Handler) ListSessions(w http.ResponseWriter, r *http.Request) {
	summaries, err := h.mgr.Summaries()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"summaries": summaries,
	})
}

// SessionUsageStats returns per-session context/cost figures for the usage
// statistics panel: tokens, context window, model and estimated credit for
// every session that has a bound conversation.
func (h *Handler) SessionUsageStats(w http.ResponseWriter, r *http.Request) {
	sessions, err := h.mgr.List()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	type usageStat struct {
		ID           string  `json:"id"`
		Name         string  `json:"name"`
		AgentType    string  `json:"agent_type"`
		Model        string  `json:"model"`
		Tokens       int64   `json:"tokens"`
		ContextWindow int64  `json:"context_window"`
		Credit       float64 `json:"credit"`
	}

	stats := make([]usageStat, 0, len(sessions))
	for _, sess := range sessions {
		if sess.CBCSessionID == "" {
			continue
		}
		var tokens int64
		var model string
		var window int64
		var credit float64

		switch sess.AgentType {
		case "claude":
			tokens = codebuddy.GetClaudeContextTokens(sess.ProjectDir, sess.CBCSessionID)
			window = codebuddy.ContextWindowForModel("claude")
			model = "claude"
		default:
			var err error
			tokens, model, err = codebuddy.GetSessionContext(sess.CBCSessionID)
			if err != nil {
				// Session may be empty (0-byte JSONL); report it anyway.
				tokens = 0
			}
			window = codebuddy.ContextWindowForModel(model)
			credit, _ = codebuddy.GetSessionCreditUsage(sess.CBCSessionID)
		}

		stats = append(stats, usageStat{
			ID:            sess.ID,
			Name:          sess.Name,
			AgentType:     sess.AgentType,
			Model:         model,
			Tokens:        tokens,
			ContextWindow: window,
			Credit:        credit,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"stats": stats,
	})
}

func (h *Handler) CreateSession(w http.ResponseWriter, r *http.Request) {
	var req session.CreateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	sess, err := h.mgr.Create(req)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// A new session may create agent conversation files; drop cached
	// find-session results so the new session is picked up immediately.
	codebuddy.ClearFindSessionCache()

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"session": sess,
	})
}

func (h *Handler) GetSession(w http.ResponseWriter, r *http.Request) {
	id := extractID(r.URL.Path, "/api/sessions/")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	sess, err := h.mgr.Get(id)
	if err != nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"session": sess,
	})
}

func (h *Handler) DeleteSession(w http.ResponseWriter, r *http.Request) {
	id := extractID(r.URL.Path, "/api/sessions/")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	if err := h.mgr.Delete(id); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// Deleted sessions may remove agent conversation files; drop cached
	// find-session results so they don't point at a removed conversation.
	codebuddy.ClearFindSessionCache()

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

func (h *Handler) RenameSession(w http.ResponseWriter, r *http.Request) {
	id := extractIDFromPath(r.URL.Path, "rename")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	var req session.RenameRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	sess, err := h.mgr.Rename(id, req.Name)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, sess)
}

// UpdateSession applies optional field updates to a session record. Only
// stopped sessions can be edited (a running terminal has a live project dir
// that must not be changed underneath it).
func (h *Handler) UpdateSession(w http.ResponseWriter, r *http.Request) {
	id := extractIDFromPath(r.URL.Path, "edit")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	sess, err := h.mgr.Get(id)
	if err != nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	if sess.Status == session.StatusRunning {
		writeError(w, http.StatusBadRequest, "stop the session before editing")
		return
	}

	var req session.UpdateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.Name == nil && req.ProjectDir == nil && req.CBCSessionID == nil {
		writeError(w, http.StatusBadRequest, "nothing to update")
		return
	}

	updated, err := h.mgr.Update(id, req)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// Project dir changes move the JSONL lookup location; drop cached
	// find-session results so they don't point at the old path.
	codebuddy.ClearFindSessionCache()

	writeJSON(w, http.StatusOK, updated)
}

func (h *Handler) RestoreAll(w http.ResponseWriter, r *http.Request) {
	sessions, err := h.mgr.RestoreAll()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"restored": len(sessions),
		"sessions": sessions,
	})
}

func extractID(path, prefix string) string {
	trimmed := strings.TrimPrefix(path, prefix)
	parts := strings.Split(trimmed, "/")
	if len(parts) > 0 && parts[0] != "" {
		return parts[0]
	}
	return ""
}

func extractIDFromPath(path, action string) string {
	parts := strings.Split(strings.TrimPrefix(path, "/api/sessions/"), "/")
	if len(parts) >= 2 && parts[len(parts)-1] == action {
		return parts[0]
	}
	return ""
}

// AgentFindSession looks up the most recent conversation for an agent
// ("codebuddy" | "claude") in a project directory.
func (h *Handler) AgentFindSession(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Agent      string   `json:"agent"`
		ProjectDir string   `json:"project_dir"`
		After      *float64 `json:"after"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.ProjectDir == "" || body.Agent == "" {
		writeError(w, http.StatusBadRequest, "invalid agent/project_dir")
		return
	}
	// `after` (unix seconds, sub-second preserved) scopes the lookup to
	// conversations created no earlier than that instant, used by agent
	// detection to associate a fresh launch with its own new conversation.
	var after *time.Time
	if body.After != nil && *body.After > 0 {
		sec := int64(*body.After)
		nsec := int64((*body.After - float64(sec)) * 1e9)
		t := time.Unix(sec, nsec)
		after = &t
	}

	var sessionID string
	switch body.Agent {
	case "codebuddy":
		if after != nil {
			sessionID = codebuddy.FindRecentSessionForProjectAfter(body.ProjectDir, *after)
		} else {
			sessionID = codebuddy.FindRecentSessionForProject(body.ProjectDir)
		}
	case "claude":
		if after != nil {
			sessionID = codebuddy.FindRecentClaudeSessionAfter(body.ProjectDir, *after)
		} else {
			sessionID = codebuddy.FindRecentClaudeSession(body.ProjectDir)
		}
	default:
		writeError(w, http.StatusBadRequest, "unknown agent")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"session_id": sessionID,
	})
}

// AgentSessionValid reports whether a session ID belongs to the given agent.
// Only codebuddy currently supports validation.
func (h *Handler) AgentSessionValid(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/api/agent/session-valid/")
	parts := strings.SplitN(rest, "/", 2)
	agent := parts[0]
	id := ""
	if len(parts) > 1 {
		id = parts[1]
	}
	valid := false
	if agent == "codebuddy" {
		if info, err := codebuddy.GetSessionByID(id); err == nil {
			valid = info.HasAssistant
		}
	}
	if agent == "claude" {
		// A claude conversation is valid when its JSONL exists under
		// ~/.claude/projects. Without this, ClaudeProvider would validate a
		// claude ID against the codebuddy store, get false, and silently
		// drop a perfectly good binding on restart.
		valid = codebuddy.ClaudeSessionFileExists(id)
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"valid": valid})
}

// AgentRecentCwd returns the last working directory recorded in the agent's
// conversation — where the agent most recently reported working (it can cd
// between turns, independent of the process's own cwd).
func (h *Handler) AgentRecentCwd(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Agent      string `json:"agent"`
		ProjectDir string `json:"project_dir"`
		SessionID  string `json:"session_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil ||
		body.Agent == "" || body.ProjectDir == "" || body.SessionID == "" {
		writeError(w, http.StatusBadRequest, "invalid agent/project_dir/session_id")
		return
	}
	cwd := codebuddy.RecentSessionCwd(body.Agent, body.ProjectDir, body.SessionID)
	writeJSON(w, http.StatusOK, map[string]interface{}{"cwd": cwd})
}

// ListAgentConversations returns every conversation JSONL for an agent
// (filesystem-level, independent of lmux session records), optionally
// filtered to one project directory. Used by the Agent browser.
//
// Conversations already bound to an lmux session are excluded (resuming those
// from the Agent list would duplicate the lmux session); `hidden` reports how
// many were removed.
func (h *Handler) ListAgentConversations(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	convs, err := codebuddy.ListConversations(q.Get("agent"), q.Get("project_dir"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	bound := make(map[string]bool)
	if summaries, err := h.mgr.Summaries(); err == nil {
		for _, s := range summaries {
			if s.CBCSessionID != "" {
				bound[s.CBCSessionID] = true
			}
		}
	}

	visible, hidden := codebuddy.FilterBoundConversations(convs, bound)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"conversations": visible,
		"hidden":        hidden,
	})
}

// AgentConversationPreview returns the recent readable user/assistant
// messages of one conversation for the Agent browser's preview pane.
func (h *Handler) AgentConversationPreview(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Agent     string `json:"agent"`
		SessionID string `json:"session_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil ||
		body.Agent == "" || body.SessionID == "" {
		writeError(w, http.StatusBadRequest, "invalid agent/session_id")
		return
	}
	rows := codebuddy.PreviewConversation(body.Agent, body.SessionID)
	if rows == nil {
		writeError(w, http.StatusNotFound, "conversation file not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"rows": rows})
}

// FindCodebuddySessionByProject looks up the most recent codebuddy session ID
// for a project directory by scanning JSONL files.
func (h *Handler) FindCodebuddySessionByProject(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ProjectDir string `json:"project_dir"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.ProjectDir == "" {
		writeError(w, http.StatusBadRequest, "invalid project_dir")
		return
	}

	sessionID := codebuddy.FindRecentSessionForProject(body.ProjectDir)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"session_id": sessionID,
	})
}

// FindClaudeSessionByProject looks up the most recent claude conversation ID
// for a project directory.
func (h *Handler) FindClaudeSessionByProject(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ProjectDir string `json:"project_dir"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.ProjectDir == "" {
		writeError(w, http.StatusBadRequest, "invalid project_dir")
		return
	}

	sessionID := codebuddy.FindRecentClaudeSession(body.ProjectDir)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"session_id": sessionID,
	})
}

// CodebuddySessionStatus reports whether a codebuddy session ID is a real
// conversation (has at least one assistant reply). Used to detect stale
// session IDs persisted earlier and re-scan for the right one.
func (h *Handler) CodebuddySessionStatus(w http.ResponseWriter, r *http.Request) {
	id := extractID(r.URL.Path, "/api/codebuddy/session/")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}
	info, err := codebuddy.GetSessionByID(id)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"valid": err == nil && info.HasAssistant,
	})
}

// AgentContext returns context usage for any agent. codebuddy uses its JSONL
// usage records; claude's context size is estimated from message text.
func (h *Handler) AgentContext(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Agent      string `json:"agent"`
		ProjectDir string `json:"project_dir"`
		SessionID  string `json:"session_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Agent == "" || body.SessionID == "" {
		writeError(w, http.StatusBadRequest, "invalid agent/session_id")
		return
	}

	switch body.Agent {
	case "codebuddy":
		tokens, model, _ := codebuddy.GetSessionContext(body.SessionID)
		window := codebuddy.ContextWindowForModel(model)
		credit, _ := codebuddy.GetSessionCreditUsage(body.SessionID)
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"tokens":         tokens,
			"context_window": window,
			"credit":         credit,
			"model":          model,
		})
	case "claude":
		tokens := codebuddy.GetClaudeContextTokens(body.ProjectDir, body.SessionID)
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"tokens":         tokens,
			"context_window": codebuddy.ContextWindowTokens, // claude maps to deepseek-v4-flash
			"credit":         0,
			"model":          "claude",
		})
	default:
		writeError(w, http.StatusBadRequest, "unknown agent")
	}
}

// CodebuddyContext returns the current conversation context size (accumulated
// input tokens) for a codebuddy session, the model in use, that model's
// context window, and the estimated credit spent on the session.
func (h *Handler) CodebuddyContext(w http.ResponseWriter, r *http.Request) {
	id := extractID(r.URL.Path, "/api/codebuddy/context/")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}
	tokens, model, err := codebuddy.GetSessionContext(id)
	window := codebuddy.ContextWindowForModel(model)
	credit, _ := codebuddy.GetSessionCreditUsage(id)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"tokens":         0,
			"model":          model,
			"context_window": window,
			"credit":         credit,
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"tokens":         tokens,
		"model":          model,
		"context_window": window,
		"credit":         credit,
	})
}

// SetCBCSessionID updates the codebuddy session ID on a session record.
func (h *Handler) SetCBCSessionID(w http.ResponseWriter, r *http.Request) {
	id := extractID(r.URL.Path, "/api/sessions/")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	var body struct {
		CBCSessionID string `json:"cbc_session_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.CBCSessionID == "" {
		writeError(w, http.StatusBadRequest, "missing cbc_session_id")
		return
	}

	if err := h.mgr.SetCBCSessionID(id, body.CBCSessionID); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

// PinSession toggles the pinned (starred) flag that keeps a session at the
// top of the sidebar.
func (h *Handler) PinSession(w http.ResponseWriter, r *http.Request) {
	id := extractIDFromPath(r.URL.Path, "pin")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	var body struct {
		Pinned *bool `json:"pinned"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Pinned == nil {
		writeError(w, http.StatusBadRequest, "missing pinned")
		return
	}

	sess, err := h.mgr.SetPinned(id, *body.Pinned)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, sess)
}

// sessionFileFor resolves the JSONL path for a session's conversation.
func sessionFileFor(agentType, projectDir, cbcSessionID string) string {
	if agentType == "claude" {
		return codebuddy.ClaudeSessionFile(projectDir, cbcSessionID)
	}
	return codebuddy.CodebuddySessionFile(projectDir, cbcSessionID)
}

// ExportSession returns a self-contained export bundle for a session's
// conversation, including the agent type, project directory, conversation ID,
// and the full raw JSONL conversation content.
//
// The optional `since` query param (byte offset) enables incremental export:
// only the JSONL bytes after `since` are returned in `content`, and the
// response carries the new total `offset` (current file size). The sync layer
// uses this to transfer only the appended lines of a growing conversation.
func (h *Handler) ExportSession(w http.ResponseWriter, r *http.Request) {
	id := extractID(r.URL.Path, "/api/sessions/")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}

	sess, err := h.mgr.Get(id)
	if err != nil {
		writeError(w, http.StatusNotFound, "session not found")
		return
	}
	if sess.CBCSessionID == "" {
		writeError(w, http.StatusBadRequest, "session has no conversation to export")
		return
	}

	path := sessionFileFor(sess.AgentType, sess.ProjectDir, sess.CBCSessionID)
	f, err := os.Open(path)
	if err != nil {
		writeError(w, http.StatusNotFound, "conversation file not found")
		return
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	total := info.Size()

	var since int64
	if sinceStr := r.URL.Query().Get("since"); sinceStr != "" {
		if parsed, err := strconv.ParseInt(sinceStr, 10, 64); err == nil && parsed >= 0 {
			since = parsed
		}
	}
	// Clamp: a since offset larger than the file means no new content.
	if since > total {
		since = total
	}

	// Read only the appended portion after `since`.
	buf := make([]byte, total-since)
	if len(buf) > 0 {
		if _, err := f.ReadAt(buf, since); err != nil && err != io.EOF {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"format":              "lmux-session",
		"version":             1,
		"name":                sess.Name,
		"agent_type":          sess.AgentType,
		"project_dir":         sess.ProjectDir,
		"cwd":                 codebuddy.RecentSessionCwd(sess.AgentType, sess.ProjectDir, sess.CBCSessionID),
		"cbc_session_id":      sess.CBCSessionID,
		"exported_at":         time.Now().Format(time.RFC3339),
		"content":             string(buf),
		"offset":              total,
		"content_modified_at": info.ModTime().Unix(),
	})
}

// ImportSession imports an exported conversation bundle. It writes the JSONL
// into the target project's session directory and creates (or updates) the
// lmux session record bound to it.
//
// conflict_mode controls what happens when a session for the same
// cbc_session_id already exists (either as a DB record or an on-disk JSONL):
//   - "" (default): report the conflict with HTTP 409 so the client can ask.
//   - "overwrite": replace the existing conversation file and session record.
//   - "new": rewrite the conversation with a fresh conversation ID and always
//     create a new independent session.
func (h *Handler) ImportSession(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name        string `json:"name"`
		AgentType   string `json:"agent_type"`
		ProjectDir  string `json:"project_dir"`
		CBCSessionID string `json:"cbc_session_id"`
		Content     string `json:"content"`
		ConflictMode string `json:"conflict_mode"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if body.ProjectDir == "" || body.Content == "" || body.CBCSessionID == "" {
		writeError(w, http.StatusBadRequest, "project_dir, cbc_session_id and content are required")
		return
	}
	if body.AgentType == "" {
		body.AgentType = "codebuddy"
	}

	absDir, err := filepath.Abs(body.ProjectDir)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid project_dir")
		return
	}

	// Conflict: a DB record bound to the same conversation, or the target
	// JSONL file already on disk.
	existing, dbErr := h.mgr.FindByCBCSessionID(body.CBCSessionID)
	targetPath := sessionFileFor(body.AgentType, absDir, body.CBCSessionID)
	fileExists := false
	if _, err := os.Stat(targetPath); err == nil {
		fileExists = true
	}
	conflict := (dbErr == nil && existing != nil) || fileExists

	switch body.ConflictMode {
	case "":
		if conflict {
			writeJSON(w, http.StatusConflict, map[string]interface{}{
				"error":    "conflict",
				"conflict": true,
			})
			return
		}
	case "overwrite", "new":
		// explicit mode, proceed below
	default:
		writeError(w, http.StatusBadRequest, "invalid conflict_mode")
		return
	}

	writeContent := body.Content
	sessionID := body.CBCSessionID
	if body.ConflictMode == "new" {
		sessionID = uuid.New().String()
		writeContent = codebuddy.RewriteSessionID(body.Content, sessionID)
		targetPath = sessionFileFor(body.AgentType, absDir, sessionID)
	}

	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		writeError(w, http.StatusInternalServerError, "create session directory: "+err.Error())
		return
	}
	if err := os.WriteFile(targetPath, []byte(writeContent), 0o644); err != nil {
		writeError(w, http.StatusInternalServerError, "write conversation: "+err.Error())
		return
	}

	// Reuse the existing record on overwrite; otherwise create a new one.
	var sess *session.Session
	if body.ConflictMode == "overwrite" && existing != nil {
		existing.Name = body.Name
		existing.ProjectDir = absDir
		existing.AgentType = body.AgentType
		if err := h.mgr.Save(existing); err != nil {
			writeError(w, http.StatusInternalServerError, "update session: "+err.Error())
			return
		}
		sess = existing
	} else {
		sess, err = h.mgr.Create(session.CreateRequest{
			ProjectDir:   absDir,
			Name:         body.Name,
			CBCSessionID: sessionID,
			AgentType:    body.AgentType,
		})
		if err != nil {
			writeError(w, http.StatusInternalServerError, "create session: "+err.Error())
			return
		}
	}

	codebuddy.InvalidateCache()
	codebuddy.ClearFindSessionCache()

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"session": sess,
	})
}
