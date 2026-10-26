import Foundation

enum NativeDecompilerDocumentMappingState: Equatable, Sendable {
    case verified
    case degraded(NativeDecompilerDocumentMappingDegradation)
}

enum NativeDecompilerDocumentMappingDegradation: String, Equatable, Sendable {
    case invalidCoordinate
    case visibleTextMismatch
    case overlappingRanges
    case duplicateRange
    case ambiguousRange
}

struct NativeDecompilerDocumentTokenRun: Equatable, Sendable {
    let tokenID: String
    let scalarOffset: Int
    let scalarLength: Int
    let kind: NativeDecompilerWireTokenKind
    let sourceRanges: [NativeDecompilerWireSourceRange]
    let entityReferences: [NativeDecompilerWireTokenEntityReference]
}

struct NativeDecompilerDocumentProjection: Equatable, Sendable {
    let text: String
    let isComplete: Bool
    let isTruncated: Bool
    let mappingState: NativeDecompilerDocumentMappingState
    let tokenRuns: [NativeDecompilerDocumentTokenRun]

    /// Schema-v3 semantic validation accepts only canonical C documents before projection.
    var language: String { "c" }
}

enum NativeDecompilerDocumentProjector {
    static func project(
        document: NativeDecompilerWirePseudocodeDocument,
        tokens: [NativeDecompilerWirePseudocodeTokenRecord],
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> NativeDecompilerDocumentProjection {
        try checkCancellation(isCancelled)

        let scalarIndex = ScalarLineIndex(text: document.text)
        try checkCancellation(isCancelled)

        var mapped: [MappedToken] = []
        mapped.reserveCapacity(tokens.count)

        for token in tokens {
            try checkCancellation(isCancelled)

            switch scalarIndex.resolve(token: token, isTruncated: document.isTruncated) {
            case .omittedBeyondVisiblePrefix:
                continue
            case let .degraded(reason):
                return try degraded(
                    document: document,
                    reason: reason,
                    isCancelled: isCancelled
                )
            case let .mapped(offset, length):
                mapped.append(MappedToken(
                    run: NativeDecompilerDocumentTokenRun(
                        tokenID: token.id,
                        scalarOffset: offset,
                        scalarLength: length,
                        kind: token.kind,
                        sourceRanges: token.sourceRanges,
                        entityReferences: token.entityReferences
                    ),
                    endOffset: offset + length
                ))
            }
        }

        mapped.sort {
            if $0.run.scalarOffset != $1.run.scalarOffset {
                return $0.run.scalarOffset < $1.run.scalarOffset
            }
            if $0.endOffset != $1.endOffset {
                return $0.endOffset < $1.endOffset
            }
            return $0.run.tokenID < $1.run.tokenID
        }

        for index in mapped.indices.dropFirst() {
            let previous = mapped[mapped.index(before: index)]
            let current = mapped[index]
            if current.run.scalarOffset == previous.run.scalarOffset {
                let reason: NativeDecompilerDocumentMappingDegradation =
                    current.endOffset == previous.endOffset ? .duplicateRange : .ambiguousRange
                return try degraded(
                    document: document,
                    reason: reason,
                    isCancelled: isCancelled
                )
            }
            if current.run.scalarOffset < previous.endOffset {
                return try degraded(
                    document: document,
                    reason: .overlappingRanges,
                    isCancelled: isCancelled
                )
            }
        }

        try checkCancellation(isCancelled)
        return NativeDecompilerDocumentProjection(
            text: document.text,
            isComplete: document.isComplete,
            isTruncated: document.isTruncated,
            mappingState: .verified,
            tokenRuns: mapped.map(\.run)
        )
    }

    private static func degraded(
        document: NativeDecompilerWirePseudocodeDocument,
        reason: NativeDecompilerDocumentMappingDegradation,
        isCancelled: @Sendable () -> Bool
    ) throws -> NativeDecompilerDocumentProjection {
        try checkCancellation(isCancelled)
        return NativeDecompilerDocumentProjection(
            text: document.text,
            isComplete: document.isComplete,
            isTruncated: document.isTruncated,
            mappingState: .degraded(reason),
            tokenRuns: []
        )
    }

    private static func checkCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }
}

private extension NativeDecompilerDocumentProjector {
    struct MappedToken {
        let run: NativeDecompilerDocumentTokenRun
        let endOffset: Int
    }

    struct ScalarLineIndex {
        let scalars: [Unicode.Scalar]
        let lineStarts: [Int]

        init(text: String) {
            var indexedScalars: [Unicode.Scalar] = []
            var starts = [0]
            for scalar in text.unicodeScalars {
                indexedScalars.append(scalar)
                if scalar == "\n" {
                    starts.append(indexedScalars.count)
                }
            }
            scalars = indexedScalars
            lineStarts = starts
        }

        func resolve(
            token: NativeDecompilerWirePseudocodeTokenRecord,
            isTruncated: Bool
        ) -> Resolution {
            guard token.line > 0, token.column > 0 else {
                return .degraded(.invalidCoordinate)
            }

            let lineIndex = Int(token.line - 1)
            guard lineIndex < lineStarts.count else {
                return isTruncated
                    ? .omittedBeyondVisiblePrefix
                    : .degraded(.invalidCoordinate)
            }

            let lineStart = lineStarts[lineIndex]
            let nextLineStart = lineIndex + 1 < lineStarts.count
                ? lineStarts[lineIndex + 1]
                : scalars.count
            var lineContentEnd = nextLineStart
            if lineIndex + 1 < lineStarts.count,
               lineContentEnd > lineStart,
               scalars[lineContentEnd - 1] == "\n" {
                lineContentEnd -= 1
                if lineContentEnd > lineStart, scalars[lineContentEnd - 1] == "\r" {
                    lineContentEnd -= 1
                }
            }
            let columnOffset = Int(token.column - 1)
            let (offset, overflowed) = lineStart.addingReportingOverflow(columnOffset)
            guard !overflowed else {
                return .degraded(.invalidCoordinate)
            }

            guard offset < lineContentEnd, offset < scalars.count else {
                if isTruncated && lineIndex == lineStarts.count - 1 && offset >= scalars.count {
                    return .omittedBeyondVisiblePrefix
                }
                return .degraded(.invalidCoordinate)
            }

            let tokenScalars = Array(token.text.unicodeScalars)
            guard !tokenScalars.isEmpty else {
                return .degraded(.ambiguousRange)
            }
            let (endOffset, endOverflowed) = offset.addingReportingOverflow(tokenScalars.count)
            guard !endOverflowed else {
                return .degraded(.invalidCoordinate)
            }
            guard endOffset <= scalars.count else {
                return isTruncated
                    ? .omittedBeyondVisiblePrefix
                    : .degraded(.invalidCoordinate)
            }
            guard endOffset <= lineContentEnd else {
                return .degraded(.invalidCoordinate)
            }
            guard scalars[offset..<endOffset].elementsEqual(tokenScalars) else {
                return .degraded(.visibleTextMismatch)
            }
            return .mapped(offset: offset, length: tokenScalars.count)
        }
    }

    enum Resolution {
        case mapped(offset: Int, length: Int)
        case omittedBeyondVisiblePrefix
        case degraded(NativeDecompilerDocumentMappingDegradation)
    }
}
