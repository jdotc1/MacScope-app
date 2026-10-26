import SwiftUI
import LumenTokens
import LumenUI

/// Developer-only prototype: the MacScope workspace chrome rebuilt on the native macOS 26/27
/// toolbar, split view and inspector, to compare with the custom `WorkspaceTopBar` before deciding
/// whether to adopt it. It never replaces the production window. It shows sample content, and
/// opens from Window ▸ Native Toolbar Prototype when the `MacScopeToolbarPrototype` default is on:
///
///     defaults write org.macscope.app MacScopeToolbarPrototype -bool YES
struct NativeToolbarPrototypeView: View {
    static let windowID = "macscope.native-toolbar-prototype"
    static let enabledDefaultsKey = "MacScopeToolbarPrototype"
    /// Matches the production workspace window's minimum content height.
    private static let minimumContentHeight: CGFloat = 680

    @State private var mode = PrototypeMode.disassembly
    @State private var showInspector = true
    @State private var selection: String? = "-[MessageViewer init]"
    @State private var isAnalyzing = false

    private let functions = [
        "-[MessageViewer init]", "-[MessageViewer dealloc]", "_objc_msgSend$load",
        "sub_1000a3f40", "-[MailboxController reload:]", "_main",
    ]

    var body: some View {
        NavigationSplitView {
            List(functions, id: \.self, selection: $selection) { name in
                Label(name, systemImage: "function")
                    .lineLimit(1)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .scrollContentBackground(.hidden)
            .background(.lumen(.sidebarBackground))
        } detail: {
            VStack(spacing: 0) {
                PrototypeListing()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.lumen(.bgCanvas))
                    // Let the canvas extend under the sidebar and toolbar glass.
                    .backgroundExtensionEffect()
                HStack(spacing: Lumen.Space.s5) {
                    Label(mode.title, systemImage: mode.systemImage)
                    Label("arm64e", systemImage: "cpu").foregroundStyle(.lumen(.fgTertiary))
                    Spacer()
                    Text("0x1000a3e1c").monospacedDigit()
                }
                .font(Lumen.Font.monoCaption)
                .foregroundStyle(.lumen(.fgSecondary))
                .padding(.horizontal, Lumen.Space.s5)
                .frame(height: DS.Layout.statusBarHeight)
                .background(.lumen(.statusbarBackground))
            }
            .navigationTitle("Mail.app")
            .navigationSubtitle("arm64e · MH_EXECUTE")
        }
        .inspector(isPresented: $showInspector) {
            PrototypeInspector()
                .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
        }
        .toolbar { toolbarContent }
        .frame(minWidth: AppLayout.minimumSupportedWindowWidth, minHeight: Self.minimumContentHeight)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") {}
            Button("Forward", systemImage: "chevron.forward") {}
        }

        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $mode) {
                ForEach(PrototypeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }

        // Tasks: one glass group, like Nova's Build/Run/Stop cluster.
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Analyze", systemImage: "hammer") { isAnalyzing.toggle() }
            Button("Run", systemImage: "play.fill") {}
                .tint(.lumen(.statusSuccess))
            Button("Stop", systemImage: "stop.fill") { isAnalyzing = false }
                .tint(.lumen(.statusDanger))
                .disabled(!isAnalyzing)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // Live status sits outside the glass so it reads as information, not a control.
        ToolbarItem(placement: .primaryAction) {
            Label(isAnalyzing ? "Analyzing 71%" : "Ready", systemImage: isAnalyzing ? "circle.dotted" : "checkmark.circle")
                .labelStyle(.titleAndIcon)
                .font(Lumen.Font.caption)
                .foregroundStyle(.lumen(isAnalyzing ? .accent : .fgSecondary))
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Menu("Theme", systemImage: "paintpalette") {
                ForEach(DSThemeStore.shared.themes) { theme in
                    Button(theme.displayName) { DSThemeStore.shared.select(theme.id) }
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
        }
    }
}

private enum PrototypeMode: String, CaseIterable, Identifiable {
    case disassembly, pseudocode, graph, hex
    var id: Self { self }
    var title: String {
        switch self {
        case .disassembly: "Disassembly"
        case .pseudocode: "Pseudocode"
        case .graph: "Graph"
        case .hex: "Hex"
        }
    }
    var systemImage: String {
        switch self {
        case .disassembly: "text.alignleft"
        case .pseudocode: "curlybraces"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .hex: "number"
        }
    }
}

private struct PrototypeListing: View {
    private static let mnemonicColumnWidth: CGFloat = 64
    private let rows: [(String, String, String, LumenToken)] = [
        ("0x1000a3e10", "pacibsp", "", .syntaxMnemonicBranch),
        ("0x1000a3e14", "stp", "x29, x30, [sp, #-0x10]!", .syntaxMnemonicMemory),
        ("0x1000a3e18", "mov", "x29, sp", .syntaxMnemonicArithmetic),
        ("0x1000a3e1c", "adrp", "x1, selRef_init@PAGE", .syntaxMnemonicMemory),
        ("0x1000a3e20", "ldr", "x1, [x1, selRef_init@PAGEOFF]", .syntaxMnemonicMemory),
        ("0x1000a3e24", "bl", "_objc_msgSendSuper2", .syntaxMnemonicBranch),
        ("0x1000a3e28", "retab", "", .syntaxMnemonicBranch),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: Lumen.Space.s6) {
                    Text(row.0).foregroundStyle(.lumen(.syntaxAddress))
                    Text(row.1).foregroundStyle(.lumen(row.3)).fontWeight(.semibold)
                        .frame(width: Self.mnemonicColumnWidth, alignment: .leading)
                    Text(row.2).foregroundStyle(.lumen(.syntaxRegister))
                }
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, Lumen.Space.s6)
                .frame(maxWidth: .infinity, minHeight: AppEditorChrome.disassemblyRowHeight, alignment: .leading)
                .background(index == 3 ? Color.lumen(.listingSelection) : .clear)
            }
        }
        .padding(.top, Lumen.Space.s4)
    }
}

private struct PrototypeInspector: View {
    var body: some View {
        Form {
            Section("Instruction") {
                LabeledContent("Address", value: "0x1000a3e1c")
                LabeledContent("Encoding", value: "ADRP")
                LabeledContent("Target", value: "selRef_init")
            }
            Section("Evidence") {
                DSEvidenceBadge(evidence: .proven, source: .machORelocation)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.lumen(.inspectorBackground))
    }
}

#Preview("Native toolbar prototype") {
    NativeToolbarPrototypeView()
}

/// Window ▸ Native Toolbar Prototype, shown only when the developer default is on.
struct NativeToolbarPrototypeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            if UserDefaults.standard.bool(forKey: NativeToolbarPrototypeView.enabledDefaultsKey) {
                Divider()
                Button("Native Toolbar Prototype") {
                    openWindow(id: NativeToolbarPrototypeView.windowID)
                }
            }
        }
    }
}
