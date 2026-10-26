import Darwin
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceExecutionLeaseTests: XCTestCase {
    func testFreshObservationRetriesIncompleteCutsWithoutReusingTheirMembers() {
        var attempts = 0, now: UInt64 = 0
        let recovered = ReconstructionSourceExecutionGroupObservation.freshCompleteCut(
            nowNanoseconds: { now }, wait: { now += UInt64($0) * 1_000 }) {
            attempts += 1
            return attempts < 4 ? nil : .init(processIDs: [123, 124], residentBytes: 4_096)
        }
        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(recovered?.processIDs, [123, 124])
        XCTAssertEqual(recovered?.residentBytes, 4_096)
    }

    func testPersistentObservationLossCannotAuthorizeContinuation() {
        var attempts = 0, now: UInt64 = 0
        let unavailable = ReconstructionSourceExecutionGroupObservation.freshCompleteCut(
            nowNanoseconds: { now }, wait: { now += UInt64($0) * 1_000 }) {
            attempts += 1
            return nil
        }
        XCTAssertGreaterThan(attempts, 1)
        XCTAssertEqual(now, ReconstructionSourceExecutionPolicy.maximumObservationRetryNanoseconds)
        XCTAssertNil(unavailable)
    }

    func testSourceHandshakeRemainsRawAfterOwnedSlaveOpenAndDoesNotEchoInput() throws {
        let lease = try Phase2ShellBrokerProcessAdapter().launch(.init(sessionID: UUID(), requestID: UUID(),
            executablePath: "/bin/sh", arguments: ["-c", "IFS= read -r line; printf 'observed:%s' \"$line\""],
            initialSize: .defaultInteractive), sourceExecutionHandshake: true)
        defer { XCTAssertTrue(lease.cleanup(timeout: 1).observedProcessAbsent) }
        let descriptor = open(lease.pty.slavePath, O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var settings = termios()
        XCTAssertEqual(tcgetattr(descriptor, &settings), 0)
        XCTAssertEqual(settings.c_lflag & tcflag_t(ECHO | ICANON | ISIG | IEXTEN), 0)
        XCTAssertEqual(settings.c_oflag & tcflag_t(OPOST), 0)
        XCTAssertEqual(try lease.writeInput(ReconstructionSourceExecutionPolicy.acknowledgment),
            ReconstructionSourceExecutionPolicy.acknowledgment.count)
        var bytes = [UInt8]()
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while lease.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
            bytes += lease.readAvailablePTYOutput(timeout: 0.01)
        }
        bytes += lease.readAvailablePTYOutput(timeout: 0)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "observed:MACSCOPE_SOURCE_EXECUTION_ACK_V1")
        XCTAssertEqual(lease.terminalOutcomeAfterObservedExit(), .exited(status: 0))
    }

    private func runner() throws -> String {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_SOURCE_EXECUTION_LEASE_TESTS"] == "1",
              let path = ProcessInfo.processInfo.environment["MACSCOPE_SOURCE_EXECUTION_RUNNER"]
                ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SourceExecutionRunner").path,
              URL(fileURLWithPath: path).lastPathComponent == "SourceExecutionRunner",
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Opt in with the compiled confined SourceExecutionRunner path")
        }
        return path
    }

    private func fixture(candidate: String) throws -> URL {
        let root = TestWorkRoot.authorityURL("source-execution-lease-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(candidate.utf8).write(to: root.appendingPathComponent("candidate.c"))
        try Data("int recovered(void); int main(void){return recovered();}".utf8)
            .write(to: root.appendingPathComponent("harness.c"))
        return root
    }

    private func plan(_ root: URL, runner: String, compile: Bool) -> Phase2HumanPTYLaunchPlan {
        let toolchain = "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
        let sdk = URL(fileURLWithPath: "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk").resolvingSymlinksInPath().path
        return .init(sessionID: UUID(), requestID: UUID(), executablePath: runner,
            arguments: compile ? ["compile", root.path, toolchain + "/usr/bin/clang", sdk, toolchain]
                : ["behavior", root.path], workingDirectoryPath: root.path,
            initialSize: .defaultInteractive)
    }

    private func build(_ root: URL, runner: String) throws {
        let result = try Phase2ShellBrokerProcessAdapter().executeSource(plan(root, runner: runner, compile: true))
        XCTAssertNil(result.failure, String(decoding: result.diagnostics, as: UTF8.self))
        XCTAssertNil(result.diagnostics.range(of: Data(ReconstructionSourceExecutionPolicy.acknowledgment)),
            "The broker acknowledgment must not echo into diagnostics")
        XCTAssertEqual(result.terminalOutcome, .exited(status: 0))
        XCTAssertTrue(result.cleanupProof.observedProcessAbsent)
        XCTAssertFalse(result.sampledProcessIDs.isEmpty)
    }

    func testAcknowledgedConfinedLauncherHasRealExitAndCleanup() throws {
        let runner = try runner(), root = try fixture(candidate: "int recovered(void){return 7;}")
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, runner: runner)
        let result = try Phase2ShellBrokerProcessAdapter().executeSource(plan(root, runner: runner, compile: false))
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.terminalOutcome, .exited(status: 7))
        XCTAssertTrue(result.cleanupProof.observedProcessAbsent)
    }

    func testFullInspectionAdmitsArithmeticAndRejectsHarnessSpoofBeforeCompile() throws {
        let runner = try runner()
        for (source, admitted) in [
            ("#include <stdint.h>\nuint32_t reconstructed(uint32_t x){return x == UINT32_MAX ? x : x+1;}", true),
            ("#include <stdint.h>\nuint32_t reconstructed(uint32_t x){return x;} int printf(const char *f,...){(void)f;return 0;}", false),
            ("#include <stdint.h>\nstatic void start(void) __attribute__((constructor)); static void start(void){} uint32_t reconstructed(uint32_t x){return x;}", false)
        ] {
            let root = try fixture(candidate: source)
            defer { try? FileManager.default.removeItem(at: root) }
            let compile = plan(root, runner: runner, compile: true)
            var arguments = compile.arguments; arguments[0] = "inspect"
            let inspection = Phase2HumanPTYLaunchPlan(sessionID: compile.sessionID, requestID: compile.requestID,
                executablePath: compile.executablePath, arguments: arguments,
                workingDirectoryPath: root.path, initialSize: compile.initialSize)
            let result = try Phase2ShellBrokerProcessAdapter().executeSource(inspection)
            XCTAssertNil(result.failure, String(decoding: result.diagnostics, as: UTF8.self))
        XCTAssertNil(result.diagnostics.range(of: Data(ReconstructionSourceExecutionPolicy.acknowledgment)),
            "The broker acknowledgment must not echo into diagnostics")
            XCTAssertEqual(result.terminalOutcome, .exited(status: 0))
            XCTAssertTrue(result.cleanupProof.observedProcessAbsent)
            let ast = try Data(contentsOf: root.appendingPathComponent("inspection/candidate.ast.json"))
            let sourceHash = ReconstructionSourceRevisionAdmission.sourceSHA256(Data(source.utf8))
            if admitted {
                let accepted = try ReconstructionSourceASTAdmission.validate(json: ast,
                    expectedSourceSHA256: sourceHash, profileID: ReconstructionSourceASTAdmission.profileID)
                XCTAssertEqual(accepted.sourceSHA256, sourceHash)
                XCTAssertEqual(accepted.astSHA256, ReconstructionSourceRevisionAdmission.sourceSHA256(ast))
            } else {
                XCTAssertThrowsError(try ReconstructionSourceASTAdmission.validate(json: ast,
                    expectedSourceSHA256: sourceHash, profileID: ReconstructionSourceASTAdmission.profileID))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("output/candidate").path))
        }
    }

    func testCPUlightResidentAllocationIsTerminatedWithCleanup() throws {
        let runner = try runner(), root = try fixture(candidate: """
        #include <stdlib.h>
        #include <unistd.h>
        int recovered(void){volatile char *p=malloc(384UL*1024*1024); if(!p)return 2;
          for(unsigned long i=0;i<384UL*1024*1024;i+=4096)p[i]=1;
          for(;;)sleep(1);}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, runner: runner)
        let result = try Phase2ShellBrokerProcessAdapter().executeSource(plan(root, runner: runner, compile: false))
        XCTAssertEqual(result.failure, .residentMemoryLimit)
        XCTAssertGreaterThan(result.peakGroupResidentBytes, ReconstructionSourceExecutionPolicy.behaviorMaximumResidentBytes)
        XCTAssertTrue(result.cleanupProof.observedProcessAbsent)
    }

    func testDiagnosticOverflowTerminatesAndRetainsOnlyBoundedBytes() throws {
        let runner = try runner(), root = try fixture(candidate: """
        #include <unistd.h>
        int recovered(void){char b[1024]={0};for(;;)write(1,b,sizeof b);}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, runner: runner)
        let result = try Phase2ShellBrokerProcessAdapter().executeSource(plan(root, runner: runner, compile: false))
        XCTAssertEqual(result.failure, .diagnosticsLimit)
        XCTAssertEqual(result.diagnostics.count, 16_384)
        XCTAssertTrue(result.cleanupProof.observedProcessAbsent)
    }

    func testWallDeadlineAndCancellationCleanOwnedGroup() throws {
        let runner = try runner(), root = try fixture(candidate: """
        #include <unistd.h>
        int recovered(void){for(;;)sleep(1);}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        try build(root, runner: runner)
        let adapter = Phase2ShellBrokerProcessAdapter()
        let expired = try adapter.executeSource(plan(root, runner: runner, compile: false))
        XCTAssertEqual(expired.failure, .deadline)
        XCTAssertTrue(expired.cleanupProof.observedProcessAbsent)
        XCTAssertLessThan(expired.elapsedSeconds, 13)
        let start = DispatchTime.now().uptimeNanoseconds
        let cancelled = try adapter.executeSource(plan(root, runner: runner, compile: false), cancelled: {
            DispatchTime.now().uptimeNanoseconds - start > 200_000_000
        })
        XCTAssertEqual(cancelled.failure, .cancelled)
        XCTAssertTrue(cancelled.cleanupProof.observedProcessAbsent)
    }

    func testGroupSamplingIncludesDescendantsAndUnavailableFailsClosed() throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_SOURCE_EXECUTION_LEASE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in owned local process sampling")
        }
        let lease = try Phase2ShellBrokerProcessAdapter().launch(.init(sessionID: UUID(), requestID: UUID(),
            executablePath: "/bin/sh", arguments: ["-c", "sleep 5 & wait"],
            initialSize: .defaultInteractive))
        defer { XCTAssertTrue(lease.cleanup(timeout: 1).observedProcessAbsent) }
        var observed: ReconstructionSourceExecutionGroupObservation?
        for _ in 0..<20 {
            observed = ReconstructionSourceExecutionGroupObservation.capture(groupID: lease.ownedProcess.processIdentifier)
            if (observed?.processIDs.count ?? 0) >= 2 { break }
            usleep(20_000)
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(observed).processIDs.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(observed).residentBytes, 0)
        XCTAssertNil(ReconstructionSourceExecutionGroupObservation.capture(groupID: -1))
    }
}
