import XCTest
@testable import MacScope

final class FunctionSignatureMatcherTests: XCTestCase {
    func testValidatorAcceptsEmptyAndValidSchemaV1Databases() {
        let emptyMatcher = FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
                signatures: []
            )
        )
        XCTAssertEqual(emptyMatcher.validatedSignatureCount, 0)
        XCTAssertTrue(emptyMatcher.validationIssues.isEmpty)

        let validMatcher = FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
                signatures: [makeValidSignature()]
            )
        )
        XCTAssertEqual(validMatcher.validatedSignatureCount, 1)
        XCTAssertTrue(validMatcher.validationIssues.isEmpty)
    }

    func testUnsupportedSchemaDisablesTheEntireDatabase() {
        let matcher = FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion + 1,
                signatures: [makeValidSignature()]
            )
        )

        XCTAssertEqual(matcher.validatedSignatureCount, 0)
        XCTAssertEqual(matcher.validationIssues.map(\.reason), [.unsupportedSchemaVersion])
    }

    func testValidatorQuarantinesMalformedRecordsWithoutDiscardingValidRecords() {
        let invalidName = makeValidSignature(name: " bad")
        let invalidLength = makeValidSignature(
            name: "invalidLength",
            totalLength: 66,
            prefixBytes: Array(repeating: 0xA5, count: 32),
            prefixMask: Array(repeating: 0xFF, count: 32),
            checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 8, crc32: 0)
        )
        let invalidMask = makeValidSignature(
            name: "invalidMask",
            prefixMask: [0x7F] + Array(repeating: 0xFF, count: 31)
        )
        let noncanonicalWildcard = makeValidSignature(
            name: "noncanonicalWildcard",
            prefixBytes: [0xA5] + Array(repeating: 0xA5, count: 31),
            prefixMask: [0] + Array(repeating: 0xFF, count: 31)
        )
        let invalidChecksum = makeValidSignature(
            name: "invalidChecksum",
            checksum: FunctionSignatureChecksumSpan(offset: UInt32.max, byteCount: 8, crc32: 0)
        )

        let matcher = FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
                signatures: [
                    invalidChecksum,
                    makeValidSignature(),
                    noncanonicalWildcard,
                    invalidMask,
                    invalidLength,
                    invalidName,
                ]
            )
        )

        XCTAssertEqual(matcher.validatedSignatureCount, 1)
        XCTAssertEqual(
            Set(matcher.validationIssues.map(\.reason)),
            [
                .invalidName,
                .invalidTotalLength,
                .invalidPrefixMask,
                .noncanonicalWildcardByte,
                .invalidChecksumRange,
            ]
        )
    }

    func testEqualPredicatesRetainDistinctIdentities() {
        let first = makeValidSignature(name: "first", libraryName: "libA")
        let second = makeValidSignature(name: "second", libraryName: "libB")
        let matcher = FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
                signatures: [second, first]
            )
        )

        XCTAssertEqual(matcher.validatedSignatureCount, 2)
        XCTAssertTrue(matcher.validationIssues.isEmpty)
    }

    func testMatcherRequiresEveryPredicateAndAllowsWildcardMutation() {
        let bytes = Array(UInt8(0)..<UInt8(64))
        let signature = makeMatchingSignature(bytes: bytes)
        let matcher = makeMatcher([signature])
        let identity = FunctionSignatureIdentity(name: signature.name, libraryName: signature.libraryName)

        XCTAssertFalse(matcher.isEmpty)
        XCTAssertEqual(
            matcher.match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: bytes,
                    importedReferences: [48: "_memcpy"]
                )
            ),
            .unique(identity)
        )

        var wildcardMutation = bytes
        wildcardMutation.replaceSubrange(4..<8, with: [0xFF, 0xFE, 0xFD, 0xFC])
        XCTAssertEqual(
            matcher.match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: wildcardMutation,
                    importedReferences: [48: "_memcpy"]
                )
            ),
            .unique(identity)
        )

        for mutationOffset in [0, 32, 40] {
            var mutation = bytes
            mutation[mutationOffset] ^= 0xFF
            XCTAssertEqual(
                matcher.match(
                    FunctionSignatureCandidate(
                        architecture: .arm64,
                        bytes: mutation,
                        importedReferences: [48: "_memcpy"]
                    )
                ),
                .noMatch
            )
        }
        XCTAssertEqual(
            matcher.match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: bytes,
                    importedReferences: [:]
                )
            ),
            .noMatch
        )
        XCTAssertEqual(
            matcher.match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: Array(bytes.dropLast()),
                    importedReferences: [48: "_memcpy"]
                )
            ),
            .noMatch
        )
    }

    func testMatcherCoalescesOneIdentityAndPreservesStableAmbiguity() {
        let bytes = Array(UInt8(0)..<UInt8(64))
        let first = makeMatchingSignature(bytes: bytes, name: "alpha", libraryName: "libA")
        let sameIdentityVariant = makeMatchingSignature(
            bytes: bytes,
            name: "alpha",
            libraryName: "libA",
            tailOffset: 44
        )
        XCTAssertEqual(
            makeMatcher([sameIdentityVariant, first]).match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: bytes,
                    importedReferences: [48: "_memcpy"]
                )
            ),
            .unique(FunctionSignatureIdentity(name: "alpha", libraryName: "libA"))
        )

        let secondIdentity = makeMatchingSignature(
            bytes: bytes,
            name: "beta",
            libraryName: "libB",
            tailOffset: 44
        )
        let candidate = FunctionSignatureCandidate(
            architecture: .arm64,
            bytes: bytes,
            importedReferences: [48: "_memcpy"]
        )
        let expected = FunctionSignatureMatchResult.ambiguous([
            FunctionSignatureIdentity(name: "alpha", libraryName: "libA"),
            FunctionSignatureIdentity(name: "beta", libraryName: "libB"),
        ])
        XCTAssertEqual(makeMatcher([secondIdentity, first]).match(candidate), expected)
        XCTAssertEqual(makeMatcher([first, secondIdentity]).match(candidate), expected)
    }

    func testEmptyMatcherHasNoValidatedRecords() {
        XCTAssertTrue(FunctionSignatureMatcher.empty.isEmpty)
        XCTAssertEqual(
            FunctionSignatureMatcher.empty.match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: Array(repeating: 0, count: 16),
                    importedReferences: [:]
                )
            ),
            .noMatch
        )
    }

    func testSchemaV1ValueTypesPreserveFrozenFields() {
        let signature = FunctionSignature(
            architecture: .arm64,
            name: "___divti3",
            libraryName: "compiler-rt",
            totalLength: 64,
            prefix: FunctionSignatureMaskedPattern(
                bytes: [0xFF, 0, 0xAB, 0],
                comparisonMask: [0xFF, 0, 0xFF, 0]
            ),
            checksum: FunctionSignatureChecksumSpan(
                offset: 32,
                byteCount: 16,
                crc32: 0x1234_5678
            ),
            collisionTail: FunctionSignatureCollisionTail(
                byteRuns: [
                    FunctionSignatureMaskedByteRun(
                        offset: 48,
                        bytes: [0xCD, 0],
                        comparisonMask: [0xFF, 0]
                    ),
                ],
                importedReferences: [
                    FunctionSignatureImportedReference(
                        instructionOffset: 52,
                        expectedSymbolName: "_memcpy"
                    ),
                ]
            )
        )
        let database = FunctionSignatureDatabase(
            schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
            signatures: [signature]
        )

        XCTAssertEqual(FunctionSignatureDatabase.currentSchemaVersion, 1)
        XCTAssertEqual(database.schemaVersion, 1)
        XCTAssertEqual(database.signatures, [signature])
        XCTAssertEqual(signature.architecture, .arm64)
        XCTAssertEqual(signature.name, "___divti3")
        XCTAssertEqual(signature.libraryName, "compiler-rt")
        XCTAssertEqual(signature.totalLength, 64)
        XCTAssertEqual(signature.prefix.bytes, [0xFF, 0, 0xAB, 0])
        XCTAssertEqual(signature.prefix.comparisonMask, [0xFF, 0, 0xFF, 0])
        XCTAssertEqual(signature.checksum.offset, 32)
        XCTAssertEqual(signature.checksum.byteCount, 16)
        XCTAssertEqual(signature.checksum.crc32, 0x1234_5678)
        XCTAssertEqual(signature.collisionTail.byteRuns[0].offset, 48)
        XCTAssertEqual(signature.collisionTail.importedReferences[0].instructionOffset, 52)
        XCTAssertEqual(signature.collisionTail.importedReferences[0].expectedSymbolName, "_memcpy")
    }

    func testCRC32ISOHDLCMatchesCanonicalReferenceVector() {
        XCTAssertEqual(
            FunctionSignatureCRC32.checksum(Array("123456789".utf8)),
            0xCBF4_3926
        )
    }

    func testCRC32ISOHDLCEmptyInputIsZero() {
        XCTAssertEqual(FunctionSignatureCRC32.checksum([]), 0)
    }

    private func makeValidSignature(
        name: String = "___divti3",
        libraryName: String = "compiler-rt",
        totalLength: UInt32 = 64,
        prefixBytes: [UInt8] = Array(repeating: 0xA5, count: 32),
        prefixMask: [UInt8] = Array(repeating: 0xFF, count: 32),
        checksum: FunctionSignatureChecksumSpan = FunctionSignatureChecksumSpan(
            offset: 32,
            byteCount: 8,
            crc32: 0
        ),
        collisionTail: FunctionSignatureCollisionTail = FunctionSignatureCollisionTail(
            byteRuns: [],
            importedReferences: []
        )
    ) -> FunctionSignature {
        FunctionSignature(
            architecture: .arm64,
            name: name,
            libraryName: libraryName,
            totalLength: totalLength,
            prefix: FunctionSignatureMaskedPattern(
                bytes: prefixBytes,
                comparisonMask: prefixMask
            ),
            checksum: checksum,
            collisionTail: collisionTail
        )
    }

    private func makeMatcher(_ signatures: [FunctionSignature]) -> FunctionSignatureMatcher {
        FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
                signatures: signatures
            )
        )
    }

    private func makeMatchingSignature(
        bytes: [UInt8],
        name: String = "___divti3",
        libraryName: String = "compiler-rt",
        tailOffset: UInt32 = 40
    ) -> FunctionSignature {
        var prefixBytes = Array(bytes.prefix(32))
        var prefixMask = Array(repeating: UInt8(0xFF), count: 32)
        prefixBytes.replaceSubrange(4..<8, with: repeatElement(0, count: 4))
        prefixMask.replaceSubrange(4..<8, with: repeatElement(0, count: 4))
        let checksumBytes = Array(bytes[32..<40])
        let tailStart = Int(tailOffset)
        return FunctionSignature(
            architecture: .arm64,
            name: name,
            libraryName: libraryName,
            totalLength: UInt32(bytes.count),
            prefix: FunctionSignatureMaskedPattern(
                bytes: prefixBytes,
                comparisonMask: prefixMask
            ),
            checksum: FunctionSignatureChecksumSpan(
                offset: 32,
                byteCount: 8,
                crc32: FunctionSignatureCRC32.checksum(checksumBytes)
            ),
            collisionTail: FunctionSignatureCollisionTail(
                byteRuns: [
                    FunctionSignatureMaskedByteRun(
                        offset: tailOffset,
                        bytes: Array(bytes[tailStart..<(tailStart + 4)]),
                        comparisonMask: Array(repeating: 0xFF, count: 4)
                    ),
                ],
                importedReferences: [
                    FunctionSignatureImportedReference(
                        instructionOffset: 48,
                        expectedSymbolName: "_memcpy"
                    ),
                ]
            )
        )
    }
}
