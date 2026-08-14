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
