import LumenUI
import SwiftUI
import LumenTokens

extension LumenPaletteKey {
    var windowThemeID: String { themeIDs[.window] ?? DSBuiltInThemes.defaultID }
    var editorThemeID: String { themeIDs[.editor] ?? windowThemeID }
}

extension DS {
    static var palette: LumenResolvedPalette { DSThemeStore.active.resolvedPalette() }
}

extension EnvironmentValues {
    /// A compatibility spelling of the same key, so domain wrappers and Lumen always agree.
    var dsPalette: LumenResolvedPalette {
        get { lumenPalette }
        set { lumenPalette = newValue }
    }
}

extension View {
    func dsPaletteRoot(store: DSThemeStore = .active) -> some View {
        lumenPaletteRoot(store: store.lumen).lumenMetrics(.standard)
    }
}
