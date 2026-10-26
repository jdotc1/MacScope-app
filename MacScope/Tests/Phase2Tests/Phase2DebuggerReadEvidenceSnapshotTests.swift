import XCTest
@testable import MacScope

final class Phase2DebuggerReadEvidenceSnapshotTests: XCTestCase {
    func testBuildsBoundedEvidenceForExactPausedCoordinate() throws {
        let fixture = try makeFixture()
        let evidence = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: fixture.snapshot,
            coordinate: fixture.coordinate
        ))

        XCTAssertEqual(evidence.coordinate, fixture.coordinate)
        XCTAssertEqual(evidence.frames.count, 5)
        XCTAssertEqual(evidence.registers.count, 16)
        XCTAssertEqual(evidence.memoryRegions.count, 5)
        XCTAssertEqual(evidence.memoryRegions.first?.previewBytes.count, 12)
        XCTAssertTrue(evidence.framesWereTruncated)
        XCTAssertTrue(evidence.registersWereTruncated)
        XCTAssertTrue(evidence.memoryRegionsWereTruncated)
        guard case .available(let scopes, let variablesWereTruncated) = evidence.variables else {
            return XCTFail("Expected exact stopped-frame variable evidence.")
        }
        XCTAssertEqual(scopes.map(\.kind), [.arguments, .locals, .statics])
        XCTAssertEqual(scopes.flatMap(\.variables).count, 64)
        XCTAssertTrue(variablesWereTruncated)
        XCTAssertEqual(scopes[0].variables[0].value, .value("0"))
        XCTAssertEqual(scopes[0].variables[1].value, .optimizedOut)
        XCTAssertEqual(scopes[1].variables[0].value, .unavailable(reason: "not materialized"))
        XCTAssertEqual(scopes[2].variables[0].value, .failed(reason: "evaluation failed"))
        let text = try XCTUnwrap(evidence.providerVisibleEvidenceText())
        XCTAssertTrue(text.contains("Selected thread: #2"), text)
        XCTAssertTrue(text.contains("Selected frame: #0"), text)
        XCTAssertTrue(text.contains("Variables (source truncated):"), text)
        XCTAssertTrue(text.contains("Arguments"), text)
        XCTAssertLessThanOrEqual(text.utf8.count, 4_096)
    }

    func testRejectsRunningAndContradictoryProcessAuthority() throws {
        let fixture = try makeFixture()
        var running = fixture.snapshot
        running.processState = .running(processID: 4242, executableName: "Fixture")
        XCTAssertNil(Phase2DebuggerReadEvidenceSnapshot(
            session: running,
            coordinate: fixture.coordinate
        ))

        var contradictory = fixture.snapshot
        contradictory.processState = .paused(processID: 9999, reason: .step)
        XCTAssertNil(Phase2DebuggerReadEvidenceSnapshot(
            session: contradictory,
            coordinate: fixture.coordinate
        ))
    }

    func testRejectsChangedStopTargetThreadAndFrameCoordinates() throws {
        let fixture = try makeFixture()

        var changedStop = fixture.snapshot
        changedStop.transportStopCoordinate = stop(stopRevision: 2)
        XCTAssertNil(Phase2DebuggerReadEvidenceSnapshot(
            session: changedStop,
            coordinate: fixture.coordinate
        ))

        var changedTarget = fixture.snapshot
        changedTarget.transportTargetAuthority = try authority(
            processID: 4242,
            executableSHA256: String(repeating: "b", count: 64)
        )
        XCTAssertNil(Phase2DebuggerReadEvidenceSnapshot(
            session: changedTarget,
            coordinate: fixture.coordinate
        ))

        var changedThread = fixture.snapshot
        changedThread.threads = changedThread.threads.map {
            DebuggerThreadSummary(
                index: $0.index,
                queueName: $0.queueName,
                stopReason: $0.stopReason,
                isSelected: $0.index == 1,
                topFrameAddress: $0.topFrameAddress,
                topFrameFunctionName: $0.topFrameFunctionName
            )
        }
        XCTAssertNil(Phase2DebuggerReadEvidenceSnapshot(
            session: changedThread,
            coordinate: fixture.coordinate
        ))

        var changedFrame = fixture.snapshot
        changedFrame.frames[0].address = 0xDEAD
        XCTAssertNil(Phase2DebuggerReadEvidenceSnapshot(
            session: changedFrame,
            coordinate: fixture.coordinate
        ))
    }

    func testFreshnessDistinguishesCoordinateChanges() throws {
        let fixture = try makeFixture()
        let evidence = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: fixture.snapshot,
            coordinate: fixture.coordinate
        ))
        XCTAssertEqual(
            evidence.freshness(
                currentCoordinate: fixture.coordinate,
                processState: fixture.snapshot.processState
            ),
            .fresh(fixture.coordinate)
        )
        XCTAssertEqual(
            evidence.freshness(
                currentCoordinate: fixture.coordinate,
                processState: .running(processID: 4242, executableName: "Fixture")
            ),
            .stale(reason: .processRunning)
        )

        let changedStop = try coordinate(
            stop: stop(stopRevision: 2),
            authority: fixture.authority,
            thread: fixture.thread,
            frameIndex: 0,
            address: 0x1000
        )
        XCTAssertEqual(
            evidence.freshness(currentCoordinate: changedStop, processState: fixture.snapshot.processState),
            .stale(reason: .stopChanged)
        )

        let changedFrame = try coordinate(
            stop: fixture.stop,
            authority: fixture.authority,
            thread: fixture.thread,
            frameIndex: 1,
            address: 0x1010
        )
        XCTAssertEqual(
            evidence.freshness(currentCoordinate: changedFrame, processState: fixture.snapshot.processState),
            .stale(reason: .frameChanged)
        )
    }

    func testZeroLimitsAreExplicitlyTruncatedAndNegativeLimitsReject() throws {
        let fixture = try makeFixture()
        let zero = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: fixture.snapshot,
            coordinate: fixture.coordinate,
            maximumFrames: 0,
            maximumRegisters: 0,
            maximumMemoryRegions: 0,
            maximumMemoryPreviewBytes: 0
        ))
        XCTAssertTrue(zero.frames.isEmpty)
        XCTAssertTrue(zero.registers.isEmpty)
        XCTAssertTrue(zero.memoryRegions.isEmpty)
        XCTAssertTrue(zero.framesWereTruncated)
        XCTAssertTrue(zero.registersWereTruncated)
        XCTAssertTrue(zero.memoryRegionsWereTruncated)
        XCTAssertNil(Phase2DebuggerReadEvidenceSnapshot(
            session: fixture.snapshot,
            coordinate: fixture.coordinate,
            maximumFrames: -1
        ))
    }

    func testEvidenceValuesAreSendable() {
        assertSendable(Phase2DebuggerReadEvidenceSnapshot.self)
        assertSendable(Phase2DebuggerFrameEvidence.self)
        assertSendable(Phase2DebuggerRegisterEvidence.self)
        assertSendable(Phase2DebuggerMemoryEvidence.self)
        assertSendable(Phase2DebuggerVariableScopeEvidence.self)
        assertSendable(Phase2DebuggerVariableEvidence.self)
    }

    func testVariableDigestChangesAtSameCoordinateAndProviderRowsRemainComplete() throws {
        let fixture = try makeFixture()
        let original = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: fixture.snapshot,
            coordinate: fixture.coordinate
        ))
        var changed = fixture.snapshot
        let changedNode = try variableNode(
            coordinate: fixture.coordinate,
            scope: .arguments,
            index: 0,
            value: .value("changed")
        )
        changed.variableScopes[0] = .init(
            coordinate: fixture.coordinate,
            scope: .arguments,
            nodes: [changedNode] + Array(changed.variableScopes[0].nodes.dropFirst()),
            wasTruncated: false
        )
        let updated = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: changed,
            coordinate: fixture.coordinate
        ))

        XCTAssertNotEqual(original.evidenceDigest, updated.evidenceDigest)
        let text = try XCTUnwrap(updated.providerVisibleEvidenceText(maximumUTF8Bytes: 700))
        XCTAssertLessThanOrEqual(text.utf8.count, 700)
        XCTAssertNotNil(
            text.range(
                of: #"\[Evidence truncated: omitted \d+ variable rows and \d+ variable scopes\.\]"#,
                options: .regularExpression
            ),
            text
        )
        XCTAssertFalse(text.hasSuffix("\u{FFFD}"), text)
    }

    func testProjectsAlreadyLoadedDescendantsInDeterministicPreorderWithoutExpansionAuthority() throws {
        let fixture = try makeFixture()
        var snapshot = fixture.snapshot
        let rootPath = ["arguments", "0", "root"]
        let childPath = rootPath + ["0", "child"]
        let grandchild = try nestedVariableNode(
            coordinate: fixture.coordinate,
            components: childPath + ["0", "grandchild"],
            value: .value("3")
        )
        let child = try nestedVariableNode(
            coordinate: fixture.coordinate,
            components: childPath,
            value: .value("2"),
            childCount: 1,
            children: [grandchild],
            childExpansion: .loaded
        )
        let root = try nestedVariableNode(
            coordinate: fixture.coordinate,
            components: rootPath,
            value: .value("1"),
            childCount: 2,
            children: [child],
            childExpansion: .loaded
        )
        snapshot.variableScopes[0] = .init(
            coordinate: fixture.coordinate,
            scope: .arguments,
            nodes: [root],
            wasTruncated: false
        )

        let evidence = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: snapshot,
            coordinate: fixture.coordinate,
            maximumVariables: 3
        ))
        guard case .available(let scopes, let wasTruncated) = evidence.variables else {
            return XCTFail("Expected variable evidence")
        }
        let rows = scopes[0].variables
        XCTAssertEqual(rows.map(\.name), ["root", "child", "grandchild"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
        XCTAssertEqual(rows.map(\.loadedChildCount), [1, 1, 0])
        XCTAssertEqual(rows.map(\.childExpansion), [.loaded, .loaded, .notLoaded])
        XCTAssertEqual(rows.map(\.descendantsWereTruncated), [false, false, false])
        XCTAssertTrue(wasTruncated, "Later scopes must share the same global budget.")
        let text = try XCTUnwrap(evidence.providerVisibleEvidenceText())
        XCTAssertTrue(text.contains("  - child"), text)
        XCTAssertTrue(text.contains("    - grandchild"), text)
        XCTAssertTrue(text.contains("loaded 1/2 children"), text)

        let changedGrandchild = try nestedVariableNode(
            coordinate: fixture.coordinate,
            components: childPath + ["0", "grandchild"],
            value: .value("changed")
        )
        let changedChild = try nestedVariableNode(
            coordinate: fixture.coordinate,
            components: childPath,
            value: .value("2"),
            childCount: 1,
            children: [changedGrandchild],
            childExpansion: .loaded
        )
        let changedRoot = try nestedVariableNode(
            coordinate: fixture.coordinate,
            components: rootPath,
            value: .value("1"),
            childCount: 2,
            children: [changedChild],
            childExpansion: .loaded
        )
        snapshot.variableScopes[0] = .init(
            coordinate: fixture.coordinate,
            scope: .arguments,
            nodes: [changedRoot],
            wasTruncated: false
        )
        let changedEvidence = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: snapshot,
            coordinate: fixture.coordinate,
            maximumVariables: 3
        ))
        XCTAssertNotEqual(evidence.evidenceDigest, changedEvidence.evidenceDigest)
    }

    func testGlobalVariableBudgetMarksPartiallyProjectedLoadedDescendants() throws {
        let fixture = try makeFixture()
        var snapshot = fixture.snapshot
        let rootPath = ["arguments", "0", "root"]
        let children = try (0..<64).map { index in
            try nestedVariableNode(
                coordinate: fixture.coordinate,
                components: rootPath + [String(index), "child_\(index)"],
                value: .value("\(index)")
            )
        }
        let root = try nestedVariableNode(
            coordinate: fixture.coordinate,
            components: rootPath,
            value: .value("root"),
            childCount: children.count,
            children: children,
            childExpansion: .loaded
        )
        snapshot.variableScopes = [
            .init(
                coordinate: fixture.coordinate,
                scope: .arguments,
                nodes: [root],
                wasTruncated: false
            ),
        ]

        let evidence = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: snapshot,
            coordinate: fixture.coordinate
        ))
        guard case .available(let scopes, let wasTruncated) = evidence.variables else {
            return XCTFail("Expected variable evidence")
        }
        XCTAssertEqual(scopes[0].variables.count, 64)
        XCTAssertTrue(wasTruncated)
        XCTAssertTrue(scopes[0].wasTruncated)
        XCTAssertTrue(scopes[0].variables[0].descendantsWereTruncated)
        XCTAssertEqual(scopes[0].variables[0].loadedChildCount, 64)
    }

    func testRejectsMismatchedVariableScopeCoordinateWithoutPublishingRows() throws {
        let fixture = try makeFixture()
        var mismatched = fixture.snapshot
        let staleCoordinate = try coordinate(
            stop: stop(stopRevision: 2),
            authority: fixture.authority,
            thread: fixture.thread,
            frameIndex: 0,
            address: 0x1000
        )
        mismatched.variableScopes[0] = .init(
            coordinate: staleCoordinate,
            scope: mismatched.variableScopes[0].scope,
            nodes: mismatched.variableScopes[0].nodes,
            wasTruncated: mismatched.variableScopes[0].wasTruncated
        )
        let evidence = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: mismatched,
            coordinate: fixture.coordinate
        ))

        XCTAssertEqual(evidence.variables, .unavailable(reason: .ambiguousSourceEvidence))
        let text = try XCTUnwrap(evidence.providerVisibleEvidenceText())
        XCTAssertTrue(text.contains("Variables: unavailable — ambiguousSourceEvidence"), text)
        XCTAssertFalse(text.contains("arguments_0"), text)
    }

    func testVariableByteBudgetReservesDeterministicOmissionCounts() throws {
        let fixture = try makeFixture()
        let evidence = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: fixture.snapshot,
            coordinate: fixture.coordinate
        ))
        guard case .available(let scopes, let wasTruncated) = evidence.variables else {
            return XCTFail("Expected available variables")
        }

        let first = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot.completeVariableLineBoundedText(
            prefixLines: ["P"],
            scopes: scopes,
            evidenceWasTruncated: wasTruncated,
            maximumUTF8Bytes: 75
        ))
        let second = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot.completeVariableLineBoundedText(
            prefixLines: ["P"],
            scopes: scopes,
            evidenceWasTruncated: wasTruncated,
            maximumUTF8Bytes: 75
        ))

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first,
            "P\n[Evidence truncated: omitted 64 variable rows and 3 variable scopes.]"
        )
        XCTAssertLessThanOrEqual(first.utf8.count, 75)
    }

    func testLegacySnapshotWithoutPublishedScopesRemainsHonestlyUnavailable() throws {
        let fixture = try makeFixture()
        var legacy = fixture.snapshot
        legacy.variableScopes = []
        let evidence = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: legacy,
            coordinate: fixture.coordinate
        ))

        XCTAssertEqual(evidence.variables, .unavailable(reason: .unsupportedCapability))
        XCTAssertTrue(
            try XCTUnwrap(evidence.providerVisibleEvidenceText())
                .contains("Variables: unavailable — unsupportedCapability")
        )
    }

    func testProviderEvidencePrioritizesCoordinateBeforeBoundedStatusText() throws {
        let fixture = try makeFixture()
        var snapshot = fixture.snapshot
        snapshot.statusMessage = String(repeating: "🧭", count: 2_000)
        let evidence = try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: snapshot,
            coordinate: fixture.coordinate
        ))

        let text = try XCTUnwrap(evidence.providerVisibleEvidenceText(maximumUTF8Bytes: 512))

        XCTAssertLessThanOrEqual(text.utf8.count, 512)
        XCTAssertTrue(text.contains("Target identity digest:"), text)
        XCTAssertTrue(text.contains("Session epoch:"), text)
        XCTAssertTrue(text.contains("Stop revision: 1"), text)
        XCTAssertTrue(text.contains("Selected thread: #2"), text)
        XCTAssertTrue(text.contains("Selected frame: #0 0x0000000000001000"), text)
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "Selected frame:")?.lowerBound),
            try XCTUnwrap(text.range(of: "Debugger state:")?.lowerBound)
        )
    }

    @MainActor
    func testPublishingEvidenceDoesNotRecordAuthorityUntilExactConsumption() throws {
        let fixture = try makeFixture()
        let store = WorkspaceStore(
            workspaceName: "Debugger evidence",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )

        store.updatePhase2DebuggerReadOnlySnapshot(
            fixture.snapshot,
            inspectionCoordinate: fixture.coordinate
        )

        XCTAssertTrue(store.phase2RuntimeAuthorityRecords.isEmpty)
        let evidence = try XCTUnwrap(store.phase2DebuggerReadEvidenceSnapshot)
        XCTAssertTrue(store.recordPhase2DebuggerReadOnlyRuntimeAuthorityConsumption(
            evidenceDigest: evidence.evidenceDigest
        ))
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.surfaces, [.debuggerReadOnly])
        XCTAssertFalse(store.recordPhase2DebuggerReadOnlyRuntimeAuthorityConsumption(
            evidenceDigest: String(repeating: "0", count: 64)
        ))
    }

    private struct Fixture {
        let stop: DebuggerStopCoordinate
        let authority: DebuggerSessionTargetAuthority
        let thread: DebuggerThreadIdentity
        let coordinate: DebuggerInspectionCoordinate
        let snapshot: DebuggerSessionSnapshot
    }

    private func makeFixture() throws -> Fixture {
        let fixtureStop = stop()
        let fixtureAuthority = try authority(processID: 4242)
        let selectedThreadSummary = DebuggerThreadSummary(
            index: 2,
            queueName: "main",
            stopReason: .breakpoint(address: 0x1000),
            isSelected: true,
            topFrameAddress: 0x1000,
            topFrameFunctionName: "frame_0"
        )
        let fixtureThread = try XCTUnwrap(DebuggerThreadIdentity(summary: selectedThreadSummary))
        let fixtureCoordinate = try coordinate(
            stop: fixtureStop,
            authority: fixtureAuthority,
            thread: fixtureThread,
            frameIndex: 0,
            address: 0x1000
        )
        let frames = (0..<7).map {
            DebuggerFrameSummary(
                index: $0,
                address: 0x1000 + UInt64($0 * 0x10),
                functionName: "frame_\($0)",
                moduleName: "Fixture",
                sourceLocation: nil
            )
        }
        let registers = (0..<18).map {
            DebuggerRegisterSummary(name: "x\($0)", value: "0x\($0)")
        }
        let memory = (0..<7).map {
            DebuggerMemorySummary(
                address: 0x2000 + UInt64($0 * 0x100),
                byteCount: 32,
                previewBytes: Array(0..<32),
                label: "region_\($0)"
            )
        }
        let arguments = try (0..<20).map { index in
            try variableNode(
                coordinate: fixtureCoordinate,
                scope: .arguments,
                index: index,
                value: index == 1 ? .optimizedOut : .value("\(index)")
            )
        }
        let locals = try (0..<20).map { index in
            try variableNode(
                coordinate: fixtureCoordinate,
                scope: .locals,
                index: index,
                value: index == 0 ? .unavailable(reason: "not materialized") : .value("local-\(index)")
            )
        }
        let statics = try (0..<30).map { index in
            try variableNode(
                coordinate: fixtureCoordinate,
                scope: .statics,
                index: index,
                value: index == 0 ? .failed(reason: "evaluation failed") : .value("static-\(index)")
            )
        }
        let snapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 4242, reason: .breakpoint(address: 0x1000)),
            breakpoints: [],
            threads: [selectedThreadSummary],
            frames: frames,
            registers: registers,
            memoryRegions: memory,
            variableScopes: [
                .init(coordinate: fixtureCoordinate, scope: .arguments, nodes: arguments, wasTruncated: false),
                .init(coordinate: fixtureCoordinate, scope: .locals, nodes: locals, wasTruncated: false),
                .init(coordinate: fixtureCoordinate, scope: .statics, nodes: statics, wasTruncated: false),
            ],
            statusMessage: "Stopped.",
            backendState: .connected(processID: 4242, adapterName: "Fixture LLDB"),
            transportSessionCoordinate: fixtureStop.session,
            transportStopCoordinate: fixtureStop,
            transportEventSequence: DebuggerEventSequence(rawValue: 1),
            transportTargetDisposition: .stopped(processID: 4242),
            transportTargetAuthority: fixtureAuthority
        )
        return Fixture(
            stop: fixtureStop,
            authority: fixtureAuthority,
            thread: fixtureThread,
            coordinate: fixtureCoordinate,
            snapshot: snapshot
        )
    }

    private func variableNode(
        coordinate: DebuggerInspectionCoordinate,
        scope: DebuggerVariableScopeKind,
        index: Int,
        value: DebuggerVariableValueState
    ) throws -> DebuggerVariableNode {
        let name = "\(scope.rawValue)_\(index)"
        let token = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: [scope.rawValue, name]
        ))
        return try XCTUnwrap(DebuggerVariableNode(
            id: token,
            name: name,
            typeName: "Int",
            value: value,
            childCount: index == 0 ? 2 : 0
        ))
    }

    private func nestedVariableNode(
        coordinate: DebuggerInspectionCoordinate,
        components: [String],
        value: DebuggerVariableValueState,
        childCount: Int = 0,
        children: [DebuggerVariableNode] = [],
        childExpansion: DebuggerVariableChildExpansionState? = nil
    ) throws -> DebuggerVariableNode {
        let token = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: components
        ))
        return try XCTUnwrap(DebuggerVariableNode(
            id: token,
            name: try XCTUnwrap(components.last),
            typeName: "Node",
            value: value,
            childCount: childCount,
            pathComponents: components,
            children: children,
            childExpansion: childExpansion
        ))
    }

    private func stop(stopRevision: UInt64 = 1) -> DebuggerStopCoordinate {
        DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(
                epoch: DebuggerSessionEpoch(
                    rawValue: UUID(uuidString: "88888888-2222-3333-4444-555555555555")!
                ),
                lifecycleRevision: DebuggerLifecycleRevision(rawValue: 3)
            ),
            stopRevision: DebuggerStopRevision(rawValue: stopRevision)
        )
    }

    private func coordinate(
        stop: DebuggerStopCoordinate,
        authority: DebuggerSessionTargetAuthority,
        thread: DebuggerThreadIdentity,
        frameIndex: Int,
        address: UInt64
    ) throws -> DebuggerInspectionCoordinate {
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: frameIndex,
            programCounter: address,
            canonicalFunctionName: "frame_\(frameIndex)"
        ))
        return try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: frame
        ))
    }

    private func authority(
        processID: Int32,
        executableSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DebuggerSessionTargetAuthority {
        let start = try XCTUnwrap(DebuggerProcessStartIdentity(
            seconds: 1_700_000_000,
            microseconds: 42
        ))
        let identity = try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: start,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            executableDeviceID: 10,
            executableFileID: UInt64(processID) + 1_000,
            executableByteCount: 4_096,
            executableSHA256: executableSHA256,
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        ))
        return DebuggerSessionTargetAuthority(origin: .attached(identity))
    }

    private func assertSendable<T: Sendable>(_ type: T.Type) {}
}
