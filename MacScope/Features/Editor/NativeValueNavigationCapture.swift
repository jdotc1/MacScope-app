import Foundation

struct NativePseudocodeValueRequest: Equatable, Sendable {
    let tokenID: String
    let direction: NativeValueNavigationDirection
}

/// Immutable action capture. Ownership remains the existing native presentation.
/// This object is neither persisted nor installed into WorkspaceStore.
struct NativeValueNavigationCapture: Sendable {
    let identity: NativePseudocodeActionIdentity
    let tokenID: String
    let result: NativeDecompilerWireStructuredResult

    static func capture(
        request: NativePseudocodeValueRequest,
        scope: NativePseudocodeActionScope,
        captured: NativePseudocodeActionIdentity
    ) -> Self? {
        guard captured == scope.identity, scope.document.mappingState == .verified else { return nil }
        var token: NativeDecompilerWirePseudocodeTokenRecord?
        for candidate in scope.result.tokens where candidate.id == request.tokenID {
            guard token == nil else { return nil }
            token = candidate
        }
        var run: NativeDecompilerDocumentTokenRun?
        for candidate in scope.document.tokenRuns where candidate.tokenID == request.tokenID {
            guard run == nil else { return nil }
            run = candidate
        }
        guard let token, let run,
              token.kind == run.kind,
              token.entityReferences == run.entityReferences,
              token.sourceRanges == run.sourceRanges else { return nil }
        let capture = Self(identity: captured, tokenID: request.tokenID, result: scope.result)
        return capture.matches(scope) ? capture : nil
    }

    func matches(_ scope: NativePseudocodeActionScope?) -> Bool {
        guard let scope, scope.identity == identity else { return false }
        let coordinate = identity.publication.coordinate
        return identity.publication.requestID == result.requestID
            && scope.result.requestID == result.requestID
            && scope.result.requestSHA256 == result.requestSHA256
            && coordinate.requestSHA256 == result.requestSHA256
            && coordinate.imageID == result.image.imageID
            && coordinate.artifactUUID == result.image.uuid
            && coordinate.functionID == result.function.functionID
            && scope.result.image == result.image
            && scope.result.function == result.function
    }

    /// Resolve a row/range only from a retained report and the still-current scope.
    /// Never convert rendered text, a varnode storage offset, or a client-supplied
    /// absolute address into a navigation target.
    func target(
        rowID: Int, sourceIndex: Int, report: NativeValueNavigationReport,
        currentScope: NativePseudocodeActionScope?
    ) -> ImageAddress? {
        guard matches(currentScope),
              report.requestID == result.requestID,
              report.requestSHA256 == result.requestSHA256,
              report.imageID == result.image.imageID,
              report.functionID == result.function.functionID,
              report.rows.indices.contains(rowID) else { return nil }
        let row = report.rows[rowID]
        guard row.id == rowID, row.sourceRanges.indices.contains(sourceIndex) else { return nil }
        let range = row.sourceRanges[sourceIndex]
        guard NativeValueNavigationIndex.admits(
            range: range, imageID: result.image.imageID, function: result.function
        ) else { return nil }
        return ImageAddress(
            slot: identity.publication.coordinate.imageSlot,
            address: range.startAddress.value
        )
    }
}
