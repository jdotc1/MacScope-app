import Foundation

/// The oracle run's report: counts per status, per category and per family (form mnemonic within
/// its category), the smallest failing word per family, and what the failures have in common.
struct A64OracleReport {
    let outcomes: [A64OracleRunner.Outcome]
    let oracleRevision: String

    private typealias Status = A64OracleRunner.Status
    private static let columns: [Status] = [.pass, .fail, .unlifted, .unsupported, .harness]

    private func counts(_ subset: [A64OracleRunner.Outcome]) -> [Status: Int] {
        Dictionary(grouping: subset, by: \.status).mapValues(\.count)
    }

    var summaryLine: String {
        let totals = counts(outcomes)
        return Self.columns.map { "\($0.rawValue) \(totals[$0] ?? 0)" }.joined(separator: " · ")
    }

    private static func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    func markdown() -> String {
        var lines: [String] = []
        let totals = counts(outcomes)
        lines.append("# A64 lifter oracle vs MacIR")
        lines.append("")
        lines.append("Oracle: schema macscope-a64-lifter-oracle-1, \(outcomes.count) fixtures, written against \(oracleRevision).")
        lines.append("")
        lines.append(Self.row(Self.columns.map(\.rawValue)))
        lines.append(Self.row(Self.columns.map { _ in "---:" }))
        lines.append(Self.row(Self.columns.map { "\(totals[$0] ?? 0)" }))
        lines.append("")
        lines.append("How to read this:")
        lines.append("- PASS: every modeled data output and unchanged-state invariant matched; any unmodeled NZCV outputs are listed separately. FPSR-bearing fixtures cannot PASS.")
        lines.append("- FAIL: an output or invariant differed, or the IR's C is undefined for the input.")
        lines.append("- UNLIFTED: the lifter emitted `.unknown` for the instruction.")
        lines.append("- UNSUPPORTED: valid IR the evaluator does not model: NZCV/FPSR-only outputs (MacIR has no flag state), vector lanes, non-default FPCR, unknown intrinsics.")
        lines.append("- Legacy C operators retain their typed C reading. Explicit access descriptors, casts, A64 division intrinsics, return targets and scalar-FP descriptors are evaluated by their documented architecture semantics, independently of source spans.")
        lines.append("- NZCV outputs on a case that also writes registers retain the legacy unmodeled reporting policy. Every FPSR expectation makes a numerically matching case UNSUPPORTED, including an expected unchanged/zero FPSR. Numeric mismatches still FAIL.")
        lines.append("- FAIL tags: `signedness` means the case passes with every signed/unsigned decision flipped (faithful but ambiguous IR). `access-width(Nu|Ns)` means it passes with an N-byte zero/sign-extending access. `c-undefined` means the C is undefined where A64 is defined.")
        lines.append("- Flag consumers (`csel`, `cset`, …) that lift to `.unknown` alone are re-run behind a synthesized `cmp` that produces the fixture's exact NZCV.")
        lines.append("")

        let failures = outcomes.filter { $0.status == .fail }
        var tagCounts: [String: Int] = [:]
        for outcome in failures {
            for tag in outcome.tags {
                tagCounts[tag.hasPrefix("access-width") ? "access-width" : tag, default: 0] += 1
            }
        }
        lines.append("FAIL tags: " + (tagCounts.isEmpty ? "none" : tagCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            + "; untagged \(failures.filter { $0.tags.isEmpty }.count).")
        let synthesized = outcomes.filter(\.viaSynthesizedCompare)
        lines.append("Synthesized-compare cases: \(synthesized.count) (" + Self.columns.compactMap { status in
            let count = synthesized.filter { $0.status == status }.count
            return count == 0 ? nil : "\(status.rawValue) \(count)"
        }.joined(separator: ", ") + ").")
        let unmodeledPasses = outcomes.filter { $0.status == .pass && !$0.unmodeled.isEmpty }.count
        lines.append("PASS cases with unmodeled NZCV/FPSR outputs: \(unmodeledPasses).")
        lines.append("")

        lines.append("## MacIR fidelity: width and signedness (§4.78)")
        lines.append("")
        lines.append("Alternate signedness/access readings are diagnostics for legacy ambiguous IR only. Explicit memory widths/extensions take precedence over diagnostic overrides. MacIR still has no NZCV/FPSR state.")
        lines.append("")
        let fidelity = Dictionary(grouping: failures.filter { outcome in
            outcome.tags.contains("signedness") || outcome.tags.contains { $0.hasPrefix("access-width") }
        }, by: \.vector.family)
        lines.append(Self.row(["Family", "signedness", "access-width", "Example"]))
        lines.append(Self.row(["---", "---:", "---:", "---"]))
        for (family, subset) in fidelity.sorted(by: { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }) {
            let signedness = subset.filter { $0.tags.contains("signedness") }.count
            let width = subset.filter { $0.tags.contains { $0.hasPrefix("access-width") } }.count
            let example = subset.min { ($0.vector.wordValue ?? .max) < ($1.vector.wordValue ?? .max) }!
            lines.append(Self.row([family, "\(signedness)", "\(width)",
                                   Self.escape("`\(example.vector.asm)`: \(example.reason) [\(example.tags.joined(separator: ", "))]")]))
        }
        if fidelity.isEmpty { lines.append(Self.row(["(none)", "0", "0", ""])) }
        lines.append("")

        lines.append("## By category")
        lines.append("")
        lines.append(Self.row(["Category", "Fixtures"] + Self.columns.map(\.rawValue)))
        lines.append(Self.row(["---", "---:"] + Self.columns.map { _ in "---:" }))
        for (category, subset) in Dictionary(grouping: outcomes, by: \.vector.category).sorted(by: { $0.key < $1.key }) {
            let c = counts(subset)
            lines.append(Self.row([category, "\(subset.count)"] + Self.columns.map { "\(c[$0] ?? 0)" }))
        }
        lines.append("")

        lines.append("## By family")
        lines.append("")
        lines.append("Smallest failing word: the lowest-valued FAIL word in the family, as oracle asm → MacScope decode, with the first mismatch and its tags. When there's no FAIL, the lowest UNLIFTED or UNSUPPORTED word is shown in italics.")
        lines.append("")
        lines.append(Self.row(["Family", "Fixtures"] + Self.columns.map(\.rawValue) + ["Smallest failing word"]))
        lines.append(Self.row(["---", "---:"] + Self.columns.map { _ in "---:" } + ["---"]))
        for (family, subset) in Dictionary(grouping: outcomes, by: \.vector.family).sorted(by: { $0.key < $1.key }) {
            let c = counts(subset)
            func smallest(_ status: Status) -> A64OracleRunner.Outcome? {
                subset.filter { $0.status == status }.min { ($0.vector.wordValue ?? .max) < ($1.vector.wordValue ?? .max) }
            }
            var detail = ""
            if let failing = smallest(.fail) {
                detail = "\(failing.vector.word) `\(failing.vector.asm)` → `\(failing.decoded)`: \(failing.reason)"
                    + (failing.tags.isEmpty ? "" : " [\(failing.tags.joined(separator: ", "))]")
            } else if let other = smallest(.unlifted) ?? smallest(.unsupported) {
                detail = "_\(other.vector.word) `\(other.vector.asm)` → `\(other.decoded)`: \(other.status.rawValue) \(other.reason)_"
            }
            lines.append(Self.row([family, "\(subset.count)"] + Self.columns.map { "\(c[$0] ?? 0)" } + [Self.escape(detail)]))
        }
        lines.append("")

        lines.append("## UNLIFTED by mnemonic")
        lines.append("")
        // A synthesized pair groups under its consumer; an undecodable word under the decoder.
        let unlifted = Dictionary(grouping: outcomes.filter { $0.status == .unlifted }) { outcome -> String in
            if outcome.reason.hasPrefix("decoder:") { return "(not decoded by ARM64Decoder)" }
            let text = outcome.decoded.hasPrefix("cmp; ") ? String(outcome.decoded.dropFirst(5)) + " (after cmp)" : outcome.decoded
            let mnemonic = text.split(separator: " ").first.map(String.init) ?? text
            return outcome.decoded.hasPrefix("cmp; ") ? mnemonic + " (after cmp)" : mnemonic
        }
        lines.append(Self.row(["Mnemonic", "Fixtures", "Example"]))
        lines.append(Self.row(["---", "---:", "---"]))
        for (mnemonic, subset) in unlifted.sorted(by: { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }) {
            lines.append(Self.row([mnemonic, "\(subset.count)", Self.escape("`\(subset[0].decoded)`")]))
        }
        lines.append("")

        lines.append("## UNSUPPORTED by reason")
        lines.append("")
        let unsupported = Dictionary(grouping: outcomes.filter { $0.status == .unsupported }) { outcome -> String in
            outcome.reason.hasPrefix("flags-only") ? "flags-only output" : outcome.reason
        }
        lines.append(Self.row(["Reason", "Fixtures"]))
        lines.append(Self.row(["---", "---:"]))
        for (reason, subset) in unsupported.sorted(by: { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }) {
            lines.append(Self.row([Self.escape(reason), "\(subset.count)"]))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// One record per fixture, for tooling and for diffing two runs.
    func json() throws -> Data {
        let records = outcomes.map { outcome -> [String: Any] in
            [
                "id": outcome.vector.id,
                "family": outcome.vector.family,
                "word": outcome.vector.word,
                "asm": outcome.vector.asm,
                "decoded": outcome.decoded,
                "status": outcome.status.rawValue,
                "reason": outcome.reason,
                "tags": outcome.tags,
                "unmodeled": outcome.unmodeled,
                "synthesizedCompare": outcome.viaSynthesizedCompare,
            ]
        }
        return try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted])
    }
}
