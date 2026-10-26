import XCTest
import Foundation

@testable import MacScope

/// Tests specifically targeting the operand tree parsing and expression table wiring
/// for BinExport2. These tests construct small synthetic snapshots featuring
/// complex operands and verify that the exporter produces correct expression
/// trees with parent indices. Where possible, they also validate the output
/// using the external `protoc` decoder against the vendored schema.
final class BinExport2OperandTreeTests: XCTestCase {
    /// A minimal proto3 reader for testing. Supports varint and length-delimited fields.
    struct ProtoReader {
        let data: Data
        var index: Int = 0

        /// Reads the next field tag, returning (fieldNumber, wireType), or nil when
        /// at end of data.
        mutating func nextTag() -> (Int, Int)? {
            guard index < data.count else { return nil }
            let (key, _) = readVarint()
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x7)
            return (fieldNumber, wireType)
        }

        /// Reads a varint and returns its value and the number of bytes consumed.
        @discardableResult
        mutating func readVarint() -> (UInt64, Int) {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            var bytesRead = 0
            while index < data.count {
                let byte = data[index]
                index += 1
                bytesRead += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            return (result, bytesRead)
        }

        /// Reads a length-delimited field and returns the bytes.
        mutating func readLengthDelimited() -> Data {
            let (len, _) = readVarint()
            guard len > 0, index + Int(len) <= data.count else { return Data() }
            let start = index
            let end = index + Int(len)
            index = end
            return data.subdata(in: start..<end)
        }

        /// Skips a field of the given wire type.
        mutating func skipField(wireType: Int) {
            switch wireType {
            case 0:
                _ = readVarint()
            case 1:
                // 64-bit fixed
                index += 8
            case 2:
                let (len, _) = readVarint()
                index += Int(len)
            case 5:
                // 32-bit fixed
                index += 4
            default:
                break
            }
        }
    }

    /// Parsed representation of a BinExport2 message for expressions.
    struct ParsedExport {
        struct ParsedExpression {
            var type: Int32
            var symbol: String
            var immediate: UInt64
            var parentIndex: Int32?
        }
        var expressions: [ParsedExpression] = []
    }

    /// Parses only the expression table from a BinExport2 message. Returns a
    /// ParsedExport with expressions populated.
    static func parseExpressions(data: Data) -> ParsedExport {
        var reader = ProtoReader(data: data)
        var result = ParsedExport()
        while let (fieldNumber, wireType) = reader.nextTag() {
            switch fieldNumber {
            case 2: // expression messages (BinExport2.expression = 2)
                let exprData = reader.readLengthDelimited()
                var exprReader = ProtoReader(data: exprData)
                var type: Int32 = 2
                var symbol: String = ""
                var immediate: UInt64 = 0
                var parent: Int32? = nil
                while let (fNum, fType) = exprReader.nextTag() {
                    switch fNum {
                    case 1: // type
                        let (val, _) = exprReader.readVarint()
                        type = Int32(bitPattern: UInt32(val))
                    case 2: // symbol
                        let nameData = exprReader.readLengthDelimited()
                        symbol = String(data: nameData, encoding: .utf8) ?? ""
                    case 3: // immediate
                        let (val, _) = exprReader.readVarint()
                        immediate = val
                    case 4: // parent_index
                        let (val, _) = exprReader.readVarint()
                        parent = Int32(bitPattern: UInt32(val))
                    default:
                        exprReader.skipField(wireType: fType)
                    }
                }
                result.expressions.append(.init(type: type, symbol: symbol, immediate: immediate, parentIndex: parent))
            default:
                // skip unhandled fields
                reader.skipField(wireType: wireType)
            }
        }
        return result
    }

    /// Builds a minimal snapshot with a single instruction. Helper for tests.
    private func makeSnapshot(architecture: String, mnemonic: String, operands: String) -> WorkspaceSnapshot {
        let image = BinaryImage(id: UUID(), name: "testbin", path: "/test", kind: "", architecture: architecture)
        let fn = FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000, endAddress: 0x1004, confidence: 1.0)
        let bb = BasicBlockSummary(id: UUID(), functionID: fn.id, startAddress: 0x1000, endAddress: 0x1004, instructionCount: 1)
        let row = InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
        return WorkspaceSnapshot(
            binaries: [image],
            functions: [fn],
            symbols: [],
            imports: [],
            indirectSymbols: [],
            exports: [],
            stringLiterals: [],
            basicBlocks: [bb],
            instructions: [row],
            xrefs: [],
            controlFlowEdges: [],
            hexBytes: Data()
        )
    }

    /// Verifies that the memory operand `[x1, #8]` yields a dereference node with a
    /// plus operator and appropriate children.
    func testArmMemoryWithOffsetTree() {
        let snapshot = makeSnapshot(architecture: "aarch64", mnemonic: "ldr", operands: "x0, [x1, #8]")
        let exporter = BinExport2Exporter()
        let data = exporter.export(snapshot)
        let parsed = Self.parseExpressions(data: data)
        // Locate nodes by type and value.
        var derefIdx: Int? = nil
        var plusIdx: Int? = nil
        var regIdx: Int? = nil
        var immIdx: Int? = nil
        for (idx, expr) in parsed.expressions.enumerated() {
            switch expr.type {
            case 7: // DEREFERENCE
                derefIdx = idx
            case 4 where expr.symbol == "+":
                plusIdx = idx
            case 5 where expr.symbol == "x1":
                regIdx = idx
            case 2 where expr.immediate == 8:
                immIdx = idx
            default:
                continue
            }
        }
        XCTAssertNotNil(derefIdx, "Dereference node must exist")
        XCTAssertNotNil(plusIdx, "Operator '+' node must exist")
        XCTAssertNotNil(regIdx, "Register x1 node must exist")
        XCTAssertNotNil(immIdx, "Immediate 8 node must exist")
        if let d = derefIdx, let p = plusIdx {
            // plus's parent should be dereference
            let plusParent = parsed.expressions[p].parentIndex
            XCTAssertEqual(plusParent, Int32(d), "Plus node should have dereference as parent")
        }
        if let p = plusIdx, let r = regIdx {
            let regParent = parsed.expressions[r].parentIndex
            XCTAssertEqual(regParent, Int32(p), "Register x1 should have plus as parent")
        }
        if let p = plusIdx, let i = immIdx {
            let immParent = parsed.expressions[i].parentIndex
            XCTAssertEqual(immParent, Int32(p), "Immediate 8 should have plus as parent")
        }
    }

    /// Regression: a NEGATIVE ARM memory offset `[x1, #-16]` must produce a single IMMEDIATE_INT
    /// (two's-complement of -16) and NO stray `SYMBOL "#"` node. The tokenizer used to split on the
    /// `-` of `#-16` while the accumulator held only the bare immediate-prefix `#`, flushing that `#`
    /// as its own token; it failed to parse as an immediate and fell through to a SYMBOL node,
    /// corrupting the operand tree BinDiff consumes. Runs without protoc (structural assertion).
    func testArmNegativeMemoryOffsetEmitsNoStrayHashNode() {
        let snapshot = makeSnapshot(architecture: "aarch64", mnemonic: "ldr", operands: "x0, [x1, #-16]")
        let data = BinExport2Exporter().export(snapshot)
        let parsed = Self.parseExpressions(data: data)

        XCTAssertFalse(
            parsed.expressions.contains { $0.type == 1 && $0.symbol == "#" },
            "A negative offset must not leak a SYMBOL \"#\" node into the operand tree"
        )
        XCTAssertTrue(
            parsed.expressions.contains { $0.type == 5 && $0.symbol == "x1" },
            "Base register x1 node must exist"
        )
        XCTAssertTrue(
            parsed.expressions.contains { $0.type == 2 && $0.immediate == UInt64(bitPattern: -16) },
            "Offset must be a single IMMEDIATE_INT carrying two's-complement -16"
        )
    }

    /// Verifies that a shifted register `x1, lsl #2` yields an operator node 'lsl' with
    /// children register x1 and immediate 2.
    func testArmShiftedRegisterTree() {
        let snapshot = makeSnapshot(architecture: "aarch64", mnemonic: "mov", operands: "x0, x1, lsl #2")
        let exporter = BinExport2Exporter()
        let data = exporter.export(snapshot)
        let parsed = Self.parseExpressions(data: data)
        var opIdx: Int? = nil
        var regIdx: Int? = nil
        var immIdx: Int? = nil
        for (idx, expr) in parsed.expressions.enumerated() {
            switch expr.type {
            case 4 where expr.symbol.lowercased() == "lsl":
                opIdx = idx
            case 5 where expr.symbol == "x1":
                // We want the register child of lsl; skip root x0
                if let parent = expr.parentIndex, let op = opIdx, parent == Int32(op) {
                    regIdx = idx
                }
            case 2 where expr.immediate == 2:
                if let parent = expr.parentIndex, let op = opIdx, parent == Int32(op) {
                    immIdx = idx
                }
            default:
                continue
            }
        }
        XCTAssertNotNil(opIdx, "Operator 'lsl' node must exist")
        XCTAssertNotNil(regIdx, "Register x1 child must exist")
        XCTAssertNotNil(immIdx, "Immediate 2 child must exist")
        if let op = opIdx, let r = regIdx {
            let parent = parsed.expressions[r].parentIndex
            XCTAssertEqual(parent, Int32(op), "Register x1 must have 'lsl' as parent")
        }
        if let op = opIdx, let i = immIdx {
            let parent = parsed.expressions[i].parentIndex
            XCTAssertEqual(parent, Int32(op), "Immediate 2 must have 'lsl' as parent")
        }
    }

    /// Verifies that an x86 scaled-index memory operand yields a dereference with a
    /// plus operator combining base, scaled index and displacement. Tests both
    /// Intel-style `[rax + rcx*4 + 0x10]` and AT&T-style `0x10(%rax,%rcx,4)`.
    func testX86ScaledIndexMemoryTree() {
        // Intel style
        let snap1 = makeSnapshot(architecture: "x86_64", mnemonic: "mov", operands: "rax, [rax + rcx*4 + 0x10]")
        // AT&T style
        let snap2 = makeSnapshot(architecture: "x86_64", mnemonic: "mov", operands: "%rax, 0x10(%rax,%rcx,4)")
        for snapshot in [snap1, snap2] {
            let exporter = BinExport2Exporter()
            let data = exporter.export(snapshot)
            let parsed = Self.parseExpressions(data: data)
            // We expect: deref, '+', 'rax', '*' (for rcx*4), 'rcx', immediate 4, immediate displacement.
            var deref: Int? = nil
            var plus: Int? = nil
            var mul: Int? = nil
            var baseReg: Int? = nil
            var indexReg: Int? = nil
            var scaleImm: Int? = nil
            var dispImm: Int? = nil
            for (idx, expr) in parsed.expressions.enumerated() {
                switch expr.type {
                case 7:
                    deref = idx
                case 4 where expr.symbol == "+":
                    plus = idx
                case 4 where expr.symbol == "*":
                    mul = idx
                case 5 where expr.symbol.lowercased() == "rax" || expr.symbol.lowercased() == "%rax":
                    // base register parent must be plus
                    if let p = expr.parentIndex, let plusIdx = plus, p == Int32(plusIdx) {
                        baseReg = idx
                    }
                case 5 where expr.symbol.lowercased() == "rcx" || expr.symbol.lowercased() == "%rcx":
                    if let p = expr.parentIndex, let mulIdx = mul, p == Int32(mulIdx) {
                        indexReg = idx
                    }
                case 2 where expr.immediate == 4:
                    if let p = expr.parentIndex, let mulIdx = mul, p == Int32(mulIdx) {
                        scaleImm = idx
                    }
                case 2 where expr.immediate == 0x10:
                    // displacement parent must be plus
                    if let p = expr.parentIndex, let plusIdx = plus, p == Int32(plusIdx) {
                        dispImm = idx
                    }
                default:
                    continue
                }
            }
            XCTAssertNotNil(deref, "Dereference node missing")
            XCTAssertNotNil(plus, "Plus node missing")
            XCTAssertNotNil(mul, "Multiply node missing")
            XCTAssertNotNil(baseReg, "Base register missing")
            XCTAssertNotNil(indexReg, "Index register missing")
            XCTAssertNotNil(scaleImm, "Scale immediate missing")
            XCTAssertNotNil(dispImm, "Displacement immediate missing")
            if let d = deref, let pIdx = plus {
                let pParent = parsed.expressions[pIdx].parentIndex
                XCTAssertEqual(pParent, Int32(d), "Plus should have dereference as parent")
            }
            if let pIdx = plus, let mIdx = mul {
                let mParent = parsed.expressions[mIdx].parentIndex
                XCTAssertEqual(mParent, Int32(pIdx), "Multiply should have plus as parent")
            }
        }
    }

    /// Verifies that plain operands produce single-leaf expression trees: registers,
    /// immediates and symbols remain as standalone nodes.
    func testPlainOperandSingleLeaf() {
        // Register
        let snapReg = makeSnapshot(architecture: "aarch64", mnemonic: "mov", operands: "x0")
        // Immediate
        let snapImm = makeSnapshot(architecture: "aarch64", mnemonic: "mov", operands: "#42")
        // Symbol
        let snapSym = makeSnapshot(architecture: "aarch64", mnemonic: "bl", operands: "printf")
        for snapshot in [snapReg, snapImm, snapSym] {
            let exporter = BinExport2Exporter()
            let data = exporter.export(snapshot)
            let parsed = Self.parseExpressions(data: data)
            // There should be exactly one expression.
            XCTAssertEqual(parsed.expressions.count, 1)
            let expr = parsed.expressions.first!
            switch snapshot.instructions.first!.operands.trimmingCharacters(in: .whitespacesAndNewlines) {
            case let s where s.hasPrefix("#"):
                XCTAssertEqual(expr.type, 2, "Immediate should be type 2")
                XCTAssertEqual(expr.immediate, 42, "Immediate value mismatch")
            case let s where BinExport2OperandParser.isRegisterToken(s):
                XCTAssertEqual(expr.type, 5, "Register should be type 5")
                XCTAssertEqual(expr.symbol, "x0", "Register name mismatch")
            default:
                XCTAssertEqual(expr.type, 1, "Symbol should be type 1")
                XCTAssertEqual(expr.symbol, "printf", "Symbol name mismatch")
            }
            XCTAssertNil(expr.parentIndex, "Standalone expressions should have no parent")
        }
    }

    /// Determinism: the same snapshot must export to byte-identical output, and
    /// parent_index 0 must be EMITTED (not zero-suppressed) so a root child can be
    /// distinguished from a node that links to expression 0.
    func testDeterminismAndParentIndexZeroEmitted() {
        // Use a memory operand as the ONLY operand. Its DEREFERENCE root sorts to expression
        // index 0 (the child register's sort path is the deref path + one element, so the deref
        // — a strict prefix — orders first). The register child therefore carries parent_index 0,
        // which must be EMITTED on the wire (a zero-suppressing writer would drop it and a decoder
        // could not tell the child from a root).
        let snapshot = makeSnapshot(architecture: "aarch64", mnemonic: "ldr", operands: "[x1]")
        let exporter = BinExport2Exporter()
        let d1 = exporter.export(snapshot)
        let d2 = exporter.export(snapshot)
        XCTAssertEqual(d1, d2, "Export must be byte-deterministic for the same snapshot")
        let parsed = Self.parseExpressions(data: d1)
        // Exactly two expressions: DEREFERENCE (index 0, root) and REGISTER x1 (child).
        XCTAssertEqual(parsed.expressions.count, 2)
        XCTAssertEqual(parsed.expressions[0].type, 7, "Expression 0 must be the DEREFERENCE root")
        XCTAssertNil(parsed.expressions[0].parentIndex, "Expression at index 0 must be a root")
        // The child register must carry parent_index == 0, proving the zero is on the wire.
        XCTAssertTrue(parsed.expressions.contains { $0.type == 5 && $0.symbol == "x1" && $0.parentIndex == 0 },
                      "register child of [x1] must have parent_index 0 emitted")
        // Byte-level confirmation: the parent_index field tag (field 4, wire type 0 => 0x20)
        // followed by value 0 must appear verbatim somewhere in the output.
        XCTAssertTrue(d1.range(of: Data([0x20, 0x00])) != nil,
                      "wire bytes must contain parent_index(=field4 varint) 0 => 0x20 0x00")
    }

    /// EXTERNAL ORACLE: decode the emitted bytes with `protoc --decode` against the vendored
    /// upstream-field-numbered schema. protoc resolves field numbers/enum names independently of
    /// our hand-rolled reader, so a passing decode confirms the wire layout (Expression.type=1,
    /// symbol=2, immediate=3, parent_index=4) matches google/binexport. Skipped if protoc or the
    /// proto file is absent.
    func testProtocDecode() throws {
        let snapshot = makeSnapshot(architecture: "aarch64", mnemonic: "ldr", operands: "x0, [x1, #8]")
        let data = BinExport2Exporter().export(snapshot)

        let outputString = try Self.decodeWithProtoc(data)
        // The decoded text representation must contain the tree node types and symbols, proving the
        // field numbers and enum values round-trip through the authoritative schema.
        XCTAssertTrue(outputString.contains("type: DEREFERENCE"),
                      "Decoded output should contain DEREFERENCE type. Got:\n\(outputString)")
        XCTAssertTrue(outputString.contains("type: OPERATOR"),
                      "Decoded output should contain OPERATOR type. Got:\n\(outputString)")
        XCTAssertTrue(outputString.contains("symbol: \"+\""),
                      "Decoded output should contain plus operator symbol. Got:\n\(outputString)")
        XCTAssertTrue(outputString.contains("symbol: \"x1\""),
                      "Decoded output should contain register x1 symbol. Got:\n\(outputString)")
        XCTAssertTrue(outputString.contains("immediate: 8"),
                      "Decoded output should contain immediate 8. Got:\n\(outputString)")
        // Structural confirmation: the '+' OPERATOR is a child of the DEREFERENCE, and the
        // IMMEDIATE 8 plus REGISTER x1 are children of '+'. protoc renders parent_index as a
        // non-zero scalar here because, for this two-operand instruction, the deref does not sort
        // to expression index 0 (the standalone `x0` register does). The deref's '+' child therefore
        // carries a non-zero parent_index — and at least one non-zero parent_index MUST appear,
        // proving the parent links survive the round-trip through the authoritative schema.
        XCTAssertTrue(outputString.contains("parent_index:"),
                      "Decoded output must show parent_index links. Got:\n\(outputString)")
    }

    /// EXTERNAL ORACLE (negative offset): the prior `testProtocDecode` only exercised a positive
    /// `#8` offset, so the green gate was blind to the stray-`#` leak on `#-16`. Decode the emitted
    /// bytes with the authoritative protoc schema and assert the tree contains the two's-complement
    /// immediate and NOT a `symbol: "#"` node.
    func testProtocDecodeNegativeOffsetEmitsNoStrayHash() throws {
        let outputString = try Self.decodeWithProtoc(
            BinExport2Exporter().export(
                makeSnapshot(architecture: "aarch64", mnemonic: "ldr", operands: "x0, [x1, #-16]")))
        XCTAssertFalse(outputString.contains("symbol: \"#\""),
                       "A negative offset must not emit a stray '#' SYMBOL node. Got:\n\(outputString)")
        XCTAssertTrue(outputString.contains("immediate: \(UInt64(bitPattern: -16))"),
                      "Decoded output must carry the two's-complement -16 immediate. Got:\n\(outputString)")
        XCTAssertTrue(outputString.contains("symbol: \"x1\""),
                      "Decoded output should contain register x1 symbol. Got:\n\(outputString)")
    }

    /// Pipes `data` through `protoc --decode=BinExport2` against the vendored schema and returns the
    /// text rendering. Throws XCTSkip when protoc or the proto file is unavailable on the host.
    private static func decodeWithProtoc(_ data: Data) throws -> String {
        let protocPath = "/opt/homebrew/bin/protoc"
        guard FileManager.default.fileExists(atPath: protocPath) else {
            throw XCTSkip("protoc not installed; skipping decode integration test")
        }
        let testBundle = Bundle(for: BinExport2OperandTreeTests.self)
        guard let protoURL = testBundle.url(forResource: "binexport2", withExtension: "proto") else {
            throw XCTSkip("binexport2.proto not bundled; skipping decode integration test")
        }
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-binexport2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        let inputURL = runDirectory.appendingPathComponent("input.bin")
        try data.write(to: inputURL, options: .atomic)
        let localProtoURL = runDirectory.appendingPathComponent(protoURL.lastPathComponent)
        try Data(contentsOf: protoURL).write(to: localProtoURL, options: .atomic)

        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: protocPath)
        process.arguments = ["--decode=BinExport2",
                             "--proto_path=\(runDirectory.path)",
                             localProtoURL.lastPathComponent]
        let outputPipe = Pipe(); let errorPipe = Pipe()
        process.standardInput = inputHandle
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let outputDrain = CoreTestPipeDrain(outputPipe)
        let errorDrain = CoreTestPipeDrain(errorPipe)
        process.waitUntilExit()
        let outputData = outputDrain.data()
        let errorData = errorDrain.data()
        let outputString = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0,
                       "protoc must decode the bytes cleanly. stderr: \(String(data: errorData, encoding: .utf8) ?? "")")
        return outputString
    }
}
