import XCTest
@testable import MacScope

final class DebuggerInspectionPresentationModelTests: XCTestCase {
    func testSourcePresentationRequiresLiveExactMappedAndSealedEvidence() {
        let fixture = try! Self.sourceFixture()

        XCTAssertEqual(
            DebuggerSourceInspectionPresentation.resolve(
                hasLiveProcessSession: false,
                coordinate: fixture.coordinate,
                selectedFrameResolvedStaticAddress: fixture.resolvedAddress,
                sourceLines: [fixture.sourceLine],
                focusedImageSlot: .primary
            ),
            .unavailable("No live debug process")
        )
        XCTAssertEqual(
            DebuggerSourceInspectionPresentation.resolve(
                hasLiveProcessSession: true,
                coordinate: nil,
                selectedFrameResolvedStaticAddress: fixture.resolvedAddress,
                sourceLines: [fixture.sourceLine],
                focusedImageSlot: .primary
            ),
            .unavailable("No exact stopped-frame identity")
        )
        XCTAssertEqual(
            DebuggerSourceInspectionPresentation.resolve(
                hasLiveProcessSession: true,
                coordinate: fixture.coordinate,
                selectedFrameResolvedStaticAddress: nil,
                sourceLines: [fixture.sourceLine],
                focusedImageSlot: .primary
            ),
            .unavailable("Runtime PC is not mapped to the workspace")
        )
        XCTAssertEqual(
            DebuggerSourceInspectionPresentation.resolve(
                hasLiveProcessSession: true,
                coordinate: fixture.coordinate,
                selectedFrameResolvedStaticAddress: fixture.resolvedAddress,
                sourceLines: [],
                focusedImageSlot: .primary
            ),
            .unavailable("No source row for selected frame")
        )

        var unsealed = fixture.sourceLine
        unsealed.debugArtifactMachOSHA256 = nil
        XCTAssertEqual(
            DebuggerSourceInspectionPresentation.resolve(
                hasLiveProcessSession: true,
                coordinate: fixture.coordinate,
                selectedFrameResolvedStaticAddress: fixture.resolvedAddress,
                sourceLines: [unsealed],
                focusedImageSlot: .primary
            ),
            .unavailable("Source row is missing exact debug-artifact seal")
        )
    }

    func testSourcePresentationReportsFreshLocationForStrictlyResolvedSourceLine() throws {
        let fixture = try Self.sourceFixture(file: "/tmp/main.swift", line: 42)
        let presentation = DebuggerSourceInspectionPresentation.resolve(
            hasLiveProcessSession: true,
            coordinate: fixture.coordinate,
            selectedFrameResolvedStaticAddress: fixture.resolvedAddress,
            sourceLines: [fixture.sourceLine],
            focusedImageSlot: .primary
        )

        XCTAssertEqual(presentation, .fresh("/tmp/main.swift:42"))
        XCTAssertTrue(presentation.isFresh)
        XCTAssertEqual(presentation.title, "Source fresh")
        XCTAssertEqual(presentation.detail, "/tmp/main.swift:42")
    }

    func testSourcePresentationRejectsDebugArtifactMismatch() throws {
        var fixture = try Self.sourceFixture()
        fixture.sourceLine.debugArtifactUUID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        let presentation = DebuggerSourceInspectionPresentation.resolve(
            hasLiveProcessSession: true,
            coordinate: fixture.coordinate,
            selectedFrameResolvedStaticAddress: fixture.resolvedAddress,
            sourceLines: [fixture.sourceLine],
            focusedImageSlot: .primary
        )

        XCTAssertEqual(presentation, .unavailable("Source debug artifact does not match selected binary"))
        XCTAssertFalse(presentation.isFresh)
    }

    func testInspectionStatusPresentationSummarizesSelectedThreadFrameAndSource() {
        let presentation = DebuggerInspectionStatusPresentation(
            hasInspectionCoordinate: true,
            sourceStatus: .fresh("/tmp/main.swift:42"),
            selectedThread: DebuggerThreadSummary(
                index: 3,
                queueName: "com.example.worker",
                stopReason: .breakpoint(address: 0x1000),
                isSelected: true,
                topFrameAddress: 0x1000,
                topFrameFunctionName: "main"
            ),
            selectedFrame: DebuggerFrameSummary(
                index: 1,
                address: 0x1000,
                functionName: "main",
                moduleName: "Fixture",
                sourceLocation: "/tmp/main.swift:42"
            )
        )

        XCTAssertEqual(presentation.coordinateTitle, "Frame identity exact")
        XCTAssertEqual(
            presentation.summary,
            "thread #3 com.example.worker · frame #1 main 0x0000000000001000 · /tmp/main.swift:42"
        )
        XCTAssertEqual(
            presentation.accessibilitySummary,
            "Frame identity exact. Source fresh: /tmp/main.swift:42. thread #3 com.example.worker. frame #1 main 0x0000000000001000."
        )
    }

    func testVariablesPresentationClearsRowsWithoutExactCoordinate() throws {
        let fixture = try Self.sourceFixture()
        let unavailable = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: nil,
            selectedFrame: nil,
            variableScopes: [Self.variableScope(coordinate: fixture.coordinate)]
        )
        XCTAssertEqual(unavailable.selectedFrameValue, "No selected frame")
        XCTAssertEqual(unavailable.frameDetail, "exact stopped-frame identity unavailable")
        XCTAssertEqual(
            unavailable.variableStatusText,
            "Variables unavailable until the process is paused with exact thread and frame identity."
        )
        XCTAssertTrue(unavailable.groups.isEmpty)
    }

    func testVariablesPresentationGroupsTypedStatesAndTruncation() throws {
        let fixture = try Self.sourceFixture()
        let presentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: fixture.coordinate,
            selectedFrame: DebuggerFrameSummary(
                index: 0,
                address: 0x1010,
                functionName: "callee",
                moduleName: nil,
                sourceLocation: nil
            ),
            variableScopes: [
                Self.variableScope(coordinate: fixture.coordinate),
                DebuggerVariableScopeSnapshot(
                    coordinate: fixture.coordinate,
                    scope: .locals,
                    nodes: [],
                    wasTruncated: false
                )
            ]
        )
        XCTAssertEqual(presentation.selectedFrameValue, "#0 callee 0x0000000000001010")
        XCTAssertEqual(presentation.frameDetail, "exact stopped-frame identity")
        XCTAssertEqual(
            presentation.variableStatusText,
            "Variables are bound to the current exact stopped frame."
        )
        XCTAssertEqual(presentation.groups.map(\.title), ["Arguments", "Locals"])
        XCTAssertEqual(presentation.groups[0].rows.map(\.value), [
            "7", "Optimized out", "Unavailable: no location", "Failed: LLDB read failed"
        ])
        XCTAssertEqual(presentation.groups[0].rows.map(\.valueTone), [
            .value, .optimizedOut, .unavailable, .failed
        ])
        XCTAssertEqual(presentation.groups[0].rows[0].childCount, 2)
        XCTAssertEqual(presentation.groups[0].rows[0].childAvailabilityText, "2 children available")
        XCTAssertEqual(presentation.groups[0].rows[0].childExpansionText, "Children not loaded")
        XCTAssertEqual(presentation.groups[0].rows[0].detailText, "Int · 2 children available · Children not loaded")
        XCTAssertNil(presentation.groups[0].rows[1].childAvailabilityText)
        XCTAssertEqual(presentation.groups[0].rows[1].detailText, "Bool")
        XCTAssertTrue(presentation.groups[0].wasTruncated)
        XCTAssertEqual(presentation.groups[1].emptyText, "No locals in this frame.")
    }

    func testVariablesPresentationFlattensLoadedChildrenWithDepth() throws {
        let fixture = try Self.sourceFixture()
        let parentComponents = ["arguments", "0", "pair"]
        let childComponents = parentComponents + ["left"]
        let child = DebuggerVariableNode(
            id: DebuggerVariablePathToken(
                coordinate: fixture.coordinate,
                components: childComponents
            )!,
            name: "left",
            typeName: "Int",
            value: .value("1"),
            childCount: 0,
            pathComponents: childComponents
        )!
        let parent = DebuggerVariableNode(
            id: DebuggerVariablePathToken(
                coordinate: fixture.coordinate,
                components: parentComponents
            )!,
            name: "pair",
            typeName: "Pair",
            value: .value("{...}"),
            childCount: 1,
            pathComponents: parentComponents,
            children: [child]
        )!

        let presentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: fixture.coordinate,
            selectedFrame: nil,
            variableScopes: [
                DebuggerVariableScopeSnapshot(
                    coordinate: fixture.coordinate,
                    scope: .arguments,
                    nodes: [parent],
                    wasTruncated: false
                )
            ]
        )

        XCTAssertEqual(presentation.groups[0].rows.map(\.name), ["pair", "left"])
        XCTAssertEqual(presentation.groups[0].rows.map(\.depth), [0, 1])
        XCTAssertTrue(presentation.groups[0].rows[0].isExpandable)
        XCTAssertTrue(presentation.groups[0].rows[0].isExpanded)
        XCTAssertEqual(presentation.groups[0].rows[0].childExpansionText, "1 loaded")
        XCTAssertFalse(presentation.groups[0].rows[1].isExpandable)
    }

    func testVariablesPresentationCollapsesLoadedDescendantsAndBlocksDuplicateLoadingRequest() throws {
        let fixture = try Self.sourceFixture()
        let loadedComponents = ["arguments", "0", "pair"]
        let childComponents = loadedComponents + ["0", "left"]
        let child = DebuggerVariableNode(
            id: DebuggerVariablePathToken(
                coordinate: fixture.coordinate,
                components: childComponents
            )!,
            name: "left",
            typeName: "Int",
            value: .value("1"),
            childCount: 0,
            pathComponents: childComponents
        )!
        let loaded = DebuggerVariableNode(
            id: DebuggerVariablePathToken(
                coordinate: fixture.coordinate,
                components: loadedComponents
            )!,
            name: "pair",
            typeName: "Pair",
            value: .value("{...}"),
            childCount: 1,
            pathComponents: loadedComponents,
            children: [child]
        )!
        let loadingComponents = ["arguments", "1", "pending"]
        let loading = DebuggerVariableNode(
            id: DebuggerVariablePathToken(
                coordinate: fixture.coordinate,
                components: loadingComponents
            )!,
            name: "pending",
            typeName: "Pair",
            value: .value("{...}"),
            childCount: 1,
            pathComponents: loadingComponents,
            childExpansion: .loading
        )!
        let presentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: fixture.coordinate,
            selectedFrame: nil,
            variableScopes: [
                DebuggerVariableScopeSnapshot(
                    coordinate: fixture.coordinate,
                    scope: .arguments,
                    nodes: [loaded, loading],
                    wasTruncated: false
                )
            ],
            collapsedTokens: [loaded.id],
            expansionStates: [loading.id: .loading],
            activeExpansionToken: loading.id
        )

        XCTAssertEqual(presentation.groups[0].rows.map(\.name), ["pair", "pending"])
        XCTAssertTrue(presentation.groups[0].rows[0].isCollapsed)
        XCTAssertFalse(presentation.groups[0].rows[0].isExpanded)
        XCTAssertEqual(presentation.groups[0].rows[0].pathComponents, loadedComponents)
        XCTAssertEqual(presentation.groups[0].rows[1].expansionState, .loading)
        XCTAssertEqual(presentation.groups[0].rows[1].childExpansionText, "Loading children…")
        XCTAssertFalse(presentation.groups[0].rows[1].canRequestExpansion)
    }

    func testVariablesPresentationReportsExactProjectionUnavailable() throws {
        let fixture = try Self.sourceFixture()
        let presentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: fixture.coordinate,
            selectedFrame: nil,
            variableScopes: []
        )
        XCTAssertTrue(presentation.groups.isEmpty)
        XCTAssertEqual(
            presentation.variableStatusText,
            "Variable projection is unavailable for this exact stopped frame."
        )
    }

    func testVariablesPresentationMasksRowsFromDifferentThread() throws {
        let fixture = try Self.sourceFixture()
        let staleCoordinate = try Self.coordinate(
            basedOn: fixture.coordinate,
            targetAuthority: fixture.targetAuthority,
            threadIndex: fixture.coordinate.thread.index + 1,
            frameIndex: fixture.coordinate.frame.frameIndex,
            programCounter: fixture.coordinate.frame.programCounter
        )
        let presentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: fixture.coordinate,
            selectedFrame: nil,
            variableScopes: [Self.variableScope(coordinate: staleCoordinate)]
        )

        XCTAssertTrue(presentation.groups.isEmpty)
        XCTAssertEqual(
            presentation.variableStatusText,
            "Variables are refreshing for the current stopped frame."
        )
    }

    func testVariablesPresentationMasksAllRowsWhenOneScopeUsesDifferentFrame() throws {
        let fixture = try Self.sourceFixture()
        let staleCoordinate = try Self.coordinate(
            basedOn: fixture.coordinate,
            targetAuthority: fixture.targetAuthority,
            threadIndex: fixture.coordinate.thread.index,
            frameIndex: fixture.coordinate.frame.frameIndex + 1,
            programCounter: fixture.coordinate.frame.programCounter + 4
        )
        let staleLocals = DebuggerVariableScopeSnapshot(
            coordinate: staleCoordinate,
            scope: .locals,
            nodes: [],
            wasTruncated: false
        )
        let presentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: fixture.coordinate,
            selectedFrame: nil,
            variableScopes: [
                Self.variableScope(coordinate: fixture.coordinate),
                staleLocals
            ]
        )

        XCTAssertTrue(presentation.groups.isEmpty)
        XCTAssertEqual(
            presentation.variableStatusText,
            "Variables are refreshing for the current stopped frame."
        )
    }

    func testMemoryPresentationSeparatesStaleGatedAndFrameBoundStates() {
        let stale = DebuggerMemoryInspectionPresentation(
            hasInspectionCoordinate: false,
            regionCount: 0
        )
        XCTAssertEqual(stale.coordinateTitle, "Memory preview stale-gated")
        XCTAssertEqual(stale.detail, "No VM regions recovered for this stopped snapshot.")
        XCTAssertEqual(
            stale.accessibilitySummary,
            "Memory preview stale-gated. No VM regions recovered for this stopped snapshot."
        )

        let frameBound = DebuggerMemoryInspectionPresentation(
            hasInspectionCoordinate: true,
            regionCount: 2
        )
        XCTAssertEqual(frameBound.coordinateTitle, "Memory preview frame-bound")
        XCTAssertEqual(
            frameBound.detail,
            "2 VM regions recovered; read/write controls remain gated by paused live-process freshness."
        )
    }

    private struct SourceFixture {
        let coordinate: DebuggerInspectionCoordinate
        let targetAuthority: DebuggerSessionTargetAuthority
        let resolvedAddress: DebuggerResolvedStaticAddress
        var sourceLine: SourceLineEntry
    }

    private static func variableScope(
        coordinate: DebuggerInspectionCoordinate
    ) -> DebuggerVariableScopeSnapshot {
        let values: [(String, String?, DebuggerVariableValueState, Int)] = [
            ("count", "Int", .value("7"), 2),
            ("cached", "Bool", .optimizedOut, 0),
            ("buffer", nil, .unavailable(reason: "no location"), 0),
            ("result", "Result", .failed(reason: "LLDB read failed"), 0)
        ]
        let nodes = values.enumerated().map { index, entry in
            DebuggerVariableNode(
                id: DebuggerVariablePathToken(
                    coordinate: coordinate,
                    components: ["argument", "\(index)"]
                )!,
                name: entry.0,
                typeName: entry.1,
                value: entry.2,
                childCount: entry.3
            )!
        }
        return DebuggerVariableScopeSnapshot(
            coordinate: coordinate,
            scope: .arguments,
            nodes: nodes,
            wasTruncated: true
        )
    }

    private static func coordinate(
        basedOn coordinate: DebuggerInspectionCoordinate,
        targetAuthority: DebuggerSessionTargetAuthority,
        threadIndex: Int,
        frameIndex: Int,
        programCounter: UInt64
    ) throws -> DebuggerInspectionCoordinate {
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: threadIndex, tid: UInt64(threadIndex)))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: frameIndex,
            programCounter: programCounter,
            canonicalFunctionName: "alternate"
        ))
        return try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: coordinate.stop,
            targetAuthority: targetAuthority,
            thread: thread,
            frame: frame
        ))
    }

    private static func sourceFixture(
        file: String = "/tmp/source.c",
        line: Int = 7
    ) throws -> SourceFixture {
        let stop = DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(
                epoch: DebuggerSessionEpoch(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
                lifecycleRevision: DebuggerLifecycleRevision(rawValue: 3)
            ),
            stopRevision: DebuggerStopRevision(rawValue: 1)
        )
        let processStart = try XCTUnwrap(DebuggerProcessStartIdentity(seconds: 1_700_000_000, microseconds: 42))
        let processIdentity = try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 123,
            startTime: processStart,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            executableDeviceID: 10,
            executableFileID: 1_123,
            executableByteCount: 4096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        ))
        let authority = try DebuggerSessionTargetAuthority(origin: .attached(processIdentity))
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 0xabc))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 0,
            programCounter: 0x2000,
            canonicalFunctionName: "main"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: frame
        ))
        let mappingKey = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: stop,
            observedPID: 123,
            authorityRevision: DebuggerRuntimeModuleAuthorityRevision(rawValue: 3),
            inventoryRevision: DebuggerRuntimeModuleInventoryRevision(rawValue: 7),
            workspaceCatalogRevision: DebuggerWorkspaceArtifactCatalogRevision(rawValue: 11)
        )
        let workspaceCoordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            slot: .primary,
            artifactIdentity: try MachOSliceArtifactIdentity(
                uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                rawCPUType: MachOConstants.cpuTypeARM64,
                rawCPUSubtype: 0,
                selectedSliceSHA256: String(repeating: "c", count: 64),
                selectedSliceByteCount: 16_384
            ),
            ownerRevision: DebuggerWorkspaceArtifactOwnerRevision(rawValue: 5)
        )
        let resolvedAddress = DebuggerResolvedStaticAddress(
            projectionKey: mappingKey,
            moduleInstanceID: DebuggerRuntimeModuleInstanceID(
                processID: 123,
                stop: stop,
                inventoryRevision: mappingKey.inventoryRevision,
                ordinal: 0
            ),
            workspaceCoordinate: workspaceCoordinate,
            runtimeAddress: 0x2000,
            imageAddress: .primary(0x1000)
        )
        let sourceLine = SourceLineEntry(
            address: 0x1000,
            file: file,
            line: line,
            column: 1,
            endSequence: false,
            debugArtifactUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            debugArtifactMachOSHA256: String(repeating: "a", count: 64),
            debugArtifactMachOByteCount: 4096,
            lineProgramUnitOffset: 1,
            fileTableIndex: 2,
            tablePath: .absoluteUTF8(file)
        )
        return SourceFixture(
            coordinate: coordinate,
            targetAuthority: authority,
            resolvedAddress: resolvedAddress,
            sourceLine: sourceLine
        )
    }
}
