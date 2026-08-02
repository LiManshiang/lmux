.PHONY: build run clean app

BINARY = .build/debug/CBSM
APP_NAME = CBSM.app
APP_DIR = .build/$(APP_NAME)
INFO_PLIST = Info.plist
RESOURCE_BUNDLE = .build/arm64-apple-macosx/debug/CBSM_CBSM.bundle

build:
	swift build

app: build
	@echo "Creating .app bundle..."
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@cp $(BINARY) $(APP_DIR)/Contents/MacOS/CBSM
	@cp $(INFO_PLIST) $(APP_DIR)/Contents/Info.plist
	@cp CBSM.entitlements $(APP_DIR)/Contents/Resources/
	@find $(APP_DIR)/Contents/Resources -name "*.html" -o -name "*.js" -o -name "*.css" | while read f; do \
		if [ -f "$$f" ]; then \
			xattr -cr "$$f" 2>/dev/null || true; \
			codesign --force --sign - "$$f" 2>/dev/null || true; \
		fi; \
	done
	@chmod +x $(APP_DIR)/Contents/MacOS/CBSM
	@codesign --force --deep --sign - $(APP_DIR) 2>/dev/null || true
	@echo "App bundle created at: $(APP_DIR)"
	@echo "Run with: open $(APP_DIR)"

run: app
	open $(APP_DIR)

clean:
	rm -rf .build/
