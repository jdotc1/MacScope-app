import SwiftUI
import LumenUI

/// Arbitrary addresses and image disambiguation retain a native sheet; command
/// discovery is hosted separately by dsWorkspaceCommandPalette on the root.
struct GoToSheet: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        GoToAddressSheet(store: store)
    }
}

private struct GoToAddressSheet: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showsImageChoices = false
    @State private var navigationIssue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Text("Go to Address or Symbol")
                .font(.title3.weight(.semibold))
                .lumenNeverTruncates("Go to Address or Symbol")

            TextField("0x100000000 or symbol name", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.address)
                .dsInitialTextEntryFocus()
                .accessibilityIdentifier("goToAddressInput")
                .onSubmit(go)
                .onChange(of: query) { _, _ in
                    showsImageChoices = false
                    navigationIssue = nil
                }

            if let navigationIssue {
                Text(navigationIssue)
                    .font(.callout)
                    .foregroundStyle(Color.lumen(.statusDanger))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("goToAddressIssue")
            }

            if showsImageChoices {
                Text("Choose the image containing this address.")
                    .font(.callout)
                ForEach(DSGoToAddressRouting.entries(for: query, in: store) ?? []) { entry in
                    let invocation = DSCommandPaletteInvocation(entry: entry, store: store)
                    Button(entry.title) {
                        apply(DSGoToAddressRouting.perform(invocation, in: store))
                    }
                    .accessibilityHint(entry.categorySubtitle)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Lumen.Space.s8)
        .frame(width: 420)
    }

    private func go() {
        apply(DSGoToAddressRouting.submit(query, in: store))
    }

    private func apply(_ submission: DSGoToAddressRouting.Submission) {
        navigationIssue = nil
        switch submission {
        case .navigated:
            dismiss()
        case .chooseImage:
            showsImageChoices = true
        case .failed(let issue):
            navigationIssue = issue
        }
    }
}

struct CommandPaletteEntry: Identifiable {
    let id: String
    let kind: CommandPaletteEntryKind
    let title: String
    let subtitle: String
    let detail: String?
    let systemImage: String
    let keywords: [String]
    let availability: CommandPaletteAvailability
    let action: CommandPaletteAction

    init(
        id: String,
        kind: CommandPaletteEntryKind,
        title: String,
        subtitle: String,
        detail: String? = nil,
        systemImage: String,
        keywords: [String],
        availability: CommandPaletteAvailability = .available,
        action: CommandPaletteAction
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.systemImage = systemImage
        self.keywords = keywords
        self.availability = availability
        self.action = action
    }

    var categorySubtitle: String {
        "\(kind.rawValue) / \(subtitle)"
    }

    var trailingAccessoryTitle: String {
        detail ?? availability.unavailableShortTitle ?? kind.rawValue
    }

    var accessibilityLabel: String {
        if let unavailableReason = availability.unavailableReason {
            return "\(title), \(categorySubtitle), unavailable, \(unavailableReason)"
        }
        return "\(title), \(categorySubtitle)"
    }

    func matches(_ normalizedQuery: String) -> Bool {
        let terms = normalizedQuery.split(separator: " ")
        guard !terms.isEmpty else { return true }
        let text = searchableText
        return terms.allSatisfy { text.contains($0) }
    }

    func score(for normalizedQuery: String) -> Int {
        let lowercasedTitle = title.lowercased()
        let lowercasedSubtitle = subtitle.lowercased()

        if lowercasedTitle == normalizedQuery { return 100 }
        if lowercasedTitle.hasPrefix(normalizedQuery) { return 90 }
        if lowercasedSubtitle.hasPrefix(normalizedQuery) { return 80 }
        if lowercasedTitle.contains(normalizedQuery) { return 70 }
        if keywords.contains(where: { $0.lowercased().hasPrefix(normalizedQuery) }) { return 60 }
        return 10
    }

    private var searchableText: String {
        ([title, subtitle, detail, kind.rawValue, availability.unavailableReason] + keywords)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}

enum CommandPaletteEntryKind: String, CaseIterable {
    case navigation = "Navigation"
    case workspace = "Workspace"
    case editor = "Editor"
    case debug = "Debug"
    case symbol = "Symbol"
    case address = "Address"

    var sortRank: Int {
        switch self {
        case .navigation: 0
        case .workspace: 1
        case .editor: 2
        case .debug: 3
        case .symbol: 4
        case .address: 5
        }
    }
}

enum CommandPaletteAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        switch self {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }

    var unavailableReason: String? {
        switch self {
        case .available:
            return nil
        case .unavailable(let reason):
            return reason
        }
    }

    var unavailableShortTitle: String? {
        unavailableReason == nil ? nil : "Unavailable"
    }
}

enum EditorScaffoldAffordance: String, CaseIterable {
    case renameSymbol
    case editComment
    case setTag
    case markAsData
    case markAsCode
    case editFunctionSignature
    case defineType
    case defineSwitchHint

    var title: String {
        switch self {
        case .renameSymbol: "Rename Symbol"
        case .editComment: "Add/Edit Comment"
        case .setTag: "Set Tag"
        case .markAsData: "Mark as Data"
        case .markAsCode: "Mark as Code"
        case .editFunctionSignature: "Edit Signature"
        case .defineType: "Define Type"
        case .defineSwitchHint: "Define Switch Hint"
        }
    }

    var systemImage: String {
        switch self {
        case .renameSymbol: "text.cursor"
        case .editComment: "pencil"
        case .setTag: "tag"
        case .markAsData: "number"
        case .markAsCode: "chevron.left.forwardslash.chevron.right"
        case .editFunctionSignature: "function"
        case .defineType: "curlybraces"
        case .defineSwitchHint: "tablecells"
        }
    }

    /// True when the affordance is workspace-global (no selected instruction needed).
    var isWorkspaceGlobal: Bool {
        self == .defineType
    }

    var keywords: [String] {
        switch self {
        case .renameSymbol:
            return ["rename", "symbol", "label", "function"]
        case .editComment:
            return ["comment", "annotation", "note", "instruction"]
        case .setTag:
            return ["tag", "label", "category", "mark", "annotation"]
        case .markAsData:
            return ["data", "mark", "bytes", "undefine", "db", "word"]
        case .markAsCode:
            return ["code", "mark", "instruction", "disassemble", "undefine"]
        case .editFunctionSignature:
            return ["signature", "prototype", "return", "arguments", "parameters", "function"]
        case .defineType:
            return ["type", "struct", "union", "enum", "typedef", "define"]
        case .defineSwitchHint:
            return ["switch", "case", "jump", "table", "hint", "dispatch", "br"]
        }
    }

    var unavailableReason: String {
        switch self {
        case .renameSymbol:
            return "Rename editor model is scaffolded but not wired to persistence."
        case .editComment:
            return "Comment editor model is scaffolded but not wired to persistence."
        case .setTag, .markAsData, .markAsCode, .editFunctionSignature, .defineType, .defineSwitchHint:
            // Wired to the override store; this string is never shown (the catalog
            // gates them on selection / availability, not unavailability). Kept for
            // exhaustiveness.
            return "Select an instruction first."
        }
    }
}

enum CommandPaletteAction {
    case showGoToAddress
    case goToAddress(UInt64)
    case goToAddressInSlot(UInt64, ImageSlot)
    case selectFunction(FunctionSummary.ID)
    case selectTool(WorkspaceTool)
    case selectEditorMode(EditorMode)
    case toggleInspector
    case toggleBreakpoint
    case presentEditorScaffold(EditorScaffoldAffordance)
    /// Apply (or clear, when nil) a highlight color to the selected instruction.
    case setColorTag(ColorTag?)
    /// Apply (or clear, when nil) a workspace type at the selected instruction.
    case applyType(String?)
    /// Set (or clear, when nil) the immediate-operand format at the selection.
    case setOperandFormat(OperandFormat?)
    /// Re-open the type editor for the catalog type with this id.
    case editType(UUID)
    /// Delete the catalog type with this id.
    case deleteType(UUID)
}

enum CommandPaletteCatalog {
    static func entries(
        functions: [FunctionSummary],
        hasSelection: Bool,
        hasHexBytes: Bool,
        addressOverrides: [UInt64: AddressOverride] = [:],
        typeDefinitions: [TypeDefinition] = []
    ) -> [CommandPaletteEntry] {
        commandEntries(hasSelection: hasSelection, hasHexBytes: hasHexBytes)
            + workspaceToolEntries()
            + editorModeEntries()
            + colorEntries(hasSelection: hasSelection)
            + operandFormatEntries(hasSelection: hasSelection)
            + typeEntries(definitions: typeDefinitions, hasSelection: hasSelection)
            + symbolEntries(functions: functions, addressOverrides: addressOverrides)
    }

    /// Per defined type: "Apply Type: <name>" (acts on the selected instruction),
    /// "Edit Type: <name>" and "Delete Type: <name>" (workspace-global catalog ops,
    /// always available). Plus one "Clear Type" command when any type exists.
    private static func typeEntries(definitions: [TypeDefinition], hasSelection: Bool) -> [CommandPaletteEntry] {
        guard !definitions.isEmpty else { return [] }
        let applyAvailability: CommandPaletteAvailability =
            hasSelection ? .available : .unavailable("Select an instruction first.")
        var entries: [CommandPaletteEntry] = []
        for type in definitions {
            entries.append(CommandPaletteEntry(
                id: "type-apply:\(type.id.uuidString)",
                kind: .editor,
                title: "Apply Type: \(type.name)",
                subtitle: "Editor Model",
                systemImage: "curlybraces",
                keywords: ["type", "apply", type.kind.rawValue, type.name],
                availability: applyAvailability,
                action: .applyType(type.name)
            ))
            entries.append(CommandPaletteEntry(
                id: "type-edit:\(type.id.uuidString)",
                kind: .editor,
                title: "Edit Type: \(type.name)",
                subtitle: "Editor Model",
                systemImage: "curlybraces",
                keywords: ["type", "edit", "rename", type.kind.rawValue, type.name],
                availability: .available,
                action: .editType(type.id)
            ))
            entries.append(CommandPaletteEntry(
                id: "type-delete:\(type.id.uuidString)",
                kind: .editor,
                title: "Delete Type: \(type.name)",
                subtitle: "Editor Model",
                systemImage: "trash",
                keywords: ["type", "delete", "remove", type.kind.rawValue, type.name],
                availability: .available,
                action: .deleteType(type.id)
            ))
        }
        entries.append(CommandPaletteEntry(
            id: "type-apply:clear",
            kind: .editor,
            title: "Clear Type",
            subtitle: "Editor Model",
            systemImage: "curlybraces",
            keywords: ["type", "clear", "remove"],
            availability: applyAvailability,
            action: .applyType(nil)
        ))
        return entries
    }

    /// Per-color "Set Color: <Name>" commands plus a "Clear Color" command, all
    /// acting on the selected instruction. Available only with a selection.
    private static func colorEntries(hasSelection: Bool) -> [CommandPaletteEntry] {
        let availability: CommandPaletteAvailability =
            hasSelection ? .available : .unavailable("Select an instruction first.")
        let colors = ColorTag.allCases.map { color in
            CommandPaletteEntry(
                id: "color:\(color.rawValue)",
                kind: .editor,
                title: "Set Color: \(color.displayName)",
                subtitle: "Editor Model",
                systemImage: "paintpalette",
                keywords: ["color", "highlight", "mark", color.rawValue],
                availability: availability,
                action: .setColorTag(color)
            )
        }
        let clear = CommandPaletteEntry(
            id: "color:clear",
            kind: .editor,
            title: "Clear Color",
            subtitle: "Editor Model",
            systemImage: "paintpalette",
            keywords: ["color", "clear", "remove", "highlight"],
            availability: availability,
            action: .setColorTag(nil)
        )
        return colors + [clear]
    }

    /// Per-format "Format Operand: <Name>" commands plus a "Clear Operand Format"
    /// command, all acting on the selected instruction's immediate operand.
    private static func operandFormatEntries(hasSelection: Bool) -> [CommandPaletteEntry] {
        let availability: CommandPaletteAvailability =
            hasSelection ? .available : .unavailable("Select an instruction first.")
        let formats = OperandFormat.allCases.map { format in
            CommandPaletteEntry(
                id: "operand-format:\(format.rawValue)",
                kind: .editor,
                title: "Format Operand: \(format.displayName)",
                subtitle: "Editor Model",
                systemImage: "number.square",
                keywords: ["operand", "format", "immediate", "hex", "decimal", "char", format.rawValue],
                availability: availability,
                action: .setOperandFormat(format)
            )
        }
        let clear = CommandPaletteEntry(
            id: "operand-format:clear",
            kind: .editor,
            title: "Clear Operand Format",
            subtitle: "Editor Model",
            systemImage: "number.square",
            keywords: ["operand", "format", "clear", "remove", "default"],
            availability: availability,
            action: .setOperandFormat(nil)
        )
        return formats + [clear]
    }

    static func filteredEntries(
        query: String,
        baseEntries: [CommandPaletteEntry],
        indexedAddresses: Set<UInt64>,
        addressEntryProvider: ((UInt64) -> [CommandPaletteEntry])? = nil
    ) -> [CommandPaletteEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmedQuery.lowercased()

        var entries: [CommandPaletteEntry]
        if normalizedQuery.isEmpty {
            entries = baseEntries
        } else {
            // Ranking normalizes strings and searches keywords. Compute it once
            // per match instead of repeating that work for every sort comparison.
            entries = baseEntries
                .filter { $0.matches(normalizedQuery) }
                .map { (entry: $0, score: $0.score(for: normalizedQuery)) }
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.entry.kind.sortRank < rhs.entry.kind.sortRank
                    }
                    return lhs.score > rhs.score
                }
                .map(\.entry)
        }

        if let address = parseHexAddress(trimmedQuery) {
            let addressEntries = addressEntryProvider?(address)
                ?? addressEntry(for: trimmedQuery, isIndexed: indexedAddresses.contains).map { [$0] }
                ?? []
            entries.insert(contentsOf: addressEntries, at: 0)
        }

        return entries
    }

    static func addressEntry(
        for value: String,
        isIndexed: (UInt64) -> Bool
    ) -> CommandPaletteEntry? {
        guard let address = parseHexAddress(value) else { return nil }
        return addressEntry(for: address, indexed: isIndexed(address))
    }

    /// Builds address matches without consulting SwiftUI or mutable workspace state. The caller
    /// supplies the already-resolved image facts, which keeps collision/runtime behavior directly
    /// testable and leaves this catalog responsible only for presentation + action identity.
    static func addressEntries(
        for address: UInt64,
        matchingSlots: [ImageSlot],
        imageName: (ImageSlot) -> String?,
        mode: WorkspaceStore.AddressDisplayMode,
        resolvedRuntimeTarget: ImageAddress?
    ) -> [CommandPaletteEntry] {
        let targets: [ImageAddress]
        switch mode {
        case .image:
            targets = matchingSlots.sorted().map { ImageAddress(slot: $0, address: address) }
        case .runtime:
            targets = resolvedRuntimeTarget.map { [$0] } ?? []
        }

        guard !targets.isEmpty else {
            // Preserve the existing focused-slot route for an unmapped image VA or an
            // unresolvable runtime VA. The store wrapper owns which slot is focused.
            return [addressEntry(for: address, indexed: false)]
        }

        return targets.map { target in
            let name = imageName(target.slot) ?? "image \(target.slot.rawValue)"
            return CommandPaletteEntry(
                id: "address:\(target.slot.rawValue):\(target.address):\(address)",
                kind: .address,
                title: "Go to \(address.hexAddress) — \(name)",
                subtitle: "Indexed Instruction",
                detail: "Return",
                systemImage: "location",
                keywords: ["address", "jump", "offset", "hex", address.hexAddress, name],
                action: .goToAddressInSlot(target.address, target.slot)
            )
        }
    }

    private static func addressEntry(for address: UInt64, indexed: Bool) -> CommandPaletteEntry {
        return CommandPaletteEntry(
            id: "address:\(address)",
            kind: .address,
            title: "Go to \(address.hexAddress)",
            subtitle: indexed ? "Indexed Instruction" : "Raw Address",
            detail: "Return",
            systemImage: "location",
            keywords: ["address", "jump", "offset", "hex", address.hexAddress],
            action: .goToAddress(address)
        )
    }

    private static func commandEntries(
        hasSelection: Bool,
        hasHexBytes: Bool
    ) -> [CommandPaletteEntry] {
        [
            CommandPaletteEntry(
                id: "command:go-to-address",
                kind: .navigation,
                title: "Go to Address",
                subtitle: "Command",
                detail: "Command-L",
                systemImage: "location",
                keywords: ["address", "jump", "offset", "hex"],
                action: .showGoToAddress
            ),
            CommandPaletteEntry(
                id: "command:search-hex-bytes",
                kind: .navigation,
                title: "Search Bytes in Hex",
                subtitle: "Hex",
                detail: "Command-4",
                systemImage: "number",
                keywords: ["hex", "bytes", "search", "raw", "offset"],
                availability: hasHexBytes ? .available : .unavailable("Open a target with readable bytes before searching hex."),
                action: .selectEditorMode(.hex)
            ),
            CommandPaletteEntry(
                id: "command:toggle-inspector",
                kind: .workspace,
                title: "Toggle Inspector",
                subtitle: "Workspace",
                systemImage: "sidebar.trailing",
                keywords: ["inspector", "details", "metadata"],
                action: .toggleInspector
            ),
            CommandPaletteEntry(
                id: "command:toggle-breakpoint",
                kind: .debug,
                title: "Toggle Breakpoint",
                subtitle: "Debugger",
                detail: "Control-Command-B",
                systemImage: "lumen.breakpoint",
                keywords: ["debug", "break", "breakpoint"],
                availability: hasSelection ? .available : .unavailable("Select an instruction before toggling a breakpoint."),
                action: .toggleBreakpoint
            )
        ] + EditorScaffoldAffordance.allCases.map { affordance in
            let availability: CommandPaletteAvailability
            if affordance.isWorkspaceGlobal {
                availability = .available
            } else {
                // These are wired to the override store; they need a selected
                // instruction/function to act on.
                availability = hasSelection ? .available : .unavailable("Select an instruction first.")
            }
            return CommandPaletteEntry(
                id: "editor-scaffold:\(affordance.rawValue)",
                kind: .editor,
                title: affordance.title,
                subtitle: "Editor Model",
                systemImage: affordance.systemImage,
                keywords: affordance.keywords,
                availability: availability,
                action: .presentEditorScaffold(affordance)
            )
        }
    }

    private static func workspaceToolEntries() -> [CommandPaletteEntry] {
        WorkspaceTool.allCases.map { tool in
            CommandPaletteEntry(
                id: "tool:\(tool.id)",
                kind: .workspace,
                title: "Show \(tool.rawValue)",
                subtitle: "Navigator",
                detail: "Tool",
                systemImage: tool.systemImage,
                keywords: ["sidebar", "navigator", tool.rawValue],
                action: .selectTool(tool)
            )
        }
    }

    private static func editorModeEntries() -> [CommandPaletteEntry] {
        EditorMode.allCases.map { mode in
            CommandPaletteEntry(
                id: "mode:\(mode.id)",
                kind: .editor,
                title: "Show \(mode.rawValue)",
                subtitle: "Editor Mode",
                detail: mode.keyboardShortcutDescription,
                systemImage: mode.systemImage,
                keywords: ["editor", "view", mode.rawValue],
                action: .selectEditorMode(mode)
            )
        }
    }

    private static func symbolEntries(
        functions: [FunctionSummary],
        addressOverrides: [UInt64: AddressOverride] = [:]
    ) -> [CommandPaletteEntry] {
        functions.map { function in
            let displayName = addressOverrides[function.startAddress]?.customName ?? function.name
            // The custom name is the title (searchable); keep the parsed name in
            // keywords so a renamed function is still findable by its original
            // symbol — muscle memory keeps working after a rename.
            var keywords = ["symbol", "function", function.startAddress.hexAddress, function.name]
            if displayName != function.name {
                keywords.append(displayName)
            }
            return CommandPaletteEntry(
                id: "symbol:\(function.id.uuidString)",
                kind: .symbol,
                title: displayName,
                subtitle: function.startAddress.hexAddress,
                detail: "Symbol",
                systemImage: "function",
                keywords: keywords,
                action: .selectFunction(function.id)
            )
        }
    }
}

func parseHexAddress(_ value: String) -> UInt64? {
    var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.lowercased().hasPrefix("0x") {
        cleaned.removeFirst(2)
    }
    cleaned = cleaned.replacingOccurrences(of: "_", with: "")
    guard !cleaned.isEmpty else { return nil }
    return UInt64(cleaned, radix: 16)
}
