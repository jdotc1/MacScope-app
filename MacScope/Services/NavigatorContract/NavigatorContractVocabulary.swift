import Foundation

/// Closed vocabularies of contract v1, mirrored from `docs/contracts/navigator-engine/v1/vocabulary.json`
/// (the Linux differential harness checks the two are identical). Append-only within v1; revision 1.1
/// appended four predicates and three gaps (no refusal).
enum NavigatorContractVocabulary {
    static let schemaVersion: Int64 = 1

    static let statuses = ["authoritative", "proven", "derived", "candidate", "unknown"]
    static let subjectKinds = ["image", "address", "range", "function", "type", "metadataRecord", "selector", "viewBody",
                               "protocol", "field"]

    enum ValueKind: String, Sendable { case boolean, string, object }

    struct Predicate: Sendable {
        var value: ValueKind
        var allowed: [String]? = nil
        var multi = false
    }

    static let predicates: [String: Predicate] = [
        "isFunctionStart": Predicate(value: .boolean),
        "hasName": Predicate(value: .string),
        "hasType": Predicate(value: .string),
        "callsTarget": Predicate(value: .string, multi: true),
        "fieldLayout": Predicate(value: .object),
        "selectorOf": Predicate(value: .string),
        "asyncContinuationOf": Predicate(value: .string),
        "viewBodyType": Predicate(value: .string),
        "libraryIdentity": Predicate(value: .object),
        "nominalKind": Predicate(value: .string, allowed: ["class", "struct", "enum", "protocol"]),
        "isGeneric": Predicate(value: .boolean),
        "storedField": Predicate(value: .object, multi: true),
        "enumCase": Predicate(value: .object, multi: true),
        "superclass": Predicate(value: .string),
        "conformsTo": Predicate(value: .string, multi: true),
        "isProtocol": Predicate(value: .boolean),
        "isPrivateOrLocal": Predicate(value: .boolean),
        "isImportedCType": Predicate(value: .boolean),
        // v1.1
        "methodTableEntry": Predicate(value: .object, multi: true),
        "conformanceMethod": Predicate(value: .object, multi: true),
        "metadataAccessorOf": Predicate(value: .string),
        "pointerAuthKey": Predicate(value: .object),
    ]

    static let gaps = [
        "unresolvedIndirectCall", "unboundGenericParameter", "unlinkedAsyncContinuation",
        "unreconstructedViewBody", "unknownType", "unnamedFunction", "unrecoveredStruct",
        "unresolvedObjCSend", "unknownCalleeEffects", "ambiguousLibraryIdentity",
        "unsupportedToolchain", "boundaryUncertain",
        "unresolvedTypeReference", "objcTypeReference", "unresolvedProtocol", "unknownContext",
        "missingFieldDescriptor", "malformedFieldDescriptor", "unresolvedSymbolicReference",
        "unresolvedConformance", "conflictingAnnotations", "staleAnnotation",
        // v1.1
        "conflictingFacts", "budgetExceeded", "producerIncomplete",
    ]

    static let refusals = [
        "budgetExceeded", "cancelled", "preconditionFailed", "unsupportedToolchain", "outOfBounds",
        "malformedInput", "unknownSubject", "unknownFact", "conflictsWithAuthority", "notReversible",
    ]

    static let provenanceKinds = ["loaderRecord", "decodedInstruction", "metadataRecord", "rule", "proofCertificate",
                                  "signatureRecord", "analystAction", "symbolGraph"]
    static let annotationActions = ["rename", "setType", "acceptCandidate", "acceptStructCandidate", "makeProcedure",
                                    "addXref", "setFact"]
    static let annotationAuthors = ["analyst", "navigator"]
    static let budgetKeys = ["instructions", "bytes", "solverSteps", "wallMillis"]

    /// Exact-scalar lookup: Swift `String` equality is canonical equivalence (U+212A KELVIN SIGN
    /// equals "K"), the contract compares scalars.
    static func predicate(named name: String) -> Predicate? {
        guard let spec = predicates[name], predicates.keys.contains(where: { $0.unicodeScalars.elementsEqual(name.unicodeScalars) }) else {
            return nil
        }
        return spec
    }

    /// The vocabulary as `vocabulary.json` spells it (minus its prose `note`), for the parity check.
    static var asJSON: NavigatorJSONValue {
        func strings(_ values: [String]) -> NavigatorJSONValue { .array(values.map { .string($0) }) }
        var predicateObjects: [String: NavigatorJSONValue] = [:]
        for (name, spec) in predicates {
            var fields: [String: NavigatorJSONValue] = ["value": .string(spec.value.rawValue)]
            if let allowed = spec.allowed { fields["enum"] = strings(allowed) }
            if spec.multi { fields["multi"] = .bool(true) }
            predicateObjects[name] = .object(fields)
        }
        return .object([
            "schemaVersion": .int(schemaVersion), "contract": .string("navigator-engine"),
            "statuses": strings(statuses), "subjectKinds": strings(subjectKinds), "predicates": .object(predicateObjects),
            "gaps": strings(gaps), "refusals": strings(refusals), "provenanceKinds": strings(provenanceKinds),
            "annotationActions": strings(annotationActions), "annotationAuthors": strings(annotationAuthors),
        ])
    }
}

extension Array where Element == String {
    /// Membership by exact Unicode scalars rather than canonical equivalence.
    func containsExactly(_ value: String) -> Bool {
        contains { $0.unicodeScalars.elementsEqual(value.unicodeScalars) }
    }
}
