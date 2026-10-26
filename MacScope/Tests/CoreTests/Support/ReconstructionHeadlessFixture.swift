import CryptoKit
import Foundation

@testable import MacScope

struct ReconstructionHeadlessTestFixture {
    let directoryURL: URL
    let source: ReconstructionAttachmentSource
    let artifact: ReconstructionArtifactCoordinate
    let image: ReconstructionImageBinding
    let functionID: UUID
    let workspace: WorkspaceSnapshot

    static func make() throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-headless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("fixture.bin")
        let data = Data([0xcf, 0xfa, 0xed, 0xfe, 0x00, 0x00, 0x00, 0x00])
        try data.write(to: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let content = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: digest,
            byteCount: UInt64(data.count)
        )
        let source = ReconstructionAttachmentSource(contentIdentity: content, verifiedURL: file)
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: UUID()),
            contentIdentity: content
        )
        let binaryID = UUID()
        let functionID = UUID()
        let image = ReconstructionImageBinding(
            binaryID: binaryID,
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )
        let binary = BinaryImage(
            id: binaryID,
            name: "fixture",
            path: file.path,
            kind: "Mach-O",
            architecture: "arm64",
            slot: .primary
        )
        var analysis = ImageAnalysis()
        analysis.functions = [FunctionSummary(
            id: functionID,
            name: "entry",
            startAddress: 0x1000,
            endAddress: 0x1008,
            confidence: 1
        )]
        analysis.imageBytes = data
        analysis.analysisInputFingerprint = try AnalysisInputFingerprint(
            imageSlot: .primary,
            binaryID: binaryID,
            binaryName: binary.name,
            binaryPath: binary.path,
            selectedSliceIndex: nil,
            artifactIdentity: nil,
            imageByteCount: UInt64(data.count),
            imageBytesSHA256: digest,
            facets: [],
            overallSHA256: String(repeating: "b", count: 64)
        )
        return .init(
            directoryURL: directory,
            source: source,
            artifact: artifact,
            image: image,
            functionID: functionID,
            workspace: WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis])
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directoryURL) }
}

/// A parseable thin arm64 Mach-O exercised through the production default `AnalysisEngine`.
struct ReconstructionRealHeadlessTestFixture {
    let directoryURL: URL
    let source: ReconstructionAttachmentSource
    let artifact: ReconstructionArtifactCoordinate

    static func make(occurrenceID: UUID = UUID()) throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-headless-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("fixture-arm64")
        let data = MachOFixture.makeExecutableWithLoadCommandMetadata().bytes
        try data.write(to: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let content = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: digest,
            byteCount: UInt64(data.count)
        )
        return .init(
            directoryURL: directory,
            source: .init(contentIdentity: content, verifiedURL: file),
            artifact: .init(
                occurrenceID: .init(rawValue: occurrenceID),
                contentIdentity: content
            )
        )
    }

    func artifact(occurrenceID: UUID) -> ReconstructionArtifactCoordinate {
        .init(
            occurrenceID: .init(rawValue: occurrenceID),
            contentIdentity: source.contentIdentity
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directoryURL) }
}

final class ReconstructionFixedAnalysisProvider: AnalysisProviding, @unchecked Sendable {
    private let result: WorkspaceSnapshot
    init(result: WorkspaceSnapshot) { self.result = result }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        try cancellation.check()
        return result
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        try cancellation.check()
        return result
    }
}

struct ReconstructionFixedAnalysisProviderFactory: ReconstructionAnalysisProviderFactory {
    let provider: ReconstructionFixedAnalysisProvider
    func makeProvider() -> any AnalysisProviding { provider }
}
