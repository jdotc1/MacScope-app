import Foundation

/// A span of the exact captured selected-image payload. Offsets are payload-relative; this type
/// performs NO virtual-address mapping (that stays with `FileAddressMapping`, alias checks included).
struct ByteExtent: Equatable, Sendable {
    enum ValidationError: Error, Equatable { case invalidExtent }

    let offset: UInt64
    let count: UInt64
    var endExclusive: UInt64 { offset + count }

    init(offset: UInt64, count: UInt64, payloadSize: UInt64) throws {
        guard count > 0, offset <= payloadSize, count <= payloadSize - offset else {
            throw ValidationError.invalidExtent
        }
        self.offset = offset
        self.count = count
    }
}

/// Maps a captured-payload span to a navigable virtual-address range through the EXISTING
/// `FileAddressMapping` authority. Pass `snapshot.imageByteMappings(in: slot)` with the explicit
/// image slot. A span that is unmapped, crosses mappings or hides an interior alias stays
/// payload-only rather than inventing one VA range.
enum SupplementalNavigationTarget: Equatable {
    case virtualAddress(start: UInt64, byteCount: Int)
    case payloadOnly(offset: UInt64, byteCount: UInt64)
}

enum SupplementalNavigationAdapter {
    static func target(for extent: ByteExtent,
                       mappings: [FileAddressMapping]) -> SupplementalNavigationTarget {
        let unmapped = SupplementalNavigationTarget.payloadOnly(
            offset: extent.offset, byteCount: extent.count)
        guard let start = Int(exactly: extent.offset),
              let count = Int(exactly: extent.count), count > 0,
              count <= Int.max - start,
              let address = FileAddressMapping.resolvedVirtualAddress(
                forFileOffset: extent.offset, in: mappings),
              FileAddressMapping.resolvedFileRange(
                forVirtualAddress: address, count: count, in: mappings)
                == start..<(start + count) else { return unmapped }
        return .virtualAddress(start: address, byteCount: count)
    }
}
