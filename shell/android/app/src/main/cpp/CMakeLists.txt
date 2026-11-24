cmake_minimum_required(VERSION 3.22.1)
project(freeplayer_cenc LANGUAGES CXX)

# The same portable CENC implementation the desktop DLL uses. On Android the
# AES core comes from native/cenc/aes128.h instead of Windows CNG, and the
# fp_cenc_* exports are the ABI DecryptProxy already binds through dart:ffi.
add_library(
    cenc_decrypt
    SHARED
    ../../../../../../native/cenc/cenc.cpp
    cenc_jni.cpp
)

target_compile_features(cenc_decrypt PRIVATE cxx_std_17)
target_compile_options(cenc_decrypt PRIVATE -O2)
set_target_properties(
    cenc_decrypt
    PROPERTIES
        OUTPUT_NAME "cenc_decrypt"
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON
        # Self-contained: no libc++_shared.so to ship beside it.
        ANDROID_STL "c++_static"
)

# JNI adapter for the vendor ByteVC2 (VVC) decoder. The vendor library lives
# in jniLibs; this bridge only dlopens it and exposes the small JNI surface
# used by Bvc2Native.java.
add_library(
    freeplayer_bvc2
    SHARED
    bvc2_bridge.cpp
)

target_compile_features(freeplayer_bvc2 PRIVATE cxx_std_17)
target_compile_options(freeplayer_bvc2 PRIVATE -O2)
target_link_libraries(freeplayer_bvc2 android dl log)
set_target_properties(
    freeplayer_bvc2
    PROPERTIES
        OUTPUT_NAME "freeplayer_bvc2"
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON
        ANDROID_STL "c++_static"
)
