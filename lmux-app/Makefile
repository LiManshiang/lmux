# lmux build targets.
#
# Single code line, two app products:
#   make app     → lmux.app     Ghostty renderer, macOS 13+   (default Package.swift)
#   make app-st  → lmux-st.app  SwiftTerm renderer, macOS 12 (Package.st.swift)
#   make app-x86 → lmux-st.app  x86_64 + SwiftTerm + macOS 12 (Intel machines)
#
# The backend binary is a build product (not tracked in git): every app*
# target rebuilds it via `go build` (best-effort: reuses an existing
# backend/lmux when the Go toolchain is missing).
#
# The st variant temporarily swaps Package.swift for Package.st.swift during
# its build (trap-based restore) and uses a separate --scratch-path (.build-st)
# so the two variants never pollute each other's build artifacts.

.PHONY: build test run clean app icon backend build-st app-st build-x86 app-x86

BINARY = .build/debug/lmux
APP_NAME = lmux.app
APP_DIR = .build/$(APP_NAME)
INFO_PLIST = Info.plist
ICON_PNG = Resources/lmux-icon.png
ICONSET_BUILD = .build/lmux.iconset
BACKEND_SRC = backend-src
BACKEND_BIN = backend/lmux

HOST_ARCH ?= $(shell uname -m)

# --- macOS 12 SwiftTerm variant (lmux-st.app) ------------------------------
# Deployment target pinned so any macOS-13+ API is a compile error.
MACOS_MIN_TARGET = -Xswiftc -target -Xswiftc $(HOST_ARCH)-apple-macosx12.0
ST_APP_NAME = lmux-st.app
ST_APP_DIR = .build-st/$(ST_APP_NAME)
ST_ICON_PNG = Resources/lmux-icon-st.png
# SwiftPM places per-target products under <scratch>/<triple>/debug.
BINARY_ST = .build-st/$(HOST_ARCH)-apple-macosx/debug/lmux
# st variant is a distinct bundle (isolated UserDefaults / launch services).
ST_BUNDLE_ID = com.manshiangli.lmux-st

# x86_64 cross-compiled SwiftTerm variant (Intel machines, macOS 12).
X86_12_TARGET = -Xswiftc -target -Xswiftc x86_64-apple-macosx12.0
BINARY_X86 = .build/x86_64-apple-macosx/debug/lmux

# Build Go backend
backend:
	cd $(BACKEND_SRC) && GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm
	@echo "Backend built: $(BACKEND_BIN)"

# Build Swift frontend (ghostty variant)
build:
	swift build --skip-update

# Run the unit test suite. Always build/test in native arm64: in a Rosetta
# shell the host arch is x86_64, which writes a second .build triple and then
# fails to load the arm64 test bundle ("incompatible architecture").
test:
	arch -arm64 swift test --skip-update

# Build Swift frontend for the macOS 12 SwiftTerm variant. The manifest swap
# is restored on exit even if the build fails (trap).
build-st:
	@cp Package.swift /tmp/lmux-Package.swift.backup
	@cp Package.st.swift Package.swift
	@trap 'cp /tmp/lmux-Package.swift.backup Package.swift' EXIT; \
	swift build --skip-update --scratch-path .build-st $(MACOS_MIN_TARGET)

# Cross-compile Swift frontend for x86_64 (Intel target), macOS 12 enforced.
build-x86:
	@cp Package.swift /tmp/lmux-Package.swift.backup
	@cp Package.st.swift Package.swift
	@trap 'cp /tmp/lmux-Package.swift.backup Package.swift' EXIT; \
	swift build --arch x86_64 --scratch-path .build $(X86_12_TARGET)

# Shared bundle assembler. $(1)=app dir, $(2)=frontend binary,
# $(3)=icon png, $(4)=minimum OS, $(5)=bundle id.
define assemble_bundle
	@rm -rf $(1)
	@mkdir -p $(1)/Contents/MacOS
	@mkdir -p $(1)/Contents/Resources
	@cp $(2) $(1)/Contents/MacOS/lmux
	@cp $(BACKEND_BIN) $(1)/Contents/MacOS/lmux-backend
	@cp $(INFO_PLIST) $(1)/Contents/Info.plist
	@cp lmux.entitlements $(1)/Contents/Resources/
	@if [ -n "$(4)" ]; then /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $(4)" $(1)/Contents/Info.plist; fi
	@if [ -n "$(5)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(5)" $(1)/Contents/Info.plist; fi
	@echo "Generating AppIcon.icns from $(3)..."
	@rm -rf $(ICONSET_BUILD)
	@mkdir -p $(ICONSET_BUILD)
	@sips -z 16 16     $(3) --out $(ICONSET_BUILD)/icon_16x16.png >/dev/null
	@sips -z 32 32     $(3) --out $(ICONSET_BUILD)/icon_16x16@2x.png >/dev/null
	@sips -z 32 32     $(3) --out $(ICONSET_BUILD)/icon_32x32.png >/dev/null
	@sips -z 64 64     $(3) --out $(ICONSET_BUILD)/icon_32x32@2x.png >/dev/null
	@sips -z 128 128   $(3) --out $(ICONSET_BUILD)/icon_128x128.png >/dev/null
	@sips -z 256 256   $(3) --out $(ICONSET_BUILD)/icon_128x128@2x.png >/dev/null
	@sips -z 256 256   $(3) --out $(ICONSET_BUILD)/icon_256x256.png >/dev/null
	@sips -z 512 512   $(3) --out $(ICONSET_BUILD)/icon_256x256@2x.png >/dev/null
	@sips -z 512 512   $(3) --out $(ICONSET_BUILD)/icon_512x512.png >/dev/null
	@sips -z 1024 1024 $(3) --out $(ICONSET_BUILD)/icon_512x512@2x.png >/dev/null
	@iconutil -c icns $(ICONSET_BUILD) -o $(1)/Contents/Resources/AppIcon.icns
	@rm -rf $(ICONSET_BUILD)
	@chmod +x $(1)/Contents/MacOS/lmux
	@chmod +x $(1)/Contents/MacOS/lmux-backend
	@codesign --force --deep --sign - $(1) 2>/dev/null || true
	@echo "App bundle created: $(1)"
endef

# Build everything for the ghostty variant. The backend build is best-effort:
# if the Go toolchain is unavailable, an existing backend binary is reused.
app: build
	@echo "Creating .app bundle..."
	@cd $(BACKEND_SRC) && GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm 2>/dev/null \
		&& echo "Backend built: $(BACKEND_BIN)" \
		|| echo "WARN: go unavailable, reusing existing backend binary"
	$(call assemble_bundle,$(APP_DIR),$(BINARY),$(ICON_PNG),,)
	@echo "Run: open $(APP_DIR)"

# SwiftTerm variant bundle (macOS 12, st icon, isolated bundle id).
app-st: build-st
	@echo "Creating $(ST_APP_NAME) bundle (SwiftTerm, macOS 12)..."
	@cd $(BACKEND_SRC) && GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm 2>/dev/null \
		&& echo "Backend built: $(BACKEND_BIN)" \
		|| echo "WARN: go unavailable, reusing existing backend binary"
	$(call assemble_bundle,$(ST_APP_DIR),$(BINARY_ST),$(ST_ICON_PNG),12.0,$(ST_BUNDLE_ID))
	@echo "Install: cp -R $(ST_APP_DIR) /Applications/$(ST_APP_NAME)"

# x86_64 SwiftTerm variant bundle (Intel machines). Backend must be built with
# matching arch: go-sqlite3 needs cgo, so CC must target x86_64 too.
app-x86: build-x86
	@echo "Creating x86_64 $(ST_APP_NAME) bundle..."
	@cd $(BACKEND_SRC) && GOARCH=amd64 CGO_ENABLED=1 CC="clang -arch x86_64" GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm 2>/dev/null \
		&& echo "Backend built (amd64, cgo): $(BACKEND_BIN)" \
		|| echo "WARN: go unavailable, reusing existing backend binary"
	$(call assemble_bundle,.build/$(ST_APP_NAME),$(BINARY_X86),$(ST_ICON_PNG),12.0,$(ST_BUNDLE_ID))
	@echo "Install: cp -R .build/$(ST_APP_NAME) /Applications/$(ST_APP_NAME)"

run:
	@if [ ! -e "$(APP_DIR)/Contents/MacOS/lmux" ] || \
	     [ -n "$$(find Sources Package.swift ../SwiftTerm/Sources ../libghostty-spm/Sources backend-src -type f -newer '$(APP_DIR)/Contents/MacOS/lmux' -print -quit 2>/dev/null)" ]; then \
		$(MAKE) app; \
	else \
		echo "lmux.app is up to date (skipping rebuild to keep signature/TCC stable)."; \
	fi
	open $(APP_DIR)

clean:
	rm -rf .build/
	rm -rf .build-st/
	rm -f $(BACKEND_BIN)
