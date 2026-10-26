import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import MacScope

#if DEBUG
final class ReconstructionInstalledPauseQualificationBarrierTests: XCTestCase {
    func testExplicitOwnedRootHoldsPauseUntilCreateOnlyRelease() async throws {
        let root = try makeOwnedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await assertPauseRelease(at: root)
    }

    func testNamedRunnerContainerRootHoldsPauseUntilCreateOnlyRelease() async throws {
        let parent = try XCTUnwrap(
            ReconstructionInstalledQualificationBarrierRoot.runnerTemporaryDirectory
        )
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw XCTSkip("Installed runner container has not been created on this host")
        }
        let root = parent.appendingPathComponent("MacScope-Task10-PauseBarrier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try await assertPauseRelease(at: root)
    }

    func testSharedRootAuthorityRejectsWrongParentsModesAndLinks() throws {
        let root = try makeOwnedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = "MacScope-Task10-PauseBarrier-"
        let validDescriptor = try XCTUnwrap(
            ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(root.path, prefix: prefix)
        )
        Darwin.close(validDescriptor)
        XCTAssertNil(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(
            root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"), prefix: prefix
        ))
        XCTAssertNil(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(
            root.path + "/../" + root.lastPathComponent, prefix: prefix
        ))
        XCTAssertNil(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(
            root.path, prefix: "MacScope-Task10-RevealBarrier-"
        ))
        XCTAssertNil(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(
            "/private/tmp/" + prefix + "not-a-uuid", prefix: prefix
        ))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertNil(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(root.path, prefix: prefix))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let nested = root.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertNil(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(nested.path, prefix: prefix))
        let link = URL(fileURLWithPath: "/private/tmp/" + prefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertNil(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(link.path, prefix: prefix))
    }

    func testSharedRootAuthorityAcceptsRevealLeafOnlyInNamedRunnerContainer() throws {
        let parent = try XCTUnwrap(ReconstructionInstalledQualificationBarrierRoot.runnerTemporaryDirectory)
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw XCTSkip("Installed runner container has not been created on this host")
        }
        let prefix = "MacScope-Task10-RevealBarrier-"
        let root = parent.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try XCTUnwrap(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(root.path, prefix: prefix))
        Darwin.close(descriptor)
        XCTAssertNil(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(
            root.path.replacingOccurrences(of: "MacScopeInstalledAppUITests.xctrunner", with: "OtherTests.xctrunner"), prefix: prefix
        ))
        XCTAssertNil(ReconstructionInstalledQualificationBarrierRoot.openOwnedRoot(
            root.path.replacingOccurrences(of: "/Data/tmp/", with: "/Data/Library/"), prefix: prefix
        ))
    }

    private func assertPauseRelease(at root: URL) async throws {
        let jobID = UUID(uuidString: "10000000-0000-0000-0000-000000000006")!
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidateSHA256 = try sha256Hex(of: executableURL)
        let environment = [
            ReconstructionInstalledPauseQualificationBarrier.runEnvironmentKey: "1",
            ReconstructionInstalledPauseQualificationBarrier.rootEnvironmentKey: root.path,
            ReconstructionInstalledPauseQualificationBarrier.candidateSHA256EnvironmentKey:
                candidateSHA256,
        ]
        let completion = PauseBarrierCompletion()
        let barrierTask = Task {
            let result = await ReconstructionInstalledPauseQualificationBarrier.waitIfRequested(
                reason: .pausedByUser,
                jobID: jobID,
                environment: environment,
                executableURL: executableURL
            )
            await completion.record(result)
            return result
        }

        let arrival = root.appendingPathComponent(
            ReconstructionInstalledPauseQualificationBarrier.arrivalFilename
        )
        try await waitForRegularFile(arrival)
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: arrival))
            as? [String: Any]
        XCTAssertEqual(receipt?["kind"] as? String, "pause")
        XCTAssertEqual(receipt?["jobID"] as? String, jobID.uuidString.lowercased())
        XCTAssertEqual(receipt?["candidateSHA256"] as? String, candidateSHA256)
        XCTAssertEqual(
            receipt?["pid"] as? Int,
            Int(ProcessInfo.processInfo.processIdentifier)
        )

        try await Task.sleep(nanoseconds: 80_000_000)
        let prematureCompletion = await completion.value
        XCTAssertNil(prematureCompletion, "arrival must not release the pending Pause command")

        let release = root.appendingPathComponent(
            ReconstructionInstalledPauseQualificationBarrier.releaseFilename
        )
        XCTAssertTrue(createEmptyFileExclusively(at: release))
        let barrierResult = await barrierTask.value
        XCTAssertTrue(barrierResult)
        let committedCompletion = await completion.value
        XCTAssertEqual(committedCompletion, true)
    }

    func testBarrierIsNoOpWithoutBothOptInsAndRejectsSymlinkRoot() async throws {
        let root = try makeOwnedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = UUID()
        let noOpResult = await ReconstructionInstalledPauseQualificationBarrier.waitIfRequested(
            reason: .pausedByUser,
            jobID: jobID,
            environment: [
                ReconstructionInstalledPauseQualificationBarrier.runEnvironmentKey: "1",
            ]
        )
        XCTAssertTrue(noOpResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            ReconstructionInstalledPauseQualificationBarrier.arrivalFilename
        ).path))

        let candidateMismatchResult = await
            ReconstructionInstalledPauseQualificationBarrier.waitIfRequested(
                reason: .pausedByUser,
                jobID: jobID,
                environment: [
                    ReconstructionInstalledPauseQualificationBarrier.runEnvironmentKey: "1",
                    ReconstructionInstalledPauseQualificationBarrier.rootEnvironmentKey: root.path,
                    ReconstructionInstalledPauseQualificationBarrier
                        .candidateSHA256EnvironmentKey: String(repeating: "0", count: 64),
                ],
                executableURL: URL(fileURLWithPath: CommandLine.arguments[0])
            )
        XCTAssertFalse(candidateMismatchResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            ReconstructionInstalledPauseQualificationBarrier.arrivalFilename
        ).path))

        let link = URL(
            fileURLWithPath: "/private/tmp/MacScope-Task10-PauseBarrier-Link-\(UUID().uuidString)"
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidateSHA256 = try sha256Hex(of: executableURL)
        let symlinkResult = await ReconstructionInstalledPauseQualificationBarrier.waitIfRequested(
            reason: .pausedByUser,
            jobID: jobID,
            environment: [
                ReconstructionInstalledPauseQualificationBarrier.runEnvironmentKey: "true",
                ReconstructionInstalledPauseQualificationBarrier.rootEnvironmentKey: link.path,
                ReconstructionInstalledPauseQualificationBarrier.candidateSHA256EnvironmentKey:
                    candidateSHA256,
            ],
            executableURL: executableURL
        )
        XCTAssertFalse(symlinkResult)
    }

    func testPendingControlIsInstalledBeforeBarrierAndPlannerCancellation() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "MacScope/Services/Reconstruction/ReconstructionJobCoordinator.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "    private func registerControl("))
        let suffix = source[start.lowerBound...]
        let end = try XCTUnwrap(suffix.range(of: "\n    private func run("))
        let body = String(suffix[..<end.lowerBound])
        let install = try XCTUnwrap(body.range(of: "pendingControls[jobID] = control"))
        let barrier = try XCTUnwrap(body.range(
            of: "ReconstructionInstalledPauseQualificationBarrier.waitIfRequested("
        ))
        let cancellation = try XCTUnwrap(body.range(of: "await planner.cancel(jobID: jobID)"))

        XCTAssertLessThan(install.lowerBound, barrier.lowerBound)
        XCTAssertLessThan(barrier.lowerBound, cancellation.lowerBound)
        XCTAssertTrue(body.contains("reason == .pausedByUser"))
        XCTAssertTrue(body.contains("rejectPendingControl(jobID: jobID, matching: completion)"))
    }

    private func makeOwnedRoot() throws -> URL {
        let root = URL(
            fileURLWithPath: "/private/tmp/MacScope-Task10-PauseBarrier-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func waitForRegularFile(_ url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey])).map(
                { $0.isRegularFile == true }
            ) == true {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(url.lastPathComponent)")
    }

    private func createEmptyFileExclusively(at url: URL) -> Bool {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { return false }
        return Darwin.close(descriptor) == 0
    }

    private func repositoryRoot() -> URL {
        var root = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    private func sha256Hex(of url: URL) throws -> String {
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

private actor PauseBarrierCompletion {
    private(set) var value: Bool?

    func record(_ result: Bool) {
        value = result
    }
}
#endif
