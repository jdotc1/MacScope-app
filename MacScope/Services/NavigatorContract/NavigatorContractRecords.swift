import Foundation

/// Typed records of contract v1. Each round-trips through `json` / `init(json:)`; `init(json:)`
/// runs the full record validation, so a typed value is always a valid record. Closed-vocabulary
/// fields stay `String` and are checked against `NavigatorContractVocabulary`.
struct NavigatorSubject: Hashable, Sendable {
    var kind: String
    var ref: String
    var image: String?

    var json: NavigatorJSONValue {
        var fields: [String: NavigatorJSONValue] = ["kind": .string(kind), "ref": .string(ref)]
        if let image { fields["image"] = .string(image) }
        return .object(fields)
    }

    init(kind: String, ref: String, image: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.image = image
    }

    init(validated json: NavigatorJSONValue) {
        kind = json["kind"]!.stringValue!
        ref = json["ref"]!.stringValue!
        image = json["image"]?.stringValue
    }
}

struct NavigatorProvenance: Hashable, Sendable {
    var kind: String
    var ref: String
    var rule: String?
    var ruleVersion: String?

    var json: NavigatorJSONValue {
        var fields: [String: NavigatorJSONValue] = ["kind": .string(kind), "ref": .string(ref)]
        if let rule, let ruleVersion {
            fields["rule"] = .string(rule)
            fields["ruleVersion"] = .string(ruleVersion)
        }
        return .object(fields)
    }

    init(kind: String, ref: String, rule: String? = nil, ruleVersion: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.rule = rule
        self.ruleVersion = ruleVersion
    }

    init(validated json: NavigatorJSONValue) {
        kind = json["kind"]!.stringValue!
        ref = json["ref"]!.stringValue!
        rule = json["rule"]?.stringValue
        ruleVersion = json["ruleVersion"]?.stringValue
    }

    /// `rule@ruleVersion` of the first entry naming a rule, else empty (part of the fact id).
    static func ruleKey(_ entries: [NavigatorProvenance]) throws -> String {
        guard let (offset, entry) = entries.enumerated().first(where: { $0.element.rule != nil }) else { return "" }
        guard let rule = entry.rule, let ruleVersion = entry.ruleVersion else {
            throw NavigatorContractError(reasons: ["fact.provenance[\(offset)]: rule and ruleVersion go together"])
        }
        return "\(rule)@\(ruleVersion)"
    }
}

struct NavigatorRefusal: Hashable, Sendable, Error {
    var code: String
    var detail: String
    var retryable: Bool

    init(_ code: String, _ detail: String, retryable: Bool = false) {
        self.code = code
        self.detail = detail
        self.retryable = retryable
    }

    var json: NavigatorJSONValue {
        .object(["code": .string(code), "detail": .string(detail), "retryable": .bool(retryable)])
    }

    init(validated json: NavigatorJSONValue) {
        code = json["code"]!.stringValue!
        detail = json["detail"]!.stringValue!
        retryable = json["retryable"]!.boolValue!
    }
}

struct NavigatorContractError: Error, Equatable, Sendable {
    var reasons: [String]
}

/// The analysis generation a record was produced against: the image it describes, the input key of
/// the analysis it read (`AnalysisInputFingerprint.inputKey`) and the knowledge version of the rules
/// and catalogues that produced it. Optional on every record; v1 records without it stay valid.
struct NavigatorGeneration: Hashable, Codable, Sendable {
    var imageIdentity: String
    var inputKey: String
    var knowledgeVersion: String

    init(imageIdentity: String, inputKey: String, knowledgeVersion: String) {
        self.imageIdentity = imageIdentity
        self.inputKey = inputKey
        self.knowledgeVersion = knowledgeVersion
    }

    var json: NavigatorJSONValue {
        .object([
            "imageIdentity": .string(imageIdentity), "inputKey": .string(inputKey),
            "knowledgeVersion": .string(knowledgeVersion),
        ])
    }

    init(validated json: NavigatorJSONValue) {
        imageIdentity = json["imageIdentity"]!.stringValue!
        inputKey = json["inputKey"]!.stringValue!
        knowledgeVersion = json["knowledgeVersion"]!.stringValue!
    }

    /// Writes the optional `generation` / `dependsOn` keys shared by Fact, FrontierItem and Annotation.
    static func stamp(_ fields: inout [String: NavigatorJSONValue], generation: NavigatorGeneration?, dependsOn: [String]?) {
        if let generation { fields["generation"] = generation.json }
        if let dependsOn { fields["dependsOn"] = .array(dependsOn.map { .string($0) }) }
    }

    /// Reads the optional `dependsOn` key of an already validated record.
    static func dependsOn(_ json: NavigatorJSONValue) -> [String]? {
        json["dependsOn"]?.arrayValue?.map { $0.stringValue! }
    }
}

struct NavigatorFact: Hashable, Sendable {
    var id: String
    var subject: NavigatorSubject
    var predicate: String
    var value: NavigatorJSONValue
    var status: String
    var provenance: [NavigatorProvenance]
    var toolchain: String
    var tier: Int64?
    var derivedFrom: [[String]]?
    /// The analysis generation the fact was produced against (not part of the id).
    var generation: NavigatorGeneration?
    /// Fingerprint facet kinds (`AnalysisFingerprintFacetKind` raw values) the fact was read from; a
    /// reanalysis that changes one of them marks the fact stale (not part of the id).
    var dependsOn: [String]?

    var revert: String { "revert:\(id)" }

    static func id(subject: NavigatorSubject, predicate: String, value: NavigatorJSONValue,
                   provenance: [NavigatorProvenance]) throws -> String {
        try NavigatorJSONCanonical.digest("f", .array([subject.json, .string(predicate), value,
                                                      .string(try NavigatorProvenance.ruleKey(provenance))]))
    }

    /// Builds and validates a fact; the id is derived, never supplied.
    static func make(subject: NavigatorSubject, predicate: String, value: NavigatorJSONValue, status: String,
                     provenance: [NavigatorProvenance], toolchain: String, tier: Int64? = nil,
                     derivedFrom: [[String]]? = nil, generation: NavigatorGeneration? = nil,
                     dependsOn: [String]? = nil) throws -> NavigatorFact {
        let fact = NavigatorFact(
            id: try id(subject: subject, predicate: predicate, value: value, provenance: provenance),
            subject: subject, predicate: predicate, value: value, status: status, provenance: provenance,
            toolchain: toolchain, tier: tier,
            derivedFrom: derivedFrom.map { $0.map { Array(Set($0)).sortedByScalars() } },
            generation: generation, dependsOn: dependsOn.map { $0.uniqueSortedByScalars() })
        let reasons = NavigatorContractValidator.validateFact(fact.json)
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        return fact
    }

    var json: NavigatorJSONValue {
        var fields: [String: NavigatorJSONValue] = [
            "kind": .string("Fact"), "schemaVersion": .int(NavigatorContractVocabulary.schemaVersion), "id": .string(id),
            "subject": subject.json, "predicate": .string(predicate), "value": value, "status": .string(status),
            "provenance": .array(provenance.map(\.json)), "toolchain": .string(toolchain), "revert": .string(revert),
        ]
        if let tier { fields["tier"] = .int(tier) }
        if let derivedFrom { fields["derivedFrom"] = .array(derivedFrom.map { .array($0.map { .string($0) }) }) }
        NavigatorGeneration.stamp(&fields, generation: generation, dependsOn: dependsOn)
        return .object(fields)
    }

    init(json: NavigatorJSONValue) throws {
        let reasons = NavigatorContractValidator.validateFact(json)
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        self.init(validated: json)
    }

    init(validated json: NavigatorJSONValue) {
        id = json["id"]!.stringValue!
        subject = NavigatorSubject(validated: json["subject"]!)
        predicate = json["predicate"]!.stringValue!
        value = json["value"]!
        status = json["status"]!.stringValue!
        provenance = json["provenance"]!.arrayValue!.map(NavigatorProvenance.init(validated:))
        toolchain = json["toolchain"]!.stringValue!
        tier = json["tier"]?.intValue
        derivedFrom = json["derivedFrom"]?.arrayValue?.map { $0.arrayValue!.map { $0.stringValue! } }
        generation = json["generation"].map(NavigatorGeneration.init(validated:))
        dependsOn = NavigatorGeneration.dependsOn(json)
    }

    private init(id: String, subject: NavigatorSubject, predicate: String, value: NavigatorJSONValue, status: String,
                 provenance: [NavigatorProvenance], toolchain: String, tier: Int64?, derivedFrom: [[String]]?,
                 generation: NavigatorGeneration?, dependsOn: [String]?) {
        self.id = id
        self.subject = subject
        self.predicate = predicate
        self.value = value
        self.status = status
        self.provenance = provenance
        self.toolchain = toolchain
        self.tier = tier
        self.derivedFrom = derivedFrom
        self.generation = generation
        self.dependsOn = dependsOn
    }
}

struct NavigatorPrimitiveRef: Hashable, Sendable {
    var name: String
    var preconditions: [String]

    var json: NavigatorJSONValue { .object(["name": .string(name), "preconditions": .array(preconditions.map { .string($0) })]) }
}

struct NavigatorFrontierItem: Hashable, Sendable {
    var id: String
    var subject: NavigatorSubject
    var gap: String
    var detail: String
    var blockedBy: [String]
    var missingEvidence: [String]
    var primitives: [NavigatorPrimitiveRef]
    var cost: [String: Int64]
    var leverage: Int64
    var reason: [NavigatorRefusal]
    var toolchain: String
    var generation: NavigatorGeneration?
    var dependsOn: [String]?

    static func id(subject: NavigatorSubject, gap: String, detail: String) throws -> String {
        try NavigatorJSONCanonical.digest("g", .array([subject.json, .string(gap), .string(detail)]))
    }

    static func make(subject: NavigatorSubject, gap: String, detail: String, toolchain: String, blockedBy: [String] = [],
                     missingEvidence: [String] = [], primitives: [NavigatorPrimitiveRef] = [], cost: [String: Int64] = [:],
                     leverage: Int64 = 0, reason: [NavigatorRefusal] = [], generation: NavigatorGeneration? = nil,
                     dependsOn: [String]? = nil) throws -> NavigatorFrontierItem {
        let item = NavigatorFrontierItem(
            id: try id(subject: subject, gap: gap, detail: detail), subject: subject, gap: gap, detail: detail,
            blockedBy: Array(Set(blockedBy)).sortedByScalars(), missingEvidence: missingEvidence, primitives: primitives,
            cost: cost, leverage: leverage, reason: reason, toolchain: toolchain, generation: generation,
            dependsOn: dependsOn.map { $0.uniqueSortedByScalars() })
        let reasons = NavigatorContractValidator.validateFrontier(item.json)
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        return item
    }

    var json: NavigatorJSONValue {
        var fields: [String: NavigatorJSONValue] = [
            "kind": .string("FrontierItem"), "schemaVersion": .int(NavigatorContractVocabulary.schemaVersion),
            "id": .string(id), "subject": subject.json, "gap": .string(gap), "detail": .string(detail),
            "blockedBy": .array(blockedBy.map { .string($0) }), "missingEvidence": .array(missingEvidence.map { .string($0) }),
            "primitives": .array(primitives.map(\.json)), "cost": .object(cost.mapValues { .int($0) }),
            "leverage": .int(leverage), "reason": .array(reason.map(\.json)), "toolchain": .string(toolchain),
        ]
        NavigatorGeneration.stamp(&fields, generation: generation, dependsOn: dependsOn)
        return .object(fields)
    }

    init(json: NavigatorJSONValue) throws {
        let reasons = NavigatorContractValidator.validateFrontier(json)
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        self.init(validated: json)
    }

    init(validated json: NavigatorJSONValue) {
        id = json["id"]!.stringValue!
        subject = NavigatorSubject(validated: json["subject"]!)
        gap = json["gap"]!.stringValue!
        detail = json["detail"]!.stringValue!
        blockedBy = json["blockedBy"]!.arrayValue!.map { $0.stringValue! }
        missingEvidence = json["missingEvidence"]!.arrayValue!.map { $0.stringValue! }
        primitives = json["primitives"]!.arrayValue!.map {
            NavigatorPrimitiveRef(name: $0["name"]!.stringValue!, preconditions: $0["preconditions"]!.arrayValue!.map { $0.stringValue! })
        }
        cost = json["cost"]!.objectValue!.mapValues { $0.intValue! }
        leverage = json["leverage"]!.intValue!
        reason = json["reason"]!.arrayValue!.map(NavigatorRefusal.init(validated:))
        toolchain = json["toolchain"]!.stringValue!
        generation = json["generation"].map(NavigatorGeneration.init(validated:))
        dependsOn = NavigatorGeneration.dependsOn(json)
    }

    private init(id: String, subject: NavigatorSubject, gap: String, detail: String, blockedBy: [String],
                 missingEvidence: [String], primitives: [NavigatorPrimitiveRef], cost: [String: Int64], leverage: Int64,
                 reason: [NavigatorRefusal], toolchain: String, generation: NavigatorGeneration?, dependsOn: [String]?) {
        self.id = id
        self.subject = subject
        self.gap = gap
        self.detail = detail
        self.blockedBy = blockedBy
        self.missingEvidence = missingEvidence
        self.primitives = primitives
        self.cost = cost
        self.leverage = leverage
        self.reason = reason
        self.toolchain = toolchain
        self.generation = generation
        self.dependsOn = dependsOn
    }
}

struct NavigatorAnnotation: Hashable, Sendable {
    var id: String
    var seq: Int64
    var session: String
    var author: String
    var action: String
    var subject: NavigatorSubject
    var predicate: String
    var value: NavigatorJSONValue
    var cites: [String]
    var rationale: String
    var reverted: Bool
    var generation: NavigatorGeneration?
    var dependsOn: [String]?

    var revert: String { "revert:\(id)" }

    /// The premise handle a derived fact uses to rest on this annotation (`ann:<session>/<seq>`).
    var premise: String { Self.premise(session: session, seq: seq) }

    static func premise(session: String, seq: Int64) -> String { "ann:\(session)/\(seq)" }

    static func id(session: String, seq: Int64, author: String, action: String, subject: NavigatorSubject,
                   predicate: String, value: NavigatorJSONValue, cites: [String]) throws -> String {
        try NavigatorJSONCanonical.digest("a", .array([
            .string(session), .int(seq), .string(author), .string(action), subject.json, .string(predicate), value,
            .array(cites.sortedByScalars().map { .string($0) }),
        ]))
    }

    static func make(session: String, seq: Int64, author: String, action: String, subject: NavigatorSubject,
                     predicate: String, value: NavigatorJSONValue, cites: [String] = [],
                     rationale: String = "", generation: NavigatorGeneration? = nil,
                     dependsOn: [String]? = nil) throws -> NavigatorAnnotation {
        let unique = Array(Set(cites)).sortedByScalars()
        let annotation = NavigatorAnnotation(
            id: try id(session: session, seq: seq, author: author, action: action, subject: subject, predicate: predicate,
                       value: value, cites: unique),
            seq: seq, session: session, author: author, action: action, subject: subject, predicate: predicate,
            value: value, cites: unique, rationale: rationale, reverted: false, generation: generation,
            dependsOn: dependsOn.map { $0.uniqueSortedByScalars() })
        let reasons = NavigatorContractValidator.validateAnnotation(annotation.json)
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        return annotation
    }

    var json: NavigatorJSONValue {
        var fields: [String: NavigatorJSONValue] = [
            "kind": .string("Annotation"), "schemaVersion": .int(NavigatorContractVocabulary.schemaVersion),
            "id": .string(id), "seq": .int(seq), "session": .string(session), "author": .string(author),
            "action": .string(action), "subject": subject.json, "predicate": .string(predicate), "value": value,
            "cites": .array(cites.map { .string($0) }), "rationale": .string(rationale), "reverted": .bool(reverted),
            "revert": .string(revert),
        ]
        NavigatorGeneration.stamp(&fields, generation: generation, dependsOn: dependsOn)
        return .object(fields)
    }

    init(json: NavigatorJSONValue) throws {
        let reasons = NavigatorContractValidator.validateAnnotation(json)
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        self.init(validated: json)
    }

    init(validated json: NavigatorJSONValue) {
        id = json["id"]!.stringValue!
        seq = json["seq"]!.intValue!
        session = json["session"]!.stringValue!
        author = json["author"]!.stringValue!
        action = json["action"]!.stringValue!
        subject = NavigatorSubject(validated: json["subject"]!)
        predicate = json["predicate"]!.stringValue!
        value = json["value"]!
        cites = json["cites"]!.arrayValue!.map { $0.stringValue! }
        rationale = json["rationale"]!.stringValue!
        reverted = json["reverted"]!.boolValue!
        generation = json["generation"].map(NavigatorGeneration.init(validated:))
        dependsOn = NavigatorGeneration.dependsOn(json)
    }

    private init(id: String, seq: Int64, session: String, author: String, action: String, subject: NavigatorSubject,
                 predicate: String, value: NavigatorJSONValue, cites: [String], rationale: String, reverted: Bool,
                 generation: NavigatorGeneration?, dependsOn: [String]?) {
        self.id = id
        self.seq = seq
        self.session = session
        self.author = author
        self.action = action
        self.subject = subject
        self.predicate = predicate
        self.value = value
        self.cites = cites
        self.rationale = rationale
        self.reverted = reverted
        self.generation = generation
        self.dependsOn = dependsOn
    }
}

struct NavigatorPrimitiveResult: Hashable, Sendable {
    var primitive: String
    var primitiveVersion: String
    var subject: NavigatorSubject
    var budget: [String: Int64]
    var facts: [NavigatorFact]
    var frontier: [NavigatorFrontierItem]
    var refusal: NavigatorRefusal?

    var outcome: String { refusal != nil ? "refusal" : (facts.isEmpty ? "narrowed" : "facts") }

    init(primitive: String, primitiveVersion: String, subject: NavigatorSubject, budget: [String: Int64],
         facts: [NavigatorFact] = [], frontier: [NavigatorFrontierItem] = [], refusal: NavigatorRefusal? = nil) {
        self.primitive = primitive
        self.primitiveVersion = primitiveVersion
        self.subject = subject
        self.budget = budget
        self.facts = facts
        self.frontier = frontier
        self.refusal = refusal
    }

    var json: NavigatorJSONValue {
        var fields: [String: NavigatorJSONValue] = [
            "kind": .string("PrimitiveResult"), "schemaVersion": .int(NavigatorContractVocabulary.schemaVersion),
            "primitive": .string(primitive), "primitiveVersion": .string(primitiveVersion), "subject": subject.json,
            "budget": .object(budget.mapValues { .int($0) }), "outcome": .string(outcome),
            "facts": .array(facts.map(\.json)), "frontier": .array(frontier.map(\.json)),
        ]
        if let refusal { fields["refusal"] = refusal.json }
        return .object(fields)
    }

    init(json: NavigatorJSONValue) throws {
        let reasons = NavigatorContractValidator.validateResult(json)
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        primitive = json["primitive"]!.stringValue!
        primitiveVersion = json["primitiveVersion"]!.stringValue!
        subject = NavigatorSubject(validated: json["subject"]!)
        budget = json["budget"]!.objectValue!.mapValues { $0.intValue! }
        facts = json["facts"]!.arrayValue!.map(NavigatorFact.init(validated:))
        frontier = json["frontier"]!.arrayValue!.map(NavigatorFrontierItem.init(validated:))
        refusal = json["refusal"].map(NavigatorRefusal.init(validated:))
    }
}

/// The persisted record kind (`kind: NavigatorEngineState`, schemaVersion 1).
struct NavigatorEngineState: Hashable, Sendable {
    var toolchain: String
    var facts: [NavigatorFact]
    var reverted: [String]
    var frontier: [NavigatorFrontierItem]
    var annotations: [NavigatorAnnotation]

    init(toolchain: String, facts: [NavigatorFact] = [], reverted: [String] = [], frontier: [NavigatorFrontierItem] = [],
         annotations: [NavigatorAnnotation] = []) {
        self.toolchain = toolchain
        self.facts = facts
        self.reverted = Array(Set(reverted)).sortedByScalars()
        self.frontier = frontier
        self.annotations = annotations
    }

    var json: NavigatorJSONValue {
        .object([
            "kind": .string("NavigatorEngineState"), "schemaVersion": .int(NavigatorContractVocabulary.schemaVersion),
            "toolchain": .string(toolchain), "facts": .array(facts.map(\.json)),
            "reverted": .array(reverted.map { .string($0) }), "frontier": .array(frontier.map(\.json)),
            "annotations": .array(annotations.map(\.json)),
        ])
    }

    init(json: NavigatorJSONValue) throws {
        let reasons = NavigatorContractValidator.validateState(json)
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        toolchain = json["toolchain"]!.stringValue!
        facts = json["facts"]!.arrayValue!.map(NavigatorFact.init(validated:))
        reverted = json["reverted"]!.arrayValue!.map { $0.stringValue! }
        frontier = json["frontier"]!.arrayValue!.map(NavigatorFrontierItem.init(validated:))
        annotations = json["annotations"]!.arrayValue!.map(NavigatorAnnotation.init(validated:))
    }
}

extension Array where Element == String {
    /// Exact-scalar de-duplication (a `Set<String>` merges canonically equivalent strings such as
    /// NFC and NFD "é"; the contract keeps them distinct), then code-point order.
    func uniqueSortedByScalars() -> [String] {
        var seen = Set<[UInt8]>()
        return filter { seen.insert([UInt8]($0.utf8)).inserted }.sortedByScalars()
    }

    /// Code-point order, matching Python's `sorted` on `str`.
    func sortedByScalars() -> [String] {
        sorted { $0.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
    }
}
