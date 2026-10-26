import Foundation

/// The finite set of selection/document commands that are dispatched from the menu (and
/// keyboard shortcuts) into `WorkspaceStore`. Centralising them as a typed, `CaseIterable`
/// enum is what makes a *dead* command (a visible menu item wired to nothing) detectable
/// automatically: every case must have a `perform` arm, an `isEnabled` arm (both compiler-
/// enforced exhaustive switches in `WorkspaceStore+Commands`), and a `notificationName`
/// entry point — and `WorkspaceCommandRoutingTests` asserts each case round-trips through
/// the menu→notification→store path. A previously-dead command (Mark as Undefined,
/// Add/Remove Bookmark, Patch Bytes, Replace with NOP, Clear Patch) can no longer ship
/// posting a notification that no one observes.
enum WorkspaceCommand: String, CaseIterable, Hashable {
    case markAsUndefined
    case markAsProcedure
    case addBookmark
    case removeBookmark
    case patchBytes
    case replaceWithNOP
    case clearPatch
    case assembleInstruction
    case findNext
    case findPrevious
    case nextProcedure
    case previousProcedure
    case topOfProcedure
    case nextSection
    case previousSection
    case nextXRef
    case previousXRef
    case copyAddress
    case copyHexString
    case nativeRequest
    case nativeRetry
    case nativeRefresh
    case nativeCancel

    /// The cross-process `Notification.Name` the menu posts and the workspace view observes
    /// for this command. One name per command; the view wires every case in one loop, so a
    /// new case without an observer is impossible.
    var notificationName: Notification.Name {
        switch self {
        case .markAsUndefined: return .macScopeMarkAsUndefined
        case .markAsProcedure: return .macScopeMarkAsProcedure
        case .addBookmark: return .macScopeAddBookmark
        case .removeBookmark: return .macScopeRemoveBookmark
        case .patchBytes: return .macScopePatchBytes
        case .replaceWithNOP: return .macScopePatchNOP
        case .clearPatch: return .macScopeClearPatch
        case .assembleInstruction: return .macScopeAssembleInstruction
        case .findNext: return .macScopeFindNext
        case .findPrevious: return .macScopeFindPrevious
        case .nextProcedure: return .macScopeNextProcedure
        case .previousProcedure: return .macScopePreviousProcedure
        case .topOfProcedure: return .macScopeTopOfProcedure
        case .nextSection: return .macScopeNextSection
        case .previousSection: return .macScopePreviousSection
        case .nextXRef: return .macScopeNextXRef
        case .previousXRef: return .macScopePreviousXRef
        case .copyAddress: return .macScopeCopyAddress
        case .copyHexString: return .macScopeCopyHexString
        case .nativeRequest: return .macScopeNativeRequest
        case .nativeRetry: return .macScopeNativeRetry
        case .nativeRefresh: return .macScopeNativeRefresh
        case .nativeCancel: return .macScopeNativeCancel
        }
    }

    /// Human-readable title (menu label / diagnostics).
    var title: String {
        switch self {
        case .markAsUndefined: return "Mark as Undefined"
        case .markAsProcedure: return "Mark as Procedure"
        case .addBookmark: return "Add Bookmark"
        case .removeBookmark: return "Remove Bookmark"
        case .patchBytes: return "Patch Bytes…"
        case .replaceWithNOP: return "Replace with NOP"
        case .clearPatch: return "Clear Patch"
        case .assembleInstruction: return "Assemble Instruction…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .nextProcedure: return "Next Procedure"
        case .previousProcedure: return "Previous Procedure"
        case .topOfProcedure: return "Go to Top of Procedure"
        case .nextSection: return "Next Section"
        case .previousSection: return "Previous Section"
        case .nextXRef: return "Next XREF"
        case .previousXRef: return "Previous XREF"
        case .copyAddress: return "Copy Current Address"
        case .copyHexString: return "Copy Hex String of Selected Bytes"
        case .nativeRequest: return "Request Native Pseudocode"
        case .nativeRetry: return "Retry Native Pseudocode"
        case .nativeRefresh: return "Refresh Native Pseudocode"
        case .nativeCancel: return "Cancel Native Pseudocode"
        }
    }
}
