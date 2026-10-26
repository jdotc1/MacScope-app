import Foundation

/// App-specific adapter for function.callsites v1. This reads one authorized,
/// immutable analysis cut; it neither performs analysis nor owns accepted evidence.
enum Phase2FunctionCallSitesProjector {
    // Bound the raw producer cut before filtering or allocating derived rows.
    static let maximumInputReferences = 100_000
    private static let maximumResults = 256

    private struct CallPair: Hashable {
        let sourceAddress: UInt64
        let targetAddress: UInt64
    }

    private struct Page {
        let items: [CallPair]
        let matchingReferenceCount: Int
        let uniqueCallPairCount: Int

        var duplicateReferenceCount: Int { matchingReferenceCount - uniqueCallPairCount }
        var omittedUniqueCallPairCount: Int { uniqueCallPairCount - items.count }
        var isTruncated: Bool { omittedUniqueCallPairCount > 0 }

        func prefix(_ count: Int) -> Self {
            .init(items: Array(items.prefix(max(0, count))),
                  matchingReferenceCount: matchingReferenceCount,
                  uniqueCallPairCount: uniqueCallPairCount)
        }
    }

    static func project(
        range: Phase2ReadFunctionRange,
        analysis: ImageAnalysis,
        authorization: Phase2ReadAuthorization
    ) -> Phase2ReadEvidenceCandidate {
        let functionCitation = Phase2ReadCitation(
            id: UUID(), target: .functionRange(range),
            dependencies: authorization.request.precondition.dependencies
        )
        let candidateID = UUID()

        func candidate(
            _ data: Phase2ReadCandidateData,
            citations: [Phase2ReadCitation]? = nil
        ) -> Phase2ReadEvidenceCandidate {
            .init(
                candidateID: candidateID,
                invocationID: authorization.request.invocationID,
                sequence: authorization.request.sequence,
                registryVersion: authorization.canonicalDescriptor.registryVersion,
                operationID: authorization.canonicalDescriptor.id,
                operationVersion: authorization.canonicalDescriptor.operationVersion,
                producingPrincipal: .app,
                precondition: authorization.request.precondition,
                citations: citations ?? [functionCitation], data: data, cancelled: false
            )
        }

        guard authorization.isValid,
              authorization.canonicalDescriptor.id == .functionCallSites,
              authorization.request.subject == .functionRange(range),
              range.isValid,
              range.image == authorization.request.precondition.image
        else { return candidate(.unavailable(.unresolvedOwner)) }

        let functions = analysis.functions.filter {
            $0.startAddress == range.start && $0.endAddress == range.endExclusive
        }
        guard functions.count == 1 else {
            return candidate(.unavailable(functions.isEmpty ? .notFound : .ambiguous))
        }

        // Check RAW rows before filtering or allocating mapped pairs. Ordinary app
        // preparation reports .limitExceeded; this is the defensive projection check.
        guard analysis.xrefs.count <= maximumInputReferences else {
            return candidate(.unavailable(.unavailable))
        }
        let itemLimit = min(
            authorization.approvedLimits.pageItems,
            min(authorization.approvedLimits.arrayItems, maximumResults)
        )
        var uniquePairs = Set<CallPair>()
        var matchingCount = 0
        for reference in analysis.xrefs {
            guard reference.kind == XRefKind.call,
                  reference.from >= range.start,
                  reference.from < range.endExclusive else { continue }
            matchingCount += 1
            uniquePairs.insert(.init(sourceAddress: reference.from, targetAddress: reference.to))
        }
        let ordered = uniquePairs.sorted {
            $0.sourceAddress == $1.sourceAddress
                ? $0.targetAddress < $1.targetAddress
                : $0.sourceAddress < $1.sourceAddress
        }
        let result = Page(items: Array(ordered.prefix(itemLimit)),
                          matchingReferenceCount: matchingCount,
                          uniqueCallPairCount: ordered.count)

        // Only source coordinates are navigable/citable. A raw target may be a stub,
        // unowned address or otherwise unresolved; this operation does not resolve it.
        var citationsBySource: [UInt64: Phase2ReadCitation] = [:]
        for item in result.items where citationsBySource[item.sourceAddress] == nil {
            citationsBySource[item.sourceAddress] = .init(
                id: UUID(),
                target: .staticLocation(.init(
                    image: range.image, domain: .imageVirtualAddress,
                    address: item.sourceAddress
                )),
                dependencies: authorization.request.precondition.dependencies
            )
        }

        func projectedCandidate(_ page: Page) -> Phase2ReadEvidenceCandidate {
            var citations = [functionCitation]
            var citedSources = Set<UInt64>()
            var items: [Phase2ReadFactValue] = []
            for item in page.items {
                // A missing source is an internal mismatch, never permission to
                // mint target-derived authority or emit an uncited row.
                guard let citation = citationsBySource[item.sourceAddress] else {
                    return candidate(.unavailable(.unresolvedOwner))
                }
                if citedSources.insert(item.sourceAddress).inserted { citations.append(citation) }
                items.append(.object([
                    .init(name: "source", value: .staticLocation(.init(
                        image: range.image, domain: .imageVirtualAddress,
                        address: item.sourceAddress
                    ))),
                    .init(name: "rawTargetAddress", value: .unsignedInteger(item.targetAddress)),
                    .init(name: "sourceCitationID", value: .text(citation.id.uuidString.lowercased())),
                ]))
            }
            return candidate(.value(.object([
                .init(name: "schemaVersion", value: .unsignedInteger(1)),
                .init(name: "source", value: .text("analysis.xrefs")),
                .init(name: "coverage", value: .text("stored-recovered-call-xrefs-only")),
                .init(name: "targetResolution", value: .text("not-attempted")),
                .init(name: "functionStart", value: .unsignedInteger(range.start)),
                .init(name: "functionEndExclusive", value: .unsignedInteger(range.endExclusive)),
                .init(name: "rawXRefCount", value: .unsignedInteger(UInt64(analysis.xrefs.count))),
                .init(name: "matchingReferenceCount", value: .unsignedInteger(UInt64(page.matchingReferenceCount))),
                .init(name: "uniqueCallPairCount", value: .unsignedInteger(UInt64(page.uniqueCallPairCount))),
                .init(name: "duplicateReferenceCount", value: .unsignedInteger(UInt64(page.duplicateReferenceCount))),
                .init(name: "returnedCount", value: .unsignedInteger(UInt64(page.items.count))),
                .init(name: "omittedUniqueCallPairCount", value: .unsignedInteger(UInt64(page.omittedUniqueCallPairCount))),
                .init(name: "isTruncated", value: .boolean(page.isTruncated)),
                .init(name: "truncatedByItemLimit", value: .boolean(result.isTruncated)),
                .init(name: "truncatedByEnvelopeLimit", value: .boolean(page.items.count < result.items.count)),
                .init(name: "items", value: .list(items)),
            ])), citations: citations)
        }

        let full = projectedCandidate(result)
        if full.fits(within: authorization.approvedLimits) { return full }

        // Reuse the acceptor's exact encoded/structural predicate. Candidate and
        // citation UUIDs remain fixed while trimming. At most nine probes for 256 rows.
        // If even the empty envelope cannot fit, return it for the existing acceptor
        // to reject as .limitExceeded; no partial or oversized evidence is accepted.
        let empty = result.prefix(0)
        var best = projectedCandidate(empty)
        guard best.fits(within: authorization.approvedLimits) else { return best }
        var lower = 0
        var upper = result.items.count
        while lower < upper {
            let middle = lower + (upper - lower + 1) / 2
            let proposal = projectedCandidate(result.prefix(middle))
            if proposal.fits(within: authorization.approvedLimits) {
                lower = middle
                best = proposal
            } else {
                upper = middle - 1
            }
        }
        return best
    }
}
