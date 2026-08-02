.PHONY: build run clean app icon backend

BINARY = .build/debug/lmux
APP_NAME = lmux.app
APP_DIR = .build/$(APP_NAME)
INFO_PLIST = Info.plist
ICONSET = Resources/lmux.iconset
ICNS = Resources/lmux.icns
BACKEND_SRC = backend-src
BACKEND_BIN = backend/lmux

# Build Go backend
backend:
	cd $(BACKEND_SRC) && GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm
	@echo "Backend built: $(BACKEND_BIN)"

# Build Swift frontend
build:
	swift build --skip-update

# Build everything
app: backend build
	@echo "Creating .app bundle..."
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@cp $(BINARY) $(APP_DIR)/Contents/MacOS/lmux
	@cp $(BACKEND_BIN) $(APP_DIR)/Contents/MacOS/lmux-backend
	@cp $(INFO_PLIST) $(APP_DIR)/Contents/Info.plist
	@cp lmux.entitlements $(APP_DIR)/Contents/Resources/
	@if [ -f "$(ICNS)" ]; then cp $(ICNS) $(APP_DIR)/Contents/Resources/AppIcon.icns; fi
	@chmod +x $(APP_DIR)/Contents/MacOS/lmux
	@chmod +x $(APP_DIR)/Contents/MacOS/lmux-backend
	@codesign --force --deep --sign - $(APP_DIR) 2>/dev/null || true
	@echo "App bundle created: $(APP_DIR)"
	@echo "Run: open $(APP_DIR)"

run: app
	open $(APP_DIR)

clean:
	rm -rf .build/
	rm -f $(BACKEND_BIN)
