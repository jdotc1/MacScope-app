import Foundation

/// Where a user/decoder comment sits relative to the instruction it annotates.
///
/// The listing draws two comment forms: an *inline* trailing comment in the
/// instruction's comment column (the common case), and a *prefix* own-line comment
/// rendered on its own row immediately above the instruction (used for longer,
/// block-style notes). The `AddressOverride` model does not yet carry an explicit
/// placement flag, so `derivedDefault(forComment:)` picks a sensible form from the
/// comment text itself — see that method for the rule.
enum ListingCommentPlacement: String, Equatable, Sendable {
    /// Trailing comment in the instruction row's own comment column.
    case inline
    /// Own-line comment rendered on a dedicated row above the instruction.
    case prefix

    /// The default placement for `comment`, derived from its text because the model
    /// carries no explicit placement flag yet (flagged under integrationRisks).
    ///
    /// Rule: a multi-line comment, or a long single-line comment (one that would not
    /// fit a trailing column), reads better as an own-line *prefix* row; everything
    /// else stays *inline*. The width threshold is deliberately generous so the
    /// overwhelmingly common short note keeps its familiar trailing position.
    static func derivedDefault(forComment comment: String) -> ListingCommentPlacement {
        if comment.contains("\n") { return .prefix }
        if comment.count > Self.inlineLengthThreshold { return .prefix }
        return .inline
    }

    /// Comments longer than this (single-line) are promoted to an own-line prefix row.
    static let inlineLengthThreshold = 60
}

/// One row in the generated disassembly listing. The existing instruction/data rows
/// are preserved verbatim as `.instruction`; this model *additively* interleaves
/// `.sectionHeader` group rows at segment/section boundaries, standalone `.label`
/// rows at function starts / named addresses, and `.prefixComment` own-line comment
/// rows. The view layer renders each case; the interleaving itself is the pure,
/// testable `DisassemblyListingBuilder.build` below.
enum ListingRow: Equatable, Identifiable, Sendable {
    /// A segment/section group header, e.g. "__TEXT,__text".
    case sectionHeader(SectionHeaderRow)
    /// A standalone label row at a function start or named address, e.g. "_main:".
    case label(LabelRow)
    /// An own-line comment rendered above the instruction it annotates.
    case prefixComment(PrefixCommentRow)
    /// A decoded instruction (or data-marked) row — the pre-existing listing row.
    case instruction(InstructionRow)

    /// A stable identity for `ForEach`. Synthetic rows derive their id from the
    /// boundary address + a kind discriminator so they never collide with an
    /// instruction row (whose id is its address).
    var id: String {
        switch self {
        case let .sectionHeader(row): return "section@\(row.address.hexAddress):\(row.name)"
        case let .label(row): return "label@\(row.address.hexAddress)"
        case let .prefixComment(row): return "prefixcomment@\(row.address.hexAddress)"
        case let .instruction(row): return "insn@\(row.address.hexAddress)"
        }
    }

    /// The instruction payload when this row is an instruction, else nil.
    var instruction: InstructionRow? {
        if case let .instruction(row) = self { return row }
        return nil
    }
}

/// A section/segment group-header row at a section boundary.
struct SectionHeaderRow: Equatable, Sendable {
    /// The section's start virtual address (the boundary this header marks).
    var address: UInt64
    /// The display name, e.g. "__TEXT,__text" (segment-qualified when available).
    var name: String
    /// True when the section holds executable code (drives the view's icon/tone).
    var isExecutable: Bool
}

/// A standalone label row at a function start or named address.
struct LabelRow: Equatable, Sendable {
    /// The labelled address.
    var address: UInt64
    /// The display name (user override > symbol/function name), without a trailing colon.
    var name: String
    /// True when the label marks a discovered function start (vs a bare named address).
    var isFunctionStart: Bool
}

/// A rendered assembler data directive split into the listing's two columns. Used to
/// carry a shaped row's `(mnemonic, operands)` through the resolved-instruction map
/// (a tuple is not `Equatable` as a stored property).
struct DataDirective: Equatable, Sendable {
    var mnemonic: String
    var operands: String
}

/// An own-line comment row rendered above the instruction it annotates.
struct PrefixCommentRow: Equatable, Sendable {
    /// The address of the instruction this comment precedes.
    var address: UInt64
    /// The comment text (may contain newlines).
    var text: String
}

/// Builds the interleaved listing-row list from a snapshot. Pure and view-free so it
/// can be unit-tested in CoreTests; `DisassemblyView` calls `build` to drive its
/// `ForEach` instead of iterating `snapshot.instructions` directly.
enum DisassemblyListingBuilder {

    /// The resolved data the view needs for one instruction row, computed once here so
    /// the per-row closure work in the View shrinks to a lookup. The fields mirror the
    /// arguments `DisassemblyListingRow` (the SwiftUI view) already takes.
    struct ResolvedInstruction: Equatable, Sendable {
        var row: InstructionRow
        /// The inline (trailing) comment to show in the comment column, if any.
        var inlineComment: String?
        var tag: String?
        var colorTag: ColorTag?
        var isData: Bool
        /// True when the user marked this row UNDEFINED — it renders a raw `.byte`
        /// undefined directive (distinct from a plain data word) and is excluded from
        /// code analysis. Drawn like a data row but with the undefined directive.
        var isUndefined: Bool = false
        /// The assembler directive `(mnemonic, operands)` for an undefined row, computed
        /// once here from the raw bytes. nil for a non-undefined row.
        var undefinedDirective: DataDirective?
        /// True when the user PATCHED this row's bytes — the row already carries the
        /// re-decoded patched instruction (the engine re-decoded it); this flags the edit
        /// for the View. nil/false for an unpatched row.
        var isPatched: Bool = false
        /// The user-authored data shape at this row (array / alignment / string), if
        /// any. When set, the row renders the shape's directive instead of the plain
        /// `.long`/`.byte` derived from the raw bytes.
        var dataShape: DataShapeOverride?
        /// The pre-rendered directive `(mnemonic, operands)` for a shaped row, computed
        /// once here (the builder owns the snapshot's byte reader) so the View needs no
        /// binary access. nil for a non-shaped row.
        var shapeDirective: DataDirective?
        var operandFormat: OperandFormat?
        /// True when this row's address is the debugger's current program counter
        /// (the live-PC row), drawn with a distinct highlight from the breakpoint
        /// gutter and the selection. Pure flag — the View only renders it. Defaults
        /// to `false` so callers that do not pass a PC are unaffected.
        var isLiveProgramCounter: Bool = false
    }

    /// Pure mapping from a program counter to the listing row it falls on, mirroring
    /// the breakpoint/selection row-flag rule: a row is the *live-PC row* exactly when
    /// its instruction address equals `programCounter`. Returns the matching
    /// instruction's address, or `nil` when `programCounter` is `nil` or no row in the
    /// snapshot sits at that address (e.g. the PC is in a region not present in this
    /// listing). View-free and unit-testable.
    ///
    /// - Note: Matching is on the instruction's own start address. A PC that lands in
    ///   the *middle* of a (variable-length) instruction does not flag that row; the
    ///   live PC is, by construction, an instruction boundary while the process is
    ///   stopped, so an exact-address match is the correct rule and avoids falsely
    ///   lighting a row the PC merely overlaps.
    static func liveProgramCounterRowAddress(
        snapshot: WorkspaceSnapshot,
        programCounter: UInt64?,
        slot: ImageSlot? = nil
    ) -> UInt64? {
        guard let programCounter else { return nil }
        let instructions = snapshot.analysis(in: slot ?? snapshot.primarySlot)?.instructions ?? []
        return instructions.first { $0.address == programCounter }?.address
    }

    /// Produces the full row list: for each instruction, in address order, emit (in
    /// order) a section header when the instruction is the first at/after a section
    /// boundary, a label row when the address is a function start or named address, a
    /// prefix comment row when the resolved comment is placed own-line, then the
    /// instruction row itself (carrying only its inline comment when placement is
    /// inline).
    ///
    /// - Note: Instructions are sorted by address defensively; the snapshot is normally
    ///   already ordered, but sorting makes the boundary logic robust to either.
    static func build(snapshot: WorkspaceSnapshot, slot: ImageSlot? = nil) -> [ListingRow] {
        // Compatibility callers keep the original nonthrowing interface.
        try! build(snapshot: snapshot, slot: slot, checkCancellation: {})
    }

    private static func build(
        snapshot: WorkspaceSnapshot,
        slot: ImageSlot?,
        checkCancellation: () throws -> Void
    ) throws -> [ListingRow] {
        try checkCancellation()
        let s = slot ?? snapshot.primarySlot
        let analysis = snapshot.analysis(in: s)
        let instructions = (analysis?.instructions ?? []).sorted { $0.address < $1.address }
        try checkCancellation()
        guard !instructions.isEmpty else { return [] }

        // Section boundaries, sorted by address; each fires once, at the first
        // instruction whose address is >= the section start (so a header lands even if
        // no instruction sits exactly on the boundary).
        let sortedSections = (analysis?.sections ?? []).sorted { $0.address < $1.address }
        var nextSectionIndex = 0

        // Function starts and named (symbol-named) addresses → label rows.
        try checkCancellation()
        var functionStarts: Set<UInt64> = []
        for (index, function) in (analysis?.functions ?? []).enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            functionStarts.insert(function.startAddress)
        }
        let labelNames = try labelNameLookup(snapshot: snapshot, slot: s, checkCancellation: checkCancellation)

        var rows: [ListingRow] = []
        rows.reserveCapacity(instructions.count + sortedSections.count + functionStarts.count)

        for (index, instruction) in instructions.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let address = instruction.address

            // (a) Section/segment group headers at each boundary the row crosses.
            while nextSectionIndex < sortedSections.count,
                  sortedSections[nextSectionIndex].address <= address {
                if nextSectionIndex.isMultiple(of: 256) { try checkCancellation() }
                let section = sortedSections[nextSectionIndex]
                nextSectionIndex += 1
                rows.append(.sectionHeader(SectionHeaderRow(
                    address: section.address,
                    name: sectionDisplayName(section),
                    isExecutable: section.isExecutable
                )))
            }

            // (b) A standalone label row at a function start / named address.
            if let name = labelNames[address] {
                rows.append(.label(LabelRow(
                    address: address,
                    name: name,
                    isFunctionStart: functionStarts.contains(address)
                )))
            }

            // (c) A prefix comment row when the resolved comment is placed own-line.
            // (An inline comment instead rides the instruction row's comment column,
            // resolved per-address in `buildResolved`.)
            if let comment = resolvedComment(snapshot: snapshot, instruction: instruction, slot: s),
               ListingCommentPlacement.derivedDefault(forComment: comment) == .prefix {
                rows.append(.prefixComment(PrefixCommentRow(address: address, text: comment)))
            }

            rows.append(.instruction(instruction))
        }

        return rows
    }

    /// Builds the full row list *and* a per-address resolved-instruction map, so the
    /// View can render synthetic rows from `build` and look up each instruction's
    /// resolved comment/tag/color/format without re-deriving them. Kept separate from
    /// `build` so the simpler row-shape assertions stay easy to test.
    /// - Parameter liveProgramCounter: the debugger's current PC, or `nil` when the
    ///   process is not stopped at a live target. The single row whose address equals
    ///   it is flagged `isLiveProgramCounter`; all others are `false` (and every row
    ///   is `false` when this is `nil`), so resuming/exiting clears the highlight.
    static func buildResolved(
        snapshot: WorkspaceSnapshot,
        liveProgramCounter: UInt64? = nil,
        stringEncoding: StringDisplayEncoding = .default,
        slot: ImageSlot? = nil
    ) -> (rows: [ListingRow], resolved: [UInt64: ResolvedInstruction]) {
        try! buildResolved(
            snapshot: snapshot, liveProgramCounter: liveProgramCounter,
            stringEncoding: stringEncoding, slot: slot, checkCancellation: {}
        )
    }

    /// Preparation workers use this overload. Sorting is fenced before/after; row and
    /// label loops yield cancellation at most every 256 entries.
    static func buildResolved(
        snapshot: WorkspaceSnapshot,
        liveProgramCounter: UInt64? = nil,
        stringEncoding: StringDisplayEncoding = .default,
        slot: ImageSlot? = nil,
        checkCancellation: () throws -> Void
    ) throws -> (rows: [ListingRow], resolved: [UInt64: ResolvedInstruction]) {
        try checkCancellation()
        let s = slot ?? snapshot.primarySlot
        let rows = try build(snapshot: snapshot, slot: s, checkCancellation: checkCancellation)
        let pcRowAddress = liveProgramCounterRowAddress(
            snapshot: snapshot,
            programCounter: liveProgramCounter,
            slot: s
        )
        // One byte reader for the whole pass — shaped string directives read their
        // literal text from the loaded bytes through it.
        let reader = snapshot.hexByteReader(in: s)
        // Direct branch/call targets render by name (`bl _printf`) rather than raw hex.
        try checkCancellation()
        // Identical precedence to branchTargetNames (symbols, then functions, overrides
        // at each address); use the cancellable label pass for worker preparation.
        let symbolizer = BranchTargetSymbolizer(namesByAddress: try labelNameLookup(
            snapshot: snapshot, slot: s, checkCancellation: checkCancellation
        ))
        let patchOverlay = try? BytePatchOverlay(patches: snapshot.patches(in: s))
        try checkCancellation()
        var resolved: [UInt64: ResolvedInstruction] = [:]
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            guard let instruction = row.instruction else { continue }
            resolved[instruction.address] = resolvedInstruction(
                instruction, snapshot: snapshot, slot: s, encoding: stringEncoding, readBytes: reader,
                patchOverlay: patchOverlay, programCounterRow: pcRowAddress,
                symbolize: { symbolizer.symbolized($0, callsOnly: false) }
            )
        }
        try checkCancellation()
        return (rows, resolved)
    }

    /// One instruction's resolved row, exactly as `buildResolved` makes it. Callers that need a
    /// single row (the selection's accessibility label) use this instead of resolving the image.
    /// `symbolize` names branch/call targets; without it the row keeps its raw operands.
    static func resolvedInstruction(
        _ instruction: InstructionRow,
        snapshot: WorkspaceSnapshot,
        slot: ImageSlot,
        encoding: StringDisplayEncoding = .default,
        readBytes: ((_ virtualAddress: UInt64, _ count: Int) -> Data?)? = nil,
        patchOverlay: BytePatchOverlay?? = nil,
        programCounterRow: UInt64? = nil,
        symbolize: ((InstructionRow) -> InstructionRow)? = nil
    ) -> ResolvedInstruction {
        let address = instruction.address
        let comment = resolvedComment(snapshot: snapshot, instruction: instruction, slot: slot)
        let inline: String?
        if let comment, ListingCommentPlacement.derivedDefault(forComment: comment) == .inline {
            inline = comment
        } else {
            inline = nil
        }
        let interpretation = interpretation(of: instruction, snapshot: snapshot, slot: slot,
                                            encoding: encoding, readBytes: readBytes)
        let overlay = patchOverlay ?? (try? BytePatchOverlay(patches: snapshot.patches(in: slot)))
        return ResolvedInstruction(
            row: symbolize?(instruction) ?? instruction,
            inlineComment: inline,
            tag: snapshot.tag(at: address, in: slot),
            colorTag: snapshot.colorTag(at: address, in: slot),
            isData: interpretation.isData,
            isUndefined: interpretation.isUndefined,
            undefinedDirective: interpretation.undefinedDirective,
            isPatched: overlay.map {
                !$0.edits.isEmpty && $0.intersects(
                    address: address,
                    count: BytePatch.parse(hex: instruction.bytes)?.bytes.count ?? 0
                )
            } ?? false,
            dataShape: interpretation.dataShape,
            shapeDirective: interpretation.shapeDirective,
            operandFormat: snapshot.operandFormat(at: address, in: slot),
            isLiveProgramCounter: programCounterRow == address
        )
    }

    /// How the listing interprets one row: data or undefined, and the directive it shows instead of
    /// the instruction. The listing and the inspector both use this, so they always agree.
    struct RowInterpretation: Equatable, Sendable {
        var isData: Bool
        var isUndefined: Bool
        var dataShape: DataShapeOverride?
        /// A shaped row's directive (array, alignment, string).
        var shapeDirective: DataDirective?
        /// An undefined row's raw `.byte` directive, annotated "undefined".
        var undefinedDirective: DataDirective?
    }

    static func interpretation(
        of instruction: InstructionRow,
        snapshot: WorkspaceSnapshot,
        slot: ImageSlot,
        encoding: StringDisplayEncoding = .default,
        readBytes: ((_ virtualAddress: UInt64, _ count: Int) -> Data?)? = nil
    ) -> RowInterpretation {
        let address = instruction.address
        let shape = snapshot.dataShape(at: address, in: slot)
        let shapeDirective = shape.map { shape -> DataDirective in
            let (mnemonic, operands) = WorkspaceSnapshot.dataDirective(
                forShape: shape, at: address, encoding: encoding,
                readBytes: readBytes ?? snapshot.hexByteReader(in: slot)
            )
            return DataDirective(mnemonic: mnemonic, operands: operands)
        }
        // An undefined row renders the raw bytes as a `.byte` directive annotated
        // "undefined", distinct from a data word. Computed from the row's own bytes
        // (the bytes are unchanged; only the interpretation is suppressed).
        let undefined = snapshot.isUndefined(at: address, in: slot)
        let undefinedDirective: DataDirective? = undefined ? {
            let (mnemonic, operands) = WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes)
            return DataDirective(mnemonic: mnemonic, operands: operands + "  ; undefined")
        }() : nil
        return RowInterpretation(isData: snapshot.isData(at: address, in: slot), isUndefined: undefined,
                                 dataShape: shape, shapeDirective: shapeDirective, undefinedDirective: undefinedDirective)
    }

    // MARK: - Helpers

    /// The override-resolved comment for an instruction, mirroring the rule the
    /// existing view used: a data-marked row suppresses the decoder comment (which
    /// described the now-hidden code interpretation) and shows only a user override.
    static func resolvedComment(snapshot: WorkspaceSnapshot, instruction: InstructionRow, slot: ImageSlot? = nil) -> String? {
        let s = slot ?? snapshot.primarySlot
        // A data OR undefined row suppresses the decoder comment (which described the
        // now-hidden code interpretation) and shows only a user override.
        if snapshot.isData(at: instruction.address, in: s) || snapshot.isUndefined(at: instruction.address, in: s) {
            return snapshot.displayComment(at: instruction.address, in: s, default: nil)
        }
        return snapshot.displayComment(at: instruction.address, in: s, default: instruction.comment)
    }

    /// The segment-qualified section display name, e.g. "__TEXT,__text". The model's
    /// `SectionSummary.name` may already be either bare ("__text") or qualified; this
    /// returns it verbatim (the loader supplies the canonical string).
    static func sectionDisplayName(_ section: SectionSummary) -> String {
        section.name
    }

    /// Maps each labellable address to its display name: function starts (named via the
    /// user override or the function's parsed name) and symbol-named addresses. The
    /// user override always wins. Function entries take precedence over a bare symbol
    /// at the same address.
    static func labelNameLookup(snapshot: WorkspaceSnapshot, slot: ImageSlot? = nil) -> [UInt64: String] {
        try! labelNameLookup(snapshot: snapshot, slot: slot, checkCancellation: {})
    }

    private static func labelNameLookup(
        snapshot: WorkspaceSnapshot, slot: ImageSlot?, checkCancellation: () throws -> Void
    ) throws -> [UInt64: String] {
        let s = slot ?? snapshot.primarySlot
        let analysis = snapshot.analysis(in: s)
        var names: [UInt64: String] = [:]

        // Symbol-named addresses first (lower precedence).
        for (index, symbol) in (analysis?.symbols ?? []).enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            guard let address = symbol.address, !symbol.name.isEmpty else { continue }
            names[address] = snapshot.displayName(at: address, in: s, default: symbol.name)
        }

        // Function starts override (higher precedence) and also cover unnamed functions.
        var functionStarts: Set<UInt64> = []
        for (index, function) in (analysis?.functions ?? []).enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            functionStarts.insert(function.startAddress)
            names[function.startAddress] = snapshot.displayName(
                at: function.startAddress, in: s,
                default: function.name
            )
        }

        // User local labels (Function ▸ Set Local Label…) become label rows too.
        try checkCancellation()
        snapshot.mergeLocalLabels(into: &names, functionStarts: functionStarts, in: s)

        return names
    }
}
