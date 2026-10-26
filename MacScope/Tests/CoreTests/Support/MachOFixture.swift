import Foundation
import XCTest
@testable import MacScope

// Synthetic Mach-O builder shared by tests in several bundles (split out of
// MachOImportTests.swift so CoreTests and Phase2Tests can both compile it
// without compiling MachOImportTests' test class twice).

struct MachOFixture {
    var bytes: Data
    var code: Data
    var codeOffset: Int
    var baseAddress: UInt64
    var stringLiteralAddress: UInt64? = nil
    var selectorStringAddress: UInt64? = nil
    var classNameStringAddress: UInt64? = nil
    var selectorReferenceAddress: UInt64? = nil
    var classReferenceAddress: UInt64? = nil
    var codeSignatureOffset: UInt32 = 0
    var codeSignatureSize: UInt32 = 0
    var dyldChainedFixupsOffset: UInt32 = 0
    var dyldChainedFixupsSize: UInt32 = 0
    /// VM address of the BIND pointer in the chained-fixups walk fixture.
    var chainedBindAddress: UInt64 = 0
    /// VM address of the REBASE pointer in the chained-fixups walk fixture.
    var chainedRebaseAddress: UInt64 = 0
    /// In-image target VM address the REBASE entry resolves to.
    var chainedRebaseTargetAddress: UInt64 = 0
    var relocationOffset: UInt32 = 0
    var relocationCount: UInt32 = 0
    var arm64SliceOffset: Int = 0
    var arm64SliceSize: Int = 0
    var stubAddress: UInt64 = 0
    var lazyPointerAddress: UInt64 = 0
    var unwindInfoAddress: UInt64 = 0
    var unwindInfoOffset: UInt32 = 0
    var unwindInfoSize: UInt32 = 0
    var ehFrameSize: UInt32 = 0
    var exceptionTableSize: UInt32 = 0
    var compactUnwindAddress: UInt64 = 0
    var compactUnwindOffset: UInt32 = 0
    var compactUnwindSize: UInt32 = 0
    var functionStartsOffset: UInt32 = 0
    var functionStartsSize: UInt32 = 0

    static func makeExecutable(code: Data = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x01, 0x40, 0xf9,
            0x00, 0x01, 0x00, 0xf9,
            0x00, 0x00, 0x80, 0x52,
            0x01, 0x00, 0x00, 0x94,
            0xc0, 0x03, 0x5f, 0xd6
        ]),
        cpuType: Int32 = MachOConstants.cpuTypeARM64,
        cpuSubtype: Int32 = 0
    ) -> MachOFixture {
        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)
        let textFileSize = UInt64(codeOffset + code.count)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: cpuType))
        bytes.appendUInt32LE(UInt32(bitPattern: cpuSubtype))
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)

        return MachOFixture(bytes: bytes, code: code, codeOffset: codeOffset, baseAddress: codeAddress)
    }

    static func makeExecutableWithEncryptionInfo(
        command: UInt32,
        cryptID: UInt32
    ) -> MachOFixture {
        precondition(command == 0x21 || command == 0x2c)
        var fixture = makeExecutable()
        let mainCommandOffset = 32 + 72 + 80
        fixture.bytes.replaceUInt32LE(at: mainCommandOffset, with: command)
        fixture.bytes.replaceUInt32LE(at: mainCommandOffset + 4, with: 24)
        fixture.bytes.replaceUInt32LE(
            at: mainCommandOffset + 8,
            with: UInt32(fixture.codeOffset)
        )
        fixture.bytes.replaceUInt32LE(
            at: mainCommandOffset + 12,
            with: UInt32(fixture.code.count)
        )
        fixture.bytes.replaceUInt32LE(at: mainCommandOffset + 16, with: cryptID)
        fixture.bytes.replaceUInt32LE(at: mainCommandOffset + 20, with: 0)
        return fixture
    }

    static func makeExecutableWithProtectedTextSegment() -> MachOFixture {
        var fixture = makeExecutable()
        let segmentFlagsOffset = 32 + 68
        fixture.bytes.replaceUInt32LE(at: segmentFlagsOffset, with: 0x8)
        return fixture
    }

    static func makeExecutableWithConditionalBranches() -> MachOFixture {
        makeExecutable(code: Data([
            0x00, 0x00, 0x80, 0x52,
            0x60, 0x00, 0x00, 0x34,
            0x21, 0x00, 0x80, 0x52,
            0x02, 0x00, 0x00, 0x14,
            0x41, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ]))
    }

    static func makeExecutableWithInternalAndExternalDirectCalls() -> MachOFixture {
        makeExecutable(code: Data([
            0x00, 0x00, 0x80, 0x52,
            0x03, 0x00, 0x00, 0x94,
            0x06, 0x00, 0x00, 0x94,
            0xc0, 0x03, 0x5f, 0xd6,
            0xff, 0x83, 0x00, 0xd1,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ]))
    }

    static func makeUniversalExecutable() -> MachOFixture {
        let arm64 = makeExecutable()
        let x86Slice = Data([
            0xcf, 0xfa, 0xed, 0xfe,
            0x07, 0x00, 0x00, 0x01,
            0x03, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00
        ])
        let fatHeaderSize = 8 + 20 * 2
        let x86SliceOffset = aligned(fatHeaderSize, to: 16)
        let arm64SliceOffset = aligned(x86SliceOffset + x86Slice.count, to: 16)

        var bytes = Data()
        bytes.appendUInt32BE(MachOConstants.fatMagic)
        bytes.appendUInt32BE(2)

        bytes.appendUInt32BE(UInt32(bitPattern: MachOConstants.cpuTypeX86_64))
        bytes.appendUInt32BE(3)
        bytes.appendUInt32BE(UInt32(x86SliceOffset))
        bytes.appendUInt32BE(UInt32(x86Slice.count))
        bytes.appendUInt32BE(4)

        bytes.appendUInt32BE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32BE(0)
        bytes.appendUInt32BE(UInt32(arm64SliceOffset))
        bytes.appendUInt32BE(UInt32(arm64.bytes.count))
        bytes.appendUInt32BE(4)

        bytes.appendPadding(to: x86SliceOffset)
        bytes.append(x86Slice)
        bytes.appendPadding(to: arm64SliceOffset)
        bytes.append(arm64.bytes)

        return MachOFixture(
            bytes: bytes,
            code: arm64.code,
            codeOffset: arm64.codeOffset,
            baseAddress: arm64.baseAddress,
            arm64SliceOffset: arm64SliceOffset,
            arm64SliceSize: arm64.bytes.count
        )
    }

    /// A 2-slice universal binary whose BOTH slices are FULL thin Mach-O executables
    /// (x86_64 at index 0, arm64 at index 1). Unlike `makeUniversalExecutable` (whose
    /// x86 slice is a 16-byte stub), this lets a test parse either slice end-to-end —
    /// exercising explicit slice selection of the non-default x86_64 slice. The byte
    /// content of both slices is the standard arm64 fixture code; only the fat-table
    /// CPU types differ, which is all the selector keys on.
    /// A fat container of the given (cputype, raw cpusubtype, slice bytes), page-aligned.
    static func makeFatContainer(_ slices: [(cpuType: Int32, cpuSubtype: UInt32, bytes: Data)]) -> Data {
        var offsets: [Int] = []
        var next = 0x1000
        for slice in slices {
            offsets.append(next)
            next = aligned(next + slice.bytes.count, to: 0x1000)
        }
        var bytes = Data()
        bytes.appendUInt32BE(MachOConstants.fatMagic)
        bytes.appendUInt32BE(UInt32(slices.count))
        for (slice, offset) in zip(slices, offsets) {
            bytes.appendUInt32BE(UInt32(bitPattern: slice.cpuType))
            bytes.appendUInt32BE(slice.cpuSubtype)
            bytes.appendUInt32BE(UInt32(offset))
            bytes.appendUInt32BE(UInt32(slice.bytes.count))
            bytes.appendUInt32BE(12)
        }
        for (slice, offset) in zip(slices, offsets) {
            bytes.appendPadding(to: offset)
            bytes.append(slice.bytes)
        }
        return bytes
    }

    static func makeUniversalDualExecutable() -> MachOFixture {
        let x86 = makeExecutable(cpuType: MachOConstants.cpuTypeX86_64)
        let arm64 = makeExecutable(cpuType: MachOConstants.cpuTypeARM64)

        let fatHeaderSize = 8 + 20 * 2
        let x86SliceOffset = aligned(fatHeaderSize, to: 16)
        let arm64SliceOffset = aligned(x86SliceOffset + x86.bytes.count, to: 16)

        var bytes = Data()
        bytes.appendUInt32BE(MachOConstants.fatMagic)
        bytes.appendUInt32BE(2)

        bytes.appendUInt32BE(UInt32(bitPattern: MachOConstants.cpuTypeX86_64))
        bytes.appendUInt32BE(3)
        bytes.appendUInt32BE(UInt32(x86SliceOffset))
        bytes.appendUInt32BE(UInt32(x86.bytes.count))
        bytes.appendUInt32BE(4)

        bytes.appendUInt32BE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32BE(0)
        bytes.appendUInt32BE(UInt32(arm64SliceOffset))
        bytes.appendUInt32BE(UInt32(arm64.bytes.count))
        bytes.appendUInt32BE(4)

        bytes.appendPadding(to: x86SliceOffset)
        bytes.append(x86.bytes)
        bytes.appendPadding(to: arm64SliceOffset)
        bytes.append(arm64.bytes)

        return MachOFixture(
            bytes: bytes,
            code: arm64.code,
            codeOffset: arm64.codeOffset,
            baseAddress: arm64.baseAddress,
            arm64SliceOffset: arm64SliceOffset,
            arm64SliceSize: arm64.bytes.count
        )
    }

    /// A malformed universal binary: the fat header claims a slice whose offset/size
    /// point beyond the end of the file. The parser must refuse it (never trap).
    static func makeUniversalWithOutOfRangeSlice() -> MachOFixture {
        var bytes = Data()
        bytes.appendUInt32BE(MachOConstants.fatMagic)
        bytes.appendUInt32BE(1)

        bytes.appendUInt32BE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32BE(0)
        bytes.appendUInt32BE(0x10_000) // offset well past the (tiny) file
        bytes.appendUInt32BE(0x10_000) // size well past the file
        bytes.appendUInt32BE(4)

        // Pad to just past the architecture table so the table read itself succeeds and
        // the failure is specifically the out-of-range slice range.
        bytes.appendPadding(to: 8 + 20)

        return MachOFixture(bytes: bytes, code: Data(), codeOffset: 0, baseAddress: 0)
    }

    /// A malformed universal binary whose fat `nfat_arch` count is absurdly large (a
    /// classic fuzzing trap). The bounded parser must reject it rather than allocate or
    /// trap.
    static func makeUniversalWithOverflowingArchCount() -> MachOFixture {
        var bytes = Data()
        bytes.appendUInt32BE(MachOConstants.fatMagic)
        bytes.appendUInt32BE(0xffff_ffff) // nfat_arch = UINT32_MAX
        bytes.appendPadding(to: 64)
        return MachOFixture(bytes: bytes, code: Data(), codeOffset: 0, baseAddress: 0)
    }

    /// An arm64 executable whose entry point is declared via LC_UNIXTHREAD (initial PC
    /// in an `ARM_THREAD_STATE64` block) instead of LC_MAIN. The PC is the code address,
    /// so `entryPointVirtualAddress`/`entryPointAddress` must resolve to `baseAddress`.
    static func makeUnixThreadExecutable(
        cpuType: Int32 = MachOConstants.cpuTypeARM64
    ) -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])

        // ARM_THREAD_STATE64 = 68 u32 words (x0..x28, fp, lr, sp = 32 u64 regs = 64
        // words, then cpsr/flags); x86_THREAD_STATE64 = 42 words. We only need the PC
        // slot filled and the count large enough to cover it.
        let isARM = cpuType == MachOConstants.cpuTypeARM64
        let flavor: UInt32 = isARM ? MachOConstants.armThreadState64Flavor : MachOConstants.x86ThreadState64Flavor
        let pcWordIndex = isARM ? MachOConstants.armThreadState64PCWordIndex : MachOConstants.x86ThreadState64RIPWordIndex
        let wordCount = isARM ? 68 : 42

        let headerSize = 32
        let segmentCommandSize = 72 + 80
        // 8 (lc header) + 8 (flavor + count) + wordCount * 4 (state words).
        let threadCommandSize = 16 + wordCount * 4
        let loadCommandsSize = segmentCommandSize + threadCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)
        let textFileSize = UInt64(codeOffset + code.count)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: cpuType))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandUnixThread)
        bytes.appendUInt32LE(UInt32(threadCommandSize))
        bytes.appendUInt32LE(flavor)
        bytes.appendUInt32LE(UInt32(wordCount))
        for word in 0..<wordCount {
            // PC occupies the low u32 of its u64 slot (a u64 = two consecutive words).
            if word == pcWordIndex {
                bytes.appendUInt32LE(UInt32(codeAddress & 0xffff_ffff))
            } else if word == pcWordIndex + 1 {
                bytes.appendUInt32LE(UInt32(codeAddress >> 32))
            } else {
                bytes.appendUInt32LE(0)
            }
        }

        precondition(bytes.count == codeOffset)
        bytes.append(code)

        return MachOFixture(bytes: bytes, code: code, codeOffset: codeOffset, baseAddress: codeAddress)
    }

    static func makeExecutableWithFunctionStarts() -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x01, 0x40, 0xf9,
            0x00, 0x01, 0x00, 0xf9,
            0x00, 0x00, 0x80, 0x52,
            0x01, 0x00, 0x00, 0x94,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let functionStartsCommandSize = 16
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize
            + functionStartsCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        var functionStarts = Data()
        functionStarts.appendULEB128(UInt64(codeOffset))
        functionStarts.appendULEB128(0x1c)
        functionStarts.appendULEB128(0)
        let functionStartsOffset = aligned(codeOffset + code.count, to: 8)
        let finalFileSize = functionStartsOffset + functionStarts.count
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandFunctionStarts)
        bytes.appendUInt32LE(UInt32(functionStartsCommandSize))
        bytes.appendUInt32LE(UInt32(functionStartsOffset))
        bytes.appendUInt32LE(UInt32(functionStarts.count))

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.appendPadding(to: functionStartsOffset)
        bytes.append(functionStarts)

        precondition(bytes.count == finalFileSize)
        return MachOFixture(bytes: bytes, code: code, codeOffset: codeOffset, baseAddress: codeAddress)
    }

    static func makeExecutableWithExceptionMetadata() -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])

        var unwindInfo = Data()
        unwindInfo.appendUInt32LE(1)
        unwindInfo.appendUInt32LE(28)
        unwindInfo.appendUInt32LE(2)
        unwindInfo.appendUInt32LE(36)
        unwindInfo.appendUInt32LE(1)
        unwindInfo.appendUInt32LE(40)
        unwindInfo.appendUInt32LE(2)
        unwindInfo.appendUInt32LE(0x0100_0000)
        unwindInfo.appendUInt32LE(0x0200_0000)
        unwindInfo.appendUInt32LE(0)
        unwindInfo.appendUInt32LE(0)
        unwindInfo.appendUInt32LE(0)
        unwindInfo.appendUInt32LE(0)
        unwindInfo.appendUInt32LE(UInt32(code.count))
        unwindInfo.appendUInt32LE(0)
        unwindInfo.appendUInt32LE(0)
        precondition(unwindInfo.count == 64)

        let ehFrame = Data([
            0x10, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x01, 0x7a, 0x52, 0x00,
            0x01, 0x78, 0x1e, 0x01
        ])
        let exceptionTable = Data([
            0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08,
            0x09, 0x0a, 0x0b, 0x0c
        ])

        let headerSize = 32
        let textSectionCount = 4
        let ldSectionCount = 1
        let textSegmentCommandSize = 72 + 80 * textSectionCount
        let ldSegmentCommandSize = 72 + 80 * ldSectionCount
        let functionStartsCommandSize = 16
        let mainCommandSize = 24
        let loadCommandsSize = textSegmentCommandSize
            + ldSegmentCommandSize
            + functionStartsCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let unwindInfoOffset = aligned(codeOffset + code.count, to: 4)
        let ehFrameOffset = aligned(unwindInfoOffset + unwindInfo.count, to: 8)
        let exceptionTableOffset = ehFrameOffset + ehFrame.count

        var compactUnwind = Data()
        compactUnwind.appendUInt64LE(UInt64(codeOffset))
        compactUnwind.appendUInt32LE(UInt32(code.count))
        compactUnwind.appendUInt32LE(0x0400_0000)
        compactUnwind.appendUInt64LE(0)
        compactUnwind.appendUInt64LE(0)
        compactUnwind.appendUInt64LE(UInt64(codeOffset + 4))
        compactUnwind.appendUInt32LE(UInt32(code.count - 4))
        compactUnwind.appendUInt32LE(0x0400_0001)
        compactUnwind.appendUInt64LE(0)
        compactUnwind.appendUInt64LE(UInt64(exceptionTableOffset))

        var functionStarts = Data()
        functionStarts.appendULEB128(UInt64(codeOffset))
        functionStarts.appendULEB128(0)

        let compactUnwindOffset = aligned(exceptionTableOffset + exceptionTable.count, to: 8)
        let functionStartsOffset = aligned(compactUnwindOffset + compactUnwind.count, to: 8)
        let finalFileSize = functionStartsOffset + functionStarts.count
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)
        let unwindInfoAddress = imageBase + UInt64(unwindInfoOffset)
        let ehFrameAddress = imageBase + UInt64(ehFrameOffset)
        let exceptionTableAddress = imageBase + UInt64(exceptionTableOffset)
        let compactUnwindAddress = imageBase + UInt64(compactUnwindOffset)
        let textFileSize = UInt64(exceptionTableOffset + exceptionTable.count)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(4)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(textSegmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(UInt32(textSectionCount))
        bytes.appendUInt32LE(0)

        appendSection(
            to: &bytes,
            sectionName: "__text",
            segmentName: "__TEXT",
            address: codeAddress,
            size: UInt64(code.count),
            fileOffset: UInt32(codeOffset),
            alignment: 2,
            flags: MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        appendSection(
            to: &bytes,
            sectionName: "__unwind_info",
            segmentName: "__TEXT",
            address: unwindInfoAddress,
            size: UInt64(unwindInfo.count),
            fileOffset: UInt32(unwindInfoOffset),
            alignment: 2,
            flags: 0
        )
        appendSection(
            to: &bytes,
            sectionName: "__eh_frame",
            segmentName: "__TEXT",
            address: ehFrameAddress,
            size: UInt64(ehFrame.count),
            fileOffset: UInt32(ehFrameOffset),
            alignment: 3,
            flags: 0
        )
        appendSection(
            to: &bytes,
            sectionName: "__gcc_except_tab",
            segmentName: "__TEXT",
            address: exceptionTableAddress,
            size: UInt64(exceptionTable.count),
            fileOffset: UInt32(exceptionTableOffset),
            alignment: 2,
            flags: 0
        )

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(ldSegmentCommandSize))
        bytes.appendFixedCString("__LD", length: 16)
        bytes.appendUInt64LE(compactUnwindAddress)
        bytes.appendUInt64LE(UInt64(compactUnwind.count))
        bytes.appendUInt64LE(UInt64(compactUnwindOffset))
        bytes.appendUInt64LE(UInt64(compactUnwind.count))
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(UInt32(ldSectionCount))
        bytes.appendUInt32LE(0)

        appendSection(
            to: &bytes,
            sectionName: "__compact_unwind",
            segmentName: "__LD",
            address: compactUnwindAddress,
            size: UInt64(compactUnwind.count),
            fileOffset: UInt32(compactUnwindOffset),
            alignment: 3,
            flags: 0
        )

        bytes.appendUInt32LE(MachOConstants.loadCommandFunctionStarts)
        bytes.appendUInt32LE(UInt32(functionStartsCommandSize))
        bytes.appendUInt32LE(UInt32(functionStartsOffset))
        bytes.appendUInt32LE(UInt32(functionStarts.count))

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.appendPadding(to: unwindInfoOffset)
        bytes.append(unwindInfo)
        bytes.appendPadding(to: ehFrameOffset)
        bytes.append(ehFrame)
        bytes.append(exceptionTable)
        bytes.appendPadding(to: compactUnwindOffset)
        bytes.append(compactUnwind)
        bytes.appendPadding(to: functionStartsOffset)
        bytes.append(functionStarts)

        precondition(bytes.count == finalFileSize)
        return MachOFixture(
            bytes: bytes,
            code: code,
            codeOffset: codeOffset,
            baseAddress: codeAddress,
            unwindInfoAddress: unwindInfoAddress,
            unwindInfoOffset: UInt32(unwindInfoOffset),
            unwindInfoSize: UInt32(unwindInfo.count),
            ehFrameSize: UInt32(ehFrame.count),
            exceptionTableSize: UInt32(exceptionTable.count),
            compactUnwindAddress: compactUnwindAddress,
            compactUnwindOffset: UInt32(compactUnwindOffset),
            compactUnwindSize: UInt32(compactUnwind.count),
            functionStartsOffset: UInt32(functionStartsOffset),
            functionStartsSize: UInt32(functionStarts.count)
        )
    }

    static func makeExecutableWithRPathsAndCodeSignature() -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let codeSignature = makeCodeSignatureSuperBlob()
        let rpaths = [
            "@executable_path/../Frameworks",
            "@loader_path/PlugIns"
        ]
        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let rpathCommandSizes = rpaths.map { aligned(12 + $0.utf8.count + 1, to: 8) }
        let codeSignatureCommandSize = 16
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize
            + rpathCommandSizes.reduce(0, +)
            + codeSignatureCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let codeSignatureOffset = aligned(codeOffset + code.count, to: 16)
        let finalFileSize = codeSignatureOffset + codeSignature.count
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        for (index, rpath) in rpaths.enumerated() {
            bytes.appendUInt32LE(MachOConstants.loadCommandRPath)
            bytes.appendUInt32LE(UInt32(rpathCommandSizes[index]))
            bytes.appendUInt32LE(12)
            bytes.appendFixedCString(rpath, length: rpathCommandSizes[index] - 12)
        }

        bytes.appendUInt32LE(MachOConstants.loadCommandCodeSignature)
        bytes.appendUInt32LE(UInt32(codeSignatureCommandSize))
        bytes.appendUInt32LE(UInt32(codeSignatureOffset))
        bytes.appendUInt32LE(UInt32(codeSignature.count))

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.appendPadding(to: codeSignatureOffset)
        bytes.append(codeSignature)

        precondition(bytes.count == finalFileSize)
        return MachOFixture(
            bytes: bytes,
            code: code,
            codeOffset: codeOffset,
            baseAddress: codeAddress,
            codeSignatureOffset: UInt32(codeSignatureOffset),
            codeSignatureSize: UInt32(codeSignature.count)
        )
    }

    static func makeExecutableWithLinkedLibraryMetadata() -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let rpaths = [
            "@executable_path/../Frameworks",
            "@loader_path/../PlugIns"
        ]
        let linkedDylibs: [(command: UInt32, name: String)] = [
            (MachOConstants.loadCommandLoadDylib, "@rpath/FixtureSupport.framework/FixtureSupport"),
            (MachOConstants.loadCommandLoadWeakDylib, "@loader_path/../PlugIns/OptionalPlugin.framework/OptionalPlugin"),
            (MachOConstants.loadCommandReexportDylib, "/System/Library/Frameworks/AppKit.framework/AppKit"),
            (MachOConstants.loadCommandLoadUpwardDylib, "@executable_path/../Frameworks/Upward.framework/Upward"),
            (MachOConstants.loadCommandLazyLoadDylib, "RelativeSupport.framework/RelativeSupport")
        ]
        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let rpathCommandSizes = rpaths.map { aligned(12 + $0.utf8.count + 1, to: 8) }
        let dylibCommandSizes = linkedDylibs.map { aligned(24 + $0.name.utf8.count + 1, to: 8) }
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize
            + rpathCommandSizes.reduce(0, +)
            + dylibCommandSizes.reduce(0, +)
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)
        let textFileSize = UInt64(codeOffset + code.count)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(UInt32(1 + rpaths.count + linkedDylibs.count + 1))
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        appendSection(
            to: &bytes,
            sectionName: "__text",
            segmentName: "__TEXT",
            address: codeAddress,
            size: UInt64(code.count),
            fileOffset: UInt32(codeOffset),
            alignment: 2,
            flags: MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )

        for (index, rpath) in rpaths.enumerated() {
            bytes.appendUInt32LE(MachOConstants.loadCommandRPath)
            bytes.appendUInt32LE(UInt32(rpathCommandSizes[index]))
            bytes.appendUInt32LE(12)
            bytes.appendFixedCString(rpath, length: rpathCommandSizes[index] - 12)
        }

        for (index, dylib) in linkedDylibs.enumerated() {
            bytes.appendUInt32LE(dylib.command)
            bytes.appendUInt32LE(UInt32(dylibCommandSizes[index]))
            bytes.appendUInt32LE(24)
            bytes.appendUInt32LE(0)
            bytes.appendUInt32LE(encodedVersion(1, 0, 0))
            bytes.appendUInt32LE(encodedVersion(1, 0, 0))
            bytes.appendFixedCString(dylib.name, length: dylibCommandSizes[index] - 24)
        }

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)

        return MachOFixture(bytes: bytes, code: code, codeOffset: codeOffset, baseAddress: codeAddress)
    }

    static func makeExecutableWithDyldChainedFixups() -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let startsOffset: UInt32 = 28
        let importsOffset: UInt32 = 32
        let symbolsOffset: UInt32 = 36
        var chainedFixups = Data()
        chainedFixups.appendUInt32LE(0)
        chainedFixups.appendUInt32LE(startsOffset)
        chainedFixups.appendUInt32LE(importsOffset)
        chainedFixups.appendUInt32LE(symbolsOffset)
        chainedFixups.appendUInt32LE(1)
        chainedFixups.appendUInt32LE(MachOConstants.dyldChainedImport)
        chainedFixups.appendUInt32LE(MachOConstants.dyldChainedSymbolsUncompressed)
        chainedFixups.appendUInt32LE(0)
        chainedFixups.appendUInt32LE(0)
        chainedFixups.appendNullTerminatedString("_puts")

        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let chainedFixupsCommandSize = 16
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize
            + chainedFixupsCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let chainedFixupsOffset = aligned(codeOffset + code.count, to: 8)
        let finalFileSize = chainedFixupsOffset + chainedFixups.count
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandDyldChainedFixups)
        bytes.appendUInt32LE(UInt32(chainedFixupsCommandSize))
        bytes.appendUInt32LE(UInt32(chainedFixupsOffset))
        bytes.appendUInt32LE(UInt32(chainedFixups.count))

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.appendPadding(to: chainedFixupsOffset)
        bytes.append(chainedFixups)

        precondition(bytes.count == finalFileSize)
        return MachOFixture(
            bytes: bytes,
            code: code,
            codeOffset: codeOffset,
            baseAddress: codeAddress,
            dyldChainedFixupsOffset: UInt32(chainedFixupsOffset),
            dyldChainedFixupsSize: UInt32(chainedFixups.count)
        )
    }

    /// A Mach-O with a __TEXT + __DATA segment, an LC_LOAD_DYLIB (libSystem, ordinal 1),
    /// and a *fully populated* LC_DYLD_CHAINED_FIXUPS payload: a real
    /// dyld_chained_starts_in_image -> per-segment starts -> per-page chain holding two
    /// DYLD_CHAINED_PTR_64 entries — one BIND (-> import `_puts`) followed by one REBASE
    /// (-> an in-image target VA). Lets the walk be asserted end to end.
    ///
    /// `tamper` lets a malformed-input test mutate the assembled bytes (e.g. corrupt the
    /// starts_offset or imports_format) before returning, mirroring `replaceUInt32*`.
    static func makeExecutableWithChainedFixupChain(
        importsFormat: UInt32 = MachOConstants.dyldChainedImport,
        imageBase: UInt64 = 0x1_0000_0000,
        pointerFormat: UInt16 = 2,
        rebaseRawOverride: UInt64? = nil,
        objectiveCReferenceSection: Bool = false,
        importCount: Int = 1,
        importLibraryOrdinalRaw: UInt16 = 1,
        importAddend: Int64 = 0,
        pageStartOverflow: [UInt16] = [],
        tamper: ((inout Data, _ chainedFixupsOffset: Int) -> Void)? = nil
    ) -> MachOFixture {
        let code = Data([
            0xc0, 0x03, 0x5f, 0xd6   // ret
        ])
        let dylibName = "/usr/lib/libSystem.B.dylib"

        let headerSize = 32
        let segmentCommandSize = 72 + 80          // segment + 1 section
        let dataSegmentCommandSize = 72 + (objectiveCReferenceSection ? 80 : 0)
        let dylibCommandSize = aligned(24 + dylibName.utf8.count + 1, to: 8)
        let chainedFixupsCommandSize = 16
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize
            + dataSegmentCommandSize
            + dylibCommandSize
            + chainedFixupsCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let codeAddress = imageBase + UInt64(codeOffset)

        // __DATA holds the chain: two 8-byte pointers.
        let dataFileOffset = aligned(codeOffset + code.count, to: 8)
        let dataVMAddress = imageBase + UInt64(dataFileOffset)
        let chainEntrySize = 8
        let dataContentSize = chainEntrySize * 2

        // Build the two chain entries (DYLD_CHAINED_PTR_64, stride 4, next in stride units).
        // entry0 (BIND): bind:1, next:2 (=> +8 bytes to entry1), ordinal:0.
        let arm64e = [UInt16(1), 9, 12].contains(pointerFormat)
        let bindRaw: UInt64 = arm64e
            ? (UInt64(1) << 62) | (UInt64(1) << 51)
            : (UInt64(1) << 63) | (UInt64(2) << 51)
        // entry1 (REBASE): bind:0, next:0 (end), target:36 bits = rebase target VA.
        let rebaseTarget = codeAddress              // points back at the __text entry
        let rebaseRaw: UInt64 = rebaseRawOverride ?? ([UInt16(6), 9, 12].contains(pointerFormat)
            ? UInt64(codeOffset) : rebaseTarget)
        var dataContent = Data()
        dataContent.appendUInt64LE(bindRaw)
        dataContent.appendUInt64LE(rebaseRaw)

        // Assemble the chained-fixups payload: header, starts_in_image, starts_in_segment
        // (for the __DATA segment, index 1), one page, the imports table, and the symbol pool.
        let pageSize: UInt16 = 0x4000
        // Layout the payload sub-structures relative to the payload start.
        let startsOffset = 32                         // after the 28-byte header, 4-aligned
        // starts_in_image: seg_count plus one seg_info_offset per load-command segment.
        let segInfoOffsetFromStarts = 12
        // starts_in_segment: size(4)+page_size(2)+pointer_format(2)+segment_offset(8)
        //   +max_valid_pointer(4)+page_count(2)+page_start[1](2) = 24 bytes.
        // `pageStartOverflow` appends DYLD_CHAINED_PTR_START_MULTI chain_starts[] entries after
        // page_start[0] (padded to 4 bytes so the imports table stays aligned).
        let startsInSegmentSize = 24 + aligned(pageStartOverflow.count * 2, to: 4)
        let importsOffset = startsOffset + segInfoOffsetFromStarts + startsInSegmentSize
        let importEntrySize: Int                       // DYLD_CHAINED_IMPORT / _ADDEND / _ADDEND64
        switch importsFormat {
        case MachOConstants.dyldChainedImportAddend: importEntrySize = 8
        case MachOConstants.dyldChainedImportAddend64: importEntrySize = 16
        default: importEntrySize = 4
        }
        let symbolsOffset = importsOffset + importEntrySize * importCount

        var symbolPool = Data([0])                     // pool starts with a leading NUL
        let putsNameOffset = symbolPool.count
        symbolPool.appendNullTerminatedString("_puts")
        let ordinal65535NameOffset = symbolPool.count
        symbolPool.appendNullTerminatedString("_ordinal65535")
        let ordinal65536NameOffset = symbolPool.count
        symbolPool.appendNullTerminatedString("_ordinal65536")

        var chainedFixups = Data()
        // dyld_chained_fixups_header
        chainedFixups.appendUInt32LE(0)                // fixups_version
        chainedFixups.appendUInt32LE(UInt32(startsOffset))
        chainedFixups.appendUInt32LE(UInt32(importsOffset))
        chainedFixups.appendUInt32LE(UInt32(symbolsOffset))
        chainedFixups.appendUInt32LE(UInt32(importCount)) // imports_count
        chainedFixups.appendUInt32LE(importsFormat)
        chainedFixups.appendUInt32LE(MachOConstants.dyldChainedSymbolsUncompressed)
        chainedFixups.appendPadding(to: startsOffset)  // pad to starts_offset

        // dyld_chained_starts_in_image
        chainedFixups.appendUInt32LE(2)                // seg_count (__TEXT, __DATA)
        chainedFixups.appendUInt32LE(0)                // seg_info_offset[0] (__TEXT: none)
        chainedFixups.appendUInt32LE(UInt32(segInfoOffsetFromStarts)) // seg_info_offset[1] (__DATA)

        // dyld_chained_starts_in_segment (for __DATA, segment index 1)
        chainedFixups.appendUInt32LE(UInt32(startsInSegmentSize)) // size
        chainedFixups.appendUInt16LE(pageSize)         // page_size
        chainedFixups.appendUInt16LE(pointerFormat) // pointer_format = DYLD_CHAINED_PTR_64 (the real ABI value
                                        // for this generic-64 chain — NOT the symbolic constant, so
                                        // the test is independent of any constant mislabeling)
        chainedFixups.appendUInt64LE(dataVMAddress - imageBase) // segment_offset is the VM-relative segment offset
        chainedFixups.appendUInt32LE(0)                // max_valid_pointer
        chainedFixups.appendUInt16LE(1)                // page_count
        chainedFixups.appendUInt16LE(0)                // page_start[0] (first fixup at page offset 0)
        for start in pageStartOverflow { chainedFixups.appendUInt16LE(start) }
        chainedFixups.appendPadding(to: startsOffset + segInfoOffsetFromStarts + startsInSegmentSize)


        precondition(chainedFixups.count == importsOffset)
        // imports table: DYLD_CHAINED_IMPORT (lib_ordinal:8, weak:1, name_offset:23),
        // _ADDEND (same + int32 addend) or _ADDEND64 (lib_ordinal:16, weak:1, reserved:15,
        // name_offset:32 + uint64 addend).
        for ordinal in 0..<importCount {
            let nameOffset = ordinal == 65535 ? ordinal65535NameOffset
                : ordinal == 65536 ? ordinal65536NameOffset : putsNameOffset
            switch importsFormat {
            case MachOConstants.dyldChainedImportAddend64:
                chainedFixups.appendUInt64LE(UInt64(importLibraryOrdinalRaw) | (UInt64(nameOffset) << 32))
                chainedFixups.appendUInt64LE(UInt64(bitPattern: importAddend))
            case MachOConstants.dyldChainedImportAddend:
                chainedFixups.appendUInt32LE(UInt32(importLibraryOrdinalRaw & 0xff) | (UInt32(nameOffset) << 9))
                chainedFixups.appendUInt32LE(UInt32(bitPattern: Int32(truncatingIfNeeded: importAddend)))
            default:
                chainedFixups.appendUInt32LE(UInt32(importLibraryOrdinalRaw & 0xff) | (UInt32(nameOffset) << 9))
            }
        }

        precondition(chainedFixups.count == symbolsOffset)
        chainedFixups.append(symbolPool)

        let chainedFixupsOffset = aligned(dataFileOffset + dataContentSize, to: 8)
        let finalFileSize = chainedFixupsOffset + chainedFixups.count

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(5)                         // 5 load commands
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        // __TEXT segment + __text section
        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(UInt64(dataFileOffset))
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(UInt64(dataFileOffset))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        // __DATA segment (no sections) — holds the chain.
        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(dataSegmentCommandSize))
        bytes.appendFixedCString("__DATA", length: 16)
        bytes.appendUInt64LE(dataVMAddress)
        bytes.appendUInt64LE(UInt64(dataContentSize))
        bytes.appendUInt64LE(UInt64(dataFileOffset))
        bytes.appendUInt64LE(UInt64(dataContentSize))
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(objectiveCReferenceSection ? 1 : 0)
        bytes.appendUInt32LE(0)

        if objectiveCReferenceSection {
            appendSection(to: &bytes, sectionName: "__objc_selrefs", segmentName: "__DATA",
                          address: dataVMAddress, size: UInt64(dataContentSize),
                          fileOffset: UInt32(dataFileOffset), alignment: 3, flags: 0)
        }
        // LC_LOAD_DYLIB (libSystem -> ordinal 1)
        bytes.appendUInt32LE(MachOConstants.loadCommandLoadDylib)
        bytes.appendUInt32LE(UInt32(dylibCommandSize))
        bytes.appendUInt32LE(24)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(encodedVersion(1400, 0, 29))
        bytes.appendUInt32LE(encodedVersion(1, 0, 0))
        bytes.appendFixedCString(dylibName, length: dylibCommandSize - 24)

        // LC_DYLD_CHAINED_FIXUPS
        bytes.appendUInt32LE(MachOConstants.loadCommandDyldChainedFixups)
        bytes.appendUInt32LE(UInt32(chainedFixupsCommandSize))
        bytes.appendUInt32LE(UInt32(chainedFixupsOffset))
        bytes.appendUInt32LE(UInt32(chainedFixups.count))

        // LC_MAIN
        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.appendPadding(to: dataFileOffset)
        bytes.append(dataContent)
        bytes.appendPadding(to: chainedFixupsOffset)
        bytes.append(chainedFixups)
        precondition(bytes.count == finalFileSize)

        tamper?(&bytes, chainedFixupsOffset)

        return MachOFixture(
            bytes: bytes,
            code: code,
            codeOffset: codeOffset,
            baseAddress: codeAddress,
            dyldChainedFixupsOffset: UInt32(chainedFixupsOffset),
            dyldChainedFixupsSize: UInt32(chainedFixups.count),
            chainedBindAddress: dataVMAddress,
            chainedRebaseAddress: dataVMAddress + 8,
            chainedRebaseTargetAddress: rebaseTarget
        )
    }

    static func makeExecutableWithRelocations() -> MachOFixture {
        let code = Data([
            0x00, 0x00, 0x00, 0x90,
            0x00, 0x00, 0x00, 0x94,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let symtabCommandSize = 24
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize
            + symtabCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let symbolCount = 2
        let symbolOffset = aligned(codeOffset + code.count, to: 8)
        let stringOffset = symbolOffset + symbolCount * 16

        var stringTable = Data([0])
        let entryNameOffset = stringTable.count
        stringTable.appendNullTerminatedString("_entry")
        let importNameOffset = stringTable.count
        stringTable.appendNullTerminatedString("_puts")

        var relocations = Data()
        relocations.appendRelocation(
            address: 4,
            symbolNumber: 1,
            isPCRelative: true,
            length: 2,
            isExternal: true,
            type: MachOConstants.arm64RelocBranch26
        )
        relocations.appendRelocation(
            address: 0,
            symbolNumber: 1,
            isPCRelative: false,
            length: 2,
            isExternal: false,
            type: MachOConstants.arm64RelocPage21
        )

        let relocationOffset = aligned(stringOffset + stringTable.count, to: 4)
        let finalFileSize = relocationOffset + relocations.count
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        appendSection(
            to: &bytes,
            sectionName: "__text",
            segmentName: "__TEXT",
            address: codeAddress,
            size: UInt64(code.count),
            fileOffset: UInt32(codeOffset),
            alignment: 2,
            relocationOffset: UInt32(relocationOffset),
            relocationCount: UInt32(relocations.count / 8),
            flags: MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )

        bytes.appendUInt32LE(MachOConstants.loadCommandSymtab)
        bytes.appendUInt32LE(UInt32(symtabCommandSize))
        bytes.appendUInt32LE(UInt32(symbolOffset))
        bytes.appendUInt32LE(UInt32(symbolCount))
        bytes.appendUInt32LE(UInt32(stringOffset))
        bytes.appendUInt32LE(UInt32(stringTable.count))

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.appendPadding(to: symbolOffset)
        bytes.appendSymbol(
            stringOffset: UInt32(entryNameOffset),
            type: MachOConstants.symbolTypeSection | MachOConstants.symbolExternal,
            sectionIndex: 1,
            description: 0,
            value: codeAddress
        )
        bytes.appendSymbol(
            stringOffset: UInt32(importNameOffset),
            type: MachOConstants.symbolTypeUndefined | MachOConstants.symbolExternal,
            sectionIndex: 0,
            description: 0,
            value: 0
        )
        bytes.append(stringTable)
        bytes.appendPadding(to: relocationOffset)
        bytes.append(relocations)

        precondition(bytes.count == finalFileSize)
        return MachOFixture(
            bytes: bytes,
            code: code,
            codeOffset: codeOffset,
            baseAddress: codeAddress,
            relocationOffset: UInt32(relocationOffset),
            relocationCount: UInt32(relocations.count / 8)
        )
    }

    static func makeExecutableWithLegacyMinimumOSVersion() -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let versionMinCommandSize = 16
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize
            + versionMinCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)
        let textFileSize = UInt64(codeOffset + code.count)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandVersionMinMacOSX)
        bytes.appendUInt32LE(UInt32(versionMinCommandSize))
        bytes.appendUInt32LE(encodedVersion(10, 13, 6))
        bytes.appendUInt32LE(encodedVersion(11, 0, 0))

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)

        return MachOFixture(bytes: bytes, code: code, codeOffset: codeOffset, baseAddress: codeAddress)
    }

    static func makeExecutableWithLoadCommandMetadata(mappedTail: Data = Data()) -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let uuidBytes: [UInt8] = [
            0x12, 0x34, 0x56, 0x78,
            0x9a, 0xbc,
            0xde, 0xf0,
            0x12, 0x34,
            0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0
        ]
        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let uuidCommandSize = 24
        let buildVersionCommandSize = 24 + 2 * 8
        let sourceVersionCommandSize = 16
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize
            + uuidCommandSize
            + buildVersionCommandSize
            + sourceVersionCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)
        let textFileSize = UInt64(codeOffset + code.count + mappedTail.count)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(textFileSize)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandUUID)
        bytes.appendUInt32LE(UInt32(uuidCommandSize))
        bytes.append(contentsOf: uuidBytes)

        bytes.appendUInt32LE(MachOConstants.loadCommandBuildVersion)
        bytes.appendUInt32LE(UInt32(buildVersionCommandSize))
        bytes.appendUInt32LE(MachOConstants.platformMacOS)
        bytes.appendUInt32LE(encodedVersion(14, 5, 0))
        bytes.appendUInt32LE(encodedVersion(15, 0, 0))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(MachOConstants.buildToolSwift)
        bytes.appendUInt32LE(encodedVersion(6, 4, 0))
        bytes.appendUInt32LE(MachOConstants.buildToolLD)
        bytes.appendUInt32LE(encodedVersion(1200, 0, 0))

        bytes.appendUInt32LE(MachOConstants.loadCommandSourceVersion)
        bytes.appendUInt32LE(UInt32(sourceVersionCommandSize))
        bytes.appendUInt64LE(encodedSourceVersion(2026, 6, 19, 4, 12))

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.append(mappedTail)

        return MachOFixture(bytes: bytes, code: code, codeOffset: codeOffset, baseAddress: codeAddress)
    }

    static func makeExecutableWithSymbols(useExportsTrieCommand: Bool = false,
                                          imageBase: UInt64 = 0x1_0000_0000,
                                          exportFlags: UInt64 = 0, exportValue: UInt64? = nil) -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let dylibName = "/usr/lib/libSystem.B.dylib"
        let headerSize = 32
        let segmentCommandSize = 72 + 80
        let dylibCommandSize = aligned(24 + dylibName.utf8.count + 1, to: 8)
        let symtabCommandSize = 24
        let dysymtabCommandSize = 80
        // LC_DYLD_INFO_ONLY is 48 bytes; the modern LC_DYLD_EXPORTS_TRIE is a 16-byte
        // linkedit_data_command (cmd, cmdsize, dataoff, datasize).
        let dyldInfoCommandSize = useExportsTrieCommand ? 16 : 48
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize
            + dylibCommandSize
            + symtabCommandSize
            + dysymtabCommandSize
            + dyldInfoCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let codeAddress = imageBase + UInt64(codeOffset)
        let symbolCount = 3
        let symbolOffset = aligned(codeOffset + code.count, to: 8)
        let stringOffset = symbolOffset + symbolCount * 16

        var stringTable = Data([0])
        let localNameOffset = stringTable.count
        stringTable.appendNullTerminatedString("_local_helper")
        let exportNameOffset = stringTable.count
        stringTable.appendNullTerminatedString("_exported_entry")
        let importNameOffset = stringTable.count
        stringTable.appendNullTerminatedString("_puts")

        let exportTrie = makeExportTrie(name: "_trie_export", address: exportValue ?? UInt64(codeOffset + 4), flags: exportFlags)
        let exportTrieOffset = aligned(stringOffset + stringTable.count, to: 8)
        let finalFileSize = exportTrieOffset + exportTrie.count

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(6)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandLoadDylib)
        bytes.appendUInt32LE(UInt32(dylibCommandSize))
        bytes.appendUInt32LE(24)
        bytes.appendUInt32LE(0x6650_1234)
        bytes.appendUInt32LE(encodedVersion(1400, 0, 29))
        bytes.appendUInt32LE(encodedVersion(1, 0, 0))
        bytes.appendFixedCString(dylibName, length: dylibCommandSize - 24)

        bytes.appendUInt32LE(MachOConstants.loadCommandSymtab)
        bytes.appendUInt32LE(UInt32(symtabCommandSize))
        bytes.appendUInt32LE(UInt32(symbolOffset))
        bytes.appendUInt32LE(UInt32(symbolCount))
        bytes.appendUInt32LE(UInt32(stringOffset))
        bytes.appendUInt32LE(UInt32(stringTable.count))

        bytes.appendUInt32LE(MachOConstants.loadCommandDysymtab)
        bytes.appendUInt32LE(UInt32(dysymtabCommandSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(1)
        for _ in 0..<12 {
            bytes.appendUInt32LE(0)
        }

        if useExportsTrieCommand {
            // LC_DYLD_EXPORTS_TRIE: a linkedit_data_command whose payload IS the export trie
            // (no LC_DYLD_INFO). Modern linkers emit this in place of LC_DYLD_INFO.
            bytes.appendUInt32LE(MachOConstants.loadCommandDyldExportsTrie)
            bytes.appendUInt32LE(UInt32(dyldInfoCommandSize)) // 16
            bytes.appendUInt32LE(UInt32(exportTrieOffset))    // dataoff
            bytes.appendUInt32LE(UInt32(exportTrie.count))    // datasize
        } else {
            bytes.appendUInt32LE(MachOConstants.loadCommandDyldInfoOnly)
            bytes.appendUInt32LE(UInt32(dyldInfoCommandSize))
            for _ in 0..<8 {
                bytes.appendUInt32LE(0)
            }
            bytes.appendUInt32LE(UInt32(exportTrieOffset))
            bytes.appendUInt32LE(UInt32(exportTrie.count))
        }

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.appendPadding(to: symbolOffset)

        bytes.appendSymbol(
            stringOffset: UInt32(localNameOffset),
            type: MachOConstants.symbolTypeSection,
            sectionIndex: 1,
            description: 0,
            value: codeAddress
        )
        bytes.appendSymbol(
            stringOffset: UInt32(exportNameOffset),
            type: MachOConstants.symbolTypeSection | MachOConstants.symbolExternal,
            sectionIndex: 1,
            description: 0,
            value: codeAddress
        )
        bytes.appendSymbol(
            stringOffset: UInt32(importNameOffset),
            type: MachOConstants.symbolTypeUndefined | MachOConstants.symbolExternal,
            sectionIndex: 0,
            description: UInt16(1 << 8),
            value: 0
        )

        bytes.append(stringTable)
        bytes.appendPadding(to: exportTrieOffset)
        bytes.append(exportTrie)

        precondition(bytes.count == finalFileSize)
        return MachOFixture(bytes: bytes, code: code, codeOffset: codeOffset, baseAddress: codeAddress)
    }

    static func makeExecutableWithImportedStubs() -> MachOFixture {
        let code = Data([
            0xc0, 0x03, 0x5f, 0xd6
        ])
        let stubs = Data([
            0x10, 0x00, 0x00, 0x90,
            0x10, 0x02, 0x40, 0xf9,
            0x00, 0x02, 0x1f, 0xd6
        ])
        let lazyPointers = Data(repeating: UInt8(0), count: 8)
        let dylibName = "/usr/lib/libSystem.B.dylib"
        let headerSize = 32
        let textSegmentCommandSize = 72 + 80 * 2
        let dataSegmentCommandSize = 72 + 80
        let dylibCommandSize = aligned(24 + dylibName.utf8.count + 1, to: 8)
        let symtabCommandSize = 24
        let dysymtabCommandSize = 80
        let mainCommandSize = 24
        let loadCommandsSize = textSegmentCommandSize
            + dataSegmentCommandSize
            + dylibCommandSize
            + symtabCommandSize
            + dysymtabCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let stubOffset = codeOffset + code.count
        let lazyPointerOffset = aligned(stubOffset + stubs.count, to: 8)
        let symbolCount = 1
        let symbolOffset = aligned(lazyPointerOffset + lazyPointers.count, to: 8)
        let stringOffset = symbolOffset + symbolCount * 16

        var stringTable = Data([0])
        let importNameOffset = stringTable.count
        stringTable.appendNullTerminatedString("_puts")

        var indirectSymbols = Data()
        indirectSymbols.appendUInt32LE(0)
        indirectSymbols.appendUInt32LE(0)
        let indirectSymbolOffset = aligned(stringOffset + stringTable.count, to: 4)
        let finalFileSize = indirectSymbolOffset + indirectSymbols.count
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)
        let stubAddress = imageBase + UInt64(stubOffset)
        let lazyPointerAddress = imageBase + UInt64(lazyPointerOffset)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(6)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(textSegmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(UInt64(stubOffset + stubs.count))
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(UInt64(stubOffset + stubs.count))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)

        appendSection(
            to: &bytes,
            sectionName: "__text",
            segmentName: "__TEXT",
            address: codeAddress,
            size: UInt64(code.count),
            fileOffset: UInt32(codeOffset),
            alignment: 2,
            flags: MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        appendSection(
            to: &bytes,
            sectionName: "__stubs",
            segmentName: "__TEXT",
            address: stubAddress,
            size: UInt64(stubs.count),
            fileOffset: UInt32(stubOffset),
            alignment: 2,
            flags: MachOConstants.sectionTypeSymbolStubs
                | MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions,
            reserved1: 0,
            reserved2: UInt32(stubs.count)
        )

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(dataSegmentCommandSize))
        bytes.appendFixedCString("__DATA", length: 16)
        bytes.appendUInt64LE(lazyPointerAddress)
        bytes.appendUInt64LE(UInt64(lazyPointers.count))
        bytes.appendUInt64LE(UInt64(lazyPointerOffset))
        bytes.appendUInt64LE(UInt64(lazyPointers.count))
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        appendSection(
            to: &bytes,
            sectionName: "__la_symbol_ptr",
            segmentName: "__DATA",
            address: lazyPointerAddress,
            size: UInt64(lazyPointers.count),
            fileOffset: UInt32(lazyPointerOffset),
            alignment: 3,
            flags: MachOConstants.sectionTypeLazySymbolPointers,
            reserved1: 1
        )

        bytes.appendUInt32LE(MachOConstants.loadCommandLoadDylib)
        bytes.appendUInt32LE(UInt32(dylibCommandSize))
        bytes.appendUInt32LE(24)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendFixedCString(dylibName, length: dylibCommandSize - 24)

        bytes.appendUInt32LE(MachOConstants.loadCommandSymtab)
        bytes.appendUInt32LE(UInt32(symtabCommandSize))
        bytes.appendUInt32LE(UInt32(symbolOffset))
        bytes.appendUInt32LE(UInt32(symbolCount))
        bytes.appendUInt32LE(UInt32(stringOffset))
        bytes.appendUInt32LE(UInt32(stringTable.count))

        bytes.appendUInt32LE(MachOConstants.loadCommandDysymtab)
        bytes.appendUInt32LE(UInt32(dysymtabCommandSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(1)
        for _ in 0..<6 {
            bytes.appendUInt32LE(0)
        }
        bytes.appendUInt32LE(UInt32(indirectSymbolOffset))
        bytes.appendUInt32LE(UInt32(indirectSymbols.count / 4))
        for _ in 0..<4 {
            bytes.appendUInt32LE(0)
        }

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.append(stubs)
        bytes.appendPadding(to: lazyPointerOffset)
        bytes.append(lazyPointers)
        bytes.appendPadding(to: symbolOffset)
        bytes.appendSymbol(
            stringOffset: UInt32(importNameOffset),
            type: MachOConstants.symbolTypeUndefined | MachOConstants.symbolExternal,
            sectionIndex: 0,
            description: UInt16(1 << 8),
            value: 0
        )
        bytes.append(stringTable)
        bytes.appendPadding(to: indirectSymbolOffset)
        bytes.append(indirectSymbols)

        precondition(bytes.count == finalFileSize)
        return MachOFixture(
            bytes: bytes,
            code: code,
            codeOffset: codeOffset,
            baseAddress: codeAddress,
            stubAddress: stubAddress,
            lazyPointerAddress: lazyPointerAddress
        )
    }

    static func makeExecutableWithCStringLiterals() -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        var cstringData = Data()
        cstringData.appendNullTerminatedString("Usage: MacScope <binary>")
        cstringData.appendNullTerminatedString("Analyze Objective-C metadata")
        cstringData.appendNullTerminatedString("")
        cstringData.append(contentsOf: "unterminated literal".utf8)

        let headerSize = 32
        let segmentCommandSize = 72 + 80 * 2
        let mainCommandSize = 24
        let loadCommandsSize = segmentCommandSize + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let cstringOffset = codeOffset + code.count
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)
        let cstringAddress = imageBase + UInt64(cstringOffset)
        let finalFileSize = cstringOffset + cstringData.count

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(UInt64(finalFileSize))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(codeAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__cstring", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(cstringAddress)
        bytes.appendUInt64LE(UInt64(cstringData.count))
        bytes.appendUInt32LE(UInt32(cstringOffset))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.sectionTypeCStringLiterals)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.append(cstringData)

        precondition(bytes.count == finalFileSize)
        return MachOFixture(
            bytes: bytes,
            code: code,
            codeOffset: codeOffset,
            baseAddress: codeAddress,
            stringLiteralAddress: cstringAddress
        )
    }

    static func makeExecutableWithObjectiveCAndSwiftMetadata() -> MachOFixture {
        let code = Data([
            0xff, 0x83, 0x00, 0xd1,
            0xfd, 0x7b, 0x01, 0xa9,
            0xfd, 0x43, 0x00, 0x91,
            0x00, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6
        ])
        var selectorData = Data()
        selectorData.appendNullTerminatedString("viewDidLoad")
        selectorData.appendNullTerminatedString("setRepresentedObject:")

        var classNameData = Data()
        classNameData.appendNullTerminatedString("AppDelegate")
        classNameData.appendNullTerminatedString("DocumentViewController")

        let selectorReferenceDataSize = 16
        let classReferenceDataSize = 16
        var swiftTypesData = Data()
        swiftTypesData.appendUInt32LE(0x20)
        swiftTypesData.appendUInt32LE(0x44)

        var swiftProtocolData = Data()
        swiftProtocolData.appendUInt32LE(0x68)

        let headerSize = 32
        let textSectionCount = 5
        let dataConstSectionCount = 2
        let textSegmentCommandSize = 72 + 80 * textSectionCount
        let dataConstSegmentCommandSize = 72 + 80 * dataConstSectionCount
        let mainCommandSize = 24
        let loadCommandsSize = textSegmentCommandSize
            + dataConstSegmentCommandSize
            + mainCommandSize
        let codeOffset = headerSize + loadCommandsSize
        let selectorOffset = codeOffset + code.count
        let classNameOffset = selectorOffset + selectorData.count
        let swiftTypesOffset = aligned(classNameOffset + classNameData.count, to: 4)
        let swiftProtocolOffset = swiftTypesOffset + swiftTypesData.count
        let selectorReferencesOffset = aligned(swiftProtocolOffset + swiftProtocolData.count, to: 8)
        let classReferencesOffset = selectorReferencesOffset + selectorReferenceDataSize
        let finalFileSize = classReferencesOffset + classReferenceDataSize
        let imageBase = 0x1_0000_0000 as UInt64
        let codeAddress = imageBase + UInt64(codeOffset)
        let selectorAddress = imageBase + UInt64(selectorOffset)
        let secondSelectorAddress = selectorAddress + UInt64("viewDidLoad".utf8.count + 1)
        let classNameAddress = imageBase + UInt64(classNameOffset)
        let secondClassNameAddress = classNameAddress + UInt64("AppDelegate".utf8.count + 1)
        let selectorReferencesAddress = imageBase + UInt64(selectorReferencesOffset)
        let classReferencesAddress = imageBase + UInt64(classReferencesOffset)
        let swiftTypesAddress = imageBase + UInt64(swiftTypesOffset)
        let swiftProtocolAddress = imageBase + UInt64(swiftProtocolOffset)

        var selectorReferencesData = Data()
        selectorReferencesData.appendUInt64LE(selectorAddress)
        selectorReferencesData.appendUInt64LE(secondSelectorAddress)

        var classReferencesData = Data()
        classReferencesData.appendUInt64LE(classNameAddress)
        classReferencesData.appendUInt64LE(secondClassNameAddress)

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(textSegmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(imageBase)
        bytes.appendUInt64LE(UInt64(selectorReferencesOffset))
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(UInt64(selectorReferencesOffset))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(UInt32(textSectionCount))
        bytes.appendUInt32LE(0)

        appendSection(
            to: &bytes,
            sectionName: "__text",
            segmentName: "__TEXT",
            address: codeAddress,
            size: UInt64(code.count),
            fileOffset: UInt32(codeOffset),
            alignment: 2,
            flags: MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        appendSection(
            to: &bytes,
            sectionName: "__objc_methname",
            segmentName: "__TEXT",
            address: selectorAddress,
            size: UInt64(selectorData.count),
            fileOffset: UInt32(selectorOffset),
            alignment: 0,
            flags: 0
        )
        appendSection(
            to: &bytes,
            sectionName: "__objc_classname",
            segmentName: "__TEXT",
            address: classNameAddress,
            size: UInt64(classNameData.count),
            fileOffset: UInt32(classNameOffset),
            alignment: 0,
            flags: 0
        )
        appendSection(
            to: &bytes,
            sectionName: "__swift5_types",
            segmentName: "__TEXT",
            address: swiftTypesAddress,
            size: UInt64(swiftTypesData.count),
            fileOffset: UInt32(swiftTypesOffset),
            alignment: 2,
            flags: 0
        )
        appendSection(
            to: &bytes,
            sectionName: "__swift5_proto",
            segmentName: "__TEXT",
            address: swiftProtocolAddress,
            size: UInt64(swiftProtocolData.count),
            fileOffset: UInt32(swiftProtocolOffset),
            alignment: 2,
            flags: 0
        )

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(dataConstSegmentCommandSize))
        bytes.appendFixedCString("__DATA_CONST", length: 16)
        bytes.appendUInt64LE(selectorReferencesAddress)
        bytes.appendUInt64LE(UInt64(finalFileSize - selectorReferencesOffset))
        bytes.appendUInt64LE(UInt64(selectorReferencesOffset))
        bytes.appendUInt64LE(UInt64(finalFileSize - selectorReferencesOffset))
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(3)
        bytes.appendUInt32LE(UInt32(dataConstSectionCount))
        bytes.appendUInt32LE(0)

        appendSection(
            to: &bytes,
            sectionName: "__objc_selrefs",
            segmentName: "__DATA_CONST",
            address: selectorReferencesAddress,
            size: UInt64(selectorReferencesData.count),
            fileOffset: UInt32(selectorReferencesOffset),
            alignment: 3,
            flags: 0
        )
        appendSection(
            to: &bytes,
            sectionName: "__objc_classrefs",
            segmentName: "__DATA_CONST",
            address: classReferencesAddress,
            size: UInt64(classReferencesData.count),
            fileOffset: UInt32(classReferencesOffset),
            alignment: 3,
            flags: 0
        )

        bytes.appendUInt32LE(MachOConstants.loadCommandMain)
        bytes.appendUInt32LE(UInt32(mainCommandSize))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(0)

        precondition(bytes.count == codeOffset)
        bytes.append(code)
        bytes.append(selectorData)
        bytes.append(classNameData)
        bytes.appendPadding(to: swiftTypesOffset)
        bytes.append(swiftTypesData)
        bytes.append(swiftProtocolData)
        bytes.appendPadding(to: selectorReferencesOffset)
        bytes.append(selectorReferencesData)
        bytes.append(classReferencesData)

        precondition(bytes.count == finalFileSize)
        return MachOFixture(
            bytes: bytes,
            code: code,
            codeOffset: codeOffset,
            baseAddress: codeAddress,
            selectorStringAddress: selectorAddress,
            classNameStringAddress: classNameAddress,
            selectorReferenceAddress: selectorReferencesAddress,
            classReferenceAddress: classReferencesAddress
        )
    }

    private static func makeCodeSignatureSuperBlob() -> Data {
        let identifier = "com.example.fixture"
        let teamIdentifier = "TEAMID1234"
        let codeDirectoryHeaderSize = 52
        let identifierOffset = codeDirectoryHeaderSize
        let teamIdentifierOffset = identifierOffset + identifier.utf8.count + 1
        let codeDirectoryLength = teamIdentifierOffset + teamIdentifier.utf8.count + 1

        var codeDirectory = Data()
        codeDirectory.appendUInt32BE(MachOConstants.codeSignatureCodeDirectoryMagic)
        codeDirectory.appendUInt32BE(UInt32(codeDirectoryLength))
        codeDirectory.appendUInt32BE(MachOConstants.codeSignatureCodeDirectoryTeamOffsetVersion)
        codeDirectory.appendUInt32BE(0x0001_0000)
        codeDirectory.appendUInt32BE(UInt32(codeDirectoryLength))
        codeDirectory.appendUInt32BE(UInt32(identifierOffset))
        codeDirectory.appendUInt32BE(2)
        codeDirectory.appendUInt32BE(3)
        codeDirectory.appendUInt32BE(20)
        codeDirectory.append(32)
        codeDirectory.append(MachOConstants.codeSignatureHashTypeSHA256)
        codeDirectory.append(0)
        codeDirectory.append(12)
        codeDirectory.appendUInt32BE(0)
        codeDirectory.appendUInt32BE(0)
        codeDirectory.appendUInt32BE(UInt32(teamIdentifierOffset))
        codeDirectory.appendNullTerminatedString(identifier)
        codeDirectory.appendNullTerminatedString(teamIdentifier)
        precondition(codeDirectory.count == codeDirectoryLength)

        let entitlementsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.app-sandbox</key>
            <true/>
            <key>com.apple.security.files.user-selected.read-only</key>
            <true/>
        </dict>
        </plist>
        """
        let entitlementPayload = Data(entitlementsXML.utf8)
        var entitlements = Data()
        entitlements.appendUInt32BE(MachOConstants.codeSignatureEmbeddedEntitlementsMagic)
        entitlements.appendUInt32BE(UInt32(MachOConstants.codeSignatureBlobHeaderSize) + UInt32(entitlementPayload.count))
        entitlements.append(entitlementPayload)

        let codeDirectoryOffset = 12 + 2 * 8
        let entitlementsOffset = codeDirectoryOffset + codeDirectory.count
        let superBlobLength = entitlementsOffset + entitlements.count

        var superBlob = Data()
        superBlob.appendUInt32BE(MachOConstants.codeSignatureEmbeddedSignatureMagic)
        superBlob.appendUInt32BE(UInt32(superBlobLength))
        superBlob.appendUInt32BE(2)
        superBlob.appendUInt32BE(MachOConstants.codeSignatureSlotCodeDirectory)
        superBlob.appendUInt32BE(UInt32(codeDirectoryOffset))
        superBlob.appendUInt32BE(MachOConstants.codeSignatureSlotEntitlements)
        superBlob.appendUInt32BE(UInt32(entitlementsOffset))
        superBlob.append(codeDirectory)
        superBlob.append(entitlements)

        precondition(superBlob.count == superBlobLength)
        return superBlob
    }

    private static func makeExportTrie(name: String, address: UInt64, flags: UInt64 = 0) -> Data {
        var terminal = Data()
        terminal.appendULEB128(flags)
        terminal.appendULEB128(address)

        var terminalNode = Data()
        terminalNode.appendULEB128(UInt64(terminal.count))
        terminalNode.append(terminal)
        terminalNode.append(0)

        var childOffset = 0
        var root = Data()
        while true {
            var candidate = Data()
            candidate.appendULEB128(0)
            candidate.append(1)
            candidate.appendNullTerminatedString(name)
            candidate.appendULEB128(UInt64(childOffset))

            if candidate.count == childOffset {
                root = candidate
                break
            }
            childOffset = candidate.count
        }

        var trie = Data()
        trie.append(root)
        trie.append(terminalNode)
        return trie
    }

    /// Locates the fixture's untouched first bind word using its format-specific layout.
    static func chainDataStart(in bytes: Data, pointerFormat: UInt16 = 2) -> Int {
        let needle: UInt64 = [UInt16(1), 9, 12].contains(pointerFormat)
            ? (UInt64(1) << 62) | (UInt64(1) << 51)
            : (UInt64(1) << 63) | (UInt64(2) << 51)
        var offset = 0
        while offset + 8 <= bytes.count {
            if readUInt64LE(bytes, at: offset) == needle {
                return offset
            }
            offset += 1
        }
        preconditionFailure("Fixture bind word not found")
    }

    static func readUInt64LE(_ bytes: Data, at offset: Int) -> UInt64 {
        let base = bytes.startIndex + offset
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[base + i]) << (8 * i)
        }
        return value
    }

    static func writeUInt64LE(_ bytes: inout Data, at offset: Int, value: UInt64) {
        let base = bytes.startIndex + offset
        for i in 0..<8 {
            bytes[base + i] = UInt8((value >> (8 * i)) & 0xff)
        }
    }

    private static func aligned(_ value: Int, to alignment: Int) -> Int {
        let remainder = value % alignment
        return remainder == 0 ? value : value + alignment - remainder
    }

    private static func encodedVersion(_ major: UInt32, _ minor: UInt32, _ patch: UInt32) -> UInt32 {
        (major << 16) | (minor << 8) | patch
    }

    static func encodedSourceVersion(
        _ major: UInt64,
        _ minor: UInt64,
        _ revision: UInt64,
        _ stage: UInt64,
        _ build: UInt64
    ) -> UInt64 {
        (major << 40) | (minor << 30) | (revision << 20) | (stage << 10) | build
    }

    private static func appendSection(
        to data: inout Data,
        sectionName: String,
        segmentName: String,
        address: UInt64,
        size: UInt64,
        fileOffset: UInt32,
        alignment: UInt32,
        relocationOffset: UInt32 = 0,
        relocationCount: UInt32 = 0,
        flags: UInt32,
        reserved1: UInt32 = 0,
        reserved2: UInt32 = 0,
        reserved3: UInt32 = 0
    ) {
        data.appendFixedCString(sectionName, length: 16)
        data.appendFixedCString(segmentName, length: 16)
        data.appendUInt64LE(address)
        data.appendUInt64LE(size)
        data.appendUInt32LE(fileOffset)
        data.appendUInt32LE(alignment)
        data.appendUInt32LE(relocationOffset)
        data.appendUInt32LE(relocationCount)
        data.appendUInt32LE(flags)
        data.appendUInt32LE(reserved1)
        data.appendUInt32LE(reserved2)
        data.appendUInt32LE(reserved3)
    }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func replaceUInt32BE(at offset: Int, with value: UInt32) {
        self[offset] = UInt8((value >> 24) & 0xff)
        self[offset + 1] = UInt8((value >> 16) & 0xff)
        self[offset + 2] = UInt8((value >> 8) & 0xff)
        self[offset + 3] = UInt8(value & 0xff)
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func replaceUInt32LE(at offset: Int, with value: UInt32) {
        let base = startIndex + offset
        self[base] = UInt8(value & 0xff)
        self[base + 1] = UInt8((value >> 8) & 0xff)
        self[base + 2] = UInt8((value >> 16) & 0xff)
        self[base + 3] = UInt8((value >> 24) & 0xff)
    }

    mutating func replaceUInt16LE(at offset: Int, with value: UInt16) {
        let base = startIndex + offset
        self[base] = UInt8(value & 0xff)
        self[base + 1] = UInt8((value >> 8) & 0xff)
    }

    mutating func replaceUInt64LE(at offset: Int, with value: UInt64) {
        let base = startIndex + offset
        for index in 0..<8 { self[base + index] = UInt8((value >> UInt64(index * 8)) & 0xff) }
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 32) & 0xff))
        append(UInt8((value >> 40) & 0xff))
        append(UInt8((value >> 48) & 0xff))
        append(UInt8((value >> 56) & 0xff))
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendFixedCString(_ string: String, length: Int) {
        let bytes = Array(string.utf8.prefix(length))
        append(contentsOf: bytes)
        append(contentsOf: repeatElement(UInt8(0), count: Swift.max(0, length - bytes.count)))
    }

    mutating func appendNullTerminatedString(_ string: String) {
        append(contentsOf: string.utf8)
        append(0)
    }

    mutating func appendPadding(to targetCount: Int) {
        precondition(count <= targetCount)
        append(contentsOf: repeatElement(UInt8(0), count: targetCount - count))
    }

    mutating func appendSymbol(
        stringOffset: UInt32,
        type: UInt8,
        sectionIndex: UInt8,
        description: UInt16,
        value: UInt64
    ) {
        appendUInt32LE(stringOffset)
        append(type)
        append(sectionIndex)
        appendUInt16LE(description)
        appendUInt64LE(value)
    }

    mutating func appendRelocation(
        address: UInt32,
        symbolNumber: UInt32,
        isPCRelative: Bool,
        length: UInt8,
        isExternal: Bool,
        type: UInt8
    ) {
        var info = symbolNumber & MachOConstants.relocationSymbolNumberMask
        if isPCRelative {
            info |= MachOConstants.relocationPCRelativeMask
        }
        info |= UInt32(length & 0x3) << 25
        if isExternal {
            info |= MachOConstants.relocationExternalMask
        }
        info |= UInt32(type & 0xf) << 28

        appendUInt32LE(address)
        appendUInt32LE(info)
    }

    mutating func appendULEB128(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            append(byte)
        } while remaining != 0
    }
}
