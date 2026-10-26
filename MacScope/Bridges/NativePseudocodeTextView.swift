import AppKit
import SwiftUI
import LumenTokens
import LumenUI

struct NativePseudocodeSourceRangeChooser: Equatable, Sendable {
    static let maximumSummaryBytes = 256

    let count: Int
    let summary: String
    let selectedRange: NativeDecompilerWireSourceRange? = nil
    private let ranges: [NativeDecompilerWireSourceRange]

    init(ranges: [NativeDecompilerWireSourceRange]) {
        self.ranges = ranges
        count = ranges.count
        let addresses = ranges.prefix(8).map {
            "\(Self.compactHex($0.startAddress.value))–\(Self.compactHex($0.endAddressExclusive.value))"
        }
        let omitted = ranges.count - addresses.count
        let suffix = omitted > 0 ? "; \(omitted) more" : ""
        let candidate = "\(ranges.count) source ranges: \(addresses.joined(separator: "; "))\(suffix)"
        summary = Self.boundedASCII(candidate)
    }

    func range(at index: Int) -> NativeDecompilerWireSourceRange? {
        guard ranges.indices.contains(index) else { return nil }
        return ranges[index]
    }

    private static func boundedASCII(_ value: String) -> String {
        guard value.utf8.count > maximumSummaryBytes else { return value }
        let prefix = value.utf8.prefix(maximumSummaryBytes - 3)
        return String(decoding: prefix, as: UTF8.self) + "..."
    }

    private static func compactHex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: false)
    }
}

enum NativePseudocodeSourceAction: Equatable, Sendable {
    case navigate(NativeDecompilerWireSourceRange)
    case choose(NativePseudocodeSourceRangeChooser)
}

struct NativePseudocodeSourceRequest: Equatable, Sendable {
    let tokenID: String
    let action: NativePseudocodeSourceAction
}

struct NativePseudocodeEntityDetail: Equatable, Sendable {
    let tokenID: String
    let entityID: String
    let kind: NativeDecompilerWireTokenEntityKind
    let value: String
    let isReadOnly = true
}

struct NativePseudocodeTokenInteraction: Equatable, Sendable {
    let tokenID: String
    let isHovered: Bool
    let isFocused: Bool
    let isSelected: Bool
    let showsFocusRing: Bool
    let keyboardAction: NativePseudocodeSourceAction?
    let entityDetails: [NativePseudocodeEntityDetail]
    var valueActionsAvailable = false
}

enum NativePseudocodeInteractionProjection {
    static let maximumEntityDetails = 8

    static func sourceAction(
        for run: NativeDecompilerDocumentTokenRun
    ) -> NativePseudocodeSourceAction? {
        let ranges = uniqueSortedRanges(run.sourceRanges)
        switch ranges.count {
        case 0:
            return nil
        case 1:
            return .navigate(ranges[0])
        default:
            return .choose(NativePseudocodeSourceRangeChooser(ranges: ranges))
        }
    }

    static func entityDetails(
        for run: NativeDecompilerDocumentTokenRun
    ) -> [NativePseudocodeEntityDetail] {
        var unique: [NativeDecompilerWireTokenEntityReference] = []
        for reference in run.entityReferences where !unique.contains(reference) {
            unique.append(reference)
        }
        unique.sort {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.id < $1.id
        }
        let total = unique.count
        return unique.prefix(maximumEntityDetails).enumerated().map { offset, reference in
            NativePseudocodeEntityDetail(
                tokenID: run.tokenID,
                entityID: reference.id,
                kind: reference.kind,
                value: "\(entityKindLabel(reference.kind)) reference \(offset + 1) of \(total)"
            )
        }
    }

    static func project(
        document: NativeDecompilerDocumentProjection,
        scalarOffset: Int,
        isHovered: Bool,
        isFocused: Bool,
        isSelected: Bool
    ) -> NativePseudocodeTokenInteraction? {
        guard scalarOffset >= 0,
              let run = document.tokenRuns.first(where: { run in
                  let end = run.scalarOffset.addingReportingOverflow(run.scalarLength)
                  return !end.overflow
                      && scalarOffset >= run.scalarOffset
                      && scalarOffset < end.partialValue
              }) else { return nil }
        return NativePseudocodeTokenInteraction(
            tokenID: run.tokenID,
            isHovered: isHovered,
            isFocused: isFocused,
            isSelected: isSelected,
            showsFocusRing: isFocused,
            keyboardAction: sourceAction(for: run),
            entityDetails: entityDetails(for: run),
            valueActionsAvailable: run.entityReferences.contains { reference in
                switch reference.kind {
                case .variable, .varnode, .operation, .instruction, .call: true
                case .block, .region, .type: false
                }
            }
        )
    }

    private static func uniqueSortedRanges(
        _ input: [NativeDecompilerWireSourceRange]
    ) -> [NativeDecompilerWireSourceRange] {
        var result: [NativeDecompilerWireSourceRange] = []
        for range in input where !result.contains(range) {
            result.append(range)
        }
        result.sort {
            if $0.imageID != $1.imageID { return $0.imageID < $1.imageID }
            if $0.startAddress.value != $1.startAddress.value {
                return $0.startAddress.value < $1.startAddress.value
            }
            return $0.endAddressExclusive.value < $1.endAddressExclusive.value
        }
        return result
    }

    private static func entityKindLabel(
        _ kind: NativeDecompilerWireTokenEntityKind
    ) -> String {
        switch kind {
        case .block: "Block"
        case .call: "Call"
        case .instruction: "Instruction"
        case .operation: "Operation"
        case .region: "Region"
        case .type: "Type"
        case .variable: "Variable"
        case .varnode: "Varnode"
        }
    }
}

struct NativePseudocodeAccessibleLine: Equatable, Sendable {
    let lineNumber: Int
    let text: String

    var identifier: String {
        NativeDecompilerAccessibilityIdentifiers.documentLine(lineNumber)
    }
}

extension NativePseudocodeSourceAction {
    var accessibilityIdentifier: String {
        switch self {
        case .navigate:
            NativeDecompilerAccessibilityIdentifiers.tokenSourceAction
        case .choose:
            NativeDecompilerAccessibilityIdentifiers.tokenSourceChooser
        }
    }
}

extension NativePseudocodeEntityDetail {
    var accessibilityIdentifier: String {
        NativeDecompilerAccessibilityIdentifiers.tokenEntityDetail
    }
}

@MainActor
final class NativePseudocodeNSTextView: NSTextView {
    private(set) var documentProjection: NativeDecompilerDocumentProjection?
    private(set) var accessibleLines: [NativePseudocodeAccessibleLine] = []
    var onSourceAction: ((NativePseudocodeSourceRequest) -> Void)?
    var onEntityDetail: ((NativePseudocodeEntityDetail) -> Void)?
    var onValueAction: ((NativePseudocodeValueRequest) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Lumen's current-line tint (U2-pseudocode, "A · Quiet strip + gutter").
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        DSCodeGutter.drawCurrentLine(in: self)
    }

    /// The current-line tint follows the insertion point, so a move repaints it.
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    func render(
        document: NativeDecompilerDocumentProjection,
        contrast: ColorSchemeContrast
    ) {
        let selection = selectedRange()
        documentProjection = document
        isEditable = false
        isSelectable = true
        isRichText = true
        allowsUndo = false
        drawsBackground = false
        textContainerInset = NSSize(width: 12, height: 8)
        focusRingType = .default

        let attributed = NSMutableAttributedString(
            string: document.text,
            attributes: [
                .font: AppTypography.pseudocodeAppKit,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let utf16Offsets = Self.utf16OffsetsByScalar(in: document.text)
        for run in document.tokenRuns {
            let end = run.scalarOffset.addingReportingOverflow(run.scalarLength)
            guard !end.overflow,
                  run.scalarOffset >= 0,
                  end.partialValue < utf16Offsets.count else { continue }
            let style = AppNativePseudocodeTokenStyle.project(run.kind, contrast: contrast)
            let range = NSRange(
                location: utf16Offsets[run.scalarOffset],
                length: utf16Offsets[end.partialValue] - utf16Offsets[run.scalarOffset]
            )
            attributed.addAttribute(.font, value: style.appKitFont, range: range)
            if let foreground = style.foregroundColor {
                attributed.addAttribute(.foregroundColor, value: foreground, range: range)
            }
        }
        textStorage?.setAttributedString(attributed)
        setSelectedRange(Self.clamped(selection, utf16Count: attributed.length))
        refreshAccessibility(document.text)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 49,
              let interaction = interactionAtSelection() else {
            super.keyDown(with: event)
            return
        }
        if event.modifierFlags.contains(.option), let detail = interaction.entityDetails.first {
            onEntityDetail?(detail)
        } else if let action = interaction.keyboardAction {
            onSourceAction?(.init(tokenID: interaction.tokenID, action: action))
        } else if let detail = interaction.entityDetails.first {
            onEntityDetail?(detail)
        } else {
            NSSound.beep()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let documentProjection else { return super.menu(for: event) }
        let location = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let offset = Self.scalarOffset(forUTF16Location: location, in: documentProjection.text)
        guard let interaction = NativePseudocodeInteractionProjection.project(
            document: documentProjection,
            scalarOffset: offset,
            isHovered: true,
            isFocused: window?.firstResponder === self,
            isSelected: false
        ) else { return super.menu(for: event) }
        return actionMenu(for: interaction)
    }

    /// Captures the callbacks at menu construction, not invocation. Updating the text view while
    /// a menu is open must not bind an old token to the new document's callbacks.
    func actionMenu(for interaction: NativePseudocodeTokenInteraction) -> NSMenu {
        let menu = NSMenu()
        if let action = interaction.keyboardAction, let callback = onSourceAction {
            let request = NativePseudocodeSourceRequest(tokenID: interaction.tokenID, action: action)
            let title: String
            switch action {
            case .navigate: title = "Reveal in Disassembly"
            case .choose: title = "Choose Source Range…"
            }
            appendAction(to: menu, title: title) { callback(request) }
        }
        for detail in interaction.entityDetails {
            guard let callback = onEntityDetail else { continue }
            appendAction(to: menu, title: "Inspect \(detail.value)…") { callback(detail) }
        }
        if interaction.valueActionsAvailable, let callback = onValueAction {
            for direction in NativeValueNavigationDirection.allCases {
                let request = NativePseudocodeValueRequest(tokenID: interaction.tokenID, direction: direction)
                let title = direction == .definitions ? "Show Definitions…" : "Show Uses…"
                // Freeze the callback and token request with this menu's publication.
                appendAction(to: menu, title: title) { callback(request) }
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        return menu
    }

    private func appendAction(to menu: NSMenu, title: String, action: @escaping () -> Void) {
        let target = NativePseudocodeMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(NativePseudocodeMenuAction.invokeMenuAction(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        menu.addItem(item)
    }

    private func interactionAtSelection() -> NativePseudocodeTokenInteraction? {
        guard let documentProjection else { return nil }
        let utf16Location = selectedRange().location
        let scalarOffset = Self.scalarOffset(
            forUTF16Location: utf16Location,
            in: documentProjection.text
        )
        return NativePseudocodeInteractionProjection.project(
            document: documentProjection,
            scalarOffset: scalarOffset,
            isHovered: false,
            isFocused: window?.firstResponder === self,
            isSelected: true
        )
    }

    private func refreshAccessibility(_ text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), lines.last == "" { lines.removeLast() }
        accessibleLines = lines.enumerated().map {
            NativePseudocodeAccessibleLine(lineNumber: $0.offset + 1, text: $0.element)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Native pseudocode document")
        setAccessibilityIdentifier(NativeDecompilerAccessibilityIdentifiers.document)
        let children = accessibleLines.map { line in
            let child = NSAccessibilityElement()
            child.setAccessibilityParent(self)
            child.setAccessibilityRole(.staticText)
            child.setAccessibilityLabel("Line \(line.lineNumber)")
            child.setAccessibilityValue(line.text)
            child.setAccessibilityIdentifier(line.identifier)
            return child
        }
        setAccessibilityChildren(children)
    }

    private static func utf16OffsetsByScalar(in text: String) -> [Int] {
        var offsets = [0]
        offsets.reserveCapacity(text.unicodeScalars.count + 1)
        var total = 0
        for scalar in text.unicodeScalars {
            total += scalar.utf16.count
            offsets.append(total)
        }
        return offsets
    }

    private static func scalarOffset(forUTF16Location location: Int, in text: String) -> Int {
        let offsets = utf16OffsetsByScalar(in: text)
        let target = min(max(0, location), offsets.last ?? 0)
        return max(0, offsets.partitioningIndex { $0 > target } - 1)
    }

    private static func clamped(_ range: NSRange, utf16Count: Int) -> NSRange {
        let location = min(max(0, range.location), utf16Count)
        let maximumLength = utf16Count - location
        return NSRange(location: location, length: min(max(0, range.length), maximumLength))
    }
}

@MainActor
private final class NativePseudocodeMenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func invokeMenuAction(_ sender: NSMenuItem) { action() }
}

private extension RandomAccessCollection {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low != high {
            let distance = self.distance(from: low, to: high)
            let middle = index(low, offsetBy: distance / 2)
            if predicate(self[middle]) {
                high = middle
            } else {
                low = index(after: middle)
            }
        }
        return distance(from: startIndex, to: low)
    }
}

struct NativePseudocodeTextView: NSViewRepresentable {
    let document: NativeDecompilerDocumentProjection
    let onSourceAction: (NativePseudocodeSourceRequest) -> Void
    let onEntityDetail: (NativePseudocodeEntityDetail) -> Void
    let onValueAction: (NativePseudocodeValueRequest) -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    /// Read when the parent's body creates this view, which subscribes the parent to theme
    /// changes; updateNSView then repaints the dynamic token colors with the new theme.
    private let editorThemeID = DSThemeStore.shared.editorTheme.id

    final class Coordinator {
        var renderedThemeID: String?
        /// The line-number gutter; its palette follows the editor theme.
        var ruler: LumenLineNumberRuler?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    init(
        document: NativeDecompilerDocumentProjection,
        onSourceAction: @escaping (NativePseudocodeSourceRequest) -> Void = { _ in },
        onEntityDetail: @escaping (NativePseudocodeEntityDetail) -> Void = { _ in },
        onValueAction: @escaping (NativePseudocodeValueRequest) -> Void = { _ in }
    ) {
        self.document = document
        self.onSourceAction = onSourceAction
        self.onEntityDetail = onEntityDetail
        self.onValueAction = onValueAction
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let textView = Self.makeTextView(document: document, contrast: contrast)
        textView.onSourceAction = onSourceAction
        textView.onEntityDetail = onEntityDetail
        textView.onValueAction = onValueAction
        scrollView.documentView = textView
        context.coordinator.ruler = DSCodeGutter.install(on: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NativePseudocodeNSTextView else { return }
        textView.onSourceAction = onSourceAction
        textView.onEntityDetail = onEntityDetail
        textView.onValueAction = onValueAction
        textView.render(document: document, contrast: contrast)
        if context.coordinator.renderedThemeID != editorThemeID {
            context.coordinator.renderedThemeID = editorThemeID
            if let ruler = context.coordinator.ruler { DSCodeGutter.refresh(ruler) }
            textView.needsDisplay = true
        }
    }

    static func makeTextView(
        document: NativeDecompilerDocumentProjection,
        contrast: ColorSchemeContrast
    ) -> NativePseudocodeNSTextView {
        let textView = NativePseudocodeNSTextView()
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.render(document: document, contrast: contrast)
        return textView
    }
}
