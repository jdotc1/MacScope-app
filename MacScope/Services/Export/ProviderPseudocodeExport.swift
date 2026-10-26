import Foundation

/// Immutable, window-captured input. The save-panel owner must recheck its
/// document/publication fence before writing; this service never consults focus.
struct ProviderPseudocodeExportInput: Sendable {
    let workspaceID: UUID
    let workspaceName: String
    let imageName: String
    let provider: PseudocodeSource
    let documentMutationGeneration: UInt64
    let expected: DecompilerPresentationIdentity
    let publication: NativeDecompilerPresentationPublicationIdentity?
    let nativeState: NativeDecompilerPresentationState
    let macScopeText: String
    let comparison: DecompilerComparisonProjection?
}

enum ProviderPseudocodeExportError: Error, Equatable {
    case nativePending
    case nativeUnavailable
    case stalePublication
    case missingNativeDocument
    case comparisonUnavailable
}

struct ProviderPseudocodeExport: Sendable {
    let text: String
    let suggestedName: String
    let workspaceID: UUID
    let documentMutationGeneration: UInt64
    let expected: DecompilerPresentationIdentity
    let publication: NativeDecompilerPresentationPublicationIdentity?
    /// Exact accepted MacScope-owned structured evidence, never reconstructed
    /// from exported text. It remains transient, just like the publication.
    let nativeEvidence: NativeDecompilerWireSuccess?
}

extension DocumentExportService {
    func renderProviderPseudocode(_ input: ProviderPseudocodeExportInput) throws -> ProviderPseudocodeExport {
        let identity = input.expected
        var header = [
            "// MacScope pseudocode export — provider: \(input.provider.rawValue)",
            "// Workspace: \(input.workspaceID.uuidString.lowercased())",
            "// Image: \(input.imageName) [slot \(identity.imageSlot.rawValue), binary \(identity.ownerBinaryID.uuidString.lowercased())]",
            "// Artifact: \(identity.artifactUUID.uuidString.lowercased()); function: \(identity.functionID)",
            "// Analysis fingerprint: \(identity.analysisInputFingerprintSHA256)",
            "// Captured document/authoring revision: \(input.documentMutationGeneration)",
        ]
        var evidence: NativeDecompilerWireSuccess?
        var body = input.macScopeText
        if input.provider != .macScope {
            let coordinate: NativeDecompilerPresentationCoordinate
            let success: NativeDecompilerWireSuccess
            switch input.nativeState {
            case .idle, .unavailable, .failed:
                throw ProviderPseudocodeExportError.nativeUnavailable
            case .analyzing:
                throw ProviderPseudocodeExportError.nativePending
            case let .ready(value, accepted):
                coordinate = value
                success = accepted
            }
            guard identity.matches(coordinate),
                  let publication = input.publication,
                  publication.coordinate == coordinate,
                  publication.requestID == success.result.requestID else {
                throw ProviderPseudocodeExportError.stalePublication
            }
            let document: NativeDecompilerWirePseudocodeDocument
            do {
                document = try NativeProviderExportValidation.acceptedDocument(success, expected: .init(
                    requestSHA256: coordinate.requestSHA256, artifactUUID: coordinate.artifactUUID,
                    imageID: coordinate.imageID, functionID: coordinate.functionID, entryAddress: nil))
            } catch NativeProviderExportValidation.Rejection.missingDocument {
                throw ProviderPseudocodeExportError.missingNativeDocument
            } catch {
                throw ProviderPseudocodeExportError.stalePublication
            }
            evidence = success
            let runtime = success.availability.runtimeIdentity
            header += [
                "// Native provider: \(runtime.backendID); engine \(runtime.engineVersion) [\(runtime.engineRevision)]",
                "// Native request SHA256 (includes authored semantic input): \(coordinate.requestSHA256)",
                "// Native wrapper: \(runtime.wrapperVersion) [\(runtime.wrapperRevision)]; package manifest: \(runtime.packageManifestSHA256); package tree: \(runtime.packageTreeSHA256)",
                "// Native target: \(runtime.languageID) / \(runtime.compilerSpecID) / \(runtime.targetProfileID); context profile: \(runtime.contextProfileSHA256)",
                "// Publication: \(publication.ownerToken.uuidString.lowercased()) generation \(publication.generation); request \(publication.requestID.uuidString.lowercased())",
                "// Native document: complete=\(document.isComplete), truncated=\(document.isTruncated)",
            ]
            body = document.text
            if input.provider == .compare {
                guard let projection = input.comparison,
                      case let .ready(comparison) = projection,
                      comparison.coordinate == coordinate,
                      comparison.structural.authority.runtimeIdentity == runtime,
                      comparison.structural.authority.requestSHA256 == coordinate.requestSHA256 else {
                    throw ProviderPseudocodeExportError.comparisonUnavailable
                }
                header.append("// Structural comparison only; an exact comparable subset is not whole-function equivalence.")
                for category in comparison.structural.categories {
                    let counts = category.counts
                    header.append("// \(category.category.rawValue): coverage=\(category.coverage.rawValue), correspondence=\(category.correspondence.rawValue), matched=\(counts.matchedCount), native-only=\(counts.nativeOnlyCount), MacScope-only=\(counts.macScopeOnlyCount), uncomparable-native=\(counts.uncomparableNativeCount), uncomparable-MacScope=\(counts.uncomparableMacScopeCount)")
                }
                body = "// ===== Native provider =====\n\(document.text)\n\n// ===== MacScope analysis provider =====\n\(input.macScopeText)"
            }
        }
        let suffix = "image-\(identity.imageSlot.rawValue)-\(input.provider.rawValue.lowercased())-pseudocode"
        return ProviderPseudocodeExport(
            text: header.joined(separator: "\n") + "\n\n" + body,
            suggestedName: "\(input.workspaceName)-\(suffix)",
            workspaceID: input.workspaceID,
            documentMutationGeneration: input.documentMutationGeneration,
            expected: identity,
            publication: input.provider == .macScope ? nil : input.publication,
            nativeEvidence: evidence
        )
    }
}
