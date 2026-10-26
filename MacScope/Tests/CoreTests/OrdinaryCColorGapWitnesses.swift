import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// SOURCE_ONLY / NOT_RUN. New complete-entry inputs from the independently
/// source-reviewed color gap plan; not dynamic coverage until the new selectors run.
/// Product remains 9784dcdde313f110d9dc2359004d56f63b0bee80.
/// No historical scenario constructor, regional binding or source-derived candidate
/// value is used. Returning K and these sparse readable cells are explicit premises.
enum OrdinaryCColorGapWitnesses {
    typealias C = OrdinaryC
    typealias O = RegionalSwitchOracle
    typealias L = OrdinaryCSourceEdgeLedger
    static let context: UInt64 = 0x10000
    static let errorManager: UInt64 = 0x20000
    static let allocator: UInt64 = 0x30000
    static let controller: UInt64 = 0x40000
    static let deconverter: UInt64 = 0x50000
    static let initialSP: UInt64 = 0x90000
    static let errorTarget: UInt64 = 0xe113_579b_2468_ace0
    static let allocatorTarget: UInt64 = 0xa117_1357_2468_ace0

    struct Edge {
        let edge: C.SourceEdge
        let sourceRow: Int
        let destinationRow: Int
        let witnesses: Set<Int>
        init(_ from: Int, _ ordinal: Int, _ to: Int, _ row: Int, _ destination: Int, _ ids: [Int]) {
            edge = .init(fromBlock: from, toBlock: to, successorOrdinal: ordinal)
            sourceRow = row; destinationRow = destination; witnesses = Set(ids)
        }
    }
    struct Slot {
        let pc: Int
        let span: C.Span
        let target: Int
        let witnesses: Set<Int>
        init(_ pc: Int, _ first: Int, _ last: Int, _ target: Int, _ ids: [Int]) {
            self.pc = pc; span = .init(first: first, last: last); self.target = target; witnesses = Set(ids)
        }
    }
    struct Witness {
        let id: Int
        let scenario: O.Scenario
        let edges: Set<C.SourceEdge>
        let residualPCs: Set<Int>
    }
    struct Layout {
        let seed: RegionalSwitchSeed
        let firstTable: UInt64
        let countTable: UInt64
        let firstBytes: [UInt8]
        let secondBytes: [UInt8]
        let precision: UInt64
        let first: Int
        let shift: Int
        let nullPointer: Int
        let cold: Int
        let finalLoad: Int
        let grayStore: Int
        let countLoad: Int
        let pointerLoad: Int
        let loopStore: Int
        let builderStore: Int
        let pointerTableLoad: Int
        let pointerGuard: Int
        let pointerFallback: Int
        let pointerTable: UInt64
        var second: Int { first + 12 }
        var tst: Int { shift + 3 }
        var firstDefault: Int { cold + 6 }
        var secondDefault: Int { cold + 15 }
        var finalOne: Int { finalLoad + 2 }
        var finalZeroLoad: Int { finalLoad + 4 }
        var finalStore: Int { finalLoad + 5 }
        var terminal: Int { finalLoad + 8 }
        var countBytes: [UInt8] { OrdinaryCColorGapWitnesses.countBytes }
        init(_ seed: RegionalSwitchSeed) throws {
            self.seed = seed
            switch seed {
            case .jinit:
                firstTable = 0x59070; countTable = 0x59084; precision = 8
                firstBytes = [0x8e,0x00,0x91,0x2f,0x32,0x2c,0x00,0x2f,0x32,0x2c]
                secondBytes = [0x8b,0x00,0x8e,0x3a,0x3d,0x37,0x00,0x3a,0x3d,0x37]
                first = 144; shift = 136; nullPointer = 276; cold = 295; finalLoad = 286
                grayStore = 246; countLoad = 247; pointerLoad = 250; loopStore = 253
                builderStore = 272; pointerTableLoad = 195; pointerGuard = 192
                pointerFallback = 217; pointerTable = 0x600c0
            case .j12init:
                firstTable = 0x590e8; countTable = 0x590fc; precision = 12
                firstBytes = [0x83,0x00,0x86,0x2d,0x30,0x2a,0x00,0x2d,0x30,0x2a]
                secondBytes = [0x80,0x00,0x83,0x32,0x35,0x2f,0x00,0x32,0x35,0x2f]
                first = 145; shift = 137; nullPointer = 266; cold = 285; finalLoad = 276
                grayStore = 239; countLoad = 240; pointerLoad = 243; loopStore = 246
                builderStore = 192; pointerTableLoad = 103; pointerGuard = 100
                pointerFallback = 190; pointerTable = 0x60110
            case .j16initC4Negative:
                throw C.Failure.invalidContract("gap witnesses have no j16 void-terminal authority")
            }
        }
    }

    // Literal 68 bytes from immutable-tables.json, not typed production cases.
    // Entries 5 and 16 are all-ones; no invented pointer-table cell is defined.
    private static let countBytes: [UInt8] = [
        0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
        0x03,0x00,0x00,0x00,0xff,0xff,0xff,0xff,
        0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
        0x03,0x00,0x00,0x00,0x04,0x00,0x00,0x00,
        0x03,0x00,0x00,0x00,0x04,0x00,0x00,0x00,
        0x04,0x00,0x00,0x00,0x04,0x00,0x00,0x00,
        0x04,0x00,0x00,0x00,0x04,0x00,0x00,0x00,
        0x04,0x00,0x00,0x00,0x04,0x00,0x00,0x00,
        0xff,0xff,0xff,0xff
    ]

    // Exact missing-edge and residual inventories from the reviewed source-only
    // triage. Empty witness sets mean CONDITIONAL NONEXECUTION, never coverage.
    static func edges(_ seed: RegionalSwitchSeed) -> [Edge] {
        if seed == .jinit {
            return [
                .init(13,1,14,61,62,[1,6]),
                .init(14,0,40,67,136,[1,6]),
                .init(15,0,28,69,104,[2,3]),
                .init(19,1,20,77,78,[2,6]),
                .init(1,1,2,10,11,[1]),
                .init(20,0,12,79,56,[6]),
                .init(20,1,21,79,80,[2]),
                .init(21,0,48,80,168,[2]),
                .init(25,0,85,97,280,[7]),
                .init(28,0,10,106,46,[2]),
                .init(28,1,29,106,107,[3]),
                .init(29,0,11,107,52,[3]),
                .init(2,0,3,17,18,[1]),
                .init(30,0,53,109,181,[4,5,13,14,15,16]),
                .init(32,1,33,114,115,[8,9]),
                .init(33,0,34,120,121,[8,9]),
                .init(37,0,85,131,280,[8]),
                .init(43,0,90,152,295,[]),
                .init(43,6,92,152,301,[]),
                .init(46,6,95,164,310,[]),
                .init(48,1,49,170,171,[2,3]),
                .init(49,0,55,172,187,[2,3]),
                .init(4,1,5,35,36,[4,5]),
                .init(50,1,51,176,177,[10,11,12]),
                .init(51,0,70,178,229,[11,12]),
                .init(51,1,52,178,179,[10]),
                .init(52,0,74,180,244,[10]),
                .init(53,0,79,184,264,[4,5]),
                .init(53,1,54,184,185,[13,14,15,16]),
                .init(54,0,78,186,257,[14,15,16]),
                .init(54,1,55,186,187,[13]),
                .init(55,0,83,188,276,[2,3,13]),
                .init(56,0,66,192,217,[17]),
                .init(5,0,10,38,46,[5]),
                .init(5,1,6,38,39,[4]),
                .init(63,0,85,210,280,[9]),
                .init(66,0,82,219,272,[17]),
                .init(6,0,11,39,52,[4]),
                .init(70,0,71,235,236,[11,12]),
                .init(71,0,74,239,244,[11]),
                .init(73,0,85,243,280,[12]),
                .init(78,0,79,263,264,[14,15,16]),
                .init(79,0,83,267,276,[4,14]),
                .init(79,1,80,267,268,[5,15,16]),
                .init(7,0,2,41,11,[2]),
                .init(80,0,85,269,280,[16]),
                .init(80,1,81,269,270,[5,15]),
                .init(81,0,82,271,272,[5,15]),
                .init(90,0,84,297,278,[]),
                .init(9,1,10,45,46,[1]),
            ]
        }
        return [
                .init(13,1,14,61,62,[1,6]),
                .init(14,0,40,67,137,[1,6]),
                .init(15,0,28,69,105,[2,3]),
                .init(19,1,20,77,78,[2,6]),
                .init(1,1,2,10,11,[1]),
                .init(20,0,12,79,56,[6]),
                .init(20,1,21,79,80,[2]),
                .init(21,0,48,80,169,[2]),
                .init(25,0,82,97,270,[7]),
                .init(26,0,56,100,190,[17]),
                .init(28,0,10,107,46,[2]),
                .init(28,1,29,107,108,[3]),
                .init(29,0,11,108,52,[3]),
                .init(2,0,3,17,18,[1]),
                .init(30,0,53,110,182,[4,5,13,14,15,16]),
                .init(32,1,33,115,116,[8,9]),
                .init(33,0,34,121,122,[8,9]),
                .init(37,0,82,132,270,[8]),
                .init(43,0,87,153,285,[]),
                .init(43,6,89,153,291,[]),
                .init(46,6,92,165,300,[]),
                .init(48,1,49,171,172,[2,3]),
                .init(49,0,55,173,188,[2,3]),
                .init(4,1,5,35,36,[4,5]),
                .init(50,1,51,177,178,[10,11,12]),
                .init(51,0,68,179,222,[11,12]),
                .init(51,1,52,179,180,[10]),
                .init(52,0,72,181,237,[10]),
                .init(53,0,77,185,257,[4,5]),
                .init(53,1,54,185,186,[13,14,15,16]),
                .init(54,0,76,187,250,[14,15,16]),
                .init(54,1,55,187,188,[13]),
                .init(55,0,80,189,266,[2,3,13]),
                .init(56,0,57,191,192,[17]),
                .init(5,0,10,38,46,[5]),
                .init(5,1,6,38,39,[4]),
                .init(63,0,82,209,270,[9]),
                .init(68,0,69,228,229,[11,12]),
                .init(69,0,72,232,237,[11]),
                .init(6,0,11,39,52,[4]),
                .init(71,0,82,236,270,[12]),
                .init(76,0,77,256,257,[14,15,16]),
                .init(77,0,80,260,266,[4,14]),
                .init(77,1,78,260,261,[5,15,16]),
                .init(78,0,82,262,270,[16]),
                .init(78,1,79,262,263,[5,15]),
                .init(79,0,57,265,192,[5,15]),
                .init(7,0,2,41,11,[2]),
                .init(87,0,81,287,268,[]),
                .init(9,1,10,45,46,[1]),
        ]
    }
    static func slots(_ seed: RegionalSwitchSeed) -> [Slot] {
        if seed == .jinit {
            return [
                .init(65,628,631,96,[4]),
                .init(81,722,725,96,[3]),
                .init(109,978,981,315,[6]),
                .init(120,1057,1060,153,[10]),
                .init(142,1268,1271,528,[12]),
                .init(215,1905,1908,528,[8]),
                .init(249,2142,2145,528,[9]),
                .init(273,2281,2284,311,[13]),
                .init(296,2509,2512,518,[5,15]),
                .init(299,2515,2518,528,[16]),
                .init(302,2522,2525,523,[4,14]),
                .init(313,2593,2596,523,[2,3,13]),
                .init(330,2736,2739,445,[1,6]),
                .init(378,3219,3222,518,[17]),
                .init(381,3227,3230,528,[7]),
                .init(471,3922,3925,540,[]),
                .init(509,4169,4172,536,[]),
            ]
        }
        return [
                .init(65,628,631,96,[4]),
                .init(81,722,725,96,[3]),
                .init(109,978,981,308,[6]),
                .init(120,1057,1060,153,[10]),
                .init(142,1268,1271,508,[12]),
                .init(215,1905,1908,508,[8]),
                .init(242,2055,2058,508,[9]),
                .init(266,2194,2197,304,[13]),
                .init(289,2422,2425,498,[5,15]),
                .init(292,2428,2431,508,[16]),
                .init(295,2435,2438,503,[4,14]),
                .init(306,2506,2509,503,[2,3,13]),
                .init(323,2649,2652,430,[1,6]),
                .init(363,3033,3036,498,[17]),
                .init(366,3040,3043,508,[7]),
                .init(456,3735,3738,520,[]),
                .init(494,3982,3985,516,[]),
        ]
    }

    private struct Input {
        let flag: UInt64
        let input: UInt64
        let output: UInt64
        let count: UInt64
        var precision: UInt64? = nil
        var dither: UInt64 = 0
        var pointer: UInt64? = nil
        var storePointer: UInt64? = nil
    }
    private static func input(_ id: Int) throws -> Input {
        switch id {
        case 1: return .init(flag: 1, input: 4, output: 4, count: 4, precision: 1) // W01: Precision error with controller and RGB count error
        case 2: return .init(flag: 0, input: 0, output: 0, count: 0, precision: 1) // W02: Precision error without controller and raw zero-color join
        case 3: return .init(flag: 0, input: 0, output: 0, count: 1) // W03: Positive general-input count bypass
        case 4: return .init(flag: 0, input: 4, output: 4, count: 4) // W04: Output four without controller, input four valid count
        case 5: return .init(flag: 0, input: 4, output: 4, count: 3) // W05: Input-four count error returns as input five
        case 6: return .init(flag: 1, input: 2, output: 2, count: 3) // W06: Output two enters controller RGB count path
        case 7: return .init(flag: 1, input: 3, output: 7, count: 3) // W07: Range-error callback returns invalid input color
        case 8: return .init(flag: 1, input: 2, output: 16, count: 3, dither: 0) // W08: RGB565 controller error changes to dithered invalid input
        case 9: return .init(flag: 1, input: 2, output: 16, count: 3, dither: 1) // W09: RGB565 controller error changes to nondithered invalid input
        case 10: return .init(flag: 1, input: 1, output: 1, count: 4, pointer: context - 0x5c, storePointer: context - 0x5c) // W10: Controller gray entry retains aliased loop recurrence
        case 11: return .init(flag: 1, input: 3, output: 1, count: 3, pointer: 0x60000, storePointer: 0x0000_0001_ffff_ff6c) // W11: Gray error callback changes count and high pointer
        case 12: return .init(flag: 1, input: 3, output: 1, count: 3) // W12: Gray error callback changes input to invalid four
        case 13: return .init(flag: 1, input: 4, output: 4, count: 4) // W13: Controller output-four fast path
        case 14: return .init(flag: 1, input: 2, output: 4, count: 3) // W14: Output-four error callback changes input to four
        case 15: return .init(flag: 1, input: 2, output: 4, count: 3) // W15: Output-four error callback changes input to five
        case 16: return .init(flag: 1, input: 2, output: 4, count: 3) // W16: Output-four error callback changes input to invalid zero
        case 17: return .init(flag: 1, input: 3, output: 7, count: 3) // W17: Returning range callback selects pointer-table default
        default: throw C.Failure.invalidContract("unknown color gap witness")
        }
    }

    private static func responses(_ id: Int, _ seed: RegionalSwitchSeed) throws -> [O.Response] {
        // Keep complete ordered scripts explicit. These response bits are input
        // premises, not output expectations and not hidden register authority.
        switch (seed, id) {
        case (.jinit, 1): return [
            .init(row: 17, result: 0xc411000000000011, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x2), .init(address: 0x10040, bytes: 4, bits: 0x7), .init(address: 0x10038, bytes: 4, bits: 0x2)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 51, result: 0xc411000000000033, writes: [], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 2): return [
            .init(row: 17, result: 0xc411000000000011, writes: [], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 51, result: 0xc411000000000033, writes: [.init(address: 0x10038, bytes: 4, bits: 0x5)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 3): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
        ]
        case (.jinit, 4): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
        ]
        case (.jinit, 5): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 51, result: 0xc411000000000033, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x5)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 274, result: 0xb017000000000112, writes: [.init(address: 0x10090, bytes: 4, bits: 0x87654321)], expectedArguments: [0x10000], expectedControl: []),
        ]
        case (.jinit, 6): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
        ]
        case (.jinit, 7): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 86, result: 0xc411000000000056, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4), .init(address: 0x10040, bytes: 4, bits: 0x8)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 285, result: 0xc41100000000011d, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x0), .init(address: 0x10090, bytes: 4, bits: 0x87654321)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 8): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 120, result: 0xc411000000000078, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4), .init(address: 0x10070, bytes: 4, bits: 0x1)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 285, result: 0xc41100000000011d, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x0), .init(address: 0x10090, bytes: 4, bits: 0x81234567)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 9): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 120, result: 0xc411000000000078, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4), .init(address: 0x10070, bytes: 4, bits: 0x0)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 285, result: 0xc41100000000011d, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x80000000)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 10): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 51, result: 0xc411000000000033, writes: [], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 11): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 234, result: 0xc4110000000000ea, writes: [.init(address: 0x10038, bytes: 4, bits: 0x4), .init(address: 0x10130, bytes: 8, bits: 0x1ffffff6c)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 12): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 234, result: 0xc4110000000000ea, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 285, result: 0xc41100000000011d, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x0), .init(address: 0x10090, bytes: 4, bits: 0x84321076)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 13): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
        ]
        case (.jinit, 14): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 262, result: 0xc411000000000106, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 15): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 262, result: 0xc411000000000106, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x5)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 274, result: 0xb017000000000112, writes: [.init(address: 0x10090, bytes: 4, bits: 0x85674321)], expectedArguments: [0x10000], expectedControl: []),
        ]
        case (.jinit, 16): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 262, result: 0xc411000000000106, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x0)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 285, result: 0xc41100000000011d, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x80000000)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.jinit, 17): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 86, result: 0xc411000000000056, writes: [.init(address: 0x10040, bytes: 4, bits: 0x5)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 99, result: 0x100000000, writes: [], expectedArguments: [0x10000], expectedControl: []),
            .init(row: 274, result: 0xb017000000000112, writes: [], expectedArguments: [0x10000], expectedControl: []),
        ]
        case (.j12init, 1): return [
            .init(row: 17, result: 0xc411000000000011, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x2), .init(address: 0x10040, bytes: 4, bits: 0x7), .init(address: 0x10038, bytes: 4, bits: 0x2)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 51, result: 0xc411000000000033, writes: [], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 2): return [
            .init(row: 17, result: 0xc411000000000011, writes: [], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 51, result: 0xc411000000000033, writes: [.init(address: 0x10038, bytes: 4, bits: 0x5)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 3): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
        ]
        case (.j12init, 4): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
        ]
        case (.j12init, 5): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 51, result: 0xc411000000000033, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x5)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 194, result: 0xb0170000000000c2, writes: [.init(address: 0x10090, bytes: 4, bits: 0x87654321)], expectedArguments: [0x10000], expectedControl: []),
        ]
        case (.j12init, 6): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
        ]
        case (.j12init, 7): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 86, result: 0xc411000000000056, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4), .init(address: 0x10040, bytes: 4, bits: 0x8)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 275, result: 0xc411000000000113, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x0), .init(address: 0x10090, bytes: 4, bits: 0x87654321)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 8): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 121, result: 0xc411000000000079, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4), .init(address: 0x10070, bytes: 4, bits: 0x1)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 275, result: 0xc411000000000113, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x0), .init(address: 0x10090, bytes: 4, bits: 0x81234567)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 9): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 121, result: 0xc411000000000079, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4), .init(address: 0x10070, bytes: 4, bits: 0x0)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 275, result: 0xc411000000000113, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x80000000)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 10): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 51, result: 0xc411000000000033, writes: [], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 11): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 227, result: 0xc4110000000000e3, writes: [.init(address: 0x10038, bytes: 4, bits: 0x4), .init(address: 0x10130, bytes: 8, bits: 0x1ffffff6c)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 12): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 227, result: 0xc4110000000000e3, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 275, result: 0xc411000000000113, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x0), .init(address: 0x10090, bytes: 4, bits: 0x84321076)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 13): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
        ]
        case (.j12init, 14): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 255, result: 0xc4110000000000ff, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x4)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 15): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 255, result: 0xc4110000000000ff, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x5)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 194, result: 0xb0170000000000c2, writes: [.init(address: 0x10090, bytes: 4, bits: 0x85674321)], expectedArguments: [0x10000], expectedControl: []),
        ]
        case (.j12init, 16): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 255, result: 0xc4110000000000ff, writes: [.init(address: 0x1003c, bytes: 4, bits: 0x0)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 275, result: 0xc411000000000113, writes: [.init(address: 0x1006c, bytes: 4, bits: 0x80000000)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
        ]
        case (.j12init, 17): return [
            .init(row: 23, result: 0x50000, writes: [], expectedArguments: [0x10000,0x1,0x50], expectedControl: [0xa11713572468ace0]),
            .init(row: 86, result: 0xc411000000000056, writes: [.init(address: 0x10040, bytes: 4, bits: 0x5)], expectedArguments: [0x10000], expectedControl: [0xe113579b2468ace0]),
            .init(row: 194, result: 0xb0170000000000c2, writes: [], expectedArguments: [0x10000], expectedControl: []),
        ]
        default: throw C.Failure.invalidContract("no returning-K gap script for this seed/input")
        }
    }

    static func make(_ layout: Layout) throws -> [Witness] {
        let plannedEdges = edges(layout.seed), plannedSlots = slots(layout.seed)
        return try (1...17).map { id in
            let input = try input(id)
            var memory = O.Memory()
            memory.initialize(errorManager + 0x28, count: 8, byte: 0xd3)
            memory.initialize(deconverter, count: 0x50, byte: 0xa7)
            memory.initialize(initialSP - 0x20, count: 0x20, byte: 0xe9)
            // This must precede every context write: W10's first canary window
            // aliases count/input/output. W11 defines only the NEW store windows;
            // an old-pointer access remains undefined, never silently zero-filled.
            if let pointer = input.storePointer {
                for index in 0..<3 {
                    memory.initialize(pointer + 0x94 + UInt64(index) * 0x60 - 4, count: 16, byte: 0x6d)
                }
            }
            func put(_ address: UInt64, _ bytes: Int, _ bits: UInt64) throws {
                try memory.store(.init(address: address, bytes: bytes, bits: bits))
            }
            try put(context, 8, errorManager); try put(context + 8, 8, allocator)
            try put(context + 0x38, 4, input.count); try put(context + 0x3c, 4, input.input)
            try put(context + 0x40, 4, input.output); try put(context + 0x6c, 4, 0)
            try put(context + 0x70, 4, input.dither)
            try put(context + 0x90, 4, 0xa5a5_1290); try put(context + 0x94, 4, 0xd5d5_1294)
            try put(context + 0x98, 4, 0xe5e5_1298)
            try put(context + 0x128, 4, input.precision ?? layout.precision)
            if let pointer = input.pointer { try put(context + 0x130, 8, pointer) }
            try put(context + 0x238, 8, controller); try put(context + 0x280, 8, 0xaaaa_bbbb_cccc_dddd)
            try put(controller + 0x14, 4, input.flag)
            try put(errorManager, 8, errorTarget); try put(allocator, 8, allocatorTarget)
            for (address, bytes) in [(layout.firstTable, layout.firstBytes),
                                     (layout.firstTable + 10, layout.secondBytes),
                                     (layout.countTable, layout.countBytes)] {
                for (offset, byte) in bytes.enumerated() { memory.bytes[address + UInt64(offset)] = byte }
            }
            let script = try responses(id, layout.seed)
            var registers: [Int: UInt64] = [0: context, 31: initialSP]
            for register in 19...30 {
                registers[register] = 0xcafe_0000_0000_0000 | (UInt64(register) << 32) | UInt64(register * 0x101)
            }
            var scenario = O.Scenario(name: String(format: "gap-W%02d", id), registers: registers,
                                      memory: memory, responses: script)
            let selectedEdges = plannedEdges.filter { $0.witnesses.contains(id) }
            let selectedSlots = plannedSlots.filter { $0.witnesses.contains(id) }
            for edge in selectedEdges {
                scenario.expectedVisits[edge.sourceRow] = 1
                scenario.expectedVisits[edge.destinationRow] = 1
            }
            for row in [0, layout.finalLoad, layout.finalStore, layout.terminal] + script.map(\.row) {
                scenario.expectedVisits[row] = 1
            }
            scenario.expectedAbsentRows.formUnion(Set(layout.seed.callRows).subtracting(script.map(\.row)))
            let finalNonzero = id == 9 || id == 16
            scenario.expectedVisits[finalNonzero ? layout.finalOne : layout.finalZeroLoad] = 1
            scenario.expectedAbsentRows.insert(finalNonzero ? layout.finalZeroLoad : layout.finalOne)
            // First cold case0 is excluded only under the checked conditional
            // proof. Never mark the lifted BR defaults as executed coverage.
            scenario.expectedAbsentRows.formUnion([layout.cold, layout.firstDefault, layout.secondDefault])
            if id == 10 || id == 11 {
                for row in [layout.grayStore, layout.countLoad, layout.pointerLoad] { scenario.expectedVisits[row] = 1 }
                for row in layout.loopStore...(layout.loopStore + 2) { scenario.expectedVisits[row] = 3 }
            } else {
                scenario.expectedAbsentRows.formUnion([layout.countLoad, layout.pointerLoad, layout.loopStore])
            }
            if [5,15,17].contains(id) { scenario.expectedVisits[layout.builderStore] = 1 }
            if id == 17 {
                scenario.expectedVisits[87] = 1; scenario.expectedVisits[90] = 1
                scenario.expectedVisits[layout.pointerGuard] = 1; scenario.expectedVisits[layout.pointerFallback] = 1
                scenario.expectedAbsentRows.insert(layout.pointerTableLoad)
            }
            if [1,2].contains(id) { scenario.expectedVisits[13] = 1 }
            if [7,17].contains(id) { scenario.expectedVisits[87] = 1; scenario.expectedVisits[90] = 1 }
            if [8,9].contains(id) {
                scenario.expectedVisits[layout.seed == .jinit ? 123 : 124] = 1
                scenario.expectedVisits[layout.seed == .jinit ? 124 : 125] = 1
            }
            scenario.premises = [
                "New complete-entry returning-K input; no regional state or expected output enters the candidate.",
                "Exact ordered call responses preserve current X19...X29/SP and only original printed result authority.",
                "Frozen dispatch/count bytes and explicit sparse cells; callbacks never write dispatch memory.",
                "Four excluded CFG roles are conditional nonexecution, not tested coverage or universal callee claims."
            ]
            return Witness(id: id, scenario: scenario, edges: Set(selectedEdges.map(\.edge)),
                           residualPCs: Set(selectedSlots.map(\.pc)))
        }
    }

    /// A bounded literal proof, separate from every dynamic-coverage set. The
    /// premise is UNCHANGED dispatch bytes, not an assumption that arbitrary K
    /// callbacks cannot modify them. These particular scripts preserve the bytes.
    static func requireConditionalNonexecution(_ source: O.Program, ledger: L.Source,
                                              layout l: Layout, witnesses: [Witness]) throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw C.Failure.invalidContract("conditional color proof: " + message) }
        }
        func literal(_ row: Int, _ mnemonic: String, _ operands: String) throws {
            try require(source.rows[row].mnemonic == mnemonic && source.rows[row].operands == operands,
                        "literal premise changed at row \(row)")
        }
        let rowAt = Dictionary(uniqueKeysWithValues: source.rows.enumerated().map { ($0.element.address, $0.offset) })
        var incoming: [Int: Set<Int>] = [:]
        func add(_ from: Int, _ to: Int) throws {
            try require(source.code.indices.contains(to), "predecessor leaves complete capture")
            incoming[to, default: []].insert(from)
        }
        for (row, code) in source.code.enumerated() {
            switch code {
            case let .branch(condition, _, address):
                guard let target = rowAt[address] else { throw C.Failure.invalidContract("unbound color proof branch") }
                try add(row, target)
                if condition != "always" { try add(row, row + 1) }
            case .indirectBranch:
                let first = row == l.first + 8
                try require(first || row == l.second + 8, "unreviewed indirect predecessor")
                let entry = first ? l.first : l.second
                let bytes = first ? l.firstBytes : l.secondBytes
                let table = l.firstTable + (first ? 0 : 10)
                try literal(entry, "sub", "w8, w8, #6")
                try literal(entry + 1, "cmp", "w8, #9")
                guard case let .branch("hi", nil, destination) = source.code[entry + 2],
                      destination == source.rows[first ? l.firstDefault : l.secondDefault].address,
                      case let .page(pageRegister, page) = source.code[entry + 3],
                      pageRegister.index == 9, page == 0x59000,
                      case let .relative(baseRegister, base) = source.code[entry + 5],
                      baseRegister.index == 10, base == source.rows[entry + 9].address else {
                    throw C.Failure.invalidContract("changed unsigned guard/table/base proof")
                }
                try literal(entry + 4, "add", "x9, x9, #0x\(String(table - 0x59000, radix: 16))")
                try literal(entry + 6, "ldrb", "w11, [x9, x8]")
                try literal(entry + 7, "add", "x10, x10, x11, lsl #2")
                try literal(entry + 8, "br", "x10")
                let targets = bytes.map { entry + 9 + Int($0) }
                try require(!targets.contains(first ? l.firstDefault : l.secondDefault),
                            "frozen dispatch byte reaches lifted default")
                for target in targets { try add(row, target) }
            case .returned: break
            default: try add(row, row + 1)
            }
        }
        // Enumerating ALL literal predecessors, including the two original byte
        // tables, prevents a hidden incoming edge from defeating the proof.
        try require(incoming[l.shift] == [67,l.shift - 1] && incoming[67] == [66]
                    && incoming[l.shift - 1] == [95] && incoming[l.tst] == [l.tst - 1]
                    && incoming[l.first] == [l.tst + 1,l.tst + 4]
                    && incoming[l.shift + 1] == [l.shift] && incoming[l.tst - 1] == [l.shift + 1]
                    && incoming[l.tst + 1] == [l.tst] && incoming[l.tst + 2] == [l.tst + 1]
                    && incoming[l.tst + 3] == [l.tst + 2] && incoming[l.tst + 4] == [l.tst + 3],
                    "mask path has an unreviewed predecessor")
        for entry in [l.first,l.second] {
            for offset in 1...8 {
                try require(incoming[entry + offset] == [entry + offset - 1],
                            "guard-to-BR has another predecessor at \(entry + offset)")
            }
        }
        try literal(66, "mov", "x9, x8")
        try literal(l.shift - 1, "mov", "w9, w8")
        try literal(l.shift, "mov", "w10, #1")
        try literal(l.shift + 1, "lsl", "x9, x10, x9")
        try literal(l.tst - 1, "mov", "w10, #0x10c4")
        try literal(l.tst, "tst", "x9, x10")
        try literal(l.tst + 2, "mov", "w10, #0x144")
        try literal(l.tst + 3, "and", "x9, x9, x10")
        guard case let .branch("eq", nil, equalTarget) = source.code[l.tst + 1],
              equalTarget == source.rows[l.first].address,
              case let .branch("cbnz", .some(tested), nonzeroTarget) = source.code[l.tst + 4],
              tested.index == 9, tested.width == 64, !tested.zero,
              nonzeroTarget == source.rows[l.nullPointer].address else {
            throw C.Failure.invalidContract("changed mask branch predicate or destination")
        }
        // Case0 requires W8=6 before SUB. Both incoming MOVs establish matching
        // low6 bits, so 1<<(W8&63)=0x40 intersects BOTH masks and CBNZ bypasses
        // SUB. This does not assume high32 equality after the X-width copy.
        let coldOrdinals = l.firstBytes.enumerated().filter { l.first + 9 + Int($0.element) == l.cold }.map(\.offset)
        try require(coldOrdinals == [0] && incoming[l.cold] == [l.first + 8],
                    "cold case0 has another table ordinal or predecessor")
        try require(incoming[l.cold + 1] == [l.cold] && incoming[l.cold + 2] == [l.cold + 1],
                    "cold outgoing edge has another predecessor")
        let excluded = edges(l.seed).filter { $0.witnesses.isEmpty }
        try require(excluded.count == 4, "wrong conditional exclusion count")
        let roles: [L.Role] = [.tableCase(0), .tableDefault, .tableDefault, .unconditional]
        let proofRows = [l.first + 8,l.first + 8,l.second + 8,l.cold + 2]
        for (row, role) in zip(proofRows,roles) {
            try require(excluded.contains { item in
                item.sourceRow == row && ledger.origins.contains(.init(edge: item.edge,row: row,role: role))
            }, "conditional exclusion has no exact source role")
        }
        for witness in witnesses {
            try require(witness.scenario.startRow == 0 && witness.scenario.stopBeforeRow == nil
                        && witness.scenario.regionalBindings.isEmpty, "not a new whole-entry witness")
            for (base, bytes) in [(l.firstTable,l.firstBytes),(l.firstTable + 10,l.secondBytes)] {
                for (offset, byte) in bytes.enumerated() {
                    try require(witness.scenario.memory.bytes[base + UInt64(offset)] == byte,
                                "scenario changes a frozen dispatch byte")
                }
                let addresses = Set(bytes.indices.map { base + UInt64($0) })
                for response in witness.scenario.responses {
                    for write in response.writes {
                        try require((0..<write.bytes).allSatisfy { !addresses.contains(write.address &+ UInt64($0)) },
                                    "callback invalidates unchanged-table proof")
                    }
                }
            }
        }
    }
}
