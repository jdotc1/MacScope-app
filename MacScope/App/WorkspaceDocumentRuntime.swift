import Foundation
import AppKit
import UniformTypeIdentifiers

/// App-lifetime composition root for conflict-safe workspace document authority.
///
/// The probe, reader, and change monitor are stateless and may be shared. Each coordinator or
/// document session receives a distinct `WorkspaceDocumentIO` actor and publisher, so unrelated
/// windows never serialize through one actor and staged-package ownership never crosses sessions.
@MainActor
final class WorkspaceDocumentRuntime {
    let registry: WorkspaceSessionRegistry
    let windowActivator: WorkspaceWindowActivator
    let openCoordinator: WorkspaceOpenCoordinator

    init(
        nativeDecompilerSessions: (any NativeDecompilerSessionProviding)? = nil,
        reconstructionRuntimeFactory: ReconstructionWorkspaceRuntimeFactory? = nil
    ) {
        let probe = WorkspacePackageVersionProbe()
        let reader = WorkspaceDocumentReader(probe: probe)
        let monitor = WorkspaceDocumentChangeMonitor()
        let makeIO: @MainActor () -> WorkspaceDocumentIO = {
            WorkspaceDocumentIO(
                probe: probe,
                reader: reader,
                publisher: WorkspaceDocumentPublisher(probe: probe),
                monitor: monitor
            )
        }

        let registry = WorkspaceSessionRegistry(
            nativeDecompilerSessions: nativeDecompilerSessions,
            reconstructionRuntimeFactory: reconstructionRuntimeFactory
        )
        let windowActivator = WorkspaceWindowActivator()
        registry.terminationChoice = { [weak windowActivator] id, snapshot in
            // A quit Apple event (`tell application … to quit`) arrives while MacScope is in the
            // background, unlike Cmd-Q. Without activation the prompt below attached to a
            // background window, the sender's event timed out, and the quit looked ignored.
            // Bring the exact document window forward before asking, and also when another sheet
            // blocks the prompt, so a refused quit is visible rather than silent.
            guard let windowActivator, let window = windowActivator.window(for: id) else {
                return .cancel
            }
            windowActivator.activateWindow(id)
            guard window.attachedSheet == nil else {
                NSSound.beep()
                return .cancel
            }
            let prompt = WorkspaceTerminationPrompt(hasConflict: snapshot.conflict != nil)
            let alert = NSAlert()
            alert.messageText = prompt.messageText
            alert.informativeText = prompt.informativeText
            for button in prompt.buttons {
                let added = alert.addButton(withTitle: button.title)
                if let keyEquivalent = button.keyEquivalent {
                    added.keyEquivalent = keyEquivalent
                    if keyEquivalent == "d" { added.keyEquivalentModifierMask = [.command] }
                }
            }
            alert.alertStyle = .warning
            let response = await Self.presentSheet(alert, on: window)
            return prompt.choice(for: response)
        }
        registry.terminationSaveDestination = { [weak windowActivator] id in
            guard let windowActivator, let window = windowActivator.window(for: id) else {
                return nil
            }
            windowActivator.activateWindow(id)
            guard window.attachedSheet == nil else { return nil }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(MacScopeDocumentPackage.formatIdentifier) ?? .package]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "Untitled.\(MacScopeDocumentPackage.fileExtension)"
            let response = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    panel.beginSheetModal(for: window) { response in
                        continuation.resume(returning: response)
                    }
                    if Task.isCancelled { panel.cancel(nil) }
                }
            } onCancel: {
                Task { @MainActor in panel.cancel(nil) }
            }
            return response == .OK ? panel.url : nil
        }
        let openCoordinator = WorkspaceOpenCoordinator(
            registry: registry,
            io: makeIO(),
            windowActivator: windowActivator,
            sessionIOFactory: makeIO
        )

        self.registry = registry
        self.windowActivator = windowActivator
        self.openCoordinator = openCoordinator
    }

    @discardableResult
    func shutdown() async -> Bool {
        await registry.shutdown()
    }

    private static func presentSheet(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
                if Task.isCancelled { window.endSheet(alert.window, returnCode: .cancel) }
            }
        } onCancel: {
            Task { @MainActor in window.endSheet(alert.window, returnCode: .cancel) }
        }
    }
}

/// The quit-time prompt for one document, kept as data so CoreTests can pin its choices without
/// presenting an `NSAlert`. Button order follows NSDocument: the first button is the default
/// (Return), "Cancel Quit" carries Escape, and the untitled prompt offers "Don't Save" (Cmd-D)
/// so quitting never forces a save.
struct WorkspaceTerminationPrompt: Equatable {
    struct Button: Equatable {
        let title: String
        let choice: WorkspaceDocumentTerminationChoice
        let keyEquivalent: String?
    }

    let messageText: String
    let informativeText: String
    let buttons: [Button]

    init(hasConflict: Bool) {
        if hasConflict {
            messageText = "The workspace changed on disk."
            informativeText = "Save your changes to another workspace, or explicitly replace the observed disk version with your local version."
            buttons = [
                Button(title: "Save As…", choice: .saveAs, keyEquivalent: nil),
                Button(title: "Cancel Quit", choice: .cancel, keyEquivalent: "\u{1b}"),
                Button(title: "Keep Local Version", choice: .keepLocalVersion, keyEquivalent: nil)
            ]
        } else {
            messageText = "Save this untitled workspace before quitting?"
            informativeText = "Your changes will be lost if you don’t save them."
            buttons = [
                Button(title: "Save As…", choice: .saveAs, keyEquivalent: nil),
                Button(title: "Cancel Quit", choice: .cancel, keyEquivalent: "\u{1b}"),
                Button(title: "Don’t Save", choice: .discard, keyEquivalent: "d")
            ]
        }
    }

    /// Maps an alert response to its button's choice; anything else (sheet ended, Escape) cancels.
    func choice(for response: NSApplication.ModalResponse) -> WorkspaceDocumentTerminationChoice {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard buttons.indices.contains(index) else { return .cancel }
        return buttons[index].choice
    }
}
