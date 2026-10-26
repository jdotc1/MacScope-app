import Foundation
import XCTest
@testable import MacScope

/// Recovering Swift protocol conformances from `__swift5_proto`. Each `ProtocolConformanceDescriptor`
/// pairs a conforming type (typeRef@4, interpreted by the flags' TypeReferenceKind) with a protocol
/// (a relative-indirectable pointer@0). Tier-1: in-module direct conformances, verified firsthand
/// against the descriptor bytes. Real-binary oracle: a swiftc binary whose conformances are also
/// confirmed by the `…Mc` mangled symbols (`nm` + `swift-demangle`).
final class SwiftConformanceTests: XCTestCase {

    func testRecoversInModuleConformances() throws {
        let url = try RealSwiftConformanceBinary.build()
        let snapshot = try AnalysisEngine().analyze(url: url)

        // Ground truth (nm …Mc + swift-demangle): c.Widget : c.Greeter and c.Gadget : c.Greeter.
        func conforms(_ type: String, to proto: String) -> Bool {
            snapshot.swiftConformances.contains { $0.typeName == type && $0.protocolName == proto }
        }
        XCTAssertTrue(conforms("Widget", to: "Greeter"), "Widget: Greeter must be recovered")
        XCTAssertTrue(conforms("Gadget", to: "Greeter"), "Gadget: Greeter must be recovered")

        // The Swift interface export annotates the type with its conformance.
        let rendered = SwiftInterfaceRenderer.render(types: snapshot.swiftTypes, conformances: snapshot.swiftConformances)
        XCTAssertTrue(rendered.contains("Widget: Greeter") || rendered.contains("Widget : Greeter"),
                      "the rendered interface must annotate the conformance. Got:\n\(rendered)")
    }

    /// Tier-2: conformances to EXTERNAL (stdlib) protocols, whose ProtocolConformanceDescriptor.protocol
    /// is an indirect bind to the protocol's `…Mp` descriptor symbol (e.g. `_$sSQMp` = Swift.Equatable).
    /// Ground truth from the binary's own `…Mc` symbols (nm + swift-demangle).
    func testRecoversExternalProtocolConformances() throws {
        let url = try RealSwiftConformanceBinary.buildExternal()
        let snapshot = try AnalysisEngine().analyze(url: url)
        func conforms(_ type: String, to proto: String) -> Bool {
            snapshot.swiftConformances.contains { $0.typeName == type && $0.protocolName == proto }
        }
        // Two-char substitutions (SQ/SH/SL/SE/Se):
        XCTAssertTrue(conforms("Point", to: "Equatable"), "Point: Equatable (SQ) must resolve")
        XCTAssertTrue(conforms("Point", to: "Hashable"), "Point: Hashable (SH) must resolve")
        XCTAssertTrue(conforms("Point", to: "Comparable"), "Point: Comparable (SL) must resolve")
        XCTAssertTrue(conforms("Point", to: "Encodable"), "Point: Encodable (SE) must resolve")
        XCTAssertTrue(conforms("Point", to: "Decodable"), "Point: Decodable (Se) must resolve")
        // Length-prefixed stdlib protocol (s23CustomStringConvertible):
        XCTAssertTrue(conforms("Point", to: "CustomStringConvertible"),
                      "Point: CustomStringConvertible (length-prefixed) must resolve")
        // Never fabricate: the protocol names must be the clean simple names, no mangling residue.
        XCTAssertFalse(snapshot.swiftConformances.contains { $0.protocolName.contains("$") || $0.protocolName.contains("Mp") },
                       "no recovered protocol name may carry mangling residue")
    }

    func testExtractsStdlibProtocolMetadataSubstitutions() {
        // xcrun swift-demangle '$sStMp' ---> protocol descriptor for Swift.IteratorProtocol
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sStMp", suffix: "Mp"), "IteratorProtocol")
        // xcrun swift-demangle '$sSTMp' ---> protocol descriptor for Swift.Sequence
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSTMp", suffix: "Mp"), "Sequence")
        // xcrun swift-demangle '$sSlMp' ---> protocol descriptor for Swift.Collection
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSlMp", suffix: "Mp"), "Collection")
        // xcrun swift-demangle '$sSLMp' ---> protocol descriptor for Swift.Comparable
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSLMp", suffix: "Mp"), "Comparable")
        // xcrun swift-demangle '$sSeMp' ---> protocol descriptor for Swift.Decodable
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSeMp", suffix: "Mp"), "Decodable")
        // xcrun swift-demangle '$sSEMp' ---> protocol descriptor for Swift.Encodable
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSEMp", suffix: "Mp"), "Encodable")
        // xcrun swift-demangle '$sSyMp' ---> protocol descriptor for Swift.StringProtocol
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSyMp", suffix: "Mp"), "StringProtocol")
        // xcrun swift-demangle '$sSYMp' ---> protocol descriptor for Swift.RawRepresentable
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSYMp", suffix: "Mp"), "RawRepresentable")
    }

    func testExtractsStdlibNominalTypeMetadataSubstitutions() {
        // xcrun swift-demangle '$sSaMn' ---> nominal type descriptor for Swift.Array
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSaMn", suffix: "Mn"), "Array")
        // xcrun swift-demangle '$sSDMn' ---> nominal type descriptor for Swift.Dictionary
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSDMn", suffix: "Mn"), "Dictionary")
        // xcrun swift-demangle '$sSSMn' ---> nominal type descriptor for Swift.String
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSSMn", suffix: "Mn"), "String")
        // xcrun swift-demangle '$sSqMn' ---> nominal type descriptor for Swift.Optional
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSqMn", suffix: "Mn"), "Optional")
        // xcrun swift-demangle '$sSJMn' ---> nominal type descriptor for Swift.Character
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSJMn", suffix: "Mn"), "Character")
        // xcrun swift-demangle '$sSNMn' ---> nominal type descriptor for Swift.ClosedRange
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSNMn", suffix: "Mn"), "ClosedRange")
        // xcrun swift-demangle '$sSOMn' ---> nominal type descriptor for Swift.ObjectIdentifier
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$sSOMn", suffix: "Mn"), "ObjectIdentifier")
    }

    func testMetadataSubstitutionLookupIsSuffixKeyed() {
        // xcrun swift-demangle '$sSTMn' ---> nominal type descriptor for Swift.Sequence
        // ST is still a protocol code because '$sSTMp' resolves; the Mn discriminator keeps it out.
        XCTAssertNil(SwiftMetadataParser._extractBoundSymbolName("_$sSTMn", suffix: "Mn"))
        // xcrun swift-demangle '$sSaMp' ---> $sSaMp
        XCTAssertNil(SwiftMetadataParser._extractBoundSymbolName("_$sSaMp", suffix: "Mp"))
        // xcrun swift-demangle '$ss23CustomStringConvertibleMp' ---> protocol descriptor for Swift.CustomStringConvertible
        XCTAssertEqual(SwiftMetadataParser._extractBoundSymbolName("_$ss23CustomStringConvertibleMp", suffix: "Mp"),
                       "CustomStringConvertible")
        // xcrun swift-demangle '$s0B3KeyMp' ---> $s0B3KeyMp
        XCTAssertNil(SwiftMetadataParser._extractBoundSymbolName("_$s0B3KeyMp", suffix: "Mp"))
    }

    /// Corpus differential: cross-check the FULL recovered conformance set against the binary's own
    /// `…Mc` symbols (nm + swift-demangle) on a DIVERSE fixture (struct/class/enum; in-module + many
    /// external protocols). The strict assertion is ZERO fabrication — every recovered conformance must
    /// be a real one swift-demangle confirms; a wrong extraction would surface a (type, protocol) pair
    /// that isn't in the ground truth. Plus a coverage floor so the parser isn't trivially empty.
    func testConformancesMatchSwiftDemangleGroundTruth() throws {
        let url = try RealSwiftConformanceBinary.compile("""
        protocol Drawable { func draw() }
        protocol Named { var name: String { get } }
        struct Circle: Drawable, Equatable, Hashable, CustomStringConvertible {
            var r: Int
            func draw() {}
            var description: String { "c" }
        }
        final class Box: Drawable, Named { var name: String { "box" }; func draw() {} }
        enum Suit: Int, CaseIterable, Comparable {
            case spade, heart
            static func < (a: Suit, b: Suit) -> Bool { a.rawValue < b.rawValue }
        }
        print(Circle(r: 1) == Circle(r: 2), Box().name, Suit.allCases.count)
        """, label: "swiftconf-corpus")

        let groundTruth = try Self.conformanceGroundTruth(url)
        try XCTSkipIf(groundTruth.isEmpty, "no …Mc symbols recovered (stripped?) — nothing to differential")

        let snapshot = try AnalysisEngine().analyze(url: url)
        let recovered = Set(snapshot.swiftConformances.map { "\($0.typeName):\($0.protocolName)" })

        // STRICT: no recovered conformance may be absent from the swift-demangle ground truth.
        let fabricated = recovered.subtracting(groundTruth)
        XCTAssertTrue(fabricated.isEmpty,
                      "fabricated conformances not confirmed by swift-demangle: \(fabricated.sorted())")
        // Coverage floor (some substitutions/kinds remain unhandled — RawRepresentable etc.).
        let hit = groundTruth.intersection(recovered).count
        XCTAssertGreaterThan(Double(hit) / Double(groundTruth.count), 0.6,
                             "recovered \(hit)/\(groundTruth.count); missed \(groundTruth.subtracting(recovered).sorted())")
    }

    /// Ground-truth `Type:Protocol` pairs from the binary's `…Mc` conformance-descriptor symbols via
    /// `nm` + `swift-demangle` ("protocol conformance descriptor for <Mod>.<Type> : <Mod>.<Proto> in …").
    private static func conformanceGroundTruth(_ url: URL) throws -> Set<String> {
        func run(_ args: [String], stdin: String? = nil) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            let inPipe = Pipe(); if stdin != nil { p.standardInput = inPipe }
            guard (try? p.run()) != nil else { return "" }
            // Drain before feeding stdin: a filter that writes while reading would otherwise
            // block on a full stdout pipe while this thread blocks writing its input.
            let drain = CoreTestPipeDrain(out)
            if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)); try? inPipe.fileHandleForWriting.close() }
            p.waitUntilExit()
            return drain.text()
        }
        let mcSymbols = run(["nm", url.path]).split(separator: "\n")
            .compactMap { $0.split(separator: " ").last.map(String.init) }
            .filter { $0.contains("$s") && $0.hasSuffix("Mc") }
        guard !mcSymbols.isEmpty else { return [] }
        let demangled = run(["swift-demangle"], stdin: mcSymbols.joined(separator: "\n"))
        var pairs: Set<String> = []
        for line in demangled.split(separator: "\n") {
            guard let range = line.range(of: "protocol conformance descriptor for ") else { continue }
            let body = line[range.upperBound...]
            guard let colon = body.range(of: " : ") else { continue }
            let typePart = String(body[..<colon.lowerBound])
            var protoPart = String(body[colon.upperBound...])
            if let inRange = protoPart.range(of: " in ") { protoPart = String(protoPart[..<inRange.lowerBound]) }
            let type = typePart.split(separator: ".").last.map(String.init) ?? typePart
            let proto = protoPart.split(separator: ".").last.map(String.init) ?? protoPart
            pairs.insert("\(type):\(proto)")
        }
        return pairs
    }
}

/// Compiles a tiny Swift binary with two in-module conformances to a local protocol. Skipped if
/// swiftc is unavailable.
private enum RealSwiftConformanceBinary {
    static func buildExternal() throws -> URL {
        try compile("""
        struct Point: Equatable, Hashable, Comparable, Codable, CustomStringConvertible {
            var x: Int
            static func < (a: Point, b: Point) -> Bool { a.x < b.x }
            var description: String { "p\\(x)" }
        }
        print(Point(x: 1) == Point(x: 2))
        """, label: "swiftconf-ext")
    }

    static func build() throws -> URL {
        try compile("""
        protocol Greeter { func greet() -> Int }
        struct Widget: Greeter { func greet() -> Int { return 42 } }
        final class Gadget: Greeter { func greet() -> Int { return 7 } }
        print(Widget().greet() + Gadget().greet())
        """, label: "swiftconf")
    }

    static func compile(_ swift: String, label: String) throws -> URL {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else {
            throw XCTSkip("xcrun unavailable on this host")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("c.swift")
        try swift.write(to: source, atomically: true, encoding: .utf8)
        let binary = dir.appendingPathComponent("c")
        let process = Process()
        process.executableURL = xcrun
        process.arguments = ["swiftc", "-O", "-o", binary.path, source.path]
        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        let output = drain.text()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("could not build the Swift conformance fixture: " + output)
        }
        return binary
    }
}
