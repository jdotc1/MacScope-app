import Foundation

enum ReconstructionTransientAnalysisProjectionError: Error, Equatable, Sendable {
    case unsupportedTaskKind(ReconstructionTaskKind)
    case invalidAuthority
    case invalidProjectionShape
    case missingExactFunction
}

/// Resolves function work only through Reconstruction's image-qualified structural coordinate.
/// `functionUUIDHint` and `symbolHint` are deliberately absent: fresh analysis UUIDs are replaced
/// during stable-image binding and therefore cannot authorize a reopened task.
enum ReconstructionReboundFunctionAuthority {
    static func expectedFunctionID(
        for coordinate: ReconstructionFunctionCoordinate
    ) -> UUID? {
        guard coordinate.boundarySchemaVersion
                == ReconstructionFunctionCoordinate.schemaVersion else {
            return nil
        }
        return ReconstructionStableImageAuthority.stableFunctionID(
            image: coordinate.image,
            analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256,
            startAddress: coordinate.startAddress,
            endAddressExclusive: coordinate.endAddressExclusive,
            boundarySchemaVersion: coordinate.boundarySchemaVersion
        )
    }

    static func matches(
        _ function: FunctionSummary,
        coordinate: ReconstructionFunctionCoordinate
    ) -> Bool {
        guard let expectedFunctionID = expectedFunctionID(for: coordinate) else {
            return false
        }
        return function.id == expectedFunctionID
            && function.startAddress == coordinate.startAddress
            && function.endAddress == coordinate.endAddressExclusive
    }

    static func resolve(
        _ coordinate: ReconstructionFunctionCoordinate,
        in workspace: WorkspaceSnapshot
    ) -> FunctionSummary? {
        guard expectedFunctionID(for: coordinate) != nil,
              (try? workspace.validateInvariants()) != nil,
              let binary = workspace.binary(in: coordinate.image.imageSlot),
              binary.id == coordinate.image.binaryID,
              binary.slot == coordinate.image.imageSlot,
              binary.selectedSliceIndex == coordinate.image.selectedSliceIndex,
              binary.artifactIdentity == coordinate.image.machOIdentity,
              reconstructionArchitecture(
                  artifactIdentity: binary.artifactIdentity,
                  displayName: binary.architecture
              ) == coordinate.image.architecture,
              let analysis = workspace.analysis(in: coordinate.image.imageSlot),
              let fingerprint = analysis.analysisInputFingerprint,
              fingerprint.binaryID == coordinate.image.binaryID,
              fingerprint.imageSlot == coordinate.image.imageSlot,
              fingerprint.binaryName == binary.name,
              fingerprint.binaryPath == binary.path,
              fingerprint.selectedSliceIndex == coordinate.image.selectedSliceIndex,
              fingerprint.artifactIdentity == coordinate.image.machOIdentity,
              fingerprint.overallSHA256 == coordinate.analysisFingerprintSHA256 else {
            return nil
        }

        let functionIDs = analysis.functions.map(\.id)
        guard Set(functionIDs).count == functionIDs.count,
              Set(analysis.basicBlocks.map(\.functionID)).isSubset(of: Set(functionIDs)) else {
            return nil
        }
        let candidates = analysis.functions.filter {
            $0.startAddress == coordinate.startAddress
                && $0.endAddress == coordinate.endAddressExclusive
        }
        guard candidates.count == 1,
              let function = candidates.first,
              matches(function, coordinate: coordinate) else {
            return nil
        }
        return function
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

/// One bounded, task-scoped view of freshly detached analysis. This value is intentionally
/// non-Codable and owns no database/package/store reference: a completed batch result may hand it
/// to the round materializer, but it can never become durable reconstruction truth by accident.
struct ReconstructionTransientAnalysisProjection: Equatable, Sendable {
    static let maximumFunctionCount = 16_384
    static let maximumFunctionNameUTF8Bytes = 1_024
    static let maximumFunctionCatalogNameUTF8Bytes = 4 * 1_024 * 1_024
    static let maximumMacScopePseudocodeUTF8Bytes = 1_048_576

    let taskID: UUID
    let taskKind: ReconstructionTaskKind
    let artifact: ReconstructionArtifactCoordinate
    let image: ReconstructionImageBinding
    let analysisFingerprintSHA256: String
    let functionCatalog: [FunctionSummary]
    let functionCatalogWasTruncated: Bool
    let functionNamesWereTruncated: Bool
    let function: FunctionSummary?
    let macScopePseudocode: String?
    let macScopePseudocodeWasTruncated: Bool

    init(
        taskID: UUID,
        taskKind: ReconstructionTaskKind,
        artifact: ReconstructionArtifactCoordinate,
        image: ReconstructionImageBinding,
        analysisFingerprintSHA256: String,
        functionCatalog: [FunctionSummary],
        function: FunctionSummary?,
        macScopePseudocode: String?,
        macScopePseudocodeWasTruncated upstreamPseudocodeWasTruncated: Bool = false
    ) throws {
        try ReconstructionValidation.requireSHA256(
            analysisFingerprintSHA256,
            field: "transient reconstruction analysis fingerprint"
        )
        switch taskKind {
        case .loadBinary, .indexImage, .enumerateFunctions:
            guard function == nil, macScopePseudocode == nil else {
                throw ReconstructionTransientAnalysisProjectionError.invalidProjectionShape
            }
        case .decompileNative:
            guard functionCatalog.isEmpty, function != nil, macScopePseudocode == nil else {
                throw ReconstructionTransientAnalysisProjectionError.invalidProjectionShape
            }
        case .decompileMacScope, .compareDecompilers:
            guard functionCatalog.isEmpty, function != nil, macScopePseudocode != nil else {
                throw ReconstructionTransientAnalysisProjectionError.invalidProjectionShape
            }
        case .ingest, .classify, .discoverRelations,
             .retrieveEvidence, .modelRound, .checkpoint, .executeSource:
            throw ReconstructionTransientAnalysisProjectionError.unsupportedTaskKind(taskKind)
        }

        let sortedCatalog = functionCatalog.sorted(by: Self.functionOrder)
        let catalog = Self.boundedFunctionCatalog(sortedCatalog)
        let exactFunction = function.map(Self.boundedFunctionName)
        let boundedText = macScopePseudocode.map {
            Self.boundedUTF8Prefix(
                $0,
                maximumBytes: Self.maximumMacScopePseudocodeUTF8Bytes
            )
        }

        self.taskID = taskID
        self.taskKind = taskKind
        self.artifact = artifact
        self.image = image
        self.analysisFingerprintSHA256 = analysisFingerprintSHA256
        self.functionCatalog = catalog.functions
        functionCatalogWasTruncated = catalog.wasTruncated
        functionNamesWereTruncated = catalog.namesWereTruncated
            || (exactFunction?.wasTruncated ?? false)
        self.function = exactFunction?.function
        self.macScopePseudocode = boundedText?.text
        macScopePseudocodeWasTruncated = upstreamPseudocodeWasTruncated
            || (boundedText?.wasTruncated ?? false)
    }

    static func project(
        task: ReconstructionTaskRecord,
        detached: ReconstructionDetachedAnalysisSnapshot
    ) throws -> Self {
        guard task.state == .pending || task.state == .running,
              detached.workspace.binaries.count == 1,
              detached.workspace.binary(in: detached.image.imageSlot)?.id
                == detached.image.binaryID,
              let analysis = detached.workspace.analysis(in: detached.image.imageSlot),
              Set(analysis.functions.map(\.id)).count == analysis.functions.count,
              analysis.analysisInputFingerprint?.overallSHA256
                == detached.analysisInputFingerprintSHA256 else {
            throw ReconstructionTransientAnalysisProjectionError.invalidAuthority
        }

        switch (task.identity.kind, task.identity.subject) {
        case (.loadBinary, let .artifact(artifact)?),
             (.indexImage, let .artifact(artifact)?),
             (.enumerateFunctions, let .artifact(artifact)?):
            guard artifact == detached.artifact else {
                throw ReconstructionTransientAnalysisProjectionError.invalidAuthority
            }
            return try Self(
                taskID: task.identity.taskID,
                taskKind: task.identity.kind,
                artifact: detached.artifact,
                image: detached.image,
                analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256,
                functionCatalog: canonicalCatalog(analysis.functions, detached: detached),
                function: nil,
                macScopePseudocode: nil
            )

        case (.loadBinary, let .image(coordinate)?),
             (.indexImage, let .image(coordinate)?),
             (.enumerateFunctions, let .image(coordinate)?):
            guard coordinate.artifact == detached.artifact,
                  coordinate.image == detached.image,
                  coordinate.analysisFingerprintSHA256
                    == detached.analysisInputFingerprintSHA256 else {
                throw ReconstructionTransientAnalysisProjectionError.invalidAuthority
            }
            return try Self(
                taskID: task.identity.taskID,
                taskKind: task.identity.kind,
                artifact: detached.artifact,
                image: detached.image,
                analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256,
                functionCatalog: canonicalCatalog(analysis.functions, detached: detached),
                function: nil,
                macScopePseudocode: nil
            )

        case (.decompileNative, let .function(coordinate)?),
             (.decompileMacScope, let .function(coordinate)?),
             (.compareDecompilers, let .function(coordinate)?):
            guard coordinate.artifact == detached.artifact,
                  coordinate.image == detached.image,
                  coordinate.analysisFingerprintSHA256
                    == detached.analysisInputFingerprintSHA256,
                  coordinate.boundarySchemaVersion
                    == ReconstructionFunctionCoordinate.schemaVersion else {
                throw ReconstructionTransientAnalysisProjectionError.invalidAuthority
            }
            guard let function = ReconstructionReboundFunctionAuthority.resolve(
                coordinate,
                in: detached.workspace
            ) else {
                throw ReconstructionTransientAnalysisProjectionError.missingExactFunction
            }
            let functionID = function.id
            let pseudocode: String?
            let pseudocodeWasTruncated: Bool
            if task.identity.kind == .decompileMacScope
                || task.identity.kind == .compareDecompilers {
                guard let renderInput = detached.workspace.pseudocodeRenderInput(
                    exactFunctionID: functionID,
                    in: detached.image.imageSlot
                ), renderInput.startAddress == coordinate.startAddress else {
                    throw ReconstructionTransientAnalysisProjectionError.missingExactFunction
                }
                let boundedFunctionName = Self.boundedUTF8Prefix(
                    renderInput.functionName,
                    maximumBytes: Self.maximumFunctionNameUTF8Bytes
                ).text
                let boundedPseudocode = PseudocodePrinter().printBoundedText(
                    functionName: boundedFunctionName,
                    startAddress: renderInput.startAddress,
                    jumpTables: renderInput.jumpTables,
                    objcSelectors: renderInput.objcSelectors,
                    constantStrings: renderInput.constantStrings,
                    nameOverrides: renderInput.nameOverrides,
                    signatureOverrides: renderInput.signatureOverrides,
                    authoredCallSignaturesByTarget: renderInput.authoredCallSignaturesByTarget,
                    directCallVoidResultTargets: renderInput.directCallVoidResultTargets,
                    machineCallUsage: renderInput.machineCallUsage,
                    machineUsageContext: renderInput.machineUsageContext,
                    ownDirectCallAddresses: renderInput.ownDirectCallAddresses,
                    registerNameOverrides: renderInput.registerNameOverrides,
                    types: renderInput.types,
                    instructions: renderInput.instructions,
                    maximumUTF8Bytes: Self.maximumMacScopePseudocodeUTF8Bytes
                )
                pseudocode = boundedPseudocode.text
                pseudocodeWasTruncated = boundedPseudocode.wasTruncated
            } else {
                pseudocode = nil
                pseudocodeWasTruncated = false
            }
            return try Self(
                taskID: task.identity.taskID,
                taskKind: task.identity.kind,
                artifact: detached.artifact,
                image: detached.image,
                analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256,
                functionCatalog: [],
                function: function,
                macScopePseudocode: pseudocode,
                macScopePseudocodeWasTruncated: pseudocodeWasTruncated
            )

        default:
            throw ReconstructionTransientAnalysisProjectionError.unsupportedTaskKind(
                task.identity.kind
            )
        }
    }

    /// Detached analysis owns its original function/block IDs. Only the outgoing catalog DTO
    /// receives durable range-based identities, so enumeration can authorize later reopened work.
    private static func canonicalCatalog(
        _ functions: [FunctionSummary],
        detached: ReconstructionDetachedAnalysisSnapshot
    ) -> [FunctionSummary] {
        functions.map { function in
            FunctionSummary(id: ReconstructionStableImageAuthority.stableFunctionID(
                image: detached.image,
                analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256,
                startAddress: function.startAddress, endAddressExclusive: function.endAddress,
                boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion),
                name: function.name, startAddress: function.startAddress,
                endAddress: function.endAddress, confidence: function.confidence,
                noReturnProvenance: function.noReturnProvenance)
        }
    }

    private static func functionOrder(_ lhs: FunctionSummary, _ rhs: FunctionSummary) -> Bool {
        if lhs.startAddress != rhs.startAddress { return lhs.startAddress < rhs.startAddress }
        if lhs.endAddress != rhs.endAddress { return lhs.endAddress < rhs.endAddress }
        let lhsID = lhs.id.uuidString.lowercased()
        let rhsID = rhs.id.uuidString.lowercased()
        return lhsID < rhsID
    }

    private static func boundedFunctionCatalog(
        _ sorted: [FunctionSummary]
    ) -> (functions: [FunctionSummary], wasTruncated: Bool, namesWereTruncated: Bool) {
        var functions: [FunctionSummary] = []
        functions.reserveCapacity(min(sorted.count, maximumFunctionCount))
        var retainedNameBytes = 0
        var namesWereTruncated = false

        for function in sorted {
            guard functions.count < maximumFunctionCount else {
                return (functions, true, namesWereTruncated)
            }
            let bounded = boundedFunctionName(function)
            let (nextNameBytes, overflow) = retainedNameBytes.addingReportingOverflow(
                bounded.function.name.utf8.count
            )
            guard !overflow, nextNameBytes <= maximumFunctionCatalogNameUTF8Bytes else {
                return (functions, true, namesWereTruncated)
            }
            functions.append(bounded.function)
            retainedNameBytes = nextNameBytes
            namesWereTruncated = namesWereTruncated || bounded.wasTruncated
        }
        return (functions, false, namesWereTruncated)
    }

    private static func boundedFunctionName(
        _ function: FunctionSummary
    ) -> (function: FunctionSummary, wasTruncated: Bool) {
        let bounded = boundedUTF8Prefix(
            function.name,
            maximumBytes: maximumFunctionNameUTF8Bytes
        )
        var function = function
        function.name = bounded.text
        return (function, bounded.wasTruncated)
    }

    private static func boundedUTF8Prefix(
        _ source: String,
        maximumBytes: Int
    ) -> (text: String, wasTruncated: Bool) {
        precondition(maximumBytes >= 0)
        guard source.utf8.count > maximumBytes else {
            return (source, false)
        }
        var text = ""
        text.reserveCapacity(maximumBytes)
        var usedBytes = 0
        for scalar in source.unicodeScalars {
            let scalarText = String(scalar)
            let scalarBytes = scalarText.utf8.count
            guard usedBytes + scalarBytes <= maximumBytes else {
                break
            }
            text.unicodeScalars.append(scalar)
            usedBytes += scalarBytes
        }
        return (text, true)
    }
}
