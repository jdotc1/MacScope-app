import CryptoKit
import Foundation

// MARK: - Session, request, lifecycle, and stop coordinates

struct DebuggerSessionEpoch: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct DebuggerRequestID: Hashable, Sendable {
    let epoch: DebuggerSessionEpoch
    let sequence: UInt64
}

struct DebuggerLifecycleRevision: Hashable, Sendable, Comparable {
    let rawValue: UInt64

    static let initial = DebuggerLifecycleRevision(rawValue: 0)

    func incremented() -> DebuggerLifecycleRevision? {
        let (next, overflowed) = rawValue.addingReportingOverflow(1)
        return overflowed ? nil : DebuggerLifecycleRevision(rawValue: next)
    }

    static func < (lhs: DebuggerLifecycleRevision, rhs: DebuggerLifecycleRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DebuggerStopRevision: Hashable, Sendable, Comparable {
    let rawValue: UInt64

    static let initial = DebuggerStopRevision(rawValue: 0)

    func incremented() -> DebuggerStopRevision? {
        let (next, overflowed) = rawValue.addingReportingOverflow(1)
        return overflowed ? nil : DebuggerStopRevision(rawValue: next)
    }

    static func < (lhs: DebuggerStopRevision, rhs: DebuggerStopRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DebuggerEventSequence: Hashable, Sendable, Comparable {
    let rawValue: UInt64

    static let initial = DebuggerEventSequence(rawValue: 0)

    func incremented() -> DebuggerEventSequence? {
        let (next, overflowed) = rawValue.addingReportingOverflow(1)
        return overflowed ? nil : DebuggerEventSequence(rawValue: next)
    }

    static func < (lhs: DebuggerEventSequence, rhs: DebuggerEventSequence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DebuggerSessionCoordinate: Hashable, Sendable {
    let epoch: DebuggerSessionEpoch
    let lifecycleRevision: DebuggerLifecycleRevision
}

struct DebuggerStopCoordinate: Hashable, Sendable {
    let session: DebuggerSessionCoordinate
    let stopRevision: DebuggerStopRevision
}

// MARK: - Semantic operations and request context

enum DebuggerOperationClassification: String, Hashable, Sendable {
    case sessionEstablishing
    case lifecycleMutating
    case stoppedStateMutating
    case stoppedStateReading

    /// Session-scoped observation of an already-running target. This is deliberately distinct
    /// from presentation-only work: the isolated status result may author a new stopped or exited
    /// lifecycle state, but it never consumes a stop coordinate.
    case sessionObserving

    /// Session-scoped work that neither advances the process lifecycle nor reads or mutates data
    /// owned by one stop. Despite the historical name, this category may still perform a backend
    /// mutation such as replacing the session's logical breakpoint set.
    case presentationOnly
}

enum DebuggerOperation: String, CaseIterable, Hashable, Sendable {
    case launch
    case attach
    case `continue`
    case runToCursor
    case stepOver
    case stepInto
    case stepOut
    case pause
    case detach
    case terminate
    case replaceBreakpoints
    case reconcileLogicalBreakpoints
    case writeRegister
    case readMemory
    case writeMemory
    case updateWatchpoints
    case evaluateExpression
    case expandVariableChildren
    case selectThread
    case selectFrame
    case refreshSnapshot
    case refreshRuntimeModules
    case pollProcessStatus

    var classification: DebuggerOperationClassification {
        switch self {
        case .launch, .attach:
            .sessionEstablishing
        case .continue, .runToCursor, .stepOver, .stepInto, .stepOut, .pause, .detach,
             .terminate:
            .lifecycleMutating
        case .reconcileLogicalBreakpoints, .writeRegister, .writeMemory, .updateWatchpoints,
             .selectThread, .selectFrame:
            .stoppedStateMutating
        case .readMemory, .evaluateExpression, .expandVariableChildren,
             .refreshSnapshot, .refreshRuntimeModules:
            .stoppedStateReading
        case .pollProcessStatus:
            .sessionObserving
        case .replaceBreakpoints:
            .presentationOnly
        }
    }

    var requiresStopCoordinate: Bool {
        switch self {
        case .continue, .runToCursor, .stepOver, .stepInto, .stepOut:
            // These lifecycle operations consume one exact stopped state. Binding the originating
            // stop prevents a delayed run request from resuming a later stop in the same session.
            true
        case .reconcileLogicalBreakpoints, .writeRegister, .readMemory, .writeMemory, .updateWatchpoints,
             .evaluateExpression, .expandVariableChildren, .selectThread, .selectFrame,
             .refreshSnapshot, .refreshRuntimeModules:
            true
        case .launch, .attach, .pause, .detach, .terminate, .replaceBreakpoints,
             .pollProcessStatus:
            false
        }
    }

    /// Safe semantic text for diagnostics and accessibility. This is derived only from the typed
    /// operation and must never be replaced with a rendered LLDB command.
    var displayLabel: String {
        switch self {
        case .launch: "Launch"
        case .attach: "Attach"
        case .continue: "Continue"
        case .runToCursor: "Run to Cursor"
        case .stepOver: "Step Over"
        case .stepInto: "Step Into"
        case .stepOut: "Step Out"
        case .pause: "Pause"
        case .detach: "Detach"
        case .terminate: "Terminate"
        case .replaceBreakpoints: "Replace Breakpoints"
        case .reconcileLogicalBreakpoints: "Reconcile Logical Breakpoints"
        case .writeRegister: "Write Register"
        case .readMemory: "Read Memory"
        case .writeMemory: "Write Memory"
        case .updateWatchpoints: "Update Watchpoints"
        case .evaluateExpression: "Evaluate Expression"
        case .expandVariableChildren: "Expand Variable Children"
        case .selectThread: "Select Thread"
        case .selectFrame: "Select Frame"
        case .refreshSnapshot: "Refresh Snapshot"
        case .refreshRuntimeModules: "Refresh Runtime Modules"
        case .pollProcessStatus: "Observe Process Status"
        }
    }
}

struct DebuggerRequestContext: Hashable, Sendable {
    let id: DebuggerRequestID
    let operation: DebuggerOperation
    let expectedSession: DebuggerSessionCoordinate
    let requiredStop: DebuggerStopCoordinate?
    /// Complete requested establishment target, or the exact accepted target for a session-scoped
    /// operation. `nil` is retained only for the legacy nil-target launch compatibility path.
    let targetAuthority: DebuggerSessionTargetAuthority?
    /// Exact opaque node identity for a child-expansion transaction. No other operation may carry it.
    let variableExpansionRequest: DebuggerVariableExpansionRequest?

    init(
        id: DebuggerRequestID,
        operation: DebuggerOperation,
        expectedSession: DebuggerSessionCoordinate,
        requiredStop: DebuggerStopCoordinate? = nil,
        targetAuthority: DebuggerSessionTargetAuthority? = nil,
        variableExpansionRequest: DebuggerVariableExpansionRequest? = nil
    ) {
        self.id = id
        self.operation = operation
        self.expectedSession = expectedSession
        self.requiredStop = requiredStop
        self.targetAuthority = targetAuthority
        self.variableExpansionRequest = variableExpansionRequest
    }

    /// Structural consistency is deliberately separate from reducer admission. It catches a
    /// foreign request/stop coordinate before transport I/O, while the reducer additionally checks
    /// current epoch, revisions, capability, and pending-request state.
    var isInternallyConsistent: Bool {
        guard id.epoch == expectedSession.epoch else { return false }
        if operation.requiresStopCoordinate {
            guard requiredStop?.session == expectedSession else { return false }
        } else if requiredStop != nil {
            return false
        }
        if operation == .expandVariableChildren {
            guard let variableExpansionRequest,
                  let requiredStop,
                  let targetAuthority,
                  variableExpansionRequest.coordinate.stop == requiredStop,
                  variableExpansionRequest.coordinate.targetDigest
                    == DebuggerInspectionTargetDigest(authority: targetAuthority) else {
                return false
            }
        } else if variableExpansionRequest != nil {
            return false
        }
        switch operation {
        case .launch:
            guard let targetAuthority else { return true }
            guard case .launched = targetAuthority.origin else { return false }
            return true
        case .attach:
            guard let targetAuthority,
                  case .attached = targetAuthority.origin else { return false }
            return true
        case .detach:
            guard let targetAuthority,
                  case .attached = targetAuthority.origin else { return false }
            return true
        case .terminate:
            // The sole nil-authority compatibility path is the historical PID-only session
            // established by an explicit nil-target launch. Reducer admission proves that state;
            // every exact-authority terminate request must identify a launched target.
            guard let targetAuthority else { return true }
            guard case .launched = targetAuthority.origin else { return false }
            return true
        case .continue, .runToCursor, .stepOver, .stepInto, .stepOut, .pause,
             .replaceBreakpoints, .reconcileLogicalBreakpoints,
             .writeRegister, .readMemory, .writeMemory, .updateWatchpoints, .evaluateExpression,
             .expandVariableChildren, .selectThread, .selectFrame, .refreshSnapshot,
             .refreshRuntimeModules, .pollProcessStatus:
            return true
        }
    }
}

// MARK: - Typed capabilities

enum DebuggerOperationCapability: Hashable, Sendable {
    case supportedAndObserved
    case unsupported(reason: String)
    case policyDenied(reason: String)

    var isSupported: Bool {
        self == .supportedAndObserved
    }
}

enum DebuggerTransportEventSource: String, Hashable, Sendable {
    case correlatedCLITranscript
}

enum DebuggerPostWriteCancellationBehavior: String, Hashable, Sendable {
    case invalidateAdapterGeneration
}

struct DebuggerTransportMechanics: Hashable, Sendable {
    let supportsExactCorrelatedTranscriptBoundaries: Bool
    let eventSource: DebuggerTransportEventSource
    let supportsCancellationBeforeWrite: Bool
    let postWriteCancellationBehavior: DebuggerPostWriteCancellationBehavior
    let transportFailureInvalidatesEpoch: Bool
    let rawConsoleSharesAcceptedSession: Bool
    let supportsPostFailureInterpreterReuse: Bool

    static let persistentCLI = DebuggerTransportMechanics(
        supportsExactCorrelatedTranscriptBoundaries: true,
        eventSource: .correlatedCLITranscript,
        supportsCancellationBeforeWrite: true,
        postWriteCancellationBehavior: .invalidateAdapterGeneration,
        transportFailureInvalidatesEpoch: true,
        rawConsoleSharesAcceptedSession: true,
        supportsPostFailureInterpreterReuse: false
    )
}

struct DebuggerTransportCapabilities: Hashable, Sendable {
    static let detachUnavailableReason =
        "Detach is unavailable until the persistent LLDB detach transaction is installed."
    private let operationStates: [DebuggerOperation: DebuggerOperationCapability]
    let mechanics: DebuggerTransportMechanics

    init(
        operationStates: [DebuggerOperation: DebuggerOperationCapability],
        mechanics: DebuggerTransportMechanics
    ) {
        precondition(
            Set(operationStates.keys) == Set(DebuggerOperation.allCases),
            "Debugger transport capabilities must classify every semantic operation exactly once."
        )
        self.operationStates = operationStates
        self.mechanics = mechanics
    }

    func capability(for operation: DebuggerOperation) -> DebuggerOperationCapability {
        // The total initializer invariant makes the fallback unreachable. Keeping the lookup
        // non-optional prevents callers from accidentally treating a missing capability as enabled.
        operationStates[operation] ?? .unsupported(reason: "Capability classification is missing.")
    }

    static func persistentCLI(attachPolicyReason: String) -> DebuggerTransportCapabilities {
        var states = Dictionary(
            uniqueKeysWithValues: DebuggerOperation.allCases.map {
                ($0, DebuggerOperationCapability.supportedAndObserved)
            }
        )
        states[.attach] = .policyDenied(reason: attachPolicyReason)
        states[.detach] = .policyDenied(reason: detachUnavailableReason)
        return DebuggerTransportCapabilities(operationStates: states, mechanics: .persistentCLI)
    }
}

// MARK: - Current-stop replacement data

enum DebuggerStoppedCollection<Element>: Hashable, Sendable where Element: Hashable & Sendable {
    case available([Element])
    case unavailable
}

enum DebuggerTransportStopReason: Hashable, Sendable {
    case breakpoint(address: UInt64)
    case step
    case signal(String)
    case userRequested
    case unknown(String)
}

struct DebuggerStoppedThread: Hashable, Sendable {
    let identifier: Int
    let threadID: UInt64?
    let queueName: String?
    let stopReason: DebuggerTransportStopReason?
    let isSelected: Bool
    let topFrameAddress: UInt64?
    let topFrameFunctionName: String?
    let name: String?

    init(
        identifier: Int,
        threadID: UInt64? = nil,
        queueName: String?,
        stopReason: DebuggerTransportStopReason?,
        isSelected: Bool,
        topFrameAddress: UInt64?,
        topFrameFunctionName: String?,
        name: String? = nil
    ) {
        self.identifier = identifier
        self.threadID = threadID
        self.queueName = queueName
        self.stopReason = stopReason
        self.isSelected = isSelected
        self.topFrameAddress = topFrameAddress
        self.topFrameFunctionName = topFrameFunctionName
        self.name = name
    }
}

struct DebuggerStoppedFrame: Hashable, Sendable {
    let identifier: Int
    let address: UInt64
    let functionName: String
    let moduleName: String?
    let sourceLocation: String?
}

enum DebuggerStoppedRegisterGroup: String, Hashable, Sendable {
    case generalPurpose
    case floatingPoint
    case system
    case other
}

struct DebuggerStoppedRegister: Hashable, Sendable {
    let name: String
    let value: String
    let role: String?
    let group: DebuggerStoppedRegisterGroup
}

struct DebuggerStoppedMemoryPreview: Hashable, Sendable {
    let address: UInt64
    let bytes: [UInt8]
    let label: String?
}

struct DebuggerStoppedData: Hashable, Sendable {
    /// Bounded structural-parser failure; never contains quoted target text.
    let threadIdentityDiagnostic: String?
    let threads: DebuggerStoppedCollection<DebuggerStoppedThread>
    let frames: DebuggerStoppedCollection<DebuggerStoppedFrame>
    let registers: DebuggerStoppedCollection<DebuggerStoppedRegister>
    let memoryPreviews: DebuggerStoppedCollection<DebuggerStoppedMemoryPreview>
    let variables: DebuggerStoppedCollection<DebuggerVariableSnapshot>
    let selectedThreadID: Int?
    let selectedFrameID: Int?
    let currentProgramCounter: UInt64?

    init(
        threads: DebuggerStoppedCollection<DebuggerStoppedThread>,
        threadIdentityDiagnostic: String? = nil,
        frames: DebuggerStoppedCollection<DebuggerStoppedFrame>,
        registers: DebuggerStoppedCollection<DebuggerStoppedRegister>,
        memoryPreviews: DebuggerStoppedCollection<DebuggerStoppedMemoryPreview>,
        variables: DebuggerStoppedCollection<DebuggerVariableSnapshot> = .unavailable,
        selectedThreadID: Int?,
        selectedFrameID: Int?,
        currentProgramCounter: UInt64?
    ) {
        self.threads = threads
        self.threadIdentityDiagnostic = threadIdentityDiagnostic
        self.frames = frames
        self.registers = registers
        self.memoryPreviews = memoryPreviews
        self.variables = variables
        self.selectedThreadID = selectedThreadID
        self.selectedFrameID = selectedFrameID
        self.currentProgramCounter = currentProgramCounter
    }

    static let unavailable = DebuggerStoppedData(
        threads: .unavailable,
        frames: .unavailable,
        registers: .unavailable,
        memoryPreviews: .unavailable,
        variables: .unavailable,
        selectedThreadID: nil,
        selectedFrameID: nil,
        currentProgramCounter: nil
    )

    static let empty = DebuggerStoppedData(
        threads: .available([]),
        frames: .available([]),
        registers: .available([]),
        memoryPreviews: .available([]),
        variables: .available([]),
        selectedThreadID: nil,
        selectedFrameID: nil,
        currentProgramCounter: nil
    )
}

struct DebuggerTransportBreakpoint: Hashable, Sendable {
    let address: UInt64
    let isEnabled: Bool
    let condition: String?
    let hitCount: Int
    let ignoreCount: Int
    let backendIdentifier: Int?
}

struct DebuggerExpressionEvaluation: Hashable, Sendable {
    let displayValue: String
    let typeName: String?
}

/// One atomic, exact-stop module collection. Partial pages never cross the typed event boundary.
struct DebuggerRuntimeModulesRefreshPayload: Hashable, Sendable {
    let observations: [DebuggerRuntimeModuleObservation]
    let observedStopID: UInt32
    let processID: Int32
    /// Identity of the retained interpreter generation that produced this complete observation.
    /// The default preserves source compatibility for pure fixtures while production always
    /// supplies its current positive generation.
    let adapterGeneration: UInt64

    init(
        observations: [DebuggerRuntimeModuleObservation],
        observedStopID: UInt32,
        processID: Int32,
        adapterGeneration: UInt64
    ) {
        self.observations = observations
        self.observedStopID = observedStopID
        self.processID = processID
        self.adapterGeneration = adapterGeneration
    }
}

// MARK: - Dispositions and diagnostics

enum DebuggerTargetDisposition: Hashable, Sendable {
    case notApplicable
    case notStarted
    case running(processID: Int32)
    case stopped(processID: Int32)
    case exited(code: Int32?)
    case detached
    case terminated
    case unknown
}

enum DebuggerTransportInvalidationReason: String, Hashable, Sendable {
    case cancellationAfterWrite
    case timeoutAfterWrite
    case endOfFileAfterWrite
    case oversizedTranscript
    case framingLoss
    case adapterFailure
}

enum DebuggerRequestDisposition: Hashable, Sendable {
    case completed(target: DebuggerTargetDisposition)
    case cancelledBeforeWrite
    case failedBeforeWrite
    case invalidatedAfterWrite(
        reason: DebuggerTransportInvalidationReason,
        target: DebuggerTargetDisposition
    )
}

struct DebuggerDiagnosticCode: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        precondition(!rawValue.isEmpty, "Debugger diagnostic codes must not be empty.")
        self.rawValue = rawValue
    }

    static let requestRejected = DebuggerDiagnosticCode(rawValue: "requestRejected")
    static let staleEvent = DebuggerDiagnosticCode(rawValue: "staleEvent")
    static let transportFailure = DebuggerDiagnosticCode(rawValue: "transportFailure")
    static let protocolViolation = DebuggerDiagnosticCode(rawValue: "protocolViolation")
    static let operationFailed = DebuggerDiagnosticCode(rawValue: "operationFailed")
}

enum DebuggerDiagnosticSeverity: String, Hashable, Sendable {
    case information
    case warning
    case error
}

/// Transient redaction inputs. These values are consumed while constructing a diagnostic and are
/// never retained by `DebuggerDiagnostic` itself.
struct DebuggerDiagnosticSensitivityCatalog: Hashable, Sendable {
    let environmentValues: [String]
    let authoredArguments: [String]
    let breakpointConditions: [String]
    let expressionTextsAndResults: [String]
    let registerAndMemoryWriteValues: [String]

    init(
        environmentValues: [String] = [],
        authoredArguments: [String] = [],
        breakpointConditions: [String] = [],
        expressionTextsAndResults: [String] = [],
        registerAndMemoryWriteValues: [String] = []
    ) {
        self.environmentValues = environmentValues
        self.authoredArguments = authoredArguments
        self.breakpointConditions = breakpointConditions
        self.expressionTextsAndResults = expressionTextsAndResults
        self.registerAndMemoryWriteValues = registerAndMemoryWriteValues
    }

    static let empty = DebuggerDiagnosticSensitivityCatalog()

    fileprivate var allValues: [String] {
        environmentValues
            + authoredArguments
            + breakpointConditions
            + expressionTextsAndResults
            + registerAndMemoryWriteValues
    }
}

struct DebuggerDiagnostic: Hashable, Sendable {
    static let maximumInputByteCount = 256 * 1_024
    static let maximumPreviewByteCount = 4 * 1_024

    let code: DebuggerDiagnosticCode
    let severity: DebuggerDiagnosticSeverity
    let semanticLabel: String
    let preview: String
    let fullContentSHA256: String
    let originalByteCount: Int
    let redactedByteCount: Int
    let isTruncated: Bool
    let targetDisposition: DebuggerTargetDisposition

    static func make(
        code: DebuggerDiagnosticCode,
        severity: DebuggerDiagnosticSeverity,
        rawText: String,
        operation: DebuggerOperation? = nil,
        sensitivityCatalog: DebuggerDiagnosticSensitivityCatalog = .empty,
        environmentValues: [String] = [],
        authoredArguments: [String] = [],
        expressionTextsAndResults: [String] = [],
        userHomeDirectory: String? = nil,
        targetDisposition: DebuggerTargetDisposition
    ) -> DebuggerDiagnostic {
        let originalByteCount = rawText.utf8.count
        // Redact before imposing the publication bound. Truncating first can split a catalogued
        // value at the boundary, leaving a sensitive prefix that no longer matches the full token.
        // Control escaping also happens only after replacement so control-bearing expression
        // results and other authored values cannot evade exact redaction.
        let fullyRedacted = redact(
            rawText,
            sensitiveValues: sensitivityCatalog.allValues
                + environmentValues
                + authoredArguments
                + expressionTextsAndResults,
            userHomeDirectory: userHomeDirectory
        )
        let redacted = utf8Prefix(
            fullyRedacted,
            maximumByteCount: maximumInputByteCount
        )
        let redactedBytes = Data(redacted.utf8)
        let digest = SHA256.hash(data: redactedBytes).map {
            String(format: "%02x", $0)
        }.joined()
        let preview = utf8Prefix(redacted, maximumByteCount: maximumPreviewByteCount)

        return DebuggerDiagnostic(
            code: code,
            severity: severity,
            semanticLabel: operation?.displayLabel ?? "Debugger Diagnostic",
            preview: preview,
            fullContentSHA256: digest,
            originalByteCount: originalByteCount,
            redactedByteCount: redacted.utf8.count,
            isTruncated: originalByteCount > maximumInputByteCount
                || fullyRedacted.utf8.count > maximumInputByteCount
                || redacted.utf8.count > maximumPreviewByteCount,
            targetDisposition: targetDisposition
        )
    }

    private static func redact(
        _ text: String,
        sensitiveValues: [String],
        userHomeDirectory: String?
    ) -> String {
        var result = text
        let secrets = Set(sensitiveValues.filter { !$0.isEmpty }).sorted {
            if $0.utf8.count == $1.utf8.count { return $0 < $1 }
            return $0.utf8.count > $1.utf8.count
        }
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        if let home = userHomeDirectory, !home.isEmpty {
            result = result.replacingOccurrences(of: home, with: "<home>")
        }
        return escapeControlCharacters(result)
    }

    private static func escapeControlCharacters(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                result += "\\n"
            case 0x0D:
                result += "\\r"
            case 0x09:
                result += "\\t"
            case 0x00...0x1F, 0x7F:
                result += String(format: "\\u{%04X}", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func utf8Prefix(_ text: String, maximumByteCount: Int) -> String {
        guard maximumByteCount > 0 else { return "" }
        guard text.utf8.count > maximumByteCount else { return text }

        var result = ""
        result.reserveCapacity(maximumByteCount)
        var usedByteCount = 0
        for scalar in text.unicodeScalars {
            let scalarText = String(scalar)
            let scalarByteCount = scalarText.utf8.count
            guard usedByteCount + scalarByteCount <= maximumByteCount else { break }
            result.unicodeScalars.append(scalar)
            usedByteCount += scalarByteCount
        }
        return result
    }
}

// MARK: - Correlated typed event envelope

enum DebuggerEventPayload: Hashable, Sendable {
    /// Legacy PID-only establishment. Accepted only for a nil-target launch request.
    case sessionOpened(observedPID: Int32)
    /// Exact establishment corroborated by the retained transport and reducer request authority.
    case authorizedSessionOpened(
        observedPID: Int32,
        authority: DebuggerSessionTargetAuthority
    )
    case requestStarted
    case processRunning(observedPID: Int32)
    case processStopped(observedPID: Int32, reason: DebuggerTransportStopReason)
    case processExited(observedPID: Int32?, exitCode: Int32?)
    case processDetached(authority: DebuggerSessionTargetAuthority)
    case processTerminated(authority: DebuggerSessionTargetAuthority)
    case stoppedDataRefreshed(DebuggerStoppedData)
    case variableChildrenRefreshed(
        request: DebuggerVariableExpansionRequest,
        snapshot: DebuggerVariableSnapshot
    )
    case breakpointsReplaced([DebuggerTransportBreakpoint])
    case watchpointsUpdated(DebuggerWatchpointUpdate)
    case expressionEvaluated(DebuggerExpressionEvaluation)
    case runtimeModulesRefreshed(DebuggerRuntimeModulesRefreshPayload)
    /// One token-correlated, canonical helper-ring page decoded against the retained binding
    /// ledger. It is intentionally not represented as raw debugger console output.
    case logicalBreakpointCallbacksDrained(DebuggerBreakpointCallbackBatch)
    case requestCompleted(DebuggerRequestDisposition)
    case requestCancelled(DebuggerRequestDisposition)
    case requestFailed(DebuggerDiagnostic)
    case sessionInvalidated(DebuggerDiagnostic)
}

struct DebuggerEventEnvelope: Hashable, Sendable {
    let sessionEpoch: DebuggerSessionEpoch
    let eventSequence: DebuggerEventSequence
    let requestID: DebuggerRequestID?
    let operation: DebuggerOperation?
    let capturedLifecycleRevision: DebuggerLifecycleRevision
    let boundStopRevision: DebuggerStopRevision?
    let payload: DebuggerEventPayload
}
