import SwiftUI

/// One-shot initial focus plus SwiftUI's declared default target. User-directed
/// Tab/click navigation stays free to leave the field; no delayed retry owns focus.
private struct DSTextEntryFocus: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .defaultFocus($isFocused, true)
            .task { isFocused = true }
    }
}

extension View {
    func dsInitialTextEntryFocus() -> some View {
        modifier(DSTextEntryFocus())
    }
}
