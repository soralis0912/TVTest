CMAKE ?= cmake
BUILD_JOBS ?= 8
TVTPLAY_DIR ?= ../../TvtPlay/macos/plugin
MACBONDRIVER_DIR ?= ../../MacBonDriver
APP := build/TVTest.app
CONTENTS := $(APP)/Contents
PLUGIN := $(abspath $(CONTENTS)/PlugIns/TvtPlay.bundle)
BONDRIVERS_DEST := $(CONTENTS)/PlugIns/BonDrivers

.PHONY: all host plugin bondrivers host-binary test
all: host plugin bondrivers
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

bondrivers:
	mkdir -p "$(BONDRIVERS_DEST)"
	@if [ -d "$(MACBONDRIVER_DIR)/build/MBD_SQR100.bundle" ]; then \
		rm -rf "$(BONDRIVERS_DEST)/MBD_SQR100.bundle"; \
		cp -R "$(MACBONDRIVER_DIR)/build/MBD_SQR100.bundle" "$(BONDRIVERS_DEST)/MBD_SQR100.bundle"; \
	fi
	@if [ -d "$(MACBONDRIVER_DIR)/build/MBD_SampleUSB.bundle" ]; then \
		rm -rf "$(BONDRIVERS_DEST)/MBD_SampleUSB.bundle"; \
		cp -R "$(MACBONDRIVER_DIR)/build/MBD_SampleUSB.bundle" "$(BONDRIVERS_DEST)/MBD_SampleUSB.bundle"; \
	fi

test: host-binary
	./build/native/TVTestRecordingSessionTests
	$(CMAKE) -S ../src/LibISDB -B build/libisdb-tests -DCMAKE_BUILD_TYPE=Debug
	$(CMAKE) --build build/libisdb-tests --target libisdbtest --parallel $(BUILD_JOBS)
	./build/libisdb-tests/Tests/libisdbtest
