import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionContainerManifestTests: XCTestCase {
    func testCanonicalManifestAndContainerIdentityIgnoreRootLocationAndCreationOrder() async throws {
        let first = try ContainerFixture(named: "first")
        let second = try ContainerFixture(named: "second")
        defer {
            first.remove()
            second.remove()
        }

        try first.writeFile("z-last.txt", bytes: Data("last".utf8))
        try first.writeFile("Sources/main.c", bytes: Data("int main(void) { return 0; }\n".utf8))
        try first.writeFile(
            "Widget.app/Contents/MacOS/Widget",
            bytes: verifiedMachOHeader(fileType: 0x2)
        )
        try first.writeFile(
            "Widget.app/Contents/Info.plist",
            bytes: Data("<?xml version=\"1.0\"?><plist><dict/></plist>\n".utf8)
        )
        try first.writeFile("Libraries/fixture.zip", bytes: verifiedZIPLocalHeader())

        try second.writeFile("Libraries/fixture.zip", bytes: verifiedZIPLocalHeader())
        try second.writeFile(
            "Widget.app/Contents/Info.plist",
            bytes: Data("<?xml version=\"1.0\"?><plist><dict/></plist>\n".utf8)
        )
        try second.writeFile(
            "Widget.app/Contents/MacOS/Widget",
            bytes: verifiedMachOHeader(fileType: 0x2)
        )
        try second.writeFile("Sources/main.c", bytes: Data("int main(void) { return 0; }\n".utf8))
        try second.writeFile("z-last.txt", bytes: Data("last".utf8))

        let firstResult = try await build(first.root)
        let secondResult = try await build(second.root)

        XCTAssertEqual(firstResult.canonicalManifestBytes, secondResult.canonicalManifestBytes)
        XCTAssertEqual(firstResult.contentIdentity, secondResult.contentIdentity)
        XCTAssertEqual(firstResult.contentIdentity.digest, sha256(firstResult.canonicalManifestBytes))
        XCTAssertEqual(
            firstResult.contentIdentity.byteCount,
            UInt64(firstResult.canonicalManifestBytes.count)
        )
        let manifest = try JSONDecoder().decode(
            CapturedContainerManifest.self,
            from: firstResult.canonicalManifestBytes
        )
        XCTAssertEqual(
            manifest.entries.map(\.relativePath),
            ["Libraries", "Sources", "Widget.app", "z-last.txt"]
        )
        XCTAssertEqual(
            manifest.entries.map(\.kind),
            [.directory, .directory, .directory, .resource]
        )
    }

    func testBuilderClassifiesVerifiedRegularFileBytesThroughTheSharedClassifier() async throws {
        let fixture = try ContainerFixture(named: "shared-classifier")
        defer { fixture.remove() }
        let cases: [(name: String, bytes: Data)] = [
            ("Library.dylib", verifiedMachOHeader(fileType: 0x6)),
            ("Archive.zip", verifiedZIPLocalHeader()),
            ("Source.swift", Data("let answer = 42\n".utf8)),
        ]
        let classifier = ReconstructionArtifactClassifier()

        for testCase in cases {
            try fixture.writeFile(testCase.name, bytes: testCase.bytes)
        }

        let result = try await build(fixture.root)
        let manifestText = try XCTUnwrap(String(data: result.canonicalManifestBytes, encoding: .utf8))
        for testCase in cases {
            let expected = classifier.classifyVerifiedRegularFile(
                originalName: testCase.name,
                verifiedPrefix: testCase.bytes,
                verifiedByteCount: UInt64(testCase.bytes.count),
                completeSample: true
            )
            XCTAssertTrue(
                manifestText.contains("\"kind\":\"\(expected.kind.rawValue)\""),
                "Builder must retain the shared classifier's kind for \(testCase.name)."
            )
        }
    }

    func testClassifierRejectsJavaClassTruncatedFatAndForgedThinMachOHints() {
        let javaClass = Data([
            0xca, 0xfe, 0xba, 0xbe,
            0x00, 0x00, 0x00, 0x3d,
            0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
        let truncatedFat = Data([
            0xca, 0xfe, 0xba, 0xbe,
            0x00, 0x00, 0x00, 0x01,
            0x01, 0x00, 0x00, 0x0c,
            0x00, 0x00, 0x00, 0x00,
        ])
        let truncatedThin = Data([
            0xcf, 0xfa, 0xed, 0xfe,
            0x0c, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
        ])
        let forgedThin = Data([
            0xcf, 0xfa, 0xed, 0xfe,
            0x0c, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x08, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        for (name, bytes) in [
            ("Fixture.class", javaClass),
            ("Truncated.fat", truncatedFat),
            ("Truncated.thin", truncatedThin),
            ("Forged.thin", forgedThin),
        ] {
            XCTAssertEqual(
                ReconstructionArtifactClassifier().classifyVerifiedRegularFile(
                    originalName: name,
                    verifiedPrefix: bytes,
                    verifiedByteCount: UInt64(bytes.count),
                    completeSample: true
                ).kind,
                .opaque,
                name
            )
        }
    }

    func testCapturedManifestBuildsCanonicalImmediateFactsWithoutReadingTheLiveTree() throws {
        let fileIdentity = try fixedContentIdentity(byte: "1", byteCount: 17)
        let directoryIdentity = try fixedContentIdentity(byte: "2", byteCount: 31)
        let builder = ReconstructionContainerManifestBuilder()

        let result = try builder.buildCapturedManifest(
            entries: [
                .init(
                    relativePath: "z-link",
                    kind: .symbolicLink,
                    contentIdentity: nil,
                    executableMode: false,
                    symbolicLinkTarget: "../target"
                ),
                .init(
                    relativePath: "Nested",
                    kind: .directory,
                    contentIdentity: directoryIdentity,
                    executableMode: true,
                    symbolicLinkTarget: nil
                ),
                .init(
                    relativePath: "a-file",
                    kind: .opaque,
                    contentIdentity: fileIdentity,
                    executableMode: false,
                    symbolicLinkTarget: nil
                ),
            ],
            limits: .init(
                maximumDepth: 16,
                maximumEntries: 64,
                maximumRelativePathUTF8Bytes: 1_024,
                maximumEncodedBytes: 64 * 1_024
            ),
            cancellation: ReconstructionCancellation()
        )

        let manifest = try JSONDecoder().decode(
            CapturedContainerManifest.self,
            from: result.canonicalManifestBytes
        )
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.entries.map(\.relativePath), ["Nested", "a-file", "z-link"])
        XCTAssertEqual(manifest.entries[0].contentIdentity, directoryIdentity)
        XCTAssertEqual(manifest.entries[0].executableMode, true)
        XCTAssertEqual(manifest.entries[1].contentIdentity, fileIdentity)
        XCTAssertEqual(manifest.entries[2].kind, .symbolicLink)
        XCTAssertEqual(manifest.entries[2].symbolicLinkTarget, "../target")
        XCTAssertEqual(result.contentIdentity.digest, sha256(result.canonicalManifestBytes))
        XCTAssertEqual(result.contentIdentity.byteCount, UInt64(result.canonicalManifestBytes.count))
        XCTAssertEqual(
            try Data(contentsOf: result.attachmentSource.verifiedURL),
            result.canonicalManifestBytes
        )
        XCTAssertEqual(result.attachmentSource.contentIdentity, result.contentIdentity)
    }

    func testLiveTreeRootManifestContainsOnlyImmediateChildrenAndMatchesCapturedBuild() async throws {
        let fixture = try ContainerFixture(named: "immediate-root")
        defer { fixture.remove() }
        let topBytes = Data("top-level\n".utf8)
        let leafBytes = Data("nested leaf\n".utf8)
        try fixture.writeFile("top.txt", bytes: topBytes)
        try fixture.writeFile("Nested/leaf.txt", bytes: leafBytes)

        let nested = try await build(fixture.root.appendingPathComponent("Nested"))
        let topIdentity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: sha256(topBytes),
            byteCount: UInt64(topBytes.count)
        )
        let captured = try ReconstructionContainerManifestBuilder().buildCapturedManifest(
            entries: [
                .init(
                    relativePath: "Nested",
                    kind: .directory,
                    contentIdentity: nested.contentIdentity,
                    executableMode: true,
                    symbolicLinkTarget: nil
                ),
                .init(
                    relativePath: "top.txt",
                    kind: .resource,
                    contentIdentity: topIdentity,
                    executableMode: false,
                    symbolicLinkTarget: nil
                ),
            ],
            limits: .init(
                maximumDepth: 16,
                maximumEntries: 64,
                maximumRelativePathUTF8Bytes: 1_024,
                maximumEncodedBytes: 64 * 1_024
            ),
            cancellation: ReconstructionCancellation()
        )
        let live = try await build(fixture.root)
        let manifest = try JSONDecoder().decode(
            CapturedContainerManifest.self,
            from: live.canonicalManifestBytes
        )

        XCTAssertEqual(manifest.entries.map(\.relativePath), ["Nested", "top.txt"])
        XCTAssertEqual(live.canonicalManifestBytes, captured.canonicalManifestBytes)
        XCTAssertEqual(live.contentIdentity, captured.contentIdentity)
    }

    func testCapturedManifestRejectsAmbiguousUnsafeAndOverBudgetFacts() throws {
        let identity = try fixedContentIdentity(byte: "3", byteCount: 8)
        let builder = ReconstructionContainerManifestBuilder()
        let limits = ReconstructionContainerManifestBuilder.Limits(
            maximumDepth: 16,
            maximumEntries: 4,
            maximumRelativePathUTF8Bytes: 16,
            maximumEncodedBytes: 4 * 1_024,
            maximumFileBytes: 32,
            maximumTotalContentBytes: 32
        )
        let cases: [[ReconstructionContainerManifestBuilder.CapturedEntry]] = [
            [
                .init(
                    relativePath: "nested/path",
                    kind: .opaque,
                    contentIdentity: identity,
                    executableMode: false,
                    symbolicLinkTarget: nil
                ),
            ],
            [
                .init(
                    relativePath: "e\u{301}",
                    kind: .opaque,
                    contentIdentity: identity,
                    executableMode: false,
                    symbolicLinkTarget: nil
                ),
                .init(
                    relativePath: "é",
                    kind: .opaque,
                    contentIdentity: identity,
                    executableMode: false,
                    symbolicLinkTarget: nil
                ),
            ],
            [
                .init(
                    relativePath: "ambiguous",
                    kind: .symbolicLink,
                    contentIdentity: identity,
                    executableMode: false,
                    symbolicLinkTarget: "target"
                ),
            ],
            [
                .init(
                    relativePath: "missing-target",
                    kind: .symbolicLink,
                    contentIdentity: nil,
                    executableMode: false,
                    symbolicLinkTarget: nil
                ),
            ],
        ]

        for entries in cases {
            XCTAssertThrowsError(try builder.buildCapturedManifest(
                entries: entries,
                limits: limits,
                cancellation: ReconstructionCancellation()
            ))
        }

        let cancelled = ReconstructionCancellation()
        cancelled.cancel()
        XCTAssertThrowsError(try builder.buildCapturedManifest(
            entries: [
                .init(
                    relativePath: "file",
                    kind: .opaque,
                    contentIdentity: identity,
                    executableMode: false,
                    symbolicLinkTarget: nil
                ),
            ],
            limits: limits,
            cancellation: cancelled
        ))
    }

    func testContainerClassificationRequiresVerifiedBundleStructure() async throws {
        let classifier = ReconstructionArtifactClassifier()
        XCTAssertEqual(
            classifier.classifyContainer(
                originalName: "Fake.app",
                childRelativePaths: ["payload.txt"]
            ),
            .directory
        )
        XCTAssertEqual(
            classifier.classifyContainer(
                originalName: "Incomplete.app",
                childRelativePaths: ["Contents/Info.plist", "Contents/MacOS"]
            ),
            .directory
        )
        XCTAssertEqual(
            classifier.classifyContainer(
                originalName: "Verified.app",
                childRelativePaths: ["Contents/Info.plist", "Contents/MacOS/Verified"]
            ),
            .directory,
            "Unverified path strings must never authorize an application bundle."
        )
        XCTAssertEqual(
            classifier.classifyContainer(
                originalName: "Fake.framework",
                childRelativePaths: ["Versions/A"]
            ),
            .directory
        )
        XCTAssertEqual(
            classifier.classifyContainer(
                originalName: "Verified.framework",
                childRelativePaths: ["Versions/A/Verified", "Versions/A/Headers/Header.h"]
            ),
            .directory,
            "Unverified path strings must never authorize a framework bundle."
        )
        XCTAssertEqual(
            classifier.classifyContainer(
                originalName: "Unsafe.app",
                childRelativePaths: ["Contents/Info.plist", "Contents/MacOS/../Unsafe"]
            ),
            .directory
        )

        let fixture = try ContainerFixture(named: "suffix-is-not-structure")
        defer { fixture.remove() }
        try fixture.writeFile("Fake.app/payload.txt", bytes: Data("not a bundle\n".utf8))
        try fixture.writeFile(
            "Fake.framework/Versions/version.txt",
            bytes: Data("not a framework\n".utf8)
        )

        let result = try await build(fixture.root)
        let manifest = try JSONDecoder().decode(
            CapturedContainerManifest.self,
            from: result.canonicalManifestBytes
        )
        let kinds = Dictionary(uniqueKeysWithValues: manifest.entries.map {
            ($0.relativePath, $0.kind)
        })
        XCTAssertEqual(kinds["Fake.app"], .directory)
        XCTAssertEqual(kinds["Fake.framework"], .directory)
    }

    func testMalformedBundleFilesystemFactsRemainDirectories() async throws {
        let fixture = try ContainerFixture(named: "malformed-bundle-facts")
        defer { fixture.remove() }

        try fixture.writeFile(
            "InfoDirectory.app/Contents/Info.plist/placeholder",
            bytes: Data("not a regular plist\n".utf8)
        )
        let infoDirectoryExecutable = try fixture.writeFile(
            "InfoDirectory.app/Contents/MacOS/InfoDirectory",
            bytes: verifiedMachOHeader(fileType: 0x2)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: infoDirectoryExecutable.path
        )

        try fixture.writeFile(
            "TextExecutable.app/Contents/Info.plist",
            bytes: Data("<?xml version=\"1.0\"?><plist><dict/></plist>\n".utf8)
        )
        let textExecutable = try fixture.writeFile(
            "TextExecutable.app/Contents/MacOS/TextExecutable",
            bytes: Data("#!/bin/sh\nexit 0\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: textExecutable.path
        )

        try fixture.writeFile(
            "NonExecutable.app/Contents/Info.plist",
            bytes: Data("<?xml version=\"1.0\"?><plist><dict/></plist>\n".utf8)
        )
        try fixture.writeFile(
            "NonExecutable.app/Contents/MacOS/NonExecutable",
            bytes: verifiedMachOHeader(fileType: 0x2)
        )
        try fixture.writeFile(
            "Text.framework/Versions/A/Text",
            bytes: Data("not a loadable framework image\n".utf8)
        )

        let result = try await build(fixture.root)
        let manifest = try JSONDecoder().decode(
            CapturedContainerManifest.self,
            from: result.canonicalManifestBytes
        )
        let rootKinds = Dictionary(uniqueKeysWithValues: manifest.entries.map {
            ($0.relativePath, $0.kind)
        })

        for name in [
            "InfoDirectory.app",
            "TextExecutable.app",
            "NonExecutable.app",
            "Text.framework",
        ] {
            XCTAssertEqual(rootKinds[name], .directory, name)
        }
    }

    func testCanonicalManifestExcludesVolatileMetadataButIncludesBytesAndExecutableMode() async throws {
        let fixture = try ContainerFixture(named: "volatile")
        defer { fixture.remove() }

        let payload = try fixture.writeFile("payload.bin", bytes: Data("one".utf8))
        let first = try await build(fixture.root)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: payload.path
        )
        let afterMTime = try await build(fixture.root)
        XCTAssertEqual(first.canonicalManifestBytes, afterMTime.canonicalManifestBytes)

        try fixture.writeFile("payload.bin", bytes: Data("two".utf8))
        let afterBytes = try await build(fixture.root)
        XCTAssertNotEqual(first.canonicalManifestBytes, afterBytes.canonicalManifestBytes)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: payload.path
        )
        let afterMode = try await build(fixture.root)
        XCTAssertNotEqual(afterBytes.canonicalManifestBytes, afterMode.canonicalManifestBytes)
    }

    func testCanonicalManifestNormalizesRelativePathsAsNFCAndSortsByUTF8Bytes() async throws {
        let composed = try ContainerFixture(named: "composed")
        let decomposed = try ContainerFixture(named: "decomposed")
        defer {
            composed.remove()
            decomposed.remove()
        }

        try composed.writeFile("é.txt", bytes: Data("accent".utf8))
        try composed.writeFile("z.txt", bytes: Data("z".utf8))
        try composed.writeFile("A.txt", bytes: Data("a".utf8))

        try decomposed.writeFile("z.txt", bytes: Data("z".utf8))
        try decomposed.writeFile("A.txt", bytes: Data("a".utf8))
        try decomposed.writeFile("e\u{301}.txt", bytes: Data("accent".utf8))

        let first = try await build(composed.root)
        let second = try await build(decomposed.root)

        XCTAssertEqual(first.canonicalManifestBytes, second.canonicalManifestBytes)
        XCTAssertEqual(first.contentIdentity, second.contentIdentity)
    }

    func testNestedContainerChangesItsParentManifestIdentity() async throws {
        let fixture = try ContainerFixture(named: "nested")
        defer { fixture.remove() }

        try fixture.writeFile("Nested/leaf.txt", bytes: Data("first".utf8))
        let first = try await build(fixture.root)

        try fixture.writeFile("Nested/leaf.txt", bytes: Data("second".utf8))
        let second = try await build(fixture.root)

        XCTAssertNotEqual(first.canonicalManifestBytes, second.canonicalManifestBytes)
        XCTAssertNotEqual(first.contentIdentity, second.contentIdentity)
    }

    func testSymlinkTextParticipatesInIdentityButEscapingTargetsAreNeverTraversed() async throws {
        let fixture = try ContainerFixture(named: "links")
        defer { fixture.remove() }
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try Data("external-v1".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try fixture.writeFile("payload.txt", bytes: Data("payload".utf8))
        try fixture.makeLink("inside-link", target: "payload.txt")
        try fixture.makeLink("outside-link", target: "../outside.txt")
        let first = try await build(fixture.root)

        try Data("external-v2".utf8).write(to: outside)
        let afterExternalMutation = try await build(fixture.root)
        XCTAssertEqual(first.canonicalManifestBytes, afterExternalMutation.canonicalManifestBytes)

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("inside-link"))
        try fixture.makeLink("inside-link", target: "different-target.txt")
        let afterLinkText = try await build(fixture.root)
        XCTAssertNotEqual(first.canonicalManifestBytes, afterLinkText.canonicalManifestBytes)
    }

    func testContainerManifestAttachmentIsRegularImmutableBytesForItsContentIdentity() async throws {
        let fixture = try ContainerFixture(named: "attachment")
        defer { fixture.remove() }
        try fixture.writeFile("input.dat", bytes: Data("immutable input".utf8))

        let result = try await build(fixture.root)
        let values = try result.attachmentSource.verifiedURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertNotEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try Data(contentsOf: result.attachmentSource.verifiedURL), result.canonicalManifestBytes)
        XCTAssertEqual(result.attachmentSource.contentIdentity, result.contentIdentity)
    }

    func testRejectsUnsafeControlCharacterPathComponents() async throws {
        let fixture = try ContainerFixture(named: "unsafe")
        defer { fixture.remove() }
        try fixture.writeFile("unsafe\u{0001}name", bytes: Data("blocked".utf8))

        await XCTAssertThrowsErrorAsync {
            _ = try await self.build(fixture.root)
        }
    }

    func testRejectsDepthEntryPathAndEncodedByteBudgetExcesses() async throws {
        let fixture = try ContainerFixture(named: "limits")
        defer { fixture.remove() }
        try fixture.writeFile("deep/inside/value.txt", bytes: Data("value".utf8))
        try fixture.writeFile("one.txt", bytes: Data("one".utf8))
        try fixture.writeFile("two.txt", bytes: Data("two".utf8))
        try fixture.writeFile("three.txt", bytes: Data("three".utf8))

        let cases: [(String, Int, Int, Int, Int)] = [
            ("depth", 1, 32, 1_024, 4_096),
            ("entries", 16, 2, 1_024, 4_096),
            ("path", 16, 32, 3, 4_096),
            ("encoded bytes", 16, 32, 1_024, 16),
        ]
        for (label, maximumDepth, maximumEntries, maximumRelativePathUTF8Bytes, maximumEncodedBytes) in cases {
            await XCTAssertThrowsErrorAsync(label) {
                _ = try await self.build(
                    fixture.root,
                    maximumDepth: maximumDepth,
                    maximumEntries: maximumEntries,
                    maximumRelativePathUTF8Bytes: maximumRelativePathUTF8Bytes,
                    maximumEncodedBytes: maximumEncodedBytes
                )
            }
        }
    }

    func testPreCancelledTraversalFailsWithoutPublishingAnAttachment() async throws {
        let fixture = try ContainerFixture(named: "cancelled")
        defer { fixture.remove() }
        try fixture.writeFile("input.txt", bytes: Data("input".utf8))
        let cancellation = ReconstructionCancellation()
        cancellation.cancel()

        await XCTAssertThrowsErrorAsync {
            _ = try await ReconstructionContainerManifestBuilder().build(
                rootURL: fixture.root,
                limits: .init(
                    maximumDepth: 16,
                    maximumEntries: 64,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024
                ),
                cancellation: cancellation
            )
        }
    }

    func testMaterializationFailurePreservesReplacementAtTemporaryPath() throws {
        let cancellation = ReconstructionCancellation()
        let replacement = MaterializedAttachmentReplacement(cancellation: cancellation)
        let builder = ReconstructionContainerManifestBuilder(
            testHooks: .init(afterAttachmentCreation: replacement.replaceAndCancel)
        )
        let identity = try fixedContentIdentity(byte: "7", byteCount: 7)

        XCTAssertThrowsError(try builder.buildCapturedManifest(
            entries: [
                .init(
                    relativePath: "input.bin",
                    kind: .opaque,
                    contentIdentity: identity,
                    executableMode: false,
                    symbolicLinkTarget: nil
                ),
            ],
            limits: .init(
                maximumDepth: 8,
                maximumEntries: 8,
                maximumRelativePathUTF8Bytes: 1_024,
                maximumEncodedBytes: 64 * 1_024
            ),
            cancellation: cancellation
        ))
        try replacement.rethrowFailure()
        let replacementURL = try XCTUnwrap(replacement.replacementPayloadURL)
        let preservedCreatorURL = try XCTUnwrap(replacement.preservedCreatorURL)
        defer {
            try? FileManager.default.removeItem(at: replacementURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: preservedCreatorURL)
        }

        XCTAssertEqual(
            try Data(contentsOf: replacementURL),
            Data("unowned replacement".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedCreatorURL.path))
    }

    func testStructuralFactPrefixWorkStopsAtConfiguredLimit() async throws {
        let fixture = try ContainerFixture(named: "structural-prefix-limit")
        defer { fixture.remove() }
        try fixture.writeFile("outer/inner/one.txt", bytes: Data("one".utf8))
        try fixture.writeFile("outer/inner/two.txt", bytes: Data("two".utf8))
        let prefixed = StructuralFactPrefixRecorder()
        let builder = ReconstructionContainerManifestBuilder(
            testHooks: .init(afterStructuralFactPrefix: prefixed.record)
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await builder.build(
                rootURL: fixture.root,
                limits: .init(
                    maximumDepth: 8,
                    maximumEntries: 16,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024,
                    maximumStructuralFactPrefixOperations: 1,
                    maximumStructuralFactPrefixUTF8Bytes: 1_024
                ),
                cancellation: ReconstructionCancellation()
            )
        }
        XCTAssertEqual(prefixed.paths.count, 1)
    }

    func testStructuralFactPrefixingObservesCancellationBetweenFacts() async throws {
        let fixture = try ContainerFixture(named: "structural-prefix-cancellation")
        defer { fixture.remove() }
        try fixture.writeFile("outer/inner/one.txt", bytes: Data("one".utf8))
        try fixture.writeFile("outer/inner/two.txt", bytes: Data("two".utf8))
        let cancellation = ReconstructionCancellation()
        let prefixed = StructuralFactPrefixRecorder(cancellation: cancellation)
        let builder = ReconstructionContainerManifestBuilder(
            testHooks: .init(afterStructuralFactPrefix: prefixed.record)
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await builder.build(
                rootURL: fixture.root,
                limits: .init(
                    maximumDepth: 8,
                    maximumEntries: 16,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024
                ),
                cancellation: cancellation
            )
        }
        XCTAssertEqual(prefixed.paths.count, 1)
    }

    func testEnumerationFailureIsFailClosedBeforeAnyAttachmentIsPublished() async throws {
        let fixture = try ContainerFixture(named: "enumeration-failure")
        defer { fixture.remove() }
        try fixture.writeFile("first.txt", bytes: Data("first".utf8))
        try fixture.writeFile("second.txt", bytes: Data("second".utf8))

        let builder = ReconstructionContainerManifestBuilder(
            testHooks: .init(forcedReaddirFailureAfterEntryCount: 1)
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await builder.build(
                rootURL: fixture.root,
                limits: .init(
                    maximumDepth: 16,
                    maximumEntries: 64,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024
                ),
                cancellation: ReconstructionCancellation()
            )
        }
    }

    func testGlobalEntryBudgetStopsBeforeOpeningOverBudgetNestedChildren() async throws {
        let fixture = try ContainerFixture(named: "global-budget")
        defer { fixture.remove() }
        try fixture.writeFile("nested/one.txt", bytes: Data("one".utf8))
        try fixture.writeFile("nested/two.txt", bytes: Data("two".utf8))
        let opened = OpenedEntryRecorder()
        let builder = ReconstructionContainerManifestBuilder(
            testHooks: .init(beforeOpeningEntry: { opened.append($0) })
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await builder.build(
                rootURL: fixture.root,
                limits: .init(
                    maximumDepth: 16,
                    maximumEntries: 2,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024
                ),
                cancellation: ReconstructionCancellation()
            )
        }
        XCTAssertEqual(opened.paths, ["nested"])
    }

    func testEntryAndDirectoryDriftAfterDescriptorAcquisitionFailClosed() async throws {
        let fileFixture = try ContainerFixture(named: "file-drift")
        defer { fileFixture.remove() }
        let payload = try fileFixture.writeFile("payload.txt", bytes: Data("before".utf8))
        let fileBuilder = ReconstructionContainerManifestBuilder(
            testHooks: .init(afterRegularFileRead: { relativePath in
                guard relativePath == "payload.txt" else { return }
                try? Data("after".utf8).write(to: payload)
            })
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await fileBuilder.build(
                rootURL: fileFixture.root,
                limits: .init(
                    maximumDepth: 16,
                    maximumEntries: 64,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024
                ),
                cancellation: ReconstructionCancellation()
            )
        }

        let directoryFixture = try ContainerFixture(named: "directory-drift")
        defer { directoryFixture.remove() }
        try directoryFixture.writeFile("stable.txt", bytes: Data("stable".utf8))
        let directoryBuilder = ReconstructionContainerManifestBuilder(
            testHooks: .init(afterDirectoryTraversal: { relativePath in
                guard relativePath.isEmpty else { return }
                try? Data("late".utf8).write(to: directoryFixture.root.appendingPathComponent("late.txt"))
            })
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await directoryBuilder.build(
                rootURL: directoryFixture.root,
                limits: .init(
                    maximumDepth: 16,
                    maximumEntries: 64,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024
                ),
                cancellation: ReconstructionCancellation()
            )
        }

        let linkFixture = try ContainerFixture(named: "link-drift")
        defer { linkFixture.remove() }
        try linkFixture.writeFile("payload.txt", bytes: Data("payload".utf8))
        try linkFixture.makeLink("payload-link", target: "payload.txt")
        let linkURL = linkFixture.root.appendingPathComponent("payload-link")
        let linkBuilder = ReconstructionContainerManifestBuilder(
            testHooks: .init(afterSymbolicLinkRead: { relativePath in
                guard relativePath == "payload-link" else { return }
                try? FileManager.default.removeItem(at: linkURL)
                try? FileManager.default.createSymbolicLink(
                    atPath: linkURL.path,
                    withDestinationPath: "replacement.txt"
                )
            })
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await linkBuilder.build(
                rootURL: linkFixture.root,
                limits: .init(
                    maximumDepth: 16,
                    maximumEntries: 64,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024
                ),
                cancellation: ReconstructionCancellation()
            )
        }
    }

    func testFinalDescriptorRelativeFactCutRejectsNestedBytesModeAndSymlinkDrift() async throws {
        for mutation in NestedFactMutation.allCases {
            let fixture = try ContainerFixture(named: "final-fact-cut-\(mutation.rawValue)")
            defer { fixture.remove() }
            let subject = fixture.root.appendingPathComponent("Nested/subject")
            switch mutation {
            case .sameSizeBytes:
                try fixture.writeFile("Nested/subject", bytes: Data("fact-A\n".utf8))
            case .executableMode:
                try fixture.writeFile("Nested/subject", bytes: Data("mode fact\n".utf8))
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: subject.path
                )
            case .symbolicLinkText:
                try fixture.makeLink("Nested/subject", target: "target-A")
            }

            let builder = ReconstructionContainerManifestBuilder(
                testHooks: .init(afterDirectoryTraversal: { relativePath in
                    guard relativePath.isEmpty else { return }
                    switch mutation {
                    case .sameSizeBytes:
                        guard let handle = try? FileHandle(forWritingTo: subject) else { return }
                        try? handle.write(contentsOf: Data("fact-B\n".utf8))
                        try? handle.synchronize()
                        try? handle.close()
                    case .executableMode:
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o755],
                            ofItemAtPath: subject.path
                        )
                    case .symbolicLinkText:
                        try? FileManager.default.removeItem(at: subject)
                        try? FileManager.default.createSymbolicLink(
                            atPath: subject.path,
                            withDestinationPath: "target-B"
                        )
                    }
                })
            )

            await XCTAssertThrowsErrorAsync(mutation.rawValue) {
                _ = try await builder.build(
                    rootURL: fixture.root,
                    limits: .init(
                        maximumDepth: 16,
                        maximumEntries: 64,
                        maximumRelativePathUTF8Bytes: 1_024,
                        maximumEncodedBytes: 64 * 1_024
                    ),
                    cancellation: ReconstructionCancellation()
                )
            }
        }
    }

    func testRejectsCallerLimitsBeyondAbsoluteTraversalHardCeilings() async throws {
        let fixture = try ContainerFixture(named: "absolute-limits")
        defer { fixture.remove() }
        try fixture.writeFile("input.txt", bytes: Data("input".utf8))

        let cases: [(Int, Int, Int, Int)] = [
            (129, 64, 1_024, 64 * 1_024),
            (16, 100_001, 1_024, 64 * 1_024),
            (16, 64, 16 * 1_024 + 1, 64 * 1_024),
            (16, 64, 1_024, 64 * 1_024 * 1_024 + 1),
        ]
        for (maximumDepth, maximumEntries, maximumRelativePathUTF8Bytes, maximumEncodedBytes) in cases {
            await XCTAssertThrowsErrorAsync {
                _ = try await self.build(
                    fixture.root,
                    maximumDepth: maximumDepth,
                    maximumEntries: maximumEntries,
                    maximumRelativePathUTF8Bytes: maximumRelativePathUTF8Bytes,
                    maximumEncodedBytes: maximumEncodedBytes
                )
            }
        }
    }

    func testPerFileContentBudgetRejectsBeforeStreamingOversizedFile() async throws {
        let fixture = try ContainerFixture(named: "per-file-content-budget")
        defer { fixture.remove() }
        try fixture.writeFile("too-large.bin", bytes: Data("four".utf8))
        let streamed = OpenedEntryRecorder()
        let builder = ReconstructionContainerManifestBuilder(
            testHooks: .init(afterRegularFileRead: { streamed.append($0) })
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await builder.build(
                rootURL: fixture.root,
                limits: .init(
                    maximumDepth: 16,
                    maximumEntries: 64,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024,
                    maximumFileBytes: 3,
                    maximumTotalContentBytes: 64
                ),
                cancellation: ReconstructionCancellation()
            )
        }
        XCTAssertTrue(streamed.paths.isEmpty)
    }

    func testAggregateContentBudgetStopsBeforeStreamingTheOverBudgetFile() async throws {
        let fixture = try ContainerFixture(named: "aggregate-content-budget")
        defer { fixture.remove() }
        try fixture.writeFile("a-first.bin", bytes: Data("one".utf8))
        try fixture.writeFile("b-second.bin", bytes: Data("two".utf8))
        let streamed = OpenedEntryRecorder()
        let builder = ReconstructionContainerManifestBuilder(
            testHooks: .init(afterRegularFileRead: { streamed.append($0) })
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await builder.build(
                rootURL: fixture.root,
                limits: .init(
                    maximumDepth: 16,
                    maximumEntries: 64,
                    maximumRelativePathUTF8Bytes: 1_024,
                    maximumEncodedBytes: 64 * 1_024,
                    maximumFileBytes: 3,
                    maximumTotalContentBytes: 5
                ),
                cancellation: ReconstructionCancellation()
            )
        }
        XCTAssertEqual(streamed.paths, ["a-first.bin"])
    }

    func testRejectsContentByteLimitsBeyondTheCorpusAttachmentHardCeiling() async throws {
        let fixture = try ContainerFixture(named: "content-limit-hard-ceiling")
        defer { fixture.remove() }
        try fixture.writeFile("input.txt", bytes: Data("input".utf8))

        let excessive = ReconstructionPackageLayout.maximumCorpusAttachmentBytes + 1
        for limits in [
            ReconstructionContainerManifestBuilder.Limits(
                maximumDepth: 16,
                maximumEntries: 64,
                maximumRelativePathUTF8Bytes: 1_024,
                maximumEncodedBytes: 64 * 1_024,
                maximumFileBytes: excessive
            ),
            ReconstructionContainerManifestBuilder.Limits(
                maximumDepth: 16,
                maximumEntries: 64,
                maximumRelativePathUTF8Bytes: 1_024,
                maximumEncodedBytes: 64 * 1_024,
                maximumTotalContentBytes: excessive
            ),
        ] {
            await XCTAssertThrowsErrorAsync {
                _ = try await ReconstructionContainerManifestBuilder().build(
                    rootURL: fixture.root,
                    limits: limits,
                    cancellation: ReconstructionCancellation()
                )
            }
        }
    }

    private func build(
        _ rootURL: URL,
        maximumDepth: Int = 16,
        maximumEntries: Int = 64,
        maximumRelativePathUTF8Bytes: Int = 1_024,
        maximumEncodedBytes: Int = 64 * 1_024
    ) async throws -> (
        canonicalManifestBytes: Data,
        contentIdentity: ReconstructionContentIdentity,
        attachmentSource: ReconstructionAttachmentSource
    ) {
        let result = try await ReconstructionContainerManifestBuilder().build(
            rootURL: rootURL,
            limits: .init(
                maximumDepth: maximumDepth,
                maximumEntries: maximumEntries,
                maximumRelativePathUTF8Bytes: maximumRelativePathUTF8Bytes,
                maximumEncodedBytes: maximumEncodedBytes
            ),
            cancellation: ReconstructionCancellation()
        )
        return (
            canonicalManifestBytes: result.canonicalManifestBytes,
            contentIdentity: result.contentIdentity,
            attachmentSource: result.attachmentSource
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ message: String = "",
        _ expression: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error. \(message)", file: file, line: line)
        } catch {
            // Expected: tests here intentionally establish the explicit reject/fail-closed contract.
        }
    }
}

private struct ContainerFixture {
    let root: URL

    init(named name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReconstructionContainerManifestTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func writeFile(_ relativePath: String, bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: url)
        return url
    }

    func makeLink(_ relativePath: String, target: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class OpenedEntryRecorder {
    private(set) var paths: [String] = []

    func append(_ path: String) {
        paths.append(path)
    }
}

private final class MaterializedAttachmentReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: ReconstructionCancellation
    private var failure: Error?
    private var recordedReplacementPayloadURL: URL?
    private var recordedPreservedCreatorURL: URL?

    init(cancellation: ReconstructionCancellation) {
        self.cancellation = cancellation
    }

    var replacementPayloadURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedReplacementPayloadURL
    }

    var preservedCreatorURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedPreservedCreatorURL
    }

    func replaceAndCancel(_ creatorURL: URL) {
        do {
            let preservedCreatorURL = creatorURL.deletingLastPathComponent()
                .appendingPathComponent("MacScope-preserved-creator-(UUID().uuidString)")
            try FileManager.default.moveItem(at: creatorURL, to: preservedCreatorURL)
            try FileManager.default.createDirectory(at: creatorURL, withIntermediateDirectories: false)
            let replacementPayloadURL = creatorURL.appendingPathComponent("replacement.bin")
            try Data("unowned replacement".utf8).write(to: replacementPayloadURL)
            lock.lock()
            recordedPreservedCreatorURL = preservedCreatorURL
            recordedReplacementPayloadURL = replacementPayloadURL
            lock.unlock()
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
        }
        cancellation.cancel()
    }

    func rethrowFailure() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
    }
}

private final class StructuralFactPrefixRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: ReconstructionCancellation?
    private var recordedPaths: [String] = []

    init(cancellation: ReconstructionCancellation? = nil) {
        self.cancellation = cancellation
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    func record(_ relativePath: String) {
        lock.lock()
        recordedPaths.append(relativePath)
        let shouldCancel = recordedPaths.count == 1
        lock.unlock()
        if shouldCancel {
            cancellation?.cancel()
        }
    }
}

private enum NestedFactMutation: String, CaseIterable {
    case sameSizeBytes = "same-size-bytes"
    case executableMode = "executable-mode"
    case symbolicLinkText = "symbolic-link-text"
}

private struct CapturedContainerManifest: Codable {
    let schemaVersion: Int
    let entries: [CapturedContainerManifestEntry]
}

private struct CapturedContainerManifestEntry: Codable {
    let relativePath: String
    let kind: ReconstructionArtifactKind
    let contentIdentity: ReconstructionContentIdentity?
    let executableMode: Bool
    let symbolicLinkTarget: String?
}

private func fixedContentIdentity(
    byte: Character,
    byteCount: UInt64
) throws -> ReconstructionContentIdentity {
    try ReconstructionContentIdentity(
        algorithm: .sha256,
        digest: String(repeating: String(byte), count: 64),
        byteCount: byteCount
    )
}

private func verifiedMachOHeader(fileType: UInt32) -> Data {
    Data([
        0xcf, 0xfa, 0xed, 0xfe,
        0x07, 0x00, 0x00, 0x01,
        0x03, 0x00, 0x00, 0x00,
        UInt8(truncatingIfNeeded: fileType),
        UInt8(truncatingIfNeeded: fileType >> 8),
        UInt8(truncatingIfNeeded: fileType >> 16),
        UInt8(truncatingIfNeeded: fileType >> 24),
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])
}

private func verifiedZIPLocalHeader() -> Data {
    Data([0x50, 0x4b, 0x03, 0x04] + Array(repeating: 0, count: 26))
}
