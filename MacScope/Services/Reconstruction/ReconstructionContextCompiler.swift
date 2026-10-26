import CryptoKit
import Foundation

enum ReconstructionContextCompilerError: Error, Equatable, Sendable {
    case invalidGapAuthority
    case contextBudgetExceeded
    case retrieval(ReconstructionRetrievalError)
}

/// Compiles one immutable, deterministic model context from a validated evidence cut.
///
/// The compiler deliberately accepts no objective prose, database handle, path, store, or
/// provider authority. The canonical retrieval packet is the sole evidence payload.
struct ReconstructionContextCompiler: Sendable {
    private static let wireMaximumContextBytes = 1_048_576
    private static let maximumGapValues = 64
    private static let maximumGapIDs = 64
    private static let maximumGapValueUTF8Bytes = 16_384

    private struct ContextEnvelope: Encodable {
        let schemaVersion: Int
        let domain: String
        let corpusManifestSHA256: String
        let evidenceFrontierSHA256: String
        let retrievalPacket: Data
        let retrievalPacketSHA256: String
        let evidenceIDs: [UUID]
        let allowedGapSubjects: [String]
        let allowedGapCategories: [String]
        let allowedGapIDs: [UUID]
    }

    private let maximumContextBytes: Int
    private let retrievalCompiler: ReconstructionRetrievalCompiler

    init(
        maximumContextBytes: Int = Self.wireMaximumContextBytes,
        retrievalCompiler: ReconstructionRetrievalCompiler = .init()
    ) {
        self.maximumContextBytes = maximumContextBytes
        self.retrievalCompiler = retrievalCompiler
    }

    func compile(
        cut: ReconstructionEvidenceCut,
        query: ReconstructionRetrievalQuery,
        allowedGapSubjects: [String],
        allowedGapCategories: [String]
    ) throws -> ReconstructionRetrievedContext {
        try compile(cut: cut, query: query, allowedGapSubjects: allowedGapSubjects,
            allowedGapCategories: allowedGapCategories, sourceBase: false)
    }

    /// Source presentation owns the oracle, parent and diagnostics. Its ordinary base page keeps
    /// the original cut identity and validation without embedding those source payloads twice.
    func compileSourceBase(
        cut: ReconstructionEvidenceCut,
        query: ReconstructionRetrievalQuery
    ) throws -> ReconstructionRetrievedContext {
        try compile(cut: cut, query: query, allowedGapSubjects: [], allowedGapCategories: [], sourceBase: true)
    }

    private func compile(
        cut: ReconstructionEvidenceCut,
        query: ReconstructionRetrievalQuery,
        allowedGapSubjects: [String],
        allowedGapCategories: [String],
        sourceBase: Bool
    ) throws -> ReconstructionRetrievedContext {
        let budget = try contextQueryBudget(cut: cut, query: query,
            allowedGapSubjects: allowedGapSubjects, allowedGapCategories: allowedGapCategories)
        let boundedQuery = budget.query
        let contextBudget = budget.contextBytes
        let gapIDs = budget.gapIDs
        let packet: ReconstructionRetrievalPacket
        do {
            packet = try sourceBase
                ? retrievalCompiler.compileSourceBase(input: budget.input, query: boundedQuery)
                : retrievalCompiler.compile(input: budget.input, query: boundedQuery)
        } catch let error as ReconstructionRetrievalError {
            throw ReconstructionContextCompilerError.retrieval(error)
        }
        try Task.checkCancellation()

        let subjects = allowedGapSubjects.sorted()
        let categories = allowedGapCategories.sorted()
        let evidenceIDs = packet.records.map(\.evidenceID)
        let canonicalBytes = try ReconstructionCanonicalJSON.encode(ContextEnvelope(
            schemaVersion: 8,
            domain: "reconstruction.context.v8",
            corpusManifestSHA256: cut.corpusManifestSHA256,
            evidenceFrontierSHA256: cut.frontierSHA256,
            retrievalPacket: packet.canonicalBytes,
            retrievalPacketSHA256: packet.canonicalSHA256,
            evidenceIDs: evidenceIDs,
            allowedGapSubjects: subjects,
            allowedGapCategories: categories,
            allowedGapIDs: gapIDs
        ))
        guard canonicalBytes.count <= contextBudget else {
            throw ReconstructionContextCompilerError.contextBudgetExceeded
        }
        let digest = Self.sha256(canonicalBytes)
        try Task.checkCancellation()
        return ReconstructionRetrievedContext(
            canonicalBytes: canonicalBytes,
            canonicalSHA256: digest,
            evidenceIDs: evidenceIDs,
            allowedGapSubjects: subjects,
            allowedGapCategories: categories,
            allowedGapIDs: gapIDs
        )
    }

    /// Bound the tool query before minting its handle so an executed read and the delivered
    /// model context consume exactly the same evidence page. This operation is idempotent.
    func boundedQuery(cut: ReconstructionEvidenceCut, query: ReconstructionRetrievalQuery,
        allowedGapSubjects: [String], allowedGapCategories: [String]) throws
        -> ReconstructionRetrievalQuery {
        try contextQueryBudget(cut: cut, query: query,
            allowedGapSubjects: allowedGapSubjects, allowedGapCategories: allowedGapCategories).query
    }

    private func contextQueryBudget(cut: ReconstructionEvidenceCut,
        query: ReconstructionRetrievalQuery, allowedGapSubjects: [String],
        allowedGapCategories: [String]) throws
        -> (query: ReconstructionRetrievalQuery, contextBytes: Int, gapIDs: [UUID],
            input: ReconstructionRetrievalProjectionInput) {
        try Task.checkCancellation()
        guard maximumContextBytes > 0,
              maximumContextBytes <= Self.wireMaximumContextBytes,
              Self.validGapAuthority(allowedGapSubjects),
              Self.validGapAuthority(allowedGapCategories)
        else {
            if maximumContextBytes <= 0 || maximumContextBytes > Self.wireMaximumContextBytes {
                throw ReconstructionContextCompilerError.contextBudgetExceeded
            }
            throw ReconstructionContextCompilerError.invalidGapAuthority
        }

        let gapIDs = ReconstructionValidation.sortedUUIDs(cut.gaps.filter {
            query.focus == nil || query.includes(subject: $0.subject)
        }.map(\.gapID))
        guard gapIDs.count <= Self.maximumGapIDs else {
            throw ReconstructionContextCompilerError.invalidGapAuthority
        }
        let input: ReconstructionRetrievalProjectionInput
        let remainingCount: Int
        do {
            input = try ReconstructionRetrievalProjectionInput(cut: cut)
            remainingCount = try retrievalCompiler.remainingCandidateCount(input: input, query: query)
        } catch let error as ReconstructionRetrievalError {
            throw ReconstructionContextCompilerError.retrieval(error)
        }
        // Reserve both Base64 expansions and the repeated evidence-ID arrays in the
        // context and XPC request. The wire cap applies to the complete request.
        let emptyEnvelope = try ReconstructionCanonicalJSON.encode(ContextEnvelope(
            schemaVersion: 8,
            domain: "reconstruction.context.v8",
            corpusManifestSHA256: cut.corpusManifestSHA256,
            evidenceFrontierSHA256: cut.frontierSHA256,
            retrievalPacket: Data(),
            retrievalPacketSHA256: String(repeating: "0", count: 64),
            evidenceIDs: [],
            allowedGapSubjects: allowedGapSubjects.sorted(),
            allowedGapCategories: allowedGapCategories.sorted(),
            allowedGapIDs: gapIDs
        ))
        let recordBudget = min(query.maximumRecords, 4_096)
        // Only records eligible after this query's cursor can be repeated as context/request
        // evidence IDs. Reserving all requested slots could exclude a fitting source observation
        // when most records in the cut belong to the source channel or another subject.
        let repeatedIDBytes = min(recordBudget, remainingCount) * 39
        // The same authority arrays are repeated outside the Base64 context. Reserve
        // their full size plus the bounded round handles and request identity fields.
        let wireContextBudget = (Phase2ReconstructionAIWorkerWireCodec.maximumEnvelopeBytes
            - emptyEnvelope.count - repeatedIDBytes - 8_192) / 4 * 3
        let contextBudget = min(maximumContextBytes, wireContextBudget)
        let availablePacketBytes = (contextBudget - emptyEnvelope.count
            - repeatedIDBytes - 4) / 4 * 3
        guard availablePacketBytes > 0 else {
            throw ReconstructionContextCompilerError.contextBudgetExceeded
        }
        let boundedQuery = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: query.corpusManifestSHA256,
            subject: query.subject,
            operationIDs: query.operationIDs,
            classifications: query.classifications,
            cursor: query.cursor,
            maximumRecords: recordBudget,
            maximumEncodedBytes: min(query.maximumEncodedBytes, availablePacketBytes),
            focus: query.focus
        )
        return (boundedQuery, contextBudget, gapIDs, input)
    }

    private static func validGapAuthority(_ values: [String]) -> Bool {
        values.count <= maximumGapValues
            && Set(values).count == values.count
            && values.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= maximumGapValueUTF8Bytes
            }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
