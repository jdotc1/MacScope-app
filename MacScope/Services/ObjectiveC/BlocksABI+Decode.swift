import Foundation

/// Bounded read access to an image or memory snapshot for `BlocksABI`. The decoder never treats
/// stored bits as an address on its own: every pointer slot goes through `pointer(at:)`, so an
/// adapter over a file image with chained fixups (or arm64e signed pointers) reports each slot as
/// `.resolved` or `.unresolved` instead of `.stored`.
protocol BlocksABIMemory {
    /// Exactly `count` bytes at `address`, or nil when any of them is outside admitted memory.
    func bytes(at address: UInt64, count: Int) -> [UInt8]?
    /// How the eight-byte pointer slot at `slot` resolves; nil when the slot is unreadable.
    func pointer(at slot: UInt64) -> BlocksABI.PointerResolution?
}

extension BlocksABIMemory {
    /// Admitted bytes from `address` up to and including the first NUL, at most `maxCount`.
    func prefix(at address: UInt64, maxCount: Int) -> [UInt8] {
        var out: [UInt8] = []
        var cursor = address
        while out.count < maxCount, let byte = bytes(at: cursor, count: 1)?.first {
            out.append(byte)
            if byte == 0 { break }
            let (next, overflow) = cursor.addingReportingOverflow(1)
            if overflow { break }
            cursor = next
        }
        return out
    }
}

extension BlocksABI {

    enum PointerResolution: Equatable, Sendable {
        /// No relocation applies; the stored little-endian bits are the target address.
        case stored(UInt64)
        /// A fixup or binding record supplies the target.
        case resolved(UInt64)
        /// A fixup or binding exists but its target is outside the admitted image (e.g. an import).
        case unresolved(symbol: String?)
    }

    enum GapCode: Equatable, Sendable {
        case misalignedSubject
        case unreadable
        case unresolvedPointer(symbol: String?)
        case nullPointer
        case unsupportedDescriptorVariant
        case unsupportedFlags
        case invalidFlags
        case invalidDescriptor
        case signatureAbsent
        case unterminatedSignature
        case invalidSignature
        case captureLayoutUnavailable
        case layout(Failure)
        case invalidByrefSize
        case unsupportedByrefFlags
        case unsupportedByrefLayout
        case forwardingCycle
        case forwardingDepthLimit
    }

    /// Something the decoder could not prove, with the address of the offending field.
    struct Gap: Equatable, Sendable {
        let code: GapCode
        let address: UInt64?
    }

    struct BlockLiteral: Equatable, Sendable {
        let address: UInt64
        var header: LiteralHeader?
        var invokeTarget: UInt64?
        var descriptor: UInt64?
        /// Descriptor `size`: the whole literal, including the 32-byte header.
        var size: UInt64?
        var copyTarget: UInt64?
        var disposeTarget: UInt64?
        var signature: String?
        /// Raw layout field: inline `0xXYZ`, an out-of-line string address, or 0.
        var layoutField: UInt64?
        /// Ownership regions with offsets relative to the literal (the first capture is at 32).
        var captures: [CaptureRegion] = []
        var gaps: [Gap] = []
    }

    struct ByrefCell: Equatable, Sendable {
        let address: UInt64
        let header: ByrefHeader
        var keepTarget: UInt64?
        var destroyTarget: UInt64?
        var layoutField: UInt64?
        /// Ownership regions with offsets relative to the cell.
        var captures: [CaptureRegion] = []
        var forwarding: UInt64?
    }

    struct ByrefChain: Equatable, Sendable {
        let root: UInt64
        /// Cells visited along `forwarding`, starting at `root`.
        var cells: [ByrefCell] = []
        /// The self-forwarding cell that ends the chain, when one was reached.
        var terminal: UInt64?
        var gaps: [Gap] = []
    }

    // MARK: - Block literal

    /// Decodes the block literal at `address`: header, large descriptor, helpers, signature and
    /// extended capture layout. Any field that cannot be proven becomes a gap and stops the
    /// dependent decoding; nothing is guessed.
    static func decodeBlock(at address: UInt64, in memory: some BlocksABIMemory) -> BlockLiteral {
        var block = BlockLiteral(address: address)
        guard address % 8 == 0 else {
            block.gaps.append(Gap(code: .misalignedSubject, address: address))
            return block
        }
        guard let bytes = memory.bytes(at: address, count: 32), let header = try? LiteralHeader(bytes) else {
            block.gaps.append(Gap(code: .unreadable, address: address))
            return block
        }
        block.header = header
        block.invokeTarget = target(at: address + 16, in: memory, gaps: &block.gaps)

        let flags = header.flags
        if !flags.isDisjoint(with: [.smallDescriptor, .inlineLayoutString]) {
            block.gaps.append(Gap(code: .unsupportedDescriptorVariant, address: address + 8))
            return block
        }
        if !flags.isDisjoint(with: .unassigned) {
            block.gaps.append(Gap(code: .unsupportedFlags, address: address + 8))
            return block
        }
        guard let fields = try? DescriptorFields(flags: flags) else {
            block.gaps.append(Gap(code: .invalidFlags, address: address + 8))
            return block
        }
        guard let descriptor = target(at: address + 24, in: memory, gaps: &block.gaps) else { return block }
        block.descriptor = descriptor
        guard let prefix = memory.bytes(at: descriptor, count: 16) else {
            block.gaps.append(Gap(code: .unreadable, address: descriptor))
            return block
        }
        // A nonzero reserved word is the in-descriptor flags form, which is not the large layout.
        guard u64(prefix, 0) == 0 else {
            block.gaps.append(Gap(code: .unsupportedDescriptorVariant, address: descriptor))
            return block
        }
        let size = u64(prefix, 8)
        guard size >= literalHeaderSize, size - literalHeaderSize <= maxCaptureBytes,
              !address.addingReportingOverflow(size).overflow else {
            block.gaps.append(Gap(code: .invalidDescriptor, address: descriptor + 8))
            return block
        }
        block.size = size

        if let copy = fields.copy, let dispose = fields.dispose {
            block.copyTarget = target(at: descriptor + UInt64(copy), in: memory, gaps: &block.gaps)
            block.disposeTarget = target(at: descriptor + UInt64(dispose), in: memory, gaps: &block.gaps)
        }
        guard let signatureOffset = fields.signature, let layoutOffset = fields.layout else {
            block.gaps.append(Gap(code: .signatureAbsent, address: address + 8))
            if size > literalHeaderSize {
                block.gaps.append(Gap(code: .captureLayoutUnavailable, address: descriptor))
            }
            return block
        }
        if let signature = target(at: descriptor + UInt64(signatureOffset), in: memory, gaps: &block.gaps) {
            switch decodeSignature(memory.prefix(at: signature, maxCount: maxSignatureBytes)) {
            case .success(let text): block.signature = text
            case .failure(let error): block.gaps.append(Gap(code: error.code, address: signature))
            }
        }

        let layoutSlot = descriptor + UInt64(layoutOffset)
        guard let resolution = memory.pointer(at: layoutSlot), let raw = memory.bytes(at: layoutSlot, count: 8) else {
            block.gaps.append(Gap(code: .unreadable, address: layoutSlot))
            return block
        }
        let layoutField = u64(raw, 0)
        block.layoutField = layoutField
        guard flags.contains(.hasExtendedLayout) else {
            if size > literalHeaderSize {
                block.gaps.append(Gap(code: .captureLayoutUnavailable, address: layoutSlot))
            }
            return block
        }
        guard let regions = layout(field: layoutField, slot: layoutSlot, resolution: resolution,
                                   payload: size - literalHeaderSize, in: memory, gaps: &block.gaps) else { return block }
        block.captures = regions.map { rebased($0, by: UInt32(literalHeaderSize)) }
        return block
    }

    // MARK: - Byref chain

    /// Decodes the `__block` cell at `address` and follows `forwarding` until a self-forwarding
    /// cell. Cycles, the depth limit and any unprovable cell stop the walk with a gap.
    static func decodeByref(at address: UInt64, in memory: some BlocksABIMemory) -> ByrefChain {
        var chain = ByrefChain(root: address)
        var seen: Set<UInt64> = []
        var current = address
        for _ in 0..<maxForwardingDepth {
            guard !seen.contains(current) else {
                chain.gaps.append(Gap(code: .forwardingCycle, address: current))
                return chain
            }
            guard current % 8 == 0 else {
                chain.gaps.append(Gap(code: .misalignedSubject, address: current))
                return chain
            }
            seen.insert(current)
            guard let bytes = memory.bytes(at: current, count: Int(byrefHeaderSize)) else {
                chain.gaps.append(Gap(code: .unreadable, address: current))
                return chain
            }
            let header: ByrefHeader
            do {
                header = try ByrefHeader(bytes)
            } catch {
                let flags = u32(bytes, 16)
                let code: GapCode = (error as? Failure) != .reserved ? .invalidByrefSize
                    : (flags & byrefUnassignedFlags != 0 ? .unsupportedByrefFlags : .unsupportedByrefLayout)
                chain.gaps.append(Gap(code: code, address: current + 16))
                return chain
            }
            guard !current.addingReportingOverflow(UInt64(header.size)).overflow else {
                chain.gaps.append(Gap(code: .invalidByrefSize, address: current + 20))
                return chain
            }

            var cell = ByrefCell(address: current, header: header)
            if let keep = header.keep, let destroy = header.destroy {
                cell.keepTarget = target(at: current + UInt64(keep), in: memory, gaps: &chain.gaps)
                cell.destroyTarget = target(at: current + UInt64(destroy), in: memory, gaps: &chain.gaps)
            }
            let base = header.payloadOffset
            let payload = header.size - base
            switch header.layoutKind {
            case 1:
                let slot = current + UInt64(header.layout ?? 0)
                guard let resolution = memory.pointer(at: slot), let raw = memory.bytes(at: slot, count: 8) else {
                    chain.gaps.append(Gap(code: .unreadable, address: slot))
                    return chain
                }
                cell.layoutField = u64(raw, 0)
                guard let regions = layout(field: u64(raw, 0), slot: slot, resolution: resolution,
                                           payload: UInt64(payload), in: memory, gaps: &chain.gaps) else {
                    chain.cells.append(cell)
                    return chain
                }
                cell.captures = regions.map { rebased($0, by: base) }
            case 0:
                if payload > 0 { chain.gaps.append(Gap(code: .captureLayoutUnavailable, address: current)) }
            case 2:
                if payload > 0 {
                    cell.captures = [CaptureRegion(kind: .nonObjectBytes, offset: base, size: payload, count: payload)]
                }
            default:
                let kind: CaptureKind = header.layoutKind == 3 ? .strong : (header.layoutKind == 4 ? .weak : .unretained)
                cell.captures = [CaptureRegion(kind: kind, offset: base, size: 8, count: 1)]
                if payload > 8 {
                    cell.captures.append(CaptureRegion(kind: .nonObjectBytes, offset: base + 8, size: payload - 8, count: payload - 8))
                }
            }

            cell.forwarding = target(at: current + 8, in: memory, gaps: &chain.gaps)
            chain.cells.append(cell)
            guard let next = cell.forwarding else { return chain }
            if next == current {
                chain.terminal = current
                return chain
            }
            current = next
        }
        chain.gaps.append(Gap(code: .forwardingDepthLimit, address: current))
        return chain
    }

    // MARK: - Helpers

    /// Resolves a required (non-NULL) pointer slot, recording why when it cannot.
    private static func target(at slot: UInt64, in memory: some BlocksABIMemory, gaps: inout [Gap]) -> UInt64? {
        switch memory.pointer(at: slot) {
        case nil:
            gaps.append(Gap(code: .unreadable, address: slot))
            return nil
        case .unresolved(let symbol):
            gaps.append(Gap(code: .unresolvedPointer(symbol: symbol), address: slot))
            return nil
        case .stored(let value), .resolved(let value):
            guard value != 0 else {
                gaps.append(Gap(code: .nullPointer, address: slot))
                return nil
            }
            return value
        }
    }

    /// Decodes an extended layout field. The field is an inline integer unless it is at least
    /// 0x1000 or a relocation applies to its slot, in which case it is a pointer to the string.
    private static func layout(field: UInt64, slot: UInt64, resolution: PointerResolution, payload: UInt64,
                               in memory: some BlocksABIMemory, gaps: inout [Gap]) -> [CaptureRegion]? {
        var value = field
        if case .stored(_) = resolution, field < inlineLayoutLimit {
            // Inline encoding; nothing to dereference.
        } else {
            guard let address = target(at: slot, in: memory, gaps: &gaps) else { return nil }
            value = address
        }
        let string = value < inlineLayoutLimit ? [] : memory.prefix(at: value, maxCount: maxLayoutBytes)
        do {
            return try decodeLayout(value: value, bytes: string, captureByteCount: payload).regions
        } catch {
            gaps.append(Gap(code: .layout(error as? Failure ?? .invalid), address: value))
            return nil
        }
    }

    /// A signature is a non-empty, NUL-terminated, printable-ASCII Objective-C type encoding.
    private static func decodeSignature(_ raw: [UInt8]) -> Result<String, GapCodeError> {
        guard raw.last == 0 else { return .failure(GapCodeError(.unterminatedSignature)) }
        let text = raw.dropLast()
        guard !text.isEmpty, text.allSatisfy({ (32...126).contains($0) }) else {
            return .failure(GapCodeError(.invalidSignature))
        }
        return .success(String(decoding: text, as: UTF8.self))
    }

    private static func rebased(_ region: CaptureRegion, by base: UInt32) -> CaptureRegion {
        CaptureRegion(kind: region.kind, offset: region.offset + base, size: region.size, count: region.count)
    }

    private struct GapCodeError: Error {
        let code: GapCode
        init(_ code: GapCode) { self.code = code }
    }
}

/// A contiguous little-endian byte range starting at `base`, with optional per-slot relocation
/// overrides. Slots without an override resolve as `.stored`.
struct BlocksABIByteImage: BlocksABIMemory {
    let base: UInt64
    let bytes: [UInt8]
    var relocations: [UInt64: BlocksABI.PointerResolution] = [:]

    func bytes(at address: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, address >= base else { return nil }
        let start = address - base
        guard start <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - start else { return nil }
        return Array(bytes[Int(start)..<Int(start) + count])
    }

    func pointer(at slot: UInt64) -> BlocksABI.PointerResolution? {
        if let relocation = relocations[slot] { return relocation }
        guard let raw = bytes(at: slot, count: 8) else { return nil }
        return .stored(BlocksABI.u64(raw, 0))
    }
}
