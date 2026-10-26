import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionRelationDiscoveryTests: XCTestCase {
    private let discoverer = ReconstructionRelationDiscoverer()

    func testVerifiedContainerManifestMembershipCreatesContainsRelation() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let childID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: rootID,
                    rootID: rootID,
                    relativePath: ".",
                    kind: .applicationBundle,
                    role: .primaryTarget,
                    digestCharacter: "a"
                ),
                try occurrence(
                    id: childID,
                    rootID: rootID,
                    relativePath: "Contents/MacOS/Target",
                    kind: .machOImage,
                    role: .dependency,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [
                ReconstructionContainerMembershipEvidence(
                    containerOccurrenceID: rootID,
                    childOccurrenceID: childID,
                    isVerifiedManifestEntry: true
                ),
            ],
            symbolicLinks: [],
            loadedBinaries: []
        )

        let relations = try discoverer.discover(input)

        let relation = try XCTUnwrap(relations.only)
        XCTAssertEqual(relation.kind, .contains)
        XCTAssertEqual(relation.sourceOccurrenceID, rootID)
        XCTAssertEqual(relation.targetOccurrenceID, childID)
        XCTAssertNil(relation.unresolvedLocator)
        XCTAssertEqual(relation.evidenceSource, .containerManifest)
    }

    func testUnverifiedOrUnknownContainerMembersDoNotCreateEdges() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let childID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let unknownID = occurrenceID("90000000-0000-0000-0000-000000000009")
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: rootID,
                    rootID: rootID,
                    relativePath: ".",
                    kind: .directory,
                    role: .primaryTarget,
                    digestCharacter: "a"
                ),
                try occurrence(
                    id: childID,
                    rootID: rootID,
                    relativePath: "Known.bin",
                    kind: .opaque,
                    role: .auxiliary,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [
                ReconstructionContainerMembershipEvidence(
                    containerOccurrenceID: rootID,
                    childOccurrenceID: childID,
                    isVerifiedManifestEntry: false
                ),
                ReconstructionContainerMembershipEvidence(
                    containerOccurrenceID: rootID,
                    childOccurrenceID: unknownID,
                    isVerifiedManifestEntry: true
                ),
            ],
            symbolicLinks: [],
            loadedBinaries: []
        )

        XCTAssertEqual(try discoverer.discover(input), [])
    }

    func testInternalSymbolicLinkResolvesRelativeToItsManifestPath() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let linkID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let targetID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: rootID,
                    rootID: rootID,
                    relativePath: ".",
                    kind: .applicationBundle,
                    role: .primaryTarget,
                    digestCharacter: "a"
                ),
                try occurrence(
                    id: linkID,
                    rootID: rootID,
                    relativePath: "Links/helper",
                    kind: .symbolicLink,
                    role: .auxiliary,
                    digestCharacter: "b"
                ),
                try occurrence(
                    id: targetID,
                    rootID: rootID,
                    relativePath: "Frameworks/libHelper.dylib",
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "c"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [
                ReconstructionSymbolicLinkEvidence(
                    sourceOccurrenceID: linkID,
                    selectedRootOccurrenceID: rootID,
                    sourceRelativePath: "Links/helper",
                    targetText: "../Frameworks/./libHelper.dylib",
                    isVerifiedManifestEntry: true
                ),
            ],
            loadedBinaries: []
        )

        let relation = try XCTUnwrap(try discoverer.discover(input).only)

        XCTAssertEqual(relation.kind, .symbolicLinkTarget)
        XCTAssertEqual(relation.sourceOccurrenceID, linkID)
        XCTAssertEqual(relation.targetOccurrenceID, targetID)
        XCTAssertNil(relation.unresolvedLocator)
        XCTAssertEqual(relation.evidenceSource, .containerManifest)
    }

    func testUnmatchedInternalSymbolicLinkRetainsNormalizedUnresolvedLocator() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let linkID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: rootID,
                    rootID: rootID,
                    relativePath: ".",
                    kind: .directory,
                    role: .primaryTarget,
                    digestCharacter: "a"
                ),
                try occurrence(
                    id: linkID,
                    rootID: rootID,
                    relativePath: "Links/missing",
                    kind: .symbolicLink,
                    role: .auxiliary,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [
                ReconstructionSymbolicLinkEvidence(
                    sourceOccurrenceID: linkID,
                    selectedRootOccurrenceID: rootID,
                    sourceRelativePath: "Links/missing",
                    targetText: "../Frameworks/./libMissing.dylib",
                    isVerifiedManifestEntry: true
                ),
            ],
            loadedBinaries: []
        )

        let relation = try XCTUnwrap(try discoverer.discover(input).only)

        XCTAssertEqual(relation.kind, .unresolvedDependency)
        XCTAssertEqual(relation.sourceOccurrenceID, linkID)
        XCTAssertNil(relation.targetOccurrenceID)
        XCTAssertEqual(relation.unresolvedLocator, "Frameworks/libMissing.dylib")
        XCTAssertEqual(relation.evidenceSource, .containerManifest)
    }

    func testEscapingAbsoluteOrMalformedSymbolicLinkTargetsCreateNoRelation() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let linkID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: rootID,
                    rootID: rootID,
                    relativePath: ".",
                    kind: .directory,
                    role: .primaryTarget,
                    digestCharacter: "a"
                ),
                try occurrence(
                    id: linkID,
                    rootID: rootID,
                    relativePath: "Links/private",
                    kind: .symbolicLink,
                    role: .auxiliary,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [
                ReconstructionSymbolicLinkEvidence(
                    sourceOccurrenceID: linkID,
                    selectedRootOccurrenceID: rootID,
                    sourceRelativePath: "Links/private",
                    targetText: "../../Outside/libPrivate.dylib",
                    isVerifiedManifestEntry: true
                ),
                ReconstructionSymbolicLinkEvidence(
                    sourceOccurrenceID: linkID,
                    selectedRootOccurrenceID: rootID,
                    sourceRelativePath: "Links/private",
                    targetText: "/usr/lib/libSystem.B.dylib",
                    isVerifiedManifestEntry: true
                ),
                ReconstructionSymbolicLinkEvidence(
                    sourceOccurrenceID: linkID,
                    selectedRootOccurrenceID: rootID,
                    sourceRelativePath: "Links/private",
                    targetText: "bad\u{0000}target",
                    isVerifiedManifestEntry: true
                ),
            ],
            loadedBinaries: []
        )

        XCTAssertEqual(try discoverer.discover(input), [])
    }

    func testMachODependencyCommandsCreateExactAndUnresolvedRelations() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let dependencyID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let selectedLocator = "/Applications/Target.app/Contents/Frameworks/libBeta.dylib"
        let sourceBinary = loadedBinary(dependencies: [
            "//Applications/Target.app/Contents/Frameworks/./libBeta.dylib",
            "/usr/lib/libAbsent.dylib",
        ])
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "Contents/MacOS/Target",
                    kind: .machOImage,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
                try occurrence(
                    id: dependencyID,
                    rootID: dependencyID,
                    relativePath: ".",
                    verifiedLocators: [selectedLocator],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )

        let relations = try discoverer.discover(input)

        XCTAssertEqual(relations.count, 2)
        let resolved = try XCTUnwrap(relations.first(where: { $0.kind == .dependsOn }))
        XCTAssertEqual(resolved.sourceOccurrenceID, sourceID)
        XCTAssertEqual(resolved.targetOccurrenceID, dependencyID)
        XCTAssertNil(resolved.unresolvedLocator)
        XCTAssertEqual(resolved.evidenceSource, .dependencyCommand)

        let unresolved = try XCTUnwrap(
            relations.first(where: { $0.kind == .unresolvedDependency })
        )
        XCTAssertEqual(unresolved.sourceOccurrenceID, sourceID)
        XCTAssertNil(unresolved.targetOccurrenceID)
        XCTAssertEqual(unresolved.unresolvedLocator, "/usr/lib/libAbsent.dylib")
        XCTAssertEqual(unresolved.evidenceSource, .dependencyCommand)
    }

    func testEquivalentDependencyCommandsResolveOnceWithoutChangingCanonicalRelation() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let dependencyID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let locator = "/Selected/libDependency.dylib"
        let duplicatedSourceBinary = loadedBinary(dependencies: [
            locator,
            "//Selected/./libDependency.dylib",
            "/Selected/Nested/../libDependency.dylib",
        ])
        let singleSourceBinary = loadedBinary(dependencies: [locator])
        let occurrences = [
            try occurrence(
                id: sourceID,
                rootID: rootID,
                relativePath: "Target",
                kind: .machOImage,
                role: .primaryTarget,
                loadedBinary: duplicatedSourceBinary
            ),
            try occurrence(
                id: dependencyID,
                rootID: dependencyID,
                relativePath: ".",
                verifiedLocators: [
                    locator,
                    "//Selected/./libDependency.dylib",
                ],
                kind: .dynamicLibrary,
                role: .dependency,
                digestCharacter: "b"
            ),
        ]
        let duplicatedInput = ReconstructionRelationDiscoveryInput(
            occurrences: occurrences,
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: duplicatedSourceBinary
                ),
            ]
        )
        let singleInput = ReconstructionRelationDiscoveryInput(
            occurrences: occurrences,
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: singleSourceBinary
                ),
            ]
        )
        let probe = ReconstructionRelationLookupProbe()
        let instrumentedDiscoverer = ReconstructionRelationDiscoverer(
            testHooks: .init(
                didPerformDependencyLocatorLookup: { probe.observe($0) }
            )
        )

        let duplicatedRelations = try instrumentedDiscoverer.discover(duplicatedInput)
        let singleRelations = try discoverer.discover(singleInput)

        XCTAssertEqual(duplicatedRelations, singleRelations)
        XCTAssertEqual(duplicatedRelations.count, 1)
        XCTAssertEqual(probe.locators, [locator])
    }

    func testDependencyLocatorCardinalityExcludesSourceBeforeSelectingUniqueTarget() throws {
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let dependencyID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let locator = "/Selected/libDependency.dylib"
        let sourceBinary = loadedBinary(dependencies: [locator])
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: sourceID,
                    relativePath: ".",
                    verifiedLocators: [locator],
                    kind: .dynamicLibrary,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
                try occurrence(
                    id: dependencyID,
                    rootID: dependencyID,
                    relativePath: ".",
                    verifiedLocators: [locator],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )

        let relation = try XCTUnwrap(try discoverer.discover(input).only)

        XCTAssertEqual(relation.kind, .dependsOn)
        XCTAssertEqual(relation.targetOccurrenceID, dependencyID)
        XCTAssertNil(relation.unresolvedLocator)
    }

    func testCancellationAfterDependencyLocatorLookupThrowsBeforeMaterialization() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let dependencyID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let locator = "/Selected/libDependency.dylib"
        let sourceBinary = loadedBinary(dependencies: [locator])
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "Target",
                    kind: .machOImage,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
                try occurrence(
                    id: dependencyID,
                    rootID: dependencyID,
                    relativePath: ".",
                    verifiedLocators: [locator],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )
        let cancellation = ReconstructionCancellation()
        let probe = ReconstructionRelationLookupProbe(cancellation: cancellation)
        let instrumentedDiscoverer = ReconstructionRelationDiscoverer(
            testHooks: .init(
                didPerformDependencyLocatorLookup: { probe.observe($0) }
            )
        )

        XCTAssertThrowsError(
            try instrumentedDiscoverer.discover(input, cancellation: cancellation)
        ) { error in
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(probe.locators, [locator])
    }

    func testMismatchedLoadedBinaryAbstainsFromDependencyRelations() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let dependencyID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let dependencyLocator = "/Selected/libForeign.dylib"
        let indexedSourceBinary = loadedBinary(
            bytes: Data([0x11]),
            dependencies: []
        )
        let foreignBinary = loadedBinary(
            bytes: Data([0x22]),
            dependencies: [dependencyLocator, "/usr/lib/libAbsent.dylib"]
        )
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "Target",
                    kind: .machOImage,
                    role: .primaryTarget,
                    loadedBinary: indexedSourceBinary
                ),
                try occurrence(
                    id: dependencyID,
                    rootID: dependencyID,
                    relativePath: ".",
                    verifiedLocators: [dependencyLocator],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: foreignBinary
                ),
            ]
        )

        XCTAssertEqual(try discoverer.discover(input), [])
    }

    func testDependencyMatchingUsesExactOccurrenceRatherThanSharedContentOrName() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let firstCopyID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let secondCopyID = occurrenceID("40000000-0000-0000-0000-000000000004")
        let sourceBinary = loadedBinary(
            dependencies: ["/Selected/B/libShared.dylib"]
        )
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "Target",
                    kind: .machOImage,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
                try occurrence(
                    id: firstCopyID,
                    rootID: firstCopyID,
                    relativePath: ".",
                    verifiedLocators: ["/Selected/A/libShared.dylib"],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "b"
                ),
                try occurrence(
                    id: secondCopyID,
                    rootID: secondCopyID,
                    relativePath: ".",
                    verifiedLocators: ["/Selected/B/libShared.dylib"],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )

        let relation = try XCTUnwrap(try discoverer.discover(input).only)

        XCTAssertEqual(relation.kind, .dependsOn)
        XCTAssertEqual(relation.targetOccurrenceID, secondCopyID)
        XCTAssertNotEqual(relation.targetOccurrenceID, firstCopyID)
    }

    func testAmbiguousDependencyLocatorDoesNotFabricateTargetOccurrence() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let firstCandidateID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let secondCandidateID = occurrenceID("40000000-0000-0000-0000-000000000004")
        let ambiguousLocator = "/Selected/libShared.dylib"
        let sourceBinary = loadedBinary(dependencies: [ambiguousLocator])
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "Target",
                    kind: .machOImage,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
                try occurrence(
                    id: firstCandidateID,
                    rootID: firstCandidateID,
                    relativePath: ".",
                    verifiedLocators: [ambiguousLocator],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "b"
                ),
                try occurrence(
                    id: secondCandidateID,
                    rootID: secondCandidateID,
                    relativePath: ".",
                    verifiedLocators: [ambiguousLocator],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "c"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )

        let relations = try discoverer.discover(input)

        XCTAssertFalse(relations.contains(where: { $0.kind == .dependsOn }))
        let unresolved = try XCTUnwrap(relations.only)
        XCTAssertEqual(unresolved.kind, .unresolvedDependency)
        XCTAssertNil(unresolved.targetOccurrenceID)
        XCTAssertEqual(unresolved.unresolvedLocator, ambiguousLocator)
    }

    func testOpaqueDylibMasqueradeCannotBecomeDependencyTarget() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let masqueradeID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let locator = "/Selected/libFoo.dylib"
        let sourceBinary = loadedBinary(dependencies: [locator])
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "Target",
                    kind: .machOImage,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
                try occurrence(
                    id: masqueradeID,
                    rootID: masqueradeID,
                    relativePath: "libFoo.dylib",
                    verifiedLocators: [locator],
                    kind: .opaque,
                    role: .dependency,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )

        let relation = try XCTUnwrap(try discoverer.discover(input).only)

        XCTAssertEqual(relation.kind, .unresolvedDependency)
        XCTAssertNil(relation.targetOccurrenceID)
        XCTAssertEqual(relation.unresolvedLocator, locator)
    }

    func testOpaqueLocatorCollisionDoesNotMakeRealDylibTargetAmbiguous() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let realDylibID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let masqueradeID = occurrenceID("40000000-0000-0000-0000-000000000004")
        let locator = "/Selected/libFoo.dylib"
        let sourceBinary = loadedBinary(dependencies: [locator])
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "Target",
                    kind: .machOImage,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
                try occurrence(
                    id: realDylibID,
                    rootID: realDylibID,
                    relativePath: "libFoo.dylib",
                    verifiedLocators: [locator],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "b"
                ),
                try occurrence(
                    id: masqueradeID,
                    rootID: masqueradeID,
                    relativePath: "libFoo.dylib",
                    verifiedLocators: [locator],
                    kind: .opaque,
                    role: .dependency,
                    digestCharacter: "c"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )

        let relation = try XCTUnwrap(try discoverer.discover(input).only)

        XCTAssertEqual(relation.kind, .dependsOn)
        XCTAssertEqual(relation.targetOccurrenceID, realDylibID)
        XCTAssertNil(relation.unresolvedLocator)
    }

    func testCancellationDuringDependencyPassThrowsWithoutPublishingRelations() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let sourceBinary = loadedBinary(dependencies: [
            "/Selected/libFirst.dylib",
            "/Selected/libSecond.dylib",
            "/Selected/libThird.dylib",
        ])
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "Target",
                    kind: .machOImage,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )
        let cancellation = ReconstructionCancellation()
        let probe = ReconstructionRelationCancellationProbe(cancellation: cancellation)
        let discoverer = ReconstructionRelationDiscoverer(
            testHooks: .init(didPollCancellation: { probe.observe($0) })
        )

        XCTAssertThrowsError(
            try discoverer.discover(input, cancellation: cancellation)
        ) { error in
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(probe.dependencyPollCount, 2)
    }

    func testPreCancelledTaskPropagatesCancellationError() async throws {
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: []
        )
        let discovery = Task { () throws -> [ReconstructionArtifactRelationRecord] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReconstructionRelationDiscoverer().discover(
                input,
                cancellation: ReconstructionCancellation()
            )
        }

        do {
            _ = try await discovery.value
            XCTFail("Pre-cancelled relation discovery completed without observing cancellation")
        } catch is CancellationError {
            // Expected: the entry cancellation gate preserves typed task cancellation.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testMalformedDependencyLocatorsAreIgnoredRatherThanPublished() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let sourceBinary = loadedBinary(
            dependencies: ["", ".", "bad\u{0000}locator"]
        )
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "Target",
                    kind: .machOImage,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )

        XCTAssertEqual(try discoverer.discover(input), [])
    }

    func testNonMachOImportNamesDoNotCreateFileLevelDependencyEdges() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let sourceID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let temptingTargetID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let sourceBinary = loadedBinary(
            dependencies: [],
            imports: [
                ImportSummary(
                    id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
                    name: "provider_symbol",
                    libraryName: "libprovider.so",
                    libraryOrdinal: nil
                ),
            ],
            includesMachOMetadata: false
        )
        let input = ReconstructionRelationDiscoveryInput(
            occurrences: [
                try occurrence(
                    id: sourceID,
                    rootID: rootID,
                    relativePath: "libconsumer.so",
                    kind: .dynamicLibrary,
                    role: .primaryTarget,
                    loadedBinary: sourceBinary
                ),
                try occurrence(
                    id: temptingTargetID,
                    rootID: temptingTargetID,
                    relativePath: ".",
                    verifiedLocators: ["libprovider.so"],
                    kind: .dynamicLibrary,
                    role: .dependency,
                    digestCharacter: "b"
                ),
            ],
            containerMemberships: [],
            symbolicLinks: [],
            loadedBinaries: [
                ReconstructionLoadedBinaryRelationEvidence(
                    sourceOccurrenceID: sourceID,
                    loadedBinary: sourceBinary
                ),
            ]
        )

        XCTAssertEqual(try discoverer.discover(input), [])
    }

    func testDuplicateEvidenceCollapsesAndShuffledInputProducesIdenticalOrderedRelations() throws {
        let rootID = occurrenceID("10000000-0000-0000-0000-000000000001")
        let childID = occurrenceID("20000000-0000-0000-0000-000000000002")
        let sourceID = occurrenceID("30000000-0000-0000-0000-000000000003")
        let dependencyID = occurrenceID("40000000-0000-0000-0000-000000000004")
        let dependencyLocator = "/Selected/libDependency.dylib"
        let sourceBinary = loadedBinary(
            dependencies: [dependencyLocator, dependencyLocator]
        )
        let occurrences = [
            try occurrence(
                id: rootID,
                rootID: rootID,
                relativePath: ".",
                kind: .directory,
                role: .primaryTarget,
                digestCharacter: "a"
            ),
            try occurrence(
                id: childID,
                rootID: rootID,
                relativePath: "Child.bin",
                kind: .opaque,
                role: .auxiliary,
                digestCharacter: "b"
            ),
            try occurrence(
                id: sourceID,
                rootID: sourceID,
                relativePath: ".",
                kind: .machOImage,
                role: .primaryTarget,
                loadedBinary: sourceBinary
            ),
            try occurrence(
                id: dependencyID,
                rootID: dependencyID,
                relativePath: ".",
                verifiedLocators: [dependencyLocator],
                kind: .dynamicLibrary,
                role: .dependency,
                digestCharacter: "d"
            ),
        ]
        let membership = ReconstructionContainerMembershipEvidence(
            containerOccurrenceID: rootID,
            childOccurrenceID: childID,
            isVerifiedManifestEntry: true
        )
        let loaded = ReconstructionLoadedBinaryRelationEvidence(
            sourceOccurrenceID: sourceID,
            loadedBinary: sourceBinary
        )
        let forward = ReconstructionRelationDiscoveryInput(
            occurrences: occurrences,
            containerMemberships: [membership, membership],
            symbolicLinks: [],
            loadedBinaries: [loaded, loaded]
        )
        let reversed = ReconstructionRelationDiscoveryInput(
            occurrences: Array(occurrences.reversed()),
            containerMemberships: Array([membership, membership].reversed()),
            symbolicLinks: [],
            loadedBinaries: Array([loaded, loaded].reversed())
        )

        let forwardRelations = try discoverer.discover(forward)
        let reversedRelations = try discoverer.discover(reversed)

        XCTAssertEqual(forwardRelations, reversedRelations)
        XCTAssertEqual(forwardRelations.count, 2)
        XCTAssertEqual(Set(forwardRelations.map(\.relationID)).count, 2)
        XCTAssertEqual(
            forwardRelations.map {
                let target = $0.targetOccurrenceID?.rawValue.uuidString ?? $0.unresolvedLocator ?? "nil"
                return "\($0.sourceOccurrenceID.rawValue.uuidString)|\($0.kind.rawValue)|\(target)"
            },
            [
                "10000000-0000-0000-0000-000000000001|contains|20000000-0000-0000-0000-000000000002",
                "30000000-0000-0000-0000-000000000003|dependsOn|40000000-0000-0000-0000-000000000004",
            ]
        )
    }

    func testCanonicalRelationDigestIsLiteralStableAndExcludesOnlyDigestField() throws {
        let relationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let sourceID = occurrenceID("22222222-2222-2222-2222-222222222222")
        let targetID = occurrenceID("33333333-3333-3333-3333-333333333333")
        let zeroDigest = String(repeating: "0", count: 64)
        let otherDigest = String(repeating: "f", count: 64)
        let first = try ReconstructionArtifactRelationRecord(
            relationID: relationID,
            kind: .contains,
            sourceOccurrenceID: sourceID,
            targetOccurrenceID: targetID,
            unresolvedLocator: nil,
            evidenceSource: .containerManifest,
            canonicalSHA256: zeroDigest
        )
        let sameRelationWithDifferentStoredDigest = try ReconstructionArtifactRelationRecord(
            relationID: relationID,
            kind: .contains,
            sourceOccurrenceID: sourceID,
            targetOccurrenceID: targetID,
            unresolvedLocator: nil,
            evidenceSource: .containerManifest,
            canonicalSHA256: otherDigest
        )
        let changedEvidenceSource = try ReconstructionArtifactRelationRecord(
            relationID: relationID,
            kind: .contains,
            sourceOccurrenceID: sourceID,
            targetOccurrenceID: targetID,
            unresolvedLocator: nil,
            evidenceSource: .loader,
            canonicalSHA256: zeroDigest
        )

        let firstDigest = try discoverer.canonicalDigest(for: first)
        let secondDigest = try discoverer.canonicalDigest(
            for: sameRelationWithDifferentStoredDigest
        )

        // SHA-256 of the exact sorted-key canonical JSON below, with no trailing newline:
        // {"evidenceSource":"containerManifest","kind":"contains","relationID":"11111111-1111-1111-1111-111111111111","sourceOccurrenceID":{"rawValue":"22222222-2222-2222-2222-222222222222"},"targetOccurrenceID":{"rawValue":"33333333-3333-3333-3333-333333333333"}}
        XCTAssertEqual(
            firstDigest,
            "f9ae9642ac791a7216e089f090d27333db601b4718536c4a794cc85f7274acda"
        )
        XCTAssertEqual(secondDigest, firstDigest)
        XCTAssertNotEqual(try discoverer.canonicalDigest(for: changedEvidenceSource), firstDigest)
    }

    private func occurrence(
        id: ReconstructionArtifactOccurrenceID,
        rootID: ReconstructionArtifactOccurrenceID,
        relativePath: String,
        verifiedLocators: [String] = [],
        kind: ReconstructionArtifactKind,
        role: ReconstructionArtifactRole,
        digestCharacter: Character
    ) throws -> ReconstructionRelationDiscoveryOccurrence {
        try occurrence(
            id: id,
            rootID: rootID,
            relativePath: relativePath,
            verifiedLocators: verifiedLocators,
            kind: kind,
            role: role,
            contentIdentity: ReconstructionContentIdentity(
                algorithm: .sha256,
                digest: String(repeating: digestCharacter, count: 64),
                byteCount: 1
            )
        )
    }

    private func occurrence(
        id: ReconstructionArtifactOccurrenceID,
        rootID: ReconstructionArtifactOccurrenceID,
        relativePath: String,
        verifiedLocators: [String] = [],
        kind: ReconstructionArtifactKind,
        role: ReconstructionArtifactRole,
        loadedBinary: LoadedBinary
    ) throws -> ReconstructionRelationDiscoveryOccurrence {
        try occurrence(
            id: id,
            rootID: rootID,
            relativePath: relativePath,
            verifiedLocators: verifiedLocators,
            kind: kind,
            role: role,
            contentIdentity: contentIdentity(for: loadedBinary)
        )
    }

    private func occurrence(
        id: ReconstructionArtifactOccurrenceID,
        rootID: ReconstructionArtifactOccurrenceID,
        relativePath: String,
        verifiedLocators: [String],
        kind: ReconstructionArtifactKind,
        role: ReconstructionArtifactRole,
        contentIdentity: ReconstructionContentIdentity
    ) throws -> ReconstructionRelationDiscoveryOccurrence {
        let record = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: id,
            contentIdentity: contentIdentity,
            kind: kind,
            roles: [role],
            executableMode: false,
            originalName: relativePath == "."
                ? "selected-root"
                : URL(fileURLWithPath: relativePath).lastPathComponent,
            diagnostic: nil
        )
        return ReconstructionRelationDiscoveryOccurrence(
            artifact: record,
            selectedRootOccurrenceID: rootID,
            relativePath: relativePath,
            verifiedLocators: verifiedLocators
        )
    }

    private func occurrenceID(_ rawValue: String) -> ReconstructionArtifactOccurrenceID {
        ReconstructionArtifactOccurrenceID(rawValue: UUID(uuidString: rawValue)!)
    }

    private func loadedBinary(
        bytes: Data = Data([0]),
        dependencies: [String],
        imports: [ImportSummary] = [],
        includesMachOMetadata: Bool = true
    ) -> LoadedBinary {
        let metadata = MachOLoadMetadata(
            codeSignature: nil,
            importedSymbols: [],
            dependentDylibs: dependencies.enumerated().map { index, path in
                MachOLoadMetadata.DependentDylib(
                    path: path,
                    kind: "required",
                    currentVersion: "1.0.0",
                    compatibilityVersion: "1.0.0",
                    ordinal: index + 1
                )
            }
        )
        return LoadedBinary(
            name: "fixture",
            path: "/immutable/corpus/fixture",
            isBundle: false,
            cpuType: 0x0100_000C,
            fileTypeName: includesMachOMetadata ? "Mach-O executable" : "ELF shared object",
            architectureDisplayName: "arm64",
            metadata: .empty,
            bytes: bytes,
            sliceOffset: 0,
            sections: [],
            executableTextSection: nil,
            entryPointAddress: nil,
            symbols: [],
            imports: imports,
            indirectSymbols: [],
            exports: [],
            stringLiterals: [],
            functionStarts: [],
            objcSelectors: [:],
            machOMetadata: includesMachOMetadata ? metadata : nil
        )
    }

    private func contentIdentity(
        for loadedBinary: LoadedBinary
    ) throws -> ReconstructionContentIdentity {
        try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: SHA256.hash(data: loadedBinary.bytes).map {
                String(format: "%02x", $0)
            }.joined(),
            byteCount: UInt64(loadedBinary.bytes.count)
        )
    }
}

private final class ReconstructionRelationCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: ReconstructionCancellation
    private var dependencyPollCountStorage = 0

    init(cancellation: ReconstructionCancellation) {
        self.cancellation = cancellation
    }

    func observe(_ checkpoint: ReconstructionRelationDiscoveryCheckpoint) {
        guard checkpoint == .dependentDylib else { return }
        lock.lock()
        dependencyPollCountStorage += 1
        let shouldCancel = dependencyPollCountStorage == 2
        lock.unlock()
        if shouldCancel { cancellation.cancel() }
    }

    var dependencyPollCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dependencyPollCountStorage
    }
}

private final class ReconstructionRelationLookupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: ReconstructionCancellation?
    private var locatorsStorage: [String] = []

    init(cancellation: ReconstructionCancellation? = nil) {
        self.cancellation = cancellation
    }

    func observe(_ locator: String) {
        lock.lock()
        locatorsStorage.append(locator)
        let shouldCancel = cancellation != nil && locatorsStorage.count == 1
        lock.unlock()
        if shouldCancel { cancellation?.cancel() }
    }

    var locators: [String] {
        lock.lock()
        defer { lock.unlock() }
        return locatorsStorage
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
