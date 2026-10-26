import Foundation
import XCTest
@testable import MacScope

final class SwiftMetadataCrossSeamTests: XCTestCase {

    func testDemangleTypeMatchesExternalOracleHardFloor() throws {
        let floor = [
            ("SaySiG", "[Swift.Int]"),
            ("SDySSSiG", "[Swift.String : Swift.Int]"),
            ("SiSg", "Swift.Int?"),
            ("ShySiG", "Swift.Set<Swift.Int>"),
            ("Si_Sft", "(Swift.Int, Swift.Float)"),
        ]

        for (mangled, expected) in floor {
            let oracle = try SwiftTypeOracle.demangleType(mangled)
            XCTAssertEqual(oracle, expected, "unexpected external oracle output for \(mangled)")
            XCTAssertEqual(SwiftDemangler.demangleType(mangled), oracle)
        }
    }

    func testDemangleTypeReturnsNilForOracleInvalidInputs() throws {
        for mangled in ["notatype", "SaySi", "SaySiGx", "SiSgX", "SiS", "SiSgt"] {
            XCTAssertEqual(try SwiftTypeOracle.demangleType(mangled), "<<invalid type>>")
            XCTAssertNil(SwiftDemangler.demangleType(mangled), "\(mangled) must not fabricate a type")
        }
    }

    func testPureSwiftStdlibNameStripsOnlySwiftModuleQualifiers() {
        XCTAssertEqual(SwiftMetadataParser.pureSwiftStdlibName("[Swift.Int]"), "[Int]")
        XCTAssertEqual(SwiftMetadataParser.pureSwiftStdlibName("[Swift.String : Swift.Int]"), "[String : Int]")
        XCTAssertEqual(SwiftMetadataParser.pureSwiftStdlibName("Swift.Set<Swift.Int>"), "Set<Int>")
        XCTAssertEqual(SwiftMetadataParser.pureSwiftStdlibName("(Swift.Int, Swift.Float)"), "(Int, Float)")
        XCTAssertEqual(SwiftDemangler.demangleType("So8NSObjectC"), "__C.NSObject")
        XCTAssertEqual(SwiftDemangler.demangleType("10Foundation4DateV"), "Foundation.Date")
        XCTAssertNil(SwiftMetadataParser.pureSwiftStdlibName("__C.NSObject"))
        XCTAssertNil(SwiftMetadataParser.pureSwiftStdlibName("Foundation.Date"))
        XCTAssertNil(SwiftMetadataParser.pureSwiftStdlibName("MySwift.Foo"))
        // Bare generic-parameter / archetype outputs must NOT be fabricated as concrete types.
        XCTAssertNil(SwiftMetadataParser.pureSwiftStdlibName("A"))
        XCTAssertNil(SwiftMetadataParser.pureSwiftStdlibName("A?"))
        XCTAssertNil(SwiftMetadataParser.pureSwiftStdlibName("Set<A>"))
        XCTAssertNil(SwiftMetadataParser.pureSwiftStdlibName("[A]"))
        XCTAssertNil(SwiftMetadataParser.pureSwiftStdlibName("(A, B)"))
        // …but concrete stdlib names that merely start uppercase are kept.
        XCTAssertEqual(SwiftMetadataParser.pureSwiftStdlibName("UInt"), "UInt")
        XCTAssertEqual(SwiftMetadataParser.pureSwiftStdlibName("[Int]"), "[Int]")
    }

    func testFieldTypesRoutePureStdlibButKeepObjCImportedRaw() throws {
        let data = try CrossSeamSwiftBinary.build(source: """
        import Foundation

        public struct LocalInner { public let tag: Int }

        public struct CrossSeamFields {
            public let scalarInt: Int
            public let scalarString: String
            public let arrayInt: [Int]
            public let dictionary: [String: Int]
            public let optionalInt: Int?
            public let setInt: Set<Int>
            public let tuple: (Int, Float)
            public let nestedArray: [[Int]]
            public let object: NSObject
            public let number: NSNumber
            public let objectArray: [NSObject]
            public let date: Date
            public let local: LocalInner
            public let localArray: [LocalInner]
            public let localOptional: LocalInner?
        }
        """)
        let machO = try MachOParser().parse(data, options: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: true,
            parseCodeSignature: false
        ))
        let type = try XCTUnwrap(machO.swiftTypes.first(where: { $0.name == "CrossSeamFields" }))
        let fields = Dictionary(uniqueKeysWithValues: type.fields.map { ($0.name, $0) })

        XCTAssertEqual(fields["scalarInt"]?.typeName, "Int")
        XCTAssertEqual(fields["scalarString"]?.typeName, "String")
        XCTAssertEqual(fields["arrayInt"]?.typeName, "[Int]")
        XCTAssertEqual(fields["arrayInt"]?.mangledTypeName, "SaySiG")
        XCTAssertEqual(fields["dictionary"]?.typeName, "[String : Int]")
        XCTAssertEqual(fields["dictionary"]?.mangledTypeName, "SDySSSiG")
        XCTAssertEqual(fields["optionalInt"]?.typeName, "Int?")
        XCTAssertEqual(fields["optionalInt"]?.mangledTypeName, "SiSg")
        XCTAssertEqual(fields["setInt"]?.typeName, "Set<Int>")
        XCTAssertEqual(fields["setInt"]?.mangledTypeName, "ShySiG")
        XCTAssertEqual(fields["tuple"]?.typeName, "(Int, Float)")
        XCTAssertEqual(fields["tuple"]?.mangledTypeName, "Si_Sft")
        XCTAssertEqual(fields["nestedArray"]?.typeName, "[[Int]]")
        XCTAssertEqual(fields["nestedArray"]?.mangledTypeName, "SaySaySiGG")

        XCTAssertNil(fields["object"]?.typeName)
        XCTAssertEqual(fields["object"]?.mangledTypeName, "So8NSObjectC")
        XCTAssertNil(fields["number"]?.typeName)
        XCTAssertEqual(fields["number"]?.mangledTypeName, "So8NSNumberC")
        XCTAssertNil(fields["objectArray"]?.typeName)
        XCTAssertEqual(fields["objectArray"]?.mangledTypeName, "SaySo8NSObjectCG")
        XCTAssertNil(fields["date"]?.typeName)

        XCTAssertEqual(fields["local"]?.typeName, "LocalInner")
        XCTAssertEqual(fields["localArray"]?.typeName, "[LocalInner]")
        XCTAssertEqual(fields["localOptional"]?.typeName, "LocalInner?")
    }

    func testCompoundSymbolicRefsMatchSwiftcSourceTruth() throws {
        let data = try CrossSeamSwiftBinary.build(source: """
        public struct LocalInner { public let tag: Int }
        public struct Foo<T> { public let value: T }
        public struct Outer {
            public struct Inner { public let code: Int }
        }

        public struct CompoundFields {
            public let stringArray: [String]
            public let localArray: [LocalInner]
            public let localOptional: LocalInner?
            public let genericLocal: Foo<LocalInner>
            public let nestedLocal: Outer.Inner
            public let optionalGenericLocal: Foo<LocalInner>?
            public let optionalNestedGenericLocal: Foo<Outer.Inner>?
        }
        """)
        let machO = try MachOParser().parse(data, options: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: true,
            parseCodeSignature: false
        ))
        let type = try XCTUnwrap(machO.swiftTypes.first(where: { $0.name == "CompoundFields" }))
        let fields = Dictionary(uniqueKeysWithValues: type.fields.map { ($0.name, $0) })

        XCTAssertEqual(fields["stringArray"]?.typeName, "[String]")
        XCTAssertEqual(fields["localArray"]?.typeName, "[LocalInner]")
        XCTAssertEqual(fields["localOptional"]?.typeName, "LocalInner?")
        XCTAssertEqual(fields["genericLocal"]?.typeName, "Foo<LocalInner>")
        XCTAssertEqual(fields["nestedLocal"]?.typeName, "Outer.Inner")
        XCTAssertEqual(fields["optionalGenericLocal"]?.typeName, "Foo<LocalInner>?")
        XCTAssertEqual(fields["optionalNestedGenericLocal"]?.typeName, "Foo<Outer.Inner>?")
    }

    func testSplicedNominalTextMatchesExternalDemangleOracleBeforeModuleStrip() throws {
        let cases = [
            ("Say1M10LocalInnerVG", "[M.LocalInner]"),
            ("1M10LocalInnerVSg", "M.LocalInner?"),
            ("1M3FooVy1M10LocalInnerVG", "M.Foo<M.LocalInner>"),
            ("1M5OuterV5InnerV", "M.Outer.Inner"),
            ("1M3FooVy1M10LocalInnerVGSg", "M.Foo<M.LocalInner>?"),
            ("1M3FooVy1M5OuterV5InnerVGSg", "M.Foo<M.Outer.Inner>?"),
        ]

        for (mangled, expected) in cases {
            let oracle = try SwiftTypeOracle.demangleType(mangled)
            XCTAssertEqual(oracle, expected, "unexpected external oracle output for \(mangled)")
            XCTAssertEqual(SwiftDemangler.demangleType(mangled), oracle)
        }
    }

    func testExistentialCompoundSymbolicRefsStayHonestNil() throws {
        let data = try CrossSeamSwiftBinary.build(source: """
        public protocol LocalExistentialProtocol {}
        public struct ExistentialWitness: LocalExistentialProtocol { public init() {} }
        public struct ExistentialFields {
            public let value: any LocalExistentialProtocol
            public let maybe: (any LocalExistentialProtocol)?
        }
        """)
        let machO = try MachOParser().parse(data, options: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: true,
            parseCodeSignature: false
        ))
        let type = try XCTUnwrap(machO.swiftTypes.first(where: { $0.name == "ExistentialFields" }))
        let fields = Dictionary(uniqueKeysWithValues: type.fields.map { ($0.name, $0) })

        XCTAssertNil(fields["value"]?.typeName)
        XCTAssertNil(fields["maybe"]?.typeName)
        XCTAssertNotNil(fields["value"]?.mangledTypeName)
        XCTAssertNotNil(fields["maybe"]?.mangledTypeName)
    }

    func testResolvedFieldTypesNeverContradictSourceTruthCorpus() throws {
        let data = try CrossSeamSwiftBinary.build(source: """
        public protocol CorpusProtocol {}
        public struct LocalInner { public let tag: Int }
        public struct Foo<T> { public let value: T }
        public struct Outer {
            public struct Inner { public let code: Int }
        }
        public struct CorpusFields<T> {
            public let scalar: Int
            public let strings: [String]
            public let local: LocalInner
            public let localArray: [LocalInner]
            public let localOptional: LocalInner?
            public let localGeneric: Foo<LocalInner>
            public let nested: Outer.Inner
            public let nestedGenericOptional: Foo<Outer.Inner>?
            public let existential: any CorpusProtocol
            public let genericParam: T
        }
        """)
        let machO = try MachOParser().parse(data, options: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: true,
            parseCodeSignature: false
        ))
        let type = try XCTUnwrap(machO.swiftTypes.first(where: { $0.name == "CorpusFields" }))
        let fields = Dictionary(uniqueKeysWithValues: type.fields.map { ($0.name, $0) })
        let sourceTruth = [
            "scalar": "Int",
            "strings": "[String]",
            "local": "LocalInner",
            "localArray": "[LocalInner]",
            "localOptional": "LocalInner?",
            "localGeneric": "Foo<LocalInner>",
            "nested": "Outer.Inner",
            "nestedGenericOptional": "Foo<Outer.Inner>?",
        ]

        for (name, field) in fields {
            guard let rendered = field.typeName else { continue }
            guard let expected = sourceTruth[name] else {
                XCTFail("unexpected non-nil field render for \(name): \(rendered)")
                continue
            }
            XCTAssertEqual(rendered, expected,
                           "non-nil field render for \(name) must match source-declared truth")
        }
        XCTAssertNil(fields["existential"]?.typeName)
        XCTAssertNil(fields["genericParam"]?.typeName)
    }
}

private enum SwiftTypeOracle {
    static func demangleType(_ mangled: String) throws -> String {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else {
            throw XCTSkip("xcrun unavailable on this host")
        }
        let process = Process()
        process.executableURL = xcrun
        process.arguments = ["swift-demangle", "--compact", "--type", mangled]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        let output = drain.text()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("swift-demangle failed on this host")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum CrossSeamSwiftBinary {
    static func build(source sourceText: String) throws -> Data {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else {
            throw XCTSkip("xcrun unavailable on this host")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-crossseam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("M.swift")
        try sourceText.write(to: source, atomically: true, encoding: .utf8)
        let moduleCache = dir.appendingPathComponent("ModuleCache", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleCache, withIntermediateDirectories: true)

        let dylib = dir.appendingPathComponent("libM.dylib")
        try run(xcrun, [
            "swiftc",
            "-target", "arm64-apple-macos27.0",
            "-module-cache-path", moduleCache.path,
            "-emit-library",
            "-o", dylib.path,
            source.path,
        ], moduleCache: moduleCache)
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw XCTSkip("swiftc did not produce a dylib on this host")
        }
        return try Data(contentsOf: dylib)
    }

    private static func run(_ tool: URL, _ arguments: [String], moduleCache: URL) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = (ProcessInfo.processInfo.environment).merging([
            "CLANG_MODULE_CACHE_PATH": moduleCache.path,
            "SWIFT_MODULE_CACHE_PATH": moduleCache.path,
        ]) { _, new in new }
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        let output = drain.text()
        if process.terminationStatus != 0 {
            throw XCTSkip("\(tool.lastPathComponent) \(arguments.first ?? "") failed (\(process.terminationStatus)): \(output)")
        }
    }
}
