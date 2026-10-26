import CryptoKit
import Foundation

struct ELFArchiveMember: Hashable, Sendable {
    /// Stable index among ordinary archive members, including non-ELF members.
    let index: Int
    /// Physical header ordinal, useful for diagnostics when special members were skipped.
    let archiveHeaderIndex: Int
    /// Sanitized display identity only. This value is never a filesystem path.
    let name: String
    let payloadRange: Range<Int>
    let isELF: Bool
    let sha256: String

    var byteCount: Int { payloadRange.count }

    var identity: ELFArchiveMemberIdentity {
        ELFArchiveMemberIdentity(
            index: index,
            archiveHeaderIndex: archiveHeaderIndex,
            name: name,
            payloadOffset: payloadRange.lowerBound,
            byteCount: byteCount,
            sha256: sha256
        )
    }
}

struct ELFArchiveCatalog: Hashable, Sendable {
    let containerIdentity: ELFArchiveContainerIdentity
    let members: [ELFArchiveMember]

    var elfMembers: [ELFArchiveMember] { members.filter(\.isELF) }
}

struct ELFArchiveParserLimits: Hashable, Sendable {
    static let product = ELFArchiveParserLimits()

    let maximumArchiveBytes: Int
    let maximumMembers: Int
    let maximumMemberBytes: Int
    let maximumAggregateMemberBytes: Int
    let maximumNameBytes: Int
    let maximumLongNameTableBytes: Int

    init(
        maximumArchiveBytes: Int = 512 * 1024 * 1024,
        maximumMembers: Int = 100_000,
        maximumMemberBytes: Int = 256 * 1024 * 1024,
        maximumAggregateMemberBytes: Int = 512 * 1024 * 1024,
        maximumNameBytes: Int = 4_096,
        maximumLongNameTableBytes: Int = 64 * 1024 * 1024
    ) {
        self.maximumArchiveBytes = max(0, maximumArchiveBytes)
        self.maximumMembers = max(0, maximumMembers)
        self.maximumMemberBytes = max(0, maximumMemberBytes)
        self.maximumAggregateMemberBytes = max(0, maximumAggregateMemberBytes)
        self.maximumNameBytes = max(0, maximumNameBytes)
        self.maximumLongNameTableBytes = max(0, maximumLongNameTableBytes)
    }
}

enum ELFArchiveParseError: LocalizedError, Equatable {
    case notArchive
    case thinArchiveUnsupported
    case cancelled
    case truncated(String)
    case malformed(String)
    case boundExceeded(String)

    var errorDescription: String? {
        switch self {
        case .notArchive:
            return "The file is not a Unix archive."
        case .thinArchiveUnsupported:
            return "Thin Unix archives are not supported."
        case .cancelled:
            return "Unix archive parsing was cancelled."
        case .truncated(let detail):
            return "The Unix archive is truncated (\(detail))."
        case .malformed(let detail):
            return "The Unix archive is malformed (\(detail))."
        case .boundExceeded(let detail):
            return "The Unix archive exceeds a parser bound (\(detail))."
        }
    }
}

/// Bounded parser for SysV/GNU and BSD `ar` containers. Archive member names are presentation
/// only: the parser never resolves them against the filesystem or lets them become path authority.
struct ELFArchiveParser {
    static let archiveMagic = Data("!<arch>\n".utf8)
    static let thinArchiveMagic = Data("!<thin>\n".utf8)

    private static let headerSize = 60

    static func isArchive(_ bytes: Data) -> Bool {
        hasPrefix(archiveMagic, in: bytes)
    }

    static func isArchiveContainer(_ bytes: Data) -> Bool {
        isArchive(bytes) || hasPrefix(thinArchiveMagic, in: bytes)
    }

    static func parse(
        _ bytes: Data,
        limits: ELFArchiveParserLimits = .product,
        shouldCancel: () -> Bool = { false }
    ) throws -> ELFArchiveCatalog {
        if hasPrefix(thinArchiveMagic, in: bytes) {
            throw ELFArchiveParseError.thinArchiveUnsupported
        }
        guard isArchive(bytes) else { throw ELFArchiveParseError.notArchive }
        guard bytes.count <= limits.maximumArchiveBytes else {
            throw ELFArchiveParseError.boundExceeded("archive byte count")
        }

        struct RawMember {
            let headerIndex: Int
            let rawName: String
            let payloadRange: Range<Int>
            let embeddedName: String?
        }

        var rawMembers: [RawMember] = []
        var longNameTableRange: Range<Int>?
        var aggregateMemberBytes = 0
        var cursor = archiveMagic.count
        var headerIndex = 0

        while cursor < bytes.count {
            guard !shouldCancel() else { throw ELFArchiveParseError.cancelled }
            guard headerIndex < limits.maximumMembers else {
                throw ELFArchiveParseError.boundExceeded("member count")
            }
            guard bytes.count - cursor >= headerSize else {
                throw ELFArchiveParseError.truncated("member header")
            }

            let headerRange = cursor..<(cursor + headerSize)
            let header = bytes[headerRange]
            guard header[header.index(header.startIndex, offsetBy: 58)] == 0x60,
                  header[header.index(header.startIndex, offsetBy: 59)] == 0x0a else {
                throw ELFArchiveParseError.malformed("member terminator at header \(headerIndex)")
            }

            let rawName = try asciiField(header.prefix(16), field: "member name", headerIndex: headerIndex)
            let sizeBytes = header.dropFirst(48).prefix(10)
            let sizeText = try asciiField(sizeBytes, field: "member size", headerIndex: headerIndex)
            let declaredSize: Int
            switch parseDecimal(sizeText) {
            case .value(let value):
                declaredSize = value
            case .invalid:
                throw ELFArchiveParseError.malformed("member size at header \(headerIndex)")
            case .overflow:
                throw ELFArchiveParseError.boundExceeded("member byte count at header \(headerIndex)")
            }
            guard declaredSize <= limits.maximumMemberBytes else {
                throw ELFArchiveParseError.boundExceeded("member byte count at header \(headerIndex)")
            }
            let aggregate = aggregateMemberBytes.addingReportingOverflow(declaredSize)
            guard !aggregate.overflow,
                  aggregate.partialValue <= limits.maximumAggregateMemberBytes else {
                throw ELFArchiveParseError.boundExceeded("aggregate member bytes")
            }
            aggregateMemberBytes = aggregate.partialValue

            let payloadStart = cursor + headerSize
            guard declaredSize <= bytes.count - payloadStart else {
                throw ELFArchiveParseError.truncated("member payload at header \(headerIndex)")
            }
            let declaredRange = payloadStart..<(payloadStart + declaredSize)

            var payloadRange = declaredRange
            var embeddedName: String?
            if rawName.hasPrefix("#1/") {
                let countText = String(rawName.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard case .value(let nameCount) = parseDecimal(countText),
                      nameCount <= declaredRange.count else {
                    throw ELFArchiveParseError.malformed("BSD extended name at header \(headerIndex)")
                }
                guard nameCount <= limits.maximumNameBytes else {
                    throw ELFArchiveParseError.boundExceeded("BSD extended member name")
                }
                let nameRange = declaredRange.lowerBound..<(declaredRange.lowerBound + nameCount)
                guard let decodedName = String(data: bytes[nameRange], encoding: .utf8) else {
                    throw ELFArchiveParseError.malformed("BSD extended name encoding at header \(headerIndex)")
                }
                embeddedName = sanitizeName(decodedName)
                payloadRange = nameRange.upperBound..<declaredRange.upperBound
            }

            if rawName == "//" {
                guard longNameTableRange == nil else {
                    throw ELFArchiveParseError.malformed("duplicate GNU long-name table")
                }
                guard declaredRange.count <= limits.maximumLongNameTableBytes else {
                    throw ELFArchiveParseError.boundExceeded("GNU long-name table")
                }
                longNameTableRange = declaredRange
            }

            rawMembers.append(RawMember(
                headerIndex: headerIndex,
                rawName: rawName,
                payloadRange: payloadRange,
                embeddedName: embeddedName
            ))

            let next = declaredRange.upperBound.addingReportingOverflow(declaredRange.count & 1)
            guard !next.overflow, next.partialValue <= bytes.count else {
                throw ELFArchiveParseError.truncated("member alignment")
            }
            cursor = next.partialValue
            headerIndex += 1
        }

        var members: [ELFArchiveMember] = []
        for raw in rawMembers {
            guard !shouldCancel() else { throw ELFArchiveParseError.cancelled }

            let resolved: String
            if let embeddedName = raw.embeddedName {
                resolved = embeddedName
            } else if raw.rawName.hasPrefix("/"), raw.rawName.count > 1,
                      raw.rawName != "//", raw.rawName != "/SYM64/" {
                let digits = String(raw.rawName.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard case .value(let offset) = parseDecimal(digits),
                      let tableRange = longNameTableRange else {
                    throw ELFArchiveParseError.malformed(
                        "GNU long-name reference at header \(raw.headerIndex)"
                    )
                }
                resolved = try resolveGNUName(
                    offset: offset,
                    tableRange: tableRange,
                    bytes: bytes,
                    maximumNameBytes: limits.maximumNameBytes,
                    shouldCancel: shouldCancel
                )
            } else {
                resolved = sanitizeName(raw.rawName)
            }

            if isSpecialMember(rawName: raw.rawName, resolvedName: resolved) { continue }
            guard !resolved.isEmpty,
                  resolved != ".",
                  resolved != "..",
                  resolved.utf8.count <= limits.maximumNameBytes else {
                throw ELFArchiveParseError.malformed("empty, unsafe, or oversized member name")
            }

            let payload = raw.payloadRange
            let isELF = payload.count >= 4
                && bytes[payload.lowerBound] == 0x7f
                && bytes[payload.lowerBound + 1] == 0x45
                && bytes[payload.lowerBound + 2] == 0x4c
                && bytes[payload.lowerBound + 3] == 0x46
            members.append(ELFArchiveMember(
                index: members.count,
                archiveHeaderIndex: raw.headerIndex,
                name: resolved,
                payloadRange: payload,
                isELF: isELF,
                // Only ELF members are selectable/product identities. Avoid hashing unrelated
                // archive payloads a second time after the whole-container digest.
                sha256: isELF
                    ? try sha256Hex(bytes, range: payload, shouldCancel: shouldCancel)
                    : ""
            ))
        }
        return ELFArchiveCatalog(
            containerIdentity: ELFArchiveContainerIdentity(
                byteCount: bytes.count,
                sha256: try sha256Hex(
                    bytes,
                    range: bytes.startIndex..<bytes.endIndex,
                    shouldCancel: shouldCancel
                )
            ),
            members: members
        )
    }

    private enum DecimalParseResult {
        case value(Int)
        case invalid
        case overflow
    }

    private static func parseDecimal(_ value: String) -> DecimalParseResult {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }
        var result = 0
        for byte in trimmed.utf8 {
            guard byte >= 0x30, byte <= 0x39 else { return .invalid }
            let multiplied = result.multipliedReportingOverflow(by: 10)
            guard !multiplied.overflow else { return .overflow }
            let added = multiplied.partialValue.addingReportingOverflow(Int(byte - 0x30))
            guard !added.overflow else { return .overflow }
            result = added.partialValue
        }
        return .value(result)
    }

    private static func asciiField(
        _ bytes: Data.SubSequence,
        field: String,
        headerIndex: Int
    ) throws -> String {
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else {
            throw ELFArchiveParseError.malformed("\(field) encoding at header \(headerIndex)")
        }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveGNUName(
        offset: Int,
        tableRange: Range<Int>,
        bytes: Data,
        maximumNameBytes: Int,
        shouldCancel: () -> Bool
    ) throws -> String {
        guard offset >= 0, offset < tableRange.count else {
            throw ELFArchiveParseError.malformed("GNU long-name offset out of range")
        }
        let absoluteOffset = tableRange.lowerBound + offset
        if offset > 0 {
            let preceding = bytes[absoluteOffset - 1]
            guard preceding == 0 || preceding == 0x0a else {
                throw ELFArchiveParseError.malformed("GNU long-name offset is not an entry boundary")
            }
        }

        var end = absoluteOffset
        var foundTerminator = false
        while end < tableRange.upperBound {
            guard !shouldCancel() else { throw ELFArchiveParseError.cancelled }
            let byte = bytes[end]
            if byte == 0 || byte == 0x0a {
                foundTerminator = true
                break
            }
            if byte == 0x2f,
               end + 1 < tableRange.upperBound,
               bytes[end + 1] == 0x0a {
                foundTerminator = true
                break
            }
            end += 1
            guard end - absoluteOffset <= maximumNameBytes else {
                throw ELFArchiveParseError.boundExceeded("GNU long member name")
            }
        }
        guard foundTerminator else {
            throw ELFArchiveParseError.malformed("unterminated GNU long member name")
        }
        guard let decoded = String(data: bytes[absoluteOffset..<end], encoding: .utf8) else {
            throw ELFArchiveParseError.malformed("GNU long member name encoding")
        }
        return sanitizeName(decoded)
    }

    private static func isSpecialMember(rawName: String, resolvedName: String) -> Bool {
        let raw = rawName.trimmingCharacters(in: .whitespaces)
        return raw == "/"
            || raw == "//"
            || raw == "/SYM64/"
            || raw.hasPrefix("__.SYMDEF")
            || resolvedName.hasPrefix("__.SYMDEF")
    }

    private static func sanitizeName(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        result.removeAll { character in
            character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        result = result.replacingOccurrences(of: "\\", with: "/")
        return result.split(separator: "/", omittingEmptySubsequences: true)
            .last.map(String.init) ?? ""
    }

    private static func hasPrefix(_ prefix: Data, in bytes: Data) -> Bool {
        bytes.count >= prefix.count && bytes.prefix(prefix.count) == prefix
    }

    private static func sha256Hex(
        _ bytes: Data,
        range: Range<Int>,
        shouldCancel: () -> Bool
    ) throws -> String {
        var hasher = SHA256()
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard !shouldCancel() else { throw ELFArchiveParseError.cancelled }
            let upperBound = min(cursor + 64 * 1024, range.upperBound)
            hasher.update(data: bytes[cursor..<upperBound])
            cursor = upperBound
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
