# Uprighter - build without Xcode.
#
# This machine has only the Command Line Tools, and its SwiftPM is broken
# (PackageDescription.swiftmodule declares `swiftLanguageVersions` while the
# dylib exports `swiftLanguageModes`, so no manifest can link). So everything
# is driven straight through swiftc from here.

APP_NAME    := Uprighter
BUNDLE_ID   := local.uprighter.app
VERSION     := 1.0

SDK         := $(shell xcrun --show-sdk-path)
ARCH        := $(shell uname -m)
TARGET      := $(ARCH)-apple-macos14.0
SWIFTC      := swiftc
SWIFTFLAGS  := -O -swift-version 5 -sdk $(SDK) -target $(TARGET)

BUILD       := build
APP         := $(BUILD)/$(APP_NAME).app
CORE_SRC    := $(wildcard Sources/UprighterCore/*.swift) $(wildcard Sources/UprighterCore/Detectors/*.swift)
CLI_SRC     := $(wildcard Sources/UprighterCLI/*.swift)
APP_SRC     := $(wildcard Sources/UprighterApp/*.swift)
CORE_LIB    := $(BUILD)/libUprighterCore.a
CLI_BIN     := $(BUILD)/uprighter

.PHONY: all core cli app run cli-run bench check clean install help

all: cli app ## Build the command line tool and the window app

help: ## List targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

$(BUILD):
	@mkdir -p $(BUILD)

core: $(CORE_LIB) ## Build the detection library

$(CORE_LIB): $(CORE_SRC) | $(BUILD)
	@echo "  core      $(words $(CORE_SRC)) files"
	@$(SWIFTC) $(SWIFTFLAGS) -module-name UprighterCore -emit-library -static \
		-emit-module -emit-module-path $(BUILD)/UprighterCore.swiftmodule \
		-o $(CORE_LIB) $(CORE_SRC)

cli: $(CLI_BIN) ## Build the `uprighter` command line tool

$(CLI_BIN): $(CORE_LIB) $(CLI_SRC)
	@echo "  cli       $(CLI_BIN)"
	@$(SWIFTC) $(SWIFTFLAGS) -I $(BUILD) -L $(BUILD) -lUprighterCore $(CLI_SRC) -o $(CLI_BIN)

app: $(APP)/Contents/MacOS/$(APP_NAME) ## Build the window app bundle

$(APP)/Contents/MacOS/$(APP_NAME): $(CORE_LIB) $(APP_SRC)
	@echo "  app       $(APP)"
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@$(SWIFTC) $(SWIFTFLAGS) -I $(BUILD) -L $(BUILD) -lUprighterCore \
		-parse-as-library $(APP_SRC) -o $(APP)/Contents/MacOS/$(APP_NAME)
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleName</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleDisplayName</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
	  '  <key>CFBundleVersion</key><string>$(VERSION)</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>14.0</string>' \
	  '  <key>NSHighResolutionCapable</key><true/>' \
	  '  <key>NSPrincipalClass</key><string>NSApplication</string>' \
	  '  <key>CFBundleDocumentTypes</key><array><dict>' \
	  '    <key>CFBundleTypeName</key><string>Image</string>' \
	  '    <key>CFBundleTypeRole</key><string>Editor</string>' \
	  '    <key>LSHandlerRank</key><string>Alternate</string>' \
	  '    <key>LSItemContentTypes</key><array><string>public.image</string></array>' \
	  '  </dict></array>' \
	  '</dict></plist>' > $(APP)/Contents/Info.plist
	@plutil -lint $(APP)/Contents/Info.plist >/dev/null
	@codesign --force --sign - --timestamp=none $(APP) 2>/dev/null || \
		echo "  note: ad-hoc signing failed; the app should still run locally"
	@echo "  done      open $(APP)"

run: app ## Build and open the window app
	@open $(APP)

cli-run: cli ## Build the CLI and show its help
	@$(CLI_BIN) --help

check: cli ## Report on the sample photos in ./Samples (if present)
	@test -d Samples && $(CLI_BIN) check Samples || echo "no Samples/ directory"

bench: cli ## Measure accuracy on known-upright photos: make bench DIR=path
	@test -n "$(DIR)" || (echo "usage: make bench DIR=/path/to/upright/photos" && exit 1)
	@$(CLI_BIN) bench "$(DIR)"

install: cli app ## Copy the app to ~/Applications and the tool to ~/bin
	@mkdir -p $$HOME/Applications $$HOME/bin
	@rm -rf $$HOME/Applications/$(APP_NAME).app
	@cp -R $(APP) $$HOME/Applications/
	@cp $(CLI_BIN) $$HOME/bin/uprighter
	@echo "  installed ~/Applications/$(APP_NAME).app and ~/bin/uprighter"

clean: ## Remove build output
	@rm -rf $(BUILD)
	@echo "  cleaned"
