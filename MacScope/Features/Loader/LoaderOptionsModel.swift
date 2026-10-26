import Foundation

/// One selectable architecture slice shown in the open-time loader-options dialog.
/// A thin projection of `MachOUniversalSlice` carrying only what the (thin) SwiftUI
/// sheet renders, plus the `index` the loader needs to actually load it.
struct LoaderSliceOption: Identifiable, Hashable, Sendable {
    /// The fat-table slice index — also the value handed back to the loader.
    var index: Int
    var architectureName: String
    var offset: UInt64
    var size: UInt64

    var id: Int { index }

    var offsetHexString: String {
        "0x\(String(offset, radix: 16))"
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(min(size, UInt64(Int64.max))), countStyle: .file)
    }

    init(index: Int, architectureName: String, offset: UInt64, size: UInt64) {
        self.index = index
        self.architectureName = architectureName
        self.offset = offset
        self.size = size
    }

    init(slice: MachOUniversalSlice) {
        self.init(
            index: slice.index,
            architectureName: slice.architectureName,
            offset: slice.offset,
            size: slice.size
        )
    }
}

/// One image of a dyld shared cache, listed by install name in the open-time picker.
struct LoaderCacheImageOption: Identifiable, Hashable, Sendable {
    /// The image's install name; also the selector handed to `DyldSharedCacheBinaryLoader`.
    var installName: String
    /// The image's mach_header VM address in the cache.
    var address: UInt64

    var id: String { installName }
    var fileName: String { (installName as NSString).lastPathComponent }
    var directory: String { (installName as NSString).deletingLastPathComponent }
    var addressHexString: String { "0x\(String(address, radix: 16))" }

    /// The picker's list: named images only (an unnamed image has no selector the loader can
    /// find again, MS-16), one row per install name, sorted case-insensitively by install name.
    static func pickerOptions(from images: [DyldCacheImage]) -> [LoaderCacheImageOption] {
        var seen = Set<String>()
        return images
            .filter { !$0.path.isEmpty && BinaryLoadSelection.isWellFormedDyldCacheImagePath($0.path) }
            .filter { seen.insert($0.path).inserted }
            .map { LoaderCacheImageOption(installName: $0.path, address: $0.address) }
            .sorted {
                let order = $0.installName.localizedCaseInsensitiveCompare($1.installName)
                return order == .orderedSame ? $0.installName < $1.installName : order == .orderedAscending
            }
    }

    /// Case-insensitive substring match on the install name; an empty query matches everything.
    static func filter(_ options: [LoaderCacheImageOption], query: String) -> [LoaderCacheImageOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return options }
        return options.filter { $0.installName.localizedCaseInsensitiveContains(needle) }
    }
}

/// The pure, headless-testable model behind the open-time loader-options dialog.
///
/// Built from what the loader detected about a candidate file (its format/arch and,
/// for a fat/universal Mach-O, the list of slices). It answers two questions the
/// open flow needs:
///   1. `requiresChoice` — does opening this file need the dialog at all? (Only a fat
///      binary with more than one slice forces a pick; a thin or single-slice binary
///      can be opened straight through.)
///   2. `selectedSliceIndex` — which slice will be loaded, defaulting to the same rule
///      the loader uses (`MachOSliceSelector`: host arm64 → x86_64 → first) and
///      mutable as the user moves the selection.
///
/// The SwiftUI sheet is a thin shell over this; all validation/selection logic lives
/// here so it can be tested without a UI.
struct LoaderOptionsModel: Equatable, Sendable {
    /// The file the dialog is opening (used for the title; never re-read here).
    let fileName: String
    /// The detected format/architecture summary (e.g. "Mach-O executable, arm64" or the
    /// universal display name). Shown to confirm what the user is about to open.
    let formatDescription: String
    /// The fat/universal slices, in file order. Empty for a thin single-arch binary.
    let slices: [LoaderSliceOption]
    /// ELF object members in ordinary-member source order. Empty for non-archives. Unlike Mach-O
    /// slices, a multi-member archive intentionally begins with no selection.
    let archiveMembers: [ELFArchiveMemberSummary]
    /// A dyld shared cache's named images, sorted by install name. Empty for anything else.
    let cacheImages: [LoaderCacheImageOption]
    /// The currently selected slice index, or `nil` for a thin binary (nothing to pick).
    private(set) var selectedSliceIndex: Int?
    private(set) var selectedArchiveMemberIndex: Int?
    /// Like an archive, a cache with several images begins with no selection: no image is a
    /// better default than another, and the loader's first-image rule is what the picker replaces.
    private(set) var selectedCacheImagePath: String?

    init(
        fileName: String,
        formatDescription: String,
        slices: [LoaderSliceOption],
        archiveMembers: [ELFArchiveMemberSummary] = [],
        cacheImages: [LoaderCacheImageOption] = [],
        defaultSelectedIndex: Int? = nil
    ) {
        self.fileName = fileName
        self.formatDescription = formatDescription
        self.slices = slices
        self.archiveMembers = archiveMembers
        self.cacheImages = cacheImages
        self.selectedCacheImagePath = cacheImages.count == 1 ? cacheImages[0].installName : nil
        if slices.isEmpty {
            self.selectedSliceIndex = nil
        } else if let defaultSelectedIndex, slices.contains(where: { $0.index == defaultSelectedIndex }) {
            self.selectedSliceIndex = defaultSelectedIndex
        } else {
            // Default to the same rule the loader applies so the highlighted row matches
            // what "Open" loads if the user changes nothing.
            self.selectedSliceIndex = Self.defaultSliceIndex(for: slices)
        }
        self.selectedArchiveMemberIndex = archiveMembers.count == 1
            ? archiveMembers[0].index
            : nil
    }

    /// True when opening this file genuinely needs a slice choice: a fat/universal binary
    /// with at least two slices. A thin binary, or a fat binary with a single slice, can
    /// be opened straight through (the sheet may still be shown to confirm format/arch,
    /// but no real decision is required).
    var requiresChoice: Bool {
        slices.count > 1 || archiveMembers.count > 1 || cacheImages.count > 1
    }

    /// Whether the dialog is fat (has slices) at all.
    var isUniversal: Bool {
        !slices.isEmpty
    }

    var isELFArchive: Bool { !archiveMembers.isEmpty }

    var isDyldSharedCache: Bool { !cacheImages.isEmpty }

    var selectedCacheImage: LoaderCacheImageOption? {
        guard let selectedCacheImagePath else { return nil }
        return cacheImages.first { $0.installName == selectedCacheImagePath }
    }

    /// Whether "Open" has everything it needs: a container format with choices needs one.
    var canOpen: Bool {
        !((isUniversal && selectedSlice == nil)
            || (isELFArchive && selectedArchiveMember == nil)
            || (isDyldSharedCache && selectedCacheImage == nil))
    }

    /// The slice index to hand the loader when the user confirms. `nil` means "use the
    /// loader's own default" (thin binary, or a fat binary where the default rule still
    /// applies and we want to avoid pinning an explicit index unnecessarily).
    var requestedSliceIndexForLoad: Int? {
        selectedSliceIndex
    }

    var selectedArchiveMember: ELFArchiveMemberSummary? {
        guard let selectedArchiveMemberIndex else { return nil }
        return archiveMembers.first { $0.index == selectedArchiveMemberIndex }
    }

    var binaryLoadSelectionForLoad: BinaryLoadSelection {
        if let image = selectedCacheImage {
            return .dyldCacheImage(image.installName)
        }
        return BinaryLoadSelection(
            requestedMachOSliceIndex: selectedSliceIndex,
            elfArchiveMember: selectedArchiveMember.map {
                ELFArchiveMemberSelection(
                    container: $0.containerIdentity,
                    member: $0.identity
                )
            }
        )
    }

    /// The selected slice option, if any.
    var selectedSlice: LoaderSliceOption? {
        guard let selectedSliceIndex else { return nil }
        return slices.first { $0.index == selectedSliceIndex }
    }

    /// Moves the selection to `index` when it names a real slice; ignores out-of-range
    /// values so the model can never select a slice that doesn't exist.
    mutating func select(index: Int) {
        guard slices.contains(where: { $0.index == index }) else { return }
        selectedSliceIndex = index
    }

    mutating func selectArchiveMember(index: Int) {
        guard archiveMembers.contains(where: { $0.index == index }) else { return }
        selectedArchiveMemberIndex = index
    }

    /// Selects a listed cache image by install name; unknown names are ignored.
    mutating func selectCacheImage(installName: String) {
        guard cacheImages.contains(where: { $0.installName == installName }) else { return }
        selectedCacheImagePath = installName
    }

    /// The default-selected slice index for a slice list, mirroring the loader's rule
    /// (host arm64 → x86_64 → first). Returns the first slice's index if the selector
    /// rejects the list (which it won't for a non-empty list).
    static func defaultSliceIndex(for slices: [LoaderSliceOption]) -> Int? {
        guard !slices.isEmpty else { return nil }
        let universalSlices = slices.map { option in
            MachOUniversalSlice(
                index: option.index,
                cpuType: Self.cpuType(forArchitectureName: option.architectureName),
                cpuSubtype: 0,
                offset: option.offset,
                size: option.size,
                alignment: 0
            )
        }
        return (try? MachOSliceSelector.selectedIndex(in: universalSlices)) ?? slices[0].index
    }

    /// Maps a display architecture name back to a Mach-O CPU type so the default-slice
    /// rule (which keys on CPU type) works from the projected `LoaderSliceOption` list.
    /// Unknown names map to 0 so they never accidentally match arm64/x86_64.
    private static func cpuType(forArchitectureName name: String) -> Int32 {
        switch name {
        // arm64e shares the arm64 cpuType so it participates in the same default
        // preference bucket (otherwise it would project to 0 and never be preferred).
        case "arm64", "arm64e": return MachOConstants.cpuTypeARM64
        case let name where name.hasPrefix("arm64"): return MachOConstants.cpuTypeARM64
        case "x86_64", "x86_64h": return MachOConstants.cpuTypeX86_64
        default: return 0
        }
    }
}
