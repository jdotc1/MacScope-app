import Foundation

/// Projects the frozen R1 operations from one immutable, app-owned workspace cut.
/// The projector has no authority of its own: it consumes an exact app authorization and
/// returns inert typed facts qualified by that authorization's subject and dependencies.
enum Phase2ReadProjector {
    static func project(
        authorization: Phase2ReadAuthorization,
        input: Phase2ReadProjectionInput
    ) -> Phase2ReadEvidenceCandidate {
        guard authorization.isValid else {
            return candidate(.unavailable(.unavailable), authorization: authorization)
        }

        let freshness = authorization.request.precondition.compared(to: input.currentState)
        guard freshness.isCurrent else {
            let reason: Phase2ReadUnavailableReason = freshness.isOwnerCurrent
                ? .unavailable
                : .unresolvedOwner
            return candidate(.unavailable(reason), authorization: authorization)
        }

        switch (authorization.canonicalDescriptor.id, authorization.request.subject) {
        case let (.reaResultsList, .workspace(workspace)), let (.reaResultsGet, .workspace(workspace)):
            guard workspace == authorization.request.precondition.workspace else {
                return candidate(.unavailable(.unresolvedOwner), authorization: authorization)
            }
            return projectREA(authorization: authorization, input: input)

        case let (.workspaceSummary, .workspace(workspace)):
            guard workspace == authorization.request.precondition.workspace else {
                return candidate(.unavailable(.unresolvedOwner), authorization: authorization)
            }
            return projectWorkspaceSummary(authorization: authorization, input: input)

        case let (.applicationGraphSummary, .workspace(workspace)):
            guard workspace == authorization.request.precondition.workspace,
                  let image = authorization.request.precondition.image,
                  let analysis = authorizedAnalysis(for: image, in: input.snapshot),
                  let binary = input.snapshot.binary(in: image.slot)
            else {
                return candidate(.unavailable(.unresolvedOwner), authorization: authorization)
            }
            return projectApplicationGraphSummary(
                image: image,
                binary: binary,
                analysis: analysis,
                authorization: authorization,
                input: input
            )

        case let (.selectionExplain, .staticLocation(location)):
            guard location.domain == .imageVirtualAddress,
                  location.image == authorization.request.precondition.image,
                  let analysis = authorizedAnalysis(for: location.image, in: input.snapshot)
            else {
                return candidate(.unavailable(.unresolvedOwner), authorization: authorization)
            }
            return projectSelection(
                location: location,
                analysis: analysis,
                authorization: authorization
            )

        case let (.functionReview, .functionRange(range)):
            guard range.isValid,
                  range.image == authorization.request.precondition.image,
                  let analysis = authorizedAnalysis(for: range.image, in: input.snapshot)
            else {
                return candidate(.unavailable(.unresolvedOwner), authorization: authorization)
            }
            return projectFunction(
                range: range,
                analysis: analysis,
                authorization: authorization
            )

        case let (.functionCallSites, .functionRange(range)):
            guard range.isValid,
                  range.image == authorization.request.precondition.image,
                  let analysis = authorizedAnalysis(for: range.image, in: input.snapshot)
            else {
                return candidate(.unavailable(.unresolvedOwner), authorization: authorization)
            }
            return Phase2FunctionCallSitesProjector.project(
                range: range, analysis: analysis, authorization: authorization
            )

        case let (.decompilerNativeResult, .functionRange(range)):
            return projectNativeDecompiler(
                range: range,
                authorization: authorization,
                input: input
            )

        case let (.decompilerMacScopeResult, .functionRange(range)):
            return projectMacScopeDecompiler(
                range: range,
                authorization: authorization,
                input: input
            )

        case let (.decompilerCompare, .functionRange(range)):
            return projectDecompilerComparison(
                range: range,
                authorization: authorization,
                input: input
            )

        default:
            return candidate(.unavailable(.unavailable), authorization: authorization)
        }
    }

    private static func projectREA(authorization: Phase2ReadAuthorization,
                                   input: Phase2ReadProjectionInput) -> Phase2ReadEvidenceCandidate {
        guard let store = input.reaResultStore, let workspaceID = input.reaWorkspaceID else {
            return candidate(.unavailable(.notFound), authorization: authorization)
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let selector = authorization.request.reaResultRead ?? .init()
            let bytes: Data
            if authorization.canonicalDescriptor.id == .reaResultsList {
                bytes = try encoder.encode(REAResultReadProjection.list(store: store, workspaceID: workspaceID,
                    activeAuthority: input.reaActiveAuthority, offset: selector.offset,
                    maximumRecords: min(REAResultReadProjection.maximumListRecords, authorization.approvedLimits.pageItems)))
            } else {
                guard let evidenceID = selector.evidenceID, let digest = selector.responseSHA256 else {
                    return candidate(.unavailable(.notFound), authorization: authorization)
                }
                let pageBytes = min(REAResultReadProjection.maximumPageBytes,
                    max(1, (authorization.approvedLimits.stringBytes - 2048) / 2))
                bytes = try encoder.encode(REAResultReadProjection.getText(store: store, workspaceID: workspaceID,
                    activeAuthority: input.reaActiveAuthority, evidenceID: evidenceID, responseSHA256: digest,
                    offset: selector.offset, maximumBytes: pageBytes))
            }
            guard bytes.count <= authorization.approvedLimits.stringBytes,
                  bytes.count <= authorization.approvedLimits.encodedResultBytes / 2,
                  let text = String(data: bytes, encoding: .utf8) else {
                return candidate(.unavailable(.unavailable), authorization: authorization)
            }
            return candidate(.value(.object([field("acceptedREAResult", .text(text))])), authorization: authorization)
        } catch {
            return candidate(.unavailable(.notFound), authorization: authorization)
        }
    }

    private static func projectWorkspaceSummary(
        authorization: Phase2ReadAuthorization,
        input: Phase2ReadProjectionInput
    ) -> Phase2ReadEvidenceCandidate {
        var fields = [
            field("workspaceName", .text(input.workspaceName)),
            field("loadedImageCount", .unsignedInteger(UInt64(input.snapshot.binaries.count))),
        ]

        if let focusedSlot = input.focusedImageSlot,
           let authorizedImage = authorization.request.precondition.image,
           authorizedImage.slot == focusedSlot,
           let analysis = authorizedAnalysis(for: authorizedImage, in: input.snapshot),
           let binary = input.snapshot.binary(in: focusedSlot) {
            fields.append(field("focusedImage", .object([
                field("name", .text(binary.name)),
                field("functionCount", .unsignedInteger(UInt64(analysis.functions.count))),
            ])))
        }

        return candidate(.value(.object(fields)), authorization: authorization)
    }

    private static func projectApplicationGraphSummary(
        image: Phase2ReadImageIdentity,
        binary: BinaryImage,
        analysis: ImageAnalysis,
        authorization: Phase2ReadAuthorization,
        input: Phase2ReadProjectionInput
    ) -> Phase2ReadEvidenceCandidate {
        guard analysis.machOMetadata != nil else {
            return candidate(.unavailable(.notFound), authorization: authorization)
        }

        let graph = ApplicationImageGraphBuilder().build(from: input.snapshot)
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let edges = graph.edges.filter { $0.fromSlot == image.slot }
        let returned = Array(edges.prefix(authorization.approvedLimits.pageItems))
        let dependencyItems = returned.map { edge in
            applicationGraphDependencyValue(
                edge,
                source: binary,
                target: nodesByID[edge.toNodeID]
            )
        }
        let resolvedCount = edges.filter(\.phase2IsResolvedWorkspaceImage).count
        let externalCount = edges.filter(\.phase2IsExternal).count
        let unresolvedCount = edges.filter(\.phase2IsUnresolved).count

        return candidate(
            .value(.object([
                field("focusedImage", .object([
                    field("slot", .unsignedInteger(UInt64(image.slot.rawValue))),
                    field("binaryID", .text(image.binaryID.uuidString)),
                    field("name", .text(binary.name)),
                    field("path", .text(binary.resolvedExecutablePath ?? binary.path)),
                ])),
                field("loadedImageCount", .unsignedInteger(UInt64(input.snapshot.binaries.count))),
                field("declaredDependencyCount", .unsignedInteger(UInt64(edges.count))),
                field("resolvedWorkspaceDependencyCount", .unsignedInteger(UInt64(resolvedCount))),
                field("externalDependencyCount", .unsignedInteger(UInt64(externalCount))),
                field("unresolvedDependencyCount", .unsignedInteger(UInt64(unresolvedCount))),
                field("dependencyPage", .object([
                    field("totalCount", .unsignedInteger(UInt64(edges.count))),
                    field("returnedCount", .unsignedInteger(UInt64(returned.count))),
                    field("omittedCount", .unsignedInteger(UInt64(edges.count - returned.count))),
                    field("items", .list(dependencyItems)),
                ])),
            ])),
            authorization: authorization
        )
    }

    private static func projectSelection(
        location: Phase2ReadStaticLocation,
        analysis: ImageAnalysis,
        authorization: Phase2ReadAuthorization
    ) -> Phase2ReadEvidenceCandidate {
        let instructions = analysis.instructions
            .filter { $0.address == location.address }
            .sorted(by: instructionOrder)
        guard instructions.count <= 1 else {
            return candidate(.unavailable(.ambiguous), authorization: authorization)
        }

        let functions = analysis.functions.filter { function in
            function.endAddress > function.startAddress
                && location.address >= function.startAddress
                && location.address < function.endAddress
        }
        guard functions.count <= 1 else {
            return candidate(.unavailable(.ambiguous), authorization: authorization)
        }

        let instructionValues = instructions.map(instructionValue)
        let functionValues = functions.map { function in
            Phase2ReadFactValue.object([
                field("name", .text(function.name)),
                field("start", .unsignedInteger(function.startAddress)),
                field("endExclusive", .unsignedInteger(function.endAddress)),
            ])
        }
        return candidate(
            .value(.object([
                field("location", .staticLocation(location)),
                field("instruction", .list(instructionValues)),
                field("function", .list(functionValues)),
            ])),
            authorization: authorization
        )
    }

    private static func projectFunction(
        range: Phase2ReadFunctionRange,
        analysis: ImageAnalysis,
        authorization: Phase2ReadAuthorization
    ) -> Phase2ReadEvidenceCandidate {
        let exactFunctions = analysis.functions.filter {
            $0.startAddress == range.start && $0.endAddress == range.endExclusive
        }
        guard exactFunctions.count == 1, let function = exactFunctions.first else {
            return candidate(
                .unavailable(exactFunctions.isEmpty ? .notFound : .ambiguous),
                authorization: authorization
            )
        }

        let instructions = analysis.instructions
            .filter { $0.address >= range.start && $0.address < range.endExclusive }
            .sorted(by: instructionOrder)
        let returned = Array(instructions.prefix(authorization.approvedLimits.pageItems))

        let page = Phase2ReadFactValue.object([
            field("totalCount", .unsignedInteger(UInt64(instructions.count))),
            field("returnedCount", .unsignedInteger(UInt64(returned.count))),
            field("omittedCount", .unsignedInteger(UInt64(instructions.count - returned.count))),
            field("items", .list(returned.map(instructionValue))),
        ])
        return candidate(
            .value(.object([
                field("name", .text(function.name)),
                field("start", .unsignedInteger(range.start)),
                field("endExclusive", .unsignedInteger(range.endExclusive)),
                field("instructionPage", page),
            ])),
            authorization: authorization
        )
    }

    private static func projectNativeDecompiler(
        range: Phase2ReadFunctionRange,
        authorization: Phase2ReadAuthorization,
        input: Phase2ReadProjectionInput
    ) -> Phase2ReadEvidenceCandidate {
        switch nativeDecompilerValue(
            range: range,
            authorization: authorization,
            input: input
        ) {
        case .value(let value):
            return candidate(.value(value), authorization: authorization)
        case .unavailable(let reason):
            return candidate(.unavailable(reason), authorization: authorization)
        }
    }

    private static func projectMacScopeDecompiler(
        range: Phase2ReadFunctionRange,
        authorization: Phase2ReadAuthorization,
        input: Phase2ReadProjectionInput
    ) -> Phase2ReadEvidenceCandidate {
        guard let value = macScopeDecompilerValue(
            range: range,
            authorization: authorization,
            input: input
        ) else {
            return candidate(.unavailable(.notFound), authorization: authorization)
        }
        return candidate(.value(value), authorization: authorization)
    }

    private static func projectDecompilerComparison(
        range: Phase2ReadFunctionRange,
        authorization: Phase2ReadAuthorization,
        input: Phase2ReadProjectionInput
    ) -> Phase2ReadEvidenceCandidate {
        guard range.isValid,
              range.image == authorization.request.precondition.image,
              let analysis = authorizedAnalysis(for: range.image, in: input.snapshot),
              let function = analysis.functions.first(where: {
                  $0.startAddress == range.start && $0.endAddress == range.endExclusive
              }),
              let expected = decompilerPresentationIdentity(for: range, in: input.snapshot)
        else {
            return candidate(.unavailable(.notFound), authorization: authorization)
        }

        let nativePresentation = NativePseudocodePresentation.project(
            state: input.nativeDecompilerState,
            expected: expected,
            macScopeIsAvailable: false
        )
        if nativePresentation.status == .stale {
            return candidate(.unavailable(.unresolvedOwner), authorization: authorization)
        }

        let nativeCoordinate: NativeDecompilerPresentationCoordinate?
        let nativeSuccess: NativeDecompilerWireSuccess?
        if nativePresentation.status == .ready,
           case let .ready(coordinate, success) = input.nativeDecompilerState {
            nativeCoordinate = coordinate
            nativeSuccess = success
        } else {
            nativeCoordinate = nil
            nativeSuccess = nil
        }
        let comparison = DecompilerComparisonProjection.project(
            coordinate: nativeCoordinate,
            expected: expected,
            native: nativeSuccess,
            macScope: NativeDecompilerMacScopeComparisonInput(
                analysis: analysis,
                function: function
            )
        )
        switch comparison {
        case let .ready(value):
            return candidate(
                .value(.object([
                    field("source", .text("comparison")),
                    field("status", .text("ready")),
                    field("start", .unsignedInteger(range.start)),
                    field("endExclusive", .unsignedInteger(range.endExclusive)),
                    field("normalizerID", .text(value.structural.normalizerID)),
                    field(
                        "categories",
                        .list(value.structural.categories.map(comparisonCategoryValue))
                    ),
                ])),
                authorization: authorization,
                citationCount: 2
            )
        case .unavailable(.coordinateMismatch):
            return candidate(.unavailable(.unresolvedOwner), authorization: authorization)
        case .unavailable(.nativeUnavailable):
            return candidate(.unavailable(.unavailable), authorization: authorization)
        case .unavailable(.macScopeUnavailable):
            return candidate(.unavailable(.notFound), authorization: authorization)
        case .unavailable(.invalidStructure):
            return candidate(.unavailable(.unavailable), authorization: authorization)
        }
    }

    private static func comparisonCategoryValue(
        _ result: NativeDecompilerComparisonCategoryResult
    ) -> Phase2ReadFactValue {
        .object([
            field("category", .text(result.category.rawValue)),
            field("matchedCount", .unsignedInteger(UInt64(result.counts.matchedCount))),
            field("nativeOnlyCount", .unsignedInteger(UInt64(result.counts.nativeOnlyCount))),
            field("macScopeOnlyCount", .unsignedInteger(UInt64(result.counts.macScopeOnlyCount))),
            field(
                "uncomparableNativeCount",
                .unsignedInteger(UInt64(result.counts.uncomparableNativeCount))
            ),
            field(
                "uncomparableMacScopeCount",
                .unsignedInteger(UInt64(result.counts.uncomparableMacScopeCount))
            ),
            field(
                "comparableUnionDenominator",
                .unsignedInteger(UInt64(result.counts.comparableUnionDenominator))
            ),
            field(
                "qualificationDenominator",
                .unsignedInteger(UInt64(result.counts.qualificationDenominator))
            ),
            field("coverage", .text(result.coverage.rawValue)),
            field("correspondence", .text(result.correspondence.rawValue)),
            field("nativeOnlySamples", .list(result.samples.nativeOnly.map(comparisonTupleValue))),
            field("macScopeOnlySamples", .list(result.samples.macScopeOnly.map(comparisonTupleValue))),
            field(
                "uncomparableNativeSamples",
                .list(result.samples.uncomparableNative.map(comparisonUncomparableValue))
            ),
            field(
                "uncomparableMacScopeSamples",
                .list(result.samples.uncomparableMacScope.map(comparisonUncomparableValue))
            ),
        ])
    }

    private static func comparisonTupleValue(
        _ sample: NativeDecompilerComparisonTupleSample
    ) -> Phase2ReadFactValue {
        switch sample {
        case let .instruction(address):
            .object([
                field("kind", .text("instruction")),
                field("address", .unsignedInteger(address)),
            ])
        case let .block(startAddress, endAddressExclusive):
            .object([
                field("kind", .text("block")),
                field("start", .unsignedInteger(startAddress)),
                field("endExclusive", .unsignedInteger(endAddressExclusive)),
            ])
        case let .edge(sourceBlockStart, targetBlockStart, kind):
            .object([
                field("kind", .text("edge")),
                field("sourceBlockStart", .unsignedInteger(sourceBlockStart)),
                field("targetBlockStart", .unsignedInteger(targetBlockStart)),
                field("edgeKind", .unsignedInteger(UInt64(kind.rawValue))),
            ])
        case let .call(sourceInstructionStart, targetAddress):
            .object([
                field("kind", .text("call")),
                field("sourceInstructionStart", .unsignedInteger(sourceInstructionStart)),
                field("targetAddress", .unsignedInteger(targetAddress)),
            ])
        }
    }

    private static func comparisonUncomparableValue(
        _ sample: NativeDecompilerComparisonUncomparableSample
    ) -> Phase2ReadFactValue {
        var fields = [field("reason", .text(sample.reason.rawValue))]
        if let primary = sample.primarySafeAddress {
            fields.append(field("primaryAddress", .unsignedInteger(primary)))
        }
        if let secondary = sample.secondarySafeAddress {
            fields.append(field("secondaryAddress", .unsignedInteger(secondary)))
        }
        return .object(fields)
    }

    private enum DecompilerProjectionValue {
        case value(Phase2ReadFactValue)
        case unavailable(Phase2ReadUnavailableReason)
    }

    private static func nativeDecompilerValue(
        range: Phase2ReadFunctionRange,
        authorization: Phase2ReadAuthorization,
        input: Phase2ReadProjectionInput
    ) -> DecompilerProjectionValue {
        guard range.isValid,
              range.image == authorization.request.precondition.image,
              let expected = decompilerPresentationIdentity(for: range, in: input.snapshot)
        else {
            return .unavailable(.unresolvedOwner)
        }

        let presentation = NativePseudocodePresentation.project(
            state: input.nativeDecompilerState,
            expected: expected,
            macScopeIsAvailable: false
        )
        guard presentation.status == .ready,
              let document = presentation.document,
              let provider = presentation.provider,
              case let .ready(_, success) = input.nativeDecompilerState
        else {
            return .unavailable(presentation.status == .stale ? .unresolvedOwner : .unavailable)
        }

        let bounded = boundedUTF8(
            document.text,
            maximumBytes: authorization.approvedLimits.stringBytes
        )
        let counts = DecompilerRecordCounts(result: success.result)
        return .value(.object([
            field("source", .text("native")),
            field("status", .text(document.isTruncated || bounded.truncated ? "truncated" : "ready")),
            field("functionName", .text(success.result.function.name)),
            field("start", .unsignedInteger(range.start)),
            field("endExclusive", .unsignedInteger(range.endExclusive)),
            field("pseudocode", .object([
                field("text", .text(bounded.text)),
                field("language", .text(document.language)),
                field("isComplete", .boolean(document.isComplete && !bounded.truncated)),
                field("isTruncated", .boolean(document.isTruncated || bounded.truncated)),
            ])),
            field("counts", decompilerCountValue(counts, warningCount: success.result.warnings.count)),
            field("authenticationSummary", authenticationSummary(result: success.result,
                range: range, limits: authorization.approvedLimits)),
            field("provider", .object([
                field("backendID", .text(provider.backendID)),
                field("engineVersion", .text(provider.engineVersion)),
                field("wrapperVersion", .text(provider.wrapperVersion)),
            ])),
        ]))
    }

    /// The validated wire effect is evidence, never a recovered address/target.
    /// No rendered text or unrestricted operation stream enters this projection.
    private static func authenticationSummary(result: NativeDecompilerWireStructuredResult,
        range: Phase2ReadFunctionRange, limits: Phase2ReadLimits) -> Phase2ReadFactValue {
        let operations = result.operations.filter { $0.authenticationEffect.kind != .none }
        let cap = max(0, min(32, limits.pageItems, limits.arrayItems))
        let rangeCap = max(0, min(8, limits.arrayItems))
        var samples: [Phase2ReadFactValue] = []
        var truncated = operations.count > cap
        func summary(_ samples: [Phase2ReadFactValue], truncated: Bool) -> Phase2ReadFactValue {
            .object([
                field("summaryVersion", .unsignedInteger(1)),
                field("totalCount", .unsignedInteger(UInt64(operations.count))),
                field("returnedCount", .unsignedInteger(UInt64(samples.count))),
                field("transformedOutputCount", .unsignedInteger(UInt64(operations.filter {
                    $0.authenticationEffect.kind == .transformedOutput }.count))),
                field("incompleteAddressCount", .unsignedInteger(UInt64(operations.filter {
                    $0.authenticationEffect.kind == .authenticatedMemoryAccessWithoutTransformedAddress }.count))),
                field("incompleteTargetCount", .unsignedInteger(UInt64(operations.filter {
                    $0.authenticationEffect.kind == .authenticatedControlTransferWithoutTransformedTarget }.count))),
                field("truncated", .boolean(truncated)), field("samples", .list(samples)),
            ])
        }
        for operation in operations.prefix(cap) {
            let effect = operation.authenticationEffect
            // Identifiers are never truncated into a different authority.
            let strings = [operation.id, operation.userOperationName ?? "", effect.outputSSAValueID ?? ""]
                + operation.sourceRanges.prefix(rangeCap).map(\.imageID)
            guard operation.opcode == .callother, let userOperationName = operation.userOperationName,
                  strings.allSatisfy({ $0.utf8.count <= limits.stringBytes }) else {
                truncated = true; continue
            }
            let ranges = operation.sourceRanges.prefix(rangeCap).map { source in
                Phase2ReadFactValue.object([
                    field("imageID", .text(source.imageID)),
                    field("imageSlot", .signedInteger(Int64(range.image.slot.rawValue))),
                    field("binaryID", .text(range.image.binaryID.uuidString.lowercased())),
                    field("start", .unsignedInteger(source.startAddress.value)),
                    field("endExclusive", .unsignedInteger(source.endAddressExclusive.value)),
                ])
            }
            let rangesTruncated = operation.sourceRanges.count > rangeCap
            var fields = [field("operationID", .text(operation.id)),
                field("opcode", .text(operation.opcode.rawValue)),
                field("userOperationName", .text(userOperationName)),
                field("effect", .text(effect.kind.rawValue)),
                field("outputSSAProvidesRecoveredAddressOrTarget", .boolean(false)),
                field("transformedAddressUnavailable", .boolean(effect.kind == .authenticatedMemoryAccessWithoutTransformedAddress)),
                field("transformedTargetUnavailable", .boolean(effect.kind == .authenticatedControlTransferWithoutTransformedTarget)),
                field("sourceRangeCount", .unsignedInteger(UInt64(operation.sourceRanges.count))),
                field("sourceRangesTruncated", .boolean(rangesTruncated)),
                field("sourceRanges", .list(ranges))]
            if let output = effect.outputSSAValueID { fields.append(field("outputSSAValueID", .text(output))) }
            let candidate = samples + [.object(fields)]
            guard let bytes = try? JSONEncoder().encode(summary(candidate, truncated: true)),
                  bytes.count <= min(32 * 1_024, limits.encodedResultBytes / 2) else {
                truncated = true; break
            }
            samples = candidate
            truncated = truncated || rangesTruncated
        }
        return summary(samples, truncated: truncated)
    }

    private static func macScopeDecompilerValue(
        range: Phase2ReadFunctionRange,
        authorization: Phase2ReadAuthorization,
        input: Phase2ReadProjectionInput
    ) -> Phase2ReadFactValue? {
        guard range.isValid,
              range.image == authorization.request.precondition.image,
              let analysis = authorizedAnalysis(for: range.image, in: input.snapshot),
              let function = analysis.functions.first(where: {
                  $0.startAddress == range.start && $0.endAddress == range.endExclusive
              })
        else { return nil }

        let renderInput = input.snapshot.pseudocodeRenderInput(
            selectedAddress: range.start,
            in: range.image.slot
        )
        guard renderInput.startAddress == range.start else { return nil }
        let document = PseudocodePrinter().print(
            functionName: renderInput.functionName,
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
            stackLocalOverrides: renderInput.stackLocalOverrides,
            resolvedIndirectCalls: renderInput.resolvedIndirectCalls,
            types: renderInput.types,
            instructions: renderInput.instructions
        )
        let bounded = boundedUTF8(
            document.text,
            maximumBytes: authorization.approvedLimits.stringBytes
        )
        return .object([
            field("source", .text("macscope")),
            field("status", .text(bounded.truncated ? "truncated" : "ready")),
            field("functionName", .text(function.name)),
            field("start", .unsignedInteger(range.start)),
            field("endExclusive", .unsignedInteger(range.endExclusive)),
            field("pseudocode", .object([
                field("text", .text(bounded.text)),
                field("language", .text("c")),
                field("isComplete", .boolean(!bounded.truncated)),
                field("isTruncated", .boolean(bounded.truncated)),
            ])),
            field("counts", decompilerCountValue(
                DecompilerRecordCounts(analysis: analysis, function: function),
                warningCount: 0
            )),
        ])
    }

    private static func decompilerPresentationIdentity(
        for range: Phase2ReadFunctionRange,
        in snapshot: WorkspaceSnapshot
    ) -> DecompilerPresentationIdentity? {
        guard let binary = snapshot.binary(in: range.image.slot),
              binary.id == range.image.binaryID,
              let artifactUUID = binary.artifactIdentity?.uuid,
              let analysis = snapshot.analysis(in: range.image.slot),
              let fingerprint = analysis.analysisInputFingerprint?.overallSHA256,
              let function = analysis.functions.first(where: {
                  $0.startAddress == range.start && $0.endAddress == range.endExclusive
              })
        else { return nil }
        return .init(
            imageSlot: range.image.slot,
            ownerBinaryID: binary.id,
            artifactUUID: artifactUUID,
            functionID: function.id.uuidString.lowercased(),
            analysisInputFingerprintSHA256: fingerprint
        )
    }

    private static func decompilerCountValue(
        _ counts: DecompilerRecordCounts,
        warningCount: Int
    ) -> Phase2ReadFactValue {
        .object([
            field("instructions", .unsignedInteger(UInt64(counts.instructionCount))),
            field("blocks", .unsignedInteger(UInt64(counts.blockCount))),
            field("edges", .unsignedInteger(UInt64(counts.edgeCount))),
            field("calls", .unsignedInteger(UInt64(counts.callCount))),
            field("warnings", .unsignedInteger(UInt64(warningCount))),
        ])
    }

    private struct DecompilerRecordCounts {
        let instructionCount: Int
        let blockCount: Int
        let edgeCount: Int
        let callCount: Int

        init(result: NativeDecompilerWireStructuredResult) {
            instructionCount = result.instructions.count
            blockCount = result.blocks.count
            edgeCount = result.edges.count
            callCount = result.calls.count
        }

        init(analysis: ImageAnalysis, function: FunctionSummary) {
            let contains: (UInt64) -> Bool = { address in
                function.startAddress < function.endAddress
                    && address >= function.startAddress
                    && address < function.endAddress
            }
            instructionCount = analysis.instructions.lazy.filter { contains($0.address) }.count
            blockCount = analysis.basicBlocks.lazy.filter { $0.functionID == function.id }.count
            edgeCount = analysis.controlFlowEdges.lazy.filter { contains($0.from) }.count
            callCount = analysis.xrefs.lazy.filter {
                $0.kind == XRefKind.call && contains($0.from)
            }.count
        }
    }

    private static func boundedUTF8(
        _ text: String,
        maximumBytes: Int
    ) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maximumBytes else { return (text, false) }
        var result = ""
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let scalarText = String(scalar)
            let scalarBytes = scalarText.utf8.count
            guard usedBytes + scalarBytes <= maximumBytes else { break }
            result.append(scalarText)
            usedBytes += scalarBytes
        }
        return (result, true)
    }

    private static func authorizedAnalysis(
        for image: Phase2ReadImageIdentity,
        in snapshot: WorkspaceSnapshot
    ) -> ImageAnalysis? {
        guard let binary = snapshot.binary(in: image.slot),
              binary.id == image.binaryID,
              binary.architecture == image.architecture,
              binary.selectedSliceIndex == image.sliceIndex
        else { return nil }
        return snapshot.analysis(in: image.slot)
    }

    private static func instructionValue(_ instruction: InstructionRow) -> Phase2ReadFactValue {
        var fields = [
            field("address", .unsignedInteger(instruction.address)),
            field("bytes", .text(instruction.bytes)),
            field("mnemonic", .text(instruction.mnemonic)),
            field("operands", .text(instruction.operands)),
        ]
        if let comment = instruction.comment {
            fields.append(field("comment", .text(comment)))
        }
        return .object(fields)
    }

    private static func applicationGraphDependencyValue(
        _ edge: ApplicationImageGraph.Edge,
        source: BinaryImage,
        target: ApplicationImageGraph.Node?
    ) -> Phase2ReadFactValue {
        .object([
            field("sourceImage", .text(source.name)),
            field("sourceSlot", .unsignedInteger(UInt64(edge.fromSlot.rawValue))),
            field("target", .text(target?.displayName ?? edge.rawPath)),
            field("rawPath", .text(edge.rawPath)),
            field("loadKind", .text(edge.loadKind)),
            field("ordinal", .unsignedInteger(UInt64(edge.ordinal))),
            field("resolution", .text(applicationGraphResolutionText(edge.resolution))),
        ])
    }

    private static func applicationGraphResolutionText(
        _ resolution: ApplicationImageGraph.Edge.Resolution
    ) -> String {
        switch resolution {
        case let .resolvedWorkspaceImage(slot):
            "resolved-workspace-image:\(slot.rawValue)"
        case let .external(path):
            "external:\(path)"
        case let .unresolved(path):
            "unresolved:\(path)"
        }
    }

    private static func instructionOrder(_ lhs: InstructionRow, _ rhs: InstructionRow) -> Bool {
        if lhs.address != rhs.address { return lhs.address < rhs.address }
        if lhs.bytes != rhs.bytes { return lhs.bytes < rhs.bytes }
        if lhs.mnemonic != rhs.mnemonic { return lhs.mnemonic < rhs.mnemonic }
        return lhs.operands < rhs.operands
    }

    private static func field(
        _ name: String,
        _ value: Phase2ReadFactValue
    ) -> Phase2ReadFactField {
        Phase2ReadFactField(name: name, value: value)
    }

    private static func candidate(
        _ data: Phase2ReadCandidateData,
        authorization: Phase2ReadAuthorization,
        citationCount: Int = 1
    ) -> Phase2ReadEvidenceCandidate {
        Phase2ReadEvidenceCandidate(
            candidateID: UUID(),
            invocationID: authorization.request.invocationID,
            sequence: authorization.request.sequence,
            registryVersion: authorization.canonicalDescriptor.registryVersion,
            operationID: authorization.canonicalDescriptor.id,
            operationVersion: authorization.canonicalDescriptor.operationVersion,
            producingPrincipal: .app,
            precondition: authorization.request.precondition,
            citations: (0..<citationCount).map { _ in citation(for: authorization.request) },
            data: data,
            cancelled: false
        )
    }

    private static func citation(for request: Phase2ReadRequest) -> Phase2ReadCitation {
        let target: Phase2ReadCitationTarget
        switch request.subject {
        case .workspace(let workspace):
            target = .workspace(workspace)
        case .staticLocation(let location):
            target = .staticLocation(location)
        case .functionRange(let range):
            target = .functionRange(range)
        }
        return Phase2ReadCitation(
            id: UUID(),
            target: target,
            dependencies: request.precondition.dependencies
        )
    }
}

private extension ApplicationImageGraph.Edge {
    var phase2IsResolvedWorkspaceImage: Bool {
        if case .resolvedWorkspaceImage = resolution { return true }
        return false
    }

    var phase2IsExternal: Bool {
        if case .external = resolution { return true }
        return false
    }

    var phase2IsUnresolved: Bool {
        if case .unresolved = resolution { return true }
        return false
    }
}
