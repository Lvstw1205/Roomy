#!/bin/bash
# Builds Roomy.app into ./dist. Usage: scripts/build-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.1}"
APP="dist/Roomy.app"

swift build -c release --product Roomy
BIN="$(swift build -c release --show-bin-path)/Roomy"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Roomy"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Roomy</string>
    <key>CFBundleDisplayName</key><string>Roomy</string>
    <key>CFBundleIdentifier</key><string>app.roomy.Roomy</string>
    <key>CFBundleExecutable</key><string>Roomy</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>Roomy looks for old installers, duplicates and large files on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Roomy looks for stale project dependencies, duplicates and large files in Documents.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Roomy looks for old installers, duplicates and large files in Downloads.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs it locally. Use a Developer ID to distribute.
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"
