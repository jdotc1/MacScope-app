import CryptoKit
import Darwin
import Foundation

struct Phase2QualificationProcessStartIdentity: Hashable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64

    var isValid: Bool { seconds > 0 && microseconds < 1_000_000 }
}

struct Phase2QualificationExecutableIdentity: Hashable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let sha256: String

    var isValid: Bool { deviceID > 0 && fileID > 0 && phase2IsSHA256Hex(sha256) }
}

/// Ephemeral launch-local evidence. Process identifiers never enter a reusable profile identity,
/// qualification report, or persisted evidence payload.
struct Phase2QualificationProcessObservation: Hashable, Sendable {
    let processID: Int32
    let parentProcessID: Int32
    let startIdentity: Phase2QualificationProcessStartIdentity
    let executableIdentity: Phase2QualificationExecutableIdentity
    let residentBytes: UInt64

    var hasValidIdentity: Bool {
        processID > 0
            && parentProcessID >= 0
            && parentProcessID != processID
            && startIdentity.isValid
            && executableIdentity.isValid
    }

    func hasSameIdentity(as other: Self) -> Bool {
        processID == other.processID
            && parentProcessID == other.parentProcessID
            && startIdentity == other.startIdentity
            && executableIdentity == other.executableIdentity
    }
}

protocol Phase2QualificationProcessObserving: Sendable {
    func observation(
        processID: Int32
    ) throws -> Phase2QualificationProcessObservation?

    /// Returns one stable, complete snapshot of the process's immediate children.
    func childProcessIDs(of processID: Int32) throws -> [Int32]?
}

struct Phase2QualificationProcessScopeBinding: Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidRoot
        case duplicateRoot
        case identityUnavailable
    }

    fileprivate enum Role: String, CaseIterable, Hashable, Sendable {
        case app
        case aiWorker = "ai-worker"
        case provider
    }

    fileprivate struct Root: Hashable, Sendable {
        let role: Role
        let processID: Int32
        let parentProcessID: Int32
        let startIdentity: Phase2QualificationProcessStartIdentity
        let executableIdentity: Phase2QualificationExecutableIdentity

        init(role: Role, observation: Phase2QualificationProcessObservation) {
            self.role = role
            processID = observation.processID
            parentProcessID = observation.parentProcessID
            startIdentity = observation.startIdentity
            executableIdentity = observation.executableIdentity
        }

        func matches(_ observation: Phase2QualificationProcessObservation) -> Bool {
            processID == observation.processID
                && parentProcessID == observation.parentProcessID
                && startIdentity == observation.startIdentity
                && executableIdentity == observation.executableIdentity
        }
    }

    let scopeIdentity: Phase2ProtocolComponentIdentity
    fileprivate let app: Root
    fileprivate let aiWorker: Root
    fileprivate let provider: Root

    init(
        app appObservation: Phase2QualificationProcessObservation,
        aiWorker workerObservation: Phase2QualificationProcessObservation,
        provider providerObservation: Phase2QualificationProcessObservation
    ) throws {
        let observations = [appObservation, workerObservation, providerObservation]
        guard observations.allSatisfy(\.hasValidIdentity),
              observations.allSatisfy({
                  $0.startIdentity.seconds <= UInt64(Int64.max)
                      && $0.startIdentity.microseconds <= UInt64(Int64.max)
                      && $0.executableIdentity.deviceID <= UInt64(Int64.max)
                      && $0.executableIdentity.fileID <= UInt64(Int64.max)
              })
        else { throw ValidationError.invalidRoot }
        guard Set(observations.map(\.processID)).count == observations.count else {
            throw ValidationError.duplicateRoot
        }

        app = Root(role: .app, observation: appObservation)
        aiWorker = Root(role: .aiWorker, observation: workerObservation)
        provider = Root(role: .provider, observation: providerObservation)
        let roots = [app, aiWorker, provider]
        do {
            scopeIdentity = try Phase2QualificationV2Identity.make(
                id: "phase2.r1.qualification-process-scope.v1",
                version: 1,
                object: [
                    "roots": roots.map(Self.identityObject),
                    "version": 1,
                ]
            )
        } catch {
            throw ValidationError.identityUnavailable
        }
    }

    private static func identityObject(_ root: Root) -> [String: Any] {
        [
            "device_id": Int64(root.executableIdentity.deviceID),
            "executable_sha256": root.executableIdentity.sha256,
            "file_id": Int64(root.executableIdentity.fileID),
            "parent_pid": Int64(root.parentProcessID),
            "pid": Int64(root.processID),
            "role": root.role.rawValue,
            "start_microseconds": Int64(root.startIdentity.microseconds),
            "start_seconds": Int64(root.startIdentity.seconds),
        ]
    }
}

protocol Phase2QualificationBoundResidentSetSampling:
    Phase2QualificationResidentSetSampling
{
    var scopeIdentity: Phase2ProtocolComponentIdentity { get }
}

struct Phase2QualificationProcessScopeSampler:
    Phase2QualificationBoundResidentSetSampling,
    Sendable
{

    private enum ScopeFailure: Error {
        case incomplete
    }

    private static let maximumScopedProcessCount = 4_096

    private let binding: Phase2QualificationProcessScopeBinding
    private let observer: any Phase2QualificationProcessObserving

    var scopeIdentity: Phase2ProtocolComponentIdentity { binding.scopeIdentity }
    /// Each successful value is one stable, complete, contemporaneous RSS snapshot across the
    /// bound app, worker, provider root, and provider descendants. Aggregation owns the maximum.
    var measurementSemantics: Phase2QualificationResidentSetMeasurementSemantics {
        .contemporaneousSnapshot
    }

    init?(
        appProcessID: Int32,
        aiWorkerProcessID: Int32,
        providerProcessID: Int32,
        observer: any Phase2QualificationProcessObserving =
            Phase2QualificationLibprocProcessObserver()
    ) {
        let rootIDs = [appProcessID, aiWorkerProcessID, providerProcessID]
        guard rootIDs.allSatisfy({ $0 > 0 }), Set(rootIDs).count == rootIDs.count else {
            return nil
        }
        do {
            guard let appObservation = try observer.observation(processID: appProcessID),
                  let workerObservation = try observer.observation(processID: aiWorkerProcessID),
                  let providerObservation = try observer.observation(processID: providerProcessID),
                  appObservation.processID == appProcessID,
                  workerObservation.processID == aiWorkerProcessID,
                  providerObservation.processID == providerProcessID,
                  appObservation.hasValidIdentity,
                  workerObservation.hasValidIdentity,
                  providerObservation.hasValidIdentity
            else { return nil }
            binding = try Phase2QualificationProcessScopeBinding(
                app: appObservation,
                aiWorker: workerObservation,
                provider: providerObservation
            )
            self.observer = observer
        } catch {
            return nil
        }
    }

    func sample() throws -> Phase2QualificationResidentSetSnapshot? {
        do {
            return try exactSample()
        } catch {
            return nil
        }
    }

    private func exactSample() throws -> Phase2QualificationResidentSetSnapshot {
        let initialApp = try revalidate(binding.app)
        let initialWorker = try revalidate(binding.aiWorker)
        let initialProvider = try revalidate(binding.provider)
        let rootIDs: Set<Int32> = [
            binding.app.processID,
            binding.aiWorker.processID,
            binding.provider.processID,
        ]
        let firstProviderTree = try providerTreeSnapshot(
            initialProvider: initialProvider,
            excludedRootIDs: rootIDs
        )
        let secondProvider = try revalidate(binding.provider)
        let secondProviderTree = try providerTreeSnapshot(
            initialProvider: secondProvider,
            excludedRootIDs: rootIDs
        )
        guard Self.haveSameIdentities(firstProviderTree, secondProviderTree) else {
            throw ScopeFailure.incomplete
        }

        // Sum only the second complete stable tree, then close the interval by revalidating roots.
        let finalApp = try revalidate(binding.app)
        let finalWorker = try revalidate(binding.aiWorker)
        let finalProvider = try revalidate(binding.provider)
        guard initialApp.hasSameIdentity(as: finalApp),
              initialWorker.hasSameIdentity(as: finalWorker),
              initialProvider.hasSameIdentity(as: finalProvider)
        else { throw ScopeFailure.incomplete }

        let appBytes = try checkedInt64(finalApp.residentBytes)
        let workerBytes = try checkedInt64(finalWorker.residentBytes)
        var providerBytes: Int64 = 0
        for observation in secondProviderTree.values {
            let (next, overflow) = providerBytes.addingReportingOverflow(
                try checkedInt64(observation.residentBytes)
            )
            guard !overflow else { throw ScopeFailure.incomplete }
            providerBytes = next
        }
        return try .init(
            appBytes: appBytes,
            aiWorkerBytes: workerBytes,
            providerBytes: providerBytes
        )
    }

    private func providerTreeSnapshot(
        initialProvider: Phase2QualificationProcessObservation,
        excludedRootIDs: Set<Int32>
    ) throws -> [Int32: Phase2QualificationProcessObservation] {
        var visited = excludedRootIDs
        var pending: [Phase2QualificationProcessObservation] = [initialProvider]
        var snapshot: [Int32: Phase2QualificationProcessObservation] = [:]

        while let initial = pending.popLast() {
            guard let children = try observer.childProcessIDs(of: initial.processID),
                  children.count <= Self.maximumScopedProcessCount,
                  Set(children).count == children.count
            else { throw ScopeFailure.incomplete }

            for childID in children {
                guard childID > 0,
                      !visited.contains(childID),
                      visited.count < Self.maximumScopedProcessCount,
                      let child = try observer.observation(processID: childID),
                      child.processID == childID,
                      child.parentProcessID == initial.processID,
                      child.hasValidIdentity
                else { throw ScopeFailure.incomplete }
                visited.insert(childID)
                pending.append(child)
            }

            guard let current = try observer.observation(processID: initial.processID),
                  current.hasValidIdentity,
                  initial.hasSameIdentity(as: current)
            else { throw ScopeFailure.incomplete }
            guard snapshot.updateValue(current, forKey: current.processID) == nil else {
                throw ScopeFailure.incomplete
            }
        }
        return snapshot
    }

    private static func haveSameIdentities(
        _ lhs: [Int32: Phase2QualificationProcessObservation],
        _ rhs: [Int32: Phase2QualificationProcessObservation]
    ) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.allSatisfy { processID, observation in
            rhs[processID].map { observation.hasSameIdentity(as: $0) } == true
        }
    }

    private func revalidate(
        _ binding: Phase2QualificationProcessScopeBinding.Root
    ) throws -> Phase2QualificationProcessObservation {
        guard let current = try observer.observation(processID: binding.processID),
              current.hasValidIdentity,
              binding.matches(current)
        else { throw ScopeFailure.incomplete }
        return current
    }

    private func checkedInt64(_ value: UInt64) throws -> Int64 {
        guard value <= UInt64(Int64.max) else { throw ScopeFailure.incomplete }
        return Int64(value)
    }
}

private struct Phase2QualificationExecutableFileState: Hashable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init?(_ value: stat) {
        let deviceID = UInt64(truncatingIfNeeded: value.st_dev)
        let fileID = UInt64(value.st_ino)
        guard deviceID > 0, fileID > 0, value.st_size >= 0 else { return nil }
        self.deviceID = deviceID
        self.fileID = fileID
        size = Int64(value.st_size)
        modificationSeconds = Int64(value.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(value.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

private final class Phase2QualificationExecutableIdentityCache: @unchecked Sendable {
    private static let maximumEntries = 4_096
    private var values: [
        Phase2QualificationExecutableFileState: Phase2QualificationExecutableIdentity
    ] = [:]
    private let lock = NSLock()

    func value(
        for state: Phase2QualificationExecutableFileState
    ) -> Phase2QualificationExecutableIdentity? {
        lock.lock(); defer { lock.unlock() }
        return values[state]
    }

    func insert(
        _ identity: Phase2QualificationExecutableIdentity,
        for state: Phase2QualificationExecutableFileState
    ) {
        lock.lock(); defer { lock.unlock() }
        if values[state] == nil, values.count >= Self.maximumEntries {
            values.removeAll(keepingCapacity: true)
        }
        values[state] = identity
    }
}

/// Production observer backed only by public Darwin and libproc interfaces.
struct Phase2QualificationLibprocProcessObserver: Phase2QualificationProcessObserving,
    Sendable
{
    private static let maximumEnumerationBytes = 1_048_576
    private static let enumerationSlackBytes = 256
    /// The libproc path-buffer size is a compound C macro that Swift 6 cannot import. libproc
    /// defines that value as four times the supported Darwin `MAXPATHLEN` constant.
    private static let executablePathBufferSize = 4 * Int(MAXPATHLEN)
    private let executableCache = Phase2QualificationExecutableIdentityCache()

    init() {}

    func observation(
        processID: Int32
    ) throws -> Phase2QualificationProcessObservation? {
        guard processID > 0,
              let before = taskAllInfo(processID: processID),
              let firstPath = executablePath(processID: processID),
              let executable = executableIdentity(path: firstPath),
              let secondPath = executablePath(processID: processID),
              firstPath == secondPath,
              let after = taskAllInfo(processID: processID),
              sameProcessIdentity(before.pbsd, after.pbsd),
              after.pbsd.pbi_pid == UInt32(processID),
              after.pbsd.pbi_ppid <= UInt32(Int32.max)
        else { return nil }

        let observation = Phase2QualificationProcessObservation(
            processID: processID,
            parentProcessID: Int32(after.pbsd.pbi_ppid),
            startIdentity: .init(
                seconds: after.pbsd.pbi_start_tvsec,
                microseconds: after.pbsd.pbi_start_tvusec
            ),
            executableIdentity: executable,
            residentBytes: after.ptinfo.pti_resident_size
        )
        return observation.hasValidIdentity ? observation : nil
    }

    func childProcessIDs(of processID: Int32) throws -> [Int32]? {
        guard processID > 0,
              let first = childSnapshot(parentProcessID: processID),
              let second = childSnapshot(parentProcessID: processID),
              first == second
        else { return nil }
        return first
    }

    private func taskAllInfo(processID: Int32) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let expected = Int32(MemoryLayout<proc_taskallinfo>.size)
        let count = proc_pidinfo(
            processID,
            PROC_PIDTASKALLINFO,
            0,
            &info,
            expected
        )
        return count == expected ? info : nil
    }

    private func executablePath(processID: Int32) -> [CChar]? {
        var path = [CChar](repeating: 0, count: Self.executablePathBufferSize)
        let count = path.withUnsafeMutableBytes { buffer in
            proc_pidpath(processID, buffer.baseAddress, UInt32(buffer.count))
        }
        guard count > 0, Int(count) < path.count else { return nil }
        path[Int(count)] = 0
        return path
    }

    private func executableIdentity(
        path: [CChar]
    ) -> Phase2QualificationExecutableIdentity? {
        var pathStateBefore = stat()
        guard path.withUnsafeBufferPointer({ buffer in
            Darwin.lstat(buffer.baseAddress, &pathStateBefore)
        }) == 0,
              (pathStateBefore.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              let pathIdentityBefore = Phase2QualificationExecutableFileState(pathStateBefore),
              let stream = path.withUnsafeBufferPointer({ buffer in
                  Darwin.fopen(buffer.baseAddress, "re")
              })
        else { return nil }
        defer { Darwin.fclose(stream) }
        let descriptor = Darwin.fileno(stream)
        guard descriptor >= 0 else { return nil }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              let beforeState = Phase2QualificationExecutableFileState(before),
              beforeState == pathIdentityBefore
        else { return nil }
        if let cached = executableCache.value(for: beforeState) {
            var after = stat()
            var pathStateAfter = stat()
            guard fstat(descriptor, &after) == 0,
                  let afterState = Phase2QualificationExecutableFileState(after),
                  afterState == beforeState,
                  path.withUnsafeBufferPointer({ buffer in
                      Darwin.lstat(buffer.baseAddress, &pathStateAfter)
                  }) == 0,
                  Phase2QualificationExecutableFileState(pathStateAfter) == beforeState
            else { return nil }
            return cached
        }

        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            hasher.update(data: Data(bytes.prefix(count)))
        }
        var after = stat()
        var pathStateAfter = stat()
        guard fstat(descriptor, &after) == 0,
              let afterState = Phase2QualificationExecutableFileState(after),
              afterState == beforeState,
              path.withUnsafeBufferPointer({ buffer in
                  Darwin.lstat(buffer.baseAddress, &pathStateAfter)
              }) == 0,
              Phase2QualificationExecutableFileState(pathStateAfter) == beforeState
        else { return nil }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let identity = Phase2QualificationExecutableIdentity(
            deviceID: beforeState.deviceID,
            fileID: beforeState.fileID,
            sha256: digest
        )
        executableCache.insert(identity, for: beforeState)
        return identity
    }

    private func childSnapshot(parentProcessID: Int32) -> [Int32]? {
        let required = proc_listpids(
            UInt32(PROC_PPID_ONLY), UInt32(parentProcessID), nil, 0
        )
        guard required >= 0,
              Int(required) <= Self.maximumEnumerationBytes - Self.enumerationSlackBytes
        else { return nil }
        let requestedBytes = max(
            Int(required) + Self.enumerationSlackBytes,
            Self.enumerationSlackBytes
        )
        let capacity = (requestedBytes + MemoryLayout<Int32>.size - 1)
            / MemoryLayout<Int32>.size
        var processIDs = [Int32](repeating: 0, count: capacity)
        let actual = processIDs.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_PPID_ONLY),
                UInt32(parentProcessID),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard actual >= 0,
              Int(actual) < processIDs.count * MemoryLayout<Int32>.size,
              Int(actual).isMultiple(of: MemoryLayout<Int32>.size)
        else { return nil }
        let count = Int(actual) / MemoryLayout<Int32>.size
        let result = Array(processIDs.prefix(count))
        guard result.allSatisfy({ $0 > 0 }), Set(result).count == result.count else {
            return nil
        }
        return result.sorted()
    }

    private func sameProcessIdentity(_ lhs: proc_bsdinfo, _ rhs: proc_bsdinfo) -> Bool {
        lhs.pbi_pid == rhs.pbi_pid
            && lhs.pbi_ppid == rhs.pbi_ppid
            && lhs.pbi_start_tvsec == rhs.pbi_start_tvsec
            && lhs.pbi_start_tvusec == rhs.pbi_start_tvusec
    }

}
