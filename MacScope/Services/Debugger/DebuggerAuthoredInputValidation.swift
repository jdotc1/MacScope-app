import Foundation

/// Shared validation for user-authored values that cross the debugger command boundary.
///
/// Keep these predicates independent of a particular UI or transport so launch summaries,
/// authoring parsers, and adapters cannot drift onto different acceptance grammars.
enum DebuggerAuthoredInputValidation {
    /// Environment names use the portable ASCII identifier grammar accepted by the debugger
    /// transport: `[A-Za-z_][A-Za-z0-9_]*`.
    static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.utf8.first,
              isASCIIAlpha(first) || first == asciiUnderscore else {
            return false
        }

        return key.utf8.dropFirst().allSatisfy { byte in
            isASCIIAlpha(byte) || isASCIIDigit(byte) || byte == asciiUnderscore
        }
    }

    static func containsUnsupportedControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
        }
    }

    private static let asciiUnderscore: UInt8 = 0x5F

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }
}
