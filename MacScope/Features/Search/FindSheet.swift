import SwiftUI
import LumenUI

/// Binary `Find` (Cmd-F): searches the loaded snapshot by text, regular expression,
/// or hex byte pattern and lists navigable results. Mirrors `GoToAddressSheet`'s
/// shape and the inspector's navigable-row pattern; navigation reuses `goToAddress`.
struct FindSheet: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var model: RetainedFindModel
    @Environment(\.dismiss) private var dismiss

    /// Remembered Find filters (Nova-style): images, result kinds, system-image exclusion.
    @AppStorage("findSearchScope") private var scopeRaw = BinarySearchScope.everything.encoded

    private var scope: BinarySearchScope { BinarySearchScope(encoded: scopeRaw) }

    private func updateScope(_ change: (inout BinarySearchScope) -> Void) {
        var next = scope
        change(&next)
        scopeRaw = next.encoded
        let rerun = model.hasSearched
        bindModel()
        if rerun { runSearch() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Text("Find in Binary")
                .font(.title3.weight(.semibold))
                .lumenNeverTruncates("Find in Binary")

            Picker("Search mode", selection: $model.mode) {
                ForEach(BinarySearchMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            scopeControls

            TextField(model.mode.prompt, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .font(model.mode == .hex ? AppTypography.bytes : nil)
                .onSubmit(runSearch)

            statusLine

            if !model.results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        ForEach(model.results) { result in
                            FindResultRow(
                                result: result,
                                imageName: store.snapshot.binary(in: result.imageSlot)?.name
                            ) {
                                guard model.admits(result, workspaceOwner: ObjectIdentifier(store),
                                    workspaceID: store.workspaceID, documentID: store.documentID,
                                    snapshot: store.snapshot, revision: store.mutationGeneration.rawValue) else { return }
                                model.select(result)
                                model.seedCursor(in: store, selecting: ImageAddress(slot: result.imageSlot, address: result.address))
                                store.goToAddress(result.address, in: result.imageSlot)
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Find", action: runSearch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.isSearching)
            }
        }
        .padding(Lumen.Space.s8)
        .frame(width: 480)
        .onAppear { bindModel(); seedCurrentCursor() }
        .onChange(of: store.mutationGeneration) { _, _ in bindModel() }
        .onChange(of: store.focusedImageSlot) { _, _ in bindModel() }
        .onChange(of: store.snapshot.binaries.map(\.id)) { _, _ in bindModel() }
        .onChange(of: scopeRaw) { _, _ in bindModel() }
        .onChange(of: model.query) { _, _ in store.seedSearchCursor([]) }
        .onChange(of: model.mode) { _, _ in store.seedSearchCursor([]) }
        .onChange(of: model.publicationID) { _, _ in seedCurrentCursor() }
    }

    private var scopeControls: some View {
        HStack(spacing: Lumen.Space.s5) {
            if store.snapshot.binaries.count > 1 {
                Picker("Search in", selection: Binding(
                    get: { scope.images },
                    set: { value in updateScope { $0.images = value } }
                )) {
                    Text("All Images").tag(BinarySearchScope.Images.all)
                    Text("Focused Image").tag(BinarySearchScope.Images.focused)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("find.scope.images")
            }
            Menu {
                ForEach(BinarySearchResult.Kind.allCases, id: \.self) { kind in
                    Toggle(Self.label(for: kind), isOn: Binding(
                        get: { scope.kinds.contains(kind) },
                        set: { isOn in
                            updateScope { scope in
                                if isOn {
                                    scope.kinds.insert(kind)
                                } else if scope.kinds.count > 1 {
                                    scope.kinds.remove(kind)
                                }
                            }
                        }
                    ))
                }
                Divider()
                Toggle("Exclude System Images", isOn: Binding(
                    get: { scope.excludesSystemImages },
                    set: { value in updateScope { $0.excludesSystemImages = value } }
                ))
                Divider()
                Button("Reset Filters") { updateScope { $0 = .everything } }
                    .disabled(scope == .everything)
            } label: {
                Label(filterSummary, systemImage: scope == .everything
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .fixedSize()
            .accessibilityIdentifier("find.scope.filters")
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private var filterSummary: String {
        let all = BinarySearchResult.Kind.allCases.count
        var parts: [String] = []
        if scope.kinds.count < all {
            parts.append(BinarySearchResult.Kind.allCases.filter(scope.kinds.contains).map { Self.label(for: $0) }.joined(separator: ", "))
        }
        if scope.excludesSystemImages { parts.append("No System Images") }
        return parts.isEmpty ? "All Results" : parts.joined(separator: " · ")
    }

    private static func label(for kind: BinarySearchResult.Kind) -> String {
        switch kind {
        case .instruction: "Instructions"
        case .string: "Strings"
        case .symbol: "Symbols"
        case .function: "Functions"
        case .bytes: "Bytes"
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let message = model.validationMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.lumen(.statusDanger))
        } else if model.isSearching {
            Text("Searching…").font(.caption).foregroundStyle(.secondary)
        } else if model.hasSearched {
            Text(resultSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resultSummary: String {
        if model.isTruncated { return "At least \(model.lowerBound) matches; showing \(model.results.count). Search limited." }
        if model.lowerBound == 0 { return "No matches." }
        return "\(model.lowerBound) match\(model.lowerBound == 1 ? "" : "es")"
    }

    private func runSearch() {
        bindModel()
        store.seedSearchCursor([])
        model.search(selecting: store.selectedImageAddress)
    }

    private func bindModel() {
        model.bind(workspaceOwner: ObjectIdentifier(store), workspaceID: store.workspaceID,
                   documentID: store.documentID, snapshot: store.snapshot,
                   revision: store.mutationGeneration.rawValue, focusedSlot: store.focusedImageSlot, scope: scope)
    }

    private func seedCurrentCursor() {
        guard model.hasSearched, !model.isSearching,
              model.results.allSatisfy({ model.admits($0, workspaceOwner: ObjectIdentifier(store),
                  workspaceID: store.workspaceID, documentID: store.documentID,
                  snapshot: store.snapshot, revision: store.mutationGeneration.rawValue) }) else { return }
        model.seedCursor(in: store, selecting: model.cursor?.current.map {
            ImageAddress(slot: $0.imageSlot, address: $0.address)
        } ?? store.selectedImageAddress)
    }
}

private struct FindResultRow: View {
    let result: BinarySearchResult
    let imageName: String?
    let navigate: () -> Void

    var body: some View {
        Button(action: navigate) {
            HStack(spacing: Lumen.Space.s5) {
                Text(result.kind.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    Text(result.preview)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(imageName ?? "image \(result.imageSlot.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Lumen.Space.s4)
                Text(result.address.hexAddress)
                    .font(AppTypography.bytes)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(result.kind.rawValue) match in \(imageName ?? "image \(result.imageSlot.rawValue)"), \(result.preview), at \(result.address.hexAddress)")
    }
}
