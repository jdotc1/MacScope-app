import SwiftUI

// Clipping is a defect (PRINCIPLES §6): a fixed-height container (a card, a tile, a settings box)
// whose content needs more height than it got cuts lines off or spills over its edge. A container
// marked `.lumenFixedContainer` compares its content's natural height at its width with the height
// it got and reports itself when the content doesn't fit. `LumenConformance.overflow` and
// `.workspaceWindow` turn the reports into test failures. Same technique as `.lumenNeverTruncates`.

/// Containers reported as clipping their content, as messages ("“name” clips its content by N pt").
public struct LumenOverflowKey: PreferenceKey {
    public static let defaultValue: Set<String> = []
    public static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
}

/// Lays its one subview out exactly as a frame would (centered), but reports no more height than
/// it was offered, so a measuring background sees the height the container got even when content
/// that can't shrink overflows it. Visually identical to the subview alone.
private struct LumenOfferedHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(proposal)
        guard let offered = proposal.height, offered.isFinite else { return size }
        return CGSize(width: size.width, height: min(size.height, offered))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: proposal)
    }
}

private struct LumenFixedContainerWatch: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        LumenOfferedHeight { content }
            .background {
                GeometryReader { actual in
                    // The same content at the container's width and its natural height, hidden.
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: actual.size.width)
                        .hidden()
                        .background {
                            GeometryReader { natural in
                                let excess = natural.size.height - actual.size.height
                                Color.clear.preference(key: LumenOverflowKey.self,
                                                       value: excess > 0.5 && actual.size.height > 0.5
                                                           ? ["“\(name)” clips its content by \(Int(excess.rounded(.up))) pt"] : [])
                            }
                        }
                }
                .accessibilityHidden(true)
            }
    }
}

public extension View {
    /// Marks the content of a fixed-height container (a card, a tile, a settings box) that must
    /// never clip it: it reports itself to Lumen's conformance checks when its content needs more
    /// height than it got. Apply inside the fixed frame, to the content:
    ///
    /// ```swift
    /// VStack { … }.lumenFixedContainer("Item card").frame(width: 300, height: 120)
    /// ```
    ///
    /// Not for scroll views, whose content is meant to be taller than they are.
    func lumenFixedContainer(_ name: String) -> some View {
        modifier(LumenFixedContainerWatch(name: name))
    }
}
