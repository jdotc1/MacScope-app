import XCTest
@testable import MacScope

final class CTypeHeaderPreprocessorGuardTests: XCTestCase {
    func testTrigraphPreprocessingCannotImportInactiveDeclarations() {
        let source = """
        struct Before { int value; };
        ??=if 0
        struct Skipped { int value; };
        struct Inactive { int value; };
        ??=endif
        """
        for input in [source, "// continued comment ??/\nstruct Hidden { int value; };",
                      "struct A ??< int x; ??>;"] {
            let result = CTypeHeaderParser.parse(input)
            XCTAssertTrue(result.types.isEmpty, "\(result.types)")
            XCTAssertTrue(result.diagnostics.contains { $0.contains("Clang import") }, "\(result.diagnostics)")
        }
    }

    func testInactiveBranchCannotImportAndPackStillWorks() throws {
        for directive in ["#if 0", "#ifdef FEATURE", "#include <header.h>", "#define COUNT 2",
                          "#undef COUNT", "#else", "#endif", "#pragma unknown", "#pragmapack(1)", "%:if 0",
                          "#if" + "\\\n" + " 0"] {
            let result = CTypeHeaderParser.parse("struct Before { int x; };\n" + directive + "\nstruct Hidden { int x; };")
            XCTAssertTrue(result.types.isEmpty, directive)
            XCTAssertTrue(result.diagnostics.contains { $0.contains("Clang import") }, directive)
        }
        let result = CTypeHeaderParser.parse("""
        /* #if 0 */
        // #include <ignored.h>
        #pragma pack(push, 1)
        struct Packed { char a; int b; };
        #pragma pack(pop)
        struct Normal { char a; int b; };
        """)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        XCTAssertEqual(TypeDefinition.size(ofType: "Packed", in: types), 5)
        XCTAssertEqual(TypeDefinition.size(ofType: "Normal", in: types), 8)
    }
}
