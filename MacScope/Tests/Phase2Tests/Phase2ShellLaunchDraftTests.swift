import XCTest

@testable import MacScope

final class Phase2ShellLaunchDraftTests: XCTestCase {
    func testLaunchDraftNormalizesExecutableArgumentsAndEnvironment() {
        let draft = Phase2ShellLaunchDraft(
            executablePathText: "  /bin/zsh  ",
            argumentsText: "-lc \"printf hi; exit 7\" '' escaped\\ value",
            environmentText: "TERM=xterm-256color; MACSCOPE_MODE=dev",
            workingDirectoryPathText: "  /tmp  "
        )

        XCTAssertEqual(draft.normalizedExecutablePath, "/bin/zsh")
        XCTAssertEqual(draft.normalizedArguments, ["-lc", "printf hi; exit 7", "", "escaped value"])
        XCTAssertEqual(draft.normalizedEnvironment, [
            "TERM": "xterm-256color",
            "MACSCOPE_MODE": "dev",
        ])
        XCTAssertEqual(draft.normalizedWorkingDirectoryPath, "/tmp")
        XCTAssertNil(draft.launchConfigurationValidationMessage)
    }

    func testLaunchDraftFormatsCopyableLaunchSummary() {
        let draft = Phase2ShellLaunchDraft(
            executablePathText: "  /bin/zsh  ",
            argumentsText: "-lc \"printf hi; exit 7\" '' plain",
            environmentText: "TERM=xterm-256color; MACSCOPE_NOTE=semi\\;line\\nslash\\\\",
            workingDirectoryPathText: "  /tmp  "
        )

        XCTAssertEqual(
            draft.launchSummaryClipboardText(terminalSize: Phase2HumanPTYTerminalSize(columns: 132, rows: 44)),
            """
            Shell Launch
            Executable: /bin/zsh
            Arguments: -lc 'printf hi; exit 7' '' plain
            Working directory: /tmp
            Terminal size: 132×44
            Environment:
              MACSCOPE_NOTE=semi\\;line\\nslash\\\\
              TERM=xterm-256color
            """
        )
    }

    func testLaunchDraftFormatsDefaultCopyableLaunchSummary() {
        let draft = Phase2ShellLaunchDraft(
            executablePathText: "/bin/zsh",
            argumentsText: "",
            environmentText: "",
            workingDirectoryPathText: ""
        )

        XCTAssertEqual(
            draft.launchSummaryClipboardText(terminalSize: .defaultInteractive),
            """
            Shell Launch
            Executable: /bin/zsh
            Arguments: (none)
            Working directory: ShellBroker default
            Terminal size: \(Phase2HumanPTYTerminalSize.defaultInteractive.columns)×\(Phase2HumanPTYTerminalSize.defaultInteractive.rows)
            Environment: (empty)
            """
        )
    }

    func testLaunchDraftDoesNotFormatInvalidLaunchSummary() {
        XCTAssertNil(
            Phase2ShellLaunchDraft(executablePathText: "zsh")
                .launchSummaryClipboardText(terminalSize: .defaultInteractive)
        )
        XCTAssertNil(
            Phase2ShellLaunchDraft(argumentsText: "\"unterminated")
                .launchSummaryClipboardText(terminalSize: .defaultInteractive)
        )
    }

    func testRestoredLaunchPlanFormatsBackIntoEditableDraft() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-restored-shell-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let draft = Phase2ShellLaunchDraft(restoredLaunchPlan: Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/zsh",
            arguments: ["-lc", "printf 'hi there'; exit 7", "", "plain"],
            environment: [
                "TERM": "xterm-256color",
                "MACSCOPE_NOTE": "semi;line\nslash\\",
            ],
            workingDirectoryPath: workingDirectory.path,
            initialSize: .defaultInteractive
        ))

        XCTAssertEqual(draft.executablePathText, "/bin/zsh")
        XCTAssertEqual(draft.normalizedArguments, ["-lc", "printf 'hi there'; exit 7", "", "plain"])
        XCTAssertEqual(draft.normalizedEnvironment, [
            "TERM": "xterm-256color",
            "MACSCOPE_NOTE": "semi;line\nslash\\",
        ])
        XCTAssertEqual(draft.normalizedWorkingDirectoryPath, workingDirectory.path)
        XCTAssertNil(draft.launchConfigurationValidationMessage)
    }

    func testLaunchDraftRejectsInvalidExecutableArgumentsAndEnvironment() {
        XCTAssertEqual(
            Phase2ShellLaunchDraft(executablePathText: "zsh").launchConfigurationValidationMessage,
            "Executable path must be absolute."
        )
        XCTAssertEqual(
            Phase2ShellLaunchDraft(argumentsText: "\"unterminated").launchConfigurationValidationMessage,
            "Arguments contain an unterminated quote."
        )
        XCTAssertEqual(
            Phase2ShellLaunchDraft(argumentsText: "dangling\\").launchConfigurationValidationMessage,
            "Arguments end with an unfinished escape."
        )
        XCTAssertEqual(
            Phase2ShellLaunchDraft(environmentText: "MISSING_EQUALS").launchConfigurationValidationMessage,
            "Environment entry must be KEY=value (MISSING_EQUALS)."
        )
        XCTAssertEqual(
            Phase2ShellLaunchDraft(environmentText: "BAD KEY=value").launchConfigurationValidationMessage,
            "Environment key contains an invalid character (BAD KEY)."
        )
        XCTAssertEqual(
            Phase2ShellLaunchDraft(environmentText: "A=1; A=2").launchConfigurationValidationMessage,
            "Environment key is duplicated (A)."
        )
    }

    func testLaunchDraftTrimsHumanControlledWorkingDirectory() {
        let draft = Phase2ShellLaunchDraft(workingDirectoryPathText: "  /tmp  \n")

        XCTAssertEqual(draft.normalizedWorkingDirectoryPath, "/tmp")
        XCTAssertNil(draft.workingDirectoryValidationMessage)
    }

    func testBlankLaunchDraftPreservesShellBrokerDefaultWorkingDirectory() {
        let draft = Phase2ShellLaunchDraft(workingDirectoryPathText: "   ")

        XCTAssertNil(draft.normalizedWorkingDirectoryPath)
        XCTAssertNil(draft.workingDirectoryValidationMessage)
    }

    func testLaunchDraftRejectsRelativeMissingAndFileWorkingDirectories() throws {
        XCTAssertEqual(
            Phase2ShellLaunchDraft(workingDirectoryPathText: "relative").workingDirectoryValidationMessage,
            "Working directory must be an absolute path."
        )
        XCTAssertEqual(
            Phase2ShellLaunchDraft(
                workingDirectoryPathText: "/tmp/macscope-missing-shell-cwd-fixture"
            ).workingDirectoryValidationMessage,
            "Working directory does not exist."
        )

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-shell-cwd-file-\(UUID().uuidString)")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertEqual(
            Phase2ShellLaunchDraft(workingDirectoryPathText: fileURL.path).workingDirectoryValidationMessage,
            "Working directory is not a directory."
        )
    }
}
