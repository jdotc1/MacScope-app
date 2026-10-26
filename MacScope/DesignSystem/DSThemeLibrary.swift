import Foundation
import LumenTokens
import LumenUI

extension DSThemeStore {
    static let maximumThemeFileSize = LumenThemeLibrary.maximumThemeFileSize
    static func refusal(for url: URL) -> String? { LumenThemeLibrary.refusal(for: url) }
    static func loadUserThemeLibrary(from directory: URL) -> LumenUserThemeLibrary {
        LumenThemeLibrary.load(from: directory, registry: MacScopeLumen.registry)
    }
    static func loadUserThemes(from directory: URL = userThemesDirectory) -> [LumenTheme] {
        loadUserThemeLibrary(from: directory).themes
    }
    static func resolvingInheritance(_ themes: [(LumenTheme, URL?)]) -> LumenUserThemeLibrary {
        LumenThemeLibrary.resolvingInheritance(themes, registry: MacScopeLumen.registry)
    }
    static func resolvingInheritance(_ themes: [LumenTheme]) -> [LumenTheme] {
        resolvingInheritance(themes.map { ($0, nil) }).themes
    }
    static func decodeTheme(_ data: Data) throws -> LumenTheme { try LumenThemeLibrary.decodeTheme(data) }
    static func encodeTheme(_ theme: LumenTheme) throws -> Data { try LumenThemeLibrary.encodeTheme(theme) }
    static func fileSlug(_ id: String) -> String { LumenThemeLibrary.fileSlug(id) }
    static func themeFolderFingerprint(_ directory: URL) -> [String] { LumenThemeLibrary.folderFingerprint(directory) }
    @discardableResult func importTheme(from source: URL) throws -> LumenTheme { try lumen.importTheme(from: source) }
    @discardableResult func duplicate(_ theme: LumenTheme) throws -> URL { try lumen.duplicate(theme) }
    @discardableResult func writeNewTheme(_ theme: LumenTheme) throws -> URL { try lumen.writeNewTheme(theme) }
    func moveUserThemeToTrash(_ id: LumenTheme.ID,
        remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        try lumen.moveUserThemeToTrash(id, remove: remove)
    }
}
