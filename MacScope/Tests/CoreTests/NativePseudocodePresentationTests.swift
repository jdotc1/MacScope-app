import XCTest
@testable import MacScope

@MainActor
final class NativePseudocodePresentationTests: XCTestCase {
    func testNativeIsTheWindowSessionDefault() {
        let selection = PseudocodeSourceSelectionModel()

        XCTAssertEqual(selection.source, .native)
        XCTAssertEqual(PseudocodeSource.allCases, [.native, .macScope, .compare])
    }

    func testProjectsReadyAnalyzingUnavailableFailedTruncatedAndStaleStates() {
        let coordinate = makeCoordinate()
        let expected = makeIdentity(matching: coordinate)

        let analyzing = NativePseudocodePresentation.project(
            state: .analyzing(coordinate),
            expected: expected,
            macScopeIsAvailable: true
        )
        XCTAssertEqual(analyzing.status, .analyzing)
        XCTAssertFalse(analyzing.usesMacScopeFallback)

        let ready = NativePseudocodePresentation.project(
            state: .ready(
                coordinate: coordinate,
                success: makeSuccess(coordinate: coordinate, isTruncated: false)
            ),
            expected: expected,
            macScopeIsAvailable: true
        )
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(ready.document?.text, "int fixture(void) {\n    return 42;\n}\n")
        XCTAssertEqual(ready.provider?.backendID, "native-decompiler")
        XCTAssertEqual(ready.provider?.engineVersion, "12.1.2")
        XCTAssertFalse(ready.document?.isTruncated ?? true)
        XCTAssertFalse(ready.usesMacScopeFallback)

        let unavailableReason = NativeDecompilerPresentationTerminalReason.provider(.unavailable)
        let unavailable = NativePseudocodePresentation.project(
            state: .unavailable(coordinate: coordinate, reason: unavailableReason),
            expected: expected,
            macScopeIsAvailable: true
        )
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertEqual(unavailable.nativeTerminalReason, unavailableReason)
        XCTAssertEqual(unavailable.fallbackReason, .terminal(unavailableReason))
        XCTAssertTrue(unavailable.usesMacScopeFallback)

        let failedReason = NativeDecompilerPresentationTerminalReason.client(.timedOut)
        let failed = NativePseudocodePresentation.project(
            state: .failed(coordinate: coordinate, reason: failedReason),
            expected: expected,
            macScopeIsAvailable: true
        )
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.nativeTerminalReason, failedReason)
        XCTAssertEqual(failed.fallbackReason, .terminal(failedReason))
        XCTAssertTrue(failed.usesMacScopeFallback)

        let truncated = NativePseudocodePresentation.project(
            state: .ready(
                coordinate: coordinate,
                success: makeSuccess(coordinate: coordinate, isTruncated: true)
            ),
            expected: expected,
            macScopeIsAvailable: true
        )
        XCTAssertEqual(truncated.status, .ready)
        XCTAssertTrue(truncated.document?.isTruncated ?? false)
        XCTAssertFalse(truncated.usesMacScopeFallback)

        let stale = NativePseudocodePresentation.project(
            state: .ready(
                coordinate: coordinate,
                success: makeSuccess(coordinate: coordinate, isTruncated: false)
            ),
            expected: DecompilerPresentationIdentity(
                imageSlot: ImageSlot(rawValue: 1),
                ownerBinaryID: coordinate.ownerBinaryID,
                artifactUUID: coordinate.artifactUUID,
                functionID: coordinate.functionID,
                analysisInputFingerprintSHA256: coordinate.analysisInputFingerprintSHA256
            ),
            macScopeIsAvailable: true
        )
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.fallbackReason, .staleResult)
        XCTAssertTrue(stale.usesMacScopeFallback)
        XCTAssertNil(stale.document)
    }

    func testFailedNativeFallsBackToMacScopeWithoutLosingTheNativeReason() {
        let coordinate = makeCoordinate()
        let reason = NativeDecompilerPresentationTerminalReason.provider(.nativeFailure)

        let projection = NativePseudocodePresentation.project(
            state: .failed(coordinate: coordinate, reason: reason),
            expected: makeIdentity(matching: coordinate),
            macScopeIsAvailable: true
        )

        XCTAssertTrue(projection.usesMacScopeFallback)
        XCTAssertEqual(projection.nativeTerminalReason, reason)
        XCTAssertEqual(projection.fallbackReason, .terminal(reason))
    }

    func testUnboundProjectionFailureFallsBackWithoutLosingTheTypedReason() {
        let reason = NativeDecompilerPresentationTerminalReason.projection(
            .missingArtifactIdentity
        )
        let projection = NativePseudocodePresentation.project(
            state: .unavailable(coordinate: nil, reason: reason),
            expected: makeIdentity(matching: makeCoordinate()),
            macScopeIsAvailable: true
        )

        XCTAssertEqual(projection.status, .unavailable)
        XCTAssertTrue(projection.usesMacScopeFallback)
        XCTAssertEqual(projection.nativeTerminalReason, reason)
        XCTAssertEqual(projection.fallbackReason, .terminal(reason))
    }

    func testTerminalProjectionUsesClosedFailureCatalogCopy() {
        let coordinate = makeCoordinate()
        let reason = NativeDecompilerPresentationTerminalReason.runtimeValidation(
            .replyRuntimeIdentityMismatch
        )
        let projection = NativePseudocodePresentation.project(
            state: .failed(coordinate: coordinate, reason: reason),
            expected: makeIdentity(matching: coordinate),
            macScopeIsAvailable: true
        )

        XCTAssertEqual(projection.failurePresentation?.rowID, 10)
        XCTAssertEqual(projection.failurePresentation?.title, "Native result rejected")
        XCTAssertEqual(
            projection.failurePresentation?.explanation,
            "The native result did not match the current verified request."
        )
        XCTAssertFalse(
            projection.failurePresentation?.explanation.contains("replyRuntimeIdentityMismatch")
                ?? true
        )
    }

    func testSelectingMacScopeDoesNotMutateNativePresentationState() {
        let native = NativeDecompilerPresentationModel()
        let selection = PseudocodeSourceSelectionModel()
        let owner = UUID()
        let coordinate = makeCoordinate()
        native.activate(ownerToken: owner)
        XCTAssertTrue(native.begin(ownerToken: owner, generation: 1, coordinate: coordinate))
        let before = native.state

        selection.select(.macScope)

        XCTAssertEqual(selection.source, .macScope)
        XCTAssertEqual(native.state, before)
    }

    func testNativeDocumentLineProjectionUsesStableOneBasedLineNumbers() {
        let document = NativeDecompilerWirePseudocodeDocument(
            text: "line one\nline two\n",
            language: "c",
            isComplete: true,
            isTruncated: false
        )

        XCTAssertEqual(
            NativePseudocodeLine.lines(in: document),
            [
                NativePseudocodeLine(lineNumber: 1, text: "line one"),
                NativePseudocodeLine(lineNumber: 2, text: "line two"),
            ]
        )
    }

    private func makeCoordinate() -> NativeDecompilerPresentationCoordinate {
        NativeDecompilerPresentationCoordinate(
            imageSlot: .primary,
            ownerBinaryID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            artifactUUID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            imageID: "image:fixture",
            functionID: "30000000-0000-0000-0000-000000000003",
            requestSHA256: String(repeating: "a", count: 64),
            analysisInputFingerprintSHA256: String(repeating: "b", count: 64)
        )
    }

    private func makeIdentity(
        matching coordinate: NativeDecompilerPresentationCoordinate
    ) -> DecompilerPresentationIdentity {
        DecompilerPresentationIdentity(
            imageSlot: coordinate.imageSlot,
            ownerBinaryID: coordinate.ownerBinaryID,
            artifactUUID: coordinate.artifactUUID,
            functionID: coordinate.functionID,
            analysisInputFingerprintSHA256: coordinate.analysisInputFingerprintSHA256
        )
    }

    private func makeSuccess(
        coordinate: NativeDecompilerPresentationCoordinate,
        isTruncated: Bool
    ) -> NativeDecompilerWireSuccess {
        NativeDecompilerWireSuccess(
            availability: NativeDecompilerWireBackendAvailability(
                available: true,
                reasonCode: "available",
                runtimeIdentity: NativeDecompilerRuntimeIdentity(
                    backendID: "native-decompiler",
                    engineVersion: "12.1.2",
                    engineRevision: "engine-revision",
                    wrapperVersion: "2",
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
                requestID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
                requestSHA256: coordinate.requestSHA256,
                image: NativeDecompilerWireImageIdentity(
                    imageID: coordinate.imageID,
                    uuid: coordinate.artifactUUID,
                    preferredLoadAddress: .init(0x1000)
                ),
                function: NativeDecompilerWireFunctionIdentity(
                    functionID: coordinate.functionID,
                    name: "fixture",
                    entryAddress: .init(0x1000),
                    endAddressExclusive: .init(0x1008)
                ),
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
                    text: "int fixture(void) {\n    return 42;\n}\n",
                    language: "c",
                    isComplete: !isTruncated,
                    isTruncated: isTruncated
                ),
                warnings: []
            )
        )
    }
}
