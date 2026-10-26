import XCTest

@testable import MacScope

final class ReconstructionNativeDecompilerAdapterTests: XCTestCase {
    func testUsesBoundSharedOwnerAdmissionAndNeverConstructsRawClient() async throws {
        let fixture = try makeAdapterFixture(
            functionUUIDHint: UUID(
                uuidString: "10000000-0000-0000-0000-000000000099"
            )
        )
        let admission = RecordingReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        let result = await adapter.decompile(
            fixture.request,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result, .completed(.init(
            taskID: fixture.request.taskID,
            checkpointID: fixture.request.checkpointID,
            checkpointRevision: fixture.request.checkpointRevision,
            corpusManifestSHA256: fixture.request.corpusManifestSHA256,
            execution: fixture.execution
        )))
        XCTAssertNotEqual(
            fixture.request.subject.functionUUIDHint,
            fixture.request.projection.functionID
        )
        let cachePolicies = await admission.cachePolicies
        XCTAssertEqual(cachePolicies, [.allowValidatedCache])
    }

    func testAcceptsReboundProjectionWithNilUUIDHint() async throws {
        let fixture = try makeAdapterFixture(functionUUIDHint: nil)
        let admission = RecordingReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        let result = await adapter.decompile(
            fixture.request,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertNil(fixture.request.subject.functionUUIDHint)
        XCTAssertEqual(result, .completed(.init(
            taskID: fixture.request.taskID,
            checkpointID: fixture.request.checkpointID,
            checkpointRevision: fixture.request.checkpointRevision,
            corpusManifestSHA256: fixture.request.corpusManifestSHA256,
            execution: fixture.execution
        )))
        let decompileCount = await admission.decompileCount
        XCTAssertEqual(decompileCount, 1)
    }

    func testRejectsImageFingerprintRangeBoundaryIDAndAmbiguousProjectionDrift() async throws {
        for drift in AdapterAuthorityDrift.refusalCases {
            let fixture = try makeAdapterFixture(authorityDrift: drift)
            let admission = RecordingReconstructionNativeAdmission(execution: fixture.execution)
            let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

            let result = await adapter.decompile(
                fixture.request,
                cancellation: ReconstructionCancellation()
            )

            XCTAssertEqual(result, .failed(.authorityMismatch), "drift: \(drift)")
            let decompileCount = await admission.decompileCount
            XCTAssertEqual(decompileCount, 0, "drift: \(drift)")
        }
    }

    func testProjectionAuthorityMismatchNeverReachesNativeAdmission() async throws {
        let fixture = try makeAdapterFixture(projectionFingerprint: String(repeating: "c", count: 64))
        let admission = RecordingReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        let result = await adapter.decompile(
            fixture.request,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result, .failed(.authorityMismatch))
        let decompileCount = await admission.decompileCount
        XCTAssertEqual(decompileCount, 0)
    }

    func testRetainsTaskCheckpointRevisionAndRequestPublicationFences() async throws {
        let fixture = try makeAdapterFixture(executionFingerprint: String(repeating: "d", count: 64))
        let admission = RecordingReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        let result = await adapter.decompile(
            fixture.request,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result, .failed(.authorityMismatch))
        let decompileCount = await admission.decompileCount
        XCTAssertEqual(decompileCount, 1)
    }

    func testRejectsNativeExecutionStructuralRangeDriftAfterAdmission() async throws {
        let fixture = try makeAdapterFixture(
            executionStartAddress: 0x1004,
            executionEndAddressExclusive: 0x100c
        )
        let admission = RecordingReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        let result = await adapter.decompile(
            fixture.request,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result, .failed(.authorityMismatch))
        let decompileCount = await admission.decompileCount
        XCTAssertEqual(decompileCount, 1)
    }

    func testPrecancelledRequestNeverReachesNativeAdmission() async throws {
        let fixture = try makeAdapterFixture()
        let admission = RecordingReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)
        let cancellation = ReconstructionCancellation()
        cancellation.cancel()

        let result = await adapter.decompile(fixture.request, cancellation: cancellation)

        XCTAssertEqual(result, .cancelled)
        let decompileCount = await admission.decompileCount
        XCTAssertEqual(decompileCount, 0)
    }

    func testCancelOutstandingIsReusableAndRetireIsTerminalIdempotent() async throws {
        let fixture = try makeAdapterFixture()
        let admission = RecordingReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        await adapter.cancelOutstanding()
        let reusableResult = await adapter.decompile(
            fixture.request,
            cancellation: ReconstructionCancellation()
        )
        XCTAssertEqual(
            reusableResult,
            .completed(.init(
                taskID: fixture.request.taskID,
                checkpointID: fixture.request.checkpointID,
                checkpointRevision: fixture.request.checkpointRevision,
                corpusManifestSHA256: fixture.request.corpusManifestSHA256,
                execution: fixture.execution
            ))
        )

        await adapter.retire()
        await adapter.retire()

        let cancelCount = await admission.cancelCount
        let retireCount = await admission.retireCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(retireCount, 1)
        let retiredResult = await adapter.decompile(
            fixture.request,
            cancellation: ReconstructionCancellation()
        )
        XCTAssertEqual(
            retiredResult,
            .failed(.providerUnavailable)
        )
        let decompileCount = await admission.decompileCount
        XCTAssertEqual(decompileCount, 1)
    }

    func testCancelOutstandingRejectsLateSuccessFromCancelledGeneration() async throws {
        let fixture = try makeAdapterFixture()
        let admission = SuspendedReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        let inFlight = Task {
            await adapter.decompile(
                fixture.request,
                cancellation: ReconstructionCancellation()
            )
        }
        await admission.waitUntilStarted()

        await adapter.cancelOutstanding()
        await admission.releaseSuccess()

        let result = await inFlight.value
        XCTAssertEqual(result, .cancelled)
        let counts = await admission.counts
        XCTAssertEqual(counts.cancel, 1)
        XCTAssertEqual(counts.retire, 0)
    }

    func testRetireRejectsLateSuccessFromRetiredAdmission() async throws {
        let fixture = try makeAdapterFixture()
        let admission = SuspendedReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        let inFlight = Task {
            await adapter.decompile(
                fixture.request,
                cancellation: ReconstructionCancellation()
            )
        }
        await admission.waitUntilStarted()

        await adapter.retire()
        await admission.releaseSuccess()

        let result = await inFlight.value
        XCTAssertEqual(result, .failed(.providerUnavailable))
        let counts = await admission.counts
        XCTAssertEqual(counts.cancel, 0)
        XCTAssertEqual(counts.retire, 1)
    }

    func testCancelOutstandingOwnsLateProviderFailureClassification() async throws {
        let fixture = try makeAdapterFixture()
        let admission = SuspendedReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        let inFlight = Task {
            await adapter.decompile(
                fixture.request,
                cancellation: ReconstructionCancellation()
            )
        }
        await admission.waitUntilStarted()

        await adapter.cancelOutstanding()
        await admission.releaseFailure(
            NativeDecompilerOwnerAdmissionError.terminalProviderResult(reason: "provider-native-failure")
        )

        let result = await inFlight.value
        XCTAssertEqual(result, .cancelled)
    }

    func testRetireOwnsLateAdmissionCancellationClassification() async throws {
        let fixture = try makeAdapterFixture()
        let admission = SuspendedReconstructionNativeAdmission(execution: fixture.execution)
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)

        let inFlight = Task {
            await adapter.decompile(
                fixture.request,
                cancellation: ReconstructionCancellation()
            )
        }
        await admission.waitUntilStarted()

        await adapter.retire()
        await admission.releaseFailure(CancellationError())

        let result = await inFlight.value
        XCTAssertEqual(result, .failed(.providerUnavailable))
    }
}

private actor RecordingReconstructionNativeAdmission: NativeDecompilerOwnerAdmission {
    private let execution: NativeDecompilerValidatedExecution
    private(set) var cachePolicies: [NativeDecompilerCacheLookupPolicy] = []
    private(set) var decompileCount = 0
    private(set) var cancelCount = 0
    private(set) var retireCount = 0

    init(execution: NativeDecompilerValidatedExecution) {
        self.execution = execution
    }

    func decompile(
        _ request: NativeDecompilerProjectionRequest,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy
    ) async throws -> NativeDecompilerValidatedExecution {
        decompileCount += 1
        cachePolicies.append(cacheLookupPolicy)
        return execution
    }

    func cancelOutstanding() async { cancelCount += 1 }
    func retire() async { retireCount += 1 }
}

private actor SuspendedReconstructionNativeAdmission: NativeDecompilerOwnerAdmission {
    private let execution: NativeDecompilerValidatedExecution
    private var resultContinuation:
        CheckedContinuation<NativeDecompilerValidatedExecution, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false
    private var cancelCount = 0
    private var retireCount = 0

    init(execution: NativeDecompilerValidatedExecution) {
        self.execution = execution
    }

    var counts: (cancel: Int, retire: Int) {
        (cancelCount, retireCount)
    }

    func decompile(
        _ request: NativeDecompilerProjectionRequest,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy
    ) async throws -> NativeDecompilerValidatedExecution {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseSuccess() {
        resultContinuation?.resume(returning: execution)
        resultContinuation = nil
    }

    func releaseFailure(_ error: any Error) {
        resultContinuation?.resume(throwing: error)
        resultContinuation = nil
    }

    func cancelOutstanding() async { cancelCount += 1 }
    func retire() async { retireCount += 1 }
}

private struct ReconstructionNativeAdapterFixture {
    let request: ReconstructionNativeDecompilationRequest
    let execution: NativeDecompilerValidatedExecution
}

private enum AdapterAuthorityDrift: String, CaseIterable {
    case none
    case image
    case fingerprint
    case range
    case boundarySchema
    case projectionFunctionID
    case ambiguousStructuralRange

    static let refusalCases = allCases.filter { $0 != .none }
}

private func makeAdapterFixture(
    functionUUIDHint: UUID? = nil,
    projectionFingerprint: String? = nil,
    executionFingerprint: String? = nil,
    executionStartAddress: UInt64 = 0x1000,
    executionEndAddressExclusive: UInt64 = 0x1008,
    authorityDrift: AdapterAuthorityDrift = .none
) throws -> ReconstructionNativeAdapterFixture {
    let freshFunctionID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let artifact = ReconstructionArtifactCoordinate(
        occurrenceID: .init(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!),
        contentIdentity: try .init(
            algorithm: .sha256,
            digest: String(repeating: "a", count: 64),
            byteCount: 8
        )
    )
    let image = ReconstructionImageBinding(
        binaryID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
        imageSlot: .primary,
        selectedSliceIndex: nil,
        architecture: .arm64,
        machOIdentity: nil
    )
    let binary = BinaryImage(
        id: image.binaryID,
        name: "fixture",
        path: "/private/tmp/reconstruction-native-adapter-fixture",
        kind: "Mach-O",
        architecture: "arm64",
        slot: image.imageSlot
    )
    var analysis = ImageAnalysis()
    analysis.imageBytes = Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0])
    analysis.functions = [FunctionSummary(
        id: freshFunctionID,
        name: "entry",
        startAddress: 0x1000,
        endAddress: 0x1008,
        confidence: 1
    )]
    let firstFingerprint = try AnalysisFingerprintBuilder.fingerprint(
        binary: binary,
        analysis: analysis
    )
    let stableFunctionID = ReconstructionStableImageAuthority.stableFunctionID(
        image: image,
        analysisFingerprintSHA256: firstFingerprint.overallSHA256,
        startAddress: 0x1000,
        endAddressExclusive: 0x1008,
        boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion
    )
    analysis.functions[0] = FunctionSummary(
        id: stableFunctionID,
        name: "entry",
        startAddress: 0x1000,
        endAddress: 0x1008,
        confidence: 1
    )
    analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
        binary: binary,
        analysis: analysis
    )
    guard analysis.analysisInputFingerprint?.overallSHA256 == firstFingerprint.overallSHA256 else {
        throw ReconstructionValidationError.invalidReference(
            field: "adapter fixture rebound fingerprint"
        )
    }
    if authorityDrift == .ambiguousStructuralRange {
        analysis.functions.append(.init(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "ambiguous-entry",
            startAddress: 0x1000,
            endAddress: 0x1008,
            confidence: 0.5
        ))
    }
    let workspace = WorkspaceSnapshot(
        binaries: [binary],
        analysisBySlot: [image.imageSlot: analysis]
    )
    let subjectImage: ReconstructionImageBinding
    if authorityDrift == .image {
        subjectImage = .init(
            binaryID: UUID(uuidString: "30000000-0000-0000-0000-000000000099")!,
            imageSlot: image.imageSlot,
            selectedSliceIndex: image.selectedSliceIndex,
            architecture: image.architecture,
            machOIdentity: image.machOIdentity
        )
    } else {
        subjectImage = image
    }
    let subjectFingerprint = authorityDrift == .fingerprint
        ? String(repeating: "c", count: 64)
        : firstFingerprint.overallSHA256
    let subjectStartAddress: UInt64 = authorityDrift == .range ? 0x1004 : 0x1000
    let subjectEndAddressExclusive: UInt64 = authorityDrift == .range ? 0x100c : 0x1008
    let boundarySchemaVersion = authorityDrift == .boundarySchema
        ? ReconstructionFunctionCoordinate.schemaVersion + 1
        : ReconstructionFunctionCoordinate.schemaVersion
    let subject = try ReconstructionFunctionCoordinate(
        artifact: artifact,
        image: subjectImage,
        analysisFingerprintSHA256: subjectFingerprint,
        startAddress: subjectStartAddress,
        endAddressExclusive: subjectEndAddressExclusive,
        boundarySchemaVersion: boundarySchemaVersion,
        functionUUIDHint: functionUUIDHint,
        symbolHint: "entry"
    )
    let projectionFunctionID = authorityDrift == .projectionFunctionID
        ? UUID(uuidString: "10000000-0000-0000-0000-000000000098")!
        : stableFunctionID
    let projection = try NativeDecompilerProjectionRequest(
        workspace: workspace,
        imageSlot: .primary,
        functionID: projectionFunctionID,
        analysisInputFingerprintSHA256: projectionFingerprint ?? firstFingerprint.overallSHA256
    )
    let success = makeAdapterSuccess(
        functionID: projectionFunctionID,
        startAddress: executionStartAddress,
        endAddressExclusive: executionEndAddressExclusive
    )
    let execution = NativeDecompilerValidatedExecution(
        requestSHA256: String(repeating: "e", count: 64),
        analysisInputFingerprintSHA256: executionFingerprint ?? firstFingerprint.overallSHA256,
        imageSlot: .primary,
        functionID: projectionFunctionID,
        success: success,
        source: .validatedCache
    )
    return ReconstructionNativeAdapterFixture(
        request: .init(
            taskID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            checkpointID: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            checkpointRevision: 7,
            corpusManifestSHA256: String(repeating: "f", count: 64),
            subject: subject,
            projection: projection
        ),
        execution: execution
    )
}

private func makeAdapterSuccess(
    functionID: UUID,
    startAddress: UInt64,
    endAddressExclusive: UInt64
) -> NativeDecompilerWireSuccess {
    let image = NativeDecompilerWireImageIdentity(
        imageID: "image:fixture",
        uuid: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
        preferredLoadAddress: .init(0x1000)
    )
    let function = NativeDecompilerWireFunctionIdentity(
        functionID: functionID.uuidString.lowercased(),
        name: "entry",
        entryAddress: .init(startAddress),
        endAddressExclusive: .init(endAddressExclusive)
    )
    return NativeDecompilerWireSuccess(
        availability: .init(
            available: true,
            reasonCode: "available",
            runtimeIdentity: .init(
                backendID: "native-decompiler",
                engineVersion: "12.1.2",
                engineRevision: String(repeating: "1", count: 40),
                wrapperVersion: "dcp05c-v3",
                wrapperRevision: String(repeating: "2", count: 40),
                packageManifestSHA256: String(repeating: "3", count: 64),
                packageTreeSHA256: String(repeating: "4", count: 64),
                languageID: "AARCH64:LE:64:AppleSilicon",
                compilerSpecID: "default",
                targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                contextProfileSHA256: String(repeating: "5", count: 64)
            ),
            capabilities: .init(
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
        result: .init(
            requestID: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            requestSHA256: String(repeating: "e", count: 64),
            image: image,
            function: function,
            addressSpaces: [], types: [], instructions: [], varnodes: [], operations: [],
            blocks: [], edges: [], ssaValues: [], ssaBindings: [], phis: [],
            memoryVersions: [], memoryPhis: [], memoryEffects: [], variables: [], calls: [],
            regions: [], tokens: [], warnings: []
        )
    )
}
