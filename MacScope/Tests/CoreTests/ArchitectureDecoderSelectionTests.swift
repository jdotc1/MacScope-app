import Foundation
import XCTest
@testable import MacScope

/// Guards the architecture → decoder routing in `AnalysisEngine.architectureDecoder`.
///
/// Contract (PARITY_CONTRACT.md §4): only arm64 (incl. arm64e — the SAME cpuType with a
/// differing subtype) and x86_64 are disassembled. Every OTHER cpuType — 32-bit ARM,
/// i386, PowerPC, or a corrupt/unknown value — is out of scope and must NOT be silently
/// mis-decoded as arm64 (which would produce confidently-wrong disassembly). It must be
/// surfaced honestly instead.
final class ArchitectureDecoderSelectionTests: XCTestCase {
    /// arm64 `ret` (little-endian c0 03 5f d6). Used as a tripwire: if an unsupported
    /// cpuType is wrongly routed to `ARM64Decoder`, these bytes decode to mnemonic "ret".
    private let arm64Ret = Data([0xC0, 0x03, 0x5F, 0xD6])

    private func loadedBinary(cpuType: Int32) -> LoadedBinary {
        let text = BinarySection(name: ".text", address: 0x4000, size: 4, fileOffset: 0, isExecutable: true)
        return LoadedBinary(
            name: "fixture", path: "/tmp/fixture", isBundle: false,
            cpuType: cpuType, fileTypeName: "fixture", architectureDisplayName: "fixture",
            metadata: .empty, bytes: arm64Ret, sliceOffset: 0,
            sections: [text], executableTextSection: text, entryPointAddress: 0x4000,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [], objcSelectors: [:]
        )
    }

    func testUnsupportedCPUTypeDoesNotSilentlyProduceARM64Disassembly() {
        // CPU_TYPE_ARM (12, 32-bit — note arm64 is 0x0100000c, this is 0x0000000c),
        // CPU_TYPE_X86/i386 (7 — arm64 x86_64 is 0x01000007, this is 0x00000007),
        // CPU_TYPE_POWERPC64 (0x01000012), and a corrupt/unknown value.
        let unsupported: [Int32] = [0x0000_000C, 0x0000_0007, 0x0100_0012, 0x7FFF_FFFF]
        for cpuType in unsupported {
            let decoder = AnalysisEngine.architectureDecoder(for: loadedBinary(cpuType: cpuType))
            let rows = decoder.decode(arm64Ret, baseAddress: 0x4000, maxInstructionCount: 16)

            XCTAssertFalse(
                rows.contains { $0.mnemonic == "ret" },
                "cpuType \(String(format: "0x%08x", cpuType)) was silently disassembled as arm64 (got \"ret\")"
            )
            // Honest degradation: no fabricated control flow, and a diagnostic naming the
            // unsupported architecture so the analyst knows WHY there is no disassembly.
            XCTAssertTrue(rows.allSatisfy { $0.flow == .normal },
                          "unsupported arch must not invent control flow (cpuType \(cpuType))")
            XCTAssertTrue(
                rows.contains { $0.comment?.localizedCaseInsensitiveContains("unsupported") == true },
                "unsupported arch should carry a diagnostic comment (cpuType \(cpuType))"
            )
        }
    }

    func testARM64CPUTypeStillRoutesToARM64Decoder() {
        // Guard against over-correction: arm64 must still disassemble.
        let decoder = AnalysisEngine.architectureDecoder(for: loadedBinary(cpuType: MachOConstants.cpuTypeARM64))
        let rows = decoder.decode(arm64Ret, baseAddress: 0x4000, maxInstructionCount: 1)
        XCTAssertEqual(rows.first?.mnemonic, "ret")
    }

    func testX86_64CPUTypeStillRoutesToX86Decoder() {
        // x86_64 `ret` is the single byte 0xC3.
        let decoder = AnalysisEngine.architectureDecoder(for: loadedBinary(cpuType: MachOConstants.cpuTypeX86_64))
        let rows = decoder.decode(Data([0xC3]), baseAddress: 0x4000, maxInstructionCount: 1)
        XCTAssertEqual(rows.first?.mnemonic, "ret")
    }
}
