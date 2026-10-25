import AppKit
import Foundation
import LumenTokens
import XCTest
@testable import LumenUI

/// An app pack with an editor surface, standing in for MacScope or any app with a second themed
/// surface. `syntax.keyword` is drawn by the editor, so it resolves through the editor's theme.
enum TestPack {
    static let editor = LumenSurface("editor")
    static let keyword: LumenToken = "syntax.keyword"

    static let pack = LumenPack(
        id: "test.app",
        tokens: [LumenTokenSpec(keyword, group: "Code", surface: editor, contrast: [.text(on: .bgCanvas)])],
        surfaces: [editor],
        themeValues: [
            LumenThemes.standardID: LumenThemeValues(light: [keyword: "#A0308A"], dark: [keyword: "#F28FD0"]),
            LumenThemes.midnightID: LumenThemeValues(dark: [keyword: "#E532AD"]),
            LumenThemes.contrastID: LumenThemeValues(light: [keyword: "#8A106E"], dark: [keyword: "#FFB0E6"]),
        ]
    )

    static let registry = LumenRegistry(packs: [.core, pack])

    /// A store that never touches user defaults or the real themes folder.
    static func store(registry: LumenRegistry = registry, themes: [LumenTheme]? = nil, folder: URL? = nil) -> LumenThemeStore {
        LumenThemeStore(registry: registry,
                        configuration: LumenStoreConfiguration(appName: "LumenTests",
                                                               themesDirectory: folder ?? URL(fileURLWithPath: "/dev/null/lumen-tests")),
                        themes: folder == nil ? (themes ?? registry.galleryThemes) : themes,
                        persistsSelection: false)
    }

    /// The Slate Sidebar example from the docs: a non-default theme with a dark sidebar.
    static var darkSidebarURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LumenUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appending(path: "Docs/examples/slate-sidebar.json")
    }
}

extension XCTestCase {
    /// A fresh folder under the temporary directory, removed after the test.
    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lumen-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func write(_ text: String, _ name: String, in folder: URL) throws {
        try Data(text.utf8).write(to: folder.appending(path: name))
    }

    /// `color` resolved in an AppKit appearance and converted to `space`.
    func resolve(_ color: NSColor, in appearance: NSAppearance.Name, space: NSColorSpace = .sRGB) throws -> NSColor {
        var resolved: NSColor?
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(space)
        }
        return try XCTUnwrap(resolved)
    }

    /// The color's sRGB components as hex, for readable assertions.
    func hex(_ color: NSColor, in appearance: NSAppearance.Name, space: NSColorSpace = .sRGB) throws -> String {
        let c = try resolve(color, in: appearance, space: space)
        return LumenColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent).hexString
    }
}

/// A flag Observation's `onChange` can set from any thread.
final class Flag: @unchecked Sendable {
    private let lock = LumenLock(0)
    var count: Int { lock.withLock { $0 } }
    func fire() { lock.withLock { $0 += 1 } }
}
