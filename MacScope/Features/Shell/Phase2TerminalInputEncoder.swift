import Foundation
import GhosttyVt

/// Thin, fail-closed adapter around Ghostty's canonical key and paste encoders.
struct Phase2TerminalInputEncoder {
    struct Modes: Equatable, Sendable {
        var applicationCursorKeys = false
        var applicationKeypad = false
        var bracketedPaste = false

        static let normal = Modes()
    }

    struct Modifiers: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        static let shift = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    struct KeyEvent: Equatable, Sendable {
        let keyCode: UInt16
        let characters: String?
        let charactersIgnoringModifiers: String?
        let modifiers: Modifiers
    }

    func encode(_ input: KeyEvent, modes: Modes) -> [UInt8]? {
        encode(input) { encoder in
            var cursorMode = modes.applicationCursorKeys
            var keypadMode = modes.applicationKeypad
            ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION, &cursorMode)
            ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION, &keypadMode)
        }
    }

    func encode(_ input: KeyEvent, terminal: GhosttyTerminal) -> [UInt8]? {
        encode(input) { encoder in
            ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
            // Mirror the two DEC keyboard modes explicitly as well. This keeps the
            // C adapter correct across Ghostty builds where the bulk option copy may
            // omit a recently changed mode until the next terminal update.
            var cursorMode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(1, false), value: false)
            var keypadMode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(66, false), value: false)
            if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &cursorMode) == GHOSTTY_SUCCESS {
                ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION, &cursorMode.value)
            }
            if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &keypadMode) == GHOSTTY_SUCCESS {
                ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION, &keypadMode.value)
            }
        }
    }

    private func encode(
        _ input: KeyEvent,
        configure: (GhosttyKeyEncoder) -> Void
    ) -> [UInt8]? {
        guard !input.modifiers.contains(.command) else { return nil }
        let key: GhosttyKey
        if let mapped = Self.ghosttyKey(for: input.keyCode) {
            key = mapped
        } else if let mapped = Self.ghosttyKey(forBaseCharacters: input.charactersIgnoringModifiers) {
            key = mapped
        } else if input.characters?.isEmpty == false {
            key = GHOSTTY_KEY_UNIDENTIFIED
        } else {
            return nil
        }

        var encoder: GhosttyKeyEncoder?
        guard ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS,
              let encoder
        else { return nil }
        defer { ghostty_key_encoder_free(encoder) }

        var altEscPrefix = true
        var optionAsAlt = GHOSTTY_OPTION_AS_ALT_TRUE
        configure(encoder)
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX, &altEscPrefix)
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)

        var event: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS,
              let event
        else { return nil }
        defer { ghostty_key_event_free(event) }

        ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(event, key)
        ghostty_key_event_set_mods(event, Self.ghosttyModifiers(input.modifiers))
        if let scalar = (input.charactersIgnoringModifiers ?? input.characters)?.unicodeScalars.first {
            ghostty_key_event_set_unshifted_codepoint(event, scalar.value)
        }
        guard let text = input.characters ?? Self.keypadText(for: input.keyCode),
              !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value) })
        else { return Self.encode(encoder: encoder, event: event) }
        // Ghostty borrows this pointer, so encode while Swift's contiguous UTF-8
        // storage is guaranteed to remain alive.
        return text.withCString { pointer in
            ghostty_key_event_set_utf8(event, pointer, strlen(pointer))
            return Self.encode(encoder: encoder, event: event)
        }
    }

    func encodePaste(_ text: String, modes: Modes) -> [UInt8] {
        encodePaste(text, bracketed: modes.bracketedPaste)
    }

    func encodePaste(_ text: String, terminal: GhosttyTerminal) -> [UInt8] {
        var bracketedPaste = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2004, false), value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &bracketedPaste) == GHOSTTY_SUCCESS else {
            return []
        }
        return encodePaste(text, bracketed: bracketedPaste.value)
    }

    private func encodePaste(_ text: String, bracketed: Bool) -> [UInt8] {
        var input = Array(text.utf8)
        var required = 0
        let first = input.withUnsafeMutableBytes { inputBuffer in
            ghostty_paste_encode(
                inputBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                inputBuffer.count,
                bracketed,
                nil,
                0,
                &required
            )
        }
        guard first == GHOSTTY_OUT_OF_SPACE || (first == GHOSTTY_SUCCESS && required == 0) else { return [] }
        guard required > 0 else { return [] }
        var output = [CChar](repeating: 0, count: required)
        var written = required
        let result = input.withUnsafeMutableBytes { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                ghostty_paste_encode(
                    inputBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    inputBuffer.count,
                    bracketed,
                    outputBuffer.baseAddress,
                    outputBuffer.count,
                    &written
                )
            }
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return output.prefix(written).map(UInt8.init(bitPattern:))
    }

    private static func encode(encoder: GhosttyKeyEncoder, event: GhosttyKeyEvent) -> [UInt8]? {
        var required = 0
        let first = ghostty_key_encoder_encode(encoder, event, nil, 0, &required)
        guard first == GHOSTTY_OUT_OF_SPACE, required > 0 else { return nil }
        var output = [CChar](repeating: 0, count: required)
        var written = required
        let result = output.withUnsafeMutableBufferPointer { buffer in
            ghostty_key_encoder_encode(encoder, event, buffer.baseAddress, buffer.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return output.prefix(written).map(UInt8.init(bitPattern:))
    }

    private static func ghosttyModifiers(_ modifiers: Modifiers) -> GhosttyMods {
        var result: GhosttyMods = 0
        if modifiers.contains(.shift) { result |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if modifiers.contains(.control) { result |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if modifiers.contains(.option) { result |= GhosttyMods(GHOSTTY_MODS_ALT) }
        return result
    }

    private static func ghosttyKey(for keyCode: UInt16) -> GhosttyKey? {
        let keys: [UInt16: GhosttyKey] = [
            36: GHOSTTY_KEY_ENTER, 48: GHOSTTY_KEY_TAB, 51: GHOSTTY_KEY_BACKSPACE,
            53: GHOSTTY_KEY_ESCAPE, 65: GHOSTTY_KEY_NUMPAD_DECIMAL,
            67: GHOSTTY_KEY_NUMPAD_MULTIPLY, 69: GHOSTTY_KEY_NUMPAD_ADD,
            75: GHOSTTY_KEY_NUMPAD_DIVIDE, 76: GHOSTTY_KEY_NUMPAD_ENTER,
            78: GHOSTTY_KEY_NUMPAD_SUBTRACT, 81: GHOSTTY_KEY_NUMPAD_EQUAL,
            82: GHOSTTY_KEY_NUMPAD_0, 83: GHOSTTY_KEY_NUMPAD_1,
            84: GHOSTTY_KEY_NUMPAD_2, 85: GHOSTTY_KEY_NUMPAD_3,
            86: GHOSTTY_KEY_NUMPAD_4, 87: GHOSTTY_KEY_NUMPAD_5,
            88: GHOSTTY_KEY_NUMPAD_6, 89: GHOSTTY_KEY_NUMPAD_7,
            91: GHOSTTY_KEY_NUMPAD_8, 92: GHOSTTY_KEY_NUMPAD_9,
            96: GHOSTTY_KEY_F5, 97: GHOSTTY_KEY_F6, 98: GHOSTTY_KEY_F7,
            99: GHOSTTY_KEY_F3, 100: GHOSTTY_KEY_F8, 101: GHOSTTY_KEY_F9,
            103: GHOSTTY_KEY_F11, 109: GHOSTTY_KEY_F10, 111: GHOSTTY_KEY_F12,
            114: GHOSTTY_KEY_INSERT, 115: GHOSTTY_KEY_HOME, 116: GHOSTTY_KEY_PAGE_UP,
            117: GHOSTTY_KEY_DELETE, 118: GHOSTTY_KEY_F4, 119: GHOSTTY_KEY_END,
            120: GHOSTTY_KEY_F2, 121: GHOSTTY_KEY_PAGE_DOWN, 122: GHOSTTY_KEY_F1,
            123: GHOSTTY_KEY_ARROW_LEFT, 124: GHOSTTY_KEY_ARROW_RIGHT,
            125: GHOSTTY_KEY_ARROW_DOWN, 126: GHOSTTY_KEY_ARROW_UP,
        ]
        return keys[keyCode]
    }

    private static func ghosttyKey(forBaseCharacters characters: String?) -> GhosttyKey? {
        guard let scalar = characters?.lowercased().unicodeScalars.first,
              (97...122).contains(scalar.value)
        else { return nil }
        let alphabet: [GhosttyKey] = [
            GHOSTTY_KEY_A, GHOSTTY_KEY_B, GHOSTTY_KEY_C, GHOSTTY_KEY_D,
            GHOSTTY_KEY_E, GHOSTTY_KEY_F, GHOSTTY_KEY_G, GHOSTTY_KEY_H,
            GHOSTTY_KEY_I, GHOSTTY_KEY_J, GHOSTTY_KEY_K, GHOSTTY_KEY_L,
            GHOSTTY_KEY_M, GHOSTTY_KEY_N, GHOSTTY_KEY_O, GHOSTTY_KEY_P,
            GHOSTTY_KEY_Q, GHOSTTY_KEY_R, GHOSTTY_KEY_S, GHOSTTY_KEY_T,
            GHOSTTY_KEY_U, GHOSTTY_KEY_V, GHOSTTY_KEY_W, GHOSTTY_KEY_X,
            GHOSTTY_KEY_Y, GHOSTTY_KEY_Z,
        ]
        return alphabet[Int(scalar.value - 97)]
    }

    private static func keypadText(for keyCode: UInt16) -> String? {
        [65: ".", 67: "*", 69: "+", 75: "/", 78: "-", 81: "=", 82: "0",
         83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
         91: "8", 92: "9"][keyCode]
    }
}
