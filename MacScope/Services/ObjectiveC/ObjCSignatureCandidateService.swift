import Foundation

/// The implementing container and dispatch side, independent of the IMP it shares.
struct ObjCMethodOwner: Hashable, Sendable {
    enum Container: Hashable, Sendable {
        case objcClass(name: String)
        case category(name: String, className: String)
    }

    var container: Container
    var isClassMethod: Bool

    var displayName: String {
        switch container {
        case .objcClass(let name): name
        case .category(let name, let className): "\(className)(\(name))"
        }
    }
}

enum ObjCMethodOwnerLookup: Equatable, Sendable {
    struct Match: Equatable, Sendable {
        var owner: ObjCMethodOwner
        var method: ObjCMethod

        var displayName: String {
            "\(owner.isClassMethod ? "+" : "-")[\(owner.displayName) \(method.selector)]"
        }
    }

    case unique(Match)
    case ambiguous([Match])
    case none

    var ambiguityEvidence: ObjCSignatureCandidate.Evidence? {
        guard case .ambiguous(let matches) = self else { return nil }
        return .init(id: "method-owner", kind: "Unknown", source: "Objective-C metadata",
                     detail: "Ambiguous method owner: \(matches.map(\.displayName).joined(separator: ", ")). No signature candidate is available.")
    }
}

/// A bounded, ephemeral Objective-C method-signature proposal. Metadata facts and model
/// hypotheses remain separate all the way to the UI; only an explicitly accepted, fully validated
/// candidate can be copied into the existing signature editor draft.
struct ObjCSignatureCandidate: Equatable, Sendable, Identifiable {
    struct Context: Equatable, Sendable {
        var target: ImageAddress
        var ownerBinaryID: UUID
        var architecture: String
        var imageUUID: String?
        var imageSDKVersion: String?
        var methodSelector: String
        var methodIsClassMethod: Bool
        var methodTypeEncoding: String?
        var selectedSliceIndex: Int? = nil
        /// Actual loader selection; nil remains unknown for legacy images.
        var machOSelectedSliceFact: MachOSelectedSliceFact? = nil
        var declarationSourceGeneration: UUID? = nil
        var documentInstallationID: UUID? = nil
        var analysisGeneration: UUID? = nil
        /// Qualification is editor-local; absent owners never authorize applying a candidate.
        var methodOwner: ObjCMethodOwner? = nil
    }

    struct Field: Equatable, Sendable {
        enum Source: String, Equatable, Sendable {
            case metadata = "Compiler metadata"
            case sdkDeclaration = "SDK declaration"
            case dwarfDeclaration = "DWARF declaration"
            case callSite = "Call-site evidence"
            case mtplxHypothesis = "Local MTPLX hypothesis"
        }

        var type: String?
        var source: Source?
        var note: String
    }

    struct Parameter: Equatable, Sendable, Identifiable {
        var id: Int { index }
        var index: Int
        var name: String
        var field: Field
    }

    enum DiagnosticSeverity: Int, Equatable, Sendable {
        case information
        case warning
        case error
    }

    struct Diagnostic: Equatable, Sendable, Identifiable {
        var id: String { code + ":" + message }
        var severity: DiagnosticSeverity
        var code: String
        var message: String
    }

    struct Evidence: Equatable, Sendable, Identifiable {
        var id: String
        var kind: String
        var source: String
        var detail: String
    }

    enum HypothesisState: Equatable, Sendable {
        case unavailable
        case pending
        case available
        case failed(String)

        var label: String {
            switch self {
            case .unavailable: "MTPLX hypothesis: unavailable"
            case .pending: "MTPLX hypothesis: pending"
            case .available: "MTPLX hypothesis: provisional"
            case .failed(let reason): "MTPLX hypothesis: failed — \(reason)"
            }
        }
    }

    let id: UUID
    var context: Context
    var selector: String
    var isClassMethod: Bool
    var returnField: Field
    var parameters: [Parameter]
    var diagnostics: [Diagnostic]
    var evidence: [Evidence] = []
    var hypothesisState: HypothesisState = .unavailable

    var canAccept: Bool {
        !diagnostics.contains { $0.severity == .error }
            && returnField.type != nil
            && parameters.allSatisfy { $0.field.type != nil }
    }

    var displayName: String { "\(isClassMethod ? "+" : "-")\(selector)" }
}

/// One bounded response from the existing local MTPLX path. It is evidence for a candidate, never
/// metadata and never persisted on its own. `nil` fields are explicit unknowns.
struct ObjCSignatureHypothesis: Equatable, Sendable {
    static let maximumParameterCount = 64
    static let maximumTypeUTF8Count = 256
    static let maximumNameUTF8Count = 128
    static let maximumExplanationUTF8Count = 4_096

    var returnType: String?
    var parameterTypes: [String?]
    var parameterNames: [String]
    var sdkVersion: String?
    var explanation: String
}

/// A declaration already recovered from the selected SDK or DWARF. Unlike a hypothesis, this is
/// authoritative evidence for the version it names, but it still must match the selected image.
struct ObjCSignatureDeclaration: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case sdk
        case dwarf
    }

    var source: Source
    var selector: String
    var returnType: String?
    var parameterTypes: [String?]
    var parameterNames: [String]
    var sdkVersion: String?
    var context: ObjCSignatureCandidate.Context? = nil
    var sourceIdentity: String? = nil
}

/// Deterministic evidence at a call boundary. Observations can corroborate or contradict a field;
/// they never fill an unknown with an invented type.
struct ObjCSignatureObservation: Equatable, Sendable {
    enum Position: Equatable, Sendable {
        case returnValue
        case parameter(Int)
    }

    var position: Position
    var type: String?
    var widthBits: Int?
    var source: String
    var address: UInt64? = nil
    var context: ObjCSignatureCandidate.Context? = nil
}

enum ObjCSignatureCandidateService {
    struct Input: Sendable {
        var context: ObjCSignatureCandidate.Context
        var method: ObjCMethod
        var knownNominalTypes: Set<String>
        var declaration: ObjCSignatureDeclaration? = nil
        var hypothesis: ObjCSignatureHypothesis?
        var observations: [ObjCSignatureObservation]
    }

    static func makeCandidate(_ input: Input) -> ObjCSignatureCandidate {
        let selectorArity = input.method.selector.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        let metadata = input.method.typeEncoding.flatMap {
            ObjCMethodEncodingFacts.decode($0, expectedParameterCount: selectorArity)
        }
        let hypothesis = bounded(input.hypothesis)
        // An unqualified declaration never supplies a type. The raw input is still validated
        // below so version and selector errors remain visible even when it cannot be admitted.
        let declaration = input.declaration.flatMap {
            $0.context == input.context && $0.sourceIdentity?.isEmpty == false
                && $0.sdkVersion == input.context.imageSDKVersion ? $0 : nil
        }

        let returnField = field(
            metadata: metadata?.returnType,
            declaration: declaration?.returnType,
            declarationSource: declaration.map(Self.declarationSource),
            hypothesis: hypothesis?.returnType,
            hypothesisSource: hypothesis == nil ? nil : .mtplxHypothesis,
            label: "return type"
        )
        var parameters: [ObjCSignatureCandidate.Parameter] = []
        parameters.reserveCapacity(selectorArity)
        for index in 0..<selectorArity {
            let metadataType = metadata?.parameterTypes[safe: index] ?? nil
            let declarationType = declaration?.parameterTypes[safe: index] ?? nil
            let hypothesisType = hypothesis?.parameterTypes[safe: index] ?? nil
            let name = declaration?.parameterNames[safe: index]
                .flatMap(Self.normalizedIdentifier)
                ?? hypothesis?.parameterNames[safe: index]
                .flatMap(Self.normalizedIdentifier)
                ?? "arg\(index)"
            parameters.append(ObjCSignatureCandidate.Parameter(
                index: index,
                name: name,
                field: field(
                    metadata: metadataType,
                    declaration: declarationType,
                    declarationSource: declaration.map(Self.declarationSource),
                    hypothesis: hypothesisType,
                    hypothesisSource: hypothesis == nil ? nil : .mtplxHypothesis,
                    label: "parameter \(index + 1)"
                )
            ))
        }

        var candidate = ObjCSignatureCandidate(
            id: UUID(),
            context: input.context,
            selector: input.method.selector,
            isClassMethod: input.method.isClassMethod,
            returnField: returnField,
            parameters: parameters,
            diagnostics: []
        )
        candidate.diagnostics = validate(
            candidate,
            method: input.method,
            knownNominalTypes: input.knownNominalTypes,
            declaration: input.declaration,
            hypothesis: hypothesis,
            observations: input.observations
        )
        candidate.evidence = [.init(id: "sdk", kind: "Declaration", source: "SDK",
                                    detail: "SDK declarations: no trusted source")]
        if let declaration {
            candidate.evidence.append(.init(id: "dwarf", kind: "Declaration",
                source: declaration.sourceIdentity ?? "Unknown source",
                detail: "\(declaration.selector): \(declaration.returnType ?? "Unknown") (\(declaration.parameterTypes.map { $0 ?? "Unknown" }.joined(separator: ", ")) )"))
        } else {
            candidate.evidence.append(.init(id: "dwarf", kind: "Declaration", source: "DWARF",
                detail: "No qualified declaration for this image and slice"))
        }
        if input.declaration != nil && declaration == nil {
            candidate.diagnostics.append(.init(severity: .error, code: "declaration-identity",
                message: "The declaration's image, slice, source or SDK qualification does not match."))
        }
        if let hypothesis {
            candidate.hypothesisState = .available
            candidate.evidence.append(.init(id: "hypothesis", kind: "Hypothesis", source: "Local MTPLX",
                detail: "\(hypothesis.explanation) Return: \(hypothesis.returnType ?? "Unknown"); arguments: \(hypothesis.parameterTypes.map { $0 ?? "Unknown" }.joined(separator: ", "))"))
        }
        return candidate
    }

    static func validateCurrentContext(
        _ candidate: ObjCSignatureCandidate,
        current: ObjCSignatureCandidate.Context
    ) -> ObjCSignatureCandidate.Diagnostic? {
        guard candidate.context.methodOwner != nil, candidate.context == current else {
            return .init(
                severity: .error,
                code: "stale-context",
                message: "The image, method owner, address, architecture, or SDK identity is unqualified or changed after this candidate was created."
            )
        }
        return nil
    }

    private static func bounded(_ hypothesis: ObjCSignatureHypothesis?) -> ObjCSignatureHypothesis? {
        guard var hypothesis,
              hypothesis.parameterTypes.count <= ObjCSignatureHypothesis.maximumParameterCount,
              hypothesis.parameterNames.count <= ObjCSignatureHypothesis.maximumParameterCount,
              hypothesis.parameterNames.allSatisfy({
                  $0.utf8.count <= ObjCSignatureHypothesis.maximumNameUTF8Count
              }),
              hypothesis.explanation.utf8.count <= ObjCSignatureHypothesis.maximumExplanationUTF8Count,
              [hypothesis.returnType].compactMap({ $0 }).allSatisfy({ boundedType($0) }),
              hypothesis.parameterTypes.compactMap({ $0 }).allSatisfy({ boundedType($0) }) else {
            return nil
        }
        hypothesis.returnType = hypothesis.returnType.flatMap(normalizedType)
        hypothesis.parameterTypes = hypothesis.parameterTypes.map { $0.flatMap(normalizedType) }
        hypothesis.parameterNames = Array(hypothesis.parameterNames.prefix(hypothesis.parameterTypes.count))
        return hypothesis
    }

    private static func boundedType(_ type: String) -> Bool {
        type.utf8.count <= ObjCSignatureHypothesis.maximumTypeUTF8Count
    }

    private static func field(
        metadata: String?,
        declaration: String?,
        declarationSource: ObjCSignatureCandidate.Field.Source?,
        hypothesis: String?,
        hypothesisSource: ObjCSignatureCandidate.Field.Source?,
        label: String
    ) -> ObjCSignatureCandidate.Field {
        if let metadata = metadata.flatMap(normalizedType) {
            let conflictingDeclaration = declaration.flatMap(normalizedType).flatMap {
                $0 == metadata ? nil : "The declaration records `\($0)`, which contradicts metadata."
            }
            let conflictingHypothesis = hypothesis.flatMap(normalizedType).flatMap {
                $0 == metadata ? nil : "The hypothesis proposed `\($0)`, which contradicts metadata."
            }
            return .init(
                type: metadata,
                source: .metadata,
                note: conflictingDeclaration ?? conflictingHypothesis ?? "Read from the Objective-C method encoding."
            )
        }
        if let declaration = declaration.flatMap(normalizedType) {
            let contradiction = hypothesis.flatMap(normalizedType).flatMap {
                $0 == declaration ? nil : "The hypothesis proposed `\($0)`, which contradicts the declaration."
            }
            return .init(
                type: declaration,
                source: declarationSource,
                note: contradiction ?? "Read from the selected declaration evidence."
            )
        }
        if let hypothesis = hypothesis.flatMap(normalizedType) {
            return .init(
                type: hypothesis,
                source: hypothesisSource,
                note: "Proposed locally; no method-encoding fact fills this \(label)."
            )
        }
        return .init(type: nil, source: nil, note: "Unknown; no supported evidence supplies this \(label).")
    }

    private static func validate(
        _ candidate: ObjCSignatureCandidate,
        method: ObjCMethod,
        knownNominalTypes: Set<String>,
        declaration: ObjCSignatureDeclaration?,
        hypothesis: ObjCSignatureHypothesis?,
        observations: [ObjCSignatureObservation]
    ) -> [ObjCSignatureCandidate.Diagnostic] {
        var diagnostics: [ObjCSignatureCandidate.Diagnostic] = []
        func append(_ severity: ObjCSignatureCandidate.DiagnosticSeverity, _ code: String, _ message: String) {
            diagnostics.append(.init(severity: severity, code: code, message: message))
        }

        let selectorArity = method.selector.filter { $0 == ":" }.count
        if candidate.context.methodSelector != method.selector
            || candidate.context.methodIsClassMethod != method.isClassMethod
            || candidate.context.methodTypeEncoding != method.typeEncoding {
            append(.error, "method-context", "The candidate context does not match the selected Objective-C method metadata.")
        }
        let selectorParts = method.selector.split(separator: ":", omittingEmptySubsequences: false)
        let selectorHasEmptyKeyword = selectorArity > 0
            && selectorParts.dropLast().contains(where: \.isEmpty)
        if method.selector.isEmpty || method.selector.utf8.count > 512 || selectorHasEmptyKeyword
            || method.selector.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }) {
            append(.error, "selector-grammar", "The Objective-C selector is empty or has an invalid keyword boundary.")
        }
        if candidate.parameters.count != selectorArity {
            append(.error, "selector-arity", "Selector `\(method.selector)` requires \(selectorArity) explicit parameter(s), but the candidate has \(candidate.parameters.count).")
        }
        if let hypothesis, hypothesis.parameterTypes.count != selectorArity {
            append(.error, "hypothesis-arity", "The local hypothesis has \(hypothesis.parameterTypes.count) parameter field(s) for a \(selectorArity)-argument selector.")
        }
        if let declaration, declaration.selector != method.selector {
            append(.error, "declaration-selector", "The declaration names selector `\(declaration.selector)`, not `\(method.selector)`." )
        }
        if let declaration, declaration.parameterTypes.count != selectorArity {
            append(.error, "declaration-arity", "The declaration has \(declaration.parameterTypes.count) parameter field(s) for a \(selectorArity)-argument selector.")
        }
        if let declarationSDK = declaration?.sdkVersion,
           declarationSDK != candidate.context.imageSDKVersion {
            let imageSDK = candidate.context.imageSDKVersion ?? "an unknown SDK"
            append(.error, "declaration-sdk-version", "The declaration targets SDK \(declarationSDK), but the selected image records \(imageSDK).")
        }
        if let candidateSDK = hypothesis?.sdkVersion,
           candidateSDK != candidate.context.imageSDKVersion {
            let imageSDK = candidate.context.imageSDKVersion ?? "an unknown SDK"
            append(.error, "sdk-version", "The hypothesis targets SDK \(candidateSDK), but the selected image records \(imageSDK).")
        }
        if candidate.returnField.type == nil {
            append(.error, "missing-return", "The return type remains unknown.")
        }
        for parameter in candidate.parameters where parameter.field.type == nil {
            append(.error, "missing-parameter", "Parameter \(parameter.index + 1) remains unknown.")
        }

        let typedFields = [("return type", candidate.returnField)] + candidate.parameters.map {
            ("parameter \($0.index + 1)", $0.field)
        }
        for (label, field) in typedFields {
            guard let type = field.type else { continue }
            if !ObjCCandidateTypeGrammar.isValid(type) {
                append(.error, "type-grammar", "The \(label) `\(type)` is outside the supported C/Objective-C type grammar.")
            }
            for name in ObjCCandidateTypeGrammar.nominalNames(in: type)
            where !knownNominalTypes.contains(name) {
                append(.error, "unknown-nominal", "The \(label) references unknown class or protocol `\(name)`.")
            }
        }

        let metadata = method.typeEncoding.flatMap {
            ObjCMethodEncodingFacts.decode($0, expectedParameterCount: selectorArity)
        }
        let metadataTypes = [metadata?.returnType ?? nil]
            + (0..<selectorArity).map { metadata?.parameterTypes[safe: $0] ?? nil }
        let declarationTypes = [declaration?.returnType ?? nil]
            + (0..<selectorArity).map { declaration?.parameterTypes[safe: $0] ?? nil }
        let hypothesisTypes = [hypothesis?.returnType ?? nil]
            + (0..<selectorArity).map { hypothesis?.parameterTypes[safe: $0] ?? nil }
        for index in 0..<metadataTypes.count {
            let label = index == 0 ? "return type" : "parameter \(index)"
            if let fact = metadataTypes[index].flatMap(normalizedType),
               let proposed = declarationTypes[index].flatMap(normalizedType), fact != proposed {
                append(.error, "metadata-declaration-conflict", "The \(label) declaration `\(proposed)` contradicts metadata `\(fact)`.")
            }
            let authority = metadataTypes[index].flatMap(normalizedType)
                ?? declarationTypes[index].flatMap(normalizedType)
            if let authority,
               let proposed = hypothesisTypes[index].flatMap(normalizedType), authority != proposed {
                append(.error, "hypothesis-conflict", "The \(label) hypothesis `\(proposed)` contradicts authoritative evidence `\(authority)`.")
            }
        }

        for observation in observations {
            if observation.address != nil && observation.context != candidate.context { continue }
            let proposed: String?
            let label: String
            switch observation.position {
            case .returnValue:
                proposed = candidate.returnField.type
                label = "return type"
            case .parameter(let index):
                proposed = candidate.parameters[safe: index]?.field.type
                label = "parameter \(index + 1)"
            }
            guard let proposed else { continue }
            if let observed = observation.type.flatMap(normalizedType), observed != proposed {
                append(.error, "contradictory-observation", "The \(label) `\(proposed)` contradicts \(observation.source), which records `\(observed)`.")
            }
            if let observedWidth = observation.widthBits,
               let proposedWidth = ObjCCandidateABI.width(of: proposed, architecture: candidate.context.architecture),
               observedWidth != proposedWidth {
                append(.error, "abi-width", "The \(label) is \(proposedWidth)-bit for \(candidate.context.architecture), but \(observation.source) requires \(observedWidth) bits.")
            }
        }

        if method.typeEncoding == nil {
            append(.information, "metadata-absent", "The image has no Objective-C type encoding for this method; proposed fields remain visibly hypothesis-backed.")
        }
        return diagnostics
    }

    private static func normalizedType(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func declarationSource(
        _ declaration: ObjCSignatureDeclaration
    ) -> ObjCSignatureCandidate.Field.Source {
        declaration.source == .sdk ? .sdkDeclaration : .dwarfDeclaration
    }

    private static func normalizedIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "_" || first.isLetter,
              trimmed.dropFirst().allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return trimmed
    }
}

private enum ObjCCandidateABI {
    static func width(of type: String, architecture: String) -> Int? {
        let type = type.replacingOccurrences(of: "const ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if type.contains("*") || ["id", "Class", "SEL"].contains(type) {
            return architecture.lowercased().contains("64") ? 64 : 32
        }
        let catalogWidth = CallSignatureCatalog.integerWidth(type)
        if catalogWidth > 0 { return catalogWidth }
        switch type {
        case "float": return 32
        case "double", "long double": return 64
        case "NSInteger", "NSUInteger":
            return architecture.lowercased().contains("64") ? 64 : 32
        default: return nil
        }
    }
}

private enum ObjCCandidateTypeGrammar {
    private static let scalarWords: Set<String> = [
        "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned",
        "BOOL", "bool", "_Bool", "id", "Class", "SEL", "NSInteger", "NSUInteger",
        "int8_t", "uint8_t", "int16_t", "uint16_t", "int32_t", "uint32_t", "int64_t", "uint64_t",
        "size_t", "ssize_t", "const", "volatile", "struct", "union", "enum"
    ]

    static func isValid(_ type: String) -> Bool {
        guard !type.isEmpty, type.utf8.count <= ObjCSignatureHypothesis.maximumTypeUTF8Count,
              type.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || CharacterSet.whitespaces.contains(scalar)
                      || "_*<>".unicodeScalars.contains(scalar)
              }) else { return false }
        let words = type.split { $0.isWhitespace || $0 == "*" || $0 == "<" || $0 == ">" }.map(String.init)
        return !words.isEmpty && words.allSatisfy { word in
            scalarWords.contains(word) || isIdentifier(word)
        }
    }

    static func nominalNames(in type: String) -> [String] {
        let words = type.split { $0.isWhitespace || $0 == "*" || $0 == "<" || $0 == ">" }.map(String.init)
        return words.filter { !scalarWords.contains($0) && isIdentifier($0) }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

private enum ObjCMethodEncodingFacts {
    struct Result {
        var returnType: String?
        var parameterTypes: [String?]
    }

    static func decode(_ encoding: String, expectedParameterCount: Int) -> Result? {
        guard encoding.utf8.count <= 4_096 else { return nil }
        let characters = Array(encoding)
        var index = 0
        var tokens: [String?] = []
        while index < characters.count, tokens.count < expectedParameterCount + 3 {
            while index < characters.count, characters[index].isNumber || characters[index] == "-" {
                index += 1
            }
            guard index < characters.count else { break }
            let start = index
            guard consumeType(characters, index: &index, depth: 0), index > start else { return nil }
            let token = String(characters[start..<index])
            tokens.append(isSupported(token) ? ObjCTypeEncoding.decode(token) : nil)
        }
        guard tokens.count >= 3 else { return nil }
        return Result(
            returnType: tokens[0],
            parameterTypes: Array(tokens.dropFirst(3).prefix(expectedParameterCount))
                + Array(repeating: nil, count: max(0, expectedParameterCount - max(0, tokens.count - 3)))
        )
    }

    private static func consumeType(_ characters: [Character], index: inout Int, depth: Int) -> Bool {
        guard depth < 16 else { return false }
        while index < characters.count, "rnNoORV".contains(characters[index]) { index += 1 }
        guard index < characters.count else { return false }
        let marker = characters[index]
        index += 1
        switch marker {
        case "^":
            return consumeType(characters, index: &index, depth: depth + 1)
        case "@":
            if index < characters.count, characters[index] == "?" { index += 1; return true }
            if index < characters.count, characters[index] == "\"" {
                index += 1
                while index < characters.count, characters[index] != "\"" { index += 1 }
                guard index < characters.count else { return false }
                index += 1
            }
            return true
        case "{", "(":
            let closing: Character = marker == "{" ? "}" : ")"
            var nesting = 1
            while index < characters.count, nesting > 0 {
                if characters[index] == marker { nesting += 1 }
                if characters[index] == closing { nesting -= 1 }
                index += 1
                if nesting > 16 { return false }
            }
            return nesting == 0
        case "[":
            while index < characters.count, characters[index].isNumber { index += 1 }
            guard consumeType(characters, index: &index, depth: depth + 1),
                  index < characters.count, characters[index] == "]" else { return false }
            index += 1
            return true
        case "b":
            while index < characters.count, characters[index].isNumber { index += 1 }
            return true
        default:
            return true
        }
    }

    private static func isSupported(_ token: String) -> Bool {
        let stripped = token.drop { "rnNoORV".contains($0) }
        guard let marker = stripped.first else { return false }
        return "vcsSiIlLqQfdDB*#:@^{([b".contains(marker)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
