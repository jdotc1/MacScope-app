import Foundation

/// Decodes Apple arm64 (LP64, little-endian) Clang Blocks ABI metadata: the block literal header,
/// the conventional large descriptor, extended capture layouts and `__block` (byref) cells, as laid
/// out in libclosure's `Block_private.h` and the Clang "Block Implementation Specification".
///
/// CORRECTNESS OVER COVERAGE: an unsupported or malformed encoding throws or becomes a `Gap`; it
/// never yields a partial capture layout. Capture regions classify the ABI's encoded ownership
/// categories only — they do not name source variables, recover C/Objective-C types, or prove that
/// a helper ran or an object was retained. Nothing here dereferences an encoded address: callers
/// supply bytes and pointer resolutions through `BlocksABIMemory`. Small descriptors (bit 22) and
/// inline generic-helper layouts (bit 21) are reported as unsupported, not read as large ones.
enum BlocksABI {

    enum Failure: String, Error, Equatable, Sendable {
        case truncated, reserved, overflow, limit, invalid, unsupported
    }

    /// Upper bound on the capture payload (block or byref) this decoder admits.
    static let maxCaptureBytes: UInt64 = 1 << 20
    /// Upper bound on an out-of-line layout string, including its terminator.
    static let maxLayoutBytes = 4096
    /// Upper bound on a signature string, including its terminator.
    static let maxSignatureBytes = 4096
    /// Upper bound on byref forwarding links followed from one root cell.
    static let maxForwardingDepth = 64
    /// Layout-field values below this are compact inline `0xXYZ` encodings, not pointers.
    static let inlineLayoutLimit: UInt64 = 0x1000
    static let literalHeaderSize: UInt64 = 32
    static let byrefHeaderSize: UInt32 = 24

    /// `Block_layout.flags` bits (libclosure `BLOCK_*`).
    struct Flags: OptionSet, Hashable, Sendable {
        let rawValue: UInt32
        static let inlineLayoutString = Flags(rawValue: 1 << 21)
        static let smallDescriptor = Flags(rawValue: 1 << 22)
        static let isNoEscape = Flags(rawValue: 1 << 23)
        static let needsFree = Flags(rawValue: 1 << 24)
        static let hasCopyDispose = Flags(rawValue: 1 << 25)
        static let hasCtor = Flags(rawValue: 1 << 26)
        static let isGC = Flags(rawValue: 1 << 27)
        static let isGlobal = Flags(rawValue: 1 << 28)
        static let useStret = Flags(rawValue: 1 << 29)
        static let hasSignature = Flags(rawValue: 1 << 30)
        static let hasExtendedLayout = Flags(rawValue: 1 << 31)
        /// Bits 16–20 are assigned to neither the compiler nor the runtime.
        static let unassigned = Flags(rawValue: 0x001F_0000)
    }

    /// `Block_byref.flags` bits outside the refcount: everything except NEEDS_FREE (24),
    /// HAS_COPY_DISPOSE (25), IS_GC (27) and the layout kind (28–31) is unassigned.
    static let byrefUnassignedFlags: UInt32 = 0x04FF_0000

    enum CaptureKind: String, Equatable, Sendable {
        case nonObjectBytes, nonObjectWords, strong, byref, weak, unretained

        /// Out-of-line layout opcode P of a `0xPN` byte (`BLOCK_LAYOUT_*`); 0 and 7–15 have no kind.
        init?(opcode: UInt8) {
            switch opcode {
            case 1: self = .nonObjectBytes
            case 2: self = .nonObjectWords
            case 3: self = .strong
            case 4: self = .byref
            case 5: self = .weak
            case 6: self = .unretained
            default: return nil
            }
        }

        var unitSize: UInt64 { self == .nonObjectBytes ? 1 : 8 }
    }

    /// One contiguous run of captured bytes. `count` is in the kind's unit (bytes for
    /// `nonObjectBytes`, eight-byte words otherwise); `size` is always in bytes.
    struct CaptureRegion: Equatable, Sendable {
        let kind: CaptureKind
        let offset: UInt32
        let size: UInt32
        let count: UInt32
    }

    struct CaptureLayout: Equatable, Sendable {
        /// Offsets are relative to the start of the capture payload. Regions are emitted one per
        /// opcode (never coalesced), followed by a trailing `nonObjectBytes` run for any rest.
        let regions: [CaptureRegion]
        /// Out-of-line layout bytes scanned, including the terminator; 0 for inline layouts.
        let consumed: Int
    }

    // MARK: - Layout

    /// Decodes an extended capture layout covering `captureByteCount` payload bytes. `value` is
    /// the layout field: below 0x1000 it is the inline `0xXYZ` form (X strong, then Y byref, then
    /// Z weak words); otherwise `bytes` must hold the out-of-line string it points to, read by the
    /// caller's bounded address authority. Each `0xPN` byte has count N+1 (libclosure
    /// `getOutOfLineOpcodeCount`); byte 0x00 terminates; `0x0N` with N≠0 and opcodes 7–15 are
    /// reserved.
    static func decodeLayout(value: UInt64, bytes: [UInt8], captureByteCount: UInt64) throws -> CaptureLayout {
        guard captureByteCount <= maxCaptureBytes else { throw Failure.limit }
        var regions: [CaptureRegion] = []
        var offset: UInt64 = 0
        var consumed = 0

        func append(_ kind: CaptureKind, _ count: UInt64) throws {
            guard count > 0 else { return }
            let size = count * kind.unitSize
            guard size <= captureByteCount - offset else { throw Failure.overflow }
            regions.append(CaptureRegion(kind: kind, offset: UInt32(offset), size: UInt32(size), count: UInt32(count)))
            offset += size
        }

        if value < inlineLayoutLimit {
            try append(.strong, (value >> 8) & 0xF)
            try append(.byref, (value >> 4) & 0xF)
            try append(.weak, value & 0xF)
        } else {
            var terminated = false
            for byte in bytes.prefix(maxLayoutBytes) {
                consumed += 1
                if byte == 0 {
                    terminated = true
                    break
                }
                guard let kind = CaptureKind(opcode: byte >> 4) else { throw Failure.reserved }
                try append(kind, UInt64(byte & 0xF) + 1)
            }
            if !terminated { throw bytes.count >= maxLayoutBytes ? Failure.limit : Failure.truncated }
        }
        try append(.nonObjectBytes, captureByteCount - offset)
        return CaptureLayout(regions: regions, consumed: consumed)
    }

    // MARK: - Fixed headers

    /// The 32-byte literal prefix. Pointer fields are raw stored bits, not validated addresses.
    struct LiteralHeader: Equatable, Sendable {
        let isa: UInt64
        let flags: Flags
        let reserved: UInt32
        let invoke: UInt64
        let descriptor: UInt64

        init(_ bytes: [UInt8]) throws {
            guard bytes.count >= 32 else { throw Failure.truncated }
            isa = BlocksABI.u64(bytes, 0)
            flags = Flags(rawValue: BlocksABI.u32(bytes, 8))
            reserved = BlocksABI.u32(bytes, 12)
            invoke = BlocksABI.u64(bytes, 16)
            descriptor = BlocksABI.u64(bytes, 24)
        }
    }

    /// Byte offsets of the optional large-descriptor fields after `{reserved, size}`
    /// (`Block_descriptor_2` when HAS_COPY_DISPOSE, then `Block_descriptor_3` when HAS_SIGNATURE).
    struct DescriptorFields: Equatable, Sendable {
        let minimumSize: UInt32
        let copy: UInt32?
        let dispose: UInt32?
        let signature: UInt32?
        let layout: UInt32?

        init(flags: Flags) throws {
            if !flags.isDisjoint(with: [.smallDescriptor, .inlineLayoutString]) { throw Failure.unsupported }
            // The layout field lives in Block_descriptor_3, which exists only with a signature;
            // C++ helpers are a property of the copy/dispose pair.
            if flags.contains(.hasExtendedLayout) && !flags.contains(.hasSignature) { throw Failure.invalid }
            if flags.contains(.hasCtor) && !flags.contains(.hasCopyDispose) { throw Failure.invalid }
            var cursor: UInt32 = 16
            if flags.contains(.hasCopyDispose) {
                copy = cursor
                dispose = cursor + 8
                cursor += 16
            } else {
                copy = nil
                dispose = nil
            }
            if flags.contains(.hasSignature) {
                signature = cursor
                layout = cursor + 8
                cursor += 16
            } else {
                signature = nil
                layout = nil
            }
            minimumSize = cursor
        }
    }

    /// The 24-byte `Block_byref` prefix plus the offsets of its conditional fields
    /// (`Block_byref_2` keep/destroy when HAS_COPY_DISPOSE, then `Block_byref_3` layout when the
    /// layout kind is EXTENDED) and of the variable payload that follows them.
    struct ByrefHeader: Equatable, Sendable {
        let isa: UInt64
        let forwarding: UInt64
        let flags: UInt32
        let size: UInt32
        /// `BLOCK_BYREF_LAYOUT_*` in bits 28–31: 0 none, 1 extended, 2 non-object, 3 strong,
        /// 4 weak, 5 unretained.
        let layoutKind: UInt32
        let keep: UInt32?
        let destroy: UInt32?
        let layout: UInt32?
        let payloadOffset: UInt32

        init(_ bytes: [UInt8]) throws {
            guard bytes.count >= 24 else { throw Failure.truncated }
            isa = BlocksABI.u64(bytes, 0)
            forwarding = BlocksABI.u64(bytes, 8)
            flags = BlocksABI.u32(bytes, 16)
            size = BlocksABI.u32(bytes, 20)
            layoutKind = flags >> 28
            guard flags & BlocksABI.byrefUnassignedFlags == 0, layoutKind <= 5 else { throw Failure.reserved }
            var cursor = BlocksABI.byrefHeaderSize
            if flags & Flags.hasCopyDispose.rawValue != 0 {
                keep = cursor
                destroy = cursor + 8
                cursor += 16
            } else {
                keep = nil
                destroy = nil
            }
            if layoutKind == 1 {
                layout = cursor
                cursor += 8
            } else {
                layout = nil
            }
            guard size >= cursor else { throw Failure.invalid }
            // A strong/weak/unretained cell holds at least one object pointer.
            if layoutKind >= 3 && size - cursor < 8 { throw Failure.invalid }
            guard UInt64(size - cursor) <= BlocksABI.maxCaptureBytes else { throw Failure.limit }
            payloadOffset = cursor
        }
    }

    static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    static func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        UInt64(u32(bytes, at)) | UInt64(u32(bytes, at + 4)) << 32
    }
}
