import Foundation

/// Canonical integrity rules shared by evidence acceptance and durable package/database admission.
enum ReconstructionEvidenceIntegrity {
    enum DurableLimits {
        static let maximumAggregateRecordCount = 100_000
        static let maximumCitationsPerEvidence = 100_000
        static let maximumFacetDependenciesPerEvidence = 100_000
        static let maximumSelectedHandleIDsPerReceipt = 100_000
        static let maximumProducerIdentityValueCount = 64
        static let maximumStringUTF8Bytes = 16 * 1_024
        static let maximumMetadataUTF8BytesPerRecord = 64 * 1_024 * 1_024
    }

    enum DurableAdmissionFailure: Error, Equatable, Sendable {
        case aggregateRecordCount
        case collectionCount(field: String)
        case stringUTF8Limit(field: String)
        case aggregateMetadataLimit(record: String)
        case arithmeticOverflow(record: String)
    }

    static func requireDurableCollectionCount(
        _ count: Int,
        field: String
    ) throws {
        guard count <= DurableLimits.maximumAggregateRecordCount else {
            throw DurableAdmissionFailure.collectionCount(field: field)
        }
    }

    /// Applies permanent durable-state bounds before admission allocates identity sets,
    /// dictionaries, grouping tables, or sorted copies. The input arrays already exist at this
    /// seam; this pass itself performs only scalar/count/UTF-8 accounting.
    static func validateDurableBounds(
        projects: [ReconstructionProjectRecord],
        corpusManifests: [ReconstructionCorpusManifest],
        evidence: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        gaps: [ReconstructionEvidenceGap],
        jobs: [ReconstructionJobRecord],
        tasks: [ReconstructionTaskRecord],
        checkpoints: [ReconstructionCheckpoint],
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt],
        finalResults: [ReconstructionFinalResultRecord] = []
    ) throws {
        var aggregateRecordCount = 0

        func requireCollectionCount(_ count: Int, field: String) throws {
            try requireDurableCollectionCount(count, field: field)
        }

        func addRecords(_ count: Int) throws {
            let (sum, overflow) = aggregateRecordCount.addingReportingOverflow(count)
            guard !overflow, sum <= DurableLimits.maximumAggregateRecordCount else {
                throw DurableAdmissionFailure.aggregateRecordCount
            }
            aggregateRecordCount = sum
        }

        try requireCollectionCount(projects.count, field: "projects")
        try addRecords(projects.count)
        try requireCollectionCount(corpusManifests.count, field: "corpus manifests")
        try addRecords(corpusManifests.count)
        try requireCollectionCount(evidence.count, field: "evidence")
        try addRecords(evidence.count)
        try requireCollectionCount(relations.count, field: "evidence relations")
        try addRecords(relations.count)
        try requireCollectionCount(gaps.count, field: "evidence gaps")
        try addRecords(gaps.count)
        try requireCollectionCount(jobs.count, field: "jobs")
        try addRecords(jobs.count)
        try requireCollectionCount(tasks.count, field: "tasks")
        try addRecords(tasks.count)
        try requireCollectionCount(checkpoints.count, field: "checkpoints")
        try addRecords(checkpoints.count)
        try requireCollectionCount(toolReceipts.count, field: "tool receipts")
        try addRecords(toolReceipts.count)
        try requireCollectionCount(modelReceipts.count, field: "model receipts")
        try addRecords(modelReceipts.count)
        try requireCollectionCount(finalResults.count, field: "final results")
        try addRecords(finalResults.count)

        for project in projects {
            try Task.checkCancellation()
            var metadata = MetadataCounter(record: "project")
            try metadata.addScalars(2)
            try metadata.add(project.name, field: "reconstruction project name")
            try metadata.add(project.currentCorpusManifestSHA256)
        }

        for manifest in corpusManifests {
            try Task.checkCancellation()
            try requireCollectionCount(manifest.artifacts.count, field: "manifest artifacts")
            try requireCollectionCount(manifest.relations.count, field: "manifest relations")
            try addRecords(manifest.artifacts.count)
            try addRecords(manifest.relations.count)
            var metadata = MetadataCounter(record: "corpus manifest")
            try metadata.addScalars(2)
            try metadata.add(manifest.canonicalSHA256)
            try metadata.addElements(manifest.artifacts.count, bytesEach: 32)
            try metadata.addElements(manifest.relations.count, bytesEach: 32)
            for occurrence in manifest.artifacts {
                try Task.checkCancellation()
                try metadata.addScalars(4)
                try metadata.add(occurrence.contentIdentity.digest)
                try metadata.add(occurrence.originalName, field: "artifact name")
                try metadata.add(occurrence.diagnostic)
                try requireCollectionCount(occurrence.roles.count, field: "artifact roles")
                try metadata.addElements(occurrence.roles.count, bytesEach: 8)
            }
            for relation in manifest.relations {
                try Task.checkCancellation()
                try metadata.addScalars(5)
                try metadata.add(relation.canonicalSHA256)
                try metadata.add(
                    relation.unresolvedLocator,
                    field: "unresolved dependency locator"
                )
            }
        }

        for record in evidence {
            try Task.checkCancellation()
            guard record.citations.count <= DurableLimits.maximumCitationsPerEvidence else {
                throw DurableAdmissionFailure.collectionCount(field: "evidence citations")
            }
            guard record.facetDependencies.count
                    <= DurableLimits.maximumFacetDependenciesPerEvidence else {
                throw DurableAdmissionFailure.collectionCount(field: "evidence facets")
            }
            try addRecords(record.citations.count)
            try addRecords(record.facetDependencies.count)
            var metadata = MetadataCounter(record: "evidence")
            try metadata.addScalars(8)
            try metadata.add(record.operationID, field: "evidence operation ID")
            try metadata.add(record.payloadSHA256)
            try metadata.add(record.diagnostic)
            try metadata.add(subject: record.subject)
            try metadata.add(producer: record.producer)
            try metadata.addElements(record.citations.count, bytesEach: 32)
            try metadata.addElements(record.facetDependencies.count, bytesEach: 16)
            for facet in record.facetDependencies {
                try Task.checkCancellation()
                try metadata.add(facet.facetIdentity, field: "facet identity")
                try metadata.add(facet.fingerprintSHA256)
            }
            for citation in record.citations {
                try Task.checkCancellation()
                try metadata.addScalars(2)
                try metadata.add(citation.locator, field: "evidence citation locator")
                if let subject = citation.subject { try metadata.add(subject: subject) }
            }
        }

        for _ in relations {
            try Task.checkCancellation()
            var metadata = MetadataCounter(record: "evidence relation")
            try metadata.addScalars(4)
        }

        for gap in gaps {
            try Task.checkCancellation()
            var metadata = MetadataCounter(record: "evidence gap")
            try metadata.addScalars(2)
            try metadata.add(gap.operationID, field: "gap operation ID")
            try metadata.add(gap.reason)
            try metadata.add(gap.canonicalSHA256)
            try metadata.add(subject: gap.subject)
        }

        for job in jobs {
            try Task.checkCancellation()
            var metadata = MetadataCounter(record: "job")
            let durableScalarCount: Int
            switch job.recordSchemaVersion {
            case 1:
                durableScalarCount = 8
            case 2:
                durableScalarCount = 10
            case 3, 4, 5, 6:
                durableScalarCount = job.pauseContext == nil ? 10 : 13
            default:
                preconditionFailure("strict job decoding admitted an unsupported schema")
            }
            try metadata.addScalars(durableScalarCount)
            try metadata.add(job.objective, field: "job objective")
            try metadata.add(job.objectiveSHA256)
            try metadata.add(job.creationCorpusManifestSHA256)
            try metadata.add(job.terminalReason)
            if let focus = job.focus { try metadata.add(subject: focus) }
            if let profile = job.sourceProfileID { try metadata.add(profile, field: "source profile") }
            if let scope = job.featureScope {
                try metadata.add(subject: .function(scope.feature))
                try metadata.addElements(scope.acceptedEvidenceIDs.count + scope.dependencyBasisEvidenceIDs.count
                    + scope.dependencies.reduce(0) { $0 + $1.evidenceIDs.count }, bytesEach: 16)
                try metadata.addScalars(8 + 4 * scope.scenarios.count + 4 * scope.dependencies.count)
                for scenario in scope.scenarios { try metadata.add(scenario.suiteSHA256) }
                for dependency in scope.dependencies {
                    try metadata.add(dependency.symbol, field: "feature dependency symbol")
                    if let subject = dependency.subject { try metadata.add(subject: subject) }
                }
                try metadata.add(scope.observationContract.contractID, field: "observation contract")
                try metadata.add(scope.admittedAtCheckpointSHA256)
                try metadata.add(scope.evidenceFrontierSHA256)
                try metadata.add(scope.canonicalSHA256)
            }
        }

        for task in tasks {
            try Task.checkCancellation()
            try requireCollectionCount(
                task.identity.dependencyTaskIDs.count,
                field: "task dependencies"
            )
            var metadata = MetadataCounter(record: "task")
            try metadata.addScalars(5)
            try metadata.add(
                task.identity.operationContractIdentity,
                field: "operation contract identity"
            )
            try metadata.add(task.identity.canonicalSHA256)
            try metadata.add(task.diagnostic)
            try metadata.addElements(task.identity.dependencyTaskIDs.count, bytesEach: 16)
            if let subject = task.identity.subject { try metadata.add(subject: subject) }
        }

        for checkpoint in checkpoints {
            try Task.checkCancellation()
            try requireCollectionCount(checkpoint.pendingTaskIDs.count, field: "pending tasks")
            try requireCollectionCount(checkpoint.runningTaskIDs.count, field: "running tasks")
            try requireCollectionCount(checkpoint.completedTaskIDs.count, field: "completed tasks")
            try requireCollectionCount(checkpoint.failedTaskIDs.count, field: "failed tasks")
            try requireCollectionCount(checkpoint.blockedTaskIDs.count, field: "blocked tasks")
            try requireCollectionCount(checkpoint.modelReceiptIDs.count, field: "model receipts")
            try requireCollectionCount(checkpoint.toolReceiptIDs.count, field: "tool receipts")
            var metadata = MetadataCounter(record: "checkpoint")
            try metadata.addScalars(8)
            try metadata.add(checkpoint.parentCheckpointSHA256)
            try metadata.add(checkpoint.corpusManifestSHA256)
            try metadata.add(checkpoint.evidenceFrontierSHA256)
            try metadata.add(checkpoint.unresolvedEvidenceGapSHA256)
            try metadata.add(checkpoint.canonicalSHA256)
            try metadata.add(checkpoint.terminalReason)
            try metadata.addElements(checkpoint.pendingTaskIDs.count, bytesEach: 16)
            try metadata.addElements(checkpoint.runningTaskIDs.count, bytesEach: 16)
            try metadata.addElements(checkpoint.completedTaskIDs.count, bytesEach: 16)
            try metadata.addElements(checkpoint.failedTaskIDs.count, bytesEach: 16)
            try metadata.addElements(checkpoint.blockedTaskIDs.count, bytesEach: 16)
            try metadata.addElements(checkpoint.modelReceiptIDs.count, bytesEach: 16)
            try metadata.addElements(checkpoint.toolReceiptIDs.count, bytesEach: 16)
        }

        for receipt in toolReceipts {
            try Task.checkCancellation()
            if let read = receipt.evidenceReadAuthority {
                try read.validate(receipt: receipt)
            }
            try requireCollectionCount(
                receipt.outputEvidenceIDs.count,
                field: "tool receipt output evidence"
            )
            var metadata = MetadataCounter(record: "tool receipt")
            try metadata.addScalars(7)
            try metadata.add(receipt.requestIdentitySHA256)
            try metadata.add(receipt.canonicalSHA256)
            try metadata.add(receipt.diagnostic)
            try metadata.add(producer: receipt.producer)
            try metadata.addElements(receipt.outputEvidenceIDs.count, bytesEach: 16)
            if let read = receipt.evidenceReadAuthority {
                try metadata.addElements(try ReconstructionCanonicalJSON.encode(read).count, bytesEach: 1)
            }
        }

        for receipt in modelReceipts {
            try Task.checkCancellation()
            guard receipt.selectedHandleIDs.count
                    <= DurableLimits.maximumSelectedHandleIDsPerReceipt else {
                throw DurableAdmissionFailure.collectionCount(field: "selected handle IDs")
            }
            try requireCollectionCount(
                receipt.acceptedEvidenceIDs.count,
                field: "model receipt accepted evidence"
            )
            var metadata = MetadataCounter(record: "model receipt")
            try metadata.addScalars(7)
            try metadata.add(receipt.requestIdentitySHA256)
            try metadata.add(receipt.canonicalSHA256)
            try metadata.add(receipt.diagnostic)
            try metadata.add(producer: receipt.producer)
            try metadata.addElements(receipt.selectedHandleIDs.count, bytesEach: 8)
            try metadata.addElements(receipt.acceptedEvidenceIDs.count, bytesEach: 16)
            for handleID in receipt.selectedHandleIDs {
                try Task.checkCancellation()
                try metadata.add(handleID, field: "selected handle ID")
            }
        }

        for result in finalResults {
            try Task.checkCancellation()
            try requireCollectionCount(
                result.citedEvidenceIDs.count,
                field: "final result cited evidence"
            )
            try addRecords(result.citedEvidenceIDs.count)
            var metadata = MetadataCounter(record: "final result")
            try metadata.addScalars(10)
            try metadata.add(result.requestIdentitySHA256)
            try metadata.add(result.payloadSHA256)
            try metadata.add(result.canonicalSHA256)
            try metadata.add(producer: result.producer)
            try metadata.addElements(result.payloadUTF8.count, bytesEach: 1)
            try metadata.addElements(result.citedEvidenceIDs.count, bytesEach: 16)
        }
    }

    static func canonicalProducerSHA256(
        _ producer: ReconstructionProducerIdentity
    ) throws -> String {
        struct Preimage: Encodable {
            let schemaVersion: Int
            let macScopeBuildIdentity: String
            let macScopeSourceIdentity: String
            let operationIdentity: String
            let registryIdentity: String
            let protocolIdentity: String
            let nativeProviderIdentity: String?
            let nativeCapabilityIdentities: [String]
            let modelKey: String?
            let endpointOrigin: String?
            let observedModelInventorySHA256: String?
            let observedConfigurationSHA256: String?
            let toolchainIdentity: String?
        }

        try Task.checkCancellation()
        let digest = try ReconstructionCanonicalJSON.sha256(of: Preimage(
            schemaVersion: producer.schemaVersion,
            macScopeBuildIdentity: producer.macScopeBuildIdentity,
            macScopeSourceIdentity: producer.macScopeSourceIdentity,
            operationIdentity: producer.operationIdentity,
            registryIdentity: producer.registryIdentity,
            protocolIdentity: producer.protocolIdentity,
            nativeProviderIdentity: producer.nativeProviderIdentity,
            nativeCapabilityIdentities: producer.nativeCapabilityIdentities,
            modelKey: producer.modelKey,
            endpointOrigin: producer.endpointOrigin,
            observedModelInventorySHA256: producer.observedModelInventorySHA256,
            observedConfigurationSHA256: producer.observedConfigurationSHA256,
            toolchainIdentity: producer.toolchainIdentity
        ))
        try Task.checkCancellation()
        return digest
    }

    static func canonicalGapSHA256(
        _ gap: ReconstructionEvidenceGap
    ) throws -> String {
        struct Preimage: Encodable {
            let schemaVersion: Int
            let gapID: UUID
            let subject: ReconstructionSubjectCoordinate
            let operationID: String
            let reason: ReconstructionDiagnostic
        }

        try Task.checkCancellation()
        let digest = try ReconstructionCanonicalJSON.sha256(of: Preimage(
            schemaVersion: ReconstructionEvidenceGap.schemaVersion,
            gapID: gap.gapID,
            subject: gap.subject,
            operationID: gap.operationID,
            reason: gap.reason
        ))
        try Task.checkCancellation()
        return digest
    }

    static func producerContainsOnlyDurableBoundedIdentity(
        _ producer: ReconstructionProducerIdentity
    ) -> Bool {
        guard producer.nativeCapabilityIdentities.count
                <= DurableLimits.maximumProducerIdentityValueCount,
              producerIdentityValueCount(producer)
                <= DurableLimits.maximumProducerIdentityValueCount else { return false }
        let values = producerIdentityValues(producer)

        guard values.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else { return false }
        return values.allSatisfy { value in
            guard !value.isEmpty,
                  value.utf8.count <= 1_024,
                  !value.unicodeScalars.contains(where: {
                      $0.value < 0x20 || $0.value == 0x7f
                  }) else { return false }
            let lowercased = value.lowercased()
            let forbiddenFragments = [
                "/users/", "/home/", "\\users\\", "$home", "file://", "/var/folders/",
                "bearer ", "api_key", "apikey", "token=", "password=", "secret=", "sk-",
                "pid=", "pid:", "processid", "process_id", "process-id",
                "connectionid", "connection_id", "connection-id",
            ]
            guard !forbiddenFragments.contains(where: lowercased.contains) else { return false }
            return !containsPointerLikeIdentity(lowercased)
        }
    }

    static func producerIdentityValues(
        _ producer: ReconstructionProducerIdentity
    ) -> [String] {
        [
            producer.macScopeBuildIdentity,
            producer.macScopeSourceIdentity,
            producer.operationIdentity,
            producer.registryIdentity,
            producer.protocolIdentity,
            producer.nativeProviderIdentity,
            producer.modelKey,
            producer.endpointOrigin,
            producer.observedModelInventorySHA256,
            producer.observedConfigurationSHA256,
            producer.toolchainIdentity,
        ].compactMap { $0 } + producer.nativeCapabilityIdentities
    }

    private static func producerIdentityValueCount(
        _ producer: ReconstructionProducerIdentity
    ) -> Int {
        let optionalValues: [String?] = [
            producer.nativeProviderIdentity,
            producer.modelKey,
            producer.endpointOrigin,
            producer.observedModelInventorySHA256,
            producer.observedConfigurationSHA256,
            producer.toolchainIdentity,
        ]
        return 5 + optionalValues.compactMap { $0 }.count
            + producer.nativeCapabilityIdentities.count
    }

    private static func containsPointerLikeIdentity(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 10 else { return false }
        for index in 0...(bytes.count - 10) where bytes[index] == 48 && bytes[index + 1] == 120 {
            let suffix = bytes[(index + 2)...]
            if suffix.prefix(8).allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }) {
                return true
            }
        }
        return false
    }

    private struct MetadataCounter {
        let record: String
        private(set) var bytes = 0

        mutating func add(_ value: String?, field: String? = nil) throws {
            guard let value else { return }
            let count = value.utf8.count
            if let field, count > DurableLimits.maximumStringUTF8Bytes {
                throw DurableAdmissionFailure.stringUTF8Limit(field: field)
            }
            try addBytes(count)
        }

        mutating func add(_ diagnostic: ReconstructionDiagnostic?) throws {
            guard let diagnostic else { return }
            try add(diagnostic.text, field: "diagnostic")
        }

        mutating func add(subject: ReconstructionSubjectCoordinate) throws {
            try addScalars(3)
            switch subject {
            case .artifact(let coordinate):
                try add(coordinate.contentIdentity.digest)
            case .image(let coordinate):
                try add(coordinate.artifact.contentIdentity.digest)
                try add(coordinate.analysisFingerprintSHA256)
                try add(coordinate.image.machOIdentity?.selectedSliceSHA256)
                try addScalars(5)
            case .function(let coordinate):
                try add(coordinate.artifact.contentIdentity.digest)
                try add(coordinate.analysisFingerprintSHA256)
                try add(coordinate.image.machOIdentity?.selectedSliceSHA256)
                try add(coordinate.symbolHint, field: "function symbol hint")
                try addScalars(9)
            }
        }

        mutating func add(producer: ReconstructionProducerIdentity) throws {
            guard ReconstructionEvidenceIntegrity.producerIdentityValueCount(producer)
                    <= DurableLimits.maximumProducerIdentityValueCount else {
                throw DurableAdmissionFailure.collectionCount(
                    field: "producer identity values"
                )
            }
            try add(producer.macScopeBuildIdentity, field: "MacScope build identity")
            try add(producer.macScopeSourceIdentity, field: "MacScope source identity")
            try add(producer.operationIdentity, field: "producer operation identity")
            try add(producer.registryIdentity, field: "producer registry identity")
            try add(producer.protocolIdentity, field: "producer protocol identity")
            try add(producer.nativeProviderIdentity, field: "native provider identity")
            try add(producer.modelKey, field: "model key")
            try add(producer.endpointOrigin, field: "endpoint origin")
            try add(producer.observedModelInventorySHA256)
            try add(producer.observedConfigurationSHA256)
            try add(producer.toolchainIdentity, field: "toolchain identity")
            try add(producer.canonicalSHA256)
            try addElements(producer.nativeCapabilityIdentities.count, bytesEach: 8)
            for identity in producer.nativeCapabilityIdentities {
                try Task.checkCancellation()
                try add(identity, field: "native capability identity")
            }
        }

        mutating func addScalars(_ count: Int) throws {
            try addElements(count, bytesEach: 8)
        }

        mutating func addElements(_ count: Int, bytesEach: Int) throws {
            let (amount, overflow) = count.multipliedReportingOverflow(by: bytesEach)
            guard !overflow else {
                throw DurableAdmissionFailure.arithmeticOverflow(record: record)
            }
            try addBytes(amount)
        }

        private mutating func addBytes(_ count: Int) throws {
            let (sum, overflow) = bytes.addingReportingOverflow(count)
            guard !overflow else {
                throw DurableAdmissionFailure.arithmeticOverflow(record: record)
            }
            guard sum <= DurableLimits.maximumMetadataUTF8BytesPerRecord else {
                throw DurableAdmissionFailure.aggregateMetadataLimit(record: record)
            }
            bytes = sum
        }
    }
}
