import XCTest
@testable import MacScope

final class DebuggerAuthoredInputValidationTests: XCTestCase {
    func testEnvironmentKeyGrammarAcceptsOnlyPortableASCIIIdentifiers() {
        for key in ["A", "z", "_", "MACSCOPE_MODE", "_private9", "a0"] {
            XCTAssertTrue(
                DebuggerAuthoredInputValidation.isValidEnvironmentKey(key),
                "Expected \(key) to satisfy the frozen environment-key grammar."
            )
        }

        for key in ["", "9MODE", "MÖDE", "MODE-NAME", "MODE=fast", "MODE.NAME", " MODE"] {
            XCTAssertFalse(
                DebuggerAuthoredInputValidation.isValidEnvironmentKey(key),
                "Expected \(key) to fail the frozen environment-key grammar."
            )
        }
    }

    func testLaunchValidationSummaryUsesSharedGrammarBeforeNormalization() {
        let configuration = DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            environment: [
                "": "orphan",
                "-FLAG": "1",
                "A=B": "1",
                "MÖDE": "1",
                "9MODE": "1",
                "CONTROL\u{0007}KEY": "1",
                "SAFE": "line\nvalue",
                " DUP ": "first",
                "DUP": "second",
            ]
        )

        let summary = DebuggerLaunchValidationSummary.evaluate(
            configuration: configuration,
            launchSupport: .supported,
            requiresExecutableFile: false
        )

        XCTAssertFalse(summary.isLaunchable)
        XCTAssertTrue(summary.issues.contains(issue("Environment key cannot be empty.")))
        for key in ["-FLAG", "A=B", "MÖDE", "9MODE", "CONTROL\u{0007}KEY"] {
            XCTAssertTrue(
                summary.issues.contains(issue("Environment key \(key) contains unsupported characters.")),
                "Missing validation issue for \(key)."
            )
        }
        XCTAssertTrue(summary.issues.contains(issue("Environment key DUP is set more than once.")))
        XCTAssertTrue(summary.issues.contains(issue(
            "Environment value for SAFE contains unsupported control characters."
        )))
    }

    func testInvocationParserAcceptsEmptyValueAndSkipsOnlyTrulyBlankRows() throws {
        let draft = try parse([
            DebuggerEnvironmentEntry(key: " _MODE9 ", value: ""),
            DebuggerEnvironmentEntry(key: "", value: ""),
        ]).get()

        XCTAssertEqual(draft.environment, ["_MODE9": ""])

        assertParseFailure(
            [DebuggerEnvironmentEntry(key: "\t", value: "")],
            reason: "Environment key contains unsupported control characters."
        )
        assertParseFailure(
            [DebuggerEnvironmentEntry(key: " ", value: "orphan")],
            reason: "Environment key cannot be empty."
        )
    }

    func testInvocationParserPreservesSpecificKeyAndValueErrors() {
        assertParseFailure(
            [DebuggerEnvironmentEntry(key: "-FLAG", value: "1")],
            reason: "Environment key -FLAG cannot start with '-'."
        )
        assertParseFailure(
            [DebuggerEnvironmentEntry(key: "A=B", value: "1")],
            reason: "Environment key A=B cannot contain '='."
        )
        assertParseFailure(
            [DebuggerEnvironmentEntry(key: "A\u{0007}B", value: "1")],
            reason: "Environment key A\u{0007}B contains unsupported control characters."
        )
        assertParseFailure(
            [DebuggerEnvironmentEntry(key: "SAFE", value: "line\nvalue")],
            reason: "Environment value for SAFE contains unsupported control characters."
        )
    }

    func testInvocationParserRejectsUnicodeDigitLeadingAndDuplicateKeys() {
        assertParseFailure(
            [DebuggerEnvironmentEntry(key: "MÖDE", value: "1")],
            reason: "Environment key MÖDE must use ASCII letters, digits, or '_' and cannot start with a digit."
        )
        assertParseFailure(
            [DebuggerEnvironmentEntry(key: "9MODE", value: "1")],
            reason: "Environment key 9MODE must use ASCII letters, digits, or '_' and cannot start with a digit."
        )
        assertParseFailure(
            [
                DebuggerEnvironmentEntry(key: "MODE", value: "first"),
                DebuggerEnvironmentEntry(key: " MODE ", value: "second"),
            ],
            reason: "Environment key MODE is set more than once."
        )
    }

    private func parse(
        _ entries: [DebuggerEnvironmentEntry]
    ) -> Result<DebuggerLaunchInvocationDraft, DebuggerAuthoringParseError> {
        DebuggerLaunchInvocationDraft.parse(
            argumentsText: "",
            environmentEntries: entries,
            workingDirectoryText: ""
        )
    }

    private func assertParseFailure(
        _ entries: [DebuggerEnvironmentEntry],
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch parse(entries) {
        case .success:
            XCTFail("Expected authored environment to be rejected.", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error.reason, reason, file: file, line: line)
        }
    }

    private func issue(_ message: String) -> DebuggerLaunchValidationIssue {
        DebuggerLaunchValidationIssue(severity: .blocker, message: message)
    }
}
