import AppKit
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceDocumentSaveSheetPresenterTests: XCTestCase {
    func testDuplicateAdmissionKeepsExactWindowAndCompletesCancellationOnce() throws {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let panel = NSSavePanel()
        var observedWindow: NSWindow?
        var observedPanel: NSSavePanel?
        var reply: (@MainActor (NSApplication.ModalResponse) -> Void)?
        var outcomes: [NSApplication.ModalResponse] = []
        let presenter = WorkspaceDocumentSaveSheetPresenter { suppliedPanel, suppliedWindow, callback in
            observedPanel = suppliedPanel
            observedWindow = suppliedWindow
            reply = callback
        }
        XCTAssertTrue(presenter.present(panel, on: window) { outcomes.append($0) })
        XCTAssertTrue(presenter.isPresenting)
        XCTAssertTrue(observedWindow === window)
        XCTAssertTrue(observedPanel === panel)
        XCTAssertFalse(presenter.present(NSSavePanel(), on: window) { outcomes.append($0) })
        let complete = try XCTUnwrap(reply)
        complete(.cancel)
        complete(.abort)
        XCTAssertEqual(outcomes, [.cancel])
        XCTAssertFalse(presenter.isPresenting)
    }

    func testAbortReleasesAdmissionAndAllowsRetryOnDifferentExactWindow() throws {
        let firstWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let secondWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        var observedWindows: [NSWindow] = []
        var replies: [@MainActor (NSApplication.ModalResponse) -> Void] = []
        var outcomes: [NSApplication.ModalResponse] = []
        let presenter = WorkspaceDocumentSaveSheetPresenter { _, suppliedWindow, callback in
            observedWindows.append(suppliedWindow)
            replies.append(callback)
        }
        XCTAssertTrue(presenter.present(NSSavePanel(), on: firstWindow) { outcomes.append($0) })
        replies[0](.abort)
        XCTAssertEqual(outcomes, [.abort])
        XCTAssertFalse(presenter.isPresenting)
        XCTAssertTrue(presenter.present(NSSavePanel(), on: secondWindow) { outcomes.append($0) })
        XCTAssertTrue(observedWindows[0] === firstWindow)
        XCTAssertTrue(observedWindows[1] === secondWindow)
        replies[0](.OK)
        XCTAssertTrue(presenter.isPresenting, "Late old completion cannot clear a new panel")
        replies[1](.cancel)
        XCTAssertEqual(outcomes, [.abort, .cancel])
        XCTAssertFalse(presenter.isPresenting)
    }
}
