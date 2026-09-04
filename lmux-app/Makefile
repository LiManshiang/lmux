.PHONY: build run clean app icon backend app-x86 build-x86 app-st build-st

BINARY = .build/debug/lmux
APP_NAME = lmux.app
APP_DIR = .build/$(APP_NAME)
INFO_PLIST = Info.plist
ICON_PNG = Resources/lmux-icon.png
ICONSET_BUILD = .build/lmux.iconset
BACKEND_SRC = backend-src
BACKEND_BIN = backend/lmux
# x86_64 (Intel) cross-compiled Swift frontend binary.
BINARY_X86 = .build/x86_64-apple-macosx/debug/lmux

# --- macOS 12 compatibility ------------------------------------------------
# This branch (swiftterm) targets macOS 12 (LSMinimumSystemVersion 12.0).
# Pin the deployment target explicitly so an API newer than macOS 12 is a
# compile error, no matter which SDK/toolchain is in use.
MACOS_MIN_TARGET = -Xswiftc -target -Xswiftc $(HOST_ARCH)-apple-macosx12.0
X86_12_TARGET = -Xswiftc -target -Xswiftc x86_64-apple-macosx12.0
HOST_ARCH ?= $(shell uname -m)
# SwiftTerm variant naming: separate bundle + icon so master and swiftterm
# builds never collide.
ST_APP_NAME = lmux-st.app
ST_ICON_PNG = Resources/lmux-icon-st.png

# Build Go backend
backend:
	cd $(BACKEND_SRC) && GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm
	@echo "Backend built: $(BACKEND_BIN)"

# Build Swift frontend (macOS 12 deployment target enforced).
build:
	swift build --skip-update $(MACOS_MIN_TARGET)

# Build everything. The backend build is best-effort: if the Go toolchain is
# unavailable, an existing backend binary is reused.
app: build
	@echo "Creating .app bundle..."
	@cd $(BACKEND_SRC) && GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm 2>/dev/null \
		&& echo "Backend built: $(BACKEND_BIN)" \
		|| echo "WARN: go unavailable, reusing existing backend binary"
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@cp $(BINARY) $(APP_DIR)/Contents/MacOS/lmux
	@cp $(BACKEND_BIN) $(APP_DIR)/Contents/MacOS/lmux-backend
	@cp $(INFO_PLIST) $(APP_DIR)/Contents/Info.plist
	@cp lmux.entitlements $(APP_DIR)/Contents/Resources/
	@echo "Generating AppIcon.icns from $(ICON_PNG)..."
	@rm -rf $(ICONSET_BUILD)
	@mkdir -p $(ICONSET_BUILD)
	@sips -z 16 16     $(ICON_PNG) --out $(ICONSET_BUILD)/icon_16x16.png >/dev/null
	@sips -z 32 32     $(ICON_PNG) --out $(ICONSET_BUILD)/icon_16x16@2x.png >/dev/null
	@sips -z 32 32     $(ICON_PNG) --out $(ICONSET_BUILD)/icon_32x32.png >/dev/null
	@sips -z 64 64     $(ICON_PNG) --out $(ICONSET_BUILD)/icon_32x32@2x.png >/dev/null
	@sips -z 128 128   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_128x128.png >/dev/null
	@sips -z 256 256   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_128x128@2x.png >/dev/null
	@sips -z 256 256   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_256x256.png >/dev/null
	@sips -z 512 512   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_256x256@2x.png >/dev/null
	@sips -z 512 512   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_512x512.png >/dev/null
	@sips -z 1024 1024 $(ICON_PNG) --out $(ICONSET_BUILD)/icon_512x512@2x.png >/dev/null
	@iconutil -c icns $(ICONSET_BUILD) -o $(APP_DIR)/Contents/Resources/AppIcon.icns
	@rm -rf $(ICONSET_BUILD)
	@chmod +x $(APP_DIR)/Contents/MacOS/lmux
	@chmod +x $(APP_DIR)/Contents/MacOS/lmux-backend
	@codesign --force --deep --sign - $(APP_DIR) 2>/dev/null || true
	@echo "App bundle created: $(APP_DIR)"
	@echo "Run: open $(APP_DIR)"

run:
	@if [ ! -e "$(APP_DIR)/Contents/MacOS/lmux" ] || \
	     [ -n "$$(find Sources Package.swift ../SwiftTerm/Sources backend-src -type f -newer '$(APP_DIR)/Contents/MacOS/lmux' -print -quit 2>/dev/null)" ]; then \
		$(MAKE) app; \
	else \
		echo "lmux.app is up to date (skipping rebuild to keep signature/TCC stable)."; \
	fi
	open $(APP_DIR)

# Cross-compile Swift frontend for x86_64 (Intel target), macOS 12 enforced.
build-x86:
	swift build --arch x86_64 $(X86_12_TARGET)

# Build an x86_64 app bundle (frontend cross-compiled, backend GOARCH=amd64).
# CGO must be enabled with a matching C compiler: the backend embeds
# go-sqlite3, which requires cgo. Without it the binary is a stub and dies on
# startup ("go-sqlite3 requires cgo to work").
app-x86: build-x86
	@echo "Creating x86_64 app bundle..."
	@cd $(BACKEND_SRC) && GOARCH=amd64 CGO_ENABLED=1 CC="clang -arch x86_64" GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm 2>/dev/null \
		&& echo "Backend built (amd64, cgo): $(BACKEND_BIN)" \
		|| echo "WARN: go unavailable, reusing existing backend binary"
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@cp $(BINARY_X86) $(APP_DIR)/Contents/MacOS/lmux
	@cp $(BACKEND_BIN) $(APP_DIR)/Contents/MacOS/lmux-backend
	@cp $(INFO_PLIST) $(APP_DIR)/Contents/Info.plist
	@cp lmux.entitlements $(APP_DIR)/Contents/Resources/
	@echo "Generating AppIcon.icns from $(ICON_PNG)..."
	@rm -rf $(ICONSET_BUILD)
	@mkdir -p $(ICONSET_BUILD)
	@sips -z 16 16     $(ICON_PNG) --out $(ICONSET_BUILD)/icon_16x16.png >/dev/null
	@sips -z 32 32     $(ICON_PNG) --out $(ICONSET_BUILD)/icon_16x16@2x.png >/dev/null
	@sips -z 32 32     $(ICON_PNG) --out $(ICONSET_BUILD)/icon_32x32.png >/dev/null
	@sips -z 64 64     $(ICON_PNG) --out $(ICONSET_BUILD)/icon_32x32@2x.png >/dev/null
	@sips -z 128 128   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_128x128.png >/dev/null
	@sips -z 256 256   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_128x128@2x.png >/dev/null
	@sips -z 256 256   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_256x256.png >/dev/null
	@sips -z 512 512   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_256x256@2x.png >/dev/null
	@sips -z 512 512   $(ICON_PNG) --out $(ICONSET_BUILD)/icon_512x512.png >/dev/null
	@sips -z 1024 1024 $(ICON_PNG) --out $(ICONSET_BUILD)/icon_512x512@2x.png >/dev/null
	@iconutil -c icns $(ICONSET_BUILD) -o $(APP_DIR)/Contents/Resources/AppIcon.icns
	@rm -rf $(ICONSET_BUILD)
	@chmod +x $(APP_DIR)/Contents/MacOS/lmux
	@chmod +x $(APP_DIR)/Contents/MacOS/lmux-backend
	@codesign --force --deep --sign - $(APP_DIR) 2>/dev/null || true
	@echo "x86_64 app bundle created: $(APP_DIR)"

# --- SwiftTerm variant (lmux-st.app, distinct icon) ------------------------

# Build Swift frontend for the swiftterm variant (macOS 12 enforced).
build-st:
	swift build --skip-update $(MACOS_MIN_TARGET)

# Build the swiftterm variant app bundle under a distinct name (lmux-st.app)
# so it can coexist with the master lmux.app, with its own icon.
app-st: build-st
	@echo "Creating swiftterm .app bundle ($(ST_APP_NAME))..."
	@cd $(BACKEND_SRC) && GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm 2>/dev/null \
		&& echo "Backend built: $(BACKEND_BIN)" \
		|| echo "WARN: go unavailable, reusing existing backend binary"
	@rm -rf .build/$(ST_APP_NAME)
	@mkdir -p .build/$(ST_APP_NAME)/Contents/MacOS
	@mkdir -p .build/$(ST_APP_NAME)/Contents/Resources
	@cp $(BINARY) .build/$(ST_APP_NAME)/Contents/MacOS/lmux
	@cp $(BACKEND_BIN) .build/$(ST_APP_NAME)/Contents/MacOS/lmux-backend
	@cp $(INFO_PLIST) .build/$(ST_APP_NAME)/Contents/Info.plist
	@cp lmux.entitlements .build/$(ST_APP_NAME)/Contents/Resources/
	@echo "Generating AppIcon.icns from $(ST_ICON_PNG)..."
	@rm -rf $(ICONSET_BUILD)
	@mkdir -p $(ICONSET_BUILD)
	@sips -z 16 16     $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_16x16.png >/dev/null
	@sips -z 32 32     $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_16x16@2x.png >/dev/null
	@sips -z 32 32     $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_32x32.png >/dev/null
	@sips -z 64 64     $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_32x32@2x.png >/dev/null
	@sips -z 128 128   $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_128x128.png >/dev/null
	@sips -z 256 256   $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_128x128@2x.png >/dev/null
	@sips -z 256 256   $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_256x256.png >/dev/null
	@sips -z 512 512   $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_256x256@2x.png >/dev/null
	@sips -z 512 512   $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_512x512.png >/dev/null
	@sips -z 1024 1024 $(ST_ICON_PNG) --out $(ICONSET_BUILD)/icon_512x512@2x.png >/dev/null
	@iconutil -c icns $(ICONSET_BUILD) -o .build/$(ST_APP_NAME)/Contents/Resources/AppIcon.icns
	@rm -rf $(ICONSET_BUILD)
	@chmod +x .build/$(ST_APP_NAME)/Contents/MacOS/lmux
	@chmod +x .build/$(ST_APP_NAME)/Contents/MacOS/lmux-backend
	@codesign --force --deep --sign - .build/$(ST_APP_NAME) 2>/dev/null || true
	@echo "Swiftterm app bundle created: .build/$(ST_APP_NAME)"
	@echo "Install: cp -R .build/$(ST_APP_NAME) /Applications/$(ST_APP_NAME)"

clean:
	rm -rf .build/
	rm -f $(BACKEND_BIN)
