import CryptoKit
import Foundation

@testable import MacScope

/// The closed installed-product package catalog. Keep the raw values sorted because the generated
/// oracle is reviewed and compared byte-for-byte by the host-independent governance gate.
enum Task10InstalledScenario: String, CaseIterable {
    case activeExecutingReads = "active-executing-reads"
    case activeRetrieving = "active-retrieving"
    case checkpointStale = "checkpoint-stale"
    case navigationCurrent = "navigation-current"
    case navigationStale = "navigation-stale"
    case noJob = "no-job"
    case pausedModelUnavailableAwaitingModel = "paused-model-unavailable-awaiting-model"
    case pausedUserRetrieving = "paused-user-retrieving"
    case terminalCompleted = "terminal-completed"

    var workspaceName: String {
        "Task 10 \(rawValue)"
    }

    var expectedJobState: ReconstructionJobState? {
        switch self {
        case .activeExecutingReads:
            .executingReads
        case .activeRetrieving, .checkpointStale, .navigationCurrent, .navigationStale:
            .retrieving
        case .noJob:
            nil
        case .pausedModelUnavailableAwaitingModel, .pausedUserRetrieving:
            .paused
        case .terminalCompleted:
            .completed
        }
    }

    var carriesRichPresentationTruth: Bool {
        switch self {
        case .checkpointStale, .navigationCurrent, .navigationStale:
            true
        default:
            false
        }
    }

    var requiresProductionContinuationGraph: Bool {
        switch self {
        case .activeExecutingReads, .activeRetrieving,
             .pausedModelUnavailableAwaitingModel, .pausedUserRetrieving:
            true
        default:
            false
        }
    }

    var expectedCheckpointFreshness: String? {
        guard expectedJobState != nil else { return nil }
        return self == .checkpointStale ? "stale" : "current"
    }

    var expectedNavigableEvidenceID: UUID? {
        self == .navigationCurrent
            ? Task10InstalledScenarioSeedPackage.navigableEvidenceID
            : nil
    }

    var expectedCurrentGapOperationID: String? {
        self == .navigationCurrent
            ? ReconstructionOperationID.evidenceQuery.rawValue
            : nil
    }

    var exposesPrivacyCanaries: Bool { self == .navigationCurrent }

    var pauseCause: ReconstructionJobPauseCause? {
        switch self {
        case .pausedModelUnavailableAwaitingModel:
            .modelUnavailable
        case .pausedUserRetrieving:
            .pausedByUser
        default:
            nil
        }
    }

    var resumeTarget: ReconstructionJobState? {
        switch self {
        case .pausedModelUnavailableAwaitingModel:
            .awaitingModel
        case .pausedUserRetrieving:
            .retrieving
        default:
            nil
        }
    }
}

struct Task10InstalledScenarioSeedPackage {
    private static let documentID = fixedUUID("10000000-0000-0000-0000-000000000001")
    private static let workspaceID = fixedUUID("10000000-0000-0000-0000-000000000002")
    private static let binaryID = fixedUUID("10000000-0000-0000-0000-000000000003")
    private static let startingBinaryID = fixedUUID("10000000-0000-0000-0000-000000000031")
    private static let startingImageSlot = ImageSlot(rawValue: 1)
    private static let startingFunctionID = fixedUUID("10000000-0000-0000-0000-000000000032")
    private static let projectID = fixedUUID("10000000-0000-0000-0000-000000000004")
    private static let occurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: fixedUUID("10000000-0000-0000-0000-000000000005")
    )
    private static let duplicateOccurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: fixedUUID("10000000-0000-0000-0000-000000000017")
    )
    private static let sourceOccurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: fixedUUID("10000000-0000-0000-0000-000000000018")
    )
    private static let headerOccurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: fixedUUID("10000000-0000-0000-0000-000000000019")
    )
    private static let resourceOccurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: fixedUUID("10000000-0000-0000-0000-000000000020")
    )
    private static let diagnosticOccurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: fixedUUID("10000000-0000-0000-0000-000000000021")
    )
    private static let duplicateResourceOccurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: fixedUUID("10000000-0000-0000-0000-000000000022")
    )
    private static let jobID = fixedUUID("10000000-0000-0000-0000-000000000006")
    private static let firstCheckpointID = fixedUUID("10000000-0000-0000-0000-000000000007")
    private static let secondCheckpointID = fixedUUID("10000000-0000-0000-0000-000000000008")
    private static let taskID = fixedUUID("10000000-0000-0000-0000-000000000009")
    static let navigableEvidenceID = fixedUUID("10000000-0000-0000-0000-000000000030")
    private static let gapID = fixedUUID("10000000-0000-0000-0000-000000000012")
    private static let currentOccurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: fixedUUID("10000000-0000-0000-0000-000000000013")
    )
    private static let toolReceiptID = fixedUUID("10000000-0000-0000-0000-000000000014")
    private static let functionStartAddress: UInt64 = 0x1_0000_0000
    private static let functionEndAddress: UInt64 = 0x1_0000_0008
    private static let startingFunctionStartAddress: UInt64 = 0x1_0000_1000
    private static let startingFunctionEndAddress: UInt64 = 0x1_0000_1008
    private static let currentAnalysisFingerprintSHA256 = String(repeating: "3", count: 64)
    private static let staleAnalysisFingerprintSHA256 = String(repeating: "4", count: 64)
    private static let binaryBytes = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01])
    // This persisted navigation image is raw data, not a Mach-O. A synthetic fat
    // header is unsafe here: Xcode's resource strip step byte-swaps its contents.
    private static let startingBinaryBytes = Data("T10START".utf8)
    private static let corpusBytes = Data("Task 10 installed deterministic corpus\n".utf8)
    private static let sourceBytes = Data("int task10_fixture(void) { return 10; }\n".utf8)
    private static let headerBytes = Data("int task10_fixture(void);\n".utf8)
    private static let resourceBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    private static let diagnosticBytes = Data("Task 10 deterministic diagnostic\n".utf8)
    private static let objective = "Reconstruct the deterministic installed fixture"
    private static let timestamp = Date(timeIntervalSince1970: 1_725_000_000)

    static let rawPathPrivacyCanary = "/fixtures/task10-installed.bin"
    static let rawPromptPrivacyCanary = "MACSCOPE_TASK10_RAW_PROMPT_CANARY_DO_NOT_EXPOSE"
    static let rawPseudocodePrivacyCanary = "MACSCOPE_TASK10_RAW_PSEUDOCODE_CANARY_DO_NOT_EXPOSE"

    let scenario: Task10InstalledScenario
    let rootURL: URL
    let packageURL: URL

    var expectedJobID: UUID? {
        scenario == .noJob ? nil : Self.jobID
    }

    var expectedCorpusOccurrenceCount: Int { scenario == .checkpointStale ? 1 : 7 }
    var expectedCorpusUniqueContentCount: Int { scenario == .checkpointStale ? 1 : 5 }
    var expectedCorpusRelationCount: Int { scenario == .checkpointStale ? 0 : 3 }
    var expectedCorpusUnresolvedRelationCount: Int { scenario == .checkpointStale ? 0 : 2 }
    var expectedTaskCount: Int {
        scenario.requiresProductionContinuationGraph ? 3
            : (scenario.carriesRichPresentationTruth ? 1 : 0)
    }
    var expectedEvidenceCount: Int { scenario.carriesRichPresentationTruth ? 13 : 0 }
    var expectedEvidenceCurrentCount: Int { scenario.carriesRichPresentationTruth ? 4 : 0 }
    var expectedEvidenceHistoricalCount: Int { scenario.carriesRichPresentationTruth ? 3 : 0 }
    var expectedEvidenceStaleCount: Int { scenario.carriesRichPresentationTruth ? 3 : 0 }
    var expectedEvidenceUnavailableCount: Int { scenario.carriesRichPresentationTruth ? 3 : 0 }
    var expectedGapCount: Int { scenario.carriesRichPresentationTruth ? 1 : 0 }
    var expectedFunctionAddress: UInt64? {
        scenario == .navigationCurrent || scenario == .navigationStale
            ? Self.functionStartAddress
            : nil
    }

    /// `navigation-current` must begin on a different persisted image.  A same-image address
    /// change cannot prove that Reveal Source transfers image focus back to the evidence owner.
    var expectedStartingImageName: String? {
        scenario == .navigationCurrent ? "Installed starting fixture" : nil
    }

    var expectedStartingFunctionAddress: UInt64? {
        scenario == .navigationCurrent ? Self.startingFunctionStartAddress : nil
    }

    static func make(_ scenario: Task10InstalledScenario) throws -> Self {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-Task10-Installed-Scenario-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        let sourceURL = rootURL.appendingPathComponent("fixture.bin")
        let referenceSourceURL = rootURL.appendingPathComponent("implementation.c")
        let referenceHeaderURL = rootURL.appendingPathComponent("contract.h")
        let resourceURL = rootURL.appendingPathComponent("fixture.png")
        let diagnosticURL = rootURL.appendingPathComponent("failure.crash")
        for (url, bytes) in [
            (sourceURL, corpusBytes),
            (referenceSourceURL, sourceBytes),
            (referenceHeaderURL, headerBytes),
            (resourceURL, resourceBytes),
            (diagnosticURL, diagnosticBytes),
        ] {
            try bytes.write(to: url, options: .atomic)
        }
        let contentIdentity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: sha256(corpusBytes),
            byteCount: UInt64(corpusBytes.count)
        )
        let sourceIdentity = try Self.contentIdentity(for: sourceBytes)
        let headerIdentity = try Self.contentIdentity(for: headerBytes)
        let resourceIdentity = try Self.contentIdentity(for: resourceBytes)
        let diagnosticIdentity = try Self.contentIdentity(for: diagnosticBytes)
        let occurrences = try [
            ReconstructionArtifactOccurrenceRecord(
                occurrenceID: occurrenceID,
                contentIdentity: contentIdentity,
                kind: .opaque,
                roles: [.primaryTarget],
                executableMode: false,
                originalName: "fixture.bin",
                diagnostic: nil
            ),
            ReconstructionArtifactOccurrenceRecord(
                occurrenceID: duplicateOccurrenceID,
                contentIdentity: contentIdentity,
                kind: .opaque,
                roles: [.testInput],
                executableMode: false,
                originalName: "fixture-duplicate.bin",
                diagnostic: nil
            ),
            ReconstructionArtifactOccurrenceRecord(
                occurrenceID: sourceOccurrenceID,
                contentIdentity: sourceIdentity,
                kind: .source,
                roles: [.referenceSource],
                executableMode: false,
                originalName: "implementation.c",
                diagnostic: nil
            ),
            ReconstructionArtifactOccurrenceRecord(
                occurrenceID: headerOccurrenceID,
                contentIdentity: headerIdentity,
                kind: .header,
                roles: [.referenceHeader],
                executableMode: false,
                originalName: "contract.h",
                diagnostic: nil
            ),
            ReconstructionArtifactOccurrenceRecord(
                occurrenceID: resourceOccurrenceID,
                contentIdentity: resourceIdentity,
                kind: .resource,
                roles: [.resource],
                executableMode: false,
                originalName: "fixture.png",
                diagnostic: nil
            ),
            ReconstructionArtifactOccurrenceRecord(
                occurrenceID: diagnosticOccurrenceID,
                contentIdentity: diagnosticIdentity,
                kind: .diagnostic,
                roles: [.diagnosticEvidence],
                executableMode: false,
                originalName: "failure.crash",
                diagnostic: nil
            ),
            ReconstructionArtifactOccurrenceRecord(
                occurrenceID: duplicateResourceOccurrenceID,
                contentIdentity: resourceIdentity,
                kind: .resource,
                roles: [.auxiliary],
                executableMode: false,
                originalName: "fixture-copy.png",
                diagnostic: nil
            ),
        ]
        let relations = try [
            makeCorpusRelation(
                relationID: fixedUUID("10000000-0000-0000-0000-000000000023"),
                kind: .sourceFor,
                sourceOccurrenceID: sourceOccurrenceID,
                targetOccurrenceID: occurrenceID,
                unresolvedLocator: nil,
                evidenceSource: .sourceMetadata
            ),
            makeCorpusRelation(
                relationID: fixedUUID("10000000-0000-0000-0000-000000000024"),
                kind: .unresolvedDependency,
                sourceOccurrenceID: occurrenceID,
                targetOccurrenceID: nil,
                unresolvedLocator: "libtask10-missing-a.dylib",
                evidenceSource: .loader
            ),
            makeCorpusRelation(
                relationID: fixedUUID("10000000-0000-0000-0000-000000000025"),
                kind: .unresolvedDependency,
                sourceOccurrenceID: occurrenceID,
                targetOccurrenceID: nil,
                unresolvedLocator: "libtask10-missing-b.dylib",
                evidenceSource: .dependencyCommand
            ),
        ]
        let provisionalManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: occurrences,
            relations: relations,
            canonicalSHA256: sha256(Data("provisional corpus manifest".utf8))
        )
        let corpusManifestSHA256 = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            of: provisionalManifest
        )
        let corpusManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: occurrences,
            relations: relations,
            canonicalSHA256: corpusManifestSHA256
        )
        let project = try ReconstructionProjectRecord(
            projectID: projectID,
            name: "Task 10 installed scenario",
            currentCorpusManifestSHA256: corpusManifestSHA256
        )

        let currentArtifact = ReconstructionArtifactCoordinate(
            occurrenceID: occurrenceID,
            contentIdentity: contentIdentity
        )
        let image = ReconstructionImageBinding(
            binaryID: binaryID,
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )
        let currentFunction = try ReconstructionFunctionCoordinate(
            artifact: currentArtifact,
            image: image,
            analysisFingerprintSHA256: currentAnalysisFingerprintSHA256,
            startAddress: functionStartAddress,
            endAddressExclusive: functionEndAddress,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
            functionUUIDHint: nil,
            symbolHint: "task10_fixture_entry"
        )
        guard let persistedFunctionID = ReconstructionReboundFunctionAuthority.expectedFunctionID(
            for: currentFunction
        ) else {
            throw NSError(
                domain: "MacScopeTests.Task10InstalledScenarioFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The function authority is not reboundable."]
            )
        }
        let inputFingerprint = try AnalysisInputFingerprint(
            imageSlot: .primary,
            binaryID: binaryID,
            binaryName: "Installed fixture",
            binaryPath: rawPathPrivacyCanary,
            selectedSliceIndex: nil,
            artifactIdentity: nil,
            imageByteCount: UInt64(binaryBytes.count),
            imageBytesSHA256: sha256(binaryBytes),
            facets: [],
            overallSHA256: currentAnalysisFingerprintSHA256
        )
        let startingInputFingerprint = try AnalysisInputFingerprint(
            imageSlot: startingImageSlot,
            binaryID: startingBinaryID,
            binaryName: "Installed starting fixture",
            binaryPath: "/fixtures/task10-installed-start.bin",
            selectedSliceIndex: nil,
            artifactIdentity: nil,
            imageByteCount: UInt64(startingBinaryBytes.count),
            imageBytesSHA256: sha256(startingBinaryBytes),
            facets: [],
            overallSHA256: sha256(Data("Task 10 installed starting image".utf8))
        )

        let state = try makeState(
            scenario: scenario,
            project: project,
            corpusManifest: corpusManifest,
            contentIdentity: contentIdentity,
            currentFunction: currentFunction
        )
        let binary = WorkspacePackageBinary(
            id: binaryID,
            displayName: "Installed fixture",
            originalPath: rawPathPrivacyCanary,
            attachmentRelativePath:
                "attachments/\(binaryID.uuidString.lowercased())/task10-installed.bin",
            kind: "Raw data",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: binaryBytes),
            fileSize: Int64(binaryBytes.count)
        )
        let startingBinary = WorkspacePackageBinary(
            id: startingBinaryID,
            displayName: "Installed starting fixture",
            originalPath: "/fixtures/task10-installed-start.bin",
            attachmentRelativePath:
                "attachments/\(startingBinaryID.uuidString.lowercased())/task10-installed-start.bin",
            kind: "Raw data",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: startingBinaryBytes),
            fileSize: Int64(startingBinaryBytes.count),
            slot: startingImageSlot
        )
        let currentImageAnalysis = WorkspacePackageAnalysis(
            functions: [
                FunctionSummary(
                    id: persistedFunctionID,
                    name: "task10_fixture_entry",
                    startAddress: functionStartAddress,
                    endAddress: functionEndAddress,
                    confidence: 1
                ),
            ],
            instructions: [
                InstructionRow(
                    address: functionStartAddress,
                    bytes: "c0 03 5f d6",
                    mnemonic: "ret",
                    operands: "",
                    hasBreakpoint: false,
                    comment: nil
                ),
            ],
            analysisInputFingerprint: inputFingerprint
        )
        let startingImageAnalysis = WorkspacePackageAnalysis(
            functions: [
                FunctionSummary(
                    id: startingFunctionID,
                    name: "task10_starting_fixture_entry",
                    startAddress: startingFunctionStartAddress,
                    endAddress: startingFunctionEndAddress,
                    confidence: 1
                ),
            ],
            instructions: [
                InstructionRow(
                    address: startingFunctionStartAddress,
                    bytes: "c0 03 5f d6",
                    mnemonic: "ret",
                    operands: "",
                    hasBreakpoint: false,
                    comment: nil
                ),
            ],
            analysisInputFingerprint: startingInputFingerprint
        )
        let manifest: WorkspacePackageManifest
        let attachmentsByBinaryID: [UUID: Data]
        if scenario == .navigationCurrent {
            // The seed deliberately remains a v2 multi-image package.  The production
            // WorkspaceStore writer promotes its nonempty reconstruction state to v3; the
            // generated resource, rather than this seed, is the artifact under test.
            manifest = WorkspacePackageManifest(
                formatVersion: WorkspacePackageManifest.multiImageFormatVersion,
                documentID: documentID,
                workspaceUUID: workspaceID,
                workspaceName: scenario.workspaceName,
                createdAt: timestamp,
                modifiedAt: timestamp,
                binaries: [binary, startingBinary],
                analysis: WorkspacePackageAnalysis(),
                imageAnalyses: [
                    WorkspacePackageImageAnalysis(
                        binaryID: binaryID,
                        imageSlot: .primary,
                        analysis: currentImageAnalysis
                    ),
                    WorkspacePackageImageAnalysis(
                        binaryID: startingBinaryID,
                        imageSlot: startingImageSlot,
                        analysis: startingImageAnalysis
                    ),
                ],
                session: WorkspacePackageSession(
                    selectedSidebarItemID: "function:\(startingFunctionID.uuidString)",
                    selectedAddress: startingFunctionStartAddress,
                    selectedTool: .project,
                    editorMode: .disassembly,
                    isInspectorPresented: true,
                    sidebarSearchText: "",
                    updatedAt: timestamp,
                    focusedImageSlot: startingImageSlot
                )
            )
            attachmentsByBinaryID = [
                binaryID: binaryBytes,
                startingBinaryID: startingBinaryBytes,
            ]
        } else {
            manifest = WorkspacePackageManifest(
                documentID: documentID,
                workspaceUUID: workspaceID,
                workspaceName: scenario.workspaceName,
                createdAt: timestamp,
                modifiedAt: timestamp,
                binaries: [binary],
                analysis: currentImageAnalysis,
                session: nil
            )
            attachmentsByBinaryID = [binaryID: binaryBytes]
        }
        let packageURL = rootURL.appendingPathComponent("Seed.mscope", isDirectory: true)
        try MacScopeDocumentPackage.writePackage(
            manifest,
            attachmentsByBinaryID: attachmentsByBinaryID,
            reconstructionState: state,
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: contentIdentity,
                    verifiedURL: sourceURL
                ),
                ReconstructionAttachmentSource(
                    contentIdentity: sourceIdentity,
                    verifiedURL: referenceSourceURL
                ),
                ReconstructionAttachmentSource(
                    contentIdentity: headerIdentity,
                    verifiedURL: referenceHeaderURL
                ),
                ReconstructionAttachmentSource(
                    contentIdentity: resourceIdentity,
                    verifiedURL: resourceURL
                ),
                ReconstructionAttachmentSource(
                    contentIdentity: diagnosticIdentity,
                    verifiedURL: diagnosticURL
                ),
            ],
            to: packageURL
        )
        return Self(scenario: scenario, rootURL: rootURL, packageURL: packageURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func makeState(
        scenario: Task10InstalledScenario,
        project: ReconstructionProjectRecord,
        corpusManifest: ReconstructionCorpusManifest,
        contentIdentity: ReconstructionContentIdentity,
        currentFunction: ReconstructionFunctionCoordinate
    ) throws -> ReconstructionWorkspaceState {
        guard let jobState = scenario.expectedJobState else {
            return try ReconstructionWorkspaceState(
                projects: [project],
                corpusManifests: [corpusManifest],
                evidence: [],
                evidenceRelations: [],
                evidenceGaps: [],
                jobs: [],
                tasks: [],
                checkpoints: [],
                toolReceipts: [],
                modelReceipts: []
            )
        }

        if scenario.carriesRichPresentationTruth {
            return try makeRichState(
                scenario: scenario,
                project: project,
                corpusManifest: corpusManifest,
                contentIdentity: contentIdentity,
                currentFunction: currentFunction
            )
        }

        let frontierSHA256 = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: corpusManifest.canonicalSHA256,
            records: [],
            projectedClassificationsByEvidenceID: [:],
            relations: [],
            gaps: [],
            checkpointRevisionsByID: [:]
        )
        let unresolvedSHA256 = try ReconstructionEvidenceGapFrontier.canonicalSHA256(for: [])
        let budget = try ReconstructionJobBudget(
            maxRounds: 2,
            maxTasks: 8,
            maxEvidenceRecords: 32,
            maxEncodedBytes: 32_768
        )
        let objectiveSHA256 = sha256(Data(objective.utf8))

        // An active enum with an empty DAG is not a production-executable job. Obtain the
        // initial corpus graph from the same transaction as Create, then freeze that pending
        // graph in each active/resumable fixture without inventing completed receipts.
        let tasks = scenario.requiresProductionContinuationGraph
            ? try makeContinuationInitialTasks(
                project: project, corpusManifest: corpusManifest, budget: budget
              )
            : []

        if let pauseCause = scenario.pauseCause, let resumeTarget = scenario.resumeTarget {
            let parent = try ReconstructionCheckpoint.make(
                checkpointID: firstCheckpointID,
                jobID: jobID,
                revision: 0,
                parentCheckpointID: nil,
                parentCheckpointSHA256: nil,
                corpusManifestSHA256: corpusManifest.canonicalSHA256,
                evidenceFrontierSHA256: frontierSHA256,
                pendingTaskIDs: tasks.map(\.identity.taskID),
                runningTaskIDs: [],
                completedTaskIDs: [],
                failedTaskIDs: [],
                blockedTaskIDs: [],
                unresolvedEvidenceGapSHA256: unresolvedSHA256,
                modelReceiptIDs: [],
                toolReceiptIDs: [],
                coordinatorState: resumeTarget,
                terminalReason: nil
            )
            let paused = try ReconstructionCheckpoint.make(
                checkpointID: secondCheckpointID,
                jobID: jobID,
                revision: 1,
                parentCheckpointID: parent.checkpointID,
                parentCheckpointSHA256: parent.canonicalSHA256,
                corpusManifestSHA256: corpusManifest.canonicalSHA256,
                evidenceFrontierSHA256: frontierSHA256,
                pendingTaskIDs: tasks.map(\.identity.taskID),
                runningTaskIDs: [],
                completedTaskIDs: [],
                failedTaskIDs: [],
                blockedTaskIDs: [],
                unresolvedEvidenceGapSHA256: unresolvedSHA256,
                modelReceiptIDs: [],
                toolReceiptIDs: [],
                coordinatorState: .paused,
                terminalReason: nil
            )
            let job = try ReconstructionJobRecord(
                jobID: jobID,
                reconstructionProjectID: projectID,
                objective: objective,
                objectiveSHA256: objectiveSHA256,
                creationCorpusManifestSHA256: corpusManifest.canonicalSHA256,
                state: .paused,
                currentCheckpointID: paused.checkpointID,
                terminalReason: nil,
                budget: budget,
                pauseContext: try ReconstructionJobPauseContext(
                    cause: pauseCause,
                    resumeTarget: resumeTarget
                )
            )
            return try workspaceState(
                project: project,
                corpusManifest: corpusManifest,
                job: job,
                checkpoints: [parent, paused],
                tasks: tasks
            )
        }

        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: firstCheckpointID,
            jobID: jobID,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: corpusManifest.canonicalSHA256,
            evidenceFrontierSHA256: frontierSHA256,
            pendingTaskIDs: tasks.map(\.identity.taskID),
            runningTaskIDs: [],
            completedTaskIDs: [],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: unresolvedSHA256,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: jobState,
            terminalReason: nil
        )
        let job = try ReconstructionJobRecord(
            jobID: jobID,
            reconstructionProjectID: projectID,
            objective: objective,
            objectiveSHA256: objectiveSHA256,
            creationCorpusManifestSHA256: corpusManifest.canonicalSHA256,
            state: jobState,
            currentCheckpointID: checkpoint.checkpointID,
            terminalReason: nil,
            budget: budget
        )
        return try workspaceState(
            project: project,
            corpusManifest: corpusManifest,
            job: job,
            checkpoints: [checkpoint],
            tasks: tasks
        )
    }

    private static func makeContinuationInitialTasks(
        project: ReconstructionProjectRecord,
        corpusManifest: ReconstructionCorpusManifest,
        budget: ReconstructionJobBudget
    ) throws -> [ReconstructionTaskRecord] {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        _ = try database.saveSnapshot(
            workspaceUUID: workspaceID,
            workspaceName: "Task 10 active fixture graph",
            snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
            now: timestamp
        )
        let foundation = try ReconstructionWorkspaceState(
            projects: [project], corpusManifests: [corpusManifest],
            evidence: [], evidenceRelations: [], evidenceGaps: [],
            jobs: [], tasks: [], checkpoints: [], toolReceipts: [], modelReceipts: []
        )
        try database.replaceReconstructionState(workspaceID: workspaceID, state: foundation)
        let committed = try database.commitInitialReconstructionJob(
            workspaceID: workspaceID,
            mutation: ReconstructionInitialJobMutation(
                jobID: jobID, projectID: project.projectID,
                selectedOccurrenceIDs: [occurrenceID], objective: objective, budget: budget
            )
        )
        // The transaction's IDs are intentionally fresh. Remap IDs, not graph semantics, so
        // repeated fixture generation remains deterministic and package hashes stay reviewable.
        let stableIDs: [ReconstructionTaskKind: UUID] = [
            .ingest: fixedUUID("10000000-0000-0000-0000-000000000120"),
            .classify: fixedUUID("10000000-0000-0000-0000-000000000121"),
            .discoverRelations: fixedUUID("10000000-0000-0000-0000-000000000122"),
        ]
        let remappedIDs = try Dictionary(uniqueKeysWithValues: committed.state.tasks.map { task in
            guard let stableID = stableIDs[task.identity.kind] else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return (task.identity.taskID, stableID)
        })
        return try committed.state.tasks.map { task in
            guard let stableID = remappedIDs[task.identity.taskID] else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let dependencies = try task.identity.dependencyTaskIDs.map { dependency in
                guard let stableDependency = remappedIDs[dependency] else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                return stableDependency
            }
            return ReconstructionTaskRecord(
                identity: try ReconstructionTaskIdentity.make(
                    taskID: stableID, jobID: task.identity.jobID, kind: task.identity.kind,
                    subject: task.identity.subject, dependencyTaskIDs: dependencies,
                    operationContractIdentity: task.identity.operationContractIdentity
                ),
                state: task.state, diagnostic: task.diagnostic
            )
        }
    }

    private static func makeRichState(
        scenario: Task10InstalledScenario,
        project: ReconstructionProjectRecord,
        corpusManifest: ReconstructionCorpusManifest,
        contentIdentity: ReconstructionContentIdentity,
        currentFunction: ReconstructionFunctionCoordinate
    ) throws -> ReconstructionWorkspaceState {
        let evidenceFunction: ReconstructionFunctionCoordinate
        if scenario == .navigationStale {
            evidenceFunction = try ReconstructionFunctionCoordinate(
                artifact: currentFunction.artifact,
                image: currentFunction.image,
                analysisFingerprintSHA256: staleAnalysisFingerprintSHA256,
                startAddress: currentFunction.startAddress,
                endAddressExclusive: currentFunction.endAddressExclusive,
                boundarySchemaVersion: currentFunction.boundarySchemaVersion,
                functionUUIDHint: nil,
                symbolHint: currentFunction.symbolHint
            )
        } else {
            evidenceFunction = currentFunction
        }
        let subject = ReconstructionSubjectCoordinate.function(evidenceFunction)
        let task = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: taskID,
                jobID: jobID,
                kind: .decompileMacScope,
                subject: subject,
                dependencyTaskIDs: [],
                operationContractIdentity: "reconstruction.decompileMacScope.v1"
            ),
            state: .completed,
            diagnostic: nil
        )
        let operationID = ReconstructionOperationID.evidenceQuery.rawValue
        let producer = try makeProducer(operationID: operationID)
        let artifactSubject = ReconstructionSubjectCoordinate.artifact(
            ReconstructionArtifactCoordinate(
                occurrenceID: occurrenceID,
                contentIdentity: contentIdentity
            )
        )
        let rawPromptPayload = Data(
            "{\"bounded\":true,\"rawPrompt\":\"\(rawPromptPrivacyCanary)\"}".utf8
        )
        let rawPseudocodePayload = Data(
            "\(rawPseudocodePrivacyCanary)\nint private_fixture(void) { return 10; }".utf8
        )
        let classifications: [ReconstructionEvidenceClassification] = [
            .acceptedCurrent, .acceptedCurrent, .acceptedCurrent, .acceptedCurrent,
            .acceptedHistorical, .acceptedHistorical, .acceptedHistorical,
            .staleArtifact, .staleArtifact, .staleAnalysis,
            .unavailable, .unavailable, .failed,
        ]
        let evidence = try classifications.enumerated().map { index, classification in
            let recordSubject: ReconstructionSubjectCoordinate = index == 0
                ? subject
                : (index == 9
                    ? .function(try ReconstructionFunctionCoordinate(
                        artifact: currentFunction.artifact,
                        image: currentFunction.image,
                        analysisFingerprintSHA256: staleAnalysisFingerprintSHA256,
                        startAddress: currentFunction.startAddress,
                        endAddressExclusive: currentFunction.endAddressExclusive,
                        boundarySchemaVersion: currentFunction.boundarySchemaVersion,
                        functionUUIDHint: nil,
                        symbolHint: currentFunction.symbolHint
                    ))
                    : artifactSubject)
            let payload: Data
            switch index {
            case 0: payload = rawPromptPayload
            case 1: payload = rawPseudocodePayload
            default: payload = Data("Bounded installed evidence \(index)".utf8)
            }
            return try ReconstructionEvidenceRecord(
                evidenceID: evidenceID(index),
                subject: recordSubject,
                operationID: operationID,
                payloadKind: index == 0 ? .structuredJSON : .text,
                payload: payload,
                payloadByteCount: UInt64(payload.count),
                payloadSHA256: sha256(payload),
                facetDependencies: [],
                producer: producer,
                citations: [try ReconstructionEvidenceCitation(
                    citationID: citationID(index),
                    sourceEvidenceID: nil,
                    subject: recordSubject,
                    locator: "bounded-installed-evidence-\(index)"
                )],
                creatingJobID: jobID,
                creatingTaskID: taskID,
                creatingCheckpointID: firstCheckpointID,
                modelReceiptID: nil,
                toolReceiptID: toolReceiptID,
                classification: classification,
                supersedesEvidenceID: nil,
                supersededByEvidenceID: nil,
                diagnostic: classification == .unavailable || classification == .failed
                    ? .sanitizing("Bounded installed evidence is unavailable")
                    : nil
            )
        }
        let gap = try makeGap(
            subject: artifactSubject,
            operationID: operationID,
            reason: .sanitizing("Missing bounded corroboration")
        )
        let toolReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: toolReceiptID,
            jobID: jobID,
            taskID: taskID,
            checkpointRevision: 0,
            requestIdentitySHA256: sha256(Data("installed fixture request".utf8)),
            producer: producer,
            terminalState: .completed,
            outputEvidenceIDs: evidence.map(\.evidenceID),
            diagnostic: nil
        )
        let projectedClassifications = Dictionary(uniqueKeysWithValues: evidence.map {
            ($0.evidenceID, $0.classification)
        })
        let evidenceFrontierSHA256 = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: corpusManifest.canonicalSHA256,
            records: evidence,
            projectedClassificationsByEvidenceID: projectedClassifications,
            relations: [],
            gaps: [gap],
            checkpointRevisionsByID: [firstCheckpointID: 0]
        )
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: firstCheckpointID,
            jobID: jobID,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: corpusManifest.canonicalSHA256,
            evidenceFrontierSHA256: evidenceFrontierSHA256,
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: [taskID],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier.canonicalSHA256(
                for: [gap]
            ),
            modelReceiptIDs: [],
            toolReceiptIDs: [toolReceiptID],
            coordinatorState: .retrieving,
            terminalReason: nil
        )
        let budget = try ReconstructionJobBudget(
            maxRounds: 2,
            maxTasks: 8,
            maxEvidenceRecords: 32,
            maxEncodedBytes: 32_768
        )
        let job = try ReconstructionJobRecord(
            jobID: jobID,
            reconstructionProjectID: projectID,
            objective: objective,
            objectiveSHA256: sha256(Data(objective.utf8)),
            creationCorpusManifestSHA256: corpusManifest.canonicalSHA256,
            state: .retrieving,
            currentCheckpointID: checkpoint.checkpointID,
            terminalReason: nil,
            budget: budget
        )

        if scenario == .checkpointStale {
            let successorOccurrence = try ReconstructionArtifactOccurrenceRecord(
                occurrenceID: currentOccurrenceID,
                contentIdentity: contentIdentity,
                kind: .opaque,
                roles: [.primaryTarget],
                executableMode: false,
                originalName: "fixture-current.bin",
                diagnostic: nil
            )
            let draft = try ReconstructionCorpusManifest(
                reconstructionProjectID: projectID,
                artifacts: [successorOccurrence],
                relations: [],
                canonicalSHA256: String(repeating: "0", count: 64)
            )
            let currentManifest = try ReconstructionCorpusManifest(
                reconstructionProjectID: projectID,
                artifacts: draft.artifacts,
                relations: draft.relations,
                canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: draft)
            )
            let advancedProject = try ReconstructionProjectRecord(
                projectID: project.projectID,
                name: project.name,
                currentCorpusManifestSHA256: currentManifest.canonicalSHA256
            )
            return try ReconstructionWorkspaceState(
                projects: [advancedProject],
                corpusManifests: [corpusManifest, currentManifest],
                evidence: evidence,
                evidenceRelations: [],
                evidenceGaps: [gap],
                jobs: [job],
                tasks: [task],
                checkpoints: [checkpoint],
                toolReceipts: [toolReceipt],
                modelReceipts: []
            )
        }
        return try ReconstructionWorkspaceState(
            projects: [project],
            corpusManifests: [corpusManifest],
            evidence: evidence,
            evidenceRelations: [],
            evidenceGaps: [gap],
            jobs: [job],
            tasks: [task],
            checkpoints: [checkpoint],
            toolReceipts: [toolReceipt],
            modelReceipts: []
        )
    }

    private static func makeProducer(operationID: String) throws -> ReconstructionProducerIdentity {
        func producer(canonicalSHA256: String) throws -> ReconstructionProducerIdentity {
            try ReconstructionProducerIdentity(
                macScopeBuildIdentity: "MacScope-installed-fixture",
                macScopeSourceIdentity: "source-installed-fixture",
                operationIdentity: operationID,
                registryIdentity: "reconstruction.v1",
                protocolIdentity: "reconstructionR1",
                canonicalSHA256: canonicalSHA256
            )
        }
        let draft = try producer(canonicalSHA256: String(repeating: "0", count: 64))
        return try producer(
            canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(draft)
        )
    }

    private static func makeGap(
        subject: ReconstructionSubjectCoordinate,
        operationID: String,
        reason: ReconstructionDiagnostic
    ) throws -> ReconstructionEvidenceGap {
        func gap(canonicalSHA256: String) throws -> ReconstructionEvidenceGap {
            try ReconstructionEvidenceGap(
                gapID: gapID,
                subject: subject,
                operationID: operationID,
                reason: reason,
                canonicalSHA256: canonicalSHA256
            )
        }
        let draft = try gap(canonicalSHA256: String(repeating: "0", count: 64))
        return try gap(canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalGapSHA256(draft))
    }

    private static func makeCorpusRelation(
        relationID: UUID,
        kind: ReconstructionArtifactRelationKind,
        sourceOccurrenceID: ReconstructionArtifactOccurrenceID,
        targetOccurrenceID: ReconstructionArtifactOccurrenceID?,
        unresolvedLocator: String?,
        evidenceSource: ReconstructionRelationEvidenceSource
    ) throws -> ReconstructionArtifactRelationRecord {
        func relation(canonicalSHA256: String) throws -> ReconstructionArtifactRelationRecord {
            try ReconstructionArtifactRelationRecord(
                relationID: relationID,
                kind: kind,
                sourceOccurrenceID: sourceOccurrenceID,
                targetOccurrenceID: targetOccurrenceID,
                unresolvedLocator: unresolvedLocator,
                evidenceSource: evidenceSource,
                canonicalSHA256: canonicalSHA256
            )
        }
        let draft = try relation(canonicalSHA256: String(repeating: "0", count: 64))
        return try relation(
            canonicalSHA256: ReconstructionRelationDiscoverer().canonicalDigest(for: draft)
        )
    }

    private static func contentIdentity(for bytes: Data) throws -> ReconstructionContentIdentity {
        try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: sha256(bytes),
            byteCount: UInt64(bytes.count)
        )
    }

    private static func evidenceID(_ index: Int) -> UUID {
        fixedUUID(String(format: "10000000-0000-0000-0000-%012d", 30 + index))
    }

    private static func citationID(_ index: Int) -> UUID {
        fixedUUID(String(format: "10000000-0000-0000-0000-%012d", 50 + index))
    }

    private static func workspaceState(
        project: ReconstructionProjectRecord,
        corpusManifest: ReconstructionCorpusManifest,
        job: ReconstructionJobRecord,
        checkpoints: [ReconstructionCheckpoint],
        tasks: [ReconstructionTaskRecord] = []
    ) throws -> ReconstructionWorkspaceState {
        try ReconstructionWorkspaceState(
            projects: [project],
            corpusManifests: [corpusManifest],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [job],
            tasks: tasks,
            checkpoints: checkpoints,
            toolReceipts: [],
            modelReceipts: []
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fixedUUID(_ value: String) -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("invalid installed-scenario UUID")
        }
        return uuid
    }
}
