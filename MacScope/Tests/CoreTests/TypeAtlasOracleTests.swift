import XCTest
import MacScopeParserEngines
@testable import MacScope

/// Three compile-once specimens, compared with the independent go-macho reader.
/// Specimens are not rebuilt. The developer oracle is exercised here only, never by analysis.
@MainActor
final class TypeAtlasOracleTests: XCTestCase {
    private struct Row: Decodable, Equatable {
        var name: String
        var address: UInt64
        var kind: String?
        var superclass: String?
        var `class`: String?
        var `protocol`: String?
        var typeAddress: UInt64?
    }
    private struct Golden: Decodable {
        struct Fixture: Decodable { var path: String }
        struct Inventory: Decodable, Equatable {
            var status: String
            var inventories: [String: [Row]]
            var errors: [String: String]?
        }
        var fixture: Fixture
        var inventory: Inventory
    }

    func testAuthoredTypeCatalogMatchesGoMachoGoldens() throws {
        for id in ["type-atlas-swift-app", "type-atlas-mixed", "type-atlas-objc"] {
            let goldenURL = TestSourceRoot.url.appendingPathComponent("Scripts/parser-oracles/goldens/\(id).json")
            let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: goldenURL))
            XCTAssertEqual(golden.inventory.status, "parsed", id)
            XCTAssertTrue(golden.inventory.errors?.isEmpty ?? true, id)
            let bytes = try Data(contentsOf: TestSourceRoot.url.appendingPathComponent(golden.fixture.path))
            let oracleJSON = try XCTUnwrap(NativeParserEngines.document(for: bytes, call: macscope_gomacho_type_inventory))
            let currentOracle = try JSONDecoder().decode(Golden.Inventory.self, from: oracleJSON)
            XCTAssertEqual(currentOracle, golden.inventory, id + " changed bounds preserve valid golden metadata")
            let parsed = try MachOParser().parse(bytes)
            let catalog = ImageTypeCatalogBuilder.build(
                slot: .primary, objcClasses: parsed.objectiveCMetadata.classes,
                objcCategories: parsed.objectiveCMetadata.categories, objcProtocols: parsed.objectiveCMetadata.protocols,
                swiftTypes: parsed.swiftTypes, swiftConformances: parsed.swiftConformances,
                xrefs: [], objcSelectors: [:], objcClassReferences: [:])
            let inventory = golden.inventory.inventories
            XCTAssertEqual(Set(inventory.keys), Set([
                "objcClasses", "objcCategories", "objcProtocols",
                "swiftTypes", "swiftProtocols", "swiftConformances"
            ]), id + " all inventory domains must be present")
            for entry in catalog.entries where entry.evidence == .descriptor {
                guard case .address = entry.id.key else {
                    XCTFail(id + " descriptor-backed row lost its address: " + entry.name)
                    continue
                }
            }
            func key(_ name: String, _ address: UInt64, _ detail: String = "") -> String {
                "\(name)|\(address)|\(detail)"
            }
            func entries(_ kind: TypeAtlasKind) -> [TypeAtlasEntry] { catalog.entries.filter { $0.kind == kind } }
            func address(_ entry: TypeAtlasEntry) -> UInt64? {
                if case let .address(value) = entry.id.key { return value }
                return nil
            }
            let classes = Set(entries(.objcClass).compactMap { entry in address(entry).map { key(entry.name, $0, entry.superclass ?? "") } })
            XCTAssertEqual(classes, Set((inventory["objcClasses"] ?? []).map { key($0.name, $0.address, $0.superclass ?? "") }), id + " ObjC classes")
            let categories = Set(entries(.objcCategory).compactMap { entry in address(entry).map { key(entry.name, $0) } })
            XCTAssertEqual(categories, Set((inventory["objcCategories"] ?? []).map { key("\($0.class ?? "") (\($0.name))", $0.address) }), id + " ObjC categories")
            // Name-only external adoptions are intentionally not descriptor declarations.
            let protocols = Set(entries(.objcProtocol).compactMap { entry in address(entry).map { key(entry.name, $0) } })
            XCTAssertEqual(protocols, Set((inventory["objcProtocols"] ?? []).map { key($0.name, $0.address) }), id + " ObjC protocols")
            for (kind, raw) in [(TypeAtlasKind.swiftClass, "class"), (.swiftStruct, "struct"), (.swiftEnum, "enum")] {
                let names = Set(entries(kind).compactMap { entry in address(entry).map { key(entry.name, $0) } })
                XCTAssertEqual(names, Set((inventory["swiftTypes"] ?? []).filter { $0.kind == raw }.map { key($0.name, $0.address) }), id + " Swift " + raw)
            }
            let oracleConformances = inventory["swiftConformances"] ?? []
            let external = oracleConformances.filter { ($0.protocol ?? "").hasPrefix("_$s") }
            XCTAssertEqual(Set(external.map { "\($0.name)|\($0.protocol ?? "")" }),
                           id == "type-atlas-swift-app" ? ["Color|_$sSQMp", "Color|_$sSHMp"] : [],
                           id + " explicitly recorded external-protocol spellings")
            let module = id == "type-atlas-swift-app" ? "TypeAtlasSwift." : "TypeAtlasMixed."
            // The oracle preserves raw external protocol symbols. The native parser
            // resolves these two known Swift standard-library protocol descriptors.
            // Do not drop external rows or apply a general demangling guess.
            let externalNames = ["_$sSQMp": "Equatable", "_$sSHMp": "Hashable"]
            let expected = try oracleConformances.map { row in
                let fullName = try XCTUnwrap(row.protocol, id + " conformance protocol")
                let name = externalNames[fullName]
                    ?? (fullName.hasPrefix(module) ? String(fullName.dropFirst(module.count)) : fullName)
                return key(row.name, row.address, "\(name)|\(try XCTUnwrap(row.typeAddress))")
            }
            let actual = try parsed.swiftConformances.map { row in
                key(row.typeName, try XCTUnwrap(row.descriptorAddress),
                    "\(row.protocolName)|\(try XCTUnwrap(row.typeDescriptorAddress))")
            }
            XCTAssertEqual(Set(actual), Set(expected), id + " Swift conformance identities and names")
            for conformance in parsed.swiftConformances {
                XCTAssertTrue(catalog.entries(named: conformance.typeName).contains { $0.conformances.contains(conformance.protocolName) }, id)
            }
            // Standalone Swift protocols are an explicit catalog limitation. The oracle
            // retains them; the disagreement ledger names each missing declaration.
            XCTAssertEqual(Set((inventory["swiftProtocols"] ?? []).map(\.name)),
                           id == "type-atlas-swift-app" ? ["Shape"] : id == "type-atlas-mixed" ? ["Runner"] : [], id)
            let generics = catalog.entries(named: "Generic")
            XCTAssertEqual(generics.count, id == "type-atlas-swift-app" ? 1 : 0, id)
            for entry in generics {
                XCTAssertFalse(entry.members.isEmpty, id + " generic fields must remain represented")
                XCTAssertTrue(entry.members.allSatisfy { $0.offset == nil && $0.evidence == .unknown })
            }
        }
    }
}
