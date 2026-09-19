package session

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"lmux/cbsm/internal/codebuddy"
)

// newTestManager builds a manager over its own database, with HOME pointed at a
// throwaway directory so the agent-conversation files a test writes are the only
// ones the rules can see.
func newTestManager(t *testing.T) (*Manager, string) {
	t.Helper()
	// HOME must not live under /var/folders: the directory rules under test
	// treat paths there as transient scratch space, which would make every work
	// directory a test creates invisible to them. /tmp only matches when it is
	// the whole path, so subdirectories of it work.
	home := filepath.Join("/tmp", "lmux-session-test-"+
		strings.ReplaceAll(t.Name(), "/", "_")+"-"+fmt.Sprint(time.Now().UnixNano()))
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(home) })
	t.Setenv("HOME", home)
	db, err := sql.Open("sqlite3", filepath.Join(t.TempDir(), "sessions.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := migrate(db); err != nil {
		t.Fatal(err)
	}
	return NewManager(&Store{db: db}), home
}

// writeAgentConversation writes a conversation whose records are Bash calls that
// cd into cdDir and carry the given timestamps — the input the directory rules
// read out of the agent's own history.
func writeAgentConversation(t *testing.T, home, projectDir, id, cdDir string, stamps []int64) {
	t.Helper()
	folder := filepath.Dir(codebuddy.AgentSessionFile("codebuddy", projectDir, id))
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	var lines []string
	for _, ts := range stamps {
		lines = append(lines, fmt.Sprintf(
			`{"sessionId":%q,"type":"function_call","name":"Bash","cwd":%q,"timestamp":%d,`+
				`"arguments":"{\"command\": \"cd %s && ls\"}"}`,
			id, projectDir, ts, cdDir))
	}
	if err := os.WriteFile(filepath.Join(folder, id+".jsonl"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustDir(t *testing.T, path string) string {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestAdoptWorkDirTakesTheFirstDirectoryWorkedIn(t *testing.T) {
	mgr, home := newTestManager(t)
	a := mustDir(t, filepath.Join(home, "work", "a"))
	b := mustDir(t, filepath.Join(home, "work", "b"))

	sess, err := mgr.Create(CreateRequest{ProjectDir: a, Name: "adopt", CBCSessionID: "conv", AgentType: "codebuddy"})
	if err != nil {
		t.Fatal(err)
	}

	// The agent's first cd happened after the session was created: this session
	// went to work in b, so b is its directory.
	writeAgentConversation(t, home, a, "conv", b,
		[]int64{time.Now().Add(30 * time.Second).UnixMilli(), time.Now().Add(time.Minute).UnixMilli()})
	if _, adopted, err := mgr.AdoptWorkDir(sess.ID); err != nil || !adopted {
		t.Fatalf("AdoptWorkDir adopted=%v err=%v, want adopted", adopted, err)
	}
	got, err := mgr.Get(sess.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.ProjectDir != b {
		t.Errorf("project dir = %q, want %q", got.ProjectDir, b)
	}
	if got.DirByHand {
		t.Error("an adopted directory is not a hand-made choice")
	}

	// Adopting again is a no-op: the first cd is already the answer.
	if _, adopted, _ := mgr.AdoptWorkDir(sess.ID); adopted {
		t.Error("a second adoption should change nothing")
	}
}

func TestAdoptWorkDirIgnoresACdOlderThanTheSession(t *testing.T) {
	mgr, home := newTestManager(t)
	a := mustDir(t, filepath.Join(home, "work", "a"))
	b := mustDir(t, filepath.Join(home, "work", "b"))

	// The conversation was bound to this session long after it was written, and
	// its oldest cd belongs to that earlier life.
	sess, err := mgr.Create(CreateRequest{ProjectDir: a, Name: "imported", CBCSessionID: "conv", AgentType: "codebuddy"})
	if err != nil {
		t.Fatal(err)
	}
	writeAgentConversation(t, home, a, "conv", b,
		[]int64{time.Now().Add(-time.Hour).UnixMilli()})
	if _, adopted, err := mgr.AdoptWorkDir(sess.ID); err != nil || adopted {
		t.Fatalf("adopted=%v err=%v, want no adoption for a cd older than the session", adopted, err)
	}
	got, _ := mgr.Get(sess.ID)
	if got.ProjectDir != a {
		t.Errorf("project dir moved to %q; a cd older than the session must not move it", got.ProjectDir)
	}
}

func TestAdoptWorkDirStopsOnceADirectoryIsChosenByHand(t *testing.T) {
	mgr, home := newTestManager(t)
	a := mustDir(t, filepath.Join(home, "work", "a"))
	b := mustDir(t, filepath.Join(home, "work", "b"))
	c := mustDir(t, filepath.Join(home, "work", "c"))

	sess, err := mgr.Create(CreateRequest{ProjectDir: a, Name: "hand", CBCSessionID: "conv", AgentType: "codebuddy"})
	if err != nil {
		t.Fatal(err)
	}
	// The conversation exists under every directory, so the only thing that can
	// stop the adoption is the hand-made choice itself.
	for _, d := range []string{a, b, c} {
		writeAgentConversation(t, home, d, "conv", b, []int64{time.Now().Add(time.Minute).UnixMilli()})
	}
	if _, err := mgr.Update(sess.ID, UpdateRequest{ProjectDir: &c}); err != nil {
		t.Fatal(err)
	}
	if _, adopted, _ := mgr.AdoptWorkDir(sess.ID); adopted {
		t.Error("a directory chosen by hand was overwritten by the agent's cd")
	}
	got, _ := mgr.Get(sess.ID)
	if got.ProjectDir != c || !got.DirByHand {
		t.Errorf("project dir = %q dirByHand = %v, want %q true", got.ProjectDir, got.DirByHand, c)
	}
}

func TestFollowConversationRebindsAndSaves(t *testing.T) {
	mgr, home := newTestManager(t)
	a := mustDir(t, filepath.Join(home, "work", "a"))

	sess, err := mgr.Create(CreateRequest{ProjectDir: a, Name: "cleared", CBCSessionID: "old", AgentType: "codebuddy"})
	if err != nil {
		t.Fatal(err)
	}
	// /clear: the old conversation stops and the new one begins immediately.
	at := time.Now()
	writeAgentConversation(t, home, a, "old", a, []int64{at.Add(-time.Minute).UnixMilli(), at.UnixMilli()})
	writeAgentConversation(t, home, a, "new", a, []int64{at.Add(29 * time.Millisecond).UnixMilli()})

	if _, followed, err := mgr.FollowConversation(sess.ID); err != nil || !followed {
		t.Fatalf("followed=%v err=%v, want followed", followed, err)
	}
	got, _ := mgr.Get(sess.ID)
	if got.CBCSessionID != "new" {
		t.Errorf("binding = %q, want the successor %q", got.CBCSessionID, "new")
	}

	// Following again changes nothing: the successor is already the live one.
	if _, followed, _ := mgr.FollowConversation(sess.ID); followed {
		t.Error("a second follow should change nothing")
	}

	// A conversation that is still the live one has nothing to follow.
	sess2, err := mgr.Create(CreateRequest{ProjectDir: a, Name: "live", CBCSessionID: "new", AgentType: "codebuddy"})
	if err != nil {
		t.Fatal(err)
	}
	if _, followed, _ := mgr.FollowConversation(sess2.ID); followed {
		t.Error("a conversation with no successor was followed")
	}
}

func TestStoreRoundTripsDirByHand(t *testing.T) {
	store, err := NewStore(filepath.Join(t.TempDir(), "sessions.db"))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	sess, err := NewManager(store).Create(CreateRequest{ProjectDir: dir, Name: "flag"})
	if err != nil {
		t.Fatal(err)
	}
	if sess.DirByHand {
		t.Error("a fresh session must not be marked as hand-set")
	}
	if _, err := NewManager(store).Update(sess.ID, UpdateRequest{ProjectDir: &dir}); err != nil {
		t.Fatal(err)
	}
	got, err := store.Get(sess.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !got.DirByHand {
		t.Error("a directory set through Update must be recorded as hand-made")
	}
}
