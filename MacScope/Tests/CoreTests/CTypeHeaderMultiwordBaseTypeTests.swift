import Foundation
import XCTest
@testable import MacScope

final class CTypeHeaderMultiwordBaseTypeTests: XCTestCase {
    func testSizeTypedefAdmitsPrototype() throws {
        let result = CTypeHeaderParser.parse("typedef long unsigned int size_t; void f(void *p, size_t n);")
        XCTAssertTrue(result.diagnostics.isEmpty, result.diagnostics.joined(separator: "\n"))
        XCTAssertEqual(result.skippedPrototypeCount, 0)
        let prototype = try XCTUnwrap(result.prototypes.first)
        XCTAssertEqual(prototype.signature.args.map(\.type), ["void *", "uint64_t"])
        XCTAssertEqual(prototype.signature.args.map(\.name), ["p", "n"])
    }

    func testIntegerSpecifierOrdersPreserveCanonicalTypeAndDarwinLayout() throws {
        let groups: [(String, Int, [String])] = [
            ("char", 1, ["char"]),
            ("int8_t", 1, ["signed char"]),
            ("uint8_t", 1, ["unsigned char"]),
            ("int16_t", 2, ["short", "short int", "signed short", "signed short int"]),
            ("uint16_t", 2, ["unsigned short", "unsigned short int"]),
            ("int32_t", 4, ["int", "signed", "signed int"]),
            ("uint32_t", 4, ["unsigned", "unsigned int"]),
            ("int64_t", 8, ["long", "long int", "signed long", "signed long int",
                             "long long", "long long int", "signed long long", "signed long long int"]),
            ("uint64_t", 8, ["unsigned long", "unsigned long int", "unsigned long long", "unsigned long long int"]),
        ]
        for (canonical, size, spellings) in groups {
            for spelling in spellings {
                for words in permutations(spelling.components(separatedBy: " ")) {
                    let ordered = words.joined(separator: " ")
                    let result = CTypeHeaderParser.parse("typedef \(ordered) T; struct S { \(ordered) value; }; void f(\(ordered) n);")
                    XCTAssertTrue(result.diagnostics.isEmpty, ordered + ": " + result.diagnostics.joined(separator: "\n"))
                    let catalog = Dictionary(result.types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                    XCTAssertEqual(catalog["T"]?.fields.first?.type, canonical, ordered)
                    XCTAssertEqual(catalog["S"]?.fields.first?.type, canonical, ordered)
                    XCTAssertEqual(result.prototypes.first?.signature.args.first?.type, canonical, ordered)
                    XCTAssertEqual(TypeDefinition.size(ofType: "T", in: catalog), size, ordered)
                    XCTAssertEqual(TypeDefinition.alignment(ofType: "T", in: catalog), size, ordered)
                }
            }
        }
    }

    func testQualifiersAtEverySpecifierBoundary() {
        let words = ["long", "unsigned", "int"]
        for constPosition in 0...words.count {
            var qualified = words
            qualified.insert("const", at: constPosition)
            for volatilePosition in 0...qualified.count {
                var both = qualified
                both.insert("volatile", at: volatilePosition)
                let spelling = both.joined(separator: " ")
                let result = CTypeHeaderParser.parse("typedef \(spelling) T; void f(\(spelling) n);")
                XCTAssertTrue(result.diagnostics.isEmpty, spelling)
                XCTAssertEqual(result.types.first?.fields.first?.type, "uint64_t", spelling)
                let qualifiers = both.filter { $0 == "const" || $0 == "volatile" }
                XCTAssertEqual(result.prototypes.first?.signature.args.first?.type,
                               (qualifiers + ["uint64_t"]).joined(separator: " "), spelling)
            }
        }
    }

    func testUnsignedLongLongSpellingsAreEquivalent() {
        let result = CTypeHeaderParser.parse("void f(unsigned long long a, long long unsigned int b);")
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.prototypes.first?.signature.args.map(\.type), ["uint64_t", "uint64_t"])
    }

    func testComplexDoubleStillSkippedWithDiagnostic() {
        let result = CTypeHeaderParser.parse("typedef _Complex double Complex; void f(_Complex double value);")
        XCTAssertTrue(result.types.isEmpty)
        XCTAssertTrue(result.prototypes.isEmpty)
        XCTAssertEqual(result.skippedPrototypeCount, 1)
        XCTAssertEqual(result.diagnostics, [
            "Skipped `typedef … Complex`: unsupported base type “_Complex double”.",
            "Skipped function prototype `f`: unresolved or unsupported declaration.",
        ])
    }

    func testInvalidSpecifierCombinationsRemainUnsupported() {
        for spelling in ["signed unsigned int", "long long long", "short long", "int int",
                         "unsigned unsigned", "char int", "unsigned float", "long mystery"] {
            XCTAssertNil(CTypeHeaderParser.normalizePrimitive(words: spelling.components(separatedBy: " ")), spelling)
        }
    }

    func testSyntheticJPEGCreateCompressHasThreeTypedArguments() {
        let result = CTypeHeaderParser.parse("""
        typedef struct jpeg_compress_struct *j_compress_ptr;
        typedef long unsigned int size_t;
        void jpeg_CreateCompress(j_compress_ptr cinfo, int version, size_t structsize);
        """)
        // The catalog reports a forward-only record, while the prototype
        // parser can still preserve its nominal pointer type.
        XCTAssertEqual(result.diagnostics, ["Skipped a struct/union without a `{ … }` body."])
        XCTAssertEqual(result.skippedPrototypeCount, 0)
        XCTAssertEqual(result.prototypes.count, 1)
        XCTAssertEqual(result.prototypes.first?.signature.args.map(\.type), ["struct jpeg_compress_struct *", "int32_t", "uint64_t"])
        XCTAssertEqual(result.prototypes.first?.signature.args.map(\.name), ["cinfo", "version", "structsize"])
    }

    // Header-only admission measurement; never analyzes a binary or runs the witness.
    func testPinnedLibjpegHeaderRemainingPrototypeSkips() throws {
        let fixture = TestSourceRoot.url.appendingPathComponent("MacScope/Tests/CoreTests/Fixtures/libjpeg-turbo-3.2.0")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-E", "-P", "-x", "c", "-I", fixture.path, "-"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("#include \"public-layout.c\"\n#include \"jpegint.h\"\n".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Clang preprocessing failed")
        guard process.terminationStatus == 0 else { return }
        let result = CTypeHeaderParser.parse(String(decoding: data, as: UTF8.self))
        let remaining = result.diagnostics.filter { $0.hasPrefix("Skipped function prototype") }
        print("H1b header-only admission: 5 -> \(result.skippedPrototypeCount) skipped; \(result.prototypes.count) admitted")
        remaining.forEach { print("H1b remaining: \($0)") }
        // H3: jcopy_block_row now imports through the nominal JBLOCK array typedef.
        XCTAssertEqual(result.skippedPrototypeCount, 0)
        // H3: admitting jcopy_block_row adds one prototype.
        XCTAssertEqual(result.prototypes.count, 115)
        // H3: jcopy_block_row was the final skipped prototype.
        XCTAssertEqual(remaining, [])
        for name in ["jpeg_CreateCompress", "jpeg_CreateDecompress", "jzero_far"] {
            XCTAssertTrue(result.prototypes.contains { $0.name == name }, name)
        }
        XCTAssertFalse(result.diagnostics.contains { $0.contains("unsupported base type “long unsigned int”") })
    }

    private func permutations(_ words: [String]) -> [[String]] {
        guard !words.isEmpty else { return [[]] }
        return Set(words).sorted().flatMap { word in
            var rest = words
            rest.remove(at: rest.firstIndex(of: word)!)
            return permutations(rest).map { [word] + $0 }
        }
    }
}
