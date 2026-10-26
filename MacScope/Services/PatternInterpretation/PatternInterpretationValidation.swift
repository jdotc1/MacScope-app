import Foundation

// Evaluated synchronously by the app owner from its current capture and request state.
// Clear activeRequestID before cancellation. isCurrent must compare live bytes,
// source, workspace, selection and owner; equality of retained keys is insufficient.
struct PatternInterpretationLiveCapture {
    var currentKey: PatternInterpretationKey
    var activeRequestID: UUID?
    var isCurrent: Bool
}

// Shared app-owned validation. No PatternLanguage imports or pointers.
// This belongs to MacScopeAnalysisCore, not the native service module.
struct ValidatedPatternInterpretation: Sendable {
    let reply: PatternInterpretationReply
    private init(reply: PatternInterpretationReply) { self.reply = reply }

    @MainActor
    static func decode(_ data: Data, for request: PatternInterpretationRequest,
                       liveCapture: () -> PatternInterpretationLiveCapture) throws -> Self {
        try requireCurrent(key: request.key, requestID: request.requestID.uuidString,
                           liveCapture: liveCapture)
        let validated = try decodeForWorker(data, for: request)
        try requireCurrent(key: request.key, requestID: request.requestID.uuidString,
                           liveCapture: liveCapture)
        return validated
    }

    // Worker-side structural validation only; this is not app publication authority.
    // The app must use decode(_:for:liveCapture:) before publishing the reply.
    static func decodeForWorker(_ data: Data, for request: PatternInterpretationRequest) throws -> Self {
        try request.validate()
        guard data.count <= 4_194_304 else { throw PatternInterpretationError.malformedReply }
        let reply = try JSONDecoder().decode(PatternInterpretationReply.self, from: data)
        guard reply.schemaVersion == 1,
              reply.engineCommit == "300d7388475dd7ffd04239dfc889b72fe08bae18",
              reply.requestID == request.requestID.uuidString,
              reply.key == request.key
        else { throw PatternInterpretationError.malformedReply }
        guard reply.nodes.count <= request.maximumNodes, reply.diagnostics.count <= 64
        else { throw PatternInterpretationError.malformedReply }

        if reply.status != .completed && reply.status != .partial {
            guard reply.nodes.isEmpty else { throw PatternInterpretationError.malformedReply }
        }
        var parents: [UInt64: PatternField] = [:]
        var actualChildren: [UInt64: UInt64] = [:]
        let containers: Set<PatternField.Kind> = [.array, .bitfieldArray, .bitfield, .struct, .union]
        let allowedFlags: Set<String> = ["valueUnsupported", "customFormattingNotApplied", "valuePreview"]
        for (index, field) in reply.nodes.enumerated() {
            guard field.id == UInt64(index + 1),
                  field.depth <= UInt32(request.maximumDepth),
                  boundedASCII(field.name, 128), boundedASCII(field.typeName, 128),
                  boundedASCII(field.value, 256),
                  field.flags.count <= 3, Set(field.flags).count == field.flags.count,
                  field.flags.allSatisfy(allowedFlags.contains),
                  field.ranges.count <= 1
            else { throw PatternInterpretationError.malformedReply }
            if let parentID = field.parentID {
                guard let parent = parents[parentID], containers.contains(parent.kind),
                      field.depth == parent.depth + 1
                else { throw PatternInterpretationError.malformedReply }
                actualChildren[parentID, default: 0] += 1
            } else {
                guard field.depth == 0 else { throw PatternInterpretationError.malformedReply }
            }
            guard containers.contains(field.kind) || (field.childCount == 0 && !field.childrenTruncated)
            else { throw PatternInterpretationError.malformedReply }
            if let bits = field.bits {
                guard [.bitfield, .bitfieldArray, .bitfieldField].contains(field.kind),
                      bits.offsetWithinFirstByte < 8
                else { throw PatternInterpretationError.malformedReply }
            }

            if field.kind == .unsupported {
                guard field.backing == .unsupported, reply.status == .partial, field.ranges.isEmpty
                else { throw PatternInterpretationError.malformedReply }
            }
            switch field.backing {
            case .file:
                guard field.sectionID == 0, field.kind != .unsupported,
                      field.ranges.count == 1, let range = field.ranges.first,
                      range.length > 0, range.selectionOffset == field.patternOffset,
                      contained(range, in: request.key.selectionByteCount)
                else { throw PatternInterpretationError.malformedReply }
                if let bits = field.bits {
                    guard bits.count > 0,
                          bits.count <= request.key.selectionByteCount * 8,
                          range.length == bits.count / 8 + (bits.count % 8 + bits.offsetWithinFirstByte + 7) / 8
                    else { throw PatternInterpretationError.malformedReply }
                } else {
                    guard range.length == field.declaredSize
                    else { throw PatternInterpretationError.malformedReply }
                }
            case .synthetic:
                guard field.sectionID != 0, field.ranges.isEmpty
                else { throw PatternInterpretationError.malformedReply }
            case .empty:
                guard field.sectionID == 0, field.ranges.isEmpty,
                      field.patternOffset <= request.key.selectionByteCount,
                      field.bits.map({ $0.count == 0 }) ?? (field.declaredSize == 0),
                      declaredSpanIsContained(field, in: request.key.selectionByteCount)
                else { throw PatternInterpretationError.malformedReply }
            case .outOfRange:
                guard field.sectionID == 0, field.ranges.isEmpty, reply.status == .partial,
                      !declaredSpanIsContained(field, in: request.key.selectionByteCount)
                else { throw PatternInterpretationError.malformedReply }
            case .unsupported:
                guard field.kind == .unsupported, field.ranges.isEmpty, reply.status == .partial
                else { throw PatternInterpretationError.malformedReply }
            }
            if field.childrenTruncated || !field.flags.isEmpty {
                guard reply.status == .partial else { throw PatternInterpretationError.malformedReply }
            }
            parents[field.id] = field
        }
        for field in reply.nodes {
            let actual = actualChildren[field.id, default: 0]
            if field.kind == .array || field.kind == .bitfieldArray {
                guard actual <= UInt64(request.maximumArrayChildren)
                else { throw PatternInterpretationError.malformedReply }
            }
            guard actual <= field.childCount,
                  field.childrenTruncated || actual == field.childCount
            else { throw PatternInterpretationError.malformedReply }
        }
        for diagnostic in reply.diagnostics {
            guard boundedASCII(diagnostic.code, 64), boundedASCII(diagnostic.message, 256),
                  diagnostic.fieldID.map({ parents[$0] != nil }) ?? true
            else { throw PatternInterpretationError.malformedReply }
        }
        return .init(reply: reply)
    }

    // Call again at selection time: a previously validated result can become stale
    // after a patch, workspace switch, resource change, or pattern edit.
    @MainActor
    func imageByteRanges(for fieldID: UInt64,
                         liveCapture: () -> PatternInterpretationLiveCapture) throws -> [Range<UInt64>] {
        try Self.requireCurrent(key: reply.key, requestID: reply.requestID, liveCapture: liveCapture)
        guard let node = reply.nodes.first(where: { $0.id == fieldID }) else {
            throw PatternInterpretationError.malformedReply
        }
        return try node.ranges.map { range in
            let (lower, overflow1) = reply.selectionImageOffset.addingReportingOverflow(range.selectionOffset)
            let (upper, overflow2) = lower.addingReportingOverflow(range.length)
            guard !overflow1, !overflow2 else { throw PatternInterpretationError.malformedReply }
            return lower..<upper
        }
    }

    // Includes ancestors/overlapping union members; the UI may choose deepest first.
    // The 4096-node cap makes a one-shot linear scan appropriate for MVP.
    @MainActor
    func fields(overlapping selectionOffset: UInt64,
                liveCapture: () -> PatternInterpretationLiveCapture) throws -> [PatternField] {
        try Self.requireCurrent(key: reply.key, requestID: reply.requestID, liveCapture: liveCapture)
        return reply.nodes.filter { field in
            field.ranges.contains { range in
                selectionOffset >= range.selectionOffset
                    && selectionOffset - range.selectionOffset < range.length
            }
        }.sorted { $0.depth > $1.depth }
    }

    @MainActor
    private static func requireCurrent(key: PatternInterpretationKey, requestID: String,
                                       liveCapture: () -> PatternInterpretationLiveCapture) throws {
        let live = liveCapture()
        guard live.isCurrent, live.currentKey == key,
              live.activeRequestID?.uuidString == requestID
        else { throw PatternInterpretationError.staleReply }
    }

    // Mirrors native byte/bit containment, including valid zero-width locations.
    // Request validation caps total at 1 MiB before this helper is reached.
    private static func declaredSpanIsContained(_ field: PatternField, in total: UInt64) -> Bool {
        guard field.patternOffset <= total else { return false }
        if let bits = field.bits {
            let remainingBits = (total - field.patternOffset) * 8
            return bits.offsetWithinFirstByte <= remainingBits
                && bits.count <= remainingBits - bits.offsetWithinFirstByte
        }
        return field.declaredSize <= total - field.patternOffset
    }

    private static func contained(_ range: PatternField.BackedRange, in total: UInt64) -> Bool {
        range.selectionOffset <= total && range.length <= total - range.selectionOffset
    }
    private static func boundedASCII(_ text: String, _ maximum: Int) -> Bool {
        text.utf8.count <= maximum && text.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }
}

