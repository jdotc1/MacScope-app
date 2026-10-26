import XCTest
import Dispatch
@testable import MacScope

final class NativeDecompilerTelemetryTests: XCTestCase {
    func testPublicSchemaIsClosedAndAllFourteenIntervalsBalanceExactlyOnce() {
        XCTAssertEqual(NativeDecompilerTelemetryIntervalKind.allCases.count, 14)
        let recorder = NativeDecompilerTelemetryRecorder(maximumHistoryCount: 32)
        for (index, kind) in NativeDecompilerTelemetryIntervalKind.allCases.enumerated() {
            let token = recorder.begin(
                kind: kind,
                cacheDisposition: .notApplicable,
                ownerKind: .windowSession,
                sizeBucket: .small,
                countBucket: .twoToFour,
                nowNanoseconds: UInt64(index * 10)
            )
            XCTAssertTrue(recorder.end(
                token: token,
                outcome: .success,
                nowNanoseconds: UInt64(index * 10 + 7)
            ))
            XCTAssertFalse(recorder.end(
                token: token,
                outcome: .failure,
                nowNanoseconds: UInt64(index * 10 + 8)
            ))
        }
        XCTAssertEqual(recorder.activeIntervalCount, 0)
        XCTAssertEqual(recorder.records.count, 14)
        XCTAssertTrue(recorder.records.allSatisfy { $0.interval?.durationNanoseconds == 7 })
    }

    func testBoundedHistoryEvictsOldestFirst() {
        let recorder = NativeDecompilerTelemetryRecorder(maximumHistoryCount: 2)
        for duration in 1 ... 3 {
            let token = recorder.begin(
                kind: .projection,
                cacheDisposition: .notApplicable,
                ownerKind: .windowSession,
                sizeBucket: .small,
                countBucket: .one,
                nowNanoseconds: 0
            )
            XCTAssertTrue(recorder.end(
                token: token,
                outcome: .success,
                nowNanoseconds: UInt64(duration)
            ))
        }
        XCTAssertEqual(
            recorder.records.compactMap { $0.interval?.durationNanoseconds },
            [2, 3]
        )
    }

    func testBalanceCheckRejectsEveryUnendedInterval() {
        let recorder = NativeDecompilerTelemetryRecorder(maximumHistoryCount: 2)
        let token = recorder.begin(
            kind: .endToEndAttempt,
            cacheDisposition: .lookupMiss,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one,
            nowNanoseconds: 1
        )

        XCTAssertThrowsError(try recorder.assertBalanced()) { error in
            XCTAssertEqual(
                error as? NativeDecompilerTelemetryLifecycleError,
                .unbalancedIntervals(count: 1)
            )
        }
        XCTAssertTrue(recorder.end(token: token, outcome: .failure, nowNanoseconds: 2))
        XCTAssertNoThrow(try recorder.assertBalanced())
    }

    func testPublicPayloadCannotCarryPathsHashesRawDiagnosticsOrExactByteCounts() {
        let mirror = Mirror(reflecting: NativeDecompilerPublicIntervalPayload(
            intervalKind: .projection,
            outcome: .success,
            durationNanoseconds: 7,
            cacheDisposition: .notApplicable,
            fallbackDisposition: .notApplicable,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one
        ))
        XCTAssertEqual(Set(mirror.children.compactMap(\.label)), [
            "intervalKind", "outcome", "durationNanoseconds", "cacheDisposition",
            "fallbackDisposition", "ownerKind", "sizeBucket", "countBucket",
        ])
        let forbidden = [
            "path", "uuid", "hash", "digest", "address", "symbol", "diagnostic",
            "byteCount", "request", "session", "workspace", "image", "generation",
        ]
        for label in mirror.children.compactMap(\.label) {
            XCTAssertFalse(forbidden.contains { label.localizedCaseInsensitiveContains($0) })
        }
    }

    func testExactCorrelationIdentityIsTransientAndExcludedFromPublicPayload() {
        let identity = NativeDecompilerTelemetryCorrelationIdentity(
            sessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            generation: 7,
            requestID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            workspaceID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            imageID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        )
        let recorder = NativeDecompilerTelemetryRecorder(maximumLogEventCount: 0)
        let token = recorder.begin(
            kind: .endToEndAttempt,
            cacheDisposition: .lookupMiss,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one,
            correlationIdentity: identity,
            nowNanoseconds: 10
        )

        XCTAssertTrue(token.wasAdmitted)
        XCTAssertTrue(recorder.end(token: token, outcome: .success, nowNanoseconds: 20))
        XCTAssertEqual(recorder.records.first?.correlationIdentity, identity)
        XCTAssertFalse(
            Mirror(reflecting: recorder.records[0].interval as Any)
                .children.contains { $0.value is UUID || $0.value is Data }
        )
        for field in Mirror(reflecting: identity).children {
            XCTAssertFalse(field.value is String)
            XCTAssertFalse(field.value is Data)
        }
    }

    func testGenerationCancellationAndRetirementFenceLateCompletions() {
        let sessionID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        let recorder = NativeDecompilerTelemetryRecorder(maximumLogEventCount: 0)
        func identity(_ generation: UInt64) -> NativeDecompilerTelemetryCorrelationIdentity {
            .init(sessionID: sessionID, generation: generation)
        }

        let first = recorder.begin(
            kind: .endToEndAttempt,
            cacheDisposition: .lookupMiss,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one,
            correlationIdentity: identity(1),
            nowNanoseconds: 1
        )
        let second = recorder.begin(
            kind: .endToEndAttempt,
            cacheDisposition: .lookupMiss,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one,
            correlationIdentity: identity(2),
            nowNanoseconds: 2
        )

        XCTAssertFalse(recorder.end(token: first, outcome: .success, nowNanoseconds: 3))
        XCTAssertTrue(recorder.cancel(
            sessionID: sessionID,
            throughGeneration: 2,
            nowNanoseconds: 4
        ))
        XCTAssertFalse(recorder.end(token: second, outcome: .success, nowNanoseconds: 5))

        let cancelledGeneration = recorder.begin(
            kind: .projection,
            cacheDisposition: .notApplicable,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one,
            correlationIdentity: identity(2),
            nowNanoseconds: 6
        )
        XCTAssertFalse(cancelledGeneration.wasAdmitted)

        let third = recorder.begin(
            kind: .projection,
            cacheDisposition: .notApplicable,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one,
            correlationIdentity: identity(3),
            nowNanoseconds: 7
        )
        XCTAssertTrue(third.wasAdmitted)
        XCTAssertFalse(recorder.retire(
            sessionID: sessionID,
            generation: 2,
            nowNanoseconds: 8
        ))
        XCTAssertTrue(recorder.retire(
            sessionID: sessionID,
            generation: 3,
            nowNanoseconds: 9
        ))
        XCTAssertFalse(recorder.end(token: third, outcome: .success, nowNanoseconds: 10))

        let retiredGeneration = recorder.begin(
            kind: .projection,
            cacheDisposition: .notApplicable,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one,
            correlationIdentity: identity(4),
            nowNanoseconds: 11
        )
        XCTAssertFalse(retiredGeneration.wasAdmitted)
        XCTAssertEqual(
            recorder.records.compactMap { $0.interval?.outcome },
            [.superseded, .cancelled, .superseded]
        )
    }

    func testOutcomeCacheAndFallbackAreSeparateDeterministicFields() {
        let recorder = NativeDecompilerTelemetryRecorder(maximumLogEventCount: 0)
        let cache = recorder.begin(
            kind: .endToEndAttempt,
            cacheDisposition: .lookupMiss,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one,
            nowNanoseconds: 0
        )
        XCTAssertTrue(recorder.end(
            token: cache,
            outcome: .cacheHit,
            fallbackDisposition: .notUsed,
            nowNanoseconds: 1
        ))

        let fallback = recorder.begin(
            kind: .endToEndAttempt,
            cacheDisposition: .bypassed,
            ownerKind: .windowSession,
            sizeBucket: .small,
            countBucket: .one,
            nowNanoseconds: 2
        )
        XCTAssertTrue(recorder.end(
            token: fallback,
            outcome: .failure,
            fallbackDisposition: .used,
            nowNanoseconds: 3
        ))

        XCTAssertEqual(recorder.records[0].interval?.outcome, .success)
        XCTAssertEqual(recorder.records[0].interval?.cacheDisposition, .lookupHit)
        XCTAssertEqual(recorder.records[0].interval?.fallbackDisposition, .notUsed)
        XCTAssertEqual(recorder.records[1].interval?.outcome, .failure)
        XCTAssertEqual(recorder.records[1].interval?.fallbackDisposition, .used)
    }

    func testRecorderCapsHistoryActiveIntervalsOwnersAndConcurrentMutation() {
        let activeLimited = NativeDecompilerTelemetryRecorder(
            maximumHistoryCount: 0,
            maximumActiveIntervalCount: 1,
            maximumLogEventCount: 0
        )
        let admitted = activeLimited.begin(
            kind: .projection,
            cacheDisposition: .notApplicable,
            ownerKind: .windowSession,
            sizeBucket: .tiny,
            countBucket: .one,
            nowNanoseconds: 0
        )
        let activeOverflow = activeLimited.begin(
            kind: .projection,
            cacheDisposition: .notApplicable,
            ownerKind: .windowSession,
            sizeBucket: .tiny,
            countBucket: .one,
            nowNanoseconds: 0
        )
        XCTAssertTrue(admitted.wasAdmitted)
        XCTAssertFalse(activeOverflow.wasAdmitted)
        XCTAssertTrue(activeLimited.end(token: admitted, outcome: .success, nowNanoseconds: 1))

        let recorder = NativeDecompilerTelemetryRecorder(
            maximumHistoryCount: .max,
            maximumActiveIntervalCount: 128,
            maximumTrackedOwnerCount: 1,
            maximumLogEventCount: 0
        )
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            let token = recorder.begin(
                kind: .projection,
                cacheDisposition: .notApplicable,
                ownerKind: .windowSession,
                sizeBucket: .tiny,
                countBucket: .one,
                nowNanoseconds: UInt64(index)
            )
            _ = recorder.end(
                token: token,
                outcome: .success,
                nowNanoseconds: UInt64(index + 1)
            )
        }
        for index in 0 ... 1_024 {
            let token = recorder.begin(
                kind: .projection,
                cacheDisposition: .notApplicable,
                ownerKind: .windowSession,
                sizeBucket: .tiny,
                countBucket: .one,
                nowNanoseconds: UInt64(index)
            )
            _ = recorder.end(
                token: token,
                outcome: .success,
                nowNanoseconds: UInt64(index + 1)
            )
        }

        let firstOwner = recorder.begin(
            kind: .projection,
            cacheDisposition: .notApplicable,
            ownerKind: .windowSession,
            sizeBucket: .tiny,
            countBucket: .one,
            correlationIdentity: .init(
                sessionID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
                generation: 1
            ),
            nowNanoseconds: 1
        )
        XCTAssertTrue(firstOwner.wasAdmitted)
        XCTAssertTrue(recorder.end(token: firstOwner, outcome: .success, nowNanoseconds: 2))
        let secondOwner = recorder.begin(
            kind: .projection,
            cacheDisposition: .notApplicable,
            ownerKind: .windowSession,
            sizeBucket: .tiny,
            countBucket: .one,
            correlationIdentity: .init(
                sessionID: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
                generation: 1
            ),
            nowNanoseconds: 3
        )

        let snapshot = recorder.snapshot()
        XCTAssertFalse(secondOwner.wasAdmitted)
        XCTAssertEqual(snapshot.activeIntervalCount, 0)
        XCTAssertEqual(snapshot.trackedOwnerCount, 1)
        XCTAssertGreaterThanOrEqual(snapshot.droppedIntervalCount, 1)
        XCTAssertEqual(snapshot.records.count, 1_024)
    }
}
