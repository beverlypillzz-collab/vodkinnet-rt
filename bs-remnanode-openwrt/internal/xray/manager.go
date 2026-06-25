package xray

import (
	"encoding/json"
	"log"
	"os"
	"os/exec"
	"sync"

	"github.com/beverlypillzz-collab/Vodkinnet-RT/bs-remnanode-openwrt/internal/config"
)

type Manager struct {
	cfg     *config.Config
	mu      sync.Mutex
	cmd     *exec.Cmd
	running bool
}

func NewManager(cfg *config.Config) *Manager {
	return &Manager{cfg: cfg}
}

// Start or restart xray with a new config JSON
func (m *Manager) Start(configJSON json.RawMessage) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Stop existing process
	if m.cmd != nil && m.running {
		log.Println("[xray] stopping previous process")
		_ = m.cmd.Process.Kill()
		_ = m.cmd.Wait()
		m.running = false
	}

	// Write config to disk
	if err := os.MkdirAll("/etc/bs-remnanode", 0755); err != nil {
		return err
	}
	if err := os.WriteFile(m.cfg.XrayConfig, configJSON, 0644); err != nil {
		return err
	}

	log.Printf("[xray] starting %s with config %s", m.cfg.XrayBin, m.cfg.XrayConfig)

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
