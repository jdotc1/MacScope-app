import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// App adapter. All store/window/panel access stays on MainActor; the worker only sees values.
@MainActor
final class AllPseudocodeExportController: ObservableObject {
    @Published private(set) var progress: AllPseudocodeExportOperation.Progress?
    private var generation = UUID()
    private var operation: AllPseudocodeExportOperation?
    private var worker: Task<AllPseudocodeExportOperation.Output, Error>?
    private var nativeOperation: NativePseudocodeBatchExportOperation?
    private var nativeWorker: Task<NativePseudocodeBatchExportOperation.Output, Error>?
    private var panel: NSSavePanel?

    func cancel() {
        generation = UUID()
        operation?.cancel()
        worker?.cancel()
        nativeOperation?.cancel()
        nativeWorker?.cancel()
        panel?.cancel(nil)
        panel = nil
        operation = nil
        nativeOperation = nil
        progress = nil
        // Keep the retired worker handle: a new job waits for its current printer to return.
    }

    func start(store: WorkspaceStore, isCurrentOwner: @escaping @MainActor () -> Bool) {
        cancel()
        guard isCurrentOwner() else { return }
        let snapshot = store.snapshot
        let slot = store.focusedImageSlot
        guard let binary = snapshot.binary(in: slot) else { return }
        let workspaceID = store.workspaceID
        let installationID = store.documentInstallationID
        let identity = AllPseudocodeExportOperation.Owner(
            documentID: store.documentID, windowGeneration: generation,
            documentGeneration: store.mutationGeneration.rawValue,
            imageSlot: slot.rawValue, binaryID: binary.id)
        let options = DecompilerOptions(userDefaults: .standard)
        let name = "\(store.workspaceName)-all-pseudocode.txt"
        let message = snapshot.binaries.count > 1 ? "Export pseudocode from \(binary.name)." : nil
        let op = AllPseudocodeExportOperation(owner: identity,
            items: (snapshot.analysis(in: slot)?.functions ?? []).map { .init(startAddress: $0.startAddress) })
        operation = op
        progress = .init(completed: 0, total: op.items.count, phase: .rendering)
        let isCurrent: @MainActor () -> Bool = { [weak self, weak store] in
            guard let self, let store else { return false }
            // Focus is intentionally absent: B stays the owner even when A has identical VAs.
            return self.generation == identity.windowGeneration && !op.isCancelled
                && isCurrentOwner() && store.workspaceID == workspaceID
                && store.documentID == identity.documentID
                && store.documentInstallationID == installationID
                && store.mutationGeneration.rawValue == identity.documentGeneration
                && store.snapshot.binary(in: slot)?.id == identity.binaryID
        }
        let previousWorker = worker
        let previousNative = nativeWorker
        let nextWorker = Task.detached(priority: .userInitiated) { [weak self] in
            // Serial across replacement jobs as well as within one job. No printer overlap.
            if let previousWorker { _ = await previousWorker.result }
            if let previousNative { _ = await previousNative.result }
            try Task.checkCancellation()
            return try await op.run(renderer: { item in
                DocumentExportService().renderAllPseudocodeBlock(snapshot: snapshot,
                    startAddress: item.startAddress, in: slot, options: options)
            }, progress: { [weak self] update in
                await self?.accept(update, operation: op, isCurrent: isCurrent)
            })
        }
        worker = nextWorker
        Task { @MainActor [weak self, weak store] in
            let result = await nextWorker.result
            guard let self, let store, self.generation == identity.windowGeneration else { op.cancel(); return }
            defer {
                if self.generation == identity.windowGeneration {
                    self.operation = nil
                    self.worker = nil
                    self.progress = nil
                    self.panel = nil
                }
            }
            guard isCurrent() else { op.cancel(); return }
            switch result {
            case .failure(let error):
                if !(error is CancellationError) { store.saveError = error.localizedDescription }
            case .success(let output):
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType.plainText]
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = name
                if let message { panel.message = message }
                self.panel = panel
                guard isCurrent() else { op.cancel(); return }
                let response = ModalPanelFocus.run { panel.runModal() }
                // The modal loop can process cancellation, close, replacement, or a newer job.
                // Recheck the complete captured owner immediately before the synchronous commit.
                guard response == .OK, let url = panel.url, isCurrent() else { op.cancel(); return }
                do {
                    try op.publish(output, currentOwner: identity, to: url)
                } catch {
                    if isCurrent(), !(error is CancellationError) {
                        store.saveError = "Could not export to \(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Whole-image export through the native provider: text plus a per-function `.report.json`.
    /// Same owner fence, serial worker and final pre-commit recheck as the MacScope export.
    func startNative(store: WorkspaceStore, isCurrentOwner: @escaping @MainActor () -> Bool,
                     decompiler: any NativePseudocodeBatchDecompiling = NativeDecompilerRuntimeRegistry.productionShared,
                     nativeEnabled: Bool = NativeDecompilerRuntimeRegistry.isProductEnabled) {
        cancel()
        guard isCurrentOwner() else { return }
        let op: NativePseudocodeBatchExportOperation
        do {
            op = try AllPseudocodeExportNativeCapture.makeOperation(
                store: store, nativeEnabled: nativeEnabled, ownerGeneration: generation)
        } catch {
            store.saveError = (error as? AllPseudocodeExportNativeCapture.Refusal)?.message
                ?? error.localizedDescription
            return
        }
        let context = op.context
        let identity = op.owner
        let slot = context.imageSlot
        let workspaceID = store.workspaceID
        let installationID = store.documentInstallationID
        let name = "\(store.workspaceName)-native-pseudocode.txt"
        let message = context.snapshot.binaries.count > 1 ? "Export native pseudocode from \(context.imageName)." : nil
        nativeOperation = op
        progress = .init(completed: 0, total: op.items.count, phase: .rendering)
        let isCurrent: @MainActor () -> Bool = { [weak self, weak store] in
            guard let self, let store else { return false }
            return self.generation == identity.windowGeneration && !op.isCancelled
                && isCurrentOwner() && store.workspaceID == workspaceID
                && store.documentID == identity.documentID
                && store.documentInstallationID == installationID
                && store.mutationGeneration.rawValue == identity.documentGeneration
                && store.snapshot.binary(in: slot)?.id == identity.binaryID
        }
        let previousWorker = worker
        let previousNative = nativeWorker
        let nextWorker = Task.detached(priority: .userInitiated) { [weak self] in
            if let previousWorker { _ = await previousWorker.result }
            if let previousNative { _ = await previousNative.result }
            try Task.checkCancellation()
            return try await op.run(decompiler: decompiler, isCurrent: { await isCurrent() },
                                    progress: { [weak self] update in
                await self?.acceptNative(update, operation: op, isCurrent: isCurrent)
            })
        }
        nativeWorker = nextWorker
        Task { @MainActor [weak self, weak store] in
            let result = await nextWorker.result
            guard let self, let store, self.generation == identity.windowGeneration else { op.cancel(); return }
            defer {
                if self.generation == identity.windowGeneration {
                    self.nativeOperation = nil
                    self.nativeWorker = nil
                    self.progress = nil
                    self.panel = nil
                }
            }
            guard isCurrent() else { op.cancel(); return }
            switch result {
            case .failure(let error):
                if !(error is CancellationError) {
                    store.saveError = "Native export stopped; nothing was written. \(AllPseudocodeExportNativeCapture.describe(error))"
                }
            case .success(let output):
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType.plainText]
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = name
                if let message { panel.message = message }
                self.panel = panel
                guard isCurrent() else { op.cancel(); return }
                let response = ModalPanelFocus.run { panel.runModal() }
                guard response == .OK, let url = panel.url, isCurrent() else { op.cancel(); return }
                do {
                    try op.publish(output, currentOwner: identity, to: url)
                } catch {
                    if isCurrent(), !(error is CancellationError) {
                        store.saveError = "Could not export to \(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func acceptNative(_ update: AllPseudocodeExportOperation.Progress,
                              operation: NativePseudocodeBatchExportOperation,
                              isCurrent: @MainActor () -> Bool) {
        guard nativeOperation === operation else { return }
        guard isCurrent() else { operation.cancel(); progress = nil; return }
        progress = update
    }

    private func accept(_ update: AllPseudocodeExportOperation.Progress,
                        operation: AllPseudocodeExportOperation,
                        isCurrent: @MainActor () -> Bool) {
        guard self.operation === operation else { return }
        guard isCurrent() else { operation.cancel(); progress = nil; return }
        progress = update
    }
}
