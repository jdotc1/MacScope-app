import SwiftUI

// A column whose content is wider than the column is cut off on both edges: SwiftUI centers the
// overflow (PRINCIPLES §6). MacScope's Types inspector did this with a table wider than its column,
// and the truncation check missed it, since no text was shortened, only shifted. Every Lumen column
// container (the inspector, the workspace window's sidebar, content, inspector and bottom regions,
// split-view columns, a sheet's content) therefore watches its content: when the width the content
// takes is more than the width the column offered, it reports itself. `LumenConformance.overflow`,
// `.truncation` and `.workspaceWindow` turn the reports into test failures.

/// Columns reported as narrower than their content, as messages
/// ("“Inspector” content is N pt wider than its column").
public struct LumenColumnOverflowKey: PreferenceKey {
    public static let defaultValue: Set<String> = []
    public static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
}

/// Lays its content out exactly as if it weren't there (the content's own size, placed centered
/// with the same proposal), and places a hidden reporter whose width is how far the content's width
/// exceeds the width offered: the centered-overflow case. Measuring at placement means flexible
/// content (which takes the width it's offered) never reports, and nothing about layout changes.
///
/// Inside a scroll view, content is placed at its own size, so the proposal there says nothing
/// about the column: a scrolling column passes its width as `offered` instead.
private struct LumenColumnWidthWatchLayout: Layout {
    var isActive = true
    var offered: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first, let reporter = subviews.last, subviews.count > 1 else { return }
        // Content of several views (a bare tuple) is placed as it would be, and isn't measured.
        for view in subviews.dropLast() {
            view.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: proposal)
        }
        var excess: CGFloat = 0
        if isActive, subviews.count == 2, let offered = offered ?? proposal.width, offered.isFinite, offered > 0.5 {
            excess = max(0, content.sizeThatFits(ProposedViewSize(width: offered, height: proposal.height)).width - offered)
        }
        reporter.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: excess, height: 0))
    }
}

private struct LumenColumnWidthWatch: ViewModifier {
    let name: String
    let isActive: Bool
    var offered: CGFloat?

    func body(content: Content) -> some View {
        // Always the same structure, active or not, so showing a region keeps its content's state.
        LumenColumnWidthWatchLayout(isActive: isActive, offered: offered) {
            content
            GeometryReader { excess in
                Color.clear.preference(key: LumenColumnOverflowKey.self,
                                       value: excess.size.width > 0.5
                                           ? ["“\(name)” content is \(Int(excess.size.width.rounded(.up))) pt wider than its column"] : [])
            }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// The column-overflow watch, switchable (a hidden workspace region is zero wide by design).
    func lumenColumnWidthWatch(_ name: String, isActive: Bool) -> some View {
        modifier(LumenColumnWidthWatch(name: name, isActive: isActive))
    }

    /// The watch for content inside a vertical scroll view: `columnWidth` is the scroll view's width.
    func lumenColumnWidthWatch(_ name: String, columnWidth: CGFloat) -> some View {
        modifier(LumenColumnWidthWatch(name: name, isActive: true, offered: columnWidth))
    }
}

public extension View {
    /// Marks the content of a column (a split-view pane, a custom inspector or sidebar) that must
    /// never be wider than the column: it reports itself to Lumen's conformance checks when its
    /// content takes more width than the column offers, which SwiftUI would center and clip on both
    /// edges. Lumen's own columns already do this. Apply to the content, inside the column's frame:
    ///
    /// ```swift
    /// TypesTable().lumenColumnContent("Types").frame(minWidth: 220, maxWidth: 360)
    /// ```
    ///
    /// Not for horizontal scroll views, whose content is meant to be wider than they are.
    func lumenColumnContent(_ name: String) -> some View {
        modifier(LumenColumnWidthWatch(name: name, isActive: true))
    }
}
