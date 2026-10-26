import Foundation
import XCTest
@testable import MacScope

/// Tier 1.2 — recursive-descent / worklist function discovery.
///
/// The `makeFunctionSummaries` slicer partitions text into `[start, nextStart)` ranges
/// over a sorted start set (LC_FUNCTION_STARTS + entry + direct-call targets). A SINGLE
/// missed start silently MERGES two adjacent functions, corrupting every downstream
/// CFG/decompile/xref. These tests prove the recovery pass restores the omitted boundary
/// from a prologue at an inter-function boundary (or a tail-call into a prologue) WITHOUT
/// introducing false splits.
@MainActor
final class RecursiveDescentDiscoveryTests: XCTestCase {

    func testSynchronousTrapHasNoOrdinaryFallthroughToBranchLeader() throws {
        for word: UInt32 in [0xd4200000, 0xd4400000] { // BRK #0 / HLT #0
            let bytes: [UInt8] = (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
            let fixture = TinyMachO.make(code: Data(
                [0x40, 0x00, 0x00, 0xb4] + // cbz x0, +8: makes the post-trap row a leader
                bytes + [0xc0, 0x03, 0x5f, 0xd6]
            ))
            let snapshot = try AnalysisEngine().analyze(url: try fixture.write())
            XCTAssertFalse(snapshot.controlFlowEdges.contains {
                $0.from == fixture.baseAddress + 4 && $0.kind == "fallthrough"
            })
            XCTAssertTrue(snapshot.controlFlowEdges.contains {
                $0.from == fixture.baseAddress && $0.to == fixture.baseAddress + 4
                    && $0.kind == "fallthrough"
            })
        }
    }

    func testCallsAndSystemCallRetainOrdinaryFallthroughToBranchLeader() throws {
        for word: UInt32 in [0x94000002, 0xd63f0000, 0xd4000001] { // BL / BLR / SVC
            let bytes: [UInt8] = (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
            let fixture = TinyMachO.make(code: Data(
                [0x40, 0x00, 0x00, 0xb4] + bytes + [0xc0, 0x03, 0x5f, 0xd6]
            ))
            let snapshot = try AnalysisEngine().analyze(url: try fixture.write())
            XCTAssertTrue(snapshot.controlFlowEdges.contains {
                $0.from == fixture.baseAddress + 4 && $0.to == fixture.baseAddress + 8
                    && $0.kind == "fallthrough"
            })
        }
    }

    // MARK: - The bug: a missed start merges two functions

    /// A binary with NO LC_FUNCTION_STARTS, NO symbols, and NO direct call into the second
    /// function. The only entry the linear pass sees is the Mach-O entry point, so the
    /// naive slicer would produce ONE function spanning both bodies. The recovery pass
    /// detects the second function's `stp x29, x30` prologue sitting right after the first
    /// function's `ret` and splits the boundary.
    func testRecoversPrologueFunctionAfterReturnThatLinearSweepMerges() throws {
        // f0: mov w0,#0 ; ret            (entry, ends at 0x08)
        // f1: stp x29,x30,[sp,#-16]! ; ret   (prologue-led, no caller, no fn-start)
        let code = Data([
            0x00, 0x00, 0x80, 0x52,         // mov w0, #0
            0xc0, 0x03, 0x5f, 0xd6,         // ret               <- f0 terminator
            0xfd, 0x7b, 0xbf, 0xa9,         // stp x29, x30, [sp, #-0x10]!  <- f1 prologue
            0xc0, 0x03, 0x5f, 0xd6          // ret
        ])
        let fixture = TinyMachO.make(code: code)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())

        // Two functions, split exactly at the recovered prologue boundary (0x08).
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [
            fixture.baseAddress,
            fixture.baseAddress + 0x08
        ])
        // The recovered start is named as a synthetic sub_ and carries the recovery
        // confidence (0.6) — distinct from a bare linear-sweep fallback (0.58/0.45).
        XCTAssertEqual(snapshot.functions.last?.name, "sub_\((fixture.baseAddress + 0x08).hexAddress)")
        XCTAssertEqual(snapshot.functions.last?.confidence, 0.6)
        // The first function now ends at the boundary instead of swallowing f1.
        XCTAssertEqual(snapshot.functions.first?.endAddress, fixture.baseAddress + 0x08)
    }

    /// The same code, but with the recovery boundary marked as DATA, must NOT become a
    /// function start — the override-aware filtering still wins, so the two bodies merge
    /// back into one function (the data mark suppresses the recovered boundary).
    func testDataMarkedAddressIsNotRecoveredAsAFunctionStart() throws {
        let code = Data([
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6,
            0xfd, 0x7b, 0xbf, 0xa9,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let fixture = TinyMachO.make(code: code)
        let boundary = fixture.baseAddress + 0x08

        let snapshot = try AnalysisEngine().analyze(
            url: try fixture.write(),
            overrides: [boundary: AddressOverride(isData: true)]
        )
        XCTAssertFalse(
            snapshot.functions.contains { $0.startAddress == boundary },
            "a data-marked address must never be promoted to a function start"
        )
    }

    func testDataShapeMarkedAddressIsExcludedFromCodeAnalysis() throws {
        // A Make Array / Make Alignment / Make String shape makes the span data, so the
        // shaped address must NOT be recovered as a function start — exactly like a plain
        // mark-as-data, since the engine's data-address set now includes shaped addresses.
        let code = Data([
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6,
            0xfd, 0x7b, 0xbf, 0xa9,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let fixture = TinyMachO.make(code: code)
        let boundary = fixture.baseAddress + 0x08

        let snapshot = try AnalysisEngine().analyze(
            url: try fixture.write(),
            overrides: [boundary: AddressOverride(dataShape: DataShapeOverride(kind: .array, elementType: "int32_t", elementCount: 2))]
        )
        XCTAssertFalse(
            snapshot.functions.contains { $0.startAddress == boundary },
            "a shaped (array) address must never be promoted to a function start"
        )
        XCTAssertTrue(snapshot.isData(at: boundary))
    }

    // MARK: - No false splits (never split on a branch target)

    /// A direct branch (`b`/`b.cond`/`cbz`/…) into a prologue must NOT be split off into a
    /// new function. A branch target that looks like a prologue is indistinguishable —
    /// without full CFG analysis — from an intra-function landing pad / stack-setup block,
    /// so the conservative choice is no split (avoiding a corrupting FALSE SPLIT). A
    /// genuine tail-called function merges instead (a recoverable false merge; the user can
    /// split it via Mark as Procedure).
    func testDoesNotSplitOnABranchTargetPrologue() throws {
        // mov ; b .+8 (-> 0x0c) ; ret ; L=0x0c: sub sp,sp,#16 (prologue, the b target) ; ret.
        // 0x0c's predecessor (the ret at 0x08) IS a terminator, so the terminator check
        // alone would split it — but it is the UNCONDITIONAL `b` target, so the branch-
        // target guard keeps it merged (the printf-style intra-function `b`-into-prologue).
        let code = Data([
            0x00, 0x00, 0x80, 0x52,         // 0x00 mov w0, #0
            0x02, 0x00, 0x00, 0x14,         // 0x04 b .+8   (unconditional, -> 0x0c)
            0xc0, 0x03, 0x5f, 0xd6,         // 0x08 ret      (terminator before the candidate)
            0xff, 0x43, 0x00, 0xd1,         // 0x0c sub sp, sp, #0x10   (prologue AND the b target)
            0xc0, 0x03, 0x5f, 0xd6          // 0x10 ret
        ])
        let fixture = TinyMachO.make(code: code)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [fixture.baseAddress],
                       "a branch-reached prologue must not be falsely split into a new function")
    }

    /// The early-return idiom (reviewer-confirmed false split): an early `ret` followed in
    /// memory by a landing pad that begins with a prologue AND is reached by an earlier
    /// intra-function conditional branch. The prologue's address-predecessor IS a terminator
    /// (the early ret), so the terminator check alone wrongly fired — the branch-target
    /// guard is what keeps the single function whole.
    func testDoesNotSplitOnEarlyReturnThenBranchIntoPrologue() throws {
        // one function: cmp w0,#0 ; b.ne L ; mov w0,#0 ; ret ; L: sub sp,sp,#0x10 ; ret
        let code = Data([
            0x1f, 0x00, 0x00, 0x71,         // cmp w0, #0
            0x61, 0x00, 0x00, 0x54,         // b.ne L (= 0x10)
            0x00, 0x00, 0x80, 0x52,         // mov w0, #0
            0xc0, 0x03, 0x5f, 0xd6,         // ret                     (early return)
            0xff, 0x43, 0x00, 0xd1,         // L: sub sp, sp, #0x10     (landing pad, branch target)
            0xc0, 0x03, 0x5f, 0xd6          // ret
        ])
        let fixture = TinyMachO.make(code: code)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [fixture.baseAddress],
                       "an early-return landing pad reached by an intra-function branch is not a new function")
    }

    /// Mark as Procedure is the manual lever: the SAME branch-into-prologue case that the
    /// conservative recovery leaves merged (one function) splits into two when the user
    /// forces a function start at the prologue — proving the override re-drives discovery.
    func testMarkAsProcedureForcesAFunctionStart() throws {
        let code = Data([
            0x00, 0x00, 0x80, 0x52,         // 0x00 mov w0, #0
            0x02, 0x00, 0x00, 0x14,         // 0x04 b .+8   (-> 0x0c)
            0xc0, 0x03, 0x5f, 0xd6,         // 0x08 ret
            0xff, 0x43, 0x00, 0xd1,         // 0x0c sub sp, sp, #0x10   (the prologue)
            0xc0, 0x03, 0x5f, 0xd6          // 0x10 ret
        ])
        let fixture = TinyMachO.make(code: code)
        let url = try fixture.write()
        let boundary = fixture.baseAddress + 0x0c

        // Baseline: conservatively merged into one function.
        XCTAssertEqual(try AnalysisEngine().analyze(url: url).functions.map(\.startAddress), [fixture.baseAddress])

        // Mark as Procedure forces the split.
        let forced = try AnalysisEngine().analyze(url: url, overrides: [boundary: AddressOverride(markAsProcedure: true)])
        XCTAssertEqual(forced.functions.map(\.startAddress), [fixture.baseAddress, boundary])

        // A forced start that is NOT a decoded-instruction address (e.g. mid-instruction,
        // reachable via the unvalidated `make-procedure` command) is ignored — it must not
        // seed a misaligned/empty phantom function.
        let bogus = fixture.baseAddress + 0x0d   // inside the `sub sp` at 0x0c
        let ignored = try AnalysisEngine().analyze(url: url, overrides: [bogus: AddressOverride(markAsProcedure: true)])
        XCTAssertFalse(ignored.functions.contains { $0.startAddress == bogus })
        XCTAssertEqual(ignored.functions.map(\.startAddress), [fixture.baseAddress])
    }

    // MARK: - No false splits (mid-function prologue shapes)

    /// A prologue-shaped instruction in the MIDDLE of a function (not preceded by a
    /// terminator) must NOT be promoted. Here a `sub sp, sp, #imm` appears after a normal
    /// `mov` — a stack re-adjustment, not a new function — so the function stays whole.
    func testDoesNotSplitOnAMidFunctionPrologueShapedInstruction() throws {
        // single function: stp(prologue) ; mov ; sub sp,sp,#16(mid-body) ; ret
        let code = Data([
            0xfd, 0x7b, 0xbf, 0xa9,         // stp x29, x30, [sp, #-0x10]!  (real prologue at start)
            0x00, 0x00, 0x80, 0x52,         // mov w0, #0   (NOT a terminator)
            0xff, 0x43, 0x00, 0xd1,         // sub sp, sp, #0x10  (mid-body, must not split)
            0xc0, 0x03, 0x5f, 0xd6          // ret
        ])
        let fixture = TinyMachO.make(code: code)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())

        // Only the entry function — the mid-body `sub sp` is not a recovered start.
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [fixture.baseAddress])
    }

    /// An intra-function conditional branch loop must NOT cause a split: the branch target
    /// is not a prologue, and the prologue-shaped first instruction is the real (already
    /// seeded) entry, so nothing new is recovered.
    func testDoesNotSplitOnAnIntraFunctionConditionalBranch() throws {
        // entry: mov w0,#0 ; b.eq .+8 ; mov w1,#0 ; ret
        let code = Data([
            0x00, 0x00, 0x80, 0x52,         // mov w0, #0
            0x40, 0x00, 0x00, 0x54,         // b.eq .+8  (conditional)
            0x01, 0x00, 0x80, 0x52,         // mov w1, #0  (branch target, NOT a prologue)
            0xc0, 0x03, 0x5f, 0xd6          // ret
        ])
        let fixture = TinyMachO.make(code: code)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())

        XCTAssertEqual(snapshot.functions.map(\.startAddress), [fixture.baseAddress])
    }

    /// The recovery pass must not regress the existing direct-call recovery scoring: a
    /// function reached by an explicit `bl` keeps its 0.62 direct-call confidence even
    /// though its body also begins with a prologue.
    func testDirectCallTargetKeepsItsConfidenceOverPrologueRecovery() throws {
        // f0: mov w0,#0 ; bl .+8 ; ret
        // f1: stp x29,x30,[sp,#-16]! ; ret   (reached by the bl AND prologue-shaped)
        let code = Data([
            0x00, 0x00, 0x80, 0x52,         // mov w0, #0
            0x02, 0x00, 0x00, 0x94,         // bl .+8   (direct call to f1)
            0xc0, 0x03, 0x5f, 0xd6,         // ret
            0xfd, 0x7b, 0xbf, 0xa9,         // stp x29, x30, [sp, #-0x10]!
            0xc0, 0x03, 0x5f, 0xd6          // ret
        ])
        let fixture = TinyMachO.make(code: code)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())

        XCTAssertEqual(snapshot.functions.map(\.startAddress), [
            fixture.baseAddress,
            fixture.baseAddress + 0x0c
        ])
        // Direct-call evidence (0.62) outranks the prologue-recovery score (0.6).
        XCTAssertEqual(snapshot.functions.last?.confidence, 0.62)
    }

    // MARK: - Data code-pointer seeding (function-pointer tables / vtables)

    /// The data-code-pointer recovery (function-pointer tables, vtables, dispatch tables) uses
    /// the pointer reference as the primary signal INSTEAD of a prologue, so a prologue-less
    /// optimized leaf handler is recovered — but it keeps recoverFunctionStarts' conservatism:
    /// only a terminator-preceded, non-branch-target, non-data candidate is promoted. (The
    /// loader→engine wiring is covered by the real-binary dispatch-table oracle.)
    func testDataPointerRecoveryHonorsConservatismGuards() {
        let base: UInt64 = 0x1000
        func insn(_ off: UInt64, _ mnemonic: String, _ flow: InstructionFlow, target: UInt64? = nil) -> DecodedInstruction {
            DecodedInstruction(address: base + off, bytes: [0, 0, 0, 0], mnemonic: mnemonic, operands: "", branchTarget: target, comment: nil, flow: flow)
        }
        let instructions = [
            insn(0x00, "b", .jump, target: base + 0x10),  // makes 0x10 a direct-branch target
            insn(0x04, "ret", .return),
            insn(0x08, "ldr", .normal),   // A: pointer target, preceded by ret  -> RECOVER
            insn(0x0c, "ret", .return),
            insn(0x10, "ldr", .normal),   // B: preceded by ret BUT a branch target -> reject
            insn(0x14, "mov", .normal),
            insn(0x18, "ldr", .normal)    // C: preceded by a non-terminator (mov) -> reject
        ]
        let decoded = Set(instructions.map(\.address))
        let candidates = [base + 0x08, base + 0x10, base + 0x18]
        let engine = AnalysisEngine()

        let recovered = engine.recoverDataPointerStarts(
            candidates: candidates, from: instructions,
            codeStart: base, codeEnd: base + 0x1c,
            existingStarts: [], decodedInstructionAddresses: decoded, dataAddresses: []
        )
        XCTAssertEqual(recovered, [base + 0x08],
                       "only the terminator-preceded, non-branch-target pointer target is a function start")

        // A data-marked pointer target is never promoted (override wins).
        let withDataMark = engine.recoverDataPointerStarts(
            candidates: candidates, from: instructions,
            codeStart: base, codeEnd: base + 0x1c,
            existingStarts: [], decodedInstructionAddresses: decoded, dataAddresses: [base + 0x08]
        )
        XCTAssertTrue(withDataMark.isEmpty, "a data-marked pointer target must not become a function start")

        // A candidate that is not a decoded instruction start (mid-instruction pointer) is rejected.
        let midInstruction = engine.recoverDataPointerStarts(
            candidates: [base + 0x09], from: instructions,
            codeStart: base, codeEnd: base + 0x1c,
            existingStarts: [], decodedInstructionAddresses: decoded, dataAddresses: []
        )
        XCTAssertTrue(midInstruction.isEmpty, "a pointer into the middle of an instruction is not a start")
    }

    /// A MANUAL switch hint must reach the CFG (not just the pseudocode): the basic-block
    /// graph shows `switch` edges to the declared case targets. The dispatch is a bare
    /// `br x0` the auto-resolver cannot recover, so any switch edges come ONLY from the
    /// user's hint — exercising both the hint→CFG wiring AND the section-accurate
    /// `hexByteReader` (the hint table is read from the real section bytes, not a header).
    func testManualSwitchHintDrivesTheCFG() throws {
        let code = Data([
            0x00, 0x00, 0x1f, 0xd6,         // 0x00 br x0   (dispatch; auto-resolver can't recover it)
            0xc0, 0x03, 0x5f, 0xd6,         // 0x04 ret     (case 0 target)
            0xc0, 0x03, 0x5f, 0xd6,         // 0x08 ret     (case 1 target)
            0xf8, 0xff, 0xff, 0xff,         // 0x0c table[0] = -0x08 (base-relative) -> 0x04
            0xfc, 0xff, 0xff, 0xff          // 0x10 table[1] = -0x04 -> 0x08
        ])
        let fixture = TinyMachO.make(code: code)
        let br = fixture.baseAddress
        let hint = SwitchHintOverride(tableBase: fixture.baseAddress + 0x0c, entryCount: 2, entryStride: 4, isRelativeToBase: true)

        let snapshot = try AnalysisEngine().analyze(url: try fixture.write(), overrides: [br: AddressOverride(switchHint: hint)])
        let switchEdges = snapshot.controlFlowEdges.filter { $0.kind == "switch" && $0.from == br }
        XCTAssertEqual(Set(switchEdges.map(\.to)), [fixture.baseAddress + 0x04, fixture.baseAddress + 0x08],
                       "the manual switch hint drives the CFG switch edges (graph agrees with pseudocode)")
    }
}

// MARK: - Minimal self-contained Mach-O builder

/// A deliberately small arm64 Mach-O (single `__TEXT,__text`, LC_MAIN entry, no symbols,
/// no LC_FUNCTION_STARTS) so the linear discovery pass sees ONLY the entry point — the
/// exact condition under which a missed start merges two functions. Kept independent of
/// the `private` MachOFixture in MachOImportTests so the two test files never collide.
/// `internal` (not `private`) so the store-concurrency tests can reuse it for an on-disk binary;
/// the file-private `Data` little-endian extension below stays local, so nothing else leaks.
struct TinyMachO {
    let bytes: Data
    let baseAddress: UInt64

    /// `symbols` (name, byte offset into `code`) adds an LC_SYMTAB of external section symbols
    /// after the code; with none, the bytes are exactly the original symbol-less fixture.
    static func make(code: Data, symbols: [(name: String, offset: Int)] = []) -> TinyMachO {
        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let mainCommandSize = 24
        let symtabCommandSize = symbols.isEmpty ? 0 : 24
        let loadCommandsSize = segmentCommandSize + mainCommandSize + symtabCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let imageBase: UInt64 = 0x1_0000_0000
        let codeAddress = imageBase + UInt64(codeOffset)
        let textFileSize = UInt64(codeOffset + code.count)

        var bytes = Data()
        // mach_header_64
        bytes.le32(0xfeedfacf)
        bytes.le32(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.le32(0)
        bytes.le32(MachOConstants.fileTypeExecute)
        bytes.le32(symbols.isEmpty ? 2 : 3) // ncmds
        bytes.le32(UInt32(loadCommandsSize))
        bytes.le32(0)
        bytes.le32(0)

        // LC_SEGMENT_64 __TEXT
        bytes.le32(MachOConstants.loadCommandSegment64)
        bytes.le32(UInt32(segmentCommandSize))
        bytes.cString("__TEXT", length: 16)
        bytes.le64(imageBase)
        bytes.le64(textFileSize)
        bytes.le64(0)
        bytes.le64(textFileSize)
        bytes.le32(5)                       // maxprot
        bytes.le32(5)                       // initprot
        bytes.le32(1)                       // nsects
        bytes.le32(0)                       // flags

        // section __text
        bytes.cString("__text", length: 16)
        bytes.cString("__TEXT", length: 16)
        bytes.le64(codeAddress)
        bytes.le64(UInt64(code.count))
        bytes.le32(UInt32(codeOffset))
        bytes.le32(2)                       // align
        bytes.le32(0)
        bytes.le32(0)
        bytes.le32(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.le32(0)
        bytes.le32(0)
        bytes.le32(0)

        // LC_MAIN
        bytes.le32(MachOConstants.loadCommandMain)
        bytes.le32(UInt32(mainCommandSize))
        bytes.le64(UInt64(codeOffset))
        bytes.le64(0)

        // LC_SYMTAB (optional): nlist_64 records then the string table, after the code.
        var stringTable = Data([0])
        var nameOffsets: [UInt32] = []
        for symbol in symbols {
            nameOffsets.append(UInt32(stringTable.count))
            stringTable.append(contentsOf: Array(symbol.name.utf8) + [0])
        }
        let symbolOffset = (codeOffset + code.count + 7) & ~7
        let stringOffset = symbolOffset + symbols.count * 16
        if !symbols.isEmpty {
            bytes.le32(MachOConstants.loadCommandSymtab)
            bytes.le32(UInt32(symtabCommandSize))
            bytes.le32(UInt32(symbolOffset))
            bytes.le32(UInt32(symbols.count))
            bytes.le32(UInt32(stringOffset))
            bytes.le32(UInt32(stringTable.count))
        }

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        if !symbols.isEmpty {
            bytes.append(contentsOf: repeatElement(0, count: symbolOffset - bytes.count))
            for (index, symbol) in symbols.enumerated() {
                bytes.le32(nameOffsets[index])
                bytes.append(MachOConstants.symbolTypeSection | MachOConstants.symbolExternal)
                bytes.append(1)             // n_sect: __text
                bytes.append(contentsOf: [0, 0]) // n_desc
                bytes.le64(codeAddress + UInt64(symbol.offset))
            }
            bytes.append(stringTable)
        }
        return TinyMachO(bytes: bytes, baseAddress: codeAddress)
    }

    func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("TinyMachO")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
}

private extension Data {
    mutating func le32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func le64(_ value: UInt64) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func cString(_ string: String, length: Int) {
        var field = Array(string.utf8.prefix(length))
        field.append(contentsOf: repeatElement(0, count: length - field.count))
        append(contentsOf: field)
    }
}
