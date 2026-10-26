import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Tier-3 DEBUGGER-DEPTH authoring layer for attach-to-PID.
///
/// Mirrors the existing debugger model idiom (pure value types, `Equatable`,
/// parsing / validation expressed as static factories that return a normalized
/// request or a human-readable rejection reason). Keeping the validation here
/// makes `DebuggerPanelViewModel` thin and leaves every non-UI decision
/// unit-testable without touching SwiftUI or a live LLDB transport.
///
/// The attach surface honors MacScope's deliberate signed-target/attach policy:
/// the parser and process lister never themselves attach or escalate; an attach
/// that the backend (or the OS) declines surfaces a typed error, never a silent
/// fake-success.

// MARK: - Validated attach-by-PID request

/// A normalized, validated request to attach the debugger to a running process
/// by numeric PID.
///
/// Validation rejects:
///  * non-numeric / empty input,
///  * a non-positive PID (`<= 0`),
///  * MacScope's own PID (you cannot self-attach the host process),
///  * a PID outside the representable `pid_t` (`Int32`) range.
///
/// This legacy UI value never authorizes a debugger transport command. Production
/// attach first upgrades a selection to `DebuggerLocalAttachRequest`, whose
/// immutable observed process identity is revalidated at the exact-attach seam.
struct DebuggerAttachPIDRequest: Equatable {
    let processID: Int32

    var displayName: String {
        "pid \(processID)"
    }

    /// The underlying `DebuggerAttachRequest` (the shared target-selection model)
    /// for this validated PID.
    var attachRequest: DebuggerAttachRequest {
        DebuggerAttachRequest(target: .processID(processID))
    }

    private init(processID: Int32) {
        self.processID = processID
    }

    /// Parses raw author input (a free-form PID text field) into a validated
    /// request. `selfProcessID` defaults to the current process so a self-attach
    /// is rejected; it is injectable for headless testing.
    static func parse(
        _ rawText: String,
        selfProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> Result<DebuggerAttachPIDRequest, DebuggerAuthoringParseError> {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalid("Enter a process ID before attaching."))
        }

        // `Int32(_:)` rejects non-numeric input and anything outside the pid_t
        // range, so a value like "99999999999" or "12a" never slips through.
        guard let processID = Int32(trimmed) else {
            return .failure(.invalid("Process ID \(trimmed) is not a valid pid."))
        }

        guard processID > 0 else {
            return .failure(.invalid("Process ID must be a positive number."))
        }

        guard processID != selfProcessID else {
            return .failure(.invalid("MacScope cannot attach its own process (pid \(processID))."))
        }

        return .success(DebuggerAttachPIDRequest(processID: processID))
    }

    /// Validates an already-numeric PID (for example one chosen from the process
    /// list), reusing the same rejection rules as the text parser.
    static func validate(
        processID: Int32,
        selfProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> Result<DebuggerAttachPIDRequest, DebuggerAuthoringParseError> {
        parse(String(processID), selfProcessID: selfProcessID)
    }
}

// MARK: - Running-process enumeration (injectable, fake-testable)

/// One candidate running process surfaced to the attach picker.
struct DebuggerProcessListEntry: Identifiable, Equatable {
    var processID: Int32
    var name: String

    var id: Int32 { processID }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "pid \(processID)" : trimmed
    }

    var detail: String {
        "pid \(processID)"
    }
}

enum DebuggerProcessListError: LocalizedError, Equatable {
    case enumerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .enumerationFailed(let reason):
            return reason
        }
    }
}

/// Injectable seam for enumerating running processes. The real implementation
/// reads the kernel process table via `sysctl(KERN_PROC_ALL)`; tests inject a
/// fake so the picker logic is exercised headlessly. The provider is read-only:
/// it never attaches, signals, or escalates — it only lists pid + name.
protocol DebuggerProcessLister {
    func listProcesses() throws -> [DebuggerProcessListEntry]
}

/// Clean-room running-process enumeration via the BSD `sysctl` `KERN_PROC_ALL`
/// table. This is a read-only listing call (`CTL_KERN`/`KERN_PROC`); it performs
/// no attach, ptrace, or task_for_pid. Entries are sorted by descending PID so
/// the most-recently-started processes surface first, and MacScope's own PID is
/// dropped (you cannot self-attach).
struct SysctlDebuggerProcessLister: DebuggerProcessLister {
    private let selfProcessID: Int32

    init(selfProcessID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.selfProcessID = selfProcessID
    }

    func listProcesses() throws -> [DebuggerProcessListEntry] {
        #if canImport(Darwin)
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0

        // First call sizes the buffer; second call fills it. A process table that
        // changes between the two calls can make the second call fail with ENOMEM,
        // so retry a bounded number of times before surfacing a typed error.
        for _ in 0..<4 {
            guard sysctl(&name, UInt32(name.count), nil, &length, nil, 0) == 0 else {
                throw DebuggerProcessListError.enumerationFailed(
                    "Could not size the process table: \(String(cString: strerror(errno)))."
                )
            }

            guard length > 0 else {
                return []
            }

            let entryStride = MemoryLayout<kinfo_proc>.stride
            let capacity = length / entryStride + 1
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var filledLength = capacity * entryStride

            let result = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
                sysctl(&name, UInt32(name.count), rawBuffer.baseAddress, &filledLength, nil, 0)
            }

            if result != 0 {
                if errno == ENOMEM {
                    // The table grew; re-size and retry.
                    continue
                }
                throw DebuggerProcessListError.enumerationFailed(
                    "Could not read the process table: \(String(cString: strerror(errno)))."
                )
            }

            let count = filledLength / entryStride
            var entries: [DebuggerProcessListEntry] = []
            entries.reserveCapacity(count)
            for index in 0..<count {
                var proc = buffer[index]
                let pid = proc.kp_proc.p_pid
                guard pid > 0, pid != selfProcessID else { continue }
                let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { rawName -> String in
                    let bytes = rawName.bindMemory(to: CChar.self)
                    return String(cString: bytes.baseAddress!)
                }
                entries.append(DebuggerProcessListEntry(processID: pid, name: name))
            }

            return entries.sorted { $0.processID > $1.processID }
        }

        throw DebuggerProcessListError.enumerationFailed(
            "The process table kept changing while it was read."
        )
        #else
        throw DebuggerProcessListError.enumerationFailed(
            "Process enumeration is only available on macOS."
        )
        #endif
    }
}
