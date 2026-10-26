import XCTest
@testable import MacScope

final class CalleeContractsPoisonReportTests: XCTestCase {
    func testImportIndirectAndFrameEscapeReasons() throws {
        func function(_ start: UInt64, _ operations: [(String, String)]) -> MacIRFunction {
            let rows = operations.enumerated().map { index, row in
                InstructionRow(address: start + UInt64(index * 4), bytes: "", mnemonic: row.0,
                    operands: row.1, hasBreakpoint: false, comment: nil)
            }
            return PseudocodePrinter().buildFunction(functionName: "fixture", startAddress: start, instructions: rows)
        }
        let imported = function(0x1000, [("bl", "_external_stub"), ("ret", "")])
        let indirect = function(0x2000, [("blr", "x12"), ("ret", "")])
        // sub sp,sp,#32; str x9,[sp,#16]; mov x29,sp; sub x0,x29,#16; ret
        let words: [UInt32] = [0xd10083ff, 0xf9000be9, 0x910003fd, 0xd10043a0, 0xd65f03c0]
        let data = Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } })
        let rows = ARM64Decoder(validateStructuredOperands: true).decode(data, baseAddress: 0x3000).map { InstructionRow(decoded: $0) }
        let escaped = PseudocodePrinter().buildFunction(functionName: "escaped", startAddress: 0x3000, instructions: rows)
        let unknown = function(0x4000, [("opaque", "x9"), ("ret", "")])
        let nonFrame = function(0x5000, [("str", "x9, [sp, #16]"), ("ret", "")])
        let open = function(0x6000, [("cbz", "x0, 0x9000"), ("ret", "")])
        let functions = [imported, indirect, escaped, unknown, nonFrame, open]
        let starts = Set(functions.map(\.startAddress))
        let before = MacIRIndirectTargetResolution.resolve(functions: functions, functionStarts: starts)
        let report = MacIRIndirectTargetResolution.poisonReport(functions: functions, functionStarts: starts)
        XCTAssertEqual(report.functions.map(\.firstRejectingReason), [
            "import: _external_stub", "indirect call", "escaped frame", "unknown IR", "non-frame store", "open control flow"
        ])
        XCTAssertTrue(report.functions.allSatisfy { !$0.visible })
        XCTAssertEqual(report.importPoisonWriterCounts, ["_external_stub": 1])
        XCTAssertEqual(MacIRIndirectTargetResolution.resolve(functions: functions, functionStarts: starts), before,
                       "diagnostics must not mutate resolution facts or behavior")
    }

    func testUnknownClassesAndCallBindingEscape() throws {
        func instruction(_ address: UInt64, _ mnemonic: String, _ operation: MacIROperation,
                         bytes: String = "") -> MacIRInstruction {
            MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: bytes,
                mnemonic: mnemonic, operands: ""), operation: operation)
        }
        let unknown = MacIRFunction(name: "unknown", startAddress: 0x1000, instructions: [
            instruction(0x1000, "opaque", .unknown(destination: nil, mnemonic: "unsupported-kind", operands: "")),
            instruction(0x1004, "ret", .returnValue(nil))
        ])
        let intrinsic = MacIRFunction(name: "intrinsic", startAddress: 0x2000, instructions: [
            instruction(0x2000, "custom", .intrinsic(destination: nil, name: "uncontracted", arguments: [])),
            instruction(0x2004, "ret", .returnValue(nil))
        ])
        let words: [UInt32] = [0xd10083ff, 0xf9000be9, 0xd65f03c0]
        let data = Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } })
        let rows = ARM64Decoder(validateStructuredOperands: true).decode(data, baseAddress: 0x3000).map { InstructionRow(decoded: $0) }
        var escaped = PseudocodePrinter().buildFunction(functionName: "escaped", startAddress: 0x3000, instructions: rows)
        let arguments = try XCTUnwrap(MacIRCallArguments([]))
        let frame = try XCTUnwrap(MacIRCallFrame(target: "_external", knownSignature: nil,
            controlInputs: .none, arguments: arguments,
            indirectResultPointer: .register(name: "sp", version: 1)))
        escaped.instructions[escaped.instructions.count - 1].source.address = 0x300c
        escaped.instructions.insert(instruction(0x3008, "bl", .call(frame: frame, result: nil)), at: 2)
        let direct = try XCTUnwrap(MacIRCallFrame(target: "0x2000", knownSignature: nil,
            controlInputs: .none, arguments: arguments))
        let caller = MacIRFunction(name: "caller", startAddress: 0x4000, instructions: [
            instruction(0x4000, "bl", .call(frame: direct, result: nil), bytes: "00 f8 ff 97"),
            instruction(0x4004, "ret", .returnValue(nil))
        ])
        var mixed = unknown
        mixed.startAddress = 0x5000
        mixed.instructions = [
            instruction(0x5000, "opaque", unknown.instructions[0].operation),
            instruction(0x5004, "custom", intrinsic.instructions[0].operation),
            instruction(0x5008, "ret", .returnValue(nil))
        ]
        let functions = [unknown, intrinsic, escaped, caller, mixed]
        let starts = Set(functions.map(\.startAddress))
        let before = MacIRIndirectTargetResolution.resolve(functions: functions, functionStarts: starts)
        let report = MacIRIndirectTargetResolution.poisonReport(functions: functions, functionStarts: starts)
        let unknownRow = try XCTUnwrap(report.unknownIRByClass.first { $0.classification.operationKind == "unknown" })
        XCTAssertEqual(unknownRow.classification.kind, "unsupported-kind")
        XCTAssertEqual(unknownRow.classification.mnemonic, "opaque")
        XCTAssertEqual(unknownRow.instructions, 2)
        XCTAssertEqual(unknownRow.functions, 2)
        XCTAssertEqual(unknownRow.first, 2)
        XCTAssertEqual(unknownRow.soleBlockerFunctions, [0x1000])
        XCTAssertTrue(unknownRow.flipIfModeled.isEmpty, "Memory-only modeling cannot close unknown control flow")
        let intrinsicRow = try XCTUnwrap(report.unknownIRByClass.first { $0.classification.operationKind == "intrinsic" })
        XCTAssertEqual(intrinsicRow.classification.kind, "uncontracted")
        XCTAssertEqual(intrinsicRow.classification.mnemonic, "custom")
        XCTAssertEqual(intrinsicRow.instructions, 2)
        XCTAssertEqual(intrinsicRow.functions, 2)
        XCTAssertEqual(intrinsicRow.first, 1)
        XCTAssertEqual(intrinsicRow.soleBlockerFunctions, [0x2000])
        XCTAssertEqual(intrinsicRow.flipIfModeled, [0x2000, 0x4000], "Fixpoint includes the newly visible caller")
        let sites = try XCTUnwrap(report.functions.first { $0.functionStart == 0x5000 }).unknownIR
        XCTAssertEqual(sites.map(\.address), [0x5000, 0x5004])
        XCTAssertEqual(sites.map(\.isFirst), [true, false])
        let frameFact = try XCTUnwrap(report.functions.first { $0.functionStart == 0x3000 })
        XCTAssertEqual(frameFact.firstRejectingReason, "escaped frame")
        XCTAssertTrue(frameFact.hasEscapedFrameWrite)
        XCTAssertFalse(frameFact.hasNonFrameStore)
        XCTAssertEqual(frameFact.firstFrameEscape?.shape, "call binding")
        XCTAssertEqual(frameFact.firstFrameEscape?.mnemonic, "bl")
        XCTAssertEqual(frameFact.firstFrameEscape?.address, 0x3008)
        XCTAssertEqual(MacIRIndirectTargetResolution.resolve(functions: functions, functionStarts: starts), before)
    }

}
