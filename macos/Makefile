CMAKE ?= cmake
BUILD_JOBS ?= 8
TVTPLAY_DIR ?= ../../TvtPlay/macos/plugin
APP := build/TVTest.app
CONTENTS := $(APP)/Contents
PLUGIN := $(abspath $(CONTENTS)/PlugIns/TvtPlay.bundle)

.PHONY: all host plugin host-binary
all: host plugin
host: host-binary $(CONTENTS)/Info.plist

host-binary:
	$(CMAKE) -S . -B build/native -DCMAKE_BUILD_TYPE=Release
	$(CMAKE) --build build/native --parallel $(BUILD_JOBS)
	mkdir -p "$(CONTENTS)/MacOS"
	install -m 755 build/native/TVTest "$(CONTENTS)/MacOS/TVTest"

$(CONTENTS)/Info.plist: Info.plist
	mkdir -p "$(@D)"
	cp "$<" "$@"

plugin:
	$(MAKE) -C "$(TVTPLAY_DIR)" HOST_SDK="$(CURDIR)" BUNDLE="$(PLUGIN)"
