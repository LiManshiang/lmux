.PHONY: build run test install-launchagent clean

GOPROXY ?= https://goproxy.cn,direct
BINARY = bin/lmux

build:
	GOPROXY=$(GOPROXY) go build -o $(BINARY) ./cmd/cbsm

run: build
	$(BINARY) --restore

test:
	GOPROXY=$(GOPROXY) go test ./...

install:
	mkdir -p $(HOME)/.local/bin
	cp $(BINARY) $(HOME)/.local/bin/lmux

install-launchagent:
	mkdir -p $(HOME)/Library/LaunchAgents
	cp com.lmux.daemon.plist $(HOME)/Library/LaunchAgents/
	launchctl load $(HOME)/Library/LaunchAgents/com.lmux.daemon.plist

uninstall-launchagent:
	launchctl unload $(HOME)/Library/LaunchAgents/com.lmux.daemon.plist || true
	rm -f $(HOME)/Library/LaunchAgents/com.lmux.daemon.plist

clean:
	rm -rf bin/
	rm -rf $(HOME)/.lmux/sessions.db $(HOME)/.lmux/config.json
