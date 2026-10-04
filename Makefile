# Every command an agent or a person needs. `make check` is the gate that CI runs.

SOURCES := Package.swift Sources Tests App/Sources
SWIFT_FLAGS := -Xswiftc -warnings-as-errors
XCODEBUILD := xcodebuild -project ClaudeMeter.xcodeproj -scheme ClaudeMeter \
	-derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
	-onlyUsePackageVersionsFromResolvedFile
APP := build/DerivedData/Build/Products/Debug/ClaudeMeter.app

.DEFAULT_GOAL := help
.PHONY: help check format lint test app run clean release

help: ## List the commands.
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-8s %s\n", $$1, $$2}'

check: lint test app ## Run everything CI runs: format lint, all tests, unsigned app build.
	@echo "check passed"

format: ## Format all Swift sources in place.
	swift format --in-place --recursive $(SOURCES)

lint: ## Fail on any formatting difference.
	swift format lint --strict --recursive $(SOURCES)

test: ## Build with warnings as errors and run every test.
	swift test $(SWIFT_FLAGS)

app: ## Build the unsigned Debug app.
	$(XCODEBUILD) -configuration Debug -destination 'platform=macOS,arch=$(shell uname -m)' \
		CODE_SIGNING_ALLOWED=NO build -quiet

run: app ## Build and launch the Debug app.
	-pkill -f '$(APP)/Contents/MacOS/ClaudeMeter'
	open $(APP)

clean: ## Remove build output.
	rm -rf .build build

release: ## Publish a signed release: make release VERSION=4.0.0 BUILD=400
	scripts/release.sh $(VERSION) $(BUILD)
