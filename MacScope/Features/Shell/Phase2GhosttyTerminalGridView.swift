import AppKit
import CoreText

@MainActor
final class Phase2GhosttyTerminalGridView: NSView, @preconcurrency NSTextInputClient {
    struct CellMetrics: Equatable {
        let width: CGFloat
        let height: CGFloat
        let baseline: CGFloat
    }

    struct CursorRenderDecision: Equatable {
        let originColumn: Int
        let columnSpan: Int
        let redrawsGrapheme: Bool
        let cursorForeground: Phase2TerminalGridColor
        let cursorBackground: Phase2TerminalGridColor
    }

    var snapshot: Phase2TerminalGridSnapshot? {
        didSet {
            updateScroller()
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    var keyEventHandler: ((Phase2TerminalInputEncoder.KeyEvent) -> Void)?
    var committedTextHandler: ((String) -> Void)?
    var pasteHandler: ((String) -> Void)?
    var geometryHandler: ((Phase2HumanPTYTerminalSize, Phase2TerminalPixelGeometry) -> Void)?
    var scrollHandler: ((Int) -> Void)?
    var scrollToOffsetHandler: ((Int) -> Void)?
    var beginSelectionHandler: ((Phase2TerminalGridPoint) -> Void)?
    var extendSelectionHandler: ((Phase2TerminalGridPoint) -> Void)?
    var endSelectionHandler: (() -> Void)?
    var clearSelectionHandler: (() -> Void)?
    var selectedTextHandler: (() -> String?)?
    var selectAllHandler: (() -> Void)?
    var mouseEventHandler: ((Phase2TerminalMouseEvent, Phase2TerminalPixelGeometry) -> Bool)?
    /// Called when Light/Dark or Increase Contrast changes, so the host can reapply the theme.
    var appearanceChangedHandler: (() -> Void)?
    /// The theme's terminal cursor color; the system accent when unset.
    var cursorColor: NSColor? {
        didSet { if cursorColor != oldValue { needsDisplay = true } }
    }
    private var selectionAnchor: Phase2TerminalGridPoint?
    private let viewportScroller = NSScroller()
    private var pointerTrackingArea: NSTrackingArea?
    private var markedText = NSMutableAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)

    private let regularFont: CTFont
    private let boldFont: CTFont
    private let italicFont: CTFont
    private let boldItalicFont: CTFont
    private(set) var cellMetrics: CellMetrics

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    init(font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)) { // ds-allow: terminal grid default; the terminal font setting overrides it
        let manager = NSFontManager.shared
        let bold = manager.convert(font, toHaveTrait: .boldFontMask)
        let italic = manager.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        regularFont = font as CTFont
        boldFont = bold as CTFont
        italicFont = italic as CTFont
        boldItalicFont = boldItalic as CTFont
        cellMetrics = Self.metrics(for: font as CTFont)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        viewportScroller.scrollerStyle = .overlay
        viewportScroller.controlSize = .small
        viewportScroller.target = self
        viewportScroller.action = #selector(scrollerChanged(_:))
        viewportScroller.isHidden = true
        addSubview(viewportScroller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        guard let snapshot else { return .zero }
        return NSSize(
            width: CGFloat(snapshot.columns) * cellMetrics.width,
            height: CGFloat(snapshot.rows) * cellMetrics.height
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChangedHandler?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
        reportGeometryIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutScroller()
        reportGeometryIfNeeded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let snapshot else {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }

        Self.nsColor(snapshot.defaultBackground).setFill()
        dirtyRect.fill()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for (rowIndex, row) in snapshot.gridRows.enumerated() {
            let rowRect = CGRect(
                x: 0,
                y: CGFloat(rowIndex) * cellMetrics.height,
                width: CGFloat(snapshot.columns) * cellMetrics.width,
                height: cellMetrics.height
            )
            guard rowRect.intersects(dirtyRect) else { continue }
            draw(row: row, rowIndex: rowIndex, context: context, scale: scale)
        }
        drawCursor(snapshot.cursor, context: context, scale: scale)
        drawMarkedText(context: context)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if forwardMouse(event, action: .press, button: .left) { return }
        guard let point = gridPoint(for: event.locationInWindow) else {
            clearSelectionHandler?()
            return
        }
        selectionAnchor = point
        beginSelectionHandler?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        if selectionAnchor == nil {
            _ = forwardMouse(event, action: .motion, button: .left)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        let decision = Self.selectionAutoscroll(
            localY: local.y,
            viewportHeight: contentBounds.height,
            cellHeight: cellMetrics.height
        )
        if decision.rows != 0 { scrollHandler?(decision.rows) }
        guard let point = gridPoint(localPoint: CGPoint(x: local.x, y: decision.clampedY)) else { return }
        extendSelectionHandler?(point)
    }

    override func mouseUp(with event: NSEvent) {
        if selectionAnchor == nil {
            _ = forwardMouse(event, action: .release, button: .left)
            return
        }
        if selectionAnchor != nil,
           let point = gridPoint(for: event.locationInWindow) {
            extendSelectionHandler?(point)
        }
        selectionAnchor = nil
        endSelectionHandler?()
    }

    override func mouseMoved(with event: NSEvent) {
        _ = forwardMouse(event, action: .motion, button: nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        if !forwardMouse(event, action: .press, button: .right) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !forwardMouse(event, action: .release, button: .right) {
            super.rightMouseUp(with: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if !forwardMouse(event, action: .motion, button: .right) {
            super.rightMouseDragged(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !forwardMouse(event, action: .press, button: .middle) {
            super.otherMouseDown(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !forwardMouse(event, action: .release, button: .middle) {
            super.otherMouseUp(with: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if !forwardMouse(event, action: .motion, button: .middle) {
            super.otherMouseDragged(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let wheelButton: Phase2TerminalMouseEvent.Button = event.scrollingDeltaY > 0 ? .four : .five
        if forwardMouse(event, action: .press, button: wheelButton) { return }
        let rows = Self.scrollRows(deltaY: event.scrollingDeltaY, hasPreciseDeltas: event.hasPreciseScrollingDeltas, cellHeight: cellMetrics.height)
        guard rows != 0 else { return }
        scrollHandler?(rows)
    }

    override func keyDown(with event: NSEvent) {
        let encodedEvent = Phase2TerminalInputEncoder.KeyEvent(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: Self.inputModifiers(event.modifierFlags)
        )
        if Self.shouldEncodeDirectly(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            keyEventHandler?(encodedEvent)
        } else {
            // AppKit owns ordinary text and composition from the first keystroke.
            // Only explicit terminal protocol keys/modifiers bypass NSTextInputClient.
            interpretKeyEvents([event])
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let character = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        switch character {
        case "c":
            _ = copySelection(to: .general)
            return true
        case "a":
            selectAllHandler?()
            return true
        case "v":
            guard let value = NSPasteboard.general.string(forType: .string) else { return true }
            pasteHandler?(value)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    @discardableResult
    func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard let value = selectedTextHandler?(), !value.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }

    func reportGeometryIfNeeded(backingScale: CGFloat? = nil) {
        guard let result = Self.terminalGeometry(
            bounds: contentBounds,
            cellMetrics: cellMetrics,
            backingScale: backingScale ?? window?.backingScaleFactor ?? 2
        ) else { return }
        geometryHandler?(result.size, result.pixels)
    }

    func gridPoint(for windowPoint: NSPoint) -> Phase2TerminalGridPoint? {
        let local = convert(windowPoint, from: nil)
        return gridPoint(localPoint: local)
    }

    private func gridPoint(localPoint: CGPoint) -> Phase2TerminalGridPoint? {
        guard contentBounds.contains(localPoint) else { return nil }
        return Self.gridPoint(localPoint: localPoint, snapshot: snapshot, cellMetrics: cellMetrics)
    }

    static func gridPoint(
        localPoint: CGPoint,
        snapshot: Phase2TerminalGridSnapshot?,
        cellMetrics: CellMetrics
    ) -> Phase2TerminalGridPoint? {
        guard let snapshot, localPoint.x >= 0, localPoint.y >= 0 else { return nil }
        let column = Int(localPoint.x / cellMetrics.width)
        let row = Int(localPoint.y / cellMetrics.height)
        guard column < snapshot.columns, row < snapshot.rows else { return nil }
        return Phase2TerminalGridPoint(column: column, row: row)
    }

    static func terminalGeometry(
        bounds: CGRect,
        cellMetrics: CellMetrics,
        backingScale: CGFloat
    ) -> (size: Phase2HumanPTYTerminalSize, pixels: Phase2TerminalPixelGeometry)? {
        guard bounds.width > 0, bounds.height > 0, cellMetrics.width > 0, cellMetrics.height > 0 else { return nil }
        let columns = max(1, Int(floor(bounds.width / cellMetrics.width)))
        let rows = max(1, Int(floor(bounds.height / cellMetrics.height)))
        let scale = max(1, backingScale)
        return (
            Phase2HumanPTYTerminalSize(columns: columns, rows: rows),
            Phase2TerminalPixelGeometry(
                screenWidth: UInt32(clamping: Int((bounds.width * scale).rounded())),
                screenHeight: UInt32(clamping: Int((bounds.height * scale).rounded())),
                cellWidth: UInt32(clamping: max(1, Int((cellMetrics.width * scale).rounded()))),
                cellHeight: UInt32(clamping: max(1, Int((cellMetrics.height * scale).rounded())))
            )
        )
    }

    static func scrollRows(deltaY: CGFloat, hasPreciseDeltas: Bool, cellHeight: CGFloat) -> Int {
        guard deltaY != 0 else { return 0 }
        let magnitude = hasPreciseDeltas ? max(1, Int(abs(deltaY) / max(1, cellHeight))) : max(1, Int(abs(deltaY)))
        return deltaY > 0 ? -magnitude : magnitude
    }

    struct SelectionAutoscrollDecision: Equatable {
        let rows: Int
        let clampedY: CGFloat
    }

    static func selectionAutoscroll(
        localY: CGFloat,
        viewportHeight: CGFloat,
        cellHeight: CGFloat
    ) -> SelectionAutoscrollDecision {
        guard viewportHeight > 0, cellHeight > 0 else {
            return SelectionAutoscrollDecision(rows: 0, clampedY: 0)
        }
        if localY < 0 {
            return SelectionAutoscrollDecision(
                rows: -max(1, Int(ceil(abs(localY) / cellHeight))),
                clampedY: 0
            )
        }
        if localY >= viewportHeight {
            return SelectionAutoscrollDecision(
                rows: max(1, Int(ceil((localY - viewportHeight + 1) / cellHeight))),
                clampedY: max(0, viewportHeight - 1)
            )
        }
        return SelectionAutoscrollDecision(rows: 0, clampedY: localY)
    }

    private func forwardMouse(
        _ event: NSEvent,
        action: Phase2TerminalMouseEvent.Action,
        button: Phase2TerminalMouseEvent.Button?
    ) -> Bool {
        // Shift is the conventional local-selection override while an application owns mouse mode.
        guard !event.modifierFlags.contains(.shift),
              let geometry = Self.terminalGeometry(
                  bounds: contentBounds,
                  cellMetrics: cellMetrics,
                  backingScale: window?.backingScaleFactor ?? 2
              )?.pixels
        else { return false }
        let local = convert(event.locationInWindow, from: nil)
        guard contentBounds.contains(local) else { return false }
        let terminalEvent = Phase2TerminalMouseEvent(
            action: action,
            button: button,
            modifiers: Self.mouseModifiers(event.modifierFlags),
            position: Phase2TerminalMousePosition(x: local.x, y: local.y)
        )
        return mouseEventHandler?(terminalEvent, geometry) ?? false
    }

    private var contentBounds: CGRect {
        guard !viewportScroller.isHidden else { return bounds }
        return CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(0, bounds.width - viewportScroller.frame.width),
            height: bounds.height
        )
    }

    private func updateScroller() {
        guard let viewport = snapshot?.viewport, viewport.scrollbackRows > 0 else {
            viewportScroller.isHidden = true
            return
        }
        viewportScroller.isHidden = false
        viewportScroller.doubleValue = Double(viewport.offset) / Double(max(1, viewport.totalRows - viewport.visibleRows))
        viewportScroller.knobProportion = CGFloat(viewport.visibleRows) / CGFloat(max(1, viewport.totalRows))
        layoutScroller()
    }

    private func layoutScroller() {
        let width = NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
        viewportScroller.frame = CGRect(
            x: max(0, bounds.maxX - width),
            y: bounds.minY,
            width: width,
            height: bounds.height
        )
    }

    @objc private func scrollerChanged(_ sender: NSScroller) {
        guard let viewport = snapshot?.viewport else { return }
        switch sender.hitPart {
        case .decrementLine: scrollHandler?(-1)
        case .incrementLine: scrollHandler?(1)
        case .decrementPage: scrollHandler?(-max(1, viewport.visibleRows - 1))
        case .incrementPage: scrollHandler?(max(1, viewport.visibleRows - 1))
        default:
            let maximumOffset = max(0, viewport.totalRows - viewport.visibleRows)
            scrollToOffsetHandler?(Int((sender.doubleValue * Double(maximumOffset)).rounded()))
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = Self.plainString(string)
        unmarkText()
        guard !value.isEmpty else { return }
        committedTextHandler?(value)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let value = Self.plainString(string)
        markedText = NSMutableAttributedString(string: value)
        markedSelection = Self.clamped(selectedRange, length: markedText.length)
        needsDisplay = true
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { markedSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.font, .foregroundColor, .backgroundColor] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= markedText.length else { return nil }
        actualRange?.pointee = range
        return markedText.attributedSubstring(from: range)
    }
    func characterIndex(for point: NSPoint) -> Int { markedText.length }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        guard let snapshot, let cursor = snapshot.cursor else {
            return window.convertToScreen(convert(bounds, to: nil))
        }
        let local = NSRect(
            x: CGFloat(cursor.column) * cellMetrics.width,
            y: CGFloat(cursor.row + 1) * cellMetrics.height,
            width: max(cellMetrics.width, 1),
            height: cellMetrics.height
        )
        return window.convertToScreen(convert(local, to: nil))
    }
    override func doCommand(by selector: Selector) {
        // Commands not translated as terminal protocol keys fail closed and remain in
        // the responder chain rather than being converted to guessed text.
        if tryToPerform(selector, with: nil) { return }
    }

    private func drawMarkedText(context: CGContext) {
        guard hasMarkedText(), let snapshot, let cursor = snapshot.cursor else { return }
        let origin = CGPoint(
            x: CGFloat(cursor.column) * cellMetrics.width,
            y: CGFloat(cursor.row) * cellMetrics.height
        )
        let display = NSMutableAttributedString(attributedString: markedText)
        display.addAttributes([
            .font: regularFont,
            .foregroundColor: Self.nsColor(snapshot.defaultForeground),
            .backgroundColor: Self.nsColor(snapshot.defaultBackground),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ], range: NSRange(location: 0, length: display.length))
        if markedSelection.length > 0 {
            display.addAttributes([
                .foregroundColor: NSColor.selectedTextColor,
                .backgroundColor: NSColor.selectedTextBackgroundColor,
            ], range: markedSelection)
        }
        let line = CTLineCreateWithAttributedString(display)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y + cellMetrics.baseline)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func draw(
        row: Phase2TerminalGridRow,
        rowIndex: Int,
        context: CGContext,
        scale: CGFloat
    ) {
        for (column, cell) in row.cells.enumerated() {
            guard cell.width != .spacerTail, cell.width != .spacerHead else { continue }
            let span: CGFloat = cell.width == .wide ? 2 : 1
            let rect = pixelAligned(
                CGRect(
                    x: CGFloat(column) * cellMetrics.width,
                    y: CGFloat(rowIndex) * cellMetrics.height,
                    width: cellMetrics.width * span,
                    height: cellMetrics.height
                ),
                scale: scale
            )
            let colors = Self.resolvedColors(for: cell)
            context.setFillColor(colors.background.cgColor)
            context.fill(rect)

            guard !cell.style.invisible, !cell.grapheme.isEmpty else { continue }
            drawGlyph(cell, in: rect, foreground: colors.foreground, context: context)
            drawDecorations(cell, in: rect, foreground: colors.foreground, context: context, scale: scale)
        }
    }

    private func drawGlyph(
        _ cell: Phase2TerminalGridCell,
        in rect: CGRect,
        foreground: NSColor,
        context: CGContext,
        appliesFaintStyle: Bool = true
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: cell.style),
            .foregroundColor: appliesFaintStyle && cell.style.faint
                ? foreground.withAlphaComponent(0.55) // ds-allow: SGR 2 faint text, a terminal convention
                : foreground,
            .ligature: 0,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: cell.grapheme, attributes: attributes)
        )
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.minY + cellMetrics.baseline)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawDecorations(
        _ cell: Phase2TerminalGridCell,
        in rect: CGRect,
        foreground: NSColor,
        context: CGContext,
        scale: CGFloat
    ) {
        context.setFillColor(foreground.cgColor)
        let thickness = max(1 / scale, cell.style.underline > 1 ? 2 / scale : 1 / scale)
        if cell.style.underline > 0 {
            context.fill(pixelAligned(
                CGRect(x: rect.minX, y: rect.maxY - 2 / scale, width: rect.width, height: thickness),
                scale: scale
            ))
        }
        if cell.style.strikethrough {
            context.fill(pixelAligned(
                CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1 / scale),
                scale: scale
            ))
        }
        if cell.style.overline {
            context.fill(pixelAligned(
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1 / scale),
                scale: scale
            ))
        }
    }

    private func drawCursor(
        _ cursor: Phase2TerminalGridCursor?,
        context: CGContext,
        scale: CGFloat
    ) {
        guard let cursor, cursor.isVisible,
              let snapshot,
              let decision = Self.cursorRenderDecision(cursor: cursor, snapshot: snapshot),
              snapshot.gridRows.indices.contains(cursor.row),
              snapshot.gridRows[cursor.row].cells.indices.contains(decision.originColumn)
        else { return }
        let cell = snapshot.gridRows[cursor.row].cells[decision.originColumn]
        let rect = pixelAligned(
            CGRect(
                x: CGFloat(decision.originColumn) * cellMetrics.width,
                y: CGFloat(cursor.row) * cellMetrics.height,
                width: CGFloat(decision.columnSpan) * cellMetrics.width,
                height: cellMetrics.height
            ),
            scale: scale
        )
        let color = (cursorColor ?? NSColor.controlAccentColor).withAlphaComponent(cursor.shouldBlink ? 0.72 : 0.82)
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1 / scale)
        switch cursor.style {
        case .bar:
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: max(1 / scale, 2 / scale), height: rect.height))
        case .block:
            let cellColors = Self.resolvedColors(for: cell)
            context.setFillColor(cellColors.foreground.cgColor)
            context.fill(rect)
            if decision.redrawsGrapheme {
                drawGlyph(
                    cell,
                    in: rect,
                    foreground: cellColors.background,
                    context: context,
                    appliesFaintStyle: false
                )
            }
        case .underline:
            context.fill(CGRect(x: rect.minX, y: rect.maxY - max(1 / scale, 2 / scale), width: rect.width, height: max(1 / scale, 2 / scale)))
        case .hollowBlock:
            context.stroke(rect.insetBy(dx: 0.5 / scale, dy: 0.5 / scale))
        }
    }

    static func cursorRenderDecision(
        cursor: Phase2TerminalGridCursor,
        snapshot: Phase2TerminalGridSnapshot
    ) -> CursorRenderDecision? {
        guard cursor.column >= 0, cursor.row >= 0,
              cursor.column < snapshot.columns, cursor.row < snapshot.rows,
              snapshot.gridRows.indices.contains(cursor.row)
        else { return nil }
        let row = snapshot.gridRows[cursor.row]
        guard row.cells.indices.contains(cursor.column) else { return nil }
        let addressedCell = row.cells[cursor.column]

        let originColumn: Int
        let cell: Phase2TerminalGridCell
        if addressedCell.width == .spacerTail,
           cursor.column > 0,
           row.cells.indices.contains(cursor.column - 1),
           row.cells[cursor.column - 1].width == .wide {
            originColumn = cursor.column - 1
            cell = row.cells[originColumn]
        } else {
            originColumn = cursor.column
            cell = addressedCell
        }
        let availableColumns = max(1, snapshot.columns - originColumn)
        let columnSpan = cell.width == .wide ? min(2, availableColumns) : 1
        let cursorColors = cursorColors(for: cell)
        return CursorRenderDecision(
            originColumn: originColumn,
            columnSpan: columnSpan,
            redrawsGrapheme: cursor.style == .block
                && !cell.style.invisible
                && !cell.grapheme.isEmpty,
            cursorForeground: cursorColors.foreground,
            cursorBackground: cursorColors.background
        )
    }

    private static func cursorColors(
        for cell: Phase2TerminalGridCell
    ) -> (foreground: Phase2TerminalGridColor, background: Phase2TerminalGridColor) {
        var foreground = cell.style.background
        var background = cell.style.foreground
        if cell.style.inverse {
            swap(&foreground, &background)
        }
        return (foreground, background)
    }

    private func font(for style: Phase2TerminalGridCellStyle) -> CTFont {
        switch (style.bold, style.italic) {
        case (true, true): boldItalicFont
        case (true, false): boldFont
        case (false, true): italicFont
        case (false, false): regularFont
        }
    }

    private func updateBackingScale() {
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    private func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (rect.origin.x * scale).rounded() / scale,
            y: (rect.origin.y * scale).rounded() / scale,
            width: (rect.width * scale).rounded() / scale,
            height: (rect.height * scale).rounded() / scale
        )
    }

    private static func metrics(for font: CTFont) -> CellMetrics {
        let glyph = CTFontGetGlyphWithName(font, "M" as CFString)
        var glyphCopy = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphCopy, &advance, 1)
        let width = ceil(max(advance.width, CTFontGetSize(font) * 0.5))
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = max(CTFontGetLeading(font), 1)
        return CellMetrics(
            width: width,
            height: ceil(ascent + descent + leading),
            baseline: ceil(ascent + leading / 2)
        )
    }

    private static func resolvedColors(
        for cell: Phase2TerminalGridCell
    ) -> (foreground: NSColor, background: NSColor) {
        var foreground = nsColor(cell.style.foreground)
        var background = nsColor(cell.style.background)
        if cell.style.inverse {
            swap(&foreground, &background)
        }
        if cell.isSelected {
            background = NSColor.selectedTextBackgroundColor
            foreground = NSColor.selectedTextColor
        }
        return (foreground, background)
    }

    private static func nsColor(_ color: Phase2TerminalGridColor) -> NSColor {
        NSColor(
            deviceRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }

    private static func inputModifiers(_ flags: NSEvent.ModifierFlags) -> Phase2TerminalInputEncoder.Modifiers {
        var result: Phase2TerminalInputEncoder.Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private static func mouseModifiers(_ flags: NSEvent.ModifierFlags) -> UInt16 {
        var result: UInt16 = 0
        if flags.contains(.shift) { result |= 1 << 0 }
        if flags.contains(.control) { result |= 1 << 1 }
        if flags.contains(.option) { result |= 1 << 2 }
        if flags.contains(.command) { result |= 1 << 3 }
        return result
    }

    private static func isProtocolKey(_ keyCode: UInt16) -> Bool {
        [36, 48, 51, 53, 65, 67, 69, 75, 76, 78, 81, 82, 83, 84, 85, 86,
         87, 88, 89, 91, 92, 96, 97, 98, 99, 100, 101, 103, 109, 111, 114,
         115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126].contains(keyCode)
    }

    static func shouldEncodeDirectly(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        isProtocolKey(keyCode)
            || !modifierFlags.intersection([.option, .control]).isEmpty
    }

    private static func plainString(_ value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: length, length: 0) }
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }
}
