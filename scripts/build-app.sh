#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
mkdir -p "build/AI Usage.app/Contents/MacOS" "build/AI Usage.app/Contents/Resources"
cp .build/release/AIUsage "build/AI Usage.app/Contents/MacOS/AIUsage"
ditto .build/release/AIUsage_AIUsage.bundle "build/AI Usage.app/Contents/Resources/AIUsage_AIUsage.bundle"
iconset="build/AppIcon.iconset"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
  sips -z "$points" "$points" Assets/AppIcon.png --out "$iconset/icon_${points}x${points}.png" >/dev/null
  pixels=$((points * 2))
  sips -z "$pixels" "$pixels" Assets/AppIcon.png --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "build/AI Usage.app/Contents/Resources/AppIcon.icns"
cat > "build/AI Usage.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIUsage</string>
<key>CFBundleIdentifier</key><string>com.tommy.aiusage</string>
<key>CFBundleName</key><string>AI Usage</string>
<key>CFBundleDisplayName</key><string>AI Usage</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleShortVersionString</key><string>0.2.5</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "build/AI Usage.app"
print "Built: $PWD/build/AI Usage.app"
