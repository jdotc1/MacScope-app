import Foundation

/// On-demand exception evidence over the loader's captured image. The app owns this
/// composition because DWARFReader belongs to DebuggerCore, which depends on AnalysisCore.
/// No file reopen, image hash, indirect dereference, or target execution occurs here.
enum ExceptionFlowService {
    static let modelIdentifier = "darwin-arm64-exception-evidence-v1"

    enum Refusal: Error, Equatable {
        case unverifiedImage, unsupportedImage, invalidMapping, encryptedMetadata
        case malformedCompact, inconsistentAssociation, unsupportedUnwindMode, limit
    }

    enum Frontier: String, Sendable {
        case personalityTargetUnresolved
        case runtimeTypeMatchingUnknown
        case runtimeReachabilityUnknown
    }

    struct Source: Equatable, Sendable {
        let section: String
        let sliceRange: Range<UInt64>
    }

    /// A structurally permitted destination. This is never an observed CFG edge,
    /// a claim that the protected instruction throws, or proof of a matching catch.
    struct Candidate: Equatable, Sendable {
        let protectedRange: Range<UInt64>
        let landingPad: UInt64
        let actionOffsets: [Int]
        let callSiteSource: Source
    }

    struct Function: Sendable {
        let functionRange: Range<UInt64>
        let lsda: MachOExceptionLSDA.Report
        let lsdaSource: Source
        let associationSources: [Source]
        let personality: MachOExceptionLSDA.Pointer?
        let cieSectionOffset: Int?
        let fdeSectionOffset: Int?
        let candidates: [Candidate]
        let frontier: [Frontier]
    }

    struct Report: Sendable {
        let modelIdentifier = ExceptionFlowService.modelIdentifier
        let identity: MachOSliceArtifactIdentity
        let functions: [Function]
    }

    private struct Association {
        let range: Range<UInt64>
        let lsda: UInt64
        let personality: MachOExceptionLSDA.Pointer?
        let fde: DWARFStructuredFDE?
        let cie: DWARFStructuredCIE?
        let sources: [Source]
    }

    /// Fails atomically: no partial evidence escapes malformed metadata.
    static func analyze(binary: LoadedBinary) throws -> Report {
        let image = try Image(binary)
        let compactSection = try image.uniqueSection("__TEXT,__unwind_info")
        let cfiSection = try image.uniqueSection("__TEXT,__eh_frame")
        var rows: [MachOUnwindFunctionStarts.ResolvedRow] = []
        if let section = compactSection {
            _ = try image.bytes(section, maximum: 2 * 1024 * 1024)
            guard let offset = UInt32(exactly: section.fileOffset),
                  let decoded = MachOUnwindFunctionStarts.resolvedRows(in: image.slice,
                    section: MachOSection(sectionName: "__unwind_info", segmentName: "__TEXT",
                        address: section.address, size: section.size, fileOffset: offset,
                        alignment: 2, relocationOffset: 0, relocationCount: 0, flags: 0,
                        reserved1: 0, reserved2: 0, reserved3: 0)), decoded.count <= 16384 else {
                throw Refusal.malformedCompact
            }
            rows = decoded
        }
        var table = DWARFStructuredCallFrameTable(cies: [], fdes: [])
        if let section = cfiSection {
            let bytes = try image.bytes(section, maximum: 2 * 1024 * 1024)
            table = try DWARFReader(sections: .init(ehFrame: bytes))
                .recoverExceptionCallFrameInfo(sectionAddress: section.address)
            guard table.cies.count <= 8192, table.fdes.count <= 8192 else { throw Refusal.limit }
        }
        let cies = Dictionary(uniqueKeysWithValues: table.cies.map { ($0.sectionOffset, $0) })
        let fdes = Dictionary(uniqueKeysWithValues: table.fdes.map { ($0.sectionOffset, $0) })
        var associations: [Association] = []
        if let compactSection {
            let groups = Dictionary(grouping: rows, by: \.functionStartOffset)
            for owner in groups.keys.sorted() {
                guard let owned = groups[owner], let first = owned.first, let last = owned.last else { continue }
                let lsdaRows = owned.filter { $0.lsdaImageOffset != nil }
                guard !lsdaRows.isEmpty else { continue }
                guard owned.allSatisfy({ [UInt32(0x02000000), 0x03000000, 0x04000000]
                    .contains($0.encoding & 0x0f000000) }) else { throw Refusal.unsupportedUnwindMode }
                let start = try add(image.base, UInt64(owner))
                var end = try add(image.base, UInt64(last.range.upperBound))
                if let next = image.starts.first(where: { $0 > start }) { end = min(end, next) }
                guard start < end, first.range.lowerBound == owner,
                      Set(lsdaRows.compactMap(\.lsdaImageOffset)).count == 1,
                      let lsdaOffset = lsdaRows.first?.lsdaImageOffset else { throw Refusal.inconsistentAssociation }
                let lsda = try add(image.base, UInt64(lsdaOffset))
                let slots = try owned.compactMap { row -> UInt64? in
                    guard let offset = row.personalitySlotImageOffset else { return nil }
                    return try addSigned(image.base, Int64(offset))
                }
                guard Set(slots).count <= 1 else { throw Refusal.inconsistentAssociation }
                let personality = slots.first.map { MachOExceptionLSDA.Pointer.indirectSlot($0) }
                var selected: DWARFStructuredFDE?
                for row in owned {
                    guard let offset = row.dwarfFDESectionOffset else { continue }
                    guard let fde = fdes[Int(offset)], fde.initialLocation == start,
                          selected == nil || selected?.sectionOffset == fde.sectionOffset else {
                        throw Refusal.inconsistentAssociation
                    }
                    let rowEnd = try add(image.base, UInt64(row.range.upperBound))
                    guard rowEnd <= (try add(fde.initialLocation, fde.rangeSize)) else {
                        throw Refusal.inconsistentAssociation
                    }
                    selected = fde
                }
                if selected == nil {
                    let matching = table.fdes.filter { $0.initialLocation == start }
                    guard matching.count <= 1 else { throw Refusal.inconsistentAssociation }
                    selected = matching.first
                }
                var cie: DWARFStructuredCIE?
                var sources = [image.source(compactSection)]
                if let fde = selected {
                    guard let linked = cies[fde.cieSectionOffset],
                          let pointer = fde.lsdaPointer, !pointer.isIndirect, pointer.value == lsda,
                          pointerValue(linked.personalityPointer) == personality,
                          fde.rangeSize <= end - start else { throw Refusal.inconsistentAssociation }
                    end = try add(start, fde.rangeSize)
                    cie = linked
                    if let cfiSection {
                        sources += try cfiSources(fde, linked, section: cfiSection)
                    }
                }
                try image.executable(start..<end)
                associations.append(Association(range: start..<end, lsda: lsda, personality: personality,
                    fde: selected, cie: cie, sources: sources))
            }
        } else {
            for fde in table.fdes {
                guard let pointer = fde.lsdaPointer, pointer.value != 0 else { continue }
                guard !pointer.isIndirect, let cie = cies[fde.cieSectionOffset], let cfiSection else {
                    throw Refusal.inconsistentAssociation
                }
                let end = try add(fde.initialLocation, fde.rangeSize)
                try image.executable(fde.initialLocation..<end)
                associations.append(Association(range: fde.initialLocation..<end, lsda: pointer.value,
                    personality: pointerValue(cie.personalityPointer), fde: fde, cie: cie,
                    sources: try cfiSources(fde, cie, section: cfiSection)))
            }
        }
        guard associations.count <= 4096 else { throw Refusal.limit }
        associations.sort { $0.range.lowerBound < $1.range.lowerBound }
        for pair in zip(associations, associations.dropFirst()) {
            guard pair.0.range.upperBound <= pair.1.range.lowerBound else { throw Refusal.inconsistentAssociation }
        }
        let addresses = Array(Set(associations.map(\.lsda))).sorted()
        var functions: [Function] = []
        var remainingBytes: UInt64 = 8 * 1024 * 1024
        for association in associations {
            let matching = image.binary.sections.filter {
                ["__TEXT,__gcc_except_tab", "__TEXT,__objc_except_tab"].contains($0.name)
                    && $0.address <= association.lsda && association.lsda - $0.address < $0.size
            }
            guard matching.count == 1, let section = matching.first else { throw Refusal.invalidMapping }
            let sectionEnd = try add(section.address, section.size)
            let end = addresses.first(where: { $0 > association.lsda && $0 < sectionEnd }) ?? sectionEnd
            let count = end - association.lsda
            guard count <= 1_048_576, count <= remainingBytes else { throw Refusal.limit }
            remainingBytes -= count
            let whole = try image.bytes(section, maximum: 8 * 1024 * 1024)
            let relative = Int(association.lsda - section.address)
            let bytes = whole.subdata(in: relative..<(relative + Int(count)))
            let report = try MachOExceptionLSDA.parse(data: bytes, address: association.lsda,
                functionStart: association.range.lowerBound, functionEnd: association.range.upperBound)
            let fileOffset = try add(section.fileOffset, UInt64(relative))
            let source = Source(section: section.name, sliceRange: fileOffset..<(fileOffset + count))
            let candidates = report.callsites.compactMap { call -> Candidate? in
                guard let landing = call.landingPad, !call.protectedRange.isEmpty else { return nil }
                return Candidate(protectedRange: call.protectedRange, landingPad: landing,
                    actionOffsets: call.actionChain, callSiteSource: Source(section: section.name,
                        sliceRange: (fileOffset + UInt64(call.source.lowerBound))..<(fileOffset + UInt64(call.source.upperBound))))
            }
            functions.append(Function(functionRange: association.range, lsda: report, lsdaSource: source,
                associationSources: association.sources, personality: association.personality,
                cieSectionOffset: association.cie?.sectionOffset, fdeSectionOffset: association.fde?.sectionOffset,
                candidates: candidates, frontier: [.personalityTargetUnresolved, .runtimeTypeMatchingUnknown,
                                                  .runtimeReachabilityUnknown]))
        }
        return Report(identity: image.identity, functions: functions)
    }

    private static func pointerValue(_ pointer: DWARFExceptionEncodedPointer?) -> MachOExceptionLSDA.Pointer? {
        pointer.map { $0.isIndirect ? .indirectSlot($0.value) : .direct($0.value) }
    }

    private static func cfiSources(_ fde: DWARFStructuredFDE, _ cie: DWARFStructuredCIE,
                                   section: BinarySection) throws -> [Source] {
        try [cie.exceptionMetadataRange, fde.exceptionMetadataRange].map { range in
            guard let range, range.lowerBound >= 0, UInt64(range.upperBound) <= section.size else {
                throw Refusal.inconsistentAssociation
            }
            return Source(section: section.name,
                sliceRange: (section.fileOffset + UInt64(range.lowerBound))..<(section.fileOffset + UInt64(range.upperBound)))
        }
    }

    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw Refusal.invalidMapping }
        return result.partialValue
    }

    private static func addSigned(_ a: UInt64, _ b: Int64) throws -> UInt64 {
        if b >= 0 { return try add(a, UInt64(b)) }
        let result = a.subtractingReportingOverflow(b.magnitude)
        guard !result.overflow else { throw Refusal.invalidMapping }
        return result.partialValue
    }

    private struct Image {
        let binary: LoadedBinary
        let identity: MachOSliceArtifactIdentity
        let input: BinaryExceptionMetadataInput
        let slice: Data
        let base: UInt64
        let starts: [UInt64]

        init(_ binary: LoadedBinary) throws {
            guard binary.artifactIntegrityState == .verified, let identity = binary.artifactIdentity,
                  identity.rawCPUType == binary.cpuType, identity.rawCPUSubtype == binary.cpuSubtype,
                  binary.sliceOffset <= UInt64(binary.bytes.count),
                  identity.selectedSliceByteCount == (binary.sliceSize ?? (UInt64(binary.bytes.count) - binary.sliceOffset)),
                  identity.selectedSliceByteCount <= UInt64(binary.bytes.count) - binary.sliceOffset else {
                throw Refusal.unverifiedImage
            }
            guard identity.rawCPUType == MachOConstants.cpuTypeARM64,
                  let input = binary.exceptionMetadataInput, [UInt32(2), 6, 8].contains(input.linkedMachOFileType),
                  !binary.isDyldSharedCacheProjection,
                  let layout = binary.preferredSegmentLayout else { throw Refusal.unsupportedImage }
            let text = layout.records.filter { $0.name == "__TEXT" }
            guard text.count == 1, let first = text.first else { throw Refusal.invalidMapping }
            guard binary.sections.count <= 4096, binary.functionStarts.count <= 100000,
                  input.encryptedSliceRanges.count <= 4096 else { throw Refusal.limit }
            self.binary = binary
            self.identity = identity
            self.input = input
            let lower = binary.bytes.startIndex + Int(binary.sliceOffset)
            self.slice = binary.bytes.subdata(in: lower..<(lower + Int(identity.selectedSliceByteCount)))
            self.base = first.preferredVMStart
            self.starts = Array(Set(binary.functionStarts)).sorted()
        }

        func uniqueSection(_ name: String) throws -> BinarySection? {
            let sections = binary.sections.filter { $0.name == name }
            guard sections.count <= 1 else { throw Refusal.invalidMapping }
            return sections.first
        }

        func source(_ section: BinarySection) -> Source {
            Source(section: section.name, sliceRange: section.fileOffset..<(section.fileOffset + section.size))
        }

        func bytes(_ section: BinarySection, maximum: UInt64) throws -> Data {
            guard section.size <= maximum, !section.isZeroFill,
                  section.fileSize.map({ $0 >= section.size }) ?? true,
                  section.fileOffset <= UInt64(slice.count), section.size <= UInt64(slice.count) - section.fileOffset else {
                throw Refusal.invalidMapping
            }
            let vmEnd = try add(section.address, section.size)
            let fileEnd = section.fileOffset + section.size
            try mapped(section.address..<vmEnd, fileOffset: section.fileOffset, executable: false)
            for other in binary.sections where other != section && other.size > 0 {
                let otherEnd = try add(other.address, other.size)
                guard otherEnd <= section.address || vmEnd <= other.address else { throw Refusal.invalidMapping }
                if !other.isZeroFill {
                    let otherFileEnd = try add(other.fileOffset, other.fileSize ?? other.size)
                    guard otherFileEnd <= section.fileOffset || fileEnd <= other.fileOffset else { throw Refusal.invalidMapping }
                }
            }
            guard binary.sections.filter({ $0 == section }).count == 1 else { throw Refusal.invalidMapping }
            guard !input.encryptedSliceRanges.contains(where: { $0.overlaps(section.fileOffset..<fileEnd) }) else {
                throw Refusal.encryptedMetadata
            }
            return slice.subdata(in: Int(section.fileOffset)..<Int(fileEnd))
        }

        func executable(_ range: Range<UInt64>) throws {
            let sections = binary.sections.filter {
                $0.isExecutable && !$0.isZeroFill && $0.address <= range.lowerBound
                    && range.upperBound >= $0.address && range.upperBound - $0.address <= $0.size
            }
            guard !range.isEmpty, sections.count == 1, let section = sections.first else { throw Refusal.invalidMapping }
            let offset = try add(section.fileOffset, range.lowerBound - section.address)
            try mapped(range, fileOffset: offset, executable: true)
        }

        private func mapped(_ range: Range<UInt64>, fileOffset: UInt64, executable: Bool) throws {
            guard let layout = binary.preferredSegmentLayout else { throw Refusal.invalidMapping }
            let overlaps = layout.records.filter {
                $0.preferredVMStart < range.upperBound
                    && range.lowerBound < $0.preferredVMStart + $0.preferredVMSize
            }
            guard overlaps.count == 1, let record = overlaps.first,
                  record.preferredVMStart <= range.lowerBound,
                  range.upperBound - record.preferredVMStart <= record.preferredVMSize,
                  range.upperBound - record.preferredVMStart <= record.fileSize,
                  record.initialProtections & 1 != 0,
                  !executable || record.initialProtections & 4 != 0,
                  fileOffset >= record.sliceRelativeFileOffset,
                  fileOffset - record.sliceRelativeFileOffset == range.lowerBound - record.preferredVMStart else {
                throw Refusal.invalidMapping
            }
        }
    }
}
