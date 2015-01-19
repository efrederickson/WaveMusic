ARCHS = armv7 armv7s arm64
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WaveMusic
WaveMusic_FILES = Tweak.xm
WaveMusic_FRAMEWORKS = AVFoundation UIKit CoreGraphics QuartzCore CoreMedia MediaPlayer

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Music"
