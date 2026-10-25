import SwiftUI
import LumenTokens

// Editors: the key/value card with
// type chips, predicate rows, the ticked slider, and quiet pull-down capsules.

// MARK: Pop-up chrome

/// The bordered pop-up look of `LumenPopUp` and `LumenInheritedPicker`, for menus whose label Lumen draws.
public struct LumenPopUpLabel: View {
    let title: String
    var symbol: String? = nil
    var width: CGFloat? = nil

    /// - Parameters:
    ///   - symbol: a glyph before the title, in the accent.
    ///   - width: a fixed width; `nil` fits the title.
    public init(_ title: String, symbol: String? = nil, width: CGFloat? = nil) {
        self.title = title
        self.symbol = symbol
        self.width = width
    }

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            if let symbol { LumenSymbol(symbol).font(.system(size: metrics.iconSize.xsmall, weight: .semibold)).foregroundStyle(palette[.accent]) }
            Text(title).foregroundStyle(palette[.fgPrimary]).lineLimit(1).lumenNeverTruncates(title)
            Spacer(minLength: metrics.spacing.s1)
            LumenSymbol("chevron.up.chevron.down").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)).foregroundStyle(palette[.fgTertiary])
                .accessibilityHidden(true)
        }
        .font(metrics.typography.body)
        .padding(.horizontal, metrics.spacing.s4)
        .frame(width: width, height: metrics.layout.controlHeight)
        .lumenChrome(.popUp)
    }
}

// MARK: Field input

/// The text inside every Lumen field: its prompt drawn by Lumen (tail-truncated and reported to the
/// truncation checks, in the proportional face even in a code field; AppKit's placeholder clips
/// mid-word), and a plain `TextField` live or the text offscreen. The owner applies
/// `.lumenChrome(.field, focused:)` with the same focus binding, so every field shows focus.
struct LumenFieldInput: View {
    @Binding var text: String
    var prompt: String = ""
    var font: Font? = nil
    var ink: LumenToken = .fgPrimary
    let focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty && !prompt.isEmpty {
                Text(prompt)
                    .font(metrics.typography.body)
                    .foregroundStyle(palette[.fgTertiary])
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .lumenNeverTruncates(prompt)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if rendersOffscreen {
                Text(text).font(font ?? metrics.typography.body).foregroundStyle(palette[ink]).lineLimit(1)
            } else {
                TextField(prompt, text: $text, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .font(font ?? metrics.typography.body)
                    .foregroundStyle(palette[ink])
                    .focused(focus)
                    .onSubmit(onSubmit)
            }
        }
        .lineLimit(1)
    }
}

/// A one-of-many choice in Lumen's pop-up look, opening a native menu with a check on the current
/// value. Use it where a themed pop-up should match Lumen's fields rather than the system's.
public struct LumenPopUp<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var width: CGFloat? = nil
    var sizingTitles: [String]? = nil

    /// - Parameter width: the least width; `nil` sizes to the widest option. The pop-up is never
    ///   narrower than its widest option, so no choice is ever cut short.
    public init(selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String, width: CGFloat? = nil) {
        _selection = selection
        self.options = options
        self.title = title
        self.width = width
    }

    /// Sized to the widest of `sizingTitles` (and its own options), so pop-ups in a column line up
    /// even when each row offers different options.
    init(selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String, sizingTitles: [String]) {
        self.init(selection: selection, options: options, title: title)
        self.sizingTitles = sizingTitles
    }

    private var label: some View {
        // Every option's label laid out hidden, so the pop-up takes the widest one's width.
        ZStack(alignment: .leading) {
            ForEach(Array(Set((sizingTitles ?? []) + options.map(title))).sorted(), id: \.self) { candidate in
                LumenPopUpLabel(candidate).hidden()
            }
            LumenPopUpLabel(title(selection)).frame(maxWidth: .infinity)
        }
        .fixedSize()
        .frame(minWidth: width)
    }

    public var body: some View {
        LumenMenuButton {
            // An inline picker, so the menu checks the current value in its state column (an image
            // in the item's image slot shifted the checked title off the others).
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in Text(title(option)).tag(option) }
            } label: { EmptyView() }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: { label }
    }
}

// MARK: Pull-down button

/// A glyph and a small chevron in a quiet capsule that opens an action menu. For a section header inside the menu, use `Section("Title") { … }`.
/// `showsTitle` adds the title after the glyph where a bare glyph wouldn't say enough.
public struct LumenPullDownButton<MenuContent: View>: View {
    private let title: String
    private let systemImage: String
    private let menu: MenuContent
    private var showsTitle = false

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameter title: the help tag and spoken name ("Add", "Actions").
    public init(_ title: String, systemImage: String, @ViewBuilder menu: () -> MenuContent) {
        self.title = title
        self.systemImage = systemImage
        self.menu = menu()
    }

    /// - Parameter showsTitle: show the title after the glyph ("+ Add ⌄"), not only as help.
    public init(_ title: String, systemImage: String, showsTitle: Bool, @ViewBuilder menu: () -> MenuContent) {
        self.init(title, systemImage: systemImage, menu: menu)
        self.showsTitle = showsTitle
    }

    private var label: some View {
        HStack(spacing: metrics.spacing.s2) {
            LumenSymbol(systemImage).font(.system(size: metrics.iconSize.small, weight: .semibold))
            if showsTitle {
                Text(title).font(metrics.typography.body).lineLimit(1).lumenNeverTruncates(title)
            }
            LumenSymbol("chevron.down").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)).accessibilityHidden(true)
        }
        .foregroundStyle(palette[.fgSecondary])
        .padding(.horizontal, metrics.spacing.s4)
        .frame(height: metrics.layout.controlHeight)
        .lumenChrome(.popUp)
    }

    public var body: some View {
        LumenMenuButton(help: title) { menu } label: { label }
            .accessibilityLabel(title)
    }
}

// MARK: Slider

/// A slider in the theme, with optional ticks, end labels ("Off" … "120") and a linked value field
/// with its unit. Drag or click the track; values snap to `step`.
public struct LumenSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let ticks: Int
    private let endLabels: (String, String)?
    private let showsField: Bool
    private let unit: String?
    private let width: CGFloat

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var fieldFocused: Bool

    /// - Parameters:
    ///   - ticks: dots under the track, ends included; 0 for none.
    ///   - endLabels: words under the ends, such as ("Off", "120").
    ///   - showsField: a field after the slider that shows and sets the value.
    ///   - unit: quiet text after the field ("sec", "%").
    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, ticks: Int = 0,
                endLabels: (String, String)? = nil, showsField: Bool = false, unit: String? = nil, width: CGFloat = 180) {
        _value = value
        self.range = range
        self.step = step
        self.ticks = ticks
        self.endLabels = endLabels
        self.showsField = showsField
        self.unit = unit
        self.width = width
    }

    /// The value at a fraction of the track, clamped and snapped to `step`.
    static func value(at fraction: Double, in range: ClosedRange<Double>, step: Double?) -> Double {
        let raw = range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
        return LumenStepping.snapped(raw, in: range, step: step)
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
    }

    public var body: some View {
        HStack(alignment: .top, spacing: metrics.spacing.s4) {
            VStack(spacing: metrics.spacing.s2) {
                track
                if let endLabels {
                    // Each end label is centered on its end of the track, where the first and last
                    // ticks and the thumb's center sit.
                    let inset = metrics.layout.sliderThumb / 2
                    ZStack {
                        Text(endLabels.0)
                            .alignmentGuide(.leading) { $0[HorizontalAlignment.center] - inset }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(endLabels.1)
                            .alignmentGuide(.trailing) { $0[HorizontalAlignment.center] + inset }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(metrics.typography.caption)
                    .foregroundStyle(palette[.fgTertiary])
                }
            }
            .frame(width: width)
            if showsField {
                field
                if let unit {
                    // One unit style, the number field's: caption in fg.tertiary.
                    Text(unit).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary]).frame(height: metrics.layout.controlHeight)
                }
            }
        }
        .lumenDisabledFade(isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Self.format(value) + (unit.map { " " + $0 } ?? ""))
        .accessibilityAdjustableAction { direction in
            let delta = step ?? (range.upperBound - range.lowerBound) / 20
            value = LumenStepping.snapped(value + (direction == .increment ? delta : -delta), in: range, step: step)
        }
    }

    private var track: some View {
        GeometryReader { proxy in
            let length = proxy.size.width
            let thumb = metrics.layout.sliderThumb
            let tick: CGFloat = 3
            ZStack(alignment: .leading) {
                Capsule().fill(palette[.bgInset]).frame(height: 4)
                    .overlay { Capsule(style: .circular).strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline) }
                Capsule().fill(palette[.accent]).frame(width: max(4, length * fraction), height: 4)
                if ticks > 1 {
                    HStack(spacing: 0) {
                        ForEach(0..<ticks, id: \.self) { index in
                            Circle().fill(palette[.fgTertiary]).frame(width: tick, height: tick)
                            if index < ticks - 1 { Spacer(minLength: 0) }
                        }
                    }
                    .padding(.horizontal, (thumb - tick) / 2)   // dot centers on the thumb's center at each end
                    .offset(y: thumb / 2 + 1)
                }
                // Drawn from tokens with a control edge, and no shadow (§7: the one shadow is
                // `LumenElevation`).
                Circle().fill(palette[.bgElevated])
                    .frame(width: thumb, height: thumb)
                    .overlay { Circle().strokeBorder(palette[.borderControl], lineWidth: metrics.stroke.hairline) }
                    .offset(x: (length - thumb) * fraction)
            }
            .frame(height: thumb + 4)
            // The pointer target is the full hit height (24 pt), wider than the drawn track.
            .frame(height: hitHeight)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard isEnabled, length > thumb else { return }
                value = Self.value(at: (drag.location.x - thumb / 2) / (length - thumb), in: range, step: step)
            })
        }
        .frame(height: hitHeight)
        // Laid out at the drawn height: the extra target overhangs, so the slider's size is unchanged.
        .padding(.vertical, -(hitHeight - metrics.layout.sliderThumb - 4) / 2)
    }

    /// The track's pointer target: the drawn track, or `minimumHitTarget` when that's taller.
    private var hitHeight: CGFloat { max(metrics.layout.sliderThumb + 4, metrics.layout.minimumHitTarget) }

    /// A typed value, clamped and snapped to `step` like the track.
    static func typed(_ typed: Double, in range: ClosedRange<Double>, step: Double?) -> Double {
        LumenStepping.snapped(typed, in: range, step: step)
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private var field: some View {
        Group {
            if rendersOffscreen {
                Text(Self.format(value))
            } else {
                // A typed value lands on the track's grid, as a drag does.
                TextField("Value", value: Binding(get: { value }, set: { value = Self.typed($0, in: range, step: step) }),
                          format: .number, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
            }
        }
        .font(metrics.typography.body)
        .foregroundStyle(palette[.fgPrimary])
        .lineLimit(1)
        .padding(.horizontal, metrics.layout.fieldInset)
        .frame(width: 48, height: metrics.layout.controlHeight, alignment: .leading)
        .lumenChrome(.field, focused: fieldFocused)
    }
}

// MARK: Text field

/// A one-line text field in Lumen's field chrome: `bg.elevated` (the raised well on a raised ground
/// in dark) with a `border.default` hairline that
/// turns `border.focus` while editing, so a focused field shows the theme's accent rather than the
/// system's ring. Use it for inspector and form fields an app draws itself. Keep prompts short
/// (examples belong in a help tag): a prompt too long for the field ends in an ellipsis and is
/// reported to the truncation checks.
public struct LumenTextField: View {
    @Binding private var text: String
    private let prompt: String
    private let monospaced: Bool
    private let onSubmit: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameters:
    ///   - prompt: shown in quiet text while the field is empty.
    ///   - monospaced: use the code font, for addresses, offsets and paths.
    ///   - onSubmit: runs on Return.
    public init(_ prompt: String = "", text: Binding<String>, monospaced: Bool = false, onSubmit: @escaping () -> Void = {}) {
        self.prompt = prompt
        _text = text
        self.monospaced = monospaced
        self.onSubmit = onSubmit
    }

    public var body: some View {
        LumenFieldInput(text: $text, prompt: prompt,
                        font: monospaced ? (codeFont ?? .standard).font(sizeDelta: -1) : metrics.typography.body,
                        focus: $isFocused, onSubmit: onSubmit)
            .padding(.horizontal, metrics.layout.fieldInset)
            .frame(maxWidth: .infinity, minHeight: metrics.layout.controlHeight, alignment: .leading)
            .lumenChrome(.field, focused: isFocused)
            .lumenDisabledFade(isEnabled)
    }
}

// MARK: Combo field

/// A field you can type in or fill from a list:
/// the chevron opens the suggestions; typing keeps any value.
public struct LumenComboField: View {
    @Binding private var text: String
    private let suggestions: [String]
    private let prompt: String
    private let monospaced: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - suggestions: what the chevron offers; picking one replaces the text.
    ///   - prompt: shown in quiet text while the field is empty.
    ///   - monospaced: use the code font, for terminal types, paths and identifiers.
    public init(text: Binding<String>, suggestions: [String], prompt: String = "", monospaced: Bool = false) {
        _text = text
        self.suggestions = suggestions
        self.prompt = prompt
        self.monospaced = monospaced
    }

    private var font: Font { monospaced ? (codeFont ?? .standard).font(sizeDelta: -1) : metrics.typography.body }

    public var body: some View {
        HStack(spacing: 0) {
            LumenFieldInput(text: $text, prompt: prompt, font: font, focus: $isFocused)
                .padding(.horizontal, metrics.layout.fieldInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            LumenInlineDivider()
            chevron
        }
        .frame(height: metrics.layout.controlHeight)
        .lumenChrome(.field, focused: isFocused)
        .lumenDisabledFade(isEnabled)
    }

    private var chevron: some View {
        LumenMenuButton(help: "Suggestions") {
            // Checked in the menu's state column when the text is one of the suggestions.
            Picker(selection: $text) {
                ForEach(suggestions, id: \.self) { suggestion in Text(suggestion).tag(suggestion) }
            } label: { EmptyView() }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            LumenSymbol("chevron.down").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold))
                .foregroundStyle(palette[.fgSecondary])
                .frame(width: metrics.layout.controlHeight, height: metrics.layout.controlHeight)
                .contentShape(.rect)
        }
        .accessibilityLabel("Suggestions")
    }
}

// MARK: Key/value editor

/// A JSON-style value type, for typed key/value settings.
public enum LumenValueType: String, CaseIterable, Sendable, Hashable {
    case array, boolean, null, number, object, string

    public var title: String { rawValue.capitalized }

    public var systemImage: String {
        switch self {
        case .array: "list.number"
        case .boolean: "circle.righthalf.filled"
        case .null: "parentheses"
        case .number: "number"
        case .object: "ellipsis.curlybraces"
        case .string: "quote.opening"
        }
    }
}

/// One entry of a `LumenKeyValueEditor`.
public struct LumenKeyValue: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var key: String
    public var value: String
    /// `nil` for untyped editors (environment variables).
    public var type: LumenValueType?

    public init(key: String, value: String, type: LumenValueType? = nil, id: UUID = UUID()) {
        self.id = id
        self.key = key
        self.value = value
        self.type = type
    }

    /// A key not yet in `entries`: "key1", "key2"…
    static func newKey(among entries: [LumenKeyValue]) -> String {
        let taken = Set(entries.map(\.key))
        var index = 1
        while taken.contains("key\(index)") { index += 1 }
        return "key\(index)"
    }
}

/// Keys and values on a `LumenTable` card: the selected row's cells become fields, and
/// in a typed editor the type shows as a tinted chip that opens the type menu. + adds a "key1" row
/// and selects it; − removes the selection; the trailing action can restore defaults.
public struct LumenKeyValueEditor: View {
    @Binding private var entries: [LumenKeyValue]
    private let typed: Bool
    private let emptyMessage: String
    private let onRestoreDefaults: (() -> Void)?
    @State private var selection: UUID?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameters:
    ///   - typed: show a type for each value (language-server settings); off for plain pairs.
    ///   - onRestoreDefaults: shows "Restore Defaults" in the footer.
    public init(entries: Binding<[LumenKeyValue]>, typed: Bool = false, emptyMessage: String = "No values",
                onRestoreDefaults: (() -> Void)? = nil) {
        _entries = entries
        self.typed = typed
        self.emptyMessage = emptyMessage
        self.onRestoreDefaults = onRestoreDefaults
    }

    /// For golden images: a selection to draw.
    init(entries: Binding<[LumenKeyValue]>, typed: Bool, emptyMessage: String, selection: UUID?) {
        self.init(entries: entries, typed: typed, emptyMessage: emptyMessage)
        _selection = State(initialValue: selection)
    }

    public var body: some View {
        var columns: [LumenTableColumn<LumenKeyValue>] = [
            LumenTableColumn("Key", width: 150) { entry in cell(entry, \.key) },
            LumenTableColumn("Value") { entry in cell(entry, \.value) },
        ]
        if typed {
            columns.append(LumenTableColumn("Type", width: 92) { entry in typeChip(entry) })
        }
        return LumenTable(entries, selection: $selection, emptyMessage: emptyMessage,
                          footer: LumenTableFooter(onAdd: add, onRemove: remove,
                                                   trailing: onRestoreDefaults.map { ("Restore Defaults", $0) }),
                          minHeight: 44, columns: columns)
    }

    private var mono: Font { (codeFont ?? .standard).font(sizeDelta: -1) }

    private func binding(for id: UUID, _ path: WritableKeyPath<LumenKeyValue, String>) -> Binding<String> {
        Binding(get: { entries.first { $0.id == id }?[keyPath: path] ?? "" },
                set: { newValue in if let index = entries.firstIndex(where: { $0.id == id }) { entries[index][keyPath: path] = newValue } })
    }

    // Cells and chips are views of their own, so they read the palette inside the table's card
    // (its raised ground), not the one outside it: a captured `palette` drew them as holes.
    @ViewBuilder private func cell(_ entry: LumenKeyValue, _ path: WritableKeyPath<LumenKeyValue, String>) -> some View {
        KeyValueCell(text: binding(for: entry.id, path), isEditing: entry.id == selection, isKey: path == \.key, font: mono)
    }

    @ViewBuilder private func typeChip(_ entry: LumenKeyValue) -> some View {
        let type = entry.type ?? .string
        LumenMenuButton(help: "Value type") {
            ForEach(LumenValueType.allCases, id: \.self) { option in
                Button { setType(option, for: entry.id) } label: { Label(option.title, systemImage: option.systemImage) }
            }
        } label: { KeyValueTypeChip(type: type) }
    }

    /// A key or value: a field in the selected row (its well drawn offscreen too, so golden images
    /// show it), text elsewhere.
    private struct KeyValueCell: View {
        @Binding var text: String
        let isEditing: Bool
        let isKey: Bool
        let font: Font
        @FocusState private var focused: Bool
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics

        var body: some View {
            if isEditing {
                LumenFieldInput(text: $text, font: font, focus: $focused)
                    .padding(.horizontal, metrics.layout.fieldInset)
                    .frame(maxWidth: .infinity, minHeight: metrics.layout.controlHeight - 2, maxHeight: metrics.layout.controlHeight - 2,
                           alignment: .leading)
                    .lumenChrome(.field, focused: focused)
            } else {
                Text(text)
                    .font(font)
                    .foregroundStyle(palette[isKey ? .fgPrimary : .fgSecondary])
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// A value's type, as a neutral chip: a type is a fact about the value, not a selection.
    private struct KeyValueTypeChip: View {
        let type: LumenValueType
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics

        var body: some View {
            HStack(spacing: metrics.spacing.s1) {
                LumenSymbol(type.systemImage).font(.system(size: metrics.iconSize.xsmall - 1, weight: .bold))
                Text(type.title).font(metrics.typography.captionEmphasized)
            }
            .foregroundStyle(palette[.fgSecondary])
            .lumenChip(palette[.bgInset])   // the one chip spec
        }
    }

    private func setType(_ type: LumenValueType, for id: UUID) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].type = type }
    }

    private func add() {
        let entry = LumenKeyValue(key: LumenKeyValue.newKey(among: entries), value: "", type: typed ? .string : nil)
        entries.append(entry)
        selection = entry.id
    }

    private func remove() {
        guard let selection else { return }
        entries.removeAll { $0.id == selection }
        self.selection = nil
    }
}

// MARK: Rule editor

/// How a rule's conditions combine.
public enum LumenRuleMatch: String, CaseIterable, Sendable, Hashable {
    case any, all, none

    public var title: String { rawValue.capitalized }
}

/// One condition: a field, an operator and a value ("Name" "is" ".git").
public struct LumenRuleCondition: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var field: String
    public var comparison: String
    public var value: String

    public init(field: String, comparison: String, value: String = "", id: UUID = UUID()) {
        self.id = id
        self.field = field
        self.comparison = comparison
        self.value = value
    }
}

/// Conditions as predicate rows: "[Any] of the following are true"
/// over rows of [field] [operator] [value] − +. + adds a condition after its row; − removes it (the
/// last one stays).
public struct LumenRuleEditor: View {
    @Binding private var match: LumenRuleMatch
    @Binding private var conditions: [LumenRuleCondition]
    private let fields: [String]
    private let comparisons: (String) -> [String]

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameter comparisons: the operators a field offers ("is", "contains", "greater than").
    public init(match: Binding<LumenRuleMatch>, conditions: Binding<[LumenRuleCondition]>, fields: [String],
                comparisons: @escaping (String) -> [String]) {
        _match = match
        _conditions = conditions
        self.fields = fields
        self.comparisons = comparisons
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s4) {
            HStack(spacing: metrics.spacing.s3) {
                LumenPopUp(selection: $match, options: LumenRuleMatch.allCases, title: \.title)
                Text("of the following are true").font(metrics.typography.body).foregroundStyle(palette[.fgPrimary])
                Spacer(minLength: metrics.spacing.s4)
                rowButton("plus", "Add Condition") { insert(after: conditions.last?.id) }
            }
            ForEach(conditions) { condition in
                HStack(spacing: metrics.spacing.s3) {
                    LumenPopUp(selection: bind(condition.id, \.field, fallback: fields.first ?? ""), options: fields, title: { $0 })
                    // Sized to the widest operator of every field, so value fields line up row to row.
                    LumenPopUp(selection: bind(condition.id, \.comparison, fallback: ""), options: comparisons(condition.field),
                               title: { $0 }, sizingTitles: fields.flatMap(comparisons))
                    valueField(condition)
                    rowButton("minus", "Remove Condition") { remove(condition.id) }
                        .disabled(conditions.count < 2)
                    rowButton("plus", "Add Condition") { insert(after: condition.id) }
                }
                .padding(.leading, metrics.spacing.s6)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func bind(_ id: UUID, _ path: WritableKeyPath<LumenRuleCondition, String>, fallback: String) -> Binding<String> {
        Binding(get: { conditions.first { $0.id == id }?[keyPath: path] ?? fallback },
                set: { newValue in
                    guard let index = conditions.firstIndex(where: { $0.id == id }) else { return }
                    conditions[index][keyPath: path] = newValue
                    if path == \.field, !comparisons(newValue).contains(conditions[index].comparison) {
                        conditions[index].comparison = comparisons(newValue).first ?? ""
                    }
                })
    }

    private func valueField(_ condition: LumenRuleCondition) -> some View {
        RuleValueField(text: bind(condition.id, \.value, fallback: ""))
    }

    /// A condition's value, focused like every Lumen field.
    private struct RuleValueField: View {
        @Binding var text: String
        @FocusState private var focused: Bool
        @Environment(\.lumenMetrics) private var metrics

        var body: some View {
            LumenFieldInput(text: $text, focus: $focused)
                .padding(.horizontal, metrics.layout.fieldInset)
                .frame(maxWidth: .infinity, minHeight: metrics.layout.controlHeight, alignment: .leading)
                .lumenChrome(.field, focused: focused)
        }
    }

    private func rowButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        LumenGlyphButton(systemImage: symbol, title: title, action: action)
    }

    /// A new condition on the first field, after `id` (or at the end).
    static func inserting(after id: UUID?, into conditions: [LumenRuleCondition], field: String, comparison: String) -> [LumenRuleCondition] {
        var result = conditions
        let condition = LumenRuleCondition(field: field, comparison: comparison)
        if let id, let index = result.firstIndex(where: { $0.id == id }) {
            result.insert(condition, at: index + 1)
        } else {
            result.append(condition)
        }
        return result
    }

    private func insert(after id: UUID?) {
        let field = fields.first ?? ""
        conditions = Self.inserting(after: id, into: conditions, field: field, comparison: comparisons(field).first ?? "")
    }

    private func remove(_ id: UUID) {
        guard conditions.count > 1 else { return }
        conditions.removeAll { $0.id == id }
    }
}
