import Foundation
import XCTest
@testable import MacScope

final class D06SelectedLaneStoreTests: XCTestCase {
    private func row(_ word: UInt32, at address: UInt64 = 0x400100) throws -> InstructionRow {
        let bytes = withUnsafeBytes(of: word.littleEndian) { Data($0) }
        let decoded = try XCTUnwrap(ARM64Decoder().decode(bytes, baseAddress: address,
            maxInstructionCount: 1).first)
        return InstructionRow(address: address, bytes: decoded.byteText,
            mnemonic: decoded.mnemonic, operands: decoded.operands,
            hasBreakpoint: false, comment: decoded.comment)
    }

    func testWitnessAndUpperLaneStoresUseExactBytesAndReadOnlySources() throws {
        // First two are real libjpeg merged-upsample byte-store forms. Others
        // exercise Q's lane-index bit, each element size and register-list wrap.
        let cases: [(UInt32, Int, Int, Int, Bool)] = [
            (0x0d00_3943, 3, 1, 6, false),
            (0x0d20_3944, 4, 1, 6, false),
            (0x4d9f_1d9f, 1, 1, 15, true),
            (0x4dbf_593f, 2, 2, 7, true),
            (0x4d9f_b11e, 3, 4, 3, true),
            (0x4dbf_a51e, 4, 8, 1, true),
        ]
        for (word, count, bytes, lane, post) in cases {
            let decoded = try row(word)
            let function = MacIRBuilder().buildFunction(name: "selected_store",
                startAddress: decoded.address, instructions: [decoded])
            let frame = try XCTUnwrap(function.instructions.first?.neonStructureLaneMemory?.frame,
                "\(decoded.mnemonic) \(decoded.operands)")
            XCTAssertEqual(frame.effect, .store)
            XCTAssertEqual(frame.structureCount, count)
            XCTAssertEqual(frame.elementBytes, bytes)
            XCTAssertEqual(frame.laneIndex, lane)
            let firstVector = Int(word & 31)
            XCTAssertEqual(frame.oldVectors.compactMap { value -> String? in
                guard case let .register(name, _) = value else { return nil }
                return name
            }, (0..<count).map { "v\((firstVector + $0) % 32)" })
            XCTAssertTrue(frame.destinations.isEmpty, "Stores never define or clear vector bits")
            XCTAssertEqual(frame.byteCount, count * bytes)
            XCTAssertEqual(frame.fixedPostDelta, post ? count * bytes : 0)
            XCTAssertEqual(frame.orderedBytes.map(\.offset), Array(0..<(count * bytes)))
            XCTAssertEqual(frame.orderedBytes.map(\.lane), (0..<count).flatMap { _ in
                Array((lane * bytes)..<((lane + 1) * bytes))
            })
            XCTAssertEqual(frame.orderedBytes.map(\.vector), (0..<count).flatMap { n in
                Array(repeating: n, count: bytes)
            })
            XCTAssertEqual(function.instructions.count, count + (post ? 1 : 0))
            for instruction in function.instructions.prefix(count) {
                guard case .intrinsic(nil, _, _) = instruction.operation else {
                    XCTFail("store must not write a vector"); continue
                }
            }
            let text = PseudocodePrinter(options: DecompilerOptions(
                structureControlFlow: true, deadCodeElimination: false,
                nopElision: false, functionSizeGate: 1_024)).print(function: function).text
            XCTAssertTrue(text.contains("__neon_extract_lane_\(bytes * 8)_at_\(lane)"), text)
            XCTAssertFalse(text.contains("__unknown"), text)
        }
    }

    func testMalformedOrUnsupportedSingleStructuresRemainRefused() throws {
        let good = try row(0x0d00_3943)
        for text in ["{v3.b, v4.b, v6.b}[6], [x10]", "{v3.b, v4.b, v5.b}[7], [x10]",
                     "{v3.h, v4.h, v5.h}[6], [x10]", "{v3.b, v4.b, v5.b}[6], [x11]",
                     "{v3.b, v4.b, v5.b}[6], [x10], #3"] {
            let malformed = InstructionRow(address: good.address, bytes: good.bytes,
                mnemonic: good.mnemonic, operands: text, hasBreakpoint: false, comment: nil)
            XCTAssertNil(MacIRBuilder.neonStructureLaneMemory(malformed), text)
        }
        // Unsupported load and new ST4 SP/register-post forms remain outside this route.
        // Existing LD4 and ST3 SP/register-post support is preserved.
        for word: UInt32 in [0x0d40_3943, 0x0d20_3be3, 0x0da1_3943] {
            XCTAssertNil(MacIRBuilder.neonStructureLaneMemory(try row(word)))
        }
        for word: UInt32 in [0x0d60_3943, 0x0d00_3be3, 0x0d81_3943] {
            XCTAssertNotNil(MacIRBuilder.neonStructureLaneMemory(try row(word)))
        }
        // Reserved halfword size bit and reserved D-lane S bit cannot be admitted
        // even if forged display text happens to describe a valid instruction.
        for word: UInt32 in [0x0d00_6443, 0x0d00_b443, 0x0d01_3943, 0x0d00_e143] {
            let bytes = withUnsafeBytes(of: word.littleEndian) { Array($0) }
                .map { String(format: "%02x", $0) }.joined(separator: " ")
            let forged = InstructionRow(address: good.address, bytes: bytes, mnemonic: "st3",
                operands: good.operands, hasBreakpoint: false, comment: nil)
            XCTAssertNil(MacIRBuilder.neonStructureLaneMemory(forged))
        }
        // A rejected encoded post-index store still poisons the base, not vectors.
        let post = try row(0x0d9f_3943)
        let malformed = InstructionRow(address: post.address, bytes: post.bytes, mnemonic: post.mnemonic,
            operands: "{v3.b, v4.b, v6.b}[6], [x10], #3", hasBreakpoint: false, comment: nil)
        var state = BuilderState(parameters: [])
        state.permitsNEONBufferCarrier = true
        _ = state.writeRegister("x10")
        let oldVector = state.writeRegister("v3")
        _ = MacIRBuilder().generalVectorRefusal(malformed, state: &state)
        XCTAssertEqual(state.readRegister("x10"), .unknown("unavailable_x10"))
        XCTAssertEqual(state.readRegister("v3"), oldVector)
    }

    func testSelectedLaneMetadataRefusesOutOfRangeLanesAndStoreDestinations() {
        for lane in [-1, 2] {
            XCTAssertNil(MacIRNEONStructureLaneMemory(effect: .store, elementBytes: 8,
                laneIndex: lane, structureCount: 1, baseRegister: "x10",
                oldBase: .register(name: "x10", version: 0),
                oldVectors: [.register(name: "v0", version: 0)], destinations: [],
                baseDestination: nil, frameSequence: 0, firstByteSequence: 0))
        }
        XCTAssertNil(MacIRNEONStructureLaneMemory(effect: .store, elementBytes: 8,
            laneIndex: 0, structureCount: 1, baseRegister: "x10",
            oldBase: .register(name: "x10", version: 0),
            oldVectors: [.register(name: "v0", version: 0)],
            destinations: [.register(name: "v0", version: 1)],
            baseDestination: nil, frameSequence: 0, firstByteSequence: 0))
        // Count one is added for stores only; existing load descriptors retain
        // their established two-to-four structure domain.
        XCTAssertNil(MacIRNEONStructureLaneMemory(effect: .load, elementBytes: 8,
            laneIndex: 0, structureCount: 1, baseRegister: "x10",
            oldBase: .register(name: "x10", version: 0),
            oldVectors: [.register(name: "v0", version: 0)],
            destinations: [.register(name: "v0", version: 1)],
            baseDestination: nil, frameSequence: 0, firstByteSequence: 0))
    }

    func testConcreteStorePreservesVectorsAndUntouchedMemoryThenWritesBack() throws {
        for word: UInt32 in [0x0d00_3943, 0x0d20_3944, 0x4d9f_1d9f, 0x4dbf_593f, 0x4d9f_b11e, 0x4dbf_a51e] {
            let decoded = try row(word)
            let function = MacIRBuilder().buildFunction(name: "concrete_lane_store",
                startAddress: decoded.address, instructions: [decoded])
            let frame = try XCTUnwrap(function.instructions.first?.neonStructureLaneMemory?.frame)
            let empty = A64OracleVector.State(gpr: nil, sp: nil, pc: nil, nzcv: nil,
                fpcr: nil, fpsr: nil, vectors: nil, memory: nil)
            var initial = try A64MachineState(seeding: empty)
            let baseIndex = try XCTUnwrap(Int(frame.baseRegister.dropFirst()))
            initial.x[baseIndex] = 0x500108 // Unaligned for ST4 .D's total span.
            initial.fpsr = 0x08000000
            for n in 0..<32 {
                initial.v[n] = .init(low: 0x0706_0504_0302_0100 &+ UInt64(n) * 0x0101_0101_0101_0101,
                                     high: 0x0f0e_0d0c_0b0a_0908 &+ UInt64(n) * 0x0101_0101_0101_0101)
            }
            for offset in -8..<40 { initial.setByte(0xa5, at: UInt64(Int64(initial.x[baseIndex]) + Int64(offset))) }
            var expectedMemory = initial.memory
            for byte in frame.orderedBytes {
                guard case let .register(name, _) = frame.oldVectors[byte.vector],
                      let vectorIndex = Int(name.dropFirst()) else { return XCTFail("physical source") }
                let vector = initial.v[vectorIndex]
                let value = UInt8(truncatingIfNeeded: (byte.lane < 8 ? vector.low : vector.high) >> ((byte.lane % 8) * 8))
                let address = initial.x[baseIndex] + UInt64(byte.offset)
                if value == 0 { expectedMemory.removeValue(forKey: address) } else { expectedMemory[address] = value }
            }
            var evaluator = MacIRConcreteEvaluator(function: function, state: initial)
            try evaluator.run(function.instructions)
            XCTAssertEqual(evaluator.state.memory, expectedMemory)
            XCTAssertEqual(evaluator.state.v, initial.v)
            var expectedGPRs = initial.x
            expectedGPRs[baseIndex] += UInt64(frame.fixedPostDelta)
            XCTAssertEqual(evaluator.state.x, expectedGPRs)
            XCTAssertEqual(evaluator.state.fpsr, initial.fpsr)
        }
    }

}
