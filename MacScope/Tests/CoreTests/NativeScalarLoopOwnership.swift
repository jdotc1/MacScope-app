import Foundation

/// Optional native scalar ownership refinement for the independent source-edge audit.
/// The captured-call default analyzer does not call this. The inputs are only
/// actual parsed text, literal original CFG and actual source-owned AST anchors.
/// SOURCE ONLY / NOT RUN. Exact membership, not “one or more enclosing loops”.
enum NativeScalarLoopOwnership {
    typealias C = OrdinaryC
    typealias L = OrdinaryCSourceEdgeLedger
    struct Binding {
        let headers: [C.Span: Int]
        let membersByHeader: [Int: Set<Int>]
        let representedMembersByLoop: [C.Span: Set<Int>]
        func owns(_ edge: C.SourceEdge, span: C.Span) -> Bool { headers[span] == edge.toBlock }
        func innermost(containing span: C.Span) -> C.Span? {
            headers.keys.filter { NativeScalarLoopOwnership.contains($0, span) }
                .min { ($0.last - $0.first) < ($1.last - $1.first) }
        }
    }

    static func bind(candidate: C.Program, source: L.Source, anchors: [Int: Int], loops: [C.Span]) throws -> Binding {
        let represented = Set(anchors.values)
        var members: [Int: Set<Int>] = [:]
        for (edge, blocks) in source.naturalLoops { members[edge.toBlock, default: []].formUnion(blocks) }
        var mapping: [C.Span: Int] = [:], visibleByLoop: [C.Span: Set<Int>] = [:]
        for loop in loops {
            let contained = anchors.keys.filter { contains(loop, candidate.code[$0].span) }
            let visible = Set(contained.compactMap { anchors[$0] })
            let candidates = members.keys.filter { header in
                let expected = members[header, default: []].intersection(represented)
                guard visible == expected, visible.contains(header) else { return false }
                // An inner backedge cannot justify an enclosing wrapper. The
                // actual header must be represented. A missing latch is allowed
                // only for a literal B-only forwarder, retained in full routes.
                return source.backedges.contains { edge in
                    edge.toBlock == header && visible.contains(edge.toBlock) &&
                    (visible.contains(edge.fromBlock) || (!represented.contains(edge.fromBlock) &&
                        source.blocks[edge.fromBlock].rows.allSatisfy { source.rows[$0].mnemonic == "b" }))
                }
            }
            guard candidates.count == 1, let header = candidates.first,
                  !mapping.values.contains(header), mapping[loop] == nil else {
                throw C.Failure.invalidContract("native loop lacks one injective original header/member binding")
            }
            mapping[loop] = header; visibleByLoop[loop] = visible
        }
        guard Set(mapping.values) == Set(members.keys) else {
            throw C.Failure.invalidContract("original natural-loop header has no bound actual lexical loop")
        }
        for outer in loops {
            for inner in loops where inner != outer {
                guard let outerHeader = mapping[outer], let innerHeader = mapping[inner],
                      let outerMembers = members[outerHeader], let innerMembers = members[innerHeader] else {
                    throw C.Failure.invalidContract("missing independent loop binding")
                }
                let lexicalNested = contains(outer, inner)
                let sourceNested = innerMembers.isStrictSubset(of: outerMembers)
                guard lexicalNested == sourceNested else {
                    throw C.Failure.invalidContract("native lexical loop nesting contradicts literal natural-loop membership")
                }
                if !lexicalNested && !contains(inner, outer), !outerMembers.isDisjoint(with: innerMembers) {
                    throw C.Failure.invalidContract("overlapping literal loops cannot be represented as disjoint lexical loops")
                }
            }
        }
        return .init(headers: mapping, membersByHeader: members, representedMembersByLoop: visibleByLoop)
    }
    static func contains(_ outer: C.Span, _ inner: C.Span) -> Bool {
        outer.first <= inner.first && outer.last >= inner.last
    }
}
