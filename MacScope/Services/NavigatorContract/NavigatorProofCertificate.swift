import Foundation

/// A proof certificate (`docs/contracts/navigator-engine/v1/proof-certificate.md`): the record a
/// `proven` fact cites through a `proofCertificate` provenance entry whose ref is the certificate's
/// `hash`.
///
/// `hash` is `sha256:` followed by the lowercase SHA-256 of the canonical JSON (`NavigatorJSONCanonical`)
/// of every field except `hash` and `budget` (`hashInput`). The hash never covers itself, and it never
/// covers the run's wall time or byte count, so two runs that reach the same verdict from the same
/// premises produce the same hash. The value is built only by `make`, which computes the hash, and by
/// `init(json:)`, which recomputes it and refuses a mismatch.
struct NavigatorProofCertificate: Hashable, Sendable {
    enum Outcome: String, CaseIterable, Hashable, Sendable {
        case proven
        case refuted
        case insufficientEvidence
        case cancelled
        case timeout
    }

    struct Budget: Hashable, Sendable {
        var wallMs: Int64
        var bytesRead: Int64

        var json: NavigatorJSONValue {
            .object(["bytesRead": .int(bytesRead), "wallMs": .int(wallMs)])
        }
    }

    static let hashPrefix = "sha256:"
    static let fieldNames = ["rule", "ruleVersion", "subject", "predicate", "value", "premises", "assumptions",
                             "conclusion", "trustedBase", "outcome", "budget", "hash"]
    /// Fields left out of the hash input: the hash itself, and the run budget, which varies run to run.
    static let unhashedFieldNames = ["budget", "hash"]

    let rule: String
    let ruleVersion: String
    let subject: NavigatorSubject
    let predicate: String
    let value: NavigatorJSONValue
    let premises: [NavigatorProvenance]
    let assumptions: [String]
    let conclusion: String
    let trustedBase: [String]
    let outcome: Outcome
    let budget: Budget
    let hash: String

    /// Builds a certificate and computes its hash; throws `NavigatorContractError` when a field is
    /// outside the contract (empty rule, unknown predicate, value of the wrong type, bad premise).
    static func make(rule: String, ruleVersion: String, subject: NavigatorSubject, predicate: String,
                     value: NavigatorJSONValue, premises: [NavigatorProvenance], assumptions: [String],
                     conclusion: String, trustedBase: [String], outcome: Outcome,
                     budget: Budget) throws -> NavigatorProofCertificate {
        let unhashed = NavigatorProofCertificate(
            rule: rule, ruleVersion: ruleVersion, subject: subject, predicate: predicate, value: value,
            premises: premises, assumptions: assumptions, conclusion: conclusion, trustedBase: trustedBase,
            outcome: outcome, budget: budget, hash: "")
        let reasons = validateBody(unhashed.body, "certificate")
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        let digest = try hash(of: unhashed.hashInput)
        return NavigatorProofCertificate(
            rule: rule, ruleVersion: ruleVersion, subject: subject, predicate: predicate, value: value,
            premises: premises, assumptions: assumptions, conclusion: conclusion, trustedBase: trustedBase,
            outcome: outcome, budget: budget, hash: digest)
    }

    /// Every field except `hash`.
    var body: NavigatorJSONValue {
        .object([
            "rule": .string(rule),
            "ruleVersion": .string(ruleVersion),
            "subject": subject.json,
            "predicate": .string(predicate),
            "value": value,
            "premises": .array(premises.map(\.json)),
            "assumptions": .array(assumptions.map { .string($0) }),
            "conclusion": .string(conclusion),
            "trustedBase": .array(trustedBase.map { .string($0) }),
            "outcome": .string(outcome.rawValue),
            "budget": budget.json,
        ])
    }

    /// Every field except `hash` and `budget`: the exact input of the hash.
    var hashInput: NavigatorJSONValue {
        Self.hashInput(of: body)
    }

    /// `body` plus `hash`.
    var json: NavigatorJSONValue {
        guard case .object(var fields) = body else { return body }
        fields["hash"] = .string(hash)
        return .object(fields)
    }

    /// The provenance entry a fact uses to cite this certificate.
    var reference: NavigatorProvenance {
        NavigatorProvenance(kind: "proofCertificate", ref: hash)
    }

    /// `fields` with `hash` and `budget` removed; a non-object is returned unchanged.
    static func hashInput(of fields: NavigatorJSONValue) -> NavigatorJSONValue {
        guard var object = fields.objectValue else { return fields }
        for key in unhashedFieldNames { object[key] = nil }
        return .object(object)
    }

    /// `sha256:<64 lowercase hex>` of the canonical JSON of `input`. `input` must contain neither
    /// `hash` nor `budget` (pass `hashInput`), so a caller cannot hash a run-dependent value by mistake.
    static func hash(of input: NavigatorJSONValue) throws -> String {
        let present = unhashedFieldNames.filter { input[$0] != nil }
        guard present.isEmpty else {
            throw NavigatorContractError(reasons: present.map { "certificate: hash input must exclude \($0)" })
        }
        let canonical = try NavigatorJSONCanonical.encode(input)
        return hashPrefix + AnalysisFingerprintBuilder.sha256Hex(Data(canonical.utf8))
    }

    /// `rule@ruleVersion`, the key a fact's rule entry carries (`NavigatorProvenance.ruleKey`).
    var ruleKey: String { "\(rule)@\(ruleVersion)" }

    /// True when `fact` names no rule, or names this certificate's `rule@ruleVersion`.
    func isFromRule(of fact: NavigatorFact) -> Bool {
        guard let key = NavigatorContractValidator.ruleKey(of: fact) else { return true }
        return key == ruleKey
    }

    /// True when this certificate concludes exactly `fact`'s claim with outcome `proven`, comes from
    /// the rule the fact's rule entry names (any rule when the fact has no rule entry), and its
    /// stored hash is the recomputed hash of its body.
    func supports(_ fact: NavigatorFact) -> Bool {
        outcome == .proven && subject == fact.subject && predicate == fact.predicate && value == fact.value
            && isFromRule(of: fact) && isIntact
    }

    /// True when `hash` equals the recomputed hash of `hashInput`.
    var isIntact: Bool {
        guard let recomputed = try? Self.hash(of: hashInput) else { return false }
        return recomputed == hash
    }

    /// Parses and validates a certificate; throws `NavigatorContractError` on a missing or unexpected
    /// field, a field outside the contract, or a `hash` that is not the recomputed hash. `budget` is
    /// validated but not hashed, so a certificate whose budget was edited still parses, with that budget.
    init(json: NavigatorJSONValue) throws {
        guard var fields = json.objectValue else { throw NavigatorContractError(reasons: ["certificate: expected object"]) }
        var reasons: [String] = []
        guard let hash = fields["hash"]?.stringValue else {
            throw NavigatorContractError(reasons: ["certificate.hash: expected string"])
        }
        if !NavigatorContractValidator.isCertificateRef(hash) {
            reasons.append("certificate.hash: expected sha256:<64 lowercase hex>")
        }
        fields["hash"] = nil
        let body = NavigatorJSONValue.object(fields)
        reasons += Self.validateBody(body, "certificate")
        guard reasons.isEmpty else { throw NavigatorContractError(reasons: reasons) }
        let recomputed = try Self.hash(of: Self.hashInput(of: body))
        guard recomputed == hash else {
            throw NavigatorContractError(reasons: ["certificate.hash: does not match recomputed \(recomputed)"])
        }
        self.init(
            rule: fields["rule"]!.stringValue!,
            ruleVersion: fields["ruleVersion"]!.stringValue!,
            subject: NavigatorSubject(validated: fields["subject"]!),
            predicate: fields["predicate"]!.stringValue!,
            value: fields["value"]!,
            premises: fields["premises"]!.arrayValue!.map(NavigatorProvenance.init(validated:)),
            assumptions: fields["assumptions"]!.arrayValue!.map { $0.stringValue! },
            conclusion: fields["conclusion"]!.stringValue!,
            trustedBase: fields["trustedBase"]!.arrayValue!.map { $0.stringValue! },
            outcome: Outcome(rawValue: fields["outcome"]!.stringValue!)!,
            budget: Budget(wallMs: fields["budget"]!["wallMs"]!.intValue!,
                           bytesRead: fields["budget"]!["bytesRead"]!.intValue!),
            hash: hash)
    }

    private init(rule: String, ruleVersion: String, subject: NavigatorSubject, predicate: String,
                 value: NavigatorJSONValue, premises: [NavigatorProvenance], assumptions: [String],
                 conclusion: String, trustedBase: [String], outcome: Outcome, budget: Budget, hash: String) {
        self.rule = rule
        self.ruleVersion = ruleVersion
        self.subject = subject
        self.predicate = predicate
        self.value = value
        self.premises = premises
        self.assumptions = assumptions
        self.conclusion = conclusion
        self.trustedBase = trustedBase
        self.outcome = outcome
        self.budget = budget
        self.hash = hash
    }

    /// Structural and vocabulary reasons for a certificate body (all fields but `hash`); empty means valid.
    static func validateBody(_ body: NavigatorJSONValue, _ at: String) -> [String] {
        guard let fields = body.objectValue else { return ["\(at): expected object"] }
        var reasons: [String] = []
        let expected = fieldNames.filter { $0 != "hash" }
        for key in expected where fields[key] == nil { reasons.append("\(at): missing \(key)") }
        for key in NavigatorJSONCanonical.sortedKeys(fields.keys) where !expected.contains(key) {
            reasons.append("\(at): unexpected \(key)")
        }
        guard reasons.isEmpty else { return reasons }
        for key in ["rule", "ruleVersion", "conclusion"] {
            if (fields[key]!.stringValue ?? "").isEmpty { reasons.append("\(at).\(key): expected non-empty string") }
        }
        reasons += NavigatorContractValidator.validateSubject(fields["subject"], "\(at).subject")
        let value = fields["value"]!
        reasons += NavigatorContractValidator.valueReasons(value, "\(at).value")
        if let predicate = fields["predicate"]!.stringValue, NavigatorJSONCanonical.isIdentifier(predicate) {
            reasons += NavigatorContractValidator.predicateValueReasons(predicate, value, "\(at)")
        } else {
            reasons.append("\(at).predicate: expected identifier")
        }
        if let premises = fields["premises"]!.arrayValue {
            for (offset, premise) in premises.enumerated() {
                reasons += NavigatorContractValidator.validateProvenance(premise, "\(at).premises[\(offset)]")
            }
        } else {
            reasons.append("\(at).premises: expected array")
        }
        for key in ["assumptions", "trustedBase"] {
            guard let items = fields[key]!.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
                reasons.append("\(at).\(key): expected array of strings")
                continue
            }
        }
        if Outcome(rawValue: fields["outcome"]!.stringValue ?? "") == nil {
            reasons.append("\(at).outcome: expected proven|refuted|insufficientEvidence|cancelled|timeout")
        }
        if let budget = fields["budget"]!.objectValue {
            for key in ["wallMs", "bytesRead"] {
                guard let number = budget[key]?.intValue, number >= 0 else {
                    reasons.append("\(at).budget.\(key): expected integer >= 0")
                    continue
                }
            }
            for key in NavigatorJSONCanonical.sortedKeys(budget.keys) where key != "wallMs" && key != "bytesRead" {
                reasons.append("\(at).budget: unexpected \(key)")
            }
        } else {
            reasons.append("\(at).budget: expected object")
        }
        return reasons
    }
}

extension NavigatorContractValidator {
    /// Resolution half of the `proven` rule. `validateFact` checks that a `proven` fact cites a
    /// well-formed certificate ref; this checks that one cited certificate resolves through
    /// `certificate` (a lookup by ref), is intact (its hash recomputes), concludes the fact's exact
    /// subject, predicate and value, comes from the rule the fact's rule entry names (any rule when
    /// the fact has no rule entry), and has outcome `proven`. nil when the fact is not `proven` or a
    /// certificate qualifies; otherwise refusal `malformedInput`, with the first of these details that
    /// applies: a certificate from the fact's rule concludes the claim with another outcome; one from
    /// another rule concludes it; `provenWithoutCertificate`.
    static func certificateRefusal(for fact: NavigatorFact,
                                   certificate: (String) -> NavigatorProofCertificate?) -> NavigatorRefusal? {
        guard fact.status == "proven" else { return nil }
        let factRule = ruleKey(of: fact)
        var outcomes: [String] = []
        var otherRules: [String] = []
        for entry in fact.provenance where entry.kind == "proofCertificate" && isCertificateRef(entry.ref) {
            guard let resolved = certificate(entry.ref), resolved.hash == entry.ref, resolved.isIntact,
                  resolved.subject == fact.subject, resolved.predicate == fact.predicate,
                  resolved.value == fact.value else { continue }
            if let factRule, resolved.ruleKey != factRule {
                otherRules.append(resolved.ruleKey)
                continue
            }
            if resolved.outcome == .proven { return nil }
            outcomes.append(resolved.outcome.rawValue)
        }
        if let outcome = outcomes.first {
            return NavigatorRefusal("malformedInput", "proven fact whose proof certificate outcome is \(outcome)")
        }
        if let factRule, let other = otherRules.first {
            return NavigatorRefusal("malformedInput", provenFromOtherRule(certificate: other, fact: factRule))
        }
        return NavigatorRefusal("malformedInput", provenWithoutCertificate)
    }
}
