import SwiftUI

/// A serializable RGBA color used to *recolor* a color-tag slot away from its shipped
/// semantic default. Kept as plain `Double` components (0...1) so the palette round-trips
/// through JSON without depending on any platform color type; the conversion to a SwiftUI
/// `Color` happens only at the view boundary.
struct PaletteColor: Equatable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.opacity = Self.clamp(opacity)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

/// One entry in the color-tag palette: a slot (`ColorTag`), its (possibly renamed) display
/// name, and its (possibly recolored) color. The slot key never changes — it is what every
/// override persists against — so renaming/recoloring is purely cosmetic and never breaks
/// an existing per-address `colorTag` assignment.
struct ColorTagPaletteEntry: Equatable, Identifiable {
    let tag: ColorTag
    var name: String
    /// `nil` ⇒ use the shipped semantic color for this slot; a value ⇒ a user recolor.
    var colorOverride: PaletteColor?

    var id: String { tag.rawValue }

    /// The shipped default display name for the slot (`"Red"`, etc.).
    var defaultName: String { tag.displayName }
}

/// The editable, persistable palette of named color tags. The underlying `ColorTag` cases
/// stay fixed (they are the stable persistence keys for per-address tinting); this layer
/// gives each slot a user-facing *name* and an optional *color override* so the palette can
/// be managed (renamed/recolored) without touching the override seam. Persisted as JSON in
/// `UserDefaults`; only entries that differ from the shipped defaults are stored, so a
/// future change to a default name/color is inherited by anyone who never customized it.
struct ColorTagPalette: Equatable {
    private(set) var entries: [ColorTagPaletteEntry]

    static let storageKey = "colorTagPalette"

    /// The shipped palette: every slot at its default name and no color override.
    static var defaults: ColorTagPalette {
        ColorTagPalette(entries: ColorTag.allCases.map {
            ColorTagPaletteEntry(tag: $0, name: $0.displayName, colorOverride: nil)
        })
    }

    init(entries: [ColorTagPaletteEntry]) {
        self.entries = entries
    }

    func entry(for tag: ColorTag) -> ColorTagPaletteEntry {
        entries.first { $0.tag == tag }
            ?? ColorTagPaletteEntry(tag: tag, name: tag.displayName, colorOverride: nil)
    }

    /// Renames a slot. An empty/whitespace-only name falls back to the shipped default so a
    /// slot can never become unlabeled.
    mutating func rename(_ tag: ColorTag, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(tag) { $0.name = trimmed.isEmpty ? tag.displayName : trimmed }
    }

    /// Recolors a slot, or clears the override (`nil` ⇒ revert to the semantic color).
    mutating func recolor(_ tag: ColorTag, to color: PaletteColor?) {
        update(tag) { $0.colorOverride = color }
    }

    /// Resets one slot to its shipped name + semantic color.
    mutating func reset(_ tag: ColorTag) {
        update(tag) { $0.name = tag.displayName; $0.colorOverride = nil }
    }

    /// Resets the whole palette to the shipped defaults.
    mutating func resetAll() {
        entries = ColorTagPalette.defaults.entries
    }

    private mutating func update(_ tag: ColorTag, _ transform: (inout ColorTagPaletteEntry) -> Void) {
        if let index = entries.firstIndex(where: { $0.tag == tag }) {
            transform(&entries[index])
        } else {
            var entry = ColorTagPaletteEntry(tag: tag, name: tag.displayName, colorOverride: nil)
            transform(&entry)
            entries.append(entry)
        }
    }

    // MARK: - Persistence

    /// The persisted shape: a slot is recorded only when its name *or* color differs from
    /// the shipped default. Keyed by `ColorTag.rawValue`.
    struct StoredEntry: Codable, Equatable {
        var name: String?
        var color: PaletteColor?
    }

    func overrideMap() -> [String: StoredEntry] {
        var map: [String: StoredEntry] = [:]
        for entry in entries {
            let nameOverride = entry.name == entry.tag.displayName ? nil : entry.name
            if nameOverride != nil || entry.colorOverride != nil {
                map[entry.tag.rawValue] = StoredEntry(name: nameOverride, color: entry.colorOverride)
            }
        }
        return map
    }

    func persist(to defaults: UserDefaults) {
        let overrides = overrideMap()
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Loads from `UserDefaults`: starts from the shipped palette and layers any persisted
    /// override on top. Missing/malformed data, or an unknown slot id, degrade to the
    /// defaults rather than throwing.
    static func load(from defaults: UserDefaults) -> ColorTagPalette {
        var palette = ColorTagPalette.defaults
        guard
            let data = defaults.data(forKey: storageKey),
            let overrides = try? JSONDecoder().decode([String: StoredEntry].self, from: data)
        else {
            return palette
        }
        for (rawTag, stored) in overrides {
            guard let tag = ColorTag(rawValue: rawTag) else { continue }
            if let name = stored.name { palette.rename(tag, to: name) }
            palette.recolor(tag, to: stored.color)
        }
        return palette
    }
}

extension ColorTagPaletteEntry {
    /// The resolved display color: the user override if present, else the slot's shipped
    /// semantic color. Lives in the view layer (depends on `ColorTag.color`).
    var resolvedColor: Color {
        colorOverride?.color ?? tag.color
    }
}
