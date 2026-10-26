import Foundation
import Synchronization
import XCTest
@testable import MacScope

final class WorkspaceDocumentChangeMonitorTests: XCTestCase {
    func testPresenterTranslatesChangedMovedAndDeletedCallbacksIntoHints() async throws {
        let registrar = RecordingWorkspaceDocumentPresenterRegistrar()
        let monitor = WorkspaceDocumentChangeMonitor(registrar: registrar)
        let location = try temporaryLocation()
        let feed = monitor.changes(at: location)
        let presenter = try XCTUnwrap(registrar.currentPresenter)
        XCTAssertEqual(registrar.addCount, 1)

        var iterator = feed.stream.makeAsyncIterator()

        presenter.presentedItemDidChange()
        let changed = await iterator.next()
        presenter.presentedItemDidMove(
            to: location.canonicalURL.appendingPathExtension("moved")
        )
        let moved = await iterator.next()
        let deletionError = await withCheckedContinuation { continuation in
            presenter.accommodatePresentedItemDeletion { error in
                continuation.resume(returning: error)
            }
        }
        let deleted = await iterator.next()

        XCTAssertNil(deletionError)
        XCTAssertEqual(changed, .changed)
        XCTAssertEqual(moved, .moved)
        XCTAssertEqual(deleted, .deleted)
    }

    func testQueuedPresenterBurstRetainsOnlyNewestAdvisoryHint() async throws {
        let registrar = RecordingWorkspaceDocumentPresenterRegistrar()
        let monitor = WorkspaceDocumentChangeMonitor(registrar: registrar)
        let location = try temporaryLocation()
        let feed = monitor.changes(at: location)
        let presenter = try XCTUnwrap(registrar.currentPresenter)

        presenter.presentedItemDidChange()
        presenter.presentedItemDidMove(
            to: location.canonicalURL.appendingPathExtension("moved")
        )
        let deletionError = await withCheckedContinuation { continuation in
            presenter.accommodatePresentedItemDeletion { error in
                continuation.resume(returning: error)
            }
        }

        var iterator = feed.stream.makeAsyncIterator()
        let retainedHint = await iterator.next()
        XCTAssertNil(deletionError)
        XCTAssertEqual(retainedHint, .deleted)
    }

    func testProbeDemandCoalescesCallbacksByRunningGeneration() throws {
        let registrar = RecordingWorkspaceDocumentPresenterRegistrar()
        let monitor = WorkspaceDocumentChangeMonitor(registrar: registrar)
        let feed = monitor.changes(at: try temporaryLocation())
        let presenter = try XCTUnwrap(registrar.currentPresenter)

        presenter.presentedItemDidChange()
        XCTAssertEqual(feed.probeDemand.beginNext(), 1)

        presenter.presentedItemDidChange()
        presenter.presentedItemDidChange()
        presenter.presentedItemDidChange()
        feed.probeDemand.complete(1)

        XCTAssertEqual(feed.probeDemand.beginNext(), 2)
        feed.probeDemand.complete(2)
        XCTAssertNil(feed.probeDemand.beginNext())

        presenter.presentedItemDidChange()
        XCTAssertEqual(feed.probeDemand.beginNext(), 3)
        feed.probeDemand.complete(3)
        XCTAssertNil(feed.probeDemand.beginNext())
    }

    func testConsumerCancellationUnregistersExactlyOnceAndFinishesStream() async throws {
        let registrar = RecordingWorkspaceDocumentPresenterRegistrar()
        let monitor = WorkspaceDocumentChangeMonitor(registrar: registrar)
        let feed = monitor.changes(at: try temporaryLocation())
        XCTAssertEqual(registrar.addCount, 1)

        let consumer = Task { () -> Int in
            var count = 0
            for await _ in feed.stream {
                count += 1
            }
            return count
        }
        consumer.cancel()
        let receivedCount = await consumer.value
        XCTAssertEqual(receivedCount, 0)

        XCTAssertEqual(registrar.removeCount, 1)
        XCTAssertNil(registrar.currentPresenter)
    }

    func testMoveHintCarriesNoReplacementLocationOrVersionAuthority() async throws {
        let registrar = RecordingWorkspaceDocumentPresenterRegistrar()
        let monitor = WorkspaceDocumentChangeMonitor(registrar: registrar)
        let location = try temporaryLocation()
        let feed = monitor.changes(at: location)
        let presenter = try XCTUnwrap(registrar.currentPresenter)
        let received = Task {
            var iterator = feed.stream.makeAsyncIterator()
            return await iterator.next()
        }

        presenter.presentedItemDidMove(
            to: URL(fileURLWithPath: "/untrusted/move/hint.mscope", isDirectory: true)
        )

        let hint = await received.value
        XCTAssertEqual(hint, .moved)
    }

    private func temporaryLocation() throws -> WorkspaceDocumentLocation {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceDocumentChangeMonitorTests-\(UUID().uuidString).mscope")
        return try WorkspaceDocumentLocation.canonicalized(from: url)
    }
}

private final class RecordingWorkspaceDocumentPresenterRegistrar:
    WorkspaceDocumentFilePresenterRegistering,
    Sendable {
    private struct State {
        var presenter: WorkspaceDocumentFilePresenterBridge?
        var additions = 0
        var removals = 0
    }

    private let state = Mutex(State())

    var currentPresenter: WorkspaceDocumentFilePresenterBridge? {
        state.withLock { $0.presenter }
    }

    var addCount: Int {
        state.withLock { $0.additions }
    }

    var removeCount: Int {
        state.withLock { $0.removals }
    }

    func add(_ presenter: WorkspaceDocumentFilePresenterBridge) {
        state.withLock {
            $0.additions += 1
            $0.presenter = presenter
        }
    }

    func remove(_ presenter: WorkspaceDocumentFilePresenterBridge) {
        state.withLock {
            $0.removals += 1
            if $0.presenter === presenter {
                $0.presenter = nil
            }
        }
    }
}
