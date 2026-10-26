import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

extension OrdinaryC {
    enum Role: Hashable { case branch, selectionCondition, memoryAddress, memoryData, callee, callArgument(Int) }
    struct Permission: Hashable { let callRow: Int; let sinkRow: Int; let role: Role }
    struct Input { let name: String; let type: CType; let entrySlot: Int }
    struct Field { let owner: String; let name: String; let offset: UInt64; let type: CType }
    struct CarrierRole { let register: Int; let width: Int }
    struct FrozenCall {
        let row: Int
        let payload: String
        let target: String
        let resultName: String?
        // Native opaque X64 aliases have the original signed64 representation.
        // K supplies raw bits in this representation, not an unsigned C cast.
        let resultType: CType = .i64
        let control: CarrierRole?
        let arguments: [CarrierRole]
    }
    struct MemoryEffect { let loading: Bool; let bytes: Int }
    struct Contract {
        let signature: String
        let inputs: [Input]
        let fields: [Field]
        let calls: [Int: FrozenCall]
        let exterior: [Int: String]
        let terminalRow: Int
        let terminalPayload: String
        let terminalName: String?
        let returnType: CType?
        let rowsByAddress: [UInt64: Int]
        let allowedLabels: Set<String>
        let memoryEffects: [Int: [MemoryEffect]]
        let helpers: [Int: Set<String>]
        let deadResults: Set<Int>
        let permissions: Set<Permission>
        // Default-off capability used only by the separately frozen no-call
        // contract. It grants one exact nonnumeric terminal, never a value.
        var noCallUnavailableTerminal: Bool = false
        func validateEnvelope(lines: [TextLine], tokens: [Token]) throws {
            let signatures = lines.enumerated().filter { $0.element.envelope == .signature }
            let closing = lines.enumerated().filter { $0.element.envelope == .closingBrace }
            guard signatures.count == 1, signatures[0].offset == 0, signatures[0].element.text == signature,
                  closing.count == 1, closing[0].offset == lines.count - 1,
                  closing[0].element.text == "}" else { throw Failure.invalidContract("function envelope changed") }
            for (index, line) in lines.enumerated() where line.envelope == .metadata {
                guard !tokens.contains(where: { $0.line == index + 1 }) else { throw Failure.unsupportedSyntax("executable metadata") }
            }
            func requireProtected(_ row: Int, _ expected: String) throws {
                let actual = lines.filter { $0.source.flatMap { rowsByAddress[$0] } == row }.map {
                    String($0.text.drop(while: { $0 == " " || $0 == "\t" }))
                }
                guard actual.filter({ $0 == expected }).count == 1 else { throw Failure.invalidContract("missing/duplicated protected row \(row)") }
                for extra in actual where extra != expected {
                    let tokens = try OrdinaryC.lex(extra).map(\.text)
                    guard (tokens.count == 2 || tokens.count == 3), allowedLabels.contains(tokens[0]),
                          tokens[1] == ":", tokens.count == 2 || tokens[2] == ";" else {
                        throw Failure.invalidContract("extra executable text at protected row \(row)")
                    }
                }
            }
            try requireProtected(terminalRow, terminalPayload)
            if noCallUnavailableTerminal {
                guard calls.isEmpty, exterior.isEmpty, helpers.isEmpty,
                      deadResults.isEmpty, permissions.isEmpty,
                      terminalName == nil, returnType == nil,
                      try OrdinaryC.lex(terminalPayload).map(\.text) == ["return", "unresolved_return_contract", ";"],
                      tokens.filter({ $0.text == "unresolved_return_contract" }).count == 1 else {
                    throw Failure.invalidContract("unavailable terminal requires one exact protected no-call observation")
                }
                guard let marker = tokens.firstIndex(where: { $0.text == "unresolved_return_contract" }),
                      marker > 0, tokens[marker - 1].text == "return", marker + 1 < tokens.count,
                      tokens[marker + 1].text == ";",
                      tokens.dropFirst(marker + 2).allSatisfy({ $0.text == "}" }) else {
                    throw Failure.invalidContract("unavailable terminal is not the final executable statement")
                }
            }
            for (row, expected) in exterior { try requireProtected(row, expected) }
            for (row, call) in calls {
                let exact = lines.filter { $0.source.flatMap { rowsByAddress[$0] } == row }.filter {
                    String($0.text.drop(while: { $0 == " " || $0 == "\t" })) == call.payload
                }
                guard exact.count == 1 else { throw Failure.invalidContract("missing/changed protected call \(row)") }
            }
        }
        /// Keep frozen authority while transporting its names through the
        /// method's already provenance-bound alpha map. Matching candidate text
        /// can establish only a renaming, never a new operation or call role.
        func alphaEquivalent(to document: PseudocodeDocument,
                             using alpha: inout SSAAlphaEquivalence) throws -> Contract {
            func protected(_ expected: String, row: Int) throws -> String {
                let candidates = document.lines.filter {
                    $0.sourceAddress.flatMap { rowsByAddress[$0] } == row
                }.map { $0.text.trimmingCharacters(in: .whitespaces) }
                let matches = candidates.compactMap { actual -> (String, SSAAlphaEquivalence)? in
                    var candidate = alpha
                    guard candidate.mismatch(actual: actual, expected: expected) == nil else { return nil }
                    return (actual, candidate)
                }
                guard matches.count == 1, let match = matches.first else {
                    throw Failure.invalidContract("missing/duplicated alpha-equivalent protected row \(row)")
                }
                alpha = match.1
                return match.0
            }
            func translated(_ expected: String) throws -> String {
                guard let result = alpha.translatedExpected(expected) else {
                    throw Failure.invalidContract("unmapped protected identity in \(expected)")
                }
                return result
            }
            // Establish the entire envelope before translating derived names.
            // No parser or oracle can therefore retain a stale result binding.
            for (row, call) in calls.sorted(by: { $0.key < $1.key }) { _ = try protected(call.payload, row: row) }
            for (row, payload) in exterior.sorted(by: { $0.key < $1.key }) { _ = try protected(payload, row: row) }
            _ = try protected(terminalPayload, row: terminalRow)
            for input in inputs {
                if let failure = alpha.mismatch(actual: input.name, expected: input.name) {
                    throw Failure.invalidContract("entry identity changed: \(failure)")
                }
            }
            let translatedCalls = try calls.mapValues { call in
                FrozenCall(row: call.row, payload: try translated(call.payload),
                    target: try translated(call.target),
                    resultName: try call.resultName.map { try translated($0) },
                    control: call.control, arguments: call.arguments)
            }
            let result = Contract(signature: try translated(signature),
                inputs: try inputs.map { Input(name: try translated($0.name), type: $0.type, entrySlot: $0.entrySlot) },
                fields: fields, calls: translatedCalls, exterior: try exterior.mapValues { try translated($0) },
                terminalRow: terminalRow, terminalPayload: try translated(terminalPayload),
                terminalName: try terminalName.map { try translated($0) }, returnType: returnType,
                rowsByAddress: rowsByAddress, allowedLabels: allowedLabels, memoryEffects: memoryEffects,
                helpers: helpers, deadResults: deadResults, permissions: permissions,
                noCallUnavailableTerminal: noCallUnavailableTerminal)
            // Program retains validateEnvelope's duplicate/extra-statement and
            // call-role checks, now against the consistently translated contract.
            return result
        }

        func protectedIdentifiers() throws -> Set<String> {
            var result: Set<String> = []
            for text in [signature, terminalPayload] + Array(exterior.values) + calls.values.map(\.payload) {
                result.formUnion(try OrdinaryC.lex(text).map(\.text).filter(OrdinaryC.identifier))
            }
            return result
        }
    }
    static func lines(_ document: PseudocodeDocument) -> [TextLine] {
        document.lines.map { line in
            let kind: EnvelopeKind
            switch line.kind {
            case .signature: kind = .signature
            case .metadata: kind = .metadata
            case .closingBrace: kind = .closingBrace
            default: kind = .body
            }
            return .init(text: line.text, source: line.sourceAddress, envelope: kind,
                phiEdge: line.syntheticPhiEdge.map {
                    .init(blockAddress: $0.blockAddress, predecessorAddress: $0.machineAddress)
                })
        }
    }

    /// Historical diagnostic payloads may contain quoted assembly. Inventory
    /// identifier tokens without treating those payloads as executable C or as
    /// result reads. Candidate parsing and exact protected-call lexing continue
    /// to use the stricter executable lexer below.
    static func baselineAuthorityIdentifierCounts(_ baseline: String) throws -> [String: Int] {
        let tokens: [OrdinaryCOutputAudit.Token]
        do { tokens = try OrdinaryCOutputAudit.lex(baseline) }
        catch { throw Failure.invalidContract("malformed frozen baseline lexical inventory: \(error)") }
        var counts: [String: Int] = [:]
        for token in tokens where identifier(token.text) { counts[token.text, default: 0] += 1 }
        return counts
    }

    /// Bind one complete captured semantic contract before constructing its
    /// Program. The legacy namespace keeps the original exact contract; SSA
    /// transports every protected identity through one source-row/width proof.
    /// Program still enforces the unchanged missing/duplicate/extra-effect gates.
    static func contract(for fixture: OrdinaryCRecordedCallFixture) throws -> Contract {
        guard fixture.function.ssaEnabled else {
            return try contract(rows: fixture.rows, function: fixture.function,
                baseline: fixture.baselineText, callRows: fixture.callRows)
        }
        let legacy = SSAAlphaEquivalence.legacyFunction(from: fixture.input)
        let frozen = try contract(rows: fixture.rows, function: legacy,
            baseline: fixture.baselineText, callRows: fixture.callRows)
        var alpha = SSAAlphaEquivalence(expected: legacy, actual: fixture.function)
        return try frozen.alphaEquivalent(to: fixture.document, using: &alpha)
    }

    /// Immutable facts are extracted from original retained payloads/literal rows.
    /// The function is consulted ONLY for original opaque carrier representation.
    /// No candidate scalar operation, projected value, physical plan or CFG
    /// decision enters Contract or Program.
    static func contract(rows: [InstructionRow], function: MacIRFunction, baseline: String,
                         callRows: [Int], blockAddresses: Set<UInt64> = []) throws -> Contract {
        guard let entry = rows.first?.address else { throw Failure.invalidContract("empty original capture") }
        let terminalRow: Int, prefix: Int, suffix: Int, dead: Set<Int>, live: Set<Int>
        switch entry {
        case 0x26c78: terminalRow = 294; prefix = 3; suffix = 292; dead = [17,51,86,120,234,262,274,285,317]; live = [23,99,212]
        case 0x2893c: terminalRow = 284; prefix = 3; suffix = 282; dead = [17,51,86,121,194,227,255,275,307]; live = [23]
        case 0x3ae18: terminalRow = 215; prefix = 7; suffix = 209; dead = [21,51,149]; live = [35,102,122,129,159,168,187,192]
        case 0x3b774: terminalRow = 187; prefix = 7; suffix = 181; dead = [21,52,159]; live = [35,131,136]
        case 0x33418: terminalRow = 57; prefix = 6; suffix = 52; dead = [40,48]; live = [12,21]
        default: throw Failure.invalidContract("outside five approved original functions")
        }
        guard Set(callRows) == dead.union(live), rows.indices.contains(terminalRow), rows[terminalRow].mnemonic == "ret" else {
            throw Failure.invalidContract("original call/terminal manifest drift")
        }
        let baselineLines = baseline.components(separatedBy: "\n")
        guard let signature = baselineLines.first, let returnIndex = baselineLines.firstIndex(where: { $0.hasSuffix("// return") }),
              baselineLines.filter({ $0.hasSuffix("// return") }).count == 1 else { throw Failure.invalidContract("missing frozen terminal") }
        func payload(_ text: String) -> String { String(text.drop(while: { $0 == " " || $0 == "\t" })) }
        let callLineIndices = baselineLines.indices.filter { baselineLines[$0].hasSuffix("// call") }
        let callPayloads = callLineIndices.map { payload(baselineLines[$0]) }
        guard callPayloads.count == callRows.count else { throw Failure.invalidContract("frozen call count") }
        var calls: [Int: FrozenCall] = [:]
        let baselineIdentifiers = try baselineAuthorityIdentifierCounts(baseline)
        for (index, row) in callRows.enumerated() {
            guard function.instructions.indices.contains(row), case let .call(frame, _) = function.instructions[row].operation,
                  frame.knownSignature == nil, frame.richArguments == nil, frame.indirectResultPointer == nil else {
                throw Failure.invalidContract("original opaque representation changed")
            }
            let statement = callPayloads[index], tokens = try lex(statement).map(\.text)
            let result = tokens.count > 1 && tokens[1] == "=" ? tokens[0] : nil
            guard let result, identifier(result) else { throw Failure.invalidContract("these original43 calls all have printed results") }
            let lexicalReads = baselineIdentifiers[result, default: 0] - 1
            // The live manifest is frozen. Reconciled legacy text may no longer
            // name a joined use, so captured decoded observation also suffices.
            // Dead rows retain their exact lexical check; candidate output never
            // establishes authority and no new return/signature role is granted.
            let laterText = baselineLines.dropFirst(callLineIndices[index] + 1).joined(separator: "\n")
            let laterTokens = try OrdinaryCOutputAudit.lex(laterText)
            let laterRead = laterTokens.indices.contains { token in
                laterTokens[token].text == result
                    && (token + 1 == laterTokens.count || laterTokens[token + 1].text != "=")
            }
            let liveResultObserved = live.contains(row) && (laterRead
                || RegionalCallOracle.Program.capturedResultIsRead(rows: rows, afterCall: row))
            guard (dead.contains(row) && lexicalReads == 0) || liveResultObserved else {
                throw Failure.invalidContract("frozen baseline result authority differs at \(row)")
            }
            let arguments = try frame.arguments.canonicalPhysicalEntriesForAudit.map { entry -> CarrierRole in
                guard case let .gpr(register, width) = entry.location, (0..<8).contains(register), [32,64].contains(width) else {
                    throw Failure.invalidContract("unsupported original opaque carrier")
                }
                return .init(register: register, width: width)
            }
            let controls = try frame.controlInputs.canonicalControlInputsForAudit.map { input -> CarrierRole in
                guard case let .gpr(register) = input.register else { throw Failure.invalidContract("unsupported original call control") }
                return .init(register: register, width: 64)
            }
            guard controls.count <= 1 else { throw Failure.invalidContract("multiple original indirect controls") }
            calls[row] = .init(row: row, payload: statement, target: frame.target, resultName: result,
                               control: controls.first, arguments: arguments)
        }
        var exterior: [Int: String] = [:]
        for row in 0..<prefix { exterior[row] = payload(baselineLines[row + 2]) }
        for row in suffix..<terminalRow { exterior[row] = payload(baselineLines[returnIndex - (terminalRow - row)]) }
        // Explicit original entry slots. These spellings are frozen external
        // operands, not runtime register-name recognition or W/X alias coupling.
        let saved: [(String, Int)]
        switch entry {
        case 0x26c78, 0x2893c: saved = [("x20_0",20),("x19_0",19),("x29_0",29),("x30_0",30)]
        case 0x3ae18, 0x3b774: saved = [("x28_0",28),("x27_0",27),("x26_0",26),("x25_0",25),("x24_0",24),("x23_0",23),("x22_0",22),("x21_0",21),("x20_0",20),("x19_0",19),("x29_0",29),("x30_0",30)]
        default: saved = [("x26_0",26),("x25_0",25),("x24_0",24),("x23_0",23),("x22_0",22),("x21_0",21),("x20_0",20),("x19_0",19),("x29_0",29),("x30_0",30)]
        }
        var inputs = saved.map { Input(name: $0.0, type: .u64, entrySlot: $0.1) }
        inputs += [.init(name: "sp_0", type: .u64, entrySlot: 31),
                   .init(name: entry == 0x33418 ? "arg0" : "cinfo", type: entry == 0x33418 ? .i64 : .jpegPointer, entrySlot: 0)]
        var memory: [Int: [MemoryEffect]] = [:], helpers: [Int: Set<String>] = [:]
        var blocks = blockAddresses.union([entry])
        for (row, instruction) in rows.enumerated() {
            let op = instruction.mnemonic
            if ["ldr","ldrb","ldrsw","ldur","ldp","str","strb","stp"].contains(op) {
                let first = instruction.operands.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
                let bytes: Int
                if op == "ldrb" || op == "strb" { bytes = 1 }
                else if op == "ldrsw" || first.hasPrefix("w") { bytes = 4 }
                else if first.hasPrefix("x") { bytes = 8 }
                else { throw Failure.invalidContract("unsupported original memory width") }
                memory[row] = Array(repeating: .init(loading: op.hasPrefix("ld"), bytes: bytes), count: op == "ldp" || op == "stp" ? 2 : 1)
            }
            if op == "adrp" { helpers[row] = ["__adrp"] }
            if op == "sdiv" { helpers[row] = ["__a64_sdiv32"] }
            if op == "b" || op.hasPrefix("b.") || op == "cbz" || op == "cbnz" {
                let target = instruction.operands.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) ?? ""
                if target.hasPrefix("0x"), let address = UInt64(target.dropFirst(2), radix: 16) { blocks.insert(address) }
                if rows.indices.contains(row + 1) { blocks.insert(rows[row + 1].address) }
            }
        }
        var permissions: Set<Permission> = []
        func allow(_ call: Int, _ role: Role, _ sites: [Int]) {
            for site in sites { permissions.insert(.init(callRow: call, sinkRow: site, role: role)) }
        }
        switch entry {
        case 0x26c78:
            allow(23, .memoryData, [25]); allow(23, .memoryAddress, [28,246,272,278,315])
            allow(99, .branch, [100]); allow(212, .branch, [213])
        case 0x2893c:
            allow(23, .memoryData, [25]); allow(23, .memoryAddress, [28,192,239,268,305])
        case 0x3ae18:
            allow(35, .memoryData, [39]); allow(35, .memoryAddress, [42,43,79,110,112,179,194,204,206,207])
            allow(102, .selectionCondition, [109]); allow(159, .selectionCondition, [109])
            allow(122, .branch, [124]); allow(129, .branch, [131]); allow(168, .branch, [170])
            allow(187, .callArgument(2), [192]); allow(192, .memoryData, [194])
        case 0x3b774:
            allow(35, .memoryData, [39]); allow(35, .memoryAddress, [40,43,44,80,105,107,123,138,176,178,179])
            allow(131, .callArgument(2), [136]); allow(136, .memoryData, [138])
        default: allow(12, .branch, [13]); allow(21, .branch, [22])
        }
        return .init(signature: signature, inputs: inputs,
            fields: [.init(owner: "jpeg_decompress_struct", name: "data_precision", offset: 0x128, type: .i32)],
            calls: calls, exterior: exterior, terminalRow: terminalRow, terminalPayload: payload(baselineLines[returnIndex]),
            terminalName: entry == 0x33418 ? "x0_9" : nil, returnType: entry == 0x33418 ? .i64 : nil,
            rowsByAddress: Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.address, $0.offset) }),
            allowedLabels: Set(blocks.map { "L_" + String($0, radix: 16) }), memoryEffects: memory,
            helpers: helpers, deadResults: dead, permissions: permissions)
    }
    static func scenario(_ source: RegionalCallOracle.Scenario, contract: Contract) throws -> Scenario {
        try scenario(name: source.name, registers: source.registers, memory: source.memory.bytes, responses: source.responses, contract: contract)
    }
    static func scenario(_ source: RegionalSwitchOracle.Scenario, contract: Contract) throws -> Scenario {
        guard source.startRow == 0, source.stopBeforeRow == nil, source.regionalBindings.isEmpty else {
            throw Failure.invalidContract("regional-only historical case is not whole-function coverage")
        }
        return try scenario(name: source.name, registers: source.registers, memory: source.memory.bytes, responses: source.responses, contract: contract)
    }
    private static func scenario(name: String, registers: [Int: UInt64], memory: [UInt64: UInt8],
                                 responses: [RegionalCallOracle.Response], contract: Contract) throws -> Scenario {
        var inputs: [String: Value] = [:]
        for binding in contract.inputs {
            guard let bits = registers[binding.entrySlot] else { throw Failure.invalidContract("missing original entry input \(binding.entrySlot)") }
            inputs[binding.name] = .init(bits, binding.type)
        }
        return .init(name: name, inputs: inputs, memory: memory, responses: responses.map { response in
            .init(row: response.row, result: response.result,
                  writes: response.writes.map { .init(address: $0.address, bytes: $0.bytes, bits: $0.bits) },
                  expectedArguments: response.expectedArguments, expectedControl: response.expectedControl)
        })
    }
    static func compare(_ candidate: Result, events: [RegionalCallOracle.Event], memory: [UInt64: UInt8],
                        returned: Bool, terminal: UInt64?, contract: Contract, name: String) throws {
        guard !contract.noCallUnavailableTerminal, candidate.unavailableTerminal == nil else {
            throw Failure.invalidContract("nonnumeric terminal needs the explicit no-call observation comparison")
        }
        guard candidate.returned, returned else { throw Failure.semanticMismatch("\(name): both executions must terminate normally") }
        var counts: [Int: Int] = [:]
        let sourceEvents: [Event] = try events.map { event in
            switch event {
            case let .call(call):
                return .call(.init(row: call.row, occurrence: call.occurrence, target: call.target,
                    control: call.control.map { .init(register: $0.register, width: $0.width, bits: $0.bits) },
                    arguments: call.arguments.map { .init(register: $0.register, width: $0.width, bits: $0.bits) },
                    result: call.result, writes: call.writes.map { .init(address: $0.address, bytes: $0.bytes, bits: $0.bits) }))
            case let .load(row, address, bytes, bits), let .store(row, address, bytes, bits):
                guard let effects = contract.memoryEffects[row], !effects.isEmpty else { throw Failure.invalidContract("source effect missing manifest") }
                let index = counts[row, default: 0]; counts[row] = index + 1
                let site = SourceSite(row: row, effectOrdinal: index % effects.count), occurrence = index / effects.count
                if case .load = event { return .load(site, occurrence, address, bytes, bits) }
                return .store(site, occurrence, address, bytes, bits)
            }
        }
        guard candidate.events == sourceEvents else {
            let first = Array(zip(candidate.events, sourceEvents)).firstIndex { pair in pair.0 != pair.1 }
            throw Failure.semanticMismatch("\(name): ordered effect mismatch at \(first.map(String.init) ?? "length"), candidate \(candidate.events.count), source \(sourceEvents.count)")
        }
        guard candidate.memory == memory else { throw Failure.semanticMismatch("\(name): final defined byte memory differs") }
        guard candidate.terminal?.bits == terminal else { throw Failure.semanticMismatch("\(name): original terminal differs") }
        guard candidate.consumedResponses == events.filter({ if case .call = $0 { return true }; return false }).count else { throw Failure.semanticMismatch("\(name): dynamic response count") }
    }
}
