import SwiftUI

/// How tightly an app packs rows. Regular reproduces the app's base metrics exactly; Compact
/// fits more on screen; Comfortable gives larger targets. Heights come from the app's
/// `LumenMetrics.Layout`, so an app with its own row metrics keeps them at every density.
public enum LumenDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case regular
    case comfortable

    public var id: Self { self }

    public var label: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Regular"
        case .comfortable: "Comfortable"
        }
    }

    /// Minimum height of a one-line row.
    public func rowHeight(in layout: LumenMetrics.Layout) -> CGFloat {
        switch self {
        case .compact: layout.rowHeightCompact
        case .regular: layout.rowHeightRegular
        case .comfortable: layout.rowHeightComfortable
        }
    }

    /// Minimum height of a two-line (title and detail) row.
    public func detailedRowHeight(in layout: LumenMetrics.Layout) -> CGFloat {
        switch self {
        case .compact: layout.detailedRowHeightCompact
        case .regular: layout.detailedRowHeightRegular
        case .comfortable: layout.detailedRowHeightComfortable
        }
    }

    /// Vertical padding inside a row: the layout's regular padding, 2 pt less (never below 1)
    /// when compact, 2 pt more when comfortable.
    public func rowVerticalPadding(detailed: Bool, in layout: LumenMetrics.Layout) -> CGFloat {
        let regular = detailed ? layout.detailedRowVerticalPadding : layout.rowVerticalPadding
        switch self {
        case .compact: return max(1, regular - 2)
        case .regular: return regular
        case .comfortable: return regular + 2
        }
    }

    /// The density saved as `raw`; unknown values read as regular.
    public static func resolve(_ raw: String) -> LumenDensity { LumenDensity(rawValue: raw) ?? .regular }
}

extension EnvironmentValues {
    @Entry public var lumenDensity: LumenDensity = .regular
}

extension View {
    /// Reads the user's density preference (`<appName>.lumen.density` in the store's defaults)
    /// and provides it to the subtree. A store that doesn't persist provides regular.
    public func lumenDensityRoot(store: LumenThemeStore = .active) -> some View {
        modifier(LumenDensityRootModifier(configuration: store.configuration, persists: store.persistsSelection))
    }
}

private struct LumenDensityRootModifier: ViewModifier {
    @AppStorage private var densityRaw: String
    private let persists: Bool

    init(configuration: LumenStoreConfiguration, persists: Bool) {
        _densityRaw = AppStorage(wrappedValue: LumenDensity.regular.rawValue, configuration.densityDefaultsKey,
                                 store: configuration.defaults)
        self.persists = persists
    }

    func body(content: Content) -> some View {
        content.environment(\.lumenDensity, persists ? LumenDensity.resolve(densityRaw) : .regular)
    }
}
