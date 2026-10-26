import Foundation

/// Resolves call/branch and data-reference targets that land in a linkage section
/// (`__stubs`, `__auth_stubs`, `__objc_stubs`, `__got`, `__auth_got`, `__la_symbol_ptr`,
/// `__nl_symbol_ptr`) to the imported symbol name they forward to.
///
/// On a stripped binary a `bl 0x100004abc` to an import stub shows only an address; the indirect
/// symbol table the Mach-O parser already resolved (`IndirectSymbolSummary.address` →
/// `.symbolName`) maps each stub/pointer slot to its symbol, so the call can be rendered as
/// `_printf` / `_objc_msgSend` / `_$s…` instead of a bare address.
///
/// Pure and `Sendable`: a function of the indirect-symbol table only — no I/O, no shared mutable
/// state. The `AnalysisEngine` builds one per analysis and uses `name(forStubTarget:)` to LABEL the
/// stub-slot addresses (so the listing and every call/data xref into them resolve to a name).
struct StubCallSymbolicator: Sendable {
    /// Sections whose entries forward 1:1 to an imported symbol via the indirect-symbol table.
    /// Mirrors `AnalysisDiagnosticsCollector.isLinkageSection` / `GoldenGate`'s stub list.
    static let linkageSections: Set<String> = [
        "__stubs", "__auth_stubs", "__objc_stubs",
        "__got", "__auth_got", "__la_symbol_ptr", "__nl_symbol_ptr",
    ]

    /// What a linkage slot IS, independent of the symbol name it is labelled with. A name
    /// resolving through a slot is not evidence that the slot is callable code: GOT and lazy /
    /// non-lazy pointer slots are DATA holding an address, while `__stubs`-family entries are
    /// executable forwarding code. Consumers that model callable code (call-graph vertices,
    /// thunk/import classification) must use this rather than `linkageSections` membership.
    enum LinkageSlotClass: Sendable, Hashable {
        /// Executable code in a Mach-O `S_SYMBOL_STUBS` section that forwards to one import.
        case executableImportStub
        /// Executable `__objc_stubs` code that loads a selector and forwards to
        /// `objc_msgSend`. It is a thunk inside this image, never an imported library function.
        case objcSelectorStub
        /// A data pointer slot (`__got`, `__auth_got`, `__la_symbol_ptr`, `__nl_symbol_ptr`).
        case dataPointer
    }

    /// Executable `S_SYMBOL_STUBS` section names (ARM64/ARM64e and the legacy PIC/non-PIC
    /// stub spellings). Only these, plus `__objc_stubs`, can hold callable forwarding code.
    static let executableImportStubSections: Set<String> = [
        "__stubs", "__auth_stubs",
        "__symbol_stub", "__symbol_stub1", "__symbol_stub4",
        "__picsymbol_stub", "__picsymbolstub1", "__picsymbolstub2", "__picsymbolstub4",
    ]

    static let objcSelectorStubSections: Set<String> = ["__objc_stubs"]

    static let dataPointerSections: Set<String> = [
        "__got", "__auth_got", "__la_symbol_ptr", "__nl_symbol_ptr",
    ]

    /// The class a section NAME (bare, or qualified `SEGMENT,section`) declares, or nil for a
    /// non-linkage section.
    static func linkageSlotClass(sectionName: String) -> LinkageSlotClass? {
        let bare = sectionName.split(separator: ",").last.map(String.init) ?? sectionName
        if executableImportStubSections.contains(bare) { return .executableImportStub }
        if objcSelectorStubSections.contains(bare) { return .objcSelectorStub }
        if dataPointerSections.contains(bare) { return .dataPointer }
        return nil
    }

    /// The class of one loader indirect-symbol row, or nil when the row is not a linkage row OR
    /// its declared kind contradicts its section (callers must then abstain). A pointer-section
    /// row is always data whatever its declared kind; an executable-stub row additionally needs
    /// the loader's `S_SYMBOL_STUBS` kind. `__objc_stubs` never has indirect rows, so one there
    /// is malformed.
    static func linkageSlotClass(for entry: IndirectSymbolSummary) -> LinkageSlotClass? {
        switch linkageSlotClass(sectionName: entry.sourceSection) {
        case .executableImportStub?:
            return entry.kind == MachOIndirectSymbolKind.symbolStub.rawValue ? .executableImportStub : nil
        case .dataPointer?:
            return .dataPointer
        case .objcSelectorStub?, nil:
            return nil
        }
    }

    /// Stub / pointer-slot virtual address → the imported symbol name it resolves to.
    let nameByStubAddress: [UInt64: String]

    /// - Parameter objcStubNames: `__objc_stubs` entry VA → `_objc_msgSend$<selector>` from
    ///   `ObjCStubSelectorRecovery`. Those stubs have no indirect-symbol rows; an indirect-symbol
    ///   name for the same address still wins.
    init(indirectSymbols: [IndirectSymbolSummary], objcStubNames: [UInt64: String] = [:]) {
        var map: [UInt64: String] = [:]
        for entry in indirectSymbols {
            // `sourceSection` is the QUALIFIED name (`__TEXT,__stubs`, `__DATA_CONST,__got`); match
            // on the section-name component so it works regardless of which segment holds the slot.
            let sectionName = entry.sourceSection.split(separator: ",").last.map(String.init) ?? entry.sourceSection
            guard Self.linkageSections.contains(sectionName) else { continue }
            // Local / absolute slots do not forward to an import — skip them rather than mislabel.
            guard !entry.isLocal, !entry.isAbsolute else { continue }
            guard let name = entry.symbolName, !name.isEmpty else { continue }
            // First writer wins: the table is ordered, and a slot maps to exactly one symbol; a later
            // duplicate address (corrupt input) must not silently rename an already-resolved stub.
            if map[entry.address] == nil {
                map[entry.address] = name
            }
        }
        for (address, name) in objcStubNames where map[address] == nil {
            map[address] = name
        }
        nameByStubAddress = map
    }

    var isEmpty: Bool { nameByStubAddress.isEmpty }

    /// The imported symbol name a call/branch/data reference to `targetAddress` resolves to, or nil
    /// when the target is not a known import stub / pointer slot.
    func name(forStubTarget targetAddress: UInt64) -> String? {
        nameByStubAddress[targetAddress]
    }
}
