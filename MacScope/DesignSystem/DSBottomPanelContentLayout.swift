import Foundation

/// Scroll-content sizing only: these never impose a minimum on the shared panel.
/// Breakpoint empty/repair actions need a taller document inside the small viewport.
enum DSBottomPanelContentLayout {
    static let debuggerHeaderAllowance: CGFloat = 60
    static let debuggerRowsMinimum: CGFloat = 80
    static let breakpointContentMinimum: CGFloat = 240

    static func debuggerHeight(availableHeight: CGFloat, isBreakpoints: Bool) -> CGFloat {
        max(
            isBreakpoints ? breakpointContentMinimum : debuggerRowsMinimum,
            availableHeight - debuggerHeaderAllowance
        )
    }
}
