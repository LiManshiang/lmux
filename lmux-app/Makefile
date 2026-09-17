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

.PHONY: build test run clean app icon backend build-st app-st build-x86 app-x86 verify verify-bundles

APP_NAME = lmux.app
APP_DIR = .build/$(APP_NAME)
INFO_PLIST = Info.plist
ICON_PNG = Resources/lmux-icon.png
ICONSET_BUILD = .build/lmux.iconset
BACKEND_SRC = backend-src
BACKEND_BIN = backend/lmux

HOST_ARCH ?= $(shell uname -m)

# Which SwiftPM build system to build with — not a preference. The build system
# decides the shape of the `Bundle.module` accessor SwiftPM generates, and only
# one shape can find a bundle inside an .app:
#
#   swiftbuild  probes Bundle.main.resourceURL  → Contents/Resources
#   native      probes Bundle.main.bundleURL    → the .app itself, then a
#               build-time absolute path that exists only on the build machine
#
# That accessor runs before ghostty_init (it is reached from
# GhosttyRuntimeResources.directoryURL), so an app whose accessor cannot see the
# bundles traps on its first terminal session — that is the 1.0.279 crash.
# Putting a copy at the .app root to satisfy the native accessor is not an
# option: codesign seals only Contents/ and refuses ("unsealed contents present
# in the bundle root"), leaving the app unsigned. The build system is what has
# to be right.
#
# Swift 6.4 (Xcode 27) defaults to swiftbuild; Swift 6.2/6.3 (Xcode 26) still
# default to the deprecated native and need the flag, so probe for it rather
# than assume. A toolchain that does not offer it (Xcode 16 / Swift 5.10) still
# builds — and check-app-bundles.sh then fails the packaging with an actionable
# message instead of shipping an app that crashes.
#
# $(1) = extra flags for `swift build`. Callers put the `@` on their own recipe
# line: an `@` that comes out of the expansion of a line that already started
# with `@trap ...; \` reaches the shell instead of being treated as a prefix.
define swift_build
	bs=""; \
	if swift build --build-system swiftbuild --help >/dev/null 2>&1; then \
		bs="--build-system swiftbuild"; \
	else \
		echo "WARN: this SwiftPM has no swiftbuild; falling back to the deprecated native system."; \
		echo "WARN: its Bundle.module accessor cannot see bundles inside an .app, so packaging will fail."; \
	fi; \
	swift build $(1) $$bs
endef

# --- macOS 12 SwiftTerm variant (lmux-st.app) ------------------------------
# Deployment target pinned so any macOS-13+ API is a compile error.
MACOS_MIN_TARGET = -Xswiftc -target -Xswiftc $(HOST_ARCH)-apple-macosx12.0
ST_APP_NAME = lmux-st.app
ST_APP_DIR = .build-st/$(ST_APP_NAME)
ST_ICON_PNG = Resources/lmux-icon-st.png
# Ask SwiftPM where the products are instead of assuming a path: swiftbuild
# writes <scratch>/out/Products/Debug and the deprecated native build system
# <scratch>/<triple>/debug, and `.build/debug` — the symlink the Makefile used
# to rely on — was missing right after a successful swiftbuild build on CI.
# --show-bin-path answers for the toolchain, scratch path and architecture in
# use. These are expanded lazily, so only the packaging targets pay for it.
BIN_DIR = $(shell swift build --skip-update --show-bin-path 2>/dev/null)
BIN_DIR_ST = $(shell swift build --skip-update --scratch-path .build-st --show-bin-path 2>/dev/null)
BIN_DIR_X86 = $(shell swift build --skip-update --arch x86_64 --scratch-path .build --show-bin-path 2>/dev/null)
BINARY = $(BIN_DIR)/lmux
BINARY_ST = $(BIN_DIR_ST)/lmux
BINARY_X86 = $(BIN_DIR_X86)/lmux
# st variant is a distinct bundle (isolated UserDefaults / launch services).
ST_BUNDLE_ID = com.manshiangli.lmux-st

# x86_64 cross-compiled SwiftTerm variant (Intel machines, macOS 12).
X86_12_TARGET = -Xswiftc -target -Xswiftc x86_64-apple-macosx12.0

# Build Go backend
backend:
	cd $(BACKEND_SRC) && GOPROXY=https://goproxy.cn,direct go build -o ../$(BACKEND_BIN) ./cmd/cbsm
	@echo "Backend built: $(BACKEND_BIN)"

# Build Swift frontend (ghostty variant)
build:
	@$(call swift_build,--skip-update)

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
	$(call swift_build,--skip-update --scratch-path .build-st $(MACOS_MIN_TARGET))

# Verify against the configuration CI uses, before tagging a release.
#
# `make app` takes the default manifest and passes no -target, so it checks
# nothing about macOS 12: two release runs were lost to macOS 13-only APIs
# that only the CI build caught. This runs the builds and tests that do.
verify: build-st build-x86 test verify-bundles
	@echo "Verified: both architectures build for macOS 12, tests pass, and the app carries its resource bundles."

# assemble_bundle runs this while packaging; repeat it for an app that was
# already built. CI and tools/verify-release.sh run the same script against the
# app they ship.
verify-bundles: app
	@bash tools/check-app-bundles.sh $(APP_DIR)

# Cross-compile Swift frontend for x86_64 (Intel target), macOS 12 enforced.
build-x86:
	@cp Package.swift /tmp/lmux-Package.swift.backup
	@cp Package.st.swift Package.swift
	@trap 'cp /tmp/lmux-Package.swift.backup Package.swift' EXIT; \
	$(call swift_build,--arch x86_64 --scratch-path .build $(X86_12_TARGET))

# Shared bundle assembler. $(1)=app dir, $(2)=frontend binary,
# $(3)=icon png, $(4)=minimum OS, $(5)=bundle id.
#
# The SwiftPM resource bundles that sit next to the frontend binary are copied
# into Contents/Resources, which is both where a packaged .app is expected to
# keep them and the location the swiftbuild accessor probes. They are not
# optional: GhosttyTerminal reaches `Bundle.module` (via GhosttyRuntimeResources
# .directoryURL) before ghostty_init, and its accessor traps with fatalError
# when the bundle is not where it looks. SwiftTerm's metallib lookup goes
# through the same accessor.
#
# The bundles deliberately get no copy at the top level of the .app: that is
# where the deprecated native build system's accessor probes, but codesign seals
# only Contents/ and rejects the extra root entries ("unsealed contents present
# in the bundle root"), which would leave the app unsigned. Hence the build
# system has to be swiftbuild rather than the layout — see the swift_build
# comment — and check-app-bundles.sh below fails the packaging if the frontend
# was built the other way.
define assemble_bundle
	@test -x $(2) || { \
		echo "ERROR: frontend binary not found at '$(2)'"; \
		echo "       swift build --show-bin-path says '$$(swift build --skip-update --show-bin-path 2>/dev/null)'"; \
		exit 1; \
	}
	@rm -rf $(1)
	@mkdir -p $(1)/Contents/MacOS
	@mkdir -p $(1)/Contents/Resources
	@cp $(2) $(1)/Contents/MacOS/lmux
	@cp $(BACKEND_BIN) $(1)/Contents/MacOS/lmux-backend
	@cp $(INFO_PLIST) $(1)/Contents/Info.plist
	@cp lmux.entitlements $(1)/Contents/Resources/
	@bundles="$$(ls -d $(dir $(2))*.bundle 2>/dev/null)"; \
	if [ -z "$$bundles" ]; then \
		echo "ERROR: no SwiftPM resource bundles in $(dir $(2)) (Rebuild, or check swift build)"; \
		exit 1; \
	fi; \
	echo "Copying resource bundles: $$(basename -a $$bundles | tr '\n' ' ')"; \
	cp -R $$bundles $(1)/Contents/Resources/
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
	@# Report signing failures instead of hiding them: a bundle whose root
	@# carries anything but Contents/ cannot be signed at all, and shipping an
	@# unsigned app would surface as a Gatekeeper problem for users, far from
	@# the cause.
	@out="$$(codesign --force --deep --sign - $(1) 2>&1)"; \
	if [ $$? -ne 0 ]; then \
		echo "ERROR: codesign failed for $(1):"; printf '%s\n' "$$out" | sed 's/^/  /'; exit 1; \
	fi; \
	codesign --verify $(1) || { echo "ERROR: $(1) does not pass signature verification"; exit 1; }
	@bash tools/check-app-bundles.sh $(1)
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
