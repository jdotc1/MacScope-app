import XCTest
@testable import MacScope

final class FunctionSignatureMatcherEdgeTests: XCTestCase {
    func testMatcherRejectsCandidateLongerThanSignature() {
        let bytes = Array(UInt8(0)..<UInt8(64))
        let signature = makeMatchingSignature(bytes: bytes)
        let matcher = makeMatcher([signature])

        XCTAssertEqual(
            matcher.match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: bytes + [0, 0, 0, 0],
                    importedReferences: [48: "_memcpy"]
                )
            ),
            .noMatch
        )
    }

    func testImportedReferenceMatchingPreservesExactMachOSpellingAndCase() {
        let bytes = Array(UInt8(0)..<UInt8(64))
        let matcher = makeMatcher([makeMatchingSignature(bytes: bytes)])

        for incorrectName in ["memcpy", "_MEMCPY", "_memcpy "] {
            XCTAssertEqual(
                matcher.match(
                    FunctionSignatureCandidate(
                        architecture: .arm64,
                        bytes: bytes,
                        importedReferences: [48: incorrectName]
                    )
                ),
                .noMatch,
                "reference spelling \(incorrectName.debugDescription) must not be normalized"
            )
        }
    }

    func testTailPredicatesDisambiguateOtherwiseIdenticalSignatures() {
        var firstBytes = Array(UInt8(0)..<UInt8(64))
        var secondBytes = firstBytes
        firstBytes.replaceSubrange(40..<44, with: [0xA1, 0xA2, 0xA3, 0xA4])
        secondBytes.replaceSubrange(40..<44, with: [0xB1, 0xB2, 0xB3, 0xB4])

        let first = makeMatchingSignature(
            bytes: firstBytes,
            name: "firstTail",
            tailOffset: 40,
            importedReference: nil
        )
        let second = makeMatchingSignature(
            bytes: secondBytes,
            name: "secondTail",
            tailOffset: 40,
            importedReference: nil
        )
        let matcher = makeMatcher([second, first])

        XCTAssertEqual(
            matcher.match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: firstBytes,
                    importedReferences: [:]
                )
            ),
            .unique(FunctionSignatureIdentity(name: "firstTail", libraryName: "compiler-rt"))
        )
        XCTAssertEqual(
            matcher.match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: secondBytes,
                    importedReferences: [:]
                )
            ),
            .unique(FunctionSignatureIdentity(name: "secondTail", libraryName: "compiler-rt"))
        )
    }

    func testChecksumEvidenceContributionIsCappedAtThirtyTwoBits() {
        let elevenExactPrefixBytes = mask(exactByteCount: 11)
        let weak = makeSignature(
            name: "weakDespiteLongChecksum",
            totalLength: 160,
            prefixMask: elevenExactPrefixBytes,
            checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 100, crc32: 0)
        )
        let weakMatcher = makeMatcher([weak])

        XCTAssertEqual(weakMatcher.validatedSignatureCount, 0)
        XCTAssertTrue(weakMatcher.validationIssues.map(\.reason).contains(.insufficientEvidence))

        let twelveExactPrefixBytes = mask(exactByteCount: 12)
        let threshold = makeSignature(
            name: "thresholdWithLongChecksum",
            totalLength: 160,
            prefixMask: twelveExactPrefixBytes,
            checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 100, crc32: 0)
        )
        let thresholdMatcher = makeMatcher([threshold])

        XCTAssertEqual(thresholdMatcher.validatedSignatureCount, 1)
        XCTAssertTrue(thresholdMatcher.validationIssues.isEmpty)
    }

    func testTailEvidenceCountsExactBytesButNotWildcards() {
        let prefixMask = mask(exactByteCount: 12)
        let threshold = makeSignature(
            name: "thresholdTail",
            prefixMask: prefixMask,
            checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 1, crc32: 0),
            tail: FunctionSignatureCollisionTail(
                byteRuns: [
                    FunctionSignatureMaskedByteRun(
                        offset: 36,
                        bytes: [0x11, 0x22, 0x33, 0],
                        comparisonMask: [0xFF, 0xFF, 0xFF, 0]
                    ),
                ],
                importedReferences: []
            )
        )
        XCTAssertEqual(makeMatcher([threshold]).validatedSignatureCount, 1)

        let wildcardHeavy = makeSignature(
            name: "wildcardsDoNotRaiseEvidence",
            prefixMask: prefixMask,
            checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 1, crc32: 0),
            tail: FunctionSignatureCollisionTail(
                byteRuns: [
                    FunctionSignatureMaskedByteRun(
                        offset: 36,
                        bytes: [0x11, 0x22, 0, 0, 0, 0, 0, 0],
                        comparisonMask: [0xFF, 0xFF, 0, 0, 0, 0, 0, 0]
                    ),
                ],
                importedReferences: []
            )
        )
        let wildcardMatcher = makeMatcher([wildcardHeavy])

        XCTAssertEqual(wildcardMatcher.validatedSignatureCount, 0)
        XCTAssertTrue(wildcardMatcher.validationIssues.map(\.reason).contains(.insufficientEvidence))
    }

    func testImportedReferencesDoNotReduceByteEvidenceFloor() {
        let signature = makeSignature(
            name: "referenceCannotSubstituteForBytes",
            prefixMask: mask(exactByteCount: 12),
            checksum: FunctionSignatureChecksumSpan(offset: 32, byteCount: 1, crc32: 0),
            tail: FunctionSignatureCollisionTail(
                byteRuns: [],
                importedReferences: [
                    FunctionSignatureImportedReference(
                        instructionOffset: 40,
                        expectedSymbolName: "_memcpy"
                    ),
                ]
            )
        )
        let matcher = makeMatcher([signature])

        XCTAssertEqual(matcher.validatedSignatureCount, 0)
        XCTAssertTrue(matcher.validationIssues.map(\.reason).contains(.insufficientEvidence))
    }

    func testValidatorRejectsTailRunThatExtendsBeyondFunctionEnd() {
        let signature = makeSignature(
            name: "tailPastEnd",
            tail: FunctionSignatureCollisionTail(
                byteRuns: [
                    FunctionSignatureMaskedByteRun(
                        offset: 60,
                        bytes: Array(repeating: 0xAB, count: 8),
                        comparisonMask: Array(repeating: 0xFF, count: 8)
                    ),
                ],
                importedReferences: []
            )
        )
        let matcher = makeMatcher([signature])

        XCTAssertEqual(matcher.validatedSignatureCount, 0)
        XCTAssertTrue(matcher.validationIssues.map(\.reason).contains(.invalidTailRun))
    }

    func testValidatorRejectsPartiallyWildcardedReferenceInstructionInPrefix() {
        var prefixMask = Array(repeating: UInt8(0xFF), count: 32)
        prefixMask[28] = 0
        prefixMask[29] = 0
        let signature = makeSignature(
            name: "partialReferenceWildcard",
            prefixMask: prefixMask,
            tail: FunctionSignatureCollisionTail(
                byteRuns: [],
                importedReferences: [
                    FunctionSignatureImportedReference(
                        instructionOffset: 28,
                        expectedSymbolName: "_memcpy"
                    ),
                ]
            )
        )
        let matcher = makeMatcher([signature])

        XCTAssertEqual(matcher.validatedSignatureCount, 0)
        XCTAssertTrue(
            matcher.validationIssues.map(\.reason).contains(.overlappingVerificationEvidence)
        )
    }

    func testIndexLookupVisitsDistinctAnchorOffsets() {
        let commonSuffix = Array(UInt8(4)..<UInt8(64))
        let offsetZeroBytes = [UInt8](repeating: 0x11, count: 4) + commonSuffix
        let offsetFourBytes = [UInt8](repeating: 0x22, count: 4) + commonSuffix

        let offsetZero = makeMatchingSignature(
            bytes: offsetZeroBytes,
            name: "offsetZero",
            importedReference: nil
        )
        var offsetFourMask = Array(repeating: UInt8(0xFF), count: 32)
        offsetFourMask.replaceSubrange(0..<4, with: repeatElement(0, count: 4))
        let offsetFour = makeMatchingSignature(
            bytes: offsetFourBytes,
            name: "offsetFour",
            prefixMask: offsetFourMask,
            importedReference: nil
        )
        let matcher = makeMatcher([offsetFour, offsetZero])

        XCTAssertEqual(matcher.validatedSignatureCount, 2)
        XCTAssertEqual(
            matcher.match(
                FunctionSignatureCandidate(
                    architecture: .arm64,
                    bytes: offsetFourBytes,
                    importedReferences: [:]
                )
            ),
            .unique(FunctionSignatureIdentity(name: "offsetFour", libraryName: "compiler-rt"))
        )
    }

    func testSchemaV1Arm64DiscriminantAndFullCollisionTailShapeAreStable() {
        let firstRun = FunctionSignatureMaskedByteRun(
            offset: 40,
            bytes: [0xAA, 0],
            comparisonMask: [0xFF, 0]
        )
        let secondRun = FunctionSignatureMaskedByteRun(
            offset: 44,
            bytes: [0xBB, 0xCC],
            comparisonMask: [0xFF, 0xFF]
        )
        let firstReference = FunctionSignatureImportedReference(
            instructionOffset: 48,
            expectedSymbolName: "_memcpy"
        )
        let secondReference = FunctionSignatureImportedReference(
            instructionOffset: 52,
            expectedSymbolName: "_abort"
        )
        let tail = FunctionSignatureCollisionTail(
            byteRuns: [firstRun, secondRun],
            importedReferences: [firstReference, secondReference]
        )

        XCTAssertEqual(FunctionSignatureArchitecture.arm64.rawValue, 1)
        XCTAssertEqual(tail.byteRuns, [firstRun, secondRun])
        XCTAssertEqual(tail.importedReferences, [firstReference, secondReference])
        XCTAssertEqual(tail.byteRuns[0].offset, 40)
        XCTAssertEqual(tail.byteRuns[0].bytes, [0xAA, 0])
        XCTAssertEqual(tail.byteRuns[0].comparisonMask, [0xFF, 0])
        XCTAssertEqual(tail.importedReferences[1].instructionOffset, 52)
        XCTAssertEqual(tail.importedReferences[1].expectedSymbolName, "_abort")
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
        name: String,
        totalLength: UInt32 = 64,
        prefixMask: [UInt8] = Array(repeating: 0xFF, count: 32),
        checksum: FunctionSignatureChecksumSpan = FunctionSignatureChecksumSpan(
            offset: 32,
            byteCount: 8,
            crc32: 0
        ),
        tail: FunctionSignatureCollisionTail = FunctionSignatureCollisionTail(
            byteRuns: [],
            importedReferences: []
        )
    ) -> FunctionSignature {
        FunctionSignature(
            architecture: .arm64,
            name: name,
            libraryName: "compiler-rt",
            totalLength: totalLength,
            prefix: FunctionSignatureMaskedPattern(
                bytes: prefixMask.map { $0 == 0xFF ? 0xA5 : 0 },
                comparisonMask: prefixMask
            ),
            checksum: checksum,
            collisionTail: tail
        )
    }

    private func makeMatchingSignature(
        bytes: [UInt8],
        name: String = "matched",
        tailOffset: UInt32 = 40,
        prefixMask: [UInt8] = {
            var value = Array(repeating: UInt8(0xFF), count: 32)
            value.replaceSubrange(4..<8, with: repeatElement(0, count: 4))
            return value
        }(),
        importedReference: FunctionSignatureImportedReference? = FunctionSignatureImportedReference(
            instructionOffset: 48,
            expectedSymbolName: "_memcpy"
        )
    ) -> FunctionSignature {
        precondition(bytes.count == 64)
        precondition(prefixMask.count == 32)
        let prefixBytes = zip(bytes.prefix(32), prefixMask).map { byte, mask in
            mask == 0xFF ? byte : 0
        }
        let tailStart = Int(tailOffset)
        return FunctionSignature(
            architecture: .arm64,
            name: name,
            libraryName: "compiler-rt",
            totalLength: UInt32(bytes.count),
            prefix: FunctionSignatureMaskedPattern(
                bytes: prefixBytes,
                comparisonMask: prefixMask
            ),
            checksum: FunctionSignatureChecksumSpan(
                offset: 32,
                byteCount: 8,
                crc32: FunctionSignatureCRC32.checksum(Array(bytes[32..<40]))
            ),
            collisionTail: FunctionSignatureCollisionTail(
                byteRuns: [
                    FunctionSignatureMaskedByteRun(
                        offset: tailOffset,
                        bytes: Array(bytes[tailStart..<(tailStart + 4)]),
                        comparisonMask: Array(repeating: 0xFF, count: 4)
                    ),
                ],
                importedReferences: importedReference.map { [$0] } ?? []
            )
        )
    }

    private func mask(exactByteCount: Int) -> [UInt8] {
        precondition((0...32).contains(exactByteCount))
        return Array(repeating: 0xFF, count: exactByteCount)
            + Array(repeating: 0, count: 32 - exactByteCount)
    }
}
