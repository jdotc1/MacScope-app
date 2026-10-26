#!/bin/zsh
# Shared offline SwiftPM harness. Retained receipts/builds live outside the checkout.
# Git-checkout-only developer tooling: Git-less sealed source exports are not supported.
# The committed gitlink, not a working-tree package or a second pin, is the authority.
set -euo pipefail
export GIT_NO_REPLACE_OBJECTS=1
(( $# == 3 )) || { print -u2 "usage: $0 export|snapshots REPOSITORY OUTPUT"; exit 2; }
MODE="$1"
REPO="$2"
OUT="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/work_root.sh"
case "$MODE" in export|snapshots) ;; *) print -u2 "unsupported mode: $MODE"; exit 2 ;; esac
PIN="$(git -C "$REPO" ls-tree HEAD ThirdParty/Lumen | awk '$1 == "160000" {print $3}')"
[[ -n "$PIN" ]] ||
  { print -u2 "This developer tool requires a Git checkout with a committed ThirdParty/Lumen gitlink; Git-less sealed exports are unsupported."; exit 1; }
LUMEN_SOURCE="${MACSCOPE_LUMEN_SOURCE_DIR:-$REPO/ThirdParty/Lumen}"
# An alternate local clone is permitted, but only immutable committed source is materialized.
git -C "$LUMEN_SOURCE" cat-file -e "$PIN^{commit}" 2>/dev/null ||
  { print -u2 "Pinned Lumen commit $PIN is unavailable locally at $LUMEN_SOURCE. Materialize the approved dependency explicitly first."; exit 1; }
WORK_ROOT="$(macscope_work_root "$REPO")/design-tool-runs"
mkdir -p "$WORK_ROOT"
WORK="$(mktemp -d "$WORK_ROOT/$MODE.XXXXXX")"
print "Design tool harness: $WORK"
mkdir -p "$WORK/Lumen" "$WORK/Sources/DesignTool"
git -C "$LUMEN_SOURCE" archive "$PIN" | tar -x -C "$WORK/Lumen"
print "$PIN" > "$WORK/lumen-revision.txt"
cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "MacScopeDesignTools", platforms: [.macOS("27.0")],
    dependencies: [.package(path: "Lumen")],
    targets: [.executableTarget(name: "DesignTool",
        dependencies: [.product(name: "LumenTokens", package: "Lumen"),
                       .product(name: "LumenUI", package: "Lumen")],
        swiftSettings: [.define("DS_SNAPSHOT_STANDALONE")])],
    swiftLanguageModes: [.v6])
SWIFT
DS="$REPO/MacScope/DesignSystem"
SOURCE_FILES=(DSTheme.swift DSBuiltInThemes.swift Lumen/MacScopePack.swift)
if [[ "$MODE" == export ]]; then
  SOURCE_FILES+=(DSTokenExport.swift)
else
  SOURCE_FILES+=(DSLumenPreferences.swift DSThemeStore.swift DSTokens.swift DSPaletteEnvironment.swift DSComponents.swift
    DSIcon.swift DSInspector.swift DSThemeEditor.swift DSThemeLibrary.swift DSGraph.swift)
  ln -s "$REPO/MacScope/Tests/CoreTests/DSSnapshot.swift" "$WORK/Sources/DesignTool/DSSnapshot.swift"
  ln -s "$REPO/MacScope/App/Localization/DSTheme+DisplayName.swift" "$WORK/Sources/DesignTool/DSTheme+DisplayName.swift"
  LABEL_WIDTH="$(sed -n 's/.*static let metadataLabelWidth: CGFloat = \([0-9.]*\).*/\1/p' "$DS/AppDesignSystem.swift")"
  [[ "$LABEL_WIDTH" == <->(|.<->) ]] ||
    { print -u2 "Could not read exactly one numeric metadataLabelWidth"; exit 1; }
  printf 'import CoreGraphics\nenum AppInspectorChrome { static let metadataLabelWidth: CGFloat = %s }\n' "$LABEL_WIDTH" > "$WORK/Sources/DesignTool/Stubs.swift"
fi
for SOURCE in "${SOURCE_FILES[@]}"; do
  [[ -f "$DS/$SOURCE" ]] || { print -u2 "Missing design source: $DS/$SOURCE"; exit 1; }
  ln -s "$DS/$SOURCE" "$WORK/Sources/DesignTool/${SOURCE:t}"
done
ln -s "$SCRIPT_DIR/$MODE-main.swift" "$WORK/Sources/DesignTool/main.swift"
# The complete pinned graph has no remote dependencies. Refuse automatic resolution.
xcrun swift build --package-path "$WORK" --scratch-path "$WORK/build" --disable-sandbox --disable-automatic-resolution --product DesignTool
[[ "${MACSCOPE_DESIGN_BUILD_ONLY:-0}" == 1 ]] && exit 0
BIN="$(xcrun swift build --package-path "$WORK" --scratch-path "$WORK/build" --show-bin-path)"
"$BIN/DesignTool" "$OUT"
