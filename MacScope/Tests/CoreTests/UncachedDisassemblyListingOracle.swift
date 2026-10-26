import Foundation
@testable import MacScope

// Frozen baseline algorithm from 4ede10bf8a3d647fa07ad28b519439eb46a91e6a.
// Independent test oracle, never compiled into the application.
enum UncachedDisassemblyListingOracle {

    /// The resolved data the view needs for one instruction row, computed once here so
    /// the per-row closure work in the View shrinks to a lookup. The fields mirror the
    /// arguments `DisassemblyListingRow` (the SwiftUI view) already takes.
    typealias ResolvedInstruction = DisassemblyListingBuilder.ResolvedInstruction

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
        let s = slot ?? snapshot.primarySlot
        let analysis = snapshot.analysis(in: s)
        let instructions = (analysis?.instructions ?? []).sorted { $0.address < $1.address }
        guard !instructions.isEmpty else { return [] }

        // Section boundaries, sorted by address; each fires once, at the first
        // instruction whose address is >= the section start (so a header lands even if
        // no instruction sits exactly on the boundary).
        let sortedSections = (analysis?.sections ?? []).sorted { $0.address < $1.address }
        var nextSectionIndex = 0

        // Function starts and named (symbol-named) addresses → label rows.
        let functionStarts = Set((analysis?.functions ?? []).map(\.startAddress))
        let labelNames = labelNameLookup(snapshot: snapshot, slot: s)

        var rows: [ListingRow] = []
        rows.reserveCapacity(instructions.count + sortedSections.count + functionStarts.count)

        for instruction in instructions {
            let address = instruction.address

            // (a) Section/segment group headers at each boundary the row crosses.
            while nextSectionIndex < sortedSections.count,
                  sortedSections[nextSectionIndex].address <= address {
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
        let s = slot ?? snapshot.primarySlot
        let rows = build(snapshot: snapshot, slot: s)
        let pcRowAddress = liveProgramCounterRowAddress(
            snapshot: snapshot,
            programCounter: liveProgramCounter,
            slot: s
        )
        // One byte reader for the whole pass — shaped string directives read their
        // literal text from the loaded bytes through it.
        let reader = snapshot.hexByteReader(in: s)
        // Direct branch/call targets render by name (`bl _printf`) rather than raw hex.
        let symbolizer = BranchTargetSymbolizer(namesByAddress: snapshot.branchTargetNames(in: s))
        let patchOverlay = try? BytePatchOverlay(patches: snapshot.patches(in: s))
        var resolved: [UInt64: ResolvedInstruction] = [:]
        for row in rows {
            guard let instruction = row.instruction else { continue }
            let address = instruction.address
            let comment = resolvedComment(snapshot: snapshot, instruction: instruction, slot: s)
            let inline: String?
            if let comment, ListingCommentPlacement.derivedDefault(forComment: comment) == .inline {
                inline = comment
            } else {
                inline = nil
            }
            let shape = snapshot.dataShape(at: address, in: s)
            let shapeDirective = shape.map { shape -> DataDirective in
                let (mnemonic, operands) = WorkspaceSnapshot.dataDirective(
                    forShape: shape, at: address, encoding: stringEncoding, readBytes: reader
                )
                return DataDirective(mnemonic: mnemonic, operands: operands)
            }
            // An undefined row renders the raw bytes as a `.byte` directive annotated
            // "undefined", distinct from a data word. Computed from the row's own bytes
            // (the bytes are unchanged; only the interpretation is suppressed).
            let undefined = snapshot.isUndefined(at: address, in: s)
            let undefinedDirective: DataDirective? = undefined ? {
                let (mnemonic, operands) = WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes)
                return DataDirective(mnemonic: mnemonic, operands: operands + "  ; undefined")
            }() : nil
            resolved[address] = ResolvedInstruction(
                row: symbolizer.symbolized(instruction, callsOnly: false),
                inlineComment: inline,
                tag: snapshot.tag(at: address, in: s),
                colorTag: snapshot.colorTag(at: address, in: s),
                isData: snapshot.isData(at: address, in: s),
                isUndefined: undefined,
                undefinedDirective: undefinedDirective,
                isPatched: patchOverlay.map {
                    !$0.edits.isEmpty && $0.intersects(
                        address: address,
                        count: BytePatch.parse(hex: instruction.bytes)?.bytes.count ?? 0
                    )
                } ?? false,
                dataShape: shape,
                shapeDirective: shapeDirective,
                operandFormat: snapshot.operandFormat(at: address, in: s),
                isLiveProgramCounter: pcRowAddress == address
            )
        }
        return (rows, resolved)
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
        let s = slot ?? snapshot.primarySlot
        let analysis = snapshot.analysis(in: s)
        var names: [UInt64: String] = [:]

        // Symbol-named addresses first (lower precedence).
        for symbol in (analysis?.symbols ?? []) {
            guard let address = symbol.address, !symbol.name.isEmpty else { continue }
            names[address] = snapshot.displayName(at: address, in: s, default: symbol.name)
        }

        // Function starts override (higher precedence) and also cover unnamed functions.
        for function in (analysis?.functions ?? []) {
            names[function.startAddress] = snapshot.displayName(
                at: function.startAddress, in: s,
                default: function.name
            )
        }
        snapshot.mergeLocalLabels(
            into: &names,
            functionStarts: Set((analysis?.functions ?? []).map(\.startAddress)),
            in: s
        )

        return names
    }
}
