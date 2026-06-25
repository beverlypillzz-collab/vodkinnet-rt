package config

import (
	"log"
	"os"
	"strconv"
)

type Config struct {
	NodePort    int
	SecretKey   string
	XtlsApiPort int
	XrayBin     string
	XrayConfig  string
}

func Load() *Config {
	cfg := &Config{
		NodePort:    2222,
		SecretKey:   "",
		XtlsApiPort: 61000,
		XrayBin:     "/usr/bin/xray",
		XrayConfig:  "/etc/bs-remnanode/xray.json",
	}

	if v := os.Getenv("NODE_PORT"); v != "" {
		if p, err := strconv.Atoi(v); err == nil {
			cfg.NodePort = p
		}
	}

	if v := os.Getenv("SECRET_KEY"); v != "" {
		cfg.SecretKey = v
	} else {
		log.Fatal("[config] SECRET_KEY is required")
	}

	if v := os.Getenv("XTLS_API_PORT"); v != "" {
		if p, err := strconv.Atoi(v); err == nil {
			cfg.XtlsApiPort = p
		}
	}

	if v := os.Getenv("XRAY_BIN"); v != "" {
		cfg.XrayBin = v
	}

	if v := os.Getenv("XRAY_CONFIG"); v != "" {
		cfg.XrayConfig = v
	}

	return cfg
}
