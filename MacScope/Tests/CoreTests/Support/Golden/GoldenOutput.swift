import Foundation
@testable import MacScope

// MARK: - Golden-output harness
//
// A pure, deterministic serializer that turns the result of the existing analysis
// pipeline (a `WorkspaceSnapshot`) into STABLE, normalized structured data, emitted
// as pretty-printed, key-sorted JSON. The same binary analyzed twice MUST produce
// byte-identical JSON — every nondeterministic field (runtime UUIDs, absolute/temp
// paths, the embedded Mach-O UUID string) is normalized away, and every collection
// is sorted by a stable key (address, then name).
//
// This is the MacScope side of a golden-output regression harness. Authorized
// reference outputs can later be dropped in privately and diffed against ours WITHOUT
// changing this API. The intended on-disk fixture layout is:
//
//     Tests/CoreTests/GoldenFixtures/<binary>/macscope.json   <- emitted by this harness
//     Tests/CoreTests/GoldenFixtures/<binary>/reference.json  <- authorized reference (NOT committed)
//
// where `<binary>` is a basename (e.g. `ls`). A future comparison test reads both
// files and diffs the normalized JSON. No reference-tool outputs and no binary fixtures are
// committed to the repo — tests analyze system binaries (e.g. `/bin/ls`) in place.
//
// Architecture scope: ARM64 and x86_64 ONLY. No PowerPC / Hexagon / i386 fields,
// cases, or handling appear anywhere here — the harness simply serializes whatever
// the in-scope pipeline produced.
//
// Coverage note: of the 13 target categories, this harness covers binary metadata,
// segments/sections, symbols, imports, exports, decoded instructions, procedures,
// basic blocks, CFG edges, cross-references, demangled names, and pseudocode. The
// "warnings/problems" category is intentionally OMITTED: the `WorkspaceSnapshot`
// model exposes no warning/diagnostic collection (diagnostics live only in the
// importer's transient result, not in the analyzed snapshot), so emitting one would
// mean fabricating a field. Per the correctness-over-coverage rule it is omitted
// rather than emitted wrong.

/// The normalized, Codable golden model. Field names and ordering are stable; the
/// JSON encoder sorts keys and pretty-prints, so the on-disk form is deterministic
/// and human-diffable.
struct GoldenOutput: Codable, Equatable {
    /// Bumped when the normalized shape changes, so a stale reference fixture is
    /// detectable rather than silently mis-compared.
    var schemaVersion: Int
    var binary: GoldenBinary
    var sections: [GoldenSection]
    var symbols: [GoldenSymbol]
    var imports: [GoldenImport]
    var exports: [GoldenExport]
    var instructions: [GoldenInstruction]
    var procedures: [GoldenProcedure]
    var basicBlocks: [GoldenBasicBlock]
    var controlFlowEdges: [GoldenEdge]
    var crossReferences: [GoldenXRef]
    var demangledNames: [GoldenDemangledName]
    var pseudocode: [GoldenPseudocode]

    static let currentSchemaVersion = 1
}

/// Binary metadata, with the absolute path stripped to a basename and the embedded
/// Mach-O UUID replaced by a placeholder (both are environment/build-specific and
/// would break byte-identical reproduction across hosts).
struct GoldenBinary: Codable, Equatable {
    var name: String
    /// Basename only — the absolute/temporary path is stripped so the output does not
    /// embed the host's directory layout.
    var pathBasename: String
    var kind: String
    var architecture: String
    /// `true` when the source carried an embedded image UUID (normalized away); the raw
    /// UUID string itself is intentionally dropped.
    var hasEmbeddedUUID: Bool
    var platformName: String?
    var minimumOSVersion: String?
    var sdkVersion: String?
    var buildTools: [String]
}

struct GoldenSection: Codable, Equatable {
    var name: String
    var address: String
    var size: UInt64
    var fileOffset: UInt64
    var isExecutable: Bool
    var isZeroFill: Bool
}

struct GoldenSymbol: Codable, Equatable {
    var name: String
    var address: String?
    var kind: String
    var libraryName: String?
}

struct GoldenImport: Codable, Equatable {
    var name: String
    var libraryName: String?
    var libraryOrdinal: Int?
}

struct GoldenExport: Codable, Equatable {
    var name: String
    var address: String?
    var source: String
}

struct GoldenInstruction: Codable, Equatable {
    var address: String
    var bytes: String
    var mnemonic: String
    var operands: String
    var comment: String?
}

struct GoldenProcedure: Codable, Equatable {
    var name: String
    var startAddress: String
    var endAddress: String
    var confidence: Double
}

struct GoldenBasicBlock: Codable, Equatable {
    /// The owning procedure's start address (a stable ordinal-free key), substituted for
    /// the runtime `functionID` UUID so reproduction is byte-identical.
    var procedureStartAddress: String?
    var startAddress: String
    var endAddress: String
    var instructionCount: Int
}

struct GoldenEdge: Codable, Equatable {
    var from: String
    var to: String
    var kind: String
}

struct GoldenXRef: Codable, Equatable {
    var from: String
    var to: String
    var kind: String
}

struct GoldenDemangledName: Codable, Equatable {
    var mangled: String
    var demangled: String
}

struct GoldenPseudocode: Codable, Equatable {
    var procedureStartAddress: String
    var procedureName: String
    var returnType: String
    var lines: [String]
}

extension GoldenOutput {
    /// Builds the normalized golden model from an analyzed snapshot.
    ///
    /// - Parameters:
    ///   - snapshot: the result of `AnalysisEngine.analyze(url:)`.
    ///   - maxProcedurePseudocode: cap on how many procedures get pseudocode emitted
    ///     (sorted by start address). Pseudocode is the most expensive field to build,
    ///     so a finite cap keeps the golden output bounded and the determinism test fast
    ///     while still proving the field is exercised. `0` omits pseudocode entirely.
    init(snapshot: WorkspaceSnapshot, maxProcedurePseudocode: Int = 8) {
        let binaryImage = snapshot.binaries.first

        self.schemaVersion = GoldenOutput.currentSchemaVersion

        self.binary = GoldenBinary(
            name: binaryImage?.name ?? "",
            // Strip the absolute/temp path to its last component so the output never
            // embeds the host's directory layout. Empty path -> empty basename.
            pathBasename: binaryImage.map { GoldenOutput.basename(of: $0.path) } ?? "",
            kind: binaryImage?.kind ?? "",
            architecture: binaryImage?.architecture ?? "",
            // The raw UUID string is host/build-specific; record only its presence.
            hasEmbeddedUUID: !(binaryImage?.metadata.uuid?.isEmpty ?? true),
            platformName: binaryImage?.metadata.platformName,
            minimumOSVersion: binaryImage?.metadata.minimumOSVersion,
            sdkVersion: binaryImage?.metadata.sdkVersion,
            // Build-tool list order is loader-defined; sort for stability.
            buildTools: (binaryImage?.metadata.buildTools ?? []).sorted()
        )

        // Sections: sort by (address, name).
        self.sections = snapshot.sections
            .map {
                GoldenSection(
                    name: $0.name,
                    address: $0.address.hexAddress,
                    size: $0.size,
                    fileOffset: $0.fileOffset,
                    isExecutable: $0.isExecutable,
                    isZeroFill: $0.isZeroFill
                )
            }
            .sorted { ($0.address, $0.name) < ($1.address, $1.name) }

        // Symbols: sort by (address ?? .max, name) so unaddressed symbols sort last
        // deterministically.
        self.symbols = snapshot.symbols
            .map {
                GoldenSymbol(
                    name: $0.name,
                    address: $0.address?.hexAddress,
                    kind: $0.kind,
                    libraryName: $0.libraryName
                )
            }
            .sorted(by: GoldenOutput.byOptionalAddressThenName(\.address, \.name))

        // Imports: sort by (name, libraryName).
        self.imports = snapshot.imports
            .map {
                GoldenImport(
                    name: $0.name,
                    libraryName: $0.libraryName,
                    libraryOrdinal: $0.libraryOrdinal
                )
            }
            .sorted { ($0.name, $0.libraryName ?? "") < ($1.name, $1.libraryName ?? "") }

        // Exports: sort by (address ?? .max, name).
        self.exports = snapshot.exports
            .map {
                GoldenExport(
                    name: $0.name,
                    address: $0.address?.hexAddress,
                    source: $0.source
                )
            }
            .sorted(by: GoldenOutput.byOptionalAddressThenName(\.address, \.name))

        // Instructions arrive in ascending address order from the decoder; sort
        // defensively by address.
        self.instructions = snapshot.instructions
            .map {
                GoldenInstruction(
                    address: $0.address.hexAddress,
                    bytes: $0.bytes,
                    mnemonic: $0.mnemonic,
                    operands: $0.operands,
                    comment: $0.comment
                )
            }
            .sorted { $0.address < $1.address }

        // Procedures: sort by (startAddress, name).
        let procedures = snapshot.functions
            .map {
                GoldenProcedure(
                    name: $0.name,
                    startAddress: $0.startAddress.hexAddress,
                    endAddress: $0.endAddress.hexAddress,
                    confidence: $0.confidence
                )
            }
            .sorted { ($0.startAddress, $0.name) < ($1.startAddress, $1.name) }
        self.procedures = procedures

        // Basic blocks reference their owning function by UUID; map that UUID to the
        // owning procedure's START ADDRESS (a stable, UUID-free key) so the output is
        // reproducible. A block whose functionID has no match (shouldn't happen) emits
        // a nil procedure address rather than leaking the UUID.
        let functionStartByID: [UUID: UInt64] = Dictionary(
            snapshot.functions.map { ($0.id, $0.startAddress) },
            uniquingKeysWith: { first, _ in first }
        )
        self.basicBlocks = snapshot.basicBlocks
            .map { block in
                GoldenBasicBlock(
                    procedureStartAddress: functionStartByID[block.functionID]?.hexAddress,
                    startAddress: block.startAddress.hexAddress,
                    endAddress: block.endAddress.hexAddress,
                    instructionCount: block.instructionCount
                )
            }
            .sorted { ($0.startAddress, $0.endAddress) < ($1.startAddress, $1.endAddress) }

        // CFG edges: sort by (from, to, kind). De-dup is not applied — a repeated edge
        // is meaningful, and the sort makes any repeat deterministic in position.
        self.controlFlowEdges = snapshot.controlFlowEdges
            .map { GoldenEdge(from: $0.from.hexAddress, to: $0.to.hexAddress, kind: $0.kind) }
            .sorted { ($0.from, $0.to, $0.kind) < ($1.from, $1.to, $1.kind) }

        // Cross-references: use the EFFECTIVE set (user suppressions/additions applied)
        // so the golden output matches what the inspector and scripting API report.
        // Sort by (from, to, kind).
        self.crossReferences = snapshot.effectiveXRefs()
            .map { GoldenXRef(from: $0.from.hexAddress, to: $0.to.hexAddress, kind: $0.kind) }
            .sorted { ($0.from, $0.to, $0.kind) < ($1.from, $1.to, $1.kind) }

        // Demangled names: every symbol/import/export name we actually recognize as a
        // mangled name, with its readable form. Keyed/sorted by the mangled string and
        // de-duplicated, so the set is stable regardless of how many tables a name
        // appears in. Names we do not recognize are omitted (the demangler returns nil),
        // never guessed — matching the demangler's correctness-over-coverage contract.
        var demangledByMangled: [String: String] = [:]
        let candidateNames = snapshot.symbols.map(\.name)
            + snapshot.imports.map(\.name)
            + snapshot.exports.map(\.name)
        for name in candidateNames where demangledByMangled[name] == nil {
            if let readable = Demangler.mangledToReadable(name) {
                demangledByMangled[name] = readable
            }
        }
        self.demangledNames = demangledByMangled
            .map { GoldenDemangledName(mangled: $0.key, demangled: $0.value) }
            .sorted { $0.mangled < $1.mangled }

        // Pseudocode: emit for the first `maxProcedurePseudocode` procedures by start
        // address. Each procedure is lifted through the SAME path the GUI/scripting use
        // (`pseudocodeTarget` -> `PseudocodePrinter.print`), so the golden text matches
        // the product. The printed lines are already deterministic (address-sourced);
        // we capture only the text, not the per-line runtime ids.
        if maxProcedurePseudocode > 0 {
            let resolvedJumpTables = snapshot.resolvedJumpTables(in: snapshot.primarySlot)
            let printer = PseudocodePrinter()
            let targets = snapshot.functions
                .sorted { $0.startAddress < $1.startAddress }
                .prefix(maxProcedurePseudocode)
            self.pseudocode = targets.compactMap { function in
                guard let target = snapshot.pseudocodeTarget(selectedAddress: function.startAddress) else {
                    return nil
                }
                let document = printer.print(
                    functionName: target.function.name,
                    startAddress: target.function.startAddress,
                    jumpTables: resolvedJumpTables,
                    objcSelectors: snapshot.objcSelectors,
                    instructions: target.instructions
                )
                return GoldenPseudocode(
                    procedureStartAddress: target.function.startAddress.hexAddress,
                    procedureName: target.function.name,
                    returnType: document.returnType,
                    lines: document.lines.map(\.text)
                )
            }
            .sorted { $0.procedureStartAddress < $1.procedureStartAddress }
        } else {
            self.pseudocode = []
        }
    }

    /// Serializes the golden model to pretty-printed, key-sorted UTF-8 JSON. The
    /// `.sortedKeys` + `.prettyPrinted` options make the bytes deterministic and
    /// human-diffable; the same model always encodes to the same bytes.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Convenience: the JSON as a UTF-8 string.
    func jsonString() throws -> String {
        String(decoding: try jsonData(), as: UTF8.self)
    }

    // MARK: - Normalization helpers

    /// The last path component of a file-system path, with no directory prefix. Strips
    /// a trailing slash first so `/a/b/` -> `b`. Empty/`/` -> "".
    static func basename(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// A comparator that orders by an optional hex-address string (nil sorts LAST) and
    /// breaks ties by name. Used for symbols/exports so unaddressed entries land at the
    /// end deterministically rather than interleaving by hash order.
    private static func byOptionalAddressThenName<T>(
        _ address: KeyPath<T, String?>,
        _ name: KeyPath<T, String>
    ) -> (T, T) -> Bool {
        { lhs, rhs in
            let lhsAddress = lhs[keyPath: address]
            let rhsAddress = rhs[keyPath: address]
            switch (lhsAddress, rhsAddress) {
            case let (.some(left), .some(right)):
                if left != right { return left < right }
                return lhs[keyPath: name] < rhs[keyPath: name]
            case (.some, .none):
                return true   // addressed entries sort before unaddressed
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs[keyPath: name] < rhs[keyPath: name]
            }
        }
    }
}
