import XCTest
@testable import MacScope

final class FunctionSignatureValidationTests: XCTestCase {
    func testRecordNamesRejectEmptyWhitespaceAndControlText() {
        let invalidNames = ["", " leading", "trailing ", "line\nfeed", "nul\0byte"]
        for (index, name) in invalidNames.enumerated() {
            assertInvalid(
                makeSignature(name: name, libraryName: "lib\(index)"),
                includes: [.invalidName]
            )
        }

        let invalidLibraries = ["", " leading", "trailing ", "line\nfeed", "nul\0byte"]
        for (index, libraryName) in invalidLibraries.enumerated() {
            assertInvalid(
                makeSignature(name: "function\(index)", libraryName: libraryName),
                includes: [.invalidLibraryName]
            )
        }
    }

    func testImportedReferenceNamesRejectEmptyWhitespaceAndControlText() {
        for invalidName in ["", " _memcpy", "_memcpy ", "_mem\ncpy", "_mem\0cpy"] {
            assertInvalid(
                makeSignature(
                    references: [
                        FunctionSignatureImportedReference(
                            instructionOffset: 48,
                            expectedSymbolName: invalidName
                        ),
                    ]
                ),
                includes: [.invalidImportedReference]
            )
        }
    }

    func testRecordAndReferenceTextIsPreservedVerbatimWhenValid() {
        assertValid(
            makeSignature(
                name: "___divti3",
                libraryName: "compiler-rt builtins",
                references: [
                    FunctionSignatureImportedReference(
                        instructionOffset: 48,
                        expectedSymbolName: "_memcpy$VARIANT$armv81"
                    ),
                ]
            )
        )
    }

    func testTotalLengthMustBePositiveAlignedAndAtMostOneMiB() {
        for length: UInt32 in [0, 2, 66, 1_048_580] {
            assertInvalid(makeSignature(totalLength: length), includes: [.invalidTotalLength])
        }

        assertValid(makeSignature(totalLength: 1_048_576))
    }

    func testPrefixLengthIsExactlyFunctionLengthCappedAtThirtyTwoBytes() {
        let short = makeSignature(
            totalLength: 16,
            prefixBytes: Array(repeating: 0xA5, count: 16),
            prefixMask: Array(repeating: 0xFF, count: 16),
            checksum: FunctionSignatureChecksumSpan(offset: 16, byteCount: 0, crc32: 0)
        )
        assertValid(short)

        assertInvalid(
            makeSignature(prefixBytes: Array(repeating: 0xA5, count: 31)),
            includes: [.invalidPrefixLength, .prefixMaskLengthMismatch]
        )
        assertInvalid(
            makeSignature(
                totalLength: 16,
                prefixBytes: Array(repeating: 0xA5, count: 32),
                prefixMask: Array(repeating: 0xFF, count: 32),
                checksum: FunctionSignatureChecksumSpan(offset: 16, byteCount: 0, crc32: 0)
            ),
            includes: [.invalidPrefixLength]
        )
    }

    func testPrefixMasksRequireEqualCountsBinaryValuesAndCanonicalWildcards() {
        assertInvalid(
            makeSignature(prefixMask: Array(repeating: 0xFF, count: 31)),
            includes: [.prefixMaskLengthMismatch]
        )

        var invalidMask = Array(repeating: UInt8(0xFF), count: 32)
        invalidMask[8] = 0x7F
        assertInvalid(makeSignature(prefixMask: invalidMask), includes: [.invalidPrefixMask])

        var wildcardMask = Array(repeating: UInt8(0xFF), count: 32)
        wildcardMask[8] = 0
        assertInvalid(
            makeSignature(prefixMask: wildcardMask),
            includes: [.noncanonicalWildcardByte]
        )

        var canonicalBytes = Array(repeating: UInt8(0xA5), count: 32)
        canonicalBytes[8] = 0
        assertValid(makeSignature(prefixBytes: canonicalBytes, prefixMask: wildcardMask))
    }

    func testPrefixRequiresAnAlignedFullyExactFourByteAnchor() {
        var mask = Array(repeating: UInt8(0), count: 32)
        mask.replaceSubrange(1..<5, with: repeatElement(0xFF, count: 4))
        let bytes = zip(Array(repeating: UInt8(0xA5), count: 32), mask).map {
            $0.1 == 0 ? 0 : $0.0
        }

        assertInvalid(
            makeSignature(prefixBytes: bytes, prefixMask: mask),
            includes: [.missingExactAnchor]
        )
    }

    func testPrefixIndexSelectsLowestAlignedExactWordAndKeepsByteOrder() {
        var mask = Array(repeating: UInt8(0), count: 32)
        mask.replaceSubrange(4..<8, with: repeatElement(0xFF, count: 4))
        mask.replaceSubrange(12..<16, with: repeatElement(0xFF, count: 4))
        var bytes = Array(repeating: UInt8(0), count: 32)
        bytes.replaceSubrange(4..<8, with: [0x11, 0x22, 0x33, 0x44])
        bytes.replaceSubrange(12..<16, with: [0xAA, 0xBB, 0xCC, 0xDD])
        let signature = makeSignature(prefixBytes: bytes, prefixMask: mask)

        let key = FunctionSignaturePrefixIndexKey.make(for: signature)

        XCTAssertEqual(key?.architecture, .arm64)
        XCTAssertEqual(key?.anchorOffset, 4)
        XCTAssertEqual(key?.byte0, 0x11)
        XCTAssertEqual(key?.byte1, 0x22)
        XCTAssertEqual(key?.byte2, 0x33)
        XCTAssertEqual(key?.byte3, 0x44)
    }

    func testCanonicalZeroChecksumIsAcceptedOnlyWhenPrefixCoversTheFunction() {
        assertValid(
            makeSignature(
                totalLength: 32,
                checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 0, crc32: 0)
            )
        )

        assertInvalid(
            makeSignature(checksum: FunctionSignatureChecksumSpan(offset: 64, byteCount: 0, crc32: 0)),
            includes: [.noncanonicalZeroChecksum]
        )
        assertInvalid(
            makeSignature(checksum: FunctionSignatureChecksumSpan(offset: 64, byteCount: 0, crc32: 1)),
            includes: [.noncanonicalZeroChecksum]
        )
        assertInvalid(
            makeSignature(checksum: FunctionSignatureChecksumSpan(offset: 60, byteCount: 0, crc32: 0)),
            includes: [.noncanonicalZeroChecksum]
        )
    }

    func testNonemptyChecksumMayHaveZeroCRCButMustFollowPrefixAndFitFunction() {
        assertValid(
            makeSignature(checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 4, crc32: 0))
        )
        assertInvalid(
            makeSignature(checksum: FunctionSignatureChecksumSpan(offset: 28, byteCount: 4, crc32: 1)),
            includes: [.invalidChecksumRange]
        )
        assertInvalid(
            makeSignature(checksum: FunctionSignatureChecksumSpan(offset: 60, byteCount: 8, crc32: 1)),
            includes: [.invalidChecksumRange]
        )
    }

    func testTailRunsMustBeNonemptySortedNonoverlappingAndAfterChecksum() {
        assertInvalid(
            makeSignature(tailRuns: [run(offset: 40, bytes: [], mask: [])]),
            includes: [.invalidTailRun]
        )
        assertInvalid(
            makeSignature(tailRuns: [run(offset: 39, bytes: [0xA5], mask: [0xFF])]),
            includes: [.invalidTailRun]
        )
        assertInvalid(
            makeSignature(
                tailRuns: [
                    run(offset: 44, bytes: [0xA5], mask: [0xFF]),
                    run(offset: 40, bytes: [0xA5], mask: [0xFF]),
                ]
            ),
            includes: [.invalidTailRun]
        )
        assertInvalid(
            makeSignature(
                tailRuns: [
                    run(offset: 40, bytes: [1, 2, 3, 4], mask: [0xFF, 0xFF, 0xFF, 0xFF]),
                    run(offset: 43, bytes: [5], mask: [0xFF]),
                ]
            ),
            includes: [.invalidTailRun]
        )

        assertValid(
            makeSignature(
                tailRuns: [
                    run(offset: 40, bytes: [1, 2, 3, 4], mask: [0xFF, 0xFF, 0xFF, 0xFF]),
                    run(offset: 44, bytes: [5], mask: [0xFF]),
                ]
            )
        )
    }

    func testTailRunMasksRequireEqualCountsBinaryValuesExactEvidenceAndCanonicalWildcards() {
        assertInvalid(
            makeSignature(tailRuns: [run(offset: 40, bytes: [0xA5], mask: [])]),
            includes: [.invalidTailRun]
        )
        assertInvalid(
            makeSignature(tailRuns: [run(offset: 40, bytes: [0xA5], mask: [0x7F])]),
            includes: [.invalidTailRun]
        )
        assertInvalid(
            makeSignature(tailRuns: [run(offset: 40, bytes: [0xA5], mask: [0])]),
            includes: [.invalidTailRun, .noncanonicalWildcardByte]
        )
        assertInvalid(
            makeSignature(tailRuns: [run(offset: 40, bytes: [0], mask: [0])]),
            includes: [.invalidTailRun]
        )
    }

    func testTailRunCapsAllowEightRunsAndThirtyTwoConstrainedBytes() {
        let eightRuns = (0..<8).map {
            run(offset: 40 + UInt32($0), bytes: [UInt8($0)], mask: [0xFF])
        }
        assertValid(makeSignature(tailRuns: eightRuns))

        let nineRuns = (0..<9).map {
            run(offset: 40 + UInt32($0), bytes: [UInt8($0)], mask: [0xFF])
        }
        assertInvalid(makeSignature(tailRuns: nineRuns), includes: [.tooManyTailRuns])

        assertValid(
            makeSignature(
                totalLength: 80,
                tailRuns: [
                    run(
                        offset: 40,
                        bytes: Array(repeating: 0xA5, count: 32),
                        mask: Array(repeating: 0xFF, count: 32)
                    ),
                ]
            )
        )
        assertInvalid(
            makeSignature(
                totalLength: 80,
                tailRuns: [
                    run(
                        offset: 40,
                        bytes: Array(repeating: 0xA5, count: 33),
                        mask: Array(repeating: 0xFF, count: 33)
                    ),
                ]
            ),
            includes: [.tooManyConstrainedTailBytes]
        )
    }

    func testImportedReferencesMustBeSortedUniqueAlignedAndWithinFunction() {
        assertInvalid(
            makeSignature(references: [reference(44), reference(40)]),
            includes: [.invalidImportedReference]
        )
        assertInvalid(
            makeSignature(references: [reference(44), reference(44)]),
            includes: [.invalidImportedReference]
        )
        assertInvalid(
            makeSignature(references: [reference(42)]),
            includes: [.invalidImportedReference]
        )
        assertInvalid(
            makeSignature(references: [reference(64)]),
            includes: [.invalidImportedReference]
        )

        assertValid(makeSignature(references: [reference(40), reference(44), reference(48)]))
    }

    func testImportedReferenceCapAllowsEightAndRejectsNine() {
        let eight = (0..<8).map { reference(40 + UInt32($0 * 4)) }
        assertValid(makeSignature(totalLength: 80, references: eight))

        let nine = (0..<9).map { reference(40 + UInt32($0 * 4)) }
        assertInvalid(
            makeSignature(totalLength: 80, references: nine),
            includes: [.tooManyImportedReferences]
        )
    }

    func testImportedReferencesCannotOverlapChecksumExactTailOrExactPrefixBytes() {
        assertInvalid(
            makeSignature(references: [reference(36)]),
            includes: [.overlappingVerificationEvidence]
        )
        assertInvalid(
            makeSignature(
                tailRuns: [run(offset: 44, bytes: [0xA5], mask: [0xFF])],
                references: [reference(44)]
            ),
            includes: [.overlappingVerificationEvidence]
        )
        assertInvalid(
            makeSignature(references: [reference(4)]),
            includes: [.overlappingVerificationEvidence]
        )
    }

    func testImportedReferenceMayOverlapOnlyWildcardedPrefixOrTailBytes() {
        var prefixBytes = Array(repeating: UInt8(0xA5), count: 32)
        var prefixMask = Array(repeating: UInt8(0xFF), count: 32)
        prefixBytes.replaceSubrange(4..<8, with: repeatElement(0, count: 4))
        prefixMask.replaceSubrange(4..<8, with: repeatElement(0, count: 4))
        assertValid(
            makeSignature(
                prefixBytes: prefixBytes,
                prefixMask: prefixMask,
                references: [reference(4)]
            )
        )

        assertValid(
            makeSignature(
                tailRuns: [
                    run(
                        offset: 44,
                        bytes: [0, 0, 0, 0, 0xA5],
                        mask: [0, 0, 0, 0, 0xFF]
                    ),
                ],
                references: [reference(44)]
            )
        )
    }

    func testEvidenceFloorRejectsOneHundredTwentyBitsAndAcceptsOneHundredTwentyEight() {
        var fifteenByteMask = Array(repeating: UInt8(0), count: 32)
        fifteenByteMask.replaceSubrange(0..<15, with: repeatElement(0xFF, count: 15))
        let fifteenBytePrefix = fifteenByteMask.map { $0 == 0 ? UInt8(0) : UInt8(0xA5) }
        assertInvalid(
            makeSignature(
                totalLength: 32,
                prefixBytes: fifteenBytePrefix,
                prefixMask: fifteenByteMask,
                checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 0, crc32: 0)
            ),
            includes: [.insufficientEvidence]
        )

        var sixteenByteMask = fifteenByteMask
        sixteenByteMask[15] = 0xFF
        let sixteenBytePrefix = sixteenByteMask.map { $0 == 0 ? UInt8(0) : UInt8(0xA5) }
        assertValid(
            makeSignature(
                totalLength: 32,
                prefixBytes: sixteenBytePrefix,
                prefixMask: sixteenByteMask,
                checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 0, crc32: 0)
            )
        )
    }

    func testOffsetArithmeticNearUInt32MaximumFailsClosedWithoutTrapping() {
        assertInvalid(
            makeSignature(
                checksum: FunctionSignatureChecksumSpan(
                    offset: UInt32.max - 1,
                    byteCount: 4,
                    crc32: 1
                )
            ),
            includes: [.invalidChecksumRange]
        )
        assertInvalid(
            makeSignature(
                tailRuns: [run(offset: UInt32.max, bytes: [0xA5], mask: [0xFF])]
            ),
            includes: [.invalidTailRun]
        )
        assertInvalid(
            makeSignature(references: [reference(UInt32.max - 3)]),
            includes: [.invalidImportedReference]
        )
    }

    func testDuplicatePredicatesKeepOneCopyForSameIdentity() {
        let signature = makeSignature(name: "same", libraryName: "sameLibrary")
        let matcher = makeMatcher([signature, signature])

        XCTAssertEqual(matcher.validatedSignatureCount, 1)
        XCTAssertEqual(matcher.validationIssues.count, 1)
        XCTAssertEqual(matcher.validationIssues.map(\.reason), [.duplicatePredicate])
        XCTAssertEqual(
            matcher.validationIssues.map(\.identity),
            Array(repeating: FunctionSignatureIdentity(name: "same", libraryName: "sameLibrary"), count: 1)
        )
    }

    func testValidationIssuesAndAcceptedCountAreIndependentOfInputOrder() {
        let invalidName = makeSignature(name: " bad", libraryName: "z")
        let invalidLibrary = makeSignature(name: "alpha", libraryName: " bad")
        let invalidLength = makeSignature(name: "middle", libraryName: "m", totalLength: 66)
        let valid = makeSignature(name: "valid", libraryName: "a")

        let forward = makeMatcher([invalidName, invalidLibrary, invalidLength, valid])
        let reverse = makeMatcher([valid, invalidLength, invalidLibrary, invalidName])

        XCTAssertEqual(forward.validatedSignatureCount, 1)
        XCTAssertEqual(reverse.validatedSignatureCount, 1)
        XCTAssertEqual(forward.validationIssues, reverse.validationIssues)
        XCTAssertEqual(
            forward.validationIssues.map(\.reason),
            [.invalidLibraryName, .invalidName, .invalidTotalLength]
        )
    }

    private func assertValid(
        _ signature: FunctionSignature,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matcher = makeMatcher([signature])
        XCTAssertEqual(matcher.validatedSignatureCount, 1, file: file, line: line)
        XCTAssertTrue(matcher.validationIssues.isEmpty, "\(matcher.validationIssues)", file: file, line: line)
    }

    private func assertInvalid(
        _ signature: FunctionSignature,
        includes expectedReasons: Set<FunctionSignatureValidationReason>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matcher = makeMatcher([signature])
        let actualReasons = Set(matcher.validationIssues.map(\.reason))
        XCTAssertEqual(matcher.validatedSignatureCount, 0, file: file, line: line)
        for reason in expectedReasons {
            XCTAssertTrue(
                actualReasons.contains(reason),
                "expected \(reason.rawValue), got \(actualReasons.map(\.rawValue).sorted())",
                file: file,
                line: line
            )
        }
    }

    private func makeMatcher(_ signatures: [FunctionSignature]) -> FunctionSignatureMatcher {
        FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
                signatures: signatures
            )
        )
    }

    private func makeSignature(
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
        tailRuns: [FunctionSignatureMaskedByteRun] = [],
        references: [FunctionSignatureImportedReference] = []
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
            collisionTail: FunctionSignatureCollisionTail(
                byteRuns: tailRuns,
                importedReferences: references
            )
        )
    }

    private func run(
        offset: UInt32,
        bytes: [UInt8],
        mask: [UInt8]
    ) -> FunctionSignatureMaskedByteRun {
        FunctionSignatureMaskedByteRun(offset: offset, bytes: bytes, comparisonMask: mask)
    }

    private func reference(
        _ offset: UInt32,
        name: String = "_memcpy"
    ) -> FunctionSignatureImportedReference {
        FunctionSignatureImportedReference(instructionOffset: offset, expectedSymbolName: name)
    }
}
