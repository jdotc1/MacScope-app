import Foundation

struct MachOParseOptions: Hashable, Sendable {
    var recoverStringLiterals: Bool
    var recoverObjectiveCMetadata: Bool
    var recoverSwiftMetadata: Bool
    var parseCodeSignature: Bool
    /// For a fat/universal binary, the explicit slice index the caller wants loaded
    /// (the user's pick from the open-time loader-options dialog). `nil` applies the
    /// default rule (host arm64 → x86_64 → first). Ignored for thin binaries.
    var requestedSliceIndex: Int?

    init(
        recoverStringLiterals: Bool = true,
        recoverObjectiveCMetadata: Bool = true,
        recoverSwiftMetadata: Bool = true,
        parseCodeSignature: Bool = true,
        requestedSliceIndex: Int? = nil
    ) {
        self.recoverStringLiterals = recoverStringLiterals
        self.recoverObjectiveCMetadata = recoverObjectiveCMetadata
        self.recoverSwiftMetadata = recoverSwiftMetadata
        self.parseCodeSignature = parseCodeSignature
        self.requestedSliceIndex = requestedSliceIndex
    }

    static let `default` = MachOParseOptions()
}

/// Context for parsing the Objective-C metadata of a dyld-cache-projected image. The per-image
/// projection omits the SHARED cache regions (class-name/selector strings live in the 123 MB
/// `__OBJC_RO`), and the data pointers use the `DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE` rebase encoding
/// rather than raw vmaddrs. So the ObjC walker needs the cache base (to decode `target = base +
/// (raw & 0x3FFFFFFFF)`) and a reader over the WHOLE cache (to fetch the shared strings on demand).
/// nil for an ordinary on-disk Mach-O (raw pointers, all bytes present locally). Held outside
/// `MachOParseOptions` because it carries a closure (non-Hashable).
struct MachOObjCCacheContext {
    /// Cache base for the `DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE` runtime-offset decode.
    let pointerBase: UInt64
    /// Reads up to `count` bytes at any cache VM address (clamped to the containing mapping), or nil.
    let readBytes: (UInt64, Int) -> [UInt8]?
}

struct MachOFile: Sendable {
    var header: MachOHeader
    var loadCommands: [MachOLoadCommand]
    var segments: [MachOSegment]
    var sections: [MachOSection]
    var dylibs: [MachODylib]
    var rpaths: [MachORPath]
    var symbols: [MachOSymbol]
    var imports: [MachOImport]
    var indirectSymbols: [MachOIndirectSymbol]
    var relocations: [MachORelocation]
    var exports: [MachOExport]
    /// False when symbol/export recovery omitted potential external addresses.
    /// Older/manual producers must fail closed until they establish completeness.
    var exportRecoveryComplete: Bool = false
    var stringLiterals: [MachOStringLiteral]
    var objectiveCMetadata: MachOObjectiveCMetadata
    var swiftMetadataSections: [MachOMetadataSection]
    /// Decoded Swift nominal types (class/struct/enum + stored fields) from `__swift5_types`/`_fieldmd`.
    var swiftTypes: [SwiftTypeDescriptor] = []
    /// Recovered in-image Swift protocol conformances (`<type>: <protocol>`) from `__swift5_proto`.
    var swiftConformances: [SwiftConformance] = []
    /// In-image Swift protocol descriptors from `__swift5_protos` (navigator `isProtocol` facts).
    var swiftProtocols: [SwiftProtocolDescriptor] = []
    var exceptionMetadata: MachOExceptionMetadata
    var functionStarts: [MachOFunctionStart]
    /// Inline data ranges declared by `LC_DATA_IN_CODE`. These usually live inside an otherwise
    /// executable section and should not be treated as instruction locations.
    var dataInCodeEntries: [MachODataInCodeEntry]
    var uuid: MachOUUID?
    var buildVersion: MachOBuildVersion?
    /// Every LC_BUILD_VERSION in load-command order. `buildVersion` stays the last of them, so
    /// existing last-wins readers are unchanged; toolchain-key detection reads the full list.
    var buildVersions: [MachOBuildVersion] = []
    var sourceVersion: MachOSourceVersion?
    var legacyMinimumOSVersion: MachOMinimumOSVersion?
    /// Every LC_VERSION_MIN_* in load-command order; the singular field remains last-wins.
    var legacyMinimumOSVersions: [MachOMinimumOSVersion] = []
    var codeSignature: MachOCodeSignature?
    var dyldChainedFixups: MachODyldChainedFixups?

    /// Every typed per-image loader finding (chained-fixup refusals + ObjC metadata diagnosis +
    /// HS-12 LC_FUNCTION_STARTS vs unwind disagreements).
    var loaderFindings: [MachOLoaderFinding] {
        (dyldChainedFixups?.diagnostics ?? []) + objectiveCMetadata.diagnostics + functionStartsDiagnostics
            + metadataParseFindings
    }
    /// Exact loader-decryption declarations retained from LC_ENCRYPTION_INFO[_64].
    /// An entry is active when `cryptID != 0`; the file range then cannot be treated as
    /// identity-effective bytes without a caller-owned decrypted view.
    var encryptionInfos: [MachOEncryptionInfo] = []
    var entryPointOffset: UInt64?
    /// Entry PC recovered DIRECTLY as a virtual address (LC_UNIXTHREAD / LC_THREAD
    /// initial program counter). Unlike `entryPointOffset` (an LC_MAIN file offset that
    /// has to be projected through the segment table), this is already a VA, so it is
    /// used as-is. nil for binaries that carry only LC_MAIN or no entry point.
    var entryPointVirtualAddress: UInt64?
    var selectedSliceOffset: UInt64
    var universalBinary: MachOUniversalBinary?
    /// Lossless loader declarations in load-command order; nil means an older producer did not capture them.
    var loaderFacts: MachOLoaderFacts? = nil
    /// HS-12: unwind-derived function starts that LC_FUNCTION_STARTS does not list
    /// (`MachOUnwindFunctionStarts`). Evidence only; `functionStarts` is never changed by them.
    var functionStartsDiagnostics: [MachOLoaderFinding] = []
    /// HS-13: graded failures of the Swift and Objective-C metadata walks (#285), as findings.
    var metadataParseFindings: [MachOLoaderFinding] = []
    /// The graded Swift metadata walk diagnostics behind the Swift part of `metadataParseFindings`,
    /// kept typed for the navigator projection (frontier items by address).
    var swiftMetadataDiagnostics: [MetadataParseDiagnostic] = []

    var architectureName: String {
        MachOArchitecture.name(for: header.cpuType)
    }

    var architectureDisplayName: String {
        guard let universalBinary, let selectedSlice = universalBinary.selectedSlice else {
            return architectureName
        }
        return "\(architectureName) (universal slice \(selectedSlice.index + 1)/\(universalBinary.slices.count) @ \(selectedSlice.offsetHexString))"
    }

    var fileTypeName: String {
        switch header.fileType {
        case MachOConstants.fileTypeObject:
            "Mach-O object"
        case MachOConstants.fileTypeExecute:
            "Mach-O executable"
        case MachOConstants.fileTypeDylib:
            "Mach-O dylib"
        case MachOConstants.fileTypeBundle:
            "Mach-O bundle"
        default:
            "Mach-O filetype \(header.fileType)"
        }
    }

    var entryPointAddress: UInt64? {
        // LC_UNIXTHREAD/LC_THREAD give the entry PC directly as a virtual address.
        if let entryPointVirtualAddress {
            return entryPointVirtualAddress
        }
        // LC_MAIN gives a file offset that has to be projected to a virtual address.
        guard let entryPointOffset else { return nil }
        return virtualAddress(forFileOffset: entryPointOffset)
    }

    var executableTextSection: MachOSection? {
        sections.first { section in
            section.segmentName == "__TEXT" && section.sectionName == "__text"
        } ?? sections.first { $0.isExecutableInstructions }
    }

    func virtualAddress(forFileOffset fileOffset: UInt64) -> UInt64? {
        for segment in segments where segment.fileSize > 0 {
            // Overflow-checked: a hostile segment whose `fileOffset + fileSize` (or `vmAddress +
            // delta`) wraps UInt64 would otherwise TRAP this read-side mapping on a malformed
            // binary. A segment whose file range wraps is impossible — skip it.
            let (fileEnd, endOverflow) = segment.fileOffset.addingReportingOverflow(segment.fileSize)
            guard !endOverflow, fileOffset >= segment.fileOffset, fileOffset < fileEnd else { continue }
            let (virtualAddress, vaOverflow) = segment.vmAddress.addingReportingOverflow(fileOffset - segment.fileOffset)
            guard !vaOverflow else { return nil }
            return virtualAddress
        }
        return nil
    }
}

struct MachODataInCodeEntry: Hashable, Sendable {
    var fileOffset: UInt32
    var length: UInt16
    var kind: UInt16
    var address: UInt64

    var kindName: String {
        switch kind {
        case MachOConstants.dataInCodeKindData: "data"
        case MachOConstants.dataInCodeKindJumpTable8: "jump-table-8"
        case MachOConstants.dataInCodeKindJumpTable16: "jump-table-16"
        case MachOConstants.dataInCodeKindJumpTable32: "jump-table-32"
        case MachOConstants.dataInCodeKindAbsJumpTable32: "absolute-jump-table-32"
        default: "kind-\(kind)"
        }
    }
}

struct MachOHeader: Sendable {
    var magic: UInt32
    var cpuType: Int32
    var cpuSubtype: Int32
    var fileType: UInt32
    var loadCommandCount: UInt32
    var loadCommandsSize: UInt32
    var flags: UInt32
    var reserved: UInt32
}

struct MachOUniversalBinary: Hashable, Sendable {
    var is64Bit: Bool
    var slices: [MachOUniversalSlice]
    var selectedSliceIndex: Int

    var selectedSlice: MachOUniversalSlice? {
        guard slices.indices.contains(selectedSliceIndex) else { return nil }
        return slices[selectedSliceIndex]
    }
}

struct MachOUniversalSlice: Hashable, Sendable {
    var index: Int
    var cpuType: Int32
    var cpuSubtype: Int32
    var offset: UInt64
    var size: UInt64
    var alignment: UInt32

    /// The slice-picker label. Includes the CPU subtype so the arm64-family slices of a modern
    /// system binary (e.g. /usr/bin/vim: arm64e and arm64e.x1) are distinguishable.
    var architectureName: String {
        MachOArchitecture.name(for: cpuType, cpuSubtype: cpuSubtype)
    }

    var offsetHexString: String {
        "0x\(String(offset, radix: 16))"
    }
}

struct MachOLoadCommand: Hashable, Sendable {
    var command: UInt32
    var commandSize: UInt32
    var offset: UInt64

    var name: String {
        switch command {
        case MachOConstants.loadCommandSymtab:
            "LC_SYMTAB"
        case MachOConstants.loadCommandDysymtab:
            "LC_DYSYMTAB"
        case MachOConstants.loadCommandSegment64:
            "LC_SEGMENT_64"
        case MachOConstants.loadCommandUUID:
            "LC_UUID"
        case MachOConstants.loadCommandDyldInfo:
            "LC_DYLD_INFO"
        case MachOConstants.loadCommandDyldInfoOnly:
            "LC_DYLD_INFO_ONLY"
        case MachOConstants.loadCommandLoadDylib:
            "LC_LOAD_DYLIB"
        case MachOConstants.loadCommandLoadWeakDylib:
            "LC_LOAD_WEAK_DYLIB"
        case MachOConstants.loadCommandReexportDylib:
            "LC_REEXPORT_DYLIB"
        case MachOConstants.loadCommandLoadUpwardDylib:
            "LC_LOAD_UPWARD_DYLIB"
        case MachOConstants.loadCommandLazyLoadDylib:
            "LC_LAZY_LOAD_DYLIB"
        case MachOConstants.loadCommandRPath:
            "LC_RPATH"
        case MachOConstants.loadCommandMain:
            "LC_MAIN"
        case MachOConstants.loadCommandThread:
            "LC_THREAD"
        case MachOConstants.loadCommandUnixThread:
            "LC_UNIXTHREAD"
        case MachOConstants.loadCommandCodeSignature:
            "LC_CODE_SIGNATURE"
        case MachOConstants.loadCommandEncryptionInfo:
            "LC_ENCRYPTION_INFO"
        case MachOConstants.loadCommandEncryptionInfo64:
            "LC_ENCRYPTION_INFO_64"
        case MachOConstants.loadCommandDyldChainedFixups:
            "LC_DYLD_CHAINED_FIXUPS"
        case MachOConstants.loadCommandDyldExportsTrie:
            "LC_DYLD_EXPORTS_TRIE"
        case MachOConstants.loadCommandFunctionStarts:
            "LC_FUNCTION_STARTS"
        case MachOConstants.loadCommandDataInCode:
            "LC_DATA_IN_CODE"
        case MachOConstants.loadCommandBuildVersion:
            "LC_BUILD_VERSION"
        case MachOConstants.loadCommandSourceVersion:
            "LC_SOURCE_VERSION"
        case MachOConstants.loadCommandVersionMinMacOSX:
            "LC_VERSION_MIN_MACOSX"
        case MachOConstants.loadCommandVersionMinIPhoneOS:
            "LC_VERSION_MIN_IPHONEOS"
        case MachOConstants.loadCommandVersionMinTVOS:
            "LC_VERSION_MIN_TVOS"
        case MachOConstants.loadCommandVersionMinWatchOS:
            "LC_VERSION_MIN_WATCHOS"
        default:
            String(format: "LC_0x%08x", command)
        }
    }
}

struct MachOEncryptionInfo: Hashable, Sendable {
    var command: UInt32
    var cryptOffset: UInt32
    var cryptSize: UInt32
    var cryptID: UInt32

    var isActive: Bool { cryptID != 0 }
}

struct MachOSegment: Hashable, Sendable {
    var name: String
    var vmAddress: UInt64
    var vmSize: UInt64
    var fileOffset: UInt64
    var fileSize: UInt64
    var maxProtection: Int32
    var initialProtection: Int32
    var sectionCount: UInt32
    var flags: UInt32
}

struct MachOSection: Hashable, Sendable {
    var sectionName: String
    var segmentName: String
    var address: UInt64
    var size: UInt64
    var fileOffset: UInt32
    var alignment: UInt32
    var relocationOffset: UInt32
    var relocationCount: UInt32
    var flags: UInt32
    var reserved1: UInt32
    var reserved2: UInt32
    var reserved3: UInt32

    var isExecutableInstructions: Bool {
        let attributes = flags & MachOConstants.sectionAttributesMask
        return attributes & MachOConstants.sectionAttributeSomeInstructions != 0
            || attributes & MachOConstants.sectionAttributePureInstructions != 0
            || (segmentName == "__TEXT" && sectionName == "__text")
    }

    var isCStringLiterals: Bool {
        let sectionType = flags & MachOConstants.sectionTypeMask
        return sectionType == MachOConstants.sectionTypeCStringLiterals
            || (segmentName == "__TEXT" && sectionName == "__cstring")
    }

    /// A zero-fill (BSS-type) section: it occupies virtual-address space but has NO file
    /// content, so its `fileOffset` is a placeholder (0) and its bytes are zero at runtime.
    var isZeroFill: Bool {
        let sectionType = flags & MachOConstants.sectionTypeMask
        return sectionType == MachOConstants.sectionTypeZeroFill
            || sectionType == MachOConstants.sectionTypeGBZeroFill
            || sectionType == MachOConstants.sectionTypeThreadLocalZeroFill
    }

    var qualifiedName: String {
        "\(segmentName),\(sectionName)"
    }
}

struct MachODylib: Hashable, Sendable {
    var name: String
    var ordinal: Int
    var command: UInt32
    var pathKind: MachORuntimePathKind
    var timestamp: UInt32
    var currentVersion: MachODylibVersion
    var compatibilityVersion: MachODylibVersion
    /// Raw alternate-encoding flags, including unsupported bits.
    var useFlags: UInt32? = nil

    var displayName: String {
        URL(fileURLWithPath: name).lastPathComponent
    }

    var commandName: String {
        switch command {
        case MachOConstants.loadCommandLoadDylib:
            "LC_LOAD_DYLIB"
        case MachOConstants.loadCommandLoadWeakDylib:
            "LC_LOAD_WEAK_DYLIB"
        case MachOConstants.loadCommandReexportDylib:
            "LC_REEXPORT_DYLIB"
        case MachOConstants.loadCommandLoadUpwardDylib:
            "LC_LOAD_UPWARD_DYLIB"
        case MachOConstants.loadCommandLazyLoadDylib:
            "LC_LAZY_LOAD_DYLIB"
        default:
            String(format: "LC_0x%08x", command)
        }
    }

    var loadKind: String {
        switch command {
        case MachOConstants.loadCommandLoadDylib:
            "required"
        case MachOConstants.loadCommandLoadWeakDylib:
            "weak"
        case MachOConstants.loadCommandReexportDylib:
            "reexport"
        case MachOConstants.loadCommandLoadUpwardDylib:
            "upward"
        case MachOConstants.loadCommandLazyLoadDylib:
            "lazy"
        default:
            "unknown"
        }
    }

    var isSystemLibrary: Bool {
        pathKind == .systemAbsolute
    }

    var rpathSuffix: String? {
        guard pathKind == .rpathRelative else { return nil }
        if name == "@rpath" {
            return ""
        }
        guard name.hasPrefix("@rpath/") else { return nil }
        return String(name.dropFirst("@rpath/".count))
    }
}

struct MachODylibVersion: Hashable, Sendable {
    var encodedValue: UInt32
    var major: UInt32
    var minor: UInt32
    var patch: UInt32

    init(encodedValue: UInt32) {
        self.encodedValue = encodedValue
        major = (encodedValue >> 16) & 0xffff
        minor = (encodedValue >> 8) & 0xff
        patch = encodedValue & 0xff
    }

    var stringValue: String {
        "\(major).\(minor).\(patch)"
    }
}

struct MachORPath: Hashable, Sendable {
    var path: String
    var command: UInt32
    var pathKind: MachORuntimePathKind
}

enum MachORuntimePathKind: String, Hashable, Sendable {
    case systemAbsolute
    case absolute
    case rpathRelative
    case loaderPathRelative
    case executablePathRelative
    case installNameRelative
    case relative
    case empty

    init(path: String) {
        if path.isEmpty {
            self = .empty
        } else if path.hasPrefix("/usr/lib/")
            || path.hasPrefix("/System/Library/")
            || path == "/usr/lib"
            || path == "/System/Library"
        {
            self = .systemAbsolute
        } else if path.hasPrefix("/") {
            self = .absolute
        } else if path == "@rpath" || path.hasPrefix("@rpath/") {
            self = .rpathRelative
        } else if path == "@loader_path" || path.hasPrefix("@loader_path/") {
            self = .loaderPathRelative
        } else if path == "@executable_path" || path.hasPrefix("@executable_path/") {
            self = .executablePathRelative
        } else if path.hasPrefix("@") {
            self = .installNameRelative
        } else {
            self = .relative
        }
    }

    var displayName: String {
        switch self {
        case .systemAbsolute:
            "system absolute"
        case .absolute:
            "absolute"
        case .rpathRelative:
            "@rpath"
        case .loaderPathRelative:
            "@loader_path"
        case .executablePathRelative:
            "@executable_path"
        case .installNameRelative:
            "install-name token"
        case .relative:
            "relative"
        case .empty:
            "empty"
        }
    }
}

enum MachOSymbolKind: String, Sendable {
    case local
    case `import`
    case export
    case undefined
    case absolute
    case indirect
}

struct MachOSymbol: Hashable, Sendable {
    var index: Int
    var name: String
    var address: UInt64?
    var kind: MachOSymbolKind
    var isExternal: Bool
    var sectionIndex: UInt8
    var type: UInt8
    var description: UInt16
    var libraryOrdinal: Int?
    var libraryName: String?
}

struct MachOImport: Hashable, Sendable {
    var symbolIndex: Int
    var name: String
    var libraryOrdinal: Int?
    var libraryName: String?
}

enum MachOIndirectSymbolKind: String, Sendable {
    case symbolStub
    case lazySymbolPointer
    case nonLazySymbolPointer
}

struct MachOIndirectSymbol: Hashable, Sendable {
    var kind: MachOIndirectSymbolKind
    var segmentName: String
    var sectionName: String
    var address: UInt64
    var entrySize: UInt32
    var tableIndex: UInt32
    var rawSymbolIndex: UInt32
    var symbolIndex: Int?
    var symbolName: String?
    var libraryOrdinal: Int?
    var libraryName: String?
    var isLocal: Bool
    var isAbsolute: Bool

    var sourceSection: String {
        "\(segmentName),\(sectionName)"
    }
}

struct MachORelocation: Hashable, Sendable {
    var segmentName: String
    var sectionName: String
    var entryIndex: Int
    var fileOffset: UInt64
    var relocationAddress: UInt32
    var resolvedAddress: UInt64?
    var symbolNumber: UInt32?
    var symbolName: String?
    var isPCRelative: Bool
    var length: UInt8
    var isExternal: Bool
    var type: UInt8
    var isScattered: Bool
    var value: UInt32?

    var sourceSection: String {
        "\(segmentName),\(sectionName)"
    }

    var widthInBytes: UInt32 {
        1 << UInt32(length)
    }

    var typeName: String {
        switch type {
        case MachOConstants.arm64RelocUnsigned:
            "ARM64_RELOC_UNSIGNED"
        case MachOConstants.arm64RelocSubtractor:
            "ARM64_RELOC_SUBTRACTOR"
        case MachOConstants.arm64RelocBranch26:
            "ARM64_RELOC_BRANCH26"
        case MachOConstants.arm64RelocPage21:
            "ARM64_RELOC_PAGE21"
        case MachOConstants.arm64RelocPageOff12:
            "ARM64_RELOC_PAGEOFF12"
        case MachOConstants.arm64RelocGOTLoadPage21:
            "ARM64_RELOC_GOT_LOAD_PAGE21"
        case MachOConstants.arm64RelocGOTLoadPageOff12:
            "ARM64_RELOC_GOT_LOAD_PAGEOFF12"
        case MachOConstants.arm64RelocPointerToGOT:
            "ARM64_RELOC_POINTER_TO_GOT"
        case MachOConstants.arm64RelocTLVPLoadPage21:
            "ARM64_RELOC_TLVP_LOAD_PAGE21"
        case MachOConstants.arm64RelocTLVPLoadPageOff12:
            "ARM64_RELOC_TLVP_LOAD_PAGEOFF12"
        case MachOConstants.arm64RelocAddend:
            "ARM64_RELOC_ADDEND"
        case MachOConstants.arm64RelocAuthenticatedPointer:
            "ARM64_RELOC_AUTHENTICATED_POINTER"
        default:
            "ARM64_RELOC_\(type)"
        }
    }
}

struct MachOExport: Hashable, Sendable {
    var symbolIndex: Int?
    var name: String
    var address: UInt64?
    var flags: UInt64?
    var source: String
}

struct MachOStringLiteral: Hashable, Sendable {
    var value: String
    var address: UInt64
    var sourceSection: String
    var byteLength: Int
}

struct MachOObjectiveCMetadata: Hashable, Sendable {
    var sections: [MachOMetadataSection]
    var selectorStrings: [MachOMetadataString]
    var classNameStrings: [MachOMetadataString]
    var methodTypeStrings: [MachOMetadataString]
    var selectorReferences: [MachOObjectiveCReference]
    var classReferences: [MachOObjectiveCReference]
    var superclassReferences: [MachOObjectiveCReference]
    /// Classes recovered by walking `__objc_classlist` → `class_t` → `class_ro_t` (names and
    /// superclasses today; members as the walker grows). Empty when none were recovered.
    var classes: [ObjCClass] = []
    /// Categories recovered by walking `__objc_catlist` → `category_t` (typically categories on an
    /// external class, since same-image categories are merged into the class at link time).
    var categories: [ObjCCategory] = []
    var protocols: [ObjCProtocol] = []
    /// Typed refusals about the ObjC metadata as a whole (e.g. an image manually extracted from
    /// the dyld shared cache, whose selector/class references point outside the image).
    var diagnostics: [MachOLoaderFinding] = []
    /// The class/category walk's graded failures (skipped methods, abandoned lists).
    var parseDiagnostics: [MetadataParseDiagnostic] = []
    /// Failures the walk's bounded log counted but didn't keep.
    var parseDiagnosticsDropped = 0

    static let empty = MachOObjectiveCMetadata(
        sections: [],
        selectorStrings: [],
        classNameStrings: [],
        methodTypeStrings: [],
        selectorReferences: [],
        classReferences: [],
        superclassReferences: []
    )
}

struct MachOMetadataSection: Hashable, Sendable {
    var kind: String
    var sectionName: String
    var segmentName: String
    var address: UInt64
    var size: UInt64
    var fileOffset: UInt32
    var entrySize: Int?
    var entryCount: Int?

    var qualifiedName: String {
        "\(segmentName),\(sectionName)"
    }
}

struct MachOMetadataString: Hashable, Sendable {
    var value: String
    var address: UInt64
    var sourceSection: String
    var byteLength: Int
}

struct MachOObjectiveCReference: Hashable, Sendable {
    var kind: String
    var sourceAddress: UInt64
    var targetAddress: UInt64
    var sourceSection: String
    var resolvedName: String?
}

struct MachOFunctionStart: Hashable, Sendable {
    var offsetFromImageBase: UInt64
    var address: UInt64
}

struct MachOExceptionMetadata: Hashable, Sendable {
    var sections: [MachOExceptionSection]
    var relatedLoadCommands: [MachOExceptionLoadCommand]

    static let empty = MachOExceptionMetadata(sections: [], relatedLoadCommands: [])

    var isEmpty: Bool {
        sections.isEmpty && relatedLoadCommands.isEmpty
    }

    var totalByteCount: UInt64 {
        // `section.size` is attacker-controlled, so the running sum can overflow UInt64; saturate
        // at .max rather than trapping (a byte-count total reads as "at least this big").
        sections.reduce(0) { partialResult, section in
            let (sum, overflow) = partialResult.addingReportingOverflow(section.size)
            return overflow ? .max : sum
        }
    }

    var compactUnwindEntryCount: Int {
        sections
            .filter { $0.kind == .compactUnwind }
            .compactMap(\.entryCount)
            .reduce(0, +)
    }
}

struct MachOExceptionSection: Hashable, Sendable {
    var kind: MachOExceptionSectionKind
    var sectionName: String
    var segmentName: String
    var address: UInt64
    var size: UInt64
    var fileOffset: UInt32
    var entrySize: Int?
    var entryCount: Int?
    var unwindInfoHeader: MachOUnwindInfoHeader?

    var qualifiedName: String {
        "\(segmentName),\(sectionName)"
    }

    var endAddress: UInt64 {
        let result = address.addingReportingOverflow(size)
        return result.overflow ? UInt64.max : result.partialValue
    }

    var endFileOffset: UInt64 {
        let result = UInt64(fileOffset).addingReportingOverflow(size)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

enum MachOExceptionSectionKind: String, Hashable, Sendable {
    case unwindInfo
    case compactUnwind
    case dwarfEHFrame
    case languageSpecificData

    var displayName: String {
        switch self {
        case .unwindInfo:
            "compact unwind info"
        case .compactUnwind:
            "relocatable compact unwind rows"
        case .dwarfEHFrame:
            "DWARF exception frames"
        case .languageSpecificData:
            "exception language-specific data"
        }
    }
}

struct MachOUnwindInfoHeader: Hashable, Sendable {
    var version: UInt32
    var commonEncodingsArraySectionOffset: UInt32
    var commonEncodingsArrayCount: UInt32
    var personalityArraySectionOffset: UInt32
    var personalityArrayCount: UInt32
    var indexSectionOffset: UInt32
    var indexCount: UInt32
}

struct MachOExceptionLoadCommand: Hashable, Sendable {
    var command: UInt32
    var name: String
    var offset: UInt64
    var dataOffset: UInt32?
    var dataSize: UInt32?

    var endOffset: UInt64? {
        guard let dataOffset, let dataSize else { return nil }
        let result = UInt64(dataOffset).addingReportingOverflow(UInt64(dataSize))
        return result.overflow ? UInt64.max : result.partialValue
    }
}

struct MachOCodeSignature: Hashable, Sendable {
    var dataOffset: UInt32
    var dataSize: UInt32
    var superBlob: MachOCodeSignatureSuperBlob?

    var endOffset: UInt64 {
        UInt64(dataOffset) + UInt64(dataSize)
    }
}

struct MachOCodeSignatureSuperBlob: Hashable, Sendable {
    var magic: UInt32
    var length: UInt32
    var blobCount: UInt32
    var blobs: [MachOCodeSignatureBlob]

    var codeDirectories: [MachOCodeDirectorySummary] {
        blobs.compactMap(\.codeDirectory)
    }

    var entitlementSummaries: [MachOCodeSignatureEntitlementsSummary] {
        blobs.compactMap(\.entitlements)
    }

    var magicName: String {
        switch magic {
        case MachOConstants.codeSignatureEmbeddedSignatureMagic:
            "Embedded Signature SuperBlob"
        case MachOConstants.codeSignatureDetachedSignatureMagic:
            "Detached Signature SuperBlob"
        default:
            String(format: "CSMAGIC_0x%08x", magic)
        }
    }
}

struct MachOCodeSignatureBlob: Hashable, Sendable {
    var type: UInt32
    var relativeOffset: UInt32
    var fileOffset: UInt64
    var magic: UInt32
    var length: UInt32
    var codeDirectory: MachOCodeDirectorySummary?
    var entitlements: MachOCodeSignatureEntitlementsSummary?

    var typeName: String {
        switch type {
        case MachOConstants.codeSignatureSlotCodeDirectory:
            "Code Directory"
        case MachOConstants.codeSignatureSlotInfoPlist:
            "Info.plist"
        case MachOConstants.codeSignatureSlotRequirements:
            "Requirements"
        case MachOConstants.codeSignatureSlotResourceDirectory:
            "Resource Directory"
        case MachOConstants.codeSignatureSlotApplication:
            "Application"
        case MachOConstants.codeSignatureSlotEntitlements:
            "Entitlements"
        case MachOConstants.codeSignatureSlotDerEntitlements:
            "DER Entitlements"
        case MachOConstants.codeSignatureSlotAlternateCodeDirectoryStart...MachOConstants.codeSignatureSlotAlternateCodeDirectoryEnd:
            "Alternate Code Directory \(type - MachOConstants.codeSignatureSlotAlternateCodeDirectoryStart)"
        default:
            "slot \(type)"
        }
    }

    var magicName: String {
        switch magic {
        case MachOConstants.codeSignatureRequirementMagic:
            "Requirement"
        case MachOConstants.codeSignatureRequirementsMagic:
            "Requirements"
        case MachOConstants.codeSignatureCodeDirectoryMagic:
            "Code Directory"
        case MachOConstants.codeSignatureEmbeddedEntitlementsMagic:
            "XML Entitlements"
        case MachOConstants.codeSignatureDerEntitlementsMagic:
            "DER Entitlements"
        case MachOConstants.codeSignatureBlobWrapperMagic:
            "CMS Signature"
        default:
            String(format: "CSMAGIC_0x%08x", magic)
        }
    }
}

struct MachOCodeDirectorySummary: Hashable, Sendable {
    var version: UInt32
    var flags: UInt32
    var hashOffset: UInt32
    var identifierOffset: UInt32
    var specialSlotCount: UInt32
    var codeSlotCount: UInt32
    var codeLimit: UInt32
    var hashSize: UInt8
    var hashType: UInt8
    var platform: UInt8
    var pageSize: UInt8
    var identifier: String?
    var teamIdentifier: String?

    var versionHexString: String {
        String(format: "0x%05x", version)
    }

    var flagsHexString: String {
        String(format: "0x%08x", flags)
    }

    var hashTypeName: String {
        switch hashType {
        case MachOConstants.codeSignatureHashTypeSHA1:
            "SHA-1"
        case MachOConstants.codeSignatureHashTypeSHA256:
            "SHA-256"
        case MachOConstants.codeSignatureHashTypeSHA256Truncated:
            "SHA-256 truncated"
        case MachOConstants.codeSignatureHashTypeSHA384:
            "SHA-384"
        default:
            "hash type \(hashType)"
        }
    }
}

struct MachOCodeSignatureEntitlementsSummary: Hashable, Sendable {
    var format: MachOCodeSignatureEntitlementsFormat
    var keyCount: Int?
    var keys: [String]
    var isParsed: Bool
}

enum MachOCodeSignatureEntitlementsFormat: String, Hashable, Sendable {
    case xml = "XML"
    case der = "DER"

    var displayName: String {
        rawValue
    }
}

/// One entry from the dyld chained-fixups imports table: a deferred bind to an
/// imported symbol resolved out of a named dylib (by library ordinal).
struct MachOChainedImport: Hashable, Sendable {
    /// Index of this import in the imports table — chain BIND entries reference it.
    var index: Int
    var name: String
    /// Library ordinal in the shared nlist-style model: 1-based into the dylib list,
    /// `MachOConstants.executableLibraryOrdinal` (0xff) for the main executable, or
    /// `MachOConstants.dynamicLookupLibraryOrdinal` (0xfe) for flat lookup. `nil` when
    /// that model has no exact encoding (self, weak lookup, unknown special values) or
    /// the encoded ordinal does not name a declared dylib; `encodedLibraryOrdinal`
    /// keeps the exact dyld value in every case.
    var libraryOrdinal: Int?
    var libraryName: String?
    var isWeakImport: Bool
    /// Addend baked into the import record (only the _ADDEND / _ADDEND64 formats carry one).
    var addend: Int64
    /// The sign-extended dyld `lib_ordinal` exactly as encoded (`> 0xF0` / `> 0xFFF0` raw
    /// values are negative specials: 0 self, -1 main executable, -2 flat lookup, -3 weak
    /// lookup). `nil` when this record was not decoded from an imports table.
    var encodedLibraryOrdinal: Int? = nil

    /// The dyld special library ordinal this import binds through, if any.
    var specialLibraryOrdinal: MachOChainedSpecialLibraryOrdinal? {
        encodedLibraryOrdinal.flatMap(MachOChainedSpecialLibraryOrdinal.init(rawValue:))
    }
}

/// dyld `BIND_SPECIAL_DYLIB_*` ordinals as they appear (sign-extended) in chained imports.
enum MachOChainedSpecialLibraryOrdinal: Int, Hashable, Sendable {
    case selfImage = 0
    case mainExecutable = -1
    case flatLookup = -2
    case weakLookup = -3

    var displayName: String {
        switch self {
        case .selfImage: "self"
        case .mainExecutable: "main executable"
        case .flatLookup: "dynamic lookup"
        case .weakLookup: "weak lookup"
        }
    }
}

/// Classifies a resolved chained-fixup entry recovered by walking the chains.
enum MachOChainedFixupKind: Hashable, Sendable {
    /// A pointer rebased to an in-image target (the walk resolved the runtime VM address).
    case rebase(targetAddress: UInt64)
    /// A pointer bound to an imported symbol (the import ordinal was resolved to a name).
    /// `addend` is the full dyld addend: the import record's addend plus the addend
    /// encoded inline in the chained pointer (wrapping 64-bit, as dyld computes it).
    case bind(importOrdinal: Int, symbolName: String?, addend: Int64)
}

/// A single resolved fixup: the location in the image that dyld would patch, plus
/// what it resolves to (an in-image rebase target or an imported-symbol bind).
struct MachOChainedFixup: Hashable, Sendable {
    /// File offset of the patched pointer within the binary slice.
    var fileOffset: UInt64
    /// Runtime virtual address of the patched pointer (segment VM base + offset).
    var address: UInt64
    /// The decoded `pointer_format` of the segment this entry came from.
    var pointerFormat: UInt16
    var kind: MachOChainedFixupKind

    var isBind: Bool {
        if case .bind = kind { return true }
        return false
    }

    var isRebase: Bool {
        if case .rebase = kind { return true }
        return false
    }

    /// The imported symbol name for a BIND, else nil.
    var boundSymbolName: String? {
        if case let .bind(_, symbolName, _) = kind { return symbolName }
        return nil
    }

    /// The combined (import + inline) addend for a BIND, else nil.
    var boundAddend: Int64? {
        if case let .bind(_, _, addend) = kind { return addend }
        return nil
    }

    /// The symbol whose exact address the patched pointer holds: a resolved BIND with a
    /// zero combined addend. A nonzero addend points inside/past the symbol, so pointer
    /// consumers must not treat the slot as a reference to the symbol itself.
    var exactBoundSymbolName: String? {
        if case let .bind(_, symbolName, addend) = kind, addend == 0 { return symbolName }
        return nil
    }

    /// The in-image target VM address for a REBASE, else nil.
    var rebaseTargetAddress: UInt64? {
        if case let .rebase(targetAddress) = kind { return targetAddress }
        return nil
    }
}

struct MachODyldChainedFixups: Hashable, Sendable {
    var dataOffset: UInt32
    var dataSize: UInt32
    var fixupsVersion: UInt32
    var startsOffset: UInt32
    var importsOffset: UInt32
    var symbolsOffset: UInt32
    var importsCount: UInt32
    var importsFormat: UInt32
    var symbolsFormat: UInt32
    /// Imports table resolved to symbol names + library ordinals. Empty when the
    /// imports could not be decoded (unknown format / out-of-range pool).
    var imports: [MachOChainedImport] = []
    /// Bind + rebase targets recovered by walking the per-page chains. Empty when the
    /// starts table is absent, malformed, or uses only unsupported pointer formats —
    /// the walk degrades gracefully rather than throwing.
    var fixups: [MachOChainedFixup] = []
    /// Typed, per-image refusals recorded while decoding the payload: every pointer format,
    /// import format, symbols format, rebase shape, `DYLD_CHAINED_PTR_START_MULTI` page and
    /// chain stride/delta inconsistency the walker does not handle is named here instead of
    /// being misread or dropped silently. Bounded by `MachOLoaderFinding.maximumPerImage`.
    var diagnostics: [MachOLoaderFinding] = []

    var bindCount: Int { fixups.lazy.filter(\.isBind).count }
    var rebaseCount: Int { fixups.lazy.filter(\.isRebase).count }

    var endOffset: UInt64 {
        UInt64(dataOffset) + UInt64(dataSize)
    }

    var startsFileOffset: UInt64 {
        UInt64(dataOffset) + UInt64(startsOffset)
    }

    var importsFileOffset: UInt64 {
        UInt64(dataOffset) + UInt64(importsOffset)
    }

    var symbolsFileOffset: UInt64 {
        UInt64(dataOffset) + UInt64(symbolsOffset)
    }

    var importsFormatName: String {
        switch importsFormat {
        case MachOConstants.dyldChainedImport:
            "DYLD_CHAINED_IMPORT"
        case MachOConstants.dyldChainedImportAddend:
            "DYLD_CHAINED_IMPORT_ADDEND"
        case MachOConstants.dyldChainedImportAddend64:
            "DYLD_CHAINED_IMPORT_ADDEND64"
        default:
            "imports format \(importsFormat)"
        }
    }

    var symbolsFormatName: String {
        switch symbolsFormat {
        case MachOConstants.dyldChainedSymbolsUncompressed:
            "uncompressed"
        case MachOConstants.dyldChainedSymbolsZlibCompressed:
            "zlib compressed"
        default:
            "symbols format \(symbolsFormat)"
        }
    }
}

/// One typed loader refusal/inconsistency for a single Mach-O image. `kind` is the closed
/// classifier; `message` is app-owned text built only from enum vocabulary and numbers (never
/// bytes from the file), so it may be shown verbatim in the Problems panel.
struct MachOLoaderFinding: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        case chainedFixupsUnknownVersion
        case chainedFixupsUnhandledImportFormat
        case chainedFixupsImportReservedBits
        case chainedFixupsImportNameOutOfRange
        case chainedFixupsImportNameUnterminated
        case chainedFixupsCompressedImportNames
        case chainedFixupsUnknownSymbolsFormat
        case chainedFixupsUnhandledPointerFormat
        case chainedFixupsStartMultiUnhandled
        case chainedFixupsUnhandledRebase
        case chainedFixupsChainDeltaMismatch
        case chainedFixupsBindOrdinalOutOfRange
        case objcMetadataFromSharedCacheExtraction
        /// HS-12: `__unwind_info` lists a function start that LC_FUNCTION_STARTS does not.
        case unwindFunctionStartNotInFunctionStarts
        /// HS-13 (#285): a Swift or Objective-C metadata walk skipped one entry it couldn't read.
        case metadataSkippedItem
        /// HS-13: a metadata walk abandoned the rest of a list after an unreadable descriptor.
        case metadataAbandonedList
        /// HS-13: a descriptor of a kind the parser doesn't model was kept with a label.
        case metadataUnknownKind
        /// HS-13: a context-parent walk stopped at its depth limit or a cycle.
        case metadataWalkCapped

        var isChainedFixups: Bool { rawValue.hasPrefix("chainedFixups") }
        var isMetadataParse: Bool { rawValue.hasPrefix("metadata") }
    }

    /// HS-13: the metadata walks' graded failures as findings, one per kind and address. Each
    /// source (Swift, Objective-C) gets half of `maximumPerImage`, so a noisy walk can't crowd out
    /// the other; when a source has more (or its parser's log dropped some), its last finding says
    /// how many aren't listed. Messages are built from the grade and address only: the parsers'
    /// own text can quote names read from the file.
    static func metadataParseFindings(swift: [MetadataParseDiagnostic], swiftDropped: Int = 0,
                                      objectiveC: [MetadataParseDiagnostic], objectiveCDropped: Int = 0) -> [MachOLoaderFinding] {
        let perSource = maximumPerImage / 2
        var findings: [MachOLoaderFinding] = []
        for (source, diagnostics, dropped) in [("Swift", swift, swiftDropped), ("Objective-C", objectiveC, objectiveCDropped)] {
            var seen = Set<String>()
            var listed: [MachOLoaderFinding] = []
            var unlisted = dropped
            for diagnostic in diagnostics {
                let (kind, phrase): (Kind, String) = switch diagnostic.grade {
                case .skippedItem: (.metadataSkippedItem, "skipped an entry it could not read")
                case .abandonedList: (.metadataAbandonedList, "abandoned a list after an unreadable descriptor")
                case .labelledUnknownKind: (.metadataUnknownKind, "kept a descriptor of an unknown kind")
                case .walkCapped: (.metadataWalkCapped, "stopped a context walk at its depth limit")
                }
                guard seen.insert("\(kind.rawValue)@\(diagnostic.address)").inserted else { continue }
                guard listed.count < perSource else { unlisted += 1; continue }
                listed.append(MachOLoaderFinding(
                    kind: kind, address: diagnostic.address, value: nil,
                    message: "\(source) metadata: the parser \(phrase) at 0x\(String(diagnostic.address, radix: 16))."
                ))
            }
            if unlisted > 0, !listed.isEmpty {
                listed[listed.count - 1].message += " \(unlisted) more \(source) metadata issue\(unlisted == 1 ? " is" : "s are") not listed."
            }
            findings += listed
        }
        return findings
    }

    static let maximumPerImage = 64

    var kind: Kind
    /// Navigation anchor: the chain slot, segment or image base the finding is about.
    var address: UInt64
    /// The offending numeric value (format, ordinal, delta...), when one exists.
    var value: UInt64?
    var message: String

    /// The `DYLD_CHAINED_PTR_*` name for a pointer_format value (fixup-chains.h).
    static func chainedPointerFormatName(_ format: UInt16) -> String {
        switch format {
        case 1: "DYLD_CHAINED_PTR_ARM64E"
        case 2: "DYLD_CHAINED_PTR_64"
        case 3: "DYLD_CHAINED_PTR_32"
        case 4: "DYLD_CHAINED_PTR_32_CACHE"
        case 5: "DYLD_CHAINED_PTR_32_FIRMWARE"
        case 6: "DYLD_CHAINED_PTR_64_OFFSET"
        case 7: "DYLD_CHAINED_PTR_ARM64E_KERNEL"
        case 8: "DYLD_CHAINED_PTR_64_KERNEL_CACHE"
        case 9: "DYLD_CHAINED_PTR_ARM64E_USERLAND"
        case 10: "DYLD_CHAINED_PTR_ARM64E_FIRMWARE"
        case 11: "DYLD_CHAINED_PTR_X86_64_KERNEL_CACHE"
        case 12: "DYLD_CHAINED_PTR_ARM64E_USERLAND24"
        case 13: "DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE"
        case 14: "DYLD_CHAINED_PTR_ARM64E_SEGMENTED"
        default: "pointer format \(format)"
        }
    }
}

/// Bounded, de-duplicating accumulator for per-image loader findings.
struct MachOLoaderFindingLog {
    private(set) var findings: [MachOLoaderFinding] = []
    private var seen = Set<String>()

    /// Records a finding once per (kind, value, scope); `scope` lets per-slot kinds collapse to
    /// one row per segment so a fully unsupported chain cannot flood the Problems panel.
    mutating func record(_ finding: MachOLoaderFinding, scope: UInt64? = nil) {
        guard findings.count < MachOLoaderFinding.maximumPerImage else { return }
        let key = "\(finding.kind.rawValue)|\(finding.value.map { String($0) } ?? "-")|\(scope.map { String($0) } ?? "-")"
        guard seen.insert(key).inserted else { return }
        findings.append(finding)
    }
}

struct MachOUUID: Hashable, Sendable {
    var bytes: [UInt8]

    var stringValue: String {
        [
            bytes[0..<4],
            bytes[4..<6],
            bytes[6..<8],
            bytes[8..<10],
            bytes[10..<16]
        ]
        .map { chunk in
            chunk.map { String(format: "%02x", $0) }.joined()
        }
        .joined(separator: "-")
    }
}

struct MachOVersion: Hashable, Sendable {
    var encodedValue: UInt32
    var major: UInt32
    var minor: UInt32
    var patch: UInt32

    init(encodedValue: UInt32) {
        self.encodedValue = encodedValue
        major = (encodedValue >> 16) & 0xffff
        minor = (encodedValue >> 8) & 0xff
        patch = encodedValue & 0xff
    }

    var stringValue: String {
        if patch == 0 {
            return "\(major).\(minor)"
        }
        return "\(major).\(minor).\(patch)"
    }
}

struct MachOBuildVersion: Hashable, Sendable {
    var platform: UInt32
    var minimumOSVersion: MachOVersion
    var sdkVersion: MachOVersion
    var tools: [MachOBuildToolVersion]

    var platformName: String {
        switch platform {
        case MachOConstants.platformMacOS:
            "macOS"
        case MachOConstants.platformIOS:
            "iOS"
        case MachOConstants.platformTVOS:
            "tvOS"
        case MachOConstants.platformWatchOS:
            "watchOS"
        case MachOConstants.platformBridgeOS:
            "bridgeOS"
        case MachOConstants.platformMacCatalyst:
            "Mac Catalyst"
        case MachOConstants.platformIOSSimulator:
            "iOS Simulator"
        case MachOConstants.platformTVOSSimulator:
            "tvOS Simulator"
        case MachOConstants.platformWatchOSSimulator:
            "watchOS Simulator"
        case MachOConstants.platformDriverKit:
            "DriverKit"
        case MachOConstants.platformVisionOS:
            "visionOS"
        case MachOConstants.platformVisionOSSimulator:
            "visionOS Simulator"
        default:
            "platform \(platform)"
        }
    }
}

struct MachOBuildToolVersion: Hashable, Sendable {
    var tool: UInt32
    var version: MachOVersion

    var toolName: String {
        switch tool {
        case MachOConstants.buildToolClang:
            "clang"
        case MachOConstants.buildToolSwift:
            "swift"
        case MachOConstants.buildToolLD:
            "ld"
        case MachOConstants.buildToolLLD:
            "lld"
        default:
            "tool \(tool)"
        }
    }

    var displayName: String {
        "\(toolName) \(version.stringValue)"
    }
}

struct MachOMinimumOSVersion: Hashable, Sendable {
    var command: UInt32
    var minimumOSVersion: MachOVersion
    var sdkVersion: MachOVersion

    var platformName: String {
        switch command {
        case MachOConstants.loadCommandVersionMinMacOSX:
            "macOS"
        case MachOConstants.loadCommandVersionMinIPhoneOS:
            "iOS"
        case MachOConstants.loadCommandVersionMinTVOS:
            "tvOS"
        case MachOConstants.loadCommandVersionMinWatchOS:
            "watchOS"
        default:
            "unknown"
        }
    }
}

struct MachOSourceVersion: Hashable, Sendable {
    var encodedValue: UInt64
    var major: UInt64
    var minor: UInt64
    var revision: UInt64
    var stage: UInt64
    var build: UInt64

    init(encodedValue: UInt64) {
        self.encodedValue = encodedValue
        major = (encodedValue >> 40) & 0xff_ffff
        minor = (encodedValue >> 30) & 0x3ff
        revision = (encodedValue >> 20) & 0x3ff
        stage = (encodedValue >> 10) & 0x3ff
        build = encodedValue & 0x3ff
    }

    var components: [UInt64] {
        [major, minor, revision, stage, build]
    }

    var stringValue: String {
        var trimmed = components
        while trimmed.count > 2, trimmed.last == 0 {
            trimmed.removeLast()
        }
        return trimmed.map(String.init).joined(separator: ".")
    }
}

private enum MachOArchitecture {
    static func name(for cpuType: Int32) -> String {
        switch cpuType {
        case MachOConstants.cpuTypeX86_64:
            "x86_64"
        case MachOConstants.cpuTypeARM64:
            "arm64"
        default:
            "cpu(\(cpuType))"
        }
    }

    /// CPU_SUBTYPE_ARM64E_X1 (`<mach/machine.h>`); lipo/otool name it `arm64e.x1`.
    static let cpuSubtypeARM64EX1: Int32 = 12

    /// Subtype-aware name, matching lipo/otool spelling. Capability bits (the pointer-auth ABI
    /// byte) are masked off; unknown arm64 subtypes keep a visible numeric suffix.
    static func name(for cpuType: Int32, cpuSubtype: Int32) -> String {
        let subtype = cpuSubtype & ~MachOConstants.cpuSubtypeCapabilityMask
        switch (cpuType, subtype) {
        case (MachOConstants.cpuTypeARM64, 0), (MachOConstants.cpuTypeARM64, 1):
            return "arm64"
        case (MachOConstants.cpuTypeARM64, 2):
            return "arm64e"
        case (MachOConstants.cpuTypeARM64, cpuSubtypeARM64EX1):
            return "arm64e.x1"
        case (MachOConstants.cpuTypeARM64, _):
            return "arm64 (subtype \(subtype))"
        case (MachOConstants.cpuTypeX86_64, 8):
            return "x86_64h"
        default:
            return name(for: cpuType)
        }
    }
}

/// Facts retained by the existing parser, without a second image/address authority.
struct MachOLoaderFacts: Sendable {
    var declaredPlatforms: [UInt32]
    var installNames: [String]
    var dyldEnvironment: [String]
}
