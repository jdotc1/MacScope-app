import Foundation
import XCTest
@testable import MacScope

final class DyldCacheDifferentialWorkflowCoordinatorTests: XCTestCase {
    func testNativeFactBuilderSelectsAndVerifiesFromAuthoritativeCacheSource() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache(cpuSubtype: 2)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-native-dyld-facts-\(UUID().uuidString)")
        try fixture.bytes.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        let loaded = try DyldSharedCacheBinaryLoader().load(at: source)
        let artifact = try XCTUnwrap(loaded.artifactIdentity)

        let facts = try DyldCacheNativeCatalogFactBuilder().build(
            sourceURL: source,
            artifactIdentity: artifact
        )

        XCTAssertEqual(facts.sourceURL, source.standardizedFileURL)
        XCTAssertEqual(facts.artifactIdentity, artifact)
        XCTAssertEqual(facts.imageIdentity.path, "/usr/lib/libFixture.dylib")
        XCTAssertEqual(facts.imageIdentity.loadAddress, fixture.imageVMAddress)
        XCTAssertEqual(facts.images, [facts.imageIdentity])
        XCTAssertEqual(facts.mappings.count, 1)
        XCTAssertEqual(facts.mappings[0].sourceFileIndex, 0)
        XCTAssertEqual(facts.mappings[0].maximumProtection, 5)
        XCTAssertEqual(facts.mappings[0].initialProtection, 5)
    }

    func testProductionFactoryCompositionIsCallableAndBindsExactRequestIdentity() async throws {
        let source = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let image = DyldCacheAnalysisTestFixtures.image()
        let sourceIdentity = try DyldCacheSourceIdentityReader.identity(for: source)
        let subject = DyldCacheAnalysisSubjectIdentity(
            artifactIdentity: artifactIdentity,
            imageIdentity: image,
            analysisGeneration: 1
        )
        let codec = DyldCacheAnalysisWireCodec()
        let transport = MockDyldCacheAnalysisTransport(outcomes: [.reply(
            codec.encodeReply(.success(DyldCacheAnalysisTestFixtures.result(
                sourceIdentity: sourceIdentity,
                subject: subject,
                images: [DyldCacheAnalysisTestFixtures.imageRecord(
                    image.path,
                    image.loadAddress
                )]
            )))
        )])
        let workflow = AnalysisProviderFactory.makeDyldCacheDifferentialWorkflow(
            transport: transport,
            codec: codec,
            makeRequestID: { DyldCacheAnalysisTestFixtures.requestID }
        )

        let report = await workflow.inspect(native: nativeFacts(
            source: source,
            selectedImage: image,
            images: [image]
        ))

        XCTAssertEqual(report.state, .agreement)
        XCTAssertEqual(report.binding?.subject.analysisGeneration, 1)
        XCTAssertEqual(report.binding?.subject.artifactIdentity, artifactIdentity)
        XCTAssertEqual(report.binding?.subject.imageIdentity, image)
        XCTAssertEqual(
            report.binding?.sourceIdentity,
            sourceIdentity
        )
        XCTAssertEqual(report.differential?.state, .agreement)
        XCTAssertNil(report.failure)
        XCTAssertEqual(transport.calls.map(\.requestID), [DyldCacheAnalysisTestFixtures.requestID])
    }

    func testPublishesClosedAgreementSupplementalNativeAndDisagreementStates() async throws {
        let source = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let shared = DyldCacheAnalysisTestFixtures.image("/shared", 1)
        let nativeOnly = DyldCacheAnalysisTestFixtures.image("/native", 2)
        let supplementalOnly = DyldCacheAnalysisTestFixtures.image("/supplemental", 3)

        let cases: [(
            native: [DyldCacheImageIdentity],
            supplemental: [DyldCacheImageIdentity],
            expected: DyldCacheDifferentialWorkflowState
        )] = [
            ([shared], [shared], .agreement),
            ([shared], [shared, supplementalOnly], .supplementalOnly),
            ([shared, nativeOnly], [shared], .nativeOnly),
            ([shared, nativeOnly], [shared, supplementalOnly], .disagreement),
        ]

        for testCase in cases {
            let provider = matchingProvider(images: testCase.supplemental)
            let workflow = DyldCacheDifferentialWorkflowCoordinator(provider: provider)
            let report = await workflow.inspect(native: nativeFacts(
                source: source,
                selectedImage: shared,
                images: testCase.native
            ))

            XCTAssertEqual(report.state, testCase.expected)
            XCTAssertNotNil(report.differential)
            XCTAssertNil(report.failure)
        }
    }

    func testPartialProviderOutputPublishesPartialNotAgreement() async throws {
        let source = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let image = DyldCacheAnalysisTestFixtures.image()
        let provider = DyldCacheWorkflowStubProvider { sourceIdentity, subject in
            DyldCacheAnalysisTestFixtures.result(
                sourceIdentity: sourceIdentity,
                subject: subject,
                images: [DyldCacheAnalysisTestFixtures.imageRecord(
                    image.path,
                    image.loadAddress
                )],
                catalogCoverage: .partial,
                completion: .partial
            )
        }

        let report = await DyldCacheDifferentialWorkflowCoordinator(provider: provider).inspect(
            native: nativeFacts(source: source, selectedImage: image, images: [image])
        )

        XCTAssertEqual(report.state, .partial)
        XCTAssertEqual(report.differential?.state, .uncomparable)
        XCTAssertNil(report.failure)
    }

    func testProviderFailurePublishesTypedErrorWithoutRawDifferential() async throws {
        let source = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let provider = DyldCacheWorkflowStubProvider { _, _ in
            throw DyldCacheAnalysisProviderError.providerUnavailable
        }

        let report = await DyldCacheDifferentialWorkflowCoordinator(provider: provider).inspect(
            native: nativeFacts(source: source)
        )

        XCTAssertEqual(report.state, .error)
        XCTAssertEqual(report.failure, .providerUnavailable)
        XCTAssertNotNil(report.binding)
        XCTAssertNil(report.differential)
    }

    func testStaleProviderResultIsRejectedBeforeDifferentialPublication() async throws {
        let source = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let provider = DyldCacheWorkflowStubProvider { sourceIdentity, subject in
            let staleSubject = DyldCacheAnalysisSubjectIdentity(
                artifactIdentity: subject.artifactIdentity,
                imageIdentity: subject.imageIdentity,
                analysisGeneration: subject.analysisGeneration + 1
            )
            return DyldCacheAnalysisTestFixtures.result(
                sourceIdentity: sourceIdentity,
                subject: staleSubject
            )
        }

        let report = await DyldCacheDifferentialWorkflowCoordinator(provider: provider).inspect(
            native: nativeFacts(source: source)
        )

        XCTAssertEqual(report.state, .error)
        XCTAssertEqual(report.failure, .staleGeneration)
        XCTAssertNil(report.differential)
    }

    private var artifactIdentity: MachOSliceArtifactIdentity {
        DyldCacheAnalysisTestFixtures.artifactIdentity()
    }

    private func nativeFacts(
        source: URL,
        selectedImage: DyldCacheImageIdentity = DyldCacheAnalysisTestFixtures.image(),
        images: [DyldCacheImageIdentity] = [],
        mappings: [DyldCacheComparableMapping] = []
    ) -> DyldCacheNativeCatalogFacts {
        DyldCacheNativeCatalogFacts(
            sourceURL: source,
            artifactIdentity: artifactIdentity,
            imageIdentity: selectedImage,
            images: images,
            mappings: mappings
        )
    }

    private func matchingProvider(
        images: [DyldCacheImageIdentity]
    ) -> DyldCacheWorkflowStubProvider {
        DyldCacheWorkflowStubProvider { sourceIdentity, subject in
            DyldCacheAnalysisTestFixtures.result(
                sourceIdentity: sourceIdentity,
                subject: subject,
                images: images.map {
                    DyldCacheAnalysisTestFixtures.imageRecord($0.path, $0.loadAddress)
                }
            )
        }
    }

    private func makeSourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-dyld-workflow-\(UUID().uuidString)")
        try Data([0x64, 0x79, 0x6c, 0x64]).write(to: url, options: .atomic)
        return url
    }
}

private struct DyldCacheWorkflowStubProvider: DyldCacheAnalysisProviding {
    typealias ResultBuilder = @Sendable (
        DyldCacheFileIdentity,
        DyldCacheAnalysisSubjectIdentity
    ) throws -> DyldCacheAnalysisResult

    let resultBuilder: ResultBuilder

    init(resultBuilder: @escaping ResultBuilder) {
        self.resultBuilder = resultBuilder
    }

    func inspectCache(
        at url: URL,
        expectedSourceIdentity: DyldCacheFileIdentity,
        subject: DyldCacheAnalysisSubjectIdentity,
        categories: [DyldCacheAnalysisCategory],
        limits: DyldCacheAnalysisLimits,
        cancellation: AnalysisCancellationToken
    ) async throws -> DyldCacheAnalysisResult {
        _ = url
        _ = categories
        _ = limits
        try cancellation.check()
        return try resultBuilder(expectedSourceIdentity, subject)
    }
}
