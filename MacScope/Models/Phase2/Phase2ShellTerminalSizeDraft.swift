import Foundation

struct Phase2ShellTerminalSizeDraft: Equatable, Sendable {
    var columnsText: String
    var rowsText: String

    init(
        columnsText: String = "\(Phase2HumanPTYTerminalSize.defaultInteractive.columns)",
        rowsText: String = "\(Phase2HumanPTYTerminalSize.defaultInteractive.rows)"
    ) {
        self.columnsText = columnsText
        self.rowsText = rowsText
    }

    init(restoredTerminalSize size: Phase2HumanPTYTerminalSize) {
        columnsText = "\(size.columns)"
        rowsText = "\(size.rows)"
    }

    var normalizedTerminalSize: Phase2HumanPTYTerminalSize? {
        Self.normalizedTerminalSize(columnsText: columnsText, rowsText: rowsText)
    }

    var terminalSizeValidationMessage: String? {
        Self.validateTerminalSize(columnsText: columnsText, rowsText: rowsText)
    }

    static func normalizedTerminalSize(
        columnsText: String,
        rowsText: String
    ) -> Phase2HumanPTYTerminalSize? {
        let columns = columnsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = rowsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let columnCount = Int(columns), let rowCount = Int(rows) else { return nil }
        return Phase2HumanPTYTerminalSize(columns: columnCount, rows: rowCount)
    }

    static func validateTerminalSize(
        columnsText: String,
        rowsText: String
    ) -> String? {
        let trimmedColumns = columnsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRows = rowsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedColumns.isEmpty, !trimmedRows.isEmpty else {
            return "Terminal size requires columns and rows."
        }
        guard let size = normalizedTerminalSize(columnsText: columnsText, rowsText: rowsText) else {
            return "Terminal size must use whole-number columns and rows."
        }
        return validateTerminalSize(size)
    }

    static func validateTerminalSize(_ size: Phase2HumanPTYTerminalSize) -> String? {
        size.isValid ? nil : "Terminal size must be between 1×1 and 1000×1000."
    }
}
