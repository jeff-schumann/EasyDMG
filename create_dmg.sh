#!/bin/bash

# Create DMG for EasyDMG distribution
# Usage: ./create_dmg.sh

set -e

# Configuration
APP_NAME="EasyDMG"
VERSION="1.0.2"
BUILD_DIR="$HOME/Library/Developer/Xcode/DerivedData/EasyDMG-dibggcaewvrasrcrtvhemiwxucou/Build/Products/Release"
DMG_NAME="${APP_NAME}_v${VERSION}"
TEMP_DIR="/tmp/${APP_NAME}_dmg"
OUTPUT_DMG="./${DMG_NAME}.dmg"

echo "📦 Creating DMG for ${APP_NAME} ${VERSION}..."

# Clean up any existing temp directory and output DMG
rm -rf "$TEMP_DIR"
rm -f "$OUTPUT_DMG"

# Create temporary directory
mkdir -p "$TEMP_DIR"

# Copy the app bundle
echo "📋 Copying ${APP_NAME}.app..."
cp -R "${BUILD_DIR}/${APP_NAME}.app" "$TEMP_DIR/"

# Create Applications symlink for easy drag-and-drop installation
echo "🔗 Creating Applications symlink..."
ln -s /Applications "$TEMP_DIR/Applications"

# Create DMG
echo "💿 Creating DMG..."
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "$TEMP_DIR" \
    -ov -format UDZO \
    "$OUTPUT_DMG"

# Clean up
rm -rf "$TEMP_DIR"

# Get DMG size
DMG_SIZE=$(stat -f%z "$OUTPUT_DMG")

echo ""
echo "✅ DMG created successfully!"
echo "📍 Location: $OUTPUT_DMG"
echo "📏 Size: $DMG_SIZE bytes"
echo ""
echo "Next steps:"
echo "1. Sign and notarize the DMG (if distributing outside App Store)"
echo "2. Generate Sparkle signature: sign_update \"$OUTPUT_DMG\""
echo "3. Upload to GitHub Release"
