ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
FINALPACKAGE ?= 1

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AAZTweakManager
AAZTweakManager_FILES = \
	main.m \
	App/ATMAppDelegate.m \
	App/ATMViewControllers.m \
	Core/ATMCore.m \
	Core/ATMBackupManager.m \
	Core/ATMZipWriter.m
AAZTweakManager_CFLAGS = -fobjc-arc -Wall -Wextra \
	-I$(THEOS_PROJECT_DIR)/App \
	-I$(THEOS_PROJECT_DIR)/Core
AAZTweakManager_FRAMEWORKS = UIKit Foundation Security
AAZTweakManager_LIBRARIES = z
AAZTweakManager_CODESIGN_FLAGS = -SResources/AAZTweakManager.entitlements
AAZTweakManager_RESOURCE_FILES = \
	Resources/AppIcon60x60.png \
	Resources/AppIcon60x60@2x.png \
	Resources/AppIcon60x60@3x.png

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache -p /Applications/AAZTweakManager.app || true"
