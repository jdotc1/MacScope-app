import Foundation

/// The one acceptance check every native-provider export runs on an accepted wire success before
/// any of its text is labelled native: the single-function export (`renderProviderPseudocode`) and
/// the whole-image batch both call it. A provider label or nonempty provenance is never proof.
enum NativeProviderExportValidation {
    struct Expectation: Equatable, Sendable {
        /// SHA-256 of the request MacScope submitted (the coordinate's or the execution's).
        let requestSHA256: String
        let artifactUUID: UUID
        /// Nil when the caller holds no projected image ID (the batch path); the artifact UUID
        /// still binds the image.
        let imageID: String?
        /// Lowercased analysis function UUID, as projected into the request.
        let functionID: String
        /// Analysis entry address, when the caller holds the function record.
        let entryAddress: UInt64?
    }

    enum Rejection: Error, Equatable, Sendable {
        case providerUnavailable
        case identityMismatch
        case missingDocument
    }

    static func acceptedDocument(
        _ success: NativeDecompilerWireSuccess,
        expected: Expectation
    ) throws -> NativeDecompilerWirePseudocodeDocument {
        guard success.availability.available else { throw Rejection.providerUnavailable }
        let result = success.result
        guard result.requestSHA256 == expected.requestSHA256,
              result.image.uuid == expected.artifactUUID,
              expected.imageID.map({ $0 == result.image.imageID }) ?? true,
              result.function.functionID == expected.functionID,
              expected.entryAddress.map({ $0 == result.function.entryAddress.value }) ?? true else {
            throw Rejection.identityMismatch
        }
        guard let document = result.pseudocodeDocument else { throw Rejection.missingDocument }
        return document
    }
}
