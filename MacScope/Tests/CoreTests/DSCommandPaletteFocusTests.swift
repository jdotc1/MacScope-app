import AppKit
import XCTest
@testable import MacScope

/// Context-policy tests, not foreground keyboard-delivery proof. Bare NSHostingView
/// fixtures did not establish key-window or text-editing preconditions in CoreTests.
/// Real typing/handoffs live in WorkspacePaletteFocusInstalledAppUITests instead.
@MainActor
final class DSCommandPaletteFocusTests: XCTestCase {
    func testDismissalClearsOnlyOriginatingKeyWindowSynchronously() {
        let store = makeStore()
        let origin = PolicyWindow()
        let other = PolicyWindow()
        defer { other.close(); origin.close() }
        origin.resetFocusClearCalls()
        other.resetFocusClearCalls()
        let context = DSCommandPaletteWindowContext()
        context.window = origin

        origin.reportsKeyWindow = false
        other.reportsKeyWindow = true
        XCTAssertFalse(origin.isKeyWindow)
        XCTAssertTrue(other.isKeyWindow)
        store.isCommandPalettePresented = true
        context.dismissPalette(in: store)
        XCTAssertFalse(store.isCommandPalettePresented)
        XCTAssertEqual(origin.focusClearCalls, 0)
        XCTAssertEqual(other.focusClearCalls, 0)

        origin.reportsKeyWindow = true
        other.reportsKeyWindow = false
        XCTAssertTrue(origin.isKeyWindow)
        XCTAssertNil(origin.attachedSheet)
        store.isCommandPalettePresented = true
        context.dismissPalette(in: store)
        XCTAssertFalse(store.isCommandPalettePresented)
        XCTAssertEqual(origin.focusClearCalls, 1, "Cleanup must finish synchronously in the origin.")
        XCTAssertEqual(other.focusClearCalls, 0)

        context.dismissPalette(in: store)
        XCTAssertEqual(origin.focusClearCalls, 1, "An already-dismissed palette has no focus authority.")
    }

    func testLateDismissalCannotClearAnAlreadyPresentedSheet() {
        let store = makeStore()
        let origin = PolicyWindow()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = FocusResponderView()
        defer {
            origin.endSheet(sheet)
            sheet.close()
            origin.close()
        }
        origin.beginSheet(sheet, completionHandler: nil)
        origin.reportsKeyWindow = true
        XCTAssertTrue(origin.isKeyWindow)
        XCTAssertTrue(origin.attachedSheet === sheet)
        let responder = sheet.contentView
        XCTAssertTrue(sheet.makeFirstResponder(responder))
        origin.resetFocusClearCalls()
        let context = DSCommandPaletteWindowContext()
        context.window = origin
        store.isCommandPalettePresented = true
        context.dismissPalette(in: store)
        XCTAssertEqual(origin.focusClearCalls, 0, "An attached destination sheet blocks origin cleanup even if key.")
        XCTAssertTrue(sheet.firstResponder === responder)
        XCTAssertFalse(store.isCommandPalettePresented)
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(workspaceName: "Palette Focus", snapshot: AnalysisEngine.previewSnapshot(), engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    /// Supplies the policy predicate explicitly and intercepts the cleanup request.
    /// It deliberately makes no claim about native activation or key-window assignment.
    private final class PolicyWindow: NSWindow {
        var reportsKeyWindow = false
        private(set) var focusClearCalls = 0

        init() {
            super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
        }

        override var isKeyWindow: Bool { reportsKeyWindow }

        func resetFocusClearCalls() { focusClearCalls = 0 }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if responder == nil { focusClearCalls += 1 }
            return super.makeFirstResponder(responder)
        }
    }

    private final class FocusResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
