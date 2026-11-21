cmake_minimum_required(VERSION 3.20)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum supported macOS version")
project(TVTestMac LANGUAGES CXX OBJCXX)

set(MACBONDRIVER_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../MacBonDriver/include"
    CACHE PATH "Path to MacBonDriver SDK include directory")
set(MACBONDRIVER_BUILD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../MacBonDriver/build"
    CACHE PATH "Path to built MacBonDriver .bundle directory")
set(TVCAS_MACOS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../TvCas/macos"
    CACHE PATH "Path to TvCas macOS directory")

add_subdirectory(../src/LibISDB/LibISDB LibISDB)
add_subdirectory("${TVCAS_MACOS_DIR}" TvCasMac)

add_executable(TVTest MACOSX_BUNDLE
    main.mm
    TVTestBuiltinPlayer.mm
    TVTestSettings.mm
    TSRecordingSession.mm
    LiveTunerSession.mm
    CaptionOverlayView.mm
    OSDOverlayView.mm
    SidePanelViewController.mm
    ProgramInfoWindowController.mm
    ProgramGuideWindowController.mm
    ProgramSearchWindowController.mm
    StreamInfoWindowController.mm
    PreferencesWindowController.mm
)
set_target_properties(TVTest PROPERTIES
    OBJCXX_STANDARD 20
    OBJCXX_STANDARD_REQUIRED YES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
)
target_compile_options(TVTest PRIVATE -fobjc-arc -Wall -Wextra)
target_include_directories(TVTest SYSTEM PRIVATE ../src/LibISDB/LibISDB "${MACBONDRIVER_INCLUDE_DIR}")
target_link_libraries(TVTest PRIVATE
    LibISDB
    tvcas_b25
    "-framework AppKit"
    "-framework QuartzCore"
    "-framework UniformTypeIdentifiers"
)

# Apply ad-hoc signing so TVTest.app launches cleanly on Apple Silicon macOS.
# MacBonDriver plugins (.bundle) live in ~/Library/Application Support/TVTest/BonDrivers/
# rather than inside TVTest.app.
add_custom_command(TARGET TVTest POST_BUILD
    COMMAND /usr/bin/codesign --force --deep --sign - "$<TARGET_BUNDLE_DIR:TVTest>"
    COMMENT "Signing TVTest.app"
)

add_executable(TVTestRecordingSessionTests
    RecordingSessionTests.mm
    TSRecordingSession.mm
    LiveTunerSession.mm
    TVTestSettings.mm
)
set_target_properties(TVTestRecordingSessionTests PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
target_compile_options(TVTestRecordingSessionTests PRIVATE -fobjc-arc -Wall -Wextra)
target_include_directories(TVTestRecordingSessionTests SYSTEM PRIVATE ../src/LibISDB/LibISDB "${MACBONDRIVER_INCLUDE_DIR}")
target_link_libraries(TVTestRecordingSessionTests PRIVATE
    LibISDB
    tvcas_b25
    "-framework Foundation"
)
