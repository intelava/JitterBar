#!/bin/zsh
# Compiles JitterBar.swift and wraps it in a dock-less JitterBar.app.
set -euo pipefail
cd "$(dirname "$0")"

APP=JitterBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "Compiling JitterBar.swift..."
swiftc -O -swift-version 5 JitterBar.swift -o "$APP/Contents/MacOS/JitterBar"

if [ -f "pixellab-A-16-bit-pixel-art-sprite-shee-1793572850083.png" ]; then
    cp "pixellab-A-16-bit-pixel-art-sprite-shee-1793572850083.png" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>JitterBar</string>
    <key>CFBundleIdentifier</key><string>dev.jitterbar.app</string>
    <key>CFBundleName</key><string>JitterBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP successfully! Run with: open $APP"
