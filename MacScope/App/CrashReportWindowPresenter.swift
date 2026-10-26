import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit owns only the auxiliary window lifecycle; the report surface is SwiftUI.
@MainActor
final class CrashReportWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = CrashReportWindowPresenter()
    private var windows: [ObjectIdentifier: NSWindow] = [:]

    func presentPanel(store: WorkspaceStore?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ips") ?? .json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a macOS crash report (.ips). The report is opened read only."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, store: store)
    }

    func open(_ url: URL, store: WorkspaceStore?) {
        let binary = store?.focusedBinary
        let context = store.flatMap { Self.context(in: $0) }
        Task { [weak self, weak store] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
                    return try CrashReport.parse(data)
                }.value
                guard let self else { return }
                let content = CrashReportView(report: report, context: context,
                                              imageName: context == nil ? nil : binary?.name) { [weak store] address in
                    guard let store, let binary,
                          store.focusedBinary?.id == binary.id,
                          store.focusedBinary?.artifactIdentity == binary.artifactIdentity,
                          store.focusedBinary?.metadata.uuid == binary.metadata.uuid else { return false }
                    return store.selectAddress(ImageAddress(slot: binary.slot, address: address))
                }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
                window.title = "\(url.lastPathComponent) — Crash Report"
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: content.dsPaletteRoot())
                window.delegate = self
                self.windows[ObjectIdentifier(window)] = window
                window.center()
                window.makeKeyAndOrderFront(nil)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t Open Crash Report"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeValue(forKey: ObjectIdentifier(window))
    }

    static func context(in store: WorkspaceStore) -> CrashReportImageContext? {
        guard let binary = store.focusedBinary,
              let uuid = binary.metadata.uuid,
              let layout = binary.preferredSegmentLayout,
              let analysis = store.snapshot.analysis(in: binary.slot) else { return nil }
        // The Mach-O header's file-backed mapping is the preferred image base. PAGEZERO
        // is not a mapping and cannot supply a slide or a navigable range.
        let bases = layout.records.filter { $0.sliceRelativeFileOffset == 0 && $0.fileSize > 0 && $0.initialProtections != 0 }
        guard bases.count == 1, let base = bases.first?.preferredVMStart else { return nil }
        let ranges = layout.records.compactMap { record -> Range<UInt64>? in
            let (end, overflow) = record.preferredVMStart.addingReportingOverflow(record.preferredVMSize)
            guard record.initialProtections != 0, !overflow, end > record.preferredVMStart else { return nil }
            return record.preferredVMStart..<end
        }
        let functions = analysis.functions.map {
            CrashReportSymbol(name: $0.name, address: $0.startAddress, endAddress: $0.endAddress)
        }
        let symbols = analysis.symbols.compactMap { symbol -> CrashReportSymbol? in
            guard let address = symbol.address else { return nil }
            return CrashReportSymbol(name: symbol.name, address: address, endAddress: nil)
        }
        return CrashReportImageContext(uuid: uuid, preferredBase: base, mappedRanges: ranges, symbols: functions + symbols)
    }
}
