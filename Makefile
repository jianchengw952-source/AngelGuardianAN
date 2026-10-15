TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GeminiSiriOverlay
GeminiSiriOverlay_FILES = Tweak.x
GeminiSiriOverlay_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unicode-zero-width -Wno-unguarded-availability-new
GeminiSiriOverlay_FRAMEWORKS = UIKit Foundation AVFoundation Speech Contacts QuartzCore CoreGraphics CoreMedia CoreVideo CoreImage

include $(THEOS_MAKE_PATH)/tweak.mk