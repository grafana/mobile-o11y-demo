cmake_minimum_required(VERSION 3.13)
project(quickpizza_ndk_crash)

add_library(quickpizza_ndk_crash SHARED quickpizza_ndk_crash.cpp)

find_library(log-lib log)
target_link_libraries(quickpizza_ndk_crash ${log-lib})
