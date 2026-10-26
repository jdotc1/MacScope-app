import Foundation

struct FunctionSignatureIdentity: Sendable, Hashable {
    let name: String
    let libraryName: String
}

struct FunctionSignatureCandidate: Sendable {
    let architecture: FunctionSignatureArchitecture
    let bytes: [UInt8]
    let importedReferences: [UInt32: String]
}

enum FunctionSignatureMatchResult: Sendable, Equatable {
    case noMatch
    case unique(FunctionSignatureIdentity)
    case ambiguous([FunctionSignatureIdentity])
}

struct FunctionSignaturePrefixIndexKey: Sendable, Hashable {
    let architecture: FunctionSignatureArchitecture
    let anchorOffset: UInt8
    let byte0: UInt8
    let byte1: UInt8
    let byte2: UInt8
    let byte3: UInt8

    static func make(for signature: FunctionSignature) -> Self? {
        let mask = signature.prefix.comparisonMask
        guard signature.prefix.bytes.count == mask.count, mask.count >= 4 else { return nil }
        for offset in stride(from: 0, through: mask.count - 4, by: 4)
        where mask[offset..<(offset + 4)].allSatisfy({ $0 == 0xFF }) {
            guard let anchorOffset = UInt8(exactly: offset) else { return nil }
            return Self(
                architecture: signature.architecture,
                anchorOffset: anchorOffset,
                byte0: signature.prefix.bytes[offset],
                byte1: signature.prefix.bytes[offset + 1],
                byte2: signature.prefix.bytes[offset + 2],
                byte3: signature.prefix.bytes[offset + 3]
            )
        }
        return nil
    }
}

enum FunctionSignatureValidationReason: String, Sendable, Hashable {
    case unsupportedSchemaVersion
    case invalidName
    case invalidLibraryName
    case invalidTotalLength
    case invalidPrefixLength
    case prefixMaskLengthMismatch
    case invalidPrefixMask
    case noncanonicalWildcardByte
    case missingExactAnchor
    case invalidChecksumRange
    case noncanonicalZeroChecksum
    case tooManyTailRuns
    case invalidTailRun
    case tooManyConstrainedTailBytes
    case tooManyImportedReferences
    case invalidImportedReference
    case overlappingVerificationEvidence
    case insufficientEvidence
    case duplicatePredicate
}

struct FunctionSignatureValidationIssue: Sendable, Hashable {
    let identity: FunctionSignatureIdentity?
    let reason: FunctionSignatureValidationReason
}

struct FunctionSignatureMatcher: Sendable {
    static let standard: FunctionSignatureMatcher = FunctionSignatureMatcher(database: FunctionSignatureCorpus.database)

    static let empty = FunctionSignatureMatcher(
        database: FunctionSignatureDatabase(
            schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
            signatures: []
        )
    )

    let validationIssues: [FunctionSignatureValidationIssue]
    let validatedSignatureCount: Int

    var isEmpty: Bool { validatedSignatureCount == 0 }

    private let anchorOffsets: [UInt8]
    private let index: [FunctionSignaturePrefixIndexKey: [FunctionSignature]]

    init(database: FunctionSignatureDatabase) {
        guard database.schemaVersion == FunctionSignatureDatabase.currentSchemaVersion else {
            validationIssues = [
                FunctionSignatureValidationIssue(
                    identity: nil,
                    reason: .unsupportedSchemaVersion
                ),
            ]
            validatedSignatureCount = 0
            anchorOffsets = []
            index = [:]
            return
        }

        var issues: [FunctionSignatureValidationIssue] = []
        var structurallyValid: [FunctionSignature] = []
        for signature in database.signatures {
            let reasons = Self.validationReasons(for: signature)
            if reasons.isEmpty {
                structurallyValid.append(signature)
            } else {
                let identity = FunctionSignatureIdentity(
                    name: signature.name,
                    libraryName: signature.libraryName
                )
                issues.append(contentsOf: reasons.map {
                    FunctionSignatureValidationIssue(identity: identity, reason: $0)
                })
            }
        }

        // Repeated records of the same identity add no evidence. Equal predicates
        // with DIFFERENT identities must survive: match() reports ambiguity rather
        // than silently discarding both names or picking one.
        var seenIdentityPredicates = Set<FunctionSignature>()
        structurallyValid.removeAll { signature in
            guard !seenIdentityPredicates.insert(signature).inserted else { return false }
            issues.append(FunctionSignatureValidationIssue(
                identity: FunctionSignatureIdentity(name: signature.name, libraryName: signature.libraryName),
                reason: .duplicatePredicate
            ))
            return true
        }

        issues.sort(by: Self.issuePrecedes)
        structurallyValid.sort(by: Self.signaturePrecedes)
        var builtIndex: [FunctionSignaturePrefixIndexKey: [FunctionSignature]] = [:]
        var offsets = Set<UInt8>()
        for signature in structurallyValid {
            guard let key = FunctionSignaturePrefixIndexKey.make(for: signature) else { continue }
            builtIndex[key, default: []].append(signature)
            offsets.insert(key.anchorOffset)
        }
        validationIssues = issues
        validatedSignatureCount = structurallyValid.count
        anchorOffsets = offsets.sorted()
        index = builtIndex
    }

    func match(_ candidate: FunctionSignatureCandidate) -> FunctionSignatureMatchResult {
        guard !isEmpty else { return .noMatch }

        var matchingIdentities = Set<FunctionSignatureIdentity>()
        for anchorOffset in anchorOffsets {
            let offset = Int(anchorOffset)
            guard candidate.bytes.count >= offset + 4 else { continue }
            let key = FunctionSignaturePrefixIndexKey(
                architecture: candidate.architecture,
                anchorOffset: anchorOffset,
                byte0: candidate.bytes[offset],
                byte1: candidate.bytes[offset + 1],
                byte2: candidate.bytes[offset + 2],
                byte3: candidate.bytes[offset + 3]
            )
            guard let signatures = index[key] else { continue }
            for signature in signatures where Self.matches(signature, candidate: candidate) {
                matchingIdentities.insert(
                    FunctionSignatureIdentity(
                        name: signature.name,
                        libraryName: signature.libraryName
                    )
                )
            }
        }

        let identities = matchingIdentities.sorted(by: Self.identityPrecedes)
        switch identities.count {
        case 0:
            return .noMatch
        case 1:
            return .unique(identities[0])
        default:
            return .ambiguous(identities)
        }
    }

    private static func validationReasons(
        for signature: FunctionSignature
    ) -> [FunctionSignatureValidationReason] {
        var reasons = Set<FunctionSignatureValidationReason>()

        if !isValidRecordText(signature.name) {
            reasons.insert(.invalidName)
        }
        if !isValidRecordText(signature.libraryName) {
            reasons.insert(.invalidLibraryName)
        }

        let lengthIsValid = signature.totalLength > 0
            && signature.totalLength.isMultiple(of: 4)
            && signature.totalLength <= 1_048_576
        if !lengthIsValid {
            reasons.insert(.invalidTotalLength)
        }

        if lengthIsValid {
            let expectedPrefixLength = signature.totalLength < 32
                ? Int(signature.totalLength)
                : 32
            if signature.prefix.bytes.count != expectedPrefixLength {
                reasons.insert(.invalidPrefixLength)
            }
        }
        if signature.prefix.bytes.count != signature.prefix.comparisonMask.count {
            reasons.insert(.prefixMaskLengthMismatch)
        } else {
            validateMaskedBytes(
                bytes: signature.prefix.bytes,
                mask: signature.prefix.comparisonMask,
                invalidMaskReason: .invalidPrefixMask,
                reasons: &reasons
            )
            if !hasExactAlignedAnchor(signature.prefix.comparisonMask) {
                reasons.insert(.missingExactAnchor)
            }
        }

        let checksumEnd = validatedChecksumEnd(
            signature.checksum,
            prefixLength: signature.prefix.bytes.count,
            totalLength: signature.totalLength,
            reasons: &reasons
        )

        if signature.collisionTail.byteRuns.count > 8 {
            reasons.insert(.tooManyTailRuns)
        }
        var previousRunEnd: UInt32?
        var constrainedTailByteCount: UInt64 = 0
        for run in signature.collisionTail.byteRuns.prefix(9) {
            var runIsValid = !run.bytes.isEmpty
            if run.bytes.count != run.comparisonMask.count {
                runIsValid = false
            } else {
                validateMaskedBytes(
                    bytes: run.bytes,
                    mask: run.comparisonMask,
                    invalidMaskReason: .invalidTailRun,
                    reasons: &reasons
                )
                let exactCount = UInt64(run.comparisonMask.lazy.filter { $0 == 0xFF }.count)
                constrainedTailByteCount = min(
                    constrainedTailByteCount + exactCount,
                    UInt64(signature.totalLength) + 1
                )
                if exactCount == 0 {
                    runIsValid = false
                }
            }

            let runCount = UInt32(exactly: run.bytes.count)
            var runEnd: UInt32?
            if let runCount,
               run.offset <= signature.totalLength,
               runCount <= signature.totalLength - run.offset {
                runEnd = run.offset + runCount
            } else {
                runIsValid = false
            }
            if let checksumEnd, run.offset < checksumEnd {
                runIsValid = false
            }
            if let previousRunEnd, run.offset < previousRunEnd {
                runIsValid = false
            }
            if let runEnd {
                previousRunEnd = runEnd
            }
            if !runIsValid {
                reasons.insert(.invalidTailRun)
            }
        }
        if constrainedTailByteCount > 32 {
            reasons.insert(.tooManyConstrainedTailBytes)
        }

        let references = signature.collisionTail.importedReferences
        if references.count > 8 {
            reasons.insert(.tooManyImportedReferences)
        }
        var previousReferenceOffset: UInt32?
        for reference in references.prefix(9) {
            var referenceIsValid = reference.instructionOffset.isMultiple(of: 4)
                && isValidRecordText(reference.expectedSymbolName)
            if let previousReferenceOffset,
               reference.instructionOffset <= previousReferenceOffset {
                referenceIsValid = false
            }
            previousReferenceOffset = reference.instructionOffset

            guard signature.totalLength >= 4,
                  reference.instructionOffset <= signature.totalLength - 4 else {
                reasons.insert(.invalidImportedReference)
                continue
            }
            if !referenceIsValid {
                reasons.insert(.invalidImportedReference)
            }

            let referenceStart = reference.instructionOffset
            let referenceEnd = referenceStart + 4
            if signature.checksum.byteCount > 0,
               let checksumEnd,
               rangesOverlap(
                    referenceStart,
                    referenceEnd,
                    signature.checksum.offset,
                    checksumEnd
               ) {
                reasons.insert(.overlappingVerificationEvidence)
            }

            for run in signature.collisionTail.byteRuns {
                for (index, mask) in run.comparisonMask.enumerated() where mask == 0xFF {
                    guard let relativeIndex = UInt32(exactly: index),
                          run.offset <= UInt32.max - relativeIndex else {
                        reasons.insert(.invalidTailRun)
                        continue
                    }
                    let byteOffset = run.offset + relativeIndex
                    if byteOffset >= referenceStart && byteOffset < referenceEnd {
                        reasons.insert(.overlappingVerificationEvidence)
                    }
                }
            }

            if lengthIsValid,
               let prefixCount = UInt32(exactly: signature.prefix.comparisonMask.count),
               referenceStart < prefixCount {
                let prefixStart = Int(referenceStart)
                let prefixEnd = min(prefixStart + 4, signature.prefix.comparisonMask.count)
                if signature.prefix.comparisonMask[prefixStart..<prefixEnd].contains(where: { $0 != 0 }) {
                    reasons.insert(.overlappingVerificationEvidence)
                }
            }
        }

        let exactPrefixBytes = UInt64(
            signature.prefix.comparisonMask.prefix(33).lazy.filter { $0 == 0xFF }.count
        )
        let checksumBits = min(UInt64(signature.checksum.byteCount) * 8, 32)
        let evidenceBits = (exactPrefixBytes + constrainedTailByteCount) * 8 + checksumBits
        if evidenceBits < 128 {
            reasons.insert(.insufficientEvidence)
        }

        return reasons.sorted { $0.rawValue < $1.rawValue }
    }

    private static func validateMaskedBytes(
        bytes: [UInt8],
        mask: [UInt8],
        invalidMaskReason: FunctionSignatureValidationReason,
        reasons: inout Set<FunctionSignatureValidationReason>
    ) {
        for (byte, maskByte) in zip(bytes, mask) {
            guard maskByte == 0 || maskByte == 0xFF else {
                reasons.insert(invalidMaskReason)
                continue
            }
            if maskByte == 0 && byte != 0 {
                reasons.insert(.noncanonicalWildcardByte)
            }
        }
    }

    private static func hasExactAlignedAnchor(_ mask: [UInt8]) -> Bool {
        guard mask.count >= 4 else { return false }
        for offset in stride(from: 0, through: mask.count - 4, by: 4)
        where mask[offset..<(offset + 4)].allSatisfy({ $0 == 0xFF }) {
            return true
        }
        return false
    }

    private static func validatedChecksumEnd(
        _ checksum: FunctionSignatureChecksumSpan,
        prefixLength: Int,
        totalLength: UInt32,
        reasons: inout Set<FunctionSignatureValidationReason>
    ) -> UInt32? {
        if checksum.byteCount == 0 {
            guard totalLength <= 32,
                  checksum.offset == totalLength,
                  checksum.crc32 == 0 else {
                reasons.insert(.noncanonicalZeroChecksum)
                return nil
            }
            return checksum.offset
        }

        guard let prefixLength = UInt32(exactly: prefixLength),
              checksum.offset >= prefixLength,
              checksum.offset <= totalLength,
              checksum.byteCount <= totalLength - checksum.offset else {
            reasons.insert(.invalidChecksumRange)
            return nil
        }
        return checksum.offset + checksum.byteCount
    }

    private static func isValidRecordText(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func rangesOverlap(
        _ firstStart: UInt32,
        _ firstEnd: UInt32,
        _ secondStart: UInt32,
        _ secondEnd: UInt32
    ) -> Bool {
        firstStart < secondEnd && secondStart < firstEnd
    }

    private static func issuePrecedes(
        _ lhs: FunctionSignatureValidationIssue,
        _ rhs: FunctionSignatureValidationIssue
    ) -> Bool {
        if lhs.reason.rawValue != rhs.reason.rawValue {
            return lhs.reason.rawValue < rhs.reason.rawValue
        }
        let lhsIdentity = lhs.identity ?? FunctionSignatureIdentity(name: "", libraryName: "")
        let rhsIdentity = rhs.identity ?? FunctionSignatureIdentity(name: "", libraryName: "")
        if lhsIdentity.name != rhsIdentity.name {
            return lhsIdentity.name < rhsIdentity.name
        }
        return lhsIdentity.libraryName < rhsIdentity.libraryName
    }

    private static func identityPrecedes(
        _ lhs: FunctionSignatureIdentity,
        _ rhs: FunctionSignatureIdentity
    ) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.libraryName < rhs.libraryName
    }

    private static func signaturePrecedes(
        _ lhs: FunctionSignature,
        _ rhs: FunctionSignature
    ) -> Bool {
        if lhs.architecture.rawValue != rhs.architecture.rawValue {
            return lhs.architecture.rawValue < rhs.architecture.rawValue
        }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.libraryName != rhs.libraryName { return lhs.libraryName < rhs.libraryName }
        if lhs.totalLength != rhs.totalLength { return lhs.totalLength < rhs.totalLength }
        if lhs.prefix.bytes != rhs.prefix.bytes {
            return lhs.prefix.bytes.lexicographicallyPrecedes(rhs.prefix.bytes)
        }
        if lhs.prefix.comparisonMask != rhs.prefix.comparisonMask {
            return lhs.prefix.comparisonMask.lexicographicallyPrecedes(rhs.prefix.comparisonMask)
        }
        if lhs.checksum.offset != rhs.checksum.offset {
            return lhs.checksum.offset < rhs.checksum.offset
        }
        if lhs.checksum.byteCount != rhs.checksum.byteCount {
            return lhs.checksum.byteCount < rhs.checksum.byteCount
        }
        if lhs.checksum.crc32 != rhs.checksum.crc32 {
            return lhs.checksum.crc32 < rhs.checksum.crc32
        }
        let lhsRuns = lhs.collisionTail.byteRuns
        let rhsRuns = rhs.collisionTail.byteRuns
        for (lhsRun, rhsRun) in zip(lhsRuns, rhsRuns) {
            if lhsRun.offset != rhsRun.offset { return lhsRun.offset < rhsRun.offset }
            if lhsRun.bytes != rhsRun.bytes {
                return lhsRun.bytes.lexicographicallyPrecedes(rhsRun.bytes)
            }
            if lhsRun.comparisonMask != rhsRun.comparisonMask {
                return lhsRun.comparisonMask.lexicographicallyPrecedes(rhsRun.comparisonMask)
            }
        }
        if lhsRuns.count != rhsRuns.count { return lhsRuns.count < rhsRuns.count }
        let lhsReferences = lhs.collisionTail.importedReferences
        let rhsReferences = rhs.collisionTail.importedReferences
        for (lhsReference, rhsReference) in zip(lhsReferences, rhsReferences) {
            if lhsReference.instructionOffset != rhsReference.instructionOffset {
                return lhsReference.instructionOffset < rhsReference.instructionOffset
            }
            if lhsReference.expectedSymbolName != rhsReference.expectedSymbolName {
                return lhsReference.expectedSymbolName < rhsReference.expectedSymbolName
            }
        }
        return lhsReferences.count < rhsReferences.count
    }

    private static func matches(
        _ signature: FunctionSignature,
        candidate: FunctionSignatureCandidate
    ) -> Bool {
        guard signature.architecture == candidate.architecture,
              let candidateLength = UInt32(exactly: candidate.bytes.count),
              candidateLength == signature.totalLength,
              matchesMaskedBytes(
                expected: signature.prefix.bytes,
                mask: signature.prefix.comparisonMask,
                candidate: candidate.bytes,
                offset: 0
              ) else {
            return false
        }

        if signature.checksum.byteCount > 0 {
            let checksumStart = Int(signature.checksum.offset)
            let checksumEnd = checksumStart + Int(signature.checksum.byteCount)
            guard checksumEnd <= candidate.bytes.count,
                  FunctionSignatureCRC32.checksum(
                    Array(candidate.bytes[checksumStart..<checksumEnd])
                  ) == signature.checksum.crc32 else {
                return false
            }
        }

        for run in signature.collisionTail.byteRuns {
            guard matchesMaskedBytes(
                expected: run.bytes,
                mask: run.comparisonMask,
                candidate: candidate.bytes,
                offset: Int(run.offset)
            ) else {
                return false
            }
        }

        for reference in signature.collisionTail.importedReferences {
            guard candidate.importedReferences[reference.instructionOffset]
                    == reference.expectedSymbolName else {
                return false
            }
        }
        return true
    }

    private static func matchesMaskedBytes(
        expected: [UInt8],
        mask: [UInt8],
        candidate: [UInt8],
        offset: Int
    ) -> Bool {
        guard offset >= 0,
              expected.count == mask.count,
              offset <= candidate.count,
              expected.count <= candidate.count - offset else {
            return false
        }
        for index in expected.indices
        where (candidate[offset + index] & mask[index]) != expected[index] {
            return false
        }
        return true
    }
}

private struct FunctionSignaturePredicate: Hashable {
    let architecture: FunctionSignatureArchitecture
    let totalLength: UInt32
    let prefix: FunctionSignatureMaskedPattern
    let checksum: FunctionSignatureChecksumSpan
    let collisionTail: FunctionSignatureCollisionTail

    init(_ signature: FunctionSignature) {
        architecture = signature.architecture
        totalLength = signature.totalLength
        prefix = signature.prefix
        checksum = signature.checksum
        collisionTail = signature.collisionTail
    }
}
