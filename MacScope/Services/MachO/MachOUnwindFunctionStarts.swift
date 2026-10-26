import Foundation

/// HS-12 (string-analysis pass, finding A3): function starts derived from compact unwind info
/// (`__TEXT,__unwind_info`), cross-checked against LC_FUNCTION_STARTS.
///
/// Evidence only. A disagreement becomes a per-image `MachOLoaderFinding` (surfaced as a
/// Problems-panel warning); it never adds, removes or moves a function start, so discovery and
/// every analysis result are unchanged.
///
/// One direction is reported: an unwind entry whose function offset LC_FUNCTION_STARTS does not
/// list. The reverse is expected and not reported: ld64 folds consecutive functions with
/// identical encodings into one unwind entry, so LC_FUNCTION_STARTS legitimately lists starts
/// the unwind table omits. `__eh_frame` is not walked separately: in a linked image a function
/// that unwinds through DWARF still has an `__unwind_info` entry (DWARF mode) at its start.
enum MachOUnwindFunctionStarts {
    /// UNWIND_SECTION_VERSION.
    static let sectionVersion: UInt32 = 1
    /// UNWIND_SECOND_LEVEL_REGULAR / UNWIND_SECOND_LEVEL_COMPRESSED.
    static let regularPageKind: UInt32 = 2
    static let compressedPageKind: UInt32 = 3
    static let maximumIndexEntries = 1 << 20
    /// Upper bound on second-level entries visited (not unique offsets), so index entries that all
    /// point at one large page cannot turn a small section into an unbounded walk.
    static let maximumScannedEntries = 4_000_000
    /// Disagreements named individually per image; any beyond are counted in one summary row.
    static let maximumNamedDisagreements = 16

    /// A resolved metadata range, in image-base-relative offsets. The last upper bound is
    /// retained exactly from the first-level sentinel, even when it is not instruction aligned.
    struct ResolvedRow: Equatable, Sendable {
        let range: Range<UInt32>
        let encoding: UInt32
        let sourceSectionOffset: UInt32
        /// Present only when this row continues a preceding function's metadata.
        var ownerFunctionOffset: UInt32? = nil
        var lsdaImageOffset: UInt32? = nil
        var lsdaSourceSectionRange: Range<UInt32>? = nil
        /// Signed image-base-relative offset of the personality pointer slot, not the routine.
        var personalitySlotImageOffset: Int32? = nil
        var personalitySourceSectionRange: Range<UInt32>? = nil

        var functionStartOffset: UInt32 { ownerFunctionOffset ?? range.lowerBound }
        var isFunctionContinuation: Bool { encoding & 0x8000_0000 != 0 }

        var dwarfFDESectionOffset: UInt32? {
            encoding & 0x0f00_0000 == 0x0300_0000 ? encoding & 0x00ff_ffff : nil
        }
    }

    /// Resolves regular and compressed ARM64 compact-unwind entries without changing the
    /// older offset-only evidence API. Nil means an unsupported or malformed table; unknown
    /// encoding modes and zero encodings remain available for the caller to classify.
    static func resolvedRows(in data: Data, section: MachOSection) -> [ResolvedRow]? {
        guard section.fileOffset != 0,
              ![UInt32(1), 0x0c, 0x12].contains(section.flags & 0xff),
              let sectionStart = Int(exactly: section.fileOffset),
              let sectionSize = Int(exactly: section.size),
              sectionSize >= 28, sectionStart <= data.count,
              sectionSize <= data.count - sectionStart else { return nil }
        let reader = SectionReader(data: data, start: sectionStart, size: sectionSize)
        guard reader.u32(0) == sectionVersion,
              let commonOffset = reader.u32(4).map(Int.init),
              let commonCount = reader.u32(8).map(Int.init), commonCount <= 256,
              let personalityOffset = reader.u32(12).map(Int.init),
              let personalityCount = reader.u32(16).map(Int.init), personalityCount <= 3,
              let indexOffset = reader.u32(20).map(Int.init),
              let indexCount = reader.u32(24).map(Int.init),
              indexCount <= maximumIndexEntries else { return nil }

        var claims: [Range<Int>] = []
        func claim(_ offset: Int, _ size: Int) -> Bool {
            guard offset >= 0, offset <= sectionSize, size <= sectionSize - offset else { return false }
            if size > 0 {
                guard offset >= 28, offset % 4 == 0 else { return false }
                claims.append(offset..<(offset + size))
            }
            return true
        }
        guard claim(commonOffset, commonCount * 4),
              claim(personalityOffset, personalityCount * 4),
              claim(indexOffset, indexCount * 12) else { return nil }
        var common: [UInt32] = []
        for index in 0..<commonCount {
            guard let encoding = reader.u32(commonOffset + index * 4) else { return nil }
            common.append(encoding)
        }
        var indices: [(low: UInt32, page: Int, lsda: Int)] = []
        for index in 0..<indexCount {
            let location = indexOffset + index * 12
            guard let low = reader.u32(location),
                  let page = reader.u32(location + 4).map(Int.init),
                  let lsda = reader.u32(location + 8).map(Int.init),
                  lsda % 4 == 0, lsda <= sectionSize else { return nil }
            if let previous = indices.last {
                guard low > previous.low, lsda >= previous.lsda else { return nil }
            }
            if index == indexCount - 1 {
                guard page == 0 else { return nil }
            } else {
                guard page != 0, low % 4 == 0 else { return nil }
            }
            indices.append((low, page, lsda))
        }
        var entries: [(offset: UInt32, encoding: UInt32, source: UInt32)] = []
        var lsdas: [UInt32: (offset: UInt32, source: UInt32)] = [:]
        for index in 0..<max(0, indices.count - 1) {
            let current = indices[index]
            let next = indices[index + 1]
            let lsdaSize = next.lsda - current.lsda
            guard lsdaSize % 8 == 0, lsdaSize / 8 <= maximumScannedEntries - lsdas.count,
                  claim(current.lsda, lsdaSize) else { return nil }
            var previousLSDAFunction: UInt32?
            for item in 0..<(lsdaSize / 8) {
                let location = current.lsda + item * 8
                guard let function = reader.u32(location),
                      let offset = reader.u32(location + 4), offset != 0,
                      let source = UInt32(exactly: location),
                      UInt32(exactly: location + 8) != nil,
                      function >= current.low, function < next.low,
                      previousLSDAFunction.map({ function > $0 }) ?? true,
                      lsdas[function] == nil else { return nil }
                lsdas[function] = (offset, source)
                previousLSDAFunction = function
            }
            let page = current.page
            guard let kind = reader.u32(page),
                  let entryOffset = reader.u16(page + 4).map(Int.init),
                  let entryCount = reader.u16(page + 6).map(Int.init), entryCount > 0,
                  entryCount <= maximumScannedEntries - entries.count else { return nil }
            let headerSize: Int
            let stride: Int
            var local: [UInt32] = []
            switch kind {
            case regularPageKind:
                headerSize = 8
                stride = 8
            case compressedPageKind:
                headerSize = 12
                stride = 4
                guard let encodingOffset = reader.u16(page + 8).map(Int.init),
                      let encodingCount = reader.u16(page + 10).map(Int.init),
                      commonCount + encodingCount <= 256,
                      encodingOffset <= 4096,
                      encodingCount * 4 <= 4096 - encodingOffset,
                      encodingCount == 0 || encodingOffset >= headerSize,
                      claim(page + encodingOffset, encodingCount * 4) else { return nil }
                for item in 0..<encodingCount {
                    guard let encoding = reader.u32(page + encodingOffset + item * 4) else { return nil }
                    local.append(encoding)
                }
            default:
                return nil
            }
            guard claim(page, headerSize), entryOffset >= headerSize, entryOffset <= 4096,
                  entryCount * stride <= 4096 - entryOffset,
                  claim(page + entryOffset, entryCount * stride) else { return nil }
            var previous: UInt32?
            for item in 0..<entryCount {
                let location = page + entryOffset + item * stride
                guard let raw = reader.u32(location), let source = UInt32(exactly: location) else { return nil }
                let offset: UInt32
                let encoding: UInt32
                if kind == regularPageKind {
                    offset = raw
                    guard let word = reader.u32(location + 4) else { return nil }
                    encoding = word
                } else {
                    let (resolved, overflow) = current.low.addingReportingOverflow(raw & 0x00ff_ffff)
                    guard !overflow else { return nil }
                    offset = resolved
                    let encodingIndex = Int(raw >> 24)
                    if encodingIndex < common.count {
                        encoding = common[encodingIndex]
                    } else {
                        let localIndex = encodingIndex - common.count
                        guard localIndex < local.count else { return nil }
                        encoding = local[localIndex]
                    }
                }
                guard offset >= current.low, offset < next.low, offset % 4 == 0,
                      item != 0 || offset == current.low,
                      previous.map({ offset > $0 }) ?? true,
                      Int((encoding >> 28) & 3) <= personalityCount else { return nil }
                entries.append((offset, encoding, source))
                previous = offset
            }
        }
        var previousEnd = 28
        for range in claims.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= previousEnd else { return nil }
            previousEnd = range.upperBound
        }
        guard let sentinel = indices.last?.low else { return [] }
        var rows: [ResolvedRow] = []
        var owner: UInt32?
        for (index, entry) in entries.enumerated() {
            let end = index + 1 < entries.count ? entries[index + 1].offset : sentinel
            var row = ResolvedRow(range: entry.offset..<end, encoding: entry.encoding,
                                  sourceSectionOffset: entry.source)
            if row.isFunctionContinuation {
                guard let owner else { return nil }
                row.ownerFunctionOffset = owner
            } else {
                owner = entry.offset
            }
            let lsda = lsdas.removeValue(forKey: entry.offset)
            guard (entry.encoding & 0x4000_0000 != 0) == (lsda != nil) else { return nil }
            if let lsda {
                row.lsdaImageOffset = lsda.offset
                row.lsdaSourceSectionRange = lsda.source..<(lsda.source + 8)
            }
            let personalityIndex = Int((entry.encoding >> 28) & 3)
            if personalityIndex > 0 {
                let location = personalityOffset + (personalityIndex - 1) * 4
                guard let raw = reader.u32(location),
                      let source = UInt32(exactly: location),
                      UInt32(exactly: location + 4) != nil else { return nil }
                row.personalitySlotImageOffset = Int32(bitPattern: raw)
                row.personalitySourceSectionRange = source..<(source + 4)
            }
            rows.append(row)
        }
        guard lsdas.isEmpty else { return nil }
        return rows
    }

    /// Cross-check findings for one parsed image. Empty when the image has no LC_FUNCTION_STARTS
    /// command (`hasFunctionStartsCommand == false`), no readable version-1 `__unwind_info`, or a
    /// function-start list truncated at the recovery cap.
    static func findings(
        in data: Data,
        sections: [MachOSection],
        segments: [MachOSegment],
        functionStarts: [MachOFunctionStart],
        hasFunctionStartsCommand: Bool
    ) -> [MachOLoaderFinding] {
        guard hasFunctionStartsCommand,
              let section = sections.first(where: {
                  $0.segmentName == "__TEXT" && $0.sectionName == "__unwind_info"
              }),
              let imageBase = segments.first(where: { $0.name == "__TEXT" })?.vmAddress
                ?? segments.map(\.vmAddress).min(),
              let unwindOffsets = functionOffsets(in: data, section: section) else {
            return []
        }
        return crossCheck(functionStarts: functionStarts, unwindOffsets: unwindOffsets, imageBase: imageBase)
    }

    /// Image-base-relative function offsets from every second-level page of `__unwind_info`,
    /// sorted and de-duplicated. Nil when the section has no file bytes (stripped), is not
    /// version 1, or is malformed anywhere: partial evidence would manufacture disagreements.
    /// All offsets are relative to `data`'s first byte (which may be a slice above index zero).
    static func functionOffsets(in data: Data, section: MachOSection) -> [UInt32]? {
        guard section.fileOffset != 0,
              let sectionStart = Int(exactly: section.fileOffset),
              let sectionSize = Int(exactly: section.size),
              sectionSize >= Int(MachOConstants.unwindInfoHeaderSize),
              sectionStart <= data.count, sectionSize <= data.count - sectionStart else {
            return nil
        }
        let reader = SectionReader(data: data, start: sectionStart, size: sectionSize)
        guard reader.u32(0) == sectionVersion,
              let indexOffset = reader.u32(20).map({ Int($0) }),
              let indexCount = reader.u32(24).map({ Int($0) }),
              indexCount <= maximumIndexEntries else {
            return nil
        }
        var offsets = Set<UInt32>()
        var scanned = 0
        for index in 0..<indexCount {
            let entry = indexOffset + index * 12
            guard let pageBase = reader.u32(entry), let pageOffset = reader.u32(entry + 4) else {
                return nil
            }
            // The last first-level entry is a sentinel (end of the last function, no page).
            guard pageOffset != 0 else { continue }
            let page = Int(pageOffset)
            guard let kind = reader.u32(page),
                  let entryPageOffset = reader.u16(page + 4).map({ Int($0) }),
                  let entryCount = reader.u16(page + 6).map({ Int($0) }) else {
                return nil
            }
            scanned += entryCount
            guard scanned <= maximumScannedEntries else { return nil }
            switch kind {
            case regularPageKind:
                // unwind_info_regular_second_level_entry { functionOffset, encoding }
                for item in 0..<entryCount {
                    guard let offset = reader.u32(page + entryPageOffset + item * 8) else { return nil }
                    offsets.insert(offset)
                }
            case compressedPageKind:
                // Low 24 bits: offset from this first-level entry's functionOffset.
                for item in 0..<entryCount {
                    guard let raw = reader.u32(page + entryPageOffset + item * 4) else { return nil }
                    let (offset, overflow) = pageBase.addingReportingOverflow(raw & 0x00ff_ffff)
                    guard !overflow else { return nil }
                    offsets.insert(offset)
                }
            default:
                return nil
            }
        }
        return offsets.sorted()
    }

    /// Findings for unwind-derived starts that LC_FUNCTION_STARTS does not list. Empty when the
    /// function-start list hit `MachORecoveryLimits.maximumFunctionStarts` (its tail is unknown).
    static func crossCheck(
        functionStarts: [MachOFunctionStart],
        unwindOffsets: [UInt32],
        imageBase: UInt64
    ) -> [MachOLoaderFinding] {
        guard functionStarts.count < MachORecoveryLimits.maximumFunctionStarts else { return [] }
        let listed = Set(functionStarts.map(\.offsetFromImageBase))
        let missing = unwindOffsets.filter { !listed.contains(UInt64($0)) }
        var findings: [MachOLoaderFinding] = []
        for (position, offset) in missing.enumerated() {
            let (address, overflow) = imageBase.addingReportingOverflow(UInt64(offset))
            guard !overflow else { continue }
            if position < maximumNamedDisagreements {
                findings.append(MachOLoaderFinding(
                    kind: .unwindFunctionStartNotInFunctionStarts,
                    address: address,
                    value: UInt64(offset),
                    message: "__unwind_info lists a function start at 0x\(String(address, radix: 16)) "
                        + "that LC_FUNCTION_STARTS does not; discovery is unchanged."
                ))
            } else {
                findings.append(MachOLoaderFinding(
                    kind: .unwindFunctionStartNotInFunctionStarts,
                    address: address,
                    value: nil,
                    message: "\(missing.count) unwind-derived function starts are not in "
                        + "LC_FUNCTION_STARTS (first \(maximumNamedDisagreements) listed separately, "
                        + "next at 0x\(String(address, radix: 16))); discovery is unchanged."
                ))
                break
            }
        }
        return findings
    }

    /// Bounds-checked little-endian reads at offsets relative to the section's first byte.
    private struct SectionReader {
        let data: Data
        let start: Int
        let size: Int

        private func contains(_ offset: Int, width: Int) -> Bool {
            offset >= 0 && offset <= size && width <= size - offset
        }

        func u16(_ offset: Int) -> UInt16? {
            guard contains(offset, width: 2) else { return nil }
            let base = data.startIndex + start + offset
            return UInt16(data[base]) | UInt16(data[base + 1]) << 8
        }

        func u32(_ offset: Int) -> UInt32? {
            guard contains(offset, width: 4) else { return nil }
            let base = data.startIndex + start + offset
            var value: UInt32 = 0
            for index in 0..<4 { value |= UInt32(data[base + index]) << UInt32(index * 8) }
            return value
        }
    }
}
