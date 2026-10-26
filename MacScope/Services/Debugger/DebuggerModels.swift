import Foundation

enum DebuggerPauseReason: Equatable {
    case breakpoint(address: UInt64)
    case step
    case signal(String)
    case userRequested
    case unknown(String)

    var displayTitle: String {
        switch self {
        case .breakpoint(let address):
            "Breakpoint at \(address.hexAddress)"
        case .step:
            "Step completed"
        case .signal(let name):
            "Signal \(name)"
        case .userRequested:
            "Paused"
        case .unknown(let detail):
            detail
        }
    }
}

enum DebuggerProcessState: Equatable {
    case notAttached
    case launching(targetPath: String)
    case running(processID: Int32, executableName: String)
    case paused(processID: Int32, reason: DebuggerPauseReason)
    case detaching(processID: Int32)
    case batchStopped(processID: Int32?, reason: DebuggerPauseReason)
    case exited(code: Int32?)
    case unavailable(reason: String)

    var displayTitle: String {
        switch self {
        case .notAttached:
            "Not attached"
        case .launching:
            "Launching"
        case .running:
            "Running"
        case .paused:
            "Paused"
        case .detaching:
            "Detaching"
        case .batchStopped:
            "Stopped"
        case .exited:
            "Exited"
        case .unavailable:
            "Backend unavailable"
        }
    }

    var detail: String {
        switch self {
        case .notAttached:
            return "No debug process is connected."
        case .launching(let targetPath):
            return "Preparing \(URL(fileURLWithPath: targetPath).lastPathComponent)."
        case .running(let processID, let executableName):
            return "\(executableName) is running as pid \(processID)."
        case .paused(let processID, let reason):
            return "pid \(processID): \(reason.displayTitle)"
        case .detaching(let processID):
            return "Disconnecting from pid \(processID). No further debugger commands are available."
        case .batchStopped(let processID, let reason):
            let pidDetail = processID.map { "pid \($0): " } ?? ""
            return "\(pidDetail)\(reason.displayTitle). LLDB batch mode has ended; no live process control is attached."
        case .exited(let code):
            return code.map { "Process exited with code \($0)." } ?? "Process exited."
        case .unavailable(let reason):
            return reason
        }
    }

    var systemImage: String {
        switch self {
        case .notAttached:
            "pause.circle"
        case .launching:
            "hourglass"
        case .running:
            "play.circle"
        case .paused:
            "pause.circle.fill"
        case .detaching:
            "arrow.right.circle"
        case .batchStopped:
            "pause.circle"
        case .exited:
            "stop.circle"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var canLaunchNewProcess: Bool {
        switch self {
        case .notAttached, .batchStopped, .exited, .unavailable:
            true
        case .launching, .running, .paused, .detaching:
            false
        }
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

enum DebuggerBatchTargetState: Equatable {
    case unknown
    case exited(code: Int32?)
    case stopped(processID: Int32?, reason: DebuggerPauseReason)
    case error(message: String)
}

enum DebuggerBackendSessionState: Equatable {
    case disconnected
    case unavailable(reason: String)
    case discovered(toolPath: String)
    case ready(adapterName: String)
    case launching(targetPath: String)
    case connected(processID: Int32, adapterName: String)
    case disconnecting(processID: Int32, adapterName: String)
    case failed(reason: String)

    var detail: String {
        switch self {
        case .disconnected:
            "No debugger backend session is active."
        case .unavailable(let reason):
            reason
        case .discovered(let toolPath):
            "LLDB toolchain discovered at \(toolPath); process-control transport is not enabled."
        case .ready(let adapterName):
            "\(adapterName) is ready."
        case .launching(let targetPath):
            "Launching \(URL(fileURLWithPath: targetPath).lastPathComponent)."
        case .connected(let processID, let adapterName):
            "\(adapterName) controls pid \(processID)."
        case .disconnecting(let processID, let adapterName):
            "\(adapterName) is disconnecting from pid \(processID)."
        case .failed(let reason):
            reason
        }
    }
}

enum DebuggerSessionIdentityKind: Equatable {
    case noTarget
    case launching(name: String)
    case liveProcess(processID: Int32, executableName: String?)
    case batchTranscript(processID: Int32?)
    case exited(code: Int32?)
    case unavailable
}

struct DebuggerSessionIdentity: Equatable {
    var kind: DebuggerSessionIdentityKind
    var displayName: String
    var processID: Int32?
    var isLiveProcess: Bool

    init(snapshot: DebuggerSessionSnapshot) {
        switch snapshot.processState {
        case .notAttached:
            self.kind = .noTarget
            self.displayName = "No target"
            self.processID = nil
            self.isLiveProcess = false
        case .launching(let targetPath):
            let name = DebuggerTargetSelectionDescriptor.displayName(forPath: targetPath)
            self.kind = .launching(name: name)
            self.displayName = name
            self.processID = nil
            self.isLiveProcess = false
        case .running(let processID, let executableName):
            self.kind = .liveProcess(processID: processID, executableName: executableName)
            self.displayName = executableName
            self.processID = processID
            self.isLiveProcess = snapshot.liveProcessID == processID
        case .paused(let processID, _):
            self.kind = .liveProcess(processID: processID, executableName: nil)
            self.displayName = "pid \(processID)"
            self.processID = processID
            self.isLiveProcess = snapshot.liveProcessID == processID
        case .detaching(let processID):
            self.kind = .unavailable
            self.displayName = "Detaching from pid \(processID)"
            self.processID = processID
            self.isLiveProcess = false
        case .batchStopped(let processID, _):
            self.kind = .batchTranscript(processID: processID)
            self.displayName = processID.map { "pid \($0)" } ?? "Batch transcript"
            self.processID = processID
            self.isLiveProcess = false
        case .exited(let code):
            self.kind = .exited(code: code)
            self.displayName = code.map { "Exited \($0)" } ?? "Exited"
            self.processID = nil
            self.isLiveProcess = false
        case .unavailable:
            self.kind = .unavailable
            self.displayName = "Unavailable"
            self.processID = nil
            self.isLiveProcess = false
        }
    }
}

struct DebuggerSessionStatusSummary: Equatable {
    var title: String
    var detail: String
    var systemImage: String
    var accessibilityLabel: String
    var identity: DebuggerSessionIdentity

    init(
        snapshot: DebuggerSessionSnapshot,
        capabilities: DebuggerCapabilityReport,
        lastError: String?
    ) {
        self.identity = DebuggerSessionIdentity(snapshot: snapshot)

        if !capabilities.isBackendAvailable {
            self.title = "Backend unavailable"
            self.detail = DebuggerPublishedDiagnosticText.project(
                lastError ?? capabilities.summary
            ).text
            self.systemImage = "exclamationmark.triangle"
        } else {
            self.title = DebuggerPublishedDiagnosticText.project(
                snapshot.processState.displayTitle
            ).text
            self.detail = DebuggerPublishedDiagnosticText.project(
                lastError ?? (
                    snapshot.statusMessage.isEmpty
                        ? snapshot.processState.detail
                        : snapshot.statusMessage
                )
            ).text
            self.systemImage = snapshot.processState.systemImage
        }

        self.accessibilityLabel = DebuggerPublishedDiagnosticText.project(
            "Debugger \(title). \(detail)"
        ).text
    }
}

enum DebuggerLaunchAdmissionDiagnosticKind: Equatable {
    case toolchainUnavailable
    case readinessProofFailed
    case launchAuthorityUnavailable
}

struct DebuggerLaunchAdmissionDiagnosticPresentation: Equatable {
    let kind: DebuggerLaunchAdmissionDiagnosticKind
    let title: String
    let reason: String
    let guidance: String
    let systemImage: String
    let isTruncated: Bool

    init(
        kind: DebuggerLaunchAdmissionDiagnosticKind,
        title: String,
        reason: String,
        guidance: String,
        systemImage: String,
        isTruncated: Bool
    ) {
        self.kind = kind
        self.title = title
        self.reason = reason
        self.guidance = guidance
        self.systemImage = systemImage
        self.isTruncated = isTruncated
    }

    init?(capabilities: DebuggerCapabilityReport) {
        switch capabilities.backendAvailability {
        case .unavailable(let reason):
            let published = Self.publishedReason(
                reason,
                fallback: "Xcode LLDB is unavailable."
            )
            self.init(
                kind: .toolchainUnavailable,
                title: "Xcode LLDB unavailable",
                reason: published.text,
                guidance: "Verify that the current Xcode 27 toolchain is installed and selected, then relaunch MacScope.",
                systemImage: "wrench.and.screwdriver",
                isTruncated: published.isTruncated
            )
        case .discovered(_, let details):
            let published = Self.publishedReason(
                details,
                fallback: "LLDB readiness could not be verified."
            )
            self.init(
                kind: .readinessProofFailed,
                title: "LLDB readiness check failed",
                reason: published.text,
                guidance: "Verify the selected Xcode LLDB can start; inspect MacScope's Console entries if the reason persists.",
                systemImage: "exclamationmark.triangle",
                isTruncated: published.isTruncated
            )
        case .ready:
            guard case .unsupported(let reason) = capabilities.launchSupport else { return nil }
            let published = Self.publishedReason(
                reason,
                fallback: "Debugger launch is unavailable."
            )
            self.init(
                kind: .launchAuthorityUnavailable,
                title: "Debugger launch unavailable",
                reason: published.text,
                guidance: "Restart MacScope if app-global launch authority should be present; the debugger remains fail-closed.",
                systemImage: "lock.shield",
                isTruncated: published.isTruncated
            )
        }
    }

    private static func publishedReason(
        _ reason: String,
        fallback: String
    ) -> DebuggerPublishedDiagnosticText.Value {
        let published = DebuggerPublishedDiagnosticText.project(reason)
        guard published.text.isEmpty else { return published }
        return DebuggerPublishedDiagnosticText.project(fallback)
    }
}

struct DebuggerBreakpoint: Identifiable, Equatable {
    var id: UInt64 { address }

    var address: UInt64
    var isEnabled: Bool
    var condition: String?
    var hitCount: Int
    var ignoreCount: Int

    init(
        address: UInt64,
        isEnabled: Bool = true,
        condition: String? = nil,
        hitCount: Int = 0,
        ignoreCount: Int = 0
    ) {
        self.address = address
        self.isEnabled = isEnabled
        self.condition = condition
        self.hitCount = hitCount
        self.ignoreCount = ignoreCount
    }

    mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    mutating func recordHit() {
        hitCount += 1
    }
}

struct DebuggerFrameSummary: Identifiable, Equatable {
    var id: Int { index }

    var index: Int
    var address: UInt64
    var functionName: String
    var moduleName: String?
    var sourceLocation: String?
}

struct DebuggerThreadSummary: Identifiable, Equatable {
    var id: Int { index }

    var tid: UInt64? = nil

    var index: Int
    var queueName: String?
    var stopReason: DebuggerPauseReason?
    var isSelected: Bool
    var topFrameAddress: UInt64?
    var topFrameFunctionName: String?
    /// The thread's pthread name (`name = '…'` in the thread list), when it has one.
    var name: String? = nil
}

/// Display group for a recovered register, used to bucket the (now much larger)
/// ARM64 register file into the panel's grouped layout. Mirrors LLDB's own
/// register-set partitioning (general-purpose, floating-point/SIMD, exception /
/// system state) so the panel can show one section per group.
enum DebuggerRegisterGroup: String, CaseIterable, Equatable {
    case generalPurpose
    case floatingPoint
    case system
    case other

    /// Human-readable section title surfaced in the registers deck.
    var displayTitle: String {
        switch self {
        case .generalPurpose: "General Purpose"
        case .floatingPoint: "Floating Point / SIMD"
        case .system: "System / Exception State"
        case .other: "Other"
        }
    }

    /// Stable ordering for the grouped display (GPR first, then FP/SIMD, then
    /// system, then anything unclassified).
    var sortOrder: Int {
        switch self {
        case .generalPurpose: 0
        case .floatingPoint: 1
        case .system: 2
        case .other: 3
        }
    }
}

struct DebuggerRegisterSummary: Identifiable, Equatable {
    var id: String { name }

    var name: String
    var value: String
    var role: String?
    var group: DebuggerRegisterGroup

    init(
        name: String,
        value: String,
        role: String? = nil,
        group: DebuggerRegisterGroup = .generalPurpose
    ) {
        self.name = name
        self.value = value
        self.role = role
        self.group = group
    }
}

struct DebuggerMemorySummary: Identifiable, Equatable {
    var id: UInt64 { address }

    var address: UInt64
    var byteCount: Int
    var previewBytes: [UInt8]
    var label: String?

    var previewText: String {
        if previewBytes.isEmpty { return "No bytes" }
        return previewBytes.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

enum DebuggerAttachTarget: Equatable {
    case processID(Int32)
    case processName(String)

    var displayName: String {
        switch self {
        case .processID(let processID):
            return "pid \(processID)"
        case .processName(let name):
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedName.isEmpty ? "process name" : "process named \(trimmedName)"
        }
    }
}

struct DebuggerAttachRequest: Equatable {
    var target: DebuggerAttachTarget

    init(target: DebuggerAttachTarget) {
        self.target = target
    }

    var displayName: String {
        target.displayName
    }
}

enum DebuggerAttachPolicy: Equatable {
    case supported
    case denied(reason: String)
    case unavailable(reason: String)

    var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    var unavailableReason: String? {
        switch self {
        case .supported:
            return nil
        case .denied(let reason), .unavailable(let reason):
            return reason
        }
    }

    func denialMessage(for request: DebuggerAttachRequest) -> String {
        switch self {
        case .supported:
            return "Attach to \(request.displayName) requires an attach transport."
        case .denied(let reason):
            return "Attach to \(request.displayName) is disabled: \(reason)"
        case .unavailable(let reason):
            return "Attach to \(request.displayName) is unavailable: \(reason)"
        }
    }
}

enum DebuggerTargetSelectionKind: Equatable {
    case importedTarget
    case processAttach
}

enum DebuggerTargetSelectionPolicy: Equatable {
    case enabled(actionTitle: String)
    case blocked(reason: String)
    case unavailable(reason: String)

    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .enabled(let actionTitle):
            actionTitle
        case .blocked(let reason), .unavailable(let reason):
            reason
        }
    }

    var statusTitle: String {
        switch self {
        case .enabled:
            "Ready"
        case .blocked:
            "Blocked"
        case .unavailable:
            "Unavailable"
        }
    }
}

struct DebuggerTargetSelectionDescriptor: Identifiable, Equatable {
    var id: String
    var kind: DebuggerTargetSelectionKind
    var title: String
    var detail: String
    var systemImage: String
    var policy: DebuggerTargetSelectionPolicy
    var validationSummary: DebuggerLaunchValidationSummary?

    var disabledReason: String? {
        policy.isEnabled ? nil : policy.displayText
    }

    static func importedTarget(
        configuration: DebuggerLaunchConfiguration,
        launchSupport: DebuggerOperationSupport,
        displayTitle: String? = nil,
        blockedReason: String? = nil,
        fileManager: FileManager = .default,
        requiresExecutableFile: Bool = false
    ) -> DebuggerTargetSelectionDescriptor {
        let normalizedExecutablePath = configuration.normalizedExecutablePath
        let displayName = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? displayName(forPath: normalizedExecutablePath)
        let validationSummary = DebuggerLaunchValidationSummary.evaluate(
            configuration: configuration,
            launchSupport: launchSupport,
            blockedReason: blockedReason,
            fileManager: fileManager,
            requiresExecutableFile: requiresExecutableFile
        )
        let detail: String
        let policy: DebuggerTargetSelectionPolicy

        if let blockedReason {
            detail = blockedReason
            policy = .blocked(reason: blockedReason)
        } else if normalizedExecutablePath.isEmpty {
            detail = "Choose an imported executable to launch under LLDB."
            policy = .blocked(reason: "Choose an imported executable before launching.")
        } else if case .unsupported(let reason) = launchSupport {
            detail = validationSummary.disabledReason ?? reason
            policy = .unavailable(reason: reason)
        } else if let disabledReason = validationSummary.disabledReason {
            detail = disabledReason
            policy = .blocked(reason: disabledReason)
        } else if let workingDirectory = configuration.normalizedWorkingDirectory {
            detail = "Launch from \(workingDirectory)."
            policy = launchSupport.targetSelectionPolicy(enabledTitle: "Launch imported target")
        } else {
            detail = "Launch as a MacScope-owned LLDB target."
            policy = launchSupport.targetSelectionPolicy(enabledTitle: "Launch imported target")
        }

        return DebuggerTargetSelectionDescriptor(
            id: "imported:\(normalizedExecutablePath)",
            kind: .importedTarget,
            title: displayName,
            detail: detail,
            systemImage: "app.badge",
            policy: policy,
            validationSummary: validationSummary
        )
    }

    static func processAttachPlaceholder(
        reason: String,
        policy: DebuggerAttachPolicy
    ) -> DebuggerTargetSelectionDescriptor {
        let policyDetail = policy.unavailableReason.map { " Attach policy: \($0)" } ?? ""
        return DebuggerTargetSelectionDescriptor(
            id: "attach:pid",
            kind: .processAttach,
            title: "PID attach",
            detail: "\(reason)\(policyDetail)",
            systemImage: "number.circle",
            policy: .blocked(reason: reason),
            validationSummary: nil
        )
    }

    static func processAttach(
        request: DebuggerAttachRequest,
        policy: DebuggerAttachPolicy
    ) -> DebuggerTargetSelectionDescriptor {
        DebuggerTargetSelectionDescriptor(
            id: "attach:\(request.displayName)",
            kind: .processAttach,
            title: request.displayName,
            detail: policy.denialMessage(for: request),
            systemImage: "number.circle",
            policy: policy.targetSelectionPolicy,
            validationSummary: nil
        )
    }

    static func displayName(forPath path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "Imported target" }
        return URL(fileURLWithPath: trimmedPath).lastPathComponent
    }
}

struct DebuggerSignedTargetPolicyDiagnostic: Identifiable, Equatable {
    enum Severity: String, Equatable {
        case info
        case warning
        case blocker
    }

    var severity: Severity
    var title: String
    var detail: String
    var systemImage: String

    var id: String {
        "\(severity.rawValue):\(title):\(detail)"
    }
}

struct DebuggerSignedTargetPolicySummary: Equatable {
    static let pendingPolicyReason = "Attach remains disabled until signed-target policy is proven."

    var title: String
    var detail: String
    var systemImage: String
    var statusTitle: String
    var disabledReason: String?
    var diagnostics: [DebuggerSignedTargetPolicyDiagnostic]

    init(
        capabilities: DebuggerCapabilityReport,
        attachPolicy: DebuggerAttachPolicy? = nil
    ) {
        let resolvedPolicy = attachPolicy ?? Self.defaultAttachPolicy(for: capabilities)

        if !capabilities.isBackendAvailable {
            self.title = "Target policy unavailable"
            self.detail = capabilities.summary
            self.systemImage = "exclamationmark.shield"
        } else if resolvedPolicy.isSupported {
            self.title = "Exact attach supported"
            self.detail = "Local process attach is enabled for exact observed process identities."
            self.systemImage = "checkmark.shield"
        } else {
            self.title = "Signed-target policy pending"
            let backendNote: String
            if capabilities.attachSupport.isSupported {
                backendNote = " Backend attach transport is present but blocked by MacScope policy."
            } else {
                backendNote = " Backend: \(capabilities.attachSupport.unavailableReason ?? capabilities.summary)"
            }
            self.detail = "Local process attach remains disabled until signed-target policy is proven.\(backendNote)"
            self.systemImage = "lock.shield"
        }

        self.statusTitle = Self.statusTitle(for: resolvedPolicy, capabilities: capabilities)
        self.disabledReason = resolvedPolicy.unavailableReason
        self.diagnostics = Self.makeDiagnostics(
            capabilities: capabilities,
            attachPolicy: resolvedPolicy
        )
    }

    private static func defaultAttachPolicy(
        for capabilities: DebuggerCapabilityReport
    ) -> DebuggerAttachPolicy {
        guard capabilities.isBackendAvailable else {
            return .unavailable(reason: capabilities.attachSupport.unavailableReason ?? capabilities.summary)
        }

        return .denied(reason: pendingPolicyReason)
    }

    private static func statusTitle(
        for policy: DebuggerAttachPolicy,
        capabilities: DebuggerCapabilityReport
    ) -> String {
        guard capabilities.isBackendAvailable else { return "Unavailable" }
        return policy.isSupported ? "Ready" : "Blocked"
    }

    private static func makeDiagnostics(
        capabilities: DebuggerCapabilityReport,
        attachPolicy: DebuggerAttachPolicy
    ) -> [DebuggerSignedTargetPolicyDiagnostic] {
        guard capabilities.isBackendAvailable else {
            return [
                DebuggerSignedTargetPolicyDiagnostic(
                    severity: .blocker,
                    title: "Debugger backend unavailable",
                    detail: capabilities.summary,
                    systemImage: "exclamationmark.triangle"
                )
            ]
        }

        if attachPolicy.isSupported {
            return [
                DebuggerSignedTargetPolicyDiagnostic(
                    severity: .info,
                    title: "Exact identity required",
                    detail: "MacScope attaches only after process discovery or manual PID resolution produces exact signed-target identity evidence.",
                    systemImage: "checkmark.shield"
                )
            ]
        }

        let policyReason = attachPolicy.unavailableReason ?? pendingPolicyReason
        var diagnostics = [
            DebuggerSignedTargetPolicyDiagnostic(
                severity: .blocker,
                title: "Signed-target policy pending",
                detail: policyReason,
                systemImage: "lock.shield"
            )
        ]

        if capabilities.attachSupport.isSupported {
            diagnostics.append(DebuggerSignedTargetPolicyDiagnostic(
                severity: .warning,
                title: "Backend attach support gated",
                detail: "A backend reports attach support, but MacScope keeps local PID/name attach controls disabled until signed-target policy is proven.",
                systemImage: "exclamationmark.shield"
            ))
        } else if let reason = capabilities.attachSupport.unavailableReason {
            diagnostics.append(DebuggerSignedTargetPolicyDiagnostic(
                severity: .info,
                title: "Attach transport unavailable",
                detail: reason,
                systemImage: "wrench.and.screwdriver"
            ))
        }

        diagnostics.append(DebuggerSignedTargetPolicyDiagnostic(
            severity: .info,
            title: "Launch-only boundary",
            detail: "Debugger launch is limited to MacScope-owned targets; arbitrary local pid/name attach remains disabled.",
            systemImage: "play.slash"
        ))

        return diagnostics
    }
}

struct DebuggerPIDTargetDescriptor: Identifiable, Equatable {
    var processID: Int32?
    var selectionDescriptor: DebuggerTargetSelectionDescriptor
    var attachAvailability: DebuggerControlAvailability
    var policyDiagnostics: [DebuggerSignedTargetPolicyDiagnostic]

    var id: String {
        selectionDescriptor.id
    }

    var title: String {
        selectionDescriptor.title
    }

    var detail: String {
        selectionDescriptor.detail
    }

    init(
        processID: Int32?,
        policy: DebuggerAttachPolicy,
        policyDiagnostics: [DebuggerSignedTargetPolicyDiagnostic],
        missingInputReason: String = "Enter a positive process ID before attaching."
    ) {
        self.processID = processID
        self.policyDiagnostics = policyDiagnostics

        if let processID {
            let request = DebuggerAttachRequest(target: .processID(processID))
            let selectionDescriptor = DebuggerTargetSelectionDescriptor.processAttach(
                request: request,
                policy: policy
            )
            self.selectionDescriptor = selectionDescriptor
            self.attachAvailability = DebuggerControlAvailability(
                action: .attachProcess,
                isEnabled: selectionDescriptor.policy.isEnabled,
                disabledReason: selectionDescriptor.disabledReason
            )
        } else {
            let selectionDescriptor = DebuggerTargetSelectionDescriptor.processAttachPlaceholder(
                reason: missingInputReason,
                policy: policy
            )
            self.selectionDescriptor = selectionDescriptor
            self.attachAvailability = DebuggerControlAvailability(
                action: .attachProcess,
                isEnabled: false,
                disabledReason: missingInputReason
            )
        }
    }
}

struct DebuggerTargetPickerSnapshot: Equatable {
    var rows: [DebuggerTargetSelectionDescriptor]
    var selectedRowID: DebuggerTargetSelectionDescriptor.ID
    var policySummary: DebuggerSignedTargetPolicySummary
    var pidTarget: DebuggerPIDTargetDescriptor

    var selectedRow: DebuggerTargetSelectionDescriptor? {
        rows.first { $0.id == selectedRowID }
    }

    var selectedSummary: DebuggerSelectedTargetSummary {
        selectedRow.map(DebuggerSelectedTargetSummary.init(descriptor:)) ?? .noTarget
    }
}

struct DebuggerSelectedTargetSummary: Equatable {
    var title: String
    var detail: String
    var statusTitle: String
    var systemImage: String
    var disabledReason: String?
    var accessibilityLabel: String

    init(
        title: String,
        detail: String,
        statusTitle: String,
        systemImage: String,
        disabledReason: String?
    ) {
        self.title = title
        self.detail = detail
        self.statusTitle = statusTitle
        self.systemImage = systemImage
        self.disabledReason = disabledReason
        self.accessibilityLabel = "\(title), \(statusTitle). \(disabledReason ?? detail)"
    }

    init(descriptor: DebuggerTargetSelectionDescriptor) {
        self.init(
            title: descriptor.title,
            detail: descriptor.validationSummary?.detail ?? descriptor.detail,
            statusTitle: descriptor.policy.statusTitle,
            systemImage: descriptor.systemImage,
            disabledReason: descriptor.disabledReason
        )
    }

    static let noTarget = DebuggerSelectedTargetSummary(
        title: "No target",
        detail: "No debugger target is selected.",
        statusTitle: "Unavailable",
        systemImage: "questionmark.circle",
        disabledReason: "No debugger target is selected."
    )
}

struct DebuggerLaunchTargetDescriptor: Equatable {
    enum Origin: Equatable {
        case importedWorkspaceBinary(binaryID: UUID, sourcePath: String)
    }

    var origin: Origin
    var displayName: String
    var sourcePath: String
    var executablePath: String
    var unavailableReason: String?

    var isLaunchable: Bool {
        unavailableReason == nil && !executablePath.isEmpty
    }

    static func importedWorkspaceBinary(
        _ binary: BinaryImage,
        fileManager: FileManager = .default
    ) -> DebuggerLaunchTargetDescriptor {
        let sourcePath = normalizePath(binary.path)
        let origin = Origin.importedWorkspaceBinary(binaryID: binary.id, sourcePath: sourcePath)
        let fallbackName = binary.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? DebuggerTargetSelectionDescriptor.displayName(forPath: sourcePath)

        guard !sourcePath.isEmpty else {
            return DebuggerLaunchTargetDescriptor(
                origin: origin,
                displayName: fallbackName,
                sourcePath: sourcePath,
                executablePath: "",
                unavailableReason: "Imported workspace target has no executable path."
            )
        }

        guard sourcePath.hasPrefix("/") else {
            return DebuggerLaunchTargetDescriptor(
                origin: origin,
                displayName: fallbackName,
                sourcePath: sourcePath,
                executablePath: sourcePath,
                unavailableReason: "Imported workspace target path must be absolute before launching."
            )
        }

        guard let executablePath = resolvedExecutablePath(
            for: sourcePath,
            binaryKind: binary.kind,
            fileManager: fileManager
        ) else {
            return DebuggerLaunchTargetDescriptor(
                origin: origin,
                displayName: fallbackName,
                sourcePath: sourcePath,
                executablePath: "",
                unavailableReason: "Imported app bundle does not declare a launchable executable."
            )
        }

        let displayName = DebuggerTargetSelectionDescriptor.displayName(forPath: executablePath)
        return DebuggerLaunchTargetDescriptor(
            origin: origin,
            displayName: displayName,
            sourcePath: sourcePath,
            executablePath: executablePath,
            unavailableReason: launchBlockReason(forExecutablePath: executablePath, fileManager: fileManager)
        )
    }

    func launchConfiguration(
        arguments: [String] = [],
        environment: [String: String] = [:],
        initialBreakpoints: [DebuggerBreakpoint] = []
    ) -> DebuggerLaunchConfiguration {
        DebuggerLaunchConfiguration.importedTarget(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            initialBreakpoints: initialBreakpoints
        )
    }

    func importedTargetDescriptor(
        launchSupport: DebuggerOperationSupport,
        arguments: [String] = [],
        environment: [String: String] = [:],
        initialBreakpoints: [DebuggerBreakpoint] = []
    ) -> DebuggerTargetSelectionDescriptor {
        DebuggerTargetSelectionDescriptor.importedTarget(
            configuration: launchConfiguration(
                arguments: arguments,
                environment: environment,
                initialBreakpoints: initialBreakpoints
            ),
            launchSupport: launchSupport,
            displayTitle: displayName,
            blockedReason: unavailableReason
        )
    }

    private static func resolvedExecutablePath(
        for sourcePath: String,
        binaryKind: String,
        fileManager: FileManager
    ) -> String? {
        guard isAppBundlePath(sourcePath, binaryKind: binaryKind) else {
            return sourcePath
        }

        guard let executableName = appBundleExecutableName(at: sourcePath, fileManager: fileManager) else {
            return nil
        }

        return URL(fileURLWithPath: sourcePath)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
            .path
    }

    private static func isAppBundlePath(_ sourcePath: String, binaryKind: String) -> Bool {
        URL(fileURLWithPath: sourcePath).pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame
            || binaryKind.localizedCaseInsensitiveContains("app bundle")
    }

    private static func appBundleExecutableName(
        at appPath: String,
        fileManager: FileManager
    ) -> String? {
        let infoURL = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)

        guard fileManager.fileExists(atPath: infoURL.path),
              let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let executableName = plist["CFBundleExecutable"] as? String
        else {
            return nil
        }

        let trimmedName = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              !trimmedName.contains("\\")
        else {
            return nil
        }

        return trimmedName
    }

    private static func launchBlockReason(
        forExecutablePath executablePath: String,
        fileManager: FileManager
    ) -> String? {
        guard fileManager.isExecutableFile(atPath: executablePath) else {
            return "No executable file exists at \(executablePath)."
        }

        return nil
    }

    private static func normalizePath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "" }
        return (trimmedPath as NSString).expandingTildeInPath
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension DebuggerAttachPolicy {
    var targetSelectionPolicy: DebuggerTargetSelectionPolicy {
        switch self {
        case .supported:
            .enabled(actionTitle: "Attach")
        case .denied(let reason):
            .blocked(reason: reason)
        case .unavailable(let reason):
            .unavailable(reason: reason)
        }
    }
}

extension DebuggerOperationSupport {
    func targetSelectionPolicy(enabledTitle: String) -> DebuggerTargetSelectionPolicy {
        switch self {
        case .supported:
            .enabled(actionTitle: enabledTitle)
        case .unsupported(let reason):
            .unavailable(reason: reason)
        }
    }
}

extension DebuggerLaunchConfiguration {
    static func importedTarget(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        initialBreakpoints: [DebuggerBreakpoint] = []
    ) -> DebuggerLaunchConfiguration {
        let normalizedExecutablePath = normalizePath(executablePath)
        return DebuggerLaunchConfiguration(
            executablePath: normalizedExecutablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: normalizedWorkingDirectory(
                workingDirectory,
                executablePath: normalizedExecutablePath
            ),
            initialBreakpoints: initialBreakpoints
        )
    }

    var importedTargetDescriptor: DebuggerTargetSelectionDescriptor {
        DebuggerTargetSelectionDescriptor.importedTarget(
            configuration: self,
            launchSupport: .supported
        )
    }

    private static func normalizedWorkingDirectory(
        _ workingDirectory: String?,
        executablePath: String
    ) -> String? {
        if let workingDirectory {
            let normalizedDirectory = normalizePath(workingDirectory)
            if !normalizedDirectory.isEmpty {
                return normalizedDirectory
            }
        }

        guard executablePath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
    }

    private static func normalizePath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "" }
        return (trimmedPath as NSString).expandingTildeInPath
    }
}

struct DebuggerCommandRunSummary: Equatable {
    var commandDisplay: String
    var lldbTerminationStatus: Int32
    var targetExitStatus: Int32?
    var targetProcessID: Int32? = nil
    var targetState: DebuggerBatchTargetState = .unknown
    var diagnosticSummary: String? = nil
    var standardOutput: String
    var standardError: String
    var timedOut: Bool

    var succeeded: Bool {
        guard !timedOut, lldbTerminationStatus == 0 else { return false }
        if case .error = targetState { return false }
        return true
    }

    var statusText: String {
        if timedOut {
            return "LLDB batch command timed out."
        }

        let targetStatus: String
        switch targetState {
        case .unknown:
            targetStatus = targetExitStatus.map { "; target exit \($0)" } ?? ""
        case .exited(let code):
            targetStatus = code.map { "; target exit \($0)" } ?? "; target exited"
        case .stopped(_, let reason):
            targetStatus = "; target stopped: \(reason.displayTitle)"
        case .error(let message):
            targetStatus = "; target error: \(message)"
        }

        return "LLDB exit \(lldbTerminationStatus)\(targetStatus)."
    }
}

struct DebuggerVariableScopeSnapshot: Equatable {
    let coordinate: DebuggerInspectionCoordinate
    let scope: DebuggerVariableScopeKind
    let nodes: [DebuggerVariableNode]
    let wasTruncated: Bool
}

struct DebuggerSessionSnapshot: Equatable {
    var processState: DebuggerProcessState
    var breakpoints: [DebuggerBreakpoint]
    var watchpoints: [DebuggerWatchpoint]
    var watchpointError: String?
    var threads: [DebuggerThreadSummary]
    var frames: [DebuggerFrameSummary]
    var registers: [DebuggerRegisterSummary]
    var memoryRegions: [DebuggerMemorySummary]
    var variableScopes: [DebuggerVariableScopeSnapshot]
    var statusMessage: String
    var backendState: DebuggerBackendSessionState
    var lastCommandRun: DebuggerCommandRunSummary?
    /// Optional WS-19 transport metadata. Legacy batch snapshots and test doubles intentionally
    /// retain `nil`; production persistent-CLI snapshots are reducer projections and carry the
    /// exact accepted coordinate. These values fence async presentation and are never reducer
    /// input authority.
    var transportSessionCoordinate: DebuggerSessionCoordinate?
    var transportStopCoordinate: DebuggerStopCoordinate?
    var transportEventSequence: DebuggerEventSequence?
    var transportDiagnostic: DebuggerDiagnostic?
    var transportTargetDisposition: DebuggerTargetDisposition?
    /// Exact reducer-accepted target authority. Terminal snapshots retain this tombstone even
    /// after the backend is no longer connected; legacy PID-only snapshots leave it nil.
    var transportTargetAuthority: DebuggerSessionTargetAuthority?
    /// Optional WS-20 runtime-module authority. Legacy/batch snapshots retain `nil`; typed
    /// persistent snapshots publish both values together. The revision orders available maps and
    /// unavailable tombstones independently from the successful inventory revision.
    var transportRuntimeModuleAuthorityRevision: DebuggerRuntimeModuleAuthorityRevision?
    var transportRuntimeModuleAuthority: DebuggerRuntimeModuleAuthority?
    /// Optional WS-21 transient binding authority. Typed persistent snapshots publish the
    /// revision and complete reducer projection together; legacy snapshots retain both as nil.
    /// This is output-only session evidence and never becomes durable workspace authority.
    var transportBreakpointBindingAuthorityRevision:
        DebuggerBreakpointBindingAuthorityRevision?
    var transportBreakpointBindingState: DebuggerBreakpointBindingReducerSnapshot?
    /// Nonauthoritative workspace correlation derived above the transport reducer. It is fenced by
    /// its complete key at use time and intentionally does not participate in transport tickets.
    var runtimeMappingProjection: DebuggerRuntimeMappingProjection?

    init(
        processState: DebuggerProcessState,
        breakpoints: [DebuggerBreakpoint],
        threads: [DebuggerThreadSummary] = [],
        frames: [DebuggerFrameSummary],
        registers: [DebuggerRegisterSummary],
        memoryRegions: [DebuggerMemorySummary],
        variableScopes: [DebuggerVariableScopeSnapshot] = [],
        statusMessage: String,
        backendState: DebuggerBackendSessionState = .disconnected,
        lastCommandRun: DebuggerCommandRunSummary? = nil,
        transportSessionCoordinate: DebuggerSessionCoordinate? = nil,
        transportStopCoordinate: DebuggerStopCoordinate? = nil,
        transportEventSequence: DebuggerEventSequence? = nil,
        transportDiagnostic: DebuggerDiagnostic? = nil,
        transportTargetDisposition: DebuggerTargetDisposition? = nil,
        transportTargetAuthority: DebuggerSessionTargetAuthority? = nil,
        transportRuntimeModuleAuthorityRevision: DebuggerRuntimeModuleAuthorityRevision? = nil,
        transportRuntimeModuleAuthority: DebuggerRuntimeModuleAuthority? = nil,
        transportBreakpointBindingAuthorityRevision:
            DebuggerBreakpointBindingAuthorityRevision? = nil,
        transportBreakpointBindingState: DebuggerBreakpointBindingReducerSnapshot? = nil,
        runtimeMappingProjection: DebuggerRuntimeMappingProjection? = nil,
        watchpoints: [DebuggerWatchpoint] = [],
        watchpointError: String? = nil
    ) {
        self.processState = processState
        self.breakpoints = breakpoints
        self.watchpoints = watchpoints
        self.watchpointError = watchpointError
        self.threads = threads
        self.frames = frames
        self.registers = registers
        self.memoryRegions = memoryRegions
        self.variableScopes = variableScopes
        self.statusMessage = statusMessage
        self.backendState = backendState
        self.lastCommandRun = lastCommandRun
        self.transportSessionCoordinate = transportSessionCoordinate
        self.transportStopCoordinate = transportStopCoordinate
        self.transportEventSequence = transportEventSequence
        self.transportDiagnostic = transportDiagnostic
        self.transportTargetDisposition = transportTargetDisposition
        self.transportTargetAuthority = transportTargetAuthority
        self.transportRuntimeModuleAuthorityRevision = transportRuntimeModuleAuthorityRevision
        self.transportRuntimeModuleAuthority = transportRuntimeModuleAuthority
        self.transportBreakpointBindingAuthorityRevision =
            transportBreakpointBindingAuthorityRevision
        self.transportBreakpointBindingState = transportBreakpointBindingState
        self.runtimeMappingProjection = runtimeMappingProjection
    }

    static var empty: DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            threads: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Debugger backend is not connected."
        )
    }

    var activeBreakpointCount: Int {
        breakpoints.filter(\.isEnabled).count
    }

    var hasLiveProcessSession: Bool {
        liveProcessID != nil
    }

    func providerVisibleReadOnlyEvidenceText(
        maximumFrames: Int = 5,
        maximumThreads: Int = 5,
        maximumRegisters: Int = 16,
        maximumMemoryRegions: Int = 5,
        maximumUTF8Bytes: Int = 4_096
    ) -> String? {
        guard processState != .notAttached else { return nil }
        var lines = [
            "Debugger state: \(processState.displayTitle)",
            "Debugger detail: \(processState.detail)",
            "Backend: \(backendState.detail)",
            "Status: \(statusMessage)",
            "Active breakpoints: \(activeBreakpointCount)",
        ]
        if let authority = transportTargetAuthority {
            lines.append("Target process ID: \(authority.processID)")
            lines.append("Target origin: \(authority.origin.providerVisibleEvidenceLabel)")
            lines.append("Target identity digest: \(authority.identityDigest.lowercaseHex)")
        } else if let liveProcessID {
            lines.append("Target process ID: \(liveProcessID)")
        }
        if let disposition = transportTargetDisposition {
            lines.append("Target disposition: \(disposition.providerVisibleEvidenceLabel)")
        }
        if let lastCommandRun {
            lines.append("Last debugger command: \(lastCommandRun.commandDisplay)")
            lines.append("Last debugger command status: \(lastCommandRun.statusText)")
        }
        let boundedThreads = threads.prefix(max(0, maximumThreads))
        if !boundedThreads.isEmpty {
            lines.append("Threads:")
            lines += boundedThreads.map { thread in
                let selected = thread.isSelected ? " selected" : ""
                let topFrame = thread.topFrameFunctionName ?? thread.topFrameAddress?.hexAddress ?? "no top frame"
                let reason = thread.stopReason.map { " · \($0.displayTitle)" } ?? ""
                return "- #\(thread.index)\(selected): \(topFrame)\(reason)"
            }
        }
        let boundedFrames = frames.prefix(max(0, maximumFrames))
        if !boundedFrames.isEmpty {
            lines.append("Frames:")
            lines += boundedFrames.map { frame in
                let module = frame.moduleName.map { " [\($0)]" } ?? ""
                let source = frame.sourceLocation.map { " · \($0)" } ?? ""
                return "- #\(frame.index) \(frame.address.hexAddress) \(frame.functionName)\(module)\(source)"
            }
        }
        let boundedRegisters = registers.prefix(max(0, maximumRegisters))
        if !boundedRegisters.isEmpty {
            lines.append("Registers:")
            lines += boundedRegisters.map { register in
                let role = register.role.map { " (\($0))" } ?? ""
                return "- \(register.name)\(role): \(register.value)"
            }
        }
        let boundedMemory = memoryRegions.prefix(max(0, maximumMemoryRegions))
        if !boundedMemory.isEmpty {
            lines.append("Memory regions:")
            lines += boundedMemory.map { region in
                let label = region.label.map { " \($0)" } ?? ""
                return "- \(region.address.hexAddress) \(region.byteCount) bytes\(label): \(region.previewText)"
            }
        }
        return Phase2AIShellOneShotExecutionResult.truncatedUTF8(
            lines.joined(separator: "\n"),
            maximumBytes: maximumUTF8Bytes
        )
    }

    var liveProcessID: Int32? {
        guard case .connected(let backendProcessID, _) = backendState else { return nil }

        switch processState {
        case .running(let processID, _), .paused(let processID, _):
            return processID == backendProcessID ? processID : nil
        case .notAttached, .launching, .detaching, .batchStopped, .exited, .unavailable:
            return nil
        }
    }

    var canRefreshStoppedSnapshot: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    var canContinueLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    /// Run-to-cursor (set a temporary one-shot breakpoint at the cursor, then
    /// continue) requires a stopped (paused) live process, mirroring the continue
    /// posture: the target must exist and be halted before we can arm the temp
    /// breakpoint and resume.
    var canRunToCursorLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    var canStepOverLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    var canStepIntoLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    var canStepOutLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    var canPauseLiveProcess: Bool {
        hasLiveProcessSession && processState.isRunning
    }

    var canTerminateLiveProcess: Bool {
        guard hasLiveProcessSession else { return false }
        guard let authority = transportTargetAuthority else { return true }
        if case .launched = authority.origin { return true }
        return false
    }

    /// Attached targets belong to the user or another app; ending that session must disconnect
    /// LLDB without killing the target. If exact origin is unavailable, the UI keeps the legacy
    /// terminate path rather than guessing that detach is safe.
    var canDetachLiveProcess: Bool {
        guard hasLiveProcessSession,
              let authority = transportTargetAuthority,
              case .attached = authority.origin else { return false }
        return true
    }

    /// Register writes require a stopped (paused) live process: the target must
    /// exist and be halted so its register file can be mutated safely.
    var canWriteRegisterLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    /// Memory reads require a stopped (paused) live process, mirroring the
    /// stopped-state snapshot refresh posture.
    var canReadMemoryLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    /// Memory writes require a stopped (paused) live process: the target must be
    /// halted so its memory can be mutated safely, mirroring the register-write
    /// posture.
    var canWriteMemoryLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    /// Expression evaluation requires a stopped (paused) live process: the target
    /// must be halted so its current frame can be evaluated against, mirroring the
    /// register-write / memory-read posture.
    var canEvaluateExpressionLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    /// Selecting a thread (and re-reading its frames/registers) requires a stopped
    /// (paused) live process, mirroring the snapshot-refresh posture.
    var canSelectThreadLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    /// Selecting a stack frame (and re-reading that frame's registers/locals plus
    /// navigating the listing to its PC) requires a stopped (paused) live process,
    /// mirroring the thread-selection / snapshot-refresh posture.
    var canSelectFrameLiveProcess: Bool {
        hasLiveProcessSession && processState.isPaused
    }

    /// The program counter of the *current* (top) stack frame while the debugger is
    /// stopped at a live process, else `nil`.
    ///
    /// This is the pure source of the "live PC" highlight surfaced in the
    /// disassembly listing. It is deliberately non-nil ONLY when the session is both
    /// attached to a live process and paused at it (the same precondition as a
    /// snapshot refresh), so a running, batch-stopped, exited, or detached session
    /// reports no live PC — the listing then clears its highlight. When stopped but
    /// the backend supplied no frames (rare), it also reports `nil` rather than
    /// guessing. The top frame (`frames.first`, frame index 0) is the innermost
    /// frame, whose address is the instruction the process is halted on.
    var liveProgramCounter: UInt64? {
        guard hasLiveProcessSession, processState.isPaused else { return nil }
        return frames.first?.address
    }

    mutating func upsertBreakpoint(_ breakpoint: DebuggerBreakpoint) {
        if let index = breakpoints.firstIndex(where: { $0.address == breakpoint.address }) {
            breakpoints[index] = breakpoint
        } else {
            breakpoints.append(breakpoint)
        }
        breakpoints.sort { $0.address < $1.address }
    }

    @discardableResult
    mutating func toggleBreakpoint(at address: UInt64) -> DebuggerBreakpoint? {
        if let index = breakpoints.firstIndex(where: { $0.address == address }) {
            breakpoints.remove(at: index)
            return nil
        }

        let breakpoint = DebuggerBreakpoint(address: address)
        upsertBreakpoint(breakpoint)
        return breakpoint
    }

    mutating func setBreakpointEnabled(at address: UInt64, isEnabled: Bool) {
        guard let index = breakpoints.firstIndex(where: { $0.address == address }) else { return }
        breakpoints[index].setEnabled(isEnabled)
    }

    mutating func replaceBreakpoints(_ nextBreakpoints: [DebuggerBreakpoint]) {
        breakpoints = nextBreakpoints
        breakpoints.sort { $0.address < $1.address }
    }
}

private extension DebuggerSessionTargetOrigin {
    var providerVisibleEvidenceLabel: String {
        switch self {
        case .launched:
            return "launched"
        case .attached:
            return "attached"
        }
    }
}

private extension DebuggerTargetDisposition {
    var providerVisibleEvidenceLabel: String {
        switch self {
        case .notApplicable:
            return "not applicable"
        case .notStarted:
            return "not started"
        case .running(let processID):
            return "running pid \(processID)"
        case .stopped(let processID):
            return "stopped pid \(processID)"
        case .exited(let code):
            return code.map { "exited \($0)" } ?? "exited"
        case .detached:
            return "detached"
        case .terminated:
            return "terminated"
        case .unknown:
            return "unknown"
        }
    }
}
