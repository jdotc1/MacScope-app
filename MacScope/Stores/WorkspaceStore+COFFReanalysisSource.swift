import Foundation

extension WorkspaceStore {
    /// Missing marker denotes the original persisted coordinate system, never an upgrade request.
    static func savedCOFFSectionLayoutVersion(_ binary: BinaryImage) -> Int? {
        guard binary.kind == "COFF object" else { return nil }
        return binary.metadata.coffSectionLayoutVersion ?? 0
    }

    /// A resolved reanalysis input. `cleanup()` removes the temp file in the recovery case (a
    /// no-op for the on-disk-source case).
    struct ReanalysisSource {
        let url: URL
        let selection: BinaryLoadSelection
        let isRecovered: Bool
        let cleanup: () -> Void
    }

    /// Reanalyzes the exact selected-image bytes retained when this workspace was loaded.
    /// The original path may have been rebuilt or replaced independently of this document.
    /// Reopening it while keeping the current authoring and binary owner would silently apply
    /// those edits to a different input. Retained Mach-O slices and ELF members are directly
    /// loadable; the original location remains the display and artifact-provenance authority.
    /// Legacy snapshots without retained bytes keep the existing original-path fallback.
    /// ELF archive members are the exception: their exact authority is the persisted outer
    /// container path plus the member selection (container and member hashes are re-checked by
    /// the loader), never a temp recovery copy; `reanalyzeHonoringOverrides` refuses beforehand
    /// when that container is missing.
    func reanalysisSource(in slot: ImageSlot, coffSectionLayoutVersion requestedVersion: Int? = nil) -> ReanalysisSource? {
        let savedVersion = snapshot.binary(in: slot).flatMap(Self.savedCOFFSectionLayoutVersion)
        let version = requestedVersion ?? savedVersion
        guard version == nil || version == 0 || version == 1 else {
            lastIssue = BinaryLoadSelectionError.invalidCOFFSectionLayoutVersion.localizedDescription
            return nil
        }
        if let binary = snapshot.binary(in: slot),
           let member = binary.elfArchiveMemberIdentity {
            guard !binary.path.isEmpty, FileManager.default.fileExists(atPath: binary.path) else {
                return nil
            }
            return ReanalysisSource(
                url: URL(fileURLWithPath: binary.path),
                selection: BinaryLoadSelection(elfArchiveMember: member),
                isRecovered: false,
                cleanup: {}
            )
        }
        let bytes = snapshot.analysis(in: slot)?.imageBytes ?? Data()
        if !bytes.isEmpty {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("macscope-recover-\(UUID().uuidString)")
            guard (try? bytes.write(to: temp)) != nil else { return nil }
            return ReanalysisSource(
                url: temp,
                selection: BinaryLoadSelection(coffSectionLayoutVersion: version),
                isRecovered: true,
                cleanup: { try? FileManager.default.removeItem(at: temp) }
            )
        }
        // A named cache projection without captured bytes reprojects the image the user picked at
        // open time from its cache, never the cache's default first image.
        if let binary = snapshot.binary(in: slot), let cacheImage = binary.dyldCacheProjectionSelection {
            return ReanalysisSource(
                url: cacheImage.cacheURL,
                selection: .dyldCacheImage(cacheImage.installName),
                isRecovered: false,
                cleanup: {}
            )
        }
        if let binary = snapshot.binary(in: slot), !binary.path.isEmpty,
           FileManager.default.fileExists(atPath: binary.path) {
            return ReanalysisSource(
                url: URL(fileURLWithPath: binary.path),
                selection: BinaryLoadSelection(
                    requestedMachOSliceIndex: binary.selectedSliceIndex,
                    elfArchiveMember: binary.elfArchiveMemberIdentity,
                    coffSectionLayoutVersion: version
                ),
                isRecovered: false,
                cleanup: {}
            )
        }
        return nil
    }

}
