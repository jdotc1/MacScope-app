import CryptoKit
import Foundation

/// HOP-4: address-derived identity for analysis rows. `FunctionSummary.id` and
/// `SymbolSummary.id` used to be fresh `UUID()`s on every analysis, so every list rebuilt
/// and any id held across a re-analysis went stale. They now derive from the image slot and
/// the start address (plus name/kind/occurrence for symbols, which can alias one address).
/// Ids stay unique within an image; distinct slots give distinct ids.
enum AnalysisStableIdentity {
    private static let functionDomain = "org.macscope.analysis.function-id.v1"
    private static let symbolDomain = "org.macscope.analysis.symbol-id.v1"

    static func functionID(slot: ImageSlot, startAddress: UInt64) -> UUID {
        var preimage = Data(functionDomain.utf8)
        preimage.append(0)
        append(Int64(slot.rawValue), to: &preimage)
        append(startAddress, to: &preimage)
        return derivedUUID(preimage)
    }

    static func symbolID(
        slot: ImageSlot,
        address: UInt64?,
        name: String,
        kind: String,
        occurrence: Int
    ) -> UUID {
        var preimage = Data(symbolDomain.utf8)
        preimage.append(0)
        append(Int64(slot.rawValue), to: &preimage)
        preimage.append(address == nil ? 0 : 1)
        append(address ?? 0, to: &preimage)
        append(Int64(name.utf8.count), to: &preimage)
        preimage.append(contentsOf: name.utf8)
        append(Int64(kind.utf8.count), to: &preimage)
        preimage.append(contentsOf: kind.utf8)
        append(Int64(occurrence), to: &preimage)
        return derivedUUID(preimage)
    }

    /// Re-identifies `symbols` in order. Exact duplicates of (address, name, kind) are told
    /// apart by their occurrence index, so ids remain unique within the image.
    static func assigningSymbolIDs(_ symbols: [SymbolSummary], slot: ImageSlot) -> [SymbolSummary] {
        struct Key: Hashable { let address: UInt64?; let name: String; let kind: String }
        var occurrences: [Key: Int] = [:]
        return symbols.map { symbol in
            let key = Key(address: symbol.address, name: symbol.name, kind: symbol.kind)
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return SymbolSummary(
                id: symbolID(slot: slot, address: symbol.address, name: symbol.name,
                             kind: symbol.kind, occurrence: occurrence),
                name: symbol.name,
                address: symbol.address,
                kind: symbol.kind,
                libraryName: symbol.libraryName,
                rawLinkageName: symbol.rawLinkageName
            )
        }
    }

    /// Re-derives the engine's `.primary` ids for the slot the store places an image in, and
    /// remaps every basic block's `functionID` to match. Functions with duplicate starts
    /// (never produced by the engine) keep their ids so uniqueness is never broken.
    static func restamp(_ analysis: inout ImageAnalysis, to slot: ImageSlot) {
        let startCounts = Dictionary(grouping: analysis.functions, by: \.startAddress).mapValues(\.count)
        var remap: [UUID: UUID] = [:]
        analysis.functions = analysis.functions.map { function in
            guard startCounts[function.startAddress] == 1 else { return function }
            let id = functionID(slot: slot, startAddress: function.startAddress)
            remap[function.id] = id
            return FunctionSummary(
                id: id,
                name: function.name,
                startAddress: function.startAddress,
                endAddress: function.endAddress,
                confidence: function.confidence,
                noReturnProvenance: function.noReturnProvenance
            )
        }
        if !remap.isEmpty {
            analysis.basicBlocks = analysis.basicBlocks.map { block in
                guard let id = remap[block.functionID] else { return block }
                var block = block
                block.functionID = id
                return block
            }
        }
        analysis.symbols = assigningSymbolIDs(analysis.symbols, slot: slot)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func derivedUUID(_ preimage: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: preimage).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // version 8: name-derived, implementation-defined
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
