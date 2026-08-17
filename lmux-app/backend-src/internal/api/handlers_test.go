package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"lmux/cbsm/internal/codebuddy"
	"lmux/cbsm/internal/session"
)

func newTestHandler(t *testing.T) *Handler {
	t.Helper()
	store, err := session.NewStore(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	return NewHandler(session.NewManager(store))
}

// ensureProjDir creates the project directory used by these tests (Create
// validates the directory exists).
func ensureProjDir(t *testing.T) {
	t.Helper()
	if err := os.MkdirAll("/tmp/proj", 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestCreateListRenameDeleteSessions(t *testing.T) {
	ensureProjDir(t)
	h := newTestHandler(t)

	// Create
	body := `{"project_dir":"/tmp/proj","name":"s1","agent_type":"codebuddy"}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.CreateSession(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("CreateSession status = %d, want %d: %s", w.Code, http.StatusCreated, w.Body.String())
	}
	var created struct {
		Session struct {
			ID string `json:"id"`
		} `json:"session"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil || created.Session.ID == "" {
		t.Fatalf("CreateSession response invalid: %v", w.Body.String())
	}
	id := created.Session.ID

	// List
	req = httptest.NewRequest(http.MethodGet, "/api/sessions", nil)
	w = httptest.NewRecorder()
	h.ListSessions(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("ListSessions status = %d", w.Code)
	}
	var list struct {
		Summaries []session.Summary `json:"summaries"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil || len(list.Summaries) != 1 {
		t.Fatalf("ListSessions = %v", w.Body.String())
	}

	// Rename
	req = httptest.NewRequest(http.MethodPut, "/api/sessions/"+id+"/rename", strings.NewReader(`{"name":"renamed"}`))
	w = httptest.NewRecorder()
	h.RenameSession(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("RenameSession status = %d", w.Code)
	}

	// Delete
	req = httptest.NewRequest(http.MethodDelete, "/api/sessions/"+id, nil)
	w = httptest.NewRecorder()
	h.DeleteSession(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("DeleteSession status = %d", w.Code)
	}

	// List is empty after delete
	req = httptest.NewRequest(http.MethodGet, "/api/sessions", nil)
	w = httptest.NewRecorder()
	h.ListSessions(w, req)
	var after struct {
		Summaries []session.Summary `json:"summaries"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &after)
	if len(after.Summaries) != 0 {
		t.Fatalf("expected 0 sessions after delete, got %d", len(after.Summaries))
	}
}

func TestAgentContextClaude(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	// Create a claude session file: 5 chars -> ~2 tokens.
	dir := filepath.Join(home, ".claude", "projects", "-tmp-proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "sess1.jsonl"), []byte(`{"message":{"content":"hello"}}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	h := newTestHandler(t)
	body := `{"agent":"claude","project_dir":"/tmp/proj","session_id":"sess1"}`
	req := httptest.NewRequest(http.MethodPost, "/api/agent/context", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.AgentContext(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("AgentContext status = %d: %s", w.Code, w.Body.String())
	}
	var resp struct {
		Tokens        int `json:"tokens"`
		ContextWindow int `json:"context_window"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Tokens != 2 {
		t.Errorf("claude tokens = %d, want 2", resp.Tokens)
	}
	if resp.ContextWindow != int(codebuddy.ContextWindowTokens) {
		t.Errorf("context_window = %d, want %d", resp.ContextWindow, codebuddy.ContextWindowTokens)
	}
}

func TestAgentContextRejectsEmptySessionID(t *testing.T) {
	h := newTestHandler(t)
	req := httptest.NewRequest(http.MethodPost, "/api/agent/context", strings.NewReader(`{"agent":"claude","project_dir":"/tmp"}`))
	w := httptest.NewRecorder()
	h.AgentContext(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for missing session_id, got %d", w.Code)
	}
}

func TestAgentFindSessionClaude(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".claude", "projects", "-tmp-proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "recent.jsonl"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	h := newTestHandler(t)
	req := httptest.NewRequest(http.MethodPost, "/api/agent/find-session", strings.NewReader(`{"agent":"claude","project_dir":"/tmp/proj"}`))
	w := httptest.NewRecorder()
	h.AgentFindSession(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("AgentFindSession status = %d", w.Code)
	}
	var resp struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.SessionID != "recent" {
		t.Errorf("find-session = %q, want %q", resp.SessionID, "recent")
	}
}

func TestExportSession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ensureProjDir(t)
	h := newTestHandler(t)

	// Create a session bound to a conversation.
	body := `{"project_dir":"/tmp/proj","name":"s1","agent_type":"codebuddy","cbc_session_id":"conv1"}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.CreateSession(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("CreateSession status = %d", w.Code)
	}
	var created struct {
		Session struct {
			ID string `json:"id"`
		} `json:"session"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	id := created.Session.ID

	// Write the conversation JSONL into the codebuddy projects dir.
	projDir := filepath.Join(home, ".codebuddy", "projects", "tmp-proj")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatal(err)
	}
	conv := `{"sessionId":"conv1","type":"user"}` + "\n"
	if err := os.WriteFile(filepath.Join(projDir, "conv1.jsonl"), []byte(conv), 0o644); err != nil {
		t.Fatal(err)
	}

	req = httptest.NewRequest(http.MethodGet, "/api/sessions/"+id+"/export", nil)
	w = httptest.NewRecorder()
	h.ExportSession(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("ExportSession status = %d: %s", w.Code, w.Body.String())
	}
	var resp struct {
		Format       string `json:"format"`
		Version      int    `json:"version"`
		Name         string `json:"name"`
		AgentType    string `json:"agent_type"`
		ProjectDir   string `json:"project_dir"`
		CBCSessionID string `json:"cbc_session_id"`
		Content      string `json:"content"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Format != "lmux-session" || resp.Version != 1 {
		t.Errorf("format/version = %q/%d, want lmux-session/1", resp.Format, resp.Version)
	}
	if resp.CBCSessionID != "conv1" || resp.Content != conv {
		t.Errorf("export content mismatch: cbc=%q content=%q", resp.CBCSessionID, resp.Content)
	}
}

func TestExportSessionNoConversation(t *testing.T) {
	ensureProjDir(t)
	h := newTestHandler(t)
	body := `{"project_dir":"/tmp/proj","name":"s1","agent_type":"codebuddy"}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.CreateSession(w, req)
	var created struct {
		Session struct {
			ID string `json:"id"`
		} `json:"session"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &created)

	req = httptest.NewRequest(http.MethodGet, "/api/sessions/"+created.Session.ID+"/export", nil)
	w = httptest.NewRecorder()
	h.ExportSession(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("ExportSession (no conversation) status = %d, want 400", w.Code)
	}
}

func TestImportSession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ensureProjDir(t)
	h := newTestHandler(t)

	importBody := `{"name":"imp","agent_type":"codebuddy","project_dir":"/tmp/proj","cbc_session_id":"conv1","content":"{\"sessionId\":\"conv1\",\"type\":\"user\"}\n"}`

	// First import: no conflict.
	req := httptest.NewRequest(http.MethodPost, "/api/sessions/import", strings.NewReader(importBody))
	w := httptest.NewRecorder()
	h.ImportSession(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("ImportSession status = %d: %s", w.Code, w.Body.String())
	}
	filePath := filepath.Join(home, ".codebuddy", "projects", "tmp-proj", "conv1.jsonl")
	if _, err := os.Stat(filePath); err != nil {
		t.Fatalf("imported file not written: %v", err)
	}

	// Second import: same conversation → conflict.
	req = httptest.NewRequest(http.MethodPost, "/api/sessions/import", strings.NewReader(importBody))
	w = httptest.NewRecorder()
	h.ImportSession(w, req)
	if w.Code != http.StatusConflict {
		t.Fatalf("ImportSession conflict status = %d, want 409", w.Code)
	}

	// Overwrite mode: succeeds and reuses the existing record.
	req = httptest.NewRequest(http.MethodPost, "/api/sessions/import", strings.NewReader(`{"name":"imp2","agent_type":"codebuddy","project_dir":"/tmp/proj","cbc_session_id":"conv1","content":"x","conflict_mode":"overwrite"}`))
	w = httptest.NewRecorder()
	h.ImportSession(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("ImportSession overwrite status = %d: %s", w.Code, w.Body.String())
	}

	// New-copy mode: rewrites the session id and always creates a new record.
	req = httptest.NewRequest(http.MethodPost, "/api/sessions/import", strings.NewReader(`{"name":"imp3","agent_type":"codebuddy","project_dir":"/tmp/proj","cbc_session_id":"conv1","content":"{\"sessionId\":\"conv1\",\"type\":\"user\"}\n","conflict_mode":"new"}`))
	w = httptest.NewRecorder()
	h.ImportSession(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("ImportSession new status = %d: %s", w.Code, w.Body.String())
	}
	var newSess struct {
		Session struct {
			CBCSessionID string `json:"cbc_session_id"`
		} `json:"session"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &newSess); err != nil {
		t.Fatal(err)
	}
	if newSess.Session.CBCSessionID == "conv1" {
		t.Errorf("new-copy import kept original cbc_session_id")
	}
	// The new conversation file was written and old content rewritten.
	newFile := filepath.Join(home, ".codebuddy", "projects", "tmp-proj", newSess.Session.CBCSessionID+".jsonl")
	if _, err := os.Stat(newFile); err != nil {
		t.Fatalf("new-copy file not written: %v", err)
	}
}

func TestUpdateSession(t *testing.T) {
	ensureProjDir(t)
	h := newTestHandler(t)

	// Create a stopped session.
	body := `{"project_dir":"/tmp/proj","name":"old","agent_type":"codebuddy","cbc_session_id":"c1"}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.CreateSession(w, req)
	var created struct {
		Session struct {
			ID string `json:"id"`
		} `json:"session"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &created)
	id := created.Session.ID

	// Update name + project_dir + cbc_session_id together.
	req = httptest.NewRequest(http.MethodPost, "/api/sessions/"+id+"/edit",
		strings.NewReader(`{"name":"new","project_dir":"/tmp/proj","cbc_session_id":"c2"}`))
	w = httptest.NewRecorder()
	h.UpdateSession(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("UpdateSession status = %d: %s", w.Code, w.Body.String())
	}
	var updated struct {
		Name         string `json:"name"`
		ProjectDir   string `json:"project_dir"`
		CBCSessionID string `json:"cbc_session_id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Name != "new" || updated.ProjectDir != "/tmp/proj" || updated.CBCSessionID != "c2" {
		t.Errorf("updated session = %+v", updated)
	}

	// Update to a nonexistent directory → error.
	req = httptest.NewRequest(http.MethodPost, "/api/sessions/"+id+"/edit",
		strings.NewReader(`{"project_dir":"/tmp/does-not-exist-xyz"}`))
	w = httptest.NewRecorder()
	h.UpdateSession(w, req)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("UpdateSession nonexistent dir status = %d, want 500", w.Code)
	}

	// Empty body → bad request.
	req = httptest.NewRequest(http.MethodPost, "/api/sessions/"+id+"/edit", strings.NewReader(`{}`))
	w = httptest.NewRecorder()
	h.UpdateSession(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("UpdateSession empty body status = %d, want 400", w.Code)
	}
}

func TestUpdateSessionRejectsRunning(t *testing.T) {
	ensureProjDir(t)
	h := newTestHandler(t)

	// Create a session and mark it running directly in the store.
	body := `{"project_dir":"/tmp/proj","name":"s","agent_type":"codebuddy"}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.CreateSession(w, req)
	var created struct {
		Session struct {
			ID string `json:"id"`
		} `json:"session"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &created)
	id := created.Session.ID
	if err := h.mgr.UpdateStatus(id, session.StatusRunning, 999); err != nil {
		t.Fatal(err)
	}

	req = httptest.NewRequest(http.MethodPost, "/api/sessions/"+id+"/edit",
		strings.NewReader(`{"name":"x"}`))
	w = httptest.NewRecorder()
	h.UpdateSession(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("UpdateSession running status = %d, want 400", w.Code)
	}
}
