cmake_minimum_required(VERSION 3.21)

# ---- Apple Development Team ---------------------------------------------------------
# Priority: local.cmake > env var APPLE_DEVELOPMENT_TEAM > empty (manual Xcode setup)
# local.cmake is gitignored — create it with: set(APPLE_DEVELOPMENT_TEAM "XXXXXXXXXX")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/local.cmake")
    include("${CMAKE_CURRENT_SOURCE_DIR}/local.cmake")
endif()
if(NOT DEFINED APPLE_DEVELOPMENT_TEAM AND DEFINED ENV{APPLE_DEVELOPMENT_TEAM})
    set(APPLE_DEVELOPMENT_TEAM "$ENV{APPLE_DEVELOPMENT_TEAM}")
endif()
if(NOT DEFINED APPLE_DEVELOPMENT_TEAM)
    set(APPLE_DEVELOPMENT_TEAM "")
endif()

# ---- vcpkg toolchain (must be set before project()) --------------------------------
# Auto-detect vcpkg submodule and activate its toolchain.
# Honors an explicit -DCMAKE_TOOLCHAIN_FILE=... override if already provided.
if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    set(CMAKE_TOOLCHAIN_FILE
        "${CMAKE_CURRENT_SOURCE_DIR}/vcpkg/scripts/buildsystems/vcpkg.cmake"
        CACHE STRING "vcpkg toolchain")
endif()

# iOS triplet: arm64-ios (device) or arm64-ios-simulator (simulator).
# Override on the cmake command line with -DVCPKG_TARGET_TRIPLET=arm64-ios-simulator
if(NOT DEFINED VCPKG_TARGET_TRIPLET)
    set(VCPKG_TARGET_TRIPLET "arm64-ios" CACHE STRING "vcpkg target triplet")
endif()

project(RmlUiIPhone
    VERSION 0.1
    LANGUAGES CXX OBJCXX C
)

# ---- Require iOS target -------------------------------------------------------------
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(WARNING "This CMakeLists is designed for iOS. "
            "Pass -DCMAKE_SYSTEM_NAME=iOS to cmake.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---- RmlUi (static, no samples, no backend) ----------------------------------------
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
set(RMLUI_SAMPLES          OFF CACHE BOOL "" FORCE)
set(RMLUI_BACKEND          "auto" CACHE STRING "" FORCE)
set(RMLUI_FONT_ENGINE      "freetype" CACHE STRING "" FORCE)

add_subdirectory(RmlUi)

# ---- App target --------------------------------------------------------------------
set(APP_SOURCES
    App/main.mm
    App/AppDelegate.mm
    App/RmlViewController.mm

    Backends/RmlUi_Renderer_Metal.mm
    Backends/RmlUi_Platform_iOS.mm
    Backends/RmlUi_Backend_iOS_Metal.mm
    # Shaders/RmlUi.metal — kept as reference only; source is embedded in Renderer_Metal.mm
)

set(APP_HEADERS
    App/AppDelegate.h
    App/RmlViewController.h

    Backends/RmlUi_Renderer_Metal.h
    Backends/RmlUi_Platform_iOS.h
    Backends/RmlUi_Backend_iOS_Metal.h
)

set(APP_RESOURCES
    App/Assets/demo.rml
    App/Assets/LatoLatin-Regular.ttf
)

add_executable(RmlUiIPhone MACOSX_BUNDLE
    ${APP_SOURCES}
    ${APP_HEADERS}
    ${APP_RESOURCES}
)

# Mark resource files so Xcode copies them into the bundle
set_source_files_properties(${APP_RESOURCES} PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources
)

# Metal shader compilation is automatic in Xcode when .metal files are in the target.

target_include_directories(RmlUiIPhone PRIVATE
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/Backends
    ${CMAKE_SOURCE_DIR}/App
    ${CMAKE_SOURCE_DIR}/RmlUi/Include
)

target_link_libraries(RmlUiIPhone PRIVATE
    RmlUi::Core
    "-framework Metal"
    "-framework MetalKit"
    "-framework UIKit"
    "-framework QuartzCore"
    "-framework Foundation"
    "-framework CoreGraphics"
    "-framework CoreText"
)

# ---- Xcode / bundle settings -------------------------------------------------------
set_target_properties(RmlUiIPhone PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.example.RmlUiIPhone"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/App/Info.plist"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.example.RmlUiIPhone"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"   # 1 = iPhone, 2 = iPad, 1,2 = both
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "15.0"
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "iPhone Developer"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${APPLE_DEVELOPMENT_TEAM}"
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"
)
