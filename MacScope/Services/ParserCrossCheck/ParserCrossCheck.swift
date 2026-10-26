import Foundation

// MARK: - Independent parser cross-check (RX-03)
//
// The analysis worker re-parses the exact captured image bytes with independent, natively
// linked engines (LIEF, pe-parse and go-macho; see AnalysisWorkerService/NativeParserEngines)
// and compares their structural facts with MacScope's own loader. Disagreements surface as
// warning diagnostics in the analysis results. Engines are evidence only: they never replace
// LoadedBinary as image, address or byte authority, and no engine text reaches the UI.
//
// Cost (decision D4): the engines run at most once per distinct selected-slice digest in a worker
// process (ParserCrossCheckVerdictCache), never on dyld-shared-cache images, and never on slices
// above AnalysisEngine.maximumParserCrossCheckBytes; an oversized slice gets one
// "cross-check skipped: size" warning instead. Nothing here can fail an analysis.

/// The independent engines MacScope can consult. Raw values are stable identifiers.
enum ParserEngineID: String, CaseIterable, Codable, Hashable, Sendable, Comparable {
    case lief
    case peParse = "pe-parse"
    case goMacho = "go-macho"

    var displayName: String {
        switch self {
        case .lief: "LIEF"
        case .peParse: "pe-parse"
        case .goMacho: "go-macho"
        }
    }

    static func < (lhs: ParserEngineID, rhs: ParserEngineID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The two container formats the engines cross-check. Universal Mach-O files are checked
/// one selected slice at a time, using the slice's exact bytes.
enum ParserCrossCheckFormat: String, Codable, Hashable, Sendable {
    case machO
    case pe

    /// Classifies the selected slice by its magic. COFF objects, ELF, archives and anything
    /// else are not cross-checked.
    static func classify(sliceBytes: Data) -> ParserCrossCheckFormat? {
        guard sliceBytes.count >= 4 else { return nil }
        let magic = sliceBytes.prefix(4).withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self)
        }
        switch UInt32(littleEndian: magic) {
        case 0xFEED_FACF, 0xFEED_FACE: return .machO
        default: break
        }
        let mz = sliceBytes.prefix(2)
        return mz.elementsEqual([0x4D, 0x5A]) ? .pe : nil
    }
}

/// Structural facts one engine reports for one image, already in MacScope vocabulary:
/// Mach-O sections are named "SEGMENT,section"; PE sections keep the raw section-table name,
/// and a PE section's extent is VirtualSize, or SizeOfRawData when VirtualSize is zero
/// (the loader convention). Addresses are unslid virtual addresses.
struct ParserEngineFacts: Hashable, Sendable {
    struct Section: Hashable, Sendable {
        var name: String
        var address: UInt64
        var size: UInt64
        /// Slice-relative offset; nil means the adapter did not report it.
        var fileOffset: UInt64? = nil
    }

    /// Mach-O load-command facts, never a substitute for the loader's validated layout.
    /// Optional scalars preserve unavailable evidence; zero is a real reported value.
    struct Segment: Hashable, Sendable {
        var name: String
        var address: UInt64?
        var size: UInt64?
        var fileOffset: UInt64?
        var fileSize: UInt64?
    }

    var cpuType: Int32?
    var sections: [Section]
    var uuid: UUID?
    var entryPointAddress: UInt64?
    var importCount: Int?
    var cpuSubtype: Int32? = nil
    /// nil = unavailable; [] = the engine reported no segments.
    var segments: [Segment]? = nil
}

/// One engine's verdict on one image.
struct ParserEngineReport: Hashable, Sendable {
    enum Observation: Hashable, Sendable {
        case parsed(ParserEngineFacts)
        /// The engine refused or failed the input. Its own diagnostic text is untrusted and
        /// deliberately not retained.
        case rejected
    }

    var engine: ParserEngineID
    var observation: Observation
}

/// The seam the analysis engine calls. The worker injects the native implementation; the
/// in-process app engine has none, so app-side analysis is unchanged.
protocol ParserCrossChecking: Sendable {
    func reports(forSliceBytes bytes: Data, format: ParserCrossCheckFormat) -> [ParserEngineReport]
}

/// One address-anchored disagreement, aggregated across engines and facts so the Problems
/// panel shows one row per location.
struct ParserCrossCheckDisagreement: Hashable, Sendable {
    enum Fact: String, CaseIterable, Codable, Hashable, Sendable, Comparable {
        case engineRejected = "rejected the image"
        case architecture = "architecture"
        case uuid = "LC_UUID"
        case entryPoint = "entry point"
        case importCount = "import count"
        case sectionMissing = "section absent"
        case sectionUnexpected = "extra section"
        case sectionAddress = "section address"
        case sectionSize = "section size"
        case sectionFileOffset = "section file offset"
        case segmentMissing = "segment absent"
        case segmentUnexpected = "extra segment"
        case segmentAddress = "segment address"
        case segmentSize = "segment size"
        case segmentFileOffset = "segment file offset"
        case segmentFileSize = "segment file size"

        static func < (lhs: Fact, rhs: Fact) -> Bool {
            Self.allCases.firstIndex(of: lhs)! < Self.allCases.firstIndex(of: rhs)!
        }
    }

    var address: UInt64
    var engines: Set<ParserEngineID>
    var facts: Set<Fact>

    /// App-owned, bounded presentation built only from enum vocabulary.
    var message: String {
        let engineList = engines.sorted().map(\.displayName).joined(separator: ", ")
        let factList = facts.sorted().map(\.rawValue).joined(separator: ", ")
        let verb = engines.count == 1 ? "disagrees" : "disagree"
        return "\(engineList) \(verb) with MacScope's loader here: \(factList)."
    }
}

enum ParserCrossCheckComparator {
    static let maximumDisagreements = 256

    /// Compares every engine report with the loader's view of the same image.
    static func disagreements(
        loaded: LoadedBinary,
        format: ParserCrossCheckFormat,
        reports: [ParserEngineReport]
    ) -> [ParserCrossCheckDisagreement] {
        let anchor = loaded.sections.map(\.address).min() ?? 0
        var byAddress: [UInt64: ParserCrossCheckDisagreement] = [:]
        func record(_ engine: ParserEngineID, _ fact: ParserCrossCheckDisagreement.Fact, at address: UInt64) {
            let address = address == UInt64.max ? anchor : address
            if byAddress[address] == nil {
                guard byAddress.count < maximumDisagreements else { return }
                byAddress[address] = ParserCrossCheckDisagreement(address: address, engines: [], facts: [])
            }
            byAddress[address]?.engines.insert(engine)
            byAddress[address]?.facts.insert(fact)
        }

        for report in reports {
            guard case let .parsed(facts) = report.observation else {
                record(report.engine, .engineRejected, at: anchor)
                continue
            }
            if let cpuType = facts.cpuType, cpuType != loaded.cpuType {
                record(report.engine, .architecture, at: anchor)
                // Do not turn a known wrong Mach-O architecture into layout noise.
                if format == .machO { continue }
            }
            switch format {
            case .machO:
                if let loaderSubtype = loaded.cpuSubtype,
                   let reportedSubtype = facts.cpuSubtype,
                   loaderSubtype != reportedSubtype {
                    record(report.engine, .architecture, at: anchor)
                    continue
                }
                let loaderUUID = loaded.artifactIdentity?.uuid
                if let loaderUUID, facts.uuid != loaderUUID {
                    record(report.engine, .uuid, at: anchor)
                    // Preserve the existing missing-UUID warning. Two known, different
                    // UUIDs identify incompatible evidence, so do not compare its layout.
                    if facts.uuid != nil { continue }
                }
                if loaded.artifactIntegrityState == .verified,
                   let layout = loaded.preferredSegmentLayout,
                   let segments = facts.segments {
                    compareSegments(layout.records, segments, anchor: anchor) { fact, address in
                        record(report.engine, fact, at: address)
                    }
                }
            case .pe:
                if let entry = loaded.entryPointAddress, let reported = facts.entryPointAddress, entry != reported {
                    record(report.engine, .entryPoint, at: entry)
                }
                if let count = facts.importCount, count != loaded.imports.count {
                    record(report.engine, .importCount, at: anchor)
                }
            }
            compareSections(
                loaded.sections, facts.sections, compareFileOffsets: format == .machO
            ) { fact, address in
                record(report.engine, fact, at: address)
            }
        }
        return byAddress.values.sorted { $0.address < $1.address }
    }

    private static func compareSections(
        _ loaderSections: [BinarySection],
        _ engineSections: [ParserEngineFacts.Section],
        compareFileOffsets: Bool,
        record: (ParserCrossCheckDisagreement.Fact, UInt64) -> Void
    ) {
        var remaining = engineSections
        for section in loaderSections {
            let candidates = remaining.indices.filter { remaining[$0].name == section.name }
            guard let index = candidates.min(by: {
                distance(remaining[$0].address, section.address) < distance(remaining[$1].address, section.address)
            }) else {
                record(.sectionMissing, section.address)
                continue
            }
            let match = remaining.remove(at: index)
            if match.address != section.address {
                record(.sectionAddress, section.address)
            }
            if match.size != section.size {
                record(.sectionSize, section.address)
            }
            // Zero-fill sections have no file bytes and their offset is a placeholder.
            // An empty section likewise establishes no byte-to-address relationship.
            if compareFileOffsets, !section.isZeroFill, section.size > 0,
               let fileOffset = match.fileOffset, fileOffset != section.fileOffset {
                record(.sectionFileOffset, section.address)
            }
        }
        for extra in remaining {
            record(.sectionUnexpected, extra.address)
        }
    }

    private static func compareSegments(
        _ loaderSegments: [MachOPreferredSegmentLayout.Record],
        _ engineSegments: [ParserEngineFacts.Segment],
        anchor: UInt64,
        record: (ParserCrossCheckDisagreement.Fact, UInt64) -> Void
    ) {
        var remaining = engineSegments
        for segment in loaderSegments {
            let candidates = remaining.indices.filter { remaining[$0].name == segment.name }
            // Names need not be unique. Prefer the nearest reported preferred address;
            // missing address evidence sorts last and ties retain source order.
            guard let index = candidates.min(by: {
                let lhs = remaining[$0].address.map { distance($0, segment.preferredVMStart) } ?? UInt64.max
                let rhs = remaining[$1].address.map { distance($0, segment.preferredVMStart) } ?? UInt64.max
                return lhs < rhs
            }) else {
                record(.segmentMissing, segment.preferredVMStart)
                continue
            }
            let match = remaining.remove(at: index)
            if let address = match.address, address != segment.preferredVMStart {
                record(.segmentAddress, segment.preferredVMStart)
            }
            if let size = match.size, size != segment.preferredVMSize {
                record(.segmentSize, segment.preferredVMStart)
            }
            if let fileOffset = match.fileOffset, fileOffset != segment.sliceRelativeFileOffset {
                record(.segmentFileOffset, segment.preferredVMStart)
            }
            if let fileSize = match.fileSize, fileSize != segment.fileSize {
                record(.segmentFileSize, segment.preferredVMStart)
            }
        }
        // An engine-only segment supplies no loader-authorized navigation coordinate.
        if !remaining.isEmpty { record(.segmentUnexpected, anchor) }
    }

    private static func distance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : rhs - lhs
    }
}

// MARK: - Cost controls (decision D4)

/// Why a slice that would otherwise be cross-checked was not handed to the engines.
struct ParserCrossCheckSkip: Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        /// The selected slice is larger than the cross-check input cap.
        case size(byteCount: Int, limit: Int)
    }

    var address: UInt64
    var reason: Reason

    /// App-owned, bounded presentation; carries only numbers MacScope computed.
    var message: String {
        switch reason {
        case let .size(byteCount, limit):
            "Parser cross-check skipped: size. The selected slice is \(Self.mebibytes(byteCount)) MiB; "
                + "the independent engines only re-parse slices up to \(Self.mebibytes(limit)) MiB."
        }
    }

    private static func mebibytes(_ bytes: Int) -> Int {
        (bytes + 1_048_575) / 1_048_576
    }
}

/// What one analysis learned from the cross-check: address-anchored disagreements, or why the
/// engines were not consulted. Both surface only as per-image warning diagnostics.
struct ParserCrossCheckOutcome: Hashable, Sendable {
    var disagreements: [ParserCrossCheckDisagreement] = []
    var skip: ParserCrossCheckSkip?

    static let notChecked = ParserCrossCheckOutcome()
}

/// Worker-process memo of engine verdicts keyed by the exact selected-slice digest, so the
/// engines run once per distinct slice: reanalysis or rehydration of the same bytes reuses the
/// stored reports and only re-runs the (cheap) comparison against the loader.
final class ParserCrossCheckVerdictCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var sha256: String
        var byteCount: Int
        var format: ParserCrossCheckFormat
    }

    static let maximumEntries = 128

    private let lock = NSLock()
    private var entries: [Key: [ParserEngineReport]] = [:]
    private var insertionOrder: [Key] = []

    init() {}

    var count: Int {
        lock.withLock { entries.count }
    }

    /// Returns the cached reports for `key`, or runs `compute` once and stores its result.
    /// Engines run outside the lock; a concurrent first analysis of the same slice may compute
    /// twice, and the first stored verdict wins.
    func reports(for key: Key, compute: () -> [ParserEngineReport]) -> [ParserEngineReport] {
        if let cached = lock.withLock({ entries[key] }) {
            return cached
        }
        let computed = compute()
        return lock.withLock {
            if let existing = entries[key] { return existing }
            entries[key] = computed
            insertionOrder.append(key)
            if insertionOrder.count > Self.maximumEntries {
                entries.removeValue(forKey: insertionOrder.removeFirst())
            }
            return computed
        }
    }
}

extension ParserCrossCheckFormat {
    private static let machHeaderFlagsOffset = 24
    private static let dylibInCacheFlag: UInt32 = 0x8000_0000 // MH_DYLIB_IN_CACHE

    /// True when the slice's Mach-O header says the image was linked into a dyld shared cache.
    /// Such images (projected out of a cache, or extracted from one) have cache-relative layouts
    /// the standalone engines do not model, so they are never cross-checked.
    static func isDyldSharedCacheImage(machHeaderPrefix bytes: Data) -> Bool {
        guard classify(sliceBytes: bytes) == .machO,
              bytes.count >= machHeaderFlagsOffset + 4 else { return false }
        let start = bytes.startIndex + machHeaderFlagsOffset
        let flags = bytes[start ..< start + 4].withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self)
        }
        return UInt32(littleEndian: flags) & dylibInCacheFlag != 0
    }
}
