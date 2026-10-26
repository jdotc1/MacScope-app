import Foundation

// Function-local SSA, stack and call-frame facts shared by the lifting helpers.
// Module-internal implementation records; no persisted or public wire authority.
enum BuilderComparisonFlagsKind {
    case subtraction
    case logicalResult
}

struct BuilderComparison {
    // Item338 logical authority; arithmetic certificates remain independent.
    var nativeSignedWordLogical: NativeSignedWordLogicalCertificate? = nil
    var left: MacIRValue
    var right: MacIRValue
    var sourceAddress: UInt64?
    var flagsKind: BuilderComparisonFlagsKind = .subtraction
    // Retain explicit CMN provenance; a CMP of a negative value is not an addition.
    var cmnAddend: MacIRValue? = nil
    var cmnWidth: Int? = nil
    // Raw operand provenance for compound eligibility; zero registers are not immediates.
    var cmnAddendWasImmediate = false
    // Minted only for an exact native unshifted CMP Wn,#imm source word.
    // Other flag producers, including ADDS/CMN, retain nil.
    var nativeSignedWordCMPSource: MacIRSourceSpan? = nil
}

/// A27: the reaching NZCV definition of one consumer row is a flags phi whose
/// every incoming edge carries a recorded comparison (design s3 :207).
struct CompoundChain: Hashable {
    var compare: UInt64
    var conditionalCompare: UInt64
}

struct FlagsPhiContext {
    var blockAddress: UInt64
    var rowAddress: UInt64
    var incomings: [(predecessorAddress: UInt64, comparison: BuilderComparison)]
}

struct PendingConditionalCompare {
    var nativeSignedWordConditionalSource: MacIRSourceSpan? = nil
    var mnemonic: String
    var left: MacIRValue
    var right: MacIRValue
    var nzcv: UInt8
    var guardSuffix: String
    var firstComparison: BuilderComparison
    var sourceAddress: UInt64
    // Exact executed-instruction view, never inferred from a lowered value or ABI type.
    var ccmnWidth: Int? = nil
    var ccmnAddendWasImmediate = false
}

struct NativeSignedWordLogicalCertificate {
    let source: MacIRSourceSpan
    let result: MacIRValue
    let originalOperation: MacIROperation
    let width: Int
    let writesRegister: Bool
    let replacementProducer: MacIROperation?

    init(source: MacIRSourceSpan, result: MacIRValue, originalOperation: MacIROperation,
         width: Int = 32, writesRegister: Bool = false, replacementProducer: MacIROperation? = nil) {
        self.source = source
        self.result = result
        self.originalOperation = originalOperation
        self.width = width
        self.writesRegister = writesRegister
        self.replacementProducer = replacementProducer
    }
}

struct NativeSignedWordLogicalPair {
    let producerSource: MacIRSourceSpan
    let originalProducer: MacIROperation
    let replacementProducer: MacIROperation
    let consumerSource: MacIRSourceSpan
    var originalConsumer: MacIROperation
    var replacementConsumer: MacIROperation
}

struct IntegerRegisterDefinition {
    var value: MacIRValue
    var width: Int
    var isJoinedDefinition = false
    /// A join creates an SSA value, not an instruction-written ABI producer.
    /// Only x0 joins use this tag; ordinary x0/w0 writes retain the default.
    var isSyntheticReturnPhi = false
}

enum StackSlotCarrierKind: Equatable {
    case integer
    case scalarFP
    case vector
}

struct StackSlotValueFact {
    var value: MacIRValue
    var byteWidth: Int
    var carrierKind: StackSlotCarrierKind
}

/// A one-instruction, SSA-exact quotient fact. Never propagated across control flow
/// or intervening instructions; used only for the adjacent DIV/MSUB remainder idiom.
struct BuilderDivision {
    let quotient: MacIRValue
    let dividend: MacIRValue
    let divisor: MacIRValue
    let width: Int
    let signed: Bool
    let sourceAddress: UInt64
}

struct BuilderState {
    /// Actual caller writes since entry or the last returning call. Incoming
    /// parameters and synthetic CFG definitions do not construct arguments.
    var constructedCallArgumentGPRs: Set<Int> = []

    var ssa: MacIRSSAState?
    // row-local exact form + complete numeric-ancestry check. A phi
    // remains a value, never an instruction/return producer. Legacy stays false.
    var ssaExactNumericInputsAvailable = false
    var ssaReturnProducerProof: Bool?
    var ssaReturnRefusal: String?
    // Enabled only for whole-function fixed-Q buffer admission.
    var permitsNEONBufferCarrier = false
    /// General region only: B/H/S/D views share the vN carrier (see neonBufferCarrier).
    var permitsNEONScalarViewCarrier = false
    // Disjoint from buffer memory; only the exact memory-free bit-view route.
    var permitsNEONBitViewCarrier = false
    var remainderFoldingAllowed = false
    var lastDivision: BuilderDivision?
    var pendingNativeLogicalPair: NativeSignedWordLogicalPair?
    var parameters: [MacIRFunctionParameter] = []
    var authoritativeReturnLocation: DarwinARM64RichReturnLocation?
    var authoritativeReturnType: String?
    var callerReturnWidth: MacIRCallerReturnEvidence.Width?
    // Immutable function input for complete return-producer analysis.
    // This context alone grants no return authority.
    var returnProducerSources: [MacIRSourceSpan] = []
    var returnProducerEntryAddress: UInt64?
    var signedBitfieldFunctionName: String?
    let memoizedReturnProducerProof: (() -> Bool) -> Bool = {
        let cache = ReturnProducerProofCache()
        return { compute in
            if let result = cache.result { return result }
            let result = compute()
            cache.result = result
            return result
        }
    }()
    var authoredCallSignaturesByTarget: [String: FunctionSignatureOverride] = [:]
    var directCallVoidResultTargets: [String: FunctionSignatureOverride] = [:]
    var machineCallUsage: MacIRMachineCallUsage? = nil
    var machineUsageContext: MacIRMachineUsageContext? = nil
    var richTypeResolver = TypeAtlasDarwinARM64LayoutResolver()
    var registerVersions: [String: Int] = [:]
    var registerVersionFloor = 0
    var currentIntegerDefinitionByIndex: [Int: IntegerRegisterDefinition] = [:]
    /// Completed x0 phi dependencies with at least one real x0/w0 write.
    /// Value-semantic snapshots never mutate another block's outgoing state.
    var resolvedX0PhiReturnProducers: Set<MacIRValue> = []
    /// Exact scalar-FP register views whose latest definition is a proven
    /// entry-stack argument. Unlike x/w, d/s aliases are not projected.
    var currentEntryStackArgumentByScalarFPRegister: [String: MacIRValue] = [:]
    /// Distinguishes a stack location proven by this function's body from a
    /// declaration-only location that arrived pre-bound in metadata.
    var bodyProvenEntryStackBindings: Set<MacIRParameterBindingID> = []
    var stackSlotValues: [Int64: StackSlotValueFact] = [:]
    /// DP04 A3: the typed memory operand of the row being lowered (see
    /// `MacIRBuilder.typedMemoryOperand(of:)`); nil keeps the text path.
    var currentTypedMemory: InstructionOperands.Memory?
    /// The row being lifted (DP04 B2 maps locals to frame regions through it).
    var currentRowAddress: UInt64?
    var localVariablesByOffset: [Int64: MacIRLocalVariable] = [:]
    var registerNameBindingsByValue: [MacIRValue: MacIRNameBinding] = [:]
    var registerNameBindingOrder: [MacIRValue] = []
    var nextRegisterTemporaryIndex = 0
    var stackBaseOffsets: [String: Int64] = [:]
    // Explicit SP writeback produces an SSA address, not a legacy frame-relative slot.
    var hasExplicitStackWriteback = false
    var stackDepth: Int64 = 0
    var maxStackDepth: Int64 = 0
    var stackDisplacement: Int64 = 0
    var maxStackDisplacement: Int64 = 0
    var hasUnknownStackPointerAdjustment = false
    /// True only while SP is still proven to be the function-entry SP. A later
    /// numeric depth of zero does not re-establish that provenance.
    var entrySPIsExact = true
    var callTargets: [String] = []
    var callSignaturesByTarget: [String: MacIRCallSignature] = [:]
    var valueTypeHints: [MacIRValue: String] = [:]
    var latestABIResultValue: MacIRValue?
    var hasUnmodeledABIResultWrite = false
    var unavailableRegisterValues: Set<String> = []
    /// Exact noninteger views made unavailable by a returning-call boundary.
    /// Integer reads use the physical x/w tombstone seam instead. Keeping this
    /// separate avoids broadening legacy unmodeled-FP-write behavior outside calls.
    var callUnavailableRegisterValues: Set<String> = []
    /// A returning call preserves only the low 64 bits of v8-v15. The region
    /// carrier is 128 bits, so a subsequent whole-vector read must abstain.
    var regionUpperVectorUnavailable: Set<String> = []
    /// The view width (bits) each SIMD register was last written at, and, for a call's
    /// scalar SIMD result, the bits the ABI defines: a D0 result is not a defined V0 (#661).
    var vectorViewWidthByIndex: [Int: Int] = [:]
    var callResultVectorWidth: [Int: Int] = [:]
    /// Scalar d/s views shadowed by a definite q/v write. WS-15 consults this
    /// evidence only while capturing call inputs; general reads and return
    /// inference remain on their frozen pre-wave behavior.
    var vectorScalarCallUnavailableRegisterValues: Set<String> = []
    var returnValue: MacIRValue?
    var returnType: String?
    var shouldInferVoidReturn = false
    var lastComparison: BuilderComparison?
    var lastAdjacentComparison: BuilderComparison?
    var pendingConditionalCompare: PendingConditionalCompare?
    var sawConditionalCompareSinceComparison = false
    /// A27 (SSA only): set per row by the SSA driver, consumed by flag readers.
    var flagsPhiContext: FlagsPhiContext?
    /// A27 (SSA only): boolean phis created for flag consumers in this block.
    var ssaFlagPhis: [MacIRPhi] = []
    var ssaFlagPhiComparisons: Set<UInt64> = []
    var ssaCompoundChains: [CompoundChain] = []
    /// Selref-slot virtual address -> resolved selector name. Empty for every
    /// existing call site; all selector bookkeeping below is gated on this.
    var objcSelectors: [UInt64: String] = [:]
    /// Dispatch `br` address -> the SSA selector value snapshotted right after
    /// its proven defining instruction. Empty unless a jump-table switch with a
    /// proven selector was recovered.
    var provenSwitchSelectors: [UInt64: MacIRValue] = [:]
    /// Register name -> the absolute page base most recently materialized into it
    /// by an `adrp` (or propagated through an immediate `add`). Used only to
    /// reconstruct a selref slot address; cleared on every other write to the
    /// register, mirroring `clearStackBaseOffset`, so a stale page base can never
    /// be misread.
    var adrpPageBaseByRegister: [String: UInt64] = [:]
    /// SSA value -> validated selector provenance recorded at the selref `ldr`
    /// site. The exact selref address remains attached to the call argument for
    /// auditing; an intervening register write creates a new value with no entry.
    var selectorEvidenceByValue: [MacIRValue: MacIRCallSelectorEvidence] = [:]
    /// Register name -> the exact immediate value most recently materialized by a
    /// `mov`/`movz`/folded-`movk` chain. Cleared on every write to that register
    /// (and its x/w width alias) so `movk` only folds when the kept bits are known.
    var materializedImmediateByRegister: [String: UInt64] = [:]
    /// HOP-5c: constant strings by address. Empty for every caller that does not supply them.
    var constantStrings: [UInt64: MacIRConstantString] = [:]
    /// SSA value -> the constant-string address it was materialized from (`adrp`+`add`, `adr`,
    /// or a register copy of one). A later write creates a new value with no entry.
    var constantStringAddressByValue: [MacIRValue: UInt64] = [:]
    /// GPR index -> byte offset from the CURRENT SP that register holds (`mov xN, sp`,
    /// `add xN, sp, #imm`). Call-capture only: it never changes lifted IR. Cleared on any
    /// write to that register, on any SP write, and at every call boundary.
    var stackPointerAliasOffsetByGPR: [Int: Int64] = [:]
    /// Exact stores into the outgoing argument area (offset from the current SP) since the
    /// last call boundary. Call-capture only (like `vectorScalarCallUnavailableRegisterValues`);
    /// the frozen `stackSlotValues` lattice and its reload folding are untouched.
    var outgoingCallStackStores: [Int64: StackSlotValueFact] = [:]

    var resolvesObjCSelectors: Bool { !objcSelectors.isEmpty }
    var resolvesConstantStrings: Bool { !constantStrings.isEmpty }
    var tracksAdrpPageBases: Bool { resolvesObjCSelectors || resolvesConstantStrings }

    var argumentBitWidths: [MacIRParameterBindingID: Int] {
        let groups = Dictionary(grouping: parameters.compactMap { parameter in
            parameter.bindingID.map { ($0, parameter.abiLocation) }
        }, by: \.0)
        return groups.compactMapValues { entries in
            guard entries.count == 1 else { return nil }
            switch entries[0].1 {
            case let .gpr(_, carrierWidth):
                return carrierWidth
            case let .simd(_, scalarWidth):
                return scalarWidth
            case let .entryStack(_, size, _):
                return size * 8
            case .unbound:
                return nil
            }
        }
    }

    /// Records the absolute page base an `adrp` placed into `register`. Called
    /// only when selector resolution is active.
    mutating func recordAdrpPageBase(_ pageBase: UInt64, for register: String) {
        adrpPageBaseByRegister[register.lowercased()] = pageBase
    }

    func adrpPageBase(for register: String) -> UInt64? {
        adrpPageBaseByRegister[register.lowercased()]
    }

    /// If `value` was produced by a load of a known selref slot, returns the
    /// validated selector provenance captured at that load.
    func selectorEvidence(for value: MacIRValue) -> MacIRCallSelectorEvidence? {
        selectorEvidenceByValue[value]
    }

    mutating func recordSelectorEvidence(
        _ evidence: MacIRCallSelectorEvidence,
        for value: MacIRValue
    ) {
        selectorEvidenceByValue[value] = evidence
    }

    func materializedImmediate(for register: String) -> UInt64? {
        materializedImmediateByRegister[register.lowercased()]
    }

    mutating func recordPlainComparison(_ comparison: BuilderComparison) {
        lastComparison = comparison
        lastAdjacentComparison = comparison
        sawConditionalCompareSinceComparison = false
    }

    mutating func recordMaterializedImmediate(_ value: UInt64, for register: String) {
        materializedImmediateByRegister[register.lowercased()] = value
    }

    mutating func clearMaterializedImmediate(for register: String) {
        let normalized = register.lowercased()
        materializedImmediateByRegister.removeValue(forKey: normalized)
        if normalized == "fp" || normalized == "x29" || normalized == "w29" {
            materializedImmediateByRegister.removeValue(forKey: "fp")
            materializedImmediateByRegister.removeValue(forKey: "x29")
            materializedImmediateByRegister.removeValue(forKey: "w29")
        }
        if normalized == "lr" || normalized == "x30" || normalized == "w30" {
            materializedImmediateByRegister.removeValue(forKey: "lr")
            materializedImmediateByRegister.removeValue(forKey: "x30")
            materializedImmediateByRegister.removeValue(forKey: "w30")
        }
        if let alias = Self.widthAlias(for: normalized) {
            materializedImmediateByRegister.removeValue(forKey: alias)
        }
    }

    var recoveredLocalVariables: [MacIRLocalVariable] {
        localVariablesByOffset.keys.sorted().compactMap { localVariablesByOffset[$0] }
    }

    var recoveredCallSignatures: [MacIRCallSignature] {
        callTargets.compactMap { callSignaturesByTarget[$0] }
    }

    var recoveredNameBindings: [MacIRNameBinding] {
        let localBindings = recoveredLocalVariables.map {
            MacIRNameBinding(
                target: .stackSlot(offset: $0.offset),
                name: $0.name,
                type: $0.type,
                kind: .stackLocal
            )
        }
        let registerBindings = registerNameBindingOrder.compactMap { registerNameBindingsByValue[$0] }
        return localBindings + registerBindings
    }

    func readRegister(_ name: String) -> MacIRValue {
        if let value = ssaValue(for: name) { return value }
        if let view = Self.simdViewWidth(name), let defined = callResultVectorWidth[view.index], view.width > defined {
            return .unknown("unavailable_upper_v\(view.index)")
        }
        if permitsNEONBufferCarrier,
           let index = MacIRBuilder.vectorRegisterIndex(name.lowercased()),
           regionUpperVectorUnavailable.contains("v\(index)") {
            return .unknown("unavailable_upper_v\(index)")
        }
        if permitsNEONBitViewCarrier, callUnavailableRegisterValues.contains(name.lowercased()) {
            return .unknown("unavailable_\(name.lowercased())")
        }
        let normalized = neonBitViewCarrier(neonBufferCarrier(name.lowercased()))
        if let value = currentIntegerValue(forRequestedRegister: normalized) {
            return value
        }
        if Self.physicalIntegerView(for: normalized) != nil,
           isIntegerRegisterUnavailable(normalized) {
            return .unknown("unavailable_\(normalized)")
        }
        if callUnavailableRegisterValues.contains(normalized) {
            return .unknown("unavailable_\(normalized)")
        }
        if registerVersions[normalized] == nil,
           let requested = Self.scalarFPView(for: normalized),
           requested.index < 8 {
            let bindingID = MacIRParameterBindingID.simd(requested.index)
            let hasOtherViewFormal = parameters.contains { parameter in
                guard parameter.bindingID == bindingID,
                      case let .simd(_, scalarWidth) = parameter.abiLocation else {
                    return false
                }
                return scalarWidth != requested.width
            }
            if hasOtherViewFormal {
                return .unknown("unavailable_\(normalized)")
            }
        }
        if let argument = currentEntryStackArgumentByScalarFPRegister[normalized] {
            return argument
        }
        if registerVersions[normalized] == nil,
           let fragment = richFragment(for: normalized) {
            if vectorScalarCallUnavailableRegisterValues.contains(normalized) {
                return .unknown("unavailable_\(normalized)")
            }
            return fragment
        }
        if registerVersions[normalized] == nil,
           let parameter = parameter(for: normalized),
           let bindingID = parameter.bindingID {
            let argument = MacIRValue.argument(bindingID: bindingID)
            if let requested = MacIRBuilder.integerRegisterView(normalized),
               let provided = MacIRBuilder.integerRegisterView(parameter.register) {
                let projected = Self.projectIntegerValue(
                    argument,
                    fromWidth: provided.width,
                    toWidth: requested.width
                )
                if let sink = RejectedCFGDiagnostics.sink {
                    sink(.entryRead(register: normalized, parameter: parameter,
                        sourceWidth: provided.width, requestedWidth: requested.width,
                        projectedValue: projected, file: #fileID, line: #line))
                }
                return projected
            }
            if let sink = RejectedCFGDiagnostics.sink {
                sink(.entryRead(register: normalized, parameter: parameter,
                    sourceWidth: nil, requestedWidth: nil, projectedValue: argument,
                    file: #fileID, line: #line))
            }
            return argument
        }
        return .register(name: normalized, version: registerVersions[normalized, default: 0])
    }

    /// The origin owns a pre-write definition, never a destination-name reread.
    func signedBitfieldOrigin(mnemonic: String, source: String, destination: String) -> MacIRSignedBitfield.Origin? {
        guard let functionName = signedBitfieldFunctionName,
              let functionStart = returnProducerEntryAddress,
              let instructionAddress = currentRowAddress,
              let view = MacIRBuilder.integerRegisterView(source),
              !isIntegerRegisterUnavailable(index: view.index) else { return nil }
        let definition: MacIRValue
        let definitionBits: Int
        if let current = currentIntegerDefinitionByIndex[view.index] {
            if current.isJoinedDefinition {
                guard mnemonic == "sbfiz", ssaExactNumericInputsAvailable,
                      let binding = ssa?.current[view.index], binding.isPhi, !binding.isUnavailable,
                      binding.value == current.value, binding.bitWidth == current.width else { return nil }
            }
            definition = current.value
            definitionBits = current.width
        } else if let fragment = richFragment(for: source) {
            definition = fragment
            definitionBits = view.width
        } else if let parameter = parameter(for: source),
                  let binding = parameter.bindingID,
                  case let .gpr(_, width) = parameter.abiLocation {
            definition = .argument(bindingID: binding)
            definitionBits = width
        } else {
            return nil
        }
        return .init(functionName: functionName, functionStart: functionStart,
                     instructionAddress: instructionAddress, mnemonic: mnemonic,
                     sourceRegister: source, destinationRegister: destination,
                     definition: definition, definitionBits: definitionBits)
    }

    @discardableResult
    mutating func writeRegister(_ name: String) -> MacIRValue {
        let normalized = neonBitViewCarrier(neonBufferCarrier(name.lowercased()))
        if let view = Self.physicalIntegerView(for: normalized), (0..<8).contains(view.index) {
            constructedCallArgumentGPRs.insert(view.index)
        }
        if normalized == "sp" || normalized == "wsp" {
            invalidateStackCoordinateSystem()
        }
        clearStackPointerAlias(for: normalized)
        if let vectorIndex = MacIRBuilder.vectorRegisterIndex(normalized) {
            recordVectorScalarFPCallClobber(index: vectorIndex)
            regionUpperVectorUnavailable.remove("v\(vectorIndex)")
        }
        if let view = Self.simdViewWidth(name) {
            vectorViewWidthByIndex[view.index] = view.width
            callResultVectorWidth.removeValue(forKey: view.index)
        }
        currentEntryStackArgumentByScalarFPRegister.removeValue(forKey: normalized)
        if let alias = Self.scalarFPAlias(for: normalized) {
            currentEntryStackArgumentByScalarFPRegister.removeValue(forKey: alias)
        }
        callUnavailableRegisterValues.remove(normalized)
        vectorScalarCallUnavailableRegisterValues.remove(normalized)
        if let view = Self.physicalIntegerView(for: normalized) {
            unavailableRegisterValues.remove(normalized)
            unavailableRegisterValues.remove("x\(view.index)")
            unavailableRegisterValues.remove("w\(view.index)")
        } else {
            unavailableRegisterValues.remove(normalized)
            if let alias = Self.scalarFPAlias(for: normalized) {
                unavailableRegisterValues.insert(alias)
                callUnavailableRegisterValues.insert(alias)
            }
        }
        let plannedBinding = ssaPlannedWrite(for: name)
        let nextVersion: Int
        if case let .register(_, version)? = plannedBinding?.value {
            nextVersion = version
        } else {
            nextVersion = max(registerVersions[normalized, default: 0] + 1,
                              registerVersionFloor + 1)
        }
        registerVersions[normalized] = nextVersion
        clearStackBaseOffset(for: normalized)
        if let alias = Self.widthAlias(for: normalized) {
            clearStackBaseOffset(for: alias)
        }
        clearMaterializedImmediate(for: normalized)
        // A non-adrp write invalidates any page base tracked for the register so
        // a later selref `ldr` cannot reconstruct a stale slot address. The adrp
        // lifting re-records the fresh page base AFTER calling writeRegister.
        if let view = Self.physicalIntegerView(for: normalized) {
            adrpPageBaseByRegister.removeValue(forKey: "x\(view.index)")
            adrpPageBaseByRegister.removeValue(forKey: "w\(view.index)")
            adrpPageBaseByRegister.removeValue(forKey: normalized)
            if view.index == 29 {
                adrpPageBaseByRegister.removeValue(forKey: "fp")
            }
            if view.index == 30 {
                adrpPageBaseByRegister.removeValue(forKey: "lr")
            }
        } else {
            adrpPageBaseByRegister.removeValue(forKey: normalized)
            if let alias = Self.widthAlias(for: normalized) {
                adrpPageBaseByRegister.removeValue(forKey: alias)
            }
        }
        let isABIResultRegister = ["x0", "w0", "d0", "s0"].contains(normalized)
        if isABIResultRegister {
            shouldInferVoidReturn = false
        }
        let value = plannedBinding?.value ?? MacIRValue.register(name: normalized, version: nextVersion)
        if let view = Self.physicalIntegerView(for: normalized) {
            currentIntegerDefinitionByIndex[view.index] = IntegerRegisterDefinition(
                value: value,
                width: plannedBinding?.bitWidth ?? view.width
            )
        }
        installSSAWrite(for: name)
        if isABIResultRegister {
            latestABIResultValue = value
            hasUnmodeledABIResultWrite = false
        }
        recordRegisterTemporaryIfNeeded(for: value)
        return value
    }

    mutating func invalidateEntrySPProvenance() {
        entrySPIsExact = false
    }

    mutating func invalidateStackCoordinateSystem() {
        invalidateEntrySPProvenance()
        invalidateAllStackSlotValues()
    }

    mutating func invalidateAllStackSlotValues() {
        stackSlotValues.removeAll(keepingCapacity: true)
        outgoingCallStackStores.removeAll(keepingCapacity: true)
    }

    mutating func invalidateStackMemoryIfProvenAlias(_ register: String) {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "sp" || normalized == "wsp" {
            invalidateStackCoordinateSystem()
            return
        }
        guard knownStackBaseOffset(for: normalized) != nil else { return }
        invalidateEntrySPProvenance()
        invalidateAllStackSlotValues()
    }

    mutating func recordUnmodeledDefiniteWrite(for register: String) {
        defer { installSSAInvalidation(for: register) }
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        clearStackPointerAlias(for: normalized)
        if normalized == "sp" || normalized == "wsp" {
            invalidateStackCoordinateSystem()
            clearStackBaseOffset(for: normalized)
            clearMaterializedImmediate(for: normalized)
            return
        }
        if let view = Self.physicalIntegerView(for: normalized) {
            unavailableRegisterValues.insert("x\(view.index)")
            unavailableRegisterValues.insert("w\(view.index)")
            currentIntegerDefinitionByIndex.removeValue(forKey: view.index)
            clearStackBaseOffset(for: "x\(view.index)")
            clearStackBaseOffset(for: "w\(view.index)")
            clearMaterializedImmediate(for: normalized)
            adrpPageBaseByRegister.removeValue(forKey: "x\(view.index)")
            adrpPageBaseByRegister.removeValue(forKey: "w\(view.index)")
            if view.index == 29 {
                adrpPageBaseByRegister.removeValue(forKey: "fp")
            }
            if view.index == 30 {
                adrpPageBaseByRegister.removeValue(forKey: "lr")
            }
            if view.index == 0 {
                latestABIResultValue = nil
                hasUnmodeledABIResultWrite = true
                shouldInferVoidReturn = false
            }
            return
        }
        if let vectorIndex = MacIRBuilder.vectorRegisterIndex(normalized) {
            recordVectorScalarFPCallClobber(index: vectorIndex)
            // Region path: an unmodelled write must not leave the previous
            // vN SSA value readable. The next real write clears this.
            if permitsNEONBufferCarrier { callUnavailableRegisterValues.insert("v\(vectorIndex)") }
            return
        }
        guard let view = Self.scalarFPView(for: normalized) else { return }
        invalidateScalarFPPhysicalRegister(index: view.index)
    }

    private mutating func recordVectorScalarFPCallClobber(index: Int) {
        guard (0...31).contains(index) else { return }
        let doubleRegister = "d\(index)"
        let singleRegister = "s\(index)"
        vectorScalarCallUnavailableRegisterValues.insert(doubleRegister)
        vectorScalarCallUnavailableRegisterValues.insert(singleRegister)

        // ★ Insight: qN/vN definitely shadow scalar call inputs in dN/sN, but
        // WS-15 freezes general dataflow and return inference. Keep this new
        // evidence in a call-capture-only lattice instead of broadening it into
        // the pre-existing scalar availability state.
    }

    private mutating func invalidateScalarFPPhysicalRegister(index: Int) {
        guard (0...31).contains(index) else { return }
        let doubleRegister = "d\(index)"
        let singleRegister = "s\(index)"
        currentEntryStackArgumentByScalarFPRegister.removeValue(forKey: doubleRegister)
        currentEntryStackArgumentByScalarFPRegister.removeValue(forKey: singleRegister)
        unavailableRegisterValues.insert(doubleRegister)
        unavailableRegisterValues.insert(singleRegister)
        callUnavailableRegisterValues.insert(doubleRegister)
        callUnavailableRegisterValues.insert(singleRegister)
        if index == 0 {
            latestABIResultValue = nil
            hasUnmodeledABIResultWrite = true
            shouldInferVoidReturn = false
        }
    }

    private mutating func recordCallerSavedScalarFPClobber(index: Int) {
        guard (0...31).contains(index) else { return }
        let dRegister = "d\(index)"
        let sRegister = "s\(index)"
        unavailableRegisterValues.insert(dRegister)
        unavailableRegisterValues.insert(sRegister)
        callUnavailableRegisterValues.insert(dRegister)
        callUnavailableRegisterValues.insert(sRegister)
        if index == 0 {
            latestABIResultValue = nil
            hasUnmodeledABIResultWrite = true
            shouldInferVoidReturn = false
        }
    }

    /// A register holding a stack address was stored to memory: the address has
    /// escaped, so any later call may write any stack slot through it.
    var stackAddressEscapedThroughMemory = false

    mutating func noteStoredStackAddress(_ register: String) {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let view = MacIRBuilder.integerRegisterView(normalized), view.width == 64 else { return }
        if stackPointerAliasOffsetByGPR[view.index] != nil || knownStackBaseOffset(for: normalized) != nil {
            stackAddressEscapedThroughMemory = true
        }
    }

    mutating func invalidateAppleCallerSavedState() {
        defer {
            installSSACallClobbers()
            constructedCallArgumentGPRs.removeAll(keepingCapacity: true)
        }
        // ADR03-N01: the callee may write any stack slot whose address it receives
        // in an argument register, or whose address escaped through memory earlier.
        let receivesStackAddress = (0...7).contains { index in
            stackPointerAliasOffsetByGPR[index] != nil || knownStackBaseOffset(for: "x\(index)") != nil
        }
        if receivesStackAddress || stackAddressEscapedThroughMemory {
            invalidateAllStackSlotValues()
        }
        // The callee owns its incoming argument area and may overwrite it; nothing stored
        // there before this call proves a later call's arguments.
        outgoingCallStackStores.removeAll(keepingCapacity: true)
        stackPointerAliasOffsetByGPR.removeAll(keepingCapacity: true)
        for index in 0...18 {
            recordUnmodeledDefiniteWrite(for: "x\(index)")
        }
        recordUnmodeledDefiniteWrite(for: "x30")

        for index in 0...7 {
            recordCallerSavedScalarFPClobber(index: index)
            callUnavailableRegisterValues.insert("v\(index)")
            callUnavailableRegisterValues.insert("q\(index)")
        }
        for index in 16...31 {
            recordCallerSavedScalarFPClobber(index: index)
            callUnavailableRegisterValues.insert("v\(index)")
            callUnavailableRegisterValues.insert("q\(index)")
        }
        for index in 8...15 {
            // Only the low 64 bits survive a call. Region scalar views share
            // vN, so keep their low-half carrier and refuse full reads above it.
            regionUpperVectorUnavailable.insert("v\(index)")
            if !permitsNEONBufferCarrier {
                callUnavailableRegisterValues.insert("v\(index)")
                callUnavailableRegisterValues.insert("q\(index)")
            }
        }

        lastComparison = nil
        lastAdjacentComparison = nil
        pendingConditionalCompare = nil
        sawConditionalCompareSinceComparison = true
    }

    mutating func invalidateGeneralVectorRegionAtCall(returning result: MacIRValue?) {
        // Calls may mutate memory reachable through any argument. The region
        // does not currently prove non-escape for every stack alias.
        invalidateAllStackSlotValues()
        func returnedVectorIndices(_ value: MacIRValue?) -> Set<Int> {
            guard let value else { return [] }
            switch value {
            case let .register(name, _):
                guard let index = MacIRBuilder.vectorRegisterIndex(neonBufferCarrier(name)) else {
                    return []
                }
                return [index]
            case let .abiComposite(_, fragments):
                return fragments.reduce(into: Set<Int>()) { result, fragment in
                    result.formUnion(returnedVectorIndices(fragment))
                }
            default: return []
            }
        }
        let returned = returnedVectorIndices(result)
        for index in returned {
            if let width = vectorViewWidthByIndex[index], width < 128 { callResultVectorWidth[index] = width }
        }
        for index in Array(0...7) + Array(16...31) {
            if returned.contains(index) { continue }
            let register = "v\(index)"
            recordUnmodeledDefiniteWrite(for: register)
            callUnavailableRegisterValues.insert(register)
        }
        for index in 8...15 {
            if returned.contains(index) { continue }
            regionUpperVectorUnavailable.insert("v\(index)")
        }
    }

    /// `b0`…`q31`/`v31` (with an optional arrangement) → register index and view width in bits.
    static func simdViewWidth(_ name: String) -> (index: Int, width: Int)? {
        let lowered = name.lowercased()
        guard let prefix = lowered.first else { return nil }
        let widths: [Character: Int] = ["b": 8, "h": 16, "s": 32, "d": 64, "q": 128, "v": 128]
        guard let width = widths[prefix] else { return nil }
        let digits = lowered.dropFirst().prefix(while: \.isNumber)
        let rest = lowered.dropFirst(1 + digits.count)
        guard !digits.isEmpty, rest.isEmpty || rest.first == ".", let index = Int(digits), (0...31).contains(index) else {
            return nil
        }
        return (index, width)
    }

    enum SSACallOutcome: Hashable { case authoredRich, typedIndirect, fallback }
    var ssaPlannedCallOutcomes: [SSACallOutcome: [Int: MacIRSSAState.Binding]] = [:]
    var ssaSelectedCallOutcome: SSACallOutcome?

    /// Capture has already chosen the lowering route. Select only its preplanned
    /// row writes before the ordinary call invalidation; never allocate a value.
    mutating func selectSSACallOutcome(_ outcome: SSACallOutcome) -> Bool {
        guard !ssaPlannedCallOutcomes.isEmpty else { return true }
        ssaSelectedCallOutcome = nil
        let cells = Set(ssaPlannedCallOutcomes.values.flatMap { $0.keys })
        for cell in cells { ssa?.writes.removeValue(forKey: cell) }
        guard let selected = ssaPlannedCallOutcomes[outcome], ssa != nil else { return false }
        for (cell, binding) in selected { ssa?.writes[cell] = binding }
        ssaSelectedCallOutcome = outcome
        return true
    }

    @discardableResult
    mutating func writeCallResult(returnType: String?) -> MacIRValue? {
        let register = Self.returnRegister(for: returnType)
        if ssa != nil {
            // The immutable SSA plan owns result identity. A clobber-only call
            // has no result definition: allocating a legacy version here can
            // collide with the next instruction or an unused phi destination.
            // Keep the call and its clobbers; do not infer a return contract.
            guard let binding = ssaPlannedWrite(for: register),
                  case .callResult = binding.origin,
                  case .register = binding.value else { return nil }
        }
        return writeRegister(register)
    }

    /// Printed frame depth only; writeback must not change legacy stack-slot
    /// coordinates, semantic frame allocation, or the emitted SSA operation.
    mutating func recordStackDisplacement(delta: Int64) {
        if delta < 0 {
            let (displacement, overflow) = stackDisplacement.subtractingReportingOverflow(delta)
            if !overflow {
                stackDisplacement = displacement
                maxStackDisplacement = max(maxStackDisplacement, displacement)
            }
        } else {
            stackDisplacement = max(0, stackDisplacement - delta)
        }
    }

    mutating func allocateStack(_ amount: Int64) {
        stackDepth += max(0, amount)
        maxStackDepth = max(maxStackDepth, stackDepth)
        stackDisplacement += max(0, amount)
        maxStackDisplacement = max(maxStackDisplacement, stackDisplacement)
    }

    mutating func freeStack(_ amount: Int64) {
        stackDepth = max(0, stackDepth - max(0, amount))
        stackDisplacement = max(0, stackDisplacement - max(0, amount))
        stackSlotValues.removeAll(keepingCapacity: true)
        adrpPageBaseByRegister.removeAll(keepingCapacity: true)
        materializedImmediateByRegister.removeAll(keepingCapacity: true)
    }

    mutating func recordCall(_ target: String, signature: MacIRCallSignature?) {
        if !callTargets.contains(target) {
            callTargets.append(target)
        }
        if let signature {
            callSignaturesByTarget[target] = signature
        }
        // A callee's void declaration governs that call only. It is not
        // authority for the enclosing function's declared return type.
        // Own-function declarations remain authoritative in preferredReturnValue.
        shouldInferVoidReturn = false
    }

    /// Canonical-spelling projection for callers that request only a signature.
    /// The shared strict binder remains the sole scalar ABI admission path.
    func authoredScalarCallSignature(target: String) -> MacIRCallSignature? {
        guard let rawReturn = authoredCallSignaturesByTarget[target]?.returnType,
              rawReturn == rawReturn.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return authoredScalarCall(target: target)?.signature
    }

    /// Only complete fixed scalar declarations can replace catalog authority.
    /// Bind with the strict ABI model; unknown types and aggregate carriers abstain.
    func authoredScalarCall(
        target: String
    ) -> (signature: MacIRCallSignature, resultRegister: String?)? {
        guard let authored = authoredCallSignaturesByTarget[target],
              authored.variadicState == .fixed,
              case let .authoritative(rows) = authored.parameterList,
              let rawReturnType = authored.returnType else { return nil }
        let tokens = rows.map(\.rowToken)
        guard tokens.allSatisfy({ !$0.isEmpty }), Set(tokens).count == tokens.count else { return nil }
        let locations = DarwinARM64ParameterBinder.bindRich(
            parameterTypes: rows.map(\.type), resolver: richTypeResolver)
        guard locations.count == rows.count else { return nil }
        var parameters: [MacIRCallParameter] = []
        for (position, pair) in zip(rows, locations).enumerated() {
            let (row, location) = pair
            guard richTypeResolver.resolveLayout(ofType: row.type)?.kind != .shortVector else { return nil }
            let register: String
            switch location {
            case let .gpr(index, width) where (0..<8).contains(index) && [32, 64].contains(width):
                register = "\(width == 64 ? "x" : "w")\(index)"
            case let .simd(index, width) where (0..<8).contains(index) && [32, 64].contains(width):
                register = "\(width == 64 ? "d" : "s")\(index)"
            default:
                return nil
            }
            parameters.append(MacIRCallParameter(index: position, register: register,
                                                 type: row.type, name: row.name))
        }
        let returnType = rawReturnType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard richTypeResolver.resolveLayout(ofType: returnType)?.kind != .shortVector else { return nil }
        let returnLocation = DarwinARM64ParameterBinder.returnLocation(
            for: returnType, resolver: richTypeResolver)
        // The existing rich route already admits an empty list with a GPR result.
        // Do not change its effect planning through this scalar-only helper.
        if rows.isEmpty, case .single(.gpr(_, _)) = returnLocation { return nil }
        let resultRegister: String?
        switch returnLocation {
        case .void:
            resultRegister = nil
        case let .single(.gpr(index, width)) where index == 0 && [32, 64].contains(width):
            resultRegister = width == 64 ? "x0" : "w0"
        case let .single(.simd(index, width)) where index == 0 && [32, 64].contains(width):
            resultRegister = width == 64 ? "d0" : "s0"
        default:
            return nil
        }
        return (MacIRCallSignature(target: target, returnType: returnType, parameters: parameters,
                                   source: "authored-declaration"), resultRegister)
    }

    /// Pure structural admission shared by result planning and value capture.
    /// This establishes ABI shape only; it does not claim argument availability.
    func authoredRichCallShape(target: String) -> (
        parameterPieces: [[DarwinARM64RichParameterPiece]],
        returnLocation: DarwinARM64RichReturnLocation, returnType: String
    )? {
        guard let signature = authoredCallSignaturesByTarget[target],
              signature.variadicState == .fixed,
              case let .authoritative(rows) = signature.parameterList,
              let returnType = signature.returnType else { return nil }
        let locations = DarwinARM64ParameterBinder.bindRich(
            parameterTypes: rows.map(\.type), resolver: richTypeResolver
        )
        guard locations.count == rows.count else { return nil }
        var parameterPieces: [[DarwinARM64RichParameterPiece]] = []
        for (row, location) in zip(rows, locations) {
            guard case let .composite(pieces) = location else { return nil }
            let doubleHFA = [2, 4].contains(pieces.count) && pieces.allSatisfy {
                if case .simd(_, 64) = $0.register { return $0.size == 8 }
                return false
            }
            guard doubleHFA || DarwinARM64ParameterBinder.isSupportedDirectGPRStruct(
                row.type, pieces: pieces, resolver: richTypeResolver
            ) else { return nil }
            parameterPieces.append(pieces)
        }
        let returnLocation = DarwinARM64ParameterBinder.returnLocation(
            for: returnType, resolver: richTypeResolver
        )
        switch returnLocation {
        case let .composite(pieces):
            let doubleHFA = [2, 4].contains(pieces.count) && pieces.allSatisfy {
                if case .simd(_, 64) = $0.register { return $0.size == 8 }
                return false
            }
            guard doubleHFA || DarwinARM64ParameterBinder.isSupportedDirectGPRStruct(
                returnType, pieces: pieces, resolver: richTypeResolver
            ) else { return nil }
        case .single(.gpr(_, _)):
            break
        case let .indirect(register, _, _):
            guard register == 8 else { return nil }
        default:
            return nil
        }
        return (parameterPieces, returnLocation, returnType)
    }

    /// Bounded authored call path: each source row keeps its complete ordered
    /// HFA or direct integer-struct carrier set. Missing evidence abstains.
    func authoredRichCall(
        target: String
    ) -> (frame: MacIRCallFrame, returnLocation: DarwinARM64RichReturnLocation, returnType: String)? {
        guard let shape = authoredRichCallShape(target: target),
              let signature = authoredCallSignaturesByTarget[target],
              case let .authoritative(rows) = signature.parameterList else { return nil }
        var arguments: [MacIRRichCallArgument] = []
        for (position, pair) in zip(rows, shape.parameterPieces).enumerated() {
            let (row, pieces) = pair
            let captured: [MacIRRichCallPiece] = pieces.compactMap { piece in
                let name: String
                switch piece.register {
                case let .simd(index, width): name = "\(width == 64 ? "d" : "s")\(index)"
                case let .gpr(index, width): name = "\(width == 64 ? "x" : "w")\(index)"
                }
                guard let value = callArgumentValue(forRegister: name) else { return nil }
                return MacIRRichCallPiece(register: piece.register,
                                          valueByteOffset: piece.valueByteOffset,
                                          size: piece.size, value: value)
            }
            guard captured.count == pieces.count else { return nil }
            arguments.append(MacIRRichCallArgument(
                rowID: MacIRParameterRowID(rawValue: row.rowToken),
                sourcePosition: position, type: row.type, pieces: captured
            ))
        }
        let indirectResultPointer: MacIRValue?
        if case .indirect = shape.returnLocation {
            guard let pointer = callArgumentValue(forRegister: "x8") else { return nil }
            indirectResultPointer = pointer
        } else {
            indirectResultPointer = nil
        }
        guard let empty = MacIRCallArguments([]),
              let frame = MacIRCallFrame(
                  target: target, knownSignature: nil, controlInputs: .none,
                  arguments: empty, richArguments: arguments,
                  indirectResultPointer: indirectResultPointer
              ) else { return nil }
        return (frame, shape.returnLocation, shape.returnType)
    }

    /// Captures one validated pre-call frame. Known signatures retain sparse
    /// source positions and exact declared locations; unknown calls retain sparse
    /// physical GPR evidence. Observation coverage never stands in for a value.
    func callFrame(
        target: String,
        knownSignature: MacIRCallSignature?,
        controlInputs: MacIRCallControlInputs,
        recoverObjectiveCTail: Bool
    ) -> MacIRCallFrame? {
        if let knownSignature {
            var entries: [MacIRCallArgument] = []
            for parameter in knownSignature.parameters {
                guard let location = MacIRCallArgumentLocation(
                    register: parameter.register
                ),
                let value = callArgumentValue(forRegister: parameter.register) else {
                    continue
                }
                let selectorEvidence: MacIRCallSelectorEvidence? = {
                    guard recoverObjectiveCTail,
                          parameter.index == 1,
                          location == .gpr(index: 1, carrierWidth: 64) else {
                        return nil
                    }
                    return self.selectorEvidence(for: value)
                }()
                entries.append(MacIRCallArgument(
                    location: location,
                    role: .fixed(sourcePosition: parameter.index),
                    value: value,
                    selectorEvidence: selectorEvidence
                ))
            }

            var tailCountEvidence: MacIRCallTailCountEvidence?
            var observationScope = MacIRCallArgumentObservationScope.none
            if !recoverObjectiveCTail,
               let recovered = formatStringTail(signature: knownSignature, fixedEntries: entries) {
                tailCountEvidence = .formatString(recovered.evidence)
                entries.append(contentsOf: recovered.entries)
                observationScope = recovered.observationScope
            }
            if recoverObjectiveCTail,
               knownSignature.isVariadic,
               let selector = entries.first(where: {
                   $0.role == .fixed(sourcePosition: 1)
                       && $0.location == .gpr(index: 1, carrierWidth: 64)
                       && $0.selectorEvidence != nil
               })?.selectorEvidence {
                let tailCount = selector.name.unicodeScalars.filter { $0 == ":" }.count
                tailCountEvidence = .objectiveCSelectorColonCount(tailCount)
                // Selector spelling proves call-specific source arity, but it does
                // not prove the anonymous arguments' types or physical placement.
                // A multi-register scalar can occupy dense GPRs, and mixed-bank
                // arguments are legal. Retain the count as presentation/audit
                // evidence while leaving anonymous rows absent until authoritative
                // method ABI evidence is available at this exact call site.
            }

            guard let arguments = MacIRCallArguments(
                entries,
                observationScope: observationScope
            ) else { return nil }
            return MacIRCallFrame(
                target: target,
                knownSignature: knownSignature,
                tailCountEvidence: tailCountEvidence,
                controlInputs: controlInputs,
                arguments: arguments
            )
        }

        let excludedKeys = controlInputs.excludedArgumentKeys
        let observedGPRIndices = Set((0..<8).filter {
            !excludedKeys.contains(.gpr(index: $0))
        })
        guard let observationScope = MacIRCallArgumentObservationScope(
            gprIndices: observedGPRIndices
        ) else { return nil }
        let entries = observedGPRIndices.sorted().compactMap { index -> MacIRCallArgument? in
            // A call-clobber definition records an effect, not an observed
            // argument. The legacy join marker exception below applies only
            // to the retained non-SSA path.
            if let binding = ssa?.current[index],
               binding.isUnavailable || !binding.hasCallArgumentEvidence { return nil }
            if let definition = currentIntegerDefinitionByIndex[index],
               !isIntegerRegisterUnavailable(index: index)
                || (ssa == nil && definition.value == .unknown("unavailable_x\(index)")) {
                return MacIRCallArgument(
                    location: .gpr(index: index, carrierWidth: definition.width),
                    role: .unknown,
                    value: definition.value
                )
            }
            let xRegister = "x\(index)"
            let wRegister = "w\(index)"
            guard !unavailableRegisterValues.contains(xRegister),
                  !unavailableRegisterValues.contains(wRegister),
                  parameters.contains(where: { $0.bindingID == .gpr(index) }) else {
                return nil
            }
            return MacIRCallArgument(
                location: .gpr(index: index, carrierWidth: 64),
                role: .unknown,
                value: readRegister(xRegister)
            )
        }
        guard let arguments = MacIRCallArguments(
            entries,
            observationScope: observationScope
        ) else { return nil }
        // Construction can force the position of a carried value, but cannot
        // invent a carrier that has no observed value. Stop at that first gap.
        let constructedCount = observedGPRIndices.intersection(constructedCallArgumentGPRs)
            .max().map { $0 + 1 } ?? 0
        let observedPrefixCount = arguments.denseUnknownGPRPrefixValues()?.count ?? 0
        guard let frame = MacIRCallFrame(
            target: target,
            knownSignature: nil,
            controlInputs: controlInputs,
            arguments: arguments,
            unknownArgumentCount: min(constructedCount, observedPrefixCount)
        ) else { return nil }
        // A scalar authored contract may exist even when this frame's catalog signature
        // is nil. Do not silently reclassify that call as untyped.
        guard authoredCallSignaturesByTarget[target] == nil else { return frame }
        return frame.applyingMachineUsage(machineCallUsage,
            expectedContext: machineUsageContext, originalCaller: returnProducerSources,
            callAddress: currentRowAddress)

        // Printer consumes the physical list only in the final unknown-direct branch,
        // after existing typed/indirect paths; full preimage read recorded in ledger.
    }

    /// Reads a call argument from a specific register (integer x/w or FP d/s).
    /// Integer requests project the latest physical definition to the requested
    /// width, then fall back to a projected incoming formal. FP requests retain
    /// the existing exact-register, scalar-alias, and incoming-formal lookup.
    private func callArgumentValue(forRegister register: String) -> MacIRValue? {
        let normalized = register.lowercased()
        if let cell = MacIRSSAState.cells(for: normalized).first,
           let binding = ssa?.current[cell] {
            guard !binding.isUnavailable, binding.hasCallArgumentEvidence else { return nil }
            if (32..<64).contains(cell),
               callUnavailableRegisterValues.contains(normalized)
                || vectorScalarCallUnavailableRegisterValues.contains(normalized) {
                return nil
            }
            if case .entry = binding.origin,
               parameter(for: normalized) == nil, richFragment(for: normalized) == nil {
                return nil
            }
            return ssaValue(for: normalized)
        }
        if MacIRBuilder.integerRegisterView(normalized) != nil {
            if let value = currentIntegerValue(forRequestedRegister: normalized) {
                return value
            }
            if let view = MacIRBuilder.integerRegisterView(normalized),
               isIntegerRegisterUnavailable(index: view.index),
               currentIntegerDefinitionByIndex[view.index]?.value
                    == .unknown("unavailable_x\(view.index)") {
                // A rejected join can retain a parameter slot without retaining
                // its value. Ordinary unwritten and call-clobbered gaps stay nil.
                return .unknown("unavailable_\(normalized)")
            }
            guard !isIntegerRegisterUnavailable(normalized) else {
                return nil
            }
            if parameter(for: normalized) != nil || richFragment(for: normalized) != nil {
                return readRegister(normalized)
            }
            return nil
        }
        if registerVersions[normalized] != nil,
           !unavailableRegisterValues.contains(normalized),
           !callUnavailableRegisterValues.contains(normalized),
           !vectorScalarCallUnavailableRegisterValues.contains(normalized) {
            return readRegister(normalized)
        }
        guard !unavailableRegisterValues.contains(normalized),
              !callUnavailableRegisterValues.contains(normalized),
              !vectorScalarCallUnavailableRegisterValues.contains(normalized) else {
            return nil
        }
        if parameter(for: normalized) != nil || richFragment(for: normalized) != nil {
            return readRegister(normalized)
        }
        return nil
    }

    mutating func preferredReturnValue() -> MacIRValue? {
        if ssa != nil, ssaReturnRefusal != nil {
            if case let .single(.gpr(index, _))? = authoritativeReturnLocation, index == 0 {
                return .unknown("unavailable_join_result")
            }
            if authoritativeReturnLocation == nil, !shouldInferVoidReturn,
               callerReturnWidth != nil || admitsInstructionReturnProducer {
                return .unknown("unavailable_join_result")
            }
        }
        if let location = authoritativeReturnLocation {
            switch location {
            case .void:
                return nil
            case let .composite(pieces):
                let doubleHFA = [2, 4].contains(pieces.count) && pieces.allSatisfy {
                    if case .simd(_, 64) = $0.register { return $0.size == 8 }
                    return false
                }
                let integerStruct = authoritativeReturnType.map {
                    DarwinARM64ParameterBinder.isSupportedDirectGPRStruct(
                        $0, pieces: pieces, resolver: richTypeResolver
                    )
                } ?? false
                guard doubleHFA || integerStruct else { return .unknown("unbound_aggregate_return") }
                let fragments = pieces.map { piece -> MacIRValue in
                    let name: String
                    switch piece.register {
                    case let .simd(index, width): name = "\(width == 64 ? "d" : "s")\(index)"
                    case let .gpr(index, width): name = "\(width == 64 ? "x" : "w")\(index)"
                    }
                    guard !unavailableRegisterValues.contains(name),
                          !callUnavailableRegisterValues.contains(name),
                          !vectorScalarCallUnavailableRegisterValues.contains(name),
                          !isIntegerRegisterUnavailable(name) else {
                        return .unknown("unbound_return_fragment_\(piece.valueByteOffset)")
                    }
                    if case .gpr = piece.register,
                       let current = currentIntegerValue(forRequestedRegister: name) {
                        return current
                    }
                    guard registerVersions[name] != nil else {
                        return .unknown("unbound_return_fragment_\(piece.valueByteOffset)")
                    }
                    return readRegister(name)
                }
                return .abiComposite(type: authoritativeReturnType ?? "aggregate", fragments: fragments)
            case let .indirect(resultPointerRegister, _, _):
                // The pointer is an ABI carrier, not the result bytes. The
                // memory store path must prove those bytes before a value can
                // be reconstructed; keep that distinction visible in output.
                return .unknown("indirect_result_via_x\(resultPointerRegister)_unverified")
            case let .single(register):
                let name: String
                switch register {
                case let .gpr(index, width): name = "\(width == 32 ? "w" : "x")\(index)"
                case let .simd(index, registerWidth):
                    name = "\(registerWidth == 64 ? "d" : "s")\(index)"
                }
                let hasAvailableValue = registerVersions[name] != nil
                    || currentIntegerValue(forRequestedRegister: name) != nil
                    || parameter(for: name) != nil || richFragment(for: name) != nil
                guard hasAvailableValue, !isIntegerRegisterUnavailable(name),
                      !unavailableRegisterValues.contains(name),
                      !callUnavailableRegisterValues.contains(name),
                      !vectorScalarCallUnavailableRegisterValues.contains(name) else {
                    return .unknown("unbound_return_\(name)")
                }
                return readRegister(name)
            case .unbound:
                return .unknown("unbound_authored_return")
            }
        }
        if shouldInferVoidReturn {
            return nil
        }
        guard callerReturnWidth != nil || admitsInstructionReturnProducer else {
            return .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
        }
        if let latestABIResultValue {
            // Instruction classes prove the integer return carrier only. A
            // later scalar-FP write must not borrow an unrelated x0 proof.
            guard callerReturnWidth != nil
                || latestABIResultValue == currentIntegerDefinitionByIndex[0]?.value
                || (latestABIResultValue == .unknown("unavailable_join_result")
                    && admitsInstructionReturnProducer) else {
                return .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
            }
            return latestABIResultValue
        }
        if hasUnmodeledABIResultWrite {
            return .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
        }
        if let definition = currentIntegerDefinitionByIndex[0],
           !isIntegerRegisterUnavailable(index: 0) {
            if definition.isSyntheticReturnPhi {
                if callerReturnWidth == nil, hasX0ReturnProducer, admitsInstructionReturnProducer {
                    return definition.value
                }
                // A real incoming write proves dataflow, not this function's
                // result contract. Authoritative signatures were handled above;
                // a witnessed caller use can also establish an integer result.
                guard let callerReturnWidth,
                      hasX0ReturnProducer || parameter(for: "x0") != nil else {
                    return .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
                }
                let value = readRegister(callerReturnWidth == .w0 ? "w0" : "x0")
                if callerReturnWidth == .w0 {
                    returnType = "uint32_t"
                    valueTypeHints[value] = "uint32_t"
                } else if !hasX0ReturnProducer, let parameter = parameter(for: "x0") {
                    // Preserve the existing entry-only caller-evidence typing.
                    returnType = parameter.type
                    valueTypeHints[value] = parameter.type
                }
                return value
            }
            if hasX0ReturnProducer { return definition.value }
        }
        if x0PassesThroughUnwritten {
            if let callerReturnWidth, let parameter = parameter(for: "x0") {
                let value = readRegister(callerReturnWidth == .w0 ? "w0" : "x0")
                let type = callerReturnWidth == .w0 ? "uint32_t" : parameter.type
                returnType = type
                valueTypeHints[value] = type
                return value
            }
            return .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
        }
        if parameter(for: "x0") != nil {
            return readRegister("x0")
        }
        return .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
    }

    // States are copied at CFG joins. Sharing this function-local cache keeps
    // the complete proof single-shot even when different RETs restore copies.
    private final class ReturnProducerProofCache {
        var result: Bool?
    }

    var admitsInstructionReturnProducer: Bool {
        if ssa != nil { return ssaReturnProducerProof ?? false }
        return memoizedReturnProducerProof {
            Self.proveReturnProducers(sources: returnProducerSources,
                entry: returnProducerEntryAddress, signatures: authoredCallSignaturesByTarget)
        }
    }

    enum ReturnProducerDefinition {
        case constant(UInt64)
        case copy(index: Int, width: Int)
        case load
        case arithmetic
        case compareSet
        case unknown
    }

    enum ReturnProducerKind: Hashable {
        case constant(UInt64)
        case load
        case arithmetic
        case exactCompareSet
    }

    private struct ReturnProducerPoint: Hashable {
        let address: UInt64
        let register: Int
        let width: Int
        let permitsExactCompareSet: Bool
    }

    /// Resolve every reachable exit before following definitions backwards.
    /// Calls kill caller-saved carriers; a load remains a load even if it reads
    /// a spill. Plain copies preserve origin but never preserve exact cset shape.
    private static func proveReturnProducers(sources: [MacIRSourceSpan], entry: UInt64?,
        signatures: [String: FunctionSignatureOverride]) -> Bool {
        guard let entry, !sources.isEmpty else { return false }
        let groups = Dictionary(grouping: sources, by: \.address)
        guard groups.values.allSatisfy({ $0.count == 1 }) else { return false }
        let rows = groups.compactMapValues(\.first)
        guard rows[entry] != nil else { return false }
        var predecessors: [UInt64: [UInt64]] = [:]
        var effects: [UInt64: [Int: ReturnProducerDefinition]] = [:]
        var returns: [UInt64] = []
        var visited: Set<UInt64> = []
        var pending = [entry]
        while let address = pending.popLast() {
            guard visited.insert(address).inserted else { continue }
            guard !Task.isCancelled, let row = rows[address] else { return false }
            let mnemonic = row.mnemonic.lowercased()
            let operands = MacIRBuilder.splitOperands(row.operands)
            var next: [UInt64] = []
            var writes: [Int: ReturnProducerDefinition] = [:]
            switch mnemonic {
            case "ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr":
                guard operands.isEmpty || mnemonic == "ret" && operands.count == 1
                    && ["x30", "lr"].contains(operands[0].lowercased()) else { return false }
                returns.append(address)
            case "b":
                guard operands.count == 1, let target = returnProducerAddress(operands[0]),
                      rows[target] != nil else { return false }
                next = [target]
            case "cbz", "cbnz", "tbz", "tbnz":
                guard operands.count == (mnemonic.hasPrefix("tb") ? 3 : 2),
                      let targetText = operands.last, let target = returnProducerAddress(targetText),
                      let fallthroughAddress = address.addressAfter() else { return false }
                next = [target, fallthroughAddress]
            case "bl", "blr":
                guard operands.count == 1 else { return false }
                if mnemonic == "bl", returnProducerCallDoesNotReturn(operands[0], signatures: signatures) {
                    break
                }
                if mnemonic == "blr", returnProducerRegister(operands[0]) == nil { return false }
                guard let fallthroughAddress = address.addressAfter() else { return false }
                next = [fallthroughAddress]
                for index in 0...18 { writes[index] = .unknown }
                writes[30] = .unknown
            default:
                if mnemonic.hasPrefix("b.") || mnemonic.hasPrefix("bc.") {
                    let suffix = String(mnemonic.split(separator: ".").last ?? "")
                    guard MacIRBuilder.branchCondition(for: suffix) != nil, operands.count == 1,
                          let target = returnProducerAddress(operands[0]),
                          let fallthroughAddress = address.addressAfter() else { return false }
                    next = [target, fallthroughAddress]
                } else {
                    guard let modeled = returnProducerWrites(mnemonic: mnemonic, operands: operands),
                          let fallthroughAddress = address.addressAfter() else { return false }
                    writes = modeled
                    next = [fallthroughAddress]
                }
            }
            effects[address] = writes
            for successor in Set(next) {
                // Missing targets, tail exits and missing fallthrough are not
                // invented edges, including after an ordinary returning call.
                guard rows[successor] != nil else { return false }
                predecessors[successor, default: []].append(address)
                pending.append(successor)
            }
        }
        guard !returns.isEmpty else { return false }

        var work: [ReturnProducerPoint] = []
        for address in returns {
            guard address != entry, let incoming = predecessors[address], !incoming.isEmpty else { return false }
            work += incoming.map { .init(address: $0, register: 0, width: 64, permitsExactCompareSet: true) }
        }
        var seen: Set<ReturnProducerPoint> = []
        var kinds: Set<ReturnProducerKind> = []
        while let point = work.popLast() {
            guard seen.insert(point).inserted else { continue }
            guard !Task.isCancelled else { return false }
            var register = point.register
            var width = point.width
            var permitsExactCompareSet = point.permitsExactCompareSet
            if let definition = effects[point.address]?[register] {
                switch definition {
                case let .constant(value):
                    kinds.insert(.constant(width == 32 ? value & 0xffff_ffff : value))
                    continue
                case .load:
                    kinds.insert(.load)
                    continue
                case .arithmetic:
                    kinds.insert(.arithmetic)
                    continue
                case .compareSet:
                    kinds.insert(permitsExactCompareSet && register == 0 ? .exactCompareSet : .arithmetic)
                    continue
                case let .copy(index, sourceWidth):
                    register = index
                    width = min(width, sourceWidth)
                    permitsExactCompareSet = false
                case .unknown:
                    return false
                }
            }
            // Entry is an unknown definition even if a backedge also reaches it.
            guard point.address != entry, let incoming = predecessors[point.address],
                  !incoming.isEmpty else { return false }
            work += incoming.map { .init(address: $0, register: register, width: width,
                                         permitsExactCompareSet: permitsExactCompareSet) }
        }
        return admitsReturnProducerKinds(kinds)
    }

    static func admitsReturnProducerKinds(_ kinds: Set<ReturnProducerKind>) -> Bool {
        guard !kinds.isEmpty else { return false }
        if kinds == [.exactCompareSet] { return true }
        let constants = kinds.compactMap { kind -> UInt64? in
            if case let .constant(value) = kind { return value }
            return nil
        }
        if constants.count == kinds.count { return constants.allSatisfy { $0 <= 1 } }
        guard !constants.isEmpty else { return false }
        let nonconstants = kinds.filter {
            if case .constant = $0 { return false }
            return true
        }
        if nonconstants == [.load] { return true }
        return nonconstants.allSatisfy { $0 == .arithmetic || $0 == .exactCompareSet }
    }

    enum ReturnContractProducer: Hashable, Sendable {
        case constant
        case load
        case arithmetic
        case compareSet
        case passthroughParameter
        case calleeResult(UInt64)
        /// A path predicate proves zero only in this register view; not a source type.
        case guardedZero(width: Int)
        case unknown
    }

    enum ReturnContractExit: Hashable, Sendable {
        case returnInstruction(UInt64)
        case tailCall(UInt64)
        case noReturnCall(UInt64)
        case trap(UInt64)
        case infiniteLoop(UInt64)
        case unknown(UInt64)
    }

    struct ReturnContractProducerFacts: Equatable, Sendable {
        let producers: [UInt64: Set<ReturnContractProducer>]
        let exits: Set<ReturnContractExit>
        var reachableAddresses: Set<UInt64> = []
    }

    private struct ReturnContractProducerPoint: Hashable {
        let address: UInt64
        let successor: UInt64
        let guardedZeroWidth: Int?
        let register: Int
        let width: Int
        let permitsExactCompareSet: Bool
    }

    /// An additive row analysis for image contracts. Producer facts never grant
    /// return authority. Calls have an explicit origin and kill volatile carriers;
    /// the existing instruction-only proof remains independent of this analysis.
    static func returnContractProducerFacts(
        sources: [MacIRSourceSpan],
        entry: UInt64?,
        signatures: [String: FunctionSignatureOverride] = [:],
        resolvedTargetsByCallSite: [UInt64: UInt64] = [:],
        noReturnCallSites: Set<UInt64> = [],
        knownFunctionStarts: Set<UInt64> = []
    ) -> ReturnContractProducerFacts {
        func refused(_ address: UInt64) -> ReturnContractProducerFacts {
            .init(producers: [address: [.unknown]], exits: [.unknown(address)])
        }
        guard let entry, !sources.isEmpty else { return refused(entry ?? 0) }
        let groups = Dictionary(grouping: sources, by: \.address)
        guard groups.values.allSatisfy({ $0.count == 1 }) else { return refused(entry) }
        let rows = groups.compactMapValues(\.first)
        guard rows[entry] != nil else { return refused(entry) }
        var predecessors: [UInt64: Set<UInt64>] = [:]
        var effects: [UInt64: [Int: ReturnProducerDefinition]] = [:]
        var callResults: [UInt64: UInt64] = [:]
        var returns: Set<UInt64> = []
        var exits: Set<ReturnContractExit> = []
        var terminalAddresses: Set<UInt64> = []
        var visited: Set<UInt64> = []
        var pending = [entry]
        while let address = pending.popLast() {
            guard visited.insert(address).inserted else { continue }
            guard !Task.isCancelled, let row = rows[address] else { return refused(address) }
            let mnemonic = row.mnemonic.lowercased()
            let operands = MacIRBuilder.splitOperands(row.operands)
            var next: [UInt64] = []
            var writes: [Int: ReturnProducerDefinition] = [:]
            switch mnemonic {
            case "ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr":
                guard operands.isEmpty || mnemonic == "ret" && operands.count == 1
                    && ["x30", "lr"].contains(operands[0].lowercased()) else { return refused(address) }
                returns.insert(address)
                exits.insert(.returnInstruction(address))
            case "b":
                guard operands.count == 1 else { return refused(address) }
                if noReturnCallSites.contains(address)
                    || returnProducerCallDoesNotReturn(operands[0], signatures: signatures) {
                    exits.insert(.noReturnCall(address))
                } else if let target = resolvedTargetsByCallSite[address] ?? returnProducerAddress(operands[0]) {
                    if rows[target] != nil && (target == entry || !knownFunctionStarts.contains(target)) {
                        next = [target]
                    } else if knownFunctionStarts.contains(target) {
                        exits.insert(.tailCall(target))
                    } else {
                        return refused(address)
                    }
                } else {
                    return refused(address)
                }
            case "cbz", "cbnz", "tbz", "tbnz":
                guard operands.count == (mnemonic.hasPrefix("tb") ? 3 : 2),
                      let register = operands.first, returnProducerRegister(register) != nil,
                      let targetText = operands.last, let target = returnProducerAddress(targetText),
                      let fallthroughAddress = address.addressAfter() else { return refused(address) }
                if mnemonic.hasPrefix("tb") {
                    guard let bit = MacIRBuilder.parseImmediate(operands[1]), bit >= 0,
                          let view = returnProducerRegister(register), bit < Int64(view.width) else {
                        return refused(address)
                    }
                }
                next = [target, fallthroughAddress]
            case "bl", "blr":
                guard operands.count == 1 else { return refused(address) }
                if noReturnCallSites.contains(address) || mnemonic == "bl"
                    && returnProducerCallDoesNotReturn(operands[0], signatures: signatures) {
                    exits.insert(.noReturnCall(address))
                    break
                }
                if mnemonic == "blr", returnProducerRegister(operands[0]) == nil { return refused(address) }
                guard let fallthroughAddress = address.addressAfter() else { return refused(address) }
                next = [fallthroughAddress]
                for index in 0...18 { writes[index] = .unknown }
                writes[30] = .unknown
                if let target = resolvedTargetsByCallSite[address]
                    ?? (mnemonic == "bl" ? returnProducerAddress(operands[0]) : nil) {
                    callResults[address] = target
                }
            case "brk", "hlt", "udf":
                guard operands.count == 1, MacIRBuilder.parseImmediate(operands[0]) != nil else {
                    return refused(address)
                }
                exits.insert(.trap(address))
            default:
                if mnemonic.hasPrefix("b.") || mnemonic.hasPrefix("bc.") {
                    let suffix = String(mnemonic.split(separator: ".").last ?? "")
                    guard MacIRBuilder.branchCondition(for: suffix) != nil, operands.count == 1,
                          let target = returnProducerAddress(operands[0]),
                          let fallthroughAddress = address.addressAfter() else { return refused(address) }
                    next = [target, fallthroughAddress]
                } else {
                    guard let modeled = returnProducerWrites(mnemonic: mnemonic, operands: operands),
                          let fallthroughAddress = address.addressAfter() else { return refused(address) }
                    writes = modeled
                    next = [fallthroughAddress]
                }
            }
            effects[address] = writes
            if next.isEmpty { terminalAddresses.insert(address) }
            for successor in Set(next) {
                guard rows[successor] != nil,
                      successor == entry || !knownFunctionStarts.contains(successor) else { return refused(address) }
                predecessors[successor, default: []].insert(address)
                pending.append(successor)
            }
        }

        // Nodes with no path to any terminal form closed, finite control-flow
        // regions. With every edge resolved, execution there can only loop.
        var reachesTerminal = terminalAddresses
        pending = Array(terminalAddresses)
        while let address = pending.popLast() {
            for predecessor in predecessors[address] ?? [] where reachesTerminal.insert(predecessor).inserted {
                pending.append(predecessor)
            }
        }
        if let loopAddress = visited.subtracting(reachesTerminal).min() {
            exits.insert(.infiniteLoop(loopAddress))
        }

        let guardedZerosEnabled = MacIRConfiguration.returnContractEnabled
        var producers: [UInt64: Set<ReturnContractProducer>] = [:]
        for returnAddress in returns.sorted() {
            var kinds: Set<ReturnContractProducer> = []
            var work: [ReturnContractProducerPoint] = []
            if returnAddress == entry { kinds.insert(.passthroughParameter) }
            for incoming in predecessors[returnAddress] ?? [] {
                work.append(.init(address: incoming, successor: returnAddress, guardedZeroWidth: nil, register: 0, width: 64, permitsExactCompareSet: true))
            }
            var seen: Set<ReturnContractProducerPoint> = []
            while let point = work.popLast() {
                guard seen.insert(point).inserted else { continue }
                guard !Task.isCancelled else { return refused(point.address) }
                var guardedZeroWidth = point.guardedZeroWidth
                var register = point.register
                var width = point.width
                var permitsExactCompareSet = point.permitsExactCompareSet
                // Consume only the exact zero edge crossed by this backward
                // path. Both successors must differ: a degenerate branch gives
                // no predicate. Keep this as fallback evidence so an existing
                // known callee/constant/load producer retains its full authority.
                // A later write/call has already stopped or redirected the walk.
                if guardedZerosEnabled, let branch = rows[point.address],
                   ["cbz", "cbnz"].contains(branch.mnemonic.lowercased()) {
                    let operands = MacIRBuilder.splitOperands(branch.operands)
                    if operands.count == 2,
                       let view = returnProducerRegister(operands[0]), view.index == register,
                       let target = returnProducerAddress(operands[1]),
                       let fallthroughAddress = point.address.addressAfter(), target != fallthroughAddress {
                        let zeroSuccessor = branch.mnemonic.lowercased() == "cbz" ? target : fallthroughAddress
                        if point.successor == zeroSuccessor {
                            guardedZeroWidth = max(guardedZeroWidth ?? 0, min(width, view.width))
                        }
                    }
                }
                if register == 0, let target = callResults[point.address] {
                    // Narrowing a callee's result changes its shape. It remains
                    // a producer, but cannot inherit that callee's full shape.
                    kinds.insert(width == 64 ? .calleeResult(target) : .arithmetic)
                    continue
                }
                if let definition = effects[point.address]?[register] {
                    switch definition {
                    case .constant: kinds.insert(.constant); continue
                    case .load: kinds.insert(.load); continue
                    case .arithmetic: kinds.insert(.arithmetic); continue
                    case .compareSet:
                        kinds.insert(permitsExactCompareSet && register == 0 ? .compareSet : .arithmetic)
                        continue
                    case let .copy(index, sourceWidth):
                        register = index
                        width = min(width, sourceWidth)
                        permitsExactCompareSet = false
                    case .unknown:
                        if let guardedZeroWidth {
                            kinds.insert(.guardedZero(width: min(width, guardedZeroWidth)))
                        } else { kinds.insert(.unknown) }
                        continue
                    }
                }
                if point.address == entry {
                    if let guardedZeroWidth {
                        kinds.insert(.guardedZero(width: min(width, guardedZeroWidth)))
                    } else { kinds.insert(register == 0 ? .passthroughParameter : .unknown) }
                }
                let incoming = predecessors[point.address] ?? []
                if incoming.isEmpty && point.address != entry { kinds.insert(.unknown) }
                for predecessor in incoming {
                    work.append(.init(address: predecessor, successor: point.address, guardedZeroWidth: guardedZeroWidth, register: register, width: width,
                                      permitsExactCompareSet: permitsExactCompareSet))
                }
            }
            producers[returnAddress] = kinds.isEmpty ? [.unknown] : kinds
        }
        return .init(producers: producers, exits: exits, reachableAddresses: visited)
    }

    private static func returnProducerCallDoesNotReturn(_ target: String,
        signatures: [String: FunctionSignatureOverride]) -> Bool {
        switch signatures[target]?.noReturnState {
        case .noReturn?: return true
        case .returns?: return false
        default:
            return NoReturnCatalog.isNoReturn(target)
                || CallSignaturePack.bundledNoReturnCanonicalNames.contains(NoReturnCatalog.canonicalName(for: target))
        }
    }

    private static func returnProducerAddress(_ text: String) -> UInt64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
    }

    private static func returnProducerRegister(_ text: String) -> (index: Int, width: Int)? {
        switch text.lowercased() {
        case "fp": return (29, 64)
        case "lr": return (30, 64)
        default: return MacIRBuilder.integerRegisterView(text)
        }
    }

    /// Only definite, explicitly modeled effects can establish producer classes.
    /// An unknown instruction refuses the proof rather than relying on an empty
    /// result from the general register-write classifier.
    static func returnProducerWrites(mnemonic: String, operands rawOperands: [String])
        -> [Int: ReturnProducerDefinition]? {
        let operands = rawOperands.map { $0.lowercased() }
        var writes: [Int: ReturnProducerDefinition] = [:]
        let destination = operands.first.flatMap(returnProducerRegister)
        func isDataDestination(_ text: String) -> Bool {
            if returnProducerRegister(text) != nil || ["xzr", "wzr", "sp", "wsp"].contains(text)
                || MacIRBuilder.vectorRegisterIndex(text) != nil { return true }
            guard let prefix = text.first, ["b", "h", "s", "d"].contains(String(prefix)),
                  let index = Int(text.dropFirst()), (0...31).contains(index) else { return false }
            return text == "\(prefix)\(index)"
        }
        switch mnemonic {
        case "mov", "movz", "movn":
            guard (operands.count == 2 || operands.count == 3), let first = operands.first,
                  isDataDestination(first) else { return nil }
            if let destination {
                if ["xzr", "wzr"].contains(operands[1]), operands.count == 2 {
                    writes[destination.index] = .constant(0)
                } else if let source = returnProducerRegister(operands[1]),
                          mnemonic == "mov", operands.count == 2 {
                    writes[destination.index] = .copy(index: source.index, width: min(destination.width, source.width))
                } else if let immediate = MacIRBuilder.parseImmediate(operands[1]) {
                    var value = UInt64(bitPattern: immediate)
                    if operands.count == 3 {
                        let shiftParts = operands[2].split(separator: " ")
                        guard mnemonic != "mov", shiftParts.count == 2, shiftParts[0] == "lsl",
                              let shift = MacIRBuilder.parseImmediate(String(shiftParts[1])),
                              [Int64(0), 16, 32, 48].contains(shift), shift < Int64(destination.width),
                              (0...65535).contains(immediate) else { return nil }
                        value <<= UInt64(shift)
                    }
                    if mnemonic == "movn" { value = ~value }
                    if destination.width == 32 { value &= 0xffff_ffff }
                    writes[destination.index] = .constant(value)
                } else {
                    writes[destination.index] = .unknown
                }
            }
        case "movk", "adr", "adrp", "fmov":
            guard operands.count >= 2, let first = operands.first, isDataDestination(first) else { return nil }
            if let destination { writes[destination.index] = .unknown }
        case "ldr", "ldur", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldurb", "ldurh", "ldursb", "ldursh", "ldursw",
             "ldp", "ldpsw", "ldnp":
            let pair = ["ldp", "ldpsw", "ldnp"].contains(mnemonic)
            guard operands.count >= (pair ? 3 : 2), isDataDestination(operands[0]),
                  !pair || isDataDestination(operands[1]) else { return nil }
            if let destination { writes[destination.index] = .load }
            if pair, let second = returnProducerRegister(operands[1]) { writes[second.index] = .load }
        case "str", "stur", "strb", "strh", "sturb", "sturh", "stp", "stnp":
            guard operands.count >= (["stp", "stnp"].contains(mnemonic) ? 3 : 2) else { return nil }
        case "add", "sub", "subs", "adds", "and", "ands", "orr", "eor", "mul", "sdiv", "udiv",
             "neg", "negs", "mvn", "bic", "bics", "orn", "eon", "lsl", "lsr", "asr", "ror",
             "ubfx", "sbfx", "ubfiz", "sbfiz", "bfi", "bfxil", "extr", "madd", "msub", "mneg",
             "umull", "smull", "umaddl", "smaddl", "smsubl", "umsubl", "smulh", "umulh",
             "sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw", "clz", "rbit", "rev", "rev16", "rev32",
             "csel", "csinc", "csinv", "csneg", "cinc", "cinv", "cneg", "csetm", "adc", "adcs", "sbc", "sbcs":
            guard operands.count >= 2, let first = operands.first, isDataDestination(first) else { return nil }
            if let destination { writes[destination.index] = .arithmetic }
        case "cset":
            guard operands.count == 2, MacIRBuilder.branchCondition(for: operands[1]) != nil,
                  let destination else { return nil }
            writes[destination.index] = .compareSet
        case "cmp", "cmn", "tst", "ccmp", "ccmn", "fcmp", "fcmpe":
            guard operands.count >= 2 else { return nil }
        case "nop", "bti": break
        case "pacibsp", "paciasp", "autibsp", "autiasp", "xpaclri": writes[30] = .unknown
        default:
            // Validated vector-only operations cannot define an integer return
            // carrier. Reuse their exact operand parsers, not mnemonic prefixes.
            let operandText = operands.joined(separator: ", ")
            if let vectorOperation = MacIRBuilder.neonLaneOperation(mnemonic: mnemonic, operandText: operandText),
               MacIRBuilder.vectorRegisterIndex(vectorOperation.destination) != nil {
                break
            }
            if let immediate = MacIRBuilder.neonMoveImmediate(mnemonic: mnemonic, operandText: operandText),
               MacIRBuilder.vectorRegisterIndex(immediate.destination) != nil {
                break
            }
            guard MacIRBuilder.neonLogical(mnemonic: mnemonic, operands: operands) != nil else { return nil }
        }
        if let base = MacIRBuilder.explicitMemoryWritebackBase(operands: operands),
           let register = returnProducerRegister(base) {
            guard writes[register.index] == nil else { return nil }
            writes[register.index] = .arithmetic
        }
        return writes
    }

    /// An untouched incoming x0 is compatible with both a void leaf and a
    /// pass-through result. Without return authority, neither is established.
    /// A phi that only carries entry values is still untouched for this policy.
    var x0PassesThroughUnwritten: Bool {
        authoritativeReturnLocation == nil && !shouldInferVoidReturn
            && latestABIResultValue == nil && !hasUnmodeledABIResultWrite
            && !hasX0ReturnProducer
            && !isIntegerRegisterUnavailable(index: 0)
            && parameter(for: "x0") != nil
    }

    private var hasX0ReturnProducer: Bool {
        guard let definition = currentIntegerDefinitionByIndex[0] else { return false }
        return !definition.isSyntheticReturnPhi
            || resolvedX0PhiReturnProducers.contains(definition.value)
    }

    mutating func recordValueType(_ type: String, for value: MacIRValue) {
        valueTypeHints[value] = type
        updateRegisterTemporaryType(type, for: value)
    }

    mutating func propagateValueType(from source: MacIRValue, to destination: MacIRValue) {
        guard let type = explicitType(for: source) else { return }
        recordValueType(type, for: destination)
    }

    func returnTypeHint(for value: MacIRValue) -> String? {
        valueTypeHints[value]
    }

    mutating func store(
        _ value: MacIRValue,
        inStackSlot offset: Int64,
        byteWidth: Int?,
        carrierKind: StackSlotCarrierKind?,
        canCacheValue: Bool = true,
        shouldPromoteToLocal: Bool,
        preferredType: String? = nil,
        stackAccessIndex: Int = 0
    ) {
        if let byteWidth,
           Self.hasValidStackRange(offset: offset, byteWidth: byteWidth) {
            invalidateStackSlotValues(overlapping: offset, byteWidth: byteWidth)
            if canCacheValue, let carrierKind {
                stackSlotValues[offset] = StackSlotValueFact(
                    value: value,
                    byteWidth: byteWidth,
                    carrierKind: carrierKind
                )
            }
        } else {
            // Without a byte extent, no existing alias can be ruled out and the
            // new value itself cannot safely satisfy a width-qualified reload.
            invalidateAllStackSlotValues()
        }
        if shouldPromoteToLocal {
            recordLocal(at: offset, byteWidth: byteWidth, source: value, preferredType: preferredType,
                        stackAccessIndex: stackAccessIndex)
        }
    }

    private mutating func invalidateStackSlotValues(overlapping offset: Int64, byteWidth: Int) {
        guard Self.hasValidStackRange(offset: offset, byteWidth: byteWidth) else {
            invalidateAllStackSlotValues()
            return
        }
        stackSlotValues = stackSlotValues.filter { candidateOffset, fact in
            !Self.stackRangesOverlap(
                firstOffset: candidateOffset,
                firstByteWidth: fact.byteWidth,
                secondOffset: offset,
                secondByteWidth: byteWidth
            )
        }
    }

    private static func stackRangesOverlap(
        firstOffset: Int64,
        firstByteWidth: Int,
        secondOffset: Int64,
        secondByteWidth: Int
    ) -> Bool {
        guard firstByteWidth > 0, secondByteWidth > 0,
              let firstWidth = Int64(exactly: firstByteWidth),
              let secondWidth = Int64(exactly: secondByteWidth) else {
            return true
        }
        let firstEnd = firstOffset.addingReportingOverflow(firstWidth)
        let secondEnd = secondOffset.addingReportingOverflow(secondWidth)
        guard !firstEnd.overflow, !secondEnd.overflow else { return true }
        return firstOffset < secondEnd.partialValue && secondOffset < firstEnd.partialValue
    }

    private static func hasValidStackRange(offset: Int64, byteWidth: Int) -> Bool {
        guard byteWidth > 0,
              let width = Int64(exactly: byteWidth) else {
            return false
        }
        return !offset.addingReportingOverflow(width).overflow
    }

    mutating func recordLocal(
        at offset: Int64,
        byteWidth: Int?,
        source: MacIRValue?,
        preferredType: String? = nil,
        stackAccessIndex: Int = 0
    ) {
        let explicitSourceType = source.flatMap(explicitType(for:))
        let inferredWidth = byteWidth
            ?? explicitSourceType.flatMap(MacIRBuilder.byteWidth(forType:))
            ?? source.flatMap(MacIRBuilder.byteWidth(for:))
            ?? 8
        // A sized access (preferredType) names the element's exact width AND
        // signedness from the encoding, which beats the always-unsigned
        // byte-width hint. It is only consulted when there is no typed source
        // value to honor, so a spilled register keeps its register type.
        let inferredType = explicitSourceType
            ?? source.map { MacIRBuilder.typeHint(for: $0, byteWidth: inferredWidth) }
            ?? preferredType
            ?? MacIRBuilder.typeHint(byteWidth: inferredWidth)

        if let existing = localVariablesByOffset[offset],
           existing.byteWidth >= inferredWidth {
            return
        }

        var local = MacIRLocalVariable(
            offset: offset,
            type: inferredType,
            byteWidth: inferredWidth
        )
        local.definingAddress = currentRowAddress
        local.definingAccessIndex = stackAccessIndex
        localVariablesByOffset[offset] = local
    }

    func valueStoredInStackSlot(
        _ offset: Int64,
        accessByteWidth: Int?,
        carrierKind: StackSlotCarrierKind?
    ) -> MacIRValue? {
        guard let accessByteWidth,
              let carrierKind,
              let fact = stackSlotValues[offset],
              Self.hasValidStackRange(offset: offset, byteWidth: fact.byteWidth),
              fact.byteWidth == accessByteWidth,
              fact.carrierKind == carrierKind else {
            return nil
        }
        return fact.value
    }

    mutating func recordExplicitStackWriteback(_ register: String) {
        if register.lowercased() == "sp" { hasExplicitStackWriteback = true }
    }

    func stackBaseOffset(for register: String) -> Int64 {
        stackBaseOffsets[register.lowercased(), default: 0]
    }

    func knownStackBaseOffset(for register: String) -> Int64? {
        stackBaseOffsets[register.lowercased()]
    }

    mutating func recordFrameBase(destination: String, source: String) {
        let normalizedDestination = destination.lowercased()
        guard !hasExplicitStackWriteback, Self.isFramePointer(normalizedDestination), source.lowercased() == "sp" else { return }
        setStackBaseOffset(0, for: normalizedDestination)
    }

    mutating func recordFrameBase(destination: String, left: String, op: String, right: String) {
        let normalizedDestination = destination.lowercased()
        guard !hasExplicitStackWriteback, Self.isFramePointer(normalizedDestination), left.lowercased() == "sp",
              let amount = MacIRBuilder.parseImmediate(right) else {
            return
        }
        setStackBaseOffset(op == "-" ? -amount : amount, for: normalizedDestination)
    }

    private mutating func setStackBaseOffset(_ offset: Int64, for register: String) {
        if Self.isFramePointer(register) {
            stackBaseOffsets["fp"] = offset
            stackBaseOffsets["x29"] = offset
        } else {
            stackBaseOffsets[register] = offset
        }
    }

    private mutating func clearStackBaseOffset(for register: String) {
        if Self.isFramePointer(register) {
            stackBaseOffsets.removeValue(forKey: "fp")
            stackBaseOffsets.removeValue(forKey: "x29")
        } else {
            stackBaseOffsets.removeValue(forKey: register)
        }
    }

    private static func isFramePointer(_ register: String) -> Bool {
        register == "fp" || register == "x29"
    }

    private static func widthAlias(for register: String) -> String? {
        if register == "xzr" {
            return "wzr"
        }
        if register == "wzr" {
            return "xzr"
        }
        guard let prefix = register.first,
              prefix == "x" || prefix == "w" else {
            return nil
        }
        let suffix = register.dropFirst()
        guard suffix.allSatisfy(\.isNumber) else { return nil }
        return "\(prefix == "x" ? "w" : "x")\(suffix)"
    }

    private func currentIntegerValue(forRequestedRegister register: String) -> MacIRValue? {
        if let cell = MacIRSSAState.integerCell(for: register),
           let binding = ssa?.current[cell], !binding.isUnavailable {
            if case .entry = binding.origin {
                switch binding.value {
                case .argument, .argumentFragment: return ssaValue(for: register)
                default: return nil
                }
            }
            return ssaValue(for: register)
        }
        guard let requested = Self.physicalIntegerView(for: register),
              !isIntegerRegisterUnavailable(index: requested.index),
              let definition = currentIntegerDefinitionByIndex[requested.index] else {
            return nil
        }
        if definition.width == requested.width {
            return definition.value
        }
        return Self.projectIntegerValue(
            definition.value,
            fromWidth: definition.width,
            toWidth: requested.width
        )
    }

    private static func projectIntegerValue(
        _ value: MacIRValue,
        fromWidth: Int,
        toWidth: Int
    ) -> MacIRValue {
        guard fromWidth != toWidth else { return value }
        if fromWidth == 32 {
            return .unary(
                op: "(uint64_t)",
                value: .unary(op: "(uint32_t)", value: value)
            )
        }
        return .unary(op: "(uint32_t)", value: value)
    }

    private func isIntegerRegisterUnavailable(_ register: String) -> Bool {
        guard let view = Self.physicalIntegerView(for: register) else { return false }
        return isIntegerRegisterUnavailable(index: view.index)
    }

    private func isIntegerRegisterUnavailable(index: Int) -> Bool {
        if let binding = ssa?.current[index] { return binding.isUnavailable }
        return unavailableRegisterValues.contains("x\(index)")
            || unavailableRegisterValues.contains("w\(index)")
    }

    private static func physicalIntegerView(for register: String) -> (index: Int, width: Int)? {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "fp" {
            return (29, 64)
        }
        if normalized == "lr" {
            return (30, 64)
        }
        return MacIRBuilder.integerRegisterView(normalized)
    }

    private static func scalarFPView(for register: String) -> (index: Int, width: Int)? {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let prefix = normalized.first,
              prefix == "d" || prefix == "s" else {
            return nil
        }
        let suffix = normalized.dropFirst()
        guard !suffix.isEmpty,
              suffix.allSatisfy(\.isNumber),
              suffix == "0" || suffix.first != "0",
              let index = Int(suffix),
              (0...31).contains(index) else {
            return nil
        }
        return (index, prefix == "d" ? 64 : 32)
    }

    private static func scalarFPAlias(for register: String) -> String? {
        guard let view = scalarFPView(for: register),
              let prefix = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first else {
            return nil
        }
        return "\(prefix == "d" ? "s" : "d")\(view.index)"
    }

    /// Atomically turns one authoritative entry-stack location into a body
    /// binding and records the loaded argument as the destination register's
    /// current semantic value. Every prerequisite is checked before mutating
    /// either the parameter table or dataflow state.
    mutating func bindEntryStackArgumentIfProven(
        byteOffset: Int,
        accessByteWidth: Int,
        destinationRegister: String
    ) -> MacIRValue? {
        let resolvedByteOffset: Int
        if let ssa {
            guard ssa.entryStackMemoryIsPristine,
                  let displacement = ssa.stackPointerOffset,
                  let offset = Int64(exactly: byteOffset) else { return nil }
            let entryOffset = offset.addingReportingOverflow(displacement)
            guard !entryOffset.overflow, let exact = Int(exactly: entryOffset.partialValue) else { return nil }
            resolvedByteOffset = exact
        } else {
            guard stackDepth == 0 else { return nil }
            resolvedByteOffset = byteOffset
        }
        let byteOffset = resolvedByteOffset
        guard entrySPIsExact,
              byteOffset >= 0,
              accessByteWidth > 0,
              stackSlotValues[Int64(byteOffset)] == nil,
              localVariablesByOffset[Int64(byteOffset)] == nil else {
            return nil
        }

        let locatedRows = parameters.indices.filter { index in
            guard case let .entryStack(candidateOffset, _, _) = parameters[index].abiLocation else {
                return false
            }
            return candidateOffset == byteOffset
        }
        guard locatedRows.count == 1 else { return nil }

        let parameterIndex = locatedRows[0]
        var parameter = parameters[parameterIndex]
        guard parameter.evidence == .authoritativeUser || parameter.evidence == .authoritativeDebug,
              case let .entryStack(locationOffset, size, alignment) = parameter.abiLocation,
              locationOffset == byteOffset,
              size == accessByteWidth,
              alignment > 0,
              byteOffset.isMultiple(of: alignment) else {
            return nil
        }

        let bindingID = MacIRParameterBindingID.entryStack(byteOffset: byteOffset)
        if let existingBinding = parameter.bindingID {
            guard existingBinding == bindingID,
                  bodyProvenEntryStackBindings.contains(bindingID) else {
                return nil
            }
        } else {
            guard parameter.rebind(bindingID: bindingID, abiLocation: parameter.abiLocation) else {
                return nil
            }
        }

        let destination = destinationRegister
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let integerDestination = Self.physicalIntegerView(for: destination)
        let isScalarFPDestination = Self.scalarFPView(for: destination) != nil
        guard integerDestination != nil || isScalarFPDestination else { return nil }
        let argument = MacIRValue.argument(bindingID: bindingID)

        // Commit only after validation and successful construction of the full
        // parameter/dataflow update above.
        parameters[parameterIndex] = parameter
        bodyProvenEntryStackBindings.insert(bindingID)
        if let view = integerDestination {
            currentIntegerDefinitionByIndex[view.index] = IntegerRegisterDefinition(
                value: argument,
                width: view.width
            )
            if view.index == 0 {
                latestABIResultValue = argument
                hasUnmodeledABIResultWrite = false
            }
        } else {
            currentEntryStackArgumentByScalarFPRegister[destination] = argument
            if destination == "d0" || destination == "s0" {
                latestABIResultValue = argument
                hasUnmodeledABIResultWrite = false
            }
        }
        replaceSSAValue(for: destination, with: argument)
        return argument
    }

    private func parameter(for register: String) -> MacIRFunctionParameter? {
        guard let info = MacIRBuilder.argumentRegisterInfo(register) else { return nil }
        let bindingID: MacIRParameterBindingID = info.isFloat ? .simd(info.index) : .gpr(info.index)
        let matches = parameters.filter { parameter in
            guard parameter.bindingID == bindingID else { return false }
            guard info.isFloat,
                  let requestedView = Self.scalarFPView(for: register),
                  case let .simd(_, scalarWidth) = parameter.abiLocation else {
                return true
            }
            return scalarWidth == requestedView.width
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func richFragment(for register: String) -> MacIRValue? {
        guard let info = MacIRBuilder.argumentRegisterInfo(register) else { return nil }
        let matches = parameters.flatMap { parameter -> [(MacIRFunctionParameter, DarwinARM64RichParameterPiece)] in
            guard case let .composite(pieces)? = parameter.richLocation else { return [] }
            return pieces.compactMap { piece in
                switch piece.register {
                case let .simd(index, width) where info.isFloat && index == info.index && width == info.width:
                    return (parameter, piece)
                case let .gpr(index, width) where !info.isFloat && index == info.index && width == info.width:
                    return (parameter, piece)
                default:
                    return nil
                }
            }
        }
        guard matches.count == 1 else { return nil }
        let (parameter, piece) = matches[0]
        return .argumentFragment(rowID: parameter.id,
                                 byteOffset: piece.valueByteOffset, size: piece.size)
    }

    private func explicitType(for value: MacIRValue) -> String? {
        if let type = valueTypeHints[value] {
            return type
        }
        if case let .argument(bindingID) = value {
            let matches = parameters.filter { $0.bindingID == bindingID }
            return matches.count == 1 ? matches[0].type : nil
        }
        return nil
    }

    private mutating func recordRegisterTemporaryIfNeeded(for value: MacIRValue) {
        guard case let .register(name, version) = value,
              Self.shouldAssignTemporaryName(to: name),
              registerNameBindingsByValue[value] == nil else {
            return
        }

        let binding = MacIRNameBinding(
            target: .register(name: name, version: version),
            name: "tmp\(nextRegisterTemporaryIndex)",
            type: MacIRBuilder.typeHint(forRegister: name, byteWidth: nil),
            kind: .registerTemporary
        )
        registerNameBindingsByValue[value] = binding
        registerNameBindingOrder.append(value)
        nextRegisterTemporaryIndex += 1
    }

    private mutating func updateRegisterTemporaryType(_ type: String, for value: MacIRValue) {
        guard var binding = registerNameBindingsByValue[value] else { return }
        binding.type = type
        registerNameBindingsByValue[value] = binding
    }

    private static func shouldAssignTemporaryName(to register: String) -> Bool {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let prefix = normalized.first,
              prefix == "x" || prefix == "w",
              let index = Int(normalized.dropFirst()) else {
            return false
        }
        return (8...15).contains(index)
    }

    private static func returnRegister(for returnType: String?) -> String {
        guard let returnType else { return "x0" }
        return CallSignatureCatalog.returnRegister(for: returnType) ?? "x0"
    }
}


// MARK: - HOP-5c format-string variadic recovery

extension BuilderState {
    mutating func recordConstantStringAddress(_ address: UInt64, for value: MacIRValue) {
        guard resolvesConstantStrings, constantStrings[address] != nil else { return }
        constantStringAddressByValue[value] = address
    }

    mutating func propagateConstantStringAddress(from source: MacIRValue, to destination: MacIRValue) {
        guard resolvesConstantStrings, let address = constantStringAddressByValue[source] else { return }
        constantStringAddressByValue[destination] = address
    }

    mutating func recordStackPointerAlias(_ register: String, offset: Int64) {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.first == "x",
              let view = MacIRBuilder.integerRegisterView(normalized),
              view.width == 64, view.index < 29, offset >= 0 else { return }
        stackPointerAliasOffsetByGPR[view.index] = offset
    }

    mutating func clearStackPointerAlias(for register: String) {
        if register == "sp" || register == "wsp" {
            stackPointerAliasOffsetByGPR.removeAll(keepingCapacity: true)
            outgoingCallStackStores.removeAll(keepingCapacity: true)
            return
        }
        guard let view = MacIRBuilder.integerRegisterView(register) else { return }
        stackPointerAliasOffsetByGPR.removeValue(forKey: view.index)
    }

    /// Offset from the current SP of a memory base register, when it is SP or a proven alias.
    private func stackPointerOffset(ofBase base: String) -> Int64? {
        let normalized = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "sp" { return 0 }
        guard normalized.first == "x",
              let view = MacIRBuilder.integerRegisterView(normalized),
              view.width == 64 else { return nil }
        return stackPointerAliasOffsetByGPR[view.index]
    }

    mutating func invalidateOutgoingCallStackIfStackPointerBased(_ base: String) {
        guard stackPointerOffset(ofBase: base) != nil else { return }
        outgoingCallStackStores.removeAll(keepingCapacity: true)
    }

    /// `[base]` or `[base, #imm]` with base SP or a proven SP alias -> offset from current SP.
    /// Nil (and the area invalidated) for any other SP-based shape; nil otherwise.
    private mutating func outgoingCallStackOffset(memoryOperand: String) -> Int64? {
        let normalized = memoryOperand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else {
            if normalized.hasSuffix("!"),
               let base = MacIRBuilder.splitOperands(String(normalized.dropFirst())).first {
                invalidateOutgoingCallStackIfStackPointerBased(base)
            }
            return nil
        }
        let parts = MacIRBuilder.splitOperands(String(normalized.dropFirst().dropLast()))
        guard let base = parts.first, let baseOffset = stackPointerOffset(ofBase: base) else {
            return nil
        }
        let immediate: Int64?
        switch parts.count {
        case 1: immediate = 0
        case 2: immediate = MacIRBuilder.parseImmediate(parts[1])
        default: immediate = nil
        }
        guard let immediate else {
            // Register-indexed or extended form through SP: no exact key.
            outgoingCallStackStores.removeAll(keepingCapacity: true)
            return nil
        }
        let (offset, overflow) = baseOffset.addingReportingOverflow(immediate)
        guard !overflow, offset >= 0 else {
            outgoingCallStackStores.removeAll(keepingCapacity: true)
            return nil
        }
        return offset
    }

    private mutating func putOutgoingCallStackFact(
        _ value: MacIRValue,
        at offset: Int64,
        byteWidth: Int?,
        carrierKind: StackSlotCarrierKind?
    ) {
        guard let byteWidth, byteWidth > 0, let carrierKind,
              let width = Int64(exactly: byteWidth) else {
            outgoingCallStackStores.removeAll(keepingCapacity: true)
            return
        }
        outgoingCallStackStores = outgoingCallStackStores.filter { candidate, fact in
            let candidateEnd = candidate + Int64(fact.byteWidth)
            return candidateEnd <= offset || offset + width <= candidate
        }
        outgoingCallStackStores[offset] = StackSlotValueFact(
            value: value,
            byteWidth: byteWidth,
            carrierKind: carrierKind
        )
    }

    /// The value an outgoing-argument store writes. A 64-bit register whose exact bits were
    /// materialized by `mov`/`movz`/`movk` stores those bits; keeping them as an immediate lets a
    /// `double` constant passed through an x register (clang's usual idiom) read as its value.
    func outgoingCallStackValue(_ value: MacIRValue, storedFrom register: String) -> MacIRValue {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.first == "x",
              let bits = materializedImmediate(for: normalized) else { return value }
        return .immediate(Int64(bitPattern: bits))
    }

    mutating func recordOutgoingCallStackStore(
        _ value: MacIRValue,
        memoryOperand: String,
        byteWidth: Int?,
        carrierKind: StackSlotCarrierKind?
    ) {
        guard let offset = outgoingCallStackOffset(memoryOperand: memoryOperand) else { return }
        putOutgoingCallStackFact(value, at: offset, byteWidth: byteWidth, carrierKind: carrierKind)
    }

    mutating func recordOutgoingCallStackPairStore(
        _ first: MacIRValue,
        _ second: MacIRValue,
        memoryOperand: String,
        elementByteWidth: Int,
        firstCarrierKind: StackSlotCarrierKind?,
        secondCarrierKind: StackSlotCarrierKind?
    ) {
        guard let offset = outgoingCallStackOffset(memoryOperand: memoryOperand) else { return }
        putOutgoingCallStackFact(first, at: offset, byteWidth: elementByteWidth, carrierKind: firstCarrierKind)
        putOutgoingCallStackFact(
            second,
            at: offset + Int64(elementByteWidth),
            byteWidth: elementByteWidth,
            carrierKind: secondCarrierKind
        )
    }

    struct RecoveredFormatStringTail {
        var evidence: MacIRCallFormatStringEvidence
        var entries: [MacIRCallArgument]
        var observationScope: MacIRCallArgumentObservationScope
    }

    /// Binds a format-string call's anonymous arguments, or returns nil so the call keeps only
    /// its declared fixed arguments. Requires: a `format` attribute describing this variadic
    /// tail, a format argument proven to be a constant string of the attribute's kind, a format
    /// the parser fully understands, and for EVERY consumed argument an exact store of a
    /// compatible width and register bank into its Apple arm64 stack slot since the last call.
    func formatStringTail(
        signature: MacIRCallSignature,
        fixedEntries: [MacIRCallArgument]
    ) -> RecoveredFormatStringTail? {
        guard resolvesConstantStrings,
              signature.isVariadic,
              let format = signature.format,
              format.describesVariadicTail(fixedParameterCount: signature.parameters.count),
              let flavor = FormatStringParser.Flavor(attributeKind: format.kind) else {
            return nil
        }
        let formatPosition = format.formatIndex - 1
        guard let formatEntry = fixedEntries.first(where: {
                  $0.role == .fixed(sourcePosition: formatPosition)
              }),
              let address = constantStringAddressByValue[formatEntry.value],
              let constant = constantStrings[address] else {
            return nil
        }
        switch flavor {
        case .printf, .osLog:
            guard constant.kind == .cString else { return nil }
        case .foundation:
            guard constant.kind == .cfString else { return nil }
        }
        guard let parsed = FormatStringParser.arguments(of: constant.text, flavor: flavor) else {
            return nil
        }

        var entries: [MacIRCallArgument] = []
        for (ordinal, argument) in parsed.enumerated() {
            let location = MacIRCallFormatStringEvidence.tailLocation(ordinal: ordinal)
            guard case let .callStack(byteOffset, _, _) = location,
                  let fact = outgoingCallStackStores[Int64(byteOffset)] else {
                return nil
            }
            let value: MacIRValue
            if argument.isFloatingPoint {
                switch (fact.carrierKind, fact.byteWidth) {
                case (.scalarFP, 8):
                    value = fact.value
                case (.integer, 8):
                    // A double constant is often materialized as its bit pattern in an x
                    // register; show the double it denotes, never the integer bits.
                    guard case let .immediate(bits) = fact.value else { return nil }
                    let double = Double(bitPattern: UInt64(bitPattern: bits))
                    guard double.isFinite else { return nil }
                    value = .symbol("\(double)")
                default:
                    return nil
                }
            } else {
                guard fact.carrierKind == .integer,
                      fact.byteWidth == 8
                        || (fact.byteWidth == 4 && argument.readByteWidth == 4) else {
                    return nil
                }
                value = fact.value
            }
            entries.append(MacIRCallArgument(
                location: location,
                role: .anonymousVariadic(tailOrdinal: ordinal),
                value: value
            ))
        }
        let tailBytes = parsed.count * FormatStringParser.stackSlotSize
        guard let observationScope = MacIRCallArgumentObservationScope(
            callStackRanges: tailBytes > 0 ? [0..<tailBytes] : []
        ) else {
            return nil
        }
        return RecoveredFormatStringTail(
            evidence: MacIRCallFormatStringEvidence(
                kind: format.kind,
                formatSourcePosition: formatPosition,
                format: constant.text,
                formatAddress: address,
                formatStringKind: constant.kind,
                argumentTypes: parsed.map(\.type)
            ),
            entries: entries,
            observationScope: observationScope
        )
    }
}
