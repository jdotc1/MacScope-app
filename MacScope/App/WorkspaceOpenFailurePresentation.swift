/// Fixed user-facing recovery text for every workspace-open ingress. Diagnostic codes
/// are an open-ended internal vocabulary: only known codes may select specific guidance.
enum WorkspaceOpenFailurePresentation {
    /// A nil message retires cancellation silently, including superseded restoration.
    static func message(for reason: String) -> String? {
        switch reason {
        case "document-open-cancelled", "document-operation-cancelled":
            return nil
        case "document-open-package-absent":
            return "The selected package no longer exists. Use Open Workspace to choose its current location or another workspace."
        case "document-open-package-invalid":
            return "The selected package is not a valid MacScope workspace. Use Open Workspace to choose another workspace."
        case "document-open-package-unverifiable", "document-read-location-not-valid":
            return "The selected package could not be verified. Check that the package is available and readable, then try Open Workspace again."
        case "document-open-observation-changed", "document-open-observation-mismatch",
             "document-read-changed-during-validation":
            return "The selected package changed while it was being opened. Wait for changes to finish, then try Open Workspace again."
        case "document-location-owned-by-another-window":
            return "The selected package is already in use by another MacScope window. Switch to that window, or close it before trying Open Workspace again."
        case "document-write-already-active":
            return "A document operation is still in progress. Wait for it to finish, then try Open Workspace again."
        case "document-conflict-unresolved":
            return "The workspace has an unresolved package conflict. Resolve the conflict in its document window, then try Open Workspace again."
        case "document-session-closed":
            return "The document window closed while the workspace was being opened. Try Open Workspace again."
        default:
            return "The workspace could not be opened safely. Use Open Workspace to choose the package again or choose another workspace."
        }
    }
}
