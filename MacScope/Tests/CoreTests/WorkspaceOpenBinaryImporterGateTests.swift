import AppKit
import XCTest
@testable import MacScope

final class WorkspaceOpenBinaryImporterGateTests: XCTestCase {
    private typealias Gate = WorkspaceOpenBinaryImporterGate
    private let alertUp = Gate.Context(documentAlertPending: true, windowHasSheet: true, importerVisible: false)
    private let otherSheet = Gate.Context(documentAlertPending: false, windowHasSheet: true, importerVisible: false)
    private let importerUp = Gate.Context(documentAlertPending: false, windowHasSheet: true, importerVisible: true)

    func testClearWindowPresentsAndDismissResets() {
        var gate = Gate()
        XCTAssertEqual(gate.request(.clear), .present)
        XCTAssertTrue(gate.isImporterPresented)
        gate.importerDidDismiss()
        XCTAssertFalse(gate.isImporterPresented)
        XCTAssertEqual(gate.request(.clear), .present)
    }

    /// The Tier 2 wedge: a request under the Patched Binary Saved alert must not raise the flag,
    /// and later requests must still present.
    func testRequestUnderDocumentAlertIsQueuedAndReplayedWhenAlertCloses() {
        var gate = Gate()
        XCTAssertEqual(gate.request(alertUp), .deferredUntilAlertCloses)
        XCTAssertFalse(gate.isImporterPresented)
        XCTAssertTrue(gate.isRequestDeferred)
        XCTAssertEqual(gate.drainDeferred(.clear), .present)
        XCTAssertTrue(gate.isImporterPresented)
        XCTAssertFalse(gate.isRequestDeferred)
    }

    func testDrainWaitsForClosingSheetThenGivesUpVisibly() {
        var gate = Gate()
        _ = gate.request(alertUp)
        for _ in 0 ..< Gate.maximumDrainAttempts {
            XCTAssertEqual(gate.drainDeferred(otherSheet), .retryShortly)
        }
        XCTAssertEqual(gate.drainDeferred(otherSheet), .refused)
        XCTAssertFalse(gate.isRequestDeferred)
        XCTAssertFalse(gate.isImporterPresented)
        // Not wedged: the next request on a clear window presents.
        XCTAssertEqual(gate.request(.clear), .present)
    }

    func testDrainStaysQueuedWhenAnotherAlertFollows() {
        var gate = Gate()
        _ = gate.request(alertUp)
        XCTAssertEqual(gate.drainDeferred(otherSheet), .retryShortly)
        XCTAssertEqual(gate.drainDeferred(alertUp), .deferredUntilAlertCloses)
        XCTAssertEqual(gate.drainDeferred(.clear), .present)
    }

    func testDrainWithoutQueuedRequestDoesNothing() {
        var gate = Gate()
        XCTAssertEqual(gate.drainDeferred(.clear), .none)
        XCTAssertFalse(gate.isImporterPresented)
    }

    func testOtherSheetRefusesWithoutRaisingFlag() {
        var gate = Gate()
        XCTAssertEqual(gate.request(otherSheet), .refused)
        XCTAssertFalse(gate.isImporterPresented)
        XCTAssertEqual(gate.request(.clear), .present)
    }

    func testVisibleImporterIsBroughtForwardNotRepresented() {
        var gate = Gate()
        XCTAssertEqual(gate.request(.clear), .present)
        XCTAssertEqual(gate.request(importerUp), .alreadyVisible)
        XCTAssertTrue(gate.isImporterPresented)
    }

    /// A flag left true with nothing on screen (SwiftUI dropped the presentation) is reset and
    /// replayed instead of swallowing every later request.
    func testStaleFlagIsResetAndReplayed() {
        var gate = Gate()
        XCTAssertEqual(gate.request(.clear), .present)
        XCTAssertEqual(gate.request(.clear), .replayAfterReset)
        XCTAssertFalse(gate.isImporterPresented)
        XCTAssertEqual(gate.request(.clear), .present)
    }

    // MARK: Quit prompt (untitled "Don't Save")

    func testUntitledQuitPromptOffersSaveAsCancelAndDontSave() {
        let prompt = WorkspaceTerminationPrompt(hasConflict: false)
        XCTAssertEqual(prompt.buttons.map(\.title), ["Save As…", "Cancel Quit", "Don’t Save"])
        XCTAssertEqual(prompt.buttons.map(\.choice), [.saveAs, .cancel, .discard])
        XCTAssertEqual(prompt.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertEqual(prompt.choice(for: .alertFirstButtonReturn), .saveAs)
        XCTAssertEqual(prompt.choice(for: .alertSecondButtonReturn), .cancel)
        XCTAssertEqual(prompt.choice(for: .alertThirdButtonReturn), .discard)
        XCTAssertEqual(prompt.choice(for: .cancel), .cancel)
    }

    func testConflictQuitPromptNeverOffersDiscard() {
        let prompt = WorkspaceTerminationPrompt(hasConflict: true)
        XCTAssertEqual(prompt.buttons.map(\.choice), [.saveAs, .cancel, .keepLocalVersion])
        XCTAssertEqual(prompt.choice(for: .alertThirdButtonReturn), .keepLocalVersion)
        XCTAssertFalse(prompt.buttons.contains { $0.choice == .discard })
    }
}
