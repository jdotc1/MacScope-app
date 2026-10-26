import Foundation
import CryptoKit

/// SOURCE_ONLY / NOT_RUN. These two immutable line/source inventories were read
/// from the retained ORIGINAL document reflection, not a new render, the rejected
/// labelled dialect, a candidate source-PC log, or a production certificate.
/// Up8/up12/skip deliberately have no mapping: their original document-line
/// reflection has not been located. Generic CFG roles cannot fill that gap.
enum OrdinaryCBaselineTransferOrigins {
    private typealias C = OrdinaryC
    typealias Ledger = OrdinaryCSourceEdgeLedger
    enum Kind: Hashable { case goto, branchHelper, conditionalBranchHelper }
    struct Entry {
        let line: Int
        let sourceRow: Int
        let kind: Kind
        let role: Ledger.Role
        let target: UInt64
    }
    struct FrozenMapping {
        let start: UInt64
        let metadataRelativePath: String
        let metadataSHA256: String
        let baselineTextSHA256: String
        let originalGotoCount: Int
        let originalUnconditionalHelperCount: Int
        let originalConditionalHelperCount: Int
        var originalBranchHelperCount: Int { originalUnconditionalHelperCount + originalConditionalHelperCount }
        fileprivate let records: String
        init(start: UInt64, metadataRelativePath: String, metadataSHA256: String,
                         baselineTextSHA256: String, gotos: Int, helpers: Int, conditionalHelpers: Int = 0, records: String) {
            self.start = start; self.metadataRelativePath = metadataRelativePath
            self.metadataSHA256 = metadataSHA256; self.baselineTextSHA256 = baselineTextSHA256
            originalGotoCount = gotos; originalUnconditionalHelperCount = helpers
            originalConditionalHelperCount = conditionalHelpers; self.records = records
        }
    }
    /// A retained printed site has its own identity even when two historical
    /// spellings observe the same physical guard-taken route.
    struct Binding: Hashable {
        let line: Int
        let sourceRow: Int
        let kind: Kind
        let role: Ledger.Role
        let target: UInt64
        let origin: Ledger.Origin
    }
    struct BoundMapping {
        let frozen: FrozenMapping
        let bindings: [Binding]
    }
    struct ResidualSlot {
        let span: OrdinaryC.Span
        let originalGotoOrigins: Set<Binding>
        let originalBranchHelperOrigins: Set<Binding>
        let otherTopologyOrigins: Set<Ledger.Origin>
    }
    struct Accounting {
        let originalGotoCount: Int
        let originalUnconditionalHelperCount: Int
        let originalConditionalHelperCount: Int
        var originalBranchHelperCount: Int { originalUnconditionalHelperCount + originalConditionalHelperCount }
        let actualPrintedGotoCount: Int
        let structuredOriginalGotoOrigins: Set<Binding>
        let residualOriginalGotoOrigins: Set<Binding>
        let unresolvedOriginalGotoOrigins: Set<Binding>
        let residualSlots: [ResidualSlot]
        let topologyGaps: [Ledger.Gap]
        // Structural accounting only. Separate numerical execution and complete
        // observed edge checks are still prerequisites for semantic acceptance.
        func requireComplete() throws {
            guard topologyGaps.isEmpty, unresolvedOriginalGotoOrigins.isEmpty else {
                throw OrdinaryC.Failure.invalidContract("BASELINE_ORIGIN_ACCOUNTING_INCOMPLETE")
            }
        }
    }
    static let missingOriginalMetadata: [UInt64] = [0x3ae18,0x3b774,0x33418]

    static func bind(_ mapping: FrozenMapping, baselineText: String, source: Ledger.Source) throws -> BoundMapping {
        guard source.rows.first?.address == mapping.start,
              SHA256.hash(data:Data(baselineText.utf8)).map({ String(format:"%02x",$0) }).joined() == mapping.baselineTextSHA256 else {
            throw C.Failure.invalidContract("baseline identity differs from original retained document reflection")
        }
        let entries = try mapping.records.split(separator:"\n").map { record -> Entry in
            let fields = record.split(separator:"|").map(String.init)
            guard fields.count == 5, let line = Int(fields[0]), let row = Int(fields[1]),
                  ["G","H","Q"].contains(fields[2]), fields[4].hasPrefix("0x"),
                  let target = UInt64(fields[4].dropFirst(2),radix:16) else { throw C.Failure.invalidContract("malformed frozen baseline record") }
            let role: Ledger.Role
            switch fields[3] {
            case "T": role = .taken
            case "U": role = .unconditional
            case "D": role = .tableDefault
            default:
                guard fields[3].hasPrefix("C"), let ordinal = Int(fields[3].dropFirst()), (0..<10).contains(ordinal) else {
                    throw C.Failure.invalidContract("unknown frozen baseline role")
                }
                role = .tableCase(ordinal)
            }
            return .init(line:line,sourceRow:row,kind:fields[2] == "G" ? .goto : fields[2] == "H" ? .branchHelper : .conditionalBranchHelper,role:role,target:target)
        }
        guard Set(entries.map(\.line)).count == entries.count,
              entries.filter({ $0.kind == .goto }).count == mapping.originalGotoCount,
              entries.filter({ $0.kind == .branchHelper }).count == mapping.originalUnconditionalHelperCount,
              entries.filter({ $0.kind == .conditionalBranchHelper }).count == mapping.originalConditionalHelperCount else {
            throw C.Failure.invalidContract("frozen baseline denominator inventory drift")
        }
        let tokens = try C.lex(baselineText)
        let sites = tokens.indices.filter { tokens[$0].text == "goto" || tokens[$0].text == "__branch" || tokens[$0].text.hasPrefix("__branch_") }
        guard sites.count == entries.count else { throw C.Failure.invalidContract("unmapped original printed transfer") }
        var matchedEntries: [Entry] = []
        for index in sites {
            let token = tokens[index], kind: Kind
            switch token.text {
            case "goto": kind = .goto
            case "__branch": kind = .branchHelper
            case "__branch_eq": kind = .conditionalBranchHelper
            default: throw C.Failure.invalidContract("unmapped original conditional branch helper")
            }
            let matches = entries.filter { $0.line == token.line && $0.kind == kind }
            let targetIndex = index + (kind == .goto ? 1 : 2)
            guard matches.count == 1, tokens.indices.contains(targetIndex),
                  (kind == .goto || tokens[index + 1].text == "("),
                  try C.literal(tokens[targetIndex].text).bits == matches[0].target else {
                throw C.Failure.invalidContract("baseline transfer token/line/target differs from frozen source binding")
            }
            matchedEntries.append(matches[0])
        }
        return .init(frozen:mapping,bindings:try bindTransfers(matchedEntries, source:source))
    }

    static func bindTransfers(_ entries: [Entry], source: Ledger.Source) throws -> [Binding] {
        let bindings = try entries.map { entry -> Binding in
            let origins = source.origins.filter { origin in
                let direct = origin.row == entry.sourceRow && origin.role == entry.role
                let guardTaken = entry.kind == .goto && entry.role == .taken &&
                    origin.role == .tableDefault &&
                    source.dispatches[origin.row]?.guardRow == entry.sourceRow &&
                    verifiedDefaultOrigin(origin, source:source)
                return (direct || guardTaken) &&
                    source.rows[source.blocks[origin.edge.toBlock].rows.lowerBound].address == entry.target
            }
            guard origins.count == 1, let origin = origins.first else {
                throw C.Failure.invalidContract("baseline transfer has no unique independent literal origin")
            }
            return .init(line:entry.line,sourceRow:entry.sourceRow,kind:entry.kind,
                         role:entry.role,target:entry.target,origin:origin)
        }
        try requireUniqueOrigins(bindings, source:source)
        return bindings
    }

    private static func verifiedDefaultOrigin(_ origin: Ledger.Origin, source: Ledger.Source) -> Bool {
        guard origin.role == .tableDefault, let dispatch = source.dispatches[origin.row],
              dispatch.row == origin.row, source.rows.indices.contains(dispatch.row),
              source.rows[dispatch.row].mnemonic == "br",
              source.rows.indices.contains(dispatch.guardRow),
              source.rows.indices.contains(dispatch.defaultRow),
              source.rows[dispatch.guardRow].mnemonic == "b.hi",
              source.branchTargets[dispatch.guardRow] == dispatch.defaultRow,
              source.blockAtRow[dispatch.guardRow] == origin.edge.fromBlock,
              source.blockAtRow[dispatch.defaultRow] == origin.edge.toBlock else { return false }
        let literal = source.rows[dispatch.guardRow].operands.trimmingCharacters(in:.whitespaces)
        return literal.hasPrefix("0x") && UInt64(literal.dropFirst(2),radix:16) == source.rows[dispatch.defaultRow].address
    }

    static func requireUniqueOrigins(_ bindings: [Binding], source: Ledger.Source) throws {
        for (origin, group) in Dictionary(grouping:bindings,by:\.origin) where group.count > 1 {
            let taken = group.filter { $0.kind == .goto && $0.role == .taken }
            let defaults = group.filter { $0.kind == .goto && $0.role == .tableDefault }
            guard group.count == 2, taken.count == 1, defaults.count == 1,
                  taken[0].line != defaults[0].line, taken[0].target == defaults[0].target,
                  defaults[0].sourceRow == origin.row,
                  source.dispatches[origin.row]?.guardRow == taken[0].sourceRow,
                  verifiedDefaultOrigin(origin, source:source),
                  source.rows[source.blocks[origin.edge.toBlock].rows.lowerBound].address == taken[0].target else {
                throw C.Failure.invalidContract("duplicate baseline origin must not collapse its denominator")
            }
        }
    }
    static func account(_ report: Ledger.Report, baseline: BoundMapping) throws -> Accounting {
        guard report.source.rows.first?.address == baseline.frozen.start,
              baseline.bindings.allSatisfy({ report.source.origins.contains($0.origin) }) else {
            throw C.Failure.invalidContract("bound baseline/source ledger mismatch")
        }
        let gotos = Set(baseline.bindings.filter { $0.kind == .goto })
        let helpers = Set(baseline.bindings.filter { $0.kind != .goto })
        let physicalOrigins = Set(baseline.bindings.map(\.origin))
        var structured: Set<Binding> = [], residual: Set<Binding> = [], unresolved: Set<Binding> = []
        for binding in gotos {
            guard let account = report.accounts.first(where: { $0.origin == binding.origin }) else { unresolved.insert(binding); continue }
            switch account.disposition {
            case .structured: structured.insert(binding)
            case .residual: residual.insert(binding)
            case .mixed, .unresolved: unresolved.insert(binding)
            }
        }
        let slots = report.residualSlots.map { slot in
            ResidualSlot(span:slot.span,originalGotoOrigins:Set(gotos.filter { slot.origins.contains($0.origin) }),
                         originalBranchHelperOrigins:Set(helpers.filter { slot.origins.contains($0.origin) }),
                         otherTopologyOrigins:slot.origins.subtracting(physicalOrigins))
        }
        return .init(originalGotoCount:baseline.frozen.originalGotoCount,
                     originalUnconditionalHelperCount:baseline.frozen.originalUnconditionalHelperCount,
                     originalConditionalHelperCount:baseline.frozen.originalConditionalHelperCount,
                     actualPrintedGotoCount:report.printedGotoCount,
                     structuredOriginalGotoOrigins:structured,residualOriginalGotoOrigins:residual,
                     unresolvedOriginalGotoOrigins:unresolved,residualSlots:slots,topologyGaps:report.gaps)
    }

    static func frozenMapping(for start: UInt64) -> FrozenMapping? {
        switch start {
        case 0x26c78:
            return .init(start:0x26c78,
                metadataRelativePath:"captures/new-switch-launch-v2-0x26c78/witness-metadata.json.document-metadata.json",
                metadataSHA256:"b2b4bc0349a790b375d782789aca4fdb00f7899bbb26a4467beb986ed9bdf3e5",
                baselineTextSHA256:"551e15d6a6289a140b433e8dc7182c897c88328bc77552a113e7f05aacd67a46",gotos:68,helpers:36,records:"""
                10|7|G|T|0x26d18
                12|10|G|T|0x26cc0
                33|32|G|T|0x26d24
                35|35|G|T|0x26d88
                37|38|G|T|0x26d30
                38|39|H|U|0x26d48
                39|41|G|T|0x26ca4
                40|42|H|U|0x26cc0
                52|55|G|T|0x26da0
                56|59|G|T|0x26dd8
                57|61|G|T|0x26dbc
                63|67|H|U|0x26e98
                64|69|G|T|0x26e18
                66|72|G|T|0x26d30
                67|73|H|U|0x26d48
                68|75|G|T|0x26e28
                69|77|G|T|0x26f2c
                70|79|G|T|0x26d58
                71|80|H|U|0x26f18
                83|93|G|T|0x26ee8
                84|95|G|T|0x26e94
                85|97|G|T|0x270d8
                88|100|G|T|0x26f6c
                91|103|H|U|0x270d0
                93|106|G|T|0x26d30
                94|107|H|U|0x26d48
                95|109|G|T|0x26f4c
                96|111|G|T|0x26f18
                112|126|G|T|0x26fb0
                113|127|G|T|0x27180
                114|129|G|T|0x27174
                115|131|G|T|0x270d8
                118|134|H|U|0x270b8
                123|140|G|T|0x26eb8
                126|143|G|T|0x270c8
                128|146|G|T|0x2712c
                135|152|G|C0|0x27114
                136|152|G|C1|0x26edc
                137|152|G|C2|0x27120
                138|152|G|C3|0x26f98
                139|152|G|C4|0x26fa4
                140|152|G|C5|0x26f8c
                141|152|G|C6|0x26edc
                142|152|G|C7|0x26f98
                143|152|G|C8|0x26fa4
                144|152|G|C9|0x26f8c
                145|152|G|D|0x2712c
                149|155|H|U|0x270d0
                151|158|G|T|0x27150
                158|164|G|C0|0x27138
                159|164|G|C1|0x26f0c
                160|164|G|C2|0x27144
                161|164|G|C3|0x26ff4
                162|164|G|C4|0x27000
                163|164|G|C5|0x26fe8
                164|164|G|C6|0x26f0c
                165|164|G|C7|0x26ff4
                166|164|G|C8|0x27000
                167|164|G|C9|0x26fe8
                168|164|G|D|0x27150
                172|167|H|U|0x270d0
                174|170|G|T|0x270d8
                176|172|H|U|0x26f64
                180|176|G|T|0x27028
                181|178|G|T|0x2700c
                183|180|H|U|0x27048
                187|184|G|T|0x27098
                188|186|G|T|0x2707c
                190|188|H|U|0x270c8
                193|192|G|T|0x26fdc
                197|196|H|U|0x270b8
                200|199|H|U|0x270d0
                203|202|H|U|0x270d0
                206|205|H|U|0x270d0
                207|206|G|T|0x27198
                208|208|G|T|0x2718c
                209|210|G|T|0x270d8
                212|213|G|T|0x26e0c
                215|216|H|U|0x270b8
                218|219|H|U|0x270b8
                221|222|H|U|0x270d0
                224|225|H|U|0x270d0
                227|228|H|U|0x270d0
                237|239|G|T|0x27048
                238|241|G|T|0x2715c
                239|243|G|T|0x270d8
                244|249|G|T|0x270f0
                250|255|G|T|0x2706c
                251|256|H|U|0x270f0
                261|267|G|T|0x270c8
                262|269|G|T|0x270d8
                268|275|H|U|0x270f0
                272|279|H|U|0x270f0
                291|297|H|U|0x270d0
                294|300|H|U|0x270d0
                297|303|H|U|0x270d0
                300|306|H|U|0x270d0
                303|309|H|U|0x270d0
                306|312|H|U|0x270d0
                312|318|H|U|0x270f0
                315|321|H|U|0x270d0
                318|324|H|U|0x270d0
                321|327|H|U|0x270d0
                324|330|H|U|0x270d0
                """)
        case 0x2893c:
            return .init(start:0x2893c,
                metadataRelativePath:"captures/new-switch-launch-v2-0x2893c/witness-metadata.json.document-metadata.json",
                metadataSHA256:"d7416e091f6290660923410ccb031a6f57abe3755f68011128f16b543b7b6490",
                baselineTextSHA256:"0f71380a5b8705fbcbf00bb44224011229d52324992be053aad026519ba7a6fa",gotos:65,helpers:35,conditionalHelpers:1,records:"""
                10|7|G|T|0x289dc
                12|10|G|T|0x28984
                33|32|G|T|0x289e8
                35|35|G|T|0x28a4c
                37|38|G|T|0x289f4
                38|39|H|U|0x28a0c
                39|41|G|T|0x28968
                40|42|H|U|0x28984
                52|55|G|T|0x28a64
                56|59|G|T|0x28a9c
                57|61|G|T|0x28a80
                63|67|H|U|0x28b60
                64|69|G|T|0x28ae0
                66|72|G|T|0x289f4
                67|73|H|U|0x28a0c
                68|75|G|T|0x28af0
                69|77|G|T|0x28bf4
                70|79|G|T|0x28a1c
                71|80|H|U|0x28be0
                83|93|G|T|0x28bb0
                84|95|G|T|0x28b5c
                85|97|G|T|0x28d74
                87|100|G|T|0x28c34
                91|104|H|U|0x28c3c
                93|107|G|T|0x289f4
                94|108|H|U|0x28a0c
                95|110|G|T|0x28c14
                96|112|G|T|0x28be0
                112|127|G|T|0x28c70
                113|128|G|T|0x28e1c
                114|130|G|T|0x28e10
                115|132|G|T|0x28d74
                118|135|H|U|0x28c3c
                123|141|G|T|0x28b80
                126|144|G|T|0x28d64
                128|147|G|T|0x28dc8
                135|153|G|C0|0x28db0
                136|153|G|C1|0x28ba4
                137|153|G|C2|0x28dbc
                138|153|G|C3|0x28c58
                139|153|G|C4|0x28c64
                140|153|G|C5|0x28c4c
                141|153|G|C6|0x28ba4
                142|153|G|C7|0x28c58
                143|153|G|C8|0x28c64
                144|153|G|C9|0x28c4c
                145|153|G|D|0x28dc8
                149|156|H|U|0x28d6c
                151|159|G|T|0x28dec
                158|165|G|C0|0x28dd4
                159|165|G|C1|0x28bd4
                160|165|G|C2|0x28de0
                161|165|G|C3|0x28c9c
                162|165|G|C4|0x28ca8
                163|165|G|C5|0x28c90
                164|165|G|C6|0x28bd4
                165|165|G|C7|0x28c9c
                166|165|G|C8|0x28ca8
                167|165|G|C9|0x28c90
                168|165|G|D|0x28dec
                172|168|H|U|0x28d6c
                174|171|G|T|0x28d74
                176|173|H|U|0x28c2c
                180|177|G|T|0x28cd0
                181|179|G|T|0x28cb4
                183|181|H|U|0x28cf0
                187|185|G|T|0x28d40
                188|187|G|T|0x28d24
                190|189|H|U|0x28d64
                196|195|H|U|0x28d8c
                199|198|H|U|0x28d6c
                202|201|H|U|0x28d6c
                205|204|H|U|0x28d6c
                206|205|Q|T|0x28e34
                207|207|G|T|0x28e28
                208|209|G|T|0x28d74
                211|212|H|U|0x28c3c
                214|215|H|U|0x28d6c
                217|218|H|U|0x28d6c
                220|221|H|U|0x28d6c
                230|232|G|T|0x28cf0
                231|234|G|T|0x28df8
                232|236|G|T|0x28d74
                237|242|G|T|0x28d8c
                243|248|G|T|0x28d14
                244|249|H|U|0x28d8c
                254|260|G|T|0x28d64
                255|262|G|T|0x28d74
                258|265|H|U|0x28c3c
                262|269|H|U|0x28d8c
                281|287|H|U|0x28d6c
                284|290|H|U|0x28d6c
                287|293|H|U|0x28d6c
                290|296|H|U|0x28d6c
                293|299|H|U|0x28d6c
                296|302|H|U|0x28d6c
                302|308|H|U|0x28d8c
                305|311|H|U|0x28d6c
                308|314|H|U|0x28d6c
                311|317|H|U|0x28d6c
                314|320|H|U|0x28d6c
                """)
        default: return nil // Do not manufacture up/skip identity from generic topology.
        }
    }
}
