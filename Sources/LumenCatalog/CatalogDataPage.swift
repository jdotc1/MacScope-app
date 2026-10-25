import SwiftUI
import LumenTokens
import LumenUI

// Notices, outlines, history, comparison and commit pieces, live.

struct DataPage: View {
    @State private var narrowValues = false
    @State private var notices: [LumenNotice] = []
    @State private var showsCard = true
    @State private var outline: LumenOutlineMode = .tree
    @State private var depth = 2
    @State private var sorts = false
    @State private var commit = "a1f5083"
    @State private var compared = "Latest Commit"
    @State private var change = 2
    @State private var ignoresWhitespace = false
    @State private var viewport: ClosedRange<Double> = 0.25...0.5
    @State private var checked: Set<String> = ["a", "n"]
    @State private var file: String? = "b"
    @State private var message = ""
    @State private var amends = false
    @State private var committed = ""

    private static let history: [(message: String, hash: String, refs: [(String, LumenRefKind)], time: String, author: String)] = [
        ("Consistency cleanup: code font fallbacks", "a1f5083", [("HEAD", .head), ("main", .branch), ("origin/main", .remote)], "14m", "avery"),
        ("Catalog Editor page", "7ec64f9", [("v0.27.0", .tag)], "28m", "avery"),
        ("Strings navigator rows", "7c42c22", [], "32m", "Robin"),
        ("Theme miniatures show syntax colors", "ba1e0ab", [("feature/minis", .custom(.huePink))], "1h", "Avery Quinn"),
    ]

    private static let nodes = [
        LumenChecklistNode(id: "src", title: "Sources", systemImage: "folder", hue: .hueBlue, depth: 0),
        LumenChecklistNode(id: "a", title: "LumenExtras.swift", systemImage: "swift", hue: .hueOrange, depth: 1, status: "A", statusTone: .statusSuccess),
        LumenChecklistNode(id: "b", title: "LumenPanels.swift", systemImage: "swift", hue: .hueOrange, depth: 1, status: "M", statusTone: .statusWarning),
        LumenChecklistNode(id: "c", title: "LumenOld.swift", systemImage: "swift", hue: .hueOrange, depth: 1, status: "D", statusTone: .statusDanger),
        LumenChecklistNode(id: "n", title: "Configuration.json", systemImage: "curlybraces", hue: .hueYellow, depth: 0, status: "?"),
    ]

    private static let lineLengths = (0..<80).map { [40, 12, 66, 30, 0, 52, 24, 70][$0 % 8] }
    private static let lineTokens = (0..<80).map { [LumenToken.hueBlue, .fgSecondary, .huePink, .hueGreen][$0 % 4] }

    private func postNotice() {
        notices.append(LumenNotice(source: "Build", title: "Build \(notices.count + 1) finished",
                                   message: "0 warnings, 0 errors.", systemImage: "hammer.fill", hue: .hueGreen,
                                   primary: LumenBarAction("Show Log") {}))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Data & Git", summary: "Notices that float in and leave, outline controls, a commit history with refs and avatars, the comparison header and diff navigator, a minimap, and the commit composer with its checklist of changes.")

            LumenSectionHeader("Semantic values")
            LumenSwitch(isOn: $narrowValues, label: "Narrow values")
            Text("Right-click a value and choose Copy to copy its full original.")
                .font(.caption).foregroundStyle(.lumen(.fgTertiary))
                .lumenWrapsWithoutTruncating()
            CatalogSemanticValues(narrow: narrowValues)

            LumenSectionHeader("Notices")
            if showsCard {
                LumenNoticeCard(LumenNotice(source: "Extension: Git Hosting", title: "Remote repository detected",
                                            message: "Connect sample/Lumen to show issues and pull requests?",
                                            systemImage: "arrow.triangle.branch", primary: LumenBarAction("Connect") { showsCard = false },
                                            secondary: LumenBarAction("Not Now") { showsCard = false })) { showsCard = false }
            } else {
                Button("Show the Notice Again") { showsCard = true }
            }
            // A stack of notices floating over its view, as they would over a window.
            // Empty, the stage says what it's for instead of showing an empty box.
            RoundedRectangle(cornerRadius: 10).fill(.lumen(.bgElevated))
                .overlay {
                    if notices.isEmpty {
                        LumenEmptyState(systemImage: "bell", title: "No notices",
                                        message: "Posted notices stack in the corner and leave when acted on or closed.",
                                        actionTitle: "Post a Notice") { postNotice() }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if !notices.isEmpty {
                        Button("Post a Notice", systemImage: "bell") { postNotice() }
                            .padding(12)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.lumen(.borderSubtle)) }
                .frame(height: 240)
                .frame(maxWidth: 420)
                .lumenNotices($notices)
                .clipped()

            LumenSectionHeader("Outline controls")
            LumenOutlineControls(mode: $outline, depth: $depth, sortsAlphabetically: $sorts)
                .frame(width: 300).lumenSidebarBackground().clipShape(.rect(cornerRadius: 8))
            Text("\(outline.rawValue.capitalized), \(depth) levels deep, \(sorts ? "sorted A–Z" : "in document order")")
                .font(.caption).foregroundStyle(.lumen(.fgTertiary))

            LumenSectionHeader("History")
            VStack(spacing: 0) {
                ForEach(Array(Self.history.enumerated()), id: \.offset) { index, entry in
                    LumenHistoryRow(message: entry.message, hash: entry.hash, refs: entry.refs, time: entry.time, author: entry.author,
                                    isFirst: index == 0, isLast: index == Self.history.count - 1, isSelected: commit == entry.hash)
                        .contentShape(.rect)
                        .onTapGesture { commit = entry.hash }
                }
            }
            .frame(width: 340).lumenSidebarBackground().clipShape(.rect(cornerRadius: 8))
            HStack(spacing: 8) {
                LumenAvatar("Avery Quinn", size: 22)
                LumenAvatar("Robin", size: 22)
                LumenRefPill("HEAD", kind: .head)
                LumenRefPill("main", kind: .branch)
                LumenRefPill("origin/main", kind: .remote)
                LumenRefPill("v0.37.0", kind: .tag)
            }

            LumenSectionHeader("Comparing versions")
            VStack(alignment: .leading, spacing: 10) {
                LumenComparisonHeader(leading: LumenComparisonSide("Current Version", tone: .hueBlue),
                                      trailing: LumenComparisonSide(compared, tone: .hueOrange, choices: [
                                          LumenBarAction("Latest Commit") { compared = "Latest Commit" },
                                          LumenBarAction("Staged") { compared = "Staged" },
                                          LumenBarAction("a1f5083") { compared = "a1f5083" },
                                      ]), detail: "Consistency cleanup")
                    .frame(maxWidth: 560)
                LumenDiffNavigator(status: "\(change) of 5", ignoresWhitespace: $ignoresWhitespace,
                                   onPrevious: { change = max(1, change - 1) }, onNext: { change = min(5, change + 1) })
                HStack(alignment: .top, spacing: 12) {
                    LumenMinimap(lineLengths: Self.lineLengths, lineTokens: Self.lineTokens, viewport: $viewport)
                        .frame(height: 180)
                    Text("Drag the minimap’s viewport. Showing \(Int(viewport.lowerBound * 100))–\(Int(viewport.upperBound * 100))% of the document.")
                        .font(.caption).foregroundStyle(.lumen(.fgTertiary)).frame(width: 180, alignment: .leading)
                }
            }

            LumenSectionHeader("Committing")
            VStack(alignment: .leading, spacing: 12) {
                LumenChecklistTree(Self.nodes, checked: $checked, selection: $file)
                LumenCommitComposer(message: $message, amends: $amends, author: "avery",
                                    canCommit: !checked.isEmpty && !message.isEmpty) {
                    committed = "Committed \(checked.count) files: “\(message.split(separator: "\n").first ?? "")”"
                    message = ""
                }
                if !committed.isEmpty { Text(committed).font(.caption).foregroundStyle(.lumen(.fgTertiary)) }
            }
            .frame(width: 320)
        }
    }
}

/// These are the original values, never pre-shortened display strings.
struct CatalogSemanticValues: View {
    let narrow: Bool
    static let narrowWidth: CGFloat = 160
    static let values = [
        "/Projects/Lumen/Sources/LumenUI/Components/Workspace/Document.swift",
        "Lumen.Workspace.DocumentController.openDocument(at:)",
        "0x0123456789abcdef0123456789abcdef0123456789abcdef",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.values, id: \.self) { value in
                LumenReferenceRow(value) {}
            }
        }
        .frame(width: narrow ? Self.narrowWidth : 420, alignment: .leading)
    }
}
