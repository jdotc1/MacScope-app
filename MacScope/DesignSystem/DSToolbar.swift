import LumenUI
import SwiftUI
import LumenTokens

/// A panel toggle is already a Button. Render it directly, letting the View menu retain sole
/// shortcut registration while the same resolved binding supplies the help tag.
struct DSToolbarInspectorToggle: View {
    @Binding var isPresented: Bool
    @AppStorage(KeyBindingSet.storageKey) private var overrides: Data?

    var body: some View {
        LumenPanelToggle(
            edge: .trailing,
            isOn: $isPresented,
            shortcut: DSWorkspaceViewShortcuts(
                bindings: KeyBindingSet.resolvingOverrides(overrides)
            ).inspector,
            registersShortcut: false
        )
        .dsToolbarDimming()
    }
}

extension View {
    func dsToolbarDimming() -> some View {
        modifier(DSToolbarDimming())
    }
}

/// Lumen's enabled inactive treatment, without compounding the button style's disabled
/// opacity (45%). Multiplying it by the inactive 55% would fall below the 2:1 chrome floor.
private struct DSToolbarDimming: ViewModifier {
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let active = activeState != .inactive
        content
            .saturation(active ? 1 : 0)
            .opacity(active || !isEnabled ? 1 : 0.55)
    }
}

/// Individual raised editor-mode buttons with a single surface around glyph and label.
struct DSEditorModeSwitcher: View {
    @Binding var selection: EditorMode
    @Environment(\.lumenPalette) private var palette
    @FocusState private var focused: Bool
    @State private var hovered: EditorMode?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsLabels: true)
            row(showsLabels: false)
        }
        .layoutPriority(1)
        .focusable()
        // Keep the mode group free of native focus outlines.
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(by: 1); return .handled }
        .dsToolbarDimming()
    }

    private func moveSelection(by step: Int) {
        let modes = EditorMode.allCases
        guard let index = modes.firstIndex(of: selection) else { return }
        selection = modes[(index + step + modes.count) % modes.count]
    }

    private func row(showsLabels: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(EditorMode.allCases, id: \.self) { mode in
                segment(mode, showsLabels: showsLabels)
            }
        }
        .fixedSize()
    }

    private func segment(_ mode: EditorMode, showsLabels: Bool) -> some View {
        let selected = selection == mode
        let foreground: Color = palette[selected ? .toolbarForeground : .fgSecondary]
        return Button { selection = mode } label: {
            HStack(spacing: 6) {
                LumenSymbol(mode.systemImage, size: 17)
                    .foregroundStyle(palette[mode.modeHue])
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                if showsLabels {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(minWidth: 32, minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(DSEditorModeButtonStyle(selected: selected, hovered: hovered == mode))
        .focusable(false)
        .onHover { hovered = $0 ? mode : (hovered == mode ? nil : hovered) }
        .help(mode.rawValue)
        .accessibilityLabel(mode.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A bevel, lower edge and directional shadow give the entire control physical depth.
private struct DSEditorModeButtonStyle: ButtonStyle {
    let selected: Bool
    let hovered: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let depressed = selected || configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let surface = palette[depressed ? .bgElevated : .bgHover]
        return configuration.label
            .background {
                shape.fill(LinearGradient(
                    colors: [surface, surface.opacity(0.88)],
                    startPoint: depressed ? .bottom : .top,
                    endPoint: depressed ? .top : .bottom
                ))
                shape.fill(LinearGradient(
                    colors: [.white.opacity(depressed ? 0.04 : (hovered ? 0.17 : 0.12)), .black.opacity(depressed ? 0.20 : 0.10)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(depressed ? 0.12 : 0.28), .black.opacity(0.38)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: contrast == .increased ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(depressed ? 0.12 : 0.36), radius: depressed ? 0.5 : 1.5, x: 0, y: depressed ? 0.5 : 2)
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}
