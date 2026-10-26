import Foundation
import Combine

enum PatternPhase: Equatable {
    case empty, running, completed, partial, timeout, unavailable, refused, cancelled, stale
}

@MainActor
final class PatternInterpretationOwner: ObservableObject {
    @Published private(set) var phase: PatternPhase = .empty
    @Published private(set) var revealCommand: PatternRevealCommand?
    private(set) var generation = UUID()
    private var capture: PatternAppCapture?
    private var admitted: ValidatedPatternInterpretation?
    private var task: Task<Void, Never>?
    private let transport: any PatternAppTransport
    private let live: () -> (PatternPaneFrame, Range<Int>, String, String)
    var available: Bool { transport.available }

    init(transport: any PatternAppTransport = UnavailablePatternAppTransport(),
         live: @escaping () -> (PatternPaneFrame, Range<Int>, String, String)) {
        self.transport = transport; self.live = live
        phase = transport.available ? .empty : .unavailable
    }

    func start(capture: PatternAppCapture) {
        invalidate()
        guard available else { phase = .unavailable; return }
        guard isCurrent(capture) else { phase = .stale; return }
        self.capture = capture
        let token = generation
        let requestID = capture.request.requestID
        let payload: Data
        do {
            payload = try JSONEncoder().encode(capture.request)
            guard payload.count <= 2_097_152 else { phase = .refused; return }
        } catch { phase = .refused; return }
        phase = .running
        task = Task { [weak self, transport] in
            do {
                try Task.checkCancellation()
                guard let self, self.generation == token, self.phase == .running,
                      self.isCurrent(capture) else { return }
                let data = try await transport.send(requestID: requestID, payload: payload)
                self.accept(data: data, requestID: requestID, generation: token)
            } catch {
                guard let self, self.generation == token, self.phase == .running else { return }
                self.admitted = nil; self.revealCommand = nil
                if error is CancellationError { self.phase = .cancelled }
                else if let failure = error as? OwnedChildController.Failure {
                    switch failure {
                    case .timedOut: self.phase = .timeout
                    case .cancelled: self.phase = .cancelled
                    case .unavailable: self.phase = .unavailable
                    default: self.phase = .refused
                    }
                } else if case PatternInterpretationError.nativeUnavailable = error {
                    self.phase = .unavailable
                } else { self.phase = .refused }
            }
        }
    }

    func invalidate() {
        let old = capture?.request.requestID
        generation = UUID() // Revoke publication before any callback/cancel can run.
        capture = nil; admitted = nil; revealCommand = nil; phase = .stale
        task?.cancel(); task = nil
        if let old { transport.cancel(requestID: old) }
    }
    func cancel() { invalidate(); phase = .cancelled }

    private func isCurrent(_ capture: PatternAppCapture) -> Bool {
        let value = live()
        return capture.current(frame: value.0, record: value.1,
                               source: value.2, sourceIdentity: value.3)
    }

    func accept(data: Data, requestID: UUID, generation token: UUID) {
        guard token == generation, phase == .running,
              let capture, capture.request.requestID == requestID else { return }
        guard isCurrent(capture) else { invalidate(); return }
        do {
            let result = try ValidatedPatternInterpretation.decode(data, for: capture.request) {
                PatternInterpretationLiveCapture(currentKey: capture.request.key,
                    activeRequestID: self.capture?.request.requestID,
                    isCurrent: self.generation == token && self.isCurrent(capture))
            }
            guard generation == token, isCurrent(capture) else { invalidate(); return }
            switch result.reply.status {
            case .completed: admitted = result; phase = .completed
            case .partial: admitted = result; phase = .partial
            case .timedOut: phase = .timeout
            case .cancelled: phase = .cancelled
            case .rejected, .failed: phase = .refused
            }
        } catch { admitted = nil; revealCommand = nil; phase = .refused }
    }

    func nodesIfCurrent(frame: PatternPaneFrame, record: Range<Int>, source: String,
                        sourceIdentity: String) -> [PatternField] {
        guard let capture, capture.current(frame: frame, record: record,
                source: source, sourceIdentity: sourceIdentity), isCurrent(capture) else { return [] }
        return admitted?.reply.nodes ?? []
    }
    func diagnosticsIfCurrent(frame: PatternPaneFrame, record: Range<Int>, source: String,
                              sourceIdentity: String) -> [PatternDiagnostic] {
        guard let capture, capture.current(frame: frame, record: record,
                source: source, sourceIdentity: sourceIdentity), isCurrent(capture) else { return [] }
        return admitted?.reply.diagnostics ?? []
    }
    func revealCommandIfCurrent(frame: PatternPaneFrame, record: Range<Int>, source: String,
                                sourceIdentity: String) -> PatternRevealCommand? {
        guard let capture, admitted != nil, capture.current(frame: frame, record: record,
                source: source, sourceIdentity: sourceIdentity), isCurrent(capture) else { return nil }
        return revealCommand
    }
    private func revealRange(fieldID: UInt64, generation token: UUID) -> Range<Int>? {
        guard token == generation, let capture, let admitted else { return nil }
        let value = live()
        return capture.reveal(fieldID: fieldID, admitted: admitted, frame: value.0,
                              record: value.1, source: value.2, sourceIdentity: value.3)
    }
    func canReveal(fieldID: UInt64, generation: UUID) -> Bool {
        revealRange(fieldID: fieldID, generation: generation) != nil
    }
    @discardableResult
    func reveal(fieldID: UInt64, generation: UUID) -> Range<Int>? {
        guard let range = revealRange(fieldID: fieldID, generation: generation) else {
            revealCommand = nil; return nil
        }
        revealCommand = PatternRevealCommand(range: range, token: UUID())
        return range
    }
}
