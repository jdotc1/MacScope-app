import AppKit
import SwiftUI
import LumenTokens

// Settings and form controls: a themed checkbox, number fields, controls
// inside sentences, checkbox grids, inherited values, cards of integration rows, editable lists and
// master-detail panes.

// MARK: Checkbox

/// A checkbox drawn in the theme: a filled-accent square (`accent.filled`) with a white check when
/// on, a `border.control` square when off.
/// Click the box or its label. Use it where native checkboxes would clash with a themed pane.
public struct LumenCheckboxStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s3) {
                    LumenCheckboxBox(state: configuration.isOn)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    configuration.label.foregroundStyle(palette[.fgPrimary])
                }
                .contentShape(.rect)
            }
            .buttonStyle(.lumenBare)
            .lumenDisabledFade(isEnabled)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

public extension ToggleStyle where Self == LumenCheckboxStyle {
    static var lumenCheckbox: LumenCheckboxStyle { LumenCheckboxStyle() }
}

// MARK: Number field

/// The value grid shared by number fields and sliders: steps counted from the range's lower bound,
/// then clamped to the range, so a field, a track and a typed value all land on the same values.
enum LumenStepping {
    /// `raw` on the grid `lowerBound + n × step`, clamped to `range`; `raw` clamped when there's no step.
    static func snapped(_ raw: Double, in range: ClosedRange<Double>, step: Double?) -> Double {
        guard let step, step > 0 else { return min(max(raw, range.lowerBound), range.upperBound) }
        let stepped = range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// The whole-number grid, in integer arithmetic: exact across all of `Int`, and never traps.
    static func snapped(_ raw: Int, in range: ClosedRange<Int>, step: Int) -> Int {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        guard step > 1 else { return clamped }
        // Distances from the lower bound fit in UInt even when the Int subtraction would overflow.
        let offset = UInt(bitPattern: clamped &- range.lowerBound)
        let span = UInt(bitPattern: range.upperBound &- range.lowerBound)
        let stride = UInt(step), remainder = offset % stride
        var snapped = offset - remainder
        // Half rounds up; a step past the top clamps to the top, as the Double grid does.
        if remainder >= stride - remainder { snapped = span - snapped >= stride ? snapped + stride : span }
        return range.lowerBound &+ Int(bitPattern: snapped)
    }
}

/// A number with a stepper and its unit: type a value or step it, clamped to `range`
/// and rounded to `step` (counted from the range's lower bound, as `LumenSlider` counts).
/// "1.5 × font size", "500 KB/s", "5 files".
public struct LumenNumberField: View {
    /// How the value is read, set and stepped: in `Double`, or exactly in `Int` for whole numbers.
    private let model: Model
    private let unit: String?
    private let width: CGFloat

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.isEnabled) private var isEnabled
    @State private var text = ""
    @FocusState private var focused: Bool

    /// - Parameters:
    ///   - fractionDigits: decimals shown; 0 for whole numbers.
    ///   - unit: shown after the stepper, in quiet text.
    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, fractionDigits: Int = 0,
                unit: String? = nil, width: CGFloat = 52) {
        let formatted = { (number: Double) in number.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never)) }
        model = Model(
            text: { formatted(value.wrappedValue) },
            commit: { text in
                if let parsed = Self.normalized(Self.parse(text), range: range, step: step) { value.wrappedValue = parsed }
            },
            nudge: { direction in
                value.wrappedValue = Self.normalized(value.wrappedValue + Double(direction) * step, range: range, step: step) ?? value.wrappedValue
            },
            atLowerBound: { value.wrappedValue <= range.lowerBound },
            atUpperBound: { value.wrappedValue >= range.upperBound })
        self.unit = unit
        self.width = width
    }

    /// Whole numbers, in integer arithmetic: exact across all of `Int` (no trip through `Double`).
    public init(value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, unit: String? = nil, width: CGFloat = 52) {
        model = Model(
            text: { String(value.wrappedValue) },
            commit: { text in
                if let parsed = Self.normalized(text, range: range, step: step) { value.wrappedValue = parsed }
            },
            nudge: { value.wrappedValue = Self.nudged(value.wrappedValue, by: $0, range: range, step: step) },
            atLowerBound: { value.wrappedValue <= range.lowerBound },
            atUpperBound: { value.wrappedValue >= range.upperBound })
        self.unit = unit
        self.width = width
    }

    /// `raw` clamped to the range and rounded to the step; `nil` when it isn't a number.
    static func normalized(_ raw: Double?, range: ClosedRange<Double>, step: Double) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        return LumenStepping.snapped(raw, in: range, step: step)
    }

    /// Typed text as a whole number in `range` on the step; a typed fraction rounds. `nil` when it
    /// isn't a number.
    static func normalized(_ text: String, range: ClosedRange<Int>, step: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let whole = Int(trimmed) { return LumenStepping.snapped(whole, in: range, step: step) }
        guard let number = parse(trimmed), number.isFinite else { return nil }
        // Past ±2⁶³ there is no Int to convert to: those are the range's ends.
        let whole: Int = number >= 0x1p63 ? .max : number < -0x1p63 ? .min : Int(number.rounded())
        return LumenStepping.snapped(whole, in: range, step: step)
    }

    /// `value` one step up (`direction` 1) or down (-1), on the grid and in the range; never overflows.
    static func nudged(_ value: Int, by direction: Int, range: ClosedRange<Int>, step: Int) -> Int {
        let (moved, overflow) = value.addingReportingOverflow(direction * max(step, 1))
        return LumenStepping.snapped(overflow ? (direction > 0 ? .max : .min) : moved, in: range, step: step)
    }

    private static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private struct Model {
        let text: () -> String
        let commit: (String) -> Void
        let nudge: (Int) -> Void
        let atLowerBound: () -> Bool
        let atUpperBound: () -> Bool
    }

    private func commit() {
        model.commit(text)
        text = model.text()
    }

    private func nudge(_ direction: Int) {
        model.nudge(direction)
        text = model.text()
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s1) {
            Group {
                if rendersOffscreen {
                    Text(model.text())
                } else {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                        .onKeyPress(.upArrow) { nudge(1); return .handled }
                        .onKeyPress(.downArrow) { nudge(-1); return .handled }
                }
            }
            .font(metrics.typography.body.monospacedDigit())
            .foregroundStyle(palette[.fgPrimary])
            .padding(.horizontal, metrics.layout.fieldInset)
            .frame(width: width, height: metrics.layout.controlHeight, alignment: .trailing)
            .lumenChrome(.field, focused: focused)
            // The stepper is a pop-up-style plate with a hairline between its halves, so it reads as
            // one control with two ends rather than two bare chevrons.
            VStack(spacing: 0) {
                stepButton("chevron.up", "Increase") { nudge(1) }.disabled(model.atUpperBound())
                Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline).padding(.horizontal, 3)
                stepButton("chevron.down", "Decrease") { nudge(-1) }.disabled(model.atLowerBound())
            }
            .frame(width: Self.stepperWidth, height: metrics.layout.controlHeight)
            .lumenChrome(.popUp)
            if let unit {
                Text(unit).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary]).fixedSize()
            }
        }
        // The value's baseline, so a sentence's words line up with the number rather than with the
        // stepper's chevrons (the stack otherwise reported a baseline ~7 pt too high).
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + Self.bodyBaselineBelowCenter }
        .lumenDisabledFade(isEnabled)
        .onAppear { text = model.text() }
        .onChange(of: model.text()) { _, new in if !focused { text = new } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unit ?? "Value")
        .accessibilityValue(model.text())
        .accessibilityAdjustableAction { direction in nudge(direction == .increment ? 1 : -1) }
    }

    /// How far below a centered line of body text its baseline sits: (ascender + descender) / 2.
    nonisolated static var bodyBaselineBelowCenter: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .body)
        return ((font.ascender + font.descender) / 2).rounded()
    }

    static let stepperWidth: CGFloat = 15

    private func stepButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        StepButton(symbol: symbol, title: title, action: action)
    }

    /// One half of the stepper: dims on its own when it can't step further.
    private struct StepButton: View {
        let symbol: String
        let title: String
        let action: () -> Void
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(action: action) {
                LumenSymbol(symbol).font(.system(size: metrics.layout.disclosureGlyph - 1, weight: .bold)).foregroundStyle(palette[.fgSecondary])
                    // Each half is half the control height, so the pair is one control-height hit area.
                    .frame(width: LumenNumberField.stepperWidth, height: max(metrics.layout.controlHeight, metrics.layout.minimumHitTarget) / 2 - 1)
                    .contentShape(.rect)
            }
            .buttonStyle(.lumenBare)
            .lumenDisabledFade(isEnabled)
            .help(title)
        }
    }
}

// MARK: Sentences

/// Lays children out left to right, wrapping to a new line when the next one doesn't fit, with
/// baselines aligned on each line. For sentence controls and tag clouds.
public struct LumenFlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let height = lines.reduce(0) { $0 + $1.height } + CGFloat(max(lines.count - 1, 0)) * lineSpacing
        // The true widest line: children are fitted to the line, so this exceeds the proposal only
        // when one can't shrink (a fixed-size word), and the column-overflow check then sees it.
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let fitted = Self.proposal(for: subviews[index], width: bounds.width)
                let size = subviews[index].sizeThatFits(fitted)
                let baseline = subviews[index].dimensions(in: fitted)[VerticalAlignment.firstTextBaseline]
                subviews[index].place(at: CGPoint(x: x, y: y + line.baseline - baseline), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    /// A child at its ideal size, or at the line's width when it's wider than a whole line: it then
    /// wraps or truncates inside the layout instead of running past its edge unseen.
    private static func proposal(for subview: LayoutSubview, width: CGFloat) -> ProposedViewSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return ideal.width > width && width.isFinite ? ProposedViewSize(width: width, height: nil) : .unspecified
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var baseline: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        var descent: CGFloat = 0
        for index in subviews.indices {
            let fitted = Self.proposal(for: subviews[index], width: width)
            let size = subviews[index].sizeThatFits(fitted)
            let baseline = subviews[index].dimensions(in: fitted)[VerticalAlignment.firstTextBaseline]
            let added = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if added > width, !line.indices.isEmpty {
                lines.append(line)
                line = Line()
                descent = 0
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.indices.append(index)
            line.baseline = max(line.baseline, baseline)
            descent = max(descent, size.height - baseline)
            line.height = line.baseline + descent
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

/// A setting phrased as a sentence with its controls inline. With `isOn`, a checkbox leads and the rest dims until it's on. Words
/// and controls wrap as one sentence in a narrow pane.
public struct LumenSentenceRow<Content: View>: View {
    private let isOn: Binding<Bool>?
    private let label: String
    private let content: Content

    @Environment(\.lumenMetrics) private var metrics

    /// - Parameters:
    ///   - isOn: the leading checkbox, which enables the rest; `nil` for none.
    ///   - label: what VoiceOver reads for the checkbox.
    public init(isOn: Binding<Bool>? = nil, label: String = "", @ViewBuilder content: () -> Content) {
        self.isOn = isOn
        self.label = label
        self.content = content()
    }

    public var body: some View {
        // The checkbox's own box-to-label gap (s3), so the sentence starts where checkbox labels do.
        HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s3) {
            if let isOn {
                // The sentence is the label: an empty one here, so the words don't repeat.
                // The stack's s3 is the whole gap: an extra 2 pt put the words right of a plain
                // checkbox's label and of a dependent group's rows (LIVE-14).
                Toggle(isOn: isOn) { EmptyView() }.toggleStyle(.lumenCheckbox)
                    .accessibilityLabel(label)
            }
            // Only the sentence dims while off; its checkbox, the one way to turn it on, stays at
            // full strength. Controls inside count this fade toward their own, so they don't dim twice.
            LumenFlowLayout(spacing: metrics.spacing.s2) { content }
                .font(metrics.typography.body)
                .disabled(!(isOn?.wrappedValue ?? true))
                .lumenDisabledFade(isOn?.wrappedValue ?? true)
        }
        .padding(.vertical, metrics.spacing.s1)
    }
}

/// A word in a `LumenSentenceRow`, in the pane's text color.
public struct LumenSentenceText: View {
    private let text: String
    @Environment(\.lumenPalette) private var palette
    public init(_ text: String) { self.text = text }
    public var body: some View { Text(text).foregroundStyle(palette[.fgPrimary]).fixedSize() }
}

/// Settings that only apply when another is on, indented under it and dimmed while it's off
/// ("Hanging indent" under "Soft-wrap lines").
public struct LumenDependentGroup<Content: View>: View {
    private let isEnabled: Bool
    private let content: Content
    @Environment(\.lumenMetrics) private var metrics

    public init(enabled isEnabled: Bool, @ViewBuilder content: () -> Content) {
        self.isEnabled = isEnabled
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s2) { content }
            .padding(.leading, metrics.layout.toggleIndicator + metrics.spacing.s3)
            .disabled(!isEnabled)
            .lumenDisabledFade(isEnabled)   // controls inside count this toward their own fade
    }
}

// MARK: Checkbox grid

/// One checkbox in a `LumenCheckboxGrid`.
public struct LumenCheckboxItem: Identifiable {
    public let id: String
    public let title: String
    public let isOn: Binding<Bool>

    public init(_ title: String, isOn: Binding<Bool>) {
        id = title
        self.title = title
        self.isOn = isOn
    }
}

/// Checkboxes in columns under one label, filling down
/// each column first, as in a sentence read top to bottom.
public struct LumenCheckboxGrid: View {
    private let items: [LumenCheckboxItem]
    private let columns: Int
    @Environment(\.lumenMetrics) private var metrics

    public init(_ items: [LumenCheckboxItem], columns: Int = 2) {
        self.items = items
        self.columns = max(columns, 1)
    }

    public var body: some View {
        let perColumn = Int((Double(items.count) / Double(columns)).rounded(.up))
        HStack(alignment: .top, spacing: metrics.spacing.s6) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(alignment: .leading, spacing: metrics.spacing.s2) {
                    ForEach(items.dropFirst(column * perColumn).prefix(perColumn)) { item in
                        Toggle(item.title, isOn: item.isOn).toggleStyle(.lumenCheckbox).font(metrics.typography.body)
                    }
                }
            }
        }
    }
}

// MARK: Inherited values

/// A choice that can follow a default set elsewhere ("Global Default (HTML)", "Default
/// (Hide)"): `nil` follows the default, which the menu names; choosing a value overrides it.
public struct LumenInheritedPicker<Value: Hashable>: View {
    @Binding private var selection: Value?
    private let options: [Value]
    private let inherited: Value
    private let defaultLabel: String
    private let title: (Value) -> String

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameters:
    ///   - inherited: the value the default currently has, named in its menu item.
    ///   - defaultLabel: "Default" or "Global Default".
    public init(selection: Binding<Value?>, options: [Value], inherited: Value, defaultLabel: String = "Default",
                title: @escaping (Value) -> String) {
        _selection = selection
        self.options = options
        self.inherited = inherited
        self.defaultLabel = defaultLabel
        self.title = title
    }

    /// "Default (HTML)" for the inherited choice, otherwise the value's title.
    static func label(for selection: Value?, inherited: Value, defaultLabel: String, title: (Value) -> String) -> String {
        selection.map(title) ?? "\(defaultLabel) (\(title(inherited)))"
    }

    public var body: some View {
        let label = HStack(spacing: metrics.spacing.s1) {
            Text(Self.label(for: selection, inherited: inherited, defaultLabel: defaultLabel, title: title))
                // The inherited value reads quieter by color alone: no italic, which nothing else uses
                // in a control and which read as disabled inside a sentence.
                .foregroundStyle(palette[selection == nil ? .fgSecondary : .fgPrimary])
            LumenSymbol("chevron.up.chevron.down").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)).foregroundStyle(palette[.fgTertiary])
                .accessibilityHidden(true)
        }
        .font(metrics.typography.body)
        .padding(.horizontal, metrics.spacing.s4)
        .frame(height: metrics.layout.controlHeight)
        .lumenChrome(.popUp)
        LumenMenuButton(help: selection == nil ? "Following the default" : "Overrides the default (\(title(inherited)))") {
            Button("\(defaultLabel) (\(title(inherited)))") { selection = nil }
            Divider()
            ForEach(options, id: \.self) { option in Button(title(option)) { selection = option } }
        } label: { label }
    }
}

// MARK: Cards

/// A rounded card of settings rows with hairlines between them.
public struct LumenSettingsCard<Content: View>: View {
    private let content: Content
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        Group {
            if #available(macOS 15, *) {
                VStack(alignment: .leading, spacing: 0) {
                    Group(subviews: content) { rows in
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            row.padding(.horizontal, metrics.spacing.s4).padding(.vertical, metrics.spacing.s3)
                            if index < rows.count - 1 {
                                Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline).padding(.horizontal, metrics.spacing.s4)
                            }
                        }
                    }
                }
            } else {
                // macOS 14 can't enumerate a view's children: rows are spaced, without hairlines.
                VStack(alignment: .leading, spacing: metrics.spacing.s4) { content }
                    .padding(.horizontal, metrics.spacing.s4).padding(.vertical, metrics.spacing.s3)
            }
        }
        .lumenRaisedGround()
        .background(palette[.bgElevated], in: .rect(cornerRadius: metrics.radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius.lg, style: .continuous).strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline)
        }
    }
}

/// A round "?" that opens a short explanation in a popover.
public struct LumenHelpButton: View {
    private let message: String
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @State private var showing = false

    public init(_ message: String) { self.message = message }

    public var body: some View {
        Button { showing.toggle() } label: {
            Text("?").font(.system(size: metrics.iconSize.small, weight: .bold, design: .rounded)).foregroundStyle(palette[.fgSecondary])
                .frame(width: 20, height: 20)
                .background(palette[.bgElevated], in: .circle)
                .overlay { Circle().strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
                // A 20 pt disc in a 24 pt hit area (PRINCIPLES §7).
                .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .lumenIconOnlyControl("Help")
        .popover(isPresented: $showing) {
            Text(message).font(metrics.typography.callout).foregroundStyle(palette[.fgPrimary])
                .fixedSize(horizontal: false, vertical: true).frame(width: 260).padding()
                .lumenRaisedGround()
        }
        .help(message)
        .accessibilityLabel("Help")
        .accessibilityHint(message)
    }
}

/// An integration's state (a language server, a tool): found, missing or running.
public struct LumenIntegrationStatus: Hashable, Sendable {
    public let title: String
    public let tone: LumenToken

    public init(_ title: String, tone: LumenToken = .fgTertiary) {
        self.title = title
        self.tone = tone
    }

    public static let notFound = LumenIntegrationStatus("Not Found", tone: .fgTertiary)
    public static let running = LumenIntegrationStatus("Running", tone: .statusSuccess)
}

/// One integration in a settings card: a switch, its name and a line about
/// it, then its status, a refresh button and an info button.
public struct LumenIntegrationRow: View {
    @Binding private var isOn: Bool
    private let name: String
    private let detail: String?
    private let status: LumenIntegrationStatus
    private let onRefresh: (() -> Void)?
    private let onInfo: (() -> Void)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameters:
    ///   - isOn: whether the integration is enabled.
    ///   - detail: a second line under the name.
    ///   - status: shown at the trailing edge ("Not Found", "Running").
    public init(isOn: Binding<Bool>, name: String, detail: String? = nil, status: LumenIntegrationStatus,
                onRefresh: (() -> Void)? = nil, onInfo: (() -> Void)? = nil) {
        _isOn = isOn
        self.name = name
        self.detail = detail
        self.status = status
        self.onRefresh = onRefresh
        self.onInfo = onInfo
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s3) {
            LumenSwitch(isOn: $isOn, label: name)
            VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                Text(name).font(metrics.typography.callout.weight(.medium)).foregroundStyle(palette[.fgPrimary]).lineLimit(1)
                    .lumenNeverTruncates(name)
                if let detail {
                    Text(detail).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary]).lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: metrics.spacing.s2)
            Text(status.title).font(metrics.typography.caption).foregroundStyle(palette[status.tone]).fixedSize()
            if let onRefresh {
                Button("Check Again", systemImage: "arrow.clockwise", action: onRefresh)
                    .labelStyle(.iconOnly).buttonStyle(.lumenPanelIcon).help("Check again")
                    .lumenIconOnlyControl("Check Again")
            }
            if let onInfo {
                LumenInlineDivider()
                Button("Info", systemImage: "info.circle", action: onInfo)
                    .labelStyle(.iconOnly).buttonStyle(.lumenPanelIcon).help("About \(name)")
                    .lumenIconOnlyControl("Info")
            }
        }
        // A trailing icon button's glyph, not its 24 pt hover tile, meets the card's inset, so the
        // row's two edges sit the same distance from the card (the glyph is about callout-sized).
        .padding(.trailing, onInfo != nil || onRefresh != nil
                 ? -(metrics.layout.minimumHitTarget - metrics.layout.toolbarGlyphSize) / 2 : 0)
        .accessibilityElement(children: .contain)
    }
}

/// A switch drawn in the theme: the filled accent (`accent.filled`) track when on, a
/// `border.control` edge when off. Drawn from tokens, with no shadow (§7: the one shadow is
/// `LumenElevation`).
public struct LumenSwitch: View {
    @Binding private var isOn: Bool
    private let label: String
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init(isOn: Binding<Bool>, label: String) {
        _isOn = isOn
        self.label = label
    }

    public var body: some View {
        Button {
            withAnimation(metrics.motion.animation(metrics.motion.fastCurve, reduceMotion: reduceMotion)) { isOn.toggle() }
        } label: {
            let height = metrics.layout.switchHeight
            Capsule()
                .fill(isOn ? palette[.accentFilled] : palette[.bgInset])
                .overlay { Capsule(style: .circular).strokeBorder(palette[.borderControl], lineWidth: isOn ? 0 : metrics.stroke.hairline) }
                .overlay(alignment: isOn ? .trailing : .leading) {
                    // On: the filled accent's own foreground (white). Off: a raised knob with a control edge.
                    Circle().fill(palette[isOn ? .accentFilledForeground : .bgElevated])
                        .overlay { Circle().strokeBorder(palette[.borderControl], lineWidth: isOn ? 0 : metrics.stroke.hairline) }
                        .padding(2)
                }
                .frame(width: (height * 1.75).rounded(), height: height)
                // The 17 pt capsule in a 24 pt tall hit area (PRINCIPLES §7).
                .frame(minWidth: metrics.layout.minimumHitTarget, minHeight: metrics.layout.minimumHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.lumenBare)
        .lumenIconOnlyControl("Switch")
        .lumenDisabledFade(isEnabled)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: List editor

/// An editable list of short strings (ignored-file patterns, registries): each row selectable with ×
/// on hover to remove, and an inline Add row at the end. Return in the Add row adds;
/// duplicates and blanks are refused.
public struct LumenListEditor: View {
    @Binding private var items: [String]
    private let addPrompt: String
    private let monospaced: Bool
    private let minHeight: CGFloat

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @State private var draft = ""
    @State private var hovered: String?
    @State private var selection: String?
    @FocusState private var listFocused: Bool
    @FocusState private var addFocused: Bool

    /// - Parameters:
    ///   - addPrompt: the placeholder of the add row at the bottom.
    ///   - monospaced: use the code font, for patterns and paths.
    ///   - minHeight: the least height of the list.
    public init(items: Binding<[String]>, addPrompt: String = "Add", monospaced: Bool = false, minHeight: CGFloat = 96) {
        _items = items
        self.addPrompt = addPrompt
        self.monospaced = monospaced
        self.minHeight = minHeight
    }

    /// `items` with `draft` added, or `nil` when it's blank or already there.
    static func adding(_ draft: String, to items: [String]) -> [String]? {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !items.contains(value) else { return nil }
        return items + [value]
    }

    private var font: Font { monospaced ? (codeFont ?? .standard).font(sizeDelta: -1) : metrics.typography.body }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The rows take keyboard focus when one is clicked, so Delete removes the selection rather
            // than going to whichever field had focus.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items, id: \.self) { item in row(item) }
            }
            .focusable(!rendersOffscreen)
            .focusEffectDisabled()
            .focused($listFocused)
            .onDeleteCommand { if let selection { items.removeAll { $0 == selection }; self.selection = nil } }
            addRow
            Spacer(minLength: 0)
        }
        .padding(.vertical, metrics.spacing.s1)
        .frame(minHeight: minHeight, alignment: .top)
        .lumenRaisedGround()
        .background(palette[.bgElevated], in: .rect(cornerRadius: metrics.radius.md, style: .continuous))   // a list box is a field: white in light, a step up in dark
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius.md, style: .continuous).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline)
        }
    }

    private func row(_ item: String) -> some View {
        HStack(spacing: metrics.spacing.s2) {
            Text(item).font(font).foregroundStyle(palette[.fgPrimary]).lineLimit(1).truncationMode(.middle).help(item)
            Spacer(minLength: metrics.spacing.s2)
            Button { items.removeAll { $0 == item } } label: {
                LumenSymbol("xmark.circle.fill").font(.caption).foregroundStyle(palette[.fgTertiary])
                    .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .lumenIconOnlyControl("Remove")
            .opacity(hovered == item ? 1 : 0)
            .help("Remove")
            .accessibilityLabel("Remove \(item)")
        }
        .padding(.horizontal, metrics.spacing.s3)
        .frame(minHeight: density.rowHeight(in: metrics.layout))
        // A list's selection is the quiet navigation-list one (bg.selected), not an accent tint. The
        // list box is a raised ground (bg.elevated), so hover and the inactive selection take their
        // raised roles, hover at full strength.
        .background(selection == item ? palette.raised()[listFocused || rendersOffscreen ? .bgSelected : .bgSelectedInactive]
                    : hovered == item ? palette.raised().hoverFill(metrics) : .clear)
        .contentShape(.rect)
        .onTapGesture { selection = item; listFocused = true }
        .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        .contextMenu { Button("Remove") { items.removeAll { $0 == item } } }
    }

    private var addRow: some View {
        HStack(spacing: metrics.spacing.s2) {
            LumenSymbol("plus").font(.caption.weight(.semibold)).foregroundStyle(palette[.accent]).accessibilityHidden(true)
            if rendersOffscreen {
                Text(addPrompt).font(metrics.typography.body).foregroundStyle(palette[.fgTertiary])
                Spacer(minLength: 0)
            } else {
                TextField(addPrompt, text: $draft, prompt: Text(addPrompt).foregroundStyle(palette[.fgTertiary]))
                    .textFieldStyle(.plain)
                    .focused($addFocused)
                    .font(draft.isEmpty ? metrics.typography.body : font)
                    .onSubmit {
                        if let updated = Self.adding(draft, to: items) { items = updated; draft = "" }
                    }
                    .accessibilityLabel(addPrompt)
            }
        }
        .padding(.horizontal, metrics.spacing.s3)
        .frame(minHeight: density.rowHeight(in: metrics.layout))
        // The add row shows focus with the fields' focus edge, inside the list box.
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                .strokeBorder(palette[.borderFocus], lineWidth: metrics.stroke.regular)
                .padding(.horizontal, metrics.spacing.s1)
                .opacity(addFocused ? 1 : 0)
        }
    }
}

// MARK: Master-detail

/// One item in a `LumenMasterDetail` list.
public struct LumenMasterItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Marked with a check: it has something set.
    public let isConfigured: Bool

    public init(id: String, title: String, isConfigured: Bool = false) {
        self.id = id
        self.title = title
        self.isConfigured = isConfigured
    }
}

/// A titled group of `LumenMasterItem`s.
public struct LumenMasterSection: Identifiable, Hashable, Sendable {
    public let title: String
    public let items: [LumenMasterItem]
    public var id: String { title }

    public init(_ title: String, items: [LumenMasterItem]) {
        self.title = title
        self.items = items
    }
}

/// A list beside the selected item's settings: grouped items with a check on
/// the configured ones, and the detail filling the rest.
public struct LumenMasterDetail<Detail: View>: View {
    private let sections: [LumenMasterSection]
    @Binding private var selection: String?
    private let listWidth: CGFloat
    private let detail: (LumenMasterItem) -> Detail

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenMetrics) private var metrics

    public init(_ sections: [LumenMasterSection], selection: Binding<String?>, listWidth: CGFloat = 200,
                @ViewBuilder detail: @escaping (LumenMasterItem) -> Detail) {
        self.sections = sections
        _selection = selection
        self.listWidth = listWidth
        self.detail = detail
    }

    public var body: some View {
        HStack(alignment: .top, spacing: metrics.spacing.s4) {
            // Scrolls when the items outgrow a fixed-height pane (live; offscreen draws them all).
            LumenScrollsLive {
                VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                    ForEach(sections) { section in
                        Text(section.title).lumenSectionLabel()
                            .padding(.horizontal, metrics.spacing.s2 + metrics.spacing.s3).padding(.top, metrics.spacing.s3).padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.items) { item in row(item) }
                    }
                }
                .padding(.bottom, metrics.spacing.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: listWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(palette[.bgElevated], in: .rect(cornerRadius: metrics.radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: metrics.radius.md, style: .continuous).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline)
            }
            Group {
                if let item = sections.flatMap(\.items).first(where: { $0.id == selection }) {
                    detail(item)
                } else {
                    LumenEmptyState(systemImage: "sidebar.left", title: "Nothing selected", message: "Choose an item on the left.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func row(_ item: LumenMasterItem) -> some View {
        let selected = item.id == selection
        return Button { selection = item.id } label: {
            HStack(spacing: metrics.spacing.s2) {
                Text(item.title).font(metrics.typography.body).foregroundStyle(palette[selected ? .accentFilledForeground : .fgPrimary]).lineLimit(1)
                    .lumenNeverTruncates(item.title)
                Spacer(minLength: 0)
                // "Configured" is a dot after the name, not a check beside the selection (which read
                // as a selection mark).
                Circle().fill(palette[selected ? .accentFilledForeground : .accent])
                    .frame(width: metrics.layout.statusDot, height: metrics.layout.statusDot)
                    .opacity(item.isConfigured ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, metrics.spacing.s3)
            .frame(minHeight: density.rowHeight(in: metrics.layout))
            .background(selected ? palette[.accentFilled] : .clear, in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
            .padding(.horizontal, metrics.spacing.s2)   // the menus' and tables' band inset
            .contentShape(.rect)
        }
        .buttonStyle(.lumenBare)
        .accessibilityLabel(item.title + (item.isConfigured ? ", configured" : ""))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
