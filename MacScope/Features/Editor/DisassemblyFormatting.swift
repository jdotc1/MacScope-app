import Foundation

/// The user-tunable display preferences that affect how a disassembly row is *rendered*
/// (as opposed to how it is decoded). These were previously write-only `@AppStorage`
/// keys set from Settings but never read back by the listing path; this type is the
/// pure bridge `(UserDefaults keys) -> formatting options -> rendered text` so toggling
/// a preference actually changes the output.
///
/// Pure value type with no SwiftUI/UserDefaults dependency baked in: it is constructed
/// from a `UserDefaults` (or directly, for tests) and consumed by
/// `DisassemblyRowFormatter`. Keeping the read pure makes the whole formatting path
/// table-testable — the same instruction renders differently per option, asserted on
/// the produced string.
struct DisassemblyDisplayOptions: Equatable {
    /// Render the hex address (and any hex byte run) in UPPERCASE, e.g. `0x00001000`
    /// -> `0X00001000`. The pre-existing `showAddressesInUppercase` Settings toggle.
    var uppercaseHex: Bool
    /// Show the raw instruction-byte column (`e0 03 01 aa`). When false the bytes
    /// column renders empty, a "hide instruction bytes" view option.
    var showInstructionBytes: Bool
    /// Show the leading address column. When false the address renders empty (a
    /// "hide addresses" listing option), useful for copy-pasting clean assembly.
    var showAddresses: Bool
    /// Number of spaces placed between an instruction's mnemonic and its operands when
    /// joining them into a single rendered line (the assembler-style "operand spacing").
    /// Clamped to a sane range when read so a hostile/garbage default can't blow up the
    /// rendered width.
    var operandSpacing: Int
    /// Tint rows whose bytes the user has patched so a patch is visible in the listing
    /// (not just carried as a model flag). The preference SEAM for patch presentation —
    /// a future Settings toggle / patch-color picker plugs into `Key.highlightPatchedBytes`
    /// without touching the render path. Defaults on.
    var highlightPatchedBytes: Bool
    /// WS-7: a per-render RUNTIME SLIDE added to every rendered address so the focused image's
    /// listing can be shown in the unified runtime address space. 0 = image VA (the default and the
    /// only value the golden/export paths ever use). Set by the interactive view from the focused
    /// image's layout slide when the runtime display mode is on. Not a persisted preference.
    var runtimeSlide: UInt64 = 0

    /// The shipped defaults — every toggle in its pre-feature behaviour (lowercase hex,
    /// bytes + addresses shown, a single space before operands, patched rows highlighted)
    /// so an un-configured app renders exactly as before.
    static let `default` = DisassemblyDisplayOptions(
        uppercaseHex: false,
        showInstructionBytes: true,
        showAddresses: true,
        operandSpacing: 1,
        highlightPatchedBytes: true
    )

    /// Operand spacing is clamped into this range so a corrupt/hostile UserDefaults
    /// value (e.g. a huge or negative integer) can never produce a pathological line.
    static let operandSpacingRange = 1...8

    // MARK: - UserDefaults keys

    /// The `UserDefaults`/`@AppStorage` keys these options read from. Kept in one place
    /// so the Settings UI and this reader can never drift apart on the string literal.
    enum Key {
        /// Pre-existing key, already surfaced in Settings as "Uppercase addresses".
        static let uppercaseHex = "showAddressesInUppercase"
        static let showInstructionBytes = "showInstructionBytes"
        static let showAddresses = "showAddresses"
        static let operandSpacing = "disassemblyOperandSpacing"
        /// Preference seam for patch presentation (future Settings toggle / color picker).
        static let highlightPatchedBytes = "highlightPatchedBytes"
    }

    /// Reads the options from a `UserDefaults`. Absent keys fall back to the shipped
    /// default (so a fresh install renders unchanged), and `operandSpacing` is clamped
    /// into `operandSpacingRange`. Pure aside from the defaults read — no side effects.
    ///
    /// `UserDefaults.object(forKey:)` is used for the booleans so an *absent* key keeps
    /// the (possibly non-false) default rather than silently reading `false`.
    init(userDefaults: UserDefaults) {
        let base = Self.default
        func bool(_ key: String, default fallback: Bool) -> Bool {
            userDefaults.object(forKey: key) == nil ? fallback : userDefaults.bool(forKey: key)
        }
        self.uppercaseHex = bool(Key.uppercaseHex, default: base.uppercaseHex)
        self.showInstructionBytes = bool(Key.showInstructionBytes, default: base.showInstructionBytes)
        self.showAddresses = bool(Key.showAddresses, default: base.showAddresses)
        self.highlightPatchedBytes = bool(Key.highlightPatchedBytes, default: base.highlightPatchedBytes)
        self.runtimeSlide = 0   // set per-render by the view, never from UserDefaults
        if userDefaults.object(forKey: Key.operandSpacing) == nil {
            self.operandSpacing = base.operandSpacing
        } else {
            let raw = userDefaults.integer(forKey: Key.operandSpacing)
            self.operandSpacing = Self.clampSpacing(raw)
        }
    }

    /// Direct memberwise init (for tests / programmatic construction). Clamps spacing so
    /// every constructed value already satisfies the invariant. `highlightPatchedBytes`
    /// defaults on so existing call sites are unaffected.
    init(uppercaseHex: Bool, showInstructionBytes: Bool, showAddresses: Bool, operandSpacing: Int,
         highlightPatchedBytes: Bool = true, runtimeSlide: UInt64 = 0) {
        self.uppercaseHex = uppercaseHex
        self.showInstructionBytes = showInstructionBytes
        self.showAddresses = showAddresses
        self.operandSpacing = Self.clampSpacing(operandSpacing)
        self.highlightPatchedBytes = highlightPatchedBytes
        self.runtimeSlide = runtimeSlide
    }

    private static func clampSpacing(_ value: Int) -> Int {
        min(operandSpacingRange.upperBound, max(operandSpacingRange.lowerBound, value))
    }
}

/// Applies `DisassemblyDisplayOptions` to one instruction's already-resolved fields,
/// producing the strings the view (or the text exporter) draws. Pure and view-free so
/// the whole preference-driven render path is unit-testable: feed an instruction +
/// options, assert on the produced columns / line.
///
/// This deliberately operates on the *display* shape only — case-folding hex, hiding a
/// column, joining mnemonic+operands with the configured spacing. It never re-decodes
/// or alters the instruction's meaning, so a wrong preference can never produce wrong
/// disassembly, only a differently-formatted view of the same instruction.
enum DisassemblyRowFormatter {

    /// The four rendered columns for a row, after display options are applied.
    struct RenderedColumns: Equatable {
        var address: String
        var bytes: String
        var mnemonic: String
        var operands: String
    }

    /// Renders the columns for an instruction. `mnemonic`/`operands` are passed in
    /// already-resolved (the caller has applied data-directive / operand-format
    /// resolution) so this layer only folds case + applies column visibility.
    static func columns(
        address: UInt64,
        bytes: String,
        mnemonic: String,
        operands: String,
        options: DisassemblyDisplayOptions
    ) -> RenderedColumns {
        RenderedColumns(
            address: options.showAddresses ? hex((address &+ options.runtimeSlide).hexAddress, options: options) : "",
            bytes: options.showInstructionBytes ? hex(bytes, options: options) : "",
            mnemonic: mnemonic,
            operands: operands
        )
    }

    /// Joins a mnemonic and operands into a single assembler line using the configured
    /// operand spacing, e.g. `mov` + `x0, x1` -> `mov    x0, x1`. An empty operand
    /// string yields just the (trimmed) mnemonic with no trailing spaces.
    static func joinedLine(mnemonic: String, operands: String, options: DisassemblyDisplayOptions) -> String {
        guard !operands.isEmpty else { return mnemonic }
        return mnemonic + String(repeating: " ", count: options.operandSpacing) + operands
    }

    /// Case-folds the hex portion of a string. Lowercase is the source-of-truth form
    /// (`hexAddress` and the decoder both emit lowercase), so uppercasing is a simple
    /// fold; the `0x` prefix's `x` is intentionally folded too (`0X…`), matching the
    /// uppercase convention so the whole token reads consistently.
    private static func hex(_ text: String, options: DisassemblyDisplayOptions) -> String {
        options.uppercaseHex ? text.uppercased() : text
    }
}
