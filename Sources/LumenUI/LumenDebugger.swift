import AppKit
import SwiftUI
import LumenTokens

// A debugger's stack and registers, chosen for MacScope: numbered frame rows, and
// register cards that mark what changed since the last stop.

private func lumenHex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

/// Shared type decisions for the debugger's rows (calm type: one weight for a row's name).
enum LumenDebuggerType {
    /// The weight of a row's name (a frame's function, a breakpoint, a watch, a variable).
    static let rowNameWeight: Font.Weight = .medium
}

extension LumenCodeFont {
    /// The advance of one digit in this font, measured, so a custom font wider than SF Mono still
    /// fits its columns (hex cells, gutters).
    var digitAdvance: CGFloat {
        ceil(("0" as NSString).size(withAttributes: [.font: nsFont()]).width * 2) / 2
    }
}

/// A `LazyVStack`, or a plain `VStack` where every row must draw in one pass (offscreen renders,
/// which have no scrolling to fill rows in later) or where the rows are few.
struct LumenLazyVStack<Content: View>: View {
    /// Up to this many rows stay eager: exact sizes anywhere (a lazy stack outside a scroll view
    /// misreports its height when rows change size after the first layout), and too few rows for
    /// laziness to matter.
    static var eagerLimit: Int { 200 }

    let eager: Bool
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        if eager {
            VStack(alignment: alignment, spacing: spacing) { content }
        } else {
            LazyVStack(alignment: alignment, spacing: spacing) { content }
        }
    }
}

// MARK: Stack

/// One frame of a call stack.
public struct LumenStackFrame: Identifiable, Hashable, Sendable {
    /// The frame's depth: 0 is the innermost.
    public let index: Int
    public let function: String
    public let address: UInt64
    /// Where it is: a source line (`main.swift:42`) or the module (`dyld`).
    public let location: String?
    /// A frame outside the app's own code, drawn quieter.
    public let isSystem: Bool
    public var id: Int { index }

    public init(index: Int, function: String, address: UInt64, location: String? = nil, isSystem: Bool = false) {
        self.index = index
        self.function = function
        self.address = address
        self.location = location
        self.isSystem = isSystem
    }
}

/// A call stack as rows: each frame's number in a badge, its function
/// and where it is, and its address at the trailing edge. The selected frame takes the quiet list selection
/// and an accent index badge; system frames are quieter. The function truncates in the middle before anything clips. Put
/// it in the pane's scroll view.
public struct LumenStackFrameList: View {
    private let frames: [LumenStackFrame]
    @Binding private var selection: Int?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.controlActiveState) private var activeState
    @State private var hovered: Int?
    @Environment(\.lumenEmptyMessage) private var emptyMessage
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameter selection: the selected frame's `index`.
    public init(_ frames: [LumenStackFrame], selection: Binding<Int?>) {
        self.frames = frames
        _selection = selection
    }

    public var body: some View {
        // Lazy in the pane's scroll view once there are many frames, so a 1,000-frame recursion builds
        // only the rows on screen (PERF-04); offscreen renders draw every row in one pass.
        LumenLazyVStack(eager: rendersOffscreen || frames.count <= LumenLazyVStack<EmptyView>.eagerLimit, spacing: metrics.spacing.s1) {
            if frames.isEmpty { LumenEmptyState.inline(emptyMessage ?? "No stack frames") }
            ForEach(frames) { frame in row(frame) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Call stack")
    }

    private func row(_ frame: LumenStackFrame) -> some View {
        let selected = frame.index == selection
        let mono = (codeFont ?? .standard).font(weight: .regular)
        return Button { selection = frame.index } label: {
            HStack(spacing: metrics.spacing.s3) {
                Text("\(frame.index)")
                    .font(metrics.typography.countDigit)
                    .foregroundStyle(palette[selected ? .accentFilledForeground : .fgSecondary])
                    .frame(minWidth: metrics.layout.frameIndexSize, minHeight: metrics.layout.frameIndexSize)
                    .background(palette[selected ? .accentFilled : .bgInset], in: .capsule)
                VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                    // One row-name weight across the debugger's rows; semibold marks the selection only.
                    LumenSemanticText(frame.function, kind: .symbol)
                        .font((codeFont ?? .standard).font(weight: selected ? .semibold : LumenDebuggerType.rowNameWeight))
                        .foregroundStyle(palette[frame.isSystem && !selected ? .fgTertiary : .fgPrimary])
                        
                    if let location = frame.location {
                        Text(location).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .layoutPriority(-1)
                Spacer(minLength: metrics.spacing.s2)
                Text(lumenHex(frame.address)).font(mono).foregroundStyle(palette[.fgSecondary]).fixedSize()
            }
            .padding(.horizontal, metrics.spacing.s2)
            .frame(minHeight: density.detailedRowHeight(in: metrics.layout))
            // The navigation family's quiet selection (§10), quieter in an inactive window; hover is
            // the one hover fill.
            .background(selected ? LumenRowColors(LumenRowState.resolve(isSelected: true, isActiveWindow: activeState != .inactive),
                                                  context: .content, palette: palette).fill
                        : hovered == frame.index ? palette.hoverFill(metrics) : .clear,
                        in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
            // The plate and the accent index mark the selection; no edge bar notching the plate's corner.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? frame.index : (hovered == frame.index ? nil : hovered) }
        .help([frame.function, frame.location].compactMap(\.self).joined(separator: " — "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([selected ? "Selected frame \(frame.index)" : "Frame \(frame.index)", frame.function,
                             lumenHex(frame.address), frame.location].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Registers

/// One register as a debugger shows it.
public struct LumenRegister: Identifiable, Hashable, Sendable {
    public let name: String
    /// The value already formatted (hex, decimal, signed or float).
    public let value: String
    /// What it's for (`frame`, `link`, `stack`, `program`), if anything.
    public let role: String?
    /// Whether it changed since the last stop.
    public let changed: Bool
    public var id: String { name }

    public init(_ name: String, value: String, role: String? = nil, changed: Bool = false) {
        self.name = name
        self.value = value
        self.role = role
        self.changed = changed
    }
}

/// Registers as small cards: the name and role over the value, in as
/// many columns as fit. A register that changed since the last stop has an accent name, outline and
/// dot. Clicking a card hands it to `onSelect` (MacScope seeds its write field). Give a group a
/// `LumenSectionHeader` above it, and switch formats with `LumenModeSwitcher(style: .pill)`.
public struct LumenRegisterGrid: View {
    private let registers: [LumenRegister]
    private let minimumColumnWidth: CGFloat
    private let onSelect: (LumenRegister) -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @State private var hovered: String?

    public init(_ registers: [LumenRegister], minimumColumnWidth: CGFloat = 168,
                onSelect: @escaping (LumenRegister) -> Void = { _ in }) {
        self.registers = registers
        self.minimumColumnWidth = minimumColumnWidth
        self.onSelect = onSelect
    }

    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumColumnWidth), spacing: metrics.spacing.s2)],
                  alignment: .leading, spacing: metrics.spacing.s2) {
            ForEach(registers) { register in card(register) }
        }
    }

    private func card(_ register: LumenRegister) -> some View {
        Button { onSelect(register) } label: {
            VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                HStack(spacing: metrics.spacing.s1) {
                    // Monospaced, so "lr" never reads as "Ir".
                    Text(register.name).font((codeFont ?? .standard).font(sizeDelta: -1, weight: .semibold))
                        .foregroundStyle(palette[register.changed ? .accent : .fgSecondary])
                    if let role = register.role {
                        Text(role).font(.caption2).foregroundStyle(palette[.fgTertiary]).lineLimit(1).truncationMode(.tail).help(role)
                    }
                    Spacer(minLength: 0)
                    if register.changed { Circle().fill(palette[.accent]).frame(width: metrics.layout.statusDot, height: metrics.layout.statusDot) }
                }
                Text(register.value)
                    .font((codeFont ?? .standard).font(weight: .regular))
                    .foregroundStyle(palette[.fgPrimary])
                    .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.85)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, metrics.spacing.s3)
            .padding(.vertical, metrics.spacing.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette[hovered == register.id ? .bgHover : .bgElevated], in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
            .overlay {
                // State at full strength: a faded accent falls below the default border in the contrast themes.
                RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                    .strokeBorder(register.changed ? palette[.accent] : palette[.borderSubtle], lineWidth: metrics.stroke.hairline)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? register.id : (hovered == register.id ? nil : hovered) }
        .help("Edit \(register.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([register.name, register.role, register.value, register.changed ? "changed" : nil]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Console

/// One line of a debugger console.
public struct LumenConsoleLine: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        /// Something the person typed, shown after the prompt.
        case command
        /// What the debugger said back.
        case output
        /// The process stopped (a breakpoint, a signal, a step).
        case stop
        case warning
        case error
    }

    public let id: UUID
    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// A debugger console as a transcript: commands after an accent prompt,
/// output quieter, stops in blue and warnings in amber, with the input line at the bottom. Lines wrap
/// rather than truncate, and the transcript follows the newest line.
///
/// Each change to `lines` re-diffs the whole transcript (about 60 ms at 100k lines in a debug
/// build), so append streamed output in batches (once a frame, not once a line), and cap a long
/// history, with a line saying how many earlier lines were dropped.
public struct LumenConsole: View {
    private let lines: [LumenConsoleLine]
    @Binding private var input: String
    private let prompt: String
    private let placeholder: String
    private let onSubmit: (String) -> Void
    private let drawsStatic: Bool
    private var acceptsInput = true

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont

    /// - Parameters:
    ///   - prompt: what precedes commands and the input (`(lldb)`).
    ///   - onSubmit: the command, on Return; the field clears itself.
    public init(lines: [LumenConsoleLine], input: Binding<String>, prompt: String = "(lldb)",
                placeholder: String = "Command", onSubmit: @escaping (String) -> Void) {
        self.init(lines: lines, input: input, prompt: prompt, placeholder: placeholder, drawsStatic: false, onSubmit: onSubmit)
    }

    /// A read-only transcript: the same lines, following the newest, with no input row (a status log,
    /// or a debugger that takes no typed commands).
    public init(lines: [LumenConsoleLine], prompt: String = "(lldb)") {
        self.init(lines: lines, input: .constant(""), prompt: prompt, placeholder: "", drawsStatic: false, onSubmit: { _ in })
        acceptsInput = false
    }

    /// For golden images, where scroll views and text fields can't draw.
    init(lines: [LumenConsoleLine], input: Binding<String>, prompt: String, placeholder: String, drawsStatic: Bool,
         onSubmit: @escaping (String) -> Void) {
        self.lines = lines
        _input = input
        self.prompt = prompt
        self.placeholder = placeholder
        self.onSubmit = onSubmit
        self.drawsStatic = drawsStatic
    }

    private var mono: Font { (codeFont ?? .standard).font(weight: .regular) }
    private var monoBold: Font { (codeFont ?? .standard).font(weight: .semibold) }

    public var body: some View {
        VStack(spacing: 0) {
            if drawsStatic {
                transcript.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    // Unwrapped: an `Optional<UUID>` never matches a row's `.id(UUID)`.
                    ScrollView { transcript }
                        .onAppear { if let last = lines.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                        .onChange(of: lines.last?.id) { _, last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            if acceptsInput { inputLine }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Console")
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: metrics.spacing.s1) {
            ForEach(lines) { line in
                // Every line's text starts at one inset; stop, warning and error marks hang in the
                // gutter before it, so wrapped lines and the input's prompt line up too.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    marker(for: line.kind).frame(width: markerGutter, alignment: .leading)
                    text(for: line)
                        .lumenWrapsWithoutTruncating()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(line.id)
            }
        }
        .padding(.vertical, metrics.spacing.s3)
        .padding(.horizontal, metrics.spacing.s2)
        // The trailing margin matches the text's leading inset (s2 plus the marker gutter).
        .padding(.trailing, markerGutter)
    }

    /// The hanging column for line marks: about two characters of the code font.
    private var markerGutter: CGFloat { (codeFont ?? .standard).digitAdvance * 2 }

    @ViewBuilder private func marker(for kind: LumenConsoleLine.Kind) -> some View {
        switch kind {
        // One symbol family at one size, set as text so each sits on the line's baseline.
        case .stop: markerSymbol("square.fill", .statusInfo).accessibilityHidden(true)
        case .warning: markerSymbol("exclamationmark.triangle.fill", .statusWarning).accessibilityLabel("Warning")
        case .error: markerSymbol("xmark.octagon.fill", .statusDanger).accessibilityLabel("Error")
        case .command, .output: Color.clear.frame(height: 1).accessibilityHidden(true)
        }
    }

    private func markerSymbol(_ name: String, _ tone: LumenToken) -> some View {
        Text(Image(systemName: name)).font(metrics.typography.caption).foregroundStyle(palette[tone])
    }

    private func text(for line: LumenConsoleLine) -> Text {
        switch line.kind {
        case .command:
            Text(prompt + " ").font(monoBold).foregroundColor(palette[.accent]) + Text(line.text).font(monoBold).foregroundColor(palette[.fgPrimary])
        case .output:
            Text(line.text).font(mono).foregroundColor(palette[.fgSecondary])
        case .stop:
            Text(line.text).font(monoBold).foregroundColor(palette[.statusInfo])
        case .warning:
            Text(line.text).font(mono).foregroundColor(palette[.statusWarning])
        case .error:
            Text(line.text).font(mono).foregroundColor(palette[.statusDanger])
        }
    }

    private var inputLine: some View {
        HStack(spacing: metrics.spacing.s2) {
            Text(prompt).font(monoBold).foregroundStyle(palette[.accent]).fixedSize()
                .padding(.leading, markerGutter)   // on the transcript's text inset
            if drawsStatic {
                Text(input.isEmpty ? placeholder : input).font(mono).foregroundStyle(palette[input.isEmpty ? .fgTertiary : .fgPrimary])
                Spacer(minLength: 0)
            } else {
                TextField(placeholder, text: $input, prompt: Text(placeholder).foregroundStyle(palette[.fgTertiary]))
                    .textFieldStyle(.plain)
                    .font(mono)
                    .foregroundStyle(palette[.fgPrimary])
                    .onSubmit {
                        let command = input
                        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        input = ""
                        onSubmit(command)
                    }
                    .accessibilityLabel("Command")
            }
            Text("↩").font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary]).accessibilityHidden(true)
        }
        .padding(.horizontal, metrics.spacing.s2)
        .frame(minHeight: 30)
        .background(palette[.bgInset])
        .overlay(alignment: .top) { Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline) }
    }
}

// MARK: Breakpoints

/// A breakpoint's on/off switch, drawn as a breakpoint arrow: filled in the accent when on,
/// outlined when off. Click to toggle.
public struct LumenBreakpointMarker: View {
    @Binding private var isOn: Bool
    private let label: String

    @Environment(\.lumenPalette) private var palette
    @State private var hovered = false

    /// - Parameter label: what the breakpoint is, for VoiceOver ("compute(_:)").
    public init(isOn: Binding<Bool>, label: String) {
        _isOn = isOn
        self.label = label
    }

    public var body: some View {
        Button { isOn.toggle() } label: {
            let ink = palette[isOn ? .accent : hovered ? .fgSecondary : .fgTertiary]
            LumenBreakpointShape()
                .fill(isOn ? ink : .clear)
                .overlay { LumenBreakpointShape().stroke(ink, lineWidth: 1.2) }
                .frame(width: 20, height: 14)
                .padding(4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(isOn ? "Disable breakpoint" : "Enable breakpoint")
        .accessibilityLabel("Breakpoint \(label)")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A breakpoint arrow: a rounded tag pointing right.
struct LumenBreakpointShape: Shape {
    func path(in rect: CGRect) -> Path {
        let point = rect.width * 0.3
        let radius = min(3, rect.height / 4)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - point, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - point, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius), radius: radius)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
            path.closeSubpath()
        }
    }
}

/// A saved breakpoint as a row: its marker to turn it on or off, where it
/// is and its scope, then its state in a tinted capsule over its hit count. Clicking the row shows
/// `details` beneath (MacScope's runtime locations); Edit and Delete are in the context menu.
public struct LumenBreakpointRow<Details: View>: View {
    @Binding private var isEnabled: Bool
    private let locator: String
    private let scope: String?
    private let status: String
    private let tone: LumenToken
    private let hits: Int
    private let onEdit: (() -> Void)?
    private let onDelete: (() -> Void)?
    private let details: Details?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @State private var expanded = false

    /// - Parameters:
    ///   - status: its state ("Armed", "Pending", "Off").
    ///   - tone: the state's color: `.statusSuccess`, `.statusWarning`, `.statusDanger` or `.fgTertiary`.
    ///   - details: shown beneath when the row is clicked.
    public init(isEnabled: Binding<Bool>, locator: String, scope: String? = nil, status: String, tone: LumenToken,
                hits: Int = 0, onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil,
                @ViewBuilder details: () -> Details) {
        _isEnabled = isEnabled
        self.locator = locator
        self.scope = scope
        self.status = status
        self.tone = tone
        self.hits = hits
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.details = details()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            HStack(spacing: metrics.spacing.s3) {
                LumenBreakpointMarker(isOn: $isEnabled, label: locator)
                Button { if Details.self != EmptyView.self { expanded.toggle() } } label: {
                    HStack(spacing: metrics.spacing.s3) {
                        VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                            LumenSemanticText(locator, kind: .symbol)
                                .font((codeFont ?? .standard).font(weight: LumenDebuggerType.rowNameWeight))
                                .foregroundStyle(palette[isEnabled ? .fgPrimary : .fgTertiary])
                                
                            if let scope {
                                Text(scope).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .layoutPriority(-1)
                        Spacer(minLength: metrics.spacing.s2)
                        VStack(alignment: .trailing, spacing: metrics.spacing.s1) {
                            Text(status)
                                .font(metrics.typography.captionEmphasized)
                                .foregroundStyle(palette[tone])
                                .lumenChip(palette.toneBackground(tone))   // the one chip spec
                            Text(hits == 1 ? "1 hit" : "\(hits.formatted()) hits")
                                .font(.caption2.monospacedDigit()).foregroundStyle(palette[.fgTertiary])
                        }
                        .fixedSize()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel([locator, scope, status, "\(hits) hits"].compactMap(\.self).joined(separator: ", "))
            }
            if expanded, let details {
                details.padding(.leading, 28 + metrics.spacing.s3)
            }
        }
        .padding(.horizontal, metrics.spacing.s2)
        .padding(.vertical, metrics.spacing.s1)
        .contextMenu {
            Button(isEnabled ? "Disable" : "Enable") { isEnabled.toggle() }
            if let onEdit { Button("Edit…", action: onEdit) }
            if let onDelete {
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

public extension LumenBreakpointRow where Details == EmptyView {
    init(isEnabled: Binding<Bool>, locator: String, scope: String? = nil, status: String, tone: LumenToken,
         hits: Int = 0, onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.init(isEnabled: isEnabled, locator: locator, scope: scope, status: status, tone: tone, hits: hits,
                  onEdit: onEdit, onDelete: onDelete) { EmptyView() }
    }
}

// MARK: Hex

/// The colors of a hex view in the quiet style: offsets tertiary, zero
/// bytes faded, other bytes primary, the ASCII column split off by a hairline, the selection a solid
/// accent block mirrored in both columns, and the selected row faintly tinted. `LumenHexDump` draws with
/// it; an app with its own hex text view (MacScope's editor) applies it as text attributes.
public struct LumenHexStyle {
    public let offset: Color
    public let byte: Color
    public let zeroByte: Color
    /// A `.` standing in for an unprintable byte in the ASCII column.
    public let unprintable: Color
    public let selectionBackground: Color
    public let selectionForeground: Color
    public let selectedRowBackground: Color
    public let separator: Color

    public init(palette: LumenResolvedPalette) {
        offset = palette[.fgTertiary]
        byte = palette[.fgPrimary]
        zeroByte = palette[.fgTertiary]
        unprintable = palette[.fgTertiary]
        // One filled-accent look: the deep accent under white, never the bright accent with dark text.
        selectionBackground = palette[.accentFilled]
        selectionForeground = palette[.accentFilledForeground]
        selectedRowBackground = palette[.accentSubtle].opacity(0.5)
        separator = palette[.borderSubtle]
    }

    /// A byte's color in the hex column.
    public func color(forByte value: UInt8) -> Color { value == 0 ? zeroByte : byte }

    /// A byte's color in the ASCII column.
    public func asciiColor(forByte value: UInt8) -> Color { Self.isPrintable(value) ? byte : unprintable }

    /// AppKit colors, for an `NSTextView`'s attributes.
    public func nsColor(forByte value: UInt8) -> NSColor { NSColor(color(forByte: value)) }

    static func isPrintable(_ value: UInt8) -> Bool { (0x20..<0x7f).contains(value) }
}

/// Bytes as a hex dump in the quiet style: the address of
/// each row, its bytes, and their ASCII. Click a byte to select it; shift-click extends the
/// selection. Sixteen bytes a row where they fit, then eight, then four, so nothing is cut off. Put
/// it in the pane's scroll view.
public struct LumenHexDump: View {
    private let bytes: [UInt8]
    private let baseAddress: UInt64
    @Binding private var selection: Range<Int>?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter selection: selected byte offsets into `bytes`.
    public init(_ bytes: [UInt8], baseAddress: UInt64, selection: Binding<Range<Int>?>) {
        self.bytes = bytes
        self.baseAddress = baseAddress
        _selection = selection
    }

    private var size: CGFloat { (codeFont ?? .standard).size }
    private var font: Font { (codeFont ?? .standard).font() }
    private var charWidth: CGFloat { (codeFont ?? .standard).digitAdvance }
    private var addressDigits: Int {
        let last = baseAddress &+ UInt64(max(bytes.count - 1, 0))
        return max(8, String(last, radix: 16).count)
    }

    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @State private var measuredWidth: CGFloat?

    /// The width a row of `perRow` bytes takes: every part of it has a fixed width.
    func rowWidth(perRow: Int) -> CGFloat {
        let charWidth = self.charWidth
        return metrics.spacing.s2 * 2 + CGFloat(addressDigits) * charWidth + charWidth * 2
            + CGFloat(perRow) * charWidth * 3 + (perRow == 16 ? charWidth : 0)
            + metrics.stroke.hairline + charWidth * 2 + CGFloat(min(perRow, bytes.count)) * charWidth
    }

    /// Sixteen, eight or four bytes a row: the most that fit `width` (four when none do).
    func bytesPerRow(in width: CGFloat?) -> Int {
        guard let width else { return 16 }
        return [16, 8].first { rowWidth(perRow: $0) <= width } ?? 4
    }

    public var body: some View {
        let style = LumenHexStyle(palette: palette)
        Group {
            if rendersOffscreen {
                ViewThatFits(in: .horizontal) {
                    rows(perRow: 16, style: style)
                    rows(perRow: 8, style: style)
                    rows(perRow: 4, style: style)
                }
            } else {
                // The same choice from the measured width, so one stack of rows is built, not three
                // (PERF-05: `ViewThatFits` measured all three as rows scrolled in).
                rows(perRow: bytesPerRow(in: measuredWidth), style: style)
            }
        }
        // The least width is the narrowest layout's (4 bytes a row), as `ViewThatFits` reported, not the
        // layout on screen: otherwise a wide pane's 16-byte rows would pin the window's minimum and the
        // narrower layouts could never be reached.
        .frame(minWidth: rendersOffscreen ? nil : rowWidth(perRow: 4), maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if !rendersOffscreen { measuredWidth = $0 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory at \(lumenHex(baseAddress)), \(bytes.count) bytes")
    }

    private func rows(perRow: Int, style: LumenHexStyle) -> some View {
        // Every cell uses the same font. Measure its digit advance once for this row collection.
        let charWidth = self.charWidth
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stride(from: 0, to: bytes.count, by: perRow)), id: \.self) { start in
                row(start: start, count: min(perRow, bytes.count - start), perRow: perRow, charWidth: charWidth, style: style)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func row(start: Int, count: Int, perRow: Int, charWidth: CGFloat, style: LumenHexStyle) -> some View {
        let rowSelected = selection.map { $0.overlaps(start..<(start + count)) } ?? false
        let address = String(baseAddress &+ UInt64(start), radix: 16)
        let rowHeight = ceil(size * 1.6)
        var widths = [CGFloat(addressDigits) * charWidth + charWidth * 2]
        for index in 0..<perRow {
            widths.append(charWidth * 3)
            if perRow == 16, index == 7 { widths.append(charWidth) }
        }
        widths.append(metrics.stroke.hairline + charWidth * 2)
        widths.append(contentsOf: repeatElement(charWidth, count: count))
        return LumenHexRowLayout(widths: widths, height: rowHeight) {
            Text(String(repeating: "0", count: max(0, addressDigits - address.count)) + address)
                .foregroundStyle(style.offset)
                .frame(width: CGFloat(addressDigits) * charWidth, alignment: .leading)
                .padding(.trailing, charWidth * 2)
            ForEach(start..<(start + perRow), id: \.self) { index in
                if index < start + count {
                    cell(index, text: String(format: "%02x", bytes[index]), ink: style.color(forByte: bytes[index]),
                         width: charWidth * 3, height: rowHeight, style: style)
                } else {
                    Color.clear.frame(width: charWidth * 3)
                }
                // Sixteen-byte rows split into two groups of eight, as hex editors and debuggers do.
                if perRow == 16, index - start == 7 { Color.clear.frame(width: charWidth) }
            }
            Rectangle().fill(style.separator).frame(width: metrics.stroke.hairline).padding(.horizontal, charWidth)
            ForEach(start..<(start + count), id: \.self) { index in
                let value = bytes[index]
                cell(index, text: LumenHexStyle.isPrintable(value) ? String(UnicodeScalar(value)) : ".",
                     ink: style.asciiColor(forByte: value), width: charWidth, height: rowHeight, style: style)
            }
        }
        .font(font)
        .frame(height: rowHeight)
        .padding(.horizontal, metrics.spacing.s2)
        .background(rowSelected ? style.selectedRowBackground : .clear)
        // One tap target a row, mapped to the byte under the pointer (PERF-05: one per cell was 32 a row).
        .contentShape(.rect)
        .onTapGesture(coordinateSpace: .local) { point in
            if let index = byteIndex(at: point.x, start: start, count: count, perRow: perRow) { select(index) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lumenHex(baseAddress &+ UInt64(start))): "
            + bytes[start..<(start + count)].map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    private func cell(_ index: Int, text: String, ink: Color, width: CGFloat, height: CGFloat, style: LumenHexStyle) -> some View {
        let selected = selection?.contains(index) ?? false
        return Text(text)
            .foregroundStyle(selected ? style.selectionForeground : ink)
            .frame(width: width, height: height)
            .background(selected ? style.selectionBackground : .clear)
    }

    /// The byte under `x` in a row's coordinates (hex or ASCII cell), or `nil` between cells.
    func byteIndex(at x: CGFloat, start: Int, count: Int, perRow: Int) -> Int? {
        let charWidth = self.charWidth
        let hexStart = metrics.spacing.s2 + CGFloat(addressDigits) * charWidth + charWidth * 2
        let gap = perRow == 16 ? charWidth : 0
        let hexEnd = hexStart + CGFloat(perRow) * charWidth * 3 + gap
        let asciiStart = hexEnd + charWidth * 2 + metrics.stroke.hairline
        var slot: Int?
        if x >= hexStart, x < hexEnd {
            var offset = x - hexStart
            if perRow == 16, offset >= charWidth * 3 * 8 {
                offset -= charWidth * 3 * 8
                slot = offset < gap ? nil : 8 + Int((offset - gap) / (charWidth * 3))
            } else {
                slot = Int(offset / (charWidth * 3))
            }
        } else if x >= asciiStart, x < asciiStart + CGFloat(count) * charWidth {
            slot = Int((x - asciiStart) / charWidth)
        }
        guard let slot, slot < count else { return nil }
        return start + slot
    }

    private func select(_ index: Int) {
        if NSEvent.modifierFlags.contains(.shift), let current = selection {
            selection = min(current.lowerBound, index)..<(max(current.upperBound - 1, index) + 1)
        } else {
            selection = index..<(index + 1)
        }
    }
}

/// Hex cells have measured, fixed advances. Placing them directly avoids asking a horizontal
/// stack to resolve every text cell's flexible minimum and maximum widths during scrolling.
private struct LumenHexRowLayout: Layout {
    let widths: [CGFloat]
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: widths.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: height))
            x += width
        }
    }
}

// MARK: Commands

/// One input of a `LumenCommandField`.
public struct LumenCommandPart {
    public let text: Binding<String>
    public let prompt: String
    /// A fixed width (a register name), or `nil` to share what's left.
    public let width: CGFloat?
    public let accessibilityLabel: String

    public init(_ text: Binding<String>, prompt: String, width: CGFloat? = nil, accessibilityLabel: String? = nil) {
        self.text = text
        self.prompt = prompt
        self.width = width
        self.accessibilityLabel = accessibilityLabel ?? prompt
    }
}

/// A debugger action as one inline command: an accent verb (`expr`, `reg`, `mem`), its inputs split by hairlines, and an accent
/// button inside the capsule. Return in any input runs it. Inputs shrink before anything clips.
public struct LumenCommandField: View {
    private let verb: String
    private let parts: [LumenCommandPart]
    private let actionTitle: String
    private let isEnabled: Bool
    private let help: String?
    private let onRun: () -> Void
    private let drawsStatic: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    /// The input holding focus, if any: the field shows focus while any of its inputs has it.
    @State private var focusedPart: Int?

    /// - Parameters:
    ///   - verb: a short word for the action, drawn in the accent.
    ///   - help: why the action is unavailable, or what it does.
    public init(_ verb: String, parts: [LumenCommandPart], actionTitle: String, isEnabled: Bool = true,
                help: String? = nil, onRun: @escaping () -> Void) {
        self.init(verb, parts: parts, actionTitle: actionTitle, isEnabled: isEnabled, help: help, drawsStatic: false, onRun: onRun)
    }

    /// For golden images, where text fields can't draw.
    init(_ verb: String, parts: [LumenCommandPart], actionTitle: String, isEnabled: Bool, help: String?, drawsStatic: Bool,
         onRun: @escaping () -> Void) {
        self.verb = verb
        self.parts = parts
        self.actionTitle = actionTitle
        self.isEnabled = isEnabled
        self.help = help
        self.onRun = onRun
        self.drawsStatic = drawsStatic
    }

    private var mono: Font { (codeFont ?? .standard).font() }

    public var body: some View {
        HStack(spacing: 0) {
            Text(verb)
                .font((codeFont ?? .standard).font(weight: .semibold))
                .foregroundStyle(palette[.accent])
                .fixedSize()
                .padding(.leading, metrics.spacing.s3)
                .padding(.trailing, metrics.spacing.s2)
                .accessibilityHidden(true)
            ForEach(parts.indices, id: \.self) { index in
                if index > 0 {
                    LumenInlineDivider()
                        .padding(.horizontal, metrics.spacing.s2)
                }
                Input(part: parts[index], font: mono, isStatic: drawsStatic || rendersOffscreen, onRun: run) { isFocused in
                    if isFocused { focusedPart = index } else if focusedPart == index { focusedPart = nil }
                }
            }
            Spacer(minLength: metrics.spacing.s2)
            Button(actionTitle, action: run)
                .font(metrics.typography.body.weight(.semibold))   // 13 pt, as every one-line control's text
                .buttonStyle(Chrome())
                .disabled(!isEnabled)
                .fixedSize()
        }
        // Lumen's field chrome at the one-line control height, focused while any input is.
        .frame(height: metrics.layout.controlHeight)
        .lumenChrome(.field, focused: focusedPart != nil)
        .help(help ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(actionTitle)
    }

    /// One input: Lumen's field input (its prompt drawn by Lumen), reporting its focus to the field.
    private struct Input: View {
        let part: LumenCommandPart
        let font: Font
        let isStatic: Bool
        let onRun: () -> Void
        let onFocus: (Bool) -> Void
        @FocusState private var focused: Bool

        var body: some View {
            LumenFieldInput(text: part.text, prompt: part.prompt, font: font, focus: $focused, onSubmit: onRun)
                .environment(\.lumenRendersOffscreen, isStatic)
                .accessibilityLabel(part.accessibilityLabel)
                .frame(width: part.width, alignment: .leading)
                .frame(minWidth: 24, maxWidth: part.width == nil ? .infinity : nil, alignment: .leading)
                .onChange(of: focused) { _, value in onFocus(value) }
        }
    }

    private func run() { if isEnabled { onRun() } }

    /// The accent button inside the capsule.
    private struct Chrome: ButtonStyle {
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.isEnabled) private var isEnabled
        func makeBody(configuration: Configuration) -> some View {
            // Inset s1 inside the field's edge, so the plate never meets the field's border, and
            // nested in the field's corner: its radius less that inset and the border.
            let inset = metrics.spacing.s1 + metrics.stroke.hairline
            let shape = RoundedRectangle(cornerRadius: max(metrics.radius.sm - inset, 2), style: .continuous)
            // The tinted panel action's look (`.lumenTinted`), as the watch list's Evaluate draws it:
            // one look for one action in one view, and no border to double the field's in the
            // contrast themes. Disabled, the one disabled fade.
            configuration.label
                .foregroundStyle(palette[.fgPrimary])
                .padding(.horizontal, metrics.spacing.s4)
                .frame(height: metrics.layout.controlHeight - 2 * inset)
                .background(palette[configuration.isPressed ? .bgSelected : .accentSubtle], in: shape)
                .padding(.trailing, inset)
                .lumenDisabledFade(isEnabled)
                .contentShape(.rect)
        }
    }
}

/// What an expression came to, under its command: `= value` and its type, or the error in red.
public struct LumenEvaluationResult: View {
    private let value: String
    private let type: String?
    private let isError: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont

    public init(_ value: String, type: String? = nil, isError: Bool = false) {
        self.value = value
        self.type = type
        self.isError = isError
    }

    public var body: some View {
        Group {
            if let type, !isError {
                // Never truncated, as the watch list and variable rows show types: a tail cut loses the
                // closing generic, the part that tells types apart. The value wraps instead, and
                // where even the type doesn't fit beside it, the type wraps on its own line (LIVE-04).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s2) {
                        // Judged with the value at a few words' width: a long value wraps beside the type.
                        valueText.frame(minWidth: 0, idealWidth: 80, alignment: .leading)
                        Text(type).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary]).lineLimit(1)
                            .fixedSize().lumenNeverTruncates(type)
                    }
                    VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                        valueText
                        Text(type).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                            .lumenWrapsWithoutTruncating()
                    }
                }
            } else {
                valueText
            }
        }
        .padding(.leading, metrics.spacing.s4)
    }

    private var valueText: some View {
        Text(isError ? value : "= " + value)
            .font((codeFont ?? .standard).font(weight: .medium))
            .foregroundStyle(palette[isError ? .statusDanger : .fgPrimary])
            .textSelection(.enabled)
            .lumenWrapsWithoutTruncating()
    }
}

// MARK: Watches

/// One watch expression and, once evaluated, what it came to.
public struct LumenWatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let expression: String
    public let value: String?
    public let type: String?
    /// Why it couldn't be evaluated ("not in scope").
    public let error: String?

    public init(id: String, expression: String, value: String? = nil, type: String? = nil, error: String? = nil) {
        self.id = id
        self.expression = expression
        self.value = value
        self.type = type
        self.error = error
    }
}

/// Watch expressions as rows: a header with the count and a quiet
/// Evaluate button (its caution as a ⚠︎ and help tag, not a paragraph), then each expression with its
/// value and type at the trailing edge, errors in red, × on hover to remove, and an Add row at the end.
public struct LumenWatchList: View {
    /// The type column's least width: values end at one edge, typed or not.
    static let typeColumn: CGFloat = 52
    private let watches: [LumenWatch]
    @Binding private var newExpression: String
    private let limit: Int?
    private let canEvaluate: Bool
    private let caution: String?
    private let onEvaluate: () -> Void
    private let onAdd: (String) -> Void
    private let onRemove: (LumenWatch.ID) -> Void
    private let drawsStatic: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @State private var hovered: String?
    @Environment(\.lumenEmptyMessage) private var emptyMessage

    /// - Parameters:
    ///   - limit: the most watches allowed; Add is disabled at the limit.
    ///   - caution: shown as a ⚠︎ by Evaluate, with this as its help ("Evaluating can run code.").
    public init(_ watches: [LumenWatch], newExpression: Binding<String>, limit: Int? = nil, canEvaluate: Bool = true,
                caution: String? = nil, onEvaluate: @escaping () -> Void, onAdd: @escaping (String) -> Void,
                onRemove: @escaping (LumenWatch.ID) -> Void) {
        self.init(watches, newExpression: newExpression, limit: limit, canEvaluate: canEvaluate, caution: caution,
                  drawsStatic: false, onEvaluate: onEvaluate, onAdd: onAdd, onRemove: onRemove)
    }

    /// For golden images, where text fields can't draw.
    init(_ watches: [LumenWatch], newExpression: Binding<String>, limit: Int?, canEvaluate: Bool, caution: String?,
         drawsStatic: Bool, onEvaluate: @escaping () -> Void, onAdd: @escaping (String) -> Void,
         onRemove: @escaping (LumenWatch.ID) -> Void) {
        self.watches = watches
        _newExpression = newExpression
        self.limit = limit
        self.canEvaluate = canEvaluate
        self.caution = caution
        self.onEvaluate = onEvaluate
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.drawsStatic = drawsStatic
    }

    private var mono: Font { (codeFont ?? .standard).font() }
    private var atLimit: Bool { limit.map { watches.count >= $0 } ?? false }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s1) {
            header
            if watches.isEmpty { LumenEmptyState.inline(emptyMessage ?? "No watches yet") }
            ForEach(watches) { watch in row(watch) }
            addRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Watches")
    }

    private var header: some View {
        HStack(spacing: metrics.spacing.s2) {
            Text("Watches").font(metrics.typography.captionEmphasized).foregroundStyle(palette[.fgSecondary])
                .accessibilityAddTraits(.isHeader)
            LumenCount(watches.count)
            Spacer(minLength: metrics.spacing.s2)
            // The caution rides on Evaluate's help and hint: a warning triangle on an ordinary
            // action reads as an error state. A tinted panel action with its own plate, so at rest it
            // reads as a button, not as a third column's header over the values and types.
            Button("Evaluate", action: onEvaluate)
                .buttonStyle(.lumenTinted)
                .lumenFocusRing()
                .disabled(!canEvaluate || watches.isEmpty)
                .help(caution.map { "Evaluate the watches at this frame. \($0)" } ?? "Evaluate the watches at this frame")
                .accessibilityHint(caution ?? "")
                .fixedSize()
                // The quiet style pads its label by s2; overhang that so the word, not its plate, ends over the types.
                .padding(.trailing, -metrics.spacing.s2)
        }
        // The rows' inset, so the title starts over the expressions and Evaluate ends over the types.
        .padding(.horizontal, metrics.spacing.s2)
    }

    private func row(_ watch: LumenWatch) -> some View {
        let shown = watch.error ?? watch.value ?? "—"
        return HStack(spacing: metrics.spacing.s2) {
            LumenSemanticText(watch.expression, kind: .expression, lineLimit: 2)
                .font((codeFont ?? .standard).font(weight: LumenDebuggerType.rowNameWeight))
                .foregroundStyle(palette[.fgPrimary])
                
                .frame(minWidth: metrics.layout.watchExpressionMinWidth, alignment: .leading)
            Spacer(minLength: metrics.spacing.s2)
            LumenCodeValue(value: shown, font: mono, nativeFont: (codeFont ?? .standard).nsFont(),
                           color: palette[watch.error != nil ? .statusDanger : watch.value == nil ? .fgTertiary : .fgPrimary],
                           kind: .expression, lineLimit: 2)
                .layoutPriority(-1)
            // Types in their own column at the pane's trailing edge, so values end at one edge whatever
            // their type. On hover the remove button takes the column's place instead of reserving
            // a blank strip past it.
            ZStack(alignment: .trailing) {
                if let type = watch.type {
                    Text(type).font(.caption2).foregroundStyle(palette[.fgTertiary]).lineLimit(1)
                        .fixedSize().lumenNeverTruncates(type)
                        .opacity(hovered == watch.id ? 0 : 1)
                }
                Button { onRemove(watch.id) } label: {
                    LumenSymbol("xmark.circle.fill").font(.caption).foregroundStyle(palette[.fgTertiary])
                        .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .lumenIconOnlyControl("Remove watch")
                .opacity(hovered == watch.id ? 1 : 0)
                .help("Remove watch")
                .accessibilityLabel("Remove watch \(watch.expression)")
            }
            .frame(minWidth: Self.typeColumn, alignment: .trailing)
            .fixedSize()
        }
        .padding(.horizontal, metrics.spacing.s2)
        .frame(minHeight: density.rowHeight(in: metrics.layout))
        .background(hovered == watch.id ? palette[.bgHover].opacity(palette.key.raised ? 1 : metrics.layout.hoverOpacity) : .clear,
                    in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        .onHover { hovered = $0 ? watch.id : (hovered == watch.id ? nil : hovered) }
        .help(watch.value == nil && watch.error == nil ? "Evaluate at a stopped frame to see its value" : "\(watch.expression) = \(shown)")
        .contextMenu { Button("Remove Watch") { onRemove(watch.id) } }
    }

    private var addRow: some View {
        HStack(spacing: metrics.spacing.s2) {
            LumenSymbol("plus").font(.caption.weight(.semibold)).foregroundStyle(palette[atLimit ? .fgTertiary : .accent])
                .accessibilityHidden(true)
            if drawsStatic {
                Text(newExpression.isEmpty ? "Add watch" : newExpression).font(metrics.typography.callout)
                    .foregroundStyle(palette[newExpression.isEmpty ? .fgTertiary : .fgPrimary])
                Spacer(minLength: 0)
            } else {
                TextField("Add watch", text: $newExpression,
                          prompt: Text(atLimit ? "Watch limit reached" : "Add watch").foregroundStyle(palette[.fgTertiary]))
                    .textFieldStyle(.plain)
                    .font(newExpression.isEmpty ? metrics.typography.callout : mono)
                    .foregroundStyle(palette[.fgPrimary])
                    .disabled(atLimit)
                    .onSubmit {
                        let expression = newExpression.trimmingCharacters(in: .whitespaces)
                        guard !expression.isEmpty, !atLimit else { return }
                        newExpression = ""
                        onAdd(expression)
                    }
                    .accessibilityLabel("New watch expression")
            }
        }
        .padding(.horizontal, metrics.spacing.s2)
        .frame(minHeight: density.rowHeight(in: metrics.layout))
    }
}

// MARK: Variables

/// One variable in a flattened tree (the app keeps the tree; each row knows its depth).
public struct LumenVariable: Identifiable, Hashable, Sendable {
    /// Whether and how a variable's children show.
    public enum Disclosure: Sendable, Hashable {
        /// No children.
        case none
        case collapsed
        case expanded
        /// Its children are being fetched.
        case loading
        /// Fetching its children failed; toggling retries.
        case failed
    }

    public let id: String
    public let depth: Int
    public let name: String
    public let type: String?
    /// The value, or what went wrong reading it.
    public let value: String
    public let disclosure: Disclosure
    /// Whether the value changed since the last stop.
    public let changed: Bool
    /// Why its children can't be fetched now, shown as help with the chevron disabled.
    public let toggleDisabledReason: String?

    public init(id: String, depth: Int = 0, name: String, type: String? = nil, value: String,
                disclosure: Disclosure = .none, changed: Bool = false, toggleDisabledReason: String? = nil) {
        self.id = id
        self.depth = depth
        self.name = name
        self.type = type
        self.value = value
        self.disclosure = disclosure
        self.changed = changed
        self.toggleDisabledReason = toggleDisabledReason
    }
}

/// A titled group of variables (Locals, Arguments, Globals).
public struct LumenVariableSection: Identifiable, Sendable {
    public let title: String
    public let variables: [LumenVariable]
    /// Shown when there are none ("No locals in this frame.").
    public let emptyMessage: String?
    /// Shown under the rows when the list was cut short ("Showing the first 200.").
    public let truncationMessage: String?
    public var id: String { title }

    public init(_ title: String, variables: [LumenVariable], emptyMessage: String? = nil, truncationMessage: String? = nil) {
        self.title = title
        self.variables = variables
        self.emptyMessage = emptyMessage
        self.truncationMessage = truncationMessage
    }
}

/// One row of a variables tree: guide lines for its depth, a chevron
/// (a spinner while loading, a red retry arrow after a failure), the name, its type quietly after it,
/// and the value at the trailing edge, in the accent when it changed, red when it couldn't be read.
/// On its own, a narrow row drops its type whole (never a sliver), then shortens a long name (short
/// ones stay whole), then the value. In a `LumenVariableTree` the types are one column for all rows,
/// shown or dropped together.
public struct LumenVariableRow: View {
    /// Where the row puts its type.
    enum TypeLayout: Equatable {
        /// After the name, whole or not at all (a row on its own).
        case inline
        /// In a column starting `nameColumn` points from the row's leading edge (a tree's rows).
        case column(nameColumn: CGFloat)
        /// Not shown (a tree too narrow for the type column); the help tag has it.
        case hidden
    }

    private let variable: LumenVariable
    private let onToggle: () -> Void
    private let typeLayout: TypeLayout

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont

    public init(_ variable: LumenVariable, onToggle: @escaping () -> Void = {}) {
        self.init(variable, typeLayout: .inline, onToggle: onToggle)
    }

    init(_ variable: LumenVariable, typeLayout: TypeLayout, onToggle: @escaping () -> Void = {}) {
        self.variable = variable
        self.typeLayout = typeLayout
        self.onToggle = onToggle
    }

    /// The width of one depth level's guide line.
    static func guideWidth(_ metrics: LumenMetrics) -> CGFloat { metrics.stroke.hairline + 15 }
    /// The disclosure's layout width (its hit area overhangs it).
    static let disclosureWidth: CGFloat = 16

    private var nameFont: Font { (codeFont ?? .standard).font(weight: LumenDebuggerType.rowNameWeight) }
    /// Types in the code font, a size down, so they read as code beside the names.
    private var typeFont: Font { (codeFont ?? .standard).font(sizeDelta: -1) }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            switch typeLayout {
            case .inline:
                leading
                if let type = variable.type {
                    // Whole or not at all: a sliver of a type reads as noise. The help tag has it.
                    ViewThatFits(in: .horizontal) {
                        typeText(type)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .layoutPriority(-1)
                }
            case .column(let nameColumn):
                leading.frame(width: nameColumn, alignment: .leading)
                if let type = variable.type { typeText(type) }
            case .hidden:
                leading
            }
            Spacer(minLength: metrics.spacing.s2)
            LumenCodeValue(value: variable.value, font: (codeFont ?? .standard).font(),
                           nativeFont: (codeFont ?? .standard).nsFont(), color: palette[valueTone],
                           kind: .expression, lineLimit: 2)
                .layoutPriority(1)
        }
        .frame(minHeight: density.rowHeight(in: metrics.layout))
        .help([variable.name, variable.type].compactMap(\.self).joined(separator: ": ") + " = " + variable.value)
        // `.combine` with selectable text can recurse; one explicit element, its toggle as an action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: Text(toggleHelp)) { if isToggleable { onToggle() } }
    }

    /// The guides, the disclosure and the name.
    private var leading: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(variable.depth, 0), id: \.self) { _ in
                Rectangle().fill(palette[.borderSubtle]).frame(width: metrics.stroke.hairline)
                    .padding(.leading, 5).padding(.trailing, 10)
                    .accessibilityHidden(true)
            }
            disclosure
            LumenSemanticText(variable.name, kind: .symbol)
                .font(nameFont)
                .foregroundStyle(palette[.fgPrimary])
                
                // Short names (most locals) never shorten: "c…he" reads worse than a shortened value.
                .fixedSize(horizontal: variable.name.count <= 10, vertical: false)
                .frame(minWidth: metrics.layout.variableNameMinWidth, alignment: .leading)
                .padding(.leading, metrics.spacing.s2)
        }
    }

    private func typeText(_ type: String) -> some View {
        Text(type).font(typeFont).foregroundStyle(palette[.fgTertiary]).lineLimit(1).fixedSize().lumenNeverTruncates(type)
    }

    private var isToggleable: Bool {
        switch variable.disclosure {
        case .collapsed: variable.toggleDisabledReason == nil
        case .expanded, .failed: true
        case .none, .loading: false
        }
    }

    private var valueTone: LumenToken {
        switch variable.disclosure {
        case .failed: .statusDanger
        case .loading: .fgTertiary
        default: variable.changed ? .accent : .fgPrimary
        }
    }

    @ViewBuilder private var disclosure: some View {
        Group {
            switch variable.disclosure {
            case .none:
                Color.clear
            case .loading:
                // Lumen's ring: the native spinner draws blank offscreen and is a second spinner look.
                LumenProgressRing(progress: nil).frame(width: Self.disclosureWidth - 4, height: Self.disclosureWidth - 4)
            case .collapsed, .expanded, .failed:
                Button(action: onToggle) {
                    LumenSymbol(variable.disclosure == .failed ? "arrow.clockwise"
                                : variable.disclosure == .expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: metrics.layout.disclosureGlyph, weight: .bold))
                        .foregroundStyle(palette[variable.disclosure == .failed ? .statusDanger : .fgSecondary])
                        .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.lumenBare)
                .lumenIconOnlyControl(toggleHelp)
                // The full hit area, laid out in the 16 pt slot: it no longer pushes into the guides and name.
                .padding(-(metrics.layout.minimumHitTarget - Self.disclosureWidth) / 2)
                .disabled(variable.toggleDisabledReason != nil && variable.disclosure == .collapsed)
                .lumenDisabledFade(!(variable.toggleDisabledReason != nil && variable.disclosure == .collapsed))
                .help(variable.toggleDisabledReason ?? toggleHelp)
                .accessibilityLabel(toggleHelp)
            }
        }
        .frame(width: Self.disclosureWidth, height: Self.disclosureWidth)
    }

    private var toggleHelp: String {
        switch variable.disclosure {
        case .expanded: "Collapse \(variable.name)"
        case .failed: "Retry loading \(variable.name)"
        default: "Expand \(variable.name)"
        }
    }

    private var accessibilityText: String {
        var parts = [variable.name]
        if let type = variable.type { parts.append(type) }
        parts.append(variable.value)
        if variable.changed { parts.append("changed") }
        if variable.depth > 0 { parts.append("level \(variable.depth + 1)") }
        return parts.joined(separator: ", ")
    }
}

/// A frame's variables as an outline: each section under a small
/// uppercase header, its rows (`LumenVariableRow`), and a quiet line when it's empty or cut short.
/// Types are one column, aligned across every row; when the tree is too narrow to keep it and still
/// leave each value room, the whole column drops (never row by row), and each row's help tag has
/// its type. Put it in the pane's scroll view.
public struct LumenVariableTree: View {
    private let sections: [LumenVariableSection]
    private let onToggle: (LumenVariable) -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont

    /// The room each value keeps beside the type column before the column drops.
    static let valueRoom: CGFloat = 72
    /// The widest a name column grows; longer names shorten in the middle inside it.
    static let maximumNameColumn: CGFloat = 180
    /// The space the name column keeps after its longest name, on top of the row's s2 spacing,
    /// so a name and its type are never closer than s5.
    static func columnGutter(_ metrics: LumenMetrics) -> CGFloat { metrics.spacing.s5 - metrics.spacing.s2 }

    public init(_ sections: [LumenVariableSection], onToggle: @escaping (LumenVariable) -> Void = { _ in }) {
        self.sections = sections
        self.onToggle = onToggle
    }

    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @State private var measuredWidth: CGFloat?
    /// The type column, measured once per change of sections, metrics or code font (PERF-03).
    @State private var cache = LumenVariableTreeCache()

    /// The type column's leading x and the width the tree needs to show it.
    static func typeColumn(for variables: [LumenVariable], metrics: LumenMetrics, codeFont: LumenCodeFont)
        -> (nameColumn: CGFloat, requiredWidth: CGFloat)? {
        let typed = variables.filter { $0.type != nil }
        guard !typed.isEmpty else { return nil }
        let nameFont = codeFont.nsFont(weight: .medium)
        let typeFont = codeFont.nsFont(sizeDelta: -1)
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let leading = variables.map {
            CGFloat(max($0.depth, 0)) * LumenVariableRow.guideWidth(metrics) + LumenVariableRow.disclosureWidth
                + metrics.spacing.s2 + width($0.name, nameFont)
        }.max() ?? 0
        // The gutter keeps the longest (often the deepest) name clear of the types: the row's own
        // s2 spacing alone left "magicUInt32" reading as one token.
        let nameColumn = min(leading, maximumNameColumn) + columnGutter(metrics)
        let types = typed.map { width($0.type ?? "", typeFont) }.max() ?? 0
        return (nameColumn, nameColumn + metrics.spacing.s2 + types + metrics.spacing.s2 * 2 + valueRoom)
    }

    public var body: some View {
        let column = cache.typeColumn(sections, metrics: metrics, codeFont: codeFont ?? .standard)
        if let column, rendersOffscreen {
            // One rule for the column: the whole tree with types, or the whole tree without.
            ViewThatFits(in: .horizontal) {
                outline(.column(nameColumn: column.nameColumn))
                    .frame(idealWidth: column.requiredWidth, maxWidth: .infinity, alignment: .leading)
                outline(.hidden)
            }
        } else if let column {
            // The same rule from the measured width, so only one outline is ever built (PERF-03:
            // `ViewThatFits` built both); before the first measurement, the ideal (typed) width.
            Group {
                if (measuredWidth ?? .infinity) >= column.requiredWidth {
                    // No minimum of its own: as with `ViewThatFits`, the narrower (untyped) outline is
                    // what the pane can shrink to, and a narrower measured width switches to it.
                    outline(.column(nameColumn: column.nameColumn))
                        .frame(minWidth: 0, idealWidth: column.requiredWidth, maxWidth: .infinity, alignment: .leading)
                } else {
                    outline(.hidden)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        } else {
            outline(.hidden)
        }
    }

    private func outline(_ layout: LumenVariableRow.TypeLayout) -> some View {
        // Lazy in the app's scroll view once there are many rows (PERF-03: a 1,000-element array built
        // every row up front). Offscreen renders, and the `ViewThatFits` they use, need every row: eager.
        LumenLazyVStack(eager: rendersOffscreen || sections.reduce(0, { $0 + $1.variables.count }) <= LumenLazyVStack<EmptyView>.eagerLimit,
                        alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                Text(section.title)
                    .lumenSectionLabel()
                    .padding(.top, metrics.spacing.s3).padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                if section.variables.isEmpty, let empty = section.emptyMessage {
                    // The inline empty state, leading under the section label.
                    LumenEmptyState.inline(empty, leading: true, padding: 2)
                }
                ForEach(section.variables) { variable in
                    LumenVariableRow(variable, typeLayout: layout) { onToggle(variable) }
                }
                if let truncation = section.truncationMessage {
                    note(truncation)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
            .lumenWrapsWithoutTruncating()
            .padding(.vertical, metrics.spacing.s2)
    }
}

/// `LumenVariableTree.typeColumn`, kept between body evaluations: it measures every name and type.
/// Holding the sections it last saw means an app's new sections always arrive in new storage.
@MainActor final class LumenVariableTreeCache {
    private var sections: [LumenVariableSection]?
    private var metrics: LumenMetrics?
    private var codeFont: LumenCodeFont?
    private var column: (nameColumn: CGFloat, requiredWidth: CGFloat)?
    /// How many times the column was measured, for tests.
    private(set) var measurements = 0

    func typeColumn(_ sections: [LumenVariableSection], metrics: LumenMetrics, codeFont: LumenCodeFont)
        -> (nameColumn: CGFloat, requiredWidth: CGFloat)? {
        if let cached = self.sections, lumenSameStorage(cached, sections), self.metrics == metrics, self.codeFont == codeFont {
            return column
        }
        column = LumenVariableTree.typeColumn(for: sections.flatMap(\.variables), metrics: metrics, codeFont: codeFont)
        self.sections = sections
        self.metrics = metrics
        self.codeFont = codeFont
        measurements += 1
        return column
    }
}

/// Whether two arrays share storage, so nothing in them can differ. A cache that keeps the array
/// it last saw makes this exact: the owner's next change to its copy has to copy the storage.
func lumenSameStorage<Element>(_ a: [Element], _ b: [Element]) -> Bool {
    a.count == b.count && a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
}
