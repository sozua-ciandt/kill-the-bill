APP_NAME    := KillTheBill
BUILD_DIR   := $(shell swift build -c release --show-bin-path 2>/dev/null)
BINARY      := $(BUILD_DIR)/$(APP_NAME)
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
RESOURCE_BUNDLE := $(BUILD_DIR)/KillTheBill_KillTheBill.bundle
INSTALL_DIR := /Applications
SIGNING_IDENTITY ?= -
CODESIGN_FLAGS := --force --sign "$(SIGNING_IDENTITY)"
SWIFT_TEST_FLAGS ?= --parallel

ifneq ($(SIGNING_IDENTITY),-)
CODESIGN_FLAGS += --options runtime --timestamp
endif

# ── Build ────────────────────────────────────────────────────────────

.PHONY: build
build:
	swift build -c release --quiet

.PHONY: test
test:
	swift test $(SWIFT_TEST_FLAGS)

.PHONY: check
check: test
	swift build -c release
	bash -n install.sh
	bash -n uninstall.sh

# ── App bundle ───────────────────────────────────────────────────────

.PHONY: bundle
bundle: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BINARY)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@cp assets/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@test -d "$(RESOURCE_BUNDLE)" || (echo "Missing SwiftPM resource bundle: $(RESOURCE_BUNDLE)" >&2; exit 1)
	@ditto "$(RESOURCE_BUNDLE)" "$(APP_BUNDLE)/Contents/Resources/KillTheBill_KillTheBill.bundle"
	@plutil -lint "$(APP_BUNDLE)/Contents/Info.plist" >/dev/null
	@codesign $(CODESIGN_FLAGS) "$(APP_BUNDLE)"
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

.PHONY: print-app-bundle
print-app-bundle:
	@echo "$(APP_BUNDLE)"

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
