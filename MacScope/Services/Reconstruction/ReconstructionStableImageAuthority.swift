import CryptoKit
import Foundation

/// Binds one freshly analyzed image to Reconstruction's durable, project-scoped owner without
/// letting `AnalysisEngine`'s intentionally random import UUID become persistent authority.
enum ReconstructionStableImageAuthority {
    private static let identityDomain = "MacScope.ReconstructionImageBinding.v1"
    private static let functionIdentityDomain = "MacScope.ReconstructionFunctionBinding.v1"

    struct BoundSnapshot: Sendable {
        let image: ReconstructionImageBinding
        let workspace: WorkspaceSnapshot
        let analysisInputFingerprintSHA256: String
    }

    static func bind(
        freshWorkspace: WorkspaceSnapshot,
        artifact: ReconstructionArtifactCoordinate,
        expectedImage: ReconstructionImageBinding?
    ) throws -> BoundSnapshot {
        guard freshWorkspace.binaries.count == 1,
              let freshBinary = freshWorkspace.binaries.first,
              let freshAnalysis = freshWorkspace.analysis(in: freshBinary.slot),
              let freshFingerprint = freshAnalysis.analysisInputFingerprint,
              freshFingerprint.binaryID == freshBinary.id,
              freshFingerprint.imageSlot == freshBinary.slot,
              freshFingerprint.binaryName == freshBinary.name,
              freshFingerprint.binaryPath == freshBinary.path,
              freshFingerprint.selectedSliceIndex == freshBinary.selectedSliceIndex,
              freshFingerprint.artifactIdentity == freshBinary.artifactIdentity,
              (try? freshWorkspace.validateInvariants()) != nil else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }

        if let identity = freshBinary.artifactIdentity {
            guard UInt64(freshAnalysis.imageBytes.count) == identity.selectedSliceByteCount,
                  AnalysisFingerprintBuilder.sha256Hex(freshAnalysis.imageBytes)
                    == identity.selectedSliceSHA256,
                  freshBinary.artifactIntegrityState == .verified,
                  let layout = freshBinary.preferredSegmentLayout,
                  (try? MachOPreferredSegmentLayout(
                      records: layout.records,
                      selectedSliceByteCount: identity.selectedSliceByteCount
                  )) != nil else {
                throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
            }
        } else {
            guard freshBinary.preferredSegmentLayout == nil,
                  freshBinary.artifactIntegrityState == .unavailable,
                  UInt64(freshAnalysis.imageBytes.count)
                    == artifact.contentIdentity.byteCount,
                  AnalysisFingerprintBuilder.sha256Hex(freshAnalysis.imageBytes)
                    == artifact.contentIdentity.digest else {
                throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
            }
        }
        let architecture = reconstructionArchitecture(
            artifactIdentity: freshBinary.artifactIdentity,
            displayName: freshBinary.architecture
        )
        let boundImage: ReconstructionImageBinding
        if let expectedImage {
            guard freshBinary.selectedSliceIndex == expectedImage.selectedSliceIndex,
                  architecture == expectedImage.architecture,
                  freshBinary.artifactIdentity == expectedImage.machOIdentity else {
                throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
            }
            boundImage = expectedImage
        } else {
            boundImage = ReconstructionImageBinding(
                binaryID: stableBinaryID(
                    occurrenceID: artifact.occurrenceID,
                    selectedSliceIndex: freshBinary.selectedSliceIndex
                ),
                imageSlot: .primary,
                selectedSliceIndex: freshBinary.selectedSliceIndex,
                architecture: architecture,
                machOIdentity: freshBinary.artifactIdentity
            )
        }

        if freshBinary.slot != boundImage.imageSlot {
            guard freshWorkspace.binary(in: boundImage.imageSlot) == nil,
                  freshWorkspace.analysis(in: boundImage.imageSlot) == nil else {
                throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
            }
        }

        var rebound = freshWorkspace
        rebound.remapImageSlot(from: freshBinary.slot, to: boundImage.imageSlot)
        guard let binaryIndex = rebound.binaries.firstIndex(where: {
            $0.slot == boundImage.imageSlot
        }) else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        let stableBinary = BinaryImage(
            id: boundImage.binaryID,
            name: freshBinary.name,
            path: freshBinary.path,
            kind: freshBinary.kind,
            architecture: freshBinary.architecture,
            originalPathBookmark: freshBinary.originalPathBookmark,
            metadata: freshBinary.metadata,
            selectedSliceIndex: freshBinary.selectedSliceIndex,
            machOSelectedSliceFact: freshBinary.machOSelectedSliceFact,
            artifactIdentity: freshBinary.artifactIdentity,
            preferredSegmentLayout: freshBinary.preferredSegmentLayout,
            artifactIntegrityState: freshBinary.artifactIntegrityState,
            resolvedExecutablePath: freshBinary.resolvedExecutablePath,
            slot: boundImage.imageSlot
        )
        rebound.binaries[binaryIndex] = stableBinary

        var reboundAnalysis = freshAnalysis
        do {
            reboundAnalysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
                binary: stableBinary,
                analysis: reboundAnalysis
            )
        } catch {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        rebound.replaceAnalysis(reboundAnalysis, in: boundImage.imageSlot)
        guard let fingerprint = reboundAnalysis.analysisInputFingerprint,
              fingerprint.binaryID == boundImage.binaryID,
              fingerprint.imageSlot == boundImage.imageSlot,
              fingerprint.selectedSliceIndex == boundImage.selectedSliceIndex,
              fingerprint.artifactIdentity == boundImage.machOIdentity,
              (try? rebound.validateInvariants()) != nil else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        return BoundSnapshot(
            image: boundImage,
            workspace: rebound,
            analysisInputFingerprintSHA256: fingerprint.overallSHA256
        )
    }

    static func bindFunction(
        _ coordinate: ReconstructionFunctionCoordinate,
        artifact: ReconstructionArtifactCoordinate,
        in bound: BoundSnapshot
    ) throws -> (snapshot: BoundSnapshot, functionID: UUID) {
        guard coordinate.artifact == artifact,
              coordinate.image == bound.image,
              coordinate.analysisFingerprintSHA256
                == bound.analysisInputFingerprintSHA256,
              coordinate.boundarySchemaVersion
                == ReconstructionFunctionCoordinate.schemaVersion,
              var analysis = bound.workspace.analysis(in: bound.image.imageSlot) else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }

        let functionIDs = analysis.functions.map(\.id)
        guard Set(functionIDs).count == functionIDs.count,
              Set(analysis.basicBlocks.map(\.functionID)).isSubset(of: Set(functionIDs)) else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        let candidates = analysis.functions.indices.filter { index in
            let function = analysis.functions[index]
            return function.startAddress == coordinate.startAddress
                && function.endAddress == coordinate.endAddressExclusive
        }
        guard candidates.count == 1, let selectedIndex = candidates.first else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }

        let selected = analysis.functions[selectedIndex]
        let stableID = stableFunctionID(
            image: bound.image,
            analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256,
            startAddress: coordinate.startAddress,
            endAddressExclusive: coordinate.endAddressExclusive,
            boundarySchemaVersion: coordinate.boundarySchemaVersion
        )
        guard !analysis.functions.enumerated().contains(where: { index, function in
            index != selectedIndex && function.id == stableID
        }) else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        analysis.functions[selectedIndex] = FunctionSummary(
            id: stableID,
            name: selected.name,
            startAddress: selected.startAddress,
            endAddress: selected.endAddress,
            confidence: selected.confidence,
            noReturnProvenance: selected.noReturnProvenance
        )
        analysis.basicBlocks = analysis.basicBlocks.map { block in
            var rebound = block
            if rebound.functionID == selected.id {
                rebound.functionID = stableID
            }
            return rebound
        }
        let reboundFunctionIDs = Set(analysis.functions.map(\.id))
        guard Set(analysis.basicBlocks.map(\.functionID)).isSubset(of: reboundFunctionIDs),
              let binary = bound.workspace.binary(in: bound.image.imageSlot) else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }

        do {
            analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
                binary: binary,
                analysis: analysis
            )
        } catch {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        guard let fingerprint = analysis.analysisInputFingerprint,
              fingerprint.overallSHA256 == coordinate.analysisFingerprintSHA256 else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        var workspace = bound.workspace
        workspace.replaceAnalysis(analysis, in: bound.image.imageSlot)
        guard (try? workspace.validateInvariants()) != nil else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        return (
            BoundSnapshot(
                image: bound.image,
                workspace: workspace,
                analysisInputFingerprintSHA256: fingerprint.overallSHA256
            ),
            stableID
        )
    }

    /// RFC 9562 UUIDv8: the version and variant bits identify an application-defined,
    /// name-derived UUID while the remaining 122 bits retain the SHA-256 preimage binding.
    static func stableBinaryID(
        occurrenceID: ReconstructionArtifactOccurrenceID,
        selectedSliceIndex: Int?
    ) -> UUID {
        var preimage = Data(identityDomain.utf8)
        preimage.append(0)
        preimage.append(contentsOf: occurrenceID.rawValue.uuidString.lowercased().utf8)
        preimage.append(0)
        if let selectedSliceIndex {
            preimage.append(contentsOf: "slice:\(selectedSliceIndex)".utf8)
        } else {
            preimage.append(contentsOf: "slice:default".utf8)
        }
        return nameDerivedUUID(preimage)
    }

    static func stableFunctionID(
        image: ReconstructionImageBinding,
        analysisFingerprintSHA256: String,
        startAddress: UInt64,
        endAddressExclusive: UInt64,
        boundarySchemaVersion: Int
    ) -> UUID {
        var preimage = Data(functionIdentityDomain.utf8)
        preimage.append(0)
        preimage.append(contentsOf: image.binaryID.uuidString.lowercased().utf8)
        preimage.append(0)
        preimage.append(contentsOf: analysisFingerprintSHA256.utf8)
        preimage.append(0)
        var start = startAddress.bigEndian
        var end = endAddressExclusive.bigEndian
        var schema = Int64(boundarySchemaVersion).bigEndian
        withUnsafeBytes(of: &start) { preimage.append(contentsOf: $0) }
        withUnsafeBytes(of: &end) { preimage.append(contentsOf: $0) }
        withUnsafeBytes(of: &schema) { preimage.append(contentsOf: $0) }
        return nameDerivedUUID(preimage)
    }

    private static func nameDerivedUUID(_ preimage: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: preimage).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func reconstructionArchitecture(
        artifactIdentity: MachOSliceArtifactIdentity?,
        displayName: String
    ) -> ReconstructionArchitecture {
        if let artifactIdentity {
            switch artifactIdentity.architectureVariant {
            case .arm64: return .arm64
            case .arm64e: return .arm64e
            case .x86_64: return .x86_64
            case .x86_64h: return .x86_64h
            case .other: return .unknown
            }
        }
        let normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let discriminator = normalized.split(whereSeparator: {
            $0.isWhitespace || $0 == "("
        }).first.map(String.init) ?? ""
        return ReconstructionArchitecture(rawValue: discriminator) ?? .unknown
    }
}
