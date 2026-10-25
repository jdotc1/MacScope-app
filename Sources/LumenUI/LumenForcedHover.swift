import SwiftUI

// Hover states can't be golden-tested: each lives in a component's private `@State isHovered`,
// driven by `.onHover`, which needs the real cursor (synthetic mouse events change nothing in an
// offscreen window). This internal hook lets a test draw any component
// hovered: a component reads `lumenForcedHover` beside its own state,
//
//     @Environment(\.lumenForcedHover) private var forcedHover
//     private var hovered: Bool { isHovered || forcedHover }
//
// and uses `hovered` wherever it read `isHovered`. Tests (`@testable import LumenUI`) wrap a view in
// `.lumenHoverForced()`. Internal: apps never see it.

extension EnvironmentValues {
    /// Draws every hover-aware component inside as hovered (tests only).
    @Entry var lumenForcedHover = false
}

extension View {
    /// Draws the hover-aware components inside as if the pointer were over each (tests only).
    func lumenHoverForced(_ on: Bool = true) -> some View {
        environment(\.lumenForcedHover, on)
    }
}
