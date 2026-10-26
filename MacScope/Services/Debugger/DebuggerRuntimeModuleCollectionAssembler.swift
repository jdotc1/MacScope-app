import CryptoKit
import Foundation

struct DebuggerRuntimeModuleDecodedCollection: Sendable {
    let token: Data
    let digest: Data
    let observedProcessID: Int32
    let observedStopID: UInt32
    let modules: [DebuggerRuntimeModuleObservation]
    let canonicalSnapshotByteCount: Int
    let logicalDecodedRecordByteCount: Int
}

struct DebuggerRuntimeModuleCollectionAssembler: Sendable {
    static let maximumPageCount = 64
    static let maximumMappedRangeCount = 32_768
    static let maximumCanonicalSnapshotBytes = 8 * 1_024 * 1_024
    static let maximumLogicalDecodedRecordBytes = 8 * 1_024 * 1_024
    static let maximumCollectionDurationNanoseconds: UInt64 = 9_000_000_000

    private let expectedToken: Data
    private let expectedProcessID: Int32
    private let startedAtUptimeNanoseconds: UInt64
    private var expectedDigest: Data?
    private var expectedObservedStopID: UInt32?
    private var expectedModuleCount: UInt32?
    private var nextOrdinal: UInt32 = 0
    private var pageCount = 0
    private var decodedModules: [LLDBRuntimeModuleDecodedRecord] = []
    private var logicalByteCount = 81
    private var mappedRangeCount = 0
    private var isComplete = false

    init(
        expectedToken: Data,
        expectedProcessID: Int32,
        startedAtUptimeNanoseconds: UInt64
    ) throws {
        guard expectedToken.count == 32, expectedProcessID > 0 else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidSchema, expectedToken)
        }
        self.expectedToken = expectedToken
        self.expectedProcessID = expectedProcessID
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
    }

    mutating func append(
        _ page: LLDBRuntimeModuleDecodedPage,
        nowUptimeNanoseconds: UInt64
    ) throws -> DebuggerRuntimeModuleDecodedCollection? {
        guard !isComplete else { throw makeLLDBRuntimeModuleInventoryFailure(.completedCollection, page.digest) }
        guard nowUptimeNanoseconds >= startedAtUptimeNanoseconds,
              nowUptimeNanoseconds - startedAtUptimeNanoseconds <= Self.maximumCollectionDurationNanoseconds else {
            throw makeLLDBRuntimeModuleInventoryFailure(.deadlineExceeded, page.digest)
        }
        try Self.validatePageCount(pageCount + 1, evidence: page.digest)
        guard page.token == expectedToken else { throw makeLLDBRuntimeModuleInventoryFailure(.tokenMismatch, page.token) }
        guard page.observedProcessID == expectedProcessID else {
            throw makeLLDBRuntimeModuleInventoryFailure(.processMismatch, page.digest)
        }
        guard page.start == nextOrdinal,
              page.start < page.end || (page.isFinal && page.moduleCount == 0),
              page.end <= page.moduleCount else {
            throw makeLLDBRuntimeModuleInventoryFailure(.intervalMismatch, page.digest)
        }
        if let expectedDigest {
            guard expectedDigest == page.digest,
                  expectedObservedStopID == page.observedStopID,
                  expectedModuleCount == page.moduleCount else {
                throw makeLLDBRuntimeModuleInventoryFailure(.collectionMismatch, page.digest)
            }
        } else {
            expectedDigest = page.digest
            expectedObservedStopID = page.observedStopID
            expectedModuleCount = page.moduleCount
        }

        var prospectiveLogicalBytes = logicalByteCount
        var prospectiveMappedRanges = mappedRangeCount
        for module in page.modules {
            prospectiveLogicalBytes = try checkedAdd(prospectiveLogicalBytes, 65, evidence: page.digest)
            if module.uuid != nil {
                prospectiveLogicalBytes = try checkedAdd(prospectiveLogicalBytes, 16, evidence: page.digest)
            }
            prospectiveLogicalBytes = try checkedAdd(
                prospectiveLogicalBytes,
                module.fullPath.utf8.count,
                evidence: page.digest
            )
            prospectiveLogicalBytes = try checkedAdd(
                prospectiveLogicalBytes,
                module.normalizedArchitectureTriple.utf8.count,
                evidence: page.digest
            )
            for section in module.sections {
                prospectiveLogicalBytes = try checkedAdd(prospectiveLogicalBytes, 27, evidence: page.digest)
                if let name = section.name {
                    prospectiveLogicalBytes = try checkedAdd(prospectiveLogicalBytes, 8, evidence: page.digest)
                    prospectiveLogicalBytes = try checkedAdd(
                        prospectiveLogicalBytes,
                        name.utf8.count,
                        evidence: page.digest
                    )
                }
                if section.runtimeStart != nil {
                    prospectiveLogicalBytes = try checkedAdd(prospectiveLogicalBytes, 8, evidence: page.digest)
                }
                if section.name != nil, section.runtimeStart != nil {
                    prospectiveMappedRanges = try checkedAdd(prospectiveMappedRanges, 1, evidence: page.digest)
                }
            }
        }
        try Self.validateDecodedCapacity(
            logicalDecodedRecordByteCount: prospectiveLogicalBytes,
            mappedRangeCount: prospectiveMappedRanges,
            evidence: page.digest
        )

        decodedModules.append(contentsOf: page.modules)
        logicalByteCount = prospectiveLogicalBytes
        mappedRangeCount = prospectiveMappedRanges
        nextOrdinal = page.end
        pageCount += 1
        guard page.isFinal else { return nil }
        guard page.end == page.moduleCount,
              decodedModules.count == Int(page.moduleCount) else {
            throw makeLLDBRuntimeModuleInventoryFailure(.intervalMismatch, page.digest)
        }

        let snapshot = Phase2ProductionJSONValue.array(decodedModules.map(\.canonicalRecord)).canonicalJSONBytes()
        try Self.validateCanonicalSnapshotCapacity(byteCount: snapshot.count, evidence: snapshot)
        let calculatedDigest = Data(SHA256.hash(data: snapshot))
        guard calculatedDigest == page.digest else { throw makeLLDBRuntimeModuleInventoryFailure(.digestMismatch, snapshot) }

        var seenFingerprints: Set<Data> = []
        var observations: [DebuggerRuntimeModuleObservation] = []
        observations.reserveCapacity(decodedModules.count)
        for module in decodedModules {
            guard seenFingerprints.insert(module.fingerprintSHA256).inserted else {
                throw makeLLDBRuntimeModuleInventoryFailure(.duplicateFingerprint, module.fingerprintSHA256)
            }
            var mappedRanges: [DebuggerRuntimeModuleMappedRangeObservation] = []
            mappedRanges.reserveCapacity(module.sections.count)
            for section in module.sections {
                guard let name = section.name, let runtimeStart = section.runtimeStart else { continue }
                guard let range = DebuggerRuntimeModuleMappedRangeObservation(
                    sectionOrdinal: section.ordinal,
                    sectionName: name,
                    staticStart: section.staticStart,
                    runtimeStart: runtimeStart,
                    byteCount: section.byteCount,
                    permissions: section.permissions
                ) else {
                    throw makeLLDBRuntimeModuleInventoryFailure(.invalidRange, module.fingerprintSHA256)
                }
                mappedRanges.append(range)
            }
            guard let observation = DebuggerRuntimeModuleObservation(
                uuid: module.uuid,
                processID: page.observedProcessID,
                observedStopID: page.observedStopID,
                mappedRanges: mappedRanges,
                fullPath: module.fullPath,
                normalizedArchitectureTriple: module.normalizedArchitectureTriple,
                displayIndex: module.ordinal,
                fingerprintSHA256: module.fingerprintSHA256
            ) else {
                throw makeLLDBRuntimeModuleInventoryFailure(.invalidSchema, module.fingerprintSHA256)
            }
            observations.append(observation)
        }
        isComplete = true
        return DebuggerRuntimeModuleDecodedCollection(
            token: page.token,
            digest: page.digest,
            observedProcessID: page.observedProcessID,
            observedStopID: page.observedStopID,
            modules: observations,
            canonicalSnapshotByteCount: snapshot.count,
            logicalDecodedRecordByteCount: logicalByteCount
        )
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int, evidence: Data) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw makeLLDBRuntimeModuleInventoryFailure(.capacityExceeded, evidence, originalCount: Int.max) }
        return result.partialValue
    }

    static func validatePageCount(_ prospectivePageCount: Int, evidence: Data) throws {
        guard (0...Self.maximumPageCount).contains(prospectivePageCount) else {
            throw makeLLDBRuntimeModuleInventoryFailure(.capacityExceeded, evidence)
        }
    }

    static func validateDecodedCapacity(
        logicalDecodedRecordByteCount: Int,
        mappedRangeCount: Int,
        evidence: Data
    ) throws {
        guard (0...Self.maximumLogicalDecodedRecordBytes).contains(logicalDecodedRecordByteCount),
              (0...Self.maximumMappedRangeCount).contains(mappedRangeCount) else {
            throw makeLLDBRuntimeModuleInventoryFailure(.capacityExceeded, evidence)
        }
    }

    static func validateCanonicalSnapshotCapacity(byteCount: Int, evidence: Data) throws {
        guard (0...Self.maximumCanonicalSnapshotBytes).contains(byteCount) else {
            throw makeLLDBRuntimeModuleInventoryFailure(.capacityExceeded, evidence)
        }
    }
}
