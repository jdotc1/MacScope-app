import SwiftUI
import LumenUI

/// The color-tag palette manager: view, rename, and recolor each named tag slot, with
/// per-slot and global reset-to-defaults. Edits persist immediately to `UserDefaults` as a
/// JSON override map. The underlying `ColorTag` slots never change (they are the stable
/// per-address persistence keys), so renaming/recoloring is purely cosmetic and never
/// disturbs an existing tag assignment.
struct ColorTagManagerView: View {
    @State private var palette = ColorTagPalette.load(from: .standard)
    @State private var selection: ColorTagPaletteEntry.ID?
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density

    /// U8-5d: the palette as a Lumen table: color, editable name, and a per-tag reset, with
    /// "Restore Defaults" in the table's footer. L3 (Lumen Tier 2e): square color wells, the reset
    /// arrow only on a changed tag, and the rows area as tall as its rows (the pane scrolls).
    var body: some View {
        LumenTable(
            palette.entries,
            selection: $selection,
            footer: LumenTableFooter(trailing: (title: "Restore Defaults", action: {
                palette.resetAll()
                palette.persist(to: .standard)
            })),
            minHeight: rowsHeight,
            columns: [
                LumenTableColumn("Color", width: 52) { entry in
                    LumenColorWell("\(entry.defaultName) tag color", color: colorBinding(for: entry))
                },
                LumenTableColumn("Name") { entry in
                    LumenTextField(entry.defaultName, text: nameBinding(for: entry))
                        .accessibilityLabel("\(entry.defaultName) tag name")
                },
                LumenTableColumn("", width: 28, alignment: .center) { entry in
                    if entry.name != entry.defaultName || entry.colorOverride != nil {
                        Button {
                            palette.reset(entry.tag)
                            palette.persist(to: .standard)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Reset this tag to its default name and color.")
                        .accessibilityLabel("Reset \(entry.defaultName) tag")
                    }
                },
            ]
        )
        .accessibilityIdentifier("settings.colorTags.table")
    }

    /// Every row shows: a row is at least the density's height and holds a color well (a control
    /// in a ring inset by s1).
    private var rowsHeight: CGFloat {
        let row = max(density.rowHeight(in: metrics.layout), metrics.layout.controlHeight + 2 * metrics.spacing.s1)
        return CGFloat(palette.entries.count) * (row + metrics.stroke.hairline)
    }

    private func colorBinding(for entry: ColorTagPaletteEntry) -> Binding<Color> {
        Binding<Color>(
            get: { palette.entry(for: entry.tag).resolvedColor },
            set: { newColor in
                palette.recolor(entry.tag, to: newColor.paletteColor)
                palette.persist(to: .standard)
            }
        )
    }

    private func nameBinding(for entry: ColorTagPaletteEntry) -> Binding<String> {
        Binding<String>(
            get: { palette.entry(for: entry.tag).name },
            set: { newName in
                palette.rename(entry.tag, to: newName)
                palette.persist(to: .standard)
            }
        )
    }
}

private extension Color {
    /// Best-effort RGBA extraction for persistence. Falls back to opaque black only if the
    /// platform can't resolve sRGB components (never happens for a `ColorPicker` value).
    var paletteColor: PaletteColor {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return PaletteColor(
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent),
            opacity: Double(nsColor.alphaComponent)
        )
    }
}
