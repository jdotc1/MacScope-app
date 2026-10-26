import CryptoKit
import Foundation
import XCTest

@testable import MacScope

final class Phase2InstalledShellSmokeRunnerTests: XCTestCase {
    private typealias Runner = Phase2InstalledShellSmokeRunner

    func testSchemaAndRendererModeEnvironmentMatchConsumerContract() throws {
        XCTAssertEqual(Runner.schemaVersion, 5)
        XCTAssertEqual(
            try Runner.rendererMode(environment: [
                Runner.rendererModeEnvironmentKey: "defaultFullGhosttySurface"
            ]),
            .defaultFullGhosttySurface
        )
        XCTAssertEqual(
            try Runner.rendererMode(environment: [
                Runner.rendererModeEnvironmentKey: "forcedLegacyGridRecoveryOverride"
            ]),
            .forcedLegacyGridRecoveryOverride
        )
        XCTAssertThrowsError(try Runner.rendererMode(environment: [:]))
        XCTAssertThrowsError(try Runner.rendererMode(environment: [
            Runner.rendererModeEnvironmentKey: "unknown"
        ]))
    }

    func testDefaultFullSurfaceEvidenceEncodesExactlyClosedConsumerRecord() throws {
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let evidence = try Runner.validateRendererEvidence(
            request: request,
            observation: validObservation(for: request)
        )

        let object = try encodedObject(evidence)
        XCTAssertEqual(Set(object.keys), rendererEvidenceKeys)
        XCTAssertEqual(object["requestedMode"] as? String, "defaultFullGhosttySurface")
        XCTAssertEqual(object["selectedBackend"] as? String, "ghosttyFullSurface")
        XCTAssertTrue(object["fallbackReason"] is NSNull)
        XCTAssertEqual(object["rendererPresented"] as? Bool, true)
        XCTAssertEqual(object["transcriptOnlyFallbackPresented"] as? Bool, false)
        XCTAssertEqual(
            object["shellSessionID"] as? String,
            request.shellSessionID.uuidString.lowercased()
        )
        XCTAssertEqual(
            object["shellRequestID"] as? String,
            request.shellRequestID.uuidString.lowercased()
        )
        XCTAssertEqual(
            object["shellProcessIdentifier"] as? Int,
            Int(request.shellProcessIdentifier)
        )
    }

    func testForcedLegacyEvidenceRequiresRealGridAndRecoveryOverride() throws {
        let request = rendererRequest(mode: .forcedLegacyGridRecoveryOverride)
        let evidence = try Runner.validateRendererEvidence(
            request: request,
            observation: validObservation(for: request)
        )

        let object = try encodedObject(evidence)
        XCTAssertEqual(Set(object.keys), rendererEvidenceKeys)
        XCTAssertEqual(
            object["requestedMode"] as? String,
            "forcedLegacyGridRecoveryOverride"
        )
        XCTAssertEqual(object["selectedBackend"] as? String, "macScopeGhosttyVTGrid")
        XCTAssertEqual(object["fallbackReason"] as? String, "recoveryOverride")
    }

    func testRendererEvidenceRejectsStaleGenerationAndMismatchedShellCoordinate() {
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let valid = validObservation(for: request)
        let mismatches: [Runner.RendererRuntimeEvidence] = [
            .init(
                requestedMode: valid.requestedMode,
                generation: UUID(),
                selectedBackend: valid.selectedBackend,
                fallbackReason: valid.fallbackReason,
                rendererPresented: true,
                transcriptOnlyFallbackPresented: false,
                shellSessionID: valid.shellSessionID,
                shellRequestID: valid.shellRequestID,
                shellProcessIdentifier: valid.shellProcessIdentifier
            ),
            .init(
                requestedMode: valid.requestedMode,
                generation: valid.generation,
                selectedBackend: valid.selectedBackend,
                fallbackReason: valid.fallbackReason,
                rendererPresented: true,
                transcriptOnlyFallbackPresented: false,
                shellSessionID: UUID(),
                shellRequestID: valid.shellRequestID,
                shellProcessIdentifier: valid.shellProcessIdentifier
            ),
            .init(
                requestedMode: valid.requestedMode,
                generation: valid.generation,
                selectedBackend: valid.selectedBackend,
                fallbackReason: valid.fallbackReason,
                rendererPresented: true,
                transcriptOnlyFallbackPresented: false,
                shellSessionID: valid.shellSessionID,
                shellRequestID: UUID(),
                shellProcessIdentifier: valid.shellProcessIdentifier
            ),
            .init(
                requestedMode: valid.requestedMode,
                generation: valid.generation,
                selectedBackend: valid.selectedBackend,
                fallbackReason: valid.fallbackReason,
                rendererPresented: true,
                transcriptOnlyFallbackPresented: false,
                shellSessionID: valid.shellSessionID,
                shellRequestID: valid.shellRequestID,
                shellProcessIdentifier: valid.shellProcessIdentifier + 1
            ),
        ]

        for observation in mismatches {
            XCTAssertThrowsError(
                try Runner.validateRendererEvidence(request: request, observation: observation)
            )
        }
    }

    func testRendererEvidenceRejectsAbsentPresentationAndTranscriptOnlyFallback() {
        let request = rendererRequest(mode: .defaultFullGhosttySurface)
        let valid = validObservation(for: request)
        let rejected: [Runner.RendererRuntimeEvidence] = [
            .init(
                requestedMode: valid.requestedMode,
                generation: valid.generation,
                selectedBackend: valid.selectedBackend,
                fallbackReason: valid.fallbackReason,
                rendererPresented: false,
                transcriptOnlyFallbackPresented: false,
                shellSessionID: valid.shellSessionID,
                shellRequestID: valid.shellRequestID,
                shellProcessIdentifier: valid.shellProcessIdentifier
            ),
            .init(
                requestedMode: valid.requestedMode,
                generation: valid.generation,
                selectedBackend: valid.selectedBackend,
                fallbackReason: valid.fallbackReason,
                rendererPresented: true,
                transcriptOnlyFallbackPresented: true,
                shellSessionID: valid.shellSessionID,
                shellRequestID: valid.shellRequestID,
                shellProcessIdentifier: valid.shellProcessIdentifier
            ),
        ]

        for observation in rejected {
            XCTAssertThrowsError(
                try Runner.validateRendererEvidence(request: request, observation: observation)
            )
        }
    }

    func testRendererEvidenceRejectsWrongBackendFallbackOrMode() {
        let request = rendererRequest(mode: .forcedLegacyGridRecoveryOverride)
        let valid = validObservation(for: request)
        let rejected: [Runner.RendererRuntimeEvidence] = [
            .init(
                requestedMode: .defaultFullGhosttySurface,
                generation: valid.generation,
                selectedBackend: valid.selectedBackend,
                fallbackReason: valid.fallbackReason,
                rendererPresented: true,
                transcriptOnlyFallbackPresented: false,
                shellSessionID: valid.shellSessionID,
                shellRequestID: valid.shellRequestID,
                shellProcessIdentifier: valid.shellProcessIdentifier
            ),
            .init(
                requestedMode: valid.requestedMode,
                generation: valid.generation,
                selectedBackend: .ghosttyFullSurface,
                fallbackReason: nil,
                rendererPresented: true,
                transcriptOnlyFallbackPresented: false,
                shellSessionID: valid.shellSessionID,
                shellRequestID: valid.shellRequestID,
                shellProcessIdentifier: valid.shellProcessIdentifier
            ),
            .init(
                requestedMode: valid.requestedMode,
                generation: valid.generation,
                selectedBackend: valid.selectedBackend,
                fallbackReason: nil,
                rendererPresented: true,
                transcriptOnlyFallbackPresented: false,
                shellSessionID: valid.shellSessionID,
                shellRequestID: valid.shellRequestID,
                shellProcessIdentifier: valid.shellProcessIdentifier
            ),
        ]

        for observation in rejected {
            XCTAssertThrowsError(
                try Runner.validateRendererEvidence(request: request, observation: observation)
            )
        }
    }

    func testCleanupProofRejectsAbsentOrFalseProcessAbsence() {
        XCTAssertNoThrow(try Runner.validateCleanupObservedProcessAbsent(true))
        XCTAssertThrowsError(try Runner.validateCleanupObservedProcessAbsent(false))
        XCTAssertThrowsError(try Runner.validateCleanupObservedProcessAbsent(nil))
    }

    func testTransportDeadlineResetsANeverReplyingOperation() async {
        let transport = Phase2InstalledShellSmokeDeadlineTransport()
        let started = Date()
        do {
            try await Runner.withTransportDeadline(
                timeoutSeconds: 0.03,
                operationDescription: "focused never-replying operation",
                transport: transport
            ) {
                try await transport.neverReply()
            }
            XCTFail("never-replying operation unexpectedly completed")
        } catch {
            // Expected timeout.
        }
        XCTAssertGreaterThanOrEqual(transport.observedResetCount, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testTransportDeadlineCancellationResetsPendingOperationPromptly() async {
        let transport = Phase2InstalledShellSmokeDeadlineTransport()
        let started = Date()
        let task = Task {
            try await Runner.withTransportDeadline(
                timeoutSeconds: 1,
                operationDescription: "focused cancelled operation",
                transport: transport
            ) {
                try await transport.neverReply()
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled operation unexpectedly completed")
        } catch {
            // Expected cancellation/reset failure.
        }
        XCTAssertGreaterThanOrEqual(transport.observedResetCount, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testReleaseProvenanceBindsCommitTreeAndExactFileDigest() throws {
        let directory = try temporaryDirectory()
        let provenanceURL = directory.appendingPathComponent("MacScopeBuildProvenance.json")
        let data = try provenanceData()
        try data.write(to: provenanceURL)

        let identity = try Runner.loadBuildIdentity(provenanceURL: provenanceURL)

        XCTAssertEqual(identity.sourceCommit, String(repeating: "a", count: 40))
        XCTAssertEqual(identity.sourceTree, String(repeating: "b", count: 40))
        XCTAssertEqual(identity.buildProvenanceSHA256, sha256Hex(data))
    }

    func testProvenanceRejectsNonReleaseAndNonFullSurfaceBuilds() throws {
        let directory = try temporaryDirectory()
        let debugURL = directory.appendingPathComponent("debug.json")
        try provenanceData(configuration: "Debug").write(to: debugURL)
        XCTAssertThrowsError(try Runner.loadBuildIdentity(provenanceURL: debugURL))

        let ineligibleURL = directory.appendingPathComponent("ineligible.json")
        try provenanceData(qualificationEligible: false).write(to: ineligibleURL)
        XCTAssertThrowsError(try Runner.loadBuildIdentity(provenanceURL: ineligibleURL))

        let legacyURL = directory.appendingPathComponent("legacy.json")
        try provenanceData(ghosttyCondition: "").write(to: legacyURL)
        XCTAssertThrowsError(try Runner.loadBuildIdentity(provenanceURL: legacyURL))
    }

    func testProvenanceRejectsSymlinkAndMultiplyLinkedFile() throws {
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.json")
        try provenanceData().write(to: sourceURL)

        let symlinkURL = directory.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: sourceURL)
        XCTAssertThrowsError(try Runner.loadBuildIdentity(provenanceURL: symlinkURL))

        let hardlinkURL = directory.appendingPathComponent("hardlink.json")
        try FileManager.default.linkItem(at: sourceURL, to: hardlinkURL)
        XCTAssertThrowsError(try Runner.loadBuildIdentity(provenanceURL: hardlinkURL))
    }

    private var rendererEvidenceKeys: Set<String> {
        [
            "requestedMode",
            "selectedBackend",
            "fallbackReason",
            "rendererPresented",
            "transcriptOnlyFallbackPresented",
            "shellSessionID",
            "shellRequestID",
            "shellProcessIdentifier",
        ]
    }

    private func rendererRequest(mode: Runner.RendererMode) -> Runner.RendererEvidenceRequest {
        .init(
            requestedMode: mode,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            shellSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            shellRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            shellProcessIdentifier: 4_321
        )
    }

    private func validObservation(
        for request: Runner.RendererEvidenceRequest
    ) -> Runner.RendererRuntimeEvidence {
        let backend: Runner.RendererBackend
        let fallback: Runner.RendererFallbackReason?
        switch request.requestedMode {
        case .defaultFullGhosttySurface:
            backend = .ghosttyFullSurface
            fallback = nil
        case .forcedLegacyGridRecoveryOverride:
            backend = .macScopeGhosttyVTGrid
            fallback = .recoveryOverride
        }
        return .init(
            requestedMode: request.requestedMode,
            generation: request.generation,
            selectedBackend: backend,
            fallbackReason: fallback,
            rendererPresented: true,
            transcriptOnlyFallbackPresented: false,
            shellSessionID: request.shellSessionID,
            shellRequestID: request.shellRequestID,
            shellProcessIdentifier: request.shellProcessIdentifier
        )
    }

    private func encodedObject(
        _ evidence: Runner.RendererEvidence
    ) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase2InstalledShellSmokeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func provenanceData(
        configuration: String = "Release",
        qualificationEligible: Bool = true,
        ghosttyCondition: String = "MACSCOPE_FULL_GHOSTTY_SURFACE"
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "schema_version": 1,
                "qualification_eligible": qualificationEligible,
                "configuration": configuration,
                "git_head_commit": String(repeating: "a", count: 40),
                "git_head_tree": String(repeating: "b", count: 40),
                "repository_clean": true,
                "ghostty_surface_compilation_condition": ghosttyCondition,
            ],
            options: [.sortedKeys]
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class Phase2InstalledShellSmokeDeadlineTransport:
    MacScope.ShellBrokerXPCTransport,
    @unchecked Sendable {
    private enum Failure: Error {
        case reset
        case unsupported
    }

    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, Error>?
    private var resetCount = 0
    private var didReset = false

    var observedResetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resetCount
    }

    func neverReply() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if didReset {
                lock.unlock()
                continuation.resume(throwing: Failure.reset)
                return
            }
            pending = continuation
            lock.unlock()
        }
    }

    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake {
        throw Failure.unsupported
    }

    func perform(
        _ request: MacScope.Phase2ShellBrokerCommandRequest
    ) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        _ = request
        throw Failure.unsupported
    }

    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        throw Failure.unsupported
    }

    func revalidateBrokerProcessReceipt(
        _ receipt: MacScope.ShellBrokerXPCProcessReceipt
    ) async -> Bool {
        _ = receipt
        return false
    }

    func reset() async {
        let continuation = recordReset()
        continuation?.resume(throwing: Failure.reset)
    }

    private func recordReset() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        resetCount += 1
        didReset = true
        let continuation = pending
        pending = nil
        return continuation
    }
}
