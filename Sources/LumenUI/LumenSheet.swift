import AppKit
import SwiftUI
import LumenTokens

// Sheets and the attach-to-process list, chosen for MacScope.

/// The state a sheet's footer reports beside its buttons ("Saved while the debugger is offline.").
public struct LumenSheetStatus: Hashable, Sendable {
    public enum Tone: Sendable, Hashable { case success, warning, danger, neutral }
    public let message: String
    public let tone: Tone
    /// The color, when given as a token like the rest of Lumen's status pieces.
    let token: LumenToken?

    public init(_ message: String, tone: Tone = .neutral) {
        self.message = message
        self.tone = tone
        token = nil
    }

    /// A status colored the way `LumenStripStatus` and `LumenBreakpointRow` are: `.statusSuccess`,
    /// `.statusWarning`, `.statusDanger`, `.statusInfo` or any other token. The status tokens also
    /// pick their glyph; others show an info glyph.
    public init(_ message: String, token: LumenToken) {
        self.message = message
        self.token = token
        switch token {
        case .statusSuccess: tone = .success
        case .statusWarning: tone = .warning
        case .statusDanger: tone = .danger
        default: tone = .neutral
        }
    }
}

/// A sheet's frame: a tile, title and context line at the top, the
/// content (`LumenFormSection`s, a list) scrolling only when it must, and a footer with the status,
/// a quiet Cancel (Esc) and one accent primary action (Return).
public struct LumenSheet<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let hue: LumenToken
    private let status: LumenSheetStatus?
    private let cancelTitle: String
    private let onCancel: () -> Void
    private let primary: LumenBarAction
    private let content: Content
    private var cancelAccessibilityIdentifier: String?
    /// False for a browse-only sheet: one Done button, which Esc also triggers.
    private var showsCancel = true

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ title: String, subtitle: String? = nil, systemImage: String, hue: LumenToken = .accent,
                status: LumenSheetStatus? = nil, cancelTitle: String = "Cancel", onCancel: @escaping () -> Void,
                primary: LumenBarAction, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hue = hue
        self.status = status
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
        self.primary = primary
        self.content = content()
    }

    /// - Parameter cancelAccessibilityIdentifier: set on Cancel, for UI tests. The primary action
    ///   takes its identifier from `LumenBarAction`.
    public init(_ title: String, subtitle: String? = nil, systemImage: String, hue: LumenToken = .accent,
                status: LumenSheetStatus? = nil, cancelTitle: String = "Cancel", cancelAccessibilityIdentifier: String?,
                onCancel: @escaping () -> Void, primary: LumenBarAction, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, hue: hue, status: status, cancelTitle: cancelTitle,
                  onCancel: onCancel, primary: primary, content: content)
        self.cancelAccessibilityIdentifier = cancelAccessibilityIdentifier
    }

    /// A browse-only sheet (a viewer, a list to look through): one primary action and no Cancel,
    /// since two buttons that both close the sheet would only add a choice that means nothing.
    /// Return and Esc both trigger `done`.
    public init(_ title: String, subtitle: String? = nil, systemImage: String, hue: LumenToken = .accent,
                status: LumenSheetStatus? = nil, done: LumenBarAction, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, hue: hue, status: status,
                  onCancel: done.perform, primary: done, content: content)
        showsCancel = false
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: metrics.spacing.s3) {
                LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileHeader)
                VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                    Text(title).font(metrics.typography.headline).foregroundStyle(palette[.fgPrimary])
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(metrics.spacing.s4)
            hairline
            ViewThatFits(in: .vertical) {
                body(of: content).frame(maxHeight: .infinity, alignment: .top)
                ScrollView { body(of: content) }
            }
            hairline
            footer
        }
        .lumenRaisedGround()
        .background(palette[.bgElevated])
    }

    private func body(of content: Content) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s4) { content }
            .padding(metrics.spacing.s4)
            .lumenColumnWidthWatch("\(title) sheet", isActive: true)   // PRINCIPLES §6: never wider than the sheet
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hairline: some View {
        Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
    }

    private var footer: some View {
        HStack(spacing: metrics.spacing.s2) {
            if let status {
                LumenSymbol(statusSymbol(status.tone)).font(.caption).foregroundStyle(palette[status.token ?? statusToken(status.tone)])
                    .accessibilityHidden(true)
                Text(status.message).font(metrics.typography.caption).foregroundStyle(palette[status.tone == .danger ? .statusDanger : .fgTertiary])
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(-1)
            }
            Spacer(minLength: metrics.spacing.s3)
            if showsCancel {
                Button(cancelTitle, action: onCancel)
                    .buttonStyle(.lumenQuiet)
                    .lumenFocusRing()
                    .keyboardShortcut(.cancelAction)
                    .lumenAccessibilityIdentifier(cancelAccessibilityIdentifier)
                    .fixedSize()
            } else {
                // Esc closes a browse-only sheet too, through the same action as Done. Invisible by
                // opacity, as the command palette's Esc is: `.hidden()` may also drop the shortcut.
                Button("Close", action: onCancel).keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            Button(primary.title, action: primary.perform)
                .buttonStyle(.lumenPrimary)
                .lumenFocusRing(cornerRadius: metrics.radius.pill)
                .disabled(!primary.isEnabled)
                .keyboardShortcut(.defaultAction)
                .help(primary.help ?? "")
                .lumenAccessibilityIdentifier(primary.accessibilityIdentifier)
                .fixedSize()
        }
        .padding(.horizontal, metrics.spacing.s4)
        .frame(minHeight: 48)
    }

    private func statusSymbol(_ tone: LumenSheetStatus.Tone) -> String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .neutral: "info.circle"
        }
    }

    private func statusToken(_ tone: LumenSheetStatus.Tone) -> LumenToken {
        switch tone {
        case .success: .statusSuccess
        case .warning: .statusWarning
        case .danger: .statusDanger
        case .neutral: .fgTertiary
        }
    }
}

/// A titled group of fields in a sheet: a small uppercase header over its rows.
public struct LumenFormSection<Content: View>: View {
    private let title: String
    private let content: Content
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            // The one section-label style.
            Text(title)
                .lumenSectionLabel()
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// A labeled field in a `LumenFormSection`: the label in a fixed column, the control filling the rest.
/// Long labels wrap; the control never clips.
public struct LumenFormRow<Control: View>: View {
    private let label: String
    private let labelWidth: CGFloat?
    private let control: Control
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter labelWidth: the label column; `nil` uses the metrics' `propertyLabelWidth`, so
    ///   sheet rows line up with inspector and property rows.
    public init(_ label: String, labelWidth: CGFloat? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.labelWidth = labelWidth
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s3) {
            Text(label).font(metrics.typography.callout).foregroundStyle(palette[.fgSecondary])
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: labelWidth ?? metrics.layout.propertyLabelWidth, alignment: .leading)
            control.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Processes

/// A running process, for an attach list.
public struct LumenProcess: Identifiable, Hashable, Sendable {
    public let pid: Int32
    public let name: String
    public let path: String?
    public let user: String?
    /// Running as another user or root: badged, since attaching needs more.
    public let isPrivileged: Bool
    public let systemImage: String
    public let hue: LumenToken
    public var id: Int32 { pid }

    public init(pid: Int32, name: String, path: String? = nil, user: String? = nil, isPrivileged: Bool = false,
                systemImage: String = "app", hue: LumenToken = .hueBlue) {
        self.pid = pid
        self.name = name
        self.path = path
        self.user = user
        self.isPrivileged = isPrivileged
        self.systemImage = systemImage
        self.hue = hue
    }
}

/// Processes as rows: a tile, the name over its path,
/// a badge when it runs as root or another user, and the PID at the trailing edge. Click selects;
/// double-click (or Return in the sheet) attaches through `onActivate`.
public struct LumenProcessList: View {
    private let processes: [LumenProcess]
    @Binding private var selection: Int32?
    private let onActivate: (LumenProcess) -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenCodeFont) private var codeFont
    @State private var hovered: Int32?
    @Environment(\.lumenEmptyMessage) private var emptyMessage

    public init(_ processes: [LumenProcess], selection: Binding<Int32?>, onActivate: @escaping (LumenProcess) -> Void = { _ in }) {
        self.processes = processes
        _selection = selection
        self.onActivate = onActivate
    }

    public var body: some View {
        LazyVStack(spacing: metrics.spacing.s1) {
            if processes.isEmpty { LumenEmptyState.inline(emptyMessage ?? "No processes") }
            ForEach(processes) { process in row(process) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Processes")
    }

    private func row(_ process: LumenProcess) -> some View {
        let selected = process.pid == selection
        // A picker's selection: the filled accent with white on it (`accent.filled` +
        // `accent.filledForeground`, the selection families).
        let ink = palette[.accentFilledForeground]
        return HStack(spacing: metrics.spacing.s3) {
            LumenRowTile(systemImage: process.systemImage, hue: process.hue, size: metrics.layout.tileRowDetailed, isHighlighted: selected,
                         foreground: .accentFilledForeground)
            VStack(alignment: .leading, spacing: 0) {
                // Regular weight: names are content, not headings (calm type).
                Text(process.name).font(metrics.typography.callout).foregroundStyle(selected ? ink : palette[.fgPrimary])
                    .lineLimit(1).lumenNeverTruncates(process.name)
                if let path = process.path {
                    Text(path).font(.caption2).foregroundStyle(selected ? ink : palette[.fgTertiary]).lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: metrics.spacing.s2)
            if process.isPrivileged, let user = process.user {
                Text(user).font(metrics.typography.captionEmphasized).foregroundStyle(selected ? ink : palette[.statusWarning])
                    .lumenChip(selected ? ink.opacity(LumenHighlightedTile.fill) : palette[.statusWarningBackground])   // the one chip spec
                    .fixedSize()
            }
            Text(verbatim: String(process.pid))
                .font((codeFont ?? .standard).font())
                .foregroundStyle(selected ? ink : palette[.fgSecondary])
                .fixedSize()
        }
        .padding(.horizontal, metrics.spacing.s2)
        .frame(minHeight: density.detailedRowHeight(in: metrics.layout))
        .background(selected ? palette[.accentFilled] : hovered == process.pid ? palette[.bgHover].opacity(palette.key.raised ? 1 : metrics.layout.hoverOpacity) : .clear,
                    in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        .contentShape(.rect)
        .lumenSelectAndOpen(select: { selection = process.pid }, open: { onActivate(process) })
        .onHover { hovered = $0 ? process.pid : (hovered == process.pid ? nil : hovered) }
        .help(process.path ?? process.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([process.name, "process \(process.pid)", process.isPrivileged ? process.user : nil, process.path]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Attach") { onActivate(process) }
    }
}
