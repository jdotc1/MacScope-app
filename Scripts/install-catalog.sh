#!/bin/bash
# Builds Lumen Catalog in release and installs it as /Applications/Lumen Catalog.app, with the
# Liquid Glass icon compiled from Design/LumenCatalog.icon (light, dark, clear and tinted).
# usage: Scripts/install-catalog.sh [scratch-path]
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${1:-${LUMEN_SCRATCH:-.build}}"
APP="/Applications/Lumen Catalog.app"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
VERSION="${VERSION:-0.1.0}"
if pgrep -x LumenCatalog >/dev/null; then
  echo "error: Lumen Catalog is running; quit it before installing." >&2
  exit 1
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build -c release --scratch-path "$SCRATCH" --product LumenCatalog
xcrun actool Design/LumenCatalog.icon --compile "$WORK" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon LumenCatalog --output-partial-info-plist "$WORK/partial.plist" > /dev/null

BUNDLE="$WORK/Lumen Catalog.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$SCRATCH/release/LumenCatalog" "$BUNDLE/Contents/MacOS/LumenCatalog"
cp "$WORK/Assets.car" "$WORK/LumenCatalog.icns" "$BUNDLE/Contents/Resources/"
# LumenUI's resource bundle (its custom SF Symbols); Bundle.module looks for it in Resources.
for resources in "$SCRATCH"/release/*.bundle; do
  [ -d "$resources" ] && cp -R "$resources" "$BUNDLE/Contents/Resources/"
done
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.lumen.lumen.catalog</string>
<key>CFBundleName</key><string>Lumen Catalog</string>
<key>CFBundleDisplayName</key><string>Lumen Catalog</string>
<key>CFBundleExecutable</key><string>LumenCatalog</string>
<key>CFBundleIconFile</key><string>LumenCatalog</string>
<key>CFBundleIconName</key><string>LumenCatalog</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${VERSION}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$BUNDLE"

if pgrep -x LumenCatalog >/dev/null; then
  echo "error: Lumen Catalog started during the build; installation skipped." >&2
  exit 1
fi
rm -rf "$APP"
cp -R "$BUNDLE" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Installed $APP ($VERSION)"
