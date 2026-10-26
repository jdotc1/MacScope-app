import Foundation

/// The pure, UI-independent model behind in-pane hex editing.
///
/// The hex pane renders a bounded window of the selected slice's payload (`snapshot.hexBytes`).
/// Every offset→address decision goes through a table of VERIFIED `FileAddressMapping`s — the
/// same table used for patch overlay and selected-address navigation — so an edit can never be
/// displayed at one byte while being persisted at another address. A cell with no mapping (an
/// unmapped header byte, zero-fill, raw padding) or with disagreeing aliases has NO address and
/// stays read-only; the legacy `address = first instruction address + offset` convention is gone
/// because it silently targeted the wrong virtual address for any window that doesn't start at
/// the first instruction (a real binary's header-first window).
///
/// It is deliberately a value type with no SwiftUI/AppKit dependency: the AppKit `NSTextView`
/// bridge (and the unit tests) drive it the same way. Pixels are not tested here — *this* layer
/// is, because the editable hex pane is a thin AppKit shell over exactly these decisions.
struct HexEditModel: Equatable {
    /// The bytes shown in the hex window (`snapshot.hexBytes`), already overlaid with any
    /// applied patches by the caller when it wants the displayed value to reflect edits.
    let bytes: [UInt8]

    /// The verified file-offset → virtual-address mappings for the image whose payload this
    /// window shows. Empty means no cell can be edited (read-only window).
    let mappings: [FileAddressMapping]

    /// The payload file offset of `bytes[0]`. The window is a prefix of the payload today, so
    /// this is 0 everywhere; it exists so a future scrolled window keeps the same math.
    let windowFileOffset: UInt64

    /// True when at least one cell in the window resolves to a unique verified address.
    /// Precomputed so `isReadOnly` (queried per render) is O(1).
    private let hasMappedCell: Bool

    /// True when nothing in this window can be edited: no bytes, or no cell with a unique
    /// verified virtual address (unmapped windows and ambiguous-alias windows are read-only).
    var isReadOnly: Bool { bytes.isEmpty || !hasMappedCell }

    /// The number of byte cells (editable or not) in the window.
    var byteCount: Int { bytes.count }

    init(bytes: [UInt8], mappings: [FileAddressMapping], windowFileOffset: UInt64 = 0) {
        self.bytes = bytes
        self.mappings = mappings
        self.windowFileOffset = windowFileOffset
        self.hasMappedCell = Self.windowHasMappedCell(
            byteCount: bytes.count, mappings: mappings, windowFileOffset: windowFileOffset
        )
    }

    init(bytes: Data, mappings: [FileAddressMapping], windowFileOffset: UInt64 = 0) {
        self.init(bytes: [UInt8](bytes), mappings: mappings, windowFileOffset: windowFileOffset)
    }

    /// Anchored-window convenience: a window whose byte 0 is KNOWN to sit at `baseAddress`
    /// (hand-built fixtures and previews — never a real binary's header-first window). It
    /// synthesizes the single linear mapping that convention implies, clamped so the virtual
    /// range cannot overflow, and routes through exactly the same mapping machinery.
    init(bytes: Data, baseAddress: UInt64?) {
        self.init(bytes: [UInt8](bytes), baseAddress: baseAddress)
    }

    init(bytes: [UInt8], baseAddress: UInt64?) {
        guard let baseAddress, !bytes.isEmpty else {
            self.init(bytes: bytes, mappings: [])
            return
        }
        let addressSpan = baseAddress == 0 ? UInt64(bytes.count) : (UInt64.max - baseAddress) + 1
        let size = min(UInt64(bytes.count), addressSpan)
        self.init(
            bytes: bytes,
            mappings: [FileAddressMapping(fileOffset: 0, size: size, virtualAddress: baseAddress)]
        )
    }

    private static func windowHasMappedCell(
        byteCount: Int,
        mappings: [FileAddressMapping],
        windowFileOffset: UInt64
    ) -> Bool {
        guard byteCount > 0, !mappings.isEmpty else { return false }
        for offset in 0..<byteCount {
            let fileOffset = windowFileOffset &+ UInt64(offset)
            if FileAddressMapping.resolvedVirtualAddress(forFileOffset: fileOffset, in: mappings) != nil {
                return true
            }
        }
        return false
    }

    /// The unique verified virtual address of the byte at window `offset`, or nil when the
    /// offset is outside the window, the byte is unmapped, or its aliases disagree.
    func address(forOffset offset: Int) -> UInt64? {
        guard offset >= 0, offset < bytes.count else { return nil }
        let fileOffset = windowFileOffset &+ UInt64(offset)
        return FileAddressMapping.resolvedVirtualAddress(forFileOffset: fileOffset, in: mappings)
    }

    /// The window offset displaying `address`, or nil when the address is not uniquely backed
    /// by a byte in this window (unmapped, ambiguous alias, or outside the window). Uses the
    /// alias-safe reverse resolution, so a file byte aliased to multiple addresses never
    /// claims a cell.
    func offset(forAddress address: UInt64) -> Int? {
        guard let fileOffset = FileAddressMapping.resolvedFileOffset(forVirtualAddress: address, in: mappings),
              fileOffset >= windowFileOffset else { return nil }
        let delta = fileOffset - windowFileOffset
        guard delta < UInt64(bytes.count) else { return nil }
        return Int(delta)
    }

    /// The current byte value at `offset`, or nil when out of range.
    func byte(atOffset offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    // MARK: - Editing

    /// The outcome of attempting to commit a typed byte at an offset.
    enum EditResult: Equatable {
        /// A valid byte edit. `address` is the verified virtual address to patch; `byte` is
        /// the new value. The caller applies this through `WorkspaceStore.setPatch`
        /// (single-byte `BytePatch`). When `byte` already equals the original, the caller may
        /// still apply it — the store prunes a no-op patch.
        case patch(address: UInt64, byte: UInt8)
        /// The window is read-only (no document / no mapped cells) — nothing was changed.
        case readOnly
        /// The offset is outside the editable window.
        case outOfRange
        /// The input was not a valid 2-digit byte (rejected; nothing changed).
        case invalidInput
        /// The cell is inside the window but has no unique verified address (unmapped header
        /// byte, zero-fill, raw padding, or an ambiguous alias) — it cannot be patched honestly.
        case unmapped
    }

    /// Validates a full two-character hex string (e.g. "4f") and resolves it to a patch at the
    /// byte's verified virtual address. Whitespace is trimmed; case-insensitive. Anything that
    /// is not exactly two hex digits is rejected (`.invalidInput`) so a fat-fingered keystroke
    /// can never write a garbage patch. Does NOT mutate any store — it returns the decision;
    /// the bridge/caller performs the (undoable) write so this stays a pure function.
    func resolveEdit(offset: Int, hexByte input: String) -> EditResult {
        guard !isReadOnly else { return .readOnly }
        guard offset >= 0, offset < bytes.count else { return .outOfRange }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 2, let value = UInt8(trimmed, radix: 16) else { return .invalidInput }
        guard let address = address(forOffset: offset) else { return .unmapped }
        return .patch(address: address, byte: value)
    }

    /// Composes a new byte from a single typed hex nibble over the existing byte at `offset`,
    /// in `position` (`.high` = first/left nibble, `.low` = second/right nibble). This is the
    /// per-keystroke entry path: typing one digit replaces one nibble of the byte under the
    /// caret, the classic hex-editor interaction. Returns `.invalidInput` for a non-hex digit.
    func resolveNibbleEdit(offset: Int, nibble input: Character, position: NibblePosition) -> EditResult {
        guard !isReadOnly else { return .readOnly }
        guard let original = byte(atOffset: offset) else { return .outOfRange }
        guard let nibbleValue = input.hexDigitValue, nibbleValue >= 0, nibbleValue < 16 else {
            return .invalidInput
        }
        guard let address = address(forOffset: offset) else { return .unmapped }
        let nibble = UInt8(nibbleValue)
        let composed: UInt8
        switch position {
        case .high:
            composed = (nibble << 4) | (original & 0x0f)
        case .low:
            composed = (original & 0xf0) | nibble
        }
        return .patch(address: address, byte: composed)
    }

    /// Which nibble of a byte a single typed digit replaces.
    enum NibblePosition: Equatable {
        case high
        case low
    }

    // MARK: - Caret navigation

    /// Clamps an offset into the valid `[0, byteCount)` range, or nil for an empty window.
    func clamped(_ offset: Int) -> Int? {
        guard byteCount > 0 else { return nil }
        return min(max(offset, 0), byteCount - 1)
    }

    /// The offset one cell in `direction` from `offset`, clamped to the window so the caret
    /// never runs off the ends. `bytesPerRow` drives vertical motion. Returns the same offset
    /// when motion is blocked at an edge (e.g. up on the first row), matching native caret feel.
    func offset(movingFrom offset: Int, _ direction: CaretDirection, bytesPerRow: Int) -> Int? {
        guard let current = clamped(offset) else { return nil }
        let perRow = max(1, bytesPerRow)
        switch direction {
        case .left:
            return clamped(current - 1)
        case .right:
            return clamped(current + 1)
        case .up:
            let candidate = current - perRow
            return candidate >= 0 ? candidate : current
        case .down:
            let candidate = current + perRow
            return candidate < byteCount ? candidate : current
        }
    }

    /// Arrow-key caret directions.
    enum CaretDirection: Equatable {
        case left
        case right
        case up
        case down
    }

    // MARK: - Accessibility

    /// A VoiceOver label for the byte cell at `offset`: its virtual address and current value.
    /// Unmapped / read-only / out-of-range cells degrade to a descriptive string rather than
    /// crashing (an unmapped cell simply has no address to speak).
    func accessibilityLabel(forOffset offset: Int) -> String {
        guard let value = byte(atOffset: offset) else { return "No byte" }
        let valueText = String(format: "0x%02X", value)
        if let address = address(forOffset: offset) {
            return "Byte at 0x" + String(address, radix: 16) + ", value " + valueText
        }
        return "Byte, value " + valueText
    }
}
