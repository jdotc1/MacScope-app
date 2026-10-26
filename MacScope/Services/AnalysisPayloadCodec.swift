import CryptoKit
import Foundation
import os

/// The derived products emitted by the analysis engine and safe to transfer across
/// the analysis-worker boundary. User-authored workspace state deliberately has no
/// representation here; the main-actor store remains its source of truth.
struct AnalysisResultPayload: Codable, Equatable, Sendable {
    private static let logger = Logger(subsystem: "org.macscope.MacScope", category: "AnalysisPayload")
    var binaries: [BinaryImage]
    var functions: [FunctionSummary]
    var symbols: [SymbolSummary]
    var imports: [ImportSummary]
    var indirectSymbols: [IndirectSymbolSummary]
    var exports: [ExportSummary]
    var stringLiterals: [StringLiteralSummary]
    var basicBlocks: [BasicBlockSummary]
    var instructions: [InstructionRow]
    var xrefs: [XRef]
    var controlFlowEdges: [ControlFlowEdge]
    var hexBytes: Data
    var jumpTables: [UInt64: [UInt64]]
    var objcSelectors: [UInt64: String]
    /// HOP-5c: `__cfstring` object address → contents. Only the CFString part of the image's
    /// constant-string map crosses the wire; the C-string part is rebuilt from `stringLiterals`.
    var constantCFStrings: [UInt64: String]
    /// RX-02a: `__objc_classrefs` slot → class. Legacy replies carry none.
    var objcClassReferences: [UInt64: ObjCClassReferenceTarget]
    var objcClasses: [ObjCClass]
    var objcProtocols: [ObjCProtocol]
    var objcCategories: [ObjCCategory]
    var swiftTypes: [SwiftTypeDescriptor]
    var swiftConformances: [SwiftConformance]
    var sections: [SectionSummary]
    var codeDataRanges: [CodeDataRangeSummary]
    var relocations: [RelocationSummary]
    var identityEffectiveByteRanges: [IdentityEffectiveByteRangeAttestation]
    var sourceLines: [SourceLineEntry]
    var imageBytes: Data
    var diagnostics: [AnalysisDiagnostic]
    var machOMetadata: MachOLoadMetadata?
    var analysisInputFingerprint: AnalysisInputFingerprint?
    /// Same-build worker reply only. BinaryImage's saved encoding excludes this.
    var containerAdmissionWitness: MachOContainerAdmissionWitness?

    private enum CodingKeys: String, CodingKey {
        case binaries
        case functions
        case symbols
        case imports
        case indirectSymbols
        case exports
        case stringLiterals
        case basicBlocks
        case instructions
        case xrefs
        case controlFlowEdges
        case hexBytes
        case jumpTables
        case objcSelectors
        case constantCFStrings
        case objcClassReferences
        case objcClasses
        case objcProtocols
        case objcCategories
        case swiftTypes
        case swiftConformances
        case sections
        case codeDataRanges
        case relocations
        case identityEffectiveByteRanges
        case sourceLines
        case imageBytes
        case diagnostics
        case machOMetadata
        case analysisInputFingerprint
        case containerAdmissionWitness
    }

    /// JSON objects cannot preserve UInt64 keys without string coercion. Pair arrays
    /// retain the numeric key and are sorted before encoding for deterministic output.
    private struct UInt64Pair<Value: Codable & Equatable>: Codable, Equatable {
        var address: UInt64
        var value: Value
    }

    init(
        binaries: [BinaryImage],
        functions: [FunctionSummary],
        symbols: [SymbolSummary],
        imports: [ImportSummary],
        indirectSymbols: [IndirectSymbolSummary],
        exports: [ExportSummary],
        stringLiterals: [StringLiteralSummary],
        basicBlocks: [BasicBlockSummary],
        instructions: [InstructionRow],
        xrefs: [XRef],
        controlFlowEdges: [ControlFlowEdge],
        hexBytes: Data,
        jumpTables: [UInt64: [UInt64]],
        objcSelectors: [UInt64: String],
        objcClasses: [ObjCClass],
        objcCategories: [ObjCCategory],
        objcProtocols: [ObjCProtocol] = [],
        swiftTypes: [SwiftTypeDescriptor],
        swiftConformances: [SwiftConformance],
        sections: [SectionSummary],
        codeDataRanges: [CodeDataRangeSummary],
        relocations: [RelocationSummary],
        sourceLines: [SourceLineEntry],
        imageBytes: Data,
        diagnostics: [AnalysisDiagnostic],
        machOMetadata: MachOLoadMetadata?,
        analysisInputFingerprint: AnalysisInputFingerprint? = nil,
        containerAdmissionWitness: MachOContainerAdmissionWitness? = nil,
        identityEffectiveByteRanges: [IdentityEffectiveByteRangeAttestation] = [],
        constantCFStrings: [UInt64: String] = [:],
        objcClassReferences: [UInt64: ObjCClassReferenceTarget] = [:]
    ) {
        self.binaries = binaries
        self.functions = functions
        self.symbols = symbols
        self.imports = imports
        self.indirectSymbols = indirectSymbols
        self.exports = exports
        self.stringLiterals = stringLiterals
        self.basicBlocks = basicBlocks
        self.instructions = instructions
        self.xrefs = xrefs
        self.controlFlowEdges = controlFlowEdges
        self.hexBytes = hexBytes
        self.jumpTables = jumpTables
        self.objcSelectors = objcSelectors
        self.constantCFStrings = constantCFStrings
        self.objcClassReferences = objcClassReferences
        self.objcClasses = objcClasses
        self.objcCategories = objcCategories
        self.objcProtocols = objcProtocols
        self.swiftTypes = swiftTypes
        self.swiftConformances = swiftConformances
        self.sections = sections
        self.codeDataRanges = codeDataRanges
        self.relocations = relocations
        self.identityEffectiveByteRanges = identityEffectiveByteRanges
        self.sourceLines = sourceLines
        self.imageBytes = imageBytes
        self.diagnostics = diagnostics
        self.machOMetadata = machOMetadata
        self.analysisInputFingerprint = analysisInputFingerprint
        self.containerAdmissionWitness = containerAdmissionWitness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        binaries = try container.decode([BinaryImage].self, forKey: .binaries)
        functions = try container.decode([FunctionSummary].self, forKey: .functions)
        symbols = try container.decode([SymbolSummary].self, forKey: .symbols)
        imports = try container.decode([ImportSummary].self, forKey: .imports)
        indirectSymbols = try container.decode([IndirectSymbolSummary].self, forKey: .indirectSymbols)
        exports = try container.decode([ExportSummary].self, forKey: .exports)
        stringLiterals = try container.decode([StringLiteralSummary].self, forKey: .stringLiterals)
        basicBlocks = try container.decode([BasicBlockSummary].self, forKey: .basicBlocks)
        instructions = try container.decode([InstructionRow].self, forKey: .instructions)
        xrefs = try container.decode([XRef].self, forKey: .xrefs)
        controlFlowEdges = try container.decode([ControlFlowEdge].self, forKey: .controlFlowEdges)
        hexBytes = try container.decode(Data.self, forKey: .hexBytes)
        jumpTables = try Self.decodeMap(
            [UInt64].self,
            from: container,
            forKey: .jumpTables
        )
        objcSelectors = try Self.decodeMap(
            String.self,
            from: container,
            forKey: .objcSelectors
        )
        // Legacy replies predate HOP-5c constant CFStrings.
        constantCFStrings = container.contains(.constantCFStrings)
            ? try Self.decodeMap(String.self, from: container, forKey: .constantCFStrings)
            : [:]
        objcClassReferences = container.contains(.objcClassReferences)
            ? try Self.decodeMap(ObjCClassReferenceTarget.self, from: container, forKey: .objcClassReferences)
            : [:]
        objcClasses = try container.decode([ObjCClass].self, forKey: .objcClasses)
        objcProtocols = try container.decodeIfPresent([ObjCProtocol].self, forKey: .objcProtocols) ?? []
        objcCategories = try container.decode([ObjCCategory].self, forKey: .objcCategories)
        swiftTypes = try container.decode([SwiftTypeDescriptor].self, forKey: .swiftTypes)
        swiftConformances = try container.decode([SwiftConformance].self, forKey: .swiftConformances)
        sections = try container.decode([SectionSummary].self, forKey: .sections)
        codeDataRanges = try container.decodeIfPresent([CodeDataRangeSummary].self, forKey: .codeDataRanges) ?? []
        relocations = try container.decode([RelocationSummary].self, forKey: .relocations)
        // Legacy replies carry no effective-byte authority; do not derive or invent it.
        identityEffectiveByteRanges = try (container.decodeIfPresent(
            [EffectiveByteRangePayload].self, forKey: .identityEffectiveByteRanges) ?? [])
            .map { try $0.validatedAttestation() }
        sourceLines = try container.decode([SourceLineEntry].self, forKey: .sourceLines)
        imageBytes = try container.decode(Data.self, forKey: .imageBytes)
        // One diagnostic this build can't read (a kind added later) is dropped, never the payload.
        let entries = try container.decode([LossyDiagnostic].self, forKey: .diagnostics)
        diagnostics = entries.compactMap(\.value)
        let dropped = entries.count - diagnostics.count
        if dropped > 0 {
            // Visible when debugging, so a real codec bug doesn't hide behind the tolerance.
            Self.logger.debug("Dropped \(dropped, privacy: .public) undecodable diagnostics from an analysis payload")
        }
        machOMetadata = try container.decodeIfPresent(MachOLoadMetadata.self, forKey: .machOMetadata)
        analysisInputFingerprint = try container.decodeIfPresent(
            AnalysisInputFingerprint.self,
            forKey: .analysisInputFingerprint
        )
        containerAdmissionWitness = try container.decodeIfPresent(
            MachOContainerAdmissionWitness.self, forKey: .containerAdmissionWitness)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(binaries, forKey: .binaries)
        try container.encode(functions, forKey: .functions)
        try container.encode(symbols, forKey: .symbols)
        try container.encode(imports, forKey: .imports)
        try container.encode(indirectSymbols, forKey: .indirectSymbols)
        try container.encode(exports, forKey: .exports)
        try container.encode(stringLiterals, forKey: .stringLiterals)
        try container.encode(basicBlocks, forKey: .basicBlocks)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(xrefs, forKey: .xrefs)
        try container.encode(controlFlowEdges, forKey: .controlFlowEdges)
        try container.encode(hexBytes, forKey: .hexBytes)
        try Self.encodeMap(jumpTables, to: &container, forKey: .jumpTables)
        try Self.encodeMap(objcSelectors, to: &container, forKey: .objcSelectors)
        try Self.encodeMap(constantCFStrings, to: &container, forKey: .constantCFStrings)
        try Self.encodeMap(objcClassReferences, to: &container, forKey: .objcClassReferences)
        try container.encode(objcClasses, forKey: .objcClasses)
        try container.encode(objcProtocols, forKey: .objcProtocols)
        try container.encode(objcCategories, forKey: .objcCategories)
        try container.encode(swiftTypes, forKey: .swiftTypes)
        try container.encode(swiftConformances, forKey: .swiftConformances)
        try container.encode(sections, forKey: .sections)
        try container.encode(codeDataRanges, forKey: .codeDataRanges)
        try container.encode(relocations, forKey: .relocations)
        try container.encode(identityEffectiveByteRanges.map(EffectiveByteRangePayload.init),
            forKey: .identityEffectiveByteRanges)
        try container.encode(sourceLines, forKey: .sourceLines)
        try container.encode(imageBytes, forKey: .imageBytes)
        try container.encode(diagnostics, forKey: .diagnostics)
        try container.encodeIfPresent(machOMetadata, forKey: .machOMetadata)
        try container.encodeIfPresent(analysisInputFingerprint, forKey: .analysisInputFingerprint)
        try container.encodeIfPresent(containerAdmissionWitness, forKey: .containerAdmissionWitness)
    }

    /// Wire representation only. Decode must re-enter the loader evidence invariants.
    private struct EffectiveByteRangePayload: Codable {
        let artifactIdentity: MachOSliceArtifactIdentity
        let segmentName: String
        let startAddress: UInt64
        let endAddressExclusive: UInt64
        let sliceRelativeFileOffset: UInt64
        let byteCount: UInt64
        let initialProtections: Int32
        let rawBytesSHA256: String

        init(_ value: IdentityEffectiveByteRangeAttestation) {
            artifactIdentity = value.artifactIdentity
            segmentName = value.segmentName
            startAddress = value.startAddress
            endAddressExclusive = value.endAddressExclusive
            sliceRelativeFileOffset = value.sliceRelativeFileOffset
            byteCount = value.byteCount
            initialProtections = value.initialProtections
            rawBytesSHA256 = value.rawBytesSHA256
        }

        func validatedAttestation() throws -> IdentityEffectiveByteRangeAttestation {
            try .init(artifactIdentity: artifactIdentity, segmentName: segmentName,
                startAddress: startAddress, endAddressExclusive: endAddressExclusive,
                sliceRelativeFileOffset: sliceRelativeFileOffset, byteCount: byteCount,
                initialProtections: initialProtections, rawBytesSHA256: rawBytesSHA256)
        }
    }

    private static func decodeMap<Value: Codable & Equatable>(
        _ valueType: Value.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [UInt64: Value] {
        let pairs = try container.decode([UInt64Pair<Value>].self, forKey: key)
        var result: [UInt64: Value] = [:]
        result.reserveCapacity(pairs.count)
        for pair in pairs {
            guard result.updateValue(pair.value, forKey: pair.address) == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Duplicate UInt64 map key \(pair.address)"
                )
            }
        }
        return result
    }

    private static func encodeMap<Value: Codable & Equatable>(
        _ map: [UInt64: Value],
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        let pairs = map.sorted { $0.key < $1.key }.map {
            UInt64Pair(address: $0.key, value: $0.value)
        }
        try container.encode(pairs, forKey: key)
    }
}

enum AnalysisPayloadCodec {
    static func payload(from snapshot: WorkspaceSnapshot) -> AnalysisResultPayload {
        AnalysisResultPayload(
            binaries: snapshot.binaries,
            functions: snapshot.functions,
            symbols: snapshot.symbols,
            imports: snapshot.imports,
            indirectSymbols: snapshot.indirectSymbols,
            exports: snapshot.exports,
            stringLiterals: snapshot.stringLiterals,
            basicBlocks: snapshot.basicBlocks,
            instructions: snapshot.instructions,
            xrefs: snapshot.xrefs,
            controlFlowEdges: snapshot.controlFlowEdges,
            hexBytes: snapshot.hexBytes,
            jumpTables: snapshot.jumpTables,
            objcSelectors: snapshot.objcSelectors,
            objcClasses: snapshot.objcClasses,
            objcCategories: snapshot.objcCategories,
            objcProtocols: snapshot.objcProtocols,
            swiftTypes: snapshot.swiftTypes,
            swiftConformances: snapshot.swiftConformances,
            sections: snapshot.sections,
            codeDataRanges: snapshot.codeDataRanges,
            relocations: snapshot.relocations,
            sourceLines: snapshot.sourceLines,
            imageBytes: snapshot.imageBytes,
            diagnostics: snapshot.diagnostics,
            machOMetadata: snapshot.machOMetadata,
            analysisInputFingerprint: snapshot.analysisInputFingerprint,
            containerAdmissionWitness: snapshot.binaries.count == 1
                ? snapshot.binaries.first?.containerAdmissionWitness : nil,
            identityEffectiveByteRanges: snapshot.identityEffectiveByteRanges,
            constantCFStrings: ImageConstantStringProvider.cfStrings(in: snapshot.constantStrings),
            objcClassReferences: snapshot.analysis(in: snapshot.primarySlot)?.objcClassReferences ?? [:]
        )
    }

    static func snapshot(from payload: AnalysisResultPayload) -> WorkspaceSnapshot {
        var binaries = payload.binaries
        for index in binaries.indices { binaries[index].containerAdmissionWitness = nil }
        if let witness = payload.containerAdmissionWitness,
           binaries.count == 1,
           binaries[0].artifactIntegrityState == .verified,
           binaries[0].artifactIdentity == witness.selectedSliceIdentity,
           UInt64(payload.imageBytes.count) == witness.sliceSize {
            let digest = SHA256.hash(data: payload.imageBytes)
                .map { String(format: "%02x", $0) }.joined()
            if digest == witness.selectedSliceIdentity.selectedSliceSHA256 {
                binaries[0].containerAdmissionWitness = witness
            }
        }
        return WorkspaceSnapshot(
            binaries: binaries,
            functions: payload.functions,
            symbols: payload.symbols,
            imports: payload.imports,
            indirectSymbols: payload.indirectSymbols,
            exports: payload.exports,
            stringLiterals: payload.stringLiterals,
            basicBlocks: payload.basicBlocks,
            instructions: payload.instructions,
            xrefs: payload.xrefs,
            controlFlowEdges: payload.controlFlowEdges,
            hexBytes: payload.hexBytes,
            jumpTables: payload.jumpTables,
            objcSelectors: payload.objcSelectors,
            objcClassReferences: payload.objcClassReferences,
            constantStrings: ImageConstantStringProvider.build(
                stringLiterals: payload.stringLiterals, cfStrings: payload.constantCFStrings
            ),
            objcClasses: payload.objcClasses,
            objcCategories: payload.objcCategories,
            objcProtocols: payload.objcProtocols,
            swiftTypes: payload.swiftTypes,
            swiftConformances: payload.swiftConformances,
            sections: payload.sections,
            codeDataRanges: payload.codeDataRanges,
            relocations: payload.relocations,
            identityEffectiveByteRanges: payload.identityEffectiveByteRanges,
            sourceLines: payload.sourceLines,
            imageBytes: payload.imageBytes,
            diagnostics: payload.diagnostics,
            machOMetadata: payload.machOMetadata,
            analysisInputFingerprint: payload.analysisInputFingerprint
        )
    }
}

/// Decodes one diagnostic, or nil when it doesn't decode (an unknown kind or provenance).
private struct LossyDiagnostic: Decodable {
    let value: AnalysisDiagnostic?

    init(from decoder: Decoder) throws {
        value = try? AnalysisDiagnostic(from: decoder)
    }
}
