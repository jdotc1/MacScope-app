import CryptoKit
import Darwin
import Foundation

/// The request surface that crosses the analysis worker boundary. Shared by the client (which
/// ENCODES it) and the worker (which DECODES it).
struct AnalysisRequest: Equatable {
    let url: URL
    let selection: BinaryLoadSelection
    let overrides: [UInt64: AddressOverride]
    let requestID: UUID
    /// Optional per-request CPU ceiling (PERF-B). Absent on the wire means the worker's
    /// host-derived interactive default.
    let resourceBudget: AnalysisResourceBudget?
    /// HOP-3: optional time/memory budget for the analysis. Absent on the wire means unlimited.
    let analysisBudget: AnalysisBudget?

    var requestedSliceIndex: Int? { selection.requestedMachOSliceIndex }

    init(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID,
        resourceBudget: AnalysisResourceBudget? = nil,
        analysisBudget: AnalysisBudget? = nil
    ) {
        self.url = url
        self.selection = selection
        self.overrides = overrides
        self.requestID = requestID
        self.resourceBudget = resourceBudget
        self.analysisBudget = analysisBudget
    }

    init(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        requestID: UUID,
        resourceBudget: AnalysisResourceBudget? = nil
    ) {
        self.init(
            url: url,
            selection: .machOSlice(requestedSliceIndex),
            overrides: overrides,
            requestID: requestID,
            resourceBudget: resourceBudget
        )
    }
}

/// The CLIENT half of the wire boundary: encode an outbound request, decode an inbound reply.
/// `XPCAnalysisProvider` depends on exactly this (interface segregation — it never needs the
/// worker's decode/encode direction).
protocol AnalysisClientWireCodec: Sendable {
    func encodeRequest(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        requestID: UUID
    ) -> Data

    func encodeRequest(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID
    ) -> Data

    func encodeRequest(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID,
        resourceBudget: AnalysisResourceBudget?
    ) -> Data

    /// HOP-3: also carries the analysis's time/memory budget.
    func encodeRequest(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID,
        resourceBudget: AnalysisResourceBudget?,
        analysisBudget: AnalysisBudget?
    ) -> Data

    /// Returns the analyzed snapshot, or throws: `AnalysisCancelled` for a cancelled reply,
    /// `RemoteAnalysisFailure` for a worker analysis failure (carrying its message),
    /// `AnalysisWorkerError.versionMismatch` for a protocol-version mismatch, or a decode error
    /// for a genuinely malformed reply (which the provider surfaces as `.malformedReply`).
    func decodeReply(_ data: Data) throws -> WorkspaceSnapshot

    /// PERF-C2: decodes a reply to a pinned request. `pinnedSource` is the client's own handle on
    /// the source it sent with `analyzePinned`; a reply may describe its image bytes as a range of
    /// that source (plus SHA-256) instead of carrying them, and the codec reads and verifies them.
    func decodeReply(_ data: Data, pinnedSource: FileHandle?) throws -> WorkspaceSnapshot
}

extension AnalysisClientWireCodec {
    /// Injected codecs that never emit pinned ranges decode exactly as before.
    func decodeReply(_ data: Data, pinnedSource: FileHandle?) throws -> WorkspaceSnapshot {
        try decodeReply(data)
    }

    func encodeRequest(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID,
        resourceBudget: AnalysisResourceBudget?
    ) -> Data {
        // Compatibility for injected codecs; the production codec carries the explicit budget.
        encodeRequest(url: url, selection: selection, overrides: overrides, requestID: requestID)
    }

    func encodeRequest(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID,
        resourceBudget: AnalysisResourceBudget?,
        analysisBudget: AnalysisBudget?
    ) -> Data {
        // Compatibility for injected codecs; the production codec carries the analysis budget.
        encodeRequest(url: url, selection: selection, overrides: overrides, requestID: requestID,
                      resourceBudget: resourceBudget)
    }

    func encodeRequest(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID
    ) -> Data {
        guard selection.elfArchiveMember == nil, selection.coffSectionLayoutVersion == nil,
              selection.dyldCacheImagePath == nil else { return Data() }
        return encodeRequest(
            url: url,
            requestedSliceIndex: selection.requestedMachOSliceIndex,
            overrides: overrides,
            requestID: requestID
        )
    }
}

/// The WORKER half: decode an inbound request, encode a reply. `AnalysisWorkerService` depends on
/// exactly this. `encodeReply` never throws — a worker must always produce a reply.
protocol AnalysisWorkerWireCodec: Sendable {
    func decodeRequest(_ data: Data) throws -> AnalysisRequest
    func encodeReply(_ result: Result<WorkspaceSnapshot, Error>) -> Data

    /// PERF-C2: `pinnedImageBytes`, when non-nil, says the successful snapshot's image bytes are
    /// exactly that range of the request's pinned source, so the codec may omit them.
    func encodeReply(
        _ result: Result<WorkspaceSnapshot, Error>,
        pinnedImageBytes: AnalysisPinnedImageByteRange?
    ) -> Data
}

extension AnalysisWorkerWireCodec {
    /// Injected codecs without the pinned-range form keep the bytes inline.
    func encodeReply(
        _ result: Result<WorkspaceSnapshot, Error>,
        pinnedImageBytes: AnalysisPinnedImageByteRange?
    ) -> Data {
        encodeReply(result)
    }
}

/// A worker-side analysis failure surfaced to the client WITH its message. Distinct from a
/// transport crash (`AnalysisWorkerError.workerCrashed`) and from a malformed reply
/// (`.malformedReply`): the analysis actually ran and failed (e.g. an unreadable file), so the
/// store shows this message exactly as the in-process engine's thrown error would appear.
struct RemoteAnalysisFailure: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// The production codec: one value that satisfies BOTH halves, backed by P1's
/// `AnalysisPayloadCodec` for the snapshot payload. The reply envelope distinguishes a successful
/// payload from each worker-failure kind so the client re-throws a faithful error; the request
/// envelope carries the analyze inputs (`UInt64`-keyed overrides flattened to pairs, matching the
/// codec's dictionary discipline). A `wireVersion` guards against a client/worker skew.
///
/// Version 3 (PERF-C2): the reply envelope gains `imageBytesInPinnedSource`. When the request came
/// through `analyzePinned` and the worker verified that the snapshot's image bytes are a byte range
/// of that pinned source, the reply carries the range and its SHA-256 and leaves
/// `payload.imageBytes` empty; the client reads the range from its own pinned handle and checks the
/// hash. Without a pinned source (plain `analyze`), or when no verified range exists, the bytes stay
/// inline (base64 in the JSON) exactly as in version 2. The request envelope is unchanged apart
/// from its version number.
/// Version 4 adds explicit saved COFF layout policy; older peers must not silently drop it.
struct PayloadWireCodec: AnalysisClientWireCodec, AnalysisWorkerWireCodec {
    static let wireVersion = 4

    /// The inline image uses base64; pinned images have a separate decoded-byte ceiling.
    /// These are rejection budgets, never truncation limits. Reduced values support small tests.
    struct Limits: Sendable {
        var maximumRequestBytes = 64 << 20
        var maximumReplyBytes = 1 << 30
        var maximumOverrides = 100_000
        var maximumRequestValues = 2_000_000
        var maximumReplyValues = 32_000_000
        var maximumRequestStringBytes = 48 << 20
        var maximumReplyStringBytes = 768 << 20
        var maximumRequestSingleStringBytes = 4 << 20
        var maximumReplySingleStringBytes = 512 << 20
        var maximumNestingDepth = 128
        var maximumPinnedImageBytes = 2 << 30

        static let production = Limits()
    }

    private let limits: Limits
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(limits: Limits = .production) {
        self.limits = limits
    }

    /// Count the wire representation without building a second JSON object graph. Every key,
    /// scalar and container counts toward aggregate model weight, including nested authoring
    /// and metadata. String counts use encoded bytes (including escapes), a conservative upper
    /// bound on decoded UTF-8. JSONDecoder remains responsible for syntax and schema validation.
    private func validateEnvelope(_ data: Data, isRequest: Bool) throws {
        let name = isRequest ? "request" : "reply"
        let byteLimit = isRequest ? limits.maximumRequestBytes : limits.maximumReplyBytes
        guard data.count <= byteLimit else { throw Self.limitError(name, "raw byte") }
        let valueLimit = isRequest ? limits.maximumRequestValues : limits.maximumReplyValues
        let stringLimit = isRequest ? limits.maximumRequestStringBytes : limits.maximumReplyStringBytes
        let singleStringLimit = isRequest
            ? limits.maximumRequestSingleStringBytes : limits.maximumReplySingleStringBytes
        var values = 0
        var stringBytes = 0
        var currentStringBytes = 0
        var depth = 0
        var inString = false
        var escaped = false
        var inScalar = false
        for byte in data {
            // The encoder emits UTF-8. Literal NUL is invalid in UTF-8 JSON and rejects
            // UTF-16/32 encodings whose interleaved zero bytes would alter lexical accounting.
            guard byte != 0 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "Analysis \(name) must use UTF-8 JSON."
                ))
            }
            if inString {
                if byte == 0x22 && !escaped {
                    inString = false
                    continue
                }
                guard currentStringBytes < singleStringLimit, stringBytes < stringLimit else {
                    throw Self.limitError(name, "string byte")
                }
                currentStringBytes += 1
                stringBytes += 1
                if escaped { escaped = false } else { escaped = byte == 0x5c }
                continue
            }
            switch byte {
            case 0x22: // quoted key or value
                inString = true
                escaped = false
                currentStringBytes = 0
                inScalar = false
            case 0x7b, 0x5b: // object or array
                guard depth < limits.maximumNestingDepth else {
                    throw Self.limitError(name, "nesting depth")
                }
                depth += 1
                inScalar = false
            case 0x7d, 0x5d:
                depth = max(0, depth - 1)
                inScalar = false
                continue
            case 0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x3a:
                inScalar = false
                continue
            default:
                if inScalar { continue }
                inScalar = true
            }
            guard values < valueLimit else { throw Self.limitError(name, "aggregate model value") }
            values += 1
        }
    }

    private static func limitError(_ envelope: String, _ budget: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Analysis \(envelope) exceeds its \(budget) limit."))
    }

    // MARK: Request envelope

    private struct OverridePair: Codable {
        var address: UInt64
        var override: AddressOverride
    }

    private struct RequestEnvelope: Codable {
        var version: Int
        var path: String
        var requestedSliceIndex: Int?
        var elfArchiveMember: ELFArchiveMemberSelection?
        var coffSectionLayoutVersion: Int?
        // Optional: envelopes without it decode as the loader's default cache image.
        var dyldCacheImagePath: String?
        var overrides: [OverridePair]
        var requestID: UUID
        // Optional and synthesized with decodeIfPresent: version-2 envelopes without it stay valid.
        var resourceBudget: AnalysisResourceBudget?
        // HOP-3, optional: envelopes without it decode as unlimited.
        var analysisBudget: AnalysisBudgetWire?
    }

    func encodeRequest(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        requestID: UUID
    ) -> Data {
        encodeRequest(
            url: url,
            selection: .machOSlice(requestedSliceIndex),
            overrides: overrides,
            requestID: requestID
        )
    }

    func encodeRequest(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID
    ) -> Data {
        encodeRequest(url: url, selection: selection, overrides: overrides,
                      requestID: requestID, resourceBudget: nil)
    }

    func encodeRequest(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID,
        resourceBudget: AnalysisResourceBudget?
    ) -> Data {
        encodeRequest(url: url, selection: selection, overrides: overrides, requestID: requestID,
                      resourceBudget: resourceBudget, analysisBudget: nil)
    }

    func encodeRequest(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        requestID: UUID,
        resourceBudget: AnalysisResourceBudget?,
        analysisBudget: AnalysisBudget?
    ) -> Data {
        guard selection.isWellFormed else { return Data() }
        let envelope = RequestEnvelope(
            version: Self.wireVersion,
            path: url.path,
            requestedSliceIndex: selection.requestedMachOSliceIndex,
            elfArchiveMember: selection.elfArchiveMember,
            coffSectionLayoutVersion: selection.coffSectionLayoutVersion,
            dyldCacheImagePath: selection.dyldCacheImagePath,
            // Sorted for deterministic bytes, same discipline as the payload's UInt64 maps.
            overrides: overrides.sorted { $0.key < $1.key }.map {
                OverridePair(address: $0.key, override: $0.value)
            },
            requestID: requestID,
            resourceBudget: resourceBudget,
            analysisBudget: analysisBudget.map(AnalysisBudgetWire.init)
        )
        // Encoding cannot fail for these Codable value types; the empty fallback would be
        // rejected by `decodeRequest` as malformed rather than silently analyzed.
        return (try? encoder.encode(envelope)) ?? Data()
    }

    func decodeRequest(_ data: Data) throws -> AnalysisRequest {
        try validateEnvelope(data, isRequest: true)
        let envelope = try decoder.decode(RequestEnvelope.self, from: data)
        guard envelope.version == Self.wireVersion else {
            throw AnalysisWorkerError.versionMismatch(expected: Self.wireVersion, got: envelope.version)
        }
        guard envelope.overrides.count <= limits.maximumOverrides else {
            throw Self.limitError("request", "override count")
        }
        let overrides = Dictionary(
            envelope.overrides.map { ($0.address, $0.override) },
            uniquingKeysWith: { first, _ in first }
        )
        let selection = try BinaryLoadSelection(
            validatingRequestedMachOSliceIndex: envelope.requestedSliceIndex,
            elfArchiveMember: envelope.elfArchiveMember,
            coffSectionLayoutVersion: envelope.coffSectionLayoutVersion,
            dyldCacheImagePath: envelope.dyldCacheImagePath
        )
        return AnalysisRequest(
            url: URL(fileURLWithPath: envelope.path),
            selection: selection,
            overrides: overrides,
            requestID: envelope.requestID,
            resourceBudget: envelope.resourceBudget,
            analysisBudget: envelope.analysisBudget?.budget
        )
    }

    // MARK: Reply envelope

    private enum FailureKind: Codable, Equatable {
        case cancelled
        case malformedRequest
        case analysisFailed(String)
        case unexpected(String)
        /// HOP-3: the analysis stopped at its time or memory budget (typed, not `.unexpected`).
        /// The worker is embedded in the app, so a client never meets a worker of another build.
        case budgetExceeded(AnalysisBudgetExceededWire)
    }

    private struct ReplyEnvelope: Codable {
        var version: Int
        var payload: AnalysisResultPayload?
        /// Version 3: set when `payload.imageBytes` were omitted because they are this range of the
        /// request's pinned source. Absent (nil) for the inline form.
        var imageBytesInPinnedSource: AnalysisPinnedImageByteRange?
        var failure: FailureKind?
    }

    func encodeReply(_ result: Result<WorkspaceSnapshot, Error>) -> Data {
        encodeReply(result, pinnedImageBytes: nil)
    }

    func encodeReply(
        _ result: Result<WorkspaceSnapshot, Error>,
        pinnedImageBytes: AnalysisPinnedImageByteRange?
    ) -> Data {
        let envelope: ReplyEnvelope
        switch result {
        case .success(let snapshot):
            var payload = AnalysisPayloadCodec.payload(from: snapshot)
            let range = pinnedImageBytes.flatMap { $0.byteCount == payload.imageBytes.count ? $0 : nil }
            if range != nil { payload.imageBytes = Data() }
            envelope = ReplyEnvelope(
                version: Self.wireVersion,
                payload: payload,
                imageBytesInPinnedSource: range,
                failure: nil
            )
        case .failure(let error):
            envelope = ReplyEnvelope(version: Self.wireVersion, payload: nil, failure: Self.failureKind(for: error))
        }
        // A worker must always return SOME reply. If the (impossible for our types) encode fails,
        // fall back to a minimal hand-built failure envelope the client can still decode.
        if let data = try? encoder.encode(envelope) { return data }
        return (try? encoder.encode(ReplyEnvelope(
            version: Self.wireVersion, payload: nil, failure: .unexpected("reply encoding failed")
        ))) ?? Data()
    }

    func decodeReply(_ data: Data) throws -> WorkspaceSnapshot {
        try decodeReply(data, pinnedSource: nil)
    }

    /// Throws `AnalysisPinnedImageBytesError` when the reply names a pinned range that cannot be
    /// read from `pinnedSource` or does not hash to the reply's SHA-256 (the provider surfaces that
    /// as `.malformedReply`).
    func decodeReply(_ data: Data, pinnedSource: FileHandle?) throws -> WorkspaceSnapshot {
        try validateEnvelope(data, isRequest: false)
        let envelope = try decoder.decode(ReplyEnvelope.self, from: data)
        guard envelope.version == Self.wireVersion else {
            throw AnalysisWorkerError.versionMismatch(expected: Self.wireVersion, got: envelope.version)
        }
        if var payload = envelope.payload {
            if let range = envelope.imageBytesInPinnedSource {
                guard range.byteCount >= 0, range.byteCount <= limits.maximumPinnedImageBytes else {
                    throw Self.limitError("reply", "pinned image byte")
                }
                guard payload.imageBytes.isEmpty else { throw AnalysisPinnedImageBytesError.inlineBytesPresent }
                guard let pinnedSource else { throw AnalysisPinnedImageBytesError.pinnedSourceMissing }
                payload.imageBytes = try AnalysisPinnedImageBytes.read(range, from: pinnedSource)
            }
            return AnalysisPayloadCodec.snapshot(from: payload)
        }
        switch envelope.failure {
        case .cancelled:
            throw AnalysisCancelled()
        case .malformedRequest:
            throw RemoteAnalysisFailure(message: "The analysis request was rejected as malformed.")
        case .analysisFailed(let message), .unexpected(let message):
            throw RemoteAnalysisFailure(message: message)
        case .budgetExceeded(let wire):
            throw wire.error ?? RemoteAnalysisFailure(message: "The analysis stopped at its budget.")
        case nil:
            // Neither a payload nor a failure — a structurally malformed reply.
            throw RemoteAnalysisFailure(message: "The analysis worker returned an empty reply.")
        }
    }

    private static func failureKind(for error: Error) -> FailureKind {
        switch error {
        case AnalysisWorkerServiceError.malformedRequest: return .malformedRequest
        case AnalysisWorkerServiceError.cancelled: return .cancelled
        case AnalysisWorkerServiceError.analysisFailed(let message): return .analysisFailed(message)
        case AnalysisWorkerServiceError.unexpectedFailure(let message): return .unexpected(message)
        case is AnalysisCancelled: return .cancelled
        case let exceeded as AnalysisBudgetExceeded: return .budgetExceeded(AnalysisBudgetExceededWire(exceeded))
        default: return .unexpected(error.localizedDescription)
        }
    }
}

// MARK: - PERF-C2 pinned image bytes

/// Where an analyze reply's image bytes sit in the pinned source the request already sent:
/// `byteCount` bytes from file offset `offset`, whose SHA-256 is `sha256` (lowercase hex).
struct AnalysisPinnedImageByteRange: Codable, Equatable, Sendable {
    var offset: UInt64
    var byteCount: Int
    var sha256: String
}

enum AnalysisPinnedImageBytesError: Error, Equatable, LocalizedError {
    /// The reply names a pinned range but the client has no pinned source for this request.
    case pinnedSourceMissing
    /// The reply both names a pinned range and carries inline bytes.
    case inlineBytesPresent
    /// The range is not a readable regular-file range of the pinned source.
    case unreadable
    /// The bytes read from the pinned source do not hash to the reply's SHA-256 (the source changed).
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .pinnedSourceMissing: "The analysis reply refers to a pinned source the request did not send."
        case .inlineBytesPresent: "The analysis reply carries image bytes and a pinned range."
        case .unreadable: "The image bytes could not be read from the pinned source."
        case .hashMismatch: "The pinned source changed during analysis (image bytes hash mismatch)."
        }
    }
}

/// PERF-C2 helpers. The worker locates the snapshot's image bytes in the pinned source and verifies
/// them byte for byte before naming the range; the client re-reads the range from its own handle
/// and checks the SHA-256. Both sides use `pread`, so the descriptor's shared file offset (the
/// worker's descriptor is a dup of the client's) is never moved.
enum AnalysisPinnedImageBytes {
    static let chunkSize = 1 << 20

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Worker half. Returns the verified range, or nil when the bytes are empty or are not found at
    /// any candidate offset: 0 (thin images), the selected ELF archive member's payload offset, and
    /// each fat Mach-O slice of matching size (requested slice first). Each candidate is compared
    /// chunk by chunk against `imageBytes`, stopping at the first difference.
    static func locate(
        _ imageBytes: Data,
        in source: FileHandle,
        selection: BinaryLoadSelection
    ) -> AnalysisPinnedImageByteRange? {
        guard !imageBytes.isEmpty, let fileSize = regularFileSize(source) else { return nil }
        let count = UInt64(imageBytes.count)
        var candidates: [UInt64] = []
        if let member = selection.elfArchiveMember, member.member.payloadOffset >= 0 {
            candidates.append(UInt64(member.member.payloadOffset))
        }
        candidates += fatSliceOffsets(source, byteCount: count, preferredIndex: selection.requestedMachOSliceIndex)
        candidates.append(0)
        var tried = Set<UInt64>()
        for offset in candidates where tried.insert(offset).inserted {
            guard offset <= fileSize, count <= fileSize - offset else { continue }
            if matches(imageBytes, source: source, offset: offset) {
                return AnalysisPinnedImageByteRange(
                    offset: offset, byteCount: imageBytes.count, sha256: sha256Hex(imageBytes)
                )
            }
        }
        return nil
    }

    /// Client half: reads exactly the range and verifies its SHA-256.
    static func read(_ range: AnalysisPinnedImageByteRange, from source: FileHandle) throws -> Data {
        guard range.byteCount >= 0,
              let fileSize = regularFileSize(source),
              range.offset <= fileSize,
              UInt64(range.byteCount) <= fileSize - range.offset,
              let bytes = pread(source.fileDescriptor, offset: range.offset, count: range.byteCount) else {
            throw AnalysisPinnedImageBytesError.unreadable
        }
        guard sha256Hex(bytes) == range.sha256 else { throw AnalysisPinnedImageBytesError.hashMismatch }
        return bytes
    }

    private static func regularFileSize(_ source: FileHandle) -> UInt64? {
        let descriptor = source.fileDescriptor
        var state = stat()
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard descriptor >= 0,
              Darwin.fstat(descriptor, &state) == 0,
              (state.st_mode & S_IFMT) == S_IFREG,
              flags >= 0,
              flags & O_ACCMODE != O_WRONLY,
              state.st_size >= 0 else { return nil }
        return UInt64(state.st_size)
    }

    private static func pread(_ descriptor: Int32, offset: UInt64, count: Int) -> Data? {
        guard offset <= UInt64(off_t.max) else { return nil }
        var data = Data(count: count)
        var failed = false
        data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                let read = Darwin.pread(descriptor, buffer.baseAddress! + done, count - done,
                                        off_t(offset) + off_t(done))
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { failed = true; return }
                done += read
            }
        }
        return failed ? nil : data
    }

    private static func matches(_ imageBytes: Data, source: FileHandle, offset: UInt64) -> Bool {
        var position = 0
        while position < imageBytes.count {
            let length = min(chunkSize, imageBytes.count - position)
            guard let chunk = pread(source.fileDescriptor, offset: offset + UInt64(position), count: length),
                  chunk == imageBytes[imageBytes.startIndex + position ..< imageBytes.startIndex + position + length]
            else { return false }
            position += length
        }
        return true
    }

    /// Offsets of fat Mach-O slices whose declared size equals `byteCount`, the preferred index
    /// first. Reads only the fat header and architecture table (at most 32 entries).
    private static func fatSliceOffsets(_ source: FileHandle, byteCount: UInt64, preferredIndex: Int?) -> [UInt64] {
        guard let header = pread(source.fileDescriptor, offset: 0, count: 8) else { return [] }
        func be32(_ data: Data, _ at: Int) -> UInt64 {
            data[data.startIndex + at ..< data.startIndex + at + 4].reduce(0) { $0 << 8 | UInt64($1) }
        }
        func be64(_ data: Data, _ at: Int) -> UInt64 { be32(data, at) << 32 | be32(data, at + 4) }
        let magic = be32(header, 0)
        let is64: Bool
        switch magic {
        case 0xCAFE_BABE: is64 = false
        case 0xCAFE_BABF: is64 = true
        default: return []
        }
        let archCount = Int(be32(header, 4))
        guard archCount > 0, archCount <= 32 else { return [] }
        let entrySize = is64 ? 32 : 20
        guard let table = pread(source.fileDescriptor, offset: 8, count: archCount * entrySize) else { return [] }
        var matching: [(index: Int, offset: UInt64)] = []
        for index in 0..<archCount {
            let base = index * entrySize
            let offset = is64 ? be64(table, base + 8) : be32(table, base + 8)
            let size = is64 ? be64(table, base + 16) : be32(table, base + 12)
            if size == byteCount { matching.append((index, offset)) }
        }
        return matching.sorted { lhs, _ in lhs.index == preferredIndex }.map(\.offset)
    }
}

// MARK: - HOP-3 budget and progress on the wire

/// `AnalysisBudget` on the wire, in milliseconds and bytes.
struct AnalysisBudgetWire: Codable, Equatable, Sendable {
    var wallClockMilliseconds: Int64?
    var physicalFootprintLimitBytes: UInt64?

    init(_ budget: AnalysisBudget) {
        wallClockMilliseconds = budget.wallClockLimit.map(Self.milliseconds)
        physicalFootprintLimitBytes = budget.physicalFootprintLimitBytes
    }

    var budget: AnalysisBudget {
        AnalysisBudget(wallClockLimit: wallClockMilliseconds.map { .milliseconds($0) },
                       physicalFootprintLimitBytes: physicalFootprintLimitBytes)
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}

/// `AnalysisBudgetExceeded` on the wire.
struct AnalysisBudgetExceededWire: Codable, Equatable, Sendable {
    var stoppedBefore: String
    var reason: String
    var limitMilliseconds: Int64?
    var elapsedMilliseconds: Int64?
    var limitBytes: UInt64?
    var footprintBytes: UInt64?

    init(_ exceeded: AnalysisBudgetExceeded) {
        stoppedBefore = exceeded.stoppedBefore.rawValue
        switch exceeded.reason {
        case let .wallClock(limit, elapsed):
            reason = "wallClock"
            limitMilliseconds = AnalysisBudgetWire.milliseconds(limit)
            elapsedMilliseconds = AnalysisBudgetWire.milliseconds(elapsed)
        case let .memory(limit, footprint):
            reason = "memory"
            limitBytes = limit
            footprintBytes = footprint
        }
    }

    /// The typed error, or nil when the reply names a phase or reason this build doesn't know.
    var error: AnalysisBudgetExceeded? {
        guard let phase = AnalysisPhase(rawValue: stoppedBefore) else { return nil }
        switch reason {
        case "wallClock":
            guard let limitMilliseconds, let elapsedMilliseconds else { return nil }
            return AnalysisBudgetExceeded(reason: .wallClock(limit: .milliseconds(limitMilliseconds),
                                                             elapsed: .milliseconds(elapsedMilliseconds)),
                                          stoppedBefore: phase)
        case "memory":
            guard let limitBytes, let footprintBytes else { return nil }
            return AnalysisBudgetExceeded(reason: .memory(limitBytes: limitBytes, footprintBytes: footprintBytes),
                                          stoppedBefore: phase)
        default:
            return nil
        }
    }
}

/// The reply to a `progress(requestID:)` poll. Versioned on its own; it echoes the request id.
/// `phase` nil means unknown: the request hasn't started, has finished, or isn't this worker's.
struct AnalysisProgressReply: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = AnalysisProgressReply.currentVersion
    var requestID: UUID
    var phase: String?
    var elapsedMilliseconds: Int64?

    init(requestID: UUID, progress: AnalysisProgress?) {
        self.requestID = requestID
        phase = progress?.phase.rawValue
        elapsedMilliseconds = progress.map { AnalysisBudgetWire.milliseconds($0.elapsed) }
    }

    /// The reported progress when this reply answers `requestID` in a known version.
    func progress(for requestID: UUID) -> AnalysisProgress? {
        guard version == Self.currentVersion, self.requestID == requestID,
              let phase = phase.flatMap(AnalysisPhase.init(rawValue:)), let elapsedMilliseconds else { return nil }
        return AnalysisProgress(phase: phase, elapsed: .milliseconds(elapsedMilliseconds))
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data) -> AnalysisProgressReply? {
        try? JSONDecoder().decode(AnalysisProgressReply.self, from: data)
    }
}
