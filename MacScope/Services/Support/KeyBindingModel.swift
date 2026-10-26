import SwiftUI

/// A single keyboard chord: a printable key plus a set of modifier flags. This is the
/// clean-room, persistable analogue of SwiftUI's `KeyboardShortcut` — `KeyboardShortcut`
/// itself is neither `Codable` nor easily comparable for conflict detection, so the
/// keybinding editor models chords with this value type and only *converts* to a
/// `KeyboardShortcut` at the point of attaching it to a command.
///
/// `key` is the lowercased single-character key (e.g. `"o"`, `"["`) or one of a small set
/// of named special keys (arrows). Modifiers are stored as a stable, order-independent set
/// so two chords that differ only in modifier *ordering* compare equal — the property the
/// whole conflict-detection contract rests on.
struct KeyChord: Equatable, Hashable, Codable {
    /// The set of modifier flags that participate in a chord. A subset of
    /// `SwiftUI.EventModifiers`, modelled separately so the chord is `Codable` and so
    /// conflict comparison is a pure set equality independent of declaration order.
    enum Modifier: String, CaseIterable, Codable, Comparable {
        case command
        case shift
        case option
        case control

        static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            order(lhs) < order(rhs)
        }

        /// A stable display/sort order (Control, Option, Shift, Command — the macOS
        /// convention, left to right as they appear in a menu).
        private static func order(_ modifier: Modifier) -> Int {
            switch modifier {
            case .control: return 0
            case .option: return 1
            case .shift: return 2
            case .command: return 3
            }
        }

        var eventModifier: EventModifiers {
            switch self {
            case .command: return .command
            case .shift: return .shift
            case .option: return .option
            case .control: return .control
            }
        }

        /// The single-glyph macOS menu symbol (⌃⌥⇧⌘).
        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }
    }

    /// A named, non-printable key. Printable keys are carried in `key` directly; these
    /// cover the arrow keys used by the navigation commands.
    enum SpecialKey: String, CaseIterable, Codable {
        case upArrow
        case downArrow
        case leftArrow
        case rightArrow

        var keyEquivalent: KeyEquivalent {
            switch self {
            case .upArrow: return .upArrow
            case .downArrow: return .downArrow
            case .leftArrow: return .leftArrow
            case .rightArrow: return .rightArrow
            }
        }

        var symbol: String {
            switch self {
            case .upArrow: return "↑"
            case .downArrow: return "↓"
            case .leftArrow: return "←"
            case .rightArrow: return "→"
            }
        }
    }

    /// The printable key, lowercased, when `special == nil`. Exactly one of `key`/`special`
    /// is meaningful: a printable chord carries `key` (`special == nil`); a special-key
    /// chord carries `special` (and `key` is ignored for equality of the glyph but kept
    /// empty by convention).
    var key: String
    var special: SpecialKey?
    var modifiers: Set<Modifier>

    init(key: String, modifiers: Set<Modifier>) {
        let normalizedKey = key.lowercased()
        precondition(normalizedKey.count == 1, "Printable key chords require exactly one character")
        self.key = normalizedKey
        self.special = nil
        self.modifiers = modifiers
    }

    init(special: SpecialKey, modifiers: Set<Modifier>) {
        self.key = ""
        self.special = special
        self.modifiers = modifiers
    }

    /// Custom decoder so a chord deserialized from JSON (or hand-edited UserDefaults) obeys the
    /// same `key.lowercased()` invariant the memberwise inits enforce. Without this, an uppercase
    /// `key` survives decode and compares unequal to the same chord built in code — silently
    /// breaking conflict detection and Reset-All override removal. Encodable stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = (try container.decode(String.self, forKey: .key)).lowercased()
        let special = try container.decodeIfPresent(SpecialKey.self, forKey: .special)
        let modifiers = try container.decode(Set<Modifier>.self, forKey: .modifiers)
        guard (special == nil && key.count == 1) || (special != nil && key.isEmpty) else {
            throw DecodingError.dataCorruptedError(
                forKey: .key,
                in: container,
                debugDescription: "A printable chord requires exactly one character; a special chord requires an empty key"
            )
        }
        self.key = key
        self.special = special
        self.modifiers = modifiers
    }

    /// The SwiftUI `KeyboardShortcut` this chord maps to, for attaching to a command.
    var keyboardShortcut: KeyboardShortcut {
        let eventModifiers = modifiers.reduce(into: EventModifiers()) { $0.insert($1.eventModifier) }
        if let special {
            return KeyboardShortcut(special.keyEquivalent, modifiers: eventModifiers)
        }
        let equivalent = KeyEquivalent(Character(key))
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    /// The human-facing menu glyphs, e.g. `⇧⌘O` or `⌃⌘↓`. Modifiers are ordered with the
    /// macOS convention; the key glyph (uppercased printable, or the arrow symbol) trails.
    var displaySymbol: String {
        let mods = modifiers.sorted().map(\.symbol).joined()
        let keyGlyph = special?.symbol ?? key.uppercased()
        return mods + keyGlyph
    }
}

/// The set of app commands whose shortcuts the keybinding editor manages. Each case is a
/// stable identifier (its `rawValue` is the JSON persistence key) decoupled from the
/// `Notification.Name` the command actually posts — so renaming a notification never
/// silently drops a user's saved override.
///
/// This is intentionally a *curated* subset of the full command surface: the commands a
/// user is most likely to want to rebind, and the ones whose chords most often collide
/// (the family of Cmd-E / Cmd-Shift-E exports, the find/navigate cluster). Extending it is
/// additive — add a case + a default; the persistence and conflict machinery need no change.
enum BindableCommand: String, CaseIterable, Identifiable, Codable {
    case openBinary
    case openProject
    case save
    case saveAs
    case exportListing
    case exportPseudocode
    case goToAddress
    case find
    case findNext
    case findPrevious
    case navigateBack
    case navigateForward
    case toggleBreakpoint
    case openQuickly
    case addBookmark
    case toggleInspector
    case togglePanel

    var id: String { rawValue }

    /// The menu label shown in the editor table.
    var title: String {
        switch self {
        case .openBinary: return "Open Binary"
        case .openProject: return "Open Workspace"
        case .save: return "Save"
        case .saveAs: return "Save As"
        case .exportListing: return "Export Listing"
        case .exportPseudocode: return "Export Pseudocode"
        case .goToAddress: return "Go to Address"
        case .find: return "Find"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .navigateBack: return "Back"
        case .navigateForward: return "Forward"
        case .toggleBreakpoint: return "Toggle Breakpoint"
        case .openQuickly: return "Open Quickly"
        case .addBookmark: return "Add Bookmark"
        case .toggleInspector: return "Show/Hide Inspector"
        case .togglePanel: return "Show/Hide Panel"
        }
    }

    /// The shipped default chord. Existing commands retain their AppCommands chords;
    /// workspace layout commands use this same authority through the DS adapter.
    var defaultChord: KeyChord {
        switch self {
        case .openBinary: return KeyChord(key: "o", modifiers: [.command])
        // ⌃⌘O, not ⇧⌘O: ⇧⌘O is Open Quickly (Xcode convention), and two menu items sharing
        // one chord means only one of them ever fires.
        case .openProject: return KeyChord(key: "o", modifiers: [.command, .control])
        case .save: return KeyChord(key: "s", modifiers: [.command])
        case .saveAs: return KeyChord(key: "s", modifiers: [.command, .shift])
        case .exportListing: return KeyChord(key: "e", modifiers: [.command])
        case .exportPseudocode: return KeyChord(key: "e", modifiers: [.command, .shift, .option])
        case .goToAddress: return KeyChord(key: "l", modifiers: [.command])
        case .find: return KeyChord(key: "f", modifiers: [.command])
        case .findNext: return KeyChord(key: "g", modifiers: [.command])
        case .findPrevious: return KeyChord(key: "g", modifiers: [.command, .shift])
        case .navigateBack: return KeyChord(key: "[", modifiers: [.command])
        case .navigateForward: return KeyChord(key: "]", modifiers: [.command])
        case .toggleBreakpoint: return KeyChord(key: "b", modifiers: [.command, .control])
        case .openQuickly: return KeyChord(key: "o", modifiers: [.command, .shift])
        case .addBookmark: return KeyChord(key: "d", modifiers: [.command])
        case .toggleInspector: return KeyChord(key: "i", modifiers: [.option, .command])
        // Shift-Command-Y remains Navigation History. The panel command is reserved
        // until the workspace publishes a bottom-panel binding.
        case .togglePanel: return KeyChord(key: "y", modifiers: [.control, .command])
        }
    }
}

/// The editable, persistable map of command → chord, with conflict detection.
///
/// This is the model behind the keybinding editor. It starts from the shipped defaults,
/// applies any user override on top, detects when two commands share a chord, and
/// round-trips through JSON in `UserDefaults`. Pure value type with no SwiftUI/UserDefaults
/// dependency baked into the core logic so conflict detection + the round-trip are
/// table-testable.
struct KeyBindingSet: Equatable {
    /// The full resolved binding for every command (defaults with overrides applied).
    private(set) var bindings: [BindableCommand: KeyChord]

    /// The `UserDefaults`/persistence key holding the JSON override map.
    static let storageKey = "keyBindingOverrides"

    /// The default set: every command at its shipped chord.
    static var defaults: KeyBindingSet {
        var bindings: [BindableCommand: KeyChord] = [:]
        for command in BindableCommand.allCases {
            bindings[command] = command.defaultChord
        }
        return KeyBindingSet(bindings: bindings)
    }

    init(bindings: [BindableCommand: KeyChord]) {
        self.bindings = bindings
    }

    /// The chord currently bound to a command (resolved default+override), or the default
    /// if (defensively) absent.
    func chord(for command: BindableCommand) -> KeyChord {
        bindings[command] ?? command.defaultChord
    }

    /// Rebinds a command to a new chord. Returns the conflicting command, if any, that
    /// already holds this exact chord — the caller decides whether to reject or allow it;
    /// the rebind is applied regardless so the editor can surface "this now conflicts".
    @discardableResult
    mutating func setChord(_ chord: KeyChord, for command: BindableCommand) -> BindableCommand? {
        let existing = bindings.first { $0.key != command && $0.value == chord }?.key
        bindings[command] = chord
        return existing
    }

    /// Resets one command to its shipped default.
    mutating func resetToDefault(_ command: BindableCommand) {
        bindings[command] = command.defaultChord
    }

    /// Resets every command to its shipped default.
    mutating func resetAllToDefaults() {
        bindings = KeyBindingSet.defaults.bindings
    }

    /// All commands sharing a chord with another command — the conflict set. A chord used
    /// by exactly one command is never reported; only collisions are. Computed purely from
    /// `bindings`, so the editor can highlight every member of a colliding pair.
    var conflicts: Set<BindableCommand> {
        var byChord: [KeyChord: [BindableCommand]] = [:]
        for (command, chord) in bindings {
            byChord[chord, default: []].append(command)
        }
        var result: Set<BindableCommand> = []
        for (_, commands) in byChord where commands.count > 1 {
            result.formUnion(commands)
        }
        return result
    }

    /// Whether the whole set is conflict-free (no two commands share a chord).
    var hasConflict: Bool { !conflicts.isEmpty }

    // MARK: - Persistence (JSON override map in UserDefaults)

    /// Only the *overrides* (commands whose chord differs from the shipped default) are
    /// persisted, so a future change to a default is automatically inherited by anyone who
    /// never customized that command. Keyed by the command's stable `rawValue`.
    func overrideMap() -> [String: KeyChord] {
        var overrides: [String: KeyChord] = [:]
        for (command, chord) in bindings where chord != command.defaultChord {
            overrides[command.rawValue] = chord
        }
        return overrides
    }

    /// Encodes the override map to JSON `Data` for `UserDefaults`. Empty (all-default) sets
    /// encode to an empty object, which `load` reads back as the pure defaults.
    func encodedOverrides() -> Data? {
        try? JSONEncoder().encode(overrideMap())
    }

    /// Writes the override map into `UserDefaults` under `storageKey` (or removes the key
    /// when there are no overrides, so a reset-to-defaults leaves a clean domain).
    func persist(to defaults: UserDefaults) {
        let overrides = overrideMap()
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Loads from `UserDefaults`: starts from defaults and layers any persisted override on
    /// top. A missing key, malformed JSON, or an unknown command id all degrade gracefully
    /// to the defaults rather than throwing — a corrupt preference can never brick the app.
    static func load(from defaults: UserDefaults) -> KeyBindingSet {
        resolvingOverrides(defaults.data(forKey: storageKey))
    }

    /// Resolves the same persisted payload observed by SwiftUI command adapters. Keeping
    /// decoding here makes initial loading and live preference changes share one authority.
    static func resolvingOverrides(_ data: Data?) -> KeyBindingSet {
        var set = KeyBindingSet.defaults
        guard
            let data,
            let overrides = try? JSONDecoder().decode([String: KeyChord].self, from: data)
        else {
            return set
        }
        for (rawCommand, chord) in overrides {
            guard let command = BindableCommand(rawValue: rawCommand) else { continue }
            set.bindings[command] = chord
        }
        return set
    }
}
