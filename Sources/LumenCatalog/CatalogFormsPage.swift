import SwiftUI
import LumenTokens
import LumenUI

// Settings forms and controls, live.

struct FormsPage: View {
    // Numbers and sentences
    @State private var lineHeight = 1.5
    @State private var limitsUploads = true
    @State private var uploadLimit = 500
    @State private var playsSound = false
    @State private var sound: String?
    @State private var wraps = true
    @State private var indent = 4
    @State private var lineNumbers = true
    @State private var minimap = false
    @State private var folding = true
    @State private var invisibles = false
    // Settings cards
    @State private var autosave = true
    @State private var sourceKit = true
    @State private var superHTML = false
    // Lists
    @State private var patterns = ["*.generated.swift", "Build/**"]
    @State private var event: String? = "fails"
    // Tabs, radios and tables
    @State private var tab = "Display"
    @State private var closes = "Only"
    @State private var keys = [KeyBinding(key: "⌥F1", action: "\\033[17~"), KeyBinding(key: "⌥F2", action: "\\033[18~"),
                               KeyBinding(key: "⌥F3", action: "\\033[19~")]
    @State private var selectedKey: String? = nil
    // Sliders, combos and menus
    @State private var idle = 45.0
    @State private var opacity = 0.3
    @State private var terminal = "xterm-256color"
    @State private var lastAction = "Nothing chosen yet"
    // Key/value and rules
    @State private var entries = [LumenKeyValue(key: "format.enable", value: "true", type: .boolean),
                                  LumenKeyValue(key: "suggest.maxItems", value: "40", type: .number),
                                  LumenKeyValue(key: "html.customData", value: "./data.json", type: .string)]
    @State private var match: LumenRuleMatch = .any
    @State private var conditions = [LumenRuleCondition(field: "Name", comparison: "is", value: ".svn"),
                                     LumenRuleCondition(field: "Size", comparison: "greater than", value: "10 MB")]
    // Colors and icons
    @State private var cursor = Color.purple
    @State private var ansi: [[Color]] = [[.black, Color(white: 0.33)],
                                          [Color(red: 1, green: 0.27, blue: 0.27), Color(red: 1, green: 0.45, blue: 0.38)],
                                          [Color(red: 0.15, green: 0.76, blue: 0.12), Color(red: 0.44, green: 0.8, blue: 0.34)]]
    @State private var icon = "server"
    @State private var family = "Menlo"
    @State private var fontStyle = "Regular"
    @State private var fontSize = 13.0
    // Files, servers and tools
    @State private var mode = 0o644
    @State private var service: String? = "gh"
    @State private var step = 1
    @State private var address = ""
    @State private var user = "dev"
    @State private var password = "secret"
    @State private var toolState: LumenToolInstallState = .available

    private static let rainbow: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]
    private static let ocean: [Color] = [.teal, .cyan, .blue, .indigo]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Forms & Controls", summary: "Settings that read like sentences, cards of integrations, list and table editors, sliders, color wells and the small controls a settings window needs. Everything here is live.")

            LumenSectionHeader("Numbers and sentences")
            VStack(alignment: .leading, spacing: 12) {
                LumenSettingsRow("Line height", description: "A multiple of the font size.") {
                    LumenNumberField(value: $lineHeight, in: 1...3, step: 0.1, fractionDigits: 1, unit: "× font size")
                }
                LumenSentenceRow(isOn: $limitsUploads, label: "Limit uploads") {
                    LumenSentenceText("Limit uploads to")
                    LumenNumberField(value: $uploadLimit, in: 0...10_000, step: 50, unit: "KB/s")
                }
                LumenSentenceRow(isOn: $playsSound, label: "Play a sound") {
                    LumenSentenceText("Play")
                    LumenInheritedPicker(selection: $sound, options: ["Glass", "Sosumi", "Tink"], inherited: "Sosumi", title: { $0 })
                    LumenSentenceText("when a build finishes")
                }
                LumenSentenceRow(isOn: $wraps, label: "Wrap lines") { LumenSentenceText("Wrap long lines") }
                LumenDependentGroup(enabled: wraps) {
                    LumenSentenceRow { LumenSentenceText("Hanging indent"); LumenNumberField(value: $indent, in: 0...16, unit: "spaces") }
                }
                LumenCheckboxGrid([
                    LumenCheckboxItem("Line numbers", isOn: $lineNumbers), LumenCheckboxItem("Minimap", isOn: $minimap),
                    LumenCheckboxItem("Code folding", isOn: $folding), LumenCheckboxItem("Invisibles", isOn: $invisibles),
                ])
            }
            .frame(maxWidth: 420, alignment: .leading)

            LumenSectionHeader("Settings cards")
            VStack(alignment: .leading, spacing: 12) {
                LumenSettingsCard {
                    LumenSettingsRow("Trim trailing whitespace", badge: ("checkmark.seal", "Set by .editorconfig")) {
                        Text("Default (Don’t Trim)").font(.callout).foregroundStyle(.lumen(.fgSecondary))
                    }
                    LumenSettingsRow("Autosave", description: "Saves documents as you type.") {
                        HStack(spacing: 6) {
                            LumenSwitch(isOn: $autosave, label: "Autosave")
                            LumenHelpButton("Autosave writes each change to disk a moment after you stop typing. Undo still works.")
                        }
                    }
                }
                LumenSettingsCard {
                    LumenIntegrationRow(isOn: $sourceKit, name: "SourceKit-LSP", detail: "/usr/bin/sourcekit-lsp",
                                        status: sourceKit ? .running : LumenIntegrationStatus("Off"), onRefresh: {}, onInfo: {})
                    LumenIntegrationRow(isOn: $superHTML, name: "SuperHTML", status: .notFound, onRefresh: {}, onInfo: {})
                }
            }
            .frame(maxWidth: 420, alignment: .leading)

            LumenSectionHeader("Lists")
            VStack(alignment: .leading, spacing: 12) {
                LumenListEditor(items: $patterns, addPrompt: "Add pattern", monospaced: true, minHeight: 80)
                LumenMasterDetail([
                    LumenMasterSection("Build", items: [LumenMasterItem(id: "starts", title: "Starts"),
                                                        LumenMasterItem(id: "fails", title: "Fails", isConfigured: true),
                                                        LumenMasterItem(id: "succeeds", title: "Succeeds")]),
                    LumenMasterSection("Run", items: [LumenMasterItem(id: "run.starts", title: "Starts")]),
                ], selection: $event, listWidth: 140) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("When a build \(item.title.lowercased())…").font(.callout)
                        Toggle("Show the Issues panel", isOn: .constant(item.isConfigured)).toggleStyle(.lumenCheckbox)
                    }
                    .padding(12)
                }
                .frame(height: 130)
            }
            .frame(maxWidth: 420, alignment: .leading)

            LumenSectionHeader("Tabs, radio groups and tables")
            VStack(alignment: .leading, spacing: 14) {
                LumenTabbedBox(selection: $tab, tabs: ["Display", "Editing", "Indentation"], title: { $0 }) { tab in
                    VStack(alignment: .leading, spacing: 8) {
                        switch tab {
                        case "Display":
                            Toggle("Line numbers", isOn: $lineNumbers).toggleStyle(.lumenCheckbox)
                            Toggle("Minimap", isOn: $minimap).toggleStyle(.lumenCheckbox)
                        case "Editing":
                            Toggle("Code folding", isOn: $folding).toggleStyle(.lumenCheckbox)
                        default:
                            LumenSentenceRow { LumenSentenceText("Indent with"); LumenNumberField(value: $indent, in: 0...16, unit: "spaces") }
                        }
                    }
                }
                LumenRadioGroup(selection: $closes, options: ["Always", "Never", "Only"],
                                title: { $0 == "Only" ? "Only if there are processes other than:" : $0 }) { option in
                    if option == "Only" { LumenTableText("rlogin, telnet, ssh", monospaced: true) }
                }
                LumenTable(keys, selection: $selectedKey,
                           footer: LumenTableFooter(onAdd: { keys.append(KeyBinding(key: "⌥F\(keys.count + 1)", action: "")) },
                                                    onRemove: { keys.removeAll { $0.id == selectedKey }; selectedKey = nil },
                                                    trailing: ("Restore Defaults", { keys = Array(keys.prefix(3)) })),
                           minHeight: 0, columns: [.text("Key", width: 70) { $0.key }, .text("Action", monospaced: true) { $0.action }])
            }
            .frame(maxWidth: 420, alignment: .leading)

            LumenSectionHeader("Sliders, combo fields and pull-downs")
            VStack(alignment: .leading, spacing: 14) {
                LumenSlider(value: $idle, in: 0...120, step: 15, ticks: 9, endLabels: ("Off", "120"), showsField: true, unit: "sec")
                LumenSlider(value: $opacity, in: 0...1)
                LumenComboField(text: $terminal, suggestions: ["vt100", "xterm", "xterm-256color"], monospaced: true)
                    .frame(width: 220)
                HStack(spacing: 10) {
                    LumenPullDownButton("Add", systemImage: "plus") {
                        Button("Generate Key…") { lastAction = "Generate Key…" }
                        Button("Import Key…") { lastAction = "Import Key…" }
                    }
                    LumenPullDownButton("Actions", systemImage: "ellipsis.circle") {
                        Button("Duplicate") { lastAction = "Duplicate" }
                        Button("Export…") { lastAction = "Export…" }
                    }
                    Text(lastAction).font(.caption).foregroundStyle(.lumen(.fgTertiary))
                }
            }

            LumenSectionHeader("Key/value and rule editors")
            VStack(alignment: .leading, spacing: 14) {
                LumenKeyValueEditor(entries: $entries, typed: true, emptyMessage: "No values")
                LumenRuleEditor(match: $match, conditions: $conditions, fields: ["Name", "Size", "Kind"],
                                comparisons: { $0 == "Size" ? ["greater than", "less than"] : ["is", "contains", "begins with"] })
            }
            .frame(maxWidth: 420, alignment: .leading)

            LumenSectionHeader("Colors, icons and fonts")
            VStack(alignment: .leading, spacing: 14) {
                LumenColorWell("Cursor", color: $cursor, supportsOpacity: true)
                LumenColorGrid(rows: ["Black", "Red", "Green"], columns: ["Normal", "Bright"]) { row, column in $ansi[row][column] }
                HStack(spacing: 10) {
                    LumenSwatchStrip(Self.rainbow)
                    Menu {
                        Button {} label: { LumenSwatchMenuLabel("Rainbow", colors: Self.rainbow) }
                        Button {} label: { LumenSwatchMenuLabel("Ocean", colors: Self.ocean) }
                    } label: {
                        Text("Color Scheme")
                    }
                    .fixedSize()
                }
                LumenIconPicker(selection: $icon, choices: [
                    LumenIconChoice(id: "server", systemImage: "server.rack", hue: .hueGreen),
                    LumenIconChoice(id: "cloud", systemImage: "cloud.fill", hue: .hueBlue),
                    LumenIconChoice(id: "terminal", systemImage: "terminal.fill", hue: .hueGraphite),
                    LumenIconChoice(id: "globe", systemImage: "globe", hue: .hueTeal),
                ], size: 36)
                LumenFontPicker(family: $family, style: $fontStyle, size: $fontSize, families: ["Menlo", "SF Mono", "Monaco"])
            }

            LumenSectionHeader("Files, servers and tools")
            VStack(alignment: .leading, spacing: 14) {
                LumenPermissionsGrid(mode: $mode)
                LumenFieldList("Untitled Server", subtitle: "SSH / SFTP", systemImage: "server.rack", hue: .hueGreen) {
                    LumenFieldRow("Address", text: $address, prompt: "server.com")
                    LumenFieldRow("User", text: $user, prompt: "(optional)")
                    LumenFieldRow("Password", text: $password, secure: true)
                }
                LumenWizardStep(step == 1 ? "Add a Service Account" : "Sign In", choices: [
                    LumenWizardChoice(id: "gh", title: "Hosting A", systemImage: "chevron.left.forwardslash.chevron.right", hue: .hueGraphite),
                    LumenWizardChoice(id: "gl", title: "Hosting B", detail: "Cloud or self-managed", systemImage: "flame", hue: .hueOrange),
                    LumenWizardChoice(id: "bb", title: "Hosting C", systemImage: "tray.full.fill", hue: .hueBlue),
                ], selection: $service, step: step, of: 2, nextTitle: step == 2 ? "Done" : "Next",
                                onCancel: { step = 1 }, onBack: step > 1 ? { step -= 1 } : nil, onNext: { step = step == 1 ? 2 : 1 })
                    .frame(height: 240)
                LumenManagedToolRow("HTML Language Server", version: "4.10.0", detail: "A language server for HTML.", state: toolState,
                                    onInstall: install, learnMore: LumenBarAction("Learn More…") {}) {
                    Button("Copy URL") {}
                    Button("Uninstall") { toolState = .available }.disabled(toolState != .installed)
                }
                LumenStatusRow("Installed", value: "/usr/local/bin/lumen v0.37", monospaced: true,
                               action: LumenBarAction("Reveal", systemImage: "magnifyingglass") {})
                LumenCodeSample(["lumen-theme validate Themes/", "lumen-theme export --out Docs/"])
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private func install() {
        toolState = .installing
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            toolState = .installed
        }
    }
}

/// A row of the key-bindings table.
struct KeyBinding: Identifiable, Hashable {
    let id = UUID().uuidString
    var key: String
    var action: String
}
