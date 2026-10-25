import SwiftUI
import LumenTokens
import LumenUI

// Collections, store cards and the tab overview, live.

struct BrowsePage: View {
    @State private var mode: LumenCollectionMode = .grid
    @State private var size = 100.0
    @State private var selection: String? = "lumen"
    @State private var sort: LumenCollectionSort = .title
    @State private var opened = "Double-click an item to open it."
    @State private var states: [String: LumenItemState] = ["formatter": .available, "tidy": .installed, "snippets": .installed,
                                                           "linter": .available]
    @State private var tab: String? = "b"

    private static let items = [
        LumenCollectionItem(id: "lumen", title: "Lumen", detail: "~/Projects/Lumen", systemImage: "lumen.lens", hue: .hueViolet,
                            date: .now.addingTimeInterval(-600)),
        LumenCollectionItem(id: "macscope", title: "MacScope", detail: "~/Projects/MacScope", systemImage: "scope", hue: .hueBlue,
                            date: .now.addingTimeInterval(-86_400), group: "Apps"),
        LumenCollectionItem(id: "archiver", title: "Image Archiver", detail: "~/Projects/ImageArchiver", systemImage: "cross.case", hue: .hueTeal,
                            date: .now.addingTimeInterval(-3 * 86_400), group: "Apps"),
        LumenCollectionItem(id: "notebook", title: "Notebook", detail: "~/Projects/Notebook", systemImage: "doc.richtext", hue: .hueOrange,
                            date: .now.addingTimeInterval(-9 * 86_400), group: "Apps"),
    ]

    private static let cards: [(id: String, title: String, author: String, summary: String, systemImage: String, hue: LumenToken)] = [
        ("formatter", "Formatter", "Sam Ortiz", "Formatting that’s fast and reliable.", "text.alignleft", .huePink),
        ("tidy", "Tidy", "Lee Marsh", "Formats JavaScript, CSS and HTML.", "curlybraces", .hueBlue),
        ("snippets", "Snippets", "Sample Co.", "The essential toolkit for web developers.", "chevron.left.forwardslash.chevron.right", .hueGreen),
        ("linter", "Linter", "Sample Co.", "Finds and fixes problems in your JavaScript.", "checkmark.shield", .hueViolet),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Browse", summary: "A collection of projects as a list or a grid with its size slider and sort, a store’s carousel of item cards, an item’s detail header, and the tab overview.")

            LumenSectionHeader("Collection")
            VStack(alignment: .leading, spacing: 10) {
                LumenCollectionControls(mode: $mode, size: $size)
                LumenCollection(Self.items, mode: mode, size: size, selection: $selection, sort: $sort) { opened = "Opened \($0.title)" }
                    .frame(maxWidth: 420)
                Text(opened).font(.caption).foregroundStyle(.lumen(.fgTertiary))
            }

            LumenSectionHeader("Store")
            LumenCarousel("Most Popular", ids: Self.cards.map(\.id)) { id in
                if let card = Self.cards.first(where: { $0.id == id }) {
                    LumenItemCard(card.title, author: card.author, summary: card.summary, systemImage: card.systemImage, hue: card.hue,
                                  state: states[card.id] ?? .available, onInstall: { install(card.id) })
                }
            }
            .frame(maxWidth: 420)
            LumenDetailHeader("Snippets", summary: "The essential toolkit for web developers.", systemImage: "chevron.left.forwardslash.chevron.right",
                              hue: .hueGreen, categories: ["Completions"], meta: ["Version 1.3.6", "3 years ago"],
                              links: [LumenBarAction("Homepage", systemImage: "globe") {},
                                      LumenBarAction("Repository", systemImage: "arrow.triangle.branch") {}],
                              permissions: [("Read & Write Files", "pencil"), ("Network", "antenna.radiowaves.left.and.right")],
                              primary: states["snippets"] == .installed ? LumenBarAction("Uninstall") { states["snippets"] = .available }
                                                                     : LumenBarAction("Install") { install("snippets") },
                              onShare: {})
                .frame(maxWidth: 420)

            LumenSectionHeader("Tab overview")
            LumenTabOverview([
                LumenOverviewTab(id: "a", title: "Package.swift", systemImage: "shippingbox", hue: .hueOrange, isPinned: true) { CatalogThumbnail() },
                LumenOverviewTab(id: "b", title: "LumenExtras.swift", systemImage: "swift", hue: .hueOrange) { CatalogThumbnail() },
                LumenOverviewTab(id: "c", title: "README.md", systemImage: "doc.text", hue: .hueBlue) { CatalogThumbnail() },
                LumenOverviewTab(id: "d", title: "zsh", systemImage: "terminal", hue: .hueTeal) { CatalogThumbnail() },
            ], selection: tab, thumbnailWidth: 150) { tab = $0 }
            .frame(maxWidth: 420)
        }
    }

    private func install(_ id: String) {
        states[id] = .installing(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            states[id] = .installed
        }
    }
}

/// A stand-in document thumbnail: lines of fake code.
struct CatalogThumbnail: View {
    @Environment(\.lumenPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach([90, 60, 110, 40, 80], id: \.self) { width in
                RoundedRectangle(cornerRadius: 2).fill(palette[.fgTertiary].opacity(0.5)).frame(width: CGFloat(width), height: 5)
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(palette[.bgCanvas])
    }
}
