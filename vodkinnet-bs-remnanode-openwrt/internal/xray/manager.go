package xray

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/beverlypillzz-collab/Vodkinnet-RT/bs-remnanode-openwrt/internal/config"
)

// allowedXrayPaths restricts which binaries can be used as xray
var allowedXrayPaths = []string{
	"/usr/bin/xray",
	"/usr/local/bin/xray",
	"/opt/xray/xray",
}

type Manager struct {
	cfg     *config.Config
	mu      sync.Mutex
	cmd     *exec.Cmd
	running bool
}

func NewManager(cfg *config.Config) *Manager {
	return &Manager{cfg: cfg}
}

// validateXrayBin checks that the xray binary path is in the allowed list
func validateXrayBin(path string) error {
	// Resolve any symlinks/relative paths
	clean := filepath.Clean(path)
	for _, allowed := range allowedXrayPaths {
		if clean == allowed {
			return nil
		}
	}
	// Also allow if path starts with /usr/bin/ or /usr/local/bin/
	if strings.HasPrefix(clean, "/usr/bin/") || strings.HasPrefix(clean, "/usr/local/bin/") {
		return nil
	}
	return fmt.Errorf("xray binary path %q is not in allowed list", path)
}

// Start or restart xray with a new config JSON
func (m *Manager) Start(configJSON json.RawMessage) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Validate xray binary path before executing
	if err := validateXrayBin(m.cfg.XrayBin); err != nil {
		return fmt.Errorf("invalid xray binary: %w", err)
	}

	// Stop existing process
	if m.cmd != nil && m.running {
		log.Println("[xray] stopping previous process")
		_ = m.cmd.Process.Kill()
		_ = m.cmd.Wait()
		m.running = false
	}

	// Write config to disk with restricted permissions (0600 = owner only)
	if err := os.MkdirAll("/etc/bs-remnanode", 0750); err != nil {
		return err
	}
	if err := os.WriteFile(m.cfg.XrayConfig, configJSON, 0600); err != nil {
		return err
	}

	log.Printf("[xray] starting %s", m.cfg.XrayBin)

	m.cmd = exec.Command(m.cfg.XrayBin, "run", "-config", m.cfg.XrayConfig)
	m.cmd.Stdout = os.Stdout
	m.cmd.Stderr = os.Stderr

	if err := m.cmd.Start(); err != nil {
		return err
	}
	m.running = true

	// Watch for unexpected exit
	go func() {
		err := m.cmd.Wait()
		m.mu.Lock()
		m.running = false
		m.mu.Unlock()
		if err != nil {
			log.Printf("[xray] exited with error: %v", err)
		} else {
			log.Println("[xray] exited cleanly")
		}
	}()

	log.Printf("[xray] started, pid=%d", m.cmd.Process.Pid)
	return nil
}

func (m *Manager) Stop() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cmd != nil && m.running {
		_ = m.cmd.Process.Kill()
		_ = m.cmd.Wait()
		m.running = false
		log.Println("[xray] stopped")
	}
}

func (m *Manager) IsRunning() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.running
}
