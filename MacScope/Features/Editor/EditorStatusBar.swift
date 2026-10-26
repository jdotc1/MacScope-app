import SwiftUI
import LumenUI

/// Nova-style per-editor status bar: one thin, quiet line at the foot of the code canvas where
/// every item does something. Mode switches the editor, Symbols jumps between neighboring
/// functions, and the address opens Go to Address.
struct EditorStatusBar: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.colorSchemeContrast) private var contrast

    /// Functions listed around the current one in the Symbols menu. The full list lives in the
    /// navigator; a menu with tens of thousands of items helps nobody.
    static let symbolsNeighborhood = 12

    static func selectedAddressText(for store: WorkspaceStore) -> String {
        store.selectedAddress.map { store.displayAddressString($0) } ?? "Go to Address"
    }

    @discardableResult
    static func navigateToSymbol(_ address: UInt64, in slot: ImageSlot,
                                 ownerBinaryID: UUID?, store: WorkspaceStore) -> Bool {
        guard let ownerBinaryID,
              store.snapshot.binary(in: slot)?.id == ownerBinaryID else { return false }
        return store.goToAddress(address, in: slot)
    }

    var body: some View {
        HStack(spacing: Lumen.Space.s5) {
            modeMenu

            if let binary = store.focusedBinary {
                Label(binary.architecture, systemImage: "cpu")
                    .help("\(binary.name) · \(binary.kind)")
                    .foregroundStyle(DS.editorColor(.fgTertiary))
            }

            if !functions.isEmpty {
                symbolsMenu
            }

            Spacer(minLength: Lumen.Space.s4)

            if !functions.isEmpty {
                Text("^[\(functions.count) function](inflect: true)")
                    .foregroundStyle(.lumen(.fgTertiary))
                    .monospacedDigit()
            }

            Button {
                store.searchSheetPresentation = .goToAddress
                store.showGoTo = true
            } label: {
                Label(Self.selectedAddressText(for: store), systemImage: "location")
                    .monospacedDigit()
            }
            .help("Go to Address")
            .accessibilityIdentifier("editor.status.go-to-address")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .font(Lumen.Font.monoCaption)
        .foregroundStyle(DS.editorColor(.fgSecondary))
        .tint(DS.editorColor(.accent))
        .lineLimit(1)
        .padding(.horizontal, Lumen.Space.s5)
        .frame(height: DS.Layout.statusBarHeight)
        .background(.lumen(.statusbarBackground))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DS.editorColor(.borderSubtle))
                .frame(height: AppContrastChrome.hairlineWidth(for: contrast))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor status")
        .accessibilityIdentifier("editor.status")
    }

    private var functions: [FunctionSummary] {
        store.focusedAnalysis?.functions ?? []
    }

    private var currentFunction: FunctionSummary? {
        EditorContextResolution.function(in: functions, selectedAddress: store.selectedAddress)
    }

    private var modeMenu: some View {
        Menu {
            Picker("Editor Mode", selection: $store.editorMode) {
                ForEach(EditorMode.allCases) { mode in
                    Label {
                        Text(mode.rawValue)
                    } icon: {
                        DS.symbolImage(mode.systemImage)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(store.editorMode.rawValue)
            } icon: {
                DS.symbolImage(store.editorMode.systemImage)
            }
        }
        .fixedSize()
        .help("Editor mode")
        .accessibilityIdentifier("editor.status.mode")
    }

    private var symbolsMenu: some View {
        let sorted = functions.sorted { $0.startAddress < $1.startAddress }
        let current = currentFunction
        let center = current.flatMap { fn in sorted.firstIndex { $0.id == fn.id } } ?? 0
        let lower = max(0, center - Self.symbolsNeighborhood / 2)
        let upper = min(sorted.count, lower + Self.symbolsNeighborhood)
        let slot = store.focusedImageSlot
        let ownerBinaryID = store.snapshot.binary(in: slot)?.id
        func name(_ fn: FunctionSummary) -> String {
            store.snapshot.displayName(at: fn.startAddress, in: slot, default: fn.name)
        }
        return Menu {
            ForEach(sorted[lower..<upper]) { fn in
                Button {
                    Self.navigateToSymbol(fn.startAddress, in: slot,
                                          ownerBinaryID: ownerBinaryID, store: store)
                } label: {
                    if fn.id == current?.id {
                        Label(name(fn), systemImage: "checkmark")
                    } else {
                        Text(name(fn))
                    }
                }
            }
            Divider()
            Button("Go to Symbol…") {
                // The Go to Address sheet resolves symbol names as well as addresses.
                store.searchSheetPresentation = .goToAddress
                store.showGoTo = true
            }
        } label: {
            Label(current.map(name) ?? "Symbols", systemImage: "function")
                .truncationMode(.middle)
        }
        .frame(maxWidth: DS.Layout.statusSymbolsMaximumWidth, alignment: .leading)
        .help("Jump to a nearby function")
        .accessibilityIdentifier("editor.status.symbols")
    }
}
