import Combine
import Foundation

/// Window-session presentation choice inside the existing pseudocode editor mode.
///
/// This is deliberately nonpersisted: opening a window always begins with the product-native
/// decompiler, while selecting MacScope or Compare never mutates the native runtime session.
enum PseudocodeSource: String, CaseIterable, Hashable, Identifiable, Sendable {
    case native = "Native"
    case macScope = "MacScope"
    case compare = "Compare"

    var id: Self { self }
}

@MainActor
final class PseudocodeSourceSelectionModel: ObservableObject {
    @Published private(set) var source: PseudocodeSource

    init(source: PseudocodeSource = .native) {
        self.source = source
    }

    func select(_ source: PseudocodeSource) {
        self.source = source
    }
}

/// The store-owned identity that a native result must match before it may be presented.
struct DecompilerPresentationIdentity: Equatable, Sendable {
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID
    let artifactUUID: UUID
    let functionID: String
    let analysisInputFingerprintSHA256: String

    func matches(_ coordinate: NativeDecompilerPresentationCoordinate) -> Bool {
        imageSlot == coordinate.imageSlot
            && ownerBinaryID == coordinate.ownerBinaryID
            && artifactUUID == coordinate.artifactUUID
            && functionID == coordinate.functionID
            && analysisInputFingerprintSHA256
                == coordinate.analysisInputFingerprintSHA256
    }
}

enum NativePseudocodePresentationStatus: Equatable, Sendable {
    case idle
    case analyzing
    case ready
    case unavailable
    case failed
    case stale
}

enum NativePseudocodeFallbackReason: Equatable, Sendable {
    case idle
    case terminal(NativeDecompilerPresentationTerminalReason)
    case staleResult
    case missingDocument
}

/// A side-effect-free projection of the window runtime's native result into editor state.
struct NativePseudocodePresentation: Equatable, Sendable {
    let status: NativePseudocodePresentationStatus
    let document: NativeDecompilerDocumentProjection?
    let provider: NativeDecompilerRuntimeIdentity?
    let nativeTerminalReason: NativeDecompilerPresentationTerminalReason?
    let fallbackReason: NativePseudocodeFallbackReason?
    let usesMacScopeFallback: Bool
    /// Request-local context the ready request explicitly omitted (transient; empty otherwise).
    var contextOmissions: NativeDecompilerContextOmissionManifest = .empty
    /// The document came from a document-only request: no tokens, graph or structure links.
    var structureOmitted = false

    var failurePresentation: NativeDecompilerFailurePresentation? {
        nativeTerminalReason.map(NativeDecompilerFailureCatalog.presentation(for:))
    }

    static func project(
        state: NativeDecompilerPresentationState,
        expected: DecompilerPresentationIdentity?,
        macScopeIsAvailable: Bool
    ) -> Self {
        switch state {
        case .idle:
            return Self(
                status: .idle,
                document: nil,
                provider: nil,
                nativeTerminalReason: nil,
                fallbackReason: macScopeIsAvailable ? .idle : nil,
                usesMacScopeFallback: macScopeIsAvailable
            )

        case let .analyzing(coordinate):
            guard expected?.matches(coordinate) == true else {
                return stale(macScopeIsAvailable: macScopeIsAvailable)
            }
            return Self(
                status: .analyzing,
                document: nil,
                provider: nil,
                nativeTerminalReason: nil,
                fallbackReason: nil,
                usesMacScopeFallback: false
            )

        case let .ready(coordinate, success):
            guard expected?.matches(coordinate) == true,
                  success.result.image.uuid == coordinate.artifactUUID,
                  success.result.image.imageID == coordinate.imageID,
                  success.result.function.functionID == coordinate.functionID,
                  success.result.requestSHA256 == coordinate.requestSHA256
            else {
                return stale(macScopeIsAvailable: macScopeIsAvailable)
            }
            guard let wireDocument = success.result.pseudocodeDocument,
                  let document = try? NativeDecompilerDocumentProjector.project(
                      document: wireDocument,
                      tokens: success.result.tokens
                  )
            else {
                return Self(
                    status: .failed,
                    document: nil,
                    provider: success.availability.runtimeIdentity,
                    nativeTerminalReason: nil,
                    fallbackReason: .missingDocument,
                    usesMacScopeFallback: macScopeIsAvailable
                )
            }
            return Self(
                status: .ready,
                document: document,
                provider: success.availability.runtimeIdentity,
                nativeTerminalReason: nil,
                fallbackReason: nil,
                usesMacScopeFallback: false,
                contextOmissions: coordinate.contextOmissions,
                structureOmitted: success.result.warnings.contains { $0.code == "native-structure-omitted" }
            )

        case let .unavailable(coordinate, reason):
            return terminal(
                status: .unavailable,
                coordinate: coordinate,
                reason: reason,
                expected: expected,
                macScopeIsAvailable: macScopeIsAvailable
            )

        case let .failed(coordinate, reason):
            return terminal(
                status: .failed,
                coordinate: coordinate,
                reason: reason,
                expected: expected,
                macScopeIsAvailable: macScopeIsAvailable
            )
        }
    }

    private static func terminal(
        status: NativePseudocodePresentationStatus,
        coordinate: NativeDecompilerPresentationCoordinate?,
        reason: NativeDecompilerPresentationTerminalReason,
        expected: DecompilerPresentationIdentity?,
        macScopeIsAvailable: Bool
    ) -> Self {
        if let coordinate, expected?.matches(coordinate) != true {
            return stale(macScopeIsAvailable: macScopeIsAvailable)
        }
        return Self(
            status: status,
            document: nil,
            provider: nil,
            nativeTerminalReason: reason,
            fallbackReason: .terminal(reason),
            usesMacScopeFallback: macScopeIsAvailable
        )
    }

    private static func stale(macScopeIsAvailable: Bool) -> Self {
        Self(
            status: .stale,
            document: nil,
            provider: nil,
            nativeTerminalReason: nil,
            fallbackReason: .staleResult,
            usesMacScopeFallback: macScopeIsAvailable
        )
    }
}

struct NativePseudocodeLine: Equatable, Sendable, Identifiable {
    let lineNumber: Int
    let text: String

    var id: Int { lineNumber }

    static func lines(in document: NativeDecompilerWirePseudocodeDocument) -> [Self] {
        var textLines = document.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if document.text.hasSuffix("\n"), textLines.last == "" {
            textLines.removeLast()
        }
        return textLines.enumerated().map { offset, text in
            Self(lineNumber: offset + 1, text: text)
        }
    }
}

struct DecompilerComparison: Equatable, Sendable {
    let coordinate: NativeDecompilerPresentationCoordinate
    let structural: NativeDecompilerStructuredComparison
}

enum DecompilerComparisonUnavailableReason: Equatable, Sendable {
    case nativeUnavailable
    case macScopeUnavailable
    case coordinateMismatch
    case invalidStructure
}

enum DecompilerComparisonProjection: Equatable, Sendable {
    case ready(DecompilerComparison)
    case unavailable(DecompilerComparisonUnavailableReason)

    static func project(
        coordinate: NativeDecompilerPresentationCoordinate?,
        expected: DecompilerPresentationIdentity,
        native: NativeDecompilerWireSuccess?,
        macScope: NativeDecompilerMacScopeComparisonInput?
    ) -> Self {
        guard let coordinate, let native else {
            return .unavailable(.nativeUnavailable)
        }
        guard expected.matches(coordinate) else {
            return .unavailable(.coordinateMismatch)
        }
        guard let macScope else {
            return .unavailable(.macScopeUnavailable)
        }
        guard native.result.image.uuid == coordinate.artifactUUID,
              native.result.image.imageID == coordinate.imageID,
              native.result.function.functionID == coordinate.functionID,
              native.result.requestSHA256 == coordinate.requestSHA256
        else {
            return .unavailable(.coordinateMismatch)
        }

        let authority = NativeDecompilerComparisonAuthority(
            imageSlot: coordinate.imageSlot,
            ownerBinaryID: coordinate.ownerBinaryID,
            artifactUUID: coordinate.artifactUUID,
            functionID: coordinate.functionID,
            requestSchemaVersion: NativeDecompilerWireRequestEnvelope.currentSchemaVersion,
            requestSHA256: coordinate.requestSHA256,
            analysisInputFingerprintSHA256: coordinate.analysisInputFingerprintSHA256,
            targetProfileID: native.availability.runtimeIdentity.targetProfileID,
            runtimeIdentity: native.availability.runtimeIdentity
        )
        do {
            return .ready(DecompilerComparison(
                coordinate: coordinate,
                structural: try NativeDecompilerComparisonNormalizer.compare(
                    native: native.result,
                    nativeAuthority: authority,
                    expectedAuthority: authority,
                    macScope: macScope
                )
            ))
        } catch {
            return .unavailable(.invalidStructure)
        }
    }
}

extension NativeDecompilerMacScopeComparisonInput {
    init(analysis: ImageAnalysis, function: FunctionSummary) {
        let contains: (UInt64) -> Bool = { address in
            function.startAddress < function.endAddress
                && address >= function.startAddress
                && address < function.endAddress
        }
        self.init(
            function: function,
            instructionStarts: analysis.instructions.compactMap {
                contains($0.address) ? $0.address : nil
            },
            basicBlocks: analysis.basicBlocks.filter { $0.functionID == function.id },
            controlFlowEdges: analysis.controlFlowEdges.filter { contains($0.from) },
            directCallXRefs: analysis.xrefs.filter {
                $0.kind == XRefKind.call && contains($0.from)
            }
        )
    }
}
