import CryptoKit
import Foundation

/// Captured from the host's admitted artifact and selected-slice receipts. No file is reopened
/// or rehashed here. A content digest never replaces the workspace's occurrence and image slot.
struct RecoveryImportIdentity: Hashable, Sendable {
    let coordinate: ReconstructionImageCoordinate
    let sliceOffset: UInt64
    let imageKey: String
    let hostImageKey: String

    init(loadedBinary: LoadedBinary, coordinate: ReconstructionImageCoordinate) throws {
        guard loadedBinary.artifactIntegrityState == .verified,
              loadedBinary.artifactIdentity == coordinate.image.machOIdentity,
              UInt64(loadedBinary.bytes.count) == coordinate.artifact.contentIdentity.byteCount else {
            throw RecoveryImportError.artifactMismatch
        }
        try self.init(coordinate: coordinate, sliceOffset: loadedBinary.sliceOffset)
    }

    init(coordinate: ReconstructionImageCoordinate, sliceOffset: UInt64) throws {
        guard let slice = coordinate.image.machOIdentity,
              [.arm64, .arm64e].contains(slice.architectureVariant),
              coordinate.image.architecture.rawValue == slice.architectureVariant.rawValue,
              sliceOffset <= coordinate.artifact.contentIdentity.byteCount,
              slice.selectedSliceByteCount <= coordinate.artifact.contentIdentity.byteCount - sliceOffset,
              sliceOffset <= UInt64(Int64.max), slice.selectedSliceByteCount <= UInt64(Int64.max) else {
            throw RecoveryImportError.artifactMismatch
        }
        self.coordinate = coordinate
        self.sliceOffset = sliceOffset
        let fields: NavigatorJSONValue = .object([
            "artifact_sha256": .string(coordinate.artifact.contentIdentity.digest),
            "slice_sha256": .string(slice.selectedSliceSHA256),
            "slice_offset": .int(Int64(sliceOffset)),
            "slice_size": .int(Int64(slice.selectedSliceByteCount)),
            "cpu_type": .int(Int64(slice.rawCPUType)), "cpu_subtype": .int(Int64(slice.rawCPUSubtype))
        ])
        imageKey = Self.digest(Data(try NavigatorJSONCanonical.encode(fields).utf8))
        hostImageKey = [coordinate.artifact.occurrenceID.rawValue.uuidString,
                       coordinate.image.binaryID.uuidString, String(coordinate.image.imageSlot.rawValue),
                       coordinate.analysisFingerprintSHA256, imageKey].joined(separator: ":")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum RecoveryImportError: Error, Equatable {
    case artifactMismatch, wrongManifest, malformedReport, staleCompletion, duplicateTask
    case inactiveParent, unsupportedFact
}

/// Immutable verified bundle. Create once at acquisition and retain for admission; reuse does
/// not walk the export again. Files are captured bytes, not paths that can change after checking.
struct RecoveryImportBundle: Sendable {
    let identity: RecoveryImportIdentity
    let analysis: Data

    init(identity: RecoveryImportIdentity, expectedIdentity: RecoveryImportIdentity,
         manifest: Data, files: [String: Data]) throws {
        // Admission order is intentional: artifact/slice receipt, manifest, then report decoding.
        guard identity == expectedIdentity else { throw RecoveryImportError.artifactMismatch }
        guard manifest.count <= 4 * 1024 * 1024, files.count <= 10_000,
              let text = String(data: manifest, encoding: .utf8) else { throw RecoveryImportError.wrongManifest }
        var expected: [String: String] = [:]
        var total = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            guard line.count > 66 else { throw RecoveryImportError.wrongManifest }
            let hash = String(line.prefix(64)), separator = line.dropFirst(64).prefix(2)
            let path = String(line.dropFirst(66))
            guard separator == "  ", hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !path.hasPrefix("/"), !path.contains("\\"),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  path != "MANIFEST.sha256", expected[path] == nil else { throw RecoveryImportError.wrongManifest }
            expected[path] = hash
        }
        guard !expected.isEmpty, Set(expected.keys) == Set(files.keys), let analysis = files["analysis.json"] else {
            throw RecoveryImportError.wrongManifest
        }
        for (path, data) in files {
            guard data.count <= 64 * 1024 * 1024, total <= 128 * 1024 * 1024 - data.count else {
                throw RecoveryImportError.wrongManifest
            }
            total += data.count
            guard RecoveryImportIdentity.digest(data) == expected[path] else { throw RecoveryImportError.wrongManifest }
        }
        self.identity = identity
        self.analysis = analysis
    }
}
