#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build/release /tmp/clang-module-cache
swiftc -O -target arm64-apple-macosx14.4 \
    -module-cache-path /tmp/clang-module-cache \
    Sources/airpods/*.swift \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/airpods/Info.plist \
    -o .build/release/airpods

BIN=".build/release/airpods"
APP="airpods.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/airpods"
cp "Sources/airpods/Info.plist" "$APP/Contents/Info.plist"
if [ -d "Sources/airpods/Resources" ]; then
    cp -R "Sources/airpods/Resources/." "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run: ./airpods.app/Contents/MacOS/airpods"
