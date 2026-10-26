import CryptoKit
import Darwin
import Foundation

/// A private installed-qualification barrier that makes the source-reveal TOCTOU boundary
/// observable without widening product protocols or persisting test state. The barrier is dormant
/// unless the ordinary installed-XCUITest opt-in and both dedicated, candidate-bound variables are
/// present. It emits identifiers and hashes only, then waits for one create-only release token.
enum ReconstructionInstalledSourceRevealQualificationBarrier {
    static let rootEnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_REVEAL_BARRIER_ROOT"
    static let candidateSHA256EnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_REVEAL_CANDIDATE_SHA256"
    static let runEnvironmentKey = "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"
    static let arrivalFilename = "source-reveal-action-rendered.json"
    static let releaseFilename = "source-reveal-invalidate-release"
    static let maximumWaitNanoseconds: UInt64 = 15_000_000_000

    enum Result: Equatable {
        case notRequested
        case released
        case refused
    }

    private enum ReleaseStatus {
        case absent
        case valid
        case invalid
    }

    private static let pollingNanoseconds: UInt64 = 20_000_000
    private static let rootPrefix = "MacScope-Task10-RevealBarrier-"

    /// A partial dedicated configuration is still a request and therefore fails closed. With no
    /// dedicated variables, even an opted-in installed test follows the byte-for-byte ordinary
    /// product dispatch path and performs no filesystem work.
    static func isRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard truthy(environment[runEnvironmentKey]) else { return false }
        return environment[rootEnvironmentKey] != nil
            || environment[candidateSHA256EnvironmentKey] != nil
    }

    static func waitIfRequested(
        evidenceID: UUID,
        request: ReconstructionSourceNavigationRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL
    ) async -> Result {
        guard isRequested(environment: environment) else { return .notRequested }
        guard let suppliedRoot = environment[rootEnvironmentKey],
              !suppliedRoot.isEmpty,
              let expectedCandidateSHA256 = environment[candidateSHA256EnvironmentKey],
              isLowercaseSHA256(expectedCandidateSHA256),
              let executableURL,
              let observedCandidateSHA256 = try? sha256Hex(of: executableURL),
              observedCandidateSHA256 == expectedCandidateSHA256,
              let rootDescriptor = ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(
                  suppliedRoot, prefix: rootPrefix
              ) else {
            return .refused
        }
        defer { Darwin.close(rootDescriptor) }

        guard releaseStatus(rootDescriptor: rootDescriptor) == .absent,
              createArrival(
                rootDescriptor: rootDescriptor,
                evidenceID: evidenceID,
                request: request,
                candidateSHA256: observedCandidateSHA256
              ) else {
            return .refused
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(maximumWaitNanoseconds)))
        while clock.now < deadline {
            switch releaseStatus(rootDescriptor: rootDescriptor) {
            case .valid:
                return .released
            case .invalid:
                return .refused
            case .absent:
                do {
                    try await Task.sleep(nanoseconds: pollingNanoseconds)
                } catch {
                    return .refused
                }
            }
        }
        return .refused
    }

    private static func truthy(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }

    private static func createArrival(
        rootDescriptor: Int32,
        evidenceID: UUID,
        request: ReconstructionSourceNavigationRequest,
        candidateSHA256: String
    ) -> Bool {
        let descriptor = arrivalFilename.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        let receipt: [String: Any] = [
            "analysisFingerprintSHA256": request.function.analysisFingerprintSHA256,
            "binaryID": request.function.image.binaryID.uuidString.lowercased(),
            "candidateSHA256": candidateSHA256,
            "evidenceID": evidenceID.uuidString.lowercased(),
            "imageSlot": request.function.image.imageSlot.rawValue,
            "kind": "source-reveal-action-rendered",
            "projectID": request.projectID.uuidString.lowercased(),
            "workspaceID": request.workspaceID.uuidString.lowercased(),
        ]
        guard JSONSerialization.isValidJSONObject(receipt),
              var payload = try? JSONSerialization.data(
                withJSONObject: receipt,
                options: [.sortedKeys]
              ),
              payload.count <= 4_096 else {
            return false
        }
        payload.append(0x0a)
        let didWrite = payload.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written
                )
                guard result > 0 else { return false }
                written += result
            }
            return true
        }
        return didWrite && Darwin.fsync(descriptor) == 0
    }

    private static func releaseStatus(rootDescriptor: Int32) -> ReleaseStatus {
        let descriptor = releaseFilename.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .absent : .invalid
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_size == 0,
              metadata.st_mode & 0o077 == 0 else {
            return .invalid
        }
        return .valid
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Shared only by the two dormant installed-qualification barriers. Parent authority is fixed
/// here, never obtained from caller environment variables or a caller-selected temporary root.
enum ReconstructionInstalledQualificationBarrierRoot {
    static var runnerTemporaryDirectory: URL? {
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let home: String? = buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(getuid(), &account, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let directory = account.pw_dir else { return nil }
            return String(cString: directory)
        }
        guard let home, home.hasPrefix("/"), home != "/" else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(
            "Library/Containers/org.macscope.app.MacScopeInstalledAppUITests.xctrunner/Data/tmp",
            isDirectory: true
        )
    }

    static func openOwnedRoot(_ path: String, prefix: String) -> Int32? {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let name = root.lastPathComponent
        let parent = root.deletingLastPathComponent().path
        let runnerParent = runnerTemporaryDirectory?.path
        // Foundation standardization rewrites physical /private/tmp to the /tmp symlink.
        // Exact parent/name equality plus the no-follow walk enforces physical spelling instead.
        guard !path.utf8.contains(0), path == parent + "/" + name,
              prefix == "MacScope-Task10-PauseBarrier-" || prefix == "MacScope-Task10-RevealBarrier-",
              name.hasPrefix(prefix), name.count == prefix.count + 36,
              UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
              parent == "/private/tmp" || parent == runnerParent else { return nil }

        // Walk from the filesystem root with descriptor-relative, no-follow opens so neither
        // a symlinked ancestor nor a path replacement can redirect subsequent receipt writes.
        var parentDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentDescriptor >= 0 else { return nil }
        defer { Darwin.close(parentDescriptor) }
        for component in parent.split(separator: "/") {
            let next = String(component).withCString {
                Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else { return nil }
            Darwin.close(parentDescriptor)
            parentDescriptor = next
        }
        if parent == runnerParent {
            var metadata = stat()
            guard Darwin.fstat(parentDescriptor, &metadata) == 0,
                  metadata.st_uid == getuid(), metadata.st_mode & 0o7777 == 0o700 else { return nil }
        }
        var before = stat()
        guard name.withCString({ Darwin.fstatat(parentDescriptor, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
              before.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == getuid(), before.st_mode & 0o7777 == 0o700 else { return nil }
        let descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
              opened.st_uid == before.st_uid,
              opened.st_mode & S_IFMT == S_IFDIR, opened.st_mode & 0o7777 == 0o700 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }
}
