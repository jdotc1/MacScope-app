import Foundation

extension NativeDecompilerSnapshotBuilder {
    struct AppendedCave {
        let range: Range<UInt64>
        let branchSourceAddress: UInt64
        let branchPatch: BytePatch
        let region: NativeDecompilerWireMemoryRegion
    }

    /// Admit exactly the bytes that the signed-layout writer would export. The captured Mach-O
    /// remains the raw authority for existing regions. The new region's raw view is its newly
    /// allocated zero-filled RX payload; its effective view is the authored output bytes.
    static func appendedCave(
        authored: AppendedExecutableCaveAuthoring,
        workspace: WorkspaceSnapshot,
        binary: BinaryImage,
        artifact: MachOSliceArtifactIdentity,
        selectedSliceBytes: Data,
        imageSlot: ImageSlot,
        functionID: UUID,
        functionRange: Range<UInt64>,
        patches: [UInt64: BytePatch],
        mappedLayout: [VerifiedSegment],
        contextRegions: [NativeDecompilerWireMemoryRegion],
        sortedXRefs: [XRef],
        budgets: NativeDecompilerWireAnalysisBudgets
    ) throws -> AppendedCave {
        guard authored.isWellFormed,
              authored.ownerBinaryID == binary.id,
              authored.functionID == functionID,
              authored.selectedSliceSHA256 == artifact.selectedSliceSHA256,
              binary.captureOrigin == .thinFile,
              artifact.rawCPUType == MachOConstants.cpuTypeARM64,
              functionRange.contains(authored.branchSourceAddress),
              authored.branchSourceAddress <= functionRange.upperBound - 4,
              UInt64(authored.codeBytes.count) <= UInt64(budgets.maxCodeBytes)
                - (functionRange.upperBound - functionRange.lowerBound),
              workspace.addressOverrides.filter({ $0.key.slot == imageSlot &&
                  $0.value.appendedExecutableCave != nil }).count == 1
        else { throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction }

        // Moving __LINKEDIT changes its VA. A selected function with any retained context or
        // observed reference into that segment cannot safely use the old address authority.
        let movedLinks = mappedLayout.filter { $0.record.name == "__LINKEDIT" }
        guard movedLinks.count == 1, let movedLink = movedLinks.first,
              movedLink.record.preferredVMStart <= UInt64.max - movedLink.record.preferredVMSize
        else { throw NativeDecompilerSnapshotProjectionError.invalidPatchRange }
        let movedRange = movedLink.record.preferredVMStart ..<
            movedLink.record.preferredVMStart + movedLink.record.preferredVMSize
        guard !sortedXRefs.contains(where: {
            functionRange.contains($0.from) && movedRange.contains($0.to)
        }), !contextRegions.contains(where: { region in
            let start = region.startAddress.value
            guard start <= UInt64.max - UInt64(region.rawBytes.count) else { return true }
            return start < movedRange.upperBound && movedRange.lowerBound < start + UInt64(region.rawBytes.count)
        }) else { throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction }

        let output: MachOPatchWriter.AppendedExecutableCave
        do {
            output = try MachOPatchWriter().makePatchedDataWithAppendedExecutableCave(
                originalData: selectedSliceBytes, patches: patches,
                caveBytes: authored.codeBytes,
                branchSourceAddress: authored.branchSourceAddress
            )
        } catch {
            throw NativeDecompilerSnapshotProjectionError.invalidPatchRange
        }
        guard output.byteCount == authored.codeBytes.count,
              output.branchSourceAddress == authored.branchSourceAddress,
              let word = output.branchInstruction,
              output.virtualAddress.isMultiple(of: 4),
              output.virtualAddress <= UInt64.max - UInt64(output.byteCount),
              let offset = Int(exactly: output.fileOffset),
              offset <= output.data.count,
              authored.codeBytes.count <= output.data.count - offset,
              Int(decoderLookaheadBytes) <= output.data.count - offset - authored.codeBytes.count
        else { throw NativeDecompilerSnapshotProjectionError.invalidPatchRange }
        let codeEnd = output.virtualAddress + UInt64(output.byteCount)
        let mappedCount = output.byteCount + Int(decoderLookaheadBytes)
        let effective = output.data.subdata(in: offset ..< offset + mappedCount)
        guard effective.prefix(output.byteCount) == authored.codeBytes,
              effective.suffix(Int(decoderLookaheadBytes)).allSatisfy({ $0 == 0 })
        else { throw NativeDecompilerSnapshotProjectionError.invalidPatchRange }
        let branchBytes = (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        let region = NativeDecompilerWireMemoryRegion(
            name: "__MSCAVE", startAddress: .init(output.virtualAddress),
            permissions: .readExecute,
            rawBytes: Data(repeating: 0, count: mappedCount),
            effectiveBytes: effective,
            appliedPatchIDs: ["patch999999"]
        )
        return AppendedCave(
            range: output.virtualAddress ..< codeEnd,
            branchSourceAddress: authored.branchSourceAddress,
            branchPatch: BytePatch(bytes: branchBytes), region: region
        )
    }
}
