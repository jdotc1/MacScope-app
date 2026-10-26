import AppKit
import ApplicationServices
import XCTest

/// Catches editor commands that lose their focused-store target or keyboard registration.
/// A direct selector is only the baseline; menu and keyboard routes must independently
/// change the installed document. Background delivery is a failed precondition, not success.
final class WorkspaceEditorCommandInstalledAppUITests: XCTestCase {
    @MainActor
    func testForegroundEditorMenuAndKeyboardParity() throws {
        continueAfterFailure = false
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        let fixture = try Task10InstalledWorkspaceFixture.copyIntoTemporaryDirectory()
        defer { fixture.remove() }
        harness.terminateExactCandidateIfRunning()
        defer { harness.terminateExactCandidateIfRunning() }

        let app = try harness.launch()
        var diagnosticAXWindow: AXUIElement?
        var diagnosticWindow: XCUIElement?
        do {
            app.activate()
            guard app.wait(for: .runningForeground, timeout: 10) else {
                throw failure("The attested candidate did not become foreground-active.")
            }
            try harness.openWorkspacePackage(fixture.packageURL, in: app)
            let title = fixture.packageURL.deletingPathExtension().lastPathComponent
            let axWindow = try harness.waitForFocusedWindow(
                titled: title, timeout: 15, context: "the command-parity fixture window"
            )
            _ = try harness.waitForAccessibilityDescendant(
                identified: InstalledAppUITestHarness.workspaceRootAccessibilityIdentifier,
                of: axWindow, depth: 10, timeout: 10, context: "the command-parity workspace"
            )
            let frame = try harness.waitForAccessibilityFrame(
                of: axWindow, context: "the command-parity fixture window"
            )
            let matches = app.windows.allElementsBoundByIndex.filter {
                abs($0.frame.minX - frame.minX) <= 4
                    && abs($0.frame.minY - frame.minY) <= 4
                    && abs($0.frame.width - frame.width) <= 4
                    && abs($0.frame.height - frame.height) <= 4
            }
            guard matches.count == 1, let window = matches.first else {
                throw failure("XCUITest did not uniquely match the focused fixture window.")
            }
            diagnosticAXWindow = axWindow
            diagnosticWindow = window

            try requireForeground(app, harness: harness, window: axWindow, stage: "direct baseline")
            let hex = window.radioButtons["Hex"]
            guard hex.waitForExistence(timeout: 10), hex.isEnabled else {
                throw failure("The fixture did not expose an enabled Hex selector.")
            }
            hex.click()
            try requireMode("Hex", in: window, context: "direct selector baseline")

            try requireForeground(app, harness: harness, window: axWindow, stage: "View Disassembly")
            try invokeViewCommand("Disassembly", in: app)
            try requireMode("Disassembly", in: window, context: "View menu")

            try requireForeground(app, harness: harness, window: axWindow, stage: "Command-4")
            app.typeKey("4", modifierFlags: .command)
            try requireMode("Hex", in: window, context: "Command-4")

            try requireForeground(app, harness: harness, window: axWindow, stage: "Command-1")
            retainFocusedElement(harness: harness, stage: "before original Command-1")
            app.typeKey("1", modifierFlags: .command)
            try requireMode("Disassembly", in: window, context: "Command-1")

            try requireForeground(app, harness: harness, window: axWindow, stage: "View Hex")
            try invokeViewCommand("Hex", in: app)
            try requireMode("Hex", in: window, context: "View menu")

            // Preserve the actual shipping shortcut: Shift-Command-Y, not Command-Y.
            // Both routes must open and dismiss the same native document sheet.
            for keyboard in [false, true] {
                let route = keyboard ? "Shift-Command-Y" : "View Navigation History"
                try requireForeground(app, harness: harness, window: axWindow, stage: route)
                if keyboard {
                    app.typeKey("y", modifierFlags: [.command, .shift])
                } else {
                    try invokeViewCommand("Navigation History", in: app)
                }
                let sheet = window.sheets.firstMatch
                guard sheet.waitForExistence(timeout: 5),
                      sheet.staticTexts["Navigation History"].waitForExistence(timeout: 5) else {
                    throw failure("\(route) did not present Navigation History in the fixture window.")
                }
                let done = sheet.buttons["Done"]
                guard done.waitForExistence(timeout: 5), done.isEnabled else {
                    throw failure("Navigation History did not expose its Done control.")
                }
                done.click()
                guard sheet.waitForNonExistence(timeout: 5) else {
                    throw failure("Navigation History did not dismiss after \(route).")
                }
            }

            // A sheet round trip must restore the document command target without an
            // activation retry that could conceal a focus-restoration regression.
            try requireForeground(app, harness: harness, window: axWindow, stage: "post-sheet Command-1")
            app.typeKey("1", modifierFlags: .command)
            try requireMode("Disassembly", in: window, context: "post-sheet Command-1")
            try requireForeground(app, harness: harness, window: axWindow, stage: "post-sheet Command-4")
            app.typeKey("4", modifierFlags: .command)
            try requireMode("Hex", in: window, context: "post-sheet Command-4")
            retainScreenshot(name: "Foreground editor command parity passed")
        } catch {
            retainScreenshot(name: "Foreground editor command parity failure")
            if let diagnosticAXWindow, let diagnosticWindow {
                retainFailureKeyProbes(app, harness: harness, axWindow: diagnosticAXWindow,
                                       window: diagnosticWindow, directHexBaseline: false)
            }
            retainFailureMenuEvidence(app, harness: harness)
            if let diagnosticAXWindow, let diagnosticWindow {
                retainFailureKeyProbes(app, harness: harness, axWindow: diagnosticAXWindow,
                                       window: diagnosticWindow, directHexBaseline: true)
            }
            throw error
        }
    }

    @MainActor
    private func retainFocusedElement(harness: InstalledAppUITestHarness, stage: String) {
        var lines = ["stage=\(stage)"]
        do {
            let application = try harness.accessibilityApplication()
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
            lines.append("focusedElementStatus=\(status.rawValue)")
            if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let element = unsafeDowncast(focused, to: AXUIElement.self)
                for attribute in [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXFocusedAttribute] {
                    var value: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                    lines.append("\(attribute): status=\(result.rawValue), value=\(String(describing: value))")
                }
            }
        } catch { lines.append("unavailable=\(error)") }
        let evidence = XCTAttachment(string: lines.joined(separator: "\n"))
        evidence.name = "Focused responder - \(stage)"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    /// Post-failure observations only. The original assertion is never retried or forgiven.
    @MainActor
    private func retainFailureKeyProbes(
        _ app: XCUIApplication, harness: InstalledAppUITestHarness,
        axWindow: AXUIElement, window: XCUIElement, directHexBaseline: Bool
    ) {
        do {
            if directHexBaseline {
                try requireForeground(app, harness: harness, window: axWindow, stage: "diagnostic direct Hex baseline")
                window.radioButtons["Hex"].click()
                try requireMode("Hex", in: window, context: "diagnostic direct Hex baseline")
            }
            let probes = directHexBaseline ? [("1", "Disassembly")] : [
                ("2", "Pseudocode"), ("3", "Graph"), ("4", "Hex"), ("1", "Disassembly")
            ]
            for (key, mode) in probes {
                let stage = "diagnostic \(directHexBaseline ? "after direct Hex" : "before menu census") Command-\(key)"
                try requireForeground(app, harness: harness, window: axWindow, stage: stage)
                retainFocusedElement(harness: harness, stage: stage)
                app.typeKey(key, modifierFlags: .command)
                var result = "expected mode observed"
                do { try requireMode(mode, in: window, context: stage) }
                catch { result = String(describing: error) }
                let states = ["Disassembly", "Pseudocode", "Graph", "Hex"].map {
                    "\($0)=\(String(describing: window.radioButtons[$0].value))"
                }
                let evidence = XCTAttachment(string: ([stage, result] + states).joined(separator: "\n"))
                evidence.name = stage
                evidence.lifetime = .keepAlways
                add(evidence)
            }
        } catch {
            let evidence = XCTAttachment(string: String(describing: error))
            evidence.name = "Post-failure key probe unavailable"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
    }

    /// Observe the advertised native binding only AFTER the unchanged assertion failed.
    /// Never turn a diagnostic menu action into a repair or replace the original error.
    @MainActor
    private func retainFailureMenuEvidence(_ app: XCUIApplication, harness: InstalledAppUITestHarness) {
        do {
            let candidate = try harness.requireRunningCandidate(timeout: 5, context: "failure menu diagnosis")
            guard app.state == .runningForeground, candidate.isActive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == candidate.processIdentifier else {
                throw failure("Failure-menu capture refused: the attested candidate is not foreground-active.")
            }
            let application = try harness.accessibilityApplication()
            var menuBarValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &menuBarValue)
            guard status == .success, let menuBarValue,
                  CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
                throw failure("Failure-menu capture could not read AXMenuBar: \(status.rawValue).")
            }
            let menuBar = unsafeDowncast(menuBarValue, to: AXUIElement.self)
            let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute,
                              kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdVirtualKeyAttribute]
            let commandTitles = Set(["Disassembly", "Pseudocode", "Graph", "Hex", "Navigation History"])
            var lines = ["candidatePID=\(candidate.processIdentifier)", "sourceCommit=\(harness.identity.sourceCommit)"]
            let menus = app.menuBars.menuBarItems.allElementsBoundByIndex
            guard !menus.isEmpty, menus.count <= 24 else {
                throw failure("Failure-menu census refused an empty or unbounded menu bar.")
            }
            for menu in menus {
                guard app.state == .runningForeground, candidate.isActive,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == candidate.processIdentifier else {
                    throw failure("Failure-menu census lost the attested foreground candidate.")
                }
                lines.append("openedMenu=\(menu.title)")
                menu.click()
                defer { app.typeKey(.escape, modifierFlags: []) }
                let items = harness.accessibilityDescendants(role: kAXMenuItemRole, of: menuBar, depth: 6)
                guard items.count <= 512 else { throw failure("Failure-menu census exceeded its item bound.") }
                for item in items {
                guard let title = harness.accessibilityString(attribute: kAXTitleAttribute as CFString, of: item),
                      commandTitles.contains(title)
                        || Set(["1", "2", "3", "4"]).contains(
                            harness.accessibilityString(attribute: kAXMenuItemCmdCharAttribute as CFString, of: item) ?? ""
                        ) else { continue }
                lines.append("command=\(title)")
                for attribute in attributes {
                    var value: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(item, attribute as CFString, &value)
                    lines.append("  \(attribute): status=\(result.rawValue), value=\(String(describing: value))")
                }
                }
                if menu.title == "View" { retainScreenshot(name: "Failure View menu open") }
            }
            let evidence = XCTAttachment(string: lines.joined(separator: "\n"))
            evidence.name = "Failure all menus numeric key equivalents"
            evidence.lifetime = .keepAlways
            add(evidence)
        } catch {
            let evidence = XCTAttachment(string: String(describing: error))
            evidence.name = "Failure View menu diagnostic unavailable"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
    }

    @MainActor
    private func requireForeground(
        _ app: XCUIApplication,
        harness: InstalledAppUITestHarness,
        window: AXUIElement,
        stage: String
    ) throws {
        let candidate = try harness.requireRunningCandidate(timeout: 5, context: stage)
        let focused = try harness.focusedAccessibilityWindow()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let sameWindow = CFEqual(focused, window)
        let evidence = XCTAttachment(string:
            "stage=\(stage)\nsourceCommit=\(harness.identity.sourceCommit)\n"
                + "executableSHA256=\(harness.identity.executableSHA256)\n"
                + "candidatePID=\(candidate.processIdentifier)\nfrontmostPID=\(String(describing: frontmostPID))\n"
                + "candidateActive=\(candidate.isActive)\nxcuiState=\(app.state.rawValue)\n"
                + "exactFixtureWindowFocused=\(sameWindow)\n"
        )
        evidence.name = "Command focus - \(stage)"
        evidence.lifetime = .keepAlways
        add(evidence)
        guard app.state == .runningForeground, candidate.isActive,
              frontmostPID == candidate.processIdentifier, sameWindow else {
            throw failure("\(stage): the exact fixture window was not foreground-focused; see focus attachment.")
        }
    }

    @MainActor
    private func invokeViewCommand(_ title: String, in app: XCUIApplication) throws {
        let menu = app.menuBars.menuBarItems["View"]
        guard menu.waitForExistence(timeout: 5) else { throw failure("View menu is missing.") }
        menu.click()
        let item = app.menuItems[title]
        let exists = item.waitForExistence(timeout: 5)
        let enabled = exists && item.isEnabled
        let evidence = XCTAttachment(string: "View > \(title): exists=\(exists), enabled=\(enabled)")
        evidence.name = "Command menu - \(title)"
        evidence.lifetime = .keepAlways
        add(evidence)
        guard enabled else { throw failure("View > \(title) is missing or disabled.") }
        item.click()
    }

    @MainActor
    private func requireMode(_ title: String, in window: XCUIElement, context: String) throws {
        let radio = window.radioButtons[title]
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard radio.exists else { return false }
            if let number = radio.value as? NSNumber { return number == NSNumber(value: 1) }
            return (radio.value as? String) == "1"
        }, object: nil)
        guard XCTWaiter.wait(for: [selected], timeout: 5) == .completed else {
            throw failure("\(context) did not select \(title); AX value=\(String(describing: radio.value)).")
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
        NSError(domain: "WorkspaceEditorCommandInstalledAppUITests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
