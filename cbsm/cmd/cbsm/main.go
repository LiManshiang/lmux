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

	// load config
	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	// set up database
	store, err := session.NewStore(session.DefaultDBPath())
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer store.Close()

	mgr := session.NewManager(store)

	// restore historical sessions if requested
	if *restore {
		log.Println("[cbsm] Restoring historical sessions...")
		sessions, err := mgr.RestoreAll()
		if err != nil {
			log.Printf("[cbsm] Restore error: %v", err)
		} else {
			log.Printf("[cbsm] Restored %d sessions", len(sessions))
		}
	}

	// start API server
	server := api.NewServer(cfg, mgr)

	// print token info for the GUI app to consume
	fmt.Printf("CBSM_TOKEN=%s\n", server.Token())
	fmt.Printf("CBSM_ADDR=%s\n", server.Addr())

	// handle graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		log.Printf("[cbsm] Received signal %v, shutting down...", sig)
		os.Exit(0)
	}()

	log.Printf("[cbsm] Starting CodeBuddy Session Manager...")
	if err := server.Start(); err != nil {
		log.Fatalf("[cbsm] Server error: %v", err)
	}
}
