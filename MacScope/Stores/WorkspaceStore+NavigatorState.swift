import Foundation
import os

/// Workspace ownership of the navigator-engine contract state (one `NavigatorContractStore` per image
/// slot). This file is the only writer: every mutation goes through
/// `registerAndApplyNavigatorMutation(in:undoable:marksDocument:_:)`, which follows the
/// `registerAndApplyManualXRefs` pattern (the inverse of a mutation restores the slot's previous
/// store value, which is a value type, so snapshot/restore is the exact inverse).
///
/// Four things feed a slot's store:
/// * analyst edits the contract names (`rename`, `setType`, `makeProcedure`, `addXref`), mirrored as
///   `author: analyst` annotations inside the edit's own undo group; the edit stays the authority;
/// * the Swift metadata producer, run as a cancellable, budgeted task after an analysis lands;
/// * the function-start proof producer, run in the same task after the metadata producer: one
///   structural proof per analysis function start (proven facts cite a certificate the workspace
///   retains in `navigatorCertificatesBySlot`), then the call-target derivation for the starts the
///   loader tables do not list;
/// * `acceptAnnotation(_:in:)` / `revertNavigator(_:in:)`, the entry points navigator commands call.
///
/// Analysis landings fence the store: facts whose `dependsOn` meets a changed fingerprint facet
/// become stale (not live) until a producer re-asserts them under the new generation.

private let navigatorStateLogger = Logger(subsystem: "org.macscope.MacScope", category: "NavigatorState")

/// The identity a producer run captured when it started. A result lands only when the workspace still
/// has exactly this identity: the same installed document, the same whole-workspace reanalysis epoch,
/// the same landed analysis of the slot and the same binary owner.
struct NavigatorLandingFence: Equatable, Sendable {
    var documentInstallationID: UUID
    var workspaceEpoch: UInt64
    var landingEpoch: UInt64
    var binaryID: UUID?
}

/// One retained producer run for a slot. `id` tells a finished run whether it is still the current one.
struct NavigatorProducerRun {
    let id: UUID
    let task: Task<Void, Never>
}

/// Everything a producer run needs, captured on the main actor.
struct NavigatorProducerInput: Sendable {
    var runID: UUID
    var slot: ImageSlot
    var imageBytes: Data
    var identity: MachOSliceArtifactIdentity?
    var generation: NavigatorGeneration?
    var fence: NavigatorLandingFence
}

/// What a producer run hands back to the main actor.
enum NavigatorProducerOutcome: Sendable {
    /// A result to `add`, the toolchain key it was detected under, and how many records the contract
    /// refused while projecting (reported, never silently dropped).
    case landed(NavigatorPrimitiveResult, toolchain: String, refused: Int)
    /// Nothing to land; `reason` is logged when present (an image without Swift metadata has none).
    case skipped(reason: String?)
    /// The run was cancelled (superseded or the workspace went away).
    case cancelled
}

/// Everything the proof producer needs, captured on the main actor: the metadata producer's input
/// plus the landed analysis's function summaries (the proof subjects, and the ranges the derivation
/// decodes).
struct NavigatorProofProducerInput: Sendable {
    var runID: UUID
    var slot: ImageSlot
    var imageBytes: Data
    var identity: MachOSliceArtifactIdentity?
    var generation: NavigatorGeneration?
    var fence: NavigatorLandingFence
    var functions: [FunctionSummary]
}

/// What a proof producer run hands back to the main actor.
enum NavigatorProofProducerOutcome: Sendable {
    /// The proof result and, when it proved anything, the derivation result, in landing order; the
    /// certificates the proven facts cite; the toolchain key the run detected; the refusals of
    /// individual starts or targets (reported, never silently dropped).
    case landed(results: [NavigatorPrimitiveResult], certificates: [NavigatorProofCertificate], toolchain: String,
                refusals: [NavigatorRefusal])
    /// Nothing to land; `reason` is logged when present (an analysis without functions has none).
    case skipped(reason: String?)
    /// The run was cancelled (superseded or the workspace went away).
    case cancelled
}

/// Constants and pure helpers of the bridge. Nonisolated so the producer task can use them.
enum NavigatorStateBridge {
    /// Session under which analyst-edit mirrors are accepted and reverted.
    static let analystSession = "analyst"
    /// Session under which navigator commands accept and revert by default.
    static let navigatorSession = "navigator"
    /// Toolchain of a slot store created before the producer has detected the image's toolchain.
    static let pendingToolchain = "toolchain-key/1|pending"
    /// Engine identity and decoder version folded into the knowledge version of every generation.
    static let engineIdentity = "macscope.navigator-store@1.1"
    static let decoderVersion = "\(SwiftMetadataFactProjection.rule)@\(SwiftMetadataFactProjection.ruleVersion)"
    /// Session under which producer results are added.
    static let producerSession = "producer:\(SwiftMetadataFactProjection.rule)@\(SwiftMetadataFactProjection.ruleVersion)"
    /// Fingerprint facets the Swift metadata projection reads: load commands and section table, and
    /// the relocation/fixup chains its pointer decoding follows.
    static let producerDependsOn = [AnalysisFingerprintFacetKind.machOLoadMetadata.rawValue,
                                    AnalysisFingerprintFacetKind.relocations.rawValue]
    /// Sessions under which the proof and derivation results are added.
    static let proofSession = "producer:\(FunctionStartStructuralProof.rule)@\(FunctionStartStructuralProof.ruleVersion)"
    static let derivationSession =
        "producer:\(FunctionStartCallTargetDerivation.rule)@\(FunctionStartCallTargetDerivation.ruleVersion)"
    /// Fingerprint facets the structural proof reads: the load commands (the three loader tables) and
    /// the section table. The derivation also decodes code bytes inside the analysis's functions.
    static let proofDependsOn = [AnalysisFingerprintFacetKind.machOLoadMetadata.rawValue,
                                 AnalysisFingerprintFacetKind.loaderSections.rawValue]
    static let derivationDependsOn = proofDependsOn + [AnalysisFingerprintFacetKind.selectedSliceBytes.rawValue,
                                                       AnalysisFingerprintFacetKind.functions.rawValue]
    /// Producer budget: 2 s of wall clock. The memory limit of `AnalysisBudget` measures the whole
    /// process footprint, which an open workspace already exceeds by far, so it is left unset.
    static let producerWallClockLimit: Duration = .seconds(2)
    static let producerBudget = AnalysisBudget(wallClockLimit: producerWallClockLimit, physicalFootprintLimitBytes: nil)
    static var producerWallMillis: Int64 {
        let components = producerWallClockLimit.components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
    /// The producer parses Swift metadata only; strings, Objective-C metadata and the code signature
    /// are not read.
    static let producerParseOptions = MachOParseOptions(
        recoverStringLiterals: false,
        recoverObjectiveCMetadata: false,
        recoverSwiftMetadata: true,
        parseCodeSignature: false
    )
    /// Digest of the versioned knowledge this build's navigator analyses depend on.
    static let knowledgeVersion = NavigatorKnowledgeVersion.digest(
        registry: .standard, engineIdentity: engineIdentity, decoderVersion: decoderVersion)
    /// Canonical JSON of the analyzer stamp (sorted keys), one input-key component.
    static let analyzerStamp: String = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(WorkspaceAnalyzerStamp.current),
              let text = String(data: data, encoding: .utf8) else {
            return "analyzer-version-\(WorkspaceAnalyzerStamp.currentVersion)"
        }
        return text
    }()

    /// Fingerprint facets whose digest differs between two landings of one slot, as facet-kind raw
    /// values (the vocabulary `dependsOn` uses). A kind present on one side only counts as changed.
    /// When either side is unknown nothing can be proven unchanged: every kind the other side names
    /// (all kinds when both are unknown) is reported.
    static func changedFacets(previous: AnalysisInputFingerprint?, current: AnalysisInputFingerprint?) -> Set<String> {
        guard let previous, let current else {
            let known = (previous ?? current)?.facets.map(\.kind.rawValue)
            return Set(known ?? AnalysisFingerprintFacetKind.allCases.map(\.rawValue))
        }
        var before: [String: String] = [:]
        for facet in previous.facets { before[facet.kind.rawValue] = facet.sha256 }
        var after: [String: String] = [:]
        for facet in current.facets { after[facet.kind.rawValue] = facet.sha256 }
        var changed = Set<String>()
        for kind in Set(before.keys).union(after.keys) where before[kind] != after[kind] {
            changed.insert(kind)
        }
        return changed
    }

    /// Patch-overlay digest of one slot: SHA-256 over the slot's patches in address order, each
    /// written as `<address hex>:<byte hex>;`. Empty overlay hashes the empty string.
    static func patchOverlayDigest(_ overrides: [ImageAddress: AddressOverride], slot: ImageSlot) -> String {
        var text = ""
        for (key, override) in overrides.filter({ $0.key.slot == slot }).sorted(by: { $0.key.address < $1.key.address }) {
            guard let patch = override.patch, !patch.isEmpty else { continue }
            text += String(key.address, radix: 16) + ":"
            text += patch.bytes.map { byte in
                let digits = String(byte, radix: 16)
                return digits.count == 1 ? "0" + digits : digits
            }.joined()
            text += ";"
        }
        return AnalysisFingerprintBuilder.sha256Hex(Data(text.utf8))
    }

    /// Structural-override digest of one slot: SHA-256 over the overrides that re-drive analysis
    /// (`isData`, `markAsProcedure`, `isUndefined`, `switchHint`, `dataShape`), each projected onto
    /// an otherwise-empty `AddressOverride`, encoded with sorted keys, in address order. Names,
    /// comments, types and patches are excluded (patches have their own digest).
    static func structuralOverridesDigest(_ overrides: [ImageAddress: AddressOverride], slot: ImageSlot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var text = ""
        for (key, override) in overrides.filter({ $0.key.slot == slot }).sorted(by: { $0.key.address < $1.key.address }) {
            var structural = AddressOverride()
            structural.isData = override.isData
            structural.markAsProcedure = override.markAsProcedure
            structural.isUndefined = override.isUndefined
            structural.switchHint = override.switchHint
            structural.dataShape = override.dataShape
            guard structural != AddressOverride() else { continue }
            let encoded = (try? encoder.encode(structural)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            text += String(key.address, radix: 16) + "=" + encoded + ";"
        }
        return AnalysisFingerprintBuilder.sha256Hex(Data(text.utf8))
    }

    /// Identity of a parsed thin slice when the binary carries none: its UUID, CPU type and the
    /// SHA-256 of the exact bytes parsed. nil for empty bytes.
    static func sliceIdentity(of file: MachOFile, bytes: Data) -> MachOSliceArtifactIdentity? {
        try? MachOSliceArtifactIdentity(
            uuid: file.uuid.flatMap { UUID(uuidString: $0.stringValue) },
            rawCPUType: file.header.cpuType,
            rawCPUSubtype: file.header.cpuSubtype,
            selectedSliceSHA256: AnalysisFingerprintBuilder.sha256Hex(bytes),
            selectedSliceByteCount: UInt64(bytes.count)
        )
    }

    /// The `budgetExceeded` frontier item for a stopped run, on the image subject. The detail is
    /// deterministic (phase and limit, not the measured time), so repeated stops raise one item.
    static func budgetExceededItem(_ exceeded: AnalysisBudgetExceeded, subject: NavigatorSubject, toolchain: String,
                                   generation: NavigatorGeneration?) -> NavigatorFrontierItem? {
        let limit: String
        switch exceeded.reason {
        case .wallClock: limit = "wall clock \(producerWallMillis) ms"
        case .memory(let limitBytes, _): limit = "memory \(limitBytes) bytes"
        }
        let detail = "\(decoderVersion) stopped before \(exceeded.stoppedBefore.rawValue): \(limit)"
        return try? NavigatorFrontierItem.make(
            subject: subject, gap: "budgetExceeded", detail: detail, toolchain: toolchain,
            primitives: [NavigatorPrimitiveRef(name: SwiftMetadataFactProjection.rule, preconditions: ["larger budget"])],
            cost: ["wallMillis": producerWallMillis],
            reason: [NavigatorRefusal("budgetExceeded", detail, retryable: true)],
            generation: generation, dependsOn: producerDependsOn)
    }

    /// The `budgetExceeded` frontier item of a proof producer run the wall clock stopped, on the image
    /// subject. Deterministic detail (rule and limit, not the measured time or the count left), so
    /// repeated stops raise one item.
    static func proofBudgetExceededItem(subject: NavigatorSubject, toolchain: String,
                                        generation: NavigatorGeneration?) -> NavigatorFrontierItem? {
        let detail = "\(FunctionStartStructuralProof.rule)@\(FunctionStartStructuralProof.ruleVersion) stopped "
            + "before every function start was examined: wall clock \(producerWallMillis) ms"
        return try? NavigatorFrontierItem.make(
            subject: subject, gap: "budgetExceeded", detail: detail, toolchain: toolchain,
            primitives: [NavigatorPrimitiveRef(name: FunctionStartStructuralProof.rule, preconditions: ["larger budget"])],
            cost: ["wallMillis": producerWallMillis],
            reason: [NavigatorRefusal("budgetExceeded", detail, retryable: true)],
            generation: generation, dependsOn: proofDependsOn)
    }

    /// One proof producer run, off the main actor: the structural proof of every distinct function
    /// start of the analysis (ascending), then, for the starts it could not prove that a direct `bl`
    /// inside a proven function targets, the call-target derivation. Both share one wall-clock budget
    /// (`producerWallClockLimit`); a stop lands what was established plus a `budgetExceeded` item.
    /// Frontier items the derivation resolves are dropped from the proof result; a derivation item for
    /// a subject the proof already narrowed is not added twice. Certificates returned are those of
    /// the proven facts (the ones the landing resolves); the others are not retained.
    static func runProofProducer(_ input: NavigatorProofProducerInput) -> NavigatorProofProducerOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard !input.imageBytes.isEmpty, !input.functions.isEmpty else { return .skipped(reason: nil) }
        guard var evidence = NavigatorImageEvidence(slice: input.imageBytes,
                                                    image: input.identity.map(NavigatorSubjectRef.imageRef)) else {
            return .skipped(reason: "slice does not parse as a thin Mach-O image")
        }
        guard let identity = input.identity ?? sliceIdentity(of: evidence.file, bytes: input.imageBytes) else {
            return .skipped(reason: "no slice identity")
        }
        if input.identity == nil,
           let named = NavigatorImageEvidence(slice: input.imageBytes, image: NavigatorSubjectRef.imageRef(identity)) {
            evidence = named
        }
        let toolchain = NavigatorToolchainKeyDetector.detect(file: evidence.file, identity: identity).canonical
        let imageSubject = NavigatorSubjectRef.imageSubject(identity)
        let clock = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
        let started = clock()
        func remaining() -> Int64 { max(0, producerWallMillis - (clock() - started)) }

        var proofFacts: [NavigatorFact] = []
        var proofFrontier: [NavigatorFrontierItem] = []
        var certificates: [NavigatorProofCertificate] = []
        var refusals: [NavigatorRefusal] = []
        var bytesRead: Int64 = 0
        var stopped = false
        let entries = Set(input.functions.map(\.startAddress)).sorted()
        for entry in entries {
            if Task.isCancelled { return .cancelled }
            let limit = remaining()
            guard limit > 0 else { stopped = true; break }
            let output = FunctionStartStructuralProof.run(
                entry: entry, evidence: evidence, toolchain: toolchain,
                generation: input.generation, dependsOn: proofDependsOn,
                wallMillisLimit: limit, clock: clock, isCancelled: { Task.isCancelled })
            bytesRead += output.result.budget["bytes"] ?? 0
            if let refusal = output.result.refusal {
                switch refusal.code {
                case "cancelled": return .cancelled
                case "budgetExceeded": stopped = true
                default: refusals.append(refusal)
                }
                if stopped { break }
                continue
            }
            if let certificate = output.certificate, certificate.outcome == .proven { certificates.append(certificate) }
            proofFacts += output.result.facts
            proofFrontier += output.result.frontier
        }

        var derivedFacts: [NavigatorFact] = []
        var derivedFrontier: [NavigatorFrontierItem] = []
        var instructions: Int64 = 0
        if !proofFacts.isEmpty, !stopped {
            let decoder = ARM64Decoder()
            let proven = Set(proofFacts.compactMap { FunctionStartCallTargetDerivation.provenEntry($0, image: evidence.image) })
            var targets = Set<UInt64>()
            for function in input.functions where proven.contains(function.startAddress) {
                for instruction in FunctionStartCallTargetDerivation.decodeFunction(function, evidence: evidence, decoder: decoder)
                where instruction.flow == .call {
                    if let target = instruction.branchTarget { targets.insert(target) }
                }
            }
            let narrowed = Set(proofFrontier.map(\.subject))
            for target in targets.intersection(Set(entries).subtracting(proven)).sorted() {
                if Task.isCancelled { return .cancelled }
                guard remaining() > 0 else { stopped = true; break }
                let result = FunctionStartCallTargetDerivation.run(
                    target: target, evidence: evidence, provenFacts: proofFacts, functions: input.functions,
                    toolchain: toolchain, generation: input.generation, dependsOn: derivationDependsOn, decoder: decoder)
                instructions += result.budget["instructions"] ?? 0
                if let refusal = result.refusal {
                    refusals.append(refusal)
                    continue
                }
                derivedFacts += result.facts
                derivedFrontier += result.frontier.filter { !narrowed.contains($0.subject) }
            }
            let resolved = Set(derivedFacts.map(\.subject))
            proofFrontier.removeAll { resolved.contains($0.subject) }
        }

        if stopped, let item = proofBudgetExceededItem(subject: imageSubject, toolchain: toolchain,
                                                       generation: input.generation) {
            proofFrontier.append(item)
        }
        let wallMillis = clock() - started
        var results: [NavigatorPrimitiveResult] = []
        if !proofFacts.isEmpty || !proofFrontier.isEmpty {
            results.append(NavigatorPrimitiveResult(
                primitive: FunctionStartStructuralProof.rule, primitiveVersion: FunctionStartStructuralProof.ruleVersion,
                subject: imageSubject, budget: ["bytes": bytesRead, "wallMillis": wallMillis],
                facts: proofFacts, frontier: proofFrontier))
        }
        if !derivedFacts.isEmpty || !derivedFrontier.isEmpty {
            results.append(NavigatorPrimitiveResult(
                primitive: FunctionStartCallTargetDerivation.rule,
                primitiveVersion: FunctionStartCallTargetDerivation.ruleVersion,
                subject: imageSubject, budget: ["instructions": instructions, "bytes": instructions * 4, "wallMillis": wallMillis],
                facts: derivedFacts, frontier: derivedFrontier))
        }
        guard !results.isEmpty else {
            return refusals.isEmpty ? .skipped(reason: nil)
                : .skipped(reason: "\(refusals.count) starts or targets refused, nothing to land")
        }
        return .landed(results: results, certificates: certificates, toolchain: toolchain, refusals: refusals)
    }

    /// One producer run: parse the slice's Swift metadata under the budget, project it onto contract
    /// records stamped with the run's generation, and return the result. Runs off the main actor.
    static func runProducer(_ input: NavigatorProducerInput) -> NavigatorProducerOutcome {
        let token = AnalysisCancellationToken.budgeted(isCancelled: { Task.isCancelled }, budget: producerBudget)
        do {
            try token.check(.load)
        } catch is AnalysisCancelled {
            return .cancelled
        } catch {
            return .skipped(reason: "stopped before parsing: \(error.localizedDescription)")
        }
        guard !input.imageBytes.isEmpty else { return .skipped(reason: nil) }
        let file: MachOFile
        do {
            file = try MachOParser().parse(input.imageBytes, options: producerParseOptions)
        } catch {
            return .skipped(reason: "Swift metadata parse failed: \(error.localizedDescription)")
        }
        guard let identity = input.identity ?? sliceIdentity(of: file, bytes: input.imageBytes) else {
            return .skipped(reason: "no slice identity")
        }
        let toolchain = NavigatorToolchainKeyDetector.detect(file: file, identity: identity).canonical
        let subject = NavigatorSubjectRef.imageSubject(identity)
        let budget: [String: Int64] = ["bytes": Int64(input.imageBytes.count), "wallMillis": producerWallMillis]
        do {
            try token.check(.diagnostics)
        } catch is AnalysisCancelled {
            return .cancelled
        } catch let exceeded as AnalysisBudgetExceeded {
            guard let item = budgetExceededItem(exceeded, subject: subject, toolchain: toolchain,
                                                generation: input.generation) else {
                return .skipped(reason: "budget exceeded; frontier item refused")
            }
            let result = NavigatorPrimitiveResult(
                primitive: SwiftMetadataFactProjection.rule, primitiveVersion: SwiftMetadataFactProjection.ruleVersion,
                subject: subject, budget: budget, frontier: [item])
            return .landed(result, toolchain: toolchain, refused: 0)
        } catch {
            return .skipped(reason: "\(error)")
        }
        let output = SwiftMetadataFactProjection.project(
            types: file.swiftTypes, conformances: file.swiftConformances,
            diagnostics: file.swiftMetadataDiagnostics, protocols: file.swiftProtocols,
            image: NavigatorSubjectRef.imageRef(identity), toolchain: toolchain,
            generation: input.generation, dependsOn: producerDependsOn)
        // A result needs at least one fact or one frontier item; an image without Swift metadata has neither.
        guard !output.facts.isEmpty || !output.frontier.isEmpty else {
            return output.refused.isEmpty ? .skipped(reason: nil)
                : .skipped(reason: "\(output.refused.count) records refused, nothing to land")
        }
        let result = NavigatorPrimitiveResult(
            primitive: SwiftMetadataFactProjection.rule, primitiveVersion: SwiftMetadataFactProjection.ruleVersion,
            subject: subject, budget: budget, facts: output.facts, frontier: output.frontier)
        return .landed(result, toolchain: toolchain, refused: output.refused.count)
    }
}

/// One analyst-edit mirror: an annotation to accept, or the (subject, predicate, value) whose live
/// analyst annotations a cleared edit reverts (`value` nil reverts every value).
private struct NavigatorAnalystNote {
    enum Kind { case accept, revert }
    var kind: Kind
    var action: String
    var subject: NavigatorSubject
    var predicate: String
    var value: NavigatorJSONValue?
}

@MainActor
extension WorkspaceStore {
    // MARK: - Reading

    /// The slot's store; nil when nothing was recorded for the slot.
    func navigatorState(for slot: ImageSlot) -> NavigatorContractStore? {
        navigatorStates[slot]
    }

    /// The slot's store, or the empty store (pending toolchain) a first mutation starts from.
    private func navigatorStoreOrEmpty(in slot: ImageSlot) -> NavigatorContractStore {
        navigatorStates[slot] ?? NavigatorContractStore(toolchain: NavigatorStateBridge.pendingToolchain)
    }

    /// The generation the slot's analysis currently has; nil without a binary, analysis or bytes.
    func navigatorGeneration(for slot: ImageSlot) -> NavigatorGeneration? {
        guard let binary = snapshot.binary(in: slot), let analysis = snapshot.analysis(in: slot) else { return nil }
        let sliceSHA256: String
        if let identity = binary.artifactIdentity {
            sliceSHA256 = identity.selectedSliceSHA256
        } else if let fingerprint = analysis.analysisInputFingerprint {
            sliceSHA256 = fingerprint.imageBytesSHA256
        } else if !analysis.imageBytes.isEmpty {
            sliceSHA256 = AnalysisFingerprintBuilder.sha256Hex(analysis.imageBytes)
        } else {
            return nil
        }
        let context = navigatorInputKeyContext(in: slot)
        // Same formula as `AnalysisFingerprintBuilder.fingerprint(binary:analysis:navigatorContext:)`
        // computes for `inputKey`, without rebuilding the facets.
        let inputKey = NavigatorAnalysisInputKey.inputKey(
            sliceSHA256: sliceSHA256, selectedSliceIndex: binary.selectedSliceIndex, context: context)
        return NavigatorGeneration(
            imageIdentity: binary.artifactIdentity.map(NavigatorSubjectRef.imageRef) ?? "slice:\(sliceSHA256)",
            inputKey: inputKey, knowledgeVersion: context.knowledgeVersion)
    }

    /// The caller-owned input-key components for one slot.
    func navigatorInputKeyContext(in slot: ImageSlot) -> NavigatorInputKeyContext {
        NavigatorInputKeyContext(
            patchOverlayDigest: NavigatorStateBridge.patchOverlayDigest(snapshot.addressOverrides, slot: slot),
            analyzerStamp: NavigatorStateBridge.analyzerStamp,
            knowledgeVersion: NavigatorStateBridge.knowledgeVersion,
            structuralOverridesDigest: NavigatorStateBridge.structuralOverridesDigest(snapshot.addressOverrides, slot: slot))
    }

    // MARK: - The mutation funnel

    /// Applies `body` to the slot's store. A refusal discards the change and is returned. An undoable
    /// mutation registers its inverse (restore the previous store value) on the slot's undo target;
    /// `marksDocument` decides whether it also records a document mutation with a matching dirty-token
    /// restore. Producer landings and generation fencing are derived state: not undoable, not dirtying.
    @discardableResult
    func registerAndApplyNavigatorMutation(
        in slot: ImageSlot,
        undoable: Bool = true,
        marksDocument: Bool = true,
        _ body: (inout NavigatorContractStore) -> NavigatorRefusal?
    ) -> NavigatorRefusal? {
        let previous = navigatorStates[slot]
        var next = navigatorStoreOrEmpty(in: slot)
        if let refusal = body(&next) { return refusal }
        if undoable {
            registerAndSetNavigatorStore(next, previous: previous, in: slot, marksDocument: marksDocument)
        } else {
            navigatorStates[slot] = next
            if marksDocument { markDocumentMutated() }
        }
        return nil
    }

    /// The form navigator commands call: one undoable, dirtying mutation as its own named undo step.
    /// `body` runs once on a copy; a refusal is returned before any undo group opens, so a refused
    /// command leaves no empty step behind.
    @discardableResult
    func registerAndApplyNavigatorMutation(
        _ body: (inout NavigatorContractStore) -> NavigatorRefusal?,
        in slot: ImageSlot,
        actionName: String = "Navigator Change"
    ) -> NavigatorRefusal? {
        let previous = navigatorStates[slot]
        var next = navigatorStoreOrEmpty(in: slot)
        if let refusal = body(&next) { return refusal }
        inNavigatorUndoGroup(named: actionName) {
            registerAndSetNavigatorStore(next, previous: previous, in: slot, marksDocument: true)
        }
        return nil
    }

    /// Sets the slot's store and registers an Undo that restores `previous`. The undo handler
    /// re-enters this helper (inside the UndoManager's own group), which registers the matching Redo.
    private func registerAndSetNavigatorStore(
        _ value: NavigatorContractStore?,
        previous: NavigatorContractStore?,
        in slot: ImageSlot,
        marksDocument: Bool
    ) {
        let findingsAtRegistration = analystFindings
        let priorToken: DirtyUndoToken? = marksDocument ? markDocumentMutated(preservingUndoComparability: true) : nil
        registerSlotScopedUndo(in: slot) { store in
            let findingsBefore = store.analystFindings
            store.registerAndSetNavigatorStore(previous, previous: value, in: slot, marksDocument: marksDocument)
            // Reconciliation is a new durable system mutation, not part of this inverse.
            if let priorToken, findingsBefore == findingsAtRegistration,
               store.analystFindings == findingsBefore {
                store.restoreDocumentDirtyToken(priorToken)
            }
        }
        navigatorStates[slot] = value
        // An explicit mutation to nil means evidence was removed, not that a document is
        // still opening. Install an empty view for this slot so reconciliation sees that loss.
        var support = analystFindingSupportSource()
        support.stores[slot] = value ?? NavigatorContractStore(toolchain: NavigatorStateBridge.pendingToolchain)
        reconcileAnalystFindings(touching: [slot], source: support)
    }

    /// Runs `apply` as one named undo step: an explicit group only on the fallback manager
    /// (`groupsByEvent == false`), exactly as `applyOverride` does.
    private func inNavigatorUndoGroup<Result>(named actionName: String, _ apply: () -> Result) -> Result {
        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent
        if needsExplicitGroup { manager.beginUndoGrouping() }
        let result = apply()
        manager.setActionName(actionName)
        if needsExplicitGroup { manager.endUndoGrouping() }
        return result
    }

    // MARK: - Entry points for navigator commands

    /// Accepts `annotation` into the slot's store as one undo step ("Accept Annotation").
    @discardableResult
    func acceptAnnotation(_ annotation: NavigatorAnnotation, in slot: ImageSlot) -> NavigatorRefusal? {
        if let refusal = navigatorStoreOrEmpty(in: slot).acceptPreflight(annotation) { return refusal }
        return inNavigatorUndoGroup(named: "Accept Annotation") {
            registerAndApplyNavigatorMutation(in: slot) { $0.accept(annotation) }
        }
    }

    /// Reverts the fact or annotation `handle` (`revert:<id>`) names as one undo step
    /// ("Revert Navigator Fact").
    @discardableResult
    func revertNavigator(_ handle: String, in slot: ImageSlot,
                         session: String = NavigatorStateBridge.navigatorSession) -> NavigatorRefusal? {
        if let refusal = navigatorStoreOrEmpty(in: slot).preview(revert: handle, session: session).refusal { return refusal }
        let refusal = inNavigatorUndoGroup(named: "Revert Navigator Fact") {
            registerAndApplyNavigatorMutation(in: slot) { $0.revert(handle, session: session) }
        }
        if refusal == nil {
            // System marks remain stale after Undo restores evidence; only explicit readmission
            // can clear them. The mutation funnel also reconciles undo/redo and mirror changes.
            analystFindingsAnnotationReverted(in: slot)
        }
        return refusal
    }

    /// What `revertNavigator(handle, in: slot)` would change; nothing is mutated.
    func previewNavigatorRevert(_ handle: String, in slot: ImageSlot,
                                session: String = NavigatorStateBridge.navigatorSession) -> NavigatorContractStore.RevertPreview {
        navigatorStoreOrEmpty(in: slot).preview(revert: handle, session: session)
    }

    // MARK: - Analyst-edit mirrors (called inside the edit's own undo group)

    /// Mirrors one address-override edit: a new name, type or forced procedure start is accepted as an
    /// analyst annotation; a cleared one reverts the live analyst annotations it had recorded.
    func mirrorAnalystOverride(_ key: ImageAddress, previous: AddressOverride?, value: AddressOverride?) {
        let subject = NavigatorSubjectRef.subject(
            kind: "address", ref: NavigatorSubjectRef.address(key.address),
            identity: snapshot.binary(in: key.slot)?.artifactIdentity)
        var notes: [NavigatorAnalystNote] = []
        func text(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let oldName = text(previous?.customName), newName = text(value?.customName)
        if oldName != newName {
            if let newName {
                notes.append(NavigatorAnalystNote(kind: .accept, action: "rename", subject: subject,
                                                  predicate: "hasName", value: .string(newName)))
            } else {
                notes.append(NavigatorAnalystNote(kind: .revert, action: "rename", subject: subject,
                                                  predicate: "hasName", value: nil))
            }
        }
        let oldType = text(previous?.appliedTypeName), newType = text(value?.appliedTypeName)
        if oldType != newType {
            if let newType {
                notes.append(NavigatorAnalystNote(kind: .accept, action: "setType", subject: subject,
                                                  predicate: "hasType", value: .string(newType)))
            } else {
                notes.append(NavigatorAnalystNote(kind: .revert, action: "setType", subject: subject,
                                                  predicate: "hasType", value: nil))
            }
        }
        let wasProcedure = previous?.markAsProcedure ?? false, isProcedure = value?.markAsProcedure ?? false
        if wasProcedure != isProcedure {
            notes.append(NavigatorAnalystNote(kind: isProcedure ? .accept : .revert, action: "makeProcedure",
                                              subject: subject, predicate: "isFunctionStart",
                                              value: isProcedure ? .bool(true) : nil))
        }
        applyAnalystNotes(notes, in: key.slot)
    }

    /// Mirrors one manual-xref edit of a slot: an added call edge is accepted as an analyst `addXref`
    /// (`callsTarget`) annotation; a removed one reverts the live annotation for that edge.
    /// Suppressions and non-call kinds have no contract predicate and are not mirrored.
    func mirrorAnalystXRefs(_ value: [ManualXRef], previous: [ManualXRef], in slot: ImageSlot) {
        let identity = snapshot.binary(in: slot)?.artifactIdentity
        func isMirrored(_ xref: ManualXRef) -> Bool { !xref.isSuppression && xref.kind == XRefKind.call && xref.imageSlot == slot }
        func note(_ xref: ManualXRef, _ kind: NavigatorAnalystNote.Kind) -> NavigatorAnalystNote {
            NavigatorAnalystNote(
                kind: kind, action: "addXref",
                subject: NavigatorSubjectRef.subject(kind: "address", ref: NavigatorSubjectRef.address(xref.from), identity: identity),
                predicate: "callsTarget", value: .string(NavigatorSubjectRef.address(xref.to)))
        }
        let before = previous.filter(isMirrored)
        let after = value.filter(isMirrored)
        var notes: [NavigatorAnalystNote] = []
        for xref in before where !after.contains(where: { $0.from == xref.from && $0.to == xref.to }) {
            notes.append(note(xref, .revert))
        }
        for xref in after where !before.contains(where: { $0.from == xref.from && $0.to == xref.to }) {
            notes.append(note(xref, .accept))
        }
        applyAnalystNotes(notes, in: slot)
    }

    /// Applies the mirrors as one navigator mutation inside the caller's undo group. The edit already
    /// recorded the document mutation, so this one does not. A refusal drops the mirror (logged); the
    /// edit itself is unaffected.
    private func applyAnalystNotes(_ notes: [NavigatorAnalystNote], in slot: ImageSlot) {
        guard !notes.isEmpty else { return }
        let generation = navigatorGenerations[slot]
        let refusal = registerAndApplyNavigatorMutation(in: slot, marksDocument: false) { store in
            var seq = store.annotations().values
                .filter { $0.session == NavigatorStateBridge.analystSession }
                .map(\.seq).max().map { $0 + 1 } ?? 0
            for note in notes {
                switch note.kind {
                case .accept:
                    guard let value = note.value else { continue }
                    let annotation: NavigatorAnnotation
                    do {
                        annotation = try NavigatorAnnotation.make(
                            session: NavigatorStateBridge.analystSession, seq: seq, author: "analyst", action: note.action,
                            subject: note.subject, predicate: note.predicate, value: value, generation: generation)
                    } catch let error as NavigatorContractError {
                        return NavigatorRefusal("malformedInput", error.reasons.first ?? "annotation refused")
                    } catch {
                        return NavigatorRefusal("malformedInput", "\(error)")
                    }
                    if let refusal = store.accept(annotation) { return refusal }
                    seq += 1
                case .revert:
                    let live = store.liveAnnotations().filter { annotation in
                        annotation.author == "analyst" && annotation.subject == note.subject
                            && annotation.predicate == note.predicate
                            && (note.value == nil || annotation.value == note.value)
                    }
                    for annotation in live.sorted(by: { $0.id < $1.id }) {
                        if let refusal = store.revert(annotation.revert, session: NavigatorStateBridge.analystSession) {
                            return refusal
                        }
                    }
                }
            }
            return nil
        }
        if let refusal {
            navigatorStateLogger.error(
                "analyst mirror for slot \(slot.rawValue, privacy: .public) refused: \(refusal.code, privacy: .public) \(refusal.detail, privacy: .public)")
        }
    }

    // MARK: - Generation fencing

    /// Called after an analysis lands for `slot` (reanalysis, reimport, import, additional image):
    /// records the new generation, fences the slot's facts, then schedules the producer.
    /// `previousFingerprint` is the slot's fingerprint before the landing (nil for a new image).
    func navigatorAnalysisDidLand(in slot: ImageSlot, previousFingerprint: AnalysisInputFingerprint?) {
        let previousGeneration = navigatorGenerations[slot]
        let current = navigatorGeneration(for: slot)
        navigatorGenerations[slot] = current
        if navigatorStates[slot] != nil {
            let imageChanged = current == nil
                || (previousGeneration != nil && previousGeneration?.imageIdentity != current?.imageIdentity)
            let changed = NavigatorStateBridge.changedFacets(
                previous: previousFingerprint, current: snapshot.analysis(in: slot)?.analysisInputFingerprint)
            registerAndApplyNavigatorMutation(in: slot, undoable: false, marksDocument: false) { store in
                if imageChanged {
                    store.markStale(Array(store.allFacts().keys))
                } else {
                    store.markStaleGeneration(changedFacets: changed)
                }
                return nil
            }
            // Findings cite facts by id and generation: after the facts were fenced, mark the findings whose
            // citations the slot no longer supports (an image change also retires citations made against
            // the previous identity).
            if imageChanged {
                analystFindingsImageIdentityChanged(in: slot)
            } else {
                analystFindingsFactsFenced(in: [slot])
            }
        }
        scheduleNavigatorProducer(in: slot)
    }

    // MARK: - Producer

    /// Cancels the slot's running producer and starts a new one for its current analysis: the Swift
    /// metadata producer, then (when the analysis has functions) the proof producer, in one task under
    /// one run id. Nothing starts for a slot without a binary or image bytes.
    func scheduleNavigatorProducer(in slot: ImageSlot) {
        navigatorProducerRunsBySlot.removeValue(forKey: slot)?.task.cancel()
        guard let binary = snapshot.binary(in: slot), let analysis = snapshot.analysis(in: slot),
              !analysis.imageBytes.isEmpty else { return }
        let input = NavigatorProducerInput(
            runID: UUID(), slot: slot, imageBytes: analysis.imageBytes, identity: binary.artifactIdentity,
            generation: navigatorGenerations[slot] ?? navigatorGeneration(for: slot),
            fence: navigatorLandingFence(for: slot))
        let proofInput: NavigatorProofProducerInput? = analysis.functions.isEmpty ? nil : NavigatorProofProducerInput(
            runID: input.runID, slot: slot, imageBytes: input.imageBytes, identity: input.identity,
            generation: input.generation, fence: input.fence, functions: analysis.functions)
        let task = Task.detached(priority: .utility) { [weak self] in
            let outcome = NavigatorStateBridge.runProducer(input)
            await self?.landNavigatorProducerOutcome(outcome, input: input, final: proofInput == nil)
            guard let proofInput, !Task.isCancelled else { return }
            let proofOutcome = NavigatorStateBridge.runProofProducer(proofInput)
            await self?.landNavigatorProofOutcome(proofOutcome, input: proofInput)
        }
        navigatorProducerRunsBySlot[slot] = NavigatorProducerRun(id: input.runID, task: task)
    }

    /// Lands a finished run when it is still the slot's current run and the workspace identity it
    /// captured still holds; otherwise the outcome is dropped (a newer landing re-runs the producer).
    /// `final` is false while the proof producer of the same run is still to come: the run then stays
    /// retained (and cancellable) until the proof outcome lands.
    func landNavigatorProducerOutcome(_ outcome: NavigatorProducerOutcome, input: NavigatorProducerInput,
                                      final: Bool = true) {
        guard navigatorProducerRunsBySlot[input.slot]?.id == input.runID else { return }
        if final { navigatorProducerRunsBySlot.removeValue(forKey: input.slot) }
        guard navigatorLandingFence(for: input.slot) == input.fence else {
            navigatorStateLogger.info("producer result for slot \(input.slot.rawValue, privacy: .public) dropped: workspace changed")
            return
        }
        switch outcome {
        case .cancelled:
            return
        case .skipped(let reason):
            if let reason {
                navigatorStateLogger.info("producer for slot \(input.slot.rawValue, privacy: .public) skipped: \(reason, privacy: .public)")
            }
        case .landed(let result, let toolchain, let refused):
            if refused > 0 {
                navigatorStateLogger.error("producer for slot \(input.slot.rawValue, privacy: .public): \(refused, privacy: .public) records refused by the contract")
            }
            let refusal = registerAndApplyNavigatorMutation(in: input.slot, undoable: false, marksDocument: false) { store in
                store.toolchain = toolchain
                return store.add(result, session: NavigatorStateBridge.producerSession)
            }
            if let refusal {
                navigatorStateLogger.error(
                    "producer result for slot \(input.slot.rawValue, privacy: .public) refused: \(refusal.code, privacy: .public) \(refusal.detail, privacy: .public)")
            }
        }
    }

    /// Lands a finished proof producer run under the same guards as `landNavigatorProducerOutcome`.
    /// The run's certificates replace the slot's retained set; a proven fact whose certificate does not
    /// resolve against that set is dropped from its result before the add (counted in the log, never
    /// landed), so every proven fact in a store cites a certificate the workspace holds.
    func landNavigatorProofOutcome(_ outcome: NavigatorProofProducerOutcome, input: NavigatorProofProducerInput) {
        guard navigatorProducerRunsBySlot[input.slot]?.id == input.runID else { return }
        navigatorProducerRunsBySlot.removeValue(forKey: input.slot)
        guard navigatorLandingFence(for: input.slot) == input.fence else {
            navigatorStateLogger.info("proof result for slot \(input.slot.rawValue, privacy: .public) dropped: workspace changed")
            return
        }
        switch outcome {
        case .cancelled:
            return
        case .skipped(let reason):
            if let reason {
                navigatorStateLogger.info("proof producer for slot \(input.slot.rawValue, privacy: .public) skipped: \(reason, privacy: .public)")
            }
        case .landed(let results, let certificates, let toolchain, let refusals):
            if !refusals.isEmpty {
                navigatorStateLogger.error("proof producer for slot \(input.slot.rawValue, privacy: .public): \(refusals.count, privacy: .public) starts or targets refused")
            }
            var byHash: [String: NavigatorProofCertificate] = [:]
            for certificate in certificates { byHash[certificate.hash] = certificate }
            navigatorCertificatesBySlot[input.slot] = byHash
            for result in results {
                var landed = result
                landed.facts = result.facts.filter { fact in
                    NavigatorContractValidator.certificateRefusal(for: fact) { byHash[$0] } == nil
                }
                let unresolved = result.facts.count - landed.facts.count
                if unresolved > 0 {
                    navigatorStateLogger.error("proof producer for slot \(input.slot.rawValue, privacy: .public): \(unresolved, privacy: .public) proven facts without a resolvable certificate dropped")
                }
                guard !landed.facts.isEmpty || !landed.frontier.isEmpty else { continue }
                let session = landed.primitive == FunctionStartStructuralProof.rule
                    ? NavigatorStateBridge.proofSession : NavigatorStateBridge.derivationSession
                let refusal = registerAndApplyNavigatorMutation(in: input.slot, undoable: false, marksDocument: false) { store in
                    store.toolchain = toolchain
                    return store.add(landed, session: session)
                }
                if let refusal {
                    navigatorStateLogger.error(
                        "proof result \(landed.primitive, privacy: .public) for slot \(input.slot.rawValue, privacy: .public) refused: \(refusal.code, privacy: .public) \(refusal.detail, privacy: .public)")
                }
            }
        }
    }

    /// The certificates the slot's latest proof landing retained, in hash order; empty for a slot
    /// without one.
    func navigatorCertificates(in slot: ImageSlot) -> [NavigatorProofCertificate] {
        (navigatorCertificatesBySlot[slot] ?? [:]).values.sorted { $0.hash < $1.hash }
    }

    // MARK: - Persistence

    /// The manifest value: one envelope per slot with recorded state, keyed by the slot's raw value;
    /// nil when no slot has any. A slot whose state cannot be encoded or exceeds the per-slot cap is
    /// left out with one log line (it reopens empty) rather than failing the save.
    func persistableNavigatorState() -> [String: NavigatorEngineStateEnvelope]? {
        var result: [String: NavigatorEngineStateEnvelope] = [:]
        for slot in navigatorStates.keys.sorted() {
            guard let store = navigatorStates[slot] else { continue }
            let state = store.state()
            guard !(state.facts.isEmpty && state.frontier.isEmpty && state.annotations.isEmpty) else { continue }
            do {
                let envelope = try NavigatorEngineStateEnvelope(store: store, generation: navigatorGenerations[slot])
                try envelope.validateShape()
                result[String(slot.rawValue)] = envelope
            } catch {
                navigatorStateLogger.error("navigator state for slot \(slot.rawValue, privacy: .public) not saved: \(String(describing: error), privacy: .public)")
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Installs the manifest's navigator state after a package restore. Each envelope is decoded and
    /// validated; canonical-ref warnings are logged, never fatal. The stored generation is compared
    /// with the recomputed one: on a different input key (or none) every fact is marked stale instead
    /// of trusted, and the producer re-asserts what still holds. Missing or undecodable state leaves the
    /// slot empty with one log line. Undo history is not restored.
    func restoreNavigatorStates(from manifest: WorkspacePackageManifest) {
        resetNavigatorStates()
        if manifest.navigatorStateUndecodable {
            navigatorStateLogger.error("navigator state in the manifest is undecodable; every slot opens empty")
        }
        for (key, envelope) in (manifest.navigatorState ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let raw = Int(key), raw >= 0 else {
                navigatorStateLogger.error("navigator state key \(key, privacy: .public) is not an image slot; ignored")
                continue
            }
            let slot = ImageSlot(rawValue: raw)
            let decoded: (state: NavigatorEngineState, warnings: [String])
            do {
                decoded = try envelope.decodedState()
            } catch {
                navigatorStateLogger.error("navigator state for slot \(raw, privacy: .public) not restored: \(String(describing: error), privacy: .public)")
                continue
            }
            if !decoded.warnings.isEmpty {
                navigatorStateLogger.info("navigator state for slot \(raw, privacy: .public): \(decoded.warnings.count, privacy: .public) non-canonical subject refs")
            }
            // Stale marks go into the restore itself so the persisted frontier is reconciled against
            // them (a store-raised item whose cause no longer holds is dropped, not kept as a phantom).
            let current = navigatorGeneration(for: slot)
            let generationChanged = current == nil || envelope.generation?.inputKey != current?.inputKey
            let stale = generationChanged ? decoded.state.facts.map(\.id) : (envelope.staleGeneration ?? [])
            navigatorStates[slot] = NavigatorContractStore(state: decoded.state, staleGeneration: stale)
        }
        for binary in snapshot.binaries {
            navigatorGenerations[binary.slot] = navigatorGeneration(for: binary.slot)
            scheduleNavigatorProducer(in: binary.slot)
        }
        // Findings were installed just before this call (`restorePackage`); with both installed, retire the
        // citations whose image identity or facts the restored state no longer supports.
        reconcileAnalystFindingsAfterOpen()
    }

    /// Drops every slot's state and cancels every producer run (document replacement or fork).
    func resetNavigatorStates() {
        for run in navigatorProducerRunsBySlot.values { run.task.cancel() }
        navigatorProducerRunsBySlot.removeAll()
        navigatorStates.removeAll()
        navigatorGenerations.removeAll()
        navigatorCertificatesBySlot.removeAll()
    }

    /// Drops one slot's state when its binary owner changed (image removed or replaced by a new owner).
    func dropNavigatorState(in slot: ImageSlot) {
        navigatorProducerRunsBySlot.removeValue(forKey: slot)?.task.cancel()
        navigatorStates.removeValue(forKey: slot)
        navigatorGenerations.removeValue(forKey: slot)
        navigatorCertificatesBySlot.removeValue(forKey: slot)
    }

    /// Moves a slot's state with its image when the slot is renumbered, then re-runs the producer
    /// under the new slot (a run captured for the old slot can no longer land).
    func remapNavigatorState(from old: ImageSlot, to new: ImageSlot) {
        navigatorProducerRunsBySlot.removeValue(forKey: old)?.task.cancel()
        if let store = navigatorStates.removeValue(forKey: old) { navigatorStates[new] = store }
        if let certificates = navigatorCertificatesBySlot.removeValue(forKey: old) {
            navigatorCertificatesBySlot[new] = certificates
        }
        navigatorGenerations.removeValue(forKey: old)
        navigatorGenerations[new] = navigatorGeneration(for: new)
        scheduleNavigatorProducer(in: new)
    }
}

extension NavigatorContractStore {
    /// The refusal `accept(annotation)` would return, computed on a copy; `self` is untouched.
    func acceptPreflight(_ annotation: NavigatorAnnotation) -> NavigatorRefusal? {
        var trial = self
        return trial.accept(annotation)
    }
}
