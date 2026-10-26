import Foundation

@MainActor
extension WorkspaceStore {
    func sourceLinks(at address: UInt64, in slot: ImageSlot) throws -> [SourceEvidenceLink] {
        guard let binary = snapshot.binary(in: slot) else { throw SourceLinkStateError.staleImage }
        let state = try SourceLinkWorkspaceState.decode(snapshot.sourceLinkState, binaries: snapshot.binaries)
        guard let binding = state.binding(for: binary) else { return [] }
        return currentSourceLinks(binary: binary, binding: binding, address: address)
    }

    func acceptSourceCheckout(
        _ checkout: AcceptedLocalSourceCheckout,
        buildRevision: SourceRevisionIdentity,
        expectedBinary: BinaryImage,
        expectedInstallationID: UUID,
        address: UInt64
    ) throws {
        guard documentInstallationID == expectedInstallationID,
              snapshot.binary(in: expectedBinary.slot) == expectedBinary,
              let image = SourceLinkImageIdentity(
                slot: expectedBinary.slot, binaryID: expectedBinary.id,
                imageUUID: expectedBinary.metadata.uuid ?? "", architecture: SourceLinkImageIdentity.architecture(for: expectedBinary),
                selectedSliceIndex: expectedBinary.selectedSliceIndex, sourceRevision: buildRevision
              ) else { throw SourceLinkStateError.staleImage }
        guard checkout.revision == buildRevision else { throw SourceLinkStateError.revisionMismatch }
        var state = try SourceLinkWorkspaceState.decode(snapshot.sourceLinkState, binaries: snapshot.binaries)
        let imported = state.debugImports.first {
            $0.slot == image.slot && $0.binaryID == image.binaryID && $0.uuid == image.imageUUID
                && $0.sliceIndex == image.selectedSliceIndex
        }
        var binding = SourceLinkWorkspaceState.Binding(
            image: image, checkout: checkout, debugArchitecture: imported?.architecture, acceptedLinks: []
        )
        binding.acceptedLinks = sourceIndex(binary: expectedBinary, binding: binding)
            .links(functionAddress: address).filter { $0.isOpenable }
        state.bindings.removeAll { $0.image.slot == image.slot }
        guard state.bindings.count < 64 else { throw SourceLinkStateError.capacity }
        state.bindings.append(binding)
        snapshot.sourceLinkState = try state.encoded()
        markDocumentMutated()
    }

    /// Captures architecture from the actual UUID-matched importer, rather than assuming the
    /// architecture of a later focused image. Legacy imports require reimport before exact use.
    func retainSourceDebugImport(_ result: DSYMImportResult, in slot: ImageSlot) {
        guard let binary = snapshot.binary(in: slot),
              let uuid = UUID(uuidString: result.matchedUUID),
              uuid == binary.metadata.uuid.flatMap(UUID.init(uuidString:)),
              let architecture = result.matchedSliceArchitecture,
              var state = try? SourceLinkWorkspaceState.decode(snapshot.sourceLinkState, binaries: snapshot.binaries) else { return }
        state.debugImports.removeAll { $0.slot == slot }
        guard state.debugImports.count < 64 else { return }
        state.debugImports.append(.init(slot: slot, binaryID: binary.id, uuid: uuid,
                                       architecture: architecture, sliceIndex: binary.selectedSliceIndex))
        // Reimport invalidates the earlier accepted source binding; a new explicit acceptance
        // supplies the revision associated with this new debug artifact.
        state.bindings.removeAll { $0.image.slot == slot }
        guard let bytes = try? state.encoded() else { return }
        snapshot.sourceLinkState = bytes
        markDocumentMutated()
    }

    func sourceOpenTarget(
        _ link: SourceEvidenceLink, origin: SourceLinkOpenOrigin
    ) throws -> SourceFileOpenTarget {
        guard let binary = snapshot.binary(in: origin.slot) else { throw SourceLinkStateError.staleImage }
        let state = try SourceLinkWorkspaceState.decode(snapshot.sourceLinkState, binaries: snapshot.binaries)
        guard let binding = state.binding(for: binary),
              let current = currentSourceLinks(binary: binary, binding: binding, address: link.functionAddress)
                .first(where: { $0 == link }) else {
            throw SourceLinkOpenError.staleImage
        }
        return try SourceLinkOpener().target(for: current, origin: origin,
                                            currentImage: binding.image, checkout: binding.checkout)
    }

    func retainOpenedSourceLink(_ link: SourceEvidenceLink, origin: SourceLinkOpenOrigin) throws {
        _ = try sourceOpenTarget(link, origin: origin)
        var state = try SourceLinkWorkspaceState.decode(snapshot.sourceLinkState, binaries: snapshot.binaries)
        guard let index = state.bindings.firstIndex(where: { $0.image == link.image }) else {
            throw SourceLinkOpenError.staleImage
        }
        guard !state.bindings[index].acceptedLinks.contains(link) else { return }
        guard state.bindings[index].acceptedLinks.count < 1_024 else { throw SourceLinkStateError.capacity }
        state.bindings[index].acceptedLinks.append(link)
        snapshot.sourceLinkState = try state.encoded()
        markDocumentMutated()
    }

    private func currentSourceLinks(binary: BinaryImage, binding: SourceLinkWorkspaceState.Binding,
                                    address: UInt64) -> [SourceEvidenceLink] {
        sourceIndex(binary: binary, binding: binding).links(functionAddress: address)
            + validatedSourceCorrelationLinks(binary: binary, binding: binding)
                .filter { $0.functionAddress == address }
    }

    private func sourceIndex(
        binary: BinaryImage, binding: SourceLinkWorkspaceState.Binding
    ) -> SourceCandidateIndex {
        SourceCandidateIndex(
            binary: binary, sourceRevision: binding.image.sourceRevision,
            debugContext: binding.debugArchitecture.map {
                .init(architecture: $0, sourceRevision: binding.image.sourceRevision)
            },
            sourceLines: snapshot.analysis(in: binary.slot)?.sourceLines ?? [],
            compilerMarkers: sourcePathMarkers(in: binary.slot),
            acceptedCheckouts: [binding.checkout]
        )
    }

    private func sourcePathMarkers(in slot: ImageSlot) -> [CompilerSourceMarker] {
        // Consume only the already recovered string table, with a small fixed input/output
        // bound. No byte scan, directory walk, or claim that a path string identifies a function.
        let extensions: Set<String> = ["c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "swift"]
        return Array((snapshot.analysis(in: slot)?.stringLiterals ?? []).prefix(1_024).compactMap { literal -> CompilerSourceMarker? in
            guard literal.value.utf8.count <= 4_096, literal.value.contains("/"),
                  !literal.value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  extensions.contains(NSString(string: literal.value).pathExtension.lowercased()) else { return nil }
            return CompilerSourceMarker(
                id: literal.id, recordedPath: literal.value,
                description: "Image-wide embedded path string at \(literal.address.hexAddress); no function or line mapping established."
            )
        }.prefix(32))
    }
}
