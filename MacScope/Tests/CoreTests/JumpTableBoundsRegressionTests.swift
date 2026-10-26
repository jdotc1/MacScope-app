import Foundation
import XCTest
@testable import MacScope

/// Regression tests for the existing JumpTableResolver API.
/// Add to MacScope/Tests/CoreTests, then regenerate the Xcode project.
final class JumpTableBoundsRegressionTests: XCTestCase {
    private let tableBase: UInt64 = 0x2000
    private let dispatchAddress: UInt64 = 0x1014
    private let caseTargets: [UInt64] = [0x1200, 0x1210, 0x1220]

    private func rows(branch: String, bound: String, branchTarget: String = "0x1100") -> [InstructionRow] {
        let values: [(UInt64, String, String)] = [
            // The X0 index must carry a proved zero-extended W0 value.
            (0x0ffc, "mov", "w0, w0"),
            (0x1000, "cmp", "w0, #\(bound)"),
            (0x1004, branch, branchTarget),
            (0x1008, "adrp", "x8, 0x2000"),
            (0x100c, "add", "x8, x8, #0x0"),
            (0x1010, "ldr", "x9, [x8, x0, lsl #3]"),
            (dispatchAddress, "br", "x9")
        ]
        return values.map { address, mnemonic, operands in
            InstructionRow(address: address, bytes: "00 00 00 00",
                           mnemonic: mnemonic, operands: operands,
                           hasBreakpoint: false, comment: nil)
        }
    }

    private func resolve(branch: String, bound: String)
        -> (tables: [UInt64: [UInt64]], reads: [UInt64]) {
        resolve(instructions: rows(branch: branch, bound: bound))
    }

    private func resolve(instructions: [InstructionRow], words: [UInt64]? = nil)
        -> (tables: [UInt64: [UInt64]], reads: [UInt64]) {
        // The fourth word deliberately resembles a valid code target. An off-by-one
        // resolver would emit it as an invented case instead of merely failing a read.
        let availableWords = words ?? (caseTargets + [0x1230])
        var storage: [UInt64: Data] = [:]
        for (index, word) in availableWords.enumerated() {
            storage[tableBase + UInt64(index * 8)] = Data((0..<8).map {
                UInt8(truncatingIfNeeded: word >> (8 * $0))
            })
        }
        var reads: [UInt64] = []
        let tables = JumpTableResolver().resolve(
            instructions: instructions,
            readBytes: { address, count in
                reads.append(address)
                guard let data = storage[address], data.count == count else { return nil }
                return data
            },
            codeRange: .init(lowerBound: 0x0f00, upperBound: 0x1800)
        )
        return (tables, reads)
    }

    func testUnsignedExclusiveBoundsDoNotReadOneExtraCase() {
        for mnemonic in ["b.hs", "b.cs"] {
            let result = resolve(branch: mnemonic, bound: "0x3")
            XCTAssertEqual(result.tables, [dispatchAddress: caseTargets], mnemonic)
            XCTAssertEqual(result.reads, [0x2000, 0x2008, 0x2010], mnemonic)
        }
    }

    func testUnsignedInclusiveBoundRetainsExistingBehavior() {
        let result = resolve(branch: "b.hi", bound: "0x2")
        XCTAssertEqual(result.tables, [dispatchAddress: caseTargets])
        XCTAssertEqual(result.reads, [0x2000, 0x2008, 0x2010])
    }

    func testComparisonWithoutBoundsBranchDoesNotAuthorizeTableRead() {
        let result = resolve(branch: "nop", bound: "0x3")
        XCTAssertTrue(result.tables.isEmpty)
        XCTAssertTrue(result.reads.isEmpty)
    }

    func testZeroExclusiveBoundDoesNotInventAnEntry() {
        let result = resolve(branch: "b.hs", bound: "0x0")
        XCTAssertTrue(result.tables.isEmpty)
        XCTAssertTrue(result.reads.isEmpty)
    }

    func testInclusiveCountOverflowDoesNotTrapOrRead() {
        let result = resolve(branch: "b.hi", bound: "0x7fffffffffffffff")
        XCTAssertTrue(result.tables.isEmpty)
        XCTAssertTrue(result.reads.isEmpty)
    }

    private func prefixGuard(bound: String) -> [InstructionRow] {
        [
            InstructionRow(address: 0x0ff0, bytes: "00 00 00 00",
                           mnemonic: "cmp", operands: "w0, #\(bound)",
                           hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x0ff4, bytes: "00 00 00 00",
                           mnemonic: "b.hi", operands: "0x1100",
                           hasBreakpoint: false, comment: nil),
            row(0x0ff8, "nop", "")
        ]
    }

    func testConflictingBoundsDeclineBeforeReadingValidLookingSentinels() {
        // Only indices 0...2 can pass the first guard. Choosing only the nearest
        // comparison would read eleven valid-looking words and invent eight cases.
        let instructions = prefixGuard(bound: "0x2") + rows(branch: "b.hi", bound: "0xa")
        let availableWords: [UInt64] = (0..<11).map { 0x1200 + UInt64($0 * 0x10) }
        let result = resolve(instructions: instructions, words: availableWords)
        XCTAssertTrue(result.tables.isEmpty)
        XCTAssertTrue(result.reads.isEmpty)
    }

    func testEquivalentBoundsRetainTheSameExtent() {
        let instructions = prefixGuard(bound: "0x2") + rows(branch: "b.hs", bound: "0x3")
        let result = resolve(instructions: instructions)
        XCTAssertEqual(result.tables, [dispatchAddress: caseTargets])
        XCTAssertEqual(result.reads, [0x2000, 0x2008, 0x2010])
    }

    func testBoundsBranchIntoProtectedSequenceDoesNotAuthorizeRead() {
        for target in ["0x1008", "0x1014"] {
            // Both the taken and fallthrough paths would still reach dispatch.
            let result = resolve(instructions: rows(branch: "b.hi", bound: "0x2", branchTarget: target))
            XCTAssertTrue(result.tables.isEmpty, target)
            XCTAssertTrue(result.reads.isEmpty, target)
        }
    }

    func testRepresentableCountOverProductLimitDoesNotAllocateOrRead() {
        for (branch, bound) in [("b.hi", "0x1000"), ("b.hs", "0x1001"), ("b.cs", "0x7fffffffffffffff")] {
            let result = resolve(branch: branch, bound: bound)
            XCTAssertTrue(result.tables.isEmpty, branch)
            XCTAssertTrue(result.reads.isEmpty, branch)
        }
    }

    /// arm64e hardened dispatch, as emitted by clang -arch arm64e -O2 (see roadmap evidence):
    /// the bounds `b.hi` guards the 32-bit index, then the aliased 64-bit index is clamped with
    /// `cmp x16, #N ; csel x16, x16, xzr, ls` — a clamp, not a branch.
    func testArm64eClampIdiomBoundsTheTable() {
        func row(_ a: UInt64, _ m: String, _ o: String) -> InstructionRow {
            InstructionRow(address: a, bytes: "00 00 00 00", mnemonic: m, operands: o, hasBreakpoint: false, comment: nil)
        }
        let instructions = [
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "mov", "w16, w0"),
            row(0x100c, "cmp", "x16, #0x2"),
            row(0x1010, "csel", "x16, x16, xzr, ls"),
            row(0x1014, "adrp", "x17, 0x2000"),
            row(0x1018, "add", "x17, x17, #0x0"),
            row(0x101c, "ldr", "x16, [x17, x16, lsl #3]"),
            row(0x1020, "br", "x16"),
        ]
        let result = resolve(instructions: instructions)
        XCTAssertEqual(result.tables, [0x1020: caseTargets])
        XCTAssertEqual(result.reads, [0x2000, 0x2008, 0x2010])
    }

    func testClampWithoutZeroRegisterDoesNotAuthorizeRead() {
        func row(_ a: UInt64, _ m: String, _ o: String) -> InstructionRow {
            InstructionRow(address: a, bytes: "00 00 00 00", mnemonic: m, operands: o, hasBreakpoint: false, comment: nil)
        }
        let instructions = [
            row(0x100c, "cmp", "x16, #0x2"),
            row(0x1010, "csel", "x16, x16, x9, ls"),
            row(0x1014, "adrp", "x17, 0x2000"),
            row(0x1018, "add", "x17, x17, #0x0"),
            row(0x101c, "ldr", "x16, [x17, x16, lsl #3]"),
            row(0x1020, "br", "x16"),
        ]
        XCTAssertTrue(resolve(instructions: instructions).tables.isEmpty)
    }

    // MARK: - Guard soundness (the bound must still describe the value that indexes the table)

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands,
                       hasBreakpoint: false, comment: nil)
    }

    /// `cmp w0, #2; b.hi` bounds the ORIGINAL w0 to 0...2, but the load indexes with w0 + 1
    /// (entries 1...3). Reporting entries 0...2 would invent case 0 and drop case 3, and the
    /// fourth table word is valid-looking so an unsound recognizer cannot hide behind a read failure.
    /// clang's arm64e hardened dispatch, as emitted for `sw_12` in the switch fixtures:
    /// entries are relative to the `adr` anchor that re-points x17 after the load.
    func testArm64eAnchorRelativeEntriesUseTheAdrAnchorNotTheTableBase() {
        let instructions = [
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "mov", "w16, w0"),
            row(0x100c, "cmp", "x16, #0x2"),
            row(0x1010, "csel", "x16, x16, xzr, ls"),
            row(0x1014, "adrp", "x17, 0x2000"),
            row(0x1018, "add", "x17, x17, #0x0"),
            row(0x101c, "ldrsw", "x16, [x17, x16, lsl #2]"),
            row(0x1020, "adr", "x17, #0"),
            row(0x1024, "add", "x16, x17, x16"),
            row(0x1028, "br", "x16"),
        ]
        // Offsets from the anchor 0x1020 to 0x1200/0x1210/0x1220.
        let offsets: [Int32] = [0x1E0, 0x1F0, 0x200]
        var storage: [UInt64: Data] = [:]
        for (index, offset) in offsets.enumerated() {
            storage[0x2000 + UInt64(index * 4)] = withUnsafeBytes(of: offset.littleEndian) { Data($0) }
        }
        let tables = JumpTableResolver().resolve(
            instructions: instructions,
            readBytes: { address, count in storage[address].flatMap { $0.count == count ? $0 : nil } },
            codeRange: .init(lowerBound: 0x0f00, upperBound: 0x3000)
        )
        XCTAssertEqual(tables, [0x1028: [0x1200, 0x1210, 0x1220]], "tableBase + raw would give 0x21e0...")
    }

    /// LLVM's ordinary 4-byte form adds the entry to an `adr` anchor defined before the load.
    func testFourByteEntriesRelativeToAnAdrAnchorDefinedBeforeTheLoad() {
        let instructions = [
            row(0x0ffc, "mov", "w0, w0"),
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "adrp", "x9, 0x2000"),
            row(0x100c, "add", "x9, x9, #0x0"),
            row(0x1010, "adr", "x10, #0x10"),
            row(0x1014, "ldrsw", "x11, [x9, x0, lsl #2]"),
            row(0x1018, "add", "x10, x10, x11"),
            row(0x101c, "br", "x10"),
        ]
        // Anchor 0x1020; entries 0x1E0/0x1F0/0x200 → 0x1200/0x1210/0x1220.
        var storage: [UInt64: Data] = [:]
        for (index, offset) in [Int32(0x1E0), 0x1F0, 0x200].enumerated() {
            storage[0x2000 + UInt64(index * 4)] = withUnsafeBytes(of: offset.littleEndian) { Data($0) }
        }
        let tables = JumpTableResolver().resolve(
            instructions: instructions,
            readBytes: { address, count in storage[address].flatMap { $0.count == count ? $0 : nil } },
            codeRange: .init(lowerBound: 0x0f00, upperBound: 0x3000)
        )
        XCTAssertEqual(tables, [0x101c: [0x1200, 0x1210, 0x1220]])
    }

    func testIndexWriteBetweenGuardAndLoadAbstains() {
        let instructions = [
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "add", "w0, w0, #0x1"),
            row(0x100c, "adrp", "x8, 0x2000"),
            row(0x1010, "add", "x8, x8, #0x0"),
            row(0x1014, "ldr", "x9, [x8, x0, lsl #3]"),
            row(0x1018, "br", "x9"),
        ]
        let result = resolve(instructions: instructions)
        XCTAssertTrue(result.tables.isEmpty)
        XCTAssertTrue(result.reads.isEmpty)
    }

    func testUnrelatedWriteBetweenGuardAndLoadStillResolves() {
        let instructions = [
            row(0x0ffc, "mov", "w0, w0"),
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "add", "w10, w10, #0x1"),
            row(0x100c, "adrp", "x8, 0x2000"),
            row(0x1010, "add", "x8, x8, #0x0"),
            row(0x1014, "ldr", "x9, [x8, x0, lsl #3]"),
            row(0x1018, "br", "x9"),
        ]
        XCTAssertEqual(resolve(instructions: instructions).tables, [0x1018: caseTargets])
    }

    func testBranchIntoGuardedSequenceFromElsewhereAbstains() {
        // 0x1100 jumps straight to the table load with an unchecked index.
        let instructions = rows(branch: "b.hi", bound: "0x2", branchTarget: "0x1200")
            + [row(0x1100, "b", "0x1008")]
        XCTAssertTrue(resolve(instructions: instructions).tables.isEmpty)
    }

    func testBaseClobberBeforeLoadAbstains() {
        let instructions = [
            row(0x0ffc, "mov", "w0, w0"),
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "adrp", "x8, 0x2000"),
            row(0x100c, "add", "x8, x8, #0x0"),
            row(0x1010, "mov", "x8, x1"),
            row(0x1014, "ldr", "x9, [x8, x0, lsl #3]"),
            row(0x1018, "br", "x9"),
        ]
        XCTAssertTrue(resolve(instructions: instructions).tables.isEmpty)
    }

    func testDispatchRegisterClobberAfterLoadAbstains() {
        let instructions = [
            row(0x0ffc, "mov", "w0, w0"),
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "adrp", "x8, 0x2000"),
            row(0x100c, "add", "x8, x8, #0x0"),
            row(0x1010, "ldr", "x9, [x8, x0, lsl #3]"),
            row(0x1014, "ldr", "x9, [x1]"),
            row(0x1018, "br", "x9"),
        ]
        XCTAssertTrue(resolve(instructions: instructions).tables.isEmpty)
    }

    func testTableAtTopOfAddressSpaceDoesNotWrapIntoLowMemory() {
        var reads: [UInt64] = []
        let instructions = [
            row(0x0ffc, "mov", "w0, w0"),
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "adrp", "x8, 0xfffffffffffff000"),
            row(0x100c, "add", "x8, x8, #0xff8"),
            row(0x1010, "ldr", "x9, [x8, x0, lsl #3]"),
            row(0x1014, "br", "x9"),
        ]
        let tables = JumpTableResolver().resolve(
            instructions: instructions,
            readBytes: { address, count in
                reads.append(address)
                return Data(repeating: 0, count: count) // every read "succeeds" with target 0x1200 below
                    .enumerated().map { $0.offset == 1 ? UInt8(0x12) : $0.element }
                    .withUnsafeBufferPointer { Data(buffer: $0) }
            },
            codeRange: .init(lowerBound: 0x0f00, upperBound: 0x1800)
        )
        XCTAssertTrue(tables.isEmpty)
        XCTAssertFalse(reads.contains { $0 < 0x1_0000 }, "wrapped read: \(reads)")
    }

    func testRecognizedBaseAdditionAfterLoadDoesNotShiftRecoveredTable() {
        for register in ["x8", "x9"] {
            let instructions = [
                row(0x1000, "cmp", "x0, #0x2"),
                row(0x1004, "b.hi", "0x1100"),
                row(0x1008, "adrp", "x8, 0x2000"),
                row(0x100c, "ldr", "x9, [x8, x0, lsl #3]"),
                row(0x1010, "add", "\(register), \(register), #0x8"),
                row(0x1014, "br", "x9"),
            ]
            let result = resolve(instructions: instructions)
            XCTAssertTrue(result.tables.isEmpty, register)
            XCTAssertTrue(result.reads.isEmpty, register)
        }
    }

    func testMultipleBaseDefinitionsDoNotSumPageAddresses() {
        let instructions = [
            row(0x1000, "cmp", "x0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "adrp", "x8, 0x1000"),
            row(0x100c, "adrp", "x8, 0x1000"),
            row(0x1010, "ldr", "x9, [x8, x0, lsl #3]"),
            row(0x1014, "br", "x9"),
        ]
        let result = resolve(instructions: instructions)
        XCTAssertTrue(result.tables.isEmpty)
        XCTAssertTrue(result.reads.isEmpty)
    }

    func testSignedAddBackRequiresUnclobberedBaseAndEarlierAnchor() {
        let prefix = [
            row(0x1000, "cmp", "x0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "adrp", "x8, 0x2000"),
            row(0x100c, "ldrsw", "x9, [x8, x0, lsl #2]"),
        ]
        let suffixes = [
            [row(0x1010, "mov", "x8, x1"),
             row(0x1014, "add", "x10, x8, x9"),
             row(0x1018, "br", "x10")],
            [row(0x1010, "add", "x10, x10, x9"),
             row(0x1014, "adr", "x10, 0x1200"),
             row(0x1018, "br", "x10")],
        ]
        for suffix in suffixes {
            let result = resolve(instructions: prefix + suffix)
            XCTAssertTrue(result.tables.isEmpty)
            XCTAssertTrue(result.reads.isEmpty)
        }
    }

    // MARK: - MS-22: write sets of MOPS, RCW, LSE atomics and PAuth_LR

    /// The guarded idiom with `instruction` between the guard and the table load.
    private func rowsWithIntervening(_ mnemonic: String, _ operands: String) -> [InstructionRow] {
        [
            row(0x0ffc, "mov", "w0, w0"),
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, mnemonic, operands),
            row(0x100c, "adrp", "x8, 0x2000"),
            row(0x1010, "add", "x8, x8, #0x0"),
            row(0x1014, "ldr", "x9, [x8, x0, lsl #3]"),
            row(0x1018, "br", "x9"),
        ]
    }

    func testModernISAIndexWritesBetweenGuardAndLoadAbstain() {
        for (mnemonic, operands) in [
            ("cpyfp", "[x0]!, [x1]!, x2!"),   // MOPS Xd writeback
            ("setm", "[x1]!, x0!, x2"),       // bare `x0!` writeback
            ("cpye", "[x1]!, [x2]!, x0!"),
            ("rcwswp", "x1, x0, [x2]"),       // RCW SWP writes Xt
            ("rcwswppal", "x1, x0, [x2]"),    // RCW *P writes Xt2
            ("swpal", "w1, w0, [x2]"),        // LSE SWP writes Rt
            ("ldaddl", "w1, w0, [x2]"),       // LSE ld<op> writes Rt
        ] {
            let result = resolve(instructions: rowsWithIntervening(mnemonic, operands))
            XCTAssertTrue(result.tables.isEmpty, "\(mnemonic) \(operands) writes the index")
            XCTAssertTrue(result.reads.isEmpty, "\(mnemonic) \(operands)")
        }
    }

    func testModernISAReadOnlyIndexOperandStillResolves() {
        for (mnemonic, operands) in [
            ("autiasppcr", "x0"),             // reads the modifier, writes x30
            ("autibsppcr", "x0"),
            ("rcwswp", "x0, x1, [x2]"),       // RCW SWP only reads Xs
            ("setp", "[x1]!, x2!, x0"),       // MOPS fill value is read
            ("pacia1716", ""),                // writes x17
        ] {
            XCTAssertEqual(resolve(instructions: rowsWithIntervening(mnemonic, operands)).tables,
                           [0x1018: caseTargets], "\(mnemonic) \(operands) does not write the index")
        }
    }

    func testCaspSecondRegisterClobberOfDispatchRegisterAbstains() {
        // casp writes Rs and Rs+1: x9 (the loaded entry) is the second register.
        let instructions = [
            row(0x0ffc, "mov", "w0, w0"),
            row(0x1000, "cmp", "w0, #0x2"),
            row(0x1004, "b.hi", "0x1100"),
            row(0x1008, "adrp", "x8, 0x2000"),
            row(0x100c, "add", "x8, x8, #0x0"),
            row(0x1010, "ldr", "x9, [x8, x0, lsl #3]"),
            row(0x1014, "casp", "x8, x9, x2, x3, [x1]"),
            row(0x1018, "br", "x9"),
        ]
        XCTAssertTrue(resolve(instructions: instructions).tables.isEmpty)
    }

    // DOT-T3: publication, not only downstream selector naming, needs the proof.
    private func publicationRows(bypass: Bool, fullWidthCompare: Bool = false) -> [InstructionRow] {
        [
            row(0x0ff8, bypass ? "cbnz" : "nop", bypass ? "x2, 0x1004" : ""),
            row(0x0ffc, "mov", "w8, w1"),
            row(0x1000, "nop", ""),
            row(0x1004, "cmp", fullWidthCompare ? "x8, #2" : "w8, #2"),
            row(0x1008, "b.hi", "0x1100"),
            row(0x100c, "adrp", "x10, 0x2000"),
            row(0x1010, "add", "x10, x10, #0"),
            row(0x1014, "ldr", "x9, [x10, x8, lsl #3]"),
            row(0x1018, "br", "x9"),
            row(0x1100, "ret", ""),
            row(0x1200, "ret", ""),
            row(0x1210, "ret", ""),
            row(0x1220, "ret", "")
        ]
    }

    func testPublicResolverDoesNotPublishWhenEntryAtCompareBypassesWDefinition() {
        let safe = publicationRows(bypass: false)
        XCTAssertEqual(resolve(instructions: safe).tables, [0x1018: caseTargets])
        // CMP X8 bounds the full carrier, so bypassing MOV W8 is harmless here.
        let fullWidth = publicationRows(bypass: true, fullWidthCompare: true)
        XCTAssertEqual(resolve(instructions: fullWidth).tables, [0x1018: caseTargets])
        let bypass = publicationRows(bypass: true)
        XCTAssertNil(JumpTableResolver.proveSelector(rows: bypass, dispatchIndex: 8))
        XCTAssertTrue(resolve(instructions: bypass).tables.isEmpty,
                      "Legacy success must not publish case edges without the reaching-W proof")
    }

    func testBuilderDoesNotKeepCasesFromResolverAfterCompareEntryBypass() throws {
        let safe = publicationRows(bypass: false)
        let safeTables = resolve(instructions: safe).tables
        let safeFunction = MacIRBuilder().buildFunction(name: "safe", jumpTables: safeTables,
                                                       instructions: safe)
        let safeDispatch = try XCTUnwrap(safeFunction.instructions.first { $0.source.address == 0x1018 })
        guard case let .switchDispatch(_, cases, _) = safeDispatch.operation else {
            return XCTFail("No-bypass control must retain the proven switch")
        }
        XCTAssertEqual(cases.map(\.target), caseTargets.map { .immediate(Int64($0)) })

        let bypass = publicationRows(bypass: true)
        let tables = resolve(instructions: bypass).tables
        let function = MacIRBuilder().buildFunction(name: "bypass", jumpTables: tables,
                                                   instructions: bypass)
        let dispatch = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1018 })
        if case .switchDispatch = dispatch.operation {
            XCTFail("An unproved legacy table must not reach the ordinary builder as switch cases")
        }
    }

}
