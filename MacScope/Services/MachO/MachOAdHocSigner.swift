import CryptoKit
import Foundation

/// D07: replaces a thin arm64 executable's final code signature with an in-process **ad-hoc**
/// signature over its current bytes, so a patched or cave-appended export is runnable without a
/// `codesign` subprocess. The new signature carries the identifier, the hardened-runtime flag and
/// the entitlement blobs of the old one; it never claims a team or certificate identity.
///
/// Layout handled: `LC_CODE_SIGNATURE` names the final `__LINKEDIT` payload (what
/// `MachOPatchWriter` produces for both patches and appended caves). Anything else is refused and
/// the caller keeps the unsigned output.
enum MachOAdHocSigner {
    enum Refusal: Error, Equatable, Sendable {
        case notThinARM64Executable
        case noCodeSignature
        case signatureNotFinalLinkeditPayload
        case malformedSignature
        case layoutOverflow
    }

    struct Outcome: Equatable, Sendable {
        let data: Data
        let identifier: String
        /// Entitlements an ad-hoc signature cannot honor (they need a provisioning profile or a
        /// platform signature): the file is written, but it may not launch.
        let restrictedEntitlements: [String]
        var warnings: [String] {
            restrictedEntitlements.isEmpty ? [] : [
                "The output is ad-hoc signed, but it carries entitlements an ad-hoc signature cannot honor "
                    + "(\(restrictedEntitlements.joined(separator: ", "))); macOS may refuse to launch it. "
                    + "Re-sign it with an identity and provisioning profile that grant them, or remove them.",
            ]
        }
    }

    static let pageSizeLog2: UInt8 = 12
    private static let pageSize = 1 << 12

    /// Presence only: validates the load-command bounds, not the signature's contents or trust.
    static func hasCodeSignatureCommand(_ input: Data) -> Bool {
        let bytes = [UInt8](input)
        guard bytes.count >= 32, le32(bytes, 0) == 0xfeed_facf else { return false }
        let commandBytes = Int(le32(bytes, 20))
        guard commandBytes <= bytes.count - 32 else { return false }
        let commandEnd = 32 + commandBytes
        var cursor = 32
        var found = false
        for _ in 0 ..< Int(le32(bytes, 16)) {
            guard commandEnd - cursor >= 8 else { return false }
            let command = le32(bytes, cursor), size = Int(le32(bytes, cursor + 4))
            guard size >= 8, size <= commandEnd - cursor else { return false }
            if command == MachOConstants.loadCommandCodeSignature {
                guard size >= 16 else { return false }
                found = true
            }
            cursor += size
        }
        return found
    }

    static func resign(_ input: Data) throws -> Outcome {
        var bytes = [UInt8](input)
        guard bytes.count >= 32, le32(bytes, 0) == 0xfeed_facf, le32(bytes, 4) == 0x0100_000c,
              le32(bytes, 12) == MachOConstants.fileTypeExecute else { throw Refusal.notThinARM64Executable }
        let commandCount = Int(le32(bytes, 16))
        let commandBytes = Int(le32(bytes, 20))
        guard commandBytes <= bytes.count - 32 else { throw Refusal.malformedSignature }
        let commandEnd = 32 + commandBytes
        var cursor = 32
        var signatureCommand: Int?
        var linkeditCommand: Int?
        var textSegment: (fileOffset: UInt64, fileSize: UInt64)?
        for _ in 0 ..< commandCount {
            guard commandEnd - cursor >= 8 else { throw Refusal.malformedSignature }
            let command = le32(bytes, cursor), size = Int(le32(bytes, cursor + 4))
            guard size >= 8, size <= commandEnd - cursor else { throw Refusal.malformedSignature }
            if command == MachOConstants.loadCommandCodeSignature {
                guard size >= 16, signatureCommand == nil else { throw Refusal.malformedSignature }
                signatureCommand = cursor
            } else if command == MachOConstants.loadCommandSegment64, size >= 72 {
                let name = segmentName(bytes, cursor + 8)
                if name == "__LINKEDIT" { linkeditCommand = cursor }
                if name == "__TEXT" { textSegment = (le64(bytes, cursor + 40), le64(bytes, cursor + 48)) }
            }
            cursor += size
        }
        guard let signatureCommand else { throw Refusal.noCodeSignature }
        guard let linkeditCommand, let textSegment else { throw Refusal.signatureNotFinalLinkeditPayload }
        let dataOffset = Int(le32(bytes, signatureCommand + 8)), dataSize = Int(le32(bytes, signatureCommand + 12))
        guard let linkeditFileOffset = Int(exactly: le64(bytes, linkeditCommand + 40)),
              let linkeditFileSize = Int(exactly: le64(bytes, linkeditCommand + 48)) else {
            throw Refusal.layoutOverflow
        }
        let (dataEnd, dataOverflow) = dataOffset.addingReportingOverflow(dataSize)
        let (linkeditEnd, linkeditOverflow) = linkeditFileOffset.addingReportingOverflow(linkeditFileSize)
        guard !dataOverflow, !linkeditOverflow else { throw Refusal.layoutOverflow }
        guard dataEnd == bytes.count, linkeditEnd == bytes.count,
              dataOffset >= linkeditFileOffset, dataOffset % 16 == 0 else {
            throw Refusal.signatureNotFinalLinkeditPayload
        }
        let old = try parseSuperBlob(Array(bytes[dataOffset...]))

        // Blobs carried over; the requirement set is the empty one an ad-hoc signature uses.
        let requirements: [UInt8] = be32(0xfade_0c01) + be32(12) + be32(0)
        var specials: [Int: [UInt8]] = [2: requirements]
        if let entitlements = old.blobs[5] { specials[5] = entitlements }
        if let der = old.blobs[7] { specials[7] = der }
        let specialSlotCount = specials.keys.max() ?? 2
        let codeLimit = dataOffset
        let codeSlotCount = (codeLimit + pageSize - 1) / pageSize
        let identifier = old.identifier.isEmpty ? "macscope.patched" : old.identifier
        let identifierBytes = Array(identifier.utf8) + [0]
        let headerSize = 88 // CodeDirectory version 0x20400 (through execSegFlags)
        let hashOffset = headerSize + identifierBytes.count + specialSlotCount * 32
        let directorySize = hashOffset + codeSlotCount * 32
        let blobTypes = specials.keys.sorted()
        let indexSize = 12 + 8 * (1 + blobTypes.count)
        let superSize = indexSize + directorySize + blobTypes.reduce(0) { $0 + specials[$1]!.count }
        let paddedSize = (superSize + 15) & ~15

        // Sizes first: the load commands sit in the first page and are hashed with it.
        let newEnd = dataOffset + paddedSize
        guard newEnd <= Int(UInt32.max) else { throw Refusal.layoutOverflow }
        put32(UInt32(paddedSize), into: &bytes, at: signatureCommand + 12)
        let newLinkeditSize = UInt64(newEnd - linkeditFileOffset)
        put64(newLinkeditSize, into: &bytes, at: linkeditCommand + 48)
        let vmPage: UInt64 = 0x4000
        put64((newLinkeditSize + vmPage - 1) & ~(vmPage - 1), into: &bytes, at: linkeditCommand + 32)
        bytes.removeSubrange(dataOffset...)

        var directory: [UInt8] = []
        directory += be32(0xfade_0c02) + be32(UInt32(directorySize)) + be32(0x0002_0400)
        let flags: UInt32 = 0x2 | (old.flags & 0x0001_0000) // CS_ADHOC | keep CS_RUNTIME
        directory += be32(flags) + be32(UInt32(hashOffset)) + be32(UInt32(headerSize))
        directory += be32(UInt32(specialSlotCount)) + be32(UInt32(codeSlotCount)) + be32(UInt32(codeLimit))
        directory += [32, 2, 0, pageSizeLog2] + be32(0) // hashSize, SHA-256, platform, page size, spare2
        directory += be32(0) + be32(0) + be32(0) + be64(0) // scatter, team, spare3, codeLimit64
        directory += be64(textSegment.fileOffset) + be64(textSegment.fileSize) + be64(0x1) // exec seg, main binary
        directory += identifierBytes
        for slot in stride(from: specialSlotCount, through: 1, by: -1) {
            directory += specials[slot].map { Array(SHA256.hash(data: $0)) } ?? [UInt8](repeating: 0, count: 32)
        }
        for page in 0 ..< codeSlotCount {
            let start = page * pageSize
            directory += Array(SHA256.hash(data: bytes[start ..< min(start + pageSize, codeLimit)]))
        }
        guard directory.count == directorySize else { throw Refusal.layoutOverflow }

        var signature = be32(0xfade_0cc0) + be32(UInt32(superSize)) + be32(UInt32(1 + blobTypes.count))
        var offset = indexSize
        signature += be32(0) + be32(UInt32(offset)); offset += directory.count
        for type in blobTypes {
            signature += be32(UInt32(type)) + be32(UInt32(offset)); offset += specials[type]!.count
        }
        signature += directory
        for type in blobTypes { signature += specials[type]! }
        signature += [UInt8](repeating: 0, count: paddedSize - signature.count)
        bytes += signature
        return Outcome(data: Data(bytes), identifier: identifier,
                       restrictedEntitlements: restrictedEntitlements(specials[5]))
    }

    // MARK: - Old signature

    private struct OldSignature { let identifier: String; let flags: UInt32; let blobs: [Int: [UInt8]] }

    private static func parseSuperBlob(_ blob: [UInt8]) throws -> OldSignature {
        guard blob.count >= 12, be32At(blob, 0) == 0xfade_0cc0 else { throw Refusal.malformedSignature }
        let length = Int(be32At(blob, 4)), count = Int(be32At(blob, 8))
        guard length <= blob.count, count < 64, 12 + count * 8 <= length else { throw Refusal.malformedSignature }
        var blobs: [Int: [UInt8]] = [:]
        var identifier = "", flags: UInt32 = 0
        for index in 0 ..< count {
            let type = Int(be32At(blob, 12 + index * 8)), offset = Int(be32At(blob, 16 + index * 8))
            guard offset + 8 <= length else { throw Refusal.malformedSignature }
            let size = Int(be32At(blob, offset + 4))
            guard size >= 8, offset + size <= length else { throw Refusal.malformedSignature }
            let payload = Array(blob[offset ..< offset + size])
            if type == 0, be32At(payload, 0) == 0xfade_0c02, payload.count >= 24 {
                flags = be32At(payload, 12)
                let identOffset = Int(be32At(payload, 20))
                if identOffset < payload.count, let end = payload[identOffset...].firstIndex(of: 0) {
                    identifier = String(decoding: payload[identOffset ..< end], as: UTF8.self)
                }
            } else if type == 5 || type == 7 {
                blobs[type] = payload
            }
        }
        return OldSignature(identifier: identifier, flags: flags, blobs: blobs)
    }

    /// Keys an ad-hoc signature cannot grant (provisioning-profile or platform-only).
    static func restrictedEntitlements(_ blob: [UInt8]?) -> [String] {
        guard let blob, blob.count > 8,
              let plist = try? PropertyListSerialization.propertyList(from: Data(blob[8...]), format: nil),
              let dictionary = plist as? [String: Any] else { return [] }
        return dictionary.keys.filter { key in
            key.hasPrefix("com.apple.developer.") || key.hasPrefix("com.apple.private.")
                || ["com.apple.application-identifier", "application-identifier", "keychain-access-groups",
                    "com.apple.security.application-groups"].contains(key)
        }.sorted()
    }

    // MARK: - Bytes

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func le64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(le32(b, o)) | UInt64(le32(b, o + 4)) << 32 }
    private static func be32At(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    private static func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xffff_ffff)) }
    private static func put32(_ v: UInt32, into b: inout [UInt8], at o: Int) {
        for i in 0 ..< 4 { b[o + i] = UInt8(v >> (8 * UInt32(i)) & 0xff) }
    }
    private static func put64(_ v: UInt64, into b: inout [UInt8], at o: Int) {
        for i in 0 ..< 8 { b[o + i] = UInt8(v >> (8 * UInt64(i)) & 0xff) }
    }
    private static func segmentName(_ b: [UInt8], _ o: Int) -> String {
        String(decoding: b[o ..< o + 16].prefix { $0 != 0 }, as: UTF8.self)
    }
}

extension WorkspaceScriptingAPI {
    nonisolated static func isUnsigned(_ signing: PreparedMachOPatchExport.Signing) -> Bool {
        if case .unsigned = signing { return true }
        return false
    }

    nonisolated static func signingKind(_ signing: PreparedMachOPatchExport.Signing) -> String {
        switch signing {
        case .unchanged: "unchanged"
        case .adHoc: "ad-hoc"
        case .unsigned: "unsigned"
        }
    }

    nonisolated static func signingWarnings(_ signing: PreparedMachOPatchExport.Signing) -> [String] {
        if case let .adHoc(_, warnings) = signing { return warnings }
        return []
    }
}
