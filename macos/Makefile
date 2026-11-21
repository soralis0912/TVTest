CMAKE ?= cmake
BUILD_JOBS ?= 8
TVTPLAY_DIR ?= ../../TvtPlay/macos/plugin
BUILD_DIR := build
APP := $(BUILD_DIR)/TVTest.app
PLUGINS_DIR ?= $(HOME)/Library/Application Support/TVTest/PlugIns
PLUGIN := $(PLUGINS_DIR)/TvtPlay.bundle

.PHONY: all app plugin test clean
all: app

app:
	$(CMAKE) -S . -B "$(BUILD_DIR)" -DCMAKE_BUILD_TYPE=Release
	$(CMAKE) --build "$(BUILD_DIR)" --target TVTest --parallel $(BUILD_JOBS)

plugin: app
	@if [ -d "$(TVTPLAY_DIR)" ]; then \
		mkdir -p "$(PLUGINS_DIR)"; \
		$(MAKE) -C "$(TVTPLAY_DIR)" HOST_SDK="$(CURDIR)" BUNDLE="$(PLUGIN)"; \
		/usr/bin/codesign --force --deep --sign - "$(PLUGIN)"; \
	else \
		echo "Note: Optional TvtPlay plugin not found at $(TVTPLAY_DIR); skipping (TVTest built-in player will be used)."; \
	fi

test:
	$(CMAKE) -S . -B "$(BUILD_DIR)" -DCMAKE_BUILD_TYPE=Release
	$(CMAKE) --build "$(BUILD_DIR)" --target TVTestRecordingSessionTests --parallel $(BUILD_JOBS)
	./$(BUILD_DIR)/TVTestRecordingSessionTests
	$(CMAKE) -S ../src/LibISDB -B "$(BUILD_DIR)/libisdb-tests" -DCMAKE_BUILD_TYPE=Debug
	$(CMAKE) --build "$(BUILD_DIR)/libisdb-tests" --target libisdbtest --parallel $(BUILD_JOBS)
	./$(BUILD_DIR)/libisdb-tests/Tests/libisdbtest

clean:
	rm -rf "$(BUILD_DIR)"
