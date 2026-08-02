.PHONY: build run test install-launchagent clean

GOPROXY ?= https://goproxy.cn,direct
BINARY = bin/cbsm

build:
	GOPROXY=$(GOPROXY) go build -o $(BINARY) ./cmd/cbsm

run: build
	$(BINARY) --restore

test:
	GOPROXY=$(GOPROXY) go test ./...

install:
	mkdir -p $(HOME)/.local/bin
	cp $(BINARY) $(HOME)/.local/bin/cbsm

install-launchagent:
	mkdir -p $(HOME)/Library/LaunchAgents
	cp com.cbsm.daemon.plist $(HOME)/Library/LaunchAgents/
	launchctl load $(HOME)/Library/LaunchAgents/com.cbsm.daemon.plist

uninstall-launchagent:
	launchctl unload $(HOME)/Library/LaunchAgents/com.cbsm.daemon.plist || true
	rm -f $(HOME)/Library/LaunchAgents/com.cbsm.daemon.plist

clean:
	rm -rf bin/
	rm -rf $(HOME)/.cbsm/sessions.db $(HOME)/.cbsm/config.json
