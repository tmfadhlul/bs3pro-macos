#!/bin/bash
# Builds a universal (Intel + Apple Silicon) BS3Pro.app and BS3Pro.dmg. Needs only Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/BS3Pro.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos13 BS3Pro.swift Sensors.swift -o build/BS3Pro-$arch
done
lipo -create build/BS3Pro-arm64 build/BS3Pro-x86_64 -output "$APP/Contents/MacOS/BS3Pro"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BS3Pro</string>
  <key>CFBundleDisplayName</key><string>BS3 Pro Control</string>
  <key>CFBundleIdentifier</key><string>dev.local.bs3pro</string>
  <key>CFBundleExecutable</key><string>BS3Pro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF

codesign --force --deep -s - "$APP"
"$APP/Contents/MacOS/BS3Pro" --selftest

mkdir build/dmg && cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "BS3 Pro Control" -srcfolder build/dmg -format UDZO -ov build/BS3Pro.dmg
lipo -info "$APP/Contents/MacOS/BS3Pro"
echo "built build/BS3Pro.dmg"
