import Foundation

/// App-side authority retained beside a native request without retaining the workspace,
/// a filesystem path, or any lazy byte reader.
struct NativeDecompilerSnapshotCoordinate: Sendable, Equatable {
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID
    let analysisInputFingerprintSHA256: String
}

/// Eager immutable content for one native-decompiler submission.
///
/// Correlation, canonical digest, transport budgets, and encoding are deliberately owned by the
/// submission boundary rather than by this workspace projection.
struct NativeDecompilerSnapshotProjection: Sendable, Equatable {
    let coordinate: NativeDecompilerSnapshotCoordinate
    let target: NativeDecompilerWireTarget
    let image: NativeDecompilerWireImageIdentity
    let function: NativeDecompilerWireFunctionIdentity
    let memoryRegions: [NativeDecompilerWireMemoryRegion]
    let symbols: [NativeDecompilerWireSymbolRecord]
    let authoredInputs: NativeDecompilerWireAuthoredInputs
    /// Request-local context deliberately left out of this request; part of request identity.
    var contextOmissions: NativeDecompilerContextOmissionManifest = .empty
}

/// Why one request-local context subject was left out of a native request.
///
/// Omission never relabels or weakens bytes: a subject is either supplied with full loader
/// byte authority or not supplied at all. The selected function's own bytes are never omitted;
/// any authority failure there still rejects the whole request.
enum NativeDecompilerContextOmissionReason: String, Sendable, Hashable, CaseIterable {
    /// The request-local context byte or region budget was exhausted by more relevant subjects.
    case budget
    /// The subject lies in loader memory that is writable at load time.
    case writable
    /// No exact loader-issued identity-effective attestation matched the subject's segment bytes.
    case unattested
    /// A workspace byte patch intersects the subject's bytes.
    case patchIntersection
    /// A known loader relocation rewrites part of the subject's bytes.
    case relocationIntersection
    /// The subject is not wholly covered by readable file-backed loader bytes of the required kind.
    case unmapped
    /// An authored function subject has no unique, aligned analysis extent to supply.
    case unresolvedSubject
}

/// Kind of request-local context candidate considered for one native request.
enum NativeDecompilerContextSubjectKind: String, Sendable, Hashable, CaseIterable {
    case authoredFunction
    case authoredLabel
    case authoredData
    case authoredAppliedType
    case derivedCallee
    case derivedData
}

/// One omitted request-local context subject.
struct NativeDecompilerContextOmission: Sendable, Hashable {
    let subjectKind: NativeDecompilerContextSubjectKind
    let startAddress: UInt64
    let endAddressExclusive: UInt64
    let reason: NativeDecompilerContextOmissionReason
    /// Call-graph distance from the selected function (1 = direct reference); nil when unrelated
    /// within the bounded relevance search.
    let relevanceDistance: Int?
}

/// Explicit, deterministic record of request-local context that a native request omitted.
///
/// The manifest is transient presentation evidence and part of request/cache identity: a result
/// produced for one omission set is never served for another. It is never persisted.
struct NativeDecompilerContextOmissionManifest: Sendable, Hashable {
    static let maximumRetainedEntries = 64
    static let empty = NativeDecompilerContextOmissionManifest(
        omissions: [], omittedNameCount: 0, omittedSignatureCount: 0, omittedAppliedTypeCount: 0
    )

    /// Total omitted subjects, including those beyond `entries`.
    let totalCount: Int
    let countsByReason: [NativeDecompilerContextOmissionReason: Int]
    /// Authored wire inputs removed from the request because their subject was omitted.
    let omittedNameCount: Int
    let omittedSignatureCount: Int
    let omittedAppliedTypeCount: Int
    /// The most relevant omissions, in relevance order, bounded for presentation.
    let entries: [NativeDecompilerContextOmission]
    /// SHA-256 over the canonical encoding of every omission and authored-input count.
    let identitySHA256: String

    var isEmpty: Bool { totalCount == 0 }
    var omittedAuthoredInputCount: Int {
        omittedNameCount + omittedSignatureCount + omittedAppliedTypeCount
    }

    func count(for reason: NativeDecompilerContextOmissionReason) -> Int {
        countsByReason[reason, default: 0]
    }

    /// `omissions` must already be in the builder's deterministic relevance order.
    init(
        omissions: [NativeDecompilerContextOmission],
        omittedNameCount: Int,
        omittedSignatureCount: Int,
        omittedAppliedTypeCount: Int
    ) {
        var counts: [NativeDecompilerContextOmissionReason: Int] = [:]
        var canonical = "macscope.native.context-omissions.v1\n"
        canonical += "names=\(omittedNameCount);signatures=\(omittedSignatureCount);"
        canonical += "appliedTypes=\(omittedAppliedTypeCount);count=\(omissions.count)\n"
        for omission in omissions {
            counts[omission.reason, default: 0] += 1
            canonical += "\(omission.subjectKind.rawValue)|\(omission.startAddress)|"
            canonical += "\(omission.endAddressExclusive)|\(omission.reason.rawValue)|"
            canonical += "\(omission.relevanceDistance.map(String.init) ?? "-")\n"
        }
        totalCount = omissions.count
        countsByReason = counts
        self.omittedNameCount = omittedNameCount
        self.omittedSignatureCount = omittedSignatureCount
        self.omittedAppliedTypeCount = omittedAppliedTypeCount
        entries = Array(omissions.prefix(Self.maximumRetainedEntries))
        identitySHA256 = AnalysisFingerprintBuilder.sha256Hex(Data(canonical.utf8))
    }
}
