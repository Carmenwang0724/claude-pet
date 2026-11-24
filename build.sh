#!/bin/sh
# Build ClaudePet.app from the Swift sources.
set -eu

# Locate the project
PROJECT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIRECTORY="$PROJECT_DIRECTORY/.build"
APP_DIRECTORY="$PROJECT_DIRECTORY/ClaudePet.app"
ARCHITECTURE="$(uname -m)"

# Compile every source file under Sources
mkdir -p "$BUILD_DIRECTORY"
find "$PROJECT_DIRECTORY/Sources" -name "*.swift" -print0 | xargs -0 swiftc -O -swift-version 5 \
    -target "$ARCHITECTURE-apple-macos13.0" \
    -o "$BUILD_DIRECTORY/ClaudePet"

# Assemble the app bundle
rm -rf "$APP_DIRECTORY"
mkdir -p "$APP_DIRECTORY/Contents/MacOS"
cp "$BUILD_DIRECTORY/ClaudePet" "$APP_DIRECTORY/Contents/MacOS/ClaudePet"
cp "$PROJECT_DIRECTORY/Resources/Info.plist" "$APP_DIRECTORY/Contents/Info.plist"

# Sign the bundle for local use
codesign --force --sign - "$APP_DIRECTORY"
echo "Built $APP_DIRECTORY"
