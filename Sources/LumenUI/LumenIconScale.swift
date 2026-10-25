import SwiftUI

// Icon scale is a rule, not a taste: a tile that is a whole control by itself (a tool switcher, a
// rail button) is as large as the pane's header tile (`tileTool`), and a tile beside its text is at
// least 16 pt. Tiles report themselves when they break the rule; `LumenConformance.iconScale`
// turns the reports into test failures.

/// What a tile is doing, which decides how small it may be.
public enum LumenIconRole: Sendable {
    /// Beside its text label (a row, a menu item, a section header).
    case inline
    /// The whole control, with no text beside it (a switcher tile, a rail button).
    case control
    /// Heading a section (an inspector section, a sidebar section): the section tile size, 28 pt.
    case section
}

/// Tiles reported as smaller than their role allows, by description.
public struct LumenIconScaleKey: PreferenceKey {
    public static let defaultValue: Set<String> = []
    public static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
}

public extension LumenIconRole {
    /// The least size this role allows.
    func minimumSize(in layout: LumenMetrics.Layout) -> CGFloat {
        switch self {
        case .inline: 16
        case .control: max(layout.tileTool, layout.minimumHitTarget)
        case .section: layout.tileSection
        }
    }
}

extension EnvironmentValues {
    @Entry var lumenIconRole: LumenIconRole = .inline
}

public extension View {
    /// Sets the role of the icon tiles inside, for the icon-scale rule.
    func lumenIconRole(_ role: LumenIconRole) -> some View {
        environment(\.lumenIconRole, role)
    }
}

// MARK: Icon-only controls

// A button whose label is only an icon has no text to widen it, so nothing keeps its hit area from
// shrinking to the glyph (PRINCIPLES §7). `.lumenIconOnlyControl()` measures the button's frame and
// reports it through `LumenIconScaleKey` when either side is under `minimumHitTarget`;
// `LumenConformance.iconScale` and `.workspaceWindow` fail on the report.

private struct LumenIconOnlyControlWatch: ViewModifier {
    let label: String?
    let isActive: Bool
    @Environment(\.lumenMetrics) private var metrics

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let minimum = metrics.layout.minimumHitTarget
                let size = proxy.size
                // Zero-sized means hidden (a collapsed region), not undersized.
                let undersized = isActive && size.width > 0.5 && size.height > 0.5
                    && (size.width + 0.5 < minimum || size.height + 0.5 < minimum)
                Color.clear.preference(key: LumenIconScaleKey.self, value: undersized
                    ? ["\(label.map { "“\($0)” " } ?? "an ")icon-only control is \(Int(size.width.rounded()))×\(Int(size.height.rounded())) pt; its hit area needs \(Int(minimum)) pt"]
                    : [])
            }
            .accessibilityHidden(true)
        }
    }
}

public extension View {
    /// Marks a button whose label is only an icon: it reports itself to Lumen's conformance checks
    /// when its hit area (this view's frame) is smaller than `metrics.layout.minimumHitTarget` on
    /// either side. Apply after the button style, so the frame measured is the one that's clicked:
    ///
    /// ```swift
    /// Button("Add", systemImage: "plus", action: add)
    ///     .labelStyle(.iconOnly).buttonStyle(LumenToolbarIconButtonStyle())
    ///     .lumenIconOnlyControl("Add")
    /// ```
    /// - Parameter label: names the control in the report; the report is generic without it.
    func lumenIconOnlyControl(_ label: String? = nil) -> some View {
        modifier(LumenIconOnlyControlWatch(label: label, isActive: true))
    }
}

extension View {
    /// `.lumenIconOnlyControl(_:)` only while the label is only an icon (a bar action that shows its
    /// title when there's room).
    func lumenIconOnlyControl(_ label: String?, isActive: Bool) -> some View {
        modifier(LumenIconOnlyControlWatch(label: label, isActive: isActive))
    }
}
