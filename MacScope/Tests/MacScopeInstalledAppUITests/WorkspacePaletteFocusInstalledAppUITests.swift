import AppKit
import ApplicationServices
import XCTest

/// Real foreground delivery proof. Typing is sent to the application, never by
/// clicking/typeText on a destination field, which could conceal a focus defect.
final class WorkspacePaletteFocusInstalledAppUITests: XCTestCase {
    @MainActor
    func testForegroundPaletteAddressAndEditorHandoffsAcceptTyping() throws {
        continueAfterFailure = false
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        let fixture = try Task10InstalledWorkspaceFixture.copyIntoTemporaryDirectory()
        defer { fixture.remove() }
        harness.terminateExactCandidateIfRunning()
        defer { harness.terminateExactCandidateIfRunning() }
        let app = try harness.launch()
        do {
            app.activate()
            try requireForeground(app, harness: harness, stage: "initial activation")
            try harness.openWorkspacePackage(fixture.packageURL, in: app)
            let axWindow = try harness.waitForFocusedWindow(
                titled: fixture.packageURL.deletingPathExtension().lastPathComponent,
                timeout: 15, context: "the palette-focus fixture window"
            )
            _ = try harness.waitForAccessibilityDescendant(
                identified: InstalledAppUITestHarness.workspaceRootAccessibilityIdentifier,
                of: axWindow, depth: 10, timeout: 10, context: "the palette-focus workspace"
            )
            let frame = try harness.waitForAccessibilityFrame(of: axWindow, context: "the palette-focus fixture window")
            let matches = app.windows.allElementsBoundByIndex.filter {
                abs($0.frame.minX - frame.minX) <= 4 && abs($0.frame.minY - frame.minY) <= 4
                    && abs($0.frame.width - frame.width) <= 4 && abs($0.frame.height - frame.height) <= 4
            }
            guard matches.count == 1, let window = matches.first else {
                throw failure("XCUITest did not uniquely match the focused fixture window.")
            }

            // An independent direct baseline must succeed without repairing the later palette route.
            try requireForeground(app, harness: harness, window: axWindow, stage: "direct Go to Address")
            try invokeNavigate("Go to Address...", in: app)
            let direct = try destinationInput("goToAddressInput", in: window)
            try typeWithoutRefocusing("0x123", into: direct, app: app, harness: harness, stage: "direct address")
            try cancelSheet(in: window)

            try requireForeground(app, harness: harness, window: axWindow, stage: "palette Go to Address")
            try invokePalette(query: "gtoadr", commandTitle: "Go to Address", in: app, window: window)
            let address = try destinationInput("goToAddressInput", in: window)
            try typeWithoutRefocusing("0x123", into: address, app: app, harness: harness, stage: "palette address")
            app.typeKey(.return, modifierFlags: [])
            let issue = window.sheets.firstMatch.staticTexts["goToAddressIssue"]
            guard issue.waitForExistence(timeout: 5) else {
                throw failure("Unmapped address did not expose the identified in-sheet issue.")
            }
            // macOS static text can expose rendered text as its value rather than
            // its label. Keep the exact sheet/identifier and full diagnostic contract.
            let issueLabel = issue.label
            let issueValue = issue.value as? String
            let expectedIssue = "Address 0x0000000000000123 is outside MacScope Sample Binary."
            let diagnosticEvidence = XCTAttachment(string:
                "identifier=\(issue.identifier)\nlabel=\(issueLabel)\nvalue=\(String(describing: issueValue))\nexpected=\(expectedIssue)"
            )
            diagnosticEvidence.name = "Palette authoritative address diagnostic"
            diagnosticEvidence.lifetime = .keepAlways
            add(diagnosticEvidence)
            guard issueLabel == expectedIssue || issueValue == expectedIssue else {
                throw failure("The identified in-sheet issue did not expose the exact authoritative outside-image diagnostic; see getter attachment.")
            }
            XCTAssertEqual(address.value as? String, "0x123", "Failed navigation must retain the query.")
            XCTAssertTrue(window.sheets.firstMatch.exists, "Failed navigation must retain the sheet.")

            // Correct the same field without clicking, then select the fixture's
            // recorded instruction so selected-target editor commands are available.
            try requireInputFocus(address, app: app, harness: harness, stage: "correcting failed address")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("0x100000000")
            XCTAssertEqual(address.value as? String, "0x100000000")
            XCTAssertTrue(issue.waitForNonExistence(timeout: 5), "Editing must clear old feedback.")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(window.sheets.firstMatch.waitForNonExistence(timeout: 5))

            for (query, title, text) in [
                ("Add/Edit Comment", "Add/Edit Comment", "palette focus comment"),
                ("Rename Symbol", "Rename Symbol", "palette_focus_rename")
            ] {
                try requireForeground(app, harness: harness, window: axWindow, stage: title)
                try invokePalette(query: query, commandTitle: title, in: app, window: window)
                let input = try destinationInput("overrideEditorInput", in: window)
                try requireInputFocus(input, app: app, harness: harness, stage: title)
                app.typeKey("a", modifierFlags: .command)
                try typeWithoutRefocusing(text, into: input, app: app, harness: harness, stage: title)
                try cancelSheet(in: window)
            }

            try requireForeground(app, harness: harness, window: axWindow, stage: "palette Escape")
            try invokeNavigate("Open Quickly...", in: app)
            let search = paletteSearch(in: window)
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            XCTAssertTrue(waitForKeyboardFocus(search), "Palette must own focus before Escape.")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Escape must dismiss the palette.")
            try requireForeground(app, harness: harness, window: axWindow, stage: "post-palette document command")
            app.typeKey("4", modifierFlags: .command)
            let hex = window.radioButtons["Hex"]
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard hex.exists else { return false }
                return (hex.value as? NSNumber) == NSNumber(value: 1) || (hex.value as? String) == "1"
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                           "Dismissal must restore usable document commands without another activation.")
            retainScreenshot(name: "Palette foreground focus and feedback passed")
        } catch {
            retainScreenshot(name: "Palette foreground focus and feedback failure")
            throw error
        }
    }

    @MainActor
    private func invokeNavigate(_ title: String, in app: XCUIApplication) throws {
        let menu = app.menuBars.menuBarItems["Navigate"]
        guard menu.waitForExistence(timeout: 5) else { throw failure("Navigate menu is missing.") }
        menu.click()
        let command = app.menuItems[title]
        guard command.waitForExistence(timeout: 5), command.isEnabled else {
            throw failure("Navigate > \(title) is missing or disabled.")
        }
        command.click()
    }

    @MainActor
    private func invokePalette(query: String, commandTitle: String, in app: XCUIApplication, window: XCUIElement) throws {
        try invokeNavigate("Open Quickly...", in: app)
        let search = paletteSearch(in: window)
        guard search.waitForExistence(timeout: 5), waitForKeyboardFocus(search) else {
            throw failure("The actual palette did not establish search-field focus.")
        }
        app.typeText(query)
        XCTAssertEqual(search.value as? String, query)
        guard window.buttons[commandTitle].waitForExistence(timeout: 5), window.buttons[commandTitle].isEnabled else {
            throw failure("Palette did not expose enabled \(commandTitle) for \(query).")
        }
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func paletteSearch(in window: XCUIElement) -> XCUIElement {
        window.textFields.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@", "Search commands", "Search commands")).firstMatch
    }

    @MainActor
    private func destinationInput(_ identifier: String, in window: XCUIElement) throws -> XCUIElement {
        let field = window.sheets.firstMatch.textFields[identifier]
        guard field.waitForExistence(timeout: 5) else { throw failure("Destination \(identifier) was not presented in the fixture window.") }
        return field
    }

    @MainActor
    private func typeWithoutRefocusing(_ text: String, into field: XCUIElement, app: XCUIApplication, harness: InstalledAppUITestHarness, stage: String) throws {
        try requireInputFocus(field, app: app, harness: harness, stage: stage)
        app.typeText(text)
        XCTAssertEqual(field.value as? String, text, "\(stage): application typing must reach the destination without a click.")
    }

    @MainActor
    private func requireInputFocus(_ field: XCUIElement, app: XCUIApplication, harness: InstalledAppUITestHarness, stage: String) throws {
        try requireForeground(app, harness: harness, stage: stage)
        guard waitForKeyboardFocus(field) else { throw failure("\(stage): destination field did not receive keyboard focus.") }
        var value: CFTypeRef?
        let axApp = try harness.accessibilityApplication()
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { throw failure("\(stage): focused AX element was unavailable.") }
        let focused = unsafeDowncast(value, to: AXUIElement.self)
        let identifier = harness.accessibilityString(attribute: kAXIdentifierAttribute as CFString, of: focused)
        let evidence = XCTAttachment(string: "stage=\(stage)\nxcuiIdentifier=\(field.identifier)\nfocusedAXIdentifier=\(String(describing: identifier))")
        evidence.name = "Palette destination focus - \(stage)"
        evidence.lifetime = .keepAlways
        add(evidence)
        guard identifier == field.identifier else { throw failure("\(stage): native AX focus did not belong to the destination field.") }
    }

    @MainActor
    private func waitForKeyboardFocus(_ field: XCUIElement) -> Bool {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hasKeyboardFocus == true"), object: field)
        return XCTWaiter.wait(for: [expected], timeout: 5) == .completed
    }

    @MainActor
    private func cancelSheet(in window: XCUIElement) throws {
        let sheet = window.sheets.firstMatch
        let cancel = sheet.buttons["Cancel"]
        guard cancel.waitForExistence(timeout: 5), cancel.isEnabled else { throw failure("Destination sheet did not expose Cancel.") }
        cancel.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func requireForeground(_ app: XCUIApplication, harness: InstalledAppUITestHarness, window: AXUIElement? = nil, stage: String) throws {
        guard app.wait(for: .runningForeground, timeout: 5) else { throw failure("\(stage): candidate is not foreground.") }
        let candidate = try harness.requireRunningCandidate(timeout: 5, context: stage)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let sameWindow = try window.map { CFEqual(try harness.focusedAccessibilityWindow(), $0) }
        let evidence = XCTAttachment(string: "stage=\(stage)\nsourceCommit=\(harness.identity.sourceCommit)\nexecutableSHA256=\(harness.identity.executableSHA256)\ncandidatePID=\(candidate.processIdentifier)\nfrontmostPID=\(String(describing: frontmost))\ncandidateActive=\(candidate.isActive)\nxcuiState=\(app.state.rawValue)\nexactFixtureWindowFocused=\(String(describing: sameWindow))")
        evidence.name = "Palette foreground preconditions - \(stage)"
        evidence.lifetime = .keepAlways
        add(evidence)
        guard candidate.isActive, frontmost == candidate.processIdentifier, sameWindow != false else {
            throw failure("\(stage): candidate identity or exact fixture window was not foreground-active.")
        }
    }

    @MainActor
    private func retainScreenshot(name: String) {
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = name
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "WorkspacePaletteFocusInstalledAppUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
