package codebuddy

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
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
