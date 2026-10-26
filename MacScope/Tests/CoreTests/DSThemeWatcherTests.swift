import Foundation
import LumenTokens
import LumenUI
import Observation
import Synchronization
import XCTest
@testable import MacScope

final class DSThemeWatcherTests: XCTestCase {
    private final class Counter: Sendable {
        let value = Mutex(0)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "theme-watch-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func awaitCount(_ count: Counter, atLeast expected: Int, timeout: TimeInterval = 3) {
        let deadline = Date.now.addingTimeInterval(timeout)
        while count.value.withLock({ $0 }) < expected && Date.now < deadline {
            RunLoop.main.run(until: .now.addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(count.value.withLock { $0 }, expected)
    }

    @MainActor
    func testExistingFileInPlaceWriteNotifiesWithoutDirectoryMutation() throws {
        let directory = try folder(), file = directory.appending(path: "theme.json")
        try Data("old".utf8).write(to: file)
        let count = Counter()
        let watch = try XCTUnwrap(LumenThemeDirectoryWatch(directory: directory, debounce: .milliseconds(20)) {
            count.value.withLock { $0 += 1 }
        })
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("new".utf8))
        try handle.synchronize()
        try handle.close()
        awaitCount(count, atLeast: 1)
        withExtendedLifetime(watch) {}
    }

    @MainActor
    func testAtomicReplacementRearmsWatchForLaterInPlaceWrite() throws {
        let directory = try folder(), file = directory.appending(path: "theme.json")
        try Data("old".utf8).write(to: file)
        let count = Counter()
        let watch = try XCTUnwrap(LumenThemeDirectoryWatch(directory: directory, debounce: .milliseconds(20)) {
            count.value.withLock { $0 += 1 }
        })
        try Data("replacement".utf8).write(to: file, options: .atomic)
        awaitCount(count, atLeast: 1)
        let previous = count.value.withLock { $0 }
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("edited".utf8))
        try handle.synchronize()
        try handle.close()
        awaitCount(count, atLeast: previous + 1)
        withExtendedLifetime(watch) {}
    }

    @MainActor
    func testNonThemeChangesAndIdleFolderDoNotReloadThemes() throws {
        let directory = try folder()
        let store = DSThemeStore(persistsSelection: false, themesDirectory: directory)
        store.watchThemesDirectory()
        let fingerprint = DSThemeStore.themeFolderFingerprint(directory)
        let changes = Counter()
        withObservationTracking {
            _ = store.themes
        } onChange: {
            changes.value.withLock { $0 += 1 }
        }
        try Data("notes".utf8).write(to: directory.appending(path: "notes.txt"))
        try Data("finder".utf8).write(to: directory.appending(path: ".DS_Store"))
        RunLoop.main.run(until: .now.addingTimeInterval(0.4))
        XCTAssertEqual(DSThemeStore.themeFolderFingerprint(directory), fingerprint)
        XCTAssertEqual(store.themes, DSBuiltInThemes.all)
        RunLoop.main.run(until: .now.addingTimeInterval(0.1))
        XCTAssertEqual(DSThemeStore.themeFolderFingerprint(directory), fingerprint)
        XCTAssertEqual(changes.value.withLock { $0 }, 0, "Unchanged theme files must not publish a reload")
    }
}
