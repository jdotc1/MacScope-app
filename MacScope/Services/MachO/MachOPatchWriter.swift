import Foundation

/// Writes a PATCHED copy of a thin Mach-O binary to a byte buffer: the original bytes
/// with each `BytePatch` override applied at the FILE OFFSET its virtual address maps to.
///
/// This is the "Save Patched Binary" engine. MacScope applies byte patches in-memory
/// (`WorkspaceStore.patchBytes` / `setPatch`, keyed by virtual address) and re-decodes the
/// listing from them; this service projects those same patches back out to a real on-disk
/// executable so the modification persists outside MacScope — the "Produce New Executable"
/// capability.
///
/// CONSERVATIVE BY DESIGN (correctness over coverage):
/// - **Thin Mach-O only.** A fat/universal binary fails with `.fatBinaryUnsupported` rather
///   than guessing a slice — silently patching one slice of a universal file would corrupt it.
/// - **Every patch must map cleanly.** Each patched virtual address is resolved to a file
///   offset through the loaded segment table (the inverse of `MachOFile.virtualAddress(forFileOffset:)`).
///   An address that falls outside every file-backed segment, lands in zero-fill space (no
///   file bytes), or whose replacement run would spill past the segment's file content fails
///   with a typed error. Every complete span must also agree with the section mapping
///   analysis uses; header-only, aliased and disagreeing spans are rejected.
///   No partial / best-effort writes: the whole operation either produces
///   a fully-applied buffer or throws.
/// - **Pure.** No file I/O — the method returns the new `Data`; the thin write-to-disk layer
///   lives at the call site (an `NSSavePanel` in the app shell), exactly like
///   `DocumentExportService`/`GraphPDFRenderer`.
///
/// CODE SIGNATURE: a patched binary's existing `LC_CODE_SIGNATURE` is left untouched and is
/// therefore INVALID for the patched bytes — the OS will refuse to run the output until it is
/// re-signed (`codesign -s - <file>` ad-hoc, or with a real identity). This increment does
/// not re-sign or strip the signature; the caller surfaces that note to the user.
struct MachOPatchWriter {
    init() {}

    /// A new independently mapped RX section. `virtualAddress` is unslid; the caller
    /// must retain this exact result when projecting authored bytes into analysis.
    struct AppendedExecutableCave {
        let data: Data
        let virtualAddress: UInt64
        let fileOffset: UInt64
        let byteCount: Int
        let branchSourceAddress: UInt64?
        let branchInstruction: UInt32?
    }

    enum CaveWriteError: LocalizedError, Equatable {
        case unsupportedLayout(String)
        case invalidCaveLength
        case invalidBranchSource
        case branchOutOfRange
        case conflictingBranchPatch
        case outputMappingFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedLayout(let reason):
                return "Cannot append an executable cave to this Mach-O: \(reason)"
            case .invalidCaveLength:
                return "The ARM64 cave must contain 4-byte-aligned instructions and fit within 1 MiB."
            case .invalidBranchSource:
                return "The branch source must be a mapped, aligned executable ARM64 instruction."
            case .branchOutOfRange:
                return "The cave is outside the ARM64 B instruction's 128 MiB reach."
            case .conflictingBranchPatch:
                return "An existing byte patch overlaps the new branch instruction."
            case .outputMappingFailed:
                return "The appended executable section did not reparse with an unambiguous file mapping."
            }
        }
    }

    enum PatchWriteError: LocalizedError, Equatable {
        /// The binary is fat/universal; this increment writes thin Mach-O only.
        case fatBinaryUnsupported
        /// The bytes are not a recognizable Mach-O (bad magic, truncated header, …).
        case notMachO(reason: String)
        /// A patched virtual address is not inside any file-backed segment.
        case addressNotMapped(address: UInt64)
        /// The replacement run starting at `address` would extend past the end of the
        /// file content of the segment it lands in (it crosses into another region or
        /// off the end of the slice). Refusing keeps a too-long patch from corrupting
        /// an adjacent segment.
        case patchExceedsSegment(address: UInt64, length: Int)
        /// A computed file offset / range fell outside the binary buffer (defensive;
        /// a well-formed Mach-O should never trigger this).
        case fileOffsetOutOfRange(address: UInt64)
        /// Section and segment mappings must resolve the entire edit to the same
        /// unique file span used by analysis. Header-only and aliased spans fail.
        case inconsistentMapping(address: UInt64)

        var errorDescription: String? {
            switch self {
            case .fatBinaryUnsupported:
                return "Saving a patched binary is only supported for thin (single-architecture) "
                    + "Mach-O files. This binary is fat/universal; extract the slice you want to patch first."
            case .notMachO(let reason):
                return "The binary could not be parsed as a Mach-O file: \(reason)"
            case .addressNotMapped(let address):
                return String(
                    format: "Patch at 0x%llx maps to no file-backed segment, so it cannot be written to disk.",
                    address
                )
            case .patchExceedsSegment(let address, let length):
                return String(
                    format: "Patch at 0x%llx (%d bytes) extends past the end of its segment's file content.",
                    address, length
                )
            case .fileOffsetOutOfRange(let address):
                return String(
                    format: "Patch at 0x%llx resolved to a file offset outside the binary.",
                    address
                )
            case .inconsistentMapping(let address):
                return String(
                    format: "Patch at 0x%llx has no unambiguous file span shared by its section and segment mappings.",
                    address
                )
            }
        }
    }

    /// Produces a new byte buffer identical to `originalData` except that each patch in
    /// `patches` (keyed by virtual address) overwrites the bytes at the file offset its
    /// address maps to.
    ///
    /// - Parameters:
    ///   - originalData: the exact bytes of the on-disk thin Mach-O (as MacScope loaded it).
    ///   - patches: the workspace's byte patches, keyed by the patched instruction's virtual
    ///     address. Empty patches are ignored. An empty map returns a byte-identical copy.
    /// - Returns: the patched bytes, the same length as `originalData`.
    /// - Throws: `PatchWriteError` for a fat binary, an unparseable Mach-O, or any patch that
    ///   cannot be mapped/fitted; `BytePatchOverlay.Failure` for an oversized/overflowing edit.
    ///   The whole operation fails rather than returning a partial result.
    func makePatchedData(originalData: Data, patches: [UInt64: BytePatch]) throws -> Data {
        // Reject fat/universal up front by inspecting the magic directly, before parsing —
        // the parser would otherwise transparently select a slice, which is exactly the
        // silent-corruption path this increment refuses.
        let magic = try readBigEndianMagic(originalData)
        if magic == MachOConstants.fatMagic || magic == MachOConstants.fatMagic64 {
            throw PatchWriteError.fatBinaryUnsupported
        }

        let machO: MachOFile
        do {
            // Parse with metadata recovery OFF: the writer only needs sections and segments for the
            // VA→file-offset projection, and skipping the heavy passes keeps the save fast.
            machO = try MachOParser().parse(
                originalData,
                options: MachOParseOptions(
                    recoverStringLiterals: false,
                    recoverObjectiveCMetadata: false,
                    recoverSwiftMetadata: false,
                    parseCodeSignature: false
                )
            )
        } catch {
            throw PatchWriteError.notMachO(reason: error.localizedDescription)
        }

        // A thin parse must not have selected a universal slice. Belt-and-suspenders: the
        // magic check above already excludes fat, but a defensive guard here means a future
        // parser change can never let a sliced offset leak into the writer.
        if machO.universalBinary != nil {
            throw PatchWriteError.fatBinaryUnsupported
        }

        var output = originalData
        // Drop any non-zero startIndex so byte writes use absolute offsets (a `Data` carved
        // from a slice can have startIndex != 0; copying through `Data(originalData)` would
        // not by itself rebase). Re-wrap to guarantee a 0-based index space.
        if output.startIndex != 0 {
            output = Data(output)
        }
        let totalCount = output.count

        // The loader admits section-backed patches. A malformed section must not
        // make analysis read one offset while this writer changes another. Require
        // agreement with every covering segment, including interior file aliases.
        let sectionMappings = FileAddressMapping.verifiedMappings(
            from: machO.sections.map {
                SectionSummary(id: UUID(), name: $0.qualifiedName, address: $0.address,
                               size: $0.size, fileOffset: UInt64($0.fileOffset),
                               isExecutable: $0.isExecutableInstructions, isZeroFill: $0.isZeroFill)
            }, payloadLength: totalCount
        )
        let segmentMappings = machO.segments.map {
            FileAddressMapping(fileOffset: $0.fileOffset, size: min($0.vmSize, $0.fileSize),
                               virtualAddress: $0.vmAddress, sectionName: $0.name)
        }

        // Use the same overlap precedence and span/size checks as effective analysis.
        // Keep the established typed errors for absent/overrun segment spans.
        let overlay = try BytePatchOverlay(patches: patches)
        for edit in overlay.edits {
            let address = edit.address
            let bytes = edit.bytes
            guard let fileOffset = fileOffset(forVirtualAddress: address, in: machO, runLength: bytes.count) else {
                // Distinguish "no segment" from "spills past segment" so the user gets an
                // actionable message. Re-resolve the containing segment to classify.
                if containingFileBackedSegment(forVirtualAddress: address, in: machO) == nil {
                    throw PatchWriteError.addressNotMapped(address: address)
                }
                throw PatchWriteError.patchExceedsSegment(address: address, length: bytes.count)
            }
            // Checked conversion + SUBTRACTION-based bounds. A hostile segment table can report a
            // file offset > Int.max (which `Int(_:)` would TRAP on) or one near the buffer end where
            // `start + bytes.count` would overflow `Int` — both become a typed error, never a crash.
            guard let start = Int(exactly: fileOffset),
                  start <= totalCount,
                  bytes.count <= totalCount - start else {
                throw PatchWriteError.fileOffsetOutOfRange(address: address)
            }
            let range = start..<(start + bytes.count)
            guard FileAddressMapping.resolvedFileRange(
                forVirtualAddress: address, count: bytes.count, in: sectionMappings
            ) == range, FileAddressMapping.resolvedFileRange(
                forVirtualAddress: address, count: bytes.count, in: segmentMappings
            ) == range else {
                throw PatchWriteError.inconsistentMapping(address: address)
            }
            output.replaceSubrange(range, with: bytes)
        }

        return output
    }

    /// Appends one file-backed executable section to a thin ARM64 executable. The
    /// existing, final `__LINKEDIT` payload is copied after the new RX segment, and
    /// every admitted load-command file offset into that payload is relocated. The
    /// old bytes remain in the prefix for provenance; only the new copy is mapped.
    /// The copied code signature is necessarily invalid after any change. Saving the
    /// returned buffer as an executable requires a separate signing operation.
    /// Unknown offset-bearing commands, non-final linkedit and occupied header slack
    /// fail before any buffer is returned.
    func makePatchedDataWithAppendedExecutableCave(
        originalData: Data,
        patches: [UInt64: BytePatch],
        caveBytes: Data,
        branchSourceAddress: UInt64? = nil
    ) throws -> AppendedExecutableCave {
        guard !caveBytes.isEmpty, caveBytes.count <= 1_048_576,
              caveBytes.count.isMultiple(of: 4) else { throw CaveWriteError.invalidCaveLength }

        // This also rejects fat input and enforces the normal patch mapping contract.
        let originalPatched = try makePatchedData(originalData: originalData, patches: patches)
        let options = MachOParseOptions(
            recoverStringLiterals: false, recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false, parseCodeSignature: false
        )
        let source: MachOFile
        do { source = try MachOParser().parse(originalData, options: options) }
        catch { throw CaveWriteError.unsupportedLayout("source does not parse") }
        guard source.universalBinary == nil,
              source.header.cpuType == MachOConstants.cpuTypeARM64,
              source.header.fileType == MachOConstants.fileTypeExecute else {
            throw CaveWriteError.unsupportedLayout("requires a thin ARM64 executable")
        }

        let page: UInt64 = 0x4000
        func aligned(_ value: UInt64) -> UInt64? {
            let sum = value.addingReportingOverflow(page - 1)
            return sum.overflow ? nil : sum.partialValue & ~(page - 1)
        }
        let links = source.segments.filter { $0.name == "__LINKEDIT" }
        guard links.count == 1, let link = links.first,
              source.segments.last?.name == "__LINKEDIT",
              !source.segments.contains(where: { $0.name == "__MSCAVE" }),
              link.fileSize > 0, link.vmSize >= link.fileSize,
              link.fileOffset <= UInt64(originalPatched.count),
              link.fileSize == UInt64(originalPatched.count) - link.fileOffset,
              link.fileOffset.isMultiple(of: page), link.vmAddress.isMultiple(of: page),
              source.sections.allSatisfy({ $0.segmentName != "__LINKEDIT" }) else {
            throw CaveWriteError.unsupportedLayout("requires one final, sectionless, page-aligned __LINKEDIT")
        }
        let linkEnd = link.vmAddress.addingReportingOverflow(link.vmSize)
        guard !linkEnd.overflow else {
            throw CaveWriteError.unsupportedLayout("__LINKEDIT VM range overflows")
        }
        guard !source.exports.contains(where: { exported in
            guard let address = exported.address else { return false }
            return address >= link.vmAddress && address < linkEnd.partialValue
        }) else {
            throw CaveWriteError.unsupportedLayout("export trie names an address in relocated __LINKEDIT")
        }
        var previousFileEnd: UInt64 = 0
        var previousVMEnd: UInt64 = 0
        for segment in source.segments {
            let fileEnd = segment.fileOffset.addingReportingOverflow(segment.fileSize)
            let vmEnd = segment.vmAddress.addingReportingOverflow(segment.vmSize)
            guard !fileEnd.overflow, !vmEnd.overflow,
                  segment.vmAddress >= previousVMEnd,
                  (segment.fileSize == 0 || segment.fileOffset >= previousFileEnd) else {
                throw CaveWriteError.unsupportedLayout("segment file or VM ranges are unordered or overlapping")
            }
            if segment.fileSize > 0 { previousFileEnd = fileEnd.partialValue }
            previousVMEnd = vmEnd.partialValue
        }
        for segment in source.segments where segment.name != "__LINKEDIT" {
            let fileEnd = segment.fileOffset.addingReportingOverflow(segment.fileSize)
            let vmEnd = segment.vmAddress.addingReportingOverflow(segment.vmSize)
            guard !fileEnd.overflow, !vmEnd.overflow,
                  fileEnd.partialValue <= link.fileOffset,
                  vmEnd.partialValue <= link.vmAddress else {
                throw CaveWriteError.unsupportedLayout("segment overlaps or follows __LINKEDIT")
            }
        }
        guard source.sections.allSatisfy({ $0.relocationCount == 0 }) else {
            throw CaveWriteError.unsupportedLayout("section relocation tables need separate rewriting")
        }

        let chainedRewrite = try Self.chainedCaveRewrite(
            originalPatched, source: source, movedLinkedit: link,
            branchSourceAddress: branchSourceAddress
        )
        let linkGrowth = UInt64(chainedRewrite?.growth ?? 0)
        let grownLinkSize = link.fileSize.addingReportingOverflow(linkGrowth)
        guard !grownLinkSize.overflow, let alignedLinkSize = aligned(grownLinkSize.partialValue) else {
            throw CaveWriteError.unsupportedLayout("grown __LINKEDIT size overflows")
        }
        let newLinkSize = grownLinkSize.partialValue
        let newLinkVMSize = max(link.vmSize, alignedLinkSize)

        // Native sparse decoding reads up to 64 bytes past the authored range.
        // Seal that lookahead as mapped RX zeros even when code fills a page.
        guard let caveOffset = aligned(UInt64(originalPatched.count)),
              let caveFileSize = aligned(UInt64(caveBytes.count) + 64),
              let caveVA = aligned(linkEnd.partialValue) else {
            throw CaveWriteError.unsupportedLayout("cave alignment overflows")
        }
        let linkOffsetSum = caveOffset.addingReportingOverflow(caveFileSize)
        let caveVMEnd = caveVA.addingReportingOverflow(caveFileSize)
        guard !linkOffsetSum.overflow, !caveVMEnd.overflow,
              let newLinkVA = aligned(caveVMEnd.partialValue) else {
            throw CaveWriteError.unsupportedLayout("new segment range overflows")
        }
        let newLinkOffset = linkOffsetSum.partialValue
        let outputEnd = newLinkOffset.addingReportingOverflow(newLinkSize)
        let newLinkVMEnd = newLinkVA.addingReportingOverflow(newLinkVMSize)
        guard !outputEnd.overflow, !newLinkVMEnd.overflow,
              outputEnd.partialValue <= UInt64(Int.max),
              caveOffset <= UInt64(UInt32.max),
              newLinkOffset <= UInt64(UInt32.max),
              outputEnd.partialValue <= UInt64(UInt32.max) else {
            throw CaveWriteError.unsupportedLayout("relocated file or VM address overflows")
        }
        let delta = newLinkOffset - link.fileOffset

        let commandLength = 152 // segment_command_64 + one section_64
        let headerLength = 32
        guard let commandsSize = Int(exactly: source.header.loadCommandsSize),
              commandsSize <= originalPatched.count - headerLength,
              source.loadCommands.count == Int(source.header.loadCommandCount),
              source.header.loadCommandCount < UInt32.max,
              commandsSize <= Int(UInt32.max) - commandLength,
              let last = source.loadCommands.last,
              let lastOffset = Int(exactly: last.offset),
              let lastSize = Int(exactly: last.commandSize),
              lastOffset <= originalPatched.count,
              lastSize <= originalPatched.count - lastOffset,
              lastOffset + lastSize == headerLength + commandsSize else {
            throw CaveWriteError.unsupportedLayout("load-command bounds disagree")
        }
        let commandEnd = headerLength + commandsSize
        let newCommandEnd = commandEnd + commandLength
        guard newCommandEnd <= originalPatched.count,
              let firstSection = source.sections.filter({ !$0.isZeroFill && $0.size > 0 })
                .map({ Int($0.fileOffset) }).min(),
              newCommandEnd <= firstSection,
              source.segments.contains(where: {
                  $0.name == "__TEXT" && $0.fileOffset == 0
                    && $0.fileSize >= UInt64(newCommandEnd)
                    && ($0.initialProtection & 4) != 0
              }),
              originalPatched[commandEnd..<newCommandEnd].allSatisfy({ $0 == 0 }) else {
            throw CaveWriteError.unsupportedLayout("no zero-filled load-command room in __TEXT")
        }
        // Find the actual segment command by its on-disk name. Segment ordering in
        // the parsed model alone is insufficient to select the insertion position.
        guard let linkCommand = source.loadCommands.first(where: {
            guard $0.command == MachOConstants.loadCommandSegment64,
                  let offset = Int(exactly: $0.offset), $0.commandSize >= 72 else { return false }
            return Array(originalPatched[(offset + 8)..<(offset + 18)]) == Array("__LINKEDIT".utf8)
        }), let insertion = Int(exactly: linkCommand.offset) else {
            throw CaveWriteError.unsupportedLayout("__LINKEDIT load command is missing")
        }

        var effectivePatches = patches
        var branchWord: UInt32?
        if let branchSourceAddress {
            guard branchSourceAddress.isMultiple(of: 4),
                  !branchSourceAddress.addingReportingOverflow(4).overflow,
                  source.sections.contains(where: { section in
                      guard section.isExecutableInstructions,
                            branchSourceAddress >= section.address else { return false }
                      let offset = branchSourceAddress - section.address
                      return offset <= section.size && section.size - offset >= 4
                  }) else { throw CaveWriteError.invalidBranchSource }
            let branchEnd = branchSourceAddress + 4
            for (address, patch) in patches where !patch.bytes.isEmpty {
                let end = address.addingReportingOverflow(UInt64(patch.bytes.count))
                guard !end.overflow else { throw CaveWriteError.conflictingBranchPatch }
                if address < branchEnd && branchSourceAddress < end.partialValue {
                    throw CaveWriteError.conflictingBranchPatch
                }
            }
            let positive = caveVA >= branchSourceAddress
            let distance = positive ? caveVA - branchSourceAddress : branchSourceAddress - caveVA
            guard distance.isMultiple(of: 4),
                  distance <= (positive ? 134_217_724 : 134_217_728) else {
                throw CaveWriteError.branchOutOfRange
            }
            let words = Int64(distance / 4) * (positive ? 1 : -1)
            let word = UInt32(0x1400_0000) | (UInt32(truncatingIfNeeded: words) & 0x03ff_ffff)
            branchWord = word
            effectivePatches[branchSourceAddress] = BytePatch(bytes: (0..<4).map {
                UInt8(truncatingIfNeeded: word >> ($0 * 8))
            })
        }
        // Reuse the writer's entire section/segment consistency check for the branch.
        var output = try makePatchedData(originalData: originalData, patches: effectivePatches)
        var newLinkPayload = Data(output[Int(link.fileOffset)..<output.count])
        if let chainedRewrite {
            let start = chainedRewrite.originalRange.lowerBound - Int(link.fileOffset)
            let end = chainedRewrite.originalRange.upperBound - Int(link.fileOffset)
            newLinkPayload.replaceSubrange(start..<end, with: chainedRewrite.payload)
        }

        // Each relocated offset must identify a complete payload in the old final
        // __LINKEDIT. A command with an unfamiliar offset layout is refused.
        func relocated(_ old: UInt32, size: UInt64) throws -> UInt32 {
            if size == 0 {
                if old == 0 { return 0 }
                return try relocatePoint(old)
            }
            guard old != 0, UInt64(old) >= link.fileOffset,
                  UInt64(old) - link.fileOffset <= link.fileSize,
                  size <= link.fileSize - (UInt64(old) - link.fileOffset) else {
                throw CaveWriteError.unsupportedLayout("load command references bytes outside __LINKEDIT")
            }
            if let chainedRewrite {
                let range = UInt64(chainedRewrite.originalRange.lowerBound)..<UInt64(chainedRewrite.originalRange.upperBound)
                guard UInt64(old) + size <= range.lowerBound || UInt64(old) >= range.upperBound else {
                    throw CaveWriteError.unsupportedLayout("linkedit tables overlap chained fixups")
                }
            }
            return try relocatePoint(old)
        }
        func relocatePoint(_ old: UInt32) throws -> UInt32 {
            guard UInt64(old) >= link.fileOffset,
                  UInt64(old) - link.fileOffset <= link.fileSize,
                  UInt64(old) <= UInt64(UInt32.max) - delta - linkGrowth else {
                throw CaveWriteError.unsupportedLayout("linkedit file offset cannot be relocated")
            }
            var growth: UInt64 = 0
            if let chainedRewrite {
                guard !chainedRewrite.originalRange.contains(Int(old)) else {
                    throw CaveWriteError.unsupportedLayout("linkedit offset aliases chained fixups")
                }
                if Int(old) >= chainedRewrite.originalRange.upperBound { growth = linkGrowth }
            }
            return UInt32(UInt64(old) + delta + growth)
        }
        func original32(_ offset: Int) -> UInt32 {
            UInt32(originalPatched[offset]) | (UInt32(originalPatched[offset + 1]) << 8)
                | (UInt32(originalPatched[offset + 2]) << 16)
                | (UInt32(originalPatched[offset + 3]) << 24)
        }
        func original64(_ offset: Int) -> UInt64 {
            UInt64(original32(offset)) | (UInt64(original32(offset + 4)) << 32)
        }
        func rewritePair(_ commandOffset: Int, _ field: Int, elementSize: UInt64 = 1) throws {
            let old = original32(commandOffset + field)
            let count = original32(commandOffset + field + 4)
            let product = UInt64(count).multipliedReportingOverflow(by: elementSize)
            guard !product.overflow else {
                throw CaveWriteError.unsupportedLayout("linkedit table size overflows")
            }
            let moved = try relocated(old, size: product.partialValue)
            Self.writeUInt32LE(moved, into: &output, at: commandOffset + (commandOffset >= insertion ? commandLength : 0) + field)
        }

        // Insert before the __LINKEDIT segment command so segment declaration order
        // remains file/VM ordered. Command offsets at or after it move by 152 bytes.
        let oldTail = Data(output[insertion..<commandEnd])
        var caveCommand = Data()
        func append32(_ value: UInt32) {
            for shift in stride(from: 0, through: 24, by: 8) {
                caveCommand.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        func append64(_ value: UInt64) {
            for shift in stride(from: 0, through: 56, by: 8) {
                caveCommand.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        func appendName(_ name: String) {
            caveCommand.append(contentsOf: name.utf8)
            caveCommand.append(contentsOf: repeatElement(0, count: 16 - name.utf8.count))
        }
        append32(MachOConstants.loadCommandSegment64); append32(UInt32(commandLength))
        appendName("__MSCAVE"); append64(caveVA); append64(caveFileSize)
        append64(caveOffset); append64(caveFileSize)
        append32(5); append32(5); append32(1); append32(0) // RX, one section
        appendName("__text"); appendName("__MSCAVE")
        append64(caveVA); append64(UInt64(caveBytes.count))
        append32(UInt32(caveOffset)); append32(2) // ARM64 instruction alignment
        append32(0); append32(0)
        append32(MachOConstants.sectionAttributePureInstructions | MachOConstants.sectionAttributeSomeInstructions)
        append32(0); append32(0); append32(0)
        guard caveCommand.count == commandLength else { throw CaveWriteError.outputMappingFailed }
        var newCommands = caveCommand
        newCommands.append(oldTail)
        output.replaceSubrange(insertion..<newCommandEnd, with: newCommands)
        Self.writeUInt32LE(source.header.loadCommandCount + 1, into: &output, at: 16)
        Self.writeUInt32LE(UInt32(commandsSize + commandLength), into: &output, at: 20)

        for command in source.loadCommands {
            guard let old = Int(exactly: command.offset),
                  let size = Int(exactly: command.commandSize), old >= headerLength,
                  old <= commandEnd, size <= commandEnd - old else {
                throw CaveWriteError.unsupportedLayout("load-command range is invalid")
            }
            let now = old + (old >= insertion ? commandLength : 0)
            switch command.command {
            case MachOConstants.loadCommandSegment64:
                guard size >= 72 else { throw CaveWriteError.unsupportedLayout("short segment command") }
                if old == insertion {
                    Self.writeUInt64LE(newLinkVA, into: &output, at: now + 24)
                    Self.writeUInt64LE(newLinkOffset, into: &output, at: now + 40)
                    Self.writeUInt64LE(newLinkVMSize, into: &output, at: now + 32)
                    Self.writeUInt64LE(newLinkSize, into: &output, at: now + 48)
                }
            case MachOConstants.loadCommandSymtab:
                guard size >= 24 else { throw CaveWriteError.unsupportedLayout("short symtab command") }
                try rewritePair(old, 8, elementSize: 16)
                try rewritePair(old, 16)
            case MachOConstants.loadCommandDysymtab:
                guard size >= 80 else { throw CaveWriteError.unsupportedLayout("short dysymtab command") }
                for (field, width) in [(32, UInt64(8)), (40, 56), (48, 4), (56, 4), (64, 8), (72, 8)] {
                    try rewritePair(old, field, elementSize: width)
                }
            case MachOConstants.loadCommandDyldInfo, MachOConstants.loadCommandDyldInfoOnly:
                guard size >= 48 else { throw CaveWriteError.unsupportedLayout("short dyld-info command") }
                // A new segment is inserted before __LINKEDIT. Existing ordinal
                // references to preceding segments remain stable; any reference
                // to the old __LINKEDIT ordinal or an unknown opcode is refused.
                // dyld numbers segments by LC_SEGMENT_64 command order, so count the
                // commands that precede __LINKEDIT rather than the parsed model.
                let movedSegmentOrdinal = source.loadCommands.filter {
                    $0.command == MachOConstants.loadCommandSegment64 && $0.offset < linkCommand.offset
                }.count
                for field in stride(from: 8, through: 32, by: 8) {
                    try Self.validateDyldInfoStream(
                        originalPatched, offset: original32(old + field),
                        size: original32(old + field + 4),
                        rebase: field == 8, movedSegmentOrdinal: movedSegmentOrdinal
                    )
                }
                try Self.validateExportTrieTargets(
                    originalPatched, offset: original32(old + 40),
                    size: original32(old + 44),
                    imageBase: source.segments.first(where: { $0.name == "__TEXT" })?.vmAddress ?? 0,
                    movedRange: link.vmAddress..<linkEnd.partialValue
                )
                for field in stride(from: 8, through: 40, by: 8) { try rewritePair(old, field) }
            case MachOConstants.loadCommandCodeSignature,
                 MachOConstants.loadCommandDyldExportsTrie,
                 MachOConstants.loadCommandFunctionStarts,
                 MachOConstants.loadCommandDataInCode,
                 0x2b: // dylib code-sign DRs
                guard size >= 16 else { throw CaveWriteError.unsupportedLayout("short linkedit-data command") }
                if command.command == MachOConstants.loadCommandDyldExportsTrie {
                    try Self.validateExportTrieTargets(
                        originalPatched, offset: original32(old + 8),
                        size: original32(old + 12),
                        imageBase: source.segments.first(where: { $0.name == "__TEXT" })?.vmAddress ?? 0,
                        movedRange: link.vmAddress..<linkEnd.partialValue
                    )
                }
                try rewritePair(old, 8)
                if command.command == MachOConstants.loadCommandCodeSignature {
                    let oldOffset = original32(old + 8)
                    let oldSize = original32(old + 12)
                    guard oldSize > 0, UInt64(oldOffset) + UInt64(oldSize) == UInt64(originalPatched.count) else {
                        throw CaveWriteError.unsupportedLayout("code signature is not the final linkedit payload")
                    }
                }
            case MachOConstants.loadCommandDyldChainedFixups:
                guard size >= 16, let chainedRewrite else {
                    throw CaveWriteError.unsupportedLayout("missing chained-fixups rewrite")
                }
                let moved = UInt64(chainedRewrite.originalRange.lowerBound) + delta
                Self.writeUInt32LE(UInt32(moved), into: &output, at: now + 8)
                Self.writeUInt32LE(UInt32(chainedRewrite.payload.count), into: &output, at: now + 12)
            case 0x1e, 0x2e: // segment split info and linker optimization hints
                throw CaveWriteError.unsupportedLayout("linkedit metadata may encode segment ordinals")
            case MachOConstants.loadCommandMain:
                guard size >= 24 else { throw CaveWriteError.unsupportedLayout("short main command") }
                // entryoff is an executable-file offset; moving it would be wrong.
                guard original64(old + 8) < link.fileOffset else {
                    throw CaveWriteError.unsupportedLayout("entry point lies in __LINKEDIT")
                }
            case MachOConstants.loadCommandUUID, MachOConstants.loadCommandBuildVersion,
                 MachOConstants.loadCommandSourceVersion, MachOConstants.loadCommandRPath,
                 MachOConstants.loadCommandLoadDylib, MachOConstants.loadCommandLoadWeakDylib,
                 MachOConstants.loadCommandReexportDylib, MachOConstants.loadCommandLoadUpwardDylib,
                 MachOConstants.loadCommandLazyLoadDylib,
                 MachOConstants.loadCommandVersionMinMacOSX,
                 MachOConstants.loadCommandVersionMinIPhoneOS,
                 MachOConstants.loadCommandVersionMinTVOS,
                 MachOConstants.loadCommandVersionMinWatchOS,
                 0xe, 0xf, 0x27: // dyld loader and LC_DYLD_ENVIRONMENT
                break
            default:
                throw CaveWriteError.unsupportedLayout("unrecognized file-offset load command \(command.name)")
            }
        }
        guard source.loadCommands.filter({ $0.command == MachOConstants.loadCommandCodeSignature }).count == 1 else {
            throw CaveWriteError.unsupportedLayout("requires one code-signature command")
        }

        output.append(contentsOf: repeatElement(0, count: Int(caveOffset) - output.count))
        output.append(caveBytes)
        output.append(contentsOf: repeatElement(0, count: Int(caveFileSize) - caveBytes.count))
        output.append(newLinkPayload)
        guard output.count == Int(outputEnd.partialValue) else { throw CaveWriteError.outputMappingFailed }

        let reparsed: MachOFile
        do { reparsed = try MachOParser().parse(output, options: options) }
        catch { throw CaveWriteError.outputMappingFailed }
        guard reparsed.segments.count == source.segments.count + 1,
              reparsed.sections.count == source.sections.count + 1,
              reparsed.exports == source.exports,
              reparsed.segments.contains(where: {
                  $0.name == "__MSCAVE" && $0.vmAddress == caveVA
                      && $0.fileOffset == caveOffset && $0.fileSize == caveFileSize
                      && $0.initialProtection == 5
              }),
              reparsed.segments.contains(where: {
                  $0.name == "__LINKEDIT" && $0.vmAddress == newLinkVA
                      && $0.fileOffset == newLinkOffset && $0.fileSize == newLinkSize
                      && $0.vmSize == newLinkVMSize
              }),
              reparsed.sections.contains(where: {
                  $0.segmentName == "__MSCAVE" && $0.address == caveVA
                      && $0.size == UInt64(caveBytes.count)
                      && $0.fileOffset == UInt32(caveOffset)
                      && $0.isExecutableInstructions
              }),
              reparsed.virtualAddress(forFileOffset: caveOffset) == caveVA else {
            throw CaveWriteError.outputMappingFailed
        }
        return AppendedExecutableCave(
            data: output, virtualAddress: caveVA, fileOffset: caveOffset,
            byteCount: caveBytes.count, branchSourceAddress: branchSourceAddress,
            branchInstruction: branchWord
        )
    }

    private struct ChainedCaveRewrite {
        let originalRange: Range<Int>
        let payload: Data
        // One UInt32 entry plus padding: preserve all existing 8/16-byte alignments.
        var growth: Int { payload.count - originalRange.count }
    }

    /// Admits only generic ARM64 64-bit chains whose locations and targets remain
    /// fixed. The starts records and chain words are copied exactly, never rebuilt
    /// from the parser's best-effort semantic projection.
    /// Layout authority: Apple's mach-o/fixup-chains.h (dyld_chained_* structures).
    private static func chainedCaveRewrite(
        _ data: Data, source: MachOFile, movedLinkedit link: MachOSegment,
        branchSourceAddress: UInt64?
    ) throws -> ChainedCaveRewrite? {
        let commands = source.loadCommands.filter { $0.command == MachOConstants.loadCommandDyldChainedFixups }
        guard !commands.isEmpty else { return nil }
        func refusal(_ reason: String) -> CaveWriteError {
            .unsupportedLayout("chained fixups: \(reason)")
        }
        guard commands.count == 1, let command = commands.first,
              command.commandSize >= 16, let commandOffset = Int(exactly: command.offset),
              commandOffset >= 0, commandOffset <= data.count, data.count - commandOffset >= 16 else {
            throw refusal("requires one complete load command")
        }
        func u16(_ position: Int) -> UInt16 {
            UInt16(data[position]) | UInt16(data[position + 1]) << 8
        }
        func u32(_ position: Int) -> UInt32 {
            UInt32(u16(position)) | UInt32(u16(position + 2)) << 16
        }
        func u64(_ position: Int) -> UInt64 {
            UInt64(u32(position)) | UInt64(u32(position + 4)) << 32
        }
        let start = Int(u32(commandOffset + 8)), length = Int(u32(commandOffset + 12))
        guard start >= Int(link.fileOffset), start <= data.count, length >= 28,
              length <= data.count - start, length <= Int(UInt32.max) - 16 else {
            throw refusal("payload leaves __LINKEDIT")
        }
        let end = start + length
        let starts = Int(u32(start + 4)), imports = Int(u32(start + 8)), symbols = Int(u32(start + 12))
        let importCount = Int(u32(start + 16)), importFormat = u32(start + 20)
        guard u32(start) == 0, u32(start + 24) == 0 else {
            throw refusal("unknown version or compressed symbols")
        }
        let importWidth: Int
        switch importFormat {
        case 1: importWidth = 4
        case 2: importWidth = 8
        case 3: importWidth = 16
        default: throw refusal("unsupported imports format \(importFormat)")
        }
        guard starts >= 28, starts <= length - 4,
              imports >= starts + 4, imports <= length,
              symbols >= imports, symbols <= length,
              importCount <= (symbols - imports) / importWidth else {
            throw refusal("header table extents overlap or leave payload")
        }
        let startsBase = start + starts
        let segmentCount = Int(u32(startsBase))
        guard segmentCount == source.segments.count, segmentCount > 0,
              segmentCount <= (imports - starts - 4) / 4,
              let imageBase = source.segments.first(where: { $0.name == "__TEXT" && $0.fileOffset == 0 })?.vmAddress else {
            throw refusal("starts segment count disagrees with load commands")
        }
        let tableEnd = startsBase + 4 + segmentCount * 4
        guard u32(startsBase + 4 + (segmentCount - 1) * 4) == 0 else {
            throw refusal("relocated __LINKEDIT has chain starts")
        }
        // Import entries and symbol names are retained, including explicit addends.
        for index in 0..<importCount {
            let entry = start + imports + index * importWidth
            let nameOffset: Int
            if importFormat == 3 {
                guard (u64(entry) >> 17) & 0x7fff == 0 else {
                    throw refusal("reserved import bits are set")
                }
                nameOffset = Int(u32(entry + 4))
            } else {
                nameOffset = Int(u32(entry) >> 9)
            }
            guard nameOffset < length - symbols,
                  data[(start + symbols + nameOffset)..<end].contains(0) else {
                throw refusal("import name is outside the symbol pool or unterminated")
            }
        }
        var recordRanges: [Range<Int>] = []
        var visited: Set<Int> = []
        let movedEnd = link.vmAddress + link.vmSize // checked by caller
        for ordinal in 0..<segmentCount {
            let relative = Int(u32(startsBase + 4 + ordinal * 4))
            if relative == 0 { continue }
            guard relative >= tableEnd - startsBase, relative <= imports - starts - 22 else {
                throw refusal("segment starts record leaves the starts pool")
            }
            let record = startsBase + relative
            let size = Int(u32(record)), pageSize = Int(u16(record + 4)), format = u16(record + 6)
            let pageCount = Int(u16(record + 20))
            guard size >= 22, size <= start + imports - record, size.isMultiple(of: 2),
                  pageCount <= (size - 22) / 2,
                  pageSize == 0x1000 || pageSize == 0x4000 else {
                throw refusal("invalid segment starts extent or page size")
            }
            guard format == 2 || format == 6 else {
                throw refusal("unsupported pointer format \(format)")
            }
            let segment = source.segments[ordinal]
            guard segment.vmAddress >= imageBase,
                  u64(record + 8) == segment.vmAddress - imageBase,
                  u32(record + 16) == 0,
                  UInt64(pageCount) <= (segment.vmSize / UInt64(pageSize)) + (segment.vmSize % UInt64(pageSize) == 0 ? 0 : 1) else {
                throw refusal("segment starts geometry disagrees with its segment")
            }
            recordRanges.append(record..<(record + size))
            let entryCount = (size - 22) / 2
            for pageIndex in 0..<pageCount {
                let first = u16(record + 22 + pageIndex * 2)
                if first == 0xffff { continue }
                var startsOnPage: [UInt16] = []
                if first & 0x8000 != 0 {
                    var index = Int(first & 0x7fff)
                    guard index >= pageCount else { throw refusal("overflow starts index aliases page starts") }
                    while true {
                        guard index < entryCount else { throw refusal("unterminated overflow starts") }
                        let value = u16(record + 22 + index * 2)
                        startsOnPage.append(value & 0x7fff)
                        index += 1
                        if value & 0x8000 != 0 { break }
                    }
                } else {
                    startsOnPage = [first]
                }
                let pageOffset = UInt64(pageIndex) * UInt64(pageSize)
                for firstOffset in startsOnPage {
                    var cursor = Int(firstOffset)
                    while true {
                        let mappedSize = min(segment.fileSize, segment.vmSize)
                        guard cursor.isMultiple(of: 4), cursor <= pageSize - 8,
                              pageOffset + UInt64(cursor) <= mappedSize,
                              mappedSize - pageOffset - UInt64(cursor) >= 8 else {
                            throw refusal("chain leaves its file-backed page")
                        }
                        let position64 = segment.fileOffset + pageOffset + UInt64(cursor)
                        guard position64 <= UInt64(data.count), UInt64(data.count) - position64 >= 8,
                              visited.count < MachOConstants.dyldChainedMaxFixups else {
                            throw refusal("chain file extent or traversal bound is invalid")
                        }
                        let position = Int(position64)
                        guard visited.insert(position).inserted else { throw refusal("chain starts overlap") }
                        // Load commands will change, so chain words cannot live in the header.
                        guard position >= 32 + Int(source.header.loadCommandsSize) + 152 else {
                            throw refusal("chain overlaps rewritten load commands")
                        }
                        if let branchSourceAddress {
                            let address = segment.vmAddress + pageOffset + UInt64(cursor)
                            guard branchSourceAddress >= address + 8 ||
                                    (branchSourceAddress < address && address - branchSourceAddress >= 4) else {
                                throw refusal("branch patch overlaps a chain word")
                            }
                        }
                        let raw = u64(position)
                        if raw >> 63 != 0 {
                            guard (raw >> 32) & 0x7ffff == 0, Int(raw & 0xffffff) < importCount else {
                                throw refusal("bind ordinal or reserved bits are invalid")
                            }
                        } else {
                            guard (raw >> 44) & 0x7f == 0 else { throw refusal("reserved rebase bits are set") }
                            let lowTarget = raw & 0xf_ffff_ffff
                            let target = (format == 6 ? imageBase : 0).addingReportingOverflow(lowTarget)
                            guard !target.overflow,
                                  target.partialValue < link.vmAddress || target.partialValue >= movedEnd else {
                                throw refusal("rebase target lies in relocated __LINKEDIT or overflows")
                            }
                        }
                        let next = Int((raw >> 51) & 0xfff) * 4
                        if next == 0 { break }
                        guard next >= 8, next <= pageSize - cursor - 8 else {
                            throw refusal("chain delta overlaps a pointer or leaves its page")
                        }
                        cursor += next
                    }
                }
            }
        }
        let ordered = recordRanges.sorted { $0.lowerBound < $1.lowerBound }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.upperBound > pair.1.lowerBound {
            throw refusal("segment starts records overlap")
        }
        // Keep all segment records, page/overflow starts, imports and strings exact.
        // Only header offsets and seg_info_offset[] move; the new cave has no fixups.
        var payload = Data(data[start..<end])
        payload.insert(contentsOf: repeatElement(UInt8(0), count: 16), at: tableEnd - start)
        writeUInt32LE(UInt32(segmentCount + 1), into: &payload, at: starts)
        for ordinal in 0..<(segmentCount - 1) {
            let relative = u32(startsBase + 4 + ordinal * 4)
            writeUInt32LE(relative == 0 ? 0 : relative + 16, into: &payload, at: starts + 4 + ordinal * 4)
        }
        // The old final zero slot now belongs to __MSCAVE; inserted zeros contain
        // the relocated __LINKEDIT slot, then twelve alignment bytes.
        writeUInt32LE(UInt32(imports + 16), into: &payload, at: 8)
        writeUInt32LE(UInt32(symbols + 16), into: &payload, at: 12)
        return ChainedCaveRewrite(originalRange: start..<end, payload: payload)
    }

    /// Validates the classic dyld-info rebase/bind bytecode without changing it. The
    /// inserted segment comes immediately before the old, final __LINKEDIT segment.
    /// Threaded bind opcodes and unknown extensions require a separate rewrite.
    private static func validateDyldInfoStream(
        _ data: Data, offset: UInt32, size: UInt32, rebase: Bool,
        movedSegmentOrdinal: Int
    ) throws {
        guard size > 0 else { return }
        let start = Int(offset)
        let length = Int(size)
        guard start > 0, start <= data.count, length <= data.count - start else {
            throw CaveWriteError.unsupportedLayout("dyld-info stream leaves the file")
        }
        let end = start + length
        var cursor = start
        func skipLEB() throws {
            for _ in 0..<10 {
                guard cursor < end else { throw CaveWriteError.unsupportedLayout("truncated dyld-info operand") }
                let byte = data[cursor]
                cursor += 1
                if byte & 0x80 == 0 { return }
            }
            throw CaveWriteError.unsupportedLayout("dyld-info operand is too long")
        }
        while cursor < end {
            let byte = data[cursor]
            cursor += 1
            let opcode = byte & 0xf0
            let immediate = Int(byte & 0x0f)
            if rebase {
                switch opcode {
                case 0x00, 0x10, 0x40, 0x50: break
                case 0x20:
                    guard immediate < movedSegmentOrdinal else {
                        throw CaveWriteError.unsupportedLayout("rebase targets relocated __LINKEDIT")
                    }
                    try skipLEB()
                case 0x30, 0x60, 0x70: try skipLEB()
                case 0x80: try skipLEB(); try skipLEB()
                default: throw CaveWriteError.unsupportedLayout("unknown dyld rebase opcode")
                }
            } else {
                switch opcode {
                case 0x00, 0x10, 0x30, 0x50, 0x90, 0xb0: break
                case 0x20, 0x60, 0x80, 0xa0: try skipLEB()
                case 0x40:
                    guard let zero = data[cursor..<end].firstIndex(of: 0) else {
                        throw CaveWriteError.unsupportedLayout("unterminated dyld bind symbol")
                    }
                    cursor = zero + 1
                case 0x70:
                    guard immediate < movedSegmentOrdinal else {
                        throw CaveWriteError.unsupportedLayout("bind targets relocated __LINKEDIT")
                    }
                    try skipLEB()
                case 0xc0: try skipLEB(); try skipLEB()
                default: throw CaveWriteError.unsupportedLayout("unknown or threaded dyld bind opcode")
                }
            }
        }
    }

    /// Parse every reachable raw export-trie terminal. The general Mach-O model merges
    /// exports by name with the symbol table and caps recovery, so that model cannot
    /// establish that *all* trie addresses avoid the moved __LINKEDIT range.
    private static func validateExportTrieTargets(
        _ data: Data, offset: UInt32, size: UInt32,
        imageBase: UInt64, movedRange: Range<UInt64>
    ) throws {
        guard size > 0 else { return }
        let start = Int(offset)
        let length = Int(size)
        guard start > 0, start <= data.count, length <= data.count - start else {
            throw CaveWriteError.unsupportedLayout("export trie leaves the file")
        }
        let end = start + length
        var pending = [0]
        var visited = Set<Int>()
        func readULEB(_ cursor: inout Int, limit: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard cursor < limit else { throw CaveWriteError.unsupportedLayout("truncated export trie operand") }
                let byte = data[cursor]
                cursor += 1
                if index == 9 && byte > 1 {
                    throw CaveWriteError.unsupportedLayout("export trie operand overflows")
                }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte & 0x80 == 0 { return value }
            }
            throw CaveWriteError.unsupportedLayout("export trie operand is too long")
        }
        func checkAddress(_ value: UInt64, absolute: Bool) throws {
            let address: UInt64
            if absolute {
                address = value
            } else {
                let sum = imageBase.addingReportingOverflow(value)
                guard !sum.overflow else {
                    throw CaveWriteError.unsupportedLayout("export trie address overflows")
                }
                address = sum.partialValue
            }
            guard !movedRange.contains(address) else {
                throw CaveWriteError.unsupportedLayout("export trie targets relocated __LINKEDIT")
            }
        }
        while let relative = pending.popLast() {
            guard relative >= 0, relative < length else {
                throw CaveWriteError.unsupportedLayout("export trie child leaves payload")
            }
            guard visited.insert(relative).inserted else { continue }
            guard visited.count <= 16_384 else {
                throw CaveWriteError.unsupportedLayout("export trie exceeds bounded traversal")
            }
            var cursor = start + relative
            let terminalSize = try readULEB(&cursor, limit: end)
            guard terminalSize <= UInt64(end - cursor) else {
                throw CaveWriteError.unsupportedLayout("export trie terminal leaves payload")
            }
            let terminalEnd = cursor + Int(terminalSize)
            if terminalSize > 0 {
                let flags = try readULEB(&cursor, limit: terminalEnd)
                if flags & MachOConstants.exportSymbolFlagsReexport != 0 {
                    _ = try readULEB(&cursor, limit: terminalEnd)
                    if cursor < terminalEnd {
                        guard let zero = data[cursor..<terminalEnd].firstIndex(of: 0) else {
                            throw CaveWriteError.unsupportedLayout("unterminated reexport name")
                        }
                        cursor = zero + 1
                    }
                } else {
                    let kind = flags & 0x3
                    guard kind <= 2 else {
                        throw CaveWriteError.unsupportedLayout("unknown export trie address kind")
                    }
                    try checkAddress(readULEB(&cursor, limit: terminalEnd), absolute: kind == 2)
                    if flags & MachOConstants.exportSymbolFlagsStubAndResolver != 0 {
                        try checkAddress(readULEB(&cursor, limit: terminalEnd), absolute: false)
                    }
                }
                guard cursor == terminalEnd else {
                    throw CaveWriteError.unsupportedLayout("unrecognized export trie terminal data")
                }
            }
            cursor = terminalEnd
            guard cursor < end else { continue }
            let childCount = Int(data[cursor])
            cursor += 1
            for _ in 0..<childCount {
                guard let zero = data[cursor..<end].firstIndex(of: 0) else {
                    throw CaveWriteError.unsupportedLayout("unterminated export trie edge")
                }
                cursor = zero + 1
                let child = try readULEB(&cursor, limit: end)
                guard child < UInt64(length) else {
                    throw CaveWriteError.unsupportedLayout("export trie child offset leaves payload")
                }
                pending.append(Int(child))
            }
        }
    }

    private static func writeUInt32LE(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private static func writeUInt64LE(_ value: UInt64, into data: inout Data, at offset: Int) {
        for index in 0..<8 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    // MARK: - VA → file offset

    /// The file offset for `virtualAddress`, requiring that `runLength` bytes starting there
    /// fit entirely within the FILE CONTENT of the segment it lands in. Returns nil if the
    /// address maps to no file-backed segment OR the run would spill past that segment's file
    /// bytes (the caller turns nil into the right typed error by re-checking containment).
    ///
    /// This is the inverse of `MachOFile.virtualAddress(forFileOffset:)`, with the extra
    /// run-length containment the loader's read-side projection doesn't need.
    private func fileOffset(forVirtualAddress virtualAddress: UInt64, in machO: MachOFile, runLength: Int) -> UInt64? {
        guard let segment = containingFileBackedSegment(forVirtualAddress: virtualAddress, in: machO) else {
            return nil
        }
        let offsetIntoSegment = virtualAddress - segment.vmAddress
        // The patch must fit within the part of the segment that is BACKED BY FILE BYTES
        // (fileSize), not the full vmSize — the tail of a segment past fileSize is zero-fill
        // with no on-disk storage to overwrite.
        let runEnd = offsetIntoSegment.addingReportingOverflow(UInt64(runLength))
        guard !runEnd.overflow, runEnd.partialValue <= segment.fileSize else {
            return nil
        }
        // Checked: a hostile `fileOffset` near UInt64.max would otherwise TRAP this addition.
        let mapped = segment.fileOffset.addingReportingOverflow(offsetIntoSegment)
        guard !mapped.overflow else { return nil }
        return mapped.partialValue
    }

    /// The file-backed segment whose virtual-address range CONTAINS `virtualAddress`, or nil.
    /// A segment with no file content (`fileSize == 0`, e.g. a pure `__PAGEZERO`) is skipped —
    /// it has no on-disk bytes to patch. The containment test uses `fileSize` for the upper
    /// bound (the file-backed span), so an address in a segment's zero-fill tail is excluded.
    private func containingFileBackedSegment(forVirtualAddress virtualAddress: UInt64, in machO: MachOFile) -> MachOSegment? {
        for segment in machO.segments where segment.fileSize > 0 {
            let lower = segment.vmAddress
            // Checked: a hostile segment whose `vmAddress + fileSize` overflows UInt64 would
            // otherwise TRAP here. A segment whose VM range wraps is malformed — skip it.
            let upper = segment.vmAddress.addingReportingOverflow(segment.fileSize)
            if !upper.overflow, virtualAddress >= lower, virtualAddress < upper.partialValue {
                return segment
            }
        }
        return nil
    }

    // MARK: - Magic

    /// Reads the 4-byte big-endian magic, throwing `.notMachO` for a buffer too small to hold
    /// one. (Mach-O thin magics are stored little-endian on disk but compared after a BE read
    /// against the fat magics, mirroring `MachOParser`; the thin/fat discrimination here only
    /// needs the fat magics, which ARE big-endian on disk.)
    private func readBigEndianMagic(_ data: Data) throws -> UInt32 {
        guard data.count >= 4 else {
            throw PatchWriteError.notMachO(reason: "file is shorter than a 4-byte magic")
        }
        let base = data.startIndex
        let b0 = UInt32(data[base])
        let b1 = UInt32(data[base + 1])
        let b2 = UInt32(data[base + 2])
        let b3 = UInt32(data[base + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
