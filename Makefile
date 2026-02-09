APP_NAME = PingClaude
BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES_DIR = $(CONTENTS)/Resources

SRC_DIR = Sources/PingClaude
SOURCES = $(wildcard $(SRC_DIR)/*.swift)

SWIFTC = swiftc
SWIFTFLAGS = -O -whole-module-optimization \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ServiceManagement

.PHONY: build bundle run clean install uninstall lint lint-fix

lint:
	@echo "Running code quality scan..."
	@swift Scripts/quality-scan.swift Sources/PingClaude

lint-fix:
	@echo "Note: Auto-fixes would require SwiftLint (macOS 13+)"
	@echo "Manual review of issues recommended."

build:
	@echo "Compiling $(APP_NAME)..."
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFTFLAGS) $(SOURCES) -o $(BUILD_DIR)/$(APP_NAME)
	@echo "Build succeeded."

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

uninstall:
	rm -rf /Applications/$(APP_NAME).app
	@echo "Removed /Applications/$(APP_NAME).app"

clean:
	rm -rf $(BUILD_DIR)
