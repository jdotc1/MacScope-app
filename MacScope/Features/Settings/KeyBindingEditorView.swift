import SwiftUI
import LumenUI

/// The keyboard-shortcut editor: a table of every `BindableCommand` with its current chord,
/// inline conflict highlighting (any two commands sharing a chord are flagged red), and
/// per-row / global reset-to-defaults. Edits persist immediately to `UserDefaults` as a
/// JSON override map; the running command menu picks them up on the next `body` evaluation.
///
/// A chord is captured by a small key-recorder: focus the field, press a key with modifiers,
/// and the chord is rebound. The recorder is a thin `NSViewRepresentable` so it can read raw
/// modifier flags + the pressed key, which SwiftUI's high-level focus APIs don't expose.
struct KeyBindingEditorView: View {
    @State private var bindings = KeyBindingSet.load(from: .standard)
    @State private var recording: BindableCommand?

    @State private var selection: BindableCommand.ID?

    /// U8-5e: the commands as a Lumen table (command, shortcut, reset) with "Restore Defaults" in
    /// its footer; about 50 rows scroll inside a fixed-height card in the Keys & Display pane. The
    /// card's 320 pt holds header, rows and footer; the rows area flexes to what's left (#406 RED:
    /// a 320 pt rows minimum pushed the footer out of the card).
    var body: some View {
        LumenFormSection("Keyboard Shortcuts") {
            if bindings.hasConflict {
                Label("Two or more commands share a shortcut.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.lumen(.statusDanger))
            }
            LumenTable(
                BindableCommand.allCases,
                selection: $selection,
                footer: LumenTableFooter(trailing: (title: "Restore Defaults", action: {
                    bindings.resetAllToDefaults()
                    bindings.persist(to: .standard)
                })),
                columns: [
                    // Every shared column has a minimum (Lumen 0.42: without one it collapses).
                    .text("Command") { $0.title }.minWidth(140),
                    LumenTableColumn("Shortcut", width: 170, alignment: .trailing) { command in shortcutCell(for: command) },
                    LumenTableColumn("", width: 28, alignment: .center) { command in resetButton(for: command) },
                ]
            )
            .frame(height: AppSettingsChrome.keyBindingTableHeight)
            .accessibilityIdentifier("settings.keyBindings.table")
        }
    }

    @ViewBuilder
    private func shortcutCell(for command: BindableCommand) -> some View {
        let chord = bindings.chord(for: command)
        let isConflicting = bindings.conflicts.contains(command)
        if recording == command {
            HStack(spacing: Lumen.Space.s3) {
                KeyChordRecorder(onChord: { newChord in
                    bindings.setChord(newChord, for: command)
                    bindings.persist(to: .standard)
                    recording = nil
                }, onCancel: { recording = nil })
                .frame(width: AppSettingsChrome.keyChordRecorderWidth, height: AppSettingsChrome.keyChordRecorderHeight)
                Button("Cancel") { recording = nil }
                    .controlSize(.small)
            }
        } else {
            Button {
                recording = command
            } label: {
                Text(chord.displaySymbol)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isConflicting ? Color.lumen(.statusDanger) : Color.primary)
                    .frame(minWidth: AppSettingsChrome.keyShortcutMinWidth)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(isConflicting ? "This shortcut conflicts with another command." : "Click to record a new shortcut.")
            .accessibilityLabel("\(command.title) shortcut \(chord.displaySymbol)")
        }
    }

    /// L4 (Lumen Tier 2e): the revert arrow shows only on a changed binding.
    @ViewBuilder
    private func resetButton(for command: BindableCommand) -> some View {
        if bindings.chord(for: command) != command.defaultChord {
            Button {
                bindings.resetToDefault(command)
                bindings.persist(to: .standard)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset \(command.title) to its default shortcut.")
            .accessibilityLabel("Reset \(command.title) shortcut")
        }
    }
}

/// A focus-grabbing recorder that captures the next key-with-modifiers chord. Reports a
/// `KeyChord` only with Command, Control or Option, preserving ordinary text entry.
/// Escape, Tab, the Cancel button, or moving focus ends recording without a binding.
struct KeyChordRecorder: NSViewRepresentable {
    let onChord: (KeyChord) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onChord = onChord
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.onChord = onChord
        nsView.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: RecorderNSView, coordinator: ()) {
        nsView.stopRecording()
    }

    final class RecorderNSView: NSView {
        var onChord: ((KeyChord) -> Void)?
        var onCancel: (() -> Void)?
        private var eventMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopRecording()
            guard let window else { return }
            window.makeFirstResponder(self)
            // Local monitors run before menu key-equivalent dispatch. Own only this
            // recorder's key window while it is first responder; never intercept another
            // window or retain a monitor after representable teardown.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window === window, window.firstResponder === self else { return event }
                self.keyDown(with: event)
                return nil
            }
        }

        func stopRecording() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }

        override func resignFirstResponder() -> Bool {
            stopRecording()
            onCancel?()
            return super.resignFirstResponder()
        }

        override func draw(_ dirtyRect: NSRect) {
            // The theme's accent tint (not the system accent) for the active-recording background.
            Lumen.nsColor(.accentSubtle).setFill()
            dirtyRect.fill()
            let text = "Press keys…" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2),
                      withAttributes: attrs)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 || event.keyCode == 48 {
                stopRecording()
                onCancel?()
                return
            }
            let modifiers = Self.chordModifiers(from: event.modifierFlags)
            guard modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
            else { return }
            if let special = Self.specialKey(for: event.keyCode) {
                stopRecording()
                onChord?(KeyChord(special: special, modifiers: modifiers))
                return
            }
            guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
                  let first = characters.first, !first.isWhitespace,
                  first.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
            stopRecording()
            onChord?(KeyChord(key: String(first), modifiers: modifiers))
        }

        private static func chordModifiers(from flags: NSEvent.ModifierFlags) -> Set<KeyChord.Modifier> {
            var modifiers: Set<KeyChord.Modifier> = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            return modifiers
        }

        private static func specialKey(for keyCode: UInt16) -> KeyChord.SpecialKey? {
            switch keyCode {
            case 126: return .upArrow
            case 125: return .downArrow
            case 123: return .leftArrow
            case 124: return .rightArrow
            default: return nil
            }
        }
    }
}
