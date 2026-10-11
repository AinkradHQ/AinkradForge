DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# `<cacheRoot>/DevPlugins`, scanned by Debug hosts only (AppEnvironment+BootstrapStores,
# PluginTrust.scansDevPluginsDirectory); cacheRoot is AinkradHome.defaultCacheRoot.
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins
XCODEBUILD := xcodebuild -scheme ForgePlugin -derivedDataPath build -destination 'platform=macOS'

generate: ; xcodegen generate
build: lint generate ; $(XCODEBUILD) -configuration Debug build
test: lint generate ; $(XCODEBUILD) -configuration Debug test
releasebuild: generate ; $(XCODEBUILD) -configuration Release build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/ForgePlugin.bundle"
	cp -R build/Build/Products/Debug/ForgePlugin.bundle "$(DEV_PLUGINS)/ForgePlugin.bundle"
# Releasing goes through scripts/release.sh, as the sibling plugins do: it builds clean, Developer-ID signs,
# publishes the GitHub release and updates the catalog (a first release's catalog entry is added by hand).
#   SIGN_IDENTITY="Developer ID Application: ..." make release V=v0.1.0
release: ; ./scripts/release.sh $(V)

.PHONY: generate build test releasebuild sideload release

include scripts/guardrails.mk
