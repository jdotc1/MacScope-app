/// Data-only scenarios for the complete retained jinit/j12init source streams.
/// Dispatch and count bytes are literal copies of immutable-tables.json, whose
/// provenance is a bounded __TEXT file read, not typed switch cases or execution.
/// Row expectations were reviewed against 26c78/2893c-source-rows.txt. This file
/// was authored source-only: no build, test, decoder, renderer or interpreter run.
/// Opaque responses are explicit model premises, not implementations of libjpeg.
extension RegionalSwitchOracle {
    enum ColorScenarios {
        static let context: UInt64 = 0x10000
        static let errorManager: UInt64 = 0x20000
        static let allocator: UInt64 = 0x30000
        static let controller: UInt64 = 0x40000
        static let deconverter: UInt64 = 0x50000
        static let components: UInt64 = 0x60000
        static let initialSP: UInt64 = 0x90000
        static let errorTarget: UInt64 = 0xe113_579b_2468_ace0
        static let allocatorTarget: UInt64 = 0xa117_1357_2468_ace0
        static let modeledTablePointer: UInt64 = 0xfedc_ba98_7654_3201

        // The two 68-byte count ranges are identical original file bytes.
        // In particular, entries 5 and 16 are ff ff ff ff, not invented values.
        private static let countBytes: [UInt8] = [
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0x03, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff
        ]

        private struct Layout {
            let seed: RegionalSwitchSeed
            let precision: UInt64
            let firstTable: UInt64
            let secondTable: UInt64
            let countTable: UInt64
            let firstBytes: [UInt8]
            let secondBytes: [UInt8]
            let firstEntry: Int
            let secondEntry: Int
            let firstLoad: Int
            let secondLoad: Int
            let firstBR: Int
            let secondBR: Int
            let firstADRBaseRow: Int
            let secondADRBaseRow: Int
            let firstDefault: Int
            let secondDefault: Int
            let nullPointer: Int
            let commonStore: Int
            let grayStore: Int
            let countLoad: Int
            let componentLoad: Int
            let loopStore: Int
            let finalLoad: Int
            let finalZeroLoad: Int
            let finalOne: Int
            let finalStore: Int
            let terminal: Int
            let rgbYCall: Int
            let yccCall: Int
            let yccStore: Int
            let yccPointerLoad: Int
            let yccPointerTable: UInt64
            let lastCallback: Int
            let shiftEntry: Int
            let tst: Int

            init(_ seed: RegionalSwitchSeed) throws {
                self.seed = seed
                switch seed {
                case .jinit:
                    precision = 8
                    firstTable = 0x59070; secondTable = 0x5907a; countTable = 0x59084
                    firstBytes = [0x8e, 0x00, 0x91, 0x2f, 0x32, 0x2c, 0x00, 0x2f, 0x32, 0x2c]
                    secondBytes = [0x8b, 0x00, 0x8e, 0x3a, 0x3d, 0x37, 0x00, 0x3a, 0x3d, 0x37]
                    firstEntry = 144; secondEntry = 156; firstLoad = 150; secondLoad = 162
                    firstBR = 152; secondBR = 164; firstADRBaseRow = 153; secondADRBaseRow = 165
                    firstDefault = 301; secondDefault = 310; nullPointer = 276; commonStore = 278
                    grayStore = 246; countLoad = 247; componentLoad = 250; loopStore = 253
                    finalLoad = 286; finalZeroLoad = 290; finalOne = 288; finalStore = 291; terminal = 294
                    rgbYCall = 317; yccCall = 274; yccStore = 272
                    yccPointerLoad = 195; yccPointerTable = 0x600c0; lastCallback = 285
                    shiftEntry = 136; tst = 139
                case .j12init:
                    precision = 12
                    firstTable = 0x590e8; secondTable = 0x590f2; countTable = 0x590fc
                    firstBytes = [0x83, 0x00, 0x86, 0x2d, 0x30, 0x2a, 0x00, 0x2d, 0x30, 0x2a]
                    secondBytes = [0x80, 0x00, 0x83, 0x32, 0x35, 0x2f, 0x00, 0x32, 0x35, 0x2f]
                    firstEntry = 145; secondEntry = 157; firstLoad = 151; secondLoad = 163
                    firstBR = 153; secondBR = 165; firstADRBaseRow = 154; secondADRBaseRow = 166
                    firstDefault = 291; secondDefault = 300; nullPointer = 266; commonStore = 268
                    grayStore = 239; countLoad = 240; componentLoad = 243; loopStore = 246
                    finalLoad = 276; finalZeroLoad = 280; finalOne = 278; finalStore = 281; terminal = 284
                    rgbYCall = 307; yccCall = 194; yccStore = 192
                    yccPointerLoad = 103; yccPointerTable = 0x60110; lastCallback = 275
                    shiftEntry = 137; tst = 140
                case .j16initC4Negative:
                    throw Failure.invalid("j16initC4Negative has no positive void terminal authority")
                }
            }

            var dispatchRows: Set<Int> { [firstLoad, firstBR, secondLoad, secondBR] }

            // Static ADR + 4*fileByte target relation from immutable-tables.json.
            // This is coverage bookkeeping, not evaluation of source scalar RHS
            // or a table synthesized from the production switch's typed cases.
            func targetRow(first: Bool, ordinal: Int) -> Int {
                (first ? firstADRBaseRow : secondADRBaseRow)
                    + Int((first ? firstBytes : secondBytes)[ordinal])
            }
        }

        static func all(for seed: RegionalSwitchSeed) throws -> [Scenario] {
            let layout = try Layout(seed)
            var scenarios: [Scenario] = []
            for ordinal in 1...9 {
                scenarios.append(try ordinalScenario(layout, first: true, ordinal: ordinal))
            }
            scenarios.append(try maskBypass(layout))
            for ordinal in 0...9 {
                scenarios.append(try ordinalScenario(layout, first: false, ordinal: ordinal))
            }
            for first in [true, false] {
                for below in [true, false] {
                    scenarios.append(try callbackDefault(layout, first: first, below: below))
                }
            }
            scenarios.append(try firstColdOrdinalZero(layout))
            for first in [true, false] {
                for value in [UInt64(5), 16, 0xffff_ffff, 0x8000_0006] {
                    scenarios.append(try regionalGuard(layout, first: first, value: value))
                }
            }
            for amount in [UInt64(0), 31, 32, 63, 64, 65, 70] {
                scenarios.append(try shiftRegion(layout, amount: amount))
            }
            scenarios.append(try highBitTSTRegion(layout))
            scenarios.append(try gray(layout, name: "gray-zero-iterations", count: 1, iterations: 0))
            scenarios.append(try gray(layout, name: "gray-one-iteration", count: 2, iterations: 1))
            scenarios.append(try gray(layout, name: "gray-multiple-iterations", count: 4, iterations: 3))
            scenarios.append(try gray(layout, name: "gray-four-iterations", count: 5, iterations: 4))
            scenarios.append(try gray(layout, name: "gray-signed-negative-skips-ffffffff", count: 0xffff_ffff, iterations: 0))
            scenarios.append(try gray(layout, name: "gray-signed-negative-skips-80000000", count: 0x8000_0000, iterations: 0))
            scenarios.append(try gray(layout, name: "gray-64-bit-pointer", count: 4, iterations: 3,
                                      pointer: 0x0000_0001_ffff_ff6c))
            scenarios.append(try gray(layout, name: "gray-count-memory-alias", count: 4, iterations: 3,
                                      pointer: context - 0x5c))
            scenarios.append(try exitWidth(layout, nonzero: false))
            scenarios.append(try exitWidth(layout, nonzero: true))
            scenarios.append(try coldRGBY(layout))
            scenarios.append(try yccModeledTable(layout, name: "ycc-table-modeled-memory", probe: 0))
            if seed == .jinit {
                scenarios.append(try yccModeledTable(layout, name: "ycc-simd-result-low32-zero", probe: 0x0000_0001_0000_0000))
                scenarios.append(try yccSIMDTrue(layout))
            }
            for input in [UInt64(1), 2, 3] {
                for dither in [UInt64(0), 1] {
                    scenarios.append(try rgb565(layout, input: input, dither: dither, probeTrue: false))
                }
            }
            if seed == .jinit {
                scenarios.append(try rgb565(layout, input: 3, dither: 0, probeTrue: true))
            }
            scenarios.append(try finalCallback(layout, nonzero: false))
            scenarios.append(try finalCallback(layout, nonzero: true))
            return scenarios
        }

        private static func put(_ memory: inout Memory, _ address: UInt64, _ width: Int, _ bits: UInt64) throws {
            try memory.store(Write(address: address, bytes: width, bits: bits))
        }

        private static func copy(_ bytes: [UInt8], to address: UInt64, in memory: inout Memory) {
            for (offset, byte) in bytes.enumerated() { memory.bytes[address + UInt64(offset)] = byte }
        }

        private static func initialRegisters() -> [Int: UInt64] {
            var registers: [Int: UInt64] = [0: context, 31: initialSP]
            for register in 19...30 {
                registers[register] = 0xcafe_0000_0000_0000 | (UInt64(register) << 32) | UInt64(register * 0x101)
            }
            return registers
        }

        private static func allocation() -> Response {
            Response(row: 23, result: deconverter, writes: [],
                     expectedArguments: [context, 1, 0x50], expectedControl: [allocatorTarget])
        }

        private static func callback(_ row: Int, writes: [Write] = []) -> Response {
            Response(row: row, result: 0xc411_0000_0000_0000 | UInt64(row), writes: writes,
                     expectedArguments: [context], expectedControl: [errorTarget])
        }

        private static func direct(_ row: Int, result: UInt64? = nil, writes: [Write] = []) -> Response {
            Response(row: row, result: result ?? (0xb017_0000_0000_0000 | UInt64(row)), writes: writes,
                     expectedArguments: [context], expectedControl: [])
        }

        private static func full(_ layout: Layout, name: String, input: UInt64, output: UInt64,
                                 count: UInt64, controllerFlag: UInt64 = 0, quantize: UInt64 = 0,
                                 dither: UInt64 = 0, dispatchMemory: Bool = true,
                                 componentPointer: UInt64? = nil, componentStores: Int = 0) throws -> Scenario {
            var memory = Memory()
            // Only cells and neighboring canaries needed by these modeled
            // objects are defined. No zero-filled giant context/table region.
            memory.initialize(errorManager + 0x28, count: 8, byte: 0xd3)
            memory.initialize(deconverter, count: 0x50, byte: 0xa7)
            memory.initialize(initialSP - 0x20, count: 0x20, byte: 0xe9)
            if let pointer = componentPointer {
                for index in 0..<componentStores {
                    memory.initialize(pointer + 0x94 + UInt64(index) * 0x60 - 4, count: 16, byte: 0x6d)
                }
                try put(&memory, context + 0x130, 8, pointer)
            }
            // Apply context cells after component canaries: the alias scenario
            // intentionally shares the first store with the count field.
            try put(&memory, context, 8, errorManager)
            try put(&memory, context + 8, 8, allocator)
            try put(&memory, context + 0x38, 4, count)
            try put(&memory, context + 0x3c, 4, input)
            try put(&memory, context + 0x40, 4, output)
            try put(&memory, context + 0x6c, 4, quantize)
            try put(&memory, context + 0x70, 4, dither)
            try put(&memory, context + 0x90, 4, 0xa5a5_1290)
            try put(&memory, context + 0x94, 4, 0xd5d5_1294)
            // A neighbor after the exit's four-byte destination catches widening.
            try put(&memory, context + 0x98, 4, 0xe5e5_1298)
            try put(&memory, context + 0x128, 4, layout.precision)
            try put(&memory, context + 0x238, 8, controller)
            try put(&memory, context + 0x280, 8, 0xaaaa_bbbb_cccc_dddd)
            try put(&memory, controller + 0x14, 4, controllerFlag)
            try put(&memory, errorManager, 8, errorTarget)
            try put(&memory, allocator, 8, allocatorTarget)
            copy(countBytes, to: layout.countTable, in: &memory)
            if dispatchMemory {
                copy(layout.firstBytes, to: layout.firstTable, in: &memory)
                copy(layout.secondBytes, to: layout.secondTable, in: &memory)
            }
            var scenario = Scenario(name: name, registers: initialRegisters(), memory: memory,
                                    responses: [allocation()])
            scenario.expectedVisits = [23: 1, layout.finalLoad: 1, layout.finalStore: 1, layout.terminal: 1]
            scenario.premises = [
                "Complete function entry; original void terminal only, never a physical-X0 return.",
                "Allocator K returns the explicitly modeled D; all opaque calls preserve X19...X29 and SP, invalidate volatile state, and define only their original printed result."
            ]
            expectFinalPath(&scenario, layout, quantize: quantize)
            return scenario
        }

        private static func expectFinalPath(_ scenario: inout Scenario, _ layout: Layout, quantize: UInt64) {
            if UInt32(truncatingIfNeeded: quantize) == 0 {
                scenario.expectedVisits[layout.finalZeroLoad] = 1
                scenario.expectedAbsentRows.remove(layout.finalZeroLoad)
                scenario.expectedVisits.removeValue(forKey: layout.finalOne)
                scenario.expectedAbsentRows.insert(layout.finalOne)
            } else {
                scenario.expectedVisits[layout.finalOne] = 1
                scenario.expectedAbsentRows.remove(layout.finalOne)
                scenario.expectedVisits.removeValue(forKey: layout.finalZeroLoad)
                scenario.expectedAbsentRows.insert(layout.finalZeroLoad)
            }
        }

        private static func expectDispatch(_ scenario: inout Scenario, _ layout: Layout, first: Bool, ordinal: Int) {
            let load = first ? layout.firstLoad : layout.secondLoad
            let branch = first ? layout.firstBR : layout.secondBR
            scenario.expectedVisits[load] = 1
            scenario.expectedVisits[branch] = 1
            scenario.expectedVisits[layout.targetRow(first: first, ordinal: ordinal)] = 1
            scenario.expectedVisits[layout.commonStore] = 1
            scenario.expectedAbsentRows.formUnion(first ? [layout.secondLoad, layout.secondBR] : [layout.firstLoad, layout.firstBR])
        }

        private static func ordinalScenario(_ layout: Layout, first: Bool, ordinal: Int) throws -> Scenario {
            let quantize: UInt64 = !first && ordinal % 2 == 1 ? 0x8000_0000 : 0
            var scenario = try full(layout, name: "\(first ? "first" : "second")-ordinal-\(ordinal)",
                                    input: first ? 2 : 1, output: UInt64(6 + ordinal),
                                    count: first ? 3 : 1, quantize: quantize)
            expectDispatch(&scenario, layout, first: first, ordinal: ordinal)
            scenario.expectedVisits[90] = 1
            scenario.premises.append("Every ordinal is separate, including shared-successor aliases; alternating second-switch quantize values put aliases 1/6 on opposite final-join paths.")
            return scenario
        }

        private static func maskBypass(_ layout: Layout) throws -> Scenario {
            var scenario = try full(layout, name: "first-mask-bypass-six", input: 2, output: 6, count: 3,
                                    dispatchMemory: false)
            scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            scenario.expectedVisits[layout.nullPointer] = 1
            scenario.expectedVisits[layout.commonStore] = 1
            scenario.premises.append("Complete-entry output color 6 bypasses the first switch via the fixed masks; it is not first ordinal-zero coverage.")
            return scenario
        }

        private static func callbackDefault(_ layout: Layout, first: Bool, below: Bool) throws -> Scenario {
            var scenario = try full(layout, name: "callback-default-\(first ? "first" : "second")-\(below ? "below" : "above")",
                                    input: 3, output: 7, count: 3, controllerFlag: 1, dispatchMemory: false)
            scenario.responses.append(callback(86, writes: [
                Write(address: context + 0x3c, bytes: 4, bits: first ? 2 : 1),
                Write(address: context + 0x40, bytes: 4, bits: below ? 5 : 16)
            ]))
            scenario.expectedVisits[86] = 1; scenario.expectedVisits[87] = 1; scenario.expectedVisits[90] = 1
            scenario.expectedVisits[first ? layout.firstDefault : layout.secondDefault] = 1
            scenario.expectedVisits[layout.commonStore] = 1
            scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            scenario.premises.append("Returning callback 86 rewrites both color fields before the actual LDP reload. Dispatch bytes at all four original table addresses remain undefined; color-count bytes for 5/16 remain the original ff ff ff ff.")
            return scenario
        }

        private static func region(_ layout: Layout, name: String, row: Int, inputs: [Int: UInt64],
                                   firstTableMemory: Bool) -> Scenario {
            var memory = Memory()
            memory.initialize(deconverter, count: 0x50, byte: 0xa7)
            if firstTableMemory { copy(layout.firstBytes, to: layout.firstTable, in: &memory) }
            var registers = inputs
            registers[19] = context; registers[20] = deconverter
            var scenario = Scenario(name: name, registers: registers, memory: memory, responses: [])
            scenario.startRow = row; scenario.stopBeforeRow = layout.finalLoad
            scenario.expectedAbsentRows = [layout.terminal]
            scenario.premises = [
                "Explicit regional instruction-state premise, not complete-entry reachability; stop before the shared final-exit first effect.",
                "Entry bindings are the reviewed UInt64 storage names, not discovered by running IR, source execution, or a production plan. No prologue, stack restoration, or opaque call is included."
            ]
            for (register, value) in registers {
                scenario.regionalBindings["rgn_regional_r\(register)_0"] = value
            }
            return scenario
        }

        private static func firstColdOrdinalZero(_ layout: Layout) throws -> Scenario {
            var scenario = region(layout, name: "first-cold-ordinal-zero-region", row: layout.firstEntry,
                                  inputs: [8: 6], firstTableMemory: true)
            expectDispatch(&scenario, layout, first: true, ordinal: 0)
            scenario.expectedVisits[layout.firstEntry] = 1
            scenario.premises.append("W8=6 at the original SUB row. Normal complete-entry color 6 cannot reach this case because the prior mask path bypasses it.")
            return scenario
        }

        private static func regionalGuard(_ layout: Layout, first: Bool, value: UInt64) throws -> Scenario {
            let row = first ? layout.firstEntry : layout.secondEntry
            var scenario = region(layout, name: "\(first ? "first" : "second")-guard-region-\(String(value, radix: 16))",
                                  row: row, inputs: [8: value], firstTableMemory: false)
            scenario.expectedVisits[row] = 1; scenario.expectedVisits[row + 1] = 1; scenario.expectedVisits[row + 2] = 1
            scenario.expectedVisits[first ? layout.firstDefault : layout.secondDefault] = 1
            scenario.expectedVisits[layout.commonStore] = 1
            scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            scenario.premises.append("Explicit W8 input for wrapping 32-bit subtraction and unsigned HI bounds; no giant count table or dispatch memory is supplied.")
            return scenario
        }

        private static func shiftRegion(_ layout: Layout, amount: UInt64) throws -> Scenario {
            var scenario = region(layout, name: "shift-region-\(amount)", row: layout.shiftEntry,
                                  inputs: [8: 7, 9: amount], firstTableMemory: amount != 70)
            scenario.expectedVisits[layout.shiftEntry] = 1
            scenario.expectedVisits[layout.shiftEntry + 1] = 1
            scenario.expectedVisits[layout.tst] = 1
            if amount == 70 {
                scenario.expectedVisits[layout.nullPointer] = 1
                scenario.expectedVisits[layout.commonStore] = 1
                scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            } else {
                expectDispatch(&scenario, layout, first: true, ordinal: 1)
            }
            scenario.premises.append("X9 is the named shift amount; W8=7 is a separate local selector premise. X LSL masks by 63: 64/65/70 correspond to 0/1/6. Emitted evaluation must require the actual explicit mask, not mask arbitrary C shifts.")
            return scenario
        }

        private static func highBitTSTRegion(_ layout: Layout) throws -> Scenario {
            var scenario = region(layout, name: "tst64-high-bit-region", row: layout.tst,
                                  inputs: [8: 7, 9: 0x8000_0000_0000_0000, 10: 0x8000_0000_0000_0000],
                                  firstTableMemory: true)
            scenario.expectedVisits[layout.tst] = 1
            scenario.expectedVisits[layout.tst + 1] = 1
            scenario.expectedVisits[layout.tst + 2] = 1
            scenario.expectedVisits[layout.tst + 3] = 1
            scenario.expectedVisits[layout.tst + 4] = 1
            expectDispatch(&scenario, layout, first: true, ordinal: 1)
            scenario.premises.append("Direct entry at TST bypasses the fixed-mask MOV. X9=X10=bit63 requires N=true/Z=false and the non-EQ path; a W-width TST would incorrectly skip the following mask instructions.")
            return scenario
        }

        private static func gray(_ layout: Layout, name: String, count: UInt64, iterations: Int,
                                 pointer: UInt64 = ColorScenarios.components) throws -> Scenario {
            var scenario = try full(layout, name: name, input: 1, output: 1, count: count,
                                    dispatchMemory: false, componentPointer: iterations == 0 ? nil : pointer,
                                    componentStores: iterations)
            if count != 1 { scenario.responses.append(callback(51)); scenario.expectedVisits[51] = 1 }
            scenario.expectedVisits[layout.grayStore] = 1
            scenario.expectedVisits[layout.countLoad] = 1
            scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            if iterations == 0 {
                scenario.expectedAbsentRows.formUnion([layout.componentLoad, layout.loopStore, layout.loopStore + 1, layout.loopStore + 2])
            } else {
                scenario.expectedVisits[layout.componentLoad] = 1
                scenario.expectedVisits[layout.loopStore] = iterations
                scenario.expectedVisits[layout.loopStore + 1] = iterations
                scenario.expectedVisits[layout.loopStore + 2] = iterations
            }
            scenario.premises.append("Returning component-error K51, when present, is modeled. STR uses four bytes and old pointer; +0x60 pointer and X64 SUBS counter must both feed every backedge. Nonzero neighboring bytes expose widening.")
            if iterations == 0 {
                scenario.premises.append("The components-pointer cell and component store memory are undefined because the signed W count comparison must skip the loop.")
            } else if pointer == context - 0x5c {
                scenario.premises.append("The first loop store aliases C+0x38; its zero does not change the snapshotted X9 recurrence. Three stores still occur at C+0x38, C+0x98, C+0xf8.")
            } else if pointer != components {
                scenario.premises.append("P=0x00000001ffffff6c makes the first store 0x0000000200000000, testing 64-bit address carry rather than a truncated W pointer.")
            }
            return scenario
        }

        private static func exitWidth(_ layout: Layout, nonzero: Bool) throws -> Scenario {
            var scenario = try full(layout, name: "exit-low32-\(nonzero ? "nonzero" : "zero")", input: 2, output: 7,
                                    count: 3, quantize: nonzero ? 0x8000_0000 : 0, dither: 0xdecafbad)
            expectDispatch(&scenario, layout, first: true, ordinal: 1)
            scenario.premises.append("Adjacent dither is nonzero even when quantize low32 is zero; final load/store widths are four bytes. Quantize nonzero selects constant 1 without loading outputComponents.")
            return scenario
        }

        private static func coldRGBY(_ layout: Layout) throws -> Scenario {
            var scenario = try full(layout, name: "cold-rgb-y-call", input: 2, output: 1, count: 3, dispatchMemory: false)
            scenario.responses.append(direct(layout.rgbYCall, writes: [
                Write(address: context + 0x90, bytes: 4, bits: 0x8000_0002),
                Write(address: initialSP - 0x18, bytes: 8, bits: 0x8bad_f00d_1919_1919)
            ]))
            scenario.expectedVisits[layout.rgbYCall - 2] = 1
            scenario.expectedVisits[layout.rgbYCall] = 1
            scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            scenario.premises.append("The post-RET builder block is reached before RET. Its explicit K writes outputComponents and the saved-X19 stack cell; live C/D remain the pre-epilogue values, not textual-order restored values.")
            return scenario
        }

        private static func yccModeledTable(_ layout: Layout, name: String, probe: UInt64) throws -> Scenario {
            var scenario = try full(layout, name: name, input: 3, output: 7, count: 3, dispatchMemory: false)
            // Only ordinal one's cell is modeled. These are NOT on-disk words
            // with fixup bits removed and make no claim about actual dyld output.
            try put(&scenario.memory, layout.yccPointerTable + 8, 8, modeledTablePointer)
            if layout.seed == .jinit {
                scenario.responses.append(direct(99, result: probe))
                scenario.expectedVisits[99] = 1
            }
            scenario.responses.append(direct(layout.yccCall))
            scenario.expectedVisits[layout.yccPointerLoad] = 1
            scenario.expectedVisits[layout.yccStore] = 1
            scenario.expectedVisits[layout.yccCall] = 1
            scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            scenario.expectedAbsentRows.insert(layout.commonStore)
            scenario.premises.append("Model-relative pointer-table memory only: the selected original-address 8-byte cell contains 0xfedcba9876543201. No chained-fixup masking, rebasing theorem, or real callee behavior is assumed.")
            if layout.seed == .jinit {
                scenario.premises.append("Probe row99 is tested as W0; the explicitly scripted result has low32 zero, including the high64-nonzero variant.")
            }
            return scenario
        }

        private static func yccSIMDTrue(_ layout: Layout) throws -> Scenario {
            var scenario = try full(layout, name: "ycc-simd-result-low32-nonzero", input: 3, output: 7, count: 3,
                                    dispatchMemory: false)
            scenario.responses.append(direct(99, result: 0x8000_0000_0000_0001))
            scenario.expectedVisits[99] = 1
            scenario.expectedVisits[101] = 1
            scenario.expectedVisits[layout.commonStore] = 1
            scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            scenario.expectedAbsentRows.formUnion([layout.yccPointerLoad, layout.yccCall])
            scenario.premises.append("The scripted probe has low32 nonzero; no modeled pointer-table cell or builder response exists on this branch. Probe bits are not a callee success claim.")
            return scenario
        }

        private static func rgb565(_ layout: Layout, input: UInt64, dither: UInt64, probeTrue: Bool) throws -> Scenario {
            var scenario = try full(layout, name: "rgb565-flags-survive-cbz-input-\(input)-dither-\(dither)\(probeTrue ? "-probe-true" : "")",
                                    input: input, output: 16, count: input == 1 ? 1 : 3, dither: dither,
                                    dispatchMemory: false)
            let isJinit = layout.seed == .jinit
            scenario.expectedVisits[isJinit ? 125 : 126] = 1
            scenario.expectedVisits[isJinit ? 126 : 127] = 1
            scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            if input == 1 || input == 2 {
                let target: Int
                if input == 1 { target = dither == 0 ? (isJinit ? 328 : 318) : (isJinit ? 322 : 312) }
                else { target = dither == 0 ? (isJinit ? 325 : 315) : (isJinit ? 319 : 309) }
                scenario.expectedVisits[target] = 1
                scenario.expectedVisits[layout.commonStore] = 1
            } else {
                if isJinit && dither == 0 {
                    scenario.responses.append(direct(212, result: probeTrue ? 0x8000_0000_0000_0001 : 0x0000_0001_0000_0000))
                    scenario.expectedVisits[212] = 1
                }
                if isJinit && dither == 0 && probeTrue {
                    scenario.expectedVisits[101] = 1
                    scenario.expectedVisits[layout.commonStore] = 1
                    scenario.expectedAbsentRows.insert(layout.yccCall)
                } else {
                    scenario.responses.append(direct(layout.yccCall))
                    scenario.expectedVisits[layout.yccStore] = 1
                    scenario.expectedVisits[layout.yccCall] = 1
                }
            }
            scenario.premises.append("CMP inputColor precedes CBZ dither. CBZ must preserve those flags for the later EQ; source-order incoming state is retained across the cold join.")
            return scenario
        }

        private static func finalCallback(_ layout: Layout, nonzero: Bool) throws -> Scenario {
            let newQuantize: UInt64 = nonzero ? 0x8000_0000 : 0
            var scenario = try full(layout, name: "callback-mutates-final-load\(nonzero ? "-nonzero" : "")",
                                    input: 1, output: 5, count: 1, quantize: nonzero ? 0 : 1, dispatchMemory: false)
            scenario.responses.append(callback(layout.lastCallback, writes: [
                Write(address: context + 0x6c, bytes: 4, bits: newQuantize),
                Write(address: context + 0x90, bytes: 4, bits: 0x8765_4321)
            ]))
            scenario.expectedVisits[layout.lastCallback] = 1
            scenario.expectedAbsentRows.formUnion(layout.dispatchRows)
            expectFinalPath(&scenario, layout, quantize: newQuantize)
            scenario.premises.append("The returning last-error K changes quantize and outputComponents before final loads, and returns unrelated high-bit data. No terminal-X0 dependency is introduced; the captured return stays void.")
            return scenario
        }
    }
}
