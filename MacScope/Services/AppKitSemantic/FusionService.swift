import Foundation

public enum AppKitWorkerFailure: String, Codable, Error, Sendable {
    case unavailable, untrustedHelper, timeout, cancelled, outputLimit, crashed
}

public struct AppKitWorkerOutput: Sendable {
    public let json: Data
    public let exitCode: Int32
    public let donorRevision: String
    public init(json: Data, exitCode: Int32, donorRevision: String) {
        self.json = json; self.exitCode = exitCode; self.donorRevision = donorRevision
    }
}

/// Implement ONLY in the signed worker. A conformer must attest the fixed helper,
/// stage these lease bytes, invoke [-J, all, stagedPath], concurrently drain both
/// pipes, enforce 10 MiB stdout/64 KiB stderr/2 s wall cap (the AnalysisWorker watchdog admits 1...2000 ms, `Services/XPC/AnalysisWorkerSupervision.swift:64`), and reap its own child
/// before returning on timeout/cancellation. This protocol is not supervision.
public protocol AppKitNibWorker: Sendable {
    func parse(_ lease: AppKitResourceLease, inputLabel: String) async throws -> AppKitWorkerOutput
}

public enum AppKitFusionState: String, Codable, Sendable {
    case disabled, complete, refused
}

public struct AppKitFusionEnvelope: Codable, Sendable {
    public let schemaVersion: Int
    public let state: AppKitFusionState
    public let claims: [AppKitSemanticClaim]
    public let refusals: [NibRefusal]
    public let workerFailure: AppKitWorkerFailure?
    public let helperExitCodes: [Int32]
}

/// Transient read-only integration entry point. All-or-nothing: any refusal
/// removes every claim. No persistence, decompiler mutation or enabled default.
public struct AppKitFusionService: Sendable {
    public init() {}

    public func analyze(enabled: Bool = false, leases: [AppKitResourceLease],
                        methods: [ObjCMethodFact], allowedImages: Set<AppKitImageKey>,
                        worker: any AppKitNibWorker) async -> AppKitFusionEnvelope {
        func envelope(_ state: AppKitFusionState, claims: [AppKitSemanticClaim] = [],
                      refusals: [NibRefusal] = [], failure: AppKitWorkerFailure? = nil,
                      exits: [Int32] = []) -> AppKitFusionEnvelope {
            .init(schemaVersion: 1, state: state, claims: claims, refusals: refusals,
                  workerFailure: failure, helperExitCodes: exits)
        }
        guard enabled else { return envelope(.disabled) }
        guard leases.count <= 256 else {
            return envelope(.refused, refusals: [.init(inputLabel: "<batch>",
                reason: .tooManyDocuments, detail: "lease document cap 256 exceeded")])
        }
        guard methods.count <= 65_536 else {
            return envelope(.refused, refusals: [.init(inputLabel: "<batch>",
                reason: .tooManyRecords, detail: "method fact cap 65,536 exceeded")])
        }
        guard allowedImages.count <= 256 else {
            return envelope(.refused, refusals: [.init(inputLabel: "<batch>",
                reason: .tooManyRecords, detail: "allowed image cap 256 exceeded")])
        }
        guard Set(leases.map(\.resource.relativePath)).count == leases.count,
              leases.allSatisfy({ lease in
                  lease.resource.hasValidIdentity &&
                  allowedImages.contains(where: {
                      $0.hasValidIdentity && $0.bundleGeneration == lease.resource.bundleGeneration
                  })
              }) else {
            return envelope(.refused, refusals: [.init(inputLabel: "<batch>",
                reason: .invalidResourceIdentity, detail: "resource or image scope not admitted")])
        }
        var claims: [AppKitSemanticClaim] = []
        var exits: [Int32] = []
        var records = 0
        for (index, lease) in leases.sorted(by: { $0.resource.relativePath < $1.resource.relativePath }).enumerated() {
            // Opaque label prevents host paths being copied into wire refusals.
            let label = "resource-\(index).nib"
            do {
                try Task.checkCancellation()
                let output = try await worker.parse(lease, inputLabel: label)
                try Task.checkCancellation()
                exits.append(output.exitCode)
                let batch = NibKitDecoder(limits: .init(maxDocuments: 1,
                    maxRecords: 65_536 - records)).decode(output.json, input: .init(
                    admittedResources: [label: lease.resource], donorRevision: output.donorRevision,
                    helperExitCode: output.exitCode))
                guard batch.complete else {
                    return envelope(.refused, refusals: batch.refusals, exits: exits)
                }
                for document in batch.documents {
                    records += document.outlets.count + document.actions.count +
                        document.runtimeAttributes.count + document.customClasses.count +
                        document.navigation.count + document.navigation.reduce(0) { $0 + ($1.details?.count ?? 0) }
                    switch AppKitFusionEngine().evaluate(document: document,
                        methodFacts: methods, allowedImageKeys: allowedImages) {
                    case .claims(let documentClaims): claims += documentClaims
                    case .refused(let refusal):
                        return envelope(.refused, refusals: [refusal], exits: exits)
                    }
                }
            } catch is CancellationError {
                return envelope(.refused, failure: .cancelled, exits: exits)
            } catch let failure as AppKitWorkerFailure {
                return envelope(.refused, failure: failure, exits: exits)
            } catch {
                return envelope(.refused, failure: .unavailable, exits: exits)
            }
        }
        return envelope(.complete, claims: claims.sorted { $0.claimID < $1.claimID }, exits: exits)
    }
}
