import Foundation

/// The kind of query a binary `Find` runs.
enum BinarySearchMode: String, CaseIterable, Identifiable, Sendable {
    case text   // case-insensitive substring over rendered listing text + strings + symbols
    case regex  // regular expression over the same rendered text
    case hex    // byte pattern over the decoded instruction byte stream

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .regex: "Regex"
        case .hex: "Hex bytes"
        }
    }

    var prompt: String {
        switch self {
        case .text: "Find text in mnemonics, operands, comments, strings, symbols"
        case .regex: "Regular expression (e.g. ^bl\\b or str.*x0)"
        case .hex: "Byte pattern, e.g. 48 89 e5 or 4889e5"
        }
    }
}

/// One hit from a binary `Find`, carrying the address to navigate to plus a short
/// human-readable preview of what matched.
struct BinarySearchResult: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case instruction
        case string
        case symbol
        case function
        case bytes
    }

    var address: UInt64
    var kind: Kind
    var preview: String
    /// WS-8: the loaded image this hit belongs to. Defaults `.primary` so single-image search and
    /// existing construction sites are unchanged; multi-image Find tags each result with its slot and
    /// folds it into `id` so identical VAs in different images are distinct rows.
    var imageSlot: ImageSlot = .primary

    var id: String { "\(imageSlot.rawValue):\(kind.rawValue):\(address):\(preview)" }
}

/// A pure, UI-independent search over every image in an already-loaded `WorkspaceSnapshot`.
///
/// Text/regex modes scan the rendered listing (mnemonic + operands + comment),
/// string literals, and symbol/function names — everything the analysis already
/// produced, so no file re-reading is needed. Hex mode scans the raw bytes of EVERY
/// file-backed section (from the snapshot's `imageBytes`/`sections` map) — not just
/// the decoded `__text` — so a pattern in `__const`, `__data`, or `__cstring` is found
/// and mapped to its virtual address; when those derived fields are unavailable (after
/// a package reload) it falls back to reconstructing the decoded instruction stream.
/// Results are de-duplicated, sorted by image slot then address, and capped at `limit`
/// so a broad query can't produce an unbounded list.
struct BinarySearchService {
    static let defaultLimit = 500

    struct BoundedOutcome: Sendable {
        let results: [BinarySearchResult]
        let lowerBound: Int
        let isTruncated: Bool
        let isCancelled: Bool
    }

    /// Confined to one detached scan; Foundation's progress callback is synchronous.
    private final class ScanBudget: @unchecked Sendable {
        let maximumMatches: Int
        let kinds: Set<BinarySearchResult.Kind>
        let cancelled: @Sendable () -> Bool
        let deadline = Date().addingTimeInterval(2)
        var work = 0
        var matches = 0
        var truncated = false
        init(limit: Int, kinds: Set<BinarySearchResult.Kind>, cancelled: @escaping @Sendable () -> Bool) {
            maximumMatches = min(500, max(1, limit)) + 1
            self.kinds = kinds
            self.cancelled = cancelled
        }
        var stopped: Bool {
            if cancelled() { return true }
            if matches >= maximumMatches || work >= 200_000 || Date() >= deadline {
                truncated = true
                return true
            }
            return false
        }
        func visit() -> Bool { guard !stopped else { return false }; work += 1; return true }
        func append(_ result: BinarySearchResult, to results: inout [BinarySearchResult]) {
            guard kinds.contains(result.kind), !stopped else { return }
            results.append(result)
            matches += 1
        }
    }

    /// Cancellable worker path: accumulation, candidate visits, byte windows and
    /// elapsed work are bounded. A limited scan reports a lower bound, not an
    /// invented exact count. The legacy exact-count entry point is unchanged.
    func searchBounded(query: String, mode: BinarySearchMode, in snapshot: WorkspaceSnapshot,
                       scope: BinarySearchScope = .everything, limit: Int = defaultLimit,
                       isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }) -> BoundedOutcome {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle.utf8.count <= 256, validate(query: needle, mode: mode) == nil else {
            return BoundedOutcome(results: [], lowerBound: 0, isTruncated: false, isCancelled: isCancelled())
        }
        let budget = ScanBudget(limit: limit, kinds: scope.kinds, cancelled: isCancelled)
        if mode == .hex, !scope.kinds.contains(.bytes) {
            return BoundedOutcome(results: [], lowerBound: 0, isTruncated: false, isCancelled: isCancelled())
        }
        let regex = mode == .regex ? try? NSRegularExpression(pattern: needle, options: [.caseInsensitive]) : nil
        let matcher: (String) -> Bool = { value in
            let text = boundedSearchText(value, budget: budget)
            if let regex {
                var found = false
                regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { result, _, stop in
                    if budget.stopped { stop.pointee = true; return }
                    if result != nil { found = true; stop.pointee = true }
                }
                return found
            }
            return text.range(of: needle, options: .caseInsensitive) != nil
        }
        var raw: [BinarySearchResult] = []
        for (slot, image) in searchTargets(in: snapshot)
            where scope.includes(slot: slot, path: snapshot.binary(in: slot)?.path) {
            guard !budget.stopped else { break }
            let hits: [BinarySearchResult]
            if mode == .hex {
                hits = hexSearch(needle, in: image, budget: budget)
            } else {
                var rows: [BinarySearchResult] = []
                let instructionCandidates = scope.kinds.contains(.instruction) ? image.instructions : []
                for row in instructionCandidates {
                    guard budget.visit() else { break }
                    guard scope.kinds.contains(.instruction) else { continue }
                    let authored = image.addressOverrides[ImageAddress(slot: slot, address: row.address)]
                    let text = [row.mnemonic, row.operands, authored?.customName,
                                authored?.customComment ?? row.comment, authored?.tag].compactMap { $0 }
                        .map { boundedSearchText($0, budget: budget) }.joined(separator: " ")
                    if matcher(text) { budget.append(.init(address: row.address, kind: .instruction, preview: String(text.prefix(512))), to: &rows) }
                }
                let stringCandidates = scope.kinds.contains(.string) ? image.stringLiterals : []
                for literal in stringCandidates {
                    guard budget.visit() else { break }
                    if scope.kinds.contains(.string), matcher(literal.value) { budget.append(.init(address: literal.address, kind: .string, preview: String(literal.value.prefix(512))), to: &rows) }
                }
                let symbolCandidates = scope.kinds.contains(.symbol) ? image.symbols : []
                for symbol in symbolCandidates {
                    guard budget.visit() else { break }
                    guard let address = symbol.address, scope.kinds.contains(.symbol) else { continue }
                    let name = image.addressOverrides[ImageAddress(slot: slot, address: address)]?.customName ?? symbol.name
                    if matcher(name) { budget.append(.init(address: address, kind: .symbol, preview: String(name.prefix(512))), to: &rows) }
                }
                let functionCandidates = scope.kinds.contains(.function) ? image.functions : []
                for function in functionCandidates {
                    guard budget.visit() else { break }
                    guard scope.kinds.contains(.function) else { continue }
                    let name = image.addressOverrides[ImageAddress(slot: slot, address: function.startAddress)]?.customName ?? function.name
                    if matcher(name) { budget.append(.init(address: function.startAddress, kind: .function, preview: String(name.prefix(512))), to: &rows) }
                }
                hits = rows
            }
            raw += hits.map { hit in var tagged = hit; tagged.imageSlot = slot; return tagged }
        }
        var seen = Set<String>()
        let hits = raw.filter { seen.insert($0.id).inserted }.sorted {
            $0.imageSlot == $1.imageSlot ? $0.address < $1.address : $0.imageSlot < $1.imageSlot
        }
        return BoundedOutcome(results: Array(hits.prefix(min(500, max(1, limit)))), lowerBound: hits.count,
                              isTruncated: budget.truncated || hits.count > limit, isCancelled: isCancelled())
    }

    private func boundedSearchText(_ value: String, budget: ScanBudget) -> String {
        var prefix = String.UnicodeScalarView()
        var count = 0
        for scalar in value.unicodeScalars {
            let size = scalar.value <= 0x7f ? 1 : scalar.value <= 0x7ff ? 2 : scalar.value <= 0xffff ? 3 : 4
            guard count + size <= 4_096 else { budget.truncated = true; break }
            prefix.append(scalar)
            count += size
        }
        return String(prefix)
    }

    func search(query: String, mode: BinarySearchMode, in snapshot: WorkspaceSnapshot, limit: Int = defaultLimit) -> [BinarySearchResult] {
        searchWithCount(query: query, mode: mode, in: snapshot, limit: limit).results
    }

    /// Like `search`, but also returns the total number of (de-duplicated) matches
    /// BEFORE the `limit` cap — so the UI can show "N matches, showing first L"
    /// accurately and distinguish an exactly-`limit` result set from a truncated one.
    func searchWithCount(
        query: String,
        mode: BinarySearchMode,
        in snapshot: WorkspaceSnapshot,
        scope: BinarySearchScope = .everything,
        limit: Int = defaultLimit
    ) -> (results: [BinarySearchResult], total: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], 0) }

        let matcher: ((String) -> Bool)?
        switch mode {
        case .text:
            matcher = substringMatcher(trimmed)
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) else {
                return ([], 0)
            }
            matcher = { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        case .hex:
            matcher = nil
        }

        var raw: [BinarySearchResult] = []
        for (slot, imageSnapshot) in searchTargets(in: snapshot)
            where scope.includes(slot: slot, path: snapshot.binary(in: slot)?.path) {
            let imageResults: [BinarySearchResult]
            switch mode {
            case .text, .regex:
                imageResults = textSearch(trimmed, in: imageSnapshot, matcher: matcher!)
            case .hex:
                imageResults = hexSearch(trimmed, in: imageSnapshot)
            }
            raw.append(contentsOf: imageResults.map { result in
                var tagged = result
                tagged.imageSlot = slot
                return tagged
            })
        }

        // De-duplicate (an address can match in more than one surface), sort by image
        // then address for stable navigation order, then cap — reporting the full count.
        var seen = Set<String>()
        let deduped = raw.filter { scope.kinds.contains($0.kind) && seen.insert($0.id).inserted }.sorted {
            if $0.imageSlot.rawValue != $1.imageSlot.rawValue {
                return $0.imageSlot.rawValue < $1.imageSlot.rawValue
            }
            return $0.address < $1.address
        }
        return (Array(deduped.prefix(limit)), deduped.count)
    }

    /// One projected snapshot per loaded image, in deterministic slot order. Search helpers keep
    /// using the established primary-projection algorithm, but each projection contains exactly the
    /// requested image's `analysis(in:)`. The binary-less fallback preserves legacy fixtures whose
    /// analysis lives under `.primary` without a synthetic `BinaryImage`.
    private func searchTargets(in snapshot: WorkspaceSnapshot) -> [(ImageSlot, WorkspaceSnapshot)] {
        guard !snapshot.binaries.isEmpty else { return [(.primary, snapshot)] }

        return snapshot.binaries
            .sorted { $0.slot < $1.slot }
            .compactMap { binary in
                guard let analysis = snapshot.analysis(in: binary.slot) else { return nil }
                var projected = WorkspaceSnapshot(
                    binaries: [binary],
                    analysisBySlot: [binary.slot: analysis]
                )
                projected.addressOverrides = snapshot.addressOverrides.filter { $0.key.slot == binary.slot }
                return (binary.slot, projected)
            }
    }

    /// Returns whether the query mode can even run (so the UI can flag a bad regex
    /// or an empty/odd hex pattern before showing "no results").
    func validate(query: String, mode: BinarySearchMode) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch mode {
        case .text:
            return nil
        case .regex:
            return (try? NSRegularExpression(pattern: trimmed)) == nil ? "Invalid regular expression." : nil
        case .hex:
            return Self.parseMaskedHexPattern(trimmed) == nil
                ? "Enter hex byte pairs; use ?? (or a ? nibble) as a wildcard, e.g. 48 89 ?? e5." : nil
        }
    }

    // MARK: - Text / regex

    private func substringMatcher(_ needle: String) -> (String) -> Bool {
        { haystack in haystack.range(of: needle, options: .caseInsensitive) != nil }
    }

    private func textSearch(_ query: String, in snapshot: WorkspaceSnapshot, matcher: (String) -> Bool) -> [BinarySearchResult] {
        var results: [BinarySearchResult] = []

        for row in snapshot.instructions {
            var text = row.mnemonic
            if !row.operands.isEmpty { text += " " + row.operands }
            if let comment = row.comment, !comment.isEmpty { text += "  ; " + comment }
            if matcher(text) {
                results.append(BinarySearchResult(address: row.address, kind: .instruction, preview: text))
            }
        }
        for literal in snapshot.stringLiterals where matcher(literal.value) {
            results.append(BinarySearchResult(address: literal.address, kind: .string, preview: "\"\(literal.value)\""))
        }
        for symbol in snapshot.symbols {
            guard let address = symbol.address, matcher(symbol.name) else { continue }
            results.append(BinarySearchResult(address: address, kind: .symbol, preview: symbol.name))
        }
        for function in snapshot.functions where matcher(function.name) {
            results.append(BinarySearchResult(address: function.startAddress, kind: .function, preview: function.name))
        }
        return results
    }

    // MARK: - Hex

    private func hexSearch(_ query: String, in snapshot: WorkspaceSnapshot, budget: ScanBudget? = nil) -> [BinarySearchResult] {
        guard let pattern = Self.parseMaskedHexPattern(query), !pattern.bytes.isEmpty else { return [] }
        let preview = pattern.preview

        // Preferred path (fresh analysis): scan EVERY file-backed section's raw bytes
        // from `imageBytes`, so a pattern in __const/__data/__cstring — not just the
        // decoded __text — is found and mapped to its virtual address. `sections`/
        // `imageBytes` are derived (empty after a package reload), so when they are
        // unavailable we fall back to reconstructing the decoded instruction stream.
        if !snapshot.sections.isEmpty, !snapshot.imageBytes.isEmpty {
            return sectionHexSearch(pattern, preview: preview, in: snapshot, budget: budget)
        }
        return instructionStreamHexSearch(pattern, preview: preview, in: snapshot, budget: budget)
    }

    /// Scans the bytes of every file-backed section for `pattern`, reporting each
    /// non-overlapping match at its virtual address. Zero-fill (BSS) sections have no
    /// file bytes and are skipped; sections are scanned in ascending VA so the merged,
    /// re-sorted result stays stable. Matches are confined to a single section (a
    /// pattern straddling a section boundary in the file is not a meaningful VA run).
    private func sectionHexSearch(_ pattern: MaskedHexPattern, preview: String, in snapshot: WorkspaceSnapshot, budget: ScanBudget? = nil) -> [BinarySearchResult] {
        let imageBytes = snapshot.imageBytes
        guard let overlay = try? BytePatchOverlay(patches: snapshot.patches(in: snapshot.primarySlot),
                                                  mappings: snapshot.imageByteMappings()) else { return [] }
        let imageCount = imageBytes.count

        // Sort the file-backed sections by file offset so we can clamp section i's
        // window to section i+1's offset. Zero-fill sections occupy VA space but have
        // no file bytes (their `fileOffset` is a placeholder), so they neither get
        // scanned nor bound a neighbor's window. Without the next-section clamp a PE
        // section whose `size` is its virtualSize (> on-file sizeOfRawData) would sweep
        // into the next section's raw bytes and alias false matches onto the wrong VA.
        let fileBacked = snapshot.sections
            .filter { !$0.isZeroFill && $0.size > 0 }
            .sorted { $0.fileOffset < $1.fileOffset }

        var results: [BinarySearchResult] = []
        for (i, section) in fileBacked.enumerated() {
            if budget?.stopped == true { break }
            // Clamp the section window to Int range, to what `imageBytes` actually holds
            // (a section can extend past the captured slice tail), AND to the next
            // file-backed section's file offset (the over-read guard described above).
            guard section.fileOffset <= UInt64(Int.max), section.size <= UInt64(Int.max) else { continue }
            let start = Int(section.fileOffset)
            guard start >= 0, start < imageCount else { continue }
            var endBound = section.fileOffset &+ section.size // declared end
            // Clamp to the nearest LATER section whose file offset is strictly
            // greater (don't cross into the next section's raw bytes). Skip equal
            // offsets: sections sharing a fileOffset alias the same bytes, and
            // clamping to an equal offset would zero the window and drop the
            // section entirely.
            var j = i + 1
            while j < fileBacked.count, fileBacked[j].fileOffset <= section.fileOffset { j += 1 }
            if j < fileBacked.count {
                endBound = min(endBound, fileBacked[j].fileOffset)
            }
            endBound = min(endBound, UInt64(imageCount)) // and never past the captured bytes
            guard endBound > UInt64(start) else { continue }
            var end = Int(endBound)
            if budget != nil, end - start > 1_048_576 { end = start + 1_048_576; budget?.truncated = true }
            guard end - start >= pattern.count else { continue }

            // Copy the section window into a contiguous array once, then sweep it.
            guard let effective = overlay.applying(to: imageBytes.subdata(in: start..<end),
                                                  at: section.address) else { continue }
            let window = [UInt8](effective)
            var index = 0
            let last = window.count - pattern.count
            while index <= last {
                if let budget, !budget.visit() { break }
                if matches(pattern, in: window, at: index) {
                    let address = section.address &+ UInt64(index)
                    let hit = BinarySearchResult(address: address, kind: .bytes, preview: preview)
                    if let budget { budget.append(hit, to: &results) } else { results.append(hit) }
                    index += pattern.count // non-overlapping
                } else {
                    index += 1
                }
            }
        }
        return results
    }

    /// Fallback (reloaded snapshot, no section bytes): reconstruct the decoded
    /// instruction byte stream, tagging each byte with its address, and sweep it.
    /// This is the original, pre-section behavior — including matches that straddle
    /// adjacent decoded instructions.
    private func instructionStreamHexSearch(_ pattern: MaskedHexPattern, preview: String, in snapshot: WorkspaceSnapshot, budget: ScanBudget? = nil) -> [BinarySearchResult] {
        guard let overlay = try? BytePatchOverlay(patches: snapshot.patches(in: snapshot.primarySlot)) else { return [] }
        var stream: [UInt8] = []
        var addressOf: [UInt64] = []
        for row in snapshot.instructions {
            if let budget, !budget.visit() || stream.count >= 1_048_576 { budget.truncated = true; break }
            if let budget, row.bytes.utf8.count > 4_096 { budget.truncated = true; continue }
            let raw = Data(row.bytes.split(separator: " ").compactMap { UInt8($0, radix: 16) })
            guard let bytes = overlay.applying(to: raw, at: row.address) else { continue }
            for (offset, byte) in bytes.enumerated() {
                stream.append(byte)
                addressOf.append(row.address &+ UInt64(offset))
            }
        }
        guard stream.count >= pattern.count else { return [] }

        var results: [BinarySearchResult] = []
        var index = 0
        let last = stream.count - pattern.count
        while index <= last {
            if let budget, !budget.visit() { break }
            if matches(pattern, in: stream, at: index) {
                guard (0..<pattern.count).allSatisfy({ offset in
                    let (expected, overflow) = addressOf[index].addingReportingOverflow(UInt64(offset))
                    return !overflow && addressOf[index + offset] == expected
                }) else { index += 1; continue }
                let hit = BinarySearchResult(address: addressOf[index], kind: .bytes, preview: preview)
                if let budget { budget.append(hit, to: &results) } else { results.append(hit) }
                index += pattern.count // non-overlapping
            } else {
                index += 1
            }
        }
        return results
    }

    private func matches(_ pattern: MaskedHexPattern, in stream: [UInt8], at index: Int) -> Bool {
        for offset in 0..<pattern.count where stream[index + offset] & pattern.mask[offset] != pattern.bytes[offset] {
            return false
        }
        return true
    }

    /// A byte pattern with a per-byte mask: `??` is mask 0x00, a `?` nibble masks that nibble.
    struct MaskedHexPattern: Equatable, Sendable {
        var bytes: [UInt8]
        var mask: [UInt8]
        var count: Int { bytes.count }
        var preview: String {
            zip(bytes, mask).map { byte, mask in
                let high = mask & 0xF0 == 0 ? "?" : String(byte >> 4, radix: 16)
                let low = mask & 0x0F == 0 ? "?" : String(byte & 0x0F, radix: 16)
                return high + low
            }.joined(separator: " ")
        }
    }

    /// Parses "48 89 e5", "4889e5", "0x48 0x89", and wildcards: "48 ?? e5", "4? 89", "48??e5".
    /// Returns nil for an empty pattern, a non-hex/non-`?` character, an odd number of nibbles,
    /// or a pattern that is all wildcards (it would match everywhere).
    static func parseMaskedHexPattern(_ query: String) -> MaskedHexPattern? {
        var compact = ""
        for token in query.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }) {
            var piece = token
            if piece.hasPrefix("0x") || piece.hasPrefix("0X") { piece = piece.dropFirst(2) }
            compact += piece
        }
        let nibbles = Array(compact)
        guard !nibbles.isEmpty, nibbles.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var mask: [UInt8] = []
        var index = 0
        while index < nibbles.count {
            var byte: UInt8 = 0
            var byteMask: UInt8 = 0
            for (shift, character) in [(4, nibbles[index]), (0, nibbles[index + 1])] {
                if character == "?" { continue }
                guard let value = character.hexDigitValue else { return nil }
                byte |= UInt8(value) << shift
                byteMask |= 0x0F << shift
            }
            bytes.append(byte)
            mask.append(byteMask)
            index += 2
        }
        guard mask.contains(where: { $0 != 0 }) else { return nil }
        return MaskedHexPattern(bytes: bytes, mask: mask)
    }

    /// Parses "48 89 e5", "4889e5", or "0x48 0x89" into bytes. Returns nil for an
    /// empty pattern, a non-hex character, or an odd number of nibbles.
    static func parseHexPattern(_ query: String) -> [UInt8]? {
        var compact = ""
        for token in query.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }) {
            var piece = token
            if piece.hasPrefix("0x") || piece.hasPrefix("0X") { piece = piece.dropFirst(2) }
            compact += piece
        }
        guard !compact.isEmpty, compact.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var iterator = compact.startIndex
        while iterator < compact.endIndex {
            let next = compact.index(iterator, offsetBy: 2)
            guard let byte = UInt8(compact[iterator..<next], radix: 16) else { return nil }
            bytes.append(byte)
            iterator = next
        }
        return bytes
    }
}

/// Where Find looks (Nova's Find filters): which images, which kinds of result, and whether to
/// skip Apple's system images. Applied inside the search, before the result cap, so the total
/// count reflects the scope.
struct BinarySearchScope: Equatable, Sendable {
    enum Images: String, CaseIterable, Sendable {
        case all
        case focused
    }

    var images: Images = .all
    /// The focused image's slot; used when `images == .focused`.
    var focusedSlot: ImageSlot?
    var kinds: Set<BinarySearchResult.Kind> = Set(BinarySearchResult.Kind.allCases)
    var excludesSystemImages = false

    static let everything = BinarySearchScope()

    func includes(slot: ImageSlot, path: String?) -> Bool {
        if images == .focused, let focusedSlot, slot != focusedSlot { return false }
        if excludesSystemImages, let path, Self.isSystemImage(path: path) { return false }
        return true
    }

    /// Apple's own code: the system volume, system libraries and the dyld shared cache.
    static func isSystemImage(path: String) -> Bool {
        path.hasPrefix("/System/")
            || path.hasPrefix("/usr/lib/")
            || path.hasPrefix("/Library/Apple/")
            || path.contains("dyld_shared_cache")
    }

    /// Stored form for remembering the user's filters: `images;kinds;excludeSystem`.
    var encoded: String {
        let kindList = BinarySearchResult.Kind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")
        return "\(images.rawValue);\(kindList);\(excludesSystemImages ? 1 : 0)"
    }

    init() {}

    init(encoded: String) {
        let parts = encoded.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return }
        images = Images(rawValue: parts[0]) ?? .all
        let decodedKinds = Set(parts[1].split(separator: ",").compactMap { BinarySearchResult.Kind(rawValue: String($0)) })
        kinds = decodedKinds.isEmpty ? Set(BinarySearchResult.Kind.allCases) : decodedKinds
        excludesSystemImages = parts[2] == "1"
    }
}
