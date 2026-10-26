import Foundation

/// HOP-5c: derives the anonymous-argument list of a format-string call from its constant format.
///
/// The parser is deliberately conservative: anything it does not fully understand (positional
/// `%n$` arguments, an unknown conversion, a truncated directive, an unterminated `os_log`
/// annotation, a conversion the flavor does not accept) makes the whole parse fail, and the
/// caller then binds only the declared fixed arguments. It never guesses an argument.
///
/// Types are the C types the callee's `va_arg` reads after default argument promotion
/// (`%hhd` reads an `int`, `%f` reads a `double`). On Apple arm64 every anonymous argument of
/// these types occupies one 8-byte stack slot (`long double` is binary64 on Darwin), which is
/// what `FormatStringParser.stackSlotSize` records for the call-frame binder.
public enum FormatStringParser {
    public enum Flavor: String, Sendable, Hashable, CaseIterable {
        /// `printf` family: C conversions only.
        case printf
        /// `NSString`/`CFString` (`NSLog`, `CFStringCreateWithFormat`): adds `%@`, `%C`, `%S`,
        /// and the legacy `%D`/`%U`/`%O`.
        case foundation
        /// `os_log`: Foundation conversions plus `{public}`/`{private}`/... annotations.
        case osLog

        /// Maps a `format` attribute archetype (as clang prints it) to the flavor this parser
        /// understands. `scanf`, `strftime`, `strfmon` and unknown kinds return nil: their
        /// arguments are not the printf-style value list.
        public init?(attributeKind: String) {
            switch attributeKind {
            case "printf", "__printf__", "freebsd_kprintf": self = .printf
            case "NSString", "__NSString__", "CFString", "__CFString__": self = .foundation
            case "os_log", "__os_log__", "os_trace": self = .osLog
            default: return nil
            }
        }
    }

    /// One argument consumed by the format, in consumption order.
    public struct Argument: Sendable, Hashable {
        /// The promoted C type the callee reads (`int`, `unsigned long`, `double`, `const char *`, `id`).
        public let type: String
        /// The directive that consumes it (`%*d` produces a `width` argument then the value).
        public let directive: String
        public let role: Role

        public enum Role: String, Sendable, Hashable {
            case value
            case fieldWidth
            case precision
        }

        public var isFloatingPoint: Bool { type == "double" }
        /// Bytes the callee reads from the slot (the slot itself is always 8 bytes on Apple arm64).
        public var readByteWidth: Int {
            switch type {
            case "int", "unsigned int", "wint_t", "unichar": 4
            default: 8
            }
        }
    }

    /// Darwin arm64: each anonymous argument occupies an 8-byte-aligned 8-byte stack slot.
    public static let stackSlotSize = 8

    /// Hard bound on recovered arguments; formats beyond it are not recovered (fixed args only).
    public static let maximumArguments = 64

    /// Returns the consumed arguments in order, or nil when the format is malformed or uses
    /// anything outside the supported subset.
    public static func arguments(of format: String, flavor: Flavor) -> [Argument]? {
        let scalars = Array(format.unicodeScalars)
        var arguments: [Argument] = []
        var index = 0

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            let position = index + offset
            return position < scalars.count ? scalars[position] : nil
        }

        while index < scalars.count {
            guard scalars[index] == "%" else {
                index += 1
                continue
            }
            let directiveStart = index
            index += 1
            guard let first = peek() else { return nil }
            if first == "%" {
                index += 1
                continue
            }

            // os_log privacy/format annotations: `%{public}s`, `%{private, mask.hash}@`, ...
            if flavor == .osLog {
                while peek() == "{" {
                    guard let close = scalars[index...].firstIndex(of: "}") else { return nil }
                    let body = String(String.UnicodeScalarView(scalars[(index + 1)..<close]))
                    guard !body.contains("%"), !body.contains("{") else { return nil }
                    index = close + 1
                }
            }

            // Flags.
            while let scalar = peek(), "-+ #0'".unicodeScalars.contains(scalar) {
                index += 1
            }

            var pending: [Argument] = []
            // Field width: digits or `*`. A digit run followed by `$` is a positional
            // argument, which this subset rejects.
            if peek() == "*" {
                index += 1
                if let scalar = peek(), isDigit(scalar) { return nil }  // `%*1$d`
                pending.append(Argument(type: "int", directive: "", role: .fieldWidth))
            } else {
                while let scalar = peek(), isDigit(scalar) { index += 1 }
                if peek() == "$" { return nil }
            }

            // Precision: `.`, `.digits`, or `.*`.
            if peek() == "." {
                index += 1
                if peek() == "*" {
                    index += 1
                    if let scalar = peek(), isDigit(scalar) { return nil }
                    pending.append(Argument(type: "int", directive: "", role: .precision))
                } else {
                    while let scalar = peek(), isDigit(scalar) { index += 1 }
                }
            }

            // Length modifier.
            var length = ""
            while let scalar = peek(), "hlLqjzt".unicodeScalars.contains(scalar) {
                length.unicodeScalars.append(scalar)
                index += 1
            }
            guard ["", "hh", "h", "l", "ll", "L", "q", "j", "z", "t"].contains(length) else {
                return nil
            }

            guard let conversion = peek() else { return nil }
            index += 1
            guard let type = valueType(conversion: conversion, length: length, flavor: flavor) else {
                return nil
            }
            let directive = String(String.UnicodeScalarView(scalars[directiveStart..<index]))
            for argument in pending {
                arguments.append(Argument(type: argument.type, directive: directive, role: argument.role))
            }
            arguments.append(Argument(type: type, directive: directive, role: .value))
            guard arguments.count <= maximumArguments else { return nil }
        }
        return arguments
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    /// The promoted type a conversion reads, or nil for an unsupported or invalid combination.
    private static func valueType(
        conversion: Unicode.Scalar,
        length: String,
        flavor: Flavor
    ) -> String? {
        let foundation = flavor != .printf
        switch conversion {
        case "d", "i":
            switch length {
            case "", "hh", "h": return "int"
            case "l": return "long"
            case "ll", "q": return "long long"
            case "j": return "intmax_t"
            case "z": return "ssize_t"
            case "t": return "ptrdiff_t"
            default: return nil
            }
        case "u", "o", "x", "X":
            switch length {
            case "", "hh", "h": return "unsigned int"
            case "l": return "unsigned long"
            case "ll", "q": return "unsigned long long"
            case "j": return "uintmax_t"
            case "z": return "size_t"
            case "t": return "ptrdiff_t"
            default: return nil
            }
        case "D", "U", "O":
            // Legacy `long` conversions (printf(3) "deprecated"); no length modifier allowed.
            guard length.isEmpty else { return nil }
            return conversion == "D" ? "long" : "unsigned long"
        case "f", "F", "e", "E", "g", "G", "a", "A":
            // `long double` is binary64 on Darwin arm64: same slot and read as `double`.
            guard length.isEmpty || length == "l" || length == "L" else { return nil }
            return "double"
        case "c":
            switch length {
            case "": return "int"
            case "l": return "wint_t"
            default: return nil
            }
        case "s":
            switch length {
            case "": return "const char *"
            case "l": return "const wchar_t *"
            default: return nil
            }
        case "p":
            guard length.isEmpty else { return nil }
            return "void *"
        case "n":
            // Writes the count through a pointer; the argument is still one pointer slot.
            switch length {
            case "": return "int *"
            case "hh": return "signed char *"
            case "h": return "short *"
            case "l": return "long *"
            case "ll", "q": return "long long *"
            case "j": return "intmax_t *"
            case "z": return "ssize_t *"
            case "t": return "ptrdiff_t *"
            default: return nil
            }
        case "@":
            guard foundation, length.isEmpty else { return nil }
            return "id"
        case "C":
            guard foundation, length.isEmpty else { return nil }
            return "unichar"
        case "S":
            guard foundation, length.isEmpty else { return nil }
            return "const unichar *"
        default:
            return nil
        }
    }
}
