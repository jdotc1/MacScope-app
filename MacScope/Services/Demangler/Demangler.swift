import Foundation

/// Front door for symbol-name demangling. Dispatches a possibly-mangled symbol
/// to the appropriate clean-room demangler (Itanium C++ `_Z…` or Swift `$s…`)
/// and returns a human-readable form, or `nil` when the name is not mangled in
/// a form we cover. Callers fall back to the raw name on `nil`.
///
/// Correctness over coverage: each backend returns `nil` rather than emit a
/// guessed result, so this function never produces a misleading demangling.
enum Demangler {
    /// Returns a readable demangling of `symbol`, or `nil` if it is not a
    /// mangled name we recognise (the caller should then show the raw name).
    static func mangledToReadable(_ symbol: String) -> String? {
        let trimmed = symbol
        guard !trimmed.isEmpty else { return nil }

        // Swift stable manglings: `$s`, `$S`, and their Mach-O `_`-prefixed
        // forms.
        if trimmed.hasPrefix("$s") || trimmed.hasPrefix("$S")
            || trimmed.hasPrefix("_$s") || trimmed.hasPrefix("_$S") || trimmed.hasPrefix("_TtC") {
            return SwiftDemangler.demangle(trimmed)
        }

        // Itanium C++: `_Z…` (or the Mach-O double-underscore `__Z…`).
        if trimmed.hasPrefix("_Z") || trimmed.hasPrefix("__Z") {
            return ItaniumDemangler.demangle(trimmed)
        }

        return nil
    }

    /// Convenience for display paths: returns the demangled name when available,
    /// otherwise the original name unchanged. Pure and cheap to call lazily.
    static func displayName(for symbol: String) -> String {
        mangledToReadable(symbol) ?? symbol
    }
}
