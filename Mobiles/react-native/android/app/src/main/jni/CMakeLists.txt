cmake_minimum_required(VERSION 3.13)

# RN New Architecture app modules (TurboModules, Fabric, autolinking).
project(appmodules)

include(${REACT_ANDROID_DIR}/cmake-utils/ReactNative-application.cmake)

# Separate JNI lib for the demo SIGSEGV button (System.loadLibrary in Kotlin).
add_library(quickpizza_ndk_crash SHARED quickpizza_ndk_crash.cpp)

find_library(log-lib log)
target_link_libraries(quickpizza_ndk_crash ${log-lib})
