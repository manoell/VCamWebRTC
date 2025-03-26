TARGET := iphone:clang:latest:14
INSTALL_TARGET_PROCESSES = SpringBoard

THEOS_DEVICE_IP=192.168.0.165

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamWebRTC

VCamWebRTC_FILES = Tweak.x
VCamWebRTC_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
