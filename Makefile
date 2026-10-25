# Shortcuts over build.sh and SwiftPM; CI and the release workflow call these
# targets, so a local run is the same check. Variable docs sit on the line
# above: an inline comment would leave a trailing space in the value.
## SwiftPM configuration for build, install and dmg
CONFIG ?= release
## Tag `make release-check` validates, e.g. v2.1.1
TAG ?=
## Where `make snapshots` writes the popover and Settings PNGs
SNAPSHOT_DIR ?= build/snapshots

# Without pipefail a failing command piped into another reports success.
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

# build.sh is the one place the version lives.
VERSION := $(shell sed -n 's:.*<key>CFBundleShortVersionString</key>.*<string>\(.*\)</string>.*:\1:p' build.sh)
DMG := build/MomentumMenu-$(VERSION).dmg

.DEFAULT_GOAL := help
.PHONY: help all test check build install dmg release-check snapshots icons clean

help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } \
		/^[a-z-]+:.*## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST) \
		| { printf "\033[1mUsage:\033[0m make \033[36m<target>\033[0m [\033[33mVAR\033[0m=value]\n\n\033[1mTargets:\033[0m\n"; cat; }
	@awk 'BEGIN { FS = " \\?= ?" } \
		/^## / { doc = substr($$0, 4); next } \
		/^[A-Z_]+ \?=/ && doc { printf "  \033[33m%-14s\033[0m %s \033[2m(default: %s)\033[0m\n", $$1, doc, ($$2 == "" ? "none" : $$2) } \
		{ doc = "" }' $(MAKEFILE_LIST) \
		| { printf "\n\033[1mVariables:\033[0m\n"; cat; }

all: check build ## Check, then build the app

test: ## Run the tests (incremental, so warnings of unchanged files stay hidden)
	swift test

# Its own scratch path, emptied first: an incremental build prints a file's
# warnings only when it recompiles that file.
check: ## Build app and tests from scratch with warnings as errors, then test
	rm -rf .build/check
	swift test --scratch-path .build/check -Xswiftc -warnings-as-errors

build: ## Build build/MomentumMenu.app
	./build.sh $(CONFIG)

install: ## Build and install to ~/Applications
	./build.sh $(CONFIG) install

# The app sits beside an Applications link to drag it onto. ULMO (LZMA) is
# about a quarter smaller than UDZO; macOS 14 and later mount it. The bundle
# is removed after: two copies with one id confuse Launch Services.
dmg: build ## Pack the app into build/MomentumMenu-<version>.dmg with a .sha256
	rm -rf build/dmg "$(DMG)" "$(DMG).sha256"
	mkdir -p build/dmg
	cp -R build/MomentumMenu.app build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "Momentum Menu" -srcfolder build/dmg -format ULMO -ov "$(DMG)"
	cd build && shasum -a 256 "$(notdir $(DMG))" > "$(notdir $(DMG)).sha256"
	rm -rf build/dmg build/MomentumMenu.app
	@echo "Packed $(DMG)"

# A tag on a commit whose build.sh says another version would ship an app
# reporting the wrong version.
release-check: ## Check TAG matches build.sh's version and has release notes
	@test -n "$(TAG)" || { echo "set TAG, e.g. make release-check TAG=v$(VERSION)" >&2; exit 1; }
	@test "$(TAG)" = "v$(VERSION)" || { echo "$(TAG) does not match build.sh's $(VERSION)" >&2; exit 1; }
	@test -f "docs/releases/$(TAG).md" || { echo "docs/releases/$(TAG).md is missing" >&2; exit 1; }
	@echo "$(TAG) matches build.sh and has notes"

snapshots: ## Render the popover and Settings to PNGs without Bluetooth
	SNAPSHOT_DIR="$(abspath $(SNAPSHOT_DIR))" swift test --filter SnapshotRender

icons: ## Redraw the app icons (needs Google Chrome and oxipng)
	Resources/AppIcon/render.sh

clean: ## Remove SwiftPM and build output
	rm -rf .build build
