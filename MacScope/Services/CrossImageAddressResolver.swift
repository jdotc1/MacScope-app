import Foundation

/// WS-7: finds absolute values in each image that resolve into ANOTHER image's runtime range, as
/// address-based cross-image edges (kind `.data`, empty `symbol` — a value-derived edge carries no
/// name). Pure function — snapshot + layout in, edges out. The counterpart to WS-6's symbolic
/// `CrossImageReferenceResolver`; the store chokepoint runs both and merges the results.
///
enum CrossImageAddressResolver {
    private struct EdgeKey: Hashable {
        let fromSlot: ImageSlot
        let from: UInt64
        let toSlot: ImageSlot
        let to: UInt64
        let kind: String
    }

    static func resolve(_ snapshot: WorkspaceSnapshot, layout: ImageLayout) -> [CrossImageXRef] {
        let images = snapshot.binaries.sorted { $0.slot < $1.slot }
        var edges: [CrossImageXRef] = []
        var seen: Set<EdgeKey> = []

        func appendEdge(fromSlot: ImageSlot, from: UInt64, target: ImageAddress) {
            let key = EdgeKey(
                fromSlot: fromSlot,
                from: from,
                toSlot: target.slot,
                to: target.address,
                kind: XRefKind.data
            )
            guard seen.insert(key).inserted else { return }
            edges.append(
                CrossImageXRef(
                    id: UUID(),
                    fromSlot: fromSlot,
                    from: from,
                    toSlot: target.slot,
                    to: target.address,
                    symbol: "",
                    kind: XRefKind.data
                )
            )
        }

        // Family 1: pointer-width words in file-backed, non-executable sections.
        for image in images {
            guard let analysis = snapshot.analysis(in: image.slot) else { continue }
            let imageByteCount = UInt64(analysis.imageBytes.count)

            for section in analysis.sections where !section.isExecutable && !section.isZeroFill {
                guard section.fileOffset < imageByteCount else { continue }

                let requestedByteCount = section.fileSize ?? section.size
                let availableByteCount = imageByteCount - section.fileOffset
                let sectionByteCount = min(requestedByteCount, availableByteCount)
                guard sectionByteCount >= 8 else { continue }

                let fileStart = Int(section.fileOffset)
                let scanByteCount = Int(sectionByteCount)
                var offset = 0
                while offset + 8 <= scanByteCount {
                    let value = littleEndianWord(in: analysis.imageBytes, at: fileStart + offset)
                    if let target = layout.resolve(runtimeVA: value), target.slot != image.slot {
                        appendEdge(
                            fromSlot: image.slot,
                            from: section.address &+ UInt64(offset),
                            target: target
                        )
                    }
                    offset += 8
                }
            }
        }

        // Family 2: already-extracted targets that did not resolve inside their source image.
        for image in images {
            guard let analysis = snapshot.analysis(in: image.slot) else { continue }

            for xref in analysis.xrefs {
                let isInsideSourceImage = analysis.sections.contains { section in
                    xref.to >= section.address && xref.to < section.address &+ section.size
                }
                guard !isInsideSourceImage,
                      let target = layout.resolve(runtimeVA: xref.to),
                      target.slot != image.slot
                else { continue }

                appendEdge(fromSlot: image.slot, from: xref.from, target: target)
            }
        }

        return edges
    }

    /// Reads a little-endian 64-bit word at a 0-based logical `offset` into `bytes`. `Data` may be a
    /// SLICE whose `startIndex` is non-zero (this is exactly how `imageBytes` can arrive — see the
    /// `hexByteReader` convention), so the logical offset is rebased onto `startIndex`; indexing with
    /// the raw offset would read the wrong bytes or trap. The caller guarantees `offset + 8` is within
    /// the logical length.
    private static func littleEndianWord(in bytes: Data, at offset: Int) -> UInt64 {
        let base = bytes.startIndex + offset
        var value: UInt64 = 0
        for byteIndex in 0..<8 {
            value |= UInt64(bytes[base + byteIndex]) << (byteIndex * 8)
        }
        return value
    }
}
