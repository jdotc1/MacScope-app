import Foundation
import Observation
import XCTest
import LumenTokens
@testable import LumenUI

/// User theme library: every store here works in a temporary folder, never the real
/// Application Support themes folder, and never persists a selection.
final class LumenThemeLibraryTests: XCTestCase {
    private let registry = TestPack.registry
    private let partial = ##"{"id": "user.calm", "name": "Calm", "inherits": "lumen.standard", "light": {"accent.default": "#2F6FDE"}}"##

    func testLibraryReportsEveryFileThatFailsToLoad() throws {
        let folder = try temporaryFolder()
        try write(partial, "a-calm.json", in: folder)
        try write(##"{"id": "user.calm", "name": "Calm again", "inherits": "lumen.standard"}"##, "b-duplicate.json", in: folder)
        try write("not json", "c-garbage.json", in: folder)
        try write(##"{"id": "user.nameless"}"##, "d-nameless.json", in: folder)
        try write(##"{"id": "lumen.standard", "name": "Fake", "inherits": "lumen.midnight"}"##, "e-reserved.json", in: folder)
        try write(##"{"id": "user.future", "name": "Future", "schemaVersion": 99}"##, "f-future.json", in: folder)
        try write(##"{"id": "user.orphan", "name": "Orphan", "inherits": "user.missing"}"##, "g-orphan.json", in: folder)
        try write("{}", "notes.txt", in: folder)

        let library = LumenThemeLibrary.load(from: folder, registry: registry)

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
        XCTAssertTrue(reasons["g-orphan.json"]?.contains("user.missing") == true)
    }

    func testHiddenBuiltInIDsAreStillReserved() throws {
        let registry = LumenRegistry(packs: [.core, LumenPack(id: "test.hide", hidesThemes: [LumenThemes.contrastID])])
        let folder = try temporaryFolder()
        try write(##"{"id": "lumen.contrast", "name": "Fake", "inherits": "lumen.standard"}"##, "fake.json", in: folder)
        let library = LumenThemeLibrary.load(from: folder, registry: registry)
        XCTAssertTrue(library.themes.isEmpty)
        XCTAssertTrue(library.problems.first?.reason.contains("built-in") == true)
    }

    func testImportCopiesIntoTheFolderSelectsAndNeverReplaces() throws {
        let folder = try temporaryFolder(), downloads = try temporaryFolder()
        try write(partial, "Calm.json", in: downloads)
        let store = TestPack.store(folder: folder)

        let first = try store.importTheme(from: downloads.appending(path: "Calm.json"))
        XCTAssertEqual(first.id, "user.calm")
        XCTAssertEqual(store.theme().id, "user.calm")
        XCTAssertEqual(store.theme().color(.accent, for: .light, in: registry).hexString, "#2F6FDE")

        let second = try store.importTheme(from: downloads.appending(path: "Calm.json"))
        XCTAssertEqual(second.id, "user.calm-2")
        XCTAssertEqual(second.name, "Calm 2")
        XCTAssertTrue(Set(store.themes.map(\.id)).isSuperset(of: ["user.calm", "user.calm-2"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).count, 2)
    }

    func testImportRejectsWhatCannotLoadAndWritesNothing() throws {
        let folder = try temporaryFolder(), downloads = try temporaryFolder()
        let store = TestPack.store(folder: folder)
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
        let midnight = try XCTUnwrap(registry.theme(id: LumenThemes.midnightID))
        try LumenThemeFile(midnight).data().write(to: downloads.appending(path: "Midnight.json"))
        let store = TestPack.store(folder: folder)
        let imported = try store.importTheme(from: downloads.appending(path: "Midnight.json"))
        XCTAssertEqual(imported.id, "user.midnight", "Never an id in the built-in namespace")
        XCTAssertEqual(store.theme().color(.bgCanvas, for: .dark, in: registry), midnight.color(.bgCanvas, for: .dark, in: registry))
        XCTAssertEqual(LumenThemeLibrary.importedID(for: "com.example.theme", registry: registry), "com.example.theme")
    }

    func testTheDarkSidebarExampleImportsWithItsOwnChromeColors() throws {
        let folder = try temporaryFolder()
        let store = TestPack.store(folder: folder)
        let imported = try store.importTheme(from: TestPack.darkSidebarURL)
        XCTAssertEqual(store.theme().id, imported.id)
        XCTAssertEqual(try hex(store.nsColor(.sidebarBackground), in: .aqua), "#1F2430")
        XCTAssertEqual(try hex(store.nsColor(.sidebarForeground), in: .aqua), "#ECEFF4")
        XCTAssertEqual(try hex(store.nsColor(.sidebarAccent), in: .aqua), "#A89BFF")
        let errors = LumenValidator.issues(for: store.theme(), in: LumenRegistry.core).filter { $0.severity == .error }
        XCTAssertEqual(errors.map(\.message), [], "The example passes the core checks")
    }

    func testEditorSavePreservesExistingFilesWithDifferentIDsOrInvalidContents() throws {
        let standard = try XCTUnwrap(registry.theme(id: LumenThemes.standardID))
        for original in [partial.replacingOccurrences(of: "user.calm", with: "user.other"), "unfinished JSON"] {
            let folder = try temporaryFolder()
            let occupied = folder.appending(path: "user.calm.json")
            try Data(original.utf8).write(to: occupied)
            let store = TestPack.store(folder: folder)

            let saved = try store.saveUserTheme(name: "Calm", inheriting: standard, overrides: [:])

            XCTAssertNotEqual(saved, occupied)
            XCTAssertEqual(try Data(contentsOf: occupied), Data(original.utf8))
            XCTAssertEqual(try LumenThemeLibrary.decodeTheme(Data(contentsOf: saved)).id, "user.calm")
            XCTAssertEqual(store.theme().id, "user.calm")
        }
    }

    func testDuplicatePreservesExistingFilesWithDifferentIDsOrInvalidContents() throws {
        let standard = try XCTUnwrap(registry.theme(id: LumenThemes.standardID))
        for original in [partial, "unfinished JSON"] {
            let folder = try temporaryFolder()
            let occupied = folder.appending(path: "user.standard.copy1.json")
            try Data(original.utf8).write(to: occupied)
            let store = TestPack.store(folder: folder)

            let saved = try store.duplicate(standard)

            XCTAssertNotEqual(saved, occupied)
            XCTAssertEqual(try Data(contentsOf: occupied), Data(original.utf8))
            XCTAssertEqual(store.theme().id, "user.standard.copy1")
            XCTAssertEqual(try LumenThemeLibrary.decodeTheme(Data(contentsOf: saved)).id, store.theme().id)
        }
    }

    func testImportPreservesAFileCreatedAfterTheStoreLoaded() throws {
        let folder = try temporaryFolder(), downloads = try temporaryFolder()
        let store = TestPack.store(folder: folder)
        let occupied = folder.appending(path: "user.calm.json")
        let original = Data("unfinished JSON".utf8)
        try original.write(to: occupied)
        try write(partial, "Calm.json", in: downloads)

        let imported = try store.importTheme(from: downloads.appending(path: "Calm.json"))

        XCTAssertEqual(try Data(contentsOf: occupied), original)
        XCTAssertNotEqual(store.userThemeFile(for: imported.id), occupied)
        XCTAssertEqual(store.theme().id, imported.id)
    }

    func testNewThemePublicationPreservesDanglingSymlinksAndCleansTemporaryFiles() throws {
        let folder = try temporaryFolder()
        let occupied = folder.appending(path: "user.calm.json")
        let missingTarget = folder.appending(path: "missing.json")
        try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: missingTarget)
        let store = TestPack.store(folder: folder)
        let standard = try XCTUnwrap(registry.theme(id: LumenThemes.standardID))

        let saved = try store.saveUserTheme(name: "Calm", inheriting: standard, overrides: [:])

        XCTAssertNotEqual(saved, occupied)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path), missingTarget.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["user.calm.json", saved.lastPathComponent])
    }

    func testFolderFingerprintIgnoresNonThemeFiles() throws {
        let folder = try temporaryFolder()
        try write(partial, "calm.json", in: folder)
        let before = LumenThemeLibrary.folderFingerprint(folder)
        try write("x", ".DS_Store", in: folder)
        try write("notes", "README.txt", in: folder)
        XCTAssertEqual(LumenThemeLibrary.folderFingerprint(folder), before)
        try write(partial.replacingOccurrences(of: "Calm", with: "Calmer"), "calm.json", in: folder)
        XCTAssertNotEqual(LumenThemeLibrary.folderFingerprint(folder), before)
    }

    func testDecoderRejectsWhatTheSchemaRejects() {
        let cases: [(String, String)] = [
            (##"{"id": "", "name": "Empty id", "inherits": "lumen.standard"}"##, "“id” is empty"),
            (##"{"id": "user.x", "name": " ", "inherits": "lumen.standard"}"##, "“name” is empty"),
            (##"{"id": "user.x", "name": "No colors"}"##, "needs a “light” or “dark” palette"),
            (##"{"id": "user.x", "name": "Bare hex", "light": {"accent.default": "2F6FDE"}}"##, "#RRGGBB"),
            (##"{"id": "user.x", "name": "Zero", "schemaVersion": 0, "inherits": "lumen.standard"}"##, "schemaVersion"),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try LumenThemeLibrary.decodeTheme(Data(json.utf8)), expected) { error in
                let message = (error as? LumenThemeImportError)?.errorDescription ?? "\(error)"
                XCTAssertTrue(message.contains(expected), "\(message) should mention \(expected)")
            }
        }
    }

    func testExportedThemeIsSelfContained() throws {
        let theme = try LumenThemeLibrary.decodeTheme(Data(partial.utf8))
        let file = LumenThemeFile(theme) { self.registry.theme(id: $0) }
        let decoded = try LumenThemeLibrary.decodeTheme(file.data())
        let standard = try XCTUnwrap(registry.theme(id: LumenThemes.standardID))

        XCTAssertNil(decoded.inherits)
        XCTAssertEqual(file.fileName, "Calm.json")
        XCTAssertEqual(decoded.color(.accent, for: .light, in: registry).hexString, "#2F6FDE")
        XCTAssertEqual(decoded.color(.bgCanvas, for: .dark, in: registry), standard.color(.bgCanvas, for: .dark, in: registry),
                       "The parent's colors travel with the file")
        XCTAssertEqual(decoded.color(TestPack.keyword, for: .dark, in: registry).hexString, "#F28FD0", "App pack values too")
        XCTAssertTrue(decoded.missingTokens(in: registry).isEmpty)
    }

    func testAnExportThatCannotMergeItsParentSaysSoInsteadOfClaimingToStandAlone() throws {
        let theme = try LumenThemeLibrary.decodeTheme(Data(partial.utf8))
        // Without a lookup, a built-in parent comes from the active store.
        let file = LumenThemeStore.withActiveStore(TestPack.store()) { LumenThemeFile(theme) }
        XCTAssertTrue(file.isSelfContained)
        XCTAssertNil(try LumenThemeLibrary.decodeTheme(file.data()).inherits)

        let orphan = try LumenThemeLibrary.decodeTheme(Data(##"{"id": "user.orphan", "name": "Orphan", "inherits": "user.missing"}"##.utf8))
        XCTAssertFalse(LumenThemeFile(orphan).isSelfContained, "Best effort keeps the parent link, and says so")
        XCTAssertThrowsError(try LumenThemeFile.selfContained(orphan)) { error in
            guard case .inheritance = error as? LumenThemeImportError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(try LumenThemeFile.selfContained(theme) { TestPack.registry.theme(id: $0) }.isSelfContained)
    }

    func testMoveToTrashRemovesTheFileAndFallsBackToTheDefault() throws {
        let folder = try temporaryFolder()
        try write(partial, "calm.json", in: folder)
        let store = TestPack.store(folder: folder)
        store.select("user.calm")
        store.select("user.calm", for: TestPack.editor)
        XCTAssertEqual(store.theme().id, "user.calm")

        var removed: [URL] = []
        try store.moveUserThemeToTrash("user.calm") { url in
            removed.append(url)
            try FileManager.default.removeItem(at: url)   // stand-in for the Trash in tests
        }
        XCTAssertEqual(removed.map(\.lastPathComponent), ["calm.json"])
        XCTAssertEqual(store.theme().id, LumenThemes.standardID)
        XCTAssertTrue(store.surfaceFollowsWindow(TestPack.editor), "A surface whose theme is gone follows the window again")
        XCTAssertThrowsError(try store.moveUserThemeToTrash(LumenThemes.midnightID) { _ in XCTFail("Built-ins have no file") }) {
            XCTAssertEqual($0 as? LumenThemeImportError, .builtIn)
        }
    }

    func testSymbolicLinksAreRefused() throws {
        let folder = try temporaryFolder(), elsewhere = try temporaryFolder()
        try write(partial, "calm.json", in: elsewhere)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "calm.json"),
                                                   withDestinationURL: elsewhere.appending(path: "calm.json"))
        let library = LumenThemeLibrary.load(from: folder, registry: registry)
        XCTAssertTrue(library.themes.isEmpty)
        XCTAssertTrue(library.problems.first?.reason.contains("symbolic link") == true)
    }

    func testOversizedFilesAreNotRead() throws {
        let folder = try temporaryFolder()
        let padding = String(repeating: " ", count: LumenThemeLibrary.maximumThemeFileSize)
        try write(partial.replacingOccurrences(of: "}", with: "\(padding)}"), "huge.json", in: folder)
        let library = LumenThemeLibrary.load(from: folder, registry: registry)
        XCTAssertTrue(library.themes.isEmpty)
        XCTAssertTrue(library.problems.first?.reason.contains("larger than 512 KB") == true)
    }

    func testStoreReportsProblemsAndFiles() throws {
        let folder = try temporaryFolder()
        try write(partial, "calm.json", in: folder)
        try write("not json", "broken.json", in: folder)
        let store = TestPack.store(folder: folder)
        XCTAssertEqual(store.themeFileProblems.map(\.file), ["broken.json"])
        XCTAssertEqual(store.userThemeFile(for: "user.calm")?.lastPathComponent, "calm.json")
        XCTAssertNil(store.userThemeFile(for: LumenThemes.standardID))
    }
}

final class LumenThemeWatcherTests: XCTestCase {
    private let partial = ##"{"id": "user.calm", "name": "Calm", "inherits": "lumen.standard", "light": {"accent.default": "#2F6FDE"}}"##

    @MainActor
    private func awaitCondition(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() && Date.now < deadline {
            RunLoop.main.run(until: .now.addingTimeInterval(0.02))
        }
    }

    @MainActor
    func testThemesReloadWhenAFileIsAddedToTheWatchedFolder() throws {
        let folder = try temporaryFolder()
        let store = TestPack.store(folder: folder)
        store.watchThemesDirectory()
        XCTAssertFalse(store.themes.contains { $0.id == "user.calm" })

        try write(partial, "calm.json", in: folder)
        awaitCondition { store.themes.contains { $0.id == "user.calm" } }
        XCTAssertTrue(store.themes.contains { $0.id == "user.calm" }, "The new file loads without choosing Reload")
    }

    @MainActor
    func testAnInPlaceEditOfTheSelectedThemeReloadsIt() throws {
        let folder = try temporaryFolder()
        try write(partial, "calm.json", in: folder)
        let store = TestPack.store(folder: folder)
        store.select("user.calm")
        store.watchThemesDirectory()

        // Rewrite the file through its existing descriptor: the folder itself doesn't change.
        let handle = try FileHandle(forWritingTo: folder.appending(path: "calm.json"))
        try handle.write(contentsOf: Data(partial.replacingOccurrences(of: "#2F6FDE", with: "#C2185B").utf8))
        try handle.synchronize()
        try handle.close()
        awaitCondition { store.theme().color(.accent, for: .light, in: store.registry).hexString == "#C2185B" }
        XCTAssertEqual(store.theme().color(.accent, for: .light, in: store.registry).hexString, "#C2185B")
    }

    @MainActor
    func testExistingFileInPlaceWriteNotifiesWithoutDirectoryMutation() throws {
        let directory = try temporaryFolder(), file = directory.appending(path: "theme.json")
        try Data("old".utf8).write(to: file)
        let count = Flag()
        let watch = try XCTUnwrap(LumenThemeDirectoryWatch(directory: directory, debounce: .milliseconds(20)) { count.fire() })
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("new".utf8))
        try handle.synchronize()
        try handle.close()
        awaitCondition(timeout: 3) { count.count >= 1 }
        XCTAssertGreaterThanOrEqual(count.count, 1)
        withExtendedLifetime(watch) {}
    }

    @MainActor
    func testAFolderReplacedAtTheSamePathIsWatchedInsteadOfTheOldOne() throws {
        let parent = try temporaryFolder()
        let folder = parent.appending(path: "Themes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = TestPack.store(folder: folder)
        store.watchThemesDirectory()

        // A sync tool or a restore swaps the folder in one step: moved aside, a new one in its place.
        try FileManager.default.moveItem(at: folder, to: parent.appending(path: "Themes-old", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        RunLoop.main.run(until: .now.addingTimeInterval(0.8))   // the watch sees the move, after its debounce

        try write(partial, "calm.json", in: folder)
        awaitCondition { store.themes.contains { $0.id == "user.calm" } }
        XCTAssertTrue(store.themes.contains { $0.id == "user.calm" }, "A file added to the new folder loads")
    }

    @MainActor
    func testAtomicReplacementRearmsWatchForLaterInPlaceWrite() throws {
        let directory = try temporaryFolder(), file = directory.appending(path: "theme.json")
        try Data("old".utf8).write(to: file)
        let count = Flag()
        let watch = try XCTUnwrap(LumenThemeDirectoryWatch(directory: directory, debounce: .milliseconds(20)) { count.fire() })
        try Data("replacement".utf8).write(to: file, options: .atomic)
        awaitCondition(timeout: 3) { count.count >= 1 }
        let previous = count.count
        XCTAssertGreaterThanOrEqual(previous, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("edited".utf8))
        try handle.synchronize()
        try handle.close()
        awaitCondition(timeout: 3) { count.count >= previous + 1 }
        XCTAssertGreaterThanOrEqual(count.count, previous + 1)
        withExtendedLifetime(watch) {}
    }

    @MainActor
    func testNonThemeChangesDoNotReloadThemes() throws {
        let directory = try temporaryFolder()
        let store = TestPack.store(folder: directory)
        store.watchThemesDirectory()
        let fingerprint = LumenThemeLibrary.folderFingerprint(directory)
        let changes = Flag()
        withObservationTracking {
            _ = store.themes
        } onChange: {
            changes.fire()
        }
        try Data("notes".utf8).write(to: directory.appending(path: "notes.txt"))
        try Data("finder".utf8).write(to: directory.appending(path: ".DS_Store"))
        RunLoop.main.run(until: .now.addingTimeInterval(0.5))
        XCTAssertEqual(store.lastFolderFingerprint.withLock { $0 }, fingerprint)
        XCTAssertEqual(store.themes, TestPack.registry.galleryThemes)
        XCTAssertEqual(changes.count, 0, "Unchanged theme files must not publish a reload")
    }
}

/// Theme library regressions.
final class LumenThemeLibraryRegressionTests: XCTestCase {
    private let registry = TestPack.registry

    func testAFileThatFailsToLoadStillOwnsItsID() throws {
        let folder = try temporaryFolder(), downloads = try temporaryFolder()
        try write(##"{"id": "a-child", "name": "Child", "inherits": "user.gone"}"##, "a-child.json", in: folder)
        try write(##"{"id": "a-child", "name": "Child", "inherits": "lumen.standard"}"##, "child.json", in: downloads)
        let store = TestPack.store(folder: folder)
        let imported = try store.importTheme(from: downloads.appending(path: "child.json"))
        XCTAssertEqual(imported.id, "a-child-2", "The broken file's id is taken")
        XCTAssertEqual(store.theme().id, "a-child-2")
    }

    func testCustomizingACustomizationDoesNotStackInheritance() throws {
        let store = TestPack.store(folder: try temporaryFolder())
        var base = try XCTUnwrap(store.themes.first { $0.id == LumenThemes.standardID })
        for round in 1...10 {
            try store.saveUserTheme(name: "Round \(round)", inheriting: base, overrides: [false: [.accent: "#2F6FDE"]])
            base = store.theme()
            XCTAssertEqual(base.name, "Round \(round)")
        }
        let file = try XCTUnwrap(store.userThemeFile(for: base.id))
        XCTAssertNil(try LumenThemeLibrary.decodeTheme(Data(contentsOf: file)).inherits, "A customization of a user theme stands alone")
    }

    func testAReloadKeepsASelectionWhoseFileIsBrokenForNow() throws {
        let folder = try temporaryFolder()
        try write(##"{"id": "user.calm", "name": "Calm", "inherits": "lumen.standard"}"##, "calm.json", in: folder)
        let store = TestPack.store(folder: folder)
        store.select("user.calm")
        try write("{ broken", "calm.json", in: folder)
        store.reloadUserThemes()
        XCTAssertEqual(store.theme().id, store.defaultThemeID, "Draws the default while the file is broken")
        try write(##"{"id": "user.calm", "name": "Calm", "inherits": "lumen.standard"}"##, "calm.json", in: folder)
        store.reloadUserThemes()
        XCTAssertEqual(store.theme().id, "user.calm", "And comes back when it's fixed")
    }

    func testIDsStartingWithADotStillWriteVisibleFiles() {
        XCTAssertEqual(LumenThemeLibrary.fileSlug(".hidden"), "hidden")
        XCTAssertEqual(LumenThemeLibrary.fileSlug("..."), "theme")
    }
}

/// Rename, edit in place and remove a broken file.
final class LumenThemeLibraryManagementTests: XCTestCase {
    private let partial = ##"{"id": "user.calm", "name": "Calm", "inherits": "lumen.standard", "light": {"accent.default": "#2F6FDE"}}"##

    func testRenamingKeepsTheFileAndID() throws {
        let folder = try temporaryFolder()
        try write(partial, "calm.json", in: folder)
        let store = TestPack.store(folder: folder)
        try store.renameUserTheme("user.calm", to: "Quiet")
        XCTAssertEqual(store.themes.first { $0.id == "user.calm" }?.name, "Quiet")
        XCTAssertEqual(store.userThemeFile(for: "user.calm")?.lastPathComponent, "calm.json")
        XCTAssertThrowsError(try store.renameUserTheme("user.calm", to: "  "))
    }

    func testEditingInPlaceKeepsTheParentAndOtherColors() throws {
        let folder = try temporaryFolder()
        try write(partial, "calm.json", in: folder)
        let store = TestPack.store(folder: folder)
        try store.updateUserTheme("user.calm", overrides: [false: [.fgSecondary: "#425570"]])
        let raw = try LumenThemeLibrary.decodeTheme(Data(contentsOf: folder.appending(path: "calm.json")))
        XCTAssertEqual(raw.inherits, "lumen.standard")
        XCTAssertEqual(raw.light?[.accent], "#2F6FDE")
        XCTAssertEqual(raw.light?[.fgSecondary], "#425570")
        XCTAssertEqual(store.themes.count { $0.id.hasPrefix("user.") }, 1, "No new theme")
    }

    func testABrokenFileCanBeRemovedFromTheGallery() throws {
        let folder = try temporaryFolder()
        try write("not json", "broken.json", in: folder)
        let store = TestPack.store(folder: folder)
        let problem = try XCTUnwrap(store.themeFileProblems.first)
        try store.moveProblemFileToTrash(problem) { try FileManager.default.removeItem(at: $0) }
        XCTAssertTrue(store.themeFileProblems.isEmpty)
        XCTAssertThrowsError(try store.moveProblemFileToTrash(LumenThemeFileProblem(file: "../escape.json", reason: "")) { _ in })
    }
}
