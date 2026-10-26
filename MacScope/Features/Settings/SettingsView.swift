import SwiftUI
import LumenTokens
import LumenUI

struct SettingsView: View {
    let providerController: Phase2LocalAIProviderController

    /// `initialCategory` opens a page other than Analysis (U8-2: truncation checks render each page).
    init(providerController: Phase2LocalAIProviderController, initialCategory: SettingsCategory = .analysis) {
        self.providerController = providerController
        _selectedCategory = State(initialValue: initialCategory)
    }

    @AppStorage("showAddressesInUppercase") private var showAddressesInUppercase = false
    @AppStorage(DisassemblyDisplayOptions.Key.showInstructionBytes)
    private var showInstructionBytes = DisassemblyDisplayOptions.default.showInstructionBytes
    @AppStorage(DisassemblyDisplayOptions.Key.showAddresses)
    private var showAddresses = DisassemblyDisplayOptions.default.showAddresses
    @AppStorage(DisassemblyDisplayOptions.Key.operandSpacing)
    private var operandSpacing = DisassemblyDisplayOptions.default.operandSpacing
    @AppStorage(PluginRuntimePolicy.StorageKey.allowDevelopmentPlugins)
    private var allowDevelopmentPlugins = PluginRuntimePolicy.settingsDefault.allowDevelopmentPlugins
    @AppStorage(PluginRuntimePolicy.StorageKey.requireSignedPlugins)
    private var requireSignedPlugins = PluginRuntimePolicy.settingsDefault.requireSignedPlugins
    @AppStorage(PluginRuntimePolicy.StorageKey.allowNetworkAccess)
    private var allowPluginNetworkAccess = PluginRuntimePolicy.settingsDefault.allowNetworkAccess
    @AppStorage(MCPAttachCoordinator.enabledDefaultsKey) private var allowAgentAttach = false
    @AppStorage(PluginRuntimePolicy.StorageKey.allowProcessSpawn)
    private var allowPluginProcessSpawn = PluginRuntimePolicy.settingsDefault.allowProcessSpawn

    // Decompiler emission options (threaded into PseudocodePrinter / RegionTree).
    @AppStorage(DecompilerOptions.Key.structureControlFlow)
    private var structureControlFlow = DecompilerOptions.default.structureControlFlow
    @AppStorage(DecompilerOptions.Key.deadCodeElimination)
    private var deadCodeElimination = DecompilerOptions.default.deadCodeElimination
    @AppStorage(DecompilerOptions.Key.nopElision)
    private var nopElision = DecompilerOptions.default.nopElision
    @AppStorage(DecompilerOptions.Key.functionSizeGate)
    private var functionSizeGate = DecompilerOptions.default.functionSizeGate

    // Fonts & theme.
    @AppStorage(AppAppearancePreference.storageKey)
    private var appearanceRaw = AppAppearancePreference.auto.rawValue
    @AppStorage(LumenDensity.defaultsKey) private var densityRaw = LumenDensity.regular.rawValue
    /// The code font (U5f: `LumenCodeFont`, migrated from the old family/size keys).
    @AppStorage(MacScopeCodeFont.storageKey)
    private var codeFontRaw = MacScopeCodeFont.current().rawValue

    // String interpretation.
    @AppStorage(StringDisplayEncoding.storageKey)
    private var stringEncodingRaw = StringDisplayEncoding.default.rawValue

    @State private var selectedCategory: SettingsCategory
    @State private var searchText = ""
    @State private var history = SettingsHistory<SettingsCategory>()

    private var visibleCategories: [SettingsCategory] {
        SettingsCategory.matching(searchText)
    }

    /// Selection that records history, so Back and Forward work like System Settings.
    private var categorySelection: Binding<SettingsCategory> {
        Binding(
            get: { selectedCategory },
            set: { next in
                history.visit(from: selectedCategory, to: next)
                selectedCategory = next
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(visibleCategories, selection: categorySelection) { category in
                // Lumen settings sidebar look: each category in its own colored tile.
                Label {
                    Text(category.title)
                } icon: {
                    LumenIconTile(category.systemImage, hue: category.hue, size: 20)
                }
                    .tag(category)
                    .accessibilityIdentifier("settings.category.\(category.rawValue)")
            }
            .listStyle(.sidebar)
            .overlay {
                if visibleCategories.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search Settings")
            .onChange(of: searchText) {
                // Keep the detail pane on a matching category while the user types.
                if let first = visibleCategories.first, !visibleCategories.contains(selectedCategory) {
                    categorySelection.wrappedValue = first
                }
            }
            .navigationSplitViewColumnWidth(
                min: AppSettingsChrome.categoryMinWidth,
                ideal: AppSettingsChrome.categoryIdealWidth,
                max: AppSettingsChrome.categoryMaxWidth
            )
        } detail: {
            selectedContent
                .frame(
                    minWidth: AppSettingsChrome.detailMinWidth,
                    idealWidth: AppSettingsChrome.detailIdealWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .workbenchPaneBackground(.settings)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") {
                    if let previous = history.goBack(from: selectedCategory) { selectedCategory = previous }
                }
                .disabled(!history.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityIdentifier("settings.history.back")

                Button("Forward", systemImage: "chevron.forward") {
                    if let next = history.goForward(from: selectedCategory) { selectedCategory = next }
                }
                .disabled(!history.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .accessibilityIdentifier("settings.history.forward")
            }
        }
        .navigationTitle(selectedCategory.title)
        .frame(
            minWidth: AppSettingsChrome.windowMinWidth,
            idealWidth: AppSettingsChrome.windowIdealWidth,
            minHeight: AppSettingsChrome.stableContentHeight,
            idealHeight: AppSettingsChrome.stableContentHeight,
            maxHeight: AppSettingsChrome.windowMaxHeight
        )
        .workbenchPaneBackground(.settings)
    }

    /// Settings layout ("B · Rich rows", Lumen 0.24.0): each pane a tiled header with a
    /// summary, then sections of rows with one-line descriptions; 2–4-choice pickers as pills.
    @ViewBuilder
    private var selectedContent: some View {
        switch selectedCategory {
        case .analysis:
            LumenSettingsPane("Analysis", systemImage: SettingsCategory.analysis.systemImage, hue: SettingsCategory.analysis.hue, summary: "How addresses and the disassembly listing read.", style: .rich) {
                LumenFormSection("Addresses") {
                    LumenSettingsRow("Uppercase addresses", description: "Show hex addresses as 0x1000A3E1C instead of 0x1000a3e1c.") {
                        Toggle("Uppercase addresses", isOn: $showAddressesInUppercase).toggleStyle(.switch)
                    }
                }
                LumenFormSection("Disassembly Display") {
                    LumenSettingsRow("Instruction bytes", description: "The raw bytes column beside each instruction.") {
                        Toggle("Show instruction bytes", isOn: $showInstructionBytes).toggleStyle(.switch)
                    }
                    LumenSettingsRow("Addresses", description: "The address column at the start of each row.") {
                        Toggle("Show addresses", isOn: $showAddresses).toggleStyle(.switch)
                    }
                    LumenSettingsRow("Operand spacing", description: "Spaces between the mnemonic and its operands: \(operandSpacing).") {
                        // U9-4g: a Lumen slider with its value field, as the other ranged settings.
                        LumenSlider(value: Self.sliderValue($operandSpacing, in: DisassemblyDisplayOptions.operandSpacingRange),
                                    in: Self.sliderRange(DisassemblyDisplayOptions.operandSpacingRange), step: 1,
                                    ticks: DisassemblyDisplayOptions.operandSpacingRange.count, showsField: true)
                            .accessibilityLabel("Operand spacing")
                    }
                    SettingsFootnote("Changes apply to the disassembly listing immediately.")
                }
                LumenFormSection("Workspace Packages") {
                    SettingsFootnote("New workspaces copy inputs into the .mscope package. Saved workspaces retain their recorded input-copying policy. Opening a package requires its attachments to be present.")
                }
            }
        case .decompiler:
            LumenSettingsPane("Decompiler", systemImage: SettingsCategory.decompiler.systemImage, hue: SettingsCategory.decompiler.hue, summary: "How MacScope's pseudocode is structured and simplified.", style: .rich) {
                LumenFormSection("Control Flow") {
                    LumenSettingsRow("Structured control flow", description: structureControlFlow
                        ? "Branches render as if/while/for where provably reducible; the rest fall back to goto."
                        : "Raw goto form: the region structurer is skipped.") {
                        Toggle("Recover structured control flow", isOn: $structureControlFlow).toggleStyle(.switch)
                    }
                }
                LumenFormSection("Simplification") {
                    LumenSettingsRow("Dead code after returns", description: "Drop unreachable instructions after a return.") {
                        Toggle("Eliminate dead code after returns", isOn: $deadCodeElimination).toggleStyle(.switch)
                    }
                    LumenSettingsRow("Nop padding", description: "Hide semantically empty nop lines.") {
                        Toggle("Hide nop padding", isOn: $nopElision).toggleStyle(.switch)
                    }
                    SettingsFootnote("Both are off by default to keep output byte-for-byte faithful.")
                }
                LumenFormSection("Structuring Budget") {
                    LumenSettingsRow("Function size gate", description: "Functions over \(functionSizeGate) instructions skip structuring and use the faster linear renderer.") {
                        LumenSlider(value: Self.sliderValue($functionSizeGate, in: DecompilerOptions.functionSizeGateRange),
                                    in: Self.sliderRange(DecompilerOptions.functionSizeGateRange), step: 16,
                                    endLabels: ("16", "65,536"), showsField: true, unit: "instr.")
                            .accessibilityLabel("Function size gate")
                    }
                }
            }
        case .appearance:
            LumenSettingsPane("Fonts & Theme", systemImage: SettingsCategory.appearance.systemImage, hue: SettingsCategory.appearance.hue, summary: "Theme, accent, density, appearance and the listing font.", style: .rich) {
                LumenFormSection("Theme") {
                    LumenThemeGallery(store: DSThemeStore.shared.lumen)
                        .padding(.vertical, Lumen.Space.s2)
                    SettingsFootnote("Themes are JSON files. Add your own to the Themes folder, then choose Reload Themes. With Increase Contrast turned on in System Settings, Scope switches to its high-contrast colors.")
                }
                LumenFormSection("Accent and Density") {
                    LumenSettingsRow("Use system accent", description: "Follow the accent set in System Settings; with Multicolor, the theme keeps its accent.") {
                        Toggle("Use system accent color", isOn: Binding(
                            get: { DSThemeStore.shared.usesSystemAccent },
                            set: { DSThemeStore.shared.setUsesSystemAccent($0) }
                        ))
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.theme.system-accent")
                    }
                    LumenSettingsRow("Density", description: "Row height in the navigator and lists.") {
                        LumenModeSwitcher(selection: $densityRaw, options: LumenDensity.allCases.map(\.rawValue), style: .pill) { raw in
                            LumenDensity(rawValue: raw)?.label ?? raw
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Density")
                        .accessibilityIdentifier("settings.theme.density")
                    }
                }
                LumenFormSection("Appearance") {
                    LumenSettingsRow("App appearance", description: DSThemeStore.shared.theme.forcedColorScheme.map { forced in
                        "\(DSThemeStore.shared.theme.displayName) is always \(forced == .dark ? "dark" : "light"), so this applies only to themes with both appearances."
                    } ?? "Automatic follows the system Light/Dark setting.") {
                        LumenModeSwitcher(selection: $appearanceRaw, options: AppAppearancePreference.allCases.map(\.rawValue), style: .pill) { raw in
                            AppAppearancePreference(rawValue: raw)?.label ?? raw
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("App appearance")
                        .disabled(DSThemeStore.shared.theme.forcedColorScheme != nil)
                    }
                }
                LumenFormSection("Code Font") {
                    LumenSettingsRow("Code font", description: "The disassembly listing, pseudocode and hex font; the byte column renders one point smaller.") {
                        LumenCodeFontPicker(selection: Binding(
                            get: { LumenCodeFont(rawValue: codeFontRaw) ?? .standard },
                            set: { codeFontRaw = $0.rawValue }
                        ))
                    }
                }

            }
        case .keysAndDisplay:
            // L4 (Lumen Tier 2e): a rich pane like the others, so the shortcuts table's card sits on
            // the pane rather than inside a grouped-form card.
            LumenSettingsPane("Keys & Display", systemImage: SettingsCategory.keysAndDisplay.systemImage,
                              hue: SettingsCategory.keysAndDisplay.hue,
                              summary: "Key bindings and how string bytes are shown.", style: .rich) {
                KeyBindingEditorView()

                LumenFormSection("String Display") {
                    LumenSettingsRow("Interpret string bytes as", description: "Display only; the stored bytes are unchanged.") {
                        LumenModeSwitcher(selection: $stringEncodingRaw, options: StringDisplayEncoding.allCases.map(\.rawValue), style: .pill) { raw in
                            StringDisplayEncoding(rawValue: raw)?.label ?? raw
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Interpret string bytes as")
                    }
                }
            }
        case .colorTags:
            // L3 (Lumen Tier 2e): a rich pane like the others; the table is as tall as its rows.
            LumenSettingsPane("Color Tags", systemImage: SettingsCategory.colorTags.systemImage,
                              hue: SettingsCategory.colorTags.hue,
                              summary: "Names for the highlight colors you apply to addresses.", style: .rich) {
                LumenFormSection("Tags") {
                    ColorTagManagerView()
                }
            }
        case .plugins:
            LumenSettingsPane("Plugins", systemImage: SettingsCategory.plugins.systemImage, hue: SettingsCategory.plugins.hue, summary: "Which plugins may load and what they may do.", style: .rich) {
                LumenFormSection("Trust") {
                    LumenSettingsRow("Development plugins", description: "Load unsigned plugins you are building locally.") {
                        Toggle("Allow development plugins", isOn: $allowDevelopmentPlugins).toggleStyle(.switch)
                    }
                    LumenSettingsRow("Require signatures", description: "Refuse any plugin without a valid code signature.") {
                        Toggle("Require signed plugins", isOn: $requireSignedPlugins).toggleStyle(.switch)
                    }
                }
                LumenFormSection("Runtime Permissions") {
                    LumenSettingsRow("Network access", description: "Let plugins open network connections.") {
                        Toggle("Allow plugin network access", isOn: $allowPluginNetworkAccess).toggleStyle(.switch)
                    }
                    LumenSettingsRow("Process spawning", description: "Let plugins launch other programs.") {
                        Toggle("Allow plugin process spawning", isOn: $allowPluginProcessSpawn).toggleStyle(.switch)
                    }
                    SettingsFootnote("Out-of-process plugin hosting remains the default; in-process plugin loading is not enabled from Settings.")
                }
                LumenFormSection("Agents") {
                    // A short description keeps the switch on the row's trailing edge like the others.
                    LumenSettingsRow("Allow agents to attach", description: "Let MCP agents work in a window you allow.") {
                        Toggle("Allow agents to attach", isOn: $allowAgentAttach).toggleStyle(.switch)
                    }
                    SettingsFootnote("Agents connect with MacScope --mcp-attach and wait until you click Allow in the window. Their edits are undoable and saved like yours. Only your user account can connect.")
                }
            }
        case .debugger:
            LumenSettingsPane("Debugger", systemImage: SettingsCategory.debugger.systemImage, hue: SettingsCategory.debugger.hue, summary: "How MacScope launches targets under LLDB.", style: .rich) {
                LumenFormSection("LLDB") {
                    LumenSettingsRow("Launch policy", description: "Launched targets stop at their entry point.") {
                        Text("Stop at entry").foregroundStyle(.secondary)
                    }
                    SettingsFootnote("Live debugger controls depend on the active debugger session and target policy. Configure launch targets and use available controls in the workspace debugger.")
                }
            }
        case .localAI:
            LocalAIProviderSettingsContainerView(controller: providerController)
                .accessibilityIdentifier("settings.local-ai")
        }
    }

    /// An integer setting as a `LumenSlider` value: rounded and clamped into its range on write.
    static func sliderValue(_ value: Binding<Int>, in range: ClosedRange<Int>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = min(max(Int($0.rounded()), range.lowerBound), range.upperBound) })
    }

    static func sliderRange(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }
}

/// Stable structural contract for the native Settings sidebar. Tests use this seam to prove every
/// category remains reachable without mounting a Settings window or depending on view internals.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case analysis
    case decompiler
    case appearance
    case keysAndDisplay
    case colorTags
    case plugins
    case debugger
    case localAI

    var id: Self { self }

    var title: String {
        switch self {
        case .analysis: "Analysis"
        case .decompiler: "Decompiler"
        case .appearance: "Fonts & Theme"
        case .keysAndDisplay: "Keys & Display"
        case .colorTags: "Color Tags"
        case .plugins: "Plugins"
        case .debugger: "Debugger"
        case .localAI: "Local AI"
        }
    }

    /// Each category's tile color (Lumen 0.24.0 pick): Analysis blue, Decompiler pink, Appearance
    /// violet, Strings/Keys graphite, Plugins green, Debugger red; Color Tags yellow, Local AI teal.
    var hue: LumenToken {
        switch self {
        case .analysis: .hueBlue
        case .decompiler: .huePink
        case .appearance: .hueViolet
        case .keysAndDisplay: .hueGraphite
        case .colorTags: .hueYellow
        case .plugins: .hueGreen
        case .debugger: .hueRed
        case .localAI: .hueTeal
        }
    }

    var systemImage: String {
        switch self {
        case .analysis: "function"
        case .decompiler: "lumen.pseudocode"
        case .appearance: "textformat"
        case .keysAndDisplay: "keyboard"
        case .colorTags: "tag"
        case .plugins: "puzzlepiece.extension"
        case .debugger: "ladybug"
        case .localAI: AppLocalAISettingsChrome.categorySymbol
        }
    }
}

private struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(AppSettingsChrome.footnoteLineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
}
