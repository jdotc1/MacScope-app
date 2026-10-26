import Foundation

enum NativeDecompilerSnapshotProjectionError: Error, Equatable, Sendable {
    case invalidBudgets
    case binaryNotFound
    case analysisNotFound
    case functionNotFound
    case unverifiedArtifact
    case missingArtifactIdentity
    case missingArtifactUUID
    case unsupportedArchitecture
    case missingSegmentLayout
    case invalidSegmentLayout
    case overlappingSegmentLayout
    case missingHeaderMappingSegment
    case missingAnalysisFingerprint
    case analysisCoordinateMismatch
    case analysisFingerprintMismatch
    case emptySelectedSlice
    case selectedSliceMismatch
    case invalidFunctionRange
    case functionExceedsBudget
    case invalidPatchRange
    case intersectingPatch
    case patchedControlFlowLeavesFunction
    case invalidRelocationRange
    case intersectingRelocation
    case effectiveLoadImageAuthorityUnavailable
    case invalidEffectiveLoadImageAttestation
    case invalidFunctionCoverage
    case tooManyMemoryRegions
    case tooManySymbols
    case requestTooLarge
    case invalidProjectedRequest
}

enum NativeDecompilerSnapshotBuilder {
    private static let maximumMemoryRegions = 256
    private static let maximumSymbols = 100_000
    private static let maximumRegionBytes = 64 * 1_024 * 1_024
    static let readProtection: Int32 = 1
    static let writeProtection: Int32 = 2
    static let executeProtection: Int32 = 4
    private static let knownProtections: Int32 = 7
    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    /// Concrete value-only image facets verified for one WorkspaceStore revision.
    /// No ImageAnalysis reference memo or mutable workspace object is retained.
    struct ValidatedImage: Sendable {
        let imageSlot: ImageSlot
        let binaryID: UUID
        let relocations: [RelocationSummary]
        let functionsByID: [UUID: [FunctionSummary]]
        let functionsByStart: [UInt64: [FunctionSummary]]
        let sortedXRefs: [XRef]
        let fingerprint: AnalysisInputFingerprint
        let artifactUUID: UUID
        let rawCPUType: Int32
        let selectedSliceBytes: Data
        let byteCount: UInt64
        let byteSHA256: String
        let mappedLayout: [VerifiedSegment]
        /// A failed segment is retained as a typed refusal, never silently admitted.
        let attestationErrors: [NativeDecompilerSnapshotProjectionError?]
        let preferredLoadAddress: UInt64
        let symbolsResult: Result<[NativeDecompilerWireSymbolRecord], NativeDecompilerSnapshotProjectionError>
        let targetResult: Result<NativeDecompilerWireTarget, NativeDecompilerSnapshotProjectionError>

        var retainedBytes: Int {
            let symbolCount = (try? symbolsResult.get())?.count ?? 0
            guard functionsByID.count <= 200_000,
                  sortedXRefs.count <= 200_000,
                  relocations.count <= 200_000,
                  symbolCount <= 200_000 else { return .max }
            let rows = functionsByID.count + sortedXRefs.count
                + relocations.count + symbolCount
            guard rows <= 200_000 else { return .max }
            return selectedSliceBytes.count + rows * 256
        }
    }

    static func build(
        from workspace: WorkspaceSnapshot,
        imageSlot: ImageSlot,
        functionID: UUID,
        budgets: NativeDecompilerWireAnalysisBudgets
    ) throws -> NativeDecompilerSnapshotProjection {
        try validateBudgets(budgets)
        let validatedImage = try validateImage(from: workspace, imageSlot: imageSlot)
        return try build(
            from: workspace, validatedImage: validatedImage,
            functionID: functionID, budgets: budgets
        )
    }

    static func validateImage(
        from workspace: WorkspaceSnapshot,
        imageSlot: ImageSlot
    ) throws -> ValidatedImage {
        let matchingBinaries = workspace.binaries.filter { $0.slot == imageSlot }
        guard matchingBinaries.count == 1, let binary = matchingBinaries.first else {
            throw NativeDecompilerSnapshotProjectionError.binaryNotFound
        }
        guard let analysis = workspace.analysis(in: imageSlot) else {
            throw NativeDecompilerSnapshotProjectionError.analysisNotFound
        }
        guard binary.artifactIntegrityState == .verified else {
            throw NativeDecompilerSnapshotProjectionError.unverifiedArtifact
        }
        guard let artifact = binary.artifactIdentity else {
            throw NativeDecompilerSnapshotProjectionError.missingArtifactIdentity
        }
        guard let artifactUUID = artifact.uuid, artifactUUID != zeroUUID else {
            throw NativeDecompilerSnapshotProjectionError.missingArtifactUUID
        }
        guard let segmentLayout = binary.preferredSegmentLayout else {
            throw NativeDecompilerSnapshotProjectionError.missingSegmentLayout
        }
        guard let fingerprint = analysis.analysisInputFingerprint else {
            throw NativeDecompilerSnapshotProjectionError.missingAnalysisFingerprint
        }
        guard fingerprint.imageSlot == imageSlot,
              fingerprint.binaryID == binary.id,
              fingerprint.selectedSliceIndex == binary.selectedSliceIndex,
              fingerprint.artifactIdentity == artifact,
              isLowercaseSHA256(fingerprint.overallSHA256)
        else {
            throw NativeDecompilerSnapshotProjectionError.analysisCoordinateMismatch
        }
        let selectedSliceBytes = analysis.imageBytes
        guard !selectedSliceBytes.isEmpty else {
            throw NativeDecompilerSnapshotProjectionError.emptySelectedSlice
        }
        let byteCount = UInt64(selectedSliceBytes.count)
        let byteSHA256 = AnalysisFingerprintBuilder.sha256Hex(selectedSliceBytes)
        guard artifact.selectedSliceByteCount == byteCount,
              artifact.selectedSliceSHA256 == byteSHA256,
              fingerprint.imageByteCount == byteCount,
              fingerprint.imageBytesSHA256 == byteSHA256
        else {
            throw NativeDecompilerSnapshotProjectionError.selectedSliceMismatch
        }
        let currentFingerprint: AnalysisInputFingerprint
        do {
            currentFingerprint = try AnalysisFingerprintBuilder.fingerprint(
                binary: binary, analysis: analysis
            )
        } catch {
            throw NativeDecompilerSnapshotProjectionError.analysisFingerprintMismatch
        }
        guard currentFingerprint == fingerprint else {
            throw NativeDecompilerSnapshotProjectionError.analysisFingerprintMismatch
        }
        let verifiedLayout = try verifyLayout(
            segmentLayout.records, selectedSliceByteCount: byteCount
        )
        let preferredLoadAddress = try derivePreferredLoadAddress(from: verifiedLayout)
        let mappedLayout = mappedSegments(verifiedLayout)
        let attestationErrors: [NativeDecompilerSnapshotProjectionError?] = mappedLayout.map { segment in
            guard segment.record.fileSize > 0,
                  segment.record.initialProtections & readProtection != 0,
                  segment.record.initialProtections & writeProtection == 0 else { return nil }
            do {
                try validateIdentityEffectiveByteAuthority(
                    for: segment, selectedSliceBytes: selectedSliceBytes,
                    artifact: artifact, attestations: analysis.identityEffectiveByteRanges
                )
                return nil
            } catch let error as NativeDecompilerSnapshotProjectionError {
                return error
            } catch {
                return .effectiveLoadImageAuthorityUnavailable
            }
        }
        let imageID = binary.id.uuidString.lowercased()
        let symbolsResult: Result<[NativeDecompilerWireSymbolRecord], NativeDecompilerSnapshotProjectionError>
        do {
            symbolsResult = .success(try projectSymbols(
                analysis.symbols, functions: analysis.functions, imageID: imageID
            ))
        } catch let error as NativeDecompilerSnapshotProjectionError {
            symbolsResult = .failure(error)
        } catch {
            symbolsResult = .failure(.invalidProjectedRequest)
        }
        let targetResult: Result<NativeDecompilerWireTarget, NativeDecompilerSnapshotProjectionError>
        do {
            targetResult = .success(try NativeDecompilerSealedTargetProfile.normalizedTarget(
                rawCPUType: UInt32(bitPattern: artifact.rawCPUType),
                rawCPUSubtype: UInt32(bitPattern: artifact.rawCPUSubtype),
                selectedSliceSHA256: byteSHA256,
                selectedSliceByteCount: byteCount
            ))
        } catch {
            targetResult = .failure(.unsupportedArchitecture)
        }
        return ValidatedImage(
            imageSlot: imageSlot, binaryID: binary.id,
            relocations: analysis.relocations,
            functionsByID: Dictionary(grouping: analysis.functions, by: \.id),
            functionsByStart: Dictionary(grouping: analysis.functions, by: \.startAddress),
            sortedXRefs: analysis.xrefs.sorted {
                ($0.from, $0.to, $0.kind) < ($1.from, $1.to, $1.kind)
            },
            fingerprint: currentFingerprint, artifactUUID: artifactUUID,
            rawCPUType: artifact.rawCPUType,
            selectedSliceBytes: selectedSliceBytes, byteCount: byteCount,
            byteSHA256: byteSHA256, mappedLayout: mappedLayout,
            attestationErrors: attestationErrors,
            preferredLoadAddress: preferredLoadAddress,
            symbolsResult: symbolsResult, targetResult: targetResult
        )
    }

    static func build(
        from workspace: WorkspaceSnapshot,
        validatedImage: ValidatedImage,
        functionID: UUID,
        budgets: NativeDecompilerWireAnalysisBudgets
    ) throws -> NativeDecompilerSnapshotProjection {
        try validateBudgets(budgets)
        let imageSlot = validatedImage.imageSlot
        let artifactUUID = validatedImage.artifactUUID
        let selectedSliceBytes = validatedImage.selectedSliceBytes
        let mappedLayout = validatedImage.mappedLayout
        let preferredLoadAddress = validatedImage.preferredLoadAddress
        let currentFingerprint = validatedImage.fingerprint
        let matchingBinaries = workspace.binaries.filter { $0.slot == imageSlot }
        guard matchingBinaries.count == 1, let binary = matchingBinaries.first else {
            throw NativeDecompilerSnapshotProjectionError.binaryNotFound
        }
        guard let analysis = workspace.analysis(in: imageSlot) else {
            throw NativeDecompilerSnapshotProjectionError.analysisNotFound
        }
        guard binary.id == validatedImage.binaryID,
              analysis.analysisInputFingerprint == currentFingerprint else {
            throw NativeDecompilerSnapshotProjectionError.analysisCoordinateMismatch
        }
        guard let artifact = binary.artifactIdentity,
              artifact.selectedSliceSHA256 == validatedImage.byteSHA256,
              artifact.selectedSliceByteCount == validatedImage.byteCount,
              artifact.rawCPUType == validatedImage.rawCPUType else {
            throw NativeDecompilerSnapshotProjectionError.selectedSliceMismatch
        }

        let matchingFunctions = validatedImage.functionsByID[functionID] ?? []
        guard matchingFunctions.count == 1, let selectedFunction = matchingFunctions.first else {
            throw NativeDecompilerSnapshotProjectionError.functionNotFound
        }
        guard selectedFunction.startAddress < selectedFunction.endAddress,
              selectedFunction.startAddress.isMultiple(of: 4),
              selectedFunction.endAddress.isMultiple(of: 4),
              isWireText(selectedFunction.name, maximum: 1_024)
        else {
            throw NativeDecompilerSnapshotProjectionError.invalidFunctionRange
        }
        let functionByteCount = selectedFunction.endAddress - selectedFunction.startAddress
        guard functionByteCount <= UInt64(budgets.maxCodeBytes) else {
            throw NativeDecompilerSnapshotProjectionError.functionExceedsBudget
        }

        try rejectRelocations(
            validatedImage.relocations,
            intersecting: selectedFunction.startAddress ..< selectedFunction.endAddress
        )

        let nominalFunctionRange = selectedFunction.startAddress ..< selectedFunction.endAddress
        let previewInputs: NativeDecompilerWireAuthoredInputs
        do {
            previewInputs = try NativeDecompilerAuthoredInputProjector.contextCandidates(
                workspace: workspace, imageSlot: imageSlot, functionID: functionID
            )
        } catch {
            throw NativeDecompilerSnapshotProjectionError.invalidProjectedRequest
        }
        var memoryRegions = try projectMemoryRegions(
            selectedSliceBytes: selectedSliceBytes,
            layout: mappedLayout,
            functionRange: nominalFunctionRange,
            attestationErrors: validatedImage.attestationErrors
        )
        let nominalMemoryRegions = memoryRegions
        let patches = workspace.patches(in: imageSlot)
        let functionRange = try fileBackedBodyRange(
            nominalRange: nominalFunctionRange, patches: patches,
            rawRegions: nominalMemoryRegions, analysis: analysis,
            workspace: workspace, imageSlot: imageSlot,
            rawCPUType: artifact.rawCPUType
        )
        if functionRange != nominalFunctionRange {
            memoryRegions = try clippedFunctionRegions(memoryRegions, to: functionRange)
        }
        let context = try selectContextWithAuthoredAdmission(
            functionRegions: memoryRegions, workspace: workspace, imageSlot: imageSlot,
            functionID: functionID, validatedImage: validatedImage, layout: mappedLayout,
            functionRange: functionRange, previewInputs: previewInputs,
            attestationErrors: validatedImage.attestationErrors,
            functionsByStart: validatedImage.functionsByStart,
            sortedXRefs: validatedImage.sortedXRefs
        )
        let authoredCave = workspace.addressOverrides[
            ImageAddress(slot: imageSlot, address: selectedFunction.startAddress)
        ]?.appendedExecutableCave
        let cave: FileBackedCave?
        let appended: AppendedCave?
        if let authoredCave {
            guard functionRange == nominalFunctionRange else {
                throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
            }
            cave = nil
            appended = try appendedCave(
                authored: authoredCave, workspace: workspace,
                binary: binary, artifact: artifact,
                selectedSliceBytes: selectedSliceBytes, imageSlot: imageSlot,
                functionID: selectedFunction.id, functionRange: functionRange,
                patches: patches, mappedLayout: mappedLayout,
                contextRegions: context.regions,
                sortedXRefs: validatedImage.sortedXRefs, budgets: budgets
            )
        } else {
            cave = try fileBackedCave(
                selectedSliceBytes: selectedSliceBytes, binary: binary, analysis: analysis,
                workspace: workspace, imageSlot: imageSlot, functionRange: functionRange,
                nominalFunctionRange: nominalFunctionRange, selectedFunctionID: selectedFunction.id,
                patches: patches, layout: mappedLayout, artifact: artifact,
                attestationErrors: validatedImage.attestationErrors,
                budgets: budgets
            )
            appended = nil
        }
        let projectedRegions = try regionsWithFileBackedCave(
            context.regions, cave: cave, selectedSliceBytes: selectedSliceBytes,
            layout: mappedLayout, attestationErrors: validatedImage.attestationErrors
        )
        var effectivePatches = patches
        if let appended {
            effectivePatches[appended.branchSourceAddress] = appended.branchPatch
        }
        memoryRegions = try materializePatchedRegions(
            projectedRegions,
            patches: effectivePatches,
            layout: mappedLayout,
            selectedSliceByteCount: selectedSliceBytes.count
        )
        if let appended {
            memoryRegions.append(appended.region)
            memoryRegions.sort { ($0.startAddress.value, $0.name) < ($1.startAddress.value, $1.name) }
        }
        try NativeDecompilerPatchedControlFlowAdmission.check(
            regions: memoryRegions,
            functionRange: functionRange,
            caveRange: appended?.range ?? cave?.range,
            rawCPUType: validatedImage.rawCPUType
        )
        let imageID = validatedImage.binaryID.uuidString.lowercased()
        let symbols = try validatedImage.symbolsResult.get()
        let target = try validatedImage.targetResult.get()
        let image = NativeDecompilerWireImageIdentity(
            imageID: imageID,
            uuid: artifactUUID,
            preferredLoadAddress: .init(preferredLoadAddress)
        )
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: selectedFunction.id.uuidString.lowercased(),
            name: selectedFunction.name,
            entryAddress: .init(selectedFunction.startAddress),
            endAddressExclusive: .init(appended?.range.upperBound ?? cave?.range.upperBound ?? selectedFunction.endAddress),
            codeRanges: (appended?.range ?? cave?.range).map { range in [
                NativeDecompilerWireCodeRange(
                    startAddress: .init(functionRange.lowerBound),
                    endAddressExclusive: .init(functionRange.upperBound)
                ),
                NativeDecompilerWireCodeRange(
                    startAddress: .init(range.lowerBound),
                    endAddressExclusive: .init(range.upperBound)
                ),
            ] }
        )
        let stackLocals = workspace.stackLocalOverrides(forProcedureAt: functionRange.lowerBound, in: imageSlot)
        // Native requests without stack edits do not pay for local recovery. A cave
        // extends the CFG beyond this single-range recovery, so keep those edits
        // persisted until the complete storage binding can be established.
        let liveStackStorage = !stackLocals.isEmpty && validatedImage.rawCPUType == MachOConstants.cpuTypeARM64
            && cave == nil && appended == nil
            ? recoveredStackStorage(functionRegions: memoryRegions, functionRange: functionRange,
                                    maximumInstructions: budgets.maxInstructions) : []
        let projection = NativeDecompilerSnapshotProjection(
            coordinate: NativeDecompilerSnapshotCoordinate(
                imageSlot: imageSlot,
                ownerBinaryID: validatedImage.binaryID,
                analysisInputFingerprintSHA256: currentFingerprint.overallSHA256
            ),
            target: target,
            image: image,
            function: function,
            memoryRegions: memoryRegions,
            symbols: symbols,
            authoredInputs: withAuthoredLocalNames(
                withCalleeSignatureHints(
                    context.authoredInputs, functionRegions: memoryRegions, functionRange: functionRange,
                    analysis: analysis, overrides: workspace.functionSignatureOverrides(in: imageSlot),
                    recoveredParameters: { [functionsByStart = validatedImage.functionsByStart, rows = analysis.instructions] target in
                        recoveredCalleeParameters(target: target, functionsByStart: functionsByStart, instructions: rows)
                    }
                ),
                stackLocals: stackLocals,
                registerNames: workspace.registerNameOverrides(forProcedureAt: functionRange.lowerBound, in: imageSlot),
                liveStackStorage: liveStackStorage,
                catalogDefinitions: workspace.typeDefinitions
            ),
            contextOmissions: context.omissions
        )

        return projection
    }

    private static func validateBudgets(_ budgets: NativeDecompilerWireAnalysisBudgets) throws {
        guard budgets.maxCodeBytes > 0,
              budgets.maxInstructions > 0,
              budgets.maxOperations > 0,
              budgets.maxOutputBytes > 0,
              budgets.maxOutputBytes <= UInt32(NativeDecompilerWireCodec.maximumResponseBytes),
              budgets.maxWallTimeMilliseconds.value > 0
        else {
            throw NativeDecompilerSnapshotProjectionError.invalidBudgets
        }
        guard NativeDecompilerProductBudgetProfile.sealed(budgets) != nil else {
            throw NativeDecompilerSnapshotProjectionError.invalidBudgets
        }
    }
}

extension NativeDecompilerSnapshotBuilder {
    static let maximumContextBytes = 1_048_576
    static let maximumContextRegions = 64
    static let referencedDataWindowBytes: UInt64 = 4_096
    static let decoderLookaheadBytes: UInt64 = 64
    /// Call-graph hops searched from the selected function when ranking authored context.
    static let maximumRelevanceDistance = 4
    /// Functions admitted to the bounded relevance search, including the selected function.
    static let maximumRelevanceFunctions = 4_096

    struct ContextSelection {
        let regions: [NativeDecompilerWireMemoryRegion]
        let authoredInputs: NativeDecompilerWireAuthoredInputs
        let omissions: NativeDecompilerContextOmissionManifest
    }

    enum ContextAuthoredInput: Hashable {
        case name(Int)
        case signature(Int)
        case appliedType(Int)
    }

    enum ContextExecutableRequirement {
        case executable
        case nonExecutable
        case any
    }

    struct ContextCandidateKey: Hashable {
        let kind: NativeDecompilerContextSubjectKind
        let lowerBound: UInt64
        let upperBound: UInt64
    }

    struct ContextCandidate {
        let kind: NativeDecompilerContextSubjectKind
        /// Complete subject extent; the selected function's bytes are carved out when supplied.
        let range: Range<UInt64>
        let requirement: ContextExecutableRequirement
        /// Authored function subject without a unique aligned analysis extent.
        let unresolved: Bool
        /// Distance from the selected function; nil when unrelated within the bounded search.
        let distance: Int?
        /// The subject touches the selected function's own bytes; failures still reject.
        let isMandatory: Bool
        let sequence: Int
        var inputs: [ContextAuthoredInput]

        var isAuthored: Bool {
            kind != .derivedCallee && kind != .derivedData
        }
    }

    struct ContextFailure {
        let reason: NativeDecompilerContextOmissionReason
        let error: NativeDecompilerSnapshotProjectionError
    }

    struct ContextPiece {
        let segment: Int
        let range: Range<UInt64>
    }

    /// Sorted, segment-local union of admitted context bytes. Pieces in one segment that touch
    /// or overlap merge into one wire region; pieces never merge across a segment boundary.
    struct ContextCoverage {
        private(set) var pieces: [ContextPiece] = []
        private(set) var byteCount: UInt64 = 0

        mutating func insert(_ piece: ContextPiece) {
            var lower = piece.range.lowerBound
            var upper = piece.range.upperBound
            var removed: UInt64 = 0
            var kept: [ContextPiece] = []
            kept.reserveCapacity(pieces.count + 1)
            for existing in pieces {
                if existing.segment == piece.segment,
                   existing.range.lowerBound <= upper, lower <= existing.range.upperBound {
                    lower = min(lower, existing.range.lowerBound)
                    upper = max(upper, existing.range.upperBound)
                    removed += existing.range.upperBound - existing.range.lowerBound
                } else {
                    kept.append(existing)
                }
            }
            kept.append(ContextPiece(segment: piece.segment, range: lower ..< upper))
            kept.sort { ($0.range.lowerBound, $0.segment) < ($1.range.lowerBound, $1.segment) }
            pieces = kept
            byteCount = byteCount - removed + (upper - lower)
        }
    }

    /// Select subjects against one captured revision before interpreting their authored types.
    /// The preview uses a one-byte applied extent solely to find candidates. A selected applied
    /// type is then replaced with its validated layout and the unchanged context selector runs
    /// again. Newly admitted subjects are resolved monotonically until the selected set settles.
    static func selectContextWithAuthoredAdmission(
        functionRegions: [NativeDecompilerWireMemoryRegion],
        workspace: WorkspaceSnapshot, imageSlot: ImageSlot, functionID: UUID,
        validatedImage: ValidatedImage, layout: [VerifiedSegment],
        functionRange: Range<UInt64>,
        previewInputs: NativeDecompilerWireAuthoredInputs,
        attestationErrors: [NativeDecompilerSnapshotProjectionError?],
        functionsByStart: [UInt64: [FunctionSummary]], sortedXRefs: [XRef]
    ) throws -> ContextSelection {
        func select(_ inputs: NativeDecompilerWireAuthoredInputs) throws -> ContextSelection {
            try selectContext(
                functionRegions: functionRegions, workspace: workspace, imageSlot: imageSlot,
                validatedImage: validatedImage, layout: layout, functionRange: functionRange,
                authoredInputs: inputs,
                attestationErrors: attestationErrors,
                functionsByStart: functionsByStart, sortedXRefs: sortedXRefs
            )
        }
        func addresses(_ context: ContextSelection) -> (signatures: Set<UInt64>, applied: Set<UInt64>) {
            (Set(context.authoredInputs.signatures.map { $0.functionAddress.value }),
             Set(context.authoredInputs.appliedTypes.map { $0.address.value }))
        }
        func exact(_ signatures: Set<UInt64>, _ applied: Set<UInt64>) throws -> NativeDecompilerWireAuthoredInputs {
            switch NativeDecompilerAuthoredInputProjector.project(
                workspace: workspace, imageSlot: imageSlot, functionID: functionID,
                signatureAddresses: signatures, appliedAddresses: applied
            ) {
            case let .valid(projection): return projection.authoredInputs
            case .invalid: throw NativeDecompilerSnapshotProjectionError.invalidProjectedRequest
            }
        }

        let previewSelection = try select(previewInputs)
        var admitted = addresses(previewSelection)
        // One byte is only a preview extent. A real authored object can reach one MiB;
        // if that possible extent touches selected/context bytes or a data-reference
        // window, omission on the preview cannot prove irrelevance. Resolve it before
        // publication, even when this conservatively turns an omission into refusal.
        let dataKinds: Set<String> = [XRefKind.data, XRefKind.string, XRefKind.selref, XRefKind.classref]
        let referenceWindows = validatedImage.sortedXRefs.compactMap { xref -> Range<UInt64>? in
            guard dataKinds.contains(xref.kind) else { return nil }
            let end = xref.to.addingReportingOverflow(referencedDataWindowBytes)
            return xref.to ..< (end.overflow ? UInt64.max : end.partialValue)
        }
        for applied in previewInputs.appliedTypes where !admitted.applied.contains(applied.address.value) {
            let start = applied.address.value
            let end = start.addingReportingOverflow(UInt64(maximumContextBytes))
            let possible = start ..< (end.overflow ? UInt64.max : end.partialValue)
            if possible.overlaps(functionRange)
                || previewSelection.regions.contains(where: { region in
                    let end = region.startAddress.value.addingReportingOverflow(UInt64(region.rawBytes.count))
                    return end.overflow
                        || possible.overlaps(region.startAddress.value ..< end.partialValue)
                })
                || referenceWindows.contains(where: { possible.overlaps($0) }) {
                admitted.applied.insert(start)
            }
        }
        var current = previewSelection
        let maximumAdmissions = previewInputs.signatures.count + previewInputs.appliedTypes.count
        for _ in 0 ... maximumAdmissions {
            let resolved = try exact(admitted.signatures, admitted.applied)
            let signaturesByAddress = Dictionary(uniqueKeysWithValues: resolved.signatures.map {
                ($0.functionAddress.value, $0)
            })
            let appliedByAddress = Dictionary(uniqueKeysWithValues: resolved.appliedTypes.map {
                ($0.address.value, $0)
            })
            let mixed = NativeDecompilerWireAuthoredInputs(
                schemaVersion: previewInputs.schemaVersion,
                names: previewInputs.names,
                signatures: previewInputs.signatures.map {
                    signaturesByAddress[$0.functionAddress.value] ?? $0
                },
                appliedTypes: previewInputs.appliedTypes.map {
                    appliedByAddress[$0.address.value] ?? $0
                },
                typeDefinitions: resolved.typeDefinitions
            )
            current = try select(mixed)
            let newlySelected = addresses(current)
            if newlySelected.signatures.isSubset(of: admitted.signatures),
               newlySelected.applied.isSubset(of: admitted.applied) {
                // Only definitions needed by the final selected subjects enter the request.
                let final = try exact(newlySelected.signatures, newlySelected.applied)
                let selectedInputs = NativeDecompilerWireAuthoredInputs(
                    schemaVersion: final.schemaVersion,
                    names: current.authoredInputs.names,
                    signatures: final.signatures,
                    appliedTypes: final.appliedTypes,
                    typeDefinitions: final.typeDefinitions
                )
                do {
                    _ = try NativeDecompilerWireCanonicalRequest
                        .canonicalAuthoredInputBytes(selectedInputs)
                } catch {
                    throw NativeDecompilerSnapshotProjectionError.invalidProjectedRequest
                }
                return ContextSelection(
                    regions: current.regions,
                    authoredInputs: selectedInputs,
                    omissions: current.omissions
                )
            }
            admitted.signatures.formUnion(newlySelected.signatures)
            admitted.applied.formUnion(newlySelected.applied)
        }
        throw NativeDecompilerSnapshotProjectionError.invalidProjectedRequest
    }

    /// Exact function identity stays separate from request-local readable context.
    ///
    /// Context is an explicit relevance-ranked subset: the selected function's own subjects and
    /// decoder lookahead are mandatory (any authority failure rejects the request); everything
    /// else is ranked by call-graph distance from the selected function (direct callees and
    /// referenced read-only data first, unrelated authored subjects last) and admitted whole or
    /// omitted with a recorded reason. Omission removes both the bytes and the authored wire
    /// inputs that depend on them; bytes are never relabeled or truncated. Never infer a region
    /// from rendered text.
    static func selectContext(
        functionRegions: [NativeDecompilerWireMemoryRegion],
        workspace: WorkspaceSnapshot, imageSlot: ImageSlot, validatedImage: ValidatedImage,
        layout: [VerifiedSegment], functionRange: Range<UInt64>,
        authoredInputs: NativeDecompilerWireAuthoredInputs,
        attestationErrors: [NativeDecompilerSnapshotProjectionError?],
        functionsByStart: [UInt64: [FunctionSummary]], sortedXRefs: [XRef]
    ) throws -> ContextSelection {
        func uniqueFunctionSpan(at address: UInt64) -> Range<UInt64>? {
            guard let functions = functionsByStart[address], functions.count == 1,
                  let function = functions.first,
                  function.startAddress < function.endAddress,
                  function.startAddress.isMultiple(of: 4), function.endAddress.isMultiple(of: 4)
            else { return nil }
            return function.startAddress ..< function.endAddress
        }

        // Bounded relevance search over image-local derived references.
        func references(from range: Range<UInt64>) -> ArraySlice<XRef> {
            var low = 0
            var high = sortedXRefs.count
            while low < high {
                let mid = (low + high) / 2
                if sortedXRefs[mid].from < range.lowerBound { low = mid + 1 } else { high = mid }
            }
            var end = low
            while end < sortedXRefs.count, sortedXRefs[end].from < range.upperBound { end += 1 }
            return sortedXRefs[low ..< end]
        }
        let dataReferenceKinds: Set<String> = [XRefKind.data, XRefKind.string, XRefKind.selref, XRefKind.classref]
        var functionDistance: [UInt64: Int] = [functionRange.lowerBound: 0]
        var visitedFunctions: [(range: Range<UInt64>, distance: Int)] = [(functionRange, 0)]
        var dataReferences: [(address: UInt64, distance: Int)] = []
        var frontier = [functionRange]
        for distance in 0 ..< maximumRelevanceDistance where !frontier.isEmpty {
            var next: [Range<UInt64>] = []
            for range in frontier {
                for xref in references(from: range) {
                    if xref.kind == XRefKind.call {
                        guard functionDistance[xref.to] == nil,
                              functionDistance.count < maximumRelevanceFunctions,
                              let span = uniqueFunctionSpan(at: xref.to) else { continue }
                        functionDistance[xref.to] = distance + 1
                        visitedFunctions.append((span, distance + 1))
                        next.append(span)
                    } else if dataReferenceKinds.contains(xref.kind) {
                        dataReferences.append((xref.to, distance + 1))
                    }
                }
            }
            frontier = next.sorted { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
        }
        dataReferences.sort { ($0.address, $0.distance) < ($1.address, $1.distance) }
        func dataDistance(_ range: Range<UInt64>) -> Int? {
            let floor = range.lowerBound >= referencedDataWindowBytes
                ? range.lowerBound - referencedDataWindowBytes + 1 : 0
            var low = 0
            var high = dataReferences.count
            while low < high {
                let mid = (low + high) / 2
                if dataReferences[mid].address < floor { low = mid + 1 } else { high = mid }
            }
            var best: Int?
            while low < dataReferences.count, dataReferences[low].address < range.upperBound {
                let reference = dataReferences[low]
                let (windowEnd, overflow) = reference.address.addingReportingOverflow(referencedDataWindowBytes)
                if range.contains(reference.address)
                    || (reference.address <= range.lowerBound && (overflow || range.lowerBound < windowEnd)) {
                    best = min(best ?? reference.distance, reference.distance)
                }
                low += 1
            }
            return best
        }
        func containingFunctionDistance(_ address: UInt64) -> Int? {
            visitedFunctions.filter { $0.range.contains(address) }.map { $0.distance }.min()
        }

        // Candidates: authored subjects grouped by exact extent, then derived direct references.
        var candidates: [ContextCandidate] = []
        var candidateIndex: [ContextCandidateKey: Int] = [:]
        func addCandidate(
            kind: NativeDecompilerContextSubjectKind, range: Range<UInt64>,
            requirement: ContextExecutableRequirement, unresolved: Bool = false,
            distance: Int?, mandatory: Bool, input: ContextAuthoredInput?
        ) {
            let key = ContextCandidateKey(kind: kind, lowerBound: range.lowerBound, upperBound: range.upperBound)
            if let index = candidateIndex[key] {
                if let input { candidates[index].inputs.append(input) }
                return
            }
            candidateIndex[key] = candidates.count
            candidates.append(ContextCandidate(
                kind: kind, range: range, requirement: requirement, unresolved: unresolved,
                distance: distance, isMandatory: mandatory, sequence: candidates.count,
                inputs: input.map { [$0] } ?? []
            ))
        }
        func addFunctionSubject(at address: UInt64, input: ContextAuthoredInput) {
            let mandatory = functionRange.contains(address)
            if let span = uniqueFunctionSpan(at: address) {
                addCandidate(kind: .authoredFunction, range: span, requirement: .executable,
                             distance: mandatory ? 0 : functionDistance[address],
                             mandatory: mandatory, input: input)
            } else {
                let end = address.addingReportingOverflow(4)
                let range = address ..< (end.overflow ? UInt64.max : end.partialValue)
                addCandidate(kind: .authoredFunction, range: range, requirement: .executable,
                             unresolved: true, distance: mandatory ? 0 : functionDistance[address],
                             mandatory: mandatory, input: input)
            }
        }
        for (index, signature) in authoredInputs.signatures.enumerated() {
            addFunctionSubject(at: signature.functionAddress.value, input: .signature(index))
        }
        for (index, name) in authoredInputs.names.enumerated() {
            let address = name.address.value
            switch name.subjectKind {
            case .function:
                addFunctionSubject(at: address, input: .name(index))
            case .label, .data:
                let size: UInt64 = name.subjectKind == .label ? 4 : 1
                let end = address.addingReportingOverflow(size)
                guard !end.overflow else { throw NativeDecompilerSnapshotProjectionError.invalidProjectedRequest }
                let range = address ..< end.partialValue
                let mandatory = range.overlaps(functionRange)
                let isLabel = name.subjectKind == .label
                addCandidate(
                    kind: isLabel ? .authoredLabel : .authoredData, range: range,
                    requirement: isLabel ? .executable : .nonExecutable,
                    distance: mandatory ? 0 : (isLabel ? containingFunctionDistance(address) : dataDistance(range)),
                    mandatory: mandatory, input: .name(index)
                )
            }
        }
        for (index, applied) in authoredInputs.appliedTypes.enumerated() {
            let end = applied.address.value.addingReportingOverflow(applied.byteCount.value)
            guard !end.overflow, applied.byteCount.value > 0 else {
                throw NativeDecompilerSnapshotProjectionError.invalidProjectedRequest
            }
            let range = applied.address.value ..< end.partialValue
            let mandatory = range.overlaps(functionRange)
            addCandidate(kind: .authoredAppliedType, range: range, requirement: .nonExecutable,
                         distance: mandatory ? 0 : dataDistance(range), mandatory: mandatory,
                         input: .appliedType(index))
        }
        // Derived references are image-local evidence from the selected function only. Targets
        // outside every file-backed loader segment are external and never become raw context.
        for xref in references(from: functionRange) where !functionRange.contains(xref.to) {
            guard let segment = layout.first(where: {
                xref.to >= $0.record.preferredVMStart && xref.to < $0.fileBackedVirtualEnd
            }) else { continue }
            if xref.kind == XRefKind.call {
                guard let span = uniqueFunctionSpan(at: xref.to) else { continue }
                addCandidate(kind: .derivedCallee, range: span, requirement: .executable,
                             distance: 1, mandatory: false, input: nil)
            } else if dataReferenceKinds.contains(xref.kind) {
                let remaining = segment.fileBackedVirtualEnd - xref.to
                addCandidate(kind: .derivedData,
                             range: xref.to ..< (xref.to + min(remaining, referencedDataWindowBytes)),
                             requirement: .any, distance: 1, mandatory: false, input: nil)
            }
        }

        // Validation. Every check is per subject; omission is all-or-nothing.
        let relocationSpans = validatedImage.relocations
            .map { (address: $0.address, width: UInt64($0.widthInBytes)) }
            .sorted { ($0.address, $0.width) < ($1.address, $1.width) }
        let maximumRelocationWidth = relocationSpans.map { $0.width }.max() ?? 0
        var attestationResults: [Int: NativeDecompilerSnapshotProjectionError?] = [:]
        func coverageFailure(
            _ range: Range<UInt64>, _ requirement: ContextExecutableRequirement
        ) -> ContextFailure? {
            var cursor = range.lowerBound
            for segment in layout where segment.record.preferredVMStart < range.upperBound
                && segment.fileBackedVirtualEnd > cursor {
                let protections = segment.record.initialProtections
                let executable = protections & executeProtection != 0
                guard segment.record.preferredVMStart <= cursor,
                      protections & readProtection != 0,
                      protections & writeProtection == 0,
                      requirement == .any || executable == (requirement == .executable) else {
                    let writable = segment.record.preferredVMStart <= cursor && protections & writeProtection != 0
                    return ContextFailure(reason: writable ? .writable : .unmapped,
                                          error: .effectiveLoadImageAuthorityUnavailable)
                }
                cursor = min(range.upperBound, segment.fileBackedVirtualEnd)
                if cursor == range.upperBound { break }
            }
            guard cursor == range.upperBound else {
                return ContextFailure(reason: .unmapped, error: .effectiveLoadImageAuthorityUnavailable)
            }
            return nil
        }
        func pieces(of range: Range<UInt64>) -> [ContextPiece] {
            var carved: [Range<UInt64>] = []
            if range.lowerBound < functionRange.lowerBound {
                carved.append(range.lowerBound ..< min(range.upperBound, functionRange.lowerBound))
            }
            if range.upperBound > functionRange.upperBound {
                carved.append(max(range.lowerBound, functionRange.upperBound) ..< range.upperBound)
            }
            var result: [ContextPiece] = []
            for piece in carved where !piece.isEmpty {
                for (index, segment) in layout.enumerated()
                where segment.record.preferredVMStart < piece.upperBound
                    && segment.fileBackedVirtualEnd > piece.lowerBound {
                    let start = max(piece.lowerBound, segment.record.preferredVMStart)
                    let end = min(piece.upperBound, segment.fileBackedVirtualEnd)
                    if start < end { result.append(ContextPiece(segment: index, range: start ..< end)) }
                }
            }
            return result
        }
        func mutationFailure(_ piece: ContextPiece) -> ContextFailure? {
            let range = piece.range
            let floor = range.lowerBound >= maximumRelocationWidth
                ? range.lowerBound - maximumRelocationWidth : 0
            var low = 0
            var high = relocationSpans.count
            while low < high {
                let mid = (low + high) / 2
                if relocationSpans[mid].address < floor { low = mid + 1 } else { high = mid }
            }
            while low < relocationSpans.count, relocationSpans[low].address < range.upperBound {
                let relocation = relocationSpans[low]
                let (end, overflow) = relocation.address.addingReportingOverflow(relocation.width)
                let intersects = relocation.width == 0
                    ? range.contains(relocation.address)
                    : overflow || range.lowerBound < end
                if intersects {
                    return ContextFailure(reason: .relocationIntersection, error: .intersectingRelocation)
                }
                low += 1
            }
            let attestation: NativeDecompilerSnapshotProjectionError?
            if let cached = attestationResults[piece.segment] {
                attestation = cached
            } else {
                attestation = attestationErrors[piece.segment]
                attestationResults[piece.segment] = .some(attestation)
            }
            if let attestation { return ContextFailure(reason: .unattested, error: attestation) }
            return nil
        }

        var coverage = ContextCoverage()
        let functionBytes = UInt64(functionRegions.reduce(0) { $0 + $1.rawBytes.count })
        let contextByteLimit = min(UInt64(maximumContextBytes),
                                   UInt64(maximumRegionBytes) - min(functionBytes, UInt64(maximumRegionBytes)))
        let contextRegionLimit = min(maximumContextRegions, maximumMemoryRegions - functionRegions.count)
        /// Admits a validated subject whole, or reports why it cannot be supplied.
        func admit(_ range: Range<UInt64>, _ requirement: ContextExecutableRequirement) -> ContextFailure? {
            if let failure = coverageFailure(range, requirement) { return failure }
            let subjectPieces = pieces(of: range)
            for piece in subjectPieces {
                if let failure = mutationFailure(piece) { return failure }
            }
            var tentative = coverage
            for piece in subjectPieces { tentative.insert(piece) }
            guard tentative.byteCount <= contextByteLimit else {
                return ContextFailure(reason: .budget, error: .requestTooLarge)
            }
            guard tentative.pieces.count <= contextRegionLimit else {
                return ContextFailure(reason: .budget, error: .tooManyMemoryRegions)
            }
            coverage = tentative
            return nil
        }

        // SLEIGH may read beyond the final instruction while decoding it. Supply only actual
        // sealed bytes remaining in that same executable file-backed segment. A missing tail
        // stays missing; this request-local context never changes the selected function extent.
        if let segment = layout.first(where: {
            $0.record.preferredVMStart < functionRange.upperBound
                && functionRange.upperBound < $0.fileBackedVirtualEnd
                && $0.record.initialProtections & readProtection != 0
                && $0.record.initialProtections & executeProtection != 0
                && $0.record.initialProtections & writeProtection == 0
        }) {
            let remaining = segment.fileBackedVirtualEnd - functionRange.upperBound
            let end = functionRange.upperBound + min(remaining, decoderLookaheadBytes)
            if let failure = admit(functionRange.upperBound ..< end, .executable) { throw failure.error }
        }

        var admittedInputs = Set<ContextAuthoredInput>()
        for candidate in candidates where candidate.isMandatory {
            if candidate.unresolved { throw NativeDecompilerSnapshotProjectionError.invalidProjectedRequest }
            if let failure = admit(candidate.range, candidate.requirement) { throw failure.error }
            admittedInputs.formUnion(candidate.inputs)
        }

        let kindOrder = Dictionary(uniqueKeysWithValues:
            NativeDecompilerContextSubjectKind.allCases.enumerated().map { ($1, $0) })
        let ranked = candidates.filter { !$0.isMandatory }.sorted { lhs, rhs in
            let left = (lhs.distance ?? Int.max, lhs.isAuthored ? 0 : 1, lhs.range.lowerBound)
            let right = (rhs.distance ?? Int.max, rhs.isAuthored ? 0 : 1, rhs.range.lowerBound)
            if left != right { return left < right }
            let leftTail = (lhs.range.upperBound, kindOrder[lhs.kind] ?? 0, lhs.sequence)
            let rightTail = (rhs.range.upperBound, kindOrder[rhs.kind] ?? 0, rhs.sequence)
            return leftTail < rightTail
        }
        var omissions: [NativeDecompilerContextOmission] = []
        var omittedNames = 0
        var omittedSignatures = 0
        var omittedAppliedTypes = 0
        for candidate in ranked {
            let reason: NativeDecompilerContextOmissionReason?
            if candidate.unresolved {
                reason = .unresolvedSubject
            } else {
                reason = admit(candidate.range, candidate.requirement)?.reason
            }
            guard let reason else {
                admittedInputs.formUnion(candidate.inputs)
                continue
            }
            omissions.append(NativeDecompilerContextOmission(
                subjectKind: candidate.kind, startAddress: candidate.range.lowerBound,
                endAddressExclusive: candidate.range.upperBound, reason: reason,
                relevanceDistance: candidate.distance
            ))
            for input in candidate.inputs {
                switch input {
                case .name: omittedNames += 1
                case .signature: omittedSignatures += 1
                case .appliedType: omittedAppliedTypes += 1
                }
            }
        }

        var regions = functionRegions
        for piece in coverage.pieces {
            let segment = layout[piece.segment]
            let fileStart = segment.record.sliceRelativeFileOffset + (piece.range.lowerBound - segment.record.preferredVMStart)
            let fileEnd = fileStart + (piece.range.upperBound - piece.range.lowerBound) // verified extents bound both
            guard let lower = Int(exactly: fileStart), let upper = Int(exactly: fileEnd),
                  upper <= validatedImage.selectedSliceBytes.count else {
                throw NativeDecompilerSnapshotProjectionError.effectiveLoadImageAuthorityUnavailable
            }
            let raw = validatedImage.selectedSliceBytes.subdata(in: lower ..< upper)
            regions.append(.init(name: segment.record.name, startAddress: .init(piece.range.lowerBound),
                permissions: segment.permissions, rawBytes: raw, effectiveBytes: raw, appliedPatchIDs: []))
        }
        guard regions.count <= maximumMemoryRegions else {
            throw NativeDecompilerSnapshotProjectionError.tooManyMemoryRegions
        }
        let selectedInputs = NativeDecompilerWireAuthoredInputs(
            schemaVersion: authoredInputs.schemaVersion,
            names: authoredInputs.names.indices.filter { admittedInputs.contains(.name($0)) }
                .map { authoredInputs.names[$0] },
            signatures: authoredInputs.signatures.indices.filter { admittedInputs.contains(.signature($0)) }
                .map { authoredInputs.signatures[$0] },
            appliedTypes: authoredInputs.appliedTypes.indices.filter { admittedInputs.contains(.appliedType($0)) }
                .map { authoredInputs.appliedTypes[$0] },
            typeDefinitions: authoredInputs.typeDefinitions
        )
        return ContextSelection(
            regions: regions.sorted { ($0.startAddress.value, $0.name) < ($1.startAddress.value, $1.name) },
            authoredInputs: selectedInputs,
            omissions: NativeDecompilerContextOmissionManifest(
                omissions: omissions, omittedNameCount: omittedNames,
                omittedSignatureCount: omittedSignatures, omittedAppliedTypeCount: omittedAppliedTypes
            )
        )
    }

    /// Raw selected-slice bytes are a valid effective view only where no loader relocation is
    /// known to rewrite the requested executable range. Until the app retains a complete
    /// loader-applied byte image, any intersecting relocation must make the native product lane
    /// abstain instead of relabeling raw bytes as effective bytes.
    static func rejectRelocations(
        _ relocations: [RelocationSummary],
        intersecting functionRange: Range<UInt64>
    ) throws {
        for relocation in relocations {
            let width = UInt64(relocation.widthInBytes)
            if width == 0 {
                if functionRange.contains(relocation.address) {
                    throw NativeDecompilerSnapshotProjectionError.intersectingRelocation
                }
                continue
            }
            let end = relocation.address.addingReportingOverflow(width)
            guard !end.overflow else {
                throw NativeDecompilerSnapshotProjectionError.invalidRelocationRange
            }
            if relocation.address < functionRange.upperBound
                && functionRange.lowerBound < end.partialValue
            {
                throw NativeDecompilerSnapshotProjectionError.intersectingRelocation
            }
        }
    }

    static func projectMemoryRegions(
        selectedSliceBytes: Data,
        layout: [VerifiedSegment],
        functionRange: Range<UInt64>,
        attestationErrors: [NativeDecompilerSnapshotProjectionError?]
    ) throws -> [NativeDecompilerWireMemoryRegion] {
        var result: [NativeDecompilerWireMemoryRegion] = []
        var cursor = functionRange.lowerBound
        var totalBytes = 0

        for (segmentIndex, segment) in layout.enumerated() where segment.record.fileSize > 0 {
            let start = max(functionRange.lowerBound, segment.record.preferredVMStart)
            let end = min(functionRange.upperBound, segment.fileBackedVirtualEnd)
            guard start < end else { continue }
            guard start == cursor,
                  segment.record.initialProtections & readProtection != 0,
                  segment.record.initialProtections & executeProtection != 0,
                  segment.record.initialProtections & writeProtection == 0
            else {
                throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
            }
            if let failure = attestationErrors[segmentIndex] { throw failure }
            let displacement = start - segment.record.preferredVMStart
            let fileStart = segment.record.sliceRelativeFileOffset.addingReportingOverflow(displacement)
            let regionByteCount = end - start
            let fileEnd = fileStart.partialValue.addingReportingOverflow(regionByteCount)
            guard !fileStart.overflow,
                  !fileEnd.overflow,
                  fileEnd.partialValue <= UInt64(selectedSliceBytes.count),
                  fileStart.partialValue <= UInt64(Int.max),
                  fileEnd.partialValue <= UInt64(Int.max),
                  regionByteCount <= UInt64(Int.max),
                  Int(regionByteCount) <= maximumRegionBytes - totalBytes
            else {
                throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
            }
            let lower = selectedSliceBytes.index(
                selectedSliceBytes.startIndex,
                offsetBy: Int(fileStart.partialValue)
            )
            let upper = selectedSliceBytes.index(
                selectedSliceBytes.startIndex,
                offsetBy: Int(fileEnd.partialValue)
            )
            let rawBytes = Data(selectedSliceBytes[lower ..< upper])
            guard !rawBytes.isEmpty else {
                throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
            }
            result.append(NativeDecompilerWireMemoryRegion(
                name: segment.record.name,
                startAddress: .init(start),
                permissions: segment.permissions,
                rawBytes: rawBytes,
                effectiveBytes: Data(rawBytes),
                appliedPatchIDs: []
            ))
            totalBytes += rawBytes.count
            cursor = end
            if result.count > maximumMemoryRegions {
                throw NativeDecompilerSnapshotProjectionError.tooManyMemoryRegions
            }
            if cursor == functionRange.upperBound { break }
        }
        guard cursor == functionRange.upperBound, !result.isEmpty else {
            throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
        }
        return result
    }

    static func validateIdentityEffectiveByteAuthority(
        for segment: VerifiedSegment,
        selectedSliceBytes: Data,
        artifact: MachOSliceArtifactIdentity,
        attestations: [IdentityEffectiveByteRangeAttestation]
    ) throws {
        let matching = attestations.filter {
            $0.artifactIdentity == artifact
                && $0.segmentName == segment.record.name
                && $0.startAddress == segment.record.preferredVMStart
                && $0.endAddressExclusive == segment.fileBackedVirtualEnd
                && $0.sliceRelativeFileOffset == segment.record.sliceRelativeFileOffset
                && $0.byteCount == segment.record.fileSize
                && $0.initialProtections == segment.record.initialProtections
        }
        guard matching.count == 1, let attestation = matching.first else {
            throw NativeDecompilerSnapshotProjectionError.effectiveLoadImageAuthorityUnavailable
        }
        let fileEnd = attestation.sliceRelativeFileOffset.addingReportingOverflow(
            attestation.byteCount
        )
        guard !fileEnd.overflow,
              fileEnd.partialValue <= UInt64(selectedSliceBytes.count),
              let lower = Int(exactly: attestation.sliceRelativeFileOffset),
              let upper = Int(exactly: fileEnd.partialValue),
              AnalysisFingerprintBuilder.sha256Hex(
                  selectedSliceBytes.subdata(in: lower..<upper)
              ) == attestation.rawBytesSHA256 else {
            throw NativeDecompilerSnapshotProjectionError.invalidEffectiveLoadImageAttestation
        }
    }

    static func projectSymbols(
        _ source: [SymbolSummary],
        functions: [FunctionSummary],
        imageID: String
    ) throws -> [NativeDecompilerWireSymbolRecord] {
        let functionStarts = Set(functions.map(\.startAddress))
        var records: [NativeDecompilerWireSymbolRecord] = []
        records.reserveCapacity(min(source.count, maximumSymbols + 1))
        var seen = Set<ProjectedSymbolKey>()

        for symbol in source {
            guard let address = symbol.address,
                  let rawName = symbol.rawLinkageName,
                  isWireText(rawName, maximum: 1_024)
            else { continue }
            let kind = symbolKind(
                loaderKind: symbol.kind,
                address: address,
                functionStarts: functionStarts
            )
            let key = ProjectedSymbolKey(
                address: address,
                kind: kind.rawValue,
                name: rawName,
                imageID: imageID
            )
            guard seen.insert(key).inserted else { continue }
            records.append(NativeDecompilerWireSymbolRecord(
                imageID: imageID,
                address: .init(address),
                name: rawName,
                kind: kind
            ))
            if records.count > maximumSymbols {
                throw NativeDecompilerSnapshotProjectionError.tooManySymbols
            }
        }
        records.sort {
            if $0.address.value != $1.address.value { return $0.address.value < $1.address.value }
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.imageID < $1.imageID
        }
        return records
    }

    static func symbolKind(
        loaderKind: String,
        address: UInt64,
        functionStarts: Set<UInt64>
    ) -> NativeDecompilerWireSymbolKind {
        switch loaderKind.lowercased() {
        case NativeDecompilerWireSymbolKind.alias.rawValue: return .alias
        case NativeDecompilerWireSymbolKind.data.rawValue: return .data
        case NativeDecompilerWireSymbolKind.function.rawValue: return .function
        case NativeDecompilerWireSymbolKind.label.rawValue: return .label
        case NativeDecompilerWireSymbolKind.object.rawValue: return .object
        case NativeDecompilerWireSymbolKind.section.rawValue: return .section
        default: return functionStarts.contains(address) ? .function : .unknown
        }
    }

    static func permissions(_ raw: Int32) -> NativeDecompilerWireMemoryPermissions {
        switch raw & knownProtections {
        case 0: .none
        case readProtection: .read
        case writeProtection: .write
        case executeProtection: .execute
        case readProtection | writeProtection: .readWrite
        case readProtection | executeProtection: .readExecute
        case writeProtection | executeProtection: .writeExecute
        default: .readWriteExecute
        }
    }

    static func isWireText(_ value: String, maximum: Int) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= maximum
            && !bytes.contains(where: { $0 < 0x20 || $0 == 0x7F })
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

}

/// Loader-layout verification and image-base derivation are internal (not private) so their
/// fail-closed vectors are directly unit-testable.
extension NativeDecompilerSnapshotBuilder {
    struct VerifiedSegment: Sendable {
        let record: MachOPreferredSegmentLayout.Record
        /// False for a file-only record (vmsize 0, filesize > 0, e.g. Go's __DWARF). Its
        /// file span is verified evidence, but it contributes no virtual bytes: both
        /// virtual ends collapse to its start so it can never cover an address.
        let isMapped: Bool
        let virtualEnd: UInt64
        let fileEnd: UInt64
        let fileBackedVirtualEnd: UInt64
        let permissions: NativeDecompilerWireMemoryPermissions
    }

    /// The only segments eligible for native virtual regions and base derivation.
    static func mappedSegments(_ layout: [VerifiedSegment]) -> [VerifiedSegment] {
        layout.filter(\.isMapped)
    }

    struct ProjectedSymbolKey: Hashable {
        let address: UInt64
        let kind: String
        let name: String
        let imageID: String
    }

    static func verifyLayout(
        _ records: [MachOPreferredSegmentLayout.Record],
        selectedSliceByteCount: UInt64
    ) throws -> [VerifiedSegment] {
        guard !records.isEmpty else {
            throw NativeDecompilerSnapshotProjectionError.invalidSegmentLayout
        }
        var verified: [VerifiedSegment] = []
        verified.reserveCapacity(records.count)
        for record in records {
            // vmsize 0 is admitted only as a file-only record that carries file bytes.
            // Such a record maps nothing, so its file size is not bounded by (or
            // projected onto) virtual memory. A mapped record keeps the strict
            // filesize <= vmsize and no-wrap virtual geometry rules.
            let isMapped = record.preferredVMSize > 0
            let virtualEnd = record.preferredVMStart.addingReportingOverflow(record.preferredVMSize)
            let fileEnd = record.sliceRelativeFileOffset.addingReportingOverflow(record.fileSize)
            let fileBackedVirtualEnd = isMapped
                ? record.preferredVMStart.addingReportingOverflow(record.fileSize)
                : (partialValue: record.preferredVMStart, overflow: false)
            guard isMapped || record.fileSize > 0,
                  !virtualEnd.overflow,
                  !fileEnd.overflow,
                  !fileBackedVirtualEnd.overflow,
                  !isMapped || record.fileSize <= record.preferredVMSize,
                  fileEnd.partialValue <= selectedSliceByteCount,
                  record.initialProtections >= 0,
                  (record.initialProtections & ~knownProtections) == 0,
                  isWireText(record.name, maximum: 256)
            else {
                throw NativeDecompilerSnapshotProjectionError.invalidSegmentLayout
            }
            verified.append(VerifiedSegment(
                record: record,
                isMapped: isMapped,
                virtualEnd: virtualEnd.partialValue,
                fileEnd: fileEnd.partialValue,
                fileBackedVirtualEnd: fileBackedVirtualEnd.partialValue,
                permissions: permissions(record.initialProtections)
            ))
        }

        verified.sort {
            if $0.record.preferredVMStart != $1.record.preferredVMStart {
                return $0.record.preferredVMStart < $1.record.preferredVMStart
            }
            if $0.virtualEnd != $1.virtualEnd { return $0.virtualEnd < $1.virtualEnd }
            if $0.record.sliceRelativeFileOffset != $1.record.sliceRelativeFileOffset {
                return $0.record.sliceRelativeFileOffset < $1.record.sliceRelativeFileOffset
            }
            return $0.record.name < $1.record.name
        }
        var priorVirtualEnd: UInt64?
        for segment in verified where segment.isMapped {
            if let priorVirtualEnd, segment.record.preferredVMStart < priorVirtualEnd {
                throw NativeDecompilerSnapshotProjectionError.overlappingSegmentLayout
            }
            priorVirtualEnd = segment.virtualEnd
        }

        let fileBacked = verified.filter { $0.record.fileSize > 0 }.sorted {
            if $0.record.sliceRelativeFileOffset != $1.record.sliceRelativeFileOffset {
                return $0.record.sliceRelativeFileOffset < $1.record.sliceRelativeFileOffset
            }
            if $0.fileEnd != $1.fileEnd { return $0.fileEnd < $1.fileEnd }
            return $0.record.name < $1.record.name
        }
        var priorFileEnd: UInt64?
        for segment in fileBacked {
            if let priorFileEnd, segment.record.sliceRelativeFileOffset < priorFileEnd {
                throw NativeDecompilerSnapshotProjectionError.overlappingSegmentLayout
            }
            priorFileEnd = segment.fileEnd
        }
        return verified
    }

    static func derivePreferredLoadAddress(from layout: [VerifiedSegment]) throws -> UInt64 {
        // The preferred load address is the image base as the loader defines it: the
        // preferred vmaddr of the mapped segment that maps the Mach-O header, i.e. whose
        // file bytes start at slice offset 0 (normally __TEXT), so base = vmaddr - 0.
        // dyld slides every segment by one amount, but vmaddr - fileoff need not agree
        // across segments: zero-fill (vmsize > filesize) in __DATA pushes the following
        // __LINKEDIT up. /usr/bin/vim arm64e: __TEXT/__DATA_CONST/__DATA give 0x100000000,
        // __LINKEDIT gives 0x100010000. Native memory regions carry each segment's own
        // vmaddr and file offset (projectMemoryRegions), and the bridge treats this value
        // as image identity only, so other segments must not share the header relation.
        // Fail closed: no mapped header segment is an error, as is any mapped file-backed
        // segment whose vmaddr lies below its file offset. Overflowing geometry and
        // overlapping segments are rejected earlier by verifyLayout.
        // A file-only record (vmsize 0) maps nothing: it can never be the header segment.
        var headerSegments: [VerifiedSegment] = []
        for segment in mappedSegments(layout) where segment.record.fileSize > 0 {
            guard segment.record.preferredVMStart >= segment.record.sliceRelativeFileOffset else {
                throw NativeDecompilerSnapshotProjectionError.invalidSegmentLayout
            }
            if segment.record.sliceRelativeFileOffset == 0 {
                headerSegments.append(segment)
            }
        }
        guard headerSegments.count == 1, let header = headerSegments.first else {
            throw NativeDecompilerSnapshotProjectionError.missingHeaderMappingSegment
        }
        return header.record.preferredVMStart
    }
}
