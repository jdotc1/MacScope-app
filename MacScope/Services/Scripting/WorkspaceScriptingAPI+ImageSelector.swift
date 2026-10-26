import Foundation

/// MS-19: the optional `image` selector for the primary-image reads `decompile` and
/// `read-bytes`, and the image provenance labels their results carry.
///
/// The default is unchanged (MS-06): with no `image` argument these commands read the
/// primary image, never live focus. A caller that wants a sibling image names it
/// explicitly, by slot index or by image-owner ID, and the result says which image
/// answered (`imageSlot`, `imageOwner`). `set-signature` deliberately stays bound to the
/// focused image (MS-06-scope2) and takes no `image` argument.
///
/// DEF-A04 adds a second, different argument: `imageSlot` is a *row filter* for the
/// row-listing reads `search`, `callers`, `callees` and `xrefs`. Omitted, those commands
/// behave as before (search spans every image, the graph reads use the primary image);
/// either way every result row now says which image produced it.
extension WorkspaceScriptingAPI {
    /// The argument name, shared by the command registry and the MCP schema.
    nonisolated static let imageSelectorArgument = "image"

    /// The optional row-filter argument of `search`, `callers`, `callees` and `xrefs`.
    nonisolated static let imageSlotFilterArgument = "imageSlot"

    /// Resolves the optional `image` argument to a loaded image's slot.
    ///
    /// Absent or JSON null returns `snapshot.primarySlot` with no validation, so legacy
    /// callers (including a workspace with no `BinaryImage` rows) behave exactly as before.
    /// A present selector is a slot index (JSON integer, or a decimal string) or an
    /// image-owner ID (`BinaryImage.id`, a UUID string, case-insensitive), and must name an
    /// image loaded in this workspace; anything else throws `ScriptingError.unknownImage`
    /// listing the valid slots.
    nonisolated static func resolveImageSlot(
        _ arguments: ScriptValue,
        snapshot: WorkspaceSnapshot
    ) throws -> ImageSlot {
        guard let selector = arguments[imageSelectorArgument], selector != .null else {
            return snapshot.primarySlot
        }
        let images = snapshot.binaries
        let match: BinaryImage?
        switch selector {
        case .int(let raw):
            match = images.first { Int64($0.slot.rawValue) == raw }
        case .double(let raw):
            match = Int64(exactly: raw).flatMap { exact in
                images.first { Int64($0.slot.rawValue) == exact }
            }
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let owner = UUID(uuidString: trimmed) {
                match = images.first { $0.id == owner }
            } else if let raw = Int(trimmed) {
                match = images.first { $0.slot.rawValue == raw }
            } else {
                match = nil
            }
        case .null, .bool, .array, .object:
            match = nil
        }
        guard let match else {
            throw ScriptingError.unknownImage(
                selector: imageSelectorDescription(selector),
                validSlots: images.map(\.slot.rawValue).sorted()
            )
        }
        return match.slot
    }

    /// Resolves the optional `imageSlot` row filter. Absent or JSON null means "no filter" (nil).
    /// A present value is validated exactly like the `image` selector (slot index, decimal
    /// string or image-owner ID) and a miss throws the same typed `unknownImage` error naming
    /// the valid slots.
    nonisolated static func resolveImageSlotFilter(
        _ arguments: ScriptValue,
        snapshot: WorkspaceSnapshot
    ) throws -> ImageSlot? {
        guard let value = arguments[imageSlotFilterArgument], value != .null else { return nil }
        return try resolveImageSlot(.object([imageSelectorArgument: value]), snapshot: snapshot)
    }

    /// A copy of `snapshot` whose primary image is the one in `slot`, so the primary-image
    /// projections (`functions`, `xrefs`, `callers(of:)`, `functionRange`, ...) read that image.
    /// Value copy only: the store's snapshot is never touched. A slot with no binary row leaves
    /// the order unchanged.
    nonisolated static func imageProjection(of snapshot: WorkspaceSnapshot, in slot: ImageSlot) -> WorkspaceSnapshot {
        guard let index = snapshot.binaries.firstIndex(where: { $0.slot == slot }), index != 0 else {
            return snapshot
        }
        var projected = snapshot
        var binaries = projected.binaries
        binaries.insert(binaries.remove(at: index), at: 0)
        projected.binaries = binaries
        return projected
    }

    /// One `search` row. Shared by the inline and detached handlers so both emit the same shape.
    nonisolated static func searchRow(_ result: BinarySearchResult) -> ScriptValue {
        .object([
            "address": .hex(result.address),
            "kind": .string(result.kind.rawValue),
            "preview": .string(result.preview),
            "imageSlot": .int(Int64(result.imageSlot.rawValue)),
        ])
    }

    /// One `callers` / `callees` row.
    nonisolated static func callEdgeRow(_ ref: XRef, slot: ImageSlot) -> ScriptValue {
        .object(["from": .hex(ref.from), "to": .hex(ref.to), "imageSlot": .int(Int64(slot.rawValue))])
    }

    /// The search scope for an optional `imageSlot` filter: every image by default, one image
    /// when filtered. `focusedSlot` is only consulted for the filtered case.
    nonisolated static func searchScope(filter: ImageSlot?, focusedSlot: ImageSlot) -> BinarySearchScope {
        var scope = BinarySearchScope.everything
        scope.focusedSlot = focusedSlot
        if let filter {
            scope.images = .focused
            scope.focusedSlot = filter
        }
        return scope
    }

    /// The provenance label every image-selectable read returns: the slot that answered
    /// and its owner ID (`BinaryImage.id`; null only for a legacy snapshot with no image row).
    nonisolated static func imageProvenanceFields(
        slot: ImageSlot,
        snapshot: WorkspaceSnapshot
    ) -> [String: ScriptValue] {
        [
            "imageSlot": .int(Int64(slot.rawValue)),
            "imageOwner": snapshot.binary(in: slot).map { .string($0.id.uuidString) } ?? .null,
        ]
    }

    nonisolated private static func imageSelectorDescription(_ selector: ScriptValue) -> String {
        switch selector {
        case .string(let text): return text
        case .int(let raw): return String(raw)
        case .double(let raw): return String(raw)
        case .bool(let raw): return String(raw)
        case .null: return "null"
        case .array: return "<array>"
        case .object: return "<object>"
        }
    }
}
