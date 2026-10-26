import Foundation
import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// One candidate render from complete schema2 input, or the explicit one-callee
/// opaque derivative below, bound to source 39a734962. Retained literal
/// rows, baseline and scenario metadata are independent source witnesses only.
/// The captured-call route does not decode machines, process headers, restore a
/// reduced snapshot or use old reflected model hashes as fresh authority.
struct OrdinaryCRecordedCallFixture {
    struct CallPayload {
        let row: Int
        let address: UInt64
        let baseline: String
        let after: [String]
    }
    struct RecordedRow {
        let address: UInt64
        let bytes: String
        let mnemonic: String
        let operands: String
        let comment: String?
        let operandWitness: UInt64
        let instructionWitness: UInt64
    }
    let start: UInt64
    let baselineText: String
    let callRows: [Int]
    let rows: [InstructionRow]
    let input: PseudocodeRenderInput
    let function: MacIRFunction
    let document: PseudocodeDocument
    var callPayloads: [CallPayload] {
        let saved = baselineText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasSuffix("// call") }
        precondition(saved.count == callRows.count)
        return callRows.enumerated().map { ordinal, row in
            .init(row: row, address: rows[row].address, baseline: saved[ordinal],
                  after: document.lines(sourcedAt: rows[row].address).map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { $0.hasSuffix("// call") })
        }
    }
    static func upsampler(_ seed: RegionalCallSeed) throws -> Self {
        try upsampler(seed, opaqueJroundUp: false)
    }

    /// Regional opaque-call invariants use an explicit one-callee derivative.
    /// The original captured declaration remains available through upsampler(_:).
    static func opaqueUpsampler(_ seed: RegionalCallSeed) throws -> Self {
        try upsampler(seed, opaqueJroundUp: true)
    }

    private static func upsampler(_ seed: RegionalCallSeed, opaqueJroundUp: Bool) throws -> Self {
        guard seed == .jinit || seed == .j12init else { throw OrdinaryCOutputAudit.Failure.invalid("only the two approved upsamplers") }
        let captures = try seed.capturedRows().map {
            RecordedRow(address: $0.address, bytes: $0.bytes, mnemonic: $0.mnemonic,
                        operands: $0.operands, comment: $0.comment, operandWitness: $0.operandWitness,
                        instructionWitness: $0.instructionWitness)
        }
        return try makeComplete(name: seed.name, start: seed.start, captures: captures,
            rowCount: seed.rowCount, blockCount: seed.blockCount,
            functionWitness: seed.functionWitness, blocksWitness: seed.blocksWitness,
            signature: seed.signature, baselineText: seed.baselineText, callRows: seed.callRows,
            loopHeaders: [15], backEdges: [CFGEdge(seed == .jinit ? 45 : 31, 15)],
            opaqueJroundUp: opaqueJroundUp)
    }
    static func skipVariable() throws -> Self {
        let seed = RegionalTerminalSeed.skipVariable
        let captures = try seed.capturedRows().map {
            RecordedRow(address: $0.address, bytes: $0.bytes, mnemonic: $0.mnemonic,
                        operands: $0.operands, comment: $0.comment, operandWitness: $0.operandWitness,
                        instructionWitness: $0.instructionWitness)
        }
        return try makeComplete(name: seed.name, start: seed.start, captures: captures,
            rowCount: seed.rowCount, blockCount: seed.blockCount,
            functionWitness: seed.functionWitness, blocksWitness: seed.blocksWitness,
            signature: seed.signature, baselineText: seed.baselineText, callRows: seed.callRows,
            loopHeaders: [], backEdges: [])
    }
    private static func makeComplete(name: String, start: UInt64, captures: [RecordedRow], rowCount: Int,
                                     blockCount: Int, functionWitness: UInt64, blocksWitness: UInt64,
                                     signature: FunctionSignatureOverride?, baselineText: String,
                                     callRows: [Int], loopHeaders: Set<Int>, backEdges: Set<CFGEdge>,
                                     opaqueJroundUp: Bool = false) throws -> Self {
        // Old model hashes/signature are retained source-witness metadata, not
        // authority for the fresh model. Only the explicit opaque branch below
        // derives a one-callee absence after complete input validation.
        let full = try opaqueJroundUp
            ? makeOpaqueUpsampler(name: name, start: start)
            : RegionalSchema2Bindings39A.make(function: name, start: start)
        if !opaqueJroundUp {
            try RegionalSchema2BuiltFixture.requireCompleteInputAuthority(full.input, capture: full.capture)
        }
        guard captures.count == rowCount, full.rows.count == rowCount,
              full.capture.cfg_blocks.count == blockCount, full.baselineText == baselineText,
              full.rows.enumerated().allSatisfy({ index, row in
                  let saved = captures[index]
                  return row.address == saved.address && row.address == start + UInt64(index * 4) &&
                      row.bytes == saved.bytes && row.mnemonic == saved.mnemonic && row.operands == saved.operands &&
                      row.comment == saved.comment && !row.hasBreakpoint && row.structuredOperands != nil
              }),
              full.rows.indices.filter({ ["bl", "blr"].contains(full.rows[$0].mnemonic) }) == callRows,
              full.capture.lifted_rows.count == rowCount else {
            throw OrdinaryCOutputAudit.Failure.invalid("literal retained source/call/text witness mismatch")
        }
        for row in callRows {
            let saved = full.capture.lifted_rows[row]
            guard saved.index == row, saved.effect_ordinal == 0,
                  saved.source_address == RegionalSchema2Context.hex(full.rows[row].address),
                  case .call = full.original.instructions[row].operation else {
                throw OrdinaryCOutputAudit.Failure.invalid("full input call source coordinate changed")
            }
        }
        let cfg = CFGBuilder.buildCFG(instructions: full.original.instructions)
        guard cfg.entryIndex == 0, cfg.loopHeaders == loopHeaders, cfg.backEdges == backEdges,
              cfg.irreducibleBlocks.isEmpty, !cfg.hasUnresolvedTargets else {
            throw OrdinaryCOutputAudit.Failure.invalid("full input call topology mismatch")
        }
        return .init(start: start, baselineText: full.baselineText, callRows: callRows,
            rows: full.rows, input: full.input, function: full.original, document: full.document)
    }

    /// Validate the complete capture first, then remove exactly one independent
    /// callee declaration. Reversibility proves all other context and index-ledger
    /// entries survive; this input is deliberately NOT the original full capture.
    private static func makeOpaqueUpsampler(name: String, start: UInt64) throws -> RegionalSchema2BuiltFixture {
        guard (name == "_jinit_upsampler" && start == 0x3ae18)
                || (name == "_j12init_upsampler" && start == 0x3b774) else {
            throw OrdinaryCOutputAudit.Failure.invalid("opaque derivative requires an approved upsampler")
        }
        let captures = try RegionalSchema2Fixture.load(resource: RegionalSchema2Bindings39A.resourceURL,
                                                       binding: RegionalSchema2Bindings39A.binding)
        let matches = captures.filter { $0.function == name && $0.start == RegionalSchema2Context.hex(start) }
        guard matches.count == 1, let capture = matches.first else {
            throw OrdinaryCOutputAudit.Failure.invalid("opaque derivative requires one exact captured target")
        }
        var input = try capture.restoredInput()
        let originalInput = input
        try RegionalSchema2BuiltFixture.requireCompleteInputAuthority(input, capture: capture)
        let originalCount = input.authoredCallSignaturesByTarget.count
        guard let declaration = input.authoredCallSignaturesByTarget["_jround_up"],
              declaration.returnType == "int64_t", declaration.variadicState == .fixed,
              case let .authoritative(parameters) = declaration.parameterList,
              parameters.map(\.name) == ["a", "b"],
              parameters.map(\.type) == ["int64_t", "int64_t"],
              input.directCallVoidResultTargets["_jround_up"] == nil else {
            throw OrdinaryCOutputAudit.Failure.invalid("unexpected captured jround_up declaration")
        }
        input.authoredCallSignaturesByTarget.removeValue(forKey: "_jround_up")
        guard input.authoredCallSignaturesByTarget["_jround_up"] == nil,
              input.authoredCallSignaturesByTarget.count == originalCount - 1 else {
            throw OrdinaryCOutputAudit.Failure.invalid("opaque derivative must remove exactly one callee")
        }
        var restored = input
        restored.authoredCallSignaturesByTarget["_jround_up"] = declaration
        guard restored == originalInput else {
            throw OrdinaryCOutputAudit.Failure.invalid("opaque derivative changed another input field")
        }
        try RegionalSchema2BuiltFixture.requireCompleteInputAuthority(restored, capture: capture)
        let printer = PseudocodePrinter(options: .default)
        let function = printer.buildFunction(functionName: input.functionName, startAddress: input.startAddress,
            jumpTables: input.jumpTables, objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
            signatureOverrides: input.signatureOverrides, authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            directCallVoidResultTargets: input.directCallVoidResultTargets, slotCallContracts: input.slotCallContracts,
            callerReturnWidth: input.callerReturnWidth, callerReturnType: input.callerReturnType,
            types: input.types, instructions: input.instructions)
        guard function.instructions.count == input.instructions.count,
              zip(function.instructions, input.instructions).allSatisfy({ pair in
                  let (instruction, row) = pair
                  return instruction.source.address == row.address && instruction.source.byteText == row.bytes &&
                      instruction.source.mnemonic == row.mnemonic && instruction.source.operands == row.operands &&
                      instruction.source.comment == row.comment && instruction.source.structuredOperands == row.structuredOperands
              }),
              CFGBuilder.buildCFG(instructions: function.instructions).blocks.map({
                  NativeScalarFixture.FrozenBlock($0, instructions: function.instructions)
              }) == capture.cfg_blocks else {
            throw OrdinaryCOutputAudit.Failure.invalid("opaque derivative changed captured source identity or CFG")
        }
        let document = printer.print(function: function, types: input.types,
            nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
        return .init(capture: capture, input: input, original: function, document: document)
    }

    /// Preserved historical construction only; no captured-call caller uses it.
    private static func make(name: String, start: UInt64, captures: [RecordedRow], rowCount: Int,
                             blockCount: Int, functionWitness: UInt64, blocksWitness: UInt64,
                             signature: FunctionSignatureOverride?, baselineText: String,
                             callRows: [Int], loopHeaders: Set<Int>, backEdges: Set<CFGEdge>) throws -> Self {
        XCTAssertEqual(captures.count, rowCount)
        let bytes = try captures.flatMap { record in
            try record.bytes.split(separator: " ").map { try XCTUnwrap(UInt8($0, radix: 16)) }
        }
        XCTAssertEqual(bytes.count, rowCount * 4)
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: start)
        guard decoded.count == captures.count else { throw OrdinaryCOutputAudit.Failure.invalid("incomplete original native decode") }
        let rows = try zip(captures, decoded).enumerated().map { index, pair in
            let (saved, instruction) = pair
            XCTAssertEqual(saved.address, start + UInt64(index * 4))
            XCTAssertEqual(instruction.address, saved.address)
            XCTAssertEqual(instruction.byteText, saved.bytes)
            XCTAssertEqual(instruction.mnemonic, saved.mnemonic)
            XCTAssertEqual(instruction.comment, saved.comment)
            let envelope = try XCTUnwrap(instruction.structuredOperands)
            XCTAssertEqual(RegionalCallFixture.fingerprint(instruction.structuredOperands), saved.operandWitness)
            if saved.mnemonic == "bl" {
                XCTAssertTrue(saved.operands.hasPrefix("_"))
                XCTAssertEqual(envelope.coverage, .complete)
                XCTAssertEqual(envelope.opcodeClass, "bl")
            } else { XCTAssertEqual(instruction.operands, saved.operands) }
            XCTAssertEqual(try JSONDecoder().decode(InstructionOperands.self, from: JSONEncoder().encode(envelope)), envelope)
            return InstructionRow(address: saved.address, bytes: saved.bytes, mnemonic: saved.mnemonic,
                operands: saved.operands, hasBreakpoint: false, comment: saved.comment, structuredOperands: envelope)
        }
        // This existing helper preprocesses the exact retained baseline header catalog;
        // it does not build, lift, print, or run a prior successful test.
        let types = try RegionalCallFixture.loadTypes()
        let summary = FunctionSummary(id: UUID(), name: name, startAddress: start,
            endAddress: start + UInt64(bytes.count), confidence: 1)
        let snapshot = WorkspaceSnapshot(binaries: [], functions: [summary], instructions: rows,
            xrefs: [], hexBytes: Data(), importedPrototypes: signature.map {
                [ImageAddress(slot: .primary, address: start): $0]
            } ?? [:], typeDefinitions: types)
        let input = snapshot.pseudocodeRenderInput(selectedAddress: start, in: .primary)
        XCTAssertEqual(input.instructions, rows)
        XCTAssertEqual(input.signatureOverrides[start], signature)
        XCTAssertNil(input.callerReturnWidth)
        XCTAssertTrue(input.nameOverrides.isEmpty)
        XCTAssertTrue(input.registerNameOverrides.isEmpty)
        XCTAssertTrue(input.stackLocalOverrides.isEmpty)
        XCTAssertTrue(input.jumpTables.isEmpty)
        XCTAssertTrue(input.objcSelectors.isEmpty)
        XCTAssertTrue(input.constantStrings.isEmpty)
        XCTAssertTrue(input.resolvedIndirectCalls.isEmpty)
        let printer = PseudocodePrinter(options: .default)
        let function = printer.buildFunction(functionName: input.functionName, startAddress: input.startAddress,
            jumpTables: input.jumpTables, objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
            signatureOverrides: input.signatureOverrides, authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            callerReturnWidth: input.callerReturnWidth, types: input.types, instructions: input.instructions)
        XCTAssertEqual(function.instructions.count, rowCount)
        XCTAssertEqual(RegionalCallFixture.fingerprint(function), functionWitness, "complete original context/model witness")
        guard function.instructions.count == rowCount else { throw OrdinaryCOutputAudit.Failure.invalid("incomplete original lift") }
        for (index, instruction) in function.instructions.enumerated() {
            XCTAssertEqual(RegionalCallFixture.fingerprint(instruction), captures[index].instructionWitness)
            XCTAssertEqual(instruction.source.structuredOperands, rows[index].structuredOperands)
        }
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        XCTAssertEqual(cfg.blocks.count, blockCount)
        XCTAssertEqual(RegionalCallFixture.fingerprint(cfg.blocks), blocksWitness)
        XCTAssertEqual(cfg.entryIndex, 0)
        XCTAssertEqual(cfg.loopHeaders, loopHeaders)
        XCTAssertEqual(cfg.backEdges, backEdges)
        XCTAssertTrue(cfg.irreducibleBlocks.isEmpty)
        XCTAssertFalse(cfg.hasUnresolvedTargets)
        let document = printer.print(function: function, types: input.types, nameOverrides: input.nameOverrides,
            registerNameOverrides: input.registerNameOverrides, stackLocalOverrides: input.stackLocalOverrides,
            resolvedIndirectCalls: input.resolvedIndirectCalls)
        return .init(start: start, baselineText: baselineText, callRows: callRows,
                     rows: rows, input: input, function: function, document: document)
    }
}

/// Full typed output remains the product obligation. The explicitly opaque
/// derivative is used only by the immutable original opaque semantic oracle.
/// Construction proves the exact one-call text/ABI bridge before either role is
/// available; it never strips arbitrary casts or signature comments.
struct OrdinaryCUpsamplerFixturePair {
    let full: OrdinaryCRecordedCallFixture
    let opaque: OrdinaryCRecordedCallFixture
    let fullAudit: OrdinaryCOutputAudit.Report
    let roundRow: Int
    let typedCallPayload: String

    private init(full: OrdinaryCRecordedCallFixture, opaque: OrdinaryCRecordedCallFixture,
                 fullAudit: OrdinaryCOutputAudit.Report, roundRow: Int, typedCallPayload: String) {
        self.full = full; self.opaque = opaque; self.fullAudit = fullAudit
        self.roundRow = roundRow; self.typedCallPayload = typedCallPayload
    }

    static func make(_ seed: RegionalCallSeed) throws -> Self {
        let full = try OrdinaryCRecordedCallFixture.upsampler(seed)
        let opaque = try OrdinaryCRecordedCallFixture.opaqueUpsampler(seed)
        return try certify(full: full, opaque: opaque, seed: seed)
    }

    /// Changed-input controls can validate or reject, but cannot mint a privileged
    /// pair from caller-supplied models. Only make(seed) constructs both fixtures.
    static func validateBridge(full: OrdinaryCRecordedCallFixture, opaque: OrdinaryCRecordedCallFixture,
                               seed: RegionalCallSeed) throws {
        _ = try certify(full: full, opaque: opaque, seed: seed)
    }

    private static func certify(full: OrdinaryCRecordedCallFixture, opaque: OrdinaryCRecordedCallFixture,
                        seed: RegionalCallSeed) throws -> Self {
        typealias C = OrdinaryC
        func reject(_ message: String) -> C.Failure { .invalidContract("TYPED_UPSAMPLER_BRIDGE: \(message)") }
        guard seed == .jinit || seed == .j12init,
              full.start == seed.start, opaque.start == full.start,
              full.rows == opaque.rows, full.rows.count == seed.rowCount,
              full.baselineText == seed.baselineText, full.baselineText == opaque.baselineText,
              full.callRows == seed.callRows, full.callRows == opaque.callRows,
              full.function.ssaEnabled == opaque.function.ssaEnabled,
              full.function.parameters == opaque.function.parameters,
              full.function.returnType == opaque.function.returnType,
              full.function.returnValue == opaque.function.returnValue,
              full.function.instructions.map(\.source) == opaque.function.instructions.map(\.source),
              CFGBuilder.buildCFG(instructions: full.function.instructions)
                == CFGBuilder.buildCFG(instructions: opaque.function.instructions) else {
            throw reject("full/opaque source, own declaration or CFG differs")
        }
        let captures = try RegionalSchema2Fixture.load(resource: RegionalSchema2Bindings39A.resourceURL,
            binding: RegionalSchema2Bindings39A.binding)
        let matches = captures.filter { $0.function == seed.name && $0.start == RegionalSchema2Context.hex(seed.start) }
        guard matches.count == 1, let capture = matches.first,
              full.input.instructions == full.rows,
              full.function.instructions.count == full.rows.count,
              zip(full.function.instructions, full.rows).allSatisfy({ instruction, source in
                  instruction.source.address == source.address && instruction.source.byteText == source.bytes
                    && instruction.source.mnemonic == source.mnemonic && instruction.source.operands == source.operands
                    && instruction.source.comment == source.comment
                    && instruction.source.structuredOperands == source.structuredOperands
              }) else { throw reject("complete captured source correspondence changed") }
        try RegionalSchema2BuiltFixture.requireCompleteInputAuthority(full.input, capture: capture)
        var restored = opaque.input
        guard let declaration = full.input.authoredCallSignaturesByTarget["_jround_up"],
              restored.authoredCallSignaturesByTarget["_jround_up"] == nil else {
            throw reject("missing exact one-callee declaration delta")
        }
        restored.authoredCallSignaturesByTarget["_jround_up"] = declaration
        guard restored == full.input else { throw reject("another input field changed") }
        let row = seed == .jinit ? 187 : 131
        guard full.function.instructions.indices.contains(row), row >= 2,
              full.rows[row].mnemonic == "bl", full.rows[row].operands == "_jround_up",
              case let .call(typed, typedResult) = full.function.instructions[row].operation,
              case let .call(untyped, opaqueResult) = opaque.function.instructions[row].operation,
              typed.target == "_jround_up", untyped.target == typed.target,
              let signature = typed.knownSignature,
              signature.source == "authored-declaration", signature.target == typed.target,
              !signature.isVariadic, signature.format == nil, signature.returnType == "int64_t",
              signature.parameters.map(\.index) == [0, 1],
              signature.parameters.map(\.register) == ["x0", "x1"],
              signature.parameters.map(\.type) == ["int64_t", "int64_t"],
              signature.parameters.map(\.name) == ["a", "b"],
              untyped.knownSignature == nil,
              opaque.function.callSignatures.isEmpty, full.function.callSignatures == [signature],
              typed.typedIndirectSignature == nil, untyped.typedIndirectSignature == nil,
              typed.typedIndirectCalleeType == nil, untyped.typedIndirectCalleeType == nil,
              typed.unknownArgumentCount == nil,
              typed.arguments.observationScope == .none,
              untyped.arguments.observationScope.canonicalGPRIndicesForAudit == Array(0..<8),
              untyped.arguments.observationScope.canonicalScalarSIMDIndicesForAudit.isEmpty,
              untyped.arguments.observationScope.canonicalCallStackRangesForAudit.isEmpty,
              typed.richArguments == nil, untyped.richArguments == nil,
              typed.indirectResultPointer == nil, untyped.indirectResultPointer == nil,
              typed.tailCountEvidence == nil, untyped.tailCountEvidence == nil,
              typed.controlInputs == untyped.controlInputs,
              typed.controlInputs.canonicalControlInputsForAudit.isEmpty,
              let result = typedResult, result == opaqueResult,
              case let .register(resultRegister, resultVersion) = result,
              resultRegister == "x0", resultVersion > 0 else {
            throw reject("round call target, signature or result changed")
        }
        let typedArguments = typed.arguments.canonicalPhysicalEntriesForAudit
        let opaqueArguments = untyped.arguments.canonicalPhysicalEntriesForAudit
        guard typedArguments.count == 2, opaqueArguments.count == 2,
              typedArguments[0].location == .gpr(index: 0, carrierWidth: 64),
              typedArguments[1].location == .gpr(index: 1, carrierWidth: 64),
              opaqueArguments[0].location == .gpr(index: 0, carrierWidth: 32),
              opaqueArguments[1].location == .gpr(index: 1, carrierWidth: 64),
              typedArguments.map(\.role) == [.fixed(sourcePosition: 0), .fixed(sourcePosition: 1)],
              opaqueArguments.allSatisfy({ $0.role == .unknown && $0.selectorEvidence == nil }),
              typedArguments.allSatisfy({ $0.selectorEvidence == nil }),
              case let .unary("(uint64_t)", .unary("(uint32_t)", narrow)) = typedArguments[0].value,
              narrow == opaqueArguments[0].value,
              typedArguments[1].value == opaqueArguments[1].value,
              case let .register(narrowRegister, narrowVersion) = narrow,
              narrowRegister == "w0", narrowVersion > 0,
              case let .register(secondRegister, secondVersion) = typedArguments[1].value,
              secondRegister == "x1", secondVersion > 0,
              full.rows[row - 2].mnemonic == "ldr", full.rows[row - 2].operands == "w0, [x19, #0x88]",
              full.rows[row - 1].mnemonic == "ldrsw", full.rows[row - 1].operands == "x1, [x19, #0x198]",
              case let .load(firstDefinition, _) = full.function.instructions[row - 2].operation,
              firstDefinition == narrow,
              case let .load(secondDefinition, _) = full.function.instructions[row - 1].operation,
              secondDefinition == typedArguments[1].value else {
            throw reject("round call changed a source register, view or local definition")
        }
        guard full.function.phis == opaque.function.phis,
              full.function.instructions.count == opaque.function.instructions.count,
              full.function.instructions.indices.allSatisfy({
                  $0 == row || full.function.instructions[$0] == opaque.function.instructions[$0]
              }) else { throw reject("another IR row or phi changed") }
        let literalAliases: Set<MacIRNameBindingTarget> = [
            .register(name: resultRegister, version: resultVersion),
            .register(name: narrowRegister, version: narrowVersion),
            .register(name: secondRegister, version: secondVersion)
        ]
        guard full.input.nameOverrides["_jround_up"] == nil,
              full.input.registerNameOverrides.isEmpty,
              !full.function.nameBindings.contains(where: { literalAliases.contains($0.target) }),
              !opaque.function.nameBindings.contains(where: { literalAliases.contains($0.target) }),
              typed.unprovenArgumentRegisters.isEmpty, untyped.unprovenArgumentRegisters.isEmpty,
              typed.machineRenderArguments == nil, untyped.machineRenderArguments == nil,
              untyped.unknownRenderValues() == [narrow, typedArguments[1].value],
              typed.denseFixedRenderValues() == typedArguments.map(\.value) else {
            throw reject("call aliases, arity or presentation changed")
        }
        let address = full.rows[row].address
        let oldPayload = "\(result) = _jround_up(\(narrow), \(typedArguments[1].value)); // call"
        let newPayload = "\(result) = _jround_up((uint64_t)((uint32_t)(\(narrow))), \(typedArguments[1].value)); // call; signature \(signature.declarationText)"
        let indices = opaque.document.lines.indices.filter {
            opaque.document.lines[$0].sourceAddress == address
                && opaque.document.lines[$0].text.trimmingCharacters(in: .whitespaces) == oldPayload
        }
        guard indices.count == 1, let callLine = indices.first,
              full.document.lines.count == opaque.document.lines.count,
              full.document.regionTree == opaque.document.regionTree,
              full.document.structureFallback == opaque.document.structureFallback else {
            throw reject("call multiplicity, line count or loop structure differs")
        }
        for index in full.document.lines.indices {
            let actual = full.document.lines[index], original = opaque.document.lines[index]
            guard actual.lineNumber == original.lineNumber, actual.kind == original.kind,
                  actual.source == original.source, actual.refusal == original.refusal else {
                throw reject("line provenance differs at \(index + 1)")
            }
            if index == callLine {
                let indentation = String(original.text.prefix { $0 == " " || $0 == "\t" })
                guard actual.text == indentation + newPayload else {
                    throw reject("call line differs beyond the one proved cast and signature suffix")
                }
            } else if actual.text != original.text {
                throw reject("non-call line differs at \(index + 1)")
            }
        }
        let audit = try OrdinaryCOutputAudit.analyze(document: full.document,
            function: full.function, baselineText: full.baselineText)
        guard audit.errors.isEmpty,
              !audit.tokens.contains(where: { $0.text.hasPrefix("rgn_regional_") }),
              audit.rawEquivalentTotal < seed.baselineRaw,
              audit.gotoEquivalentTotal < seed.baselineTotal,
              !audit.loops.isEmpty else {
            throw C.Failure.unsupportedSyntax("TYPED_UPSAMPLER_PRODUCT_REPAIR_REQUIRED: \(audit.errors)")
        }
        return Self(full: full, opaque: opaque, fullAudit: audit, roundRow: row, typedCallPayload: newPayload)
    }

    /// Not exposed as a semantic-machine contract. It permits the row-ownership
    /// parser to inspect the ACTUAL typed document after the exact bridge above.
    func requireFullTypedRowOwnership() throws {
        try RegionalCallRowOwnership.requirePositive(typedUpsampler: self)
    }
}
