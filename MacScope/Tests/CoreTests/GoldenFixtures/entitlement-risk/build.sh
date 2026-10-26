#!/bin/sh
# Build small arm64 Mach-O declarations for the read-only entitlement classifier.
set -eu
cd "$(dirname "$0")"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
make_case() {
  name="$1"
  options="$2"
  plist="$3"
  clang -std=c11 -O0 -Wall -Wextra -Werror -target arm64-apple-macos27.0 \
    -isysroot "$sdk" main.c -o "$name"
  if [ -n "$plist" ]; then
    if [ -n "$options" ]; then
      codesign --force --sign - --options runtime --generate-entitlement-der \
        --entitlements "$plist" "$name"
    else
      codesign --force --sign - --generate-entitlement-der --entitlements "$plist" "$name"
    fi
  elif [ -n "$options" ]; then
    codesign --force --sign - --options runtime "$name"
  else
    codesign --force --sign - "$name"
  fi
}
make_case runtime-off '' runtime-off.plist
make_case library-validation runtime library-validation.plist
make_case library-and-dyld runtime library-and-dyld.plist
make_case jit-only runtime jit-only.plist
make_case task-allow runtime task-allow.plist
make_case sandbox-exception runtime sandbox-exception.plist
make_case clean-runtime runtime ''
