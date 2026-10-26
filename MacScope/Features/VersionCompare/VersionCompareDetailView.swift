import SwiftUI
import LumenUI

/// Opens from an accepted Compare Images row. Both panes scroll independently because the analysis
/// does not provide trustworthy cross-version instruction or basic-block correspondence.
struct VersionCompareDetailView: View {
    @ObservedObject var store: WorkspaceStore
    let pair: VersionComparePair
    let computation: VersionCompareComputation
    let row: VersionCompareRow
    let onDismiss: @MainActor () -> Void
    let onNavigate: @MainActor () -> Void
    @State private var navigationError: String?

    var body: some View {
        VStack(spacing: Lumen.Space.s0) {
            HStack {
                Text("Function change detail").font(.headline)
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            switch VersionCompareInstructionDetail.project(
                row: row, pair: pair, computation: computation, snapshot: store.snapshot
            ) {
            case .unavailable(let reason):
                ContentUnavailableView("Detail unavailable", systemImage: "arrow.clockwise", description: Text(reason))
            case .ready(let detail):
                comparison(detail)
            }
        }
        // Retain the comparison dialog bounds; Lumen has no equivalent two-pane sheet metric.
        .frame(minWidth: 800, idealWidth: 980, minHeight: 440, idealHeight: 620)
        .alert("Could not open reference", isPresented: Binding(
            get: { navigationError != nil },
            set: { if !$0 { navigationError = nil } }
        )) {
            Button("OK", role: .cancel) { navigationError = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(navigationError ?? "The reference is unavailable.")
        }
    }

    private func comparison(_ detail: VersionCompareInstructionDetail) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text("\(detail.basis.compareLabel) · \(detail.confidence.compareLabel)")
                .font(.subheadline)
            Text(detail.differences.isEmpty
                 ? "No known fingerprint differences"
                 : "Changed facts: " + detail.differences.map(\.compareLabel).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Each pane shows decoded rows from its own image. Instructions and basic blocks are unpaired; rows at the same height are not established equivalents.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Lumen.Space.s0) {
                pane("Old", side: detail.old, origin: .compareImagesOld(slot: detail.old.image.slot))
                Divider()
                pane("New", side: detail.new, origin: .compareImagesNew(slot: detail.new.image.slot))
            }
        }
        .padding()
    }

    private func pane(_ title: String, side: VersionCompareInstructionDetail.Side,
                      origin: SourceLinkOpenOrigin) -> some View {
        ScrollView {
          VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text("\(title): \(side.image.name) (slot \(side.image.slot.rawValue))")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("\(side.function.name) · \(side.function.addressText)–\(side.endAddress.hexAddress)")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
            Text("\(side.totalInstructionCount) decoded rows · unpaired")
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                    contextGroup("Callers", links: side.context.callers,
                                 count: side.context.callerCount, side: side)
                    contextGroup("Other references in", links: side.context.incomingReferences,
                                 count: side.context.incomingCount, side: side)
                    contextGroup("References out", links: side.context.outgoingReferences,
                                 count: side.context.outgoingCount, side: side)
                    contextGroup("Type users in this function", links: side.context.typeUsers,
                                 count: side.context.typeUserCount, side: side)
                    Text("These are image-local facts. They do not imply that a caller, reference, or type matches across versions.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Lumen.Space.s3)
            } label: {
                Text("Change context · \(side.context.callerCount) callers · \(side.context.typeUserCount) type uses")
                    .font(.caption.weight(.semibold))
            }
            Divider()
            if let address = side.function.address {
                SourceLinksView(store: store, slot: side.image.slot, address: address, origin: origin)
            }
            // Retain compact 3-point row spacing; the Lumen spacing ladder has no equivalent.
            LazyVStack(alignment: .leading, spacing: 3) {
                    if side.instructions.isEmpty {
                        Text("No decoded instructions in this function range.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(side.instructions) { instruction in
                        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
                            // Fixed address/byte columns keep decoded rows aligned; no matching Lumen metrics.
                            Text(instruction.address.hexAddress)
                                .frame(width: 110, alignment: .leading)
                            Text(instruction.bytes.isEmpty ? "—" : instruction.bytes)
                                .frame(width: 150, alignment: .leading)
                            Text(instruction.mnemonic + (instruction.operands.isEmpty ? "" : " " + instruction.operands))
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                    if side.omittedInstructionCount > 0 {
                        Text("\(side.omittedInstructionCount) more decoded rows omitted (300-row limit).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          // Preserve the existing pane inset; there is no 10-point Lumen spacing token.
          .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func contextGroup(
        _ title: String,
        links: [VersionCompareChangeContext.Link],
        count: Int,
        side: VersionCompareInstructionDetail.Side
    ) -> some View {
        // Preserve compact context spacing; Lumen has no 3- or 5-point spacing tokens.
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title) (\(count))")
                .font(.caption.weight(.semibold))
            if count == 0 {
                Text("None recorded").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(links) { link in
                Button {
                    navigate(link, side: side)
                } label: {
                    HStack(spacing: 5) {
                        Text(link.kind).foregroundStyle(.secondary)
                        Text(link.label)
                        Text(link.address.hexAddress).foregroundStyle(.secondary)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                }
                .buttonStyle(.link)
            }
            if count > links.count {
                Text("\(count - links.count) more omitted (\(VersionCompareChangeContext.maximumLinksPerGroup)-link limit).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func navigate(
        _ link: VersionCompareChangeContext.Link,
        side: VersionCompareInstructionDetail.Side
    ) {
        guard case .ready(let current) = VersionCompareInstructionDetail.project(
            row: row, pair: pair, computation: computation, snapshot: store.snapshot
        ) else {
            navigationError = "The comparison changed. Re-run Compare Images before following this reference."
            return
        }
        let currentSide = side.image.slot == pair.old.slot ? current.old : current.new
        guard currentSide.image == side.image,
              currentSide.context.allLinks.contains(link),
              store.goToAddress(link.address, in: side.image.slot) else {
            navigationError = "This reference is no longer available in \(side.image.name)."
            return
        }
        onNavigate()
    }
}
