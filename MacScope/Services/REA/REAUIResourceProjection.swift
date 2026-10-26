import CryptoKit
import Foundation

/// Produces the exact selected-image UI request from immutable captured inputs.
/// This seam performs no acquisition, process execution, filesystem access, or evidence admission.
enum REAUIResourceProjection {
    // Each method expands into roughly 40 structural items in the shared 500,000-item
    // request budget. Leave headroom for captured documents and catalog metadata.
    static let maximumImplementations = 8_000
    enum Failure: Error, Equatable {
        case invalidIdentity
        case invalidSlice
        case contradictoryImage
        case wrongImageOrSnapshot
        case invalidPath
        case invalidCaptureHash
        case duplicatePath
        case invalidMetadata
        case budgetExceeded
    }

    static func build(
        selectedImage: LoadedBinary,
        snapshotID: String,
        documents: [REAUIResourceCapture],
        omittedDocuments: Int = 0,
        catalogs: [REAUIAssetCatalogCapture]? = nil,
        omittedCatalogs: Int = 0
    ) throws -> REAUIResourceInput {
        guard !snapshotID.isEmpty, snapshotID.utf8.count <= 256 else { throw Failure.invalidIdentity }
        guard documents.count <= 64, (0...1_000_000).contains(omittedDocuments),
              (catalogs?.count ?? 0) <= 64, (0...1_000_000).contains(omittedCatalogs) else { throw Failure.budgetExceeded }
        let target = try selectedSliceSHA256(selectedImage)
        var capturedByteCount = 0
        var paths = Set<String>()
        let projectedDocuments = try documents.map { capture -> REAUIResourceDocument in
            try verifyBinding(target: target, snapshotID: snapshotID, captureTarget: capture.targetSHA256, captureSnapshot: capture.snapshotID)
            try verifyPath(capture.relativePath)
            guard paths.insert(capture.relativePath).inserted else { throw Failure.duplicatePath }
            try reserve(capture.bytes.count, total: &capturedByteCount)
            guard isHash(capture.archiveSHA256), digest(capture.bytes) == capture.archiveSHA256 else { throw Failure.invalidCaptureHash }
            return REAUIResourceDocument(relativePath: capture.relativePath, archiveSHA256: capture.archiveSHA256,
                                         kind: capture.kind, format: capture.format, bytesBase64: capture.bytes.base64EncodedString())
        }
        var catalogPaths = Set<String>()
        let projectedCatalogs = try catalogs.map { captures in
            try captures.map { capture -> REAUIAssetCatalogDocument in
                try verifyBinding(target: target, snapshotID: snapshotID, captureTarget: capture.targetSHA256, captureSnapshot: capture.snapshotID)
                try verifyPath(capture.path)
                guard catalogPaths.insert(capture.path).inserted else { throw Failure.duplicatePath }
                guard isHash(capture.catalogSHA256), isHash(capture.toolSHA256),
                      !capture.captureID.isEmpty, capture.captureID.utf8.count <= 256 else { throw Failure.invalidIdentity }
                try reserve(capture.metadataBytes.count, total: &capturedByteCount)
                guard isHash(capture.metadataSHA256), digest(capture.metadataBytes) == capture.metadataSHA256 else { throw Failure.invalidCaptureHash }
                return REAUIAssetCatalogDocument(path: capture.path, sha256: capture.catalogSHA256, captureID: capture.captureID,
                                                toolSHA256: capture.toolSHA256, metadataJSONBase64: capture.metadataBytes.base64EncodedString(),
                                                metadataSHA256: capture.metadataSHA256)
            }
        }
        let metadata = try projectMetadata(selectedImage, target: target)
        return REAUIResourceInput(targetSHA256: target, snapshotID: snapshotID, documents: projectedDocuments,
                                  omittedDocuments: omittedDocuments, omittedCatalogs: omittedCatalogs,
                                  metadata: REAUIBoundObjCMetadata(targetSHA256: target, snapshotID: snapshotID, value: metadata),
                                  assetCatalogs: projectedCatalogs)
    }

    static func selectedSliceSHA256(_ image: LoadedBinary) throws -> String {
        if case .contradictoryEvidence = image.artifactIntegrityState { throw Failure.contradictoryImage }
        if case .verified = image.artifactIntegrityState, image.artifactIdentity == nil { throw Failure.contradictoryImage }
        guard image.sliceOffset <= UInt64(image.bytes.count), let start = Int(exactly: image.sliceOffset) else { throw Failure.invalidSlice }
        let remaining = image.bytes.count - start
        let count: Int
        if let declared = image.sliceSize {
            guard let value = Int(exactly: declared), value > 0, value <= remaining else { throw Failure.invalidSlice }
            count = value
        } else { count = remaining }
        guard count > 0 else { throw Failure.invalidSlice }
        let hash = digest(image.bytes.subdata(in: start..<(start + count)))
        if let identity = image.artifactIdentity {
            guard identity.selectedSliceByteCount == UInt64(count), identity.selectedSliceSHA256 == hash,
                  identity.rawCPUType == image.cpuType,
                  image.cpuSubtype.map({ $0 == identity.rawCPUSubtype }) ?? true else { throw Failure.contradictoryImage }
        }
        return hash
    }

    private static func projectMetadata(_ image: LoadedBinary, target: String) throws -> REAUIObjCMetadata {
        guard !image.name.isEmpty else { throw Failure.invalidMetadata }
        var implementations: [REAUIObjCImplementation] = []
        var omittedImplementations = 0
        func append(_ methods: [ObjCMethod], className: String, category: String?) throws {
            guard !className.isEmpty else { throw Failure.invalidMetadata }
            for method in methods {
                guard !method.selector.isEmpty else { throw Failure.invalidMetadata }
                guard implementations.count < maximumImplementations else {
                    omittedImplementations += 1
                    continue
                }
                let address = method.implementation.map { "0x" + String($0, radix: 16) }
                let location = REAUILocation(address: address)
                implementations.append(REAUIObjCImplementation(
                    className: className, selector: method.selector, methodType: method.isClassMethod ? "class" : "instance",
                    implementationAddress: address, category: category, location: location,
                    decode: REAUIDecodeState(status: address == nil ? "partial" : "decoded", reason: address == nil ? "implementation_not_recovered" : nil),
                    evidence: [REAUIObjCEvidence(description: "LoadedBinary Objective-C method projection; runtime dispatch was not observed",
                                                location: location, artifactPath: image.name, artifactSHA256: target)]))
            }
        }
        for cls in image.objcClasses {
            try append(cls.instanceMethods, className: cls.name, category: nil)
            try append(cls.classMethods, className: cls.name, category: nil)
        }
        for category in image.objcCategories {
            guard !category.name.isEmpty, !category.className.isEmpty else { throw Failure.invalidMetadata }
            let name = category.className + "(" + category.name + ")"
            try append(category.instanceMethods, className: name, category: category.name)
            try append(category.classMethods, className: name, category: category.name)
        }
        let decoded = implementations.filter { $0.implementationAddress != nil }.count
        var coverage = [
            REAUIObjCCoverage(facet: "objc_dispatch_implementations", status: "partial",
                              reason: image.diagnosticTruncations.isEmpty ? "loader_metadata_projection_not_exhaustive" : "loader_reported_truncated_structures",
                              examined: implementations.count, decoded: decoded)
        ]
        if omittedImplementations > 0 {
            coverage.append(REAUIObjCCoverage(facet: "objc_dispatch_projection_budget", status: "partial",
                reason: "method_projection_budget_exhausted", examined: omittedImplementations, decoded: 0))
        }
        return REAUIObjCMetadata(implementations: implementations, coverage: coverage)
    }

    private static func reserve(_ bytes: Int, total: inout Int) throws {
        guard bytes <= 8 * 1024 * 1024 - total else { throw Failure.budgetExceeded }
        total += bytes
    }
    private static func verifyBinding(target: String, snapshotID: String, captureTarget: String, captureSnapshot: String) throws {
        guard target == captureTarget, snapshotID == captureSnapshot else { throw Failure.wrongImageOrSnapshot }
    }
    private static func verifyPath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.invalidPath }
    }
    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
