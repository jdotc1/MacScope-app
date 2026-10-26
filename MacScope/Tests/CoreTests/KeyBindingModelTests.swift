import XCTest
import SwiftUI
@testable import MacScope

/// Tier 3 — the keybinding editor model. Asserts the two contracts the editor rests on:
/// (1) conflict detection flags exactly the commands that share a chord, and (2) the
/// override map round-trips through UserDefaults JSON. Plus reset-to-defaults and the
/// chord-equality property (modifier ordering is irrelevant) the conflict logic depends on.
final class KeyBindingModelTests: XCTestCase {

    @MainActor
    func testRecorderRejectsTextAndCapturesOccupiedCommandChord() throws {
        let recorder = KeyChordRecorder.RecorderNSView()
        var captured: KeyChord?
        recorder.onChord = { captured = $0 }
        for flags: NSEvent.ModifierFlags in [[], .shift] {
            recorder.keyDown(with: try recorderEvent("f", keyCode: 3, modifiers: flags))
            XCTAssertNil(captured)
        }
        recorder.keyDown(with: try recorderEvent("e", keyCode: 14, modifiers: .command))
        XCTAssertEqual(captured, KeyChord(key: "e", modifiers: [.command]))
    }

    @MainActor
    func testRecorderEscapeAndTabCancelWithoutRebinding() throws {
        for keyCode: UInt16 in [53, 48] {
            let recorder = KeyChordRecorder.RecorderNSView()
            var cancelled = false
            var captured: KeyChord?
            recorder.onCancel = { cancelled = true }
            recorder.onChord = { captured = $0 }
            recorder.keyDown(with: try recorderEvent("", keyCode: keyCode, modifiers: []))
            XCTAssertTrue(cancelled)
            XCTAssertNil(captured)
        }
    }

    @MainActor
    private func recorderEvent(_ characters: String, keyCode: UInt16,
                               modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
    }

    private func defaults() -> UserDefaults {
        let suite = "KeyBindingModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Chord equality (the property conflict detection relies on)

    func testChordEqualityIgnoresModifierOrdering() {
        let a = KeyChord(key: "o", modifiers: [.command, .shift])
        let b = KeyChord(key: "O", modifiers: [.shift, .command]) // different case + order
        XCTAssertEqual(a, b, "Chords must compare equal regardless of modifier order or key case.")
    }

    func testDecodedUppercaseKeyNormalizesToLowercase() throws {
        // Regression: the synthesized decoder stored `key` verbatim, so an uppercase key from JSON
        // (or hand-edited UserDefaults) compared unequal to the same chord built in code — silently
        // breaking conflict detection + Reset-All override removal. init(from:) now lowercases.
        let decoded = try JSONDecoder().decode(KeyChord.self, from: Data(#"{"key":"O","modifiers":["command"]}"#.utf8))
        XCTAssertEqual(decoded.key, "o")
        XCTAssertEqual(decoded, KeyChord(key: "o", modifiers: [.command]))
        let roundTripped = try JSONDecoder().decode(KeyChord.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTripped, decoded, "encode→decode must preserve the normalized chord")
    }

    func testChordsDifferWhenModifiersDiffer() {
        XCTAssertNotEqual(
            KeyChord(key: "g", modifiers: [.command]),
            KeyChord(key: "g", modifiers: [.command, .shift])
        )
    }

    func testSpecialKeyChordDistinctFromPrintable() {
        XCTAssertNotEqual(
            KeyChord(special: .downArrow, modifiers: [.command]),
            KeyChord(key: "j", modifiers: [.command])
        )
    }

    // MARK: - Defaults

    func testDefaultsCoverEveryCommand() {
        let set = KeyBindingSet.defaults
        for command in BindableCommand.allCases {
            XCTAssertEqual(set.chord(for: command), command.defaultChord, "\(command) default mismatch")
        }
    }

    func testShippedDefaultsAreConflictFreeWithinTheEditableSet() {
        // The curated editable set must ship with no internal collisions: two menu items on one
        // chord means only one of them can ever fire.
        let conflicts = KeyBindingSet.defaults.conflicts
        XCTAssertEqual(conflicts, [],
                       "Unexpected default shortcut collision: \(conflicts.map(\.title))")
    }

    func testWorkspaceLayoutDefaultsPreserveExistingReservedChords() {
        let set = KeyBindingSet.defaults
        XCTAssertEqual(set.chord(for: .toggleInspector), KeyChord(key: "i", modifiers: [.option, .command]))
        XCTAssertEqual(set.chord(for: .togglePanel), KeyChord(key: "y", modifiers: [.control, .command]))
        XCTAssertEqual(set.chord(for: .openQuickly), KeyChord(key: "o", modifiers: [.shift, .command]))
        // Open Workspace and Open Quickly must not share a chord: the File menu item wins and
        // Open Quickly becomes unreachable from the keyboard.
        XCTAssertEqual(set.chord(for: .openProject), KeyChord(key: "o", modifiers: [.control, .command]))
        XCTAssertNotEqual(set.chord(for: .openProject), set.chord(for: .openQuickly))

        let reserved = [KeyChord(key: "y", modifiers: [.shift, .command])]
            + (1...4).map { KeyChord(key: String($0), modifiers: [.command]) }
        for command in [BindableCommand.toggleInspector, .togglePanel] {
            XCTAssertFalse(reserved.contains(set.chord(for: command)), "Layout default shadows an existing fixed command")
        }
    }

    func testWorkspaceLayoutRebindingPersistsAndConvertsResolvedShortcuts() throws {
        let d = defaults()
        var set = KeyBindingSet.defaults
        let inspector = KeyChord(special: .rightArrow, modifiers: [.option, .control, .command])
        let panel = KeyChord(key: "j", modifiers: [.shift, .option, .command])
        XCTAssertNil(set.setChord(inspector, for: .toggleInspector))
        XCTAssertNil(set.setChord(panel, for: .togglePanel))
        set.persist(to: d)

        let loaded = KeyBindingSet.load(from: d)
        XCTAssertEqual(loaded, set)
        XCTAssertEqual(KeyBindingSet.resolvingOverrides(d.data(forKey: KeyBindingSet.storageKey)), loaded)
        let shortcuts = DSWorkspaceViewShortcuts(bindings: loaded)
        let inspectorShortcut = try XCTUnwrap(shortcuts.inspector)
        XCTAssertEqual(inspectorShortcut.key, .rightArrow)
        XCTAssertEqual(inspectorShortcut.modifiers, [.option, .control, .command])
        let panelShortcut = try XCTUnwrap(shortcuts.panel)
        XCTAssertEqual(panelShortcut.key, KeyEquivalent("j"))
        XCTAssertEqual(panelShortcut.modifiers, [.shift, .option, .command])
    }

    func testWorkspaceLayoutResetPersistsSingleAndAllDefaults() {
        let d = defaults()
        var set = KeyBindingSet.defaults
        set.setChord(KeyChord(key: "j", modifiers: [.control, .command]), for: .toggleInspector)
        set.setChord(KeyChord(key: "j", modifiers: [.option, .command]), for: .togglePanel)
        set.persist(to: d)
        set.resetToDefault(.toggleInspector)
        set.persist(to: d)
        let partiallyReset = KeyBindingSet.load(from: d)
        XCTAssertEqual(partiallyReset.chord(for: .toggleInspector), BindableCommand.toggleInspector.defaultChord)
        XCTAssertEqual(partiallyReset.chord(for: .togglePanel), set.chord(for: .togglePanel))
        XCTAssertEqual(Set(partiallyReset.overrideMap().keys), [BindableCommand.togglePanel.rawValue])

        set.resetAllToDefaults()
        set.persist(to: d)
        XCTAssertNil(d.data(forKey: KeyBindingSet.storageKey))
        XCTAssertEqual(KeyBindingSet.resolvingOverrides(d.data(forKey: KeyBindingSet.storageKey)), .defaults)
    }

    func testWorkspaceShortcutConversionUsesDefaultsForMissingResolvedEntries() throws {
        // KeyBindingSet has no unbound state: a missing entry deliberately inherits its
        // shipped default, including in the command adapter.
        let shortcuts = DSWorkspaceViewShortcuts(bindings: KeyBindingSet(bindings: [:]))
        let inspector = try XCTUnwrap(shortcuts.inspector)
        XCTAssertEqual(inspector.key, KeyEquivalent("i"))
        XCTAssertEqual(inspector.modifiers, [.option, .command])
        let panel = try XCTUnwrap(shortcuts.panel)
        XCTAssertEqual(panel.key, KeyEquivalent("y"))
        XCTAssertEqual(panel.modifiers, [.control, .command])
        XCTAssertEqual(KeyBindingSet.resolvingOverrides(nil), .defaults)
        XCTAssertEqual(KeyBindingSet.resolvingOverrides(Data("invalid".utf8)), .defaults)
    }

    // MARK: - Conflict detection

    func testRebindingOntoAnotherCommandReportsAndFlagsBoth() {
        var set = KeyBindingSet.defaults
        // Rebind Find (Cmd-F) onto Save's chord (Cmd-S).
        let saveChord = KeyChord(key: "s", modifiers: [.command])
        let conflicting = set.setChord(saveChord, for: .find)
        XCTAssertEqual(conflicting, .save, "setChord must report the command already holding the chord.")
        // Both members of the colliding pair are flagged.
        XCTAssertTrue(set.conflicts.isSuperset(of: [.find, .save]))
        XCTAssertTrue(set.hasConflict)
    }

    func testResolvingAConflictClearsTheFlag() {
        var set = KeyBindingSet.defaults
        set.setChord(KeyChord(key: "s", modifiers: [.command]), for: .find) // collide with Save
        XCTAssertTrue(set.conflicts.contains(.find))
        // Move Find to a free chord.
        set.setChord(KeyChord(key: "j", modifiers: [.command, .control, .option]), for: .find)
        XCTAssertFalse(set.conflicts.contains(.find))
        XCTAssertFalse(set.conflicts.contains(.save))
    }

    func testUniqueChordIsNeverReportedAsConflict() {
        var set = KeyBindingSet.defaults
        set.setChord(KeyChord(key: "k", modifiers: [.command, .control]), for: .find)
        XCTAssertFalse(set.conflicts.contains(.find))
    }

    // MARK: - Reset

    func testResetToDefaultRestoresOneCommand() {
        var set = KeyBindingSet.defaults
        set.setChord(KeyChord(key: "z", modifiers: [.command]), for: .save)
        XCTAssertNotEqual(set.chord(for: .save), BindableCommand.save.defaultChord)
        set.resetToDefault(.save)
        XCTAssertEqual(set.chord(for: .save), BindableCommand.save.defaultChord)
    }

    func testResetAllRestoresEverything() {
        var set = KeyBindingSet.defaults
        set.setChord(KeyChord(key: "z", modifiers: [.command]), for: .save)
        set.setChord(KeyChord(key: "y", modifiers: [.command]), for: .find)
        set.resetAllToDefaults()
        XCTAssertEqual(set, KeyBindingSet.defaults)
        XCTAssertTrue(set.overrideMap().isEmpty)
    }

    // MARK: - Persistence round-trip

    func testOverrideMapOnlyContainsChangedCommands() {
        var set = KeyBindingSet.defaults
        set.setChord(KeyChord(key: "n", modifiers: [.command, .control]), for: .find)
        let overrides = set.overrideMap()
        XCTAssertEqual(Array(overrides.keys), [BindableCommand.find.rawValue],
                       "Only the changed command is persisted; defaults are inherited.")
    }

    func testPersistAndLoadRoundTrip() {
        let d = defaults()
        var set = KeyBindingSet.defaults
        let newFind = KeyChord(key: "n", modifiers: [.command, .control])
        let newBack = KeyChord(special: .leftArrow, modifiers: [.command, .option])
        set.setChord(newFind, for: .find)
        set.setChord(newBack, for: .navigateBack)
        set.persist(to: d)

        let loaded = KeyBindingSet.load(from: d)
        XCTAssertEqual(loaded.chord(for: .find), newFind)
        XCTAssertEqual(loaded.chord(for: .navigateBack), newBack)
        // Untouched commands keep their defaults.
        XCTAssertEqual(loaded.chord(for: .save), BindableCommand.save.defaultChord)
        XCTAssertEqual(loaded, set)
    }

    func testLoadFromEmptyDefaultsYieldsShippedDefaults() {
        XCTAssertEqual(KeyBindingSet.load(from: defaults()), KeyBindingSet.defaults)
    }

    func testPersistEmptyOverridesClearsTheStoredKey() {
        let d = defaults()
        var set = KeyBindingSet.defaults
        set.setChord(KeyChord(key: "n", modifiers: [.command]), for: .find)
        set.persist(to: d)
        XCTAssertNotNil(d.data(forKey: KeyBindingSet.storageKey))
        // Resetting back to defaults and persisting must remove the key, not store "{}".
        set.resetAllToDefaults()
        set.persist(to: d)
        XCTAssertNil(d.data(forKey: KeyBindingSet.storageKey))
        XCTAssertEqual(KeyBindingSet.load(from: d), KeyBindingSet.defaults)
    }

    func testCorruptStoredDataDegradesToDefaults() {
        let d = defaults()
        d.set(Data("not json".utf8), forKey: KeyBindingSet.storageKey)
        XCTAssertEqual(KeyBindingSet.load(from: d), KeyBindingSet.defaults)
    }

    func testMultiCharacterPersistedKeyDegradesToDefaultsBeforeSwiftUIConversion() {
        let d = defaults()
        d.set(Data(#"{"find":{"key":"ss","modifiers":["command"]}}"#.utf8), forKey: KeyBindingSet.storageKey)

        let loaded = KeyBindingSet.load(from: d)
        XCTAssertEqual(loaded, KeyBindingSet.defaults)
        guard loaded == KeyBindingSet.defaults else { return }

        XCTAssertNoThrow(loaded.chord(for: .find).keyboardShortcut)
    }

    func testEmptyPersistedPrintableKeyDegradesToDefaults() {
        let d = defaults()
        d.set(Data(#"{"find":{"key":"","modifiers":["command"]}}"#.utf8), forKey: KeyBindingSet.storageKey)

        XCTAssertEqual(KeyBindingSet.load(from: d), KeyBindingSet.defaults)
    }

    func testPersistedChordWithPrintableAndSpecialKeyDegradesToDefaults() {
        let d = defaults()
        d.set(Data(#"{"find":{"key":"s","special":"upArrow","modifiers":["command"]}}"#.utf8), forKey: KeyBindingSet.storageKey)

        XCTAssertEqual(KeyBindingSet.load(from: d), KeyBindingSet.defaults)
    }

    func testDecomposedGraphemePersistedKeyBuildsKeyboardShortcut() {
        let d = defaults()
        let decomposedKey = "e\u{301}"
        XCTAssertEqual(decomposedKey.unicodeScalars.count, 2)
        XCTAssertEqual(decomposedKey.utf8.count, 3)
        XCTAssertEqual(decomposedKey.count, 1)
        d.set(
            Data(#"{"find":{"key":"\#(decomposedKey)","modifiers":["control"]}}"#.utf8),
            forKey: KeyBindingSet.storageKey
        )

        let loaded = KeyBindingSet.load(from: d)
        XCTAssertEqual(loaded.chord(for: .find).key, decomposedKey)
        XCTAssertNoThrow(loaded.chord(for: .find).keyboardShortcut)
    }

    func testUnknownCommandIdInStorageIsIgnored() {
        let d = defaults()
        // A stored override for a command id that no longer exists must be skipped, not crash.
        let payload = ["someRemovedCommand": KeyChord(key: "x", modifiers: [.command])]
        d.set(try! JSONEncoder().encode(payload), forKey: KeyBindingSet.storageKey)
        XCTAssertEqual(KeyBindingSet.load(from: d), KeyBindingSet.defaults)
    }

    // MARK: - Display symbol (used by the editor table)

    func testDisplaySymbolOrdersModifiersAndShowsKey() {
        XCTAssertEqual(KeyChord(key: "o", modifiers: [.command, .shift]).displaySymbol, "⇧⌘O")
        XCTAssertEqual(KeyChord(key: "e", modifiers: [.command, .shift, .option]).displaySymbol, "⌥⇧⌘E")
        XCTAssertEqual(KeyChord(special: .downArrow, modifiers: [.command, .control]).displaySymbol, "⌃⌘↓")
    }
}
