import SwiftUI
import LumenUI

extension DS {
    /// Structural sizes shared by the shell.
    enum Layout {
        static let sidebarRailWidth: CGFloat = 40
        static let sidebarRailButton: CGFloat = 28
        static let rowHeightCompact = Lumen.Layout.rowHeightCompact
        static let rowHeightRegular = Lumen.Layout.rowHeightRegular
        static let rowHeightComfortable = Lumen.Layout.rowHeightComfortable
        static let statusBarHeight: CGFloat = 22
        /// Leaves room for mode and address controls beside long function names.
        static let statusSymbolsMaximumWidth: CGFloat = 280
        static let tabHeight: CGFloat = 28
        static let minimumHitTarget: CGFloat = 24
        /// Every toolbar icon button: 28 pt target, 15 pt glyph.
        static let toolbarButton: CGFloat = 28
        static let toolbarGlyphSize: CGFloat = 15
        /// Widest a menu label in the editor status bar may grow before truncating.
    }
}
extension Lumen.Font {
    /// The breakpoint counter remains an app-owned listing-gutter metric.
    static let gutterBadge = SwiftUI.Font.system(size: 7, weight: .bold, design: .rounded)
}
