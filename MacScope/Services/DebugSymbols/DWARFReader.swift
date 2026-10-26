import Foundation

/// One function-name record recovered from a dSYM's `.debug_info`: a
/// `DW_TAG_subprogram` that carried both a name (`DW_AT_name`) and a defining
/// address (`DW_AT_low_pc`). Declarations without a `low_pc` (prototypes, inlined-only
/// subprograms) are dropped — only entries with a concrete address are surfaced, since
/// the importer keys the injected name on that virtual address.
struct DWARFFunctionSymbol: Hashable, Sendable {
    /// The function's defining virtual address (`DW_AT_low_pc`, resolved through
    /// `.debug_addr` when the producer used `DW_FORM_addrx`).
    var address: UInt64
    /// The source-level function name (`DW_AT_name`, resolved through `.debug_str` /
    /// `.debug_str_offsets` depending on the form).
    var name: String
}

/// A recovered DWARF type DIE, rendered into the human-readable type spelling used
/// by `dwarfdump`-style diagnostics. `members` and `enumerators` preserve the
/// reachable graph detail for composite types even though the handoff CLI only
/// prints the top-level `name/kind/byteSize` fields.
struct DWARFType: Hashable, Sendable {
    var name: String
    var kind: String
    var byteSize: Int
    var members: [DWARFTypeMember] = []
    var enumerators: [DWARFEnumerator] = []
}

struct DWARFTypeMember: Hashable, Sendable {
    var name: String
    var typeName: String
    var byteOffset: UInt64?
}

struct DWARFEnumerator: Hashable, Sendable {
    var name: String
    var value: Int64?
}

/// A typed source local recovered from a function's DIE subtree. `role` is
/// deliberately stringly (`param`/`local`) because the standalone handoff tool
/// prints it directly. `location` is the normalized DWARF expression spelling
/// used by the package-02 handoff gates, or empty when the location is absent or
/// cannot be modeled exactly.
struct DWARFLocal: Hashable, Sendable {
    var function: String
    var name: String
    var typeName: String
    var role: String
    var location: String = ""
}

/// A file-scope global variable with a concrete static address. Package-03 only
/// surfaces globals whose `DW_AT_location` is a single `DW_OP_addr`/`DW_OP_addrx`
/// expression, matching the handoff oracle's "addressed globals only" contract.
struct DWARFGlobal: Hashable, Sendable {
    var name: String
    var typeName: String
    var address: UInt64
}

/// One half-open PC range from a DWARF v5 `.debug_loclists` location list.
/// `location` uses the package-04 normalized grammar (`regN`, `fbreg N`,
/// `bregN N`, `addr 0x...`, or `<expr>` for opaque expressions).
struct DWARFLoclistRange: Hashable, Sendable {
    var lowPC: UInt64
    var highPC: UInt64
    var location: String
}

/// A source variable or formal parameter whose `DW_AT_location` is represented
/// by a DWARF v5 location list instead of one inline expression.
struct DWARFLoclist: Hashable, Sendable {
    var name: String
    var ranges: [DWARFLoclistRange]
}

/// One half-open PC range from a DWARF v5 `.debug_rnglists` range list.
struct DWARFRnglistRange: Hashable, Sendable {
    var lowPC: UInt64
    var highPC: UInt64
}

/// A DIE whose `DW_AT_ranges` attribute resolved to one or more non-contiguous
/// address ranges. Values are emitted in DIE/document order by `recoverRnglists()`.
struct DWARFRnglist: Hashable, Sendable {
    var ranges: [DWARFRnglistRange]
}

/// A decoded `.eh_frame` Common Information Entry. The FDE records below keep
/// a copy of the CIE they were decoded against so tests and tools can verify the
/// alignment factors and initial unwind program without reparsing section state.
struct DWARFCallFrameCIE: Hashable, Sendable {
    var version: UInt8
    var augmentation: String
    var codeAlignmentFactor: UInt64
    var dataAlignmentFactor: Int64
    var returnAddressRegister: UInt64
    var fdePointerEncoding: UInt8
    var initialInstructions: [String]
}

/// One Frame Description Entry from `.eh_frame`, in section order. `operations`
/// is the normalized FDE CFA program only; CIE initial instructions are exposed
/// on `cie.initialInstructions` and are not prepended to the FDE stream because
/// the handoff oracle compares the FDE rows emitted by `dwarfdump --eh-frame`.
struct DWARFCallFrameInfo: Hashable, Sendable {
    var initialLocation: UInt64
    var rangeSize: UInt64
    var operations: [String]
    var cie: DWARFCallFrameCIE
}

/// Lossless call-frame data for clients that must distinguish partial decoding.
enum DWARFStructuredCFADecodeStatus: Hashable, Sendable {
    case complete
    case unsupported(opcode: UInt8)
    /// Section offset of the instruction whose operands could not be decoded.
    case malformed(offset: Int)
}

enum DWARFStructuredCFAOperand: Hashable, Sendable {
    case unsigned(UInt64)
    case signed(Int64)
    case block([UInt8])
}

struct DWARFStructuredCFAOperation: Hashable, Sendable {
    var sectionOffset: Int
    var opcode: UInt8
    var operands: [DWARFStructuredCFAOperand]
    var rawBytes: [UInt8]
}

struct DWARFStructuredCFAProgram: Hashable, Sendable {
    var sectionOffset: Int
    var rawBytes: [UInt8]
    var operations: [DWARFStructuredCFAOperation]
    var status: DWARFStructuredCFADecodeStatus
}

struct DWARFStructuredCIE: Hashable, Sendable {
    var sectionOffset: Int
    var version: UInt8
    var augmentation: String
    var augmentationData: [UInt8]
    var codeAlignmentFactor: UInt64
    var dataAlignmentFactor: Int64
    var returnAddressRegister: UInt64
    var fdePointerEncoding: UInt8
    var initialProgram: DWARFStructuredCFAProgram
    var lsdaPointerEncoding: UInt8? = nil
    var personalityPointer: DWARFExceptionEncodedPointer? = nil
    var exceptionMetadataRange: Range<Int>? = nil
}

struct DWARFStructuredFDE: Hashable, Sendable {
    var sectionOffset: Int
    var cieSectionOffset: Int
    var initialLocation: UInt64
    var rangeSize: UInt64
    var augmentationData: [UInt8]
    var program: DWARFStructuredCFAProgram
    var lsdaPointer: DWARFExceptionEncodedPointer? = nil
    var exceptionMetadataRange: Range<Int>? = nil
}

/// The encoded target is a slot address when indirect. Reading that slot and
/// establishing a personality identity remain the loaded image's responsibility.
struct DWARFExceptionEncodedPointer: Hashable, Sendable {
    var value: UInt64
    var encoding: UInt8
    var sectionRange: Range<Int>

    var isIndirect: Bool { encoding & 0x80 != 0 }
}

struct DWARFStructuredCallFrameTable: Hashable, Sendable {
    var cies: [DWARFStructuredCIE]
    var fdes: [DWARFStructuredFDE]
}

enum DWARFReaderError: LocalizedError, Equatable {
    case missingDebugInfo
    case missingAbbrev
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingDebugInfo:
            "The dSYM has no __DWARF,__debug_info section to read function names from."
        case .missingAbbrev:
            "The dSYM has no __DWARF,__debug_abbrev section, so its debug entries cannot be decoded."
        case .malformed(let reason):
            "The dSYM's DWARF data is malformed: \(reason)."
        }
    }
}

/// A conservative, bounds-checked reader for the slice of DWARF needed to recover
/// FUNCTION NAMES: it walks every compilation unit in `.debug_info`, decodes each
/// `DW_TAG_subprogram` against the unit's abbreviation table, and pulls `DW_AT_name`
/// + `DW_AT_low_pc`.
///
/// Scope (deliberately narrow — correctness over coverage):
///   * Only the attributes/forms that name + address a subprogram are interpreted;
///     every other form is *skipped by its known size* so the DIE cursor stays aligned.
///   * Both the classic direct forms (`DW_FORM_addr`, `DW_FORM_strp`, `DW_FORM_string`)
///     and the DWARF-5 indexed forms (`DW_FORM_addrx*` via `.debug_addr`,
///     `DW_FORM_strx*` via `.debug_str_offsets`) are handled, because modern Apple
///     clang emits the indexed forms.
///   * Type/line-table import is OUT OF SCOPE (see the import service's `remaining`).
///
/// Defensiveness: every read is range-checked; an unknown form (whose size cannot be
/// determined) aborts THAT unit cleanly rather than risking a desynced walk, and a
/// truncated structure throws `.malformed` instead of trapping.
struct DWARFReader {
    /// The raw bytes of each `__DWARF` section the reader consults, keyed by section name.
    /// Missing sections are simply absent (the reader degrades — e.g. no `.debug_addr`
    /// means `DW_FORM_addrx` cannot resolve, so those subprograms are dropped).
    struct Sections {
        var debugInfo: Data
        var debugAbbrev: Data
        var debugStr: Data
        var debugStrOffsets: Data
        var debugAddr: Data
        /// `__DWARF,__debug_line` — the line-number program (address↔source line table).
        var debugLine: Data
        /// `__DWARF,__debug_line_str` — DWARF v5 line-table string pool (file/dir names).
        var debugLineStr: Data
        /// `__DWARF,__debug_loclists` — DWARF v5 per-range location lists.
        var debugLoclists: Data
        /// `__DWARF,__debug_rnglists` — DWARF v5 non-contiguous address ranges.
        var debugRnglists: Data
        /// `__TEXT,__eh_frame` — call-frame information unwind records.
        var ehFrame: Data

        init(
            debugInfo: Data = Data(),
            debugAbbrev: Data = Data(),
            debugStr: Data = Data(),
            debugStrOffsets: Data = Data(),
            debugAddr: Data = Data(),
            debugLine: Data = Data(),
            debugLineStr: Data = Data(),
            debugLoclists: Data = Data(),
            debugRnglists: Data = Data(),
            ehFrame: Data = Data()
        ) {
            self.debugInfo = debugInfo
            self.debugAbbrev = debugAbbrev
            self.debugStr = debugStr
            self.debugStrOffsets = debugStrOffsets
            self.debugAddr = debugAddr
            self.debugLine = debugLine
            self.debugLineStr = debugLineStr
            self.debugLoclists = debugLoclists
            self.debugRnglists = debugRnglists
            self.ehFrame = ehFrame
        }
    }

    struct TypeResolutionLimits: Sendable {
        // These bounds accommodate unusually complex compiler-generated types while
        // keeping reference walks and a single displayed type spelling finite.
        var maximumReferenceDepth: Int = 256
        var maximumRenderedNameBytes: Int = 64 * 1024

        static let production = TypeResolutionLimits()
    }

    private let sections: Sections
    private let typeResolutionLimits: TypeResolutionLimits

    init(sections: Sections, typeResolutionLimits: TypeResolutionLimits = .production) {
        self.sections = sections
        self.typeResolutionLimits = typeResolutionLimits
    }

    /// Walks every compilation unit and returns the recovered function symbols, sorted
    /// by address with names deduplicated to the FIRST occurrence at a given address
    /// (a later declaration never clobbers an earlier definition).
    func recoverFunctionSymbols() throws -> [DWARFFunctionSymbol] {
        guard !sections.debugInfo.isEmpty else { throw DWARFReaderError.missingDebugInfo }
        guard !sections.debugAbbrev.isEmpty else { throw DWARFReaderError.missingAbbrev }

        let info = ByteCursor(sections.debugInfo)
        var byAddress: [UInt64: String] = [:]

        while info.remaining > 0 {
            // A compilation-unit header begins each unit; on any malformed header we stop
            // (we cannot find the next unit without a valid length), surfacing what we have.
            let unitStart = info.offset
            guard let unit = try parseCompilationUnit(info) else { break }
            // Advance past this unit regardless of how far the DIE walk got, so a single
            // odd unit never blocks the ones after it.
            defer { info.seek(to: unit.nextUnitOffset) }

            guard unitStart != unit.nextUnitOffset else { break } // zero-length guard

            do {
                try walkUnit(unit, into: &byAddress)
            } catch {
                // A malformed DIE walk in one unit is non-fatal: keep the names we got and
                // move to the next unit (the defer reseats the cursor).
                continue
            }
        }

        return byAddress
            .map { DWARFFunctionSymbol(address: $0.key, name: $0.value) }
            .sorted { $0.address < $1.address }
    }

    /// Recovers every modeled type DIE in DIE order. Type names are resolved through
    /// the CU-local reference graph, so forward references and multi-DIE chains
    /// (pointer -> const -> struct, array -> subrange, typedef -> target) are handled
    /// after the unit has been indexed.
    func recoverTypes() throws -> [DWARFType] {
        let units = try parseDIEUnits()
        var types: [DWARFType] = []

        for unit in units {
            let resolver = TypeResolver(unit: unit, limits: typeResolutionLimits)
            for node in unit.nodes {
                guard let kind = Self.typeKind(for: node.tag),
                      let name = try resolver.typeName(for: node),
                      !name.isEmpty else {
                    continue
                }

                types.append(DWARFType(
                    name: name,
                    kind: kind,
                    byteSize: try resolver.byteSize(for: node),
                    members: try resolver.members(of: node),
                    enumerators: resolver.enumerators(of: node)
                ))
            }
        }

        return types
    }

    /// Recovers named formal parameters and local variables from function definitions.
    /// Package-02 location expressions are normalized when they are simple and exact;
    /// unsupported or malformed expressions keep the package-01 local/type recovery
    /// intact by surfacing an empty location string.
    func recoverLocals() throws -> [DWARFLocal] {
        let units = try parseDIEUnits()
        var locals: [DWARFLocal] = []

        for unit in units {
            let resolver = TypeResolver(unit: unit, limits: typeResolutionLimits)
            for root in unit.roots {
                try collectLocals(under: root, resolver: resolver, into: &locals)
            }
        }

        return locals
    }

    /// Recovers file-scope globals: `DW_TAG_variable` DIEs that are direct children
    /// of the compile unit, have a name + type, and carry a concrete
    /// `DW_OP_addr`/`DW_OP_addrx` location.
    func recoverGlobals() throws -> [DWARFGlobal] {
        let units = try parseDIEUnits()
        var globals: [DWARFGlobal] = []

        for unit in units {
            let resolver = TypeResolver(unit: unit, limits: typeResolutionLimits)
            for root in unit.roots {
                try collectGlobals(atTopLevelOf: root, resolver: resolver, into: &globals)
            }
        }

        return globals
    }

    /// Recovers DWARF v5 location lists attached to named formal parameters and
    /// variables. This is intentionally separate from `recoverLocals()`, whose
    /// package-02 contract is single-expression `DW_AT_location` normalization.
    func recoverLoclists() throws -> [DWARFLoclist] {
        let units = try parseDIEUnits()
        var loclists: [DWARFLoclist] = []

        for unit in units {
            for node in unit.nodes where node.tag == DWARFConstants.tagFormalParameter ||
                node.tag == DWARFConstants.tagVariable {
                guard let name = node.attributes[DWARFConstants.atName]?.stringValue,
                      !name.isEmpty else {
                    continue
                }

                let ranges = loclistRanges(
                    from: node.attributes[DWARFConstants.atLocation],
                    unit: unit.header
                )
                if !ranges.isEmpty {
                    loclists.append(DWARFLoclist(name: name, ranges: ranges))
                }
            }
        }

        return loclists
    }

    /// Recovers DWARF v5 range lists attached to any DIE carrying `DW_AT_ranges`.
    /// The returned array preserves DIE/document order so callers can compare against
    /// `dwarfdump`'s inline range rendering without needing DIE names.
    func recoverRnglists() throws -> [DWARFRnglist] {
        let units = try parseDIEUnits()
        var rnglists: [DWARFRnglist] = []

        for unit in units {
            for node in unit.nodes {
                let ranges = rnglistRanges(
                    from: node.attributes[DWARFConstants.atRanges],
                    unit: unit.header
                )
                if !ranges.isEmpty {
                    rnglists.append(DWARFRnglist(ranges: ranges))
                }
            }
        }

        return rnglists
    }

    /// Recovers `.eh_frame` FDE unwind programs in section order. Missing or malformed
    /// CFI data is non-fatal: a malformed entry stops CFI recovery without affecting
    /// the package-01...04 DWARF readers, and an unknown `DW_CFA_*` opcode stops only
    /// the current program.
    func recoverCallFrameInfo() throws -> [DWARFCallFrameInfo] {
        guard !sections.ehFrame.isEmpty else { return [] }

        let cursor = ByteCursor(sections.ehFrame)
        var ciesByOffset: [Int: DWARFCallFrameCIE] = [:]
        var fdes: [DWARFCallFrameInfo] = []

        while cursor.remaining >= 4 {
            let entryStart = cursor.offset
            let header: EHFrameEntryHeader
            do {
                guard let parsedHeader = try readEHFrameEntryHeader(cursor) else { break }
                header = parsedHeader
            } catch {
                break
            }

            defer { cursor.seek(to: header.contentEndOffset) }
            guard header.contentEndOffset > entryStart,
                  cursor.offset + 4 <= header.contentEndOffset else {
                continue
            }

            do {
                let ciePointerFieldOffset = cursor.offset
                let ciePointer = try cursor.readU32()
                let entryPayloadBaseOffset = cursor.offset
                let entryPayload = try cursor.readBytes(header.contentEndOffset - cursor.offset)
                let entryCursor = ByteCursor(Data(entryPayload))
                if ciePointer == 0 {
                    if let cie = try readEHFrameCIE(entryCursor) {
                        ciesByOffset[entryStart] = cie
                    }
                    continue
                }

                guard UInt64(ciePointerFieldOffset) >= UInt64(ciePointer),
                      let cieOffset = Int(exactly: UInt64(ciePointerFieldOffset) - UInt64(ciePointer)),
                      let cie = ciesByOffset[cieOffset],
                      let fde = try readEHFrameFDE(
                          entryCursor,
                          cie: cie,
                          entryPayloadBaseOffset: entryPayloadBaseOffset
                      ) else {
                    continue
                }
                fdes.append(fde)
            } catch {
                continue
            }
        }

        return fdes
    }

    private struct EHFrameEntryHeader {
        var contentEndOffset: Int
    }

    private func readEHFrameEntryHeader(_ cursor: ByteCursor) throws -> EHFrameEntryHeader? {
        let initialLength = try cursor.readU32()
        if initialLength == 0 { return nil }

        let length: UInt64
        if initialLength == 0xffff_ffff {
            length = try cursor.readU64()
        } else {
            length = UInt64(initialLength)
        }

        guard length >= 4,
              length <= UInt64(Int.max),
              length <= UInt64(cursor.count - cursor.offset) else {
            throw DWARFReaderError.malformed(".eh_frame entry length runs past section")
        }

        return EHFrameEntryHeader(contentEndOffset: cursor.offset + Int(length))
    }

    private func readEHFrameCIE(
        _ cursor: ByteCursor
    ) throws -> DWARFCallFrameCIE? {
        guard cursor.remaining > 0 else { return nil }

        let version = try cursor.readU8()
        let augmentation = try cursor.readCString(limit: cursor.count)

        let codeAlignmentFactor = try cursor.readULEB128()
        let dataAlignmentFactor = try cursor.readSLEB128()
        let returnAddressRegister: UInt64
        if version == 1 {
            returnAddressRegister = UInt64(try cursor.readU8())
        } else {
            returnAddressRegister = try cursor.readULEB128()
        }

        var fdePointerEncoding = DWEHPointerEncoding.absptr
        if augmentation.hasPrefix("z") {
            let augmentationLength = try cursor.readULEB128()
            guard augmentationLength <= UInt64(Int.max),
                  augmentationLength <= UInt64(cursor.remaining) else {
                return nil
            }

            let augmentationData = try cursor.readBytes(Int(augmentationLength))
            fdePointerEncoding = readCIEAugmentation(
                augmentation,
                data: augmentationData,
                defaultFDEPointerEncoding: fdePointerEncoding
            )
        }

        let instructions = try cursor.readBytes(cursor.remaining)
        var cie = DWARFCallFrameCIE(
            version: version,
            augmentation: augmentation,
            codeAlignmentFactor: codeAlignmentFactor,
            dataAlignmentFactor: dataAlignmentFactor,
            returnAddressRegister: returnAddressRegister,
            fdePointerEncoding: fdePointerEncoding,
            initialInstructions: []
        )
        cie.initialInstructions = decodeCFAProgram(instructions, cie: cie)
        return cie
    }

    private func readCIEAugmentation(
        _ augmentation: String,
        data: [UInt8],
        defaultFDEPointerEncoding: UInt8
    ) -> UInt8 {
        let cursor = ByteCursor(Data(data))
        var fdePointerEncoding = defaultFDEPointerEncoding

        for byte in augmentation.utf8.dropFirst() {
            do {
                switch byte {
                case CharacterASCII.upperL:
                    _ = try cursor.readU8()
                case CharacterASCII.upperP:
                    let personalityEncoding = try cursor.readU8()
                    _ = try readEHEncodedPointer(
                        cursor,
                        encoding: personalityEncoding,
                        encodedFieldOffset: cursor.offset,
                        applyApplication: false
                    )
                case CharacterASCII.upperR:
                    fdePointerEncoding = try cursor.readU8()
                default:
                    cursor.seek(to: cursor.count)
                    return fdePointerEncoding
                }
            } catch {
                return fdePointerEncoding
            }
        }

        return fdePointerEncoding
    }

    private func readEHFrameFDE(
        _ cursor: ByteCursor,
        cie: DWARFCallFrameCIE,
        entryPayloadBaseOffset: Int
    ) throws -> DWARFCallFrameInfo? {
        let initialLocationFieldOffset = entryPayloadBaseOffset + cursor.offset
        guard let initialLocation = try readEHEncodedPointer(
            cursor,
            encoding: cie.fdePointerEncoding,
            encodedFieldOffset: initialLocationFieldOffset,
            applyApplication: true
        ) else {
            return nil
        }

        let rangeFieldOffset = entryPayloadBaseOffset + cursor.offset
        guard let rangeSize = try readEHEncodedPointer(
            cursor,
            encoding: cie.fdePointerEncoding,
            encodedFieldOffset: rangeFieldOffset,
            applyApplication: false
        ) else {
            return nil
        }

        if cie.augmentation.hasPrefix("z") {
            let augmentationLength = try cursor.readULEB128()
            guard augmentationLength <= UInt64(Int.max),
                  augmentationLength <= UInt64(cursor.remaining) else {
                return nil
            }
            try cursor.skip(Int(augmentationLength))
        }

        let instructions = try cursor.readBytes(cursor.remaining)
        return DWARFCallFrameInfo(
            initialLocation: initialLocation,
            rangeSize: rangeSize,
            operations: decodeCFAProgram(instructions, cie: cie),
            cie: cie
        )
    }

    private struct EHEncodedValue {
        var unsigned: UInt64
        var signed: Int64
    }

    private func readEHEncodedPointer(
        _ cursor: ByteCursor,
        encoding: UInt8,
        encodedFieldOffset: Int,
        applyApplication: Bool
    ) throws -> UInt64? {
        if encoding == DWEHPointerEncoding.omit { return nil }

        let format = encoding & DWEHPointerEncoding.formatMask
        let application = encoding & DWEHPointerEncoding.applicationMask
        if application == DWEHPointerEncoding.aligned {
            try cursor.align(to: DWEHPointerEncoding.nativePointerSize)
        }

        let value: EHEncodedValue
        switch format {
        case DWEHPointerEncoding.absptr:
            let raw = try cursor.readU64()
            value = EHEncodedValue(unsigned: raw, signed: Int64(bitPattern: raw))
        case DWEHPointerEncoding.uleb128:
            let raw = try cursor.readULEB128()
            value = EHEncodedValue(unsigned: raw, signed: Int64(bitPattern: raw))
        case DWEHPointerEncoding.udata2:
            let raw = UInt64(try cursor.readU16())
            value = EHEncodedValue(unsigned: raw, signed: Int64(raw))
        case DWEHPointerEncoding.udata4:
            let raw = UInt64(try cursor.readU32())
            value = EHEncodedValue(unsigned: raw, signed: Int64(raw))
        case DWEHPointerEncoding.udata8:
            let raw = try cursor.readU64()
            value = EHEncodedValue(unsigned: raw, signed: Int64(bitPattern: raw))
        case DWEHPointerEncoding.sleb128:
            let raw = try cursor.readSLEB128()
            value = EHEncodedValue(unsigned: UInt64(bitPattern: raw), signed: raw)
        case DWEHPointerEncoding.sdata2:
            let raw = Int64(Int16(bitPattern: try cursor.readU16()))
            value = EHEncodedValue(unsigned: UInt64(bitPattern: raw), signed: raw)
        case DWEHPointerEncoding.sdata4:
            let raw = Int64(Int32(bitPattern: try cursor.readU32()))
            value = EHEncodedValue(unsigned: UInt64(bitPattern: raw), signed: raw)
        case DWEHPointerEncoding.sdata8:
            let raw = Int64(bitPattern: try cursor.readU64())
            value = EHEncodedValue(unsigned: UInt64(bitPattern: raw), signed: raw)
        default:
            throw DWARFReaderError.malformed("unsupported .eh_frame pointer encoding 0x\(String(encoding, radix: 16))")
        }

        guard applyApplication else { return value.unsigned }
        switch application {
        case DWEHPointerEncoding.absoluteptr, DWEHPointerEncoding.aligned:
            return value.unsigned
        case DWEHPointerEncoding.pcrel:
            let (resolved, overflow) = Int64(encodedFieldOffset).addingReportingOverflow(value.signed)
            guard !overflow else { return nil }
            return UInt64(bitPattern: resolved)
        default:
            // textrel/datarel/funcrel need loader bases that this raw-section reader
            // does not have. Keep the raw value; package-05 gates range and program.
            return value.unsigned
        }
    }

    private func decodeCFAProgram(
        _ bytes: [UInt8],
        cie: DWARFCallFrameCIE
    ) -> [String] {
        let cursor = ByteCursor(Data(bytes))
        var operations: [String] = []

        do {
            while cursor.remaining > 0 {
                let opcode = try cursor.readU8()
                let primary = opcode & DWARFCFAOpcode.primaryMask
                switch primary {
                case DWARFCFAOpcode.advanceLoc:
                    let delta = UInt64(opcode & DWARFCFAOpcode.primaryOperandMask)
                    guard let advance = Self.factoredAdvance(delta, codeAlignment: cie.codeAlignmentFactor) else {
                        return operations
                    }
                    operations.append("advance \(advance)")

                case DWARFCFAOpcode.offset:
                    let register = UInt64(opcode & DWARFCFAOpcode.primaryOperandMask)
                    let factoredOffset = try cursor.readULEB128()
                    guard let offset = Self.factoredOffset(
                        factoredOffset,
                        dataAlignment: cie.dataAlignmentFactor
                    ) else {
                        return operations
                    }
                    operations.append("offset reg\(register) \(offset)")

                case DWARFCFAOpcode.restore:
                    let register = UInt64(opcode & DWARFCFAOpcode.primaryOperandMask)
                    operations.append("restore reg\(register)")

                default:
                    guard decodeExtendedCFAOpcode(
                        opcode,
                        cursor: cursor,
                        cie: cie,
                        operations: &operations
                    ) else {
                        return operations
                    }
                }
            }
        } catch {
            return operations
        }

        return operations
    }

    private func decodeExtendedCFAOpcode(
        _ opcode: UInt8,
        cursor: ByteCursor,
        cie: DWARFCallFrameCIE,
        operations: inout [String]
    ) -> Bool {
        do {
            switch opcode {
            case DWARFCFAOpcode.nop:
                operations.append("nop")
            case DWARFCFAOpcode.setLoc:
                _ = try readEHEncodedPointer(
                    cursor,
                    encoding: cie.fdePointerEncoding,
                    encodedFieldOffset: cursor.offset,
                    applyApplication: true
                )
            case DWARFCFAOpcode.advanceLoc1:
                guard let advance = Self.factoredAdvance(
                    UInt64(try cursor.readU8()),
                    codeAlignment: cie.codeAlignmentFactor
                ) else { return false }
                operations.append("advance \(advance)")
            case DWARFCFAOpcode.advanceLoc2:
                guard let advance = Self.factoredAdvance(
                    UInt64(try cursor.readU16()),
                    codeAlignment: cie.codeAlignmentFactor
                ) else { return false }
                operations.append("advance \(advance)")
            case DWARFCFAOpcode.advanceLoc4:
                guard let advance = Self.factoredAdvance(
                    UInt64(try cursor.readU32()),
                    codeAlignment: cie.codeAlignmentFactor
                ) else { return false }
                operations.append("advance \(advance)")
            case DWARFCFAOpcode.offsetExtended:
                let register = try cursor.readULEB128()
                let factoredOffset = try cursor.readULEB128()
                guard let offset = Self.factoredOffset(
                    factoredOffset,
                    dataAlignment: cie.dataAlignmentFactor
                ) else { return false }
                operations.append("offset reg\(register) \(offset)")
            case DWARFCFAOpcode.restoreExtended:
                operations.append("restore reg\(try cursor.readULEB128())")
            case DWARFCFAOpcode.undefined:
                operations.append("undefined reg\(try cursor.readULEB128())")
            case DWARFCFAOpcode.sameValue:
                operations.append("same_value reg\(try cursor.readULEB128())")
            case DWARFCFAOpcode.register:
                _ = try cursor.readULEB128()
                _ = try cursor.readULEB128()
            case DWARFCFAOpcode.rememberState:
                operations.append("remember_state")
            case DWARFCFAOpcode.restoreState:
                operations.append("restore_state")
            case DWARFCFAOpcode.defCFA:
                let register = try cursor.readULEB128()
                let offset = try cursor.readULEB128()
                operations.append("def_cfa reg\(register) \(offset)")
            case DWARFCFAOpcode.defCFARegister:
                operations.append("def_cfa_register reg\(try cursor.readULEB128())")
            case DWARFCFAOpcode.defCFAOffset:
                operations.append("def_cfa_offset \(try cursor.readULEB128())")
            case DWARFCFAOpcode.defCFAExpression:
                guard skipCFABlock(cursor) else { return false }
            case DWARFCFAOpcode.expression:
                _ = try cursor.readULEB128()
                guard skipCFABlock(cursor) else { return false }
            case DWARFCFAOpcode.offsetExtendedSF:
                let register = try cursor.readULEB128()
                let factoredOffset = try cursor.readSLEB128()
                guard let offset = Self.factoredSignedOffset(
                    factoredOffset,
                    dataAlignment: cie.dataAlignmentFactor
                ) else { return false }
                operations.append("offset reg\(register) \(offset)")
            case DWARFCFAOpcode.defCFASF:
                let register = try cursor.readULEB128()
                let factoredOffset = try cursor.readSLEB128()
                guard let offset = Self.factoredSignedOffset(
                    factoredOffset,
                    dataAlignment: cie.dataAlignmentFactor
                ) else { return false }
                operations.append("def_cfa reg\(register) \(offset)")
            case DWARFCFAOpcode.defCFAOffsetSF:
                let factoredOffset = try cursor.readSLEB128()
                guard let offset = Self.factoredSignedOffset(
                    factoredOffset,
                    dataAlignment: cie.dataAlignmentFactor
                ) else { return false }
                operations.append("def_cfa_offset \(offset)")
            case DWARFCFAOpcode.valOffset:
                _ = try cursor.readULEB128()
                _ = try cursor.readULEB128()
            case DWARFCFAOpcode.valOffsetSF:
                _ = try cursor.readULEB128()
                _ = try cursor.readSLEB128()
            case DWARFCFAOpcode.valExpression:
                _ = try cursor.readULEB128()
                guard skipCFABlock(cursor) else { return false }
            default:
                return false
            }
        } catch {
            return false
        }

        return true
    }

    private func skipCFABlock(_ cursor: ByteCursor) -> Bool {
        do {
            let length = try cursor.readULEB128()
            guard length <= UInt64(Int.max) else { return false }
            try cursor.skip(Int(length))
            return true
        } catch {
            return false
        }
    }

    private static func factoredAdvance(_ delta: UInt64, codeAlignment: UInt64) -> UInt64? {
        let (advance, overflow) = delta.multipliedReportingOverflow(by: codeAlignment)
        return overflow ? nil : advance
    }

    private static func factoredOffset(_ factoredOffset: UInt64, dataAlignment: Int64) -> Int64? {
        guard let signed = Int64(exactly: factoredOffset) else { return nil }
        return factoredSignedOffset(signed, dataAlignment: dataAlignment)
    }

    private static func factoredSignedOffset(_ factoredOffset: Int64, dataAlignment: Int64) -> Int64? {
        let (offset, overflow) = factoredOffset.multipliedReportingOverflow(by: dataAlignment)
        return overflow ? nil : offset
    }

    // MARK: - Compilation unit

    private struct CompilationUnit {
        var version: UInt16
        var addressSize: UInt8
        var offsetSize: UInt8
        var abbrevOffset: UInt64
        /// Offset in `.debug_info` of the CU header's first byte.
        var unitStartOffset: Int
        /// Offset in `.debug_info` of the first DIE (just past this header).
        var firstDIEOffset: Int
        /// Offset in `.debug_info` where this unit ends (start of the next unit).
        var nextUnitOffset: Int
        /// `DW_AT_str_offsets_base` for `DW_FORM_strx` resolution (defaults to the
        /// post-header position, 8, for the single-CU dSYMs this targets).
        var strOffsetsBase: UInt64
        /// `DW_AT_addr_base` for `DW_FORM_addrx` resolution (defaults to 8).
        var addrBase: UInt64
        /// `DW_AT_loclists_base` for `DW_FORM_loclistx` resolution.
        var loclistsBase: UInt64
        /// `DW_AT_rnglists_base` for `DW_FORM_rnglistx` resolution.
        var rnglistsBase: UInt64
        /// Initial range address base from the root DIE's `DW_AT_low_pc`.
        /// Preserve the existing zero-base compatibility when that attribute is
        /// absent; an unresolved indexed address is unknown, not address zero.
        var rangeBaseAddress: UInt64? = 0
    }

    /// Parses one CU header (DWARF v2–v5; the v5 layout reorders unit_type before
    /// addr_size). Returns nil only when there are not even enough bytes for a length.
    private func parseCompilationUnit(_ cursor: ByteCursor) throws -> CompilationUnit? {
        guard cursor.remaining >= 4 else { return nil }
        let headerStart = cursor.offset
        let initialLength = try cursor.readU32()
        // 64-bit DWARF (0xffffffff escape) is not produced by Apple's toolchain for these
        // unit sizes; reject it explicitly rather than mis-reading a 32-bit length.
        guard initialLength != 0xffff_ffff else {
            throw DWARFReaderError.malformed("64-bit DWARF unit length is unsupported")
        }
        let unitLength = Int(initialLength)
        // The length counts bytes AFTER the length field itself.
        let nextUnitOffset = cursor.offset + unitLength
        guard unitLength > 0, nextUnitOffset <= cursor.count else {
            throw DWARFReaderError.malformed("compilation unit length runs past .debug_info")
        }

        let version = try cursor.readU16()
        let addressSize: UInt8
        let abbrevOffset: UInt64
        if version >= 5 {
            // v5: version, unit_type (u8), address_size (u8), debug_abbrev_offset (u32).
            _ = try cursor.readU8() // unit_type
            addressSize = try cursor.readU8()
            abbrevOffset = UInt64(try cursor.readU32())
        } else {
            // v2–v4: version, debug_abbrev_offset (u32), address_size (u8).
            abbrevOffset = UInt64(try cursor.readU32())
            addressSize = try cursor.readU8()
        }

        guard addressSize == 4 || addressSize == 8 else {
            throw DWARFReaderError.malformed("unsupported address size \(addressSize)")
        }

        _ = headerStart
        return CompilationUnit(
            version: version,
            addressSize: addressSize,
            offsetSize: 4,
            abbrevOffset: abbrevOffset,
            unitStartOffset: headerStart,
            firstDIEOffset: cursor.offset,
            nextUnitOffset: nextUnitOffset,
            // Apple single-CU dSYMs place the str-offsets/addr arrays right after their
            // 8-byte section headers; the per-CU base attributes (read below) refine this.
            strOffsetsBase: 8,
            addrBase: 8,
            loclistsBase: 0,
            rnglistsBase: 0
        )
    }

    // MARK: - DIE walk

    /// Walks the DIE tree of `unit`, decoding abbreviations lazily and collecting every
    /// subprogram's name+address. The root DIE's `str_offsets_base`/`addr_base` (when
    /// present) refine the unit's resolution bases before any subprogram is read — the
    /// root always precedes its children, so the bases are set before they are needed.
    private func walkUnit(_ unit: CompilationUnit, into byAddress: inout [UInt64: String]) throws {
        let abbrevTable = try parseAbbrevTable(at: unit.abbrevOffset)
        var unit = unit

        let info = ByteCursor(sections.debugInfo, endOffset: unit.nextUnitOffset)
        info.seek(to: unit.firstDIEOffset)

        // The walk does not need to track sibling/child nesting to find subprograms: every
        // DIE is visited linearly, and a null abbrev code (0) marks an end-of-children that
        // we simply skip. This is sufficient because we extract per-DIE attributes only.
        var guardCounter = 0
        let maxDIEs = sections.debugInfo.count + 1 // a hard cap; one DIE is at least 1 byte
        while info.offset < unit.nextUnitOffset {
            guardCounter += 1
            if guardCounter > maxDIEs {
                throw DWARFReaderError.malformed("DIE walk exceeded the entry-count cap")
            }
            let code = try info.readULEB128()
            if code == 0 { continue } // end-of-children sentinel
            guard let abbrev = abbrevTable[code] else {
                // Unknown abbrev code: we cannot know the attribute sizes, so we cannot
                // keep the cursor aligned — abort this unit's walk cleanly.
                throw DWARFReaderError.malformed("DIE references undefined abbreviation code \(code)")
            }

            var name: String?
            var lowPC: UInt64?
            var sawLowPCAddrx = false

            for attribute in abbrev.attributes {
                let value = try readAttributeValue(
                    attribute,
                    cursor: info,
                    unit: &unit
                )
                switch attribute.attribute {
                case DWARFConstants.atName:
                    if case let .string(text) = value { name = text }
                case DWARFConstants.atLowPC:
                    switch value {
                    case let .address(addr):
                        lowPC = addr
                    case let .addrIndex(index):
                        lowPC = resolveAddress(index: index, base: unit.addrBase)
                        sawLowPCAddrx = true
                    default:
                        break
                    }
                case DWARFConstants.atStrOffsetsBase:
                    if let base = Self.unsignedValue(value) { unit.strOffsetsBase = base }
                case DWARFConstants.atAddrBase:
                    if let base = Self.unsignedValue(value) { unit.addrBase = base }
                case DWARFConstants.atLoclistsBase:
                    if let base = Self.unsignedValue(value) { unit.loclistsBase = base }
                case DWARFConstants.atRnglistsBase:
                    if let base = Self.unsignedValue(value) { unit.rnglistsBase = base }
                default:
                    break
                }
            }

            // Only emit a subprogram that both NAMES and ADDRESSES a function. A DW_FORM_addrx
            // that could not be resolved (missing/short .debug_addr) leaves lowPC nil and is
            // dropped — we never inject a name at a bogus address.
            if abbrev.tag == DWARFConstants.tagSubprogram,
               let name, !name.isEmpty,
               let lowPC {
                _ = sawLowPCAddrx
                // First definition wins; later declarations at the same address don't clobber.
                if byAddress[lowPC] == nil {
                    byAddress[lowPC] = name
                }
            }
        }
    }

    // MARK: - Reusable DIE tree/type recovery

    private final class ParsedDIE {
        var tag: UInt64
        var attributes: [UInt64: AttributeValue]
        var cuOffset: Int
        var absoluteOffset: Int
        weak var parent: ParsedDIE?
        var children: [ParsedDIE]

        init(
            tag: UInt64,
            attributes: [UInt64: AttributeValue],
            cuOffset: Int,
            absoluteOffset: Int,
            children: [ParsedDIE] = []
        ) {
            self.tag = tag
            self.attributes = attributes
            self.cuOffset = cuOffset
            self.absoluteOffset = absoluteOffset
            self.children = children
        }
    }

    private struct ParsedDIEUnit {
        var header: CompilationUnit
        var roots: [ParsedDIE]
        var nodes: [ParsedDIE]
        var cuOffsetMap: [Int: ParsedDIE]
        var absoluteOffsetMap: [Int: ParsedDIE]
    }

    private func parseDIEUnits() throws -> [ParsedDIEUnit] {
        guard !sections.debugInfo.isEmpty else { throw DWARFReaderError.missingDebugInfo }
        guard !sections.debugAbbrev.isEmpty else { throw DWARFReaderError.missingAbbrev }

        let info = ByteCursor(sections.debugInfo)
        var units: [ParsedDIEUnit] = []

        while info.remaining > 0 {
            let unitStart = info.offset
            guard let unit = try parseCompilationUnit(info) else { break }
            defer { info.seek(to: unit.nextUnitOffset) }

            guard unitStart != unit.nextUnitOffset else { break }
            do {
                units.append(try parseDIEUnit(unit))
            } catch {
                continue
            }
        }

        return units
    }

    private func parseDIEUnit(_ initialUnit: CompilationUnit) throws -> ParsedDIEUnit {
        let abbrevTable = try parseAbbrevTable(at: initialUnit.abbrevOffset)
        var unit = initialUnit
        let info = ByteCursor(sections.debugInfo, endOffset: unit.nextUnitOffset)
        info.seek(to: unit.firstDIEOffset)

        var roots: [ParsedDIE] = []
        var stack: [ParsedDIE] = []
        var nodes: [ParsedDIE] = []
        var cuOffsetMap: [Int: ParsedDIE] = [:]
        var absoluteOffsetMap: [Int: ParsedDIE] = [:]
        var guardCounter = 0
        let maxDIEs = sections.debugInfo.count + 1

        while info.offset < unit.nextUnitOffset {
            guardCounter += 1
            if guardCounter > maxDIEs {
                throw DWARFReaderError.malformed("DIE tree walk exceeded the entry-count cap")
            }

            let absoluteOffset = info.offset
            let cuOffset = absoluteOffset - unit.unitStartOffset
            let code = try info.readULEB128()
            if code == 0 {
                if !stack.isEmpty {
                    _ = stack.removeLast()
                }
                continue
            }

            guard let abbrev = abbrevTable[code] else {
                throw DWARFReaderError.malformed("DIE references undefined abbreviation code \(code)")
            }

            var attributes: [UInt64: AttributeValue] = [:]
            for attribute in abbrev.attributes {
                let value = try readAttributeValue(attribute, cursor: info, unit: &unit)
                if attribute.attribute == DWARFConstants.atStrOffsetsBase,
                   let base = Self.unsignedValue(value) {
                    unit.strOffsetsBase = base
                } else if attribute.attribute == DWARFConstants.atAddrBase,
                          let base = Self.unsignedValue(value) {
                    unit.addrBase = base
                } else if attribute.attribute == DWARFConstants.atLoclistsBase,
                          let base = Self.unsignedValue(value) {
                    unit.loclistsBase = base
                } else if attribute.attribute == DWARFConstants.atRnglistsBase,
                          let base = Self.unsignedValue(value) {
                    unit.rnglistsBase = base
                }

                if !value.isSkipped {
                    attributes[attribute.attribute] = value
                }
            }

            // Resolve the root address only after all its attributes have been
            // read: DW_AT_addr_base may follow an indexed DW_AT_low_pc.
            // A child DIE's low_pc must not replace the compilation-unit base.
            if absoluteOffset == unit.firstDIEOffset {
                switch attributes[DWARFConstants.atLowPC] {
                case .address(let address):
                    unit.rangeBaseAddress = address
                case .addrIndex(let index):
                    unit.rangeBaseAddress = resolveAddress(index: index, base: unit.addrBase,
                                                           addressSize: unit.addressSize)
                default:
                    break
                }
            }

            let node = ParsedDIE(
                tag: abbrev.tag,
                attributes: attributes,
                cuOffset: cuOffset,
                absoluteOffset: absoluteOffset
            )
            nodes.append(node)
            cuOffsetMap[cuOffset] = node
            absoluteOffsetMap[absoluteOffset] = node

            if let parent = stack.last {
                node.parent = parent
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            if abbrev.hasChildren {
                stack.append(node)
            }
        }

        return ParsedDIEUnit(
            header: unit,
            roots: roots,
            nodes: nodes,
            cuOffsetMap: cuOffsetMap,
            absoluteOffsetMap: absoluteOffsetMap
        )
    }

    private func collectLocals(
        under node: ParsedDIE,
        resolver: TypeResolver,
        into locals: inout [DWARFLocal]
    ) throws {
        if node.tag == DWARFConstants.tagSubprogram,
           node.attributes[DWARFConstants.atLowPC]?.addressLikeValue != nil,
           let functionName = node.attributes[DWARFConstants.atName]?.stringValue,
           !functionName.isEmpty {
            try collectLocals(inFunction: node, named: functionName, resolver: resolver, into: &locals)
            return
        }

        for child in node.children {
            try collectLocals(under: child, resolver: resolver, into: &locals)
        }
    }

    private func collectLocals(
        inFunction function: ParsedDIE,
        named functionName: String,
        resolver: TypeResolver,
        into locals: inout [DWARFLocal]
    ) throws {
        for child in function.children {
            switch child.tag {
            case DWARFConstants.tagFormalParameter, DWARFConstants.tagVariable:
                guard let localName = child.attributes[DWARFConstants.atName]?.stringValue,
                      !localName.isEmpty,
                      let typeName = try resolver.typeName(for: child.attributes[DWARFConstants.atType]),
                      !typeName.isEmpty else {
                    continue
                }
                locals.append(DWARFLocal(
                    function: functionName,
                    name: localName,
                    typeName: typeName,
                    role: child.tag == DWARFConstants.tagFormalParameter ? "param" : "local",
                    location: normalizedLocation(
                        from: child.attributes[DWARFConstants.atLocation],
                        unit: resolver.unit.header
                    )
                ))
            case DWARFConstants.tagSubprogram:
                continue
            default:
                try collectLocals(inFunction: child, named: functionName, resolver: resolver, into: &locals)
            }
        }
    }

    private func collectGlobals(
        atTopLevelOf root: ParsedDIE,
        resolver: TypeResolver,
        into globals: inout [DWARFGlobal]
    ) throws {
        let candidates = root.tag == DWARFConstants.tagCompileUnit ? root.children : [root]
        for node in candidates where node.tag == DWARFConstants.tagVariable {
            guard let name = node.attributes[DWARFConstants.atName]?.stringValue,
                  !name.isEmpty,
                  let typeName = try resolver.typeName(for: node.attributes[DWARFConstants.atType]),
                  !typeName.isEmpty,
                  let address = addressLocation(
                      from: node.attributes[DWARFConstants.atLocation],
                      unit: resolver.unit.header
                  ) else {
                continue
            }

            globals.append(DWARFGlobal(name: name, typeName: typeName, address: address))
        }
    }

    private struct TypeResolver {
        var unit: ParsedDIEUnit
        var limits: TypeResolutionLimits

        func typeName(for value: AttributeValue?) throws -> String? {
            guard let node = referencedDIE(from: value) else { return nil }
            return try typeName(for: node)
        }

        func typeName(for node: ParsedDIE) throws -> String? {
            var visited: Set<Int> = []
            return try typeName(for: node, visited: &visited)
        }

        func members(of node: ParsedDIE) throws -> [DWARFTypeMember] {
            guard node.tag == DWARFConstants.tagStructureType ||
                    node.tag == DWARFConstants.tagUnionType ||
                    node.tag == DWARFConstants.tagClassType else {
                return []
            }

            return try node.children.compactMap { child in
                guard child.tag == DWARFConstants.tagMember,
                      let name = child.attributes[DWARFConstants.atName]?.stringValue,
                      !name.isEmpty,
                      let typeName = try typeName(for: child.attributes[DWARFConstants.atType]) else {
                    return nil
                }
                return DWARFTypeMember(
                    name: name,
                    typeName: typeName,
                    byteOffset: child.attributes[DWARFConstants.atDataMemberLocation]?.unsignedValue
                )
            }
        }

        func enumerators(of node: ParsedDIE) -> [DWARFEnumerator] {
            guard node.tag == DWARFConstants.tagEnumerationType else { return [] }
            return node.children.compactMap { child in
                guard child.tag == DWARFConstants.tagEnumerator,
                      let name = child.attributes[DWARFConstants.atName]?.stringValue,
                      !name.isEmpty else {
                    return nil
                }
                return DWARFEnumerator(
                    name: name,
                    value: child.attributes[DWARFConstants.atConstValue]?.signedValue
                )
            }
        }

        private func typeName(
            for node: ParsedDIE,
            visited: inout Set<Int>,
            functionPointer: Bool = false
        ) throws -> String? {
            guard !visited.contains(node.absoluteOffset) else { return nil }
            guard visited.count < limits.maximumReferenceDepth else {
                throw DWARFReaderError.malformed("type reference depth limit exceeded")
            }
            visited.insert(node.absoluteOffset)
            defer { visited.remove(node.absoluteOffset) }

            switch node.tag {
            case DWARFConstants.tagBaseType, DWARFConstants.tagTypedef:
                guard let name = nonEmptyName(of: node) else { return nil }
                return try joinedName([name])
            case DWARFConstants.tagStructureType, DWARFConstants.tagClassType,
                 DWARFConstants.tagUnionType, DWARFConstants.tagEnumerationType:
                if let name = nonEmptyName(of: node) { return try joinedName([name]) }
                return try anonymousCompositeName(Self.anonymousKind(for: node.tag), node: node)
            case DWARFConstants.tagPointerType:
                guard let pointee = referencedDIE(from: node.attributes[DWARFConstants.atType]) else {
                    return try joinedName(["void *"])
                }
                if pointee.tag == DWARFConstants.tagSubroutineType {
                    return try typeName(for: pointee, visited: &visited, functionPointer: true)
                }
                guard let name = try typeName(for: pointee, visited: &visited) else { return nil }
                return try joinedName([name, " *"])
            case DWARFConstants.tagConstType, DWARFConstants.tagVolatileType,
                 DWARFConstants.tagRestrictType:
                guard let base = referencedDIE(from: node.attributes[DWARFConstants.atType]),
                      let name = try typeName(for: base, visited: &visited) else { return nil }
                let keyword = node.tag == DWARFConstants.tagConstType ? "const"
                    : (node.tag == DWARFConstants.tagVolatileType ? "volatile" : "restrict")
                return try joinedName([keyword, " ", name])
            case DWARFConstants.tagArrayType:
                guard let element = referencedDIE(from: node.attributes[DWARFConstants.atType]),
                      var name = try typeName(for: element, visited: &visited) else { return nil }
                var hasSubrange = false
                for child in node.children where child.tag == DWARFConstants.tagSubrangeType {
                    hasSubrange = true
                    let dimension = arrayCount(of: child).map { "[\($0)]" } ?? "[]"
                    name = try joinedName([name, dimension])
                }
                if hasSubrange { return name }
                return try joinedName([name, "[]"])
            case DWARFConstants.tagSubroutineType:
                let returnType: String
                if let target = referencedDIE(from: node.attributes[DWARFConstants.atType]) {
                    returnType = try typeName(for: target, visited: &visited) ?? "void"
                } else {
                    returnType = "void"
                }
                var name = try joinedName([returnType, functionPointer ? " (*)(" : " ("])
                var hasParameter = false
                for parameter in node.children where parameter.tag == DWARFConstants.tagFormalParameter {
                    guard let target = referencedDIE(from: parameter.attributes[DWARFConstants.atType]),
                          let parameterName = try typeName(for: target, visited: &visited) else { continue }
                    name = try joinedName([name, hasParameter ? ", " : "", parameterName])
                    hasParameter = true
                }
                return try joinedName([name, ")"])
            default:
                return nil
            }
        }

        // Check each component before allocating the combined spelling. The byte
        // limit applies to UTF-8, including multi-byte source identifiers.
        private func joinedName(_ components: [String]) throws -> String {
            var remaining = limits.maximumRenderedNameBytes
            for component in components {
                let count = component.utf8.count
                guard count <= remaining else {
                    throw DWARFReaderError.malformed("rendered type name byte limit exceeded")
                }
                remaining -= count
            }
            return components.joined()
        }

        func byteSize(for node: ParsedDIE) throws -> Int {
            var current = node
            var visited: Set<Int> = []
            var arrayMultiplier = 1
            while true {
                guard !visited.contains(current.absoluteOffset) else { return 0 }
                guard visited.count < limits.maximumReferenceDepth else {
                    throw DWARFReaderError.malformed("type reference depth limit exceeded")
                }
                visited.insert(current.absoluteOffset)
                if let direct = current.attributes[DWARFConstants.atByteSize]?.unsignedValue,
                   let size = Int(exactly: direct) {
                    let (total, overflow) = size.multipliedReportingOverflow(by: arrayMultiplier)
                    return overflow ? 0 : total
                }
                switch current.tag {
                case DWARFConstants.tagPointerType:
                    let (total, overflow) = Int(unit.header.addressSize)
                        .multipliedReportingOverflow(by: arrayMultiplier)
                    return overflow ? 0 : total
                case DWARFConstants.tagTypedef, DWARFConstants.tagConstType,
                     DWARFConstants.tagVolatileType, DWARFConstants.tagRestrictType,
                     DWARFConstants.tagEnumerationType:
                    break
                case DWARFConstants.tagArrayType:
                    for child in current.children where child.tag == DWARFConstants.tagSubrangeType {
                        guard let count = arrayCount(of: child), let intCount = Int(exactly: count) else {
                            return 0
                        }
                        let (product, overflow) = arrayMultiplier.multipliedReportingOverflow(by: intCount)
                        guard !overflow else { return 0 }
                        arrayMultiplier = product
                    }
                default:
                    return 0
                }
                guard let target = referencedDIE(from: current.attributes[DWARFConstants.atType]) else {
                    return 0
                }
                current = target
            }
        }

        private func referencedDIE(from value: AttributeValue?) -> ParsedDIE? {
            guard let value else { return nil }
            switch value {
            case .uint(let offset):
                guard let intOffset = Int(exactly: offset) else { return nil }
                return unit.cuOffsetMap[intOffset] ?? unit.absoluteOffsetMap[intOffset]
            case .debugInfoOffset(let offset):
                guard let intOffset = Int(exactly: offset) else { return nil }
                return unit.absoluteOffsetMap[intOffset] ?? unit.cuOffsetMap[intOffset]
            default:
                return nil
            }
        }

        private func nonEmptyName(of node: ParsedDIE) -> String? {
            guard let name = node.attributes[DWARFConstants.atName]?.stringValue,
                  !name.isEmpty else {
                return nil
            }
            return name
        }

        private func anonymousCompositeName(_ kind: String, node: ParsedDIE) throws -> String {
            var name = "\(kind) "
            var hasQualifier = false
            var parent = node.parent
            var depth = 1
            while let current = parent {
                guard depth < limits.maximumReferenceDepth else {
                    throw DWARFReaderError.malformed("type reference depth limit exceeded")
                }
                depth += 1
                if current.tag == DWARFConstants.tagStructureType ||
                    current.tag == DWARFConstants.tagClassType ||
                    current.tag == DWARFConstants.tagUnionType ||
                    current.tag == DWARFConstants.tagEnumerationType {
                    let qualifier = nonEmptyName(of: current) ?? "\(Self.anonymousKind(for: current.tag)) "
                    name = try joinedName([qualifier, "::", name])
                    hasQualifier = true
                }
                parent = current.parent
            }
            return try joinedName([name, hasQualifier ? "" : "<anonymous>"])
        }

        private static func anonymousKind(for tag: UInt64) -> String {
            switch tag {
            case DWARFConstants.tagStructureType: return "structure"
            case DWARFConstants.tagClassType: return "class"
            case DWARFConstants.tagUnionType: return "union"
            case DWARFConstants.tagEnumerationType: return "enum"
            default: return "type"
            }
        }

        private func arrayCount(of subrange: ParsedDIE) -> UInt64? {
            if let count = subrange.attributes[DWARFConstants.atCount]?.unsignedValue {
                return count
            }
            if let upper = subrange.attributes[DWARFConstants.atUpperBound]?.unsignedValue {
                let (count, overflow) = upper.addingReportingOverflow(1)
                return overflow ? nil : count
            }
            return nil
        }
    }

    private static func typeKind(for tag: UInt64) -> String? {
        switch tag {
        case DWARFConstants.tagBaseType: return "base"
        case DWARFConstants.tagPointerType: return "pointer"
        case DWARFConstants.tagStructureType, DWARFConstants.tagClassType: return "struct"
        case DWARFConstants.tagUnionType: return "union"
        case DWARFConstants.tagEnumerationType: return "enum"
        case DWARFConstants.tagTypedef: return "typedef"
        case DWARFConstants.tagArrayType: return "array"
        case DWARFConstants.tagConstType: return "const"
        case DWARFConstants.tagVolatileType: return "volatile"
        case DWARFConstants.tagRestrictType: return "restrict"
        default: return nil
        }
    }

    private static func unsignedValue(_ value: AttributeValue) -> UInt64? {
        value.unsignedValue
    }

    private func normalizedLocation(from value: AttributeValue?, unit: CompilationUnit) -> String {
        guard case let .exprloc(bytes) = value else { return "" }
        let evaluator = DWARFLocationExpressionEvaluator(addressSize: unit.addressSize) { index in
            resolveAddress(index: index, base: unit.addrBase)
        }
        return evaluator.normalizedLocation(from: bytes)
    }

    private func addressLocation(from value: AttributeValue?, unit: CompilationUnit) -> UInt64? {
        guard case let .exprloc(bytes) = value else { return nil }
        let evaluator = DWARFLocationExpressionEvaluator(addressSize: unit.addressSize) { index in
            resolveAddress(index: index, base: unit.addrBase)
        }
        return evaluator.resolvedAddress(from: bytes)
    }

    private func loclistRanges(from value: AttributeValue?, unit: CompilationUnit) -> [DWARFLoclistRange] {
        guard !sections.debugLoclists.isEmpty else { return [] }

        switch value {
        case .loclistIndex(let index):
            guard let offset = resolveLoclistOffset(index: index, unit: unit) else { return [] }
            return decodeLoclist(at: offset, unit: unit)
        case .loclistOffset(let offset):
            return decodeLoclist(at: offset, unit: unit)
        default:
            return []
        }
    }

    private struct LoclistsTable {
        var offsetTableStart: Int
        var endOffset: Int
        var addressSize: UInt8
        var offsets: [UInt64]
    }

    private func resolveLoclistOffset(index: UInt64, unit: CompilationUnit) -> UInt64? {
        guard let table = loclistsTable(forBase: unit.loclistsBase),
              let intIndex = Int(exactly: index),
              table.offsets.indices.contains(intIndex) else {
            return nil
        }

        let offsetTableStart = UInt64(table.offsetTableStart)
        let (absoluteOffset, overflow) = offsetTableStart.addingReportingOverflow(table.offsets[intIndex])
        guard !overflow, absoluteOffset <= UInt64(sections.debugLoclists.count) else { return nil }
        return absoluteOffset
    }

    private func loclistsTable(forBase base: UInt64) -> LoclistsTable? {
        guard let tables = try? parseLoclistsTables(), !tables.isEmpty else { return nil }
        if let exact = tables.first(where: { UInt64($0.offsetTableStart) == base }) {
            return exact
        }
        return tables.first
    }

    private func loclistsTable(containing offset: UInt64) -> LoclistsTable? {
        guard let tables = try? parseLoclistsTables(),
              let intOffset = Int(exactly: offset) else {
            return nil
        }
        return tables.first { intOffset >= $0.offsetTableStart && intOffset < $0.endOffset }
    }

    private func parseLoclistsTables() throws -> [LoclistsTable] {
        let cursor = ByteCursor(sections.debugLoclists)
        var tables: [LoclistsTable] = []

        while cursor.remaining >= 4 {
            let initialOffset = cursor.offset
            let initialLength = try cursor.readU32()
            let offsetSize: Int
            let unitLength: UInt64
            if initialLength == 0xffff_ffff {
                offsetSize = 8
                unitLength = try cursor.readU64()
            } else {
                offsetSize = 4
                unitLength = UInt64(initialLength)
            }

            let contentStart = cursor.offset
            guard unitLength > 0,
                  unitLength <= UInt64(cursor.count - contentStart) else {
                break
            }
            let nextOffset = contentStart + Int(unitLength)
            guard nextOffset > contentStart, nextOffset <= cursor.count else { break }

            let version = try cursor.readU16()
            let addressSize = try cursor.readU8()
            let segmentSelectorSize = try cursor.readU8()
            let offsetEntryCount = try cursor.readU32()
            guard version == 5,
                  (addressSize == 4 || addressSize == 8),
                  segmentSelectorSize == 0 else {
                cursor.seek(to: nextOffset)
                continue
            }

            let offsetTableStart = cursor.offset
            var offsets: [UInt64] = []
            for _ in 0..<Int(offsetEntryCount) {
                guard cursor.offset + offsetSize <= nextOffset else {
                    throw DWARFReaderError.malformed("loclists offset table runs past unit")
                }
                offsets.append(offsetSize == 8 ? try cursor.readU64() : UInt64(try cursor.readU32()))
            }

            _ = initialOffset
            tables.append(LoclistsTable(
                offsetTableStart: offsetTableStart,
                endOffset: nextOffset,
                addressSize: addressSize,
                offsets: offsets
            ))
            cursor.seek(to: nextOffset)
        }

        return tables
    }

    private func decodeLoclist(at offset: UInt64, unit: CompilationUnit) -> [DWARFLoclistRange] {
        guard let startOffset = Int(exactly: offset),
              startOffset >= 0,
              startOffset < sections.debugLoclists.count else {
            return []
        }

        let table = loclistsTable(containing: offset)
        let addressSize = table?.addressSize ?? unit.addressSize
        let limit = table?.endOffset ?? sections.debugLoclists.count
        guard startOffset < limit else { return [] }

        let cursor = ByteCursor(sections.debugLoclists)
        cursor.seek(to: startOffset)
        var ranges: [DWARFLoclistRange] = []
        var baseAddress: UInt64?

        while cursor.offset < limit {
            do {
                let kind = try cursor.readU8()
                switch kind {
                case DWARFLoclistEntry.endOfList:
                    return ranges

                case DWARFLoclistEntry.baseAddressx:
                    let index = try cursor.readULEB128()
                    baseAddress = resolveAddress(index: index, base: unit.addrBase)

                case DWARFLoclistEntry.startxEndx:
                    let startIndex = try cursor.readULEB128()
                    let endIndex = try cursor.readULEB128()
                    guard let expression = try readLoclistExpression(cursor, limit: limit) else {
                        return ranges
                    }
                    if let lo = resolveAddress(index: startIndex, base: unit.addrBase),
                       let hi = resolveAddress(index: endIndex, base: unit.addrBase) {
                        appendLoclistRange(lo: lo, hi: hi, expression: expression, unit: unit, to: &ranges)
                    }

                case DWARFLoclistEntry.startxLength:
                    let startIndex = try cursor.readULEB128()
                    let length = try cursor.readULEB128()
                    guard let expression = try readLoclistExpression(cursor, limit: limit) else {
                        return ranges
                    }
                    if let lo = resolveAddress(index: startIndex, base: unit.addrBase) {
                        let (hi, overflow) = lo.addingReportingOverflow(length)
                        if !overflow {
                            appendLoclistRange(lo: lo, hi: hi, expression: expression, unit: unit, to: &ranges)
                        }
                    }

                case DWARFLoclistEntry.offsetPair:
                    let start = try cursor.readULEB128()
                    let end = try cursor.readULEB128()
                    guard let expression = try readLoclistExpression(cursor, limit: limit) else {
                        return ranges
                    }
                    // Package 04 and Apple's dwarfdump render offset-pair ranges as
                    // function-relative offsets, so keep the raw pair instead of base-adding.
                    _ = baseAddress
                    appendLoclistRange(lo: start, hi: end, expression: expression, unit: unit, to: &ranges)

                case DWARFLoclistEntry.defaultLocation:
                    guard (try readLoclistExpression(cursor, limit: limit)) != nil else {
                        return ranges
                    }

                case DWARFLoclistEntry.startEnd:
                    let lo = try readLoclistAddress(cursor, addressSize: addressSize)
                    let hi = try readLoclistAddress(cursor, addressSize: addressSize)
                    guard let expression = try readLoclistExpression(cursor, limit: limit) else {
                        return ranges
                    }
                    appendLoclistRange(lo: lo, hi: hi, expression: expression, unit: unit, to: &ranges)

                case DWARFLoclistEntry.startLength:
                    let lo = try readLoclistAddress(cursor, addressSize: addressSize)
                    let length = try cursor.readULEB128()
                    guard let expression = try readLoclistExpression(cursor, limit: limit) else {
                        return ranges
                    }
                    let (hi, overflow) = lo.addingReportingOverflow(length)
                    if !overflow {
                        appendLoclistRange(lo: lo, hi: hi, expression: expression, unit: unit, to: &ranges)
                    }

                default:
                    return ranges
                }
            } catch {
                return ranges
            }
        }

        return ranges
    }

    private func readLoclistExpression(_ cursor: ByteCursor, limit: Int) throws -> [UInt8]? {
        let length = try cursor.readULEB128()
        guard length <= UInt64(Int.max) else { return nil }
        let intLength = Int(length)
        guard cursor.offset <= limit, intLength <= limit - cursor.offset else { return nil }
        return try cursor.readBytes(intLength)
    }

    private func readLoclistAddress(_ cursor: ByteCursor, addressSize: UInt8) throws -> UInt64 {
        switch addressSize {
        case 4:
            return UInt64(try cursor.readU32())
        case 8:
            return try cursor.readU64()
        default:
            throw DWARFReaderError.malformed("unsupported loclist address size \(addressSize)")
        }
    }

    private func appendLoclistRange(
        lo: UInt64,
        hi: UInt64,
        expression: [UInt8],
        unit: CompilationUnit,
        to ranges: inout [DWARFLoclistRange]
    ) {
        guard hi > lo else { return }
        ranges.append(DWARFLoclistRange(
            lowPC: lo,
            highPC: hi,
            location: normalizedLoclistLocation(from: expression, unit: unit)
        ))
    }

    private func normalizedLoclistLocation(from bytes: [UInt8], unit: CompilationUnit) -> String {
        guard !bytes.isEmpty else { return "<expr>" }
        let evaluator = DWARFLocationExpressionEvaluator(addressSize: unit.addressSize) { index in
            resolveAddress(index: index, base: unit.addrBase)
        }
        let text = evaluator.normalizedLocation(from: bytes)
        guard Self.isSimpleLoclistLocation(text) else { return "<expr>" }
        return text
    }

    private static func isSimpleLoclistLocation(_ text: String) -> Bool {
        text.range(of: #"^reg[0-9]+$"#, options: .regularExpression) != nil ||
            text.range(of: #"^fbreg -?[0-9]+$"#, options: .regularExpression) != nil ||
            text.range(of: #"^breg[0-9]+ -?[0-9]+$"#, options: .regularExpression) != nil ||
            text.range(of: #"^addr 0x[0-9a-f]+$"#, options: .regularExpression) != nil
    }

    private func rnglistRanges(from value: AttributeValue?, unit: CompilationUnit) -> [DWARFRnglistRange] {
        guard !sections.debugRnglists.isEmpty else { return [] }

        switch value {
        case .rnglistIndex(let index):
            guard let offset = resolveRnglistOffset(index: index, unit: unit) else { return [] }
            return decodeRnglist(at: offset, unit: unit)
        case .rnglistOffset(let offset):
            return decodeRnglist(at: offset, unit: unit)
        default:
            return []
        }
    }

    private struct RnglistsTable {
        var offsetTableStart: Int
        var endOffset: Int
        var addressSize: UInt8
        var offsets: [UInt64]
    }

    private func resolveRnglistOffset(index: UInt64, unit: CompilationUnit) -> UInt64? {
        guard let table = rnglistsTable(forBase: unit.rnglistsBase),
              let intIndex = Int(exactly: index),
              table.offsets.indices.contains(intIndex) else {
            return nil
        }

        let offsetTableStart = UInt64(table.offsetTableStart)
        let (absoluteOffset, overflow) = offsetTableStart.addingReportingOverflow(table.offsets[intIndex])
        guard !overflow, absoluteOffset <= UInt64(sections.debugRnglists.count) else { return nil }
        return absoluteOffset
    }

    private func rnglistsTable(forBase base: UInt64) -> RnglistsTable? {
        guard let tables = try? parseRnglistsTables(), !tables.isEmpty else { return nil }
        if let exact = tables.first(where: { UInt64($0.offsetTableStart) == base }) {
            return exact
        }
        return tables.first
    }

    private func rnglistsTable(containing offset: UInt64) -> RnglistsTable? {
        guard let tables = try? parseRnglistsTables(),
              let intOffset = Int(exactly: offset) else {
            return nil
        }
        return tables.first { intOffset >= $0.offsetTableStart && intOffset < $0.endOffset }
    }

    private func parseRnglistsTables() throws -> [RnglistsTable] {
        let cursor = ByteCursor(sections.debugRnglists)
        var tables: [RnglistsTable] = []

        while cursor.remaining >= 4 {
            let initialLength = try cursor.readU32()
            let offsetSize: Int
            let unitLength: UInt64
            if initialLength == 0xffff_ffff {
                offsetSize = 8
                unitLength = try cursor.readU64()
            } else {
                offsetSize = 4
                unitLength = UInt64(initialLength)
            }

            let contentStart = cursor.offset
            guard unitLength > 0,
                  unitLength <= UInt64(cursor.count - contentStart) else {
                break
            }
            let nextOffset = contentStart + Int(unitLength)
            guard nextOffset > contentStart, nextOffset <= cursor.count else { break }

            let version = try cursor.readU16()
            let addressSize = try cursor.readU8()
            let segmentSelectorSize = try cursor.readU8()
            let offsetEntryCount = try cursor.readU32()
            guard version == 5,
                  (addressSize == 4 || addressSize == 8),
                  segmentSelectorSize == 0 else {
                cursor.seek(to: nextOffset)
                continue
            }

            let offsetTableStart = cursor.offset
            var offsets: [UInt64] = []
            for _ in 0..<Int(offsetEntryCount) {
                guard cursor.offset + offsetSize <= nextOffset else {
                    throw DWARFReaderError.malformed("rnglists offset table runs past unit")
                }
                offsets.append(offsetSize == 8 ? try cursor.readU64() : UInt64(try cursor.readU32()))
            }

            tables.append(RnglistsTable(
                offsetTableStart: offsetTableStart,
                endOffset: nextOffset,
                addressSize: addressSize,
                offsets: offsets
            ))
            cursor.seek(to: nextOffset)
        }

        return tables
    }

    private func decodeRnglist(at offset: UInt64, unit: CompilationUnit) -> [DWARFRnglistRange] {
        guard let startOffset = Int(exactly: offset),
              startOffset >= 0,
              startOffset < sections.debugRnglists.count else {
            return []
        }

        let table = rnglistsTable(containing: offset)
        let addressSize = table?.addressSize ?? unit.addressSize
        let limit = table?.endOffset ?? sections.debugRnglists.count
        guard startOffset < limit else { return [] }

        let cursor = ByteCursor(sections.debugRnglists)
        cursor.seek(to: startOffset)
        var ranges: [DWARFRnglistRange] = []
        var baseAddress = unit.rangeBaseAddress ?? 0
        var baseAddressIsKnown = unit.rangeBaseAddress != nil

        while cursor.offset < limit {
            do {
                let kind = try cursor.readU8()
                switch kind {
                case DWARFRnglistEntry.endOfList:
                    return ranges

                case DWARFRnglistEntry.baseAddressx:
                    guard let index = try readBoundedULEB128(cursor, limit: limit) else { return ranges }
                    if let resolved = resolveAddress(index: index, base: unit.addrBase) {
                        baseAddress = resolved
                        baseAddressIsKnown = true
                    } else {
                        baseAddressIsKnown = false
                    }

                case DWARFRnglistEntry.startxEndx:
                    guard let startIndex = try readBoundedULEB128(cursor, limit: limit),
                          let endIndex = try readBoundedULEB128(cursor, limit: limit) else {
                        return ranges
                    }
                    if let lo = resolveAddress(index: startIndex, base: unit.addrBase),
                       let hi = resolveAddress(index: endIndex, base: unit.addrBase) {
                        appendRnglistRange(lo: lo, hi: hi, to: &ranges)
                    }

                case DWARFRnglistEntry.startxLength:
                    guard let startIndex = try readBoundedULEB128(cursor, limit: limit),
                          let length = try readBoundedULEB128(cursor, limit: limit) else {
                        return ranges
                    }
                    if let lo = resolveAddress(index: startIndex, base: unit.addrBase) {
                        let (hi, overflow) = lo.addingReportingOverflow(length)
                        if !overflow {
                            appendRnglistRange(lo: lo, hi: hi, to: &ranges)
                        }
                    }

                case DWARFRnglistEntry.offsetPair:
                    guard let start = try readBoundedULEB128(cursor, limit: limit),
                          let end = try readBoundedULEB128(cursor, limit: limit),
                          baseAddressIsKnown,
                          let lo = Self.addRangeOffset(base: baseAddress, offset: start),
                          let hi = Self.addRangeOffset(base: baseAddress, offset: end) else {
                        return ranges
                    }
                    appendRnglistRange(lo: lo, hi: hi, to: &ranges)

                case DWARFRnglistEntry.baseAddress:
                    guard let address = try readRnglistAddress(cursor, addressSize: addressSize, limit: limit) else {
                        return ranges
                    }
                    baseAddress = address
                    baseAddressIsKnown = true

                case DWARFRnglistEntry.startEnd:
                    guard let lo = try readRnglistAddress(cursor, addressSize: addressSize, limit: limit),
                          let hi = try readRnglistAddress(cursor, addressSize: addressSize, limit: limit) else {
                        return ranges
                    }
                    appendRnglistRange(lo: lo, hi: hi, to: &ranges)

                case DWARFRnglistEntry.startLength:
                    guard let lo = try readRnglistAddress(cursor, addressSize: addressSize, limit: limit),
                          let length = try readBoundedULEB128(cursor, limit: limit) else {
                        return ranges
                    }
                    let (hi, overflow) = lo.addingReportingOverflow(length)
                    if !overflow {
                        appendRnglistRange(lo: lo, hi: hi, to: &ranges)
                    }

                default:
                    return ranges
                }
            } catch {
                return ranges
            }
        }

        return ranges
    }

    private func readBoundedULEB128(_ cursor: ByteCursor, limit: Int) throws -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while true {
            guard cursor.offset < limit else { return nil }
            let byte = try cursor.readU8()
            if shift < 64 {
                result |= UInt64(byte & 0x7f) << shift
            }
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 70 { return nil }
        }

        return result
    }

    private func readRnglistAddress(_ cursor: ByteCursor, addressSize: UInt8, limit: Int) throws -> UInt64? {
        let size = Int(addressSize)
        guard cursor.offset <= limit, size <= limit - cursor.offset else { return nil }

        switch addressSize {
        case 4:
            return UInt64(try cursor.readU32())
        case 8:
            return try cursor.readU64()
        default:
            return nil
        }
    }

    private func appendRnglistRange(lo: UInt64, hi: UInt64, to ranges: inout [DWARFRnglistRange]) {
        guard hi > lo else { return }
        ranges.append(DWARFRnglistRange(lowPC: lo, highPC: hi))
    }

    private static func addRangeOffset(base: UInt64, offset: UInt64) -> UInt64? {
        let (value, overflow) = base.addingReportingOverflow(offset)
        return overflow ? nil : value
    }

    // MARK: - Abbreviation table

    private struct Abbreviation {
        var tag: UInt64
        var hasChildren: Bool
        var attributes: [AbbrevAttribute]
    }

    private struct AbbrevAttribute {
        var attribute: UInt64
        var form: UInt64
        /// Implicit constant value for `DW_FORM_implicit_const` (carried in the abbrev,
        /// not the DIE). nil for every other form.
        var implicitConst: Int64?
    }

    /// Parses the abbreviation table that begins at `offset` in `.debug_abbrev`. Stops at
    /// the table-terminating null entry (abbrev code 0).
    private func parseAbbrevTable(at offset: UInt64) throws -> [UInt64: Abbreviation] {
        let cursor = ByteCursor(sections.debugAbbrev)
        guard offset <= UInt64(cursor.count) else {
            throw DWARFReaderError.malformed("abbrev offset runs past .debug_abbrev")
        }
        cursor.seek(to: Int(offset))

        var table: [UInt64: Abbreviation] = [:]
        while cursor.remaining > 0 {
            let code = try cursor.readULEB128()
            if code == 0 { break } // end of this table
            let tag = try cursor.readULEB128()
            let hasChildren = try cursor.readU8() != 0
            var attributes: [AbbrevAttribute] = []
            // attribute/form pairs terminated by a (0,0) pair
            while true {
                let attr = try cursor.readULEB128()
                let form = try cursor.readULEB128()
                if attr == 0, form == 0 { break }
                var implicitConst: Int64?
                if form == DWARFConstants.formImplicitConst {
                    implicitConst = try cursor.readSLEB128()
                }
                attributes.append(AbbrevAttribute(attribute: attr, form: form, implicitConst: implicitConst))
            }
            table[code] = Abbreviation(tag: tag, hasChildren: hasChildren, attributes: attributes)
        }
        return table
    }

    // MARK: - Attribute values

    private enum AttributeValue {
        case string(String)
        case address(UInt64)
        case addrIndex(UInt64)
        case strIndex(UInt64)
        case uint(UInt64)
        case sint(Int64)
        case debugInfoOffset(UInt64)
        case exprloc([UInt8])
        case loclistIndex(UInt64)
        case loclistOffset(UInt64)
        case rnglistIndex(UInt64)
        case rnglistOffset(UInt64)
        case skipped

        var isSkipped: Bool {
            if case .skipped = self { return true }
            return false
        }

        var stringValue: String? {
            if case let .string(value) = self { return value }
            return nil
        }

        var unsignedValue: UInt64? {
            switch self {
            case let .uint(value), let .address(value):
                return value
            case let .sint(value):
                return value >= 0 ? UInt64(value) : nil
            case let .loclistOffset(value), let .rnglistOffset(value):
                return value
            default:
                return nil
            }
        }

        var signedValue: Int64? {
            switch self {
            case let .sint(value):
                return value
            case let .uint(value), let .address(value):
                return Int64(exactly: value)
            default:
                return nil
            }
        }

        var addressLikeValue: UInt64? {
            switch self {
            case let .address(value), let .uint(value):
                return value
            case let .addrIndex(value):
                return value
            default:
                return nil
            }
        }
    }

    /// Reads (or skips) a single attribute's value, advancing `cursor` by exactly the
    /// form's encoded size. Unsupported-but-sized forms are consumed and reported as
    /// `.skipped`; an unknown form throws (the cursor can no longer be kept aligned).
    private func readAttributeValue(
        _ attribute: AbbrevAttribute,
        cursor: ByteCursor,
        unit: inout CompilationUnit
    ) throws -> AttributeValue {
        // Indirect forms may themselves select DW_FORM_indirect. Consume that
        // byte-bounded chain iteratively so hostile input cannot exhaust the
        // call stack; a truncated ULEB still fails through the cursor.
        var attribute = attribute
        while attribute.form == DWARFConstants.formIndirect {
            attribute = AbbrevAttribute(
                attribute: attribute.attribute,
                form: try cursor.readULEB128(),
                implicitConst: attribute.implicitConst
            )
        }
        switch attribute.form {
        case DWARFConstants.formAddr:
            let value = unit.addressSize == 8 ? try cursor.readU64() : UInt64(try cursor.readU32())
            return .address(value)

        case DWARFConstants.formData1, DWARFConstants.formFlag, DWARFConstants.formStrx1, DWARFConstants.formAddrx1, DWARFConstants.formRef1:
            let value = UInt64(try cursor.readU8())
            return classifyIndexed(form: attribute.form, value: value, unit: unit)

        case DWARFConstants.formData2, DWARFConstants.formStrx2, DWARFConstants.formAddrx2, DWARFConstants.formRef2:
            let value = UInt64(try cursor.readU16())
            return classifyIndexed(form: attribute.form, value: value, unit: unit)

        case DWARFConstants.formStrx3, DWARFConstants.formAddrx3:
            let value = try cursor.readU24()
            return classifyIndexed(form: attribute.form, value: value, unit: unit)

        case DWARFConstants.formData4, DWARFConstants.formRef4, DWARFConstants.formStrx4, DWARFConstants.formAddrx4, DWARFConstants.formSecOffset:
            let value = UInt64(try cursor.readU32())
            if attribute.form == DWARFConstants.formSecOffset,
               attribute.attribute == DWARFConstants.atLocation {
                return .loclistOffset(value)
            }
            if attribute.form == DWARFConstants.formSecOffset,
               attribute.attribute == DWARFConstants.atRanges {
                return .rnglistOffset(value)
            }
            // sec_offset can carry a base (str_offsets_base / addr_base handled by caller).
            return classifyIndexed(form: attribute.form, value: value, unit: unit)

        case DWARFConstants.formData8, DWARFConstants.formRef8, DWARFConstants.formRefSig8:
            let value = try cursor.readU64()
            return .uint(value)

        case DWARFConstants.formData16:
            try cursor.skip(16)
            return .skipped

        case DWARFConstants.formSData:
            return .sint(try cursor.readSLEB128())

        case DWARFConstants.formUData, DWARFConstants.formRefUData:
            let value = try cursor.readULEB128()
            return .uint(value)

        case DWARFConstants.formStrx, DWARFConstants.formAddrx:
            let index = try cursor.readULEB128()
            return classifyIndexed(form: attribute.form, value: index, unit: unit)

        case DWARFConstants.formString:
            return .string(try cursor.readCString())

        case DWARFConstants.formStrp, DWARFConstants.formLineStrp:
            let offset = UInt64(try cursor.readU32())
            // .debug_line_str is not retained; only .debug_str-backed strp resolves.
            if attribute.form == DWARFConstants.formStrp {
                return .string(stringFromDebugStr(offset: offset))
            }
            return .skipped

        case DWARFConstants.formFlagPresent:
            return .uint(1) // no bytes in the DIE

        case DWARFConstants.formImplicitConst:
            return .sint(attribute.implicitConst ?? 0)

        case DWARFConstants.formExprLoc:
            let length = try cursor.readULEB128()
            // A crafted ULEB128 can exceed Int.max; Int(length) would TRAP. Reject it instead.
            guard length <= UInt64(Int.max) else {
                throw DWARFReaderError.malformed("block/exprloc length overflow")
            }
            return .exprloc(try cursor.readBytes(Int(length)))

        case DWARFConstants.formBlock:
            let length = try cursor.readULEB128()
            guard length <= UInt64(Int.max) else {
                throw DWARFReaderError.malformed("block/exprloc length overflow")
            }
            try cursor.skip(Int(length))
            return .skipped

        case DWARFConstants.formBlock1:
            let length = UInt64(try cursor.readU8())
            try cursor.skip(Int(length))
            return .skipped

        case DWARFConstants.formBlock2:
            let length = UInt64(try cursor.readU16())
            try cursor.skip(Int(length))
            return .skipped

        case DWARFConstants.formBlock4:
            let length = UInt64(try cursor.readU32())
            try cursor.skip(Int(length))
            return .skipped

        case DWARFConstants.formRefAddr:
            // Offset-sized absolute reference into .debug_info (DWARF32 → 4 bytes).
            let value = unit.offsetSize == 8 ? try cursor.readU64() : UInt64(try cursor.readU32())
            return .debugInfoOffset(value)

        case DWARFConstants.formLoclistx:
            let index = try cursor.readULEB128()
            if attribute.attribute == DWARFConstants.atLocation {
                return .loclistIndex(index)
            }
            return .skipped

        case DWARFConstants.formRnglistx:
            let index = try cursor.readULEB128()
            if attribute.attribute == DWARFConstants.atRanges {
                return .rnglistIndex(index)
            }
            return .skipped

        default:
            throw DWARFReaderError.malformed("unsupported DWARF form 0x\(String(attribute.form, radix: 16))")
        }
    }

    /// Tags an already-read integer with the meaning its form implies: an addrx-family
    /// value is an address index, a strx-family value is a string index (resolved here),
    /// otherwise it is an opaque uint the caller may use as a base offset.
    private func classifyIndexed(form: UInt64, value: UInt64, unit: CompilationUnit) -> AttributeValue {
        switch form {
        case DWARFConstants.formAddrx, DWARFConstants.formAddrx1, DWARFConstants.formAddrx2,
             DWARFConstants.formAddrx3, DWARFConstants.formAddrx4:
            return .addrIndex(value)
        case DWARFConstants.formStrx, DWARFConstants.formStrx1, DWARFConstants.formStrx2,
             DWARFConstants.formStrx3, DWARFConstants.formStrx4:
            if let text = stringFromStrIndex(value, base: unit.strOffsetsBase) {
                return .string(text)
            }
            return .strIndex(value)
        default:
            return .uint(value)
        }
    }

    // MARK: - String / address resolution

    /// Resolves a `.debug_str` offset to its NUL-terminated string (empty when out of range).
    private func stringFromDebugStr(offset: UInt64) -> String {
        let reader = LittleEndianReader(sections.debugStr)
        guard offset <= UInt64(sections.debugStr.count) else { return "" }
        return reader.cString(fileOffset: Int(offset), limit: sections.debugStr.count)
    }

    /// Resolves a `DW_FORM_strx` INDEX through `.debug_str_offsets` (`base` + index*4 →
    /// a `.debug_str` offset → the string). Returns nil when either table is missing /
    /// the index is out of range, so the caller can fall back to a raw index marker.
    private func stringFromStrIndex(_ index: UInt64, base: UInt64) -> String? {
        guard !sections.debugStrOffsets.isEmpty else { return nil }
        // Overflow-checked: a crafted index could otherwise wrap base + index*4 back into range
        // and read an attacker-chosen slot past the bounds guard.
        let (product, mulOverflow) = index.multipliedReportingOverflow(by: 4)
        guard !mulOverflow else { return nil }
        let (entryOffset, addOverflow) = base.addingReportingOverflow(product)
        let (end, endOverflow) = entryOffset.addingReportingOverflow(4)
        guard !addOverflow, !endOverflow, end <= UInt64(sections.debugStrOffsets.count) else { return nil }
        let cursor = ByteCursor(sections.debugStrOffsets)
        cursor.seek(to: Int(entryOffset))
        guard let strOffset = try? cursor.readU32() else { return nil }
        return stringFromDebugStr(offset: UInt64(strOffset))
    }

    /// Resolves a `DW_FORM_addrx` index with the caller's address-table width.
    /// Existing consumers retain their eight-byte default.
    private func resolveAddress(index: UInt64, base: UInt64, addressSize: UInt8 = 8) -> UInt64? {
        guard !sections.debugAddr.isEmpty, addressSize == 4 || addressSize == 8 else { return nil }
        // Overflow-checked: the entry stride and base must not wrap.
        let (product, mulOverflow) = index.multipliedReportingOverflow(by: UInt64(addressSize))
        guard !mulOverflow else { return nil }
        let (entryOffset, addOverflow) = base.addingReportingOverflow(product)
        let (end, endOverflow) = entryOffset.addingReportingOverflow(UInt64(addressSize))
        guard !addOverflow, !endOverflow, end <= UInt64(sections.debugAddr.count) else { return nil }
        let cursor = ByteCursor(sections.debugAddr)
        cursor.seek(to: Int(entryOffset))
        if addressSize == 4 {
            guard let address = try? cursor.readU32() else { return nil }
            return UInt64(address)
        }
        return try? cursor.readU64()
    }
}

private struct DWARFLocationExpressionEvaluator {
    var addressSize: UInt8
    var resolveAddressIndex: (UInt64) -> UInt64?

    func normalizedLocation(from bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        let cursor = ByteCursor(Data(bytes))

        do {
            var location = try readBaseLocation(cursor)
            guard !location.text.isEmpty else { return "" }

            var allowsPlusUconst = location.isCFA
            var hasStackValue = false
            while cursor.remaining > 0 {
                let opcode = try cursor.readU8()
                switch opcode {
                case DWARFLocationOpcode.plusUconst where allowsPlusUconst && !hasStackValue:
                    let offset = try cursor.readULEB128()
                    guard offset <= UInt64(Int64.max) else { return "" }
                    location.text = "cfa \(offset)"
                    allowsPlusUconst = false
                case DWARFLocationOpcode.stackValue where !hasStackValue && cursor.remaining == 0:
                    hasStackValue = true
                default:
                    return ""
                }
            }

            return hasStackValue ? "\(location.text) stack_value" : location.text
        } catch {
            return ""
        }
    }

    func resolvedAddress(from bytes: [UInt8]) -> UInt64? {
        guard !bytes.isEmpty else { return nil }
        let cursor = ByteCursor(Data(bytes))

        do {
            let location = try readBaseLocation(cursor)
            guard cursor.remaining == 0 else { return nil }
            return location.address
        } catch {
            return nil
        }
    }

    private func readBaseLocation(_ cursor: ByteCursor) throws -> (text: String, isCFA: Bool, address: UInt64?) {
        let opcode = try cursor.readU8()
        switch opcode {
        case DWARFLocationOpcode.addr:
            switch addressSize {
            case 4:
                let address = UInt64(try cursor.readU32())
                return ("addr 0x\(String(address, radix: 16))", false, address)
            case 8:
                let address = try cursor.readU64()
                return ("addr 0x\(String(address, radix: 16))", false, address)
            default:
                return ("", false, nil)
            }
        case DWARFLocationOpcode.reg0...DWARFLocationOpcode.reg31:
            return ("reg\(opcode - DWARFLocationOpcode.reg0)", false, nil)
        case DWARFLocationOpcode.breg0...DWARFLocationOpcode.breg31:
            let register = opcode - DWARFLocationOpcode.breg0
            return ("breg\(register) \(try cursor.readSLEB128())", false, nil)
        case DWARFLocationOpcode.regx:
            return ("reg\(try cursor.readULEB128())", false, nil)
        case DWARFLocationOpcode.fbreg:
            return ("fbreg \(try cursor.readSLEB128())", false, nil)
        case DWARFLocationOpcode.bregx:
            let register = try cursor.readULEB128()
            let offset = try cursor.readSLEB128()
            return ("breg\(register) \(offset)", false, nil)
        case DWARFLocationOpcode.callFrameCFA:
            return ("cfa 0", true, nil)
        case DWARFLocationOpcode.addrx:
            let index = try cursor.readULEB128()
            guard let address = resolveAddressIndex(index) else { return ("", false, nil) }
            return ("addr 0x\(String(address, radix: 16))", false, address)
        default:
            return ("", false, nil)
        }
    }
}

private enum DWARFLocationOpcode {
    static let addr: UInt8 = 0x03
    static let plusUconst: UInt8 = 0x23
    static let reg0: UInt8 = 0x50
    static let reg31: UInt8 = 0x6f
    static let breg0: UInt8 = 0x70
    static let breg31: UInt8 = 0x8f
    static let regx: UInt8 = 0x90
    static let fbreg: UInt8 = 0x91
    static let bregx: UInt8 = 0x92
    static let callFrameCFA: UInt8 = 0x9c
    static let stackValue: UInt8 = 0x9f
    static let addrx: UInt8 = 0xa1
}

/// A minimal forward cursor over a `Data` slice with bounds-checked little-endian reads
/// and LEB128 decoders. Distinct from `LittleEndianReader` (which is random-access and
/// shared by the format loaders) because the DWARF walk is fundamentally sequential —
/// a moving `offset` keeps the abbrev/DIE/attribute decoders simple and aligned.
private final class ByteCursor {
    let bytes: [UInt8]
    private let endOffset: Int
    private(set) var offset: Int

    init(_ data: Data, endOffset: Int? = nil) {
        self.bytes = [UInt8](data)
        self.endOffset = max(0, min(endOffset ?? data.count, data.count))
        self.offset = 0
    }

    var count: Int { endOffset }
    var remaining: Int { endOffset - offset }

    func seek(to newOffset: Int) {
        offset = max(0, min(newOffset, endOffset))
    }

    func skip(_ length: Int) throws {
        guard length >= 0, length <= remaining else {
            throw DWARFReaderError.malformed("read past end of section")
        }
        offset += length
    }

    func align(to alignment: Int) throws {
        guard alignment > 0 else { return }
        let remainder = offset % alignment
        if remainder != 0 {
            try skip(alignment - remainder)
        }
    }

    func readBytes(_ length: Int) throws -> [UInt8] {
        guard length >= 0, length <= remaining else {
            throw DWARFReaderError.malformed("read past end of section")
        }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }

    func readU8() throws -> UInt8 {
        guard remaining >= 1 else { throw DWARFReaderError.malformed("u8 past end") }
        defer { offset += 1 }
        return bytes[offset]
    }

    func readU16() throws -> UInt16 {
        guard remaining >= 2 else { throw DWARFReaderError.malformed("u16 past end") }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    func readU24() throws -> UInt64 {
        guard remaining >= 3 else { throw DWARFReaderError.malformed("u24 past end") }
        defer { offset += 3 }
        return UInt64(bytes[offset])
            | (UInt64(bytes[offset + 1]) << 8)
            | (UInt64(bytes[offset + 2]) << 16)
    }

    func readU32() throws -> UInt32 {
        guard remaining >= 4 else { throw DWARFReaderError.malformed("u32 past end") }
        defer { offset += 4 }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * i) }
        return value
    }

    func readU64() throws -> UInt64 {
        guard remaining >= 8 else { throw DWARFReaderError.malformed("u64 past end") }
        defer { offset += 8 }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
        return value
    }

    /// Reads a NUL-terminated UTF-8 string, consuming the terminator.
    func readCString() throws -> String {
        var scalars: [UInt8] = []
        while offset < endOffset {
            let byte = bytes[offset]
            offset += 1
            if byte == 0 { return String(decoding: scalars, as: UTF8.self) }
            scalars.append(byte)
        }
        throw DWARFReaderError.malformed("unterminated string")
    }

    func readCString(limit: Int) throws -> String {
        guard limit >= offset, limit <= endOffset else {
            throw DWARFReaderError.malformed("invalid string limit")
        }
        var scalars: [UInt8] = []
        while offset < limit {
            let byte = bytes[offset]
            offset += 1
            if byte == 0 { return String(decoding: scalars, as: UTF8.self) }
            scalars.append(byte)
        }
        throw DWARFReaderError.malformed("unterminated string")
    }

    func readULEB128() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readU8()
            let payload = byte & 0x7f
            // At bit 63 only one value bit remains. Later groups may only
            // zero-extend it; shifting first would silently discard overflow.
            if (shift == 63 && payload > 1) || (shift > 63 && payload != 0) {
                throw DWARFReaderError.malformed("ULEB128 value exceeds UInt64")
            }
            if shift < 64 {
                result |= UInt64(payload) << shift
            }
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 70 { throw DWARFReaderError.malformed("ULEB128 too long") }
        }
        return result
    }

    func readSLEB128() throws -> Int64 {
        var result: Int64 = 0
        var shift: UInt64 = 0
        var byte: UInt8 = 0
        repeat {
            byte = try readU8()
            let payload = byte & 0x7f
            // The tenth group must be an exact sign extension. Any other
            // payload represents a value outside the signed 64-bit domain.
            if shift == 63 && payload != 0 && payload != 0x7f {
                throw DWARFReaderError.malformed("SLEB128 value exceeds Int64")
            }
            if shift < 64 {
                result |= Int64(payload) << shift
            }
            shift += 7
            if shift > 70 { throw DWARFReaderError.malformed("SLEB128 too long") }
        } while byte & 0x80 != 0
        // Sign-extend
        if shift < 64, byte & 0x40 != 0 {
            result |= -(Int64(1) << shift)
        }
        return result
    }
}

/// The subset of DWARF tag/attribute/form constants the function-name reader needs.
/// Values are the stable external ABI from the DWARF 5 standard.
enum DWARFConstants {
    // Tags
    static let tagArrayType: UInt64 = 0x01
    static let tagClassType: UInt64 = 0x02
    static let tagEnumerationType: UInt64 = 0x04
    static let tagFormalParameter: UInt64 = 0x05
    static let tagMember: UInt64 = 0x0d
    static let tagPointerType: UInt64 = 0x0f
    static let tagCompileUnit: UInt64 = 0x11
    static let tagStructureType: UInt64 = 0x13
    static let tagSubroutineType: UInt64 = 0x15
    static let tagTypedef: UInt64 = 0x16
    static let tagUnionType: UInt64 = 0x17
    static let tagSubrangeType: UInt64 = 0x21
    static let tagBaseType: UInt64 = 0x24
    static let tagConstType: UInt64 = 0x26
    static let tagEnumerator: UInt64 = 0x28
    static let tagSubprogram: UInt64 = 0x2e
    static let tagVariable: UInt64 = 0x34
    static let tagVolatileType: UInt64 = 0x35
    static let tagRestrictType: UInt64 = 0x37

    // Attributes
    static let atLocation: UInt64 = 0x02
    static let atName: UInt64 = 0x03
    static let atByteSize: UInt64 = 0x0b
    static let atLowPC: UInt64 = 0x11
    static let atConstValue: UInt64 = 0x1c
    static let atPrototyped: UInt64 = 0x27
    static let atUpperBound: UInt64 = 0x2f
    static let atAbstractOrigin: UInt64 = 0x31
    static let atCount: UInt64 = 0x37
    static let atDataMemberLocation: UInt64 = 0x38
    static let atAppleObjCDirect: UInt64 = 0x3fee
    static let atSpecification: UInt64 = 0x47
    static let atType: UInt64 = 0x49
    static let atRanges: UInt64 = 0x55
    static let atStrOffsetsBase: UInt64 = 0x72
    static let atAddrBase: UInt64 = 0x73
    static let atRnglistsBase: UInt64 = 0x74
    static let atLoclistsBase: UInt64 = 0x8c

    // Forms
    static let formAddr: UInt64 = 0x01
    static let formBlock2: UInt64 = 0x03
    static let formBlock4: UInt64 = 0x04
    static let formData2: UInt64 = 0x05
    static let formData4: UInt64 = 0x06
    static let formData8: UInt64 = 0x07
    static let formString: UInt64 = 0x08
    static let formBlock: UInt64 = 0x09
    static let formBlock1: UInt64 = 0x0a
    static let formData1: UInt64 = 0x0b
    static let formFlag: UInt64 = 0x0c
    static let formSData: UInt64 = 0x0d
    static let formStrp: UInt64 = 0x0e
    static let formUData: UInt64 = 0x0f
    static let formRefAddr: UInt64 = 0x10
    static let formRef1: UInt64 = 0x11
    static let formRef2: UInt64 = 0x12
    static let formRef4: UInt64 = 0x13
    static let formRef8: UInt64 = 0x14
    static let formRefUData: UInt64 = 0x15
    static let formIndirect: UInt64 = 0x16
    static let formSecOffset: UInt64 = 0x17
    static let formExprLoc: UInt64 = 0x18
    static let formFlagPresent: UInt64 = 0x19
    static let formStrx: UInt64 = 0x1a
    static let formAddrx: UInt64 = 0x1b
    static let formRefSup4: UInt64 = 0x1c
    static let formStrpSup: UInt64 = 0x1d
    static let formData16: UInt64 = 0x1e
    static let formLineStrp: UInt64 = 0x1f
    static let formRefSig8: UInt64 = 0x20
    static let formImplicitConst: UInt64 = 0x21
    static let formLoclistx: UInt64 = 0x22
    static let formRnglistx: UInt64 = 0x23
    static let formStrx1: UInt64 = 0x25
    static let formStrx2: UInt64 = 0x26
    static let formStrx3: UInt64 = 0x27
    static let formStrx4: UInt64 = 0x28
    static let formAddrx1: UInt64 = 0x29
    static let formAddrx2: UInt64 = 0x2a
    static let formAddrx3: UInt64 = 0x2b
    static let formAddrx4: UInt64 = 0x2c
}

private enum DWARFLoclistEntry {
    static let endOfList: UInt8 = 0x00
    static let baseAddressx: UInt8 = 0x01
    static let startxEndx: UInt8 = 0x02
    static let startxLength: UInt8 = 0x03
    static let offsetPair: UInt8 = 0x04
    static let defaultLocation: UInt8 = 0x05
    static let startEnd: UInt8 = 0x07
    static let startLength: UInt8 = 0x08
}

private enum DWARFRnglistEntry {
    static let endOfList: UInt8 = 0x00
    static let baseAddressx: UInt8 = 0x01
    static let startxEndx: UInt8 = 0x02
    static let startxLength: UInt8 = 0x03
    static let offsetPair: UInt8 = 0x04
    static let baseAddress: UInt8 = 0x05
    static let startEnd: UInt8 = 0x06
    static let startLength: UInt8 = 0x07
}

private enum DWARFCFAOpcode {
    static let primaryMask: UInt8 = 0xc0
    static let primaryOperandMask: UInt8 = 0x3f
    static let advanceLoc: UInt8 = 0x40
    static let offset: UInt8 = 0x80
    static let restore: UInt8 = 0xc0

    static let nop: UInt8 = 0x00
    static let setLoc: UInt8 = 0x01
    static let advanceLoc1: UInt8 = 0x02
    static let advanceLoc2: UInt8 = 0x03
    static let advanceLoc4: UInt8 = 0x04
    static let offsetExtended: UInt8 = 0x05
    static let restoreExtended: UInt8 = 0x06
    static let undefined: UInt8 = 0x07
    static let sameValue: UInt8 = 0x08
    static let register: UInt8 = 0x09
    static let rememberState: UInt8 = 0x0a
    static let restoreState: UInt8 = 0x0b
    static let defCFA: UInt8 = 0x0c
    static let defCFARegister: UInt8 = 0x0d
    static let defCFAOffset: UInt8 = 0x0e
    static let defCFAExpression: UInt8 = 0x0f
    static let expression: UInt8 = 0x10
    static let offsetExtendedSF: UInt8 = 0x11
    static let defCFASF: UInt8 = 0x12
    static let defCFAOffsetSF: UInt8 = 0x13
    static let valOffset: UInt8 = 0x14
    static let valOffsetSF: UInt8 = 0x15
    static let valExpression: UInt8 = 0x16
}

private enum DWEHPointerEncoding {
    static let nativePointerSize = 8
    static let formatMask: UInt8 = 0x0f
    static let applicationMask: UInt8 = 0x70

    static let absptr: UInt8 = 0x00
    static let uleb128: UInt8 = 0x01
    static let udata2: UInt8 = 0x02
    static let udata4: UInt8 = 0x03
    static let udata8: UInt8 = 0x04
    static let sleb128: UInt8 = 0x09
    static let sdata2: UInt8 = 0x0a
    static let sdata4: UInt8 = 0x0b
    static let sdata8: UInt8 = 0x0c
    static let omit: UInt8 = 0xff

    static let absoluteptr: UInt8 = 0x00
    static let pcrel: UInt8 = 0x10
    static let textrel: UInt8 = 0x20
    static let datarel: UInt8 = 0x30
    static let funcrel: UInt8 = 0x40
    static let aligned: UInt8 = 0x50
}

private enum CharacterASCII {
    static let upperL: UInt8 = 0x4c
    static let upperP: UInt8 = 0x50
    static let upperR: UInt8 = 0x52
}

extension DWARFReader {
    /// Strict record recovery with lossless instruction programs. Unlike the display
    /// API, a malformed envelope fails the table instead of silently dropping data.
    func recoverStructuredCallFrameInfo(
        sectionAddress: UInt64 = 0
    ) throws -> DWARFStructuredCallFrameTable {
        try recoverStructuredCallFrameInfo(sectionAddress: sectionAddress, includeExceptionMetadata: false)
    }

    /// Retains exact CIE personality and FDE LSDA fields without resolving indirect
    /// slots or claiming runtime exception behavior. Unsupported encodings fail closed.
    func recoverExceptionCallFrameInfo(
        sectionAddress: UInt64 = 0
    ) throws -> DWARFStructuredCallFrameTable {
        try recoverStructuredCallFrameInfo(sectionAddress: sectionAddress, includeExceptionMetadata: true)
    }

    private func recoverStructuredCallFrameInfo(
        sectionAddress: UInt64, includeExceptionMetadata: Bool
    ) throws -> DWARFStructuredCallFrameTable {
        let cursor = ByteCursor(sections.ehFrame)
        var table = DWARFStructuredCallFrameTable(cies: [], fdes: [])
        var ciesByOffset: [Int: DWARFStructuredCIE] = [:]
        while cursor.remaining > 0 {
            let entryStart = cursor.offset
            guard cursor.remaining >= 4 else {
                throw DWARFReaderError.malformed("truncated .eh_frame header at \(entryStart)")
            }
            let initialLength = try cursor.readU32()
            cursor.seek(to: entryStart)
            guard initialLength != UInt32.max else {
                throw DWARFReaderError.malformed("DWARF64 structured call-frame records are unsupported")
            }
            guard let header = try readEHFrameEntryHeader(cursor) else {
                guard try cursor.readBytes(cursor.remaining).allSatisfy({ $0 == 0 }) else {
                    throw DWARFReaderError.malformed("nonzero data after .eh_frame terminator")
                }
                break
            }
            let pointerOffset = cursor.offset
            let pointer = try cursor.readU32()
            let payloadOffset = cursor.offset
            let payload = ByteCursor(Data(try cursor.readBytes(header.contentEndOffset - cursor.offset)))
            if pointer == 0 {
                let cie = try readStructuredCIE(payload, entryOffset: entryStart,
                    payloadOffset: payloadOffset, sectionAddress: sectionAddress,
                    includeExceptionMetadata: includeExceptionMetadata)
                ciesByOffset[entryStart] = cie
                table.cies.append(cie)
            } else {
                guard UInt64(pointer) <= UInt64(pointerOffset),
                      let cie = ciesByOffset[pointerOffset - Int(pointer)],
                      cie.sectionOffset < entryStart else {
                    throw DWARFReaderError.malformed("FDE does not reference an earlier exact CIE")
                }
                let location: UInt64
                if includeExceptionMetadata {
                    guard cie.fdePointerEncoding & 0x80 == 0 else {
                        throw DWARFReaderError.malformed("indirect exception FDE location is unsupported")
                    }
                    location = try readExceptionPointer(payload, encoding: cie.fdePointerEncoding,
                        sectionOffset: payloadOffset, sectionAddress: sectionAddress).value
                } else {
                    location = try readStructuredPointer(payload, encoding: cie.fdePointerEncoding,
                        fieldOffset: payloadOffset + payload.offset, sectionAddress: sectionAddress,
                        applyApplication: true)
                }
                let range = try readStructuredPointer(payload, encoding: cie.fdePointerEncoding,
                    fieldOffset: payloadOffset + payload.offset, sectionAddress: sectionAddress,
                    applyApplication: false)
                let augmentation = cie.augmentation.hasPrefix("z")
                    ? try readStructuredBlock(payload) : []
                let programOffset = payloadOffset + payload.offset
                var lsdaPointer: DWARFExceptionEncodedPointer?
                if includeExceptionMetadata {
                    let signedRange = [UInt8(9), 10, 11, 12].contains(cie.fdePointerEncoding & 0x0f)
                    guard range > 0, !(signedRange && Int64(bitPattern: range) < 0),
                          !location.addingReportingOverflow(range).overflow else {
                        throw DWARFReaderError.malformed("invalid exception FDE address range")
                    }
                    let augmentationCursor = ByteCursor(Data(augmentation))
                    if let encoding = cie.lsdaPointerEncoding, encoding != 0xff {
                        lsdaPointer = try readExceptionPointer(augmentationCursor, encoding: encoding,
                            sectionOffset: programOffset - augmentation.count,
                            sectionAddress: sectionAddress)
                    }
                    guard augmentationCursor.remaining == 0 else {
                        throw DWARFReaderError.malformed("unconsumed exception FDE augmentation data")
                    }
                }
                let bytes = try payload.readBytes(payload.remaining)
                table.fdes.append(DWARFStructuredFDE(sectionOffset: entryStart,
                    cieSectionOffset: cie.sectionOffset, initialLocation: location, rangeSize: range,
                    augmentationData: augmentation,
                    program: decodeStructuredCFA(bytes, sectionOffset: programOffset,
                        pointerEncoding: cie.fdePointerEncoding, sectionAddress: sectionAddress),
                    lsdaPointer: lsdaPointer,
                    exceptionMetadataRange: includeExceptionMetadata ? entryStart..<programOffset : nil))
            }
        }
        return table
    }

    private func readStructuredCIE(
        _ cursor: ByteCursor, entryOffset: Int, payloadOffset: Int, sectionAddress: UInt64,
        includeExceptionMetadata: Bool
    ) throws -> DWARFStructuredCIE {
        let version = try cursor.readU8()
        guard version == 1 || version == 3 else {
            throw DWARFReaderError.malformed("unsupported structured CIE version \(version)")
        }
        let augmentation = try cursor.readCString()
        guard augmentation.isEmpty || augmentation.hasPrefix("z") else {
            throw DWARFReaderError.malformed("unsupported CIE augmentation")
        }
        let codeAlignment = try cursor.readULEB128()
        let dataAlignment = try cursor.readSLEB128()
        let returnRegister = version == 1 ? UInt64(try cursor.readU8()) : try cursor.readULEB128()
        let augmentationData = augmentation.hasPrefix("z") ? try readStructuredBlock(cursor) : []
        let augmentationCursor = ByteCursor(Data(augmentationData))
        let augmentationOffset = payloadOffset + cursor.offset - augmentationData.count
        var pointerEncoding: UInt8 = 0
        var lsdaPointerEncoding: UInt8?
        var personalityPointer: DWARFExceptionEncodedPointer?
        var seen: Set<Character> = []
        for character in augmentation.dropFirst() {
            if includeExceptionMetadata, !seen.insert(character).inserted {
                throw DWARFReaderError.malformed("duplicate exception CIE augmentation")
            }
            switch character {
            case "R": pointerEncoding = try augmentationCursor.readU8()
            case "L": lsdaPointerEncoding = try augmentationCursor.readU8()
            case "P":
                let encoding = try augmentationCursor.readU8()
                if includeExceptionMetadata {
                    personalityPointer = try readExceptionPointer(augmentationCursor, encoding: encoding,
                        sectionOffset: augmentationOffset, sectionAddress: sectionAddress)
                } else {
                    _ = try readStructuredPointer(augmentationCursor, encoding: encoding & 0x0f,
                        fieldOffset: 0, sectionAddress: 0, applyApplication: false)
                }
            case "S" where includeExceptionMetadata: break
            default: throw DWARFReaderError.malformed("unsupported CIE augmentation \(character)")
            }
        }
        guard augmentationCursor.remaining == 0 else {
            throw DWARFReaderError.malformed("unconsumed CIE augmentation data")
        }
        let programOffset = payloadOffset + cursor.offset
        let bytes = try cursor.readBytes(cursor.remaining)
        return DWARFStructuredCIE(sectionOffset: entryOffset, version: version,
            augmentation: augmentation, augmentationData: augmentationData,
            codeAlignmentFactor: codeAlignment, dataAlignmentFactor: dataAlignment,
            returnAddressRegister: returnRegister, fdePointerEncoding: pointerEncoding,
            initialProgram: decodeStructuredCFA(bytes, sectionOffset: programOffset,
                pointerEncoding: pointerEncoding, sectionAddress: sectionAddress),
            lsdaPointerEncoding: includeExceptionMetadata ? lsdaPointerEncoding : nil,
            personalityPointer: personalityPointer,
            exceptionMetadataRange: includeExceptionMetadata ? entryOffset..<programOffset : nil)
    }

    private func readExceptionPointer(
        _ cursor: ByteCursor, encoding: UInt8, sectionOffset: Int, sectionAddress: UInt64
    ) throws -> DWARFExceptionEncodedPointer {
        let application = encoding & 0x70
        guard encoding != 0xff, application == 0 || application == 0x10 else {
            throw DWARFReaderError.malformed("unsupported exception pointer application")
        }
        let start = cursor.offset
        let format = encoding & 0x0f
        let raw = try readStructuredPointer(cursor, encoding: format, fieldOffset: 0,
            sectionAddress: 0, applyApplication: false)
        let fieldOffset = sectionOffset + start
        var value = raw
        // A zero encoded pointer is null, including PC-relative forms. An indirect
        // zero remains an unresolved slot and is never promoted to a null target.
        if raw != 0, application == 0x10 {
            let (base, baseOverflow) = sectionAddress.addingReportingOverflow(UInt64(fieldOffset))
            // Darwin's native-width PC-relative fields use a signed pointer-sized
            // displacement (including the compiler-produced 0x10 FDE/LSDA form).
            let signed = [UInt8(0), 9, 10, 11, 12].contains(format)
            let displacement = Int64(bitPattern: raw)
            let resolved = signed && displacement < 0
                ? base.subtractingReportingOverflow(displacement.magnitude)
                : base.addingReportingOverflow(raw)
            guard !baseOverflow, !resolved.overflow else {
                throw DWARFReaderError.malformed("exception pointer address overflow")
            }
            value = resolved.partialValue
        }
        return DWARFExceptionEncodedPointer(value: value, encoding: encoding,
            sectionRange: fieldOffset..<(sectionOffset + cursor.offset))
    }

    private func readStructuredBlock(_ cursor: ByteCursor) throws -> [UInt8] {
        let size = try cursor.readULEB128()
        guard size <= UInt64(cursor.remaining) else {
            throw DWARFReaderError.malformed("truncated structured CFI block")
        }
        return try cursor.readBytes(Int(size))
    }

    private func readStructuredPointer(
        _ cursor: ByteCursor, encoding: UInt8, fieldOffset: Int,
        sectionAddress: UInt64, applyApplication: Bool
    ) throws -> UInt64 {
        let application = encoding & 0x70
        guard encoding & 0x80 == 0, application == 0 || application == 0x10 else {
            throw DWARFReaderError.malformed("unsupported structured CFI pointer encoding")
        }
        let value: UInt64
        switch encoding & 0x0f {
        case 0: value = try cursor.readU64()
        case 1: value = try cursor.readULEB128()
        case 2: value = UInt64(try cursor.readU16())
        case 3: value = UInt64(try cursor.readU32())
        case 4: value = try cursor.readU64()
        case 9: value = UInt64(bitPattern: try cursor.readSLEB128())
        case 10: value = UInt64(bitPattern: Int64(Int16(bitPattern: try cursor.readU16())))
        case 11: value = UInt64(bitPattern: Int64(Int32(bitPattern: try cursor.readU32())))
        case 12: value = try cursor.readU64()
        default: throw DWARFReaderError.malformed("unsupported structured CFI pointer width")
        }
        guard applyApplication && application == 0x10 else { return value }
        let (base, baseOverflow) = sectionAddress.addingReportingOverflow(UInt64(fieldOffset))
        let displacement = Int64(bitPattern: value)
        let resolved: (partialValue: UInt64, overflow: Bool)
        if displacement < 0 {
            resolved = base.subtractingReportingOverflow(displacement.magnitude)
        } else {
            resolved = base.addingReportingOverflow(UInt64(displacement))
        }
        guard !baseOverflow, !resolved.overflow else {
            throw DWARFReaderError.malformed("structured CFI address overflow")
        }
        return resolved.partialValue
    }

    private func decodeStructuredCFA(
        _ bytes: [UInt8], sectionOffset: Int, pointerEncoding: UInt8, sectionAddress: UInt64
    ) -> DWARFStructuredCFAProgram {
        let cursor = ByteCursor(Data(bytes))
        var result = DWARFStructuredCFAProgram(sectionOffset: sectionOffset,
            rawBytes: bytes, operations: [], status: .complete)
        while cursor.remaining > 0 {
            let start = cursor.offset
            do {
                let opcode = try cursor.readU8()
                var operands: [DWARFStructuredCFAOperand] = []
                var supported = true
                switch opcode & 0xc0 {
                case 0x40, 0xc0:
                    operands = [.unsigned(UInt64(opcode & 0x3f))]
                case 0x80:
                    operands = [.unsigned(UInt64(opcode & 0x3f)), .unsigned(try cursor.readULEB128())]
                default:
                    switch opcode {
                    case 0, 0x0a, 0x0b: break
                    case 1:
                        operands = [.unsigned(try readStructuredPointer(cursor, encoding: pointerEncoding,
                            fieldOffset: sectionOffset + cursor.offset, sectionAddress: sectionAddress,
                            applyApplication: true))]
                    case 2: operands = [.unsigned(UInt64(try cursor.readU8()))]
                    case 3: operands = [.unsigned(UInt64(try cursor.readU16()))]
                    case 4: operands = [.unsigned(UInt64(try cursor.readU32()))]
                    case 5, 9, 0x0c, 0x14:
                        operands = [.unsigned(try cursor.readULEB128()), .unsigned(try cursor.readULEB128())]
                    case 6, 7, 8, 0x0d, 0x0e:
                        operands = [.unsigned(try cursor.readULEB128())]
                    case 0x0f: operands = [.block(try readStructuredBlock(cursor))]
                    case 0x10, 0x16:
                        operands = [.unsigned(try cursor.readULEB128()), .block(try readStructuredBlock(cursor))]
                    case 0x11, 0x12, 0x15:
                        operands = [.unsigned(try cursor.readULEB128()), .signed(try cursor.readSLEB128())]
                    case 0x13: operands = [.signed(try cursor.readSLEB128())]
                    default: supported = false
                    }
                }
                result.operations.append(DWARFStructuredCFAOperation(sectionOffset: sectionOffset + start,
                    opcode: opcode, operands: operands, rawBytes: Array(bytes[start..<cursor.offset])))
                if !supported {
                    result.status = .unsupported(opcode: opcode)
                    return result
                }
            } catch {
                result.status = .malformed(offset: sectionOffset + start)
                return result
            }
        }
        return result
    }
}
