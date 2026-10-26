import XCTest
@testable import MacScope

final class WorkspaceOpenFailurePresentationTests: XCTestCase {
    func testKnownOpenRejectionsProvideFixedRecoveryForBothIngresses() {
        let cases: [(String, String)] = [
            ("document-open-package-absent", "The selected package no longer exists. Use Open Workspace to choose its current location or another workspace."),
            ("document-open-package-invalid", "The selected package is not a valid MacScope workspace. Use Open Workspace to choose another workspace."),
            ("document-open-package-unverifiable", "The selected package could not be verified. Check that the package is available and readable, then try Open Workspace again."),
            ("document-open-observation-changed", "The selected package changed while it was being opened. Wait for changes to finish, then try Open Workspace again."),
            ("document-location-owned-by-another-window", "The selected package is already in use by another MacScope window. Switch to that window, or close it before trying Open Workspace again."),
            ("document-write-already-active", "A document operation is still in progress. Wait for it to finish, then try Open Workspace again."),
            ("document-conflict-unresolved", "The workspace has an unresolved package conflict. Resolve the conflict in its document window, then try Open Workspace again."),
            ("document-session-closed", "The document window closed while the workspace was being opened. Try Open Workspace again.")
        ]
        for (reason, expected) in cases {
            XCTAssertEqual(WorkspaceOpenFailurePresentation.message(for: reason), expected, reason)
        }
        for reason in ["document-open-observation-mismatch", "document-read-changed-during-validation"] {
            XCTAssertEqual(WorkspaceOpenFailurePresentation.message(for: reason),
                           WorkspaceOpenFailurePresentation.message(for: "document-open-observation-changed"))
        }
        XCTAssertEqual(WorkspaceOpenFailurePresentation.message(for: "document-read-location-not-valid"),
                       WorkspaceOpenFailurePresentation.message(for: "document-open-package-unverifiable"))
    }

    func testCancellationIncludingSupersededRestorationHasNoAlertMessage() {
        XCTAssertNil(WorkspaceOpenFailurePresentation.message(for: "document-open-cancelled"))
        XCTAssertNil(WorkspaceOpenFailurePresentation.message(for: "document-operation-cancelled"))
    }

    func testUnknownDiagnosticsNeverReachUserOrInferCompatibility() throws {
        let fallback = try XCTUnwrap(WorkspaceOpenFailurePresentation.message(for: "document-open-failed"))
        for reason in ["", "private/path/to/package", "document-open-package-invalid-secret",
                       "document-open-newer-analyzer", "unsafe\nmessage", String(repeating: "x", count: 1024)] {
            XCTAssertEqual(WorkspaceOpenFailurePresentation.message(for: reason), fallback)
        }
    }
}
