import SwiftUI

// Rule: a tile's backlight stays inside its strip and never crosses a
// hairline or the container's edge; where it can only be clipped (the toolbar) it's off. A strip
// that backlights its tiles marks itself `.lumenBacklightContainer(_:)`; the backlight view reports
// its visible extent with `.lumenBacklightExtent(blur:)`. `LumenConformance.backlight` turns a glow
// that leaves its container, or one with no container at all, into a test failure. The tile and the
// strips opt in.

/// One backlight's visible extent and the container it must stay inside, in global coordinates.
public struct LumenBacklightEntry: Hashable, Sendable {
    public let glow: CGRect
    /// `nil` when the tile isn't inside a `.lumenBacklightContainer`.
    public let container: String?
    public let containerID: UUID?
}

/// Every reporting backlight (`.lumenBacklightExtent`).
public struct LumenBacklightKey: PreferenceKey {
    public static let defaultValue: Set<LumenBacklightEntry> = []
    public static func reduce(value: inout Set<LumenBacklightEntry>, nextValue: () -> Set<LumenBacklightEntry>) { value.formUnion(nextValue()) }
}

/// Every backlight container's frame, in global coordinates, by its identity.
public struct LumenBacklightContainerKey: PreferenceKey {
    public static let defaultValue: [UUID: CGRect] = [:]
    public static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LumenBacklightContainerIdentity: Hashable, Sendable {
    let name: String
    let id: UUID
}

extension EnvironmentValues {
    @Entry var lumenBacklightContainer: LumenBacklightContainerIdentity? = nil
}

private struct LumenBacklightContainerModifier: ViewModifier {
    let name: String
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.lumenBacklightContainer, LumenBacklightContainerIdentity(name: name, id: id))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: LumenBacklightContainerKey.self, value: [id: proxy.frame(in: .global)])
                }
                .accessibilityHidden(true)
            }
    }
}

private struct LumenBacklightExtentModifier: ViewModifier {
    let bleed: CGFloat
    @Environment(\.lumenBacklightContainer) private var container

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(key: LumenBacklightKey.self, value: [
                    LumenBacklightEntry(glow: proxy.frame(in: .global).insetBy(dx: -bleed, dy: -bleed),
                                        container: container?.name, containerID: container?.id),
                ])
            }
            .accessibilityHidden(true)
        }
    }
}

public extension View {
    /// Marks the strip whose tiles are backlit (a sidebar switcher's row, a mode switcher): every
    /// backlight inside must stay within this view's bounds, so it never crosses the hairline or
    /// edge that bounds the strip. Apply to the strip, inside any hairline that bounds it.
    func lumenBacklightContainer(_ name: String) -> some View {
        modifier(LumenBacklightContainerModifier(name: name))
    }

    /// Reports a backlight's visible extent to the conformance checks: apply to the glow shape,
    /// after its frame and before its offset and blur (so the report moves with the glow), passing
    /// the blur radius:
    ///
    /// ```swift
    /// Ellipse().fill(glow).frame(width: w, height: h).lumenBacklightExtent(blur: r).offset(y: dy).blur(radius: r)
    /// ```
    ///
    /// The glow's visible edge is taken as 1.5 × the radius past the shape.
    func lumenBacklightExtent(blur radius: CGFloat) -> some View {
        modifier(LumenBacklightExtentModifier(bleed: radius * 1.5))
    }
}
