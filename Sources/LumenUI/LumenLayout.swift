import AppKit
import SwiftUI

/// Layout checks for the rule that a window never cuts its content off: every column declares the
/// least width its content needs, and a window's minimum is the sum of its columns' minimums.
///
/// SwiftUI centers content that is wider than the space it's given, which clips both edges. Tests
/// use `minimumWidth(of:)` to prove a view fits the column it lives in:
///
/// ```swift
/// XCTAssertLessThanOrEqual(LumenLayout.minimumWidth(of: SettingsPane()), MyApp.detailMinWidth)
/// ```
public enum LumenLayout {
    /// `.lumenInspector`'s column widths. Count `min` in a window's minimum width.
    public static let inspectorColumn: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (220, 280, 360)

    /// The narrowest width `view` lays out at without overflowing: what SwiftUI chooses when offered
    /// almost no width. Measured with Lumen's palette and standard metrics unless the view sets its own.
    @MainActor
    public static func minimumWidth<Content: View>(of view: Content, height: CGFloat = 10_000) -> CGFloat {
        let host = NSHostingController(rootView: view.lumenPaletteRoot().lumenMetrics(.standard))
        return host.sizeThatFits(in: CGSize(width: 1, height: height)).width
    }
}

public extension View {
    /// Text that wraps and is never truncated, measured at least `LumenEmptyState.inlineMeasureWidth`
    /// wide. Plain `.fixedSize(horizontal: false, vertical: true)` answers a split view's near-zero-
    /// width sizing pass with the text wrapped a few letters per line, and that height becomes a
    /// minimum taller than the window (PRINCIPLES §6; the Workspace window in 0.51.1). Only a
    /// near-zero proposal (under `LumenWrapMeasureLayout.nearZeroWidth`, the sizing pass) changes:
    /// at any real width, a 90 pt column included, the text wraps within the width it's offered.
    /// `LumenConformance.narrowSizing` checks it.
    func lumenWrapsWithoutTruncating() -> some View {
        LumenWrapMeasureLayout(minimumWidth: LumenEmptyState.inlineMeasureWidth) { self }
    }

    /// `lumenWrapsWithoutTruncating()` for a stack placed at its ideal height, as
    /// `.fixedSize(horizontal: false, vertical: true)` places it: offered the bounds' height, a stack
    /// of selectable values squeezes its rows (the non-scrolling inspector).
    internal func lumenWrapsAtIdealHeight() -> some View {
        LumenWrapMeasureLayout(minimumWidth: LumenEmptyState.inlineMeasureWidth, placesAtIdealHeight: true) { self }
    }
}

/// Answers a near-zero width proposal (a split view's sizing pass) by measuring its one subview
/// `minimumWidth` wide; any other proposal goes through unchanged, so in a real column the text
/// wraps within the column instead of overflowing it. Either way the subview takes its full
/// wrapped height (see `View.lumenWrapsWithoutTruncating()`).
struct LumenWrapMeasureLayout: Layout {
    /// Proposals narrower than this are the sizing pass, not a column anything is drawn in.
    static let nearZeroWidth: CGFloat = 40

    var minimumWidth: CGFloat
    var placesAtIdealHeight = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = proposal.width.map { $0 < Self.nearZeroWidth ? max($0, minimumWidth) : $0 }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: placesAtIdealHeight ? nil : bounds.height))
    }
}

/// Wraps its one subview (centered text) to even lines: at the narrowest width that keeps the number
/// of lines the offered width gives, so the last line isn't one word left on its own ("cross-" /
/// "references."). A width that fits one line, or no width, goes through unchanged.
struct LumenBalancedWrapLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite, width > 0 else { return subview.sizeThatFits(proposal) }
        return Self.balanced(subview, width: width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = Self.balanced(subview, width: bounds.width)
        subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                      proposal: ProposedViewSize(width: size.width, height: nil))
    }

    /// The subview's size at the narrowest width (to a point) no taller than at `width`.
    static func balanced(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let wrapped = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let line = subview.sizeThatFits(.unspecified)
        guard line.width > width, line.height > 0 else { return wrapped }
        let lines = max(1, (wrapped.height / line.height).rounded())
        // No narrower than the text spread evenly over its lines; binary search to a point.
        var low = min(width, (line.width / lines).rounded(.down)), high = width
        while high - low > 1 {
            let mid = ((low + high) / 2).rounded()
            if subview.sizeThatFits(ProposedViewSize(width: mid, height: nil)).height <= wrapped.height + 0.5 { high = mid } else { low = mid }
        }
        return CGSize(width: high, height: wrapped.height)
    }
}
