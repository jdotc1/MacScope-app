import Darwin
import Foundation

actor WorkspaceDocumentPublisher: WorkspaceDocumentPublishing {
    private struct RecoverablePublicationFailure: Error {
        let sessionError: WorkspaceDocumentSessionError
    }

    private struct StageOwnership: Sendable {
        let stagingID: UUID
        let stagingURL: URL
        let parentDirectory: URL
        let documentID: UUID
        let workspaceID: UUID
        let manifestData: Data
        let attachmentsByBinaryID: [UUID: Data]
        let reconstructionState: ReconstructionWorkspaceState
        let reconstructionContentIdentities: [ReconstructionContentIdentity]
        let observation: WorkspacePackageExternalVersion
        let capturedMutationGeneration: WorkspaceDocumentMutationGeneration
        /// Decode-once scope shared by staging, every later `validateStage` and the
        /// post-publication probe of these exact manifest bytes.
        let decodeScope: WorkspaceManifestDecodeScope
    }

    private let probe: WorkspacePackageVersionProbe
    private let fileManager: FileManager
    private let beforeParentDirectorySynchronization: @Sendable () throws -> Void
    private let beforeRollbackRename: @Sendable () throws -> Void
    private let beforeAtomicPublicationRename: @Sendable () -> Void
    private let beforeRetiredPackageCleanup: @Sendable () throws -> Void
    private var stages: [UUID: StageOwnership] = [:]

    init(
        probe: WorkspacePackageVersionProbe = WorkspacePackageVersionProbe(),
        fileManager: FileManager = .default,
        beforeParentDirectorySynchronization: @escaping @Sendable () throws -> Void = {},
        beforeRollbackRename: @escaping @Sendable () throws -> Void = {},
        beforeAtomicPublicationRename: @escaping @Sendable () -> Void = {},
        beforeRetiredPackageCleanup: @escaping @Sendable () throws -> Void = {}
    ) {
        self.probe = probe
        self.fileManager = fileManager
        self.beforeParentDirectorySynchronization = beforeParentDirectorySynchronization
        self.beforeRollbackRename = beforeRollbackRename
        self.beforeAtomicPublicationRename = beforeAtomicPublicationRename
        self.beforeRetiredPackageCleanup = beforeRetiredPackageCleanup
    }

    func stage(
        _ payload: WorkspaceDocumentPackagePayload,
        in parentDirectory: URL
    ) async throws -> WorkspaceDocumentStagedPackage {
        try WorkspaceManifestDecodeScope.ensuring { decodeScope in
            try stageInDecodeScope(payload, in: parentDirectory, decodeScope: decodeScope)
        }
    }

    private func stageInDecodeScope(
        _ payload: WorkspaceDocumentPackagePayload,
        in parentDirectory: URL,
        decodeScope: WorkspaceManifestDecodeScope
    ) throws -> WorkspaceDocumentStagedPackage {
        try Task.checkCancellation()
        let parent = try validatedParentDirectory(parentDirectory)
        // Fail before writing rather than stage a package the probe cannot capture.
        guard UInt64(payload.manifestData.count) <= MacScopeDocumentPackage.maximumManifestBytes else {
            throw WorkspaceDocumentSessionError.operationFailed("document-stage-manifest-too-large")
        }
        let contents = try MacScopeDocumentPackage.validatedContents(
            manifestData: payload.manifestData,
            attachmentsByBinaryID: payload.attachmentsByBinaryID,
            reconstructionState: payload.reconstructionState,
            instructionSidecarData: payload.instructionSidecarData
        )
        guard contents.manifest.documentID == payload.documentID,
              contents.manifest.workspaceUUID == payload.workspaceID else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-stage-logical-identity-mismatch"
            )
        }

        let stagingID = UUID()
        let stagingURL = parent.appendingPathComponent(
            ".macscope-stage-\(stagingID.uuidString.lowercased()).mscope",
            isDirectory: true
        )
        var createdIdentity: WorkspaceFileObjectIdentity?
        do {
            try MacScopeDocumentPackage.writePackage(
                contents.manifest,
                attachmentsByBinaryID: payload.attachmentsByBinaryID,
                reconstructionState: payload.reconstructionState,
                reconstructionAttachmentSources: payload.reconstructionAttachmentSources,
                to: stagingURL,
                fileManager: fileManager,
                instructionSidecarData: payload.instructionSidecarData
            )
            createdIdentity = try WorkspaceDocumentLocation.canonicalized(
                from: stagingURL
            ).fileObjectIdentity

            // The package writer serializes the admitted model again. Codable collections
            // such as runtime-authority Sets may produce equivalent JSON with different bytes.
            // Admit that transformation semantically, then pin the writer's exact bytes so
            // every later validation still rejects changes to the owned stage.
            let stagedManifestData = try Data(
                contentsOf: MacScopeDocumentPackage.manifestURL(in: stagingURL)
            )
            let writtenManifest = try MacScopeDocumentPackage.validatedManifest(
                manifestData: stagedManifestData
            )
            let expectedManifest = try MacScopeDocumentPackage.preparedInstructionStorage(
                MacScopeDocumentPackage.preparedManifest(
                    contents.manifest, reconstructionState: payload.reconstructionState
                ), instructionSidecarData: payload.instructionSidecarData
            ).manifest
            let writtenEncoding = try MacScopeDocumentPackage.canonicalEncodedManifest(
                writtenManifest, decodedFrom: stagedManifestData
            )
            let expectedEncoding = try MacScopeDocumentPackage.encodedManifest(expectedManifest)
            // Byte-equal canonical encodings are trivially the same persisted identity; only a
            // difference (e.g. Set ordering) needs the normalizing object comparison.
            guard try writtenEncoding == expectedEncoding
                || persistedManifestIdentity(encoded: writtenEncoding)
                    == persistedManifestIdentity(encoded: expectedEncoding) else {
                throw WorkspaceDocumentSessionError.operationFailed(
                    "document-stage-manifest-readback-mismatch"
                )
            }
            let observation = try probe.observeSynchronously(stagingURL)
            let ownership = StageOwnership(
                stagingID: stagingID,
                stagingURL: stagingURL,
                parentDirectory: parent,
                documentID: payload.documentID,
                workspaceID: payload.workspaceID,
                manifestData: stagedManifestData,
                attachmentsByBinaryID: payload.attachmentsByBinaryID,
                reconstructionState: payload.reconstructionState,
                reconstructionContentIdentities: payload.reconstructionAttachmentSources
                    .map(\.contentIdentity)
                    .sorted { $0.digest < $1.digest },
                observation: observation,
                capturedMutationGeneration: payload.capturedMutationGeneration,
                decodeScope: decodeScope
            )
            try validateStage(ownership)
            stages[stagingID] = ownership
            return WorkspaceDocumentStagedPackage(
                stagingID: stagingID,
                stagingURL: stagingURL,
                stagedObservation: observation,
                capturedMutationGeneration: payload.capturedMutationGeneration
            )
        } catch {
            cleanupConstructedStage(
                at: stagingURL,
                stagingID: stagingID,
                parentDirectory: parent,
                expectedIdentity: createdIdentity
            )
            throw error
        }
    }

    func publish(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        expecting expected: WorkspacePackageExternalVersion
    ) async throws -> WorkspaceDocumentPublishReceipt {
        guard let ownership = stages[staged.stagingID],
              ownership.stagingURL == staged.stagingURL,
              ownership.observation == staged.stagedObservation,
              ownership.capturedMutationGeneration == staged.capturedMutationGeneration else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-stage-ownership-unproven"
            )
        }
        guard expected.location == destination,
              ownership.parentDirectory
                == destination.canonicalURL.deletingLastPathComponent() else {
            stages[staged.stagingID] = nil
            cleanupOwnedStage(ownership, allowsReplacedRoot: false)
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-publish-location-mismatch"
            )
        }

        do {
            try Task.checkCancellation()
            let receipt = try WorkspaceManifestDecodeScope.$current.withValue(
                ownership.decodeScope
            ) {
                try validateStage(ownership)
                return try coordinatedPublish(
                    ownership,
                    destination: destination,
                    expected: expected
                )
            }
            stages[staged.stagingID] = nil
            return receipt
        } catch let failure as RecoverablePublicationFailure {
            stages[staged.stagingID] = nil
            throw failure.sessionError
        } catch {
            stages[staged.stagingID] = nil
            cleanupOwnedStage(ownership, allowsReplacedRoot: false)
            throw error
        }
    }

    func discard(_ staged: WorkspaceDocumentStagedPackage) async {
        guard let ownership = stages[staged.stagingID],
              ownership.stagingURL == staged.stagingURL,
              ownership.observation == staged.stagedObservation,
              ownership.capturedMutationGeneration == staged.capturedMutationGeneration else {
            return
        }
        stages[staged.stagingID] = nil
        cleanupOwnedStage(ownership, allowsReplacedRoot: false)
    }

    private func coordinatedPublish(
        _ ownership: StageOwnership,
        destination: WorkspaceDocumentLocation,
        expected: WorkspacePackageExternalVersion
    ) throws -> WorkspaceDocumentPublishReceipt {
        do {
            return try WorkspacePackageNamespaceCoordinator.coordinate(
                stagedAt: ownership.stagingURL,
                destination: destination.canonicalURL
            ) { coordinatedStageURL, coordinatedDestinationURL in
                try validateStage(ownership, at: coordinatedStageURL)
                let observed = try probe.observeSynchronously(coordinatedDestinationURL)
                guard observed == expected else {
                    throw RecoverablePublicationFailure(
                        sessionError: .operationFailed(
                            "document-publish-destination-changed-recovery:\(coordinatedStageURL.lastPathComponent)"
                        )
                    )
                }

                beforeAtomicPublicationRename()
                if expected.condition == .absent {
                    try Task.checkCancellation()
                    try atomicRename(
                        from: coordinatedStageURL,
                        to: coordinatedDestinationURL,
                        flags: UInt32(RENAME_EXCL),
                        failure: "document-publish-exclusive-create-failed"
                    )
                } else {
                    try Task.checkCancellation()
                    try atomicRename(
                        from: coordinatedStageURL,
                        to: coordinatedDestinationURL,
                        flags: UInt32(RENAME_SWAP),
                        failure: "document-publish-atomic-replace-failed"
                    )
                }

                let published: WorkspacePackageExternalVersion
                do {
                    published = try probe.observeSynchronously(coordinatedDestinationURL)
                    guard published.condition == .valid,
                          published.observationSHA256
                            == ownership.observation.observationSHA256,
                          published.manifestSHA256
                            == ownership.observation.manifestSHA256,
                          published.validatedContentSHA256
                            == ownership.observation.validatedContentSHA256 else {
                        throw WorkspaceDocumentSessionError.operationFailed(
                            "document-publish-postcondition-failed"
                        )
                    }
                    do {
                        try synchronizeParentDirectory(at: ownership.parentDirectory)
                    } catch {
                        throw WorkspaceDocumentSessionError.operationFailed(
                            "document-publish-parent-synchronization-failed"
                        )
                    }
                } catch {
                    let publicationError = error
                    do {
                        try beforeRollbackRename()
                        if expected.condition == .absent {
                            try atomicRename(
                                from: coordinatedDestinationURL,
                                to: coordinatedStageURL,
                                flags: UInt32(RENAME_EXCL),
                                failure: "document-publish-create-rollback-failed"
                            )
                        } else {
                            try atomicRename(
                                from: coordinatedStageURL,
                                to: coordinatedDestinationURL,
                                flags: UInt32(RENAME_SWAP),
                                failure: "document-publish-replace-rollback-failed"
                            )
                        }
                    } catch {
                        let recoveryName = expected.condition == .absent
                            ? coordinatedDestinationURL.lastPathComponent
                            : coordinatedStageURL.lastPathComponent
                        throw RecoverablePublicationFailure(
                            sessionError: .operationFailed(
                                "document-publish-rollback-failed-recovery:\(recoveryName)"
                            )
                        )
                    }
                    do {
                        try synchronizeParentDirectory(at: ownership.parentDirectory)
                    } catch {
                        let reason = expected.condition == .absent
                            ? "document-publish-rollback-sync-failed-recovery:\(coordinatedStageURL.lastPathComponent)"
                            : "document-publish-rollback-sync-failed-prior-at-destination"
                        throw RecoverablePublicationFailure(
                            sessionError: .operationFailed(reason)
                        )
                    }
                    throw publicationError
                }

                if expected.condition != .absent {
                    do {
                        try beforeRetiredPackageCleanup()
                        let expectedPriorIdentity = expected.location.fileObjectIdentity.map {
                            WorkspacePackageNamespaceCoordinator.FileObjectIdentity(
                                device: $0.device,
                                inode: $0.inode
                            )
                        }
                        guard try WorkspacePackageNamespaceCoordinator.fileObjectIdentity(
                            at: coordinatedStageURL
                        ) == expectedPriorIdentity else {
                            throw RecoverablePublicationFailure(
                                sessionError: .operationFailed(
                                    "document-publish-cleanup-ownership-unproven-recovery:\(coordinatedStageURL.lastPathComponent)"
                                )
                            )
                        }
                        try fileManager.removeItem(at: coordinatedStageURL)
                    } catch let failure as RecoverablePublicationFailure {
                        throw failure
                    } catch {
                        throw RecoverablePublicationFailure(
                            sessionError: .operationFailed(
                                "document-publish-cleanup-failed-recovery:\(coordinatedStageURL.lastPathComponent)"
                            )
                        )
                    }
                }
                return WorkspaceDocumentPublishReceipt(
                    stagingID: ownership.stagingID,
                    destination: published.location,
                    priorObservation: observed,
                    publishedObservation: published
                )
            }
        } catch WorkspacePackageNamespaceCoordinator.CoordinationError.failed {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-publish-coordination-failed"
            )
        } catch WorkspacePackageNamespaceCoordinator.CoordinationError.accessorNotInvoked {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-publish-accessor-not-invoked"
            )
        }
    }

    /// Compare persisted authority rather than decoder-created compatibility identities.
    /// Pristine breakpoint catalog UUIDs are intentionally omitted by the package encoder;
    /// runtime-authority surfaces are the one unordered Set in the manifest envelope.
    private func persistedManifestIdentity(encoded: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw WorkspaceDocumentSessionError.operationFailed("document-stage-manifest-object-invalid")
        }
        if var records = object["runtimeAuthorityRecords"] as? [[String: Any]] {
            for index in records.indices {
                guard let surfaces = records[index]["surfaces"] as? [String] else {
                    throw WorkspaceDocumentSessionError.operationFailed("document-stage-manifest-surfaces-invalid")
                }
                records[index]["surfaces"] = surfaces.sorted()
            }
            object["runtimeAuthorityRecords"] = records
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validateStage(
        _ ownership: StageOwnership,
        at stagedURL: URL? = nil
    ) throws {
        let stagedURL = stagedURL ?? ownership.stagingURL
        guard stagedURL.deletingLastPathComponent()
                == ownership.parentDirectory,
              stagedURL.lastPathComponent
                == ".macscope-stage-\(ownership.stagingID.uuidString.lowercased()).mscope" else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-stage-containment-unproven"
            )
        }
        let manifestData = try Data(
            contentsOf: MacScopeDocumentPackage.manifestURL(
                in: stagedURL
            )
        )
        guard manifestData == ownership.manifestData else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-stage-manifest-changed"
            )
        }
        let reopened = try MacScopeDocumentPackage.openPackage(
            from: stagedURL,
            fileManager: fileManager
        )
        guard reopened.manifest.documentID == ownership.documentID,
              reopened.manifest.workspaceUUID == ownership.workspaceID,
              reopened.attachmentsByBinaryID == ownership.attachmentsByBinaryID,
              reopened.reconstructionState == ownership.reconstructionState,
              reopened.reconstructionAttachmentSources
                .map(\.contentIdentity)
                .sorted(by: { $0.digest < $1.digest })
                == ownership.reconstructionContentIdentities else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-stage-readback-mismatch"
            )
        }
        let observed = try probe.observeSynchronously(stagedURL)
        // A stage the probe cannot admit is not a foreign modification: report the probe's own
        // reason so a capture bound or validation failure is not misread as a concurrent writer.
        guard observed.condition == .valid else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-stage-observation-not-valid:"
                    + (observed.boundedReason ?? observed.condition.rawValue)
            )
        }
        guard observed == ownership.observation else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-stage-observation-changed"
            )
        }
    }

    private func validatedParentDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-stage-parent-not-file-url"
            )
        }
        let canonical = url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: canonical.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-stage-parent-not-directory"
            )
        }
        return canonical
    }

    private func cleanupConstructedStage(
        at stagingURL: URL,
        stagingID: UUID,
        parentDirectory: URL,
        expectedIdentity: WorkspaceFileObjectIdentity?
    ) {
        guard stagingURL.deletingLastPathComponent() == parentDirectory,
              stagingURL.lastPathComponent
                == ".macscope-stage-\(stagingID.uuidString.lowercased()).mscope" else {
            return
        }
        guard fileManager.fileExists(atPath: stagingURL.path) else { return }
        let currentIdentity = try? WorkspaceDocumentLocation.canonicalized(
            from: stagingURL
        ).fileObjectIdentity
        guard let expectedIdentity,
              currentIdentity == expectedIdentity else {
            quarantine(
                stagingURL: stagingURL,
                stagingID: stagingID,
                parentDirectory: parentDirectory
            )
            return
        }
        do {
            try fileManager.removeItem(at: stagingURL)
        } catch {
            quarantine(
                stagingURL: stagingURL,
                stagingID: stagingID,
                parentDirectory: parentDirectory
            )
        }
    }

    private func cleanupOwnedStage(
        _ ownership: StageOwnership,
        allowsReplacedRoot: Bool
    ) {
        guard fileManager.fileExists(atPath: ownership.stagingURL.path),
              ownership.stagingURL.deletingLastPathComponent()
                == ownership.parentDirectory,
              ownership.stagingURL.lastPathComponent
                == ".macscope-stage-\(ownership.stagingID.uuidString.lowercased()).mscope" else {
            return
        }
        let currentLocation = try? WorkspaceDocumentLocation.canonicalized(
            from: ownership.stagingURL
        )
        let identityMatches = currentLocation?.fileObjectIdentity
            == ownership.observation.location.fileObjectIdentity
        if allowsReplacedRoot || identityMatches {
            do {
                try fileManager.removeItem(at: ownership.stagingURL)
                return
            } catch {
                // The exact owned name remains quarantined below.
            }
        }
        quarantine(ownership)
    }

    private func quarantine(_ ownership: StageOwnership) {
        quarantine(
            stagingURL: ownership.stagingURL,
            stagingID: ownership.stagingID,
            parentDirectory: ownership.parentDirectory
        )
    }

    private func quarantine(
        stagingURL: URL,
        stagingID: UUID,
        parentDirectory: URL
    ) {
        guard stagingURL.deletingLastPathComponent() == parentDirectory,
              stagingURL.lastPathComponent
                == ".macscope-stage-\(stagingID.uuidString.lowercased()).mscope" else {
            return
        }
        let quarantineURL = parentDirectory.appendingPathComponent(
            ".macscope-quarantine-\(stagingID.uuidString.lowercased()).mscope",
            isDirectory: true
        )
        try? atomicRename(
            from: stagingURL,
            to: quarantineURL,
            flags: UInt32(RENAME_EXCL),
            failure: "document-stage-quarantine-failed"
        )
    }

    private func atomicRename(
        from source: URL,
        to destination: URL,
        flags: UInt32,
        failure: String
    ) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
        guard status == 0 else {
            throw WorkspaceDocumentSessionError.operationFailed(failure)
        }
    }

    private func synchronizeParentDirectory(at directory: URL) throws {
        try beforeParentDirectorySynchronization()
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
