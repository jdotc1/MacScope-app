import Foundation
import Synchronization

/// Scoped configuration is inherited by structured child tasks, never persisted.
/// Detached tasks deliberately do not inherit it: pass explicit builder flags there.
/// withValue restores the enclosing scope on normal return, throw and cancellation;
/// a killed process has no preference write to recover.
public enum MacIRConfiguration {
    /// An explicitly installed, immutable test-run baseline also covers detached
    /// work and XCTest's async scheduling. Never inferred from process identity.
    public struct TestBaseline: Equatable, Sendable {
        public let ssa: Bool
        public let explicitCFG: Bool
        public let returnContract: Bool
        public init(ssa: Bool, explicitCFG: Bool, returnContract: Bool) {
            self.ssa = ssa
            self.explicitCFG = explicitCFG
            self.returnContract = returnContract
        }
    }
    private static let testBaseline = Mutex<TestBaseline?>(
        launchTestBaseline(environment: ProcessInfo.processInfo.environment))

    /// Explicit launch injection for installed-app tests, not a test-process
    /// heuristic. Normal launches without this key retain preference fallback.
    public static func launchTestBaseline(environment: [String: String]) -> TestBaseline? {
        guard let marker = environment["MACSCOPE_TEST_MODE_BASELINE"] else { return nil }
        precondition(marker == "1", "Invalid installed-test mode baseline")
        return .init(ssa: environment["MACSCOPE_SSA_LIFTER"] == "1",
                     explicitCFG: environment["MACSCOPE_EXPLICIT_CFG"] == "1",
                     returnContract: environment["MACSCOPE_RETURN_CONTRACT_TABLE"] == "1")
    }

    /// Idempotent installation; a test cannot mutate another suite's baseline.
    /// There is deliberately no reset: lifetime is the test runner process.
    public static func installTestBaseline(_ baseline: TestBaseline) -> Bool {
        testBaseline.withLock { current in
            guard current == nil || current == baseline else { return false }
            current = baseline
            return true
        }
    }

    public static var installedTestBaseline: TestBaseline? {
        testBaseline.withLock { $0 }
    }

    @TaskLocal public static var ssaOverride: Bool?
    @TaskLocal public static var explicitCFGOverride: Bool?
    @TaskLocal public static var returnContractOverride: Bool?

    /// Compatibility: only the exact string "1" enables a flag. Other values,
    /// including "0", fall through to the existing preference (not forced off).
    public static func enabled(environmentValue: String?, preference: @autoclosure () -> Bool) -> Bool {
        environmentValue == "1" || preference()
    }

    public static var ssaEnabled: Bool {
        ssaOverride ?? testBaseline.withLock { $0?.ssa } ?? enabled(environmentValue: ProcessInfo.processInfo.environment["MACSCOPE_SSA_LIFTER"],
                               preference: UserDefaults.standard.bool(forKey: "MacScopeSSALifter"))
    }

    public static var explicitCFGEnabled: Bool {
        explicitCFGOverride ?? testBaseline.withLock { $0?.explicitCFG } ?? enabled(environmentValue: ProcessInfo.processInfo.environment["MACSCOPE_EXPLICIT_CFG"],
                                       preference: UserDefaults.standard.bool(forKey: "MacScopeExplicitCFG"))
    }

    public static var returnContractEnabled: Bool {
        returnContractOverride ?? testBaseline.withLock { $0?.returnContract } ?? UserDefaults.standard.bool(forKey: "MacScopeReturnContractTable")
    }
}

public struct MacIRBuilder: Sendable {
    private let skipsRejectedCFGReconciliation: Bool
    private let nativeSignedWordCMPEnabled: Bool
    private let explicitCFGEnabled: Bool
    let ssaEnabled: Bool
    let ssaCancellation: @Sendable () -> Bool
    let ssaBeforeRenaming: (@Sendable () -> Void)?
    let ssaBeforeFinalization: (@Sendable () -> Void)?
    var ssaIsCancelled: Bool { Task.isCancelled || ssaCancellation() }

    public init(explicitCFGEnabled: Bool? = nil, ssaEnabled: Bool? = nil) {
        skipsRejectedCFGReconciliation = false
        let requestedSSA = ssaEnabled ?? MacIRConfiguration.ssaEnabled
        self.ssaEnabled = requestedSSA
        nativeSignedWordCMPEnabled = !requestedSSA
        ssaCancellation = { false }
        ssaBeforeRenaming = nil
        ssaBeforeFinalization = nil
        self.explicitCFGEnabled = explicitCFGEnabled ?? MacIRConfiguration.explicitCFGEnabled
    }

    /// Lexical proof lifts must independently certify every reconciled read.
    /// Ordinary callers retain rejected-CFG reconciliation without opting in.
    init(skippingRejectedCFGReconciliation: Bool, explicitCFGEnabled: Bool? = nil) {
        self.init(skippingRejectedCFGReconciliation: skippingRejectedCFGReconciliation,
                  explicitCFGEnabled: explicitCFGEnabled, nativeSignedWordCMPEnabled: true)
    }

    init(skippingRejectedCFGReconciliation: Bool, explicitCFGEnabled: Bool?,
         nativeSignedWordCMPEnabled: Bool) {
        skipsRejectedCFGReconciliation = skippingRejectedCFGReconciliation
        self.nativeSignedWordCMPEnabled = nativeSignedWordCMPEnabled
        ssaEnabled = false
        ssaCancellation = { false }
        ssaBeforeRenaming = nil
        ssaBeforeFinalization = nil
        self.explicitCFGEnabled = explicitCFGEnabled ?? MacIRConfiguration.explicitCFGEnabled
    }

    init(ssaEnabled: Bool, ssaCancellation: @escaping @Sendable () -> Bool,
         ssaBeforeRenaming: (@Sendable () -> Void)? = nil,
         ssaBeforeFinalization: (@Sendable () -> Void)? = nil) {
        skipsRejectedCFGReconciliation = false
        explicitCFGEnabled = true
        self.ssaEnabled = ssaEnabled
        nativeSignedWordCMPEnabled = !ssaEnabled
        self.ssaCancellation = ssaCancellation
        self.ssaBeforeRenaming = ssaBeforeRenaming
        self.ssaBeforeFinalization = ssaBeforeFinalization
    }

    public func buildFunction<RowSequence: Sequence>(
        name: String,
        startAddress: UInt64? = nil,
        endAddress: UInt64? = nil,
        jumpTables: [UInt64: [UInt64]] = [:],
        objcSelectors: [UInt64: String] = [:],
        constantStrings: [UInt64: MacIRConstantString] = [:],
        authoritativeParameterPlan: MacIRAuthoritativeParameterPlan? = nil,
        authoritativeReturnLocation: DarwinARM64RichReturnLocation? = nil,
        authoritativeReturnType: String? = nil,
        callerReturnWidth: MacIRCallerReturnEvidence.Width? = nil,
        authoredCallSignaturesByTarget: [String: FunctionSignatureOverride] = [:],
        directCallVoidResultTargets: [String: FunctionSignatureOverride] = [:],
        machineCallUsage: MacIRMachineCallUsage? = nil,
        machineUsageContext: MacIRMachineUsageContext? = nil,
        slotCallContracts: [UInt64: FunctionPointerSignatureV1] = [:],
        slotCallSignatures: [UInt64: MacIRCallSignature] = [:],
        richTypeResolver: TypeAtlasDarwinARM64LayoutResolver = TypeAtlasDarwinARM64LayoutResolver(),
        knownTailCallTargets: [UInt64: String] = [:],
        instructions rows: RowSequence
    ) -> MacIRFunction where RowSequence.Element: DecompilerInstructionRow {
        let materializedRows = Array(rows)
        // Balanced events let the test sink distinguish nested lexical builds
        // without storing diagnostics in BuilderState or changing its identity.
        var diagnosticBuildID: UUID? = nil
        if let sink = RejectedCFGDiagnostics.sink {
            let id = UUID()
            diagnosticBuildID = id
            sink(.buildBegin(id: id, name: name, start: startAddress ?? materializedRows.first?.address ?? 0))
        }
        defer {
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticBuildID {
                sink(.buildEnd(id: id))
            }
        }
        var ssaEntryBackedge = false
        var provenTailCallTargets: [UInt64: UInt64] = [:]
        let ssaFunctionRange: Range<UInt64>? = ssaEnabled ? materializedRows.first.flatMap { first in
            let lower = startAddress ?? first.address
            guard let last = materializedRows.last,
                  let upper = endAddress ?? last.address.addressAfter(), lower < upper else { return nil }
            return lower..<upper
        } : nil
        let ssaOutsideFunctionFallback = ssaFunctionRange.map { range in
            materializedRows.contains { row in
                let mnemonic = row.mnemonic.lowercased()
                guard range.contains(row.address),
                      mnemonic == "br" || mnemonic.hasPrefix("braa") || mnemonic.hasPrefix("brab"),
                      let targets = jumpTables[row.address] else { return false }
                return targets.contains { !range.contains($0) && knownTailCallTargets[$0] == nil }
            }
        } ?? false
        func attachingCFG(to original: MacIRFunction) -> MacIRFunction {
            if ssaEnabled && ssaIsCancelled {
                return Self.cancelledSSAFunction(name: name, startAddress: startAddress,
                    sources: materializedRows.map { .init(address: $0.address, byteText: $0.bytes,
                        mnemonic: $0.mnemonic.lowercased(), operands: $0.operands,
                        comment: $0.comment, structuredOperands: $0.structuredOperands) })
            }
            var result = original
            if explicitCFGEnabled || ssaEntryBackedge || ssaOutsideFunctionFallback {
                result.cfg = MacIRCFG.build(instructions: result.instructions,
                jumpTables: jumpTables, knownTailCallTargets: knownTailCallTargets,
                provenTailCallTargets: provenTailCallTargets,
                authoredCallSignaturesByTarget: authoredCallSignaturesByTarget,
                owningFunctionRange: ssaOutsideFunctionFallback ? ssaFunctionRange : nil)
                if let cfg = result.cfg {
                    result.refusals = cfg.refusals
                } else {
                    result.phis = []
                    result.refusals = [.init(reason: .cancelled, scope: .function, detail: nil)]
                }
            }
            if ssaEntryBackedge {
                result.refusals.append(.init(reason: .unknownEffects, scope: .function,
                    detail: "entry block has an in-graph predecessor"))
            }
            if ssaEnabled {
                ssaBeforeFinalization?()
                if ssaIsCancelled || result.refusals.contains(where: { $0.reason == .cancelled }) {
                    return Self.cancelledSSAFunction(name: name, startAddress: startAddress,
                        sources: materializedRows.map { .init(address: $0.address, byteText: $0.bytes,
                            mnemonic: $0.mnemonic.lowercased(), operands: $0.operands,
                            comment: $0.comment, structuredOperands: $0.structuredOperands) })
                }
            }
            return result
        }
        // Tail-call proof needs no state. Recover switches first so their
        // authority wins, then seed parameters exactly as ordinary calls do.
        let recoveredSwitches: [UInt64: RecoveredSwitch] = jumpTables.isEmpty
            ? [:] : Self.recoverSwitchDispatches(rows: materializedRows, jumpTables: jumpTables)
        let tailCalls = Self.provenTailCalls(rows: materializedRows,
            entry: startAddress ?? materializedRows.first?.address ?? 0,
            knownTargets: knownTailCallTargets, recoveredSwitches: Set(recoveredSwitches.keys),
            pathCompleteEnabled: ssaEnabled && MacIRConfiguration.returnContractEnabled)
        for row in materializedRows where tailCalls[row.address] != nil {
            if let target = MacIRTailCallProof.address(row.operands) {
                provenTailCallTargets[row.address] = target
            }
        }
        let parameterRows = Self.tailCallParameterRows(materializedRows, tailCalls: tailCalls)
        let parameters = authoritativeParameterPlan?.parameters
            ?? Self.recoverFunctionParameters(from: parameterRows)
        var state = BuilderState(parameters: parameters)
        // Preserve existing frame metadata for the entire function when an SP
        // modification cannot be expressed as a known immediate delta.
        state.hasUnknownStackPointerAdjustment = materializedRows.contains { row in
            let mnemonic = row.mnemonic.lowercased()
            let operands = Self.splitOperands(row.operands.lowercased())
            guard Self.argumentRegisterWrites(mnemonic: mnemonic, operands: operands).contains("sp") else { return false }
            if Self.scalarWritebackAddress(operands: operands)?.base == "sp" { return false }
            return !(["add", "sub"].contains(mnemonic) && operands.count == 3
                && operands[1] == "sp" && Self.parseImmediate(operands[2]) != nil)
        }
        state.signedBitfieldFunctionName = name
        state.authoritativeReturnLocation = authoritativeReturnLocation
        state.authoritativeReturnType = authoritativeReturnType
        state.callerReturnWidth = callerReturnWidth
        state.returnProducerEntryAddress = startAddress ?? materializedRows.first?.address
        state.returnProducerSources = materializedRows.map { row in
            MacIRSourceSpan(address: row.address, byteText: row.bytes,
                mnemonic: row.mnemonic.lowercased(), operands: row.operands,
                comment: row.comment, structuredOperands: row.structuredOperands)
        }
        state.authoredCallSignaturesByTarget = authoredCallSignaturesByTarget
        state.directCallVoidResultTargets = directCallVoidResultTargets
        state.machineUsageContext = machineUsageContext
        if let machineCallUsage,
           machineCallUsage.matches(expected: machineUsageContext, originalCaller: state.returnProducerSources) {
            state.machineCallUsage = machineCallUsage
        }
        state.richTypeResolver = richTypeResolver
        // Authored parameters are entry facts: plain GPR formals seed the entry
        // state and every CFG path reads them like recovered ones. Only plans
        // whose formals the joins cannot carry (variadic, non-GPR or rich
        // composite locations) keep the linear builder.
        let hasUnsupportedParameterPlan = authoritativeParameterPlan.map { plan in
            plan.isVariadic || plan.parameters.contains { parameter in
                guard case .gpr = parameter.abiLocation else { return true }
                return parameter.richLocation != nil
            }
        } ?? false
        if Self.attemptsGeneralVectorRegion(materializedRows) {
            // Image-wide facts are commonly present even when this function
            // has no instruction that can consume them. PC-relative address
            // formation and returning calls lift through ordinary per-row
            // semantics; proven jump tables become region switch blocks. A
            // call-site contract the region cannot carry still requires fallback.
            let hasRelevantExternalFacts = materializedRows.contains { row in
                guard Self.isGeneralVectorIndirectCall(row.mnemonic.lowercased()) else { return false }
                // These maps are not passed through the region operation wrapper.
                // A known-tail target key colliding with this call address is
                // conservatively left to the ordinary route, never inferred as a tail.
                return slotCallContracts[row.address] != nil || slotCallSignatures[row.address] != nil
                    || jumpTables[row.address] != nil || knownTailCallTargets[row.address] != nil
            }
            if let region = buildGeneralVectorRegion(name: name, startAddress: startAddress,
                rows: materializedRows, initialState: state, jumpTables: jumpTables,
                hasExternalFacts: hasRelevantExternalFacts || hasUnsupportedParameterPlan,
                isVariadic: authoritativeParameterPlan?.isVariadic ?? false) {
                return attachingCFG(to: Self.attachingStackStorage(to: region, rows: materializedRows))
            }
        }
        if Self.attemptsVectorControlRegion(materializedRows),
           let region = buildVectorControlRegion(name: name, startAddress: startAddress,
                rows: materializedRows, initialState: state,
                hasExternalFacts: !jumpTables.isEmpty || !objcSelectors.isEmpty ||
                    !constantStrings.isEmpty || hasUnsupportedParameterPlan) {
            return attachingCFG(to: Self.attachingStackStorage(to: region, rows: materializedRows))
        }
        // An adjacent quotient is only known to dominate MSUB in a straight-line
        // function. Conservatively decline this peephole around any branch/call.
        state.remainderFoldingAllowed = !materializedRows.contains { row in
            let mnemonic = row.mnemonic.lowercased()
            return mnemonic == "b" || mnemonic.hasPrefix("b.") || mnemonic.hasPrefix("bc.")
                || mnemonic.hasPrefix("br") || mnemonic.hasPrefix("bl")
                || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic)
        }
        // Carry the selref-slot -> selector-name map into per-instruction
        // lifting. Entirely gated on supplied data: when `objcSelectors` is empty
        // (every existing call site) none of the selector-provenance bookkeeping
        // ever fires and the emitted IR is byte-identical to today's output.
        state.objcSelectors = objcSelectors
        // HOP-5c: constant strings the analysis resolved (address -> text). Gated the same
        // way: empty means no adrp/add string provenance is tracked and no format-string
        // variadic tail is recovered.
        state.constantStrings = constantStrings
        // Switch and exact-address tail-call authority were computed before
        // parameter recovery; architectural rows remain unchanged for lifting.
        // Selector definitions to snapshot while lifting: the SSA value a proven
        // selector register holds right after its defining instruction (the bounds
        // `cmp` or the clamping `csel`), keyed by that instruction's address.
        var selectorCaptures: [UInt64: [(dispatchAddress: UInt64, register: String)]] = [:]
        for (dispatchAddress, recovered) in recoveredSwitches {
            guard let selector = recovered.selector else { continue }
            selectorCaptures[selector.definitionAddress, default: []].append(
                (dispatchAddress: dispatchAddress, register: selector.register)
            )
        }
        if ssaEnabled && !ssaOutsideFunctionFallback {
            if let function = buildSSAFunction(name: name, startAddress: startAddress, endAddress: endAddress,
                rows: materializedRows, initialState: state, jumpTables: jumpTables,
                recoveredSwitches: recoveredSwitches, tailCalls: tailCalls,
                isVariadic: authoritativeParameterPlan?.isVariadic ?? false,
                slotCallContracts: slotCallContracts, slotCallSignatures: slotCallSignatures,
                knownTailCallTargets: knownTailCallTargets) {
                return function
            }
            ssaEntryBackedge = true
        }
        var arithmeticRewrite = MacIRArithmeticRewrite()
        let scalarCFG = ScalarCFGStatePlan.admit(materializedRows,
            hasExternalFacts: !jumpTables.isEmpty || !objcSelectors.isEmpty ||
                !constantStrings.isEmpty || hasUnsupportedParameterPlan)
        var rejectedCFG = scalarCFG == nil
            ? RejectedCFGStatePlan(rows: materializedRows, jumpTables: jumpTables) : nil
        let scalarEntryState = state
        var scalarOutgoing: [Int: BuilderState] = [:]
        var scalarPhiDrafts: [ScalarCFGStatePlan.PhiDraft] = []
        var reconciliationFired = false
        var nativeLogicalPairs: [NativeSignedWordLogicalPair] = []
        var irInstructions = materializedRows.enumerated().flatMap { rowIndex, row -> [MacIRInstruction] in
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticBuildID {
                sink(.rowBegin(buildID: id, row: rowIndex, address: row.address))
            }
            defer {
                if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticBuildID {
                    sink(.rowEnd(buildID: id, row: rowIndex))
                }
            }
            if let scalarCFG, let blockIndex = scalarCFG.blockAtStart[rowIndex] {
                state = scalarCFG.incoming(for: blockIndex, entry: scalarEntryState,
                                           outgoing: scalarOutgoing, phis: &scalarPhiDrafts)
            } else if !skipsRejectedCFGReconciliation,
                      rejectedCFG?.reconcile(at: rowIndex, state: &state) == true {
                reconciliationFired = true
                arithmeticRewrite = MacIRArithmeticRewrite()
            }
            defer {
                if let scalarCFG, let blockIndex = scalarCFG.blockAtEnd[rowIndex] {
                    scalarOutgoing[blockIndex] = state
                }
            }
            let source = MacIRSourceSpan(
                address: row.address,
                byteText: row.bytes,
                mnemonic: row.mnemonic.lowercased(),
                operands: row.operands,
                comment: row.comment,
                structuredOperands: row.structuredOperands
            )
            if let widening = Self.neonWideningPairwise(source) {
                // A validated per-row descriptor, not a whole-function or ABI
                // exemption, also owns the ordinary legacy route.
                return [Self.liftNEONWideningPairwise(widening, source: source, state: &state)]
            }
            if let immediate = Self.neonBitClearImmediate(mnemonic: source.mnemonic, operandText: source.operands) {
                return Self.liftNEONBitClearImmediate(immediate, source: source, state: &state)
            }
            if Self.hasUnclaimedVectorOperand(source.operands) {
                // The retired whole-function routes cannot authorize a scalar
                // interpretation of an unclaimed Q/V instruction.
                return [generalVectorRefusal(row, state: &state)]
            }
            // One architectural tail branch expands to ordered call + return
            // effects at its original address. CFGBuilder already resolves an
            // address to its first effect and terminates at returnValue.
            if let tailCall = tailCalls[source.address] {
                var candidateState = state
                var callSource = source
                callSource.mnemonic = tailCall.callMnemonic
                callSource.operands = tailCall.callOperands
                callSource.structuredOperands = nil
                let call = operation(for: callSource, state: &candidateState,
                                     slotCallContract: slotCallContracts[source.address],
                                     slotCallSignature: slotCallSignatures[source.address])
                if case .call = call {
                    var returnSource = source
                    returnSource.mnemonic = "ret"
                    returnSource.operands = ""
                    returnSource.structuredOperands = nil
                    let returned: MacIROperation
                    if authoritativeReturnLocation == nil && callerReturnWidth == nil {
                        // A synthetic RET is not new evidence about this function's
                        // return contract. Preserve the existing unresolved marker.
                        let unresolved = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
                        candidateState.returnValue = unresolved
                        candidateState.returnType = state.returnType
                        returned = .returnValue(unresolved)
                    } else {
                        returned = operation(for: returnSource, state: &candidateState)
                    }
                    state = candidateState
                    return [MacIRInstruction(source: tailCall.source(source, phase: .call), operation: call),
                            MacIRInstruction(source: tailCall.source(source, phase: .returnAfterCall), operation: returned)]
                }
                // If existing call binding refuses, keep the original branch
                // and original state. No fallback signature is manufactured.
            }
            let returnTarget = source.mnemonic == "ret" && !source.operands.isEmpty
                ? Self.value(for: source.operands, state: state) : nil
            let lifted = Self.explicitComparisonTypes(
                scalarCFG?.selectForJoinMove(rowIndex: rowIndex, row: row,
                                             outgoing: scalarOutgoing, state: &state)
                    ?? operation(for: source, state: &state, recoveredSwitches: recoveredSwitches,
                                 slotCallContract: slotCallContracts[source.address],
                                 slotCallSignature: slotCallSignatures[source.address]),
                source: source, argumentBitWidths: state.argumentBitWidths, parameters: state.parameters
            )
            let arithmeticOperands = Self.splitOperands(source.operands)
            let recovered = arithmeticRewrite.rewrite(
                lifted, mnemonic: source.mnemonic,
                width: arithmeticOperands.first.flatMap(Self.scalarDataBitWidth),
                operandWidths: arithmeticOperands.dropFirst().map(Self.scalarDataBitWidth),
                address: source.address, allowSequence: state.remainderFoldingAllowed
            )
            if var pair = state.pendingNativeLogicalPair {
                pair.originalConsumer = recovered
                pair.replacementConsumer = Self.explicitComparisonTypes(
                    pair.replacementConsumer, source: source,
                    argumentBitWidths: state.argumentBitWidths, parameters: state.parameters)
                nativeLogicalPairs.append(pair)
                state.pendingNativeLogicalPair = nil
            }
            if !skipsRejectedCFGReconciliation {
                rejectedCFG?.capture(at: rowIndex, operation: lifted, state: state)
            }
            for capture in selectorCaptures[row.address] ?? [] {
                let selectorValue = Self.value(for: capture.register, state: state)
                state.provenSwitchSelectors[capture.dispatchAddress] = selectorValue
            }
            return [MacIRInstruction(source: source, operation: recovered,
                memoryAccess: Self.memoryAccess(for: source), returnTarget: returnTarget,
                scalarFP: Self.scalarFPSemantics(mnemonic: source.mnemonic,
                    operands: Self.splitOperands(source.operands)))]
        }

        irInstructions = Self.committingNativeLogicalPairs(nativeLogicalPairs, to: irInstructions)

        var rawFunction = MacIRFunction(
            name: name,
            startAddress: startAddress ?? materializedRows.first?.address ?? 0,
            endAddress: materializedRows.last.flatMap { $0.address.addressAfter() },
            returnType: state.returnType ?? "int64_t",
            isVariadic: authoritativeParameterPlan?.isVariadic ?? false,
            parameters: state.parameters,
            localVariables: state.recoveredLocalVariables,
            nameBindings: state.recoveredNameBindings,
            stackFrameSize: state.maxStackDepth,
            maxStackDisplacement: state.maxStackDisplacement,
            callTargets: state.callTargets,
            callSignatures: state.recoveredCallSignatures,
            returnValue: state.returnValue,
            instructions: irInstructions
        )
        if let scalarCFG {
            rawFunction.applyPhiResolution(scalarCFG.resolvePhiPresentation(
                scalarPhiDrafts, rows: materializedRows, outgoing: scalarOutgoing,
                instructions: irInstructions))
        }

        var function = attachingCFG(to: Self.attachingStackStorage(to: LocalTypeInferencePass.infer(function: rawFunction),
                                                 rows: materializedRows))
        if reconciliationFired && !function.refusals.contains(where: { $0.reason == .cancelled }) {
            // Snapshot the row protocol's complete input without retaining an
            // arbitrary caller-owned sequence. No twin is needed until a proof
            // reader asks for markers; semantic equality never asks for them.
            let lexicalRows = materializedRows.map { row in
                ReconciliationRow(address: row.address, bytes: row.bytes, mnemonic: row.mnemonic,
                    operands: row.operands, comment: row.comment, structuredOperands: row.structuredOperands)
            }
            let reconciled = function
            let entryBackedgeFallback = ssaEntryBackedge
            let lexicalCFGEnabled = explicitCFGEnabled || entryBackedgeFallback
            let lexicalNativeSignedCMPEnabled = nativeSignedWordCMPEnabled
            function.reconciliationEvidence = RegionalReconciliationEvidence {
                var lexical = MacIRBuilder(skippingRejectedCFGReconciliation: true,
                    explicitCFGEnabled: lexicalCFGEnabled,
                    nativeSignedWordCMPEnabled: lexicalNativeSignedCMPEnabled).buildFunction(
                    name: name, startAddress: startAddress, jumpTables: jumpTables,
                    objcSelectors: objcSelectors, constantStrings: constantStrings,
                    authoritativeParameterPlan: authoritativeParameterPlan,
                    authoritativeReturnLocation: authoritativeReturnLocation,
                    authoritativeReturnType: authoritativeReturnType, callerReturnWidth: callerReturnWidth,
                    authoredCallSignaturesByTarget: authoredCallSignaturesByTarget,
                    directCallVoidResultTargets: directCallVoidResultTargets,
                    machineCallUsage: machineCallUsage,
                    machineUsageContext: machineUsageContext,
                    slotCallContracts: slotCallContracts, slotCallSignatures: slotCallSignatures,
                    richTypeResolver: richTypeResolver, knownTailCallTargets: knownTailCallTargets,
                    instructions: lexicalRows)
                if entryBackedgeFallback {
                    // The refusal describes the attempted SSA route, not a
                    // difference between the two legacy operand lifts.
                    lexical.refusals.append(.init(reason: .unknownEffects, scope: .function,
                        detail: "entry block has an in-graph predecessor"))
                }
                var recorded = reconciled
                RegionalLexicalProof.record(reconciled: &recorded, lexical: lexical)
                return .init(markers: recorded.reconciliationMarkers,
                             nonMarkerDifference: recorded.nonMarkerDifference)
            }
        }
        return function
    }

    private struct ReconciliationRow: DecompilerInstructionRow, Sendable {
        let address: UInt64
        let bytes: String
        let mnemonic: String
        let operands: String
        let comment: String?
        let structuredOperands: InstructionOperands?
    }

    /// Preserve recursive callback declarators and C's unspecified/empty distinction.
    private static func functionPointerCastType(_ contract: FunctionPointerSignatureV1) -> String {
        var parameters = contract.parameters.map { parameter in
            parameter.functionPointerSignatureV1.map(functionPointerCastType) ?? parameter.type
        }
        if contract.isVariadic { parameters.append("...") }
        let list = parameters.isEmpty && !contract.hasUnspecifiedParameters
            ? "void" : parameters.joined(separator: ", ")
        return "\(contract.returnType) (*)(\(list))"
    }

    func operationForVectorRegion(for source: MacIRSourceSpan,
                                  state: inout BuilderState) -> MacIROperation {
        operation(for: source, state: &state)
    }

    func operation(
        for source: MacIRSourceSpan,
        state: inout BuilderState,
        recoveredSwitches: [UInt64: RecoveredSwitch] = [:],
        slotCallContract: FunctionPointerSignatureV1? = nil,
        slotCallSignature: MacIRCallSignature? = nil
    ) -> MacIROperation {
        // A26 (SSA only): a pending comparison survives rows that write no NZCV
        // and none of the registers it reads, within the same block. Branches,
        // calls, barriers and block entries clear it exactly as before.
        let adjacent = state.lastAdjacentComparison
        let pending = state.pendingConditionalCompare
        let destinationValue: MacIRValue? = ssaEnabled && (adjacent != nil || pending != nil)
            ? Self.splitOperands(source.operands).first.map { state.readRegister($0.lowercased()) }
            : nil
        let result = operationCore(
            for: source, state: &state, recoveredSwitches: recoveredSwitches,
            slotCallContract: slotCallContract, slotCallSignature: slotCallSignature)
        if ssaEnabled, adjacent != nil || pending != nil,
           Self.preservesPendingComparison(
            mnemonic: source.mnemonic,
            operands: Self.splitOperands(source.operands),
            adjacent: adjacent,
            pending: pending,
            destinationValue: destinationValue) {
            state.lastAdjacentComparison = adjacent
            state.pendingConditionalCompare = pending
        }
        mintNativeLogicalConditionalCertificate(source: source, operation: result, state: &state)
        return result
    }

    private func operationCore(
        for source: MacIRSourceSpan,
        state: inout BuilderState,
        recoveredSwitches: [UInt64: RecoveredSwitch] = [:],
        slotCallContract: FunctionPointerSignatureV1? = nil,
        slotCallSignature: MacIRCallSignature? = nil
    ) -> MacIROperation {
        let operands = Self.splitOperands(source.operands)
        // DP04 A3: memory addressing reads the row's complete typed sidecar.
        state.currentTypedMemory = Self.typedMemoryOperand(of: source)
        state.currentRowAddress = source.address
        defer { state.currentTypedMemory = nil; state.currentRowAddress = nil }
        let adjacentComparison = state.lastAdjacentComparison
        let pendingConditionalCompare = state.pendingConditionalCompare
        let precedingDivision = state.lastDivision.flatMap { $0.sourceAddress.addressAfter() == source.address ? $0 : nil }
        state.lastDivision = nil
        state.lastAdjacentComparison = nil
        state.pendingConditionalCompare = nil
        state.pendingNativeLogicalPair = nil

        if let adjacentComparison, let logical = adjacentComparison.nativeSignedWordLogical,
           !logical.writesRegister || logical.replacementProducer != nil {
            // Keep both legacy statements until the exact pair commits after collection.
            if let legacy = stagedNativeTSTOperation(for: source, operands: operands,
                comparison: adjacentComparison, state: &state) { return legacy }
        } else if let native = nativeLogicalConditionalOperation(
            for: source, operands: operands, adjacent: adjacentComparison,
            pending: pendingConditionalCompare, state: &state) {
            return native
        }

        // Arranged vector FP rows are owned by the multi-effect vector/SSA
        // dispatch. Never fall back to a legacy scalar numeric descriptor here.
        // Whole status-register accesses remain refused until split/merge is modeled.
        if MacIRFPBlockedEffect.requiresEnvironment(mnemonic: source.mnemonic, operands: source.operands)
            || MacIRFPBlockedEffect.isStatusAccess(source: source) {
            let inputs = Self.unknownInputs(mnemonic: source.mnemonic, operands: operands, state: state)
            let writesDestination = source.mnemonic.lowercased() != "msr"
            var destination: MacIRValue?
            if writesDestination, let name = operands.first,
               Self.ssaRegisterView(for: name) != nil, !Self.isZeroRegister(name) {
                destination = state.writeRegister(name)
                state.recordUnmodeledDefiniteWrite(for: name)
            }
            return .unknown(destination: destination, inputs: inputs,
                            mnemonic: source.mnemonic, operands: source.operands)
        }

        if let fp = Self.scalarFPSemantics(mnemonic: source.mnemonic, operands: operands) {
            let arguments = operands.dropFirst().prefix(fp.operation.arity).map { Self.value(for: $0, state: state) }
            let destination = state.writeRegister(operands[0])
            state.recordValueType(fp.storageResultType.cType, for: destination)
            return .intrinsic(destination: destination, name: fp.intrinsicName, arguments: arguments)
        }

        // Extended-register add/sub (`add/sub Xd, Xn, Wm, sxtw/uxtw #s`)
        // is distinct from the shifted-register data-processing form below: ARM64
        // logical ops do not take extended-register operands, and flag-setting
        // adds/subs stay in the comparison seam.
        if operands.count == 4,
           let operation = extendedRegisterDataProcessing(mnemonic: source.mnemonic, operands: operands, state: &state) {
            return operation
        }

        // Shifted-register data-processing (`add/sub/and/orr/eor Xd, Xn, Xm, lsl/lsr/asr #s`)
        // → `Xd = Xn OP (Xm << s)` (and `ror #s` → the rotate expression). Handled here so the
        // per-opcode 3-operand paths below stay unchanged; the extended-register (sxtw/uxtw)
        // forms and the flag-setting adds/subs fall through to the faithful low-level rendering.
        if operands.count == 4,
           let operation = shiftedRegisterDataProcessing(mnemonic: source.mnemonic, operands: operands, state: &state) {
            return operation
        }

        // Shifted-register bit-clear family (`bic/orn/eon Xd, Xn, Xm, lsl/lsr/asr #s`)
        // → `Xd = Xn OP ~(Xm SHIFT s)`. Kept separate from the plain shifted-register helper
        // because the complement must wrap the shifted (or rotated) value.
        if operands.count == 4,
           let operation = shiftedBitClearStyleOperation(mnemonic: source.mnemonic, operands: operands, state: &state) {
            return operation
        }

        switch source.mnemonic {
        case "sub",
             "subs",
             "adds",
             "add",
             "and",
             "eor",
             "mul",
             "sdiv", "udiv":
            if let operation = operationArithmeticCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "neg",
             "negs",
             "mvn",
             "bic",
             "orn",
             "eon",
             "movn":
            if let operation = operationUnaryCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "cmn",
             "cmp",
             "tst",
             "ands",
             "bics":
            if let operation = operationComparisonCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "lsl", "lsr", "asr",
             "sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw",
             "clz", "rbit", "rev", "rev16", "rev32":
            if let operation = operationBitTransformCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "ubfx",
             "sbfx",
             "ubfiz",
             "sbfiz",
             "bfi",
             "bfxil",
             "extr",
             "ror":
            if let operation = operationBitfieldCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "madd", "msub", "mneg":
            return multiplyAccumulateOperation(mnemonic: source.mnemonic, operands: operands, state: &state, division: precedingDivision)

        case "umull", "smull",
             "umaddl",
             "smaddl", "smsubl", "umsubl",
             "smulh", "umulh":
            if let operation = operationWideningMultiplyCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "orr",
             "mov", "movz",
             "movk",
             "fmov":
            if let operation = operationMoveCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "ldr", "ldur", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldurb", "ldurh", "ldursw", "ldursb", "ldursh":
            if let operation = operationScalarLoadCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "str", "stur", "strb", "strh", "sturb", "sturh":
            if let operation = operationScalarStoreCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "stp":
            if let operation = operationPairStoreCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "ldp", "ldpsw":
            if let operation = operationPairLoadCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "adr",
             "adrp":
            if let operation = operationAddressCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "bl":
            if let operation = operationDirectCallCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "blr", "blraa", "blrab", "blraaz", "blrabz":
            if let operation = operationIndirectCallCase(for: source, operands: operands, state: &state, slotCallContract: slotCallContract, slotCallSignature: slotCallSignature) {
                return operation
            }

        case "br", "braa", "brab", "braaz", "brabz":
            if let operation = operationRegisterBranchCase(for: source, operands: operands, state: &state, recoveredSwitches: recoveredSwitches) {
                return operation
            }

        case "ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr", "eret", "eretaa", "eretab":
            if let operation = operationReturnCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "ccmp", "ccmn":
            if let operation = operationConditionalCompareCase(for: source, operands: operands, state: &state, adjacentComparison: adjacentComparison, pendingConditionalCompare: pendingConditionalCompare) {
                return operation
            }

        case "nop",
             "brk",
             "pacibsp", "paciasp", "autibsp", "autiasp",
             "paciza", "pacizb", "pacia", "pacib",
             "autiza", "autizb", "autia", "autib",
             "xpaclri", "xpacd", "xpaci":
            if let operation = operationSimpleControlCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case _ where Self.modernTransparentPACIntrinsicNames.contains(source.mnemonic):
            // FEAT_PAuth_LR and the PAC 1716 hints: value-transparent like the
            // list above, but the 1716/171615 forms rewrite x17 in place.
            for register in Self.modernPACRegisterWrites(mnemonic: source.mnemonic) {
                state.recordUnmodeledDefiniteWrite(for: register)
            }
            return .intrinsic(destination: nil, name: source.mnemonic, arguments: [])

        case "fjcvtzs",
             "crc32b", "crc32h", "crc32w", "crc32x", "crc32cb", "crc32ch", "crc32cw", "crc32cx":
            if let operation = operationConvertCRCCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "b":
            guard let target = operands.first, !target.isEmpty else { break }
            return .intrinsic(destination: nil, name: "branch", arguments: [Self.value(for: target, state: state)])

        case "cbz", "cbnz",
             "tbz", "tbnz":
            if let operation = operationTestBranchCase(for: source, operands: operands, state: &state) {
                return operation
            }

        case "csel", "csinc", "csinv", "csneg",
             "cinc", "cinv", "cneg",
             "csetm":
            if let operation = operationConditionalSelectCase(for: source, operands: operands, state: &state, pendingConditionalCompare: pendingConditionalCompare) {
                return operation
            }

        case "cset":
            if let operation = operationConditionalSetCase(for: source, operands: operands, state: &state, pendingConditionalCompare: pendingConditionalCompare) {
                return operation
            }

        default:
            if let operation = operationConditionalBranchCase(for: source, operands: operands, state: &state, pendingConditionalCompare: pendingConditionalCompare) {
                return operation
            }

        }

        // HOP-2: bind what the unmodelled instruction reads to the SSA values
        // live before it, before any of its writes below are recorded.
        let unknownInputs = Self.unknownInputs(mnemonic: source.mnemonic, operands: operands, state: state)

        if Self.isConditionalCompareInstruction(source.mnemonic) {
            state.sawConditionalCompareSinceComparison = true
        } else if Self.writesNZCVFlags(source.mnemonic) {
            state.sawConditionalCompareSinceComparison = true
        }

        // Unsupported store/atomic forms can overwrite the incoming stack-argument
        // area even when their base address remains entry SP. Once that happens,
        // address equality no longer proves that a later load observes the formal.
        if Self.unmodeledMemoryWriteTargetsProvenStack(
            mnemonic: source.mnemonic,
            operands: operands,
            state: state
        ) {
            state.invalidateEntrySPProvenance()
            state.invalidateAllStackSlotValues()
        }

        // Writeback syntax is architectural evidence independent of whether this
        // particular load/store/SIMD/MTE mnemonic has a modeled operation. Preserve
        // the rendered unknown instruction, but never preserve stale base state.
        if let writebackBase = Self.explicitMemoryWritebackBase(operands: operands) {
            state.recordUnmodeledDefiniteWrite(for: writebackBase)
        }

        let definiteWrites = Self.argumentRegisterWrites(
            mnemonic: source.mnemonic,
            operands: operands
        )
        if let destination = Self.firstOperandWriteForUnknown(mnemonic: source.mnemonic, operands: operands) {
            let normalizedDestination = destination.lowercased()
            let isStackPointer = normalizedDestination == "sp" || normalizedDestination == "wsp"
            if isStackPointer {
                if Self.unknownClaimsFirstOperandWrite(mnemonic: source.mnemonic) {
                    state.recordUnmodeledDefiniteWrite(for: normalizedDestination)
                }
            } else if Self.unknownClaimsFirstOperandWrite(mnemonic: source.mnemonic) {
                // writeRegister is a strict superset of the bare cache clear:
                // it also bumps the SSA version (downstream reads bind to the
                // unknown's result, not the stale prior version) and clears
                // the void-return inference for w0/x0.
                let destinationValue = state.writeRegister(destination)
                var skippedMaterializedDestination = false
                for register in definiteWrites {
                    let normalized = register.lowercased()
                    if normalized == normalizedDestination, !skippedMaterializedDestination {
                        skippedMaterializedDestination = true
                        continue
                    }
                    state.recordUnmodeledDefiniteWrite(for: normalized)
                }
                return .unknown(
                    destination: destinationValue,
                    inputs: unknownInputs,
                    mnemonic: source.mnemonic,
                    operands: source.operands
                )
            }
            state.clearMaterializedImmediate(for: destination)
        }
        for register in definiteWrites {
            state.recordUnmodeledDefiniteWrite(for: register)
        }
        return .unknown(destination: nil, inputs: unknownInputs, mnemonic: source.mnemonic, operands: source.operands)
    }

    @inline(never)
    private func operationBitfieldCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "ubfx":
            // ubfx Xd, Xn, #lsb, #width zero-extends a bit field, so its C
            // semantics are exactly (Xn >> lsb) & ((1 << width) - 1).
            if let operation = unsignedBitfieldExtractOperation(operands: operands, state: &state) {
                return operation
            }

        case "sbfx":
            if let operation = signedBitfieldExtractOperation(operands: operands, state: &state) {
                return operation
            }

        case "ubfiz":
            if let operation = bitfieldInsertZeroOperation(operands: operands, signed: false, state: &state) {
                return operation
            }

        case "sbfiz":
            if let operation = bitfieldInsertZeroOperation(operands: operands, signed: true, state: &state) {
                return operation
            }

        case "bfi":
            if let operation = bitfieldInsertOperation(operands: operands, state: &state) {
                return operation
            }

        case "bfxil":
            if let operation = bitfieldExtractInsertLowOperation(operands: operands, state: &state) {
                return operation
            }

        case "extr":
            if let operation = extractRegisterPairOperation(operands: operands, state: &state) {
                return operation
            }

        case "ror":
            if let operation = rotateRightOperation(operands: operands, state: &state) {
                return operation
            }

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationWideningMultiplyCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "umull", "smull":
            if let operation = wideningMultiplyOperation(mnemonic: source.mnemonic, operands: operands, state: &state) {
                return operation
            }

        case "umaddl":
            if let operation = unsignedMultiplyAddLongOperation(operands: operands, state: &state) {
                return operation
            }

        case "smaddl", "smsubl", "umsubl":
            if let operation = longMultiplyAccumulateOperation(mnemonic: source.mnemonic, operands: operands, state: &state) {
                return operation
            }

        case "smulh", "umulh":
            if let operation = highMultiplyOperation(mnemonic: source.mnemonic, operands: operands, state: &state) {
                return operation
            }

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationSimpleControlCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "nop":
            return .intrinsic(destination: nil, name: "nop", arguments: [])

        case "brk":
            guard operands.count == 1,
                  let immediate = Self.parseImmediate(operands[0]) else { break }
            return .intrinsic(destination: nil, name: "brk", arguments: [.immediate(immediate)])

        case "pacibsp", "paciasp", "autibsp", "autiasp",
             "paciza", "pacizb", "pacia", "pacib",
             "autiza", "autizb", "autia", "autib",
             "xpaclri", "xpacd", "xpaci":
            return .intrinsic(destination: nil, name: source.mnemonic, arguments: [])

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationArithmeticCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "sub":
            guard operands.count == 3, Self.hasOnlyScalarGPROperands(operands) else { break }
            if operands[0] == "sp", operands[1] == "sp", let amount = Self.parseImmediate(operands[2]) {
                state.allocateStack(amount)
                let destination = state.writeRegister("sp")
                return .intrinsic(destination: destination, name: "stack_alloc", arguments: [.immediate(amount)])
            }
            return binaryOperation("-", operands: operands, state: &state)

        case "subs":
            guard operands.count == 3 else { break }
            return flagSettingSubtractionOperation(operands: operands, sourceAddress: source.address, state: &state)

        case "adds":
            guard operands.count == 3 else { break }
            return flagSettingAdditionOperation(operands: operands, sourceAddress: source.address, state: &state)

        case "add":
            guard operands.count == 3, Self.hasOnlyScalarGPROperands(operands) else { break }
            if operands[0] == "sp", operands[1] == "sp", let amount = Self.parseImmediate(operands[2]) {
                state.freeStack(amount)
                let destination = state.writeRegister("sp")
                return .intrinsic(destination: destination, name: "stack_free", arguments: [.immediate(amount)])
            }
            // Selector provenance: the adrp+add+ldr selref idiom materializes the
            // slot base as `add xD, xN, #off` where xN already holds an adrp page
            // base. Capture the propagated absolute base BEFORE binaryOperation
            // writes the destination (which clears it), then re-record it so the
            // following `ldr [xD]` reconstructs the same slot. Gated on active
            // selector resolution; purely additive bookkeeping — the emitted IR is
            // unchanged.
            var propagatedSelectorPageBase: UInt64?
            if state.tracksAdrpPageBases,
               let sourceBase = state.adrpPageBase(for: operands[1]),
               let offset = Self.parseImmediate(operands[2]),
               offset >= 0,
               UInt64(offset) <= UInt64.max - sourceBase {
                propagatedSelectorPageBase = sourceBase + UInt64(offset)
            }
            let addOperation = binaryOperation("+", operands: operands, state: &state)
            if let propagatedSelectorPageBase {
                state.recordAdrpPageBase(propagatedSelectorPageBase, for: operands[0])
                state.recordConstantStringAddress(
                    propagatedSelectorPageBase,
                    for: Self.value(for: operands[0], state: state)
                )
            }
            if operands[1].lowercased() == "sp",
               let offset = Self.parseImmediate(operands[2]) {
                state.recordStackPointerAlias(operands[0], offset: offset)
            }
            return addOperation

        case "and":
            guard operands.count == 3 else { break }
            return binaryOperation("&", operands: operands, state: &state)

        case "eor":
            guard operands.count == 3 else { break }
            return binaryOperation("^", operands: operands, state: &state)

        case "mul":
            guard operands.count == 3 else { break }
            // Only SSA scalar MUL changes; legacy retains the exact binaryOperation path.
            if ssaEnabled, let width = Self.scalarDataBitWidth(operands[0]),
               operands.dropFirst().allSatisfy({ Self.scalarDataBitWidth($0) == width }) {
                let left = Self.value(for: operands[1], state: state)
                let right = Self.value(for: operands[2], state: state)
                let destination = state.writeRegister(operands[0])
                return .binary(destination: destination, op: "*",
                    left: Self.unsignedCast(left, width: width),
                    right: Self.unsignedCast(right, width: width))
            }
            return binaryOperation("*", operands: operands, state: &state)

        case "sdiv", "udiv":
            guard operands.count == 3, Self.hasOnlyScalarGPROperands(operands),
                  let width = Self.scalarDataBitWidth(operands[0]),
                  operands.dropFirst().allSatisfy({ Self.scalarDataBitWidth($0) == width }) else { break }
            let arguments = operands.dropFirst().map { Self.value(for: $0, state: state) }
            let destination = state.writeRegister(operands[0])
            if state.remainderFoldingAllowed, !Self.isZeroRegister(operands[0]) {
                state.lastDivision = BuilderDivision(quotient: destination, dividend: arguments[0], divisor: arguments[1],
                                                     width: width, signed: source.mnemonic == "sdiv", sourceAddress: source.address)
            }
            return .intrinsic(destination: destination, name: "a64_\(source.mnemonic)\(width)", arguments: arguments)

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationUnaryCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "neg":
            // neg Xd, Xm aliases `sub Xd, XZR, Xm`: Xd = -Xm. Only the
            // two-operand form has unambiguous semantics; the shifted form has
            // three operands and falls through to the faithful low-level form.
            guard operands.count == 2 else { break }
            let source = Self.value(for: operands[1], state: state)
            let destination = state.writeRegister(operands[0])
            return .assign(destination: destination, source: .unary(op: "-", value: source))

        case "negs":
            // negs Xd, Xm aliases `subs Xd, XZR, Xm`: Xd = -Xm and set flags.
            // Mirror the subs split so a downstream conditional folds.
            guard operands.count == 2 else { break }
            return flagSettingNegationOperation(operands: operands, sourceAddress: source.address, state: &state)

        case "mvn":
            // mvn Xd, Xm aliases `orn Xd, XZR, Xm`: Xd = ~Xm. Two-operand form
            // only; the shifted form has three operands and falls through.
            guard operands.count == 2 else { break }
            let source = Self.value(for: operands[1], state: state)
            let destination = state.writeRegister(operands[0])
            return .assign(destination: destination, source: .unary(op: "~", value: source))

        case "bic":
            // bic Xd, Xn, Xm: Xd = Xn & ~Xm. The shifted-register form has more
            // than three operands and falls through to the faithful form.
            guard operands.count == 3, !Self.hasUnclaimedVectorOperand(source.operands) else { break }
            return bitClearStyleOperation("&", operands: operands, state: &state)

        case "orn":
            // orn Xd, Xn, Xm: Xd = Xn | ~Xm.
            guard operands.count == 3 else { break }
            return bitClearStyleOperation("|", operands: operands, state: &state)

        case "eon":
            // eon Xd, Xn, Xm: Xd = Xn ^ ~Xm.
            guard operands.count == 3 else { break }
            return bitClearStyleOperation("^", operands: operands, state: &state)

        case "movn":
            // movn Xd, #imm loads ~imm. Only the canonical two-operand,
            // non-shifted immediate form is folded to a single constant; the
            // shifted form (three operands) and register forms fall through.
            guard operands.count == 2, let immediate = Self.parseImmediate(operands[1]) else { break }
            let folded = Int64(bitPattern: ~UInt64(bitPattern: immediate))
            let destination = state.writeRegister(operands[0])
            return .assign(destination: destination, source: .immediate(folded))

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationComparisonCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "cmn":
            // cmn Xn, Xm aliases `adds XZR, Xn, Xm`: it compares Xn against -Xm.
            // Seed the comparison as (Xn, -Xm) so a following conditional folds,
            // paralleling how cmp seeds (Xn, Xm).
            guard operands.count == 2 || operands.count == 3 else { break }
            if operands.count == 3 {
                guard let operation = threeOperandComparisonOperation(
                    mnemonic: source.mnemonic,
                    operands: operands,
                    sourceAddress: source.address,
                    state: &state
                ) else {
                    break
                }
                return operation
            }
            return twoOperandComparisonOperation(
                mnemonic: source.mnemonic,
                operands: operands,
                sourceAddress: source.address,
                state: &state
            )

        case "cmp":
            guard operands.count == 2 || operands.count == 3 else { break }
            let comparisonOperation: MacIROperation
            if operands.count == 3 {
                guard let operation = threeOperandComparisonOperation(
                    mnemonic: source.mnemonic,
                    operands: operands,
                    sourceAddress: source.address,
                    state: &state
                ) else {
                    break
                }
                comparisonOperation = operation
            } else {
                comparisonOperation = twoOperandComparisonOperation(
                    mnemonic: source.mnemonic,
                    operands: operands,
                    sourceAddress: source.address,
                    state: &state
                )
            }
            if !ssaEnabled, nativeSignedWordCMPEnabled,
               Self.isExactNativeWordCMPImmediate(source),
               var comparison = state.lastComparison,
               comparison.sourceAddress == source.address {
                comparison.nativeSignedWordCMPSource = source
                state.recordPlainComparison(comparison)
            }
            return comparisonOperation

        case "tst":
            guard let operation = testComparisonOperation(
                operands: operands,
                sourceAddress: source.address,
                state: &state
            ) else {
                break
            }
            return operation

        case "ands":
            guard let operation = flagSettingLogicalOperation(
                mnemonic: source.mnemonic,
                operands: operands,
                sourceAddress: source.address,
                state: &state
            ) else {
                break
            }
            return operation

        case "bics":
            guard let operation = flagSettingLogicalOperation(
                mnemonic: source.mnemonic,
                operands: operands,
                sourceAddress: source.address,
                state: &state
            ) else {
                break
            }
            return operation

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationBitTransformCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "lsl", "lsr", "asr":
            guard operands.count == 3,
                  Self.hasOnlyScalarGPROperands(operands),
                  let bitWidth = Self.scalarDataBitWidth(operands[0]) else { break }
            let amount = Self.value(for: operands[2], state: state)
            let immediate = Self.parseImmediate(operands[2])
            if let immediate, !(0..<Int64(bitWidth)).contains(immediate) { break }
            let sourceValue = Self.shiftOperand(Self.value(for: operands[1], state: state), mnemonic: source.mnemonic, width: bitWidth)
            let destination = state.writeRegister(operands[0])
            return .binary(destination: destination, op: Self.shiftOperator(for: source.mnemonic), left: sourceValue,
                           right: immediate == nil ? Self.shiftAmountModWidth(amount, bitWidth: bitWidth) : amount)

        case "sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw":
            // Width/sign extension aliases of SBFM/UBFM. Render as a C cast of
            // the source register. Two-operand form only.
            guard operands.count == 2,
                  source.mnemonic != "uxtw" || Self.hasOnlyRound2ScalarGPROperands(operands) else { break }
            // Read the source before writing the destination so in-place forms
            // (for example sxtw x0, w0) observe the incoming version.
            let castSource = Self.value(for: operands[1], state: state)
            let castDestination = state.writeRegister(operands[0])
            return .assign(
                destination: castDestination,
                source: .unary(op: Self.extensionCast(for: source.mnemonic), value: castSource)
            )

        case "clz", "rbit", "rev", "rev16", "rev32":
            // Single-source bit/byte transforms with no direct C operator;
            // render as a faithful intrinsic call. Two-operand form only.
            guard operands.count == 2 else { break }
            // Read the source before writing the destination so in-place forms
            // (for example rbit x0, x0) observe the incoming version.
            let transformSource = Self.value(for: operands[1], state: state)
            let transformDestination = state.writeRegister(operands[0])
            return .intrinsic(
                destination: transformDestination,
                name: source.mnemonic,
                arguments: [transformSource]
            )

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationMoveCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "orr":
            guard operands.count == 3 else { break }
            let left = Self.value(for: operands[1], state: state)
            let right = Self.value(for: operands[2], state: state)
            let destination = state.writeRegister(operands[0])
            if left == .immediate(0) {
                return .assign(destination: destination, source: right)
            }
            if right == .immediate(0) {
                return .assign(destination: destination, source: left)
            }
            return .binary(destination: destination, op: "|", left: left, right: right)

        case "mov", "movz":
            guard let materializedImmediate = Self.moveMaterializedImmediate(mnemonic: source.mnemonic, operands: operands),
                  Self.hasOnlyScalarGPROperands(operands) else {
                guard operands.count == 2 else { break }
                let sourceValue = Self.value(for: operands[1], state: state)
                let destination = state.writeRegister(operands[0])
                state.propagateValueType(from: sourceValue, to: destination)
                state.recordFrameBase(destination: operands[0], source: operands[1])
                if operands[1].lowercased() == "sp" {
                    state.recordStackPointerAlias(operands[0], offset: 0)
                }
                state.propagateConstantStringAddress(from: sourceValue, to: destination)
                if let immediate = Self.moveMaterializedImmediate(mnemonic: source.mnemonic, operands: operands) {
                    state.recordMaterializedImmediate(immediate, for: operands[0])
                }
                return .assign(destination: destination, source: sourceValue)
            }
            let destination = state.writeRegister(operands[0])
            state.recordMaterializedImmediate(materializedImmediate, for: operands[0])
            return .assign(destination: destination, source: .immediate(Int64(bitPattern: materializedImmediate)))

        case "movk":
            if let operation = moveKeepOperation(operands: operands, state: &state) {
                return operation
            }
            if let operation = standaloneMoveKeepOperation(operands: operands, state: &state) {
                return operation
            }
            if let destination = operands.first {
                state.clearMaterializedImmediate(for: destination)
            }

        case "fmov":
            if let operation = fmovScalarBitMoveOperation(operands: operands, state: &state) {
                return operation
            }
            if let operation = fmovScalarImmediateOperation(operands: operands, state: &state) {
                return operation
            }
            if let operation = fmovIncomingScalarParameterMoveOperation(
                operands: operands,
                state: &state
            ) {
                return operation
            }

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationAddressCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "adr":
            guard operands.count == 2,
                  Self.hasOnlyScalarGPROperands(operands),
                  Self.scalarRegisterBitWidth(operands[0]) == 64 else {
                break
            }
            let destination = state.writeRegister(operands[0])
            // HOP-5c: ld64's LOH rewrite turns `adrp`+`add` into `adr`+`nop`.
            if let address = Self.parseImmediate(operands[1]), address >= 0 {
                state.recordConstantStringAddress(UInt64(address), for: destination)
            }
            return .assign(destination: destination, source: Self.value(for: operands[1], state: state))

        case "adrp":
            guard operands.count == 2 else { break }
            let destination = state.writeRegister(operands[0])
            // Selector provenance: the real disassembler renders adrp with a
            // RESOLVED absolute page base immediate (e.g. `adrp x1, 0x100008000`).
            // Record it so a following selref `ldr x1, [x1, #off]` can compute the
            // slot address. Gated on active selector resolution; the symbolic
            // `_sym@PAGE` form used by some synthetic inputs does not parse to an
            // immediate and is simply ignored.
            if state.tracksAdrpPageBases,
               let selectorRegister = Self.canonical64BitSelectorRegister(operands[0]),
               let pageBase = Self.parseImmediate(operands[1]),
               pageBase >= 0 {
                state.recordAdrpPageBase(UInt64(pageBase), for: selectorRegister)
            }
            return .intrinsic(
                destination: destination,
                name: "adrp",
                arguments: [Self.value(for: operands[1], state: state)]
            )

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationDirectCallCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "bl":
            guard Self.hasValidReturningCallOperands(mnemonic: source.mnemonic, operands: operands),
                  let target = operands.first else { break }
            if let rich = state.authoredRichCall(target: target) {
                guard state.selectSSACallOutcome(.authoredRich) else { break }
                state.invalidateAppleCallerSavedState()
                let result: MacIRValue?
                switch rich.returnLocation {
                case let .composite(pieces):
                    let values = pieces.compactMap { piece -> MacIRValue? in
                        switch piece.register {
                        case let .simd(index, width):
                            return state.writeRegister("\(width == 64 ? "d" : "s")\(index)")
                        case let .gpr(index, width):
                            return state.writeRegister("\(width == 64 ? "x" : "w")\(index)")
                        }
                    }
                    result = values.count == pieces.count
                        ? .abiComposite(type: rich.returnType, fragments: values)
                        : nil
                case let .single(register):
                    switch register {
                    case let .gpr(index, width):
                        result = state.writeRegister("\(width == 64 ? "x" : "w")\(index)")
                    case let .simd(index, width):
                        result = state.writeRegister("\(width == 64 ? "d" : "s")\(index)")
                    }
                case .indirect:
                    // x8 is a pre-call result-buffer address, not a returned
                    // scalar register. The frame keeps it separately.
                    result = nil
                default:
                    result = nil
                }
                if case .single(_) = rich.returnLocation, let result {
                    state.recordValueType(rich.returnType, for: result)
                }
                state.recordCall(target, signature: nil)
                return .call(frame: rich.frame, result: result)
            }
            // Exact authored scalar authority precedes the permissive catalog fallback.
            let authoredScalar = state.authoredScalarCall(target: target)
            let signature = authoredScalar?.signature ?? Self.knownCallSignature(for: target)
            guard let frame = state.callFrame(
                target: target,
                knownSignature: signature,
                controlInputs: .none,
                recoverObjectiveCTail: state.resolvesObjCSelectors
                    && Self.isObjCMessageSendTarget(target)
            ) else { break }
            guard state.selectSSACallOutcome(.fallback) else { break }
            state.invalidateAppleCallerSavedState()
            let returnOnlyVoid: Bool
            if signature == nil, state.authoredCallSignaturesByTarget[target] == nil,
               let contract = state.directCallVoidResultTargets[target],
               contract.returnType == "void",
               case .unspecified = contract.parameterList,
               contract.variadicState == .unspecified {
                returnOnlyVoid = true
            } else {
                returnOnlyVoid = false
            }
            // Reserve the omitted result's version without making a value available.
            // Subsequent definitions keep their names and the call clobber remains intact.
            if returnOnlyVoid {
                state.registerVersions["x0"] = max(state.registerVersions["x0", default: 0] + 1,
                                                   state.registerVersionFloor + 1)
            }
            let result: MacIRValue?
            if signature?.returnsVoid == true || returnOnlyVoid {
                result = nil
            } else if let register = authoredScalar?.resultRegister {
                // The strict binder, not a spelling heuristic, owns typedef return carriers.
                result = state.writeRegister(register)
            } else {
                result = state.writeCallResult(returnType: signature?.returnType)
            }
            if let result, let returnType = signature?.returnType {
                state.recordValueType(returnType, for: result)
            }
            state.recordCall(target, signature: signature)
            return .call(frame: frame, result: result)

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationReturnCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr", "eret", "eretaa", "eretab":
            // ret + the arm64e authenticated returns retaa/retab (every PAC-protected epilogue),
            // plus the exception returns eret/eretaa/eretab (kernel/driver) — all control-flow exits.
            let returnValue = state.preferredReturnValue()
            state.returnValue = returnValue
            if let returnValue, let returnType = state.returnTypeHint(for: returnValue) {
                state.returnType = returnType
            } else if returnValue == nil, state.shouldInferVoidReturn {
                state.returnType = "void"
            }
            return .returnValue(returnValue)

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationConvertCRCCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "fjcvtzs":
            // FJCVTZS Wd, Dn: named intrinsic; it also writes NZCV (Z = exact).
            guard operands.count == 2,
                  !Self.isZeroRegister(operands[0].lowercased()) else { break }
            let convertSource = Self.value(for: operands[1], state: state)
            let convertDestination = state.writeRegister(operands[0])
            state.sawConditionalCompareSinceComparison = true
            return .intrinsic(destination: convertDestination, name: "fjcvtzs", arguments: [convertSource])

        case "crc32b", "crc32h", "crc32w", "crc32x", "crc32cb", "crc32ch", "crc32cw", "crc32cx":
            // CRC32{C}{B,H,W,X} Wd, Wn, {W,X}m: named intrinsic with a W result.
            guard operands.count == 3,
                  !Self.isZeroRegister(operands[0].lowercased()) else { break }
            let crcAccumulator = Self.value(for: operands[1], state: state)
            let crcData = Self.value(for: operands[2], state: state)
            let crcDestination = state.writeRegister(operands[0])
            return .intrinsic(
                destination: crcDestination,
                name: source.mnemonic,
                arguments: [crcAccumulator, crcData]
            )

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationTestBranchCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "cbz", "cbnz":
            guard operands.count == 2 else { break }
            return .conditionalBranch(
                condition: source.mnemonic == "cbz" ? "==" : "!=",
                left: Self.value(for: operands[0], state: state),
                right: .immediate(0),
                target: Self.value(for: operands[1], state: state)
            )

        case "tbz", "tbnz":
            guard operands.count == 3,
                  let bit = Self.parseImmediate(operands[1]),
                  bit >= 0,
                  bit < 64 else {
                break
            }
            return .conditionalBranch(
                condition: source.mnemonic == "tbz" ? "==" : "!=",
                left: .bitTest(value: Self.value(for: operands[0], state: state), bit: bit),
                right: .immediate(0),
                target: Self.value(for: operands[2], state: state)
            )

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationIndirectCallCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState,
        slotCallContract: FunctionPointerSignatureV1?, slotCallSignature: MacIRCallSignature?
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "blr", "blraa", "blrab", "blraaz", "blrabz":
            // blr Xn (+ the arm64e authenticated blraa/blrab/blraaz/blrabz) is an indirect
            // branch-with-link (indirect CALL). operands[0] is the target register; the
            // authenticated forms carry a separate PAC-modifier control input.
            // Capture both controls and arguments before applying the call boundary.
            guard Self.hasValidReturningCallOperands(mnemonic: source.mnemonic, operands: operands),
                  let targetRegisterName = operands.first?.lowercased(),
                  let targetRegister = MacIRCallControlRegister(register: targetRegisterName),
                  let canonicalTargetRegisterName = targetRegister.registerName else { break }
            let indirectTarget = "(*\(canonicalTargetRegisterName))"
            var controlEntries = [MacIRCallControlInput(
                role: .indirectTarget,
                register: targetRegister,
                value: state.readRegister(canonicalTargetRegisterName)
            )]
            if source.mnemonic == "blraa" || source.mnemonic == "blrab" {
                guard let modifierName = operands.last?.lowercased(),
                      let modifierRegister = MacIRCallControlRegister(register: modifierName),
                      let canonicalModifierName = modifierRegister.registerName else { break }
                controlEntries.append(MacIRCallControlInput(
                    role: .pointerAuthenticationModifier,
                    register: modifierRegister,
                    value: state.readRegister(canonicalModifierName)
                ))
            }
            guard let controlInputs = MacIRCallControlInputs(controlEntries) else { break }
            // Reuse the scalar ABI capture logic without pretending the indirect
            // control value is a direct callee. The temporary frame never escapes.
            var captureSignature = slotCallSignature
            captureSignature?.target = "__slot_argument_capture"
            if let contract = slotCallContract, let signature = slotCallSignature,
               let captureSignature,
               signature.target == indirectTarget,
               !contract.hasUnspecifiedParameters, !contract.isVariadic,
               let captured = state.callFrame(target: captureSignature.target,
                   knownSignature: captureSignature, controlInputs: .none, recoverObjectiveCTail: false),
               captured.arguments.canonicalPhysicalEntriesForAudit.count == signature.parameters.count,
               let frame = MacIRCallFrame(target: indirectTarget, knownSignature: nil,
                   controlInputs: controlInputs, arguments: captured.arguments,
                   typedIndirectSignature: signature,
                   typedIndirectCalleeType: Self.functionPointerCastType(contract)) {
                guard state.selectSSACallOutcome(.typedIndirect) else { break }
                state.invalidateAppleCallerSavedState()
                let result = signature.returnsVoid ? nil : state.writeCallResult(returnType: signature.returnType)
                if let result { state.recordValueType(signature.returnType, for: result) }
                state.recordCall(indirectTarget, signature: nil)
                return .call(frame: frame, result: result)
            }
            guard let frame = state.callFrame(
                      target: indirectTarget,
                      knownSignature: nil,
                      controlInputs: controlInputs,
                      recoverObjectiveCTail: false
                  ) else { break }
            guard state.selectSSACallOutcome(.fallback) else { break }
            state.invalidateAppleCallerSavedState()
            let result = state.writeCallResult(returnType: nil)
            state.recordCall(indirectTarget, signature: nil)
            return .call(frame: frame, result: result)

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationRegisterBranchCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState,
        recoveredSwitches: [UInt64: RecoveredSwitch]
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "br", "braa", "brab", "braaz", "brabz":
            // br Xn (+ the arm64e authenticated braa/brab/braaz/brabz) is an indirect branch
            // (tail-call / jump-table dispatch). operands[0] is the destination register; the
            // authenticated forms carry a 2nd PAC-modifier operand. We do NOT resolve the
            // destination; represent it as an opaque computed branch keyed on the register so
            // structuring never mistakes it for a resolvable branch.
            guard !operands.isEmpty, Self.isRegister(operands[0].lowercased()) else { break }
            // If the dispatch idiom was recovered for this br address AND the
            // caller supplied the resolved case targets, emit a structured
            // switch. The selector is the exact SSA definition the selector proof
            // captured at the guard, never the register's value at this `br`
            // (the index register is routinely reused for the loaded entry or
            // the computed target). Without a proof the proven case edges stay,
            // but the switch abstains from naming a selector.
            if let recovered = recoveredSwitches[source.address] {
                let indexValue = state.provenSwitchSelectors[source.address]
                    ?? MacIRValue.unknown(Self.unprovenSwitchSelectorText)
                let defaultTarget = recovered.defaultTarget.map { MacIRValue.immediate(Int64(bitPattern: $0)) }
                let cases = recovered.targets.enumerated().map { offset, target in
                    MacIRSwitchCase(value: Int64(offset), target: .immediate(Int64(bitPattern: target)))
                }
                return .switchDispatch(index: indexValue, cases: cases, defaultTarget: defaultTarget)
            }
            return .intrinsic(
                destination: nil,
                name: "branch_register",
                arguments: [Self.value(for: operands[0], state: state)]
            )

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationConditionalCompareCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState,
        adjacentComparison: BuilderComparison?, pendingConditionalCompare: PendingConditionalCompare?
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "ccmp", "ccmn":
            if pendingConditionalCompare == nil,
               let comparison = adjacentComparison,
               let pending = conditionalCompare(
                mnemonic: source.mnemonic,
                operands: operands,
                sourceAddress: source.address,
                firstComparison: comparison,
                state: state
               ) {
                state.pendingConditionalCompare = pending
            }
            guard let operation = conditionalCompareIntrinsic(
                mnemonic: source.mnemonic,
                operands: operands,
                state: state
            ) else {
                break
            }
            state.sawConditionalCompareSinceComparison = true
            return operation

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationConditionalSelectCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState,
        pendingConditionalCompare: PendingConditionalCompare?
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "csel", "csinc", "csinv", "csneg":
            if let operation = conditionalSelectOperation(
                mnemonic: source.mnemonic,
                operands: operands,
                sourceAddress: source.address,
                pendingConditionalCompare: pendingConditionalCompare,
                state: &state
            ) {
                return operation
            }

        case "cneg" where operands.count == 3 && ["mi", "pl"].contains(operands[2]):
            // Arm ARM CNEG_CSNEG: CSNEG Rd, Rn, Rn, invert(cond).
            // CSNEG Execute negates modulo datasize; ConditionHolds MI tests N,
            // not N != V. Reuse only a proven plain reaching comparison.
            guard let destinationView = Self.integerRegisterView(operands[0]),
                  let sourceView = Self.integerRegisterView(operands[1]),
                  sourceView.width == destinationView.width,
                  pendingConditionalCompare == nil, state.flagsPhiContext == nil,
                  !state.sawConditionalCompareSinceComparison,
                  let comparison = state.lastComparison,
                  let width = Self.bitWidth(forComparisonOperand: comparison.left,
                                            argumentBitWidths: state.argumentBitWidths),
                  [32, 64].contains(width) else { break }
            let result: MacIRValue
            switch comparison.flagsKind {
            case .subtraction:
                result = .binaryExpression(op: "-",
                    left: Self.unsignedCast(comparison.left, width: width),
                    right: Self.unsignedCast(comparison.right, width: width))
            case .logicalResult:
                result = comparison.left
            }
            let sign = MacIRValue.binaryExpression(op: "&",
                left: Self.unsignedCast(result, width: width),
                right: .immediate(Int64(bitPattern: UInt64(1) << (width - 1))))
            let value = Self.unsignedCast(Self.value(for: operands[1], state: state), width: sourceView.width)
            let negated = Self.unsignedCast(.binaryExpression(op: "-",
                left: .immediate(0), right: value), width: sourceView.width)
            let destination = state.writeRegister(operands[0])
            return .select(destination: destination,
                condition: operands[2] == "mi" ? "!=" : "==", left: sign, right: .immediate(0),
                trueValue: negated, falseValue: value)

        case "cinc", "cinv", "cneg":
            guard operands.count == 3,
                  Self.hasOnlyScalarGPROperands(operands),
                  let invertedCondition = Self.invertedConditionSuffix(for: operands[2]) else {
                break
            }
            let canonicalMnemonic: String
            switch source.mnemonic {
            case "cinc":
                canonicalMnemonic = "csinc"
            case "cinv":
                canonicalMnemonic = "csinv"
            default:
                canonicalMnemonic = "csneg"
            }
            let canonicalOperands = [operands[0], operands[1], operands[1], invertedCondition]
            if let operation = conditionalSelectOperation(
                mnemonic: canonicalMnemonic,
                operands: canonicalOperands,
                sourceAddress: source.address,
                pendingConditionalCompare: pendingConditionalCompare,
                state: &state
            ) {
                return operation
            }

        case "csetm":
            guard operands.count == 2,
                  Self.hasOnlyScalarGPROperands(operands),
                  let invertedCondition = Self.invertedConditionSuffix(for: operands[1]),
                  let zeroRegister = Self.zeroRegister(matchingWidthOf: operands[0]) else {
                break
            }
            let canonicalOperands = [operands[0], zeroRegister, zeroRegister, invertedCondition]
            if let operation = conditionalSelectOperation(
                mnemonic: "csinv",
                operands: canonicalOperands,
                sourceAddress: source.address,
                pendingConditionalCompare: pendingConditionalCompare,
                state: &state
            ) {
                return operation
            }

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationConditionalSetCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState,
        pendingConditionalCompare: PendingConditionalCompare?
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "cset":
            if operands.count == 2,
               let pendingConditionalCompare,
               let compound = Self.compoundCondition(
                for: pendingConditionalCompare,
                branchSuffix: operands[1],
                branchAddress: source.address,
                argumentBitWidths: state.argumentBitWidths,
                carriedAcrossFlagNeutralRows: ssaEnabled,
            projectSigned: ssaEnabled
               ) {
                recordCompoundChain(pendingConditionalCompare, state: &state)
                let destination = state.writeRegister(operands[0])
                state.recordValueType("BOOL", for: destination)
                return .compareToBool(
                    destination: destination,
                    condition: "!=",
                    left: compound,
                    right: .immediate(0)
                )
            }
            if operands.count == 2,
               let flag = flagsPhiCondition(suffix: operands[1], state: &state) {
                let destination = state.writeRegister(operands[0])
                state.recordValueType("BOOL", for: destination)
                return .compareToBool(destination: destination, condition: "!=", left: flag, right: .immediate(0))
            }
            guard operands.count == 2,
                  !state.sawConditionalCompareSinceComparison,
                  let comparison = state.lastComparison,
                  Self.canResolveComparisonSuffix(operands[1], for: comparison),
                  let condition = Self.branchCondition(for: operands[1]) else {
                break
            }
            let destination = state.writeRegister(operands[0])
            state.recordValueType("BOOL", for: destination)
            if operands[1].lowercased() == "lt",
               let addend = comparison.cmnAddend, let width = comparison.cmnWidth {
                // CMN is addition: -MIN wraps to MIN, so a < -b is not N != V at that boundary.
                let a = Self.unsignedCast(comparison.left, width: width)
                let b = Self.unsignedCast(addend, width: width)
                let sum = Self.unsignedCast(.binaryExpression(op: "+", left: a, right: b), width: width)
                let overflow = MacIRValue.binaryExpression(op: "&",
                    left: .unary(op: "~", value: .binaryExpression(op: "^", left: a, right: b)),
                    right: .binaryExpression(op: "^", left: a, right: sum))
                let sign = Self.unsignedCast(.immediate(Int64(bitPattern: UInt64(1) << (width - 1))), width: width)
                let negativeXorOverflow = MacIRValue.binaryExpression(op: "&",
                    left: .binaryExpression(op: "^", left: sum, right: overflow), right: sign)
                return .compareToBool(destination: destination, condition: "!=",
                    left: negativeXorOverflow, right: .immediate(0))
            }
            let projected = nativeSignedWordCMPPredicate(
                comparison: comparison, suffix: operands[1], consumerAddress: source.address,
                argumentBitWidths: state.argumentBitWidths)
            return .compareToBool(
                destination: destination,
                condition: condition,
                left: projected?.left ?? comparison.left,
                right: projected?.right ?? comparison.right
            )

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationConditionalBranchCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState,
        pendingConditionalCompare: PendingConditionalCompare?
    ) -> MacIROperation? {
        switch source.mnemonic {
        default:
            if source.mnemonic.hasPrefix("b."),
               let target = operands.first,
               !target.isEmpty {
                let suffix = String(source.mnemonic.dropFirst(2))
                if let pendingConditionalCompare,
                   let compound = Self.compoundCondition(
                    for: pendingConditionalCompare,
                    branchSuffix: suffix,
                    branchAddress: source.address,
                    argumentBitWidths: state.argumentBitWidths,
                    carriedAcrossFlagNeutralRows: ssaEnabled,
                    projectSigned: ssaEnabled
                   ) {
                    recordCompoundChain(pendingConditionalCompare, state: &state)
                    return .conditionalBranch(
                        condition: "!=",
                        left: compound,
                        right: .immediate(0),
                        target: Self.value(for: target, state: state)
                    )
                }
                if let flag = flagsPhiCondition(suffix: suffix, state: &state) {
                    return .conditionalBranch(
                        condition: "!=",
                        left: flag,
                        right: .immediate(0),
                        target: Self.value(for: target, state: state)
                    )
                }
                if !state.sawConditionalCompareSinceComparison,
                   let comparison = state.lastComparison,
                   Self.canResolveComparisonSuffix(suffix, for: comparison),
                   let condition = Self.branchCondition(for: suffix) {
                    if let addend = comparison.cmnAddend,
                       let width = comparison.cmnWidth,
                       ["lo", "cc", "hs", "cs"].contains(suffix.lowercased()) {
                        // For W-bit unsigned operands, C=0 iff a <= (2^W-1)-b.
                        // Complement AFTER width projection, including shifted addends.
                        let complement = Self.unsignedCast(
                            .unary(op: "~", value: Self.unsignedCast(addend, width: width)), width: width)
                        return .conditionalBranch(
                            condition: ["lo", "cc"].contains(suffix.lowercased()) ? "<=" : ">",
                            left: Self.unsignedCast(comparison.left, width: width),
                            right: complement,
                            target: Self.value(for: target, state: state)
                        )
                    }
                    if !ssaEnabled, nativeSignedWordCMPEnabled,
                       let producer = comparison.nativeSignedWordCMPSource,
                       comparison.flagsKind == .subtraction,
                       comparison.cmnAddend == nil,
                       producer.address == comparison.sourceAddress,
                       source.address >= 4, producer.address == source.address - 4,
                       ["ge", "lt", "gt", "le"].contains(suffix.lowercased()),
                       Self.bitWidth(forComparisonOperand: comparison.left,
                           argumentBitWidths: state.argumentBitWidths) == 32 {
                        return .conditionalBranch(
                            condition: condition,
                            left: Self.signedProjection(comparison.left, width: 32,
                                partner: comparison.right),
                            right: Self.signedProjection(comparison.right, width: 32,
                                partner: comparison.left),
                            target: Self.value(for: target, state: state)
                        )
                    }
                    return .conditionalBranch(
                        condition: condition,
                        left: comparison.left,
                        right: comparison.right,
                        target: Self.value(for: target, state: state)
                    )
                }
                return .intrinsic(
                    destination: nil,
                    name: "branch_\(suffix)",
                    arguments: [Self.value(for: target, state: state)]
                )
            }
            break
        }
        return nil
    }

    @inline(never)
    private func operationScalarLoadCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "ldr", "ldur", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldurb", "ldurh", "ldursw", "ldursb", "ldursh":
            if Self.explicitMemoryWritebackBase(operands: operands) == "sp" {
                // Keep the established SP rendering path, but do not let a later
                // [sp] load pretend that the updated base is still entry SP.
                state.invalidateStackCoordinateSystem()
            }
            if let writeback = Self.scalarWritebackAddress(operands: operands),
               Self.hasScalarTransferWithGPRAddress(operands) {
                let baseSource = state.readRegister(writeback.base)
                let destination = state.writeRegister(operands[0])
                let baseDestination = state.writeRegister(writeback.base)
                state.recordExplicitStackWriteback(writeback.base)
                if writeback.base == "sp", !state.hasUnknownStackPointerAdjustment {
                    state.recordStackDisplacement(delta: writeback.delta)
                }
                return .loadWriteback(
                    destination: destination,
                    baseDestination: baseDestination,
                    baseSource: baseSource,
                    delta: writeback.delta,
                    preIndex: writeback.preIndex
                )
            }
            // Never silently drop writeback on an unmodeled transfer form.
            if let writeback = Self.scalarWritebackAddress(operands: operands), writeback.delta != 0 { break }
            guard operands.count == 2 else { break }
            if ["ldurb", "ldurh", "ldursw", "ldursb", "ldursh"].contains(source.mnemonic) {
                guard Self.hasOnlyScalarGPROperands(operands, allowingMemory: true) else { break }
            }
            // Selector provenance: detect a load FROM a known `__objc_selrefs`
            // slot. The selref idiom is `adrp xN, <page>` + `ldr xD, [xN, #off]`
            // (or `[xN]`), so the slot address is the page base recorded for the
            // base register plus the load offset. We resolve this BEFORE the
            // existing stack/load handling — a selref base is a literal-derived
            // register (never sp/fp), so this never intersects the stack path.
            // Scoped to the 64-bit `ldr` mnemonic only, since a SEL is a 64-bit
            // pointer; this also avoids any w-register/x-register key mismatch at
            // the call site.
            let selectorForLoad: MacIRCallSelectorEvidence? = {
                guard state.resolvesObjCSelectors, source.mnemonic == "ldr",
                      Self.canonical64BitSelectorRegister(operands[0]) != nil,
                      let (base, offset) = Self.selrefMemoryComponents(operands[1]),
                      let pageBase = state.adrpPageBase(for: base),
                      offset >= 0 else {
                    return nil
                }
                let unsignedOffset = UInt64(offset)
                guard unsignedOffset <= UInt64.max - pageBase else { return nil }
                let selrefAddress = pageBase + unsignedOffset
                guard let selectorName = state.objcSelectors[selrefAddress] else {
                    return nil
                }
                return MacIRCallSelectorEvidence(
                    name: selectorName,
                    selrefAddress: selrefAddress
                )
            }()
            let entryStackOffset = Self.exactEntryStackLoadOffset(
                memoryOperand: operands[1],
                mnemonic: source.mnemonic,
                destinationRegister: operands[0]
            )
            let accessByteWidth = Self.loadStoreByteWidth(
                mnemonic: source.mnemonic,
                register: operands[0]
            )
            let address = Self.memoryValue(for: operands[1], state: state)
            let destination = state.writeRegister(operands[0])
            if let selectorForLoad {
                // Record provenance only; the emitted operation stays the normal
                // `.load`, so value-flow is untouched. The substitution happens at
                // the objc_msgSend call by looking up this destination value.
                state.recordSelectorEvidence(selectorForLoad, for: destination)
                return .load(destination: destination, address: address)
            }
            if state.ssa != nil, let entryStackOffset, let accessByteWidth,
               let argument = state.bindEntryStackArgumentIfProven(
                   byteOffset: entryStackOffset, accessByteWidth: accessByteWidth,
                   destinationRegister: operands[0]) {
                state.propagateValueType(from: argument, to: destination)
                if case .stackSlot = address {
                    return .stackSlotRead(destination: destination, slot: address, value: argument)
                }
                return .assign(destination: destination, source: argument)
            }
            if case let .stackSlot(offset) = address {
                if let entryStackOffset,
                   let accessByteWidth,
                   let argument = state.bindEntryStackArgumentIfProven(
                       byteOffset: entryStackOffset,
                       accessByteWidth: accessByteWidth,
                       destinationRegister: operands[0]
                   ) {
                    state.propagateValueType(from: argument, to: destination)
                    return .stackSlotRead(destination: destination, slot: address, value: argument)
                }
                state.recordLocal(
                    at: offset,
                    byteWidth: accessByteWidth,
                    source: nil,
                    preferredType: Self.sizedAccessElementType(mnemonic: source.mnemonic)
                )
                if Self.isLosslessStackValueLoad(source.mnemonic),
                   Self.hasExactStackMemoryAddress(operands[1]),
                   let value = state.valueStoredInStackSlot(
                       offset,
                       accessByteWidth: accessByteWidth,
                       carrierKind: Self.stackSlotCarrierKind(forRegister: operands[0])
                   ) {
                    state.propagateValueType(from: value, to: destination)
                    return .stackSlotRead(destination: destination, slot: address, value: value)
                }
            }
            return .load(destination: destination, address: address)

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationScalarStoreCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "str", "stur", "strb", "strh", "sturb", "sturh":
            if let stored = operands.first { state.noteStoredStackAddress(stored) }
            if Self.explicitMemoryWritebackBase(operands: operands) == "sp" {
                // Preserve the existing SP store rendering while severing entry
                // address provenance before any later stack-formal lookup.
                state.invalidateStackCoordinateSystem()
            }
            if let writeback = Self.scalarWritebackAddress(operands: operands),
               Self.hasScalarTransferWithGPRAddress(operands) {
                let source = Self.value(for: operands[0], state: state)
                state.invalidateStackMemoryIfProvenAlias(writeback.base)
                state.invalidateOutgoingCallStackIfStackPointerBased(writeback.base)
                let baseSource = state.readRegister(writeback.base)
                let baseDestination = state.writeRegister(writeback.base)
                state.recordExplicitStackWriteback(writeback.base)
                if writeback.base == "sp", !state.hasUnknownStackPointerAdjustment {
                    state.recordStackDisplacement(delta: writeback.delta)
                }
                return .storeWriteback(
                    source: source,
                    baseDestination: baseDestination,
                    baseSource: baseSource,
                    delta: writeback.delta,
                    preIndex: writeback.preIndex
                )
            }
            if let writeback = Self.scalarWritebackAddress(operands: operands), writeback.delta != 0 { break } // see the load case
            guard operands.count == 2 else { break }
            if ["sturb", "sturh"].contains(source.mnemonic) {
                guard Self.hasOnlyScalarGPROperands(operands, allowingMemory: true) else { break }
            }
            let storeMnemonic = source.mnemonic
            let source = Self.value(for: operands[0], state: state)
            let address = Self.memoryValue(for: operands[1], state: state)
            if case .stackSlot = address {
                // A modeled write through exact entry SP may overlap any packed
                // formal. This includes a proven fp/x29 alias of entry SP; the
                // physical spelling cannot weaken the memory-provenance rule.
                state.invalidateEntrySPProvenance()
            } else if let base = Self.bracketedMemoryBase(operands[1]),
                      base == "sp" || state.knownStackBaseOffset(for: base) != nil {
                // A register-indexed write off SP (or a proven alias) is a computed address,
                // not a slot, and may still land on any stack formal.
                state.invalidateEntrySPProvenance()
            }
            if case let .stackSlot(offset) = address,
               Self.hasExactStackMemoryAddress(operands[1]) {
                state.store(
                    source,
                    inStackSlot: offset,
                    byteWidth: Self.loadStoreByteWidth(mnemonic: storeMnemonic, register: operands[0]),
                    carrierKind: Self.stackSlotCarrierKind(forRegister: operands[0]),
                    canCacheValue: Self.isLosslessStackValueStore(storeMnemonic),
                    shouldPromoteToLocal: Self.shouldPromoteStackStore(sourceOperand: operands[0]),
                    preferredType: Self.sizedAccessElementType(mnemonic: storeMnemonic)
                )
            } else if let base = Self.bracketedMemoryBase(operands[1]),
                      base == "sp" || state.knownStackBaseOffset(for: base) != nil {
                // A register-indexed store through SP or a proven stack alias
                // has no exact slot key. Any cached fact may alias it, so
                // retaining even a disjoint-looking entry would be unsound.
                state.invalidateAllStackSlotValues()
            }
            state.recordOutgoingCallStackStore(
                state.outgoingCallStackValue(source, storedFrom: operands[0]),
                memoryOperand: operands[1],
                byteWidth: Self.loadStoreByteWidth(mnemonic: storeMnemonic, register: operands[0]),
                carrierKind: Self.stackSlotCarrierKind(forRegister: operands[0])
            )
            return .store(
                source: source,
                address: address
            )

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationPairStoreCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "stp":
            guard operands.count >= 3 else { break }
            state.noteStoredStackAddress(operands[0])
            state.noteStoredStackAddress(operands[1])
            if Self.hasNonStackPairWriteback(operands: operands) { break }
            if let operation = stackPairWritebackOperation(mnemonic: source.mnemonic, operands: operands, state: &state) {
                return operation
            }
            let pairMemoryOperand = Self.memoryOperand(from: operands)
            let pairWritebackBase = Self.pairWritebackBase(operands: operands)
            if pairWritebackBase == "sp" {
                state.invalidateStackCoordinateSystem()
            }
            let firstValue = state.readRegister(operands[0])
            let secondValue = state.readRegister(operands[1])
            let address = Self.memoryValue(for: pairMemoryOperand, state: state)
            let pairElementByteWidth = Self.pairElementByteWidth(for: operands[0])
            if case .stackSlot = address {
                state.invalidateEntrySPProvenance()
            }
            if pairWritebackBase == nil,
               case let .stackSlot(offset) = address,
               let elementByteWidth = pairElementByteWidth {
                let shouldPromoteToLocal = Self.shouldPromoteStackPairStore(
                    firstOperand: operands[0],
                    secondOperand: operands[1]
                )
                state.store(
                    firstValue,
                    inStackSlot: offset,
                    byteWidth: Int(elementByteWidth),
                    carrierKind: Self.stackSlotCarrierKind(forRegister: operands[0]),
                    shouldPromoteToLocal: shouldPromoteToLocal
                )
                state.store(
                    secondValue,
                    inStackSlot: offset + elementByteWidth,
                    byteWidth: Int(elementByteWidth),
                    carrierKind: Self.stackSlotCarrierKind(forRegister: operands[1]),
                    shouldPromoteToLocal: shouldPromoteToLocal,
                    stackAccessIndex: 1
                )
            }
            if pairWritebackBase == nil, let elementByteWidth = pairElementByteWidth {
                state.recordOutgoingCallStackPairStore(
                    firstValue,
                    secondValue,
                    memoryOperand: pairMemoryOperand,
                    elementByteWidth: Int(elementByteWidth),
                    firstCarrierKind: Self.stackSlotCarrierKind(forRegister: operands[0]),
                    secondCarrierKind: Self.stackSlotCarrierKind(forRegister: operands[1])
                )
            } else if let base = Self.bracketedMemoryBase(pairMemoryOperand) {
                state.invalidateOutgoingCallStackIfStackPointerBased(base)
            }
            var arguments = [firstValue, secondValue, address]
            if case let .stackSlot(offset) = address,
               let elementByteWidth = pairElementByteWidth {
                arguments.append(.stackSlot(offset: offset + elementByteWidth))
            }
            return .intrinsic(
                destination: nil,
                name: "save_pair",
                arguments: arguments
            )

        default:
            break
        }
        return nil
    }

    @inline(never)
    private func operationPairLoadCase(
        for source: MacIRSourceSpan, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        switch source.mnemonic {
        case "ldp", "ldpsw":
            guard operands.count >= 3 else { break }
            if Self.hasNonStackPairWriteback(operands: operands) { break }
            if let operation = stackPairWritebackOperation(mnemonic: source.mnemonic, operands: operands, state: &state) {
                return operation
            }
            let pairWritebackBase = Self.pairWritebackBase(operands: operands)
            if pairWritebackBase == "sp" {
                state.invalidateStackCoordinateSystem()
            }
            let address = Self.memoryValue(for: Self.memoryOperand(from: operands), state: state)
            let firstDestination = state.writeRegister(operands[0])
            let secondDestination = state.writeRegister(operands[1])
            let pairElementByteWidth = Self.pairElementByteWidth(
                mnemonic: source.mnemonic,
                register: operands[0]
            )
            if case let .stackSlot(offset) = address,
               let elementByteWidth = pairElementByteWidth {
                let shouldPromoteToLocal = Self.shouldPromoteStackPairLoad(
                    firstOperand: operands[0],
                    secondOperand: operands[1]
                )
                if shouldPromoteToLocal {
                    state.recordLocal(
                        at: offset,
                        byteWidth: Int(elementByteWidth),
                        source: nil
                    )
                    state.recordLocal(
                        at: offset + elementByteWidth,
                        byteWidth: Int(elementByteWidth),
                        source: nil,
                        stackAccessIndex: 1
                    )
                }
                if source.mnemonic == "ldp",
                   pairWritebackBase == nil,
                   let firstValue = state.valueStoredInStackSlot(
                       offset,
                       accessByteWidth: Int(elementByteWidth),
                       carrierKind: Self.stackSlotCarrierKind(forRegister: operands[0])
                   ),
                   let secondValue = state.valueStoredInStackSlot(
                       offset + elementByteWidth,
                       accessByteWidth: Int(elementByteWidth),
                       carrierKind: Self.stackSlotCarrierKind(forRegister: operands[1])
                   ) {
                    state.propagateValueType(from: firstValue, to: firstDestination)
                    state.propagateValueType(from: secondValue, to: secondDestination)
                    return .stackSlotPairRead(
                        firstDestination: firstDestination,
                        firstSlot: address,
                        firstValue: firstValue,
                        secondDestination: secondDestination,
                        secondSlot: .stackSlot(offset: offset + elementByteWidth),
                        secondValue: secondValue
                    )
                }
            }
            var arguments = [firstDestination, secondDestination, address]
            if case let .stackSlot(offset) = address,
               let elementByteWidth = pairElementByteWidth {
                arguments.append(.stackSlot(offset: offset + elementByteWidth))
            }
            return .intrinsic(
                destination: nil,
                name: "restore_pair",
                arguments: arguments
            )

        default:
            break
        }
        return nil
    }

    /// The `.unknown` read sets (HOP-2) bound to the current SSA values.
    private static func unknownInputs(mnemonic: String, operands: [String], state: BuilderState) -> MacIRUnknownInputs {
        let sets = unknownInstructionReadSets(mnemonic: mnemonic, operands: operands)
        let bind = { (name: String) in MacIRUnknownRead(register: name, value: state.readRegister(name)) }
        return MacIRUnknownInputs(
            mayRead: sets.mayRead.map(bind),
            definiteRead: sets.definiteRead.map(bind),
            mayReadNZCV: sets.mayReadNZCV,
            definitelyReadsNZCV: sets.definitelyReadsNZCV
        )
    }

    /// A malformed-operand fallback `.unknown` with its reads recorded.
    private static func unknownFallback(mnemonic: String, operands: [String], state: BuilderState) -> MacIROperation {
        .unknown(
            destination: nil,
            inputs: unknownInputs(mnemonic: mnemonic, operands: operands, state: state),
            mnemonic: mnemonic,
            operands: operands.joined(separator: ", ")
        )
    }

    private func binaryOperation(_ op: String, operands: [String], state: inout BuilderState) -> MacIROperation {
        guard operands.count == 3 else {
            return Self.unknownFallback(mnemonic: op, operands: operands, state: state)
        }
        let left = Self.value(for: operands[1], state: state)
        let right: MacIRValue
        if op == "&", let destinationView = Self.integerRegisterView(operands[0]),
           let sourceView = Self.integerRegisterView(operands[1]),
           destinationView.width == sourceView.width,
           let immediate = Self.parseRegisterImmediate(operands[2], bitWidth: destinationView.width) {
            right = .immediate(immediate)
        } else {
            right = Self.value(for: operands[2], state: state)
        }
        let destination = state.writeRegister(operands[0])
        state.recordFrameBase(destination: operands[0], left: operands[1], op: op, right: operands[2])
        return .binary(
            destination: destination,
            op: op,
            left: left,
            right: right
        )
    }

    private func moveKeepOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard (operands.count == 2 || operands.count == 3),
              Self.hasOnlyScalarGPROperands(operands),
              let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
              let current = state.materializedImmediate(for: operands[0]),
              let immediate = Self.parseImmediate(operands[1]),
              (0...0xffff).contains(immediate),
              let shift = Self.moveWideShift(operands.count == 3 ? operands[2] : nil, bitWidth: bitWidth) else {
            return nil
        }

        let registerMask = Self.registerMask(bitWidth: bitWidth)
        let halfwordMask = UInt64(0xffff) << UInt64(shift)
        let inserted = (UInt64(bitPattern: immediate) & 0xffff) << UInt64(shift)
        let folded = ((current & registerMask) & ~halfwordMask) | inserted
        let normalized = folded & registerMask
        let destination = state.writeRegister(operands[0])
        state.recordMaterializedImmediate(normalized, for: operands[0])
        return .assign(destination: destination, source: .immediate(Int64(bitPattern: normalized)))
    }

    private func standaloneMoveKeepOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard (operands.count == 2 || operands.count == 3),
              Self.hasOnlyRound2ScalarGPROperands(operands),
              Self.isRound2DataRegister(operands[0]),
              let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
              let immediate = Self.parseImmediate(operands[1]),
              (0...0xffff).contains(immediate),
              let shift = Self.moveWideShift(operands.count == 3 ? operands[2] : nil, bitWidth: bitWidth) else {
            return nil
        }

        let destinationOldValue = Self.value(for: operands[0], state: state)
        let registerMask = Self.registerMask(bitWidth: bitWidth)
        let halfwordMask = UInt64(0xffff) << UInt64(shift)
        let preservedMask = registerMask & ~halfwordMask
        let preserved = MacIRValue.binaryExpression(
            op: "&",
            left: destinationOldValue,
            right: .immediate(Int64(bitPattern: preservedMask))
        )
        let insertedValue = (UInt64(bitPattern: immediate) & 0xffff) << UInt64(shift)
        let combined = MacIRValue.binaryExpression(
            op: "|",
            left: preserved,
            right: .immediate(Int64(bitPattern: insertedValue))
        )
        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: combined)
    }

    private static func moveMaterializedImmediate(mnemonic: String, operands: [String]) -> UInt64? {
        guard mnemonic == "mov" || mnemonic == "movz",
              (operands.count == 2 || (mnemonic == "movz" && operands.count == 3)),
              let bitWidth = scalarRegisterBitWidth(operands[0]),
              let immediate = (mnemonic == "mov" && integerRegisterView(operands[0]) != nil
                  ? parseRegisterImmediate(operands[1], bitWidth: bitWidth)
                  : parseImmediate(operands[1])) else {
            return nil
        }

        let registerMask = registerMask(bitWidth: bitWidth)
        if mnemonic == "mov" {
            guard operands.count == 2 else { return nil }
            return UInt64(bitPattern: immediate) & registerMask
        }

        guard (0...0xffff).contains(immediate),
              let shift = moveWideShift(operands.count == 3 ? operands[2] : nil, bitWidth: bitWidth) else {
            return nil
        }
        return ((UInt64(bitPattern: immediate) & 0xffff) << UInt64(shift)) & registerMask
    }

    private static func moveWideShift(_ operand: String?, bitWidth: Int) -> Int? {
        guard let operand else { return 0 }
        let parts = operand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
        guard parts.count == 2,
              parts[0].lowercased() == "lsl",
              let amount = parseImmediate(parts[1]),
              amount >= 0,
              amount < Int64(bitWidth),
              amount % 16 == 0 else {
            return nil
        }
        return Int(amount)
    }

    private func fmovScalarBitMoveOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard Self.isFmovScalarGPRFPBitMove(operands) else { return nil }

        let source = state.readRegister(operands[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let destinationRegister = operands[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let destination = state.writeRegister(destinationRegister)
        if destinationRegister.hasPrefix("d") {
            state.recordValueType("double", for: destination)
        } else if destinationRegister.hasPrefix("s") {
            state.recordValueType("float", for: destination)
        }
        return .intrinsic(destination: destination, name: "fmov", arguments: [source])
    }

    private func fmovScalarImmediateOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard operands.count == 2,
              Self.isFmovScalarFPRegister(operands[0]),
              let literal = Self.fmovImmediateLiteral(operands[1]) else {
            return nil
        }

        let destinationRegister = operands[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let destination = state.writeRegister(destinationRegister)
        state.recordValueType(destinationRegister.hasPrefix("s") ? "float" : "double", for: destination)
        return .assign(destination: destination, source: .symbol(literal))
    }

    /// Preserve an exact same-view scalar SIMD argument use as a typed body value.
    /// Same-width scalar FP moves preserve value bits, including NaN payloads;
    /// local registers and recovered formal inputs share the same semantics.
    private func fmovIncomingScalarParameterMoveOperation(
        operands: [String],
        state: inout BuilderState
    ) -> MacIROperation? {
        guard Self.isFmovScalarFPFPMove(operands) else { return nil }

        let sourceRegister = operands[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let source = state.readRegister(sourceRegister)
        if case .unknown = source { return nil }

        let destinationRegister = operands[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let destination = state.writeRegister(destinationRegister)
        state.propagateValueType(from: source, to: destination)
        return .assign(destination: destination, source: source)
    }

    private static func fmovImmediateLiteral(_ operand: String) -> String? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("#") else { return nil }
        let literal = String(normalized.dropFirst())
        guard !literal.isEmpty,
              literal.contains("."),
              Double(literal) != nil else {
            return nil
        }
        return literal
    }

    /// Reuse the byte-backed native CMP authority; do not infer new flag provenance.
    private func nativeSignedWordCMPPredicate(
        comparison: BuilderComparison, suffix: String, consumerAddress: UInt64,
        argumentBitWidths: [MacIRParameterBindingID: Int]
    ) -> (left: MacIRValue, right: MacIRValue)? {
        guard !ssaEnabled, nativeSignedWordCMPEnabled,
              let producer = comparison.nativeSignedWordCMPSource,
              comparison.flagsKind == .subtraction,
              comparison.cmnAddend == nil,
              producer.address == comparison.sourceAddress,
              consumerAddress >= 4, producer.address == consumerAddress - 4,
              ["ge", "lt", "gt", "le"].contains(suffix.lowercased()),
              Self.bitWidth(forComparisonOperand: comparison.left,
                  argumentBitWidths: argumentBitWidths) == 32 else { return nil }
        return (
            Self.signedProjection(comparison.left, width: 32, partner: comparison.right),
            Self.signedProjection(comparison.right, width: 32, partner: comparison.left)
        )
    }

    private static func isExactNativeWordCMPImmediate(_ source: MacIRSourceSpan) -> Bool {
        guard source.mnemonic == "cmp" else { return false }
        let operands = splitOperands(source.operands)
        guard operands.count == 2,
              let register = integerRegisterView(operands[0]),
              register.width == 32, register.index < 31,
              operands[0] == "w\(register.index)",
              let immediate = parseImmediate(operands[1]) else { return false }
        let tokens = source.byteText.split(separator: " ")
        guard tokens.count == 4 else { return false }
        var word: UInt32 = 0
        for (index, token) in tokens.enumerated() {
            guard token.utf8.count == 2, token.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }), let byte = UInt8(token, radix: 16) else { return false }
            word |= UInt32(byte) << UInt32(index * 8)
        }
        // sf=0, op=SUB, S=1, immediate class, sh=0, Rd=WZR.
        return word & 0xffc0_001f == 0x7100_001f
            && Int((word >> 5) & 31) == register.index
            && Int64((word >> 10) & 0xfff) == immediate
    }

    private func twoOperandComparisonOperation(
        mnemonic: String,
        operands: [String],
        sourceAddress: UInt64,
        state: inout BuilderState
    ) -> MacIROperation {
        let left = Self.value(for: operands[0], state: state)
        let right = mnemonic == "cmn"
            ? Self.negatedValue(for: operands[1], state: state)
            : Self.value(for: operands[1], state: state)
        let comparison = BuilderComparison(left: left, right: right, sourceAddress: sourceAddress,
            cmnAddend: mnemonic == "cmn" ? Self.value(for: operands[1], state: state) : nil,
            cmnWidth: mnemonic == "cmn" ? Self.scalarDataBitWidth(operands[0]) : nil,
            cmnAddendWasImmediate: mnemonic == "cmn" && Self.parseImmediate(operands[1]) != nil)
        state.recordPlainComparison(comparison)
        var renderedRight = right
        if mnemonic == "cmn", Self.parseImmediate(operands[1]) == nil,
           let width = Self.scalarDataBitWidth(operands[0]),
           let bits = Self.compoundUnsignedAtom(Self.value(for: operands[1], state: state), width: width) {
            renderedRight = Self.unsignedCast(.binaryExpression(op: "-",
                left: Self.unsignedCast(.immediate(0), width: width), right: bits), width: width)
        }
        return .intrinsic(destination: nil, name: "compare", arguments: [left, renderedRight])
    }

    private func threeOperandComparisonOperation(
        mnemonic: String,
        operands: [String],
        sourceAddress: UInt64,
        state: inout BuilderState
    ) -> MacIROperation? {
        guard operands.count == 3,
              ["cmp", "cmn"].contains(mnemonic),
              Self.hasOnlyRound2ScalarGPROperands(operands),
              let composedRight = Self.comparisonRegisterOperandValue(
                register: operands[1],
                modifier: operands[2],
                state: state
              ) else {
            return nil
        }

        let left = Self.value(for: operands[0], state: state)
        let right = mnemonic == "cmn"
            ? MacIRValue.unary(op: "-", value: composedRight)
            : composedRight
        let comparison = BuilderComparison(left: left, right: right, sourceAddress: sourceAddress,
            cmnAddend: mnemonic == "cmn" ? composedRight : nil,
            cmnWidth: mnemonic == "cmn" ? Self.scalarDataBitWidth(operands[0]) : nil)
        state.recordPlainComparison(comparison)
        return .intrinsic(destination: nil, name: "compare", arguments: [left, right])
    }

    private static func comparisonRegisterOperandValue(
        register: String,
        modifier: String,
        state: BuilderState
    ) -> MacIRValue? {
        if let extended = extendedRegisterValue(register: register, extend: modifier, state: state) {
            return extended
        }
        if let shifted = shiftedRegisterValue(register: register, shift: modifier, state: state) {
            return shifted
        }
        return nil
    }

    static func isSupportedComparisonRegisterModifier(register: String, modifier: String) -> Bool {
        let keyword = modifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first?
            .lowercased()
        switch keyword {
        case "sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw":
            return isRound2WDataRegister(register)
        case "lsl", "lsr", "asr":
            return isRegister(register)
        default:
            return false
        }
    }

    /// Arm ARM DecodeBitMasks: a logical immediate is a replicated rotated
    /// nonempty, non-full run of ones in a power-of-two element.
    private static func logicalTestImmediate(_ operand: String, width: Int) -> UInt64? {
        var text = String(operand.dropFirst()).lowercased()
        let radix = text.hasPrefix("0x") ? 16 : 10
        if radix == 16 { text = String(text.dropFirst(2)) }
        guard let bits = UInt64(text, radix: radix), bits != 0,
              bits <= registerMask(bitWidth: width) else { return nil }
        for size in [2, 4, 8, 16, 32, 64] where size <= width {
            let mask = registerMask(bitWidth: size)
            let element = bits & mask
            var repeated: UInt64 = 0
            for shift in stride(from: 0, to: width, by: size) { repeated |= element << shift }
            guard repeated == bits, element != 0, element != mask else { continue }
            let rotated = ((element >> 1) | (element << (size - 1))) & mask
            if (element ^ rotated).nonzeroBitCount == 2 { return bits }
        }
        return nil
    }

    private func testComparisonOperation(
        operands: [String],
        sourceAddress: UInt64,
        state: inout BuilderState
    ) -> MacIROperation? {
        // ISA_A64 2025-12 TST_ANDS_log_imm / TST_ANDS_log_shift:
        // result = operand1 AND operand2; NZCV = result<MSB> : IsZeroBit(result) : '00'.
        // Keep the signed-width result, never a Boolean bit test: bit 63 is N.
        if let result = Self.additionalLogicalTestResult(operands: operands, state: state) {
            state.recordPlainComparison(BuilderComparison(
                left: result, right: .immediate(0), sourceAddress: sourceAddress,
                flagsKind: .logicalResult))
            return .intrinsic(destination: nil, name: "compare", arguments: [result, .immediate(0)])
        }
        guard operands.count == 2,
              let view = Self.integerRegisterView(operands[0]) else { return nil }
        let left = Self.unsignedCast(Self.value(for: operands[0], state: state), width: view.width)
        let right: MacIRValue
        if operands[1].hasPrefix("#") {
            guard let mask = Self.logicalTestImmediate(operands[1], width: view.width) else { return nil }
            right = .immediate(Int64(bitPattern: mask))
        } else {
            guard let other = Self.integerRegisterView(operands[1]), other.width == view.width else { return nil }
            right = Self.value(for: operands[1], state: state)
        }
        // Arm ARM TST_ANDS_log_imm alias; ANDS_log_imm Execute:
        // N = result[width-1], Z = IsZeroBit(result), C = V = 0.
        // Keep all result bits: a boolean bitTest would lose the sign flag.
        let testValue = MacIRValue.unary(
            op: view.width == 32 ? "(int32_t)" : "(int64_t)",
            value: .binaryExpression(op: "&", left: left, right: right))

        let comparison = BuilderComparison(
            left: testValue,
            right: .immediate(0),
            sourceAddress: sourceAddress,
            flagsKind: .logicalResult
        )
        state.recordPlainComparison(comparison)
        return .intrinsic(destination: nil, name: "compare", arguments: [testValue, .immediate(0)])
    }

    /// Bounded additions only: high-bit 64-bit masks and ASR register TST.
    /// Other existing encodings retain their existing lifting route.
    private static func additionalLogicalTestResult(operands: [String], state: BuilderState) -> MacIRValue? {
        guard operands.count == 2 || operands.count == 3,
              let view = integerRegisterView(operands[0]) else { return nil }
        let width = view.width
        let right: MacIRValue
        if operands.count == 2 {
            let text = operands[1].lowercased()
            guard width == 64, text.hasPrefix("#0x"),
                  let mask = logicalTestImmediate(text, width: width), mask > UInt64(Int64.max) else { return nil }
            right = .immediate(Int64(bitPattern: mask))
        } else {
            guard integerRegisterView(operands[1])?.width == width else { return nil }
            let shift = operands[2].split(separator: " ")
            guard shift.count == 2, shift[0].lowercased() == "asr",
                  let amount = parseImmediate(String(shift[1])), amount >= 0, amount < Int64(width) else { return nil }
            let signed = MacIRValue.unary(op: width == 32 ? "(int32_t)" : "(int64_t)",
                                         value: value(for: operands[1], state: state))
            right = .binaryExpression(op: ">>", left: signed, right: .immediate(amount))
        }
        let result = MacIRValue.binaryExpression(op: "&",
            left: unsignedCast(value(for: operands[0], state: state), width: width),
            right: unsignedCast(right, width: width))
        return .unary(op: width == 32 ? "(int32_t)" : "(int64_t)", value: result)
    }

    private func flagSettingLogicalOperation(
        mnemonic: String,
        operands: [String],
        sourceAddress: UInt64,
        state: inout BuilderState
    ) -> MacIROperation? {
        guard operands.count == 3,
              ["ands", "bics"].contains(mnemonic),
              Self.scalarRegisterBitWidth(operands[0]) != nil || Self.isZeroRegister(operands[0]),
              Self.isScalarGPROperand(operands[1]),
              Self.isScalarGPROrImmediateOperand(operands[2]),
              Self.hasOnlyScalarGPROperands(operands) else {
            return nil
        }

        let left = Self.value(for: operands[1], state: state)
        let right = Self.value(for: operands[2], state: state)
        let result: MacIRValue = mnemonic == "bics"
            ? .binaryExpression(op: "&", left: left, right: .unary(op: "~", value: right))
            : .binaryExpression(op: "&", left: left, right: right)
        let comparison = BuilderComparison(
            left: result,
            right: .immediate(0),
            sourceAddress: sourceAddress,
            flagsKind: .logicalResult
        )
        state.recordPlainComparison(comparison)

        if Self.isZeroRegister(operands[0]) {
            return .intrinsic(destination: nil, name: "compare", arguments: [result, .immediate(0)])
        }

        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: result)
    }

    private static func shiftOperator(for mnemonic: String) -> String {
        mnemonic == "lsl" ? "<<" : ">>"
    }

    private static func isScalarGPROrImmediateOperand(_ operand: String) -> Bool {
        parseImmediate(operand) != nil
            || isScalarGPROperand(operand)
    }

    private static func isScalarGPROperand(_ operand: String) -> Bool {
        scalarRegisterBitWidth(operand) != nil
            || isZeroRegister(operand)
    }

    private func extendedRegisterDataProcessing(
        mnemonic: String,
        operands: [String],
        state: inout BuilderState
    ) -> MacIROperation? {
        let ops: [String: String] = ["add": "+", "sub": "-"]
        // ISA_A64 2025-12 ADD_addsub_ext / SUB_addsub_ext: ExtendReg
        // followed by AddWithCarry and truncation to datasize. W writes zero-extend.
        if operands.count == 4, let op = ops[mnemonic],
           // Rd/Rn=31 encodes WSP here, not WZR; WSP remains outside this route.
           operands[0].lowercased() != "wzr", operands[1].lowercased() != "wzr",
           operands.prefix(3).allSatisfy({ Self.isRound2WDataRegister($0) }) {
            let extensionParts = operands[3].split(separator: " ")
            if extensionParts.count == 1 || extensionParts.count == 2,
               extensionParts.first?.lowercased() == "sxth" {
                let amount: Int64? = extensionParts.count == 1 ? 0 : Self.parseImmediate(String(extensionParts[1]))
                if let amount, amount >= 0, amount <= 4 {
                    let left = Self.unsignedCast(Self.value(for: operands[1], state: state), width: 32)
                    let narrow = MacIRValue.unary(op: "(int16_t)", value: Self.value(for: operands[2], state: state))
                    let extended = Self.unsignedCast(narrow, width: 32)
                    let shifted: MacIRValue = amount == 0 ? extended
                        : .binaryExpression(op: "<<", left: extended, right: .immediate(amount))
                    let result = Self.unsignedCast(.binaryExpression(op: op, left: left, right: shifted), width: 32)
                    return .assign(destination: state.writeRegister(operands[0]), source: result)
                }
            }
        }
        guard operands.count == 4,
              let op = ops[mnemonic],
              Self.hasOnlyRound2ScalarGPROperands(operands),
              Self.isRound2XDomainRegister(operands[0]),
              Self.isRound2XDomainRegister(operands[1]),
              Self.isRound2WDataRegister(operands[2]),
              let extended = Self.extendedRegisterValue(register: operands[2], extend: operands[3], state: state)
        else { return nil }

        let left = Self.value(for: operands[1], state: state)
        let destination = state.writeRegister(operands[0])
        return .binary(destination: destination, op: op, left: left, right: extended)
    }

    /// Lifts the shifted-register form of the non-flag-setting data-processing ops
    /// (`add/sub/and/orr/eor Xd, Xn, Xm, lsl/lsr/asr #s`) to `Xd = Xn OP (Xm << s)`.
    /// Returns nil for any other mnemonic, an unsupported shift (ror / sxtw / uxtw), or a
    /// non-register operand, so those fall through to the faithful low-level rendering.
    private func shiftedRegisterDataProcessing(
        mnemonic: String,
        operands: [String],
        state: inout BuilderState
    ) -> MacIROperation? {
        let ops: [String: String] = ["add": "+", "sub": "-", "and": "&", "orr": "|", "eor": "^"]
        guard operands.count == 4,
              let op = ops[mnemonic],
              let shifted = Self.shiftedRegisterValue(register: operands[2], shift: operands[3], state: state)
        else { return nil }
        // Read both sources before writing the destination so in-place forms
        // (e.g. add x0, x0, x0, lsl #2) observe the incoming versions.
        let left = Self.value(for: operands[1], state: state)
        let destination = state.writeRegister(operands[0])
        return .binary(destination: destination, op: op, left: left, right: shifted)
    }

    private func shiftedBitClearStyleOperation(
        mnemonic: String,
        operands: [String],
        state: inout BuilderState
    ) -> MacIROperation? {
        let ops: [String: String] = ["bic": "&", "orn": "|", "eon": "^"]
        guard operands.count == 4,
              let op = ops[mnemonic] else { return nil }
        guard Self.hasOnlyScalarGPROperands(operands),
              let shifted = Self.shiftedRegisterValue(register: operands[2], shift: operands[3], state: state) else {
            return Self.unknownFallback(mnemonic: mnemonic, operands: operands, state: state)
        }

        let left = Self.value(for: operands[1], state: state)
        let destination = state.writeRegister(operands[0])
        return .binary(
            destination: destination,
            op: op,
            left: left,
            right: .unary(op: "~", value: shifted)
        )
    }

    /// Materializes a shifted register operand `Xm, lsl/lsr/asr #s` as `Xm << s` /
    /// `Xm >> s` (shift 0 → `Xm`), and `Xm, ror #s` (logical ops only) as the same rotate the
    /// standalone `ror` lowers to, `(Xm >> s) | (Xm << (width - s))`. A non-register base, a
    /// rotate amount outside the register width, or another keyword (the sxtw/uxtw
    /// extended-register forms) returns nil.
    private static func shiftedRegisterValue(register: String, shift: String, state: BuilderState) -> MacIRValue? {
        guard isRegister(register) else { return nil }
        let parts = shift.split(separator: " ").map(String.init)
        guard let keyword = parts.first?.lowercased(), ["lsl", "lsr", "asr", "ror"].contains(keyword) else {
            return nil
        }
        let amount = parts.dropFirst().first.flatMap(parseImmediate) ?? 0
        let base = value(for: register, state: state)
        if keyword == "ror" {
            // C5 (vim decompile sweep): SHA-style `eor w9, w9, w22, ror #11` stayed opaque (352
            // `__unknown`s in one function).
            guard let bitWidth = scalarRegisterBitWidth(register), amount >= 0, amount < Int64(bitWidth) else {
                return nil
            }
            if amount == 0 { return base }
            return .binaryExpression(
                op: "|",
                left: .binaryExpression(op: ">>", left: unsignedCast(base, width: bitWidth), right: .immediate(amount)),
                right: .binaryExpression(op: "<<", left: base, right: .immediate(Int64(bitWidth) - amount))
            )
        }
        if amount == 0 { return base }
        return .binaryExpression(op: keyword == "lsl" ? "<<" : ">>", left: shiftOperand(base, mnemonic: keyword, width: scalarRegisterBitWidth(register) ?? 64), right: .immediate(amount))
    }

    private static func extendedRegisterValue(register: String, extend: String, state: BuilderState) -> MacIRValue? {
        guard isRound2WDataRegister(register) else { return nil }
        let parts = extend
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
        guard let keyword = parts.first?.lowercased(),
              ["sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw"].contains(keyword) else {
            return nil
        }
        let amount = parts.dropFirst().first.flatMap(parseImmediate) ?? 0
        guard amount >= 0, amount <= 4 else { return nil }

        let base = value(for: register, state: state)
        let narrowed = MacIRValue.unary(op: extensionCast(for: keyword), value: base)
        guard amount != 0 else { return narrowed }

        let widenedCast = keyword.hasPrefix("s") ? "(int64_t)" : "(uint64_t)"
        return .binaryExpression(
            op: "<<",
            left: .unary(op: widenedCast, value: narrowed),
            right: .immediate(amount)
        )
    }

    private func multiplyAccumulateOperation(mnemonic: String, operands: [String], state: inout BuilderState, division: BuilderDivision?) -> MacIROperation {
        let requiredOperands = mnemonic == "mneg" ? 3 : 4
        guard operands.count == requiredOperands else {
            return Self.unknownFallback(mnemonic: mnemonic, operands: operands, state: state)
        }

        // Read every source operand before writing the destination so in-place
        // forms (for example madd x0, x0, x1, x2) observe the incoming versions.
        let factorA = Self.value(for: operands[1], state: state)
        let factorB = Self.value(for: operands[2], state: state)
        let product = MacIRValue.binaryExpression(op: "*", left: factorA, right: factorB)

        if mnemonic == "mneg" {
            let destination = state.writeRegister(operands[0])
            // Convert before multiplication AND negation; an outer cast is too late.
            // Legacy returns its original unary expression below.
            if ssaEnabled, let width = Self.scalarDataBitWidth(operands[0]),
               operands.dropFirst().allSatisfy({ Self.scalarDataBitWidth($0) == width }) {
                return .binary(destination: destination, op: "-",
                    left: Self.unsignedCast(.immediate(0), width: width),
                    right: .binaryExpression(op: "*",
                        left: Self.unsignedCast(factorA, width: width),
                        right: Self.unsignedCast(factorB, width: width)))
            }
            return .assign(destination: destination, source: .unary(op: "-", value: product))
        }

        let addend = Self.value(for: operands[3], state: state)
        // MADD is independent of the MSUB division/remainder recognition below.
        // Read all incoming values before writing; default mode takes no new write.
        if ssaEnabled, mnemonic == "madd",
           let width = Self.scalarDataBitWidth(operands[0]),
           operands.dropFirst().allSatisfy({ Self.scalarDataBitWidth($0) == width }) {
            let destination = state.writeRegister(operands[0])
            return .binary(destination: destination, op: "+",
                left: Self.unsignedCast(addend, width: width),
                right: .binaryExpression(op: "*",
                    left: Self.unsignedCast(factorA, width: width),
                    right: Self.unsignedCast(factorB, width: width)))
        }
        if mnemonic == "msub", let division, Self.scalarDataBitWidth(operands[0]) == division.width,
           addend == division.dividend,
           (factorA == division.quotient && factorB == division.divisor
            || factorB == division.quotient && factorA == division.divisor) {
            let destination = state.writeRegister(operands[0])
            return .intrinsic(destination: destination,
                              name: "a64_\(division.signed ? "srem" : "urem")\(division.width)",
                              arguments: [division.dividend, division.divisor])
        }
        let destination = state.writeRegister(operands[0])
        // SSA MSUB is modular at the destination width, including its nested product.
        // Legacy lifting takes the unchanged return below.
        if ssaEnabled, mnemonic == "msub",
           let width = Self.scalarDataBitWidth(operands[0]),
           operands.dropFirst().allSatisfy({ Self.scalarDataBitWidth($0) == width }) {
            return .binary(destination: destination, op: "-",
                left: Self.unsignedCast(addend, width: width),
                right: .binaryExpression(op: "*",
                    left: Self.unsignedCast(factorA, width: width),
                    right: Self.unsignedCast(factorB, width: width)))
        }
        return .binary(
            destination: destination,
            op: mnemonic == "madd" ? "+" : "-",
            left: addend,
            right: product
        )
    }

    private func wideningMultiplyOperation(mnemonic: String, operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard operands.count == 3,
              Self.hasOnlyScalarGPROperands(operands),
              Self.isXRegister(operands[0]),
              Self.isWRegister(operands[1]),
              Self.isWRegister(operands[2]) else {
            return nil
        }

        let signed = mnemonic == "smull"
        let left = Self.widenedWordValue(for: operands[1], signed: signed, state: state)
        let right = Self.widenedWordValue(for: operands[2], signed: signed, state: state)
        let destination = state.writeRegister(operands[0])
        return .binary(destination: destination, op: "*", left: left, right: right)
    }

    private func unsignedMultiplyAddLongOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard operands.count == 4,
              Self.hasOnlyScalarGPROperands(operands),
              Self.isXRegister(operands[0]),
              Self.isWRegister(operands[1]),
              Self.isWRegister(operands[2]),
              Self.isXRegister(operands[3]) else {
            return nil
        }

        let left = Self.widenedWordValue(for: operands[1], signed: false, state: state)
        let right = Self.widenedWordValue(for: operands[2], signed: false, state: state)
        let product = MacIRValue.binaryExpression(op: "*", left: left, right: right)
        let addend = Self.value(for: operands[3], state: state)
        let destination = state.writeRegister(operands[0])
        return .binary(destination: destination, op: "+", left: addend, right: product)
    }

    private func longMultiplyAccumulateOperation(
        mnemonic: String, operands: [String], state: inout BuilderState
    ) -> MacIROperation? {
        // Only the architectural Xd, Wn, Wm, Xa form. SP and numeric 31 are
        // not data registers here; malformed spellings must remain unknown.
        func dataRegister(_ operand: String, prefix: Character) -> Bool {
            let text = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text == "\(prefix)zr" { return true }
            guard text.first == prefix, let index = Int(text.dropFirst()),
                  (0...30).contains(index), text == "\(prefix)\(index)" else { return false }
            return true
        }
        guard ["smaddl", "smsubl", "umsubl"].contains(mnemonic), operands.count == 4,
              dataRegister(operands[0], prefix: "x"),
              dataRegister(operands[1], prefix: "w"),
              dataRegister(operands[2], prefix: "w"),
              dataRegister(operands[3], prefix: "x") else { return nil }
        let signed = mnemonic != "umsubl"
        // Capture all incoming SSA operands before writing an aliased Xd.
        let left = Self.widenedWordValue(for: operands[1], signed: signed, state: state)
        let right = Self.widenedWordValue(for: operands[2], signed: signed, state: state)
        let product = MacIRValue.binaryExpression(op: "*", left: left, right: right)
        let accumulator = Self.value(for: operands[3], state: state)
        let destination = state.writeRegister(operands[0])
        // Signed 32x32 fits Int64. Cast BOTH terms before the accumulation so
        // rendered C uses defined modulo-2^64 arithmetic even at wraparound.
        return .binary(destination: destination, op: mnemonic == "smaddl" ? "+" : "-",
            left: .unary(op: "(uint64_t)", value: accumulator),
            right: .unary(op: "(uint64_t)", value: product))
    }

    private func highMultiplyOperation(
        mnemonic: String,
        operands: [String],
        state: inout BuilderState
    ) -> MacIROperation? {
        guard operands.count == 3,
              Self.hasOnlyRound2ScalarGPROperands(operands),
              Self.isRound2XDataRegister(operands[0]),
              Self.isRound2XDataRegister(operands[1]),
              Self.isRound2XDataRegister(operands[2]) else {
            return nil
        }

        let left = Self.value(for: operands[1], state: state)
        let right = Self.value(for: operands[2], state: state)
        let destination = state.writeRegister(operands[0])
        return .intrinsic(destination: destination, name: mnemonic, arguments: [left, right])
    }

    private static func widenedWordValue(for operand: String, signed: Bool, state: BuilderState) -> MacIRValue {
        let source = value(for: operand, state: state)
        if signed {
            return .unary(op: "(int64_t)", value: .unary(op: "(int32_t)", value: source))
        }
        return .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: source))
    }

    private func unsignedBitfieldExtractOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        // Require the canonical four-operand form with well-formed bounds; any
        // malformed or out-of-range field falls through to the faithful
        // low-level rendering by returning nil.
        guard operands.count == 4,
              let lsb = Self.parseImmediate(operands[2]),
              let width = Self.parseImmediate(operands[3]),
              lsb >= 0,
              width >= 1,
              lsb + width <= 64,
              width < 64 else {
            return nil
        }

        // Read the source before writing the destination so in-place forms (for
        // example ubfx x0, x0, #4, #4) observe the incoming version.
        let source = Self.value(for: operands[1], state: state)
        // width is guaranteed in 1...63 by the guard above, so the unsigned mask
        // computation stays within UInt64 and never overflows on the - 1.
        let mask = MacIRValue.immediate(Int64(bitPattern: (UInt64(1) << UInt64(width)) - 1))

        // lsb == 0 makes the shift a no-op, so collapse it to a plain mask.
        let shifted = lsb == 0
            ? source
            : MacIRValue.binaryExpression(op: ">>", left: Self.unsignedCast(source, width: Self.scalarRegisterBitWidth(operands[0]) ?? 64), right: .immediate(lsb))
        let extracted = MacIRValue.binaryExpression(op: "&", left: shifted, right: mask)

        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: extracted)
    }

    private func signedBitfieldExtractOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard operands.count == 4,
              Self.hasOnlyScalarGPROperands(operands),
              let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
              Self.scalarRegisterBitWidth(operands[1]) == bitWidth,
              let lsb = Self.parseImmediate(operands[2]),
              let width = Self.parseImmediate(operands[3]),
              let origin = state.signedBitfieldOrigin(mnemonic: "sbfx", source: operands[1], destination: operands[0]),
              let field = MacIRSignedBitfield(source: Self.value(for: operands[1], state: state),
                  operandBits: bitWidth, sourceLSB: lsb, fieldBits: width, insertLSB: 0, origin: origin) else {
            return nil
        }

        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: .signedBitfield(field))
    }

    private func bitfieldInsertZeroOperation(
        operands: [String],
        signed: Bool,
        state: inout BuilderState
    ) -> MacIROperation? {
        if signed {
            guard operands.count == 4,
                  Self.hasOnlyScalarGPROperands(operands),
                  let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
                  Self.scalarRegisterBitWidth(operands[1]) == bitWidth,
                  let lsb = Self.parseImmediate(operands[2]),
                  let width = Self.parseImmediate(operands[3]),
                  let origin = state.signedBitfieldOrigin(mnemonic: "sbfiz", source: operands[1], destination: operands[0]),
                  let field = MacIRSignedBitfield(source: Self.value(for: operands[1], state: state),
                      operandBits: bitWidth, sourceLSB: 0, fieldBits: width, insertLSB: lsb, origin: origin) else {
                return nil
            }
            let destination = state.writeRegister(operands[0])
            return .assign(destination: destination, source: .signedBitfield(field))
        }
        guard operands.count == 4,
              Self.hasOnlyScalarGPROperands(operands),
              let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
              let lsb = Self.parseImmediate(operands[2]),
              let width = Self.parseImmediate(operands[3]),
              let field = Self.bitfieldParameters(lsb: lsb, width: width, bitWidth: bitWidth) else {
            return nil
        }

        let source = Self.value(for: operands[1], state: state)
        let masked = MacIRValue.binaryExpression(op: "&", left: source, right: .immediate(Int64(bitPattern: field.mask)))
        let inserted = Self.shiftedValue(masked, op: "<<", amount: field.lsb)

        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: inserted)
    }

    private func bitfieldInsertOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard operands.count == 4,
              Self.hasOnlyScalarGPROperands(operands),
              let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
              let lsb = Self.parseImmediate(operands[2]),
              let width = Self.parseImmediate(operands[3]),
              let field = Self.bitfieldParameters(lsb: lsb, width: width, bitWidth: bitWidth) else {
            return nil
        }

        let destinationOldValue = Self.value(for: operands[0], state: state)
        let source = Self.value(for: operands[1], state: state)
        let fieldMask = field.mask << UInt64(field.lsb)
        let preservedMask = Self.registerMask(bitWidth: bitWidth) & ~fieldMask
        let preserved = MacIRValue.binaryExpression(
            op: "&",
            left: destinationOldValue,
            right: .immediate(Int64(bitPattern: preservedMask))
        )
        let inserted = MacIRValue.binaryExpression(
            op: "&",
            left: Self.shiftedValue(source, op: "<<", amount: field.lsb),
            right: .immediate(Int64(bitPattern: fieldMask))
        )
        let combined = MacIRValue.binaryExpression(op: "|", left: preserved, right: inserted)
        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: combined)
    }

    private func bitfieldExtractInsertLowOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard operands.count == 4,
              Self.hasOnlyScalarGPROperands(operands),
              let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
              let lsb = Self.parseImmediate(operands[2]),
              let width = Self.parseImmediate(operands[3]),
              let field = Self.bitfieldParameters(lsb: lsb, width: width, bitWidth: bitWidth) else {
            return nil
        }

        let destinationOldValue = Self.value(for: operands[0], state: state)
        let source = Self.value(for: operands[1], state: state)
        let preservedMask = Self.registerMask(bitWidth: bitWidth) & ~field.mask
        let preserved = MacIRValue.binaryExpression(
            op: "&",
            left: destinationOldValue,
            right: .immediate(Int64(bitPattern: preservedMask))
        )
        let extracted = MacIRValue.binaryExpression(
            op: "&",
            left: Self.shiftedValue(source, op: ">>", amount: field.lsb),
            right: .immediate(Int64(bitPattern: field.mask))
        )
        let combined = MacIRValue.binaryExpression(op: "|", left: preserved, right: extracted)
        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: combined)
    }

    private func extractRegisterPairOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard operands.count == 4,
              Self.hasOnlyScalarGPROperands(operands),
              let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
              Self.scalarRegisterBitWidth(operands[1]) == bitWidth,
              Self.scalarRegisterBitWidth(operands[2]) == bitWidth,
              let lsb = Self.parseImmediate(operands[3]),
              lsb >= 0,
              lsb < Int64(bitWidth) else {
            return nil
        }

        let high = Self.value(for: operands[1], state: state)
        let low = Self.value(for: operands[2], state: state)
        let extracted: MacIRValue
        if lsb == 0 {
            extracted = low
        } else {
            extracted = .binaryExpression(
                op: "|",
                left: .binaryExpression(op: ">>", left: Self.unsignedCast(low, width: bitWidth), right: .immediate(lsb)),
                right: .binaryExpression(op: "<<", left: high, right: .immediate(Int64(bitWidth) - lsb))
            )
        }
        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: extracted)
    }

    /// `amount & (width - 1)`: an A64 register shift amount, taken modulo the register width.
    static func shiftAmountModWidth(_ amount: MacIRValue, bitWidth: Int) -> MacIRValue {
        .binaryExpression(op: "&", left: amount, right: .immediate(Int64(bitWidth - 1)))
    }

    private func rotateRightOperation(operands: [String], state: inout BuilderState) -> MacIROperation? {
        // Register amount (`rorv`): rotate by `n mod width`. The left half is masked too, so a
        // zero amount stays defined: `(x >> m) | (x << ((width - m) & (width - 1)))`.
        if operands.count == 3,
           Self.hasOnlyRound2ScalarGPROperands(operands),
           operands.allSatisfy(Self.isRound2DataRegister),
           let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
           Self.scalarRegisterBitWidth(operands[1]) == bitWidth,
           Self.parseImmediate(operands[2]) == nil {
            let source = Self.value(for: operands[1], state: state)
            let amount = Self.shiftAmountModWidth(Self.value(for: operands[2], state: state), bitWidth: bitWidth)
            let complement = Self.shiftAmountModWidth(
                .binaryExpression(op: "-", left: .immediate(Int64(bitWidth)), right: amount),
                bitWidth: bitWidth
            )
            let destination = state.writeRegister(operands[0])
            return .assign(destination: destination, source: .binaryExpression(
                op: "|",
                left: .binaryExpression(op: ">>", left: Self.unsignedCast(source, width: bitWidth), right: amount),
                right: .binaryExpression(op: "<<", left: source, right: complement)
            ))
        }
        guard operands.count == 3,
              Self.hasOnlyScalarGPROperands(operands),
              let bitWidth = Self.scalarRegisterBitWidth(operands[0]),
              Self.scalarRegisterBitWidth(operands[1]) == bitWidth,
              let amount = Self.parseImmediate(operands[2]),
              amount >= 0,
              amount < Int64(bitWidth) else {
            return nil
        }

        let source = Self.value(for: operands[1], state: state)
        let rotated: MacIRValue
        if amount == 0 {
            rotated = source
        } else {
            rotated = .binaryExpression(
                op: "|",
                left: .binaryExpression(op: ">>", left: Self.unsignedCast(source, width: bitWidth), right: .immediate(amount)),
                right: .binaryExpression(op: "<<", left: source, right: .immediate(Int64(bitWidth) - amount))
            )
        }
        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: rotated)
    }

    private static func bitfieldParameters(lsb: Int64, width: Int64, bitWidth: Int) -> (lsb: Int64, width: Int64, mask: UInt64)? {
        guard lsb >= 0,
              width >= 1,
              lsb + width <= Int64(bitWidth) else {
            return nil
        }
        let mask = width == 64 ? UInt64.max : (UInt64(1) << UInt64(width)) - 1
        return (lsb, width, mask)
    }

    private static func shiftedValue(_ value: MacIRValue, op: String, amount: Int64) -> MacIRValue {
        amount == 0 ? value : .binaryExpression(op: op, left: value, right: .immediate(amount))
    }

    private func flagSettingSubtractionOperation(
        operands: [String],
        sourceAddress: UInt64,
        state: inout BuilderState
    ) -> MacIROperation {
        guard operands.count == 3 else {
            return Self.unknownFallback(mnemonic: "subs", operands: operands, state: state)
        }

        let left = Self.value(for: operands[1], state: state)
        let right = Self.value(for: operands[2], state: state)
        let comparison = BuilderComparison(left: left, right: right, sourceAddress: sourceAddress)
        state.recordPlainComparison(comparison)

        if Self.isZeroRegister(operands[0]) {
            return .intrinsic(
                destination: nil,
                name: "compare",
                arguments: [left, right]
            )
        }

        let destination = state.writeRegister(operands[0])
        state.recordFrameBase(destination: operands[0], left: operands[1], op: "-", right: operands[2])
        return .binary(
            destination: destination,
            op: "-",
            left: left,
            right: right
        )
    }

    private func flagSettingAdditionOperation(
        operands: [String],
        sourceAddress: UInt64,
        state: inout BuilderState
    ) -> MacIROperation {
        guard operands.count == 3 else {
            return Self.unknownFallback(mnemonic: "adds", operands: operands, state: state)
        }

        let left = Self.value(for: operands[1], state: state)
        let right = Self.value(for: operands[2], state: state)
        // adds sets NZCV for Xn + Xm, i.e. it compares Xn against -Xm exactly
        // like the cmn alias (adds XZR, Xn, Xm). Seed the comparison with the
        // negated right operand so a following conditional folds correctly; the
        // destination still receives the true sum.
        let negatedRight = Self.negatedValue(for: operands[2], state: state)
        let comparison = BuilderComparison(left: left, right: negatedRight, sourceAddress: sourceAddress)
        state.recordPlainComparison(comparison)

        if Self.isZeroRegister(operands[0]) {
            return .intrinsic(
                destination: nil,
                name: "compare",
                arguments: [left, negatedRight]
            )
        }

        let destination = state.writeRegister(operands[0])
        state.recordFrameBase(destination: operands[0], left: operands[1], op: "+", right: operands[2])
        return .binary(
            destination: destination,
            op: "+",
            left: left,
            right: right
        )
    }

    private static func extensionCast(for mnemonic: String) -> String {
        switch mnemonic {
        case "sxtb":
            return "(int8_t)"
        case "sxth":
            return "(int16_t)"
        case "sxtw":
            return "(int32_t)"
        case "uxtb":
            return "(uint8_t)"
        case "uxth":
            return "(uint16_t)"
        case "uxtw":
            return "(uint32_t)"
        default:
            return ""
        }
    }

    static func loadStoreByteWidth(mnemonic: String, register: String) -> Int? {
        switch mnemonic {
        case "ldrb", "ldrsb", "strb", "ldurb", "ldursb", "sturb":
            return 1
        case "ldrh", "ldrsh", "strh", "ldurh", "ldursh", "sturh":
            return 2
        case "ldrsw", "ldursw":
            return 4
        default:
            return byteWidth(forRegister: register)
        }
    }

    private static func isLosslessStackValueStore(_ mnemonic: String) -> Bool {
        mnemonic == "str" || mnemonic == "stur"
    }

    private static func isLosslessStackValueLoad(_ mnemonic: String) -> Bool {
        mnemonic == "ldr" || mnemonic == "ldur"
    }

    fileprivate static func stackSlotCarrierKind(forRegister register: String) -> StackSlotCarrierKind? {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "fp" || normalized == "lr" {
            return .integer
        }
        switch normalized.first {
        case "x", "w":
            return .integer
        case "d", "s":
            return .scalarFP
        case "q", "v":
            return .vector
        default:
            return nil
        }
    }

    /// The element type recovered from a sized load/store mnemonic.
    ///
    /// The encoded access width and signedness are unambiguous: a `ldrb` reads
    /// exactly one zero-extended byte (`uint8_t`), `ldrsb` reads one
    /// sign-extended byte (`int8_t`), and so on. The plain register-width forms
    /// (`ldr`/`ldur`/`str`/`stur`) carry no element evidence and return `nil` so
    /// the existing register-width type hint stays in force.
    static func sizedAccessElementType(mnemonic: String) -> String? {
        switch mnemonic {
        case "ldrb", "strb", "ldurb", "sturb":
            return "uint8_t"
        case "ldrsb", "ldursb":
            return "int8_t"
        case "ldrh", "strh", "ldurh", "sturh":
            return "uint16_t"
        case "ldrsh", "ldursh":
            return "int16_t"
        case "ldrsw", "ldursw":
            return "int32_t"
        default:
            return nil
        }
    }

    private func flagSettingNegationOperation(
        operands: [String],
        sourceAddress: UInt64,
        state: inout BuilderState
    ) -> MacIROperation {
        guard operands.count == 2 else {
            return Self.unknownFallback(mnemonic: "negs", operands: operands, state: state)
        }

        // negs is `subs Xd, XZR, Xm`, so the comparison is 0 - Xm; seed
        // (left: 0, right: Xm) exactly like subs seeds (left, right).
        let right = Self.value(for: operands[1], state: state)
        let comparison = BuilderComparison(left: .immediate(0), right: right, sourceAddress: sourceAddress)
        state.recordPlainComparison(comparison)

        if Self.isZeroRegister(operands[0]) {
            return .intrinsic(
                destination: nil,
                name: "compare",
                arguments: [.immediate(0), right]
            )
        }

        let destination = state.writeRegister(operands[0])
        return .assign(destination: destination, source: .unary(op: "-", value: right))
    }

    private func bitClearStyleOperation(_ op: String, operands: [String], state: inout BuilderState) -> MacIROperation {
        guard operands.count == 3 else {
            return Self.unknownFallback(mnemonic: op, operands: operands, state: state)
        }

        // Read both sources before writing the destination so in-place forms
        // (for example bic x0, x0, x1) observe the incoming versions.
        let left = Self.value(for: operands[1], state: state)
        let right = Self.value(for: operands[2], state: state)
        let destination = state.writeRegister(operands[0])
        return .binary(
            destination: destination,
            op: op,
            left: left,
            right: .unary(op: "~", value: right)
        )
    }

    private static func negatedValue(for operand: String, state: BuilderState) -> MacIRValue {
        if let immediate = parseImmediate(operand) {
            return .immediate(Int64(bitPattern: 0 &- UInt64(bitPattern: immediate)))
        }
        return .unary(op: "-", value: value(for: operand, state: state))
    }

    private func conditionalCompare(
        mnemonic: String,
        operands: [String],
        sourceAddress: UInt64,
        firstComparison: BuilderComparison,
        state: BuilderState
    ) -> PendingConditionalCompare? {
        guard operands.count == 4,
              Self.isRegister(operands[0]),
              Self.isRegister(operands[1]) || Self.parseImmediate(operands[1]) != nil,
              let nzcv = Self.parseImmediate(operands[2]),
              (0...0xf).contains(nzcv) else {
            return nil
        }
        let guardSuffix = operands[3].lowercased()
        guard guardSuffix != "al",
              guardSuffix != "nv",
              Self.branchCondition(for: guardSuffix) != nil else {
            return nil
        }
        if firstComparison.flagsKind == .logicalResult,
           guardSuffix != "eq",
           guardSuffix != "ne" {
            return nil
        }

        let right: MacIRValue = mnemonic == "ccmn"
            ? Self.negatedValue(for: operands[1], state: state)
            : Self.value(for: operands[1], state: state)
        return PendingConditionalCompare(
            mnemonic: mnemonic,
            left: Self.value(for: operands[0], state: state),
            right: right,
            nzcv: UInt8(nzcv),
            guardSuffix: guardSuffix,
            firstComparison: firstComparison,
            sourceAddress: sourceAddress,
            ccmnWidth: mnemonic == "ccmn" ? Self.scalarDataBitWidth(operands[0]) : nil,
            ccmnAddendWasImmediate: mnemonic == "ccmn" && Self.parseImmediate(operands[1]) != nil
        )
    }

    private func conditionalCompareIntrinsic(
        mnemonic: String,
        operands: [String],
        state: BuilderState
    ) -> MacIROperation? {
        guard operands.count == 4,
              Self.isRegister(operands[0]),
              Self.isRegister(operands[1]) || Self.parseImmediate(operands[1]) != nil,
              let nzcv = Self.parseImmediate(operands[2]),
              (0...0xf).contains(nzcv) else {
            return nil
        }

        let suffix = operands[3].lowercased()
        guard !suffix.isEmpty else { return nil }

        var right: MacIRValue = mnemonic == "ccmn"
            ? Self.negatedValue(for: operands[1], state: state)
            : Self.value(for: operands[1], state: state)
        if mnemonic == "ccmn", Self.parseImmediate(operands[1]) == nil {
            guard let width = Self.scalarDataBitWidth(operands[0]),
                  let bits = Self.compoundUnsignedAtom(Self.value(for: operands[1], state: state), width: width) else { return nil }
            right = Self.unsignedCast(.binaryExpression(op: "-",
                left: Self.unsignedCast(.immediate(0), width: width), right: bits), width: width)
        }
        return .intrinsic(
            destination: nil,
            name: "conditional_compare_\(suffix)",
            arguments: [
                Self.value(for: operands[0], state: state),
                right,
                .immediate(nzcv)
            ]
        )
    }

    /// A subtraction relation can reuse addition flags only outside its exact
    /// width-specific C/V exceptions. This gate does not add new suffix support.
    private static func compoundAdditionTermIsEquivalent(
        suffix: String,
        addend: MacIRValue?,
        addendWasImmediate: Bool,
        width: Int?,
        addendIsNegated: Bool = false
    ) -> Bool {
        let usesCarry: Bool
        switch suffix.lowercased() {
        case "eq", "ne", "mi", "pl":
            return true
        case "hs", "cs", "lo", "cc", "hi", "ls":
            usesCarry = true
        case "ge", "lt", "gt", "le", "vs", "vc":
            usesCarry = false
        default:
            return false
        }
        guard addendWasImmediate, let width, width == 32 || width == 64,
              let addend, case let .immediate(value) = addend else { return false }
        // CCMN retains -b; undo that representation with defined unsigned wrap.
        // Then project to the instruction width before testing either exception.
        let storedBits = UInt64(bitPattern: value)
        let originalBits = addendIsNegated ? UInt64(0) &- storedBits : storedBits
        let bits = originalBits & (width == 32 ? UInt64(0xffff_ffff) : UInt64.max)
        return usesCarry ? bits != 0 : bits != (UInt64(1) << (width - 1))
    }

    // A cast after signed arithmetic cannot establish modular C semantics.
    private static func compoundUnsignedAtom(_ value: MacIRValue, width: Int) -> MacIRValue? {
        guard width == 32 || width == 64 else { return nil }
        switch value {
        case .register, .argument:
            return unsignedCast(value, width: width)
        case let .immediate(number):
            // These negative hex literals negate as unsigned int before widening.
            if width == 64, number <= -2_147_483_648, number >= -4_294_967_295 {
                return unsignedCast(.binaryExpression(op: "-",
                    left: unsignedCast(.immediate(0), width: width),
                    right: unsignedCast(.immediate(-number), width: width)), width: width)
            }
            return unsignedCast(value, width: width)
        case let .unary(op, inner) where op == "(uint32_t)" || op == "(uint64_t)":
            guard let projected = compoundUnsignedAtom(inner, width: op == "(uint32_t)" ? 32 : 64) else { return nil }
            return unsignedCast(projected, width: width)
        default: return nil
        }
    }

    // Machine flag equivalence does not by itself establish C expression types.
    private static func compoundComparisonTerm(
        suffix: String,
        left: MacIRValue,
        right: MacIRValue,
        isAddition: Bool,
        additionWidth: Int?,
        argumentBitWidths: [MacIRParameterBindingID: Int],
        projectSigned: Bool
    ) -> MacIRValue? {
        guard isAddition else {
            return comparisonTerm(suffix: suffix, left: left, right: right,
                argumentBitWidths: argumentBitWidths, projectSigned: projectSigned)
        }
        guard let width = additionWidth, width == 32 || width == 64,
              let condition = branchCondition(for: suffix),
              let unsignedLeft = compoundUnsignedAtom(left, width: width) else { return nil }
        if suffix == "eq" || suffix == "ne" {
            let negated: MacIRValue
            switch right {
            case .immediate:
                guard let bits = compoundUnsignedAtom(right, width: width) else { return nil }
                negated = bits
            case let .unary("-", addend):
                guard let bits = compoundUnsignedAtom(addend, width: width) else { return nil }
                negated = unsignedCast(.binaryExpression(op: "-",
                    left: unsignedCast(.immediate(0), width: width), right: bits), width: width)
            default: return nil
            }
            return .binaryExpression(op: condition, left: unsignedLeft, right: negated)
        }
        if isUnsignedConditionSuffix(suffix) {
            guard let unsignedRight = compoundUnsignedAtom(right, width: width) else { return nil }
            return .binaryExpression(op: condition, left: unsignedLeft, right: unsignedRight)
        }
        guard ["ge", "lt", "gt", "le"].contains(suffix) else { return nil }
        func signedOperand(_ value: MacIRValue, partner: MacIRValue) -> MacIRValue? {
            if case let .immediate(number) = value,
               (width == 32 && (number < Int64(Int32.min) || number > Int64(Int32.max)))
                || number == Int64.min || (number <= -2_147_483_648 && number >= -4_294_967_295) {
                guard let bits = compoundUnsignedAtom(value, width: width) else { return nil }
                return signedProjection(bits, width: width, partner: partner)
            }
            guard compoundUnsignedAtom(value, width: width) != nil else { return nil }
            return signedProjection(value, width: width, partner: partner)
        }
        guard let signedLeft = signedOperand(left, partner: right),
              let signedRight = signedOperand(right, partner: left) else { return nil }
        return .binaryExpression(op: condition, left: signedLeft, right: signedRight)
    }

    private static func compoundCondition(
        for pending: PendingConditionalCompare,
        branchSuffix: String,
        branchAddress: UInt64,
        argumentBitWidths: [MacIRParameterBindingID: Int],
        carriedAcrossFlagNeutralRows: Bool = false,
        projectSigned: Bool = false
    ) -> MacIRValue? {
        let normalizedBranchSuffix = branchSuffix.lowercased()
        guard pending.mnemonic != "ccmn" || compoundAdditionTermIsEquivalent(
            suffix: normalizedBranchSuffix, addend: pending.right,
            addendWasImmediate: pending.ccmnAddendWasImmediate,
            width: pending.ccmnWidth, addendIsNegated: true
        ), pending.firstComparison.cmnAddend == nil || compoundAdditionTermIsEquivalent(
            suffix: pending.guardSuffix, addend: pending.firstComparison.cmnAddend,
            addendWasImmediate: pending.firstComparison.cmnAddendWasImmediate,
            width: pending.firstComparison.cmnWidth
        ) else { return nil }
        // A26: under SSA the carried state itself proves the rows between are
        // same-block and flag-neutral, so source-address adjacency is not needed.
        guard let compareAddress = pending.firstComparison.sourceAddress,
              carriedAcrossFlagNeutralRows
                || (compareAddress.isContiguous(to: pending.sourceAddress)
                    && pending.sourceAddress.isContiguous(to: branchAddress)),
              branchCondition(for: normalizedBranchSuffix) != nil,
              let branchIfFirstConditionFails = conditionHolds(suffix: normalizedBranchSuffix, nzcv: pending.nzcv),
              let secondTerm = compoundComparisonTerm(
                suffix: normalizedBranchSuffix,
                left: pending.left,
                right: pending.right,
                isAddition: pending.mnemonic == "ccmn",
                additionWidth: pending.ccmnWidth,
                argumentBitWidths: argumentBitWidths,
                projectSigned: projectSigned
              ) else {
            return nil
        }

        if branchIfFirstConditionFails {
            guard let invertedGuardSuffix = invertedConditionSuffix(for: pending.guardSuffix),
                  pending.firstComparison.cmnAddend == nil || compoundAdditionTermIsEquivalent(
                    suffix: invertedGuardSuffix, addend: pending.firstComparison.cmnAddend,
                    addendWasImmediate: pending.firstComparison.cmnAddendWasImmediate,
                    width: pending.firstComparison.cmnWidth
                  ),
                  let firstTerm = compoundComparisonTerm(
                    suffix: invertedGuardSuffix,
                    left: pending.firstComparison.left,
                    right: pending.firstComparison.right,
                    isAddition: pending.firstComparison.cmnAddend != nil,
                    additionWidth: pending.firstComparison.cmnWidth,
                    argumentBitWidths: argumentBitWidths,
                    projectSigned: projectSigned
                  ) else {
                return nil
            }
            return .binaryExpression(op: "||", left: firstTerm, right: secondTerm)
        }

        guard let firstTerm = compoundComparisonTerm(
            suffix: pending.guardSuffix,
            left: pending.firstComparison.left,
            right: pending.firstComparison.right,
            isAddition: pending.firstComparison.cmnAddend != nil,
            additionWidth: pending.firstComparison.cmnWidth,
            argumentBitWidths: argumentBitWidths,
            projectSigned: projectSigned
        ) else {
            return nil
        }
        return .binaryExpression(op: "&&", left: firstTerm, right: secondTerm)
    }

    /// A28: remember which cmp;ccmp pair a lifted compound condition consumed.
    func recordCompoundChain(_ pending: PendingConditionalCompare, state: inout BuilderState) {
        guard ssaEnabled, let compare = pending.firstComparison.sourceAddress else { return }
        state.ssaCompoundChains.append(.init(compare: compare, conditionalCompare: pending.sourceAddress))
    }

    /// A27: the condition `suffix` evaluated on every incoming edge's own
    /// comparison, merged by a boolean phi at the join. Nil (no partial lift)
    /// unless every incoming is a recorded plain subtraction comparison.
    func flagsPhiCondition(suffix: String, state: inout BuilderState) -> MacIRValue? {
        guard ssaEnabled, let context = state.flagsPhiContext, !context.incomings.isEmpty,
              Self.branchCondition(for: suffix) != nil else { return nil }
        var incoming: [MacIRPhi.Incoming] = []
        for item in context.incomings {
            guard item.comparison.flagsKind == .subtraction,
                  Self.canResolveComparisonSuffix(suffix, for: item.comparison),
                  item.comparison.cmnAddend == nil || Self.compoundAdditionTermIsEquivalent(
                    suffix: suffix, addend: item.comparison.cmnAddend,
                    addendWasImmediate: item.comparison.cmnAddendWasImmediate,
                    width: item.comparison.cmnWidth),
                  let term = Self.compoundComparisonTerm(
                    suffix: suffix.lowercased(),
                    left: item.comparison.left,
                    right: item.comparison.right,
                    isAddition: item.comparison.cmnAddend != nil,
                    additionWidth: item.comparison.cmnWidth,
                    argumentBitWidths: state.argumentBitWidths,
                    projectSigned: true) else { return nil }
            incoming.append(.init(predecessorAddress: item.predecessorAddress, value: term))
        }
        let destination = MacIRValue.register(
            name: "flag_\(String(context.rowAddress, radix: 16))_\(suffix.lowercased())", version: 0)
        for item in context.incomings { if let address = item.comparison.sourceAddress { state.ssaFlagPhiComparisons.insert(address) } }
        state.ssaFlagPhis.append(MacIRPhi(
            blockAddress: context.blockAddress, destination: destination, bitWidth: 32, incoming: incoming))
        return destination
    }

    private static func comparisonTerm(
        suffix: String,
        left: MacIRValue,
        right: MacIRValue,
        argumentBitWidths: [MacIRParameterBindingID: Int],
        projectSigned: Bool = false
    ) -> MacIRValue? {
        guard let condition = branchCondition(for: suffix) else { return nil }
        if isUnsignedConditionSuffix(suffix) {
            let width = comparisonBitWidth(
                left: left,
                right: right,
                argumentBitWidths: argumentBitWidths
            )
            return .binaryExpression(
                op: condition,
                left: unsignedCast(left, width: width),
                right: unsignedCast(right, width: width)
            )
        }
        if projectSigned, ["ge", "lt", "gt", "le"].contains(suffix.lowercased()) {
            let width = comparisonBitWidth(left: left, right: right, argumentBitWidths: argumentBitWidths)
            return .binaryExpression(op: condition,
                left: signedProjection(left, width: width, partner: right),
                right: signedProjection(right, width: width, partner: left))
        }
        return .binaryExpression(op: condition, left: left, right: right)
    }

    private static func conditionHolds(suffix: String, nzcv: UInt8) -> Bool? {
        let n = (nzcv & 0b1000) != 0
        let z = (nzcv & 0b0100) != 0
        let c = (nzcv & 0b0010) != 0
        let v = (nzcv & 0b0001) != 0
        switch suffix.lowercased() {
        case "eq":
            return z
        case "ne":
            return !z
        case "cs", "hs":
            return c
        case "cc", "lo":
            return !c
        case "hi":
            return c && !z
        case "ls":
            return !c || z
        case "ge":
            return n == v
        case "lt":
            return n != v
        case "gt":
            return !z && n == v
        case "le":
            return z || n != v
        default:
            return nil
        }
    }

    static func isUnsignedConditionSuffix(_ suffix: String) -> Bool {
        switch suffix.lowercased() {
        case "cs", "hs", "cc", "lo", "hi", "ls":
            return true
        default:
            return false
        }
    }

    private static func canResolveComparisonSuffix(_ suffix: String, for comparison: BuilderComparison) -> Bool {
        guard comparison.flagsKind == .logicalResult else { return true }
        switch suffix.lowercased() {
        case "eq", "ne", "lt", "le", "gt", "ge":
            return true
        default:
            return false
        }
    }

    static func comparisonBitWidth(
        left: MacIRValue,
        right: MacIRValue,
        argumentBitWidths: [MacIRParameterBindingID: Int]
    ) -> Int {
        bitWidth(forComparisonOperand: left, argumentBitWidths: argumentBitWidths)
            ?? bitWidth(forComparisonOperand: right, argumentBitWidths: argumentBitWidths)
            ?? 64
    }

    private static func bitWidth(
        forComparisonOperand value: MacIRValue,
        argumentBitWidths: [MacIRParameterBindingID: Int]
    ) -> Int? {
        switch value {
        case let .argument(bindingID):
            return argumentBitWidths[bindingID]
        case let .register(name, _):
            return name.lowercased().hasPrefix("w") ? 32 : 64
        case let .unary(op, _) where op.contains("32"):
            return 32
        case let .unary(op, _) where op.contains("64"):
            return 64
        case let .unary(_, inner):
            return bitWidth(forComparisonOperand: inner, argumentBitWidths: argumentBitWidths)
        default:
            return nil
        }
    }

    private static func unsignedCast(_ value: MacIRValue, width: Int) -> MacIRValue {
        .unary(op: width == 32 ? "(uint32_t)" : "(uint64_t)", value: value)
    }

    private static func isBitTestComparison(_ comparison: BuilderComparison) -> Bool {
        if case .bitTest = comparison.left, comparison.right == .immediate(0) {
            return true
        }
        if case .bitTest = comparison.right, comparison.left == .immediate(0) {
            return true
        }
        return false
    }

    /// Matches the `objc_msgSend` call target in either the underscore-prefixed
    /// disassembly form (`_objc_msgSend`) or the canonical form. Scoped to plain
    /// `objc_msgSend` for now; `objc_msgSendSuper` (different argument layout) is
    /// intentionally left for a follow-up.
    private static func isObjCMessageSendTarget(_ target: String) -> Bool {
        let symbol = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
        return canonical == "objc_msgSend"
    }

    static func knownCallSignature(for target: String) -> MacIRCallSignature? {
        CallSignatureCatalog.standard.signature(for: target)
    }

    private static let returningCallMnemonics: Set<String> = [
        "bl", "blr", "blraa", "blrab", "blraaz", "blrabz",
    ]

    static func hasValidReturningCallOperands(
        mnemonic: String,
        operands: [String]
    ) -> Bool {
        switch mnemonic.lowercased() {
        case "bl":
            return operands.count == 1 && isValidDirectCallTarget(operands[0])
        case "blr", "blraaz", "blrabz":
            return operands.count == 1
                && isCanonicalBranchRegister(operands[0])
        case "blraa", "blrab":
            return operands.count == 2
                && isCanonicalBranchRegister(operands[0])
                && isCanonicalAuthenticatedModifier(operands[1])
        default:
            return false
        }
    }

    /// A returning indirect branch consumes a 64-bit general-purpose register.
    /// Keep this stricter than `isRegister`, which intentionally recognizes FP,
    /// SIMD, stack-pointer, aliases, and synthetic spellings for general operand
    /// parsing. The decoder emits this operand class only as canonical x0...x30.
    private static func isCanonicalBranchRegister(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let view = integerRegisterView(normalized) else { return false }
        return view.width == 64
    }

    private static func isCanonicalAuthenticatedModifier(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "sp" || isCanonicalBranchRegister(normalized)
    }

    /// Direct branch-with-link rows name an absolute address or a resolved symbol.
    /// Reject register and memory spellings so malformed synthetic rows cannot
    /// acquire call semantics merely by carrying one nonempty operand.
    private static func isValidDirectCallTarget(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              !normalized.hasPrefix("#"),
              !normalized.contains("["),
              !normalized.contains("]"),
              !isRegister(normalized),
              !isZeroRegister(normalized) else {
            return false
        }
        return true
    }

    private static func recoverFunctionParameters<Row: DecompilerInstructionRow>(from rows: [Row]) -> [MacIRFunctionParameter] {
        var parametersByIndex: [Int: MacIRFunctionParameter] = [:]
        var evidenceByIndex: [Int: MacIRParameterEvidence] = [:]
        var writtenArgumentIndexes: Set<Int> = []
        // FP-class params accumulate separately, keyed by FP register number
        // (d0-d7 / s0-s7). The register-number namespace overlaps the integer
        // one (both 0..<8), so these must never share a dictionary/set with
        // the integer accumulators above.
        var fpParametersByIndex: [Int: MacIRFunctionParameter] = [:]
        var fpEvidenceByIndex: [Int: MacIRParameterEvidence] = [:]
        var writtenFPArgumentIndexes: Set<Int> = []


        for row in rows {
            let mnemonic = row.mnemonic.lowercased()
            let operands = splitOperands(row.operands)

            for register in argumentRegisterReads(mnemonic: mnemonic, operands: operands) {
                guard let info = argumentRegisterInfo(register) else { continue }
                if info.isFloat {
                    // Integer bits in an S/D lane do not prove an ABI float formal.
                    // Keep the genuine register read in the effect table, but do not
                    // manufacture a floating declaration from this use alone.
                    if let conversion = scalarFPSemantics(mnemonic: mnemonic, operands: operands),
                       conversion.operation == .fromInteger, conversion.integerCarrier == .scalarSIMDBits { continue }
                    guard !writtenFPArgumentIndexes.contains(info.index) else { continue }
                    let existing = fpParametersByIndex[info.index]
                    let merged = mergedParameter(existing, with: info)
                    fpParametersByIndex[info.index] = merged
                    if existing == nil || existing != merged {
                        fpEvidenceByIndex[info.index] = .heuristicEntryRead
                    }
                } else {
                    guard !writtenArgumentIndexes.contains(info.index) else { continue }
                    let existing = parametersByIndex[info.index]
                    let merged = mergedParameter(existing, with: info)
                    parametersByIndex[info.index] = merged
                    if existing == nil || existing != merged {
                        evidenceByIndex[info.index] = .heuristicEntryRead
                    }
                }
            }

            if mnemonic == "bl",
               hasValidReturningCallOperands(mnemonic: mnemonic, operands: operands),
               let target = operands.first,
               let signature = knownCallSignature(for: target) {
                for parameter in signature.parameters {
                    if CallSignatureCatalog.typeClass(parameter.type) == .float {
                        // FP catalog params (e.g. sin/pow's `double` in d0) must be
                        // classified by register CLASS and routed into the FP
                        // accumulator keyed by their FP register number — gated by
                        // the FP write set. Routing them into the integer bucket
                        // (gated only by the integer write set) fabricated a bogus
                        // double param and could duplicate a genuine FP param that
                        // was also recovered from a direct d/s read.
                        guard let fpRegNum = fpRegisterNumber(parameter.register),
                              !writtenFPArgumentIndexes.contains(fpRegNum) else { continue }
                        let existing = fpParametersByIndex[fpRegNum]
                        let merged = mergedParameter(existing, with: parameter)
                        fpParametersByIndex[fpRegNum] = merged
                        if existing == nil || existing != merged {
                            fpEvidenceByIndex[fpRegNum] = .knownCallTypeConstraint
                        }
                    } else {
                        // Key/gate the integer seed by the param's REGISTER number,
                        // not its source position. assignRegisters advances the x/w
                        // (NGRN) and d/s (NSRN) counters independently, so in a mixed
                        // float-before-integer signature (e.g. frexp(double, int*):
                        // value=d0 index0, exp=x0 but index1) the source position
                        // exceeds the x/w register number. Keying by position would
                        // mis-gate against writtenArgumentIndexes (which is keyed by
                        // register number) and fabricate/duplicate an integer param.
                        // Symmetric with the FP branch and the direct-read path.
                        guard let regNum = argumentRegisterInfo(parameter.register)?.index,
                              !writtenArgumentIndexes.contains(regNum) else { continue }
                        let existing = parametersByIndex[regNum]
                        let merged = mergedParameter(existing, with: parameter)
                        parametersByIndex[regNum] = merged
                        if existing == nil || existing != merged {
                            evidenceByIndex[regNum] = .knownCallTypeConstraint
                        }
                    }
                }
                if let resultRegister = CallSignatureCatalog.returnRegister(for: signature.returnType),
                   let resultInfo = argumentRegisterInfo(resultRegister) {
                    if resultInfo.isFloat {
                        writtenFPArgumentIndexes.insert(resultInfo.index)
                    } else {
                        writtenArgumentIndexes.insert(resultInfo.index)
                    }
                }
            }

            if returningCallMnemonics.contains(mnemonic),
               hasValidReturningCallOperands(mnemonic: mnemonic, operands: operands) {
                writtenArgumentIndexes.formUnion(0..<8)
                writtenFPArgumentIndexes.formUnion(0..<8)
            }

            for register in argumentRegisterWrites(mnemonic: mnemonic, operands: operands) {
                if let info = argumentRegisterInfo(register) {
                    if info.isFloat {
                        writtenFPArgumentIndexes.insert(info.index)
                    } else {
                        writtenArgumentIndexes.insert(info.index)
                    }
                }
            }

        }

        let integerKeys = parametersByIndex.keys.sorted()
        let floatingKeys = fpParametersByIndex.keys.sorted()
        let denseIntegerOnly = floatingKeys.isEmpty
            && integerKeys == Array(0..<integerKeys.count)
        let denseFloatingOnly = integerKeys.isEmpty
            && floatingKeys == Array(0..<floatingKeys.count)

        func recoveredParameter(
            _ parameter: MacIRFunctionParameter,
            legacyIndex: Int,
            sourcePosition: Int?,
            evidence: MacIRParameterEvidence
        ) -> MacIRFunctionParameter {
            guard let bindingID = parameter.bindingID,
                  var recovered = MacIRFunctionParameter(
                    id: .recovered(bindingID),
                    bindingID: bindingID,
                    sourcePosition: sourcePosition,
                    abiLocation: parameter.abiLocation,
                    type: parameter.type,
                    name: sourcePosition.map { "arg\($0)" },
                    evidence: evidence
                  ) else {
                preconditionFailure("recovered ABI parameter must have a valid binding/location pair")
            }
            // Transitional compatibility for callers that still display the old
            // integer slot. Identity and body binding never consult this field.
            recovered.index = legacyIndex
            return recovered
        }

        let intParams = integerKeys.enumerated().map { ordinal, key in
            recoveredParameter(
                parametersByIndex[key]!,
                legacyIndex: key,
                sourcePosition: denseIntegerOnly ? ordinal : nil,
                evidence: evidenceByIndex[key] ?? .heuristicEntryRead
            )
        }
        let fpLegacyBase = (integerKeys.max() ?? -1) + 1
        let fpParams = floatingKeys.enumerated().map { ordinal, key in
            recoveredParameter(
                fpParametersByIndex[key]!,
                legacyIndex: fpLegacyBase + key,
                sourcePosition: denseFloatingOnly ? ordinal : nil,
                evidence: fpEvidenceByIndex[key] ?? .heuristicEntryRead
            )
        }
        return intParams + fpParams
    }

    static func unmodeledMemoryWriteTargetsProvenStack(
        mnemonic: String,
        operands: [String],
        state: BuilderState
    ) -> Bool {
        guard unmodeledMemoryWritePrefixes.contains(where: mnemonic.hasPrefix)
                || isMemoryOperationMnemonic(mnemonic) else {
            return false
        }
        return operands.contains { operand in
            guard let base = bracketedMemoryBase(operand) else { return false }
            return base == "sp" || state.knownStackBaseOffset(for: base) != nil
        }
    }

    private static func bracketedMemoryBase(_ operand: String) -> String? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix("!") {
            normalized.removeLast()
        }
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else {
            return nil
        }
        let parts = splitOperands(String(normalized.dropFirst().dropLast()))
        guard let first = parts.first else { return nil }
        return memoryBaseRegister(first)
    }

    static func memoryBaseRegister(_ operand: String) -> String? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "sp" {
            return "sp"
        }
        return writebackBaseRegister(normalized)
    }

    /// Pair writeback is simultaneous: data accesses use the old/pre-indexed base,
    /// then the explicit SSA base destination receives oldBase + delta.
    private func stackPairWritebackOperation(mnemonic: String, operands: [String], state: inout BuilderState) -> MacIROperation? {
        guard operands.count >= 3,
              let writeback = Self.scalarWritebackAddress(operands: Array(operands.dropFirst())),
              writeback.base == "sp",
              writeback.delta != 0 || !writeback.preIndex,
              Self.pairElementByteWidth(mnemonic: mnemonic, register: operands[0]) != nil,
              Self.pairElementByteWidth(for: operands[0]) == Self.pairElementByteWidth(for: operands[1]) else { return nil }
        let base = state.readRegister("sp")
        let first: MacIRValue
        let second: MacIRValue
        if mnemonic == "stp" {
            first = Self.value(for: operands[0], state: state)
            second = Self.value(for: operands[1], state: state)
        } else {
            first = state.writeRegister(operands[0])
            second = state.writeRegister(operands[1])
        }
        let updatedBase = state.writeRegister("sp")
        state.recordExplicitStackWriteback("sp")
        state.recordStackDisplacement(delta: writeback.delta)
        return .intrinsic(destination: nil,
                          name: mnemonic == "stp" ? "save_pair_writeback" : "restore_pair_writeback",
                          arguments: [first, second, base, updatedBase, .immediate(writeback.delta), .immediate(writeback.preIndex ? 1 : 0)])
    }

    private static func hasNonStackPairWriteback(operands: [String]) -> Bool {
        guard let base = pairWritebackBase(operands: operands) else { return false }
        return base != "sp"
    }

    static func pairWritebackBase(operands: [String]) -> String? {
        if operands.count == 4,
           let base = plainBracketedPairWritebackBase(operands[2]),
           parseImmediate(operands[3]) != nil {
            return base == "fp" ? "x29" : base
        }
        if operands.count >= 3 {
            guard let base = pairPreIndexWritebackBase(operands[2]) else { return nil }
            return base == "fp" ? "x29" : base
        }
        return nil
    }

    private static func plainBracketedPairWritebackBase(_ operand: String) -> String? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("["),
              normalized.hasSuffix("]") else {
            return nil
        }
        let body = String(normalized.dropFirst().dropLast())
        let parts = splitOperands(body)
        guard parts.count == 1 else { return nil }
        return parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func pairPreIndexWritebackBase(_ operand: String) -> String? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasSuffix("!") else { return nil }
        normalized.removeLast()
        guard normalized.hasPrefix("["),
              normalized.hasSuffix("]") else {
            return nil
        }
        let body = String(normalized.dropFirst().dropLast())
        let parts = splitOperands(body)
        guard parts.count == 2,
              parseImmediate(parts[1]) != nil else {
            return nil
        }
        return parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func mergedParameter(
        _ existing: MacIRFunctionParameter?,
        with info: ArgumentRegisterInfo
    ) -> MacIRFunctionParameter {
        guard let existing else {
            return MacIRFunctionParameter(
                index: info.index,
                register: info.register,
                type: info.type
            )
        }
        guard info.width > Self.typeWidth(existing.type) else { return existing }
        return MacIRFunctionParameter(
            index: info.index,
            register: info.register,
            type: info.type,
            name: existing.name
        )
    }

    private static func mergedParameter(
        _ existing: MacIRFunctionParameter?,
        with callParameter: MacIRCallParameter
    ) -> MacIRFunctionParameter {
        let candidate = MacIRFunctionParameter(
            index: callParameter.index,
            register: callParameter.register,
            type: callParameter.type
        )
        guard let existing else { return candidate }

        let existingWidth = Self.typeWidth(existing.type)
        let candidateWidth = Self.typeWidth(candidate.type)
        if candidateWidth > existingWidth || Self.isGenericIntegerType(existing.type) {
            return MacIRFunctionParameter(
                index: existing.index,
                register: candidate.register,
                type: candidate.type,
                name: existing.name
            )
        }
        return existing
    }

    private static func typeWidth(_ type: String) -> Int {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "int64_t", "uint64_t", "size_t", "void *", "const void *", "char *", "const char *", "id", "SEL", "double":
            return 64
        case "int32_t", "uint32_t", "int", "BOOL", "float":
            return 32
        case "uint16_t":
            return 16
        case "uint8_t", "char":
            return 8
        default:
            return 0
        }
    }

    private static func isGenericIntegerType(_ type: String) -> Bool {
        type == "int64_t" || type == "int32_t"
    }

    static func typeHint(for value: MacIRValue, byteWidth: Int?) -> String {
        switch value {
        case .argument:
            return typeHint(byteWidth: byteWidth)
        case let .register(name, _):
            return typeHint(forRegister: name, byteWidth: byteWidth)
        default:
            return typeHint(byteWidth: byteWidth)
        }
    }

    static func typeHint(forRegister register: String, byteWidth: Int?) -> String {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("w") || normalized.hasPrefix("s") {
            return "int32_t"
        }
        if normalized.hasPrefix("q") || normalized.hasPrefix("v") {
            return "__int128_t"
        }
        return typeHint(byteWidth: byteWidth ?? Self.byteWidth(forRegister: normalized))
    }

    static func typeHint(byteWidth: Int?) -> String {
        switch byteWidth {
        case 1:
            return "uint8_t"
        case 2:
            return "uint16_t"
        case 4:
            return "int32_t"
        case 16:
            return "__int128_t"
        default:
            return "int64_t"
        }
    }

    static func byteWidth(for value: MacIRValue) -> Int? {
        switch value {
        case .argument:
            return nil
        case let .register(name, _):
            return byteWidth(forRegister: name)
        default:
            return nil
        }
    }

    static func byteWidth(forType type: String) -> Int? {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "uint8_t", "char":
            return 1
        case "uint16_t":
            return 2
        case "int32_t", "uint32_t", "int", "BOOL":
            return 4
        case "int64_t", "uint64_t", "size_t", "void *", "const void *", "char *", "const char *", "id", "SEL":
            return 8
        case "__int128_t":
            return 16
        default:
            return nil
        }
    }

    static func byteWidth(forRegister register: String) -> Int? {
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized.first {
        case "w", "s":
            return 4
        case "x", "d":
            return 8
        case "q", "v":
            return 16
        default:
            return nil
        }
    }

    static func value(for operand: String, state: BuilderState) -> MacIRValue {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()
        if lowercased == "xzr" || lowercased == "wzr" {
            return .immediate(0)
        }
        if let immediate = parseImmediate(normalized) {
            return .immediate(immediate)
        }
        if normalized.hasPrefix("_") {
            return .symbol(normalized)
        }
        if isRegister(lowercased) {
            return state.readRegister(lowercased)
        }
        // Full vector arrangements share the Q value, but lane syntax and
        // general register admission retain their existing contracts.
        if lowercased.hasPrefix("v"), lowercased.contains("."), !lowercased.contains("["),
           let view = ssaRegisterView(for: lowercased), view.bitWidth == 128,
           let value = state.ssaValue(for: lowercased) {
            return value
        }
        if lowercased.hasPrefix("0x"), let value = Int64(lowercased.dropFirst(2), radix: 16) {
            return .immediate(value)
        }
        return .unknown(normalized)
    }

    /// Returns an exact byte offset from the function's entry SP only for the
    /// scalar, non-writeback load shapes that can independently prove an
    /// authoritative stack-parameter body binding. Generic stack-slot lowering
    /// intentionally remains broader than this parser.
    private static func exactEntryStackLoadOffset(
        memoryOperand: String,
        mnemonic: String,
        destinationRegister: String
    ) -> Int? {
        let destination = destinationRegister
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isInteger = integerRegisterView(destination) != nil
        let isWRegister = integerRegisterView(destination)?.width == 32
        let isXRegister = integerRegisterView(destination)?.width == 64
        let isScalarFP: Bool = {
            guard let prefix = destination.first,
                  prefix == "s" || prefix == "d",
                  let index = Int(destination.dropFirst()),
                  (0...31).contains(index) else {
                return false
            }
            return true
        }()

        switch mnemonic {
        case "ldr", "ldur":
            guard isInteger || isScalarFP else { return nil }
        case "ldrb", "ldrh", "ldurb", "ldurh":
            guard isWRegister else { return nil }
        case "ldrsb", "ldrsh", "ldursb", "ldursh":
            guard isWRegister || isXRegister else { return nil }
        case "ldrsw", "ldursw":
            guard isXRegister else { return nil }
        default:
            return nil
        }

        let normalized = memoryOperand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.hasSuffix("!"),
              normalized.hasPrefix("["),
              normalized.hasSuffix("]") else {
            return nil
        }
        let parts = splitOperands(String(normalized.dropFirst().dropLast()))
        guard parts.count == 1 || parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "sp" else {
            return nil
        }
        let offset = parts.count == 2 ? parseImmediate(parts[1]) : 0
        guard let offset, offset >= 0 else { return nil }
        return Int(exactly: offset)
    }

    private static func memoryValue(for operand: String, state: BuilderState) -> MacIRValue {
        if let typed = state.currentTypedMemory, let value = structuredMemoryValue(typed, state: state) {
            return value
        }
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("!") {
            normalized.removeLast()
        }

        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else {
            return value(for: normalized, state: state)
        }

        let body = String(normalized.dropFirst().dropLast())
        let parts = splitOperands(body)
        guard let base = parts.first?.lowercased() else { return .unknown(normalized) }

        // Only `[sp]` / `[sp, #imm]` (and the same off a known frame base) name one stack slot.
        // A register index (`[sp, x2]`, `[sp, w2, sxtw #2]`) is a computed address: it falls
        // through to the register-offset lowering below instead of collapsing to slot 0, which
        // dropped the index (A64 oracle: 63 fixtures hit SP+0).
        let immediateOffset: Int64? = parts.count == 1 ? 0 : (parts.count == 2 ? parseImmediate(parts[1]) : nil)
        if base == "sp", !state.hasExplicitStackWriteback, let offset = immediateOffset {
            return .stackSlot(offset: state.stackBaseOffset(for: base) + offset)
        }
        if (base == "fp" || base == "x29"),
           let frameBase = state.knownStackBaseOffset(for: base),
           let offset = immediateOffset {
            return .stackSlot(offset: frameBase + offset)
        }

        if parts.count == 1, isRegister(base) {
            return state.readRegister(base)
        }

        // `[base, #offset]` → a structured `base + offset` address so the printer renders a
        // readable `*(base + 0x60)` dereference (and a later type-aware pass can fold it to
        // `base->field`) instead of the raw machine bracket form. Only the plain
        // immediate-offset shape is lowered here; indexed/extended forms stay opaque.
        if parts.count == 2, isRegister(base), let offset = parseImmediate(parts[1]) {
            let baseValue = state.readRegister(base)
            return offset == 0
                ? baseValue
                : .binaryExpression(op: "+", left: baseValue, right: .immediate(offset))
        }

        // `[base, index]` and `[base, index, lsl/sxtw/uxtw #shift]` — register-offset and
        // scaled/extended-register-offset addressing (the array[i] idiom) → `base + index`
        // / `base + (index << shift)` (shift 0 → `base + index`). The extension keyword is
        // elided; the arithmetic shape is what makes an array access legible. Only lowered
        // when both base and index are registers.
        if parts.count == 2, isRegister(base), isRegister(parts[1]) {
            return .binaryExpression(
                op: "+",
                left: state.readRegister(base),
                right: state.readRegister(parts[1])
            )
        }
        if parts.count == 3, isRegister(base), isRegister(parts[1]) {
            // DP01 #633: a W index with uxtw/sxtw is extended to 64 bits before
            // the shift; dropping the extension changes the address.
            let rawIndex = state.readRegister(parts[1])
            let keyword = parts[2].split(separator: " ").first.map { $0.lowercased() } ?? ""
            let indexValue: MacIRValue = switch keyword {
            case "uxtw": .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: rawIndex))
            case "sxtw": .unary(op: "(int64_t)", value: .unary(op: "(int32_t)", value: rawIndex))
            default: rawIndex
            }
            let shift = parts[2].split(separator: " ").last.map(String.init).flatMap(parseImmediate) ?? 0
            let scaledIndex = shift == 0
                ? indexValue
                : .binaryExpression(op: "<<", left: indexValue, right: .immediate(shift))
            return .binaryExpression(op: "+", left: state.readRegister(base), right: scaledIndex)
        }

        return .unknown(normalized)
    }

    /// True only when a stack-relative memory operand names one exact byte
    /// offset. Register-indexed and writeback forms must not participate in the
    /// stack-value cache because their post-instruction coordinate or alias set
    /// is not represented by a single stable key.
    private static func hasExactStackMemoryAddress(_ operand: String) -> Bool {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.hasSuffix("!"),
              normalized.hasPrefix("["),
              normalized.hasSuffix("]") else {
            return false
        }

        let parts = splitOperands(String(normalized.dropFirst().dropLast()))
        guard let base = parts.first,
              base == "sp" || base == "fp" || base == "x29" else {
            return false
        }
        if parts.count == 1 {
            return true
        }
        return parts.count == 2 && parseImmediate(parts[1]) != nil
    }

    /// Parses a simple `[base]` / `[base, #off]` memory operand for selref slot
    /// reconstruction. Returns the lowercased base register and the (defaulted
    /// zero) byte offset, but ONLY when the base is a canonical 64-bit x0...x30
    /// register. Symbolic aliases (`fp`/`lr`) and the stack pointer are rejected.
    /// Indexed/extended forms (`[base, w0, lsl #2]`) and pre/post-index (`!`) are
    /// rejected so the conservative slot computation never misfires.
    private static func selrefMemoryComponents(_ operand: String) -> (base: String, offset: Int64)? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        // A writeback (`!`) form is not a plain selref slot load.
        guard !normalized.hasSuffix("!"),
              normalized.hasPrefix("["), normalized.hasSuffix("]") else {
            return nil
        }
        let body = String(normalized.dropFirst().dropLast())
        let parts = splitOperands(body)
        guard let first = parts.first,
              let base = canonical64BitSelectorRegister(first) else {
            return nil
        }

        switch parts.count {
        case 1:
            return (base, 0)
        case 2:
            // Second component must be a plain immediate; an index register
            // (`w0, lsl #2`) yields more parts and is rejected above.
            guard let offset = parseImmediate(parts[1]) else { return nil }
            return (base, offset)
        default:
            return nil
        }
    }

    /// ★ Insight
    /// A register-shaped token is not ABI proof: the generic parser intentionally
    /// accepts scalar-FP, vector, and loosely ranged spellings for ordinary IR.
    /// Selector provenance is narrower and may use only an exact 64-bit x0...x30
    /// carrier, so malformed disassembly can never mint a trusted selector name.
    private static func canonical64BitSelectorRegister(_ operand: String) -> String? {
        guard let view = integerRegisterView(operand), view.width == 64 else {
            return nil
        }
        return "x\(view.index)"
    }

    static func memoryOperand(from operands: [String]) -> String {
        guard operands.count > 3 else { return operands[2] }
        return operands.dropFirst(2).joined(separator: ", ")
    }

    /// Register data only. Do not use for offsets, shifts, lanes, or bounds.
    /// Hexadecimal input denotes up to 64 bits; a leading minus negates that
    /// magnitude modulo 2^64, then a W destination retains its low 32 bits.
    static func parseRegisterImmediate(_ operand: String, bitWidth: Int) -> Int64? {
        guard bitWidth == 32 || bitWidth == 64 else { return nil }
        var text = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        let negative = text.hasPrefix("-")
        if negative { text.removeFirst() }
        guard text.hasPrefix("0x") else { return parseImmediate(operand) }
        let digits = text.dropFirst(2)
        guard !digits.isEmpty,
              digits.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }),
              let magnitude = UInt64(digits, radix: 16) else { return nil }
        let bits = negative ? UInt64(0) &- magnitude : magnitude
        let narrowed = bitWidth == 32 ? bits & 0xffff_ffff : bits
        return Int64(bitPattern: narrowed)
    }

    static func parseImmediate(_ operand: String) -> Int64? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") {
            normalized.removeFirst()
        }

        let sign: Int64
        if normalized.hasPrefix("-") {
            sign = -1
            normalized.removeFirst()
        } else {
            sign = 1
        }

        if normalized.hasPrefix("0x") {
            return Int64(normalized.dropFirst(2), radix: 16).map { sign * $0 }
        }
        return Int64(normalized).map { sign * $0 }
    }

    private static func conditionalSelectFalseValue(
        mnemonic: String,
        operand: String,
        state: BuilderState
    ) -> MacIRValue {
        let value = value(for: operand, state: state)
        switch mnemonic {
        case "csinc":
            return .binaryExpression(op: "+", left: value, right: .immediate(1))
        case "csinv":
            return .unary(op: "~", value: value)
        case "csneg":
            return .unary(op: "-", value: value)
        default:
            return value
        }
    }

    private func conditionalSelectOperation(
        mnemonic: String,
        operands: [String],
        sourceAddress: UInt64,
        pendingConditionalCompare: PendingConditionalCompare?,
        state: inout BuilderState
    ) -> MacIROperation? {
        if operands.count == 4,
           let pendingConditionalCompare,
           let compound = Self.compoundCondition(
            for: pendingConditionalCompare,
            branchSuffix: operands[3],
            branchAddress: sourceAddress,
            argumentBitWidths: state.argumentBitWidths,
            carriedAcrossFlagNeutralRows: ssaEnabled,
            projectSigned: ssaEnabled
           ) {
            recordCompoundChain(pendingConditionalCompare, state: &state)
            let trueValue = Self.value(for: operands[1], state: state)
            let falseValue = Self.conditionalSelectFalseValue(
                mnemonic: mnemonic,
                operand: operands[2],
                state: state
            )
            let destination = state.writeRegister(operands[0])
            return .select(
                destination: destination,
                condition: "!=",
                left: compound,
                right: .immediate(0),
                trueValue: trueValue,
                falseValue: falseValue
            )
        }

        if operands.count == 4,
           let flag = flagsPhiCondition(suffix: operands[3], state: &state) {
            let trueValue = Self.value(for: operands[1], state: state)
            let falseValue = Self.conditionalSelectFalseValue(
                mnemonic: mnemonic,
                operand: operands[2],
                state: state
            )
            let destination = state.writeRegister(operands[0])
            return .select(
                destination: destination,
                condition: "!=",
                left: flag,
                right: .immediate(0),
                trueValue: trueValue,
                falseValue: falseValue
            )
        }
        guard operands.count == 4,
              !state.sawConditionalCompareSinceComparison,
              let comparison = state.lastComparison,
              Self.canResolveComparisonSuffix(operands[3], for: comparison),
              let condition = Self.branchCondition(for: operands[3]) else {
            return nil
        }
        let trueValue = Self.value(for: operands[1], state: state)
        let falseValue = Self.conditionalSelectFalseValue(
            mnemonic: mnemonic,
            operand: operands[2],
            state: state
        )
        let destination = state.writeRegister(operands[0])
        let projected = nativeSignedWordCMPPredicate(
            comparison: comparison, suffix: operands[3], consumerAddress: sourceAddress,
            argumentBitWidths: state.argumentBitWidths)
        return .select(
            destination: destination,
            condition: condition,
            left: projected?.left ?? comparison.left,
            right: projected?.right ?? comparison.right,
            trueValue: trueValue,
            falseValue: falseValue
        )
    }

    private func mintNativeLogicalConditionalCertificate(
        source: MacIRSourceSpan, operation: MacIROperation, state: inout BuilderState
    ) {
        guard !ssaEnabled, nativeSignedWordCMPEnabled else { return }
        if Self.isExactNativeWordLogical(source),
           let word = Self.nativeLogicalConditionalWord(source),
           var comparison = state.lastAdjacentComparison,
           comparison.sourceAddress == source.address, comparison.flagsKind == .logicalResult {
            let width = word & 0x8000_0000 == 0 ? 32 : 64
            let isImmediate = word & 0x7f80_0000 == 0x7200_0000
            // Already-correct X low-mask forms stay on their original route.
            if width == 64, isImmediate,
               let mask = Self.nativeLogicalWordMask(word), mask <= UInt64(Int64.max) { return }
            let result: MacIRValue
            let replacement: MacIROperation?
            let writesRegister: Bool
            if case let .assign(destination, originalBits) = operation {
                writesRegister = true
                if width == 32, source.mnemonic == "ands" {
                    // Accepted338 W ANDS behavior is not changed by this extension.
                    result = destination
                    replacement = nil
                } else {
                    guard Self.nativeLogicalUnsignedLoadInputs(source, width: width,
                              sources: state.returnProducerSources),
                          state.registerNameBindingsByValue[destination]?.type == "int\(width)_t",
                          state.valueTypeHints[destination] == nil,
                          let normalized = Self.nativeLogicalAssignmentBits(originalBits,
                              complement: source.mnemonic == "bics", width: width) else { return }
                    result = Self.unsignedCast(destination, width: width)
                    replacement = .assign(destination: destination,
                        source: Self.signedProjection(normalized, width: width, partner: .immediate(0)))
                }
            } else {
                writesRegister = false
                guard word & 31 == 31,
                      case .intrinsic(nil, "compare", _) = operation,
                      let normalized = Self.certifiedNativeTSTResult(source, state: state) else { return }
                result = normalized
                replacement = nil
            }
            comparison.nativeSignedWordLogical = .init(source: source, result: result,
                originalOperation: operation, width: width, writesRegister: writesRegister,
                replacementProducer: replacement)
            state.recordPlainComparison(comparison)
        } else if Self.isExactNativeWordConditional(source),
                  var pending = state.pendingConditionalCompare,
                  pending.sourceAddress == source.address {
            // A provisional local copy is not published until both source certificates hold.
            pending.nativeSignedWordConditionalSource = source
            guard Self.nativeLogicalFirstComparison(pending, sources: state.returnProducerSources) != nil else { return }
            state.pendingConditionalCompare = pending
        }
    }

    private static func nativeLogicalAssignmentBits(
        _ expression: MacIRValue, complement: Bool, width: Int
    ) -> MacIRValue? {
        guard case let .binaryExpression("&", left, right) = expression else { return nil }
        let rhs: MacIRValue
        if complement {
            guard case let .unary("~", operand) = right else { return nil }
            rhs = .unary(op: "~", value: unsignedCast(operand, width: width))
        } else { rhs = unsignedCast(right, width: width) }
        let result = unsignedCast(.binaryExpression(op: "&",
            left: unsignedCast(left, width: width), right: rhs), width: width)
        return isPureValue(result) ? result : nil
    }

    // Ruling5 admits a producer replacement only for a demonstrated unsigned
    // assignment hazard, not for an already-signed ordinary input. This narrow
    // provenance window has only exact zero-offset scalar unsigned loads.
    private static func nativeLogicalUnsignedLoadInputs(
        _ source: MacIRSourceSpan, width: Int, sources: [MacIRSourceSpan]
    ) -> Bool {
        guard let word = nativeLogicalConditionalWord(source),
              word & 0x7f20_0000 == (source.mnemonic == "bics" ? 0x6a20_0000 : 0x6a00_0000),
              (word >> 10) & 63 == 0,
              let index = sources.firstIndex(of: source), index >= 3,
              sources.filter({ $0.address == source.address }).count == 1 else { return false }
        let needed = Set([(word >> 5) & 31, (word >> 16) & 31])
        guard !needed.contains(31) else { return false }
        var loaded: Set<UInt32> = []
        for i in (index - 3)..<index {
            let row = sources[i]
            guard row.address <= UInt64.max - 4, row.address + 4 == sources[i + 1].address,
                  row.mnemonic == "ldr", let encoding = nativeLogicalConditionalWord(row),
                  encoding & 0xffc0_0000 == (width == 32 ? 0xb940_0000 : 0xf940_0000),
                  (encoding >> 10) & 0xfff == 0 else { return false }
            let destination = encoding & 31, base = (encoding >> 5) & 31
            guard destination != 31, base != 31,
                  splitOperands(row.operands) == [
                    nativeLogicalWordRegister(destination, width: width),
                    "[\(nativeLogicalWordRegister(base, width: 64))]"] else { return false }
            loaded.insert(destination)
        }
        guard needed.isSubset(of: loaded),
              Set(sources.map(\.address)).count == sources.count else { return false }
        let start = sources[index - 3].address
        // The separate continuation gate rejects unknown/indirect transfers.
        // Here reject every exact direct edge that bypasses any load in this window.
        for row in sources {
            guard let encoding = nativeLogicalConditionalWord(row) else { return false }
            let bits: Int, shift: Int
            if encoding & 0xfc00_0000 == 0x1400_0000 { bits = 26; shift = 0 }
            else if encoding & 0xff00_0010 == 0x5400_0000
                || encoding & 0x7e00_0000 == 0x3400_0000 { bits = 19; shift = 5 }
            else if encoding & 0x7e00_0000 == 0x3600_0000 { bits = 14; shift = 5 }
            else { continue }
            let raw = Int64((encoding >> UInt32(shift)) & ((UInt32(1) << UInt32(bits)) - 1))
            let sign = Int64(1) << Int64(bits - 1), delta = ((raw ^ sign) - sign) * 4
            let target: UInt64
            if delta < 0 {
                guard row.address >= UInt64(-delta) else { return false }
                target = row.address - UInt64(-delta)
            } else {
                guard row.address <= UInt64.max - UInt64(delta) else { return false }
                target = row.address + UInt64(delta)
            }
            if target > start && target <= source.address { return false }
        }
        return true
    }

    private static func nativeLogicalConditionalWord(_ source: MacIRSourceSpan) -> UInt32? {
        let tokens = source.byteText.split(separator: " ")
        guard tokens.count == 4 else { return nil }
        var word: UInt32 = 0
        for (index, token) in tokens.enumerated() {
            guard token.utf8.count == 2, token.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }), let byte = UInt8(token, radix: 16) else { return nil }
            word |= UInt32(byte) << UInt32(index * 8)
        }
        return word
    }

    private static func nativeLogicalWordRegister(_ index: UInt32, width: Int = 32) -> String {
        index == 31 ? (width == 32 ? "wzr" : "xzr") : "\(width == 32 ? "w" : "x")\(index)"
    }

    private static func isExactNativeWordLogical(_ source: MacIRSourceSpan) -> Bool {
        guard ["tst", "ands", "bics"].contains(source.mnemonic),
              let word = nativeLogicalConditionalWord(source) else { return false }
        let width = word & 0x8000_0000 == 0 ? 32 : 64
        let operands = splitOperands(source.operands)
        let rd = word & 31, rn = (word >> 5) & 31
        let alias = source.mnemonic == "tst"
        if source.mnemonic != "bics" { guard alias == (rd == 31) else { return false } }
        let prefix = alias ? [nativeLogicalWordRegister(rn, width: width)]
            : [nativeLogicalWordRegister(rd, width: width), nativeLogicalWordRegister(rn, width: width)]
        guard operands.starts(with: prefix) else { return false }
        if word & 0x7f80_0000 == 0x7200_0000 {
            guard source.mnemonic != "bics", operands.count == prefix.count + 1,
                  let mask = nativeLogicalWordMask(word),
                  operands[prefix.count].hasPrefix("#"),
                  let immediate = logicalTestImmediate(operands[prefix.count], width: width) else { return false }
            return immediate == mask
        }
        let expected: UInt32 = source.mnemonic == "bics" ? 0x6a20_0000 : 0x6a00_0000
        guard word & 0x7f20_0000 == expected,
              width == 64 || word & 0x0000_8000 == 0 else { return false }
        let rm = (word >> 16) & 31
        let shift = Int((word >> 22) & 3), amount = Int((word >> 10) & 63)
        let withRegister = prefix + [nativeLogicalWordRegister(rm, width: width)]
        if amount == 0 { return operands == withRegister }
        let shifts = ["lsl", "lsr", "asr", "ror"]
        guard operands.count == withRegister.count + 1,
              operands.starts(with: withRegister) else { return false }
        let modifier = operands[withRegister.count].split(separator: " ")
        return modifier.count == 2 && modifier[0] == shifts[shift]
            && parseImmediate(String(modifier[1])) == Int64(amount)
    }

    // Exact logical-immediate DecodeBitMasks. The 64-bit element never shifts by64.
    private static func nativeLogicalWordMask(_ word: UInt32) -> UInt64? {
        let width = word & 0x8000_0000 == 0 ? 32 : 64
        let n = Int((word >> 22) & 1)
        guard width == 64 || n == 0 else { return nil }
        let imms = Int((word >> 10) & 63), immr = Int((word >> 16) & 63)
        let control = (n << 6) | ((~imms) & 63)
        var length = -1
        for bit in stride(from: 6, through: 0, by: -1) where control & (1 << bit) != 0 {
            length = bit; break
        }
        guard length >= 1 else { return nil }
        let size = 1 << length
        guard size <= width else { return nil }
        let levels = size - 1, s = imms & (size - 1), r = immr & (size - 1)
        guard s != levels else { return nil }
        let mask = size == 64 ? UInt64.max : (UInt64(1) << UInt64(size)) - 1
        let ones = (UInt64(1) << UInt64(s + 1)) - 1
        let element = r == 0 ? ones : ((ones >> UInt64(r)) | (ones << UInt64(size - r))) & mask
        var result: UInt64 = 0
        for offset in stride(from: 0, to: width, by: size) { result |= element << UInt64(offset) }
        return result
    }

    private static func isExactNativeWordConditional(_ source: MacIRSourceSpan) -> Bool {
        guard ["ccmp", "ccmn"].contains(source.mnemonic),
              let word = nativeLogicalConditionalWord(source),
              word & 0x3fe0_0410 == 0x3a40_0000 else { return false }
        let width = word & 0x8000_0000 == 0 ? 32 : 64
        let operands = splitOperands(source.operands)
        guard operands.count == 4,
              (source.mnemonic == "ccmp") == (word & 0x4000_0000 != 0),
              operands[0] == nativeLogicalWordRegister((word >> 5) & 31, width: width),
              parseImmediate(operands[2]) == Int64(word & 15) else { return false }
        let second = (word >> 16) & 31
        if word & 0x800 != 0 {
            guard parseImmediate(operands[1]) == Int64(second) else { return false }
        } else {
            guard operands[1] == nativeLogicalWordRegister(second, width: width) else { return false }
        }
        let conditions = ["eq", "ne", "hs", "lo", "mi", "pl", "vs", "vc",
                          "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"]
        let condition = Int((word >> 12) & 15), text = operands[3]
        return text == conditions[condition] || (condition == 2 && text == "cs")
            || (condition == 3 && text == "cc")
    }

    // X authority belongs only to this logical/conditional hook, never the335 certificate.
    private static func nativeLogicalFirstComparison(
        _ pending: PendingConditionalCompare, sources: [MacIRSourceSpan]
    ) -> MacIRSourceSpan? {
        guard let producer = pending.nativeSignedWordConditionalSource,
              let word = nativeLogicalConditionalWord(producer), producer.address >= 4,
              pending.firstComparison.sourceAddress == producer.address - 4,
              pending.firstComparison.flagsKind == .subtraction,
              pending.firstComparison.cmnAddend == nil else { return nil }
        if word & 0x8000_0000 == 0 {
            guard let first = pending.firstComparison.nativeSignedWordCMPSource,
                  first.address == producer.address - 4, isExactNativeWordCMPImmediate(first) else { return nil }
            return first
        }
        let matches = sources.filter { $0.address == producer.address - 4 }
        guard matches.count == 1, let first = matches.first,
              first.mnemonic == "cmp", let firstWord = nativeLogicalConditionalWord(first),
              firstWord & 0xffc0_001f == 0xf100_001f,
              (firstWord >> 5) & 31 != 31 else { return nil }
        let operands = splitOperands(first.operands)
        guard operands.count == 2,
              operands[0] == nativeLogicalWordRegister((firstWord >> 5) & 31, width: 64),
              parseImmediate(operands[1]) == Int64((firstWord >> 10) & 0xfff) else { return nil }
        return first
    }

    // Item338: producer-specific native hook. This does not read arithmetic certificates.
    private func nativeLogicalConditionalOperation(
        for source: MacIRSourceSpan, operands: [String],
        adjacent: BuilderComparison?, pending: PendingConditionalCompare?,
        state: inout BuilderState
    ) -> MacIROperation? {
        guard !ssaEnabled, nativeSignedWordCMPEnabled else { return nil }
        let suffix: String
        if source.mnemonic.hasPrefix("b."), operands.count == 1 {
            suffix = String(source.mnemonic.dropFirst(2))
        } else {
            let count: Int
            switch source.mnemonic {
            case "cset", "csetm": count = 2
            case "cinc", "cinv", "cneg": count = 3
            case "csel", "csinc", "csinv", "csneg": count = 4
            default: return nil
            }
            guard operands.count == count,
                  Self.hasOnlyScalarGPROperands(operands),
                  Self.integerRegisterView(operands[0]) != nil else { return nil }
            suffix = operands[count - 1]
        }
        guard ["ge", "lt", "gt", "le"].contains(suffix),
              let relation = Self.branchCondition(for: suffix) else { return nil }
        let condition: String
        let left: MacIRValue
        let right: MacIRValue
        if let pending, let producer = pending.nativeSignedWordConditionalSource,
           source.address >= 4, producer.address == source.address - 4,
           producer.address == pending.sourceAddress,
           let first = Self.nativeLogicalFirstComparison(pending, sources: state.returnProducerSources),
           producer.address >= 4, first.address == producer.address - 4,
           first.address == pending.firstComparison.sourceAddress,
           let producerWord = Self.nativeLogicalConditionalWord(producer) {
            let width = producerWord & 0x8000_0000 == 0 ? 32 : 64
            if width == 64 {
                // Correct CCMN equality/unsigned-guard cells keep their legacy text.
                if pending.mnemonic == "ccmn", !["ge", "lt", "gt", "le"].contains(pending.guardSuffix) { return nil }
                guard Self.nativeLogicalContinuationRefusal(producer: producer, consumer: source,
                    sources: state.returnProducerSources) == nil else { return nil }
            }
            // Source certificates, not arbitrary IR value shapes, establish exact views.
            // Keep immediate nodes literal so the existing addition gate is unchanged.
            var projected = pending
            projected.firstComparison.left = Self.unsignedCast(pending.firstComparison.left, width: width)
            // CCMN already owns an encoded-width signed projection. Preserve an
            // authoritative same-width argument rather than nesting an unsigned
            // spelling cast inside that existing projection (item345).
            if pending.mnemonic == "ccmn", case let .argument(bindingID) = pending.left,
               state.argumentBitWidths[bindingID] == width {
                projected.left = pending.left
            } else {
                projected.left = Self.unsignedCast(pending.left, width: width)
            }
            if pending.mnemonic == "ccmp", case .immediate = pending.right {
                // Literal is already the exact encoded imm5.
            } else if pending.mnemonic == "ccmp" {
                projected.right = Self.unsignedCast(pending.right, width: width)
            }
            guard let compound = Self.compoundCondition(
                for: projected, branchSuffix: suffix, branchAddress: source.address,
                argumentBitWidths: state.argumentBitWidths, projectSigned: true
            ) else { return nil }
            condition = "!="
            left = compound
            right = .immediate(0)
        } else if !state.sawConditionalCompareSinceComparison,
                  let adjacent, let logical = adjacent.nativeSignedWordLogical,
                  adjacent.flagsKind == .logicalResult,
                  logical.source.address == adjacent.sourceAddress,
                  source.address >= 4, logical.source.address == source.address - 4 {
            condition = relation
            left = Self.signedProjection(logical.result, width: logical.width, partner: .immediate(0))
            right = .immediate(0)
        } else { return nil }

        if source.mnemonic.hasPrefix("b.") {
            return .conditionalBranch(condition: condition, left: left, right: right,
                target: Self.value(for: operands[0], state: state))
        }
        if source.mnemonic == "cset" {
            let destination = state.writeRegister(operands[0])
            state.recordValueType("BOOL", for: destination)
            return .compareToBool(destination: destination,
                condition: condition, left: left, right: right)
        }
        let yes: MacIRValue
        let no: MacIRValue
        switch source.mnemonic {
        case "csetm":
            yes = .unary(op: "~", value: .immediate(0))
            no = .immediate(0)
        case "cinc", "cinv", "cneg":
            let canonical = source.mnemonic == "cinc" ? "csinc"
                : source.mnemonic == "cinv" ? "csinv" : "csneg"
            yes = Self.conditionalSelectFalseValue(mnemonic: canonical, operand: operands[1], state: state)
            no = Self.value(for: operands[1], state: state)
        default:
            yes = Self.value(for: operands[1], state: state)
            no = Self.conditionalSelectFalseValue(mnemonic: source.mnemonic, operand: operands[2], state: state)
        }
        return .select(destination: state.writeRegister(operands[0]), condition: condition,
            left: left, right: right, trueValue: yes, falseValue: no)
    }

    // Both legacy operations survive until the unchanged exact pair commit succeeds.
    private func stagedNativeTSTOperation(
        for source: MacIRSourceSpan, operands: [String], comparison: BuilderComparison,
        state: inout BuilderState
    ) -> MacIROperation? {
        guard let logical = comparison.nativeSignedWordLogical,
              !logical.writesRegister || logical.replacementProducer != nil else { return nil }
        let oldProof = logical.source.mnemonic == "tst" && logical.width == 32
            && Self.nativeTSTHasImmediateFlagKill(producer: logical.source, consumer: source,
                sources: state.returnProducerSources)
        // W TST expansion is limited to the eight branch cells and a direct
        // RET-only continuation. Do not admit old NOP-before-writer controls.
        let nextRows = state.returnProducerSources.filter { source.address <= UInt64.max - 4
            && $0.address == source.address + 4 }
        let immediateReturn = nextRows.count == 1 && nextRows[0].mnemonic == "ret"
            && Self.nativeLogicalConditionalWord(nextRows[0]) == 0xd65f_03c0
        let extendedShape = logical.width == 64 || logical.source.mnemonic == "bics"
            || source.mnemonic.hasPrefix("b.") || immediateReturn
        guard oldProof || (extendedShape && Self.nativeLogicalContinuationRefusal(producer: logical.source,
            consumer: source, sources: state.returnProducerSources) == nil) else { return nil }
        var candidate = state
        guard let repaired = nativeLogicalConditionalOperation(for: source, operands: operands,
            adjacent: comparison, pending: nil, state: &candidate) else { return nil }
        var legacy = state
        let original: MacIROperation?
        if source.mnemonic.hasPrefix("b.") {
            original = operationConditionalBranchCase(for: source, operands: operands,
                state: &legacy, pendingConditionalCompare: nil)
        } else if source.mnemonic == "cset" {
            original = operationConditionalSetCase(for: source, operands: operands,
                state: &legacy, pendingConditionalCompare: nil)
        } else {
            original = operationConditionalSelectCase(for: source, operands: operands,
                state: &legacy, pendingConditionalCompare: nil)
        }
        guard let original else { return nil }
        state = legacy
        let replacement = logical.replacementProducer ?? .intrinsic(destination: nil, name: "compare", arguments: [
            Self.signedProjection(logical.result, width: logical.width, partner: .immediate(0)), .immediate(0)])
        state.pendingNativeLogicalPair = .init(
            producerSource: logical.source, originalProducer: logical.originalOperation,
            replacementProducer: replacement,
            consumerSource: source, originalConsumer: original, replacementConsumer: repaired)
        return original
    }

    // Deliberately bounded: only an immediate exact fresh CMP kills the old flags.
    // No branch/join/unknown authority, and no traversal across the end of a block.
    private static func nativeTSTHasImmediateFlagKill(
        producer: MacIRSourceSpan, consumer: MacIRSourceSpan, sources: [MacIRSourceSpan]
    ) -> Bool {
        guard !consumer.mnemonic.hasPrefix("b."),
              Set(sources.map(\.address)).count == sources.count,
              sources.filter({ $0.address == producer.address }).count == 1,
              sources.filter({ $0.address == consumer.address }).count == 1,
              let p = sources.firstIndex(of: producer), let c = sources.firstIndex(of: consumer),
              p + 1 == c, sources.indices.contains(c + 1),
              consumer.address <= UInt64.max - 4,
              sources[c + 1].address == consumer.address + 4,
              isExactNativeWordCMPImmediate(sources[c + 1]) else { return false }
        // With no control transfer in this source inventory there can be no
        // intra-function branch target/join into the certified straight-line pair.
        // Any such transfer is outside this deliberately narrow proof.
        for (index, row) in sources.enumerated() {
            let name = row.mnemonic
            if name.hasPrefix("b.") || name.hasPrefix("bc.") || ["b", "bl", "blr", "br", "cbz", "cbnz", "tbz", "tbnz",
                "braa", "brab", "blraa", "blrab", "braaz", "brabz", "blraaz", "blrabz",
                "unknown", ".word"].contains(name) { return false }
            if index <= c + 1 && ["ret", "retaa", "retab", "eret", "drps"].contains(name) { return false }
        }
        return true
    }

    // Module-internal for isolated commit-negative tests; production proposals
    // are created only by stagedNativeTSTOperation after certificate consumption.
    static func committingNativeLogicalPairs(
        _ proposals: [NativeSignedWordLogicalPair], to original: [MacIRInstruction]
    ) -> [MacIRInstruction] {
        var result = original
        for pair in proposals {
            guard proposals.filter({ $0.producerSource.address == pair.producerSource.address
                || $0.consumerSource.address == pair.consumerSource.address }).count == 1 else { continue }
            let producers = original.indices.filter { original[$0].source.address == pair.producerSource.address }
            let consumers = original.indices.filter { original[$0].source.address == pair.consumerSource.address }
            guard producers.count == 1, consumers.count == 1,
                  let p = producers.first, let c = consumers.first, p + 1 == c,
                  original[p].source == pair.producerSource,
                  original[c].source == pair.consumerSource,
                  original[p].operation == pair.originalProducer,
                  original[c].operation == pair.originalConsumer else { continue }
            // There is no write before all pair checks succeed.
            result[p].operation = pair.replacementProducer
            result[c].operation = pair.replacementConsumer
        }
        return result
    }

    private static func certifiedNativeTSTResult(_ source: MacIRSourceSpan, state: BuilderState) -> MacIRValue? {
        guard ["tst", "bics"].contains(source.mnemonic), isExactNativeWordLogical(source),
              let word = nativeLogicalConditionalWord(source), word & 31 == 31 else { return nil }
        let width = word & 0x8000_0000 == 0 ? 32 : 64
        let operands = splitOperands(source.operands)
        let first = source.mnemonic == "tst" ? 0 : 1
        let left = unsignedCast(value(for: operands[first], state: state), width: width)
        var right: MacIRValue
        if word & 0x7f80_0000 == 0x7200_0000 {
            guard let mask = nativeLogicalWordMask(word) else { return nil }
            guard let literal = compoundUnsignedAtom(.immediate(Int64(bitPattern: mask)), width: width) else { return nil }
            right = literal
        } else {
            right = unsignedCast(value(for: operands[first + 1], state: state), width: width)
            let amount = Int((word >> 10) & 63), kind = Int((word >> 22) & 3)
            if amount != 0 {
                // W TST ASR remains item339; other modified forms have no admitted operation.
                guard width == 64, source.mnemonic == "tst", kind == 2 else { return nil }
                let logical = MacIRValue.binaryExpression(op: ">>", left: right, right: .immediate(Int64(amount)))
                let sign = MacIRValue.binaryExpression(op: ">>", left: right, right: .immediate(63))
                let fill = MacIRValue.binaryExpression(op: "<<",
                    left: .binaryExpression(op: "-", left: unsignedCast(.immediate(0), width: 64), right: sign),
                    right: .immediate(Int64(64 - amount)))
                right = .binaryExpression(op: "|", left: logical, right: fill)
            }
        }
        if source.mnemonic == "bics" { right = .unary(op: "~", value: right) }
        let bits = MacIRValue.binaryExpression(op: "&", left: left, right: right)
        let result = width == 32 && source.mnemonic == "tst" ? bits : unsignedCast(bits, width: width)
        return isPureValue(result) ? result : nil
    }

    // This separate source-CFG gate does not weaken the accepted straight-line gate.
    // A nil reason is a proof of closure, not a visited-set or unreachable-edge guess.
    static func nativeLogicalContinuationRefusal(
        producer: MacIRSourceSpan, consumer: MacIRSourceSpan, sources: [MacIRSourceSpan]
    ) -> String? {
        guard sources.count <= 64 else { return "row-cap" }
        guard Set(sources.map(\.address)).count == sources.count else { return "duplicate-address" }
        guard let p = sources.firstIndex(of: producer), let c = sources.firstIndex(of: consumer),
              p + 1 == c, producer.address <= UInt64.max - 4,
              consumer.address == producer.address + 4 else { return "pair-not-adjacent" }
        let byAddress = Dictionary(uniqueKeysWithValues: sources.map { ($0.address, $0) })
        var leaders: Set<UInt64> = [sources.first?.address ?? producer.address]
        // Decode only transfer geometry; never prune either successor using a predicate.
        func target(_ row: MacIRSourceSpan, word: UInt32, bits: Int, shift: Int) -> UInt64? {
            let raw = Int64((word >> UInt32(shift)) & ((UInt32(1) << UInt32(bits)) - 1))
            let sign = Int64(1) << Int64(bits - 1)
            let delta = ((raw ^ sign) - sign) * 4
            let result: UInt64
            if delta < 0 {
                guard row.address >= UInt64(-delta) else { return nil }
                result = row.address - UInt64(-delta)
            } else {
                guard row.address <= UInt64.max - UInt64(delta) else { return nil }
                result = row.address + UInt64(delta)
            }
            let operands = splitOperands(row.operands)
            guard let text = operands.last, let parsed = parseImmediate(text), parsed >= 0,
                  UInt64(parsed) == result else { return nil }
            return result
        }
        func successors(_ row: MacIRSourceSpan) -> [UInt64]? {
            guard let word = nativeLogicalConditionalWord(row) else { return nil }
            if row.mnemonic == "b", word & 0xfc00_0000 == 0x1400_0000,
               let destination = target(row, word: word, bits: 26, shift: 0) { return [destination] }
            let conditional = row.mnemonic.hasPrefix("b.") && word & 0xff00_0010 == 0x5400_0000
            let compare = ["cbz", "cbnz"].contains(row.mnemonic) && word & 0x7e00_0000 == 0x3400_0000
            let test = ["tbz", "tbnz"].contains(row.mnemonic) && word & 0x7e00_0000 == 0x3600_0000
            if conditional || compare || test {
                guard row.address <= UInt64.max - 4,
                      let destination = target(row, word: word, bits: test ? 14 : 19, shift: 5) else { return nil }
                return [row.address + 4, destination]
            }
            return nil
        }
        // No edge may enter between the producer and consumer. Unknown indirect
        // transfers cannot establish absence of such an edge, so decline globally.
        for row in sources {
            let mnemonic = row.mnemonic
            guard let encoded = nativeLogicalConditionalWord(row),
                  !["unknown", ".word", ".inst"].contains(mnemonic) else { return "unknown-or-undecoded" }
            let namedDirect = mnemonic == "b" || mnemonic.hasPrefix("b.")
                || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic)
            let exactReturn = mnemonic == "ret" && encoded == 0xd65f_03c0
                && (row.operands.isEmpty || row.operands == "x30")
            let exactNOP = mnemonic == "nop" && encoded == 0xd503_201f && row.operands.isEmpty
            // Branch/exception/system major class: no unrecognized encoded transfer
            // may hide behind a benign mnemonic outside the forward walk.
            if ["br", "braa", "brab", "braaz", "brabz"].contains(mnemonic) { return "indirect-branch" }
            if ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"].contains(mnemonic) { return "call" }
            if encoded & 0x1c00_0000 == 0x1400_0000,
               !namedDirect && !exactReturn && !exactNOP { return "unrecognized-transfer-or-system" }
            if mnemonic == "b" || mnemonic.hasPrefix("b.")
                || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic) {
                guard let next = successors(row) else { return "unresolved-successor" }
                for address in next {
                    guard byAddress[address] != nil else { return "tail-or-unresolved-successor" }
                    if address == consumer.address && row.address != producer.address { return "producer-bypass" }
                    leaders.insert(address)
                }
            }
        }
        guard leaders.count <= 16 else { return "block-cap" }
        let starts: [UInt64]
        if consumer.mnemonic.hasPrefix("b.") {
            guard let next = successors(consumer) else { return "unresolved-successor" }
            starts = next
        } else {
            guard consumer.address <= UInt64.max - 4 else { return "unresolved-successor" }
            starts = [consumer.address + 4]
        }
        var active: Set<UInt64> = [], closed: Set<UInt64> = []
        func visit(_ address: UInt64) -> String? {
            if closed.contains(address) { return nil }
            guard active.insert(address).inserted else { return "unclosed-cycle" }
            defer { active.remove(address) }
            guard let row = byAddress[address], let word = nativeLogicalConditionalWord(row) else { return "unknown-or-undecoded" }
            let mnemonic = row.mnemonic
            // CCMP/CCMN read incoming NZCV before writing it: reader rejection wins.
            if mnemonic.hasPrefix("b.") || ["cset", "csetm", "csel", "csinc", "csinv", "csneg",
                "cinc", "cinv", "cneg", "adc", "adcs", "sbc", "sbcs", "ngc", "ngcs",
                "ccmp", "ccmn"].contains(mnemonic)
                || (mnemonic == "mrs" && row.operands.lowercased().contains("nzcv")) { return "nzcv-reader" }
            if mnemonic == "ret", word == 0xd65f_03c0,
               row.operands.isEmpty || row.operands == "x30" { closed.insert(address); return nil }
            if nativeLogicalFullFlagWriter(row, word: word) { closed.insert(address); return nil }
            let next: [UInt64]
            if mnemonic == "b" || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic) {
                guard let edges = successors(row) else { return "unresolved-successor" }
                next = edges
            } else if mnemonic == "nop", word == 0xd503_201f, row.operands.isEmpty {
                guard address <= UInt64.max - 4 else { return "unresolved-successor" }
                next = [address + 4]
            } else if ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"].contains(mnemonic) {
                return "call"
            } else if ["br", "braa", "brab", "braaz", "brabz"].contains(mnemonic) {
                return "indirect-branch"
            } else { return "unsupported-neutral-or-unknown" }
            for edge in next { if let reason = visit(edge) { return reason } }
            closed.insert(address)
            return nil
        }
        for start in starts { if let reason = visit(start) { return reason } }
        return nil
    }

    private static func nativeLogicalFullFlagWriter(_ source: MacIRSourceSpan, word: UInt32) -> Bool {
        if ["tst", "ands", "bics"].contains(source.mnemonic) {
            return isExactNativeWordLogical(source)
        }
        guard ["cmp", "cmn", "adds", "subs"].contains(source.mnemonic),
              word & 0x2000_0000 != 0 else { return false }
        let width = word & 0x8000_0000 == 0 ? 32 : 64
        let subtraction = word & 0x4000_0000 != 0
        let rd = word & 31, rn = (word >> 5) & 31
        let alias = source.mnemonic == "cmp" || source.mnemonic == "cmn"
        guard alias == (rd == 31),
              subtraction == (source.mnemonic == "cmp" || source.mnemonic == "subs") else { return false }
        let operands = splitOperands(source.operands)
        func register(_ index: UInt32, width: Int, stack: Bool) -> String {
            if index == 31 && stack { return width == 32 ? "wsp" : "sp" }
            return nativeLogicalWordRegister(index, width: width)
        }
        let immediate = word & 0x1f80_0000 == 0x1100_0000
        let shifted = word & 0x1f20_0000 == 0x0b00_0000
        let extended = word & 0x1fe0_0000 == 0x0b20_0000
        guard immediate || shifted || extended else { return false }
        let prefix = (alias ? [] : [register(rd, width: width, stack: false)])
            + [register(rn, width: width, stack: immediate || extended)]
        guard operands.starts(with: prefix) else { return false }
        let tail = Array(operands.dropFirst(prefix.count))
        if immediate {
            let raw = Int64((word >> 10) & 0xfff), shift = (word >> 22) & 1
            if tail.count == 1 { return parseImmediate(tail[0]) == raw << (shift == 0 ? 0 : 12) }
            return shift == 1 && tail.count == 2 && parseImmediate(tail[0]) == raw
                && tail[1] == "lsl #12"
        }
        let rm = (word >> 16) & 31
        if shifted {
            let kind = Int((word >> 22) & 3), amount = Int((word >> 10) & 63)
            guard kind != 3, width == 64 || amount < 32,
                  tail.first == register(rm, width: width, stack: false) else { return false }
            if amount == 0 { return tail.count == 1 }
            guard tail.count == 2 else { return false }
            let modifier = tail[1].split(separator: " ")
            return modifier.count == 2 && modifier[0] == ["lsl", "lsr", "asr"][kind]
                && parseImmediate(String(modifier[1])) == Int64(amount)
        }
        let option = Int((word >> 13) & 7), amount = Int((word >> 10) & 7)
        guard amount <= 4, width == 64 || (option != 3 && option != 7),
              tail.count == 2,
              tail[0] == register(rm, width: option == 3 || option == 7 ? 64 : 32, stack: false) else { return false }
        let modifier = tail[1].split(separator: " ")
        let names = ["uxtb", "uxth", "uxtw", "uxtx", "sxtb", "sxth", "sxtw", "sxtx"]
        guard modifier.first == Substring(names[option]) else { return false }
        return amount == 0 && modifier.count == 1
            || modifier.count == 2 && parseImmediate(String(modifier[1])) == Int64(amount)
    }

    private static func singleBitIndex(for mask: Int64) -> Int64? {
        guard mask > 0 else { return nil }
        let value = UInt64(mask)
        guard value & (value - 1) == 0 else { return nil }
        return Int64(value.trailingZeroBitCount)
    }

    static func splitOperands(_ text: String) -> [String] {
        var operands: [String] = []
        var current = ""
        var bracketDepth = 0

        for character in text {
            switch character {
            case "[":
                bracketDepth += 1
                current.append(character)
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            case "," where bracketDepth == 0:
                operands.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll(keepingCapacity: true)
            default:
                current.append(character)
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            operands.append(tail)
        }
        return operands
    }

    /// Rendered in place of a switch selector whose identity is not proven: the
    /// case edges come from the supplied table, but no value is claimed to be
    /// the one the table is indexed by.
    static let unprovenSwitchSelectorText = "unproven_switch_selector"

    /// A jump-table dispatch idiom that matched conservatively and whose case
    /// targets were supplied by the caller.
    struct RecoveredSwitch {
        /// The proven selector definition (see `JumpTableSelectorProof`). nil
        /// means the selector is unproven and the switch abstains from naming it.
        var selector: JumpTableSelectorProof?
        /// The ordered case target addresses supplied by the caller.
        var targets: [UInt64]
        /// The default branch target (the bounds-check exit), if recovered.
        var defaultTarget: UInt64?
    }

    /// Conservatively detects the canonical compiler jump-table dispatch idiom
    /// ending in `br <reg>` and associates it with caller-supplied case targets.
    ///
    /// The detection is gated entirely on `jumpTables`: a `br` becomes a switch
    /// only when (a) the caller supplied a non-empty target array keyed by that
    /// `br`'s address AND (b) the `br` carries a single register operand. The
    /// preceding bounds-check (`cmp Ridx, #N` immediately followed by
    /// `b.hi`/`b.cs`/`b.hs` to a default label) is recovered best-effort for the
    /// default target; if a bounds `N` is found it is cross-checked against the
    /// table length (`targets.count <= N + 1`) and a disagreement REJECTS the
    /// switch (conservative: idiom and table disagree). Table data alone gates
    /// emission of the case edges. The selector is named only when
    /// `JumpTableResolver.proveSelector` proves which SSA definition indexes the
    /// table; otherwise the switch abstains from naming one (never the dispatched
    /// target register, and never a later redefinition of the index register).
    fileprivate static func recoverSwitchDispatches<Row: DecompilerInstructionRow>(
        rows: [Row],
        jumpTables: [UInt64: [UInt64]]
    ) -> [UInt64: RecoveredSwitch] {
        var result: [UInt64: RecoveredSwitch] = [:]

        for (dispatchIndex, row) in rows.enumerated() {
            guard row.mnemonic.lowercased() == "br" else { continue }
            let operands = splitOperands(row.operands)
            guard operands.count == 1, isRegister(operands[0].lowercased()) else { continue }
            guard let targets = jumpTables[row.address], !targets.isEmpty else { continue }

            // Best-effort backward scan for the bounds-check pair. We only look
            // back a short straight-line window and stop at any control-flow
            // boundary so we never cross a basic-block edge.
            var defaultTarget: UInt64?
            var boundsLimit: Int64?

            var scanIndex = dispatchIndex - 1
            var steps = 0
            while scanIndex >= 0, steps < 16 {
                let candidate = rows[scanIndex]
                let mnemonic = candidate.mnemonic.lowercased()
                // Stop at any intervening control-flow transfer (excluding the
                // bounds branch we are looking for, handled below).
                if Self.isControlFlowBoundary(mnemonic) {
                    // A b.hi/b.cs/b.hs to a default label paired with the
                    // immediately preceding cmp identifies the bounds check.
                    if mnemonic.hasPrefix("b."),
                       ["hi", "cs", "hs"].contains(String(mnemonic.dropFirst(2))),
                       scanIndex - 1 >= 0,
                       rows[scanIndex - 1].mnemonic.lowercased() == "cmp" {
                        let cmpOperands = splitOperands(rows[scanIndex - 1].operands)
                        if cmpOperands.count == 2,
                           isRegister(cmpOperands[0].lowercased()),
                           let bound = parseImmediate(cmpOperands[1]) {
                            boundsLimit = bound
                            defaultTarget = parseBranchTargetAddress(splitOperands(candidate.operands).first)
                        }
                    }
                    break
                }
                scanIndex -= 1
                steps += 1
            }

            // If a bounds limit was recovered, the table length must agree
            // (N + 1 in-range cases). A disagreement means the supplied table
            // and the detected idiom contradict each other; stay conservative.
            if let boundsLimit, boundsLimit >= 0, targets.count > Int(boundsLimit) + 1 {
                continue
            }

            let selector = JumpTableResolver.proveSelector(rows: rows, dispatchIndex: dispatchIndex)
            // A bounds branch the 16-row scan above could not reach still names the
            // proven default exit.
            if defaultTarget == nil, case let .boundsBranch(provenDefault)? = selector?.guardKind {
                defaultTarget = provenDefault
            }
            result[row.address] = RecoveredSwitch(
                selector: selector,
                targets: targets,
                defaultTarget: defaultTarget
            )
        }

        return result
    }

    /// True for mnemonics that terminate a straight-line run for the purposes of
    /// the conservative jump-table backward scan.
    private static func isControlFlowBoundary(_ mnemonic: String) -> Bool {
        switch mnemonic {
        case "b", "bl", "blr", "br", "ret", "cbz", "cbnz", "tbz", "tbnz",
             "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr", "eret", "eretaa", "eretab",
             "blraa", "blrab", "blraaz", "blrabz",
             "braa", "brab", "braaz", "brabz":
            return true
        default:
            return mnemonic.hasPrefix("b.")
        }
    }

    /// Parses a branch target operand as an absolute address (decimal or hex).
    private static func parseBranchTargetAddress(_ operand: String?) -> UInt64? {
        guard let operand else { return nil }
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("0x") {
            return UInt64(normalized.dropFirst(2), radix: 16)
        }
        return UInt64(normalized)
    }
}

struct ArgumentRegisterInfo {
    var index: Int
    var register: String
    var width: Int
    var type: String
    var isFloat: Bool = false
}

