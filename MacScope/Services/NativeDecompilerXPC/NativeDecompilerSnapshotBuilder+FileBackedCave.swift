import Foundation

extension NativeDecompilerSnapshotBuilder {
    struct FileBackedCave {
        let range: Range<UInt64>
        let regions: [NativeDecompilerWireMemoryRegion]
    }

    /// Analysis functions use [start, next start), which includes compiler alignment
    /// after a terminal return. A cave in that padding must not be sent to the native
    /// worker as original function code. Admit only an exact tail-padding replacement:
    /// the raw branch site was a return, any intervening bytes are inert, and the
    /// patch fills the complete padding run up to the next function boundary.
    static func fileBackedBodyRange(
        nominalRange: Range<UInt64>,
        patches: [UInt64: BytePatch],
        rawRegions: [NativeDecompilerWireMemoryRegion],
        analysis: ImageAnalysis,
        workspace: WorkspaceSnapshot,
        imageSlot: ImageSlot,
        rawCPUType: Int32
    ) throws -> Range<UInt64> {
        guard rawCPUType == MachOConstants.cpuTypeARM64 else { return nominalRange }
        var candidates: [(source: UInt64, target: UInt64)] = []
        for (address, patch) in patches where nominalRange.contains(address) && patch.bytes.count == 4 {
            guard address <= UInt64.max - 4,
                  let target = directBranchTarget(address: address, patch: patch),
                  target >= address + 4, nominalRange.contains(target),
                  let tail = rawBytes(in: target ..< nominalRange.upperBound, from: rawRegions),
                  rawPadding(tail) else { continue }
            candidates.append((address, target))
        }
        guard !candidates.isEmpty else { return nominalRange }
        guard candidates.count == 1 else {
            throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
        }
        let (source, target) = candidates[0]
        let bodyEnd = source + 4
        guard let originalReturn = rawBytes(in: source ..< bodyEnd, from: rawRegions),
              ARM64Decoder().decode(originalReturn, baseAddress: source, maxInstructionCount: 1)
                  .first?.flow == .return,
              let gap = rawBytes(in: bodyEnd ..< target, from: rawRegions),
              inertAlignment(gap),
              let cavePatch = patches[target], !cavePatch.isEmpty,
              cavePatch.bytes.count.isMultiple(of: 4),
              UInt64(cavePatch.bytes.count) == nominalRange.upperBound - target,
              patches.allSatisfy({ address, patch in
                  patch.isEmpty || address == source || address == target ||
                      (address <= bodyEnd && UInt64(patch.bytes.count) <= bodyEnd - address) ||
                      address >= nominalRange.upperBound
              }),
              !analysis.xrefs.contains(where: { xref in
                  (bodyEnd ..< nominalRange.upperBound).contains(xref.to) ||
                      (bodyEnd ..< nominalRange.upperBound).contains(xref.from)
              }),
              !analysis.symbols.contains(where: {
                  $0.address.map((bodyEnd ..< nominalRange.upperBound).contains) ?? false
              }),
              !analysis.codeDataRanges.contains(where: { data in
                  guard let end = data.endAddress else { return true }
                  return data.address < nominalRange.upperBound && bodyEnd < end
              }),
              !workspace.codeExcludedAddresses(in: imageSlot).contains(where:
                  (bodyEnd ..< nominalRange.upperBound).contains)
        else { throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction }
        try rejectRelocations(analysis.relocations, intersecting: bodyEnd ..< nominalRange.upperBound)
        return nominalRange.lowerBound ..< bodyEnd
    }

    /// The nominal range was already checked against the loader attestation once.
    /// Slice that verified projection instead of hashing the same segment again.
    static func clippedFunctionRegions(
        _ regions: [NativeDecompilerWireMemoryRegion], to bodyRange: Range<UInt64>
    ) throws -> [NativeDecompilerWireMemoryRegion] {
        var clipped: [NativeDecompilerWireMemoryRegion] = []
        var cursor = bodyRange.lowerBound
        for region in regions {
            let start = region.startAddress.value
            guard UInt64(region.rawBytes.count) <= UInt64.max - start else {
                throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
            }
            let end = start + UInt64(region.rawBytes.count)
            let lower = max(start, cursor)
            let upper = min(end, bodyRange.upperBound)
            guard lower < upper else { continue }
            guard lower == cursor, region.appliedPatchIDs.isEmpty else {
                throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
            }
            let slice = Int(lower - start) ..< Int(upper - start)
            clipped.append(.init(
                name: region.name, startAddress: .init(lower),
                permissions: region.permissions,
                rawBytes: region.rawBytes.subdata(in: slice),
                effectiveBytes: region.effectiveBytes.subdata(in: slice),
                appliedPatchIDs: []
            ))
            cursor = upper
            if cursor == bodyRange.upperBound { break }
        }
        guard cursor == bodyRange.upperBound else {
            throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
        }
        return clipped
    }

    /// Sparse code is admitted only when the existing Save Patched Binary writer can
    /// export the same captured thin Mach-O and patch map. The cave occupies bytes in
    /// one verified executable section; it never extends the selected slice or image.
    static func fileBackedCave(
        selectedSliceBytes: Data,
        binary: BinaryImage,
        analysis: ImageAnalysis,
        workspace: WorkspaceSnapshot,
        imageSlot: ImageSlot,
        functionRange: Range<UInt64>,
        nominalFunctionRange: Range<UInt64>,
        selectedFunctionID: UUID,
        patches: [UInt64: BytePatch],
        layout: [VerifiedSegment],
        artifact: MachOSliceArtifactIdentity,
        attestationErrors: [NativeDecompilerSnapshotProjectionError?],
        budgets: NativeDecompilerWireAnalysisBudgets
    ) throws -> FileBackedCave? {
        guard artifact.rawCPUType == MachOConstants.cpuTypeARM64 else { return nil }
        var destinations: [UInt64] = []
        for (address, patch) in patches where functionRange.contains(address) && patch.bytes.count == 4 {
            guard let target = directBranchTarget(address: address, patch: patch) else { continue }
            if !functionRange.contains(target) { destinations.append(target) }
        }
        guard !destinations.isEmpty else { return nil }
        guard destinations.count == 1, let target = destinations.first,
              target >= functionRange.upperBound,
              target.isMultiple(of: 4),
              let cavePatch = patches[target],
              !cavePatch.isEmpty,
              cavePatch.bytes.count.isMultiple(of: 4),
              cavePatch.bytes.count <= BytePatch.maxByteCount,
              UInt64(cavePatch.bytes.count) <= UInt64(budgets.maxCodeBytes)
                - (functionRange.upperBound - functionRange.lowerBound)
        else { throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction }
        let end = target.addingReportingOverflow(UInt64(cavePatch.bytes.count))
        guard !end.overflow else { throw NativeDecompilerSnapshotProjectionError.invalidPatchRange }
        let range = target ..< end.partialValue
        guard patches.allSatisfy({ address, patch in
            address == target || patch.isEmpty ||
                (address < target && UInt64(patch.bytes.count) <= target - address) ||
                address >= range.upperBound
        }),
              analysis.functions.allSatisfy({ function in
                  if function.id == selectedFunctionID && functionRange != nominalFunctionRange {
                      return range.upperBound == nominalFunctionRange.upperBound &&
                          function.startAddress == nominalFunctionRange.lowerBound &&
                          function.endAddress == nominalFunctionRange.upperBound
                  }
                  return function.endAddress <= range.lowerBound || function.startAddress >= range.upperBound
              }),
              analysis.codeDataRanges.allSatisfy({ data in
                  guard let end = data.endAddress else { return false }
                  return end <= range.lowerBound || data.address >= range.upperBound
              }),
              !analysis.xrefs.contains(where: { range.contains($0.to) || range.contains($0.from) }),
              !analysis.symbols.contains(where: { $0.address.map(range.contains) ?? false }),
              !workspace.codeExcludedAddresses(in: imageSlot).contains(where: range.contains),
              let section = analysis.sections.first(where: { section in
                  section.isExecutable && !section.isZeroFill &&
                      section.address <= target &&
                      section.size <= UInt64.max - section.address &&
                      range.upperBound <= section.address + section.size
              }),
              analysis.sections.filter({ section in
                  section.size <= UInt64.max - section.address &&
                      section.address < range.upperBound &&
                      range.lowerBound < section.address + section.size
              }).count == 1,
              section.fileSize.map({ UInt64(cavePatch.bytes.count) <= $0 &&
                  target - section.address <= $0 - UInt64(cavePatch.bytes.count) }) ?? true,
              binary.captureOrigin == .thinFile
        else { throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction }

        try rejectRelocations(analysis.relocations, intersecting: range)
        // SLEIGH can read beyond the final cave word while decoding it. Include
        // only sealed bytes from the same file-backed RX section, as context;
        // the cave's code range still ends at the last patch-authored word.
        let sectionFileSize = min(section.size, section.fileSize ?? section.size)
        guard sectionFileSize <= UInt64.max - section.address,
              let segment = layout.first(where: {
                  $0.record.preferredVMStart <= target &&
                      range.upperBound <= $0.fileBackedVirtualEnd &&
                      $0.record.initialProtections & readProtection != 0 &&
                      $0.record.initialProtections & executeProtection != 0 &&
                      $0.record.initialProtections & writeProtection == 0
              }) else { throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction }
        let availableEnd = min(section.address + sectionFileSize, segment.fileBackedVirtualEnd)
        guard availableEnd >= range.upperBound,
              decoderLookaheadBytes <= UInt64.max - range.upperBound,
              availableEnd - range.upperBound >= decoderLookaheadBytes
        else { throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction }
        let projectedEnd = range.upperBound + decoderLookaheadBytes
        let regions = try projectMemoryRegions(
            selectedSliceBytes: selectedSliceBytes, layout: layout,
            functionRange: target ..< projectedEnd,
            attestationErrors: attestationErrors
        )
        guard regions.count == 1,
              regions[0].rawBytes.count >= cavePatch.bytes.count,
              rawPadding(regions[0].rawBytes.subdata(in: 0 ..< cavePatch.bytes.count))
        else { throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction }
        // This is the product's actual export mapping/format authority. It rejects
        // universal slices, invalid Mach-O structure, section/segment disagreement,
        // non-file-backed edits and overlapping edits before v4 can be published.
        do {
            let exported = try MachOPatchWriter().makePatchedData(
                originalData: selectedSliceBytes, patches: patches
            )
            // The writer parses the captured input. Parse the changed output once as
            // well, since the accepted cave must live in a valid exported Mach-O.
            _ = try MachOPatchWriter().makePatchedData(
                originalData: exported, patches: [:]
            )
        } catch {
            throw NativeDecompilerSnapshotProjectionError.invalidPatchRange
        }
        return FileBackedCave(range: range, regions: regions)
    }

    static func regionsWithFileBackedCave(
        _ existing: [NativeDecompilerWireMemoryRegion],
        cave: FileBackedCave?,
        selectedSliceBytes: Data,
        layout: [VerifiedSegment],
        attestationErrors: [NativeDecompilerSnapshotProjectionError?]
    ) throws -> [NativeDecompilerWireMemoryRegion] {
        guard let cave else { return existing }
        guard cave.regions.count == 1, let caveRegion = cave.regions.first,
              UInt64(caveRegion.rawBytes.count) <= UInt64.max - caveRegion.startAddress.value
        else { throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage }
        var lower = caveRegion.startAddress.value
        var upper = lower + UInt64(caveRegion.rawBytes.count)
        var consumed = Set<Int>()
        var changed = true
        while changed {
            changed = false
            for (index, region) in existing.enumerated() where !consumed.contains(index) {
                let start = region.startAddress.value
                guard UInt64(region.rawBytes.count) <= UInt64.max - start else {
                    throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
                }
                let end = start + UInt64(region.rawBytes.count)
                guard start <= upper && lower <= end else { continue }
                guard region.name == caveRegion.name,
                      region.permissions == caveRegion.permissions else {
                    throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
                }
                consumed.insert(index)
                lower = min(lower, start)
                upper = max(upper, end)
                changed = true
            }
        }
        if consumed.isEmpty {
            return (existing + cave.regions).sorted {
                ($0.startAddress.value, $0.name) < ($1.startAddress.value, $1.name)
            }
        }
        let projected = try projectMemoryRegions(
            selectedSliceBytes: selectedSliceBytes, layout: layout,
            functionRange: lower ..< upper,
            attestationErrors: attestationErrors
        )
        guard projected.count == 1, let union = projected.first,
              union.name == caveRegion.name,
              union.permissions == caveRegion.permissions else {
            throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
        }
        for region in [caveRegion] + existing.enumerated().compactMap({
            consumed.contains($0.offset) ? $0.element : nil
        }) {
            let offset = Int(region.startAddress.value - lower)
            let end = offset + region.rawBytes.count
            guard end <= union.rawBytes.count,
                  union.rawBytes.subdata(in: offset ..< end) == region.rawBytes else {
                throw NativeDecompilerSnapshotProjectionError.effectiveLoadImageAuthorityUnavailable
            }
        }
        var result = existing.enumerated().compactMap {
            consumed.contains($0.offset) ? nil : $0.element
        }
        result.append(union)
        return result.sorted { ($0.startAddress.value, $0.name) < ($1.startAddress.value, $1.name) }
    }

    private static func rawPadding(_ bytes: Data) -> Bool {
        guard bytes.count.isMultiple(of: 4) else { return false }
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let word = bytes.subdata(in: offset ..< offset + 4)
            if word != Data(repeating: 0, count: 4) &&
                word != Data([0x1f, 0x20, 0x03, 0xd5]) { return false }
        }
        return true
    }

    private static func inertAlignment(_ bytes: Data) -> Bool {
        guard bytes.count.isMultiple(of: 4) else { return false }
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let word = bytes.subdata(in: offset ..< offset + 4)
            if word != Data(repeating: 0, count: 4) &&
                word != Data([0x1f, 0x20, 0x03, 0xd5]) &&
                word != Data([0x20, 0x00, 0x20, 0xd4]) { return false }
        }
        return true
    }

    private static func rawBytes(
        in range: Range<UInt64>, from regions: [NativeDecompilerWireMemoryRegion]
    ) -> Data? {
        var bytes = Data()
        var cursor = range.lowerBound
        for region in regions.sorted(by: { $0.startAddress.value < $1.startAddress.value }) {
            let start = region.startAddress.value
            guard UInt64(region.rawBytes.count) <= UInt64.max - start else { return nil }
            let end = start + UInt64(region.rawBytes.count)
            let lower = max(start, cursor)
            let upper = min(end, range.upperBound)
            guard lower < upper else { continue }
            guard lower == cursor else { return nil }
            bytes.append(region.rawBytes.subdata(in: Int(lower - start) ..< Int(upper - start)))
            cursor = upper
            if cursor == range.upperBound { return bytes }
        }
        return cursor == range.upperBound ? bytes : nil
    }

    private static func directBranchTarget(address: UInt64, patch: BytePatch) -> UInt64? {
        guard patch.bytes.count == 4 else { return nil }
        let word = patch.bytes.enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << (UInt32($1.offset) * 8))
        }
        // ARM64 B immediate, excluding BL.
        guard word & 0xfc00_0000 == 0x1400_0000 else { return nil }
        let displacement = (Int64(word & 0x03ff_ffff) << 38) >> 36
        if displacement >= 0 {
            let sum = address.addingReportingOverflow(UInt64(displacement))
            return sum.overflow ? nil : sum.partialValue
        }
        return address >= UInt64(-displacement) ? address - UInt64(-displacement) : nil
    }
}
