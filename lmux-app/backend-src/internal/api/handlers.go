package api

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/manshiangli/cbsm/internal/codebuddy"
	"github.com/manshiangli/cbsm/internal/session"
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

// CodebuddyContext returns the current conversation context size (accumulated
// input tokens) for a codebuddy session, the model in use, and that model's
// context window.
func (h *Handler) CodebuddyContext(w http.ResponseWriter, r *http.Request) {
	id := extractID(r.URL.Path, "/api/codebuddy/context/")
	if id == "" {
		writeError(w, http.StatusBadRequest, "missing session id")
		return
	}
	tokens, model, err := codebuddy.GetSessionContext(id)
	window := codebuddy.ContextWindowForModel(model)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"tokens":         0,
			"model":          model,
			"context_window": window,
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"tokens":         tokens,
		"model":          model,
		"context_window": window,
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
