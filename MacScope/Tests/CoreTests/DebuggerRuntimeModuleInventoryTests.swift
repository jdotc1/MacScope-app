import Foundation
import CryptoKit
import XCTest
@testable import MacScope

final class DebuggerRuntimeModuleInventoryTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    func testRuntimeModuleValuesAreSendableHashableAndValidated() throws {
        assertSendableAndHashable(DebuggerRuntimeModuleInventoryRevision.self)
        assertSendableAndHashable(DebuggerRuntimeModuleAuthorityRevision.self)
        assertSendableAndHashable(DebuggerRuntimeModuleMappedRangeObservation.self)
        assertSendableAndHashable(DebuggerRuntimeModuleObservation.self)
        assertSendableAndHashable(DebuggerRuntimeModuleObservationFingerprint.self)
        assertSendableAndHashable(DebuggerRuntimeModuleInstanceID.self)
        assertSendableAndHashable(DebuggerRuntimeModuleInstance.self)
        assertSendableAndHashable(DebuggerRuntimeModuleInventory.self)
        assertSendableAndHashable(DebuggerRuntimeModuleAuthority.self)
        assertSendableAndHashable(DebuggerRuntimeModuleInventoryChanges.self)

        XCTAssertNil(
            DebuggerRuntimeModuleMappedRangeObservation(
                sectionOrdinal: 0,
                sectionName: "__TEXT",
                staticStart: 0x1000,
                runtimeStart: 0x2000,
                byteCount: 0,
                permissions: 5
            )
        )
        XCTAssertNil(
            DebuggerRuntimeModuleMappedRangeObservation(
                sectionOrdinal: 0,
                sectionName: "bad\nname",
                staticStart: 0x1000,
                runtimeStart: 0x2000,
                byteCount: 0x10,
                permissions: 5
            )
        )
        XCTAssertNil(
            DebuggerRuntimeModuleMappedRangeObservation(
                sectionOrdinal: 0,
                sectionName: "__TEXT",
                staticStart: .max,
                runtimeStart: 0x2000,
                byteCount: 1,
                permissions: 5
            )
        )
        XCTAssertNil(
            DebuggerRuntimeModuleMappedRangeObservation(
                sectionOrdinal: 0,
                sectionName: "__TEXT",
                staticStart: 0x1000,
                runtimeStart: .max,
                byteCount: 1,
                permissions: 5
            )
        )
        XCTAssertNil(
            DebuggerRuntimeModuleMappedRangeObservation(
                sectionOrdinal: 0,
                sectionName: "__TEXT",
                staticStart: 0x1000,
                runtimeStart: 0x2000,
                byteCount: 0x10,
                permissions: 8
            )
        )

        let range = try XCTUnwrap(mappedRange())
        XCTAssertNil(
            DebuggerRuntimeModuleObservation(
                uuid: nil,
                processID: 0,
                observedStopID: 77,
                mappedRanges: [range],
                fullPath: "/tmp/zero",
                normalizedArchitectureTriple: "arm64-apple-macosx",
                displayIndex: nil,
                fingerprintSHA256: Data(repeating: 1, count: 32)
            )
        )
        XCTAssertNil(
            DebuggerRuntimeModuleObservation(
                uuid: nil,
                processID: 42,
                observedStopID: 77,
                mappedRanges: [range],
                fullPath: "/tmp/bad\0path",
                normalizedArchitectureTriple: "arm64-apple-macosx",
                displayIndex: nil,
                fingerprintSHA256: Data(repeating: 2, count: 32)
            )
        )
        XCTAssertNil(
            DebuggerRuntimeModuleObservation(
                uuid: nil,
                processID: 42,
                observedStopID: 77,
                mappedRanges: [range],
                fullPath: "/tmp/good",
                normalizedArchitectureTriple: "arm64 ambiguous",
                displayIndex: nil,
                fingerprintSHA256: Data(repeating: 3, count: 32)
            )
        )
        XCTAssertNil(
            DebuggerRuntimeModuleObservation(
                uuid: nil,
                processID: 42,
                observedStopID: 77,
                mappedRanges: [range],
                fullPath: "/tmp/good",
                normalizedArchitectureTriple: "ARM64-apple-macosx",
                displayIndex: nil,
                fingerprintSHA256: Data(repeating: 4, count: 32)
            )
        )
        XCTAssertNil(DebuggerRuntimeModuleObservationFingerprint(sha256: Data(repeating: 0, count: 31)))
        XCTAssertNotNil(module(path: "/tmp/good", backendIndex: 7))
        XCTAssertNotNil(module(path: "", backendIndex: 8))

        XCTAssertEqual(
            DebuggerRuntimeModuleInventoryRevision(rawValue: 8).incremented(),
            DebuggerRuntimeModuleInventoryRevision(rawValue: 9)
        )
        XCTAssertEqual(
            DebuggerRuntimeModuleAuthorityRevision(rawValue: 13).incremented(),
            DebuggerRuntimeModuleAuthorityRevision(rawValue: 14)
        )
        XCTAssertNil(DebuggerRuntimeModuleInventoryRevision(rawValue: .max).incremented())
        XCTAssertNil(DebuggerRuntimeModuleAuthorityRevision(rawValue: .max).incremented())
    }

    func testCompleteRefreshOrdersDeterministicallyAndQualifiesEveryInstanceID() throws {
        let stop = makeStop(lifecycle: 1, stop: 1)
        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop.session)

        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop), .accepted)
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory(
                [
                    try XCTUnwrap(module(path: "/usr/lib/Z.dylib", backendIndex: 1)),
                    try XCTUnwrap(module(path: "/usr/lib/A.dylib", backendIndex: 9)),
                ],
                observedStopID: 77,
                processID: 42,
                at: stop
            ),
            .accepted
        )

        let inventory = try XCTUnwrap(reducer.state.availableInventory)
        XCTAssertEqual(inventory.processID, 42)
        XCTAssertEqual(inventory.stop, stop)
        XCTAssertEqual(inventory.revision, DebuggerRuntimeModuleInventoryRevision(rawValue: 1))
        XCTAssertEqual(inventory.modules.map(\.observation.fullPath), ["/usr/lib/Z.dylib", "/usr/lib/A.dylib"])
        XCTAssertEqual(
            inventory.modules.map(\.id),
            [
                DebuggerRuntimeModuleInstanceID(
                    processID: 42,
                    stop: stop,
                    inventoryRevision: DebuggerRuntimeModuleInventoryRevision(rawValue: 1),
                    ordinal: 0
                ),
                DebuggerRuntimeModuleInstanceID(
                    processID: 42,
                    stop: stop,
                    inventoryRevision: DebuggerRuntimeModuleInventoryRevision(rawValue: 1),
                    ordinal: 1
                ),
            ]
        )
        XCTAssertEqual(reducer.state.inventoryRevision.rawValue, 1)
        XCTAssertEqual(reducer.state.authorityRevision.rawValue, 3)
        XCTAssertEqual(reducer.state.changes.appeared.count, 2)
        XCTAssertTrue(reducer.state.changes.disappeared.isEmpty)
        XCTAssertTrue(reducer.state.changes.remapped.isEmpty)
    }

    func testEveryCompleteRefreshAdvancesInventoryAndAuthorityAndRemintsEqualContent() throws {
        let stop = makeStop(lifecycle: 1, stop: 1)
        let observed = try XCTUnwrap(module(path: "/usr/lib/libEqual.dylib", backendIndex: 3))
        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop.session)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop), .accepted)

        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory([observed], observedStopID: 77, processID: 42, at: stop),
            .accepted
        )
        let first = try XCTUnwrap(reducer.state.availableInventory)

        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory([observed], observedStopID: 77, processID: 42, at: stop),
            .accepted
        )
        let second = try XCTUnwrap(reducer.state.availableInventory)

        XCTAssertEqual(first.revision.rawValue, 1)
        XCTAssertEqual(second.revision.rawValue, 2)
        XCTAssertNotEqual(first.modules[0].id, second.modules[0].id)
        XCTAssertEqual(reducer.state.authorityRevision.rawValue, 5)
        XCTAssertTrue(reducer.state.changes.appeared.isEmpty)
        XCTAssertTrue(reducer.state.changes.disappeared.isEmpty)
        XCTAssertTrue(reducer.state.changes.remapped.isEmpty)
    }

    func testReconciliationReportsLoadUnloadRemapAndBackendIndexReuseWithoutPreservingIdentity() throws {
        let stop1 = makeStop(lifecycle: 1, stop: 1)
        let stop2 = makeStop(lifecycle: 2, stop: 2)
        let oldA = try XCTUnwrap(
            module(
                path: "/tmp/A.dylib",
                backendIndex: 4,
                uuid: uuid(1),
                staticStart: 0x1000,
                runtimeStart: 0x9000
            )
        )
        let oldB = try XCTUnwrap(
            module(
                path: "/tmp/B.dylib",
                backendIndex: 8,
                uuid: uuid(2),
                staticStart: 0x2000,
                runtimeStart: 0xA000
            )
        )
        let remappedA = try XCTUnwrap(
            module(
                path: "/tmp/A.dylib",
                backendIndex: 17,
                uuid: uuid(1),
                observedStopID: 78,
                staticStart: 0x1000,
                runtimeStart: 0xB000
            )
        )
        let newCReusingIndex = try XCTUnwrap(
            module(
                path: "/tmp/C.dylib",
                backendIndex: 8,
                uuid: uuid(3),
                observedStopID: 78,
                staticStart: 0x3000,
                runtimeStart: 0xC000
            )
        )

        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop1.session)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop1), .accepted)
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop1), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory([oldA, oldB], observedStopID: 77, processID: 42, at: stop1),
            .accepted
        )
        let oldIDs = Set(try XCTUnwrap(reducer.state.availableInventory).modules.map(\.id))

        XCTAssertEqual(reducer.transitionToRunning(processID: 42, session: stop1.session), .accepted)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop2), .accepted)
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop2), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory(
                [newCReusingIndex, remappedA],
                observedStopID: 78,
                processID: 42,
                at: stop2
            ),
            .accepted
        )

        let inventory = try XCTUnwrap(reducer.state.availableInventory)
        XCTAssertTrue(oldIDs.isDisjoint(with: Set(inventory.modules.map(\.id))))
        XCTAssertEqual(Set(reducer.state.changes.appeared), [newCReusingIndex.fingerprint])
        XCTAssertEqual(Set(reducer.state.changes.disappeared), [oldB.fingerprint])
        XCTAssertEqual(reducer.state.changes.remapped.count, 1)
        XCTAssertEqual(reducer.state.changes.remapped[0].previous, oldA.fingerprint)
        XCTAssertEqual(reducer.state.changes.remapped[0].current, remappedA.fingerprint)
    }

    func testNilZeroAndNonuniqueUUIDsNeverInventRemapContinuity() throws {
        let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        for candidateUUID in [nil, zeroUUID] as [UUID?] {
            let stop1 = makeStop(lifecycle: 1, stop: 1)
            let stop2 = makeStop(lifecycle: 2, stop: 2)
            let old = try XCTUnwrap(
                module(
                    path: "/tmp/no-identity.dylib",
                    backendIndex: 1,
                    uuid: candidateUUID,
                    runtimeStart: 0x9000
                )
            )
            let current = try XCTUnwrap(
                module(
                    path: "/tmp/no-identity.dylib",
                    backendIndex: 2,
                    uuid: candidateUUID,
                    observedStopID: 78,
                    runtimeStart: 0xA000
                )
            )
            var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop1.session)
            XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop1), .accepted)
            XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop1), .accepted)
            XCTAssertEqual(
                reducer.acceptInventory([old], observedStopID: 77, processID: 42, at: stop1),
                .accepted
            )
            XCTAssertEqual(reducer.transitionToRunning(processID: 42, session: stop1.session), .accepted)
            XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop2), .accepted)
            XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop2), .accepted)
            XCTAssertEqual(
                reducer.acceptInventory([current], observedStopID: 78, processID: 42, at: stop2),
                .accepted
            )
            XCTAssertEqual(reducer.state.changes.appeared, [current.fingerprint])
            XCTAssertEqual(reducer.state.changes.disappeared, [old.fingerprint])
            XCTAssertTrue(reducer.state.changes.remapped.isEmpty)
        }

        let stop1 = makeStop(lifecycle: 11, stop: 11)
        let stop2 = makeStop(lifecycle: 12, stop: 12)
        let sharedUUID = uuid(9)
        let old1 = try XCTUnwrap(
            module(path: "/tmp/old-1", backendIndex: 1, uuid: sharedUUID, runtimeStart: 0x10000)
        )
        let old2 = try XCTUnwrap(
            module(path: "/tmp/old-2", backendIndex: 2, uuid: sharedUUID, runtimeStart: 0x20000)
        )
        let current = try XCTUnwrap(
            module(
                path: "/tmp/current",
                backendIndex: 3,
                uuid: sharedUUID,
                observedStopID: 78,
                runtimeStart: 0x30000
            )
        )
        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop1.session)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop1), .accepted)
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop1), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory([old1, old2], observedStopID: 77, processID: 42, at: stop1),
            .accepted
        )
        XCTAssertEqual(reducer.transitionToRunning(processID: 42, session: stop1.session), .accepted)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop2), .accepted)
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop2), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory([current], observedStopID: 78, processID: 42, at: stop2),
            .accepted
        )
        XCTAssertEqual(reducer.state.changes.appeared, [current.fingerprint])
        XCTAssertEqual(Set(reducer.state.changes.disappeared), [old1.fingerprint, old2.fingerprint])
        XCTAssertTrue(reducer.state.changes.remapped.isEmpty)
    }

    func testArchitectureChangeAndCompleteSnapshotMultiplicityNeverInventRemap() throws {
        let stop1 = makeStop(lifecycle: 21, stop: 21)
        let stop2 = makeStop(lifecycle: 22, stop: 22)
        let sharedUUID = uuid(19)

        let oldArchitecture = try XCTUnwrap(
            module(
                path: "/tmp/architecture",
                backendIndex: 1,
                uuid: sharedUUID,
                runtimeStart: 0x10_000,
                triple: "arm64-apple-macosx"
            )
        )
        let newArchitecture = try XCTUnwrap(
            module(
                path: "/tmp/architecture",
                backendIndex: 2,
                uuid: sharedUUID,
                observedStopID: 78,
                runtimeStart: 0x20_000,
                triple: "arm64e-apple-macosx"
            )
        )
        var architectureReducer = DebuggerRuntimeModuleInventoryReducer(session: stop1.session)
        XCTAssertEqual(architectureReducer.observeStopped(processID: 42, at: stop1), .accepted)
        XCTAssertEqual(architectureReducer.admitRefresh(processID: 42, at: stop1), .accepted)
        XCTAssertEqual(
            architectureReducer.acceptInventory(
                [oldArchitecture], observedStopID: 77, processID: 42, at: stop1
            ),
            .accepted
        )
        XCTAssertEqual(
            architectureReducer.transitionToRunning(processID: 42, session: stop1.session),
            .accepted
        )
        XCTAssertEqual(architectureReducer.observeStopped(processID: 42, at: stop2), .accepted)
        XCTAssertEqual(architectureReducer.admitRefresh(processID: 42, at: stop2), .accepted)
        XCTAssertEqual(
            architectureReducer.acceptInventory(
                [newArchitecture], observedStopID: 78, processID: 42, at: stop2
            ),
            .accepted
        )
        XCTAssertEqual(architectureReducer.state.changes.appeared, [newArchitecture.fingerprint])
        XCTAssertEqual(architectureReducer.state.changes.disappeared, [oldArchitecture.fingerprint])
        XCTAssertTrue(architectureReducer.state.changes.remapped.isEmpty)

        let unchangedOld = try XCTUnwrap(
            module(path: "/tmp/unchanged", backendIndex: 1, uuid: sharedUUID, runtimeStart: 0x30_000)
        )
        let changedOld = try XCTUnwrap(
            module(path: "/tmp/changed-old", backendIndex: 2, uuid: sharedUUID, runtimeStart: 0x40_000)
        )
        let unchangedCurrent = try XCTUnwrap(
            module(
                path: "/tmp/unchanged",
                backendIndex: 3,
                uuid: sharedUUID,
                observedStopID: 78,
                runtimeStart: 0x30_000
            )
        )
        let changedCurrent = try XCTUnwrap(
            module(
                path: "/tmp/changed-current",
                backendIndex: 4,
                uuid: sharedUUID,
                observedStopID: 78,
                runtimeStart: 0x50_000
            )
        )
        var multiplicityReducer = DebuggerRuntimeModuleInventoryReducer(session: stop1.session)
        XCTAssertEqual(multiplicityReducer.observeStopped(processID: 42, at: stop1), .accepted)
        XCTAssertEqual(multiplicityReducer.admitRefresh(processID: 42, at: stop1), .accepted)
        XCTAssertEqual(
            multiplicityReducer.acceptInventory(
                [unchangedOld, changedOld], observedStopID: 77, processID: 42, at: stop1
            ),
            .accepted
        )
        XCTAssertEqual(
            multiplicityReducer.transitionToRunning(processID: 42, session: stop1.session),
            .accepted
        )
        XCTAssertEqual(multiplicityReducer.observeStopped(processID: 42, at: stop2), .accepted)
        XCTAssertEqual(multiplicityReducer.admitRefresh(processID: 42, at: stop2), .accepted)
        XCTAssertEqual(
            multiplicityReducer.acceptInventory(
                [unchangedCurrent, changedCurrent],
                observedStopID: 78,
                processID: 42,
                at: stop2
            ),
            .accepted
        )
        XCTAssertEqual(multiplicityReducer.state.changes.appeared, [changedCurrent.fingerprint])
        XCTAssertEqual(multiplicityReducer.state.changes.disappeared, [changedOld.fingerprint])
        XCTAssertTrue(multiplicityReducer.state.changes.remapped.isEmpty)
    }

    func testAuthorityTransitionsInstallMonotonicTombstonesWithoutReusingInventory() throws {
        let stop = makeStop(lifecycle: 1, stop: 1)
        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop.session)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop), .accepted)
        XCTAssertAuthority(reducer.state.authority, unavailable: .newStop)

        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertAuthority(reducer.state.authority, unavailable: .refreshInProgress)
        XCTAssertEqual(reducer.state.authorityRevision.rawValue, 2)

        let sensitiveFailure = "/Users/private/Target SECRET_ENV=token\nexpression-result"
            + String(repeating: "X", count: 5_000)
        let safeFailure = DebuggerRuntimeModuleFailureEvidence(redacting: sensitiveFailure)
        XCTAssertEqual(safeFailure.evidenceByteCount, sensitiveFailure.utf8.count)
        XCTAssertEqual(safeFailure.evidenceSHA256.count, 32)
        XCTAssertFalse(String(reflecting: safeFailure).contains("SECRET_ENV"))
        XCTAssertEqual(
            reducer.failRefresh(processID: 42, at: stop, evidence: safeFailure),
            .accepted
        )
        XCTAssertAuthority(
            reducer.state.authority,
            unavailable: .refreshFailed(safeFailure)
        )
        XCTAssertNil(reducer.state.availableInventory)
        XCTAssertEqual(reducer.state.inventoryRevision.rawValue, 0)
        XCTAssertEqual(reducer.state.authorityRevision.rawValue, 3)

        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory(
                [try XCTUnwrap(module(path: "/tmp/loaded.dylib", backendIndex: 1))],
                observedStopID: 77,
                processID: 42,
                at: stop
            ),
            .accepted
        )
        XCTAssertNotNil(reducer.state.availableInventory)
        XCTAssertEqual(reducer.state.inventoryRevision.rawValue, 1)
        XCTAssertEqual(reducer.state.authorityRevision.rawValue, 5)

        XCTAssertEqual(reducer.admitExpressionEvaluation(processID: 42, at: stop), .accepted)
        XCTAssertAuthority(reducer.state.authority, unavailable: .expressionEvaluationAdmitted)
        XCTAssertNil(reducer.state.availableInventory)
        XCTAssertEqual(reducer.state.inventoryRevision.rawValue, 1)
        XCTAssertEqual(reducer.state.authorityRevision.rawValue, 6)

        XCTAssertEqual(reducer.admitResumeCapableOperation(processID: 42, at: stop), .accepted)
        XCTAssertAuthority(reducer.state.authority, unavailable: .resumeCapableOperationAdmitted)
        XCTAssertEqual(reducer.state.authorityRevision.rawValue, 7)
    }

    func testRunningTerminalAndSessionInvalidationClearRuntimeInstances() throws {
        let stop = makeStop(lifecycle: 1, stop: 1)
        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop.session)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop), .accepted)
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory(
                [try XCTUnwrap(module(path: "/tmp/loaded.dylib", backendIndex: 1))],
                observedStopID: 77,
                processID: 42,
                at: stop
            ),
            .accepted
        )

        XCTAssertEqual(reducer.transitionToRunning(processID: 42, session: stop.session), .accepted)
        XCTAssertAuthority(reducer.state.authority, unavailable: .running)
        XCTAssertNil(reducer.state.availableInventory)
        XCTAssertTrue(reducer.state.activeModules.isEmpty)
        XCTAssertNil(reducer.state.currentStop)

        let stop2 = makeStop(lifecycle: 2, stop: 2)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop2), .accepted)
        XCTAssertEqual(reducer.transitionToTerminal(processID: 42, session: stop2.session), .accepted)
        XCTAssertAuthority(reducer.state.authority, unavailable: .terminal)
        XCTAssertTrue(reducer.state.activeModules.isEmpty)

        XCTAssertEqual(reducer.invalidateSession(epoch: epoch), .accepted)
        XCTAssertAuthority(reducer.state.authority, unavailable: .sessionInvalidated)
        XCTAssertTrue(reducer.state.activeModules.isEmpty)
        XCTAssertTrue(reducer.state.isSessionInvalidated)
    }

    func testPhaseLatchRejectsDuplicateAndPostTerminalTransitionsAtomically() throws {
        let stop1 = makeStop(lifecycle: 1, stop: 1)
        let stop2 = makeStop(lifecycle: 2, stop: 2)
        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop1.session)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop1), .accepted)
        XCTAssertEqual(reducer.transitionToRunning(processID: 42, session: stop1.session), .accepted)

        var before = reducer.state
        XCTAssertEqual(
            reducer.transitionToRunning(processID: 42, session: stop1.session),
            .rejected(.invalidTransition)
        )
        XCTAssertEqual(reducer.state, before)

        XCTAssertEqual(reducer.transitionToTerminal(processID: 42, session: stop1.session), .accepted)
        before = reducer.state
        XCTAssertEqual(
            reducer.transitionToTerminal(processID: 42, session: stop1.session),
            .rejected(.invalidTransition)
        )
        XCTAssertEqual(reducer.state, before)
        XCTAssertEqual(
            reducer.transitionToRunning(processID: 42, session: stop1.session),
            .rejected(.invalidTransition)
        )
        XCTAssertEqual(reducer.state, before)
        XCTAssertEqual(
            reducer.observeStopped(processID: 42, at: stop2),
            .rejected(.invalidTransition)
        )
        XCTAssertEqual(reducer.state, before)
    }

    func testTerminalAndInvalidationFailClosedAtAuthorityRevisionExhaustion() throws {
        let stop = makeStop(lifecycle: 1, stop: 1)

        var terminalReducer = DebuggerRuntimeModuleInventoryReducer(
            session: stop.session,
            initialAuthorityRevision: DebuggerRuntimeModuleAuthorityRevision(rawValue: .max - 3)
        )
        XCTAssertEqual(terminalReducer.observeStopped(processID: 42, at: stop), .accepted)
        XCTAssertEqual(terminalReducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertEqual(
            terminalReducer.acceptInventory(
                [try XCTUnwrap(module(path: "/tmp/exhausted-terminal", backendIndex: 1))],
                observedStopID: 77,
                processID: 42,
                at: stop
            ),
            .accepted
        )
        XCTAssertEqual(terminalReducer.state.authorityRevision.rawValue, .max)
        XCTAssertNotNil(terminalReducer.state.availableInventory)
        XCTAssertEqual(
            terminalReducer.transitionToTerminal(processID: 42, session: stop.session),
            .accepted
        )
        XCTAssertAuthority(terminalReducer.state.authority, unavailable: .terminal)
        XCTAssertNil(terminalReducer.state.availableInventory)
        XCTAssertEqual(terminalReducer.state.authorityRevision.rawValue, .max)

        var invalidatedReducer = DebuggerRuntimeModuleInventoryReducer(
            session: stop.session,
            initialAuthorityRevision: DebuggerRuntimeModuleAuthorityRevision(rawValue: .max - 3)
        )
        XCTAssertEqual(invalidatedReducer.observeStopped(processID: 42, at: stop), .accepted)
        XCTAssertEqual(invalidatedReducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertEqual(
            invalidatedReducer.acceptInventory(
                [try XCTUnwrap(module(path: "/tmp/exhausted-invalidation", backendIndex: 2))],
                observedStopID: 77,
                processID: 42,
                at: stop
            ),
            .accepted
        )
        XCTAssertEqual(invalidatedReducer.state.authorityRevision.rawValue, .max)
        XCTAssertNotNil(invalidatedReducer.state.availableInventory)
        XCTAssertEqual(invalidatedReducer.invalidateSession(epoch: epoch), .accepted)
        XCTAssertAuthority(
            invalidatedReducer.state.authority,
            unavailable: .sessionInvalidated
        )
        XCTAssertNil(invalidatedReducer.state.availableInventory)
        XCTAssertEqual(invalidatedReducer.state.authorityRevision.rawValue, .max)
    }

    func testCollectionWideMappedRangeLimitRejectsAtomically() throws {
        let stop = makeStop(lifecycle: 1, stop: 1)
        let observations = try (0..<257).map { moduleIndex in
            try XCTUnwrap(moduleWithMappedRangeCount(128, moduleIndex: moduleIndex))
        }
        XCTAssertEqual(observations.reduce(0) { $0 + $1.mappedRanges.count }, 32_896)

        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop.session)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop), .accepted)
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        let before = reducer.state
        XCTAssertEqual(
            reducer.acceptInventory(observations, observedStopID: 77, processID: 42, at: stop),
            .rejected(.invalidObservation)
        )
        XCTAssertEqual(reducer.state, before)
        XCTAssertEqual(
            reducer.failRefresh(
                processID: 42,
                at: stop,
                evidence: DebuggerRuntimeModuleFailureEvidence(redacting: "capacity")
            ),
            .accepted
        )
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory(
                [try XCTUnwrap(module(path: "/tmp/retry", backendIndex: 1))],
                observedStopID: 77,
                processID: 42,
                at: stop
            ),
            .accepted
        )
    }

    func testUnavailableStateRetainsNoPriorPathOrRangeEvidence() throws {
        let stop = makeStop(lifecycle: 1, stop: 1)
        let sensitivePath = "/private/secret/runtime-module.dylib"
        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop.session)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop), .accepted)
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        XCTAssertEqual(
            reducer.acceptInventory(
                [try XCTUnwrap(module(path: sensitivePath, backendIndex: 1))],
                observedStopID: 77,
                processID: 42,
                at: stop
            ),
            .accepted
        )
        XCTAssertEqual(reducer.transitionToRunning(processID: 42, session: stop.session), .accepted)

        let retainedState = String(reflecting: reducer)
        XCTAssertFalse(retainedState.contains(sensitivePath))
        XCTAssertFalse(retainedState.contains("__TEXT"))
        XCTAssertFalse(retainedState.contains("runtimeStart"))
    }

    func testStaleSessionStopAndUnadmittedCompletionCannotMutateState() throws {
        let stop = makeStop(lifecycle: 3, stop: 8)
        let staleStop = makeStop(lifecycle: 2, stop: 7)
        let foreignStop = DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(
                epoch: DebuggerSessionEpoch(),
                lifecycleRevision: DebuggerLifecycleRevision(rawValue: 3)
            ),
            stopRevision: DebuggerStopRevision(rawValue: 8)
        )
        let observed = try XCTUnwrap(module(path: "/tmp/stale.dylib", backendIndex: 1))
        var reducer = DebuggerRuntimeModuleInventoryReducer(session: stop.session)
        XCTAssertEqual(reducer.observeStopped(processID: 42, at: stop), .accepted)

        var before = reducer.state
        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: staleStop), .rejected(.staleSession))
        XCTAssertEqual(reducer.state, before)

        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: foreignStop), .rejected(.foreignEpoch))
        XCTAssertEqual(reducer.state, before)

        XCTAssertEqual(
            reducer.acceptInventory([observed], observedStopID: 77, processID: 42, at: stop),
            .rejected(.refreshNotAdmitted)
        )
        XCTAssertEqual(reducer.state, before)

        before = reducer.state
        XCTAssertEqual(
            reducer.acceptInventory([observed], observedStopID: 77, processID: 43, at: stop),
            .rejected(.wrongProcess)
        )
        XCTAssertEqual(reducer.state, before)
        XCTAssertEqual(
            reducer.acceptInventory([observed], observedStopID: 77, processID: 42, at: staleStop),
            .rejected(.staleSession)
        )
        XCTAssertEqual(reducer.state, before)

        XCTAssertEqual(reducer.admitRefresh(processID: 42, at: stop), .accepted)
        before = reducer.state
        XCTAssertEqual(
            reducer.acceptInventory(
                [observed, observed],
                observedStopID: 77,
                processID: 42,
                at: stop
            ),
            .rejected(.invalidObservation)
        )
        XCTAssertEqual(reducer.state, before)
    }

    private func XCTAssertAuthority(
        _ authority: DebuggerRuntimeModuleAuthority,
        unavailable reason: DebuggerRuntimeModuleUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(let actual) = authority else {
            XCTFail("Expected unavailable authority, got \(authority)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, reason, file: file, line: line)
    }

    private func makeStop(lifecycle: UInt64, stop: UInt64) -> DebuggerStopCoordinate {
        DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: DebuggerLifecycleRevision(rawValue: lifecycle)
            ),
            stopRevision: DebuggerStopRevision(rawValue: stop)
        )
    }

    private func mappedRange(
        staticStart: UInt64 = 0x1000,
        runtimeStart: UInt64 = 0x9000
    ) -> DebuggerRuntimeModuleMappedRangeObservation? {
        DebuggerRuntimeModuleMappedRangeObservation(
            sectionOrdinal: 0,
            sectionName: "__TEXT",
            staticStart: staticStart,
            runtimeStart: runtimeStart,
            byteCount: 0x100,
            permissions: 5
        )
    }

    private func module(
        path: String,
        backendIndex: UInt32,
        uuid: UUID? = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
        observedStopID: UInt32 = 77,
        staticStart: UInt64 = 0x1000,
        runtimeStart: UInt64 = 0x9000,
        triple: String = "arm64-apple-macosx"
    ) -> DebuggerRuntimeModuleObservation? {
        guard let range = mappedRange(staticStart: staticStart, runtimeStart: runtimeStart) else {
            return nil
        }
        let fingerprintInput = Data(
            "\(path)|\(staticStart)|\(runtimeStart)".utf8
        )
        let fingerprintSHA256 = Data(SHA256.hash(data: fingerprintInput))
        return DebuggerRuntimeModuleObservation(
            uuid: uuid,
            processID: 42,
            observedStopID: observedStopID,
            mappedRanges: [range],
            fullPath: path,
            normalizedArchitectureTriple: triple,
            displayIndex: backendIndex,
            fingerprintSHA256: fingerprintSHA256
        )
    }

    private func moduleWithMappedRangeCount(
        _ count: Int,
        moduleIndex: Int
    ) -> DebuggerRuntimeModuleObservation? {
        let ranges = (0..<count).compactMap { rangeIndex in
            DebuggerRuntimeModuleMappedRangeObservation(
                sectionOrdinal: UInt32(rangeIndex),
                sectionName: "__SEG\(rangeIndex)",
                staticStart: UInt64(0x1000 + moduleIndex * 0x10000 + rangeIndex * 0x100),
                runtimeStart: UInt64(0x1_0000_0000 + moduleIndex * 0x10000 + rangeIndex * 0x100),
                byteCount: 0x80,
                permissions: 5
            )
        }
        guard ranges.count == count else { return nil }
        return DebuggerRuntimeModuleObservation(
            uuid: uuid(moduleIndex + 100),
            processID: 42,
            observedStopID: 77,
            mappedRanges: ranges,
            fullPath: "/tmp/module-\(moduleIndex)",
            normalizedArchitectureTriple: "arm64-apple-macosx",
            displayIndex: UInt32(moduleIndex),
            fingerprintSHA256: Data(SHA256.hash(data: Data("module-\(moduleIndex)".utf8)))
        )
    }

    private func uuid(_ value: Int) -> UUID {
        let suffix = String(format: "%012X", value)
        return UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-\(suffix)")!
    }

    private func assertSendableAndHashable<T: Sendable & Hashable>(_ type: T.Type) {}
}
