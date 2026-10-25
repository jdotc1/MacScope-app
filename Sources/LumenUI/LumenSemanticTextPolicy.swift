import Foundation

/// Display-only omission and wrapping boundaries. Callers keep the source string for copying
/// and accessibility. This deliberately does not attempt to parse a programming language.
enum LumenSemanticTextKind: Sendable {
    case symbol, type, path, expression, snippet
}

enum LumenSemanticTextPolicy {
    /// Bound renderer expansion before copying candidate substrings. The original and final
    /// ellipsis are additional, so at most fourteen candidates reach either renderer.
    private static let omissionBoundaryLimit = 12

    private static func sampledBoundaries(_ boundaries: [String.Index]) -> [String.Index] {
        guard boundaries.count > omissionBoundaryLimit else { return boundaries }
        return (0..<omissionBoundaryLimit).map { slot in
            boundaries[slot * (boundaries.count - 1) / (omissionBoundaryLimit - 1)]
        }
    }

    /// Longest first; every alternative omits complete components and marks the omission.
    static func candidates(for original: String, kind: LumenSemanticTextKind) -> [String] {
        guard !original.isEmpty else { return [original] }
        var result = [original]
        if case .snippet = kind {
            // Source excerpts may be incomplete statements. Retain a complete token prefix,
            // explicitly marked as an excerpt, rather than inventing closing punctuation.
            for boundary in sampledBoundaries(Array(wrappingBoundaries(in: original, kind: kind).reversed())) {
                let candidate = String(original[..<boundary]) + "…"
                if candidate.count < original.count, !result.contains(candidate) { result.append(candidate) }
            }
            if original != "…" { result.append("…") }
            return result
        }
        for boundary in sampledBoundaries(boundaries(in: original, kind: kind)) {
            let suffix = String(original[boundary...])
            let candidate = "…" + suffix
            if candidate.count < original.count, !result.contains(candidate) {
                result.append(candidate)
            }
        }
        if original != "…" { result.append("…") }
        return result
    }

    /// Every candidate with its wrapping chunks, longest first. Labels re-render on every scroll,
    /// hover and resize, so the tokenised plan is memoised per (value, kind) (PERF-06).
    static func renderPlan(for original: String, kind: LumenSemanticTextKind) -> [(candidate: String, chunks: [String])] {
        let key = PlanKey(value: original, kind: kind)
        if let plan = planCache.withLock({ $0[key] }) { return plan }
        let plan = candidates(for: original, kind: kind).map { (candidate: $0, chunks: chunks(for: $0, kind: kind)) }
        planCache.withLock { cache in
            if cache.count >= planCacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = plan
        }
        return plan
    }

    private struct PlanKey: Hashable { let value: String; let kind: LumenSemanticTextKind }
    private static let planCacheLimit = 4_096
    private static let planCache = LumenLock<[PlanKey: [(candidate: String, chunks: [String])]]>([:])

    /// Joining the chunks always recovers the exact source, with no injected break characters.
    /// A renderer may wrap between chunks, but must not truncate within an atomic chunk.
    static func chunks(for original: String, kind: LumenSemanticTextKind) -> [String] {
        var start = original.startIndex
        var result: [String] = []
        for boundary in wrappingBoundaries(in: original, kind: kind) {
            result.append(String(original[start..<boundary]))
            start = boundary
        }
        result.append(String(original[start...]))
        return result
    }

    /// How a value shows when no semantic candidate fits: native truncation of the original,
    /// never a bare "…". Source excerpts keep their leading context, so they truncate at
    /// the tail; every other kind truncates in the middle, keeping both distinctive ends.
    enum Fallback: Equatable, Sendable { case middle, tail }

    static func fallback(for kind: LumenSemanticTextKind) -> Fallback {
        if case .snippet = kind { return .tail }
        return .middle
    }

    /// The text the fallback truncates. A path keeps its file name whole before anything else, so
    /// its fallback is the last component (every longer candidate, "…name" included, did not fit).
    static func fallbackSource(for original: String, kind: LumenSemanticTextKind) -> String {
        guard case .path = kind, let last = boundaries(in: original, kind: .path).last else { return original }
        return String(original[last...])
    }

    /// Labels that name a file or a path use the path policy (the file name stays whole and
    /// leading components go first); anything else is a qualified symbol. "LumenExtras.swift"
    /// is a file, not the member `swift` of `LumenExtras`.
    static func labelKind(for value: String) -> LumenSemanticTextKind {
        if value.hasPrefix("~/") || value.contains("/") { return .path }
        return looksLikeFileName(value) ? .path : .symbol
    }

    /// Extensions common in developer tools. A lowercase member (`Type.member`) is not one,
    /// so qualified symbols keep the symbol policy.
    private static let fileExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hh", "hpp", "c", "cc", "cpp", "cxx", "s", "asm", "ll", "metal",
        "js", "mjs", "cjs", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "java", "kt", "sh", "zsh",
        "json", "plist", "strings", "stringsdict", "xcstrings", "xib", "nib", "storyboard",
        "entitlements", "xcconfig", "md", "txt", "rtf", "log", "csv", "tsv", "yml", "yaml", "toml",
        "xml", "html", "css", "png", "jpg", "jpeg", "gif", "heic", "pdf", "svg", "icns",
        "dylib", "a", "o", "so", "tbd", "framework", "app", "appex", "bundle", "xcassets",
        "zip", "gz", "tar", "dmg", "pkg", "ipa", "lock", "resolved", "dsym", "crash", "ips"
    ]

    /// `name.ext`, optionally with `:line[:column]`, where `ext` is a known file extension.
    static func looksLikeFileName(_ value: String) -> Bool {
        var name = Substring(value)
        // Drop up to two trailing `:digits` groups (file:line:column).
        for _ in 0..<2 {
            guard let colon = name.lastIndex(of: ":") else { break }
            let digits = name[name.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { break }
            name = name[..<colon]
        }
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return false }
        let stem = name[..<dot], ext = name[name.index(after: dot)...]
        guard fileExtensions.contains(ext.lowercased()) else { return false }
        return stem.allSatisfy { $0.isLetter || $0.isNumber || "_-+@.".contains($0) }
    }

    /// Chooses a complete display candidate, wrapping only at semantic boundaries. When nothing
    /// but the bare ellipsis would fit, the original wraps natively (at spaces, else between
    /// characters) and its last line truncates per `fallback(for:)`.
    /// Returned lines are presentation-only; callers retain `original` as the value.
    static func presentation(for original: String, kind: LumenSemanticTextKind,
                             width: CGFloat, maxLines: Int,
                             measure: (String) -> CGFloat) -> [String] {
        guard width > 0, maxLines > 0 else { return [] }
        for (candidate, candidateChunks) in renderPlan(for: original, kind: kind) where candidate != "…" || original == "…" {
            var lines: [String] = []
            var line = ""
            var lineWidth: CGFloat = 0
            var fits = true
            // Each chunk is measured once and line widths accumulate (exact for the monospaced
            // code fonts this serves; within kerning for others).
            for chunk in candidateChunks {
                let chunkWidth = measure(chunk)
                guard chunkWidth <= width else { fits = false; break }
                if !line.isEmpty && lineWidth + chunkWidth > width {
                    lines.append(line)
                    if lines.count >= maxLines { fits = false; break }
                    line = chunk
                    lineWidth = chunkWidth
                } else {
                    line += chunk
                    lineWidth += chunkWidth
                }
            }
            if fits {
                lines.append(line)
                if lines.count <= maxLines { return lines }
            }
        }
        return fallbackLines(for: fallbackSource(for: original, kind: kind), mode: fallback(for: kind),
                             width: width, maxLines: maxLines, measure: measure)
    }

    /// Native-style wrapping plus last-line truncation, as an NSTextField or a SwiftUI Text with a
    /// line limit draws it. Never returns a bare ellipsis while at least one character fits.
    static func fallbackLines(for source: String, mode: Fallback, width: CGFloat, maxLines: Int,
                              measure: (String) -> CGFloat) -> [String] {
        guard width > 0, maxLines > 0, !source.isEmpty else { return [] }
        var rest = Array(source)
        var lines: [String] = []
        func fitting(_ count: Int, _ make: (Int) -> String) -> Int {
            // Largest k in 0...count whose rendering fits.
            var low = 0, high = count
            while low < high {
                let mid = (low + high + 1) / 2
                if measure(make(mid)) <= width { low = mid } else { high = mid - 1 }
            }
            return low
        }
        while lines.count < maxLines - 1, !rest.isEmpty, measure(String(rest)) > width {
            var count = max(1, fitting(rest.count) { String(rest[..<$0]) })
            // Prefer the last space in the line, as word wrapping does.
            if let space = rest[..<count].lastIndex(where: \.isWhitespace), space > 0, count < rest.count {
                count = space + 1
            }
            lines.append(String(rest[..<count]))
            rest.removeFirst(count)
        }
        guard !rest.isEmpty else { return lines }
        if measure(String(rest)) <= width {
            lines.append(String(rest))
            return lines
        }
        let shown: String
        switch mode {
        case .tail:
            let count = max(1, fitting(rest.count - 1) { String(rest[..<$0]) + "…" })
            shown = String(rest[..<count]) + "…"
        case .middle:
            func middle(_ count: Int) -> String {
                let head = (count + 1) / 2
                return String(rest[..<head]) + "…" + String(rest[(rest.count - (count - head))...])
            }
            shown = middle(max(1, fitting(rest.count - 1, middle)))
        }
        // Not even one character and the ellipsis fit: draw no partial glyph.
        guard measure(shown) <= width else { return lines }
        lines.append(shown)
        return lines
    }

    /// Lexical wrapping has more boundaries than abbreviation: every token remains present.
    /// Validate the whole value before exposing any breaks, including paired delimiters and
    /// escaped quoted literals. Ambiguous/unbalanced syntax stays atomic.
    private static func wrappingBoundaries(in value: String, kind: LumenSemanticTextKind) -> [String.Index] {
        if case .path = kind { return boundaries(in: value, kind: kind) }
        let allowsIncompleteContainers: Bool
        if case .snippet = kind { allowsIncompleteContainers = true } else { allowsIncompleteContainers = false }
        let wrapsOperators: Bool
        switch kind { case .expression, .snippet: wrapsOperators = true; default: wrapsOperators = false }
        var stack: [Character] = []
        var quote: Character?
        var escaped = false
        var result: [String.Index] = []
        var index = value.startIndex
        let closing: [Character: Character] = ["<": ">", "(": ")", "[": "]", "{": "}"]
        func append(_ boundary: String.Index) {
            if boundary > value.startIndex && boundary < value.endIndex && result.last != boundary { result.append(boundary) }
        }
        while index < value.endIndex {
            let character = value[index]
            let next = value.index(after: index)
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else if let expected = closing[character] {
                stack.append(expected)
                append(next)
            } else if ">)]}".contains(character) {
                if allowsIncompleteContainers {
                    if stack.last == character { stack.removeLast() }
                } else {
                    guard stack.popLast() == character else { return [] }
                }
            } else if character == ":" {
                if next < value.endIndex && value[next] == ":" {
                    let after = value.index(after: next)
                    append(after)
                    index = after
                    continue
                }
                append(next)
            } else if character == "," || character.isWhitespace {
                // Keep consecutive whitespace together, preserving the exact source spacing.
                if !character.isWhitespace || next == value.endIndex || !value[next].isWhitespace { append(next) }
            } else if wrapsOperators, "+-*/%=!&|^~?".contains(character) {
                // Operators stay complete, even when there is no surrounding whitespace.
                append(index)
                var after = next
                while after < value.endIndex && "+-*/%=!&|^~?".contains(value[after]) {
                    after = value.index(after: after)
                }
                append(after)
                index = after
                continue
            } else if character == "." {
                if index != value.startIndex && next < value.endIndex,
                   isIdentifierEnd(value[value.index(before: index)]), isIdentifierStart(value[next]) { append(next) }
            } else if !(character.isLetter || character.isNumber || character == "_" || "+-*/%=!&|^~?…".contains(character)) {
                return []
            }
            index = next
        }
        guard (allowsIncompleteContainers || stack.isEmpty), quote == nil else { return [] }
        return result
    }

    private static func boundaries(in value: String, kind: LumenSemanticTextKind) -> [String.Index] {
        switch kind {
        case .expression, .snippet:
            // Operators, literals and evaluation order have no safe generic abbreviation.
            return []
        case .path:
            return value.indices.compactMap { index in
                let next = value.index(after: index)
                return value[index] == "/" && next != value.endIndex ? next : nil
            }
        case .symbol, .type:
            return qualifiedBoundaries(in: value)
        }
    }

    private static func qualifiedBoundaries(in value: String) -> [String.Index] {
        var stack: [Character] = []
        var result: [String.Index] = []
        var index = value.startIndex
        let closing: [Character: Character] = ["<": ">", "(": ")", "[": "]", "{": "}"]
        while index < value.endIndex {
            let character = value[index]
            let next = value.index(after: index)
            if let expected = closing[character] {
                stack.append(expected)
            } else if ">)]}".contains(character) {
                guard stack.popLast() == character else { return [] }
            } else if character == "\"" || character == "'" || character == "`" || character == "\\" {
                return []
            } else if character == ":", stack.isEmpty {
                // A single colon may be an Objective-C selector label. Keep all labels intact.
                guard next < value.endIndex, value[next] == ":" else { return [] }
                let after = value.index(after: next)
                guard after < value.endIndex else { return [] }
                result.append(after)
                index = after
                continue
            } else if character == ".", stack.isEmpty {
                guard next < value.endIndex else { return [] }
                // Never treat ranges, decimal literals or optional chaining as qualification.
                guard index != value.startIndex, isIdentifierEnd(value[value.index(before: index)]), isIdentifierStart(value[next]) else { return [] }
                result.append(next)
            } else if stack.isEmpty && !(character.isLetter || character.isNumber || character == "_") {
                return []
            }
            index = next
        }
        guard stack.isEmpty else { return [] }
        return result
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isIdentifierEnd(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || ">)]".contains(character)
    }
}
