import XCTest
@testable import MacScope

@MainActor
final class NativeDecompilerPresentationTests: XCTestCase {
    func testProviderExportUICaptureRejectsChangedProviderPublicationAndAuthoringRevision() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        var binary = try XCTUnwrap(store.snapshot.binaries.first)
        binary.artifactIdentity = try MachOSliceArtifactIdentity(uuid: UUID(),
            rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64), selectedSliceByteCount: 4)
        store.snapshot.binaries = [binary]
        var analysis = try XCTUnwrap(store.focusedAnalysis)
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        store.snapshot.analysisBySlot[binary.slot] = analysis
        let expected = try XCTUnwrap(ProviderPseudocodeExportCapture.expectedIdentity(in: store))
        let coordinate = NativeDecompilerPresentationCoordinate(imageSlot: expected.imageSlot,
            ownerBinaryID: expected.ownerBinaryID, artifactUUID: expected.artifactUUID,
            imageID: "image:fixture", functionID: expected.functionID,
            requestSHA256: String(repeating: "a", count: 64),
            analysisInputFingerprintSHA256: expected.analysisInputFingerprintSHA256)
        let model = NativeDecompilerPresentationModel()
        let owner = UUID()
        model.activate(ownerToken: owner)
        XCTAssertTrue(model.begin(ownerToken: owner, generation: 1, coordinate: coordinate))
        XCTAssertTrue(model.publishReady(ownerToken: owner, generation: 1, coordinate: coordinate,
                                        success: makeSuccess(coordinate: coordinate)))
        let capture = try ProviderPseudocodeExportCapture.capture(store: store, presentation: model, provider: .native)
        XCTAssertTrue(capture.isCurrent(store: store, presentation: model, provider: .native))
        XCTAssertFalse(capture.isCurrent(store: store, presentation: model, provider: .compare))
        XCTAssertTrue(model.begin(ownerToken: owner, generation: 2, coordinate: coordinate))
        XCTAssertFalse(capture.isCurrent(store: store, presentation: model, provider: .native))
        XCTAssertTrue(model.publishReady(ownerToken: owner, generation: 2, coordinate: coordinate,
                                        success: makeSuccess(coordinate: coordinate)))
        let current = try ProviderPseudocodeExportCapture.capture(store: store, presentation: model, provider: .native)
        store.setCustomComment(analysis.functions.first?.startAddress ?? 0, comment: "changed authoring")
        XCTAssertFalse(current.isCurrent(store: store, presentation: model, provider: .native))
    }

    func testProviderExportUICaptureDoesNotFabricateNativeAuthority() {
        let empty = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        let store = WorkspaceStore(workspaceName: "empty", snapshot: empty, engine: AnalysisEngine())
        XCTAssertThrowsError(try ProviderPseudocodeExportCapture.capture(store: store,
            presentation: NativeDecompilerPresentationModel(), provider: .native)) {
            XCTAssertEqual($0 as? ProviderPseudocodeExportError, .nativeUnavailable)
        }
    }
    func testProviderExportCapturesExactNativePublicationWithoutRegeneratingMacScopeText() throws {
        let coordinate = makeCoordinate()
        let success = makeSuccess(coordinate: coordinate)
        let exported = try DocumentExportService().renderProviderPseudocode(
            exportInput(coordinate: coordinate, state: .ready(coordinate: coordinate, success: success)))
        XCTAssertTrue(exported.text.hasSuffix("void fixture(void) {}\n"))
        XCTAssertFalse(exported.text.contains("MACSCOPE_BODY"))
        XCTAssertEqual(exported.nativeEvidence, success)
        XCTAssertTrue(exported.text.contains("Native request SHA256 (includes authored semantic input): \(coordinate.requestSHA256)"))
        XCTAssertTrue(exported.text.contains("Captured document/authoring revision: 7"))
        XCTAssertTrue(exported.suggestedName.hasSuffix("image-0-native-pseudocode"))
    }

    func testProviderExportRejectsPendingStaleAndMissingPublicationsWithoutFallback() {
        let coordinate = makeCoordinate()
        let success = makeSuccess(coordinate: coordinate)
        for (state, publication, error) in [
            (NativeDecompilerPresentationState.analyzing(coordinate), true, ProviderPseudocodeExportError.nativePending),
            (.idle, true, .nativeUnavailable),
            (.ready(coordinate: coordinate, success: success), false, .stalePublication),
            (.ready(coordinate: replacing(coordinate, imageSlot: ImageSlot(rawValue: 1)), success: success), true, .stalePublication),
        ] {
            XCTAssertThrowsError(try DocumentExportService().renderProviderPseudocode(
                exportInput(coordinate: coordinate, state: state, includesPublication: publication))) {
                XCTAssertEqual($0 as? ProviderPseudocodeExportError, error)
            }
        }
        let macScope = exportInput(coordinate: coordinate, state: .idle, provider: .macScope)
        XCTAssertNoThrow(try DocumentExportService().renderProviderPseudocode(macScope))
    }

    func testCompareExportRequiresQualifiedComparisonAndLabelsBothProviders() throws {
        let original = makeCoordinate()
        let functionID = UUID()
        let coordinate = NativeDecompilerPresentationCoordinate(
            imageSlot: original.imageSlot, ownerBinaryID: original.ownerBinaryID,
            artifactUUID: original.artifactUUID, imageID: original.imageID,
            functionID: functionID.uuidString.lowercased(), requestSHA256: original.requestSHA256,
            analysisInputFingerprintSHA256: original.analysisInputFingerprintSHA256)
        let success = makeSuccess(coordinate: coordinate)
        let function = FunctionSummary(id: functionID, name: "fixture", startAddress: 0x1000,
                                       endAddress: 0x1004, confidence: 1)
        let input = NativeDecompilerMacScopeComparisonInput(function: function, instructionStarts: [],
            basicBlocks: [], controlFlowEdges: [], directCallXRefs: [])
        let expected = exportInput(coordinate: coordinate, state: .idle).expected
        let comparison = DecompilerComparisonProjection.project(coordinate: coordinate, expected: expected,
                                                               native: success, macScope: input)
        let exported = try DocumentExportService().renderProviderPseudocode(
            exportInput(coordinate: coordinate, state: .ready(coordinate: coordinate, success: success),
                        provider: .compare, comparison: comparison))
        XCTAssertTrue(exported.text.contains("===== Native provider ====="))
        XCTAssertTrue(exported.text.contains("===== MacScope analysis provider =====\nMACSCOPE_BODY"))
        XCTAssertTrue(exported.text.contains("not whole-function equivalence"))
        XCTAssertTrue(exported.text.contains("coverage="))
        XCTAssertThrowsError(try DocumentExportService().renderProviderPseudocode(
            exportInput(coordinate: coordinate, state: .ready(coordinate: coordinate, success: success),
                        provider: .compare))) {
            XCTAssertEqual($0 as? ProviderPseudocodeExportError, .comparisonUnavailable)
        }
    }

    private func exportInput(
        coordinate: NativeDecompilerPresentationCoordinate,
        state: NativeDecompilerPresentationState,
        provider: PseudocodeSource = .native,
        includesPublication: Bool = true,
        comparison: DecompilerComparisonProjection? = nil
    ) -> ProviderPseudocodeExportInput {
        let success = makeSuccess(coordinate: coordinate)
        return ProviderPseudocodeExportInput(
            workspaceID: UUID(), workspaceName: "fixture", imageName: "fixture-image", provider: provider,
            documentMutationGeneration: 7,
            expected: DecompilerPresentationIdentity(imageSlot: coordinate.imageSlot,
                ownerBinaryID: coordinate.ownerBinaryID, artifactUUID: coordinate.artifactUUID,
                functionID: coordinate.functionID,
                analysisInputFingerprintSHA256: coordinate.analysisInputFingerprintSHA256),
            publication: includesPublication ? NativeDecompilerPresentationPublicationIdentity(
                ownerToken: UUID(), generation: 3, coordinate: coordinate, requestID: success.result.requestID) : nil,
            nativeState: state, macScopeText: "MACSCOPE_BODY", comparison: comparison)
    }

    func testExactGenerationTransitionsFromAnalyzingToReadyWithFullValidatedSuccess() throws {
        let model = NativeDecompilerPresentationModel()
        let ownerToken = UUID()
        let coordinate = makeCoordinate()
        let success = makeSuccess(coordinate: coordinate)

        model.activate(ownerToken: ownerToken)
        model.begin(ownerToken: ownerToken, generation: 1, coordinate: coordinate)
        XCTAssertEqual(model.state, .analyzing(coordinate))

        XCTAssertTrue(model.publishReady(
            ownerToken: ownerToken,
            generation: 1,
            coordinate: coordinate,
            success: success
        ))
        XCTAssertEqual(model.state, .ready(coordinate: coordinate, success: success))
        XCTAssertFalse(model.publishReady(
            ownerToken: ownerToken,
            generation: 1,
            coordinate: coordinate,
            success: success
        ))
    }

    func testReadyPublicationRejectsStaleGenerationAndEveryForgedCoordinateDimension() throws {
        let model = NativeDecompilerPresentationModel()
        let ownerToken = UUID()
        let coordinate = makeCoordinate()
        model.activate(ownerToken: ownerToken)
        model.begin(ownerToken: ownerToken, generation: 7, coordinate: coordinate)

        let forgeries = [
            replacing(coordinate, imageSlot: ImageSlot(rawValue: 1)),
            replacing(coordinate, ownerBinaryID: UUID()),
            replacing(coordinate, artifactUUID: UUID()),
            replacing(coordinate, imageID: "forged-image"),
            replacing(coordinate, functionID: "forged-function"),
            replacing(coordinate, requestSHA256: String(repeating: "f", count: 64)),
            replacing(coordinate, analysisInputFingerprintSHA256: String(repeating: "e", count: 64)),
        ]

        XCTAssertFalse(model.publishReady(
            ownerToken: ownerToken,
            generation: 6,
            coordinate: coordinate,
            success: makeSuccess(coordinate: coordinate)
        ))
        for forged in forgeries {
            XCTAssertFalse(model.publishReady(
                ownerToken: ownerToken,
                generation: 7,
                coordinate: forged,
                success: makeSuccess(coordinate: forged)
            ))
        }
        XCTAssertEqual(model.state, .analyzing(coordinate))
    }

    func testFailureAndUnavailableStatesRetainExactTerminalReason() {
        let model = NativeDecompilerPresentationModel()
        let ownerToken = UUID()
        let coordinate = makeCoordinate()

        model.activate(ownerToken: ownerToken)
        model.begin(ownerToken: ownerToken, generation: 1, coordinate: coordinate)
        XCTAssertTrue(model.publishTerminal(
            ownerToken: ownerToken,
            generation: 1,
            coordinate: coordinate,
            reason: .provider(.unavailable)
        ))
        XCTAssertEqual(
            model.state,
            .unavailable(coordinate: coordinate, reason: .provider(.unavailable))
        )
        XCTAssertFalse(model.publishTerminal(
            ownerToken: ownerToken,
            generation: 1,
            coordinate: coordinate,
            reason: .provider(.unavailable)
        ))

        model.begin(ownerToken: ownerToken, generation: 2, coordinate: coordinate)
        XCTAssertTrue(model.publishTerminal(
            ownerToken: ownerToken,
            generation: 2,
            coordinate: coordinate,
            reason: .client(.timedOut)
        ))
        XCTAssertEqual(
            model.state,
            .failed(coordinate: coordinate, reason: .client(.timedOut))
        )
    }

    func testProjectionFailureRetainsExactReasonAndRejectsDisplacedOwnerPublication() {
        let model = NativeDecompilerPresentationModel()
        let displacedOwner = UUID()
        let currentOwner = UUID()

        model.activate(ownerToken: displacedOwner)
        XCTAssertTrue(model.publishProjectionFailure(
            ownerToken: displacedOwner,
            generation: 1,
            error: .missingArtifactIdentity
        ))
        XCTAssertEqual(
            model.state,
            .unavailable(
                coordinate: nil,
                reason: .projection(.missingArtifactIdentity)
            )
        )

        model.activate(ownerToken: currentOwner)
        XCTAssertFalse(model.publishProjectionFailure(
            ownerToken: displacedOwner,
            generation: 2,
            error: .unsupportedArchitecture
        ))
        XCTAssertEqual(model.state, .idle)
    }

    func testReplacementAndEvictionClearOnlyTheExactOwnerGeneration() {
        let model = NativeDecompilerPresentationModel()
        let displacedOwner = UUID()
        let currentOwner = UUID()
        let coordinate = makeCoordinate()

        model.activate(ownerToken: displacedOwner)
        model.begin(ownerToken: displacedOwner, generation: 1, coordinate: coordinate)
        model.activate(ownerToken: currentOwner)
        model.begin(ownerToken: currentOwner, generation: 1, coordinate: coordinate)

        XCTAssertFalse(model.clear(ownerToken: displacedOwner, generation: 2))
        XCTAssertEqual(model.state, .analyzing(coordinate))
        XCTAssertTrue(model.clear(ownerToken: currentOwner, generation: 2))
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.begin(
            ownerToken: currentOwner,
            generation: 1,
            coordinate: coordinate
        ))
        XCTAssertEqual(model.state, .idle)
    }

    func testDisplacedOwnerCannotReclaimModelAfterSynchronousReplacement() {
        let model = NativeDecompilerPresentationModel()
        let displacedOwner = UUID()
        let currentOwner = UUID()
        let coordinate = makeCoordinate()

        model.activate(ownerToken: displacedOwner)
        XCTAssertTrue(model.begin(
            ownerToken: displacedOwner,
            generation: 1,
            coordinate: coordinate
        ))
        model.activate(ownerToken: currentOwner)
        XCTAssertTrue(model.begin(
            ownerToken: currentOwner,
            generation: 1,
            coordinate: coordinate
        ))

        XCTAssertFalse(model.begin(
            ownerToken: displacedOwner,
            generation: 2,
            coordinate: coordinate
        ))
        XCTAssertEqual(model.state, .analyzing(coordinate))
    }

    private func makeCoordinate() -> NativeDecompilerPresentationCoordinate {
        NativeDecompilerPresentationCoordinate(
            imageSlot: .primary,
            ownerBinaryID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            artifactUUID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            imageID: "image:fixture",
            functionID: "function:fixture",
            requestSHA256: String(repeating: "a", count: 64),
            analysisInputFingerprintSHA256: String(repeating: "b", count: 64)
        )
    }

    private func makeSuccess(
        coordinate: NativeDecompilerPresentationCoordinate
    ) -> NativeDecompilerWireSuccess {
        let requestID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let image = NativeDecompilerWireImageIdentity(
            imageID: coordinate.imageID,
            uuid: coordinate.artifactUUID,
            preferredLoadAddress: .init(0x1000)
        )
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: coordinate.functionID,
            name: "fixture",
            entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x1004)
        )
        return NativeDecompilerWireSuccess(
            availability: NativeDecompilerWireBackendAvailability(
                available: true,
                reasonCode: "available",
                runtimeIdentity: NativeDecompilerRuntimeIdentity(
                    backendID: "native-decompiler",
                    engineVersion: "12.1.2",
                    engineRevision: "engine-revision",
                    wrapperVersion: "1",
                    wrapperRevision: "wrapper-revision",
                    packageManifestSHA256: String(repeating: "d", count: 64),
                    packageTreeSHA256: String(repeating: "e", count: 64),
                    languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
                    targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                    contextProfileSHA256: "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
                ),
                capabilities: NativeDecompilerWireBackendCapabilities(
                    nativeDecompilerHeritage: true,
                    completeRegisterSSA: false,
                    memorySSA: false,
                    recoveredVariables: false,
                    recoveredTypes: false,
                    structuredControlFlow: true,
                    tokenizedPseudocode: false,
                    imageQualifiedSourceRanges: true
                )
            ),
            result: NativeDecompilerWireStructuredResult(
                requestID: requestID,
                requestSHA256: coordinate.requestSHA256,
                image: image,
                function: function,
                addressSpaces: [],
                types: [],
                instructions: [],
                varnodes: [],
                operations: [],
                blocks: [],
                edges: [],
                ssaValues: [],
                ssaBindings: [],
                phis: [],
                memoryVersions: [],
                memoryPhis: [],
                memoryEffects: [],
                variables: [],
                calls: [],
                regions: [],
                tokens: [],
                pseudocodeDocument: NativeDecompilerWirePseudocodeDocument(
                    text: "void fixture(void) {}\n",
                    language: "c",
                    isComplete: true,
                    isTruncated: false
                ),
                warnings: []
            )
        )
    }

    private func replacing(
        _ coordinate: NativeDecompilerPresentationCoordinate,
        imageSlot: ImageSlot? = nil,
        ownerBinaryID: UUID? = nil,
        artifactUUID: UUID? = nil,
        imageID: String? = nil,
        functionID: String? = nil,
        requestSHA256: String? = nil,
        analysisInputFingerprintSHA256: String? = nil
    ) -> NativeDecompilerPresentationCoordinate {
        NativeDecompilerPresentationCoordinate(
            imageSlot: imageSlot ?? coordinate.imageSlot,
            ownerBinaryID: ownerBinaryID ?? coordinate.ownerBinaryID,
            artifactUUID: artifactUUID ?? coordinate.artifactUUID,
            imageID: imageID ?? coordinate.imageID,
            functionID: functionID ?? coordinate.functionID,
            requestSHA256: requestSHA256 ?? coordinate.requestSHA256,
            analysisInputFingerprintSHA256: analysisInputFingerprintSHA256
                ?? coordinate.analysisInputFingerprintSHA256
        )
    }
}
