package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
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

func TestExportSessionIncremental(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ensureProjDir(t)
	h := newTestHandler(t)

	body := `{"project_dir":"/tmp/proj","name":"s1","agent_type":"codebuddy","cbc_session_id":"conv1"}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.CreateSession(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("CreateSession status = %d", w.Code)
	}
	sessionID := idOf(w)

	projDir := filepath.Join(home, ".codebuddy", "projects", "tmp-proj")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatal(err)
	}
	line1 := `{"sessionId":"conv1","type":"user"}` + "\n"
	convPath := filepath.Join(projDir, "conv1.jsonl")
	if err := os.WriteFile(convPath, []byte(line1), 0o644); err != nil {
		t.Fatal(err)
	}

	// Full export (since=0): returns all content and the new offset.
	req = httptest.NewRequest(http.MethodGet, "/api/sessions/"+sessionID+"/export", nil)
	w = httptest.NewRecorder()
	h.ExportSession(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("ExportSession full status = %d", w.Code)
	}
	var full struct {
		Content string `json:"content"`
		Offset  int64  `json:"offset"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &full)
	if full.Content != line1 {
		t.Errorf("full content = %q, want %q", full.Content, line1)
	}
	offset := full.Offset
	if offset <= 0 {
		t.Fatalf("offset = %d, want > 0", offset)
	}

	// Append a second line, then export with since=<offset>.
	line2 := `{"sessionId":"conv1","type":"assistant"}` + "\n"
	if err := os.WriteFile(convPath, []byte(line1+line2), 0o644); err != nil {
		t.Fatal(err)
	}
	req = httptest.NewRequest(http.MethodGet, "/api/sessions/"+sessionID+"/export?since="+strconv.FormatInt(offset, 10), nil)
	w = httptest.NewRecorder()
	h.ExportSession(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("ExportSession incremental status = %d", w.Code)
	}
	var inc struct {
		Content string `json:"content"`
		Offset  int64  `json:"offset"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &inc)
	if inc.Content != line2 {
		t.Errorf("incremental content = %q, want %q", inc.Content, line2)
	}
	if inc.Offset != int64(len(line1)+len(line2)) {
		t.Errorf("incremental offset = %d, want %d", inc.Offset, len(line1)+len(line2))
	}

	// since beyond EOF: empty content, offset clamped to file size.
	req = httptest.NewRequest(http.MethodGet, "/api/sessions/"+sessionID+"/export?since=999999", nil)
	w = httptest.NewRecorder()
	h.ExportSession(w, req)
	_ = json.Unmarshal(w.Body.Bytes(), &inc)
	if inc.Content != "" {
		t.Errorf("clamped content = %q, want empty", inc.Content)
	}
	if inc.Offset != int64(len(line1)+len(line2)) {
		t.Errorf("clamped offset = %d, want file size", inc.Offset)
	}
}

// idOf extracts the session id from a CreateSession response recorder body.
func idOf(w *httptest.ResponseRecorder) string {
	var created struct {
		Session struct {
			ID string `json:"id"`
		} `json:"session"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &created)
	return created.Session.ID
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

func TestImportSessionRewritesCwd(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ensureProjDir(t)
	h := newTestHandler(t)

	// A bundle from another machine carries the source machine's cwd; the
	// CLI matches resumable conversations by that recorded cwd, so the
	// import must localize it to the target project dir.
	importBody := `{"name":"imp","agent_type":"codebuddy","project_dir":"/tmp/proj","cbc_session_id":"conv2","content":"{\"sessionId\":\"conv2\",\"type\":\"user\",\"cwd\":\"/Users/someone-else\"}\n{\"sessionId\":\"conv2\",\"type\":\"message\",\"role\":\"assistant\",\"cwd\":\"/Volumes/Elsewhere\"}\n"}`

	req := httptest.NewRequest(http.MethodPost, "/api/sessions/import", strings.NewReader(importBody))
	w := httptest.NewRecorder()
	h.ImportSession(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("ImportSession status = %d: %s", w.Code, w.Body.String())
	}

	got, err := os.ReadFile(filepath.Join(home, ".codebuddy", "projects", "tmp-proj", "conv2.jsonl"))
	if err != nil {
		t.Fatalf("imported file not written: %v", err)
	}
	if strings.Contains(string(got), "/Users/someone-else") || strings.Contains(string(got), "/Volumes/Elsewhere") {
		t.Errorf("imported content still carries foreign cwd: %s", got)
	}
	if !strings.Contains(string(got), `"cwd":"/tmp/proj"`) {
		t.Errorf("imported content missing localized cwd: %s", got)
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

func TestPinSession(t *testing.T) {
	ensureProjDir(t)
	h := newTestHandler(t)

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

	// Pin.
	req = httptest.NewRequest(http.MethodPost, "/api/sessions/"+id+"/pin", strings.NewReader(`{"pinned":true}`))
	w = httptest.NewRecorder()
	h.PinSession(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("PinSession status = %d: %s", w.Code, w.Body.String())
	}
	var sess struct {
		Pinned bool `json:"pinned"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &sess)
	if !sess.Pinned {
		t.Errorf("expected pinned=true after pin")
	}

	// Unpin.
	req = httptest.NewRequest(http.MethodPost, "/api/sessions/"+id+"/pin", strings.NewReader(`{"pinned":false}`))
	w = httptest.NewRecorder()
	h.PinSession(w, req)
	_ = json.Unmarshal(w.Body.Bytes(), &sess)
	if sess.Pinned {
		t.Errorf("expected pinned=false after unpin")
	}

	// Missing pinned → bad request.
	req = httptest.NewRequest(http.MethodPost, "/api/sessions/"+id+"/pin", strings.NewReader(`{}`))
	w = httptest.NewRecorder()
	h.PinSession(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("PinSession missing pinned status = %d, want 400", w.Code)
	}
}

func TestSessionUsageStats(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ensureProjDir(t)
	h := newTestHandler(t)

	// Session bound to a codebuddy conversation with usage records.
	body := `{"project_dir":"/tmp/proj","name":"s1","agent_type":"codebuddy","cbc_session_id":"u1"}`
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.CreateSession(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("CreateSession status = %d", w.Code)
	}

	// Write usage-bearing JSONL: 1000 input tokens, 200 output, deepseek model.
	projDir := filepath.Join(home, ".codebuddy", "projects", "tmp-proj")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatal(err)
	}
	conv := `{"sessionId":"u1","type":"message","providerData":{"model":"deepseek-v4-flash"},"message":{"usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":0}}}` + "\n"
	if err := os.WriteFile(filepath.Join(projDir, "u1.jsonl"), []byte(conv), 0o644); err != nil {
		t.Fatal(err)
	}

	req = httptest.NewRequest(http.MethodGet, "/api/sessions/usage", nil)
	w = httptest.NewRecorder()
	h.SessionUsageStats(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("SessionUsageStats status = %d", w.Code)
	}
	var resp struct {
		Stats []struct {
			ID            string  `json:"id"`
			Tokens        int64   `json:"tokens"`
			ContextWindow int64   `json:"context_window"`
			Model         string  `json:"model"`
			Credit        float64 `json:"credit"`
		} `json:"stats"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Stats) != 1 {
		t.Fatalf("expected 1 stat, got %d: %s", len(resp.Stats), w.Body.String())
	}
	if resp.Stats[0].Tokens != 1000 {
		t.Errorf("tokens = %d, want 1000", resp.Stats[0].Tokens)
	}
	if resp.Stats[0].ContextWindow != codebuddy.ContextWindowForModel("deepseek-v4-flash") {
		t.Errorf("context_window = %d", resp.Stats[0].ContextWindow)
	}
	if resp.Stats[0].Model != "deepseek-v4-flash" {
		t.Errorf("model = %q", resp.Stats[0].Model)
	}
}

// --- LocalizeSessionCwd ---

func TestLocalizeSessionCwd(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ensureProjDir(t)
	h := newTestHandler(t)

	sess, err := h.mgr.Create(session.CreateRequest{
		ProjectDir:   "/tmp/proj",
		Name:         "localize-me",
		CBCSessionID: "conv9",
		AgentType:    "codebuddy",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	// Conversation history from another machine: its recorded cwd no longer
	// exists here, which is exactly what makes the CLI start an empty session.
	dir := filepath.Join(home, ".codebuddy", "projects", "tmp-proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "conv9.jsonl")
	body := `{"sessionId":"conv9","type":"message","role":"user","cwd":"/Users/someone-else"}` + "\n" +
		`{"sessionId":"conv9","type":"message","role":"assistant","cwd":"/Users/someone-else","content":"hi"}` + "\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	h.LocalizeSessionCwd(w, httptest.NewRequest(http.MethodPost, "/api/sessions/"+sess.ID+"/localize-cwd", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), `"updated":true`) {
		t.Errorf("expected updated=true, got %s", w.Body.String())
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(got), "/Users/someone-else") {
		t.Errorf("foreign cwd still present: %s", got)
	}
	if !strings.Contains(string(got), `"cwd":"/tmp/proj"`) {
		t.Errorf("cwd not rewritten to project dir: %s", got)
	}
	// Non-cwd fields must survive untouched.
	if !strings.Contains(string(got), `"content":"hi"`) || !strings.Contains(string(got), `"sessionId":"conv9"`) {
		t.Errorf("unrelated fields changed: %s", got)
	}

	// Idempotent: a second call reports no change.
	w2 := httptest.NewRecorder()
	h.LocalizeSessionCwd(w2, httptest.NewRequest(http.MethodPost, "/api/sessions/"+sess.ID+"/localize-cwd", nil))
	if strings.Contains(w2.Body.String(), `"updated":true`) {
		t.Errorf("second call should be a no-op, got %s", w2.Body.String())
	}
}

func TestLocalizeSessionCwdSkipsRunningAndUnbound(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ensureProjDir(t)
	h := newTestHandler(t)

	// No conversation bound -> nothing to do, but not an error.
	plain, err := h.mgr.Create(session.CreateRequest{ProjectDir: "/tmp/proj", Name: "plain"})
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	h.LocalizeSessionCwd(w, httptest.NewRequest(http.MethodPost, "/api/sessions/"+plain.ID+"/localize-cwd", nil))
	if w.Code != http.StatusOK || strings.Contains(w.Body.String(), `"updated":true`) {
		t.Errorf("unbound session: code=%d body=%s", w.Code, w.Body.String())
	}

	// Running sessions must not be touched (the agent is appending to the file).
	running, err := h.mgr.Create(session.CreateRequest{
		ProjectDir: "/tmp/proj", Name: "running", CBCSessionID: "conv10", AgentType: "codebuddy",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := h.mgr.UpdateStatus(running.ID, session.StatusRunning, 1234); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(home, ".codebuddy", "projects", "tmp-proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "conv10.jsonl")
	original := `{"sessionId":"conv10","type":"message","role":"user","cwd":"/Users/someone-else"}` + "\n"
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}

	w2 := httptest.NewRecorder()
	h.LocalizeSessionCwd(w2, httptest.NewRequest(http.MethodPost, "/api/sessions/"+running.ID+"/localize-cwd", nil))
	if strings.Contains(w2.Body.String(), `"updated":true`) {
		t.Errorf("running session must be skipped, got %s", w2.Body.String())
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != original {
		t.Errorf("running session's file was modified: %s", after)
	}
}
