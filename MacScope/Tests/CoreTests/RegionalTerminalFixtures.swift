import Foundation
import XCTest
@testable import MacScope

/// Complete real capture, including original inferred/authored render context.
/// Source: regional-multicall-v1-new-input-diagnostic/metadata.json.document-metadata.json.
/// Retained capture SHA-256: 300e06bb2982b27d10feac6a52b60e4e318f8d75cb180c2334ffa800a40dff7f.
/// Retained canonical baseline dump SHA-256: 6218b13be22165a884ce6973efede35b36c95085106802c48a613262cedef5cc.
/// Baselines below are the existing retained earlier captures, not the baseline output.
/// Per-row FNV witnesses include every original operand field and IR sidecar;
/// normalization matches the existing captured-fixture helper, not the product.
enum RegionalTerminalSeed {
    case finishDecompress, skipVariable
    var name: String { self == .finishDecompress ? "_jpeg_finish_decompress" : "_skip_variable" }
    var start: UInt64 { self == .finishDecompress ? 0x2177c : 0x33418 }
    var rowCount: Int { self == .finishDecompress ? 56 : 58 }
    var blockCount: Int { self == .finishDecompress ? 14 : 10 }
    var prefixEnd: Int { self == .finishDecompress ? 3 : 6 }
    var suffixStart: Int { self == .finishDecompress ? 53 : 52 }
    var callRows: [Int] { self == .finishDecompress ? [20, 31, 35, 43, 49, 51] : [12, 21, 40, 48] }
    var signature: FunctionSignatureOverride? {
        guard self == .finishDecompress else { return nil }
        let row = ArgOverride(rowToken: "compat-e86ab5708c5cb867bfc6396a", name: "cinfo",
                              type: "struct jpeg_decompress_struct *", provenance: .user)
        return FunctionSignatureOverride(returnType: "int32_t", parameterList: .authoritative([row]),
                                         variadicState: .fixed, noReturnState: .unspecified)
    }
    struct CapturedRow {
        let address: UInt64
        let bytes: String
        let mnemonic: String
        let operands: String
        let comment: String?
        let operandWitness: UInt64
        let instructionWitness: UInt64
    }

    func capturedRows() throws -> [CapturedRow] {
        try sourceRecord.split(separator: "\n").map { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields.count, 7, "invalid retained row, not a decoder refusal")
            guard fields.count == 7 else { throw RegionalTerminalFixture.Failure.invalidCapture }
            return CapturedRow(address: try XCTUnwrap(UInt64(fields[0], radix: 16)),
                               bytes: fields[1], mnemonic: fields[2], operands: fields[3],
                               comment: fields[4].isEmpty ? nil : fields[4],
                               operandWitness: try XCTUnwrap(UInt64(fields[5], radix: 16)),
                               instructionWitness: try XCTUnwrap(UInt64(fields[6], radix: 16)))
        }
    }
}

extension RegionalTerminalSeed {
    var returnRow: Int {
        let matches = sourceRecord.split(separator: "\n").enumerated().compactMap { index, line in
            line.split(separator: "|", omittingEmptySubsequences: false)[2] == "ret" ? index : nil
        }
        XCTAssertEqual(matches.count, 1, "captured decoded input must contain exactly one ret row; found \(matches)")
        return matches.first ?? -1
    }

    var protectedRows: Set<Int> {
        let named = self == .finishDecompress
            ? [43, 44, 45, 52, 53, 54]
            : Array(0..<prefixEnd) + [12, 13] + Array(37...57)
        return Set(callRows + [returnRow] + named)
    }

    var namedSuccessorCounts: [Int: Int] {
        if self == .finishDecompress { return [44: 2, 55: 0] }
        // Captured paths end at CBZ 13, B.LO 43, B 49, the fallthrough
        // constant at 50, and RET 57. Counts belong to each containing block.
        var counts = Dictionary(uniqueKeysWithValues:
            (Array(0..<prefixEnd) + [12, 13] + Array(37...43)).map { ($0, 2) })
        for row in 44...50 { counts[row] = 1 }
        for row in 51...57 { counts[row] = 0 }
        return counts
    }
}

struct RegionalTerminalFixture {
    enum Failure: Error { case invalidCapture, missingHeaders(String), preprocessingFailed(Int32) }
    let seed: RegionalTerminalSeed
    let rows: [InstructionRow]
    let function: MacIRFunction
    let document: PseudocodeDocument
    /// Same-context legacy structure() path. Frozen actual DEFAULT text defines goto credit.
    let legacy: PseudocodeDocument
    let types: [TypeDefinition]
    /// Complete schema2 input for accepted captures; historical negatives are nil.
    let capturedInput: PseudocodeRenderInput?

    struct CallPayloadComparison {
        let row: Int
        let address: UInt64
        let baseline: String
        let after: [String]
        var changedBeyondIndentation: Bool { after != [baseline] }
    }

    /// Frozen call-contract comparison. Only enclosing indentation is normalized;
    /// the existing target, inputs, result assignment and comment are untouched.
    var callPayloads: [CallPayloadComparison] {
        let baseline = seed.baselineText.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { $0.hasSuffix("// call") }
        precondition(baseline.count == seed.callRows.count)
        return seed.callRows.enumerated().map { ordinal, row in
            let address = rows[row].address
            let after = document.lines(sourcedAt: address).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }.filter { $0.hasSuffix("// call") }
            return CallPayloadComparison(row: row, address: address,
                                         baseline: baseline[ordinal], after: after)
        }
    }

    static func loadTypes() throws -> [TypeDefinition] { try RegionalCallFixture.loadTypes() }
    static func fingerprint<T>(_ value: T) -> UInt64 { RegionalCallFixture.fingerprint(value) }

    static func make(_ seed: RegionalTerminalSeed, types suppliedTypes: [TypeDefinition]? = nil) throws -> Self {
        if seed == .skipVariable {
            let full = try OrdinaryCRecordedCallFixture.skipVariable()
            let input = full.input, function = full.function, actual = full.document
            guard suppliedTypes == nil || suppliedTypes == input.types else {
                throw Failure.invalidCapture
            }
            XCTAssertEqual(actual.text, DocumentExportService().pseudocodeText(for: input, options: .default),
                           "the real default export must exercise the same full-context production route")
            RenderProperties.assertCallShape(function, callRows: seed.callRows, decoded: full.rows,
                baselineCallLines: seed.baselineText.split(separator: "\n").map(String.init).filter { $0.hasSuffix("// call") })
            RenderProperties.assertReturnShape(function, returnRow: seed.returnRow)
            RenderProperties.assertSuccessorCounts(CFGBuilder.buildCFG(instructions: function.instructions),
                rows: seed.namedSuccessorCounts)
            var legacyOptions = DecompilerOptions.default
            legacyOptions.structureControlFlow = false
            let legacy = PseudocodePrinter(options: legacyOptions).print(function: function, types: input.types,
                nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
                stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
            return Self(seed: seed, rows: full.rows, function: function, document: actual,
                legacy: legacy, types: input.types, capturedInput: input)
        }
        return try makeHistorical(seed, types: suppliedTypes)
    }

    /// Outside current capture coverage: deliberately historical construction, never relabelled.
    private static func makeHistorical(_ seed: RegionalTerminalSeed, types suppliedTypes: [TypeDefinition]?) throws -> Self {
        let captures = try seed.capturedRows()
        XCTAssertEqual(captures.count, seed.rowCount)
        guard captures.count == seed.rowCount else { throw Failure.invalidCapture }
        let bytes = try captures.flatMap { captured in
            try captured.bytes.split(separator: " ").map { try XCTUnwrap(UInt8($0, radix: 16)) }
        }
        XCTAssertEqual(bytes.count, seed.rowCount * 4)
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: seed.start)
        XCTAssertEqual(decoded.count, captures.count)
        guard decoded.count == captures.count else { throw Failure.invalidCapture }
        let rows = try zip(captures, decoded).enumerated().map { index, pair in
            let (captured, instruction) = pair
            XCTAssertEqual(captured.address, seed.start + UInt64(index * 4))
            XCTAssertEqual(instruction.address, captured.address)
            XCTAssertEqual(instruction.byteText, captured.bytes)
            XCTAssertEqual(instruction.mnemonic, captured.mnemonic)
            XCTAssertEqual(instruction.comment, captured.comment)
            let envelope = try XCTUnwrap(instruction.structuredOperands)
            XCTAssertEqual(fingerprint(instruction.structuredOperands), captured.operandWitness,
                           "complete independently retained operand envelope at row \(index)")
            if captured.mnemonic != "bl" {
                XCTAssertEqual(instruction.operands, captured.operands)
            } else {
                // Real BL text has its original symbolic opaque target; the
                // decoded envelope independently retains numeric PC authority.
                // This asserts no new symbol-address resolution theorem.
                XCTAssertTrue(captured.operands.hasPrefix("_"))
                XCTAssertEqual(envelope.coverage, .complete)
                XCTAssertEqual(envelope.opcodeClass, "bl")
            }
            XCTAssertEqual(try JSONDecoder().decode(InstructionOperands.self,
                from: JSONEncoder().encode(envelope)), envelope)
            return InstructionRow(address: captured.address, bytes: captured.bytes,
                mnemonic: captured.mnemonic, operands: captured.operands, hasBreakpoint: false,
                comment: captured.comment, structuredOperands: envelope)
        }
        let types = try suppliedTypes ?? loadTypes()
        let signature = seed.signature
        let summary = FunctionSummary(id: UUID(), name: seed.name, startAddress: seed.start,
            endAddress: seed.start + UInt64(bytes.count), confidence: 1)
        let snapshot = WorkspaceSnapshot(binaries: [], functions: [summary], instructions: rows,
            xrefs: [], hexBytes: Data(), importedPrototypes: signature.map {
                [ImageAddress(slot: .primary, address: seed.start): $0]
            } ?? [:], typeDefinitions: types)
        let input = snapshot.pseudocodeRenderInput(selectedAddress: seed.start, in: .primary)
        XCTAssertEqual(input.instructions, rows)
        XCTAssertEqual(input.signatureOverrides[seed.start], signature)
        XCTAssertNil(input.callerReturnWidth)
        XCTAssertTrue(input.nameOverrides.isEmpty)
        XCTAssertTrue(input.registerNameOverrides.isEmpty)
        XCTAssertTrue(input.stackLocalOverrides.isEmpty)
        XCTAssertTrue(input.jumpTables.isEmpty)
        XCTAssertTrue(input.objcSelectors.isEmpty)
        XCTAssertTrue(input.constantStrings.isEmpty)
        XCTAssertTrue(input.resolvedIndirectCalls.isEmpty)
        let printer = PseudocodePrinter(options: .default)
        let function = printer.buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            callerReturnWidth: input.callerReturnWidth, types: input.types,
            instructions: input.instructions)
        XCTAssertEqual(function.instructions.count, seed.rowCount)
        guard function.instructions.count == seed.rowCount else { throw Failure.invalidCapture }
        for (index, instruction) in function.instructions.enumerated() {
            XCTAssertEqual(instruction.source.structuredOperands, rows[index].structuredOperands)
        }
        RenderProperties.assertCallShape(function, callRows: seed.callRows, decoded: rows,
            baselineCallLines: seed.baselineText.split(separator: "\n").map(String.init).filter { $0.hasSuffix("// call") })
        RenderProperties.assertReturnShape(function, returnRow: seed.returnRow)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        RenderProperties.assertSuccessorCounts(cfg, rows: seed.namedSuccessorCounts)
        XCTAssertEqual(cfg.blocks.count, seed.blockCount)
        XCTAssertEqual(cfg.entryIndex, 0)
        XCTAssertEqual(cfg.loopHeaders, seed == .finishDecompress ? [9] : [])
        XCTAssertEqual(cfg.backEdges, seed == .finishDecompress ? [CFGEdge(10, 9)] : [])
        XCTAssertTrue(cfg.irreducibleBlocks.isEmpty)
        XCTAssertFalse(cfg.hasUnresolvedTargets)
        let actual = printer.print(function: function, types: input.types,
            nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
        XCTAssertEqual(actual.text, DocumentExportService().pseudocodeText(for: input, options: .default),
                       "the real default export must exercise the same full-context production route")
        var legacyOptions = DecompilerOptions.default
        legacyOptions.structureControlFlow = false
        let legacy = PseudocodePrinter(options: legacyOptions).print(function: function, types: input.types,
            nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
        return Self(seed: seed, rows: rows, function: function, document: actual, legacy: legacy, types: types, capturedInput: nil)
    }

}

private enum FinishDecompressTerminalCapturedData {
    static let functionWitness: UInt64 = 0x2dcea2d6438655a5
    static let blocksWitness: UInt64 = 0x30884c2190976ed1
    // Original address, bytes, mnemonic, operands, comment, operand and IR witnesses.
    static let sourceRecord = """
    2177c|f4 4f be a9|stp|x20, x19, [sp, #-0x20]!||a6b440d6c3bec2cb|33cb6b72f8b5c5bc
    21780|fd 7b 01 a9|stp|x29, x30, [sp, #0x10]||681e914f40b8561f|8412476ee1de0769
    21784|fd 43 00 91|add|x29, sp, #0x10||1a479afaad9a52ea|7fbfae9e949b28b5
    21788|f3 03 00 aa|mov|x19, x0||b5a7cfada79f5022|2000a9bbac6ee39e
    2178c|08 24 40 b9|ldr|w8, [x0, #0x24]||57b01099b3f27b79|f5a21b55d3a65e85
    21790|09 35 03 51|sub|w9, w8, #0xcd||6b88a5c2df7cc3dd|2659c8ced12067fe
    21794|3f 05 00 71|cmp|w9, #1||d8151c865efbbd7d|c349cd157ef54396
    21798|68 00 00 54|b.hi|0x00000000000217a4||85eb40d7f35d876f|7c4a175d4d231cea
    2179c|69 5a 40 b9|ldr|w9, [x19, #0x58]||914ee70d18271663|859c88dc8f4e8fee
    217a0|a9 01 00 34|cbz|w9, 0x00000000000217d4||6f2fcb156cecc479|411034f4ebfdf710
    217a4|1f 49 03 71|cmp|w8, #0xd2||0cda92bd8c31fe8c|62cbf65dc1a1b4d0
    217a8|60 03 00 54|b.eq|0x0000000000021814||2628765080bc3353|e89c80f6c404178f
    217ac|1f 3d 03 71|cmp|w8, #0xcf||5f3d5c4c93fd7874|91fc43dc5e277491
    217b0|e0 02 00 54|b.eq|0x000000000002180c||30c388b885da3d02|c361469f12c3c3e6
    217b4|69 02 40 f9|ldr|x9, [x19]||c03128173a42ef6f|eaf5db839af7f3d6
    217b8|aa 02 80 52|mov|w10, #0x15||0647f080aca638c5|bfd7e827a0cd6c69
    217bc|2a 21 05 29|stp|w10, w8, [x9, #0x28]||d9c2154fabee8e04|72096062735bd021
    217c0|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|6a0f2a578b82b8b5
    217c4|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|f96cff27c4a0d679
    217c8|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|a4361c6d8df1d2ca
    217cc|00 01 3f d6|blr|x8||d4648694c208727c|2cf04e902fa2c605
    217d0|11 00 00 14|b|0x0000000000021814||cbd8c67a686ca0a3|c05afb672afc95d1
    217d4|68 aa 40 b9|ldr|w8, [x19, #0xa8]||a639d469e3fb9fef|4fe529752fded825
    217d8|69 8e 40 b9|ldr|w9, [x19, #0x8c]||93ae76cd8e69bd98|5b6a875490ac10dd
    217dc|1f 01 09 6b|cmp|w8, w9||c155333d3e6b6dae|2ba160776d888d3e
    217e0|e2 00 00 54|b.hs|0x00000000000217fc||733137fd3548295b|a3d803494df45ec6
    217e4|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|fb51414444f42310
    217e8|a9 08 80 52|mov|w9, #0x45||c05ade98b1fe336f|4cc73b813e099a29
    217ec|09 29 00 b9|str|w9, [x8, #0x28]||bb4b144c535b7823|4b7b1d9b17fddd94
    217f0|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|a9c4bfbd81bcb61b
    217f4|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|87b43a9ab61213b9
    217f8|00 01 3f d6|blr|x8||d4648694c208727c|59db3f957075ab88
    217fc|68 1e 41 f9|ldr|x8, [x19, #0x238]||53423a7c7ebc02a1|bb0bfa83778ac2f4
    21800|08 05 40 f9|ldr|x8, [x8, #8]||2f82d4e6a9dff056|84d5a1c7b8b5bb58
    21804|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|eb54e8e699364a29
    21808|00 01 3f d6|blr|x8||d4648694c208727c|d5e000c968f2e300
    2180c|48 1a 80 52|mov|w8, #0xd2||b99b1c969386e6de|f34fd2e143111819
    21810|68 26 00 b9|str|w8, [x19, #0x24]||2c13a127c78d6311|b7876a0d45b30354
    21814|68 2e 41 f9|ldr|x8, [x19, #0x258]||9f7571a3b62c5160|4ec28365b1088fb2
    21818|09 25 40 b9|ldr|w9, [x8, #0x24]||45bb96feb4d5134c|13bdbfcdb6e1e19d
    2181c|c9 00 00 35|cbnz|w9, 0x0000000000021834||e07ab3c29a48432b|d1a4a7ee3b399d8c
    21820|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|2313f08ce1ba1fb7
    21824|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|3e57a87a82737e68
    21828|00 01 3f d6|blr|x8||d4648694c208727c|ad80622d02bfca37
    2182c|40 ff ff 35|cbnz|w0, 0x0000000000021814||1bc776ca57e5fee5|78e102d8b49b2d63
    21830|08 00 00 14|b|0x0000000000021850||424accd0d45b8c61|cd75d8bb3e00c27c
    21834|68 16 40 f9|ldr|x8, [x19, #0x28]||5d99e2815ab5fa48|d3ba68164c270dda
    21838|08 19 40 f9|ldr|x8, [x8, #0x30]||3a220e1849082014|3536e09619115e4c
    2183c|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|2a2d1fd5552d7c1c
    21840|00 01 3f d6|blr|x8||d4648694c208727c|ff59a7d3c6547eae
    21844|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|d8c77985f06689fc
    21848|3a e7 ff 97|bl|_jpeg_abort||36727397b00f7689|51b305e5b897819d
    2184c|20 00 80 52|mov|w0, #1||3cbdcea56d06b78a|a0d5e954cc54bcec
    21850|fd 7b 41 a9|ldp|x29, x30, [sp, #0x10]||6df44215522e0fdb|79b69a621525f40f
    21854|f4 4f c2 a8|ldp|x20, x19, [sp], #0x20||fa77aef49765806d|f84095f8f2c993fd
    21858|c0 03 5f d6|ret|||52dc34e2ac6a9178|d6a89528552a7e85
    """
    static let baselineText = """
    int32_t _jpeg_finish_decompress(struct jpeg_decompress_struct * cinfo) {
        // entry 0x000000000002177c; no stack frame; calls (*x8), _jpeg_abort
        *(uint64_t *)(sp_0 + -0x20), *(uint64_t *)((sp_0 + -0x20) + 0x8), sp_1 = x20_0, x19_0, sp_0 - 0x20;
        *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8) = x29_0, x30_0; // saves register pair
        x29_1 = sp_1 + 0x10;
        x19_1 = cinfo;
        tmp0 = cinfo->global_state;
        tmp1 = tmp0 - 0xcd;
        if ((uint32_t)(tmp1) > (uint32_t)(0x1)) goto 0x217a4; // conditional branch
        tmp2 = *(uint32_t *)(x19_1 + 0x58);
        if (tmp2 == 0x0) goto 0x217d4; // conditional branch
        if (tmp0 == 0xd2) goto 0x21814; // conditional branch
        if (tmp0 == 0xcf) goto 0x2180c; // conditional branch
        tmp3 = *(x19_1);
        tmp4 = 0x15;
        *(uint32_t *)(tmp3 + 0x28), *(uint32_t *)((tmp3 + 0x28) + 0x4) = tmp4, tmp0; // saves register pair
        tmp5 = *(x19_1);
        tmp6 = *(tmp5);
        x0_1 = x19_1;
        x0_2 = (*tmp6)(x0_1); // call
        __branch(0x21814); // unconditional branch
        tmp7 = *(uint32_t *)(x19_1 + 0xa8);
        tmp8 = *(uint32_t *)(x19_1 + 0x8c);
        if ((uint32_t)(tmp7) >= (uint32_t)(tmp8)) goto 0x217fc; // conditional branch
        tmp9 = *(x19_1);
        tmp10 = 0x45;
        *(uint32_t *)(tmp9 + 0x28) = tmp10;
        tmp11 = *(tmp9);
        x0_3 = x19_1;
        x0_4 = (*tmp11)(x0_3); // call
        tmp12 = *(x19_1 + 0x238);
        tmp13 = *(tmp12 + 0x8);
        x0_5 = x19_1;
        x0_6 = (*tmp13)(x0_5); // call
        tmp14 = 0xd2;
        *(uint32_t *)(x19_1 + 0x24) = tmp14;
        tmp15 = *(x19_1 + 0x258);
        tmp16 = *(uint32_t *)(tmp15 + 0x24);
        if (tmp16 != 0x0) goto 0x21834; // conditional branch
        tmp17 = *(tmp15);
        x0_7 = x19_1;
        x0_8 = (*tmp17)(x0_7); // call
        if ((uint32_t)(x0_8) != 0x0) goto 0x21814; // conditional branch
        __branch(0x21850); // unconditional branch
        tmp18 = *(x19_1 + 0x28);
        tmp19 = *(tmp18 + 0x30);
        x0_9 = x19_1;
        x0_10 = (*tmp19)(x0_9); // call
        x0_11 = x19_1;
        x0_12 = _jpeg_abort(x0_11); // call
        w0_1 = 0x1;
        x29_2, x30_1 = *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8); // restores register pair
        x20_1, x19_2, sp_2 = *(uint64_t *)(sp_1), *(uint64_t *)(sp_1 + 0x8), sp_1 + 0x20;
        return w0_1; // return
    }
    """
}

private enum SkipVariableTerminalCapturedData {
    static let functionWitness: UInt64 = 0xae449d500cda7fd2
    static let blocksWitness: UInt64 = 0x96bf8aa02f0a201b
    // Original address, bytes, mnemonic, operands, comment, operand and IR witnesses.
    static let sourceRecord = """
    33418|fa 67 bb a9|stp|x26, x25, [sp, #-0x50]!||b67b86f0cf71f513|9263c81d926e7358
    3341c|f8 5f 01 a9|stp|x24, x23, [sp, #0x10]||c6321e446c894e12|a24d2f4c5bb8d74b
    33420|f6 57 02 a9|stp|x22, x21, [sp, #0x20]||2defc65364c27430|17337739638e10da
    33424|f4 4f 03 a9|stp|x20, x19, [sp, #0x30]||5261f9d053f62da6|76823249f039345b
    33428|fd 7b 04 a9|stp|x29, x30, [sp, #0x40]||ace2caff5241824a|45c933757c2696c4
    3342c|fd 03 01 91|add|x29, sp, #0x40||88ab455e2c04420e|54b2c4eaef114098
    33430|f3 03 00 aa|mov|x19, x0||b5a7cfada79f5022|f9d2016cc1459c58
    33434|16 14 40 f9|ldr|x22, [x0, #0x28]||3c89b0a2b006ea14|69264bbb4762fdc1
    33438|c8 06 40 f9|ldr|x8, [x22, #8]||7821afca50ca7278|aed5ab3fee9412a8
    3343c|c8 00 00 b5|cbnz|x8, 0x0000000000033454||dcaa23ec7721d2a2|5814c77c88f5ce5a
    33440|c8 0e 40 f9|ldr|x8, [x22, #0x18]||73fc751fcd68ac4c|af9cb6a1e85e3a23
    33444|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|e7f699cd2b90e1d8
    33448|00 01 3f d6|blr|x8||d4648694c208727c|92bd00b30e559f58
    3344c|a0 04 00 34|cbz|w0, 0x00000000000334e0||faeb280b1e2a831f|21bad420ae18478f
    33450|c8 06 40 f9|ldr|x8, [x22, #8]||7821afca50ca7278|77595c0d4d799eb2
    33454|d7 02 40 f9|ldr|x23, [x22]||90f0124596112bb5|48c90ebb60b9d1d3
    33458|f4 16 40 38|ldrb|w20, [x23], #1||232549cb6bb775af|bec70c57844cf676
    3345c|08 05 00 f1|subs|x8, x8, #1||9b87d75247eb6e40|b23b6fddf4ae2559
    33460|c1 00 00 54|b.ne|0x0000000000033478||763dfb9d6b50e0f9|becddd0b8a93ec15
    33464|c8 0e 40 f9|ldr|x8, [x22, #0x18]||73fc751fcd68ac4c|5e6d1147e895fbff
    33468|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|928f134a770249b3
    3346c|00 01 3f d6|blr|x8||d4648694c208727c|7968278ec89ee463
    33470|80 03 00 34|cbz|w0, 0x00000000000334e0||87ec36a485fbb8c9|3c9b52a12c77ba02
    33474|d7 22 40 a9|ldp|x23, x8, [x22]||d0bf76a9ab64518a|bade0d15e77aeb27
    33478|89 de 78 d3|lsl|x9, x20, #8||fe99c0f5132f4ea6|51f628c520c7aeba
    3347c|ea 16 40 38|ldrb|w10, [x23], #1||f540222bf2f38064|0c3f7f5fe5119243
    33480|18 05 00 d1|sub|x24, x8, #1||a74c82b7da03f54e|8d932cbe7d84eec0
    33484|39 01 0a aa|orr|x25, x9, x10||e68f873a14c0ba4a|97cac7fd608202c0
    33488|34 0b 00 d1|sub|x20, x25, #2||4dec7e224d84ad31|8a1884f242a94684
    3348c|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|b8d09f41ab35eae7
    33490|a9 0b 80 52|mov|w9, #0x5d||37b17f32837e80cb|1c301e5bec4cca68
    33494|6a 36 42 b9|ldr|w10, [x19, #0x234]||4727165b9ad4cb40|acc2b9059f93d9ec
    33498|09 29 05 29|stp|w9, w10, [x8, #0x28]||ad92a4f3d7436892|da8638b4d1858b0e
    3349c|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|aec8861a19b4307f
    334a0|14 31 00 b9|str|w20, [x8, #0x30]||3c723531c5c0abfc|500f798cb4141bfc
    334a4|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|cf559e0a66cb6e33
    334a8|08 05 40 f9|ldr|x8, [x8, #8]||2f82d4e6a9dff056|937198f2453264a6
    334ac|35 00 80 52|mov|w21, #1||d9aa50ffd48fb03b|e93914e227805391
    334b0|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|7af9e8a8b07c33c2
    334b4|21 00 80 52|mov|w1, #1||2fcba54fa2dba661|102f0d7e6d5c9f9a
    334b8|00 01 3f d6|blr|x8||d4648694c208727c|750962d78121061a
    334bc|d7 62 00 a9|stp|x23, x24, [x22]||7a91cf2c0791e754|3e501f708a349e0b
    334c0|3f 0f 00 f1|cmp|x25, #3||adc6956aca885555|a4a796859aa0cc81
    334c4|03 01 00 54|b.lo|0x00000000000334e4||b127f465af59a60d|3ef2317af1dc5efb
    334c8|68 16 40 f9|ldr|x8, [x19, #0x28]||5d99e2815ab5fa48|c557fa35b145f7ec
    334cc|08 11 40 f9|ldr|x8, [x8, #0x20]||8f345ebe3db57dc7|b502d26467756832
    334d0|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|f27b6248b985aece
    334d4|e1 03 14 aa|mov|x1, x20||f5140832f0fc8506|4be78fd613d839f1
    334d8|00 01 3f d6|blr|x8||d4648694c208727c|857bdfa59ef3c5e3
    334dc|02 00 00 14|b|0x00000000000334e4||0faa7be3460885bd|b2db4dbca9b870c7
    334e0|15 00 80 52|mov|w21, #0||c2d44e58748e8b2d|3238e25e669dbb7e
    334e4|e0 03 15 aa|mov|x0, x21||2e5a02bec194f8f2|6c72168375009029
    334e8|fd 7b 44 a9|ldp|x29, x30, [sp, #0x40]||b820e43a0f0b5628|6ff3a69d1bdfe61c
    334ec|f4 4f 43 a9|ldp|x20, x19, [sp, #0x30]||3a7e29e33da505f8|ad4e82429f768841
    334f0|f6 57 42 a9|ldp|x22, x21, [sp, #0x20]||4492156f9cca23fe|1909b650a8a551be
    334f4|f8 5f 41 a9|ldp|x24, x23, [sp, #0x10]||193eb0531918d348|9e36157a9ddb861c
    334f8|fa 67 c5 a8|ldp|x26, x25, [sp], #0x50||5770660a054c4113|d838615f8a028414
    334fc|c0 03 5f d6|ret|||52dc34e2ac6a9178|c19de1d54f11e4b7
    """
    static let baselineText = """
    int64_t _skip_variable(int64_t arg0) {
        // entry 0x0000000000033418; stack frame 0x50 bytes; calls (*x8)
        *(uint64_t *)(sp_0 + -0x50), *(uint64_t *)((sp_0 + -0x50) + 0x8), sp_1 = x26_0, x25_0, sp_0 - 0x50;
        *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8) = x24_0, x23_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8) = x22_0, x21_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8) = x20_0, x19_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8) = x29_0, x30_0; // saves register pair
        x29_1 = sp_1 + 0x40;
        x19_1 = arg0;
        x22_1 = *(arg0 + 0x28);
        tmp0 = *(x22_1 + 0x8);
        if (tmp0 != 0x0) goto 0x33454; // conditional branch
        tmp1 = *(x22_1 + 0x18);
        x0_1 = x19_1;
        x0_2 = (*tmp1)(x0_1); // call
        if ((uint32_t)(x0_2) == 0x0) goto 0x334e0; // conditional branch
        tmp2 = *(x22_1 + 0x8);
        x23_1 = *(x22_1);
        w20_1, x23_2 = *(uint8_t *)(x23_1), x23_1 + 0x1;
        tmp3 = unavailable_x8 - 0x1;
        if (unavailable_x8 != 0x1) goto 0x33478; // conditional branch
        tmp4 = *(x22_1 + 0x18);
        x0_3 = x19_1;
        x0_4 = (*tmp4)(x0_3); // call
        if ((uint32_t)(x0_4) == 0x0) goto 0x334e0; // conditional branch
        x23_3, tmp5 = *(uint64_t *)(x22_1), *(uint64_t *)(x22_1 + 0x8); // restores register pair
        tmp6 = (uint64_t)((uint64_t)((uint32_t)(w20_1))) << 0x8;
        tmp7, x23_4 = *(uint8_t *)(unavailable_x23), unavailable_x23 + 0x1;
        x24_1 = unavailable_x8 - 0x1;
        x25_1 = tmp6 | (uint64_t)((uint32_t)(tmp7));
        x20_1 = x25_1 - 0x2;
        tmp8 = *(x19_1);
        tmp9 = 0x5d;
        tmp10 = *(uint32_t *)(x19_1 + 0x234);
        *(uint32_t *)(tmp8 + 0x28), *(uint32_t *)((tmp8 + 0x28) + 0x4) = tmp9, tmp10; // saves register pair
        tmp11 = *(x19_1);
        *(uint32_t *)(tmp11 + 0x30) = (uint32_t)(x20_1);
        tmp12 = *(x19_1);
        tmp13 = *(tmp12 + 0x8);
        w21_1 = 0x1;
        x0_5 = x19_1;
        w1_1 = 0x1;
        x0_6 = (*tmp13)(x0_5, w1_1); // call
        *(uint64_t *)(x22_1), *(uint64_t *)(x22_1 + 0x8) = x23_4, x24_1; // saves register pair
        if ((uint64_t)(x25_1) < (uint64_t)(0x3)) goto 0x334e4; // conditional branch
        tmp14 = *(x19_1 + 0x28);
        tmp15 = *(tmp14 + 0x20);
        x0_7 = x19_1;
        x1_1 = x20_1;
        x0_8 = (*tmp15)(x0_7, x1_1); // call
        __branch(0x334e4); // unconditional branch
        w21_2 = 0x0;
        x0_9 = unavailable_x21;
        x29_2, x30_1 = *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8); // restores register pair
        x20_2, x19_2 = *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8); // restores register pair
        x22_2, x21_1 = *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8); // restores register pair
        x24_2, x23_5 = *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8); // restores register pair
        x26_1, x25_2, sp_2 = *(uint64_t *)(sp_1), *(uint64_t *)(sp_1 + 0x8), sp_1 + 0x50;
        return x0_9; // return
    }
    """
    // Current flat output; differs from the capture above only by flat label spelling.
    static let flatText = """
    int64_t _skip_variable(int64_t arg0) {
        // entry 0x0000000000033418; stack frame 0x50 bytes; calls (*x8)
        *(uint64_t *)(sp_0 + -0x50), *(uint64_t *)((sp_0 + -0x50) + 0x8), sp_1 = x26_0, x25_0, sp_0 - 0x50;
        *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8) = x24_0, x23_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8) = x22_0, x21_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8) = x20_0, x19_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8) = x29_0, x30_0; // saves register pair
        x29_1 = sp_1 + 0x40;
        x19_1 = arg0;
        x22_1 = *(arg0 + 0x28);
        tmp0 = *(x22_1 + 0x8);
        if (tmp0 != 0x0) goto loc_33454; // conditional branch
        tmp1 = *(x22_1 + 0x18);
        x0_1 = x19_1;
        x0_2 = (*tmp1)(x0_1); // call
        if ((uint32_t)(x0_2) == 0x0) goto loc_334e0; // conditional branch
        tmp2 = *(x22_1 + 0x8);
        loc_33454:
        x23_1 = *(x22_1);
        w20_1, x23_2 = *(uint8_t *)(x23_1), x23_1 + 0x1;
        tmp3 = unavailable_x8 - 0x1;
        if (unavailable_x8 != 0x1) goto loc_33478; // conditional branch
        tmp4 = *(x22_1 + 0x18);
        x0_3 = x19_1;
        x0_4 = (*tmp4)(x0_3); // call
        if ((uint32_t)(x0_4) == 0x0) goto loc_334e0; // conditional branch
        x23_3, tmp5 = *(uint64_t *)(x22_1), *(uint64_t *)(x22_1 + 0x8); // restores register pair
        loc_33478:
        tmp6 = (uint64_t)((uint64_t)((uint32_t)(w20_1))) << 0x8;
        tmp7, x23_4 = *(uint8_t *)(unavailable_x23), unavailable_x23 + 0x1;
        x24_1 = unavailable_x8 - 0x1;
        x25_1 = tmp6 | (uint64_t)((uint32_t)(tmp7));
        x20_1 = x25_1 - 0x2;
        tmp8 = *(x19_1);
        tmp9 = 0x5d;
        tmp10 = *(uint32_t *)(x19_1 + 0x234);
        *(uint32_t *)(tmp8 + 0x28), *(uint32_t *)((tmp8 + 0x28) + 0x4) = tmp9, tmp10; // saves register pair
        tmp11 = *(x19_1);
        *(uint32_t *)(tmp11 + 0x30) = (uint32_t)(x20_1);
        tmp12 = *(x19_1);
        tmp13 = *(tmp12 + 0x8);
        w21_1 = 0x1;
        x0_5 = x19_1;
        w1_1 = 0x1;
        x0_6 = (*tmp13)(x0_5, w1_1); // call
        *(uint64_t *)(x22_1), *(uint64_t *)(x22_1 + 0x8) = x23_4, x24_1; // saves register pair
        if ((uint64_t)(x25_1) < (uint64_t)(0x3)) goto loc_334e4; // conditional branch
        tmp14 = *(x19_1 + 0x28);
        tmp15 = *(tmp14 + 0x20);
        x0_7 = x19_1;
        x1_1 = x20_1;
        x0_8 = (*tmp15)(x0_7, x1_1); // call
        goto loc_334e4; // unconditional branch
        loc_334e0:
        w21_2 = 0x0;
        loc_334e4:
        x0_9 = unavailable_x21;
        x29_2, x30_1 = *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8); // restores register pair
        x20_2, x19_2 = *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8); // restores register pair
        x22_2, x21_1 = *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8); // restores register pair
        x24_2, x23_5 = *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8); // restores register pair
        x26_1, x25_2, sp_2 = *(uint64_t *)(sp_1), *(uint64_t *)(sp_1 + 0x8), sp_1 + 0x50;
        return x0_9; // return
    }
    """
}

extension RegionalTerminalSeed {
    var functionWitness: UInt64 {
        self == .finishDecompress ? FinishDecompressTerminalCapturedData.functionWitness : SkipVariableTerminalCapturedData.functionWitness
    }
    var blocksWitness: UInt64 {
        self == .finishDecompress ? FinishDecompressTerminalCapturedData.blocksWitness : SkipVariableTerminalCapturedData.blocksWitness
    }
    var sourceRecord: String {
        self == .finishDecompress ? FinishDecompressTerminalCapturedData.sourceRecord : SkipVariableTerminalCapturedData.sourceRecord
    }
    var baselineText: String {
        self == .finishDecompress ? FinishDecompressTerminalCapturedData.baselineText : SkipVariableTerminalCapturedData.baselineText
    }
    var flatText: String {
        self == .finishDecompress ? FinishDecompressTerminalCapturedData.baselineText : SkipVariableTerminalCapturedData.flatText
    }
}
