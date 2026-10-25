import AppKit
import SwiftUI

// Two rows of one column that truncate to the same visible text read as one value: MacScope's
// members table showed "triggerAna…" twice for triggerAnalysisOnAppear and triggerAnalysisOnChange,
// and the 8-character floor passed both. Each one-line cell that may truncate reports
// what it shows (its visible text at the width it got) with its column, and
// `LumenConformance.truncation` and `.workspaceWindow` fail when two different values in one
// column show the same thing. Components opt in with
// `.lumenReportsVisibleText(_:font:truncation:)`.

/// What a one-line cell shows: its column, its full text and the text visible at its width.
public struct LumenVisibleTextEntry: Hashable, Sendable {
    public let column: String
    public let text: String
    public let visible: String

    public init(column: String, text: String, visible: String) {
        self.column = column
        self.text = text
        self.visible = visible
    }
}

/// Every reporting cell's visible text (`.lumenReportsVisibleText`).
public struct LumenVisibleTextKey: PreferenceKey {
    public static let defaultValue: Set<LumenVisibleTextEntry> = []
    public static func reduce(value: inout Set<LumenVisibleTextEntry>, nextValue: () -> Set<LumenVisibleTextEntry>) {
        value.formUnion(nextValue())
    }
}

public enum LumenVisibleText {
    /// The text a one-line label of `font` shows in `width` with `truncation`: the whole text when it
    /// fits, else the longest prefix (`.tail`), suffix (`.head`) or balanced head and tail
    /// (`.middle`) that fits with an ellipsis. An estimate of what SwiftUI draws, close enough to
    /// tell two cells apart: what matters is whether two values look the same.
    public static func visible(_ text: String, width: CGFloat, font: NSFont, truncation: Text.TruncationMode = .tail) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ s: String) -> Bool { (s as NSString).size(withAttributes: attributes).width <= width + 0.5 }
        if fits(text) { return text }
        let characters = Array(text)
        func candidate(_ n: Int) -> String {
            switch truncation {
            case .head: return "…" + String(characters.suffix(n))
            case .middle: return String(characters.prefix((n + 1) / 2)) + "…" + String(characters.suffix(n / 2))
            default: return String(characters.prefix(n)) + "…"
            }
        }
        // The most characters that fit, by bisection (width grows with n).
        var low = 0, high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(candidate(mid)) { low = mid } else { high = mid - 1 }
        }
        return candidate(low)
    }
}

extension EnvironmentValues {
    /// The column the cells inside belong to, for `.lumenReportsVisibleText(_:font:truncation:)`:
    /// a table sets it on each column's cells. `nil` (the default) reports nothing.
    @Entry public var lumenVisibleTextColumn: String? = nil
}

private struct LumenVisibleTextReport: ViewModifier {
    let text: String
    let column: String?
    let font: NSFont
    let truncation: Text.TruncationMode
    @Environment(\.lumenVisibleTextColumn) private var environmentColumn

    func body(content: Content) -> some View {
        content.background {
            if let column = column ?? environmentColumn {
                GeometryReader { proxy in
                    Color.clear.preference(key: LumenVisibleTextKey.self, value: [
                        LumenVisibleTextEntry(column: column, text: text,
                                              visible: LumenVisibleText.visible(text, width: proxy.size.width, font: font, truncation: truncation)),
                    ])
                }
                .accessibilityHidden(true)
            }
        }
    }
}

public extension View {
    /// Reports what this one-line label shows at its width, so the conformance checks fail when two
    /// different values in one column truncate to the same text. Apply to the `Text`, with the font
    /// it's drawn in; `column` names the column (rows of one column share it), or comes from the
    /// environment (`lumenVisibleTextColumn`, which a table sets per column).
    ///
    /// ```swift
    /// Text(member.name).lineLimit(1).truncationMode(.middle)
    ///     .lumenReportsVisibleText(member.name, column: "Members.Name", font: .systemFont(ofSize: 12), truncation: .middle)
    /// ```
    func lumenReportsVisibleText(_ text: String, column: String? = nil, font: NSFont,
                                 truncation: Text.TruncationMode = .tail) -> some View {
        modifier(LumenVisibleTextReport(text: text, column: column, font: font, truncation: truncation))
    }
}
