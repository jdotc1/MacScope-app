import Foundation

/// A VERIFIED file-offset → virtual-address mapping for one contiguous run of file-backed
/// bytes inside an image's exact selected-slice payload.
///
/// This is the sole production authority for converting a persisted payload offset to a
/// virtual address and back (hex editing, patch overlay, selected-address navigation). It
/// exists because the legacy convention — `address = first instruction address + window
/// offset` — silently targets the wrong virtual address for any window that does not start
/// at the first instruction (a real binary's header-first window, restored documents, PE
/// raw padding). A byte with no mapping, or with mappings that disagree, has NO address and
/// must stay read-only rather than guess.
///
/// Mappings are persisted with the image (`BinaryImage.byteMappings`), so a restored
/// document edits at the same verified addresses as a fresh analysis.
struct FileAddressMapping: Hashable, Codable, Sendable {
    /// Byte offset of the run inside the exact selected-slice payload (slice-relative).
    var fileOffset: UInt64
    /// Length of the run in bytes. A valid mapping has `size > 0` and neither its file
    /// range nor its virtual range overflows.
    var size: UInt64
    /// Virtual address of the byte at `fileOffset`.
    var virtualAddress: UInt64
    /// The originating section/segment name, for diagnostics only (participates in
    /// equality so fixtures can assert provenance; never used for resolution).
    var sectionName: String? = nil

    init(fileOffset: UInt64, size: UInt64, virtualAddress: UInt64, sectionName: String? = nil) {
        self.fileOffset = fileOffset
        self.size = size
        self.virtualAddress = virtualAddress
        self.sectionName = sectionName
    }

    /// True when the mapping is internally sound: nonzero length and no overflow in either
    /// the file range or the virtual range. Invalid mappings never resolve anything.
    var isWellFormed: Bool {
        guard size > 0 else { return false }
        guard fileOffset <= UInt64.max - (size - 1) else { return false }
        guard virtualAddress <= UInt64.max - (size - 1) else { return false }
        return true
    }

    func containsFileOffset(_ offset: UInt64) -> Bool {
        guard isWellFormed else { return false }
        return offset >= fileOffset && offset - fileOffset < size
    }

    func containsVirtualAddress(_ address: UInt64) -> Bool {
        guard isWellFormed else { return false }
        return address >= virtualAddress && address - virtualAddress < size
    }

    /// The virtual address of the payload byte at `offset` under THIS mapping alone, or nil
    /// when the offset is outside the run. Collection-level resolution (which also rejects
    /// disagreeing aliases) is `resolvedVirtualAddress(forFileOffset:in:)`.
    func virtualAddress(forFileOffset offset: UInt64) -> UInt64? {
        guard containsFileOffset(offset) else { return nil }
        return virtualAddress &+ (offset - fileOffset)
    }

    /// The payload offset of `address` under THIS mapping alone, or nil when outside the run.
    func fileOffset(forVirtualAddress address: UInt64) -> UInt64? {
        guard containsVirtualAddress(address) else { return nil }
        return fileOffset &+ (address - virtualAddress)
    }

    // MARK: - Collection-level resolution (alias-safe)

    /// Resolves a payload offset to a virtual address across ALL applicable mappings.
    /// Succeeds only when at least one mapping covers the offset and every covering mapping
    /// agrees on the address — valid binaries can contain aliases, and a byte whose aliases
    /// disagree must never silently pick one.
    static func resolvedVirtualAddress(
        forFileOffset offset: UInt64,
        in mappings: [FileAddressMapping]
    ) -> UInt64? {
        var resolved: UInt64?
        for mapping in mappings {
            guard let address = mapping.virtualAddress(forFileOffset: offset) else { continue }
            if let existing = resolved, existing != address { return nil }
            resolved = address
        }
        return resolved
    }

    /// Resolves a virtual address to a payload offset across ALL applicable mappings.
    /// Succeeds only when every covering mapping agrees on the offset AND the offset
    /// round-trips forward to this same address — rejecting a file byte that is aliased to
    /// multiple virtual addresses (patching it would change more than the user asked for).
    static func resolvedFileOffset(
        forVirtualAddress address: UInt64,
        in mappings: [FileAddressMapping]
    ) -> UInt64? {
        var resolved: UInt64?
        for mapping in mappings {
            guard let offset = mapping.fileOffset(forVirtualAddress: address) else { continue }
            if let existing = resolved, existing != offset { return nil }
            resolved = offset
        }
        guard let offset = resolved else { return nil }
        guard resolvedVirtualAddress(forFileOffset: offset, in: mappings) == address else { return nil }
        return offset
    }

    /// Resolves a complete contiguous read without accepting an alias or crossing a
    /// mapping boundary. Checking every intersecting mapping also catches an alias
    /// wholly inside the requested range (endpoint checks alone are insufficient).
    static func resolvedFileRange(
        forVirtualAddress address: UInt64,
        count: Int,
        in mappings: [FileAddressMapping]
    ) -> Range<Int>? {
        guard count > 0,
              address <= UInt64.max - UInt64(count - 1),
              let offset = resolvedFileOffset(forVirtualAddress: address, in: mappings),
              offset <= UInt64.max - UInt64(count - 1),
              let start = Int(exactly: offset), count <= Int.max - start else { return nil }
        let lastAddress = address + UInt64(count - 1)
        let lastOffset = offset + UInt64(count - 1)
        guard mappings.contains(where: {
            $0.containsVirtualAddress(address) && $0.containsVirtualAddress(lastAddress)
        }) else { return nil }

        for mapping in mappings where mapping.isWellFormed {
            let firstSharedAddress = max(address, mapping.virtualAddress)
            let lastSharedAddress = min(lastAddress, mapping.virtualAddress + (mapping.size - 1))
            if firstSharedAddress <= lastSharedAddress,
               mapping.fileOffset(forVirtualAddress: firstSharedAddress)
                    != offset + (firstSharedAddress - address) { return nil }
            let firstSharedOffset = max(offset, mapping.fileOffset)
            let lastSharedOffset = min(lastOffset, mapping.fileOffset + (mapping.size - 1))
            if firstSharedOffset <= lastSharedOffset,
               mapping.virtualAddress(forFileOffset: firstSharedOffset)
                    != address + (firstSharedOffset - offset) { return nil }
        }
        return start..<(start + count)
    }

    // MARK: - Section-derived mappings

    /// Builds the verified mappings for an image from its (format-neutral) sections and the
    /// exact selected-slice payload length. Each non-zero-fill section contributes at most
    /// one mapping, clamped by:
    ///  - the declared virtual span (`size`) — PE raw padding past the virtual span stays
    ///    persisted but UNMAPPED (it has no address);
    ///  - the declared physical size (`fileSize`, when the format distinguishes it);
    ///  - the payload boundary — bytes past the payload do not exist;
    ///  - the next distinct non-zero-fill section's file offset — malformed metadata must
    ///    not project one section's addresses over a neighbor's bytes.
    /// Zero-fill sections occupy address space with NO file bytes and never receive a
    /// mapping. A section whose clamped run is empty, starts past the payload, or whose
    /// virtual range would overflow is skipped (no address is ever invented).
    static func verifiedMappings(
        from sections: [SectionSummary],
        payloadLength: Int
    ) -> [FileAddressMapping] {
        guard payloadLength > 0 else { return [] }
        let payload = UInt64(payloadLength)
        let fileBacked = sections.filter { !$0.isZeroFill }
        let startOffsets = fileBacked.map(\.fileOffset)
        var mappings: [FileAddressMapping] = []
        for section in fileBacked.sorted(by: { ($0.fileOffset, $0.address) < ($1.fileOffset, $1.address) }) {
            guard section.fileOffset < payload else { continue }
            var run = section.size
            if let fileSize = section.fileSize {
                run = min(run, fileSize)
            }
            run = min(run, payload - section.fileOffset)
            if let next = startOffsets.lazy.filter({ $0 > section.fileOffset }).min() {
                run = min(run, next - section.fileOffset)
            }
            guard run > 0 else { continue }
            guard section.address <= UInt64.max - (run - 1) else { continue }
            mappings.append(
                FileAddressMapping(
                    fileOffset: section.fileOffset,
                    size: run,
                    virtualAddress: section.address,
                    sectionName: section.name
                )
            )
        }
        return mappings
    }
}

/// A derived, immutable overlay over bytes supplied by the existing loader/mapping
/// authority. Raw artifact bytes are never replaced. Overlapping edits apply in
/// ascending start-address order; the edit with the greater start wins shared bytes.
/// This rule is independent of dictionary order and is shared by analysis and export.
struct BytePatchOverlay: Sendable {
    struct Edit: Sendable {
        let address: UInt64
        let endAddress: UInt64
        let bytes: [UInt8]
    }

    enum Failure: LocalizedError, Equatable {
        case oversizedPatch(address: UInt64, count: Int)
        case addressOverflow(address: UInt64)
        case unmappedPatch(address: UInt64)

        var errorDescription: String? {
            switch self {
            case let .oversizedPatch(address, count):
                return "Patch at \(address.hexAddress) has \(count) bytes; the limit is \(BytePatch.maxByteCount)."
            case let .addressOverflow(address):
                return "Patch at \(address.hexAddress) extends beyond the address space."
            case let .unmappedPatch(address):
                return "Patch at \(address.hexAddress) is not wholly inside one unambiguous file-backed mapping."
            }
        }
    }

    static let empty = BytePatchOverlay(edits: [])
    let edits: [Edit]

    private init(edits: [Edit]) { self.edits = edits }

    /// A nil mapping list is only for callers that supply their own read/write
    /// authority (the Mach-O writer or a legacy hand-built linear byte window).
    init(patches: [UInt64: BytePatch], mappings: [FileAddressMapping]? = nil) throws {
        var edits: [Edit] = []
        for address in patches.keys.sorted() {
            guard let patch = patches[address], !patch.isEmpty else { continue }
            guard patch.bytes.count <= BytePatch.maxByteCount else {
                throw Failure.oversizedPatch(address: address, count: patch.bytes.count)
            }
            let (end, overflow) = address.addingReportingOverflow(UInt64(patch.bytes.count))
            guard !overflow else { throw Failure.addressOverflow(address: address) }
            if let mappings,
               FileAddressMapping.resolvedFileRange(
                   forVirtualAddress: address, count: patch.bytes.count, in: mappings
               ) == nil {
                throw Failure.unmappedPatch(address: address)
            }
            edits.append(Edit(address: address, endAddress: end, bytes: patch.bytes))
        }
        self.edits = edits
    }

    func applying(to raw: Data, at address: UInt64) -> Data? {
        guard !raw.isEmpty else { return raw }
        let (end, overflow) = address.addingReportingOverflow(UInt64(raw.count))
        guard !overflow else { return nil }
        var result = raw
        for edit in candidates(at: address, end: end) where edit.endAddress > address {
            let first = max(address, edit.address)
            let last = min(end, edit.endAddress)
            let destination = result.startIndex + Int(first - address)
            let source = Int(first - edit.address)
            let count = Int(last - first)
            result.replaceSubrange(destination..<(destination + count),
                                   with: edit.bytes[source..<(source + count)])
        }
        return result
    }

    func intersects(address: UInt64, count: Int) -> Bool {
        guard count > 0 else { return false }
        let (end, overflow) = address.addingReportingOverflow(UInt64(count))
        guard !overflow else { return false }
        return candidates(at: address, end: end).contains { $0.endAddress > address }
    }

    /// Every admitted patch is at most maxByteCount bytes, so an intersecting
    /// edit cannot start farther back. Two binary searches avoid O(rows * edits)
    /// work when annotating a complete disassembly or reading table entries.
    private func candidates(at address: UInt64, end: UInt64) -> ArraySlice<Edit> {
        let reach = UInt64(BytePatch.maxByteCount - 1)
        let firstPossible = address > reach ? address - reach : 0
        return edits[lowerBound(firstPossible)..<lowerBound(end)]
    }

    private func lowerBound(_ address: UInt64) -> Int {
        var low = 0
        var high = edits.count
        while low < high {
            let middle = low + (high - low) / 2
            if edits[middle].address < address { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
