// Swift arm64 convention decisions from structured boundary evidence.
// Pure and Foundation-free; consumes the demangler's SwiftSymbolFacts.
// The closed-key JSON codec lives in SwiftConventionCodec.swift.
//
// Sources (swiftlang/swift, swift-6.3-RELEASE):
// self parameter — lib/IRGen/GenCall.cpp:1891–1920 (hasSelfContextParameter) and
// lib/SIL/IR/TypeLowering.cpp:3695–3711 (thin vs thick metatype); error — GenCall.cpp:2098–2125,
// :2173–2178 (typed errors: x21 is a flag only), :2181–2198 and :2353–2360 (async: the error
// travels in the swiftself slot of the resume continuation, never x21).

enum SwiftConvention: String, Equatable {
    case cdecl, swiftcall, swiftasynccall, abstain
}

enum SwiftStorageClaim: String, Equatable {
    case scalarOnly, abstainH03, abstainH07, notClaimed
}

enum SwiftEvidenceTier: String, Equatable {
    case header, derived, closedWorld
}

enum SwiftMetadataMethodSource: String, Equatable {
    case vtable, override, witness
}

/// SwiftMetadataMethod flags decoded from MethodDescriptorFlags (MetadataValues.h:394–399).
struct SwiftMetadataMethodFacts: Equatable {
    var source: SwiftMetadataMethodSource
    var isInstance = false
    var isAsync = false
    var isDynamic = false
    init(source: SwiftMetadataMethodSource, isInstance: Bool = false, isAsync: Bool = false, isDynamic: Bool = false) {
        self.source = source; self.isInstance = isInstance; self.isAsync = isAsync; self.isDynamic = isDynamic
    }
}

struct SwiftRuntimeHelperFacts: Equatable {
    var name: String
    var cc: String            // C_CC | SwiftCC | SwiftAsyncCC | unknown
    var asyncContextIn: String? = nil
    var contextIn: [String] = []
    var errorOut: String? = nil
    init(name: String, cc: String, asyncContextIn: String? = nil, contextIn: [String] = [], errorOut: String? = nil) {
        self.name = name; self.cc = cc; self.asyncContextIn = asyncContextIn; self.contextIn = contextIn; self.errorOut = errorOut
    }
}

/// Body-derived facts (tier derived).
struct SwiftBodyObservations: Equatable {
    var readsX20BeforeWrite = false
    var writesX21 = false
    var readsX22BeforeWrite = false
    init(readsX20BeforeWrite: Bool = false, writesX21: Bool = false, readsX22BeforeWrite: Bool = false) {
        self.readsX20BeforeWrite = readsX20BeforeWrite; self.writesX21 = writesX21; self.readsX22BeforeWrite = readsX22BeforeWrite
    }
}

struct SwiftCallerEvidence: Equatable {
    var testsX21AfterCall = false
    var passesX22 = false
    var passesX20 = false
    init(testsX21AfterCall: Bool = false, passesX22: Bool = false, passesX20: Bool = false) {
        self.testsX21AfterCall = testsX21AfterCall; self.passesX22 = passesX22; self.passesX20 = passesX20
    }
}

struct SwiftBoundaryEvidence: Equatable {
    var symbolFacts: SwiftSymbolFacts? = nil
    var metadataMethod: SwiftMetadataMethodFacts? = nil
    var isAsyncEntryRecord = false
    var runtimeHelper: SwiftRuntimeHelperFacts? = nil
    var isCFacing = false
    var observations: SwiftBodyObservations? = nil
    var callerEvidence: SwiftCallerEvidence? = nil
    init() {}
}

struct SwiftConventionDecision: Equatable {
    static let schemaVersion = 2
    var convention: SwiftConvention = .abstain
    var contextIn: [String] = []
    var errorOut: String? = nil
    var asyncContextIn: String? = nil
    var indirectResult: String? = nil
    var storage: SwiftStorageClaim = .notClaimed
    var tier: SwiftEvidenceTier = .header
    var reasons: [String] = []
    var abstentions: [String] = []
    init() {}
}

enum SwiftConventionReason {
    static let asyncFunctionPointerIsData = "ASYNC_FUNCTION_POINTER_IS_DATA"
    static let symbolNotParsed = "SYMBOL_NOT_PARSED"
    static let runtimeHelperSwiftCC = "RUNTIME_HELPER_SWIFTCC"
    static let runtimeHelperSwiftAsyncCC = "RUNTIME_HELPER_SWIFTASYNCCC"
    static let runtimeHelperC = "RUNTIME_HELPER_C"
    static let runtimeHelperUnknown = "RUNTIME_HELPER_UNKNOWN"
    static let cFacingThunk = "C_FACING_THUNK"
    static let asyncFromSymbol = "ASYNC_FROM_SYMBOL"
    static let asyncFromFunclet = "ASYNC_FROM_FUNCLET"
    static let asyncFromMetadata = "ASYNC_FROM_METADATA"
    static let asyncFromEntryRecord = "ASYNC_FROM_ENTRY_RECORD"
    static let funcletParametersInContext = "FUNCLET_PARAMETERS_IN_CONTEXT"
    static let swiftFunctionEntity = "SWIFT_FUNCTION_ENTITY"
    static let partialApplyForwarder = "PARTIAL_APPLY_FORWARDER"
    static let dispatchThunk = "DISPATCH_THUNK"
    static let reabstractionThunk = "REABSTRACTION_THUNK"
    static let mergedFunction = "MERGED_FUNCTION"
    static let closureContext = "CLOSURE_CONTEXT"
    // self parameter (rule 5): positive statements …
    static let selfClassReference = "SELF_CLASS_REFERENCE"
    static let selfArchetypeOrIndirect = "SELF_ARCHETYPE_OR_INDIRECT"
    static let selfInoutAddress = "SELF_INOUT_ADDRESS"
    static let selfMetatypeThick = "SELF_METATYPE_THICK"
    static let selfMetatypeThin = "SELF_METATYPE_THIN"
    static let contextFromMetadataMethod = "CONTEXT_FROM_METADATA_METHOD"
    static let contextSlotReservedForThrows = "CONTEXT_SLOT_RESERVED_FOR_THROWS"
    // … and abstentions.
    static let selfStorageValueType = "SELF_STORAGE_VALUE_TYPE"
    static let selfMutatingUnknown = "SELF_MUTATING_UNKNOWN"
    static let selfKindUnknown = "SELF_KIND_UNKNOWN"
    // error
    static let errorFromThrows = "ERROR_FROM_THROWS"
    static let asyncErrorInResumeSwiftSelf = "ASYNC_ERROR_IN_RESUME_SWIFTSELF"
    static let typedThrowsErrorStorage = "TYPED_THROWS_ERROR_STORAGE"
    static let noHeaderFacts = "NO_HEADER_FACTS"
    static let observedX20Read = "OBSERVED_X20_READ"
    static let observedX21Write = "OBSERVED_X21_WRITE"
    static let observedX22Read = "OBSERVED_X22_READ"
    static let observedX21Test = "OBSERVED_X21_TEST"
    static let observedX22Pass = "OBSERVED_X22_PASS"
    static let observedX20Pass = "OBSERVED_X20_PASS"
    static let observedConfirmsError = "OBSERVED_CONFIRMS_ERROR"
    static let observedConfirmsAsync = "OBSERVED_CONFIRMS_ASYNC"
    static let contradictionX21TestOnNonThrowing = "CONTRADICTION_X21_TEST_ON_NONTHROWING"
    static let contradictionX22OnSync = "CONTRADICTION_X22_ON_SYNC"
    static let storageGenericH07 = "STORAGE_GENERIC_H07"
    static let storageAggregateH03 = "STORAGE_AGGREGATE_H03"
    static let typedThrowsLayout = "TYPED_THROWS_LAYOUT"
    static let storageUnknownSignature = "STORAGE_UNKNOWN_SIGNATURE"

    static let selfPositive: [String] = [selfClassReference, selfArchetypeOrIndirect, selfInoutAddress, selfMetatypeThick]
    static let selfAbstentions: [String] = [selfStorageValueType, selfMutatingUnknown, selfKindUnknown]
}

enum SwiftConventionAdapter {
    private typealias R = SwiftConventionReason

    /// Rule 5: (registers, reasons, abstentions) for `self`, from GenCall.cpp:1891–1920.
    ///
    /// * indirect self (mutating value type, opaque/generic self) → one pointer, swiftself (x20);
    /// * metatype self → swiftself iff the metatype is thick (TypeLowering.cpp:3695–3711:
    ///   thin only for a non-generic value type);
    /// * class reference, class-bound archetype → swiftself;
    /// * value-type self by value → ordinary parameter storage (type-dependent): abstain.
    static func selfContext(_ facts: SwiftSymbolFacts) -> (registers: [String], reasons: [String], abstentions: [String]) {
        let n = facts.selfNominalKind
        switch facts.selfKind {
        case .none:
            return ([], [], [])
        case .initializingInit, .deallocatingDeinit, .destroyingDeinit:
            // fc / fD / fd exist only on classes; self is the object reference.
            if n == .struct || n == .enum { return ([], [], [R.selfKindUnknown]) }
            return (["x20"], [R.selfClassReference], [])
        case .static, .allocatingInit:
            // self is a metatype: thick (one pointer, swiftself) unless the owning type is a
            // non-generic value type, whose metatype is thin and has no storage at all.
            switch n {
            case .class, .protocol, .archetype: return (["x20"], [R.selfMetatypeThick], [])
            case .struct, .enum:
                if facts.selfTypeIsGeneric { return (["x20"], [R.selfMetatypeThick], []) }
                return ([], [R.selfMetatypeThin], [])
            case .none, .unknown: return ([], [], [R.selfKindUnknown])
            }
        case .instance:
            switch n {
            case .class: return (["x20"], [R.selfClassReference], [])
            case .protocol, .archetype: return (["x20"], [R.selfArchetypeOrIndirect], [])
            case .struct, .enum:
                switch facts.isMutating {
                case .some(true): return (["x20"], [R.selfInoutAddress], [])
                case .some(false): return ([], [], [R.selfStorageValueType])
                case .none: return ([], [], [R.selfMutatingUnknown])
                }
            case .none, .unknown: return ([], [], [R.selfKindUnknown])
            }
        }
    }

    /// Ordered header selection, storage abstentions, then derived confirmation or contradiction.
    static func decide(_ ev: SwiftBoundaryEvidence) -> SwiftConventionDecision {
        let f = ev.symbolFacts
        var reasons: [String] = []
        var abst: [String] = []
        var d = SwiftConventionDecision()

        // Rule 1.
        if let f, f.isAsyncFunctionPointer {
            return abstain([R.asyncFunctionPointerIsData], [R.asyncFunctionPointerIsData])
        }

        // Rule 2.
        if let h = ev.runtimeHelper {
            switch h.cc {
            case "SwiftAsyncCC":
                d.convention = .swiftasynccall
                d.asyncContextIn = h.asyncContextIn ?? "x22"
                d.contextIn = h.contextIn
                d.errorOut = h.errorOut
                reasons.append(R.runtimeHelperSwiftAsyncCC)
            case "SwiftCC":
                d.convention = .swiftcall
                d.contextIn = h.contextIn
                d.errorOut = h.errorOut
                reasons.append(R.runtimeHelperSwiftCC)
            case "C_CC":
                d.convention = .cdecl
                reasons.append(R.runtimeHelperC)
            default:
                return abstain([R.runtimeHelperUnknown], [R.runtimeHelperUnknown])
            }
            d.storage = .scalarOnly
            d.tier = .header
            d.reasons = reasons
            return applyDerived(d, ev, headerThrowing: d.errorOut != nil, headerErrorX21: d.errorOut == "x21",
                                headerAsync: d.convention == .swiftasynccall)
        }

        // Rule 3.
        if ev.isCFacing {
            d.convention = .cdecl
            d.storage = .scalarOnly
            d.tier = .header
            d.reasons = [R.cFacingThunk]
            return applyDerived(d, ev, headerThrowing: false, headerErrorX21: false, headerAsync: false)
        }

        let hasSymbol = f != nil
        let hasMetadata = ev.metadataMethod != nil
        if !hasSymbol && !hasMetadata && !ev.isAsyncEntryRecord {
            // Rule 8.
            let obs = observationCodes(ev)
            let base: [String] = (f == nil && !hasMetadata) ? [R.symbolNotParsed] : []
            return abstain(base + [R.noHeaderFacts] + obs, [R.noHeaderFacts], tier: obs.isEmpty ? .header : .derived)
        }

        let facts = f ?? SwiftSymbolFacts()
        var isAsync = false
        if facts.isAsync { isAsync = true; reasons.append(R.asyncFromSymbol) }
        if facts.funclet != nil { isAsync = true; reasons.append(R.asyncFromFunclet) }
        if let m = ev.metadataMethod, m.isAsync { isAsync = true; reasons.append(R.asyncFromMetadata) }
        if ev.isAsyncEntryRecord { isAsync = true; reasons.append(R.asyncFromEntryRecord) }

        let throwing = facts.isThrowing

        let shapeKnown = facts.isFunction || facts.isPartialApplyForwarder || facts.isDispatchThunk
            || facts.isReabstractionThunk || facts.isMerged || facts.funclet != nil
            || hasMetadata || ev.isAsyncEntryRecord
        if !shapeKnown {
            let obs = observationCodes(ev)
            return abstain(reasons + [R.noHeaderFacts] + obs, [R.noHeaderFacts], tier: obs.isEmpty ? .header : .derived)
        }

        if facts.isPartialApplyForwarder { reasons.append(R.partialApplyForwarder) }
        if facts.isDispatchThunk { reasons.append(R.dispatchThunk) }
        if facts.isReabstractionThunk { reasons.append(R.reabstractionThunk) }
        if facts.isMerged { reasons.append(R.mergedFunction) }
        if facts.isFunction && !(facts.isPartialApplyForwarder || facts.isDispatchThunk
                                 || facts.isReabstractionThunk || facts.isMerged) {
            reasons.append(R.swiftFunctionEntity)
        }

        // Rules 4–7: convention.
        d.convention = isAsync ? .swiftasynccall : .swiftcall
        if isAsync { d.asyncContextIn = "x22" }

        // Context register (rule 5 for self; rule 6 for closure forwarders; funclets take none).
        var selfAbstained = false
        if facts.funclet != nil {
            reasons.append(R.funcletParametersInContext)
        } else if facts.isPartialApplyForwarder {
            // A thick closure always has a context (GenCall.cpp:2085–2087 / :2345–2346).
            d.contextIn = ["x20"]
            reasons.append(R.closureContext)
        } else {
            let s = selfContext(facts)
            if !s.registers.isEmpty {
                d.contextIn = s.registers
                reasons.append(contentsOf: s.reasons)
            } else if hasMetadata {
                // Vtable: class (reference or thick metatype). Witness: lowered against the requirement,
                // whose Self is a type parameter — indirect value self, thick metatype
                // (TypeLowering.cpp:3695–3711, GenCall.cpp:1897–1909). One pointer in x20 either way.
                d.contextIn = ["x20"]
                reasons.append(R.contextFromMetadataMethod)
            } else if !s.abstentions.isEmpty {
                abst.append(contentsOf: s.abstentions)
                selfAbstained = true
            } else {
                reasons.append(contentsOf: s.reasons)      // SELF_METATYPE_THIN, or nothing for a free function
            }
        }

        // Error register (rule 4 for async, rule 5 for sync).
        if throwing {
            if isAsync {
                // The error is handed to the resume continuation in its swiftself slot, never x21
                // (GenCall.cpp:2181–2198, :2353–2360).
                reasons.append(R.asyncErrorInResumeSwiftSelf)
            } else if facts.thrownType != nil {
                // Typed throws: x21 is only a flag (Int8PtrTy, GenCall.cpp:2173–2178); the value is in
                // the combined return registers or a trailing indirect buffer (:2108–2125, :4724–4740).
                abst.append(R.typedThrowsErrorStorage)
            } else {
                d.errorOut = "x21"
                reasons.append(R.errorFromThrows)
            }
            if !isAsync && d.contextIn.isEmpty && !selfAbstained && facts.funclet == nil {
                // needsContext(): a throwing function without a context still reserves the slot
                // (GenCall.cpp:2064–2078). Informational: x20 is part of the signature but unused.
                reasons.append(R.contextSlotReservedForThrows)
            }
        }

        if facts.hasNonScalarReturn { d.indirectResult = "x8" }

        // Storage rules.
        var storage: SwiftStorageClaim = .scalarOnly
        if !hasSymbol {
            storage = .notClaimed
            abst.append(R.storageUnknownSignature)
        }
        if facts.isGeneric {
            storage = .abstainH07
            abst.append(R.storageGenericH07)
        }
        if storage != .abstainH07 && (facts.hasNonScalarParameter || facts.hasNonScalarReturn) {
            storage = .abstainH03
            abst.append(R.storageAggregateH03)
        }
        if storage != .abstainH07, facts.thrownType != nil {
            storage = .abstainH03
            abst.append(R.typedThrowsLayout)
        }
        if storage == .scalarOnly && facts.funclet != nil {
            storage = .notClaimed
        }
        d.storage = storage
        if selfAbstained {
            // When self storage is uncertain the whole decision abstains: a wrong first parameter is worse than none.
            // Metadata-method evidence has already taken precedence above.
            d.convention = .abstain
            d.contextIn = []
            d.errorOut = nil
            d.asyncContextIn = nil
            d.indirectResult = nil
            d.storage = .notClaimed
            reasons.removeAll { $0 == R.errorFromThrows || $0 == R.contextSlotReservedForThrows }
        }
        d.tier = .header
        d.reasons = reasons
        d.abstentions = abst
        return applyDerived(d, ev, headerThrowing: throwing, headerErrorX21: d.errorOut == "x21", headerAsync: isAsync)
    }

    private static func abstain(_ reasons: [String], _ abstentions: [String],
                                tier: SwiftEvidenceTier = .header) -> SwiftConventionDecision {
        var d = SwiftConventionDecision()
        d.convention = .abstain
        d.tier = tier
        d.reasons = reasons
        d.abstentions = abstentions
        d.storage = .notClaimed
        return d
    }

    private static func observationCodes(_ ev: SwiftBoundaryEvidence) -> [String] {
        var codes: [String] = []
        if let o = ev.observations {
            if o.readsX20BeforeWrite { codes.append(R.observedX20Read) }
            if o.writesX21 { codes.append(R.observedX21Write) }
            if o.readsX22BeforeWrite { codes.append(R.observedX22Read) }
        }
        if let c = ev.callerEvidence {
            if c.passesX20 { codes.append(R.observedX20Pass) }
            if c.testsX21AfterCall { codes.append(R.observedX21Test) }
            if c.passesX22 { codes.append(R.observedX22Pass) }
        }
        return codes
    }

    /// Derived evidence may confirm or contradict a header decision, never select one.
    private static func applyDerived(_ input: SwiftConventionDecision, _ ev: SwiftBoundaryEvidence,
                                     headerThrowing: Bool, headerErrorX21: Bool, headerAsync: Bool) -> SwiftConventionDecision {
        var d = input
        let codes = observationCodes(ev)
        if codes.isEmpty { return d }
        d.reasons.append(contentsOf: codes)
        let c = ev.callerEvidence
        var contradictions: [String] = []
        if let c, c.testsX21AfterCall, !headerThrowing { contradictions.append(R.contradictionX21TestOnNonThrowing) }
        if let c, c.passesX22, !headerAsync { contradictions.append(R.contradictionX22OnSync) }
        if !contradictions.isEmpty {
            d.reasons.append(contentsOf: contradictions)
            d.abstentions.append(contentsOf: contradictions)
            d.convention = .abstain
            d.contextIn = []
            d.errorOut = nil
            d.asyncContextIn = nil
            d.indirectResult = nil
            d.storage = .notClaimed
            d.tier = .derived
            return d
        }
        if let c, c.testsX21AfterCall, headerErrorX21 { d.reasons.append(R.observedConfirmsError) }
        if headerAsync, (c?.passesX22 ?? false) || (ev.observations?.readsX22BeforeWrite ?? false) {
            d.reasons.append(R.observedConfirmsAsync)
        }
        return d
    }
}
