import Darwin
import Foundation
import CryptoKit
import SwiftUI

enum MacScopeDocumentPackage {
    static let fileExtension = "mscope"
    static let manifestFileName = "manifest.json"
    static let attachmentsDirectoryName = "attachments"
    static let formatIdentifier = "org.macscope.workspace-package"
    /// Capture bound for manifest.json only. Legacy v1–3 packages may still contain large
    /// inline instruction arrays; v4 moves those rows to an independently bounded binary file.
    static let maximumManifestBytes: UInt64 = ReconstructionPackageLayout.maximumCorpusAttachmentBytes

    struct PackageWriteTestHooks {
        var didSynchronizeDirectory: ((URL) -> Void)? = nil
        var beforeDestinationParentSynchronization: (() throws -> Void)? = nil
        var beforePublicationRollbackRename: (() throws -> Void)? = nil
        var beforePublicationRollbackParentSynchronization: (() throws -> Void)? = nil
        var beforeRetiredPackageCleanup: (() throws -> Void)? = nil
    }

    struct PackageOpenTestHooks {
        var afterInitialAttachmentValidation: (() throws -> Void)? = nil
    }

    /// A reader capability error is distinct from a corrupt package or write failure. Keeping it
    /// separate also leaves the established closed write-error classification unchanged.
    struct UnsupportedReaderFeaturesError: Error, Equatable, LocalizedError {
        let features: [String]
        var errorDescription: String? {
            if !features.isEmpty && features.allSatisfy({ $0 == WorkspacePackageManifest.analystFindingCitationsReaderFeature }) {
                return String(format: String(localized: "analyst.findings.requiresNewerBuild",
                    defaultValue: "This workspace carries analyst findings that cite contract facts and needs a MacScope build that supports %@ (October 2026 or newer)."),
                    features.joined(separator: ", "))
            }
            return String(format: String(localized: "reconstruction.replay.requiresNewerBuild",
                defaultValue: "This workspace was saved while a reconstruction job was running and needs a MacScope build that supports %@ (October 2026 or newer)."),
                features.joined(separator: ", "))
        }
    }

    enum PackageError: Error, Equatable, LocalizedError {
        case duplicateBinaryID(UUID)
        case duplicateImageSlot(ImageSlot)
        case duplicateAssistantSessionID(UUID)
        case duplicateAssistantSessionSequence(Int)
        case duplicateAssistantConversationTurn(UUID, Int)
        case duplicateAssistantInferenceTurnID(UUID)
        case duplicateAssistantShellProposalID(UUID)
        case duplicateAssistantShellExecutionID(UUID)
        case duplicateAssistantContinuationRequestID(UUID)
        case invalidAssistantContinuationCheckpoint(UUID)
        case duplicateRuntimeAuthorityRecordID(UUID)
        case duplicateImageAnalysisBinaryID(UUID)
        case duplicateImageAnalysisSlot(ImageSlot)
        case imageAnalysisSlotMismatch(binaryID: UUID, binarySlot: ImageSlot, analysisSlot: ImageSlot)
        case missingImageAnalysis(UUID)
        case unknownImageAnalysisBinaryID(UUID)
        case unknownAttachmentBinaryID(UUID)
        case attachmentHashMismatch(String, expected: String, actual: String)
        case attachmentSizeMismatch(String, expected: Int64, actual: Int64)
        case invalidAttachmentHash(String)
        case invalidArchiveMemberIdentity(UUID)
        case archiveMemberAttachmentMismatch(UUID)
        case archiveMemberFingerprintMismatch(UUID)
        case binaryMetadataFingerprintMismatch(UUID)
        case attachmentArtifactReconstructionFailed(String)
        case emptyWorkspaceName
        case invalidAttachmentRelativePath(String)
        case invalidFormatIdentifier(String)
        case missingAttachment(String)
        case invalidAssistantSessionProviderToolCount(UUID, Int)
        case invalidAssistantSessionSchemaVersion(UUID, Int)
        case invalidAssistantSessionContentHash(UUID)
        case invalidRuntimeAuthorityRecord(UUID)
        case invalidRuntimeAuthorityRecordSchemaVersion(UUID, Int)
        case unsupportedFormatVersion(Int)
        case version1ContainsImageAnalyses
        case version2ImageAnalysisContainsAuthoring(UUID)
        case version2TopLevelAnalysisContainsDerivedData
        case packagePublicationRollbackFailed(recoveryURL: URL)
        case packagePublicationCleanupOwnershipUnproven(recoveryURL: URL)
        case newerAnalyzerVersion(Int, missingFeatures: [String])

        var errorDescription: String? {
            switch self {
            case .duplicateBinaryID(let id):
                "Package manifest contains duplicate binary ID \(id.uuidString)."
            case .duplicateImageSlot(let slot):
                "Package manifest contains duplicate binary image slot \(slot.rawValue)."
            case .duplicateAssistantSessionID(let id):
                "Package manifest contains duplicate Assistant session record ID \(id.uuidString)."
            case .duplicateAssistantSessionSequence(let sequence):
                "Package manifest contains duplicate Assistant session sequence \(sequence)."
            case .duplicateAssistantConversationTurn(let conversationID, let sequence):
                "Package manifest contains duplicate Assistant conversation turn \(conversationID.uuidString)#\(sequence)."
            case .duplicateAssistantInferenceTurnID(let id):
                "Package manifest contains duplicate Assistant inference turn ID \(id.uuidString)."
            case .duplicateAssistantShellProposalID(let id):
                "Package manifest contains duplicate Assistant shell proposal ID \(id.uuidString)."
            case .duplicateAssistantShellExecutionID(let id):
                "Package manifest contains duplicate Assistant shell execution ID \(id.uuidString)."
            case .duplicateAssistantContinuationRequestID(let id):
                "Package manifest contains duplicate Assistant continuation request ID \(id.uuidString)."
            case .invalidAssistantContinuationCheckpoint(let id):
                "Package Assistant session \(id.uuidString) contains an invalid continuation checkpoint."
            case .duplicateRuntimeAuthorityRecordID(let id):
                "Package manifest contains duplicate runtime-authority record ID \(id.uuidString)."
            case .duplicateImageAnalysisBinaryID(let id):
                "Package manifest contains duplicate analysis records for binary \(id.uuidString)."
            case .duplicateImageAnalysisSlot(let slot):
                "Package manifest contains duplicate analysis image slot \(slot.rawValue)."
            case .imageAnalysisSlotMismatch(let binaryID, let binarySlot, let analysisSlot):
                "Package analysis for binary \(binaryID.uuidString) declares slot \(analysisSlot.rawValue), but the binary declares slot \(binarySlot.rawValue)."
            case .missingImageAnalysis(let id):
                "Package manifest has no image analysis for binary \(id.uuidString)."
            case .unknownImageAnalysisBinaryID(let id):
                "Package image analysis references unknown binary \(id.uuidString)."
            case .unknownAttachmentBinaryID(let id):
                "Package attachment payload references unknown binary \(id.uuidString)."
            case .attachmentHashMismatch(let path, let expected, let actual):
                "Package attachment hash mismatch for \(path). Expected \(expected), found \(actual)."
            case .attachmentSizeMismatch(let path, let expected, let actual):
                "Package attachment size mismatch for \(path). Expected \(expected) bytes, found \(actual) bytes."
            case .invalidAttachmentHash(let path):
                "Package v3 attachment hash is not canonical lowercase SHA-256: \(path)"
            case .invalidArchiveMemberIdentity(let id):
                "Package binary \(id.uuidString) contains an invalid ELF archive member identity."
            case .archiveMemberAttachmentMismatch(let id):
                "Package binary \(id.uuidString) attachment does not match its selected ELF archive member."
            case .archiveMemberFingerprintMismatch(let id):
                "Package binary \(id.uuidString) archive member identity disagrees with its analysis fingerprint."
            case .binaryMetadataFingerprintMismatch(let id):
                "Package binary \(id.uuidString) loader metadata disagrees with its analysis fingerprint."
            case .attachmentArtifactReconstructionFailed(let path):
                "Package Mach-O attachment cannot be reconstructed as a complete selected slice: \(path)"
            case .emptyWorkspaceName:
                "Package manifest workspace name is empty."
            case .invalidAttachmentRelativePath(let path):
                "Package manifest attachment path is not package-relative: \(path)"
            case .invalidFormatIdentifier(let identifier):
                "Unsupported MacScope package format identifier: \(identifier)"
            case .missingAttachment(let path):
                "Package attachment is missing: \(path)"
            case .invalidAssistantSessionProviderToolCount(let id, let count):
                "Package Assistant session \(id.uuidString) declares provider tool count \(count); expected \(WorkspacePackageAssistantSessionRecord.providerToolCountRange.lowerBound)...\(WorkspacePackageAssistantSessionRecord.providerToolCountRange.upperBound)."
            case .invalidAssistantSessionSchemaVersion(let id, let version):
                "Package Assistant session \(id.uuidString) uses unsupported record schema version \(version)."
            case .invalidAssistantSessionContentHash(let id):
                "Package Assistant session \(id.uuidString) failed content-hash validation."
            case .invalidRuntimeAuthorityRecord(let id):
                "Package runtime-authority record \(id.uuidString) is structurally invalid."
            case .invalidRuntimeAuthorityRecordSchemaVersion(let id, let version):
                "Package runtime-authority record \(id.uuidString) uses unsupported record schema version \(version)."
            case .unsupportedFormatVersion(let version):
                "Unsupported MacScope package format version: \(version)"
            case .version1ContainsImageAnalyses:
                "Package v1 manifest contains v2 per-image analysis records; refusing to flatten them."
            case .version2ImageAnalysisContainsAuthoring(let id):
                "Package v2 image analysis for binary \(id.uuidString) contains workspace authoring that belongs in the top-level analysis."
            case .version2TopLevelAnalysisContainsDerivedData:
                "Package v2 top-level analysis contains image-derived data that belongs in a per-image analysis record."
            case .packagePublicationRollbackFailed(let recoveryURL):
                "Package publication rollback failed; the prior package remains recoverable at \(recoveryURL.path)."
            case .packagePublicationCleanupOwnershipUnproven(let recoveryURL):
                "Package publication cleanup ownership was not proven; recovery content remains at \(recoveryURL.path)."
            case .newerAnalyzerVersion(let version, let missingFeatures):
                "This workspace was saved by a newer MacScope analyzer (version \(version); this build reads up to "
                    + "version \(WorkspaceAnalyzerStamp.currentVersion)). This build lacks: "
                    + missingFeatures.joined(separator: "; ") + ". Open it with a newer MacScope."
            }
        }
    }

    static func fileHash(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func manifestURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent(manifestFileName, isDirectory: false)
    }

    static func attachmentRelativePath(for binaryID: UUID, originalPath: String) -> String {
        let fileName = sanitizedFileName(
            from: URL(fileURLWithPath: originalPath).lastPathComponent,
            fallbackID: binaryID
        )
        return [
            attachmentsDirectoryName,
            binaryID.uuidString.lowercased(),
            fileName
        ].joined(separator: "/")
    }

    static func attachmentURL(in packageURL: URL, for binaryID: UUID, originalPath: String) -> URL {
        attachmentRelativePath(for: binaryID, originalPath: originalPath)
            .split(separator: "/")
            .reduce(packageURL) { url, component in
                url.appendingPathComponent(String(component), isDirectory: false)
            }
    }

    static func attachmentURL(in packageURL: URL, relativePath: String) throws -> URL {
        try attachmentPathComponents(relativePath).reduce(packageURL) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }
    }

    static func encodedManifest(_ manifest: WorkspacePackageManifest) throws -> Data {
        try manifestEncoder().encode(manifest)
    }

    static func validatedContents(
        manifestData: Data,
        attachmentsByBinaryID: [UUID: Data],
        reconstructionState: ReconstructionWorkspaceState = .empty,
        instructionSidecarData: Data? = nil
    ) throws -> WorkspacePackageContents {
        try Task.checkCancellation()
        let manifest = try validatedManifest(manifestData: manifestData)
        _ = try validatedAttachmentPayloads(
            for: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID
        )
        try validatePersistedAnalysisBindings(
            for: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID
        )
        if manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion {
            let encoded = try ReconstructionPackageCodec.encode(reconstructionState)
            guard encoded.descriptor == manifest.reconstruction else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "workspace manifest descriptor disagreement"
                )
            }
        } else if reconstructionState != .empty {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "legacy package contains reconstruction state"
            )
        }
        return try packageContents(
            manifest: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID,
            reconstructionState: reconstructionState,
            reconstructionAttachmentSources: [],
            instructionSidecarData: instructionSidecarData
        )
    }

    static func validatedManifest(
        manifestData: Data
    ) throws -> WorkspacePackageManifest {
        try Task.checkCancellation()
        let scope = WorkspaceManifestDecodeScope.current
        if let cached = scope?.manifest(for: manifestData) { return cached }
        let decoded = try decodedManifest(from: manifestData)
        try validateManifest(
            decoded.manifest,
            in: URL(fileURLWithPath: "/", isDirectory: true)
        )
        scope?.record(
            decoded.manifest,
            for: manifestData,
            canonicalEncoding: decoded.canonicalEncoding
        )
        return decoded.manifest
    }

    /// `encodedManifest(manifest)` for a manifest that `validatedManifest(manifestData: data)`
    /// (directly or through `validatedContents`/`openPackage`) produced from `data`. Inside a
    /// `WorkspaceManifestDecodeScope` the canonical bytes are computed once per byte buffer.
    static func canonicalEncodedManifest(
        _ manifest: WorkspacePackageManifest,
        decodedFrom data: Data
    ) throws -> Data {
        let scope = WorkspaceManifestDecodeScope.current
        if let cached = scope?.canonicalEncoding(for: data) { return cached }
        let encoded = try encodedManifest(manifest)
        scope?.recordCanonicalEncoding(encoded, for: data)
        return encoded
    }

    static func preparePackageDirectory(
        at packageURL: URL,
        for manifest: WorkspacePackageManifest,
        fileManager: FileManager = .default
    ) throws {
        try Task.checkCancellation()
        try validateManifest(manifest, in: packageURL, fileManager: fileManager)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: packageURL.appendingPathComponent(attachmentsDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )

        for binary in manifest.binaries {
            try Task.checkCancellation()
            let attachmentURL = try attachmentURL(in: packageURL, relativePath: binary.attachmentRelativePath)
            try fileManager.createDirectory(
                at: attachmentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    static func writeManifest(
        _ manifest: WorkspacePackageManifest,
        to packageURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try Task.checkCancellation()
        try preparePackageDirectory(at: packageURL, for: manifest, fileManager: fileManager)
        let data = try encodedManifest(manifest)
        try Task.checkCancellation()
        try data.write(to: manifestURL(in: packageURL), options: [.atomic])
        try Task.checkCancellation()
    }

    /// Returns the manifest actually written: the canonical v4 form with its instruction sidecar
    /// descriptor, not the caller's input manifest.
    @discardableResult
    static func writePackage(
        _ manifest: WorkspacePackageManifest,
        attachmentsByBinaryID: [UUID: Data],
        reconstructionState: ReconstructionWorkspaceState = .empty,
        reconstructionAttachmentSources: [ReconstructionAttachmentSource] = [],
        to packageURL: URL,
        fileManager: FileManager = .default,
        testHooks: PackageWriteTestHooks? = nil,
        instructionSidecarData: Data? = nil
    ) throws -> WorkspacePackageManifest {
        try Task.checkCancellation()
        let prepared = try preparedPackageManifest(
            manifest,
            reconstructionState: reconstructionState,
            instructionSidecarData: instructionSidecarData
        )
        let instructionStorage = try preparedInstructionStorage(
            prepared.manifest, instructionSidecarData: prepared.manifest.instructionSidecar == nil ? nil : instructionSidecarData
        )
        let manifest = instructionStorage.manifest
        try validateManifest(manifest, in: packageURL, fileManager: fileManager)
        let attachmentPayloads = try validatedAttachmentPayloads(
            for: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID
        )
        try validatePersistedAnalysisBindings(
            for: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID
        )
        try Task.checkCancellation()

        let temporaryPackageURL = temporaryReplacementURL(for: packageURL)
        try? fileManager.removeItem(at: temporaryPackageURL)
        do {
            var stagedPackageIsComplete = false
            defer {
                if !stagedPackageIsComplete {
                    try? fileManager.removeItem(at: temporaryPackageURL)
                }
            }

            try fileManager.createDirectory(
                at: packageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try preparePackageDirectory(
                at: temporaryPackageURL,
                for: manifest,
                fileManager: fileManager
            )

            for payload in attachmentPayloads {
                try Task.checkCancellation()
                let url = try attachmentURL(
                    in: temporaryPackageURL,
                    relativePath: payload.binary.attachmentRelativePath
                )
                try payload.data.write(to: url, options: [.atomic])
                try Task.checkCancellation()
                try synchronizeFile(at: url)
            }

            try Task.checkCancellation()
            if let encoded = prepared.reconstruction {
                try writeReconstructionPackage(
                    encoded,
                    sources: reconstructionAttachmentSources,
                    to: temporaryPackageURL,
                    fileManager: fileManager
                )
            } else if !reconstructionAttachmentSources.isEmpty {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "legacy package has reconstruction attachment sources"
                )
            }
            let instructionURL = temporaryPackageURL.appendingPathComponent(WorkspaceInstructionSidecarCodec.fileName)
            try instructionStorage.data.write(to: instructionURL, options: [.atomic])
            try synchronizeFile(at: instructionURL)
            let data = try encodedManifest(manifest)
            try Task.checkCancellation()
            try data.write(to: manifestURL(in: temporaryPackageURL), options: [.atomic])
            try Task.checkCancellation()
            try synchronizeFile(at: manifestURL(in: temporaryPackageURL))
            try synchronizePackageDirectories(
                at: temporaryPackageURL,
                observer: testHooks?.didSynchronizeDirectory
            )
            try Task.checkCancellation()
            _ = try openPackage(from: temporaryPackageURL, fileManager: fileManager)
            try Task.checkCancellation()
            stagedPackageIsComplete = true
        }
        try publishStagedPackage(
            at: packageURL,
            stagedAt: temporaryPackageURL,
            fileManager: fileManager,
            testHooks: testHooks
        )
        return manifest
    }

    static func preparedManifest(
        _ manifest: WorkspacePackageManifest,
        reconstructionState: ReconstructionWorkspaceState,
        instructionSidecarData: Data? = nil
    ) throws -> WorkspacePackageManifest {
        try preparedPackageManifest(
            manifest,
            reconstructionState: reconstructionState,
            instructionSidecarData: instructionSidecarData
        ).manifest
    }

    static func readManifest(
        from packageURL: URL,
        fileManager: FileManager = .default,
        requireAttachments: Bool = false
    ) throws -> WorkspacePackageManifest {
        try Task.checkCancellation()
        let data = try readRegularFile(
            at: manifestURL(in: packageURL),
            relativeTo: packageURL,
            maximumByteCount: Int(maximumManifestBytes)
        )
        try Task.checkCancellation()
        let manifest = try validatedManifest(manifestData: data)
        try validateManifest(
            manifest,
            in: packageURL,
            requireAttachments: requireAttachments,
            fileManager: fileManager
        )
        if requireAttachments {
            _ = try validatedInstructionGroups(manifest, data: readInstructionSidecar(for: manifest, in: packageURL))
        }
        return manifest
    }

    static func openPackage(
        from packageURL: URL,
        fileManager: FileManager = .default,
        testHooks: PackageOpenTestHooks? = nil
    ) throws -> WorkspacePackageContents {
        try Task.checkCancellation()
        let manifestData = try readRegularFile(
            at: manifestURL(in: packageURL),
            relativeTo: packageURL,
            maximumByteCount: Int(maximumManifestBytes)
        )
        try Task.checkCancellation()
        let manifest = try validatedManifest(manifestData: manifestData)
        // Preserve the path-based adapter's typed package errors before raw file reads. The
        // session authority uses already-observed bytes; legacy callers of this API still expect
        // a missing declared attachment to surface as `PackageError.missingAttachment`.
        try validateManifest(
            manifest,
            in: packageURL,
            requireAttachments: true,
            fileManager: fileManager
        )
        try Task.checkCancellation()
        try testHooks?.afterInitialAttachmentValidation?()
        try Task.checkCancellation()
        var attachmentsByBinaryID: [UUID: Data] = [:]
        for binary in manifest.binaries {
            try Task.checkCancellation()
            guard let maximumByteCount = Int(exactly: binary.fileSize),
                  maximumByteCount >= 0 else {
                throw PackageError.attachmentSizeMismatch(
                    binary.attachmentRelativePath,
                    expected: binary.fileSize,
                    actual: -1
                )
            }
            attachmentsByBinaryID[binary.id] = try readRegularFile(
                at: attachmentURL(
                    in: packageURL,
                    relativePath: binary.attachmentRelativePath
                ),
                relativeTo: packageURL,
                maximumByteCount: maximumByteCount
            )
            try Task.checkCancellation()
        }
        _ = try validatedAttachmentPayloads(
            for: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID
        )
        try validatePersistedAnalysisBindings(
            for: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID
        )
        try Task.checkCancellation()
        let reconstruction: (
            state: ReconstructionWorkspaceState,
            sources: [ReconstructionAttachmentSource]
        )
        if manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion {
            try Task.checkCancellation()
            reconstruction = try readReconstructionPackage(
                descriptor: manifest.reconstruction,
                from: packageURL,
                fileManager: fileManager
            )
        } else {
            reconstruction = (.empty, [])
        }
        let instructionSidecarData = try readInstructionSidecar(for: manifest, in: packageURL)
        let contents = try packageContents(
            manifest: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID,
            reconstructionState: reconstruction.state,
            reconstructionAttachmentSources: reconstruction.sources,
            instructionSidecarData: instructionSidecarData
        )
        try Task.checkCancellation()
        return contents
    }

    private static func packageContents(
        manifest: WorkspacePackageManifest,
        attachmentsByBinaryID: [UUID: Data],
        reconstructionState: ReconstructionWorkspaceState,
        reconstructionAttachmentSources: [ReconstructionAttachmentSource],
        instructionSidecarData: Data?
    ) throws -> WorkspacePackageContents {
        try Task.checkCancellation()
        guard manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.reconstructionReplayReaderFeature)
                == (reconstructionState.replayRecords != nil),
              reconstructionState.replayRecords == (try reconstructionState.pruningTerminalReplayRecordsForSave()).replayRecords else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("owner replay reader feature disagreement")
        }
        try manifest.analystFindings?.validate(workspaceID: manifest.workspaceUUID, documentID: manifest.documentID)
        guard manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingsReaderFeature)
                == (manifest.analystFindings.map { !$0.isEmpty } ?? false),
              manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingHistoryReaderFeature)
                == (manifest.analystFindings?.schemaVersion == 2) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("analyst finding reader feature disagreement")
        }
        guard analystFindingCitationsFeatureAgrees(manifest) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("analyst finding v2 reader feature disagreement")
        }
        let persistedManifest = manifest
        let manifest = try manifestByRestoringInstructions(manifest, instructionSidecarData: instructionSidecarData)
        let sortedBinaries = manifest.binaries.sorted {
            ($0.slot.rawValue, $0.id.uuidString) < ($1.slot.rawValue, $1.id.uuidString)
        }
        var binaryImages: [BinaryImage] = []
        for binary in sortedBinaries {
            try Task.checkCancellation()
            guard let attachmentData = attachmentsByBinaryID[binary.id] else {
                throw PackageError.missingAttachment(binary.attachmentRelativePath)
            }
            let appearsMachO = binary.kind.localizedCaseInsensitiveContains("mach-o")
                || binary.kind.localizedCaseInsensitiveContains("app bundle")
            let artifact: MachOSliceArtifactReconstruction?
            if appearsMachO {
                do {
                    artifact = try MachOSliceArtifactReconstructor
                        .reconstructOrMarkUnavailableForAnonymousObject(
                            selectedSliceBytes: attachmentData
                        )
                } catch {
                    throw PackageError.attachmentArtifactReconstructionFailed(
                        binary.attachmentRelativePath
                    )
                }
            } else {
                artifact = nil
            }
            binaryImages.append(
                BinaryImage(
                    id: binary.id,
                    name: binary.displayName,
                    path: binary.originalPath,
                    kind: binary.kind,
                    architecture: binary.architecture,
                    originalPathBookmark: binary.originalPathBookmark,
                    metadata: binary.metadata ?? .empty,
                    selectedSliceIndex: binary.selectedSliceIndex,
                    machOSelectedSliceFact: binary.machOSelectedSliceFact,
                    elfArchiveMemberIdentity: binary.elfArchiveMemberIdentity,
                    artifactIdentity: artifact?.identity,
                    preferredSegmentLayout: artifact?.preferredSegmentLayout,
                    artifactIntegrityState: artifact == nil ? .unavailable : .verified,
                    resolvedExecutablePath: nil,
                    slot: binary.slot
                )
            )
        }

        let snapshot: WorkspaceSnapshot
        if manifest.analysisFormatVersion == WorkspacePackageManifest.currentFormatVersion {
            // Legacy v1 has one flat analysis associated with the primary/first binary. Join its
            // attachment by UUID (not "first nonempty" sentinel) so a valid zero-byte payload
            // cannot accidentally inherit a sibling's bytes.
            let analysis = manifest.analysis ?? WorkspacePackageAnalysis()
            let primaryImageBytes = sortedBinaries.first
                .flatMap { attachmentsByBinaryID[$0.id] } ?? Data()
            var legacySnapshot = analysis.snapshot(
                binaries: binaryImages,
                hexBytes: Data(primaryImageBytes.prefix(WorkspaceSnapshot.hexViewByteWindow))
            )
            legacySnapshot.imageBytes = primaryImageBytes
            snapshot = legacySnapshot
        } else {
            let authoring = manifest.analysis ?? WorkspacePackageAnalysis()
            var recordsByBinaryID: [UUID: WorkspacePackageImageAnalysis] = [:]
            for record in manifest.imageAnalyses ?? [] {
                try Task.checkCancellation()
                recordsByBinaryID[record.binaryID] = record
            }
            var analysisBySlot: [ImageSlot: ImageAnalysis] = [:]
            for binary in sortedBinaries {
                try Task.checkCancellation()
                // validateManifest proved the 1:1 UUID+slot join before dictionary construction.
                guard let record = recordsByBinaryID[binary.id] else {
                    throw PackageError.missingImageAnalysis(binary.id)
                }
                let imageBytes = attachmentsByBinaryID[binary.id] ?? Data()
                analysisBySlot[binary.slot] = record.analysis.imageAnalysis(
                    hexBytes: Data(imageBytes.prefix(WorkspaceSnapshot.hexViewByteWindow)),
                    imageBytes: imageBytes
                )
            }
            snapshot = WorkspaceSnapshot(
                binaries: binaryImages,
                analysisBySlot: analysisBySlot,
                addressOverrides: WorkspacePackageAnalysis.overrideMap(from: authoring.addressOverrides),
                importedPrototypes: ImportedPrototypeEntry.map(from: authoring.importedPrototypes),
                typeDefinitions: authoring.typeDefinitions,
                manualXRefs: authoring.manualXRefs,
                bookmarks: authoring.bookmarks,
                segmentOverrides: authoring.segmentOverrides,
                logicalBreakpointCatalog: authoring.logicalBreakpointCatalog,
                launchProfileCatalog: authoring.launchProfileCatalog,
                savedWatchCatalog: authoring.savedWatchCatalog,
                sourceLinkState: authoring.sourceLinkState
            )
        }
        // HS-1: never trust a saved analysis blindly. Drop inconsistent procedures and derived
        // entries; the store rebuilds the affected images through its reanalysis path.
        var repairedSnapshot = snapshot
        // Reuse canonical facets only through the SHA-admitted sidecar's decoded group. The
        // descriptor SHA covers presentation fields and all images; it is not a semantic facet.
        // No digest supplied by a package is trusted as a memo. Mutation/repair invalidates it.
        if let descriptor = persistedManifest.instructionSidecar,
           let data = instructionSidecarData,
           let groups = WorkspaceManifestDecodeScope.current?.instructionGroups(for: data, descriptor: descriptor) {
            for group in groups {
                let slot = group.imageSlot ?? binaryImages.first?.slot ?? .primary
                guard var analysis = repairedSnapshot.analysisBySlot[slot] else { continue }
                analysis.instructionFingerprintMemo = group.instructionFingerprintMemo
                if group.controlFlowEdges != nil {
                    analysis.controlFlowFingerprintMemo = group.controlFlowFingerprintMemo
                }
                repairedSnapshot.analysisBySlot[slot] = analysis
            }
        }
        let analysisRepairs = WorkspaceAnalysisIntegrity.repair(&repairedSnapshot)
        try Task.checkCancellation()
        return WorkspacePackageContents(
            manifest: persistedManifest,
            snapshot: repairedSnapshot,
            attachmentsByBinaryID: attachmentsByBinaryID,
            instructionSidecarData: instructionSidecarData,
            session: manifest.session,
            reconstructionState: reconstructionState,
            reconstructionAttachmentSources: reconstructionAttachmentSources,
            logicalBreakpointCatalogAvailability: manifest.analysis?
                .logicalBreakpointCatalogAvailability ?? .available,
            launchProfileCatalogAvailability: manifest.analysis?
                .launchProfileCatalogAvailability ?? .available,
            analysisRepairs: analysisRepairs
        )
    }

    private static func decodedManifest(
        from data: Data
    ) throws -> (manifest: WorkspacePackageManifest, canonicalEncoding: Data?) {
        try Task.checkCancellation()
        // One linear byte pass yields the duplicate-key findings, strict JSON grammar and the
        // root key facts the v3 policy needs (formerly a full JSONSerialization parse).
        guard UInt64(data.count) <= maximumManifestBytes else {
            throw instructionStorageError("manifest exceeds byte limit")
        }
        let preflight = try WorkspacePackageDuplicateKeyPreflight.scan(data)
        try Task.checkCancellation()
        // Reader capabilities are checked before the closed typed codec, so a later reader can
        // explain an unsupported active-job feature without misreporting corrupt package JSON.
        if preflight.root?.keys.contains("requiredReaderFeatures") == true {
            guard !preflight.findings.anyObjectMember else {
                throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
            }
            struct ReaderFeatures: Decodable { let requiredReaderFeatures: [String] }
            let features = try JSONDecoder().decode(ReaderFeatures.self, from: data).requiredReaderFeatures
            try validateReaderFeatures(features)
        }
        let isStrict = try validateVersion3ManifestKeyPolicy(preflight)
        let decoder = manifestDecoder()
        decoder.userInfo[.workspacePackageDuplicateKeyFindings] = preflight.findings
        let manifest = try decoder.decode(WorkspacePackageManifest.self, from: data)
        try manifest.analystFindings?.validate(workspaceID: manifest.workspaceUUID, documentID: manifest.documentID)
        try Task.checkCancellation()
        var canonicalEncoding: Data?
        if isStrict {
            if manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion {
                guard let root = preflight.root,
                      version3RequiredManifestRootKeys.isSubset(of: root.keys),
                      version3RequiredManifestRootKeys.isDisjoint(with: root.nullValuedKeys) else {
                    throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
                }
            }
            canonicalEncoding = try validateVersion3ManifestKeyStructure(
                data,
                decodedManifest: manifest
            )
        }
        try Task.checkCancellation()
        return (manifest, canonicalEncoding)
    }

    private static func validateVersion3ManifestKeyPolicy(
        _ preflight: WorkspacePackageJSONPreflightResult
    ) throws -> Bool {
        try Task.checkCancellation()
        // Any v3/v4 spelling at the raw root selects strict duplicate-key admission, including
        // ambiguous duplicated formatVersion members before Foundation picks one value.
        guard let root = preflight.root else { return false }
        let versions = root.formatVersionTokens.compactMap { token -> Int? in
            (try? JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed) as? NSNumber)?.intValue
        }
        let isVersion4 = versions.contains(WorkspacePackageManifest.instructionSidecarFormatVersion)
        guard isVersion4 || versions.contains(WorkspacePackageManifest.reconstructionFormatVersion) else { return false }
        try Task.checkCancellation()
        guard !preflight.findings.anyObjectMember else {
            throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
        }
        var allowed: Set<String> = [
            "formatIdentifier",
            "formatVersion",
            "documentID",
            "workspaceUUID",
            "workspaceName",
            "createdAt",
            "modifiedAt",
            "inputCopyingDecision",
            "bookmarkResolutionDecision",
            "binaries",
            "analysis",
            "imageAnalyses",
            "session",
            "assistantSessionRecords",
            "runtimeAuthorityRecords",
            "reconstruction",
            "analyzer",
            "requiredReaderFeatures",
            "analystFindings",
            "navigatorState",
        ]
        var required = version3RequiredManifestRootKeys
        if isVersion4 {
            allowed.formUnion(["instructionSidecar", "reaEvidence"])
            required.subtract(["analysis", "imageAnalyses", "assistantSessionRecords", "runtimeAuthorityRecords", "reconstruction"])
            required.insert("instructionSidecar")
        }
        let observed = root.keys
        guard observed.isSubset(of: allowed), required.isSubset(of: observed),
              required.isDisjoint(with: root.nullValuedKeys) else {
            throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
        }
        return true
    }

    /// These roots encode v3's complete persisted workspace authority. They cannot use the
    /// decoder's legacy `decodeIfPresent` null-to-missing compatibility because accepting such a
    /// value would silently replace durable typed state with an in-memory default.
    private static let version3RequiredManifestRootKeys: Set<String> = [
        "formatIdentifier",
        "formatVersion",
        "documentID",
        "workspaceUUID",
        "workspaceName",
        "createdAt",
        "modifiedAt",
        "inputCopyingDecision",
        "bookmarkResolutionDecision",
        "binaries",
        "analysis",
        "imageAnalyses",
        "assistantSessionRecords",
        "runtimeAuthorityRecords",
        "reconstruction",
    ]

    /// A v3 manifest is a closed typed object graph. Foundation's synthesized `Codable`
    /// implementations deliberately ignore unknown members, so compare every decoded nested
    /// container with the structure emitted by the same typed value. Comparing key structure
    /// rather than scalar bytes preserves accepted date spellings and JSON formatting, while the
    /// encoder's existing omission rules keep writer-produced optional/default fields stable.
    /// Returns the canonical (writer) encoding of `decodedManifest`.
    private static func validateVersion3ManifestKeyStructure(
        _ data: Data,
        decodedManifest: WorkspacePackageManifest
    ) throws -> Data {
        try Task.checkCancellation()
        let normalizedData = try manifestEncoder().encode(decodedManifest)
        try Task.checkCancellation()
        // Writer-produced bytes re-encode identically: identical bytes have identical key
        // structure at every depth, so the object-graph comparison below cannot fail.
        if normalizedData == data { return normalizedData }
        guard let observed = try JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
        }
        try Task.checkCancellation()
        guard let normalized = try JSONSerialization.jsonObject(with: normalizedData)
            as? [String: Any] else {
            throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
        }
        try Task.checkCancellation()

        // Required v3 authority roots must survive a typed round trip. Optional roots retain
        // their established omission/null compatibility, but every materialized object is still
        // required to match the typed writer's emitted key set exactly.
        for key in observed.keys.sorted() {
            try Task.checkCancellation()
            guard let observedValue = observed[key] else {
                throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
            }
            if version3RequiredManifestRootKeys.contains(key) {
                guard !(observedValue is NSNull), let normalizedValue = normalized[key] else {
                    throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
                }
                try validateVersion3JSONKeyStructure(
                    observed: observedValue,
                    normalized: normalizedValue
                )
                continue
            }
            guard let normalizedValue = normalized[key] else { continue }
            try validateVersion3JSONKeyStructure(
                observed: observedValue,
                normalized: normalizedValue
            )
        }
        return normalizedData
    }

    private static func validateVersion3JSONKeyStructure(
        observed: Any,
        normalized: Any
    ) throws {
        try Task.checkCancellation()
        if let observedObject = observed as? [String: Any] {
            guard let normalizedObject = normalized as? [String: Any] else {
                throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
            }
            let observedKeys = Set(observedObject.keys)
            let normalizedKeys = Set(normalizedObject.keys)
            // A missing key is compatible only when decoding it produces a value that the writer
            // also omits. Core arrays and nonoptional state re-encode their keys, so exact
            // equality prevents a deletion from silently becoming an empty/default value.
            guard observedKeys == normalizedKeys else {
                throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
            }
            for key in observedKeys.sorted() {
                try Task.checkCancellation()
                guard let observedValue = observedObject[key],
                      let normalizedValue = normalizedObject[key] else {
                    throw ReconstructionPackageValidationError.noncanonicalManifest(
                        manifestFileName
                    )
                }
                try validateVersion3JSONKeyStructure(
                    observed: observedValue,
                    normalized: normalizedValue
                )
            }
            return
        }

        if let observedArray = observed as? [Any] {
            guard let normalizedArray = normalized as? [Any],
                  observedArray.count == normalizedArray.count else {
                throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
            }
            for (observedValue, normalizedValue) in zip(observedArray, normalizedArray) {
                try Task.checkCancellation()
                try validateVersion3JSONKeyStructure(
                    observed: observedValue,
                    normalized: normalizedValue
                )
            }
            return
        }

        guard !(normalized is [String: Any]), !(normalized is [Any]) else {
            throw ReconstructionPackageValidationError.noncanonicalManifest(manifestFileName)
        }
    }

    private static func validatedAttachmentPayloads(
        for manifest: WorkspacePackageManifest,
        attachmentsByBinaryID: [UUID: Data]
    ) throws -> [(binary: WorkspacePackageBinary, data: Data)] {
        try Task.checkCancellation()
        let binaryIDs = Set(manifest.binaries.map(\.id))
        try Task.checkCancellation()
        if let unknownAttachmentID = attachmentsByBinaryID.keys
            .filter({ !binaryIDs.contains($0) })
            .sorted(by: { $0.uuidString < $1.uuidString })
            .first {
            throw PackageError.unknownAttachmentBinaryID(unknownAttachmentID)
        }
        return try manifest.binaries.map { binary in
            try Task.checkCancellation()
            guard let attachmentData = attachmentsByBinaryID[binary.id] else {
                throw PackageError.missingAttachment(binary.attachmentRelativePath)
            }
            try validateAttachmentData(attachmentData, for: binary)
            return (binary: binary, data: attachmentData)
        }
    }

    private static func validatePersistedAnalysisBindings(
        for manifest: WorkspacePackageManifest,
        attachmentsByBinaryID: [UUID: Data]?
    ) throws {
        let fingerprintsByBinaryID: [UUID: AnalysisInputFingerprint]
        if manifest.analysisFormatVersion == WorkspacePackageManifest.currentFormatVersion {
            if let binary = manifest.binaries.min(by: {
                ($0.slot.rawValue, $0.id.uuidString) < ($1.slot.rawValue, $1.id.uuidString)
            }), let fingerprint = manifest.analysis?.analysisInputFingerprint {
                fingerprintsByBinaryID = [binary.id: fingerprint]
            } else {
                fingerprintsByBinaryID = [:]
            }
        } else {
            fingerprintsByBinaryID = Dictionary(uniqueKeysWithValues:
                (manifest.imageAnalyses ?? []).compactMap { record in
                    record.analysis.analysisInputFingerprint.map { (record.binaryID, $0) }
                }
            )
        }

        for binary in manifest.binaries {
            try Task.checkCancellation()
            guard let fingerprint = fingerprintsByBinaryID[binary.id] else { continue }
            guard fingerprint.elfArchiveMemberIdentity == binary.elfArchiveMemberIdentity else {
                throw PackageError.archiveMemberFingerprintMismatch(binary.id)
            }
            if let attachmentData = attachmentsByBinaryID?[binary.id],
               try !AnalysisFingerprintBuilder.persistedELFLoadMetadataMatchesFingerprint(
                attachmentData: attachmentData,
                persistedKind: binary.kind,
                metadata: binary.metadata ?? .empty,
                fingerprint: fingerprint
               ) {
                throw PackageError.binaryMetadataFingerprintMismatch(binary.id)
            }
        }
    }

    private static func validateReaderFeatures(_ features: [String]) throws {
        guard features.count <= 16, Set(features).count == features.count,
              features.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("invalid required reader features")
        }
        let unknown = features.filter {
            $0 != WorkspacePackageManifest.reconstructionReplayReaderFeature
                && $0 != WorkspacePackageManifest.analystFindingsReaderFeature
                && $0 != WorkspacePackageManifest.analystFindingHistoryReaderFeature
                && $0 != WorkspacePackageManifest.analystFindingCitationsReaderFeature
                && $0 != WorkspacePackageManifest.appendedExecutableCaveReaderFeature
                && $0 != WorkspacePackageManifest.navigatorStateReaderFeature
        }
        guard unknown.isEmpty else { throw UnsupportedReaderFeaturesError(features: unknown) }
    }

    /// `analyst.findings.v2` is declared only with findings present, and findings that cite facts or carry
    /// retract, stale or readmit operations always declare it. A package that predates the feature has
    /// neither, so it still validates; a package that declares it is refused by a build that does not know it.
    private static func analystFindingCitationsFeatureAgrees(_ manifest: WorkspacePackageManifest) -> Bool {
        let declared = manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingCitationsReaderFeature)
        if declared { return manifest.analystFindings.map { !$0.isEmpty } ?? false }
        return !(manifest.analystFindings?.usesV2Extensions ?? false)
    }

    static func validateManifest(
        _ manifest: WorkspacePackageManifest,
        in packageURL: URL,
        requireAttachments: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        try Task.checkCancellation()
        try manifest.analystFindings?.validate(workspaceID: manifest.workspaceUUID, documentID: manifest.documentID)
        try validateReaderFeatures(manifest.requiredReaderFeatures)
        guard manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingHistoryReaderFeature)
                == (manifest.analystFindings?.schemaVersion == 2) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("analyst finding history reader feature disagreement")
        }
        guard analystFindingCitationsFeatureAgrees(manifest) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("analyst finding v2 reader feature disagreement")
        }
        let authoredCaves = manifest.analysis?.addressOverrides.compactMap {
            $0.override.appendedExecutableCave
        } ?? []
        if !authoredCaves.isEmpty {
            guard manifest.requiredReaderFeatures.contains(
                WorkspacePackageManifest.appendedExecutableCaveReaderFeature
            ), authoredCaves.allSatisfy(\.isWellFormed) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "appended executable cave authoring is invalid or lacks reader authority"
                )
            }
        }
        guard manifest.formatIdentifier == formatIdentifier else {
            throw PackageError.invalidFormatIdentifier(manifest.formatIdentifier)
        }
        guard WorkspacePackageManifest.supportedFormatVersions.contains(manifest.formatVersion) else {
            throw PackageError.unsupportedFormatVersion(manifest.formatVersion)
        }
        try validateInstructionSidecarDescriptor(manifest)
        // HS-2: refuse a workspace from a newer analyzer, naming what this build lacks. Workspaces
        // without a stamp (written before stamping) or from this/an older analyzer load as before.
        if let analyzer = manifest.analyzer {
            let missing = analyzer.featuresMissing()
            guard missing.isEmpty else {
                throw PackageError.newerAnalyzerVersion(analyzer.version, missingFeatures: missing)
            }
        }
        if manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion {
            guard manifest.reconstruction != nil else {
                throw ReconstructionPackageValidationError.invalidDescriptor
            }
        } else if manifest.reconstruction != nil {
            throw ReconstructionPackageValidationError.invalidDescriptor
        }
        if manifest.analysisFormatVersion == WorkspacePackageManifest.currentFormatVersion,
           manifest.imageAnalyses != nil {
            throw PackageError.version1ContainsImageAnalyses
        }
        guard !manifest.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PackageError.emptyWorkspaceName
        }

        var seenBinaryIDs = Set<UUID>()
        var seenBinarySlots = Set<ImageSlot>()
        var validatedAttachmentsByBinaryID: [UUID: Data] = [:]
        for binary in manifest.binaries {
            try Task.checkCancellation()
            guard seenBinaryIDs.insert(binary.id).inserted else {
                throw PackageError.duplicateBinaryID(binary.id)
            }
            guard seenBinarySlots.insert(binary.slot).inserted else {
                throw PackageError.duplicateImageSlot(binary.slot)
            }

            let components = try attachmentPathComponents(binary.attachmentRelativePath)
            guard components.count == 3,
                  components[0] == attachmentsDirectoryName,
                  components[1] == binary.id.uuidString.lowercased() else {
                throw PackageError.invalidAttachmentRelativePath(binary.attachmentRelativePath)
            }
            if manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion,
               !isCanonicalSHA256(binary.fileHash) {
                throw PackageError.invalidAttachmentHash(binary.attachmentRelativePath)
            }
            if let archive = binary.elfArchiveMemberIdentity {
                guard BinaryImage.isValidArchiveMemberIdentity(archive),
                      binary.selectedSliceIndex == nil,
                      binary.machOSelectedSliceFact == nil else {
                    throw PackageError.invalidArchiveMemberIdentity(binary.id)
                }
                guard binary.fileSize == Int64(archive.member.byteCount),
                      binary.fileHash == archive.member.sha256 else {
                    throw PackageError.archiveMemberAttachmentMismatch(binary.id)
                }
            }
            if requireAttachments {
                let url = try attachmentURL(in: packageURL, relativePath: binary.attachmentRelativePath)
                guard fileManager.fileExists(atPath: url.path) else {
                    throw PackageError.missingAttachment(binary.attachmentRelativePath)
                }
                guard let maximumByteCount = Int(exactly: binary.fileSize),
                      maximumByteCount >= 0 else {
                    throw PackageError.attachmentSizeMismatch(
                        binary.attachmentRelativePath,
                        expected: binary.fileSize,
                        actual: -1
                    )
                }
                let data = try readRegularFile(
                    at: url,
                    relativeTo: packageURL,
                    maximumByteCount: maximumByteCount
                )
                try Task.checkCancellation()
                try validateAttachmentData(data, for: binary)
                validatedAttachmentsByBinaryID[binary.id] = data
            }
        }

        var seenAssistantRecordIDs = Set<UUID>()
        var seenAssistantSequences = Set<Int>()
        var seenAssistantConversationTurns = Set<String>()
        var seenAssistantInferenceTurnIDs = Set<UUID>()
        var seenAssistantContinuationAuthorityIDs = Set<UUID>()
        for record in manifest.assistantSessionRecords {
            try Task.checkCancellation()
            guard seenAssistantRecordIDs.insert(record.id).inserted else {
                throw PackageError.duplicateAssistantSessionID(record.id)
            }
            guard seenAssistantSequences.insert(record.sequence).inserted else {
                throw PackageError.duplicateAssistantSessionSequence(record.sequence)
            }
            guard (1...WorkspacePackageAssistantSessionRecord.schemaVersion).contains(record.recordSchemaVersion) else {
                throw PackageError.invalidAssistantSessionSchemaVersion(
                    record.id,
                    record.recordSchemaVersion
                )
            }
            guard WorkspacePackageAssistantSessionRecord.providerToolCountRange.contains(record.providerToolCount) else {
                throw PackageError.invalidAssistantSessionProviderToolCount(
                    record.id,
                    record.providerToolCount
                )
            }
            guard record.sequence > 0, record.turnSequence > 0 else {
                throw PackageError.invalidAssistantSessionSchemaVersion(record.id, record.recordSchemaVersion)
            }
            let conversationTurn = "\(record.conversationID.uuidString)#\(record.turnSequence)"
            guard seenAssistantConversationTurns.insert(conversationTurn).inserted else {
                throw PackageError.duplicateAssistantConversationTurn(record.conversationID, record.turnSequence)
            }
            guard seenAssistantInferenceTurnIDs.insert(record.inferenceTurnID).inserted else {
                throw PackageError.duplicateAssistantInferenceTurnID(record.inferenceTurnID)
            }
            if let checkpoint = record.continuationCheckpoint {
                guard checkpoint.isStructurallyValid(
                    workspaceID: manifest.workspaceUUID,
                    conversationID: record.conversationID,
                    inferenceTurnID: record.inferenceTurnID,
                    turnSequence: record.turnSequence
                ) else {
                    throw PackageError.invalidAssistantContinuationCheckpoint(record.id)
                }
                guard seenAssistantContinuationAuthorityIDs.insert(checkpoint.shellProposalID).inserted else {
                    throw PackageError.duplicateAssistantShellProposalID(checkpoint.shellProposalID)
                }
                if let id = checkpoint.shellExecutionID,
                   !seenAssistantContinuationAuthorityIDs.insert(id).inserted {
                    throw PackageError.duplicateAssistantShellExecutionID(id)
                }
                if let id = checkpoint.continuationRequestID,
                   !seenAssistantContinuationAuthorityIDs.insert(id).inserted {
                    throw PackageError.duplicateAssistantContinuationRequestID(id)
                }
            }
            let expectedHash = record.calculatedContentSHA256(
                workspaceUUID: manifest.workspaceUUID,
                documentID: manifest.documentID
            )
            guard expectedHash == record.contentSHA256 else {
                throw PackageError.invalidAssistantSessionContentHash(record.id)
            }
        }
        var seenRuntimeAuthorityRecordIDs = Set<UUID>()
        for record in manifest.runtimeAuthorityRecords {
            try Task.checkCancellation()
            guard seenRuntimeAuthorityRecordIDs.insert(record.id).inserted else {
                throw PackageError.duplicateRuntimeAuthorityRecordID(record.id)
            }
            guard record.recordSchemaVersion == WorkspacePackageRuntimeAuthorityRecord.schemaVersion else {
                throw PackageError.invalidRuntimeAuthorityRecordSchemaVersion(
                    record.id,
                    record.recordSchemaVersion
                )
            }
            guard record.authorityRecord.isStructurallyValid else {
                throw PackageError.invalidRuntimeAuthorityRecord(record.id)
            }
        }

        if manifest.analysisFormatVersion == WorkspacePackageManifest.multiImageFormatVersion
            || manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion {
            var binariesByID: [UUID: WorkspacePackageBinary] = [:]
            for binary in manifest.binaries {
                try Task.checkCancellation()
                binariesByID[binary.id] = binary
            }
            let imageAnalyses = manifest.imageAnalyses ?? []
            if manifest.analysis?.hasDerivedPayload == true {
                throw PackageError.version2TopLevelAnalysisContainsDerivedData
            }
            var seenAnalysisBinaryIDs = Set<UUID>()
            var seenAnalysisSlots = Set<ImageSlot>()
            for record in imageAnalyses {
                try Task.checkCancellation()
                guard seenAnalysisBinaryIDs.insert(record.binaryID).inserted else {
                    throw PackageError.duplicateImageAnalysisBinaryID(record.binaryID)
                }
                guard seenAnalysisSlots.insert(record.imageSlot).inserted else {
                    throw PackageError.duplicateImageAnalysisSlot(record.imageSlot)
                }
                guard let binary = binariesByID[record.binaryID] else {
                    throw PackageError.unknownImageAnalysisBinaryID(record.binaryID)
                }
                guard record.imageSlot == binary.slot else {
                    throw PackageError.imageAnalysisSlotMismatch(
                        binaryID: record.binaryID,
                        binarySlot: binary.slot,
                        analysisSlot: record.imageSlot
                    )
                }
                guard !record.analysis.hasAuthoringPayload else {
                    throw PackageError.version2ImageAnalysisContainsAuthoring(record.binaryID)
                }
            }
            for binary in manifest.binaries where !seenAnalysisBinaryIDs.contains(binary.id) {
                try Task.checkCancellation()
                throw PackageError.missingImageAnalysis(binary.id)
            }
        }

        // Binary identity and analysis provenance are independent persisted anchors. Always bind
        // archive-member identity. When attachments were admitted, also bind the persisted ELF
        // load metadata to the exact bytes that passed attachment validation.
        try validatePersistedAnalysisBindings(
            for: manifest,
            attachmentsByBinaryID: requireAttachments ? validatedAttachmentsByBinaryID : nil
        )
    }

    private static func validateAttachmentData(_ data: Data, for binary: WorkspacePackageBinary) throws {
        try Task.checkCancellation()
        let actualSize = Int64(data.count)
        guard binary.fileSize == actualSize else {
            throw PackageError.attachmentSizeMismatch(
                binary.attachmentRelativePath,
                expected: binary.fileSize,
                actual: actualSize
            )
        }

        guard !binary.fileHash.isEmpty else { return }
        let actualHash = fileHash(for: data)
        try Task.checkCancellation()
        guard binary.fileHash.lowercased() == actualHash else {
            throw PackageError.attachmentHashMismatch(
                binary.attachmentRelativePath,
                expected: binary.fileHash,
                actual: actualHash
            )
        }
        if let archive = binary.elfArchiveMemberIdentity,
           (archive.member.byteCount != data.count || archive.member.sha256 != actualHash) {
            throw PackageError.archiveMemberAttachmentMismatch(binary.id)
        }
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    static func reconstructionAttachmentURL(
        in packageURL: URL,
        contentIdentity: ReconstructionContentIdentity
    ) throws -> URL {
        let relativePath = try ReconstructionPackageLayout.attachmentPath(for: contentIdentity)
        return relativePath.split(separator: "/").reduce(packageURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    private static func preparedPackageManifest(
        _ original: WorkspacePackageManifest,
        reconstructionState: ReconstructionWorkspaceState,
        instructionSidecarData: Data? = nil
    ) throws -> (
        manifest: WorkspacePackageManifest,
        reconstruction: ReconstructionPackageEncodedManifests?
    ) {
        let reconstructionState = try reconstructionState.pruningTerminalReplayRecordsForSave()
        var manifest = original
        manifest.requiredReaderFeatures = reconstructionState.replayRecords == nil
            ? [] : [WorkspacePackageManifest.reconstructionReplayReaderFeature]
        try manifest.analystFindings?.validate(workspaceID: manifest.workspaceUUID, documentID: manifest.documentID)
        if manifest.analystFindings.map({ !$0.isEmpty }) == true {
            manifest.requiredReaderFeatures.append(WorkspacePackageManifest.analystFindingsReaderFeature)
            if manifest.analystFindings?.schemaVersion == 2 {
                manifest.requiredReaderFeatures.append(WorkspacePackageManifest.analystFindingHistoryReaderFeature)
            }
            manifest.requiredReaderFeatures.append(WorkspacePackageManifest.analystFindingCitationsReaderFeature)
        }
        if manifest.analysis?.addressOverrides.contains(where: {
            $0.override.appendedExecutableCave != nil
        }) == true {
            manifest.requiredReaderFeatures.append(WorkspacePackageManifest.appendedExecutableCaveReaderFeature)
        }
        if manifest.navigatorState.map({ !$0.isEmpty }) == true {
            manifest.requiredReaderFeatures.append(WorkspacePackageManifest.navigatorStateReaderFeature)
        } else {
            manifest.navigatorState = nil
        }
        if manifest.formatVersion == WorkspacePackageManifest.instructionSidecarFormatVersion {
            try validateInstructionSidecarDescriptor(manifest)
            let encoded = reconstructionState == .empty ? nil : try ReconstructionPackageCodec.encode(reconstructionState)
            if encoded?.descriptor == manifest.reconstruction {
                return (manifest, encoded)
            }
            // Reconstruction promotion/collapse changes ownership layout. Restore the exact
            // rows before applying the existing migration, then encode a newly bound sidecar.
            manifest = try manifestByRestoringInstructions(manifest, instructionSidecarData: instructionSidecarData)
            manifest.formatVersion = manifest.analysisFormatVersion
            manifest.instructionSidecar = nil
        }
        let needsPerImageAnalysis = manifest.binaries.count > 1
            || manifest.binaries.contains { $0.slot != .primary }
        guard reconstructionState != .empty else {
            manifest.reconstruction = nil
            if needsPerImageAnalysis {
                try promoteManifestToPerImageAnalysis(&manifest)
                manifest.formatVersion = WorkspacePackageManifest.multiImageFormatVersion
            } else {
                try collapseManifestToVersion1(&manifest)
                manifest.formatVersion = WorkspacePackageManifest.currentFormatVersion
            }
            return (manifest, nil)
        }

        let encoded = try ReconstructionPackageCodec.encode(reconstructionState)
        try promoteManifestToPerImageAnalysis(&manifest)
        manifest.analysis = manifest.analysis ?? WorkspacePackageAnalysis()
        manifest.formatVersion = WorkspacePackageManifest.reconstructionFormatVersion
        manifest.reconstruction = encoded.descriptor
        return (manifest, encoded)
    }

    private static func promoteManifestToPerImageAnalysis(
        _ manifest: inout WorkspacePackageManifest
    ) throws {
        if manifest.analysisFormatVersion == WorkspacePackageManifest.currentFormatVersion {
            let legacy = manifest.analysis ?? WorkspacePackageAnalysis()
            manifest.analysis = authoringAnalysis(from: legacy)
            var imageAnalyses: [WorkspacePackageImageAnalysis] = []
            imageAnalyses.reserveCapacity(manifest.binaries.count)
            for (index, binary) in manifest.binaries.enumerated() {
                try Task.checkCancellation()
                imageAnalyses.append(WorkspacePackageImageAnalysis(
                    binaryID: binary.id,
                    imageSlot: binary.slot,
                    analysis: index == 0 ? derivedAnalysis(from: legacy) : WorkspacePackageAnalysis()
                ))
            }
            manifest.imageAnalyses = imageAnalyses
        }
        guard manifest.imageAnalyses != nil else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "per-image package has no image analyses"
            )
        }
    }

    private static func collapseManifestToVersion1(
        _ manifest: inout WorkspacePackageManifest
    ) throws {
        guard manifest.binaries.count <= 1,
              manifest.binaries.allSatisfy({ $0.slot == .primary }) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "multi-image package cannot collapse to v1"
            )
        }
        if manifest.analysisFormatVersion != WorkspacePackageManifest.currentFormatVersion {
            let authoring = manifest.analysis ?? WorkspacePackageAnalysis()
            let derived = manifest.imageAnalyses?.first?.analysis ?? WorkspacePackageAnalysis()
            manifest.analysis = combinedAnalysis(authoring: authoring, derived: derived)
        }
        manifest.imageAnalyses = nil
    }

    private static func derivedAnalysis(
        from analysis: WorkspacePackageAnalysis
    ) -> WorkspacePackageAnalysis {
        WorkspacePackageAnalysis(
            functions: analysis.functions,
            symbols: analysis.symbols,
            imports: analysis.imports,
            indirectSymbols: analysis.indirectSymbols,
            exports: analysis.exports,
            stringLiterals: analysis.stringLiterals,
            constantCFStrings: analysis.constantCFStrings,
            basicBlocks: analysis.basicBlocks,
            instructions: analysis.instructions,
            xrefs: analysis.xrefs,
            controlFlowEdges: analysis.controlFlowEdges,
            sourceLines: analysis.sourceLines,
            analysisInputFingerprint: analysis.analysisInputFingerprint
        )
    }

    private static func authoringAnalysis(
        from analysis: WorkspacePackageAnalysis
    ) -> WorkspacePackageAnalysis {
        WorkspacePackageAnalysis(
            addressOverrides: analysis.addressOverrides,
            importedPrototypes: analysis.importedPrototypes,
            typeDefinitions: analysis.typeDefinitions,
            manualXRefs: analysis.manualXRefs,
            bookmarks: analysis.bookmarks,
            segmentOverrides: analysis.segmentOverrides,
            logicalBreakpointCatalog: analysis.logicalBreakpointCatalog,
            logicalBreakpointCatalogAvailability: analysis.logicalBreakpointCatalogAvailability,
            launchProfileCatalog: analysis.launchProfileCatalog,
            launchProfileCatalogAvailability: analysis.launchProfileCatalogAvailability,
            savedWatchCatalog: analysis.savedWatchCatalog,
            sourceLinkState: analysis.sourceLinkState
        )
    }

    private static func combinedAnalysis(
        authoring: WorkspacePackageAnalysis,
        derived: WorkspacePackageAnalysis
    ) -> WorkspacePackageAnalysis {
        WorkspacePackageAnalysis(
            functions: derived.functions,
            symbols: derived.symbols,
            imports: derived.imports,
            indirectSymbols: derived.indirectSymbols,
            exports: derived.exports,
            stringLiterals: derived.stringLiterals,
            constantCFStrings: derived.constantCFStrings,
            basicBlocks: derived.basicBlocks,
            instructions: derived.instructions,
            xrefs: derived.xrefs,
            controlFlowEdges: derived.controlFlowEdges,
            sourceLines: derived.sourceLines,
            analysisInputFingerprint: derived.analysisInputFingerprint,
            addressOverrides: authoring.addressOverrides,
            importedPrototypes: authoring.importedPrototypes,
            typeDefinitions: authoring.typeDefinitions,
            manualXRefs: authoring.manualXRefs,
            bookmarks: authoring.bookmarks,
            segmentOverrides: authoring.segmentOverrides,
            logicalBreakpointCatalog: authoring.logicalBreakpointCatalog,
            logicalBreakpointCatalogAvailability: authoring.logicalBreakpointCatalogAvailability,
            launchProfileCatalog: authoring.launchProfileCatalog,
            launchProfileCatalogAvailability: authoring.launchProfileCatalogAvailability,
            savedWatchCatalog: authoring.savedWatchCatalog,
            sourceLinkState: authoring.sourceLinkState
        )
    }

    private static func writeReconstructionPackage(
        _ encoded: ReconstructionPackageEncodedManifests,
        sources: [ReconstructionAttachmentSource],
        to packageURL: URL,
        fileManager: FileManager
    ) throws {
        try Task.checkCancellation()
        var expectedByDigest: [String: ReconstructionContentIdentity] = [:]
        for content in encoded.contents {
            try Task.checkCancellation()
            guard expectedByDigest.updateValue(
                content.contentIdentity,
                forKey: content.contentIdentity.digest
            ) == nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "duplicate encoded content identity"
                )
            }
        }
        var sourceByDigest: [String: ReconstructionAttachmentSource] = [:]
        for source in sources {
            try Task.checkCancellation()
            guard expectedByDigest[source.contentIdentity.digest] == source.contentIdentity,
                  sourceByDigest.updateValue(source, forKey: source.contentIdentity.digest) == nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "attachment source catalog disagreement"
                )
            }
        }
        guard sourceByDigest.count == expectedByDigest.count else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "attachment source catalog incomplete"
            )
        }

        let reconstructionRoot = packageURL.appendingPathComponent(
            ReconstructionPackageLayout.rootDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: reconstructionRoot,
            withIntermediateDirectories: true
        )
        for content in encoded.contents {
            try Task.checkCancellation()
            guard let source = sourceByDigest[content.contentIdentity.digest] else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "attachment source missing"
                )
            }
            let destination = try reconstructionAttachmentURL(
                in: packageURL,
                contentIdentity: content.contentIdentity
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try streamVerifiedRegularFile(
                from: source,
                to: destination,
                expected: content.contentIdentity
            )
            try Task.checkCancellation()
        }

        for (relativePath, data) in [
            (ReconstructionPackageLayout.corpusManifestPath, encoded.corpusData),
            (ReconstructionPackageLayout.evidenceManifestPath, encoded.evidenceData),
            (ReconstructionPackageLayout.checkpointManifestPath, encoded.checkpointData),
        ] {
            try Task.checkCancellation()
            let url = relativePath.split(separator: "/").reduce(packageURL) { url, component in
                url.appendingPathComponent(String(component), isDirectory: false)
            }
            try data.write(to: url, options: [.atomic])
            try Task.checkCancellation()
            try synchronizeFile(at: url)
        }
    }

    private static func readReconstructionPackage(
        descriptor: ReconstructionPackageDescriptor?,
        from packageURL: URL,
        fileManager: FileManager
    ) throws -> (
        state: ReconstructionWorkspaceState,
        sources: [ReconstructionAttachmentSource]
    ) {
        try Task.checkCancellation()
        guard let descriptor else {
            throw ReconstructionPackageValidationError.invalidDescriptor
        }
        // The caller-selected package root is the trust boundary. Resolve that
        // boundary once (macOS commonly supplies /var as an alias of
        // /private/var), then reject every alias below it with retained-fd
        // descriptor-relative traversal.
        let trustedPackageURL = try resolvedTrustRoot(packageURL)
        let corpusData = try readRegularFile(
            at: trustedPackageURL.appendingPathComponent(descriptor.corpusManifestPath),
            relativeTo: trustedPackageURL,
            maximumByteCount: ReconstructionPackageLayout.maximumManifestBytes
        )
        try Task.checkCancellation()
        let evidenceData = try readRegularFile(
            at: trustedPackageURL.appendingPathComponent(descriptor.evidenceManifestPath),
            relativeTo: trustedPackageURL,
            maximumByteCount: ReconstructionPackageLayout.maximumManifestBytes
        )
        try Task.checkCancellation()
        let checkpointData = try readRegularFile(
            at: trustedPackageURL.appendingPathComponent(descriptor.checkpointManifestPath),
            relativeTo: trustedPackageURL,
            maximumByteCount: ReconstructionPackageLayout.maximumManifestBytes
        )
        try Task.checkCancellation()
        let state = try ReconstructionPackageCodec.decode(
            descriptor: descriptor,
            corpusData: corpusData,
            evidenceData: evidenceData,
            checkpointData: checkpointData
        )
        guard state != .empty else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "package v3 contains no reconstruction state"
            )
        }
        let contents = try ReconstructionPackageCodec.contentRecords(in: state)
        var sources: [ReconstructionAttachmentSource] = []
        for content in contents {
            try Task.checkCancellation()
            let url = try reconstructionAttachmentURL(
                in: trustedPackageURL,
                contentIdentity: content.contentIdentity
            )
            try verifyRegularFile(
                at: url,
                relativeTo: trustedPackageURL,
                expected: content.contentIdentity
            )
            sources.append(
                ReconstructionAttachmentSource(
                    contentIdentity: content.contentIdentity,
                    verifiedURL: url
                )
            )
        }
        try Task.checkCancellation()
        try validateReconstructionInventory(
            at: trustedPackageURL,
            expectedContents: contents,
            fileManager: fileManager
        )
        return (state, sources)
    }

    private static func validateReconstructionInventory(
        at packageURL: URL,
        expectedContents: [ReconstructionPackageContentRecord],
        fileManager: FileManager
    ) throws {
        try Task.checkCancellation()
        var expectedFiles = Set<String>()
        for content in expectedContents {
            try Task.checkCancellation()
            expectedFiles.insert(content.attachmentPath)
        }
        expectedFiles.formUnion([
            ReconstructionPackageLayout.corpusManifestPath,
            ReconstructionPackageLayout.evidenceManifestPath,
            ReconstructionPackageLayout.checkpointManifestPath,
        ])
        var expectedDirectories = Set<String>()
        for path in expectedFiles {
            try Task.checkCancellation()
            let components = path.split(separator: "/").map(String.init)
            for componentCount in 1..<components.count {
                try Task.checkCancellation()
                expectedDirectories.insert(
                    components.prefix(componentCount).joined(separator: "/")
                )
            }
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("package inventory")
        }
        var observed = Set<String>()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let relative = url.path.replacingOccurrences(
                of: packageURL.path + "/",
                with: "",
                options: [.anchored]
            )
            let reconstructionPrefix = ReconstructionPackageLayout.rootDirectoryName + "/"
            let looksLikeReconstruction = relative.lowercased()
                .hasPrefix(ReconstructionPackageLayout.rootDirectoryName.lowercased())
            guard !looksLikeReconstruction
                    || relative == ReconstructionPackageLayout.rootDirectoryName
                    || relative.hasPrefix(reconstructionPrefix) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "wrong-case reconstruction path"
                )
            }
            guard relative == ReconstructionPackageLayout.rootDirectoryName
                    || relative.hasPrefix(reconstructionPrefix) else { continue }
            guard expectedFiles.contains(relative) || expectedDirectories.contains(relative) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "unreferenced reconstruction object"
                )
            }
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            let hasExpectedType = expectedDirectories.contains(relative)
                ? values.isDirectory == true
                : values.isRegularFile == true
            guard values.isSymbolicLink != true, hasExpectedType else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "nonregular reconstruction object"
                )
            }
            observed.insert(relative)
        }
        guard enumerationError == nil,
              observed == expectedFiles.union(expectedDirectories) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "incomplete reconstruction inventory"
            )
        }
        try Task.checkCancellation()
    }

    private static func streamVerifiedRegularFile(
        from source: ReconstructionAttachmentSource,
        to destinationURL: URL,
        expected: ReconstructionContentIdentity
    ) throws {
        try Task.checkCancellation()
        guard source.contentIdentity == expected else {
            throw ReconstructionPackageValidationError.contentIdentityConflict(expected.digest)
        }
        let sourceFD: Int32
        if source.hasDescriptorAuthority {
            sourceFD = try source.openVerifiedDescriptor()
            guard sourceFD >= 0 else {
                throw ReconstructionPackageValidationError.contentIdentityConflict(expected.digest)
            }
        } else {
            let packageRoot = try reconstructionPackageRoot(
                containing: source.verifiedURL,
                expected: expected
            )
            sourceFD = try openRegularFileWithoutFollowingSymlinks(
                at: source.verifiedURL,
                relativeTo: packageRoot
            )
        }
        defer { Darwin.close(sourceFD) }
        let before = try verifiedStatus(fd: sourceFD, expected: expected)
        let destinationFD = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IRGRP | S_IROTH
        )
        guard destinationFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var succeeded = false
        defer {
            Darwin.close(destinationFD)
            if !succeeded { try? FileManager.default.removeItem(at: destinationURL) }
        }

        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let remaining = expected.byteCount >= total ? expected.byteCount - total : 0
            let requested = min(buffer.count, Int(min(remaining + 1, UInt64(buffer.count))))
            let count = Darwin.read(sourceFD, &buffer, requested)
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            total += UInt64(count)
            guard total <= expected.byteCount else {
                throw ReconstructionPackageValidationError.contentIdentityConflict(expected.digest)
            }
            let chunk = Data(buffer.prefix(count))
            hasher.update(data: chunk)
            var written = 0
            while written < count {
                try Task.checkCancellation()
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationFD,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
            guard written == count else {
                throw POSIXError(.EIO)
            }
        }
        var after = stat()
        guard Darwin.fstat(sourceFD, &after) == 0,
              stableStatus(before, after),
              total == expected.byteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined()
                == expected.digest,
              Darwin.fsync(destinationFD) == 0 else {
            throw ReconstructionPackageValidationError.contentIdentityConflict(expected.digest)
        }
        try Task.checkCancellation()
        succeeded = true
    }

    private static func reconstructionPackageRoot(
        containing sourceURL: URL,
        expected: ReconstructionContentIdentity
    ) throws -> URL? {
        let expectedComponents = try ReconstructionPackageLayout
            .attachmentPath(for: expected)
            .split(separator: "/")
            .map(String.init)
        let sourceComponents = sourceURL.standardizedFileURL.pathComponents
        guard sourceComponents.count > expectedComponents.count,
              Array(sourceComponents.suffix(expectedComponents.count)) == expectedComponents else {
            return nil
        }
        let root = expectedComponents.reduce(sourceURL.standardizedFileURL) { root, _ in
            root.deletingLastPathComponent()
        }
        return try resolvedTrustRoot(root)
    }

    private static func verifyRegularFile(
        at url: URL,
        relativeTo trustedRoot: URL,
        expected: ReconstructionContentIdentity
    ) throws {
        try Task.checkCancellation()
        let fd = try openRegularFileWithoutFollowingSymlinks(
            at: url,
            relativeTo: trustedRoot
        )
        defer { Darwin.close(fd) }
        let before = try verifiedStatus(fd: fd, expected: expected)
        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let remaining = expected.byteCount >= total ? expected.byteCount - total : 0
            let requested = min(buffer.count, Int(min(remaining + 1, UInt64(buffer.count))))
            let count = Darwin.read(fd, &buffer, requested)
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            total += UInt64(count)
            guard total <= expected.byteCount else {
                throw ReconstructionPackageValidationError.contentIdentityConflict(expected.digest)
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0,
              stableStatus(before, after),
              total == expected.byteCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined()
                == expected.digest else {
            throw ReconstructionPackageValidationError.contentIdentityConflict(expected.digest)
        }
        try Task.checkCancellation()
    }

    private static func verifiedStatus(
        fd: Int32,
        expected: ReconstructionContentIdentity
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(fd, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0,
              UInt64(status.st_size) == expected.byteCount,
              expected.byteCount <= ReconstructionPackageLayout.maximumCorpusAttachmentBytes else {
            throw ReconstructionPackageValidationError.contentIdentityConflict(expected.digest)
        }
        return status
    }

    static func readRegularFile(
        at url: URL,
        relativeTo trustedRoot: URL,
        maximumByteCount: Int? = nil
    ) throws -> Data {
        try Task.checkCancellation()
        let fd = try openRegularFileWithoutFollowingSymlinks(
            at: url,
            relativeTo: trustedRoot
        )
        defer { Darwin.close(fd) }
        var before = stat()
        guard Darwin.fstat(fd, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              let observedByteCount = Int(exactly: before.st_size) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("manifest file type")
        }
        if let maximumByteCount,
           observedByteCount > maximumByteCount {
            throw ReconstructionPackageValidationError.stateGraphInvalid("manifest file type")
        }
        var result = Data()
        result.reserveCapacity(observedByteCount)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let requested: Int
            if let maximumByteCount {
                let remaining = maximumByteCount - result.count
                requested = remaining < buffer.count ? remaining + 1 : buffer.count
            } else {
                requested = buffer.count
            }
            let count = Darwin.read(fd, &buffer, requested)
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            if let maximumByteCount,
               result.count + count > maximumByteCount {
                throw ReconstructionPackageValidationError.stateGraphInvalid("manifest exceeds byte limit")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0,
              stableStatus(before, after),
              UInt64(result.count) == UInt64(after.st_size) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "manifest changed during read"
            )
        }
        try Task.checkCancellation()
        return result
    }

    private static func openRegularFileWithoutFollowingSymlinks(
        at url: URL,
        relativeTo trustedRoot: URL? = nil
    ) throws -> Int32 {
        try Task.checkCancellation()
        guard url.isFileURL else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("non-file attachment URL")
        }
        let baseURL: URL
        let components: [String]
        if let trustedRoot {
            baseURL = trustedRoot.standardizedFileURL
            let basePath = baseURL.path.hasSuffix("/")
                ? String(baseURL.path.dropLast())
                : baseURL.path
            let candidatePath = url.standardizedFileURL.path
            let prefix = basePath + "/"
            guard candidatePath.hasPrefix(prefix) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "attachment escapes trusted root"
                )
            }
            components = candidatePath.dropFirst(prefix.count).split(separator: "/").map(String.init)
        } else {
            // An authored or previously verified external source may sit below
            // a legitimate system alias such as /var. Resolve only its
            // caller-selected parent; the final leaf remains no-follow and is
            // revalidated by size, link count, stable metadata, and digest.
            baseURL = try resolvedTrustRoot(url.deletingLastPathComponent())
            components = [url.lastPathComponent]
        }
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("invalid attachment URL")
        }
        var parent = Darwin.open(
            baseURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for component in components.dropLast() {
            try Task.checkCancellation()
            let child = component.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard child >= 0 else {
                let savedErrno = errno
                Darwin.close(parent)
                throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
            }
            Darwin.close(parent)
            parent = child
        }
        let descriptor = components.last!.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        let savedErrno = errno
        Darwin.close(parent)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
        return descriptor
    }

    private static func resolvedTrustRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "non-file trust root"
            )
        }
        errno = 0
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return URL(
            fileURLWithPath: String(cString: resolved),
            isDirectory: true
        )
    }

    private static func stableStatus(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func synchronizeFile(at url: URL) throws {
        try Task.checkCancellation()
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try Task.checkCancellation()
    }

    private static func synchronizeDirectory(
        at url: URL,
        checkingCancellation: Bool = true
    ) throws {
        if checkingCancellation { try Task.checkCancellation() }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if checkingCancellation { try Task.checkCancellation() }
    }

    private static func synchronizePackageDirectories(
        at packageURL: URL,
        observer: ((URL) -> Void)?
    ) throws {
        try Task.checkCancellation()
        var directories = [packageURL]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "staged package directory inventory"
            )
        }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { directories.append(url) }
        }
        guard enumerationError == nil else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "staged package directory inventory"
            )
        }
        directories.sort {
            ($0.pathComponents.count, $0.path) > ($1.pathComponents.count, $1.path)
        }
        for directory in directories {
            try Task.checkCancellation()
            try synchronizeDirectory(at: directory)
            observer?(directory)
            try Task.checkCancellation()
        }
    }

    private static func temporaryReplacementURL(for packageURL: URL) -> URL {
        let baseName = packageURL.lastPathComponent.isEmpty ? "MacScopePackage" : packageURL.lastPathComponent
        return packageURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(baseName).\(UUID().uuidString).tmp", isDirectory: true)
    }

    private static func publishStagedPackage(
        at packageURL: URL,
        stagedAt temporaryPackageURL: URL,
        fileManager: FileManager,
        testHooks: PackageWriteTestHooks?
    ) throws {
        let parent = packageURL.deletingLastPathComponent()
        try WorkspacePackageNamespaceCoordinator.coordinate(
            stagedAt: temporaryPackageURL,
            destination: packageURL
        ) { coordinatedStageURL, coordinatedDestinationURL in
            guard let stagedIdentity = try WorkspacePackageNamespaceCoordinator
                .fileObjectIdentity(at: coordinatedStageURL) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "package publication staged root absent"
                )
            }
            let priorDestinationIdentity = try WorkspacePackageNamespaceCoordinator
                .fileObjectIdentity(at: coordinatedDestinationURL)
            let replacingExisting = priorDestinationIdentity != nil
            try Task.checkCancellation()
            try atomicRename(
                from: coordinatedStageURL,
                to: coordinatedDestinationURL,
                flags: replacingExisting ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
            )
            do {
                guard try WorkspacePackageNamespaceCoordinator.fileObjectIdentity(
                    at: coordinatedDestinationURL
                ) == stagedIdentity else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "package publication postcondition failed"
                    )
                }
                if let hook = testHooks?.beforeDestinationParentSynchronization {
                    try hook()
                }
                try synchronizeDirectory(at: parent)
            } catch {
                var rollbackRenameSucceeded = false
                do {
                    if let hook = testHooks?.beforePublicationRollbackRename {
                        try hook()
                    }
                    if replacingExisting {
                        try atomicRename(
                            from: coordinatedStageURL,
                            to: coordinatedDestinationURL,
                            flags: UInt32(RENAME_SWAP)
                        )
                    } else {
                        try atomicRename(
                            from: coordinatedDestinationURL,
                            to: coordinatedStageURL,
                            flags: UInt32(RENAME_EXCL)
                        )
                    }
                    rollbackRenameSucceeded = true
                    if let hook = testHooks?.beforePublicationRollbackParentSynchronization {
                        try hook()
                    }
                    try synchronizeDirectory(at: parent, checkingCancellation: false)
                } catch {
                    if replacingExisting {
                        throw PackageError.packagePublicationRollbackFailed(
                            recoveryURL: rollbackRenameSucceeded
                                ? coordinatedDestinationURL
                                : coordinatedStageURL
                        )
                    }
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "package publication rollback failed"
                    )
                }

                do {
                    guard try WorkspacePackageNamespaceCoordinator.fileObjectIdentity(
                        at: coordinatedStageURL
                    ) == stagedIdentity else {
                        throw PackageError.packagePublicationCleanupOwnershipUnproven(
                            recoveryURL: coordinatedStageURL
                        )
                    }
                    try fileManager.removeItem(at: coordinatedStageURL)
                    try? synchronizeDirectory(at: parent, checkingCancellation: false)
                } catch let cleanupError as PackageError {
                    throw cleanupError
                } catch {
                    throw PackageError.packagePublicationCleanupOwnershipUnproven(
                        recoveryURL: coordinatedStageURL
                    )
                }
                throw error
            }
            guard replacingExisting else { return }

            do {
                if let hook = testHooks?.beforeRetiredPackageCleanup {
                    try hook()
                }
                guard try WorkspacePackageNamespaceCoordinator.fileObjectIdentity(
                    at: coordinatedStageURL
                ) == priorDestinationIdentity else {
                    throw PackageError.packagePublicationCleanupOwnershipUnproven(
                        recoveryURL: coordinatedStageURL
                    )
                }
                try fileManager.removeItem(at: coordinatedStageURL)
                try? synchronizeDirectory(at: parent)
            } catch let error as PackageError {
                throw error
            } catch {
                throw PackageError.packagePublicationCleanupOwnershipUnproven(
                    recoveryURL: coordinatedStageURL
                )
            }
        }
    }

    private static func atomicRename(
        from sourceURL: URL,
        to destinationURL: URL,
        flags: UInt32
    ) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { source in
            destinationURL.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return Darwin.renameatx_np(
                    AT_FDCWD,
                    source,
                    AT_FDCWD,
                    destination,
                    flags
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func manifestEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(manifestDateFormatter().string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func manifestDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = manifestDateFormatter().date(from: value) ?? fallbackManifestDateFormatter().date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid package manifest date: \(value)"
                )
            }
            return date
        }
        return decoder
    }

    private static func manifestDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func fallbackManifestDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func sanitizedFileName(from fileName: String, fallbackID: UUID) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "input-\(fallbackID.uuidString.lowercased()).bin"
        let candidate = (trimmed.isEmpty || trimmed == "." || trimmed == "..") ? fallback : trimmed
        let sanitized = candidate.unicodeScalars.map { scalar in
            if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                return "_"
            }
            return String(scalar)
        }.joined()
        return sanitized.isEmpty ? fallback : sanitized
    }

    private static func attachmentPathComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~") else {
            throw PackageError.invalidAttachmentRelativePath(relativePath)
        }

        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PackageError.invalidAttachmentRelativePath(relativePath)
        }
        guard components.first == attachmentsDirectoryName else {
            throw PackageError.invalidAttachmentRelativePath(relativePath)
        }

        return components
    }
}
