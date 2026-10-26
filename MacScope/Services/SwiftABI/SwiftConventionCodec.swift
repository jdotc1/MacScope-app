// Closed-key JSON codec for SwiftBoundaryEvidence / SwiftConventionDecision.
//
// Evidence decoding and schema-2 decision encoding:
// unknown keys and unknown enum values are errors, never dropped. Output keys are
// emitted sorted so the differential driver can compare bytes with the Python side.

import Foundation

enum SwiftConventionCodecError: Error, Equatable, CustomStringConvertible {
    case unknownKeys(where: String, keys: [String])
    case badValue(where: String, value: String)
    case notAnObject(where: String)

    var description: String {
        switch self {
        case .unknownKeys(let w, let k):
            // Python-repr spelling of the key list so the differential compares error lines too.
            return "ValueError: \(w): unknown keys [" + k.map { "'\($0)'" }.joined(separator: ", ") + "]"
        case .badValue(let w, let v): return "ValueError: \(w) \(v)"
        case .notAnObject(let w): return "TypeError: \(w) is not an object"
        }
    }
}

enum SwiftConventionCodec {
    private static let evidenceKeys: Set<String> = ["symbolFacts", "metadataMethod", "isAsyncEntryRecord",
                                                   "runtimeHelper", "isCFacing", "observations", "callerEvidence"]
    private static let symbolKeys: Set<String> = ["isFunction", "isAsync", "isThrowing", "thrownType", "isGeneric",
                                                 "isPartialApplyForwarder", "isDispatchThunk", "isAsyncFunctionPointer",
                                                 "isReabstractionThunk", "isMerged", "funclet", "selfKind", "selfNominalKind",
                                                 "selfTypeIsGeneric", "isMutating", "hasNonScalarParameter", "hasNonScalarReturn"]

    private static func checkKeys(_ obj: [String: Any], _ allowed: Set<String>, _ location: String) throws {
        let extra = Set(obj.keys).subtracting(allowed).sorted()
        if !extra.isEmpty { throw SwiftConventionCodecError.unknownKeys(where: location, keys: extra) }
    }

    private static func bool(_ obj: [String: Any], _ key: String) -> Bool {
        if let b = obj[key] as? Bool { return b }
        if let n = obj[key] as? NSNumber { return n.boolValue }
        return false
    }

    /// Tri-state: missing or null → nil (Python: `sf.get(key)` is None), else the truth value.
    private static func optionalBool(_ obj: [String: Any], _ key: String) -> Bool? {
        guard let v = obj[key], !(v is NSNull) else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    /// Missing and null are optional; a present value must not silently weaken the evidence.
    private static func string(_ obj: [String: Any], _ key: String) throws -> String? {
        guard let value = obj[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else {
            throw SwiftConventionCodecError.badValue(where: key, value: "must be a string or null")
        }
        return text
    }

    private static func object(_ obj: [String: Any], _ key: String) throws -> [String: Any]? {
        guard let v = obj[key], !(v is NSNull) else { return nil }
        guard let o = v as? [String: Any] else { throw SwiftConventionCodecError.notAnObject(where: key) }
        return o
    }

    static func evidence(from obj: [String: Any]) throws -> SwiftBoundaryEvidence {
        try checkKeys(obj, evidenceKeys, "evidence")
        var ev = SwiftBoundaryEvidence()
        if let sf = try object(obj, "symbolFacts") {
            try checkKeys(sf, symbolKeys, "symbolFacts")
            var f = SwiftSymbolFacts()
            f.isFunction = bool(sf, "isFunction")
            f.isAsync = bool(sf, "isAsync")
            f.isThrowing = bool(sf, "isThrowing")
            f.thrownType = try string(sf, "thrownType")
            f.isGeneric = bool(sf, "isGeneric")
            f.isPartialApplyForwarder = bool(sf, "isPartialApplyForwarder")
            f.isDispatchThunk = bool(sf, "isDispatchThunk")
            f.isAsyncFunctionPointer = bool(sf, "isAsyncFunctionPointer")
            f.isReabstractionThunk = bool(sf, "isReabstractionThunk")
            f.isMerged = bool(sf, "isMerged")
            f.selfTypeIsGeneric = bool(sf, "selfTypeIsGeneric")
            f.isMutating = optionalBool(sf, "isMutating")
            f.hasNonScalarParameter = bool(sf, "hasNonScalarParameter")
            f.hasNonScalarReturn = bool(sf, "hasNonScalarReturn")
            if let fl = try object(sf, "funclet") {
                try checkKeys(fl, ["kind", "index"], "funclet")
                let kindText = try string(fl, "kind") ?? ""
                guard let kind = SwiftFuncletKind(rawValue: kindText) else {
                    throw SwiftConventionCodecError.badValue(where: "funclet.kind", value: "'\(kindText)'")
                }
                let index = (fl["index"] as? NSNumber)?.intValue ?? 0
                f.funclet = SwiftFunclet(kind: kind, index: index)
            }
            let selfText = try string(sf, "selfKind") ?? "none"
            guard let selfKind = SwiftSelfKind(rawValue: selfText) else {
                throw SwiftConventionCodecError.badValue(where: "selfKind", value: "'\(selfText)'")
            }
            f.selfKind = selfKind
            let nominalText = try string(sf, "selfNominalKind") ?? "none"
            guard let nominal = SwiftSelfNominalKind(rawValue: nominalText) else {
                throw SwiftConventionCodecError.badValue(where: "selfNominalKind", value: "'\(nominalText)'")
            }
            f.selfNominalKind = nominal
            ev.symbolFacts = f
        }
        if let mm = try object(obj, "metadataMethod") {
            try checkKeys(mm, ["source", "isInstance", "isAsync", "isDynamic"], "metadataMethod")
            let srcText = try string(mm, "source") ?? ""
            guard let src = SwiftMetadataMethodSource(rawValue: srcText) else {
                throw SwiftConventionCodecError.badValue(where: "metadataMethod.source", value: "'\(srcText)'")
            }
            ev.metadataMethod = SwiftMetadataMethodFacts(source: src, isInstance: bool(mm, "isInstance"),
                                                         isAsync: bool(mm, "isAsync"), isDynamic: bool(mm, "isDynamic"))
        }
        if let rh = try object(obj, "runtimeHelper") {
            try checkKeys(rh, ["name", "cc", "asyncContextIn", "contextIn", "errorOut"], "runtimeHelper")
            ev.runtimeHelper = try SwiftRuntimeHelperFacts(name: string(rh, "name") ?? "", cc: string(rh, "cc") ?? "",
                                                       asyncContextIn: string(rh, "asyncContextIn"),
                                                       contextIn: (rh["contextIn"] as? [String]) ?? [],
                                                       errorOut: string(rh, "errorOut"))
        }
        if let ob = try object(obj, "observations") {
            try checkKeys(ob, ["readsX20BeforeWrite", "writesX21", "readsX22BeforeWrite"], "observations")
            ev.observations = SwiftBodyObservations(readsX20BeforeWrite: bool(ob, "readsX20BeforeWrite"),
                                                    writesX21: bool(ob, "writesX21"),
                                                    readsX22BeforeWrite: bool(ob, "readsX22BeforeWrite"))
        }
        if let ce = try object(obj, "callerEvidence") {
            try checkKeys(ce, ["testsX21AfterCall", "passesX22", "passesX20"], "callerEvidence")
            ev.callerEvidence = SwiftCallerEvidence(testsX21AfterCall: bool(ce, "testsX21AfterCall"),
                                                    passesX22: bool(ce, "passesX22"), passesX20: bool(ce, "passesX20"))
        }
        ev.isAsyncEntryRecord = bool(obj, "isAsyncEntryRecord")
        ev.isCFacing = bool(obj, "isCFacing")
        return ev
    }

    static func json(_ d: SwiftConventionDecision) -> [String: Any] {
        return [
            "schemaVersion": SwiftConventionDecision.schemaVersion,
            "convention": d.convention.rawValue,
            "contextIn": d.contextIn,
            "errorOut": d.errorOut ?? NSNull(),
            "asyncContextIn": d.asyncContextIn ?? NSNull(),
            "indirectResult": d.indirectResult ?? NSNull(),
            "storage": d.storage.rawValue,
            "tier": d.tier.rawValue,
            "reasons": d.reasons,
            "abstentions": d.abstentions,
        ]
    }
}
