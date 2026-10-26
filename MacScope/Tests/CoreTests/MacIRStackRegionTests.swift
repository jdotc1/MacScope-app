import XCTest
@testable import MacScope

/// DP04 B2 (slice 1): storage regions and local identity from frame accesses.
final class MacIRStackRegionTests: XCTestCase {
    private func regions(_ text: [(String, String)]) -> MacIRStackRegionAnalysis {
        let rows = text.enumerated().map { index, pair in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: pair.0, operands: pair.1,
                           hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder().buildFunction(name: "regions", startAddress: 0x1000, instructions: rows)
        let frame = MacIRFrameAnalysis.analyze(rows: rows, instructions: function.instructions)
        return MacIRStackRegionAnalysis.analyze(functionStart: 0x1000, rows: rows,
                                                instructions: function.instructions, frame: frame)
    }

    func testOverlapEscapeReuseAndIdentity() {
        // Partial overlap: one storage group, flagged (no stale-reload facts).
        let overlap = regions([("sub", "sp, sp, #0x20"), ("str", "x0, [sp]"), ("ldr", "w1, [sp, #0x4]"),
                               ("add", "sp, sp, #0x20"), ("ret", "")])
        XCTAssertEqual(overlap.regions.map(\.range), [-32 ..< -24])
        XCTAssertEqual(overlap.regions.first?.hasPartialOverlap, true)
        XCTAssertEqual(overlap.regions.first?.lifetimes.count, 1)

        // Disjoint accesses stay distinct regions.
        let disjoint = regions([("sub", "sp, sp, #0x20"), ("str", "x0, [sp]"), ("str", "x1, [sp, #0x8]"),
                                ("add", "sp, sp, #0x20"), ("ret", "")])
        XCTAssertEqual(disjoint.regions.map(\.range), [-32 ..< -24, -24 ..< -16])
        XCTAssertTrue(disjoint.regions.allSatisfy { $0.role == .candidateLocal && !$0.escapes })

        // An address passed to a call escapes.
        let escaped = regions([("sub", "sp, sp, #0x20"), ("str", "x2, [sp, #0x8]"), ("add", "x0, sp, #0x8"),
                               ("bl", "_fill"), ("ldr", "x1, [sp, #0x8]"), ("add", "sp, sp, #0x20"), ("ret", "")])
        XCTAssertEqual(escaped.regions.map(\.range), [-24 ..< -16])
        XCTAssertEqual(escaped.regions.first?.escapes, true)
        XCTAssertEqual(escaped.regions.first?.lifetimes.count, 1, "an escaped slot never splits its lifetime")

        // Identical reanalysis yields identical locators.
        let program = [("sub", "sp, sp, #0x10"), ("str", "x0, [sp]"), ("ldr", "x1, [sp]"),
                       ("str", "x2, [sp]"), ("ldr", "x3, [sp]"), ("add", "sp, sp, #0x10"), ("ret", "")]
        let first = regions(program), second = regions(program)
        XCTAssertEqual(first.regions.flatMap(\.lifetimes), second.regions.flatMap(\.lifetimes))
        // A proven reuse (straight line, full overwrite after a read) gets a new identity.
        let reuse = first.regions.first?.lifetimes ?? []
        XCTAssertEqual(reuse.map(\.anchor), [0x1004, 0x100c])
        XCTAssertNotEqual(reuse.first?.identity, reuse.last?.identity)
        // With a branch the separation is not proven: one lifetime.
        let branched = regions([("sub", "sp, sp, #0x10"), ("str", "x0, [sp]"), ("ldr", "x1, [sp]"),
                                ("cbz", "x1, 0x1014"), ("str", "x2, [sp]"), ("ldr", "x3, [sp]"),
                                ("add", "sp, sp, #0x10"), ("ret", "")])
        XCTAssertEqual(branched.regions.first?.lifetimes.count, 1)

        // Saved registers and incoming arguments are not user locals.
        let saved = regions([("stp", "x29, x30, [sp, #-0x10]!"), ("ldr", "x0, [sp, #0x18]"),
                             ("ldp", "x29, x30, [sp], #0x10"), ("ret", "")])
        XCTAssertEqual(saved.regions.map(\.role), [.savedRegister, .savedRegister, .incomingArgument])
        XCTAssertEqual(saved.regions.map(\.range), [-16 ..< -8, -8 ..< 0, 8 ..< 16])
    }

    private func locals(_ text: [(String, String)]) -> [MacIRLocalVariable] {
        let rows = text.enumerated().map { index, pair in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: pair.0, operands: pair.1,
                           hasBreakpoint: false, comment: nil)
        }
        return MacIRBuilder().buildFunction(name: "locals", startAddress: 0x1000, instructions: rows).localVariables
    }

    /// DP04 B2 (slice 2): locals carry the region identity; offset APIs are unchanged.
    func testLocalsAdoptRegionIdentity() {
        let program = [("sub", "sp, sp, #0x20"), ("str", "x0, [sp, #0x8]"), ("str", "w1, [sp, #0x14]"),
                       ("ldr", "x2, [sp, #0x8]"), ("ldr", "w3, [sp, #0x14]"), ("add", "sp, sp, #0x20"), ("ret", "")]
        let first = locals(program)
        let described = first.map { "\($0.offset)/\($0.byteWidth)=\($0.stackStorage?.identity ?? "nil")" }
        let wide = first.first { $0.byteWidth == 8 }
        XCTAssertEqual(wide?.stackStorage?.entryRange, -24 ..< -16, "\(described)")
        XCTAssertEqual(wide?.stackStorage?.identity, "macir-stack-v1:1000:-24:-16:1004", "\(described)")
        XCTAssertEqual(wide?.stackStorage?.role, .candidateLocal)
        XCTAssertEqual(wide?.stackStorage?.escapes, false)
        let narrow = first.first { $0.byteWidth == 4 }
        XCTAssertEqual(narrow?.stackStorage?.entryRange, -12 ..< -8, "\(described)")
        // Deterministic: identical input, identical identities.
        XCTAssertEqual(first.map(\.stackStorage), locals(program).map(\.stackStorage))
        // Identity stays out of equality, so offset-keyed expectations are unchanged.
        if let wide {
            var bare = wide
            bare.stackStorage = nil
            XCTAssertEqual(bare, wide)
        }

        // An escaped slot keeps its identity and says so.
        let escaped = locals([("sub", "sp, sp, #0x20"), ("str", "x2, [sp, #0x8]"), ("add", "x0, sp, #0x8"),
                              ("bl", "_fill"), ("ldr", "x1, [sp, #0x8]"), ("add", "sp, sp, #0x20"), ("ret", "")])
        let escapedStorage = escaped.compactMap(\.stackStorage)
        XCTAssertTrue(escapedStorage.allSatisfy(\.escapes), "\(escapedStorage)")

        // A slot with two proven lifetimes has no single identity yet: unattached.
        let reused = locals([("sub", "sp, sp, #0x10"), ("str", "x0, [sp]"), ("ldr", "x1, [sp]"),
                             ("str", "x2, [sp]"), ("ldr", "x3, [sp]"), ("add", "sp, sp, #0x10"), ("ret", "")])
        XCTAssertTrue(reused.allSatisfy { $0.stackStorage == nil }, "\(reused.map(\.stackStorage))")
    }

    func testPreviouslyPromotedFirstPairElementKeepsDistinctStorageAndEdits() throws {
        for useRegion in [false, true] {
            var text = [("sub", "sp, sp, #32"), ("str", "x0, [sp]"),
                        ("stp", "x0, x1, [sp]")]
            if useRegion {
                text += [("add", "v0.8h, v0.8h, v1.8h"), ("subs", "x2, x2, #1"), ("b.ne", "0x100c")]
            }
            text += [("add", "sp, sp, #32"), ("ret", "")]
            let rows = text.enumerated().map { index, pair in
                InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                               operands: pair.1, hasBreakpoint: false, comment: nil)
            }
            if useRegion {
                XCTAssertTrue(MacIRBuilder.attemptsGeneralVectorRegion(rows))
                XCTAssertNotNil(MacIRBuilder().buildGeneralVectorRegion(
                    name: "pair", startAddress: 0x1000, rows: rows,
                    initialState: BuilderState(parameters: []),
                    hasExternalFacts: false, isVariadic: false), "the region route must be admitted")
            }
            let function = MacIRBuilder().buildFunction(name: "pair", startAddress: 0x1000, instructions: rows)
            if useRegion {
                XCTAssertNotNil(function.instructions.first { $0.source.address == 0x100c }?.neonLaneOp)
            }
            let locals = function.localVariables.sorted { $0.offset < $1.offset }
            XCTAssertEqual(locals.count, 2)
            let first = try XCTUnwrap(locals.first)
            let second = try XCTUnwrap(locals.last)
            XCTAssertEqual(first.definingAddress, 0x1004)
            XCTAssertEqual(second.definingAddress, 0x1008)
            XCTAssertEqual(first.stackStorage?.entryRange, -32 ..< -24)
            XCTAssertEqual(second.stackStorage?.entryRange, -24 ..< -16)
            XCTAssertNotEqual(first.stackStorage?.authoringKey, second.stackStorage?.authoringKey)
            for (key, targetOffset, untouched) in [("-32:-24", first.offset, second),
                                                   ("-24:-16", second.offset, first)] {
                let edited = PseudocodePrinter().print(function: function, stackLocalOverrides: [
                    key: StackLocalOverride(name: "chosen", typeName: "int64_t"),
                ])
                let target = try XCTUnwrap(edited.localVariables.first { $0.offset == targetOffset })
                XCTAssertEqual(target.name, "chosen")
                XCTAssertEqual(target.type, "int64_t")
                XCTAssertEqual(edited.localVariables.first { $0.offset == untouched.offset }?.name, untouched.name)
                XCTAssertEqual(edited.localVariables.first { $0.offset == untouched.offset }?.type, untouched.type)
            }
        }
    }

}
