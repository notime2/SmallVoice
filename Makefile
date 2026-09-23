# SmallVoice build helpers. Everything builds into ./build so paths stay predictable.
DERIVED      := $(CURDIR)/build/DerivedData
PKG_DERIVED  := $(CURDIR)/build/PackageDerivedData
SOURCES      := $(DERIVED)/SourcePackages
XCFLAGS      := -skipPackagePluginValidation -skipMacroValidation
CONFIG       ?= Debug
APP          := $(DERIVED)/Build/Products/$(CONFIG)/SmallVoice.app
INSTALL_DIR  ?= /Applications

.PHONY: project build test install run dmg clean

project:
	xcodegen generate

build: project
	xcodebuild -project SmallVoice.xcodeproj -scheme SmallVoice -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) $(XCFLAGS) build

test:
	cd Packages/ParakeetKit && xcodebuild -scheme ParakeetKit -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(PKG_DERIVED) -clonedSourcePackagesDirPath $(SOURCES) $(XCFLAGS) test

install:
	$(MAKE) build CONFIG=Release
	-pkill -x SmallVoice; sleep 0.5
	rm -rf "$(INSTALL_DIR)/SmallVoice.app"
	ditto "$(DERIVED)/Build/Products/Release/SmallVoice.app" "$(INSTALL_DIR)/SmallVoice.app"
	open "$(INSTALL_DIR)/SmallVoice.app"

run: build
	open "$(APP)"

# A disk image of the Release build, signed with whatever Config/*.xcconfig selects.
# For a notarized image that opens anywhere, use scripts/notarize.sh instead.
dmg:
	$(MAKE) build CONFIG=Release
	scripts/make-dmg.sh "$(DERIVED)/Build/Products/Release/SmallVoice.app" build/SmallVoice.dmg

clean:
	rm -rf build
