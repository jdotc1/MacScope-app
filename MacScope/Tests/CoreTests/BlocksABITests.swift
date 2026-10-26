import Foundation
import XCTest
@testable import MacScope

final class BlocksABITests: XCTestCase {

    private typealias ABI = BlocksABI
    private typealias Region = BlocksABI.CaptureRegion

    // MARK: - Compiler-emitted literals (clang 20.1.2, aarch64-macos, blocks-abi/blocks_matrix.m)

    /// `fixture_mixed_managed` at -O0: strong, weak and unretained captures described by the
    /// out-of-line layout string `31 52 61 00`.
    func testMixedManagedBlockFromCompilerBytes() {
        let block: UInt64 = 0x0100_C000
        let memory = SparseMemory(chunks: [
            block: hex("0003000200000000000000c200000000148100010000000058a8000100000000"
                + "0000000700000000000000070000000000000007000000000000000700000000"
                + "000000070000000000000007000000000000000700000000"),
            0x0100_A858: hex("00000000000000005800000000000000d8810001000000006c82000100000000"
                + "fca30001000000002ea9000100000000"),
            0x0100_A3FC: Array("v8@?0\0".utf8),
            0x0100_A92E: hex("31526100"),
        ])
        let decoded = ABI.decodeBlock(at: block, in: memory)
        XCTAssertEqual(decoded.gaps, [])
        XCTAssertEqual(decoded.header?.flags.rawValue, 0xC200_0000)
        XCTAssertEqual(decoded.invokeTarget, 0x0100_8114)
        XCTAssertEqual(decoded.descriptor, 0x0100_A858)
        XCTAssertEqual(decoded.size, 88)
        XCTAssertEqual(decoded.copyTarget, 0x0100_81D8)
        XCTAssertEqual(decoded.disposeTarget, 0x0100_826C)
        XCTAssertEqual(decoded.signature, "v8@?0")
        XCTAssertEqual(decoded.layoutField, 0x0100_A92E)
        XCTAssertEqual(decoded.captures, [
            Region(kind: .strong, offset: 32, size: 16, count: 2),
            Region(kind: .weak, offset: 48, size: 24, count: 3),
            Region(kind: .unretained, offset: 72, size: 16, count: 2),
        ])
    }

    /// `fixture_global` at -O0: a global literal with a signature, no helpers and no captures.
    func testGlobalBlockFromCompilerBytes() {
        let block: UInt64 = 0x0100_C100
        let memory = SparseMemory(chunks: [
            block: hex("00020002000000000000005000000000800000010000000058a4000100000000"),
            0x0100_A458: hex("00000000000000002000000000000000fca30001000000000000000000000000"),
            0x0100_A3FC: Array("v8@?0\0".utf8),
        ])
        let decoded = ABI.decodeBlock(at: block, in: memory)
        XCTAssertEqual(decoded.gaps, [])
        XCTAssertEqual(decoded.header?.flags.rawValue, 0x5000_0000)
        XCTAssertEqual(decoded.size, 32)
        XCTAssertNil(decoded.copyTarget)
        XCTAssertEqual(decoded.signature, "v8@?0")
        XCTAssertEqual(decoded.layoutField, 0)
        XCTAssertEqual(decoded.captures, [])
    }

    /// `fixture_byref_extended` at -O0: the block's descriptor (inline layout 0x10, one byref
    /// word) and the stack `__block` cell it captures, with an EXTENDED cell layout 0x101.
    func testByrefExtendedFromCompilerBytes() {
        let block: UInt64 = 0x0100_C200
        let descriptor: UInt64 = 0x0100_A500
        var literal = le64(0) + le32(0xC200_0000) + le32(0) + le64(0x0100_0100) + le64(descriptor)
        literal += le64(0x40F_FE98)
        let cell: UInt64 = 0x40F_FE98
        let memory = SparseMemory(chunks: [
            block: literal,
            descriptor: hex("000000000000000028000000000000000c03000100000000440300010000000040080001000000001000000000000000"),
            0x0100_0840: Array("v8@?0\0".utf8),
            cell: hex("000000000000000098fe0f040000000000000012480000009c010001000000000402000100000000"
                + "0101000000000000000000070000000000000007000000000807060504030201"),
        ])

        let decoded = ABI.decodeBlock(at: block, in: memory)
        XCTAssertEqual(decoded.gaps, [])
        XCTAssertEqual(decoded.size, 40)
        XCTAssertEqual(decoded.layoutField, 0x10)
        XCTAssertEqual(decoded.captures, [Region(kind: .byref, offset: 32, size: 8, count: 1)])

        let chain = ABI.decodeByref(at: cell, in: memory)
        XCTAssertEqual(chain.gaps, [])
        XCTAssertEqual(chain.terminal, cell)
        XCTAssertEqual(chain.cells.count, 1)
        let header = chain.cells[0].header
        XCTAssertEqual(header.flags, 0x1200_0000)
        XCTAssertEqual(header.size, 72)
        XCTAssertEqual(header.layoutKind, 1)
        XCTAssertEqual([header.keep, header.destroy, header.layout], [24, 32, 40])
        XCTAssertEqual(header.payloadOffset, 48)
        XCTAssertEqual(chain.cells[0].keepTarget, 0x0100_019C)
        XCTAssertEqual(chain.cells[0].destroyTarget, 0x0100_0204)
        XCTAssertEqual(chain.cells[0].layoutField, 0x101)
        XCTAssertEqual(chain.cells[0].captures, [
            Region(kind: .strong, offset: 48, size: 8, count: 1),
            Region(kind: .weak, offset: 56, size: 8, count: 1),
            Region(kind: .nonObjectBytes, offset: 64, size: 8, count: 8),
        ])
    }

    /// `fixture_strong_16` at -O2: sixteen strong words encoded as the single opcode `3F`.
    func testSixteenStrongWordsFromCompilerLayout() throws {
        let layout = try ABI.decodeLayout(value: 0x0100_A930, bytes: hex("3f00"), captureByteCount: 128)
        XCTAssertEqual(layout.regions, [Region(kind: .strong, offset: 0, size: 128, count: 16)])
        XCTAssertEqual(layout.consumed, 2)
    }

    // MARK: - Layout encoding boundaries

    func testInlineLayoutOrderAndTail() throws {
        let layout = try ABI.decodeLayout(value: 0x121, bytes: [], captureByteCount: 40)
        XCTAssertEqual(layout.regions, [
            Region(kind: .strong, offset: 0, size: 8, count: 1),
            Region(kind: .byref, offset: 8, size: 16, count: 2),
            Region(kind: .weak, offset: 24, size: 8, count: 1),
            Region(kind: .nonObjectBytes, offset: 32, size: 8, count: 8),
        ])
        XCTAssertEqual(layout.consumed, 0)
        let words = try ABI.decodeLayout(value: 0x123, bytes: [], captureByteCount: 48)
        XCTAssertEqual(words.regions.map(\.count), [1, 2, 3])
        XCTAssertEqual(words.regions.map(\.offset), [0, 8, 24])
    }

    func testOutOfLineCountIsNibblePlusOne() throws {
        let layout = try ABI.decodeLayout(value: 0x4000, bytes: hex("304f5000"), captureByteCount: 144)
        XCTAssertEqual(layout.regions.map(\.kind), [.strong, .byref, .weak])
        XCTAssertEqual(layout.regions.map(\.count), [1, 16, 1])
        XCTAssertEqual(layout.consumed, 4)
        // Opcode 1 counts bytes, opcode 2 counts words; the rest becomes a non-object tail.
        let bytes = try ABI.decodeLayout(value: 0x4000, bytes: hex("122200"), captureByteCount: 32)
        XCTAssertEqual(bytes.regions, [
            Region(kind: .nonObjectBytes, offset: 0, size: 3, count: 3),
            Region(kind: .nonObjectWords, offset: 3, size: 24, count: 3),
            Region(kind: .nonObjectBytes, offset: 27, size: 5, count: 5),
        ])
    }

    func testMalformedLayoutsThrow() {
        assertFailure(.reserved) { try ABI.decodeLayout(value: 0x4000, bytes: hex("307000"), captureByteCount: 64) }
        assertFailure(.reserved) { try ABI.decodeLayout(value: 0x4000, bytes: hex("0500"), captureByteCount: 64) }
        assertFailure(.overflow) { try ABI.decodeLayout(value: 0xFFF, bytes: [], captureByteCount: 8) }
        assertFailure(.overflow) { try ABI.decodeLayout(value: 0x4000, bytes: hex("3f00"), captureByteCount: 8) }
        assertFailure(.truncated) { try ABI.decodeLayout(value: 0x4000, bytes: hex("30"), captureByteCount: 64) }
        assertFailure(.limit) {
            try ABI.decodeLayout(value: 0x4000, bytes: [UInt8](repeating: 0x10, count: ABI.maxLayoutBytes), captureByteCount: 1 << 20)
        }
        assertFailure(.limit) { try ABI.decodeLayout(value: 0, bytes: [], captureByteCount: ABI.maxCaptureBytes + 1) }
    }

    // MARK: - Header and descriptor boundaries

    func testDescriptorFieldOffsets() throws {
        let fields = try ABI.DescriptorFields(flags: [.hasCopyDispose, .hasSignature])
        XCTAssertEqual(fields.minimumSize, 48)
        XCTAssertEqual([fields.copy, fields.dispose, fields.signature, fields.layout], [16, 24, 32, 40])
        let bare = try ABI.DescriptorFields(flags: [])
        XCTAssertEqual(bare.minimumSize, 16)
        XCTAssertNil(bare.signature)

        assertFailure(.unsupported) { try ABI.DescriptorFields(flags: .smallDescriptor) }
        assertFailure(.unsupported) { try ABI.DescriptorFields(flags: .inlineLayoutString) }
        assertFailure(.invalid) { try ABI.DescriptorFields(flags: .hasExtendedLayout) }
        assertFailure(.invalid) { try ABI.DescriptorFields(flags: .hasCtor) }
        assertFailure(.truncated) { try ABI.LiteralHeader([UInt8](repeating: 0, count: 31)) }
    }

    func testUnassignedBlockFlagBitsAreUnsupported() {
        let block: UInt64 = 0x2000
        let memory = SparseMemory(chunks: [
            block: le64(0) + le32(0x4001_0000) + le32(0) + le64(0x3000) + le64(0x2100),
            0x2100: le64(0) + le64(32) + le64(0x2200) + le64(0),
        ])
        let decoded = ABI.decodeBlock(at: block, in: memory)
        XCTAssertEqual(decoded.gaps, [.init(code: .unsupportedFlags, address: block + 8)])
        XCTAssertNil(decoded.descriptor)
    }

    func testDescriptorFieldsThatCannotBeProvenBecomeGaps() {
        let block: UInt64 = 0x2000
        let header = le64(0) + le32(0x4000_0000) + le32(0) + le64(0x3000) + le64(0x2100)
        var memory = SparseMemory(chunks: [block: header, 0x2100: le64(0) + le64(32) + le64(0x2200) + le64(0)])
        memory.relocations[block + 24] = .unresolved(symbol: "_descriptor")
        XCTAssertEqual(ABI.decodeBlock(at: block, in: memory).gaps,
                       [.init(code: .unresolvedPointer(symbol: "_descriptor"), address: block + 24)])

        let inFlags = SparseMemory(chunks: [block: header, 0x2100: le64(1) + le64(32)])
        XCTAssertEqual(ABI.decodeBlock(at: block, in: inFlags).gaps, [.init(code: .unsupportedDescriptorVariant, address: 0x2100)])

        let tooSmall = SparseMemory(chunks: [block: header, 0x2100: le64(0) + le64(31)])
        XCTAssertEqual(ABI.decodeBlock(at: block, in: tooSmall).gaps, [.init(code: .invalidDescriptor, address: 0x2108)])

        let unterminated = SparseMemory(chunks: [block: header, 0x2100: le64(0) + le64(32) + le64(0x2200) + le64(0),
                                                 0x2200: Array("v8@?0".utf8)])
        XCTAssertEqual(ABI.decodeBlock(at: block, in: unterminated).gaps, [.init(code: .unterminatedSignature, address: 0x2200)])

        XCTAssertEqual(ABI.decodeBlock(at: block + 4, in: unterminated).gaps, [.init(code: .misalignedSubject, address: block + 4)])
    }

    // MARK: - Byref boundaries

    func testByrefHeaderOffsetsAndLimits() throws {
        func cell(flags: UInt32, size: UInt32) -> [UInt8] { le64(0) + le64(0) + le32(flags) + le32(size) }
        let offsets = try [0, 1 << 25, 1 << 28, (1 << 25) | (1 << 28)].map {
            try ABI.ByrefHeader(cell(flags: UInt32($0), size: 48)).payloadOffset
        }
        XCTAssertEqual(offsets, [24, 40, 32, 48])
        for kind: UInt32 in 3...5 {
            assertFailure(.invalid) { try ABI.ByrefHeader(cell(flags: kind << 28, size: 24)) }
            XCTAssertNoThrow(try ABI.ByrefHeader(cell(flags: kind << 28, size: 32)))
        }
        assertFailure(.reserved) { try ABI.ByrefHeader(cell(flags: 1 << 16, size: 24)) }
        assertFailure(.reserved) { try ABI.ByrefHeader(cell(flags: 1 << 26, size: 24)) }
        assertFailure(.reserved) { try ABI.ByrefHeader(cell(flags: 6 << 28, size: 32)) }
        assertFailure(.invalid) { try ABI.ByrefHeader(cell(flags: 1 << 25, size: 24)) }
        XCTAssertNoThrow(try ABI.ByrefHeader(cell(flags: 0, size: 24 + (1 << 20))))
        assertFailure(.limit) { try ABI.ByrefHeader(cell(flags: 0, size: 24 + (1 << 20) + 1)) }
        assertFailure(.truncated) { try ABI.ByrefHeader([UInt8](repeating: 0, count: 23)) }
    }

    func testByrefForwardingChainAndCycle() {
        let heap: UInt64 = 0x5000
        let stack: UInt64 = 0x6000
        let chain = ABI.decodeByref(at: stack, in: SparseMemory(chunks: [
            stack: le64(0) + le64(heap) + le32(3 << 28) + le32(32) + le64(0),
            heap: le64(0) + le64(heap) + le32(3 << 28) + le32(40) + le64(0) + le64(0),
        ]))
        XCTAssertEqual(chain.gaps, [])
        XCTAssertEqual(chain.cells.map(\.address), [stack, heap])
        XCTAssertEqual(chain.terminal, heap)
        XCTAssertEqual(chain.cells[1].captures, [
            Region(kind: .strong, offset: 24, size: 8, count: 1),
            Region(kind: .nonObjectBytes, offset: 32, size: 8, count: 8),
        ])

        let cycle = ABI.decodeByref(at: stack, in: SparseMemory(chunks: [
            stack: le64(0) + le64(heap) + le32(2 << 28) + le32(24),
            heap: le64(0) + le64(stack) + le32(2 << 28) + le32(24),
        ]))
        XCTAssertEqual(cycle.gaps, [.init(code: .forwardingCycle, address: stack)])
        XCTAssertNil(cycle.terminal)

        let legacy = ABI.decodeByref(at: stack, in: SparseMemory(chunks: [
            stack: le64(0) + le64(stack) + le32(0) + le32(32) + le64(0),
        ]))
        XCTAssertEqual(legacy.gaps, [.init(code: .captureLayoutUnavailable, address: stack)])
        XCTAssertEqual(legacy.terminal, stack)
    }

    // MARK: - Helpers

    private struct SparseMemory: BlocksABIMemory {
        var chunks: [UInt64: [UInt8]]
        var relocations: [UInt64: BlocksABI.PointerResolution] = [:]

        func bytes(at address: UInt64, count: Int) -> [UInt8]? {
            for (base, data) in chunks where address >= base && address - base < UInt64(data.count) {
                let start = Int(address - base)
                guard count <= data.count - start else { return nil }
                return Array(data[start..<start + count])
            }
            return nil
        }

        func pointer(at slot: UInt64) -> BlocksABI.PointerResolution? {
            if let relocation = relocations[slot] { return relocation }
            return bytes(at: slot, count: 8).map { .stored(BlocksABI.u64($0, 0)) }
        }
    }

    private func assertFailure<T>(_ expected: BlocksABI.Failure, file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? BlocksABI.Failure, expected, file: file, line: line)
        }
    }

    private func hex(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
}
