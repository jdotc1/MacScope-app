import Foundation

/// Check effective ARM64 control flow after the patch overlay. The optional v4
/// cave is a second, bounded file-backed code range established by the builder.
enum NativeDecompilerPatchedControlFlowAdmission {
    static func check(
        regions: [NativeDecompilerWireMemoryRegion],
        functionRange: Range<UInt64>,
        caveRange: Range<UInt64>? = nil,
        rawCPUType: Int32
    ) throws {
        guard rawCPUType == MachOConstants.cpuTypeARM64 else { return }
        guard regions.contains(where: { !$0.appliedPatchIDs.isEmpty }) else { return }
        var raw = Data()
        var effective = Data()
        var cursor = functionRange.lowerBound
        for region in regions {
            let start = region.startAddress.value
            let end = start + UInt64(region.rawBytes.count)
            let lower = max(start, cursor)
            let upper = min(end, functionRange.upperBound)
            guard lower < upper else { continue }
            guard lower == cursor else {
                throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
            }
            let slice = Int(lower - start)..<Int(upper - start)
            raw.append(region.rawBytes.subdata(in: slice))
            effective.append(region.effectiveBytes.subdata(in: slice))
            cursor = upper
            if cursor == functionRange.upperBound { break }
        }
        guard cursor == functionRange.upperBound, raw.count == effective.count,
              raw.count.isMultiple(of: 4) else {
            throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
        }
        let decoder = ARM64Decoder()
        var reachedCave = false
        for offset in stride(from: 0, to: raw.count, by: 4) {
            let wordRange = offset..<(offset + 4)
            guard raw.subdata(in: wordRange) != effective.subdata(in: wordRange) else { continue }
            let address = functionRange.lowerBound + UInt64(offset)
            guard let instruction = decoder.decode(
                effective.subdata(in: wordRange), baseAddress: address, maxInstructionCount: 1
            ).first, instruction.mnemonic != "unavailable" else {
                throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
            }
            switch instruction.flow {
            case .jump, .conditionalJump:
                guard let target = instruction.branchTarget,
                      (functionRange.contains(target) ||
                        (instruction.flow == .jump && target == caveRange?.lowerBound)) else {
                    throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
                }
                if target == caveRange?.lowerBound { reachedCave = true }
                if instruction.flow == .conditionalJump,
                   address + 4 == functionRange.upperBound {
                    throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
                }
            case .indirectJump:
                throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
            default:
                break
            }
        }
        guard let caveRange else { return }
        guard reachedCave else {
            throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
        }
        var cave = Data()
        var caveCursor = caveRange.lowerBound
        for region in regions {
            let start = region.startAddress.value
            guard UInt64(region.rawBytes.count) <= UInt64.max - start else {
                throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
            }
            let end = start + UInt64(region.rawBytes.count)
            let lower = max(start, caveCursor)
            let upper = min(end, caveRange.upperBound)
            guard lower < upper else { continue }
            guard lower == caveCursor, !region.appliedPatchIDs.isEmpty else {
                throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
            }
            cave.append(region.effectiveBytes.subdata(in: Int(lower - start)..<Int(upper - start)))
            caveCursor = upper
            if caveCursor == caveRange.upperBound { break }
        }
        guard caveCursor == caveRange.upperBound, cave.count.isMultiple(of: 4) else {
            throw NativeDecompilerSnapshotProjectionError.invalidFunctionCoverage
        }
        var caveSuccessors: [UInt64: [UInt64]] = [:]
        for offset in stride(from: 0, to: cave.count, by: 4) {
            let address = caveRange.lowerBound + UInt64(offset)
            guard let instruction = decoder.decode(
                cave.subdata(in: offset..<(offset + 4)),
                baseAddress: address, maxInstructionCount: 1
            ).first, instruction.mnemonic != "unavailable" else {
                throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
            }
            switch instruction.flow {
            case .jump, .conditionalJump:
                guard let target = instruction.branchTarget,
                      functionRange.contains(target) || caveRange.contains(target),
                      instruction.flow != .conditionalJump || address + 4 < caveRange.upperBound
                else { throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction }
                caveSuccessors[address] = (caveRange.contains(target) ? [target] : []) +
                    (instruction.flow == .conditionalJump ? [address + 4] : [])
            case .indirectJump:
                throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
            case .normal, .call, .indirectCall:
                guard address + 4 < caveRange.upperBound else {
                    throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
                }
                caveSuccessors[address] = [address + 4]
            case .return, .trap:
                caveSuccessors[address] = []
            }
        }
        var reached: Set<UInt64> = []
        var pending = [caveRange.lowerBound]
        while let address = pending.popLast() {
            guard caveRange.contains(address), caveSuccessors[address] != nil else {
                throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
            }
            if reached.insert(address).inserted {
                pending.append(contentsOf: caveSuccessors[address] ?? [])
            }
        }
        guard reached.count == cave.count / 4 else {
            throw NativeDecompilerSnapshotProjectionError.patchedControlFlowLeavesFunction
        }
    }
}
