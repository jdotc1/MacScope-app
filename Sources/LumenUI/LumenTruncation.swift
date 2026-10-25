import SwiftUI

// Truncation is a defect for a primary label (a title, a button, a breadcrumb, a section name): the
// user loses words they need. Lumen's components mark such labels with `.lumenNeverTruncates`; each
// compares the width it needs on one line with the width it got and reports itself when cut short.
// `LumenConformance.truncation` and `.workspaceWindow` turn the reports into test failures, for any
// pane, sheet, settings page or window. Secondary detail (a path under a title) may truncate in the
// middle with a help tag, and doesn't use this.

extension EnvironmentValues {
    /// Whether Lumen's tables collect their cells' layout-check reports (truncation, visible text)
    /// for `LumenConformance` and test hosts. On wherever XCTest is loaded (any test run), off in a
    /// shipping app, where the reporting cost every scroll step and nothing read it (PERF-09). Set
    /// it to collect reports elsewhere (an in-app debug overlay).
    @Entry public var lumenReportsLayoutChecks: Bool = LumenLayoutChecks.isTesting
}

enum LumenLayoutChecks {
    /// XCTest is loaded: a test run, where the conformance checks read the reports.
    static let isTesting = NSClassFromString("XCTestCase") != nil
}

/// Labels reported as cut short, by their text.
public struct LumenTruncationKey: PreferenceKey {
    public static let defaultValue: Set<String> = []
    public static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
}

private struct LumenTruncationWatch: ViewModifier {
    let label: String
    /// The smallest scale the label may shrink to (`minimumScaleFactor`); shrinking within it isn't
    /// truncation.
    var minimumScale: CGFloat = 1

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { actual in
                // The same label laid out at its natural one-line width, measured and hidden.
                content
                    .fixedSize()
                    .hidden()
                    .background {
                        GeometryReader { natural in
                            Color.clear.preference(key: LumenTruncationKey.self,
                                                   value: natural.size.width * minimumScale > actual.size.width + 0.5 && actual.size.width > 0.5 ? [label] : [])
                        }
                    }
            }
            .accessibilityHidden(true)
        }
    }
}

public extension View {
    /// Marks a one-line primary label that must never be cut short: it reports itself to Lumen's
    /// conformance checks when it is. Apply to the `Text` (after its font), not to a container.
    func lumenNeverTruncates(_ label: String) -> some View {
        modifier(LumenTruncationWatch(label: label))
    }

    /// A one-line primary label that may shrink to `minimumScale` (its `minimumScaleFactor`) to fit,
    /// but must never be cut short at that scale. Shrinking within it isn't reported.
    func lumenNeverTruncates(_ label: String, minimumScale: CGFloat) -> some View {
        modifier(LumenTruncationWatch(label: label, minimumScale: minimumScale))
    }
}
