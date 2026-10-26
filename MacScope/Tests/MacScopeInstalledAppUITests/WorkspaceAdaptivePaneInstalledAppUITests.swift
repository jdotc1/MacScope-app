import AppKit
import ApplicationServices
import XCTest

/// Installed behavior proof for the workspace's native adaptive split view.
///
/// These tests deliberately observe window, pane, text, focus, and divider behavior through the
/// shipping accessibility boundary. They do not inspect source spellings or infer layout from a
/// screenshot. A screenshot can accompany qualification separately, but geometry remains the
/// authority here.
final class WorkspaceAdaptivePaneInstalledAppUITests: XCTestCase {
    private enum Identifier {
        static let root = "workspace.root"
        static let sidebar = "workspace.pane.sidebar"
        static let editor = "workspace.pane.editor"
        static let inspector = "workspace.pane.inspector"
    }

    private enum Contract {
        // The target compiles the same AppLayout.swift source as the app; the
        // separate UI runner does not import or load the application executable.
        static let sidebarWidths = AppLayout.sidebarMinWidth...AppLayout.sidebarMaxWidth
        static let inspectorWidths = AppLayout.inspectorMinWidth...AppLayout.inspectorMaxWidth
        static let editorMinimumWidth = AppLayout.editorMinimumReadableWidth
        static let frameTolerance: CGFloat = 3
        static let dividerTolerance: CGFloat = 12
        static let restoredWidthTolerance: CGFloat = 8
    }

    struct PaneSnapshot {
        let sidebarElement: AXUIElement
        let inspectorElement: AXUIElement?
        let root: CGRect
        let sidebar: CGRect
        let editor: CGRect
        let inspector: CGRect?
    }

    struct EssentialTextExpectation {
        enum Layout {
            case singleLine
            case wrapping
        }

        let accessibilityText: String
        let renderedText: String
        let font: NSFont
        let layout: Layout
        var isDisclosureHeader = false
    }

    @MainActor
    func testAdaptivePanesRemainInsideWideAndMinimumWindows() throws {
        continueAfterFailure = false
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        defer { harness.terminateExactCandidateIfRunning() }

        let app = try harness.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        // AX sizing works for a background application, but XCUI hittability
        // requires the candidate window to be foreground before testing controls.
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15),
            "The candidate did not become foreground before pane interaction (state: \(app.state.rawValue)).")
        try harness.setFocusedWindowSize(.wide)
        let window = try harness.focusedAccessibilityWindow()
        let wide = try paneSnapshot(
            harness: harness,
            window: window,
            expectsInspector: true
        )
        try retainGeometryEvidence(wide, stage: "wide", window: window, harness: harness, app: app)
        try assertPaneGeometry(wide, in: window, harness: harness)
        try assertEssentialText(
            sidebarEssentialTextExpectations(),
            remainsInside: wide.sidebar,
            accessibilityRoot: wide.sidebarElement,
            harness: harness,
            in: app
        )
        try assertEssentialText(
            inspectorEssentialTextExpectations(),
            remainsInside: try XCTUnwrap(wide.inspector),
            accessibilityRoot: try XCTUnwrap(wide.inspectorElement),
            harness: harness,
            in: app
        )

        try harness.setFocusedWindowSize(.minimum)
        guard waitForPaneCondition(timeout: 5, {
            (try? harness.hasAccessibilityDescendant(
                identified: Identifier.inspector,
                of: window,
                depth: 14
            )) == false
        }) else {
            throw paneFailure("The compact workspace did not retire the inspector pane.")
        }
        let compact = try paneSnapshot(
            harness: harness,
            window: window,
            expectsInspector: false
        )
        try retainGeometryEvidence(compact, stage: "minimum", window: window, harness: harness, app: app)
        try assertPaneGeometry(compact, in: window, harness: harness)
        XCTAssertEqual(
            compact.sidebar.minX,
            wide.sidebar.minX,
            accuracy: Contract.frameTolerance,
            "Retiring the compact inspector displaced the leading sidebar."
        )
        try assertEssentialText(
            sidebarEssentialTextExpectations(),
            remainsInside: compact.sidebar,
            accessibilityRoot: compact.sidebarElement,
            harness: harness,
            in: app
        )
        try assertCompactWelcomeReachability(in: app, panes: compact, harness: harness)
    }

    @MainActor
    func testNativeDividersMoveClampAndPreserveKeyboardFocus() throws {
        continueAfterFailure = false
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        defer { harness.terminateExactCandidateIfRunning() }

        let app = try harness.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        try harness.setFocusedWindowSize(.wide)
        let window = try harness.focusedAccessibilityWindow()
        var panes = try paneSnapshot(harness: harness, window: window, expectsInspector: true)
        let xcuiWindow = try matchingXCUIWindow(in: app, frame: try windowFrame(window, harness))

        let filter = app.textFields.matching(
            NSPredicate(format: "label == %@ OR placeholderValue == %@", "Filter project", "Filter project")
        ).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "The sidebar filter was not reachable.")
        filter.click()
        XCTAssertTrue(
            waitForKeyboardFocus(filter),
            "The sidebar filter did not receive keyboard focus before divider adjustment."
        )

        let initialSidebarWidth = panes.sidebar.width
        try dragRootDivider(
            nearest: panes.sidebar.maxX,
            toScreenX: min(panes.root.maxX - 1, panes.sidebar.maxX + 24),
            panes: panes,
            window: window,
            xcuiWindow: xcuiWindow,
            harness: harness
        )
        panes = try waitForPaneWidthChange(
            from: initialSidebarWidth,
            pane: .sidebar,
            window: window,
            harness: harness
        )
        XCTAssertGreaterThan(
            abs(panes.sidebar.width - initialSidebarWidth),
            6,
            "The leading native divider did not adjust the sidebar."
        )

        try dragRootDivider(
            nearest: panes.sidebar.maxX,
            toScreenX: panes.root.minX + 24,
            panes: panes,
            window: window,
            xcuiWindow: xcuiWindow,
            harness: harness
        )
        panes = try waitForPaneWidth(
            pane: .sidebar,
            window: window,
            harness: harness,
            satisfies: { $0 <= Contract.sidebarWidths.lowerBound + Contract.frameTolerance }
        )
        assertWidth(panes.sidebar.width, liesIn: Contract.sidebarWidths, name: "sidebar")
        try assertEssentialText(
            sidebarEssentialTextExpectations(),
            remainsInside: panes.sidebar,
            accessibilityRoot: panes.sidebarElement,
            harness: harness,
            in: app
        )

        try dragRootDivider(
            nearest: panes.sidebar.maxX,
            toScreenX: panes.root.minX + 620,
            panes: panes,
            window: window,
            xcuiWindow: xcuiWindow,
            harness: harness
        )
        panes = try waitForPaneWidth(
            pane: .sidebar,
            window: window,
            harness: harness,
            satisfies: { $0 >= Contract.sidebarWidths.upperBound - Contract.frameTolerance }
        )
        assertWidth(panes.sidebar.width, liesIn: Contract.sidebarWidths, name: "sidebar")

        let initialInspectorWidth = try XCTUnwrap(panes.inspector).width
        try dragRootDivider(
            nearest: panes.editor.maxX,
            toScreenX: panes.root.maxX - 24,
            panes: panes,
            window: window,
            xcuiWindow: xcuiWindow,
            harness: harness
        )
        panes = try waitForPaneWidth(
            pane: .inspector,
            window: window,
            harness: harness,
            satisfies: { $0 <= Contract.inspectorWidths.lowerBound + Contract.frameTolerance }
        )
        assertWidth(try XCTUnwrap(panes.inspector).width, liesIn: Contract.inspectorWidths, name: "inspector")
        try assertEssentialText(
            inspectorEssentialTextExpectations(),
            remainsInside: try XCTUnwrap(panes.inspector),
            accessibilityRoot: try XCTUnwrap(panes.inspectorElement),
            harness: harness,
            in: app
        )

        try dragRootDivider(
            nearest: panes.editor.maxX,
            toScreenX: panes.root.maxX - 620,
            panes: panes,
            window: window,
            xcuiWindow: xcuiWindow,
            harness: harness
        )
        panes = try waitForPaneWidth(
            pane: .inspector,
            window: window,
            harness: harness,
            satisfies: { $0 >= Contract.inspectorWidths.upperBound - Contract.frameTolerance }
        )
        let finalInspectorWidth = try XCTUnwrap(panes.inspector).width
        assertWidth(finalInspectorWidth, liesIn: Contract.inspectorWidths, name: "inspector")
        XCTAssertGreaterThan(
            abs(finalInspectorWidth - initialInspectorWidth),
            6,
            "The trailing native divider did not adjust the inspector."
        )
        XCTAssertTrue(
            waitForKeyboardFocus(filter),
            "Native divider adjustment discarded the sidebar filter's keyboard focus."
        )
        try assertPaneGeometry(panes, in: window, harness: harness)
    }

    @MainActor
    func testPaneWidthsRestoreAndRemainIndependentAcrossWindows() throws {
        continueAfterFailure = false
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        defer { harness.terminateExactCandidateIfRunning() }

        let app = try harness.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        try harness.setFocusedWindowSize(.wide)
        let firstWindow = try harness.focusedAccessibilityWindow()
        var first = try paneSnapshot(harness: harness, window: firstWindow, expectsInspector: true)
        let firstXCUIWindow = try matchingXCUIWindow(
            in: app,
            frame: try windowFrame(firstWindow, harness)
        )

        try dragRootDivider(
            nearest: first.sidebar.maxX,
            toScreenX: first.root.minX + 376,
            panes: first,
            window: firstWindow,
            xcuiWindow: firstXCUIWindow,
            harness: harness
        )
        first = try waitForPaneWidth(
            pane: .sidebar,
            window: firstWindow,
            harness: harness,
            satisfies: { $0 >= 368 }
        )
        try dragRootDivider(
            nearest: first.editor.maxX,
            toScreenX: first.root.maxX - 324,
            panes: first,
            window: firstWindow,
            xcuiWindow: firstXCUIWindow,
            harness: harness
        )
        first = try waitForPaneWidth(
            pane: .inspector,
            window: firstWindow,
            harness: harness,
            satisfies: { (316...332).contains($0) }
        )
        let restoredSidebarWidth = first.sidebar.width
        let restoredInspectorWidth = try XCTUnwrap(first.inspector).width

        try harness.setFocusedWindowSize(.minimum)
        guard waitForPaneCondition(timeout: 5, {
            (try? harness.hasAccessibilityDescendant(
                identified: Identifier.inspector,
                of: firstWindow,
                depth: 14
            )) == false
        }) else {
            throw paneFailure("The compact round trip did not retire the inspector.")
        }
        try harness.setFocusedWindowSize(.wide)
        first = try paneSnapshot(harness: harness, window: firstWindow, expectsInspector: true)
        XCTAssertEqual(
            first.sidebar.width,
            restoredSidebarWidth,
            accuracy: Contract.restoredWidthTolerance,
            "The same window did not restore its adjusted sidebar width."
        )
        XCTAssertEqual(
            try XCTUnwrap(first.inspector).width,
            restoredInspectorWidth,
            accuracy: Contract.restoredWidthTolerance,
            "The same window did not restore its adjusted inspector width."
        )

        app.typeKey("n", modifierFlags: .command)
        guard waitForPaneCondition(timeout: 10, { app.windows.count >= 2 }) else {
            throw paneFailure("New Window did not create a second workspace window.")
        }
        let secondWindow = try harness.focusedAccessibilityWindow()
        try harness.setFocusedWindowSize(.wide)
        var second = try paneSnapshot(harness: harness, window: secondWindow, expectsInspector: true)
        let secondXCUIWindow = try matchingXCUIWindow(
            in: app,
            frame: try windowFrame(secondWindow, harness)
        )
        try dragRootDivider(
            nearest: second.sidebar.maxX,
            toScreenX: second.root.minX + 332,
            panes: second,
            window: secondWindow,
            xcuiWindow: secondXCUIWindow,
            harness: harness
        )
        second = try waitForPaneWidth(
            pane: .sidebar,
            window: secondWindow,
            harness: harness,
            satisfies: { $0 <= 340 }
        )
        XCTAssertGreaterThan(
            abs(first.sidebar.width - second.sidebar.width),
            20,
            "The two windows did not retain independent sidebar divider positions."
        )
        let secondInspectorBaseline = try XCTUnwrap(second.inspector).width
        // Native split views may start at the 260-point minimum rather than idealWidth.
        // Choose the farther of two compact targets so the drag actually moves the pane,
        // while both targets remain distinct from the first window's adjusted 324 points.
        let secondInspectorTarget: CGFloat = secondInspectorBaseline < 276 ? 288 : 264
        try dragRootDivider(
            nearest: second.editor.maxX,
            toScreenX: second.root.maxX - secondInspectorTarget,
            panes: second,
            window: secondWindow,
            xcuiWindow: secondXCUIWindow,
            harness: harness
        )
        second = try waitForPaneWidth(
            pane: .inspector,
            window: secondWindow,
            harness: harness,
            satisfies: {
                abs($0 - secondInspectorTarget) <= 8 && abs($0 - secondInspectorBaseline) > 6
            }
        )
        let secondInspectorWidth = try XCTUnwrap(second.inspector).width
        XCTAssertGreaterThan(
            abs(secondInspectorWidth - secondInspectorBaseline),
            6,
            "The second window's trailing divider did not adjust its inspector."
        )
        XCTAssertGreaterThan(
            abs(restoredInspectorWidth - secondInspectorWidth),
            24,
            "The two windows did not retain independent inspector divider positions."
        )

        try harness.raiseAccessibilityWindow(firstWindow)
        let firstAfterSecondWindow = try paneSnapshot(
            harness: harness,
            window: firstWindow,
            expectsInspector: true
        )
        XCTAssertEqual(
            firstAfterSecondWindow.sidebar.width,
            restoredSidebarWidth,
            accuracy: Contract.restoredWidthTolerance,
            "Adjusting the second window changed the first window's sidebar width."
        )
        XCTAssertEqual(
            try XCTUnwrap(firstAfterSecondWindow.inspector).width,
            restoredInspectorWidth,
            accuracy: Contract.restoredWidthTolerance,
            "Adjusting the second window changed the first window's inspector width."
        )

        try harness.raiseAccessibilityWindow(secondWindow)
        let secondAfterFirstWindow = try paneSnapshot(
            harness: harness,
            window: secondWindow,
            expectsInspector: true
        )
        XCTAssertEqual(
            secondAfterFirstWindow.sidebar.width,
            second.sidebar.width,
            accuracy: Contract.restoredWidthTolerance,
            "Raising the first window changed the second window's sidebar width."
        )
        XCTAssertEqual(
            try XCTUnwrap(secondAfterFirstWindow.inspector).width,
            secondInspectorWidth,
            accuracy: Contract.restoredWidthTolerance,
            "Raising the first window changed the second window's inspector width."
        )
    }
}

private extension WorkspaceAdaptivePaneInstalledAppUITests {
    enum Pane {
        case sidebar
        case inspector
    }

    @MainActor
    func paneSnapshot(
        harness: InstalledAppUITestHarness,
        window: AXUIElement,
        expectsInspector: Bool
    ) throws -> PaneSnapshot {
        let rootElement = try harness.waitForAccessibilityDescendant(
            identified: Identifier.root,
            of: window,
            depth: 14,
            timeout: 5,
            context: "the workspace root"
        )
        let sidebarElement = try harness.waitForAccessibilityDescendant(
            identified: Identifier.sidebar,
            of: rootElement,
            depth: 14,
            timeout: 5,
            context: "the workspace sidebar"
        )
        let editorElement = try harness.waitForAccessibilityDescendant(
            identified: Identifier.editor,
            of: rootElement,
            depth: 14,
            timeout: 5,
            context: "the workspace editor"
        )
        let inspectorElement: AXUIElement?
        if expectsInspector {
            inspectorElement = try harness.waitForAccessibilityDescendant(
                identified: Identifier.inspector,
                of: rootElement,
                depth: 14,
                timeout: 5,
                context: "the workspace inspector"
            )
        } else {
            let isPresent = try harness.hasAccessibilityDescendant(
                identified: Identifier.inspector,
                of: rootElement,
                depth: 14
            )
            XCTAssertFalse(isPresent, "The compact workspace retained an inspector pane.")
            inspectorElement = nil
        }

        return PaneSnapshot(
            sidebarElement: sidebarElement,
            inspectorElement: inspectorElement,
            root: try harness.waitForAccessibilityFrame(of: rootElement, context: "workspace root"),
            sidebar: try harness.waitForAccessibilityFrame(of: sidebarElement, context: "sidebar"),
            editor: try harness.waitForAccessibilityFrame(of: editorElement, context: "editor"),
            inspector: try inspectorElement.map {
                try harness.waitForAccessibilityFrame(of: $0, context: "inspector")
            }
        )
    }

    @MainActor
    private func assertCompactWelcomeReachability(
        in app: XCUIApplication,
        panes: PaneSnapshot,
        harness: InstalledAppUITestHarness
    ) throws {
        // Lumen's empty hero carries the identifier on the hero itself (Lumen 0.34.2), so it exists
        // whether or not the hero currently scrolls.
        let welcome = app.descendants(matching: .any).matching(identifier: "workspace.empty.scroll").firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout: 5), "The empty welcome needs a contained viewport.")
        assertContained(welcome.frame, in: panes.editor, name: "welcome viewport")
        for identifier in ["workspace.empty.open-binary", "workspace.empty.open-workspace"] {
            let action = app.buttons.matching(identifier: identifier).firstMatch
            XCTAssertTrue(action.isHittable, "The compact welcome must keep its opening actions reachable.")
            assertContained(action.frame, in: welcome.frame, name: "welcome opening action")
        }

        // Preserve real recent-document history: inspect and scroll, but never open or clear it.
        let recents = app.buttons.matching(identifier: "workspace.empty.recents")
        if recents.count > 0 {
            let last = recents.element(boundBy: recents.count - 1)
            for _ in 0..<5 {
                if last.isHittable && welcome.frame.contains(last.frame) { break }
                welcome.scroll(byDeltaX: 0, deltaY: -120)
            }
            XCTAssertTrue(last.isHittable, "The last recent workspace must be reachable by scrolling.")
            assertContained(last.frame, in: welcome.frame, name: "last recent workspace")
        }

        let window = try harness.focusedAccessibilityWindow()
        let debugger = try harness.waitForAccessibilityDescendant(
            identified: "debugger.deck", of: window, depth: 14, timeout: 5,
            context: "the compact debugger deck"
        )
        assertContained(
            try harness.waitForAccessibilityFrame(of: debugger, context: "compact debugger deck"),
            in: panes.editor, name: "debugger deck"
        )
    }

    @MainActor
    private func retainGeometryEvidence(
        _ panes: PaneSnapshot,
        stage: String,
        window: AXUIElement,
        harness: InstalledAppUITestHarness,
        app: XCUIApplication
    ) throws {
        let geometry = "\(stage): window=\(try windowFrame(window, harness)) "
            + "root=\(panes.root) sidebar=\(panes.sidebar) editor=\(panes.editor) "
            + "inspector=\(String(describing: panes.inspector))"
        print(geometry)
        let text = XCTAttachment(string: geometry + "\n" + app.debugDescription)
        text.name = "adaptive-pane-\(stage)-geometry"
        text.lifetime = .keepAlways
        add(text)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "adaptive-pane-\(stage)-window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func assertPaneGeometry(
        _ panes: PaneSnapshot,
        in window: AXUIElement,
        harness: InstalledAppUITestHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let window = try windowFrame(window, harness)
        assertContained(panes.root, in: window, name: "workspace root", file: file, line: line)
        assertContained(panes.sidebar, in: panes.root, name: "sidebar", file: file, line: line)
        assertContained(panes.editor, in: panes.root, name: "editor", file: file, line: line)
        assertWidth(panes.sidebar.width, liesIn: Contract.sidebarWidths, name: "sidebar", file: file, line: line)
        XCTAssertTrue(
            Contract.editorMinimumWidth.isFinite,
            "Installed pane tests must compile against the live AppLayout authority.",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            panes.editor.width,
            Contract.editorMinimumWidth - Contract.frameTolerance,
            "Editor is narrower than AppLayout.editorMinimumReadableWidth.",
            file: file,
            line: line
        )
        XCTAssertEqual(
            panes.sidebar.minX,
            panes.root.minX,
            accuracy: Contract.dividerTolerance,
            "Sidebar does not reach the workspace root's leading edge.",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            panes.sidebar.maxX,
            panes.editor.minX + Contract.frameTolerance,
            "Sidebar and editor overlap.",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            panes.editor.minX - panes.sidebar.maxX,
            Contract.dividerTolerance,
            "Sidebar and editor are not adjacent.",
            file: file,
            line: line
        )

        if let inspector = panes.inspector {
            assertContained(inspector, in: panes.root, name: "inspector", file: file, line: line)
            assertWidth(inspector.width, liesIn: Contract.inspectorWidths, name: "inspector", file: file, line: line)
            XCTAssertLessThanOrEqual(
                panes.editor.maxX,
                inspector.minX + Contract.frameTolerance,
                "Editor and inspector overlap.",
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                inspector.minX - panes.editor.maxX,
                Contract.dividerTolerance,
                "Editor and inspector are not adjacent.",
                file: file,
                line: line
            )
            XCTAssertEqual(
                inspector.maxX,
                panes.root.maxX,
                accuracy: Contract.dividerTolerance,
                "Inspector does not reach the workspace root's trailing edge.",
                file: file,
                line: line
            )
        } else {
            XCTAssertEqual(
                panes.editor.maxX,
                panes.root.maxX,
                accuracy: Contract.dividerTolerance,
                "Compact editor does not reach the workspace root's trailing edge.",
                file: file,
                line: line
            )
        }
    }

    func assertContained(
        _ child: CGRect,
        in parent: CGRect,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tolerance = Contract.frameTolerance
        XCTAssertGreaterThanOrEqual(child.minX, parent.minX - tolerance, "\(name) extends left of its owner.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(child.minY, parent.minY - tolerance, "\(name) extends above its owner.", file: file, line: line)
        XCTAssertLessThanOrEqual(child.maxX, parent.maxX + tolerance, "\(name) extends right of its owner.", file: file, line: line)
        XCTAssertLessThanOrEqual(child.maxY, parent.maxY + tolerance, "\(name) extends below its owner.", file: file, line: line)
    }

    func assertWidth(
        _ width: CGFloat,
        liesIn range: ClosedRange<CGFloat>,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            width,
            range.lowerBound - Contract.frameTolerance,
            "\(name) is narrower than its supported minimum.",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            width,
            range.upperBound + Contract.frameTolerance,
            "\(name) is wider than its supported maximum.",
            file: file,
            line: line
        )
    }

    @MainActor
    func sidebarEssentialTextExpectations() -> [EssentialTextExpectation] {
        [
            EssentialTextExpectation(
                accessibilityText: "Project",
                renderedText: "Project",
                font: NSFont.preferredFont(forTextStyle: .headline),
                layout: .singleLine
            ),
            EssentialTextExpectation(
                accessibilityText: "MacScope Workspace",
                renderedText: "MacScope Workspace",
                font: NSFont.preferredFont(forTextStyle: .caption1),
                layout: .singleLine
            ),
        ]
    }

    @MainActor
    func inspectorEssentialTextExpectations() -> [EssentialTextExpectation] {
        let caption = NSFont.preferredFont(forTextStyle: .caption1)
        return [
            EssentialTextExpectation(
                accessibilityText: "Inspector",
                renderedText: "Inspector",
                font: NSFont.preferredFont(forTextStyle: .headline),
                layout: .singleLine
            ),
            EssentialTextExpectation(
                accessibilityText: "Selection",
                renderedText: "Selection",
                font: NSFont.systemFont(ofSize: caption.pointSize, weight: .semibold),
                layout: .singleLine,
                isDisclosureHeader: true
            ),
            EssentialTextExpectation(
                accessibilityText: "Select an instruction to inspect bytes, operands, xrefs, and debugger context.",
                renderedText: "Select an instruction to inspect bytes, operands, xrefs, and debugger context.",
                font: caption,
                layout: .wrapping
            ),
        ]
    }

    @MainActor
    func assertEssentialText(
        _ expectations: [EssentialTextExpectation],
        remainsInside pane: CGRect,
        accessibilityRoot: AXUIElement,
        harness: InstalledAppUITestHarness,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for expectation in expectations {
            // A collapsible section exposes its title on the disclosure button;
            // ordinary text can expose its string as value or title instead of label.
            let expectedStrings = [expectation.accessibilityText, expectation.renderedText]
            let elementType: XCUIElement.ElementType = expectation.isDisclosureHeader ? .button : .staticText
            let query = app.descendants(matching: elementType).matching(NSPredicate(
                format: "label IN %@ OR title IN %@ OR value IN %@",
                expectedStrings, expectedStrings, expectedStrings
            ))
            // XCUI can omit a value-only static-text match even when the pane's
            // native AX tree exposes that exact text. Use the actual descendant
            // and its fresh frame, never the enclosing pane's accessible label.
            let nativeTextElement: () -> AXUIElement? = { [self] in
                harness.accessibilityDescendants(
                    role: (expectation.isDisclosureHeader ? kAXButtonRole : kAXStaticTextRole) as String,
                    of: accessibilityRoot,
                    depth: 14
                ).first {
                    guard accessibilityDisplayedText(of: $0, matchingAny: expectedStrings,
                        harness: harness) != nil,
                        let frame = harness.accessibilityFrame(of: $0) else { return false }
                    return pane.intersects(frame)
                }
            }
            guard waitForPaneCondition(timeout: 5, {
                query.allElementsBoundByIndex.contains(where: {
                    $0.exists && pane.intersects($0.frame)
                }) || (!expectation.isDisclosureHeader && nativeTextElement() != nil)
            }) else {
                throw paneFailure(
                    "The pane did not expose essential text '\(expectation.accessibilityText)'."
                )
            }
            let element = query.allElementsBoundByIndex.first(where: {
                $0.exists && pane.intersects($0.frame)
            })
            let accessibilityTextElement = nativeTextElement()
            let nativeFrame = accessibilityTextElement.flatMap { harness.accessibilityFrame(of: $0) }
            guard let textFrame = element?.frame ?? (expectation.isDisclosureHeader ? nil : nativeFrame) else {
                throw paneFailure(
                    "The pane did not expose essential text '\(expectation.accessibilityText)'."
                )
            }
            assertContained(
                textFrame,
                in: pane,
                name: "essential text '\(expectation.accessibilityText)'",
                file: file,
                line: line
            )
            if expectation.isDisclosureHeader {
                let disclosure = try XCTUnwrap(element, file: file, line: line)
                XCTAssertTrue(disclosure.isHittable, "The section disclosure header is not reachable.", file: file, line: line)
            }

            // AXVisibleCharacterRange describes AXValue, not an independently
            // matched title/description. A disclosure's value is its state
            // ("Expanded"), whose character count cannot prove its title fits.
            if !expectation.isDisclosureHeader, let accessibilityTextElement,
               let exposedValue = harness.accessibilityString(attribute: kAXValueAttribute as CFString,
                   of: accessibilityTextElement), expectedStrings.contains(exposedValue) {
                switch try harness.accessibilityCharacterVisibility(of: accessibilityTextElement) {
                case .visibleRange(let visibleRange):
                    let completeRange = CFRange(
                        location: 0,
                        length: exposedValue.utf16.count
                    )
                    XCTAssertEqual(
                        visibleRange.location,
                        completeRange.location,
                        "Essential text starts outside its visible accessibility range.",
                        file: file,
                        line: line
                    )
                    XCTAssertEqual(
                        visibleRange.length,
                        completeRange.length,
                        "Accessibility reports only part of the essential text as visible.",
                        file: file,
                        line: line
                    )
                case .unsupported:
                    break
                }
            }

            assertRenderedTextFits(
                expectation,
                in: textFrame,
                file: file,
                line: line
            )
        }
    }

    @MainActor
    func accessibilityDisplayedText(
        of element: AXUIElement,
        matchingAny expectedStrings: [String],
        harness: InstalledAppUITestHarness
    ) -> String? {
        let expectedStrings = Set(expectedStrings)
        return [
            kAXTitleAttribute,
            kAXValueAttribute,
            kAXDescriptionAttribute,
        ].compactMap {
            harness.accessibilityString(attribute: $0 as CFString, of: element)
        }.first(where: expectedStrings.contains)
    }

    func assertRenderedTextFits(
        _ expectation: EssentialTextExpectation,
        in frame: CGRect,
        file: StaticString,
        line: UInt
    ) {
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            XCTFail(
                "Neither accessibility nor rendered geometry can prove essential text visibility.",
                file: file,
                line: line
            )
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: expectation.font]
        let measurementTolerance: CGFloat = 2
        switch expectation.layout {
        case .singleLine:
            let required = (expectation.renderedText as NSString).size(withAttributes: attributes)
            guard required.width.isFinite, required.height.isFinite else {
                XCTFail(
                    "AppKit could not measure essential text '\(expectation.renderedText)'.",
                    file: file,
                    line: line
                )
                return
            }
            XCTAssertGreaterThanOrEqual(
                frame.width + measurementTolerance,
                ceil(required.width),
                "Rendered width cannot contain essential text '\(expectation.renderedText)' without truncation.",
                file: file,
                line: line
            )
        case .wrapping:
            let required = (expectation.renderedText as NSString).boundingRect(
                with: CGSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            guard required.width.isFinite, required.height.isFinite else {
                XCTFail(
                    "AppKit could not measure wrapped essential text '\(expectation.renderedText)'.",
                    file: file,
                    line: line
                )
                return
            }
            XCTAssertGreaterThanOrEqual(
                frame.height + measurementTolerance,
                ceil(required.height),
                "Rendered height cannot contain all lines of essential text '\(expectation.renderedText)'.",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    func dragRootDivider(
        nearest boundaryX: CGFloat,
        toScreenX destinationX: CGFloat,
        panes: PaneSnapshot,
        window: AXUIElement,
        xcuiWindow: XCUIElement,
        harness: InstalledAppUITestHarness
    ) throws {
        let candidates = harness.accessibilityDescendants(
            role: kAXSplitterRole as String,
            of: window,
            depth: 14
        ).compactMap { splitter -> (AXUIElement, CGRect)? in
            guard let frame = harness.accessibilityFrame(of: splitter),
                  frame.height >= panes.root.height * 0.7,
                  frame.midX >= panes.root.minX - Contract.dividerTolerance,
                  frame.midX <= panes.root.maxX + Contract.dividerTolerance else {
                return nil
            }
            return (splitter, frame)
        }
        guard let splitter = candidates.min(by: {
            abs($0.1.midX - boundaryX) < abs($1.1.midX - boundaryX)
        }), abs(splitter.1.midX - boundaryX) <= Contract.dividerTolerance else {
            throw paneFailure("Accessibility did not expose the requested native root divider.")
        }
        let windowFrame = xcuiWindow.frame
        guard windowFrame.width > 0, windowFrame.height > 0 else {
            throw paneFailure("XCUITest did not expose a nonempty window frame for divider input.")
        }
        let start = xcuiWindow.coordinate(withNormalizedOffset: CGVector(
            dx: (splitter.1.midX - windowFrame.minX) / windowFrame.width,
            dy: (splitter.1.midY - windowFrame.minY) / windowFrame.height
        ))
        let destination = xcuiWindow.coordinate(withNormalizedOffset: CGVector(
            dx: (destinationX - windowFrame.minX) / windowFrame.width,
            dy: (splitter.1.midY - windowFrame.minY) / windowFrame.height
        ))
        // Native macOS divider input is a mouse drag, not a touch press gesture.
        // The default velocity compresses short adjustments into sub-60ms gestures that can
        // leave native dividers stationary despite a verified splitter hit. Use a deliberate
        // mouse drag without changing its endpoints or any movement/clamp/focus assertions.
        start.click(
            forDuration: 0.2,
            thenDragTo: destination,
            withVelocity: XCUIGestureVelocity(rawValue: 100),
            thenHoldForDuration: 0
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    @MainActor
    func waitForPaneWidthChange(
        from priorWidth: CGFloat,
        pane: Pane,
        window: AXUIElement,
        harness: InstalledAppUITestHarness
    ) throws -> PaneSnapshot {
        try waitForPaneWidth(
            pane: pane,
            window: window,
            harness: harness,
            satisfies: { abs($0 - priorWidth) > 6 }
        )
    }

    @MainActor
    func waitForPaneWidth(
        pane: Pane,
        window: AXUIElement,
        harness: InstalledAppUITestHarness,
        satisfies predicate: (CGFloat) -> Bool
    ) throws -> PaneSnapshot {
        let deadline = Date().addingTimeInterval(5)
        var lastObservedWidth: CGFloat?
        repeat {
            if let snapshot = try? paneSnapshot(
                harness: harness,
                window: window,
                expectsInspector: true
            ) {
                let width = pane == .sidebar ? snapshot.sidebar.width : snapshot.inspector?.width
                lastObservedWidth = width
                if let width, predicate(width) { return snapshot }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw paneFailure(
            "The \(pane) pane did not settle at the requested divider position; "
                + "last observed width: \(lastObservedWidth.map { "\($0)" } ?? "unavailable")."
        )
    }

    @MainActor
    func matchingXCUIWindow(in app: XCUIApplication, frame: CGRect) throws -> XCUIElement {
        guard waitForPaneCondition(timeout: 5, { !app.windows.allElementsBoundByIndex.isEmpty }),
              let window = app.windows.allElementsBoundByIndex.min(by: {
                  frameDistance($0.frame, frame) < frameDistance($1.frame, frame)
              }),
              frameDistance(window.frame, frame) <= 16 else {
            throw paneFailure("XCUITest could not match the focused accessibility window.")
        }
        return window
    }

    func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    @MainActor
    func windowFrame(
        _ window: AXUIElement,
        _ harness: InstalledAppUITestHarness
    ) throws -> CGRect {
        try harness.waitForAccessibilityFrame(of: window, context: "installed-app window")
    }

    @MainActor
    func waitForKeyboardFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

@MainActor
private func waitForPaneCondition(
    timeout: TimeInterval,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return predicate()
}

private func paneFailure(_ message: String) -> NSError {
    NSError(
        domain: "MacScopeInstalledAppUITests.AdaptivePane",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
