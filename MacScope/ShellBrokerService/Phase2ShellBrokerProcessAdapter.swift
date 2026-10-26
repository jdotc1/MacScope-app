import Darwin
import Foundation
#if TESTING_SHELL_BROKER_PRINCIPAL
@testable import MacScope
#endif

/// Minimal real process bridge for the Phase 2 ShellBroker.
///
/// This adapter deliberately stops short of terminal rendering, XPC command dispatch, input
/// forwarding, resize, and transcript streaming. Its job is to prove the process-ownership seam
/// with a real broker-owned pseudo-terminal: a validated launch plan allocates one PTY, creates one
/// owned process bound to the PTY slave side, observes the exact executable path for that PID, and
/// can produce cleanup evidence for that same process object.
final class Phase2ShellBrokerProcessAdapter: @unchecked Sendable {
    enum LaunchError: Error, Equatable {
        case invalidLaunchPlan([Phase2HumanPTYLaunchPlanValidationIssue])
        case ptyAllocationFailed(String)
        case runFailed(String)
        case processGroupIsolationFailed(processIdentifier: Int32)
        case executablePathObservationFailed(processIdentifier: Int32)
        case executablePathMismatch(expected: String, actual: String)
    }

    func launch(_ plan: Phase2HumanPTYLaunchPlan, sourceExecutionHandshake: Bool = false)
        throws -> Phase2ShellBrokerProcessLease {
        let validation = Phase2HumanPTYLaunchPlanValidator.validate(plan)
        guard validation.isAccepted else {
            throw LaunchError.invalidLaunchPlan(validation.issues)
        }

        let pty: Phase2ShellBrokerPTYAllocation
        do {
            pty = try Phase2ShellBrokerPTYAllocator.allocate(initialSize: plan.initialSize)
        } catch {
            throw LaunchError.ptyAllocationFailed(error.localizedDescription)
        }

        let processIdentifier: Int32
        do {
            processIdentifier = try Self.spawn(plan: plan, pty: pty)
        } catch let error as LaunchError {
            pty.close()
            throw error
        } catch {
            pty.close()
            throw LaunchError.runFailed(String(describing: error))
        }
        let spawnedProcess = Phase2ShellBrokerSpawnedProcess(processIdentifier: processIdentifier)

        guard processIdentifier > 1, Darwin.getpgid(processIdentifier) == processIdentifier else {
            pty.close()
            cleanupFailedLaunch(spawnedProcess, processIdentifier: processIdentifier)
            throw LaunchError.processGroupIsolationFailed(processIdentifier: processIdentifier)
        }
        let observedPath: String
        do {
            observedPath = try Self.executablePath(for: processIdentifier)
        } catch {
            pty.close()
            cleanupFailedLaunch(spawnedProcess, processIdentifier: processIdentifier)
            throw LaunchError.executablePathObservationFailed(processIdentifier: processIdentifier)
        }

        guard observedPath == plan.executablePath else {
            pty.close()
            cleanupFailedLaunch(spawnedProcess, processIdentifier: processIdentifier)
            throw LaunchError.executablePathMismatch(expected: plan.executablePath, actual: observedPath)
        }

        if sourceExecutionHandshake {
            // Opening the slave during spawn resets macOS PTY settings. The exact owned launcher
            // waits for the broker ACK, so establish and verify raw input after that open.
            do { try pty.configureSourceExecutionHandshake() }
            catch {
                pty.close()
                cleanupFailedLaunch(spawnedProcess, processIdentifier: processIdentifier)
                throw LaunchError.ptyAllocationFailed(error.localizedDescription)
            }
        }

        let ownedProcess = Phase2ShellBrokerOwnedProcess(
            sessionID: plan.sessionID,
            requestID: plan.requestID,
            processIdentifier: processIdentifier,
            executablePath: observedPath
        )
        return Phase2ShellBrokerProcessLease(
            plan: plan,
            process: spawnedProcess,
            ownedProcess: ownedProcess,
            pty: pty
        )
    }

    private static func spawn(plan: Phase2HumanPTYLaunchPlan, pty: Phase2ShellBrokerPTYAllocation) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            if actions != nil { posix_spawn_file_actions_destroy(&actions) }
            if attributes != nil { posix_spawnattr_destroy(&attributes) }
            throw LaunchError.runFailed("posix_spawn initialization failed")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var status = posix_spawn_file_actions_addopen(
            &actions,
            STDIN_FILENO,
            pty.slavePath,
            O_RDWR,
            0
        )
        guard status == 0 else { throw LaunchError.runFailed(Self.spawnError(status)) }
        for targetDescriptor in [STDOUT_FILENO, STDERR_FILENO] {
            status = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, targetDescriptor)
            guard status == 0 else { throw LaunchError.runFailed(Self.spawnError(status)) }
        }
        if let workingDirectoryPath = plan.workingDirectoryPath {
            let status = posix_spawn_file_actions_addchdir(&actions, workingDirectoryPath)
            guard status == 0 else { throw LaunchError.runFailed(Self.spawnError(status)) }
        }

        // XPC worker threads can block control signals. The owned shell and its descendants
        // must receive their own signals instead of inheriting that thread's delivery mask.
        var signalMask = sigset_t()
        _ = sigemptyset(&signalMask)
        status = posix_spawnattr_setsigmask(&attributes, &signalMask)
        guard status == 0 else { throw LaunchError.runFailed(Self.spawnError(status)) }

        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK)
        status = posix_spawnattr_setflags(&attributes, flags)
        guard status == 0 else { throw LaunchError.runFailed(Self.spawnError(status)) }

        let environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        let environmentStrings = environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
        var processIdentifier: pid_t = 0
        try withMutableCStringArray([plan.executablePath] + plan.arguments) { arguments in
            try withMutableCStringArray(environmentStrings) { environment in
                status = posix_spawn(
                    &processIdentifier,
                    plan.executablePath,
                    &actions,
                    &attributes,
                    arguments,
                    environment
                )
                guard status == 0 else { throw LaunchError.runFailed(Self.spawnError(status)) }
            }
        }
        return processIdentifier
    }

    private static func spawnError(_ status: Int32) -> String {
        String(cString: strerror(status))
    }

    private static func executablePath(for processIdentifier: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let byteCount = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard byteCount > 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        return String(cString: buffer)
    }
}

final class Phase2ShellBrokerProcessLease: @unchecked Sendable {
    enum ControlError: Error, Equatable {
        case processNotRunning(processIdentifier: Int32)
        case unsupportedSignal(Phase2HumanPTYSignal)
        case signalFailed(signal: Phase2HumanPTYSignal, errno: Int32)
    }

    let plan: Phase2HumanPTYLaunchPlan
    let ownedProcess: Phase2ShellBrokerOwnedProcess
    let pty: Phase2ShellBrokerPTYAllocation

    private let process: Phase2ShellBrokerSpawnedProcess
    private let controlLock = NSLock()
    private var completedCleanupProof: Phase2ShellBrokerCleanupProof?

    fileprivate init(
        plan: Phase2HumanPTYLaunchPlan,
        process: Phase2ShellBrokerSpawnedProcess,
        ownedProcess: Phase2ShellBrokerOwnedProcess,
        pty: Phase2ShellBrokerPTYAllocation
    ) {
        self.plan = plan
        self.process = process
        self.ownedProcess = ownedProcess
        self.pty = pty
    }

    var isRunning: Bool {
        controlLock.withLock {
            completedCleanupProof == nil && process.ownedProcessGroupExists
        }
    }

    var observedTerminalOutcomeIfExited: Phase2HumanPTYTerminalOutcome? {
        controlLock.withLock {
            if let completedCleanupProof { return completedCleanupProof.outcome }
            guard !process.ownedProcessGroupExists else { return nil }
            return process.terminalOutcome
        }
    }

    func terminalOutcomeAfterObservedExit(timeout: TimeInterval = 0.02) -> Phase2HumanPTYTerminalOutcome? {
        controlLock.withLock {
            guard completedCleanupProof == nil, !process.ownedProcessGroupExists,
                  process.waitForLeaderExit(timeout: timeout) else { return nil }
            return process.terminalOutcome
        }
    }

    func readAvailablePTYOutput(maxBytes: Int = 4_096, timeout: TimeInterval = 0.5) -> [UInt8] {
        controlLock.withLock {
            guard completedCleanupProof == nil else { return [] }
            return pty.readAvailable(maxBytes: maxBytes, timeout: timeout)
        }
    }

    func writeInput(_ bytes: [UInt8]) throws -> Int {
        try controlLock.withLock {
            guard completedCleanupProof == nil, process.ownedProcessGroupExists else {
                throw ControlError.processNotRunning(processIdentifier: ownedProcess.processIdentifier)
            }
            return try pty.writeInput(bytes)
        }
    }

    func resizeTerminal(_ size: Phase2HumanPTYTerminalSize) throws {
        try controlLock.withLock {
            guard completedCleanupProof == nil, process.ownedProcessGroupExists else {
                throw ControlError.processNotRunning(processIdentifier: ownedProcess.processIdentifier)
            }
            try pty.resize(size)
        }
    }

    func sendSignal(_ signal: Phase2HumanPTYSignal) throws {
        try controlLock.withLock {
            guard completedCleanupProof == nil, process.ownedProcessGroupExists else {
                throw ControlError.processNotRunning(processIdentifier: ownedProcess.processIdentifier)
            }
            let signalNumber: Int32
            switch signal {
            case .interrupt:
                signalNumber = SIGINT
            case .terminate:
                signalNumber = SIGTERM
            case .suspend:
                signalNumber = SIGTSTP
            case .continueSignal:
                signalNumber = SIGCONT
            }
            let foreground = try pty.foregroundProcessGroup(ownedSessionID: ownedProcess.processIdentifier)
                ?? ownedProcess.processIdentifier
            guard Darwin.kill(-foreground, signalNumber) == 0 else {
                throw ControlError.signalFailed(signal: signal, errno: errno)
            }
        }
    }

    func cleanup(
        outcome: Phase2HumanPTYTerminalOutcome = .canceled,
        timeout: TimeInterval = 2.0
    ) -> Phase2ShellBrokerCleanupProof {
        controlLock.withLock {
            if let completedCleanupProof { return completedCleanupProof }
            // Job-control foreground groups differ from the interactive shell's group.
            // Stop that exact PTY/session-owned job first, allowing its parent shell to reap it.
            let foregroundAbsent = cleanupForegroundJob(timeout: timeout)
            if process.ownedProcessGroupExists {
                terminateProcessGroupOrLeader(ownedProcess.processIdentifier)
            }
            // Tear down the owned terminal before waiting for its leader. In the
            // persistent LaunchAgent path a shell may remain in terminal I/O until
            // the master closes, even after the termination request. Foreground
            // ownership has already been checked and its cleanup attempted above.
            pty.close()
            let observedAbsent = waitForOwnedProcessGroupExit(timeout: timeout) && foregroundAbsent
            let proof = Phase2ShellBrokerCleanupProof(
                sessionID: ownedProcess.sessionID,
                requestID: ownedProcess.requestID,
                processIdentifier: ownedProcess.processIdentifier,
                observedProcessAbsent: observedAbsent,
                outcome: outcome
            )
            completedCleanupProof = proof
            return proof
        }
    }

    func closePTYAfterObservedExit() {
        controlLock.withLock {
            guard completedCleanupProof == nil else { return }
            _ = process.waitForLeaderExit(timeout: 0)
            pty.close()
        }
    }

    private func cleanupForegroundJob(timeout: TimeInterval) -> Bool {
        let owner = ownedProcess.processIdentifier
        guard let group = try? pty.foregroundProcessGroup(ownedSessionID: owner), group != owner else { return true }
        func stillOwned() -> Bool { Darwin.getsid(group) == owner && processGroupExists(group) }
        guard stillOwned() else { return !processGroupExists(group) }
        _ = Darwin.kill(-group, SIGTERM)
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while stillOwned(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if stillOwned() { _ = Darwin.kill(-group, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(1)
        while stillOwned(), Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
        // A departed group leader does not prove that all group members departed.
        // Lost session identity prevents further signaling, but must never certify absence.
        return !processGroupExists(group)
    }

    private func waitForOwnedProcessGroupExit(timeout: TimeInterval) -> Bool {
        if waitForOwnedProcessGroupAbsence(process, timeout: timeout) {
            _ = process.waitForLeaderExit(timeout: 0)
            return true
        }
        _ = Darwin.kill(-ownedProcess.processIdentifier, SIGKILL)
        let groupAbsent = waitForOwnedProcessGroupAbsence(process, timeout: 1.0)
        _ = process.waitForLeaderExit(timeout: 1.0)
        return groupAbsent
    }
}

private final class Phase2ShellBrokerSpawnedProcess: @unchecked Sendable {
    let processIdentifier: Int32

    private let condition = NSCondition()
    private var leaderRunning = true
    private var groupMayExist = true
    private var observedOutcome: Phase2HumanPTYTerminalOutcome?

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = Darwin.waitpid(processIdentifier, &status, 0)
            } while result < 0 && errno == EINTR

            condition.lock()
            leaderRunning = false
            if !processGroupExists(processIdentifier) {
                groupMayExist = false
            }
            observedOutcome = result == processIdentifier ? Self.outcome(fromWaitStatus: status) : .outcomeUnknown
            condition.broadcast()
            condition.unlock()
        }
    }

    var isLeaderRunning: Bool {
        condition.withLock { leaderRunning }
    }

    var terminalOutcome: Phase2HumanPTYTerminalOutcome? {
        condition.withLock { observedOutcome }
    }

    var ownedProcessGroupExists: Bool {
        condition.lock()
        guard groupMayExist else {
            condition.unlock()
            return false
        }
        condition.unlock()

        let exists = processGroupExists(processIdentifier)
        if !exists {
            condition.withLock { groupMayExist = false }
        }
        return exists
    }

    func waitForLeaderExit(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard leaderRunning else { return true }
        guard timeout > 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while leaderRunning, condition.wait(until: deadline) {}
        return !leaderRunning
    }

    private static func outcome(fromWaitStatus status: Int32) -> Phase2HumanPTYTerminalOutcome {
        let lowBits = status & 0x7f
        if lowBits == 0 {
            return .exited(status: (status >> 8) & 0xff)
        }
        let signalNumber = lowBits
        switch signalNumber {
        case SIGINT: return .signaled(.interrupt)
        case SIGTERM: return .signaled(.terminate)
        case SIGTSTP: return .signaled(.suspend)
        case SIGCONT: return .signaled(.continueSignal)
        default: return .outcomeUnknown
        }
    }
}

final class Phase2ShellBrokerPTYAllocation: @unchecked Sendable {
    enum IOError: Error, Equatable {
        case closed
        case emptyInput
        case invalidResize(Phase2HumanPTYTerminalSize)
        case descriptorDuplicationFailed(errno: Int32)
        case writeFailed(errno: Int32, bytesWritten: Int)
        case resizeFailed(errno: Int32)
    }

    let slavePath: String
    let initialSize: Phase2HumanPTYTerminalSize

    private let lock = NSLock()
    private var masterFileDescriptor: Int32?
#if TESTING_SHELL_BROKER_PRINCIPAL
    var masterOperationWillExecute: (@Sendable (Int32) -> Void)?
#endif

    init(
        masterFileDescriptor: Int32,
        slavePath: String,
        initialSize: Phase2HumanPTYTerminalSize
    ) {
        self.masterFileDescriptor = masterFileDescriptor
        self.slavePath = slavePath
        self.initialSize = initialSize
    }

    deinit {
        close()
    }

    func readAvailable(maxBytes: Int, timeout: TimeInterval) -> [UInt8] {
        guard maxBytes > 0 else { return [] }

        lock.lock()
        defer { lock.unlock() }
        let descriptor = masterFileDescriptor
        guard let descriptor else { return [] }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let timeoutMilliseconds = Int32(max(0, timeout * 1_000))
        let ready = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        let readableEvents = Int16(POLLIN | POLLHUP)
        guard ready > 0, (pollDescriptor.revents & readableEvents) != 0 else { return [] }

        let byteCount = min(maxBytes, 64 * 1_024)
        var buffer = [UInt8](repeating: 0, count: byteCount)
        let readCount = Darwin.read(descriptor, &buffer, byteCount)
        guard readCount > 0 else { return [] }
        return Array(buffer.prefix(Int(readCount)))
    }

    func writeInput(_ bytes: [UInt8]) throws -> Int {
        guard !bytes.isEmpty else { throw IOError.emptyInput }
        return try withMasterFileDescriptor { descriptor in
            var bytesWritten = 0
            while bytesWritten < bytes.count {
                let writeCount = bytes.withUnsafeBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: bytesWritten),
                        bytes.count - bytesWritten
                    )
                }
                if writeCount > 0 {
                    bytesWritten += writeCount
                    continue
                }
                if writeCount < 0, errno == EINTR {
                    continue
                }
                throw IOError.writeFailed(errno: writeCount == 0 ? EIO : errno, bytesWritten: bytesWritten)
            }
            return bytesWritten
        }
    }

    /// Resolve only a foreground group in the exact session established by our owned shell.
    /// The PTY descriptor and getsid join prevent a process-group proposal from targeting outsiders.
    func foregroundProcessGroup(ownedSessionID: Int32) throws -> Int32? {
        try withMasterFileDescriptor { descriptor in
            let group = Darwin.tcgetpgrp(descriptor)
            guard group > 1, Darwin.getsid(group) == ownedSessionID else { return nil }
            return group
        }
    }

    func resize(_ size: Phase2HumanPTYTerminalSize) throws {
        guard size.isValid else { throw IOError.invalidResize(size) }
        try withMasterFileDescriptor { descriptor in
            var windowSize = winsize(
                ws_row: UInt16(size.rows),
                ws_col: UInt16(size.columns),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            guard Darwin.ioctl(descriptor, UInt(TIOCSWINSZ), &windowSize) == 0 else {
                throw IOError.resizeFailed(errno: errno)
            }
        }
    }

    /// Raw input without echo permits an exact launcher ACK after ownership observation.
    func configureSourceExecutionHandshake() throws {
        try withMasterFileDescriptor { descriptor in
            var settings = termios()
            guard tcgetattr(descriptor, &settings) == 0 else { throw IOError.closed }
            cfmakeraw(&settings)
            withUnsafeMutableBytes(of: &settings.c_cc) { bytes in
                bytes[Int(VMIN)] = 1
                bytes[Int(VTIME)] = 0
            }
            guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else { throw IOError.closed }
            var observed = termios()
            guard tcgetattr(descriptor, &observed) == 0,
                  observed.c_iflag == settings.c_iflag, observed.c_oflag == settings.c_oflag,
                  observed.c_cflag == settings.c_cflag, observed.c_lflag == settings.c_lflag else {
                throw IOError.closed
            }
            let controls = withUnsafeBytes(of: observed.c_cc) { Array($0) }
            guard controls[Int(VMIN)] == 1, controls[Int(VTIME)] == 0 else { throw IOError.closed }
        }
    }

    private func withMasterFileDescriptor<Result>(
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        let operationDescriptor = try lock.withLock {
            guard let descriptor = masterFileDescriptor else { throw IOError.closed }
            let duplicated = Darwin.dup(descriptor)
            guard duplicated >= 0 else { throw IOError.descriptorDuplicationFailed(errno: errno) }
            return duplicated
        }
        defer { Darwin.close(operationDescriptor) }
#if TESTING_SHELL_BROKER_PRINCIPAL
        masterOperationWillExecute?(operationDescriptor)
#endif
        return try operation(operationDescriptor)
    }

    func close() {
        let descriptor = lock.withLock {
            let descriptor = masterFileDescriptor
            masterFileDescriptor = nil
            return descriptor
        }
        if let descriptor {
            Darwin.close(descriptor)
        }
    }
}

enum Phase2ShellBrokerPTYAllocator {
    enum AllocationError: LocalizedError, Equatable {
        case invalidInitialSize(Phase2HumanPTYTerminalSize)
        case openPTYFailed(errno: Int32)
        case slavePathUnavailable
        case sizeConfigurationFailed(errno: Int32)
        case nonblockingConfigurationFailed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .invalidInitialSize(let size):
                "invalid initial PTY size \(size.columns)x\(size.rows)"
            case .openPTYFailed(let errno):
                "openpty failed with errno \(errno)"
            case .slavePathUnavailable:
                "openpty did not return a slave path"
            case .nonblockingConfigurationFailed(let errno):
                "PTY nonblocking configuration failed with errno \(errno)"
            case .sizeConfigurationFailed(let errno):
                "PTY size configuration failed with errno \(errno)"
            }
        }
    }

    static func allocate(initialSize: Phase2HumanPTYTerminalSize) throws -> Phase2ShellBrokerPTYAllocation {
        guard initialSize.isValid else {
            throw AllocationError.invalidInitialSize(initialSize)
        }

        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 1_024)
        var term = termios()
        var size = winsize(
            ws_row: UInt16(initialSize.rows),
            ws_col: UInt16(initialSize.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&master, &slave, &name, &term, &size) == 0 else {
            throw AllocationError.openPTYFailed(errno: errno)
        }
        Darwin.close(slave)

        // dup() shares these status flags. Every input operation must release the lease's
        // control lock on backpressure so signals and bounded cleanup remain available.
        let flags = Darwin.fcntl(master, F_GETFL)
        guard flags >= 0, Darwin.fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let capturedErrno = errno
            Darwin.close(master)
            throw AllocationError.nonblockingConfigurationFailed(errno: capturedErrno)
        }
        let verifiedFlags = Darwin.fcntl(master, F_GETFL)
        guard verifiedFlags >= 0, verifiedFlags & O_NONBLOCK != 0 else {
            let capturedErrno = verifiedFlags < 0 ? errno : EIO
            Darwin.close(master)
            throw AllocationError.nonblockingConfigurationFailed(errno: capturedErrno)
        }

        let slavePath = String(cString: name)
        guard !slavePath.isEmpty else {
            Darwin.close(master)
            throw AllocationError.slavePathUnavailable
        }

        if Darwin.ioctl(master, UInt(TIOCSWINSZ), &size) != 0 {
            let capturedErrno = errno
            Darwin.close(master)
            throw AllocationError.sizeConfigurationFailed(errno: capturedErrno)
        }

        return Phase2ShellBrokerPTYAllocation(
            masterFileDescriptor: master,
            slavePath: slavePath,
            initialSize: initialSize
        )
    }
}

private func terminateProcessGroupOrLeader(_ processIdentifier: Int32) {
    guard processIdentifier > 1 else { return }
    if Darwin.getpgid(processIdentifier) == processIdentifier {
        _ = Darwin.kill(-processIdentifier, SIGTERM)
    } else {
        _ = Darwin.kill(processIdentifier, SIGTERM)
    }
}

private func cleanupFailedLaunch(
    _ process: Phase2ShellBrokerSpawnedProcess,
    processIdentifier: Int32
) {
    terminateProcessGroupOrLeader(processIdentifier)
    if process.ownedProcessGroupExists {
        _ = waitForOwnedProcessGroupAbsence(process, timeout: 0.2)
    }
    if process.ownedProcessGroupExists {
        if Darwin.getpgid(processIdentifier) == processIdentifier {
            _ = Darwin.kill(-processIdentifier, SIGKILL)
        } else {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
    _ = process.waitForLeaderExit(timeout: 1.0)
}

private func processGroupExists(_ processGroupIdentifier: Int32) -> Bool {
    guard processGroupIdentifier > 1 else { return false }
    errno = 0
    if Darwin.kill(-processGroupIdentifier, 0) == 0 { return true }
    return errno == EPERM
}

private func waitForOwnedProcessGroupAbsence(
    _ process: Phase2ShellBrokerSpawnedProcess,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(max(0, timeout))
    while process.ownedProcessGroupExists, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    return !process.ownedProcessGroupExists
}

private func withMutableCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) throws -> Result {
    let pointers = strings.map { strdup($0) }
    guard pointers.allSatisfy({ $0 != nil }) else {
        pointers.forEach { free($0) }
        throw Phase2ShellBrokerProcessAdapter.LaunchError.runFailed("argument allocation failed")
    }
    defer { pointers.forEach { free($0) } }
    var terminatedPointers = pointers + [nil]
    return try terminatedPointers.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
