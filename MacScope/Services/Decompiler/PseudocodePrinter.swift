import Foundation

struct PseudocodeBoundedText: Equatable, Sendable {
    let text: String
    let wasTruncated: Bool
    let emittedLineCount: Int
}

public struct PseudocodePrinter: Sendable {
    /// User-tunable emission preferences (control-flow structuring, dead-code /
    /// NOP elision, the function-size gate). Defaults to the shipped behaviour so
    /// every existing call site is unaffected.
    let options: DecompilerOptions

    /// Names depend only on target addresses and lexical occurrence counts,
    /// never CFG block IDs. Scope and loop namespaces remain distinct.
    struct RecoveryLabelAllocator {
        private var counts: [String: Int] = [:]
        mutating func label(prefix: String, address: UInt64) -> String {
            let base = "\(prefix)_0x\(String(address, radix: 16))"
            let occurrence = counts[base, default: 0] + 1
            counts[base] = occurrence
            return occurrence == 1 ? base : "\(base)_\(occurrence)"
        }
    }
    #if DEBUG
    /// Nil by default; capture belongs to one caller's printer instance.
    var renderCapture: RenderCapture? = nil

    final class RenderCapture: @unchecked Sendable {
        struct PhiGates: Sendable {
            let functionStart: UInt64
            let completeEdges: Bool
            let completePhis: Bool
        }
        struct Output: Sendable {
            let originalFunction: MacIRFunction
            let renderedFunction: MacIRFunction
            let document: PseudocodeDocument
            let options: DecompilerOptions
            let phiGates: [PhiGates]
        }
        private enum State { case idle, recording, completed, invalid }
        private let lock = NSLock()
        private var state = State.idle
        private var original: MacIRFunction?
        private var options: DecompilerOptions = .default
        private var gates: [PhiGates] = []
        private var result: Output?

        // Called only while holding lock. Invalid is permanent: a copied
        // printer must never rebind this capture to a second invocation.
        private func invalidate() {
            state = .invalid
            original = nil; gates = []; result = nil
        }
        fileprivate func begin(original: MacIRFunction, options: DecompilerOptions) {
            lock.lock(); defer { lock.unlock() }
            guard state == .idle else { invalidate(); return }
            state = .recording
            self.original = original; self.options = options
        }
        fileprivate func recordGates(functionStart: UInt64, completeEdges: Bool, completePhis: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard state == .recording, original?.startAddress == functionStart else {
                invalidate(); return
            }
            gates.append(.init(functionStart: functionStart,
                completeEdges: completeEdges, completePhis: completePhis))
        }
        fileprivate func complete(rendered: MacIRFunction, document: PseudocodeDocument) {
            lock.lock(); defer { lock.unlock() }
            guard state == .recording, let original,
                  original.startAddress == rendered.startAddress,
                  original.name == rendered.name,
                  document.entryAddress == rendered.startAddress,
                  document.functionName == rendered.name,
                  document.returnType == rendered.returnType,
                  document.parameters == rendered.parameters else {
                invalidate(); return
            }
            result = .init(originalFunction: original, renderedFunction: rendered,
                document: document, options: options, phiGates: gates)
            state = .completed
        }
        var output: Output? {
            lock.lock(); defer { lock.unlock() }
            guard state == .completed else { return nil }
            return result
        }
    }

    /// Optional, instance-scoped observation used by emitted-text mutation tests.
    var recoveryTextCheckCapture: CP6RecoveryTextCheck.Capture? = nil
    /// Evidence-only raw candidate rendering. Proofs and the text assertion
    /// still run; this switch and every use of it are absent from release.
    var bypassRecoveryReadabilityForTesting = false
    #endif
    private let boundedEmissionState: PseudocodeBoundedEmissionState?
    /// Cooperative cancellation for the checkpointed `print(...checkpoint:)` overload only.
    /// nil on every other path, which keeps their emission (and its cost) unchanged.
    private let emissionCancellation: PseudocodeEmissionCancellation?

    private func lexicalProof(for function: MacIRFunction) -> RegionalLexicalProof? {
        RegionalLexicalProof(reconciled: function)
    }

    private func lexicalNames(for proof: RegionalLexicalProof?, preserving names: PseudocodeNameContext)
        -> PseudocodeNameContext {
        guard let proof else { return names }
        var result = PseudocodeNameContext(function: proof.function, types: Array(names.typesByName.values),
            callTargetRenames: names.callTargetRenames, registerNameOverrides: names.registerNameOverrides)
        result.allowsTSTASRStatementLocals = names.allowsTSTASRStatementLocals
        result.redundantCompareIndices = redundantCompareIndices(function: proof.function, names: result)
        result.resolvedIndirectCalls = names.resolvedIndirectCalls
        result.usesNativeAddressLabels = names.usesNativeAddressLabels
        return result
    }

    /// Emission steps (appended lines, region entries, structured instructions) between two
    /// invocations of the caller's checkpoint. The first checkpoint fires at step N, so short
    /// functions observe no internal checkpoint at all.
    static let cancellationCheckpointInterval = 64

    /// Latches the first error thrown by the caller's checkpoint. Once latched, emission stops:
    /// `appendLine` drops output, `emissionLimitReached` is true and region emission unwinds,
    /// and the checkpointed `print` rethrows the error instead of returning a partial document.
    /// Uncancelled runs only count steps, so their output is byte-identical.
    private final class PseudocodeEmissionCancellation: @unchecked Sendable {
        private let checkpoint: () throws -> Void
        private var steps = 0
        private(set) var error: (any Error)?

        var isCancelled: Bool { error != nil }

        init(checkpoint: @escaping () throws -> Void) {
            self.checkpoint = checkpoint
        }

        func step() {
            guard error == nil else { return }
            steps += 1
            guard steps.isMultiple(of: PseudocodePrinter.cancellationCheckpointInterval) else { return }
            do { try checkpoint() } catch { self.error = error }
        }
    }

    private final class PseudocodeBoundedEmissionState: @unchecked Sendable {
        enum Admission {
            case accepted(String)
            case stopped
        }

        let maximumUTF8Bytes: Int
        private(set) var joinedUTF8ByteCount = 0
        private(set) var emittedLineCount = 0
        private(set) var wasTruncated = false

        var isStopped: Bool { wasTruncated }

        init(maximumUTF8Bytes: Int) {
            precondition(maximumUTF8Bytes > 0)
            self.maximumUTF8Bytes = maximumUTF8Bytes
        }

        func admit(_ source: String, hasLeadingNewline: Bool) -> Admission {
            guard !isStopped else { return .stopped }
            let separatorBytes = hasLeadingNewline ? 1 : 0
            let remaining = maximumUTF8Bytes - joinedUTF8ByteCount
            guard remaining > separatorBytes else {
                wasTruncated = true
                return .stopped
            }
            let availableTextBytes = remaining - separatorBytes
            let bounded = Self.scalarSafePrefix(source, maximumUTF8Bytes: availableTextBytes)
            joinedUTF8ByteCount += separatorBytes + bounded.text.utf8.count
            emittedLineCount += 1
            if bounded.wasTruncated {
                wasTruncated = true
            }
            return .accepted(bounded.text)
        }

        private static func scalarSafePrefix(
            _ source: String,
            maximumUTF8Bytes: Int
        ) -> (text: String, wasTruncated: Bool) {
            guard source.utf8.count > maximumUTF8Bytes else {
                return (source, false)
            }
            var result = ""
            result.reserveCapacity(maximumUTF8Bytes)
            var usedBytes = 0
            for scalar in source.unicodeScalars {
                let scalarText = String(scalar)
                let scalarBytes = scalarText.utf8.count
                guard usedBytes + scalarBytes <= maximumUTF8Bytes else { break }
                result.unicodeScalars.append(scalar)
                usedBytes += scalarBytes
            }
            return (result, true)
        }
    }

    private struct BodyStructureResult {
        var regionTree: PseudocodeRegionNode?
        var structureFallback: PseudocodeStructureFallback?
    }

    private struct RegionEmissionResult {
        var supported: Bool
        var node: PseudocodeRegionNode?
        var emittedBlocks: Set<Int>
        var gotoLeafCount: Int

        var containsGotoLeaf: Bool { gotoLeafCount > 0 }

        static let omitted = RegionEmissionResult(supported: true, node: nil, emittedBlocks: [], gotoLeafCount: 0)
        static let unsupported = RegionEmissionResult(supported: false, node: nil, emittedBlocks: [], gotoLeafCount: 0)
    }

    private struct LoopEmissionContext {
        var exitTarget: Int
        var loopBlocks: Set<Int>
    }

    private struct ContinuationGotoEmissionContext {
        var targetAddresses: Set<UInt64> = []
        var emittedLabelCounts: [UInt64: Int] = [:]
        var invalidStatementBoundaryTargets: Set<UInt64> = []

        var hasTargets: Bool { !targetAddresses.isEmpty }
        var targetCount: Int { targetAddresses.count }

        mutating func recordTargets(
            _ targets: Set<Int>,
            cfg: CFG,
            instructions: [MacIRInstruction]
        ) -> Bool {
            for blockIndex in targets {
                guard blockIndex >= 0,
                      blockIndex < cfg.blocks.count else {
                    return false
                }
                let instructionIndex = cfg.blocks[blockIndex].startIndex
                guard instructionIndex >= 0,
                      instructionIndex < instructions.count else {
                    return false
                }
                targetAddresses.insert(instructions[instructionIndex].source.address)
            }
            return true
        }

        func targetAddress(
            for blockIndex: Int,
            cfg: CFG,
            instructions: [MacIRInstruction]
        ) -> UInt64? {
            guard blockIndex >= 0,
                  blockIndex < cfg.blocks.count else {
                return nil
            }
            let instructionIndex = cfg.blocks[blockIndex].startIndex
            guard instructionIndex >= 0,
                  instructionIndex < instructions.count else {
                return nil
            }
            let address = instructions[instructionIndex].source.address
            return targetAddresses.contains(address) ? address : nil
        }

        mutating func recordEmittedLabel(address: UInt64) {
            emittedLabelCounts[address, default: 0] += 1
        }

        mutating func recordInvalidStatementBoundary(address: UInt64) {
            invalidStatementBoundaryTargets.insert(address)
        }

        var emittedExactlyOnceAtStatementBoundaries: Bool {
            guard invalidStatementBoundaryTargets.isEmpty else { return false }
            for address in targetAddresses {
                guard emittedLabelCounts[address] == 1 else { return false }
            }
            return emittedLabelCounts.keys.allSatisfy { targetAddresses.contains($0) }
        }
    }

    private enum GotoLeafDecision: String, CaseIterable {
        case emitted
        case failedContiguity = "failed-contiguity"
        case failedPartition = "failed-partition"
        case failedTerminalness = "failed-terminalness"
        case conditionUnrecoverable = "condition-unrecoverable"
    }

    private struct GotoLeafEmissionDiagnostics {
        var enabled: Bool
        private(set) var counts: [GotoLeafDecision: Int] = [:]

        mutating func record(_ decision: GotoLeafDecision, count: Int = 1) {
            guard enabled, count > 0 else { return }
            counts[decision, default: 0] += count
        }

        var hasCounts: Bool {
            !counts.isEmpty
        }

        func countsText() -> String {
            GotoLeafDecision.allCases.compactMap { decision -> String? in
                guard let count = counts[decision], count > 0 else { return nil }
                return "\(decision.rawValue):\(count)"
            }
            .joined(separator: ",")
        }
    }

    static let gotoLeafDiagnosticsEnvironmentKey = "MACSCOPE_GOTOLEAF_DIAGNOSTICS"

    private static var gotoLeafDiagnosticsEnabled: Bool {
        let value = ProcessInfo.processInfo.environment[gotoLeafDiagnosticsEnvironmentKey]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    public init() {
        self.options = .default
        self.boundedEmissionState = nil
        self.emissionCancellation = nil
    }

    /// Constructs a printer with explicit decompiler options. `internal` because
    /// `DecompilerOptions` is an internal type; GUI/scripting call sites read the
    /// options from `UserDefaults` and pass them here.
    init(options: DecompilerOptions) {
        self.options = options
        self.boundedEmissionState = nil
        self.emissionCancellation = nil
    }

    private init(
        options: DecompilerOptions,
        boundedEmissionState: PseudocodeBoundedEmissionState?,
        emissionCancellation: PseudocodeEmissionCancellation? = nil
    ) {
        self.options = options
        self.boundedEmissionState = boundedEmissionState
        self.emissionCancellation = emissionCancellation
    }

    /// The same rendering as `print(function:types:nameOverrides:registerNameOverrides:)`,
    /// with cooperative cancellation: `checkpoint` runs every `cancellationCheckpointInterval`
    /// emission steps, and the first error it throws stops emission and is rethrown — no partial
    /// document is returned. Certified TST-ASR statement locals deliberately decline
    /// this stateful path; functions without such a certificate remain byte-identical.
    func print(
        function: MacIRFunction,
        ownDirectCallAddresses: Set<UInt64> = [],
        types: [TypeDefinition] = [],
        nameOverrides: [String: String] = [:],
        registerNameOverrides: [String: String] = [:],
        stackLocalOverrides: [String: StackLocalOverride] = [:],
        resolvedIndirectCalls: [UInt64: PseudocodeIndirectCall] = [:],
        checkpoint: () throws -> Void
    ) throws -> PseudocodeDocument {
        try withoutActuallyEscaping(checkpoint) { checkpoint in
            let cancellation = PseudocodeEmissionCancellation(checkpoint: checkpoint)
            var printer = Self(
                options: options,
                boundedEmissionState: boundedEmissionState,
                emissionCancellation: cancellation
            )
            #if DEBUG
            printer.renderCapture = renderCapture
            #endif
            let document = printer.print(
                function: function,
                ownDirectCallAddresses: ownDirectCallAddresses,
                types: types,
                nameOverrides: nameOverrides,
                registerNameOverrides: registerNameOverrides,
                stackLocalOverrides: stackLocalOverrides,
                resolvedIndirectCalls: resolvedIndirectCalls
            )
            if let error = cancellation.error { throw error }
            return document
        }
    }

    public func print(
        function: MacIRFunction,
        ownDirectCallAddresses: Set<UInt64> = [],
        types: [TypeDefinition] = [],
        nameOverrides: [String: String] = [:],
        registerNameOverrides: [String: String] = [:],
        stackLocalOverrides: [String: StackLocalOverride] = [:],
        resolvedIndirectCalls: [UInt64: PseudocodeIndirectCall] = [:]
    ) -> PseudocodeDocument {
        #if DEBUG
        renderCapture?.begin(original: function, options: options)
        #endif
        let allowsTSTASRStatementLocals = !function.ssaEnabled
        let function = RegionalLexicalProof.projecting(function) {
            Self.applyingStackLocalOverrides(stackLocalOverrides,
                to: MacIRFPEnvironmentPseudocodeProjection.project(Self.projectDirectVoidCallResults($0,
                    ownDirectCallAddresses: ownDirectCallAddresses)))
        }
        let document = printProjected(function: function, types: types, nameOverrides: nameOverrides,
            registerNameOverrides: registerNameOverrides, resolvedIndirectCalls: resolvedIndirectCalls,
            allowsTSTASRStatementLocals: allowsTSTASRStatementLocals)
        #if DEBUG
        renderCapture?.complete(rendered: function, document: document)
        #endif
        return document
    }

    private func printProjected(
        function: MacIRFunction,
        types: [TypeDefinition],
        nameOverrides: [String: String],
        registerNameOverrides: [String: String],
        resolvedIndirectCalls: [UInt64: PseudocodeIndirectCall],
        allowsTSTASRStatementLocals: Bool
    ) -> PseudocodeDocument {
        var lines: [PseudocodeLine] = []
        for definition in MacIRSignedBitfield.helperDefinitions(in: function) {
            for line in definition.components(separatedBy: "\n") {
                appendLine(line, kind: .metadata, to: &lines)
            }
        }
        var nameContext = PseudocodeNameContext(
            function: function,
            types: types,
            callTargetRenames: nameOverrides,
            registerNameOverrides: registerNameOverrides
        )
        nameContext.allowsTSTASRStatementLocals = allowsTSTASRStatementLocals
        nameContext.redundantCompareIndices = redundantCompareIndices(function: function, names: nameContext)
        nameContext.resolvedIndirectCalls = resolvedIndirectCalls
        let callSignaturesByTarget = Dictionary(uniqueKeysWithValues: function.callSignatures.map { ($0.target, $0) })
        let noReturnQualifier = function.isNoReturn ? "noreturn " : ""
        appendLine("\(noReturnQualifier)\(function.returnType) \(function.name)(\(parameterList(for: function))) {", kind: .signature, to: &lines)
        if !emissionLimitReached {
            appendLine(functionMetadataLine(for: function, names: nameContext), kind: .metadata, to: &lines)
        }
        for localVariable in function.localVariables where !emissionLimitReached {
            appendLine(
                "    \(localVariable.type) \(localVariable.name);",
                kind: .declaration,
                to: &lines
            )
        }

        let hasPresentationPhis = !Self.presentationPhis(function).isEmpty
        let bodyStructure: BodyStructureResult
        if emissionLimitReached {
            bodyStructure = .init(regionTree: nil, structureFallback: nil)
        } else if Self.hasFunctionEntryPhi(function)
                    && (!function.ssaEnabled || !MacIRBuilder.hasBoundedEntryLoopProof(function)
                        || !entryPhiNamesAreSafe(function, names: nameContext)) {
            appendLine("    __unavailable_cfg_phi();", kind: .instruction, to: &lines)
            bodyStructure = .init(regionTree: nil, structureFallback: .unstructurableCFG)
        } else if emitVisibleDiamondJoin(function: function, names: nameContext, into: &lines) {
            bodyStructure = .init(regionTree: nil, structureFallback: nil)
        } else if function.ssaEnabled, hasPresentationPhis, options.structureControlFlow,
                  !Self.hasFunctionEntryPhi(function),
                  function.instructions.count <= options.functionSizeGate,
                  let cfg = function.cfg?.compatibilityCFG,
                  let native = emitDecodedScalarFallback(function: function, cfg: cfg, depth: 0,
                      names: nameContext, callSignaturesByTarget: callSignaturesByTarget, into: &lines) {
            // Prove the unchanged architectural rows before any edge-copy projection.
            // Failure leaves both the original SSA function and the output untouched.
            bodyStructure = .init(regionTree: native, structureFallback: nil)
        } else if function.ssaEnabled, hasPresentationPhis, options.structureControlFlow,
                  let structured = emitSSAEdgeProjection(function: function, names: nameContext,
                      callSignaturesByTarget: callSignaturesByTarget, into: &lines) {
            bodyStructure = structured
        } else if hasPresentationPhis || function.retainsPhiControlPresentation || Self.hasFunctionEntryPhi(function) {
            bodyStructure = emitPhiCFGBody(function: function, names: nameContext,
                callSignaturesByTarget: callSignaturesByTarget, into: &lines)
        } else {
            bodyStructure = emitBody(
                function: function,
                depth: 0,
                instructions: function.instructions,
                names: nameContext,
                callSignaturesByTarget: callSignaturesByTarget,
                into: &lines
            )
        }

        appendRefusals(function: function, to: &lines)
        if !emissionLimitReached {
            appendLine("}", kind: .closingBrace, to: &lines)
        }
        return PseudocodeDocument(
            functionName: function.name,
            entryAddress: function.startAddress,
            returnType: function.returnType,
            parameters: function.parameters,
            localVariables: function.localVariables,
            nameBindings: function.nameBindings,
            stackFrameSize: function.stackFrameSize,
            callTargets: function.callTargets,
            callSignatures: function.callSignatures,
            lines: lines,
            regionTree: bodyStructure.regionTree,
            structureFallback: bodyStructure.structureFallback
        )
    }

    private func appendRefusals(function: MacIRFunction, to lines: inout [PseudocodeLine]) {
        if function.ssaEnabled {
            for refusal in function.refusals where !emissionLimitReached {
                let address: UInt64?
                switch refusal.scope {
                case let .row(value), let .cell(_, value): address = value
                case let .block(index):
                    let blocks = function.cfg?.compatibilityCFG.blocks ?? []
                    address = blocks.indices.contains(index)
                        ? function.instructions[refusal.reason == .targetOutsideFunction
                            ? blocks[index].endIndex - 1 : blocks[index].startIndex].source.address : nil
                case .function: address = nil
                }
                // Entry-backedge refusal is an IR/census fact; its retained
                // row-wise presentation remains byte-identical.
                guard refusal.detail != "entry block has an in-graph predecessor" else { continue }
                let source = address.flatMap { value in function.instructions.first { $0.source.address == value }?.source }
                appendLine("    // refusal: \(Self.sanitizedComment(refusal.detail ?? refusal.reason.rawValue))",
                    kind: .metadata, source: source, refusal: refusal, to: &lines)
            }
        }
    }

    /// A complete two-arm assignment to one register needs one visible local.
    /// Keep the SSA select in MacIR; this only changes its proven presentation.
    private func emitVisibleDiamondJoin(
        function: MacIRFunction, names: PseudocodeNameContext,
        into lines: inout [PseudocodeLine]
    ) -> Bool {
        if function.ssaEnabled { return emitVisibleSSADiamondJoin(function: function, names: names, into: &lines) }
        let rows = function.instructions
        guard function.phis.isEmpty, rows.count == 6,
              case let .conditionalBranch(_, _, _, takenTarget) = rows[0].operation,
              case let .immediate(takenAddress) = takenTarget,
              UInt64(bitPattern: takenAddress) == rows[3].source.address,
              case let .assign(fallDestination, fallValue) = rows[1].operation,
              case .immediate = fallValue,
              case let .intrinsic(nil, "branch", branchArguments) = rows[2].operation,
              branchArguments == [.immediate(Int64(bitPattern: rows[4].source.address))],
              case let .assign(takenDestination, takenValue) = rows[3].operation,
              case .immediate = takenValue,
              case let .select(selectedDestination, condition, left, right,
                               selectedTaken, selectedFall) = rows[4].operation,
              selectedTaken == takenDestination, selectedFall == fallDestination,
              case let .returnValue(returned) = rows[5].operation,
              returned == selectedDestination,
              function.returnType == "int64_t",
              rows[1].source.address < rows[2].source.address,
              rows[2].source.address < rows[3].source.address,
              rows[3].source.address < rows[4].source.address,
              rows[4].source.address < rows[5].source.address,
              case let .register(fallRegister, _) = fallDestination,
              case let .register(takenRegister, _) = takenDestination,
              case let .register(returnRegister, _) = selectedDestination,
              returnRegister == "x0",
              fallRegister == takenRegister,
              fallRegister.hasPrefix("x") else { return false }
        let joinedName = "joined_\(fallRegister)"
        let conditionText = renderCondition(left: left, condition: condition,
                                            right: right, names: names)
        let occupiedNames = Set(function.parameters.map(\.name)
            + function.localVariables.map(\.name)
            + function.nameBindings.map(\.name)
            + Array(names.registerNameOverrides.values))
        guard !occupiedNames.contains(joinedName),
              !conditionText.contains(joinedName) else { return false }
        appendLine("    int64_t \(joinedName);", kind: .declaration, to: &lines)
        appendLine("    if (\(conditionText)) {", kind: .instruction,
                   source: rows[0].source, to: &lines)
        appendLine("        \(joinedName) = \(valueText(for: takenValue, names: names));",
                   kind: .instruction, source: rows[3].source, to: &lines)
        appendLine("    } else {", kind: .instruction, to: &lines)
        appendLine("        \(joinedName) = \(valueText(for: fallValue, names: names));",
                   kind: .instruction, source: rows[1].source, to: &lines)
        appendLine("    }", kind: .instruction, to: &lines)
        appendLine("    // x0 receives \(joinedName)", kind: .metadata,
                   source: rows[4].source, to: &lines)
        appendLine("    return \(joinedName);", kind: .instruction,
                   source: rows[5].source, to: &lines)
        return true
    }

    /// Only phis reachable from retained instruction inputs need printed copies.
    /// Follow persisted incoming expressions to a fixed point so live cycles and
    /// all scalar/vector projections keep their dependencies. The complete phi
    /// graph remains available to semantic consumers, including NZCV, memory
    /// ordering and QC, which have no numeric edge assignments in this printer.
    static func presentationPhis(_ function: MacIRFunction) -> [MacIRPhi] {
        guard function.ssaEnabled else { return function.phis }
        let candidates = function.phis.filter { ($0.cell ?? 0) < 96 }
        let byDestination = Dictionary(grouping: candidates.indices) { candidates[$0].destination }
        var pending: [MacIRValue] = []
        for instruction in function.instructions {
            pending.append(contentsOf: presentationInputs(instruction.operation))
            if let target = instruction.returnTarget { pending.append(target) }
            if let effect = instruction.fpEnvironment {
                pending += [effect.left, effect.right, effect.numericResult,
                            effect.fpcrInput, effect.fpsrInput, effect.fpsrOutput]
            }
        }
        if let returned = function.returnValue { pending.append(returned) }
        var visited: Set<MacIRValue> = []
        var retained: Set<Int> = []
        while let value = pending.popLast() {
            guard visited.insert(value).inserted else { continue }
            for index in byDestination[value, default: []] where retained.insert(index).inserted {
                pending.append(contentsOf: candidates[index].incoming.map(\.value))
            }
            switch value {
            case let .unary(_, inner), let .bitTest(inner, _):
                pending.append(inner)
            case let .signedBitfield(field): pending.append(field.source)
            case let .binaryExpression(_, left, right):
                pending += [left, right]
            case let .abiComposite(_, fragments):
                pending.append(contentsOf: fragments)
            case .register, .argument, .argumentFragment, .immediate, .stackSlot,
                 .symbol, .temporary, .unknown:
                break
            }
        }
        return candidates.indices.filter { retained.contains($0) }.map { candidates[$0] }
    }

    /// Remove an unused scalar result supported by a void contract, or a verified
    /// own-image call result with an independent caller-side physical lifetime proof.
    /// This is a presentation projection: call arguments, source spans, versions and
    /// the original model remain intact. Absence of a use alone never proves void.
    static func projectDirectVoidCallResults(_ function: MacIRFunction,
                                            ownDirectCallAddresses: Set<UInt64> = []) -> MacIRFunction {
        // SSA edge uses and opaque operations need a separate proof; do not guess.
        guard !function.ssaEnabled, function.phis.isEmpty,
              !function.instructions.contains(where: {
                  if case .unknown = $0.operation { return true }
                  // Typed semantic sidecars may carry additional uses. Admit only
                  // the plain operation envelope covered by presentationInputs.
                  return $0 != MacIRInstruction(source: $0.source, operation: $0.operation,
                      memoryAccess: $0.memoryAccess, returnTarget: $0.returnTarget)
              }) else { return function }
        var inputs = function.instructions.flatMap { instruction -> [MacIRValue] in
            var values = presentationInputs(instruction.operation)
            if let target = instruction.returnTarget { values.append(target) }
            if let effect = instruction.fpEnvironment {
                values += [effect.left, effect.right, effect.numericResult,
                           effect.fpcrInput, effect.fpsrInput, effect.fpsrOutput]
            }
            return values
        }
        if let value = function.returnValue { inputs.append(value) }
        var readRegisters: Set<MacIRValue> = []
        while let value = inputs.popLast() {
            switch value {
            case let .register(name, version):
                // x0 and w0 are views of the same ABI result storage.
                let carrier = MacIRBuilder.integerRegisterView(name)
                readRegisters.insert(.register(name: carrier?.index == 0 ? "x0" : name, version: version))
            case let .unary(_, inner), let .bitTest(inner, _): inputs.append(inner)
            case let .binaryExpression(_, left, right): inputs += [left, right]
            case let .signedBitfield(field): inputs.append(field.source)
            case let .abiComposite(_, fragments): inputs += fragments
            case .unknown: return function
            case .argument, .argumentFragment, .immediate, .stackSlot, .symbol, .temporary: break
            }
        }
        let physicallyDeadCalls: Set<UInt64> = ownDirectCallAddresses.isEmpty
            ? [] : callerScalarDeadCallAddresses(in: function)
        var projected = function
        for index in function.instructions.indices {
            let instruction = function.instructions[index]
            guard instruction.source.mnemonic.lowercased() == "bl",
                  case let .call(frame, result?) = instruction.operation,
                  frame.controlInputs.indirectTarget == nil,
                  frame.typedIndirectSignature == nil,
                  frame.typedIndirectCalleeType == nil,
                  frame.indirectResultPointer == nil,
                  case let .register(name, version) = result,
                  name == "x0" || name == "w0",
                  !readRegisters.contains(.register(name: "x0", version: version)),
                  (directCallHasVoidReturn(frame, signatures: function.callSignatures)
                   || (ownDirectCallAddresses.contains(instruction.source.address)
                       && physicallyDeadCalls.contains(instruction.source.address))) else { continue }
            projected.instructions[index].operation = .call(frame: frame, result: nil)
        }
        return projected
    }

    /// A narrow machine-register lifetime proof, independent of callee return
    /// type. The existing whole-function modeled-use guard must also pass.
    /// Only a contiguous linear run of validated scalar instructions is admitted;
    /// joins, branches, calls (even empty recovered arguments), RET and gaps refuse.
    /// This intentionally does not use absence from an effect helper as proof.
    static func callerScalarDeadCallAddresses(in function: MacIRFunction) -> Set<UInt64> {
        guard !function.ssaEnabled, function.phis.isEmpty else { return [] }
        let groups = Dictionary(grouping: function.instructions, by: { $0.source.address })
        guard groups.values.allSatisfy({ $0.count == 1 }) else { return [] }
        func register(_ text: String) -> Int? {
            guard text == text.lowercased(), let view = MacIRBuilder.integerRegisterView(text),
                  text == "x\(view.index)" || text == "w\(view.index)" else { return nil }
            return view.index
        }
        func input(_ text: String) -> Bool {
            if let index = register(text) { return index != 0 }
            return MacIRBuilder.parseImmediate(text) != nil
        }
        // One reverse pass, shared by all calls. A gap or unsupported transfer
        // resets the fact; only a validated overwrite introduces a true seed.
        var dead = false
        var nextAddress: UInt64?
        var result: Set<UInt64> = []
        for row in function.instructions.sorted(by: { $0.source.address > $1.source.address }) {
            let successor = row.source.address.addingReportingOverflow(4)
            if successor.overflow || nextAddress != successor.partialValue { dead = false }
            nextAddress = row.source.address
            guard row == MacIRInstruction(source: row.source, operation: row.operation,
                      memoryAccess: row.memoryAccess, returnTarget: row.returnTarget),
                  row.returnTarget == nil else { dead = false; continue }
            let mnemonic = row.source.mnemonic.lowercased()
            if case .call = row.operation {
                if mnemonic == "bl", dead { result.insert(row.source.address) }
                // The preceding call result may be an implicit argument here.
                dead = false
                continue
            }
            let operands = MacIRBuilder.splitOperands(row.source.operands)
            let destination: MacIRValue
            switch row.operation {
            case let .assign(value, _):
                guard mnemonic == "mov", operands.count == 2,
                      input(operands[1]) else { dead = false; continue }
                destination = value
            case let .binary(value, _, _, _):
                guard ["add", "sub", "and", "orr", "eor"].contains(mnemonic),
                      operands.count == 3, input(operands[1]), input(operands[2]) else {
                    dead = false; continue
                }
                destination = value
            default:
                dead = false
                continue
            }
            guard let rawDestination = operands.first, let index = register(rawDestination),
                  case let .register(name, _) = destination,
                  name == rawDestination else { dead = false; continue }
            // Sources were checked first: add x0,x0,#1 does not kill the old value.
            if index == 0 { dead = true }
        }
        return result
    }

    private static func directCallHasVoidReturn(_ frame: MacIRCallFrame,
                                                signatures: [MacIRCallSignature]) -> Bool {
        let contracts = signatures.filter { $0.target == frame.target }
            + (frame.knownSignature.map { [$0] } ?? [])
        // A conflicting nonvoid contract always wins over the built-in fallback.
        if !contracts.isEmpty {
            return contracts.allSatisfy { $0.target == frame.target && $0.returnsVoid }
        }
        // Public libc declaration: void __stack_chk_fail(void). Match the exact
        // Mach-O symbol only; noreturn in general does not imply a void result.
        // Return-only knowledge must not change recovered arguments or comments.
        return frame.target == "___stack_chk_fail"
    }

    private static func presentationInputs(_ operation: MacIROperation) -> [MacIRValue] {
        switch operation {
        case let .assign(_, source):
            return [source]
        case let .binary(_, _, left, right):
            return [left, right]
        case let .load(_, address):
            return [address]
        case let .store(source, address):
            return [source, address]
        case let .loadWriteback(_, _, baseSource, _, _):
            return [baseSource]
        case let .storeWriteback(source, _, baseSource, _, _):
            return [source, baseSource]
        case let .stackSlotRead(_, slot, value):
            return [slot, value]
        case let .stackSlotPairRead(_, firstSlot, firstValue, _, secondSlot, secondValue):
            return [firstSlot, firstValue, secondSlot, secondValue]
        case let .call(frame, _):
            return frame.bindingValues
        case let .conditionalBranch(_, left, right, target):
            return [left, right, target]
        case let .select(_, _, left, right, yes, no):
            return [left, right, yes, no]
        case let .compareToBool(_, _, left, right):
            return [left, right]
        case let .returnValue(value):
            return value.map { [$0] } ?? []
        case let .intrinsic(_, _, arguments):
            // Some intrinsics also carry output operands in this array.
            // Conservatively retaining them cannot delete a live phi.
            return arguments
        case let .switchDispatch(index, cases, defaultTarget):
            return [index] + cases.map(\.target) + (defaultTarget.map { [$0] } ?? [])
        case let .unknown(_, inputs, _, _):
            return inputs.mayRead.map(\.value) + inputs.definiteRead.map(\.value)
        }
    }

    /// A 32- or 64-bit join fed only by same-width unsigned loads, non-negative
    /// constants, explicit unsigned conversions and other such joins is unsigned:
    /// an `int32_t` phi would make a high-bit load an implementation-defined
    /// conversion.
    /// Load results whose every use is a bare operand of a signed relational branch.
    /// Ordinary C reads an unsigned load as unsigned, so the load itself is typed
    /// signed instead of casting the result (a high-bit unsigned-to-signed cast is
    /// not defined C).
    static func signedCompareOnlyLoadDestinations(_ function: MacIRFunction) -> Set<MacIRValue> {
        var casts: [MacIRValue: Int] = [:]
        func count(_ subject: Any, into counts: inout [MacIRValue: Int]) {
            if let value = subject as? MacIRValue {
                counts[value, default: 0] += 1
                // An explicit integer cast of a signed value is always defined.
                if case let .unary(op, inner) = value, op.hasPrefix("(uint") || op.hasPrefix("(int"),
                   case .register = inner { casts[inner, default: 0] += 1 }
                // A34: a resolved projection marker is a cast of its operand.
                if case let .binaryExpression(op, inner, _) = value, op == MacIRBuilder.signedProjectionOperator,
                   case .register = inner { casts[inner, default: 0] += 1 }
            }
            for child in Mirror(reflecting: subject).children { count(child.value, into: &counts) }
        }
        var mentions: [MacIRValue: Int] = [:], signedUses: [MacIRValue: Int] = [:]
        var loaded: Set<MacIRValue> = []
        for instruction in function.instructions {
            count(instruction.operation, into: &mentions)
            switch instruction.operation {
            case let .load(destination, _): if case .register = destination { loaded.insert(destination) }
            case let .intrinsic(_, name, arguments) where name == "compare":
                // The flag-setting compare is folded into its branch and never printed.
                for argument in arguments { if case .register = argument { casts[argument, default: 0] += 1 } }
            case let .conditionalBranch(condition, left, right, _) where ["<", "<=", ">", ">="].contains(condition):
                if case .register = left { signedUses[left, default: 0] += 1 }
                if case .register = right { signedUses[right, default: 0] += 1 }
            default: break
            }
        }
        for phi in function.phis { count(phi, into: &mentions) }
        return Set(loaded.filter { value in
            guard let uses = signedUses[value], uses > 0 else { return false }
            return mentions[value] == uses + (casts[value] ?? 0) + 1
        })
    }

    private static func phiScalarType(_ phi: MacIRPhi, in function: MacIRFunction) -> String {
        guard let index = function.phis.firstIndex(of: phi) else { return phiScalarType(phi) }
        return phiScalarTypes(in: function)[index]
    }

    /// Solve the unsigned proof coinductively: cycles start admitted, and a
    /// failed leaf removes every dependent proof alternative. No provisional
    /// DFS success escapes its cycle. Width belongs to each value query; a phi
    /// dependency switches to that phi's own width, as the recursive proof did.
    private static func phiScalarTypes(in function: MacIRFunction) -> [String] {
        enum Node: Hashable {
            case phi(Int)
            case value(MacIRValue, Int)
        }
        var firstPhi: [MacIRValue: Int] = [:]
        for (index, phi) in function.phis.enumerated() where firstPhi[phi.destination] == nil {
            firstPhi[phi.destination] = index
        }
        var definitions: [MacIRValue: [MacIRInstruction]] = [:]
        for instruction in function.instructions {
            let destinations: [MacIRValue]
            switch instruction.operation {
            case let .binary(destination, _, _, _), let .assign(destination, _), let .load(destination, _):
                destinations = [destination]
            case let .storeWriteback(_, destination, _, _, _), let .loadWriteback(_, destination, _, _, _):
                destinations = [destination]
            case let .intrinsic(destination?, _, _): destinations = [destination]
            case let .intrinsic(nil, "restore_pair", arguments) where arguments.count >= 3:
                destinations = Array(arguments.prefix(2))
            default: destinations = []
            }
            for destination in Set(destinations) { definitions[destination, default: []].append(instruction) }
        }
        // Each node is an OR of alternatives, each alternative an AND of inputs.
        // An empty alternative is a proven leaf; no alternatives is a refusal.
        func alternatives(_ node: Node) -> [[Node]] {
            switch node {
            case let .phi(index):
                let phi = function.phis[index]
                guard phi.scalarView == .integer, phi.bitWidth == 32 || phi.bitWidth == 64,
                      !phi.incoming.isEmpty else { return [] }
                return [phi.incoming.map { .value($0.value, phi.bitWidth) }]
            case let .value(value, width):
                if case .unary(width == 32 ? "(uint32_t)" : "(uint64_t)", _) = value { return [[]] }
                if let index = firstPhi[value] { return [[.phi(index)]] }
                return (definitions[value] ?? []).compactMap { instruction -> [Node]? in
                    switch instruction.operation {
                    case let .binary(_, op, left, right):
                        guard ["+", "-", "&", "|", "^", "<<", ">>"].contains(op) else { return nil }
                        if case .immediate = right { return [.value(left, width)] }
                        return [.value(right, width), .value(left, width)]
                    case let .assign(_, source):
                        if case let .immediate(constant) = source {
                            return constant >= 0 && (width == 64 || constant <= Int64(UInt32.max)) ? [] : nil
                        }
                        if case .unary(width == 32 ? "(uint32_t)" : "(uint64_t)", _) = source { return [] }
                        return nil
                    case let .storeWriteback(_, _, baseSource, _, _), let .loadWriteback(_, _, baseSource, _, _):
                        return [.value(baseSource, width)]
                    case let .intrinsic(destination?, name, _) where destination == value:
                        return name.contains("adrp") && width == 64 ? [] : nil
                    case let .intrinsic(nil, "restore_pair", arguments):
                        guard arguments.count >= 3, arguments.prefix(2).contains(value),
                              case let .register(register, _) = value else { return nil }
                        return MacIRBuilder.integerRegisterView(register)?.width == width
                            && instruction.memoryAccess?.byteWidth != 16 ? [] : nil
                    case let .load(destination, _):
                        if let access = instruction.memoryAccess {
                            return access.byteWidth * 8 == width && access.extensionKind != .sign ? [] : nil
                        }
                        if case let .register(register, _) = destination {
                            return MacIRBuilder.integerRegisterView(register)?.width == width ? [] : nil
                        }
                        return nil
                    default: return nil
                    }
                }
            }
        }
        var nodes = function.phis.indices.map { Node.phi($0) }
        var discovered = Set(nodes)
        var rules: [Node: [[Node]]] = [:]
        var cursor = 0
        while cursor < nodes.count {
            let node = nodes[cursor]; cursor += 1
            let choices = alternatives(node)
            rules[node] = choices
            for dependency in choices.flatMap({ $0 }) where discovered.insert(dependency).inserted {
                nodes.append(dependency)
            }
        }
        var dependents: [Node: [(Node, Int)]] = [:]
        var remaining: [Node: Int] = [:]
        var invalid: [Node: Set<Int>] = [:]
        var rejected: Set<Node> = []
        var queue: [Node] = []
        for node in nodes {
            let choices = rules[node] ?? []
            remaining[node] = choices.count
            if choices.isEmpty { rejected.insert(node); queue.append(node) }
            for (index, inputs) in choices.enumerated() {
                for input in Set(inputs) { dependents[input, default: []].append((node, index)) }
            }
        }
        cursor = 0
        while cursor < queue.count {
            let failed = queue[cursor]; cursor += 1
            for (node, alternative) in dependents[failed] ?? [] {
                guard !rejected.contains(node), invalid[node, default: []].insert(alternative).inserted else { continue }
                remaining[node, default: 0] -= 1
                if remaining[node] == 0 { rejected.insert(node); queue.append(node) }
            }
        }
        return function.phis.enumerated().map { index, phi in
            rejected.contains(.phi(index)) ? phiScalarType(phi) : "uint\(phi.bitWidth)_t"
        }
    }

    private static func phiScalarType(_ phi: MacIRPhi) -> String {
        switch phi.scalarView {
        case .binary32: return "float"
        case .binary64: return "double"
        case .bits64: return "uint64_t"
        case .integer: return phi.bitWidth == 128 ? "__uint128_t" : "int\(phi.bitWidth)_t"
        }
    }

    /// A phi transports register bits, not an out-of-range unsigned-to-signed
    /// C conversion. Normalize to the destination storage width, then use the
    /// existing defined signed projection. All incoming values here are persisted
    /// pure SSA values; scheduling still snapshots every source before any write.
    /// Call only for SSA copies: legacy declarations and expressions stay intact.
    static func phiTransportValue(_ value: MacIRValue, type: String, sourceType: String?) -> MacIRValue {
        let width: Int
        switch type {
        case "int32_t": width = 32
        case "int64_t": width = 64
        default: return value
        }
        if sourceType == type { return value }
        return .binaryExpression(op: MacIRBuilder.signedProjectionOperator,
            left: .unary(op: "(uint\(width)_t)", value: value), right: .immediate(Int64(width)))
    }

    /// Copy-local C type facts, never merged into the general rendering context.
    /// Declared phis seed cycles; inferred values require one plain defining row.
    /// Structured recovery can rewrite scalar RHSs, so it uses declarations only.
    func phiTransportSourceTypes(in function: MacIRFunction, names: PseudocodeNameContext,
                                 phiTypes: [(MacIRValue, String)], inferPlainScalars: Bool) -> [MacIRValue: String] {
        var writes: [MacIRValue: Int] = [:]
        var atoms: Set<MacIRValue> = []
        var blocked: Set<MacIRValue> = []
        for row in function.instructions {
            RegionalBoundaryPlan.values(row.operation)?.forEach { RegionalBoundaryPlan.collectAtoms($0, into: &atoms) }
            let destinations: [MacIRValue]
            switch row.operation {
            case let .assign(d, _), let .binary(d, _, _, _), let .load(d, _),
                 let .select(d, _, _, _, _, _), let .compareToBool(d, _, _, _),
                 let .stackSlotRead(d, _, _): destinations = [d]
            case let .loadWriteback(d, base, _, _, _): destinations = [d, base]
            case let .storeWriteback(_, base, _, _, _): destinations = [base]
            case let .stackSlotPairRead(a, _, _, b, _, _): destinations = [a, b]
            case let .call(_, result), let .unknown(result, _, _, _): destinations = result.map { [$0] } ?? []
            case let .intrinsic(result, name, arguments):
                destinations = result.map { [$0] } ?? []
                // A comparison reads its scalar arguments and writes only flags.
                // Other tuple/helper argument positions are not type authority.
                if result != nil || name != "compare" {
                    arguments.forEach { RegionalBoundaryPlan.collectAtoms($0, into: &blocked) }
                }
            default: destinations = []
            }
            destinations.forEach { writes[$0, default: 0] += 1; atoms.insert($0) }
        }
        phiTypes.forEach { atoms.insert($0.0) }
        for parameter in function.parameters {
            if let binding = parameter.bindingID { atoms.insert(.argument(bindingID: binding)) }
        }
        var owners: [String: Set<MacIRValue>] = [:]
        for atom in atoms {
            switch atom {
            case .argument, .register, .temporary, .stackSlot:
                let spelling = valueText(for: atom, names: names)
                owners[spelling, default: []].insert(atom)
                if function.localVariables.contains(where: { $0.name == spelling }) { blocked.insert(atom) }
            default: break
            }
        }
        for values in owners.values where values.count != 1 { blocked.formUnion(values) }
        for (value, count) in writes where count != 1 { blocked.insert(value) }
        var facts: [MacIRValue: String] = [:]
        func record(_ value: MacIRValue, _ type: String) {
            guard !blocked.contains(value) else { return }
            if let existing = names.valueTypes[value], existing != type { blocked.insert(value); facts[value] = nil; return }
            if let existing = facts[value], existing != type { blocked.insert(value); facts[value] = nil; return }
            facts[value] = type
        }
        if names.emitsParameterDeclarations {
            let byName = Dictionary(grouping: function.parameters, by: \.name)
            for parameter in function.parameters {
                guard let binding = parameter.bindingID, byName[parameter.name]?.count == 1,
                      names.argumentNames[binding] == parameter.name,
                      names.argumentTypes[binding] == parameter.type,
                      names.parameterTypesByBinding[binding] == parameter.type,
                      !function.localVariables.contains(where: { $0.name == parameter.name }) else { continue }
                record(.argument(bindingID: binding), parameter.type)
            }
        }
        let groupedPhis = Dictionary(grouping: phiTypes, by: { $0.0 })
        for (value, entries) in groupedPhis {
            guard entries.count == 1, writes[value] == nil,
                  !function.localVariables.contains(where: { $0.name == valueText(for: value, names: names) }) else { blocked.insert(value); continue }
            record(value, entries[0].1)
        }
        guard inferPlainScalars else { return facts }
        func expressionType(_ value: MacIRValue) -> String? {
            if let type = facts[value], !blocked.contains(value) { return type }
            switch value {
            case let .immediate(integer) where (-Int64(Int32.max)...Int64(Int32.max)).contains(integer):
                // -0x80000000 has an unsigned hexadecimal operand in C.
                // Its unary minus is still unsigned; Int32.min is excluded.
                return "int32_t"
            case let .unary(op, operand) where op == "(int32_t)" || op == "(int64_t)":
                guard expressionType(operand) != nil else { return nil }
                return String(op.dropFirst().dropLast())
            case let .binaryExpression(op, left, right) where op == "+" || op == "-":
                guard let a = expressionType(left), let b = expressionType(right),
                      ["int32_t", "int64_t"].contains(a), ["int32_t", "int64_t"].contains(b) else { return nil }
                return a == "int64_t" || b == "int64_t" ? "int64_t" : "int32_t"
            default: return nil
            }
        }
        // Monotone finite propagation: no value is inferred from its phi input
        // or from a similarly spelled variable; unsigned operands do not certify
        // a signed arithmetic result. Unknown operations remain unknown.
        var changed = true
        while changed {
            changed = false
            for row in function.instructions {
                guard row == MacIRInstruction(source: row.source, operation: row.operation, memoryAccess: row.memoryAccess) else { continue }
                let destination: MacIRValue
                let type: String?
                switch row.operation {
                case let .assign(d, source):
                    guard !names.ordinarySSAMemoryEffects else { continue }
                    destination = d; type = expressionType(source)
                case let .binary(d, op, left, right) where op == "+" || op == "-":
                    guard !names.unsignedSelectorDestinations.contains(d) else { continue }
                    destination = d; type = expressionType(.binaryExpression(op: op, left: left, right: right))
                case let .load(d, address):
                    if case .stackSlot = address { continue }
                    if case let .register(register, _) = d,
                       MacIRBuilder.integerRegisterView(register) == nil { continue }
                    if case let .argument(binding) = d, binding.kind == .simd { continue }
                    guard let access = row.memoryAccess, [1, 2, 4, 8].contains(access.byteWidth),
                          !names.ordinarySSAMemoryEffects else { continue }
                    var addressAtoms: Set<MacIRValue> = []
                    RegionalBoundaryPlan.collectAtoms(address, into: &addressAtoms)
                    guard !addressAtoms.contains(where: { emittedPointerType(for: $0, names: names) != nil }) else { continue }
                    destination = d
                    type = "\(access.extensionKind == .sign ? "int" : "uint")\(access.byteWidth * 8)_t"
                default: continue
                }
                guard writes[destination] == 1, facts[destination] == nil,
                      !blocked.contains(destination), let type else { continue }
                record(destination, type)
                if facts[destination] != nil { changed = true }
            }
        }
        return facts.filter { !blocked.contains($0.key) }
    }

    private static func phiSource(_ phi: MacIRPhi, predecessor: UInt64?) -> MacIRSourceSpan {
        var source = MacIRSourceSpan(address: phi.blockAddress, byteText: "", mnemonic: "phi", operands: "")
        source.syntheticPhiEdge = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
            predecessor: predecessor.map { .machine($0) } ?? phi.incoming.first?.predecessor ?? .machine(phi.blockAddress),
            destination: phi.destination)
        return source
    }

    private static func phiSource(_ phi: MacIRPhi, edge: MacIRPhiPredecessor) -> MacIRSourceSpan {
        var source = MacIRSourceSpan(address: phi.blockAddress, byteText: "", mnemonic: "phi", operands: "")
        source.syntheticPhiEdge = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
            predecessor: edge, destination: phi.destination)
        return source
    }

    private static func hasFunctionEntryPhi(_ function: MacIRFunction) -> Bool {
        function.phis.contains { $0.incoming.contains { $0.predecessor == .functionEntry } }
    }

    /// A virtual predecessor reads original bindings before the loop. Its
    /// declarations must not shadow those bindings through presentation renames.
    private func entryPhiNamesAreSafe(_ function: MacIRFunction, names: PseudocodeNameContext) -> Bool {
        let phis = Self.presentationPhis(function)
        let destinationNames = phis.map { valueText(for: $0.destination, names: names) }
        let destinations = Set(destinationNames)
        guard destinations.count == phis.count,
              destinations.isDisjoint(with: function.parameters.map(\.name)),
              destinations.isDisjoint(with: function.localVariables.map(\.name)) else { return false }
        for phi in phis {
            var pending = phi.incoming.filter { $0.predecessor == .functionEntry }.map(\.value)
            while let value = pending.popLast() {
                switch value {
                case let .unary(_, inner), let .bitTest(inner, _): pending.append(inner)
                case let .signedBitfield(field): pending.append(field.source)
                case let .binaryExpression(_, left, right): pending += [left, right]
                case let .abiComposite(_, fragments): pending += fragments
                case .unknown: return false
                case .argument, .argumentFragment, .register, .stackSlot, .symbol, .temporary, .immediate:
                    if value != phi.destination,
                       destinations.contains(valueText(for: value, names: names)) { return false }
                }
            }
        }
        return true
    }

    private func emitVisibleSSADiamondJoin(function: MacIRFunction, names: PseudocodeNameContext,
                                          into lines: inout [PseudocodeLine]) -> Bool {
        let rows = function.instructions
        let phis = Self.presentationPhis(function)
        guard !Self.hasFunctionEntryPhi(function), rows.count == 6, phis.count == 1,
              let phi = phis.first, phi.bitWidth == 64, phi.scalarView == .integer,
              phi.blockAddress == rows[4].source.address,
              case let .conditionalBranch(condition, left, right, .immediate(taken)) = rows[0].operation,
              UInt64(bitPattern: taken) == rows[3].source.address,
              case let .assign(fallDestination, fallValue) = rows[1].operation,
              case .immediate = fallValue,
              case let .intrinsic(nil, "branch", arguments) = rows[2].operation,
              arguments == [.immediate(Int64(bitPattern: phi.blockAddress))],
              case let .assign(takenDestination, takenValue) = rows[3].operation,
              case .immediate = takenValue,
              phi.incoming == [.init(predecessorAddress: rows[2].source.address, value: fallDestination),
                               .init(predecessorAddress: rows[3].source.address, value: takenDestination)],
              case let .assign(selectedDestination, source) = rows[4].operation, source == phi.destination,
              case let .returnValue(returned) = rows[5].operation, returned == selectedDestination,
              function.returnType == "int64_t",
              case let .register(fallRegister, _) = fallDestination,
              case let .register(takenRegister, _) = takenDestination,
              case .register("x0", _) = selectedDestination,
              fallRegister == takenRegister, fallRegister.hasPrefix("x"),
              let cfg = function.cfg?.compatibilityCFG,
              cfg.postDomTree[cfg.entryIndex].map({ cfg.blocks[$0].startIndex }) == 4 else { return false }
        let joinedName = "joined_\(fallRegister)"
        let conditionText = renderCondition(left: left, condition: condition, right: right, names: names)
        let occupied = Set(function.parameters.map(\.name) + function.localVariables.map(\.name)
            + function.nameBindings.map(\.name) + Array(names.registerNameOverrides.values))
        guard !occupied.contains(joinedName), !conditionText.contains(joinedName) else { return false }
        appendLine("    int64_t \(joinedName);", kind: .declaration,
                   source: Self.phiSource(phi, predecessor: nil), to: &lines)
        appendLine("    if (\(conditionText)) {", kind: .instruction, source: rows[0].source, to: &lines)
        appendLine("        \(joinedName) = \(valueText(for: takenValue, names: names));",
                   kind: .instruction, source: rows[3].source, to: &lines)
        appendLine("    } else {", kind: .instruction, to: &lines)
        appendLine("        \(joinedName) = \(valueText(for: fallValue, names: names));",
                   kind: .instruction, source: rows[1].source, to: &lines)
        appendLine("    }", kind: .instruction, to: &lines)
        appendLine("    // x0 receives \(joinedName)", kind: .metadata, source: rows[4].source, to: &lines)
        appendLine("    return \(joinedName);", kind: .instruction, source: rows[5].source, to: &lines)
        return true
    }

    /// De-SSA is a presentation transaction. Each persisted incoming is read
    /// at its predecessor exit; split critical edges keep those reads conditional.
    /// The existing region tree consumes this copy-expanded graph. The original
    /// function, its architectural graph, and its instruction list stay intact.
    private func emitSSAEdgeProjection(function: MacIRFunction, names: PseudocodeNameContext,
                                      callSignaturesByTarget: [String: MacIRCallSignature],
                                      into lines: inout [PseudocodeLine]) -> BodyStructureResult? {
        let architecturalFunction = function
        // The existing native recurrence proof consumes the sealed virtual
        // entry and actual backedge values without stripping architectural phis.
        // Unsupported shapes retain the exact flat edge-copy fallback.
        if Self.hasFunctionEntryPhi(function) {
            guard MacIRBuilder.hasBoundedEntryLoopProof(function),
                  let cfg = function.cfg?.compatibilityCFG,
                  let region = emitEntryLoopFallbackCandidate(function: function, cfg: cfg,
                    depth: 0, names: names, callSignaturesByTarget: callSignaturesByTarget,
                    lexicalProof: nil, into: &lines) else { return nil }
            return BodyStructureResult(regionTree: region, structureFallback: nil)
        }
        let function = Self.ssaComparisonPresentation(of: function)
        guard let cfg = function.cfg?.compatibilityCFG, !cfg.hasUnresolvedTargets,
              cfg.irreducibleBlocks.isEmpty, !cfg.blocks.isEmpty
        else {
            PseudocodeSSARecoveryEmitter.diagnose(function: function, stage: "projection",
                reason: "missing-closed-nonempty-reducible-cfg")
            return nil
        }
        // A38: the existing flag-off physical-state proof (the only authority on call-boundary
        // agreement: symbolic target, decoded BL envelope, resultless-call reads) gates admission.
        if case let .failure(refusal) = RegionalPhysicalStatePlan.proveClassified(
            function: architecturalFunction, cfg: cfg), refusal.isContradiction {
            PseudocodeSSARecoveryEmitter.diagnose(function: function, stage: "projection",
                reason: "physical-state-contradiction:\(refusal.guardName)")
            return nil
        }
        // This projection preserves the already lifted operations, including
        // call effects and contracts. It only schedules persisted edge values.
        let rows = function.instructions
        let presentationPhis = Self.presentationPhis(function)
        let scalarTypes = Self.phiScalarTypes(in: function)
        func phiType(_ phi: MacIRPhi) -> String {
            guard let index = function.phis.firstIndex(of: phi) else { return Self.phiScalarType(phi) }
            return scalarTypes[index]
        }
        let transportTypes = phiTransportSourceTypes(in: function, names: names,
            phiTypes: presentationPhis.map { ($0.destination, phiType($0)) }, inferPlainScalars: false)
        let byAddress = Dictionary(uniqueKeysWithValues: cfg.blocks.map { (rows[$0.startIndex].source.address, $0.index) })
        var copies: [CFGEdge: [MacIRInstruction]] = [:]
        var temporaryTypes: [(MacIRValue, String, MacIRSourceSpan)] = []
        var address = (rows.map { $0.source.address }.max() ?? 0)
        guard address < UInt64(Int64.max) - UInt64(presentationPhis.count * 32 + rows.count * 32 + 4096) else { return nil }
        var usedAtoms: Set<MacIRValue> = []
        rows.forEach { instruction in
            RegionalBoundaryPlan.values(instruction.operation)?.forEach { RegionalBoundaryPlan.collectAtoms($0, into: &usedAtoms) }
        }
        presentationPhis.forEach { phi in
            RegionalBoundaryPlan.collectAtoms(phi.destination, into: &usedAtoms)
            phi.incoming.forEach { RegionalBoundaryPlan.collectAtoms($0.value, into: &usedAtoms) }
        }
        var occupiedNames = Set(usedAtoms.map { valueText(for: $0, names: names) })
            .union(function.parameters.map(\.name)).union(function.localVariables.map(\.name))
            .union(function.nameBindings.map(\.name)).union(names.registerNameOverrides.values)
        var temporary = (usedAtoms.compactMap { value -> Int? in
            if case let .temporary(index) = value { return index }; return nil
        }.max() ?? -1) + 1
        func nextSource(_ phi: MacIRPhi, predecessor: UInt64) -> MacIRSourceSpan {
            address += 4
            var source = Self.phiSource(phi, predecessor: predecessor)
            source.address = address
            return source
        }
        var pending: [CFGEdge: [(MacIRPhi, MacIRValue)]] = [:]
        for phi in presentationPhis {
            let machineInputs = phi.incoming.filter { $0.machineAddress != nil }
            guard let block = byAddress[phi.blockAddress],
                  machineInputs.compactMap(\.machineAddress) == cfg.blocks[block].predecessors.map({ rows[cfg.blocks[$0].endIndex - 1].source.address })
            else { return nil }
            for (predecessor, incoming) in zip(cfg.blocks[block].predecessors, machineInputs) {
                pending[CFGEdge(predecessor, block), default: []].append((phi, incoming.value))
            }
        }
        for edge in pending.keys.sorted(by: { $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from }) {
            let predecessor = rows[cfg.blocks[edge.from].endIndex - 1].source.address
            let assignments = pending[edge, default: []]
            let destinations = Set(assignments.map { $0.0.destination })
            if !edgeCopyNeedsSnapshots(destinations: destinations,
                incoming: assignments.map { $0.1 }, names: names) {
                // Independent copies need no snapshots. Preserve the persisted bits
                // and predecessor-specific sources across the C storage boundary.
                copies[edge] = assignments.map { phi, incoming in
                    MacIRInstruction(source: nextSource(phi, predecessor: predecessor),
                        operation: .assign(destination: phi.destination,
                            source: Self.phiTransportValue(incoming, type: phiType(phi), sourceType: transportTypes[incoming])))
                }
                continue
            }
            var writes: [MacIRInstruction] = []
            for (phi, incoming) in assignments {
                var snapshot = MacIRValue.temporary(temporary); temporary += 1
                while occupiedNames.contains(valueText(for: snapshot, names: names)) {
                    snapshot = .temporary(temporary); temporary += 1
                }
                occupiedNames.insert(valueText(for: snapshot, names: names))
                let source = nextSource(phi, predecessor: predecessor)
                temporaryTypes.append((snapshot, phiType(phi), source))
                copies[edge, default: []].append(MacIRInstruction(source: source,
                    operation: .assign(destination: snapshot,
                        source: Self.phiTransportValue(incoming, type: phiType(phi), sourceType: transportTypes[incoming]))))
                writes.append(MacIRInstruction(source: nextSource(phi, predecessor: predecessor),
                    operation: .assign(destination: phi.destination, source: snapshot)))
            }
            copies[edge, default: []] += writes
        }
        // A structured transaction must preserve callable bindings as well as
        // text. Original destinations and new phi storage can both shadow a
        // retained direct or resolved indirect callee.
        var callables: Set<String> = []
        for row in rows {
            guard case let .call(frame, _) = row.operation else { continue }
            let display = row.source.mnemonic == "bl"
                ? (names.callTargetRenames[frame.target] ?? frame.target)
                : names.resolvedIndirectCalls[row.source.address]?.name
            if let display {
                callables.formUnion(tokenize(display, lineNumber: 0, sourceAddress: nil)
                    .filter { $0.kind == .identifier || $0.kind == .intrinsic }.map(\.text))
            }
        }
        let writtenValues = rows.flatMap { MacIRBuilder.ssaDestinations($0.operation) }
            + presentationPhis.map(\.destination) + temporaryTypes.map { $0.0 }
        guard writtenValues.allSatisfy({
            !callables.contains(valueText(for: $0, names: names))
        }) else { return nil }
        let originalEdgeCopies = copies
        var splitAddress: [CFGEdge: UInt64] = [:]
        for (edge, schedule) in copies where cfg.blocks[edge.from].successors.count > 1 {
            splitAddress[edge] = schedule.first?.source.address
        }
        var leaderAddress: [Int: UInt64] = [:]
        for block in cfg.blocks {
            let edge = block.successors.count == 1 ? CFGEdge(block.index, block.successors[0]) : nil
            // A one-row transfer needs its copies before the old leader.
            if block.endIndex == block.startIndex + 1,
               CFGBuilder.terminatorKind(of: rows[block.startIndex].operation) != .none,
               let edge, var schedule = copies[edge], !schedule.isEmpty {
                schedule[0].source.address = rows[block.startIndex].source.address
                copies[edge] = schedule
            }
            leaderAddress[block.index] = rows[block.startIndex].source.address
        }
        func target(_ original: MacIRValue, from block: Int) -> MacIRValue {
            guard case let .immediate(raw) = original, let successor = byAddress[UInt64(bitPattern: raw)] else { return original }
            return .immediate(Int64(bitPattern: splitAddress[CFGEdge(block, successor)] ?? leaderAddress[successor] ?? rows[cfg.blocks[successor].startIndex].source.address))
        }
        func transfer(to block: Int, source: MacIRSourceSpan) -> MacIRInstruction {
            address += 4
            var synthetic = source; synthetic.address = address
            return MacIRInstruction(source: synthetic, operation: .intrinsic(destination: nil, name: "branch",
                arguments: [.immediate(Int64(bitPattern: leaderAddress[block] ?? rows[cfg.blocks[block].startIndex].source.address))]))
        }
        var projected: [MacIRInstruction] = []
        for block in cfg.blocks {
            let last = block.endIndex - 1
            projected += rows[block.startIndex..<last]
            var terminal = rows[last]
            if block.successors.count == 1, let successor = block.successors.first,
               let schedule = copies[CFGEdge(block.index, successor)] {
                if CFGBuilder.terminatorKind(of: terminal.operation) == .none {
                    projected.append(terminal); projected += schedule; continue
                }
                projected += schedule
            }
            switch terminal.operation {
            case let .conditionalBranch(condition, left, right, destination):
                terminal.operation = .conditionalBranch(condition: condition, left: left, right: right,
                    target: target(destination, from: block.index))
            case let .intrinsic(nil, "branch", arguments) where arguments.count == 1:
                terminal.operation = .intrinsic(destination: nil, name: "branch", arguments: [target(arguments[0], from: block.index)])
            case let .intrinsic(destination, name, arguments)
                where name.hasPrefix("branch_") && name != "branch_register" && !arguments.isEmpty:
                terminal.operation = .intrinsic(destination: destination, name: name,
                    arguments: [target(arguments[0], from: block.index)] + arguments.dropFirst())
            case let .switchDispatch(index, cases, defaultTarget):
                terminal.operation = .switchDispatch(index: index,
                    cases: cases.map { .init(value: $0.value, target: target($0.target, from: block.index)) },
                    defaultTarget: defaultTarget.map { target($0, from: block.index) })
            default: break
            }
            projected.append(terminal)
            // Keep edge-only copies next to their predecessor. Appending them
            // beyond the function's lexical tail separates shared tails and
            // natural loops from their own copy blocks.
            var outgoingSplits = splitAddress.keys.filter { $0.from == block.index }
                .sorted { $0.to < $1.to }
            if case let .conditionalBranch(originalTarget) = CFGBuilder.terminatorKind(of: rows[last].operation),
               let originalTarget, let taken = byAddress[originalTarget],
               let fallthroughBlock = block.successors.first(where: { $0 != taken }) {
                let fallthroughEdge = CFGEdge(block.index, fallthroughBlock)
                if let schedule = copies[fallthroughEdge], let first = schedule.first {
                    projected += schedule
                    projected.append(transfer(to: fallthroughBlock, source: first.source))
                } else if let split = outgoingSplits.first,
                          let first = copies[split]?.first {
                    // The original fallthrough must skip the taken edge's
                    // copies, even when that edge has no assignments itself.
                    projected.append(transfer(to: fallthroughBlock, source: first.source))
                }
                outgoingSplits.removeAll { $0 == fallthroughEdge }
            }
            for edge in outgoingSplits {
                guard let schedule = copies[edge], let first = schedule.first else { return nil }
                projected += schedule
                projected.append(transfer(to: edge.to, source: first.source))
            }
        }
        var candidate = function
        candidate.instructions = projected; candidate.phis = []; candidate.cfg = nil
        var scratch = lines
        for phi in presentationPhis {
            appendLine("    \(phiType(phi)) \(valueText(for: phi.destination, names: names));",
                kind: .declaration, source: Self.phiSource(phi, predecessor: nil), to: &scratch)
        }
        for (value, type, source) in temporaryTypes {
            appendLine("    \(type) \(valueText(for: value, names: names));", kind: .declaration, source: source, to: &scratch)
        }
        var projectedNames = names
        projectedNames.redundantCompareIndices = redundantCompareIndices(function: candidate, names: projectedNames)
        for phi in presentationPhis { projectedNames.valueTypes[phi.destination] = phiType(phi) }
        for (value, type, _) in temporaryTypes { projectedNames.valueTypes[value] = type }
        let declarationLines = scratch
        let result = emitBody(function: candidate, depth: 0, instructions: projected, names: projectedNames,
            callSignaturesByTarget: callSignaturesByTarget, into: &scratch)
        guard result.regionTree != nil else {
            // The original graph owns all control edges. Bind its persisted
            // copies to those edges instead of rendering projected copy tails.
            let unresolved = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
            var recoveryNames = projectedNames
            recoveryNames.ordinarySSAMemoryEffects = true
            // A 32-bit jump-table selector is compared unsigned, so its defining
            // subtract is written as an unsigned 32-bit operation.
            recoveryNames.addressBaseRegisters = Set(function.instructions.compactMap { instruction -> MacIRValue? in
                var address: MacIRValue
                switch instruction.operation {
                case let .load(_, location), let .store(_, location): address = location
                default: return nil
                }
                while case let .binaryExpression(_, left, _) = address { address = left }
                if case .register = address { return address }
                return nil
            })
            recoveryNames.signedCompareLoadDestinations = Self.signedCompareOnlyLoadDestinations(function)
            struct SubsKey: Hashable { var minuend: MacIRValue; var subtrahend: Int64 }
            var subsResults: [SubsKey: MacIRValue] = [:]
            for instruction in function.instructions {
                if instruction.source.mnemonic.lowercased() == "subs",
                   case let .binary(destination, "-", minuend, .immediate(subtrahend)) = instruction.operation,
                   case .register = destination, case .register = minuend {
                    subsResults[.init(minuend: minuend, subtrahend: subtrahend)] = destination
                }
            }
            recoveryNames.unsignedSelectorDestinations = Set(function.instructions.compactMap { instruction in
                if case let .switchDispatch(selector, _, _) = instruction.operation { return selector }
                return nil
            })
            recoveryNames.redundantCompareIndices = redundantCompareIndices(function: function, names: recoveryNames)
            let recoveryPlan = function.returnValue != unresolved
                ? RegionTree.ssaRecoveryPlan(function: function, cfg: cfg) : nil
            if function.returnValue == unresolved {
                PseudocodeSSARecoveryEmitter.diagnose(function: function, stage: "admission", reason: "unresolved-return-contract")
            } else if recoveryPlan == nil {
                PseudocodeSSARecoveryEmitter.diagnose(function: function, stage: "admission", reason: "topology-plan")
            }
            if let plan = recoveryPlan,
               let recovered = PseudocodeSSARecoveryEmitter.emit(function: function, cfg: cfg,
                    plan: plan, copies: originalEdgeCopies, depth: 0, lineOffset: declarationLines.count,
                    rendering: .init(block: { block, depth, suppressed in
                        var payload: [PseudocodeLine] = []
                        guard emitBlock(block, depth: depth, cfg: cfg, instructions: rows,
                            names: recoveryNames, callSignaturesByTarget: callSignaturesByTarget,
                            suppressedInstructions: suppressed, into: &payload) else { return nil }
                        return payload
                    }, value: { valueText(for: $0, names: recoveryNames) },
                    condition: { operation, inverse in
                        guard case let .conditionalBranch(op, left, right, _) = operation else { return nil }
                        // `subs d, x, #k` then `b.eq/ne` compares x with k; the
                        // source-faithful test reads the subtraction's result.
                        if op == "==" || op == "!=", case let .immediate(subtrahend) = right,
                           let result = subsResults[.init(minuend: left, subtrahend: subtrahend)] {
                            let condition = inverse ? (op == "==" ? "!=" : "==") : op
                            return renderCondition(left: result, condition: condition, right: .immediate(0), names: recoveryNames)
                        }
                        let unsupported = right == .immediate(0) && isCompoundCondition(left)
                            && negateCondition(left) == nil
                        if unsupported && op == "==" { return nil }
                        guard !inverse || !unsupported,
                              let condition = inverse ? invertedBranchCondition(op) : op else { return nil }
                        return renderCondition(left: left, condition: condition, right: right, names: recoveryNames)
                    }, copy: { render(instruction: $0, names: recoveryNames) },
                    comment: { commentSuffix(for: $0, callSignaturesByTarget: callSignaturesByTarget) },
                    cancelled: { emissionCancellation?.isCancelled == true || emissionLimitReached })) {
                var recoveryLines = declarationLines
                for fragment in recovered.fragments {
                    appendLine(fragment.text, kind: fragment.kind, source: fragment.source, to: &recoveryLines)
                }
                lines = recoveryLines
                return .init(regionTree: recovered.region, structureFallback: nil)
            }
            // Prefer the exact SSA projection; certificates remain an unchanged
            // fallback over the architectural instructions, never copy rows.
            if let certified = emitRegionalPhysicalFallback(function: architecturalFunction,
                cfg: cfg, depth: 0, names: names,
                callSignaturesByTarget: callSignaturesByTarget, into: &lines) {
                return .init(regionTree: certified, structureFallback: nil)
            }
            // Retain the structurer's precise refusal while using the original
            // graph for flat copies. A phi must not erase an unsupported-region
            // diagnostic or make projected synthetic rows own original text.
            _ = emitPhiCFGBody(function: function, names: names,
                callSignaturesByTarget: callSignaturesByTarget, into: &lines)
            return result
        }
        lines = scratch
        return result
    }

    private func edgeCopyNeedsSnapshots(destinations: Set<MacIRValue>, incoming: [MacIRValue],
                                       names: PseudocodeNameContext) -> Bool {
        let destinationNames = Set(destinations.map { valueText(for: $0, names: names) })
        var reads: Set<MacIRValue> = []
        var worklist = incoming
        var hasOpaqueRead = false
        while let value = worklist.popLast() {
            switch value {
            case let .unary(_, inner), let .bitTest(inner, _): worklist.append(inner)
            case let .signedBitfield(field): worklist.append(field.source)
            case let .binaryExpression(_, left, right): worklist += [left, right]
            case let .abiComposite(_, fragments): worklist += fragments
            case .unknown, .argumentFragment, .stackSlot, .symbol:
                // Their rendered expressions can hide another identifier.
                // Keep snapshots rather than infer dependencies from text.
                hasOpaqueRead = true
            case .register, .argument, .immediate, .temporary:
                reads.insert(value)
            }
        }
        let readNames = Set(reads.map { valueText(for: $0, names: names) })
        if !hasOpaqueRead, destinations.isDisjoint(with: reads),
           destinationNames.isDisjoint(with: readNames) { return false }
        return true
    }

    #if DEBUG
    func edgeCopyNeedsSnapshotsForTesting(destinations: Set<MacIRValue>, incoming: [MacIRValue],
                                         function: MacIRFunction) -> Bool {
        edgeCopyNeedsSnapshots(destinations: destinations, incoming: incoming,
            names: PseudocodeNameContext(function: function))
    }
    #endif

    /// Phi-bearing scalar functions use explicit labels and edge copies. A
    /// copy belongs to the selected predecessor edge, including critical
    /// conditional edges; putting it at the join would select a textual writer.
    /// This path is deliberately shared by raw and structured options until a
    /// region emitter can carry the same edge assignments into nested braces.
    private func emitPhiCFGBody(
        function: MacIRFunction, names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> BodyStructureResult {
        let hasEntry = Self.hasFunctionEntryPhi(function)
        guard !hasEntry || (function.ssaEnabled && MacIRBuilder.hasBoundedEntryLoopProof(function)
            && entryPhiNamesAreSafe(function, names: names)) else {
            appendLine("    __unavailable_cfg_phi();", kind: .instruction, to: &lines)
            return .init(regionTree: nil, structureFallback: .unstructurableCFG)
        }
        let function = Self.ssaComparisonPresentation(of: function)
        let instructions = function.instructions
        let presentationPhis = Self.presentationPhis(function)
        let cfg = function.cfg?.compatibilityCFG ?? CFGBuilder.buildCFG(instructions: instructions)
        guard !cfg.hasUnresolvedTargets, !cfg.blocks.isEmpty else {
            if hasEntry {
                appendLine("    __unavailable_cfg_phi();", kind: .instruction, to: &lines)
                return .init(regionTree: nil, structureFallback: .unstructurableCFG)
            }
            emitFlat(0..<instructions.count, depth: 0, instructions: instructions,
                      names: names, callSignaturesByTarget: function.ssaEnabled ? callSignaturesByTarget : [:], into: &lines)
            return .init(regionTree: nil, structureFallback: .unstructurableCFG)
        }
        let blockAddress: [Int: UInt64] = Dictionary(uniqueKeysWithValues: cfg.blocks.map {
            ($0.index, instructions[$0.startIndex].source.address)
        })
        let blockByAddress = Dictionary(uniqueKeysWithValues: blockAddress.map { ($0.value, $0.key) })
        let phisByBlock = Dictionary(grouping: presentationPhis, by: \.blockAddress)
        let completeEdges = cfg.blocks.allSatisfy { block in
            let operation = instructions[block.endIndex - 1].operation
            switch operation {
            case let .conditionalBranch(_, _, _, target):
                guard case let .immediate(integer) = target,
                      let taken = blockByAddress[UInt64(bitPattern: integer)] else { return false }
                return block.successors.count == 2 && block.successors.contains(taken)
            case let .intrinsic(_, name, arguments) where name == "branch":
                guard arguments.count == 1,
                      case let .immediate(integer) = arguments[0],
                      let target = blockByAddress[UInt64(bitPattern: integer)] else { return false }
                return block.successors == [target]
            case let .intrinsic(_, name, arguments)
                where function.ssaEnabled && name.hasPrefix("branch_") && name != "branch_register":
                guard let argument = arguments.first, case let .immediate(integer) = argument,
                      let taken = blockByAddress[UInt64(bitPattern: integer)] else { return false }
                return block.successors.count == 2 && block.successors.contains(taken)
            case let .switchDispatch(_, cases, defaultTarget):
                // The architectural table edge has only case successors. Its
                // retained default describes the separate bounds-check branch,
                // so it must resolve for display without becoming a phi edge.
                if function.ssaEnabled, let defaultTarget {
                    guard case let .immediate(integer) = defaultTarget,
                          blockByAddress[UInt64(bitPattern: integer)] != nil else { return false }
                }
                let targets = cases.map(\.target)
                    + (function.ssaEnabled ? [] : (defaultTarget.map { [$0] } ?? []))
                let successors = targets.compactMap { value -> Int? in
                    guard case let .immediate(integer) = value else { return nil }
                    return blockByAddress[UInt64(bitPattern: integer)]
                }
                return !cases.isEmpty && successors.count == targets.count
                    && Set(successors) == Set(block.successors)
            case .returnValue:
                return block.successors.isEmpty
            case let .call(frame, _) where NoReturnCatalog.isNoReturn(frame.target):
                return block.successors.isEmpty
            default:
                guard CFGBuilder.terminatorKind(of: operation) == .none else {
                    return false
                }
                if block.successors.count == 1 { return true }
                guard function.ssaEnabled, block.successors.isEmpty,
                      let graph = function.cfg,
                      graph.blocks.indices.contains(block.index),
                      graph.terminators.indices.contains(block.index),
                      graph.unreachable.contains(block.index),
                      graph.blocks[block.index].startAddress == instructions[block.startIndex].source.address,
                      graph.terminators[block.index] == .none else {
                    return false
                }
                let edges = graph.blocks[block.index].successors
                return edges.count == 1
                    && edges[0].from == block.index
                    && edges[0].kind == .fallthrough
                    && edges[0].to == nil
            }
        }
        let completePhis = presentationPhis.allSatisfy { phi in
            guard phi.bitWidth == 64 || phi.bitWidth == 128 || (function.ssaEnabled && phi.bitWidth == 32),
                  let blockIndex = blockByAddress[phi.blockAddress] else { return false }
            let expected = Set(cfg.blocks[blockIndex].predecessors.map {
                instructions[cfg.blocks[$0].endIndex - 1].source.address
            })
            let machineInputs = phi.incoming.compactMap(\.machineAddress)
            let entryCount = phi.incoming.filter { $0.predecessor == .functionEntry }.count
            return entryCount == (hasEntry && blockIndex == cfg.entryIndex ? 1 : 0)
                && machineInputs.count == expected.count
                && Set(machineInputs) == expected
        }
        #if DEBUG
        renderCapture?.recordGates(functionStart: function.startAddress,
            completeEdges: completeEdges, completePhis: completePhis)
        #endif
        guard completeEdges, completePhis else {
            appendLine("    __unavailable_cfg_phi();", kind: .instruction, to: &lines)
            return .init(regionTree: nil, structureFallback: .unstructurableCFG)
        }
        // Match the transfers emitted below after lexical fallthrough elision.
        // Conditional taken arms and switch cases always emit their gotos;
        // other successor edges need a label only when they are nonlexical.
        let gotoTargets: Set<Int> = cfg.blocks.enumerated().reduce(into: []) { targets, entry in
            let (position, block) = entry
            let lexicalSuccessor = position + 1 < cfg.blocks.count
                ? cfg.blocks[position + 1].index : nil
            switch instructions[block.endIndex - 1].operation {
            case let .conditionalBranch(_, _, _, target):
                if case let .immediate(integer) = target,
                   let taken = blockByAddress[UInt64(bitPattern: integer)] {
                    targets.insert(taken)
                }
            case let .switchDispatch(_, _, defaultTarget):
                targets.formUnion(block.successors)
                if function.ssaEnabled, let defaultTarget,
                   case let .immediate(integer) = defaultTarget,
                   let defaultBlock = blockByAddress[UInt64(bitPattern: integer)] {
                    targets.insert(defaultBlock)
                }
            case let .intrinsic(_, name, arguments)
                where function.ssaEnabled && name.hasPrefix("branch_") && name != "branch_register":
                if let argument = arguments.first, case let .immediate(integer) = argument,
                   let taken = blockByAddress[UInt64(bitPattern: integer)] { targets.insert(taken) }
            default:
                break
            }
            targets.formUnion(block.successors.filter { $0 != lexicalSuccessor })
        }
        func label(_ address: UInt64) -> String { "L_\(String(address, radix: 16))" }
        // 128-bit phis join whole vector registers (D06 region path).
        func phiType(_ phi: MacIRPhi) -> String {
            function.ssaEnabled
                ? Self.phiScalarType(phi, in: function)
                : (phi.bitWidth == 128 ? "__uint128_t" : "int\(phi.bitWidth)_t")
        }
        let transportTypes = function.ssaEnabled ? phiTransportSourceTypes(in: function, names: names,
            phiTypes: presentationPhis.map { ($0.destination, phiType($0)) }, inferPlainScalars: true) : [:]
        for phi in presentationPhis where !emissionLimitReached {
            appendLine("    \(phiType(phi)) \(valueText(for: phi.destination, names: names));",
                       kind: .declaration,
                       source: function.ssaEnabled ? Self.phiSource(phi, predecessor: nil) : nil, to: &lines)
        }
        var occupiedAtoms: Set<MacIRValue> = []
        if function.ssaEnabled {
            for instruction in instructions {
                RegionalBoundaryPlan.values(instruction.operation)?.forEach {
                    RegionalBoundaryPlan.collectAtoms($0, into: &occupiedAtoms)
                }
            }
            for phi in presentationPhis {
                RegionalBoundaryPlan.collectAtoms(phi.destination, into: &occupiedAtoms)
                phi.incoming.forEach { RegionalBoundaryPlan.collectAtoms($0.value, into: &occupiedAtoms) }
            }
        }
        var occupiedNames = Set(occupiedAtoms.map { valueText(for: $0, names: names) })
            .union(function.parameters.map(\.name)).union(function.localVariables.map(\.name))
            .union(function.nameBindings.map(\.name)).union(names.registerNameOverrides.values)
        func snapshotName(predecessor: Int, successor: Int, position: Int) -> String {
            guard function.ssaEnabled else { return "__edge_\(predecessor)_\(successor)_\(position)" }
            // This is the flat renderer, including a refused structured attempt.
            // Its copy identities must not depend on the requested presentation.
            var name = "__edge_\(predecessor)_\(successor)_\(position)"
            while occupiedNames.contains(name) { name += "_" }
            occupiedNames.insert(name)
            return name
        }
        func edgeCopies(from predecessor: BasicBlock, to successor: Int,
                        source: MacIRSourceSpan) {
            guard let targetAddress = blockAddress[successor] else { return }
            let predAddress = instructions[predecessor.endIndex - 1].source.address
            let assignments = (phisByBlock[targetAddress] ?? []).compactMap { phi
                -> (MacIRValue, MacIRValue, String, MacIRSourceSpan)? in
                guard let incoming = phi.incoming.first(where: {
                    $0.machineAddress == predAddress
                }) else { return nil }
                let value = function.ssaEnabled
                    ? Self.phiTransportValue(incoming.value, type: phiType(phi), sourceType: transportTypes[incoming.value]) : incoming.value
                return (phi.destination, value,
                    function.ssaEnabled ? phiType(phi) : (phi.bitWidth == 128 ? "__uint128_t" : "int64_t"),
                    function.ssaEnabled ? Self.phiSource(phi, predecessor: predAddress) : source)
            }
            // Snapshot every source before writing any destination. This is
            // essential when two phi assignments exchange live values.
            let snapshots = assignments.indices.map {
                snapshotName(predecessor: predecessor.index, successor: successor, position: $0)
            }
            for (position, assignment) in assignments.enumerated() where !emissionLimitReached {
                let qualifier = function.ssaEnabled ? "" : "const "
                appendLine("        \(qualifier)\(assignment.2) \(snapshots[position]) = \(valueText(for: assignment.1, names: names));",
                           kind: .instruction, source: assignment.3, to: &lines)
            }
            for (position, assignment) in assignments.enumerated() where !emissionLimitReached {
                appendLine("        \(valueText(for: assignment.0, names: names)) = \(snapshots[position]);",
                           kind: .instruction, source: assignment.3, to: &lines)
            }
        }
        // Initialize once before the original entry label. Backedges target
        // that label, so they never replay the function-entry assignments.
        let entryAssignments = presentationPhis.compactMap { phi -> (MacIRPhi, MacIRValue)? in
            guard let incoming = phi.incoming.first(where: { $0.predecessor == .functionEntry }) else { return nil }
            return (phi, incoming.value)
        }
        var entrySnapshots: [String] = []
        for (position, assignment) in entryAssignments.enumerated() where !emissionLimitReached {
            var snapshot = "__entry_phi_\(position)"
            while occupiedNames.contains(snapshot) { snapshot += "_" }
            occupiedNames.insert(snapshot); entrySnapshots.append(snapshot)
            appendLine("    \(phiType(assignment.0)) \(snapshot) = \(valueText(for: assignment.1, names: names));",
                kind: .instruction, source: Self.phiSource(assignment.0, edge: .functionEntry), to: &lines)
        }
        for (position, assignment) in entryAssignments.enumerated() where !emissionLimitReached {
            appendLine("    \(valueText(for: assignment.0.destination, names: names)) = \(entrySnapshots[position]);",
                kind: .instruction, source: Self.phiSource(assignment.0, edge: .functionEntry), to: &lines)
        }
        var implicitTakenCopies: [(BasicBlock, Int, MacIRSourceSpan, String)] = []
        for (position, block) in cfg.blocks.enumerated() where !emissionLimitReached {
            // Only top-level transfers may become lexical fallthrough. Keep
            // edge copies in their original order.
            // A taken-arm or switch-case goto must still skip the other edge's
            // copies, even when its destination is the next emitted block.
            let lexicalSuccessor = position + 1 < cfg.blocks.count
                ? cfg.blocks[position + 1].index : nil
            guard let address = blockAddress[block.index] else { continue }
            if gotoTargets.contains(block.index) {
                appendLine("    \(label(address)):", kind: .instruction,
                           source: function.ssaEnabled ? nil : instructions[block.startIndex].source, to: &lines)
            }
            for rowIndex in block.instructionRange where !emissionLimitReached {
                let instruction = instructions[rowIndex]
                // Use the ordinary route's source-comment normalization, without
                // adding annotations to synthetic labels or predecessor copies.
                let trimmedComment = instruction.source.comment?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let sourceComment = trimmedComment.isEmpty ? nil : Self.sanitizedComment(trimmedComment)
                let suffix = function.ssaEnabled
                    ? commentSuffix(for: instruction, callSignaturesByTarget: callSignaturesByTarget)
                    : sourceComment.map { " // \($0)" } ?? ""
                if names.redundantCompareIndices.contains(rowIndex) {
                    if let sourceComment {
                        appendLine("    // \(sourceComment)", kind: .metadata,
                                   source: instruction.source, to: &lines)
                    }
                    // A27: an elided compare that ends its block still owes the
                    // fallthrough edge's phi copies.
                    if rowIndex == block.endIndex - 1, function.ssaEnabled,
                       let successor = block.successors.first, block.successors.count == 1,
                       let nextAddress = blockAddress[successor] {
                        edgeCopies(from: block, to: successor, source: instruction.source)
                        if successor != lexicalSuccessor {
                            appendLine("    goto \(label(nextAddress));", kind: .instruction,
                                       source: instruction.source, to: &lines)
                        }
                    }
                    continue
                }
                let isTerminator = rowIndex == block.endIndex - 1
                if isTerminator,
                   case let .conditionalBranch(condition, left, right, target) = instruction.operation,
                   case let .immediate(targetInteger) = target,
                   let taken = blockByAddress[UInt64(bitPattern: targetInteger)],
                   let fallthroughBlock = block.successors.first(where: { $0 != taken }),
                   let fallthroughAddress = blockAddress[fallthroughBlock] {
                    let takenAddress = UInt64(bitPattern: targetInteger)
                    if function.ssaEnabled {
                        let needsCopies = !(phisByBlock[takenAddress] ?? []).isEmpty
                        let stub = "L_edge_\(block.index)_\(taken)"
                        let destination = needsCopies ? stub : label(takenAddress)
                        appendLine("    if (\(renderCondition(left: left, condition: condition, right: right, names: names))) goto \(destination);\(suffix)",
                                   kind: .instruction, source: instruction.source, to: &lines)
                        if needsCopies { implicitTakenCopies.append((block, taken, instruction.source, stub)) }
                    } else {
                        appendLine("    if (\(renderCondition(left: left, condition: condition, right: right, names: names))) {\(suffix)",
                                   kind: .instruction, source: instruction.source, to: &lines)
                        edgeCopies(from: block, to: taken, source: instruction.source)
                        appendLine("        goto \(label(takenAddress));",
                                   kind: .instruction, source: instruction.source, to: &lines)
                        appendLine("    }", kind: .instruction, source: instruction.source, to: &lines)
                    }
                    edgeCopies(from: block, to: fallthroughBlock, source: instruction.source)
                    if fallthroughBlock != lexicalSuccessor {
                        appendLine("    goto \(label(fallthroughAddress));", kind: .instruction,
                                   source: instruction.source, to: &lines)
                    }
                } else if isTerminator, function.ssaEnabled,
                          case let .intrinsic(destination, name, arguments) = instruction.operation,
                          name.hasPrefix("branch_"), name != "branch_register",
                          let argument = arguments.first, case let .immediate(targetInteger) = argument,
                          let taken = blockByAddress[UInt64(bitPattern: targetInteger)],
                          let fallthroughBlock = block.successors.first(where: { $0 != taken }),
                          let fallthroughAddress = blockAddress[fallthroughBlock] {
                    // Preserve the unresolved flag predicate. Only its target
                    // is relocated to an edge-copy block; no condition is inferred.
                    let stub = "L_edge_\(block.index)_\(taken)"
                    let needsCopies = !(phisByBlock[UInt64(bitPattern: targetInteger)] ?? []).isEmpty
                    var transfer = instruction
                    transfer.operation = .intrinsic(destination: destination, name: name,
                        arguments: [.symbol(needsCopies ? stub : label(UInt64(bitPattern: targetInteger)))]
                            + arguments.dropFirst())
                    appendLine("    \(render(instruction: transfer, names: names));\(suffix)",
                        kind: .instruction, source: instruction.source, to: &lines)
                    edgeCopies(from: block, to: fallthroughBlock, source: instruction.source)
                    if fallthroughBlock != lexicalSuccessor {
                        appendLine("    goto \(label(fallthroughAddress));", kind: .instruction,
                            source: instruction.source, to: &lines)
                    }
                    if needsCopies { implicitTakenCopies.append((block, taken, instruction.source, stub)) }
                } else if isTerminator,
                          case let .switchDispatch(index, cases, defaultTarget) = instruction.operation {
                    appendLine("    switch (\(valueText(for: index, names: names))) {\(suffix)",
                               kind: .instruction, source: instruction.source, to: &lines)
                    func emitCase(_ heading: String, target: MacIRValue) {
                        guard case let .immediate(integer) = target,
                              let successor = blockByAddress[UInt64(bitPattern: integer)] else { return }
                        appendLine("    \(heading): {", kind: .instruction, source: instruction.source, to: &lines)
                        if !function.ssaEnabled || block.successors.contains(successor) {
                            edgeCopies(from: block, to: successor, source: instruction.source)
                        }
                        appendLine("        goto \(label(UInt64(bitPattern: integer)));",
                                   kind: .instruction, source: instruction.source, to: &lines)
                        appendLine("    }", kind: .instruction, source: instruction.source, to: &lines)
                    }
                    for item in cases { emitCase("case \(item.value)", target: item.target) }
                    if let defaultTarget { emitCase("default", target: defaultTarget) }
                    appendLine("    }", kind: .instruction, source: instruction.source, to: &lines)
                } else if isTerminator,
                          case let .intrinsic(_, name, arguments) = instruction.operation,
                          name == "branch", arguments.count == 1,
                          case let .immediate(targetInteger) = arguments[0],
                          let successor = blockByAddress[UInt64(bitPattern: targetInteger)] {
                    edgeCopies(from: block, to: successor, source: instruction.source)
                    if successor != lexicalSuccessor {
                        appendLine("    goto \(label(UInt64(bitPattern: targetInteger)));\(suffix)",
                                   kind: .instruction, source: instruction.source, to: &lines)
                    } else if let sourceComment {
                        // The transfer is lexical fallthrough, but its evidence
                        // still has a row with the original instruction's source.
                        appendLine("    // \(sourceComment)", kind: .metadata,
                                   source: instruction.source, to: &lines)
                    }
                } else {
                    appendLine("    \(render(instruction: instruction, names: names));\(suffix)",
                               kind: .instruction, source: instruction.source, to: &lines)
                    if isTerminator, case .returnValue = instruction.operation {
                        continue
                    }
                    if isTerminator, let successor = block.successors.first,
                       let nextAddress = blockAddress[successor] {
                        edgeCopies(from: block, to: successor, source: instruction.source)
                        if successor != lexicalSuccessor {
                            appendLine("    goto \(label(nextAddress));", kind: .instruction,
                                       source: instruction.source, to: &lines)
                        }
                    }
                }
            }
        }
        for (predecessor, successor, source, stub) in implicitTakenCopies where !emissionLimitReached {
            guard let target = blockAddress[successor], let phi = phisByBlock[target]?.first else { continue }
            let synthetic = Self.phiSource(phi, predecessor: source.address)
            appendLine("    \(stub):", kind: .instruction, source: synthetic, to: &lines)
            edgeCopies(from: predecessor, to: successor, source: source)
            appendLine("    goto \(label(target));", kind: .instruction, source: synthetic, to: &lines)
        }
        return .init(regionTree: nil, structureFallback: nil)
    }

    func print(
        function: MacIRFunction,
        forcedRegionForTesting region: Region,
        types: [TypeDefinition] = [],
        nameOverrides: [String: String] = [:],
        registerNameOverrides: [String: String] = [:]
    ) -> PseudocodeDocument {
        var lines: [PseudocodeLine] = []
        for definition in MacIRSignedBitfield.helperDefinitions(in: function) {
            for line in definition.components(separatedBy: "\n") {
                appendLine(line, kind: .metadata, to: &lines)
            }
        }
        var nameContext = PseudocodeNameContext(
            function: function,
            types: types,
            callTargetRenames: nameOverrides,
            registerNameOverrides: registerNameOverrides
        )
        nameContext.redundantCompareIndices = redundantCompareIndices(function: function, names: nameContext)
        let callSignaturesByTarget = Dictionary(uniqueKeysWithValues: function.callSignatures.map { ($0.target, $0) })
        let noReturnQualifier = function.isNoReturn ? "noreturn " : ""
        appendLine("\(noReturnQualifier)\(function.returnType) \(function.name)(\(parameterList(for: function))) {", kind: .signature, to: &lines)
        appendLine(functionMetadataLine(for: function, names: nameContext), kind: .metadata, to: &lines)
        for localVariable in function.localVariables {
            appendLine(
                "    \(localVariable.type) \(localVariable.name);",
                kind: .declaration,
                to: &lines
            )
        }

        let bodyStructure = emitBody(
            function: function,
            forcedRegionForTesting: region,
            depth: 0,
            instructions: function.instructions,
            names: nameContext,
            callSignaturesByTarget: callSignaturesByTarget,
            into: &lines
        )

        appendRefusals(function: function, to: &lines)
        appendLine("}", kind: .closingBrace, to: &lines)
        return PseudocodeDocument(
            functionName: function.name,
            entryAddress: function.startAddress,
            returnType: function.returnType,
            parameters: function.parameters,
            localVariables: function.localVariables,
            nameBindings: function.nameBindings,
            stackFrameSize: function.stackFrameSize,
            callTargets: function.callTargets,
            callSignatures: function.callSignatures,
            lines: lines,
            regionTree: bodyStructure.regionTree,
            structureFallback: bodyStructure.structureFallback
        )
    }

    /// Indentation prefix for a given nesting depth. depth 0 => 4 spaces
    /// (today's top level), depth 1 => 8 spaces (today's bodies), depth 2 => 12
    /// spaces (new nesting), and so on. Reproduces the previous hard-coded
    /// spacing exactly by construction.
    private func indent(_ depth: Int) -> String {
        String(repeating: " ", count: (depth + 1) * 4)
    }

    /// Containment until dead-code elimination is based on CFG reachability.
    /// A later textual instruction may have an incoming edge from before a return.
    /// Opaque operations and explicit return targets cannot prove linear control flow.
    static func linearDeadCodeEliminationIsSafe(_ instructions: [MacIRInstruction]) -> Bool {
        instructions.allSatisfy { instruction in
            guard instruction.returnTarget == nil else { return false }
            if case .unknown = instruction.operation { return false }
            switch CFGBuilder.terminatorKind(of: instruction.operation) {
            case .none, .returnTerminator:
                return true
            default:
                return false
            }
        }
    }

    /// Recursively structures the half-open instruction range `range` at the
    /// given nesting `depth`, appending rendered lines to `lines`. Applies the
    /// same matcher order as the previous flat loop, but emits each construct's
    /// body by recursing at `depth + 1` instead of an inline 8-space loop, and
    /// bounds every match to stay within `range`. Recursion is total: each
    /// recursive call is on a strictly smaller sub-range.
    /// Minimal address-ordered fallback; statements share the region row emitter.
    private func emitFlat(
        _ range: Range<Int>, depth: Int, instructions: [MacIRInstruction],
        names: PseudocodeNameContext, callSignaturesByTarget: [String: MacIRCallSignature],
        continuationLabelAddresses: Set<UInt64> = [],
        into lines: inout [PseudocodeLine]
    ) {
        if options.deadCodeElimination, Self.linearDeadCodeEliminationIsSafe(instructions) {
            emitRows(range, depth: depth, instructions: instructions, names: names,
                     callSignaturesByTarget: callSignaturesByTarget, into: &lines)
            return
        }
        let addresses = Set(range.map { instructions[$0].source.address })
        let targets = Self.flatLabelTargets(instructions)
        func transfer(_ value: MacIRValue) -> String {
            if let address = CFGBuilder.address(of: value),
               addresses.contains(address) || continuationLabelAddresses.contains(address) {
                return "goto \(gotoLeafLabelText(address, names: names))"
            }
            return branchTransferText(value, names: names)
        }
        // Synthetic edge copies are scheduled before their transfer even
        // though their source addresses lie beyond the architectural rows.
        let ordered = range.contains { instructions[$0].source.syntheticPhiEdge != nil }
            ? Array(range) : range.sorted { instructions[$0].source.address < instructions[$1].source.address }
        var offset = 0
        while offset < ordered.count, !emissionLimitReached {
            emissionCancellation?.step()
            let index = ordered[offset], instruction = instructions[index]
            if targets.contains(instruction.source.address) {
                appendLine("\(indent(depth))\(gotoLeafLabelText(instruction.source.address, names: names)):",
                           kind: .instruction, to: &lines)
            }
            let suffix = commentSuffix(for: instruction, callSignaturesByTarget: callSignaturesByTarget)
            switch instruction.operation {
            case let .conditionalBranch(condition, left, right, target):
                appendLine("\(indent(depth))if (\(renderCondition(left: left, condition: condition, right: right, names: names))) \(transfer(target));\(suffix)",
                           kind: .instruction, source: instruction.source, to: &lines)
            case let .intrinsic(_, name, arguments) where name == "branch" && arguments.count == 1:
                // A projected transfer is synthetic control, not a phi copy
                // assignment or an additional statement owned by the old row.
                appendLine("\(indent(depth))\(transfer(arguments[0]));\(suffix)",
                           kind: .instruction,
                           source: instruction.source.syntheticPhiEdge == nil ? instruction.source : nil,
                           to: &lines)
            case let .switchDispatch(value, cases, defaultTarget):
                appendLine("\(indent(depth))switch (\(valueText(for: value, names: names))) {\(suffix)",
                           kind: .instruction, source: instruction.source, to: &lines)
                for item in cases where !emissionLimitReached {
                    appendLine("\(indent(depth + 1))case \(MacIRValue.immediate(item.value)): \(transfer(item.target));",
                               kind: .instruction, source: instruction.source, to: &lines)
                }
                let exit = defaultTarget.map { "\(transfer($0));" } ?? "break;"
                appendLine("\(indent(depth + 1))default: \(exit)", kind: .instruction, source: instruction.source, to: &lines)
                appendLine("\(indent(depth))}", kind: .instruction, to: &lines)
            default:
                var end = offset + 1
                while end < ordered.count, ordered[end] == ordered[end - 1] + 1,
                      !targets.contains(instructions[ordered[end]].source.address) {
                    if case .none = CFGBuilder.terminatorKind(of: instructions[ordered[end - 1]].operation),
                       case .none = CFGBuilder.terminatorKind(of: instructions[ordered[end]].operation) {
                        end += 1
                    } else { break }
                }
                // Include a terminal return so the shared returned-call fold survives.
                if end < ordered.count, ordered[end] == ordered[end - 1] + 1,
                   !targets.contains(instructions[ordered[end]].source.address),
                   case .returnValue = instructions[ordered[end]].operation {
                    end += 1
                }
                emitRows(index..<(ordered[end - 1] + 1), depth: depth, instructions: instructions,
                         names: names, callSignaturesByTarget: callSignaturesByTarget, into: &lines)
                offset = end
                continue
            }
            offset += 1
        }
    }

    private func emitRows(
        _ range: Range<Int>,
        depth: Int,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        ordinaryContext: RegionalOrdinaryEmissionContext? = nil,
        scalarContext: DecodedScalarNativeEmissionContext? = nil,
        into lines: inout [PseudocodeLine]
    ) {
        guard !emissionLimitReached else { return }
        guard ordinaryContext == nil || scalarContext == nil else {
            ordinaryContext?.failed = true; scalarContext?.failed = true; return
        }
        if let scalarContext {
            guard range.lowerBound >= 0, range.upperBound <= scalarContext.values.groups.count else {
                scalarContext.failed = true; return
            }
            for row in range {
                guard !emissionLimitReached, scalarContext.own(row) else { return }
                let original = instructions[row]
                for (ordinal, item) in scalarContext.values.groups[row].enumerated() {
                    switch item {
                    case let .instruction(prepared):
                        guard prepared.source == original.source else { scalarContext.failed = true; return }
                        let suffix = ordinal == 0
                            ? commentSuffix(for: original, callSignaturesByTarget: callSignaturesByTarget) : ""
                        appendLine("\(indent(depth))\(render(instruction: prepared, names: names));\(suffix)",
                                   kind: .instruction, source: prepared.source, to: &lines)
                    case let .protectedOriginal(expectedRow):
                        guard expectedRow == row, let retained = scalarContext.originals[row],
                              scalarContext.originalLineIndices[row] == nil else {
                            scalarContext.failed = true; return
                        }
                        scalarContext.originalLineIndices[row] = lines.count
                        appendLine(retained.text, kind: retained.kind, source: retained.source, to: &lines)
                    }
                }
            }
            return
        }
        if let ordinaryContext {
            guard range.lowerBound >= 0, range.upperBound <= ordinaryContext.values.groups.count else {
                ordinaryContext.failed = true; return
            }
            for row in range {
                guard !emissionLimitReached, ordinaryContext.own(row) else { return }
                let original = instructions[row]
                let hasProtectedOriginal = ordinaryContext.values.groups[row].contains {
                    if case .protectedOriginal = $0 { return true }; return false
                }
                for (ordinal, item) in ordinaryContext.values.groups[row].enumerated() {
                    switch item {
                    case let .instruction(prepared):
                        guard prepared.source == original.source else { ordinaryContext.failed = true; return }
                        // The same native scalar/memory renderer owns all cast,
                        // operator and value naming. The overlay owns no text.
                        let suffix = ordinal == 0 && !hasProtectedOriginal
                            ? commentSuffix(for: original, callSignaturesByTarget: callSignaturesByTarget) : ""
                        appendLine("\(indent(depth))\(render(instruction: prepared, names: names));\(suffix)",
                                   kind: .instruction, source: prepared.source, to: &lines)
                    case let .protectedOriginal(expectedRow):
                        guard expectedRow == row, let retained = ordinaryContext.originals[row],
                              ordinaryContext.originalLineIndices[row] == nil else {
                            ordinaryContext.failed = true; return
                        }
                        ordinaryContext.originalLineIndices[row] = lines.count
                        let text = ordinaryContext.callRows.contains(row)
                            ? indent(depth) + String(retained.text.drop(while: { $0 == " " })) : retained.text
                        appendLine(text, kind: retained.kind, source: retained.source, to: &lines)
                    }
                }
            }
            return
        }
        let prefix = indent(depth)
        var instructionIndex = range.lowerBound
        // Elide a tail only when the entire instruction stream proves linear.
        // A later row may otherwise be reached by a branch before this return.
        let mayElideAfterReturn = options.deadCodeElimination
            && Self.linearDeadCodeEliminationIsSafe(instructions)
        var sawReturn = false
        while instructionIndex < range.upperBound, !emissionLimitReached {
            emissionCancellation?.step()
            let current = instructions[instructionIndex]

            // NOP elision: `nop` carries no semantics — drop the `__nop()` line.
            if options.nopElision, isNopIntrinsic(current.operation) {
                instructionIndex += 1
                continue
            }

            // Each structured body uses a fresh sawReturn. The whole-stream
            // guard above excludes branches, opaque operations and return targets.
            if mayElideAfterReturn, sawReturn {
                instructionIndex += 1
                continue
            }
            if case .returnValue = current.operation {
                sawReturn = true
            }

            if case let .switchDispatch(index, cases, defaultTarget) = current.operation {
                appendLine(
                    "\(prefix)switch (\(valueText(for: index, names: names))) {\(commentSuffix(for: current, callSignaturesByTarget: callSignaturesByTarget))",
                    kind: .instruction,
                    source: current.source,
                    to: &lines
                )
                let caseIndent = indent(depth + 1)
                for switchCase in cases where !emissionLimitReached {
                    appendLine(
                        "\(caseIndent)case \(MacIRValue.immediate(switchCase.value)): \(branchTransferText(switchCase.target, names: names));",
                        kind: .instruction,
                        source: current.source,
                        to: &lines
                    )
                }
                let defaultText = defaultTarget.map { "\(branchTransferText($0, names: names));" } ?? "break;"
                appendLine("\(caseIndent)default: \(defaultText)", kind: .instruction, source: current.source, to: &lines)
                appendLine("\(prefix)}", kind: .instruction, to: &lines)
                instructionIndex += 1
                continue
            }

            if instructionIndex + 2 <= range.upperBound,
               let returnedCall = returnedCall(
                startingAt: instructionIndex,
                instructions: instructions
            ) {
                let callText = renderCall(
                    frame: returnedCall.frame,
                    names: names,
                    address: returnedCall.instruction.source.address
                )
                let suffix = commentSuffix(
                    for: returnedCall.instruction,
                    callSignaturesByTarget: callSignaturesByTarget,
                    extraAnnotations: ["return"]
                )
                appendLine(
                    "\(prefix)return \(callText);\(suffix)",
                    kind: .instruction,
                    source: returnedCall.instruction.source,
                    to: &lines
                )
                instructionIndex += 2
                continue
            }

            if instructionIndex + 2 <= range.upperBound,
               let foldedCompareToBool = foldedCompareToBool(
                startingAt: instructionIndex,
                instructions: instructions
            ) {
                appendLine(
                    "\(prefix)\(render(instruction: foldedCompareToBool.instruction, names: names));\(commentSuffix(for: foldedCompareToBool.instruction, callSignaturesByTarget: callSignaturesByTarget))",
                    kind: .instruction,
                    source: foldedCompareToBool.instruction.source,
                    to: &lines
                )
                instructionIndex += 2
                continue
            }

            if instructionIndex + 2 <= range.upperBound,
               let foldedGlobalAddress = foldedGlobalAddress(
                startingAt: instructionIndex,
                instructions: instructions,
                names: names
            ) {
                appendLine(
                    "\(prefix)\(foldedGlobalAddress.destinationText) = &\(foldedGlobalAddress.symbolName);\(commentSuffix(for: foldedGlobalAddress.instruction, callSignaturesByTarget: callSignaturesByTarget, extraAnnotations: ["global address"]))",
                    kind: .instruction,
                    source: foldedGlobalAddress.instruction.source,
                    to: &lines
                )
                instructionIndex += 2
                continue
            }

            if names.redundantCompareIndices.contains(instructionIndex) {
                instructionIndex += 1
                continue
            }
            let instruction = instructions[instructionIndex]
            appendLine(
                "\(prefix)\(render(instruction: instruction, names: names));\(commentSuffix(for: instruction, callSignaturesByTarget: callSignaturesByTarget))",
                kind: .instruction,
                source: instruction.source,
                to: &lines
            )
            instructionIndex += 1
        }
    }

    /// Choose a region plan from CFG facts, otherwise emit a flat body.
    /// No competing rendering or output-quality score participates in selection.
    private func emitBody(
        function: MacIRFunction,
        depth: Int,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> BodyStructureResult {
        // Bounded output goes directly to the linear path so its fence stops work.
        if boundedEmissionState != nil {
            emitFlat(
                0..<instructions.count,
                depth: depth,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                into: &lines
            )
            return BodyStructureResult(regionTree: nil, structureFallback: .gotoForm)
        }

        // Explicit goto-form output skips region analysis.
        guard options.structureControlFlow else {
            emitFlat(
                0..<instructions.count,
                depth: depth,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                into: &lines
            )
            return BodyStructureResult(regionTree: nil, structureFallback: .gotoForm)
        }

        // Large functions use the flat emitter without region analysis.
        guard instructions.count <= options.functionSizeGate else {
            emitFlat(
                0..<instructions.count,
                depth: depth,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                into: &lines
            )
            return BodyStructureResult(regionTree: nil, structureFallback: .sizeGate)
        }

        let cfg = function.cfg?.compatibilityCFG ?? CFGBuilder.buildCFG(instructions: instructions)
        let regionBuild = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: instructions,
            allowRejoiningContinuationGotos: function.ssaEnabled)
        guard let region = regionBuild.region else {
            RegionTree.emitDiagnosticsIfEnabled(
                functionName: function.name,
                fallback: PseudocodeStructureFallback.unstructurableCFG.rawValue,
                diagnostics: regionBuild.diagnostics
            )
            emitFlat(
                0..<instructions.count,
                depth: depth,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                into: &lines
            )
            return BodyStructureResult(regionTree: nil, structureFallback: .unstructurableCFG)
        }

        // Instructions to suppress: block-terminating unconditional branches
        // whose targets stay inside the function. Those are structural jumps
        // (fall-through, loop back-edge, or join). An out-of-function direct
        // branch is a visible tail-call exit and must render through the shared
        // row emitter with its source metadata intact.
        let functionRange = CFGBuilder.functionAddressRange(instructions: instructions)
        let projectedTargets: Set<UInt64> = function.ssaEnabled
            ? Set(instructions.filter { $0.source.syntheticPhiEdge != nil }.map { $0.source.address }) : []
        var suppressedInstructions: Set<Int> = []
        for block in cfg.blocks {
            let terminatorIndex = block.endIndex - 1
            guard terminatorIndex >= block.startIndex else { continue }
            if case let .unconditionalBranch(target) = CFGBuilder.terminatorKind(of: instructions[terminatorIndex].operation),
               let target,
               functionRange?.contains(target) == true || projectedTargets.contains(target) {
                suppressedInstructions.insert(terminatorIndex)
            }
        }

        // Render into a scratch buffer; if any region cannot be faithfully
        // emitted, abort and fall back to the flat emitter for the whole
        // function so output is never partially-structured/wrong.
        var scratch: [PseudocodeLine] = lines
        var gotoLeafDiagnostics = GotoLeafEmissionDiagnostics(enabled: Self.gotoLeafDiagnosticsEnabled)
        var continuationGotoContext = ContinuationGotoEmissionContext()
        let regionResult = emitRegion(
            region,
            depth: depth,
            cfg: cfg,
            instructions: instructions,
            names: namesWithGotoLeafLabels(names, region: region, cfg: cfg, instructions: instructions),
            callSignaturesByTarget: callSignaturesByTarget,
            suppressedInstructions: suppressedInstructions,
            loopContext: nil,
            continuationGotoContext: &continuationGotoContext,
            gotoLeafDiagnostics: &gotoLeafDiagnostics,
            into: &scratch
        )
        if regionResult.supported,
           regionResult.emittedBlocks == Set(cfg.blocks.indices),
           continuationGotoContext.emittedExactlyOnceAtStatementBoundaries,
           let regionNode = regionResult.node {
            if regionResult.containsGotoLeaf || continuationGotoContext.hasTargets {
                gotoLeafDiagnostics.record(.emitted, count: regionResult.gotoLeafCount)
            }
            emitGotoLeafDiagnosticsIfEnabled(functionName: function.name, diagnostics: gotoLeafDiagnostics)
            RegionTree.emitDiagnosticsIfEnabled(
                functionName: function.name,
                fallback: nil,
                diagnostics: regionBuild.diagnostics
            )
            if let local = tstASRStatementLocals(function: function, region: region, cfg: cfg,
                instructions: instructions, names: names, callSignaturesByTarget: callSignaturesByTarget,
                lines: scratch, node: regionNode) {
                lines = local.lines
                return BodyStructureResult(regionTree: local.node, structureFallback: nil)
            }
            lines = scratch
            return BodyStructureResult(regionTree: regionNode, structureFallback: nil)
        } else {
            // Preserve every formerly accepted rendering. Only a vetoed
            // function can enter the separately proof-checked recovery grammar.
            if let recovered = emitRecovery(
                cfg: cfg, depth: depth, instructions: instructions, names: names,
                callSignaturesByTarget: callSignaturesByTarget, into: &lines
            ) {
                return BodyStructureResult(regionTree: recovered, structureFallback: nil)
            }
            if let carried = emitEntryLoopFallback(
                function: function, cfg: cfg, depth: depth, names: names,
                callSignaturesByTarget: callSignaturesByTarget, into: &lines
            ) {
                return BodyStructureResult(regionTree: carried, structureFallback: nil)
            }
            // Keep a proven acyclic prefix without reinterpreting the terminal
            // unsupported interval. This is supplementary: every previously
            // accepted normal or opt-in recovery rendering keeps precedence.
            if let plan = RegionTree.buildTerminalSuffixFallback(cfg: cfg, instructions: instructions) {
                    var localized = lines
                    var localizedDiagnostics = GotoLeafEmissionDiagnostics(enabled: Self.gotoLeafDiagnosticsEnabled)
                    var localizedContinuation = ContinuationGotoEmissionContext()
                    let result = emitRegion(
                        plan.region, depth: depth, cfg: cfg, instructions: instructions,
                        names: namesWithGotoLeafLabels(names, region: plan.region, cfg: cfg, instructions: instructions),
                        callSignaturesByTarget: callSignaturesByTarget,
                        suppressedInstructions: suppressedInstructions, loopContext: nil,
                        continuationGotoContext: &localizedContinuation,
                        gotoLeafDiagnostics: &localizedDiagnostics, into: &localized
                    )
                    if result.supported, let node = result.node,
                       result.emittedBlocks == Set(cfg.blocks.indices), result.gotoLeafCount == 1,
                       !localizedContinuation.hasTargets {
                        localizedDiagnostics.record(.emitted, count: 1)
                        emitGotoLeafDiagnosticsIfEnabled(functionName: function.name, diagnostics: localizedDiagnostics)
                        RegionTree.emitDiagnosticsIfEnabled(functionName: function.name, fallback: nil,
                                                            diagnostics: regionBuild.diagnostics)
                        lines = localized
                        return BodyStructureResult(regionTree: node, structureFallback: nil)
                    }
            }
            if let certified = emitDecodedScalarFallback(
                function: function, cfg: cfg, depth: depth, names: names,
                callSignaturesByTarget: callSignaturesByTarget, into: &lines
            ) {
                return BodyStructureResult(regionTree: certified, structureFallback: nil)
            }
            if let certified = emitRegionalPhysicalFallback(
                function: function, cfg: cfg, depth: depth, names: names,
                callSignaturesByTarget: callSignaturesByTarget, into: &lines
            ) {
                return BodyStructureResult(regionTree: certified, structureFallback: nil)
            }
            emitGotoLeafDiagnosticsIfEnabled(functionName: function.name, diagnostics: gotoLeafDiagnostics)
            var diagnostics = regionBuild.diagnostics
            diagnostics.recordFatal(.emitterUnsupportedRegion)
            RegionTree.emitDiagnosticsIfEnabled(
                functionName: function.name,
                fallback: PseudocodeStructureFallback.unsupportedRegion.rawValue,
                diagnostics: diagnostics
            )
            emitFlat(
                0..<instructions.count,
                depth: depth,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                into: &lines
            )
            return BodyStructureResult(regionTree: nil, structureFallback: .unsupportedRegion)
        }
    }

    /// Current decoded scalar cells may cross an opaque event only through the
    /// certified role ledger. The event itself must retain its old printed form.
    private func emitRegionalPhysicalFallback(
        function: MacIRFunction, cfg: CFG, depth: Int, names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        guard boundedEmissionState == nil else { return nil }
        if let proof = lexicalProof(for: function) {
            var candidate = lines
            if let node = emitRegionalPhysicalFallbackCandidate(function: proof.function, cfg: cfg, depth: depth,
                names: lexicalNames(for: proof, preserving: names),
                callSignaturesByTarget: callSignaturesByTarget, lexicalProof: proof, into: &candidate) {
                lines = candidate
                return node
            }
        }
        return emitRegionalPhysicalFallbackCandidate(function: function, cfg: cfg, depth: depth, names: names,
            callSignaturesByTarget: callSignaturesByTarget, lexicalProof: nil, into: &lines)
    }

    private func emitRegionalPhysicalFallbackCandidate(
        function: MacIRFunction, cfg: CFG, depth: Int, names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        lexicalProof: RegionalLexicalProof?, into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        guard boundedEmissionState == nil else { return nil }
        guard let state = RegionalPhysicalStatePlan.prove(function: function, cfg: cfg, lexicalProof: lexicalProof,
                attemptLexical: false),
              let values = RegionalOrdinaryValuePlan.prove(function: function, cfg: cfg, certifiedBy: state,
                lexicalProof: lexicalProof),
              let control = RegionalOrdinaryControlPlan.prove(
                function: function, cfg: cfg, certifiedBy: state, values: values) else { return nil }
        let forbidden: Set<String> = [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
            "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
            "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
            "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
            "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary",
            "_Noreturn", "_Static_assert", "_Thread_local", "alignas", "alignof", "bool",
            "constexpr", "false", "nullptr", "static_assert", "thread_local", "true", "typeof",
            "typeof_unqual", "_BitInt", "int8_t", "int16_t", "int32_t", "int64_t",
            "uint8_t", "uint16_t", "uint32_t", "uint64_t"
        ]
        func valid(_ name: String) -> Bool {
            !forbidden.contains(name)
                && name.range(of: #"\A[A-Za-z_][A-Za-z_0-9]*\z"#, options: .regularExpression) != nil
        }
        var owners: [String: MacIRValue] = [:]
        var formals: Set<String> = []
        for parameter in function.parameters {
            guard let binding = parameter.bindingID else { return nil }
            let value = MacIRValue.argument(bindingID: binding)
            let text = valueText(for: value, names: names)
            guard text == parameter.name, valid(text), owners[text] == nil else { return nil }
            owners[text] = value
            formals.insert(text)
        }
        for value in values.namedValues {
            let text = valueText(for: value, names: names)
            guard valid(text), owners[text] == nil || owners[text] == value else { return nil }
            owners[text] = value
        }
        let reserved = Set(names.argumentNames.values)
            .union(names.localsByOffset.values.map(\.name)).union(names.registerNamesByValue.values)
        guard Set(values.declarations.map(\.storage)).count == values.declarations.count,
              values.declarations.allSatisfy({ declaration in
                  let text = valueText(for: declaration.storage, names: names)
                  guard ["uint64_t", "uint32_t", "int64_t", "int32_t"].contains(declaration.type),
                        valid(text), !formals.contains(text) else { return false }
                  if state.boundaries.aliasValues.contains(declaration.storage) { return true }
                  if case .register = declaration.storage { return owners[text] == declaration.storage }
                  return text == declaration.storage.description && !reserved.contains(text)
              }) else { return nil }

        var statementCache: [Int: [PseudocodeLine]] = [:]
        func originalLines(at row: Int) -> [PseudocodeLine] {
            guard let block = blockContaining(instructionIndex: row, cfg: cfg) else { return [] }
            if statementCache[block] == nil {
                var statements: [PseudocodeLine] = []
                emitRows(cfg.blocks[block].instructionRange, depth: depth, instructions: function.instructions,
                         names: names, callSignaturesByTarget: callSignaturesByTarget, into: &statements)
                statementCache[block] = statements
            }
            return statementCache[block, default: []].filter { $0.source == function.instructions[row].source }
        }
        func payload(_ text: String) -> String { String(text.drop(while: { $0 == " " })) }
        guard state.permitsPrintedResultUses(readWitness: { row, value in
            guard function.instructions.indices.contains(row) else { return false }
            let source = function.instructions[row].source
            let candidates = originalLines(at: row).filter { $0.kind == .instruction }
            guard candidates.count == 1, let line = candidates.first else { return false }
            guard let value else {
                // A certified original conditional-branch endpoint must itself
                // survive in the old body; metadata or a lost source is not use.
                if case .conditionalBranch = function.instructions[row].operation { return true }
                return false
            }
            let name = valueText(for: value, names: names)
            return line.tokens.contains { token in
                token.kind == .identifier && token.text == name && token.sourceAddress == source.address
            }
        }, sourceWitness: { row in
            guard function.instructions.indices.contains(row) else { return false }
            // The independent edge certificate names only original CSEL/store
            // rows. A declaration or a call-result LHS cannot satisfy it.
            switch function.instructions[row].operation {
            case .store, .unknown(_, _, "csel", _): break
            default: return false
            }
            return originalLines(at: row).filter { $0.kind == .instruction }.count == 1
        }) else { return nil }
        var originals: [Int: PseudocodeLine] = [:]
        for row in state.boundaries.originalRows {
            guard function.instructions.indices.contains(row) else { return nil }
            let instruction = function.instructions[row]
            let candidates = originalLines(at: row)
            let expected = render(instruction: instruction, names: names) + ";"
                + commentSuffix(for: instruction, callSignaturesByTarget: callSignaturesByTarget)
            // An absorbed/rewritten old call or an unavailable printed result is
            // not a reusable event. There is no fresh-render fallback here.
            guard candidates.count == 1, let original = candidates.first,
                  original.kind == .instruction, payload(original.text) == expected else { return nil }
            originals[row] = original
        }
        var retainedIdentifiers: Set<String> = []
        var retainedCallables: Set<String> = []
        for call in state.boundaries.calls.values {
            let display: String?
            if call.original.source.mnemonic == "bl" {
                display = names.callTargetRenames[call.frame.target] ?? call.frame.target
            } else {
                display = names.resolvedIndirectCalls[call.original.source.address]?.name
            }
            if let display {
                retainedCallables.formUnion(tokenize(display, lineNumber: 0, sourceAddress: nil)
                    .filter { $0.kind == .identifier || $0.kind == .intrinsic }.map(\.text))
            }
        }
        for original in originals.values {
            let tokens = original.tokens.filter { $0.kind != .comment }
            for (index, token) in tokens.enumerated() where token.kind == .identifier || token.kind == .intrinsic {
                retainedIdentifiers.insert(token.text)
                if index + 1 < tokens.count, tokens[index + 1].text == "(" {
                    retainedCallables.insert(token.text)
                }
            }
        }
        // Exact text is insufficient if a fresh declaration shadows a callee
        // or retained helper. Preserve identifier binding as well as spelling.
        guard values.declarations.allSatisfy({ declaration in
            let text = valueText(for: declaration.storage, names: names)
            return !retainedCallables.contains(text)
                && (state.boundaries.aliasValues.contains(declaration.storage)
                    || !retainedIdentifiers.contains(text))
        }) else { return nil }
        var nativeNames = names
        nativeNames.valueTypes.merge(values.valueTypes) { _, certified in certified }
        // The declaration certificate describes integer dereferences, not
        // context-dependent struct fields or stack-local sugar. Refuse that
        // distinct rendering rather than infer its type from an IR carrier.
        for group in values.groups {
            for item in group {
                guard case let .instruction(instruction) = item,
                      case let .load(_, address) = instruction.operation else { continue }
                if case .stackSlot = address { return nil }
                guard structFieldAccess(for: address, names: nativeNames) == nil else { return nil }
                if case let .load(carrier, _) = instruction.operation,
                   let access = instruction.memoryAccess ?? recordNaturalAccess(carrier, names: nativeNames),
                   recordFieldMemoryText(address: address, carrier: carrier, access: access,
                       isStore: false, names: nativeNames) != nil { return nil }
                let memberTarget: (MacIRValue, Int)?
                if case let .binaryExpression(op, base, .immediate(offset)) = address,
                   op == "+", offset == 0 { memberTarget = (base, 0) }
                else { memberTarget = PseudocodeNameContext.dereferenceTarget(address) }
                if let (base, offset) = memberTarget,
                   let access = instruction.memoryAccess,
                   nativeNames.structFieldName(forBase: base, offset: offset, access: access,
                       floating: false, isStore: false) != nil { return nil }
            }
        }
        let context = RegionalOrdinaryEmissionContext(function: function, cfg: cfg, values: values,
            control: control, originals: originals, callRows: state.boundaries.callRows)
        var scratch = lines
        // Function-scope native declarations avoid jumping into initialized
        // scopes. Every name has a source/join/boundary/cycle certificate; this
        // is not one mutable printed cell per physical register.
        // Keep the complete internal type/name certificate. Only exact-type
        // single-static-definition SSA values can use the existing native
        // assignment convention without an additional printed declaration.
        guard values.declarations.allSatisfy({ $0.initializer == nil }),
              values.printedDeclarationValues.isSubset(of: Set(values.declarations.map(\.storage))) else { return nil }
        let printedDeclarations = values.declarations.filter { values.printedDeclarationValues.contains($0.storage) }
        let persistedDeclarations = function.ssaEnabled
            ? printedDeclarations.filter { declaration in function.phis.contains { $0.destination == declaration.storage } }
            : []
        for declaration in persistedDeclarations {
            guard let phi = function.phis.first(where: { $0.destination == declaration.storage }) else { return nil }
            appendLine("\(indent(depth))\(declaration.type) \(valueText(for: declaration.storage, names: nativeNames));",
                kind: .declaration, source: Self.phiSource(phi, predecessor: nil), to: &scratch)
        }
        let persistedValues = Set(persistedDeclarations.map(\.storage))
        let ordinaryDeclarations = printedDeclarations.filter { !persistedValues.contains($0.storage) }
        let types = Set(ordinaryDeclarations.map(\.type)).sorted()
        for type in types {
            let declarations = ordinaryDeclarations.filter { $0.type == type }
            for start in stride(from: 0, to: declarations.count, by: 6) {
                let chunk = declarations[start..<min(start + 6, declarations.count)]
                    .map { valueText(for: $0.storage, names: nativeNames) }.joined(separator: ", ")
                appendLine("\(indent(depth))\(type) \(chunk);", kind: .declaration, to: &scratch)
            }
        }
        var diagnostics = GotoLeafEmissionDiagnostics(enabled: Self.gotoLeafDiagnosticsEnabled)
        var continuation = ContinuationGotoEmissionContext()
        let result = emitRegion(control.root, depth: depth, cfg: cfg, instructions: function.instructions,
            names: nativeNames, callSignaturesByTarget: callSignaturesByTarget,
            suppressedInstructions: [], loopContext: nil,
            continuationGotoContext: &continuation, gotoLeafDiagnostics: &diagnostics,
            ordinaryContext: context, into: &scratch)
        guard result.supported, let node = result.node, context.complete,
              result.emittedBlocks == Set(cfg.blocks.indices), !continuation.hasTargets,
              !emissionLimitReached else { return nil }
        for (row, index) in context.originalLineIndices {
            guard let original = originals[row], scratch.indices.contains(index) else { return nil }
            let after = scratch[index]
            let delta: Int
            if state.boundaries.callRows.contains(row) {
                guard payload(after.text) == payload(original.text) else { return nil }
                delta = after.text.count - original.text.count
            } else {
                guard after.text == original.text else { return nil }
                delta = 0
            }
            guard after.kind == original.kind, after.source == original.source,
                  after.tokens.count == original.tokens.count,
                  zip(after.tokens, original.tokens).allSatisfy({ after, before in
                      after.kind == before.kind && after.text == before.text
                          && after.sourceAddress == before.sourceAddress
                          && after.range.lowerBound == before.range.lowerBound + delta
                          && after.range.upperBound == before.range.upperBound + delta
                  }) else { return nil }
        }
        lines = scratch
        return node
    }

    private func emitOrdinaryFallbackLabel(
        _ block: Int, loopEntry: Bool = false, depth: Int,
        context: RegionalOrdinaryEmissionContext, into lines: inout [PseudocodeLine]
    ) -> Bool {
        guard let label = context.control.labels[block] else { return true }
        if label.isLoopEntry && !loopEntry {
            guard context.labels.contains(block) else { context.failed = true; return false }
            return true
        }
        guard label.isLoopEntry == loopEntry, context.labels.insert(block).inserted,
              context.cfg.blocks.indices.contains(block) else { context.failed = true; return false }
        let source = context.function.instructions[context.cfg.blocks[block].startIndex].source
        // A certified source block may contain no prepared statements. The
        // empty statement keeps the label valid even at a lexical scope end.
        appendLine("\(indent(depth))\(label.name):;", kind: .instruction, source: source, to: &lines)
        return true
    }

    private func emitOrdinaryFallbackLeading(
        _ row: Int, depth: Int, context: RegionalOrdinaryEmissionContext,
        names: PseudocodeNameContext, callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        guard let block = blockContaining(instructionIndex: row, cfg: context.cfg),
              row == context.cfg.blocks[block].endIndex - 1,
              context.values.groups[row].isEmpty,
              emitOrdinaryFallbackLabel(block, depth: depth, context: context, into: &lines),
              context.own(row) else { context.failed = true; return nil }
        let start = lines.count + 1
        emitRows(context.cfg.blocks[block].startIndex..<row, depth: depth,
            instructions: context.function.instructions, names: names,
            callSignaturesByTarget: callSignaturesByTarget, ordinaryContext: context, into: &lines)
        return start <= lines.count ? PseudocodeRegionNode(kind: .block, startLine: start,
                                                          endLine: lines.count) : nil
    }

    private func emitOrdinaryFallbackBlock(
        _ block: Int, depth: Int, context: RegionalOrdinaryEmissionContext,
        names: PseudocodeNameContext, callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> RegionEmissionResult {
        guard context.cfg.blocks.indices.contains(block),
              emitOrdinaryFallbackLabel(block, depth: depth, context: context, into: &lines) else { return .unsupported }
        let start = lines.count + 1, bounds = context.cfg.blocks[block]
        emitRows(bounds.startIndex..<bounds.endIndex, depth: depth,
            instructions: context.function.instructions, names: names,
            callSignaturesByTarget: callSignaturesByTarget, ordinaryContext: context, into: &lines)
        guard !context.failed else { return .unsupported }
        return RegionEmissionResult(supported: true,
            node: start <= lines.count ? PseudocodeRegionNode(kind: .block, startLine: start, endLine: lines.count) : nil,
            emittedBlocks: [block], gotoLeafCount: 0)
    }

    /// Only empty control phases qualify. A block, predicate or payload node
    /// never becomes empty merely because its current rendering looks small.
    private func ordinaryFallbackHasNoText(_ region: Region, context: RegionalOrdinaryEmissionContext) -> Bool {
        switch region {
        case let .sequence(parts): return parts.allSatisfy { ordinaryFallbackHasNoText($0, context: context) }
        case let .certifiedEdge(id):
            guard let slot = context.control.edgeSlots[id], slot.transfer == .fallthrough else { return false }
            return slot.phase == .transferOnly || slot.origins.allSatisfy { (context.values.edgeCopies[$0.cfgEdge] ?? []).isEmpty }
        default: return false
        }
    }

    private func emitOrdinaryFallbackEdge(
        _ id: RegionalOrdinaryControlPlan.EdgeEmissionSlotID, depth: Int,
        context: RegionalOrdinaryEmissionContext, names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature], into lines: inout [PseudocodeLine]
    ) -> RegionEmissionResult {
        guard let slot = context.control.edgeSlots[id], context.own(slot),
              slot.nearestLoopHeader == context.activeLoops.last,
              let origin = slot.origins.first else { return .unsupported }
        let start = lines.count + 1
        if slot.phase != .transferOnly {
            guard let copies = RegionalOrdinaryControlPlan.commonCopySchedule(
                for: slot.origins, values: context.values) else { return .unsupported }
            // Preserve the certified sequential schedule without reindexing
            // through legacy row-index suppression or peepholes. Expression,
            // naming and casts still use the unchanged native scalar renderer.
            // A factored schedule renders once; its slot still owns every
            // original source edge, not only this representative source span.
            for copy in copies {
                appendLine("\(indent(depth))\(render(instruction: copy, names: names));",
                           kind: .instruction, source: copy.source, to: &lines)
            }
        }
        var gotos = 0
        if slot.phase != .copiesOnly {
            let row = context.cfg.blocks[origin.sourceBlock].endIndex - 1
            let source = context.function.instructions[row].source
            switch slot.transfer {
            case .fallthrough: break
            case let .gotoLabel(target):
                guard let label = context.control.labels[target],
                      slot.origins.allSatisfy({ $0.targetBlock == target }) else { return .unsupported }
                appendLine("\(indent(depth))goto \(label.name);", kind: .instruction, source: source, to: &lines)
                gotos = 1
            case let .breakLoop(header):
                guard context.activeLoops.last == header else { return .unsupported }
                appendLine("\(indent(depth))break;", kind: .instruction, source: source, to: &lines)
            case let .continueLoop(header):
                guard context.activeLoops.last == header else { return .unsupported }
                appendLine("\(indent(depth))continue;", kind: .instruction, source: source, to: &lines)
            }
        }
        return RegionEmissionResult(supported: true,
            node: start <= lines.count ? PseudocodeRegionNode(kind: gotos == 0 ? .block : .gotoLeaf,
                startLine: start, endLine: lines.count) : nil, emittedBlocks: [], gotoLeafCount: gotos)
    }

    /// Reuse the decoded admission and nested topology, but project source SSA
    /// definitions and selected edge copies through the existing native printer.
    private func emitDecodedScalarFallback(
        function: MacIRFunction, cfg: CFG, depth: Int, names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        guard boundedEmissionState == nil else { return nil }
        if let proof = lexicalProof(for: function) {
            var candidate = lines
            if let node = emitDecodedScalarFallbackCandidate(function: proof.function, cfg: cfg, depth: depth,
                names: lexicalNames(for: proof, preserving: names),
                callSignaturesByTarget: callSignaturesByTarget, lexicalProof: proof, into: &candidate) {
                lines = candidate
                return node
            }
        }
        return emitDecodedScalarFallbackCandidate(function: function, cfg: cfg, depth: depth, names: names,
            callSignaturesByTarget: callSignaturesByTarget, lexicalProof: nil, into: &lines)
    }

    private func emitDecodedScalarFallbackCandidate(
        function: MacIRFunction, cfg: CFG, depth: Int, names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        lexicalProof: RegionalLexicalProof?, into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        guard boundedEmissionState == nil else { return nil }
        let reserved = Set(names.argumentNames.values)
            .union(names.localsByOffset.values.map(\.name)).union(names.registerNamesByValue.values)
            .union(names.registerNameOverrides.values)
        guard let state = DecodedScalarCFGPlan.prove(function: function, cfg: cfg, lexicalProof: lexicalProof,
                attemptLexical: false),
              let topology = RegionTree.build(cfg: cfg, instructions: function.instructions, certifiedBy: state),
              let proof = DecodedScalarRegionPlan.prove(cfg: cfg, instructions: function.instructions,
                                                       state: state, control: topology),
              let values = DecodedScalarNativeValuePlan.prove(function: function, cfg: cfg, certifiedBy: state,
                  renderedName: { valueText(for: $0, names: names) }, reservedNames: reserved,
                  authoritativeTypes: names.valueTypes, lexicalProof: lexicalProof),
              let control = DecodedScalarNativeControlPlan.prove(function: function, cfg: cfg,
                  state: state, topology: proof, values: values) else { return nil }
        var owners: [String: MacIRValue] = [:]
        let forbidden: Set<String> = ["auto", "break", "case", "char", "const", "continue", "default",
            "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int",
            "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
            "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "true", "false",
            "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t"]
        func ownName(_ value: MacIRValue) -> Bool {
            let text = valueText(for: value, names: names)
            guard !forbidden.contains(text),
                  text.range(of: #"\A[A-Za-z_][A-Za-z_0-9]*\z"#, options: .regularExpression) != nil,
                  owners[text] == nil || owners[text] == value else { return false }
            owners[text] = value; return true
        }
        for (binding, name) in names.argumentNames {
            let value = MacIRValue.argument(bindingID: binding)
            guard valueText(for: value, names: names) == name, ownName(value) else { return nil }
        }
        guard values.namedValues.allSatisfy(ownName) else { return nil }
        var statementCache: [Int: [PseudocodeLine]] = [:]
        func originalLines(at row: Int) -> [PseudocodeLine] {
            guard let block = blockContaining(instructionIndex: row, cfg: cfg) else { return [] }
            if statementCache[block] == nil {
                var statements: [PseudocodeLine] = []
                emitRows(cfg.blocks[block].instructionRange, depth: depth, instructions: function.instructions,
                         names: names, callSignaturesByTarget: callSignaturesByTarget, into: &statements)
                statementCache[block] = statements
            }
            return statementCache[block, default: []].filter { $0.source == function.instructions[row].source }
        }
        var originals: [Int: PseudocodeLine] = [:]
        for (row, group) in values.groups.enumerated() {
            for item in group {
                guard case let .protectedOriginal(expected) = item else { continue }
                guard expected == row, case .returnValue = function.instructions[row].operation else { return nil }
                let matches = originalLines(at: row)
                guard matches.count == 1, originals[row] == nil, let original = matches.first,
                      original.kind == .instruction else { return nil }
                originals[row] = original
            }
        }
        guard values.permitsNames(names: names, renderedName: { valueText(for: $0, names: names) }) else { return nil }
        var nativeNames = names
        nativeNames.valueTypes.merge(values.valueTypes) { _, certified in certified }
        for group in values.groups {
            for item in group {
                guard case let .instruction(instruction) = item,
                      case let .load(_, address) = instruction.operation else { continue }
                if case .stackSlot = address { return nil }
                guard structFieldAccess(for: address, names: nativeNames) == nil else { return nil }
                if case let .load(carrier, _) = instruction.operation,
                   let access = instruction.memoryAccess ?? recordNaturalAccess(carrier, names: nativeNames),
                   recordFieldMemoryText(address: address, carrier: carrier, access: access,
                       isStore: false, names: nativeNames) != nil { return nil }
                let target: (MacIRValue, Int)?
                if case let .binaryExpression(op, base, .immediate(offset)) = address,
                   op == "+", offset == 0 { target = (base, 0) }
                else { target = PseudocodeNameContext.dereferenceTarget(address) }
                if let (base, offset) = target, let access = instruction.memoryAccess,
                   nativeNames.structFieldName(forBase: base, offset: offset, access: access,
                       floating: false, isStore: false) != nil { return nil }
            }
        }
        guard values.declarations.allSatisfy({ $0.initializer == nil }),
              values.printedDeclarationValues.isSubset(of: Set(values.declarations.map(\.storage))) else { return nil }
        let context = DecodedScalarNativeEmissionContext(function: function, cfg: cfg,
            values: values, control: control, originals: originals)
        var scratch = lines
        let start = scratch.count + 1
        let printed = values.declarations.filter { values.printedDeclarationValues.contains($0.storage) }
        for type in Set(printed.map(\.type)).sorted() {
            let declarations = printed.filter { $0.type == type }
            for offset in stride(from: 0, to: declarations.count, by: 6) {
                let chunk = declarations[offset..<min(offset + 6, declarations.count)]
                    .map { valueText(for: $0.storage, names: nativeNames) }.joined(separator: ", ")
                appendLine("\(indent(depth))\(type) \(chunk);", kind: .declaration, to: &scratch)
            }
        }
        var diagnostics = GotoLeafEmissionDiagnostics(enabled: Self.gotoLeafDiagnosticsEnabled)
        var continuation = ContinuationGotoEmissionContext()
        let result = emitRegion(control.root, depth: depth, cfg: cfg, instructions: function.instructions,
            names: nativeNames, callSignaturesByTarget: callSignaturesByTarget,
            suppressedInstructions: [], loopContext: nil, continuationGotoContext: &continuation,
            gotoLeafDiagnostics: &diagnostics, scalarContext: context, into: &scratch)
        guard result.supported, let body = result.node, context.complete,
              result.emittedBlocks == Set(cfg.blocks.indices), !continuation.hasTargets,
              !emissionLimitReached else { return nil }
        for (row, index) in context.originalLineIndices {
            guard let original = originals[row], scratch.indices.contains(index),
                  scratch[index].text == original.text, scratch[index].kind == original.kind,
                  scratch[index].source == original.source else { return nil }
        }
        lines = scratch
        return PseudocodeRegionNode(kind: .sequence, startLine: start, endLine: scratch.count, children: [body])
    }

    private func emitScalarFallbackLeading(
        _ row: Int, depth: Int, context: DecodedScalarNativeEmissionContext,
        names: PseudocodeNameContext, callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        guard let block = blockContaining(instructionIndex: row, cfg: context.cfg),
              row == context.cfg.blocks[block].endIndex - 1,
              context.values.groups[row].isEmpty, context.own(row) else { context.failed = true; return nil }
        let start = lines.count + 1
        emitRows(context.cfg.blocks[block].startIndex..<row, depth: depth,
            instructions: context.function.instructions, names: names,
            callSignaturesByTarget: callSignaturesByTarget, scalarContext: context, into: &lines)
        return start <= lines.count ? PseudocodeRegionNode(kind: .block, startLine: start, endLine: lines.count) : nil
    }

    private func emitScalarFallbackBlock(
        _ block: Int, depth: Int, context: DecodedScalarNativeEmissionContext,
        names: PseudocodeNameContext, callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> RegionEmissionResult {
        guard context.cfg.blocks.indices.contains(block) else { return .unsupported }
        let start = lines.count + 1, bounds = context.cfg.blocks[block]
        emitRows(bounds.startIndex..<bounds.endIndex, depth: depth,
            instructions: context.function.instructions, names: names,
            callSignaturesByTarget: callSignaturesByTarget, scalarContext: context, into: &lines)
        guard !context.failed else { return .unsupported }
        return RegionEmissionResult(supported: true,
            node: start <= lines.count ? PseudocodeRegionNode(kind: .block, startLine: start, endLine: lines.count) : nil,
            emittedBlocks: [block], gotoLeafCount: 0)
    }

    private func scalarFallbackHasNoText(_ region: Region, context: DecodedScalarNativeEmissionContext) -> Bool {
        switch region {
        case let .sequence(parts): return parts.allSatisfy { scalarFallbackHasNoText($0, context: context) }
        case let .certifiedEdge(id):
            guard let slot = context.control.edgeSlots[id], slot.transfer == .fallthrough else { return false }
            return slot.origins.allSatisfy { (context.values.edgeCopies[$0.cfgEdge] ?? []).isEmpty }
        default: return false
        }
    }

    private func emitScalarFallbackEdge(
        _ id: DecodedScalarNativeControlPlan.EdgeEmissionSlotID, depth: Int,
        context: DecodedScalarNativeEmissionContext, names: PseudocodeNameContext,
        into lines: inout [PseudocodeLine]
    ) -> RegionEmissionResult {
        guard let slot = context.control.edgeSlots[id], context.own(slot),
              let origin = slot.origins.first else { return .unsupported }
        let start = lines.count + 1
        for copy in context.values.edgeCopies[origin.cfgEdge] ?? [] {
            guard case .assign = copy.operation else { return .unsupported }
            appendLine("\(indent(depth))\(render(instruction: copy, names: names));",
                       kind: .instruction, source: copy.source, to: &lines)
        }
        switch slot.transfer {
        case .fallthrough: break
        case let .breakLoop(header):
            guard context.activeLoops.last == header else { return .unsupported }
            let source = context.function.instructions[context.cfg.blocks[origin.sourceBlock].endIndex - 1].source
            appendLine("\(indent(depth))break;", kind: .instruction, source: source, to: &lines)
        }
        return RegionEmissionResult(supported: true,
            node: start <= lines.count ? PseudocodeRegionNode(kind: .block, startLine: start, endLine: lines.count) : nil,
            emittedBlocks: [], gotoLeafCount: 0)
    }

    /// Supplementary fallback only. The certificate repairs every backedge-live
    /// architectural value before this loop can replace a raw self-transfer.
    private func emitEntryLoopFallback(
        function: MacIRFunction, cfg: CFG, depth: Int, names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        guard boundedEmissionState == nil else { return nil }
        if let proof = lexicalProof(for: function) {
            var candidate = lines
            if let node = emitEntryLoopFallbackCandidate(function: proof.function, cfg: cfg, depth: depth,
                names: lexicalNames(for: proof, preserving: names),
                callSignaturesByTarget: callSignaturesByTarget, lexicalProof: proof, into: &candidate) {
                lines = candidate
                return node
            }
        }
        return emitEntryLoopFallbackCandidate(function: function, cfg: cfg, depth: depth, names: names,
            callSignaturesByTarget: callSignaturesByTarget, lexicalProof: nil, into: &lines)
    }

    private func emitEntryLoopFallbackCandidate(
        function: MacIRFunction, cfg: CFG, depth: Int, names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        lexicalProof: RegionalLexicalProof?, into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        // Speculative scratch emission must not consume a shared bounded budget.
        guard boundedEmissionState == nil else { return nil }
        guard let plan = EntryLoopNativeValuePlan.prove(function: function, cfg: cfg, lexicalProof: lexicalProof,
                attemptLexical: false),
              plan.permitsNames(names: names, renderedName: { valueText(for: $0, names: names) }) else { return nil }
        let forbiddenNames: Set<String> = [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
            "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
            "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
            "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
            "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary",
            "_Noreturn", "_Static_assert", "_Thread_local", "alignas", "alignof", "bool",
            "constexpr", "false", "nullptr", "static_assert", "thread_local", "true", "typeof",
            "typeof_unqual", "_BitInt", "int8_t", "int16_t", "int32_t", "int64_t",
            "uint8_t", "uint16_t", "uint32_t", "uint64_t"
        ]
        let validName: (String) -> Bool = {
            !forbiddenNames.contains($0)
                && $0.range(of: #"\A[A-Za-z_][A-Za-z_0-9]*\z"#, options: .regularExpression) != nil
        }
        var ownerByName: [String: MacIRValue] = [:]
        // Unused formals still own storage in the printed scope. A body temp
        // must not silently capture one (and inherit its narrower type).
        for (binding, name) in names.argumentNames {
            let value = MacIRValue.argument(bindingID: binding)
            guard validName(name), ownerByName[name] == nil || ownerByName[name] == value else { return nil }
            ownerByName[name] = value
        }
        for value in plan.namedValues {
            let name = valueText(for: value, names: names)
            guard validName(name),
                  ownerByName[name] == nil || ownerByName[name] == value else { return nil }
            ownerByName[name] = value
        }
        var nativeNames = names
        nativeNames.valueTypes.merge(plan.valueTypes) { _, certified in certified }
        // The projection certifies scalar integer dereferences, not contextual
        // field/stack sugar with a different inferred RHS representation.
        for group in plan.groups {
            for instruction in group {
                guard case let .load(_, address) = instruction.operation else { continue }
                if case .stackSlot = address { return nil }
                guard structFieldAccess(for: address, names: nativeNames) == nil else { return nil }
                if case let .load(carrier, _) = instruction.operation,
                   let access = instruction.memoryAccess ?? recordNaturalAccess(carrier, names: nativeNames),
                   recordFieldMemoryText(address: address, carrier: carrier, access: access,
                       isStore: false, names: nativeNames) != nil { return nil }
                let target: (MacIRValue, Int)?
                if case let .binaryExpression(op, base, .immediate(offset)) = address,
                   op == "+", offset == 0 { target = (base, 0) }
                else { target = PseudocodeNameContext.dereferenceTarget(address) }
                if let (base, offset) = target, let access = instruction.memoryAccess,
                   nativeNames.structFieldName(forBase: base, offset: offset, access: access,
                       floating: false, isStore: false) != nil { return nil }
            }
        }

        let prefix = indent(depth), bodyPrefix = indent(depth + 1)
        var scratch = lines
        let start = scratch.count + 1
        for declaration in plan.declarations {
            appendLine("\(prefix)\(declaration.type) \(valueText(for: declaration.storage, names: nativeNames)) = \(valueText(for: declaration.initializer, names: nativeNames));",
                       kind: .declaration, to: &scratch)
        }
        let loopStart = scratch.count + 1
        appendLine("\(prefix)do {", kind: .instruction, to: &scratch)
        let bodyStart = scratch.count + 1
        for (row, group) in plan.groups.enumerated() {
            for (ordinal, instruction) in group.enumerated() {
                let suffix = ordinal == 0 ? commentSuffix(for: function.instructions[row],
                    callSignaturesByTarget: callSignaturesByTarget) : ""
                appendLine("\(bodyPrefix)\(render(instruction: instruction, names: nativeNames));\(suffix)",
                           kind: .instruction, source: instruction.source, to: &scratch)
            }
        }
        let bodyEnd = scratch.count
        let condition = "\(valueText(for: plan.conditionValue, names: nativeNames)) \(plan.condition) 0x0"
        appendLine("\(prefix)} while (\(condition));\(commentSuffix(for: plan.branch, callSignaturesByTarget: callSignaturesByTarget))",
                   kind: .instruction, source: plan.branch.source, to: &scratch)
        let loopEnd = scratch.count
        appendLine("\(prefix)\(render(instruction: plan.terminal, names: names));\(commentSuffix(for: plan.terminal, callSignaturesByTarget: callSignaturesByTarget))",
                   kind: .instruction, source: plan.terminal.source, to: &scratch)
        let bodyLines = scratch.dropFirst(lines.count)
        // Splitting a writeback retains two scalar effects at one immutable
        // row. Ownership is by the certified group, not comment cardinality.
        guard plan.groups.count == function.instructions.count - 2,
              Set(bodyLines.compactMap { $0.source?.address }) == Set(function.instructions.map { $0.source.address }),
              plan.groups.enumerated().allSatisfy({ row, group in
                  group.allSatisfy { $0.source == function.instructions[row].source }
                    && bodyLines.filter { $0.source == function.instructions[row].source }.count == group.count
              }),
              bodyLines.filter({ $0.source == plan.branch.source }).count == 1,
              bodyLines.filter({ $0.source == plan.terminal.source }).count == 1 else { return nil }
        let loop = PseudocodeRegionNode(kind: .doWhileLoop, startLine: loopStart, endLine: loopEnd,
            condition: condition, conditionSourceAddress: plan.branch.source.address,
            children: [.init(kind: .block, startLine: bodyStart, endLine: bodyEnd)])
        let node = PseudocodeRegionNode(kind: .sequence, startLine: start, endLine: scratch.count,
            children: [loop, .init(kind: .block, startLine: scratch.count, endLine: scratch.count)])
        lines = scratch
        return node
    }

    /// Emit the proven recovery grammar. Named block breaks are C-like
    /// pseudocode (not ISO C); unlike an unlabelled break they specify exactly
    /// which post-loop continuation is selected, including across nested loops.
    private func emitRecovery(
        cfg: CFG, depth: Int, instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        guard options.recoverSharedTails || options.recoverLoopExits || options.recoverGuardRegions else { return nil }
        let diagnostics = RegionTree.buildWithDiagnostics(
            cfg: cfg, instructions: instructions, collectDiagnostics: true
        ).diagnostics
        guard diagnostics.siteCounts[.branchConditionMissingAdjacentCompare, default: 0] == 0,
              let veto = diagnostics.fatalVeto,
              let plan = RegionTree.recoveryPlan(cfg: cfg, instructions: instructions, options: options, veto: veto)
        else { return nil }
        var scratch = lines
        var failed = false
        var remainingNodes = 8192
        var labelAllocator = RecoveryLabelAllocator()
        var breakLabels: [Int: String] = [:], continueLabels: [Int: String] = [:]
        #if DEBUG
        var textCheck = CP6RecoveryTextCheck.Emission(bodyStart: lines.count)
        #endif
        func label(_ prefix: String, _ target: Int) -> String {
            let address = instructions[cfg.blocks[target].startIndex].source.address
            return labelAllocator.label(prefix: prefix, address: address)
        }
        func isEmpty(_ region: RegionTree.RecoveryRegion) -> Bool {
            if case .sequence(let parts) = region { return parts.allSatisfy(isEmpty) }
            return false
        }
        func transfer(_ region: RegionTree.RecoveryRegion) -> String? {
            switch region {
            case .breakTo(let target): return breakLabels[target].map { "break \($0);" }
            case .continueAt(let header): return continueLabels[header].map { "continue \($0);" }
            default: return nil
            }
        }
        func emit(_ region: RegionTree.RecoveryRegion, at level: Int) -> PseudocodeRegionNode? {
            remainingNodes -= 1
            guard !failed, remainingNodes >= 0, level - depth <= 128,
                  emissionCancellation?.isCancelled != true else { failed = true; return nil }
            let prefix = String(repeating: "    ", count: level + 1)
            let start = scratch.count + 1
            var children: [PseudocodeRegionNode] = []
            var kind: PseudocodeRegionNode.Kind = .sequence
            var condition: String?
            var conditionAddress: UInt64?
            func child(_ region: RegionTree.RecoveryRegion, at level: Int) {
                if let node = emit(region, at: level) { children.append(node) }
            }
            switch region {
            case .sequence(let parts):
                for part in parts { child(part, at: level) }
            case .scope(let target, let body):
                let name = label("exit", target)
                breakLabels[target] = name
                appendLine("\(prefix)\(name): {", kind: .instruction, to: &scratch)
                child(body, at: level + 1)
                appendLine("\(prefix)}", kind: .instruction, to: &scratch)
                breakLabels.removeValue(forKey: target)
            case .loop(let header, let body):
                kind = .whileLoop
                condition = "true"
                let name = label("loop", header)
                continueLabels[header] = name
                appendLine("\(prefix)\(name): while (true) {", kind: .instruction, to: &scratch)
                child(body, at: level + 1)
                appendLine("\(prefix)}", kind: .instruction, to: &scratch)
                continueLabels.removeValue(forKey: header)
            case .breakTo(let target):
                guard let name = breakLabels[target] else { failed = true; return nil }
                appendLine("\(prefix)break \(name);", kind: .instruction, to: &scratch)
            case .continueAt(let header):
                guard let name = continueLabels[header] else { failed = true; return nil }
                appendLine("\(prefix)continue \(name);", kind: .instruction, to: &scratch)
            case .block(let index, let exits):
                kind = .block
                let block = cfg.blocks[index]
                let last = block.endIndex - 1
                var suppressed = Set<Int>()
                if exits.count == 2 {
                    suppressed.insert(last)
                } else if exits.count == 1,
                          case .unconditionalBranch = CFGBuilder.terminatorKind(of: instructions[last].operation) {
                    suppressed.insert(last)
                }
                #if DEBUG
                let payloadStart = scratch.count
                #endif
                _ = emitBlock(index, depth: level, cfg: cfg, instructions: instructions,
                              names: names, callSignaturesByTarget: callSignaturesByTarget,
                              suppressedInstructions: suppressed, into: &scratch)
                #if DEBUG
                textCheck.recordBlock(index, payloadStart: payloadStart, lines: scratch)
                #endif
                if exits.count == 2 {
                    guard case let .conditionalBranch(op, left, right, _) = instructions[last].operation else {
                        failed = true; return nil
                    }
                    kind = .ifThenElse
                    // The existing renderer can negate logical compounds only
                    // when every leaf has a supported inverse. Its generic
                    // fallback does not parenthesize a compound compared to zero,
                    // so never introduce that fallback by flipping a guard.
                    let unsupportedCompoundNegation = right == .immediate(0)
                        && isCompoundCondition(left) && negateCondition(left) == nil
                    if unsupportedCompoundNegation && op == "==" {
                        failed = true; return nil
                    }
                    let forward = renderCondition(left: left, condition: op, right: right, names: names)
                    let inverseOperator = unsupportedCompoundNegation && op == "!=" ? nil : invertedBranchCondition(op)
                    let inverted = inverseOperator.map {
                        renderCondition(left: left, condition: $0, right: right, names: names)
                    }
                    let flip = isEmpty(exits[0]) && !isEmpty(exits[1]) && inverted != nil
                    let text = flip ? inverted! : forward
                    let taken = flip ? exits[1] : exits[0]
                    let other = flip ? exits[0] : exits[1]
                    condition = text
                    conditionAddress = instructions[last].source.address
                    #if DEBUG
                    textCheck.recordBranch(index, lineIndex: scratch.count, forward: forward,
                                           inverted: inverted, source: instructions[last].source)
                    #endif
                    let comment = commentSuffix(for: instructions[last], callSignaturesByTarget: callSignaturesByTarget)
                    if isEmpty(other), let statement = transfer(taken) {
                        kind = .ifThen
                        appendLine("\(prefix)if (\(text)) \(statement)\(comment)",
                                   kind: .instruction, source: instructions[last].source, to: &scratch)
                    } else {
                        kind = isEmpty(other) ? .ifThen : .ifThenElse
                        appendLine("\(prefix)if (\(text)) {\(comment)",
                                   kind: .instruction, source: instructions[last].source, to: &scratch)
                        child(taken, at: level + 1)
                        if !isEmpty(other) {
                            appendLine("\(prefix)} else {", kind: .instruction, to: &scratch)
                            child(other, at: level + 1)
                        }
                        appendLine("\(prefix)}", kind: .instruction, to: &scratch)
                    }
                } else if let exit = exits.first {
                    child(exit, at: level)
                }
            }
            guard scratch.count >= start else { return nil }
            return PseudocodeRegionNode(kind: kind, startLine: start, endLine: scratch.count,
                                        condition: condition, conditionSourceAddress: conditionAddress,
                                        children: children)
        }
        guard let node = emit(plan.root, at: depth), !failed,
              emissionCancellation?.isCancelled != true else { return nil }
        #if DEBUG
        assert(CP6RecoveryTextCheck.validate(lines: scratch, plan: plan.root, cfg: cfg, emission: textCheck),
               "Recovered text does not match its proven plan")
        recoveryTextCheckCapture?.record(lines: scratch, plan: plan.root, cfg: cfg, emission: textCheck)
        #endif
        lines = scratch
        return node
    }

    #if DEBUG
    /// Historical cost model retained solely for direct regression tests. Token classification excludes
    /// comments and string contents, so text that happens to mention a goto
    /// cannot buy an extra transfer. Indentation is measured on emitted code.
    static func recoveryReadabilityAdmits(candidate: [PseudocodeLine], legacy: [PseudocodeLine],
                                          startingAt start: Int, options: DecompilerOptions) -> Bool {
        func metrics(_ lines: [PseudocodeLine]) -> (gotos: Int, transfers: Int, indent: Int) {
            var gotos = 0, transfers = 0, indent = 0
            for line in lines.dropFirst(start) where line.kind == .instruction {
                for token in line.tokens where token.kind == .keyword {
                    if token.text == "goto" { gotos += 1 }
                    if token.text == "break" || token.text == "continue" { transfers += 1 }
                }
                indent = max(indent, line.text.prefix(while: { $0 == " " }).count)
            }
            return (gotos, transfers, indent)
        }
        let before = metrics(legacy), after = metrics(candidate)
        let removed = before.gotos - after.gotos
        let ratio = min(max(options.recoveryMaxTransferRatioPercent, 0), 400)
        let extraDepth = min(max(options.recoveryMaxAdditionalNesting, 0), 16)
        return removed > 0 && after.transfers * 100 <= removed * ratio
            && after.indent <= before.indent + 4 * extraDepth
    }

    #endif

    private func emitBody(
        function: MacIRFunction,
        forcedRegionForTesting region: Region,
        depth: Int,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> BodyStructureResult {
        let cfg = function.cfg?.compatibilityCFG ?? CFGBuilder.buildCFG(instructions: instructions)
        let functionRange = CFGBuilder.functionAddressRange(instructions: instructions)
        var suppressedInstructions: Set<Int> = []
        for block in cfg.blocks {
            let terminatorIndex = block.endIndex - 1
            guard terminatorIndex >= block.startIndex else { continue }
            if case let .unconditionalBranch(target) = CFGBuilder.terminatorKind(of: instructions[terminatorIndex].operation),
               let target,
               let functionRange,
               functionRange.contains(target) {
                suppressedInstructions.insert(terminatorIndex)
            }
        }

        var scratch = lines
        var gotoLeafDiagnostics = GotoLeafEmissionDiagnostics(enabled: Self.gotoLeafDiagnosticsEnabled)
        var continuationGotoContext = ContinuationGotoEmissionContext()
        let regionResult = emitRegion(
            region,
            depth: depth,
            cfg: cfg,
            instructions: instructions,
            names: namesWithGotoLeafLabels(names, region: region, cfg: cfg, instructions: instructions),
            callSignaturesByTarget: callSignaturesByTarget,
            suppressedInstructions: suppressedInstructions,
            loopContext: nil,
            continuationGotoContext: &continuationGotoContext,
            gotoLeafDiagnostics: &gotoLeafDiagnostics,
            into: &scratch
        )
        if regionResult.supported,
           regionResult.emittedBlocks == Set(cfg.blocks.indices),
           continuationGotoContext.emittedExactlyOnceAtStatementBoundaries,
           let regionNode = regionResult.node {
            if regionResult.containsGotoLeaf || continuationGotoContext.hasTargets {
                gotoLeafDiagnostics.record(.emitted, count: regionResult.gotoLeafCount)
            }
            emitGotoLeafDiagnosticsIfEnabled(functionName: function.name, diagnostics: gotoLeafDiagnostics)
            lines = scratch
            return BodyStructureResult(regionTree: regionNode, structureFallback: nil)
        }

        emitGotoLeafDiagnosticsIfEnabled(functionName: function.name, diagnostics: gotoLeafDiagnostics)
        emitFlat(
            0..<instructions.count,
            depth: depth,
            instructions: instructions,
            names: names,
            callSignaturesByTarget: callSignaturesByTarget,
            into: &lines
        )
        return BodyStructureResult(regionTree: nil, structureFallback: .unsupportedRegion)
    }

    private func emitGotoLeafDiagnosticsIfEnabled(
        functionName: String,
        diagnostics: GotoLeafEmissionDiagnostics
    ) {
        guard diagnostics.enabled, diagnostics.hasCounts else { return }
        let line = "GOTOLEAF_DIAGNOSTICS\tfunction=\(functionName)\tcounts=\(diagnostics.countsText())\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    /// Emit a proven region using the common statement renderer.
    /// Unsupported regions are rejected before the scratch body is published.
    private func emitRegion(
        _ region: Region,
        depth: Int,
        cfg: CFG,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        suppressedInstructions: Set<Int>,
        loopContext: LoopEmissionContext?,
        continuationGotoContext: inout ContinuationGotoEmissionContext,
        gotoLeafDiagnostics: inout GotoLeafEmissionDiagnostics,
        ordinaryContext: RegionalOrdinaryEmissionContext? = nil,
        scalarContext: DecodedScalarNativeEmissionContext? = nil,
        into lines: inout [PseudocodeLine]
    ) -> RegionEmissionResult {
        guard ordinaryContext == nil || scalarContext == nil else { return .unsupported }
        if let emissionCancellation {
            emissionCancellation.step()
            // Only a cancelled run takes this exit; the caller's fallback then stops immediately.
            if emissionCancellation.isCancelled { return .unsupported }
        }
        let prefix = indent(depth)
        switch region {
        case let .sequence(items):
            let startLine = lines.count + 1
            var children: [PseudocodeRegionNode] = []
            var emittedBlocks: Set<Int> = []
            var gotoLeafCount = 0
            for item in items {
                let itemResult = emitRegion(
                    item,
                    depth: depth,
                    cfg: cfg,
                    instructions: instructions,
                    names: names,
                    callSignaturesByTarget: callSignaturesByTarget,
                    suppressedInstructions: suppressedInstructions,
                    loopContext: loopContext,
                    continuationGotoContext: &continuationGotoContext,
                    gotoLeafDiagnostics: &gotoLeafDiagnostics,
                    ordinaryContext: ordinaryContext, scalarContext: scalarContext,
                    into: &lines
                )
                guard itemResult.supported else {
                    return .unsupported
                }
                if itemResult.containsGotoLeaf || gotoLeafCount > 0 || scalarContext != nil {
                    if !emittedBlocks.isDisjoint(with: itemResult.emittedBlocks) {
                        gotoLeafDiagnostics.record(.failedPartition)
                        return .unsupported
                    }
                }
                emittedBlocks.formUnion(itemResult.emittedBlocks)
                gotoLeafCount += itemResult.gotoLeafCount
                if let itemNode = itemResult.node {
                    children.append(itemNode)
                }
            }
            let endLine = lines.count
            guard startLine <= endLine else {
                return RegionEmissionResult(
                    supported: true,
                    node: nil,
                    emittedBlocks: emittedBlocks,
                    gotoLeafCount: gotoLeafCount
                )
            }
            return RegionEmissionResult(
                supported: true,
                node: PseudocodeRegionNode(
                    kind: .sequence,
                    startLine: startLine,
                    endLine: endLine,
                    children: children
                ),
                emittedBlocks: emittedBlocks,
                gotoLeafCount: gotoLeafCount
            )

        case let .block(blockIndex):
            if let scalarContext {
                return emitScalarFallbackBlock(blockIndex, depth: depth, context: scalarContext,
                    names: names, callSignaturesByTarget: callSignaturesByTarget, into: &lines)
            }
            if let ordinaryContext {
                return emitOrdinaryFallbackBlock(blockIndex, depth: depth, context: ordinaryContext,
                    names: names, callSignaturesByTarget: callSignaturesByTarget, into: &lines)
            }
            return emitBlockRegion(
                blockIndex,
                kind: .block,
                depth: depth,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                loopContext: loopContext,
                continuationGotoContext: &continuationGotoContext,
                into: &lines
            )

        case let .ifThen(cond, body, join, inverted):
            guard continuationGotoContext.recordTargets(
                cond.continuationGotoTargets, cfg: cfg, instructions: instructions
            ) else { return .unsupported }
            var selectedBody = body
            var fusedCondition: String?
            var fusedBlocks: Set<Int> = []
            if ordinaryContext == nil, scalarContext == nil, inverted,
               case let .ifThen(inner, innerBody, innerJoin, innerInverted) = body,
               innerInverted, innerJoin == join,
               let folded = structuredShortCircuitIf(startingAt: cond.compareIndex ?? cond.branchIndex,
                   limit: instructions.count, instructions: instructions, names: names),
               folded.targetIndex == cfg.blocks[join].startIndex,
               let innerBlock = blockContaining(instructionIndex: inner.branchIndex, cfg: cfg),
               cfg.blocks[innerBlock].startIndex == (inner.compareIndex ?? inner.branchIndex) {
                selectedBody = innerBody
                fusedCondition = folded.conditionText
                fusedBlocks.insert(innerBlock)
            }
            // Emit any leading instructions of the branch block (everything
            // before the suppressed compare/branch) as ordinary statements.
            let leadingNode: PseudocodeRegionNode?
            if let scalarContext {
                leadingNode = emitScalarFallbackLeading(cond.branchIndex, depth: depth,
                    context: scalarContext, names: names,
                    callSignaturesByTarget: callSignaturesByTarget, into: &lines)
                guard !scalarContext.failed else { return .unsupported }
            } else if let ordinaryContext {
                leadingNode = emitOrdinaryFallbackLeading(cond.branchIndex, depth: depth,
                    context: ordinaryContext, names: names,
                    callSignaturesByTarget: callSignaturesByTarget, into: &lines)
                guard !ordinaryContext.failed else { return .unsupported }
            } else {
                leadingNode = emitBranchBlockLeadingStatementsNode(cond: cond, depth: depth, cfg: cfg, instructions: instructions, names: names, callSignaturesByTarget: callSignaturesByTarget, into: &lines)
            }
            let startLine = lines.count + 1
            let branchInstruction = instructions[cond.branchIndex]
            // Fall-through bodies render the INVERTED condition (the C `if`
            // guards entry into the fall-through); a taken-edge body renders the
            // RAW condition (entering the body IS "branch taken").
            let conditionText = fusedCondition ?? (inverted
                ? invertedConditionText(for: cond, names: names)
                : rawConditionText(for: cond, names: names))
            appendLine(
                "\(prefix)if (\(conditionText)) {\(commentSuffix(for: branchInstruction, callSignaturesByTarget: callSignaturesByTarget))",
                kind: .instruction,
                source: branchInstruction.source,
                to: &lines
            )
            let bodyResult = emitRegion(
                selectedBody,
                depth: depth + 1,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                loopContext: loopContext,
                continuationGotoContext: &continuationGotoContext,
                gotoLeafDiagnostics: &gotoLeafDiagnostics,
                ordinaryContext: ordinaryContext, scalarContext: scalarContext,
                into: &lines
            )
            guard bodyResult.supported else { return .unsupported }
            var emittedBlocks = blockContaining(instructionIndex: cond.branchIndex, cfg: cfg).map { Set([$0]) } ?? []
            if bodyResult.containsGotoLeaf, !emittedBlocks.isDisjoint(with: bodyResult.emittedBlocks) {
                gotoLeafDiagnostics.record(.failedPartition)
                return .unsupported
            }
            emittedBlocks.formUnion(fusedBlocks)
            emittedBlocks.formUnion(bodyResult.emittedBlocks)
            appendLine("\(prefix)}", kind: .instruction, to: &lines)
            let constructNode = PseudocodeRegionNode(
                kind: .ifThen,
                startLine: startLine,
                endLine: lines.count,
                condition: conditionText,
                conditionSourceAddress: branchInstruction.source.address,
                children: bodyResult.node.map { [$0] } ?? []
            )
            return RegionEmissionResult(
                supported: true,
                node: wrappingLeadingNode(leadingNode, around: constructNode),
                emittedBlocks: emittedBlocks,
                gotoLeafCount: bodyResult.gotoLeafCount
            )

        case let .ifThenElse(cond, thenBody, elseBody, _):
            if !cond.continuationGotoTargets.isEmpty {
                guard continuationGotoContext.recordTargets(
                    cond.continuationGotoTargets, cfg: cfg, instructions: instructions
                ) else { return .unsupported }
            }
            let leadingNode: PseudocodeRegionNode?
            if let scalarContext {
                leadingNode = emitScalarFallbackLeading(cond.branchIndex, depth: depth,
                    context: scalarContext, names: names,
                    callSignaturesByTarget: callSignaturesByTarget, into: &lines)
                guard !scalarContext.failed else { return .unsupported }
            } else if let ordinaryContext {
                leadingNode = emitOrdinaryFallbackLeading(cond.branchIndex, depth: depth,
                    context: ordinaryContext, names: names,
                    callSignaturesByTarget: callSignaturesByTarget, into: &lines)
                guard !ordinaryContext.failed else { return .unsupported }
            } else {
                leadingNode = emitBranchBlockLeadingStatementsNode(cond: cond, depth: depth, cfg: cfg, instructions: instructions, names: names, callSignaturesByTarget: callSignaturesByTarget, into: &lines)
            }
            let thenEmpty = ordinaryContext.map { ordinaryFallbackHasNoText(thenBody, context: $0) }
                ?? scalarContext.map { scalarFallbackHasNoText(thenBody, context: $0) } ?? false
            let elseEmpty = ordinaryContext.map { ordinaryFallbackHasNoText(elseBody, context: $0) }
                ?? scalarContext.map { scalarFallbackHasNoText(elseBody, context: $0) } ?? false
            // No admitted distinct-successor graph currently needs both empty
            // arms. Do not invent a condition-elision proof here.
            guard !(thenEmpty && elseEmpty) else { return .unsupported }
            let swapped = thenEmpty
            let omitElse = thenEmpty || elseEmpty
            let firstBody = swapped ? elseBody : thenBody
            let secondBody = swapped ? thenBody : elseBody
            let startLine = lines.count + 1
            let branchInstruction = instructions[cond.branchIndex]
            let conditionText = swapped ? rawConditionText(for: cond, names: names)
                : invertedConditionText(for: cond, names: names)
            appendLine(
                "\(prefix)if (\(conditionText)) {\(commentSuffix(for: branchInstruction, callSignaturesByTarget: callSignaturesByTarget))",
                kind: .instruction,
                source: branchInstruction.source,
                to: &lines
            )
            let thenResult = emitRegion(
                firstBody,
                depth: depth + 1,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                loopContext: loopContext,
                continuationGotoContext: &continuationGotoContext,
                gotoLeafDiagnostics: &gotoLeafDiagnostics,
                ordinaryContext: ordinaryContext, scalarContext: scalarContext,
                into: &lines
            )
            guard thenResult.supported else { return .unsupported }
            appendLine(omitElse ? "\(prefix)}" : "\(prefix)} else {", kind: .instruction, to: &lines)
            let elseResult = emitRegion(
                secondBody,
                depth: depth + (omitElse ? 0 : 1),
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                loopContext: loopContext,
                continuationGotoContext: &continuationGotoContext,
                gotoLeafDiagnostics: &gotoLeafDiagnostics,
                ordinaryContext: ordinaryContext, scalarContext: scalarContext,
                into: &lines
            )
            guard elseResult.supported else { return .unsupported }
            let gotoLeafCount = thenResult.gotoLeafCount + elseResult.gotoLeafCount
            var emittedBlocks = blockContaining(instructionIndex: cond.branchIndex, cfg: cfg).map { Set([$0]) } ?? []
            if gotoLeafCount > 0 {
                for result in [thenResult, elseResult] {
                    if !emittedBlocks.isDisjoint(with: result.emittedBlocks) {
                        gotoLeafDiagnostics.record(.failedPartition)
                        return .unsupported
                    }
                    emittedBlocks.formUnion(result.emittedBlocks)
                }
            } else {
                emittedBlocks.formUnion(thenResult.emittedBlocks)
                emittedBlocks.formUnion(elseResult.emittedBlocks)
            }
            if !omitElse { appendLine("\(prefix)}", kind: .instruction, to: &lines) }
            let constructNode = PseudocodeRegionNode(
                kind: omitElse ? .ifThen : .ifThenElse,
                startLine: startLine,
                endLine: lines.count,
                condition: conditionText,
                conditionSourceAddress: branchInstruction.source.address,
                children: [thenResult.node, elseResult.node].compactMap { $0 }
            )
            return RegionEmissionResult(
                supported: true,
                node: wrappingLeadingNode(leadingNode, around: constructNode),
                emittedBlocks: emittedBlocks,
                gotoLeafCount: gotoLeafCount
            )

        case let .whileLoop(cond, body, header):
            guard ordinaryContext == nil, scalarContext == nil else { return .unsupported }
            guard continuationGotoContext.recordTargets(
                cond.continuationGotoTargets,
                cfg: cfg,
                instructions: instructions
            ) else {
                return .unsupported
            }
            let leadingNode = emitBranchBlockLeadingStatementsNode(cond: cond, depth: depth, cfg: cfg, instructions: instructions, names: names, callSignaturesByTarget: callSignaturesByTarget, into: &lines)
            let startLine = lines.count + 1
            let branchInstruction = instructions[cond.branchIndex]
            let conditionText = invertedConditionText(for: cond, names: names)
            appendLine(
                "\(prefix)while (\(conditionText)) {\(commentSuffix(for: branchInstruction, callSignaturesByTarget: callSignaturesByTarget))",
                kind: .instruction,
                source: branchInstruction.source,
                to: &lines
            )
            let bodyResult = emitRegion(
                body,
                depth: depth + 1,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                loopContext: loopEmissionContext(header: header, primaryBranchIndex: cond.branchIndex, cfg: cfg),
                continuationGotoContext: &continuationGotoContext,
                gotoLeafDiagnostics: &gotoLeafDiagnostics,
                ordinaryContext: ordinaryContext, scalarContext: scalarContext,
                into: &lines
            )
            guard bodyResult.supported else { return .unsupported }
            var emittedBlocks = blockContaining(instructionIndex: cond.branchIndex, cfg: cfg).map { Set([$0]) } ?? []
            if bodyResult.containsGotoLeaf, !emittedBlocks.isDisjoint(with: bodyResult.emittedBlocks) {
                gotoLeafDiagnostics.record(.failedPartition)
                return .unsupported
            }
            emittedBlocks.formUnion(bodyResult.emittedBlocks)
            appendLine("\(prefix)}", kind: .instruction, to: &lines)
            let constructNode = PseudocodeRegionNode(
                kind: .whileLoop,
                startLine: startLine,
                endLine: lines.count,
                condition: conditionText,
                conditionSourceAddress: branchInstruction.source.address,
                children: bodyResult.node.map { [$0] } ?? []
            )
            return RegionEmissionResult(
                supported: true,
                node: wrappingLeadingNode(leadingNode, around: constructNode),
                emittedBlocks: emittedBlocks,
                gotoLeafCount: bodyResult.gotoLeafCount
            )

        case let .doWhileLoop(body, cond):
            let ordinaryLoop = ordinaryContext?.control.loops.values.first { $0.condition.branchIndex == cond.branchIndex }
            let scalarLoop = scalarContext?.control.loops.values.first { $0.condition.branchIndex == cond.branchIndex }
            if let scalarContext {
                guard let scalarLoop, scalarLoop.kind == .doWhile,
                      scalarContext.ownDoWhileEdges(scalarLoop) else { return .unsupported }
                scalarContext.activeLoops.append(scalarLoop.header)
            }
            defer { if scalarLoop != nil { _ = scalarContext?.activeLoops.popLast() } }
            if let ordinaryContext {
                guard let ordinaryLoop, ordinaryLoop.kind == .doWhile,
                      ordinaryContext.ownDoWhileEdges(ordinaryLoop),
                      emitOrdinaryFallbackLabel(ordinaryLoop.header, loopEntry: true, depth: depth,
                                               context: ordinaryContext, into: &lines) else { return .unsupported }
                ordinaryContext.activeLoops.append(ordinaryLoop.header)
            }
            defer { if ordinaryLoop != nil { _ = ordinaryContext?.activeLoops.popLast() } }
            guard continuationGotoContext.recordTargets(
                cond.continuationGotoTargets,
                cfg: cfg,
                instructions: instructions
            ) else {
                return .unsupported
            }
            let startLine = lines.count + 1
            appendLine("\(prefix)do {", kind: .instruction,
                       source: ordinaryLoop.map { instructions[cfg.blocks[$0.header].startIndex].source }
                        ?? scalarLoop.map { instructions[cfg.blocks[$0.header].startIndex].source }, to: &lines)
            let bodyResult = emitRegion(
                body,
                depth: depth + 1,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                loopContext: doWhileLoopEmissionContext(cond: cond, cfg: cfg),
                continuationGotoContext: &continuationGotoContext,
                gotoLeafDiagnostics: &gotoLeafDiagnostics,
                ordinaryContext: ordinaryContext, scalarContext: scalarContext,
                into: &lines
            )
            guard bodyResult.supported else { return .unsupported }
            var emittedBlocks = blockContaining(instructionIndex: cond.branchIndex, cfg: cfg).map { Set([$0]) } ?? []
            if bodyResult.containsGotoLeaf, !emittedBlocks.isDisjoint(with: bodyResult.emittedBlocks) {
                gotoLeafDiagnostics.record(.failedPartition)
                return .unsupported
            }
            emittedBlocks.formUnion(bodyResult.emittedBlocks)
            if let scalarLoop { emittedBlocks.formUnion(scalarLoop.implicitBlocks) }
            // The bottom-test block's leading statements (before the suppressed
            // compare/branch) precede the `} while` line.
            let bottomLeadingNode: PseudocodeRegionNode?
            if let scalarContext {
                bottomLeadingNode = emitScalarFallbackLeading(cond.branchIndex, depth: depth + 1,
                    context: scalarContext, names: names,
                    callSignaturesByTarget: callSignaturesByTarget, into: &lines)
                guard !scalarContext.failed else { return .unsupported }
            } else if let ordinaryContext {
                bottomLeadingNode = emitOrdinaryFallbackLeading(cond.branchIndex, depth: depth + 1,
                    context: ordinaryContext, names: names,
                    callSignaturesByTarget: callSignaturesByTarget, into: &lines)
                guard !ordinaryContext.failed else { return .unsupported }
            } else {
                bottomLeadingNode = emitBranchBlockLeadingStatementsNode(cond: cond, depth: depth + 1, cfg: cfg, instructions: instructions, names: names, callSignaturesByTarget: callSignaturesByTarget, into: &lines)
            }
            let branchInstruction = instructions[cond.branchIndex]
            // Bottom-tested: the back-edge condition is the RAW (non-inverted)
            // branch condition.
            let conditionText = rawConditionText(for: cond, names: names)
            appendLine(
                "\(prefix)} while (\(conditionText));\(commentSuffix(for: branchInstruction, callSignaturesByTarget: callSignaturesByTarget))",
                kind: .instruction,
                source: branchInstruction.source,
                to: &lines
            )
            let constructNode = PseudocodeRegionNode(
                kind: .doWhileLoop,
                startLine: startLine,
                endLine: lines.count,
                condition: conditionText,
                conditionSourceAddress: branchInstruction.source.address,
                children: [bodyResult.node, bottomLeadingNode].compactMap { $0 }
            )
            return RegionEmissionResult(
                supported: true,
                node: constructNode,
                emittedBlocks: emittedBlocks,
                gotoLeafCount: bodyResult.gotoLeafCount
            )

        case let .switchDispatch(blockIndex, _, _):
            guard ordinaryContext == nil, scalarContext == nil else { return .unsupported }
            return emitBlockRegion(
                blockIndex,
                kind: .switchDispatch,
                depth: depth,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                loopContext: loopContext,
                continuationGotoContext: &continuationGotoContext,
                into: &lines
            )

        case let .gotoLeaf(blocks):
            guard ordinaryContext == nil, scalarContext == nil else { return .unsupported }
            return emitGotoLeafRegion(
                blocks,
                depth: depth,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                gotoLeafDiagnostics: &gotoLeafDiagnostics,
                continuationLabelAddresses: continuationGotoContext.targetAddresses,
                into: &lines
            )

        case let .naturalLoop(body, header):
            if ordinaryContext == nil, scalarContext == nil {
                guard let loop = RegionTree.syntheticPhiLatchLoop(header: header, cfg: cfg, instructions: instructions) else {
                    return .unsupported
                }
                let start = lines.count + 1
                appendLine("\(prefix)while (true) {", kind: .instruction, to: &lines)
                let child = emitRegion(body, depth: depth + 1, cfg: cfg, instructions: instructions,
                    names: names, callSignaturesByTarget: callSignaturesByTarget,
                    suppressedInstructions: suppressedInstructions,
                    loopContext: LoopEmissionContext(exitTarget: loop.exit, loopBlocks: loop.blocks),
                    continuationGotoContext: &continuationGotoContext,
                    gotoLeafDiagnostics: &gotoLeafDiagnostics, into: &lines)
                guard child.supported, child.emittedBlocks == loop.blocks else { return .unsupported }
                appendLine("\(prefix)}", kind: .instruction, to: &lines)
                return RegionEmissionResult(supported: true,
                    node: PseudocodeRegionNode(kind: .whileLoop, startLine: start, endLine: lines.count,
                        condition: "true", children: child.node.map { [$0] } ?? []),
                    emittedBlocks: child.emittedBlocks, gotoLeafCount: child.gotoLeafCount)
            }
            if let scalarContext {
                guard let loop = scalarContext.control.loops[header], loop.kind == .natural else { return .unsupported }
                let start = lines.count + 1
                appendLine("\(prefix)while (true) {", kind: .instruction,
                           source: instructions[cfg.blocks[header].startIndex].source, to: &lines)
                scalarContext.activeLoops.append(header)
                defer { _ = scalarContext.activeLoops.popLast() }
                let child = emitRegion(body, depth: depth + 1, cfg: cfg, instructions: instructions,
                    names: names, callSignaturesByTarget: callSignaturesByTarget,
                    suppressedInstructions: suppressedInstructions,
                    loopContext: LoopEmissionContext(exitTarget: loop.exit, loopBlocks: loop.members),
                    continuationGotoContext: &continuationGotoContext,
                    gotoLeafDiagnostics: &gotoLeafDiagnostics, scalarContext: scalarContext, into: &lines)
                guard child.supported, child.emittedBlocks == loop.members else { return .unsupported }
                appendLine("\(prefix)}", kind: .instruction, to: &lines)
                return RegionEmissionResult(supported: true,
                    node: PseudocodeRegionNode(kind: .whileLoop, startLine: start, endLine: lines.count,
                        condition: "true", conditionSourceAddress: instructions[cfg.blocks[header].startIndex].source.address,
                        children: child.node.map { [$0] } ?? []),
                    emittedBlocks: child.emittedBlocks, gotoLeafCount: child.gotoLeafCount)
            }
            guard let ordinaryContext, let loop = ordinaryContext.control.loops[header],
                  loop.kind == .natural,
                  emitOrdinaryFallbackLabel(header, loopEntry: true, depth: depth,
                                            context: ordinaryContext, into: &lines) else { return .unsupported }
            let start = lines.count + 1
            appendLine("\(prefix)while (true) {", kind: .instruction,
                       source: instructions[cfg.blocks[header].startIndex].source, to: &lines)
            ordinaryContext.activeLoops.append(header)
            defer { _ = ordinaryContext.activeLoops.popLast() }
            let child = emitRegion(body, depth: depth + 1, cfg: cfg, instructions: instructions,
                names: names, callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                loopContext: LoopEmissionContext(exitTarget: loop.exit, loopBlocks: loop.members),
                continuationGotoContext: &continuationGotoContext,
                gotoLeafDiagnostics: &gotoLeafDiagnostics, ordinaryContext: ordinaryContext, scalarContext: scalarContext, into: &lines)
            guard child.supported, child.emittedBlocks == loop.members else { return .unsupported }
            appendLine("\(prefix)}", kind: .instruction, to: &lines)
            return RegionEmissionResult(supported: true,
                node: PseudocodeRegionNode(kind: .whileLoop, startLine: start, endLine: lines.count,
                    condition: "true", conditionSourceAddress: instructions[cfg.blocks[header].startIndex].source.address,
                    children: child.node.map { [$0] } ?? []),
                emittedBlocks: child.emittedBlocks, gotoLeafCount: child.gotoLeafCount)

        case let .certifiedEdge(id):
            if let scalarContext {
                return emitScalarFallbackEdge(id, depth: depth, context: scalarContext,
                    names: names, into: &lines)
            }
            guard let ordinaryContext else { return .unsupported }
            return emitOrdinaryFallbackEdge(id, depth: depth, context: ordinaryContext,
                names: names, callSignaturesByTarget: callSignaturesByTarget, into: &lines)

        case let .certifiedSelection(id):
            guard let ordinaryContext, let selection = ordinaryContext.control.selections[id] else { return .unsupported }
            let leading = emitOrdinaryFallbackLeading(selection.row, depth: depth, context: ordinaryContext,
                names: names, callSignaturesByTarget: callSignaturesByTarget, into: &lines)
            guard !ordinaryContext.failed else { return .unsupported }
            let start = lines.count + 1
            var children: [PseudocodeRegionNode] = [], blocks: Set<Int> = [selection.block], gotos = 0
            let row = instructions[selection.row]
            // Discharge only the explicitly bounds-certified impossible model
            // slot. The original B.HI still emits its own physical default edge.
            let guardedDefault = selection.guardedDefault
            if let proof = guardedDefault {
                guard proof.dispatchRow == selection.row,
                      proof.origin == selection.defaultArm.edge,
                      case let .certifiedEdge(id) = selection.defaultArm.region, id == proof.slot,
                      let slot = ordinaryContext.control.edgeSlots[id],
                      slot.origins == [proof.origin], slot.phase == .copiesAndTransfer,
                      slot.commonTransferAnchor == nil,
                      slot.nearestLoopHeader == ordinaryContext.activeLoops.last,
                      (ordinaryContext.values.edgeCopies[proof.origin.cfgEdge] ?? []).isEmpty,
                      ordinaryContext.own(slot) else { return .unsupported }
            }
            let arms = selection.arms + (guardedDefault == nil ? [selection.defaultArm] : [])
            for (index, arm) in arms.enumerated() {
                // One-group selections keep a real source selector read.
                let exhaustiveLast = guardedDefault != nil && index > 0 && index == arms.count - 1
                if index < selection.arms.count && !exhaustiveLast {
                    guard let first = arm.caseValues.first else { return .unsupported }
                    var predicate = MacIRValue.binaryExpression(op: "==", left: selection.selector, right: .immediate(first))
                    for value in arm.caseValues.dropFirst() {
                        predicate = .binaryExpression(op: "||", left: predicate,
                            right: .binaryExpression(op: "==", left: selection.selector, right: .immediate(value)))
                    }
                    let condition = renderCondition(left: predicate, condition: "!=", right: .immediate(0), names: names)
                    appendLine("\(prefix)\(index == 0 ? "if" : "} else if") (\(condition)) {\(commentSuffix(for: row, callSignaturesByTarget: callSignaturesByTarget))",
                               kind: .instruction, source: row.source, to: &lines)
                } else if !selection.arms.isEmpty {
                    appendLine("\(prefix)} else {", kind: .instruction, source: row.source, to: &lines)
                }
                let child = emitRegion(arm.region, depth: depth + (selection.arms.isEmpty ? 0 : 1),
                    cfg: cfg, instructions: instructions, names: names,
                    callSignaturesByTarget: callSignaturesByTarget,
                    suppressedInstructions: suppressedInstructions, loopContext: loopContext,
                    continuationGotoContext: &continuationGotoContext,
                    gotoLeafDiagnostics: &gotoLeafDiagnostics, ordinaryContext: ordinaryContext, scalarContext: scalarContext, into: &lines)
                guard child.supported, blocks.isDisjoint(with: child.emittedBlocks) else { return .unsupported }
                blocks.formUnion(child.emittedBlocks); gotos += child.gotoLeafCount
                if let node = child.node { children.append(node) }
            }
            if !selection.arms.isEmpty { appendLine("\(prefix)}", kind: .instruction, to: &lines) }
            let node = start <= lines.count ? PseudocodeRegionNode(kind: .switchDispatch,
                startLine: start, endLine: lines.count,
                conditionSourceAddress: row.source.address, children: children) : nil
            return RegionEmissionResult(supported: true,
                node: node.map { wrappingLeadingNode(leading, around: $0) } ?? leading,
                emittedBlocks: blocks, gotoLeafCount: gotos)

        case .irreducible:
            return .unsupported
        }
    }

    private func emitGotoLeafRegion(
        _ blocks: [Int],
        depth: Int,
        cfg: CFG,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        gotoLeafDiagnostics: inout GotoLeafEmissionDiagnostics,
        continuationLabelAddresses: Set<UInt64>,
        into lines: inout [PseudocodeLine]
    ) -> RegionEmissionResult {
        guard let leafRange = contiguousInstructionRange(forGotoLeafBlocks: blocks, cfg: cfg) else {
            gotoLeafDiagnostics.record(.failedContiguity)
            return .unsupported
        }
        let blockSet = Set(blocks)
        let startLine = lines.count + 1
        emitFlat(
            leafRange,
            depth: depth,
            instructions: instructions,
            names: names,
            callSignaturesByTarget: callSignaturesByTarget,
            continuationLabelAddresses: continuationLabelAddresses,
            into: &lines
        )
        let endLine = lines.count
        guard startLine <= endLine else {
            return RegionEmissionResult(
                supported: true,
                node: nil,
                emittedBlocks: blockSet,
                gotoLeafCount: 1
            )
        }
        return RegionEmissionResult(
            supported: true,
            node: PseudocodeRegionNode(kind: .gotoLeaf, startLine: startLine, endLine: endLine),
            emittedBlocks: blockSet,
            gotoLeafCount: 1
        )
    }

    /// Every branch or switch target in the function; `emitFlat` labels each one it emits.
    private static func flatLabelTargets(_ instructions: [MacIRInstruction]) -> Set<UInt64> {
        var targets: Set<UInt64> = []
        for instruction in instructions {
            switch CFGBuilder.terminatorKind(of: instruction.operation) {
            case let .conditionalBranch(target), let .unconditionalBranch(target):
                if let target { targets.insert(target) }
            case let .switchDispatch(values): targets.formUnion(values)
            default: break
            }
        }
        return targets
    }

    /// Plan labels from the selected regions, without changing region selection.
    /// Leaf rows own their labels; ordinary block labels cover cross-region raw transfers.
    private func namesWithGotoLeafLabels(
        _ names: PseudocodeNameContext, region: Region, cfg: CFG, instructions: [MacIRInstruction]
    ) -> PseudocodeNameContext {
        if options.deadCodeElimination, Self.linearDeadCodeEliminationIsSafe(instructions) { return names }
        var leaves: [[Int]] = []
        var blocks: Set<Int> = []
        var rawBlocks: Set<Int> = []
        var continuationBlocks: Set<Int> = []
        func collect(_ region: Region, loopContext: LoopEmissionContext? = nil) {
            switch region {
            case let .sequence(items): items.forEach { collect($0, loopContext: loopContext) }
            case let .ifThen(cond, body, _, _):
                continuationBlocks.formUnion(cond.continuationGotoTargets)
                collect(body, loopContext: loopContext)
            case let .whileLoop(cond, body, header):
                continuationBlocks.formUnion(cond.continuationGotoTargets)
                collect(body, loopContext: loopEmissionContext(header: header,
                    primaryBranchIndex: cond.branchIndex, cfg: cfg))
            case let .doWhileLoop(body, cond):
                continuationBlocks.formUnion(cond.continuationGotoTargets)
                collect(body, loopContext: doWhileLoopEmissionContext(cond: cond, cfg: cfg))
            case let .naturalLoop(body, _): collect(body, loopContext: loopContext)
            case let .ifThenElse(cond, then, els, _):
                continuationBlocks.formUnion(cond.continuationGotoTargets)
                collect(then, loopContext: loopContext); collect(els, loopContext: loopContext)
            case let .gotoLeaf(items): leaves.append(items)
            case let .block(index), let .switchDispatch(index, _, _):
                blocks.insert(index)
                // A branch already represented by break owns no printed goto.
                if let loopContext, isLoopBreakBlock(index, context: loopContext, cfg: cfg, instructions: instructions) {
                    break
                }
                rawBlocks.insert(index)
            case .irreducible, .certifiedEdge, .certifiedSelection: break
            }
        }
        collect(region)
        let targets = Self.flatLabelTargets(instructions)
        var labeled = names
        var rawTargets: Set<UInt64> = []
        for items in leaves {
            guard let range = contiguousInstructionRange(forGotoLeafBlocks: items, cfg: cfg) else { continue }
            rawTargets.formUnion(Self.flatLabelTargets(Array(instructions[range])))
            for index in range where targets.contains(instructions[index].source.address) {
                labeled.gotoLeafLabelAddresses.insert(instructions[index].source.address)
            }
        }
        for block in rawBlocks where cfg.blocks.indices.contains(block) {
            let range = cfg.blocks[block].startIndex..<cfg.blocks[block].endIndex
            rawTargets.formUnion(Self.flatLabelTargets(instructions[range].filter { instruction in
                switch instruction.operation {
                case .conditionalBranch, .switchDispatch: return true
                default: return false
                }
            }))
        }
        for block in blocks.union(continuationBlocks) where cfg.blocks.indices.contains(block) {
            let address = instructions[cfg.blocks[block].startIndex].source.address
            if continuationBlocks.contains(block) {
                labeled.gotoLeafLabelAddresses.insert(address)
            } else if rawTargets.contains(address) {
                labeled.blockLabelAddresses.insert(address)
                labeled.gotoLeafLabelAddresses.insert(address)
            }
        }
        return labeled
    }

    private func gotoLeafLabelText(_ address: UInt64, names: PseudocodeNameContext) -> String {
        "L_\(String(address, radix: 16))"
    }

    /// Only an emission-owned label can be a C goto destination. Missing and
    /// external targets retain the printer's existing explicit branch intrinsic.
    private func branchTransferText(_ target: MacIRValue, names: PseudocodeNameContext) -> String {
        if let address = CFGBuilder.address(of: target), names.gotoLeafLabelAddresses.contains(address) {
            return "goto \(gotoLeafLabelText(address, names: names))"
        }
        return "__branch(\(valueText(for: target, names: names)))"
    }

    private func contiguousInstructionRange(forGotoLeafBlocks blocks: [Int], cfg: CFG) -> Range<Int>? {
        let blockSet = Set(blocks)
        guard !blockSet.isEmpty, blockSet.count == blocks.count else { return nil }
        guard blockSet.allSatisfy({ $0 >= 0 && $0 < cfg.blocks.count }) else { return nil }

        let sortedBlocks = blockSet
            .map { cfg.blocks[$0] }
            .sorted { lhs, rhs in
                if lhs.startIndex == rhs.startIndex { return lhs.endIndex < rhs.endIndex }
                return lhs.startIndex < rhs.startIndex
            }
        guard let first = sortedBlocks.first else { return nil }
        var cursor = first.startIndex
        let lowerBound = cursor
        for block in sortedBlocks {
            guard block.startIndex == cursor, block.endIndex > block.startIndex else { return nil }
            cursor = block.endIndex
        }
        let range = lowerBound..<cursor
        let coveredBlocks = Set(
            cfg.blocks
                .filter { $0.instructionRange.overlaps(range) }
                .map(\.index)
        )
        guard coveredBlocks == blockSet else { return nil }
        return range
    }

    private func emitBlockRegion(
        _ blockIndex: Int,
        kind: PseudocodeRegionNode.Kind,
        depth: Int,
        cfg: CFG,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        suppressedInstructions: Set<Int>,
        loopContext: LoopEmissionContext?,
        continuationGotoContext: inout ContinuationGotoEmissionContext,
        into lines: inout [PseudocodeLine]
    ) -> RegionEmissionResult {
        let startLine = lines.count + 1
        let targetAddress = continuationGotoContext.targetAddress(
            for: blockIndex,
            cfg: cfg,
            instructions: instructions
        )
        let labelLineCount: Int?
        let blockAddress = instructions[cfg.blocks[blockIndex].startIndex].source.address
        if targetAddress == nil, names.blockLabelAddresses.contains(blockAddress) {
            appendLine("\(addressLabelText(blockAddress, names: names)):;", kind: .instruction, to: &lines)
        }
        if let targetAddress {
            appendLine("\(addressLabelText(targetAddress, names: names)):", kind: .instruction, to: &lines)
            continuationGotoContext.recordEmittedLabel(address: targetAddress)
            labelLineCount = lines.count
        } else {
            labelLineCount = nil
        }
        let emitted: Bool
        if let loopContext, isLoopBreakBlock(blockIndex, context: loopContext, cfg: cfg, instructions: instructions) {
            emitted = emitLoopBreakBlock(
                blockIndex,
                depth: depth,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                context: loopContext,
                into: &lines
            )
        } else {
            emitted = emitBlock(
                blockIndex,
                depth: depth,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                into: &lines
            )
        }
        guard emitted else {
            return .unsupported
        }
        if let targetAddress, let labelLineCount, lines.count == labelLineCount {
            continuationGotoContext.recordInvalidStatementBoundary(address: targetAddress)
        }
        let endLine = lines.count
        guard startLine <= endLine else {
            return RegionEmissionResult(
                supported: true,
                node: nil,
                emittedBlocks: [blockIndex],
                gotoLeafCount: 0
            )
        }
        return RegionEmissionResult(
            supported: true,
            node: PseudocodeRegionNode(kind: kind, startLine: startLine, endLine: endLine),
            emittedBlocks: [blockIndex],
            gotoLeafCount: 0
        )
    }

    private func isLoopBreakBlock(
        _ blockIndex: Int,
        context: LoopEmissionContext,
        cfg: CFG,
        instructions: [MacIRInstruction]
    ) -> Bool {
        guard context.loopBlocks.contains(blockIndex) else { return false }
        let block = cfg.blocks[blockIndex]
        guard block.endIndex > block.startIndex else { return false }
        let terminator = CFGBuilder.terminatorKind(of: instructions[block.endIndex - 1].operation)
        switch terminator {
        case .unconditionalBranch:
            return block.successors.first == context.exitTarget
        case .conditionalBranch:
            guard block.successors.count == 2,
                  block.successors.contains(context.exitTarget) else { return false }
            let takenTarget = block.successors[0]
            let fallThrough = block.successors[1]
            if takenTarget == context.exitTarget {
                return context.loopBlocks.contains(fallThrough)
            }
            if fallThrough == context.exitTarget {
                return context.loopBlocks.contains(takenTarget)
            }
            return false
        default:
            return false
        }
    }

    private func emitLoopBreakBlock(
        _ blockIndex: Int,
        depth: Int,
        cfg: CFG,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        suppressedInstructions: Set<Int>,
        context: LoopEmissionContext,
        into lines: inout [PseudocodeLine]
    ) -> Bool {
        let prefix = indent(depth)
        let block = cfg.blocks[blockIndex]
        let terminatorIndex = block.endIndex - 1
        let terminator = CFGBuilder.terminatorKind(of: instructions[terminatorIndex].operation)
        switch terminator {
        case .unconditionalBranch:
            guard block.successors.first == context.exitTarget else { return false }
            guard emitBlock(
                blockIndex,
                depth: depth,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                suppressedInstructions: suppressedInstructions,
                into: &lines
            ) else {
                return false
            }
            appendLine("\(prefix)break;", kind: .instruction, source: instructions[terminatorIndex].source, to: &lines)
            return true

        case .conditionalBranch:
            let successors = block.successors
            guard successors.count == 2,
                  let cond = branchCondition(for: blockIndex, cfg: cfg, instructions: instructions) else {
                return false
            }
            let takenTarget = successors[0]
            let fallThrough = successors[1]
            let breaksOnTaken: Bool
            if takenTarget == context.exitTarget, context.loopBlocks.contains(fallThrough) {
                breaksOnTaken = true
            } else if fallThrough == context.exitTarget, context.loopBlocks.contains(takenTarget) {
                breaksOnTaken = false
            } else {
                return false
            }

            emitBranchBlockLeadingStatements(
                cond: cond,
                depth: depth,
                cfg: cfg,
                instructions: instructions,
                names: names,
                callSignaturesByTarget: callSignaturesByTarget,
                into: &lines
            )
            let branchInstruction = instructions[cond.branchIndex]
            let conditionText = breaksOnTaken
                ? rawConditionText(for: cond, names: names)
                : invertedConditionText(for: cond, names: names)
            appendLine(
                "\(prefix)if (\(conditionText)) {\(commentSuffix(for: branchInstruction, callSignaturesByTarget: callSignaturesByTarget))",
                kind: .instruction,
                source: branchInstruction.source,
                to: &lines
            )
            appendLine("\(indent(depth + 1))break;", kind: .instruction, to: &lines)
            appendLine("\(prefix)}", kind: .instruction, to: &lines)
            return true

        default:
            return false
        }
    }

    private func emitBranchBlockLeadingStatementsNode(
        cond: BranchCondition,
        depth: Int,
        cfg: CFG,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) -> PseudocodeRegionNode? {
        let startLine = lines.count + 1
        emitBranchBlockLeadingStatements(
            cond: cond,
            depth: depth,
            cfg: cfg,
            instructions: instructions,
            names: names,
            callSignaturesByTarget: callSignaturesByTarget,
            into: &lines
        )
        let endLine = lines.count
        guard startLine <= endLine else { return nil }
        return PseudocodeRegionNode(kind: .block, startLine: startLine, endLine: endLine)
    }

    private func wrappingLeadingNode(
        _ leadingNode: PseudocodeRegionNode?,
        around constructNode: PseudocodeRegionNode
    ) -> PseudocodeRegionNode {
        guard let leadingNode else { return constructNode }
        return PseudocodeRegionNode(
            kind: .sequence,
            startLine: leadingNode.startLine,
            endLine: constructNode.endLine,
            children: [leadingNode, constructNode]
        )
    }

    /// Emits the instructions of the branch block that precede the suppressed
    /// compare + conditional branch consumed by a structured header. In the
    /// supported idioms the block is exactly `[compare, branch]` or `[branch]`,
    /// so this emits nothing; it stays correct for blocks with leading work.
    private func emitBranchBlockLeadingStatements(
        cond: BranchCondition,
        depth: Int,
        cfg: CFG,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        into lines: inout [PseudocodeLine]
    ) {
        guard let blockIndex = blockContaining(instructionIndex: cond.branchIndex, cfg: cfg) else { return }
        let block = cfg.blocks[blockIndex]
        let firstSuppressed = cond.compareIndex ?? cond.branchIndex
        guard firstSuppressed > block.startIndex else { return }
        // Reuse the common statement emitter, including intra-block folds.
        emitRows(
            block.startIndex..<firstSuppressed,
            depth: depth,
            instructions: instructions,
            names: names,
            callSignaturesByTarget: callSignaturesByTarget,
            into: &lines
        )
    }

    private func blockContaining(instructionIndex: Int, cfg: CFG) -> Int? {
        for block in cfg.blocks where block.instructionRange.contains(instructionIndex) {
            return block.index
        }
        return nil
    }

    private func loopEmissionContext(header: Int, primaryBranchIndex: Int? = nil, cfg: CFG) -> LoopEmissionContext? {
        let tails = cfg.backEdges.filter { $0.to == header }.map { $0.from }
        guard tails.count == 1, let latch = tails.first else { return nil }
        let loopBlocks = naturalLoopBody(header: header, latch: latch, cfg: cfg)
        if let primaryBranchIndex,
           let branchBlock = blockContaining(instructionIndex: primaryBranchIndex, cfg: cfg) {
            let branchExits = cfg.blocks[branchBlock].successors.filter { !loopBlocks.contains($0) }
            if branchExits.count == 1, let exitTarget = branchExits.first {
                return LoopEmissionContext(exitTarget: exitTarget, loopBlocks: loopBlocks)
            }
        }
        let exits = loopExitTargets(loopBlocks: loopBlocks, cfg: cfg)
        guard exits.count == 1, let exitTarget = exits.first else { return nil }
        return LoopEmissionContext(exitTarget: exitTarget, loopBlocks: loopBlocks)
    }

    private func doWhileLoopEmissionContext(cond: BranchCondition, cfg: CFG) -> LoopEmissionContext? {
        guard let latch = blockContaining(instructionIndex: cond.branchIndex, cfg: cfg),
              let header = cfg.backEdges.first(where: { $0.from == latch })?.to else {
            return nil
        }
        return loopEmissionContext(header: header, primaryBranchIndex: cond.branchIndex, cfg: cfg)
    }

    private func naturalLoopBody(header: Int, latch: Int, cfg: CFG) -> Set<Int> {
        var body: Set<Int> = [header]
        var stack = [latch]
        while let block = stack.popLast() {
            if body.contains(block) { continue }
            body.insert(block)
            for pred in cfg.blocks[block].predecessors where pred != header {
                stack.append(pred)
            }
        }
        return body
    }

    private func loopExitTargets(loopBlocks: Set<Int>, cfg: CFG) -> Set<Int> {
        var exits: Set<Int> = []
        for block in loopBlocks {
            for succ in cfg.blocks[block].successors where !loopBlocks.contains(succ) {
                exits.insert(succ)
            }
        }
        return exits
    }

    private func branchCondition(for block: Int, cfg: CFG, instructions: [MacIRInstruction]) -> BranchCondition? {
        if let condition = RegionTree.syntheticPhiLatchCondition(test: block, cfg: cfg, instructions: instructions) {
            return condition
        }
        let branchIndex = cfg.blocks[block].endIndex - 1
        guard case let .conditionalBranch(condition, left, right, _) = instructions[branchIndex].operation else {
            return nil
        }
        let mnemonic = instructions[branchIndex].source.mnemonic.lowercased()
        let isZeroCheck = mnemonic == "cbz" || mnemonic == "cbnz" || mnemonic == "tbz" || mnemonic == "tbnz"
        if isZeroCheck {
            return BranchCondition(
                branchIndex: branchIndex,
                compareIndex: nil,
                left: left,
                condition: condition,
                right: right,
                isZeroCheck: true
            )
        }
        let compareIndex = branchIndex - 1
        if compareIndex >= cfg.blocks[block].startIndex,
           case let .intrinsic(_, name, arguments) = instructions[compareIndex].operation,
           name == "compare",
           arguments.count == 2,
           instructions[compareIndex].source.address.isContiguous(to: instructions[branchIndex].source.address),
           arguments[0] == MacIRBuilder.droppingSignedProjection(left),
           arguments[1] == MacIRBuilder.droppingSignedProjection(right) {
            return BranchCondition(
                branchIndex: branchIndex,
                compareIndex: compareIndex,
                left: left,
                condition: condition,
                right: right,
                isZeroCheck: false
            )
        }
        return nil
    }

    /// Emits the instructions of a single basic block by delegating to the
    /// shared statement emitter (so intra-block folds — returned-call,
    /// compare-to-bool, global-address, switch — render byte-identically). A
    /// trailing suppressed instruction (a back-edge `b` folded into a loop) is
    /// excluded from the emitted range.
    private func emitBlock(
        _ blockIndex: Int,
        depth: Int,
        cfg: CFG,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        suppressedInstructions: Set<Int>,
        into lines: inout [PseudocodeLine]
    ) -> Bool {
        let block = cfg.blocks[blockIndex]
        var end = block.endIndex
        // Drop a trailing suppressed back-edge branch from the emitted range.
        if end - 1 >= block.startIndex, suppressedInstructions.contains(end - 1) {
            end -= 1
        }
        guard end > block.startIndex else { return true }
        emitRows(
            block.startIndex..<end,
            depth: depth,
            instructions: instructions,
            names: names,
            callSignaturesByTarget: callSignaturesByTarget,
            into: &lines
        )
        return true
    }

    /// The C `if (...)`-guard condition text: the INVERTED branch condition
    /// (entering the structured body is the negation of "branch taken").
    private func invertedConditionText(for cond: BranchCondition, names: PseudocodeNameContext) -> String {
        guard let inverted = invertedBranchCondition(cond.condition) else {
            return rawConditionText(for: cond, names: names)
        }
        if cond.isZeroCheck {
            return renderZeroCheckCondition(left: cond.left, condition: inverted, right: cond.right, names: names)
        }
        return renderCondition(left: cond.left, condition: inverted, right: cond.right, names: names)
    }

    /// The RAW (non-inverted) branch condition text — used for do-while back-edges.
    private func rawConditionText(for cond: BranchCondition, names: PseudocodeNameContext) -> String {
        if cond.isZeroCheck {
            return renderZeroCheckCondition(left: cond.left, condition: cond.condition, right: cond.right, names: names)
        }
        return renderCondition(left: cond.left, condition: cond.condition, right: cond.right, names: names)
    }

    public func print<RowSequence: Sequence>(
        functionName: String,
        startAddress: UInt64? = nil,
        jumpTables: [UInt64: [UInt64]] = [:],
        objcSelectors: [UInt64: String] = [:],
        constantStrings: [UInt64: MacIRConstantString] = [:],
        nameOverrides: [String: String] = [:],
        signatureOverrides: [UInt64: FunctionSignatureOverride] = [:],
        authoredCallSignaturesByTarget: [String: FunctionSignatureOverride] = [:],
        directCallVoidResultTargets: [String: FunctionSignatureOverride] = [:],
        machineCallUsage: MacIRMachineCallUsage? = nil,
        machineUsageContext: MacIRMachineUsageContext? = nil,
        ownDirectCallAddresses: Set<UInt64> = [],
        knownTailCallTargets: [UInt64: String] = [:],
        registerNameOverrides: [String: String] = [:],
        stackLocalOverrides: [String: StackLocalOverride] = [:],
        resolvedIndirectCalls: [UInt64: PseudocodeIndirectCall] = [:],
        slotCallContracts: [UInt64: FunctionPointerSignatureV1] = [:],
        callerReturnWidth: MacIRCallerReturnEvidence.Width? = nil,
        callerReturnType: String? = nil,
        types: [TypeDefinition] = [],
        instructions rows: RowSequence
    ) -> PseudocodeDocument where RowSequence.Element: DecompilerInstructionRow {
        let function = buildFunction(
            functionName: functionName,
            startAddress: startAddress,
            jumpTables: jumpTables,
            objcSelectors: objcSelectors,
            constantStrings: constantStrings,
            signatureOverrides: signatureOverrides,
            authoredCallSignaturesByTarget: authoredCallSignaturesByTarget,
            directCallVoidResultTargets: directCallVoidResultTargets,
            machineCallUsage: machineCallUsage,
            machineUsageContext: machineUsageContext,
            knownTailCallTargets: knownTailCallTargets,
            slotCallContracts: slotCallContracts,
            callerReturnWidth: callerReturnWidth,
            callerReturnType: callerReturnType,
            types: types,
            instructions: rows
        )
        return print(
            function: function,
            ownDirectCallAddresses: ownDirectCallAddresses,
            types: types,
            nameOverrides: nameOverrides,
            registerNameOverrides: registerNameOverrides,
            stackLocalOverrides: stackLocalOverrides,
            resolvedIndirectCalls: resolvedIndirectCalls
        )
    }

    /// Reconstruction-only output fence. Existing document/UI rendering remains unlimited and
    /// byte-identical; this overload stops the linear emitter as soon as the joined UTF-8 budget
    /// is exhausted, so a later payload trim never follows an unbounded rendered document.
    func printBoundedText<RowSequence: Sequence>(
        functionName: String,
        startAddress: UInt64? = nil,
        jumpTables: [UInt64: [UInt64]] = [:],
        objcSelectors: [UInt64: String] = [:],
        constantStrings: [UInt64: MacIRConstantString] = [:],
        nameOverrides: [String: String] = [:],
        signatureOverrides: [UInt64: FunctionSignatureOverride] = [:],
        authoredCallSignaturesByTarget: [String: FunctionSignatureOverride] = [:],
        directCallVoidResultTargets: [String: FunctionSignatureOverride] = [:],
        machineCallUsage: MacIRMachineCallUsage? = nil,
        machineUsageContext: MacIRMachineUsageContext? = nil,
        ownDirectCallAddresses: Set<UInt64> = [],
        knownTailCallTargets: [UInt64: String] = [:],
        registerNameOverrides: [String: String] = [:],
        stackLocalOverrides: [String: StackLocalOverride] = [:],
        types: [TypeDefinition] = [],
        instructions rows: RowSequence,
        maximumUTF8Bytes: Int
    ) -> PseudocodeBoundedText where RowSequence.Element: DecompilerInstructionRow {
        let state = PseudocodeBoundedEmissionState(maximumUTF8Bytes: maximumUTF8Bytes)
        var printer = Self(options: options, boundedEmissionState: state)
        #if DEBUG
        printer.renderCapture = renderCapture
        #endif
        let document = printer.print(
            functionName: functionName,
            startAddress: startAddress,
            jumpTables: jumpTables,
            objcSelectors: objcSelectors,
            constantStrings: constantStrings,
            nameOverrides: nameOverrides,
            signatureOverrides: signatureOverrides,
            authoredCallSignaturesByTarget: authoredCallSignaturesByTarget,
            directCallVoidResultTargets: directCallVoidResultTargets,
            machineCallUsage: machineCallUsage,
            machineUsageContext: machineUsageContext,
            ownDirectCallAddresses: ownDirectCallAddresses,
            knownTailCallTargets: knownTailCallTargets,
            registerNameOverrides: registerNameOverrides,
            stackLocalOverrides: stackLocalOverrides,
            types: types,
            instructions: rows
        )
        return PseudocodeBoundedText(
            text: document.text,
            wasTruncated: state.wasTruncated,
            emittedLineCount: state.emittedLineCount
        )
    }

    /// Builds the same post-override MacIR consumed by `print`, without
    /// rendering it. Candidate audit producers use this seam so body-use facts
    /// come from typed argument nodes rather than parsing pseudocode text.
    func buildFunction<RowSequence: Sequence>(
        functionName: String,
        startAddress: UInt64? = nil,
        jumpTables: [UInt64: [UInt64]] = [:],
        objcSelectors: [UInt64: String] = [:],
        constantStrings: [UInt64: MacIRConstantString] = [:],
        signatureOverrides: [UInt64: FunctionSignatureOverride] = [:],
        authoredCallSignaturesByTarget: [String: FunctionSignatureOverride] = [:],
        directCallVoidResultTargets: [String: FunctionSignatureOverride] = [:],
        machineCallUsage: MacIRMachineCallUsage? = nil,
        machineUsageContext: MacIRMachineUsageContext? = nil,
        knownTailCallTargets: [UInt64: String] = [:],
        slotCallContracts: [UInt64: FunctionPointerSignatureV1] = [:],
        callerReturnWidth: MacIRCallerReturnEvidence.Width? = nil,
        callerReturnType: String? = nil,
        types: [TypeDefinition] = [],
        explicitCFGEnabled: Bool? = nil,
        ssaEnabled: Bool? = nil,
        instructions rows: RowSequence
    ) -> MacIRFunction where RowSequence.Element: DecompilerInstructionRow {
        let signature = startAddress.flatMap { signatureOverrides[$0] }
        let resolver = TypeAtlasDarwinARM64LayoutResolver(
            catalog: Dictionary(types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        )
        let authoritativeParameterPlan = signature.flatMap {
            Self.authoritativeParameterPlan(for: $0, resolver: resolver)
        }
        let materializedRows = Array(rows)
        let rowsByAddress = Dictionary(materializedRows.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        var admittedSlotSignatures: [UInt64: MacIRCallSignature] = [:]
        for (address, contract) in slotCallContracts {
            guard let row = rowsByAddress[address],
                  let register = row.operands.split(separator: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let signature = SlotTypedPrototypeBinding.callSignature(
                    contract: contract, target: "(*\(register))", types: types) else { continue }
            admittedSlotSignatures[address] = signature
        }
        let function = MacIRBuilder(explicitCFGEnabled: explicitCFGEnabled, ssaEnabled: ssaEnabled).buildFunction(
            name: functionName,
            startAddress: startAddress,
            jumpTables: jumpTables,
            objcSelectors: objcSelectors,
            constantStrings: constantStrings,
            authoritativeParameterPlan: authoritativeParameterPlan,
            authoritativeReturnLocation: (signature?.returnType ?? callerReturnType).map {
                Self.admittedReturnLocation(for: $0, resolver: resolver)
            },
            authoritativeReturnType: signature?.returnType ?? callerReturnType,
            callerReturnWidth: callerReturnWidth,
            authoredCallSignaturesByTarget: authoredCallSignaturesByTarget,
            directCallVoidResultTargets: directCallVoidResultTargets,
            machineCallUsage: machineCallUsage,
            machineUsageContext: machineUsageContext,
            slotCallContracts: slotCallContracts,
            slotCallSignatures: admittedSlotSignatures,
            richTypeResolver: resolver,
            knownTailCallTargets: knownTailCallTargets,
            instructions: materializedRows
        )
        return RegionalLexicalProof.projecting(function) { original in
            var result = original
            // Caller return evidence changes only the header after ABI lifting.
            if signature?.returnType == nil, let callerReturnType {
                result.returnType = callerReturnType
            }
            if let signature { result = Self.applying(signature, to: result) }
            return result
        }
    }

    private static func admittedReturnLocation(
        for type: String,
        resolver: any DarwinARM64TypeLayoutResolving
    ) -> DarwinARM64RichReturnLocation {
        let location = DarwinARM64ParameterBinder.returnLocation(for: type, resolver: resolver)
        guard case let .composite(pieces) = location else { return location }
        if [2, 4].contains(pieces.count),
           pieces.allSatisfy({ if case .simd(_, 64) = $0.register { return $0.size == 8 }; return false }) {
            return location
        }
        if DarwinARM64ParameterBinder.isSupportedDirectGPRStruct(type, pieces: pieces, resolver: resolver) {
            return location
        }
        return .unbound(reason: .unsupportedType(type))
    }

    /// Converts an active authored declaration into the pre-lift parameter plan.
    /// An unspecified list intentionally returns nil so ordinary recovery remains
    /// active. Source position is array order; persisted row tokens remain opaque.
    private static func authoritativeParameterPlan(
        for signature: FunctionSignatureOverride,
        resolver: any DarwinARM64TypeLayoutResolving
    ) -> MacIRAuthoritativeParameterPlan? {
        guard case let .authoritative(rows) = signature.parameterList else {
            return nil
        }

        let rowTokens = rows.map(\.rowToken)
        guard rowTokens.allSatisfy({ !$0.isEmpty }),
              Set(rowTokens).count == rowTokens.count else {
            return nil
        }

        let locations = DarwinARM64ParameterBinder.bindRich(
            parameterTypes: rows.map(\.type),
            isVariadic: signature.variadicState == .variadic,
            resolver: resolver
        )
        guard locations.count == rows.count else { return nil }

        var parameters: [MacIRFunctionParameter] = []
        parameters.reserveCapacity(rows.count)
        for (sourcePosition, pair) in zip(rows, locations).enumerated() {
            let (row, richLocation) = pair
            let location: MacIRABIParameterLocation
            let supportedRichLocation: DarwinARM64RichParameterLocation?
            switch richLocation {
            case let .gpr(index, width):
                location = .gpr(index: index, carrierWidth: width)
                supportedRichLocation = nil
            case let .simd(index, width):
                location = .simd(index: index, scalarWidth: width)
                supportedRichLocation = nil
            case .entryStack where resolver.resolveLayout(ofType: row.type)?.kind == .aggregate:
                // DP01 #597: the scalar plan has no byte-fragment model for a
                // stack-passed aggregate, so it abstains instead of binding the
                // whole object as one integer argument.
                location = .unbound(reason: .unsupportedType(row.type))
                supportedRichLocation = nil
            case let .entryStack(offset, size, alignment):
                location = .entryStack(byteOffset: offset, size: size, alignment: alignment)
                supportedRichLocation = nil
            case let .composite(pieces) where [2, 4].contains(pieces.count)
                && pieces.allSatisfy({ if case .simd(_, 64) = $0.register { return $0.size == 8 }; return false }):
                location = .unbound(reason: .unsupportedType(row.type))
                supportedRichLocation = richLocation
            case let .composite(pieces) where DarwinARM64ParameterBinder.isSupportedDirectGPRStruct(
                row.type, pieces: pieces, resolver: resolver
            ):
                location = .unbound(reason: .unsupportedType(row.type))
                supportedRichLocation = richLocation
            case .composite, .indirect:
                location = .unbound(reason: .unsupportedType(row.type))
                supportedRichLocation = nil
            case let .unbound(reason):
                location = .unbound(reason: reason)
                supportedRichLocation = nil
            }
            let bindingID: MacIRParameterBindingID?
            switch location {
            case .gpr, .simd:
                bindingID = location.bindingID
            case .entryStack, .unbound:
                bindingID = nil
            }
            let evidence: MacIRParameterEvidence
            switch row.provenance {
            case .debug:
                evidence = .authoritativeDebug
            case .user, .script, .legacy:
                // A legacy row reaches the active list only after safe migration
                // or explicit adoption; ambiguous legacy rows remain quarantined.
                evidence = .authoritativeUser
            }

            guard let parameter = MacIRFunctionParameter(
                id: MacIRParameterRowID(rawValue: row.rowToken),
                bindingID: bindingID,
                sourcePosition: sourcePosition,
                abiLocation: location,
                richLocation: supportedRichLocation,
                type: row.type,
                name: row.name,
                evidence: evidence
            ) else {
                return nil
            }
            parameters.append(parameter)
        }

        return MacIRAuthoritativeParameterPlan(
            parameters: parameters,
            isVariadic: signature.variadicState == .variadic
        )
    }

    /// Applies the declaration fields that do not participate in body lifting.
    /// Parameter identity was installed through the pre-lift authoritative plan;
    /// replacing it here would erase recovered inputs for an unspecified list.
    static func applying(_ signature: FunctionSignatureOverride, to function: MacIRFunction) -> MacIRFunction {
        var function = function
        if let returnType = signature.returnType, !returnType.isEmpty {
            function.returnType = returnType
        }
        switch signature.variadicState {
        case .unspecified:
            break
        case .fixed:
            function.isVariadic = false
        case .variadic:
            function.isVariadic = true
        }
        switch signature.noReturnState {
        case .unspecified:
            break
        case .returns:
            function.isNoReturn = false
        case .noReturn:
            function.isNoReturn = true
        }
        return function
    }

    // Presentation-only. Nothing here changes the function or a regional proof.
    private struct TSTASRStatementLocalCertificate {
        let producerIndex: Int
        let consumerIndex: Int
        let producer: MacIRInstruction
        let consumer: MacIRInstruction
        let name: String
        let initializer: MacIRValue
        let replacement: MacIROperation
        let branch: BranchCondition?
        let inverted: Bool
    }

    private static func tstASRWord(_ source: MacIRSourceSpan) -> UInt32? {
        let parts = source.byteText.split(separator: " ")
        guard parts.count == 4, source.syntheticPhiEdge == nil,
              source.tailCallEffect == nil else { return nil }
        var result: UInt32 = 0
        for (i, part) in parts.enumerated() {
            guard part.utf8.count == 2,
                  part.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let byte = UInt8(part, radix: 16) else { return nil }
            result |= UInt32(byte) << UInt32(8 * i)
        }
        return result
    }

    private static func tstASRIdentifiers(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init))
    }

    private func tstASRPureWord(_ value: MacIRValue, register: UInt32,
                               function: MacIRFunction, names: PseudocodeNameContext) -> Bool {
        // No argument fragments, memory expressions, calls or textual expressions.
        // Refusing an unproved shape is preferable to duplicating an effect.
        guard case let .register(name, version) = value,
              name == "w\(register)", register < 31,
              !function.nameBindings.contains(where: { binding in
                  guard binding.target == .register(name: name, version: version),
                        let type = binding.type else { return false }
                  return !["uint32_t", "int32_t", "uint64_t", "int64_t"].contains(type)
              }),
              let type = printedScalarType(of: value, names: names),
              ["uint32_t", "int32_t", "uint64_t", "int64_t"].contains(type),
              emittedPointerType(for: value, names: names) == nil else { return false }
        let text = valueText(for: value, names: names)
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // Text and bytes independently agree on the consumer and its alias condition.
    private static func tstASRConsumerRelation(_ source: MacIRSourceSpan) -> String? {
        guard let word = tstASRWord(source) else { return nil }
        let suffixes = ["eq", "ne", "hs", "lo", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"]
        let relations = ["ge": ">=", "lt": "<", "gt": ">", "le": "<="]
        if word & 0xff00_0010 == 0x5400_0000 {
            let suffix = suffixes[Int(word & 15)]
            guard source.mnemonic == "b.\(suffix)", let relation = relations[suffix] else { return nil }
            let raw = Int64((word >> 5) & 0x7ffff)
            let delta = (raw >= 0x40000 ? raw - 0x80000 : raw) * 4
            let target = source.address &+ UInt64(bitPattern: delta)
            guard source.operands == target.hexAddress else { return nil }
            return relation
        }
        guard word & 0x1fe0_0000 == 0x1a80_0000, word & 0x2000_0000 == 0 else { return nil }
        let is64 = word & 0x8000_0000 != 0
        func reg(_ n: UInt32) -> String { n == 31 ? (is64 ? "xzr" : "wzr") : "\(is64 ? "x" : "w")\(n)" }
        let rd = word & 31, rn = (word >> 5) & 31, rm = (word >> 16) & 31
        let op = (word >> 30) & 1, op2 = (word >> 10) & 3
        let code = Int((word >> 12) & 15)
        guard code < 14 else { return nil }
        let inverse = suffixes[code ^ 1]
        var mnemonic: String
        var operands: String
        if rn == rm, op == 0, op2 == 1 {
            mnemonic = rn == 31 ? "cset" : "cinc"
            operands = rn == 31 ? "\(reg(rd)), \(inverse)" : "\(reg(rd)), \(reg(rn)), \(inverse)"
        } else if rn == rm, op == 1, op2 == 0 {
            mnemonic = rn == 31 ? "csetm" : "cinv"
            operands = rn == 31 ? "\(reg(rd)), \(inverse)" : "\(reg(rd)), \(reg(rn)), \(inverse)"
        } else if rn == rm, op == 1, op2 == 1 {
            mnemonic = "cneg"; operands = "\(reg(rd)), \(reg(rn)), \(inverse)"
        } else {
            switch (op, op2) {
            case (0, 0): mnemonic = "csel"
            case (0, 1): mnemonic = "csinc"
            case (1, 0): mnemonic = "csinv"
            case (1, 1): mnemonic = "csneg"
            default: return nil
            }
            operands = "\(reg(rd)), \(reg(rn)), \(reg(rm)), \(suffixes[code])"
        }
        guard source.mnemonic == mnemonic, source.operands == operands else { return nil }
        // The retained lifter implements these aliases with an inverted select.
        let relationCode = mnemonic == "cset" ? code ^ 1 : code
        return relations[suffixes[relationCode]]
    }

    private static func tstASRFlagsDie(after index: Int, cfg: CFG,
                                      instructions: [MacIRInstruction]) -> Bool {
        guard !cfg.hasUnresolvedTargets else { return false }
        var visited: Set<Int> = [], active: Set<Int> = [], blocks: Set<Int> = []
        func visit(_ i: Int) -> Bool {
            guard instructions.indices.contains(i),
                  let block = cfg.blocks.first(where: { $0.instructionRange.contains(i) }) else { return false }
            if active.contains(i) { return false } // a non-closing cycle is not proof
            if visited.contains(i) { return true }
            guard visited.count < 64 else { return false }
            blocks.insert(block.index)
            guard blocks.count <= 16 else { return false }
            visited.insert(i); active.insert(i); defer { active.remove(i) }
            let row = instructions[i]
            guard let word = tstASRWord(row.source) else { return false }
            if word == 0xd65f_03c0, row.source.mnemonic == "ret",
               case .returnValue = row.operation { return true }
            // Exact CMP W immediate is a full NZCV writer; no generic unknown
            // or partial writer is credited. Other full writers may be refused.
            if word & 0xff80_001f == 0x7100_001f, row.source.mnemonic == "cmp",
               case .intrinsic(nil, "compare", _) = row.operation { return true }
            // Only NOP and resolved immediate B are admitted before closure.
            // This conservative whitelist excludes every reader, call and unknown.
            let neutral: Bool
            switch row.operation {
            case let .intrinsic(nil, "nop", arguments):
                neutral = arguments.isEmpty && word == 0xd503_201f && row.source.mnemonic == "nop"
            case let .intrinsic(nil, "branch", arguments):
                let raw = Int64(word & 0x03ff_ffff)
                let delta = (raw >= 0x0200_0000 ? raw - 0x0400_0000 : raw) * 4
                let target = row.source.address &+ UInt64(bitPattern: delta)
                neutral = word & 0xfc00_0000 == 0x1400_0000 && row.source.mnemonic == "b"
                    && row.source.operands == target.hexAddress
                    && arguments == [.immediate(Int64(bitPattern: target))]
            default: neutral = false
            }
            guard neutral else { return false }
            if i + 1 < block.endIndex { return visit(i + 1) }
            guard !block.successors.isEmpty else { return false }
            return block.successors.allSatisfy { successor in
                cfg.blocks.indices.contains(successor) && visit(cfg.blocks[successor].startIndex)
            }
        }
        guard let block = cfg.blocks.first(where: { $0.instructionRange.contains(index) }) else { return false }
        if index + 1 < block.endIndex { return visit(index + 1) }
        guard !block.successors.isEmpty else { return false }
        return block.successors.allSatisfy { successor in
            cfg.blocks.indices.contains(successor) && visit(cfg.blocks[successor].startIndex)
        }
    }

    private func tstASRStatementLocals(
        function: MacIRFunction, region: Region, cfg: CFG,
        instructions: [MacIRInstruction], names: PseudocodeNameContext,
        callSignaturesByTarget: [String: MacIRCallSignature],
        lines: [PseudocodeLine], node: PseudocodeRegionNode
    ) -> (lines: [PseudocodeLine], node: PseudocodeRegionNode)? {
        guard names.allowsTSTASRStatementLocals, !function.ssaEnabled,
              boundedEmissionState == nil, emissionCancellation == nil,
              names.blockLabelAddresses.isEmpty, names.gotoLeafLabelAddresses.isEmpty,
              !cfg.hasUnresolvedTargets else { return nil }
        guard instructions.contains(where: {
            guard let word = Self.tstASRWord($0.source) else { return false }
            return word & 0xffe0_801f == 0x6a80_001f && ((word >> 10) & 31) != 0
        }) else { return nil }
        // Only ordinary braced blocks and simple ifThen headers have slots.
        // Reject the entire plan on loops/switch/goto/fusion rather than infer
        // placement from indentation or add another emitter route.
        var slots: [Int: (BranchCondition?, Bool)] = [:]
        func collect(_ region: Region) -> Bool {
            switch region {
            case let .sequence(children): return children.allSatisfy(collect)
            case let .block(index):
                guard cfg.blocks.indices.contains(index) else { return false }
                for i in cfg.blocks[index].instructionRange { slots[i] = (nil, false) }
                return true
            case let .ifThen(cond, body, _, inverted):
                guard case .block = body, cond.continuationGotoTargets.isEmpty,
                      let compare = cond.compareIndex, compare + 1 == cond.branchIndex else { return false }
                slots[cond.branchIndex] = (cond, inverted)
                return collect(body)
            default: return false
            }
        }
        guard collect(region) else { return nil }
        let groups = Dictionary(grouping: instructions.indices, by: { instructions[$0].source.address })
        guard groups.count == instructions.count else { return nil }
        var inventory = Set<String>()
        func reserve(_ text: String) { inventory.formUnion(Self.tstASRIdentifiers(text)) }
        lines.forEach { reserve($0.text) }
        reserve(function.name)
        function.localVariables.forEach { reserve($0.name) }
        function.parameters.forEach { reserve($0.name) }
        function.nameBindings.forEach { reserve($0.name) }
        names.registerNameOverrides.forEach { reserve($0.key); reserve($0.value) }
        names.registerNamesByValue.values.forEach(reserve)
        names.argumentNames.values.forEach(reserve)
        names.callTargetRenames.forEach { reserve($0.key); reserve($0.value) }
        // Includes hidden/elided symbol references; no translation-unit claim.
        instructions.forEach { reserve(render(instruction: $0, names: names)) }
        reserve("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary _Noreturn _Static_assert _Thread_local")
        var certificates: [TSTASRStatementLocalCertificate] = []
        for consumerIndex in slots.keys.sorted() where consumerIndex > 0 {
            let producerIndex = consumerIndex - 1
            let producer = instructions[producerIndex], consumer = instructions[consumerIndex]
            guard let word = Self.tstASRWord(producer.source),
                  word & 0xffe0_801f == 0x6a80_001f,
                  producer.source.mnemonic == "tst" else { continue }
            let shift = Int64((word >> 10) & 31), rn = (word >> 5) & 31, rm = (word >> 16) & 31
            guard shift > 0, rn < 31, rm < 31,
                  producer.source.operands == "w\(rn), w\(rm), asr #\(shift)",
                  consumer.source.address >= 4, producer.source.address == consumer.source.address - 4,
                  groups[producer.source.address]?.count == 1, groups[consumer.source.address]?.count == 1,
                  cfg.blocks.contains(where: { $0.instructionRange.contains(producerIndex) && $0.instructionRange.contains(consumerIndex) }),
                  let relation = Self.tstASRConsumerRelation(consumer.source),
                  case let .intrinsic(nil, "compare", arguments) = producer.operation,
                  arguments.count == 2, arguments[1] == .immediate(0),
                  case let .unary("(int32_t)", bits) = arguments[0],
                  case let .binaryExpression("&", .unary("(uint32_t)", left), .unary("(uint32_t)", shifted)) = bits,
                  case let .binaryExpression(">>", .unary("(int32_t)", right), .immediate(actualShift)) = shifted,
                  actualShift == shift, tstASRPureWord(left, register: rn, function: function, names: names),
                  tstASRPureWord(right, register: rm, function: function, names: names),
                  Self.tstASRFlagsDie(after: consumerIndex, cfg: cfg, instructions: instructions) else { continue }
            let local = "tst_u_\(String(producer.source.address, radix: 16))"
            guard !inventory.contains(local), let slot = slots[consumerIndex] else { continue }
            let u = MacIRValue.unary(op: "(uint32_t)", value: .symbol(local))
            let sign = MacIRValue.binaryExpression(op: ">>", left: u, right: .immediate(31))
            let fill = MacIRValue.unary(op: "(uint32_t)", value: .binaryExpression(op: "-",
                left: .unary(op: "(uint32_t)", value: .immediate(0)), right: sign))
            let asr = MacIRValue.binaryExpression(op: "|",
                left: .binaryExpression(op: ">>", left: u, right: .immediate(shift)),
                right: .binaryExpression(op: "<<", left: fill, right: .immediate(32 - shift)))
            let logical = MacIRValue.binaryExpression(op: "&", left: .unary(op: "(uint32_t)", value: left), right: asr)
            let projected = MacIRBuilder.signedProjection(logical, width: 32)
            let replacement: MacIROperation
            switch consumer.operation {
            case let .compareToBool(destination, condition, value, zero)
                where condition == relation && value == arguments[0] && zero == .immediate(0):
                replacement = .compareToBool(destination: destination, condition: condition, left: projected, right: zero)
            case let .select(destination, condition, value, zero, yes, no)
                where condition == relation && value == arguments[0] && zero == .immediate(0):
                replacement = .select(destination: destination, condition: condition, left: projected, right: zero, trueValue: yes, falseValue: no)
            case let .conditionalBranch(condition, value, zero, target)
                where condition == relation && value == arguments[0] && zero == .immediate(0):
                guard let encodedTarget = UInt64(consumer.source.operands.dropFirst(2), radix: 16),
                      target == .immediate(Int64(bitPattern: encodedTarget)),
                      let branch = slot.0, branch.branchIndex == consumerIndex,
                      branch.compareIndex == producerIndex, branch.left == value,
                      branch.right == zero, branch.condition == condition, !branch.isZeroCheck else { continue }
                replacement = .conditionalBranch(condition: condition, left: projected, right: zero, target: target)
            default: continue
            }
            certificates.append(.init(producerIndex: producerIndex, consumerIndex: consumerIndex,
                producer: producer, consumer: consumer, name: local, initializer: right,
                replacement: replacement, branch: slot.0, inverted: slot.1))
            inventory.insert(local)
        }
        guard !certificates.isEmpty else { return nil }
        var replacements: [Int: (String, String, MacIRSourceSpan)] = [:]
        var conditions: [UInt64: String] = [:]
        for certificate in certificates {
            guard instructions[certificate.producerIndex] == certificate.producer,
                  instructions[certificate.consumerIndex] == certificate.consumer,
                  lines.filter({ $0.source == certificate.producer.source }).isEmpty else { return nil }
            let matches = lines.indices.filter { lines[$0].source == certificate.consumer.source }
            guard matches.count == 1, let lineIndex = matches.first, replacements[lineIndex] == nil else { return nil }
            let original = lines[lineIndex]
            let prefix = String(original.text.prefix(while: { $0 == " " || $0 == "\t" }))
            if lineIndex > 0, lines[lineIndex - 1].text.trimmingCharacters(in: .whitespaces).hasSuffix(":") { return nil }
            let suffix = commentSuffix(for: certificate.consumer, callSignaturesByTarget: callSignaturesByTarget)
            let expected: String, updated: String
            if var branch = certificate.branch {
                let old = certificate.inverted ? invertedConditionText(for: branch, names: names) : rawConditionText(for: branch, names: names)
                guard case let .conditionalBranch(_, projected, _, _) = certificate.replacement else { return nil }
                branch.left = projected
                let new = certificate.inverted ? invertedConditionText(for: branch, names: names) : rawConditionText(for: branch, names: names)
                expected = "\(prefix)if (\(old)) {\(suffix)"
                updated = "\(prefix)if (\(new)) {\(suffix)"
                conditions[certificate.consumer.source.address] = new
            } else {
                expected = "\(prefix)\(render(operation: certificate.consumer.operation, names: names));\(suffix)"
                updated = "\(prefix)\(render(operation: certificate.replacement, names: names));\(suffix)"
            }
            guard original.text == expected else { return nil }
            let declaration = "\(prefix)uint32_t \(certificate.name) = (uint32_t)(\(valueText(for: certificate.initializer, names: names)));"
            replacements[lineIndex] = (declaration, updated, certificate.producer.source)
        }
        // Only now commit new text. appendLine is state-free under the entry guard.
        var output: [PseudocodeLine] = []
        for (i, line) in lines.enumerated() {
            if let replacement = replacements[i] {
                appendLine(replacement.0, kind: .declaration, source: replacement.2, to: &output)
                appendLine(replacement.1, kind: line.kind, source: line.source, refusal: line.refusal, to: &output)
            } else {
                appendLine(line.text, kind: line.kind, source: line.source, refusal: line.refusal, to: &output)
            }
        }
        let inserted = replacements.keys.map { $0 + 1 }
        func remap(_ old: PseudocodeRegionNode) -> PseudocodeRegionNode {
            var result = old
            result.startLine += inserted.filter { $0 < old.startLine }.count
            result.endLine += inserted.filter { $0 <= old.endLine }.count
            if let address = old.conditionSourceAddress, let condition = conditions[address] { result.condition = condition }
            result.children = old.children.map(remap)
            if old.kind == .ifThen, let address = old.conditionSourceAddress,
               conditions[address] != nil, inserted.contains(old.startLine) {
                let declarationLine = result.startLine
                result.startLine += 1 // the actual braced header, not its preceding declaration
                return PseudocodeRegionNode(kind: .sequence, startLine: declarationLine,
                    endLine: result.endLine, children: [
                        PseudocodeRegionNode(kind: .block, startLine: declarationLine, endLine: declarationLine),
                        result])
            }
            return result
        }
        return (output, remap(node))
    }

    private func appendLine(
        _ text: String,
        kind: PseudocodeLineKind,
        source: MacIRSourceSpan? = nil,
        refusal: MacIRRefusal? = nil,
        to lines: inout [PseudocodeLine]
    ) {
        if let emissionCancellation {
            emissionCancellation.step()
            if emissionCancellation.isCancelled { return }
        }
        let admittedText: String
        if let boundedEmissionState {
            switch boundedEmissionState.admit(text, hasLeadingNewline: !lines.isEmpty) {
            case .accepted(let boundedText):
                admittedText = boundedText
            case .stopped:
                return
            }
        } else {
            admittedText = text
        }
        let lineNumber = lines.count + 1
        lines.append(
            PseudocodeLine(
                lineNumber: lineNumber,
                kind: kind,
                text: admittedText,
                source: source,
                tokens: tokenize(
                    admittedText,
                    lineNumber: lineNumber,
                    sourceAddress: refusal == nil && source?.syntheticPhiEdge == nil ? source?.address : nil
                ),
                refusal: refusal
            )
        )
    }

    private var emissionLimitReached: Bool {
        boundedEmissionState?.isStopped == true || emissionCancellation?.isCancelled == true
    }

    /// Intrinsic names that are semantically empty for pseudocode purposes and may be
    /// elided by the optional NOP-elision pass: `nop` padding and the arm64e pointer-
    /// authentication ops (transparent to value flow and control flow at this level).
    /// Traps (`brk`, `udf`) must NEVER appear here — they stay visible.
    private static let elidableIntrinsicNames: Set<String> = [
        "nop",
        "pacibsp", "paciasp", "autibsp", "autiasp",
        "paciza", "pacizb", "pacia", "pacib",
        "autiza", "autizb", "autia", "autib",
        "xpaclri", "xpacd", "xpaci",
        "paciasppc", "pacibsppc", "pacnbiasppc", "pacnbibsppc",
        "autiasppc", "autibsppc", "autiasppcr", "autibsppcr", "pacm",
        "pacia171615", "pacib171615", "autia171615", "autib171615",
        "pacia1716", "pacib1716", "autia1716", "autib1716",
    ]

    /// True iff `operation` is a semantically-empty padding/PAC intrinsic. Used by the
    /// optional NOP-elision pass to drop `__nop()`-class lines. (PAC entries are inert
    /// until the IR builder lifts those mnemonics to `.intrinsic` — today they surface
    /// as `__unknown` and never reach this predicate.)
    private func isNopIntrinsic(_ operation: MacIROperation) -> Bool {
        if case let .intrinsic(_, name, arguments) = operation,
           Self.elidableIntrinsicNames.contains(name), arguments.isEmpty {
            return true
        }
        return false
    }

    func render(operation: MacIROperation, names: PseudocodeNameContext) -> String {
        switch operation {
        case let .assign(destination, source):
            return "\(valueText(for: destination, names: names)) = \(valueText(for: source, names: names))"

        case let .binary(destination, op, left, right):
            // Keep each nested expression as one operand, including arithmetic.
            // This preserves the IR tree independently of C operator precedence.
            return "\(valueText(for: destination, names: names)) = \(valueText(for: .binaryExpression(op: op, left: left, right: right), names: names))"

        case let .load(destination, address):
            if case .stackSlot = address {
                return "\(valueText(for: destination, names: names)) = \(valueText(for: address, names: names))"
            }
            if let unknown = recordUnknownWidthText(address: address, carrier: destination, isStore: false, names: names) {
                return "\(valueText(for: destination, names: names)) = \(unknown)"
            }
            let record = recordNaturalAccess(destination, names: names).flatMap {
                recordMemoryText(address: address, carrier: destination, access: $0, isStore: false, names: names)
            }
            let source = record ?? structFieldAccess(for: address, names: names) ?? "*(\(valueText(for: address, names: names)))"
            return "\(valueText(for: destination, names: names)) = \(source)"

        case let .store(source, address):
            if let unknown = recordUnknownWidthText(address: address, carrier: source, isStore: true, names: names) { return unknown }
            let record = recordNaturalAccess(source, names: names, isStore: true).flatMap {
                recordMemoryText(address: address, carrier: source, access: $0, isStore: true, names: names)
            }
            let target = record ?? structFieldAccess(for: address, names: names) ?? lvalue(for: address, names: names)
            let value = record == nil ? valueText(for: source, names: names) : recordStoreValueText(source, names: names)
            return "\(target) = \(value)"

        case let .loadWriteback(destination, baseDestination, baseSource, delta, preIndex):
            let baseDestinationText = valueText(for: baseDestination, names: names)
            let baseSourceText = valueText(for: baseSource, names: names)
            let updateText = writebackUpdateText(baseSource: baseSource, delta: delta, names: names)
            let address = preIndex ? MacIRValue.binaryExpression(op: "+", left: baseSource, right: .immediate(delta)) : baseSource
            if let access = recordNaturalAccess(destination, names: names),
               let memory = recordMemoryText(address: address, carrier: destination, access: access,
                   isStore: false, names: names, allowField: false) {
                if preIndex { return "\(baseDestinationText), \(valueText(for: destination, names: names)) = \(updateText), \(memory)" }
                return "\(valueText(for: destination, names: names)), \(baseDestinationText) = \(memory), \(updateText)"
            }
            if preIndex {
                return "\(baseDestinationText), \(valueText(for: destination, names: names)) = \(updateText), *(\(updateText))"
            }
            return "\(valueText(for: destination, names: names)), \(baseDestinationText) = *(\(baseSourceText)), \(updateText)"

        case let .storeWriteback(source, baseDestination, baseSource, delta, preIndex):
            let baseDestinationText = valueText(for: baseDestination, names: names)
            let baseSourceText = valueText(for: baseSource, names: names)
            let updateText = writebackUpdateText(baseSource: baseSource, delta: delta, names: names)
            let address = preIndex ? MacIRValue.binaryExpression(op: "+", left: baseSource, right: .immediate(delta)) : baseSource
            if let access = recordNaturalAccess(source, names: names, isStore: true),
               let memory = recordMemoryText(address: address, carrier: source, access: access,
                   isStore: true, names: names, allowField: false) {
                if preIndex { return "\(baseDestinationText) = \(updateText), \(memory) = \(recordStoreValueText(source, names: names))" }
                return "\(memory) = \(recordStoreValueText(source, names: names)), \(baseDestinationText) = \(updateText)"
            }
            if preIndex {
                return "\(baseDestinationText) = \(updateText), *(\(updateText)) = \(valueText(for: source, names: names))"
            }
            return "*(\(baseSourceText)) = \(valueText(for: source, names: names)), \(baseDestinationText) = \(updateText)"

        case let .stackSlotRead(destination, slot, value):
            let source = stackLocalName(for: slot, names: names) ?? valueText(for: value, names: names)
            return "\(valueText(for: destination, names: names)) = \(source)"

        case let .stackSlotPairRead(firstDestination, firstSlot, firstValue, secondDestination, secondSlot, secondValue):
            let firstSource = stackLocalName(for: firstSlot, names: names) ?? valueText(for: firstValue, names: names)
            let secondSource = stackLocalName(for: secondSlot, names: names) ?? valueText(for: secondValue, names: names)
            return "\(valueText(for: firstDestination, names: names)), \(valueText(for: secondDestination, names: names)) = \(firstSource), \(secondSource)"

        case let .call(frame, result):
            let callText = renderCall(frame: frame, names: names)
            if let result, case let .abiComposite(_, fragments) = result {
                return "\(fragments.map { valueText(for: $0, names: names) }.joined(separator: ", ")) = \(callText)"
            }
            if let pointer = frame.indirectResultPointer {
                return "\(callText) /* indirect result buffer: \(valueText(for: pointer, names: names)) */"
            }
            return result.map { "\(valueText(for: $0, names: names)) = \(callText)" } ?? callText

        case let .conditionalBranch(condition, left, right, target):
            return "if (\(renderCondition(left: left, condition: condition, right: right, names: names))) \(branchTransferText(target, names: names))"

        case let .select(destination, condition, left, right, trueValue, falseValue):
            // The condition must go through renderCondition, not raw valueText: it both
            // parenthesizes a bitwise operand (`(a & 0x7f) != 0` — 62 corpus sites rendered the
            // C-wrong `a & 0x7f != 0` = `a & (0x7f != 0)`) and collapses IR-7's `compound != 0`
            // to the bare `a || b`.
            let conditionExpression = renderCondition(left: left, condition: condition, right: right, names: names)
            return "\(valueText(for: destination, names: names)) = (\(conditionExpression)) ? \(valueText(for: trueValue, names: names)) : \(valueText(for: falseValue, names: names))"

        case let .compareToBool(destination, condition, left, right):
            return "\(valueText(for: destination, names: names)) = \(conditionText(left: left, condition: condition, right: right, names: names))"

        case let .returnValue(value):
            if let value {
                return "return \(valueText(for: value, names: names))"
            }
            return "return"

        case let .intrinsic(destination, name, arguments):
            if let localPairAssignment = renderLocalPairAssignment(
                intrinsicName: name,
                arguments: arguments,
                names: names
            ) {
                return localPairAssignment
            }

            // Stack-pair arg[3] is internal architectural-slot metadata for
            // local-name selection. Preserve the established three-argument
            // pseudo-call whenever exact local rendering is unavailable.
            let renderedArguments: ArraySlice<MacIRValue>
            if (name == "save_pair" || name == "restore_pair"), arguments.count == 4 {
                renderedArguments = arguments.prefix(3)
            } else {
                renderedArguments = arguments[...]
            }
            if name == "fmov", let destination, arguments.count == 1,
               let field = names.bitMovedFieldText(destination: destination, source: arguments[0]) {
                return "\(valueText(for: destination, names: names)) = \(field)"
            }
            let invocation = "__\(name)(\(renderedArguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")))"
            return destination.map { "\(valueText(for: $0, names: names)) = \(invocation)" } ?? invocation

        case let .switchDispatch(index, _, _):
            // The structurer intercepts switchDispatch and emits a multi-line
            // block; this single-line form is a faithful fallback only.
            return "switch (\(valueText(for: index, names: names)))"

        case let .unknown(destination, _, mnemonic, operands):
            let invocation = "__unknown(\"\(Self.escape(mnemonic))\", \"\(Self.escape(operands))\")"
            return destination.map { "\(valueText(for: $0, names: names)) = \(invocation)" } ?? invocation
        }
    }

    func writebackUpdateText(baseSource: MacIRValue, delta: Int64, names: PseudocodeNameContext) -> String {
        let baseSourceText = valueText(for: baseSource, names: names)
        if let typed = typedByteOffsetText(op: "+", left: baseSource, right: .immediate(delta), names: names) {
            return typed
        }
        if delta < 0 {
            return "\(baseSourceText) - \(valueText(for: .immediate(-delta), names: names))"
        }
        return "\(baseSourceText) + \(valueText(for: .immediate(delta), names: names))"
    }

    private func returnedCall(
        startingAt instructionIndex: Int,
        instructions: [MacIRInstruction]
    ) -> ReturnedCall? {
        let returnIndex = instructionIndex + 1
        guard instructions.indices.contains(instructionIndex),
              instructions.indices.contains(returnIndex),
              case let .call(frame, result) = instructions[instructionIndex].operation,
              let result,
              case let .returnValue(returnValue) = instructions[returnIndex].operation,
              instructions[returnIndex].returnTarget == nil,
              returnValue == result else {
            return nil
        }

        return ReturnedCall(
            instruction: instructions[instructionIndex],
            frame: frame
        )
    }

    private func foldedCompareToBool(
        startingAt compareIndex: Int,
        instructions: [MacIRInstruction]
    ) -> FoldedCompareToBool? {
        let boolIndex = compareIndex + 1
        guard instructions.indices.contains(compareIndex),
              instructions.indices.contains(boolIndex),
              case let .intrinsic(_, compareName, compareArguments) = instructions[compareIndex].operation,
              compareName == "compare",
              compareArguments.count == 2,
              instructions[compareIndex].source.address.isContiguous(to: instructions[boolIndex].source.address),
              case let .compareToBool(_, _, left, right) = instructions[boolIndex].operation,
              compareArguments[0] == left,
              compareArguments[1] == right else {
            return nil
        }

        return FoldedCompareToBool(instruction: instructions[boolIndex])
    }

    /// Folds the canonical Apple Silicon `adrp xN, _sym@PAGE` / `add xN, xN,
    /// _sym@PAGEOFF` pair that materializes the runtime address of a named
    /// global, string literal, or imported data symbol into a single
    /// `dst = &_sym` assignment. The fold is intentionally conservative: it
    /// fires only when both halves are physically adjacent, the `add` consumes
    /// exactly the `adrp` result, and both operands name the same base symbol.
    /// Every uncertain case returns nil and keeps the faithful two-line
    /// rendering.
    private func foldedGlobalAddress(
        startingAt adrpIndex: Int,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext
    ) -> FoldedGlobalAddress? {
        let addIndex = adrpIndex + 1
        guard instructions.indices.contains(adrpIndex),
              instructions.indices.contains(addIndex),
              case let .intrinsic(adrpDestination, adrpName, adrpArguments) = instructions[adrpIndex].operation,
              adrpName == "adrp",
              let adrpDestination,
              adrpArguments.count == 1,
              case let .symbol(pageText) = adrpArguments[0],
              case let .binary(addDestination, addOperator, addLeft, addRight) = instructions[addIndex].operation,
              addOperator == "+",
              case let .symbol(pageOffText) = addRight,
              instructions[adrpIndex].source.address.isContiguous(to: instructions[addIndex].source.address),
              addLeft == adrpDestination else {
            return nil
        }

        let baseSymbol = Self.baseSymbol(pageText)
        guard !baseSymbol.isEmpty,
              baseSymbol.hasPrefix("_"),
              baseSymbol == Self.baseSymbol(pageOffText) else {
            return nil
        }

        return FoldedGlobalAddress(
            instruction: instructions[addIndex],
            destinationText: valueText(for: addDestination, names: names),
            symbolName: baseSymbol
        )
    }

    /// Strips a trailing `@PAGE`-family relocation suffix from a symbolic
    /// operand, splitting on the LAST `@` so symbols that themselves embed an
    /// `@` are not mis-grouped. The comparison is case-insensitive to tolerate
    /// disassembler spelling differences.
    private static func baseSymbol(_ symbol: String) -> String {
        guard let separatorIndex = symbol.lastIndex(of: "@") else {
            return symbol
        }
        let suffix = symbol[symbol.index(after: separatorIndex)...].lowercased()
        switch suffix {
        case "page", "pageoff", "gotpage", "gotpageoff", "pageoff12":
            return String(symbol[..<separatorIndex])
        default:
            return symbol
        }
    }

    private func renderCall(
        frame: MacIRCallFrame,
        names: PseudocodeNameContext,
        address: UInt64? = nil
    ) -> String {
        if let signature = frame.typedIndirectSignature,
           let cast = frame.typedIndirectCalleeType,
           let target = frame.controlInputs.indirectTarget {
            let values = frame.denseFixedRenderValues()
            if values.count == signature.parameters.count {
                let arguments = values.map { valueText(for: $0, names: names) }.joined(separator: ", ")
                return "((\(cast))\(valueText(for: target.value, names: names)))(\(arguments))"
            }
        }
        if let richArguments = frame.richArguments {
            let displayTarget = names.callTargetRenames[frame.target] ?? frame.target
            let values = richArguments.map { valueText(for: $0.value, names: names) }
            return "\(displayTarget)(\(values.joined(separator: ", ")))"
        }
        let arguments: [MacIRValue]
        if let signature = frame.knownSignature {
            if signature.isVariadic, frame.tailCountEvidence != nil {
                if let completeArguments = frame.completeKnownVariadicRenderValues() {
                    if let bracket = objcBracketMessage(
                        target: frame.target,
                        arguments: completeArguments,
                        names: names
                    ) {
                        return bracket
                    }
                    arguments = completeArguments
                } else {
                    arguments = frame.denseFixedRenderValues()
                }
            } else {
                arguments = frame.denseFixedRenderValues()
            }
        } else {
            arguments = frame.unknownRenderValues()
        }

        let unproven = frame.unprovenArgumentRegisters
        let argumentComment = unproven.isEmpty ? "" : " /* unproven args: \(unproven.joined(separator: ", ")) */"
        var displayTarget = names.callTargetRenames[frame.target] ?? frame.target
        // An indirect call goes through the value its target register holds at the call,
        // so `ldr x8, [x8, #0x20]; blr x8` reads `(*x8_2)(...)`, tied to that load.
        if frame.target.hasPrefix("(*"), let target = frame.controlInputs.indirectTarget {
            switch target.value {
            case let .register(_, version) where version > 0:
                displayTarget = "(*\(valueText(for: target.value, names: names)))"
            case .argument:
                displayTarget = "(*\(valueText(for: target.value, names: names)))"
            default:
                break // an unwritten entry register keeps its plain name, `(*x8)`
            }
            // A call whose slot resolved to exactly one function names it, and says which slot.
            if let address = address ?? names.renderingCallAddress,
               let resolved = names.resolvedIndirectCalls[address] {
                let text = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
                return "\(resolved.name)(\(text)) /* via \(resolved.slot) */\(argumentComment)"
            }
        }
        if let machineArguments = frame.machineRenderArguments {
            let text = machineArguments.compactMap { argument -> String? in
                guard case let .gpr(index, _) = argument.location else { return nil }
                return "x\(index): \(valueText(for: argument.value, names: names))"
            }.joined(separator: ", ")
            return "\(displayTarget)(/* machine inputs */ \(text))\(argumentComment)"
        }
        return "\(displayTarget)(\(arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")))\(argumentComment)"
    }

    /// Renders a resolved `objc_msgSend(receiver, "selector", args...)` as an
    /// Objective-C bracket message, e.g. `[receiver setObject:a forKey:b]` or
    /// `[receiver viewDidLoad]`. Fires only when the selector is a resolved
    /// string literal whose colon count exactly matches the supplied message
    /// arguments; on any mismatch it returns nil and the call renders as a plain
    /// function call (conservative — never drops or reorders arguments).
    private func objcBracketMessage(
        target: String,
        arguments: [MacIRValue],
        names: PseudocodeNameContext
    ) -> String? {
        let canonicalTarget = target.hasPrefix("_") ? String(target.dropFirst()) : target
        guard canonicalTarget == "objc_msgSend",
              arguments.count >= 2,
              case let .symbol(selectorText) = arguments[1],
              selectorText.hasPrefix("\""),
              selectorText.hasSuffix("\""),
              selectorText.count >= 2 else {
            return nil
        }

        let selector = String(selectorText.dropFirst().dropLast())
        guard Self.isConservativeObjectiveCSelector(selector) else { return nil }

        let receiver = valueText(for: arguments[0], names: names)
        let messageArgs = arguments[2...].map { valueText(for: $0, names: names) }
        let colonCount = selector.filter { $0 == ":" }.count

        if colonCount == 0 {
            guard messageArgs.isEmpty else { return nil }
            return "[\(receiver) \(selector)]"
        }

        guard selector.hasSuffix(":") else { return nil }
        let keywords = selector
            .split(separator: ":", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        guard keywords.count == colonCount, messageArgs.count == colonCount else { return nil }

        let parts = zip(keywords, messageArgs).map { "\($0):\($1)" }.joined(separator: " ")
        return "[\(receiver) \(parts)]"
    }

    /// Bracket syntax embeds selector keywords as source tokens. Preserve any
    /// exact runtime selector as evidence, but embed only the conservative ASCII
    /// identifier grammar that cannot terminate or manufacture pseudocode.
    private static func isConservativeObjectiveCSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty else { return false }
        let hasColon = selector.contains(":")
        if hasColon, !selector.hasSuffix(":") { return false }

        let components = selector.split(separator: ":", omittingEmptySubsequences: false)
        let keywords = hasColon ? components.dropLast() : components[...]
        guard !keywords.isEmpty else { return false }
        return keywords.allSatisfy(Self.isConservativeObjectiveCIdentifier)
    }

    private static func isConservativeObjectiveCIdentifier(
        _ identifier: Substring
    ) -> Bool {
        guard let first = identifier.utf8.first,
              Self.isASCIIIdentifierHead(first) else {
            return false
        }
        return identifier.utf8.dropFirst().allSatisfy(Self.isASCIIIdentifierBody)
    }

    private static func isASCIIIdentifierHead(_ byte: UInt8) -> Bool {
        byte == 0x5f || (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }

    private static func isASCIIIdentifierBody(_ byte: UInt8) -> Bool {
        Self.isASCIIIdentifierHead(byte) || (0x30...0x39).contains(byte)
    }

    private func structuredShortCircuitIf(
        startingAt instructionIndex: Int,
        limit: Int,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext
    ) -> StructuredShortCircuitIf? {
        guard let first = decodeGuardBranch(startingAt: instructionIndex, limit: limit, compareFedOnly: false, instructions: instructions, names: names) else {
            return nil
        }
        let secondStart = first.branchIndex + 1
        guard secondStart < limit,
              let second = decodeGuardBranch(startingAt: secondStart, limit: limit, compareFedOnly: false, instructions: instructions, names: names),
              first.targetIndex == second.targetIndex else {
            return nil
        }

        let joinIndex = second.targetIndex
        // Reject an ambiguous three-or-more-term chain: a further adjacent guard
        // that also targets the same join.
        let thirdStart = second.branchIndex + 1
        if thirdStart < limit,
           let third = decodeGuardBranch(startingAt: thirdStart, limit: limit, compareFedOnly: false, instructions: instructions, names: names),
           third.targetIndex == joinIndex {
            return nil
        }

        guard let bodyRange = straightLineBodyRange(after: second.branchIndex, before: joinIndex, in: instructions) else {
            return nil
        }

        return StructuredShortCircuitIf(
            branchIndex: first.branchIndex,
            bodyRange: bodyRange,
            targetIndex: joinIndex,
            conditionText: "\(first.invertedConditionText) && \(second.invertedConditionText)"
        )
    }

    /// Decodes a single compare-fed or zero-check guard branch starting at
    /// `index`, returning the branch index, the forward exit target index, and
    /// the body-entry (inverted) condition text. Mirrors the gating used by the
    /// existing fallthrough-if matchers so operand/flag coupling is validated.
    private func decodeGuardBranch(
        startingAt index: Int,
        limit: Int,
        compareFedOnly: Bool = false,
        instructions: [MacIRInstruction],
        names: PseudocodeNameContext
    ) -> DecodedGuardBranch? {
        guard instructions.indices.contains(index) else { return nil }

        // Zero-check form: the branch is itself at `index`.
        if !compareFedOnly,
           isZeroCheckBranchMnemonic(instructions[index].source.mnemonic),
           case let .conditionalBranch(condition, left, right, target) = instructions[index].operation,
           right == .immediate(0),
           let targetIndex = localForwardTargetIndex(for: target, after: index, in: instructions),
           targetIndex <= limit,
           let invertedCondition = invertedBranchCondition(condition) {
            return DecodedGuardBranch(
                branchIndex: index,
                targetIndex: targetIndex,
                invertedConditionText: renderZeroCheckCondition(left: left, condition: invertedCondition, right: right, names: names)
            )
        }

        // Compare-fed form: compare at `index`, branch at `index + 1`.
        let branchIndex = index + 1
        if instructions.indices.contains(branchIndex),
           case let .intrinsic(_, compareName, compareArguments) = instructions[index].operation,
           compareName == "compare",
           compareArguments.count == 2,
           instructions[index].source.address.isContiguous(to: instructions[branchIndex].source.address),
           case let .conditionalBranch(condition, left, right, target) = instructions[branchIndex].operation,
           compareArguments[0] == left,
           compareArguments[1] == right,
           let targetIndex = localForwardTargetIndex(for: target, after: branchIndex, in: instructions),
           targetIndex <= limit,
           let invertedCondition = invertedBranchCondition(condition) {
            return DecodedGuardBranch(
                branchIndex: branchIndex,
                targetIndex: targetIndex,
                invertedConditionText: renderCondition(left: left, condition: invertedCondition, right: right, names: names)
            )
        }

        return nil
    }

    /// Base hardware-register name underlying a value, used to prove induction
    /// variable identity across SSA versions. Returns nil for non-register
    /// values (immediates, stack slots, expressions) so only the unambiguous
    /// register idiom is accepted.
    private func baseRegisterName(of value: MacIRValue) -> String? {
        if case let .register(name, _) = value {
            return name
        }
        return nil
    }

    /// True iff `operation` writes a register whose base name is `register`.
    func writesRegister(_ register: String, operation: MacIROperation) -> Bool {
        switch operation {
        case let .assign(destination, _):
            return baseRegisterName(of: destination) == register
        case let .binary(destination, _, _, _):
            return baseRegisterName(of: destination) == register
        case let .load(destination, _):
            return baseRegisterName(of: destination) == register
        case let .loadWriteback(destination, baseDestination, _, _, _):
            return baseRegisterName(of: destination) == register || baseRegisterName(of: baseDestination) == register
        case let .storeWriteback(_, baseDestination, _, _, _):
            return baseRegisterName(of: baseDestination) == register
        case let .stackSlotRead(destination, _, _):
            return baseRegisterName(of: destination) == register
        case let .compareToBool(destination, _, _, _):
            return baseRegisterName(of: destination) == register
        case let .select(destination, _, _, _, _, _):
            return baseRegisterName(of: destination) == register
        case let .intrinsic(destination, _, _):
            return destination.flatMap(baseRegisterName(of:)) == register
        case let .call(_, result):
            return result.flatMap(baseRegisterName(of:)) == register
        case let .unknown(destination, _, _, _):
            // UD-1 lets a destination-writing `__unknown` (cset/csel/csneg/umov/…)
            // claim and SSA-bump its first operand. This guard's only caller is the
            // for-loop only-writer check, which must SEE that write: a body
            // `__unknown` clobbering the induction register would otherwise be folded
            // away into an unsound `for (init; cond; step)` header. `default: return
            // false` silently mis-answered for the claimed subset.
            return destination.flatMap(baseRegisterName(of:)) == register
        default:
            return false
        }
    }

    private func isZeroCheckBranchMnemonic(_ mnemonic: String) -> Bool {
        let normalized = mnemonic.lowercased()
        return normalized == "cbz" || normalized == "cbnz" || normalized == "tbz" || normalized == "tbnz"
    }

    private func localForwardTargetIndex(
        for target: MacIRValue,
        after branchIndex: Int,
        in instructions: [MacIRInstruction],
        maxInstructionDistance: Int = 64
    ) -> Int? {
        guard case let .immediate(targetAddress) = target,
              targetAddress >= 0,
              let targetIndex = instructions.firstIndex(where: { $0.source.address == UInt64(targetAddress) }),
              targetIndex > branchIndex + 1,
              targetIndex - branchIndex <= maxInstructionDistance else {
            return nil
        }
        return targetIndex
    }

    private func straightLineBodyRange(
        after branchIndex: Int,
        before targetIndex: Int,
        in instructions: [MacIRInstruction]
    ) -> Range<Int>? {
        let bodyRange = (branchIndex + 1)..<targetIndex
        guard bodyIsClosedRegion(bodyRange, allowingTrailingReturnAt: nil, instructions: instructions) else {
            return nil
        }
        return bodyRange
    }

    /// Resolves a branch target value to the index of the instruction at that
    /// address, with NO forward-only or distance constraints. Used by the
    /// closed-region escape analysis, which only cares WHERE a transfer lands,
    /// not its direction or distance. Returns nil for non-immediate, negative,
    /// or unresolvable targets.
    private func resolveTargetIndex(
        for target: MacIRValue,
        in instructions: [MacIRInstruction]
    ) -> Int? {
        guard case let .immediate(targetAddress) = target,
              targetAddress >= 0 else {
            return nil
        }
        return instructions.firstIndex(where: { $0.source.address == UInt64(targetAddress) })
    }

    /// Escape analysis: a body half-open range `body` is a safely structurable
    /// closed region iff every control transfer originating inside it resolves
    /// to an index that stays strictly within `body`, and no `returnValue`
    /// appears except at `returnIndex` (used by earlyReturn for its trailing
    /// return). Any transfer that could leave the region, an unresolvable
    /// transfer target, or an unexpected return causes a rejection so the
    /// caller falls back to the existing faithful/goto rendering. This is a
    /// conservative superset of the previous straight-line validator on every
    /// existing body (which contained only inert ops), so existing output is
    /// unchanged.
    private func bodyIsClosedRegion(
        _ body: Range<Int>,
        allowingTrailingReturnAt returnIndex: Int?,
        instructions: [MacIRInstruction]
    ) -> Bool {
        guard body.lowerBound <= body.upperBound else { return false }
        for index in body {
            switch instructions[index].operation {
            case .returnValue:
                if index != returnIndex {
                    return false
                }
            case let .conditionalBranch(_, _, _, target):
                guard let landing = resolveTargetIndex(for: target, in: instructions),
                      body.contains(landing) else {
                    return false
                }
            case let .intrinsic(_, name, arguments):
                if name == "branch" || name.hasPrefix("branch") {
                    guard let first = arguments.first,
                          let landing = resolveTargetIndex(for: first, in: instructions),
                          body.contains(landing) else {
                        return false
                    }
                }
            case .switchDispatch:
                // A switch dispatch transfers control to case targets that are
                // out of the row window; treat it as escaping so a recovered
                // switch is never silently absorbed into a loop/if body.
                return false
            default:
                continue
            }
        }
        return true
    }

    private func renderCondition(
        left: MacIRValue,
        condition: String,
        right: MacIRValue,
        names: PseudocodeNameContext
    ) -> String {
        if right == .immediate(0), isCompoundCondition(left) {
            switch condition {
            case "!=":
                return renderCompoundCondition(left, names: names)
            case "==":
                if let negated = negateCondition(left) {
                    return renderCompoundCondition(negated, names: names)
                }
            default:
                break
            }
        }
        // Keep nested value expressions grouped for comparisons as well. In
        // particular, `a & b == 0` would parse as `a & (b == 0)` in C.
        return "\(parenthesizedOperandText(for: left, names: names)) \(condition) \(parenthesizedOperandText(for: right, names: names))"
    }

    private func conditionText(
        left: MacIRValue,
        condition: String,
        right: MacIRValue,
        names: PseudocodeNameContext
    ) -> String {
        // Delegate to renderCondition so `.compareToBool` renders IDENTICALLY to the `b.cond`
        // path: it collapses `compound != 0` to the bare `a || b` (IR-7's ccmp fusion) and
        // parenthesizes bitwise operands. Rendering the two paths differently is what produced
        // `w0 = w23 == 0xd || w23 == 0xa != 0x0`.
        renderCondition(left: left, condition: condition, right: right, names: names)
    }

    private func renderZeroCheckCondition(
        left: MacIRValue,
        condition: String,
        right: MacIRValue,
        names: PseudocodeNameContext
    ) -> String {
        guard right == .immediate(0), isTruthinessCandidate(left) else {
            return renderCondition(left: left, condition: condition, right: right, names: names)
        }

        let leftText = valueText(for: left, names: names)
        switch condition {
        case "!=":
            return leftText
        case "==":
            return "!\(leftText)"
        default:
            return renderCondition(left: left, condition: condition, right: right, names: names)
        }
    }

    private func isTruthinessCandidate(_ value: MacIRValue) -> Bool {
        switch value {
        case .argument, .register:
            return true
        default:
            return false
        }
    }

    private func invertedBranchCondition(_ condition: String) -> String? {
        switch condition {
        case "==":
            return "!="
        case "!=":
            return "=="
        case "<":
            return ">="
        case "<=":
            return ">"
        case ">":
            return "<="
        case ">=":
            return "<"
        default:
            return nil
        }
    }

    private func negateCondition(_ value: MacIRValue) -> MacIRValue? {
        guard case let .binaryExpression(op, left, right) = value else { return nil }
        switch op {
        case "&&":
            guard let negatedLeft = negateCondition(left),
                  let negatedRight = negateCondition(right) else {
                return nil
            }
            return .binaryExpression(op: "||", left: negatedLeft, right: negatedRight)
        case "||":
            guard let negatedLeft = negateCondition(left),
                  let negatedRight = negateCondition(right) else {
                return nil
            }
            return .binaryExpression(op: "&&", left: negatedLeft, right: negatedRight)
        case "==", "!=", "<", "<=", ">", ">=":
            guard let inverted = invertedBranchCondition(op) else { return nil }
            return .binaryExpression(op: inverted, left: left, right: right)
        default:
            return nil
        }
    }

    private func isCompoundCondition(_ value: MacIRValue) -> Bool {
        guard case let .binaryExpression(op, _, _) = value else { return false }
        return op == "&&" || op == "||"
    }

    private func isComparisonCondition(_ value: MacIRValue) -> Bool {
        guard case let .binaryExpression(op, _, _) = value else { return false }
        return ["==", "!=", "<", "<=", ">", ">="].contains(op)
    }

    private func renderCompoundCondition(_ value: MacIRValue, names: PseudocodeNameContext) -> String {
        guard case let .binaryExpression(op, left, right) = value else {
            return valueText(for: value, names: names)
        }
        switch op {
        case "&&", "||":
            return "\(compoundTermText(left, names: names)) \(op) \(compoundTermText(right, names: names))"
        case "==", "!=", "<", "<=", ">", ">=":
            return renderComparisonCondition(op: op, left: left, right: right, names: names)
        default:
            return valueText(for: value, names: names)
        }
    }

    private func compoundTermText(_ value: MacIRValue, names: PseudocodeNameContext) -> String {
        if isComparisonCondition(value) {
            return "(\(renderCompoundCondition(value, names: names)))"
        }
        if isCompoundCondition(value) {
            return "(\(renderCompoundCondition(value, names: names)))"
        }
        return valueText(for: value, names: names)
    }

    private func renderComparisonCondition(
        op: String,
        left: MacIRValue,
        right: MacIRValue,
        names: PseudocodeNameContext
    ) -> String {
        "\(compoundOperandText(left, names: names)) \(op) \(compoundOperandText(right, names: names))"
    }

    private func compoundOperandText(_ value: MacIRValue, names: PseudocodeNameContext) -> String {
        let text = valueText(for: value, names: names)
        if case .binaryExpression = value {
            return "(\(text))"
        }
        return text
    }

    private func parameterList(for function: MacIRFunction) -> String {
        guard !function.parameters.isEmpty else {
            return function.isVariadic ? "..." : "void"
        }

        let sourcePositions = function.parameters.compactMap(\.sourcePosition)
        let hasCompleteSourceOrder = sourcePositions.count == function.parameters.count
            && Set(sourcePositions).count == sourcePositions.count
            && sourcePositions.sorted() == Array(function.parameters.indices)

        guard hasCompleteSourceOrder else {
            let inputs = function.parameters
                .map { "\($0.register):\($0.type) \($0.name)" }
                .joined(separator: ", ")
            let abiInputs = "/* ABI inputs: \(inputs) */"
            return function.isVariadic ? "... \(abiInputs)" : abiInputs
        }

        var declarations = function.parameters
            .sorted { $0.sourcePosition! < $1.sourcePosition! }
            .map { "\($0.type) \($0.name)" }
        if function.isVariadic {
            declarations.append("...")
        }
        return declarations.joined(separator: ", ")
    }

    private func lvalue(for address: MacIRValue, names: PseudocodeNameContext) -> String {
        switch address {
        case .stackSlot:
            return valueText(for: address, names: names)
        default:
            return "*(\(valueText(for: address, names: names)))"
        }
    }

    /// Field-access sugar: `*(argN + off)` renders as `argN->field` when argN is a pointer to
    /// a catalog struct and a field starts exactly at `off`. Returns nil for every other shape
    /// (non-argument base, no applied `<struct> *` type, or no field at that offset) so the
    /// caller falls back to the raw dereference — output is unchanged without an applied type.
    private func structFieldAccess(for address: MacIRValue, names: PseudocodeNameContext) -> String? {
        guard let (base, offset) = PseudocodeNameContext.dereferenceTarget(address),
              let field = names.structFieldName(forBase: base, offset: offset)
        else { return nil }
        return "\(valueText(for: base, names: names))->\(field)"
    }

    func valueText(for value: MacIRValue, names: PseudocodeNameContext) -> String {
        switch value {
        case let .stackSlot(offset):
            return names.localsByOffset[offset]?.name ?? value.description
        case let .register(name, version):
            // A USER register rename (version-agnostic, keyed by register id) wins over both the
            // recovered binding and the raw `x19_0` rendering: the user named this storage
            // location, so show that name everywhere it appears.
            if let renamed = names.userRegisterName(for: name) { return renamed }
            return names.registerNamesByValue[.register(name: name, version: version)] ?? value.description
        case let .argument(bindingID):
            // Resolve through the owning function's parameter table. A missing
            // or duplicate binding fails closed to a bank-qualified placeholder.
            return names.argumentNames[bindingID] ?? bindingID.placeholderName
        case let .argumentFragment(rowID, byteOffset, size):
            return names.fragmentText(rowID: rowID, byteOffset: byteOffset, size: size)
        case let .abiComposite(type, fragments):
            return "__abi_compose<\(type)>(\(fragments.map { valueText(for: $0, names: names) }.joined(separator: ", ")))"
        case let .bitTest(value, bit):
            return "((\(parenthesizedOperandText(for: value, names: names)) >> \(MacIRValue.immediate(bit))) & 0x1)"
        case let .unary(op, value):
            let bitcasts = ["__ssa_bitcast_f32": "__bitcast_f32", "__ssa_bitcast_f64": "__bitcast_f64",
                            "__ssa_bitcast_u32": "__bitcast_u32", "__ssa_bitcast_u64": "__bitcast_u64",
                            "__ssa_low64": "__low64", "__ssa_high64": "__high64"]
            if let bitcast = bitcasts[op] { return "\(bitcast)(\(valueText(for: value, names: names)))" }
            // Preserve the operand tree, including arithmetic/casts and nested unary
            // operators. For example, -(-x) must never become the token --x.
            return "\(op)(\(valueText(for: value, names: names)))"
        case let .binaryExpression(op, left, right):
            if op == "__ssa_join_vector_halves" {
                return "__join_vector_halves(\(valueText(for: left, names: names)), \(valueText(for: right, names: names)))"
            }
            if op == MacIRBuilder.signedProjectionOperator {
                if case let .immediate(width) = right {
                    return signedProjectionText(of: left, partner: nil, width: Int(width), names: names)
                }
                if case let .binaryExpression(ctx, .immediate(width), partner) = right, ctx == MacIRBuilder.projectionContextOperator {
                    return signedProjectionText(of: left, partner: partner, width: Int(width), names: names)
                }
            }
            if let typed = typedByteOffsetText(op: op, left: left, right: right, names: names) { return typed }
            let leftText = parenthesizedOperandText(for: left, names: names)
            let rightText = parenthesizedOperandText(for: right, names: names)
            return "\(leftText) \(op) \(rightText)"
        case let .signedBitfield(field):
            return field.render(sourceText: valueText(for: field.source, names: names))
        default:
            return value.description
        }
    }

    /// A34: the declared C type the printer gives `value`, when it establishes one (else nil).
    func printedScalarType(of value: MacIRValue, names: PseudocodeNameContext) -> String? {
        switch value {
        case let .unary(op, _):
            guard op.first == "(", op.last == ")" else { return nil }
            return String(op.dropFirst().dropLast())
        case let .argument(binding):
            return names.argumentTypes[binding] ?? names.parameterTypesByBinding[binding]
        case let .register(name, _):
            if let type = names.valueTypes[value] { return type }
            guard let access = names.loadAccessByDestination[value], [4, 8].contains(access.byteWidth),
                  !(name.hasPrefix("s") || name.hasPrefix("d")) else { return nil }
            // Match the explicit signed64 transport emitted for SSA signed-word X loads.
            if names.ordinarySSAMemoryEffects, access.extensionKind == .sign, access.byteWidth == 4,
               MacIRBuilder.integerRegisterView(name)?.width == 64 { return "int64_t" }
            let signed = access.extensionKind == .sign
                || (names.ordinarySSAMemoryEffects && access.extensionKind == .none
                    && names.signedCompareLoadDestinations.contains(value))
            return "\(signed ? "int" : "uint")\(access.byteWidth * 8)_t"
        default:
            return names.valueTypes[value]
        }
    }

    /// A34: resolves a signed-condition projection marker. Plain `(intW_t)e` only when e prints as
    /// exactly signed W; every other case uses the A31 defined two's-complement transport. A pointer
    /// operand is left bare (never cast), so the ordinary-C proof refuses it.
    func signedProjectionText(of operand: MacIRValue, partner: MacIRValue?, width: Int, names: PseudocodeNameContext) -> String {
        let type = printedScalarType(of: operand, names: names)
        if emittedPointerType(for: operand, names: names) != nil || type?.hasSuffix("*") == true {
            return valueText(for: operand, names: names)
        }
        if type == "int\(width)_t" { return "(int\(width)_t)(\(valueText(for: operand, names: names)))" }
        // A35: a narrower signed operand stays bare only when its defining instruction sign-extends to W
        // and the partner prints as signed W; otherwise the transport below is refused by the proof.
        if let partner, let narrower = Self.signedBits(type), narrower < width,
           case let .register(name, _) = operand, let access = names.loadAccessByDestination[operand],
           access.extensionKind == .sign, access.byteWidth * 8 == narrower,
           MacIRBuilder.integerRegisterView(name)?.width == width,
           partnerPrintsSignedWidth(partner, width: width, names: names) {
            return valueText(for: operand, names: names)
        }
        let e = parenthesizedOperandText(for: operand, names: names)
        let sign = width == 32 ? "0x80000000" : "0x8000000000000000"
        return "((\(e) & \(sign)) == 0 ? (int\(width)_t)\(e) : -1 - (int\(width)_t)(uint\(width)_t)~\(e))"
    }

    private static func signedBits(_ type: String?) -> Int? {
        guard let type, type.hasPrefix("int"), type.hasSuffix("_t") else { return nil }
        return Int(type.dropFirst(3).dropLast(2))
    }

    /// The partner of a bare sign-extended operand prints as signed W: a small literal, a declared
    /// intW_t, or an operand that resolves to a plain cast or the transport.
    private func partnerPrintsSignedWidth(_ partner: MacIRValue, width: Int, names: PseudocodeNameContext) -> Bool {
        var value = partner
        if case let .binaryExpression(op, inner, _) = value, op == MacIRBuilder.signedProjectionOperator { value = inner }
        if case let .immediate(constant) = value { return constant >= Int64(Int32.min) && constant <= Int64(Int32.max) }
        let type = printedScalarType(of: value, names: names)
        if emittedPointerType(for: value, names: names) != nil || type?.hasSuffix("*") == true { return false }
        if type == "int\(width)_t" { return true }
        guard MacIRBuilder.isPureValue(partner) else { return false } // effectful partners stay unprojected
        if let narrower = Self.signedBits(type), narrower < width { return false }
        return true
    }

    /// MacIR address offsets are bytes; C pointer arithmetic is in pointee elements.
    /// Only an actually emitted pointer declaration/cast can introduce C scaling.
    /// In particular, field-sugar valueTypes do not type bare SSA register names.
    func emittedPointerType(for value: MacIRValue, names: PseudocodeNameContext) -> String? {
        let type: String?
        switch value {
        case let .argument(binding):
            guard names.emitsParameterDeclarations else { return nil }
            type = names.argumentTypes[binding]
        case let .stackSlot(offset):
            type = names.localsByOffset[offset]?.type
        case let .unary(op, _):
            guard op.first == "(", op.last == ")" else { return nil }
            type = String(op.dropFirst().dropLast())
        case let .binaryExpression(op, base, offset) where op == "+" || op == "-":
            let leftType = emittedPointerType(for: base, names: names)
            let rightType = emittedPointerType(for: offset, names: names)
            if leftType != nil, rightType == nil { type = leftType }
            else if op == "+", leftType == nil { type = rightType }
            else { return nil }
        default:
            return nil
        }
        guard let type, resolvedPointer(type, names: names) != nil else { return nil }
        return type
    }

    /// Resolve whole-pointer aliases as well as explicit T*. Incomplete, cyclic,
    /// vector, or multi-field aliases do not establish a pointer type.
    func resolvedPointer(_ type: String, names: PseudocodeNameContext) -> DarwinARM64NormalizedDataPointer? {
        var spelling = type
        var visited: Set<String> = []
        while true {
            if let pointer = DarwinARM64ParameterBinder.normalizedDataPointer(spelling) { return pointer }
            let aliasName = spelling.split(whereSeparator: \.isWhitespace)
                .filter { $0 != "const" && $0 != "volatile" }.joined(separator: " ")
            guard visited.insert(aliasName).inserted,
                  let alias = names.typesByName[aliasName], alias.kind == .typedef,
                  alias.vectorByteSize == nil, alias.fields.count == 1,
                  alias.fields[0].layoutIsUnknown != true else { return nil }
            spelling = alias.fields[0].type
        }
    }

    private func typedByteOffsetText(op: String, left: MacIRValue, right: MacIRValue,
                                     names: PseudocodeNameContext) -> String? {
        if op == "+", emittedPointerType(for: left, names: names) == nil,
           emittedPointerType(for: right, names: names) != nil {
            return typedByteOffsetText(op: op, left: right, right: left, names: names)
        }
        guard op == "+" || op == "-",
              let type = emittedPointerType(for: left, names: names),
              emittedPointerType(for: right, names: names) == nil,
              let pointer = resolvedPointer(type, names: names) else { return nil }
        // Record and unresolved pointees require exact byte arithmetic. A
        // memory access with a proven width may separately select a field path.
        if emittedRecordPointer(left, names: names) != nil {
            return byteOffsetFallbackText(type: type, op: op, left: left, right: right, names: names)
        }
        let size: Int
        if pointer.indirectionLevel > 1 {
            size = 8
        } else {
            if let layout = TypeAtlasDarwinARM64LayoutResolver(catalog: names.typesByName)
                .resolveLayout(ofType: pointer.pointeeWords.joined(separator: " ")),
               (layout.kind == .integer || layout.kind == .floating), layout.size > 0 {
                size = layout.size
            } else {
                return byteOffsetFallbackText(type: type, op: op, left: left, right: right, names: names)
            }
        }
        let base = parenthesizedOperandText(for: left, names: names)
        if case let .immediate(bytes) = right, bytes % Int64(size) == 0 {
            let index = valueText(for: .immediate(bytes / Int64(size)), names: names)
            return "\(base) \(op) \(index)"
        }
        if size == 1 {
            return "\(base) \(op) \(parenthesizedOperandText(for: right, names: names))"
        }
        return byteOffsetFallbackText(type: type, op: op, left: left, right: right, names: names)
    }

    func byteOffsetFallbackText(type: String, op: String, left: MacIRValue,
                                right: MacIRValue, names: PseudocodeNameContext, restoreType: Bool = true) -> String {
        // Cast the base before adding; restore the result type for enclosing expressions.
        let qualifiers = type.split(whereSeparator: { $0.isWhitespace || $0 == "*" })
            .filter { $0 == "const" || $0 == "volatile" }
        let byteType = Set(qualifiers).sorted().map(String.init).joined(separator: " ")
        let prefix = byteType.isEmpty ? "" : byteType + " "
        let address = "(\(prefix)uint8_t *)(\(valueText(for: left, names: names))) \(op) \(parenthesizedOperandText(for: right, names: names))"
        return restoreType ? "(\(type))(\(address))" : address
    }

    /// Preserve each nested expression as one operand. Do not reassociate even
    /// apparently associative arithmetic: fixed-width and floating semantics may differ.
    func parenthesizedOperandText(for value: MacIRValue, names: PseudocodeNameContext) -> String {
        let text = valueText(for: value, names: names)
        if case .binaryExpression = value {
            return "(\(text))"
        }
        return text
    }

    private func stackLocalName(for slot: MacIRValue, names: PseudocodeNameContext) -> String? {
        guard case let .stackSlot(offset) = slot else { return nil }
        return names.localsByOffset[offset]?.name
    }

    private func renderLocalPairAssignment(
        intrinsicName: String,
        arguments: [MacIRValue],
        names: PseudocodeNameContext
    ) -> String? {
        guard (arguments.count == 3 || arguments.count == 4),
              case let .stackSlot(offset) = arguments[2],
              let firstLocal = names.localsByOffset[offset] else {
            return nil
        }
        let secondOffset: Int64
        if arguments.count == 4 {
            guard case let .stackSlot(explicitSecondOffset) = arguments[3] else {
                return nil
            }
            secondOffset = explicitSecondOffset
        } else {
            // Compatibility for manually constructed legacy IR. New builder output
            // always carries the architectural second slot explicitly because a
            // wider local may already overlap the first offset.
            secondOffset = offset + Int64(firstLocal.byteWidth)
        }
        guard let secondLocal = names.localsByOffset[secondOffset] else {
            return nil
        }

        switch intrinsicName {
        case "save_pair":
            return "\(firstLocal.name), \(secondLocal.name) = \(valueText(for: arguments[0], names: names)), \(valueText(for: arguments[1], names: names))"
        case "restore_pair":
            return "\(valueText(for: arguments[0], names: names)), \(valueText(for: arguments[1], names: names)) = \(firstLocal.name), \(secondLocal.name)"
        default:
            return nil
        }
    }

    private func functionMetadataLine(for function: MacIRFunction, names: PseudocodeNameContext) -> String {
        let stackText = function.maxStackDisplacement > 0
            ? "stack frame \(hexByteCount(function.maxStackDisplacement)) bytes"
            : "no stack frame"
        let callsText = function.callTargets.isEmpty
            ? "calls none"
            : "calls \(function.callTargets.map { names.callTargetRenames[$0] ?? $0 }.joined(separator: ", "))"
        let noReturnText = function.isNoReturn ? "; noreturn" : ""
        return "    // entry \(formatAddress(function.startAddress)); \(stackText); \(callsText)\(noReturnText)"
    }

    private func commentSuffix(
        for instruction: MacIRInstruction,
        callSignaturesByTarget: [String: MacIRCallSignature] = [:],
        extraAnnotations: [String] = []
    ) -> String {
        let annotations = comments(for: instruction, callSignaturesByTarget: callSignaturesByTarget) + extraAnnotations
        guard !annotations.isEmpty else { return "" }
        return " // " + annotations.joined(separator: "; ")
    }

    private func comments(
        for instruction: MacIRInstruction,
        callSignaturesByTarget: [String: MacIRCallSignature]
    ) -> [String] {
        var comments: [String] = []
        if let sourceComment = instruction.source.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sourceComment.isEmpty {
            comments.append(Self.sanitizedComment(sourceComment))
        }

        switch instruction.operation {
        case let .intrinsic(_, name, arguments):
            switch name {
            case "stack_alloc":
                if let amount = arguments.first {
                    comments.append("allocates \(amount) stack bytes")
                }
            case "stack_free":
                if let amount = arguments.first {
                    comments.append("releases \(amount) stack bytes")
                }
            // A 16-byte pair is vector data, not a callee-saved register pair.
            case "save_pair" where instruction.memoryAccess?.byteWidth != 16:
                comments.append("saves register pair")
            case "restore_pair" where instruction.memoryAccess?.byteWidth != 16:
                comments.append("restores register pair")
            case "compare":
                comments.append("sets condition flags")
            case "branch":
                comments.append("unconditional branch")
            case "branch_register":
                comments.append("indirect branch")
            default:
                if name.hasPrefix("branch_") {
                    comments.append("conditional branch")
                }
            }

        case let .call(frame, _):
            comments.append("call")
            if let signature = frame.knownSignature {
                comments.append("signature \(signature.declarationText)")
            }

        case .switchDispatch:
            comments.append("jump table")

        case .conditionalBranch:
            comments.append("conditional branch")

        case .select:
            comments.append("conditional select")

        case .compareToBool:
            comments.append("compare to bool")

        case .returnValue:
            comments.append("return")

        case let .store(_, address):
            if case .stackSlot = address {
                comments.append("stack store")
            }

        case let .load(_, address):
            if case .stackSlot = address {
                comments.append("stack load")
            }

        case let .stackSlotRead(_, slot, _):
            comments.append("recovered \(slot)")

        case let .stackSlotPairRead(_, firstSlot, _, _, secondSlot, _):
            comments.append("restores register pair")
            comments.append("recovered \(firstSlot), \(secondSlot)")

        default:
            break
        }

        return comments
    }

    private func tokenize(_ text: String, lineNumber: Int, sourceAddress: UInt64?) -> [PseudocodeToken] {
        let characters = Array(text)
        var tokens: [PseudocodeToken] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }

            let start = index
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                tokens.append(
                    PseudocodeToken(
                        lineNumber: lineNumber,
                        kind: .comment,
                        text: String(characters[start..<characters.count]),
                        range: start..<characters.count,
                        sourceAddress: sourceAddress
                    )
                )
                index = characters.count
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index < characters.count {
                    if index + 1 < characters.count,
                       characters[index] == "*", characters[index + 1] == "/" {
                        index += 2
                        break
                    }
                    index += 1
                }
                tokens.append(
                    PseudocodeToken(
                        lineNumber: lineNumber,
                        kind: .comment,
                        text: String(characters[start..<index]),
                        range: start..<index,
                        sourceAddress: sourceAddress
                    )
                )
            } else if character.isLetter || character == "_" {
                index += 1
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    index += 1
                }
                appendToken(
                    String(characters[start..<index]),
                    range: start..<index,
                    lineNumber: lineNumber,
                    sourceAddress: sourceAddress,
                    to: &tokens
                )
            } else if character.isNumber || (character == "-" && index + 1 < characters.count && characters[index + 1].isNumber) {
                index += 1
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "x" {
                    index += 1
                }
                tokens.append(
                    PseudocodeToken(
                        lineNumber: lineNumber,
                        kind: .literal,
                        text: String(characters[start..<index]),
                        range: start..<index,
                        sourceAddress: sourceAddress
                    )
                )
            } else if character == "\"" {
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" {
                        index = min(characters.count, index + 2)
                    } else if characters[index] == "\"" {
                        index += 1
                        break
                    } else {
                        index += 1
                    }
                }
                tokens.append(
                    PseudocodeToken(
                        lineNumber: lineNumber,
                        kind: .literal,
                        text: String(characters[start..<index]),
                        range: start..<index,
                        sourceAddress: sourceAddress
                    )
                )
            } else {
                index += 1
                tokens.append(
                    PseudocodeToken(
                        lineNumber: lineNumber,
                        kind: .punctuation,
                        text: String(character),
                        range: start..<index,
                        sourceAddress: sourceAddress
                    )
                )
            }
        }

        return tokens
    }

    private func appendToken(
        _ text: String,
        range: Range<Int>,
        lineNumber: Int,
        sourceAddress: UInt64?,
        to tokens: inout [PseudocodeToken]
    ) {
        let kind: PseudocodeTokenKind
        if text == "return" || text == "if" || text == "else" || text == "goto" || text == "while"
            || text == "for" || text == "do"
            || text == "switch" || text == "case" || text == "default" || text == "break" || text == "continue" {
            kind = .keyword
        } else if text == "int64_t"
            || text == "uint64_t"
            || text == "int32_t"
            || text == "uint32_t"
            || text == "int16_t"
            || text == "uint16_t"
            || text == "int8_t"
            || text == "uint8_t"
            || text == "size_t"
            || text == "__int128_t"
            || text == "const"
            || text == "char"
            || text == "int"
            || text == "BOOL"
            || text == "id"
            || text == "SEL"
            || text == "void" {
            kind = .type
        } else if text == "__unknown" {
            kind = .unknown
        } else if text.hasPrefix("__") {
            kind = .intrinsic
        } else {
            kind = .identifier
        }

        tokens.append(
            PseudocodeToken(
                lineNumber: lineNumber,
                kind: kind,
                text: text,
                range: range,
                sourceAddress: sourceAddress
            )
        )
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func sanitizedComment(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func formatAddress(_ address: UInt64) -> String {
        "0x" + String(address, radix: 16, uppercase: false).leftPadded(to: 16, with: "0")
    }

    private func addressLabelText(_ address: UInt64, names: PseudocodeNameContext) -> String {
        "L_" + String(address, radix: 16, uppercase: false)
    }

    private func hexByteCount(_ value: Int64) -> String {
        "0x" + String(value, radix: 16, uppercase: false)
    }
}

struct PseudocodeNameContext {
    // Captured from the public print input, not original Builder request provenance.
    var allowsTSTASRStatementLocals = false
    var redundantCompareIndices: Set<Int> = []
    var localsByOffset: [Int64: MacIRLocalVariable]
    var registerNamesByValue: [MacIRNameBindingTarget: String]
    /// Parsed-name → user-display-name for renamed callees. Consulted when
    /// rendering call targets so a renamed function shows its custom name in
    /// call expressions and the metadata "calls" list. Empty in tests / when no
    /// rename override is set, leaving output byte-identical.
    var callTargetRenames: [String: String]
    /// Parameter name keyed by argument-register slot index, taken from
    /// `function.parameters`. Body `.argument` references resolve their displayed
    /// name through this so they stay in sync with the (possibly overridden)
    /// signature line — without an override these equal the build-time-baked
    /// names, so output is byte-identical.
    var argumentNames: [MacIRParameterBindingID: String]
    var argumentRows: [MacIRParameterRowID: MacIRFunctionParameter]
    /// User REGISTER RENAMES keyed by the register IDENTIFIER (e.g. "x19"), version-agnostic:
    /// the rename applies to EVERY SSA version of that register so the user sees one consistent
    /// name throughout the body (a register is one storage location; the SSA `_N` is an internal
    /// numbering detail). Empty in the default path, leaving output byte-identical.
    var registerNameOverrides: [String: String]
    /// Applied parameter TYPE keyed by argument-register slot index, from
    /// `function.parameters`. Used to resolve `*(argN + off)` to `argN->field` when the arg
    /// carries a `<struct> *` type. Empty without an applied signature, so output stays
    /// byte-identical.
    var argumentTypes: [MacIRParameterBindingID: String]
    /// Match parameterList against the original rows, before any ID deduplication.
    var emitsParameterDeclarations: Bool
    /// The workspace struct catalog keyed by name, for the field-access sugar above. Empty
    /// unless the caller threads the type catalog through, so output stays byte-identical.
    var typesByName: [String: TypeDefinition]
    /// Duplicate names cannot establish a unique field-layout proof.
    var recordFieldTypesByName: [String: TypeDefinition]
    var recordParametersByBinding: [MacIRParameterBindingID: MacIRFunctionParameter]
    /// Struct-pointer type per SSA value, propagated forward through field loads: when
    /// `dest = base->field` and `field` is itself a `<struct> *`, `dest` inherits that type so
    /// a later `*(dest + off)` also sugars to `dest->field2` (the pointer-chase idiom). Empty
    /// without applied types → byte-identical output.
    var valueTypes: [MacIRValue: String]
    var recordPointerConsumers: Set<MacIRValue> = []
    /// QC effects are printed only when the function reads FPSR back.
    var observesFPSR = false
    /// D05: SSA registers that hold one parameter fragment unchanged (`x19 = x0`), so a bit move
    /// of a GPR-carried float field (`fmov s0, w19`) can name the field it moves.
    var argumentFragmentsByValue: [MacIRValue: (rowID: MacIRParameterRowID, byteOffset: Int, size: Int)] = [:]
    /// Indirect calls whose slot resolved to one function, keyed by call address. Empty by
    /// default, leaving output byte-identical.
    var resolvedIndirectCalls: [UInt64: PseudocodeIndirectCall] = [:]
    /// The call instruction being rendered, when `resolvedIndirectCalls` is not empty.
    var renderingCallAddress: UInt64?
    /// SSA presentation uses one native C label namespace for original addresses.
    var usesNativeAddressLabels = false
    /// Non-leaf blocks that own a label for a retained raw transfer.
    var blockLabelAddresses: Set<UInt64> = []
    /// Only the SSA recovery payload lowers non-frame memory tuples into C statements.
    var ordinarySSAMemoryEffects = false
    var unsignedSelectorDestinations: Set<MacIRValue> = []
    /// Registers a load or store addresses through; their register copies are unsigned.
    var addressBaseRegisters: Set<MacIRValue> = []
    /// Loaded registers read only by signed relational branches; their load is typed signed.
    var signedCompareLoadDestinations: Set<MacIRValue> = []
    /// A34: byte width and extension of the single load defining each register, and the declared type
    /// of each parameter binding, so a signed-projection marker can be resolved from printed types.
    var loadAccessByDestination: [MacIRValue: MacIRMemoryAccess] = [:]
    var parameterTypesByBinding: [MacIRParameterBindingID: String] = [:]
    /// Addresses labelled by a goto-leaf body. Empty outside goto-leaf regions.
    var gotoLeafLabelAddresses: Set<UInt64> = []

    init(
        function: MacIRFunction,
        types: [TypeDefinition] = [],
        callTargetRenames: [String: String] = [:],
        registerNameOverrides: [String: String] = [:]
    ) {
        localsByOffset = Dictionary(uniqueKeysWithValues: function.localVariables.map { ($0.offset, $0) })
        usesNativeAddressLabels = function.ssaEnabled
        observesFPSR = function.observesFPSR
        var ambiguousLoads: Set<MacIRValue> = []
        for instruction in function.instructions {
            guard case let .load(destination, _) = instruction.operation, let access = instruction.memoryAccess else { continue }
            if loadAccessByDestination[destination] != nil { ambiguousLoads.insert(destination) }
            loadAccessByDestination[destination] = access
        }
        for value in ambiguousLoads { loadAccessByDestination[value] = nil }
        for parameter in function.parameters { if let id = parameter.bindingID { parameterTypesByBinding[id] = parameter.type } }
        for instruction in function.instructions {
            guard case let .assign(destination, source) = instruction.operation,
                  case .register = destination else { continue }
            if case let .argumentFragment(rowID, byteOffset, size) = source {
                argumentFragmentsByValue[destination] = (rowID, byteOffset, size)
            } else if let fragment = argumentFragmentsByValue[source] {
                argumentFragmentsByValue[destination] = fragment
            }
        }
        registerNamesByValue = Dictionary(
            uniqueKeysWithValues: function.nameBindings.compactMap { binding in
                guard case .register = binding.target else { return nil }
                return (binding.target, binding.name)
            }
        )
        self.callTargetRenames = callTargetRenames
        let parameterGroups = Dictionary(grouping: function.parameters.compactMap { parameter in
            parameter.bindingID.map { ($0, parameter) }
        }, by: \.0)
        argumentNames = parameterGroups.compactMapValues { entries in
            entries.count == 1 ? entries[0].1.name : nil
        }
        argumentRows = Dictionary(function.parameters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sourcePositions = function.parameters.compactMap(\.sourcePosition)
        emitsParameterDeclarations = sourcePositions.count == function.parameters.count
            && Set(sourcePositions).count == sourcePositions.count
            && sourcePositions.sorted() == Array(function.parameters.indices)
        argumentTypes = parameterGroups.compactMapValues { entries in
            entries.count == 1 ? entries[0].1.type : nil
        }
        // All catalog types (not just structs) so nested struct/union field types resolve when
        // computing member offsets; pointeeStruct filters to structs for the dereference root.
        typesByName = Dictionary(
            types.map { ($0.name, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let recordParameterIDs = Dictionary(grouping: function.parameters, by: \.id)
        recordParametersByBinding = parameterGroups.compactMapValues { entries in
            guard entries.count == 1, let parameter = entries.first?.1,
                  recordParameterIDs[parameter.id]?.count == 1 else { return nil }
            return parameter
        }
        recordFieldTypesByName = Dictionary(grouping: types, by: \.name)
            .compactMapValues { $0.count == 1 ? $0.first : nil }
        valueTypes = Self.propagateStructPointerTypes(
            function: function,
            argumentTypes: argumentTypes,
            typesByName: typesByName
        )
        // Lowercase the override keys to match the IR's lowercased register names; a blank
        // mapping (already pruned upstream) is harmless here.
        self.registerNameOverrides = Dictionary(
            registerNameOverrides.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        // Only the completed SSA sidecar identifies generated NZCV predicates.
        // Printer-only physical-register and callee aliases occupy their names;
        // an intentional override of the predicate itself still wins valueText.
        for binding in MacIRBuilder.ssaNZCVPrintedPredicateNameBindings(function: function,
            registerNameOverrides: self.registerNameOverrides, callTargetRenames: self.callTargetRenames) {
            registerNamesByValue[binding.target] = binding.name
        }
        collectRecordPointerConsumers(in: function)
    }

    func fragmentText(rowID: MacIRParameterRowID, byteOffset: Int, size: Int) -> String {
        guard let parameter = argumentRows[rowID] else {
            return "__abi_fragment(unknown, \(byteOffset), \(size))"
        }
        if let (path, leafType) = fieldPath(in: parameter.type, offset: byteOffset, size: size, depth: 0) {
            // A floating field carried in a GPR holds raw bits, not a numeric
            // value; keep the byte fragment so integer expressions stay exact.
            let floating = ["float", "double"].contains(leafType.trimmingCharacters(in: .whitespaces))
            if !(floating && Self.isGPRCarried(parameter, byteOffset: byteOffset)) {
                return "\(parameter.name).\(path)"
            }
        }
        return "__abi_fragment(\(parameter.name), \(byteOffset), \(size))"
    }

    /// `fmov sN, wM` / `fmov dN, xM` of an unchanged GPR-carried parameter fragment is the
    /// float or double field at those bytes (little-endian: the low word is the first bytes).
    /// Anything else, including a width or type mismatch, keeps the raw bit move.
    func bitMovedFieldText(destination: MacIRValue, source: MacIRValue) -> String? {
        guard case let .register(name, _) = destination else { return nil }
        let width: Int, leaf: String, carrier: MacIRValue
        if name.hasPrefix("s"), case let .unary("(uint32_t)", inner) = source {
            (width, leaf, carrier) = (4, "float", inner)
        } else if name.hasPrefix("d") {
            (width, leaf, carrier) = (8, "double", source)
        } else {
            return nil
        }
        var direct: (rowID: MacIRParameterRowID, byteOffset: Int, size: Int)?
        if case let .argumentFragment(rowID, byteOffset, size) = carrier { direct = (rowID, byteOffset, size) }
        guard let fragment = direct ?? argumentFragmentsByValue[carrier], fragment.size == 8,
              let parameter = argumentRows[fragment.rowID],
              Self.isGPRCarried(parameter, byteOffset: fragment.byteOffset),
              let (path, leafType) = fieldPath(in: parameter.type, offset: fragment.byteOffset, size: width, depth: 0),
              leafType.trimmingCharacters(in: .whitespaces) == leaf else { return nil }
        return "\(parameter.name).\(path)"
    }

    private static func isGPRCarried(_ parameter: MacIRFunctionParameter, byteOffset: Int) -> Bool {
        guard case let .composite(pieces)? = parameter.richLocation else { return false }
        return pieces.contains { piece in
            guard case .gpr = piece.register else { return false }
            return piece.valueByteOffset <= byteOffset && byteOffset < piece.valueByteOffset + piece.size
        }
    }

    private func fieldPath(in typeName: String, offset: Int, size: Int, depth: Int) -> (String, String)? {
        guard depth < 4, let type = typesByName[typeName] else { return nil }
        for member in type.memberLayout(in: typesByName) {
            guard let memberSize = TypeDefinition.size(ofType: member.field.type, in: typesByName),
                  memberSize > 0, offset >= member.offset,
                  offset - member.offset < memberSize else { continue }
            if offset == member.offset && size == memberSize {
                return (member.field.name, member.field.type)
            }
            if let (nested, leafType) = fieldPath(in: member.field.type,
                                                  offset: offset - member.offset,
                                                  size: size, depth: depth + 1) {
                return ("\(member.field.name).\(nested)", leafType)
            }
        }
        return nil
    }

    /// The user's display name for the register `name` (the IR's lowercased identifier), or nil.
    /// Resolves a 32-bit alias (`w19`) to its 64-bit register (`x19`) and vice-versa so a rename
    /// applies regardless of which width the instruction touched — they are one physical register.
    func userRegisterName(for name: String) -> String? {
        guard !registerNameOverrides.isEmpty else { return nil }
        if let direct = registerNameOverrides[name] { return direct }
        // General-purpose registers: x0..x30 / w0..w30 share storage. Map across the width prefix.
        guard let first = name.first, first == "x" || first == "w" else { return nil }
        let alias = (first == "x" ? "w" : "x") + name.dropFirst()
        return registerNameOverrides[alias]
    }

    /// The field name that begins exactly at `offset` in the catalog struct that `base`'s
    /// pointer type refers to. `base` may be an argument (typed via the applied signature) or
    /// any propagated value (typed by `valueTypes`). nil when the base has no `<struct> *`
    /// type, the pointee is not a catalog struct, or no field starts at `offset`.
    func structFieldName(forBase base: MacIRValue, offset: Int) -> String? {
        structField(forBase: base, offset: offset)?.name
    }

    private func structField(forBase base: MacIRValue, offset: Int) -> FieldDef? {
        let typeString: String?
        if case let .argument(bindingID) = base {
            typeString = argumentTypes[bindingID]
        } else {
            typeString = valueTypes[base]
        }
        guard let typeString,
              let structDef = Self.pointeeStruct(for: typeString, in: typesByName) else { return nil }
        return structDef.memberLayout(in: typesByName).first { $0.offset == offset }?.field
    }

    /// Sized accesses need an exact scalar field and compatible architectural
    /// semantics. The legacy unsized helper deliberately keeps its old policy.
    func structFieldName(
        forBase base: MacIRValue, offset: Int, access: MacIRMemoryAccess,
        floating: Bool, isStore: Bool
    ) -> String? {
        guard [1, 2, 4, 8].contains(access.byteWidth),
              let field = structField(forBase: base, offset: offset),
              field.bitWidth == nil, field.inlineAggregateKind == nil,
              field.inlineFields.isEmpty, field.layoutIsUnknown != true,
              let layout = TypeAtlasDarwinARM64LayoutResolver(catalog: typesByName).resolveLayout(ofType: field.type),
              layout.size == access.byteWidth,
              layout.kind == (floating ? .floating : .integer) else { return nil }
        if !isStore {
            if floating {
                guard access.extensionKind == .none else { return nil }
            } else {
                switch access.extensionKind {
                case .sign:
                    guard scalarSignedness(field.type) == true else { return nil }
                case .zero:
                    guard scalarSignedness(field.type) == false else { return nil }
                case .none:
                    guard access.byteWidth == 4 || access.byteWidth == 8 else { return nil }
                }
            }
        }
        return field.name
    }

    /// Resolve aliases before testing integer signedness. Width and scalar class
    /// have already been proved by the shared Darwin layout resolver.
    func scalarSignedness(_ type: String, visiting: Set<String> = []) -> Bool? {
        let name = type.split(whereSeparator: { $0.isWhitespace })
            .filter { !["const", "volatile", "restrict", "_Atomic"].contains(String($0)) }
            .joined(separator: " ")
        let catalogName = name.hasPrefix("enum ") ? String(name.dropFirst(5)) : name
        if let definition = typesByName[catalogName] {
            guard !visiting.contains(catalogName) else { return nil }
            if definition.kind == .typedef, definition.vectorByteSize == nil,
               definition.fields.count == 1 {
                return scalarSignedness(definition.fields[0].type, visiting: visiting.union([catalogName]))
            }
            if definition.kind == .enum {
                // Darwin's C enum representation is signed when its range
                // includes negative values; otherwise it uses unsigned int/long.
                return definition.fields.contains { $0.type.hasPrefix("-") }
            }
            return nil
        }
        switch name {
        case "int8_t", "int16_t", "int32_t", "int64_t", "char", "signed char",
             "short", "short int", "signed short", "signed short int", "int", "signed", "signed int",
             "long", "long int", "signed long", "signed long int", "long long", "long long int",
             "signed long long", "signed long long int", "ssize_t", "intptr_t", "ptrdiff_t", "wchar_t":
            return true
        case "uint8_t", "uint16_t", "uint32_t", "uint64_t", "bool", "_Bool", "unsigned char",
             "unsigned short", "unsigned short int", "unsigned", "unsigned int", "unsigned long",
             "unsigned long int", "unsigned long long", "unsigned long long int", "size_t", "uintptr_t":
            return false
        default: return nil
        }
    }

    /// Resolves a `<struct> *` type string (e.g. "struct Foo *" or "Foo *") to its catalog
    /// struct definition; nil for a non-pointer or a pointee that isn't a catalog struct.
    static func pointeeStruct(for typeString: String, in typesByName: [String: TypeDefinition]) -> TypeDefinition? {
        guard let pointer = DarwinARM64ParameterBinder.normalizedDataPointer(typeString),
              let name = pointer.catalogStructName else { return nil }
        guard let def = typesByName[name], def.kind == .struct else { return nil }
        return def
    }

    /// The (base pointer, byte offset) a memory address dereferences: `base + off` for an
    /// immediate-offset expression, or `(base, 0)` for a bare pointer value — the first-field
    /// case, since `[base, #0]` lowers to a bare `base`. nil for addresses that aren't a plain
    /// pointer dereference (stack slots, immediates, symbols, register-indexed forms), so the
    /// field-access sugar never fires on them.
    static func dereferenceTarget(_ address: MacIRValue) -> (base: MacIRValue, offset: Int)? {
        if case let .binaryExpression(op, base, right) = address, op == "+",
           case let .immediate(offset) = right, offset > 0 {
            return (base, Int(offset))
        }
        switch address {
        case .argument, .register, .temporary:
            return (address, 0)
        default:
            return nil
        }
    }

    /// Forward pass computing the struct-pointer type of each SSA value loaded from a
    /// struct-pointer field, seeded by the applied argument types. Program order guarantees a
    /// value is typed before its uses in a straight-line chain; any unmatched shape is skipped
    /// (correctness-over-coverage — a value is only ever given a type it provably has).
    private static func propagateStructPointerTypes(
        function: MacIRFunction,
        argumentTypes: [MacIRParameterBindingID: String],
        typesByName: [String: TypeDefinition]
    ) -> [MacIRValue: String] {
        guard !typesByName.isEmpty else { return [:] }
        var types: [MacIRValue: String] = [:]
        func baseType(_ value: MacIRValue) -> String? {
            if case let .argument(bindingID) = value { return argumentTypes[bindingID] }
            return types[value]
        }
        for instruction in function.instructions {
            guard case let .load(destination, address) = instruction.operation,
                  let access = instruction.memoryAccess,
                  access.byteWidth == 8, access.extensionKind == .none,
                  case let .register(register, _) = destination,
                  let carrier = MacIRBuilder.integerRegisterView(register), carrier.width == 64,
                  let (base, offset) = dereferenceTarget(address),
                  let baseTypeString = baseType(base),
                  let structDef = pointeeStruct(for: baseTypeString, in: typesByName),
                  let match = structDef.memberLayout(in: typesByName).first(where: { $0.offset == offset }),
                  pointeeStruct(for: match.field.type, in: typesByName) != nil
            else { continue }
            types[destination] = match.field.type
        }
        return types
    }
}

private struct StructuredShortCircuitIf {
    var branchIndex: Int
    var bodyRange: Range<Int>
    var targetIndex: Int
    var conditionText: String
}

private struct DecodedGuardBranch {
    var branchIndex: Int
    var targetIndex: Int
    var invertedConditionText: String
}

private struct ReturnedCall {
    var instruction: MacIRInstruction
    var frame: MacIRCallFrame
}

private struct FoldedCompareToBool {
    var instruction: MacIRInstruction
}

private struct FoldedGlobalAddress {
    var instruction: MacIRInstruction
    var destinationText: String
    var symbolName: String
}


/// An indirect call resolved to one function (`MacIRIndirectTargetResolution`), for rendering:
/// `name(args) /* via slot */`.
public struct PseudocodeIndirectCall: Equatable, Sendable {
    public let target: UInt64
    public let name: String
    public let slot: String

    public init(target: UInt64, name: String, slot: String) {
        self.target = target
        self.name = name
        self.slot = slot
    }
}

extension PseudocodePrinter {
    /// Function-local slot resolutions of one built function. Signature-typed resolutions are
    /// image-wide facts and are left to callers that analyzed the whole image.
    static func functionLocalIndirectCalls(
        in function: MacIRFunction,
        functionStarts: Set<UInt64>,
        name: (UInt64) -> String
    ) -> [UInt64: PseudocodeIndirectCall] {
        let report = MacIRIndirectTargetResolution.resolve(functions: [function], functionStarts: functionStarts)
        var calls: [UInt64: PseudocodeIndirectCall] = [:]
        for resolution in report.resolutions {
            guard case .function = resolution.scope else { continue }
            calls[resolution.callAddress] = PseudocodeIndirectCall(
                target: resolution.target, name: name(resolution.target), slot: resolution.slot.description)
        }
        return calls
    }
}

/// Diagnostic native-IR evidence only. This deliberately grants no rendering
/// authority: unchanged incoming x0 can be a forwarded return value, and a nil
/// inferred return operand is not an ABI kill. Build once per frozen image batch.
enum MacIROwnCalleeReturnEvidence {
    enum Outcome: String, Equatable, Sendable {
        case writesX0 = "writes-x0"
        case passthroughIncomingX0 = "passthrough-incoming-x0"
        case unknown = "UNKNOWN"
    }
    struct Site: Equatable, Sendable {
        let function: UInt64
        let instruction: UInt64
    }
    struct Summary: Equatable, Sendable {
        let outcome: Outcome
        /// Syntactic CFG witness, not a claim of branch-condition feasibility.
        let writingPath: [Site]
    }
    fileprivate enum PathNode: Sendable {
        case step(Site, previous: Int?)
        case concatenate(Int, Int)
    }
    struct Report: Sendable {
        fileprivate let witnesses: [UInt64: Int]
        fileprivate let paths: [PathNode]
        func summary(at address: UInt64) -> Summary {
            guard let witness = witnesses[address] else {
                return Summary(outcome: .unknown, writingPath: [])
            }
            // Materialize only the requested witness. The cached graph shares
            // prefixes and callee suffixes, avoiding quadratic tail-chain copies.
            var pending: [(Int, Bool)] = [(witness, false)]
            var result: [Site] = []
            while let (index, emit) = pending.popLast() {
                switch paths[index] {
                case let .step(site, previous):
                    if emit { result.append(site) }
                    else {
                        pending.append((index, true))
                        if let previous { pending.append((previous, false)) }
                    }
                case let .concatenate(prefix, suffix):
                    pending.append((suffix, false))
                    pending.append((prefix, false))
                }
            }
            return Summary(outcome: .writesX0, writingPath: result)
        }
    }
    private struct Local {
        var witness: Int? = nil
        var tails: [(UInt64, Int)] = []
    }

    static func collect(functions: [MacIRFunction]) -> Report {
        let groups = Dictionary(grouping: functions, by: \.startAddress)
        let unique = groups.compactMapValues { $0.count == 1 ? $0.first : nil }
        let starts = Set(unique.keys)
        var locals: [UInt64: Local] = [:]
        var paths: [PathNode] = []
        for (address, function) in unique {
            locals[address] = scan(function, starts: starts, paths: &paths)
        }
        // Explicit empty bottom is distinct from unknown. Only a concrete
        // write-to-RET witness seeds this least fixed point. A recursive SCC
        // without a seed never becomes a write witness or a void claim.
        var solved: [UInt64: Int] = [:]
        var dependents: [UInt64: [(UInt64, Int)]] = [:]
        var pending: [UInt64] = []
        for (address, local) in locals {
            if let witness = local.witness { solved[address] = witness; pending.append(address) }
            for (target, path) in local.tails {
                dependents[target, default: []].append((address, path))
            }
        }
        while let target = pending.popLast() {
            guard let suffix = solved[target] else { continue }
            for (caller, prefix) in dependents[target, default: []] where solved[caller] == nil {
                solved[caller] = paths.count
                paths.append(.concatenate(prefix, suffix))
                pending.append(caller)
            }
        }
        return Report(witnesses: solved, paths: paths)
    }

    private static func scan(_ function: MacIRFunction, starts: Set<UInt64>,
                             paths: inout [PathNode]) -> Local {
        guard !function.ssaEnabled, function.phis.isEmpty else { return Local() }
        let groups = Dictionary(grouping: function.instructions, by: { $0.source.address })
        guard groups.values.allSatisfy({ $0.count == 1 }) else { return Local() }
        let rows = groups.compactMapValues(\.first)
        struct State: Hashable { let address: UInt64; let written: Bool }
        // One incoming/unknown and one written state per instruction. Paths are
        // retained as shared arena links and expanded only on a report query.
        // This bounds the local walk by 2V states, not one walk per call site.
        let entry = State(address: function.startAddress, written: false)
        var pending = [entry]
        var visited: Set<State> = [entry]
        let entryPath = paths.count
        paths.append(.step(Site(function: function.startAddress, instruction: entry.address), previous: nil))
        var statePaths: [State: Int] = [entry: entryPath]
        var result = Local()
        func address(_ value: MacIRValue) -> UInt64? {
            guard case let .immediate(value) = value, value >= 0 else { return nil }
            return UInt64(value)
        }
        func scalarWrite(_ value: MacIRValue) -> Bool? {
            guard case let .register(name, _) = value,
                  let view = MacIRBuilder.integerRegisterView(name) else { return nil }
            return view.index == 0
        }
        while let state = pending.popLast() {
            guard let row = rows[state.address] else { continue }
            guard row == MacIRInstruction(source: row.source, operation: row.operation,
                memoryAccess: row.memoryAccess, returnTarget: row.returnTarget) else { continue }
            let next = state.address.addingReportingOverflow(4)
            var successors: [UInt64] = []
            var written = state.written
            switch row.operation {
            case .returnValue:
                guard row.source.mnemonic.lowercased() == "ret", row.returnTarget == nil else { continue }
                if written, result.witness == nil { result.witness = statePaths[state] }
                continue
            case let .assign(destination, _), let .binary(destination, _, _, _),
                 let .load(destination, _), let .select(destination, _, _, _, _, _),
                 let .compareToBool(destination, _, _, _):
                guard let writes = scalarWrite(destination) else { continue }
                written = written || writes
            case .store:
                break
            case let .conditionalBranch(_, _, _, target):
                guard let branch = address(target), !next.overflow else { continue }
                successors = [branch, next.partialValue]
            case let .call(frame, _):
                // Non-tail calls and opaque external tails stop the path. A
                // modeled call result is not a callee-owned write witness.
                guard row.source.mnemonic.lowercased() == "b",
                      frame.controlInputs.indirectTarget == nil,
                      frame.typedIndirectSignature == nil,
                      frame.typedIndirectCalleeType == nil,
                      frame.indirectResultPointer == nil else { continue }
                let operand = row.source.operands.trimmingCharacters(in: .whitespacesAndNewlines)
                guard operand.hasPrefix("0x"), let target = UInt64(operand.dropFirst(2), radix: 16),
                      starts.contains(target) else { continue }
                if let path = statePaths[state] { result.tails.append((target, path)) }
                continue
            case .loadWriteback, .storeWriteback, .stackSlotRead, .stackSlotPairRead,
                 .intrinsic, .switchDispatch, .unknown:
                continue
            }
            if successors.isEmpty {
                guard !next.overflow else { continue }
                successors = [next.partialValue]
            }
            for successor in successors where rows[successor] != nil {
                let candidate = State(address: successor, written: written)
                if visited.insert(candidate).inserted {
                    statePaths[candidate] = paths.count
                    paths.append(.step(Site(function: function.startAddress, instruction: successor),
                                       previous: statePaths[state]))
                    pending.append(candidate)
                }
            }
        }
        return result
    }
}
