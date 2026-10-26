import Foundation
import XCTest

@testable import MacScope

final class MacScopeGhosttyActionRouterTests: XCTestCase {
    func testLocalSurfaceActionsProduceOnlyMediatedIntents() {
        let router = MacScopeGhosttyActionRouter()
        let cases: [(MacScopeGhosttyAction, MacScopeGhosttyActionRouter.Decision)] = [
            (.render, .perform(.scheduleRender)),
            (.wakeup, .perform(.wakeup)),
            (.selectionChanged, .perform(.selectionChanged)),
            (.pointerChanged(.text), .perform(.pointerChanged(.text))),
            (.bell, .perform(.bell)),
            (.closeSurface, .perform(.requestClose)),
            (.rendererHealth(.healthy), .perform(.rendererHealth(.healthy))),
            (.rendererHealth(.unhealthy), .perform(.rendererHealth(.unhealthy))),
        ]

        for (action, expected) in cases {
            XCTAssertEqual(router.route(action), expected)
        }
    }

    func testMetadataIsControlFreeAndBoundedAtUTF8ScalarBoundaries() {
        let router = MacScopeGhosttyActionRouter(limits: .init(
            maximumTitleByteCount: 5,
            maximumWorkingDirectoryByteCount: 9,
            maximumHyperlinkByteCount: 128
        ))

        XCTAssertEqual(
            router.route(.titleChanged("A\n🚀BC")),
            .perform(.updateTitleMetadata("A🚀"))
        )
        XCTAssertEqual(
            router.route(.workingDirectoryChanged("/tmp/\0safe-and-unbounded")),
            .perform(.updateWorkingDirectoryMetadata("/tmp/safe"))
        )
    }

    func testEveryApplicationShellActionIsExplicitlyDenied() {
        let router = MacScopeGhosttyActionRouter()
        let frozenActions: Set<MacScopeGhosttyApplicationAction> = [
            .newWindow,
            .closeWindow,
            .newTab,
            .closeTab,
            .splitHorizontal,
            .splitVertical,
            .closeSplit,
            .quitApplication,
            .checkForUpdates,
            .applyUpdate,
            .reloadConfiguration,
            .openConfiguration,
            .showNotification,
            .installShellIntegration,
            .launchChildProcess,
            .unsupportedNativeAction,
        ]

        XCTAssertEqual(Set(MacScopeGhosttyApplicationAction.allCases), frozenActions)
        for action in MacScopeGhosttyApplicationAction.allCases {
            XCTAssertEqual(
                router.route(.application(action)),
                .denied(.applicationAuthority),
                "unexpected authority for \(action)"
            )
        }
    }

    func testHyperlinksRequireBoundedDirectHumanHTTPActivation() throws {
        let router = MacScopeGhosttyActionRouter(limits: .init(
            maximumTitleByteCount: 32,
            maximumWorkingDirectoryByteCount: 32,
            maximumHyperlinkByteCount: 64
        ))
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/docs?q=1"))

        XCTAssertEqual(
            router.route(.activateHyperlink(
                "https://example.com/docs?q=1",
                activation: .directHuman
            )),
            .perform(.activateHyperlink(expectedURL))
        )
        for activation in [
            MacScopeGhosttyActivation.keyboardProtocol,
            .terminalProgram,
            .replay,
        ] {
            XCTAssertEqual(
                router.route(.activateHyperlink(
                    "https://example.com/docs",
                    activation: activation
                )),
                .denied(.indirectActivation)
            )
        }
        for value in [
            "file:///private/tmp/terminal-owned",
            "javascript:alert(1)",
            "https://user:password@example.com/",
            "https://",
            "https://example.com/" + String(repeating: "x", count: 65),
        ] {
            XCTAssertEqual(
                router.route(.activateHyperlink(value, activation: .directHuman)),
                .denied(.invalidActivation)
            )
        }
    }

    func testOSC52ClipboardControlIsAlwaysDenied() {
        XCTAssertEqual(
            MacScopeGhosttyActionRouter().route(.osc52ClipboardControl),
            .denied(.clipboardControlDisabled)
        )
    }

    func testDiagnosticsNeverRetainMetadataOrHyperlinkContents() {
        let diagnostics = MacScopeGhosttySurfaceDiagnostics(capacity: 2)
        let router = MacScopeGhosttyActionRouter(diagnostics: diagnostics)
        let secret = "terminal-private-content-7e8358b9"

        _ = router.route(.titleChanged(secret))
        _ = router.route(.activateHyperlink(
            "https://example.com/\(secret)",
            activation: .terminalProgram
        ))
        _ = router.route(.application(.quitApplication))

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.evictedEntryCount, 1)
        XCTAssertFalse(String(describing: snapshot).contains(secret))
    }
}
