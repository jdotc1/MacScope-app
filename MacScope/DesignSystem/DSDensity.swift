import SwiftUI
import LumenTokens
import LumenUI

extension LumenDensity {
    static let defaultsKey = DSThemeStore.configuration.densityDefaultsKey
    var sidebarRowHeight: CGFloat { rowHeight(in: LumenMetrics.standard.layout) }
    var sidebarDetailedRowHeight: CGFloat { detailedRowHeight(in: LumenMetrics.standard.layout) }
    func sidebarVerticalPadding(detailed: Bool) -> CGFloat {
        rowVerticalPadding(detailed: detailed, in: LumenMetrics.standard.layout)
    }
    var listingRowHeight: CGFloat { rowHeight(in: LumenMetrics.standard.layout) }
}

extension EnvironmentValues {
    var dsDensity: LumenDensity {
        get { lumenDensity }
        set { lumenDensity = newValue }
    }
}

extension View {
    func dsDensityRoot() -> some View { lumenDensityRoot(store: DSThemeStore.active.lumen) }
}
