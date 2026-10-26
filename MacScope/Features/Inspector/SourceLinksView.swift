import AppKit
import SwiftUI
import LumenUI

/// Shared by the focused inspector and both sides of the accepted comparison detail.
struct SourceLinksView: View {
    @ObservedObject var store: WorkspaceStore
    let slot: ImageSlot
    let address: UInt64
    let origin: SourceLinkOpenOrigin
    @State private var choosingCheckout = false
    @State private var opened: SourcePreviewDocument?
    @State private var errorMessage: String?
    @State private var reading: Result<[SourceEvidenceLink], Error> = .success([])

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s3) {
            HStack {
                Text("Source evidence").font(.caption.weight(.semibold))
                Spacer()
                Button("Choose Source…") { choosingCheckout = true }
                    .controlSize(.small)
                    .disabled(store.snapshot.binary(in: slot)?.metadata.uuid == nil)
            }
            switch reading {
            case .failure(let error):
                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
            case .success(let links):
                if links.isEmpty {
                    Text("Unresolved — choose a local checkout and its build revision.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                        Text(qualification(link)).font(.caption.weight(.medium))
                        if let image = link.image {
                            Text("\(image.architecture) · slot \(image.slot.rawValue) · revision \(image.sourceRevision.value)")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let path = link.recordedPath {
                            Text(path + (link.line.map { ":\($0)" } ?? ""))
                                .font(.system(.caption, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let reason = link.unresolvedReason {
                            Text(reason.sourceLinkDescription).font(.caption).foregroundStyle(.secondary)
                        }
                        if case .some(.compilerMarker(_, let detail)) = link.evidence {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if case .some(.functionCorrelation(let reference, let referenceAddress, _, _, _, _)) = link.evidence {
                            Text("Reviewed function candidate · reference \(reference.imageUUID.uuidString) at \(referenceAddress.hexAddress)")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if link.isOpenable {
                            Button(link.qualification == .exactDebugSymbols ? "Open Source Line" : "Open Candidate File") {
                                open(link)
                            }.controlSize(.small)
                        }
                    }
                }
            }
            SourceFunctionCandidatesView(store: store, slot: slot, address: address)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $choosingCheckout) {
            SourceCheckoutSheet(store: store, slot: slot, address: address)
        }
        .sheet(item: $opened) { document in
            SourcePreviewView(document: document)
        }
        .task(id: ReadingKey(slot: slot, address: address, revision: store.nativeDecompilerSnapshotRevision,
                             sourceState: store.snapshot.sourceLinkState)) {
            reading = Result { try store.sourceLinks(at: address, in: slot) }
        }
    }

    private struct ReadingKey: Hashable {
        let slot: ImageSlot
        let address: UInt64
        let revision: UUID
        let sourceState: Data
    }

    private func qualification(_ link: SourceEvidenceLink) -> LocalizedStringResource {
        switch link.qualification {
        case .exactDebugSymbols: "Exact debug-symbol evidence"
        case .versionQualifiedCandidate: "Tentative source candidate"
        case .unresolved: "Unresolved source link"
        }
    }

    private func open(_ link: SourceEvidenceLink) {
        do {
            guard link.functionAddress == address, link.image?.slot == slot else {
                throw SourceLinkOpenError.staleImage
            }
            let target = try store.sourceOpenTarget(link, origin: origin)
            let document = try SourcePreviewDocument(target: target)
            try store.retainOpenedSourceLink(link, origin: origin)
            opened = document
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct SourceCheckoutSheet: View {
    @ObservedObject var store: WorkspaceStore
    let slot: ImageSlot
    let address: UInt64
    @Environment(\.dismiss) private var dismiss
    @State private var binary: BinaryImage?
    @State private var installationID: UUID?
    @State private var localRoot = ""
    @State private var recordedRoot = ""
    @State private var buildRevision = ""
    @State private var checkoutRevision = ""
    @State private var message: String?

    var body: some View {
        Form {
            Text("Link a local source checkout").font(.headline)
            Text("Enter the immutable revision used for this build and the revision of the local checkout. MacScope retains your explicit association; it does not verify repository contents or copy source files.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(localRoot.isEmpty ? "No local checkout selected" : localRoot)
                    .lineLimit(2).textSelection(.enabled)
                Button("Choose Folder…") { chooseRoot() }
            }
            TextField("Source root recorded by compiler", text: $recordedRoot)
            TextField("Build source revision", text: $buildRevision)
            TextField("Local checkout revision", text: $checkoutRevision)
            Text("Exact links require a matching dSYM imported with architecture evidence. Older imports must be read again before linking.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Accept Source Checkout") { accept() }
                    .disabled(localRoot.isEmpty || recordedRoot.isEmpty || buildRevision.isEmpty || checkoutRevision.isEmpty)
            }
        }
        // Reviewed geometry: Lumen has no checkout-form width equivalent.
        .padding().frame(width: 560)
        .onAppear {
            binary = store.snapshot.binary(in: slot)
            installationID = store.documentInstallationID
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localRoot = url.path
    }

    private func accept() {
        do {
            guard let binary, let installationID, let revision = SourceRevisionIdentity(buildRevision),
                  let checkoutRevision = SourceRevisionIdentity(checkoutRevision),
                  let checkout = AcceptedLocalSourceCheckout(
                    localRootPath: localRoot, recordedSourceRoot: recordedRoot, revision: checkoutRevision
                  ) else { throw SourceLinkStateError.invalid }
            try store.acceptSourceCheckout(checkout, buildRevision: revision,
                                           expectedBinary: binary, expectedInstallationID: installationID,
                                           address: address)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

struct SourcePreviewDocument: Identifiable {
    let id = UUID()
    let target: SourceFileOpenTarget
    let lines: [String]

    init(target: SourceFileOpenTarget) throws {
        let values = try target.fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 2_097_152 else {
            throw SourceLinkOpenError.fileUnavailable
        }
        let handle = try FileHandle(forReadingFrom: target.fileURL)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 2_097_153) ?? Data()
        guard bytes.count <= 2_097_152, let text = String(data: bytes, encoding: .utf8) else {
            throw SourceLinkOpenError.fileUnavailable
        }
        // Treat CRLF as one physical line so DWARF's line numbers do not drift on Windows
        // checkouts. Splitting with CharacterSet.newlines would count both bytes separately.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard lines.count <= 50_000, target.line.map({ $0 > 0 && $0 <= lines.count }) ?? true else {
            throw SourceLinkOpenError.fileUnavailable
        }
        self.target = target
        self.lines = lines
    }
}

private struct SourcePreviewView: View {
    let document: SourcePreviewDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(document.target.fileURL.lastPathComponent + (document.target.line.map { ":\($0)" } ?? " — file candidate"))
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(document.target.image.architecture) · slot \(document.target.image.slot.rawValue) · \(document.target.image.sourceRevision.value)")
                .font(.caption).textSelection(.enabled)
            ScrollViewReader { reader in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: Lumen.Space.s0) {
                        ForEach(document.lines.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: Lumen.Space.s5) {
                                // Reviewed geometry: Lumen has no source line-number column width.
                                Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                                Text(document.lines[index].isEmpty ? " " : document.lines[index]).textSelection(.enabled)
                            }
                            .font(.system(.body, design: .monospaced))
                            .padding(.vertical, Lumen.Space.s1)
                            // Reviewed opacity: preserve the source-line highlight; Lumen has no 0.15 role.
                            .background(index + 1 == document.target.line ? Color.accentColor.opacity(0.15) : .clear)
                            .id(index + 1)
                        }
                    }
                }
                .onAppear { reader.scrollTo(document.target.line ?? 1, anchor: .center) }
            }
        // Reviewed geometry: Lumen has no source-preview minimum-size equivalent.
        }.padding().frame(minWidth: 700, minHeight: 480)
    }
}

private extension SourceLinkUnresolvedReason {
    var sourceLinkDescription: LocalizedStringResource {
        switch self {
        case .imageHasNoUUID: "The image has no UUID."
        case .debugArtifactIncomplete: "Complete debug-symbol architecture and line evidence is unavailable. Reimport the matching dSYM."
        case .debugArtifactUUIDMismatch: "The dSYM UUID differs from this image."
        case .architectureMismatch: "The dSYM architecture differs from this image."
        case .sourceRevisionMismatch: "The source revisions differ."
        case .noAcceptedCheckout: "No local source checkout is accepted for this revision."
        case .recordedPathOutsideAcceptedRoot: "The compiler path lies outside the accepted source root."
        case .noLineForAddress: "No debug-symbol source line covers this address."
        }
    }
}
