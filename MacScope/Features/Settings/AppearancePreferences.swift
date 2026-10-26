import SwiftUI
import LumenUI

/// The user's chosen app appearance. Exposed as a *preference* (default `.auto`,
/// which follows the system) rather than a force-set global — per the project
/// convention to never hard-code `.preferredColorScheme`. The root view reads
/// `colorScheme` and applies it; `.auto` maps to `nil` so the system setting
/// (incl. Auto/sundown) is honoured.
enum AppAppearancePreference: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    /// The `@AppStorage` key. A single source of truth so Settings and the root
    /// view can't drift on the literal.
    static let storageKey = "appAppearancePreference"

    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The SwiftUI color scheme to force, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Resolves the stored raw string into a case, defaulting to `.auto` for an
    /// absent or unrecognised value.
    static func resolve(_ raw: String) -> AppAppearancePreference {
        AppAppearancePreference(rawValue: raw) ?? .auto
    }
}

/// The CPU sub-mode display hint: whether the listing annotates each function (or section)
/// with the decoder's instruction-set mode (ARM64/A64 today; the seam for an ARM/Thumb hint
/// on a future 32-bit decoder). A pure display preference — it never changes how an
/// instruction is decoded, only whether the mode is surfaced to the reader. Off by default
/// so the listing is unchanged until the user opts in.
enum CPUSubModeDisplayPreference {
    static let storageKey = "showCPUSubModeHint"
    /// Off by default — no mode annotation until the user enables it.
    static let `default` = false

    static func read(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) == nil ? `default` : defaults.bool(forKey: storageKey)
    }
}

/// The listing/pseudocode font as Lumen's `LumenCodeFont` (U5f): one value stored as
/// `"<family>:<size>"` (`system` for the system monospaced font), shared with Lumen's code
/// components through `.lumenCodeFont`. Settings that predate it (`listingFontFamily` /
/// `listingFontSize`) migrate once on first read: System -> the system monospaced font, a named
/// family -> that face; the size clamps to 9...24 as before.
enum MacScopeCodeFont {
    static let storageKey = "macscope.codeFont"

    enum LegacyKey {
        static let family = "listingFontFamily"
        static let size = "listingFontSize"
    }

    /// The person's code font, migrating the legacy keys the first time.
    static func current(_ defaults: UserDefaults = .standard) -> LumenCodeFont {
        // Test-controlled view construction must not migrate app preferences.
        // Explicit isolated suites still exercise the real migration below.
        if defaults === UserDefaults.standard, MacIRConfiguration.installedTestBaseline != nil {
            return .standard
        }
        if let raw = defaults.string(forKey: storageKey), let font = LumenCodeFont(rawValue: raw) {
            return font
        }
        let migrated = legacyFont(defaults)
        if defaults.object(forKey: LegacyKey.family) != nil || defaults.object(forKey: LegacyKey.size) != nil {
            defaults.set(migrated.rawValue, forKey: storageKey)
        }
        return migrated
    }

    /// The legacy settings as a code font (the defaults when they were never set).
    static func legacyFont(_ defaults: UserDefaults) -> LumenCodeFont {
        let family = defaults.string(forKey: LegacyKey.family)
        let known: Set<String> = ["SF Mono", "Menlo", "Monaco", "Courier New"]
        let size = defaults.object(forKey: LegacyKey.size) == nil
            ? LumenCodeFont.standard.size
            : CGFloat(defaults.double(forKey: LegacyKey.size))
        return LumenCodeFont(family: family.flatMap { known.contains($0) ? $0 : nil }, size: size)
    }
}
