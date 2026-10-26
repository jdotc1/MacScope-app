import Foundation

/// Whole-image export through the native provider (audit D10). One serial pass over captured
/// inputs: each function is decompiled by the app-owned native runtime, accepted only through
/// `NativeProviderExportValidation`, and written one bounded block at a time to an owned temporary
/// spool. A per-function report records provider, identity, status and provenance. A function the
/// provider refuses or fails is listed as such; it is never replaced with MacScope pseudocode.
/// A failed or cancelled run removes its spool and never publishes.
enum NativePseudocodeBatchExport {
    /// Proposal defaults from the D10 audit, not measured product limits. Exceeding the aggregate
    /// text or report limit fails the export instead of silently truncating it.
    struct Limits: Codable, Equatable, Sendable {
        var maximumItems = 10_000
        var maximumFunctionTextBytes = 1 << 20
        var maximumTotalTextBytes = 256 << 20
        var maximumRowBytes = 64 << 10
        var maximumReportBytes = 16 << 20
    }

    struct Item: Equatable, Sendable {
        let functionID: UUID
        let startAddress: UInt64
        let name: String
    }

    /// Everything the export binds to, captured once on MainActor. The snapshot is frozen.
    struct Context: Sendable {
        let workspaceID: UUID
        let imageName: String
        let imageSlot: ImageSlot
        let binaryID: UUID
        let artifactUUID: UUID
        let analysisInputFingerprintSHA256: String
        let documentGeneration: UInt64
        let snapshot: WorkspaceSnapshot
    }

    enum Status: String, Codable, Sendable, CaseIterable {
        /// Complete native document.
        case exported
        /// Native document the provider marked truncated.
        case truncated
        /// Native document the provider marked incomplete but not truncated.
        case incomplete
        /// The provider or its projection declined this function. No text written.
        case refused
        /// Worker, runtime, validation or size failure. No text written.
        case failed
    }

    struct Provenance: Codable, Equatable, Sendable {
        let requestSHA256: String
        let analysisInputFingerprintSHA256: String
        let imageID: String
        let artifactUUID: UUID
        let runtime: NativeDecompilerRuntimeIdentity
        /// "executed" or "validated-cache".
        let source: String
    }

    struct Row: Codable, Equatable, Sendable {
        let functionID: String
        let name: String
        let startAddress: String
        let provider: String
        let status: Status
        let reason: String?
        let textByteCount: Int
        let provenance: Provenance?
    }

    struct Report: Codable, Equatable, Sendable {
        var schema = NativePseudocodeBatchExport.reportSchema
        var version = 1
        let provider: String
        let workspaceID: UUID
        let imageName: String
        let imageSlot: Int
        let binaryID: UUID
        let artifactUUID: UUID
        let analysisInputFingerprintSHA256: String
        let documentGeneration: UInt64
        let limits: Limits
        let counts: [String: Int]
        let textByteCount: Int
        let textSHA256: String
        let rows: [Row]
    }

    static let providerName = "native"

    /// `out.c` exported by run `3f2a9b1c-…` → `out.c.3f2a9b1c.report.json`, beside the text. The
    /// full text name (extension kept) and the run's own id make every report name unique, so a
    /// report is always created new and never replaces anything: another export's report (same
    /// stem, other extension, or an earlier run) or a user file (DP16 #693).
    static func reportURL(for textURL: URL, runID: UUID) -> URL {
        textURL.deletingLastPathComponent()
            .appendingPathComponent("\(textURL.lastPathComponent).\(runTag(runID)).report.json")
    }

    /// The first eight hex digits of a run id, as the report name and the text header show it.
    static func runTag(_ runID: UUID) -> String {
        String(runID.uuidString.lowercased().prefix(8))
    }

    static let reportSchema = "macscope.native-pseudocode-batch-report"

    static func items(for analysis: ImageAnalysis) -> [Item] {
        analysis.functions.map { .init(functionID: $0.id, startAddress: $0.startAddress, name: $0.name) }
    }

    static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

    static func singleLine(_ text: String, limit: Int = 160) -> String {
        let flat = text.map { $0.isNewline ? " " : $0 }
        return String(String(flat).prefix(limit))
    }
}

/// App-owned native admission. One export captures and validates its image once, then asks the
/// session for each function.
protocol NativePseudocodeBatchDecompiling: Sendable {
    func beginBatchExport(snapshot: WorkspaceSnapshot, imageSlot: ImageSlot) async throws
        -> any NativePseudocodeBatchSession
}

/// One export's native capture. Cancelling the calling task cancels the native request.
protocol NativePseudocodeBatchSession: Sendable {
    func decompile(functionID: UUID) async throws -> NativeDecompilerValidatedExecution
    /// Synchronous: closes admission and cancels requests in flight.
    func cancel()
    /// Releases the capture. Called once on every exit path.
    func retire() async
}

/// The shared export spool (`PseudocodeExportSpool.swift`) under the names D10 introduced.
typealias NativePseudocodeBatchSink = PseudocodeExportSink
typealias NativePseudocodeBatchSpool = PseudocodeExportSpool

/// One serial native export. Same owner fence and single-use publication contract as
/// `AllPseudocodeExportOperation`; the spool replaces the in-memory join.
final class NativePseudocodeBatchExportOperation: @unchecked Sendable {
    typealias Owner = AllPseudocodeExportOperation.Owner
    typealias Progress = AllPseudocodeExportOperation.Progress
    typealias Batch = NativePseudocodeBatchExport

    enum Failure: Error, Equatable {
        case alreadyStarted
        case staleOwner
        case notPublishable
        case itemLimit
        case duplicateFunction
        case aggregateTextLimit
        case reportLimit
        /// The native runtime or this export's admission ended; no further function can succeed.
        case sessionEnded(String)
    }

    /// Opaque, complete output: a finished spool plus its encoded report.
    struct Output: Sendable {
        fileprivate let operationID: UUID
        fileprivate let sink: any NativePseudocodeBatchSink
        fileprivate let reportData: Data
        let report: Batch.Report
    }

    let owner: Owner
    let context: Batch.Context
    let items: [Batch.Item]
    let limits: Batch.Limits
    private let operationID = UUID()
    private let lock = NSLock()
    private enum State { case idle, running, ready, publishing, published, cancelled, failed }
    private var state = State.idle
    private var cancellationRequested = false
    private var hasStarted = false
    private var cancelInFlight: (@Sendable () -> Void)?
    private var session: (any NativePseudocodeBatchSession)?
    private var pendingSink: (any NativePseudocodeBatchSink)?

    init(owner: Owner, context: Batch.Context, items: [Batch.Item], limits: Batch.Limits = .init()) {
        self.owner = owner
        self.context = context
        self.limits = limits
        self.items = items.sorted {
            $0.startAddress == $1.startAddress
                ? $0.functionID.uuidString < $1.functionID.uuidString
                : $0.startAddress < $1.startAddress
        }
    }

    deinit { pendingSink?.remove() }

    /// Also cancels the native capture and the request in flight.
    func cancel() {
        let (inFlight, session, sink) = lock.withLock {
            () -> ((@Sendable () -> Void)?, (any NativePseudocodeBatchSession)?, (any NativePseudocodeBatchSink)?) in
            cancellationRequested = true
            var sink: (any NativePseudocodeBatchSink)?
            if state == .ready || state == .idle {
                state = .cancelled
                sink = pendingSink
                pendingSink = nil
            }
            return (cancelInFlight, self.session, sink)
        }
        session?.cancel()
        inFlight?()
        sink?.remove()
    }

    /// Runs `work` in a task that `cancel()` reaches, as does cancelling the calling task.
    private func cancellable<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await work() }
        let alreadyCancelled = lock.withLock { () -> Bool in
            cancelInFlight = { task.cancel() }
            return cancellationRequested
        }
        if alreadyCancelled { task.cancel() }
        defer { lock.withLock { cancelInFlight = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    var isCancelled: Bool { lock.withLock { cancellationRequested } }

    private func checkCancellation() throws {
        if Task.isCancelled || lock.withLock({ cancellationRequested }) { throw CancellationError() }
    }

    /// `isCurrent` is asked before every function; a false answer fails the export as stale.
    func run(
        decompiler: any NativePseudocodeBatchDecompiling,
        isCurrent: @Sendable () async -> Bool = { true },
        makeSink: @Sendable () throws -> any NativePseudocodeBatchSink = {
            try NativePseudocodeBatchSpool(prefix: "MacScope-native-export")
        },
        maxProgressUpdates: Int = 32,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Output {
        try lock.withLock {
            guard !hasStarted else { throw Failure.alreadyStarted }
            hasStarted = true
            state = .running
        }
        var completed = 0
        let total = items.count
        let budget = max(1, maxProgressUpdates)
        let stride = max(1, total / budget + (total % budget == 0 ? 0 : 1))
        await progress(Progress(completed: 0, total: total, phase: .rendering))
        var sink: (any NativePseudocodeBatchSink)?
        var nativeSession: (any NativePseudocodeBatchSession)?
        do {
            try checkCancellation()
            guard total <= limits.maximumItems else { throw Failure.itemLimit }
            guard Set(items.map(\.functionID)).count == total else { throw Failure.duplicateFunction }
            let spool = try makeSink()
            sink = spool
            lock.withLock { pendingSink = spool }
            var rows: [Batch.Row] = []
            rows.reserveCapacity(total)
            var textBytes = 0
            var rowBytes = 0
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            func write(_ string: String) throws {
                let data = Data(string.utf8)
                guard data.count <= limits.maximumTotalTextBytes - textBytes else { throw Failure.aggregateTextLimit }
                try spool.append(data)
                textBytes += data.count
            }
            try write(fileHeader())
            // One capture for the whole export. An image the provider cannot capture is reported
            // per function, as each function's own request would have been.
            var captureRefusal: (Batch.Status, String)?
            if total > 0 {
                let context = context
                do {
                    let opened = try await cancellable {
                        try await decompiler.beginBatchExport(snapshot: context.snapshot, imageSlot: context.imageSlot)
                    }
                    nativeSession = opened
                    let cancelled = lock.withLock { () -> Bool in
                        session = opened
                        return cancellationRequested
                    }
                    if cancelled { opened.cancel() }
                } catch {
                    if error is CancellationError { throw error }
                    captureRefusal = try Self.classify(error)
                }
            }
            for item in items {
                try checkCancellation()
                guard await isCurrent() else { throw Failure.staleOwner }
                let rendered: Rendered
                if let nativeSession {
                    rendered = try await render(item, session: nativeSession)
                } else {
                    let (status, reason) = captureRefusal ?? (.failed, "no-native-capture")
                    rendered = marker(item, status: status, reason: reason)
                }
                try checkCancellation()
                let row = rendered.row
                let encodedRow = try encoder.encode(row).count
                guard encodedRow <= limits.maximumRowBytes,
                      encodedRow <= limits.maximumReportBytes - rowBytes else { throw Failure.reportLimit }
                try write("\n\n" + rendered.block)
                rowBytes += encodedRow
                rows.append(row)
                completed += 1
                if completed < total && completed % stride == 0 {
                    await progress(Progress(completed: completed, total: total, phase: .rendering))
                }
            }
            try checkCancellation()
            if let finished = nativeSession {
                nativeSession = nil
                lock.withLock { session = nil }
                await finished.retire()
            }
            let sha = try spool.finish()
            var counts: [String: Int] = [:]
            for status in Batch.Status.allCases { counts[status.rawValue] = rows.filter { $0.status == status }.count }
            let report = Batch.Report(
                provider: Batch.providerName, workspaceID: context.workspaceID, imageName: context.imageName,
                imageSlot: context.imageSlot.rawValue, binaryID: context.binaryID,
                artifactUUID: context.artifactUUID,
                analysisInputFingerprintSHA256: context.analysisInputFingerprintSHA256,
                documentGeneration: context.documentGeneration, limits: limits, counts: counts,
                textByteCount: textBytes, textSHA256: sha, rows: rows)
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let reportData = try encoder.encode(report)
            guard reportData.count <= limits.maximumReportBytes else { throw Failure.reportLimit }
            try lock.withLock {
                guard !cancellationRequested else { throw CancellationError() }
                state = .ready
            }
            await progress(Progress(completed: completed, total: total, phase: .completed))
            return Output(operationID: operationID, sink: spool, reportData: reportData, report: report)
        } catch {
            let cancelled = error is CancellationError
            lock.withLock {
                state = cancelled ? .cancelled : .failed
                pendingSink = nil
                session = nil
            }
            sink?.remove()
            if let nativeSession {
                nativeSession.cancel()
                await nativeSession.retire()
            }
            await progress(Progress(completed: completed, total: total, phase: cancelled ? .cancelled : .failed))
            throw error
        }
    }

    /// Call on MainActor immediately after the live owner/window fence, with no intervening await.
    /// Commits the text, then the report; if the report cannot be committed the text destination
    /// is restored to what it was. Returns the report URL. The spool is removed either way.
    @MainActor
    @discardableResult
    func publish(_ output: Output, currentOwner: Owner, to destination: URL,
                 fileManager: FileManager = .default) throws -> URL {
        try lock.withLock {
            guard !cancellationRequested else { throw CancellationError() }
            guard owner == currentOwner else { throw Failure.staleOwner }
            guard state == .ready, output.operationID == operationID else { throw Failure.notPublishable }
            state = .publishing
            pendingSink = nil
        }
        defer { output.sink.remove() }
        let reportURL = Batch.reportURL(for: destination, runID: output.operationID)
        do {
            try PseudocodeExportPublication.withStaging(for: destination, fileManager: fileManager) { staging in
                let stagedText = staging.appendingPathComponent("text")
                let stagedReport = staging.appendingPathComponent("report")
                try fileManager.copyItem(at: output.sink.textURL, to: stagedText)
                try output.reportData.write(to: stagedReport)
                // The spool is owner-only; published files get the ordinary mode, as Export All's do.
                for staged in [stagedText, stagedReport] {
                    try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path)
                }
                let backupName = ".\(destination.lastPathComponent).macscope-export-backup-\(UUID().uuidString)"
                let backupURL = destination.deletingLastPathComponent().appendingPathComponent(backupName)
                let hadPrior = try PseudocodeExportPublication.commit(stagedText, to: destination,
                                                                      backupName: backupName, fileManager: fileManager)
                do {
                    // The save panel chose only the text. The report gets a name of its own (see
                    // `reportURL`) and is moved into place without overwriting: if anything were
                    // already there the move fails and the export reports it, replacing nothing.
                    try fileManager.moveItem(at: stagedReport, to: reportURL)
                } catch {
                    if hadPrior {
                        _ = try? fileManager.replaceItemAt(destination, withItemAt: backupURL)
                    } else {
                        try? fileManager.removeItem(at: destination)
                    }
                    throw error
                }
                if hadPrior { try? fileManager.removeItem(at: backupURL) }
            }
            lock.withLock { state = .published }
            return reportURL
        } catch {
            lock.withLock { state = .failed }
            throw error
        }
    }

    private func fileHeader() -> String {
        [
            "// MacScope pseudocode export — provider: Native, whole image",
            "// Workspace: \(context.workspaceID.uuidString.lowercased())",
            "// Image: \(Batch.singleLine(context.imageName)) [slot \(context.imageSlot.rawValue), binary \(context.binaryID.uuidString.lowercased())]",
            "// Artifact: \(context.artifactUUID.uuidString.lowercased())",
            "// Analysis fingerprint: \(context.analysisInputFingerprintSHA256)",
            "// Captured document/authoring revision: \(context.documentGeneration)",
            "// Per-function status and provenance: the .\(Batch.runTag(operationID)).report.json file beside this one.",
            "// Functions the native provider refused or failed are listed, not replaced with MacScope pseudocode.",
        ].joined(separator: "\n")
    }

    private struct Rendered {
        let row: Batch.Row
        let block: String
    }

    /// Per-function outcomes become rows; fatal runtime/admission errors and cancellation throw.
    private func render(_ item: Batch.Item,
                        session: any NativePseudocodeBatchSession) async throws -> Rendered {
        let functionID = item.functionID
        let result: Result<NativeDecompilerValidatedExecution, Error>
        do {
            result = .success(try await cancellable { try await session.decompile(functionID: functionID) })
        } catch {
            result = .failure(error)
        }
        try checkCancellation()
        switch result {
        case .failure(let error):
            if error is CancellationError { throw error }
            let (status, reason) = try Self.classify(error)
            return marker(item, status: status, reason: reason)
        case .success(let execution):
            guard execution.functionID == item.functionID, execution.imageSlot == context.imageSlot,
                  execution.analysisInputFingerprintSHA256 == context.analysisInputFingerprintSHA256 else {
                return marker(item, status: .failed, reason: "validation-identity-mismatch")
            }
            let document: NativeDecompilerWirePseudocodeDocument
            do {
                document = try NativeProviderExportValidation.acceptedDocument(execution.success, expected: .init(
                    requestSHA256: execution.requestSHA256, artifactUUID: context.artifactUUID, imageID: nil,
                    functionID: item.functionID.uuidString.lowercased(), entryAddress: item.startAddress))
            } catch NativeProviderExportValidation.Rejection.providerUnavailable {
                return marker(item, status: .refused, reason: "provider-unavailable")
            } catch NativeProviderExportValidation.Rejection.missingDocument {
                return marker(item, status: .refused, reason: "no-native-document")
            } catch {
                return marker(item, status: .failed, reason: "validation-identity-mismatch")
            }
            let text = Data(document.text.utf8)
            guard text.count <= limits.maximumFunctionTextBytes else {
                return marker(item, status: .failed, reason: "function-text-over-limit")
            }
            let status: Batch.Status = document.isTruncated ? .truncated : (document.isComplete ? .exported : .incomplete)
            let source: String
            switch execution.source {
            case .executed: source = "executed"
            case .validatedCache: source = "validated-cache"
            }
            let provenance = Batch.Provenance(
                requestSHA256: execution.requestSHA256,
                analysisInputFingerprintSHA256: execution.analysisInputFingerprintSHA256,
                imageID: execution.success.result.image.imageID, artifactUUID: context.artifactUUID,
                runtime: execution.success.availability.runtimeIdentity, source: source)
            let label = status == .exported ? "native" : "native, \(status.rawValue)"
            let block = "// ===== \(Batch.singleLine(item.name)) @ \(Batch.hex(item.startAddress)) — \(label) =====\n"
                + "// function \(item.functionID.uuidString.lowercased()); request \(execution.requestSHA256)\n"
                + document.text
            let reason: String? = switch status {
            case .truncated: "native-document-truncated-output-budget"
            case .incomplete: "native-document-incomplete"
            default: nil
            }
            return Rendered(row: row(item, status: status, reason: reason, bytes: text.count, provenance: provenance),
                            block: block)
        }
    }

    private func marker(_ item: Batch.Item, status: Batch.Status, reason: String) -> Rendered {
        Rendered(row: row(item, status: status, reason: reason, bytes: 0, provenance: nil),
                 block: "// ===== \(Batch.singleLine(item.name)) @ \(Batch.hex(item.startAddress)) — not exported: \(status.rawValue) (\(reason)) =====")
    }

    private func row(_ item: Batch.Item, status: Batch.Status, reason: String?, bytes: Int,
                     provenance: Batch.Provenance?) -> Batch.Row {
        Batch.Row(functionID: item.functionID.uuidString.lowercased(), name: Batch.singleLine(item.name, limit: 512),
                  startAddress: Batch.hex(item.startAddress), provider: Batch.providerName, status: status,
                  reason: reason, textByteCount: bytes, provenance: provenance)
    }

    /// Per-function refusal or failure versus a fatal session error (thrown).
    static func classify(_ error: Error) throws -> (Batch.Status, String) {
        switch error {
        case let NativeDecompilerOwnerAdmissionError.terminalProviderResult(reason):
            return (.refused, Batch.singleLine(reason))
        case NativeDecompilerOwnerAdmissionError.ownerRetired:
            throw Failure.sessionEnded("export-owner-retired")
        case NativeDecompilerProcessRuntimeError.shutDown:
            throw Failure.sessionEnded("native-runtime-shut-down")
        case let error as NativeDecompilerSnapshotProjectionError:
            return (.refused, Batch.singleLine("projection-\(error)"))
        case let error as NativeDecompilerProcessRuntimeError:
            return (.failed, Batch.singleLine("runtime-\(error)"))
        case let error as NativeDecompilerRuntimeValidationError:
            return (.failed, Batch.singleLine("runtime-validation-\(error)"))
        case is ReconstructionValidationError:
            return (.failed, "invalid-request")
        default:
            return (.failed, Batch.singleLine("error-\(type(of: error))"))
        }
    }
}
