{
  "schema_version": 1,
  "as_of": "2026-09-01",
  "purpose": "Bounded census of source/tool authority and accepted external inputs used by normal build/test/runtime surfaces.",
  "classification_rule": "Ghostty, SLEIGH, MachOKit, and XcodeGen resolve from governed repository inputs. External work roots contain verified derived outputs or read-only views and never establish source authority. Xcode, the macOS SDK/system frameworks, and LM Studio remain platform/tool/service inputs.",
  "surfaces": [
    {
      "id": "normal-bootstrap",
      "kind": "normal-build-entrypoint",
      "path": "Scripts/bootstrap.sh",
      "inputs": [
        {"id": "ghostty-vt-source", "class": "source-dependency", "manifest_component": "ghostty-vt", "authority": "repository", "resolution": "ThirdParty/GhosttyVT/Source"},
        {"id": "ghostty-surface-source", "class": "build-source", "manifest_component": "ghostty-surface", "authority": "repository", "resolution": "dependencies/build_vendored_ghostty_surface.sh"},
        {"id": "sleigh-native-source", "class": "source-dependency", "manifest_component": "sleigh-native-dcp03b4", "authority": "repository", "resolution": "ThirdParty/SleighNative"},
        {"id": "machokit-source", "class": "source-dependency", "manifest_component": "machokit-v2", "authority": "repository", "resolution": "ThirdParty/MachOKit/materialization"},
        {"id": "xcodegen-tool", "class": "build-tool", "manifest_component": "xcodegen-tool", "authority": "repository", "resolution": "ThirdParty/XcodeGen/bin/xcodegen"},
        {"id": "xcode-27-toolchain-and-macos-sdk", "class": "platform-toolchain", "manifest_component": null, "authority": "external", "resolution": "xcode27_env.sh"}
      ]
    },
    {
      "id": "normal-test",
      "kind": "normal-test-entrypoint",
      "path": "Scripts/test.sh",
      "inputs": [
        {"id": "normal-bootstrap-authority", "class": "repository-entrypoint", "manifest_component": null, "authority": "repository", "resolution": "bootstrap.sh"},
        {"id": "xcode-27-toolchain-and-macos-sdk", "class": "platform-toolchain", "manifest_component": null, "authority": "external", "resolution": "xcode27_env.sh"}
      ]
    },
    {
      "id": "normal-runtime",
      "kind": "product-runtime",
      "path": "MacScope/Services/Phase2/QualificationGate/Phase2QualificationGateRuntimeCollector.swift",
      "inputs": [
        {"id": "lm-studio-local-service", "class": "local-product-service", "manifest_component": null, "authority": "external", "resolution": "http://127.0.0.1:1234"}
      ]
    }
  ],
  "approved_source_components": ["rea-selected", "ghostty-vt", "ghostty-surface", "machokit-v2", "sleigh-native-dcp03b4", "swift-assembly-vendor", "zig-toolchain", "xcodegen-tool", "compiler-rt-signature-corpus", "pypcode-dcp03-proof", "libghidra-dcp03b3-pilot", "lief-parser-engine", "pe-parse-parser-engine", "go-macho-parser-engine", "corkami-pocs-pe-specimens", "binexport2-schema", "entitlements-comparison"],
  "ordered_blockers": [
    {"id": "DEP-REPOSITORY-SOURCE-AUTHORITY", "priority": 1, "status": "closed", "detail": "Normal bootstrap resolves governed Ghostty, SLEIGH, MachOKit, and XcodeGen inputs from the repository; generated external work roots and read-only views are outputs, not source authority."},
    {"id": "DEP-XCODEGEN-REPOSITORY-TOOL", "priority": 2, "status": "closed", "detail": "Bootstrap verifies and invokes the exact governed repository XcodeGen executable without PATH authority."},
    {"id": "DEP-PLATFORM-TOOLCHAIN", "priority": 3, "status": "accepted-platform-input", "detail": "Xcode 27, its bundled Swift/LLDB, and the macOS 27 SDK are required platform inputs and intentionally remain outside third-party source inventory."},
    {"id": "DEP-LM-STUDIO-SERVICE", "priority": 4, "status": "accepted-local-service-input", "detail": "LM Studio at loopback port 1234 is a product service classification, not a source dependency or vendored runtime."}
  ]
}
