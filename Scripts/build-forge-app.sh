#!/bin/bash
# Builds a double-clickable Forge.app (release build) in the project folder.
#   Scripts/build-forge-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Forge
swift build -c release --product ForgeSnapshots

APP=Forge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Forge "$APP/Contents/MacOS/Forge"

# App icon: painted by Forge's own renderer, then scaled to every size macOS asks for.
WORK=$(mktemp -d)
ICONSET="$WORK/Forge.iconset"
mkdir -p "$ICONSET"
.build/release/ForgeSnapshots --icon "$WORK/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Forge.icns"
rm -rf "$WORK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Forge</string>
  <key>CFBundleDisplayName</key><string>Forge</string>
  <key>CFBundleIdentifier</key><string>com.silverninja71.forge</string>
  <key>CFBundleExecutable</key><string>Forge</string>
  <key>CFBundleIconFile</key><string>Forge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.silverninja71.forge.part</string>
      <key>UTTypeDescription</key><string>Forge Part</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>forge</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Forge Part</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key><array><string>com.silverninja71.forge.part</string></array>
      <key>LSTypeIsPackage</key><true/>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will run it locally.
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
