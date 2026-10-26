import Foundation
import XCTest
@testable import MacScope

@MainActor
final class NativeDecompilerDriveControlTests: XCTestCase {
    func testRequestAdmitsOnlyWhenNoAttemptOrResultExists() async throws {
        let (store, session) = try makeBoundNativeDriveStore()
        XCTAssertEqual(session.submissions.count, 1)
        store.requestNativeDecompiler()
        XCTAssertEqual(session.submissions.count, 1)
    }

    func testCancelQueuedAndActiveWorkKeepsSessionReusableAndFencesLateCompletion() async throws {
        let (store, session) = try makeBoundNativeDriveStore()
        store.cancelNativeDecompiler()
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(session.terminateCount, 0)
        store.refreshNativeDecompiler()
        XCTAssertEqual(session.submissions.count, 2)
    }

    func testRetryRequiresCurrentCausalFrozenTicketAndExactTarget() async throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let ticket = try XCTUnwrap(session.submissions.last?.ticket)
        store.retryNativeDecompiler()
        XCTAssertEqual(session.retries.map(\.frozenTicket), [ticket])
    }

    func testStoreFacingRetryCarriesOnlyCausalTicketAndCurrentTargetAuthority() async throws {
        let (store, session) = try makeBoundNativeDriveStore()
        store.retryNativeDecompiler()
        let retry = try XCTUnwrap(session.retries.last)
        XCTAssertEqual(retry.imageSlot, .primary)
        XCTAssertEqual(retry.functionID, store.snapshot.functions.first?.id)
        XCTAssertEqual(retry.snapshot.binaries.first?.id, store.snapshot.binaries.first?.id)
    }

    func testRetryReusesFrozenStoreTicketAndCallsSessionExactlyOnce() async throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let ticket = try XCTUnwrap(session.submissions.last?.ticket)
        store.retryNativeDecompiler()
        XCTAssertEqual(session.retries.count, 1)
        XCTAssertEqual(session.retries[0].frozenTicket, ticket)
    }

    func testRefreshAdvancesManualIntentBypassesCacheAndCreatesOneTicket() async throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let prior = try XCTUnwrap(session.submissions.last?.ticket)
        store.refreshNativeDecompiler()
        let refreshed = try XCTUnwrap(session.submissions.last)
        XCTAssertEqual(session.submissions.count, 2)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(refreshed.cacheLookupPolicy, .bypassCacheLookup)
        XCTAssertEqual(refreshed.ticket.manualIntentGeneration, prior.manualIntentGeneration + 1)
    }

    func testRapidCancelRetryRefreshRacesDoNotDoublePublishOrLeakWaiter() async throws {
        let (store, session) = try makeBoundNativeDriveStore()
        store.cancelNativeDecompiler()
        store.retryNativeDecompiler()
        store.refreshNativeDecompiler()
        XCTAssertEqual(session.cancelCount, 2)
        XCTAssertEqual(session.retries.count, 1)
        XCTAssertEqual(session.submissions.count, 2)
        XCTAssertEqual(session.terminateCount, 0)
    }

    func testDriveCounterExhaustionCancelsExactlyOnceAndCannotRevive() async throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let submissionsBefore = session.submissions.count
        store.nativeDecompilerDriveContext.driveGeneration = .max

        store.establishNativeDriveContext(origin: .interactiveAdoption)

        XCTAssertEqual(store.nativeDecompilerDriveContext.machine.state, .exhausted(.drive))
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(session.submissions.count, submissionsBefore)
        store.requestNativeDecompiler()
        store.retryNativeDecompiler()
        store.refreshNativeDecompiler()
        store.cancelNativeDecompiler()
        XCTAssertEqual(store.nativeDecompilerDriveContext.machine.state, .exhausted(.drive))
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(session.submissions.count, submissionsBefore)
        XCTAssertTrue(session.retries.isEmpty)
    }

}
