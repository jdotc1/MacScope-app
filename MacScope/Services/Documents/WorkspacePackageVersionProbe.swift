import CryptoKit
import Darwin
import Foundation

protocol WorkspacePackageVersionProbing: Sendable {
    func observe(_ url: URL) async throws -> WorkspacePackageExternalVersion
}

struct WorkspacePackageVersionProbe: WorkspacePackageVersionProbing {
    typealias ReadCheckpoint = @Sendable (String) -> Void

    struct Limits: Sendable {
        let maximumManifestCaptureBytes: UInt64
        let maximumInstructionSidecarCaptureBytes: UInt64
        let maximumAttachmentCaptureBytes: UInt64
        let maximumTotalAttachmentCaptureBytes: UInt64
        let maximumTreeEntryCount: Int
        let maximumTreeNameBytes: Int

        init(
            maximumManifestCaptureBytes: UInt64 = MacScopeDocumentPackage.maximumManifestBytes,
            maximumInstructionSidecarCaptureBytes: UInt64 = WorkspaceInstructionSidecarCodec.maximumBytes,
            maximumAttachmentCaptureBytes: UInt64 = ReconstructionPackageLayout
                .maximumCorpusAttachmentBytes,
            maximumTotalAttachmentCaptureBytes: UInt64 = ReconstructionPackageLayout
                .maximumCorpusAttachmentBytes,
            maximumTreeEntryCount: Int = 100_000,
            maximumTreeNameBytes: Int = 16 * 1_024 * 1_024
        ) {
            self.maximumManifestCaptureBytes = maximumManifestCaptureBytes
            self.maximumInstructionSidecarCaptureBytes = maximumInstructionSidecarCaptureBytes
            self.maximumAttachmentCaptureBytes = maximumAttachmentCaptureBytes
            self.maximumTotalAttachmentCaptureBytes = maximumTotalAttachmentCaptureBytes
            self.maximumTreeEntryCount = maximumTreeEntryCount
            self.maximumTreeNameBytes = maximumTreeNameBytes
        }
    }

    private static let observationDomain =
        "org.macscope.workspace-package-observation.v1"
    private let limits: Limits
    private let beforeReadingRelativePath: ReadCheckpoint?
    private let beforeCancellableWork: ReadCheckpoint?
    private let beforeTreeSnapshot: (@Sendable () -> Void)?
    private let didBuildTreeIndex: (@Sendable (Int) -> Void)?
    private let didUseTreeIndex: ReadCheckpoint?

    init(
        limits: Limits = Limits(),
        beforeReadingRelativePath: ReadCheckpoint? = nil,
        beforeCancellableWork: ReadCheckpoint? = nil,
        beforeTreeSnapshot: (@Sendable () -> Void)? = nil,
        didBuildTreeIndex: (@Sendable (Int) -> Void)? = nil,
        didUseTreeIndex: ReadCheckpoint? = nil
    ) {
        self.limits = limits
        self.beforeReadingRelativePath = beforeReadingRelativePath
        self.beforeCancellableWork = beforeCancellableWork
        self.beforeTreeSnapshot = beforeTreeSnapshot
        self.didBuildTreeIndex = didBuildTreeIndex
        self.didUseTreeIndex = didUseTreeIndex
    }

    func observe(_ url: URL) async throws -> WorkspacePackageExternalVersion {
        try observeSynchronously(url)
    }

    /// `NSFileCoordinator` accessors are synchronous. Publication uses this identical body so the
    /// final destination comparison is made while coordinated write access is still held rather
    /// than before or after the protected transaction.
    func observeSynchronously(_ url: URL) throws -> WorkspacePackageExternalVersion {
        // One decode of the manifest bytes serves both the manifest gate and the content
        // validation below (and an enclosing save/open operation's scope, when installed).
        try WorkspaceManifestDecodeScope.ensuring { _ in
            try observeInDecodeScope(url)
        }
    }

    private func observeInDecodeScope(_ url: URL) throws -> WorkspacePackageExternalVersion {
        try Task.checkCancellation()
        let location = try WorkspaceDocumentLocation.canonicalized(from: url)
        guard let expectedRootIdentity = location.fileObjectIdentity else {
            return absentObservation(at: location)
        }

        do {
            let initialTree = try treeSnapshot(at: location.canonicalURL)
            guard initialTree.root.metadata.objectIdentity == expectedRootIdentity else {
                return unverifiableObservation(
                    at: location,
                    reason: "package-root-changed-before-observation"
                )
            }
            guard initialTree.root.kind == .directory else {
                return try invalidAfterStableRecheck(
                    at: location,
                    initialTree: initialTree,
                    manifestData: nil,
                    fileEvidence: [],
                    reason: "package-root-not-directory"
                )
            }
            if initialTree.entries.contains(where: { $0.kind == .symbolicLink }) {
                return try invalidAfterStableRecheck(
                    at: location,
                    initialTree: initialTree,
                    manifestData: nil,
                    fileEvidence: [],
                    reason: "package-symbolic-link-unsupported"
                )
            }
            if initialTree.entries.contains(where: { $0.kind == .special }) {
                return try invalidAfterStableRecheck(
                    at: location,
                    initialTree: initialTree,
                    manifestData: nil,
                    fileEvidence: [],
                    reason: "package-special-file-unsupported"
                )
            }

            guard let manifestEntry = treeEntry(
                named: MacScopeDocumentPackage.manifestFileName,
                in: initialTree
            ), manifestEntry.kind == .regularFile else {
                return try invalidAfterStableRecheck(
                    at: location,
                    initialTree: initialTree,
                    manifestData: nil,
                    fileEvidence: [],
                    reason: "package-manifest-not-regular-file"
                )
            }
            guard manifestEntry.metadata.size >= 0,
                  UInt64(manifestEntry.metadata.size)
                    <= limits.maximumManifestCaptureBytes else {
                return try invalidAfterStableRecheck(
                    at: location,
                    initialTree: initialTree,
                    manifestData: nil,
                    fileEvidence: [],
                    reason: "package-file-too-large"
                )
            }

            let manifestRead = try readRegularFile(
                rootURL: location.canonicalURL,
                expectedRoot: expectedRootIdentity,
                relativePath: MacScopeDocumentPackage.manifestFileName,
                maximumByteCount: limits.maximumManifestCaptureBytes,
                requiresSingleLink: true
            )
            let manifestData = manifestRead.data
            let manifest: WorkspacePackageManifest
            do {
                beforeCancellableWork?("manifest-validation")
                manifest = try MacScopeDocumentPackage.validatedManifest(
                    manifestData: manifestData
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let finalTree = try treeSnapshot(at: location.canonicalURL)
                guard finalTree == initialTree else {
                    return unverifiableObservation(
                        at: location,
                        reason: "package-changed-during-observation"
                    )
                }
                return invalidObservation(
                    at: location,
                    tree: finalTree,
                    manifestData: manifestData,
                    fileEvidence: [manifestRead.evidence],
                    reason: "package-manifest-invalid"
                )
            }

            var instructionSidecarData: Data?
            var instructionEvidence: [FileEvidence] = []
            if let descriptor = manifest.instructionSidecar {
                guard let entry = treeEntry(named: descriptor.path, in: initialTree),
                      entry.kind == .regularFile, entry.metadata.size >= 0,
                      UInt64(entry.metadata.size) == descriptor.byteCount,
                      descriptor.byteCount <= limits.maximumInstructionSidecarCaptureBytes else {
                    return try invalidAfterStableRecheck(
                        at: location, initialTree: initialTree, manifestData: manifestData,
                        fileEvidence: [manifestRead.evidence], reason: "package-instruction-sidecar-size-or-file-invalid"
                    )
                }
                let read = try readRegularFile(
                    rootURL: location.canonicalURL, expectedRoot: expectedRootIdentity,
                    relativePath: descriptor.path, maximumByteCount: limits.maximumInstructionSidecarCaptureBytes,
                    requiresSingleLink: true
                )
                instructionSidecarData = read.data
                instructionEvidence = [read.evidence]
                guard read.evidence.sha256 == descriptor.sha256 else {
                    return try invalidAfterStableRecheck(
                        at: location, initialTree: initialTree, manifestData: manifestData,
                        fileEvidence: [manifestRead.evidence] + instructionEvidence,
                        reason: "package-instruction-sidecar-hash-mismatch"
                    )
                }
            }

            var reconstructionState = ReconstructionWorkspaceState.empty
            var reconstructionEvidence: [FileEvidence] = []
            var reconstructionContents: [ReconstructionPackageContentRecord] = []
            if manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion {
                guard let descriptor = manifest.reconstruction else {
                    return try invalidAfterStableRecheck(
                        at: location,
                        initialTree: initialTree,
                        manifestData: manifestData,
                        fileEvidence: [manifestRead.evidence],
                        reason: "package-reconstruction-descriptor-missing"
                    )
                }
                let reconstructionManifestPaths = [
                    descriptor.corpusManifestPath,
                    descriptor.evidenceManifestPath,
                    descriptor.checkpointManifestPath,
                ]
                guard reconstructionManifestPaths.allSatisfy({ path in
                    guard let entry = treeEntry(named: path, in: initialTree) else {
                        return false
                    }
                    return entry.kind == .regularFile
                        && entry.metadata.size >= 0
                        && UInt64(entry.metadata.size)
                            <= UInt64(ReconstructionPackageLayout.maximumManifestBytes)
                }) else {
                    return try invalidAfterStableRecheck(
                        at: location,
                        initialTree: initialTree,
                        manifestData: manifestData,
                        fileEvidence: [manifestRead.evidence],
                        reason: "package-reconstruction-manifest-missing"
                    )
                }
                var reconstructionHasHardLinkAlias = reconstructionManifestPaths.contains {
                    treeEntry(named: $0, in: initialTree)?.metadata.linkCount != 1
                }
                let corpusRead = try readRegularFile(
                    rootURL: location.canonicalURL,
                    expectedRoot: expectedRootIdentity,
                    relativePath: descriptor.corpusManifestPath,
                    maximumByteCount: UInt64(ReconstructionPackageLayout.maximumManifestBytes),
                    requiresSingleLink: false
                )
                let evidenceRead = try readRegularFile(
                    rootURL: location.canonicalURL,
                    expectedRoot: expectedRootIdentity,
                    relativePath: descriptor.evidenceManifestPath,
                    maximumByteCount: UInt64(ReconstructionPackageLayout.maximumManifestBytes),
                    requiresSingleLink: false
                )
                let checkpointRead = try readRegularFile(
                    rootURL: location.canonicalURL,
                    expectedRoot: expectedRootIdentity,
                    relativePath: descriptor.checkpointManifestPath,
                    maximumByteCount: UInt64(ReconstructionPackageLayout.maximumManifestBytes),
                    requiresSingleLink: false
                )
                reconstructionEvidence = [
                    corpusRead.evidence,
                    evidenceRead.evidence,
                    checkpointRead.evidence,
                ]
                do {
                    beforeCancellableWork?("reconstruction-graph-validation")
                    reconstructionState = try ReconstructionPackageCodec.decode(
                        descriptor: descriptor,
                        corpusData: corpusRead.data,
                        evidenceData: evidenceRead.data,
                        checkpointData: checkpointRead.data
                    )
                    guard reconstructionState != .empty else {
                        return try invalidAfterStableRecheck(
                            at: location,
                            initialTree: initialTree,
                            manifestData: manifestData,
                            fileEvidence: [manifestRead.evidence] + reconstructionEvidence,
                            reason: "package-reconstruction-state-empty"
                        )
                    }
                    reconstructionContents = try ReconstructionPackageCodec.contentRecords(
                        in: reconstructionState
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return try invalidAfterStableRecheck(
                        at: location,
                        initialTree: initialTree,
                        manifestData: manifestData,
                        fileEvidence: [manifestRead.evidence] + reconstructionEvidence,
                        reason: "package-reconstruction-manifest-invalid"
                    )
                }

                var observedReconstructionContents: [(
                    record: ReconstructionPackageContentRecord,
                    evidence: FileEvidence
                )] = []
                for content in reconstructionContents.sorted(by: {
                    $0.attachmentPath < $1.attachmentPath
                }) {
                    guard let entry = treeEntry(
                        named: content.attachmentPath,
                        in: initialTree
                    ),
                          entry.kind == .regularFile,
                          entry.metadata.size >= 0,
                          UInt64(entry.metadata.size) == content.contentIdentity.byteCount else {
                        return try invalidAfterStableRecheck(
                            at: location,
                            initialTree: initialTree,
                            manifestData: manifestData,
                            fileEvidence: [manifestRead.evidence] + reconstructionEvidence,
                            reason: "package-reconstruction-content-missing"
                        )
                    }
                    reconstructionHasHardLinkAlias = reconstructionHasHardLinkAlias
                        || entry.metadata.linkCount != 1
                    let evidence = try digestRegularFile(
                        rootURL: location.canonicalURL,
                        expectedRoot: expectedRootIdentity,
                        relativePath: content.attachmentPath,
                        maximumByteCount: content.contentIdentity.byteCount,
                        requiresSingleLink: false
                    )
                    reconstructionEvidence.append(evidence)
                    observedReconstructionContents.append((content, evidence))
                }
                guard observedReconstructionContents.allSatisfy({ observed in
                    observed.evidence.byteCount == observed.record.contentIdentity.byteCount
                        && observed.evidence.sha256 == observed.record.contentIdentity.digest
                }) else {
                    return try invalidAfterStableRecheck(
                        at: location,
                        initialTree: initialTree,
                        manifestData: manifestData,
                        fileEvidence: [manifestRead.evidence] + reconstructionEvidence,
                        reason: "package-reconstruction-content-invalid"
                    )
                }
                guard !reconstructionHasHardLinkAlias else {
                    return try invalidAfterStableRecheck(
                        at: location,
                        initialTree: initialTree,
                        manifestData: manifestData,
                        fileEvidence: [manifestRead.evidence] + reconstructionEvidence,
                        reason: "package-reconstruction-hard-link-unsupported"
                    )
                }
            }

            let declaredPaths = Set(manifest.binaries.map(\.attachmentRelativePath))
                .union(reconstructionEvidence.map(\.relativePath))
                .union(instructionEvidence.map(\.relativePath))
            var requiredDirectories: Set<String> = [
                MacScopeDocumentPackage.attachmentsDirectoryName
            ]
            for relativePath in declaredPaths {
                let components = relativePath.split(separator: "/").map(String.init)
                for count in 1..<components.count {
                    requiredDirectories.insert(components.prefix(count).joined(separator: "/"))
                }
            }
            guard requiredDirectories.allSatisfy({
                treeEntry(named: $0, in: initialTree)?.kind == .directory
            }) else {
                return try invalidAfterStableRecheck(
                    at: location,
                    initialTree: initialTree,
                    manifestData: manifestData,
                    fileEvidence: [manifestRead.evidence],
                    reason: "package-declared-directory-missing"
                )
            }

            let allowedLeaves = declaredPaths.union([
                MacScopeDocumentPackage.manifestFileName
            ])
            let unexpectedLeaves = initialTree.entries.filter {
                $0.kind != .directory && !allowedLeaves.contains($0.relativePath)
            }
            guard unexpectedLeaves.isEmpty else {
                return try invalidAfterStableRecheck(
                    at: location,
                    initialTree: initialTree,
                    manifestData: manifestData,
                    fileEvidence: [manifestRead.evidence],
                    reason: "package-undeclared-leaf"
                )
            }
            if manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion {
                let reconstructionRoot = ReconstructionPackageLayout.rootDirectoryName
                let reconstructionRootLowercased = reconstructionRoot.lowercased()
                let unexpectedReconstructionDirectories = initialTree.entries.filter {
                    $0.kind == .directory
                        && $0.relativePath.lowercased().hasPrefix(
                            reconstructionRootLowercased
                        )
                        && !requiredDirectories.contains($0.relativePath)
                }
                guard unexpectedReconstructionDirectories.isEmpty else {
                    return try invalidAfterStableRecheck(
                        at: location,
                        initialTree: initialTree,
                        manifestData: manifestData,
                        fileEvidence: [manifestRead.evidence] + reconstructionEvidence,
                        reason: "package-undeclared-reconstruction-directory"
                    )
                }
            }

            var attachmentsByBinaryID: [UUID: Data] = [:]
            var fileEvidence = [manifestRead.evidence] + reconstructionEvidence + instructionEvidence
            var totalAttachmentBytes: UInt64 = 0
            for binary in manifest.binaries {
                try Task.checkCancellation()
                guard let declaredSize = UInt64(exactly: binary.fileSize),
                      declaredSize <= limits.maximumAttachmentCaptureBytes else {
                    return try invalidAfterStableRecheck(
                        at: location,
                        initialTree: initialTree,
                        manifestData: manifestData,
                        fileEvidence: fileEvidence,
                        reason: "package-file-too-large"
                    )
                }
                guard totalAttachmentBytes <= limits.maximumTotalAttachmentCaptureBytes,
                      declaredSize <= limits.maximumTotalAttachmentCaptureBytes
                        - totalAttachmentBytes else {
                    return try invalidAfterStableRecheck(
                        at: location,
                        initialTree: initialTree,
                        manifestData: manifestData,
                        fileEvidence: fileEvidence,
                        reason: "package-attachment-capture-budget-exceeded"
                    )
                }
                totalAttachmentBytes += declaredSize
            }
            for binary in manifest.binaries.sorted(by: {
                $0.attachmentRelativePath < $1.attachmentRelativePath
            }) {
                guard treeEntry(
                    named: binary.attachmentRelativePath,
                    in: initialTree
                )?.kind
                        == .regularFile else {
                    return try invalidAfterStableRecheck(
                        at: location,
                        initialTree: initialTree,
                        manifestData: manifestData,
                        fileEvidence: fileEvidence,
                        reason: "package-declared-attachment-missing"
                    )
                }
                let read = try readRegularFile(
                    rootURL: location.canonicalURL,
                    expectedRoot: expectedRootIdentity,
                    relativePath: binary.attachmentRelativePath,
                    maximumByteCount: UInt64(binary.fileSize),
                    requiresSingleLink: true
                )
                attachmentsByBinaryID[binary.id] = read.data
                fileEvidence.append(read.evidence)
            }

            let contents: WorkspacePackageContents?
            do {
                beforeCancellableWork?("package-contents-validation")
                contents = try MacScopeDocumentPackage.validatedContents(
                    manifestData: manifestData,
                    attachmentsByBinaryID: attachmentsByBinaryID,
                    reconstructionState: reconstructionState,
                    instructionSidecarData: instructionSidecarData
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                contents = nil
            }
            let finalTree = try treeSnapshot(at: location.canonicalURL)
            guard finalTree == initialTree else {
                return unverifiableObservation(
                    at: location,
                    reason: "package-changed-during-observation"
                )
            }

            guard let contents else {
                return invalidObservation(
                    at: location,
                    tree: finalTree,
                    manifestData: manifestData,
                    fileEvidence: fileEvidence,
                    reason: "package-content-validation-failed"
                )
            }
            return try validObservation(
                at: location,
                manifestData: manifestData,
                manifest: contents.manifest,
                attachmentsByBinaryID: contents.attachmentsByBinaryID,
                reconstructionEvidence: reconstructionEvidence + instructionEvidence
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ProbeFailure.unstable(let reason) {
            return unverifiableObservation(at: location, reason: reason)
        } catch ProbeFailure.invalid(let reason) {
            return invalidObservation(
                at: location,
                tree: nil,
                manifestData: nil,
                fileEvidence: [],
                reason: reason
            )
        } catch ProbeFailure.hostFailure(let reason) {
            throw WorkspaceDocumentSessionError.operationFailed(reason)
        } catch {
            throw WorkspaceDocumentSessionError.operationFailed(
                "package-observation-internal-failure"
            )
        }
    }

    private func absentObservation(
        at location: WorkspaceDocumentLocation
    ) -> WorkspacePackageExternalVersion {
        var digest = DomainDigest(domain: Self.observationDomain)
        digest.addString("condition", WorkspacePackageObservationCondition.absent.rawValue)
        return WorkspacePackageExternalVersion(
            location: location,
            condition: .absent,
            observationSHA256: digest.finalize(),
            manifestSHA256: nil,
            validatedContentSHA256: nil,
            boundedReason: nil
        )
    }

    private func validObservation(
        at location: WorkspaceDocumentLocation,
        manifestData: Data,
        manifest: WorkspacePackageManifest,
        attachmentsByBinaryID: [UUID: Data],
        reconstructionEvidence: [FileEvidence]
    ) throws -> WorkspacePackageExternalVersion {
        var exactDigest = DomainDigest(domain: Self.observationDomain)
        exactDigest.addString("condition", WorkspacePackageObservationCondition.valid.rawValue)
        exactDigest.addData("manifest", manifestData)
        addDeclaredAttachmentEvidence(
            manifest: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID,
            to: &exactDigest
        )
        addReconstructionEvidence(reconstructionEvidence, to: &exactDigest)

        var validatedDigest = DomainDigest(
            domain: Self.observationDomain + ".validated-content"
        )
        validatedDigest.addData(
            "canonical-manifest",
            try MacScopeDocumentPackage.canonicalEncodedManifest(
                manifest,
                decodedFrom: manifestData
            )
        )
        addDeclaredAttachmentEvidence(
            manifest: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID,
            to: &validatedDigest
        )
        addReconstructionEvidence(reconstructionEvidence, to: &validatedDigest)

        return WorkspacePackageExternalVersion(
            location: location,
            condition: .valid,
            observationSHA256: exactDigest.finalize(),
            manifestSHA256: MacScopeDocumentPackage.fileHash(for: manifestData),
            validatedContentSHA256: validatedDigest.finalize(),
            boundedReason: nil
        )
    }

    private func addDeclaredAttachmentEvidence(
        manifest: WorkspacePackageManifest,
        attachmentsByBinaryID: [UUID: Data],
        to digest: inout DomainDigest
    ) {
        for binary in manifest.binaries.sorted(by: {
            $0.attachmentRelativePath < $1.attachmentRelativePath
        }) {
            let data = attachmentsByBinaryID[binary.id] ?? Data()
            digest.addString("attachment-path", binary.attachmentRelativePath)
            digest.addInt64("declared-size", binary.fileSize)
            digest.addString("declared-sha256", binary.fileHash.lowercased())
            digest.addUInt64("actual-size", UInt64(data.count))
            digest.addString(
                "actual-sha256",
                MacScopeDocumentPackage.fileHash(for: data)
            )
        }
    }

    private func addReconstructionEvidence(
        _ evidence: [FileEvidence],
        to digest: inout DomainDigest
    ) {
        for item in evidence.sorted(by: { $0.relativePath < $1.relativePath }) {
            digest.addString("reconstruction-path", item.relativePath)
            digest.addUInt64("reconstruction-size", item.byteCount)
            digest.addString("reconstruction-sha256", item.sha256)
        }
    }

    private func invalidAfterStableRecheck(
        at location: WorkspaceDocumentLocation,
        initialTree: TreeSnapshot,
        manifestData: Data?,
        fileEvidence: [FileEvidence],
        reason: String
    ) throws -> WorkspacePackageExternalVersion {
        let finalTree = try treeSnapshot(at: location.canonicalURL)
        guard finalTree == initialTree else {
            return unverifiableObservation(
                at: location,
                reason: "package-changed-during-observation"
            )
        }
        return invalidObservation(
            at: location,
            tree: finalTree,
            manifestData: manifestData,
            fileEvidence: fileEvidence,
            reason: reason
        )
    }

    private func invalidObservation(
        at location: WorkspaceDocumentLocation,
        tree: TreeSnapshot?,
        manifestData: Data?,
        fileEvidence: [FileEvidence],
        reason: String
    ) -> WorkspacePackageExternalVersion {
        let boundedReason = bounded(reason)
        var digest = DomainDigest(domain: Self.observationDomain)
        digest.addString("condition", WorkspacePackageObservationCondition.invalid.rawValue)
        digest.addString("reason", boundedReason)
        if let manifestData {
            digest.addData("manifest", manifestData)
        }
        for entry in tree?.entries ?? [] {
            digest.addString("tree-path", entry.relativePath)
            digest.addString("tree-kind", entry.kind.rawValue)
            digest.addInt64("tree-size", entry.metadata.size)
        }
        for evidence in fileEvidence.sorted(by: { $0.relativePath < $1.relativePath }) {
            digest.addString("observed-path", evidence.relativePath)
            digest.addUInt64("observed-size", evidence.byteCount)
            digest.addString("observed-sha256", evidence.sha256)
        }
        return WorkspacePackageExternalVersion(
            location: location,
            condition: .invalid,
            observationSHA256: digest.finalize(),
            manifestSHA256: manifestData.map {
                MacScopeDocumentPackage.fileHash(for: $0)
            },
            validatedContentSHA256: nil,
            boundedReason: boundedReason
        )
    }

    private func unverifiableObservation(
        at location: WorkspaceDocumentLocation,
        reason: String
    ) -> WorkspacePackageExternalVersion {
        let boundedReason = bounded(reason)
        var digest = DomainDigest(domain: Self.observationDomain)
        digest.addString(
            "condition",
            WorkspacePackageObservationCondition.unverifiable.rawValue
        )
        digest.addString("reason", boundedReason)
        return WorkspacePackageExternalVersion(
            location: location,
            condition: .unverifiable,
            observationSHA256: digest.finalize(),
            manifestSHA256: nil,
            validatedContentSHA256: nil,
            boundedReason: boundedReason
        )
    }

    private func bounded(_ reason: String) -> String {
        let filtered = reason.unicodeScalars.map { scalar -> String in
            if scalar.value < 0x20 || scalar.value == 0x7f {
                return "?"
            }
            return String(scalar)
        }.joined()
        var result = ""
        for character in filtered {
            let candidate = result + String(character)
            guard candidate.utf8.count <= 256 else { break }
            result = candidate
        }
        return result
    }

    private func readRegularFile(
        rootURL: URL,
        expectedRoot: WorkspaceFileObjectIdentity,
        relativePath: String,
        maximumByteCount: UInt64? = nil,
        requiresSingleLink: Bool
    ) throws -> (data: Data, evidence: FileEvidence) {
        let inspected = try inspectRegularFile(
            rootURL: rootURL,
            expectedRoot: expectedRoot,
            relativePath: relativePath,
            maximumByteCount: maximumByteCount,
            requiresSingleLink: requiresSingleLink,
            captureData: true
        )
        guard let data = inspected.data else {
            throw ProbeFailure.hostFailure("package-file-capture-failed")
        }
        return (data, inspected.evidence)
    }

    private func digestRegularFile(
        rootURL: URL,
        expectedRoot: WorkspaceFileObjectIdentity,
        relativePath: String,
        maximumByteCount: UInt64,
        requiresSingleLink: Bool
    ) throws -> FileEvidence {
        try inspectRegularFile(
            rootURL: rootURL,
            expectedRoot: expectedRoot,
            relativePath: relativePath,
            maximumByteCount: maximumByteCount,
            requiresSingleLink: requiresSingleLink,
            captureData: false
        ).evidence
    }

    private func inspectRegularFile(
        rootURL: URL,
        expectedRoot: WorkspaceFileObjectIdentity,
        relativePath: String,
        maximumByteCount: UInt64?,
        requiresSingleLink: Bool,
        captureData: Bool
    ) throws -> (data: Data?, evidence: FileEvidence) {
        try Task.checkCancellation()
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
              }) else {
            throw ProbeFailure.invalid("package-relative-path-invalid")
        }

        let rootDescriptor = rootURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP {
                throw ProbeFailure.unstable("package-changed-during-observation")
            }
            throw ProbeFailure.hostFailure("package-root-open-failed")
        }
        defer { Darwin.close(rootDescriptor) }

        var rootMetadata = stat()
        guard Darwin.fstat(rootDescriptor, &rootMetadata) == 0 else {
            throw ProbeFailure.hostFailure("package-root-stat-failed")
        }
        guard FileObjectID(rootMetadata).workspaceIdentity == expectedRoot else {
            throw ProbeFailure.unstable("package-root-changed-during-observation")
        }

        var parentDescriptor = rootDescriptor
        var ownedDirectories: [Int32] = []
        defer {
            for descriptor in ownedDirectories.reversed() {
                Darwin.close(descriptor)
            }
        }
        for component in components.dropLast() {
            let child = component.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard child >= 0 else {
                if errno == ENOENT || errno == ENOTDIR || errno == ELOOP {
                    throw ProbeFailure.unstable("package-changed-during-observation")
                }
                throw ProbeFailure.hostFailure("package-directory-open-failed")
            }
            ownedDirectories.append(child)
            parentDescriptor = child
        }

        let descriptor = components[components.count - 1].withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw ProbeFailure.invalid("package-symbolic-link-unsupported")
            }
            if errno == ENOENT || errno == ENOTDIR {
                throw ProbeFailure.unstable("package-changed-during-observation")
            }
            throw ProbeFailure.hostFailure("package-file-open-failed")
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else {
            throw ProbeFailure.hostFailure("package-file-stat-failed")
        }
        guard (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0,
              UInt64(before.st_size) <= UInt64(Int.max),
              !requiresSingleLink || before.st_nlink == 1 else {
            throw ProbeFailure.invalid("package-leaf-not-regular-file")
        }
        if let maximumByteCount,
           UInt64(before.st_size) > maximumByteCount {
            throw ProbeFailure.invalid("package-file-too-large")
        }

        beforeReadingRelativePath?(relativePath)
        var data: Data? = captureData ? Data() : nil
        if captureData {
            data?.reserveCapacity(Int(before.st_size))
        }
        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                total += UInt64(count)
                if let maximumByteCount,
                   total > maximumByteCount {
                    throw ProbeFailure.invalid("package-file-too-large")
                }
                let chunk = Data(buffer.prefix(Int(count)))
                hasher.update(data: chunk)
                data?.append(chunk)
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw ProbeFailure.hostFailure("package-file-read-failed")
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else {
            throw ProbeFailure.hostFailure("package-file-stat-failed")
        }
        guard FileMetadata(after) == FileMetadata(before),
              total == UInt64(after.st_size) else {
            throw ProbeFailure.unstable("package-file-changed-during-read")
        }
        return (
            data,
            FileEvidence(
                relativePath: relativePath,
                byteCount: total,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        )
    }

    private func treeSnapshot(at rootURL: URL) throws -> TreeSnapshot {
        beforeTreeSnapshot?()
        try Task.checkCancellation()
        let descriptor = rootURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw ProbeFailure.unstable("package-changed-during-observation")
            }
            if errno == ENOTDIR {
                throw ProbeFailure.invalid("package-root-not-directory")
            }
            if errno == ELOOP {
                throw ProbeFailure.invalid("package-root-symbolic-link-unsupported")
            }
            throw ProbeFailure.hostFailure("package-root-open-failed")
        }
        defer { Darwin.close(descriptor) }

        var rootStat = stat()
        guard Darwin.fstat(descriptor, &rootStat) == 0 else {
            throw ProbeFailure.hostFailure("package-root-stat-failed")
        }
        let root = TreeEntry(
            relativePath: "",
            kind: FileKind(mode: rootStat.st_mode),
            metadata: FileMetadata(rootStat)
        )
        var entries: [TreeEntry] = []
        var visitedDirectories: Set<FileObjectID> = [FileObjectID(rootStat)]
        var budget = TreeEnumerationBudget(
            remainingEntries: limits.maximumTreeEntryCount,
            remainingNameBytes: limits.maximumTreeNameBytes
        )
        try enumerateDirectory(
            descriptor,
            relativeComponents: [],
            depth: 0,
            visitedDirectories: &visitedDirectories,
            budget: &budget,
            entries: &entries
        )
        entries.sort { $0.relativePath < $1.relativePath }
        let snapshot = TreeSnapshot(
            root: root,
            entries: entries,
            didUseIndex: didUseTreeIndex
        )
        didBuildTreeIndex?(entries.count)
        return snapshot
    }

    private func treeEntry(
        named relativePath: String,
        in snapshot: TreeSnapshot
    ) -> TreeEntry? {
        return snapshot.entry(named: relativePath)
    }

    private func enumerateDirectory(
        _ descriptor: Int32,
        relativeComponents: [String],
        depth: Int,
        visitedDirectories: inout Set<FileObjectID>,
        budget: inout TreeEnumerationBudget,
        entries: inout [TreeEntry]
    ) throws {
        try Task.checkCancellation()
        guard depth <= 128 else {
            throw ProbeFailure.invalid("package-tree-depth-unsupported")
        }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw ProbeFailure.hostFailure("package-directory-dup-failed")
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw ProbeFailure.hostFailure("package-directory-open-failed")
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            try Task.checkCancellation()
            let length = Int(entry.pointee.d_namlen)
            guard length > 0, length <= Int(NAME_MAX) else {
                throw ProbeFailure.invalid("package-file-name-invalid")
            }
            let bytes: [UInt8] = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: UInt8.self,
                    capacity: Int(NAME_MAX) + 1
                ) { start in
                    Array(UnsafeBufferPointer(start: start, count: length))
                }
            }
            guard let name = String(bytes: bytes, encoding: .utf8) else {
                throw ProbeFailure.invalid("package-file-name-not-utf8")
            }
            if name != "." && name != ".." {
                beforeCancellableWork?("tree-enumeration")
                try Task.checkCancellation()
                try budget.admit(nameByteCount: length)
                names.append(name)
            }
        }
        guard errno == 0 else {
            throw ProbeFailure.hostFailure("package-directory-read-failed")
        }

        for name in names.sorted() {
            try Task.checkCancellation()
            var metadata = stat()
            let status = name.withCString {
                Darwin.fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                if errno == ENOENT || errno == ENOTDIR {
                    throw ProbeFailure.unstable("package-changed-during-observation")
                }
                throw ProbeFailure.hostFailure("package-entry-stat-failed")
            }
            let components = relativeComponents + [name]
            let relativePath = components.joined(separator: "/")
            let kind = FileKind(mode: metadata.st_mode)
            entries.append(TreeEntry(
                relativePath: relativePath,
                kind: kind,
                metadata: FileMetadata(metadata)
            ))

            if kind == .directory {
                guard visitedDirectories.insert(FileObjectID(metadata)).inserted else {
                    throw ProbeFailure.invalid("package-directory-cycle")
                }
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard child >= 0 else {
                    if errno == ENOENT || errno == ENOTDIR || errno == ELOOP {
                        throw ProbeFailure.unstable("package-changed-during-observation")
                    }
                    throw ProbeFailure.hostFailure("package-directory-open-failed")
                }
                defer { Darwin.close(child) }
                try enumerateDirectory(
                    child,
                    relativeComponents: components,
                    depth: depth + 1,
                    visitedDirectories: &visitedDirectories,
                    budget: &budget,
                    entries: &entries
                )
            }
        }
    }
}

private enum ProbeFailure: Error {
    case invalid(String)
    case unstable(String)
    case hostFailure(String)
}

private enum FileKind: String, Equatable {
    case directory
    case regularFile
    case symbolicLink
    case special

    init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFDIR:
            self = .directory
        case S_IFREG:
            self = .regularFile
        case S_IFLNK:
            self = .symbolicLink
        default:
            self = .special
        }
    }
}

private struct FileObjectID: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(truncatingIfNeeded: metadata.st_dev)
        inode = UInt64(truncatingIfNeeded: metadata.st_ino)
    }

    var workspaceIdentity: WorkspaceFileObjectIdentity {
        WorkspaceFileObjectIdentity(device: device, inode: inode)
    }
}

private struct FileMetadata: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let linkCount: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ metadata: stat) {
        device = UInt64(truncatingIfNeeded: metadata.st_dev)
        inode = UInt64(truncatingIfNeeded: metadata.st_ino)
        mode = UInt32(metadata.st_mode)
        linkCount = UInt64(truncatingIfNeeded: metadata.st_nlink)
        size = metadata.st_size
        modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }

    var objectIdentity: WorkspaceFileObjectIdentity {
        WorkspaceFileObjectIdentity(device: device, inode: inode)
    }
}

private struct TreeEntry: Equatable {
    let relativePath: String
    let kind: FileKind
    let metadata: FileMetadata
}

private struct TreeEnumerationBudget {
    var remainingEntries: Int
    var remainingNameBytes: Int

    mutating func admit(nameByteCount: Int) throws {
        guard remainingEntries > 0 else {
            throw ProbeFailure.invalid("package-tree-entry-budget-exceeded")
        }
        guard nameByteCount <= remainingNameBytes else {
            throw ProbeFailure.invalid("package-tree-name-byte-budget-exceeded")
        }
        remainingEntries -= 1
        remainingNameBytes -= nameByteCount
    }
}

private struct TreeEntryIndex: Equatable {
    private let entriesByRelativePath: [String: TreeEntry]
    private let didUseIndex: WorkspacePackageVersionProbe.ReadCheckpoint?

    init(
        entries: [TreeEntry],
        didUseIndex: WorkspacePackageVersionProbe.ReadCheckpoint?
    ) {
        entriesByRelativePath = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.relativePath, $0) }
        )
        self.didUseIndex = didUseIndex
    }

    subscript(relativePath: String) -> TreeEntry? {
        didUseIndex?(relativePath)
        return entriesByRelativePath[relativePath]
    }

    static func == (lhs: TreeEntryIndex, rhs: TreeEntryIndex) -> Bool {
        lhs.entriesByRelativePath == rhs.entriesByRelativePath
    }
}

private struct TreeSnapshot: Equatable {
    let root: TreeEntry
    let entries: [TreeEntry]
    private let index: TreeEntryIndex

    init(
        root: TreeEntry,
        entries: [TreeEntry],
        didUseIndex: WorkspacePackageVersionProbe.ReadCheckpoint?
    ) {
        self.root = root
        self.entries = entries
        index = TreeEntryIndex(entries: entries, didUseIndex: didUseIndex)
    }

    func entry(named relativePath: String) -> TreeEntry? {
        index[relativePath]
    }
}

private struct FileEvidence {
    let relativePath: String
    let byteCount: UInt64
    let sha256: String
}

private struct DomainDigest {
    private var hasher = SHA256()

    init(domain: String) {
        addString("domain", domain)
    }

    mutating func addString(_ label: String, _ value: String) {
        addData(label, Data(value.utf8))
    }

    mutating func addUInt64(_ label: String, _ value: UInt64) {
        var bigEndian = value.bigEndian
        addData(label, Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size))
    }

    mutating func addInt64(_ label: String, _ value: Int64) {
        addUInt64(label, UInt64(bitPattern: value))
    }

    mutating func addData(_ label: String, _ value: Data) {
        let labelData = Data(label.utf8)
        updateLength(labelData.count)
        hasher.update(data: labelData)
        updateLength(value.count)
        hasher.update(data: value)
    }

    mutating func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func updateLength(_ length: Int) {
        var bigEndian = UInt64(length).bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            hasher.update(data: Data(bytes))
        }
    }
}
