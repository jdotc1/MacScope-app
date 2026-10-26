import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
import Security
#endif

enum DebuggerLocalProcessResolution<Value: Sendable>: Sendable {
    case resolved(Value)
    case ineligible(DebuggerLocalAttachDenial)
    case unknown(DebuggerLocalAttachDenial)

    var denial: DebuggerLocalAttachDenial? {
        switch self {
        case .resolved: nil
        case let .ineligible(denial), let .unknown(denial): denial
        }
    }

    var isResolved: Bool {
        if case .resolved = self { return true }
        return false
    }
}

extension DebuggerLocalProcessResolution: Equatable where Value: Equatable {}

struct DebuggerLocalProcessObservationPolicy: Hashable, Sendable {
    let hostRealUserID: UInt32
    let hostEffectiveUserID: UInt32
    let selfProcessID: Int32
    let excludedInfrastructure: Set<DebuggerLocalProcessInstanceKey>
}

struct DebuggerLocalProcessDynamicState: Hashable, Sendable {
    let isSystem: Bool
    let isTraced: Bool
    let isExiting: Bool
    let isZombie: Bool
    let isTranslated: Bool
    let hasPrivilegedIdentityTransition: Bool
    let targetDisallowsDebugging: Bool
    let hasUnknownSecurityPolicy: Bool

    init(
        isSystem: Bool = false,
        isTraced: Bool = false,
        isExiting: Bool = false,
        isZombie: Bool = false,
        isTranslated: Bool = false,
        hasPrivilegedIdentityTransition: Bool = false,
        targetDisallowsDebugging: Bool = false,
        hasUnknownSecurityPolicy: Bool = false
    ) {
        self.isSystem = isSystem
        self.isTraced = isTraced
        self.isExiting = isExiting
        self.isZombie = isZombie
        self.isTranslated = isTranslated
        self.hasPrivilegedIdentityTransition = hasPrivilegedIdentityTransition
        self.targetDisallowsDebugging = targetDisallowsDebugging
        self.hasUnknownSecurityPolicy = hasUnknownSecurityPolicy
    }
}

struct DebuggerLocalProcessCatalogEvidence: Hashable, Sendable {
    let fingerprint: DebuggerLocalProcessCatalogFingerprint
    let displayName: String
    let parentProcessID: Int32
    let savedUserID: UInt32
    let dynamicState: DebuggerLocalProcessDynamicState
}

struct DebuggerLocalProcessAuthorizationEvidence: Hashable, Sendable {
    let catalogEvidence: DebuggerLocalProcessCatalogEvidence
    let identity: DebuggerLocalProcessIdentity

    var fingerprint: DebuggerLocalProcessCatalogFingerprint {
        catalogEvidence.fingerprint
    }
}

struct DebuggerLocalProcessCatalogObservation: Hashable, Sendable {
    let fingerprint: DebuggerLocalProcessCatalogFingerprint
    let displayName: String
    let parentProcessID: Int32
    let dynamicState: DebuggerLocalProcessDynamicState
    let eligibility: DebuggerLocalProcessEligibility
}

protocol DebuggerLocalProcessEvidenceProviding: Sendable {
    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]>

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence>

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>
}

/// Injectable immediate-preflight seam used after the fresh targetless helper has been exactly
/// registered and before any target attach command is authorized or written.
/// Success returns the newly observed complete identity, which must equal the immutable request.
protocol DebuggerLocalProcessIdentityRevalidating: Sendable {
    func revalidateAttachRequest(
        _ request: DebuggerLocalAttachRequest,
        policy: DebuggerLocalProcessObservationPolicy
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>
}

/// Post-retirement identity-only reobservation. This seam proves only whether one previously
/// accepted immutable local-process identity still exists; it grants no attach eligibility and
/// authorizes no PID action.
protocol DebuggerLocalProcessIdentityReobserving: Sendable {
    func reobserveIdentity(
        _ expected: DebuggerLocalProcessIdentity
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>
}

/// Identity-free terminal observation for one immutable process instance. This result is only an
/// absence proof; it carries no attach eligibility, complete executable identity, or PID authority.
enum DebuggerLocalProcessInstanceTerminalObservation: Hashable, Sendable {
    case absent
    case stillPresent
}

protocol DebuggerLocalProcessInstanceAbsenceProving: Sendable {
    func proveProcessInstanceAbsent(
        _ expected: DebuggerLocalProcessInstanceKey
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceTerminalObservation>
}

/// Narrow kernel-lifetime evidence for one PID. Implementations must read only attributes needed
/// to identify the live kernel process instance; executable path, file metadata, architecture,
/// signing information, and complete authorization identity are explicitly outside this seam.
protocol DebuggerLocalProcessInstanceAnchorProviding: Sendable {
    func processInstanceAnchor(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceKey>
}

private struct UnavailableDebuggerLocalProcessInstanceAnchorProvider:
    DebuggerLocalProcessInstanceAnchorProviding {
    func processInstanceAnchor(
        processID _: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceKey> {
        .unknown(.unstableSnapshot)
    }
}

/// Production two-pass process-instance observer. Each pass reads only the PID/start-time kernel
/// anchor, so an exec, executable rename, or executable unlink cannot masquerade as process
/// termination. The detached proof is deliberately cancellation-shielded after entry: callers may
/// abandon their wait, but cannot truncate the second observation pass.
struct DebuggerLocalProcessInstanceAbsenceObserver:
    DebuggerLocalProcessInstanceAbsenceProving,
    Sendable {
    private enum Pass: Sendable {
        case absent
        case stillPresent
        case unknown(DebuggerLocalAttachDenial)
    }

    private let anchorProvider: any DebuggerLocalProcessInstanceAnchorProviding

    init(anchorProvider: any DebuggerLocalProcessInstanceAnchorProviding) {
        self.anchorProvider = anchorProvider
    }

    /// Compatibility entry point for registry composition. Production evidence providers must
    /// also expose the dedicated kernel anchor seam. A custom full-evidence provider that does not
    /// do so fails closed; its catalog failures are never reinterpreted as process absence.
    init(provider: any DebuggerLocalProcessEvidenceProviding) {
        anchorProvider = provider as? any DebuggerLocalProcessInstanceAnchorProviding
            ?? UnavailableDebuggerLocalProcessInstanceAnchorProvider()
    }

    func proveProcessInstanceAbsent(
        _ expected: DebuggerLocalProcessInstanceKey
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceTerminalObservation> {
        let anchorProvider = anchorProvider
        let proofTask = Task.detached(priority: .userInitiated) {
            let first = await Self.observePass(expected, anchorProvider: anchorProvider)
            let second = await Self.observePass(expected, anchorProvider: anchorProvider)
            return Self.resolve(first: first, second: second)
        }
        return await withTaskCancellationHandler {
            await proofTask.value
        } onCancel: {
            // A terminal settlement already began. Cancellation must not interrupt its second pass.
        }
    }

    private static func observePass(
        _ expected: DebuggerLocalProcessInstanceKey,
        anchorProvider: any DebuggerLocalProcessInstanceAnchorProviding
    ) async -> Pass {
        let result = await anchorProvider.processInstanceAnchor(processID: expected.processID)
        switch result {
        case let .resolved(anchor):
            guard anchor.processID == expected.processID else {
                return .unknown(.identityChanged)
            }
            return anchor.startTime == expected.startTime ? .stillPresent : .absent
        case .unknown(.disappeared):
            return .absent
        case let .unknown(denial), let .ineligible(denial):
            return .unknown(denial)
        }
    }

    private static func resolve(
        first: Pass,
        second: Pass
    ) -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceTerminalObservation> {
        if case let .unknown(denial) = first { return .unknown(denial) }
        if case let .unknown(denial) = second { return .unknown(denial) }
        switch (first, second) {
        case (.absent, .absent):
            return .resolved(.absent)
        case (.stillPresent, .stillPresent):
            return .resolved(.stillPresent)
        case (.absent, .stillPresent), (.stillPresent, .absent):
            return .unknown(.identityChanged)
        case (.unknown, _), (_, .unknown):
            return .unknown(.unstableSnapshot)
        }
    }
}

struct DebuggerLocalProcessIdentityObserver: Sendable,
    DebuggerLocalProcessIdentityRevalidating,
    DebuggerLocalProcessIdentityReobserving {
    private let provider: any DebuggerLocalProcessEvidenceProviding

    init(provider: any DebuggerLocalProcessEvidenceProviding) {
        self.provider = provider
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        await provider.processIDs()
    }

    func observeCatalog(
        processID: Int32,
        policy: DebuggerLocalProcessObservationPolicy
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogObservation> {
        guard !Task.isCancelled else { return .unknown(.timeout) }
        let result = await provider.catalogEvidence(processID: processID)
        guard case let .resolved(evidence) = result else {
            return result.forwardingFailure()
        }
        guard evidence.fingerprint.processID == processID else {
            return .unknown(.identityChanged)
        }

        return .resolved(
            DebuggerLocalProcessCatalogObservation(
                fingerprint: evidence.fingerprint,
                displayName: Self.sanitizedDisplayName(
                    evidence.displayName,
                    processID: processID
                ),
                parentProcessID: evidence.parentProcessID,
                dynamicState: evidence.dynamicState,
                eligibility: Self.eligibility(for: evidence, policy: policy)
            )
        )
    }

    func authorize(
        selection: DebuggerLocalProcessCatalogSelection,
        policy: DebuggerLocalProcessObservationPolicy
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationGrant> {
        guard !Task.isCancelled else { return .unknown(.timeout) }
        let processID = selection.fingerprint.processID
        guard processID > 1, processID != policy.selfProcessID else {
            return .ineligible(.selfOrOwnedInfrastructure)
        }

        let firstResult = await provider.authorizationEvidence(processID: processID)
        guard case let .resolved(first) = firstResult else {
            return firstResult.forwardingFailure()
        }
        guard !Task.isCancelled else { return .unknown(.timeout) }
        guard Self.eligibility(for: first.catalogEvidence, policy: policy).isAttachable else {
            return Self.resolutionForEligibility(
                Self.eligibility(for: first.catalogEvidence, policy: policy)
            )
        }
        let secondResult = await provider.authorizationEvidence(processID: processID)
        guard case let .resolved(second) = secondResult else {
            return secondResult.forwardingFailure()
        }
        guard first == second else { return .unknown(.identityChanged) }
        let secondEligibility = Self.eligibility(for: second.catalogEvidence, policy: policy)
        guard secondEligibility.isAttachable else {
            return Self.resolutionForEligibility(secondEligibility)
        }

        guard let grant = DebuggerLocalProcessAuthorizationGrant(
            discoveryGeneration: selection.discoveryGeneration,
            fingerprint: selection.fingerprint,
            authorizationFingerprint: second.fingerprint,
            identity: second.identity
        ) else {
            return .unknown(.identityChanged)
        }
        return .resolved(grant)
    }

    /// Re-observes one selected process twice through the same bounded authorization path used by
    /// discovery authorization. Any incoherent evidence, policy denial, A/B instability, or drift
    /// from the complete selected identity fails before an attach adapter can be touched.
    func revalidateAttachRequest(
        _ request: DebuggerLocalAttachRequest,
        policy: DebuggerLocalProcessObservationPolicy
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity> {
        guard !Task.isCancelled else { return .unknown(.timeout) }
        let expectedIdentity = request.selectedIdentity
        let processID = expectedIdentity.processID
        guard processID > 1, processID != policy.selfProcessID else {
            return .ineligible(.selfOrOwnedInfrastructure)
        }

        let firstResult = await provider.authorizationEvidence(processID: processID)
        guard case let .resolved(first) = firstResult else {
            return firstResult.forwardingFailure()
        }
        guard !Task.isCancelled else { return .unknown(.timeout) }
        guard first.fingerprint.matches(first.identity), first.identity.processID == processID else {
            return .unknown(.identityChanged)
        }
        let firstEligibility = Self.eligibility(for: first.catalogEvidence, policy: policy)
        guard firstEligibility.isAttachable else {
            return Self.resolutionForEligibility(firstEligibility)
        }

        let secondResult = await provider.authorizationEvidence(processID: processID)
        guard case let .resolved(second) = secondResult else {
            return secondResult.forwardingFailure()
        }
        guard !Task.isCancelled else { return .unknown(.timeout) }
        guard second.fingerprint.matches(second.identity), second.identity.processID == processID else {
            return .unknown(.identityChanged)
        }
        guard first == second,
              first.identity.identityDigest == second.identity.identityDigest else {
            return .unknown(.identityChanged)
        }
        let secondEligibility = Self.eligibility(for: second.catalogEvidence, policy: policy)
        guard secondEligibility.isAttachable else {
            return Self.resolutionForEligibility(secondEligibility)
        }
        guard second.identity == expectedIdentity,
              second.identity.identityDigest == expectedIdentity.identityDigest else {
            return .unknown(.identityChanged)
        }
        return .resolved(second.identity)
    }

    /// Performs exactly two bounded complete OS identity observations. Mutable attach-policy facts
    /// are deliberately ignored: post-retirement recovery needs immutable survival evidence, not a
    /// fresh attach grant. Any incomplete pass, A/B instability, or drift from `expected` fails
    /// closed without a third observation or a target action.
    func reobserveIdentity(
        _ expected: DebuggerLocalProcessIdentity
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity> {
        guard !Task.isCancelled else { return .unknown(.timeout) }
        let processID = expected.processID

        let firstResult = await provider.authorizationEvidence(processID: processID)
        guard case let .resolved(first) = firstResult else {
            return Self.identityReobservationFailure(firstResult)
        }
        guard !Task.isCancelled else { return .unknown(.timeout) }
        guard first.fingerprint.matches(first.identity),
              first.identity.processID == processID else {
            return .unknown(.identityChanged)
        }

        let secondResult = await provider.authorizationEvidence(processID: processID)
        guard case let .resolved(second) = secondResult else {
            return Self.identityReobservationFailure(secondResult)
        }
        guard !Task.isCancelled else { return .unknown(.timeout) }
        guard second.fingerprint.matches(second.identity),
              second.identity.processID == processID,
              first.identity == second.identity,
              first.identity.identityDigest == second.identity.identityDigest,
              second.identity == expected,
              second.identity.identityDigest == expected.identityDigest else {
            return .unknown(.identityChanged)
        }
        return .resolved(second.identity)
    }

    /// Provider-side `ineligible` values are attach classifications, not identity evidence. This
    /// seam cannot reinterpret them as proof that the immutable process survived, so they collapse
    /// to an unknown identity change while precise observation failures remain intact.
    private static func identityReobservationFailure(
        _ result: DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>
    ) -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity> {
        switch result {
        case .resolved:
            .unknown(.unstableSnapshot)
        case .ineligible:
            .unknown(.identityChanged)
        case let .unknown(denial):
            .unknown(denial)
        }
    }

    private static func eligibility(
        for evidence: DebuggerLocalProcessCatalogEvidence,
        policy: DebuggerLocalProcessObservationPolicy
    ) -> DebuggerLocalProcessEligibility {
        let fingerprint = evidence.fingerprint
        let instance = DebuggerLocalProcessInstanceKey(
            processID: fingerprint.processID,
            startTime: fingerprint.startTime
        )
        if fingerprint.processID <= 1 { return .ineligible(.systemProcess) }
        if fingerprint.processID == policy.selfProcessID
            || policy.excludedInfrastructure.contains(instance) {
            return .ineligible(.selfOrOwnedInfrastructure)
        }
        if evidence.dynamicState.isSystem { return .ineligible(.systemProcess) }
        if fingerprint.codeIdentity?.isPlatformBinary == true {
            return .ineligible(.platformProtected)
        }
        if evidence.dynamicState.targetDisallowsDebugging {
            return .ineligible(.targetDisallowsDebugging)
        }
        if evidence.dynamicState.hasUnknownSecurityPolicy {
            return .unknown(.authorizationDeniedUnclassified)
        }
        if fingerprint.realUserID != policy.hostRealUserID
            || fingerprint.effectiveUserID != policy.hostEffectiveUserID {
            return .ineligible(.differentUser)
        }
        if fingerprint.realUserID != fingerprint.effectiveUserID
            || evidence.savedUserID != fingerprint.realUserID
            || evidence.dynamicState.hasPrivilegedIdentityTransition {
            return .ineligible(.privilegedIdentity)
        }
        if evidence.dynamicState.isTraced { return .ineligible(.alreadyTraced) }
        if evidence.dynamicState.isExiting || evidence.dynamicState.isZombie {
            return .ineligible(.exiting)
        }
        if evidence.dynamicState.isTranslated {
            return .ineligible(.translatedArchitecture)
        }
        return .eligible
    }

    private static func resolutionForEligibility<Value: Sendable>(
        _ eligibility: DebuggerLocalProcessEligibility
    ) -> DebuggerLocalProcessResolution<Value> {
        switch eligibility {
        case .eligible: .unknown(.unstableSnapshot)
        case let .ineligible(denial): .ineligible(denial)
        case let .unknown(denial): .unknown(denial)
        }
    }

    private static func sanitizedDisplayName(_ raw: String, processID: Int32) -> String {
        var result = ""
        result.reserveCapacity(min(raw.utf8.count, 256))
        for scalar in raw.unicodeScalars {
            let replacement: UnicodeScalar = CharacterSet.controlCharacters.contains(scalar)
                ? " " : scalar
            let addition = String(replacement)
            guard result.utf8.count + addition.utf8.count <= 256 else { break }
            result.append(addition)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "pid \(processID)" : trimmed
    }
}

private extension DebuggerLocalProcessResolution {
    func mapResolved<NewValue: Sendable>(
        _ transform: (Value) -> NewValue
    ) -> DebuggerLocalProcessResolution<NewValue> {
        switch self {
        case let .resolved(value): .resolved(transform(value))
        case let .ineligible(denial): .ineligible(denial)
        case let .unknown(denial): .unknown(denial)
        }
    }

    func forwardingFailure<NewValue: Sendable>()
        -> DebuggerLocalProcessResolution<NewValue> {
        switch self {
        case .resolved:
            .unknown(.unstableSnapshot)
        case let .ineligible(denial):
            .ineligible(denial)
        case let .unknown(denial):
            .unknown(denial)
        }
    }
}

extension DebuggerLocalProcessInstanceKey {
    init(processID: Int32, startTime: DebuggerProcessStartIdentity) {
        self.processID = processID
        self.startTime = startTime
    }
}

#if canImport(Darwin)
enum DarwinReadResult<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case interrupted
    case endOfFile
    case failed(Int32)
    case cancelled
    case malformed
}

enum DarwinProcessReadInterpreter {
    static func fixedSizeResult(
        returnedByteCount: Int32,
        expectedByteCount: Int,
        capturedErrno: Int32
    ) -> DebuggerLocalProcessResolution<Bool> {
        guard Int(returnedByteCount) == expectedByteCount else {
            return returnedByteCount <= 0
                ? failure(forErrno: capturedErrno)
                : .unknown(.unstableSnapshot)
        }
        return .resolved(true)
    }

    static func pathResult(
        bytes: [CChar],
        returnedByteCount: Int32,
        capturedErrno: Int32
    ) -> DebuggerLocalProcessResolution<String> {
        guard returnedByteCount > 0 else { return failure(forErrno: capturedErrno) }
        let count = Int(returnedByteCount)
        guard count < bytes.count,
              let nulIndex = bytes.firstIndex(of: 0),
              nulIndex == count || nulIndex + 1 == count else {
            return .unknown(.unstableSnapshot)
        }
        let pathBytes = bytes[..<nulIndex].map { UInt8(bitPattern: $0) }
        guard let rawPath = String(bytes: pathBytes, encoding: .utf8),
              !rawPath.isEmpty else {
            return .unknown(.unstableSnapshot)
        }
        let path = (rawPath as NSString).standardizingPath
        guard path.hasPrefix("/"), !path.isEmpty else {
            return .unknown(.unstableSnapshot)
        }
        return .resolved(path)
    }

    static func failure<Value: Sendable>(
        forErrno capturedErrno: Int32
    ) -> DebuggerLocalProcessResolution<Value> {
        switch capturedErrno {
        case ESRCH, ENOENT: .unknown(.disappeared)
        case EACCES, EPERM: .unknown(.metadataAccessDenied)
        default: .unknown(.unstableSnapshot)
        }
    }
}

struct DarwinSecuritySigningFacts: Hashable, Sendable {
    let identifier: String?
    let teamIdentifier: String?
    let codeDirectorySHA256: String?
    /// A missing platform field in otherwise successful signing information means false.
    let platformValue: Bool?
    let signingFlags: UInt32?
}

enum DarwinSecuritySigningOutcome: Hashable, Sendable {
    case signed(DarwinSecuritySigningFacts)
    case unsigned
    case failure(OSStatus)
}

enum DarwinSecurityStatusInterpreter {
    static func observe(
        status: OSStatus,
        facts: DarwinSecuritySigningFacts? = nil
    ) -> DarwinSecurityObservation {
        if status == errSecCSUnsigned { return observe(.unsigned) }
        guard status == errSecSuccess, let facts else { return observe(.failure(status)) }
        return observe(.signed(facts))
    }

    static func observe(_ outcome: DarwinSecuritySigningOutcome) -> DarwinSecurityObservation {
        switch outcome {
        case let .signed(facts):
            return DarwinSecurityObservation(
                identity: DebuggerLocalCodeIdentity(
                    signingIdentifier: facts.identifier,
                    teamIdentifier: facts.teamIdentifier,
                    codeDirectorySHA256: facts.codeDirectorySHA256,
                    isPlatformBinary: facts.platformValue ?? false,
                    signingFlags: facts.signingFlags
                ),
                policyIsUnknown: false
            )
        case .unsigned:
            return DarwinSecurityObservation(identity: nil, policyIsUnknown: false)
        case .failure:
            return DarwinSecurityObservation(identity: nil, policyIsUnknown: true)
        }
    }
}

enum DarwinAuthorizationHasher {
    static let maximumByteCount: UInt64 = 16 * 1_024 * 1_024 * 1_024
    static let chunkByteCount = 1_048_576

    static func sha256(
        byteCount: UInt64,
        deadlineExpired: () -> Bool,
        isCancelled: () -> Bool,
        read: (UInt64, Int) -> DarwinReadResult<Data>
    ) -> DarwinHashResult {
        guard byteCount > 0, byteCount <= maximumByteCount else { return .unstable }
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < byteCount {
            if isCancelled() { return .cancelled }
            if deadlineExpired() { return .timeout }
            let requested = Int(min(UInt64(chunkByteCount), byteCount - offset))
            switch read(offset, requested) {
            case let .value(data):
                guard !data.isEmpty, data.count <= requested else { return .unstable }
                hasher.update(data: data)
                offset += UInt64(data.count)
            case .interrupted:
                continue
            case .cancelled:
                return .cancelled
            case .endOfFile, .failed, .malformed:
                return .unstable
            }
        }
        if isCancelled() { return .cancelled }
        if deadlineExpired() { return .timeout }
        return .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

enum DarwinMachOParser {
    static let maximumFatSliceCount = 128
    static let maximumLoadCommandCount: UInt32 = 4_096
    static let maximumLoadCommandByteCount: UInt32 = 16 * 1_024 * 1_024

    static func observe(
        fileByteCount: UInt64,
        expectedArchitecture: DebuggerLocalProcessArchitecture,
        read: (UInt64, Int) -> DarwinReadResult<Data>
    ) -> DarwinReadResult<DarwinMachOObservation> {
        let prefixResult = exactRead(offset: 0, count: 8, read: read)
        guard case let .value(prefix) = prefixResult else {
            return prefixResult.forwardingReadFailure()
        }
        var sliceOffset: UInt64 = 0
        var sliceByteCount = fileByteCount
        let magicBE = prefix.uint32BE(at: 0)
        if magicBE == 0xcafe_babe || magicBE == 0xcafe_babf {
            let is64BitFat = magicBE == 0xcafe_babf
            let sliceCount = Int(prefix.uint32BE(at: 4))
            guard (1...maximumFatSliceCount).contains(sliceCount) else { return .malformed }
            let entryByteCount = is64BitFat ? 32 : 20
            let tableByteCount = sliceCount.multipliedReportingOverflow(by: entryByteCount)
            guard !tableByteCount.overflow else { return .malformed }
            let tableEnd = UInt64(8 + tableByteCount.partialValue)
            guard tableEnd <= fileByteCount else { return .malformed }
            let tableResult = exactRead(
                offset: 8,
                count: tableByteCount.partialValue,
                read: read
            )
            guard case let .value(table) = tableResult else {
                return tableResult.forwardingReadFailure()
            }
            var selected: (offset: UInt64, size: UInt64)?
            for index in 0..<sliceCount {
                let cursor = index * entryByteCount
                let cpuType = Int32(bitPattern: table.uint32BE(at: cursor))
                let cpuSubtype = Int32(bitPattern: table.uint32BE(at: cursor + 4))
                let offset = is64BitFat
                    ? table.uint64BE(at: cursor + 8)
                    : UInt64(table.uint32BE(at: cursor + 8))
                let size = is64BitFat
                    ? table.uint64BE(at: cursor + 16)
                    : UInt64(table.uint32BE(at: cursor + 12))
                let alignment = table.uint32BE(at: cursor + (is64BitFat ? 24 : 16))
                let reserved = is64BitFat ? table.uint32BE(at: cursor + 28) : 0
                guard alignment < 63,
                      reserved == 0,
                      offset >= tableEnd,
                      offset.isMultiple(of: UInt64(1) << alignment) else {
                    return .malformed
                }
                let (end, overflow) = offset.addingReportingOverflow(size)
                guard !overflow, size >= 32, end <= fileByteCount else { return .malformed }
                guard mappedArchitecture(cpuType: cpuType, cpuSubtype: cpuSubtype)
                    == expectedArchitecture else {
                    continue
                }
                guard selected == nil else { return .malformed }
                selected = (offset, size)
            }
            guard let selected else { return .malformed }
            sliceOffset = selected.offset
            sliceByteCount = selected.size
        }

        let headerResult = exactRead(offset: sliceOffset, count: 32, read: read)
        guard case let .value(header) = headerResult else {
            return headerResult.forwardingReadFailure()
        }
        guard header.uint32LE(at: 0) == 0xfeed_facf,
              mappedArchitecture(
                  cpuType: Int32(bitPattern: header.uint32LE(at: 4)),
                  cpuSubtype: Int32(bitPattern: header.uint32LE(at: 8))
              ) == expectedArchitecture else {
            return .malformed
        }
        let commandCount = header.uint32LE(at: 16)
        let commandByteCount = header.uint32LE(at: 20)
        guard commandCount <= maximumLoadCommandCount,
              commandByteCount <= maximumLoadCommandByteCount else {
            return .malformed
        }
        let (commandsEnd, overflow) = UInt64(32).addingReportingOverflow(
            UInt64(commandByteCount)
        )
        guard !overflow, commandsEnd <= sliceByteCount else { return .malformed }
        let commandsResult = exactRead(
            offset: sliceOffset + 32,
            count: Int(commandByteCount),
            read: read
        )
        guard case let .value(commands) = commandsResult else {
            return commandsResult.forwardingReadFailure()
        }
        var cursor = 0
        var uuid: UUID?
        for _ in 0..<commandCount {
            guard cursor <= commands.count - 8 else { return .malformed }
            let command = commands.uint32LE(at: cursor)
            let size = Int(commands.uint32LE(at: cursor + 4))
            guard size >= 8, cursor <= commands.count - size else { return .malformed }
            if command == 0x1b {
                guard size == 24, uuid == nil else { return .malformed }
                let bytes = Array(commands[(cursor + 8)..<(cursor + 24)])
                uuid = UUID(uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                ))
            }
            cursor += size
        }
        guard cursor == commands.count else { return .malformed }
        return .value(DarwinMachOObservation(
            architecture: expectedArchitecture,
            uuid: uuid
        ))
    }

    private static func exactRead(
        offset: UInt64,
        count: Int,
        read: (UInt64, Int) -> DarwinReadResult<Data>
    ) -> DarwinReadResult<Data> {
        guard count >= 0 else { return .malformed }
        if count == 0 { return .value(Data()) }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let readOffset = offset.addingReportingOverflow(UInt64(result.count))
            guard !readOffset.overflow else { return .malformed }
            switch read(readOffset.partialValue, count - result.count) {
            case let .value(data):
                guard !data.isEmpty, data.count <= count - result.count else {
                    return .malformed
                }
                result.append(data)
            case .interrupted:
                continue
            case .endOfFile:
                return .endOfFile
            case let .failed(error):
                return .failed(error)
            case .cancelled:
                return .cancelled
            case .malformed:
                return .malformed
            }
        }
        return .value(result)
    }

    private static func mappedArchitecture(
        cpuType: Int32,
        cpuSubtype: Int32
    ) -> DebuggerLocalProcessArchitecture? {
        guard cpuType == CPU_TYPE_ARM64 else { return nil }
        switch UInt32(bitPattern: cpuSubtype) & 0x00ff_ffff {
        case 0, 1: return .arm64
        case 2: return .arm64e
        default: return nil
        }
    }
}

private extension DarwinReadResult {
    func forwardingReadFailure<NewValue: Equatable & Sendable>() -> DarwinReadResult<NewValue> {
        switch self {
        case .value: .malformed
        case .interrupted: .interrupted
        case .endOfFile: .endOfFile
        case let .failed(error): .failed(error)
        case .cancelled: .cancelled
        case .malformed: .malformed
        }
    }
}

/// Public-API-only production evidence source. Catalog observation deliberately never computes a
/// complete executable digest; authorization does so for one selected PID and is invoked twice by
/// `DebuggerLocalProcessIdentityObserver`.
struct DarwinDebuggerLocalProcessEvidenceProvider:
    DebuggerLocalProcessEvidenceProviding,
    DebuggerLocalProcessInstanceAnchorProviding {
    private static let maximumPIDEnumerationAttempts = 4
    private static let maximumPIDCount = 16_384
    private static let authorizationHashTimeout: Duration = .seconds(30)

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        guard !Task.isCancelled else { return .unknown(.timeout) }
        errno = 0
        let advertisedByteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        let advertisedErrno = errno
        guard advertisedByteCount >= 0 else {
            return Self.failure(forErrno: advertisedErrno)
        }
        var capacity = max(
            Int(advertisedByteCount),
            MemoryLayout<pid_t>.stride * 256
        )
        for _ in 0..<Self.maximumPIDEnumerationAttempts {
            capacity = min(
                capacity + MemoryLayout<pid_t>.stride * 256,
                MemoryLayout<pid_t>.stride * Self.maximumPIDCount
            )
            var values = [pid_t](
                repeating: 0,
                count: capacity / MemoryLayout<pid_t>.stride
            )
            errno = 0
            let filled = values.withUnsafeMutableBytes { buffer in
                proc_listpids(
                    UInt32(PROC_ALL_PIDS),
                    0,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            let filledErrno = errno
            guard filled >= 0 else { return Self.failure(forErrno: filledErrno) }
            let byteCount = Int(filled)
            guard byteCount % MemoryLayout<pid_t>.stride == 0 else {
                return .unknown(.unstableSnapshot)
            }
            if byteCount < capacity {
                let count = byteCount / MemoryLayout<pid_t>.stride
                let observedPIDs: [Int32] = values[0..<count].map { value in
                    Int32(value)
                }
                let pids = Set(observedPIDs.filter { $0 > 0 })
                return .resolved(pids.sorted())
            }
            guard capacity < MemoryLayout<pid_t>.stride * Self.maximumPIDCount else {
                return .unknown(.unstableSnapshot)
            }
            capacity = min(capacity * 2, MemoryLayout<pid_t>.stride * Self.maximumPIDCount)
        }
        return .unknown(.unstableSnapshot)
    }

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        await observe(processID: processID, includeDigest: false).mapResolved { observation in
            observation.catalog
        }
    }

    /// Reads only `PROC_PIDTBSDINFO`, whose PID/start-time pair identifies the kernel process
    /// instance independently of executable metadata. ESRCH/ENOENT mean the PID is not observable;
    /// access or malformed-read failures remain unknown and can never release ownership.
    func processInstanceAnchor(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceKey> {
        guard processID > 0 else { return .unknown(.disappeared) }
        guard !Task.isCancelled else { return .unknown(.timeout) }
        return Self.anchor(processID: processID).mapResolved { anchor in
            DebuggerLocalProcessInstanceKey(
                processID: anchor.processID,
                startTime: anchor.startTime
            )
        }
    }

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        let result = await observe(processID: processID, includeDigest: true)
        switch result {
        case let .resolved(observation):
            guard let identity = observation.identity else {
                return .unknown(.unstableSnapshot)
            }
            return .resolved(DebuggerLocalProcessAuthorizationEvidence(
                catalogEvidence: observation.catalog,
                identity: identity
            ))
        case let .ineligible(denial):
            return .ineligible(denial)
        case let .unknown(denial):
            return .unknown(denial)
        }
    }

    private func observe(
        processID: Int32,
        includeDigest: Bool
    ) async -> DebuggerLocalProcessResolution<DarwinObservation> {
        guard processID > 0 else { return .unknown(.disappeared) }
        guard !Task.isCancelled else { return .unknown(.timeout) }
        let anchorAResult = Self.anchor(processID: processID)
        guard case let .resolved(anchorA) = anchorAResult else {
            return anchorAResult.forwardingFailure()
        }
        let architectureResolution = Self.architecture(processID: processID)
        guard case let .resolved(architectureResult) = architectureResolution else {
            return architectureResolution.forwardingFailure()
        }
        let pathResolution = Self.executablePath(processID: processID)
        guard case let .resolved(path) = pathResolution else {
            return pathResolution.forwardingFailure()
        }
        errno = 0
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let openErrno = errno
        guard descriptor >= 0 else { return Self.failure(forErrno: openErrno) }
        defer { close(descriptor) }

        guard let metadataBefore = Self.metadata(descriptor: descriptor, path: path) else {
            return .unknown(.unstableSnapshot)
        }
        let machOResult = DarwinMachOParser.observe(
            fileByteCount: metadataBefore.byteCount,
            expectedArchitecture: architectureResult.architecture,
            read: { offset, count in
                Self.read(descriptor: descriptor, offset: offset, count: count)
            }
        )
        let machO: DarwinMachOObservation
        switch machOResult {
        case let .value(observation):
            machO = observation
        case .cancelled:
            return .unknown(.timeout)
        case .interrupted, .endOfFile, .failed, .malformed:
            return .unknown(.unstableSnapshot)
        }
        guard !Task.isCancelled else { return .unknown(.timeout) }
        let security = Self.codeIdentity(processID: processID)
        let codeIdentity = security.identity
        let executableSHA256: String?
        if includeDigest {
            let hashResult = await Self.completeSHA256(
                descriptor: descriptor,
                byteCount: metadataBefore.byteCount
            )
            switch hashResult {
            case let .success(digest):
                executableSHA256 = digest
            case .timeout, .cancelled:
                return .unknown(.timeout)
            case .unstable:
                return .unknown(.unstableSnapshot)
            }
        } else {
            executableSHA256 = nil
        }
        guard let metadataAfter = Self.metadata(descriptor: descriptor, path: path),
              metadataBefore == metadataAfter else {
            return .unknown(.identityChanged)
        }
        let anchorBResult = Self.anchor(processID: processID)
        guard case let .resolved(anchorB) = anchorBResult else {
            return anchorBResult.forwardingFailure()
        }
        guard anchorA == anchorB else { return .unknown(.identityChanged) }

        guard let fingerprint = DebuggerLocalProcessCatalogFingerprint(
            processID: processID,
            startTime: anchorA.startTime,
            realUserID: anchorA.realUserID,
            effectiveUserID: anchorA.effectiveUserID,
            canonicalExecutablePath: metadataBefore.canonicalPath,
            executableDeviceID: metadataBefore.deviceID,
            executableFileID: metadataBefore.fileID,
            executableByteCount: metadataBefore.byteCount,
            executableChangeTimeNanoseconds: metadataBefore.changeTimeNanoseconds,
            architecture: machO.architecture,
            machOUUID: machO.uuid,
            codeIdentity: codeIdentity
        ) else {
            return .unknown(.unstableSnapshot)
        }
        let catalog = DebuggerLocalProcessCatalogEvidence(
            fingerprint: fingerprint,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            parentProcessID: anchorA.parentProcessID,
            savedUserID: anchorA.savedUserID,
            dynamicState: anchorA.dynamicState(
                translated: false,
                security: security
            )
        )
        guard let executableSHA256 else {
            return .resolved(DarwinObservation(catalog: catalog, identity: nil))
        }
        guard let identity = DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: anchorA.startTime,
            realUserID: anchorA.realUserID,
            effectiveUserID: anchorA.effectiveUserID,
            canonicalExecutablePath: metadataBefore.canonicalPath,
            executableDeviceID: metadataBefore.deviceID,
            executableFileID: metadataBefore.fileID,
            executableByteCount: metadataBefore.byteCount,
            executableSHA256: executableSHA256,
            architecture: machO.architecture,
            machOUUID: machO.uuid,
            codeIdentity: codeIdentity
        ) else {
            return .unknown(.unstableSnapshot)
        }
        return .resolved(DarwinObservation(catalog: catalog, identity: identity))
    }

    private static func anchor(
        processID: Int32
    ) -> DebuggerLocalProcessResolution<DarwinAnchor> {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        errno = 0
        let count = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(size))
        }
        let status = DarwinProcessReadInterpreter.fixedSizeResult(
            returnedByteCount: count,
            expectedByteCount: size,
            capturedErrno: errno
        )
        guard status.isResolved else {
            return status.forwardingFailure()
        }
        guard info.pbi_pid == UInt32(processID) else {
            return .unknown(.identityChanged)
        }
        guard let microseconds = UInt32(exactly: info.pbi_start_tvusec),
              let startTime = DebuggerProcessStartIdentity(
                  seconds: info.pbi_start_tvsec,
                  microseconds: microseconds
              ) else {
            return .unknown(.unstableSnapshot)
        }
        return .resolved(DarwinAnchor(
            processID: processID,
            parentProcessID: Int32(bitPattern: info.pbi_ppid),
            startTime: startTime,
            realUserID: info.pbi_ruid,
            effectiveUserID: info.pbi_uid,
            savedUserID: info.pbi_svuid,
            flags: info.pbi_flags,
            status: info.pbi_status
        ))
    }

    private static func architecture(
        processID: Int32
    ) -> DebuggerLocalProcessResolution<DarwinArchitectureObservation> {
        var info = proc_archinfo()
        let size = MemoryLayout<proc_archinfo>.size
        errno = 0
        let count = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processID, PROC_PIDARCHINFO, 0, $0, Int32(size))
        }
        let status = DarwinProcessReadInterpreter.fixedSizeResult(
            returnedByteCount: count,
            expectedByteCount: size,
            capturedErrno: errno
        )
        guard status.isResolved else {
            return status.forwardingFailure()
        }
        if info.p_cputype == CPU_TYPE_X86_64 {
            return .ineligible(.translatedArchitecture)
        }
        guard info.p_cputype == CPU_TYPE_ARM64 else {
            return .ineligible(.unsupportedArchitecture)
        }
        let subtype = UInt32(bitPattern: info.p_cpusubtype) & 0x00ff_ffff
        switch subtype {
        case 0, 1: return .resolved(DarwinArchitectureObservation(architecture: .arm64))
        case 2: return .resolved(DarwinArchitectureObservation(architecture: .arm64e))
        default: return .ineligible(.unsupportedArchitecture)
        }
    }

    private static func executablePath(
        processID: Int32
    ) -> DebuggerLocalProcessResolution<String> {
        let maximumPathByteCount = Int(MAXPATHLEN) * 4
        var bytes = [CChar](repeating: 0, count: maximumPathByteCount)
        errno = 0
        let count = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(processID, buffer.baseAddress, UInt32(buffer.count))
        }
        return DarwinProcessReadInterpreter.pathResult(
            bytes: bytes,
            returnedByteCount: count,
            capturedErrno: errno
        )
    }

    private static func read(
        descriptor: Int32,
        offset: UInt64,
        count: Int
    ) -> DarwinReadResult<Data> {
        guard !Task.isCancelled else { return .cancelled }
        guard count >= 0, offset <= UInt64(Int64.max) else { return .malformed }
        if count == 0 { return .value(Data()) }
        var result = Data(count: count)
        errno = 0
        let readCount = result.withUnsafeMutableBytes { bytes in
            pread(descriptor, bytes.baseAddress!, count, off_t(offset))
        }
        let capturedErrno = errno
        if readCount < 0 {
            return capturedErrno == EINTR ? .interrupted : .failed(capturedErrno)
        }
        guard readCount > 0 else { return .endOfFile }
        result.removeSubrange(readCount..<result.count)
        return .value(result)
    }

    private static func metadata(
        descriptor: Int32,
        path: String
    ) -> DarwinExecutableMetadata? {
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_dev > 0,
              value.st_ino > 0,
              value.st_size > 0,
              value.st_ctimespec.tv_sec >= 0,
              (0..<1_000_000_000).contains(value.st_ctimespec.tv_nsec) else {
            return nil
        }
        let seconds = UInt64(value.st_ctimespec.tv_sec)
        let (scaled, overflowA) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (changeTime, overflowB) = scaled.addingReportingOverflow(
            UInt64(value.st_ctimespec.tv_nsec)
        )
        guard !overflowA, !overflowB else { return nil }
        return DarwinExecutableMetadata(
            canonicalPath: path,
            deviceID: UInt64(value.st_dev),
            fileID: UInt64(value.st_ino),
            byteCount: UInt64(value.st_size),
            changeTimeNanoseconds: changeTime
        )
    }

    private static func completeSHA256(
        descriptor: Int32,
        byteCount: UInt64
    ) async -> DarwinHashResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: authorizationHashTimeout)
        return DarwinAuthorizationHasher.sha256(
            byteCount: byteCount,
            deadlineExpired: { clock.now >= deadline },
            isCancelled: { Task.isCancelled },
            read: { offset, count in
                Self.read(descriptor: descriptor, offset: offset, count: count)
            }
        )
    }

    private static func codeIdentity(processID: Int32) -> DarwinSecurityObservation {
        var dynamicCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)]
            as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &dynamicCode
        )
        guard guestStatus == errSecSuccess, let dynamicCode else {
            return DarwinSecurityStatusInterpreter.observe(status: guestStatus)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return DarwinSecurityStatusInterpreter.observe(status: staticStatus)
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        let signingStatus = SecCodeCopySigningInformation(staticCode, flags, &information)
        guard signingStatus == errSecSuccess else {
            return DarwinSecurityStatusInterpreter.observe(status: signingStatus)
        }
        guard let values = information as? [String: Any] else {
            return DarwinSecurityStatusInterpreter.observe(.failure(errSecInternalError))
        }
        let identifier = values[kSecCodeInfoIdentifier as String] as? String
        let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        let signingFlags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        let platformNumber = values[kSecCodeInfoPlatformIdentifier as String] as? NSNumber
        let cdHash = sha256CodeDirectoryHash(values)
        return DarwinSecurityStatusInterpreter.observe(
            status: errSecSuccess,
            facts: DarwinSecuritySigningFacts(
                identifier: identifier,
                teamIdentifier: team,
                codeDirectorySHA256: cdHash,
                platformValue: platformNumber.map { $0.uint32Value != 0 },
                signingFlags: signingFlags
            )
        )
    }

    private static func sha256CodeDirectoryHash(_ values: [String: Any]) -> String? {
        guard let algorithms = values[kSecCodeInfoDigestAlgorithms as String] as? [NSNumber],
              let hashes = values[kSecCodeInfoCdHashes as String] as? [Data],
              algorithms.count == hashes.count else {
            return nil
        }
        for (algorithm, hash) in zip(algorithms, hashes)
        where algorithm.uint32Value == 2 && hash.count == 32 {
            return hash.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }

    private static func failure<Value: Sendable>(forErrno capturedErrno: Int32)
        -> DebuggerLocalProcessResolution<Value> {
        DarwinProcessReadInterpreter.failure(forErrno: capturedErrno)
    }
}

private struct DarwinObservation: Sendable {
    let catalog: DebuggerLocalProcessCatalogEvidence
    let identity: DebuggerLocalProcessIdentity?
}

private struct DarwinExecutableMetadata: Hashable, Sendable {
    let canonicalPath: String
    let deviceID: UInt64
    let fileID: UInt64
    let byteCount: UInt64
    let changeTimeNanoseconds: UInt64
}

struct DarwinMachOObservation: Hashable, Sendable {
    let architecture: DebuggerLocalProcessArchitecture
    let uuid: UUID?
}

private struct DarwinArchitectureObservation: Hashable, Sendable {
    let architecture: DebuggerLocalProcessArchitecture
}

struct DarwinSecurityObservation: Hashable, Sendable {
    let identity: DebuggerLocalCodeIdentity?
    let policyIsUnknown: Bool
}

enum DarwinHashResult: Equatable, Sendable {
    case success(String)
    case timeout
    case cancelled
    case unstable
}

private struct DarwinAnchor: Hashable, Sendable {
    let processID: Int32
    let parentProcessID: Int32
    let startTime: DebuggerProcessStartIdentity
    let realUserID: UInt32
    let effectiveUserID: UInt32
    let savedUserID: UInt32
    let flags: UInt32
    let status: UInt32

    func dynamicState(
        translated: Bool,
        security: DarwinSecurityObservation
    ) -> DebuggerLocalProcessDynamicState {
        DebuggerLocalProcessDynamicState(
            isSystem: (flags & UInt32(PROC_FLAG_SYSTEM)) != 0,
            isTraced: (flags & UInt32(PROC_FLAG_TRACED)) != 0,
            isExiting: (flags & UInt32(PROC_FLAG_INEXIT)) != 0,
            isZombie: status == UInt32(SZOMB),
            isTranslated: translated,
            hasPrivilegedIdentityTransition: (flags & UInt32(PROC_FLAG_PSUGID)) != 0,
            // A positive attach prohibition is not derivable from the public signing facts used
            // during discovery. Structured LLDB transport owns that later classification.
            targetDisallowsDebugging: false,
            hasUnknownSecurityPolicy: security.policyIsUnknown
        )
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        let bytes = self[offset..<(offset + 4)]
        return bytes.enumerated().reduce(0) { partial, pair in
            partial | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }
    }

    func uint32BE(at offset: Int) -> UInt32 {
        let bytes = self[offset..<(offset + 4)]
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func uint64BE(at offset: Int) -> UInt64 {
        let bytes = self[offset..<(offset + 8)]
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
#endif
