import Foundation
@testable import MacScope

/// One classified divergence between MacScope and an oracle, for the trusted-gate report.
struct GoldenDivergence: Equatable {
    var capability: String
    var detail: String
}

/// A KNOWN, accepted difference that must NOT fail the gate. Clean-room safe: it names only a
/// `/bin/ls` instruction address or symbol key and a human-readable reason — never any oracle
/// output.
struct GoldenAcceptedDelta: Equatable {
    enum Kind: Equatable { case decode, imports }
    var kind: Kind
    /// Decode entries use a canonical `0x` instruction address; import entries use a symbol name.
    var key: String
    var reason: String
}

/// Classifies a MacScope-vs-oracle `GoldenOutput` comparison into a GATE verdict. The whole point
/// of a *trusted* gate is that it turns the build RED only on a real, un-accepted divergence —
/// a decode error, missing import, or genuine coverage regression — and stays GREEN on the large volume of
/// oracle scope / taxonomy / naming-convention differences that are NOT MacScope defects.
///
/// Why the raw `GoldenDiff.matches` (exact, symmetric match) cannot be the gate: the v1 oracle
/// exporters intentionally leave whole categories empty (the reference exporter still does for imports/exports/
/// CFG/xrefs/demangled names) and use different conventions for the rest (Mach-O `SEG,SECT` vs
/// bare section names, symbol-`kind` vocabularies, import stubs modeled as `imports` here vs
/// `procedures` there, auto-generated `loc_`/`FUN_`/`byte_` labels). Demanding an exact match
/// against that conflates three unlike
/// things — real divergence, oracle scope, and convention — so the differential is permanently red
/// and therefore worthless as a gate. This gate separates them.
///
/// The policy (see `GoldenFixtures/README.md` for the full rationale):
///   • DECODE (gated): a shared-address instruction whose mnemonic/operands are not semantically
///     equivalent (after `OperandNormalizer`), unless its address is in `acceptedDeltas`.
///   • IMPORTS (gated): every oracle import must be present in MacScope's import set after
///     `normalizedSymbolName` (library/ordinal metadata differences remain reported-only), unless
///     the import symbol is in `acceptedDeltas`.
///   • COVERAGE (gated): a NAMED function or NAMED code symbol the oracle has that MacScope lacks,
///     after excluding import stubs (`__stubs`/`__auth_stubs`/GOT), oracle auto-labels
///     (`loc_`/`FUN_`/`byte_`/…), names MacScope models under `imports`, and any address outside
///     the loaded image or in a non-executable section.
///   • Everything else is REPORTED (printed, never failing): binary metadata, sections, symbol-kind
///     taxonomy, exports, CFG/xrefs, demangled-name gaps, basic-block boundaries, pseudocode, stub
///     procedures, and unnamed auto-discovered functions — each a known convention/scope
///     difference, not a defect.
enum GoldenGate {
    /// The committed allowlist of accepted differences. Each entry documents a specific, understood
    /// divergence that is NOT a MacScope defect; keep it minimal and re-justify on every change.
    static let acceptedDeltas: [GoldenAcceptedDelta] = [
        GoldenAcceptedDelta(
            kind: .decode,
            key: "0x0000000100003748",
            reason: "MacScope emits the preferred BFI alias (`bfi x10, x23, #1, #63`); some oracles "
                  + "(reference output) emit the raw BFM encoding (`bfm …, #0x3f, #0x3e`) — same instruction "
                  + "(immr = -lsb mod 64 = 0x3f, imms = width-1 = 0x3e)."
        )
    ]

    struct Verdict {
        /// Real, un-accepted divergences. A NON-empty list fails the gate.
        var gated: [GoldenDivergence]
        /// Divergences matched by the allowlist, surfaced for transparency.
        var accepted: [GoldenDivergence]
        /// Per-capability summary of the non-gated differences (oracle scope / taxonomy / naming),
        /// kept visible so nothing is silently hidden.
        var reported: [String]

        /// The gate passes iff there are no un-accepted real divergences.
        var passes: Bool { gated.isEmpty }

        /// A human-readable report for the test failure message / console.
        var lines: [String] {
            var out: [String] = []
            if gated.isEmpty {
                out.append("✓ gate PASS — no un-accepted decode, import, or coverage divergences")
            } else {
                out.append("✗ gate FAIL — \(gated.count) un-accepted divergence(s):")
                out += gated.map { "    [\($0.capability)] \($0.detail)" }
            }
            if !accepted.isEmpty {
                out.append("accepted (allowlisted, \(accepted.count)):")
                out += accepted.map { "    [\($0.capability)] \($0.detail)" }
            }
            if !reported.isEmpty {
                out.append("reported (oracle scope / taxonomy / naming — not gated):")
                out += reported.map { "    \($0)" }
            }
            return out
        }
    }

    static func evaluate(actual: GoldenOutput,
                         reference: GoldenOutput,
                         allowlist: [GoldenAcceptedDelta] = acceptedDeltas) -> Verdict {
        let sections = SectionTable(actual.sections)
        let acceptedDecodeAddrs = Set(allowlist.filter { $0.kind == .decode }.compactMap { parseAddress($0.key) })
        let acceptedImportNames = Set(allowlist.filter { $0.kind == .imports }.map { normalizedSymbolName($0.key) })
        let actualImportNames = Set(actual.imports.map { normalizedSymbolName($0.name) })
        let actualSymbolAddrs = Set(actual.symbols.compactMap { $0.address.flatMap(parseAddress) })
        let actualProcAddrs = Set(actual.procedures.compactMap { parseAddress($0.startAddress) })
        // The [start, end) ranges of every function MacScope discovered. An oracle function/symbol
        // whose address falls INSIDE one of these is already covered by a MacScope function — the
        // oracle merely over-split / mid-function-labeled it (e.g. reference output creating a function at the
        // `stp` right after an arm64e `pacibsp` prologue) — so it is a boundary/labeling difference,
        // not missing coverage.
        let actualFunctionRanges: [(lo: UInt64, hi: UInt64)] = actual.procedures.compactMap { p in
            guard let lo = parseAddress(p.startAddress), let hi = parseAddress(p.endAddress), lo < hi else { return nil }
            return (lo, hi)
        }
        func coveredByFunction(_ addr: UInt64) -> Bool {
            actualFunctionRanges.contains { addr >= $0.lo && addr < $0.hi }
        }
        let actualInstrByAddr = Dictionary(actual.instructions.map { (parseAddress($0.address) ?? 0, $0) },
                                           uniquingKeysWith: { first, _ in first })

        var gated: [GoldenDivergence] = []
        var accepted: [GoldenDivergence] = []

        // DECODE — shared-address instructions whose semantics differ.
        for ref in reference.instructions {
            guard let addr = parseAddress(ref.address), let mine = actualInstrByAddr[addr] else { continue }
            let same = OperandNormalizer.canonicalMnemonic(mine.mnemonic) == OperandNormalizer.canonicalMnemonic(ref.mnemonic)
                && OperandNormalizer.equivalent(mine.operands, ref.operands)
            if same { continue }
            let detail = "@\(ref.address) MacScope `\(mine.mnemonic) \(mine.operands)` vs oracle `\(ref.mnemonic) \(ref.operands)`"
            if acceptedDecodeAddrs.contains(addr) {
                accepted.append(GoldenDivergence(capability: "instructions", detail: detail))
            } else {
                gated.append(GoldenDivergence(capability: "instructions", detail: detail))
            }
        }

        // IMPORTS — every oracle import must be present by normalized symbol name. Library path and
        // ordinal taxonomy remain in the raw reported diff because tools disagree on those details.
        for imported in reference.imports {
            let normalized = normalizedSymbolName(imported.name)
            guard !actualImportNames.contains(normalized) else { continue }
            let library = imported.libraryName.map { " from \($0)" } ?? ""
            let detail = "oracle imports `\(imported.name)`\(library) but MacScope did not"
            if acceptedImportNames.contains(normalized) {
                accepted.append(GoldenDivergence(capability: "imports", detail: detail))
            } else {
                gated.append(GoldenDivergence(capability: "imports", detail: detail))
            }
        }

        // COVERAGE (functions) — a real, named function in executable code that MacScope lacks.
        for proc in reference.procedures {
            guard let addr = parseAddress(proc.startAddress), !actualProcAddrs.contains(addr) else { continue }
            guard let section = sections.section(at: addr), section.isExecutable,
                  !isStubSection(section.name), !isAutoLabel(proc.name),
                  !coveredByFunction(addr) else { continue }
            gated.append(GoldenDivergence(capability: "procedures",
                detail: "oracle has function `\(proc.name)` @\(proc.startAddress) (in \(section.name)) that MacScope did not discover"))
        }

        // COVERAGE (symbols) — a real, named code symbol that MacScope lacks (by address).
        for sym in reference.symbols {
            guard let addrString = sym.address, let addr = parseAddress(addrString),
                  !actualSymbolAddrs.contains(addr) else { continue }
            guard let section = sections.section(at: addr), section.isExecutable,
                  !isStubSection(section.name), !isAutoLabel(sym.name),
                  !actualImportNames.contains(normalizedSymbolName(sym.name)),
                  !coveredByFunction(addr) else { continue }
            gated.append(GoldenDivergence(capability: "symbols",
                detail: "oracle has code symbol `\(sym.name)` @\(addrString) (in \(section.name)) that MacScope did not name"))
        }

        // REPORTED — the full raw diff, for visibility (never failing).
        let raw = GoldenOutputDiff.compare(actual: actual, reference: reference)
        return Verdict(gated: gated, accepted: accepted, reported: raw.summaryLines)
    }

    // MARK: - Classification helpers

    /// Section names whose contents are dispatch/indirection STUBS, not user functions: import
    /// stubs (`__stubs`/`__auth_stubs`), the GOT and symbol-pointer tables, and the modern ObjC
    /// message-send stubs (`__objc_stubs` = the `_objc_msgSend$<selector>` stubs each tail-calling
    /// `objc_msgSend`). MacScope models these as imports / dispatch helpers rather than as
    /// procedures, so an oracle that lists them as functions (selector-named, like reference output) is a
    /// modeling difference, not a missing function.
    private static func isStubSection(_ name: String) -> Bool {
        let stubs = ["__stubs", "__auth_stubs", "__objc_stubs", "__got", "__auth_got",
                     "__la_symbol_ptr", "__nl_symbol_ptr"]
        return stubs.contains { name.contains($0) }
    }

    /// True for an oracle's AUTO-generated label (no real symbol): `loc_`/`sub_`/`byte_`/
    /// `switch_table_`/… and reference output `FUN_`/`LAB_`/`DAT_`/… plus a few fixed synthetic names. A real
    /// symbol (`_main`, `_helper`) never matches, so excluding these cannot hide a genuine miss.
    private static func isAutoLabel(_ name: String) -> Bool {
        if ["MACH_HEADER", "EntryPoint", "entry"].contains(name) { return true }
        return autoLabelRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static let autoLabelRegex: NSRegularExpression = {
        // Leading optional `_`, then a known auto-label prefix, then `_`.
        let prefixes = ["loc", "locret", "sub", "nullsub", "def", "jpt", "switch_table", "unk", "algn",
                        "fun", "lab", "dat", "stru", "off", "byte", "word", "dword", "qword", "asc",
                        "flt", "dbl", "tbyte", "xmmword", "extern"].joined(separator: "|")
        return try! NSRegularExpression(pattern: "^_?(\(prefixes))_", options: [.caseInsensitive])
    }()

    /// Normalizes a symbol name for import matching: drop leading Mach-O `_` characters and lowercase,
    /// so an oracle's `___error` symbol matches MacScope's `_error`/`error` import entry.
    private static func normalizedSymbolName(_ name: String) -> String {
        var n = name
        while n.hasPrefix("_") { n.removeFirst() }
        return n.lowercased()
    }

    /// Parses a `0x`-prefixed (or bare) hex address string to a `UInt64`, ignoring zero-padding.
    static func parseAddress(_ s: String) -> UInt64? {
        let body = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        return UInt64(body, radix: 16)
    }

    /// An address → section resolver over MacScope's own sections (the authority for what is in the
    /// loaded image and what is executable).
    private struct SectionTable {
        private let ranges: [(lo: UInt64, hi: UInt64, name: String, isExecutable: Bool)]
        init(_ sections: [GoldenSection]) {
            ranges = sections.compactMap { s in
                guard let lo = GoldenGate.parseAddress(s.address) else { return nil }
                return (lo, lo &+ s.size, s.name, s.isExecutable)
            }
        }
        func section(at addr: UInt64) -> (name: String, isExecutable: Bool)? {
            for r in ranges where addr >= r.lo && addr < r.hi { return (r.name, r.isExecutable) }
            return nil
        }
    }
}
