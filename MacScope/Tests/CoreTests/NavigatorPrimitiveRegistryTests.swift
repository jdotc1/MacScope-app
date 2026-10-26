import Foundation
import XCTest
@testable import MacScope

/// Primitive registry: vocabulary validation, lookup, applicability and the knowledge-version digest.
final class NavigatorPrimitiveRegistryTests: XCTestCase {
    private static func key(
        arch: String = "arm64",
        platforms: [NavigatorToolchainKey.Platform] = [NavigatorToolchainKey.Platform(name: "macOS", minOS: "14.0", sdk: "15.0")],
        swiftTool: String? = "6.3",
        swiftABI: String? = "5",
        linkerFlavor: String = "chained"
    ) -> NavigatorToolchainKey {
        var tools = [NavigatorToolchainKey.Tool(name: "ld", version: "1200.0")]
        if let swiftTool { tools.insert(NavigatorToolchainKey.Tool(name: "swift", version: swiftTool), at: 0) }
        return NavigatorToolchainKey(
            arch: arch,
            platforms: platforms,
            tools: tools,
            swiftABI: swiftABI,
            linkerFlavor: linkerFlavor,
            confidence: platforms.isEmpty ? .unknown : .exact,
            derivedFrom: String(repeating: "d", count: 64)
        )
    }

    private static func descriptor(
        id: String = "test.rule",
        version: String = "1",
        producesStatus: String = "derived",
        costClass: String = "cheap",
        inputs: [String] = [],
        outputs: [String] = ["hasName"],
        applicability: NavigatorApplicability = .any,
        onOutOfRange: String = "proceed"
    ) -> NavigatorPrimitiveDescriptor {
        NavigatorPrimitiveDescriptor(
            id: id,
            version: version,
            producesStatus: producesStatus,
            costClass: costClass,
            inputs: inputs,
            outputs: outputs,
            applicability: applicability,
            onOutOfRange: onOutOfRange
        )
    }

    func testStandardRegistryValidatesAgainstVocabulary() {
        XCTAssertEqual(NavigatorPrimitiveRegistry.standard.validateAgainstVocabulary(), [])
    }

    func testStandardRegistrySeedsAndLookup() throws {
        let registry = NavigatorPrimitiveRegistry.standard

        XCTAssertEqual(registry.primitives.map(\.id), [
            "macho.slice-identity",
            "macho.build-version",
            "macscope.swift-metadata-parser",
            "objc.class-parser",
            "proof.function-start-structural",
            "derive.function-start-call-target",
        ])
        XCTAssertEqual(registry.catalogues.map(\.id), [
            "signatures.call-catalog",
            "analysis.no-return-catalog",
            "signatures.swift-runtime-seeds",
        ])

        let parser = try XCTUnwrap(registry.lookup(id: SwiftMetadataFactProjection.rule))
        XCTAssertEqual(parser.version, SwiftMetadataFactProjection.ruleVersion)
        XCTAssertEqual(parser.producesStatus, "authoritative")
        XCTAssertTrue(parser.outputs.contains("conformsTo"))
        XCTAssertTrue(parser.outputs.contains("unresolvedProtocol"))

        let loaderOnly = NavigatorApplicability(archs: ["arm64", "arm64e"], platforms: ["macOS"],
                                                linkerFlavors: ["chained", "classic"])

        let proof = try XCTUnwrap(registry.lookup(id: "proof.function-start-structural"))
        XCTAssertTrue(proof.isImplemented)
        XCTAssertEqual(proof, NavigatorPrimitiveDescriptor.functionStartStructuralProof)
        XCTAssertEqual(proof.version, "1")
        XCTAssertEqual(proof.producesStatus, "proven")
        XCTAssertEqual(proof.costClass, "cheap")
        XCTAssertEqual(proof.inputs, [])
        XCTAssertEqual(proof.outputs, ["isFunctionStart", "boundaryUncertain"])
        XCTAssertEqual(proof.applicability, loaderOnly)
        XCTAssertEqual(proof.onOutOfRange, "abstain")

        let derive = try XCTUnwrap(registry.lookup(id: "derive.function-start-call-target"))
        XCTAssertTrue(derive.isImplemented)
        XCTAssertEqual(derive, NavigatorPrimitiveDescriptor.functionStartCallTargetDerivation)
        XCTAssertEqual(derive.version, "1")
        XCTAssertEqual(derive.producesStatus, "derived")
        XCTAssertEqual(derive.costClass, "bounded")
        XCTAssertEqual(derive.inputs, ["isFunctionStart"])
        XCTAssertEqual(derive.outputs, ["isFunctionStart", "boundaryUncertain"])
        XCTAssertEqual(derive.applicability, loaderOnly)
        XCTAssertEqual(derive.onOutOfRange, "abstain")

        XCTAssertEqual(registry.primitives.filter(\.isImplemented).map(\.id), [
            SwiftMetadataFactProjection.rule,
            "proof.function-start-structural",
            "derive.function-start-call-target",
        ])
        XCTAssertNil(registry.lookup(id: "signatures.call-catalog"))
        XCTAssertEqual(registry.catalogue(id: "signatures.swift-runtime-seeds"), RuntimeSignatureSeeds.knowledge)
        XCTAssertNil(registry.lookup(id: "missing.rule"))
    }

    func testCatalogueKnowledgeConstants() {
        XCTAssertEqual(CallSignatureCatalog.knowledge.id, "signatures.call-catalog")
        XCTAssertEqual(CallSignatureCatalog.knowledge.onOutOfRange, "proceed")
        XCTAssertEqual(NoReturnCatalog.knowledge.id, "analysis.no-return-catalog")
        XCTAssertEqual(NoReturnCatalog.knowledge.applicability, .any)
        XCTAssertEqual(RuntimeSignatureSeeds.knowledge.id, "signatures.swift-runtime-seeds")
        XCTAssertEqual(RuntimeSignatureSeeds.knowledge.onOutOfRange, "downgrade")
        XCTAssertEqual(
            RuntimeSignatureSeeds.knowledge.applicability.swiftTools,
            NavigatorVersionRange(minimum: "6.0", maximum: "6.3")
        )
        XCTAssertTrue(RuntimeSignatureSeeds.knowledge.version.contains("swift-6.3-RELEASE"))
    }

    func testValidationFailsOnDeliberatelyBadDescriptor() {
        let bad = Self.descriptor(
            id: "bad.rule",
            producesStatus: "unknown",
            costClass: "free",
            inputs: ["hasName"],
            outputs: ["notAPredicate"],
            applicability: NavigatorApplicability(archs: ["mips"], linkerFlavors: ["lazy"]),
            onOutOfRange: "skip"
        )
        let reasons = NavigatorPrimitiveRegistry(primitives: [bad], catalogues: []).validateAgainstVocabulary()

        XCTAssertEqual(reasons, [
            "primitive bad.rule: producesStatus unknown not a producible vocabulary status",
            "primitive bad.rule: costClass free not cheap|bounded|expensive",
            "primitive bad.rule: onOutOfRange skip not abstain|downgrade|proceed",
            "primitive bad.rule: output notAPredicate not a vocabulary predicate or gap",
            "primitive bad.rule: arch mips not a slice architecture variant",
            "primitive bad.rule: linker flavor lazy not chained|classic|none",
        ])
    }

    func testValidationFailsOnDuplicateIdsEmptyVersionsAndBadCatalogues() {
        let registry = NavigatorPrimitiveRegistry(
            primitives: [
                Self.descriptor(id: "dup.rule", inputs: ["notAGap"]),
                Self.descriptor(id: "dup.rule", version: ""),
            ],
            catalogues: [
                NavigatorKnowledgeDescriptor(
                    id: "bad.catalogue",
                    version: "1",
                    applicability: NavigatorApplicability(swiftABI: "4", swiftTools: NavigatorVersionRange(minimum: "6.x", maximum: "6.3")),
                    onOutOfRange: "ignore"
                ),
            ]
        )

        XCTAssertEqual(registry.validateAgainstVocabulary(), [
            "primitive dup.rule: input notAGap not a vocabulary predicate or gap",
            "primitive dup.rule: empty version",
            "primitive dup.rule: duplicate id",
            "catalogue bad.catalogue: onOutOfRange ignore not abstain|downgrade|proceed",
            "catalogue bad.catalogue: swiftABI 4 not 5",
            "catalogue bad.catalogue: swiftTools 6.x–6.3 is not a dotted version range",
        ])
    }

    func testApplicabilityFiltersByArchSwiftABIAndLinker() throws {
        let registry = NavigatorPrimitiveRegistry.standard

        XCTAssertEqual(registry.applicable(to: Self.key()).map(\.id), registry.primitives.map(\.id))

        let intelWithoutSwift = Self.key(arch: "x86_64", swiftTool: nil, swiftABI: nil, linkerFlavor: "classic")
        XCTAssertEqual(registry.applicable(to: intelWithoutSwift).map(\.id), [
            "macho.slice-identity",
            "macho.build-version",
            "objc.class-parser",
        ])

        let iOS = [NavigatorToolchainKey.Platform(name: "iOS", minOS: "17.0", sdk: "18.0")]
        for id in ["proof.function-start-structural", "derive.function-start-call-target"] {
            let primitive = try XCTUnwrap(registry.lookup(id: id))
            XCTAssertEqual(registry.disposition(of: primitive, for: intelWithoutSwift), "abstain", id)
            XCTAssertEqual(registry.disposition(of: primitive, for: Self.key()), "proceed", id)
            XCTAssertEqual(registry.disposition(of: primitive, for: Self.key(arch: "arm64e", linkerFlavor: "classic")), "proceed", id)
            XCTAssertEqual(registry.disposition(of: primitive, for: Self.key(platforms: iOS)), "abstain", id)
            XCTAssertEqual(registry.disposition(of: primitive, for: Self.key(linkerFlavor: "none")), "abstain", id)
            XCTAssertEqual(primitive.applicability.verdict(for: Self.key(platforms: [])), .undetermined, id)
            XCTAssertEqual(registry.disposition(of: primitive, for: Self.key(platforms: [])), "abstain", id)
        }

        let linkerBound = NavigatorApplicability(platforms: ["iOS"], linkerFlavors: ["classic"])
        XCTAssertEqual(linkerBound.verdict(for: Self.key()), .outOfRange)
        XCTAssertEqual(linkerBound.verdict(for: Self.key(linkerFlavor: "classic")), .outOfRange)
        XCTAssertEqual(
            linkerBound.verdict(for: Self.key(platforms: [NavigatorToolchainKey.Platform(name: "iOS", minOS: "17.0", sdk: "18.0")],
                                              linkerFlavor: "classic")),
            .inRange
        )
        XCTAssertEqual(linkerBound.verdict(for: Self.key(platforms: [], linkerFlavor: "classic")), .undetermined)
    }

    func testRuntimeSeedsDowngradeOutsideSwiftTools6_0Through6_3() {
        let registry = NavigatorPrimitiveRegistry.standard
        let seeds = RuntimeSignatureSeeds.knowledge

        XCTAssertEqual(seeds.applicability.verdict(for: Self.key(swiftTool: "6.3")), .inRange)
        XCTAssertEqual(seeds.applicability.verdict(for: Self.key(swiftTool: "6.0")), .inRange)
        XCTAssertEqual(seeds.applicability.verdict(for: Self.key(swiftTool: "6.3.1")), .inRange)
        XCTAssertEqual(seeds.applicability.verdict(for: Self.key(swiftTool: "6.4")), .outOfRange)
        XCTAssertEqual(seeds.applicability.verdict(for: Self.key(swiftTool: "5.10")), .outOfRange)
        XCTAssertEqual(seeds.applicability.verdict(for: Self.key(swiftTool: nil)), .undetermined)

        XCTAssertEqual(registry.disposition(of: seeds, for: Self.key(swiftTool: "6.2")), "proceed")
        XCTAssertEqual(registry.disposition(of: seeds, for: Self.key(swiftTool: "6.4")), "downgrade")
        XCTAssertEqual(registry.disposition(of: seeds, for: Self.key(swiftTool: nil)), "downgrade")
        XCTAssertEqual(registry.disposition(of: CallSignatureCatalog.knowledge, for: Self.key(swiftTool: "6.4")), "proceed")
    }

    func testVersionRangeComparesAtBoundPrecision() {
        let range = NavigatorVersionRange(minimum: "6.0", maximum: "6.3")

        XCTAssertEqual(range.contains("6"), true)
        XCTAssertEqual(range.contains("6.0.2"), true)
        XCTAssertEqual(range.contains("6.3.9"), true)
        XCTAssertEqual(range.contains("6.4"), false)
        XCTAssertEqual(range.contains("5.9.2"), false)
        XCTAssertNil(range.contains("6.x"))
        XCTAssertNil(range.contains(""))
        XCTAssertTrue(range.isWellFormed)
        XCTAssertFalse(NavigatorVersionRange(minimum: "6.3", maximum: "6.0").isWellFormed)
    }

    func testKnowledgeVersionFramesIDsAndVersionsSeparately() {
        func digest(_ id: String, _ version: String, catalogue: Bool) -> String {
            let registry = NavigatorPrimitiveRegistry(
                primitives: catalogue ? [] : [Self.descriptor(id: id, version: version)],
                catalogues: catalogue ? [NavigatorKnowledgeDescriptor(id: id, version: version, applicability: .any)] : []
            )
            return NavigatorKnowledgeVersion.digest(registry: registry, engineIdentity: "engine", decoderVersion: "decoder")
        }
        for catalogue in [false, true] {
            XCTAssertNotEqual(digest("a@b", "c", catalogue: catalogue), digest("a", "b@c", catalogue: catalogue))
        }
    }

    func testKnowledgeVersionDigestIsStableOrderIndependentAndSensitive() {
        let registry = NavigatorPrimitiveRegistry.standard
        let catalogues = registry.catalogues
        let baseline = NavigatorKnowledgeVersion.digest(
            registry: registry, catalogues: catalogues, engineIdentity: "engine-1", decoderVersion: "decoder-1")

        XCTAssertEqual(baseline.utf8.count, 64)
        XCTAssertTrue(AnalysisFacetFingerprint.isLowercaseSHA256(baseline))
        XCTAssertEqual(
            baseline,
            NavigatorKnowledgeVersion.digest(registry: registry, catalogues: catalogues, engineIdentity: "engine-1", decoderVersion: "decoder-1")
        )
        XCTAssertEqual(
            baseline,
            NavigatorKnowledgeVersion.digest(registry: registry, engineIdentity: "engine-1", decoderVersion: "decoder-1")
        )

        let reordered = NavigatorPrimitiveRegistry(primitives: registry.primitives.reversed(), catalogues: registry.catalogues)
        XCTAssertEqual(
            baseline,
            NavigatorKnowledgeVersion.digest(
                registry: reordered, catalogues: catalogues.reversed(), engineIdentity: "engine-1", decoderVersion: "decoder-1")
        )

        var bumpedCatalogues = catalogues
        bumpedCatalogues[0].version = "2"
        var bumpedPrimitives = registry.primitives
        bumpedPrimitives[0].version = "2"
        let bumpedRegistry = NavigatorPrimitiveRegistry(primitives: bumpedPrimitives, catalogues: registry.catalogues)
        let variants = [
            NavigatorKnowledgeVersion.digest(
                registry: registry, catalogues: bumpedCatalogues, engineIdentity: "engine-1", decoderVersion: "decoder-1"),
            NavigatorKnowledgeVersion.digest(
                registry: bumpedRegistry, catalogues: catalogues, engineIdentity: "engine-1", decoderVersion: "decoder-1"),
            NavigatorKnowledgeVersion.digest(
                registry: registry, catalogues: catalogues, engineIdentity: "engine-2", decoderVersion: "decoder-1"),
            NavigatorKnowledgeVersion.digest(
                registry: registry, catalogues: catalogues, engineIdentity: "engine-1", decoderVersion: "decoder-2"),
            NavigatorKnowledgeVersion.digest(
                registry: registry, catalogues: [], engineIdentity: "engine-1", decoderVersion: "decoder-1"),
        ]
        for variant in variants { XCTAssertNotEqual(variant, baseline) }
        XCTAssertEqual(Set(variants).count, variants.count)
        for index in catalogues.indices {
            var changed = catalogues
            changed[index].version += ";next"
            XCTAssertNotEqual(baseline, NavigatorKnowledgeVersion.digest(
                registry: registry, catalogues: changed, engineIdentity: "engine-1", decoderVersion: "decoder-1"))
        }
        for index in registry.primitives.indices {
            var changed = registry.primitives
            changed[index].version += ";next"
            XCTAssertNotEqual(baseline, NavigatorKnowledgeVersion.digest(
                registry: NavigatorPrimitiveRegistry(primitives: changed, catalogues: catalogues),
                engineIdentity: "engine-1", decoderVersion: "decoder-1"))
        }
    }
}
