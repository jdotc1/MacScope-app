import Foundation

/// Non-void evidence only, assuming compiler-generated AAPCS64 callers (no
/// IPRA/custom convention). A direct BL followed by a modeled read of its exact
/// x0 result witnesses the callee's return contract. Missing evidence never
/// establishes void. Call boundaries, x0/w0 writes and unmodeled effects stop
/// a path; RET's inferred result and tail branches are never witnesses.
public enum MacIRCallerReturnEvidence {
    public enum Width: Int, Hashable, Sendable {
        case w0 = 32
        case x0 = 64
    }

    public static func collect(functions: [MacIRFunction]) -> [UInt64: Width] {
        let targets = Dictionary(grouping: functions, by: \.startAddress)
        let starts = Set(targets.compactMap { $0.value.count == 1 ? $0.key : nil })
        var evidence: [UInt64: Width] = [:]
        var uncertainWidths: Set<UInt64> = []
        for function in functions {
            let calls = function.instructions.compactMap { instruction -> (MacIRInstruction, UInt64, MacIRValue?)? in
                guard instruction.source.mnemonic == "bl",
                      case let .call(_, result) = instruction.operation,
                      let target = addressValue(instruction.source.operands), starts.contains(target) else { return nil }
                return (instruction, target, result)
            }
            // Multiple effects at one source address need an effect-aware CFG.
            // Refuse those callers rather than inventing instruction ordering.
            let groups = Dictionary(grouping: function.instructions, by: { $0.source.address })
            guard groups.values.allSatisfy({ $0.count == 1 }) else {
                uncertainWidths.formUnion(calls.map { $0.1 })
                continue
            }
            let instructions = groups.compactMapValues(\.first)
            var reachable: Set<UInt64> = []
            var pending = [function.startAddress]
            while let address = pending.popLast() {
                guard reachable.insert(address).inserted, let instruction = instructions[address] else { continue }
                pending += successors(of: instruction)
            }
            // The immediate raw-register witness needs control-flow reachability,
            // not a complete SSA model of earlier data instructions. Keep this
            // separate from the legacy result-lifetime walk and its width audit.
            var immediateReachable: Set<UInt64> = []
            var immediatePending = [function.startAddress]
            while let address = immediatePending.popLast() {
                guard immediateReachable.insert(address).inserted,
                      let instruction = instructions[address] else { continue }
                immediatePending += immediateCallerSuccessors(of: instruction,
                    instructions: instructions, targets: targets)
            }
            let widthUses = WidthUseIndex(function: function)
            for (call, target, possibleResult) in calls {
                // Neither witness route may use an unreachable call or the
                // nonexistent continuation of a known non-returning call.
                guard immediateReachable.contains(call.source.address),
                      let continuation = call.source.address.addressAfter(),
                      immediateCallerSuccessors(of: call, instructions: instructions,
                          targets: targets).contains(continuation) else {
                    uncertainWidths.insert(target)
                    continue
                }
                // Source-register reads survive value folding and missing call
                // result SSA. Only the immediately following instruction can
                // supply this bounded witness; targets remain raw addresses.
                if immediateReachable.contains(call.source.address),
                   let nextAddress = call.source.address.addressAfter(),
                   immediateCallerSuccessors(of: call, instructions: instructions, targets: targets).contains(nextAddress),
                   let read = immediateResultRead(after: call, instructions: instructions) {
                    if evidence[target] != .x0 { evidence[target] = read.width }
                    // Raw reads establish non-void, but a missing exact SSA
                    // input cannot support the existing whole-value width audit.
                    if possibleResult.map({ result in
                        read.inputs.contains { readWidth(of: result, in: $0, width: 64) != nil }
                    }) != true {
                        uncertainWidths.insert(target)
                    }
                }
                guard reachable.contains(call.source.address), let result = possibleResult,
                      case let .register(name, _) = result,
                      let carrier = MacIRBuilder.integerRegisterView(name), carrier.index == 0 else {
                    uncertainWidths.insert(target)
                    continue
                }
                // Witness discovery below stays path-local. Narrowing additionally
                // needs a whole-value use proof, including copies/phis beyond a
                // carrier overwrite or other boundary of the witness walk.
                if !allUsesAre32Bit(of: result, in: function, instructions: instructions, uses: widthUses) {
                    uncertainWidths.insert(target)
                }
                var visited: Set<UInt64> = []
                var work = successors(of: call)
                while let next = work.popLast() {
                    guard visited.insert(next).inserted else { continue }
                    guard let instruction = instructions[next] else {
                        uncertainWidths.insert(target)
                        continue
                    }
                    guard let inputs = modeledInputs(of: instruction.operation) else {
                        // The walk stops at carrier writes, so x0 is still
                        // live here. RET or a later call may forward all 64
                        // bits even without an explicit modeled input.
                        uncertainWidths.insert(target)
                        continue
                    }
                    for input in inputs {
                        if let width = readWidth(of: result, in: input, width: carrier.width) {
                            let observed: Width = width == 32 ? .w0 : .x0
                            if evidence[target] != .x0 { evidence[target] = observed }
                        }
                    }
                    // Reads precede writes, so e.g. add x0,x0,#1 is a witness,
                    // but a subsequent use cannot witness the old call result.
                    let writes = MacIRBuilder.argumentRegisterWrites(mnemonic: instruction.source.mnemonic,
                        operands: MacIRBuilder.splitOperands(instruction.source.operands))
                    guard !writes.contains(where: { MacIRBuilder.integerRegisterView($0)?.index == 0 }),
                          !destinations(of: instruction.operation).contains(where: isResultCarrier) else { continue }
                    let nextAddresses = successors(of: instruction)
                    if nextAddresses.isEmpty { uncertainWidths.insert(target) }
                    work += nextAddresses
                }
            }
        }
        // A missed/opaque caller or path cannot justify narrowing. This never
        // creates non-void evidence: only an already witnessed callee is widened.
        for target in uncertainWidths where evidence[target] != nil { evidence[target] = .x0 }
        return evidence
    }

    /// Control-only reachability for the bounded BL + 4 witness. No edge here
    /// changes the existing SSA witness walk or authorizes a narrower result.
    private static func immediateCallerSuccessors(of instruction: MacIRInstruction,
        instructions: [UInt64: MacIRInstruction], targets: [UInt64: [MacIRFunction]]) -> [UInt64] {
        let fallthroughAddresses = instruction.source.address.addressAfter().map { [$0] } ?? []
        func resolved(_ addresses: [UInt64]) -> [UInt64] {
            addresses.allSatisfy { instructions[$0] != nil } ? addresses : []
        }
        switch instruction.operation {
        case let .call(frame, _):
            let rawTarget = addressValue(instruction.source.operands)
            let knownTarget = rawTarget.flatMap { targets[$0] }.flatMap { $0.count == 1 ? $0.first : nil }
            if knownTarget?.isNoReturn == true || NoReturnCatalog.isNoReturn(frame.target)
                || CallSignaturePack.bundledNoReturnCanonicalNames.contains(
                    NoReturnCatalog.canonicalName(for: frame.target)) { return [] }
            return resolved(fallthroughAddresses)
        case let .conditionalBranch(_, _, _, target):
            guard let address = addressValue(target) else { return [] }
            return resolved(fallthroughAddresses + [address])
        case let .switchDispatch(_, cases, defaultTarget):
            let values = cases.map(\.target) + (defaultTarget.map { [$0] } ?? [])
            let addresses = values.compactMap(addressValue)
            guard !values.isEmpty, addresses.count == values.count else { return [] }
            return resolved(addresses)
        case .returnValue: return []
        case let .intrinsic(_, name, arguments):
            if name == "branch_register" || name == "brk" { return [] }
            if name == "branch" {
                guard instruction.source.mnemonic == "b", arguments.count == 1,
                      let target = arguments.first.flatMap(addressValue) else { return [] }
                return resolved([target])
            }
            if name.hasPrefix("branch_") {
                let suffix = String(name.dropFirst("branch_".count))
                guard instruction.source.mnemonic == "b.\(suffix)", arguments.count == 1,
                      let target = arguments.first.flatMap(addressValue) else { return [] }
                if suffix == "al" || suffix == "nv" { return resolved([target]) }
                guard ["eq", "ne", "cs", "hs", "cc", "lo", "mi", "pl", "vs", "vc",
                       "hi", "ls", "ge", "lt", "gt", "le"].contains(suffix) else { return [] }
                return resolved(fallthroughAddresses + [target])
            }
            if intrinsicInputs(name: name, arguments: arguments) != nil {
                return resolved(fallthroughAddresses)
            }
            let operands = MacIRBuilder.splitOperands(instruction.source.operands)
            if (name == "stack_alloc" && instruction.source.mnemonic == "sub")
                || (name == "stack_free" && instruction.source.mnemonic == "add") {
                guard operands.count == 3, operands[0] == "sp", operands[1] == "sp",
                      let amount = MacIRBuilder.parseImmediate(operands[2]), (0...4095).contains(amount),
                      arguments == [.immediate(amount)] else { return [] }
                return resolved(fallthroughAddresses)
            }
            if name == "adrp", instruction.source.mnemonic == "adrp" {
                guard operands.count == 2,
                      MacIRBuilder.integerRegisterView(operands[0])?.width == 64,
                      let page = addressValue(operands[1]), page & 0xfff == 0,
                      arguments.count == 1, arguments.first.flatMap(addressValue) == page else { return [] }
                return resolved(fallthroughAddresses)
            }
            return []
        case .unknown:
            return isPlainQMemory(instruction.source) ? resolved(fallthroughAddresses) : []
        case .assign, .binary, .load, .store, .loadWriteback, .storeWriteback,
             .stackSlotRead, .stackSlotPairRead, .select, .compareToBool:
            return resolved(fallthroughAddresses)
        }
    }

    /// Exact plain Q-register loads/stores cannot change control flow. Their
    /// data effects remain opaque; indexed and writeback forms are not admitted.
    private static func isPlainQMemory(_ source: MacIRSourceSpan) -> Bool {
        let mnemonic = source.mnemonic
        guard ["ldr", "ldur", "str", "stur", "ldp", "stp"].contains(mnemonic) else { return false }
        let pair = mnemonic == "ldp" || mnemonic == "stp"
        let operands = MacIRBuilder.splitOperands(source.operands)
        guard operands.count == (pair ? 3 : 2) else { return false }
        for register in operands.dropLast() {
            guard register.hasPrefix("q"), let index = Int(register.dropFirst()),
                  (0...31).contains(index), register == "q\(index)" else { return false }
        }
        guard let memory = operands.last, memory.hasPrefix("["), memory.hasSuffix("]") else { return false }
        let parts = MacIRBuilder.splitOperands(String(memory.dropFirst().dropLast()))
        guard (1...2).contains(parts.count) else { return false }
        if parts[0] != "sp" {
            guard let base = MacIRBuilder.integerRegisterView(parts[0]), base.width == 64,
                  (0...30).contains(base.index), parts[0] == "x\(base.index)" else { return false }
        }
        var offset: Int64 = 0
        if parts.count == 2 {
            guard parts[1].hasPrefix("#") else { return false }
            var digits = Substring(parts[1].dropFirst())
            let negative = digits.hasPrefix("-")
            if negative { digits = digits.dropFirst() }
            let hexadecimal = digits.hasPrefix("0x")
            if hexadecimal { digits = digits.dropFirst(2) }
            let alphabet = hexadecimal ? "0123456789abcdef" : "0123456789"
            guard !digits.isEmpty, digits.allSatisfy({ alphabet.contains($0) }),
                  let magnitude = UInt64(digits, radix: hexadecimal ? 16 : 10), magnitude <= 65520 else { return false }
            offset = negative ? -Int64(magnitude) : Int64(magnitude)
        }
        if pair { return (-1024...1008).contains(offset) && offset % 16 == 0 }
        if mnemonic == "ldur" || mnemonic == "stur" { return (-256...255).contains(offset) }
        return (0...65520).contains(offset) && offset % 16 == 0
    }

    /// Read-before-write effects in the instruction at BL + 4 witness the
    /// returned register even when lifting folded its value. Control transfers
    /// with unresolved successors, calls, returns and opaque effects refuse.
    private static func immediateResultRead(after call: MacIRInstruction,
                                            instructions: [UInt64: MacIRInstruction])
        -> (width: Width, inputs: [MacIRValue])? {
        guard let address = call.source.address.addressAfter(),
              let instruction = instructions[address],
              let inputs = modeledInputs(of: instruction.operation) else { return nil }
        if case let .conditionalBranch(_, _, _, target) = instruction.operation {
            guard let targetAddress = addressValue(target), instructions[targetAddress] != nil,
                  let fallthroughAddress = address.addressAfter(),
                  instructions[fallthroughAddress] != nil else { return nil }
        }
        if case .intrinsic(_, "branch", _) = instruction.operation { return nil }
        let widths = MacIRBuilder.argumentRegisterReads(mnemonic: instruction.source.mnemonic,
            operands: MacIRBuilder.splitOperands(instruction.source.operands))
            .compactMap { MacIRBuilder.integerRegisterView($0) }
            .filter { $0.index == 0 }
            .map(\.width)
        guard let width = widths.max() else { return nil }
        return (width == 32 ? .w0 : .x0, inputs)
    }

    /// Candidate filtering only: the original predicates below still decide widths.
    /// They match exact values at every expression level. auditedReadWidth also
    /// treats a nested unknown as a wildcard, whereas phi readWidth does not.
    private struct WidthUseIndex {
        var instructions: [MacIRValue: [Int]] = [:]
        var phis: [MacIRValue: [Int]] = [:]
        var wildcardInstructions: [Int] = []

        init(function: MacIRFunction) {
            func values(in inputs: [MacIRValue]) -> (Set<MacIRValue>, Bool) {
                var pending = inputs, found: Set<MacIRValue> = []
                var unknown = false
                while let value = pending.popLast() {
                    guard found.insert(value).inserted else { continue }
                    switch value {
                    case let .unary(_, inner), let .bitTest(inner, _): pending.append(inner)
                    case let .signedBitfield(node): pending.append(node.source)
                    case let .binaryExpression(_, left, right): pending += [left, right]
                    case let .abiComposite(_, fragments): pending += fragments
                    case .unknown: unknown = true
                    default: break
                    }
                }
                return (found, unknown)
            }
            for (index, instruction) in function.instructions.enumerated() {
                var inputs = (modeledInputs(of: instruction.operation) ?? []) + unclassifiedInputs(of: instruction)
                if case let .call(frame, _) = instruction.operation {
                    inputs += frame.controlInputs.bindingValues
                        + (frame.richArguments?.flatMap { $0.pieces.map(\.value) } ?? [])
                        + (frame.indirectResultPointer.map { [$0] } ?? [])
                        + frame.arguments.canonicalPhysicalEntriesForAudit.map(\.value)
                }
                let (keys, unknown) = values(in: inputs)
                for key in keys { instructions[key, default: []].append(index) }
                if unknown { wildcardInstructions.append(index) }
            }
            for (index, phi) in function.phis.enumerated() {
                for key in values(in: phi.incoming.map(\.value)).0 { phis[key, default: []].append(index) }
            }
        }

        func instructionIndices(for value: MacIRValue) -> [Int] {
            let exact = instructions[value] ?? []
            guard !wildcardInstructions.isEmpty else { return exact }
            var result: [Int] = [], i = 0, j = 0
            while i < exact.count || j < wildcardInstructions.count {
                if j == wildcardInstructions.count || (i < exact.count && exact[i] < wildcardInstructions[j]) {
                    result.append(exact[i]); i += 1
                } else if i == exact.count || wildcardInstructions[j] < exact[i] {
                    result.append(wildcardInstructions[j]); j += 1
                } else {
                    result.append(exact[i]); i += 1; j += 1
                }
            }
            return result
        }
    }

    #if DEBUG
    static func widthFactsForTesting(result: MacIRValue, function: MacIRFunction,
                                     expression: MacIRValue) -> (candidates: [Int], indexed: Bool,
                                         fullScan: Bool, auditedWidth: Int?, readWidth: Int?) {
        let index = WidthUseIndex(function: function)
        var fullScan = index
        let values = Set(index.instructions.keys).union(index.phis.keys).union([result])
        for value in values {
            fullScan.instructions[value] = Array(function.instructions.indices)
            fullScan.phis[value] = Array(function.phis.indices)
        }
        fullScan.wildcardInstructions = []
        let rows = Dictionary(function.instructions.map { ($0.source.address, $0) },
                              uniquingKeysWith: { first, _ in first })
        return (index.instructionIndices(for: result),
            allUsesAre32Bit(of: result, in: function, instructions: rows, uses: index),
            allUsesAre32Bit(of: result, in: function, instructions: rows, uses: fullScan),
            auditedReadWidth(of: result, in: expression),
            readWidth(of: result, in: expression, width: 64))
    }
    #endif

    /// Follow forwarding definitions to a fixed point. This proof can only veto
    /// narrowing; it never creates a witness, even when it finds a wide read.
    private static func allUsesAre32Bit(of result: MacIRValue, in function: MacIRFunction,
                                       instructions: [UInt64: MacIRInstruction], uses: WidthUseIndex,
                                       classifyTypedCalls: Bool = false) -> Bool {
        var pending = [result]
        var visited: Set<MacIRValue> = []
        while let value = pending.popLast() {
            guard visited.insert(value).inserted else { continue }
            for index in uses.instructionIndices(for: value) {
                let instruction = function.instructions[index]
                // Return operands, call arguments/control inputs, unknown
                // effects and unresolved transfer targets cannot prove a
                // 32-bit-only read, including through a forwarded copy.
                if classifyTypedCalls, case let .call(frame, _) = instruction.operation {
                    let controlInputs = (instruction.returnTarget.map { [$0] } ?? [])
                        + frame.controlInputs.bindingValues
                        + (frame.richArguments?.flatMap { $0.pieces.map(\.value) } ?? [])
                        + (frame.indirectResultPointer.map { [$0] } ?? [])
                    if controlInputs.contains(where: { auditedReadWidth(of: value, in: $0) != nil }) { return false }
                    for argument in frame.arguments.canonicalPhysicalEntriesForAudit {
                        guard auditedReadWidth(of: value, in: argument.value) != nil else { continue }
                        guard typedCallArgumentReadWidth(of: value, argument: argument, frame: frame) == 32 else { return false }
                    }
                } else {
                    for input in unclassifiedInputs(of: instruction) {
                        if auditedReadWidth(of: value, in: input) != nil { return false }
                    }
                }
                for input in modeledInputs(of: instruction.operation) ?? [] {
                    if let width = auditedReadWidth(of: value, in: input), width != 32 { return false }
                }
                if case let .assign(destination, source) = instruction.operation,
                   readWidth(of: value, in: source, width: 64) != nil {
                    guard isFollowable(destination) else { return false }
                    pending.append(destination)
                }
            }
            for index in uses.phis[value] ?? [] {
                let phi = function.phis[index]
                let incoming = phi.incoming.filter { readWidth(of: value, in: $0.value, width: 64) != nil }
                guard !incoming.isEmpty else { continue }
                // A phi forwards the value; it does not itself establish a
                // narrow read. Refuse malformed/unresolved edges and expressions.
                guard incoming.allSatisfy({ $0.value == value }),
                      phi.bitWidth == 32 || phi.bitWidth == 64,
                      instructions[phi.blockAddress] != nil,
                      phi.incoming.allSatisfy({ incoming in
                          guard let address = incoming.machineAddress else { return false }
                          return instructions[address] != nil
                      }),
                      isFollowable(phi.destination) else { return false }
                pending.append(phi.destination)
            }
        }
        return true
    }

    /// A declared fixed argument identifies its physical read width. Only a
    /// direct value or immediate register view can inherit a narrow carrier;
    /// converting an already evaluated expression cannot narrow its inputs.
    private static func typedCallArgumentReadWidth(of result: MacIRValue,
        argument: MacIRCallArgument, frame: MacIRCallFrame) -> Int? {
        guard let signature = frame.knownSignature ?? frame.typedIndirectSignature,
              let position = argument.sourcePosition,
              let parameter = signature.parameters.first(where: { $0.index == position }),
              case let .gpr(_, carrierWidth) = argument.location,
              MacIRCallArgumentLocation(register: parameter.register) == argument.location,
              readWidth(of: result, in: argument.value, width: 64) != nil else { return nil }
        if carrierWidth == 64 { return 64 }
        if argument.value == result { return 32 }
        if case let .unary(op, inner) = argument.value,
           inner == result, op == "(uint32_t)" || op == "(int32_t)" { return 32 }
        return auditedReadWidth(of: result, in: argument.value)
    }

    private static func isFollowable(_ value: MacIRValue) -> Bool {
        switch value {
        case .register, .temporary: return true
        default: return false
        }
    }

    /// Only an immediate 32-bit register view proves a narrow read. A cast of
    /// an already evaluated wider expression cannot narrow its operand reads.
    private static func auditedReadWidth(of result: MacIRValue, in value: MacIRValue) -> Int? {
        if value == result {
            if case let .register(name, _) = value {
                return MacIRBuilder.integerRegisterView(name)?.width ?? 64
            }
            return 64
        }
        switch value {
        case let .unary(op, inner):
            // Reading xN after a wN definition is represented as
            // uint64_t(uint32_t(wN)). It is still a wide use of the copy.
            if (op == "(uint64_t)" || op == "(int64_t)"),
               readWidth(of: result, in: inner, width: 64) != nil { return 64 }
            if inner == result && (op == "(uint32_t)" || op == "(int32_t)") { return 32 }
            return auditedReadWidth(of: result, in: inner)
        case let .signedBitfield(node):
            return auditedReadWidth(of: result, in: node.source)
        case let .bitTest(inner, _): return auditedReadWidth(of: result, in: inner)
        case let .binaryExpression(_, left, right):
            return [auditedReadWidth(of: result, in: left), auditedReadWidth(of: result, in: right)]
                .compactMap { $0 }.max()
        case let .abiComposite(_, fragments):
            return fragments.compactMap { auditedReadWidth(of: result, in: $0) }.max()
        case .unknown: return 64 // opaque input cannot establish absence of a wider read
        case .register, .argument, .argumentFragment, .immediate, .stackSlot, .symbol, .temporary: return nil
        }
    }

    private static func unclassifiedInputs(of instruction: MacIRInstruction) -> [MacIRValue] {
        var inputs = instruction.returnTarget.map { [$0] } ?? []
        switch instruction.operation {
        case let .call(frame, _): inputs += frame.bindingValues
        case let .unknown(_, unknown, _, _): inputs += unknown.mayRead.map(\.value)
        case let .switchDispatch(index, cases, defaultTarget):
            inputs += [index] + cases.map(\.target) + (defaultTarget.map { [$0] } ?? [])
        case let .conditionalBranch(_, _, _, target): inputs.append(target)
        case let .intrinsic(_, name, arguments):
            if name == "branch" || intrinsicInputs(name: name, arguments: arguments) == nil {
                inputs += arguments
            }
        // A return operand can escape to the caller's caller at full width.
        // Like the explicit control target above, it only vetoes narrowing;
        // modeledInputs still excludes RET so it never creates a witness.
        case let .returnValue(value): inputs += value.map { [$0] } ?? []
        case .assign, .binary, .load, .store, .loadWriteback, .storeWriteback,
             .stackSlotRead, .stackSlotPairRead, .select, .compareToBool: break
        }
        return inputs
    }

    private static func addressValue(_ text: String) -> UInt64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
    }

    private static func addressValue(_ value: MacIRValue) -> UInt64? {
        switch value {
        case let .immediate(address) where address >= 0: return UInt64(address)
        case let .symbol(text): return addressValue(text)
        default: return nil
        }
    }

    private static func successors(of instruction: MacIRInstruction) -> [UInt64] {
        let fallthroughAddress = instruction.source.address.addressAfter().map { [$0] } ?? []
        switch instruction.operation {
        case let .conditionalBranch(_, _, _, target):
            guard let target = addressValue(target) else { return [] }
            return fallthroughAddress + [target]
        case let .intrinsic(nil, "branch", arguments) where instruction.source.mnemonic == "b":
            return arguments.first.flatMap(addressValue).map { [$0] } ?? []
        case let .intrinsic(_, name, arguments):
            return intrinsicInputs(name: name, arguments: arguments) == nil ? [] : fallthroughAddress
        case .returnValue, .unknown, .switchDispatch: return []
        default: return fallthroughAddress
        }
    }

    /// Nil means that no read or continuation is admitted at this boundary.
    private static func modeledInputs(of operation: MacIROperation) -> [MacIRValue]? {
        switch operation {
        case let .assign(_, source): return [source]
        case let .binary(_, _, left, right): return [left, right]
        case let .load(_, address): return [address]
        case let .store(source, address): return [source, address]
        case let .loadWriteback(_, _, base, _, _): return [base]
        case let .storeWriteback(source, _, base, _, _): return [source, base]
        case let .stackSlotRead(_, slot, value): return [slot, value]
        case let .stackSlotPairRead(_, firstSlot, first, _, secondSlot, second):
            return [firstSlot, first, secondSlot, second]
        case let .conditionalBranch(_, left, right, _): return [left, right]
        case let .select(_, _, left, right, yes, no): return [left, right, yes, no]
        case let .compareToBool(_, _, left, right): return [left, right]
        case .intrinsic(nil, "branch", _): return []
        case let .intrinsic(_, name, arguments): return intrinsicInputs(name: name, arguments: arguments)
        case .call, .returnValue, .unknown, .switchDispatch: return nil
        }
    }

    /// These modeled intrinsics have ordinary fallthrough. Pair loads carry
    /// destinations in their argument list: only their address is a read.
    private static func intrinsicInputs(name: String, arguments: [MacIRValue]) -> [MacIRValue]? {
        switch name {
        case "compare", "save_pair": return arguments
        case "save_pair_writeback": return Array(arguments.prefix(3))
        case "restore_pair": return Array(arguments.dropFirst(2))
        case "restore_pair_writeback": return arguments.count >= 3 ? [arguments[2]] : nil
        case "nop", "pacibsp", "paciasp", "autibsp", "autiasp", "xpaclri": return []
        default: return nil
        }
    }

    private static func readWidth(of result: MacIRValue, in value: MacIRValue, width: Int) -> Int? {
        if value == result { return width }
        switch value {
        case let .unary(op, inner):
            let narrowed = op == "(uint32_t)" || op == "(int32_t)"
            return readWidth(of: result, in: inner, width: narrowed ? 32 : width)
        case let .signedBitfield(node):
            return readWidth(of: result, in: node.source, width: node.operandBits)
        case let .bitTest(inner, _): return readWidth(of: result, in: inner, width: width)
        case let .binaryExpression(_, left, right):
            return [readWidth(of: result, in: left, width: width),
                    readWidth(of: result, in: right, width: width)].compactMap { $0 }.max()
        case let .abiComposite(_, fragments):
            return fragments.compactMap { readWidth(of: result, in: $0, width: width) }.max()
        default: return nil
        }
    }

    private static func isResultCarrier(_ value: MacIRValue) -> Bool {
        guard case let .register(name, _) = value else { return false }
        return MacIRBuilder.integerRegisterView(name)?.index == 0
    }

    private static func destinations(of operation: MacIROperation) -> [MacIRValue] {
        switch operation {
        case let .assign(destination, _), let .binary(destination, _, _, _),
             let .load(destination, _), let .stackSlotRead(destination, _, _),
             let .select(destination, _, _, _, _, _), let .compareToBool(destination, _, _, _):
            return [destination]
        case let .loadWriteback(destination, base, _, _, _): return [destination, base]
        case let .storeWriteback(_, base, _, _, _): return [base]
        case let .stackSlotPairRead(first, _, _, second, _, _): return [first, second]
        default: return []
        }
    }
}

/// Declaration-backed own-return contracts for literal function addresses installed
/// in callback fields. This inventory does not resolve calls or infer parameters.
public enum MacIRSlotReturnAuthority {
    public struct StoreEvidence: Codable, Sendable {
        public let functionStart: UInt64
        public let address: UInt64
        public let returnType: String?
        public let reason: String?
        public var slotSignature: FunctionPointerSignatureV1? = nil
    }

    public struct Entry: Codable, Sendable {
        public let target: UInt64
        public let stores: [StoreEvidence]
        public let admittedType: String?
        public let vetoReasons: [String]
    }

    public struct ParameterRoot: Codable, Sendable {
        public let functionStart: UInt64
        public let parameterIndex: Int
        public let registerIndex: Int
        public let type: String
        public let round: Int
    }

    public struct Report: Codable, Sendable {
        /// Compatibility view for own-return diagnostics. Slot observations
        /// never establish the stored function's own declaration.
        public var returnTypes: [UInt64: String] { [:] }
        /// Caller-side permission to omit an unused direct-call result only.
        /// This set is not a callee return type or a return-contract source.
        public let callerSideVoidResultTargets: Set<UInt64>
        public let entries: [Entry]
        public let parameterRoots: [ParameterRoot]
    }

    public static func collect(functions: [MacIRFunction], types: [TypeDefinition],
                               signatures: [UInt64: FunctionSignatureOverride],
                               callerReturns: [UInt64: MacIRCallerReturnEvidence.Width]) -> Report {
        collectWithCallerUseEvidence(functions: functions, types: types,
            signatures: signatures, callerReturns: callerReturns,
            directCallSources: nil, callerFunctions: nil)
    }

    static func collectWithCallerUseEvidence(functions: [MacIRFunction], types: [TypeDefinition],
                               signatures: [UInt64: FunctionSignatureOverride],
                               callerReturns: [UInt64: MacIRCallerReturnEvidence.Width],
                               directCallSources: [MacIRSourceSpan]?,
                               callerFunctions: [MacIRFunction]?) -> Report {
        // Only an explicit complete raw-call inventory can justify a negative
        // use claim. Reuse the completed lift; absence of callerReturns is not proof.
        let discardedTargets = directCallSources.map {
            MacIRCallerReturnEvidence.discardedDirectCallTargets(
                functions: callerFunctions ?? functions, directCalls: $0, callerWidths: callerReturns)
        } ?? []
        let starts = Set(functions.map(\.startAddress))
        let catalog = Dictionary(grouping: types, by: \.name).compactMapValues { $0.count == 1 ? $0.first : nil }
        // A stored pointer may have been cast. Slot prototypes describe the
        // indirect caller's ABI, not the target's own return or parameter types.
        // Keep the store/conflict ledger, but never bootstrap callee roots from
        // it. Independently declared roots already present in the functions are
        // still available to Facts; caller-side SlotTypedPrototypeBinding is separate.
        var observations: [UInt64: [StoreEvidence]] = [:]
        for function in functions {
            let data = StaticFacts(function: function, starts: starts)
            let facts = Facts(data: data, catalog: catalog, inferredRoots: [:])
            for (target, stores) in facts.collect() {
                observations[target, default: []] += stores
            }
        }
        var callerSideVoidResultTargets: Set<UInt64> = []
        let entries = observations.keys.sorted().map { target -> Entry in
            let stores = observations[target, default: []].sorted {
                ($0.functionStart, $0.address, $0.reason ?? "", $0.returnType ?? "") <
                ($1.functionStart, $1.address, $1.reason ?? "", $1.returnType ?? "")
            }
            let candidates = Set(stores.compactMap(\.returnType))
            var vetoes = Set(stores.compactMap(\.reason))
            if candidates.count > 1 { vetoes.insert("conflicting slot return types") }
            if candidates.isEmpty { vetoes.insert("no admitted slot declaration") }
            if signatures[target] != nil { vetoes.insert("existing signature takes precedence") }
            if candidates.contains("void"), callerReturns[target] != nil {
                vetoes.insert("positive caller return evidence conflicts with void")
            }
            if candidates.contains("void"), !discardedTargets.contains(target) {
                vetoes.insert("direct call result is not proved dead at every site")
            }
            // Every direct site must have a complete read-before-redefinition
            // proof. Store/declaration and positive-use vetoes remain separate;
            // this permission never supplies the target's own declaration.
            if vetoes.isEmpty, candidates == Set(["void"]) {
                callerSideVoidResultTargets.insert(target)
            }
            // Independent signatures/caller evidence retain their existing
            // paths. Do not copy them into a slot-derived authority map or let
            // slot conflicts revoke them. Own constants are likewise handled
            // by the existing builder, never inferred here from slot stores.
            vetoes.insert("slot observations do not establish own declaration")
            return Entry(target: target, stores: stores, admittedType: nil, vetoReasons: vetoes.sorted())
        }
        // Own-return and parameter-root projections stay empty. The separate
        // caller-only set cannot type the callee or seed a declaration root.
        let report = Report(callerSideVoidResultTargets: callerSideVoidResultTargets,
                            entries: entries, parameterRoots: [])
        #if DEBUG
        // Opt-in diagnostics reuse this completed collection; never rebuild IR or
        // rerun the witness to obtain the per-target authority ledger.
        if ProcessInfo.processInfo.environment["MACSCOPE_SLOT_RETURN_DIAGNOSTICS"] == "1",
           let data = try? JSONEncoder().encode(report), let json = String(data: data, encoding: .utf8) {
            print("SLOT_RETURN_AUTHORITY " + json)
        }
        #endif
        return report
    }

    #if DEBUG
    static func targetSetsForTesting(function: MacIRFunction, starts: Set<UInt64>,
                                     queries: [(MacIRValue, Int)]) -> [Set<UInt64>] {
        let data = StaticFacts(function: function, starts: starts)
        return queries.map { data.targets($0.0, at: $0.1, starts: starts) }
    }
    #endif

    private struct Store {
        let index: Int
        let source: MacIRValue
        let address: MacIRValue
        let width: Int?
    }

    private struct Pointer: Hashable {
        let type: String
        let offset: Int64
        var dependencies: Set<MacIRValue> = []
    }

    private struct ValueUse: Hashable {
        let value: MacIRValue
        let index: Int
    }

    private final class ConstantMemo {
        struct Result { let value: Int64? }
        var values: [ValueUse: Result] = [:]
    }

    /// Condense the lazy ValueUse graph with iterative Tarjan. Finished nodes
    /// share one reach set per SCC; an absent set means a completed empty SCC.
    private final class ReachMemo {
        private struct Frame {
            let node: ValueUse
            let next: [ValueUse]
            let terminal: UInt64?
            var cursor = 0
        }
        private var component: [ValueUse: Int] = [:]
        private var nonempty: [Int: Set<UInt64>] = [:]
        private var componentCount = 0

        func targets(_ root: ValueUse,
                     successors: (ValueUse) -> (terminal: UInt64?, next: [ValueUse])) -> Set<UInt64> {
            if let id = component[root] { return nonempty[id] ?? [] }
            var indices: [ValueUse: Int] = [:], low: [ValueUse: Int] = [:]
            var active: Set<ValueUse> = [], stack: [ValueUse] = []
            var frames: [Frame] = [], edges: [ValueUse: Frame] = [:]
            func discover(_ node: ValueUse) {
                let index = indices.count
                indices[node] = index; low[node] = index
                active.insert(node); stack.append(node)
                let (terminal, next) = successors(node)
                let frame = Frame(node: node, next: next, terminal: terminal)
                edges[node] = frame; frames.append(frame)
            }
            discover(root)
            while !frames.isEmpty {
                let top = frames.count - 1
                let node = frames[top].node
                if frames[top].cursor < frames[top].next.count {
                    let next = frames[top].next[frames[top].cursor]
                    frames[top].cursor += 1
                    if component[next] != nil { continue }
                    if let index = indices[next] {
                        if active.contains(next) { low[node] = min(low[node]!, index) }
                    } else { discover(next) }
                    continue
                }
                frames.removeLast()
                if low[node] == indices[node] {
                    let id = componentCount
                    componentCount += 1
                    var members: [ValueUse] = []
                    while let member = stack.popLast() {
                        active.remove(member); component[member] = id; members.append(member)
                        if member == node { break }
                    }
                    var found: Set<UInt64> = []
                    for member in members {
                        guard let frame = edges.removeValue(forKey: member) else { continue }
                        if let terminal = frame.terminal { found.insert(terminal) }
                        for next in frame.next {
                            if let successor = component[next], successor != id,
                               let values = nonempty[successor] { found.formUnion(values) }
                        }
                    }
                    if !found.isEmpty { nonempty[id] = found }
                }
                if let parent = frames.last?.node { low[parent] = min(low[parent]!, low[node]!) }
            }
            return component[root].flatMap { nonempty[$0] } ?? []
        }
    }

    /// Rooted dom-tree components receive nested intervals. Malformed or absent
    /// components retain the bounded parent walk, including its missing-parent semantics.
    struct DominanceIntervals {
        private var enter: [Int: Int] = [:]
        private var exit: [Int: Int] = [:]

        init(domTree: [Int: Int]) {
            var children: [Int: [Int]] = [:]
            for (child, parent) in domTree where child != parent {
                children[parent, default: []].append(child)
            }
            var clock = 0
            for (root, parent) in domTree where root == parent {
                var pending: [(block: Int, closing: Bool)] = [(root, false)]
                while let frame = pending.popLast() {
                    if frame.closing {
                        exit[frame.block] = clock
                        clock += 1
                    } else {
                        enter[frame.block] = clock
                        clock += 1
                        pending.append((frame.block, true))
                        for child in children[frame.block] ?? [] {
                            pending.append((child, false))
                        }
                    }
                }
            }
        }

        func dominates(_ definition: Int, _ use: Int, cfg: CFG, blocks: [Int: Int]) -> Bool {
            guard !cfg.hasUnresolvedTargets, let source = blocks[definition], let destination = blocks[use],
                  cfg.domTree[destination] != nil else { return false }
            if source == destination { return definition < use }
            if let sourceEnter = enter[source], let sourceExit = exit[source],
               let destinationEnter = enter[destination], let destinationExit = exit[destination] {
                return sourceEnter <= destinationEnter && destinationExit <= sourceExit
            }
            var block = destination
            var seen: Set<Int> = []
            while seen.insert(block).inserted, let parent = cfg.domTree[block], parent != block {
                if parent == source { return true }
                block = parent
            }
            return false
        }
    }

    /// All data here depends only on this function and the collection's starts.
    /// One instance per array position preserves duplicate-function ordering.
    private final class StaticFacts {
        let function: MacIRFunction
        let cfg: CFG
        let dominance: DominanceIntervals
        var blocks: [Int: Int] = [:]
        var definitions: [MacIRValue: [Int]] = [:]
        var phiValues: Set<MacIRValue> = []
        var phiIncomingByDestination: [MacIRValue: [[MacIRValue]]] = [:]
        var stores: [Store] = []
        var storesByIndex: [Int: [Store]] = [:]
        let constants = ConstantMemo()
        let reach = ReachMemo()
        var foundStores: [Set<UInt64>] = []
        var exactStores: [UInt64?] = []
        var escapeRecords: [UInt64: [StoreEvidence]] = [:]

        init(function: MacIRFunction, starts: Set<UInt64>) {
            self.function = function
            cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            dominance = DominanceIntervals(domTree: cfg.domTree)
            for block in cfg.blocks {
                for index in block.instructionRange { blocks[index] = block.index }
            }
            phiValues = Set(function.phis.map(\.destination))
            phiIncomingByDestination = Dictionary(grouping: function.phis, by: \.destination)
                .mapValues { $0.map { $0.incoming.map(\.value) } }
            for (index, instruction) in function.instructions.enumerated() {
                for value in Facts.destinations(instruction.operation) { definitions[value, default: []].append(index) }
                switch instruction.operation {
                case let .store(source, address):
                    stores.append(Store(index: index, source: source, address: address,
                                        width: instruction.memoryAccess?.byteWidth))
                case let .intrinsic(nil, "save_pair", arguments) where arguments.count == 3:
                    let operands = MacIRBuilder.splitOperands(instruction.source.operands)
                    let is64 = instruction.source.mnemonic == "stp" && operands.count == 3 &&
                        MacIRBuilder.integerRegisterView(operands[0])?.width == 64 &&
                        MacIRBuilder.integerRegisterView(operands[1])?.width == 64
                    stores.append(Store(index: index, source: arguments[0], address: arguments[2], width: is64 ? 8 : nil))
                    stores.append(Store(index: index, source: arguments[1],
                                        address: .binaryExpression(op: "+", left: arguments[2], right: .immediate(8)),
                                        width: is64 ? 8 : nil))
                default: break
                }
            }
            storesByIndex = Dictionary(grouping: stores, by: \.index)
            for store in stores {
                foundStores.append(targets(store.source, at: store.index, starts: starts))
                exactStores.append(constant(store.source, at: store.index).flatMap { $0 >= 0 ? UInt64($0) : nil })
            }
            for (index, instruction) in function.instructions.enumerated() {
                let inputs: [MacIRValue]
                if let indexedStores = storesByIndex[index] {
                    // The address itself is an escape if it denotes a function.
                    inputs = indexedStores.map(\.address)
                } else {
                    switch instruction.operation {
                    case .assign, .binary, .intrinsic(_, "adrp", _): continue
                    case .intrinsic(nil, "branch", _): continue
                    case let .conditionalBranch(_, left, right, _): inputs = [left, right]
                    case let .switchDispatch(value, _, _): inputs = [value]
                    default: inputs = Facts.inputs(instruction.operation)
                    }
                }
                let escaped = inputs.reduce(into: Set<UInt64>()) { $0.formUnion(targets($1, at: index, starts: starts)) }
                for target in escaped {
                    escapeRecords[target, default: []].append(StoreEvidence(functionStart: function.startAddress,
                        address: instruction.source.address, returnType: nil,
                        reason: "address escape outside a typed callback store"))
                }
            }
        }

        func dominates(_ definition: Int, _ use: Int) -> Bool {
            dominance.dominates(definition, use, cfg: cfg, blocks: blocks)
        }

        func definition(_ value: MacIRValue, at use: Int) -> Int? {
            guard !phiValues.contains(value), let indices = definitions[value], indices.count == 1,
                  let index = indices.first, dominates(index, use) else { return nil }
            return index
        }

        func constant(_ value: MacIRValue, at use: Int, seen: Set<MacIRValue> = []) -> Int64? {
            let key = ValueUse(value: value, index: use)
            if let cached = constants.values[key] { return cached.value }
            let result = uncachedConstant(value, at: use, seen: seen)
            // Accepted definition edges strictly descend through dominance;
            // phis and duplicate definitions are refused. Cache completed proofs
            // (including failure), never partially explored escape/phi graphs.
            constants.values[key] = ConstantMemo.Result(value: result)
            return result
        }

        func uncachedConstant(_ value: MacIRValue, at use: Int, seen: Set<MacIRValue>) -> Int64? {
            guard !seen.contains(value) else { return nil }
            let next = seen.union([value])
            switch value {
            case let .immediate(number): return number
            case let .symbol(text):
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.hasPrefix("0x") ? Int64(text.dropFirst(2), radix: 16) : Int64(text)
            case let .binaryExpression(op, left, right):
                guard let lhs = constant(left, at: use, seen: next),
                      let rhs = constant(right, at: use, seen: next) else { return nil }
                return Facts.arithmetic(op, lhs, rhs)
            default: break
            }
            guard let index = definition(value, at: use) else { return nil }
            switch function.instructions[index].operation {
            case let .assign(_, source): return constant(source, at: index, seen: next)
            case let .binary(_, op, left, right):
                guard let lhs = constant(left, at: index, seen: next),
                      let rhs = constant(right, at: index, seen: next) else { return nil }
                return Facts.arithmetic(op, lhs, rhs)
            case let .intrinsic(_, "adrp", arguments) where arguments.count == 1:
                return constant(arguments[0], at: index, seen: next)
            default: return nil
            }
        }

        func targetSuccessors(of use: ValueUse, starts: Set<UInt64>) -> (terminal: UInt64?, next: [ValueUse]) {
            if let number = constant(use.value, at: use.index), number >= 0,
               starts.contains(UInt64(number)) { return (UInt64(number), []) }
            var next: [ValueUse] = []
            let components: [MacIRValue]
            switch use.value {
            case let .binaryExpression(_, left, right): components = [left, right]
            case let .unary(_, inner), let .bitTest(inner, _): components = [inner]
            case let .signedBitfield(node): components = [node.source]
            case let .abiComposite(_, fragments): components = fragments
            default: components = []
            }
            next += components.map { ValueUse(value: $0, index: use.index) }
            // Refused def-use proofs still supply veto evidence. Never
            // lose an address merely because its use is an ambiguous join.
            for definition in definitions[use.value] ?? [] {
                let forwarded: [MacIRValue]
                switch function.instructions[definition].operation {
                case let .assign(_, source): forwarded = [source]
                case let .binary(_, _, left, right): forwarded = [left, right]
                case let .select(_, _, _, _, yes, no): forwarded = [yes, no]
                case let .intrinsic(_, "adrp", arguments): forwarded = arguments
                default: forwarded = []
                }
                next += forwarded.map { ValueUse(value: $0, index: definition) }
            }
            for incoming in phiIncomingByDestination[use.value] ?? [] {
                next += incoming.map { ValueUse(value: $0, index: use.index) }
            }
            return (nil, next)
        }

        func targets(_ value: MacIRValue, at index: Int, starts: Set<UInt64>) -> Set<UInt64> {
            reach.targets(ValueUse(value: value, index: index)) { targetSuccessors(of: $0, starts: starts) }
        }

    }

    private struct IdentityResult {
        let value: MacIRValue?
        let cycleRefused: Bool
    }

    private final class ObjectMemo {
        struct PointerResult { let value: Pointer? }
        var identities: [ValueUse: IdentityResult] = [:]
        var pointers: [ValueUse: PointerResult] = [:]

        func clear() {
            identities.removeAll(keepingCapacity: true)
            pointers.removeAll(keepingCapacity: true)
        }
    }

    private struct Facts {
        let data: StaticFacts
        let catalog: [String: TypeDefinition]
        var function: MacIRFunction { data.function }
        var cfg: CFG { data.cfg }
        var blocks: [Int: Int] { data.blocks }
        var definitions: [MacIRValue: [Int]] { data.definitions }
        var phiValues: Set<MacIRValue> { data.phiValues }
        var stores: [Store] { data.stores }
        var roots: [MacIRValue: String] = [:]
        var registrations: [MacIRValue: Set<String>] = [:]
        var registrationDependencies: [MacIRValue: Set<MacIRValue>] = [:]
        var ambiguousIdentities: Set<MacIRValue> = []
        let objects = ObjectMemo()

        init(data: StaticFacts, catalog: [String: TypeDefinition], inferredRoots: [Int: String]) {
            self.data = data
            self.catalog = catalog
            for (index, type) in inferredRoots {
                roots[.register(name: "x\(index)", version: 0)] = type
                for parameter in function.parameters where parameter.abiLocation == .gpr(index: index, carrierWidth: 64) {
                    if let binding = parameter.bindingID { roots[.argument(bindingID: binding)] = type }
                }
            }
            for parameter in function.parameters {
                guard let type = Self.pointeeName(parameter.type, catalog: catalog),
                      case let .gpr(index, width) = parameter.abiLocation, width == 64 else { continue }
                if let binding = parameter.bindingID { roots[.argument(bindingID: binding)] = type }
                roots[.register(name: "x\(index)", version: 0)] = type
            }
            // A registration is a declaration about the exact SSA object, not a
            // mutable register or a remembered memory load. Both uses must be
            // dominated by that object's unique definition, in either store order.
            var changed = true
            while changed {
                changed = false
                for store in stores where store.width == 8 {
                    guard let identity = identity(store.source, at: store.index),
                          let pointer = pointer(store.address, at: store.index),
                          let field = Self.field(at: pointer, catalog: catalog),
                          field.functionPointerSignatureV1 == nil,
                          let name = Self.objectPointeeName(field, catalog: catalog) else { continue }
                    if registrations[identity, default: []].insert(name).inserted {
                        changed = true
                        objects.clear()
                    }
                    let previous = registrationDependencies[identity, default: []]
                    registrationDependencies[identity, default: []].formUnion(pointer.dependencies)
                    if previous != registrationDependencies[identity] { changed = true }
                }
            }
            // A later conflicting registration invalidates every fact derived
            // through it, even if the fact was discovered in an earlier pass.
            ambiguousIdentities = Set(registrations.compactMap { value, names in
                names.count != 1 || roots[value].map({ !names.contains($0) }) == true ? value : nil
            })
            objects.clear()
            changed = true
            while changed {
                changed = false
                for (value, dependencies) in registrationDependencies
                    where !dependencies.isDisjoint(with: ambiguousIdentities) {
                    if ambiguousIdentities.insert(value).inserted {
                        changed = true
                        objects.clear()
                    }
                }
            }
        }

        func definition(_ value: MacIRValue, at use: Int) -> Int? { data.definition(value, at: use) }
        func constant(_ value: MacIRValue, at use: Int) -> Int64? { data.constant(value, at: use) }

        func identity(_ value: MacIRValue, at use: Int) -> MacIRValue? {
            identityResult(value, at: use).value
        }

        // Only empty-path queries use the memo. A recursive lookup could otherwise
        // reuse a proof that traverses an ancestor forbidden by this query's path.
        func identityResult(_ value: MacIRValue, at use: Int) -> IdentityResult {
            let key = ValueUse(value: value, index: use)
            if let cached = objects.identities[key] { return cached }
            var seen: Set<MacIRValue> = []
            var cycleRefused = false
            let value = uncachedIdentity(value, at: use, seen: &seen, cycleRefused: &cycleRefused)
            let result = IdentityResult(value: value, cycleRefused: cycleRefused)
            if !cycleRefused { objects.identities[key] = result }
            return result
        }

        func uncachedIdentity(_ value: MacIRValue, at use: Int, seen: inout Set<MacIRValue>,
                              cycleRefused: inout Bool) -> MacIRValue? {
            guard seen.insert(value).inserted else { cycleRefused = true; return nil }
            defer { seen.remove(value) }
            guard !phiValues.contains(value) else { return nil }
            if roots[value] != nil, definitions[value] == nil { return value }
            guard let index = definition(value, at: use) else { return nil }
            if case let .assign(_, source) = function.instructions[index].operation {
                return uncachedIdentity(source, at: index, seen: &seen, cycleRefused: &cycleRefused)
            }
            switch value {
            case .register, .temporary: return value
            default: return nil
            }
        }

        static func arithmetic(_ op: String, _ lhs: Int64, _ rhs: Int64) -> Int64? {
            guard op == "+" || op == "-" else { return nil }
            let result = op == "+" ? lhs.addingReportingOverflow(rhs) : lhs.subtractingReportingOverflow(rhs)
            return result.overflow ? nil : result.partialValue
        }

        func pointer(_ value: MacIRValue, at use: Int) -> Pointer? {
            let key = ValueUse(value: value, index: use)
            if let cached = objects.pointers[key] { return cached.value }
            var seen: Set<MacIRValue> = []
            var cycleRefused = false
            let result = uncachedPointer(value, at: use, seen: &seen, cycleRefused: &cycleRefused)
            if !cycleRefused { objects.pointers[key] = ObjectMemo.PointerResult(value: result) }
            return result
        }

        func uncachedPointer(_ value: MacIRValue, at use: Int, seen: inout Set<MacIRValue>,
                             cycleRefused: inout Bool) -> Pointer? {
            guard seen.insert(value).inserted else { cycleRefused = true; return nil }
            defer { seen.remove(value) }
            guard !phiValues.contains(value), !cfg.hasUnresolvedTargets,
                  let block = blocks[use], cfg.domTree[block] != nil else { return nil }
            let identity = identityResult(value, at: use)
            if identity.cycleRefused { cycleRefused = true }
            if let id = identity.value {
                guard !ambiguousIdentities.contains(id) else { return nil }
                if let names = registrations[id] {
                    guard names.count == 1, let name = names.first,
                          roots[id].map({ $0 == name }) ?? true else { return nil }
                    return Pointer(type: name, offset: 0, dependencies: [id])
                }
            }
            if let root = roots[value], definitions[value] == nil {
                return Pointer(type: root, offset: 0, dependencies: [value])
            }
            if case let .binaryExpression(op, left, right) = value,
               let base = uncachedPointer(left, at: use, seen: &seen, cycleRefused: &cycleRefused), let offset = constant(right, at: use),
               let sum = Self.arithmetic(op, base.offset, offset) { return Pointer(type: base.type, offset: sum, dependencies: base.dependencies) }
            guard let index = definition(value, at: use) else { return nil }
            switch function.instructions[index].operation {
            case let .assign(_, source): return uncachedPointer(source, at: index, seen: &seen, cycleRefused: &cycleRefused)
            case let .binary(_, op, left, right):
                guard let base = uncachedPointer(left, at: index, seen: &seen, cycleRefused: &cycleRefused), let offset = constant(right, at: index),
                      let sum = Self.arithmetic(op, base.offset, offset) else { return nil }
                return Pointer(type: base.type, offset: sum, dependencies: base.dependencies)
            case let .load(_, address) where function.instructions[index].memoryAccess?.byteWidth == 8:
                guard let base = uncachedPointer(address, at: index, seen: &seen, cycleRefused: &cycleRefused),
                      let field = Self.field(at: base, catalog: catalog),
                      let name = Self.objectPointeeName(field, catalog: catalog) else { return nil }
                return Pointer(type: name, offset: 0, dependencies: base.dependencies)
            default: return nil
            }
        }

        func collect() -> [UInt64: [StoreEvidence]] {
            var result: [UInt64: [StoreEvidence]] = [:]
            func record(_ target: UInt64, index: Int, type: String?, reason: String?,
                        signature: FunctionPointerSignatureV1? = nil) {
                result[target, default: []].append(StoreEvidence(functionStart: function.startAddress,
                    address: function.instructions[index].source.address, returnType: type, reason: reason,
                    slotSignature: signature))
            }
            for (position, store) in stores.enumerated() {
                let found = data.foundStores[position]
                guard !found.isEmpty else { continue }
                let exact = data.exactStores[position]
                let field = pointer(store.address, at: store.index).flatMap { Self.field(at: $0, catalog: catalog) }
                let type = field?.declaratorSemanticsV1 == .functionPointerCarrier
                    ? field?.functionPointerSignatureV1?.returnType.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                for target in found {
                    let admitted = store.width == 8 && exact == target && type?.isEmpty == false
                    record(target, index: store.index, type: admitted ? type : nil,
                           reason: admitted ? nil : "untyped, unresolved, or non-pointer-width store",
                           signature: admitted ? field?.functionPointerSignatureV1 : nil)
                }
            }
            // Preserve the original two phases: stores, then instruction escapes.
            for (target, records) in data.escapeRecords { result[target, default: []] += records }
            return result
        }

        static func destinations(_ operation: MacIROperation) -> [MacIRValue] {
            switch operation {
            case let .assign(value, _), let .binary(value, _, _, _), let .load(value, _),
                 let .stackSlotRead(value, _, _), let .select(value, _, _, _, _, _),
                 let .compareToBool(value, _, _, _): return [value]
            case let .loadWriteback(value, base, _, _, _): return [value, base]
            case let .storeWriteback(_, base, _, _, _): return [base]
            case let .stackSlotPairRead(first, _, _, second, _, _): return [first, second]
            case let .call(_, value), let .intrinsic(value, _, _), let .unknown(value, _, _, _): return value.map { [$0] } ?? []
            default: return []
            }
        }

        static func inputs(_ operation: MacIROperation) -> [MacIRValue] {
            switch operation {
            case let .assign(_, source): return [source]
            case let .binary(_, _, left, right), let .compareToBool(_, _, left, right): return [left, right]
            case let .load(_, address): return [address]
            case let .store(source, address): return [source, address]
            case let .loadWriteback(_, _, base, _, _): return [base]
            case let .storeWriteback(source, _, base, _, _): return [source, base]
            case let .stackSlotRead(_, slot, value): return [slot, value]
            case let .stackSlotPairRead(_, slot, value, _, otherSlot, otherValue): return [slot, value, otherSlot, otherValue]
            case let .call(frame, _): return frame.bindingValues
            case let .conditionalBranch(_, left, right, target): return [left, right, target]
            case let .select(_, _, left, right, yes, no): return [left, right, yes, no]
            case let .returnValue(value): return value.map { [$0] } ?? []
            case let .intrinsic(_, _, arguments): return arguments
            case let .switchDispatch(index, cases, target): return [index] + cases.map(\.target) + (target.map { [$0] } ?? [])
            case let .unknown(_, inputs, _, _): return inputs.mayRead.map(\.value)
            }
        }

        static func objectPointeeName(_ field: FieldDef, catalog: [String: TypeDefinition]) -> String? {
            guard field.functionPointerSignatureV1 == nil,
                  field.declaratorSemanticsV1 == nil || field.declaratorSemanticsV1 == .ordinary else { return nil }
            return pointeeName(field.type, catalog: catalog)
        }

        static func pointeeName(_ spelling: String, catalog: [String: TypeDefinition], seen: Set<String> = []) -> String? {
            let spelling = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seen.contains(spelling) else { return nil }
            if let alias = catalog[spelling], alias.kind == .typedef, alias.inferenceProvenance == nil,
               alias.fields.count == 1, let field = alias.fields.first {
                return pointeeName(field.type, catalog: catalog, seen: seen.union([spelling]))
            }
            guard spelling.hasSuffix("*") else { return nil }
            let name = aggregateName(String(spelling.dropLast()))
            guard let name, let type = catalog[name], type.kind == .struct, type.inferenceProvenance == nil else { return nil }
            return name
        }

        static func aggregateName(_ spelling: String) -> String? {
            var words = spelling.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                .filter { $0 != "const" && $0 != "volatile" }
            if words.first == "struct" { words.removeFirst() }
            guard words.count == 1, let name = words.first, PseudocodePrinter.isCIdentifier(name) else { return nil }
            return name
        }

        static func field(at pointer: Pointer, catalog: [String: TypeDefinition], seen: Set<String> = []) -> FieldDef? {
            guard pointer.offset >= 0, !seen.contains(pointer.type), let type = catalog[pointer.type],
                  type.kind == .struct, type.inferenceProvenance == nil,
                  let offset = Int(exactly: pointer.offset) else { return nil }
            let members = type.memberLayout(in: catalog)
            // Only the declaration prefix determines a field offset. A trailing
            // inline union does not invalidate the preceding callback prefix.
            for (index, declared) in type.fields.enumerated() {
                guard type.fields[...index].allSatisfy({ field in
                    field.byteOffset == nil && field.layoutSource == nil && field.inlineFields.isEmpty &&
                    field.bitWidth == nil && field.layoutIsUnknown != true &&
                    field.minimumAlignmentType.map({ exactValueLayout($0, catalog: catalog) }) != false
                }) else { return nil }
                let matches = members.filter { $0.field.name == declared.name }
                guard matches.count == 1, let member = matches.first,
                      type.fields.filter({ $0.name == declared.name }).count == 1 else { return nil }
                if member.offset == offset, declared.declaratorSemanticsV1 == .functionPointerCarrier || objectPointeeName(declared, catalog: catalog) != nil {
                    return declared
                }
                if let name = aggregateName(declared.type), let child = catalog[name], child.kind == .struct,
                   let size = TypeDefinition.size(ofType: declared.type, in: catalog),
                   offset >= member.offset, offset - member.offset < size {
                    // A nonzero child offset depends on the complete child's
                    // alignment, including its trailing members. Offset-zero pub
                    // needs only the declaration prefix of the selected callback.
                    guard member.offset == 0 || exactValueLayout(declared.type, catalog: catalog) else { return nil }
                    return field(at: Pointer(type: name, offset: Int64(offset - member.offset)),
                                 catalog: catalog, seen: seen.union([pointer.type]))
                }
                if member.offset > offset { return nil }
                guard Self.exactValueLayout(declared.type, catalog: catalog) else { return nil }
            }
            return nil
        }

        static func exactValueLayout(_ spelling: String, catalog: [String: TypeDefinition],
                                     seen: Set<String> = []) -> Bool {
            let text = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("*") { return true }
            if let bracket = text.firstIndex(of: "[") {
                return exactValueLayout(String(text[..<bracket]), catalog: catalog, seen: seen)
                    && TypeDefinition.size(ofType: text, in: catalog) != nil
            }
            guard let name = aggregateName(text), let definition = catalog[name] else {
                return TypeDefinition.size(ofType: text, in: [:]) != nil
            }
            guard !seen.contains(name), definition.inferenceProvenance == nil else { return false }
            // Enum fields encode enumerator values, not member type spellings.
            // Ask the declaration-aware layout engine to validate their range
            // and completeness instead of interpreting values such as "0" as types.
            if definition.kind == .enum {
                guard TypeDefinition.size(ofType: text, in: catalog) != nil,
                      TypeDefinition.alignment(ofType: text, in: catalog) != nil else { return false }
            }
            return definition.fields.allSatisfy { field in
                field.byteOffset == nil && field.layoutSource == nil && field.inlineFields.isEmpty &&
                    field.bitWidth == nil && field.layoutIsUnknown != true &&
                    field.minimumAlignmentType.map({
                        exactValueLayout($0, catalog: catalog, seen: seen.union([name]))
                    }) != false &&
                    (definition.kind == .enum ||
                        exactValueLayout(field.type, catalog: catalog, seen: seen.union([name])))
            }
        }
    }
}

// MARK: - Narrow compiler-generated closed-world caller evidence

extension MacIRCallerReturnEvidence {
    struct ClosedWorldContract: Codable, Sendable {
        let returnType: String
        let evidence: String
    }
    struct ClosedWorldCondition: Codable, Sendable {
        let condition: Int
        let satisfied: Bool
        let detail: String
    }
    struct ClosedWorldRefusal: Codable, Sendable {
        let reason: String
        var functionAddress: UInt64? = nil
        var tableAddress: UInt64? = nil
        var dispatchAddress: UInt64? = nil
        /// Diagnostic provenance only; never an input to the closure proof.
        var instructionAddress: UInt64? = nil
        var detail: String? = nil
    }
    struct ClosedWorldTable: Codable, Sendable {
        let address: UInt64
        let byteCount: Int
        let stride: Int
        let dispatchAddress: UInt64
        let functionAddress: UInt64
        let guardAddress: UInt64
        let targets: [UInt64]
    }
    struct ClosedWorldReport: Codable, Sendable {
        var contracts: [UInt64: ClosedWorldContract] = [:]
        var refusals: [ClosedWorldRefusal] = []
        var census: [String: Int] = [:]
        var evidence: [UInt64: [ClosedWorldCondition]] = [:]
        var tables: [ClosedWorldTable] = []
        var imageGuards: [String: Bool] = [:]
        var exported: Set<UInt64> = []
        var entry: UInt64? = nil
        var addressTaken: Set<UInt64>? = nil
        var tableTargets: Set<UInt64> = []
    }

    /// Closed-world discard is diagnostic only, not return-type authority.
    /// This does not change `collect`, prove slot escape closure, or infer a parameter list.
    /// No externally supplied Boolean can mark an image complete; inventories derive from its bytes.
    static func collectClosedWorld(analysis: ImageAnalysis, functions: [MacIRFunction],
                                   effectiveSignatures: [UInt64: FunctionSignatureOverride] = [:],
                                   includeImageFacts: Bool = false) -> ClosedWorldReport {
        var result = ClosedWorldReport()
        let guardNames = ["code_decode_incomplete", "code_ownership_work_cap", "code_section_inventory_unavailable", "code_section_unreadable_or_capped", "decoded_code_mismatch_unknown_or_unowned", "function_or_inline_data_declarations_incomplete", "function_span_ambiguous_or_outside_declared_code", "image_or_function_inventory_unavailable_or_capped", "initializer_or_terminator_inventory_unsupported", "inline_data_leaves_code_section", "inline_data_overlap", "nonzero_unsectioned_executable_bytes", "not_supported_slid_dylib_or_pie", "rows_outside_complete_code_data_partition", "selected_image_parse_failed", "symbol_or_export_inventory_incomplete", "unaccounted_code_tail_or_mapping_gap", "whole_image_instruction_cap", "declared_fixup_inventory_complete"]
        result.imageGuards = Dictionary(uniqueKeysWithValues: guardNames.map { ($0, false) })
        let summaries = analysis.functions.sorted { $0.startAddress < $1.startAddress }
        let starts = Set(summaries.map(\.startAddress))
        result.census["functions"] = summaries.count
        func failAll(_ reason: String, condition: Int,
                     instructionAddress: UInt64? = nil, detail: String? = nil) -> ClosedWorldReport {
            var failed = result
            failed.imageGuards[reason] = false
            failed.refusals.append(.init(reason: reason, instructionAddress: instructionAddress, detail: detail))
            failed.census["condition_\(condition)_refused"] = summaries.count
            for start in starts {
                failed.evidence[start] = (1...6).map {
                    .init(condition: $0, satisfied: false, detail: $0 == condition ? reason : "not established: earlier image prerequisite refused")
                }
            }
            return failed
        }
        guard !Task.isCancelled, !analysis.imageBytes.isEmpty, analysis.imageBytes.count <= 64 * 1024 * 1024,
              !summaries.isEmpty, summaries.count <= 4096, starts.count == summaries.count else {
            return failAll("image_or_function_inventory_unavailable_or_capped", condition: 4)
        }
        result.imageGuards["image_or_function_inventory_unavailable_or_capped"] = true
        let parsed: (file: MachOFile, coverage: MachOFixupCoverage)
        do {
            parsed = try MachOParser().parseWithFixupCoverage(analysis.imageBytes,
                options: MachOParseOptions(recoverStringLiterals: false, recoverObjectiveCMetadata: false,
                                           recoverSwiftMetadata: false, parseCodeSignature: false))
        } catch { return failAll("selected_image_parse_failed", condition: 2) }
        result.imageGuards["selected_image_parse_failed"] = true
        let file = parsed.file, coverage = parsed.coverage
        result.exported = Set(file.exports.compactMap(\.address))
            .union(file.symbols.filter(\.isExternal).compactMap(\.address))
        result.entry = file.entryPointAddress
        result.imageGuards["export_recovery_complete"] = file.exportRecoveryComplete
        if includeImageFacts {
            let index = FunctionAddressTakenIndex(image: file, bytes: analysis.imageBytes, functions: summaries)
            result.addressTaken = index.isComplete ? index.addresses : starts
            result.imageGuards["address_taken_inventory_complete"] = index.isComplete
        }
        guard coverage.symbolInventoryIsComplete, coverage.exportInventoryIsComplete else {
            return failAll("symbol_or_export_inventory_incomplete", condition: 1)
        }
        result.imageGuards["symbol_or_export_inventory_incomplete"] = true
        guard coverage.isComplete else {
            let reasons = coverage.refusalReasons.union(coverage.fixupRefusalReasons).map(\.rawValue).sorted().joined(separator: ",")
            return failAll("declared_fixup_inventory_incomplete:\(reasons)", condition: 2)
        }
        result.imageGuards["declared_fixup_inventory_complete"] = true
        guard file.header.cpuType == MachOConstants.cpuTypeARM64, file.header.cpuSubtype & 0x00ffffff == 0,
              file.header.fileType == 6 || (file.header.fileType == 2 && file.header.flags & 0x200000 != 0) else {
            return failAll("not_supported_slid_dylib_or_pie", condition: 2)
        }
        result.imageGuards["not_supported_slid_dylib_or_pie"] = true
        guard coverage.functionStartsInventoryIsComplete, coverage.dataInCodeInventoryIsComplete,
              Set(file.functionStarts.map(\.address)).isSubset(of: starts) else {
            return failAll("function_or_inline_data_declarations_incomplete", condition: 4)
        }
        result.imageGuards["function_or_inline_data_declarations_incomplete"] = true
        guard !file.sections.contains(where: { $0.size > 0 && [UInt32(9), 10, 0x15, 0x16].contains($0.flags & 0xff) }) else {
            return failAll("initializer_or_terminator_inventory_unsupported", condition: 1)
        }
        result.imageGuards["initializer_or_terminator_inventory_unsupported"] = true
        let bytes = analysis.imageBytes
        func read(_ address: UInt64, _ count: Int) -> Data? {
            guard count > 0, let width = UInt64(exactly: count) else { return nil }
            let owners = file.sections.filter { section in
                !section.isZeroFill && address >= section.address && width <= section.size
                    && address - section.address <= section.size - width
            }
            guard owners.count == 1, let section = owners.first else { return nil }
            let offset = UInt64(section.fileOffset) + (address - section.address)
            guard offset <= UInt64(bytes.count), width <= UInt64(bytes.count) - offset else { return nil }
            return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        // Account executable-segment bytes outside sections too. The Mach-O
        // header/load commands are structural data; otherwise only literal zero
        // gaps are accepted. Nonzero unsectioned padding/code is not guessed.
        for segment in file.segments where segment.initialProtection & 4 != 0 && segment.fileSize > 0 {
            let segmentStart = Int(segment.fileOffset), segmentEnd = Int(segment.fileOffset + segment.fileSize)
            var spans = file.sections.filter { $0.segmentName == segment.name && !$0.isZeroFill && $0.size > 0 }
                .map { Int($0.fileOffset)..<(Int($0.fileOffset) + Int($0.size)) }
            if segmentStart == 0 { spans.append(0..<(32 + Int(file.header.loadCommandsSize))) }
            spans.sort { $0.lowerBound < $1.lowerBound }
            var cursor = segmentStart
            for span in spans {
                guard span.lowerBound >= cursor, span.upperBound <= segmentEnd,
                      bytes[cursor..<span.lowerBound].allSatisfy({ $0 == 0 }) else {
                    return failAll("nonzero_unsectioned_executable_bytes", condition: 4)
                }
                cursor = span.upperBound
            }
            guard bytes[cursor..<segmentEnd].allSatisfy({ $0 == 0 }) else {
                return failAll("nonzero_unsectioned_executable_bytes", condition: 4)
            }
        }
        result.imageGuards["nonzero_unsectioned_executable_bytes"] = true
        let codeSections = file.sections.filter { $0.isExecutableInstructions && $0.size > 0 }
        guard !codeSections.isEmpty, codeSections.count <= 256 else { return failAll("code_section_inventory_unavailable", condition: 4) }
        result.imageGuards["code_section_inventory_unavailable"] = true
        let declaredWords = codeSections.reduce(UInt64(0)) { $0 + $1.size / 4 }
        // Upper-bound search uses at most floor(log2(count)) + 1 start
        // comparisons, then one exclusive-end comparison. Each raw word needs
        // one lookup and can cause at most one later direct-caller lookup.
        var ownershipComparisons = 1, remainingOwners = summaries.count
        while remainingOwners > 0 { ownershipComparisons += 1; remainingOwners /= 2 }
        guard declaredWords <= 1_000_000,
              declaredWords * UInt64(ownershipComparisons) * 2 <= 64_000_000 else {
            return failAll("code_ownership_work_cap", condition: 4)
        }
        result.imageGuards["code_ownership_work_cap"] = true
        for (index, summary) in summaries.enumerated() {
            guard summary.startAddress < summary.endAddress,
                  index == 0 || summaries[index - 1].endAddress <= summary.startAddress,
                  codeSections.filter({ summary.startAddress >= $0.address && summary.endAddress <= $0.address + $0.size }).count == 1 else {
                return failAll("function_span_ambiguous_or_outside_declared_code", condition: 4)
            }
        }
        result.imageGuards["function_span_ambiguous_or_outside_declared_code"] = true
        func codeOwnerIndex(_ address: UInt64) -> Int? {
            var lower = 0, upper = summaries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if summaries[middle].startAddress <= address { lower = middle + 1 }
                else { upper = middle }
            }
            // Validated nonoverlapping spans make the predecessor the only
            // possible owner. Gaps and the final exclusive end stay unowned.
            guard lower > 0, address < summaries[lower - 1].endAddress else { return nil }
            return lower - 1
        }
        let declaredData = file.dataInCodeEntries.sorted { $0.address < $1.address }
        let storedRows = Dictionary(grouping: analysis.instructions, by: \.address)
        var decoded: [DecodedInstruction] = []
        var decodedByOwner = Array(repeating: [DecodedInstruction](), count: summaries.count)
        for section in codeSections {
            guard !section.isZeroFill, section.address % 4 == 0, section.size <= 4 * 1_000_000 else {
                return failAll("code_section_unreadable_or_capped", condition: 4)
            }
            var cursor = section.address
            let end = section.address + section.size
            let data = declaredData.filter { $0.address >= section.address && $0.address < end }
            for exclusion in data + [MachODataInCodeEntry(fileOffset: 0, length: 0, kind: 0, address: end)] {
                guard exclusion.address >= cursor else { return failAll("inline_data_overlap", condition: 4) }
                let count = Int(exclusion.address - cursor)
                if count > 0 {
                    guard count % 4 == 0, cursor % 4 == 0, let raw = read(cursor, count) else {
                        return failAll("unaccounted_code_tail_or_mapping_gap", condition: 4)
                    }
                    let words = ARM64Decoder().decode(raw, baseAddress: cursor, maxInstructionCount: count / 4)
                    guard words.count == count / 4 else { return failAll("code_decode_incomplete", condition: 4) }
                    for word in words {
                        guard !["unknown", "unavailable", "udf"].contains(word.mnemonic), !word.mnemonic.hasPrefix(".") else {
                            return failAll("decoded_code_mismatch_unknown_or_unowned", condition: 4,
                                instructionAddress: word.address,
                                detail: "unknown_decoded_word; bytes=\(word.byteText); mnemonic=\(word.mnemonic); operands=\(word.operands)")
                        }
                        guard let rows = storedRows[word.address] else {
                            return failAll("decoded_code_mismatch_unknown_or_unowned", condition: 4,
                                instructionAddress: word.address, detail: "missing_stored_row")
                        }
                        guard rows.count == 1 else {
                            return failAll("decoded_code_mismatch_unknown_or_unowned", condition: 4,
                                instructionAddress: word.address, detail: "duplicate_stored_rows; count=\(rows.count)")
                        }
                        guard rows[0].bytes.lowercased() == word.byteText.lowercased() else {
                            return failAll("decoded_code_mismatch_unknown_or_unowned", condition: 4,
                                instructionAddress: word.address,
                                detail: "stored_bytes_mismatch; expected=\(word.byteText); actual=\(rows[0].bytes)")
                        }
                        guard rows[0].mnemonic.lowercased() == word.mnemonic.lowercased() else {
                            return failAll("decoded_code_mismatch_unknown_or_unowned", condition: 4,
                                instructionAddress: word.address,
                                detail: "stored_mnemonic_mismatch; expected=\(word.mnemonic); actual=\(rows[0].mnemonic)")
                        }
                        guard rows[0].operands.lowercased() == word.operands.lowercased() else {
                            return failAll("decoded_code_mismatch_unknown_or_unowned", condition: 4,
                                instructionAddress: word.address,
                                detail: "stored_operands_mismatch; expected=\(word.operands); actual=\(rows[0].operands)")
                        }
                        guard let owner = codeOwnerIndex(word.address) else {
                            return failAll("decoded_code_mismatch_unknown_or_unowned", condition: 4,
                                instructionAddress: word.address, detail: "unowned_decoded_word")
                        }
                        decodedByOwner[owner].append(word)
                    }
                    decoded += words
                }
                cursor = exclusion.address + UInt64(exclusion.length)
                guard cursor <= end else { return failAll("inline_data_leaves_code_section", condition: 4) }
            }
        }
        guard decoded.count <= 1_000_000 else { return failAll("whole_image_instruction_cap", condition: 4) }
        decoded.sort { $0.address < $1.address }
        // These exact validated partitions replace later whole-image scans per
        // function. Explicit sorting preserves their former address order even
        // when section declarations arrive in a different order.
        for owner in decodedByOwner.indices { decodedByOwner[owner].sort { $0.address < $1.address } }
        result.imageGuards["code_decode_incomplete"] = true
        result.imageGuards["code_section_unreadable_or_capped"] = true
        result.imageGuards["decoded_code_mismatch_unknown_or_unowned"] = true
        result.imageGuards["inline_data_leaves_code_section"] = true
        result.imageGuards["inline_data_overlap"] = true
        result.imageGuards["unaccounted_code_tail_or_mapping_gap"] = true
        result.imageGuards["whole_image_instruction_cap"] = true
        let decodedByAddress = Dictionary(uniqueKeysWithValues: decoded.map { ($0.address, $0) })
        let decodedAddresses = Set(decodedByAddress.keys)
        guard starts.isSubset(of: decodedAddresses), analysis.instructions.allSatisfy({ row in
            decodedAddresses.contains(row.address) || declaredData.contains { row.address >= $0.address && row.address < $0.address + UInt64($0.length) }
        }) else { return failAll("rows_outside_complete_code_data_partition", condition: 4) }
        // No unknown padding is silently omitted: all declared code bytes above
        // were decoded or belong to a fully validated data-in-code declaration.
        result.imageGuards["rows_outside_complete_code_data_partition"] = true
        result.census["decoded_code_words"] = decoded.count
        var entries = starts.union(file.exports.compactMap(\.address))
            .union(file.symbols.compactMap(\.address))
        if let entry = file.entryPointAddress { entries.insert(entry) }
        let fixups = file.dyldChainedFixups?.fixups ?? []
        let fixupsByAddress = Dictionary(uniqueKeysWithValues: fixups.map { ($0.address, $0) })
        let fixupTargets = Set(fixups.compactMap(\.rebaseTargetAddress))
        var tableTargets: Set<UInt64> = []
        var relativeConstantTargets: Set<UInt64> = []
        var tableBytes: [Range<UInt64>] = []
        var tableLoads: Set<UInt64> = [], tableAdds: [UInt64: [UInt64]] = [:]
        var tableFailure = false
        func refuseTable(_ reason: String, table: UInt64? = nil, branch: UInt64? = nil, function: UInt64? = nil) {
            tableFailure = true
            result.refusals.append(.init(reason: reason, functionAddress: function, tableAddress: table, dispatchAddress: branch))
        }
        for (owner, summary) in summaries.enumerated() {
            let words = decodedByOwner[owner]
            let rows = words.map(InstructionRow.init(decoded:))
            let branches = rows.enumerated().filter { $0.element.mnemonic == "br" }
            let otherIndirect = words.filter { $0.flow == .indirectJump && $0.mnemonic != "br" }
            for branch in otherIndirect { refuseTable("unsupported_indirect_dispatch", branch: branch.address, function: summary.startAddress) }
            guard !branches.isEmpty else { continue }
            result.census["relative_table_sites_found", default: 0] += branches.count
            var proofs: [JumpTableSelectorProof] = []
            var badProof = false
            for (index, branch) in branches {
                guard let proof = JumpTableResolver.proveSelector(rows: rows, dispatchIndex: index),
                      case let .boundsBranch(defaultTarget) = proof.guardKind, let target = defaultTarget,
                      decodedAddresses.contains(target), target >= summary.startAddress, target < summary.endAddress else {
                    refuseTable("unbounded_dispatch_table_address_unavailable", branch: branch.address, function: summary.startAddress)
                    badProof = true; continue
                }
                proofs.append(proof)
            }
            guard !badProof else { continue }
            var trace: [(UInt64, Int, Bool)] = []
            let recovered = JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
                let value = read(address, count)
                trace.append((address, count, value?.count == count))
                return value
            }, codeRange: .init(lowerBound: summary.startAddress, upperBound: summary.endAddress))
            let expected = proofs.reduce(0) { $0 + $1.caseCount }
            guard Set(recovered.keys) == Set(branches.map { $0.element.address }), trace.count == expected,
                  trace.allSatisfy({ $0.2 }) else {
                refuseTable("incomplete_or_ambiguous_table_read_trace", table: trace.first?.0, function: summary.startAddress)
                continue
            }
            var offset = 0
            let lastDispatch = branches.map { $0.element.address }.max()!
            for (position, pair) in branches.enumerated() {
                let proof = proofs[position], branch = pair.element
                let reads = Array(trace[offset..<(offset + proof.caseCount)]); offset += proof.caseCount
                let base = reads[0].0, stride = reads[0].1
                guard [1, 2, 4].contains(stride), let targets = recovered[branch.address], targets.count == proof.caseCount,
                      reads.enumerated().allSatisfy({ $0.element.1 == stride && base <= UInt64.max - UInt64($0.offset * stride)
                          && $0.element.0 == base + UInt64($0.offset * stride) }),
                      targets.allSatisfy({ $0 > summary.startAddress && $0 < summary.endAddress
                          && $0 > lastDispatch && decodedAddresses.contains($0) && !entries.contains($0) }) else {
                    refuseTable("relative_table_not_strict_internal_or_guard_safe", table: base, branch: branch.address, function: summary.startAddress)
                    continue
                }
                let count = proof.caseCount * stride
                guard base <= UInt64.max - UInt64(count), read(base, count)?.count == count else {
                    refuseTable("table_extent_unmapped", table: base, branch: branch.address, function: summary.startAddress); continue
                }
                let span = base..<(base + UInt64(count))
                guard !tableBytes.contains(where: { $0.overlaps(span) }) else {
                    refuseTable("table_has_multiple_branch_owners", table: base, branch: branch.address, function: summary.startAddress); continue
                }
                let setup = rows.filter { $0.address > proof.definitionAddress && $0.address < branch.address }
                let loads = setup.filter { $0.mnemonic.hasPrefix("ldr") && $0.operands.contains("[") }
                guard loads.count == 1 else {
                    refuseTable("table_load_attribution_ambiguous", table: base, branch: branch.address, function: summary.startAddress); continue
                }
                let branchOperands = MacIRBuilder.splitOperands(branch.operands)
                guard let add = setup.last(where: { $0.mnemonic == "add" }),
                      MacIRBuilder.splitOperands(add.operands).first == branchOperands.first else {
                    refuseTable("table_add_attribution_ambiguous", table: base, branch: branch.address, function: summary.startAddress); continue
                }
                tableLoads.insert(loads[0].address); tableAdds[add.address] = targets
                tableBytes.append(span); tableTargets.formUnion(targets)
                result.tables.append(.init(address: base, byteCount: count, stride: stride,
                    dispatchAddress: branch.address, functionAddress: summary.startAddress,
                    guardAddress: proof.definitionAddress, targets: targets))
            }
        }
        for entry in declaredData {
            let owners = result.tables.filter { $0.address == entry.address && $0.byteCount == Int(entry.length)
                && ((entry.kind == 2 && $0.stride == 1) || (entry.kind == 3 && $0.stride == 2) || (entry.kind == 4 && $0.stride == 4)) }
            // Generic inline data is not silently assumed to contain no relative pointers.
            if owners.count != 1 { refuseTable("declared_inline_data_not_fully_owned_relative_table", table: entry.address) }
        }
        for table in result.tables {
            let overlaps = declaredData.filter { entry in
                (entry.address..<(entry.address + UInt64(entry.length))).overlaps(table.address..<(table.address + UInt64(table.byteCount)))
            }
            if !overlaps.isEmpty && !(overlaps.count == 1 && overlaps[0].address == table.address && Int(overlaps[0].length) == table.byteCount) {
                refuseTable("table_declared_extent_mismatch", table: table.address, branch: table.dispatchAddress, function: table.functionAddress)
            }
        }
        // Explicitly named relative-metadata families need their own complete
        // decoder. Existing __unwind_info is the lead's explicit exception.
        for section in file.sections where section.size > 0 && !section.isExecutableInstructions && !section.isZeroFill {
            if section.sectionName == "__unwind_info" { continue }
            if ["__eh_frame", "__gcc_except_tab"].contains(section.sectionName)
                || section.sectionName.hasPrefix("__swift5_")
                || section.sectionName.hasPrefix("__objc_") && !section.isCStringLiterals {
                refuseTable("unsupported_relative_metadata_section", table: section.address)
            }
            // Conservatively inspect every 32-bit self-relative entry in regular
            // constant data, except bytes already attributed to a proven table.
            // This does not claim arbitrary bytes are a table or that this scan
            // inventories other encodings. Unreadable/unaligned tails refuse.
            if section.sectionName == "__const" {
                guard section.size <= 16 * 1024 * 1024, let raw = read(section.address, Int(section.size)), raw.count % 4 == 0 else {
                    refuseTable("relative_constant_inventory_unreadable", table: section.address); continue
                }
                for offset in Swift.stride(from: 0, to: raw.count, by: 4) {
                    let address = section.address + UInt64(offset)
                    if tableBytes.contains(where: { $0.contains(address) }) { continue }
                    let word = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(raw[offset + $1]) << (8 * $1)) }
                    let delta = Int64(Int32(bitPattern: word))
                    let target = UInt64(bitPattern: Int64(bitPattern: address) &+ delta)
                    let baseTarget = UInt64(bitPattern: Int64(bitPattern: section.address) &+ delta)
                    if codeSections.contains(where: { target >= $0.address && target < $0.address + $0.size
                        || baseTarget >= $0.address && baseTarget < $0.address + $0.size }) {
                        if starts.contains(target) { relativeConstantTargets.insert(target) }
                        if starts.contains(baseTarget) { relativeConstantTargets.insert(baseTarget) }
                        refuseTable("unattributed_relative_constant_candidate", table: address)
                    }
                }
            }
        }
        result.census["relative_tables_admitted"] = result.tables.count
        result.census["relative_tables_refused"] = result.refusals.count
        // Indirect setup/unknown tables anywhere veto the image, not just their
        // decoded targets. A missing actual table address is never invented.
        let tablesComplete = !tableFailure
        let materialization = closedWorldMaterializations(decoded: decoded, summaries: summaries, decodedByOwner: decodedByOwner,
            tables: result.tables, tableLoads: tableLoads, tableAdds: tableAdds, fixups: fixupsByAddress, read: read)
        for name in guardNames { result.imageGuards[name] = true }
        result.imageGuards["relative_table_inventory_complete"] = tablesComplete
        result.imageGuards["materialization_inventory_complete"] = materialization.complete
        result.tableTargets = tableTargets.union(relativeConstantTargets)
        let exported = result.exported
        let functionIR = Dictionary(grouping: functions, by: \.startAddress)
        var directCallsByTarget: [UInt64: [DecodedInstruction]] = [:]
        for call in decoded where call.flow == .call {
            if let target = call.branchTarget { directCallsByTarget[target, default: []].append(call) }
        }
        let tailTargets = Set(decoded.filter { $0.flow == .jump }.compactMap(\.branchTarget).filter { starts.contains($0) })
        for summary in summaries {
            let target = summary.startAddress
            let calls = directCallsByTarget[target] ?? []
            let privateEntry = !exported.contains(target) && file.entryPointAddress != target && !tableTargets.contains(target)
            let noFixup = !fixupTargets.contains(target)
            let noMaterialization = materialization.complete && !materialization.targets.contains(target)
            var discarded = 0
            for call in calls {
                guard let ownerIndex = codeOwnerIndex(call.address) else { continue }
                let owner = summaries[ownerIndex]
                guard let irs = functionIR[owner.startAddress], irs.count == 1,
                      closedWorldCallIsDiscarded(call: call.address, function: irs[0], raw: decodedByAddress,
                          end: owner.endAddress, tables: result.tables,
                          callerSignature: effectiveSignatures[owner.startAddress]) else { continue }
                discarded += 1
            }
            let callersComplete = !calls.isEmpty && discarded == calls.count && !tailTargets.contains(target)
            let conditions: [ClosedWorldCondition] = [
                .init(condition: 1, satisfied: privateEntry, detail: "non-exported, no global symbol/entry/init/term/jump-table entry"),
                .init(condition: 2, satisfied: true, detail: "slid MH_DYLIB/PIE; declared fixup inventory complete; unrelocated absolute pointers are not a valid loader state"),
                .init(condition: 3, satisfied: noFixup, detail: "no rebase/auth-rebase/bind-addend resolves to entry"),
                .init(condition: 4, satisfied: noMaterialization, detail: materialization.complete ? "all declared code decoded; no ADR/ADRP+ADD/ADRP+LDR/MOVZ-MOVK entry materialization" : "materialization analysis incomplete: \(materialization.reason)"),
                .init(condition: 5, satisfied: tablesComplete, detail: tablesComplete ? "relative tables guard-bounded, wholly decoded, strictly internal, non-entry and single-branch owned" : "image-wide relative inventory refused"),
                .init(condition: 6, satisfied: callersComplete, detail: "\(discarded) of \(calls.count) direct callers prove x0 discarded; no unresolved tail caller")
            ]
            result.evidence[target] = conditions
            for condition in conditions where !condition.satisfied {
                result.census["condition_\(condition.condition)_refused", default: 0] += 1
                result.refusals.append(.init(reason: condition.detail, functionAddress: target))
            }
            guard conditions.allSatisfy(\.satisfied), effectiveSignatures[target]?.returnType == nil else { continue }
            // Even complete caller coverage cannot distinguish a void callee
            // from a value-returning callee whose result every caller discards.
            // Keep the six conditions, but never publish them as type authority.
            result.census["discard_without_return_type_authority", default: 0] += 1
            result.refusals.append(.init(reason: "discard_without_return_type_authority",
                functionAddress: target))
        }
        result.census["void_contracts"] = result.contracts.count
        return result
    }

    private struct ClosedWorldConstant: Hashable {
        let value: UInt64
        /// 0 = immediate, 1 = ADRP page awaiting use, 2 = materialized address.
        let kind: Int
    }
    private static func closedWorldMaterializations(decoded: [DecodedInstruction], summaries: [FunctionSummary],
        decodedByOwner: [[DecodedInstruction]],
        tables: [ClosedWorldTable], tableLoads: Set<UInt64>, tableAdds: [UInt64: [UInt64]],
        fixups: [UInt64: MachOChainedFixup], read: (UInt64, Int) -> Data?)
        -> (complete: Bool, targets: Set<UInt64>, reason: String) {
        let byAddress = Dictionary(uniqueKeysWithValues: decoded.map { ($0.address, $0) })
        let byBranch = Dictionary(uniqueKeysWithValues: tables.map { ($0.dispatchAddress, $0.targets) })
        let starts = Set(summaries.map(\.startAddress))
        var targets: Set<UInt64> = []
        func register(_ text: String) -> Int? { MacIRBuilder.integerRegisterView(text)?.index }
        for (owner, summary) in summaries.enumerated() {
            typealias State = [Set<ClosedWorldConstant>]
            var incoming: [UInt64: State] = [summary.startAddress: Array(repeating: [], count: 31)]
            var pending = [summary.startAddress], iterations = 0
            // Also seed unreachable decoded blocks: condition 4 covers ALL code.
            var processed: Set<UInt64> = []
            let functionWords = decodedByOwner[owner]
            while true {
                if pending.isEmpty {
                    guard let unseen = functionWords.first(where: { !processed.contains($0.address) }) else { break }
                    incoming[unseen.address] = Array(repeating: [], count: 31); pending.append(unseen.address)
                }
                guard let address = pending.popLast(), let row = byAddress[address], var state = incoming[address] else {
                    return (false, targets, "instruction_gap")
                }
                iterations += 1
                guard iterations <= max(1, functionWords.count) * 32, !Task.isCancelled else { return (false, targets, "fixed_point_limit") }
                processed.insert(address)
                let old = state, ops = MacIRBuilder.splitOperands(row.operands.lowercased()), mnemonic = row.mnemonic.lowercased()
                for written in MacIRBuilder.argumentRegisterWrites(mnemonic: mnemonic, operands: ops) {
                    if let index = register(written), index < 31 { state[index] = [] }
                }
                var assigned: Set<ClosedWorldConstant>?
                if ["adr", "adrp"].contains(mnemonic), ops.count == 2 {
                    guard let value = addressValue(ops[1]) else { return (false, targets, "unresolved_pc_relative_address") }
                    assigned = [.init(value: value, kind: mnemonic == "adrp" ? 1 : 2)]
                } else if mnemonic == "mov", ops.count == 2 {
                    if let source = register(ops[1]), source < 31 { assigned = old[source] }
                    else if let immediate = MacIRBuilder.parseImmediate(ops[1]) {
                        let value = ops[0].hasPrefix("w") ? UInt64(UInt32(truncatingIfNeeded: immediate)) : UInt64(bitPattern: immediate)
                        assigned = [.init(value: value, kind: 0)]
                    }
                } else if mnemonic == "movk", ops.count == 2 || ops.count == 3 {
                    guard let destination = ops.first.flatMap(register), destination < 31,
                          let immediate = MacIRBuilder.parseImmediate(ops[1]), (0...65535).contains(immediate), !old[destination].isEmpty else {
                        return (false, targets, "unbounded_movk_sequence")
                    }
                    let shift: Int64
                    if ops.count == 3 {
                        let parts = ops[2].split(separator: " ")
                        guard parts.count == 2, parts[0] == "lsl", let amount = MacIRBuilder.parseImmediate(String(parts[1])),
                              [Int64(0), 16, 32, 48].contains(amount) else { return (false, targets, "unsupported_movk_shift") }
                        shift = amount
                    } else { shift = 0 }
                    assigned = Set(old[destination].map {
                        let value = ($0.value & ~(UInt64(0xffff) << shift)) | (UInt64(immediate) << shift)
                        return .init(value: ops[0].hasPrefix("w") ? value & 0xffffffff : value, kind: $0.kind)
                    })
                } else if let provenTargets = tableAdds[address] {
                    assigned = Set(provenTargets.map { .init(value: $0, kind: 2) })
                } else if mnemonic == "add", ops.count >= 3, let left = register(ops[1]), left < 31, !old[left].isEmpty {
                    if let immediate = MacIRBuilder.parseImmediate(ops[2]), immediate >= 0,
                       ops.count == 3 || (ops.count == 4 && ops[3] == "lsl #12") {
                        let offset = UInt64(immediate) << (ops.count == 4 ? 12 : 0)
                        var values: Set<ClosedWorldConstant> = []
                        for value in old[left] {
                            guard offset <= UInt64.max - value.value else { return (false, targets, "address_add_overflow") }
                            values.insert(.init(value: value.value + offset, kind: value.kind == 0 ? 0 : 2))
                        }
                        assigned = values
                    } else {
                        if old[left].contains(where: { $0.kind > 0 }) { return (false, targets, "unmodeled_address_arithmetic") }
                        assigned = []
                    }
                } else if mnemonic.hasPrefix("ldr"), ops.count >= 2, !tableLoads.contains(address),
                          ops[1].hasPrefix("["), ops[1].hasSuffix("]") {
                    let memory = MacIRBuilder.splitOperands(String(ops[1].dropFirst().dropLast()))
                    if let baseName = memory.first, let base = register(baseName), base < 31,
                       old[base].contains(where: { $0.kind > 0 }) {
                        guard mnemonic == "ldr", ops.count == 2, ops[0].hasPrefix("x"), memory.count <= 2,
                              let delta = memory.count == 1 ? Int64(0) : MacIRBuilder.parseImmediate(memory[1]), delta >= 0 else {
                            return (false, targets, "unsupported_address_load")
                        }
                        var values: Set<ClosedWorldConstant> = []
                        for constant in old[base] {
                            guard UInt64(delta) <= UInt64.max - constant.value else { return (false, targets, "address_load_overflow") }
                            let cell = constant.value + UInt64(delta)
                            if let fixup = fixups[cell] {
                                if let value = fixup.rebaseTargetAddress { values.insert(.init(value: value, kind: 2)) }
                                // The complete certificate admits only strong,
                                // zero-addend external binds, which cannot name F.
                            } else {
                                guard let data = read(cell, 8), data.count == 8 else { return (false, targets, "unreadable_address_load") }
                                let value = (0..<8).reduce(UInt64(0)) { $0 | (UInt64(data[$1]) << (8 * $1)) }
                                values.insert(.init(value: value, kind: 2))
                            }
                        }
                        assigned = values
                    }
                }
                let reads = MacIRBuilder.argumentRegisterReads(mnemonic: mnemonic, operands: ops)
                    .compactMap(register).filter { $0 < 31 }
                if assigned == nil && !tableLoads.contains(address) {
                    // An unsupported instruction cannot silently consume an address or
                    // an immediate that may be part of a MOV-wide construction.
                    let possibleReads = Set(reads + ops.flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
                        .compactMap(register).filter { $0 < 31 })
                    let readsAddress = possibleReads.contains { !old[$0].isEmpty }
                    let preservesOnly = ["cmp", "cmn", "tst", "cbz", "cbnz", "tbz", "tbnz", "str", "stur", "strb", "strh", "stp", "br"].contains(mnemonic)
                    if readsAddress && !preservesOnly { return (false, targets, "unsupported_address_value_effect") }
                    if mnemonic.hasPrefix("st"), reads.contains(where: { old[$0].contains { $0.kind == 1 } }) {
                        return (false, targets, "unresolved_page_spilled")
                    }
                }
                if row.flow == .return, old[0].contains(where: { $0.kind == 1 }) {
                    return (false, targets, "unresolved_page_returned")
                }
                if let assigned, let destination = ops.first.flatMap(register), destination < 31 {
                    guard assigned.count <= 16 else { return (false, targets, "constant_set_limit") }
                    let narrowed = ops[0].hasPrefix("w")
                        ? Set(assigned.map { ClosedWorldConstant(value: $0.value & 0xffffffff, kind: $0.kind) }) : assigned
                    state[destination] = narrowed
                    targets.formUnion(narrowed.map(\.value))
                }
                if row.flow == .call || row.flow == .indirectCall {
                    if state.prefix(9).contains(where: { $0.contains(where: { $0.kind == 1 }) }) {
                        return (false, targets, "unresolved_page_escapes_call")
                    }
                    for index in 0...18 { state[index] = [] }; state[30] = []
                }
                let successors: [UInt64]
                switch row.flow {
                case .return, .trap: successors = []
                case .jump: successors = row.branchTarget.map { [$0] } ?? []
                case .conditionalJump: successors = (row.branchTarget.map { [$0] } ?? []) + [address + 4]
                case .indirectJump: successors = byBranch[address] ?? []
                default: successors = [address + 4]
                }
                for next in successors {
                    guard next >= summary.startAddress, next < summary.endAddress, byAddress[next] != nil else {
                        if row.flow == .jump, starts.contains(next) { continue }
                        return (false, targets, "unmodeled_code_edge")
                    }
                    if let prior = incoming[next] {
                        guard zip(prior, state).allSatisfy({ pair in pair.0.isEmpty == pair.1.isEmpty }) else {
                            return (false, targets, "constant_join_has_unknown_path")
                        }
                        let merged = zip(prior, state).map { pair in pair.0.union(pair.1) }
                        guard merged.allSatisfy({ $0.count <= 16 }) else { return (false, targets, "constant_join_limit") }
                        if merged != prior { incoming[next] = merged; pending.append(next) }
                    } else { incoming[next] = state; pending.append(next) }
                }
            }
        }
        return (true, targets, "")
    }

    private static func closedWorldCallIsDiscarded(call: UInt64, function: MacIRFunction,
        raw: [UInt64: DecodedInstruction], end: UInt64, tables: [ClosedWorldTable],
        callerSignature: FunctionSignatureOverride?) -> Bool {
        let grouped = Dictionary(grouping: function.instructions, by: { $0.source.address })
        guard grouped.values.allSatisfy({ $0.count == 1 }), let instruction = grouped[call]?.first,
              case let .call(_, result?) = instruction.operation, isResultCarrier(result) else { return false }
        let byAddress = grouped.compactMapValues(\.first)
        var graph: [UInt64: [UInt64]] = [:]
        var pending = [call + 4]
        while let address = pending.popLast() {
            if graph[address] != nil { continue }
            guard graph.count < 50_000, !Task.isCancelled,
                  address >= function.startAddress, address < end,
                  let row = raw[address], let effect = byAddress[address],
                  effect.source.byteText.lowercased() == row.byteText.lowercased(),
                  effect.source.mnemonic.lowercased() == row.mnemonic.lowercased(),
                  effect.source.operands.lowercased() == row.operands.lowercased() else { return false }
            let ops = MacIRBuilder.splitOperands(row.operands)
            if MacIRBuilder.argumentRegisterReads(mnemonic: row.mnemonic, operands: ops).contains(where: {
                MacIRBuilder.integerRegisterView($0)?.index == 0
            }) { return false }
            if row.flow == .return {
                guard callerSignature?.returnType?.trimmingCharacters(in: .whitespacesAndNewlines) == "void" else { return false }
                graph[address] = []; continue
            }
            guard let inputs = modeledInputs(of: effect.operation),
                  !inputs.contains(where: { auditedReadWidth(of: result, in: $0) != nil }) else { return false }
            if MacIRBuilder.argumentRegisterWrites(mnemonic: row.mnemonic, operands: ops).contains(where: {
                MacIRBuilder.integerRegisterView($0)?.index == 0
            }) || destinations(of: effect.operation).contains(where: isResultCarrier) {
                graph[address] = []; continue
            }
            let next: [UInt64]
            switch row.flow {
            case .jump: next = row.branchTarget.map { [$0] } ?? []
            case .conditionalJump: next = (row.branchTarget.map { [$0] } ?? []) + [address + 4]
            case .indirectJump: next = tables.first(where: { $0.dispatchAddress == address })?.targets ?? []
            case .return, .trap, .call, .indirectCall: return false
            case .normal: next = [address + 4]
            }
            guard !next.isEmpty else { return false }
            graph[address] = Array(Set(next)); pending += next
        }
        // Remove proved-discard terminals backwards. A cycle left over is not
        // assumed to terminate or discard, and no recursive stack is needed.
        var remaining = graph.mapValues(\.count), predecessors: [UInt64: [UInt64]] = [:]
        for (source, edges) in graph { for target in edges { predecessors[target, default: []].append(source) } }
        var finished = remaining.filter { $0.value == 0 }.map(\.key), removed = 0
        while let address = finished.popLast() {
            removed += 1
            for source in predecessors[address] ?? [] {
                remaining[source, default: 0] -= 1
                if remaining[source] == 0 { finished.append(source) }
            }
        }
        return removed == graph.count
    }
}

extension MacIRCallerReturnEvidence {
    /// Caller-only omission permission from a complete raw BL and B inventory.
    /// A positive return witness is not a completeness proof for unused results.
    static func discardedDirectCallTargets(functions: [MacIRFunction],
        directCalls: [MacIRSourceSpan], callerWidths: [UInt64: Width]) -> Set<UInt64> {
        guard !Task.isCancelled else { return [] }
        let owners = Dictionary(grouping: functions, by: \.startAddress)
        // The existing classifier is keyed by caller start. Duplicate ownership
        // would overwrite a caller, so it cannot establish an all-site result.
        guard owners.values.allSatisfy({ $0.count == 1 }) else { return [] }
        let rawGroups = Dictionary(grouping: directCalls, by: \.address)
        guard rawGroups.values.allSatisfy({ $0.count == 1 }) else { return [] }
        var rawTargets: [UInt64: UInt64] = [:]
        for source in directCalls {
            let operands = MacIRBuilder.splitOperands(source.operands)
            guard ["bl", "b"].contains(source.mnemonic.lowercased()), operands.count == 1,
                  let operand = operands.first, let target = addressValue(operand) else {
                // An unresolved direct identity might be another call to any
                // candidate. It must not disappear as an unrelated import.
                return []
            }
            rawTargets[source.address] = target
        }
        var lifted: [UInt64: [(caller: UInt64, instruction: MacIRInstruction)]] = [:]
        for function in functions {
            for instruction in function.instructions {
                lifted[instruction.source.address, default: []].append((function.startAddress, instruction))
                if ["bl", "b"].contains(instruction.source.mnemonic.lowercased()) {
                    guard let raw = rawGroups[instruction.source.address]?.first,
                          instruction.source.mnemonic.lowercased() == raw.mnemonic.lowercased(),
                          instruction.source.byteText == raw.byteText,
                          addressValue(instruction.source.operands) == rawTargets[instruction.source.address] else {
                        // Extra, mismatched or unowned IR identity makes this
                        // supplied inventory incomplete, not negative evidence.
                        return []
                    }
                }
            }
        }
        // Supply the already collected widths: do not rerun the positive own-
        // return witness collector while asking this independent lifetime question.
        let classified = collectCallSitesForPurpose(functions: functions, resolvedTargets: [:],
            callerWidths: callerWidths, slotTailSites: [], purpose: .callerOmission)
        var seen: Set<UInt64> = [], refused: Set<UInt64> = []
        for source in directCalls {
            guard !Task.isCancelled else { return [] }
            guard let target = rawTargets[source.address], owners[target] != nil else {
                // A resolved numeric target outside this completed collection
                // cannot alias a candidate start. Its effects on a live result
                // are still refused by the lifetime classifier at that boundary.
                continue
            }
            if source.mnemonic.lowercased() == "b" {
                let sourceGroup = lifted[source.address, default: []]
                let sourceOwners = Set(sourceGroup.map(\.caller))
                let targetOwners = Set(lifted[target, default: []].map(\.caller))
                let matchingLocalSource = sourceGroup.allSatisfy { owned in
                    guard owned.instruction.source.mnemonic.lowercased() == "b",
                          owned.instruction.source.byteText == source.byteText,
                          addressValue(owned.instruction.source.operands) == target else { return false }
                    if case .call = owned.instruction.operation { return false }
                    return true
                }
                // A uniquely owned same-function edge (including an entry
                // backedge) is control flow, not a separate tail invocation.
                // Nonlocal, missing or ambiguous B ownership cannot prove that.
                if sourceOwners != Set([target]) || targetOwners != sourceOwners || !matchingLocalSource {
                    refused.insert(target)
                }
                continue
            }
            seen.insert(target)
            guard let group = lifted[source.address], group.count == 1,
                  let owned = group.first, owned.instruction.source.mnemonic.lowercased() == "bl",
                  owned.instruction.source.byteText == source.byteText,
                  addressValue(owned.instruction.source.operands) == target,
                  case let .call(frame, _) = owned.instruction.operation,
                  frame.controlInputs.indirectTarget == nil else {
                refused.insert(target); continue
            }
            let sites = classified[owned.caller, default: []].filter { $0.address == source.address }
            guard sites.count == 1, let site = sites.first,
                  site.target == .direct(target), !site.isTailCall,
                  site.consumption == .discarded else {
                refused.insert(target); continue
            }
        }
        // No direct site means no permission. One unproved site vetoes the
        // target even if every other caller overwrites X0/W0 before reading it.
        return seen.subtracting(refused)
    }

    /// Records positive reads and complete lifetime proofs independently of return authority.
    static func collectCallSites(functions: [MacIRFunction],
        resolvedTargets: [UInt64: CallSiteContract.Target] = [:],
        callerWidths: [UInt64: Width]? = nil,
        slotTailSites: Set<UInt64> = []) -> [UInt64: [CallSiteContract]] {
        collectCallSitesForPurpose(functions: functions, resolvedTargets: resolvedTargets,
            callerWidths: callerWidths, slotTailSites: slotTailSites, purpose: .returnEvidence)
    }

    private enum CallConsumptionPurpose: Equatable {
        case returnEvidence
        case callerOmission
    }

    private static func collectCallSitesForPurpose(functions: [MacIRFunction],
        resolvedTargets: [UInt64: CallSiteContract.Target], callerWidths: [UInt64: Width]?,
        slotTailSites: Set<UInt64>, purpose: CallConsumptionPurpose) -> [UInt64: [CallSiteContract]] {
        let targets = Dictionary(grouping: functions, by: \.startAddress)
        let starts = Set(targets.keys)
        let witnessedWidths = callerWidths ?? collect(functions: functions)
        var sites: [UInt64: [CallSiteContract]] = [:]
        for function in functions.sorted(by: { $0.startAddress < $1.startAddress }) {
            let grouped = Dictionary(grouping: function.instructions, by: { $0.source.address })
            let unique = grouped.values.allSatisfy { $0.count == 1 }
            let instructions = grouped.compactMapValues(\.first)
            var reachable = Set<UInt64>(), pending = [function.startAddress]
            while let address = pending.popLast() {
                guard reachable.insert(address).inserted, let instruction = instructions[address] else { continue }
                pending += immediateCallerSuccessors(of: instruction, instructions: instructions, targets: targets)
            }
            let widthUses = WidthUseIndex(function: function)
            let reaching = unique ? resultCarrierDefinitions(in: function, instructions: instructions) : [:]
            var result: [CallSiteContract] = []
            for instruction in function.instructions.sorted(by: { $0.source.address < $1.source.address }) {
                let address = instruction.source.address
                let rawTarget = addressValue(instruction.source.operands)
                let nonlocal = rawTarget.map { $0 != function.startAddress && instructions[$0] == nil } ?? true
                let tail = (instruction.source.mnemonic == "b" && nonlocal
                    && (rawTarget.map { starts.contains($0) } == true || resolvedTargets[address] != nil))
                    || (instruction.source.mnemonic == "br" && slotTailSites.contains(address))
                let target: CallSiteContract.Target
                if let resolved = resolvedTargets[address] { target = resolved }
                else if let rawTarget, starts.contains(rawTarget) { target = .direct(rawTarget) }
                else if case let .call(frame, _) = instruction.operation, frame.controlInputs.indirectTarget == nil,
                        addressValue(frame.target) == nil { target = .import(frame.target) }
                else if instruction.source.mnemonic == "bl", let rawTarget { target = .direct(rawTarget) }
                else { target = .unknown }
                if tail {
                    guard unique, reachable.contains(address) else { continue }
                    result.append(.init(address: address, target: target, consumption: .flowsToReturn, isTailCall: true))
                    continue
                }
                guard case .call = instruction.operation else { continue }
                let continuation = address.addressAfter()
                let canReturn = continuation.map {
                    immediateCallerSuccessors(of: instruction, instructions: instructions, targets: targets).contains($0)
                } == true
                var fact: (consumption: CallSiteContract.Consumption, typeDisputed: Bool, consumerTypes: [String], rawReads: [CallSiteContract.RawRead]) =
                    unique && reachable.contains(address) && canReturn
                    ? callConsumption(instruction, in: function, instructions: instructions, reaching: reaching, uses: widthUses, purpose: purpose) : (.unknown, false, [], [])
                // A raw w0 use observes only the low word. Preserve the existing
                // whole-target width audit before forming an exact value shape.
                if case let .direct(callee) = target, case .read(32, nil) = fact.consumption,
                   witnessedWidths[callee] == .x0 {
                    fact.consumption = .read(width: 64, type: nil)
                }
                result.append(.init(address: address, target: target, consumption: fact.consumption,
                    isTailCall: false, typeDisputed: fact.typeDisputed, consumerTypes: fact.consumerTypes,
                    rawReads: fact.rawReads))
            }
            sites[function.startAddress] = result
        }
        return sites
    }

    private enum ResultCarrierDefinition: Equatable {
        case instruction(UInt64)
        case unknown
    }

    /// A read needs the same call definition on every incoming path. Continue
    /// past overwrites here so a later merge cannot hide a second definition;
    /// the separate lifetime walk still stops at the overwrite or opaque effect.
    private static func resultCarrierDefinitions(in function: MacIRFunction,
        instructions: [UInt64: MacIRInstruction]) -> [UInt64: ResultCarrierDefinition] {
        var incoming: [UInt64: ResultCarrierDefinition] = [function.startAddress: .unknown]
        var pending = [function.startAddress], queued: Set<UInt64> = [function.startAddress]
        while let address = pending.popLast() {
            queued.remove(address)
            guard !Task.isCancelled, let instruction = instructions[address], let state = incoming[address] else { return [:] }
            let next: [UInt64]
            let output: ResultCarrierDefinition
            switch instruction.operation {
            case .returnValue: continue
            case .call:
                output = .instruction(address)
                next = address.addressAfter().map { [$0] } ?? []
            case let .switchDispatch(_, cases, defaultTarget):
                let targets = cases.map(\.target) + (defaultTarget.map { [$0] } ?? [])
                next = targets.compactMap(addressValue)
                guard !next.isEmpty, next.count == targets.count else { return [:] }
                output = state
            default:
                let operands = MacIRBuilder.splitOperands(instruction.source.operands)
                let writes = MacIRBuilder.argumentRegisterWrites(mnemonic: instruction.source.mnemonic, operands: operands)
                if modeledInputs(of: instruction.operation) == nil {
                    // An opaque operation may replace x0 even if the decoder
                    // did not name a destination. Never step over it unchanged.
                    output = .unknown
                    // A normal opaque instruction can reach its fallthrough;
                    // unknown control transfers cannot certify any merge.
                    let mnemonic = instruction.source.mnemonic
                    guard mnemonic != "br", mnemonic != "ret", mnemonic != "b",
                          !mnemonic.hasPrefix("b."), !["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic) else { return [:] }
                    next = address.addressAfter().map { [$0] } ?? []
                } else {
                    output = writes.contains(where: { MacIRBuilder.integerRegisterView($0)?.index == 0 })
                        || destinations(of: instruction.operation).contains(where: isResultCarrier)
                        ? .instruction(address) : state
                    next = successors(of: instruction)
                }
            }
            for successor in Set(next) where instructions[successor] != nil {
                let merged = incoming[successor].map { $0 == output ? output : .unknown } ?? output
                if incoming[successor] != merged {
                    incoming[successor] = merged
                    if queued.insert(successor).inserted { pending.append(successor) }
                }
            }
        }
        return incoming
    }

    private static func callConsumption(_ call: MacIRInstruction, in function: MacIRFunction,
        instructions: [UInt64: MacIRInstruction], reaching: [UInt64: ResultCarrierDefinition], uses: WidthUseIndex,
        purpose: CallConsumptionPurpose)
        -> (consumption: CallSiteContract.Consumption, typeDisputed: Bool, consumerTypes: [String], rawReads: [CallSiteContract.RawRead]) {
        guard case let .call(_, possibleResult) = call.operation else { return (.unknown, false, [], []) }
        let result = possibleResult.flatMap { isResultCarrier($0) ? $0 : nil }
        if purpose == .callerOmission, result == nil { return (.unknown, false, [], []) }
        var readWidth: Int?, readTypes = Set<String>(), rawReadingPCs = Set<UInt64>()
        if let address = call.source.address.addressAfter(),
           reaching[address] == .instruction(call.source.address),
           let immediate = immediateResultRead(after: call, instructions: instructions) {
            readWidth = immediate.width.rawValue
            rawReadingPCs.insert(address)
        }
        var graph: [UInt64: [UInt64]] = [:], pending = successors(of: call)
        guard !pending.isEmpty else { return (.unknown, false, [], []) }
        var flows = false, refused = false, ambiguousRead = false
        while let address = pending.popLast() {
            if graph[address] != nil { continue }
            guard graph.count < 50_000, !Task.isCancelled, let instruction = instructions[address] else {
                refused = true; continue
            }
            graph[address] = []
            if case .returnValue = instruction.operation {
                flows = true
                continue
            }
            if case let .call(frame, _) = instruction.operation {
                var consumed = false
                if let signature = frame.knownSignature ?? frame.typedIndirectSignature {
                    for argument in frame.arguments.canonicalPhysicalEntriesForAudit {
                        guard let result,
                              let width = typedCallArgumentReadWidth(of: result, argument: argument, frame: frame),
                              let position = argument.sourcePosition,
                              let parameter = signature.parameters.first(where: { $0.index == position }) else { continue }
                        guard reaching[address] == .instruction(call.source.address) else {
                            ambiguousRead = true; continue
                        }
                        readWidth = max(readWidth ?? 0, width)
                        readTypes.insert(parameter.type)
                        consumed = true
                    }
                }
                // A modeled consumer reads before the next call replaces x0.
                // An unclassified call boundary cannot complete this proof.
                if !consumed { refused = true }
                continue
            }
            guard let inputs = modeledInputs(of: instruction.operation) else { refused = true; continue }
            if purpose == .callerOmission, let result {
                let liveInputs = inputs + unclassifiedInputs(of: instruction)
                // While the physical result is live, neither an exact use nor
                // an opaque input may be hidden by the following overwrite.
                if liveInputs.contains(where: { auditedReadWidth(of: result, in: $0) != nil }) {
                    refused = true; continue
                }
            }
            let operands = MacIRBuilder.splitOperands(instruction.source.operands)
            let physical = MacIRBuilder.argumentRegisterReads(mnemonic: instruction.source.mnemonic, operands: operands)
                .compactMap { MacIRBuilder.integerRegisterView($0) }.filter { $0.index == 0 }.map(\.width)
            let semantic = result.map { result in
                inputs.compactMap { Self.readWidth(of: result, in: $0, width: 64) }
            } ?? []
            if let width = (physical + semantic).max() {
                if reaching[address] == .instruction(call.source.address) {
                    readWidth = max(readWidth ?? 0, width)
                    rawReadingPCs.insert(address)
                }
                else { ambiguousRead = true }
            }
            let writes = MacIRBuilder.argumentRegisterWrites(mnemonic: instruction.source.mnemonic, operands: operands)
            if writes.contains(where: { MacIRBuilder.integerRegisterView($0)?.index == 0 })
                || destinations(of: instruction.operation).contains(where: isResultCarrier) { continue }
            let next = Array(Set(successors(of: instruction)))
            if next.isEmpty { refused = true; continue }
            graph[address] = next
            pending += next
        }
        if refused || ambiguousRead { return (.unknown, false, [], []) }
        if let width = readWidth {
            let auditedWidth = width == 32 && result.map {
                allUsesAre32Bit(of: $0, in: function, instructions: instructions, uses: uses, classifyTypedCalls: true)
            } == true ? 32 : 64
            return (.read(width: auditedWidth, type: readTypes.count == 1 ? readTypes.first : nil), readTypes.count > 1, readTypes.sorted(),
                    rawReadPaths(from: call.source.address, graph: graph, readingPCs: rawReadingPCs))
        }
        guard let result else { return (.unknown, false, [], []) }
        if purpose == .callerOmission {
            guard !flows, lifetimeTerminates(graph) else { return (.unknown, false, [], []) }
        }
        func escapes(_ value: MacIRValue) -> Bool {
            switch purpose {
            case .returnEvidence: return auditedReadWidth(of: result, in: value) != nil
            case .callerOmission: return Self.readWidth(of: result, in: value, width: 64) != nil
            }
        }
        // After proved physical death, an exact SSA/phi reference still vetoes
        // omission. An unrelated unavailable value is not this result identity.
        // Return-width evidence retains its stricter opaque-input audit.
        if function.phis.contains(where: { $0.incoming.contains { escapes($0.value) } }) {
            return (.unknown, false, [], [])
        }
        for instruction in function.instructions {
            var inputs = (modeledInputs(of: instruction.operation) ?? []) + unclassifiedInputs(of: instruction)
            if case let .returnValue(.some(.unknown(marker))) = instruction.operation,
               marker == MacIRIndirectTargetResolution.unresolvedReturnContractMarker {
                // This generated return marker is not a reference to the
                // call's SSA result. Still audit an explicit return target.
                inputs = instruction.returnTarget.map { [$0] } ?? []
            }
            if inputs.contains(where: escapes) {
                if case .returnValue = instruction.operation, graph[instruction.source.address] != nil { continue }
                return (.unknown, false, [], [])
            }
        }
        if purpose == .returnEvidence, !lifetimeTerminates(graph) { return (.unknown, false, [], []) }
        return (flows ? .flowsToReturn : .discarded, false, [], [])
    }

    // Success must hold on every path. A live cycle is not a proof of death.
    private static func lifetimeTerminates(_ graph: [UInt64: [UInt64]]) -> Bool {
        var remaining = graph.mapValues(\.count), predecessors: [UInt64: [UInt64]] = [:]
        for (source, edges) in graph { for target in edges { predecessors[target, default: []].append(source) } }
        var finished = remaining.filter { $0.value == 0 }.map(\.key), removed = 0
        while let address = finished.popLast() {
            removed += 1
            for source in predecessors[address] ?? [] {
                remaining[source, default: 0] -= 1
                if remaining[source] == 0 { finished.append(source) }
            }
        }
        return removed == graph.count
    }

    /// Retain a deterministic shortest witness for each admitted raw read. The
    /// lifetime and all-incoming definition proofs above decide admission; this
    /// traversal only serializes their already collected instruction edges.
    private static func rawReadPaths(from callPC: UInt64, graph: [UInt64: [UInt64]],
                                     readingPCs: Set<UInt64>) -> [CallSiteContract.RawRead] {
        guard !readingPCs.isEmpty, let continuation = callPC.addressAfter(), graph[continuation] != nil else { return [] }
        var predecessors: [UInt64: UInt64] = [continuation: callPC]
        var pending = [continuation], index = 0
        while index < pending.count {
            let address = pending[index]
            index += 1
            for successor in (graph[address] ?? []).sorted() where predecessors[successor] == nil {
                predecessors[successor] = address
                pending.append(successor)
            }
        }
        return readingPCs.sorted().compactMap { readingPC in
            var reversePath = [readingPC], address = readingPC
            while address != callPC {
                guard let predecessor = predecessors[address] else { return nil }
                reversePath.append(predecessor)
                address = predecessor
            }
            return .init(readingPC: readingPC, path: Array(reversePath.reversed()))
        }
    }

}


extension MacIRCallerReturnEvidence {
    static func buildImageFacts(analysis: ImageAnalysis, functions: [MacIRFunction],
        effectiveSignatures: [UInt64: FunctionSignatureOverride] = [:],
        legacyReport: ClosedWorldReport? = nil) -> ImageFacts {
        let starts = Set(analysis.functions.map(\.startAddress))
        let report = legacyReport ?? collectClosedWorld(analysis: analysis, functions: functions,
            effectiveSignatures: effectiveSignatures, includeImageFacts: true)
        var guards = report.imageGuards
        let taken: Set<UInt64>
        if let captured = report.addressTaken { taken = captured }
        else {
            // A refused or older collection carries no negative address authority.
            // Reuse its failure rather than beginning another raw-image scan.
            taken = starts
            guards["address_taken_inventory_complete"] = false
        }
        return ImageFacts(functionStarts: starts, exported: report.exported, entry: report.entry,
            addressTaken: taken, tableTargets: report.tableTargets, closedWorldGuards: guards,
            imageComplete: !guards.isEmpty && guards.values.allSatisfy { $0 })
    }
}
