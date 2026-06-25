package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/beverlypillzz-collab/Vodkinnet-RT/bs-remnanode-openwrt/internal/api"
	"github.com/beverlypillzz-collab/Vodkinnet-RT/bs-remnanode-openwrt/internal/config"
	"github.com/beverlypillzz-collab/Vodkinnet-RT/bs-remnanode-openwrt/internal/xray"
)

func main() {
	cfg := config.Load()

	log.Printf("[bs-remnanode] starting, NODE_PORT=%d", cfg.NodePort)

	xm := xray.NewManager(cfg)

	srv := api.NewServer(cfg, xm)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		if err := srv.Start(); err != nil {
			log.Fatalf("[bs-remnanode] server error: %v", err)
		}
	}()

	log.Printf("[bs-remnanode] listening on :%d", cfg.NodePort)

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("[bs-remnanode] shutting down...")
	cancel()
	xm.Stop()
	srv.Shutdown(ctx)
}
