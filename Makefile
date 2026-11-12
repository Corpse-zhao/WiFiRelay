TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = WiFiRelayD
WiFiRelayD_FILES = daemon.m
WiFiRelayD_FRAMEWORKS = Foundation SystemConfiguration
WiFiRelayD_CFLAGS = -fobjc-arc
WiFiRelayD_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
