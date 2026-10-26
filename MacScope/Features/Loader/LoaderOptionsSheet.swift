import Foundation
import SwiftUI
import LumenUI

/// The open-time loader-options dialog. A thin shell over `LoaderOptionsModel`: for a
/// fat/universal binary it lists the slices and lets the user pick one; "Open" imports
/// the chosen slice. All selection/default logic lives in the model — this view only
/// renders rows and forwards the pick to the store.
struct LoaderOptionsSheet: View {
    let request: LoaderOptionsRequest
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    /// Local editable copy of the model so the picker can mutate the selection before the
    /// user confirms; the store's request is left untouched until "Open".
    @State private var model: LoaderOptionsModel
    /// The dyld cache image filter (install-name substring).
    @State private var cacheImageQuery = ""

    init(request: LoaderOptionsRequest, store: WorkspaceStore) {
        self.request = request
        self.store = store
        _model = State(initialValue: request.model)
    }

    var body: some View {
        LumenSheet(
            "Open \(model.fileName)",
            subtitle: model.formatDescription,
            systemImage: "cpu",
            hue: .huePink,
            cancelAccessibilityIdentifier: "loader.options.cancel",
            onCancel: {
                store.cancelLoaderOptions()
                dismiss()
            },
            primary: LumenBarAction(
                "Open",
                isEnabled: model.canOpen,
                accessibilityIdentifier: "loader.options.open",
                perform: open
            )
        ) {
            VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                // A container-level identifier is propagated onto descendants by the installed
                // SwiftUI bridge, overwriting the list and button identities. Keep the
                // sheet-presence sentinel on this stable leaf instead.
                Text(model.isUniversal ? "Choose an architecture slice to disassemble:"
                     : model.isELFArchive ? "Choose an ELF archive member to disassemble:"
                     : model.isDyldSharedCache ? "Choose a cache image to disassemble:"
                     : "Open with the default loader options.")
                    .font(.callout)
                    .accessibilityIdentifier("loader.options.sheet")

                if model.isUniversal {
                    LumenSourceList(model.slices.map { slice in
                        LumenSourceListItem(id: String(slice.index), title: slice.architectureName,
                                            detail: "offset \(slice.offsetHexString) · \(slice.sizeDescription)",
                                            systemImage: "cpu")
                    }, selection: sliceItemSelection)
                    .frame(height: AppLayout.loaderArchitectureListHeight)
                    .accessibilityLabel("Architecture slices")
                } else if model.isELFArchive {
                    List(model.archiveMembers, selection: archiveSelectionBinding) { member in
                        LoaderArchiveMemberRow(
                            member: member,
                            isSelected: model.selectedArchiveMemberIndex == member.index
                        )
                        .tag(member.index)
                        .listRowInsets(EdgeInsets(
                            top: Lumen.Space.s2,
                            leading: Lumen.Space.s4,
                            bottom: Lumen.Space.s2,
                            trailing: Lumen.Space.s4
                        ))
                    }
                    .frame(height: AppLayout.loaderArchiveListHeight)
                    .accessibilityLabel("ELF archive members")
                    .accessibilityIdentifier("loader.archive.members")
                } else if model.isDyldSharedCache {
                    LoaderCacheImagePicker(model: $model, query: $cacheImageQuery)
                }
            }
        }
        .frame(width: model.isDyldSharedCache ? AppLayout.loaderCacheSheetWidth : AppLayout.loaderOptionsSheetWidth)
    }

    /// The selected slice as the source list's string id.
    private var sliceItemSelection: Binding<String?> {
        Binding(
            get: { model.selectedSliceIndex.map(String.init) },
            set: { newValue in
                if let index = newValue.flatMap(Int.init) { model.select(index: index) }
            }
        )
    }

    private var archiveSelectionBinding: Binding<Int?> {
        Binding(
            get: { model.selectedArchiveMemberIndex },
            set: { newValue in
                if let newValue { model.selectArchiveMember(index: newValue) }
            }
        )
    }

    private func open() {
        // Re-pack the user's edited selection into the request the store imports.
        var confirmed = request
        confirmed.model = model
        store.confirmLoaderOptions(confirmed)
        dismiss()
    }
}

private struct LoaderArchiveMemberRow: View {
    let member: ELFArchiveMemberSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Lumen.Space.s5) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                Text(member.name).font(.body.weight(.medium))
                Text("member \(member.index) · \(memberSizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.name), archive member \(member.index)")
        .accessibilityIdentifier("loader.archive.member.\(member.index)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var memberSizeDescription: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(member.byteCount),
            countStyle: .file
        )
    }
}

/// The dyld shared cache image list: a filter field over a Lumen source list of install names
/// (file name as the title, its directory as the detail), sorted by `LoaderCacheImageOption`.
struct LoaderCacheImagePicker: View {
    @Binding var model: LoaderOptionsModel
    @Binding var query: String

    var body: some View {
        let visible = LoaderCacheImageOption.filter(model.cacheImages, query: query)
        VStack(alignment: .leading, spacing: Lumen.Space.s3) {
            LumenTextField("Filter by install name", text: $query, monospaced: true)
                .accessibilityLabel("Filter cache images")
                .accessibilityIdentifier("loader.cache.filter")
            LumenSourceList(visible.map { image in
                LumenSourceListItem(id: image.installName, title: image.fileName,
                                    detail: image.directory, systemImage: "shippingbox")
            }, selection: selection)
            .frame(height: AppLayout.loaderCacheImageListHeight)
            .accessibilityLabel("Cache images")
            .accessibilityIdentifier("loader.cache.images")
            Text(countLine(visible: visible.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("loader.cache.count")
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedCacheImagePath },
            set: { newValue in
                if let newValue { model.selectCacheImage(installName: newValue) }
            }
        )
    }

    private func countLine(visible: Int) -> String {
        let total = model.cacheImages.count
        let shown = visible == total ? "\(total) images" : "\(visible) of \(total) images"
        guard let selected = model.selectedCacheImage else { return shown }
        return "\(shown) · selected \(selected.installName)"
    }
}
