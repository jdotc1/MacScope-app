import Foundation

public enum Authority: String, Codable, Sendable {
    case authoritative, derived, unknown
}

public struct ProofFact: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let image: String
    public let subject: String
    public let predicate: String
    public let value: JSONValue
    public let authority: Authority
    public let anchors: [String]
    public let parents: [String]
    public let rule: String
    public let unknownReason: String?

    public init(id: String, image: String, subject: String, predicate: String, value: JSONValue,
                authority: Authority, anchors: [String] = [], parents: [String] = [],
                rule: String = "", unknownReason: String? = nil) throws {
        try ImageKey.validate(image)
        guard !id.isEmpty, !subject.isEmpty, !predicate.isEmpty else { throw RecoveryError.invalid("fact identity missing") }
        guard Set(anchors).count == anchors.count, Set(parents).count == parents.count else { throw RecoveryError.invalid("duplicate fact dependency") }
        switch authority {
        case .authoritative:
            guard !anchors.isEmpty, !rule.isEmpty else { throw RecoveryError.invalid("authoritative fact requires direct evidence") }
        case .derived:
            guard !anchors.isEmpty || !parents.isEmpty, !rule.isEmpty else { throw RecoveryError.invalid("derived fact requires dependencies and rule") }
        case .unknown:
            guard let reason = unknownReason, !reason.isEmpty else { throw RecoveryError.invalid("unknown fact requires reason") }
        }
        self.id = id; self.image = image; self.subject = subject; self.predicate = predicate
        self.value = value; self.authority = authority; self.anchors = anchors; self.parents = parents
        self.rule = rule; self.unknownReason = unknownReason
    }
    private enum CodingKeys: String, CodingKey {
        case id, image, subject, predicate, value, authority, anchors, parents, rule
        case unknownReason = "unknown_reason"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), image: c.decode(String.self, forKey: .image),
                      subject: c.decode(String.self, forKey: .subject), predicate: c.decode(String.self, forKey: .predicate),
                      value: c.decode(JSONValue.self, forKey: .value), authority: c.decode(Authority.self, forKey: .authority),
                      anchors: c.decodeIfPresent([String].self, forKey: .anchors) ?? [],
                      parents: c.decodeIfPresent([String].self, forKey: .parents) ?? [],
                      rule: c.decodeIfPresent(String.self, forKey: .rule) ?? "",
                      unknownReason: c.decodeIfPresent(String.self, forKey: .unknownReason))
    }
}

/// In-memory consumer of verified producer facts. It checks identity and graph
/// structure, not the semantic truth of a rule or the cryptographic fact digest.
/// Artifact digest verification belongs at the archive/worker admission boundary.
public struct EvidenceGraph: Sendable {
    public let image: String
    private var anchors: Set<String> = []
    private var facts: [String: ProofFact] = [:]
    private var inactive: Set<String> = []
    private var reverse: [String: Set<String>] = [:]
    public private(set) var journal: [String] = []
    public init(image: String) { self.image = image }

    public mutating func addAnchor(_ id: String, image: String) throws {
        guard image == self.image, !id.isEmpty else { throw RecoveryError.invalid("anchor image mismatch") }
        anchors.insert(id)
    }
    public mutating func add(_ fact: ProofFact) throws {
        guard fact.image == image else { throw RecoveryError.invalid("fact image mismatch") }
        guard !inactive.contains(fact.id) else { throw RecoveryError.stale("retracted fact requires a new producer revision") }
        guard fact.anchors.allSatisfy({ anchors.contains($0) }) else { throw RecoveryError.invalid("missing anchor") }
        guard fact.parents.allSatisfy({ facts[$0] != nil && !inactive.contains($0) }) else { throw RecoveryError.invalid("missing/inactive parent") }
        if let previous = facts[fact.id] {
            guard previous == fact else { throw RecoveryError.invalid("fact ID reused for different content") }
            return
        }
        guard !fact.parents.contains(fact.id) else { throw RecoveryError.invalid("self-dependent fact") }
        facts[fact.id] = fact
        for parent in fact.parents { reverse[parent, default: []].insert(fact.id) }
        journal.append("admitted \(fact.id)")
    }
    public var activeFacts: [ProofFact] {
        facts.values.filter { !inactive.contains($0.id) }.sorted { $0.id < $1.id }
    }
    public func explain(_ id: String, maximum: Int = 100_000) throws -> [ProofFact] {
        guard facts[id] != nil else { throw RecoveryError.invalid("unknown fact") }
        var queue = [id]; var seen: Set<String> = []; var result: [ProofFact] = []
        while let next = queue.popLast() {
            if seen.contains(next) { continue }
            guard result.count < maximum else { throw RecoveryError.budget("proof graph traversal") }
            guard let fact = facts[next] else { throw RecoveryError.invalid("broken proof graph") }
            seen.insert(next); result.append(fact)
            queue.append(contentsOf: fact.parents.sorted().reversed())
        }
        return result
    }
    @discardableResult public mutating func retract(_ id: String, reason: String) throws -> [String] {
        guard facts[id] != nil, !reason.isEmpty else { throw RecoveryError.invalid("retraction requires known fact and reason") }
        var queue = [id]; var removed: Set<String> = []
        while let next = queue.popLast() {
            if removed.contains(next) { continue }
            removed.insert(next)
            queue.append(contentsOf: reverse[next, default: []])
        }
        inactive.formUnion(removed)
        journal.append("retracted \(id): \(reason)")
        return removed.sorted()
    }
}
