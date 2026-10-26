import Foundation

/// Stand-alone semantic contract. MacScope's selected binary, slot, resource
/// ownership and generation must be projected into these DTOs by an app adapter.
/// No donor model or absolute filesystem path is part of persisted contracts.
public struct AppKitImageKey: Codable, Hashable, Sendable {
    public let imageID: String
    public let imageGeneration: String
    public let bundleGeneration: String

    public init(imageID: String, imageGeneration: String, bundleGeneration: String) {
        self.imageID = imageID
        self.imageGeneration = imageGeneration
        self.bundleGeneration = bundleGeneration
    }
}

extension AppKitImageKey {
    public var hasValidIdentity: Bool {
        [imageID, imageGeneration, bundleGeneration].allSatisfy { value in
            !value.isEmpty && value.utf8.count <= 4096 &&
            value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
    }
}

public struct AppKitResourceIdentity: Codable, Hashable, Sendable {
    public let bundleID: String
    public let bundleGeneration: String
    /// Stable relative path inside the admitted bundle; never an absolute path.
    public let relativePath: String
    public let contentSHA256: String

    public init(bundleID: String, bundleGeneration: String, relativePath: String, contentSHA256: String) {
        self.bundleID = bundleID
        self.bundleGeneration = bundleGeneration
        self.relativePath = relativePath
        self.contentSHA256 = contentSHA256
    }

    public var hasValidIdentity: Bool {
        guard !bundleID.isEmpty, !bundleGeneration.isEmpty,
              !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              relativePath.lowercased().hasSuffix(".nib"),
              !relativePath.contains("\\"),
              bundleID.utf8.count <= 4096, bundleGeneration.utf8.count <= 4096,
              relativePath.utf8.count <= 4096,
              [bundleID, bundleGeneration, relativePath].allSatisfy({ string in
                  string.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
              }),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false)
                 .contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              contentSHA256.utf8.count == 64,
              contentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return false }
        return true
    }
}

public struct NibConnection: Codable, Hashable, Sendable {
    /// Keep string open for future upstream kinds; only exact "action" is callable.
    public let kind: String
    public let name: String
    public let source: String
    public let destination: String
    public let event: String?
    /// Optional future donor patch: indices are resource-local, never VM addresses.
    public let sourceObjectIndex: Int?
    public let destinationObjectIndex: Int?

    public init(kind: String, name: String, source: String, destination: String,
                event: String? = nil, sourceObjectIndex: Int? = nil,
                destinationObjectIndex: Int? = nil) {
        self.kind = kind
        self.name = name
        self.source = source
        self.destination = destination
        self.event = event
        self.sourceObjectIndex = sourceObjectIndex
        self.destinationObjectIndex = destinationObjectIndex
    }
}

public struct NibRuntimeAttribute: Codable, Hashable, Sendable {
    public let object: String
    public let keyPath: String
    public let value: String
}

public struct NibCustomClass: Codable, Hashable, Sendable {
    public let `class`: String
    public let base: String
    public let sceneID: String?
    public let module: String?
}

public struct NibNavigationHint: Codable, Hashable, Sendable {
    public let kind: String
    public let sourceClass: String
    public let sourceSceneID: String?
    public let destinationClass: String?
    public let destinationID: String?
    public let identifier: String?
    public let selector: String?
    public let customClass: String?
    /// Values are opaque donor hints; they carry no proven AppKit semantics.
    public let details: [String: String]?
}

public struct NibDecodedDocument: Codable, Sendable {
    public let resource: AppKitResourceIdentity
    public let donorRevision: String
    public let archiveFormatVersion: Int
    public let coderVersion: Int
    public let outlets: [NibConnection]
    /// Upstream nibkit includes `binding`/`help` in this array: check kind.
    public let actions: [NibConnection]
    public let runtimeAttributes: [NibRuntimeAttribute]
    public let customClasses: [NibCustomClass]
    public let navigation: [NibNavigationHint]

    public init(resource: AppKitResourceIdentity, donorRevision: String,
                archiveFormatVersion: Int, coderVersion: Int,
                outlets: [NibConnection], actions: [NibConnection],
                runtimeAttributes: [NibRuntimeAttribute],
                customClasses: [NibCustomClass], navigation: [NibNavigationHint]) {
        self.resource = resource
        self.donorRevision = donorRevision
        self.archiveFormatVersion = archiveFormatVersion
        self.coderVersion = coderVersion
        self.outlets = outlets
        self.actions = actions
        self.runtimeAttributes = runtimeAttributes
        self.customClasses = customClasses
        self.navigation = navigation
    }
}

public enum NibRefusalReason: String, Codable, Sendable {
    case invalidResourceIdentity, unexpectedDocument, duplicateDocument
    case missingRequiredFields, corruptJSON, donorDocumentError
    case outputTooLarge, tooManyDocuments, tooManyRecords
    case oversizedText, donorExitNonzero, unsupportedDonorRevision
}

public struct NibRefusal: Codable, Hashable, Sendable {
    public let inputLabel: String
    public let reason: NibRefusalReason
    /// A bounded, app-owned diagnostic string; no untrusted raw input copied.
    public let detail: String

    public init(inputLabel: String, reason: NibRefusalReason, detail: String) {
        self.inputLabel = inputLabel
        self.reason = reason
        self.detail = detail
    }
}

public struct NibParseBatch: Codable, Sendable {
    public let documents: [NibDecodedDocument]
    public let refusals: [NibRefusal]
    public let helperExitCode: Int32
    public let complete: Bool

    public init(documents: [NibDecodedDocument], refusals: [NibRefusal],
                helperExitCode: Int32, complete: Bool) {
        self.documents = documents
        self.refusals = refusals
        self.helperExitCode = helperExitCode
        self.complete = complete
    }
}

public enum AppKitObjCMethodOwnerKind: String, Codable, Hashable, Sendable { case classDefinition, categoryDefinition }

public struct ObjCMethodFact: Codable, Hashable, Sendable {
    public let image: AppKitImageKey
    public let ownerClass: String
    public let selector: String
    public let isClassMethod: Bool
    public let ownerKind: AppKitObjCMethodOwnerKind
    /// Preferred/link-time VM coordinate, NOT a process slide-adjusted pointer.
    public let implementationVMAddress: UInt64?

    public init(image: AppKitImageKey, ownerClass: String, selector: String,
                isClassMethod: Bool, ownerKind: AppKitObjCMethodOwnerKind = .classDefinition,
                implementationVMAddress: UInt64?) {
        self.image = image
        self.ownerClass = ownerClass
        self.selector = selector
        self.isClassMethod = isClassMethod
        self.ownerKind = ownerKind
        self.implementationVMAddress = implementationVMAddress
    }
}

public enum AppKitClaimStatus: String, Codable, Sendable {
    case observed, candidate, corroboratedStatic, unresolved
}

public struct CandidateImplementation: Codable, Hashable, Sendable {
    public let image: AppKitImageKey
    public let vmAddress: UInt64
}

public struct AppKitSemanticClaim: Codable, Sendable {
    public let claimID: String
    public let resource: AppKitResourceIdentity
    public let donorRevision: String
    public let kind: String
    public let ordinal: Int
    public let selectorOrKey: String
    public let sourceLabel: String
    public let destinationLabel: String
    /// Present for action connectors with an event mask/name; never a call proof.
    public let eventLabel: String?
    /// Raw observed attribute/metadata value; not a destination class.
    public let observedValue: String?
    public let status: AppKitClaimStatus
    public let candidateImplementation: CandidateImplementation?
    public let candidateCount: Int
    public let refusalReason: String?
    public let evidenceOrigins: [String]
    /// Always false in v1; only a separate process/session-bound runtime proof
    /// can ever establish a real dispatch, never a NIB or method-name match.
    public let runtimeDispatchProven: Bool

    public init(claimID: String, resource: AppKitResourceIdentity, donorRevision: String,
                kind: String, ordinal: Int, selectorOrKey: String, sourceLabel: String,
                destinationLabel: String, eventLabel: String? = nil,
                observedValue: String? = nil, status: AppKitClaimStatus,
                candidateImplementation: CandidateImplementation? = nil,
                candidateCount: Int = 0, refusalReason: String? = nil,
                evidenceOrigins: [String]) {
        self.claimID = claimID
        self.resource = resource
        self.donorRevision = donorRevision
        self.kind = kind
        self.ordinal = ordinal
        self.selectorOrKey = selectorOrKey
        self.sourceLabel = sourceLabel
        self.destinationLabel = destinationLabel
        self.eventLabel = eventLabel
        self.observedValue = observedValue
        self.status = status
        self.candidateImplementation = candidateImplementation
        self.candidateCount = candidateCount
        self.refusalReason = refusalReason
        self.evidenceOrigins = evidenceOrigins
        self.runtimeDispatchProven = false
    }
}
