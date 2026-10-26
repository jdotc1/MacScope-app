#!/bin/sh
set -eu
cd "$(dirname "$0")"

sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
target="arm64-apple-macos27.0"

for optimization in O1 O2; do
  /usr/bin/xcrun --sdk macosx clang -std=c11 "-$optimization" -g0 \
    -Wall -Wextra -Werror -Wno-format-security -fno-builtin \
    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
    -target "$target" -isysroot "$sdk" \
    -dynamiclib security_cases.c -o "security-c-arm64-$optimization"

  /usr/bin/xcrun --sdk macosx clang "-$optimization" -g0 \
    -Wall -Wextra -Werror -fobjc-arc -fno-objc-msgsend-selector-stubs \
    -target "$target" -isysroot "$sdk" -dynamiclib xpc_peer_trust.m \
    -framework Foundation -o "security-objc-arm64-$optimization"
done
