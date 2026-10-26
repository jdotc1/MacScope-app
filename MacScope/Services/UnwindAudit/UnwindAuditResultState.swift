import Foundation

/// Ephemeral publication authority. A fresh workspace generation invalidates all
/// coordinates even when an image is reopened into the same numeric slot.
struct UnwindAuditResultKey: Hashable, Sendable {
    let imageID: UUID
    let slot: ImageSlot
    let generation: UUID
    let identity: MachOSliceArtifactIdentity
    let modelID: String
    let configuration: UnwindAuditLimits

    static let currentModelID = "arm64-bounded-loops-cfa-register-v1"
}

struct UnwindAuditRequest: Hashable, Sendable {
    let id: UUID
    let key: UnwindAuditResultKey
}

struct UnwindAuditNavigationTarget: Hashable, Sendable {
    let key: UnwindAuditResultKey
    let address: UInt64
}

/// Workspace-owned and deliberately absent from workspace persistence.
struct UnwindAuditResultState: Sendable {
    enum Phase: Equatable, Sendable {
        case idle, running, completed, cancelled
        case failed(String)
    }

    private(set) var key: UnwindAuditResultKey?
    private(set) var request: UnwindAuditRequest?
    private(set) var phase: Phase = .idle
    private(set) var report: UnwindAuditReport?
    private(set) var sortedFindings: [UnwindAuditFinding] = []
    private(set) var discardedPublicationCount = 0

    mutating func activate(_ key: UnwindAuditResultKey?) {
        guard self.key != key else { return }
        self.key = key
        request = nil
        report = nil
        sortedFindings = []
        phase = .idle
    }

    mutating func begin(_ key: UnwindAuditResultKey) -> UnwindAuditRequest {
        activate(key)
        let request = UnwindAuditRequest(id: UUID(), key: key)
        self.request = request
        report = nil
        sortedFindings = []
        phase = .running
        return request
    }

    mutating func cancel() {
        guard request != nil else { return }
        request = nil
        phase = .cancelled
    }

    @discardableResult
    mutating func publish(_ report: UnwindAuditReport, for request: UnwindAuditRequest) -> Bool {
        guard accepts(request) else { return discard() }
        guard report.identity == request.key.identity,
              report.analysisModelVersion == request.key.modelID,
              report.configuration == request.key.configuration else {
            _ = discard()
            self.request = nil
            phase = .failed("The audit result does not match the requested image, model, or limits.")
            return false
        }
        do { try report.validate() }
        catch {
            self.request = nil
            phase = .failed("The audit report is invalid: \(error)")
            return false
        }
        self.report = report
        sortedFindings = report.findings.sorted {
            let left = Self.rank($0.verdict), right = Self.rank($1.verdict)
            if left != right { return left < right }
            if $0.function.address != $1.function.address { return $0.function.address < $1.function.address }
            return $0.function.id < $1.function.id
        }
        self.request = nil
        phase = .completed
        return true
    }

    mutating func fail(_ message: String, for request: UnwindAuditRequest) {
        guard accepts(request) else { _ = discard(); return }
        self.request = nil
        phase = .failed(message)
    }

    func navigationTarget(for finding: UnwindAuditFinding, address: UInt64? = nil) -> UnwindAuditNavigationTarget? {
        let address = address ?? finding.function.address
        guard let key, phase == .completed, finding.identity == key.identity,
              report?.findings.contains(finding) == true,
              address >= finding.function.address, address < finding.endAddress else { return nil }
        return .init(key: key, address: address)
    }

    private func accepts(_ request: UnwindAuditRequest) -> Bool {
        phase == .running && self.request == request && key == request.key
    }

    private mutating func discard() -> Bool {
        if discardedPublicationCount < Int.max { discardedPublicationCount += 1 }
        return false
    }

    private static func rank(_ verdict: String) -> Int {
        switch verdict { case "unresolved": 0; case "inconsistency": 1; default: 2 }
    }
}
