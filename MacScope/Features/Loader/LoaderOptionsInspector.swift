import Foundation

/// The thin I/O shim that turns a candidate file URL into a `LoaderOptionsModel` for the
/// open-time dialog. Resolves an `.app` bundle to its executable, parses the Mach-O once
/// (default slice), and projects its `universalBinary` slice list into the pure model.
///
/// All decisions about whether a dialog is needed and which slice is the default live in
/// `LoaderOptionsModel`; this type only gathers the inputs. Non-Mach-O or unreadable
/// files yield a thin model (no slices) rather than throwing — the open flow then skips
/// straight to the load and lets the real loader surface any error.
struct LoaderOptionsInspector: Sendable {
    typealias CancellationCheck = @Sendable () -> Bool
    typealias InspectionOperation = @Sendable (URL, CancellationCheck) -> LoaderOptionsModel

    private let operation: InspectionOperation

    init(importer: MachOImportService = MachOImportService(), parser: MachOParser = MachOParser()) {
        self.operation = { url, shouldCancel in
            Self.inspectSynchronously(
                url: url,
                importer: importer,
                parser: parser,
                shouldCancel: shouldCancel
            )
        }
    }

    /// Test seam for proving executor and publication behavior without reading a real archive.
    /// Product construction always uses the importer/parser initializer above.
    init(operation: @escaping InspectionOperation) {
        self.operation = operation
    }

    func inspect(url: URL) -> LoaderOptionsModel {
        operation(url, { false })
    }

    /// Performs bounded file inspection away from the main actor. Cancellation propagates to the
    /// detached worker and into the archive parser's existing cooperative checkpoints. The caller
    /// still owns publication fencing because cancellation can race a completed inspection.
    func inspectOffMain(url: URL) async throws -> LoaderOptionsModel {
        let operation = self.operation
        let worker = Task.detached(priority: .userInitiated) {
            operation(url, { Task.isCancelled })
        }
        let model = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return model
    }

    private static func inspectSynchronously(
        url: URL,
        importer: MachOImportService,
        parser: MachOParser,
        shouldCancel: CancellationCheck
    ) -> LoaderOptionsModel {
        let fileName = url.lastPathComponent

        // Resolve `.app` bundles to their executable; fall back to the URL itself.
        let executableURL = (try? importer.resolveExecutable(at: url))?.executableURL ?? url

        // Do not map an oversized archive merely to populate a picker. The authoritative loader
        // will surface its typed bound failure when the user opens it.
        if let handle = try? FileHandle(forReadingFrom: executableURL) {
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: 8)) ?? Data()
            if ELFArchiveParser.isArchiveContainer(prefix),
               let size = try? executableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > ELFArchiveParserLimits.product.maximumArchiveBytes {
                return LoaderOptionsModel(
                    fileName: fileName,
                    formatDescription: "Unix archive",
                    slices: []
                )
            }
        }

        guard !shouldCancel(),
              let bytes = try? Data(contentsOf: executableURL, options: [.mappedIfSafe]),
              !bytes.isEmpty else {
            // Non-Mach-O (ELF/PE) or unreadable: present as a thin file with no slices so
            // the open flow proceeds straight to the loader.
            return LoaderOptionsModel(
                fileName: fileName,
                formatDescription: "Binary",
                slices: []
            )
        }


        if DyldSharedCacheParser.isDyldSharedCache(bytes) {
            // Header + image table only; no image is projected and no sibling sub-cache is opened
            // here. The loader re-admits the cache and its siblings when the user opens an image.
            guard !shouldCancel(), let header = try? DyldSharedCacheParser().parseHeader(bytes) else {
                return LoaderOptionsModel(fileName: fileName, formatDescription: "dyld shared cache", slices: [])
            }
            let images = LoaderCacheImageOption.pickerOptions(from: header.images)
            return LoaderOptionsModel(
                fileName: fileName,
                formatDescription: "dyld shared cache (\(header.architecture)) — "
                    + "\(images.count) image\(images.count == 1 ? "" : "s")",
                slices: [],
                cacheImages: images
            )
        }

        if ELFArchiveParser.isArchiveContainer(bytes) {
            guard let catalog = try? ELFArchiveParser.parse(bytes, shouldCancel: shouldCancel),
                  !shouldCancel(),
                  !catalog.elfMembers.isEmpty else {
                return LoaderOptionsModel(
                    fileName: fileName,
                    formatDescription: "Unix archive",
                    slices: []
                )
            }
            let members = catalog.elfMembers.map {
                ELFArchiveMemberSummary(
                    containerIdentity: catalog.containerIdentity,
                    identity: $0.identity
                )
            }
            return LoaderOptionsModel(
                fileName: fileName,
                formatDescription: "Unix archive — \(members.count) ELF member\(members.count == 1 ? "" : "s")",
                slices: [],
                archiveMembers: members
            )
        }

        guard !shouldCancel(), let machO = try? parser.parse(bytes) else {
            return LoaderOptionsModel(
                fileName: fileName,
                formatDescription: "Binary",
                slices: []
            )
        }

        guard let universalBinary = machO.universalBinary, !universalBinary.slices.isEmpty else {
            // Thin single-arch Mach-O.
            return LoaderOptionsModel(
                fileName: fileName,
                formatDescription: "\(machO.fileTypeName), \(machO.architectureName)",
                slices: []
            )
        }

        let options = universalBinary.slices.map(LoaderSliceOption.init(slice:))
        return LoaderOptionsModel(
            fileName: fileName,
            formatDescription: "Universal \(machO.fileTypeName) — \(universalBinary.slices.count) slices",
            slices: options,
            defaultSelectedIndex: universalBinary.selectedSliceIndex
        )
    }
}
