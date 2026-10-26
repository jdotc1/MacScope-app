#!/bin/sh
set -eu
cd "$(dirname "$0")"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
STAGE="$PWD/.stage"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Missing.framework" "$STAGE/Found.framework" "$STAGE/outside"
"$CC" -arch arm64 -isysroot "$SDK" -O1 -dynamiclib stub.c \
  -install_name '@rpath/Missing.framework/Missing' -o "$STAGE/Missing.framework/Missing"
"$CC" -arch arm64 -isysroot "$SDK" -O1 -dynamiclib stub.c \
  -install_name '/opt/example/libOutside.dylib' -o "$STAGE/outside/libOutside.dylib"
"$CC" -arch arm64 -isysroot "$SDK" -O1 -dynamiclib stub.c \
  -install_name '@rpath/Found.framework/Found' -Wl,-headerpad_max_install_names \
  -Wl,-reexport_library,"$STAGE/outside/libOutside.dylib" \
  -o "$STAGE/Found.framework/Found"
for name in ordinary hardened; do
  app="$PWD/$name.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks/Found.framework"
  cp "$STAGE/Found.framework/Found" "$app/Contents/Frameworks/Found.framework/Found"
  install_name_tool -id "@rpath/Wrong.framework/Wrong" "$app/Contents/Frameworks/Found.framework/Found"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>RiskFixture</string><key>CFBundleIdentifier</key><string>test.local.loadpath</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
  "$CC" -arch arm64 -isysroot "$SDK" -O1 main.c \
    -F "$STAGE" -framework Found -weak_framework Missing \
    -Wl,-rpath,/usr/local/lib \
    -Wl,-rpath,@executable_path/../Frameworks \
    -Wl,-rpath,relative/lib \
    -Wl,-dyld_env,DYLD_LIBRARY_PATH=/tmp/load-path-risk \
    -o "$app/Contents/MacOS/RiskFixture"
  if [ "$name" = hardened ]; then
    codesign --force --sign - --options runtime --timestamp=none "$app/Contents/Frameworks/Found.framework/Found"
    codesign --force --sign - --options runtime --timestamp=none "$app"
  else
    codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/Found.framework/Found"
    codesign --force --sign - --timestamp=none "$app"
  fi
done
