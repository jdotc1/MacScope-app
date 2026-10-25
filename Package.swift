// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacScope",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacScope", targets: ["MacScope"]),
        .library(name: "LumenTokens", targets: ["LumenTokens"]),
        .library(name: "LumenUI", targets: ["LumenUI"]),
        .library(name: "LumenConformance", targets: ["LumenConformance"]),
        .library(name: "MacScopeTheme", targets: ["MacScopeTheme"]),
        .library(name: "MacScopeShell", targets: ["MacScopeShell"]),
        .executable(name: "lumen-theme", targets: ["lumen-theme"]),
        .executable(name: "LumenCatalog", targets: ["LumenCatalog"]),
    ],
    targets: [
        // The MacScope app: the workspace window, menus and Settings, on synthetic data.
        .executableTarget(name: "MacScope", dependencies: ["MacScopeShell", "MacScopeTheme", "LumenTokens", "LumenUI"]),
        // MacScope's workspace window built from public Lumen API with synthetic data.
        .target(name: "MacScopeShell", dependencies: ["LumenTokens", "LumenUI"]),
        // MacScope's pack: its domain color roles, three built-in themes and rules.
        .target(name: "MacScopeTheme", dependencies: ["LumenTokens"]),
        // Tokens, themes, the validator and export: plain Swift, no UI.
        .target(name: "LumenTokens"),
        // SwiftUI and AppKit: the theme store, palette environment, scales, components, and the
        // theme gallery, editor and library.
        // Resources: Lumen's custom SF Symbols (an asset catalog of symbol templates).
        .target(name: "LumenUI", dependencies: ["LumenTokens"], resources: [.process("Resources")]),
        // Design-rule checks an app runs in its own tests: themes, layout, shortcuts, coverage.
        // For test targets only; an app's product never links it.
        .target(name: "LumenConformance", dependencies: ["LumenTokens", "LumenUI"]),
        // Validates theme files and exports the reference artifacts from the command line.
        .executableTarget(name: "lumen-theme", dependencies: ["LumenTokens"]),
        // Every component in a real Mac app, including native menus and the Settings window.
        .executableTarget(name: "LumenCatalog", dependencies: ["LumenTokens", "LumenUI", "MacScopeShell"]),
        .testTarget(name: "LumenTokensTests", dependencies: ["LumenTokens"]),
        .testTarget(name: "MacScopeThemeTests", dependencies: ["MacScopeTheme", "LumenConformance"],
                    resources: [.copy("macscope-expected.json")]),
        // LumenConformance: the golden views also pass the design-rule checks.
        .testTarget(name: "LumenUITests", dependencies: ["LumenUI", "LumenConformance"], exclude: ["Goldens"]),
        // The Catalog's windows never cut their content off: each page fits its column's minimum.
        .testTarget(name: "LumenConformanceTests", dependencies: ["LumenConformance", "LumenUI", "LumenTokens"]),
        .testTarget(name: "LumenCatalogTests", dependencies: ["LumenCatalog", "MacScopeShell", "LumenUI", "LumenConformance"]),
    ],
    swiftLanguageModes: [.v6]
)
