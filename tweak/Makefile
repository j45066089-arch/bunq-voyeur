# bunqVoyeur — loggt entschlüsselte bunq-Server-Antworten (NSJSONSerialization-Hook)
ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = bunqVoyeur

bunqVoyeur_FILES = Tweak.x
bunqVoyeur_CFLAGS = -fobjc-arc -F$(THEOS)/sdks/iPhoneOS$(TARGET_VERSION).sdk/System/Library/Frameworks

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 bunq || true"
