# Every command an agent or a person needs. `make check` is the gate that CI runs.

SOURCES := Package.swift Sources Tests App/Sources
SWIFT_FLAGS := -Xswiftc -warnings-as-errors
XCODEBUILD := xcodebuild -project ClaudeMeter.xcodeproj -scheme ClaudeMeter \
	-derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
	-onlyUsePackageVersionsFromResolvedFile
APP := $(CURDIR)/build/DerivedData/Build/Products/Debug/ClaudeMeter.app

.DEFAULT_GOAL := help
.PHONY: help check format lint test app release-build run clean release release-candidate

help: ## List the commands.
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-18s %s\n", $$1, $$2}'

check: lint test app release-build ## Run everything CI runs: lint, tests, Debug and Release builds.
	@echo "check passed"

format: ## Format all Swift sources in place.
	swift format --in-place --recursive $(SOURCES)

lint: ## Fail on any formatting difference.
	swift format lint --strict --recursive $(SOURCES)

# `swift test --quiet` also hides compiler errors, so the build runs as its own step with full
# output. The quiet test run prints each failure with its file and line, and nothing else.
test: ## Build with warnings as errors and run every test. VERBOSE=1 lists every test.
	swift build --build-tests $(SWIFT_FLAGS)
	swift test --skip-build $(if $(VERBOSE),,--quiet)

app: ## Build the unsigned Debug app for this Mac.
	$(XCODEBUILD) -configuration Debug -destination 'platform=macOS,arch=$(shell uname -m)' \
		CODE_SIGNING_ALLOWED=NO build -quiet

release-build: ## Build the unsigned universal Release app, as the release archive does.
	$(XCODEBUILD) -configuration Release -destination 'generic/platform=macOS' \
		CODE_SIGNING_ALLOWED=NO build -quiet

run: app ## Build and launch the Debug app of this checkout.
	-pkill -f '$(APP)/Contents/MacOS/ClaudeMeter'
	@while pgrep -f '$(APP)/Contents/MacOS/ClaudeMeter' >/dev/null; do sleep 0.1; done
	open '$(APP)'

clean: ## Remove build output.
	rm -rf .build build

release: ## Publish a signed release (maintainer only): make release VERSION=4.0.0 BUILD=400
	@test -n "$(VERSION)" -a -n "$(BUILD)" || { echo "usage: make release VERSION=4.0.0 BUILD=400"; exit 2; }
	scripts/release.sh "$(VERSION)" "$(BUILD)"

release-candidate: ## Build and validate a release without publishing anything.
	@test -n "$(VERSION)" -a -n "$(BUILD)" || { echo "usage: make release-candidate VERSION=4.0.0 BUILD=400"; exit 2; }
	scripts/release.sh "$(VERSION)" "$(BUILD)" --prepare-only
