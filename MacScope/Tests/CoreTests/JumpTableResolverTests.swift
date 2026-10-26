import XCTest
@testable import MacScope

final class JumpTableResolverTests: XCTestCase {
    // Executable text range shared by the synthetic fixtures.
    private let codeRange = JumpTableResolver.CodeRange(
        lowerBound: 0x1000_0000,
        upperBound: 0x1000_1000
    )

    /// A closure-backed byte reader over a dictionary of [virtualAddress: bytes].
    private func reader(_ table: [UInt64: [UInt8]]) -> JumpTableResolver.ByteReader {
        { virtualAddress, count in
            guard let bytes = table[virtualAddress], bytes.count >= count else { return nil }
            return Data(bytes.prefix(count))
        }
    }

    private func le32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [
            UInt8(bits & 0xff),
            UInt8((bits >> 8) & 0xff),
            UInt8((bits >> 16) & 0xff),
            UInt8((bits >> 24) & 0xff)
        ]
    }

    private func le64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * $0)) & 0xff) }
    }

    /// Little-endian helper for 16-bit values.
    private func le16(_ value: UInt16) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff)
        ]
    }

    /// Little-endian helper for 8-bit values.
    private func le8(_ value: UInt8) -> [UInt8] {
        [value]
    }

    private func row(
        _ address: UInt64,
        _ mnemonic: String,
        _ operands: String
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: nil
        )
    }

    /// The canonical signed-4-byte dispatch idiom, using numerically resolved
    /// adrp/add operands (the form the decoder actually emits).
    private func signedOffsetRows(
        base: UInt64,
        brAddress: UInt64,
        boundN: Int64
    ) -> [InstructionRow] {
        let page = base & ~0xfff
        let lo12 = base & 0xfff
        return [
            row(brAddress &- 0x18, "cmp", "w0, #0x\(String(boundN, radix: 16))"),
            row(brAddress &- 0x14, "b.hi", "0x10000900"),
            row(brAddress &- 0x10, "adrp", "x8, 0x\(String(page, radix: 16))"),
            row(brAddress &- 0x0c, "add", "x8, x8, #0x\(String(lo12, radix: 16))"),
            row(brAddress &- 0x08, "ldrsw", "x9, [x8, w0, lsl #2]"),
            row(brAddress &- 0x04, "add", "x8, x8, x9"),
            row(brAddress, "br", "x8")
        ]
    }

    func testSignedOffsetHappyPath() {
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let targets: [UInt64] = [0x1000_0040, 0x1000_0048, 0x1000_0050, 0x1000_0058]
        let rows = signedOffsetRows(base: base, brAddress: brAddress, boundN: 3)
        var bytes: [UInt64: [UInt8]] = [:]
        for (i, target) in targets.enumerated() {
            let offset = Int32(Int64(bitPattern: target) - Int64(bitPattern: base))
            bytes[base + UInt64(i * 4)] = le32(offset)
        }

        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertEqual(result, [brAddress: targets])
    }

    func testSignedOffsetSupportsNegativeOffsets() {
        // A case block sitting BEFORE the table proves sign-extension is correct.
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let target: UInt64 = 0x1000_0010 // base - 0x7f0
        let rows = signedOffsetRows(base: base, brAddress: brAddress, boundN: 0)
        let offset = Int32(Int64(bitPattern: target) - Int64(bitPattern: base))
        let bytes: [UInt64: [UInt8]] = [base: le32(offset)]

        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertEqual(result, [brAddress: [target]])
    }

    func testAbsolute64HappyPath() {
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let targets: [UInt64] = [0x1000_0300, 0x1000_0400, 0x1000_0500]
        let rows = [
            row(brAddress &- 0x18, "mov", "w0, w0"),
            row(brAddress &- 0x14, "cmp", "w0, #0x2"),
            row(brAddress &- 0x10, "b.hi", "0x10000900"),
            row(brAddress &- 0x0c, "adrp", "x8, 0x\(String(base & ~0xfff, radix: 16))"),
            row(brAddress &- 0x08, "add", "x8, x8, #0x\(String(base & 0xfff, radix: 16))"),
            row(brAddress &- 0x04, "ldr", "x9, [x8, x0, lsl #3]"),
            row(brAddress, "br", "x9")
        ]
        var bytes: [UInt64: [UInt8]] = [:]
        for (i, target) in targets.enumerated() {
            bytes[base + UInt64(i * 8)] = le64(target)
        }

        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertEqual(result, [brAddress: targets])
    }

    func testBailsWhenTargetOutsideCodeRange() {
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let rows = signedOffsetRows(base: base, brAddress: brAddress, boundN: 1)
        // First entry valid, second resolves to 0x20000000 (outside the range).
        let bytes: [UInt64: [UInt8]] = [
            base: le32(Int32(Int64(0x1000_0040) - Int64(base))),
            base + 4: le32(Int32(truncatingIfNeeded: Int64(0x2000_0000) - Int64(base)))
        ]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBailsWhenTargetUnaligned() {
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let rows = signedOffsetRows(base: base, brAddress: brAddress, boundN: 0)
        // Target 0x10000042 is not 4-byte aligned.
        let bytes: [UInt64: [UInt8]] = [base: le32(Int32(Int64(0x1000_0042) - Int64(base)))]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBailsWhenReaderReturnsNil() {
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let rows = signedOffsetRows(base: base, brAddress: brAddress, boundN: 2)
        // Only the first two of three entries are available.
        let bytes: [UInt64: [UInt8]] = [
            base: le32(Int32(Int64(0x1000_0040) - Int64(base))),
            base + 4: le32(Int32(Int64(0x1000_0044) - Int64(base)))
        ]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBailsWhenBoundsMissing() {
        // No cmp -> entry count unknown -> refuse to read an unbounded table.
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let rows = [
            row(brAddress &- 0x10, "adrp", "x8, 0x\(String(base & ~0xfff, radix: 16))"),
            row(brAddress &- 0x0c, "add", "x8, x8, #0x\(String(base & 0xfff, radix: 16))"),
            row(brAddress &- 0x08, "ldrsw", "x9, [x8, w0, lsl #2]"),
            row(brAddress &- 0x04, "add", "x8, x8, x9"),
            row(brAddress, "br", "x8")
        ]
        let bytes: [UInt64: [UInt8]] = [base: le32(0x40)]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBailsOnRegisterMismatch() {
        // Load base x7 while the table base was formed in x8.
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let rows = [
            row(brAddress &- 0x18, "cmp", "w0, #0x1"),
            row(brAddress &- 0x14, "b.hi", "0x10000900"),
            row(brAddress &- 0x10, "adrp", "x8, 0x\(String(base & ~0xfff, radix: 16))"),
            row(brAddress &- 0x0c, "add", "x8, x8, #0x\(String(base & 0xfff, radix: 16))"),
            row(brAddress &- 0x08, "ldrsw", "x9, [x7, w0, lsl #2]"),
            row(brAddress &- 0x04, "add", "x8, x8, x9"),
            row(brAddress, "br", "x8")
        ]
        let bytes: [UInt64: [UInt8]] = [base: le32(0x40), base + 4: le32(0x44)]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBailsOnSymbolicPageOffBase() {
        // The committed builder fixture uses _jt@PAGE / _jt@PAGEOFF, which carry
        // no numeric immediate: the table base is unresolved, so the resolver
        // bails (the builder is fed targets directly in its own tests).
        let brAddress: UInt64 = 0x1000_0020
        let rows = [
            row(brAddress &- 0x18, "cmp", "w0, #0x2"),
            row(brAddress &- 0x14, "b.hi", "0x10000900"),
            row(brAddress &- 0x10, "adrp", "x8, _jt@PAGE"),
            row(brAddress &- 0x0c, "add", "x8, x8, _jt@PAGEOFF"),
            row(brAddress &- 0x08, "ldrsw", "x9, [x8, w0, lsl #2]"),
            row(brAddress &- 0x04, "add", "x8, x8, x9"),
            row(brAddress, "br", "x8")
        ]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader([:]),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testPlainIndirectBranchHasNoIdiom() {
        let rows = [row(0x1000_0020, "br", "x9")]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader([:]),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBailsOnInconsistentShiftWidth() {
        // ldr (8-byte) with lsl #2 (4-byte stride) is an inconsistent encoding.
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let rows = [
            row(brAddress &- 0x18, "mov", "w0, w0"),
            row(brAddress &- 0x14, "cmp", "w0, #0x1"),
            row(brAddress &- 0x10, "b.hi", "0x10000900"),
            row(brAddress &- 0x0c, "adrp", "x8, 0x\(String(base & ~0xfff, radix: 16))"),
            row(brAddress &- 0x08, "add", "x8, x8, #0x\(String(base & 0xfff, radix: 16))"),
            row(brAddress &- 0x04, "ldr", "x9, [x8, x0, lsl #2]"),
            row(brAddress, "br", "x9")
        ]
        let bytes: [UInt64: [UInt8]] = [base: le64(0x1000_0300), base + 8: le64(0x1000_0400)]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testResolvesTwoIndependentSitesInOneFunction() {
        let baseA: UInt64 = 0x1000_0700
        let brA: UInt64 = 0x1000_0020
        let baseB: UInt64 = 0x1000_0900
        let brB: UInt64 = 0x1000_0060
        var rows = signedOffsetRows(base: baseA, brAddress: brA, boundN: 0)
        // A control-flow boundary separates the two straight-line dispatch runs
        // so neither backward scan crosses the other site's br.
        rows.append(row(brA &+ 0x04, "ret", ""))
        rows.append(contentsOf: signedOffsetRows(base: baseB, brAddress: brB, boundN: 0))
        let targetA: UInt64 = 0x1000_0040
        let targetB: UInt64 = 0x1000_00c0
        let bytes: [UInt64: [UInt8]] = [
            baseA: le32(Int32(Int64(targetA) - Int64(baseA))),
            baseB: le32(Int32(Int64(targetB) - Int64(baseB)))
        ]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertEqual(result, [brA: [targetA], brB: [targetB]])
    }

    /// The resolver's [UInt64: [UInt64]] output feeds the committed
    /// MacIRBuilder seam end-to-end (no Mach-O needed).
    func testResolverOutputDrivesBuilderSwitchDispatch() {
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let targets: [UInt64] = [0x1000_0040, 0x1000_0048]
        let rows = signedOffsetRows(base: base, brAddress: brAddress, boundN: 1)
        var bytes: [UInt64: [UInt8]] = [:]
        for (i, target) in targets.enumerated() {
            bytes[base + UInt64(i * 4)] = le32(Int32(Int64(target) - Int64(base)))
        }

        let resolved = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertEqual(resolved, [brAddress: targets])

        let function = MacIRBuilder().buildFunction(
            name: "_switch_from_resolver",
            jumpTables: resolved,
            instructions: rows
        )
        let document = PseudocodePrinter().print(function: function)
        XCTAssertTrue(document.text.contains("switch ("))
        GotoLabelWellFormednessTests.assertTransfer(document.text, target: 0x10000040, condition: "case 0x0:")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        GotoLabelWellFormednessTests.assertTransfer(document.text, target: 0x10000048, condition: "case 0x1:")
        XCTAssertFalse(document.text.contains("__branch_register"))
    }

    /// Tier 1.3: a `br` jump-table dispatch seeds each in-text case target as a basic-block
    /// LEADER and emits a `switch` successor EDGE to each distinct target (the indirect
    /// branch has no static branchTarget, so without this its successors are invisible).
    func testJumpTableDispatchSeedsSwitchBlockLeadersAndEdges() {
        func ins(_ addr: UInt64, _ mnemonic: String, _ operands: String, _ flow: InstructionFlow) -> DecodedInstruction {
            DecodedInstruction(address: addr, bytes: [0, 0, 0, 0], mnemonic: mnemonic, operands: operands,
                               branchTarget: nil, comment: nil, flow: flow)
        }
        let instrs = [
            ins(0x00, "nop", "", .normal),
            ins(0x04, "br", "x0", .indirectJump),   // the switch dispatch
            ins(0x08, "ret", "", .return),          // case 0
            ins(0x0c, "ret", "", .return),          // case 1
        ]
        let functions = [FunctionSummary(id: UUID(), name: "_f", startAddress: 0x00, endAddress: 0x10, confidence: 0.9)]
        let jumpTables: [UInt64: [UInt64]] = [0x04: [0x08, 0x0c, 0x08]]  // a repeated case target
        let engine = AnalysisEngine()

        let blocks = engine.buildBasicBlocks(from: instrs, functions: functions, codeStart: 0x00, jumpTables: jumpTables)
        XCTAssertTrue(blocks.contains { $0.startAddress == 0x08 }, "case target is a block leader")
        XCTAssertTrue(blocks.contains { $0.startAddress == 0x0c }, "case target is a block leader")

        let edges = engine.buildControlFlowEdges(from: instrs, basicBlocks: blocks, jumpTables: jumpTables)
        let switchEdges = edges.filter { $0.kind == "switch" }
        XCTAssertEqual(Set(switchEdges.map(\.to)), [0x08, 0x0c], "a switch edge to each distinct case target")
        XCTAssertEqual(switchEdges.count, 2, "duplicate table targets are de-duplicated")
        XCTAssertTrue(switchEdges.allSatisfy { $0.from == 0x04 }, "every switch edge originates at the dispatch")
    }

    // MARK: - New tests for compact jump-table encodings

    func testUnsignedByteOffsetTableWithMovAliasedIndex() {
        // Real clang -O2/-Os emits `mov w9, w0` between the bounds `cmp w0` and the table load
        // `ldrb [.., w9]`, so the load's index register is NOT the bounds register (verified
        // firsthand vs clang 21 on a 20-case switch: `cmp w0,#0x13` / `mov w8,w0` / `ldrb [x9,x8]`).
        // The resolver must follow that mov-alias backward to tie the bounds to the index; without
        // it `entryCount` is never set and the switch renders opaque.
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0024
        let page = base & ~0xfff
        let lo12 = base & 0xfff
        let rows: [InstructionRow] = [
            row(brAddress &- 0x20, "cmp", "w0, #0x7"),
            row(brAddress &- 0x1c, "b.hi", "0x10000900"),
            row(brAddress &- 0x18, "adrp", "x8, 0x\(String(page, radix: 16))"),
            row(brAddress &- 0x14, "add", "x8, x8, #0x\(String(lo12, radix: 16))"),
            row(brAddress &- 0x10, "adr", "x10, #0x10"),
            row(brAddress &- 0x0c, "mov", "w9, w0"),            // the alias clang inserts
            row(brAddress &- 0x08, "ldrb", "w11, [x8, w9]"),    // index is w9 (= w0), not w0
            row(brAddress &- 0x04, "add", "x10, x10, w11, lsl #2"),
            row(brAddress, "br", "x10")
        ]
        let anchor = (brAddress &- 0x10) &+ 0x10
        let targets: [UInt64] = [
            0x1000_0100, 0x1000_0104, 0x1000_0108, 0x1000_010c,
            0x1000_0110, 0x1000_0114, 0x1000_0118, 0x1000_011c
        ]
        var bytes: [UInt64: [UInt8]] = [:]
        for (i, target) in targets.enumerated() {
            bytes[base &+ UInt64(i)] = le8(UInt8((target &- anchor) / 4))
        }
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertEqual(result, [brAddress: targets],
                       "the mov-aliased index must be followed backward to recover the table")
    }

    func testUnsignedByteOffsetTable() {
        // A dense byte-offset table anchored by an ADR instruction with a scale.
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let page = base & ~0xfff
        let lo12 = base & 0xfff
        // Build the instruction sequence for a byte offset table.
        let rows: [InstructionRow] = [
            row(brAddress &- 0x1c, "cmp", "w0, #0x7"),
            row(brAddress &- 0x18, "b.hi", "0x10000900"),
            row(brAddress &- 0x14, "adrp", "x8, 0x\(String(page, radix: 16))"),
            row(brAddress &- 0x10, "add", "x8, x8, #0x\(String(lo12, radix: 16))"),
            row(brAddress &- 0x0c, "adr", "x10, #0x10"),
            row(brAddress &- 0x08, "ldrb", "w11, [x8, w0]"),
            row(brAddress &- 0x04, "add", "x10, x10, w11, lsl #2"),
            row(brAddress, "br", "x10")
        ]
        // Compute the anchor from the ADR instruction: adr at brAddress-0x0c plus 0x10.
        let anchor = (brAddress &- 0x0c) &+ 0x10
        // Eight case targets spaced 4 bytes apart.
        let targets: [UInt64] = [
            0x1000_0100, 0x1000_0104, 0x1000_0108, 0x1000_010c,
            0x1000_0110, 0x1000_0114, 0x1000_0118, 0x1000_011c
        ]
        // Construct the table bytes: each entry = (target - anchor) / 4, fits in a single byte.
        var bytes: [UInt64: [UInt8]] = [:]
        for (i, target) in targets.enumerated() {
            let entry = (target &- anchor) / 4
            bytes[base &+ UInt64(i)] = le8(UInt8(entry))
        }
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertEqual(result, [brAddress: targets])
        // A plain indirect br should produce no jump table.
        let noRows = [row(brAddress, "br", "x10")]
        let resultNeg = JumpTableResolver().resolve(
            instructions: noRows,
            readBytes: reader([:]),
            codeRange: codeRange
        )
        XCTAssertTrue(resultNeg.isEmpty)
    }

    func testUnsignedHalfOffsetTable() {
        // A dense halfword-offset table anchored by an ADR instruction with a scale.
        let base: UInt64 = 0x1000_0900
        let brAddress: UInt64 = 0x1000_0060
        let page = base & ~0xfff
        let lo12 = base & 0xfff
        // Instruction sequence: halfword table with lsl #1 indexing and lsl #2 scaling.
        let rows: [InstructionRow] = [
            row(brAddress &- 0x1c, "cmp", "w0, #0x3"),
            row(brAddress &- 0x18, "b.hi", "0x10000900"),
            row(brAddress &- 0x14, "adrp", "x8, 0x\(String(page, radix: 16))"),
            row(brAddress &- 0x10, "add", "x8, x8, #0x\(String(lo12, radix: 16))"),
            row(brAddress &- 0x0c, "adr", "x10, #0x10"),
            row(brAddress &- 0x08, "ldrh", "w11, [x8, w0, lsl #1]"),
            row(brAddress &- 0x04, "add", "x10, x10, w11, lsl #2"),
            row(brAddress, "br", "x10")
        ]
        // Anchor: adr row address plus 0x10.
        let anchor = (brAddress &- 0x0c) &+ 0x10
        // Four contiguous targets starting at anchor.
        let targets: [UInt64] = [
            anchor, anchor &+ 4, anchor &+ 8, anchor &+ 12
        ]
        // Table entries are 0,1,2,3 as 16-bit little-endian values.
        var bytes: [UInt64: [UInt8]] = [:]
        let entries: [UInt16] = [0, 1, 2, 3]
        for (i, entry) in entries.enumerated() {
            bytes[base &+ UInt64(i * 2)] = le16(entry)
        }
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertEqual(result, [brAddress: targets])
        // Negative: plain indirect br.
        let noRows = [row(brAddress, "br", "x10")]
        let resultNeg = JumpTableResolver().resolve(
            instructions: noRows,
            readBytes: reader([:]),
            codeRange: codeRange
        )
        XCTAssertTrue(resultNeg.isEmpty)
    }

    func testAdrRelativeTable() {
        // A PC-relative 32-bit offset table anchored by an ADR instruction.
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0050
        let page = base & ~0xfff
        let lo12 = base & 0xfff
        // Instruction sequence: ldr w9 from [x8,w0,lsl #2], add x10,x10,w9,lsl #0.
        let rows: [InstructionRow] = [
            row(brAddress &- 0x1c, "cmp", "w0, #0x2"),
            row(brAddress &- 0x18, "b.hi", "0x10000900"),
            row(brAddress &- 0x14, "adrp", "x8, 0x\(String(page, radix: 16))"),
            row(brAddress &- 0x10, "add", "x8, x8, #0x\(String(lo12, radix: 16))"),
            row(brAddress &- 0x0c, "adr", "x10, #-0x4"),
            row(brAddress &- 0x08, "ldr", "w9, [x8, w0, lsl #2]"),
            row(brAddress &- 0x04, "add", "x10, x10, w9, lsl #0"),
            row(brAddress, "br", "x10")
        ]
        // Anchor: adr row address minus 0x4.
        let anchor = (brAddress &- 0x0c) &- 0x4
        // Entries: relative offsets -8, 4, 8.
        var bytes: [UInt64: [UInt8]] = [:]
        let entries: [Int32] = [-8, 4, 8]
        for (i, entry) in entries.enumerated() {
            bytes[base &+ UInt64(i * 4)] = le32(entry)
        }
        // Expected targets computed from anchor + entry.
        let targets: [UInt64] = [
            anchor &- 8,
            anchor &+ 4,
            anchor &+ 8
        ]
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertEqual(result, [brAddress: targets])
        // Negative: plain indirect br.
        let noRows = [row(brAddress, "br", "x10")]
        let resultNeg = JumpTableResolver().resolve(
            instructions: noRows,
            readBytes: reader([:]),
            codeRange: codeRange
        )
        XCTAssertTrue(resultNeg.isEmpty)
    }

    // MARK: - Adversarial conservatism guards for compact encodings

    /// The anchor-add's offset register must be the load destination. If it adds
    /// an unrelated register (`w12` vs the loaded `w11`), the offset semantics are
    /// unproven and the whole site must be dropped.
    func testCompactBailsWhenAnchorAddOffsetIsNotLoadDest() {
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let page = base & ~0xfff
        let lo12 = base & 0xfff
        let rows: [InstructionRow] = [
            row(brAddress &- 0x1c, "cmp", "w0, #0x7"),
            row(brAddress &- 0x18, "b.hi", "0x10000900"),
            row(brAddress &- 0x14, "adrp", "x8, 0x\(String(page, radix: 16))"),
            row(brAddress &- 0x10, "add", "x8, x8, #0x\(String(lo12, radix: 16))"),
            row(brAddress &- 0x0c, "adr", "x10, #0x10"),
            row(brAddress &- 0x08, "ldrb", "w11, [x8, w0]"),
            row(brAddress &- 0x04, "add", "x10, x10, w12, lsl #2"), // w12, not w11
            row(brAddress, "br", "x10")
        ]
        let anchor = (brAddress &- 0x0c) &+ 0x10
        var bytes: [UInt64: [UInt8]] = [:]
        for i in 0..<8 {
            let target = 0x1000_0100 &+ UInt64(i * 4)
            bytes[base &+ UInt64(i)] = le8(UInt8((target &- anchor) / 4))
        }
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// The anchor register (and thus the anchor-add destination) must be the
    /// register the `br` dispatches through. A mismatch must drop the site.
    func testCompactBailsWhenBranchDoesNotUseAnchorRegister() {
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let page = base & ~0xfff
        let lo12 = base & 0xfff
        let rows: [InstructionRow] = [
            row(brAddress &- 0x1c, "cmp", "w0, #0x7"),
            row(brAddress &- 0x18, "b.hi", "0x10000900"),
            row(brAddress &- 0x14, "adrp", "x8, 0x\(String(page, radix: 16))"),
            row(brAddress &- 0x10, "add", "x8, x8, #0x\(String(lo12, radix: 16))"),
            row(brAddress &- 0x0c, "adr", "x10, #0x10"),
            row(brAddress &- 0x08, "ldrb", "w11, [x8, w0]"),
            row(brAddress &- 0x04, "add", "x10, x10, w11, lsl #2"),
            row(brAddress, "br", "x13") // dispatches through x13, not the anchor x10
        ]
        let anchor = (brAddress &- 0x0c) &+ 0x10
        var bytes: [UInt64: [UInt8]] = [:]
        for i in 0..<8 {
            let target = 0x1000_0100 &+ UInt64(i * 4)
            bytes[base &+ UInt64(i)] = le8(UInt8((target &- anchor) / 4))
        }
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// A compact byte/half/adr encoding with no `adr` anchor at all cannot form a
    /// target and must be dropped rather than guessed.
    func testCompactBailsWhenAnchorMissing() {
        let base: UInt64 = 0x1000_0800
        let brAddress: UInt64 = 0x1000_0020
        let page = base & ~0xfff
        let lo12 = base & 0xfff
        let rows: [InstructionRow] = [
            row(brAddress &- 0x18, "cmp", "w0, #0x7"),
            row(brAddress &- 0x14, "b.hi", "0x10000900"),
            row(brAddress &- 0x10, "adrp", "x8, 0x\(String(page, radix: 16))"),
            row(brAddress &- 0x0c, "add", "x8, x8, #0x\(String(lo12, radix: 16))"),
            row(brAddress &- 0x08, "ldrb", "w11, [x8, w0]"),
            row(brAddress &- 0x04, "add", "x10, x10, w11, lsl #2"), // anchor-add but no adr
            row(brAddress, "br", "x10")
        ]
        var bytes: [UInt64: [UInt8]] = [:]
        for i in 0..<8 { bytes[base &+ UInt64(i)] = le8(UInt8(i)) }
        let result = JumpTableResolver().resolve(
            instructions: rows,
            readBytes: reader(bytes),
            codeRange: codeRange
        )
        XCTAssertTrue(result.isEmpty)
    }
}
