export THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.5:16.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

THEOS_LAYOUT_DIR = layout
THEOS_XCODE_DERIVED_DATA = $(THEOS_PROJECT_DIR)/.theos/xcode-derived
THEOS_XCODE_APP = $(THEOS_XCODE_DERIVED_DATA)/Build/Products/Debug-iphoneos/Tellus.app
THEOS_STAGED_APP = $(THEOS_STAGING_DIR)/Applications/Tellus.app

include $(THEOS_MAKE_PATH)/package.mk

$(THEOS_PACKAGE_DIR):
	mkdir -p "$@"

after-stage::
	xcodebuild -quiet -project TellusApp.xcodeproj -scheme Tellus -destination 'generic/platform=iOS' -derivedDataPath "$(THEOS_XCODE_DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO build
	mkdir -p "$(dir $(THEOS_STAGED_APP))"
	ditto "$(THEOS_XCODE_APP)" "$(THEOS_STAGED_APP)"
	find "$(THEOS_STAGED_APP)" -type f -print0 | while IFS= read -r -d '' file; do \
		if file -b "$$file" | grep -q 'Mach-O'; then ldid -S "$$file"; fi; \
	done
