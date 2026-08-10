package api

import (
	"fmt"
	"log"
	"net/http"

	"github.com/manshiangli/cbsm/internal/config"
	"github.com/manshiangli/cbsm/internal/session"
)

type Server struct {
	cfg    *config.Config
	mgr    *session.Manager
	server *http.Server
}

func NewServer(cfg *config.Config, mgr *session.Manager) *Server {
	return &Server{cfg: cfg, mgr: mgr}
}

func (s *Server) Start() error {
	mux := http.NewServeMux()
	h := NewHandler(s.mgr)

	mux.HandleFunc("/api/health", corsMiddleware(h.Health))

	mux.HandleFunc("/api/sessions", s.auth(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			h.ListSessions(w, r)
		case http.MethodPost:
			h.CreateSession(w, r)
		default:
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/api/sessions/", s.auth(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if id := extractIDFromPath(path, "rename"); id != "" && r.Method == http.MethodPost {
			h.RenameSession(w, r)
			return
		}
		if id := extractIDFromPath(path, "cbc-session"); id != "" && r.Method == http.MethodPost {
			h.SetCBCSessionID(w, r)
			return
		}
		switch r.Method {
		case http.MethodGet:
			h.GetSession(w, r)
		case http.MethodDelete:
			h.DeleteSession(w, r)
		default:
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/api/restore", s.auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			h.RestoreAll(w, r)
		} else {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/api/codebuddy/find-session", s.auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			h.FindCodebuddySessionByProject(w, r)
		} else {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/api/claude/find-session", s.auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			h.FindClaudeSessionByProject(w, r)
		} else {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/api/agent/find-session", s.auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			h.AgentFindSession(w, r)
		} else {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/api/agent/context", s.auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			h.AgentContext(w, r)
		} else {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/api/agent/session-valid/", s.auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			h.AgentSessionValid(w, r)
		} else {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/api/codebuddy/session/", s.auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			h.CodebuddySessionStatus(w, r)
		} else {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))
	mux.HandleFunc("/api/codebuddy/context/", s.auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			h.CodebuddyContext(w, r)
		} else {
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	}))

	addr := fmt.Sprintf("127.0.0.1:%d", s.cfg.Port)
	s.server = &http.Server{Addr: addr, Handler: mux}

	log.Printf("[lmux] API server listening on %s (token: %s...)", addr, s.cfg.Token[:8])
	return s.server.ListenAndServe()
}

func (s *Server) Addr() string { return fmt.Sprintf("127.0.0.1:%d", s.cfg.Port) }
func (s *Server) Token() string { return s.cfg.Token }

func (s *Server) auth(handler http.HandlerFunc) http.HandlerFunc {
	return corsMiddleware(tokenAuth(s.cfg.Token, handler))
}
