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
# Publishing goes through `ainkrad publish` and nowhere else: it validates the
# bundle as the store does, signs it ($SIGN_IDENTITY, or --sign-identity in
# PUBLISH_FLAGS), creates the GitHub Release and lists it in AinkradCatalog.
#   SIGN_IDENTITY="Developer ID Application: ..." make release V=v1.0.0
#   make release V=v1.0.0 PUBLISH_FLAGS="--dry-run --sign-identity -"   # plan only
AINKRAD ?= ainkrad
release: releasebuild ; $(AINKRAD) publish build/Build/Products/Release/ForgePlugin.bundle $(V) $(PUBLISH_FLAGS)

.PHONY: generate build test releasebuild sideload release

include scripts/guardrails.mk
