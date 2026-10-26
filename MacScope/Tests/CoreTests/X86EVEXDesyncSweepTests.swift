import Foundation
import XCTest
@testable import MacScope

/// Adversarial desync gate for the EVEX rendering breadth. x86 is variable-length, so a wrong length
/// on ANY EVEX form — rendered OR a length-correct placeholder — desyncs the whole linear sweep and
/// every following instruction is garbage. Compile a real AVX-512 function whose body MIXES rendered
/// forms (vpaddd/vpxord/vfmadd) with ones the decoder does NOT render (vpgatherdd/vsqrtps/vrndscaleps/
/// kxnorw), then assert the decoder stays byte-synchronized to `ret`: it must produce an instruction
/// at the EXACT offset otool places retq. If any EVEX length were wrong, the sweep would not land there.
final class X86EVEXDesyncSweepTests: XCTestCase {
    func testDecoderStaysSyncedThroughUnrenderedEVEXForms() throws {
        let clang = "/usr/bin/clang", otoolPath = "/usr/bin/otool"
        guard FileManager.default.isExecutableFile(atPath: clang),
              FileManager.default.isExecutableFile(atPath: otoolPath) else { throw XCTSkip("toolchain unavailable") }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("evexsweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("f.c"), obj = dir.appendingPathComponent("f.o")
        try """
        #include <immintrin.h>
        __attribute__((target("avx512f,avx512bw,avx512dq")))
        __m512i f(__m512i a, __m512i b, __m512i c, int* p) {
            __m512i x = _mm512_add_epi32(a, b);
            x = _mm512_xor_si512(x, c);
            x = _mm512_mullo_epi32(x, b);
            __m512i g = _mm512_i32gather_epi32(x, p, 4);
            __m512 y = _mm512_cvtepi32_ps(_mm512_add_epi32(x, g));
            y = _mm512_fmadd_ps(y, y, y);
            y = _mm512_sqrt_ps(y);
            y = _mm512_roundscale_ps(y, 0x1);
            return _mm512_cvttps_epi32(y);
        }
        """.write(to: src, atomically: true, encoding: .utf8)

        func run(_ path: String, _ args: [String]) throws -> (Int32, String) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { throw XCTSkip("could not launch \(path): \(error)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let (cstatus, cout) = try run(clang,
            ["-c", "-O2", "-arch", "x86_64", "-mavx512f", "-mavx512bw", "-mavx512dq", src.path, "-o", obj.path])
        guard cstatus == 0, FileManager.default.fileExists(atPath: obj.path) else {
            throw XCTSkip("clang did not build the avx512 object on this host: \(cout)")
        }

        // otool -> the offset of the function's `ret` (ground truth the decoder must land on).
        let (_, otoolText) = try run(otoolPath, ["-tvVj", obj.path])
        var retOffset: UInt64? = nil
        for line in otoolText.split(separator: "\n") {
            let t = line.split(separator: "\t")
            guard t.count >= 3 else { continue }
            if t[2].hasPrefix("ret"), let off = UInt64(t[0].trimmingCharacters(in: .whitespaces), radix: 16) {
                retOffset = off
            }
        }
        let ret = try XCTUnwrap(retOffset, "otool showed no ret in f — fixture assumption broken")

        let loaded = try MachOBinaryLoader().load(at: obj)
        let section = try XCTUnwrap(loaded.executableTextSection, "no __text")
        let start = Int(loaded.sliceOffset + section.fileOffset)
        let textBytes = loaded.bytes.subdata(in: start..<(start + Int(section.size)))
        let rows = X86_64Decoder().decode(textBytes, baseAddress: section.address,
                                          maxInstructionCount: Int(section.size))
        let atRet = rows.first { $0.address == section.address &+ ret }
        XCTAssertNotNil(atRet,
            "decoder DESYNCED: no instruction lands at otool's ret offset 0x\(String(ret, radix: 16)) — "
            + "a wrong EVEX length corrupted the sweep")
        XCTAssertTrue(atRet?.mnemonic.hasPrefix("ret") ?? false,
            "the instruction at the ret offset is \(atRet?.mnemonic ?? "nil"), not ret — desync")
    }
}
