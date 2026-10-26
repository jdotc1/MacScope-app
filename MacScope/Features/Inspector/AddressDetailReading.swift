import Foundation

/// Pure, GUI-free resolution of "what is at this address?" for the address-detail
/// panel. Reuses the snapshot's existing landmark collections (sections, symbols,
/// functions, addressOverrides, xrefs) without reaching into any private store
/// helper, so the resolution stays fully unit-testable.
///
/// Every comparison uses non-wrapping 64-bit arithmetic against attacker-influenced
/// fields (a section's `address`/`size` can come from a raw on-disk u64), so a
/// malformed section that would wrap `address + size` is treated as not containing
/// the address rather than spuriously matching it.
struct AddressDetailReading: Equatable {
    /// The address that was resolved (echoed back for display).
    let address: UInt64
    /// The section whose half-open `[address, address+size)` range contains the
    /// target, if any. Zero-fill sections still count (they own VA space).
    let section: SectionSummary?
    /// The nearest symbol/function at-or-before the address, with the byte offset
    /// past its start. Nil when no landmark precedes the address.
    let nearestSymbolName: String?
    let nearestSymbolAddress: UInt64?
    let nearestSymbolOffset: UInt64?
    /// The user override applied at the exact address (rename/comment/tag/type/data-mark).
    let appliedName: String?
    let appliedComment: String?
    let appliedTag: String?
    let appliedTypeName: String?
    let isMarkedAsData: Bool
    /// Cross-reference summary counts at the exact address.
    let referencesToCount: Int
    let referencesFromCount: Int

    init(address: UInt64, snapshot: WorkspaceSnapshot, imageSlot: ImageSlot? = nil) {
        self.address = address
        let slot = imageSlot ?? snapshot.primarySlot
        let analysis = snapshot.analysis(in: slot)

        self.section = Self.section(containing: address, in: analysis?.sections ?? [])

        let nearest = Self.nearestSymbol(
            to: address,
            functions: analysis?.functions ?? [],
            symbols: analysis?.symbols ?? [],
            snapshot: snapshot,
            imageSlot: slot
        )
        self.nearestSymbolName = nearest?.name
        self.nearestSymbolAddress = nearest?.address
        self.nearestSymbolOffset = nearest.map { address - $0.address }

        let override = snapshot.overrides(in: slot)[address]
        // Normalize empty strings to nil so an empty override field doesn't render
        // as a blank row.
        self.appliedName = override?.customName.flatMap { $0.isEmpty ? nil : $0 }
        self.appliedComment = override?.customComment.flatMap { $0.isEmpty ? nil : $0 }
        self.appliedTag = override?.tag.flatMap { $0.isEmpty ? nil : $0 }
        // Resolve the applied type through the catalog so a dangling name degrades
        // to nil (matching snapshot.appliedType).
        self.appliedTypeName = override?.appliedTypeName.flatMap { name in
            guard !name.isEmpty, snapshot.typeDefinitions.contains(where: { $0.name == name }) else { return nil }
            return name
        }
        self.isMarkedAsData = snapshot.isData(at: address, in: slot)

        self.referencesToCount = snapshot.effectiveXRefs(to: address, in: slot).count
        self.referencesFromCount = snapshot.effectiveXRefs(from: address, in: slot).count
    }

    /// True when the address lands inside a known section. Used to distinguish a
    /// reachable address from one outside the whole binary's mapped space.
    var isInSection: Bool { section != nil }

    /// The rendered "Symbol+offset" string, e.g. "_main+0x14" or "_main" at the
    /// exact start. Nil when no symbol precedes the address.
    var symbolWithOffset: String? {
        guard let name = nearestSymbolName, let offset = nearestSymbolOffset else { return nil }
        if offset == 0 { return name }
        return "\(name)+0x" + String(offset, radix: 16, uppercase: false)
    }

    /// True when any user override fact is present at the address.
    var hasOverride: Bool {
        appliedName != nil || appliedComment != nil || appliedTag != nil
            || appliedTypeName != nil || isMarkedAsData
    }

    /// Ordered label/value rows for the panel, omitting absent facts. The view binds
    /// directly to these.
    var rows: [(label: String, value: String, isMonospaced: Bool)] {
        var rows: [(label: String, value: String, isMonospaced: Bool)] = []
        rows.append((label: "Address", value: address.hexAddress, isMonospaced: true))
        rows.append((label: "Section", value: section?.name ?? "(none)", isMonospaced: false))
        if let symbolWithOffset {
            rows.append((label: "Symbol", value: symbolWithOffset, isMonospaced: true))
        }
        if let appliedName {
            rows.append((label: "Name", value: appliedName, isMonospaced: false))
        }
        if let appliedTypeName {
            rows.append((label: "Type", value: appliedTypeName, isMonospaced: false))
        }
        if let appliedTag {
            rows.append((label: "Tag", value: appliedTag, isMonospaced: false))
        }
        if isMarkedAsData {
            rows.append((label: "Kind", value: "Data", isMonospaced: false))
        }
        if let appliedComment {
            rows.append((label: "Comment", value: appliedComment, isMonospaced: false))
        }
        rows.append((label: "Refs to", value: "\(referencesToCount)", isMonospaced: false))
        rows.append((label: "Refs from", value: "\(referencesFromCount)", isMonospaced: false))
        return rows
    }

    // MARK: - Pure resolution helpers

    /// The section whose half-open range contains `address`, using non-wrapping
    /// arithmetic (`address < section.address + section.size` computed so an
    /// overflowing `address + size` simply fails the test). When sections overlap,
    /// the lowest-start match wins, deterministically.
    static func section(containing address: UInt64, in sections: [SectionSummary]) -> SectionSummary? {
        sections
            .filter { section in
                guard section.address <= address else { return false }
                let (end, overflow) = section.address.addingReportingOverflow(section.size)
                if overflow { return address >= section.address }
                return address < end
            }
            .min { lhs, rhs in
                if lhs.address == rhs.address { return lhs.name < rhs.name }
                return lhs.address < rhs.address
            }
    }

    private struct Landmark {
        let name: String
        let address: UInt64
    }

    /// The nearest named landmark at-or-before `address`: the highest-start function
    /// or addressed symbol whose start is `<= address`. Functions are preferred (and
    /// honor renames); ties on address prefer the function. Returns nil when nothing
    /// precedes the address.
    private static func nearestSymbol(
        to address: UInt64,
        functions: [FunctionSummary],
        symbols: [SymbolSummary],
        snapshot: WorkspaceSnapshot,
        imageSlot: ImageSlot
    ) -> Landmark? {
        var best: Landmark?
        func consider(_ candidateAddress: UInt64, _ name: String) {
            guard candidateAddress <= address else { return }
            if let current = best, current.address >= candidateAddress { return }
            best = Landmark(name: name, address: candidateAddress)
        }
        for function in functions {
            let name = snapshot.displayName(at: function.startAddress, in: imageSlot, default: function.name)
            consider(function.startAddress, name)
        }
        for symbol in symbols {
            guard let symbolAddress = symbol.address else { continue }
            consider(symbolAddress, symbol.name)
        }
        // A user local label is the nearest landmark when it sits between the procedure
        // start and the address ("loc_retry+0x4"); ties keep the function/symbol name.
        for (labelAddress, label) in snapshot.localLabels(in: imageSlot) {
            consider(labelAddress, label)
        }
        return best
    }
}
