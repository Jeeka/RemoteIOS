#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PLATFORM="${1:-OS64}"
SOURCE="$(python3 scripts/prepare.py)"
BUILD="$PWD/.build/device"
if [[ "$PLATFORM" == SIMULATORARM64 ]]; then BUILD="$PWD/.build/simulator"; fi
cmake -S "$SOURCE/client/iOS" -B "$BUILD" -G Xcode \
  -DCMAKE_TOOLCHAIN_FILE="$SOURCE/cmake/ios.toolchain.cmake" \
  -DPLATFORM="$PLATFORM" -DDEPLOYMENT_TARGET=16.0 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_CONFIGURATION_TYPES=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY= \
  -DWITH_FFMPEG=OFF -DWITH_OPENH264=OFF -DWITH_OPUS=OFF \
  -DWITH_PNG=OFF -DWITH_WEBP=OFF -DWITH_JPEG=OFF
cmake --build "$BUILD" --config Release --parallel 3
if [[ "$PLATFORM" == OS64 ]]; then python3 scripts/package.py "$BUILD/Release-iphoneos/iFreeRDP.app"; fi
