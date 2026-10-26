import Foundation

/// Callee-side Darwin arm64 `va_list` traversal for ordinary C variadics
/// (`va_start`, `va_arg`, `va_copy`, `va_end`) over an immutable memory snapshot.
///
/// Apple arm64 departs from AAPCS64 here: every anonymous argument is passed on the
/// stack, never in x0-x7/v0-v7, and `va_list` is a plain `char *` (8 bytes), not the
/// 32-byte AAPCS64 `{__stack, __gr_top, __vr_top, __gr_offs, __vr_offs}` record. So
/// `va_copy` is a pointer copy and `va_start` is callee-entry SP plus the named stack
/// extent rounded up to 8. Each `va_arg` aligns the cursor to max(8, natural alignment)
/// (16 for `__int128` and 16-byte-aligned records), reads the value inline when it is a
/// scalar, a record of at most 16 bytes or a float/double HFA of any size, and otherwise
/// reads an 8-byte pointer to the record; the cursor advances by the slot rounded up to 8.
///
/// Types, default promotions, carrier classification and the named prefix are inputs:
/// nothing here guesses a signature from bytes. Every failure leaves the cursor
/// unchanged, and returned values are derived reconstruction evidence only.
public enum DarwinARM64Variadic {
    public static let profileID = "darwin-arm64-c17-varargs-v1"
    /// `va_list` on Darwin arm64 is `char *`.
    public static let vaListByteCount = 8
    public static let slotByteCount: UInt64 = 8
    public static let maximumArguments = FormatStringParser.maximumArguments
    public static let maximumValueBytes = 4096
    /// Bound on the named stack extent and, separately, on any read slot's end
    /// relative to callee-entry SP.
    public static let maximumNamedStackExtent: UInt64 = 4096
    public static let maximumIncomingStackBytes: UInt64 = 8192

    public enum Fault: Error, Equatable, Sendable {
        case invalidMetadata(String)
        case unsupportedProfile(String)
        case unboundNamedParameter(index: Int)
        case arithmeticOverflow
        case misalignedEntrySP
        case stackBounds
        case ended
        case exhausted
        case typeMismatch(expected: String, requested: String)
        case identityMismatch
        case unreadable(AddressRange)
        case shortRead(expected: Int, actual: Int)
        case invalidIndirectPointer(address: UInt64, alignment: UInt64)
    }

    /// Half-open, nonempty range; an unrepresentable exclusive end is refused.
    public struct AddressRange: Equatable, Sendable {
        public let start: UInt64
        public let byteCount: UInt64
        public let end: UInt64

        public init(start: UInt64, byteCount: UInt64) throws {
            guard byteCount > 0 else { throw Fault.invalidMetadata("empty address range") }
            self.start = start
            self.byteCount = byteCount
            self.end = try checkedAdd(start, byteCount)
        }

        func contains(_ other: AddressRange) -> Bool { start <= other.start && other.end <= end }
    }

    /// Image identity alone does not distinguish two memory snapshots of that image.
    public struct SnapshotIdentity: Equatable, Sendable {
        public let imageID: String
        public let snapshotID: String

        public init(imageID: String, snapshotID: String) throws {
            try validateID(imageID)
            try validateID(snapshotID)
            self.imageID = imageID
            self.snapshotID = snapshotID
        }
    }

    /// A meaningful field range of a value. Padding never appears in these ranges.
    public struct ValueByteRange: Equatable, Sendable {
        public let offset: Int
        public let byteCount: Int
        public let end: Int

        public init(offset: Int, byteCount: Int) throws {
            let (end, overflow) = offset.addingReportingOverflow(byteCount)
            guard offset >= 0, byteCount > 0, !overflow else {
                throw Fault.invalidMetadata("invalid value byte range")
            }
            self.offset = offset
            self.byteCount = byteCount
            self.end = end
        }
    }

    /// The already established transport of one anonymous argument; not a classifier.
    public enum Carrier: Equatable, Sendable {
        case direct
        case homogeneousFloat(baseByteCount: Int, memberCount: Int)
        case indirectPointer64
    }

    public struct ArgumentDescriptor: Equatable, Sendable {
        /// The type the caller wrote (`char`, `float`) and the promoted type `va_arg`
        /// reads (`int`, `double`); identical when no promotion applies.
        public let sourceTypeID: String
        public let extractionTypeID: String
        public let valueByteCount: Int
        public let valueAlignment: UInt64
        public let carrier: Carrier
        public let meaningfulBytes: [ValueByteRange]

        public init(
            sourceTypeID: String,
            extractionTypeID: String,
            valueByteCount: Int,
            valueAlignment: UInt64,
            carrier: Carrier,
            meaningfulBytes: [ValueByteRange]
        ) throws {
            try validateID(sourceTypeID)
            try validateID(extractionTypeID)
            guard (1...maximumValueBytes).contains(valueByteCount),
                  [UInt64(1), 2, 4, 8, 16].contains(valueAlignment),
                  valueByteCount % Int(valueAlignment) == 0,
                  (1...128).contains(meaningfulBytes.count) else {
                throw Fault.invalidMetadata("unsupported size, alignment, or field count")
            }
            var previousEnd = 0
            var meaningfulCount = 0
            for field in meaningfulBytes {
                guard field.offset >= previousEnd, field.end <= valueByteCount else {
                    throw Fault.invalidMetadata("fields must be ordered, disjoint, and within the value")
                }
                previousEnd = field.end
                meaningfulCount += field.byteCount
            }
            switch carrier {
            case .direct:
                guard valueByteCount <= 16 else {
                    throw Fault.invalidMetadata("direct values over 16 bytes require an HFA carrier")
                }
            case let .homogeneousFloat(base, count):
                guard [4, 8].contains(base), (1...4).contains(count),
                      valueByteCount == base * count, valueAlignment == UInt64(base),
                      meaningfulCount == valueByteCount else {
                    throw Fault.invalidMetadata("invalid natural float/double HFA")
                }
            case .indirectPointer64:
                guard valueByteCount > 16 else {
                    throw Fault.invalidMetadata("an indirect record must exceed 16 bytes")
                }
            }
            self.sourceTypeID = sourceTypeID
            self.extractionTypeID = extractionTypeID
            self.valueByteCount = valueByteCount
            self.valueAlignment = valueAlignment
            self.carrier = carrier
            self.meaningfulBytes = meaningfulBytes
        }

        /// The descriptor of one argument a constant format consumes. Format arguments
        /// are already promoted scalars, so source and extraction types coincide.
        public init(formatArgument argument: FormatStringParser.Argument) throws {
            let width = argument.readByteWidth
            try self.init(
                sourceTypeID: argument.type,
                extractionTypeID: argument.type,
                valueByteCount: width,
                valueAlignment: UInt64(width),
                carrier: .direct,
                meaningfulBytes: [ValueByteRange(offset: 0, byteCount: width)]
            )
        }
    }

    /// The callee-entry stack bytes that the complete named prefix occupies: the end of
    /// the furthest stack carrier among `bindRich` locations, an indirect record's
    /// stack carrier counting as one 8-byte pointer. Register rows add nothing. Any
    /// unbound row refuses, because a partial prefix cannot place `va_start`.
    public static func namedStackExtent(of locations: [DarwinARM64RichParameterLocation]) throws -> UInt64 {
        var extent: UInt64 = 0
        for (index, location) in locations.enumerated() {
            let offset: Int
            let size: Int
            switch location {
            case .gpr, .simd, .composite, .indirect(pointer: .gpr, _, _):
                continue
            case let .entryStack(byteOffset, byteSize, _):
                offset = byteOffset
                size = byteSize
            case let .indirect(pointer: .entryStack(byteOffset), _, _):
                offset = byteOffset
                size = 8
            case .unbound:
                throw Fault.unboundNamedParameter(index: index)
            }
            guard offset >= 0, size > 0 else { throw Fault.invalidMetadata("negative named stack location") }
            extent = max(extent, try checkedAdd(UInt64(offset), UInt64(size)))
        }
        guard extent <= maximumNamedStackExtent else {
            throw Fault.invalidMetadata("named stack extent exceeds budget")
        }
        return extent
    }

    public struct ReadableRegion: Equatable, Sendable {
        public let id: String
        public let range: AddressRange

        public init(id: String, range: AddressRange) throws {
            try validateID(id)
            self.id = id
            self.range = range
        }
    }

    public enum ReadPurpose: Equatable, Sendable { case directValue, pointerCarrier, indirectValue }

    /// One request, already bounded to a single declared immutable region.
    public struct BoundedReadRequest: Equatable, Sendable {
        public let identity: SnapshotIdentity
        public let regionID: String
        public let range: AddressRange
        public let purpose: ReadPurpose
    }

    public struct ReadEvidence: Equatable, Sendable {
        public let identity: SnapshotIdentity
        public let regionID: String
        public let range: AddressRange
    }

    struct ReadResult {
        let bytes: [UInt8]
        let evidence: [ReadEvidence]
    }

    /// Serves exact reads from declared, non-overlapping regions of one snapshot. The
    /// closure must answer from that snapshot without process reads or mutation; bounds
    /// and response lengths are enforced here, content authenticity is the caller's.
    public struct SnapshotReader: Sendable {
        public let identity: SnapshotIdentity
        private let regions: [ReadableRegion]
        private let body: @Sendable (BoundedReadRequest) throws -> [UInt8]

        public init(
            identity: SnapshotIdentity,
            regions: [ReadableRegion],
            read: @escaping @Sendable (BoundedReadRequest) throws -> [UInt8]
        ) throws {
            guard (1...128).contains(regions.count), Set(regions.map(\.id)).count == regions.count else {
                throw Fault.invalidMetadata("regions must have unique IDs and a bounded count")
            }
            let sorted = regions.sorted { $0.range.start < $1.range.start }
            var end: UInt64 = 0
            var total: UInt64 = 0
            for region in sorted {
                guard region.range.start >= end else { throw Fault.invalidMetadata("overlapping snapshot regions") }
                total = try checkedAdd(total, region.range.byteCount)
                guard total <= 16 * 1024 * 1024 else { throw Fault.invalidMetadata("snapshot exceeds 16 MiB budget") }
                end = region.range.end
            }
            self.identity = identity
            self.regions = sorted
            self.body = read
        }

        func readExactly(_ range: AddressRange, purpose: ReadPurpose) throws -> ReadResult {
            guard range.byteCount <= UInt64(maximumValueBytes) else {
                throw Fault.invalidMetadata("read exceeds value byte budget")
            }
            var position = range.start
            var requests: [BoundedReadRequest] = []
            for region in regions {
                if position >= region.range.end { continue }
                if region.range.start > position { break }
                let end = min(range.end, region.range.end)
                requests.append(BoundedReadRequest(
                    identity: identity, regionID: region.id,
                    range: try AddressRange(start: position, byteCount: end - position), purpose: purpose))
                position = end
                if position == range.end { break }
            }
            guard position == range.end else { throw Fault.unreadable(range) }
            var bytes: [UInt8] = []
            var evidence: [ReadEvidence] = []
            for request in requests {
                let chunk = try body(request)
                guard chunk.count == Int(request.range.byteCount) else {
                    throw Fault.shortRead(expected: Int(request.range.byteCount), actual: chunk.count)
                }
                bytes.append(contentsOf: chunk)
                evidence.append(ReadEvidence(identity: identity, regionID: request.regionID, range: request.range))
            }
            return ReadResult(bytes: bytes, evidence: evidence)
        }
    }

    public enum Lifetime: Equatable, Sendable { case active, ended }

    /// One `va_arg` result: reconstruction evidence, never an observed runtime fact.
    public struct DerivedValue: Equatable, Sendable {
        public let identity: SnapshotIdentity
        public let descriptor: ArgumentDescriptor
        public let argumentIndex: Int
        public let cursorBefore: UInt64
        public let cursorAfter: UInt64
        public let slotRange: AddressRange
        public let payloadRange: AddressRange
        /// The meaningful field bytes in field order; padding is excluded.
        public let canonicalBytes: [UInt8]
        public let carrierEvidence: [ReadEvidence]
        public let payloadEvidence: [ReadEvidence]
    }

    /// A `va_list` value. Value semantics make `copied()` an independent `va_copy`
    /// at the current position; copying never clones argument memory.
    public struct Cursor: Equatable, Sendable {
        public let identity: SnapshotIdentity
        public let entrySP: UInt64
        public let namedStackExtent: UInt64
        public let incomingStackBounds: AddressRange
        public private(set) var nextAddress: UInt64
        public private(set) var nextArgumentIndex = 0
        public private(set) var lifetime = Lifetime.active
        private let arguments: [ArgumentDescriptor]

        /// `entrySP` is SP at callee entry, before any prologue adjustment.
        public init(
            profileID: String = DarwinARM64Variadic.profileID,
            identity: SnapshotIdentity,
            entrySP: UInt64,
            namedStackExtent: UInt64,
            incomingStackBounds: AddressRange,
            arguments: [ArgumentDescriptor]
        ) throws {
            guard profileID == DarwinARM64Variadic.profileID else { throw Fault.unsupportedProfile(profileID) }
            guard entrySP % 16 == 0 else { throw Fault.misalignedEntrySP }
            guard namedStackExtent <= maximumNamedStackExtent, arguments.count <= maximumArguments else {
                throw Fault.invalidMetadata("named extent or argument count exceeds budget")
            }
            let initial = try aligned(checkedAdd(entrySP, namedStackExtent), to: slotByteCount)
            guard incomingStackBounds.start <= entrySP, initial <= incomingStackBounds.end else {
                throw Fault.stackBounds
            }
            self.identity = identity
            self.entrySP = entrySP
            self.namedStackExtent = namedStackExtent
            self.incomingStackBounds = incomingStackBounds
            self.nextAddress = initial
            self.arguments = arguments
        }

        public func copied() throws -> Self {
            guard lifetime == .active else { throw Fault.ended }
            return self
        }

        public mutating func end() throws {
            guard lifetime == .active else { throw Fault.ended }
            lifetime = .ended
        }

        /// `va_arg(ap, typeID)`. State changes only after every read has succeeded.
        public mutating func extract(typeID: String, using reader: SnapshotReader) throws -> DerivedValue {
            guard lifetime == .active else { throw Fault.ended }
            guard nextArgumentIndex < arguments.count else { throw Fault.exhausted }
            let argument = arguments[nextArgumentIndex]
            guard typeID == argument.extractionTypeID else {
                throw Fault.typeMismatch(expected: argument.extractionTypeID, requested: typeID)
            }
            guard reader.identity == identity else { throw Fault.identityMismatch }
            let indirect = argument.carrier == .indirectPointer64
            let alignment = indirect ? slotByteCount : max(slotByteCount, argument.valueAlignment)
            let slotSize = try indirect ? slotByteCount : aligned(UInt64(argument.valueByteCount), to: slotByteCount)
            let slot = try AddressRange(start: aligned(nextAddress, to: alignment), byteCount: slotSize)
            guard incomingStackBounds.contains(slot), slot.end - entrySP <= maximumIncomingStackBytes else {
                throw Fault.stackBounds
            }
            var payloadAddress = slot.start
            var carrierEvidence: [ReadEvidence] = []
            if indirect {
                let carrier = try reader.readExactly(slot, purpose: .pointerCarrier)
                payloadAddress = carrier.bytes.enumerated().reduce(UInt64(0)) {
                    $0 | (UInt64($1.element) << (8 * $1.offset))
                }
                guard payloadAddress != 0, payloadAddress % argument.valueAlignment == 0 else {
                    throw Fault.invalidIndirectPointer(address: payloadAddress, alignment: argument.valueAlignment)
                }
                carrierEvidence = carrier.evidence
            }
            let payload = try AddressRange(start: payloadAddress, byteCount: UInt64(argument.valueByteCount))
            let read = try reader.readExactly(payload, purpose: indirect ? .indirectValue : .directValue)
            let canonical = argument.meaningfulBytes.flatMap { read.bytes[$0.offset..<$0.end] }
            let result = DerivedValue(
                identity: identity, descriptor: argument, argumentIndex: nextArgumentIndex,
                cursorBefore: nextAddress, cursorAfter: slot.end, slotRange: slot, payloadRange: payload,
                canonicalBytes: canonical, carrierEvidence: carrierEvidence, payloadEvidence: read.evidence)
            nextAddress = slot.end
            nextArgumentIndex += 1
            return result
        }
    }

    static func checkedAdd(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw Fault.arithmeticOverflow }
        return result
    }

    static func aligned(_ value: UInt64, to alignment: UInt64) throws -> UInt64 {
        let remainder = value % alignment
        return try checkedAdd(value, remainder == 0 ? 0 : alignment - remainder)
    }

    static func validateID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw Fault.invalidMetadata("identifier must be 1...256 printable ASCII bytes")
        }
    }
}
