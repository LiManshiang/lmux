package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/manshiangli/cbsm/internal/api"
	"github.com/manshiangli/cbsm/internal/config"
	"github.com/manshiangli/cbsm/internal/session"
)

func main() {
	cfgPath := flag.String("config", config.DefaultConfigPath(), "Path to config file")
	restore := flag.Bool("restore", false, "Restore all historical CodeBuddy sessions on startup")
	flag.Parse()

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	store, err := session.NewStore(session.DefaultDBPath())
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer store.Close()

	mgr := session.NewManager(store)
	server := api.NewServer(cfg, mgr)

	// Print token IMMEDIATELY
	fmt.Printf("LMUX_TOKEN=%s\n", server.Token())
	fmt.Printf("LMUX_ADDR=%s\n", server.Addr())

	// Handle graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		os.Exit(0)
	}()

	// Start HTTP server FIRST (non-blocking goroutine), restore concurrently
	go func() {
		if *restore {
			log.Println("[lmux] Restoring historical sessions...")
			sessions, err := mgr.RestoreAll()
			if err != nil {
				log.Printf("[lmux] Restore error: %v", err)
			} else {
				log.Printf("[lmux] Restored %d sessions", len(sessions))
			}
		}
	}()

	log.Printf("[lmux] Starting CodeBuddy Session Manager...")
	if err := server.Start(); err != nil {
		log.Fatalf("[lmux] Server error: %v", err)
	}
}
