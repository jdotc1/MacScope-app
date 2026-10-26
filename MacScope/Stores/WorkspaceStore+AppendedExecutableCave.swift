import Foundation

@MainActor
extension WorkspaceStore {
    /// Author one appended ARM64 code body for a selected function. The edit is anchored at the
    /// function entry, so the existing slot-qualified override undo and package persistence own
    /// it. Admission to a signed output and to native analysis happens separately at use time.
    @discardableResult
    func setAppendedExecutableCave(
        functionID: UUID, in slot: ImageSlot,
        branchSourceAddress: UInt64, codeBytes: Data
    ) -> Bool {
        guard let binary = snapshot.binary(in: slot),
              let analysis = snapshot.analysis(in: slot),
              let function = analysis.functions.first(where: { $0.id == functionID }),
              function.startAddress < function.endAddress,
              function.endAddress >= 4,
              function.startAddress <= branchSourceAddress,
              branchSourceAddress <= function.endAddress - 4,
              branchSourceAddress.isMultiple(of: 4),
              binary.captureOrigin == .thinFile,
              let artifact = binary.artifactIdentity,
              artifact.rawCPUType == MachOConstants.cpuTypeARM64,
              artifact.selectedSliceByteCount == UInt64(analysis.imageBytes.count)
        else {
            lastIssue = "Select an ARM64 function in a captured thin Mach-O before appending executable code."
            return false
        }
        let key = ImageAddress(slot: slot, address: function.startAddress)
        var authored = snapshot.addressOverrides[key] ?? AddressOverride()
        guard !snapshot.addressOverrides.contains(where: { otherKey, otherOverride in
            otherKey.slot == slot && otherKey != key &&
                otherOverride.appendedExecutableCave != nil
        }) else {
            lastIssue = "Only one appended executable cave is supported per image. Clear the existing cave first."
            return false
        }
        let cave = AppendedExecutableCaveAuthoring(
            ownerBinaryID: binary.id, functionID: functionID,
            selectedSliceSHA256: artifact.selectedSliceSHA256,
            branchSourceAddress: branchSourceAddress, codeBytes: codeBytes
        )
        guard cave.isWellFormed,
              snapshot.patches(in: slot).allSatisfy({ address, patch in
                  if patch.isEmpty { return true }
                  if address >= branchSourceAddress + 4 { return true }
                  return address < branchSourceAddress &&
                      UInt64(patch.bytes.count) <= branchSourceAddress - address
              }) else {
            lastIssue = "The cave is malformed or its branch site overlaps an existing byte patch."
            return false
        }
        authored.appendedExecutableCave = cave
        lastIssue = nil
        applyOverride(key, authored, actionName: "Append Code")
        return true
    }

    @discardableResult
    func clearAppendedExecutableCave(at entry: UInt64, in slot: ImageSlot) -> Bool {
        let key = ImageAddress(slot: slot, address: entry)
        guard var authored = snapshot.addressOverrides[key], authored.appendedExecutableCave != nil else {
            lastIssue = "No appended code remains at this entry in the selected image."
            return false
        }
        authored.appendedExecutableCave = nil
        lastIssue = nil
        applyOverride(key, authored, actionName: "Clear Appended Code")
        return true
    }
}
