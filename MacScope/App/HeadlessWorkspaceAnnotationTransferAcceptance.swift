import CryptoKit
import Foundation

/// RX-01 §2.8 headless acceptance for "Transfer Names and Comments". Store-level, no window and
/// no view model: the same production pieces the Compare Images review uses, in order —
/// `VersionCompareComputation.build` (off the main actor) → `AnnotationTransferCandidates.build`
/// → the default high-confidence selection → `AnnotationTransferCandidates.preview` →
/// `WorkspaceStore.commitAnnotationTransfer` → one Undo / Redo round trip → caller-supplied save
/// → caller-supplied reopen of the saved package → per-slot authoring digests.
///
/// The result is a machine-readable `ScriptValue` object; `passed` is true only when every step
/// held. Used by `HeadlessWorkspaceAcceptance` action `annotation-transfer` (save and reload
/// through the document session) and by CoreTests (`writeDocumentPackage` + a fresh restore).
/// Package I/O stays with the caller so App code never bypasses the document authority.
@MainActor
enum HeadlessWorkspaceAnnotationTransferAcceptance {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Saves `store`, reopens the saved package, and returns its URL and the reopened snapshot.
    typealias Save = @MainActor (WorkspaceStore) async throws -> (package: URL, reopened: WorkspaceSnapshot)

    /// Compares the first two analyzed images in slot order (old = lower slot, new = next slot),
    /// unless explicit slots are given. Throws only for setup failures (fewer than two images,
    /// matcher error, reopen error); a refused or empty commit is reported with `passed: false`.
    static func run(store: WorkspaceStore,
                    oldSlot: ImageSlot? = nil,
                    newSlot: ImageSlot? = nil,
                    save: Save) async throws -> ScriptValue {
        let images = VersionCompareViewModel.images(in: store.snapshot)
        guard let old = oldSlot.map({ slot in images.first { $0.slot == slot } }) ?? images.first,
              let new = newSlot.map({ slot in images.first { $0.slot == slot } })
                ?? images.first(where: { $0.slot != old.slot }),
              old.slot != new.slot,
              let oldAnalysis = store.snapshot.analysis(in: old.slot),
              let newAnalysis = store.snapshot.analysis(in: new.slot) else {
            throw Failure(description: "annotation-transfer-needs-two-analyzed-images")
        }
        let pair = VersionComparePair(old: old, new: new)
        let computation = try await Task.detached(priority: .userInitiated) {
            try VersionCompareComputation.build(old: oldAnalysis, new: newAnalysis)
        }.value

        let candidates = AnnotationTransferCandidates.build(
            result: computation.result, oldSlot: old.slot, newSlot: new.slot, snapshot: store.snapshot)
        let selected = AnnotationTransferCandidates.defaultSelection(candidates)
        let preview = try AnnotationTransferCandidates.preview(
            candidates, selected: selected, oldSlot: old.slot, newSlot: new.slot, snapshot: store.snapshot)

        var report: [String: ScriptValue] = [
            "oldSlot": .int(Int64(old.slot.rawValue)),
            "newSlot": .int(Int64(new.slot.rawValue)),
            "candidates": .int(Int64(candidates.count)),
            "selected": .int(Int64(selected.count)),
            "previewNames": .int(Int64(preview.nameCount)),
            "previewComments": .int(Int64(preview.commentCount)),
            "conflicts": .array(preview.conflicts.map { conflict in
                .object([
                    "destinationAddress": .string(conflict.destinationAddress.hexAddress),
                    "field": .string(conflict.field.rawValue),
                    "kind": .string(conflict.kind.rawValue)
                ])
            })
        ]
        var failures: [String] = []
        func finish() -> ScriptValue {
            report["failures"] = .array(failures.map(ScriptValue.string))
            report["passed"] = .bool(failures.isEmpty)
            return .object(report)
        }

        let before = destinationPartition(store.snapshot, slot: new.slot)
        let outcome = store.commitAnnotationTransfer(.init(pair: pair, preview: preview))
        report["outcome"] = encode(outcome)
        guard case .applied = outcome else {
            failures.append("commit-not-applied")
            return finish()
        }
        let after = destinationPartition(store.snapshot, slot: new.slot)
        report["destinationDigestBefore"] = .string(digest(before))
        report["destinationDigestAfter"] = .string(digest(after))

        // One Undo step reverts the whole destination partition; Redo restores it exactly.
        let undoName = store.undoManager.undoActionName
        report["undoActionName"] = .string(undoName)
        if undoName != WorkspaceStore.annotationTransferActionName { failures.append("undo-action-name") }
        store.undoManager.undo()
        let undoRestored = destinationPartition(store.snapshot, slot: new.slot) == before
        report["undoRestoresBefore"] = .bool(undoRestored)
        if !undoRestored { failures.append("undo-did-not-restore-before") }
        store.undoManager.redo()
        let redoRestored = destinationPartition(store.snapshot, slot: new.slot) == after
        report["redoRestoresAfter"] = .bool(redoRestored)
        if !redoRestored { failures.append("redo-did-not-restore-after") }

        let digestsBeforeSave = authoringDigestBySlot(store.snapshot)
        let saved = try await save(store)
        report["savedPackage"] = .string(saved.package.path)
        let digestsAfterReopen = authoringDigestBySlot(saved.reopened)
        report["authoringDigestBySlot"] = scriptValue(digestsBeforeSave)
        report["reopenedAuthoringDigestBySlot"] = scriptValue(digestsAfterReopen)
        let reopenMatches = digestsBeforeSave == digestsAfterReopen
        report["reopenMatches"] = .bool(reopenMatches)
        if !reopenMatches { failures.append("reopen-authoring-digest-mismatch") }
        return finish()
    }

    // MARK: - Digests

    /// SHA-256 of the canonical JSON of each slot's `AddressOverrideEntry` list, address-sorted.
    /// JSON strings carry the exact UTF-8 (no Unicode normalization), so equal digests mean the
    /// authored text survived byte for byte. Keys are slot raw values as decimal strings.
    static func authoringDigestBySlot(_ snapshot: WorkspaceSnapshot) -> [String: String] {
        let slots = Set(snapshot.binaries.map(\.slot)).union(snapshot.addressOverrides.keys.map(\.slot))
        var result: [String: String] = [:]
        for slot in slots {
            result[String(slot.rawValue)] = digest(destinationPartition(snapshot, slot: slot))
        }
        return result
    }

    static func scriptValue(_ digests: [String: String]) -> ScriptValue {
        .object(digests.mapValues(ScriptValue.string))
    }

    private static func destinationPartition(_ snapshot: WorkspaceSnapshot,
                                             slot: ImageSlot) -> [UInt64: AddressOverride] {
        var partition: [UInt64: AddressOverride] = [:]
        for (key, value) in snapshot.addressOverrides where key.slot == slot { partition[key.address] = value }
        return partition
    }

    private static func digest(_ partition: [UInt64: AddressOverride]) -> String {
        let entries = partition.keys.sorted().map { address in
            AddressOverrideEntry(address: address, override: partition[address]!)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(entries)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ outcome: AnnotationTransferCommitOutcome) -> ScriptValue {
        switch outcome {
        case let .applied(names, comments, conflicts):
            return .object(["kind": .string("applied"), "names": .int(Int64(names)),
                            "comments": .int(Int64(comments)), "conflicts": .int(Int64(conflicts))])
        case let .nothingToApply(conflicts):
            return .object(["kind": .string("nothingToApply"), "conflicts": .int(Int64(conflicts))])
        case let .refused(refusal):
            return .object(["kind": .string("refused"), "refusal": .string(String(describing: refusal))])
        }
    }
}
