import Darwin
import XCTest

@testable import MacScope

final class ReconstructionDetachedAnalysisSnapshotBuilderTests: XCTestCase {
    func testBuildsExactDetachedAuthorityFromDescriptorRevalidatedAttachment() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }

        let result = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
            source: fixture.source,
            artifact: fixture.artifact,
            expectedImage: fixture.image,
            provider: ReconstructionFixedAnalysisProvider(result: fixture.workspace),
            overrides: [:],
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result.artifact, fixture.artifact)
        XCTAssertEqual(result.image, fixture.image)
        XCTAssertEqual(result.workspace.binaries.map(\.id), [fixture.image.binaryID])
        let binary = try XCTUnwrap(result.workspace.binary(in: fixture.image.imageSlot))
        let analysis = try XCTUnwrap(result.workspace.analysis(in: fixture.image.imageSlot))
        let recomputed = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
        XCTAssertEqual(result.analysisInputFingerprintSHA256, recomputed.overallSHA256)
        XCTAssertEqual(recomputed.binaryID, fixture.image.binaryID)
        XCTAssertEqual(recomputed.imageSlot, fixture.image.imageSlot)
    }

    func testRejectsPathDescriptorContentAndArtifactDriftBeforeAdmission() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        try Data(repeating: 0xff, count: 8).write(to: fixture.source.verifiedURL)

        do {
            _ = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
                source: fixture.source,
                artifact: fixture.artifact,
                expectedImage: fixture.image,
                provider: ReconstructionFixedAnalysisProvider(result: fixture.workspace),
                overrides: [:],
                cancellation: ReconstructionCancellation()
            )
            XCTFail("Mutated attachment bytes must be refused before analysis authority is accepted")
        } catch let error as ReconstructionDetachedAnalysisError {
            XCTAssertEqual(error, .contentDrift)
        }

        let inFlightFixture = try ReconstructionHeadlessTestFixture.make()
        defer { inFlightFixture.remove() }
        do {
            _ = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
                source: inFlightFixture.source,
                artifact: inFlightFixture.artifact,
                expectedImage: inFlightFixture.image,
                provider: ReconstructionMutatingAnalysisProvider(
                    result: inFlightFixture.workspace,
                    attachmentURL: inFlightFixture.source.verifiedURL
                ),
                overrides: [:],
                cancellation: ReconstructionCancellation()
            )
            XCTFail("Attachment drift during analysis must be refused before authority is accepted")
        } catch let error as ReconstructionDetachedAnalysisError {
            XCTAssertEqual(error, .contentDrift)
        }
    }

    func testProviderReadsPinnedInodeWhenVerifiedPathIsSwappedAndRestored() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let expectedBytes = try Data(contentsOf: fixture.source.verifiedURL)
        let replacementBytes = Data(repeating: 0xa5, count: expectedBytes.count)
        let recorder = ReconstructionPinnedURLObservationRecorder()

        let result = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
            source: fixture.source,
            artifact: fixture.artifact,
            expectedImage: fixture.image,
            provider: ReconstructionPathSwappingAnalysisProvider(
                result: fixture.workspace,
                verifiedURL: fixture.source.verifiedURL,
                replacementBytes: replacementBytes,
                recorder: recorder
            ),
            overrides: [:],
            cancellation: ReconstructionCancellation()
        )

        let recordedObservation = await recorder.observation
        let observation = try XCTUnwrap(recordedObservation)
        XCTAssertEqual(observation.bytes, expectedBytes)
        XCTAssertNotEqual(observation.bytes, replacementBytes)
        XCTAssertTrue(observation.providerPath.hasPrefix("/dev/fd/"))
        XCTAssertEqual(result.image, fixture.image)
        XCTAssertEqual(try Data(contentsOf: fixture.source.verifiedURL), expectedBytes)
    }

    func testSignedXPCUsesTransferredPinnedDescriptorWhenAttachmentPathIsReplaced() async throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_PINNED_XPC_PATH_SWAP"] == "1" else {
            throw XCTSkip("Set MACSCOPE_RUN_PINNED_XPC_PATH_SWAP=1 in signed app-hosted acceptance.")
        }
        let fixture = try ReconstructionRealHeadlessTestFixture.make()
        defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.source.verifiedURL)
        let replacementBytes = MachOFixture.makeExecutableWithSymbols().bytes
        XCTAssertNotEqual(originalBytes, replacementBytes)

        let transport = NSXPCConnectionTransport()
        let provider = ReconstructionPinnedXPCPathSwapProvider(
            delegate: XPCAnalysisProvider(transport: transport, codec: PayloadWireCodec()),
            verifiedURL: fixture.source.verifiedURL,
            replacementBytes: replacementBytes
        )
        let detached = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
            source: fixture.source,
            artifact: fixture.artifact,
            expectedImage: nil,
            provider: provider,
            overrides: [:],
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(detached.workspace.imageBytes, originalBytes)
        XCTAssertNotEqual(detached.workspace.imageBytes, replacementBytes)
        let workerPID = try XCTUnwrap(transport.remoteProcessIdentifier)
        XCTAssertGreaterThan(workerPID, 0)
        XCTAssertNotEqual(workerPID, getpid())
        XCTAssertEqual(try Data(contentsOf: fixture.source.verifiedURL), originalBytes)
    }

    func testRejectsSameInodeMutationThatIsRestoredBeforeProviderReturns() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let expectedBytes = try Data(contentsOf: fixture.source.verifiedURL)
        let replacementBytes = Data(repeating: 0xa5, count: expectedBytes.count)
        XCTAssertNotEqual(replacementBytes, expectedBytes)

        do {
            _ = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
                source: fixture.source,
                artifact: fixture.artifact,
                expectedImage: fixture.image,
                provider: ReconstructionInPlaceRestoringAnalysisProvider(
                    result: fixture.workspace,
                    verifiedURL: fixture.source.verifiedURL,
                    originalBytes: expectedBytes,
                    replacementBytes: replacementBytes
                ),
                overrides: [:],
                cancellation: ReconstructionCancellation()
            )
            XCTFail("Same-inode mutation during detached analysis must invalidate the snapshot")
        } catch let error as ReconstructionDetachedAnalysisError {
            XCTAssertEqual(error, .analysisAuthorityMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source.verifiedURL), expectedBytes)
    }

    func testProviderReadsDescriptorBoundVaultSourceAcrossRootSwapAndRestore() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let expectedBytes = try Data(contentsOf: fixture.source.verifiedURL)
        let replacementBytes = Data(repeating: 0xa5, count: expectedBytes.count)
        let vaultRoot = fixture.directoryURL.appendingPathComponent(
            "descriptor-vault",
            isDirectory: true
        )
        let shardName = String(fixture.source.contentIdentity.digest.prefix(2))
        let shardURL = vaultRoot.appendingPathComponent(shardName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: shardURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let durableURL = shardURL.appendingPathComponent(
            fixture.source.contentIdentity.digest
        )
        try expectedBytes.write(to: durableURL)

        let rootDescriptor = vaultRoot.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            } ?? -1
        }
        XCTAssertGreaterThanOrEqual(rootDescriptor, 0)
        let authority = try ReconstructionSidecarAttachmentAuthority(
            pinnedRootDescriptor: rootDescriptor
        )
        _ = Darwin.close(rootDescriptor)
        let source = authority.source(
            contentIdentity: fixture.source.contentIdentity,
            rootURL: vaultRoot
        )

        let displacedVault = fixture.directoryURL.appendingPathComponent(
            "displaced-descriptor-vault",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: vaultRoot, to: displacedVault)
        let decoyShard = vaultRoot.appendingPathComponent(shardName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: decoyShard,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try replacementBytes.write(
            to: decoyShard.appendingPathComponent(fixture.source.contentIdentity.digest)
        )
        let recorder = ReconstructionPinnedURLObservationRecorder()

        let result: ReconstructionDetachedAnalysisSnapshot
        do {
            result = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
                source: source,
                artifact: fixture.artifact,
                expectedImage: fixture.image,
                provider: ReconstructionPinnedURLReadingAnalysisProvider(
                    result: fixture.workspace,
                    recorder: recorder
                ),
                overrides: [:],
                cancellation: ReconstructionCancellation()
            )
            try FileManager.default.removeItem(at: vaultRoot)
            try FileManager.default.moveItem(at: displacedVault, to: vaultRoot)
        } catch {
            try? FileManager.default.removeItem(at: vaultRoot)
            if FileManager.default.fileExists(atPath: displacedVault.path) {
                try? FileManager.default.moveItem(at: displacedVault, to: vaultRoot)
            }
            throw error
        }

        let recordedObservation = await recorder.observation
        let observation = try XCTUnwrap(recordedObservation)
        XCTAssertEqual(observation.bytes, expectedBytes)
        XCTAssertNotEqual(observation.bytes, replacementBytes)
        XCTAssertTrue(observation.providerPath.hasPrefix("/dev/fd/"))
        XCTAssertEqual(result.image, fixture.image)
        authority.revoke()
        XCTAssertThrowsError(try source.openVerifiedDescriptor()) { error in
            XCTAssertEqual(
                error as? ReconstructionSidecarAttachmentAuthorityError,
                .revoked
            )
        }
    }

    func testFunctionBindingRefusesZeroStructuralCandidates() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        let detached = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
            source: fixture.source,
            artifact: fixture.artifact,
            expectedImage: fixture.image,
            provider: ReconstructionFixedAnalysisProvider(result: fixture.workspace),
            overrides: [:],
            cancellation: ReconstructionCancellation()
        )
        let coordinate = try ReconstructionFunctionCoordinate(
            artifact: fixture.artifact,
            image: detached.image,
            analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256,
            startAddress: 0x2000,
            endAddressExclusive: 0x2008,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
            functionUUIDHint: fixture.functionID,
            symbolHint: nil
        )

        XCTAssertThrowsError(try ReconstructionStableImageAuthority.bindFunction(
            coordinate,
            artifact: fixture.artifact,
            in: .init(
                image: detached.image,
                workspace: detached.workspace,
                analysisInputFingerprintSHA256: detached.analysisInputFingerprintSHA256
            )
        )) { error in
            XCTAssertEqual(
                error as? ReconstructionDetachedAnalysisError,
                .analysisAuthorityMismatch
            )
        }
    }

    func testFunctionBindingRefusesAmbiguousStructuralCandidates() async throws {
        let fixture = try ReconstructionHeadlessTestFixture.make()
        defer { fixture.remove() }
        var ambiguousWorkspace = fixture.workspace
        ambiguousWorkspace.mutateAnalysis(in: fixture.image.imageSlot) { analysis in
            analysis.functions.append(FunctionSummary(
                id: UUID(),
                name: "duplicate-entry",
                startAddress: 0x1000,
                endAddress: 0x1008,
                confidence: 0.5
            ))
        }
        let detached = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
            source: fixture.source,
            artifact: fixture.artifact,
            expectedImage: fixture.image,
            provider: ReconstructionFixedAnalysisProvider(result: ambiguousWorkspace),
            overrides: [:],
            cancellation: ReconstructionCancellation()
        )
        let coordinate = try ReconstructionFunctionCoordinate(
            artifact: fixture.artifact,
            image: detached.image,
            analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256,
            startAddress: 0x1000,
            endAddressExclusive: 0x1008,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
            functionUUIDHint: fixture.functionID,
            symbolHint: "entry"
        )

        XCTAssertThrowsError(try ReconstructionStableImageAuthority.bindFunction(
            coordinate,
            artifact: fixture.artifact,
            in: .init(
                image: detached.image,
                workspace: detached.workspace,
                analysisInputFingerprintSHA256: detached.analysisInputFingerprintSHA256
            )
        )) { error in
            XCTAssertEqual(
                error as? ReconstructionDetachedAnalysisError,
                .analysisAuthorityMismatch
            )
        }
    }

    func testExpectedImageBindingRequiresExactSliceArchitectureAndMachOIdentity()
        async throws
    {
        let fixture = try ReconstructionRealHeadlessTestFixture.make()
        defer { fixture.remove() }
        let detached = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
            source: fixture.source,
            artifact: fixture.artifact,
            expectedImage: nil,
            provider: AnalysisEngine(),
            overrides: [:],
            cancellation: ReconstructionCancellation()
        )
        let identity = try XCTUnwrap(detached.image.machOIdentity)
        let driftedIdentity = try MachOSliceArtifactIdentity(
            uuid: identity.uuid,
            rawCPUType: identity.rawCPUType,
            rawCPUSubtype: identity.rawCPUSubtype,
            selectedSliceSHA256: String(repeating: "0", count: 64),
            selectedSliceByteCount: identity.selectedSliceByteCount
        )
        let mismatches = [
            ReconstructionImageBinding(
                binaryID: detached.image.binaryID,
                imageSlot: detached.image.imageSlot,
                selectedSliceIndex: 0,
                architecture: detached.image.architecture,
                machOIdentity: identity
            ),
            ReconstructionImageBinding(
                binaryID: detached.image.binaryID,
                imageSlot: detached.image.imageSlot,
                selectedSliceIndex: detached.image.selectedSliceIndex,
                architecture: .x86_64,
                machOIdentity: identity
            ),
            ReconstructionImageBinding(
                binaryID: detached.image.binaryID,
                imageSlot: detached.image.imageSlot,
                selectedSliceIndex: detached.image.selectedSliceIndex,
                architecture: detached.image.architecture,
                machOIdentity: driftedIdentity
            ),
        ]

        for mismatch in mismatches {
            XCTAssertThrowsError(try ReconstructionStableImageAuthority.bind(
                freshWorkspace: detached.workspace,
                artifact: fixture.artifact,
                expectedImage: mismatch
            )) { error in
                XCTAssertEqual(
                    error as? ReconstructionDetachedAnalysisError,
                    .analysisAuthorityMismatch
                )
            }
        }
    }
}

private struct ReconstructionMutatingAnalysisProvider: AnalysisProviding {
    let result: WorkspaceSnapshot
    let attachmentURL: URL

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        fatalError("detached analysis uses the asynchronous provider entry point")
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        try cancellation.check()
        try Data(repeating: 0xee, count: 8).write(to: attachmentURL)
        return result
    }
}

private actor ReconstructionPinnedURLObservationRecorder {
    struct Observation: Sendable {
        let bytes: Data
        let providerPath: String
    }

    private(set) var observation: Observation?

    func record(bytes: Data, providerURL: URL) {
        observation = Observation(bytes: bytes, providerPath: providerURL.path)
    }
}

private struct ReconstructionPinnedURLReadingAnalysisProvider: AnalysisProviding {
    let result: WorkspaceSnapshot
    let recorder: ReconstructionPinnedURLObservationRecorder

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        fatalError("detached analysis uses the asynchronous provider entry point")
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        try cancellation.check()
        let bytes = try Data(contentsOf: url)
        await recorder.record(bytes: bytes, providerURL: url)
        return result
    }
}

private struct ReconstructionPathSwappingAnalysisProvider: AnalysisProviding {
    let result: WorkspaceSnapshot
    let verifiedURL: URL
    let replacementBytes: Data
    let recorder: ReconstructionPinnedURLObservationRecorder

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        fatalError("detached analysis uses the asynchronous provider entry point")
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        try cancellation.check()
        let backupURL = verifiedURL.deletingLastPathComponent().appendingPathComponent(
            ".MacScope-pinned-source-\(UUID().uuidString)"
        )
        try FileManager.default.moveItem(at: verifiedURL, to: backupURL)
        do {
            try replacementBytes.write(to: verifiedURL, options: .withoutOverwriting)
            let observed = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: verifiedURL)
            try FileManager.default.moveItem(at: backupURL, to: verifiedURL)
            await recorder.record(bytes: observed, providerURL: url)
            return result
        } catch {
            try? FileManager.default.removeItem(at: verifiedURL)
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: verifiedURL)
            }
            throw error
        }
    }
}

private struct ReconstructionInPlaceRestoringAnalysisProvider: AnalysisProviding {
    let result: WorkspaceSnapshot
    let verifiedURL: URL
    let originalBytes: Data
    let replacementBytes: Data

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        fatalError("detached analysis uses the asynchronous provider entry point")
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        try cancellation.check()
        let descriptor = verifiedURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        var originalState = stat()
        guard Darwin.fstat(descriptor, &originalState) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try write(replacementBytes, to: descriptor)
        let observed = try Data(contentsOf: url)
        guard observed == replacementBytes else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        try write(originalBytes, to: descriptor)
        var originalTimes = [originalState.st_atimespec, originalState.st_mtimespec]
        let timeRestoreResult = originalTimes.withUnsafeMutableBufferPointer { times in
            Darwin.futimens(descriptor, times.baseAddress)
        }
        guard timeRestoreResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return result
    }

    private func write(_ bytes: Data, to descriptor: Int32) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { rawBuffer in
                Darwin.pwrite(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += count
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private final class ReconstructionPinnedXPCPathSwapProvider: PinnedAnalysisInputProviding, @unchecked Sendable {
    private let delegate: XPCAnalysisProvider
    private let verifiedURL: URL
    private let replacementBytes: Data

    init(delegate: XPCAnalysisProvider, verifiedURL: URL, replacementBytes: Data) {
        self.delegate = delegate
        self.verifiedURL = verifiedURL
        self.replacementBytes = replacementBytes
    }

    func analyze(url: URL, requestedSliceIndex: Int?, overrides: [UInt64: AddressOverride],
                 cancellation: AnalysisCancellationToken) throws -> WorkspaceSnapshot {
        try delegate.analyze(url: url, requestedSliceIndex: requestedSliceIndex,
                             overrides: overrides, cancellation: cancellation)
    }

    func openBinary(url: URL, requestedSliceIndex: Int?, overrides: [UInt64: AddressOverride],
                    cancellation: AnalysisCancellationToken) async throws -> WorkspaceSnapshot {
        try await delegate.openBinary(url: url, requestedSliceIndex: requestedSliceIndex,
                                      overrides: overrides, cancellation: cancellation)
    }

    func openPinnedBinary(url: URL, source: FileHandle, selection: BinaryLoadSelection,
                          overrides: [UInt64: AddressOverride],
                          cancellation: AnalysisCancellationToken) async throws -> WorkspaceSnapshot {
        let backupURL = verifiedURL.deletingLastPathComponent()
            .appendingPathComponent(".MacScope-xpc-pinned-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: verifiedURL, to: backupURL)
        do {
            try replacementBytes.write(to: verifiedURL, options: .withoutOverwriting)
            let workspace = try await delegate.openPinnedBinary(
                url: url, source: source, selection: selection,
                overrides: overrides, cancellation: cancellation
            )
            try FileManager.default.removeItem(at: verifiedURL)
            try FileManager.default.moveItem(at: backupURL, to: verifiedURL)
            return workspace
        } catch {
            try? FileManager.default.removeItem(at: verifiedURL)
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: verifiedURL)
            }
            throw error
        }
    }

    func rehydrate(imageBytes: Data, requestedSliceIndex: Int?, preserving persisted: ImageAnalysis,
                   cancellation: AnalysisCancellationToken) throws -> ImageAnalysis {
        try delegate.rehydrate(imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
                               preserving: persisted, cancellation: cancellation)
    }

    func rehydrate(imageBytes: Data, requestedSliceIndex: Int?, preserving persisted: ImageAnalysis,
                   overrides: [UInt64: AddressOverride],
                   cancellation: AnalysisCancellationToken) throws -> ImageAnalysis {
        try delegate.rehydrate(imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
                               preserving: persisted, overrides: overrides, cancellation: cancellation)
    }
}
