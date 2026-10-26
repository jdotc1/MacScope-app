import Darwin
import Foundation

/// Caller-owned reopen context. Only loader inputs cross the worker boundary; persisted products
/// and authored overrides remain here for source compatibility, never in RequestEnvelope.
struct AnalysisRehydrateRequest {
    let imageBytes: Data
    let requestedSliceIndex: Int?
    let coffSectionLayoutVersion: Int?
    let persisted: ImageAnalysis
    let overrides: [UInt64: AddressOverride]
    let resourceBudget: AnalysisResourceBudget?
    let requestID: UUID

    init(imageBytes: Data, requestedSliceIndex: Int?, persisted: ImageAnalysis,
         overrides: [UInt64: AddressOverride], resourceBudget: AnalysisResourceBudget? = nil,
         requestID: UUID = UUID(), coffSectionLayoutVersion: Int? = nil) {
        self.imageBytes = imageBytes
        self.requestedSliceIndex = requestedSliceIndex
        self.coffSectionLayoutVersion = coffSectionLayoutVersion
        self.persisted = persisted
        self.overrides = overrides
        self.resourceBudget = resourceBudget
        self.requestID = requestID
    }
}

/// The worker cannot access persisted rows, CFG, xrefs or authored overrides through this type.
struct AnalysisRehydrateLoaderRequest {
    let imageBytes: Data
    let requestedSliceIndex: Int?
    let coffSectionLayoutVersion: Int?
    let requestID: UUID
    let resourceBudget: AnalysisResourceBudget?
}

/// PERF-C: a rehydrate transfer refused because one of its byte quantities exceeds the product cap.
/// Raised before the oversize quantity is encoded or parsed (sender preflight, receiver encoded-size
/// check, descriptor size check), and carried back from the worker as a typed reply.
struct AnalysisTransferLimitExceeded: Error, Equatable, Sendable, LocalizedError {
    enum Field: String, Codable, Equatable, Sendable {
        case imageBytes
        case requestEnvelope
        case replyEnvelope
    }

    let field: Field
    let byteCount: Int
    let limit: Int

    var errorDescription: String? {
        "The \(field.rawValue) transfer is \(byteCount) bytes, over the \(limit)-byte limit."
    }
}

/// PERF-C byte caps for one rehydrate transfer. These are explicit product limits, not process
/// allocation bounds: image bytes up to 384 MiB, each JSON envelope (request or reply) up to 512 MiB.
struct AnalysisRehydrateTransferLimits: Equatable, Sendable {
    var maximumImageBytes: Int
    var maximumEnvelopeBytes: Int

    static let standard = AnalysisRehydrateTransferLimits(
        maximumImageBytes: 384 << 20,
        maximumEnvelopeBytes: 512 << 20
    )
}

/// Version 5 carries saved COFF layout policy and is coordinated across app and worker. No v3 retry can resend persisted products.
/// The worker returns only admitted loader evidence; both local and remote callers use the same
/// Foundation-only postprocessor over the caller's unchanged persisted analysis and captured bytes.
struct AnalysisRehydrateWireCodec: Sendable {
    static let wireVersion = 5
    let limits: AnalysisRehydrateTransferLimits

    init(limits: AnalysisRehydrateTransferLimits = .standard) { self.limits = limits }

    private struct VersionEnvelope: Decodable { var version: Int }

    private struct RequestEnvelope: Codable {
        var version: Int
        var requestID: UUID
        var imageBytes: Data
        var imageByteCount: Int
        var imageBytesOnDescriptor: Bool
        var requestedSliceIndex: Int?
        var coffSectionLayoutVersion: Int?
        var resourceBudget: AnalysisResourceBudget?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case version, requestID, imageBytes, imageByteCount, imageBytesOnDescriptor
            case requestedSliceIndex, resourceBudget, coffSectionLayoutVersion
        }
        init(version: Int, requestID: UUID, imageBytes: Data, imageByteCount: Int,
             imageBytesOnDescriptor: Bool, requestedSliceIndex: Int?, coffSectionLayoutVersion: Int?, resourceBudget: AnalysisResourceBudget?) {
            self.version = version
            self.requestID = requestID
            self.imageBytes = imageBytes
            self.imageByteCount = imageByteCount
            self.imageBytesOnDescriptor = imageBytesOnDescriptor
            self.requestedSliceIndex = requestedSliceIndex
            self.coffSectionLayoutVersion = coffSectionLayoutVersion
            self.resourceBudget = resourceBudget
        }
        init(from decoder: Decoder) throws {
            try AnalysisRehydrateWireCodec.rejectUnknownFields(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            requestID = try c.decode(UUID.self, forKey: .requestID)
            imageBytes = try c.decode(Data.self, forKey: .imageBytes)
            imageByteCount = try c.decode(Int.self, forKey: .imageByteCount)
            imageBytesOnDescriptor = try c.decode(Bool.self, forKey: .imageBytesOnDescriptor)
            requestedSliceIndex = try c.decodeIfPresent(Int.self, forKey: .requestedSliceIndex)
            coffSectionLayoutVersion = try c.decodeIfPresent(Int.self, forKey: .coffSectionLayoutVersion)
            resourceBudget = try c.decodeIfPresent(AnalysisResourceBudget.self, forKey: .resourceBudget)
        }
    }

    private enum FailureKind: Codable, Equatable {
        case cancelled
        case malformedRequest
        case loadFailed(String)
        case unexpected(String)
        case transferLimitExceeded(field: AnalysisTransferLimitExceeded.Field, byteCount: Int, limit: Int)
    }

    private struct ReplyEnvelope: Codable {
        var version: Int
        var loader: LoaderWire?
        var failure: FailureKind?

        private enum CodingKeys: String, CodingKey, CaseIterable { case version, loader, failure }
        init(version: Int, loader: LoaderWire?, failure: FailureKind?) {
            self.version = version
            self.loader = loader
            self.failure = failure
        }
        init(from decoder: Decoder) throws {
            try AnalysisRehydrateWireCodec.rejectUnknownFields(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            loader = try c.decodeIfPresent(LoaderWire.self, forKey: .loader)
            failure = try c.decodeIfPresent(FailureKind.self, forKey: .failure)
            guard (loader == nil) != (failure == nil) else {
                throw AnalysisWorkerError.malformedReply(reason: "rehydrate reply must contain exactly one outcome")
            }
        }
    }

    /// Explicit compact DTO. The metadata carrier reuses the established projections only for
    /// ObjC/Swift/Mach-O metadata, not byte authority, diagnostics or any caller-owned products.
    private struct LoaderWire: Codable {
        var requestID: UUID
        var requestedSliceIndex: Int?
        var imageByteCount: Int
        var sliceOffset: UInt64
        var sliceSize: UInt64?
        var sections: [SectionSummary]
        var mappings: [FileAddressMapping]
        var preferredSegmentLayout: MachOPreferredSegmentLayout?
        var codeDataRanges: [CodeDataRangeSummary]
        var relocations: [RelocationSummary]
        var identityEffectiveByteRanges: [AttestationWire]
        var metadata: AnalysisResultPayload?
        var constantCFStrings: [ImageConstantStringProvider.PersistedCFString]
        var loaderTruncations: [TruncationWire]
        var parserDisagreements: [DisagreementWire]
        var parserCrossCheckSkip: SkipWire?
        var loaderFindings: [FindingWire]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case requestID, requestedSliceIndex, imageByteCount, sliceOffset
            case sliceSize, sections, mappings, preferredSegmentLayout
            case codeDataRanges, relocations, identityEffectiveByteRanges, metadata
            case constantCFStrings, loaderTruncations, parserDisagreements, parserCrossCheckSkip
            case loaderFindings
        }
        init(from decoder: Decoder) throws {
            try AnalysisRehydrateWireCodec.rejectUnknownFields(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try c.decode(UUID.self, forKey: .requestID)
            requestedSliceIndex = try c.decodeIfPresent(Int.self, forKey: .requestedSliceIndex)
            imageByteCount = try c.decode(Int.self, forKey: .imageByteCount)
            sliceOffset = try c.decode(UInt64.self, forKey: .sliceOffset)
            sliceSize = try c.decodeIfPresent(UInt64.self, forKey: .sliceSize)
            sections = try c.decode([SectionSummary].self, forKey: .sections)
            mappings = try c.decode([FileAddressMapping].self, forKey: .mappings)
            preferredSegmentLayout = try c.decodeIfPresent(MachOPreferredSegmentLayout.self, forKey: .preferredSegmentLayout)
            codeDataRanges = try c.decode([CodeDataRangeSummary].self, forKey: .codeDataRanges)
            relocations = try c.decode([RelocationSummary].self, forKey: .relocations)
            identityEffectiveByteRanges = try c.decode([AttestationWire].self, forKey: .identityEffectiveByteRanges)
            // v4 metadata must not carry diagnostics, including records the general
            // payload decoder would silently discard as an unknown future kind.
            _ = try c.decodeIfPresent(MetadataAdmission.self, forKey: .metadata)
            metadata = try c.decodeIfPresent(AnalysisResultPayload.self, forKey: .metadata)
            constantCFStrings = try c.decode([ImageConstantStringProvider.PersistedCFString].self, forKey: .constantCFStrings)
            loaderTruncations = try c.decode([TruncationWire].self, forKey: .loaderTruncations)
            parserDisagreements = try c.decode([DisagreementWire].self, forKey: .parserDisagreements)
            parserCrossCheckSkip = try c.decodeIfPresent(SkipWire.self, forKey: .parserCrossCheckSkip)
            loaderFindings = try c.decode([FindingWire].self, forKey: .loaderFindings)
        }

        init(_ products: RehydrationLoaderProducts) throws {
            try products.validate(imageByteCount: products.imageByteCount)
            requestID = products.requestID
            requestedSliceIndex = products.requestedSliceIndex
            imageByteCount = products.imageByteCount
            sliceOffset = products.sliceOffset
            sliceSize = products.sliceSize
            sections = products.sections
            mappings = products.mappings
            preferredSegmentLayout = products.preferredSegmentLayout
            codeDataRanges = products.codeDataRanges
            relocations = products.relocations
            identityEffectiveByteRanges = products.identityEffectiveByteRanges.map(AttestationWire.init)
            metadata = AnalysisRehydrateWireCodec.metadataPayload(for: products)
            constantCFStrings = try ImageConstantStringProvider.validated(products.constantCFStrings.map {
                .init(address: $0.key, text: $0.value)
            })
            loaderTruncations = products.loaderTruncations.map { TruncationWire(address: $0.address) }
            parserDisagreements = products.parserDisagreements.map(DisagreementWire.init)
            parserCrossCheckSkip = products.parserCrossCheckSkip.map(SkipWire.init)
            loaderFindings = products.loaderFindings.map(FindingWire.init)
        }

        func products() throws -> RehydrationLoaderProducts {
            // Bounds and authoritative fields are admitted BEFORE projecting metadata.
            var result = RehydrationLoaderProducts(requestID: requestID,
                requestedSliceIndex: requestedSliceIndex, imageByteCount: imageByteCount,
                sliceOffset: sliceOffset, sliceSize: sliceSize, sections: sections, mappings: mappings,
                preferredSegmentLayout: preferredSegmentLayout, codeDataRanges: codeDataRanges,
                relocations: relocations)
            try result.validate(imageByteCount: imageByteCount)
            let count = RehydrationLoaderProducts.maximumRecordCount
            guard identityEffectiveByteRanges.count <= count, loaderTruncations.count <= count,
                  loaderFindings.count <= count,
                  parserDisagreements.count <= ParserCrossCheckComparator.maximumDisagreements,
                  Set(parserDisagreements.map(\.address)).count == parserDisagreements.count,
                  parserCrossCheckSkip == nil || parserDisagreements.isEmpty else {
                throw AnalysisWorkerError.malformedReply(reason: "invalid loader evidence counts or outcomes")
            }
            let payloadLength = sliceSize ?? UInt64(imageByteCount) - sliceOffset
            result.identityEffectiveByteRanges = try identityEffectiveByteRanges.map {
                try $0.value(selectedSliceByteCount: payloadLength)
            }
            result.constantCFStrings = Dictionary(uniqueKeysWithValues:
                try ImageConstantStringProvider.validated(constantCFStrings).map { ($0.address, $0.text) })
            result.loaderTruncations = loaderTruncations.map { .init(address: $0.address, message: "") }
            result.parserDisagreements = try parserDisagreements.map { try $0.value() }
            result.parserCrossCheckSkip = try parserCrossCheckSkip?.value(selectedSliceByteCount: payloadLength)
            result.loaderFindings = try loaderFindings.map { try $0.value() }
            let projected = try AnalysisRehydrateWireCodec.metadataAnalysis(from: metadata)
            result.machOMetadata = projected.machOMetadata
            result.objcClasses = projected.objcClasses
            result.objcCategories = projected.objcCategories
            result.objcProtocols = projected.objcProtocols
            result.swiftTypes = projected.swiftTypes
            result.swiftConformances = projected.swiftConformances
            result.objcSelectors = projected.objcSelectors
            result.objcClassReferences = projected.objcClassReferences
            try result.validate(imageByteCount: imageByteCount)
            return result
        }
    }

    /// Inspect the raw field before AnalysisResultPayload's deliberate lossy diagnostic
    /// decoding can erase forbidden evidence. The shared analyze codec stays unchanged.
    private struct MetadataAdmission: Decodable {
        private enum CodingKeys: String, CodingKey { case diagnostics }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let diagnostics = try fields.nestedUnkeyedContainer(forKey: .diagnostics)
            guard diagnostics.isAtEnd else {
                throw AnalysisWorkerError.malformedReply(reason: "loader metadata contains diagnostic records")
            }
        }
    }

    private struct TruncationWire: Codable { var address: UInt64 }

    private struct DisagreementWire: Codable {
        var address: UInt64
        var engines: [ParserEngineID]
        var facts: [ParserCrossCheckDisagreement.Fact]
        init(_ value: ParserCrossCheckDisagreement) {
            address = value.address
            engines = value.engines.sorted()
            facts = value.facts.sorted()
        }
        func value() throws -> ParserCrossCheckDisagreement {
            guard !engines.isEmpty, !facts.isEmpty,
                  engines.count <= ParserEngineID.allCases.count,
                  facts.count <= ParserCrossCheckDisagreement.Fact.allCases.count,
                  Set(engines).count == engines.count, Set(facts).count == facts.count else {
                throw AnalysisWorkerError.malformedReply(reason: "invalid parser disagreement")
            }
            return .init(address: address, engines: Set(engines), facts: Set(facts))
        }
    }

    private struct SkipWire: Codable {
        var address: UInt64
        var reason: String
        var byteCount: Int
        var limit: Int
        init(_ value: ParserCrossCheckSkip) {
            address = value.address
            switch value.reason {
            case let .size(byteCount, limit):
                reason = "size"
                self.byteCount = byteCount
                self.limit = limit
            }
        }
        func value(selectedSliceByteCount: UInt64) throws -> ParserCrossCheckSkip {
            guard reason == "size", limit >= 0, byteCount > limit,
                  byteCount <= Int.max - 1_048_575, UInt64(byteCount) == selectedSliceByteCount else {
                throw AnalysisWorkerError.malformedReply(reason: "invalid parser cross-check skip")
            }
            return .init(address: address, reason: .size(byteCount: byteCount, limit: limit))
        }
    }

    private struct FindingWire: Codable {
        var category: String
        var code: String
        var address: UInt64
        var message: String
        init(_ value: LoaderFinding) {
            category = value.category.rawValue
            code = value.code
            address = value.address
            message = value.message
        }
        func value() throws -> LoaderFinding {
            guard let category = LoaderFinding.Category(rawValue: category) else {
                throw AnalysisWorkerError.malformedReply(reason: "unknown loader finding category")
            }
            return .init(category: category, code: code, address: address, message: message)
        }
    }

    private struct AttestationWire: Codable {
        var artifactIdentity: MachOSliceArtifactIdentity
        var segmentName: String
        var startAddress: UInt64
        var endAddressExclusive: UInt64
        var sliceRelativeFileOffset: UInt64
        var byteCount: UInt64
        var initialProtections: Int32
        var rawBytesSHA256: String
        init(_ value: IdentityEffectiveByteRangeAttestation) {
            artifactIdentity = value.artifactIdentity
            segmentName = value.segmentName
            startAddress = value.startAddress
            endAddressExclusive = value.endAddressExclusive
            sliceRelativeFileOffset = value.sliceRelativeFileOffset
            byteCount = value.byteCount
            initialProtections = value.initialProtections
            rawBytesSHA256 = value.rawBytesSHA256
        }
        func value(selectedSliceByteCount: UInt64) throws -> IdentityEffectiveByteRangeAttestation {
            guard artifactIdentity.selectedSliceByteCount == selectedSliceByteCount else {
                throw AnalysisWorkerError.malformedReply(reason: "attestation belongs to a different slice")
            }
            return try .init(artifactIdentity: artifactIdentity, segmentName: segmentName,
                startAddress: startAddress, endAddressExclusive: endAddressExclusive,
                sliceRelativeFileOffset: sliceRelativeFileOffset, byteCount: byteCount,
                initialProtections: initialProtections, rawBytesSHA256: rawBytesSHA256)
        }
    }

    // MARK: Client half

    func encodeRequest(_ request: AnalysisRehydrateRequest, imageBytesOnDescriptor: Bool = false) throws -> Data {
        try preflight(imageByteCount: request.imageBytes.count)
        guard request.requestedSliceIndex.map({ $0 >= 0 }) ?? true,
              request.coffSectionLayoutVersion == nil || request.coffSectionLayoutVersion == 0 || request.coffSectionLayoutVersion == 1 else {
            throw AnalysisWorkerServiceError.malformedRequest
        }
        let envelope = RequestEnvelope(version: Self.wireVersion, requestID: request.requestID,
            imageBytes: imageBytesOnDescriptor ? Data() : request.imageBytes,
            imageByteCount: request.imageBytes.count, imageBytesOnDescriptor: imageBytesOnDescriptor,
            requestedSliceIndex: request.requestedSliceIndex, coffSectionLayoutVersion: request.coffSectionLayoutVersion,
            resourceBudget: request.resourceBudget)
        let data = try JSONEncoder().encode(envelope)
        try checkEnvelopeSize(data, field: .requestEnvelope)
        return data
    }

    func preflight(imageByteCount: Int) throws {
        guard imageByteCount >= 0 else { throw AnalysisWorkerServiceError.malformedRequest }
        guard imageByteCount <= limits.maximumImageBytes else {
            throw AnalysisTransferLimitExceeded(field: .imageBytes, byteCount: imageByteCount,
                                                limit: limits.maximumImageBytes)
        }
    }

    func decodeLoaderReply(_ data: Data, requestID: UUID, requestImageByteCount: Int,
                           requestedSliceIndex: Int?) throws -> RehydrationLoaderProducts {
        let envelope = try decodeReplyEnvelope(data)
        if let failure = envelope.failure { try Self.throwFailure(failure) }
        guard let wire = envelope.loader else {
            throw AnalysisWorkerError.malformedReply(reason: "missing loader products")
        }
        try preflight(imageByteCount: wire.imageByteCount)
        // Check the owner before doing metadata reconstruction or accepting byte authority.
        guard wire.requestID == requestID, wire.imageByteCount == requestImageByteCount,
              wire.requestedSliceIndex == requestedSliceIndex else {
            throw AnalysisWorkerError.malformedReply(reason: "loader products do not belong to this request")
        }
        let products = try wire.products()
        try products.validate(imageByteCount: requestImageByteCount,
                              requestedSliceIndex: requestedSliceIndex, requestID: requestID)
        return products
    }

    // MARK: Worker half

    func decodeRequest(_ data: Data, imageSource: FileHandle? = nil) throws -> AnalysisRehydrateLoaderRequest {
        try checkEnvelopeSize(data, field: .requestEnvelope)
        try checkVersion(data)
        let envelope = try JSONDecoder().decode(RequestEnvelope.self, from: data)
        guard envelope.requestedSliceIndex.map({ $0 >= 0 }) ?? true,
              envelope.coffSectionLayoutVersion == nil || envelope.coffSectionLayoutVersion == 0 || envelope.coffSectionLayoutVersion == 1 else {
            throw AnalysisWorkerServiceError.malformedRequest
        }
        try preflight(imageByteCount: envelope.imageByteCount)
        let imageBytes: Data
        if envelope.imageBytesOnDescriptor {
            guard let imageSource, envelope.imageBytes.isEmpty else {
                throw AnalysisWorkerServiceError.malformedRequest
            }
            imageBytes = try AnalysisSealedByteDescriptor.read(imageSource, expectedCount: envelope.imageByteCount)
        } else {
            guard imageSource == nil, envelope.imageBytes.count == envelope.imageByteCount else {
                throw AnalysisWorkerServiceError.malformedRequest
            }
            imageBytes = envelope.imageBytes
        }
        return .init(imageBytes: imageBytes, requestedSliceIndex: envelope.requestedSliceIndex,
                     coffSectionLayoutVersion: envelope.coffSectionLayoutVersion, requestID: envelope.requestID, resourceBudget: envelope.resourceBudget)
    }

    /// An unencodable, contradictory or oversize success becomes a typed failure, never a v3 reply.
    func encodeLoaderReply(_ result: Result<RehydrationLoaderProducts, Error>) -> Data {
        let envelope: ReplyEnvelope
        switch result {
        case .success(let products):
            do {
                try preflight(imageByteCount: products.imageByteCount)
                let wire = try LoaderWire(products)
                // The same structural admission is enforced on both sides of the wire.
                _ = try wire.products()
                envelope = .init(version: Self.wireVersion, loader: wire, failure: nil)
            } catch { return encodeFailure(Self.failureKind(for: error)) }
        case .failure(let error):
            return encodeFailure(Self.failureKind(for: error))
        }
        if let data = try? JSONEncoder().encode(envelope) {
            if data.count <= limits.maximumEnvelopeBytes { return data }
            return encodeFailure(.transferLimitExceeded(field: .replyEnvelope, byteCount: data.count,
                                                       limit: limits.maximumEnvelopeBytes))
        }
        return encodeFailure(.unexpected("rehydrate loader reply encoding failed"))
    }

    // These old internal test seams remain source-compatible, but cannot accept unbound successes.
    // Their v3 semantics are intentionally not supported; the local owner must migrate old selectors.
    @available(*, deprecated, message: "Wire v4 requires encodeLoaderReply and admitted loader products")
    func encodeReply(_ result: Result<ImageAnalysis, Error>, requestImageBytes: Data? = nil,
                     requestPersisted: ImageAnalysis? = nil) -> Data {
        switch result {
        case .failure(let error): return encodeFailure(Self.failureKind(for: error))
        case .success: return encodeFailure(.unexpected("wire v4 refuses a legacy ImageAnalysis reply"))
        }
    }

    @available(*, deprecated, message: "Wire v4 requires decodeLoaderReply with request binding and caller rebuild")
    func decodeReply(_ data: Data, requestImageBytes: Data,
                     requestPersisted: ImageAnalysis? = nil) throws -> ImageAnalysis {
        let envelope = try decodeReplyEnvelope(data)
        if let failure = envelope.failure { try Self.throwFailure(failure) }
        throw AnalysisWorkerError.malformedReply(reason: "wire v4 success requires the original request UUID and slice")
    }

    private func checkEnvelopeSize(_ data: Data, field: AnalysisTransferLimitExceeded.Field) throws {
        guard data.count <= limits.maximumEnvelopeBytes else {
            throw AnalysisTransferLimitExceeded(field: field, byteCount: data.count, limit: limits.maximumEnvelopeBytes)
        }
    }

    private func checkVersion(_ data: Data) throws {
        let header = try JSONDecoder().decode(VersionEnvelope.self, from: data)
        guard header.version == Self.wireVersion else {
            throw AnalysisWorkerError.versionMismatch(expected: Self.wireVersion, got: header.version)
        }
    }

    private func decodeReplyEnvelope(_ data: Data) throws -> ReplyEnvelope {
        try checkEnvelopeSize(data, field: .replyEnvelope)
        try checkVersion(data)
        return try JSONDecoder().decode(ReplyEnvelope.self, from: data)
    }

    private func encodeFailure(_ failure: FailureKind) -> Data {
        (try? JSONEncoder().encode(ReplyEnvelope(version: Self.wireVersion, loader: nil, failure: failure))) ?? Data()
    }

    private static func throwFailure(_ failure: FailureKind) throws -> Never {
        switch failure {
        case .cancelled: throw AnalysisCancelled()
        case .malformedRequest:
            throw RemoteAnalysisFailure(message: "The rehydrate request was rejected as malformed.")
        case .loadFailed(let message), .unexpected(let message): throw RemoteAnalysisFailure(message: message)
        case .transferLimitExceeded(let field, let byteCount, let limit):
            guard byteCount >= 0, limit >= 0, byteCount > limit else {
                throw AnalysisWorkerError.malformedReply(reason: "contradictory transfer-limit failure")
            }
            throw AnalysisTransferLimitExceeded(field: field, byteCount: byteCount, limit: limit)
        }
    }

    private static func failureKind(for error: Error) -> FailureKind {
        switch error {
        case AnalysisWorkerServiceError.malformedRequest: return .malformedRequest
        case AnalysisWorkerServiceError.cancelled: return .cancelled
        case AnalysisWorkerServiceError.analysisFailed(let message): return .loadFailed(message)
        case AnalysisWorkerServiceError.unexpectedFailure(let message): return .unexpected(message)
        case let limit as AnalysisTransferLimitExceeded:
            return .transferLimitExceeded(field: limit.field, byteCount: limit.byteCount, limit: limit.limit)
        case is AnalysisCancelled: return .cancelled
        default: return .unexpected(error.localizedDescription)
        }
    }

    private static func metadataPayload(for loader: RehydrationLoaderProducts) -> AnalysisResultPayload? {
        guard loader.machOMetadata != nil || !loader.objcClasses.isEmpty || !loader.objcCategories.isEmpty
            || !loader.objcProtocols.isEmpty || !loader.swiftTypes.isEmpty || !loader.swiftConformances.isEmpty
            || !loader.objcSelectors.isEmpty || !loader.objcClassReferences.isEmpty else { return nil }
        var metadata = ImageAnalysis()
        metadata.machOMetadata = loader.machOMetadata
        metadata.objcClasses = loader.objcClasses
        metadata.objcCategories = loader.objcCategories
        metadata.objcProtocols = loader.objcProtocols
        metadata.swiftTypes = loader.swiftTypes
        metadata.swiftConformances = loader.swiftConformances
        metadata.objcSelectors = loader.objcSelectors
        metadata.objcClassReferences = loader.objcClassReferences
        return AnalysisPayloadCodec.payload(from: WorkspaceSnapshot(binaries: [], analysisBySlot: [.primary: metadata]))
    }

    private static func metadataAnalysis(from payload: AnalysisResultPayload?) throws -> ImageAnalysis {
        guard let payload else { return ImageAnalysis() }
        guard payload.binaries.isEmpty else { throw AnalysisWorkerServiceError.malformedRequest }
        let snapshot = AnalysisPayloadCodec.snapshot(from: payload)
        guard snapshot.analysisBySlot.count == 1, snapshot.crossImageXrefs.isEmpty,
              let value = snapshot.analysis(in: .primary),
              value.functions.isEmpty, value.symbols.isEmpty, value.imports.isEmpty,
              value.indirectSymbols.isEmpty, value.exports.isEmpty, value.stringLiterals.isEmpty,
              value.basicBlocks.isEmpty, value.instructions.isEmpty, value.xrefs.isEmpty,
              value.controlFlowEdges.isEmpty, value.hexBytes.isEmpty, value.sourceLines.isEmpty,
              value.imageBytes.isEmpty, value.sections.isEmpty, value.codeDataRanges.isEmpty,
              value.relocations.isEmpty, value.identityEffectiveByteRanges.isEmpty,
              value.jumpTables.isEmpty, value.diagnostics.isEmpty, value.constantStrings.isEmpty,
              value.analysisInputFingerprint == nil else {
            throw AnalysisWorkerError.malformedReply(reason: "loader metadata contains caller-owned or contradictory products")
        }
        return value
    }

    private struct WireKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func rejectUnknownFields(in decoder: Decoder, allowed: [String]) throws {
        let keys = try decoder.container(keyedBy: WireKey.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: Set(allowed)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unexpected fields in coordinated rehydrate protocol"))
        }
    }
}

/// PERF-C: raw image bytes on the analysis channel's pinned-descriptor path, instead of base64
/// inside a JSON envelope.
///
/// The client writes the bytes to a private file, opens a read-only descriptor, unlinks the name
/// and closes the write descriptor before sending. Nothing can reopen or modify the file after
/// that, so the descriptor is sealed: the worker reads exactly the bytes the client wrote. The
/// worker validates it like `analyzePinned` (regular file, readable) plus an exact size match.
enum AnalysisSealedByteDescriptor {
    /// Client half. Throws `POSIXError` when the private file cannot be made; the caller may fall
    /// back to the inline form.
    static func make(_ bytes: Data, directory: URL = FileManager.default.temporaryDirectory) throws -> FileHandle {
        let path = directory.appendingPathComponent("macscope-rehydrate-transfer-\(UUID().uuidString)").path
        let writeFD = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard writeFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let readFD = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let openErrno = errno
        Darwin.unlink(path)
        guard readFD >= 0 else {
            Darwin.close(writeFD)
            throw POSIXError(POSIXErrorCode(rawValue: openErrno) ?? .EIO)
        }
        var failure: Int32 = 0
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(writeFD, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        Darwin.close(writeFD)
        guard failure == 0 else {
            Darwin.close(readFD)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        return FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
    }

    /// Worker half. Reads exactly `expectedCount` bytes from offset 0 with `pread` (the descriptor's
    /// shared file offset is never used). Any validation or short-read failure is malformed.
    static func read(_ source: FileHandle, expectedCount: Int) throws -> Data {
        let descriptor = source.fileDescriptor
        var state = stat()
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard descriptor >= 0,
              Darwin.fstat(descriptor, &state) == 0,
              (state.st_mode & S_IFMT) == S_IFREG,
              flags >= 0,
              flags & O_ACCMODE != O_WRONLY,
              state.st_size == off_t(expectedCount) else {
            throw AnalysisWorkerServiceError.malformedRequest
        }
        var data = Data(count: expectedCount)
        var shortRead = false
        data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.pread(descriptor, buffer.baseAddress! + offset,
                                         buffer.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { shortRead = true; return }
                offset += count
            }
        }
        guard !shortRead else { throw AnalysisWorkerServiceError.malformedRequest }
        return data
    }
}
