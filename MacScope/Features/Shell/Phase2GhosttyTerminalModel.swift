import Foundation

#if canImport(GhosttyVt)
import GhosttyVt

@MainActor
final class Phase2GhosttyTerminalModel {
    private let inputEncoder = Phase2TerminalInputEncoder()
    private(set) var sessionID: UUID
    private(set) var terminalSize: Phase2HumanPTYTerminalSize
    private(set) var lastAppliedSequence: UInt64?
    private(set) var missingSequenceRanges: [ClosedRange<UInt64>] = []
    private(set) var integrity: Phase2GhosttyTerminalIntegrity = .authoritative

    private var handles = GhosttyHandles()
    private var selectionAnchorScreenPoint: Phase2TerminalGridPoint?

    init(sessionID: UUID, terminalSize: Phase2HumanPTYTerminalSize = .defaultInteractive) {
        precondition(terminalSize.isValid)
        self.sessionID = sessionID
        self.terminalSize = terminalSize
        createGhosttyState()
    }

    func replaceSession(
        _ sessionID: UUID,
        terminalSize: Phase2HumanPTYTerminalSize = .defaultInteractive
    ) {
        guard sessionID != self.sessionID else {
            resize(to: terminalSize)
            return
        }
        destroyGhosttyState()
        self.sessionID = sessionID
        self.terminalSize = terminalSize
        lastAppliedSequence = nil
        missingSequenceRanges = []
        integrity = .authoritative
        selectionAnchorScreenPoint = nil
        createGhosttyState()
    }

    @discardableResult
    func ingest(_ events: [Phase2HumanPTYTranscriptEvent]) -> Phase2GhosttyTerminalIngestion {
        var applied: [UInt64] = []
        var duplicates: [UInt64] = []
        var foreign: [UInt64] = []
        var newGaps: [ClosedRange<UInt64>] = []

        for event in events {
            guard event.sessionID == sessionID else {
                foreign.append(event.sequence)
                continue
            }
            if let lastAppliedSequence, event.sequence <= lastAppliedSequence {
                duplicates.append(event.sequence)
                continue
            }
            if let gap = Self.missingSequenceRange(
                after: lastAppliedSequence,
                before: event.sequence
            ) {
                missingSequenceRanges.append(gap)
                newGaps.append(gap)
                integrity = .sequenceGap(gap)
                destroyGhosttyState()
                break
            }

            switch event.payload {
            case .output(_, let bytes):
                write(bytes)
            case .resize(let columns, let rows):
                let size = Phase2HumanPTYTerminalSize(columns: columns, rows: rows)
                if size.isValid { resize(to: size) }
            case .gap(let reason, let lostByteCount):
                // VT parsing is stateful. Once bytes are known to be absent, every later cell may
                // be plausible but wrong, so discard native state and refuse authoritative grids.
                integrity = .transcriptGap(reason: reason, lostByteCount: lostByteCount)
                destroyGhosttyState()
            case .input, .signal, .reconnect, .terminal:
                break
            }
            lastAppliedSequence = event.sequence
            applied.append(event.sequence)

            if integrity != .authoritative {
                break
            }
        }

        return Phase2GhosttyTerminalIngestion(
            appliedSequences: applied,
            ignoredDuplicateSequences: duplicates,
            ignoredForeignSessionSequences: foreign,
            missingSequenceRanges: newGaps
        )
    }

    static func missingSequenceRange(
        after lastAppliedSequence: UInt64?,
        before incomingSequence: UInt64
    ) -> ClosedRange<UInt64>? {
        guard let lastAppliedSequence else {
            guard incomingSequence != 1 else { return nil }
            return 1...(incomingSequence > 1 ? incomingSequence - 1 : 1)
        }
        guard incomingSequence > lastAppliedSequence else { return nil }
        let (expectedSequence, overflowed) = lastAppliedSequence.addingReportingOverflow(1)
        guard !overflowed, incomingSequence > expectedSequence else { return nil }
        return expectedSequence...(incomingSequence - 1)
    }

    func resize(to size: Phase2HumanPTYTerminalSize) {
        resize(to: size, cellWidthPixels: 1, cellHeightPixels: 1)
    }

    func resize(
        to size: Phase2HumanPTYTerminalSize,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32
    ) {
        guard size.isValid, let terminal = handles.terminal else { return }
        guard ghostty_terminal_resize(
            terminal,
            UInt16(clamping: size.columns),
            UInt16(clamping: size.rows),
            max(1, cellWidthPixels),
            max(1, cellHeightPixels)
        ) == GHOSTTY_SUCCESS else { return }
        terminalSize = size
    }

    func scrollViewport(rows: Int) {
        guard integrity == .authoritative, let terminal = handles.terminal, rows != 0 else { return }
        var value = GhosttyTerminalScrollViewportValue()
        value.delta = rows
        ghostty_terminal_scroll_viewport(
            terminal,
            GhosttyTerminalScrollViewport(tag: GHOSTTY_SCROLL_VIEWPORT_DELTA, value: value)
        )
    }

    func scrollViewportToBottom() {
        guard integrity == .authoritative, let terminal = handles.terminal else { return }
        ghostty_terminal_scroll_viewport(
            terminal,
            GhosttyTerminalScrollViewport(
                tag: GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
                value: GhosttyTerminalScrollViewportValue()
            )
        )
    }

    func scrollViewport(to offset: Int) {
        guard integrity == .authoritative, let terminal = handles.terminal else { return }
        var value = GhosttyTerminalScrollViewportValue()
        value.row = max(0, offset)
        ghostty_terminal_scroll_viewport(
            terminal,
            GhosttyTerminalScrollViewport(tag: GHOSTTY_SCROLL_VIEWPORT_ROW, value: value)
        )
    }

    @discardableResult
    func beginSelection(at point: Phase2TerminalGridPoint) -> Bool {
        guard let screenPoint = resolvedPoint(point, from: GHOSTTY_POINT_TAG_VIEWPORT, to: GHOSTTY_POINT_TAG_SCREEN)
        else {
            selectionAnchorScreenPoint = nil
            return false
        }
        selectionAnchorScreenPoint = screenPoint
        return installSelection(from: screenPoint, through: screenPoint, tag: GHOSTTY_POINT_TAG_SCREEN)
    }

    @discardableResult
    func extendSelection(to point: Phase2TerminalGridPoint) -> Bool {
        guard let anchor = selectionAnchorScreenPoint,
              let screenPoint = resolvedPoint(point, from: GHOSTTY_POINT_TAG_VIEWPORT, to: GHOSTTY_POINT_TAG_SCREEN)
        else { return false }
        return installSelection(from: anchor, through: screenPoint, tag: GHOSTTY_POINT_TAG_SCREEN)
    }

    func endSelection() {
        selectionAnchorScreenPoint = nil
    }

    @discardableResult
    func select(from start: Phase2TerminalGridPoint, through end: Phase2TerminalGridPoint) -> Bool {
        installSelection(from: start, through: end, tag: GHOSTTY_POINT_TAG_VIEWPORT)
    }

    private func installSelection(
        from start: Phase2TerminalGridPoint,
        through end: Phase2TerminalGridPoint,
        tag: GhosttyPointTag
    ) -> Bool {
        guard integrity == .authoritative, let terminal = handles.terminal else { return false }
        var startRef = GhosttyGridRef(size: MemoryLayout<GhosttyGridRef>.size, node: nil, x: 0, y: 0)
        var endRef = GhosttyGridRef(size: MemoryLayout<GhosttyGridRef>.size, node: nil, x: 0, y: 0)
        guard ghostty_terminal_grid_ref(terminal, Self.point(start, tag: tag), &startRef) == GHOSTTY_SUCCESS,
              ghostty_terminal_grid_ref(terminal, Self.point(end, tag: tag), &endRef) == GHOSTTY_SUCCESS
        else { return false }
        var selection = GhosttySelection(
            size: MemoryLayout<GhosttySelection>.size,
            start: startRef,
            end: endRef,
            rectangle: false
        )
        return withUnsafePointer(to: &selection) {
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, $0) == GHOSTTY_SUCCESS
        }
    }

    func clearSelection() {
        guard integrity == .authoritative, let terminal = handles.terminal else { return }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        selectionAnchorScreenPoint = nil
    }

    @discardableResult
    func selectAll() -> Bool {
        guard integrity == .authoritative, let terminal = handles.terminal else { return false }
        var selection = GhosttySelection(
            size: MemoryLayout<GhosttySelection>.size,
            start: GhosttyGridRef(),
            end: GhosttyGridRef(),
            rectangle: false
        )
        guard ghostty_terminal_select_all(terminal, &selection) == GHOSTTY_SUCCESS else { return false }
        return withUnsafePointer(to: &selection) {
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, $0) == GHOSTTY_SUCCESS
        }
    }

    func selectedText() -> String? {
        guard integrity == .authoritative, let terminal = handles.terminal else { return nil }
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        var required = 0
        let probe = ghostty_terminal_selection_format_buf(terminal, options, nil, 0, &required)
        guard probe == GHOSTTY_OUT_OF_SPACE, required > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: required)
        var written = 0
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            ghostty_terminal_selection_format_buf(
                terminal, options, buffer.baseAddress, buffer.count, &written
            )
        }
        guard result == GHOSTTY_SUCCESS else { return nil }
        return String(decoding: bytes.prefix(written), as: UTF8.self)
    }

    func snapshot() -> Phase2TerminalGridSnapshot? {
        guard integrity == .authoritative,
              let terminal = handles.terminal,
              let renderState = handles.renderState,
              let rowIterator = handles.rowIterator,
              let rowCells = handles.rowCells
        else { return nil }
        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else { return nil }

        var columns: UInt16 = 0
        var rows: UInt16 = 0
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &columns) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) == GHOSTTY_SUCCESS
        else { return nil }

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        guard ghostty_render_state_colors_get(renderState, &colors) == GHOSTTY_SUCCESS else { return nil }

        var scrollbar = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(
            terminal,
            GHOSTTY_TERMINAL_DATA_SCROLLBAR,
            &scrollbar
        ) == GHOSTTY_SUCCESS else { return nil }

        guard ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            &handles.rowIterator
        ) == GHOSTTY_SUCCESS else { return nil }

        var copiedRows: [Phase2TerminalGridRow] = []
        copiedRows.reserveCapacity(Int(rows))
        while ghostty_render_state_row_iterator_next(rowIterator) {
            var isDirty = false
            _ = ghostty_render_state_row_get(
                rowIterator,
                GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                &isDirty
            )
            guard ghostty_render_state_row_get(
                rowIterator,
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                &handles.rowCells
            ) == GHOSTTY_SUCCESS else { return nil }

            var copiedCells: [Phase2TerminalGridCell] = []
            copiedCells.reserveCapacity(Int(columns))
            while ghostty_render_state_row_cells_next(rowCells) {
                copiedCells.append(copyCell(rowCells, colors: colors))
            }
            copiedRows.append(Phase2TerminalGridRow(cells: copiedCells, isDirty: isDirty))
        }

        return Phase2TerminalGridSnapshot(
            sessionID: sessionID,
            columns: Int(columns),
            rows: Int(rows),
            defaultForeground: Self.color(colors.foreground),
            defaultBackground: Self.color(colors.background),
            gridRows: copiedRows,
            cursor: copyCursor(renderState),
            lastAppliedSequence: lastAppliedSequence,
            missingSequenceRanges: missingSequenceRanges,
            viewport: Phase2TerminalViewportState(
                totalRows: Int(clamping: scrollbar.total),
                offset: Int(clamping: scrollbar.offset),
                visibleRows: Int(clamping: scrollbar.len)
            )
        )
    }

    func encodeInput(_ event: Phase2TerminalInputEncoder.KeyEvent) -> [UInt8]? {
        guard integrity == .authoritative, let terminal = handles.terminal else { return nil }
        return inputEncoder.encode(event, terminal: terminal)
    }

    func encodePaste(_ text: String) -> [UInt8]? {
        guard integrity == .authoritative, let terminal = handles.terminal else { return nil }
        let bytes = inputEncoder.encodePaste(text, terminal: terminal)
        return bytes.isEmpty && !text.isEmpty ? nil : bytes
    }

    func terminalMode(value: UInt16, ansi: Bool = false) -> Bool? {
        guard integrity == .authoritative, let terminal = handles.terminal else { return nil }
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else {
            return nil
        }
        return config.value
    }

    var isMouseTrackingEnabled: Bool {
        guard integrity == .authoritative, let terminal = handles.terminal else { return false }
        var enabled = false
        guard ghostty_terminal_get(
            terminal,
            GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
            &enabled
        ) == GHOSTTY_SUCCESS else { return false }
        return enabled
    }

    func encodeMouse(_ event: Phase2TerminalMouseEvent, geometry: Phase2TerminalPixelGeometry) -> [UInt8]? {
        guard integrity == .authoritative,
              let terminal = handles.terminal,
              let mouseEncoder = handles.mouseEncoder,
              let mouseEvent = handles.mouseEvent,
              geometry.isValid
        else { return nil }
        ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal)
        var size = GhosttyMouseEncoderSize(
            size: MemoryLayout<GhosttyMouseEncoderSize>.size,
            screen_width: geometry.screenWidth,
            screen_height: geometry.screenHeight,
            cell_width: geometry.cellWidth,
            cell_height: geometry.cellHeight,
            padding_top: 0,
            padding_bottom: 0,
            padding_right: 0,
            padding_left: 0
        )
        withUnsafePointer(to: &size) {
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, $0)
        }
        var anyButtonPressed = event.action != .release && event.button != nil
        withUnsafePointer(to: &anyButtonPressed) {
            ghostty_mouse_encoder_setopt(
                mouseEncoder,
                GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
                $0
            )
        }
        ghostty_mouse_event_set_action(mouseEvent, event.action.ghosttyValue)
        if let button = event.button {
            ghostty_mouse_event_set_button(mouseEvent, button.ghosttyValue)
        } else {
            ghostty_mouse_event_clear_button(mouseEvent)
        }
        ghostty_mouse_event_set_mods(mouseEvent, event.modifiers)
        ghostty_mouse_event_set_position(
            mouseEvent,
            GhosttyMousePosition(x: Float(event.position.x), y: Float(event.position.y))
        )
        var bytes = [CChar](repeating: 0, count: 64)
        var written = 0
        let result = ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &bytes, bytes.count, &written)
        guard result == GHOSTTY_SUCCESS else { return nil }
        return bytes.prefix(written).map { UInt8(bitPattern: $0) }
    }

    private func resolvedPoint(
        _ point: Phase2TerminalGridPoint,
        from sourceTag: GhosttyPointTag,
        to destinationTag: GhosttyPointTag
    ) -> Phase2TerminalGridPoint? {
        guard integrity == .authoritative, let terminal = handles.terminal else { return nil }
        var ref = GhosttyGridRef(size: MemoryLayout<GhosttyGridRef>.size, node: nil, x: 0, y: 0)
        guard ghostty_terminal_grid_ref(terminal, Self.point(point, tag: sourceTag), &ref) == GHOSTTY_SUCCESS
        else { return nil }
        var coordinate = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(
            terminal,
            &ref,
            destinationTag,
            &coordinate
        ) == GHOSTTY_SUCCESS else { return nil }
        return Phase2TerminalGridPoint(column: Int(coordinate.x), row: Int(coordinate.y))
    }

    private static func point(_ point: Phase2TerminalGridPoint, tag: GhosttyPointTag) -> GhosttyPoint {
        var value = GhosttyPointValue()
        value.coordinate = GhosttyPointCoordinate(
            x: UInt16(clamping: point.column),
            y: UInt32(clamping: point.row)
        )
        return GhosttyPoint(tag: tag, value: value)
    }

    private func copyCell(
        _ cells: GhosttyRenderStateRowCells,
        colors: GhosttyRenderStateColors
    ) -> Phase2TerminalGridCell {
        var raw: GhosttyCell = 0
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
        var wide = GHOSTTY_CELL_WIDE_NARROW
        _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)

        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)

        var foreground = colors.foreground
        if ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            &foreground
        ) != GHOSTTY_SUCCESS { foreground = colors.foreground }
        var background = colors.background
        if ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
            &background
        ) != GHOSTTY_SUCCESS { background = colors.background }

        var selected = false
        _ = ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED,
            &selected
        )

        var required = GhosttyBuffer(ptr: nil, cap: 0, len: 0)
        let initial = ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
            &required
        )
        var grapheme = ""
        if initial == GHOSTTY_OUT_OF_SPACE, required.len > 0 {
            var bytes = [UInt8](repeating: 0, count: required.len)
            var decodedCount = 0
            bytes.withUnsafeMutableBufferPointer { buffer in
                var output = GhosttyBuffer(ptr: buffer.baseAddress, cap: buffer.count, len: 0)
                if ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                    &output
                ) == GHOSTTY_SUCCESS {
                    decodedCount = output.len
                }
            }
            grapheme = String(decoding: bytes.prefix(decodedCount), as: UTF8.self)
        }

        let width: Phase2TerminalGridCellWidth
        switch wide {
        case GHOSTTY_CELL_WIDE_WIDE: width = .wide
        case GHOSTTY_CELL_WIDE_SPACER_TAIL: width = .spacerTail
        case GHOSTTY_CELL_WIDE_SPACER_HEAD: width = .spacerHead
        default: width = .narrow
        }

        return Phase2TerminalGridCell(
            grapheme: grapheme,
            width: width,
            style: Phase2TerminalGridCellStyle(
                foreground: Self.color(foreground),
                background: Self.color(background),
                bold: style.bold,
                italic: style.italic,
                faint: style.faint,
                inverse: style.inverse,
                invisible: style.invisible,
                strikethrough: style.strikethrough,
                overline: style.overline,
                underline: Int32(style.underline)
            ),
            isSelected: selected
        )
    }

    private func copyCursor(_ renderState: GhosttyRenderState) -> Phase2TerminalGridCursor? {
        var visible = false
        var inViewport = false
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
        _ = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
            &inViewport
        )
        guard inViewport else { return nil }

        var x: UInt16 = 0
        var y: UInt16 = 0
        var blinking = false
        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style)

        let copiedStyle: Phase2TerminalGridCursorStyle
        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: copiedStyle = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: copiedStyle = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: copiedStyle = .hollowBlock
        default: copiedStyle = .block
        }
        return Phase2TerminalGridCursor(
            column: Int(x),
            row: Int(y),
            style: copiedStyle,
            isVisible: visible,
            shouldBlink: blinking
        )
    }

    private func write(_ bytes: [UInt8]) {
        guard let terminal = handles.terminal, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buffer in
            ghostty_terminal_vt_write(terminal, buffer.baseAddress, buffer.count)
        }
    }

    private func createGhosttyState() {
        var newTerminal: GhosttyTerminal?
        guard ghostty_terminal_new(
            nil,
            &newTerminal,
            UInt16(clamping: terminalSize.columns),
            UInt16(clamping: terminalSize.rows)
        ) == GHOSTTY_SUCCESS, let createdTerminal = newTerminal else { return }
        // Upstream removed the creation-time options struct; scrollback is now a
        // post-create setter. The prior max_scrollback of 10_000 maps to the
        // line-count limit (the classic 10k-line scrollback budget).
        var maxScrollbackLines = size_t(10_000)
        _ = ghostty_terminal_set(createdTerminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &maxScrollbackLines)
        handles.terminal = newTerminal
        _ = ghostty_render_state_new(nil, &handles.renderState)
        _ = ghostty_render_state_row_iterator_new(nil, &handles.rowIterator)
        _ = ghostty_render_state_row_cells_new(nil, &handles.rowCells)
        _ = ghostty_mouse_encoder_new(nil, &handles.mouseEncoder)
        _ = ghostty_mouse_event_new(nil, &handles.mouseEvent)
    }

    /// Sets the terminal's default colors and 256-color palette from the MacScope theme.
    /// Per-index OSC overrides a program has set are preserved by the engine. Returns whether
    /// every option was accepted.
    @discardableResult
    func applyTheme(_ palette: TerminalThemePalette) -> Bool {
        guard let terminal = handles.terminal else { return false }
        func rgb(_ c: TerminalThemePalette.RGB) -> GhosttyColorRgb { GhosttyColorRgb(r: c.r, g: c.g, b: c.b) }
        var foreground = rgb(palette.foreground)
        var background = rgb(palette.background)
        var cursor = rgb(palette.cursor)
        var table = palette.palette256.map(rgb)
        var accepted = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground) == GHOSTTY_SUCCESS
        accepted = (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background) == GHOSTTY_SUCCESS) && accepted
        accepted = (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor) == GHOSTTY_SUCCESS) && accepted
        accepted = table.withUnsafeMutableBufferPointer { buffer in
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress) == GHOSTTY_SUCCESS
        } && accepted
        return accepted
    }

    private func destroyGhosttyState() {
        handles = GhosttyHandles()
    }

    private static func color(_ color: GhosttyColorRgb) -> Phase2TerminalGridColor {
        Phase2TerminalGridColor(red: color.r, green: color.g, blue: color.b)
    }
}

/// Owns opaque C handles so Swift's nonisolated object destruction can release them.
/// The enclosing main-actor model remains the sole accessor during the lifetime.
private final class GhosttyHandles: @unchecked Sendable {
    var terminal: GhosttyTerminal?
    var renderState: GhosttyRenderState?
    var rowIterator: GhosttyRenderStateRowIterator?
    var rowCells: GhosttyRenderStateRowCells?
    var mouseEncoder: GhosttyMouseEncoder?
    var mouseEvent: GhosttyMouseEvent?

    deinit {
        if let mouseEvent { ghostty_mouse_event_free(mouseEvent) }
        if let mouseEncoder { ghostty_mouse_encoder_free(mouseEncoder) }
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
    }
}
#endif
