import AppKit
import SwiftUI
import LumenTokens

// A code pane's status strip and gutter, chosen for MacScope's pseudocode.

// MARK: Status strip

/// A state shown in a status strip: a colored dot and a word ("Ready", "Decompiling").
public struct LumenStripStatus: Hashable, Sendable {
    public let title: String
    public let tone: LumenToken
    /// What VoiceOver says for the status, when the word alone is too terse; `nil` uses the title.
    public var spokenLabel: String?
    /// Detail VoiceOver reads after the label ("12 of 40 functions").
    public var spokenValue: String?
    /// Set on the status, for UI tests.
    public var accessibilityIdentifier: String?

    /// - Parameter tone: `.statusSuccess`, `.statusWarning`, `.statusDanger`, `.statusInfo` or `.fgTertiary`.
    public init(_ title: String, tone: LumenToken) {
        self.title = title
        self.tone = tone
    }

    /// - Parameters:
    ///   - spokenLabel: what VoiceOver says instead of the title.
    ///   - spokenValue: detail VoiceOver reads after the label.
    ///   - accessibilityIdentifier: set on the status, for UI tests.
    public init(_ title: String, tone: LumenToken, spokenLabel: String? = nil, spokenValue: String? = nil,
                accessibilityIdentifier: String?) {
        self.init(title, tone: tone)
        self.spokenLabel = spokenLabel
        self.spokenValue = spokenValue
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// A warning or note in a status strip ("Truncated", "Fallback"): a tinted capsule with a help tag.
public struct LumenStripChip: Identifiable, Hashable, Sendable {
    public let title: String
    public let tone: LumenToken
    public let help: String?
    public var id: String { title }

    public init(_ title: String, tone: LumenToken = .statusWarning, help: String? = nil) {
        self.title = title
        self.tone = tone
        self.help = help
    }
}

/// The strip over a code pane: a leading control (a
/// `LumenModeSwitcher(style: .pill)` for the source), the status as a dot and a word, warning chips,
/// and icon-only commands at the trailing edge. When narrow, the chips fold into one menu (a capsule
/// with their count, each chip and its help inside), then the status word shortens last; nothing is
/// hidden to fit (PRINCIPLES §6).
public struct LumenStatusStrip<Leading: View>: View {
    private let status: LumenStripStatus?
    private let chips: [LumenStripChip]
    private let actions: [LumenBarAction]
    private let leading: Leading

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter actions: commands, drawn as their glyphs with the title as help; give each a `systemImage`.
    public init(status: LumenStripStatus? = nil, chips: [LumenStripChip] = [], actions: [LumenBarAction] = [],
                @ViewBuilder leading: () -> Leading) {
        self.status = status
        self.chips = chips
        self.actions = actions
        self.leading = leading()
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s3) {
            leading.fixedSize()
            ViewThatFits(in: .horizontal) {
                middle(.chips, statusShortens: false)
                middle(.menu, statusShortens: false)
                middle(.compactMenu, statusShortens: false)
                middle(.compactMenu, statusShortens: true)
            }
            actionButtons
        }
        // Symmetric insets: the switcher sits as far from the leading edge as the commands from the trailing one.
        .padding(.horizontal, metrics.spacing.s4)
        .frame(minHeight: metrics.layout.paneHeaderHeight)
        // An explicit rectangle: a bare color background takes the card's corner shape at its own
        // corners, leaving wedges where the divider meets the card's hairline.
        .background(palette[.bgCanvas], in: Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityValue(([status?.title] + chips.map(\.title)).compactMap(\.self).joined(separator: ", "))
    }

    /// How the chips show: each as a capsule, folded into one menu, or that menu as a glyph and count.
    private enum ChipFold { case chips, menu, compactMenu }

    private func middle(_ fold: ChipFold, statusShortens: Bool) -> some View {
        HStack(spacing: metrics.spacing.s2) {
            if let status {
                HStack(spacing: metrics.spacing.s1) {
                    Circle().fill(palette[status.tone]).frame(width: metrics.layout.statusDot, height: metrics.layout.statusDot)
                    Text(status.title).font(metrics.typography.caption.weight(.semibold))
                        .foregroundStyle(palette[.fgSecondary]).lineLimit(1)
                        .truncationMode(.tail).help(status.title)   // shortens only as the strip's last resort
                        .fixedSize(horizontal: !statusShortens, vertical: false)
                }
                .layoutPriority(-1)
                .help(status.title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status.spokenLabel ?? status.title)
                .accessibilityValue(status.spokenValue ?? "")
                .lumenAccessibilityIdentifier(status.accessibilityIdentifier)
            }
            Spacer(minLength: metrics.spacing.s2)
            if fold != .chips, !chips.isEmpty {
                chipMenu(compact: fold == .compactMenu)
            } else {
                ForEach(chips) { chip in
                    chipCapsule(chip.title, tone: chip.tone).help(chip.help ?? chip.title)
                }
            }
        }
    }

    private func chipCapsule(_ title: String, tone: LumenToken, symbol: String? = nil, menu: Bool = false) -> some View {
        HStack(spacing: metrics.spacing.s1) {
            if let symbol { LumenSymbol(symbol).font(.system(size: metrics.iconSize.micro, weight: .semibold)).accessibilityHidden(true) }
            if !title.isEmpty { Text(title).font(metrics.typography.captionEmphasized) }
            if menu { LumenSymbol("chevron.down").font(.system(size: metrics.iconSize.micro, weight: .bold)).accessibilityHidden(true) }
        }
        .foregroundStyle(palette[tone])
        .lumenChip(palette.toneBackground(tone))   // the one chip spec
        .fixedSize()
    }

    /// The chips as one menu: a capsule in the most urgent chip's tone, with the only chip's title or
    /// their count (compact: the tone's glyph, and the count when there are several), listing each chip
    /// and its help.
    private func chipMenu(compact: Bool) -> some View {
        let tone = Self.urgent(chips.map(\.tone))
        let title = compact ? (chips.count > 1 ? "\(chips.count)" : "") : chips.count == 1 ? chips[0].title : "\(chips.count) notes"
        return LumenMenuButton(help: chips.map { $0.help ?? $0.title }.joined(separator: " · ")) {
            ForEach(chips) { chip in
                Button { } label: { Text(chip.help.map { "\(chip.title) — \($0)" } ?? chip.title) }
                    .disabled(true)
            }
        } label: {
            chipCapsule(title, tone: tone, symbol: compact ? Self.symbol(for: tone) : nil, menu: true)
        }
        .accessibilityLabel(chips.map(\.title).joined(separator: ", "))
    }

    /// A tone's glyph: error is the octagon (Lumen's one danger glyph), warning a triangle, anything else an info circle.
    static func symbol(for tone: LumenToken) -> String {
        switch tone {
        case .statusDanger: "xmark.octagon.fill"
        case .statusWarning: "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    /// The most urgent of several tones: danger, then warning, then info, then the rest.
    static func urgent(_ tones: [LumenToken]) -> LumenToken {
        for tone in [LumenToken.statusDanger, .statusWarning, .statusInfo, .statusSuccess] where tones.contains(tone) { return tone }
        return tones.first ?? .fgTertiary
    }

    private var actionButtons: some View {
        HStack(spacing: metrics.spacing.s1) {
            ForEach(actions) { action in
                Button(action: action.perform) {
                    LumenSymbol(action.systemImage ?? "circle").font(.system(size: metrics.layout.paneActionGlyph))
                }
                .buttonStyle(.lumenPanelIcon)   // a pane's icon button, in the content's ink: the strip isn't the toolbar
                .lumenIconOnlyControl(action.title)
                .lumenFocusRing()
                .disabled(!action.isEnabled)
                .help(action.help ?? action.title)
                .accessibilityLabel(action.title)
                .lumenAccessibilityIdentifier(action.accessibilityIdentifier)
            }
        }
        .fixedSize()
    }
}

// MARK: Code listing

/// A run of code text in one syntax role (`LumenToken.Code.keyword`, …).
public struct LumenCodeRun: Hashable, Sendable {
    public let text: String
    public let token: LumenToken

    public init(_ text: String, _ token: LumenToken = LumenToken.Code.variable) {
        self.text = text
        self.token = token
    }
}

/// Read-only code with a line-number gutter and the current line tinted (the code pack's
/// `code.lineNumber` and `code.currentLine`), for short listings in SwiftUI. Long documents belong in
/// a text view with `LumenLineNumberRuler`. Past 200 lines they build lazily in the pane's scroll
/// view, so a long listing costs only the lines on screen. Needs the code pack in the registry.
public struct LumenCodeListing: View {
    private let lines: [[LumenCodeRun]]
    private let currentLine: Int?
    private let firstLineNumber: Int

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    /// - Parameter currentLine: the zero-based index of the line to tint.
    public init(_ lines: [[LumenCodeRun]], currentLine: Int? = nil, firstLineNumber: Int = 1) {
        self.lines = lines
        self.currentLine = currentLine
        self.firstLineNumber = firstLineNumber
    }

    private var size: CGFloat { (codeFont ?? .standard).size }

    public var body: some View {
        let digits = max(2, String(firstLineNumber + lines.count - 1).count)
        // Lazy in the pane's scroll view once there are many lines, so a 1,000-line disassembly builds
        // the lines on screen (PERF-08); offscreen renders draw every line in one pass.
        LumenLazyVStack(eager: rendersOffscreen || lines.count <= LumenLazyVStack<EmptyView>.eagerLimit, alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let isCurrent = index == currentLine
                HStack(spacing: 0) {
                    Text(verbatim: String(firstLineNumber + index))
                        .font((codeFont ?? .standard).font(sizeDelta: -1))
                        .foregroundStyle(palette[isCurrent ? .fgSecondary : LumenToken.Code.lineNumber])
                        .frame(width: CGFloat(digits) * (codeFont ?? .standard).digitAdvance + 4, alignment: .trailing)
                        .padding(.trailing, 10)
                        .accessibilityHidden(true)
                    lines[index].reduce(Text(verbatim: "")) { $0 + Text(verbatim: $1.text).foregroundColor(palette[$1.token]) }
                        .font((codeFont ?? .standard).font())
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .frame(height: ceil(size * 1.55))
                // Full-bleed and square (explicit rectangles; a bare color rounds to its container's corners).
                .background(isCurrent ? palette[LumenToken.Code.currentLine] : .clear, in: Rectangle())
            }
        }
        .padding(.vertical, metrics.spacing.s4)
        .background(palette[.bgCanvas], in: Rectangle())
    }
}

// MARK: AppKit gutter

/// A line-number gutter for a code `NSTextView` (MacScope's pseudocode view): numbers in
/// `code.lineNumber`, the current line's number brighter on a `code.currentLine` band. Install with
/// `LumenLineNumberRuler.install(on:palette:)`; set `palette` again when the theme changes. Pair it with
/// `LumenLineNumberRuler.drawCurrentLine(in:color:)` in the text view's `drawBackground(in:)`.
@MainActor
public final class LumenLineNumberRuler: NSRulerView {
    public var palette: LumenResolvedPalette { didSet { needsDisplay = true } }
    /// Lines (zero-based) with a breakpoint: a filled accent tag under the number.
    public var breakpoints: Set<Int> = [] { didSet { needsDisplay = true } }
    /// Lines whose breakpoint is off: an outlined tag.
    public var disabledBreakpoints: Set<Int> = [] { didSet { needsDisplay = true } }
    /// Called with the line (zero-based) when its number is clicked; set it to toggle breakpoints.
    public var onClickLine: ((Int) -> Void)?
    /// Builds the right-click menu for a line, or `nil` for none (Edit/Disable/Delete Breakpoint).
    public var menuForLine: ((Int) -> NSMenu?)?
    private(set) var lineStarts: [Int] = [0]
    private weak var textView: NSTextView?

    public init(textView: NSTextView, palette: LumenResolvedPalette) {
        self.palette = palette
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        recountLines()
        let center = NotificationCenter.default
        if let storage = textView.textStorage {
            center.addObserver(self, selector: #selector(textDidChange), name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        center.addObserver(self, selector: #selector(selectionDidChange), name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Puts a ruler on `textView`'s scroll view and shows it.
    @discardableResult
    public static func install(on textView: NSTextView, palette: LumenResolvedPalette) -> LumenLineNumberRuler {
        let ruler = LumenLineNumberRuler(textView: textView, palette: palette)
        if let scrollView = textView.enclosingScrollView {
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }
        return ruler
    }

    /// Tints the line holding the insertion point. Call from the text view's `drawBackground(in:)`.
    public static func drawCurrentLine(in textView: NSTextView, color: NSColor) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              textView.selectedRange().length == 0 else { return }
        let string = textView.string as NSString
        let location = min(textView.selectedRange().location, string.length)
        let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        if glyphs.length == 0 { rect = layoutManager.extraLineFragmentRect }
        rect.origin.x = 0
        rect.size.width = textView.bounds.width
        rect.origin.y += textView.textContainerOrigin.y
        color.setFill()
        rect.fill()
    }

    /// The zero-based line holding character `index`.
    func line(at index: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func recountLines() {
        let string = (textView?.string ?? "") as NSString
        var starts = [0]
        var index = 0
        while index < string.length {
            let range = string.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < string.length || (index == string.length && string.length > 0
                && string.character(at: string.length - 1) == 10) {
                starts.append(index)
            }
        }
        lineStarts = starts
        let digits = max(2, String(starts.count).count)
        let font = numberFont
        ruleThickness = ceil(CGFloat(digits) * font.maximumAdvancement.width + 18)
        needsDisplay = true
    }

    @objc private func textDidChange(_ note: Notification) { recountLines() }
    @objc private func selectionDidChange(_ note: Notification) { needsDisplay = true }

    private var numberFont: NSFont {
        let size = max(9, (textView?.font?.pointSize ?? 12) - 1)
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// The breakpoint tag: a rounded rectangle with a point on its trailing side.
    static func breakpointPath(in rect: NSRect) -> NSBezierPath {
        let point = min(rect.height / 2, 6)
        let radius = min(3, rect.height / 4)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - point, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX - point, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.maxY - radius), radius: radius)
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.close()
        return path
    }

    /// The zero-based line at a point in the ruler, or `nil` past the text.
    func line(atRulerPoint point: NSPoint) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        var inText = convert(point, to: textView)
        inText.x = textView.textContainerOrigin.x + 1
        inText.y -= textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: inText, in: container)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard inText.y <= fragment.maxY else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return line(at: character)
    }

    public override func mouseDown(with event: NSEvent) {
        guard let onClickLine, let line = line(atRulerPoint: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onClickLine(line)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let menuForLine, let line = line(atRulerPoint: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuForLine(line)
    }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor(palette[.bgCanvas]).setFill()
        rect.fill()
        let string = textView.string as NSString
        let currentLine = line(at: min(textView.selectedRange().location, string.length))
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let origin = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        let font = numberFont
        var lastLine = -1
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { [self] fragment, _, _, glyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = self.line(at: character)
            guard line != lastLine else { return }
            lastLine = line
            let y = origin + fragment.minY
            let isCurrent = line == currentLine
            if isCurrent {
                NSColor(palette[LumenToken.Code.currentLine]).setFill()
                NSRect(x: 0, y: y, width: ruleThickness, height: fragment.height).fill()
            }
            let hasBreakpoint = breakpoints.contains(line)
            let disabled = hasBreakpoint && disabledBreakpoints.contains(line)
            if hasBreakpoint {
                let tag = Self.breakpointPath(in: NSRect(x: 3, y: y + 1, width: ruleThickness - 5, height: max(fragment.height - 2, 8)))
                if disabled {
                    // Off: an outlined tag, as `LumenBreakpointMarker` draws it, so its number stays legible.
                    NSColor(palette[.accent]).setStroke()
                    tag.lineWidth = 1
                    tag.stroke()
                } else {
                    NSColor(palette[.accentFilled]).setFill()
                    tag.fill()
                }
            }
            let label = String(line + 1) as NSString
            let ink: LumenToken = hasBreakpoint ? (disabled ? .fgSecondary : .accentFilledForeground)
                : isCurrent ? .fgSecondary : LumenToken.Code.lineNumber
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(palette[ink]),
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
        }
    }
}
