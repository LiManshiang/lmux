package codebuddy

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// SearchOptions configures a content search across conversation histories.
type SearchOptions struct {
	Query      string
	Agent      string // "codebuddy", "claude", or "" for both
	ProjectDir string // "" scans every project directory
	All        bool   // ignore the default recency / size window
	MaxAgeDays int
	MaxConvos  int
	MaxHits    int
	Workers    int
	Timeout    time.Duration
}

const (
	searchMaxAgeDays   = 90
	searchMaxConvos    = 300
	searchMaxHits      = 200
	searchWorkers      = 8
	searchHitsPerConvo = 5
	snippetBefore      = 60  // runes kept before the match
	snippetAfter       = 90  // runes kept after the match
	ctxCheckEvery      = 512 // lines between context checks
)

// roleMarker is a cheap pre-filter: every message record carries a "role"
// field, while tool calls, reasoning and snapshots do not. Scanning for it
// avoids unmarshalling the majority of lines (tool traffic dominates real
// histories), which is what keeps a 1.6GB search near a second.
var roleMarker = []byte(`"role"`)

// SearchHit is one matching message inside a conversation.
type SearchHit struct {
	Role    string `json:"role"`
	Snippet string `json:"snippet"`
	Line    int    `json:"line"`
}

// SearchGroup collects the hits found in a single conversation.
type SearchGroup struct {
	Conversation ConversationSummary `json:"conversation"`
	Hits         []SearchHit         `json:"hits"`
}

// SearchResult is what the browser needs to render a content search.
type SearchResult struct {
	Groups        []SearchGroup `json:"results"`
	ScannedConvos int           `json:"scanned"`
	ScannedBytes  int64         `json:"scanned_bytes"`
	Truncated     bool          `json:"truncated"`
	TimedOut      bool          `json:"timed_out"`
	ElapsedMS     int64         `json:"elapsed_ms"`
}

// SearchConversations looks for Query inside the text of user/assistant
// messages across the conversation history.
//
// It deliberately does not build an index. Conversation text reaches ~1.6GB on
// a busy machine, an FTS index would cost more disk than the text itself, and a
// bounded parallel scan answers in about a second. The default window (recent
// MaxAgeDays and MaxConvos) covers what people actually search for; All lifts
// the window at the cost of a few seconds.
func SearchConversations(ctx context.Context, o SearchOptions) SearchResult {
	start := time.Now()
	res := SearchResult{Groups: []SearchGroup{}}

	query := strings.TrimSpace(o.Query)
	if query == "" {
		res.ElapsedMS = time.Since(start).Milliseconds()
		return res
	}
	if o.MaxAgeDays <= 0 {
		o.MaxAgeDays = searchMaxAgeDays
	}
	if o.MaxConvos <= 0 {
		o.MaxConvos = searchMaxConvos
	}
	if o.MaxHits <= 0 {
		o.MaxHits = searchMaxHits
	}
	if o.Workers <= 0 {
		o.Workers = searchWorkers
	}
	if o.Timeout <= 0 {
		o.Timeout = 6 * time.Second
		if o.All {
			o.Timeout = 20 * time.Second
		}
	}

	all, err := ListConversations(o.Agent, o.ProjectDir)
	if err != nil {
		res.ElapsedMS = time.Since(start).Milliseconds()
		return res
	}

	// ListConversations may hand back the slice held by its cache, so build the
	// candidate list in a fresh slice instead of filtering in place.
	candidates := make([]ConversationSummary, 0, len(all))
	if o.All {
		candidates = append(candidates, all...)
	} else {
		cutoff := time.Now().AddDate(0, 0, -o.MaxAgeDays).Unix()
		for _, c := range all {
			if c.MTime < cutoff {
				continue
			}
			if len(candidates) >= o.MaxConvos {
				break
			}
			candidates = append(candidates, c)
		}
	}

	runCtx, cancel := context.WithTimeout(ctx, o.Timeout)
	defer cancel()

	lowerQuery := strings.ToLower(query)
	lenQuery := len(lowerQuery)

	var (
		mu      sync.Mutex
		groups  []rankedGroup
		hits    int
		scanned int
		nbytes  int64
		trunc   bool
	)

	type job struct {
		index int
		conv  ConversationSummary
	}
	jobs := make(chan job)
	var wg sync.WaitGroup

	for i := 0; i < o.Workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				if runCtx.Err() != nil {
					return
				}
				hitsFound, bytesRead := searchOneFile(runCtx, j.conv, lowerQuery, lenQuery)

				mu.Lock()
				scanned++
				nbytes += bytesRead
				if len(hitsFound) > 0 {
					// Respect the global cap: take what fits, then stop handing
					// out work.
					if remaining := o.MaxHits - hits; remaining > 0 {
						if len(hitsFound) > remaining {
							hitsFound = hitsFound[:remaining]
							trunc = true
						}
						hits += len(hitsFound)
						groups = append(groups, rankedGroup{index: j.index, group: SearchGroup{
							Conversation: j.conv,
							Hits:         hitsFound,
						}})
						if hits >= o.MaxHits {
							trunc = true
						}
					} else {
						trunc = true
					}
				}
				reached := hits >= o.MaxHits
				mu.Unlock()

				if reached {
					cancel()
					return
				}
			}
		}()
	}

	for i, c := range candidates {
		select {
		case jobs <- job{index: i, conv: c}:
		case <-runCtx.Done():
		}
		if runCtx.Err() != nil {
			break
		}
	}
	close(jobs)
	wg.Wait()

	sort.Slice(groups, func(a, b int) bool { return groups[a].index < groups[b].index })
	for _, g := range groups {
		res.Groups = append(res.Groups, g.group)
	}
	res.ScannedConvos = scanned
	res.ScannedBytes = nbytes
	res.Truncated = trunc
	res.TimedOut = errors.Is(runCtx.Err(), context.DeadlineExceeded)
	res.ElapsedMS = time.Since(start).Milliseconds()
	return res
}

type rankedGroup struct {
	index int
	group SearchGroup
}

// searchOneFile scans a single conversation file, returning its hits (at most
// searchHitsPerConvo) and how many bytes were read.
//
// The file's size is captured up front so a conversation being appended to
// while we search yields a stable, complete prefix rather than a half-written
// last line.
func searchOneFile(ctx context.Context, conv ConversationSummary, lowerQuery string, lenQuery int) ([]SearchHit, int64) {
	path := conversationPath(conv.Agent, conv.FileRel)
	if path == "" {
		return nil, 0
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, 0
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		return nil, 0
	}
	limit := stat.Size()

	reader := bufio.NewReaderSize(f, 1<<20)
	var (
		hits     []SearchHit
		read     int64
		lineNo   int
		sinceChk int
	)
	for read < limit {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			read += int64(len(line))
			lineNo++

			// Cheap pre-filter: skip tool traffic, reasoning and snapshots.
			if bytes.Contains(line, roleMarker) {
				trimmed := bytes.TrimRight(line, "\r\n")
				observePreviewLine(conv.Agent, trimmed, func(role, text string) {
					if len(hits) >= searchHitsPerConvo {
						return
					}
					if snippet, ok := matchSnippet(text, lowerQuery, lenQuery); ok {
						hits = append(hits, SearchHit{Role: role, Snippet: snippet, Line: lineNo})
					}
				})
			}

			sinceChk++
			if sinceChk >= ctxCheckEvery {
				sinceChk = 0
				if ctx.Err() != nil {
					break
				}
			}
		}
		if err != nil {
			break // EOF or read error: we have the prefix we wanted
		}
	}
	return hits, read
}

// matchSnippet reports whether text contains query (case-insensitively) and
// returns a readable window around the first match.
//
// Lowercasing can change byte length for a few exotic code points (for example
// 'İ'), which would make the match offset wrong; in that case the line is
// skipped rather than risking a mangled snippet.
func matchSnippet(text, lowerQuery string, lenQuery int) (string, bool) {
	if text == "" || lenQuery == 0 {
		return "", false
	}
	lower := strings.ToLower(text)
	if len(lower) != len(text) {
		return "", false
	}
	i := strings.Index(lower, lowerQuery)
	if i < 0 {
		return "", false
	}
	return snippetAround(text, i, lenQuery, snippetBefore, snippetAfter), true
}

// snippetAround returns the match at [i, i+n) plus up to before/after runes of
// context on each side, with ellipses where the text was cut. All offsets are
// byte-based, and the window is expanded on rune boundaries so multi-byte
// characters (Chinese, emoji) are never split.
func snippetAround(s string, i, n, before, after int) string {
	start := i
	for c := 0; c < before && start > 0; c++ {
		_, size := utf8.DecodeLastRuneInString(s[:start])
		if size == 0 {
			break
		}
		start -= size
	}
	end := i + n
	if end > len(s) {
		end = len(s)
	}
	for c := 0; c < after && end < len(s); c++ {
		_, size := utf8.DecodeRuneInString(s[end:])
		if size == 0 {
			break
		}
		end += size
	}

	var b strings.Builder
	if start > 0 {
		b.WriteString("…")
	}
	b.WriteString(strings.TrimSpace(s[start:end]))
	if end < len(s) {
		b.WriteString("…")
	}
	return b.String()
}

// conversationPath resolves a conversation file from its projects-root-relative
// path (ConversationSummary.FileRel), without walking the directory tree.
func conversationPath(agent, fileRel string) string {
	if fileRel == "" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	root := filepath.Join(home, ".codebuddy", "projects")
	if agent == "claude" {
		root = filepath.Join(home, ".claude", "projects")
	}
	return filepath.Join(root, fileRel)
}
