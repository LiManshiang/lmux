package codebuddy

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// CompactionBase returns the byte offset in a conversation's JSONL at which its
// live history begins — the start of the last compaction boundary record, or 0
// when the conversation has never been compacted.
//
// /compact, and the automatic compaction that runs when the context fills up,
// leave the file append-only: nothing is removed, a summary record and then a
// user message carrying <conversation_history_summary> are written at the end.
// The CLI resolves a conversation's real history by slicing from that last
// boundary, both while compacting and every time it assembles a model request:
//
//	filterBeforeCompactedMessage(ei){for(let ea=ei.length-1;ea>=0;ea--)if(isCompactBoundaryMessage(ei[ea]))return ei.slice(ea);return ei}
//	[Compact:PreMessage] session.history trimmed in-place: ${eu} -> ${history.length}
//
// Everything before the boundary is dead weight the CLI will not read again —
// measured here, 79% of one 83 MB conversation. A sync copy can start there
// instead of at byte zero.
//
// The predicate mirrors the CLI's isCompactBoundaryMessage, with one deliberate
// omission noted below. Mirroring it is the whole point: a cut EARLIER than the
// CLI's keeps records the model still reads, which wastes space but is harmless,
// while a cut LATER than the CLI's drops context. Every uncertain case therefore
// falls back to 0 — no trimming — rather than to a guess.
//
// A read error is reported with a zero base for the same reason: the caller
// keeps the whole conversation.
func CompactionBase(agent, path string) (int64, error) {
	// Only codebuddy writes the marker; a claude conversation has no base.
	if agent != "codebuddy" {
		return 0, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()

	// ReadBytes rather than a Scanner: one record can inline megabytes of tool
	// output, far past a Scanner's token limit. A record boundary is the only
	// place a JSONL line can be split safely.
	rd := bufio.NewReaderSize(f, 64<<10)
	var offset, base int64
	for {
		line, err := rd.ReadBytes('\n')
		if len(line) > 0 {
			if trimmed := bytes.TrimSpace(line); mayBeBoundary(trimmed) && isCompactionBoundary(trimmed) {
				base = offset
			}
			offset += int64(len(line))
		}
		if err != nil {
			if err == io.EOF {
				return base, nil
			}
			return 0, err
		}
	}
}

// boundaryProbe is the slice of a record that decides whether it is a
// compaction boundary. Nothing else in the record is decoded — a tool result
// can be megabytes of output that this scan has no use for.
type boundaryProbe struct {
	Type         string `json:"type"`
	Role         string `json:"role"`
	ProviderData struct {
		IsCompacted         bool   `json:"isCompacted"`
		IsSummary           bool   `json:"isSummary"`
		IsCompactInternal   bool   `json:"isCompactInternal"`
		IsPtlRecovery       bool   `json:"isPtlRecovery"`
		IsMediaBodyRecovery bool   `json:"isMediaBodyRecovery"`
		CompactType         string `json:"compactType"`
		Agent               string `json:"agent"`
	} `json:"providerData"`
}

// isCompactionBoundary mirrors the CLI's HistoryUtils.isCompactBoundaryMessage.
//
// Deliberately not implemented: the CLI's third alternative also treats a user
// message whose text contains <cb_summary, <conversation_history_summary or
// data-role="compact-summary" as a boundary. Recognising those would mean
// decoding message bodies on every user record, and missing them only ever
// leaves more history in place — the harmless direction. Their real shape is
// covered anyway: both compaction paths set isCompacted and isSummary alongside
// compactType (verified against codebuddy.js, and against every boundary record
// in this machine's conversations).
func isCompactionBoundary(line []byte) bool {
	var rec boundaryProbe
	if json.Unmarshal(line, &rec) != nil {
		return false
	}
	if rec.Type != "message" || rec.Role != "user" {
		return false
	}
	pd := rec.ProviderData
	// Point-in-time recoveries re-send an earlier message; they are not
	// boundaries even when they carry the same flags.
	if pd.IsPtlRecovery || pd.IsMediaBodyRecovery {
		return false
	}
	if pd.IsCompacted || pd.IsSummary {
		return true
	}
	// "compact" is the agent name of the compaction pseudo-agent; its own
	// records are the compaction, not a message the user sent a boundary for.
	return !pd.IsCompactInternal && pd.Agent != "compact" && pd.CompactType != ""
}

// boundaryMarkers are substrings any boundary record must contain. Parsing every
// line of an 83 MB file is what would make this scan expensive; these gates are
// a single IndexByte pass each and reject almost everything.
//
// Markers are matched without anchoring to `":"` or `": "` because the CLI
// writes both spacings in the same file.
var boundaryMarkers = [][]byte{
	[]byte("compact"),
	[]byte("isSummary"),
	[]byte("conversation_history_summary"),
	[]byte("cb_summary"),
}

func mayBeBoundary(line []byte) bool {
	if len(line) == 0 || line[0] != '{' {
		return false
	}
	for _, marker := range boundaryMarkers {
		if bytes.Contains(line, marker) {
			return true
		}
	}
	return false
}

// PruneOutcome reports what a prune did.
type PruneOutcome struct {
	// Pruned is false when there was nothing to do — the conversation has never
	// been compacted, or already starts at its boundary. Not an error: it is the
	// normal answer for most conversations.
	Pruned bool
	// Base is the offset the removed prefix ended at, now the file's start.
	Base int64
	// RemovedBytes is how much was discarded; Size is what remains.
	RemovedBytes int64
	Size         int64
}

// ErrConversationInUse reports that a live agent holds the conversation, so
// rewriting it under the process's feet is refused.
var ErrConversationInUse = fmt.Errorf("a running agent still has this conversation open; stop it first")

// PruneToCompactionBase rewrites a conversation so that it starts at its last
// compaction boundary, discarding everything before it.
//
// The discarded records are ones the CLI has already stopped reading, and
// stopped showing: HistoryUtils.filterBeforeCompactedMessage slices from that
// boundary both while compacting and on every model request, and the terminal
// trims session.history in place at the same moment. Verified end to end against
// a real CLI — a conversation rewritten this way resumes normally, answers from
// its summary, and appends as usual, while a fact that lived only in the
// discarded prefix stays unknowable in the untouched file too. So the file keeps
// its meaning and loses the weight (on this machine, 79% of an 83 MB
// conversation).
//
// Irreversible, and deliberately so — there is no backup, which is the point of
// offering it. Two guards stand in for one: a running agent is refused outright,
// and the candidate file must begin with a parseable boundary record and end
// with the same bytes as the original before it is renamed into place, so a
// wrong offset fails the check and leaves the original untouched.
//
// sessionID is only used for the running-agent check; path is the conversation
// itself, which is not always under the session's recorded project directory.
func PruneToCompactionBase(agent, path, sessionID string) (PruneOutcome, error) {
	info, err := os.Stat(path)
	if err != nil {
		return PruneOutcome{}, err
	}
	out := PruneOutcome{Size: info.Size()}

	base, err := CompactionBase(agent, path)
	if err != nil {
		return out, err
	}
	if base <= 0 || base >= info.Size() {
		return out, nil
	}
	if ConversationInUse(sessionID) {
		return out, ErrConversationInUse
	}

	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".prune-*")
	if err != nil {
		return out, err
	}
	tmpName := tmp.Name()
	keep := false
	defer func() {
		if !keep {
			os.Remove(tmpName)
		}
	}()

	src, err := os.Open(path)
	if err != nil {
		tmp.Close()
		return out, err
	}
	defer src.Close()

	if _, err := src.Seek(base, io.SeekStart); err != nil {
		tmp.Close()
		return out, err
	}
	w := bufio.NewWriterSize(tmp, 1<<20)
	if _, err := io.Copy(w, src); err != nil {
		tmp.Close()
		return out, err
	}
	if err := w.Flush(); err != nil {
		tmp.Close()
		return out, err
	}
	if err := tmp.Close(); err != nil {
		return out, err
	}

	// Everything below can still refuse. Until the rename lands, `path` is
	// exactly as it was.
	if err := verifyPruned(tmpName, path); err != nil {
		return out, err
	}
	if err := os.Chmod(tmpName, info.Mode().Perm()); err != nil {
		return out, err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return out, err
	}
	keep = true

	// The conversation list is memoised for 5s and the scanner keeps parsed
	// summaries; both now describe a file that no longer exists in that shape.
	conversationsMu.Lock()
	conversationsCache = conversationsCacheEntry{}
	conversationsMu.Unlock()
	InvalidateCache()

	out.Pruned = true
	out.Base = base
	out.RemovedBytes = base
	out.Size = info.Size() - base
	return out, nil
}

// verifyPruned checks the candidate file before it replaces the real one: it has
// to start at a parseable compaction boundary, and to end with the same bytes as
// the original. Either check failing means the cut landed somewhere other than a
// record boundary, and the caller keeps the original rather than a file that
// begins mid-record.
func verifyPruned(candidate, original string) error {
	f, err := os.Open(candidate)
	if err != nil {
		return err
	}
	first, readErr := bufio.NewReaderSize(f, 64<<10).ReadBytes('\n')
	f.Close()
	if readErr != nil && readErr != io.EOF {
		return readErr
	}
	if !isCompactionBoundary(bytes.TrimSpace(first)) {
		return fmt.Errorf("refusing to prune: the result would not start at a compaction boundary")
	}

	candTail, err := tailBytes(candidate, 64<<10)
	if err != nil {
		return err
	}
	srcTail, err := tailBytes(original, 64<<10)
	if err != nil {
		return err
	}
	// Compare the overlap. A candidate is expected to be shorter, but both reads
	// cover a whole file when it is under the window, so the comparison has to be
	// "the candidate is the original's last m bytes" rather than "these reads are
	// equal" — otherwise every short conversation fails its own prune.
	m := len(candTail)
	if len(srcTail) < m {
		m = len(srcTail)
	}
	if m == 0 || !bytes.Equal(candTail[len(candTail)-m:], srcTail[len(srcTail)-m:]) {
		return fmt.Errorf("refusing to prune: the result would not end where the conversation ends")
	}
	return nil
}

// tailBytes returns at most the last window bytes of a file — exactly the last
// window when the file is longer, and the whole file when it is shorter.
//
// Deliberately not readEdge(path, -1): that one clamps a negative offset to 0,
// so for anything under the window it returns the file from the start, and
// comparing two of those compares whole files rather than their ends. Every
// conversation smaller than the window — which is most of them — would fail the
// check below and be refused.
func tailBytes(path string, window int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	n := window
	if info.Size() < n {
		n = info.Size()
	}
	if n <= 0 {
		return nil, nil
	}
	buf := make([]byte, n)
	if _, err := f.ReadAt(buf, info.Size()-n); err != nil && err != io.EOF {
		return nil, err
	}
	return buf, nil
}
