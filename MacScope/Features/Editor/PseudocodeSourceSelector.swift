import SwiftUI
import LumenTokens
import LumenUI

/// Compact window-session source selector shown only inside the pseudocode context bar.
struct PseudocodeSourceSelector: View {
    @ObservedObject var selection: PseudocodeSourceSelectionModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Lumen pill switcher; the compact menu below
            // stays as the fallback when even the pill cannot fit.
            LumenModeSwitcher(selection: sourceBinding, options: PseudocodeSource.allCases, style: .pill, title: \.rawValue)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(segmentedAccessibility.label)
            .accessibilityValue(segmentedAccessibility.value)
            .accessibilityHint(segmentedAccessibility.hint)
            .accessibilityIdentifier(
                NativeDecompilerAccessibilityIdentifiers.sourceSegmented
            )

            Menu {
                ForEach(PseudocodeSource.allCases) { source in
                    Button(source.rawValue) {
                        selection.select(source)
                    }
                }
            } label: {
                Label(selection.source.rawValue, systemImage: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(menuAccessibility.label)
            .accessibilityValue(menuAccessibility.value)
            .accessibilityHint(menuAccessibility.hint)
            .accessibilityIdentifier(NativeDecompilerAccessibilityIdentifiers.sourceMenu)
        }
        .help("Choose native decompilation, MacScope pseudocode, or a semantic comparison")
    }

    private var sourceBinding: Binding<PseudocodeSource> {
        Binding(
            get: { selection.source },
            set: { selection.select($0) }
        )
    }

    private var segmentedAccessibility: FocusedPresentationAccessibility.NativeSourceSelectorPresentation {
        FocusedPresentationAccessibility.nativeSourceSelector(
            source: selection.source,
            mode: .segmented
        )
    }

    private var menuAccessibility: FocusedPresentationAccessibility.NativeSourceSelectorPresentation {
        FocusedPresentationAccessibility.nativeSourceSelector(
            source: selection.source,
            mode: .compactMenu
        )
    }
}
