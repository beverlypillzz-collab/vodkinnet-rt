package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"

	"github.com/beverlypillzz-collab/Vodkinnet-RT/bs-remnanode-openwrt/internal/config"
	"github.com/beverlypillzz-collab/Vodkinnet-RT/bs-remnanode-openwrt/internal/xray"
)

type Server struct {
	cfg  *config.Config
	xm   *xray.Manager
	http *http.Server
}

func NewServer(cfg *config.Config, xm *xray.Manager) *Server {
	s := &Server{cfg: cfg, xm: xm}
	mux := http.NewServeMux()

	// Auth middleware applied to all routes
	mux.HandleFunc("/", s.auth(s.notFound))

	// node-contract endpoints
	mux.HandleFunc("GET /api/node/health", s.auth(s.handleHealth))
	mux.HandleFunc("GET /api/node/info", s.auth(s.handleInfo))
	mux.HandleFunc("POST /api/node/start", s.auth(s.handleStart))
	mux.HandleFunc("POST /api/node/stop", s.auth(s.handleStop))
	mux.HandleFunc("POST /api/node/restart", s.auth(s.handleRestart))

	s.http = &http.Server{
		Addr:    fmt.Sprintf(":%d", cfg.NodePort),
		Handler: mux,
	}
	return s
}

func (s *Server) Start() error {
	return s.http.ListenAndServe()
}

func (s *Server) Shutdown(ctx context.Context) {
	_ = s.http.Shutdown(ctx)
}

// --- Middleware ---

func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("Authorization")
		expected := "Bearer " + s.cfg.SecretKey
		if token != expected {
			s.json(w, http.StatusUnauthorized, map[string]string{
				"error": "unauthorized",
			})
			return
		}
		next(w, r)
	}
}

// --- Handlers ---

// GET /api/node/health
// Panel polls this to check node liveness
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.json(w, http.StatusOK, map[string]interface{}{
		"status": "ok",
		"xray":   s.xm.IsRunning(),
	})
}

// GET /api/node/info
// Panel fetches node metadata
func (s *Server) handleInfo(w http.ResponseWriter, r *http.Request) {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	s.json(w, http.StatusOK, map[string]interface{}{
		"version":   "bs-remnanode/1.0.0",
		"xrayRunning": s.xm.IsRunning(),
		"os":        runtime.GOOS,
		"arch":      runtime.GOARCH,
		"memUsed":   m.Alloc,
		"uptime":    time.Now().Unix(),
	})
}

// POST /api/node/start
// Body: {"config": <xray json config>}
// Panel sends xray config and expects node to start xray with it
func (s *Server) handleStart(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Config json.RawMessage `json:"config"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		s.json(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if body.Config == nil {
		s.json(w, http.StatusBadRequest, map[string]string{"error": "config is required"})
		return
	}

	if err := s.xm.Start(body.Config); err != nil {
		log.Printf("[api] failed to start xray: %v", err)
		s.json(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	s.json(w, http.StatusOK, map[string]string{"status": "started"})
}

// POST /api/node/stop
func (s *Server) handleStop(w http.ResponseWriter, r *http.Request) {
	s.xm.Stop()
	s.json(w, http.StatusOK, map[string]string{"status": "stopped"})
}

// POST /api/node/restart
// Body: {"config": <xray json config>}  (optional — reuse existing if absent)
func (s *Server) handleRestart(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Config json.RawMessage `json:"config"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)

	if body.Config != nil {
		if err := s.xm.Start(body.Config); err != nil {
			log.Printf("[api] restart failed: %v", err)
			s.json(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
	} else {
		// Restart with existing config file
		s.xm.Stop()
		// Read existing config
		import_cfg, err := readExistingConfig(s.cfg.XrayConfig)
		if err != nil {
			s.json(w, http.StatusInternalServerError, map[string]string{"error": "no config available: " + err.Error()})
			return
		}
		if err := s.xm.Start(import_cfg); err != nil {
			s.json(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
	}

	s.json(w, http.StatusOK, map[string]string{"status": "restarted"})
}

func (s *Server) notFound(w http.ResponseWriter, r *http.Request) {
	s.json(w, http.StatusNotFound, map[string]string{"error": "not found"})
}

// --- Helpers ---

func (s *Server) json(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func readExistingConfig(path string) (json.RawMessage, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(data), nil
}
