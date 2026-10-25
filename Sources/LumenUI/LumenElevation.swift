import SwiftUI

/// The one shadow Lumen draws: a floating surface (a menu, a popover, a palette, a toast) over the
/// window. Everything else gets its depth from material, a gentle gradient and a hairline, never a
/// drop shadow or glow (PRINCIPLES §7).
public enum LumenElevation: Sendable {
    /// Menus, completion lists, small popups.
    case menu
    /// Popovers, the command palette, search panels, notices.
    case popover
}

private struct LumenElevationShadow: ViewModifier {
    let elevation: LumenElevation
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        // Composited first: SwiftUI shadows each layer of a container on its own, so without it
        // every keycap, chip and swatch inside the surface carried a soft gray halo.
        let surface = content.compositingGroup()
        switch elevation {
        case .menu: surface.shadow(color: .black.opacity(dark ? 0.40 : 0.12), radius: 10, y: 4)
        case .popover: surface.shadow(color: .black.opacity(dark ? 0.45 : 0.14), radius: 16, y: 6)
        }
    }
}

public extension View {
    /// Lifts a floating surface above the window with Lumen's single, tight shadow.
    func lumenElevation(_ elevation: LumenElevation) -> some View {
        modifier(LumenElevationShadow(elevation: elevation))
    }
}

/// A soft halo of light behind a mark: Lumen's expressive flourish for a hero tile (the welcome
/// window, an empty-state hero) and a selected graph node. A glow is light, not depth, so it
/// isn't the drop shadow PRINCIPLES §7 rules out; keep it to a few marks per window.
public enum LumenGlow: Sendable {
    /// Behind a large hero tile (welcome window, address hero).
    case hero
    /// Around a selected node or card on a canvas.
    case selection
}

public extension View {
    /// Lights `color` softly behind the view.
    func lumenGlow(_ glow: LumenGlow, color: Color) -> some View {
        // Composited first, so the light falls behind the whole mark, not around each layer in it.
        switch glow {
        case .hero: compositingGroup().shadow(color: color.opacity(0.4), radius: 20, y: 4)
        case .selection: compositingGroup().shadow(color: color.opacity(0.45), radius: 8)
        }
    }
}

extension EnvironmentValues {
    /// Whether icon tiles inside are backlit (very subtle).
    @Entry var lumenTileBacklight = false
    /// Tiles draw on their hue in dark mode too: on a selected row, where a slate tile would read
    /// as a hole in the selection.
    @Entry var lumenTileHueGround = false
}

public extension View {
    /// Backlights the icon tiles inside: each tile's own hue falls softly on the surface just below
    /// it, as from a key lit from behind. Lumen's tool switchers and mode switchers are backlit; the
    /// toolbar and top bar never are. Pass `false` to turn it off for a container.
    func lumenTileBacklight(_ on: Bool = true) -> some View {
        environment(\.lumenTileBacklight, on)
    }
}
