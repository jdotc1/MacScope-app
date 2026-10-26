enum MachOConstants {
    static let machMagic64: UInt32 = 0xfeedfacf
    static let fatMagic: UInt32 = 0xcafebabe
    static let fatMagic64: UInt32 = 0xcafebabf

    static let cpuTypeX86_64: Int32 = 0x0100_0007
    static let cpuTypeARM64: Int32 = 0x0100_000c
    /// CPU_SUBTYPE_MASK: the capability/feature bits in a cpusubtype's high byte (e.g. the
    /// arm64e pointer-authentication ABI version). Mask them off to compare architectures.
    static let cpuSubtypeCapabilityMask = Int32(bitPattern: 0xff00_0000)

    // LC_UNIXTHREAD / LC_THREAD initial-PC recovery. After the 8-byte load-command
    // header, the body is one or more (flavor: u32, count: u32, state[count]: u32)
    // tuples. We read the architecture's general thread-state flavor and pull the
    // program counter out of the register block at a fixed word offset.
    static let armThreadState64Flavor: UInt32 = 6
    static let x86ThreadState64Flavor: UInt32 = 4
    /// u32-WORD index of `pc` within `arm_thread_state64_t`: the 32 u64 registers
    /// before it (x0..x28, fp, lr, sp) occupy 64 u32 words, so `pc` starts at word 64.
    static let armThreadState64PCWordIndex = 64
    /// u32-WORD index of `rip` within `x86_thread_state64_t`: the 16 u64 registers
    /// before it (rax..r15) occupy 32 u32 words, so `rip` starts at word 32.
    static let x86ThreadState64RIPWordIndex = 32

    static let fileTypeObject: UInt32 = 0x1
    static let fileTypeExecute: UInt32 = 0x2
    static let fileTypeDylib: UInt32 = 0x6
    static let fileTypeBundle: UInt32 = 0x8

    static let loadCommandSymtab: UInt32 = 0x2
    static let loadCommandDysymtab: UInt32 = 0xb
    static let loadCommandLoadDylib: UInt32 = 0xc
    static let loadCommandLoadWeakDylib: UInt32 = 0x8000_0018
    static let loadCommandThread: UInt32 = 0x4
    static let loadCommandUnixThread: UInt32 = 0x5
    static let loadCommandSegment64: UInt32 = 0x19
    static let loadCommandUUID: UInt32 = 0x1b
    static let loadCommandRPath: UInt32 = 0x8000_001c
    static let loadCommandCodeSignature: UInt32 = 0x1d
    static let loadCommandEncryptionInfo: UInt32 = 0x21
    static let loadCommandDyldInfo: UInt32 = 0x22
    static let loadCommandDyldInfoOnly: UInt32 = 0x8000_0022
    static let loadCommandMain: UInt32 = 0x8000_0028
    static let loadCommandBuildVersion: UInt32 = 0x32
    static let loadCommandReexportDylib: UInt32 = 0x8000_001f
    static let loadCommandLazyLoadDylib: UInt32 = 0x20
    static let loadCommandLoadUpwardDylib: UInt32 = 0x8000_0023
    static let loadCommandVersionMinMacOSX: UInt32 = 0x24
    static let loadCommandVersionMinIPhoneOS: UInt32 = 0x25
    static let loadCommandFunctionStarts: UInt32 = 0x26
    static let loadCommandDataInCode: UInt32 = 0x29  // LC_DATA_IN_CODE (linkedit_data_command)
    static let loadCommandSourceVersion: UInt32 = 0x2a
    static let loadCommandEncryptionInfo64: UInt32 = 0x2c
    static let loadCommandVersionMinTVOS: UInt32 = 0x2f
    static let loadCommandVersionMinWatchOS: UInt32 = 0x30
    static let loadCommandDyldExportsTrie: UInt32 = 0x8000_0033  // LC_DYLD_EXPORTS_TRIE (linkedit_data_command)
    static let loadCommandDyldChainedFixups: UInt32 = 0x8000_0034

    static let segmentFlagProtectedVersion1: UInt32 = 0x8

    static let platformMacOS: UInt32 = 0x1
    static let platformIOS: UInt32 = 0x2
    static let platformTVOS: UInt32 = 0x3
    static let platformWatchOS: UInt32 = 0x4
    static let platformBridgeOS: UInt32 = 0x5
    static let platformMacCatalyst: UInt32 = 0x6
    static let platformIOSSimulator: UInt32 = 0x7
    static let platformTVOSSimulator: UInt32 = 0x8
    static let platformWatchOSSimulator: UInt32 = 0x9
    static let platformDriverKit: UInt32 = 0xa
    static let platformVisionOS: UInt32 = 0xb
    static let platformVisionOSSimulator: UInt32 = 0xc

    static let buildToolClang: UInt32 = 0x1
    static let buildToolSwift: UInt32 = 0x2
    static let buildToolLD: UInt32 = 0x3
    static let buildToolLLD: UInt32 = 0x4

    static let sectionAttributesMask: UInt32 = 0xffff_ff00
    static let sectionTypeMask: UInt32 = 0x0000_00ff
    static let sectionTypeZeroFill: UInt32 = 0x1
    static let sectionTypeCStringLiterals: UInt32 = 0x2
    static let sectionTypeNonLazySymbolPointers: UInt32 = 0x6
    static let sectionTypeLazySymbolPointers: UInt32 = 0x7
    static let sectionTypeSymbolStubs: UInt32 = 0x8
    static let sectionTypeGBZeroFill: UInt32 = 0xc
    static let sectionTypeThreadLocalZeroFill: UInt32 = 0x12
    static let sectionAttributeSomeInstructions: UInt32 = 0x0000_0400
    static let sectionAttributePureInstructions: UInt32 = 0x8000_0000

    static let dataInCodeKindData: UInt16 = 1
    static let dataInCodeKindJumpTable8: UInt16 = 2
    static let dataInCodeKindJumpTable16: UInt16 = 3
    static let dataInCodeKindJumpTable32: UInt16 = 4
    static let dataInCodeKindAbsJumpTable32: UInt16 = 5

    static let symbolTypeMask: UInt8 = 0x0e
    static let symbolTypeUndefined: UInt8 = 0x00
    static let symbolTypeAbsolute: UInt8 = 0x02
    static let symbolTypeSection: UInt8 = 0x0e
    static let symbolTypePreboundUndefined: UInt8 = 0x0c
    static let symbolTypeIndirect: UInt8 = 0x0a
    static let symbolExternal: UInt8 = 0x01
    static let symbolDebugMask: UInt8 = 0xe0

    static let dynamicLookupLibraryOrdinal = 0xfe
    static let executableLibraryOrdinal = 0xff
    static let indirectSymbolLocal: UInt32 = 0x8000_0000
    static let indirectSymbolAbsolute: UInt32 = 0x4000_0000
    static let indirectSymbolIndexMask: UInt32 = 0x3fff_ffff
    static let exportSymbolFlagsReexport: UInt64 = 0x08
    static let exportSymbolFlagsStubAndResolver: UInt64 = 0x10

    static let arm64RelocUnsigned: UInt8 = 0
    static let arm64RelocSubtractor: UInt8 = 1
    static let arm64RelocBranch26: UInt8 = 2
    static let arm64RelocPage21: UInt8 = 3
    static let arm64RelocPageOff12: UInt8 = 4
    static let arm64RelocGOTLoadPage21: UInt8 = 5
    static let arm64RelocGOTLoadPageOff12: UInt8 = 6
    static let arm64RelocPointerToGOT: UInt8 = 7
    static let arm64RelocTLVPLoadPage21: UInt8 = 8
    static let arm64RelocTLVPLoadPageOff12: UInt8 = 9
    static let arm64RelocAddend: UInt8 = 10
    static let arm64RelocAuthenticatedPointer: UInt8 = 11

    static let relocationSymbolNumberMask: UInt32 = 0x00ff_ffff
    static let relocationPCRelativeMask: UInt32 = 0x0100_0000
    static let relocationExternalMask: UInt32 = 0x0800_0000
    static let relocationScatteredMask: UInt32 = 0x8000_0000
    static let scatteredRelocationAddressMask: UInt32 = 0x00ff_ffff
    static let scatteredRelocationPCRelativeMask: UInt32 = 0x4000_0000

    static let dyldChainedImport: UInt32 = 0x1
    static let dyldChainedImportAddend: UInt32 = 0x2
    static let dyldChainedImportAddend64: UInt32 = 0x3
    static let dyldChainedSymbolsUncompressed: UInt32 = 0x0
    static let dyldChainedSymbolsZlibCompressed: UInt32 = 0x1
    static let dyldChainedFixupsHeaderSize: UInt32 = 28

    // dyld_chained_ptr formats (subset — the common 64-bit ones we walk). Unknown
    // formats are skipped gracefully so a future/unsupported pointer kind never traps.
    // Values are the external ABI from <mach-o/fixup-chains.h>; pinned by
    // `testChainedPointerFormatConstantsMatchABI` (they were previously transposed).
    static let dyldChainedPtrArm64e: UInt16 = 1        // DYLD_CHAINED_PTR_ARM64E
    static let dyldChainedPtr64: UInt16 = 2            // DYLD_CHAINED_PTR_64 (target is a VM address)
    static let dyldChainedPtr64Offset: UInt16 = 6      // DYLD_CHAINED_PTR_64_OFFSET (target is an image-base offset)
    static let dyldChainedPtrArm64eUserland: UInt16 = 9  // DYLD_CHAINED_PTR_ARM64E_USERLAND
    static let dyldChainedPtrArm64eUserland24: UInt16 = 12 // DYLD_CHAINED_PTR_ARM64E_USERLAND24

    /// `page_start` sentinel marking a page with no fixups (DYLD_CHAINED_PTR_START_NONE).
    static let dyldChainedPtrStartNone: UInt16 = 0xffff
    /// DYLD_CHAINED_PTR_START_MULTI: page_start indexes an overflow chain_starts[] list (32-bit formats).
    static let dyldChainedPtrStartMulti: UInt16 = 0x8000
    /// DYLD_CHAINED_PTR_START_LAST: marks the last entry of a START_MULTI chain_starts[] list.
    static let dyldChainedPtrStartLast: UInt16 = 0x8000
    /// Hard cap on a single chain's entry count, so a cyclic / overlong `next` field
    /// can never spin the walk forever on untrusted bytes.
    static let dyldChainedMaxChainLength: Int = 1_000_000
    /// Hard cap on total resolved fixups surfaced, so a hostile starts table can't
    /// balloon memory without bound.
    static let dyldChainedMaxFixups: Int = 4_000_000
    static let unwindInfoHeaderSize: UInt32 = 28
    static let compactUnwindEntrySize64: Int = 32

    static let codeSignatureSuperBlobHeaderSize: UInt32 = 12
    static let codeSignatureBlobHeaderSize: UInt32 = 8
    static let codeSignatureCodeDirectoryHeaderSize: UInt32 = 44
    static let codeSignatureCodeDirectoryTeamOffsetVersion: UInt32 = 0x20200
    static let codeSignatureEmbeddedSignatureMagic: UInt32 = 0xfade_0cc0
    static let codeSignatureDetachedSignatureMagic: UInt32 = 0xfade_0cc1
    static let codeSignatureRequirementMagic: UInt32 = 0xfade_0c00
    static let codeSignatureRequirementsMagic: UInt32 = 0xfade_0c01
    static let codeSignatureCodeDirectoryMagic: UInt32 = 0xfade_0c02
    static let codeSignatureBlobWrapperMagic: UInt32 = 0xfade_0b01
    static let codeSignatureEmbeddedEntitlementsMagic: UInt32 = 0xfade_7171
    static let codeSignatureDerEntitlementsMagic: UInt32 = 0xfade_7172
    static let codeSignatureSlotCodeDirectory: UInt32 = 0
    static let codeSignatureSlotInfoPlist: UInt32 = 1
    static let codeSignatureSlotRequirements: UInt32 = 2
    static let codeSignatureSlotResourceDirectory: UInt32 = 3
    static let codeSignatureSlotApplication: UInt32 = 4
    static let codeSignatureSlotEntitlements: UInt32 = 5
    static let codeSignatureSlotDerEntitlements: UInt32 = 7
    static let codeSignatureSlotAlternateCodeDirectoryStart: UInt32 = 0x1000
    static let codeSignatureSlotAlternateCodeDirectoryEnd: UInt32 = 0x1004
    static let codeSignatureHashTypeSHA1: UInt8 = 1
    static let codeSignatureHashTypeSHA256: UInt8 = 2
    static let codeSignatureHashTypeSHA256Truncated: UInt8 = 3
    static let codeSignatureHashTypeSHA384: UInt8 = 4
}
