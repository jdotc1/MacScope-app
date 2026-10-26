#!/bin/sh
set -eu
cd "$(dirname "$0")"
base=Fixture.app/Contents
mkdir -p "$base/MacOS" "$base/XPCServices/FixtureService.xpc/Contents/MacOS" "$base/Library/LaunchServices" "$base/Library/LaunchDaemons" "$base/Library/LaunchAgents" "$base/Library/LoginItems/FixtureLogin.app/Contents/MacOS"
cat > "$base/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.fixture.host</string><key>CFBundleExecutable</key><string>FixtureHost</string><key>SMPrivilegedExecutables</key><dict><key>com.example.fixture.helper</key><string>identifier "com.example.fixture.helper"</string></dict></dict></plist>
PLIST
cat > "$base/XPCServices/FixtureService.xpc/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.fixture.service</string><key>CFBundleExecutable</key><string>FixtureService</string><key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>RunLoopType</key><string>NSRunLoop</string><key>JoinExistingSession</key><true/></dict></dict></plist>
PLIST
cat > info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.fixture.helper</string><key>CFBundleExecutable</key><string>FixtureHelper</string><key>SMAuthorizedClients</key><array><string>identifier "com.example.fixture.host"</string></array></dict></plist>
PLIST
cat > launchd.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>com.example.fixture.helper</string><key>MachServices</key><dict><key>com.example.fixture.control</key><true/><key>com.example.fixture.absent</key><true/></dict><key>Program</key><string>/Library/PrivilegedHelperTools/com.example.fixture.helper</string></dict></plist>
PLIST
cat > events-launchd.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>com.example.fixture.events</string><key>MachServices</key><dict><key>com.example.fixture.events</key><true/></dict><key>Program</key><string>/Library/PrivilegedHelperTools/com.example.fixture.events</string><key>SMAuthorizedClients</key><array><string>anchor apple generic and identifier "com.example.fixture.host"</string></array></dict></plist>
PLIST
clang -arch arm64 -O1 -fobjc-arc -framework Foundation host.m -o "$base/MacOS/FixtureHost"
clang -arch arm64 -O1 -fobjc-arc -framework Foundation host.m -o "$base/Library/LoginItems/FixtureLogin.app/Contents/MacOS/FixtureLogin"
clang -arch arm64 -O1 -fobjc-arc -framework Foundation service.m -o "$base/XPCServices/FixtureService.xpc/Contents/MacOS/FixtureService"
clang -arch arm64 -O1 -fobjc-arc -framework Foundation -sectcreate __TEXT __info_plist info.plist -sectcreate __TEXT __launchd_plist launchd.plist helper.m -o "$base/Library/LaunchServices/FixtureHelper"
clang -arch arm64 -O1 -fblocks -sectcreate __TEXT __launchd_plist events-launchd.plist libxpc.c -o "$base/Library/LaunchServices/FixtureEvents"
cat > "$base/Library/LaunchDaemons/com.example.fixture.agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>com.example.fixture.daemon</string><key>MachServices</key><dict><key>com.example.fixture.daemon</key><true/></dict><key>BundleProgram</key><string>Library/LaunchServices/FixtureHelper</string><key>AssociatedBundleIdentifiers</key><array><string>com.example.fixture.host</string></array></dict></plist>
PLIST
cat > "$base/Library/LaunchAgents/com.example.fixture.user.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>com.example.fixture.user</string><key>MachServices</key><dict><key>com.example.fixture.user</key><true/></dict><key>BundleProgram</key><string>MacOS/FixtureHost</string></dict></plist>
PLIST
cat > "$base/Library/LoginItems/FixtureLogin.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.fixture.login</string><key>CFBundleExecutable</key><string>FixtureLogin</string></dict></plist>
PLIST
codesign --force --sign - "$base/MacOS/FixtureHost" "$base/Library/LoginItems/FixtureLogin.app/Contents/MacOS/FixtureLogin" "$base/XPCServices/FixtureService.xpc/Contents/MacOS/FixtureService" "$base/Library/LaunchServices/FixtureHelper" "$base/Library/LaunchServices/FixtureEvents"
codesign --force --sign - "$base/XPCServices/FixtureService.xpc"
codesign --force --sign - "$base/Library/LoginItems/FixtureLogin.app"
codesign --force --sign - Fixture.app
