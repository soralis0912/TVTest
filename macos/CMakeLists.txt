cmake_minimum_required(VERSION 3.20)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum supported macOS version")
project(TVTestMac LANGUAGES CXX OBJCXX)

set(MACBONDRIVER_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../MacBonDriver/include"
    CACHE PATH "Path to MacBonDriver SDK include directory")

add_subdirectory(../src/LibISDB/LibISDB LibISDB)

add_executable(TVTest
    main.mm
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
set_target_properties(TVTest PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
target_compile_options(TVTest PRIVATE -fobjc-arc -Wall -Wextra)
target_include_directories(TVTest SYSTEM PRIVATE ../src/LibISDB/LibISDB "${MACBONDRIVER_INCLUDE_DIR}")
target_link_libraries(TVTest PRIVATE
    LibISDB
    "-framework AppKit"
    "-framework QuartzCore"
    "-framework UniformTypeIdentifiers"
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
    "-framework Foundation"
)
