import Foundation

/// Exact reviewed nibkit commit: this prevents silent JSON-shape changes
/// from being treated as equally authoritative. MacScope can opt into a new
/// revision with a separate schema/fixture review.
public enum NibKitRevision {
    public static let reviewed = "fcf4670db8ba5d5d94ab62951a971be949b7b21f"
}

public struct NibKitDecodeLimits: Sendable {
    public let maxOutputBytes: Int
    public let maxDocuments: Int
    public let maxRecords: Int
    public let maxFieldBytes: Int

    public init(maxOutputBytes: Int = 10 * 1024 * 1024,
                maxDocuments: Int = 256, maxRecords: Int = 65_536,
                maxFieldBytes: Int = 4096) {
        self.maxOutputBytes = maxOutputBytes
        self.maxDocuments = maxDocuments
        self.maxRecords = maxRecords
        self.maxFieldBytes = maxFieldBytes
    }
}

public struct NibKitDecodeInput: Sendable {
    /// Admitted invocation label -> independently proven bundle resource ID.
    /// Production worker usually invokes the CLI with just one .nib.
    public let admittedResources: [String: AppKitResourceIdentity]
    public let donorRevision: String
    public let helperExitCode: Int32

    public init(admittedResources: [String: AppKitResourceIdentity],
                donorRevision: String, helperExitCode: Int32) {
        self.admittedResources = admittedResources
        self.donorRevision = donorRevision
        self.helperExitCode = helperExitCode
    }
}

private struct RawNibDocument: Decodable {
    let file: String
    let error: String?
    let formatVersion: Int?
    let coderVersion: Int?
    let outlets: [NibConnection]?
    let actions: [NibConnection]?
    let runtimeAttrs: [NibRuntimeAttribute]?
    let classes: [NibCustomClass]?
    let navigation: [NibNavigationHint]?
}

private enum RawOneOrMany: Decodable {
    case one(RawNibDocument)
    case many([RawNibDocument])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([RawNibDocument].self) {
            self = .many(arr)
        } else {
            self = .one(try container.decode(RawNibDocument.self))
        }
    }

    var documents: [RawNibDocument] {
        switch self {
        case .one(let doc): return [doc]
        case .many(let docs): return docs
        }
    }
}

public struct NibKitDecoder: Sendable {
    public let limits: NibKitDecodeLimits
    public init(limits: NibKitDecodeLimits = NibKitDecodeLimits()) { self.limits = limits }

    public func decode(_ output: Data, input: NibKitDecodeInput) -> NibParseBatch {
        func fail(_ reason: NibRefusalReason, _ detail: String = "") -> NibParseBatch {
            NibParseBatch(documents: [], refusals: [NibRefusal(inputLabel: "<batch>", reason: reason, detail: detail)],
                          helperExitCode: input.helperExitCode, complete: false)
        }

        guard limits.maxOutputBytes >= 0, limits.maxDocuments > 0,
              limits.maxRecords >= 0, limits.maxFieldBytes > 0,
              input.admittedResources.count <= limits.maxDocuments,
              Set(input.admittedResources.values).count == input.admittedResources.count,
              input.admittedResources.keys.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= limits.maxFieldBytes &&
                  label.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
              }) else { return fail(.invalidResourceIdentity, "invalid admission map or decode limits") }
        guard input.donorRevision == NibKitRevision.reviewed else {
            return fail(.unsupportedDonorRevision, "pinned donor identity did not match")
        }
        guard !input.admittedResources.isEmpty,
              input.admittedResources.values.allSatisfy(\.hasValidIdentity) else {
            return fail(.invalidResourceIdentity, "admitted source identity invalid")
        }
        guard output.count <= limits.maxOutputBytes else {
            return fail(.outputTooLarge, "bounded output cap")
        }
        let raw: [RawNibDocument]
        do { raw = try JSONDecoder().decode(RawOneOrMany.self, from: output).documents }
        catch { return fail(.corruptJSON, "upstream JSON could not be decoded") }
        guard raw.count <= limits.maxDocuments else {
            return fail(.tooManyDocuments, "document cap")
        }

        var seen = Set<String>()
        var documents = [NibDecodedDocument]()
        var refusals = [NibRefusal]()
        var recordCount = 0
        for doc in raw {
            // Do not trust donor file label to establish a filesystem path.
            guard let resource = input.admittedResources[doc.file] else {
                refusals.append(.init(inputLabel: "<unadmitted>", reason: .unexpectedDocument,
                                      detail: "upstream emitted a document not mapped by worker"))
                continue
            }
            guard seen.insert(doc.file).inserted else {
                refusals.append(.init(inputLabel: doc.file, reason: .duplicateDocument,
                                      detail: "duplicate donor label"))
                continue
            }
            if doc.error != nil {
                // Do not carry untrusted parser error text into app diagnostics.
                refusals.append(.init(inputLabel: doc.file, reason: .donorDocumentError,
                                      detail: "nibkit reported a resource error"))
                continue
            }
            guard let format = doc.formatVersion, let coder = doc.coderVersion,
                  let outs = doc.outlets, let acts = doc.actions,
                  let attrs = doc.runtimeAttrs, let classes = doc.classes,
                  let nav = doc.navigation else {
                refusals.append(.init(inputLabel: doc.file, reason: .missingRequiredFields,
                                      detail: "not full -J all output"))
                continue
            }
            recordCount += outs.count + acts.count + attrs.count + classes.count + nav.count +
                           nav.reduce(0, { $0 + ($1.details?.count ?? 0) })
            guard recordCount <= limits.maxRecords else {
                return fail(.tooManyRecords, "bounded record count")
            }
            var values: [String] = []
            for connection in outs + acts {
                values += [connection.kind, connection.name, connection.source,
                           connection.destination, connection.event ?? ""]
            }
            for attr in attrs { values += [attr.object, attr.keyPath, attr.value] }
            for cls in classes { values += [cls.class, cls.base, cls.sceneID ?? "", cls.module ?? ""] }
            for hint in nav {
                values += [hint.kind, hint.sourceClass, hint.sourceSceneID ?? "",
                           hint.destinationClass ?? "", hint.destinationID ?? "",
                           hint.identifier ?? "", hint.selector ?? "", hint.customClass ?? ""]
                for (key, value) in hint.details ?? [:] { values += [key, value] }
            }
            guard values.allSatisfy({ $0.utf8.count <= limits.maxFieldBytes }) else {
                refusals.append(.init(inputLabel: doc.file, reason: .oversizedText,
                                      detail: "field cap"))
                continue
            }
            guard outs.allSatisfy({ $0.kind == "outlet" }) else {
                refusals.append(.init(inputLabel: doc.file, reason: .missingRequiredFields,
                                      detail: "outlet row with conflicting kind"))
                continue
            }
            guard (outs + acts).allSatisfy({
                ($0.sourceObjectIndex ?? 0) >= 0 && ($0.destinationObjectIndex ?? 0) >= 0
            }) else {
                refusals.append(.init(inputLabel: doc.file, reason: .missingRequiredFields,
                                      detail: "negative resource-local object index"))
                continue
            }
            documents.append(.init(resource: resource, donorRevision: input.donorRevision,
                                   archiveFormatVersion: format, coderVersion: coder,
                                   outlets: outs, actions: acts, runtimeAttributes: attrs,
                                   customClasses: classes, navigation: nav))
        }

        // A parse output that omitted an admitted resource cannot be complete.
        for missing in input.admittedResources.keys.sorted() where !seen.contains(missing) {
            refusals.append(.init(inputLabel: missing, reason: .unexpectedDocument,
                                  detail: "admitted resource missing from donor output"))
        }
        if input.helperExitCode != 0 {
            refusals.append(.init(inputLabel: "<batch>", reason: .donorExitNonzero,
                                  detail: "helper exited nonzero"))
        }
        let complete = refusals.isEmpty && input.helperExitCode == 0 &&
                       documents.count == input.admittedResources.count
        // Fail closed at this boundary: if a multi-document batch contains any
        // error, expose refusals but withhold successful docs from fusion.
        return .init(documents: complete ? documents : [], refusals: refusals,
                     helperExitCode: input.helperExitCode, complete: complete)
    }
}
