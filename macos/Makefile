TVTPLAY_DIR ?= ../../TvtPlay/macos/plugin
APP := build/TVTest.app
CONTENTS := $(APP)/Contents
PLUGIN := $(abspath $(CONTENTS)/PlugIns/TvtPlay.bundle)

.PHONY: all host plugin
all: host plugin
host: $(CONTENTS)/MacOS/TVTest $(CONTENTS)/Info.plist

$(CONTENTS)/MacOS/TVTest: main.m TVTestPlaybackPlugin.h Makefile
	mkdir -p "$(@D)"
	xcrun clang -fobjc-arc -mmacosx-version-min=12.0 -Wall -Wextra -O2 -framework AppKit -framework UniformTypeIdentifiers main.m -o "$@"

$(CONTENTS)/Info.plist: Info.plist
	mkdir -p "$(@D)"
	cp "$<" "$@"

plugin:
	$(MAKE) -C "$(TVTPLAY_DIR)" HOST_SDK="$(CURDIR)" BUNDLE="$(PLUGIN)"
