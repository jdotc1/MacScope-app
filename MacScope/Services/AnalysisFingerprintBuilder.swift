import CryptoKit
import Foundation

enum AnalysisFingerprintBuilder {
    static func fingerprint(
        binary: BinaryImage,
        analysis: ImageAnalysis
    ) throws -> AnalysisInputFingerprint {
        try fingerprint(binary: binary, analysis: analysis, navigatorContext: nil)
    }

    /// Builds the fingerprint and, when `navigatorContext` is non-nil, also records the navigator
    /// analysis input key. The context never feeds `overallSHA256` or any facet, so the overall
    /// digest is identical with and without it.
    static func fingerprint(
        binary: BinaryImage,
        analysis: ImageAnalysis,
        navigatorContext: NavigatorInputKeyContext?
    ) throws -> AnalysisInputFingerprint {
        let imageBytesSHA256 = sha256Hex(analysis.imageBytes)
        let facets = try buildFacets(binary: binary, analysis: analysis, imageBytesSHA256: imageBytesSHA256)
        let overallSHA256 = overallDigest(
            binary: binary,
            analysis: analysis,
            imageBytesSHA256: imageBytesSHA256,
            facets: facets
        )
        return try AnalysisInputFingerprint(
            imageSlot: binary.slot,
            binaryID: binary.id,
            binaryName: binary.name,
            binaryPath: binary.path,
            selectedSliceIndex: binary.selectedSliceIndex,
            artifactIdentity: binary.artifactIdentity,
            elfArchiveMemberIdentity: binary.elfArchiveMemberIdentity,
            imageByteCount: UInt64(analysis.imageBytes.count),
            imageBytesSHA256: imageBytesSHA256,
            facets: facets,
            overallSHA256: overallSHA256,
            inputKey: navigatorContext.map { context in
                NavigatorAnalysisInputKey.inputKey(
                    sliceSHA256: binary.artifactIdentity?.selectedSliceSHA256 ?? imageBytesSHA256,
                    selectedSliceIndex: binary.selectedSliceIndex,
                    context: context
                )
            }
        )
    }

    private static func buildFacets(
        binary: BinaryImage,
        analysis: ImageAnalysis,
        imageBytesSHA256: String
    ) throws -> [AnalysisFacetFingerprint] {
        func instructionFacet() throws -> AnalysisFacetFingerprint {
            try analysis.instructionFingerprintMemo.value { try instructionsFacet(analysis.instructions) }
        }
        func otherFacets() throws -> [AnalysisFacetFingerprint] {
            try [
                selectedSliceBytesFacet(analysis: analysis, imageBytesSHA256: imageBytesSHA256),
                sectionsFacet(analysis.sections),
                codeDataRangesFacet(analysis.codeDataRanges),
                relocationsFacet(
                    analysis.relocations,
                    identityEffectiveByteRanges: analysis.identityEffectiveByteRanges
                ),
                machOLoadMetadataFacet(binary: binary, analysis: analysis),
                functionsFacet(analysis.functions),
                analysis.controlFlowFingerprintMemo.value { try controlFlowFacet(analysis.controlFlowEdges) },
                xrefsFacet(analysis.xrefs),
                sourceLinesFacet(analysis.sourceLines),
            ]
        }
        let instruction: AnalysisFacetFingerprint
        let others: [AnalysisFacetFingerprint]
        if shouldOverlapInstructionFacet(analysis) {
            // Facets are independent pure functions of immutable array values; the instruction
            // facet (the largest on real images) overlaps with all the others on a second core.
            let lanes = FacetLanes(instructionWork: instructionFacet, otherWork: otherFacets)
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                lanes.run(lane)
            }
            instruction = try lanes.instruction!.get()
            others = try lanes.others!.get()
        } else {
            instruction = try instructionFacet()
            others = try otherFacets()
        }
        // Schema-1 facet order: instructions sit between load metadata and functions.
        return Array(others[0..<5]) + [instruction] + Array(others[5...])
    }

    /// Overlap only when both sides carry enough rows to repay a second thread.
    private static func shouldOverlapInstructionFacet(_ analysis: ImageAnalysis) -> Bool {
        guard analysis.instructions.count >= 4_096 else { return false }
        let otherWork = analysis.controlFlowEdges.count + analysis.xrefs.count + analysis.sourceLines.count
            + analysis.relocations.count + analysis.functions.count + analysis.imageBytes.count / 256
        return otherWork >= 2_048
    }

    /// Each slot is written by exactly one `concurrentPerform` lane and read only after it returns.
    private final class FacetLanes: @unchecked Sendable {
        let instructionWork: () throws -> AnalysisFacetFingerprint
        let otherWork: () throws -> [AnalysisFacetFingerprint]
        var instruction: Result<AnalysisFacetFingerprint, any Error>?
        var others: Result<[AnalysisFacetFingerprint], any Error>?

        init(
            instructionWork: @escaping () throws -> AnalysisFacetFingerprint,
            otherWork: @escaping () throws -> [AnalysisFacetFingerprint]
        ) {
            self.instructionWork = instructionWork
            self.otherWork = otherWork
        }

        func run(_ lane: Int) {
            if lane == 0 {
                instruction = Result { try instructionWork() }
            } else {
                others = Result { try otherWork() }
            }
        }
    }

    private static func selectedSliceBytesFacet(
        analysis: ImageAnalysis,
        imageBytesSHA256: String
    ) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        writer.field("kind", AnalysisFingerprintFacetKind.selectedSliceBytes.rawValue)
        writer.field("byteCount", UInt64(analysis.imageBytes.count))
        writer.field("sha256", imageBytesSHA256)
        return try AnalysisFacetFingerprint(
            kind: .selectedSliceBytes,
            itemCount: analysis.imageBytes.isEmpty ? 0 : 1,
            byteCount: UInt64(analysis.imageBytes.count),
            sha256: writer.digestHex()
        )
    }

    private static func sectionsFacet(_ sections: [SectionSummary]) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        let sorted = sections.sorted {
            ($0.address, $0.name, $0.size, $0.fileOffset) < ($1.address, $1.name, $1.size, $1.fileOffset)
        }
        for section in sorted {
            writer.beginRecord("section")
            writer.field("name", section.name)
            writer.field("address", section.address)
            writer.field("size", section.size)
            writer.field("fileOffset", section.fileOffset)
            writer.field("isExecutable", section.isExecutable)
            writer.field("isZeroFill", section.isZeroFill)
            writer.optionalField("fileSize", section.fileSize)
            writer.endRecord("section")
        }
        return try AnalysisFacetFingerprint(kind: .loaderSections, itemCount: sorted.count, sha256: writer.digestHex())
    }

    private static func codeDataRangesFacet(_ ranges: [CodeDataRangeSummary]) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        let sorted = ranges.sorted {
            ($0.address, $0.size, $0.kind) < ($1.address, $1.size, $1.kind)
        }
        for range in sorted {
            writer.beginRecord("codeDataRange")
            writer.field("address", range.address)
            writer.field("size", range.size)
            writer.field("kind", range.kind)
            writer.endRecord("codeDataRange")
        }
        return try AnalysisFacetFingerprint(kind: .codeDataRanges, itemCount: sorted.count, sha256: writer.digestHex())
    }

    private static func relocationsFacet(
        _ relocations: [RelocationSummary],
        identityEffectiveByteRanges: [IdentityEffectiveByteRangeAttestation]
    ) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        let sorted = relocations.sorted {
            ($0.address, $0.sectionName, $0.typeCode, $0.symbolName ?? "") <
                ($1.address, $1.sectionName, $1.typeCode, $1.symbolName ?? "")
        }
        for relocation in sorted {
            writer.beginRecord("relocation")
            writer.field("address", relocation.address)
            writer.field("sectionName", relocation.sectionName)
            writer.field("typeCode", relocation.typeCode)
            writer.optionalField("typeName", relocation.typeName)
            writer.optionalField("symbolName", relocation.symbolName)
            writer.optionalField("symbolIndex", relocation.symbolIndex)
            writer.optionalField("addend", relocation.addend)
            writer.field("isPCRelative", relocation.isPCRelative)
            writer.field("widthInBytes", relocation.widthInBytes)
            writer.endRecord("relocation")
        }
        let sortedAttestations = identityEffectiveByteRanges.sorted { lhs, rhs in
            if lhs.startAddress != rhs.startAddress { return lhs.startAddress < rhs.startAddress }
            if lhs.endAddressExclusive != rhs.endAddressExclusive { return lhs.endAddressExclusive < rhs.endAddressExclusive }
            if lhs.sliceRelativeFileOffset != rhs.sliceRelativeFileOffset {
                return lhs.sliceRelativeFileOffset < rhs.sliceRelativeFileOffset
            }
            return lhs.segmentName < rhs.segmentName
        }
        for attestation in sortedAttestations {
            writer.beginRecord("identityEffectiveByteRange")
            writer.field("model", IdentityEffectiveByteRangeAttestation.modelIdentifier)
            writer.optionalField("artifactUUID", attestation.artifactIdentity.uuid?.uuidString)
            writer.field("rawCPUType", attestation.artifactIdentity.rawCPUType)
            writer.field("rawCPUSubtype", attestation.artifactIdentity.rawCPUSubtype)
            writer.field("architectureVariant", attestation.artifactIdentity.architectureVariant.rawValue)
            writer.field("selectedSliceSHA256", attestation.artifactIdentity.selectedSliceSHA256)
            writer.field("selectedSliceByteCount", attestation.artifactIdentity.selectedSliceByteCount)
            writer.field("segmentName", attestation.segmentName)
            writer.field("startAddress", attestation.startAddress)
            writer.field("endAddressExclusive", attestation.endAddressExclusive)
            writer.field("sliceRelativeFileOffset", attestation.sliceRelativeFileOffset)
            writer.field("byteCount", attestation.byteCount)
            writer.field("initialProtections", attestation.initialProtections)
            writer.field("rawBytesSHA256", attestation.rawBytesSHA256)
            writer.endRecord("identityEffectiveByteRange")
        }
        return try AnalysisFacetFingerprint(
            kind: .relocations,
            itemCount: sorted.count + sortedAttestations.count,
            sha256: writer.digestHex()
        )
    }

    private static func machOLoadMetadataFacet(
        binary: BinaryImage,
        analysis: ImageAnalysis
    ) throws -> AnalysisFacetFingerprint {
        try loadMetadataFacet(
            metadata: binary.metadata,
            artifactIdentity: binary.artifactIdentity,
            machOMetadata: analysis.machOMetadata
        )
    }

    /// Cross-checks the independently persisted loader-metadata facet when immutable attachment
    /// evidence proves that the image is ELF. Applicability deliberately does not trust the
    /// mutable persisted `kind`, current GNU build-ID presence, or fingerprint artifact-identity
    /// discriminator: deleting or drifting any of those fields must not downgrade validation.
    ///
    /// A fingerprint-bound ELF attachment always has a reproducible nil-artifact/nil-Mach-O
    /// metadata facet. That remains compatible with genuinely legacy ELF fingerprints which
    /// predate GNU build-ID persistence: their recorded facet and current empty-build-ID facet
    /// still match. Records without a fingerprint-bound ELF attachment remain outside this
    /// narrow check.
    static func persistedELFLoadMetadataMatchesFingerprint(
        attachmentData: Data,
        persistedKind: String,
        metadata: BinaryMetadataSummary,
        fingerprint: AnalysisInputFingerprint
    ) throws -> Bool {
        guard UInt64(attachmentData.count) == fingerprint.imageByteCount,
              sha256Hex(attachmentData) == fingerprint.imageBytesSHA256 else {
            return false
        }
        guard attachmentData.starts(with: [0x7f, 0x45, 0x4c, 0x46]) else { return true }
        let normalizedKind = persistedKind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedKind == "elf" || normalizedKind.hasPrefix("elf "),
              fingerprint.artifactIdentity == nil else {
            return false
        }
        guard let recorded = fingerprint.facets.first(where: {
            $0.kind == .machOLoadMetadata
        }) else {
            return false
        }
        let recomputed = try loadMetadataFacet(
            metadata: metadata,
            artifactIdentity: nil,
            machOMetadata: nil
        )
        return recorded == recomputed
    }

    private static func loadMetadataFacet(
        metadata: BinaryMetadataSummary,
        artifactIdentity: MachOSliceArtifactIdentity?,
        machOMetadata: MachOLoadMetadata?
    ) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        writer.optionalField("metadataUUID", metadata.uuid)
        if let buildID = metadata.elfGNUBuildID {
            // Preserve all pre-build-ID facet digests: absence contributes no
            // new field, while a present ELF identity remains domain-separated.
            writer.field("metadataELFGNUBuildID", buildID)
        }
        writer.optionalField("platformName", metadata.platformName)
        writer.optionalField("minimumOSVersion", metadata.minimumOSVersion)
        writer.optionalField("sdkVersion", metadata.sdkVersion)
        for tool in metadata.buildTools.sorted() {
            writer.field("buildTool", tool)
        }
        if let identity = artifactIdentity {
            writer.optionalField("artifactUUID", identity.uuid?.uuidString)
            writer.field("rawCPUType", identity.rawCPUType)
            writer.field("rawCPUSubtype", identity.rawCPUSubtype)
            writer.field("architectureVariant", identity.architectureVariant.rawValue)
            writer.field("selectedSliceSHA256", identity.selectedSliceSHA256)
            writer.field("selectedSliceByteCount", identity.selectedSliceByteCount)
        } else {
            writer.field("artifactIdentity", "nil")
        }
        if let machO = machOMetadata {
            for dylib in machO.dependentDylibs.sorted(by: { ($0.path, $0.kind) < ($1.path, $1.kind) }) {
                writer.beginRecord("dependentDylib")
                writer.field("path", dylib.path)
                writer.field("kind", dylib.kind)
                writer.field("currentVersion", dylib.currentVersion)
                writer.field("compatibilityVersion", dylib.compatibilityVersion)
                writer.field("ordinal", dylib.ordinal)
                writer.endRecord("dependentDylib")
            }
            for symbol in machO.importedSymbols.sorted(by: { ($0.name, $0.libraryOrdinal ?? -1) < ($1.name, $1.libraryOrdinal ?? -1) }) {
                writer.beginRecord("importedSymbol")
                writer.field("name", symbol.name)
                writer.optionalField("libraryOrdinal", symbol.libraryOrdinal)
                writer.optionalField("libraryName", symbol.libraryName)
                writer.field("isWeak", symbol.isWeak)
                writer.optionalField("addend", symbol.addend)
                writer.field("source", symbol.source)
                writer.endRecord("importedSymbol")
            }
            if let signature = machO.codeSignature {
                writer.beginRecord("codeSignature")
                writer.optionalField("teamIdentifier", signature.teamIdentifier)
                writer.optionalField("identifier", signature.identifier)
                writer.optionalField("hashTypeName", signature.hashTypeName)
                writer.optionalField("codeSignatureFlags", signature.codeSignatureFlags)
                writer.optionalField("entitlementsFormat", signature.entitlementsFormat)
                writer.field("entitlementsDER", signature.entitlementsDER)
                writer.optionalField("entitlementsKeyCount", signature.entitlementsKeyCount)
                for key in signature.entitlementsKeys.sorted() {
                    writer.field("entitlementsKey", key)
                }
                writer.field("entitlementsParsed", signature.entitlementsParsed)
                writer.endRecord("codeSignature")
            }
        } else {
            writer.field("machOMetadata", "nil")
        }
        return try AnalysisFacetFingerprint(kind: .machOLoadMetadata, itemCount: 1, sha256: writer.digestHex())
    }

    private static func instructionsFacet(_ instructions: [InstructionRow]) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        // Loader output is already address-ordered; Swift's sort is stable, so sorting a
        // non-decreasing array is the identity and the copy can be skipped.
        let sorted = isNonDecreasingByAddress(instructions) ? instructions : instructions.sorted { $0.address < $1.address }
        for row in sorted {
            writer.beginRecord("instruction")
            writer.field("address", row.address)
            writer.field("bytes", row.bytes)
            writer.field("mnemonic", row.mnemonic)
            writer.field("operands", row.operands)
            writer.endRecord("instruction")
        }
        return try AnalysisFacetFingerprint(kind: .decodedInstructions, itemCount: sorted.count, sha256: writer.digestHex())
    }

    private static func functionsFacet(_ functions: [FunctionSummary]) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        let sorted = functions.sorted {
            ($0.startAddress, $0.endAddress, $0.name) < ($1.startAddress, $1.endAddress, $1.name)
        }
        for function in sorted {
            writer.beginRecord("function")
            writer.field("name", function.name)
            writer.field("startAddress", function.startAddress)
            writer.field("endAddress", function.endAddress)
            writer.field("confidence", function.confidence)
            writer.endRecord("function")
        }
        return try AnalysisFacetFingerprint(kind: .functions, itemCount: sorted.count, sha256: writer.digestHex())
    }

    private static func controlFlowFacet(_ edges: [ControlFlowEdge]) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        let inOrder: (ControlFlowEdge, ControlFlowEdge) -> Bool = {
            ($0.from, $0.to, $0.kind) < ($1.from, $1.to, $1.kind)
        }
        let sorted = isNonDecreasing(edges, by: inOrder) ? edges : edges.sorted(by: inOrder)
        for edge in sorted {
            writer.beginRecord("controlFlow")
            writer.field("from", edge.from)
            writer.field("to", edge.to)
            writer.field("kind", edge.kind)
            writer.endRecord("controlFlow")
        }
        return try AnalysisFacetFingerprint(kind: .controlFlow, itemCount: sorted.count, sha256: writer.digestHex())
    }

    private static func isNonDecreasingByAddress(_ rows: [InstructionRow]) -> Bool {
        rows.withUnsafeBufferPointer { buffer in
            var index = 1
            while index < buffer.count {
                if buffer[index].address < buffer[index - 1].address { return false }
                index += 1
            }
            return true
        }
    }

    private static func isNonDecreasing<Element>(_ items: [Element], by areInIncreasingOrder: (Element, Element) -> Bool) -> Bool {
        var index = 1
        while index < items.count {
            if areInIncreasingOrder(items[index], items[index - 1]) { return false }
            index += 1
        }
        return true
    }

    private static func xrefsFacet(_ xrefs: [XRef]) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        let sorted = xrefs.sorted {
            ($0.from, $0.to, $0.kind) < ($1.from, $1.to, $1.kind)
        }
        for xref in sorted {
            writer.beginRecord("xref")
            writer.field("from", xref.from)
            writer.field("to", xref.to)
            writer.field("kind", xref.kind)
            writer.endRecord("xref")
        }
        return try AnalysisFacetFingerprint(kind: .xrefs, itemCount: sorted.count, sha256: writer.digestHex())
    }

    private static func sourceLinesFacet(_ lines: [SourceLineEntry]) throws -> AnalysisFacetFingerprint {
        var writer = AnalysisFingerprintCanonicalWriter()
        let sorted = lines.sorted {
            ($0.address, $0.line, $0.column, $0.file ?? "") < ($1.address, $1.line, $1.column, $1.file ?? "")
        }
        for line in sorted {
            writer.beginRecord("sourceLine")
            writer.field("address", line.address)
            writer.optionalField("file", line.file)
            writer.field("line", line.line)
            writer.field("column", line.column)
            writer.field("endSequence", line.endSequence)
            writer.optionalField("debugArtifactUUID", line.debugArtifactUUID?.uuidString)
            writer.optionalField("debugArtifactMachOSHA256", line.debugArtifactMachOSHA256)
            writer.optionalField("debugArtifactMachOByteCount", line.debugArtifactMachOByteCount)
            writer.optionalField("lineProgramUnitOffset", line.lineProgramUnitOffset)
            writer.optionalField("fileTableIndex", line.fileTableIndex)
            writer.optionalField("tablePath", line.tablePath.map { String(describing: $0) })
            writer.endRecord("sourceLine")
        }
        return try AnalysisFacetFingerprint(kind: .debugSourceLines, itemCount: sorted.count, sha256: writer.digestHex())
    }

    private static func overallDigest(
        binary: BinaryImage,
        analysis: ImageAnalysis,
        imageBytesSHA256: String,
        facets: [AnalysisFacetFingerprint]
    ) -> String {
        var writer = AnalysisFingerprintCanonicalWriter()
        writer.field("schemaVersion", AnalysisInputFingerprint.currentSchemaVersion)
        writer.field("imageSlot", binary.slot.rawValue)
        writer.field("binaryID", binary.id.uuidString)
        writer.field("binaryName", binary.name)
        writer.field("binaryPath", binary.path)
        writer.optionalField("selectedSliceIndex", binary.selectedSliceIndex)
        if let archive = binary.elfArchiveMemberIdentity {
            writer.field("elfArchiveContainerByteCount", archive.container.byteCount)
            writer.field("elfArchiveContainerSHA256", archive.container.sha256)
            writer.field("elfArchiveOrdinaryMemberIndex", archive.member.index)
            writer.field("elfArchiveHeaderIndex", archive.member.archiveHeaderIndex)
            writer.field("elfArchiveMemberName", archive.member.name)
            writer.field("elfArchiveMemberPayloadOffset", archive.member.payloadOffset)
            writer.field("elfArchiveMemberByteCount", archive.member.byteCount)
            writer.field("elfArchiveMemberSHA256", archive.member.sha256)
        }
        writer.field("imageByteCount", UInt64(analysis.imageBytes.count))
        writer.field("imageBytesSHA256", imageBytesSHA256)
        if let identity = binary.artifactIdentity {
            writer.optionalField("artifactUUID", identity.uuid?.uuidString)
            writer.field("artifactSHA256", identity.selectedSliceSHA256)
            writer.field("artifactByteCount", identity.selectedSliceByteCount)
            writer.field("artifactCPUType", identity.rawCPUType)
            writer.field("artifactCPUSubtype", identity.rawCPUSubtype)
        } else {
            writer.field("artifactIdentity", "nil")
        }
        for facet in facets.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            writer.beginRecord("facet")
            writer.field("kind", facet.kind.rawValue)
            writer.field("schemaVersion", facet.schemaVersion)
            writer.field("itemCount", facet.itemCount)
            writer.optionalField("byteCount", facet.byteCount)
            writer.field("sha256", facet.sha256)
            writer.endRecord("facet")
        }
        return writer.digestHex()
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Lowercase hex, identical to `String(format: "%02x")` per byte.
    static func hex(_ digest: SHA256.Digest) -> String {
        let alphabet: [UInt8] = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            text.append(alphabet[Int(byte >> 4)])
            text.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}

/// A memo belongs to one immutable array generation. ImageAnalysis replaces it on every
/// write (including element writes); copies retain the old generation safely. Sidecar admission
/// shares the same memo with snapshots in that operation, never a persisted/untrusted digest.
final class AnalysisFacetDigestMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: AnalysisFacetFingerprint?

    func value(_ build: () throws -> AnalysisFacetFingerprint) rethrows -> AnalysisFacetFingerprint {
        try lock.withLock {
            if let cached { return cached }
            let value = try build()
            cached = value
            return value
        }
    }
}

/// Streams the exact schema-1 canonical byte stream (`"<utf8 count>:" + utf8 + "\n"` for every
/// name and value) into SHA-256 through one fixed staging buffer. Nothing is materialised: no
/// facet-sized byte array, no per-field String for integers, no Data copy at the end. The digest
/// is byte-for-byte the digest of the historical materialised stream.
/// Noncopyable because it owns its staging memory; writers are always local and short-lived.
struct AnalysisFingerprintCanonicalWriter: ~Copyable {
    private static let stagingCapacity = 1 << 16
    private let staging: UnsafeMutableRawPointer
    private var used = 0
    private var hasher = SHA256()

    init() {
        staging = UnsafeMutableRawPointer.allocate(byteCount: Self.stagingCapacity, alignment: 16)
    }

    deinit {
        staging.deallocate()
    }

    mutating func beginRecord(_ name: String) {
        field("begin", name)
    }

    mutating func endRecord(_ name: String) {
        field("end", name)
    }

    mutating func field(_ name: String, _ value: String) {
        append(name)
        append(value)
    }

    mutating func field(_ name: String, _ value: Bool) {
        field(name, value ? "true" : "false")
    }

    mutating func field(_ name: String, _ value: Int) {
        append(name)
        appendDecimal(magnitude: UInt64(value.magnitude), negative: value < 0)
    }

    mutating func field(_ name: String, _ value: Int32) {
        append(name)
        appendDecimal(magnitude: UInt64(value.magnitude), negative: value < 0)
    }

    mutating func field(_ name: String, _ value: UInt32) {
        append(name)
        appendDecimal(magnitude: UInt64(value), negative: false)
    }

    mutating func field(_ name: String, _ value: UInt64) {
        append(name)
        appendDecimal(magnitude: value, negative: false)
    }

    mutating func field(_ name: String, _ value: Double) {
        field(name, String(format: "%.17g", value))
    }

    mutating func optionalField(_ name: String, _ value: String?) {
        field(name, value ?? "<nil>")
    }

    mutating func optionalField(_ name: String, _ value: Int?) {
        if let value { field(name, value) } else { field(name, "<nil>") }
    }

    mutating func optionalField(_ name: String, _ value: UInt32?) {
        if let value { field(name, value) } else { field(name, "<nil>") }
    }

    mutating func optionalField(_ name: String, _ value: UInt64?) {
        if let value { field(name, value) } else { field(name, "<nil>") }
    }

    mutating func optionalField(_ name: String, _ value: Int64?) {
        if let value {
            append(name)
            appendDecimal(magnitude: value.magnitude, negative: value < 0)
        } else {
            field(name, "<nil>")
        }
    }

    func digestHex() -> String {
        var final = hasher
        final.update(bufferPointer: UnsafeRawBufferPointer(start: staging, count: used))
        return AnalysisFingerprintBuilder.hex(final.finalize())
    }

    private mutating func flush() {
        guard used > 0 else { return }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: staging, count: used))
        used = 0
    }

    /// Guarantees `byteCount` (at most the staging capacity) contiguous free bytes.
    private mutating func reserve(_ byteCount: Int) {
        if Self.stagingCapacity - used < byteCount { flush() }
    }

    private mutating func append(_ value: String) {
        var value = value
        value.withUTF8 { appendLengthPrefixed($0) }
    }

    private mutating func appendLengthPrefixed(_ bytes: UnsafeBufferPointer<UInt8>) {
        // Header: decimal byte count (at most 20 digits) and ':'.
        reserve(21)
        writeDigits(UInt64(bytes.count))
        staging.storeBytes(of: 0x3A, toByteOffset: used, as: UInt8.self)
        used += 1
        if let base = bytes.baseAddress, !bytes.isEmpty {
            if Self.stagingCapacity - used >= bytes.count {
                (staging + used).copyMemory(from: base, byteCount: bytes.count)
                used += bytes.count
            } else {
                flush()
                if bytes.count >= Self.stagingCapacity {
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(bytes))
                } else {
                    staging.copyMemory(from: base, byteCount: bytes.count)
                    used = bytes.count
                }
            }
        }
        reserve(1)
        staging.storeBytes(of: 0x0A, toByteOffset: used, as: UInt8.self)
        used += 1
    }

    /// Writes the length-prefixed decimal text exactly as `String(value)` renders it.
    private mutating func appendDecimal(magnitude: UInt64, negative: Bool) {
        var digits = 1
        var probe = magnitude
        while probe >= 10 {
            probe /= 10
            digits += 1
        }
        let length = digits + (negative ? 1 : 0)
        // "<length>:" (at most 3 bytes) + text (at most 21) + "\n".
        reserve(32)
        writeDigits(UInt64(length))
        staging.storeBytes(of: 0x3A, toByteOffset: used, as: UInt8.self)
        used += 1
        if negative {
            staging.storeBytes(of: 0x2D, toByteOffset: used, as: UInt8.self)
            used += 1
        }
        writeDigits(magnitude, count: digits)
        staging.storeBytes(of: 0x0A, toByteOffset: used, as: UInt8.self)
        used += 1
    }

    private mutating func writeDigits(_ value: UInt64) {
        var digits = 1
        var probe = value
        while probe >= 10 {
            probe /= 10
            digits += 1
        }
        writeDigits(value, count: digits)
    }

    /// Caller has reserved `count` bytes.
    private mutating func writeDigits(_ value: UInt64, count: Int) {
        var remaining = value
        var offset = used + count - 1
        repeat {
            staging.storeBytes(of: UInt8(truncatingIfNeeded: 0x30 + remaining % 10), toByteOffset: offset, as: UInt8.self)
            remaining /= 10
            offset -= 1
        } while remaining > 0
        used += count
    }
}
