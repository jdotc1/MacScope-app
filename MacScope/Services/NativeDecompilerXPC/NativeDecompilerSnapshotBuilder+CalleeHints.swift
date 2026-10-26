import Foundation

/// Authored-input v2: known prototypes for the selected function's direct callees
/// (BL targets, and B targets outside the function, i.e. tail calls). The bridge
/// installs each as the callee's named, locked prototype so call sites show their
/// arguments. A function without a hinted callee keeps its v1 request bytes.
extension NativeDecompilerSnapshotBuilder {
    static let maximumCalleeSignatureHints = 256
    /// Bounded recovery attempts per request, including declined or unusable hints.
    static let maximumRecoveredCalleeHints = 32
    static let maximumRecoveredCalleeBytes: UInt64 = 4_096

    /// MacScope's own parameter recovery on an in-image callee, kept only when
    /// confident: every parameter is a GPR read at entry (or constrained by a
    /// known call), in contiguous registers from x0, with nothing on SIMD or the stack.
    static func recoveredCalleeParameters(
        target: UInt64,
        functionsByStart: [UInt64: [FunctionSummary]],
        instructions: [InstructionRow]
    ) -> [(name: String, type: String)]? {
        guard let matches = functionsByStart[target], matches.count == 1, let callee = matches.first,
              callee.endAddress > callee.startAddress,
              callee.endAddress - callee.startAddress <= maximumRecoveredCalleeBytes else { return nil }
        var low = 0, high = instructions.count
        while low < high {
            let mid = (low + high) / 2
            if instructions[mid].address < callee.startAddress { low = mid + 1 } else { high = mid }
        }
        var rows: [InstructionRow] = []
        var index = low
        while index < instructions.count, instructions[index].address < callee.endAddress {
            rows.append(instructions[index]); index += 1
        }
        guard rows.first?.address == callee.startAddress else { return nil }
        let function = MacIRBuilder().buildFunction(name: callee.name, startAddress: callee.startAddress,
                                                    instructions: rows)
        guard !function.isVariadic, (1...8).contains(function.parameters.count) else { return nil }
        var parameters: [(name: String, type: String)] = []
        for (position, parameter) in function.parameters.enumerated() {
            guard [.heuristicEntryRead, .knownCallTypeConstraint].contains(parameter.evidence),
                  case let .gpr(index, _) = parameter.abiLocation, index == position else { return nil }
            parameters.append((parameter.name, parameter.type))
        }
        return parameters
    }

    static func withCalleeSignatureHints(
        _ inputs: NativeDecompilerWireAuthoredInputs,
        functionRegions: [NativeDecompilerWireMemoryRegion],
        functionRange: Range<UInt64>,
        analysis: ImageAnalysis,
        overrides: [UInt64: FunctionSignatureOverride],
        catalog: CallSignatureCatalog = .standard,
        recoveredParameters: ((UInt64) -> [(name: String, type: String)]?)? = nil
    ) -> NativeDecompilerWireAuthoredInputs {
        let targets = directCalleeAddresses(in: functionRegions, functionRange: functionRange)
        guard !targets.isEmpty, let types = try? NativeAuthoredCatalogIndex(definitions: []) else {
            return inputs
        }
        let authored = Set(inputs.signatures.map(\.functionAddress.value))
        let names = calleeNames(analysis)
        var hints: [NativeDecompilerWireCalleeSignatureHint] = []
        var recoveryAttempts = 0
        for target in targets.sorted() where !authored.contains(target) {
            guard hints.count < maximumCalleeSignatureHints, let name = names[target] else { continue }
            if let hint = overrideHint(overrides[target], name: name, address: target, types: types)
                ?? catalogHint(catalog.signature(for: name), name: name, address: target, types: types) {
                hints.append(hint)
            } else if let hint = swiftConventionHint(name: name, address: target, types: types).hint {
                hints.append(hint)
            } else if recoveryAttempts < maximumRecoveredCalleeHints,
                      let recoveredParameters {
                // Charge before recovery: declined parameters and unrepresentable
                // types still incurred the cost of lifting the callee's body.
                recoveryAttempts += 1
                if let parameters = recoveredParameters(target),
                   let hint = hint(name: name, source: .recovered, address: target, returnType: nil,
                                   parameters: parameters, variadicState: .fixed, noReturnState: .unspecified,
                                   types: types) {
                    // Lowest priority: never shadows debug, authored or SDK signatures.
                    hints.append(hint)
                }
            }
        }
        guard !hints.isEmpty else { return inputs }
        return NativeDecompilerWireAuthoredInputs(
            schemaVersion: NativeDecompilerWireAuthoredInputs.calleeHintSchemaVersion,
            names: inputs.names,
            signatures: inputs.signatures,
            appliedTypes: inputs.appliedTypes,
            typeDefinitions: inputs.typeDefinitions,
            calleeSignatureHints: hints
        )
    }

    /// Installable scalar signatures decided only from the callee's own symbol.
    static func swiftConventionHint(
        name: String,
        address: UInt64,
        types: NativeAuthoredCatalogIndex
    ) -> (hint: NativeDecompilerWireCalleeSignatureHint?, abstentions: [String]) {
        guard let demangled = SwiftDemangler.demangleWithFacts(name), let facts = demangled.facts else {
            return (nil, ["SYMBOL_NOT_PARSED"])
        }
        var evidence = SwiftBoundaryEvidence()
        evidence.symbolFacts = facts
        let decision = SwiftConventionAdapter.decide(evidence)
        guard [.swiftcall, .swiftasynccall].contains(decision.convention),
              decision.storage == .scalarOnly, decision.indirectResult == nil,
              decision.contextIn.isEmpty || decision.contextIn == ["x20"],
              decision.asyncContextIn == nil || decision.asyncContextIn == "x22" else {
            return (nil, decision.abstentions.isEmpty ? ["CONTEXT_REGISTERS_UNMODELED"] : decision.abstentions)
        }
        guard !facts.isPartialApplyForwarder, !facts.isDispatchThunk, !facts.isReabstractionThunk,
              !facts.isMerged, facts.funclet == nil else { return (nil, ["WRAPPER_UNMODELED"]) }
        guard !facts.selfTypeIsGeneric || facts.isGeneric else {
            return (nil, ["GENERIC_METADATA_PARAMETERS_UNMODELED"])
        }
        guard let parameterTypes = demangled.parameterTypes else { return (nil, ["PARAMETER_TYPE_UNMAPPED"]) }
        var parameters: [NativeDecompilerWireAuthoredParameter] = []
        for (index, text) in parameterTypes.enumerated() {
            guard let spelling = swiftAuthoredType(text, result: false),
                  let type = try? NativeAuthoredTypeParserV1.parse(spelling, role: .parameter, catalog: types) else {
                return (nil, ["PARAMETER_TYPE_UNMAPPED"])
            }
            parameters.append(.init(name: "arg\(index)", type: type))
        }
        guard let text = demangled.resultType, let spelling = swiftAuthoredType(text, result: true),
              let result = try? NativeAuthoredTypeParserV1.parse(spelling, role: .returnType, catalog: types) else {
            return (nil, ["RESULT_TYPE_UNMAPPED"])
        }
        guard parameters.count <= 8 else { return (nil, ["TOO_MANY_PARAMETERS"]) }
        if !decision.contextIn.isEmpty || decision.asyncContextIn != nil {
            guard let pointer = try? NativeAuthoredTypeParserV1.parse("void *", role: .parameter, catalog: types)
            else { return (nil, ["CONTEXT_REGISTERS_UNMODELED"]) }
            if decision.contextIn == ["x20"] {
                parameters.append(.init(name: facts.selfKind == .none ? "context" : "self", type: pointer,
                                        storageRegister: "x20"))
            }
            if decision.asyncContextIn == "x22" {
                parameters.append(.init(name: "asyncContext", type: pointer, storageRegister: "x22"))
            }
        }
        guard isWireText(name, maximum: 1_024) else { return (nil, ["SYMBOL_NOT_PARSED"]) }
        return (.init(name: name, source: .swift, signature: .init(
            functionAddress: .init(address), returnType: result, parameterListState: .authoritative,
            parameters: parameters, variadicState: .fixed, noReturnState: .unspecified)),
                decision.errorOut == "x21" ? ["ERROR_REGISTER_UNMODELED"] : [])
    }

    private static func swiftAuthoredType(_ text: String, result: Bool) -> String? {
        switch text {
        case "Swift.Int", "Swift.Int64", "Builtin.Word": return "int64_t"
        case "Swift.UInt", "Swift.UInt64": return "uint64_t"
        case "Swift.Int32": return "int32_t"
        case "Swift.UInt32", "Swift.Unicode.Scalar": return "uint32_t"
        case "Swift.Int16": return "int16_t"
        case "Swift.UInt16": return "uint16_t"
        case "Swift.Int8": return "int8_t"
        case "Swift.UInt8": return "uint8_t"
        case "Swift.Bool": return "bool"
        case "Swift.Float": return "float"
        case "Swift.Double": return "double"
        case "Swift.OpaquePointer", "Swift.UnsafeRawPointer", "Swift.UnsafeMutableRawPointer",
             "Builtin.RawPointer", "Builtin.NativeObject", "Swift.AnyObject", "Swift.AnyClass": return "void *"
        case "()", "Swift.Void", "Swift.Never": return result ? "void" : nil
        default:
            return text.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*\.Unsafe(Mutable)?Pointer<.*>$"#,
                              options: .regularExpression) != nil ? "void *" : nil
        }
    }

    /// Direct BL targets and out-of-function B targets, decoded from the function's
    /// own effective bytes.
    static func directCalleeAddresses(
        in regions: [NativeDecompilerWireMemoryRegion],
        functionRange: Range<UInt64>
    ) -> Set<UInt64> {
        var targets = Set<UInt64>()
        for region in regions {
            let start = region.startAddress.value
            let bytes = region.effectiveBytes
            var offset = 0
            while offset + 4 <= bytes.count {
                defer { offset += 4 }
                let address = start + UInt64(offset)
                guard functionRange.contains(address) else { continue }
                let base = bytes.startIndex + offset
                let word = UInt32(bytes[base]) | UInt32(bytes[base + 1]) << 8
                    | UInt32(bytes[base + 2]) << 16 | UInt32(bytes[base + 3]) << 24
                let isCall = word & 0xfc00_0000 == 0x9400_0000
                guard isCall || word & 0xfc00_0000 == 0x1400_0000 else { continue }
                let imm26 = Int64(word & 0x03ff_ffff)
                let displacement = ((imm26 ^ 0x0200_0000) - 0x0200_0000) * 4
                let target = UInt64(bitPattern: Int64(bitPattern: address) &+ displacement)
                if isCall || !functionRange.contains(target) { targets.insert(target) }
            }
        }
        return targets
    }

    /// Linkage names by address: function symbols, then import stubs.
    private static func calleeNames(_ analysis: ImageAnalysis) -> [UInt64: String] {
        var names: [UInt64: String] = [:]
        for stub in analysis.indirectSymbols where stub.sourceSection.contains("stubs") {
            if let name = stub.symbolName, !name.isEmpty { names[stub.address] = name }
        }
        for symbol in analysis.symbols {
            if let address = symbol.address, let name = symbol.rawLinkageName, !name.isEmpty {
                names[address] = name
            }
        }
        return names
    }

    private static func overrideHint(
        _ override: FunctionSignatureOverride?,
        name: String,
        address: UInt64,
        types: NativeAuthoredCatalogIndex
    ) -> NativeDecompilerWireCalleeSignatureHint? {
        guard let override, case let .authoritative(arguments) = override.parameterList else { return nil }
        let source: NativeDecompilerWireCalleeSignatureHintSource =
            !arguments.isEmpty && arguments.allSatisfy({ $0.provenance == .debug }) ? .debug : .authored
        let variadicState: NativeDecompilerWireAuthoredVariadicState = switch override.variadicState {
        case .unspecified: .unspecified
        case .fixed: .fixed
        case .variadic: .variadic
        }
        let noReturnState: NativeDecompilerWireAuthoredNoReturnState = switch override.noReturnState {
        case .unspecified: .unspecified
        case .returns: .returns
        case .noReturn: .noReturn
        }
        return hint(name: name, source: source, address: address,
                    returnType: override.returnType,
                    parameters: arguments.map { ($0.name, $0.type) },
                    variadicState: variadicState, noReturnState: noReturnState,
                    types: types)
    }

    private static func catalogHint(
        _ signature: MacIRCallSignature?,
        name: String,
        address: UInt64,
        types: NativeAuthoredCatalogIndex
    ) -> NativeDecompilerWireCalleeSignatureHint? {
        guard let signature else { return nil }
        return hint(name: name, source: .sdk, address: address,
                    returnType: signature.returnType,
                    parameters: signature.parameters.map { ($0.name, $0.type) },
                    variadicState: signature.isVariadic ? .variadic : .fixed, noReturnState: .unspecified,
                    types: types)
    }

    /// A hint only when every type parses without a catalog definition.
    private static func hint(
        name: String,
        source: NativeDecompilerWireCalleeSignatureHintSource,
        address: UInt64,
        returnType: String?,
        parameters: [(name: String, type: String)],
        variadicState: NativeDecompilerWireAuthoredVariadicState,
        noReturnState: NativeDecompilerWireAuthoredNoReturnState,
        types: NativeAuthoredCatalogIndex
    ) -> NativeDecompilerWireCalleeSignatureHint? {
        guard isWireText(name, maximum: 1_024) else { return nil }
        let wireReturn: NativeDecompilerWireAuthoredType?
        if let returnType, !returnType.isEmpty {
            guard let parsed = try? NativeAuthoredTypeParserV1.parse(returnType, role: .returnType, catalog: types)
            else { return nil }
            wireReturn = parsed
        } else {
            wireReturn = nil
        }
        var wireParameters: [NativeDecompilerWireAuthoredParameter] = []
        for (index, parameter) in parameters.enumerated() {
            guard let type = try? NativeAuthoredTypeParserV1.parse(parameter.type, role: .parameter, catalog: types)
            else { return nil }
            let parameterName = isWireText(parameter.name, maximum: 1_024) && !parameter.name.isEmpty
                ? parameter.name : "arg\(index)"
            wireParameters.append(.init(name: parameterName, type: type))
        }
        return NativeDecompilerWireCalleeSignatureHint(
            name: name,
            source: source,
            signature: NativeDecompilerWireAuthoredSignature(
                functionAddress: .init(address),
                returnType: wireReturn,
                parameterListState: .authoritative,
                parameters: wireParameters,
                variadicState: variadicState,
                noReturnState: noReturnState
            )
        )
    }
}
