import Foundation
import SwiftUI

struct PatternPaneFrame: Equatable { // NEW
    let publication: PatternPublicationEpoch
    let workspaceID: UUID
    let slot: ImageSlot
    let owner: UUID?
    let window: Range<Int>
    let bytes: Data
    let patchedOffsets: Set<Int>
    let mappings: [FileAddressMapping]
    @MainActor
    static func read(_ store: WorkspaceStore) -> Self {
        let window = store.hexWindowRange()
        let rendered = store.patchedHexWindow()
        return Self(publication: store.patternPublicationEpoch, workspaceID: store.workspaceID, slot: store.focusedImageSlot,
                    owner: store.focusedBinary?.id, window: window,
                    bytes: rendered.bytes, patchedOffsets: rendered.patchedOffsets, mappings: store.hexWindowMappings)
    }
}

@MainActor
struct PatternAppCapture { // NEW; supersedes packet app-only capture implementation
    let frame: PatternPaneFrame
    let record: Range<Int>
    let sourceIdentity: String
    let request: PatternInterpretationRequest
    init(frame: PatternPaneFrame, record: Range<Int>, source: String,
         sourceIdentity: String) throws {
        guard let owner = frame.owner, frame.window.lowerBound >= 0,
              frame.bytes.count == frame.window.count,
              record.lowerBound >= 0, !record.isEmpty,
              record.upperBound <= frame.bytes.count else {
            throw PatternInterpretationError.invalidRequest
        }
        let (offset, overflow) = UInt64(frame.window.lowerBound)
            .addingReportingOverflow(UInt64(record.lowerBound))
        guard !overflow else { throw PatternInterpretationError.invalidRequest }
        let bytes = frame.bytes.subdata(in: record)
        let key = PatternInterpretationKey(imageIdentity: owner.uuidString,
            byteSnapshotID: UUID(), patternIdentity: sourceIdentity,
            selectionImageOffset: offset, selectionByteCount: UInt64(bytes.count))
        let request = PatternInterpretationRequest(requestID: UUID(), key: key,
                                                  bytes: bytes, source: source)
        try request.validate()
        self.frame = frame; self.record = record
        self.sourceIdentity = sourceIdentity; self.request = request
    }
    func current(frame: PatternPaneFrame, record: Range<Int>, source: String,
                 sourceIdentity: String) -> Bool {
        self.frame == frame && self.record == record && self.sourceIdentity == sourceIdentity
            && request.source == source
    }
    func reveal(fieldID: UInt64, admitted: ValidatedPatternInterpretation,
                frame: PatternPaneFrame, record: Range<Int>, source: String,
                sourceIdentity: String) -> Range<Int>? {
        guard current(frame: frame, record: record, source: source, sourceIdentity: sourceIdentity),
              admitted.reply.key == request.key,
              admitted.reply.requestID == request.requestID.uuidString,
              let node = admitted.reply.nodes.first(where: { $0.id == fieldID }),
              node.backing == .file, node.kind != .unsupported,
              node.ranges.count == 1, let r = node.ranges.first,
              r.length > 0, r.selectionOffset <= UInt64(record.count),
              r.length <= UInt64(record.count) - r.selectionOffset else { return nil }
        // Count <= window bytes; UInt64-to-Int conversion is now bounded by an Int count.
        let lower = record.lowerBound + Int(r.selectionOffset)
        let range = lower..<(lower + Int(r.length))
        var previous: UInt64?
        for offset in range {
            guard let address = FileAddressMapping.resolvedVirtualAddress(
                    forFileOffset: UInt64(offset), in: frame.mappings),
                  FileAddressMapping.resolvedFileOffset(forVirtualAddress: address,
                    in: frame.mappings) == UInt64(offset) else { return nil }
            if let previous {
                let (next, overflow) = previous.addingReportingOverflow(1)
                guard !overflow, next == address else { return nil }
            }
            previous = address
        }
        return range
    }
}

final class PatternPublicationEpoch: Equatable {
    static func == (lhs: PatternPublicationEpoch, rhs: PatternPublicationEpoch) -> Bool { lhs === rhs }
}

struct PatternRevealCommand: Equatable {
    let range: Range<Int>
    let token: UUID
}
