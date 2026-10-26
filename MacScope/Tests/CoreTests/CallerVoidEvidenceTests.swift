import XCTest
@testable import MacScope

/// Raw-image controls accompany every refusal: absence of xrefs is never authority.
final class CallerVoidEvidenceTests: XCTestCase {
    private typealias Op = (String, String, UInt32)
    private let discard: [Op] = [("mov", "x0, #0", 0xd2800000), ("ret", "", 0xd65f03c0)]

    private func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }

    private func fixture(second: [Op]? = nil, reference: [UInt32] = [],
                         pointer: UInt64? = nil, relative: Bool = false,
                         exported: Bool = false, trie: Bool = false,
                         chained: Bool = false, unsupportedFixup: Bool = false,
                         incomplete: Bool = false) -> WorkspaceSnapshot {
        var bytes = Data(repeating: 0, count: 0x6000)
        var commands = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { commands.append(contentsOf: $0) }
        }
        func name(_ value: String) {
            commands.append(contentsOf: value.utf8)
            commands.append(Data(repeating: 0, count: 16 - value.utf8.count))
        }
        func segment(_ segment: String, _ address: UInt64, _ size: UInt64,
                     _ sections: [(String, UInt64, UInt64, UInt32)]) {
            append(UInt32(0x19)); append(UInt32(72 + 80 * sections.count)); name(segment)
            append(address); append(size); append(address); append(size)
            append(UInt32(7)); append(UInt32(segment == "__TEXT" ? 5 : 3))
            append(UInt32(sections.count)); append(UInt32(0))
            for (section, start, count, flags) in sections {
                name(section); name(segment); append(start); append(count); append(UInt32(start))
                append(UInt32(2)); append(UInt32(0)); append(UInt32(0)); append(flags)
                append(UInt32(0)); append(UInt32(0)); append(UInt32(0))
            }
        }
        segment("__TEXT", 0, 0x4000, [("__text", 0x1000, 0x1300, 0x80000400),
                                      ("__const", 0x3000, 0x100, 0)])
        segment("__DATA_CONST", 0x4000, 0x1000, [("__const", 0x4000, 0x100, 0)])
        var commandCount: UInt32 = 2
        if exported {
            append(UInt32(2)); append(UInt32(24)); append(UInt32(0x5000)); append(UInt32(1))
            append(UInt32(0x5010)); append(UInt32(7)); commandCount += 1
            put(UInt32(1), at: 0x5000, in: &bytes)
            bytes[0x5004] = 0x0f; bytes[0x5005] = 1
            put(UInt64(0x1000), at: 0x5008, in: &bytes)
            bytes.replaceSubrange(0x5010..<0x5017, with: [0, 95, 108, 101, 97, 102, 0])
        }
        if trie {
            append(UInt32(0x80000033)); append(UInt32(16)); append(UInt32(0x5100)); append(UInt32(13))
            commandCount += 1
            bytes.replaceSubrange(0x5100..<0x510d, with: [0, 1, 108, 101, 97, 102, 0, 8, 3, 0, 0x80, 0x20, 0])
        }
        if chained || unsupportedFixup {
            append(UInt32(0x80000034)); append(UInt32(16)); append(UInt32(0x5200)); append(UInt32(64))
            commandCount += 1
            for (offset, value): (Int, UInt32) in [(4, 28), (8, 64), (12, 64), (20, 1), (28, 2), (36, 12), (40, 24)] {
                put(value, at: 0x5200 + offset, in: &bytes)
            }
            put(UInt16(4096), at: 0x522c, in: &bytes)
            put(UInt16(unsupportedFixup ? 99 : 6), at: 0x522e, in: &bytes)
            put(UInt64(0x4000), at: 0x5230, in: &bytes)
            put(UInt16(1), at: 0x523c, in: &bytes)
            put(UInt64(0x1000), at: 0x4000, in: &bytes)
        }
        put(UInt32(0xfeedfacf), at: 0, in: &bytes); put(UInt32(0x0100000c), at: 4, in: &bytes)
        put(UInt32(2), at: 12, in: &bytes); put(commandCount, at: 16, in: &bytes)
        put(UInt32(commands.count), at: 20, in: &bytes)
        bytes.replaceSubrange(32..<(32 + commands.count), with: commands)
        var analysis = ImageAnalysis()
        func function(_ start: UInt64, _ name: String, _ ops: [Op]) {
            analysis.functions.append(FunctionSummary(id: UUID(), name: name, startAddress: start,
                endAddress: start + UInt64(ops.count * 4), confidence: 1))
            for (index, op) in ops.enumerated() {
                let address = start + UInt64(index * 4)
                put(op.2, at: Int(address), in: &bytes)
                analysis.instructions.append(InstructionRow(address: address, bytes: String(format: "%08x", op.2),
                    mnemonic: op.0, operands: op.1, hasBreakpoint: false, comment: nil))
            }
        }
        function(0x1000, "copy_leaf", [("ldr", "x8, [x0]", 0xf9400008),
            ("str", "x8, [x1]", 0xf9000028), ("ret", "", 0xd65f03c0)])
        function(0x2000, "caller_a", [("bl", "0x1000", 0x97fffc00)] + discard)
        function(0x2100, "caller_b", [("bl", "0x1000", 0x97fffbc0)] + (second ?? discard))
        function(0x2200, "reference", Array(repeating: ("nop", "", 0xd503201f), count: 8))
        for (index, word) in reference.enumerated() { put(word, at: 0x2200 + index * 4, in: &bytes) }
        if let pointer { put(pointer, at: 0x4000, in: &bytes) }
        if relative { put(Int32(-0x2000), at: 0x3000, in: &bytes) }
        if incomplete { bytes = Data(bytes.prefix(0x4080)) }
        analysis.imageBytes = bytes
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "fixture", path: "/fixture/caller-consumption",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        return snapshot
    }

    private func functions(_ value: WorkspaceSnapshot) -> [MacIRFunction] {
        value.functions.map { summary in
            MacIRBuilder().buildFunction(name: summary.name, startAddress: summary.startAddress,
                instructions: value.instructions.filter { $0.address >= summary.startAddress && $0.address < summary.endAddress })
        }
    }

    private func consumption(_ value: WorkspaceSnapshot, caller: UInt64 = 0x2100) -> CallSiteContract.Consumption? {
        MacIRCallerReturnEvidence.collectCallSites(functions: functions(value))[caller]?.first?.consumption
    }

    private func index(_ value: WorkspaceSnapshot) throws -> FunctionAddressTakenIndex {
        FunctionAddressTakenIndex(image: try MachOParser().parse(value.imageBytes),
            bytes: value.imageBytes, functions: value.functions)
    }

    private func positive(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(consumption(fixture(), caller: 0x2000), .discarded, file: file, line: line)
        XCTAssertEqual(consumption(fixture()), .discarded, file: file, line: line)
    }

    func testTwoDiscardingCallersRecordDiscardWithoutInferringVoid() { positive() }
    func testOneW0ReaderKeepsExistingWidthEvidence() {
        positive()
        XCTAssertEqual(consumption(fixture(second: [("mov", "w9, w0", 0x2a0003e9)] + discard)), .read(width: 32, type: nil))
    }
    func testExternalSymbolAndExportTrieRemainExternal() throws {
        for value in [fixture(exported: true), fixture(trie: true)] {
            let image = try MachOParser().parse(value.imageBytes)
            XCTAssertTrue(image.exportRecoveryComplete)
            XCTAssertTrue(image.exports.contains { $0.address == 0x1000 })
        }
    }
    func testKnownByteIndexFacts() throws {
        positive()
        for value in [fixture(reference: [0x10ff7008]),
                      fixture(reference: [0xf0ffffe8, 0x91000109]),
                      fixture(reference: [0xf0ffffe8, 0xf9400109]),
                      fixture(reference: [0x17fffb80]),
                      fixture(pointer: 0x1000), fixture(relative: true), fixture(chained: true)] {
            let image = try MachOParser().parse(value.imageBytes)
            let result = FunctionAddressTakenIndex(image: image, bytes: value.imageBytes, functions: value.functions)
            XCTAssertTrue(image.exportRecoveryComplete)
            XCTAssertTrue(result.isComplete)
            XCTAssertTrue(result.contains(0x1000))
        }
        let chained = fixture(chained: true)
        let image = try MachOParser().parse(chained.imageBytes)
        XCTAssertEqual(image.dyldChainedFixups?.fixups.first?.rebaseTargetAddress, 0x1000)
    }
    func testIncompleteImageAndUnsupportedFixupFailClosed() throws {
        for value in [fixture(incomplete: true), fixture(unsupportedFixup: true)] {
            let result = try index(value)
            XCTAssertFalse(result.isComplete)
            XCTAssertTrue(value.functions.allSatisfy { result.contains($0.startAddress) })
        }
    }
    func testUnknownCallerEffectRefusesDiscard() {
        positive()
        XCTAssertEqual(consumption(fixture(second: [("opaque", "x0", 0), ("ret", "", 0xd65f03c0)])), .unknown)
    }
    func testLiveAtReturnFlowsAndUnknownCallRefusesDiscard() {
        positive()
        XCTAssertEqual(consumption(fixture(second: [("ret", "", 0xd65f03c0)])), .flowsToReturn)
        XCTAssertEqual(consumption(fixture(second: [("bl", "0x9000", 0x94001bbf), ("ret", "", 0xd65f03c0)])), .unknown)
    }
    func testCopyReadBeforeOverwriteIsValueConsumption() {
        positive()
        XCTAssertEqual(consumption(fixture(second: [("mov", "x9, x0", 0xaa0003e9)] + discard)), .read(width: 64, type: nil))
    }
    func testPairLoadOverwriteStopsRawResultLifetime() throws {
        let result = MacIRValue.register(name: "x0", version: 1)
        let loaded = MacIRValue.register(name: "w0", version: 2)
        let other = MacIRValue.register(name: "w6", version: 1)
        let arguments = try XCTUnwrap(MacIRCallArguments([]))
        let frame = try XCTUnwrap(MacIRCallFrame(target: "0x1000", knownSignature: nil,
            controlInputs: .none, arguments: arguments))
        func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
                         _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: .init(address: address, byteText: "", mnemonic: mnemonic,
                operands: operands), operation: operation)
        }
        for readsOldResult in [false, true] {
            let base: MacIRValue = readsOldResult ? result : .argument(bindingID: .gpr(4))
            let caller = MacIRFunction(name: "caller", startAddress: 0x2000, instructions: [
                instruction(0x2000, "bl", "0x1000", .call(frame: frame, result: result)),
                instruction(0x2004, "nop", "", .intrinsic(destination: nil, name: "nop", arguments: [])),
                instruction(0x2008, "ldp", readsOldResult ? "w0, w6, [x0]" : "w0, w6, [x4]",
                    .intrinsic(destination: nil, name: "restore_pair", arguments: [loaded, other, base])),
                instruction(0x200c, "sxtw", "x0, w0", .assign(destination: .register(name: "x0", version: 3),
                    source: .unary(op: "(int32_t)", value: loaded))),
                instruction(0x2010, "ret", "", .returnValue(nil))
            ])
            let leaf = MacIRFunction(name: "leaf", startAddress: 0x1000, instructions: [])
            let site = try XCTUnwrap(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first)
            XCTAssertEqual(site.consumption, readsOldResult ? .read(width: 64, type: nil) : .discarded)
        }
    }
    func testUnmodeledInstructionBeforeReadRemainsUnknown() throws {
        let result = MacIRValue.register(name: "x0", version: 1)
        let arguments = try XCTUnwrap(MacIRCallArguments([]))
        let frame = try XCTUnwrap(MacIRCallFrame(target: "0x1000", knownSignature: nil,
            controlInputs: .none, arguments: arguments))
        func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
                         _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: .init(address: address, byteText: "", mnemonic: mnemonic,
                operands: operands), operation: operation)
        }
        let caller = MacIRFunction(name: "caller", startAddress: 0x2000, instructions: [
            instruction(0x2000, "bl", "0x1000", .call(frame: frame, result: result)),
            instruction(0x2004, "opaque", "", .intrinsic(destination: nil, name: "opaque", arguments: [])),
            instruction(0x2008, "mov", "x9, x0", .assign(destination: .register(name: "x9", version: 1), source: result)),
            instruction(0x200c, "ret", "", .returnValue(nil))
        ])
        let leaf = MacIRFunction(name: "leaf", startAddress: 0x1000, instructions: [])
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first?.consumption, .unknown)
    }

    func testOpaqueLiveContinuationOverridesEarlierRead() throws {
        let result = MacIRValue.register(name: "x0", version: 1)
        let arguments = try XCTUnwrap(MacIRCallArguments([]))
        let frame = try XCTUnwrap(MacIRCallFrame(target: "0x1000", knownSignature: nil,
            controlInputs: .none, arguments: arguments))
        func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
                         _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: .init(address: address, byteText: "", mnemonic: mnemonic,
                operands: operands), operation: operation)
        }
        let leaf = MacIRFunction(name: "leaf", startAddress: 0x1000, instructions: [])
        for hasSSAResult in [false, true] {
            for endsLifetime in [false, true] {
                let boundary = endsLifetime
                    ? instruction(0x2008, "mov", "x0, #0", .assign(destination: .register(name: "x0", version: 2), source: .immediate(0)))
                    : instruction(0x2008, "nop", "", .intrinsic(destination: nil, name: "nop", arguments: []))
                let caller = MacIRFunction(name: "continuation", startAddress: 0x2000, instructions: [
                    instruction(0x2000, "bl", "0x1000", .call(frame: frame, result: hasSSAResult ? result : nil)),
                    instruction(0x2004, "mov", "x9, x0", .assign(destination: .register(name: "x9", version: 1), source: result)),
                    boundary,
                    instruction(0x200c, "opaque", "", .intrinsic(destination: nil, name: "opaque", arguments: [])),
                    instruction(0x2010, "ret", "", .returnValue(nil))
                ])
                XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first?.consumption,
                    endsLifetime ? .read(width: 64, type: nil) : .unknown)
            }
        }
        let split = MacIRFunction(name: "split", startAddress: 0x2000, instructions: [
            instruction(0x2000, "bl", "0x1000", .call(frame: frame, result: result)),
            instruction(0x2004, "mov", "x9, x0", .assign(destination: .register(name: "x9", version: 1), source: result)),
            instruction(0x2008, "cbz", "x1, 0x2014", .conditionalBranch(condition: "==",
                left: .argument(bindingID: .gpr(1)), right: .immediate(0), target: .immediate(0x2014))),
            instruction(0x200c, "opaque", "", .intrinsic(destination: nil, name: "opaque", arguments: [])),
            instruction(0x2010, "ret", "", .returnValue(nil)),
            instruction(0x2014, "ret", "", .returnValue(nil))
        ])
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, split])[0x2000]?.first?.consumption, .unknown)
    }

    func testMergedCarrierDefinitionsRefuseRead() throws {
        let result = MacIRValue.register(name: "x0", version: 1)
        let replacement = MacIRValue.register(name: "x0", version: 2)
        let arguments = try XCTUnwrap(MacIRCallArguments([]))
        let frame = try XCTUnwrap(MacIRCallFrame(target: "0x1000", knownSignature: nil,
            controlInputs: .none, arguments: arguments))
        func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
                         _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: .init(address: address, byteText: "", mnemonic: mnemonic,
                operands: operands), operation: operation)
        }
        let leaf = MacIRFunction(name: "leaf", startAddress: 0x1000, instructions: [])
        let alternatives: [(String, String, MacIROperation, CallSiteContract.Consumption)] = [
            ("nop", "", .intrinsic(destination: nil, name: "nop", arguments: []), .read(width: 64, type: nil)),
            ("mov", "x0, #7", .assign(destination: replacement, source: .immediate(7)), .unknown),
            ("opaque", "", .intrinsic(destination: nil, name: "opaque", arguments: []), .unknown)
        ]
        for (mnemonic, operands, operation, expected) in alternatives {
            let caller = MacIRFunction(name: "diamond", startAddress: 0x2000, instructions: [
                instruction(0x2000, "bl", "0x1000", .call(frame: frame, result: result)),
                instruction(0x2004, "cbz", "x1, 0x2010", .conditionalBranch(condition: "==",
                    left: .argument(bindingID: .gpr(1)), right: .immediate(0), target: .immediate(0x2010))),
                instruction(0x2008, mnemonic, operands, operation),
                instruction(0x200c, "b", "0x2014", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x2014)])),
                instruction(0x2010, "nop", "", .intrinsic(destination: nil, name: "nop", arguments: [])),
                instruction(0x2014, "mov", "x9, x0", .assign(destination: .register(name: "x9", version: 1), source: result)),
                instruction(0x2018, "mov", "x0, #0", .assign(destination: replacement, source: .immediate(0))),
                instruction(0x201c, "ret", "", .returnValue(nil))
            ])
            XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first?.consumption,
                expected, mnemonic)
        }
        // The immediate raw-register shortcut has the same obligation, even
        // when the call result has no SSA value and a backedge reaches BL + 4.
        for hasSSAResult in [false, true] {
            let caller = MacIRFunction(name: "backedge", startAddress: 0x2000, instructions: [
                instruction(0x2000, "bl", "0x1000", .call(frame: frame, result: hasSSAResult ? result : nil)),
                instruction(0x2004, "mov", "x9, x0", .assign(destination: .register(name: "x9", version: 1), source: result)),
                instruction(0x2008, "mov", "x0, #7", .assign(destination: replacement, source: .immediate(7))),
                instruction(0x200c, "b", "0x2004", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x2004)]))
            ])
            XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first?.consumption,
                .unknown, "SSA result: \(hasSSAResult)")
        }
    }

    func testIncompleteExportRecoveryRefusesClosure() throws {
        var value = fixture(exported: true)
        var bytes = value.imageBytes
        put(UInt32(0), at: 0x5000, in: &bytes)
        value.imageBytes = bytes
        let image = try MachOParser().parse(bytes)
        XCTAssertFalse(image.exportRecoveryComplete)
        XCTAssertTrue(image.exports.isEmpty)
    }
    func testExternalDebugSymbolAndDuplicateTablesFailClosed() throws {
        let debug = fixture(exported: true)
        var debugBytes = debug.imageBytes
        debugBytes[0x5004] = 0xef
        XCTAssertFalse(try MachOParser().parse(debugBytes).exportRecoveryComplete)

        var duplicate = fixture(exported: true)
        var bytes = duplicate.imageBytes
        let commandsSize = (0..<4).reduce(0) { $0 | Int(bytes[20 + $1]) << ($1 * 8) }
        let count = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[16 + $1]) << ($1 * 8) }
        let offset = 32 + commandsSize
        put(UInt32(2), at: offset, in: &bytes)
        put(UInt32(24), at: offset + 4, in: &bytes)
        put(count + 1, at: 16, in: &bytes)
        put(UInt32(commandsSize + 24), at: 20, in: &bytes)
        duplicate.imageBytes = bytes
        let image = try MachOParser().parse(bytes)
        XCTAssertTrue(image.exports.isEmpty)
        let result = FunctionAddressTakenIndex(image: image, bytes: bytes, functions: duplicate.functions)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(duplicate.functions.allSatisfy { result.contains($0.startAddress) })
    }
    func testMalformedChainedSegmentIsIncomplete() throws {
        positive()
        let value = fixture(chained: true)
        var image = try MachOParser().parse(value.imageBytes)
        image.segments[1].fileOffset = UInt64.max
        let result = FunctionAddressTakenIndex(image: image, bytes: value.imageBytes, functions: value.functions)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(value.functions.allSatisfy { result.contains($0.startAddress) })
    }
    func testMissingRawCallerRemainsVisibleInIndex() throws {
        var missing = fixture()
        missing.functions.removeAll { $0.startAddress == 0x2100 }
        missing.instructions.removeAll { (0x2100..<0x2110).contains($0.address) }
        XCTAssertEqual(try index(missing).directCalls[0x1000], [0x2000, 0x2100])
        XCTAssertNil(MacIRCallerReturnEvidence.collectCallSites(functions: functions(missing))[0x2100])
    }
    func testEverySuccessorMustOverwriteForDiscard() {
        XCTAssertEqual(consumption(fixture(second: [("cbz", "x19, 0x2110", 0xb4000073),
            ("mov", "x0, #0", 0xd2800000), ("ret", "", 0xd65f03c0), ("ret", "", 0xd65f03c0)])), .flowsToReturn)
        XCTAssertEqual(consumption(fixture(second: [("cbz", "x19, 0x2110", 0xb4000073),
            ("mov", "x0, #0", 0xd2800000), ("ret", "", 0xd65f03c0),
            ("mov", "w0, #0", 0x52800000), ("ret", "", 0xd65f03c0)])), .discarded)
        XCTAssertEqual(consumption(fixture(second: [("cbz", "x19, 0x2104", 0xb4000013)] + discard)), .unknown)
    }
    func testLoopBeforeOverwriteRefusesDiscard() {
        XCTAssertEqual(consumption(fixture(second: [("cbz", "x2, 0x2104", 0xb4000002)] + discard)), .unknown)
    }
    func testConditionalTailBranchesAreAddressTaken() throws {
        for word: UInt32 in [0x54ff7000, 0xb4ff7002, 0x36077002] {
            XCTAssertTrue(try index(fixture(reference: [word])).contains(0x1000))
        }
    }
    func testExplicitEscapesAndPhiAfterOverwriteRefuseDiscard() throws {
        positive()
        let lifted = functions(fixture())
        var caller = try XCTUnwrap(lifted.first { $0.startAddress == 0x2000 })
        let leaf = try XCTUnwrap(lifted.first { $0.startAddress == 0x1000 })
        guard case let .call(_, result?) = caller.instructions[0].operation else { return XCTFail("call result missing") }
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first?.consumption, .discarded)
        caller.instructions[2].operation = .returnValue(.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first?.consumption, .discarded)
        caller.instructions[2].operation = .returnValue(.unknown("opaque return"))
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first?.consumption, .unknown)
        caller.instructions[2].operation = .returnValue(result)
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first?.consumption, .unknown)
        caller.instructions[2].operation = .returnValue(.immediate(0))
        caller.phis = [MacIRPhi(blockAddress: 0x2008, destination: .temporary(999), bitWidth: 64,
            incoming: [.init(predecessorAddress: 0x2004, value: result)])]
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first?.consumption, .unknown)
    }
    func testUnavailableImageFactsFailClosed() {
        var analysis = ImageAnalysis()
        analysis.functions = fixture().functions
        let facts = MacIRCallerReturnEvidence.buildImageFacts(analysis: analysis, functions: [])
        XCTAssertFalse(facts.imageComplete)
        XCTAssertEqual(facts.addressTaken, Set(analysis.functions.map(\.startAddress)))
        XCTAssertEqual(facts.closedWorldGuards["image_or_function_inventory_unavailable_or_capped"], false)
    }
    func testUnreachableTailDoesNotCreateAContractEdge() {
        let caller = MacIRFunction(name: "caller", startAddress: 0x2000, instructions: [
            MacIRInstruction(source: MacIRSourceSpan(address: 0x2000, byteText: "", mnemonic: "ret", operands: ""),
                operation: .returnValue(nil)),
            MacIRInstruction(source: MacIRSourceSpan(address: 0x2004, byteText: "", mnemonic: "b", operands: "0x1000"),
                operation: .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x1000)]))
        ])
        let leaf = MacIRFunction(name: "leaf", startAddress: 0x1000, instructions: [])
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000], [])
    }
    func testMixedRawRegisterViewsPreserveWholeTargetWidth() {
        let value = fixture(second: [("mov", "w9, w0", 0x2a0003e9)] + discard)
        var lifted = functions(value)
        let operations = [("bl", "0x1000"), ("ldr", "x9, [x0]"), ("ret", "")]
        let rows = operations.enumerated().map { index, operation in
            InstructionRow(address: 0x3000 + UInt64(index * 4), bytes: "", mnemonic: operation.0,
                operands: operation.1, hasBreakpoint: false, comment: nil)
        }
        lifted.append(MacIRBuilder().buildFunction(name: "wide", startAddress: 0x3000, instructions: rows))
        let widths = MacIRCallerReturnEvidence.collect(functions: lifted)
        XCTAssertEqual(widths[0x1000], .x0)
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: lifted, callerWidths: widths)[0x2100]?.first?.consumption,
            .read(width: 64, type: nil))
    }

    func testConflictingTypedConsumersPreserveTerminalTypeDisagreement() throws {
        let result = MacIRValue.register(name: "x0", version: 1)
        let emptyArguments = try XCTUnwrap(MacIRCallArguments([]))
        let calleeFrame = try XCTUnwrap(MacIRCallFrame(target: "0x1000", knownSignature: nil,
            controlInputs: .none, arguments: emptyArguments))
        func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
            _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: "", mnemonic: mnemonic,
                operands: operands), operation: operation)
        }
        func consumer(_ address: UInt64, _ target: String, _ type: String) throws -> MacIRInstruction {
            let arguments = try XCTUnwrap(MacIRCallArguments([MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: 64), role: .fixed(sourcePosition: 0), value: result)]))
            let signature = MacIRCallSignature(target: target, returnType: "void", parameters: [
                MacIRCallParameter(index: 0, register: "x0", type: type)])
            let frame = try XCTUnwrap(MacIRCallFrame(target: target, knownSignature: signature,
                controlInputs: .none, arguments: arguments))
            return instruction(address, "bl", target, .call(frame: frame, result: nil))
        }
        for secondType in ["char *", "int *"] {
            let caller = MacIRFunction(name: "split", startAddress: 0x2000, instructions: [
                instruction(0x2000, "bl", "0x1000", .call(frame: calleeFrame, result: result)),
                instruction(0x2004, "cbz", "x1, 0x2010", .conditionalBranch(condition: "==",
                    left: .argument(bindingID: .gpr(1)), right: .immediate(0), target: .immediate(0x2010))),
                try consumer(0x2008, "_consume_first", "int *"),
                instruction(0x200c, "ret", "", .returnValue(nil)),
                try consumer(0x2010, "_consume_second", secondType),
                instruction(0x2014, "ret", "", .returnValue(nil))
            ])
            let leaf = MacIRFunction(name: "leaf", startAddress: 0x1000, instructions: [])
            let site = try XCTUnwrap(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller])[0x2000]?.first)
            XCTAssertEqual(site.consumption, .read(width: 64, type: secondType == "int *" ? "int *" : nil))
            XCTAssertEqual(site.typeDisputed, secondType != "int *")
            XCTAssertEqual(site.consumerTypes, Array(Set(["int *", secondType])).sorted())
        }
    }

    func testTypedFixedConsumerUsesDeclaredCarrierWidthWithoutChangingLegacyCollector() throws {
        let result = MacIRValue.register(name: "x0", version: 1)
        let scenarios: [(Int, MacIRValue, Bool, Int)] = [
            (32, result, false, 32),
            (32, .unary(op: "(uint32_t)", value: result), false, 32),
            (64, result, false, 64),
            (32, .unary(op: "(uint32_t)", value: .binaryExpression(op: "+", left: result, right: .immediate(1))), false, 64),
            (32, result, true, 64)
        ]
        for (carrierWidth, value, hasControlRead, expectedWidth) in scenarios {
            let producerArguments = try XCTUnwrap(MacIRCallArguments([]))
            let producer = try XCTUnwrap(MacIRCallFrame(target: "0x1000", knownSignature: nil,
                controlInputs: .none, arguments: producerArguments))
            let register = carrierWidth == 32 ? "w0" : "x0"
            let type = carrierWidth == 32 ? "int" : "int64_t"
            let arguments = try XCTUnwrap(MacIRCallArguments([MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: carrierWidth), role: .fixed(sourcePosition: 0), value: value)]))
            let signature = MacIRCallSignature(target: "_consume_fixed", returnType: "void", parameters: [
                MacIRCallParameter(index: 0, register: register, type: type)])
            let consumer = try XCTUnwrap(MacIRCallFrame(target: "_consume_fixed", knownSignature: signature,
                controlInputs: .none, arguments: arguments))
            func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
                _ operation: MacIROperation) -> MacIRInstruction {
                MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: "", mnemonic: mnemonic,
                    operands: operands), operation: operation)
            }
            var consumingCall = instruction(0x2004, "bl", "_consume_fixed", .call(frame: consumer, result: nil))
            if hasControlRead { consumingCall.returnTarget = result }
            let caller = MacIRFunction(name: "typed_caller", startAddress: 0x2000, instructions: [
                instruction(0x2000, "bl", "0x1000", .call(frame: producer, result: result)), consumingCall,
                instruction(0x2008, "ret", "", .returnValue(nil))
            ])
            let leaf = MacIRFunction(name: "leaf", startAddress: 0x1000, instructions: [])
            let legacy = MacIRCallerReturnEvidence.collect(functions: [leaf, caller])
            XCTAssertNil(legacy[0x1000], "typed-call arguments must not add legacy witnesses")
            let site = try XCTUnwrap(MacIRCallerReturnEvidence.collectCallSites(functions: [leaf, caller],
                callerWidths: legacy)[0x2000]?.first)
            XCTAssertEqual(site.consumption, .read(width: expectedWidth, type: type))
            XCTAssertFalse(site.typeDisputed)
        }
    }

}
