APP_NAME = PingClaude
BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES_DIR = $(CONTENTS)/Resources

SRC_DIR = Sources/PingClaude
SOURCES = $(wildcard $(SRC_DIR)/*.swift)
TEST_SOURCES = $(filter-out $(SRC_DIR)/main.swift, $(SOURCES))

SWIFTC = swiftc
SWIFTFLAGS = -O -whole-module-optimization \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ServiceManagement

.PHONY: build bundle run clean install uninstall deploy lint lint-fix test

test: build
	@echo "Running tests..."
	@$(SWIFTC) $(SWIFTFLAGS) $(TEST_SOURCES) Tests/PingClaudeTests.swift -o $(BUILD_DIR)/PingClaudeTests
	@$(BUILD_DIR)/PingClaudeTests
	@rm $(BUILD_DIR)/PingClaudeTests
	@echo "Tests complete."

lint:
	@echo "Running code quality scan..."
	@swift Scripts/quality-scan.swift Sources/PingClaude

lint-fix:
	@echo "Note: Auto-fixes would require SwiftLint (macOS 13+)"
	@echo "Manual review of issues recommended."

build:
	@echo "Compiling $(APP_NAME)..."
	@mkdir -p $(BUILD_DIR)
	@echo 'extension Constants { static let buildVersion = "$(shell date +%Y%m%d.%H%M%S)" }' > $(SRC_DIR)/BuildVersion.swift
	$(SWIFTC) $(SWIFTFLAGS) $(SRC_DIR)/*.swift -o $(BUILD_DIR)/$(APP_NAME)
	@echo "Build succeeded. Version: $$(cat $(SRC_DIR)/BuildVersion.swift | grep -o '"[^"]*"')"

bundle: build
	@echo "Assembling $(APP_NAME).app bundle..."
	@mkdir -p $(MACOS_DIR) $(RESOURCES_DIR)
	cp $(BUILD_DIR)/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	cp SupportFiles/Info.plist $(CONTENTS)/Info.plist
	@echo "$(APP_BUNDLE) is ready."

run: bundle
	@echo "Launching $(APP_NAME)..."
	open $(APP_BUNDLE)

install: bundle
	@echo "Installing to /Applications..."
	cp -R $(APP_BUNDLE) /Applications/$(APP_NAME).app
	@echo "Installed /Applications/$(APP_NAME).app"

deploy: bundle
	@echo "Deploying $(APP_NAME)..."
	@pkill -9 -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@sleep 1
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) /Applications/$(APP_NAME).app
	@BUILD_HASH=$$(md5 -q $(BUILD_DIR)/$(APP_NAME)); \
	 INSTALLED_HASH=$$(md5 -q /Applications/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)); \
	 VERSION=$$(cat $(BUILD_DIR)/BuildVersion.swift | sed -n 's/.*"\(.*\)".*/\1/p'); \
	 if [ "$$BUILD_HASH" = "$$INSTALLED_HASH" ]; then \
	   echo "Verified: /Applications/$(APP_NAME).app matches build ($$VERSION, md5:$$BUILD_HASH)"; \
	 else \
	   echo "ERROR: Binary mismatch! Build md5:$$BUILD_HASH != Installed md5:$$INSTALLED_HASH"; \
	   exit 1; \
	 fi
	@open /Applications/$(APP_NAME).app
	@echo "Deployed and launched $(APP_NAME)."

uninstall:
	rm -rf /Applications/$(APP_NAME).app
	@echo "Removed /Applications/$(APP_NAME).app"

clean:
	rm -rf $(BUILD_DIR)
