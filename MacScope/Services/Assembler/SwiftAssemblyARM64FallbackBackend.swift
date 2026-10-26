import Foundation
import SwiftAssemblyVendor

/// Narrow adapter over the reviewed direct-source swift-assembly closure.
///
/// Vendor types remain behind `ARM64AssemblyFallbackBackend`. The router owns every admission,
/// real-address, round-trip, architecture, and semantic-equivalence decision.
struct SwiftAssemblyARM64FallbackBackend: ARM64AssemblyFallbackBackend {
    func assemble(
        _ text: String,
        architecture: ARM64AssemblyArchitecture
    ) throws -> [UInt8] {
        let word = try SwiftAssemblyVendor.ARM64Assembler.assembleWord(
            text,
            architecture: vendorArchitecture(architecture)
        )
        return [
            UInt8(truncatingIfNeeded: word),
            UInt8(truncatingIfNeeded: word >> 8),
            UInt8(truncatingIfNeeded: word >> 16),
            UInt8(truncatingIfNeeded: word >> 24),
        ]
    }

    func disassemble(
        _ bytes: [UInt8],
        architecture: ARM64AssemblyArchitecture
    ) throws -> String {
        // The reviewed upstream disassembler has no architecture parameter. Requiring the exact
        // architecture at this seam still prevents arm64e requests from silently assembling as
        // arm64; the router independently validates the returned word at its real address.
        _ = architecture
        guard bytes.count == 4 else {
            throw SwiftAssemblyAdapterError.invalidInstructionByteCount
        }
        let word = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return try SwiftAssemblyVendor.ARM64Assembler.disassembleWord(word)
    }

    private func vendorArchitecture(
        _ architecture: ARM64AssemblyArchitecture
    ) -> SwiftAssemblyVendor.ARM64Assembler.Architecture {
        switch architecture {
        case .arm64: .arm64
        case .arm64e: .arm64e
        }
    }
}

private enum SwiftAssemblyAdapterError: Error {
    case invalidInstructionByteCount
}
