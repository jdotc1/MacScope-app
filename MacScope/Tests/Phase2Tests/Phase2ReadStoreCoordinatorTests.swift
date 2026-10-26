import XCTest
@testable import MacScope

@MainActor
final class Phase2ReadStoreCoordinatorTests: XCTestCase {
    func testExternalPreparedReadsPreserveCoordinatorReplaySemantics() throws {
        let store = makeStore()
        let persistent = try prepared(.workspaceSummary, in: store)
        let persistentEvidence = try XCTUnwrap(store.executePhase2Read(persistent).acceptedEvidence)
        for principal in [Phase2Principal.cli, .mcp] {
            guard case .prepared(let read) = store.preparePhase2Read(
                operation: .workspaceSummary, proposingPrincipal: principal
            ) else { return XCTFail("Expected external preparation") }
            let execution = store.executePhase2Read(read)
            XCTAssertEqual(execution.disposition, .accepted)
            XCTAssertNotNil(execution.acceptedEvidence)
            XCTAssertNotNil(store.acceptedPhase2Evidence(invocationID: read.authorization.request.invocationID))
            XCTAssertEqual(store.executePhase2Read(read).disposition, .duplicate)
        }
        XCTAssertEqual(store.acceptedPhase2Evidence(invocationID: persistentEvidence.invocationID), persistentEvidence)
        XCTAssertNoThrow(try store.compilePhase2GroundedContext(invocationIDs: [persistentEvidence.invocationID]))
    }

    func testExternalPrincipalsMayProposeOnlyClosedSummaryAndFunctionReads() throws {
        let store = makeStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        for principal in [Phase2Principal.cli, .mcp] {
            for operation in [Phase2ReadOperationID.workspaceSummary, .applicationGraphSummary, .functionReview] {
                guard case .prepared(let read) = store.preparePhase2Read(
                    operation: operation, proposingPrincipal: principal
                ) else { return XCTFail("External bounded read must receive app authorization") }
                XCTAssertEqual(read.authorization.request.proposingPrincipal, principal)
                XCTAssertEqual(read.authorization.authorizingPrincipal, .app)
                XCTAssertEqual(store.executePhase2Read(read).disposition, .accepted)
            }
            for operation in [Phase2ReadOperationID.selectionExplain, .decompilerNativeResult,
                              .decompilerMacScopeResult, .decompilerCompare] {
                guard case .rejected(.unauthorized) = store.preparePhase2Read(
                    operation: operation, proposingPrincipal: principal
                ) else { return XCTFail("External read must stay inside the closed subset") }
            }
        }
    }

    func testExternalReadSerializationSuppressesStaleAndDuplicateFacts() throws {
        let store = makeStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let delayed = try prepared(.functionReview, in: store)
        var replacement = store.snapshot
        replacement.replaceAnalysis(changedAnalysis(), in: .primary)
        store.snapshot = replacement
        let stale = try WorkspaceScriptingAPI.readEvidenceResult(
            store.executePhase2Read(delayed), authorization: delayed.authorization
        )
        XCTAssertEqual(stale["status"]?.stringValue, "unavailable")
        XCTAssertEqual(stale["reason"]?.stringValue, "stale")
        XCTAssertNil(stale["facts"])
        XCTAssertNil(stale["evidenceID"])

        let current = try prepared(.functionReview, in: store)
        let acceptedExecution = store.executePhase2Read(current)
        let accepted = try WorkspaceScriptingAPI.readEvidenceResult(
            acceptedExecution, authorization: current.authorization
        )
        XCTAssertEqual(accepted["status"]?.stringValue, "accepted")
        XCTAssertNotNil(accepted["facts"])
        let forgedAuthorization = Phase2ReadAuthorization(
            request: current.authorization.request,
            canonicalDescriptor: current.authorization.canonicalDescriptor,
            authorizingPrincipal: .mcp,
            approvedLimits: current.authorization.approvedLimits
        )
        let forged = try WorkspaceScriptingAPI.readEvidenceResult(
            acceptedExecution, authorization: forgedAuthorization
        )
        XCTAssertEqual(forged["status"]?.stringValue, "unavailable")
        XCTAssertEqual(forged["reason"]?.stringValue, "unauthorized")
        XCTAssertNil(forged["facts"])

        let duplicate = try WorkspaceScriptingAPI.readEvidenceResult(
            store.executePhase2Read(current), authorization: current.authorization
        )
        XCTAssertEqual(duplicate["reason"]?.stringValue, "duplicate")
        XCTAssertNil(duplicate["facts"])
        XCTAssertNil(duplicate["evidenceID"])
    }

    func testInitialIdentityAndCurrentStateRemainStableWithoutMutation() throws {
        let store = makeStore()

        let first = try prepared(.workspaceSummary, in: store)
        let second = try prepared(.workspaceSummary, in: store)
        let firstPrecondition = first.authorization.request.precondition
        let secondPrecondition = second.authorization.request.precondition

        XCTAssertEqual(firstPrecondition.workspace, secondPrecondition.workspace)
        XCTAssertEqual(firstPrecondition.workspaceRevision, secondPrecondition.workspaceRevision)
        XCTAssertEqual(firstPrecondition.image, secondPrecondition.image)
        XCTAssertEqual(first.input.currentState, second.input.currentState)
        XCTAssertGreaterThan(firstPrecondition.workspaceRevision, 0)
        XCTAssertGreaterThan(try XCTUnwrap(firstPrecondition.image).ownerGeneration, 0)
        XCTAssertGreaterThan(try XCTUnwrap(firstPrecondition.image).analysisRevision, 0)
        XCTAssertEqual(
            try XCTUnwrap(firstPrecondition.image).analysisFingerprintSHA256,
            "1111111111111111111111111111111111111111111111111111111111111111"
        )
    }

    func testSameOwnerAnalysisPublicationAdvancesOnlyAnalysisRevision() throws {
        let store = makeStore()
        let before = try prepared(.workspaceSummary, in: store)
        let beforeImage = try XCTUnwrap(before.authorization.request.precondition.image)

        var replacement = store.snapshot
        replacement.replaceAnalysis(changedAnalysis(), in: .primary)
        store.snapshot = replacement

        let after = try prepared(.workspaceSummary, in: store)
        let afterImage = try XCTUnwrap(after.authorization.request.precondition.image)
        XCTAssertEqual(afterImage.owner, beforeImage.owner)
        XCTAssertGreaterThan(afterImage.analysisRevision, beforeImage.analysisRevision)
        XCTAssertEqual(
            afterImage.analysisFingerprintSHA256,
            "2222222222222222222222222222222222222222222222222222222222222222"
        )
        XCTAssertEqual(
            after.authorization.request.precondition.workspace,
            before.authorization.request.precondition.workspace
        )
        XCTAssertEqual(
            after.authorization.request.precondition.workspaceRevision,
            before.authorization.request.precondition.workspaceRevision
        )
    }

    func testReplacementBinaryAdvancesOwnerGenerationAndInvalidatesPriorOwner() throws {
        let store = makeStore()
        let before = try prepared(.workspaceSummary, in: store)
        let beforeImage = try XCTUnwrap(before.authorization.request.precondition.image)
        let replacementBinary = binary(id: testID(2))

        store.snapshot = WorkspaceSnapshot(
            binaries: [replacementBinary],
            analysisBySlot: [.primary: changedAnalysis()]
        )

        let after = try prepared(.workspaceSummary, in: store)
        let afterImage = try XCTUnwrap(after.authorization.request.precondition.image)
        XCTAssertEqual(afterImage.slot, beforeImage.slot)
        XCTAssertEqual(afterImage.binaryID, replacementBinary.id)
        XCTAssertGreaterThan(afterImage.ownerGeneration, beforeImage.ownerGeneration)
        XCTAssertFalse(
            before.authorization.request.precondition
                .compared(to: after.input.currentState)
                .isOwnerCurrent
        )
    }

    func testCoordinatorAuthorizesExactSelectionAndFunctionSubjects() throws {
        let store = makeStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))

        let selection = try prepared(.selectionExplain, in: store)
        let function = try prepared(.functionReview, in: store)
        guard case let .staticLocation(location) = selection.authorization.request.subject else {
            return XCTFail("Expected an exact static-location subject")
        }
        guard case let .functionRange(range) = function.authorization.request.subject else {
            return XCTFail("Expected an exact function-range subject")
        }

        XCTAssertEqual(location.address, 0x1004)
        XCTAssertEqual(location.domain, .imageVirtualAddress)
        XCTAssertEqual(location.image, selection.authorization.request.precondition.image)
        XCTAssertEqual(range.start, 0x1000)
        XCTAssertEqual(range.endExclusive, 0x1010)
        XCTAssertEqual(range.image, function.authorization.request.precondition.image)
    }

    func testExecutionAcceptsWorkspaceSummaryWhenUnrelatedInstructionFacetChanges() throws {
        let store = makeStore()
        let current = try prepared(.workspaceSummary, in: store)
        XCTAssertEqual(store.executePhase2Read(current).disposition, .accepted)

        let delayed = try prepared(.workspaceSummary, in: store)
        var replacement = store.snapshot
        replacement.replaceAnalysis(changedAnalysis(), in: .primary)
        store.snapshot = replacement

        XCTAssertEqual(store.executePhase2Read(delayed).disposition, .accepted)
    }

    func testExecutionRejectsSelectionReadWhenDeclaredInstructionFacetChanges() throws {
        let store = makeStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let delayed = try prepared(.selectionExplain, in: store)

        var replacement = store.snapshot
        replacement.replaceAnalysis(changedAnalysis(), in: .primary)
        store.snapshot = replacement

        XCTAssertEqual(store.executePhase2Read(delayed).disposition, .stale)
    }

    func testExecutionRejectsApplicationGraphWhenFocusedLoaderMetadataChanges() throws {
        let store = makeStore()
        let delayed = try prepared(.applicationGraphSummary, in: store)
        let facets = delayed.authorization.request.precondition.dependencies.map(\.facet)

        XCTAssertEqual(facets, [.workspaceTopology, .loaderMetadata])

        var replacement = store.snapshot
        replacement.replaceAnalysis(changedAnalysis(), in: .primary)
        store.snapshot = replacement

        XCTAssertEqual(store.executePhase2Read(delayed).disposition, .stale)
    }

    func testDuplicateExecutionDoesNotReExposePreviouslyAcceptedEvidence() throws {
        let store = makeStore()
        let prepared = try prepared(.workspaceSummary, in: store)

        let accepted = store.executePhase2Read(prepared)
        XCTAssertEqual(accepted.disposition, .accepted)
        XCTAssertNotNil(accepted.acceptedEvidence)

        let duplicate = store.executePhase2Read(prepared)
        XCTAssertEqual(duplicate.disposition, .duplicate)
        XCTAssertNil(duplicate.acceptedEvidence)
    }
}

private extension Phase2ReadStoreCoordinatorTests {
    func prepared(
        _ operation: Phase2ReadOperationID,
        in store: WorkspaceStore
    ) throws -> Phase2PreparedRead {
        switch store.preparePhase2Read(
            operation: operation,
            proposingPrincipal: .model,
            limits: .maximum
        ) {
        case .prepared(let prepared):
            return prepared
        case .unavailable(let reason):
            throw CoordinatorTestError.unavailable(reason)
        case .rejected(let disposition):
            throw CoordinatorTestError.rejected(disposition)
        }
    }

    func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "Phase 2 coordinator",
            snapshot: WorkspaceSnapshot(
                binaries: [binary(id: testID(1))],
                analysisBySlot: [.primary: initialAnalysis()]
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    func binary(id: UUID) -> BinaryImage {
        BinaryImage(
            id: id,
            name: "coordinator",
            path: "/ignored/coordinator",
            kind: "Mach-O",
            architecture: "arm64",
            selectedSliceIndex: 0,
            slot: .primary
        )
    }

    func initialAnalysis() -> ImageAnalysis {
        var analysis = ImageAnalysis(
            functions: [
                FunctionSummary(
                    id: testID(10),
                    name: "exact_function",
                    startAddress: 0x1000,
                    endAddress: 0x1010,
                    confidence: 1
                ),
            ],
            instructions: [instruction(0x1000, "first"), instruction(0x1004, "selected")],
            sections: [
                SectionSummary(
                    id: testID(11),
                    name: "__text",
                    address: 0x1000,
                    size: 0x10,
                    fileOffset: 0,
                    isExecutable: true
                ),
            ]
        )
        analysis.machOMetadata = MachOLoadMetadata(
            codeSignature: nil,
            importedSymbols: [],
            dependentDylibs: [dependency(path: "/usr/lib/libSystem.B.dylib", ordinal: 1)]
        )
        analysis.analysisInputFingerprint = fingerprint(
            overallSHA256: String(repeating: "1", count: 64),
            functionFacetSHA256: String(repeating: "a", count: 64),
            instructionFacetSHA256: String(repeating: "b", count: 64)
        )
        return analysis
    }

    func changedAnalysis() -> ImageAnalysis {
        var analysis = initialAnalysis()
        analysis.instructions.append(instruction(0x1008, "changed"))
        analysis.machOMetadata = MachOLoadMetadata(
            codeSignature: nil,
            importedSymbols: [],
            dependentDylibs: [
                dependency(path: "/usr/lib/libSystem.B.dylib", ordinal: 1),
                dependency(path: "@rpath/New.framework/New", ordinal: 2),
            ]
        )
        analysis.analysisInputFingerprint = fingerprint(
            overallSHA256: String(repeating: "2", count: 64),
            functionFacetSHA256: String(repeating: "a", count: 64),
            instructionFacetSHA256: String(repeating: "c", count: 64)
        )
        return analysis
    }

    func fingerprint(
        overallSHA256: String,
        functionFacetSHA256: String,
        instructionFacetSHA256: String
    ) -> AnalysisInputFingerprint {
        let sliceFacet = try! AnalysisFacetFingerprint(
            kind: .selectedSliceBytes,
            itemCount: 1,
            byteCount: 4,
            sha256: String(repeating: "0", count: 64)
        )
        let functionFacet = try! AnalysisFacetFingerprint(
            kind: .functions,
            itemCount: 1,
            sha256: functionFacetSHA256
        )
        let instructionFacet = try! AnalysisFacetFingerprint(
            kind: .decodedInstructions,
            itemCount: 2,
            sha256: instructionFacetSHA256
        )
        return try! AnalysisInputFingerprint(
            imageSlot: .primary,
            binaryID: testID(1),
            binaryName: "coordinator",
            binaryPath: "/ignored/coordinator",
            selectedSliceIndex: 0,
            artifactIdentity: nil,
            imageByteCount: 4,
            imageBytesSHA256: String(repeating: "f", count: 64),
            facets: [sliceFacet, functionFacet, instructionFacet],
            overallSHA256: overallSHA256
        )
    }

    func instruction(_ address: UInt64, _ mnemonic: String) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: "",
            hasBreakpoint: false,
            comment: nil
        )
    }

    func dependency(path: String, ordinal: Int) -> MachOLoadMetadata.DependentDylib {
        MachOLoadMetadata.DependentDylib(
            path: path,
            kind: "required",
            currentVersion: "1.0.0",
            compatibilityVersion: "1.0.0",
            ordinal: ordinal
        )
    }
}

private enum CoordinatorTestError: Error {
    case unavailable(Phase2ReadUnavailableReason)
    case rejected(Phase2ReadDisposition)
}

private func testID(_ byte: UInt8) -> UUID {
    UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
}
