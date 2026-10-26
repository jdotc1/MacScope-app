import Foundation

@MainActor
extension WorkspaceStore {
    func sourceFunctionCandidates(from referenceSlot: ImageSlot, to targetSlot: ImageSlot,
                                  targetRevision: SourceRevisionIdentity) throws -> [SourceFunctionCorrelation] {
        guard referenceSlot != targetSlot,
              let reference = snapshot.binary(in: referenceSlot),
              let target = snapshot.binary(in: targetSlot),
              let referenceAnalysis = snapshot.analysis(in: referenceSlot),
              let targetAnalysis = snapshot.analysis(in: targetSlot),
              let binding = try SourceLinkWorkspaceState.decode(snapshot.sourceLinkState, binaries: snapshot.binaries).binding(for: reference)
        else { return [] }
        return try SourceFunctionCorrelationMatcher.candidates(
            reference: reference, referenceAnalysis: referenceAnalysis, referenceBinding: binding,
            target: target, targetAnalysis: targetAnalysis, targetRevision: targetRevision
        )
    }

    func acceptSourceFunctionCandidate(_ candidate: SourceFunctionCorrelation,
                                       expectedInstallationID: UUID) throws {
        guard expectedInstallationID == documentInstallationID,
              let referenceSlot = candidate.referenceLink.image?.slot,
              let current = try sourceFunctionCandidates(
                from: referenceSlot, to: candidate.targetImage.slot,
                targetRevision: candidate.targetImage.sourceRevision
              ).first(where: { $0 == candidate }) else { throw SourceLinkStateError.staleImage }
        var state = try SourceLinkWorkspaceState.decode(snapshot.sourceLinkState, binaries: snapshot.binaries)
        guard let target = snapshot.binary(in: current.targetImage.slot),
              let targetBinding = state.binding(for: target),
              targetBinding.image == current.targetImage,
              let referenceCheckout = state.bindings.first(where: {
                  $0.image == current.referenceLink.image
              })?.checkout,
              targetBinding.checkout.localRootPath == referenceCheckout.localRootPath,
              targetBinding.checkout.recordedSourceRoot == referenceCheckout.recordedSourceRoot,
              targetBinding.checkout.revision == referenceCheckout.revision,
              let index = state.bindings.firstIndex(where: { $0.image == current.targetImage })
        else { throw SourceLinkStateError.revisionMismatch }
        var values = state.bindings[index].correlations ?? []
        if values.contains(current) { return }
        guard values.count < 1_024 else { throw SourceLinkStateError.capacity }
        values.append(current)
        state.bindings[index].correlations = values
        snapshot.sourceLinkState = try state.encoded()
        markDocumentMutated()
    }

    /// Recomputed on read/open, so changed analysis, a replaced reference, revision or slice
    /// cannot leave a persisted candidate openable merely because its saved text still exists.
    func validatedSourceCorrelationLinks(binary: BinaryImage,
                                            binding: SourceLinkWorkspaceState.Binding) -> [SourceEvidenceLink] {
        let saved = binding.correlations ?? []
        var result: [SourceEvidenceLink] = []
        for referenceSlot in Set(saved.compactMap { $0.referenceLink.image?.slot }).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let current = try? sourceFunctionCandidates(
                from: referenceSlot, to: binary.slot, targetRevision: binding.image.sourceRevision
            ) else { continue }
            let accepted = Set(saved)
            result.append(contentsOf: current.filter { accepted.contains($0) }.compactMap { $0.link(checkout: binding.checkout) })
        }
        return result
    }
}
