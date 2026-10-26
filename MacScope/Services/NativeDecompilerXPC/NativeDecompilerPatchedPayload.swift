import Foundation

/// A bounded view of patches over the verified selected slice. The artifact bytes and
/// their loader attestation remain raw; only materialized request regions become effective.
struct NativeDecompilerPatchedPayload: Sendable {
    static let maximumEdits = 4_096
    static let maximumEditedBytes = 1_048_576

    enum Failure: Error, Equatable {
        case tooManyEdits
        case tooManyEditedBytes
        case outOfPayload
        case regionMappingMismatch
    }

    struct Region: Sendable, Equatable {
        let rawBytes: Data
        let effectiveBytes: Data
        /// Index into the address-sorted overlay, retained in overlay order. An edit
        /// crossing two request regions can appear in each; wire IDs are assigned later.
        let appliedEditIndices: [Int]
        let appliedFileRanges: [Range<Int>]
    }

    private let overlay: BytePatchOverlay
    private let mappings: [FileAddressMapping]
    private let selectedSliceByteCount: Int

    init(
        patches: [UInt64: BytePatch],
        mappings: [FileAddressMapping],
        selectedSliceByteCount: Int
    ) throws {
        guard selectedSliceByteCount > 0 else { throw Failure.outOfPayload }
        let overlay = try BytePatchOverlay(patches: patches, mappings: mappings)
        guard overlay.edits.count <= Self.maximumEdits else { throw Failure.tooManyEdits }
        var editedBytes = 0
        for edit in overlay.edits {
            guard edit.bytes.count <= Self.maximumEditedBytes - editedBytes else {
                throw Failure.tooManyEditedBytes
            }
            editedBytes += edit.bytes.count
            guard let range = FileAddressMapping.resolvedFileRange(
                forVirtualAddress: edit.address,
                count: edit.bytes.count,
                in: mappings
            ), range.upperBound <= selectedSliceByteCount else {
                throw Failure.outOfPayload
            }
        }
        self.overlay = overlay
        self.mappings = mappings
        self.selectedSliceByteCount = selectedSliceByteCount
    }

    func region(
        rawBytes: Data,
        at startAddress: UInt64,
        sliceRelativeFileOffset: UInt64
    ) throws -> Region {
        guard !rawBytes.isEmpty,
              let fileStart = Int(exactly: sliceRelativeFileOffset),
              fileStart <= selectedSliceByteCount,
              rawBytes.count <= selectedSliceByteCount - fileStart,
              startAddress <= UInt64.max - UInt64(rawBytes.count)
        else { throw Failure.outOfPayload }

        let endAddress = startAddress + UInt64(rawBytes.count)
        var indices: [Int] = []
        var ranges: [Range<Int>] = []
        for (index, edit) in overlay.edits.enumerated()
        where edit.address < endAddress && startAddress < edit.endAddress {
            let overlapStart = max(startAddress, edit.address)
            let overlapEnd = min(endAddress, edit.endAddress)
            let overlapCount = Int(overlapEnd - overlapStart)
            let expectedStart = fileStart + Int(overlapStart - startAddress)
            guard let mapped = FileAddressMapping.resolvedFileRange(
                forVirtualAddress: overlapStart,
                count: overlapCount,
                in: mappings
            ), mapped.lowerBound == expectedStart else {
                throw Failure.regionMappingMismatch
            }
            indices.append(index)
            ranges.append(mapped)
        }
        guard let effective = overlay.applying(to: rawBytes, at: startAddress) else {
            throw Failure.outOfPayload
        }
        return Region(
            rawBytes: rawBytes,
            effectiveBytes: effective,
            appliedEditIndices: indices,
            appliedFileRanges: ranges
        )
    }
}
