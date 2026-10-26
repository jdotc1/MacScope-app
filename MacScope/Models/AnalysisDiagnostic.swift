import Foundation

/// One app-owned, transient analysis failure surfaced in the Problems panel.
///
/// Diagnostics may cross the analysis-worker boundary, but they are never persistence authority.
/// Their identity is made only from typed authority and numeric evidence; message text is bounded
/// presentation and can never change which failure a row represents.
struct AnalysisDiagnostic: Hashable, Codable, Sendable, Identifiable {
    static let maximumMessageUTF8Bytes = 512

    enum Severity: Int, Hashable, Codable, Sendable, Comparable, CaseIterable {
        case error
        case warning

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Sort/display rank: errors before warnings.
        var sortRank: Int { rawValue }
    }

    /// The failure classification. This stays separate from severity and provenance: a caller
    /// cannot turn untrusted message text into a different failure or producer identity.
    enum Kind: String, Hashable, Codable, Sendable, CaseIterable {
        case unresolvedBranchTarget
        case undecodedInstruction
        case xrefTargetOutsideSections
        case loaderTruncation
        /// An independent parser engine (LIEF, pe-parse, go-macho) disagrees with MacScope's
        /// loader about the same captured bytes. Evidence only; the loader stays authoritative.
        case parserCrossCheckDisagreement
        /// The independent engines were not consulted for this image (today: the selected slice
        /// exceeds the cross-check size cap). Informational; the loader result is unaffected.
        case parserCrossCheckSkipped
        /// The loader explicitly refused a structure it does not handle (e.g. an unhandled
        /// chained-fixup pointer format) instead of misreading it. App-owned typed message.
        case unsupportedLoaderStructure
        /// ObjC metadata is unavailable/untrustworthy (e.g. an image extracted from the dyld
        /// shared cache). App-owned typed message.
        case objcMetadataUnavailable
        /// HS-12: LC_FUNCTION_STARTS and the unwind tables disagree about a function start.
        /// Evidence only; discovery is unchanged. App-owned typed message.
        case functionStartsDisagreement
        /// HS-13: a Swift or Objective-C metadata walk skipped, abandoned or capped part of its work.
        case metadataParseIssue

        var title: String {
            switch self {
            case .unresolvedBranchTarget: "Unresolved branch target"
            case .undecodedInstruction: "Undecoded instruction"
            case .xrefTargetOutsideSections: "Reference outside any section"
            case .loaderTruncation: "Truncated / over-read structure"
            case .parserCrossCheckDisagreement: "Parser cross-check disagreement"
            case .parserCrossCheckSkipped: "Parser cross-check skipped"
            case .unsupportedLoaderStructure: "Unsupported loader structure"
            case .objcMetadataUnavailable: "Objective-C metadata unavailable"
            case .functionStartsDisagreement: "Function starts disagree with unwind info"
            case .metadataParseIssue: "Metadata partly unreadable"
            }
        }

        fileprivate var expectedProvenance: Provenance {
            switch self {
            case .unresolvedBranchTarget: .controlFlow
            case .undecodedInstruction: .decoder
            case .xrefTargetOutsideSections: .crossReference
            case .loaderTruncation: .loader
            case .parserCrossCheckDisagreement, .parserCrossCheckSkipped: .parserCrossCheck
            case .unsupportedLoaderStructure, .objcMetadataUnavailable, .functionStartsDisagreement, .metadataParseIssue: .loader
            }
        }

        fileprivate var fallbackMessage: String {
            switch self {
            case .unresolvedBranchTarget:
                "A control-flow target was not decoded as an instruction."
            case .undecodedInstruction:
                "An instruction inside executable code could not be decoded."
            case .xrefTargetOutsideSections:
                "A reference target is outside every mapped section."
            case .loaderTruncation:
                "The loader reported a truncated or over-read structure."
            case .parserCrossCheckDisagreement:
                "An independent parser engine disagrees with MacScope's loader."
            case .parserCrossCheckSkipped:
                "The independent parser cross-check was skipped for this image."
            case .unsupportedLoaderStructure:
                "The loader refused a structure it does not handle."
            case .objcMetadataUnavailable:
                "Objective-C metadata is unavailable for this image."
            case .functionStartsDisagreement:
                "LC_FUNCTION_STARTS and the unwind tables disagree about a function start."
            case .metadataParseIssue:
                "Part of the Swift or Objective-C metadata could not be read."
            }
        }
    }

    typealias Failure = Kind

    enum Provenance: String, Hashable, Codable, Sendable, CaseIterable {
        case controlFlow
        case decoder
        case crossReference
        case loader
        case parserCrossCheck
    }

    /// Exact authority for a diagnostic that is allowed to leave an image-local analysis bucket.
    /// UUIDs are typed and nonzero; the analysis generation is monotonic within its run.
    struct Authority: Hashable, Codable, Sendable {
        let imageID: UUID
        let documentID: UUID
        let sessionID: UUID
        let runID: UUID
        let analysisGeneration: UInt64

        init?(
            imageID: UUID,
            documentID: UUID,
            sessionID: UUID,
            runID: UUID,
            analysisGeneration: UInt64
        ) {
            guard analysisGeneration > 0,
                  Self.isValid(imageID),
                  Self.isValid(documentID),
                  Self.isValid(sessionID),
                  Self.isValid(runID) else {
                return nil
            }
            self.imageID = imageID
            self.documentID = documentID
            self.sessionID = sessionID
            self.runID = runID
            self.analysisGeneration = analysisGeneration
        }

        private enum CodingKeys: String, CodingKey {
            case imageID
            case documentID
            case sessionID
            case runID
            case analysisGeneration
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let imageID = try container.decode(UUID.self, forKey: .imageID)
            let documentID = try container.decode(UUID.self, forKey: .documentID)
            let sessionID = try container.decode(UUID.self, forKey: .sessionID)
            let runID = try container.decode(UUID.self, forKey: .runID)
            let generation = try container.decode(UInt64.self, forKey: .analysisGeneration)
            guard let value = Self(
                imageID: imageID,
                documentID: documentID,
                sessionID: sessionID,
                runID: runID,
                analysisGeneration: generation
            ) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid analysis diagnostic authority."
                ))
            }
            self = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(imageID, forKey: .imageID)
            try container.encode(documentID, forKey: .documentID)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(runID, forKey: .runID)
            try container.encode(analysisGeneration, forKey: .analysisGeneration)
        }

        fileprivate var identityText: String {
            [imageID, documentID, sessionID, runID]
                .map { $0.uuidString.lowercased() }
                .joined(separator: "/")
                + "/g\(analysisGeneration)"
        }

        private static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        private static func isValid(_ value: UUID) -> Bool {
            value != zeroUUID
        }
    }

    /// Image-local origin of the evidence. The diagnostic's `address` remains the navigation
    /// anchor (often a target); this coordinate records the instruction/reference/loader site
    /// that actually produced the finding without retaining bytes, source paths, or text.
    struct SourceCoordinate: Hashable, Codable, Sendable {
        let address: UInt64

        init?(address: UInt64) {
            guard address != UInt64.max else { return nil }
            self.address = address
        }

        private enum CodingKeys: String, CodingKey { case address }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let address = try container.decode(UInt64.self, forKey: .address)
            guard let value = Self(address: address) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid analysis diagnostic source coordinate."
                ))
            }
            self = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(address, forKey: .address)
        }
    }

    var severity: Severity
    /// The address the diagnostic is anchored to; selecting the row jumps here.
    var address: UInt64
    var kind: Kind
    private(set) var message: String
    private(set) var provenance: Provenance
    private(set) var authority: Authority?
    private(set) var sourceCoordinate: SourceCoordinate?

    var failure: Failure { kind }

    /// Compatibility initializer for app-owned construction sites. Invalid legacy fixture
    /// addresses remain representable for transport round-trip tests, but they have no source
    /// coordinate and are rejected by `validated(...)` and every publication fence.
    init(
        severity: Severity,
        address: UInt64,
        kind: Kind,
        message: String,
        provenance: Provenance? = nil,
        authority: Authority? = nil,
        sourceCoordinate: SourceCoordinate? = nil
    ) {
        self.severity = severity
        self.address = address
        self.kind = kind
        self.message = Self.sanitized(message, fallback: kind.fallbackMessage)
        self.provenance = provenance ?? kind.expectedProvenance
        self.authority = authority
        self.sourceCoordinate = sourceCoordinate ?? SourceCoordinate(address: address)
    }

    /// Short-lived image-local validation context. Repeated app-owned messages are sanitized
    /// once per image pass. Arbitrary distinct messages cannot grow the cache beyond 256 entries;
    /// authority, coordinates and provenance are still checked for each diagnostic.
    struct ImageValidationContext {
        private struct Key: Hashable { let message: String; let kind: Kind }
        private var messages: [Key: String] = [:]

        mutating func validated(severity: Severity, address: UInt64, kind: Kind, message: String,
                                provenance: Provenance, authority: Authority?,
                                sourceCoordinate: SourceCoordinate) -> AnalysisDiagnostic? {
            guard address != UInt64.max, provenance == kind.expectedProvenance else { return nil }
            let key = message.utf8.count <= AnalysisDiagnostic.maximumMessageUTF8Bytes
                ? Key(message: message, kind: kind) : nil
            let sanitized: String
            if let key, let cached = messages[key] { sanitized = cached }
            else {
                sanitized = AnalysisDiagnostic.sanitized(message, fallback: kind.fallbackMessage)
                if let key, messages.count < 256 { messages[key] = sanitized }
            }
            return AnalysisDiagnostic(severity: severity, address: address, kind: kind,
                sanitizedMessage: sanitized, provenance: provenance, authority: authority,
                sourceCoordinate: sourceCoordinate)
        }
    }

    private init(severity: Severity, address: UInt64, kind: Kind, sanitizedMessage: String,
                 provenance: Provenance, authority: Authority?, sourceCoordinate: SourceCoordinate) {
        self.severity = severity
        self.address = address
        self.kind = kind
        self.message = sanitizedMessage
        self.provenance = provenance
        self.authority = authority
        self.sourceCoordinate = sourceCoordinate
    }

    /// Fail-closed construction used by the collector and publication boundary.
    static func validated(
        severity: Severity,
        address: UInt64,
        kind: Kind,
        message: String,
        provenance: Provenance,
        authority: Authority?,
        sourceCoordinate: SourceCoordinate
    ) -> AnalysisDiagnostic? {
        guard address != UInt64.max,
              provenance == kind.expectedProvenance else {
            return nil
        }
        let value = AnalysisDiagnostic(
            severity: severity,
            address: address,
            kind: kind,
            message: message,
            provenance: provenance,
            authority: authority,
            sourceCoordinate: sourceCoordinate
        )
        return value.isStructurallyValid ? value : nil
    }

    var isStructurallyValid: Bool {
        address != UInt64.max
            && sourceCoordinate != nil
            && provenance == kind.expectedProvenance
            && message.utf8.count <= Self.maximumMessageUTF8Bytes
    }

    func isCurrent(for expected: Authority) -> Bool {
        isStructurallyValid && authority == expected
    }

    /// Stable, bounded identity made only from authority + structured evidence. Presentation text
    /// is intentionally excluded, so sanitization or wording changes cannot churn row identity.
    var id: String {
        let owner = authority?.identityText ?? "image-local"
        let source = sourceCoordinate.map { $0.address.hexAddress } ?? "invalid-source"
        return "\(owner):\(provenance.rawValue):\(kind.rawValue):\(source)->\(address.hexAddress):s\(severity.rawValue)"
    }

    /// The display address text (zero-padded hex), reused by the panel and accessibility.
    var addressText: String { address.hexAddress }

    private enum CodingKeys: String, CodingKey {
        case severity
        case address
        case kind
        case message
        case provenance
        case authority
        case sourceCoordinate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let severity = try container.decode(Severity.self, forKey: .severity)
        let address = try container.decode(UInt64.self, forKey: .address)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? kind.fallbackMessage
        let provenance = try container.decodeIfPresent(Provenance.self, forKey: .provenance)
            ?? kind.expectedProvenance
        let authority = try container.decodeIfPresent(Authority.self, forKey: .authority)
        let source = try container.decodeIfPresent(SourceCoordinate.self, forKey: .sourceCoordinate)
            ?? SourceCoordinate(address: address)
        self.init(
            severity: severity,
            address: address,
            kind: kind,
            message: message,
            provenance: provenance,
            authority: authority,
            sourceCoordinate: source
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(severity, forKey: .severity)
        try container.encode(address, forKey: .address)
        try container.encode(kind, forKey: .kind)
        try container.encode(message, forKey: .message)
        try container.encode(provenance, forKey: .provenance)
        try container.encodeIfPresent(authority, forKey: .authority)
        try container.encodeIfPresent(sourceCoordinate, forKey: .sourceCoordinate)
    }

    /// Normalizes app-owned presentation and removes the common sensitive/unbounded payload
    /// shapes before retention. Third-party loader text never reaches this function: the collector
    /// deliberately replaces it with a fixed app-owned failure description.
    private static func sanitized(_ candidate: String, fallback: String) -> String {
        let oneLine = candidate.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
        }
        let normalized = String(oneLine)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return fallback }

        let lower = normalized.lowercased()
        let sensitiveMarkers = [
            "authorization:", "bearer ", "api_key", "apikey", "password", "passwd",
            "secret", "access_token", "refresh_token", "cookie:", "set-cookie:", "prompt"
        ]
        guard !sensitiveMarkers.contains(where: lower.contains),
              !resemblesBinaryPayload(normalized) else {
            return fallback
        }

        let redacted = normalized.split(separator: " ", omittingEmptySubsequences: true).map {
            token -> String in
            looksLikePath(String(token)) ? "<redacted-path>" : String(token)
        }.joined(separator: " ")
        return boundedUTF8(redacted.isEmpty ? fallback : redacted)
    }

    private static func looksLikePath(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>,;:'\""))
        let lower = trimmed.lowercased()
        if lower.hasPrefix("file://") || lower.hasPrefix("~/") || trimmed.hasPrefix("/") {
            return true
        }
        let scalars = Array(trimmed.unicodeScalars)
        return scalars.count >= 3
            && CharacterSet.letters.contains(scalars[0])
            && scalars[1] == ":"
            && (scalars[2] == "\\" || scalars[2] == "/")
    }

    private static func resemblesBinaryPayload(_ value: String) -> Bool {
        let tokens = value.split(whereSeparator: { $0.isWhitespace })
        let byteTokens = tokens.filter { token in
            token.utf8.count == 2 && token.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            }
        }
        if byteTokens.count >= 8 { return true }
        return tokens.contains { token in
            token.utf8.count >= 64 && token.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || byte == 43 || byte == 47 || byte == 61
            }
        }
    }

    private static func boundedUTF8(_ value: String) -> String {
        guard value.utf8.count > maximumMessageUTF8Bytes else { return value }
        let marker = "…"
        let budget = maximumMessageUTF8Bytes - marker.utf8.count
        var result = ""
        var used = 0
        for character in value {
            let width = String(character).utf8.count
            guard used + width <= budget else { break }
            result.append(character)
            used += width
        }
        return result + marker
    }
}
