package api

import (
	"context"
	"crypto/subtle"
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

const (
	maxBodySize = 5 << 20 // 5 MB
)

type Server struct {
	cfg  *config.Config
	xm   *xray.Manager
	http *http.Server
}

func NewServer(cfg *config.Config, xm *xray.Manager) *Server {
	s := &Server{cfg: cfg, xm: xm}
	mux := http.NewServeMux()

	mux.HandleFunc("/", s.auth(s.notFound))
	mux.HandleFunc("GET /api/node/health", s.auth(s.handleHealth))
	mux.HandleFunc("GET /api/node/info", s.auth(s.handleInfo))
	mux.HandleFunc("POST /api/node/start", s.auth(s.handleStart))
	mux.HandleFunc("POST /api/node/stop", s.auth(s.handleStop))
	mux.HandleFunc("POST /api/node/restart", s.auth(s.handleRestart))

	s.http = &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.NodePort),
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
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

// auth uses constant-time comparison to prevent timing attacks
func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("Authorization")
		expected := "Bearer " + s.cfg.SecretKey
		// ConstantTimeCompare prevents timing-based token guessing
		if subtle.ConstantTimeCompare([]byte(token), []byte(expected)) != 1 {
			s.json(w, http.StatusUnauthorized, map[string]string{
				"error": "unauthorized",
			})
			return
		}
		next(w, r)
	}
}

// --- Handlers ---

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.json(w, http.StatusOK, map[string]interface{}{
		"status": "ok",
		"xray":   s.xm.IsRunning(),
	})
}

func (s *Server) handleInfo(w http.ResponseWriter, r *http.Request) {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	s.json(w, http.StatusOK, map[string]interface{}{
		"version":     "bs-remnanode/1.0.0",
		"xrayRunning": s.xm.IsRunning(),
		"os":          runtime.GOOS,
		"arch":        runtime.GOARCH,
		"memUsed":     m.Alloc,
		"uptime":      time.Now().Unix(),
	})
}

func (s *Server) handleStart(w http.ResponseWriter, r *http.Request) {
	// Limit request body to prevent OOM on router
	r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)

	var body struct {
		Config json.RawMessage `json:"config"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		s.json(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if body.Config == nil {
		s.json(w, http.StatusBadRequest, map[string]string{"error": "config is required"})
		return
	}

	if err := s.xm.Start(body.Config); err != nil {
		log.Printf("[api] failed to start xray: %v", err)
		// Don't expose internal error details to caller
		s.json(w, http.StatusInternalServerError, map[string]string{"error": "failed to start xray"})
		return
	}

	s.json(w, http.StatusOK, map[string]string{"status": "started"})
}

func (s *Server) handleStop(w http.ResponseWriter, r *http.Request) {
	s.xm.Stop()
	s.json(w, http.StatusOK, map[string]string{"status": "stopped"})
}

func (s *Server) handleRestart(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)

	var body struct {
		Config json.RawMessage `json:"config"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)

	if body.Config != nil {
		if err := s.xm.Start(body.Config); err != nil {
			log.Printf("[api] restart failed: %v", err)
			s.json(w, http.StatusInternalServerError, map[string]string{"error": "failed to restart xray"})
			return
		}
	} else {
		s.xm.Stop()
		cfg, err := readExistingConfig(s.cfg.XrayConfig)
		if err != nil {
			s.json(w, http.StatusInternalServerError, map[string]string{"error": "no config available"})
			return
		}
		if err := s.xm.Start(cfg); err != nil {
			s.json(w, http.StatusInternalServerError, map[string]string{"error": "failed to restart xray"})
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
