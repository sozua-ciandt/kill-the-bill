APP_NAME    := KillTheBill
BUILD_DIR   := .build/arm64-apple-macosx/release
BINARY      := $(BUILD_DIR)/$(APP_NAME)
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := /Applications

# ── Build ────────────────────────────────────────────────────────────

.PHONY: build
build:
	swift build -c release --quiet

# ── App bundle ───────────────────────────────────────────────────────

.PHONY: bundle
bundle: build
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BINARY)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

# ── Install to /Applications ─────────────────────────────────────────

.PHONY: install
install: bundle
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.5
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"
	@open "$(INSTALL_DIR)/$(APP_NAME).app"

# ── Run (dev) ────────────────────────────────────────────────────────

.PHONY: run
run: build
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.5
	@nohup "$(BINARY)" > /dev/null 2>&1 &
	@echo "$(APP_NAME) running"

# ── Uninstall ────────────────────────────────────────────────────────

.PHONY: uninstall
uninstall:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Uninstalled $(APP_NAME)"

# ── Clean ────────────────────────────────────────────────────────────

.PHONY: clean
clean:
	swift package clean
	@rm -rf "$(APP_BUNDLE)"
