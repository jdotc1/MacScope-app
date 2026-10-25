import SwiftUI
import LumenTokens

/// A miniature app window built only from Lumen parts: a toolbar, a sidebar with a selected row,
/// and a content area with a section header, badges, pills, property rows and an empty state.
///
/// Use it to preview an app's identity (theme plus metrics) in one place. Lumen's golden-image
/// tests and the visual catalog render it, so a change to any role or metric shows up here.
public struct LumenShowcase: View {
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init() {}

    private let rows: [(symbol: String, title: String, detail: String)] = [
        ("doc.text", "Overview", "12 items"),
        ("tray.full", "Inbox", "3 new"),
        ("clock", "Recent", "Today"),
        ("archivebox", "Archive", "248"),
    ]

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                sidebar.frame(width: 168)
                    // The column divider, as the welcome window and split views draw it: in Contrast the
                    // sidebar and the canvas are one fill, and nothing else marks the edge (GB-41).
                    .overlay(alignment: .trailing) { Rectangle().fill(palette[.borderSubtle]).frame(width: metrics.stroke.hairline) }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .clipShape(.rect(cornerRadius: metrics.radius.lg))
        .overlay { RoundedRectangle(cornerRadius: metrics.radius.lg).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
    }

    private var toolbar: some View {
        HStack(spacing: metrics.spacing.s4) {
            HStack(spacing: metrics.spacing.s2) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 9, height: 9)   // the system's traffic lights, not themeable
                }
            }
            Text("Project").font(metrics.typography.headline).foregroundStyle(palette[.toolbarForeground])
            Spacer()
            LumenSymbol("magnifyingglass")
                .font(.system(size: metrics.layout.toolbarGlyphSize))
                .foregroundStyle(palette[.toolbarForeground])
                .frame(width: metrics.layout.toolbarButton, height: metrics.layout.toolbarButton)
        }
        .padding(.horizontal, metrics.spacing.s5)
        .frame(height: metrics.layout.toolbarButton + metrics.spacing.s4)
        .background(palette[.toolbarBackground])
        .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s1) {
            Text("LIBRARY")
                .font(metrics.typography.sectionLabel)
                .tracking(0.5)
                .foregroundStyle(palette[.sidebarSecondaryForeground])
                .padding(.horizontal, metrics.spacing.s4)
                .padding(.top, metrics.spacing.s4)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let selected = index == 1
                HStack(spacing: metrics.spacing.s3) {
                    LumenSymbol(row.symbol)
                        .foregroundStyle(selected ? palette[.sidebarAccent] : palette[.sidebarSecondaryForeground])
                        .frame(width: metrics.iconSize.large)
                    Text(row.title).font(metrics.typography.body).foregroundStyle(palette[.sidebarForeground])
                    Spacer(minLength: 0)
                    Text(row.detail).font(metrics.typography.caption).foregroundStyle(palette[.sidebarSecondaryForeground])
                }
                .padding(.horizontal, metrics.spacing.s3)
                .frame(height: metrics.layout.rowHeightRegular)
                .background(selected ? palette[.sidebarRowSelected] : .clear, in: .rect(cornerRadius: metrics.radius.sm))
                .padding(.horizontal, metrics.spacing.s2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette[.sidebarBackground])
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s4) {
            LumenSectionHeader(title: "Inbox") { LumenBadge("3 new", tone: .accent) }
            HStack(spacing: metrics.spacing.s3) {
                LumenBadge("Verified", systemImage: "checkmark.seal.fill", tone: .success)
                LumenBadge("2 warnings", tone: .warning)
                LumenBadge("1 error", tone: .danger)
                LumenBadge("Draft")
            }
            HStack(spacing: metrics.spacing.s3) {
                LumenPill(label: "version", value: "2.4.1")
                LumenPill(label: "items", value: "1,284", style: .metric)
                LumenTag("pinned", token: .accent)
            }
            VStack(alignment: .leading, spacing: 0) {
                LumenPropertyRow(label: "Owner", value: "Alex", monospaced: false)
                LumenPropertyRow(label: "Identifier", value: "0x1000a3e1c")
            }
            Text("Selected row").font(metrics.typography.body).foregroundStyle(palette[.fgPrimary])
                .padding(.horizontal, metrics.spacing.s3)
                .frame(maxWidth: .infinity, minHeight: metrics.layout.rowHeightRegular, alignment: .leading)
                .background(palette[.bgSelected], in: .rect(cornerRadius: metrics.radius.sm))
            Text("A link to more").font(metrics.typography.callout).foregroundStyle(palette[.fgLink])
        }
        .padding(metrics.spacing.s6)
        .background(palette[.bgCanvas])
    }
}
