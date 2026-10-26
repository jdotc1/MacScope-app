import Foundation
import LumenTokens
import LumenUI
import XCTest
@testable import MacScope

/// User theme library: every store here works in a temporary folder, never the real
/// Application Support themes folder.
final class DSThemeLibraryTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ds-themes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ json: String, _ name: String, in folder: URL) throws {
        try Data(json.utf8).write(to: folder.appending(path: name))
    }

    private let partial = ##"{"id": "user.calm", "name": "Calm", "inherits": "com.macscope.theme.scope", "light": {"accent.default": "#2F6FDE"}}"##

    func testLibraryReportsEveryFileThatFailsToLoad() throws {
        let folder = try temporaryFolder()
        try write(partial, "a-calm.json", in: folder)
        try write(##"{"id": "user.calm", "name": "Calm again", "inherits": "com.macscope.theme.scope"}"##, "b-duplicate.json", in: folder)
        try write("not json", "c-garbage.json", in: folder)
        try write(##"{"id": "user.nameless"}"##, "d-nameless.json", in: folder)
        try write(##"{"id": "com.macscope.theme.scope", "name": "Fake Scope", "inherits": "com.macscope.theme.midnight"}"##, "e-reserved.json", in: folder)
        try write(##"{"id": "user.future", "name": "Future", "schemaVersion": 99}"##, "f-future.json", in: folder)
        try write(##"{"id": "user.orphan", "name": "Orphan", "inherits": "user.missing"}"##, "g-orphan.json", in: folder)
        try write("{}", "notes.txt", in: folder)

        let library = DSThemeStore.loadUserThemeLibrary(from: folder)

        XCTAssertEqual(library.themes.map(\.id), ["user.calm"])
        XCTAssertEqual(library.files["user.calm"]?.lastPathComponent, "a-calm.json")
        XCTAssertNil(library.themes.first?.inherits, "Loaded themes are flattened")
        let reasons = Dictionary(uniqueKeysWithValues: library.problems.map { ($0.file, $0.reason) })
        XCTAssertEqual(Set(reasons.keys), ["b-duplicate.json", "c-garbage.json", "d-nameless.json",
                                           "e-reserved.json", "f-future.json", "g-orphan.json"])
        XCTAssertTrue(reasons["b-duplicate.json"]?.contains("already uses the id user.calm") == true)
        XCTAssertTrue(reasons["d-nameless.json"]?.contains("“name” is missing") == true)
        XCTAssertTrue(reasons["e-reserved.json"]?.contains("built-in") == true)
        XCTAssertTrue(reasons["f-future.json"]?.contains("newer version") == true)
        XCTAssertTrue(reasons["f-future.json"]?.contains("99") == true)
        XCTAssertTrue(reasons["g-orphan.json"]?.contains("user.missing") == true)
    }

    func testImportCopiesIntoTheFolderSelectsAndNeverReplaces() throws {
        let folder = try temporaryFolder(), downloads = try temporaryFolder()
        try write(partial, "Calm.json", in: downloads)
        let store = DSThemeStore(persistsSelection: false, themesDirectory: folder)

        let first = try store.importTheme(from: downloads.appending(path: "Calm.json"))
        XCTAssertEqual(first.id, "user.calm")
        XCTAssertEqual(store.theme.id, "user.calm")
        XCTAssertEqual(store.theme.hex(.accent, for: .light).hexString, "#2F6FDE")

        let second = try store.importTheme(from: downloads.appending(path: "Calm.json"))
        XCTAssertEqual(second.id, "user.calm-2")
        XCTAssertEqual(second.name, "Calm 2")
        XCTAssertEqual(Set(store.themes.map(\.id)).isSuperset(of: ["user.calm", "user.calm-2"]), true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).count, 2)
    }

    func testEditorSavePreservesExistingFilesWithDifferentIDsOrInvalidContents() throws {
        for original in [partial.replacingOccurrences(of: "user.calm", with: "user.other"), "unfinished JSON"] {
            let folder = try temporaryFolder()
            let occupied = folder.appending(path: "user.calm.json")
            try Data(original.utf8).write(to: occupied)
            let store = DSThemeStore(persistsSelection: false, themesDirectory: folder)

            let saved = try store.saveUserTheme(name: "Calm", inheriting: DSBuiltInThemes.scope, overrides: [:])

            XCTAssertNotEqual(saved, occupied)
            XCTAssertEqual(try Data(contentsOf: occupied), Data(original.utf8))
            XCTAssertEqual(try DSThemeStore.decodeTheme(Data(contentsOf: saved)).id, "user.calm")
            XCTAssertEqual(store.theme.id, "user.calm")
        }
    }

    func testDuplicatePreservesExistingFilesWithDifferentIDsOrInvalidContents() throws {
        for original in [partial, "unfinished JSON"] {
            let folder = try temporaryFolder()
            let occupied = folder.appending(path: "user.scope.copy1.json")
            try Data(original.utf8).write(to: occupied)
            let store = DSThemeStore(persistsSelection: false, themesDirectory: folder)

            let saved = try store.duplicate(DSBuiltInThemes.scope)

            XCTAssertNotEqual(saved, occupied)
            XCTAssertEqual(try Data(contentsOf: occupied), Data(original.utf8))
            XCTAssertEqual(store.theme.id, "user.scope.copy1")
            XCTAssertEqual(try DSThemeStore.decodeTheme(Data(contentsOf: saved)).id, store.theme.id)
        }
    }

    func testImportPreservesAFileCreatedAfterTheStoreLoaded() throws {
        let folder = try temporaryFolder(), downloads = try temporaryFolder()
        let store = DSThemeStore(persistsSelection: false, themesDirectory: folder)
        let occupied = folder.appending(path: "user.calm.json")
        let original = Data("unfinished JSON".utf8)
        try original.write(to: occupied)
        try write(partial, "Calm.json", in: downloads)

        let imported = try store.importTheme(from: downloads.appending(path: "Calm.json"))

        XCTAssertEqual(try Data(contentsOf: occupied), original)
        XCTAssertNotEqual(store.userThemeFile(for: imported.id), occupied)
        XCTAssertEqual(store.theme.id, imported.id)
    }

    func testNewThemePublicationPreservesDanglingSymlinksAndCleansTemporaryFiles() throws {
        let folder = try temporaryFolder()
        let occupied = folder.appending(path: "user.calm.json")
        let missingTarget = folder.appending(path: "missing.json")
        try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: missingTarget)
        let store = DSThemeStore(persistsSelection: false, themesDirectory: folder)

        let saved = try store.saveUserTheme(name: "Calm", inheriting: DSBuiltInThemes.scope, overrides: [:])

        XCTAssertNotEqual(saved, occupied)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path), missingTarget.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                       ["user.calm.json", saved.lastPathComponent])
    }

    func testImportRejectsWhatCannotLoad() throws {
        let folder = try temporaryFolder(), downloads = try temporaryFolder()
        let store = DSThemeStore(persistsSelection: false, themesDirectory: folder)
        try write(##"{"id": "user.orphan", "name": "Orphan", "inherits": "user.missing"}"##, "orphan.json", in: downloads)
        try write(##"{"id": "user.future", "name": "Future", "schemaVersion": 99}"##, "future.json", in: downloads)

        XCTAssertThrowsError(try store.importTheme(from: downloads.appending(path: "orphan.json"))) { error in
            XCTAssertEqual(error as? LumenThemeImportError, .inheritance("inherits unknown theme user.missing"))
        }
        XCTAssertThrowsError(try store.importTheme(from: downloads.appending(path: "future.json"))) { error in
            XCTAssertEqual(error as? LumenThemeImportError, .newerSchema(99))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)), [],
                       "A rejected import writes nothing")
    }

    func testAnExportedBuiltInImportsAsTheUsersOwnTheme() throws {
        let folder = try temporaryFolder(), downloads = try temporaryFolder()
        try LumenThemeFile(DSBuiltInThemes.midnight).data().write(to: downloads.appending(path: "Midnight.json"))
        let store = DSThemeStore(persistsSelection: false, themesDirectory: folder)
        let imported = try store.importTheme(from: downloads.appending(path: "Midnight.json"))
        XCTAssertEqual(imported.id, "user.midnight", "Never an id in the built-in namespace")
        XCTAssertEqual(store.theme.hex(.bgCanvas, for: .dark), DSBuiltInThemes.midnight.hex(.bgCanvas, for: .dark))
    }

    func testFolderFingerprintIgnoresNonThemeFiles() throws {
        let folder = try temporaryFolder()
        try write(partial, "calm.json", in: folder)
        let before = DSThemeStore.themeFolderFingerprint(folder)
        try write("x", ".DS_Store", in: folder)
        try write("notes", "README.txt", in: folder)
        XCTAssertEqual(DSThemeStore.themeFolderFingerprint(folder), before)
        try write(partial.replacingOccurrences(of: "Calm", with: "Calmer"), "calm.json", in: folder)
        XCTAssertNotEqual(DSThemeStore.themeFolderFingerprint(folder), before)
    }

    func testDecoderRejectsWhatTheSchemaRejects() {
        let cases: [(String, String)] = [
            (##"{"id": "", "name": "Empty id", "inherits": "com.macscope.theme.scope"}"##, "“id” is empty"),
            (##"{"id": "user.x", "name": " ", "inherits": "com.macscope.theme.scope"}"##, "“name” is empty"),
            (##"{"id": "user.x", "name": "No colors"}"##, "needs a “light” or “dark” palette"),
            (##"{"id": "user.x", "name": "Bare hex", "light": {"accent.default": "2F6FDE"}}"##, "#RRGGBB"),
            (##"{"id": "user.x", "name": "Zero", "schemaVersion": 0, "inherits": "com.macscope.theme.scope"}"##, "schemaVersion"),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try DSThemeStore.decodeTheme(Data(json.utf8)), expected) { error in
                let message = (error as? LumenThemeImportError)?.errorDescription ?? "\(error)"
                XCTAssertTrue(message.contains(expected), "\(message) should mention \(expected)")
            }
        }
    }

    func testExportedThemeIsSelfContained() throws {
        let theme = try DSThemeStore.decodeTheme(Data(partial.utf8))
        let file = LumenThemeFile(theme) { id in DSBuiltInThemes.all.first { $0.id == id } }
        let decoded = try DSThemeStore.decodeTheme(file.data())

        XCTAssertNil(decoded.inherits)
        XCTAssertEqual(file.fileName, "Calm.json")
        XCTAssertEqual(decoded.hex(.accent, for: .light).hexString, "#2F6FDE")
        XCTAssertEqual(decoded.hex(.bgCanvas, for: .dark), DSBuiltInThemes.scope.hex(.bgCanvas, for: .dark),
                       "The parent's colors travel with the file")
        XCTAssertTrue(decoded.missingTokens.isEmpty)
    }

    func testMoveToTrashRemovesTheFileAndFallsBackToScope() throws {
        let folder = try temporaryFolder()
        try write(partial, "calm.json", in: folder)
        let store = DSThemeStore(selectedID: "user.calm", persistsSelection: false, themesDirectory: folder)
        XCTAssertEqual(store.theme.id, "user.calm")

        var removed: [URL] = []
        try store.moveUserThemeToTrash("user.calm") { url in
            removed.append(url)
            try FileManager.default.removeItem(at: url)   // stand-in for the Trash in tests
        }
        XCTAssertEqual(removed.map(\.lastPathComponent), ["calm.json"])
        XCTAssertEqual(store.theme.id, DSBuiltInThemes.scope.id)
        XCTAssertThrowsError(try store.moveUserThemeToTrash(DSBuiltInThemes.midnight.id) { _ in XCTFail("Built-ins have no file") }) {
            XCTAssertEqual($0 as? LumenThemeImportError, .builtIn)
        }
    }

    func testEditingTheSelectedThemeInPlaceYieldsANewPalette() throws {
        let folder = try temporaryFolder()
        try write(partial, "calm.json", in: folder)
        let store = DSThemeStore(selectedID: "user.calm", persistsSelection: false, themesDirectory: folder)
        let before = store.resolvedPalette()

        try write(partial.replacingOccurrences(of: "#2F6FDE", with: "#C2185B"), "calm.json", in: folder)
        store.reloadUserThemes()

        XCTAssertNotEqual(store.resolvedPalette(), before, "Same theme id, new colors: readers must re-render")
        XCTAssertEqual(store.theme.hex(.accent, for: .light).hexString, "#C2185B")
    }

    func testSymbolicLinksAreRefused() throws {
        let folder = try temporaryFolder(), elsewhere = try temporaryFolder()
        try write(partial, "calm.json", in: elsewhere)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "calm.json"),
                                                   withDestinationURL: elsewhere.appending(path: "calm.json"))
        let library = DSThemeStore.loadUserThemeLibrary(from: folder)
        XCTAssertTrue(library.themes.isEmpty)
        XCTAssertTrue(library.problems.first?.reason.contains("symbolic link") == true)
    }

    func testStoresThatDoNotPersistIgnoreTheSavedChoice() {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, persistsSelection: false)
        XCTAssertEqual(store.theme.id, DSBuiltInThemes.defaultID, "Tests and previews start from Scope on every Mac")
    }

    func testOversizedFilesAreNotRead() throws {
        let folder = try temporaryFolder()
        let padding = String(repeating: " ", count: DSThemeStore.maximumThemeFileSize)
        try write(partial.replacingOccurrences(of: "}", with: "\(padding)}"), "huge.json", in: folder)
        let library = DSThemeStore.loadUserThemeLibrary(from: folder)
        XCTAssertTrue(library.themes.isEmpty)
        XCTAssertTrue(library.problems.first?.reason.contains("larger than 512 KB") == true)
    }

    @MainActor
    func testThemesReloadWhenAFileIsAddedToTheWatchedFolder() throws {
        let folder = try temporaryFolder()
        let store = DSThemeStore(persistsSelection: false, themesDirectory: folder)
        store.watchThemesDirectory()
        XCTAssertFalse(store.themes.contains { $0.id == "user.calm" })

        try write(partial, "calm.json", in: folder)
        let deadline = Date.now.addingTimeInterval(5)
        while !store.themes.contains(where: { $0.id == "user.calm" }) && Date.now < deadline {
            RunLoop.main.run(until: .now.addingTimeInterval(0.05))
        }
        XCTAssertTrue(store.themes.contains { $0.id == "user.calm" }, "The new file loads without choosing Reload")
    }
}
