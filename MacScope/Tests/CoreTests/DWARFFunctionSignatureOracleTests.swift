import Foundation
import XCTest
@testable import MacScope

/// Adversarial oracle tests for `DWARFFunctionSignatureReader`. Unlike the
/// shipped tests (which assert against the implementer's own hand-assembled
/// DWARF bytes, or a single trivial `int(int,int)` real dSYM), these build a
/// real dSYM with a VARIED signature matrix and derive ground truth from an
/// INDEPENDENT traversal of `dwarfdump --debug-info` output — base/pointer/
/// const/typedef chains, struct-pointer params, a `void`-returning function,
/// and functions with zero parameters.
final class DWARFFunctionSignatureOracleTests: XCTestCase {

    /// The source compiled into the oracle dSYM. Each function exercises a
    /// distinct DW_AT_type chain the shipped tests do not cover with real
    /// compiler output.
    private static let source = """
    struct Point { int x; int y; };
    union Tag { int i; float f; };
    enum Color { RED, GREEN, BLUE };
    typedef unsigned long my_ulong;

    int f(int a, char *b) { return a + (b ? 1 : 0); }
    double g(void) { return 3.14; }
    const char *h(unsigned long n, short s) { (void)n; (void)s; return "x"; }
    int takes_struct_ptr(struct Point *p) { return p->x; }
    int takes_union_ptr(union Tag *t) { return t->i; }
    enum Color takes_enum(enum Color c) { return c; }
    int takes_const_struct_ptr(const struct Point *p) { return p->x; }
    int takes_volatile(volatile int x) { return x; }
    void takes_array_ptr(int (*p)[10]) { (*p)[0] = 1; }
    int mixed_variadic(double scale, int *values, ...) { return (int)scale + *values; }
    my_ulong uses_typedef(my_ulong v) { return v + 1; }
    void returns_void(int a) { (void)a; }
    int no_params(void) { return 7; }
    int old_style() { return 11; }
    int main(void) {
        struct Point p = {1, 2};
        union Tag tg; tg.i = 3;
        int arr[10] = {0};
        takes_array_ptr(&arr);
        return f(1, 0) + (int)g() + (int)h(1, 2)[0]
             + takes_struct_ptr(&p) + takes_union_ptr(&tg)
             + (int)takes_enum(GREEN) + takes_const_struct_ptr(&p)
             + takes_volatile(5) + mixed_variadic(1.0, &arr[0])
             + (int)uses_typedef(3) + no_params() + old_style() + arr[0];
    }
    """

    /// Renders a type the way `DWARFFunctionSignatureReader` does: a pointer
    /// appends `*` to its (already-rendered) pointee; const/volatile/restrict
    /// prepend their keyword; base/typedef and the named composites
    /// (struct/union/enum/class) yield their name; an anonymous composite or any
    /// other tag is unresolvable -> nil. This mirrors the production renderer
    /// exactly so we test resolution, not cosmetic spacing.
    ///
    /// `DW_TAG_array_type` is deliberately NOT mirrored here: this oracle's DIE
    /// parser does not capture `DW_TAG_subrange_type`/`DW_AT_count`, so the array
    /// dimension cannot be derived. Array rendering is pinned by a direct concrete
    /// assertion in `testReaderConcreteExpectations` instead.
    private static func renderExpected(offset: Int, dies: [Int: OracleDIE]) -> String? {
        renderExpected(offset: offset, dies: dies, visited: [])
    }

    private static func renderExpected(offset: Int, dies: [Int: OracleDIE], visited: Set<Int>) -> String? {
        guard !visited.contains(offset), let die = dies[offset] else { return nil }
        var visited = visited
        visited.insert(offset)
        switch die.tag {
        case "DW_TAG_base_type", "DW_TAG_typedef",
             "DW_TAG_structure_type", "DW_TAG_union_type",
             "DW_TAG_enumeration_type", "DW_TAG_class_type":
            return die.name
        case "DW_TAG_pointer_type":
            guard let t = die.typeOffset,
                  let inner = renderExpected(offset: t, dies: dies, visited: visited) else { return nil }
            return inner + "*"
        case "DW_TAG_const_type":
            guard let t = die.typeOffset,
                  let inner = renderExpected(offset: t, dies: dies, visited: visited) else { return nil }
            return "const " + inner
        case "DW_TAG_volatile_type":
            guard let t = die.typeOffset,
                  let inner = renderExpected(offset: t, dies: dies, visited: visited) else { return nil }
            return "volatile " + inner
        case "DW_TAG_restrict_type":
            guard let t = die.typeOffset,
                  let inner = renderExpected(offset: t, dies: dies, visited: visited) else { return nil }
            return "restrict " + inner
        default:
            return nil
        }
    }

    func testReaderMatchesOracleAcrossSignatureMatrix() throws {
        let dsym = try OracleDSYM.build(source: Self.source, label: "sig-matrix")
        let sections = try dsym.dwarfSections()
        let recovered = DWARFFunctionSignatureReader(sections: sections).recoverSignatures()

        let dwarfdump = try OracleDSYM.dwarfdumpDebugInfo(dsym.dsymURL)
        let dies = OracleDIE.parse(dwarfdump)
        let subprograms = OracleSubprogram.parse(dwarfdump, dies: dies)

        // The functions we expect to recover by name. (takes_array_ptr is excluded: its
        // dimension cannot be derived through renderExpected — see testReaderConcreteExpectations.)
        let expectedNames = ["f", "g", "h", "takes_struct_ptr", "takes_union_ptr",
                             "takes_enum", "takes_const_struct_ptr", "takes_volatile",
                             "mixed_variadic", "uses_typedef", "returns_void", "no_params"]
        for name in expectedNames {
            XCTAssertNotNil(subprograms[name], "oracle missing subprogram \(name)")
        }

        for (name, sub) in subprograms where expectedNames.contains(name) {
            guard let sig = recovered[sub.lowPC] else {
                XCTFail("reader recovered no signature for \(name) @ \(String(sub.lowPC, radix: 16))")
                continue
            }

            // Return type.
            let expectedReturn = sub.returnTypeOffset.flatMap { Self.renderExpected(offset: $0, dies: dies) }
            XCTAssertEqual(sig.returnType, expectedReturn, "return type mismatch for \(name)")

            // Parameter count and order.
            XCTAssertEqual(sig.args.count, sub.params.count, "param count mismatch for \(name)")
            XCTAssertEqual(sig.args.map(\.index), Array(0..<sub.params.count), "param index/order mismatch for \(name)")
            XCTAssertEqual(sig.args.map(\.provenance), Array(repeating: .debug, count: sub.params.count))
            XCTAssertEqual(sig.variadicState, sub.isVariadic ? .variadic : .fixed)
            XCTAssertEqual(Set(sig.args.map(\.rowToken)).count, sig.args.count)
            XCTAssertTrue(sig.args.allSatisfy { $0.rowToken.hasPrefix("debug-") })
            guard case .authoritative = sig.parameterList else {
                XCTFail("DWARF must emit an authoritative list for \(name)")
                continue
            }

            for (i, param) in sub.params.enumerated() where i < sig.args.count {
                let arg = sig.args[i]
                XCTAssertEqual(arg.name, param.name, "param[\(i)] name mismatch for \(name)")
                let expectedType = param.typeOffset.flatMap { Self.renderExpected(offset: $0, dies: dies) } ?? "undefined"
                XCTAssertEqual(arg.type, expectedType, "param[\(i)] type mismatch for \(name)")
            }
        }
    }

    /// Two translation units linked together produce two compile units in one
    /// `.debug_info`. DWARF `DW_FORM_ref4` type references are CU-relative, so
    /// the reader must resolve each subprogram's types against ITS OWN compile
    /// unit. A bug that treated references as section-absolute (or that shared
    /// one offset map across CUs) would cross-contaminate: the second CU's
    /// types would resolve against the first CU's DIEs. This pins that the two
    /// CUs stay isolated.
    func testReaderResolvesTypesPerCompileUnit() throws {
        let a = """
        double afn(double d, char *s) { (void)s; return d; }
        """
        let b = """
        double afn(double d, char *s);
        short bfn(short x, unsigned long y) { (void)y; return x; }
        int main(void) { return (int)afn(1.0, 0) + bfn(2, 3); }
        """
        let dsym = try OracleDSYM.buildMultiUnit(units: ["a.c": a, "b.c": b], label: "sig-multicu")
        let sections = try dsym.dwarfSections()
        let recovered = DWARFFunctionSignatureReader(sections: sections).recoverSignatures()
        let dwarfdump = try OracleDSYM.dwarfdumpDebugInfo(dsym.dsymURL)
        let dies = OracleDIE.parse(dwarfdump)
        let subprograms = OracleSubprogram.parse(dwarfdump, dies: dies)

        func sig(_ name: String) throws -> FunctionSignatureOverride {
            let sub = try XCTUnwrap(subprograms[name], "no subprogram \(name)")
            return try XCTUnwrap(recovered[sub.lowPC], "no signature for \(name)")
        }

        // afn lives in CU #1.
        let afn = try sig("afn")
        XCTAssertEqual(afn.returnType, "double")
        assertDebugRows(afn, [("d", "double"), ("s", "char*")])

        // bfn lives in CU #2. Its types must NOT resolve against CU #1.
        let bfn = try sig("bfn")
        XCTAssertEqual(bfn.returnType, "short")
        assertDebugRows(bfn, [("x", "short"), ("y", "unsigned long")])
    }

    /// Pins the concrete, human-checked expectations so a regression in the
    /// renderer (not just a self-consistent drift) is caught.
    func testReaderConcreteExpectations() throws {
        let dsym = try OracleDSYM.build(source: Self.source, label: "sig-concrete")
        let sections = try dsym.dwarfSections()
        let recovered = DWARFFunctionSignatureReader(sections: sections).recoverSignatures()
        let dwarfdump = try OracleDSYM.dwarfdumpDebugInfo(dsym.dsymURL)
        let dies = OracleDIE.parse(dwarfdump)
        let subprograms = OracleSubprogram.parse(dwarfdump, dies: dies)

        func sig(_ name: String) throws -> FunctionSignatureOverride {
            let sub = try XCTUnwrap(subprograms[name], "no subprogram \(name)")
            return try XCTUnwrap(recovered[sub.lowPC], "no signature for \(name)")
        }

        // double g(void) -> ret double, no params (empty, not garbage).
        let g = try sig("g")
        XCTAssertEqual(g.returnType, "double")
        assertDebugRows(g, [])

        // int no_params(void) -> empty args.
        let np = try sig("no_params")
        XCTAssertEqual(np.returnType, "int")
        assertDebugRows(np, [])

        // void returns_void(int a) -> nil return type, one int param.
        let rv = try sig("returns_void")
        XCTAssertNil(rv.returnType, "void return must be nil, not a fabricated type")
        assertDebugRows(rv, [("a", "int")])

        // const char *h(unsigned long n, short s)
        let h = try sig("h")
        XCTAssertEqual(h.returnType, "const char*")
        assertDebugRows(h, [("n", "unsigned long"), ("s", "short")])

        // int f(int a, char *b)
        let f = try sig("f")
        XCTAssertEqual(f.returnType, "int")
        assertDebugRows(f, [("a", "int"), ("b", "char*")])

        // my_ulong uses_typedef(my_ulong v) -> typedef name preserved.
        let ut = try sig("uses_typedef")
        XCTAssertEqual(ut.returnType, "my_ulong")
        assertDebugRows(ut, [("v", "my_ulong")])

        // int takes_struct_ptr(struct Point *p): pointer -> structure_type, now resolved
        // to the named struct. The headline case — the parameter renders as "Point*",
        // not "undefined".
        let ts = try sig("takes_struct_ptr")
        XCTAssertEqual(ts.returnType, "int")
        assertDebugRows(ts, [("p", "Point*")])

        // int takes_union_ptr(union Tag *t): pointer -> union_type.
        let tu = try sig("takes_union_ptr")
        XCTAssertEqual(tu.returnType, "int")
        assertDebugRows(tu, [("t", "Tag*")])

        // enum Color takes_enum(enum Color c): enumeration_type resolved by name, as both
        // the return type and the parameter.
        let te = try sig("takes_enum")
        XCTAssertEqual(te.returnType, "Color")
        assertDebugRows(te, [("c", "Color")])

        // const struct Point *: pointer -> const_type -> structure_type composes to
        // "const Point*".
        let tc = try sig("takes_const_struct_ptr")
        XCTAssertEqual(tc.returnType, "int")
        assertDebugRows(tc, [("p", "const Point*")])

        // volatile int: a transparent qualifier handled like const, prefixing "volatile ".
        let tv = try sig("takes_volatile")
        XCTAssertEqual(tv.returnType, "int")
        assertDebugRows(tv, [("x", "volatile int")])

        // void takes_array_ptr(int (*p)[10]): pointer -> array_type(int, count 10).
        // dwarfdump's canonical declarator is "int (*)[10]"; the reader composes type
        // names by prefix/suffix, so it renders "int[10]*" — what this pins is that the
        // element type AND the dimension (DW_TAG_subrange_type's DW_AT_count = 10) are
        // recovered, not "undefined". Asserted directly because the oracle's DIE parser
        // does not capture subrange counts, so renderExpected cannot derive it.
        let ta = try sig("takes_array_ptr")
        XCTAssertNil(ta.returnType, "void return must be nil")
        assertDebugRows(ta, [("p", "int[10]*")])

        // The formal-parameter DIEs remain in source order even though Darwin's
        // ABI assigns these rows from different register banks. The trailing
        // DW_TAG_unspecified_parameters is declarator evidence, not a fake row.
        let variadic = try sig("mixed_variadic")
        XCTAssertEqual(variadic.returnType, "int")
        assertDebugRows(
            variadic,
            [("scale", "double"), ("values", "int*")],
            variadicState: .variadic
        )
    }

    func testReaderUsesDwarfdumpPrototypeEvidenceForEmptyParameterLists() throws {
        let dsym = try OracleDSYM.build(source: Self.source, label: "sig-prototype-evidence")
        let sections = try dsym.dwarfSections()
        let recovered = DWARFFunctionSignatureReader(sections: sections).recoverSignatures()
        let dwarfdump = try OracleDSYM.dwarfdumpDebugInfo(dsym.dsymURL)
        let dies = OracleDIE.parse(dwarfdump)
        let subprograms = OracleSubprogram.parse(dwarfdump, dies: dies)

        let explicitVoid = try XCTUnwrap(subprograms["no_params"])
        XCTAssertTrue(explicitVoid.isPrototyped, "dwarfdump must positively identify f(void)")
        let explicitSignature = try XCTUnwrap(recovered[explicitVoid.lowPC])
        guard case let .authoritative(explicitRows) = explicitSignature.parameterList else {
            return XCTFail("positive DW_AT_prototyped evidence must preserve explicit void")
        }
        XCTAssertTrue(explicitRows.isEmpty)
        XCTAssertEqual(explicitSignature.variadicState, .fixed)

        let oldStyle = try XCTUnwrap(subprograms["old_style"])
        XCTAssertFalse(oldStyle.isPrototyped, "the real C no-prototype control must lack prototype evidence")
        let oldStyleSignature = try XCTUnwrap(recovered[oldStyle.lowPC])
        XCTAssertEqual(oldStyleSignature.returnType, "int")
        guard case .unspecified = oldStyleSignature.parameterList else {
            return XCTFail("a real no-prototype definition must not be promoted to (void)")
        }
        XCTAssertEqual(oldStyleSignature.variadicState, .unspecified)
    }

    private func assertDebugRows(
        _ signature: FunctionSignatureOverride,
        _ expected: [(name: String, type: String)],
        variadicState: FunctionSignatureOverride.VariadicState = .fixed,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(signature.args.map(\.index), Array(expected.indices), file: file, line: line)
        XCTAssertEqual(signature.args.map(\.name), expected.map { $0.name }, file: file, line: line)
        XCTAssertEqual(signature.args.map(\.type), expected.map { $0.type }, file: file, line: line)
        XCTAssertEqual(
            signature.args.map(\.provenance),
            Array(repeating: .debug, count: expected.count),
            file: file,
            line: line
        )
        XCTAssertEqual(signature.variadicState, variadicState, file: file, line: line)
        XCTAssertEqual(Set(signature.args.map(\.rowToken)).count, signature.args.count, file: file, line: line)
        XCTAssertTrue(signature.args.allSatisfy { $0.rowToken.hasPrefix("debug-") }, file: file, line: line)
        guard case .authoritative = signature.parameterList else {
            return XCTFail("DWARF signature must be authoritative", file: file, line: line)
        }
    }
}

// MARK: - Oracle parsing of dwarfdump --debug-info

/// A minimal DIE record extracted from dwarfdump output: its CU-relative
/// offset, tag, optional name, and optional DW_AT_type target offset.
private struct OracleDIE {
    var offset: Int
    var tag: String
    var name: String?
    var typeOffset: Int?

    static func parse(_ output: String) -> [Int: OracleDIE] {
        var dies: [Int: OracleDIE] = [:]
        var current: OracleDIE?

        func flush() {
            if let c = current { dies[c.offset] = c }
            current = nil
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            // A DIE header looks like: "0x00000031:   DW_TAG_subprogram"
            if let (off, tag) = dieHeader(line) {
                flush()
                current = OracleDIE(offset: off, tag: tag, name: nil, typeOffset: nil)
                continue
            }
            guard current != nil else { continue }
            if line.contains("DW_AT_name"), let name = quoted(line) {
                current?.name = name
            } else if line.contains("DW_AT_type"), let ref = firstHex0x(line) {
                current?.typeOffset = ref
            }
        }
        flush()
        return dies
    }

    private static func dieHeader(_ line: String) -> (Int, String)? {
        // Match "<hex>:   DW_TAG_..."
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let prefix = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        guard prefix.hasPrefix("0x"), let off = Int(prefix.dropFirst(2), radix: 16) else { return nil }
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("DW_TAG_") else { return nil }
        let tag = rest.split(separator: " ").first.map(String.init) ?? rest
        return (off, tag)
    }

    private static func quoted(_ line: String) -> String? {
        guard let first = line.firstIndex(of: "\"") else { return nil }
        let after = line.index(after: first)
        guard let second = line[after...].firstIndex(of: "\"") else { return nil }
        return String(line[after..<second])
    }

    /// The first `0x....` hex token on the line (the DW_AT_type reference
    /// offset, e.g. `DW_AT_type (0x00000107 "const char *")`).
    static func firstHex0x(_ line: String) -> Int? {
        guard let range = line.range(of: "0x") else { return nil }
        var idx = range.upperBound
        var scalars = ""
        while idx < line.endIndex, line[idx].isHexDigit {
            scalars.append(line[idx]); idx = line.index(after: idx)
        }
        return Int(scalars, radix: 16)
    }
}

/// A subprogram parsed from dwarfdump: name, resolved low_pc, return-type
/// offset, and ordered parameters (each with name + type offset).
private struct OracleSubprogram {
    struct Param { var name: String; var typeOffset: Int? }
    var name: String
    var lowPC: UInt64
    var returnTypeOffset: Int?
    var params: [Param] = []
    var isVariadic = false
    var isPrototyped = false

    static func parse(_ output: String, dies: [Int: OracleDIE]) -> [String: OracleSubprogram] {
        var result: [String: OracleSubprogram] = [:]
        var current: OracleSubprogram?
        var inParam = false
        var paramName: String?
        var paramType: Int?

        func flushParam() {
            if inParam, let n = paramName {
                current?.params.append(Param(name: n, typeOffset: paramType))
            }
            inParam = false; paramName = nil; paramType = nil
        }
        func flushFunc() {
            flushParam()
            if let c = current { result[c.name] = c }
            current = nil
        }

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw
            if line.contains("DW_TAG_subprogram") {
                flushFunc()
                current = OracleSubprogram(name: "", lowPC: 0, returnTypeOffset: nil)
                continue
            }
            guard current != nil else { continue }
            if line.contains("DW_TAG_formal_parameter") {
                flushParam()
                inParam = true
                continue
            }
            if line.contains("DW_TAG_unspecified_parameters") {
                flushParam()
                current?.isVariadic = true
                continue
            }
            // Any other DW_TAG_ ends the subprogram (e.g. nested lexical block,
            // variable, or the next top-level DIE).
            if line.contains("DW_TAG_") {
                flushFunc()
                continue
            }
            if inParam {
                if line.contains("DW_AT_name"), let n = quoted(line) { paramName = n }
                else if line.contains("DW_AT_type"), let r = OracleDIE.firstHex0x(line) { paramType = r }
            } else {
                if line.contains("DW_AT_low_pc"), let pc = lowPCValue(line) { current?.lowPC = pc }
                else if line.contains("DW_AT_name"), let n = quoted(line) { current?.name = n }
                else if line.contains("DW_AT_type"), let r = OracleDIE.firstHex0x(line) { current?.returnTypeOffset = r }
                else if line.contains("DW_AT_prototyped"), line.contains("true") { current?.isPrototyped = true }
            }
        }
        flushFunc()
        // Drop any malformed entry with an empty name.
        return result.filter { !$0.key.isEmpty }
    }

    /// dwarfdump prints DW_AT_low_pc as a resolved absolute address, e.g.
    /// `DW_AT_low_pc (0x00000001000003c8)`.
    private static func lowPCValue(_ line: String) -> UInt64? {
        guard let range = line.range(of: "0x") else { return nil }
        var idx = range.upperBound
        var scalars = ""
        while idx < line.endIndex, line[idx].isHexDigit {
            scalars.append(line[idx]); idx = line.index(after: idx)
        }
        return UInt64(scalars, radix: 16)
    }

    private static func quoted(_ line: String) -> String? {
        guard let first = line.firstIndex(of: "\"") else { return nil }
        let after = line.index(after: first)
        guard let second = line[after...].firstIndex(of: "\"") else { return nil }
        return String(line[after..<second])
    }
}

// MARK: - Real dSYM builder

private struct OracleDSYM {
    var dsymURL: URL
    var dwarfURL: URL

    func dwarfSections() throws -> DWARFReader.Sections {
        let bytes = try Data(contentsOf: dwarfURL)
        let machO = try MachOParser().parse(bytes, options: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false,
            parseCodeSignature: false
        ))
        var sections = DWARFReader.Sections()
        for section in machO.sections where section.segmentName == "__DWARF" {
            guard let data = Self.slice(section, bytes: bytes) else { continue }
            switch section.sectionName {
            case "__debug_info": sections.debugInfo = data
            case "__debug_abbrev": sections.debugAbbrev = data
            case "__debug_str": sections.debugStr = data
            case "__debug_str_offs", "__debug_str_offsets": sections.debugStrOffsets = data
            case "__debug_addr": sections.debugAddr = data
            default: break
            }
        }
        return sections
    }

    private static func slice(_ section: MachOSection, bytes: Data) -> Data? {
        guard section.size > 0, let size = Int(exactly: section.size) else { return nil }
        let start = Int(section.fileOffset)
        let (end, overflow) = start.addingReportingOverflow(size)
        guard !overflow, start <= end, end <= bytes.count else { return nil }
        let base = bytes.startIndex
        return bytes.subdata(in: (base + start)..<(base + end))
    }

    static func build(source: String, label: String) throws -> OracleDSYM {
        let clang = URL(fileURLWithPath: "/usr/bin/clang")
        let dsymutil = URL(fileURLWithPath: "/usr/bin/dsymutil")
        guard FileManager.default.isExecutableFile(atPath: clang.path),
              FileManager.default.isExecutableFile(atPath: dsymutil.path) else {
            throw XCTSkip("clang/dsymutil unavailable on this host")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sourceURL = dir.appendingPathComponent("x.c")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let objectURL = dir.appendingPathComponent("x.o")
        let binaryURL = dir.appendingPathComponent("x")
        try Proc.run(clang, ["-g", "-O0", "-c", "-o", objectURL.path, sourceURL.path])
        try Proc.run(clang, ["-g", "-O0", "-o", binaryURL.path, objectURL.path])
        try Proc.run(dsymutil, [binaryURL.path])

        let dsymURL = dir.appendingPathComponent("x.dSYM", isDirectory: true)
        let dwarfURL = dsymURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("DWARF", isDirectory: true)
            .appendingPathComponent("x")
        guard FileManager.default.fileExists(atPath: dwarfURL.path) else {
            throw XCTSkip("dsymutil produced no DWARF on this host")
        }
        return OracleDSYM(dsymURL: dsymURL, dwarfURL: dwarfURL)
    }

    /// Builds a dSYM from multiple translation units linked into one binary so
    /// `.debug_info` carries multiple compile units.
    static func buildMultiUnit(units: [String: String], label: String) throws -> OracleDSYM {
        let clang = URL(fileURLWithPath: "/usr/bin/clang")
        let dsymutil = URL(fileURLWithPath: "/usr/bin/dsymutil")
        guard FileManager.default.isExecutableFile(atPath: clang.path),
              FileManager.default.isExecutableFile(atPath: dsymutil.path) else {
            throw XCTSkip("clang/dsymutil unavailable on this host")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var objects: [String] = []
        for (fileName, source) in units.sorted(by: { $0.key < $1.key }) {
            let srcURL = dir.appendingPathComponent(fileName)
            try source.write(to: srcURL, atomically: true, encoding: .utf8)
            let objURL = dir.appendingPathComponent(fileName + ".o")
            try Proc.run(clang, ["-g", "-O0", "-c", "-o", objURL.path, srcURL.path])
            objects.append(objURL.path)
        }
        let binaryURL = dir.appendingPathComponent("x")
        try Proc.run(clang, ["-g", "-O0", "-o", binaryURL.path] + objects)
        try Proc.run(dsymutil, [binaryURL.path])

        let dsymURL = dir.appendingPathComponent("x.dSYM", isDirectory: true)
        let dwarfURL = dsymURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("DWARF", isDirectory: true)
            .appendingPathComponent("x")
        guard FileManager.default.fileExists(atPath: dwarfURL.path) else {
            throw XCTSkip("dsymutil produced no DWARF on this host")
        }
        return OracleDSYM(dsymURL: dsymURL, dwarfURL: dwarfURL)
    }

    static func dwarfdumpDebugInfo(_ dsymURL: URL) throws -> String {
        let dwarfdump = URL(fileURLWithPath: "/usr/bin/dwarfdump")
        guard FileManager.default.isExecutableFile(atPath: dwarfdump.path) else {
            throw XCTSkip("dwarfdump unavailable on this host")
        }
        return try Proc.run(dwarfdump, ["--debug-info", dsymURL.path])
    }
}

private enum Proc {
    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(tool.lastPathComponent) failed (\(process.terminationStatus)): \(out)")
        }
        return out
    }
}
