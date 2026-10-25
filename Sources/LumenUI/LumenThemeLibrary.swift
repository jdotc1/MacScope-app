import CoreTransferable
import Foundation
import LumenTokens
import UniformTypeIdentifiers

// The user theme library: loading with per-file problems, import, export, removal, saving, and
// live reload when the themes folder changes. Theme files are plain `LumenTheme` JSON (the schema
// `LumenExport.themeSchemaJSON` publishes).

/// A theme file that could not be loaded, and why, in words a theme author can act on.
public struct LumenThemeFileProblem: Hashable, Sendable, Identifiable {
    public let file: String
    public let reason: String
    public var id: String { file + reason }

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// The result of reading a themes folder.
public struct LumenUserThemeLibrary: Sendable {
    /// Loaded themes, flattened (inheritance merged in), in file-name order.
    public var themes: [LumenTheme] = []
    /// The file each loaded theme came from.
    public var files: [String: URL] = [:]
    public var problems: [LumenThemeFileProblem] = []
    /// Every id a file in the folder declares, loaded or not: a file that fails to load still owns
    /// its id, so a new theme mustn't take it.
    public var reservedIDs: Set<String> = []

    public init() {}
}

public enum LumenThemeImportError: LocalizedError, Equatable {
    case unreadable(String)
    case newerSchema(Int)
    case inheritance(String)
    case builtIn
    /// The file was written but the theme didn't load (the reason is the folder's problem for it).
    case didNotLoad(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "This file isn’t a theme: \(reason)"
        case .newerSchema(let version): "This theme needs a newer version of the app (theme format \(version))."
        case .inheritance(let reason): "This theme can’t be loaded: it \(reason)."
        case .builtIn: "Built-in themes can’t be removed."
        case .didNotLoad(let reason): "The theme was saved but can’t be loaded: \(reason)."
        }
    }
}

/// Reading, writing and checking theme files. Pure functions of their inputs; the store's
/// library methods build on them.
public enum LumenThemeLibrary {
    /// Theme files are a few KB; anything far larger is not a theme and is not read.
    public static let maximumThemeFileSize = 512 * 1024

    /// Why `url` is not read at all, or `nil` when it may be: links are refused (a theme file is
    /// a plain file the user owns), and so is a file whose size can't be read or is too large.
    public static func refusal(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else {
            return "the file can’t be read"
        }
        if values.isSymbolicLink == true { return "the file is a symbolic link; copy the theme into the folder instead" }
        guard values.isRegularFile == true, let size = values.fileSize else { return "the file can’t be read" }
        if size > maximumThemeFileSize {
            return "the file is larger than \(maximumThemeFileSize / 1024) KB; a theme is a few KB of colors"
        }
        return nil
    }

    /// Decodes every `*.json` theme in `directory` and resolves `inherits`. A file is skipped,
    /// logged and reported when it fails to decode, uses a newer schema, reuses a built-in or
    /// already-loaded id, or has a missing parent or an inheritance cycle.
    public static func load(from directory: URL, registry: LumenRegistry) -> LumenUserThemeLibrary {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return LumenUserThemeLibrary() }
        var problems: [LumenThemeFileProblem] = []
        func skip(_ url: URL, _ reason: String) {
            LumenThemeStore.log.error("Skipping theme \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            problems.append(LumenThemeFileProblem(file: url.lastPathComponent, reason: reason))
        }
        // Every built-in id is reserved, including themes a pack hides from the gallery.
        let builtInIDs = Set(registry.builtInThemes.map(\.id))
        var seenIDs = builtInIDs
        var decoded: [(LumenTheme, URL?)] = []
        for url in urls.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let refusal = refusal(for: url) {
                skip(url, refusal)
                continue
            }
            do {
                let theme = registry.migratingRenamedKeys(in: try decodeTheme(Data(contentsOf: url)))
                guard seenIDs.insert(theme.id).inserted else {
                    skip(url, builtInIDs.contains(theme.id)
                         ? "the id \(theme.id) belongs to a built-in theme"
                         : "another theme file already uses the id \(theme.id)")
                    continue
                }
                decoded.append((theme, url))
            } catch let error as LumenThemeImportError {
                skip(url, error.errorDescription ?? "\(error)")
            } catch {
                skip(url, error.localizedDescription)
            }
        }
        var library = resolvingInheritance(decoded, registry: registry)
        library.problems = problems + library.problems
        library.reservedIDs = seenIDs.subtracting(builtInIDs)
        return library
    }

    /// Merges each theme's `inherits` chain; parents may be any built-in (hidden ones too) or
    /// other themes in the list. A theme with a missing parent or a cycle is reported rather
    /// than loaded half resolved.
    public static func resolvingInheritance(_ themes: [(LumenTheme, URL?)], registry: LumenRegistry) -> LumenUserThemeLibrary {
        var byID: [String: LumenTheme] = [:]
        for theme in registry.builtInThemes + themes.map(\.0) where byID[theme.id] == nil {
            byID[theme.id] = theme
        }
        var library = LumenUserThemeLibrary()
        for (theme, url) in themes {
            do {
                library.themes.append(try theme.flattened { byID[$0] })
                if let url { library.files[theme.id] = url }
            } catch {
                let name = url?.lastPathComponent ?? theme.id
                LumenThemeStore.log.error("Skipping theme \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                library.problems.append(LumenThemeFileProblem(file: name, reason: "it \(error)"))
            }
        }
        return library
    }

    /// Decodes one theme file and checks its schema version.
    public static func decodeTheme(_ data: Data) throws -> LumenTheme {
        let theme: LumenTheme
        do {
            theme = try JSONDecoder().decode(LumenTheme.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw LumenThemeImportError.unreadable("“\(key.stringValue)” is missing")
        } catch let DecodingError.dataCorrupted(context) {
            throw LumenThemeImportError.unreadable(context.debugDescription)
        } catch let DecodingError.typeMismatch(_, context) {
            throw LumenThemeImportError.unreadable("unexpected value at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw LumenThemeImportError.unreadable(error.localizedDescription)
        }
        guard theme.schemaVersion <= LumenTheme.currentSchemaVersion else {
            throw LumenThemeImportError.newerSchema(theme.schemaVersion)
        }
        return theme
    }

    public static func encodeTheme(_ theme: LumenTheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(theme)
    }

    /// A file name for a theme id: letters, digits, dots and hyphens kept, anything else a hyphen,
    /// and no leading dot (the folder skips hidden files, so the theme would never load).
    public static func fileSlug(_ id: String) -> String {
        let slug = String(String(id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }).drop { $0 == "." })
        return slug.isEmpty ? "theme" : slug
    }

    /// Name, size and modification date of every theme file in `directory`. The folder watch
    /// reloads only when this changes, so Finder's `.DS_Store` and other files don't.
    public static func folderFingerprint(_ directory: URL) -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return "\(url.lastPathComponent)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        }.sorted()
    }

    /// The id an imported theme takes: a built-in's id (an exported built-in coming back) moves
    /// out of the reserved namespace to `user.<last component>`, so it becomes the user's own.
    public static func importedID(for id: String, registry: LumenRegistry) -> String {
        guard registry.theme(id: id) != nil else { return id }
        return "user." + (id.split(separator: ".").last.map(String.init) ?? id)
    }

    // MARK: Editor

    /// What the editor shows while editing: `base` (already flattened by the store) with the
    /// overrides on top. Normal-color overrides sit above the base's contrast overlays too,
    /// exactly as a saved child resolves inheritance.
    public static func editorPreview(name: String, inheriting base: LumenTheme,
                                     overrides: [Bool: [LumenToken: LumenColor]]) -> LumenTheme {
        var theme = base
        theme.id = "user.draft"
        theme.name = name
        theme.inherits = nil
        for (dark, colors) in overrides where !colors.isEmpty {
            let layer = palette(colors)
            if dark {
                theme.dark = (theme.dark ?? LumenPalette()).merging(layer)
                theme.darkHighContrast = theme.darkHighContrast?.merging(layer)
            } else {
                theme.light = (theme.light ?? LumenPalette()).merging(layer)
                theme.lightHighContrast = theme.lightHighContrast?.merging(layer)
            }
        }
        return theme
    }

    /// The theme file the editor saves: `inherits` = `base`, holding only the overrides, with an
    /// id that does not collide with `existingIDs`.
    public static func partialTheme(name: String, inheriting base: LumenTheme, overrides: [Bool: [LumenToken: LumenColor]],
                                    existingIDs: Set<String>) -> LumenTheme {
        func variant(_ dark: Bool) -> LumenPalette? {
            guard let colors = overrides[dark], !colors.isEmpty else { return nil }
            return palette(colors)
        }
        let slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        var id = "user.\(slug)"
        var suffix = 2
        while existingIDs.contains(id) { id = "user.\(slug)-\(suffix)"; suffix += 1 }
        return LumenTheme(id: id, name: name, summary: "Based on \(base.name).", colorSpace: base.colorSpace,
                          inherits: base.id, light: variant(false), dark: variant(true))
    }

    private static func palette(_ colors: [LumenToken: LumenColor]) -> LumenPalette {
        LumenPalette(colors: Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value) }))
    }
}

// MARK: Store operations

extension LumenThemeStore {
    /// Copies a theme file into the themes folder, loads it and selects it for the window. An id
    /// that is already taken gets a numeric suffix, so importing never replaces an existing theme.
    @discardableResult
    public func importTheme(from source: URL) throws -> LumenTheme {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if let refusal = LumenThemeLibrary.refusal(for: source) {
            throw LumenThemeImportError.unreadable(refusal)
        }
        var theme = registry.migratingRenamedKeys(in: try LumenThemeLibrary.decodeTheme(Data(contentsOf: source)))
        theme.id = LumenThemeLibrary.importedID(for: theme.id, registry: registry)
        let current = themes
        let taken = takenThemeIDs
        if taken.contains(theme.id) {
            var suffix = 2
            while taken.contains("\(theme.id)-\(suffix)") { suffix += 1 }
            theme.id = "\(theme.id)-\(suffix)"
            theme.name = "\(theme.name) \(suffix)"
        }
        do {
            _ = try theme.flattened { id in registry.theme(id: id) ?? current.first { $0.id == id } }
        } catch {
            throw LumenThemeImportError.inheritance("\(error)")
        }
        let url = try writeNewTheme(theme)
        try loadWrittenTheme(theme.id, from: url)
        return theme
    }

    /// Every id a new theme mustn't take: loaded themes, built-ins (hidden ones too), and ids
    /// declared by files in the folder that didn't load.
    var takenThemeIDs: Set<String> {
        Set(themes.map(\.id)).union(registry.builtInThemes.map(\.id)).union(state.withLock { $0.reservedIDs })
    }

    /// Reloads after writing `url` and selects `id`, or reports why the new theme didn't load.
    private func loadWrittenTheme(_ id: LumenTheme.ID, from url: URL) throws {
        reloadUserThemes()
        watchThemesDirectory()
        guard themes.contains(where: { $0.id == id }) else {
            let reason = themeFileProblems.first { $0.file == url.lastPathComponent }?.reason ?? "the folder didn’t load it"
            throw LumenThemeImportError.didNotLoad(reason)
        }
        select(id)
    }

    /// Moves a user theme's file to the Trash (recoverable from Finder) and reloads. Themes that
    /// inherit from it then fail to load and show up in `themeFileProblems`. Tests pass a
    /// `remove` that deletes a temporary file instead.
    public func moveUserThemeToTrash(
        _ id: LumenTheme.ID,
        remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        guard let url = userThemeFile(for: id) else { throw LumenThemeImportError.builtIn }
        try remove(url)
        reloadUserThemes()
    }

    /// Renames a user theme: its file keeps its place and id, only the display name changes.
    public func renameUserTheme(_ id: LumenTheme.ID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LumenThemeImportError.unreadable("a theme needs a name") }
        try rewriteUserTheme(id) { $0.name = trimmed }
    }

    /// Saves `overrides` into a user theme's own file (editing in place) rather than as a new theme.
    /// The file keeps its id, name, parent and any colors the overrides don't touch.
    public func updateUserTheme(_ id: LumenTheme.ID, overrides: [Bool: [LumenToken: LumenColor]]) throws {
        try rewriteUserTheme(id) { theme in
            for (dark, colors) in overrides where !colors.isEmpty {
                var palette = (dark ? theme.dark : theme.light) ?? LumenPalette()
                for (token, color) in colors { palette[token] = color }
                if dark { theme.dark = palette } else { theme.light = palette }
            }
        }
    }

    /// Reads a user theme's file as written (inheritance not merged), changes it, checks it still
    /// loads, and writes it back atomically.
    private func rewriteUserTheme(_ id: LumenTheme.ID, _ change: (inout LumenTheme) -> Void) throws {
        guard let url = userThemeFile(for: id) else { throw LumenThemeImportError.builtIn }
        var theme = try LumenThemeLibrary.decodeTheme(Data(contentsOf: url))
        change(&theme)
        do {
            _ = try theme.flattened { parent in registry.theme(id: parent) ?? themes.first { $0.id == parent } }
        } catch {
            throw LumenThemeImportError.inheritance("\(error)")
        }
        try LumenThemeLibrary.encodeTheme(theme).write(to: url, options: .atomic)
        reloadUserThemes()
    }

    /// Moves a theme file that failed to load (see `themeFileProblems`) to the Trash and reloads.
    public func moveProblemFileToTrash(
        _ problem: LumenThemeFileProblem,
        remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        let url = themesDirectory.appending(path: problem.file)
        // Only a file directly in the themes folder, named as the problem names it.
        guard url.deletingLastPathComponent().standardizedFileURL == themesDirectory.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw LumenThemeImportError.unreadable("\(problem.file) isn’t in the themes folder")
        }
        try remove(url)
        reloadUserThemes()
    }

    /// Writes an editable copy of `theme` into the themes folder, loads it and selects it.
    /// Returns the new file's URL so the caller can reveal it.
    @discardableResult
    public func duplicate(_ theme: LumenTheme) throws -> URL {
        let existingIDs = takenThemeIDs
        var index = 1
        var candidate: String { "user.\(theme.id.split(separator: ".").last ?? "theme").copy\(index)" }
        while existingIDs.contains(candidate) { index += 1 }
        var copy = theme
        copy.id = candidate
        copy.name = "\(theme.name) Copy\(index > 1 ? " \(index)" : "")"
        copy.summary = "Your copy of \(theme.name). Edit the JSON, then choose Reload Themes."
        let url = try writeNewTheme(copy)
        try loadWrittenTheme(copy.id, from: url)
        return url
    }

    /// Saves `overrides` on `base` as a new theme, reloads and selects it, and returns the file URL.
    /// On a built-in, the file holds only the overrides (`inherits` = `base`). On a user theme it
    /// holds every color: customizing a customization doesn't stack inheritance (which has a depth
    /// limit) or depend on the earlier file staying put. Existing files are never replaced.
    @discardableResult
    public func saveUserTheme(name: String, inheriting base: LumenTheme, overrides: [Bool: [LumenToken: LumenColor]]) throws -> URL {
        let taken = takenThemeIDs
        var theme = LumenThemeLibrary.partialTheme(name: name, inheriting: base, overrides: overrides, existingIDs: taken)
        if userThemeFile(for: base.id) != nil {
            var complete = LumenThemeLibrary.editorPreview(name: name, inheriting: base, overrides: overrides)
            complete.id = theme.id
            complete.summary = theme.summary
            theme = complete
        }
        do {
            _ = try theme.flattened { id in registry.theme(id: id) ?? themes.first { $0.id == id } }
        } catch {
            throw LumenThemeImportError.inheritance("\(error)")
        }
        let url = try writeNewTheme(theme)
        try loadWrittenTheme(theme.id, from: url)
        return url
    }

    /// Publishes complete bytes without replacing any directory entry. Loaded theme ids do not
    /// reserve file names: a skipped file or a file with a different id still belongs to its
    /// author. A same-directory hard link gives the final name an atomic, exclusive creation,
    /// including when another writer wins the name or a dangling symlink already occupies it.
    @discardableResult
    public func writeNewTheme(_ theme: LumenTheme) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        let temporary = themesDirectory.appending(path: ".\(UUID().uuidString).theme")
        try LumenThemeLibrary.encodeTheme(theme).write(to: temporary, options: .withoutOverwriting)
        defer { try? manager.removeItem(at: temporary) }
        let slug = LumenThemeLibrary.fileSlug(theme.id)
        for attempt in 1...10_000 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let destination = themesDirectory.appending(path: "\(slug)\(suffix).json")
            do {
                try manager.linkItem(at: temporary, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: themesDirectory.path])
    }

    // MARK: Live reload

    /// Watches `themesDirectory` and reloads shortly after a theme file is added, removed or
    /// saved, whether the editor replaces the file or writes it in place. Does nothing until the
    /// folder exists; saving, duplicating or importing a theme starts it.
    public func watchThemesDirectory() {
        directoryWatch.withLock { watch in
            guard watch == nil else { return }
            let fingerprint = LumenThemeLibrary.folderFingerprint(themesDirectory)
            lastFolderFingerprint.withLock { $0 = fingerprint }
            watch = LumenThemeDirectoryWatch(directory: themesDirectory) { [weak self] in
                self?.directoryWatchFired()
            }
        }
    }

    private func directoryWatchFired() {
        // The watch follows the folder it opened, not the path. When that folder was deleted or
        // moved, watch the one at the path now (replaced in one step, by a sync tool or a
        // restore); with none there, stop, and start again on the next save. The fingerprint check
        // below picks up what the new folder already holds.
        directoryWatch.withLock { watch in
            guard let current = watch, !current.watchesCurrentDirectory else { return }
            watch = LumenThemeDirectoryWatch(directory: themesDirectory) { [weak self] in
                self?.directoryWatchFired()
            }
        }
        // Finder's .DS_Store and other non-theme files change the folder too; reload only when
        // a theme file was added, removed or rewritten.
        let fingerprint = LumenThemeLibrary.folderFingerprint(themesDirectory)
        guard lastFolderFingerprint.withLock({ previous in
            defer { previous = fingerprint }
            return previous != fingerprint
        }) else { return }
        reloadUserThemes()
    }
}

/// A file-system watch on one folder and the theme files in it, debounced so a burst of writes
/// reloads once. Cancelled on release.
public final class LumenThemeDirectoryWatch: Sendable {
    private let source: any DispatchSourceFileSystemObject
    /// Bumped on every event; a scheduled callback fires only if no later event superseded it.
    private let generation = LumenLock(0)
    private let fileSources = LumenLock<[any DispatchSourceFileSystemObject]>([])
    private let directory: URL
    /// The opened folder's device and inode, to tell it from another folder at the same path.
    private let device: dev_t
    private let inode: ino_t
    private let debounce: DispatchTimeInterval
    private let onChange: @Sendable () -> Void

    /// `nil` when the folder can't be opened (it doesn't exist yet).
    public init?(directory: URL, debounce: DispatchTimeInterval = .milliseconds(250), onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            close(descriptor)
            return nil
        }
        self.directory = directory
        device = metadata.st_dev
        inode = metadata.st_ino
        self.debounce = debounce
        self.onChange = onChange
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            // Atomic saves replace the file's vnode. Reopen the current files before notifying
            // the store, so their next in-place edit is still watched.
            self?.refreshFileWatches()
            self?.scheduleChange()
        }
        source.setCancelHandler { close(descriptor) }
        refreshFileWatches()
        source.resume()
    }

    /// Whether the folder at `directory` is still the one this watch opened: false once it was
    /// deleted, moved away or replaced by another folder at the same path.
    public var watchesCurrentDirectory: Bool {
        var metadata = stat()
        guard stat(directory.path(percentEncoded: false), &metadata) == 0 else { return false }
        return metadata.st_dev == device && metadata.st_ino == inode
    }

    private func refreshFileWatches() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        fileSources.withLock { sources in
            for source in sources { source.cancel() }
            sources.removeAll()
            for url in urls where url.pathExtension.lowercased() == "json" {
                // Match the loader's ordinary-file boundary: never follow a link or keep a
                // descriptor open on a directory or special file.
                let descriptor = open(url.path(percentEncoded: false), O_EVTONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { continue }
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                    close(descriptor)
                    continue
                }
                let fileSource = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .main
                )
                fileSource.setEventHandler { [weak self] in self?.scheduleChange() }
                fileSource.setCancelHandler { close(descriptor) }
                fileSource.resume()
                sources.append(fileSource)
            }
        }
    }

    private func scheduleChange() {
        let mine = generation.withLock { value -> Int in
            value += 1
            return value
        }
        let generation = generation, onChange = onChange
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) {
            if generation.withLock({ $0 }) == mine { onChange() }
        }
    }

    deinit {
        generation.withLock { $0 += 1 }   // drop a callback still waiting out the debounce
        source.cancel()
        fileSources.withLock { sources in
            for source in sources { source.cancel() }
        }
    }
}

/// A theme as a shareable file. With its inheritance merged in (`isSelfContained`), it loads on a
/// Mac (or in an app) that lacks the parent theme; `selfContained(_:lookup:)` guarantees that or
/// throws.
public struct LumenThemeFile: Transferable, Sendable {
    public let theme: LumenTheme

    /// Merges in the theme's parents where it can. When a parent can't be found, the file keeps its
    /// `inherits` link and `isSelfContained` is false: it loads only where that parent exists.
    ///
    /// - Parameter lookup: finds parent themes by id (built-ins and user themes); by default, the
    ///   active store's registry and themes.
    public init(_ theme: LumenTheme, lookup: (String) -> LumenTheme? = LumenThemeFile.activeStoreLookup) {
        self.theme = (try? theme.flattened(lookup: lookup)) ?? theme
    }

    private init(flattened theme: LumenTheme) {
        self.theme = theme
    }

    /// A file that loads anywhere, or `LumenThemeImportError.inheritance` when a parent can't be
    /// found (or the chain is too deep or circular).
    public static func selfContained(_ theme: LumenTheme,
                                     lookup: (String) -> LumenTheme? = LumenThemeFile.activeStoreLookup) throws -> LumenThemeFile {
        do {
            return LumenThemeFile(flattened: try theme.flattened(lookup: lookup))
        } catch {
            throw LumenThemeImportError.inheritance("\(error)")
        }
    }

    /// Whether every parent is merged in, so the file doesn't depend on another theme.
    public var isSelfContained: Bool { theme.inherits == nil }

    /// Finds a theme by id in the active store: its registry's themes (hidden ones too), then the
    /// themes it offers.
    public static func activeStoreLookup(_ id: String) -> LumenTheme? {
        let store = LumenThemeStore.active
        return store.registry.theme(id: id) ?? store.themes.first { $0.id == id }
    }

    public var fileName: String { "\(theme.name).json" }

    public func data() throws -> Data { try LumenThemeLibrary.encodeTheme(theme) }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { try $0.data() }
            .suggestedFileName { $0.fileName }
    }
}
