import Foundation

extension WorkspaceStore {
    /// Preserve the numeric image/runtime address and show its original COFF section offset.
    /// Selection, authoring and navigation continue to use the numeric analysis coordinate.
    func displayAddressString(_ imageVA: UInt64) -> String {
        let numeric: String
        switch addressDisplayMode {
        case .image:
            numeric = imageVA.hexAddress
        case .runtime:
            numeric = imageLayout.runtimeVA(ImageAddress(slot: focusedImageSlot, address: imageVA)).hexAddress
        }
        guard let label = coffSectionOffsetLabel(for: imageVA, in: focusedImageSlot) else {
            return numeric
        }
        return "\(numeric) (\(label))"
    }

    /// Use the exact row's image, and abstain if malformed/overlapping metadata is ambiguous.
    func coffSectionOffsetLabel(for address: UInt64, in slot: ImageSlot) -> String? {
        let sections = snapshot.analysis(in: slot)?.sections ?? []
        let matches = sections.filter { section in
            guard section.coffCoordinate?.layoutVersion == 1,
                  section.size > 0, address >= section.address else { return false }
            return address - section.address < section.size
        }
        guard matches.count == 1, let section = matches.first,
              let coordinate = section.coffCoordinate, coordinate.sectionOrdinal > 0 else { return nil }
        let offset = address - section.address
        let label = "\(section.name)+0x\(String(offset, radix: 16))"
        let duplicateName = sections.filter { $0.coffCoordinate != nil && $0.name == section.name }.count > 1
        return duplicateName ? "\(label) [section \(coordinate.sectionOrdinal)]" : label
    }

    /// Reserve space beside the numeric address without changing other binary formats.
    var coffSectionAddressColumnExtraWidth: Double {
        let sections = snapshot.analysis(in: focusedImageSlot)?.sections ?? []
        let nameCounts = Dictionary(grouping: sections.filter { $0.coffCoordinate != nil }, by: \.name)
            .mapValues(\.count)
        let maxCharacters = sections.compactMap { section -> Int? in
            guard let coordinate = section.coffCoordinate, coordinate.layoutVersion == 1 else { return nil }
            let duplicateName = nameCounts[section.name, default: 0] > 1
            let suffix = duplicateName ? " [section \(coordinate.sectionOrdinal)]".count : 0
            return section.name.count + 11 + suffix
        }.max() ?? 0
        return maxCharacters == 0 ? 0 : Double(maxCharacters * 8 + 8)
    }
}
