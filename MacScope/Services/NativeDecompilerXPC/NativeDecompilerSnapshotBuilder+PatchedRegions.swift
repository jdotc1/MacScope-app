import Foundation

extension NativeDecompilerSnapshotBuilder {
    /// The verified loader layout maps raw artifact offsets. Patch materialization is
    /// request-local and never changes that layout or the retained artifact bytes.
    static func materializePatchedRegions(
        _ regions: [NativeDecompilerWireMemoryRegion],
        patches: [UInt64: BytePatch],
        layout: [VerifiedSegment],
        selectedSliceByteCount: Int
    ) throws -> [NativeDecompilerWireMemoryRegion] {
        guard patches.values.contains(where: { !$0.isEmpty }) else { return regions }
        let mappings = layout.compactMap { segment -> FileAddressMapping? in
            let size = segment.fileBackedVirtualEnd - segment.record.preferredVMStart
            guard size > 0 else { return nil }
            return FileAddressMapping(
                fileOffset: segment.record.sliceRelativeFileOffset,
                size: size,
                virtualAddress: segment.record.preferredVMStart,
                sectionName: segment.record.name
            )
        }
        let payload: NativeDecompilerPatchedPayload
        do {
            payload = try NativeDecompilerPatchedPayload(
                patches: patches,
                mappings: mappings,
                selectedSliceByteCount: selectedSliceByteCount
            )
        } catch {
            throw NativeDecompilerSnapshotProjectionError.invalidPatchRange
        }

        var nextPatchID = 0
        return try regions.map { region in
            let start = region.startAddress.value
            let (end, overflow) = start.addingReportingOverflow(UInt64(region.rawBytes.count))
            guard !overflow,
                  region.rawBytes == region.effectiveBytes,
                  let segment = layout.first(where: {
                      $0.record.preferredVMStart <= start && end <= $0.fileBackedVirtualEnd
                  })
            else { throw NativeDecompilerSnapshotProjectionError.invalidProjectedRequest }
            let displacement = start - segment.record.preferredVMStart
            let (fileOffset, fileOverflow) = segment.record.sliceRelativeFileOffset.addingReportingOverflow(displacement)
            guard !fileOverflow else { throw NativeDecompilerSnapshotProjectionError.invalidPatchRange }
            let materialized: NativeDecompilerPatchedPayload.Region
            do {
                materialized = try payload.region(
                    rawBytes: region.rawBytes,
                    at: start,
                    sliceRelativeFileOffset: fileOffset
                )
            } catch {
                throw NativeDecompilerSnapshotProjectionError.invalidPatchRange
            }
            guard materialized.appliedEditIndices.count <= 100_000 - nextPatchID else {
                throw NativeDecompilerSnapshotProjectionError.invalidPatchRange
            }
            let ids = materialized.appliedEditIndices.map { _ -> String in
                nextPatchID += 1
                return String(format: "patch%06d", nextPatchID)
            }
            return NativeDecompilerWireMemoryRegion(
                name: region.name,
                startAddress: region.startAddress,
                permissions: region.permissions,
                rawBytes: materialized.rawBytes,
                effectiveBytes: materialized.effectiveBytes,
                appliedPatchIDs: ids
            )
        }
    }
}
