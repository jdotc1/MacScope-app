import Foundation

/// Renders the current analysis to plain text for "Export Listing" / "Export
/// Pseudocode" — a common reverse-engineering workflow (dump the disassembly or the
/// recovered pseudocode to a `.txt`/`.asm` file). This service is intentionally *pure*: every
/// method returns a `String` and performs no file I/O, so it is fully unit-testable
/// and the thin write-to-disk layer lives at the call site (an `NSSavePanel` in the
/// app shell).
///
/// The rendering reuses the same building blocks the GUI already draws with — the
/// pure `DisassemblyListingBuilder` (section-header / label / prefix-comment rows +
/// the per-address resolved instruction the view shows) and `PseudocodePrinter`'s
/// `PseudocodeDocument` — so an exported file matches the on-screen listing/pseudocode
/// exactly (applied overrides, custom names, comments, data directives, operand
/// formats, and all).
struct DocumentExportService {
    #if DEBUG
    var pseudocodeCapture: PseudocodePrinter.RenderCapture? = nil
    #endif
    init() {}

    // MARK: - Listing

    /// Column layout for the plain-text listing. The address column is the canonical
    /// 18-character `0x…` form (`UInt64.hexAddress`); the bytes / mnemonic columns are
    /// padded to a fixed width so the operands and comments line up in a monospace
    /// viewer. Values are generous so the common short instruction is untruncated, and
    /// nothing is ever *cut* — an over-long field simply pushes the next column right
    /// (lossless, never lossy).
    private enum Column {
        static let bytes = 24
        static let mnemonic = 10
    }

    /// Renders the whole disassembly LISTING to plain text: section-header rows, label
    /// rows at function starts / named addresses, own-line (prefix) comment rows, and
    /// the instruction rows themselves (address / bytes / mnemonic / operands / inline
    /// comment), honoring every applied override exactly as the on-screen listing does
    /// (custom names, comments, mark-as-data directives, operand formats).
    ///
    /// The row interleaving and the per-address resolved instruction come straight from
    /// `DisassemblyListingBuilder.buildResolved`, so the export can never drift from the
    /// GUI's row shape.
    func renderListing(snapshot: WorkspaceSnapshot) -> String {
        renderListing(snapshot: snapshot, in: snapshot.primarySlot)
    }

    /// Focused-image export uses the same slot-qualified inputs as the visible listing.
    func renderListing(snapshot: WorkspaceSnapshot, in slot: ImageSlot) -> String {
        let (rows, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snapshot, slot: slot)
        var lines: [String] = []
        lines.reserveCapacity(rows.count)
        for row in rows {
            switch row {
            case let .sectionHeader(header):
                lines.append(renderSectionHeader(header))
            case let .label(label):
                lines.append(renderLabel(label))
            case let .prefixComment(comment):
                lines.append(contentsOf: renderPrefixComment(comment))
            case let .instruction(instruction):
                lines.append(renderInstruction(resolved[instruction.address] ?? fallbackResolved(instruction)))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A section/segment group header line, e.g.
    /// `; ============ __TEXT,__text (0x0000000100000f00) ============`.
    private func renderSectionHeader(_ header: SectionHeaderRow) -> String {
        let bar = String(repeating: "=", count: 12)
        return "; \(bar) \(header.name) (\(header.address.hexAddress)) \(bar)"
    }

    /// A standalone label row at a function start / named address, e.g. `_main:`.
    private func renderLabel(_ label: LabelRow) -> String {
        "\(label.name):"
    }

    /// An own-line comment rendered above the instruction it annotates. The comment may
    /// contain newlines (the model promotes multi-line notes to prefix rows); each
    /// physical line is emitted as its own `;`-prefixed comment line so the output stays
    /// a valid assembler comment block.
    private func renderPrefixComment(_ comment: PrefixCommentRow) -> [String] {
        comment.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "; \($0)" }
    }

    /// One instruction row: `address  bytes  mnemonic operands  ; comment`. Mirrors the
    /// view's resolution exactly — a data-marked row renders as an assembler data
    /// directive (`.long`/`.byte`) instead of the decoded instruction, and a decoded row
    /// applies the user's operand format. The trailing inline comment is appended only
    /// when one is present.
    private func renderInstruction(_ resolved: DisassemblyListingBuilder.ResolvedInstruction) -> String {
        let row = resolved.row
        let displayed: (mnemonic: String, operands: String)
        if resolved.isData || resolved.isUndefined {
            let directive = resolved.isUndefined
                ? resolved.undefinedDirective : resolved.shapeDirective
            if let directive {
                displayed = (directive.mnemonic, directive.operands)
            } else {
                displayed = WorkspaceSnapshot.dataDirective(forBytes: row.bytes)
            }
        } else if let format = resolved.operandFormat {
            displayed = (row.mnemonic, OperandFormat.apply(to: row.operands, format: format))
        } else {
            displayed = (row.mnemonic, row.operands)
        }

        var line = row.address.hexAddress
        line += "  " + pad(row.bytes, to: Column.bytes)
        line += "  " + pad(displayed.mnemonic, to: Column.mnemonic)
        if !displayed.operands.isEmpty {
            line += " " + displayed.operands
        }
        if let comment = resolved.inlineComment, !comment.isEmpty {
            // Trim the field run to a single space before the comment marker so the
            // column padding never leaves a ragged gap before `;`.
            line = trimTrailingSpaces(line) + "  ; " + comment
        } else {
            // No operands/comment after a column: drop the trailing padding so the row
            // ends cleanly rather than with a run of spaces.
            line = trimTrailingSpaces(line)
        }
        return line
    }

    /// A resolved view for an instruction that the builder's map did not cover (it
    /// should always cover an instruction row, but this keeps the render total without a
    /// force-unwrap): the decoder's own comment, no overrides applied.
    private func fallbackResolved(_ row: InstructionRow) -> DisassemblyListingBuilder.ResolvedInstruction {
        DisassemblyListingBuilder.ResolvedInstruction(
            row: row,
            inlineComment: row.comment,
            tag: nil,
            colorTag: nil,
            isData: false,
            operandFormat: nil
        )
    }

    // MARK: - Pseudocode

    /// Renders the pseudocode for ONE function (the function enclosing `selectedAddress`,
    /// or the first discovered function when `selectedAddress` is nil) to plain text,
    /// reusing the exact `PseudocodePrinter` call the GUI's pseudocode pane makes — so
    /// the exported text matches the on-screen pseudocode including applied name and
    /// signature overrides, resolved jump tables, and Objective-C selectors.
    ///
    /// Returns an empty string when the snapshot has no functions to decompile.
    func renderPseudocode(snapshot: WorkspaceSnapshot, selectedAddress: UInt64?) -> String {
        renderPseudocode(
            snapshot: snapshot,
            selectedAddress: selectedAddress,
            in: snapshot.primarySlot
        )
    }

    /// Explicit-image variant used by focused GUI export. Every image-local printer input is
    /// captured by the same slot-owned aggregate as the interactive pseudocode pane. The
    /// aggregate intentionally has an instruction fallback for the pane, so export separately
    /// preserves its existing empty-string contract when this image has no discovered function.
    func renderPseudocode(
        snapshot: WorkspaceSnapshot,
        selectedAddress: UInt64?,
        in slot: ImageSlot
    ) -> String {
        let input = snapshot.pseudocodeRenderInput(
            selectedAddress: selectedAddress,
            in: slot
        )
        guard input.startAddress != nil else { return "" }
        return pseudocodeText(for: input)
    }

    /// Renders the pseudocode for EVERY discovered function (the whole-binary scope) to
    /// plain text, in ascending start-address order, separated by a blank line. Each
    /// function is printed with the same override-aware printer call as the single
    /// function path. Returns an empty string when there are no functions.
    func renderAllPseudocode(snapshot: WorkspaceSnapshot) -> String {
        renderAllPseudocode(snapshot: snapshot, in: snapshot.primarySlot)
    }

    /// Explicit-image whole-function export. Functions are read only from `slot`, while the
    /// workspace-global type catalog continues to arrive through `PseudocodeRenderInput`.
    func renderAllPseudocode(snapshot: WorkspaceSnapshot, in slot: ImageSlot) -> String {
        let functions = (snapshot.analysis(in: slot)?.functions ?? [])
            .sorted { $0.startAddress < $1.startAddress }
        guard !functions.isEmpty else { return "" }
        // One image-wide pass, shared by every block, adds the typed slot resolutions.
        _ = snapshot.imageWideIndirectCalls(in: slot, compute: true)
        var blocks: [String] = []
        blocks.reserveCapacity(functions.count)
        for function in functions {
            if let block = renderAllPseudocodeBlock(snapshot: snapshot,
                startAddress: function.startAddress, in: slot,
                options: DecompilerOptions(userDefaults: .standard)) {
                blocks.append(block)
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Same canonical per-function path for synchronous export and the captured async job.
    /// nil means selection mismatch; an empty String is still a block.
    func renderAllPseudocodeBlock(snapshot: WorkspaceSnapshot, startAddress: UInt64,
                                 in slot: ImageSlot, options: DecompilerOptions) -> String? {
        let input = snapshot.pseudocodeRenderInput(selectedAddress: startAddress, in: slot)
        guard input.startAddress == startAddress else { return nil }
        return pseudocodeText(for: input, options: options)
    }

    /// Renders every recovered Objective-C class to a class-dump header — the
    /// `@interface … @end` blocks `ObjectiveCHeaderRenderer` produces, in `__objc_classlist`
    /// order. Returns a short comment when the binary defines no Objective-C classes (so the
    /// exported file is never empty/confusing).
    func renderObjectiveCHeader(snapshot: WorkspaceSnapshot) -> String {
        renderObjectiveCHeader(snapshot: snapshot, in: snapshot.primarySlot)
    }

    func renderObjectiveCHeader(snapshot: WorkspaceSnapshot, in slot: ImageSlot) -> String {
        let classes = snapshot.analysis(in: slot)?.objcClasses ?? []
        let categories = snapshot.analysis(in: slot)?.objcCategories ?? []
        guard !classes.isEmpty || !categories.isEmpty else {
            return "// No Objective-C classes were recovered from this binary.\n"
        }
        return ObjectiveCHeaderRenderer.render(classes: classes, categories: categories)
    }

    /// Renders every recovered Swift nominal type to a source-like interface — the
    /// `struct`/`class`/`enum` blocks `SwiftInterfaceRenderer` produces, in `__swift5_types`
    /// order. Returns a short comment when the binary defines no Swift types (so the exported
    /// file is never empty/confusing).
    func renderSwiftInterface(snapshot: WorkspaceSnapshot) -> String {
        renderSwiftInterface(snapshot: snapshot, in: snapshot.primarySlot)
    }

    func renderSwiftInterface(snapshot: WorkspaceSnapshot, in slot: ImageSlot) -> String {
        let types = snapshot.analysis(in: slot)?.swiftTypes ?? []
        let conformances = snapshot.analysis(in: slot)?.swiftConformances ?? []
        guard !types.isEmpty || !conformances.isEmpty else {
            return "// No Swift types were recovered from this binary.\n"
        }
        return SwiftInterfaceRenderer.render(types: types, conformances: conformances)
    }

    /// Renders the workspace type catalog (`struct`/`union`/`enum`/`typedef`) back out as
    /// C type declarations — the symmetric inverse of `CTypeHeaderParser`'s import. The
    /// emitted text re-imports to the equivalent catalog (round-trip), so a user can export
    /// their authored types, edit them in an editor, and paste them back. Returns a banner
    /// with a "no types" note when the catalog is empty (never an empty/confusing file).
    func renderTypeCatalog(snapshot: WorkspaceSnapshot) -> String {
        CTypeHeaderRenderer.render(types: snapshot.typeDefinitions)
    }

    /// The shared single-function pseudocode render: the same `PseudocodePrinter.print`
    /// invocation the GUI pane uses, returning the document's joined text.
    func pseudocodeText(for input: PseudocodeRenderInput,
                                options: DecompilerOptions = DecompilerOptions(userDefaults: .standard)) -> String {
        var printer = PseudocodePrinter(options: options)
        #if DEBUG
        printer.renderCapture = pseudocodeCapture
        #endif
        let document = printer.print(
            functionName: input.functionName,
            startAddress: input.startAddress,
            jumpTables: input.jumpTables,
            objcSelectors: input.objcSelectors,
            constantStrings: input.constantStrings,
            nameOverrides: input.nameOverrides,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            directCallVoidResultTargets: input.directCallVoidResultTargets,
            machineCallUsage: input.machineCallUsage,
            machineUsageContext: input.machineUsageContext,
            ownDirectCallAddresses: input.ownDirectCallAddresses,
            knownTailCallTargets: input.knownTailCallTargets,
            registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides,
            resolvedIndirectCalls: input.resolvedIndirectCalls,
            slotCallContracts: input.slotCallContracts,
            callerReturnWidth: input.callerReturnWidth,
            callerReturnType: input.callerReturnType,
            types: input.types,
            instructions: input.instructions
        )
        return document.text
    }

    // MARK: - Formatting helpers

    /// Right-pads `value` with spaces to `width`. An over-width value is returned
    /// verbatim (never truncated) so no listing detail is ever lost — it simply pushes
    /// the following column right.
    private func pad(_ value: String, to width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    /// Drops trailing spaces so an inline comment attaches with a clean single gap
    /// rather than after a run of column padding.
    private func trimTrailingSpaces(_ value: String) -> String {
        var end = value.endIndex
        while end > value.startIndex {
            let previous = value.index(before: end)
            if value[previous] == " " { end = previous } else { break }
        }
        return String(value[value.startIndex..<end])
    }
}
