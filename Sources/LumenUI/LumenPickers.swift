import AppKit
import SwiftUI
import LumenTokens

// Small pickers: square color
// wells, a list wizard step, card field lists, plus swatch menus, an icon picker, a permissions grid
// and a managed tool row.

// MARK: Color wells

/// A color in a rounded square with a hairline ring, opening the system color panel.
public struct LumenColorWell: View {
    @Binding private var color: Color
    private let title: String
    private let supportsOpacity: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameter title: the spoken name and help ("Background", "Bright Red").
    public init(_ title: String, color: Binding<Color>, supportsOpacity: Bool = false) {
        self.title = title
        _color = color
        self.supportsOpacity = supportsOpacity
    }

    public var body: some View {
        ZStack {
            // The swatch sits inside a ring, inset by s1 so the ring's radius is the swatch's plus s1.
            RoundedRectangle(cornerRadius: metrics.radius.xs, style: .continuous)
                .fill(color)
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.radius.xs, style: .continuous)
                        .strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline)
                }
                .frame(width: metrics.layout.controlHeight, height: metrics.layout.controlHeight)
                .padding(metrics.spacing.s1)
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.radius.xs + metrics.spacing.s1, style: .continuous)
                        .strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline)
                }
            if !rendersOffscreen {
                // The system picker takes the clicks; the drawn swatch is what shows.
                ColorPicker(title, selection: $color, supportsOpacity: supportsOpacity)
                    .labelsHidden()
                    .opacity(0.02)
                    .frame(width: 26, height: 26)
                    .clipped()
            }
        }
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// Color wells in a labelled grid: a name per row and a column per variant (ANSI Colors × Normal /
/// Bright).
public struct LumenColorGrid: View {
    private let rows: [String]
    private let columns: [String]
    private let color: (_ row: Int, _ column: Int) -> Binding<Color>

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(rows: [String], columns: [String], color: @escaping (_ row: Int, _ column: Int) -> Binding<Color>) {
        self.rows = rows
        self.columns = columns
        self.color = color
    }

    public var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: metrics.spacing.s4, verticalSpacing: metrics.spacing.s3) {
            GridRow {
                Text("")
                ForEach(columns.indices, id: \.self) { column in
                    Text(columns[column]).font(metrics.typography.caption).foregroundStyle(palette[.fgSecondary])
                        .gridColumnAlignment(.center)
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    Text(rows[row]).font(metrics.typography.callout).foregroundStyle(palette[.fgSecondary])
                    ForEach(columns.indices, id: \.self) { column in
                        LumenColorWell("\(columns[column]) \(rows[row])", color: color(row, column))
                    }
                }
            }
        }
    }
}

// MARK: Swatch strips and icon picker

/// A palette as a strip of color bars, for menu items and pickers.
public struct LumenSwatchStrip: View {
    private let colors: [Color]
    private let width: CGFloat
    private let height: CGFloat
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ colors: [Color], width: CGFloat = 22, height: CGFloat = 14) {
        self.colors = colors
        self.width = width
        self.height = height
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { index in colors[index] }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: metrics.radius.xs, style: .continuous))
        // A sub-hairline: a 1 pt edge would swallow a swatch this small.
        .overlay { RoundedRectangle(cornerRadius: metrics.radius.xs, style: .continuous).strokeBorder(palette[.borderSubtle], lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    /// The strip as an `NSImage` (not a template), for native menu items.
    @MainActor
    public static func image(_ colors: [Color], width: CGFloat = 22, height: CGFloat = 14, scale: CGFloat = 2) -> NSImage? {
        let renderer = ImageRenderer(content: LumenSwatchStrip(colors, width: width, height: height).padding(0.5))
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width + 1, height: height + 1))
        image.isTemplate = false
        return image
    }
}

/// A native menu item led by a palette strip: `Menu { Button { … } label: { LumenSwatchMenuLabel("Rainbow", colors: …) } }`.
public struct LumenSwatchMenuLabel: View {
    private let title: String
    private let colors: [Color]
    @Environment(\.displayScale) private var displayScale

    public init(_ title: String, colors: [Color]) {
        self.title = title
        self.colors = colors
    }

    public var body: some View {
        Label {
            Text(title)
        } icon: {
            if let image = LumenSwatchStrip.image(colors, scale: max(displayScale, 2)) { Image(nsImage: image) }
        }
    }
}

/// One choice in a `LumenIconPicker`.
public struct LumenIconChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let systemImage: String
    public let hue: LumenToken

    public init(id: String, systemImage: String, hue: LumenToken) {
        self.id = id
        self.systemImage = systemImage
        self.hue = hue
    }
}

/// A large icon with a chevron that opens a grid of icons to pick from, with actions under it
///.
public struct LumenIconPicker: View {
    @Binding private var selection: String
    private let choices: [LumenIconChoice]
    private let size: CGFloat
    private let actions: [LumenBarAction]
    @State private var isOpen = false

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter actions: shown under the grid ("Choose Image…", "Use Default Image").
    public init(selection: Binding<String>, choices: [LumenIconChoice], size: CGFloat = 44, actions: [LumenBarAction] = []) {
        _selection = selection
        self.choices = choices
        self.size = size
        self.actions = actions
    }

    private var current: LumenIconChoice? { choices.first { $0.id == selection } ?? choices.first }

    public var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(alignment: .center, spacing: metrics.spacing.s2) {
                if let current { LumenIconTile(current.systemImage, hue: current.hue, size: size) }
                LumenSymbol("chevron.down").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)).foregroundStyle(palette[.fgSecondary])
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Choose Icon")
        .accessibilityLabel("Choose Icon")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { grid }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s4) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: metrics.spacing.s3), count: 4), spacing: metrics.spacing.s3) {
                ForEach(choices) { choice in
                    Button { selection = choice.id; isOpen = false } label: {
                        LumenIconTile(choice.systemImage, hue: choice.hue, size: metrics.layout.tileProminent)
                            .padding(3)
                            .overlay {
                                if choice.id == selection {
                                    RoundedRectangle(cornerRadius: metrics.radius.md, style: .continuous)
                                        .strokeBorder(palette[.accent], lineWidth: metrics.stroke.focus)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice.id == selection ? [.isSelected, .isButton] : .isButton)
                }
            }
            if !actions.isEmpty {
                Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
                ForEach(actions) { action in
                    Button(action.title) { isOpen = false; action.perform() }
                        .buttonStyle(.lumenBare)
                        .font(metrics.typography.callout)
                        .foregroundStyle(palette[.fgPrimary])
                        .disabled(!action.isEnabled)
                        .lumenDisabledFade(action.isEnabled)
                }
            }
        }
        .padding(metrics.spacing.s5)
        .lumenRaisedGround()
    }
}

// MARK: Wizard step

/// One option in a `LumenWizardStep`.
public struct LumenWizardChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let systemImage: String
    public let hue: LumenToken

    public init(id: String, title: String, detail: String? = nil, systemImage: String, hue: LumenToken) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.hue = hue
    }
}

/// A step of a sheet wizard that picks one thing: a title,
/// a list of large-icon rows, "Step 1 of 2", and Cancel / Back / Next. Double-click a row to go on.
public struct LumenWizardStep: View {
    private let title: String
    private let choices: [LumenWizardChoice]
    @Binding private var selection: String?
    private let step: Int
    private let stepCount: Int
    private let nextTitle: String
    private let onCancel: () -> Void
    private let onBack: (() -> Void)?
    private let onNext: () -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameters:
    ///   - step: this step, from 1.
    ///   - onBack: shows Back; `nil` on the first step.
    public init(_ title: String, choices: [LumenWizardChoice], selection: Binding<String?>, step: Int = 1, of stepCount: Int = 1,
                nextTitle: String = "Next", onCancel: @escaping () -> Void, onBack: (() -> Void)? = nil, onNext: @escaping () -> Void) {
        self.title = title
        self.choices = choices
        _selection = selection
        self.step = step
        self.stepCount = stepCount
        self.nextTitle = nextTitle
        self.onCancel = onCancel
        self.onBack = onBack
        self.onNext = onNext
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s5) {
            Text(title).font(metrics.typography.headline).foregroundStyle(palette[.fgPrimary]).accessibilityAddTraits(.isHeader)
            // The card hugs its choices and scrolls only when they don't fit (a greedy scroll view
            // stretched it into an empty well); the choices start at its top.
            Group {
                if rendersOffscreen { list } else { ViewThatFits(in: .vertical) { list; ScrollView { list } } }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(metrics.spacing.s2)
            .lumenChrome(.card)
            HStack(spacing: metrics.spacing.s3) {
                if stepCount > 1 {
                    Text("Step \(step) of \(stepCount)").font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                }
                Spacer(minLength: metrics.spacing.s4)
                Button("Cancel", action: onCancel).buttonStyle(.lumenQuiet).keyboardShortcut(.cancelAction).fixedSize()
                if let onBack { Button("Back", action: onBack).buttonStyle(.lumenQuiet).fixedSize() }
                Button(nextTitle, action: onNext)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
                    .fixedSize()
            }
        }
        .padding(metrics.spacing.s6)
    }

    private var list: some View {
        VStack(spacing: metrics.spacing.s1) {
            ForEach(choices) { choice in
                let selected = choice.id == selection
                HStack(spacing: metrics.spacing.s5) {
                    LumenIconTile(choice.systemImage, hue: choice.hue, size: metrics.layout.tileHeader)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.title).font(metrics.typography.body).foregroundStyle(palette[selected ? .accentFilledForeground : .fgPrimary])
                        if let detail = choice.detail {
                            Text(detail).font(metrics.typography.caption)
                                .foregroundStyle(selected ? palette[.accentFilledForeground].opacity(LumenRowColors.selectedSecondaryOpacity) : palette[.fgTertiary])
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(metrics.spacing.s3)
                // A picker's choice: the filled accent with white text, as menus and pickers select.
                .background(selected ? palette[.accentFilled] : .clear, in: .rect(cornerRadius: metrics.radius.md, style: .continuous))
                .contentShape(.rect)
                // A click selects at once; a double-click also goes on.
                .lumenSelectAndOpen(select: { selection = choice.id }, open: onNext)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}

// MARK: Field list

/// A labelled value in a `LumenFieldList`: the label at the leading edge, a borderless field (or any
/// control) at the trailing edge.
public struct LumenFieldRow<Control: View>: View {
    private let label: String
    private let control: Control

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s5) {
            Text(label).font(metrics.typography.body).foregroundStyle(palette[.fgPrimary]).fixedSize()
            Spacer(minLength: metrics.spacing.s4)
            control
        }
        .frame(minHeight: metrics.layout.controlHeight + 2 * metrics.spacing.s1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

public extension LumenFieldRow {
    /// A borderless text (or secure) field, right-aligned, with a quiet prompt ("(optional)").
    init(_ label: String, text: Binding<String>, prompt: String = "", secure: Bool = false) where Control == LumenInlineField {
        self.init(label) { LumenInlineField(text: text, prompt: prompt, secure: secure) }
    }
}

/// The borderless, right-aligned field of a `LumenFieldRow`.
public struct LumenInlineField: View {
    @Binding private var text: String
    private let prompt: String
    private let secure: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @FocusState private var focused: Bool

    public init(text: Binding<String>, prompt: String = "", secure: Bool = false) {
        _text = text
        self.prompt = prompt
        self.secure = secure
    }

    public var body: some View {
        Group {
            if rendersOffscreen {
                Text(text.isEmpty ? prompt : (secure ? String(repeating: "•", count: text.count) : text))
                    .foregroundStyle(palette[text.isEmpty ? .fgTertiary : .fgSecondary])
            } else if secure {
                SecureField("", text: $text, prompt: Text(prompt).foregroundStyle(palette[.fgTertiary]))
                    .textFieldStyle(.plain).foregroundStyle(palette[focused ? .fgPrimary : .fgSecondary])
                    .focused($focused)
            } else {
                TextField("", text: $text, prompt: Text(prompt).foregroundStyle(palette[.fgTertiary]))
                    .textFieldStyle(.plain).foregroundStyle(palette[focused ? .fgPrimary : .fgSecondary])
                    .focused($focused)
            }
        }
        .font(metrics.typography.body)
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .frame(maxWidth: 260, alignment: .trailing)
        // Borderless at rest; while editing it shows the fields' focus edge, as every Lumen field does.
        .padding(.horizontal, metrics.layout.fieldInset)
        .frame(minHeight: metrics.layout.controlHeight)
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                .strokeBorder(palette[.borderFocus], lineWidth: metrics.stroke.regular)
                .opacity(focused ? 1 : 0)
        }
    }
}

/// A titled form on a settings card (for a server form): the item's tile, title
/// and subtitle, then `LumenFieldRow`s with hairlines between them.
public struct LumenFieldList<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let hue: LumenToken
    private let content: Content

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameters:
    ///   - subtitle: a quiet line under the title (the protocol, the kind).
    ///   - content: `LumenFieldRow`s; the card puts hairlines between them.
    public init(_ title: String, subtitle: String? = nil, systemImage: String, hue: LumenToken, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hue = hue
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s5) {
            HStack(spacing: metrics.spacing.s5) {
                LumenIconTile(systemImage, hue: hue, size: metrics.layout.tilePaneHeader)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(metrics.typography.headline).foregroundStyle(palette[.fgPrimary]).accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                    }
                }
            }
            LumenSettingsCard { content }
        }
    }
}

// MARK: Permissions grid

/// Unix permissions as Read / Write / Execute checkboxes for User, Group and World, with the octal
/// value (editable) and its rw-r--r-- form.
public struct LumenPermissionsGrid: View {
    @Binding private var mode: Int

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameter mode: the permission bits, such as `0o644`.
    public init(mode: Binding<Int>) {
        _mode = mode
    }

    private static let classes = ["User", "Group", "World"]
    private static let rights = [("Read", 4), ("Write", 2), ("Execute", 1)]

    /// "0644" for `0o644`.
    public static func octal(_ mode: Int) -> String { "0" + String(mode & 0o777, radix: 8).leftPadded(to: 3) }

    /// The mode in `text` ("644", "0755"), or `nil` when it isn't octal permissions.
    public static func mode(from text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(digits.count), let value = Int(digits, radix: 8), value <= 0o777 else { return nil }
        return value
    }

    /// "rw-r--r--" for `0o644`.
    public static func symbolic(_ mode: Int) -> String {
        (0..<3).map { group in
            let bits = (mode >> (6 - group * 3)) & 7
            return (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + (bits & 1 != 0 ? "x" : "-")
        }.joined()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s5) {
            Grid(alignment: .leading, horizontalSpacing: metrics.spacing.s6, verticalSpacing: metrics.spacing.s4) {
                ForEach(Self.classes.indices, id: \.self) { group in
                    GridRow {
                        Text(Self.classes[group] + ":").font(metrics.typography.body).foregroundStyle(palette[.fgSecondary])
                            .gridColumnAlignment(.trailing)
                        ForEach(Self.rights, id: \.0) { right in
                            let bit = right.1 << (6 - group * 3)
                            Toggle(right.0, isOn: Binding(get: { mode & bit != 0 }, set: { mode = $0 ? mode | bit : mode & ~bit }))
                                .toggleStyle(.lumenCheckbox)
                        }
                    }
                }
            }
            HStack(spacing: metrics.spacing.s4) {
                Text("Octal:").font(metrics.typography.body).foregroundStyle(palette[.fgSecondary])
                OctalField(mode: $mode)
                Text(Self.symbolic(mode)).font((codeFont ?? .standard).font(sizeDelta: -1)).foregroundStyle(palette[.fgTertiary])
            }
        }
    }

    /// The octal value, typed freely and applied on Return or when the field loses focus (typing "7"
    /// on the way to "755" is not a mode, so a binding that dropped it made the field uneditable);
    /// text that isn't a mode reverts.
    private struct OctalField: View {
        @Binding var mode: Int
        @State private var text = ""
        @FocusState private var focused: Bool
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.lumenCodeFont) private var codeFont

        init(mode: Binding<Int>) {
            _mode = mode
            _text = State(initialValue: LumenPermissionsGrid.octal(mode.wrappedValue))   // offscreen renders run no onAppear
        }

        var body: some View {
            LumenFieldInput(text: $text, font: (codeFont ?? .standard).font(sizeDelta: -1), focus: $focused, onSubmit: commit)
                .padding(.horizontal, metrics.layout.fieldInset)
                .frame(width: 60, height: metrics.layout.controlHeight, alignment: .leading)
                .lumenChrome(.field, focused: focused)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onChange(of: mode) { _, new in if !focused { text = LumenPermissionsGrid.octal(new) } }
                .accessibilityLabel("Octal permissions")
        }

        private func commit() {
            if let value = LumenPermissionsGrid.mode(from: text) { mode = value }
            text = LumenPermissionsGrid.octal(mode)
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}

// MARK: Managed tool row

/// What a managed tool is doing.
public enum LumenToolInstallState: Sendable, Hashable {
    case available
    case installing
    case installed
}

/// A tool the app can install and manage: its package icon, name and dim
/// version, an Install capsule like `LumenItemCard`'s (Installed when done), a ⋯ menu, and a description with a link.
public struct LumenManagedToolRow<MenuContent: View>: View {
    private let name: String
    private let version: String?
    private let detail: String?
    private let systemImage: String
    private let hue: LumenToken
    private let state: LumenToolInstallState
    private let onInstall: () -> Void
    private let learnMore: LumenBarAction?
    private let menu: MenuContent

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameters:
    ///   - version: shown dim after the name.
    ///   - detail: a line under a hairline, with `learnMore` after it.
    ///   - state: Install, a spinner while installing, or Installed.
    ///   - menu: the ⋯ menu's items (Copy URL, Install Version…).
    public init(_ name: String, version: String? = nil, detail: String? = nil, systemImage: String = "shippingbox.fill",
                hue: LumenToken = .hueOrange, state: LumenToolInstallState, onInstall: @escaping () -> Void,
                learnMore: LumenBarAction? = nil, @ViewBuilder menu: () -> MenuContent) {
        self.name = name
        self.version = version
        self.detail = detail
        self.systemImage = systemImage
        self.hue = hue
        self.state = state
        self.onInstall = onInstall
        self.learnMore = learnMore
        self.menu = menu()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s3) {
            HStack(spacing: metrics.spacing.s4) {
                LumenSymbol(systemImage).font(.system(size: metrics.iconSize.large)).foregroundStyle(palette[hue])
                    .frame(width: metrics.iconSize.large)
                (Text(name).foregroundColor(palette[.fgPrimary]).fontWeight(.semibold)
                    + Text(version.map { "  " + $0 } ?? "").foregroundColor(palette[.fgTertiary]))
                    .font(metrics.typography.callout)
                    .lineLimit(1)
                    .lumenNeverTruncates(name + (version.map { "  " + $0 } ?? ""))
                Spacer(minLength: metrics.spacing.s4)
                stateControl
                more
            }
            if detail != nil || learnMore != nil {
                Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
                HStack(spacing: metrics.spacing.s2) {
                    if let detail { Text(detail).foregroundStyle(palette[.fgSecondary]) }
                    if let learnMore {
                        Button(learnMore.title, action: learnMore.perform).buttonStyle(.lumenBare).foregroundStyle(palette[.fgLink]).lumenLinkPointer()
                    }
                }
                .font(metrics.typography.caption)
                // Under the name: the icon's column plus the gap after it.
                .padding(.leading, metrics.iconSize.large + metrics.spacing.s4)
            }
        }
        .padding(metrics.spacing.s5)
        .lumenChrome(.card)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var stateControl: some View {
        switch state {
        case .available:
            // One Install button (the extension card's too): the tinted panel-action style, 24 pt, 13 pt.
            Button("Install", action: onInstall)
                .buttonStyle(LumenTintedButtonStyle())
                .fixedSize()
        case .installing:
            LumenProgressRing(progress: nil).frame(width: 16, height: 16)
        case .installed:
            Text("Installed").font(metrics.typography.caption.weight(.semibold)).foregroundStyle(palette[.fgTertiary])
        }
    }

    private var more: some View {
        LumenMenuButton(help: "More") { menu } label: {
            LumenSymbol("ellipsis.circle").font(.system(size: metrics.layout.toolbarGlyphSize)).foregroundStyle(palette[.fgSecondary])
        }
        .accessibilityLabel("More")
    }
}
