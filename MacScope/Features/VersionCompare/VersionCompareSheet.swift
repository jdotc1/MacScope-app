import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumenTokens
import LumenUI

/// Compare Images (View ▸ Compare Images…): pairs the functions of two images already loaded in
/// this workspace and lists unchanged / changed / added / removed functions. Ambiguous matches stay
/// unresolved until the user pins a pair. Selecting a function focuses its image and jumps there.
struct VersionCompareSheet: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var model: VersionCompareViewModel
    let onDismiss: @MainActor () -> Void
    @State private var detailSelection: VersionCompareDetailSelection?
    @State private var exportErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isAvailable {
                VStack(spacing: 0) {
                    controls
                    Divider()
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                placeholder(systemImage: "square.on.square.dashed",
                            title: "Load at least two images to compare.",
                            detail: "Use File ▸ Load Additional Binary… to add another version of this binary to the workspace.")
            }
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 440, idealHeight: 600)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare Images")
        .onAppear { model.bind(to: store.snapshot) }
        .onChange(of: VersionCompareViewModel.images(in: store.snapshot)) { _, _ in
            model.bind(to: store.snapshot)
        }
        .sheet(item: $detailSelection) { selection in
            VersionCompareDetailView(
                store: store, pair: selection.pair, computation: selection.computation,
                row: selection.row, onDismiss: { detailSelection = nil },
                onNavigate: {
                    detailSelection = nil
                    onDismiss()
                }
            )
        }
        .alert("Could not export comparison", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { exportErrorMessage = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(exportErrorMessage ?? "The report could not be saved.")
        }
    }

    // MARK: - Header and controls

    private var header: some View {
        HStack(spacing: Lumen.Space.s5) {
            Label("Compare Images", systemImage: "arrow.left.arrow.right.square")
                .font(.headline)
                .lumenNeverTruncates("Compare Images")
                .accessibilityAddTraits(.isHeader)
            if let summary = model.report?.summary {
                Text(Self.summaryText(summary))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Lumen.Space.s5)
            Button("Done") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s5)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack(spacing: Lumen.Space.s4) {
                imagePicker("Old", selection: model.oldSlot, select: model.selectOld)
                Button {
                    model.swapImages()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("Swap old and new images")
                .accessibilityLabel("Swap old and new images")
                imagePicker("New", selection: model.newSlot, select: model.selectNew)
                Spacer(minLength: Lumen.Space.s4)
                if model.phase == .running || model.isPinning {
                    ProgressView().controlSize(.small)
                }
                Button("Re-run") { model.run() }
                    .disabled(model.selectedPair == nil || model.phase == .running)
                    .help("Recompute the comparison from scratch (discards manual pins)")
                Button("Transfer Names and Comments…") { _ = model.beginTransferReview(snapshot: store.snapshot) }
                    .disabled(!model.canBeginTransferReview || model.transferReview != nil)
                    .help("Review your names and comments from the old image and copy them to the matched functions in the new image")
                    .accessibilityIdentifier("versionCompare.transfer.open")
                Button("Export Report…") { exportReport() }
                    .disabled(!canExport)
            }
            HStack(spacing: Lumen.Space.s4) {
                Picker("Show", selection: $model.filter) {
                    ForEach(VersionCompareFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Filter by name or address", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
            if let summary = model.report?.summary {
                summaryPills(summary)
            }
            if let outcome = model.transferOutcome {
                HStack(spacing: Lumen.Space.s2) {
                    Image(systemName: outcome.isRefused ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(Color.lumen(outcome.isRefused ? .statusWarning : .statusSuccess))
                        .accessibilityHidden(true)
                    Text(outcome.message).font(.caption)
                    Button("Dismiss") { model.clearTransferOutcome() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("versionCompare.transfer.outcome")
            }
            if let pinError = model.pinError {
                HStack(spacing: Lumen.Space.s2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.lumen(.statusWarning))
                        .accessibilityHidden(true)
                    Text(pinError).font(.caption)
                    Button("Dismiss") { model.clearPinError() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s5)
    }

    private func imagePicker(_ title: String, selection: ImageSlot?,
                             select: @escaping @MainActor (ImageSlot) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: { if let slot = $0 { select(slot) } })) {
            ForEach(model.images) { image in
                Text("\(image.name) (slot \(image.slot.rawValue))").tag(Optional(image.slot))
            }
        }
        .frame(maxWidth: 240)
    }

    private func summaryPills(_ summary: VersionCompareSummary) -> some View {
        HStack(spacing: Lumen.Space.s4) {
            pill("Unchanged", summary.unchanged, token: .statusNeutral)
            pill("Changed", summary.changed, token: .statusWarning)
            pill("Added", summary.added, token: .statusSuccess)
            pill("Removed", summary.removed, token: .statusDanger)
            pill("Unresolved", summary.unresolvedGroups, token: .statusInfo)
            if summary.manualPins > 0 {
                pill("Pinned", summary.manualPins, token: .statusInfo)
            }
        }
    }

    private func pill(_ title: String, _ count: Int, token: LumenToken) -> some View {
        HStack(spacing: Lumen.Space.s2) {
            Circle().fill(Color.lumen(token)).frame(width: 7, height: 7).accessibilityHidden(true)
            Text("\(count) \(title)").font(.caption).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .unavailable, .idle:
            placeholder(systemImage: "square.on.square", title: "Choose two different images.", detail: nil)
        case .running:
            VStack(spacing: Lumen.Space.s4) {
                ProgressView()
                Text("Fingerprinting and matching functions…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            placeholder(systemImage: "exclamationmark.triangle", title: "Comparison failed.", detail: message)
        case .ready:
            if let review = model.transferReview {
                AnnotationTransferReviewView(review: review, model: model, store: store)
            } else if let report = model.report {
                list(report)
            }
        }
    }

    private func list(_ report: VersionCompareReport) -> some View {
        let groups = report.filteredUnresolvedGroups(filter: model.filter, search: model.searchText)
        let rows = report.filteredRows(filter: model.filter, search: model.searchText)
        return List {
            if !groups.isEmpty {
                Section("Unresolved — pin a pair to resolve") {
                    ForEach(groups) { group in
                        VersionCompareUnresolvedGroupView(group: group, isPinning: model.isPinning,
                                                          navigate: navigate, pin: model.pin)
                    }
                }
            }
            Section("Functions") {
                if rows.isEmpty {
                    Text("No functions match.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    VersionCompareRowView(row: row, navigate: navigate) {
                        showDetail(for: row)
                    }
                }
            }
        }
        .listStyle(.inset)
        .disabled(model.isPinning)
    }

    private func navigate(_ function: VersionCompareFunctionRef?, _ side: VersionCompareViewModel.Side) {
        guard let target = model.navigationTarget(for: function, side: side),
              VersionCompareViewModel.navigate(to: target, in: store) else { return }
        onDismiss()
    }

    private var canExport: Bool {
        model.phase == .ready && !model.isPinning && model.report != nil
            && model.comparedPair != nil && model.computation != nil
    }

    private func showDetail(for row: VersionCompareRow) {
        guard (row.status == .changed || row.status == .unchanged),
              let pair = model.comparedPair,
              let computation = model.computation,
              model.phase == .ready,
              model.report?.rows.contains(row) == true else { return }
        detailSelection = VersionCompareDetailSelection(
            pair: pair, computation: computation, row: row
        )
    }

    private func exportReport() {
        guard canExport, let pair = model.comparedPair,
              let computation = model.computation,
              model.selectedPair == pair else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacScope Comparison.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard model.phase == .ready, !model.isPinning,
              model.comparedPair == pair,
              model.selectedPair == pair,
              model.report == computation.report else {
            exportErrorMessage = "The comparison changed while choosing a destination. Re-run Compare Images and export again."
            return
        }
        do {
            let data = try VersionCompareExportService.encode(
                computation: computation, pair: pair, snapshot: store.snapshot
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func placeholder(systemImage: String, title: String, detail: String?) -> some View {
        VStack(spacing: Lumen.Space.s4) {
            Spacer()
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.callout).foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Lumen.Space.s7)
    }

    static func summaryText(_ summary: VersionCompareSummary) -> String {
        "\(summary.changed) changed · \(summary.added) added · \(summary.removed) removed · "
            + "\(summary.unresolvedGroups) unresolved"
    }
}

private struct VersionCompareDetailSelection: Identifiable {
    let id = UUID()
    let pair: VersionComparePair
    let computation: VersionCompareComputation
    let row: VersionCompareRow
}

// MARK: - Rows

private struct VersionCompareRowView: View {
    let row: VersionCompareRow
    let navigate: @MainActor (VersionCompareFunctionRef?, VersionCompareViewModel.Side) -> Void
    let showDetail: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
            Text(statusTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.lumen(statusToken))
                .frame(width: 76, alignment: .leading)
            VersionCompareFunctionButton(function: row.old) { navigate(row.old, .old) }
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VersionCompareFunctionButton(function: row.new) { navigate(row.new, .new) }
            Spacer(minLength: Lumen.Space.s4)
            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            if row.status == .changed || row.status == .unchanged {
                Button("Details…", action: showDetail)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        switch row.status {
        case .changed: "Changed"
        case .removed: "Removed"
        case .added: "Added"
        case .unchanged: "Unchanged"
        }
    }

    private var statusToken: LumenToken {
        switch row.status {
        case .changed: .statusWarning
        case .removed: .statusDanger
        case .added: .statusSuccess
        case .unchanged: .statusNeutral
        }
    }

    private var detailText: String {
        var parts: [String] = []
        if let basis = row.basis, let confidence = row.confidence {
            parts.append("\(basis.compareLabel) · \(confidence.compareLabel)")
        }
        if !row.differences.isEmpty {
            parts.append("Δ " + row.differences.map(\.compareLabel).joined(separator: ", "))
        }
        if row.symbolNameChanged { parts.append("renamed/stripped") }
        return parts.joined(separator: "\n")
    }
}

private struct VersionCompareUnresolvedGroupView: View {
    let group: VersionCompareUnresolvedGroupRow
    let isPinning: Bool
    let navigate: @MainActor (VersionCompareFunctionRef?, VersionCompareViewModel.Side) -> Void
    let pin: @MainActor (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text(group.bases.map(\.compareLabel).joined(separator: ", "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.lumen(.statusInfo))
            ForEach(group.old, id: \.id) { old in
                HStack(spacing: Lumen.Space.s4) {
                    VersionCompareFunctionButton(function: old) { navigate(old, .old) }
                    Menu("Pin to…") {
                        ForEach(group.new, id: \.id) { new in
                            Button("\(new.name) — \(new.addressText)") { pin(old.id, new.id) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(isPinning || group.new.isEmpty)
                    Spacer(minLength: 0)
                }
            }
            if !group.new.isEmpty {
                HStack(spacing: Lumen.Space.s4) {
                    Text("Candidates:").font(.caption).foregroundStyle(.secondary)
                    ForEach(group.new, id: \.id) { new in
                        VersionCompareFunctionButton(function: new) { navigate(new, .new) }
                    }
                }
            }
        }
        .padding(.vertical, Lumen.Space.s2)
    }
}

private struct VersionCompareFunctionButton: View {
    let function: VersionCompareFunctionRef?
    let action: @MainActor () -> Void

    var body: some View {
        if let function {
            Button {
                action()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(function.name).font(.body).lineLimit(1).truncationMode(.middle)
                    Text(function.addressText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(function.address == nil)
            .help("Go to \(function.name)")
            .accessibilityLabel("\(function.name) at \(function.addressText)")
            .accessibilityHint("Jumps to this function in its image")
        } else {
            Text("—").foregroundStyle(.tertiary).accessibilityLabel("None")
        }
    }
}

// MARK: - Annotation transfer review (RX-01)

/// Stateless rendering of `AnnotationTransferReview`: proposed rows with confidence and reason,
/// conflicts (never written), and skipped rows. All behaviour lives in the view model.
private struct AnnotationTransferReviewView: View {
    let review: AnnotationTransferReview
    @ObservedObject var model: VersionCompareViewModel
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                Section("Proposed — \(review.selected.count) of \(review.selectableIDs.count) selected") {
                    let rows = review.candidates.filter { $0.skip == nil }
                    if rows.isEmpty {
                        Text("No matched function in the old image carries a name or comment of yours.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(rows) { candidate in
                        AnnotationTransferCandidateRow(
                            candidate: candidate, functions: functions(candidate),
                            isSelected: review.selected.contains(candidate.id),
                            toggle: { model.setTransferSelection(candidate.id, selected: $0) })
                    }
                }
                if let plan = review.plan, !plan.conflicts.isEmpty {
                    Section("Conflicts — left unchanged") {
                        ForEach(Array(plan.conflicts.enumerated()), id: \.offset) { _, conflict in
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(conflict.destinationAddress.hexAddress) · \(conflict.field.rawValue) · \(conflict.kind.compareLabel)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.lumen(.statusWarning))
                                Text("Keeps “\(conflict.existing)”; would have been “\(conflict.incoming)”")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if !review.skipped.isEmpty {
                    Section("Skipped") {
                        ForEach(review.skipped) { candidate in
                            HStack(spacing: Lumen.Space.s4) {
                                Text(functions(candidate).old?.name ?? candidate.oldAddress.hexAddress)
                                    .font(.callout).lineLimit(1)
                                Text(candidate.skip?.compareLabel ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("versionCompare.transfer.review")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text("Transfer names and comments from \(review.pair.old.name) (slot \(review.pair.old.slot.rawValue)) "
                 + "to \(review.pair.new.name) (slot \(review.pair.new.slot.rawValue))")
                .font(.callout.weight(.semibold))
            Text("Only your own names and comments at matched function starts move; generated sub_… names and "
                 + "analysis symbols never do. Existing text is never overwritten. High-confidence pairs are "
                 + "preselected; check others only after reviewing their confidence and reason.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if review.unresolvedGroupCount > 0 {
                Text("\(review.unresolvedGroupCount) ambiguous groups not offered — pin a pair in Compare Images to include it.")
                    .font(.caption).foregroundStyle(Color.lumen(.statusInfo))
            }
            HStack(spacing: Lumen.Space.s4) {
                Button("Select All") { model.selectAllTransferCandidates() }
                    .accessibilityIdentifier("versionCompare.transfer.selectAll")
                Button("Select High Confidence") { model.selectHighConfidenceTransferCandidates() }
                    .accessibilityIdentifier("versionCompare.transfer.selectHighConfidence")
                Button("Select None") { model.clearTransferSelection() }
                    .accessibilityIdentifier("versionCompare.transfer.selectNone")
            }
            .controlSize(.small)
            .disabled(review.selectableIDs.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s5)
    }

    private var footer: some View {
        HStack(spacing: Lumen.Space.s4) {
            if case .failure(let error) = review.preview {
                Text(error.localizedDescription).font(.caption).foregroundStyle(Color.lumen(.statusDanger))
            } else if let plan = review.plan {
                Text("\(plan.conflicts.count) \(plan.conflicts.count == 1 ? "conflict" : "conflicts") will be left unchanged")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Lumen.Space.s4)
            if model.transferOutcome?.isRefused == true {
                Button("Rebuild Preview") { _ = model.rebuildTransferPreview(snapshot: store.snapshot) }
                    .accessibilityIdentifier("versionCompare.transfer.rebuild")
            }
            Button("Cancel") { model.dismissTransferReview() }
                .accessibilityIdentifier("versionCompare.transfer.cancel")
            Button(review.applyTitle) { _ = model.applyTransfer(in: store) }
                .buttonStyle(.borderedProminent)
                .disabled(!review.canApply)
                .help("Apply as one step; Undo reverts every transferred name and comment")
                .accessibilityIdentifier("versionCompare.transfer.apply")
        }
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s5)
    }

    private func functions(_ candidate: AnnotationTransferCandidate)
        -> (old: VersionCompareFunctionRef?, new: VersionCompareFunctionRef?) {
        (model.computation?.oldFunctions[candidate.oldID], model.computation?.newFunctions[candidate.newID])
    }
}

private struct AnnotationTransferCandidateRow: View {
    let candidate: AnnotationTransferCandidate
    let functions: (old: VersionCompareFunctionRef?, new: VersionCompareFunctionRef?)
    let isSelected: Bool
    let toggle: @MainActor (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { toggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Transfer to \(functions.new?.name ?? candidate.newAddress.hexAddress)")
                .accessibilityIdentifier("versionCompare.transfer.row.\(candidate.id)")
            functionText(functions.old, fallback: candidate.oldAddress)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            functionText(functions.new, fallback: candidate.newAddress)
            VStack(alignment: .leading, spacing: 0) {
                Text("Moves \(candidate.movesText)").font(.caption.weight(.semibold))
                if let name = candidate.incoming.name {
                    Text("“\(name)”").font(.caption).lineLimit(1).truncationMode(.middle)
                }
                if let comment = candidate.incoming.comment {
                    Text(comment).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Lumen.Space.s4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(candidate.confidence.compareLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.lumen(confidenceToken))
                Text(candidate.reasonText)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var confidenceToken: LumenToken {
        switch candidate.confidence {
        case .userConfirmed, .high: .statusSuccess
        case .medium: .statusWarning
        case .low: .statusDanger
        }
    }

    private func functionText(_ function: VersionCompareFunctionRef?, fallback: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(function?.name ?? fallback.hexAddress).font(.body).lineLimit(1).truncationMode(.middle)
            Text((function?.address ?? fallback).hexAddress)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Command wiring

/// Presents Compare Images for this window when View ▸ Compare Images… targets its store, and
/// publishes the command's enablement (at least two analyzed images) as a focused scene value.
/// The view model lives with the window so a comparison survives closing and reopening the sheet.
struct VersionCompareCommandHandler: ViewModifier {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var model = VersionCompareViewModel()
    @State private var isPresented = false

    init(store: WorkspaceStore) {
        self.store = store
    }

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.versionCompareAvailable,
                VersionCompareViewModel.isAvailable(in: store.snapshot))
            .onReceive(NotificationCenter.default.publisher(for: .macScopeShowVersionCompare)
                .filter { store.commandTargetsSelf($0) }) { _ in
                guard VersionCompareViewModel.isAvailable(in: store.snapshot) else { return }
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                VersionCompareSheet(store: store, model: model) { isPresented = false }
            }
    }
}

struct VersionCompareAvailableFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    /// Whether the focused window can open Compare Images (two or more analyzed images).
    var versionCompareAvailable: Bool? {
        get { self[VersionCompareAvailableFocusedValueKey.self] }
        set { self[VersionCompareAvailableFocusedValueKey.self] = newValue }
    }
}
