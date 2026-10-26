import Foundation

/// Record and state validation of contract v1: the JSON Schema's structural rules plus vocabulary
/// membership, id recomputation and the cross-record rules of a state. A line-for-line port of
/// the navigator contract; the differential harness checks that both
/// accept and refuse the same inputs. An empty result means valid.
enum NavigatorContractValidator {
    typealias JSON = NavigatorJSONValue

    /// `reasons` refuse the record; `warnings` are advisory (non-canonical subject refs written before
    /// every producer used `NavigatorSubjectRef`) and never refuse it.
    struct Report: Hashable, Sendable {
        var reasons: [String]
        var warnings: [String]

        var isValid: Bool { reasons.isEmpty }
    }

    static func validateRecord(_ record: JSON) -> [String] {
        switch record["kind"]?.stringValue {
        case "NavigatorEngineState": return validateState(record)
        case "Fact": return validateFact(record, "$")
        case "FrontierItem": return validateFrontier(record, "$")
        case "Annotation": return validateAnnotation(record, "$")
        case "PrimitiveResult": return validateResult(record, "$")
        default: return ["$: unknown record kind"]
        }
    }

    // MARK: - helpers

    private static func keys(_ record: [String: JSON], required: [String], optional: [String], _ at: String) -> [String] {
        var reasons: [String] = []
        for key in required where record[key] == nil { reasons.append("\(at): missing \(key)") }
        let allowed = Set(required + optional)
        for key in record.keys where !allowed.contains(key) {
            reasons.append("\(at): unexpected \(key)")
        }
        return reasons
    }

    private static func string(_ value: JSON?, _ at: String, minLength: Int = 1) -> [String] {
        guard let text = value?.stringValue, text.unicodeScalars.count >= minLength else {
            return ["\(at): expected string of length >= \(minLength)"]
        }
        return []
    }

    private static func integer(_ value: JSON?, _ at: String, minimum: Int64 = 0, maximum: Int64? = nil) -> [String] {
        guard let number = value?.intValue, number >= minimum, maximum.map({ number <= $0 }) ?? true else {
            return ["\(at): expected integer in range"]
        }
        return []
    }

    private static func schemaVersion(_ value: JSON?, _ at: String) -> [String] {
        value?.intValue == NavigatorContractVocabulary.schemaVersion ? [] : ["\(at).schemaVersion: expected 1"]
    }

    static func valueReasons(_ value: JSON, _ at: String) -> [String] {
        switch value {
        case .null, .bool, .int, .string: return []
        case .array(let items):
            for (offset, item) in items.enumerated() {
                let reasons = valueReasons(item, "\(at)[\(offset)]")
                if !reasons.isEmpty { return reasons }
            }
            return []
        case .object(let fields):
            for key in NavigatorJSONCanonical.sortedKeys(fields.keys) {
                guard NavigatorJSONCanonical.isIdentifier(key) else { return ["\(at): object key is not an ASCII identifier"] }
                let reasons = valueReasons(fields[key]!, "\(at).\(key)")
                if !reasons.isEmpty { return reasons }
            }
            return []
        }
    }

    private static func matches(_ text: String, prefix: Character) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 34, scalars[0] == prefix.unicodeScalars.first!, scalars[1] == "-" else { return false }
        return scalars[2...].allSatisfy { (0x30 ... 0x39).contains($0.value) || (0x61 ... 0x66).contains($0.value) }
    }

    static func isFactID(_ text: String) -> Bool { matches(text, prefix: "f") }
    static func isFrontierID(_ text: String) -> Bool { matches(text, prefix: "g") }
    static func isAnnotationID(_ text: String) -> Bool { matches(text, prefix: "a") }

    /// `ann:<session>/<seq>`: a premise naming an accepted annotation (v1.1 `provenanceRefGrammar`).
    /// The session is every scalar between `ann:` and the last `/` (non-empty, no line feed); the
    /// seq is a canonical non-negative decimal. Mirrors `ANNOTATION_PREMISE` in the Python reference.
    static func isAnnotationPremise(_ text: String) -> Bool {
        parseAnnotationPremise(text) != nil
    }

    /// The (session, seq digits) of an `ann:` premise, or nil when the text is not one.
    static func parseAnnotationPremise(_ text: String) -> (session: String, seq: String)? {
        let scalars = Array(text.unicodeScalars)
        let prefix = Array("ann:".unicodeScalars)
        guard scalars.count > prefix.count + 2, Array(scalars[0 ..< prefix.count]) == prefix,
              let slash = scalars.lastIndex(of: "/"), slash > prefix.count else { return nil }
        let session = scalars[prefix.count ..< slash]
        let digits = scalars[(slash + 1)...]
        guard !session.contains("\n"), !digits.isEmpty,
              digits.allSatisfy({ (0x30 ... 0x39).contains($0.value) }),
              digits.count == 1 || digits.first != "0" else { return nil }
        var sessionText = String.UnicodeScalarView()
        sessionText.append(contentsOf: session)
        var digitText = String.UnicodeScalarView()
        digitText.append(contentsOf: digits)
        return (String(sessionText), String(digitText))
    }

    /// A `derivedFrom` member: a fact id or an annotation premise.
    static func isPremise(_ text: String) -> Bool { isFactID(text) || isAnnotationPremise(text) }

    /// Refusal detail for a `proven` fact that cites no resolvable proof certificate.
    static let provenWithoutCertificate = "proven fact without a resolvable proof certificate"

    /// Refusal detail for a `proven` fact whose matching certificates all come from another rule
    /// than the one its rule entry names; both arguments are `rule@ruleVersion`.
    static func provenFromOtherRule(certificate: String, fact: String) -> String {
        "proven fact whose proof certificate is from \(certificate), not \(fact)"
    }

    /// The fact's `rule@ruleVersion` (`NavigatorProvenance.ruleKey`: its first entry naming a rule, the
    /// key its id carries), or nil when no entry names a rule. An entry with a rule and no version
    /// fails `validateFact`; here it counts as no rule.
    static func ruleKey(of fact: NavigatorFact) -> String? {
        guard let key = try? NavigatorProvenance.ruleKey(fact.provenance), !key.isEmpty else { return nil }
        return key
    }

    /// `sha256:` followed by 64 lowercase hex digits: the only `proofCertificate` ref form.
    static func isCertificateRef(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let prefix = Array("sha256:".unicodeScalars)
        guard scalars.count == prefix.count + 64, Array(scalars[0 ..< prefix.count]) == prefix else { return false }
        return scalars[prefix.count...].allSatisfy { (0x30 ... 0x39).contains($0.value) || (0x61 ... 0x66).contains($0.value) }
    }

    private static func idList(_ value: JSON?, _ at: String, minItems: Int = 0, unique: Bool = true,
                               pattern: (String) -> Bool = isFactID) -> [String] {
        guard let items = value?.arrayValue, items.count >= minItems else { return ["\(at): expected array of >= \(minItems) ids"] }
        var reasons: [String] = []
        var seen: [String] = []
        for (offset, item) in items.enumerated() {
            guard let text = item.stringValue, pattern(text) else { reasons.append("\(at)[\(offset)]: bad id"); continue }
            if unique, seen.contains(text) { reasons.append("\(at): duplicate ids") }
            seen.append(text)
        }
        return reasons
    }

    private static func stringArray(_ value: JSON?) -> Bool {
        guard let items = value?.arrayValue else { return false }
        return items.allSatisfy { $0.stringValue != nil }
    }

    /// The optional `generation` object shared by Fact, FrontierItem and Annotation.
    static func validateGeneration(_ value: JSON?, _ at: String) -> [String] {
        guard let fields = value?.objectValue else { return ["\(at): expected object"] }
        let names = ["imageIdentity", "inputKey", "knowledgeVersion"]
        var reasons = keys(fields, required: names, optional: [], at)
        for name in names where fields[name] != nil { reasons += string(fields[name], "\(at).\(name)") }
        return reasons
    }

    /// The optional `dependsOn` list: >= 1 distinct identifiers (fingerprint facet kinds).
    static func validateDependsOn(_ value: JSON?, _ at: String) -> [String] {
        guard let items = value?.arrayValue, !items.isEmpty else { return ["\(at): expected non-empty array"] }
        var reasons: [String] = []
        var seen: [[UInt8]] = []
        for (offset, item) in items.enumerated() {
            guard let text = item.stringValue, NavigatorJSONCanonical.isIdentifier(text) else {
                reasons.append("\(at)[\(offset)]: expected identifier")
                continue
            }
            let key = Array(text.utf8)
            if seen.contains(key) { reasons.append("\(at): duplicate entries") }
            seen.append(key)
        }
        return reasons
    }

    /// Checks the two optional generation keys when present.
    private static func generationKeys(_ fields: [String: JSON], _ at: String) -> [String] {
        var reasons: [String] = []
        if fields["generation"] != nil { reasons += validateGeneration(fields["generation"], "\(at).generation") }
        if fields["dependsOn"] != nil { reasons += validateDependsOn(fields["dependsOn"], "\(at).dependsOn") }
        return reasons
    }

    static func validateSubject(_ value: JSON?, _ at: String = "subject") -> [String] {
        guard let fields = value?.objectValue else { return ["\(at): expected object"] }
        var reasons = keys(fields, required: ["kind", "ref"], optional: ["image"], at)
        if !NavigatorContractVocabulary.subjectKinds.containsExactly(fields["kind"]?.stringValue ?? "\u{0}") {
            reasons.append("\(at).kind: not in vocabulary")
        }
        reasons += string(fields["ref"], "\(at).ref")
        if fields["image"] != nil { reasons += string(fields["image"], "\(at).image") }
        return reasons
    }

    static func validateProvenance(_ value: JSON, _ at: String) -> [String] {
        guard let fields = value.objectValue else { return ["\(at): expected object"] }
        var reasons = keys(fields, required: ["kind", "ref"], optional: ["rule", "ruleVersion"], at)
        if !NavigatorContractVocabulary.provenanceKinds.containsExactly(fields["kind"]?.stringValue ?? "\u{0}") {
            reasons.append("\(at).kind: not in vocabulary")
        }
        reasons += string(fields["ref"], "\(at).ref")
        if (fields["rule"] == nil) != (fields["ruleVersion"] == nil) {
            reasons.append("\(at): rule and ruleVersion go together")
        }
        for key in ["rule", "ruleVersion"] where fields[key] != nil { reasons += string(fields[key], "\(at).\(key)") }
        return reasons
    }

    static func validateBudget(_ value: JSON?, _ at: String) -> [String] {
        guard let fields = value?.objectValue else { return ["\(at): expected object"] }
        var reasons = keys(fields, required: [], optional: NavigatorContractVocabulary.budgetKeys, at)
        for key in NavigatorContractVocabulary.budgetKeys where fields[key] != nil {
            reasons += integer(fields[key], "\(at).\(key)")
        }
        return reasons
    }

    static func validateRefusal(_ value: JSON?, _ at: String = "refusal") -> [String] {
        guard let fields = value?.objectValue else { return ["\(at): expected object"] }
        var reasons = keys(fields, required: ["code", "detail", "retryable"], optional: [], at)
        if !NavigatorContractVocabulary.refusals.containsExactly(fields["code"]?.stringValue ?? "\u{0}") {
            reasons.append("\(at).code: not in vocabulary")
        }
        if fields["detail"]?.stringValue == nil { reasons.append("\(at).detail: expected string") }
        if fields["retryable"]?.boolValue == nil { reasons.append("\(at).retryable: expected boolean") }
        return reasons
    }

    private static func predicateValue(_ predicate: String, _ value: JSON, status: String, _ at: String) -> [String] {
        guard let spec = NavigatorContractVocabulary.predicate(named: predicate) else {
            return ["\(at).predicate: not in vocabulary"]
        }
        if status == "unknown" { return [] }
        var values = [value]
        if status == "candidate", let alternatives = value["alternatives"]?.arrayValue { values = alternatives }
        var reasons: [String] = []
        for item in values {
            let typeMatches: Bool
            switch spec.value {
            case .boolean: typeMatches = item.boolValue != nil
            case .string: typeMatches = item.stringValue != nil
            case .object: typeMatches = item.objectValue != nil
            }
            if !typeMatches {
                reasons.append("\(at).value: \(predicate) expects \(spec.value.rawValue)")
            } else if let allowed = spec.allowed, let text = item.stringValue, !allowed.contains(where: { $0.unicodeScalars.elementsEqual(text.unicodeScalars) }) {
                reasons.append("\(at).value: not allowed for \(predicate)")
            }
        }
        return reasons
    }

    /// `predicateValue` for a settled (non-candidate, non-unknown) claim; used by proof certificates.
    static func predicateValueReasons(_ predicate: String, _ value: JSON, _ at: String) -> [String] {
        predicateValue(predicate, value, status: "proven", at)
    }

    private static func exact(_ value: JSON?, _ expected: String) -> Bool {
        guard let text = value?.stringValue else { return false }
        return text.unicodeScalars.elementsEqual(expected.unicodeScalars)
    }

    // MARK: - records

    static func validateFact(_ record: JSON, _ at: String = "fact") -> [String] {
        guard let fields = record.objectValue else { return ["\(at): expected object"] }
        var reasons = keys(fields, required: ["kind", "schemaVersion", "id", "subject", "predicate", "value", "status",
                                              "provenance", "toolchain", "revert"],
                           optional: ["tier", "derivedFrom", "generation", "dependsOn"], at)
        guard reasons.isEmpty else { return reasons }
        if !exact(fields["kind"], "Fact") { reasons.append("\(at).kind: expected Fact") }
        reasons += schemaVersion(fields["schemaVersion"], at)
        reasons += validateSubject(fields["subject"], "\(at).subject")
        let predicate = fields["predicate"]!.stringValue
        if predicate.map(NavigatorJSONCanonical.isIdentifier) != true { reasons.append("\(at).predicate: expected identifier") }
        let value = fields["value"]!
        reasons += valueReasons(value, "\(at).value")
        let status = fields["status"]!.stringValue ?? "\u{0}"
        if !NavigatorContractVocabulary.statuses.containsExactly(status) { reasons.append("\(at).status: not in vocabulary") }
        var provenance = fields["provenance"]!.arrayValue ?? []
        if provenance.isEmpty {
            reasons.append("\(at).provenance: expected non-empty array")
            provenance = []
        }
        for (offset, entry) in provenance.enumerated() { reasons += validateProvenance(entry, "\(at).provenance[\(offset)]") }
        // The store unions provenance of equal facts, so one fact never lists an entry twice.
        let encodedEntries = provenance.map { (try? NavigatorJSONCanonical.encode($0)).map { Array($0.utf8) } ?? [] }
        if Set(encodedEntries).count != encodedEntries.count { reasons.append("\(at).provenance: duplicate entries") }
        reasons += string(fields["toolchain"], "\(at).toolchain")
        if status == "proven", !provenance.contains(where: { entry in
            exact(entry["kind"], "proofCertificate") && (entry["ref"]?.stringValue).map(isCertificateRef) == true
        }) {
            reasons.append("\(at).provenance: \(provenWithoutCertificate)")
        }
        if status == "derived" || status == "candidate" {
            if fields["tier"] == nil { reasons.append("\(at).tier: required") } else { reasons += integer(fields["tier"], "\(at).tier", minimum: 1, maximum: 3) }
        } else if fields["tier"] != nil {
            reasons.append("\(at).tier: only derived and candidate facts carry a tier")
        }
        if let groups = fields["derivedFrom"] {
            if let items = groups.arrayValue, !items.isEmpty {
                for (offset, group) in items.enumerated() {
                    reasons += idList(group, "\(at).derivedFrom[\(offset)]", minItems: 1, pattern: isPremise)
                }
            } else {
                reasons.append("\(at).derivedFrom: expected non-empty array")
            }
        }
        if status == "derived", fields["derivedFrom"] == nil { reasons.append("\(at).derivedFrom: required for derived") }
        if status == "authoritative", fields["derivedFrom"] != nil { reasons.append("\(at).derivedFrom: authoritative facts are read") }
        if status == "unknown", value != .null { reasons.append("\(at).value: unknown facts carry null") }
        reasons += generationKeys(fields, at)
        if status == "candidate" {
            var ok = false
            if let object = value.objectValue, object.count == 1, let alternatives = object["alternatives"]?.arrayValue,
               alternatives.count >= 2, valueReasons(value, "").isEmpty {
                let encoded = alternatives.compactMap { try? NavigatorJSONCanonical.encode($0) }
                ok = Set(encoded.map { Array($0.unicodeScalars.map(\.value)) }).count == alternatives.count
            }
            if !ok { reasons.append("\(at).value: candidate needs {alternatives: [>= 2 distinct]}") }
        }
        if reasons.isEmpty, let predicate {
            reasons += predicateValue(predicate, value, status: status, at)
            let subject = NavigatorSubject(validated: fields["subject"]!)
            let entries = provenance.map(NavigatorProvenance.init(validated:))
            if let expected = try? NavigatorFact.id(subject: subject, predicate: predicate, value: value, provenance: entries) {
                if !exact(fields["id"], expected) {
                    reasons.append("\(at).id: does not match recomputed \(expected)")
                } else if !exact(fields["revert"], "revert:" + expected) {
                    reasons.append("\(at).revert: must be revert:<id>")
                }
            } else {
                reasons.append("\(at): not canonically encodable")
            }
        }
        return reasons
    }

    static func validateFrontier(_ record: JSON, _ at: String = "frontier") -> [String] {
        guard let fields = record.objectValue else { return ["\(at): expected object"] }
        var reasons = keys(fields, required: ["kind", "schemaVersion", "id", "subject", "gap", "detail", "blockedBy",
                                              "missingEvidence", "primitives", "cost", "leverage", "reason", "toolchain"],
                           optional: ["generation", "dependsOn"], at)
        guard reasons.isEmpty else { return reasons }
        if !exact(fields["kind"], "FrontierItem") { reasons.append("\(at).kind: expected FrontierItem") }
        reasons += schemaVersion(fields["schemaVersion"], at)
        reasons += validateSubject(fields["subject"], "\(at).subject")
        if !NavigatorContractVocabulary.gaps.containsExactly(fields["gap"]!.stringValue ?? "\u{0}") { reasons.append("\(at).gap: not in vocabulary") }
        if fields["detail"]!.stringValue == nil { reasons.append("\(at).detail: expected string") }
        reasons += idList(fields["blockedBy"], "\(at).blockedBy")
        if !stringArray(fields["missingEvidence"]) { reasons.append("\(at).missingEvidence: expected array of strings") }
        if let primitives = fields["primitives"]!.arrayValue {
            for (offset, primitive) in primitives.enumerated() {
                let where_ = "\(at).primitives[\(offset)]"
                guard let object = primitive.objectValue else { reasons.append("\(where_): expected object"); continue }
                reasons += keys(object, required: ["name", "preconditions"], optional: [], where_)
                reasons += string(object["name"], "\(where_).name")
                if !stringArray(object["preconditions"]) { reasons.append("\(where_).preconditions: expected array of strings") }
            }
        } else {
            reasons.append("\(at).primitives: expected array")
        }
        reasons += validateBudget(fields["cost"], "\(at).cost")
        reasons += integer(fields["leverage"], "\(at).leverage")
        if let items = fields["reason"]!.arrayValue {
            for (offset, item) in items.enumerated() { reasons += validateRefusal(item, "\(at).reason[\(offset)]") }
        } else {
            reasons.append("\(at).reason: expected array")
        }
        reasons += string(fields["toolchain"], "\(at).toolchain")
        reasons += generationKeys(fields, at)
        if reasons.isEmpty {
            let subject = NavigatorSubject(validated: fields["subject"]!)
            let expected = try? NavigatorFrontierItem.id(subject: subject, gap: fields["gap"]!.stringValue!, detail: fields["detail"]!.stringValue!)
            if expected == nil || !exact(fields["id"], expected!) { reasons.append("\(at).id: does not match recomputed id") }
        }
        return reasons
    }

    static func validateAnnotation(_ record: JSON, _ at: String = "annotation") -> [String] {
        guard let fields = record.objectValue else { return ["\(at): expected object"] }
        var reasons = keys(fields, required: ["kind", "schemaVersion", "id", "seq", "session", "author", "action", "subject",
                                              "predicate", "value", "cites", "rationale", "reverted", "revert"],
                           optional: ["generation", "dependsOn"], at)
        guard reasons.isEmpty else { return reasons }
        if !exact(fields["kind"], "Annotation") { reasons.append("\(at).kind: expected Annotation") }
        reasons += schemaVersion(fields["schemaVersion"], at)
        reasons += integer(fields["seq"], "\(at).seq")
        reasons += string(fields["session"], "\(at).session")
        let author = fields["author"]!.stringValue ?? "\u{0}"
        if !NavigatorContractVocabulary.annotationAuthors.containsExactly(author) { reasons.append("\(at).author: not in vocabulary") }
        if !NavigatorContractVocabulary.annotationActions.containsExactly(fields["action"]!.stringValue ?? "\u{0}") {
            reasons.append("\(at).action: not in vocabulary")
        }
        reasons += validateSubject(fields["subject"], "\(at).subject")
        let predicate = fields["predicate"]!.stringValue
        if predicate.flatMap(NavigatorContractVocabulary.predicate(named:)) == nil
            || !(predicate.map(NavigatorJSONCanonical.isIdentifier) ?? false) {
            reasons.append("\(at).predicate: not in vocabulary")
        }
        let value = fields["value"]!
        reasons += valueReasons(value, "\(at).value")
        let navigator = author == "navigator"
        reasons += idList(fields["cites"], "\(at).cites", minItems: navigator ? 1 : 0)
        let rationale = fields["rationale"]!.stringValue
        if rationale == nil || (navigator && rationale!.isEmpty) { reasons.append("\(at).rationale: navigator annotations state a rationale") }
        if fields["reverted"]!.boolValue == nil { reasons.append("\(at).reverted: expected boolean") }
        reasons += generationKeys(fields, at)
        if reasons.isEmpty, let predicate {
            reasons += predicateValue(predicate, value, status: "authoritative", at)
            let cites = fields["cites"]!.arrayValue!.map { $0.stringValue! }
            let expected = try? NavigatorAnnotation.id(
                session: fields["session"]!.stringValue!, seq: fields["seq"]!.intValue!, author: author,
                action: fields["action"]!.stringValue!, subject: NavigatorSubject(validated: fields["subject"]!),
                predicate: predicate, value: value, cites: cites)
            if expected == nil || !exact(fields["id"], expected!) {
                reasons.append("\(at).id: does not match recomputed id")
            } else if !exact(fields["revert"], "revert:" + expected!) {
                reasons.append("\(at).revert: must be revert:<id>")
            }
        }
        return reasons
    }

    static func validateResult(_ record: JSON, _ at: String = "result") -> [String] {
        guard let fields = record.objectValue else { return ["\(at): expected object"] }
        var reasons = keys(fields, required: ["kind", "schemaVersion", "primitive", "primitiveVersion", "subject", "budget",
                                              "outcome", "facts", "frontier"],
                           optional: ["refusal"], at)
        guard reasons.isEmpty else { return reasons }
        if !exact(fields["kind"], "PrimitiveResult") { reasons.append("\(at).kind: expected PrimitiveResult") }
        reasons += schemaVersion(fields["schemaVersion"], at)
        reasons += string(fields["primitive"], "\(at).primitive")
        reasons += string(fields["primitiveVersion"], "\(at).primitiveVersion")
        reasons += validateSubject(fields["subject"], "\(at).subject")
        reasons += validateBudget(fields["budget"], "\(at).budget")
        let outcome = fields["outcome"]!.stringValue ?? "\u{0}"
        if !["facts", "narrowed", "refusal"].contains(outcome) { reasons.append("\(at).outcome: not facts|narrowed|refusal") }
        guard let facts = fields["facts"]!.arrayValue, let frontier = fields["frontier"]!.arrayValue else {
            return reasons + ["\(at): facts and frontier are arrays"]
        }
        for (offset, fact) in facts.enumerated() { reasons += validateFact(fact, "\(at).facts[\(offset)]") }
        for (offset, item) in frontier.enumerated() { reasons += validateFrontier(item, "\(at).frontier[\(offset)]") }
        if outcome == "refusal" {
            if fields["refusal"] == nil { reasons.append("\(at).refusal: required") } else { reasons += validateRefusal(fields["refusal"], "\(at).refusal") }
            if !facts.isEmpty { reasons.append("\(at).facts: a refusal carries no facts") }
        } else if fields["refusal"] != nil {
            reasons.append("\(at).refusal: only for outcome refusal")
        }
        if outcome == "facts", facts.isEmpty { reasons.append("\(at).facts: outcome facts needs at least one fact") }
        if outcome == "narrowed", frontier.isEmpty { reasons.append("\(at).frontier: outcome narrowed needs at least one item") }
        return reasons
    }

    // MARK: - state

    static func validateState(_ state: JSON) -> [String] {
        guard let fields = state.objectValue else { return ["state: expected object"] }
        var reasons = keys(fields, required: ["kind", "schemaVersion", "toolchain", "facts", "reverted", "frontier", "annotations"],
                           optional: [], "state")
        guard reasons.isEmpty else { return reasons }
        if !exact(fields["kind"], "NavigatorEngineState") { reasons.append("state.kind: expected NavigatorEngineState") }
        reasons += schemaVersion(fields["schemaVersion"], "state")
        reasons += string(fields["toolchain"], "state.toolchain")
        for name in ["facts", "reverted", "frontier", "annotations"] where fields[name]!.arrayValue == nil {
            return reasons + ["state.\(name): expected array"]
        }
        reasons += idList(fields["reverted"], "state.reverted")
        let factValues = fields["facts"]!.arrayValue!
        for (offset, fact) in factValues.enumerated() { reasons += validateFact(fact, "state.facts[\(offset)]") }
        for (offset, item) in fields["frontier"]!.arrayValue!.enumerated() { reasons += validateFrontier(item, "state.frontier[\(offset)]") }
        for (offset, annotation) in fields["annotations"]!.arrayValue!.enumerated() {
            reasons += validateAnnotation(annotation, "state.annotations[\(offset)]")
        }
        guard reasons.isEmpty else { return reasons }
        var facts: [String: NavigatorFact] = [:]
        for value in factValues {
            let fact = NavigatorFact(validated: value)
            if facts[fact.id] != nil { reasons.append("state: duplicate fact \(fact.id)") }
            facts[fact.id] = fact
        }
        for value in factValues {
            let fact = NavigatorFact(validated: value)
            // An absent premise makes that derivation dead (README §4), not the state invalid.
            for parent in (fact.derivedFrom ?? []).joined() {
                if let premise = facts[parent], fact.status == "derived",
                   !["authoritative", "proven", "derived"].contains(premise.status) {
                    reasons.append("state: derived \(fact.id) rests on \(premise.status) \(parent)")
                }
            }
        }
        for target in fields["reverted"]!.arrayValue!.map({ $0.stringValue! }) {
            if let fact = facts[target] {
                if fact.status == "authoritative" { reasons.append("state: authoritative \(target) cannot be reverted") }
            } else {
                reasons.append("state: reverted \(target) is not a persisted fact")
            }
        }
        if hasCycle(facts) { reasons.append("state: derivation cycle") }
        var frontierIDs = Set<String>()
        for value in fields["frontier"]!.arrayValue! {
            let item = NavigatorFrontierItem(validated: value)
            if !frontierIDs.insert(item.id).inserted { reasons.append("state: duplicate frontier item \(item.id)") }
            for blocker in item.blockedBy where facts[blocker] == nil { reasons.append("state: \(item.id) blocked by missing \(blocker)") }
        }
        var annotationIDs = Set<String>()
        for value in fields["annotations"]!.arrayValue! {
            let annotation = NavigatorAnnotation(validated: value)
            // An absent citation makes the annotation stale, not the state invalid.
            if !annotationIDs.insert(annotation.id).inserted { reasons.append("state: duplicate annotation \(annotation.id)") }
        }
        return reasons
    }

    static func hasCycle(_ facts: [String: NavigatorFact]) -> Bool {
        var colour: [String: Int] = [:]  // 1 grey, 2 black
        func parents(_ id: String) -> [String] {
            Array(Set((facts[id]?.derivedFrom ?? []).joined().filter { facts[$0] != nil })).sortedByScalars()
        }
        for root in facts.keys.sorted() where colour[root] == nil {
            var stack: [(String, [String], Int)] = [(root, parents(root), 0)]
            colour[root] = 1
            while !stack.isEmpty {
                let (node, children, next) = stack[stack.count - 1]
                if next == children.count {
                    colour[node] = 2
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].2 += 1
                let child = children[next]
                if colour[child] == 1 { return true }
                if colour[child] == nil {
                    colour[child] = 1
                    stack.append((child, parents(child), 0))
                }
            }
        }
        return false
    }
}
