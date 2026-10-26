import LumenTokens
import LumenUI
import SwiftUI
import XCTest
@testable import MacScope

@MainActor
final class DebuggerWatchpointDeckTests: XCTestCase {
    func testEditorRejectsMalformedAddressAndMisalignment() {
        var draft = WatchpointEditorDraft()
        draft.addressText = "not-an-address"
        XCTAssertNil(draft.request)
        draft.addressText = "0x1003"
        draft.size = 4
        XCTAssertEqual(draft.validationMessage, "The address must be aligned to the selected size.")
        XCTAssertNil(draft.request)
        draft.addressText = "0x1004"
        XCTAssertNil(draft.validationMessage)
        XCTAssertNotNil(draft.request)
        draft.size = 3
        XCTAssertNil(draft.request)
    }

    func testEditorPreservesIdentityAccessAndEnabledState() {
        let watchpoint = DebuggerWatchpoint(id: UUID(), address: 0x1000, size: 4,
                                           access: .readWrite, isEnabled: false, backendID: 1)
        let draft = WatchpointEditorDraft(watchpoint: watchpoint)
        guard let request = draft.request,
              case let .upsert(id, address, size, access, enabled) = request else {
            return XCTFail("Expected editable watchpoint request")
        }
        XCTAssertEqual(id, watchpoint.id)
        XCTAssertEqual(address, 0x1000)
        XCTAssertEqual(size, 4)
        XCTAssertEqual(access, .readWrite)
        XCTAssertFalse(enabled)
    }

    /// Review artifact only: pure offscreen rendering, without app launch or screen capture.
    func testRenderWatchpointDeckForReview() throws {
        let rows = [
            DebuggerWatchpoint(id: UUID(), address: 0x100004000, size: 8,
                               access: .write, isEnabled: true, backendID: 1),
            DebuggerWatchpoint(id: UUID(), address: 0x100004010, size: 4,
                               access: .readWrite, isEnabled: false, backendID: 2)
        ]
        let subject = DSSnapshot.Subject(
            name: "watchpoint-deck", size: CGSize(width: 820, height: 300),
            view: AnyView(WatchpointsDeckView(watchpoints: rows, canEdit: true,
                                             error: nil, onRequest: { _ in }, rendersOffscreen: true)
                .lumenRendersOffscreen(true)))
        let variant = DSSnapshot.Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .dark)
        let png = try XCTUnwrap(DSSnapshot.png(of: subject, in: variant))
        let url = TestWorkRoot.scratchURL("watchpoint-deck-preview.png")
        try png.write(to: url)
        print("UI review shot: \(url.path)")
    }
}
