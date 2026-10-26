import XCTest
@testable import MacScope

final class Phase2QualificationEnvironmentV2Tests: XCTestCase {
    func testEnvironmentIdentityIsStableAndChangesForEveryMaterialField() throws {
        let baseline = try makeEnvironment()
        let baselineID = try baseline.contentIdentity()

        XCTAssertEqual(baselineID.id, "phase2.r1.qualification-environment.v2")
        XCTAssertEqual(baselineID.version, 2)
        XCTAssertEqual(baselineID.sha256?.count, 64)
        XCTAssertEqual(baselineID, try makeEnvironment().contentIdentity())
        XCTAssertNotEqual(baselineID, try makeEnvironment(xcodeBuild: "18A999").contentIdentity())
        XCTAssertNotEqual(baselineID, try makeEnvironment(physicalMemoryBytes: 137_438_953_472).contentIdentity())
        XCTAssertNotEqual(baselineID, try makeEnvironment(workerExecutableDigest: digest("b")).contentIdentity())
    }

    func testEnvironmentRejectsUnboundedOrNoncanonicalIdentityInputs() throws {
        XCTAssertThrowsError(try makeEnvironment(hardwareModel: ""))
        XCTAssertThrowsError(try makeEnvironment(processorFamily: String(repeating: "a", count: 257)))
        XCTAssertThrowsError(try makeEnvironment(appExecutableDigest: "not-a-digest"))
        XCTAssertThrowsError(try makeEnvironment(physicalMemoryBytes: 0))
        XCTAssertThrowsError(try makeEnvironment(physicalCoreCount: 9, logicalCoreCount: 8))
        XCTAssertThrowsError(try makeEnvironment(performanceCoreCount: 9, efficiencyCoreCount: 2))
    }

    func testInjectedCollectorEnforcesExactM1Max64GiBPolicyAndRedactsSensitiveShapes() throws {
        let observation = rawEnvironment()
        let environment = try Phase2QualificationEnvironmentCollector().collect(
            observation: observation,
            hardwarePolicy: .thisM1Max64GiB
        )
        XCTAssertEqual(environment.hardwareModel, "MacBookPro18,2")
        XCTAssertEqual(environment.performanceCoreCount, 8)
        XCTAssertEqual(environment.efficiencyCoreCount, 2)

        var sensitive = observation
        sensitive.hardwareModel = "/Users/person/MacBookPro18,2"
        XCTAssertThrowsError(try Phase2QualificationEnvironmentCollector().collect(
            observation: sensitive, hardwarePolicy: .thisM1Max64GiB
        ))
    }

    func testRuntimeProvenanceIsContentAddressedWithoutEndpointOrPayloadFields() throws {
        let baseline = try makeProvenance()
        let baselineID = try baseline.contentIdentity()

        XCTAssertEqual(baselineID.id, "phase2.r1.qualification-runtime-provenance.v3")
        XCTAssertEqual(baselineID.version, 3)
        XCTAssertEqual(baselineID, try makeProvenance().contentIdentity())
        XCTAssertNotEqual(baselineID, try makeProvenance(providerRevision: 12).contentIdentity())
        XCTAssertNotEqual(baselineID, try makeProvenance(loadedInstanceIdentityDigest: digest("c")).contentIdentity())
        XCTAssertNotEqual(
            baselineID,
            try makeProvenance(modelSource: "publisher/different-model").contentIdentity()
        )
        XCTAssertNotEqual(
            baselineID,
            try makeProvenance(
                modelRevisionIdentity: try component(
                    id: "phase2.r1.qwen3-coder-30b-a3b-instruct-8bit.model-revision.v1",
                    byte: "d"
                )
            ).contentIdentity()
        )
        XCTAssertNotEqual(
            baselineID,
            try makeProvenance(
                productionDefinitionIdentity: try component(
                    id: "phase2.r1.standard-qualification-definition.v1",
                    byte: "e"
                )
            ).contentIdentity()
        )
    }

    func testRuntimeProvenanceRejectsInvalidFreshnessAndIdentity() throws {
        XCTAssertThrowsError(try makeProvenance(endpointGeneration: 0))
        XCTAssertThrowsError(try makeProvenance(providerRevision: 0))
        XCTAssertThrowsError(try makeProvenance(startedAt: 200, endedAt: 199))
        XCTAssertThrowsError(try makeProvenance(modelKeyIdentityDigest: "bad"))
    }

    func testEndpointBoundProviderRuntimeIdentityIsExactContentAddressedAndRejectsWrongComponent() throws {
        let baseline = try providerRuntime()
        XCTAssertEqual(
            try baseline.contentIdentity(),
            try providerRuntime().contentIdentity()
        )
        let changed = try Phase2EndpointBoundProviderRuntimeIdentity(
            endpoint: .init(
                id: "phase2.r1.provider-endpoint.v1", version: 1,
                sha256: digest("f")
            ),
            processStart: baseline.processStart,
            executableBuild: baseline.executableBuild,
            apiProbe: baseline.apiProbe
        )
        XCTAssertNotEqual(try baseline.contentIdentity(), try changed.contentIdentity())
        XCTAssertThrowsError(try Phase2EndpointBoundProviderRuntimeIdentity(
            endpoint: .init(
                id: "phase2.r1.wrong-endpoint.v1", version: 1, sha256: digest("e")
            ),
            processStart: baseline.processStart,
            executableBuild: baseline.executableBuild,
            apiProbe: baseline.apiProbe
        ))
    }

    private func makeEnvironment(
        xcodeBuild: String = "18A100",
        hardwareModel: String = "Mac16,1",
        processorFamily: String = "apple-silicon",
        physicalMemoryBytes: UInt64 = 68_719_476_736,
        physicalCoreCount: Int = 12,
        logicalCoreCount: Int = 12,
        performanceCoreCount: Int = 8,
        efficiencyCoreCount: Int = 4,
        appExecutableDigest: String? = nil,
        workerExecutableDigest: String? = nil
    ) throws -> Phase2QualificationEnvironmentV2 {
        try .init(
            bundleShortVersion: "2.0",
            bundleVersion: "204",
            macScopeCommit: String(repeating: "1", count: 40),
            appExecutableDigest: appExecutableDigest ?? digest("a"),
            workerExecutableDigest: workerExecutableDigest ?? digest("w"),
            signingRequirementDigest: digest("s"),
            xcodeVersion: "27.0",
            xcodeBuild: xcodeBuild,
            swiftCompilerVersion: "6.2.0",
            sdkVersion: "27.0",
            sdkBuild: "26A100",
            operatingSystemVersion: "27.0",
            operatingSystemBuild: "26A100",
            architecture: "arm64",
            hardwareModel: hardwareModel,
            processorFamily: processorFamily,
            physicalMemoryBytes: physicalMemoryBytes,
            physicalCoreCount: physicalCoreCount,
            logicalCoreCount: logicalCoreCount,
            performanceCoreCount: performanceCoreCount,
            efficiencyCoreCount: efficiencyCoreCount
        )
    }

    private func rawEnvironment() -> Phase2QualificationEnvironmentObservation {
        .init(
            bundleShortVersion: "2.0", bundleVersion: "204",
            macScopeCommit: String(repeating: "1", count: 40),
            appExecutableDigest: digest("a"), workerExecutableDigest: digest("w"),
            signingRequirementDigest: digest("s"), xcodeVersion: "27.0",
            xcodeBuild: "18A100", swiftCompilerVersion: "6.2.0", sdkVersion: "27.0",
            sdkBuild: "26A100", operatingSystemVersion: "27.0",
            operatingSystemBuild: "26A100", architecture: "arm64",
            hardwareModel: "MacBookPro18,2", processorFamily: "Apple M1 Max",
            physicalMemoryBytes: 68_719_476_736, physicalCoreCount: 10,
            logicalCoreCount: 10, performanceCoreCount: 8, efficiencyCoreCount: 2
        )
    }

    private func makeProvenance(
        endpointGeneration: UInt64 = 7,
        providerRevision: UInt64 = 11,
        modelKeyIdentityDigest: String? = nil,
        loadedInstanceIdentityDigest: String? = nil,
        modelSource: String = "provider-catalog",
        modelRevisionIdentity: Phase2ProtocolComponentIdentity? = nil,
        productionDefinitionIdentity: Phase2ProtocolComponentIdentity? = nil,
        startedAt: Int64 = 100,
        endedAt: Int64 = 200
    ) throws -> Phase2QualificationRuntimeProvenance {
        let production = Phase2ProductionQualificationPolicy.standard
        return try .init(
            endpointProfileID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            endpointGeneration: endpointGeneration,
            providerRevision: providerRevision,
            modelSource: modelSource,
            modelRevisionIdentity: modelRevisionIdentity ?? production.modelRevision.identity,
            productionDefinitionIdentity:
                productionDefinitionIdentity ?? production.definitionIdentity,
            modelKeyIdentityDigest: modelKeyIdentityDigest ?? digest("m"),
            loadedInstanceIdentityDigest: loadedInstanceIdentityDigest ?? digest("i"),
            loadedConfigurationIdentityDigest: digest("l"),
            providerBuildObservationDigest: digest("p"),
            providerRuntimeIdentity: try providerRuntime(),
            workerManifestDigest: digest("w"),
            measurementScopeIdentity: try .init(
                id: "phase2.r1.measurement-scope.app-worker-provider",
                version: 1,
                sha256: digest("r")
            ),
            startedAtEpochMilliseconds: startedAt,
            endedAtEpochMilliseconds: endedAt
        )
    }

    private func providerRuntime() throws -> Phase2EndpointBoundProviderRuntimeIdentity {
        func component(_ id: String, _ value: Character) throws -> Phase2ProtocolComponentIdentity {
            try .init(id: id, version: 1, sha256: digest(value))
        }
        return try .init(
            endpoint: component("phase2.r1.provider-endpoint.v1", "e"),
            processStart: component("phase2.r1.provider-process-start.v1", "p"),
            executableBuild: component("phase2.r1.provider-executable-build.v1", "x"),
            apiProbe: component("phase2.r1.provider-api-probe.v1", "a")
        )
    }

    private func component(
        id: String,
        byte: Character
    ) throws -> Phase2ProtocolComponentIdentity {
        try .init(id: id, version: 1, sha256: digest(byte))
    }

    private func digest(_ character: Character) -> String {
        let allowed = Array("0123456789abcdef")
        let scalar = character.unicodeScalars.first!.value
        return String(repeating: String(allowed[Int(scalar) % allowed.count]), count: 64)
    }
}
