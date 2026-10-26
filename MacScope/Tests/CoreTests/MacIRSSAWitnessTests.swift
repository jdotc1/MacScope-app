import Foundation
import XCTest
@testable import MacScope

/// Acceptance over the existing single image witness pass. Expected addresses
/// are frozen machine producer/exit rows, independent of SSA version numbering.
struct SSAWitnessAcceptance {
    struct Case {
        let start: UInt64
        let producers: Set<UInt64>
        let namedRows: Set<UInt64>
        let exits: [UInt64]
    }
    static let valueCases: [Case] = [
        .init(start: 0x1438, producers: [0x1568, 0x1570, 0x15a0], namedRows: [0x1568, 0x1570, 0x15a0], exits: [0x15b0]),
        .init(start: 0x172c, producers: [0x185c, 0x1864, 0x1894], namedRows: [0x185c, 0x1864, 0x1894], exits: [0x18a4]),
        .init(start: 0x1cc8, producers: [0x1ee4, 0x1f30], namedRows: [0x1ee4, 0x1f30], exits: [0x1f5c]),
        .init(start: 0x21a8, producers: [0x22f0, 0x2334], namedRows: [0x22f0, 0x2334], exits: [0x2370]),
        .init(start: 0x25d8, producers: [0x27f4, 0x2840], namedRows: [0x27f4, 0x2840], exits: [0x286c]),
        .init(start: 0x2ab8, producers: [0x2c00, 0x2c44], namedRows: [0x2c00, 0x2c44], exits: [0x2c80]),
        .init(start: 0x972c, producers: [0x9880, 0x9900, 0x99b0, 0x99e0, 0x9a14, 0x996c], namedRows: [0x9880, 0x9900, 0x99b0, 0x99e0, 0x9a14, 0x996c], exits: [0x99a4]),
        .init(start: 0x1761c, producers: [0x17940, 0x17948, 0x17950, 0x17960, 0x17988, 0x179b0], namedRows: [0x17940, 0x17948, 0x17950, 0x17960, 0x17988, 0x179b0], exits: [0x179dc]),
        .init(start: 0x1b9b8, producers: [0x1b9dc, 0x1b9e8], namedRows: [0x1b9dc, 0x1b9e8], exits: [0x1b9e0, 0x1b9ec]),
        .init(start: 0x1c224, producers: [0x1c25c, 0x1c278], namedRows: [0x1c25c, 0x1c278], exits: [0x1c260, 0x1c288]),
        .init(start: 0x21038, producers: [0x21208, 0x2124c], namedRows: [0x21208, 0x2124c], exits: [0x2128c]),
        .init(start: 0x213e8, producers: [0x21464], namedRows: [0x21430, 0x21434, 0x21464], exits: [0x21474]),
        .init(start: 0x2177c, producers: [0x21828, 0x2184c], namedRows: [0x21828, 0x2184c], exits: [0x21858]),
        .init(start: 0x21ec8, producers: [0x22054], namedRows: [0x21ee8, 0x22030, 0x22054], exits: [0x22074]),
        .init(start: 0x22684, producers: [0x22710, 0x22724], namedRows: [0x22710, 0x22724], exits: [0x22730]),
        .init(start: 0x22b28, producers: [0x22cb4], namedRows: [0x22b48, 0x22c90, 0x22cb4], exits: [0x22cd4]),
        .init(start: 0x23e40, producers: [0x23f9c, 0x23fec, 0x2400c], namedRows: [0x23f9c, 0x23fec, 0x2400c], exits: [0x24040]),
        .init(start: 0x24048, producers: [0x240b0, 0x24204], namedRows: [0x240b0, 0x24204], exits: [0x24224]),
        .init(start: 0x24230, producers: [0x242d4, 0x244b4, 0x244dc], namedRows: [0x242d4, 0x244b4, 0x244dc], exits: [0x244fc]),
        .init(start: 0x24548, producers: [0x245d8, 0x25390], namedRows: [0x245d8, 0x25390], exits: [0x253b0]),
        .init(start: 0x2574c, producers: [0x258a8, 0x258f8, 0x25918], namedRows: [0x258a8, 0x258f8, 0x25918], exits: [0x2594c]),
        .init(start: 0x25954, producers: [0x259bc, 0x25b10], namedRows: [0x259bc, 0x25b10], exits: [0x25b30]),
        .init(start: 0x25b3c, producers: [0x25be0, 0x25dc0, 0x25de8], namedRows: [0x25be0, 0x25dc0, 0x25de8], exits: [0x25e08]),
        .init(start: 0x25e0c, producers: [0x25e9c, 0x26c54], namedRows: [0x25e9c, 0x26c54], exits: [0x26c74]),
        .init(start: 0x2c558, producers: [0x2c5b8, 0x2c68c], namedRows: [0x2c5b8, 0x2c68c], exits: [0x2c6a8]),
        .init(start: 0x2c6b4, producers: [0x2c714, 0x2c8a8, 0x2c8c0, 0x2c8cc], namedRows: [0x2c714, 0x2c8a8, 0x2c8c0, 0x2c8cc], exits: [0x2c8fc]),
        .init(start: 0x2cca4, producers: [0x2cd04, 0x2cddc], namedRows: [0x2cd04, 0x2cddc], exits: [0x2cdf8]),
        .init(start: 0x2ce04, producers: [0x2ce64, 0x2cff8, 0x2d010, 0x2d01c], namedRows: [0x2ce64, 0x2cff8, 0x2d010, 0x2d01c], exits: [0x2d04c]),
        .init(start: 0x2d3ac, producers: [0x2d40c, 0x2d4e4], namedRows: [0x2d40c, 0x2d4e4], exits: [0x2d500]),
        .init(start: 0x2d50c, producers: [0x2d56c, 0x2d700, 0x2d718, 0x2d724], namedRows: [0x2d56c, 0x2d700, 0x2d718, 0x2d724], exits: [0x2d754]),
        .init(start: 0x2df5c, producers: [0x2e3a4, 0x2e3c8, 0x2e35c], namedRows: [0x2e3a4, 0x2e3c8, 0x2e35c], exits: [0x2e3e8]),
        .init(start: 0x2f334, producers: [0x2f358, 0x2f380, 0x2f6e8], namedRows: [0x2f358, 0x2f380, 0x2f6e8], exits: [0x2f370]),
        .init(start: 0x2fbf0, producers: [0x2fe18], namedRows: [0x2fc10, 0x2fcc8, 0x2fe04, 0x2fe14, 0x2fe18], exits: [0x2fe38]),
        .init(start: 0x2fe3c, producers: [0x2fe78, 0x2fe8c], namedRows: [0x2fe78, 0x2fe8c], exits: [0x2fe98]),
        .init(start: 0x3337c, producers: [0x33398, 0x333ec, 0x33408], namedRows: [0x33398, 0x333ec, 0x33408], exits: [0x33414]),
        .init(start: 0x33500, producers: [0x33544, 0x33568, 0x335b0, 0x33660], namedRows: [0x33544, 0x33568, 0x335b0, 0x33660], exits: [0x33694]),
        .init(start: 0x3376c, producers: [0x337c0, 0x337e0, 0x33880, 0x3399c], namedRows: [0x337c0, 0x337e0, 0x33880, 0x3399c], exits: [0x339b8]),
        .init(start: 0x399a4, producers: [0x399ec, 0x39a80, 0x39b18, 0x39c1c, 0x39bf8], namedRows: [0x399ec, 0x39a80, 0x39b18, 0x39c1c, 0x39bf8], exits: [0x39c18]),
        .init(start: 0x39c24, producers: [0x39c6c, 0x39ccc, 0x39d48, 0x39e30, 0x39e08, 0x39de4], namedRows: [0x39c6c, 0x39ccc, 0x39d48, 0x39e30, 0x39e08, 0x39de4], exits: [0x39e04]),
        .init(start: 0x39e5c, producers: [0x39e98, 0x39ee4, 0x39f44], namedRows: [0x39e98, 0x39ee4, 0x39f44], exits: [0x39f5c]),
        .init(start: 0x39f60, producers: [0x39fb8, 0x3a2e4, 0x3a3ac], namedRows: [0x39fb8, 0x3a2e4, 0x3a3ac], exits: [0x3a31c]),
        .init(start: 0x46838, producers: [0x46a58], namedRows: [0x46920, 0x46924, 0x46984, 0x46988, 0x46a58], exits: [0x46a70]),
        .init(start: 0x46a74, producers: [0x46b5c], namedRows: [0x46af4, 0x46af8, 0x46b5c], exits: [0x46b74]),
        .init(start: 0x517d8, producers: [0x51cb8], namedRows: [0x51ca8, 0x51cac, 0x51cb0, 0x51cb4, 0x51cb8], exits: [0x51ce4]),
        .init(start: 0x57e14, producers: [0x57e3c, 0x57e50], namedRows: [0x57e3c, 0x57e50], exits: [0x57e5c]),
        .init(start: 0x57f04, producers: [0x57f2c, 0x57f40], namedRows: [0x57f2c, 0x57f40], exits: [0x57f4c]),
        .init(start: 0x57f68, producers: [0x57f90, 0x57fa4], namedRows: [0x57f90, 0x57fa4], exits: [0x57fb0]),
        .init(start: 0x57fcc, producers: [0x57ff4, 0x58008], namedRows: [0x57ff4, 0x58008], exits: [0x58014]),
        .init(start: 0x5802c, producers: [0x58054, 0x58068], namedRows: [0x58054, 0x58068], exits: [0x58074]),
        .init(start: 0x5808c, producers: [0x580b4, 0x580c8], namedRows: [0x580b4, 0x580c8], exits: [0x580d4]),
        .init(start: 0x58324, producers: [0x5834c, 0x58360], namedRows: [0x5834c, 0x58360], exits: [0x5836c]),
        .init(start: 0x5838c, producers: [0x583b4, 0x583c8], namedRows: [0x583b4, 0x583c8], exits: [0x583d4]),
        .init(start: 0x58410, producers: [0x58438, 0x5844c], namedRows: [0x58438, 0x5844c], exits: [0x58458]),
        .init(start: 0x58478, producers: [0x584a0, 0x584b4], namedRows: [0x584a0, 0x584b4], exits: [0x584c0]),
    ]
    static let truthStarts: Set<UInt64> = [
        0x9394, 0x972c, 0x9ae8, 0x1761c, 0x1a104, 0x1c678, 0x1ce2c,
        0x24548, 0x25e0c, 0x2df5c, 0x2f334, 0x32540, 0x399a4,
        0x4be18, 0x4c078, 0x4c668, 0x50944, 0x517d8
    ]
    private var observedA: Set<UInt64> = []
    private var observedB: Set<UInt64> = []
    private var results: [[String: Any]] = []
    private var observedSpecial: Set<UInt64> = []

    static func hex(_ address: UInt64) -> String { "0x" + String(address, radix: 16) }

    /// Expand only phis. An ordinary write (including a MOV) is the physical
    /// cell's producer; its operands are separate dependencies, not extra X0
    /// definitions. Cycles terminate by definition identity.
    static func leaves(_ initial: Int, info: MacIRSSAInfo,
                       file: StaticString = #filePath, line: UInt = #line) -> Set<UInt64> {
        var work = [initial], seen: Set<Int> = [], addresses: Set<UInt64> = []
        while let raw = work.popLast() {
            let id = info.plan.canonicalID(raw)
            guard seen.insert(id).inserted else { continue }
            guard info.plan.definitions.indices.contains(id) else {
                XCTFail("missing reaching definition \(id)", file: file, line: line)
                addresses.insert(UInt64.max)
                continue
            }
            let definition = info.plan.definitions[id]
            switch definition.origin {
            case let .instruction(address): addresses.insert(address)
            case .callResult:
                let rows = info.plan.rowWriteBindings.indices.filter {
                    info.plan.rowWriteBindings[$0][definition.cell].map(info.plan.canonicalID) == id
                }
                XCTAssertEqual(rows.count, 1, "call result has one source row", file: file, line: line)
                for row in rows { addresses.insert(info.sourceAddresses[row]) }
            case .phi:
                let phis = info.plan.phis.filter { info.plan.canonicalID($0.destination) == id }
                XCTAssertEqual(phis.count, 1, "a reaching phi has one definition", file: file, line: line)
                for phi in phis { work.append(contentsOf: phi.incoming.map(\.definition)) }
            case .entry, .callClobber, .refusal:
                XCTFail("nonconcrete reaching origin: \(definition.origin)", file: file, line: line)
                addresses.insert(UInt64.max)
            }
        }
        return addresses
    }

    /// Follow captured semantic input bindings as a separate provenance check.
    /// Entry arguments and memory epochs terminate; ordinary source rows remain
    /// distinguishable from the direct physical-cell producer check above.
    static func dependencyRows(_ initial: Int, info: MacIRSSAInfo) -> Set<UInt64> {
        var work = [initial], seen: Set<Int> = [], result: Set<UInt64> = []
        var rowsByDefinition: [Int: [Int]] = [:]
        for row in info.plan.rowWriteBindings.indices {
            for definition in info.plan.rowWriteBindings[row].values {
                rowsByDefinition[info.plan.canonicalID(definition), default: []].append(row)
            }
        }
        let phisByDefinition = Dictionary(grouping: info.plan.phis, by: { info.plan.canonicalID($0.destination) })
        while let raw = work.popLast() {
            let id = info.plan.canonicalID(raw)
            guard seen.insert(id).inserted, info.plan.definitions.indices.contains(id) else { continue }
            let definition = info.plan.definitions[id]
            if case .phi = definition.origin {
                for phi in phisByDefinition[id] ?? [] {
                    work.append(contentsOf: phi.incoming.map(\.definition))
                }
                continue
            }
            guard definition.cell != 97 else { continue }
            for row in rowsByDefinition[id] ?? [] {
                result.insert(info.sourceAddresses[row])
                work.append(contentsOf: info.plan.rowReadBindings[row].filter { $0.key != 97 }.map(\.value))
            }
        }
        return result
    }

    mutating func observe(function: MacIRFunction, input: PseudocodeRenderInput) throws {
        do {
            try inspect(function: function, input: input)
        } catch {
            results.append(["start": input.startAddress.map(Self.hex) ?? "missing", "pass": false,
                            "error": String(describing: error)])
            XCTFail("SSA witness input could not be checked: \(error)")
        }
    }

    private mutating func inspect(function: MacIRFunction, input: PseudocodeRenderInput) throws {
        let start = try XCTUnwrap(input.startAddress)
        let valueCase = Self.valueCases.first { $0.start == start }
        guard valueCase != nil || Self.truthStarts.contains(start)
                || start == 0x32368 || start == 0x7a88 else { return }
        XCTAssertFalse(function.refusals.contains { $0.detail == "entry block has an in-graph predecessor" },
                       "acceptance functions cannot use the entry-backedge escape")
        let info = try XCTUnwrap(function.ssaInfo, "SSA metadata required at \(Self.hex(start))")
        if let valueCase {
            observedA.insert(start)
            let sourceAddresses = Set(input.instructions.map(\.address))
            XCTAssertTrue(valueCase.namedRows.isSubset(of: sourceAddresses),
                          "every named machine producer/dependency row is present")
            var union: Set<UInt64> = []
            var dependencies: Set<UInt64> = []
            var exits: [[String: Any]] = []
            var everyExitMatches = true
            for exit in valueCase.exits {
                let row = try XCTUnwrap(info.sourceAddresses.firstIndex(of: exit))
                XCTAssertEqual(input.instructions[row].mnemonic, "ret")
                let definition = try XCTUnwrap(info.plan.rowReadBindings[row][0])
                let actual = Self.leaves(definition, info: info)
                let perExit: [UInt64: Set<UInt64>] = [
                    0x1b9e0: [0x1b9dc], 0x1b9ec: [0x1b9e8],
                    0x1c260: [0x1c25c], 0x1c288: [0x1c278]
                ]
                let expected = perExit[exit] ?? valueCase.producers
                XCTAssertEqual(actual, expected, "exact producer set at exit \(Self.hex(exit))")
                XCTAssertTrue(actual.isSubset(of: valueCase.producers),
                              "unexpected terminal producer at \(Self.hex(exit)): \(actual.sorted().map(Self.hex))")
                XCTAssertFalse(actual.isEmpty, "terminal read has concrete producers")
                union.formUnion(actual)
                dependencies.formUnion(Self.dependencyRows(definition, info: info))
                everyExitMatches = everyExitMatches && actual == expected
                exits.append(["exit": Self.hex(exit), "producers": actual.sorted().map(Self.hex),
                              "pass": actual == expected])
            }
            XCTAssertEqual(union, valueCase.producers,
                           "exact producer set at \(Self.hex(start)); supporting non-X0 rows are dependencies")
            XCTAssertTrue(valueCase.namedRows.isSubset(of: dependencies),
                          "all named supporting producer rows must reach the terminal dependency graph")
            results.append(["set": "A", "start": Self.hex(start), "exits": exits,
                            "expected": valueCase.producers.sorted().map(Self.hex),
                            "pass": everyExitMatches && union == valueCase.producers && valueCase.namedRows.isSubset(of: dependencies),
                            "contract": String(describing: function.returnValue)])
        }
        if Self.truthStarts.contains(start) {
            observedB.insert(start)
            let exits = input.instructions.indices.filter { input.instructions[$0].mnemonic == "ret" }
            XCTAssertFalse(exits.isEmpty, "truth-value function must expose its return exits")
            var exitResults: [[String: Any]] = []
            for row in exits {
                let definition = try XCTUnwrap(info.plan.rowReadBindings[row][0])
                let producers = Self.leaves(definition, info: info)
                XCTAssertFalse(producers.isEmpty, "every truth-value exit reaches concrete producers")
                exitResults.append(["exit": Self.hex(input.instructions[row].address),
                                    "producers": producers.sorted().map(Self.hex), "pass": !producers.isEmpty && !producers.contains(UInt64.max)])
            }
            results.append(["set": "B", "start": Self.hex(start), "exits": exitResults,
                            "pass": !exitResults.isEmpty && exitResults.allSatisfy { $0["pass"] as? Bool == true }])
        }
        if start == 0x32368 {
            observedSpecial.insert(start)
            try Self.requireMarkerPhis(function)
        }
        if start == 0x7a88 {
            observedSpecial.insert(start)
            _ = try XCTUnwrap(SSAPropertyAssertions.phi(function, block: 0x7b30, cell: 8, width: 64,
                incoming: [(0x7b14, 0x7b10), (0x7b2c, 0x7b2c)]))
        }
    }

    func finish(output: URL) throws {
        XCTAssertEqual(observedA, Set(Self.valueCases.map(\.start)))
        XCTAssertEqual(observedB, Self.truthStarts)
        XCTAssertEqual(observedSpecial, [0x32368, 0x7a88])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("ssa-exit-acceptance.json"), options: .withoutOverwriting)
    }

    /// Frozen predecessor sets from the complete color-converter capture.
    /// The epilogue's two predecessors agree, so its read retains the earlier
    /// merge identity instead of inventing a redundant terminal phi.
    static func requireColorConverterTerminal(_ function: MacIRFunction) throws -> MacIRValue {
        let info = try XCTUnwrap(function.ssaInfo)
        let graph = try XCTUnwrap(function.cfg)
        let expected: [(UInt64, [(UInt64, Set<UInt64>)])] = [
            (0x2aad4, [
                (0x2a8dc, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2a990, [0x2a6f8, 0x2a768]),
                (0x2aabc, [0x2a6f8, 0x2a768, 0x2aaa8]),
            ]),
            (0x2aadc, [
                (0x2a90c, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2a93c, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2a9c4, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2a9d0, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2a9dc, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2aa08, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2aa14, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2aa20, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2aad8, [0x2a6f8, 0x2a768, 0x2a7f4, 0x2aaa8]),
                (0x2ab0c, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2ab18, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2ab24, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2ab30, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2ab3c, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2ab48, [0x2a6f8, 0x2a768, 0x2a7f4]),
                (0x2ab60, [0x2a6f8, 0x2a768, 0x2a880]),
                (0x2ab6c, [0x2a6f8, 0x2a768, 0x2a880]),
                (0x2ab78, [0x2a6f8, 0x2a768, 0x2a880]),
                (0x2ab84, [0x2a6f8, 0x2a768, 0x2a880]),
            ]),
            (0x2aae0, [
                (0x2a9b8, [0x2a9b4]),
                (0x2aa74, [0x2a6f8, 0x2a768, 0x2aa38]),
                (0x2aa90, [0x2a6f8, 0x2a768, 0x2aa38]),
                (0x2aadc, [0x2a6f8, 0x2a768, 0x2a7f4, 0x2a880, 0x2aaa8]),
            ]),
        ]
        for (address, slots) in expected {
            let block = try XCTUnwrap(graph.blocks.first { $0.startAddress == address })
            let phi = try XCTUnwrap(info.plan.phis.first { $0.block == block.index && $0.cell == 0 })
            let persisted = try XCTUnwrap(function.phis.first { $0.blockAddress == address &&
                SSAPropertyAssertions.physicalCell($0.destination) == 0 })
            XCTAssertEqual(phi.incoming.map(\.machineAddress), slots.map { Optional.some($0.0) })
            XCTAssertEqual(persisted.incoming.map(\.machineAddress), slots.map { Optional.some($0.0) })
            for (incoming, expectedSlot) in zip(phi.incoming, slots) {
                XCTAssertEqual(leaves(incoming.definition, info: info), expectedSlot.1,
                               "exact predecessor producer closure at \(hex(address)) via \(incoming.machineAddress.map(hex) ?? "function-entry")")
                XCTAssertEqual(persisted.incoming.first { $0.machineAddress == incoming.machineAddress }?.value,
                               info.values[info.plan.canonicalID(incoming.definition)])
            }
        }
        let retRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x2ab00))
        let definition = try XCTUnwrap(info.plan.rowReadBindings[retRow][0])
        XCTAssertEqual(leaves(definition, info: info), [0x2a6f8, 0x2a768, 0x2a7f4, 0x2a880,
                                                      0x2a9b4, 0x2aa38, 0x2aaa8])
        let terminalBlock = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x2aae0 })
        XCTAssertEqual(info.plan.definitions[info.plan.canonicalID(definition)].origin, .phi(block: terminalBlock.index))
        let value = try XCTUnwrap(info.values[info.plan.canonicalID(definition)])
        XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        XCTAssertEqual(function.instructions[281].operation, .returnValue(function.returnValue))
        XCTAssertNil(RegionalBoundaryPlan.prove(function: function,
            cfg: CFGBuilder.buildCFG(instructions: function.instructions)))
        return value
    }

    private static func requireMarkerPhis(_ function: MacIRFunction) throws {
        let info = try XCTUnwrap(function.ssaInfo)
        let graph = try XCTUnwrap(function.cfg)
        typealias Slot = (predecessor: UInt64, source: UInt64, isPhi: Bool)
        let rows: [(Int, UInt64, [Slot])] = [
            (21, 0x323a0, [(0x32388,0x32384,false),(0x3239c,0x3239c,false),(0x323c8,0x323bc,true)]),
            (21, 0x323bc, [(0x323b8,0x323a0,false),(0x32404,0x323e8,false)]),
            (21, 0x323cc, [(0x323ac,0x323a0,false),(0x323f0,0x323e8,false)]),
            (21, 0x323e4, [(0x323cc,0x323cc,true),(0x323e0,0x323e0,false)]),
            (22, 0x323a0, [(0x32388,0x32384,false),(0x3239c,0x3239c,false),(0x323c8,0x323bc,true)]),
            (22, 0x323bc, [(0x323b8,0x323a4,false),(0x32404,0x323e4,false)]),
            (22, 0x323cc, [(0x323ac,0x323a4,false),(0x323f0,0x323e4,false)]),
            (22, 0x323e4, [(0x323cc,0x323cc,true),(0x323e0,0x323e0,false)])
        ]
        XCTAssertEqual(info.plan.phis.filter { $0.cell == 21 || $0.cell == 22 }.count, 8)
        XCTAssertEqual(info.plan.phis.filter { $0.cell == 21 || $0.cell == 22 }.reduce(0) { $0 + $1.incoming.count }, 18)
        for (cell, address, expected) in rows {
            let block = try XCTUnwrap(graph.blocks.first { $0.startAddress == address })
            let phi = try XCTUnwrap(info.plan.phis.first { $0.block == block.index && $0.cell == cell })
            XCTAssertEqual(phi.incoming.map(\.machineAddress), expected.map { Optional.some($0.predecessor) })
            let persisted = try XCTUnwrap(function.phis.first { $0.blockAddress == address &&
                SSAPropertyAssertions.physicalCell($0.destination) == cell })
            XCTAssertEqual(persisted.incoming.map(\.machineAddress), expected.map { Optional.some($0.predecessor) })
            XCTAssertEqual(persisted.bitWidth, 64)
            for (slot, wanted) in zip(phi.incoming, expected) {
                let id = info.plan.canonicalID(slot.definition)
                let definition = info.plan.definitions[id]
                if wanted.isPhi {
                    let sourceBlock = try XCTUnwrap(graph.blocks.first { $0.startAddress == wanted.source })
                    XCTAssertEqual(definition.origin, .phi(block: sourceBlock.index))
                } else { XCTAssertEqual(definition.origin, .instruction(wanted.source)) }
                XCTAssertEqual(definition.cell, cell)
                XCTAssertEqual(persisted.incoming.first { $0.machineAddress == slot.machineAddress }?.value,
                               info.values[id])
            }
        }
        for address in [UInt64(0x3238c), 0x32450] {
            XCTAssertFalse(function.phis.contains { $0.blockAddress == address &&
                [21, 22].contains(SSAPropertyAssertions.physicalCell($0.destination) ?? -1) })
        }
        for address in [UInt64(0x32394), 0x323d8, 0x32438] {
            let row = try XCTUnwrap(info.sourceAddresses.firstIndex(of: address))
            XCTAssertNil(info.plan.rowWriteBindings[row][21])
            XCTAssertNil(info.plan.rowWriteBindings[row][22])
        }
    }
}

extension MacIRSSATests {
    func testReportCapturedUpsamplerLoopHeaderProducers() throws {
        guard SSAPropertyAssertions.enabled,
              ProcessInfo.processInfo.environment["MACSCOPE_SSA_REPORT_CAPTURED_LOOP"] == "1" else {
            throw XCTSkip("Enable the one-time captured-loop report before converting its expectation")
        }
        let fixture = try RegionalCallFixture.make(.j16init)
        let info = try XCTUnwrap(fixture.function.ssaInfo)
        let graph = try XCTUnwrap(fixture.function.cfg)
        for phi in info.plan.phis where phi.cell == 0 {
            let block = graph.blocks[phi.block]
            let slots = phi.incoming.map { incoming -> String in
                let id = info.plan.canonicalID(incoming.definition)
                let producers = SSAWitnessAcceptance.leaves(id, info: info).sorted().map(SSAWitnessAcceptance.hex)
                return "\(incoming.machineAddress.map(SSAWitnessAcceptance.hex) ?? "function-entry")->\(info.plan.definitions[id].origin) leaves=\(producers)"
            }
            print("SSA_CAPTURED_LOOP cell=0 block=\(SSAWitnessAcceptance.hex(block.startAddress)) incoming=\(slots)")
        }
        let exit = try XCTUnwrap(info.sourceAddresses.firstIndex(of: fixture.rows[187].address))
        let definition = try XCTUnwrap(info.plan.rowReadBindings[exit][0])
        print("SSA_CAPTURED_LOOP exit=\(SSAWitnessAcceptance.hex(fixture.rows[187].address)) producers=\(SSAWitnessAcceptance.leaves(definition, info: info).sorted().map(SSAWitnessAcceptance.hex))")
    }
}
