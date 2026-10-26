import Foundation

/// Complete document-owned debugger evidence. This value is independent of editor focus and
/// remains installed while attaching to an arbitrary process, where no launch candidate exists.
struct DebuggerWorkspaceAuthority: Equatable, Sendable {
    let workspaceID: UUID
    let artifactCatalog: DebuggerWorkspaceArtifactCatalog
    let logicalBreakpointCatalogAvailability: DebuggerLogicalBreakpointCatalogAvailability
    let logicalBreakpointCatalog: DebuggerLogicalBreakpointCatalog
    let logicalBreakpointCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate
    let breakpointResolutionCatalog: DebuggerBreakpointResolutionCatalog
    let breakpointResolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate

    var isStructurallyValid: Bool {
        workspaceID == logicalBreakpointCatalogCoordinate.workspaceID
            && workspaceID == breakpointResolutionCatalogCoordinate.workspaceID
            && logicalBreakpointCatalog.catalogID == logicalBreakpointCatalogCoordinate.catalogID
            && logicalBreakpointCatalog.revision == logicalBreakpointCatalogCoordinate.revision
            && breakpointResolutionCatalog.coordinate == breakpointResolutionCatalogCoordinate
            && breakpointResolutionCatalogCoordinate.workspaceArtifactCatalogRevision
                == artifactCatalog.revision
            && breakpointResolutionCatalog.isStructurallyValid
    }
}

/// The focused image's optional next-launch proposal. It deliberately contains no document-wide
/// catalogs, so ordinary focus churn cannot replace authority used by a live or attached session.
struct DebuggerFocusedLaunchCandidate: Equatable {
    let imageSlot: ImageSlot
    let launchTarget: DebuggerLaunchTargetDescriptor
    let gutterBreakpointAddresses: [UInt64]
    let breakpointRevision: UInt64
}

/// Compatibility aggregate for the existing active-session reconciliation pipeline. New callers
/// must deliver `DebuggerWorkspaceAuthority` and `DebuggerFocusedLaunchCandidate` independently.
@available(*, deprecated, message: "Use DebuggerWorkspaceAuthority and DebuggerFocusedLaunchCandidate")
struct DebuggerWorkspaceInput: Equatable {
    var imageSlot: ImageSlot
    var launchTarget: DebuggerLaunchTargetDescriptor
    var gutterBreakpointAddresses: [UInt64]
    var breakpointRevision: UInt64
    var logicalBreakpointCatalogAvailability: DebuggerLogicalBreakpointCatalogAvailability
    var logicalBreakpointCatalog: DebuggerLogicalBreakpointCatalog
    var logicalBreakpointCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate
    var breakpointResolutionCatalog: DebuggerBreakpointResolutionCatalog
    var breakpointResolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate

    init(
        imageSlot: ImageSlot,
        launchTarget: DebuggerLaunchTargetDescriptor,
        gutterBreakpointAddresses: [UInt64],
        breakpointRevision: UInt64,
        logicalBreakpointCatalogAvailability: DebuggerLogicalBreakpointCatalogAvailability,
        logicalBreakpointCatalog: DebuggerLogicalBreakpointCatalog,
        logicalBreakpointCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate,
        breakpointResolutionCatalog: DebuggerBreakpointResolutionCatalog,
        breakpointResolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate
    ) {
        self.imageSlot = imageSlot
        self.launchTarget = launchTarget
        self.gutterBreakpointAddresses = gutterBreakpointAddresses
        self.breakpointRevision = breakpointRevision
        self.logicalBreakpointCatalogAvailability = logicalBreakpointCatalogAvailability
        self.logicalBreakpointCatalog = logicalBreakpointCatalog
        self.logicalBreakpointCatalogCoordinate = logicalBreakpointCatalogCoordinate
        self.breakpointResolutionCatalog = breakpointResolutionCatalog
        self.breakpointResolutionCatalogCoordinate = breakpointResolutionCatalogCoordinate
    }

    init(
        authority: DebuggerWorkspaceAuthority,
        candidate: DebuggerFocusedLaunchCandidate
    ) {
        imageSlot = candidate.imageSlot
        launchTarget = candidate.launchTarget
        gutterBreakpointAddresses = candidate.gutterBreakpointAddresses
        breakpointRevision = candidate.breakpointRevision
        logicalBreakpointCatalogAvailability = authority.logicalBreakpointCatalogAvailability
        logicalBreakpointCatalog = authority.logicalBreakpointCatalog
        logicalBreakpointCatalogCoordinate = authority.logicalBreakpointCatalogCoordinate
        breakpointResolutionCatalog = authority.breakpointResolutionCatalog
        breakpointResolutionCatalogCoordinate = authority.breakpointResolutionCatalogCoordinate
    }

    var focusedLaunchCandidate: DebuggerFocusedLaunchCandidate {
        DebuggerFocusedLaunchCandidate(
            imageSlot: imageSlot,
            launchTarget: launchTarget,
            gutterBreakpointAddresses: gutterBreakpointAddresses,
            breakpointRevision: breakpointRevision
        )
    }
}
