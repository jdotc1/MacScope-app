import Foundation

/// Pure, value-type dirty-state + autosave-decision logic for a workspace document.
///
/// The store mutates persisted state through a handful of choke points
/// (`registerAndApplyOverride`, `registerAndApplyTypeDefinitions`, breakpoint
/// toggles). Each mutation allocates a unique `revision`; a successful save
/// records the revision it captured as the `savedRevision`. The document is
/// dirty whenever `revision != savedRevision`.
///
/// Undo/redo are themselves mutations, but the document must read *clean* again
/// once the user undoes back to the last-saved point. To make that coherent
/// without diffing the (large, non-`Equatable`) snapshot, every undoable edit
/// captures the revision that was current *before* it ran and registers an Undo
/// that `restore(token:)`s it. Undoing therefore rewinds `revision` to the exact
/// value it held at the save boundary, and `isDirty` falls back to `false`.
///
/// Everything here is deterministic and free of timers/clocks so it can be
/// exercised headlessly: the store injects the wall-clock/trigger, this type
/// only decides *whether* an autosave should run.
struct DocumentDirtyTracker: Equatable {
    /// Current content-state identity. Allocated on every persisted edit; restored
    /// (possibly downward) by undo/redo via `restore(token:)`.
    private(set) var revision: Int = 0
    /// Allocator identity is never rewound by Undo; divergent edits cannot reuse a saved token.
    private var lastIssuedRevision: Int = 0

    /// The `revision` captured by the most recent successful save, or `nil` when
    /// the document has never been saved. A never-saved document with edits is
    /// dirty; a never-saved document with no edits is not.
    private(set) var savedRevision: Int?

    /// `true` when there are persisted changes not yet written to disk. A
    /// never-saved document (`savedRevision == nil`) is clean at revision 0 and
    /// dirty once any mutation advances the revision.
    var isDirty: Bool {
        revision != (savedRevision ?? 0)
    }

    /// An opaque token capturing the current revision. Hand this to an Undo
    /// registration before mutating, then feed it back to `restore(token:)` from
    /// the undo handler so the dirty-state rewinds with the edit.
    var token: Int { revision }

    /// Records a persisted mutation, advancing the revision. Returns the *prior*
    /// token so the caller can register a matching undo restore.
    @discardableResult
    mutating func recordMutation() -> Int {
        let previous = revision
        lastIssuedRevision += 1
        revision = lastIssuedRevision
        return previous
    }

    /// Restores the revision to a previously captured `token` (an undo/redo step).
    mutating func restore(token: Int) {
        revision = token
    }

    /// Marks the document clean at the current revision (a successful save).
    mutating func markSaved() {
        savedRevision = revision
    }

    /// Marks the document clean at a specific revision token — used when a save
    /// captures the revision at the start of the write and clears dirty against
    /// *that* baseline even if further edits landed mid-write.
    mutating func markSaved(at token: Int) {
        savedRevision = token
    }
}

/// The outcome of asking "should we autosave right now?". Mirrors the persisted
/// `WorkspaceDatabase.WorkspaceDocumentAutosaveDecision` cases the store records,
/// but lives in pure logic so the decision is testable without a database.
enum AutosaveDecision: Equatable {
    /// Persist now (the document is dirty and nothing blocks the write).
    case save
    /// Nothing to do — the document is already clean.
    case skipNoChanges
    /// A file conflict was detected; defer to manual resolution.
    case skipConflict
}

/// Pure autosave policy: given the current dirty state and whether a conflict is
/// outstanding, decides whether an autosave should fire. Deliberately stateless
/// and clock-free — the store owns the debounce timer and merely consults this to
/// gate each tick, so the "fires after a mutation / not on a no-op" behavior is
/// unit-testable by driving the inputs directly.
enum AutosavePolicy {
    static func decide(isDirty: Bool, hasConflict: Bool) -> AutosaveDecision {
        if hasConflict { return .skipConflict }
        return isDirty ? .save : .skipNoChanges
    }
}
