import Foundation

// MCP navigator surface (contract v1): typed facts, frontier with cost and leverage, dependents,
// the primitive list, revert preview and revert, acceptance, the detected toolchain and
// provenance resolution, all behind the closed command authority in `MCPServer.swift`.
//
// `MCPServer.swift` keeps its structure: `HeadlessAutomationAuthority` lists the catalog below,
// validates through `NavigatorMCPCommands.validate` and dispatches with one line each in
// `execute` / `executeAsync`. The handlers live here.
//
// Result conventions, identical on the inline, async and attached transports:
// - a miss is a typed absence, `{absent: {subject, reason}}` with reason one of `noSuchImage`,
//   `noSuchSubject`, `noFacts`, `stale`, `unsupportedToolchain`; no command answers a miss with
//   an empty array;
// - a refusal from the store, the bridge or the contract validator is an ordinary returned value
//   `{error: "refused", refusal: {code, detail, retryable}}` (never thrown, so it is never a
//   transport failure);
// - a cursor from another analysis generation is exactly `{error: "staleCursor"}`.
// Argument shape errors (missing or mistyped arguments) are the authority's usual -32602.

/// Image bytes and identity captured on the MainActor so detection and resolution can run in a
/// detached task.
struct NavigatorImageInput: Sendable {
    /// The selected slice, indexed from the start of the slice.
    var slice: Data
    var identity: MachOSliceArtifactIdentity?
}

/// Everything the navigator commands read from or write to the workspace. `live(_:)` binds it to
/// a `WorkspaceStore`; tests bind it to in-memory values. All workspace access goes through this
/// type, so the bridge to the navigator store is adapted in one place.
@MainActor
struct NavigatorSurface {
    /// Maps the `imageSlot` argument (slot index, decimal string or image-owner ID) to a loaded
    /// image, nil when none matches.
    var resolveImage: @MainActor (ScriptValue) -> ImageSlot?
    /// The image's navigator store (a value copy), nil when the image has none.
    var state: @MainActor (ImageSlot) -> NavigatorContractStore?
    /// The analysis generation key of the image (`AnalysisInputFingerprint.inputKey`).
    var generationKey: @MainActor (ImageSlot) -> String
    /// The selected slice and identity of the image, nil when no bytes are loaded.
    var image: @MainActor (ImageSlot) -> NavigatorImageInput?
    /// Proof certificates the image's provenance may cite.
    var certificates: @MainActor (ImageSlot) -> [NavigatorProofCertificate]
    /// Accepts an annotation (one undo group); a refusal is returned typed.
    var accept: @MainActor (NavigatorAnnotation, ImageSlot) -> NavigatorRefusal?
    /// Reverts `handle` (`revert:<id>`) under `session` (one undo group).
    var revert: @MainActor (_ handle: String, _ session: String, ImageSlot) -> NavigatorRefusal?
    var registry: NavigatorPrimitiveRegistry

    init(resolveImage: @escaping @MainActor (ScriptValue) -> ImageSlot?,
         state: @escaping @MainActor (ImageSlot) -> NavigatorContractStore?,
         generationKey: @escaping @MainActor (ImageSlot) -> String,
         image: @escaping @MainActor (ImageSlot) -> NavigatorImageInput?,
         certificates: @escaping @MainActor (ImageSlot) -> [NavigatorProofCertificate] = { _ in [] },
         accept: @escaping @MainActor (NavigatorAnnotation, ImageSlot) -> NavigatorRefusal?,
         revert: @escaping @MainActor (_ handle: String, _ session: String, ImageSlot) -> NavigatorRefusal?,
         registry: NavigatorPrimitiveRegistry = .standard) {
        self.resolveImage = resolveImage
        self.state = state
        self.generationKey = generationKey
        self.image = image
        self.certificates = certificates
        self.accept = accept
        self.revert = revert
        self.registry = registry
    }
}

extension NavigatorSurface {
    /// The surface over a workspace store. The `store.` calls into the navigator bridge
    /// (`navigatorState(for:)`, `navigatorGenerations`/`navigatorGeneration(for:)`,
    /// `navigatorCertificates(in:)`, `acceptAnnotation(_:in:)`, `revertNavigator(_:in:session:)`)
    /// are the only references to it.
    static func live(_ store: WorkspaceStore) -> NavigatorSurface {
        NavigatorSurface(
            resolveImage: { raw in
                try? WorkspaceScriptingAPI.resolveImageSlot(
                    .object([WorkspaceScriptingAPI.imageSelectorArgument: raw]), snapshot: store.snapshot)
            },
            // `navigatorState(for: ImageSlot) -> NavigatorContractStore?` is the bridge's accessor.
            state: { slot in store.navigatorState(for: slot) },
            // The cursor is fenced on the same input key the bridge stamps into the slot's generation
            // (recorded at the last landing, else recomputed); the stored fingerprint carries no input
            // key because the bridge computes it on demand.
            generationKey: { slot in
                store.navigatorGenerations[slot]?.inputKey ?? store.navigatorGeneration(for: slot)?.inputKey ?? "none"
            },
            image: { slot in
                let snapshot = store.snapshot
                guard let analysis = snapshot.analysis(in: slot), !analysis.imageBytes.isEmpty else { return nil }
                return NavigatorImageInput(slice: analysis.imageBytes, identity: snapshot.binary(in: slot)?.artifactIdentity)
            },
            // The certificates the producer retained for the slot (in memory, rebuilt on reopen);
            // a `proofCertificate` provenance resolves against this set or not at all.
            certificates: { slot in store.navigatorCertificates(in: slot) },
            // `acceptAnnotation(_:in:) -> NavigatorRefusal?` is the bridge's entry point (one undo
            // group, "Accept Annotation").
            accept: { annotation, slot in store.acceptAnnotation(annotation, in: slot) },
            // The bridge's own `revertNavigator(_:in:session:)` runs the revert preflight, names the
            // undo step "Revert Navigator Fact" and lets the findings layer react to the revert.
            revert: { handle, session, slot in
                store.revertNavigator(handle, in: slot, session: session)
            })
    }
}

enum NavigatorMCPCommands {
    // MARK: - Names and catalog

    static let nameFacts = "navigator-facts"
    static let nameFrontier = "navigator-frontier"
    static let nameDependents = "navigator-dependents"
    static let namePrimitives = "navigator-primitives"
    static let namePreviewRevert = "navigator-preview-revert"
    static let nameRevert = "navigator-revert"
    static let nameAccept = "navigator-accept"
    static let nameToolchain = "navigator-toolchain"
    static let nameResolveProvenance = "navigator-resolve-provenance"

    static let names: [String] = [
        nameFacts, nameFrontier, nameDependents, namePrimitives, namePreviewRevert, nameRevert,
        nameAccept, nameToolchain, nameResolveProvenance,
    ]

    /// What an attached agent may call: every read and `navigator-accept`; not `navigator-revert`.
    static let attachable: Set<String> = Set(names).subtracting([nameRevert])

    static let imageSlotKey = WorkspaceScriptingAPI.imageSlotFilterArgument

    static let catalog: [ScriptingCommandInfo] = [
        ScriptingCommandInfo(
            name: nameFacts,
            summary: "List the navigator's typed facts for one image, sorted by id; stale facts are left out unless includeStale is true. Cursor-paged, limit at most 256. A miss is {absent: {subject, reason}}.",
            mutates: false,
            arguments: [imageSlotKey, "subject", "predicate", "status", "includeStale", "cursor", "limit"]),
        ScriptingCommandInfo(
            name: nameFrontier,
            summary: "List the open frontier of one image: items with cost, costClass and leverage, sorted by leverage descending then cost ascending. Cursor-paged, limit at most 256. A miss is {absent: {subject, reason}}.",
            mutates: false,
            arguments: [imageSlotKey, "kind", "cursor", "limit"]),
        ScriptingCommandInfo(
            name: nameDependents,
            summary: "List the facts and annotations that rest, transitively (depth at most 32), on a fact, annotation id or ann:<session>/<seq> premise. A miss is {absent: {subject, reason}}.",
            mutates: false,
            arguments: [imageSlotKey, "id"]),
        ScriptingCommandInfo(
            name: namePrimitives,
            summary: "List the registry primitives that apply to the image's detected toolchain key, each with producesStatus, applicability and onOutOfRange. A miss is {absent: {subject, reason}}.",
            mutates: false,
            arguments: [imageSlotKey]),
        ScriptingCommandInfo(
            name: namePreviewRevert,
            summary: "Preview reverting a fact or annotation (or its revert:<id> handle): the live facts lost, annotations affected and frontier items raised. Changes nothing.",
            mutates: false,
            arguments: [imageSlotKey, "id"]),
        ScriptingCommandInfo(
            name: nameRevert,
            summary: "Revert a fact or annotation (or its revert:<id> handle) under a session as one undo group, and report the effect. Authoritative facts are refused as notReversible.",
            mutates: true,
            arguments: [imageSlotKey, "id", "session"]),
        ScriptingCommandInfo(
            name: nameAccept,
            summary: "Accept a navigator annotation: a full Annotation record, or a draft without id (session, seq, author, action, subject, predicate, value, cites, rationale). The author must be navigator; refusals are typed.",
            mutates: true,
            arguments: [imageSlotKey, "annotation"]),
        ScriptingCommandInfo(
            name: nameToolchain,
            summary: "Report the toolchain key detected from the image (arch, platforms, tools, swiftABI, linkerFlavor) with its confidence. A miss is {absent: {subject, reason}}.",
            mutates: false,
            arguments: [imageSlotKey]),
        ScriptingCommandInfo(
            name: nameResolveProvenance,
            summary: "Resolve a provenance entry (kind, ref) to the record it cites: bytes as hex (bounded to 4 KiB, truncated flagged), a rule, a proof certificate, an annotation, or an unresolvable reason.",
            mutates: false,
            arguments: [imageSlotKey, "provenance"]),
    ]

    static func handles(_ command: String) -> Bool { names.contains(command) }

    static func info(_ command: String) -> ScriptingCommandInfo? { catalog.first { $0.name == command } }

    // MARK: - Limits

    static let defaultPageLimit = 100
    static let maximumPageLimit = 256
    static let maximumDependentsDepth = 32
    static let maximumDependentRows = 256
    static let maximumResolvedHexBytes = 4_096
    static let maximumIdBytes = 512
    static let maximumSessionBytes = 128
    static let maximumCursorBytes = 1_024

    // MARK: - Schemas

    static func requiredArguments(for command: String) -> [String] {
        switch command {
        case nameDependents, namePreviewRevert: return [imageSlotKey, "id"]
        case nameRevert: return [imageSlotKey, "id", "session"]
        case nameAccept: return [imageSlotKey, "annotation"]
        case nameResolveProvenance: return [imageSlotKey, "provenance"]
        default: return [imageSlotKey]
        }
    }

    static func argumentSchema(_ argument: String) -> ScriptValue {
        let string: ScriptValue = .object(["type": .string("string")])
        func strings(_ values: [String]) -> ScriptValue { .array(values.map(ScriptValue.string)) }
        switch argument {
        case imageSlotKey:
            return .object([
                "type": .array([.string("integer"), .string("string")]),
                "description": .string("The image to read: its slot index (0 is the primary image), a decimal slot string or the image-owner ID shown by `info`. Required."),
            ])
        case "subject":
            return .object([
                "type": .string("object"),
                "description": .string("Only facts about this subject {kind, ref, image?}. kind is one of the contract subject kinds."),
                "properties": .object([
                    "kind": .object(["type": .string("string"), "enum": strings(NavigatorContractVocabulary.subjectKinds)]),
                    "ref": string,
                    "image": string,
                ]),
                "required": strings(["kind", "ref"]),
                "additionalProperties": .bool(false),
            ])
        case "predicate":
            return .object([
                "type": .string("string"),
                "enum": strings(NavigatorContractVocabulary.predicates.keys.sorted()),
                "description": .string("Only facts with this predicate."),
            ])
        case "status":
            return .object([
                "type": .string("string"),
                "enum": strings(NavigatorContractVocabulary.statuses),
                "description": .string("Only facts with this status."),
            ])
        case "kind":
            return .object([
                "type": .string("string"),
                "enum": strings(NavigatorContractVocabulary.gaps),
                "description": .string("Only frontier items of this gap kind."),
            ])
        case "includeStale":
            return .object([
                "type": .string("boolean"),
                "description": .string("Also list facts a reanalysis invalidated (default false)."),
            ])
        case "cursor":
            return .object([
                "type": .string("string"),
                "description": .string("The `next` value of the previous page. It is bound to the analysis generation: after a reanalysis the answer is {error: \"staleCursor\"}; restart without a cursor."),
            ])
        case "limit":
            return .object([
                "type": .string("integer"), "minimum": .int(1), "maximum": .int(Int64(maximumPageLimit)),
                "description": .string("Rows per page, 1 to \(maximumPageLimit) (default \(defaultPageLimit))."),
            ])
        case "id":
            return .object([
                "type": .string("string"), "maxLength": .int(Int64(maximumIdBytes)),
                "description": .string("A fact id (f-...), annotation id (a-...), ann:<session>/<seq> premise or revert:<id> handle."),
            ])
        case "session":
            return .object([
                "type": .string("string"), "minLength": .int(1), "maxLength": .int(Int64(maximumSessionBytes)),
                "description": .string("The session the revert is journaled under."),
            ])
        case "annotation":
            return .object([
                "type": .string("object"),
                "description": .string("A NavigatorAnnotation record (with id) or a draft without id: session, seq, author (must be navigator), action, subject, predicate, value, cites (at least one live fact id), rationale (non-empty)."),
            ])
        case "provenance":
            return .object([
                "type": .string("object"),
                "description": .string("A provenance entry {kind, ref, rule?, ruleVersion?}."),
                "properties": .object([
                    "kind": .object(["type": .string("string"), "enum": strings(NavigatorContractVocabulary.provenanceKinds)]),
                    "ref": string, "rule": string, "ruleVersion": string,
                ]),
                "required": strings(["kind", "ref"]),
                "additionalProperties": .bool(false),
            ])
        default:
            return string
        }
    }

    // MARK: - Argument validation

    /// Shape validation for the closed authority (failures are the usual -32602). Semantic
    /// problems (a subject, id or provenance that is not in the contract grammar) are typed
    /// refusals from `execute`, so an agent is told why.
    static func validate(command: String, fields: [String: ScriptValue]) throws {
        let invalid = HeadlessAutomationAuthorityError.invalidArguments
        guard let slot = fields[imageSlotKey], slot != .null else { throw invalid }

        func string(_ key: String, maxBytes: Int, required: Bool = false, nonEmpty: Bool = false) throws {
            guard let value = fields[key], value != .null else {
                if required { throw invalid }
                return
            }
            guard let text = value.stringValue, text.utf8.count <= maxBytes, !(nonEmpty && text.isEmpty) else { throw invalid }
        }
        func object(_ key: String, required: Bool) throws {
            guard let value = fields[key], value != .null else {
                if required { throw invalid }
                return
            }
            guard case .object = value else { throw invalid }
        }
        func page() throws {
            if let limit = fields["limit"], limit != .null {
                guard case .int(let count) = limit, (1 ... Int64(maximumPageLimit)).contains(count) else { throw invalid }
            }
            try string("cursor", maxBytes: maximumCursorBytes)
            if let cursor = fields["cursor"]?.stringValue, decodeCursor(cursor) == nil { throw invalid }
        }

        switch command {
        case nameFacts:
            try object("subject", required: false)
            try string("predicate", maxBytes: 256)
            try string("status", maxBytes: 64)
            if let stale = fields["includeStale"], stale != .null, stale.boolValue == nil { throw invalid }
            try page()
        case nameFrontier:
            try string("kind", maxBytes: 64)
            try page()
        case nameDependents, namePreviewRevert:
            try string("id", maxBytes: maximumIdBytes, required: true, nonEmpty: true)
        case nameRevert:
            try string("id", maxBytes: maximumIdBytes, required: true, nonEmpty: true)
            try string("session", maxBytes: maximumSessionBytes, required: true, nonEmpty: true)
            if fields["session"]?.stringValue?.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) == true {
                throw invalid
            }
        case nameAccept:
            try object("annotation", required: true)
        case nameResolveProvenance:
            try object("provenance", required: true)
        default:
            break
        }
    }

    // MARK: - Execution

    /// Work that parses a Mach-O slice or reads many bytes. Captured on the MainActor with only
    /// Sendable values, run inline by `execute` and in a detached task by `executeAsync`.
    struct HeavyJob: Sendable {
        enum Kind: Sendable {
            case toolchain(stateToolchain: String?)
            case primitives
            case provenance(NavigatorProvenance, annotations: [NavigatorAnnotation], certificates: [NavigatorProofCertificate])
        }

        var kind: Kind
        var slot: Int64
        var input: NavigatorImageInput?
        var registry: NavigatorPrimitiveRegistry

        func run() throws -> ScriptValue {
            let echo = NavigatorMCPCommands.slotEcho(slot)
            switch kind {
            case .toolchain(let stateToolchain):
                guard let key = NavigatorMCPCommands.detect(input) else {
                    return NavigatorMCPCommands.absent(echo, "unsupportedToolchain")
                }
                try Task.checkCancellation()
                return .object([
                    "toolchain": NavigatorMCPCommands.toolchainValue(key),
                    "stateToolchain": stateToolchain.map(ScriptValue.string) ?? .null,
                ])
            case .primitives:
                guard let key = NavigatorMCPCommands.detect(input) else {
                    return NavigatorMCPCommands.absent(echo, "unsupportedToolchain")
                }
                try Task.checkCancellation()
                let applicable = registry.applicable(to: key)
                guard !applicable.isEmpty else { return NavigatorMCPCommands.absent(echo, "unsupportedToolchain") }
                return .object([
                    "primitives": .array(applicable.map {
                        NavigatorMCPCommands.descriptorValue($0, disposition: registry.disposition(of: $0, for: key))
                    }),
                    "toolchain": .object([
                        "canonical": .string(key.canonical), "confidence": .string(key.confidence.rawValue),
                    ]),
                ])
            case .provenance(let provenance, let annotations, let certificates):
                var evidence: NavigatorImageEvidence?
                if NavigatorProvenanceResolver.imageKinds.contains(provenance.kind), let input {
                    evidence = NavigatorImageEvidence(
                        slice: input.slice, image: input.identity.map(NavigatorSubjectRef.imageRef))
                }
                try Task.checkCancellation()
                let context = NavigatorProvenanceResolver.Context(
                    registry: registry, certificates: certificates, annotations: annotations)
                let resolved = NavigatorProvenanceResolver.resolve(provenance, in: evidence, context: context)
                return .object(["resolved": NavigatorMCPCommands.resolvedValue(resolved, slice: evidence?.slice)])
            }
        }
    }

    enum Prepared {
        case done(ScriptValue)
        case heavy(HeavyJob)
    }

    /// Inline execution (the CLI, the headless MCP transport's sync path, tests).
    @MainActor
    static func execute(command: String, arguments: ScriptValue, surface: NavigatorSurface) throws -> ScriptValue {
        switch try prepare(command: command, arguments: arguments, surface: surface) {
        case .done(let value): return value
        case .heavy(let job): return try job.run()
        }
    }

    /// Async execution: the MainActor part runs first, then the heavy part off the MainActor in a
    /// task the request owns (cancelled with it).
    @MainActor
    static func executeAsync(command: String, arguments: ScriptValue, surface: NavigatorSurface) async throws -> ScriptValue {
        switch try prepare(command: command, arguments: arguments, surface: surface) {
        case .done(let value):
            return value
        case .heavy(let job):
            let work = Task.detached(priority: Task.currentPriority) { try job.run() }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
    }

    @MainActor
    private static func prepare(command: String, arguments: ScriptValue, surface: NavigatorSurface) throws -> Prepared {
        guard handles(command), case .object(let fields) = arguments else {
            throw HeadlessAutomationAuthorityError.invalidArguments
        }
        try validate(command: command, fields: fields)
        guard let rawSlot = fields[imageSlotKey], let slot = surface.resolveImage(rawSlot) else {
            return .done(absent(.object([imageSlotKey: fields[imageSlotKey] ?? .null]), "noSuchImage"))
        }
        switch command {
        case nameFacts:
            return .done(factsResult(fields, slot: slot, surface: surface))
        case nameFrontier:
            return .done(frontierResult(fields, slot: slot, surface: surface))
        case nameDependents:
            return .done(dependentsResult(fields, slot: slot, surface: surface))
        case namePreviewRevert:
            return .done(revertResult(fields, slot: slot, surface: surface, perform: false))
        case nameRevert:
            return .done(revertResult(fields, slot: slot, surface: surface, perform: true))
        case nameAccept:
            return .done(acceptResult(fields, slot: slot, surface: surface))
        case namePrimitives:
            return .heavy(HeavyJob(kind: .primitives, slot: Int64(slot.rawValue), input: surface.image(slot),
                                   registry: surface.registry))
        case nameToolchain:
            return .heavy(HeavyJob(kind: .toolchain(stateToolchain: surface.state(slot)?.toolchain),
                                   slot: Int64(slot.rawValue), input: surface.image(slot), registry: surface.registry))
        case nameResolveProvenance:
            return try provenanceJob(fields, slot: slot, surface: surface)
        default:
            throw HeadlessAutomationAuthorityError.unavailableCommand
        }
    }

    // MARK: - navigator-facts

    @MainActor
    private static func factsResult(_ fields: [String: ScriptValue], slot: ImageSlot, surface: NavigatorSurface) -> ScriptValue {
        guard let paging = pageRequest(fields, slot: slot, surface: surface) else { return staleCursor }
        let echo = slotEcho(Int64(slot.rawValue))
        guard let store = surface.state(slot) else { return absent(echo, "noFacts") }

        var subjectKey: String?
        var subjectEcho = echo
        if let raw = fields["subject"], raw != .null {
            guard let json = contract(raw) else { return malformed("subject: not contract JSON") }
            if let first = NavigatorContractValidator.validateSubject(json, "subject").first { return malformed(first) }
            subjectKey = canonical(NavigatorSubject(validated: json).json)
            subjectEcho = slotEcho(Int64(slot.rawValue), ["subject": raw])
        }
        let predicate = fields["predicate"].flatMap { $0 == .null ? nil : $0.stringValue }
        if let predicate, NavigatorContractVocabulary.predicate(named: predicate) == nil {
            return malformed("predicate: not in vocabulary")
        }
        let status = fields["status"].flatMap { $0 == .null ? nil : $0.stringValue }
        if let status, !NavigatorContractVocabulary.statuses.containsExactly(status) {
            return malformed("status: not in vocabulary")
        }
        let includeStale = fields["includeStale"]?.boolValue ?? false

        func matches(_ fact: NavigatorFact) -> Bool {
            (subjectKey.map { canonical(fact.subject.json) == $0 } ?? true)
                && (predicate.map { sameScalars(fact.predicate, $0) } ?? true)
                && (status.map { sameScalars(fact.status, $0) } ?? true)
        }

        let all = store.allFacts()
        guard !all.isEmpty else { return absent(echo, "noFacts") }
        let reverted = store.revertedTargets()
        var rows = store.liveFacts().values.filter(matches)
        let staleMatches = all.values.filter {
            store.staleGeneration.contains($0.id) && !reverted.contains($0.id) && matches($0)
        }
        if includeStale { rows += staleMatches }
        rows.sort { $0.id < $1.id }

        if rows.isEmpty {
            if let subjectKey, !all.values.contains(where: { canonical($0.subject.json) == subjectKey }) {
                return absent(subjectEcho, "noSuchSubject")
            }
            return absent(subjectEcho, !includeStale && !staleMatches.isEmpty ? "stale" : "noFacts")
        }
        guard paging.offset < rows.count else { return absent(subjectEcho, "noFacts") }
        let end = min(rows.count, paging.offset + paging.limit)
        var result: [String: ScriptValue] = ["facts": .array(rows[paging.offset ..< end].map { script($0.json) })]
        if end < rows.count { result["next"] = .string(encodeCursor(offset: end, generation: surface.generationKey(slot))) }
        return .object(result)
    }

    // MARK: - navigator-frontier

    @MainActor
    private static func frontierResult(_ fields: [String: ScriptValue], slot: ImageSlot, surface: NavigatorSurface) -> ScriptValue {
        guard let paging = pageRequest(fields, slot: slot, surface: surface) else { return staleCursor }
        let echo = slotEcho(Int64(slot.rawValue))
        guard let store = surface.state(slot) else { return absent(echo, "noFacts") }
        let kind = fields["kind"].flatMap { $0 == .null ? nil : $0.stringValue }
        if let kind, !NavigatorContractVocabulary.gaps.containsExactly(kind) { return malformed("kind: not a gap in the vocabulary") }

        var items = store.frontier()
        if let kind { items = items.filter { sameScalars($0.gap, kind) } }
        guard !items.isEmpty else {
            return absent(kind.map { slotEcho(Int64(slot.rawValue), ["kind": .string($0)]) } ?? echo, "noFacts")
        }
        let ranked = items.map { (item: $0, cost: costRank(of: $0, registry: surface.registry)) }.sorted { lhs, rhs in
            if lhs.item.leverage != rhs.item.leverage { return lhs.item.leverage > rhs.item.leverage }
            if lhs.cost.rank != rhs.cost.rank { return lhs.cost.rank < rhs.cost.rank }
            return lhs.item.id < rhs.item.id
        }
        guard paging.offset < ranked.count else { return absent(echo, "noFacts") }
        let end = min(ranked.count, paging.offset + paging.limit)
        let rows: [ScriptValue] = ranked[paging.offset ..< end].map { entry in
            guard case .object(var object) = script(entry.item.json) else { return script(entry.item.json) }
            object["costClass"] = .string(entry.cost.label)
            return .object(object)
        }
        var result: [String: ScriptValue] = ["items": .array(rows)]
        if end < ranked.count { result["next"] = .string(encodeCursor(offset: end, generation: surface.generationKey(slot))) }
        return .object(result)
    }

    /// The producer cost class of an item: the most expensive registry primitive it names
    /// (`cheap` < `bounded` < `expensive`); `unrated` (ranked last) when none is in the registry.
    static func costRank(of item: NavigatorFrontierItem, registry: NavigatorPrimitiveRegistry) -> (rank: Int, label: String) {
        let classes = NavigatorPrimitiveRegistry.costClasses
        var worst = -1
        for primitive in item.primitives {
            guard let descriptor = registry.lookup(id: primitive.name),
                  let index = classes.firstIndex(of: descriptor.costClass) else { continue }
            worst = max(worst, index)
        }
        return worst < 0 ? (classes.count, "unrated") : (worst, classes[worst])
    }

    // MARK: - navigator-dependents

    private enum DependentNode {
        case fact(NavigatorFact)
        case annotation(NavigatorAnnotation)

        var id: String {
            switch self {
            case .fact(let fact): fact.id
            case .annotation(let note): note.id
            }
        }

        /// The handle other records cite this one by: a fact id, or `ann:<session>/<seq>`.
        var key: String {
            switch self {
            case .fact(let fact): fact.id
            case .annotation(let note): note.premise
            }
        }
    }

    @MainActor
    private static func dependentsResult(_ fields: [String: ScriptValue], slot: ImageSlot, surface: NavigatorSurface) -> ScriptValue {
        guard let id = fields["id"]?.stringValue else { return malformed("id is required") }
        let echo = slotEcho(Int64(slot.rawValue), ["id": .string(id)])
        let isFact = NavigatorContractValidator.isFactID(id)
        let isNote = NavigatorContractValidator.isAnnotationID(id)
        let isPremise = NavigatorContractValidator.isAnnotationPremise(id)
        guard isFact || isNote || isPremise else {
            return malformed("id must be a fact id, an annotation id or an ann:<session>/<seq> premise")
        }
        guard let store = surface.state(slot) else { return absent(slotEcho(Int64(slot.rawValue)), "noFacts") }

        let facts = store.allFacts()
        let notes = store.annotations()
        let reverted = store.revertedTargets()
        let liveFacts = store.liveFacts()
        let liveNotes = Set(store.liveAnnotations().map(\.id))

        let rootKey: String
        let rootID: String
        if isFact {
            guard facts[id] != nil, !reverted.contains(id) else { return absent(echo, "noSuchSubject") }
            guard !store.staleGeneration.contains(id) else { return absent(echo, "stale") }
            rootKey = id
            rootID = id
        } else {
            let note = isNote ? notes[id] : notes.values.first { sameScalars($0.premise, id) }
            guard let note, !note.reverted else { return absent(echo, "noSuchSubject") }
            guard liveNotes.contains(note.id) else { return absent(echo, "stale") }
            rootKey = note.premise
            rootID = note.id
        }

        // Reverse index: premise handle -> the records whose derivation or citations name it.
        var reverse: [String: [DependentNode]] = [:]
        for fact in facts.values where !reverted.contains(fact.id) {
            for group in fact.derivedFrom ?? [] {
                for premise in group { reverse[premise, default: []].append(.fact(fact)) }
            }
        }
        for note in notes.values where !note.reverted {
            for cite in note.cites { reverse[cite, default: []].append(.annotation(note)) }
        }

        var seen: Set<String> = [rootID]
        var layer = [rootKey]
        var depth = 0
        var truncated = false
        var rows: [(depth: Int, id: String, value: ScriptValue)] = []
        while !layer.isEmpty {
            depth += 1
            if depth > maximumDependentsDepth {
                truncated = truncated || layer.contains { key in (reverse[key] ?? []).contains { !seen.contains($0.id) } }
                break
            }
            var next: [String] = []
            for key in layer {
                for node in (reverse[key] ?? []).sorted(by: { $0.id < $1.id }) {
                    guard seen.insert(node.id).inserted else { continue }
                    guard rows.count < maximumDependentRows else { truncated = true; continue }
                    let value: ScriptValue
                    switch node {
                    case .fact(let fact):
                        value = .object(["kind": .string("fact"), "id": .string(fact.id), "depth": .int(Int64(depth)),
                                         "live": .bool(liveFacts[fact.id] != nil), "record": script(fact.json)])
                    case .annotation(let note):
                        value = .object(["kind": .string("annotation"), "id": .string(note.id), "depth": .int(Int64(depth)),
                                         "live": .bool(liveNotes.contains(note.id)), "record": script(note.json)])
                    }
                    rows.append((depth, node.id, value))
                    next.append(node.key)
                }
            }
            layer = next
        }
        guard !rows.isEmpty else { return absent(echo, "noFacts") }
        rows.sort { ($0.depth, $0.id) < ($1.depth, $1.id) }
        return .object(["id": .string(id), "dependents": .array(rows.map(\.value)), "truncated": .bool(truncated)])
    }

    // MARK: - navigator-preview-revert / navigator-revert

    @MainActor
    private static func revertResult(_ fields: [String: ScriptValue], slot: ImageSlot, surface: NavigatorSurface,
                                     perform: Bool) -> ScriptValue {
        guard let raw = fields["id"]?.stringValue else { return malformed("id is required") }
        let bare = raw.hasPrefix("revert:") ? String(raw.dropFirst("revert:".count)) : raw
        let echo = slotEcho(Int64(slot.rawValue), ["id": .string(bare)])
        let isFact = NavigatorContractValidator.isFactID(bare)
        guard isFact || NavigatorContractValidator.isAnnotationID(bare) else {
            return malformed("id must be a fact id, an annotation id or a revert:<id> handle")
        }
        let session = fields["session"]?.stringValue ?? "preview"
        guard let store = surface.state(slot) else { return absent(slotEcho(Int64(slot.rawValue)), "noFacts") }
        if isFact {
            guard store.allFacts()[bare] != nil else { return absent(echo, "noSuchSubject") }
            guard !store.staleGeneration.contains(bare) else { return absent(echo, "stale") }
        } else {
            guard store.annotations()[bare] != nil else { return absent(echo, "noSuchSubject") }
        }
        let handle = "revert:" + bare
        let effect = store.preview(revert: handle, session: session)
        if let refusal = effect.refusal { return refused(refusal) }
        var result: [String: ScriptValue] = [
            "id": .string(bare),
            "factsLost": strings(effect.factsLost),
            "annotationsAffected": strings(effect.annotationsAffected),
            "frontierRaised": strings(effect.frontierRaised),
        ]
        if perform {
            if let refusal = surface.revert(handle, session, slot) { return refused(refusal) }
            result["reverted"] = .bool(true)
            result["session"] = .string(session)
        }
        return .object(result)
    }

    // MARK: - navigator-accept

    @MainActor
    private static func acceptResult(_ fields: [String: ScriptValue], slot: ImageSlot, surface: NavigatorSurface) -> ScriptValue {
        guard let raw = fields["annotation"], case .object(let record) = raw, let json = contract(raw) else {
            return malformed("annotation: expected a JSON object of contract values")
        }
        guard let author = record["author"]?.stringValue else { return malformed("annotation.author is required") }
        guard sameScalars(author, "navigator") else {
            return refused(NavigatorRefusal("preconditionFailed", "navigator-accept takes author navigator; analyst annotations are made in the app"))
        }
        guard surface.state(slot) != nil else { return absent(slotEcho(Int64(slot.rawValue)), "noFacts") }
        let annotation: NavigatorAnnotation
        do {
            annotation = try parseAnnotation(record, json)
        } catch let error as NavigatorContractError {
            return malformed(error.reasons.prefix(8).joined(separator: "; "))
        } catch {
            return malformed("annotation: \(error.localizedDescription)")
        }
        if let refusal = surface.accept(annotation, slot) { return refused(refusal) }
        return .object(["accepted": .object([
            "annotation": script(annotation.json),
            "premise": .string(annotation.premise),
            "revert": .string(annotation.revert),
        ])])
    }

    /// A full record (it has an id: validated, id recomputed) or a draft (no id: the id is a
    /// canonical-JSON digest a caller cannot compute, so the draft is built and validated here).
    private static func parseAnnotation(_ record: [String: ScriptValue], _ json: NavigatorJSONValue) throws -> NavigatorAnnotation {
        if record["id"] != nil { return try NavigatorAnnotation(json: json) }
        let draftKeys: Set<String> = ["session", "seq", "author", "action", "subject", "predicate", "value", "cites", "rationale"]
        let extra = Set(record.keys).subtracting(draftKeys)
        guard extra.isEmpty else {
            throw NavigatorContractError(reasons: ["annotation: unknown keys \(extra.sorted().joined(separator: ", "))"])
        }
        guard let session = json["session"]?.stringValue, let seq = json["seq"]?.intValue,
              let author = json["author"]?.stringValue, let action = json["action"]?.stringValue,
              let subjectJSON = json["subject"], let predicate = json["predicate"]?.stringValue,
              let value = json["value"] else {
            throw NavigatorContractError(reasons: ["annotation: session, seq, author, action, subject, predicate and value are required"])
        }
        let subjectReasons = NavigatorContractValidator.validateSubject(subjectJSON, "annotation.subject")
        guard subjectReasons.isEmpty else { throw NavigatorContractError(reasons: subjectReasons) }
        var cites: [String] = []
        if let list = json["cites"] {
            guard let items = list.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
                throw NavigatorContractError(reasons: ["annotation.cites: expected array of strings"])
            }
            cites = items.compactMap(\.stringValue)
        }
        var rationale = ""
        if let entry = json["rationale"] {
            guard let text = entry.stringValue else { throw NavigatorContractError(reasons: ["annotation.rationale: expected string"]) }
            rationale = text
        }
        return try NavigatorAnnotation.make(
            session: session, seq: seq, author: author, action: action, subject: NavigatorSubject(validated: subjectJSON),
            predicate: predicate, value: value, cites: cites, rationale: rationale)
    }

    // MARK: - navigator-resolve-provenance

    @MainActor
    private static func provenanceJob(_ fields: [String: ScriptValue], slot: ImageSlot, surface: NavigatorSurface) throws -> Prepared {
        guard let raw = fields["provenance"], let json = contract(raw) else {
            return .done(malformed("provenance: expected a JSON object of contract values"))
        }
        if let first = NavigatorContractValidator.validateProvenance(json, "provenance").first {
            return .done(malformed(first))
        }
        let annotations = surface.state(slot)?.annotations().values.sorted { $0.id < $1.id } ?? []
        return .heavy(HeavyJob(
            kind: .provenance(NavigatorProvenance(validated: json), annotations: annotations,
                              certificates: surface.certificates(slot)),
            slot: Int64(slot.rawValue), input: surface.image(slot), registry: surface.registry))
    }

    // MARK: - Heavy-job helpers (run off the MainActor)

    /// The toolchain key of an image, nil when there is no identity or the slice does not parse.
    static func detect(_ input: NavigatorImageInput?) -> NavigatorToolchainKey? {
        guard let input, let identity = input.identity,
              let file = try? MachOParser().parse(input.slice, options: NavigatorImageEvidence.parseOptions),
              file.selectedSliceOffset == 0 else { return nil }
        return NavigatorToolchainKeyDetector.detect(file: file, identity: identity)
    }

    static func toolchainValue(_ key: NavigatorToolchainKey) -> ScriptValue {
        .object([
            "arch": .string(key.arch),
            "platforms": .array(key.platforms.map {
                ScriptValue.object(["name": .string($0.name), "minOS": .string($0.minOS), "sdk": .string($0.sdk)])
            }),
            "tools": .array(key.tools.map { ScriptValue.object(["name": .string($0.name), "version": .string($0.version)]) }),
            "swiftABI": key.swiftABI.map(ScriptValue.string) ?? .null,
            "linkerFlavor": .string(key.linkerFlavor),
            "confidence": .string(key.confidence.rawValue),
            "derivedFrom": .string(key.derivedFrom),
            "canonical": .string(key.canonical),
        ])
    }

    static func applicabilityValue(_ applicability: NavigatorApplicability) -> ScriptValue {
        .object([
            "archs": strings(applicability.archs),
            "platforms": strings(applicability.platforms),
            "swiftABI": applicability.swiftABI.map(ScriptValue.string) ?? .null,
            "linkerFlavors": strings(applicability.linkerFlavors),
            "swiftTools": applicability.swiftTools.map {
                ScriptValue.object(["minimum": .string($0.minimum), "maximum": .string($0.maximum)])
            } ?? .null,
        ])
    }

    static func descriptorValue(_ descriptor: NavigatorPrimitiveDescriptor, disposition: String?) -> ScriptValue {
        var fields: [String: ScriptValue] = [
            "id": .string(descriptor.id),
            "version": .string(descriptor.version),
            "producesStatus": .string(descriptor.producesStatus),
            "costClass": .string(descriptor.costClass),
            "inputs": strings(descriptor.inputs),
            "outputs": strings(descriptor.outputs),
            "applicability": applicabilityValue(descriptor.applicability),
            "onOutOfRange": .string(descriptor.onOutOfRange),
            "isImplemented": .bool(descriptor.isImplemented),
        ]
        if let disposition { fields["disposition"] = .string(disposition) }
        return .object(fields)
    }

    /// The hex of `slice[range]`, at most `maximumResolvedHexBytes` bytes, and whether it was cut.
    /// Nil when the range lies outside the slice.
    static func boundedHex(_ slice: Data, _ range: Range<Int>) -> (hex: String, truncated: Bool)? {
        guard range.lowerBound >= 0, range.upperBound <= slice.count else { return nil }
        let length = min(range.count, maximumResolvedHexBytes)
        let start = slice.startIndex + range.lowerBound
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(length * 2)
        for byte in slice[start ..< start + length] {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return (String(decoding: out, as: UTF8.self), range.count > maximumResolvedHexBytes)
    }

    private static func rangeFields(_ range: Range<Int>, sha256: String, slice: Data?) -> [String: ScriptValue] {
        var fields: [String: ScriptValue] = [
            "range": .object(["offset": .int(Int64(range.lowerBound)), "length": .int(Int64(range.count))]),
            "sha256": .string(sha256),
            "byteCount": .int(Int64(range.count)),
        ]
        if let slice, let bounded = boundedHex(slice, range) {
            fields["hex"] = .string(bounded.hex)
            fields["truncated"] = .bool(bounded.truncated)
        } else {
            fields["hex"] = .null
            fields["truncated"] = .bool(false)
        }
        return fields
    }

    static func resolvedValue(_ resolved: NavigatorProvenanceResolver.Resolved, slice: Data?) -> ScriptValue {
        switch resolved {
        case .bytes(let range, let sha256):
            var fields = rangeFields(range, sha256: sha256, slice: slice)
            fields["type"] = .string("bytes")
            return .object(fields)
        case .record(let description, let range, let sha256):
            var fields: [String: ScriptValue] = [
                "type": .string("record"), "description": .string(description), "sha256": .string(sha256),
            ]
            if let range { fields.merge(rangeFields(range, sha256: sha256, slice: slice)) { _, new in new } }
            return .object(fields)
        case .rule(let descriptor):
            return .object(["type": .string("rule"), "rule": descriptorValue(descriptor, disposition: nil)])
        case .certificate(let certificate):
            return .object(["type": .string("certificate"), "certificate": script(certificate.json)])
        case .annotation(let id):
            return .object(["type": .string("annotation"), "id": .string(id)])
        case .unresolvable(let reason):
            return .object(["type": .string("unresolvable"), "reason": .string(reason.rawValue)])
        }
    }

    // MARK: - Typed absence, refusal and cursors

    static let absenceReasons = ["noSuchImage", "noSuchSubject", "noFacts", "stale", "unsupportedToolchain"]

    /// `{absent: {subject, reason}}`; `subject` echoes what the caller asked about.
    static func absent(_ subject: ScriptValue, _ reason: String) -> ScriptValue {
        .object(["absent": .object(["subject": subject, "reason": .string(reason)])])
    }

    /// `{error: "refused", refusal: {code, detail, retryable}}`.
    static func refused(_ refusal: NavigatorRefusal) -> ScriptValue {
        .object(["error": .string("refused"), "refusal": script(refusal.json)])
    }

    static func malformed(_ detail: String) -> ScriptValue {
        refused(NavigatorRefusal("malformedInput", detail))
    }

    /// The only answer to a cursor minted under another analysis generation.
    static let staleCursor: ScriptValue = .object(["error": .string("staleCursor")])

    static func slotEcho(_ slot: Int64, _ extra: [String: ScriptValue] = [:]) -> ScriptValue {
        var fields = extra
        fields[imageSlotKey] = .int(slot)
        return .object(fields)
    }

    /// Cursor = opaque base64 of `v1|<offset>|<generation key>`. The key is everything after the
    /// second bar, so a key that itself contains `|` round-trips.
    static func encodeCursor(offset: Int, generation: String) -> String {
        Data("v1|\(offset)|\(generation)".utf8).base64EncodedString()
    }

    static func decodeCursor(_ text: String) -> (offset: Int, generation: String)? {
        guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8),
              decoded.hasPrefix("v1|") else { return nil }
        let body = decoded.dropFirst(3)
        guard let bar = body.firstIndex(of: "|") else { return nil }
        let digits = body[..<bar]
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let offset = Int(digits) else { return nil }
        return (offset, String(body[body.index(after: bar)...]))
    }

    /// The requested page, or nil when the cursor was minted under another generation.
    @MainActor
    private static func pageRequest(_ fields: [String: ScriptValue], slot: ImageSlot,
                                    surface: NavigatorSurface) -> (offset: Int, limit: Int)? {
        let limit = Int(fields["limit"]?.intValue ?? Int64(defaultPageLimit))
        guard let cursor = fields["cursor"]?.stringValue else { return (0, limit) }
        guard let decoded = decodeCursor(cursor), decoded.generation == surface.generationKey(slot) else { return nil }
        return (decoded.offset, limit)
    }

    // MARK: - Conversions

    static func script(_ value: NavigatorJSONValue) -> ScriptValue {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .int(let number): return .int(number)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map { script($0) })
        case .object(let fields): return .object(fields.mapValues { script($0) })
        }
    }

    /// The contract has no floating point: an integral double becomes an integer, a non-integral
    /// one is not contract JSON (nil).
    static func contract(_ value: ScriptValue) -> NavigatorJSONValue? {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .int(let number): return .int(number)
        case .double(let number):
            guard number.isFinite, number == number.rounded(.towardZero), let exact = Int64(exactly: number) else { return nil }
            return .int(exact)
        case .string(let text): return .string(text)
        case .array(let items):
            var out: [NavigatorJSONValue] = []
            for item in items {
                guard let converted = contract(item) else { return nil }
                out.append(converted)
            }
            return .array(out)
        case .object(let fields):
            var out: [String: NavigatorJSONValue] = [:]
            for (key, item) in fields {
                guard let converted = contract(item) else { return nil }
                out[key] = converted
            }
            return .object(out)
        }
    }

    private static func strings(_ values: [String]) -> ScriptValue { .array(values.map { ScriptValue.string($0) }) }

    private static func canonical(_ value: NavigatorJSONValue) -> String { (try? NavigatorJSONCanonical.encode(value)) ?? "" }

    private static func sameScalars(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }
}
