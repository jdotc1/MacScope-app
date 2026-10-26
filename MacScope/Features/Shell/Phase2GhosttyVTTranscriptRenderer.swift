import Foundation

#if canImport(GhosttyVt)
import GhosttyVt
#endif

enum Phase2GhosttyVTTranscriptRenderer {
    static func renderPlainText(
        terminalText: String,
        columns: Int = 120,
        rows: Int = 40
    ) -> String? {
        renderPlainText(
            bytes: Array(terminalText.utf8),
            columns: columns,
            rows: rows
        )
    }

    static func renderPlainText(
        bytes: [UInt8],
        columns: Int = 120,
        rows: Int = 40
    ) -> String? {
        #if canImport(GhosttyVt)
        guard !bytes.isEmpty else { return "" }

        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(
            nil,
            &terminal,
            UInt16(max(1, min(columns, Int(UInt16.max)))),
            UInt16(max(1, min(rows, Int(UInt16.max))))
        ) == GHOSTTY_SUCCESS,
              let terminal
        else {
            return nil
        }
        defer { ghostty_terminal_free(terminal) }
        // Upstream removed the creation-time options struct; scrollback is now a
        // post-create setter. The prior max_scrollback of 10_000 maps to the
        // line-count limit (the classic 10k-line scrollback budget).
        var maxScrollbackLines = size_t(10_000)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &maxScrollbackLines)

        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ghostty_terminal_vt_write(terminal, baseAddress, buffer.count)
        }

        var formatterOptions = GhosttyFormatterTerminalOptions()
        formatterOptions.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        formatterOptions.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        formatterOptions.trim = true

        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal, formatterOptions) == GHOSTTY_SUCCESS,
              let formatter
        else {
            return nil
        }
        defer { ghostty_formatter_free(formatter) }

        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &buffer, &length) == GHOSTTY_SUCCESS,
              let buffer
        else {
            return nil
        }
        defer { ghostty_free(nil, buffer, length) }

        return String(data: Data(bytes: buffer, count: length), encoding: .utf8)
        #else
        return nil
        #endif
    }
}
