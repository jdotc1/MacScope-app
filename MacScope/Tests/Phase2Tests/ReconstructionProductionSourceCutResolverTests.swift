import Foundation
import XCTest
@testable import MacScope

@MainActor
final class ReconstructionProductionSourceCutResolverTests: XCTestCase {
    func testCompilerAndBehaviorVectorsMatchFixedRunnerArguments() throws {
        let request = request(root: TestWorkRoot.authorityPath("source-fixed"))
        XCTAssertEqual(ReconstructionProductionSourceCutOracleAssembler.compileArguments(request), [
            request.compilerPath, "-std=c11", "-O0", "-Wall", "-Wextra", "-Werror", "-target",
            "arm64-apple-macos27.0", "-isysroot", request.sdkRootPath,
            "-ffreestanding", "-fno-builtin", "-ferror-limit=8",
            request.stageRootPath + "/candidate.c", request.stageRootPath + "/harness.c",
            "-o", request.stageRootPath + "/output/candidate"])
        XCTAssertEqual(ReconstructionProductionSourceCutOracleAssembler.behaviorArguments(request),
                       [request.stageRootPath + "/output/candidate"])
    }

    func testArgumentIdentityIncludesActualStageAndSDKPaths() throws {
        let a = request(root: TestWorkRoot.authorityPath("source-first"))
        let b = request(root: TestWorkRoot.authorityPath("source-second"))
        let c = request(root: a.stageRootPath, sdk: "/Applications/Xcode.app/Contents/Developer/SDKs/Other.sdk")
        func compileHash(_ request: MacScope.Phase2SourceExecutionRequest) throws -> String {
            try ReconstructionCanonicalJSON.sha256(of: ReconstructionProductionSourceCutOracleAssembler.compileArguments(request))
        }
        XCTAssertNotEqual(try compileHash(a), try compileHash(b))
        XCTAssertNotEqual(try compileHash(a), try compileHash(c))
        XCTAssertNotEqual(try ReconstructionCanonicalJSON.sha256(of: ReconstructionProductionSourceCutOracleAssembler.behaviorArguments(a)),
                          try ReconstructionCanonicalJSON.sha256(of: ReconstructionProductionSourceCutOracleAssembler.behaviorArguments(b)))
    }

    func testStaleBatchCutFailsBeforeCreatingStage() async throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let parent = TestWorkRoot.authorityURL("source-never-created-" + UUID().uuidString.lowercased())
        let resolver = ReconstructionProductionSourceCutResolver(basis: fixture.basis, stageParent: parent)
        let authority = try ReconstructionBatchAuthority(jobID: fixture.basis.job.jobID, checkpointID: UUID(),
            checkpointRevision: fixture.basis.checkpoint.revision, corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256)
        do {
            _ = try await resolver.resolve(task: fixture.model, authority: authority, cancellation: .init())
            XCTFail("A stale committed cut cannot resolve executable source")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testCancellationBeforeResolutionDoesNotCreateStage() async throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let parent = TestWorkRoot.authorityURL("source-never-created-" + UUID().uuidString.lowercased())
        let resolver = ReconstructionProductionSourceCutResolver(basis: fixture.basis, stageParent: parent)
        let authority = try ReconstructionBatchAuthority(jobID: fixture.basis.job.jobID,
            checkpointID: fixture.basis.checkpoint.checkpointID, checkpointRevision: fixture.basis.checkpoint.revision,
            corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256)
        let cancellation = ReconstructionCancellation(); cancellation.cancel()
        do {
            _ = try await resolver.resolve(task: fixture.model, authority: authority, cancellation: cancellation)
            XCTFail("Cancelled admission cannot resolve executable source")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    private func request(root: String, sdk: String = "/Applications/Xcode.app/Contents/Developer/SDKs/MacOSX.sdk") -> MacScope.Phase2SourceExecutionRequest {
        let hash = ProductionSourceOwnerFixture.hash("controlled tool identity")
        return .init(requestID: UUID(), sessionID: UUID(), operation: .compile, sourceAuthority: .original,
            stageRootPath: root, revisionSHA256: nil, sourceSHA256: hash, harnessSHA256: hash,
            compilerPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            sdkRootPath: sdk, toolchainRootPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
            runnerSHA256: hash, compilerSHA256: hash, sdkSettingsSHA256: hash)
    }
}
