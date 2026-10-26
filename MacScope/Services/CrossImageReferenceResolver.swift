import Foundation

/// WS-6: derives symbol-name-matched cross-image reference edges from a workspace snapshot.
///
/// Pure function — snapshot in, edges + diagnostics out; no mutation, no I/O. An edge joins an
/// image A's imported/undefined symbol (its `__stubs`/`__got` indirect-symbol site) to another
/// image B's exported definition of the same verbatim name. The result is a transient, never-
/// persisted product assigned to `WorkspaceSnapshot.crossImageXrefs` by the store chokepoint.
///
/// The body is implemented in WS-6 Task 2; this frozen signature is what the store chokepoint and
/// tests build against (mirroring how the WS-5 `rehydrate` seam was frozen before its body landed).
enum CrossImageReferenceResolver {
    /// Returns every symbolic cross-image edge, plus one diagnostic string per ambiguous
    /// (multiply-exported) name that was actually joined.
    static func resolve(_ snapshot: WorkspaceSnapshot) -> (edges: [CrossImageXRef], diagnostics: [String]) {
        let images = snapshot.binaries.sorted { $0.slot < $1.slot }

        var exportIndex: [String: (slot: ImageSlot, address: UInt64)] = [:]
        var duplicated: Set<String> = []

        for image in images {
            guard let analysis = snapshot.analysis(in: image.slot) else { continue }
            for export in analysis.exports {
                guard let address = export.address else { continue }
                if exportIndex[export.name] == nil {
                    exportIndex[export.name] = (slot: image.slot, address: address)
                } else {
                    duplicated.insert(export.name)
                }
            }
        }

        var edges: [CrossImageXRef] = []
        var joinedNames: Set<String> = []

        for image in images {
            guard let analysis = snapshot.analysis(in: image.slot) else { continue }
            let entries = analysis.indirectSymbols.enumerated().sorted { lhs, rhs in
                if lhs.element.tableIndex != rhs.element.tableIndex {
                    return lhs.element.tableIndex < rhs.element.tableIndex
                }
                return lhs.offset < rhs.offset
            }

            for (_, entry) in entries {
                guard let name = entry.symbolName,
                      let export = exportIndex[name],
                      export.slot != image.slot
                else { continue }

                let kind = entry.sourceSection.range(of: "__got", options: .caseInsensitive) == nil
                    ? XRefKind.call
                    : XRefKind.data
                edges.append(CrossImageXRef(
                    id: UUID(),
                    fromSlot: image.slot,
                    from: entry.address,
                    toSlot: export.slot,
                    to: export.address,
                    symbol: name,
                    kind: kind
                ))
                joinedNames.insert(name)
            }
        }

        let diagnostics = duplicated.intersection(joinedNames).sorted().map { name in
            "Cross-image symbol \"\(name)\" is exported by multiple images; resolved to the lowest slot."
        }
        return (edges, diagnostics)
    }
}
