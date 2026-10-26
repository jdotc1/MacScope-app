import Foundation

protocol WorkspaceDocumentReading: Sendable {
    func readValidated(
        from location: WorkspaceDocumentLocation
    ) async throws -> WorkspaceDocumentValidatedPackage
}

protocol WorkspaceDocumentChangeMonitoring: Sendable {
    func changes(
        at location: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentChangeFeed
}

protocol WorkspaceDocumentPublishing: Sendable {
    func stage(
        _ payload: WorkspaceDocumentPackagePayload,
        in parentDirectory: URL
    ) async throws -> WorkspaceDocumentStagedPackage

    func publish(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        expecting expected: WorkspacePackageExternalVersion
    ) async throws -> WorkspaceDocumentPublishReceipt

    func discard(_ staged: WorkspaceDocumentStagedPackage) async
}

struct WorkspaceDocumentReader: WorkspaceDocumentReading {
    private let probe: WorkspacePackageVersionProbe

    init(probe: WorkspacePackageVersionProbe = WorkspacePackageVersionProbe()) {
        self.probe = probe
    }

    func readValidated(
        from location: WorkspaceDocumentLocation
    ) async throws -> WorkspaceDocumentValidatedPackage {
        // Both probes and the package open validate the same manifest bytes: decode them once.
        try WorkspaceManifestDecodeScope.ensuring { _ in
            try readValidatedInDecodeScope(from: location)
        }
    }

    private func readValidatedInDecodeScope(
        from location: WorkspaceDocumentLocation
    ) throws -> WorkspaceDocumentValidatedPackage {
        try Task.checkCancellation()
        let before = try probe.observeSynchronously(location.canonicalURL)
        guard before.condition == .valid,
              before.location.canonicalURL == location.canonicalURL,
              location.fileObjectIdentity == nil
                || before.location.fileObjectIdentity == location.fileObjectIdentity else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-read-location-not-valid"
            )
        }

        let manifestData = try Data(
            contentsOf: MacScopeDocumentPackage.manifestURL(
                in: location.canonicalURL
            )
        )
        let contents = try MacScopeDocumentPackage.openPackage(
            from: location.canonicalURL
        )
        let after = try probe.observeSynchronously(location.canonicalURL)
        guard after == before,
              after.manifestSHA256 == MacScopeDocumentPackage.fileHash(
                for: manifestData
              ) else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-read-changed-during-validation"
            )
        }
        return WorkspaceDocumentValidatedPackage(
            manifestData: manifestData,
            attachmentsByBinaryID: contents.attachmentsByBinaryID,
            reconstructionState: contents.reconstructionState,
            reconstructionAttachmentSources: contents.reconstructionAttachmentSources,
            instructionSidecarData: contents.instructionSidecarData,
            observation: after
        )
    }
}

actor WorkspaceDocumentIO {
    private let probe: any WorkspacePackageVersionProbing
    private let reader: any WorkspaceDocumentReading
    private let publisher: any WorkspaceDocumentPublishing
    private let monitor: any WorkspaceDocumentChangeMonitoring
    private var operationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        probe: any WorkspacePackageVersionProbing,
        reader: any WorkspaceDocumentReading,
        publisher: any WorkspaceDocumentPublishing,
        monitor: any WorkspaceDocumentChangeMonitoring
    ) {
        self.probe = probe
        self.reader = reader
        self.publisher = publisher
        self.monitor = monitor
    }

    init() {
        let productionProbe = WorkspacePackageVersionProbe()
        self.probe = productionProbe
        self.reader = WorkspaceDocumentReader(probe: productionProbe)
        self.publisher = WorkspaceDocumentPublisher(probe: productionProbe)
        self.monitor = WorkspaceDocumentChangeMonitor()
    }

    func observe(_ url: URL) async throws -> WorkspacePackageExternalVersion {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        return try await probe.observe(url)
    }

    func readValidated(
        from location: WorkspaceDocumentLocation
    ) async throws -> WorkspaceDocumentValidatedPackage {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        return try await reader.readValidated(from: location)
    }

    func changes(
        at location: WorkspaceDocumentLocation
    ) async -> WorkspaceDocumentChangeFeed {
        monitor.changes(at: location)
    }

    func stage(
        _ payload: WorkspaceDocumentPackagePayload,
        in parentDirectory: URL
    ) async throws -> WorkspaceDocumentStagedPackage {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        return try await publisher.stage(payload, in: parentDirectory)
    }

    func publish(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        expecting expected: WorkspacePackageExternalVersion
    ) async throws -> WorkspaceDocumentPublishReceipt {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        return try await publisher.publish(
            staged,
            to: destination,
            expecting: expected
        )
    }

    func discard(_ staged: WorkspaceDocumentStagedPackage) async {
        await acquireOperation()
        defer { releaseOperation() }
        await publisher.discard(staged)
    }

    private func acquireOperation() async {
        if !operationActive {
            operationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationActive = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}
