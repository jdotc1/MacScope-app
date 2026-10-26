import Foundation

/// Stored only through the existing snapshot/package/database owner. No source contents or
/// directory enumeration are included. Binary replacements cannot inherit a previous binding.
struct SourceLinkWorkspaceState: Codable, Equatable {
    struct Binding: Codable, Equatable {
        let image: SourceLinkImageIdentity
        let checkout: AcceptedLocalSourceCheckout
        let debugArchitecture: String?
        var acceptedLinks: [SourceEvidenceLink]
        var correlations: [SourceFunctionCorrelation]? = nil
    }

    struct DebugImport: Codable, Equatable {
        let slot: ImageSlot
        let binaryID: UUID
        let uuid: UUID
        let architecture: String
        let sliceIndex: Int?
    }

    var version = 2
    var bindings: [Binding] = []
    var debugImports: [DebugImport] = []

    static func decode(_ bytes: Data, binaries: [BinaryImage] = []) throws -> Self {
        guard !bytes.isEmpty else { return Self() }
        guard bytes.count <= 1_048_576 else { throw SourceLinkStateError.invalid }
        let findings = try WorkspacePackageDuplicateKeyPreflight.findings(in: bytes)
        guard !findings.anyObjectMember else {
            throw SourceLinkStateError.invalid
        }
        var state = try JSONDecoder().decode(Self.self, from: bytes)
        guard (state.version == 1 || state.version == 2), state.bindings.count <= 64, state.debugImports.count <= 64,
              Set(state.bindings.map { $0.image.slot }).count == state.bindings.count,
              state.bindings.allSatisfy({ binding in
                  binding.image.sourceRevision == binding.checkout.revision
                      && (binding.correlations?.count ?? 0) <= 1_024
                      && (binding.correlations ?? []).allSatisfy {
                          $0.targetImage == binding.image
                              && $0.referenceLink.image?.sourceRevision == binding.checkout.revision
                              && $0.referenceLink.qualification == .exactDebugSymbols
                      }
                      && binding.acceptedLinks.count <= 1_024
                      && binding.acceptedLinks.allSatisfy {
                          $0.image == binding.image && $0.checkoutID == binding.checkout.id
                      }
              }) else { throw SourceLinkStateError.invalid }
        if state.version == 1, state.bindings.contains(where: { binding in
            !(binding.correlations ?? []).isEmpty || binding.acceptedLinks.contains { link in
                if case .some(.functionCorrelation) = link.evidence { return true }
                return false
            }
        }) { throw SourceLinkStateError.invalid }
        // V1 saved the image display label. Upgrade only an exact existing owner/slice
        // whose saved label equals that image's display label; the loader supplies the
        // new precise identity. This never equates architectures for source correlation matching.
        if state.version == 1 {
            state.bindings = state.bindings.map { binding in
                guard let binary = binaries.first(where: {
                    $0.slot == binding.image.slot && $0.id == binding.image.binaryID
                        && $0.metadata.uuid.flatMap(UUID.init(uuidString:)) == binding.image.imageUUID
                        && $0.selectedSliceIndex == binding.image.selectedSliceIndex
                        && $0.architecture == binding.image.architecture
                }), let image = SourceLinkImageIdentity(
                    slot: binary.slot, binaryID: binary.id, imageUUID: binding.image.imageUUID.uuidString,
                    architecture: SourceLinkImageIdentity.architecture(for: binary),
                    selectedSliceIndex: binary.selectedSliceIndex, sourceRevision: binding.image.sourceRevision
                ) else { return binding }
                let links = binding.acceptedLinks.map { link in
                    SourceEvidenceLink(image: image, functionAddress: link.functionAddress,
                        recordedPath: link.recordedPath, localPath: link.localPath,
                        checkoutID: link.checkoutID, line: link.line, column: link.column,
                        qualification: link.qualification, evidence: link.evidence,
                        unresolvedReason: link.unresolvedReason)
                }
                return Binding(image: image, checkout: binding.checkout,
                               debugArchitecture: binding.debugArchitecture, acceptedLinks: links)
            }
        }
        return state
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var current = self
        current.version = 2
        let bytes = try encoder.encode(current)
        _ = try Self.decode(bytes)
        return bytes
    }

    func binding(for binary: BinaryImage) -> Binding? {
        bindings.first {
            $0.image.slot == binary.slot && $0.image.binaryID == binary.id
                && $0.image.imageUUID == binary.metadata.uuid.flatMap(UUID.init(uuidString:))
                && $0.image.architecture == SourceLinkImageIdentity.architecture(for: binary)
                && $0.image.selectedSliceIndex == binary.selectedSliceIndex
        }
    }

    /// Package import assigns fresh workspace binary IDs. Preserve the proven image/slice/source
    /// facts while following that explicit owner remap, including nested accepted evidence.
    func remappingBinaryIDs(_ ids: [UUID: UUID], markerIDs: [UUID: UUID] = [:]) throws -> Self {
        func remap(_ image: SourceLinkImageIdentity) throws -> SourceLinkImageIdentity {
            guard let next = SourceLinkImageIdentity(
                slot: image.slot, binaryID: ids[image.binaryID] ?? image.binaryID,
                imageUUID: image.imageUUID.uuidString, architecture: image.architecture,
                selectedSliceIndex: image.selectedSliceIndex, sourceRevision: image.sourceRevision
            ) else { throw SourceLinkStateError.invalid }
            return next
        }
        var next = self
        next.bindings = try bindings.map { binding in
            let image = try remap(binding.image)
            let links = try binding.acceptedLinks.map { link in
                let evidence: SourceLinkEvidence?
                if case .some(.compilerMarker(let id, let description)) = link.evidence {
                    evidence = .compilerMarker(markerID: markerIDs[id] ?? id, description: description)
                } else if case .some(.functionCorrelation(let reference, let address, let uuid,
                                                          let digest, let body, let semantic)) = link.evidence {
                    evidence = .functionCorrelation(referenceImage: try remap(reference),
                        referenceAddress: address, debugArtifactUUID: uuid, debugArtifactSHA256: digest,
                        normalizedBodyHash: body, semanticBodyHash: semantic)
                } else { evidence = link.evidence }
                return SourceEvidenceLink(
                    image: image, functionAddress: link.functionAddress,
                    recordedPath: link.recordedPath, localPath: link.localPath,
                    checkoutID: link.checkoutID, line: link.line, column: link.column,
                    qualification: link.qualification, evidence: evidence,
                    unresolvedReason: link.unresolvedReason
                )
            }
            let correlations = try binding.correlations.map { values in
                try values.map { value in
                    let anchor = value.referenceLink
                    return SourceFunctionCorrelation(
                        referenceLink: SourceEvidenceLink(
                            image: try anchor.image.map(remap), functionAddress: anchor.functionAddress,
                            recordedPath: anchor.recordedPath, localPath: anchor.localPath,
                            checkoutID: anchor.checkoutID, line: anchor.line, column: anchor.column,
                            qualification: anchor.qualification, evidence: anchor.evidence,
                            unresolvedReason: anchor.unresolvedReason
                        ), targetImage: try remap(value.targetImage), targetAddress: value.targetAddress,
                        normalizedBodyHash: value.normalizedBodyHash, semanticBodyHash: value.semanticBodyHash,
                        size: value.size, instructionCount: value.instructionCount
                    )
                }
            }
            return Binding(image: image, checkout: binding.checkout,
                           debugArchitecture: binding.debugArchitecture, acceptedLinks: links,
                           correlations: correlations)
        }
        next.debugImports = debugImports.map {
            DebugImport(slot: $0.slot, binaryID: ids[$0.binaryID] ?? $0.binaryID, uuid: $0.uuid,
                        architecture: $0.architecture, sliceIndex: $0.sliceIndex)
        }
        return next
    }
}

enum SourceLinkStateError: LocalizedError {
    case invalid
    case staleImage
    case revisionMismatch
    case capacity

    var errorDescription: String? {
        switch self {
        case .invalid: "Saved source evidence is invalid or exceeds its storage bound."
        case .staleImage: "The image changed. Choose the source checkout again for this image."
        case .revisionMismatch: "The build source revision and checkout revision must match."
        case .capacity: "The workspace source evidence limit has been reached."
        }
    }
}
