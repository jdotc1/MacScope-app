import SwiftUI
import LumenUI
import AppKit

@MainActor
struct REAWorkbenchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var controller: REAWorkbenchController
    init(selectedBinaryURL: URL, expectedSelectedSHA256: String, requestedSliceIndex: Int? = nil,
         workspaceID: UUID, history: [REAResultEvidence] = [],
         makeAuthority: @escaping REAWorkbenchController.Authority,
         onAccepted: @escaping REAWorkbenchController.Acceptance) {
        _controller = State(initialValue: REAWorkbenchController(selectedBinaryURL: selectedBinaryURL,
            expectedSelectedSHA256: expectedSelectedSHA256, requestedSliceIndex: requestedSliceIndex,
            workspaceID: workspaceID, history: history, makeAuthority: makeAuthority, onAccepted: onAccepted))
    }
    var body: some View {
        VStack(spacing: 0) {
            REAWorkbenchHeader(name: controller.selectedName, isRunning: controller.isRunning,
                cancel: controller.cancel, close: { dismiss() })
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        REAWorkbenchCaptureControls(controller: controller)
                        REAWorkbenchProcessControls(controller: controller)
                        REAWorkbenchHistory(controller: controller)
                    }.padding(18)
                }.frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                VStack(alignment: .leading, spacing: 10) {
                    if let presentation = controller.presentation {
                        REAInspectionResultView(presentation: presentation)
                    } else {
                        ContentUnavailableView("Inspect Captured Evidence", systemImage: "scope",
                            description: Text("Choose a folder for application and UI inspection, or compare two programs using the same execution inputs."))
                    }
                }.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity).padding(Lumen.Space.s5)
            }
            Divider()
            REAWorkbenchStatus(status: controller.status, error: controller.errorMessage, isRunning: controller.isRunning)
        }
        .frame(minWidth: 840, idealWidth: 1080, minHeight: 620, idealHeight: 760)
        .task { await controller.loadSelectedImage() }
        .onDisappear { controller.cancel() }
    }
}

private struct REAWorkbenchHeader: View {
    let name: String; let isRunning: Bool; let cancel: () -> Void; let close: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("REA Inspection").font(.headline).lumenNeverTruncates("REA Inspection")
                Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isRunning { Button("Cancel", action: cancel) }
            Button("Done", action: close).keyboardShortcut(.cancelAction)
        }.padding(Lumen.Space.s6)
    }
}

private struct REAWorkbenchCaptureControls: View {
    let controller: REAWorkbenchController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Application and UI").font(.headline).lumenNeverTruncates("Application and UI")
            Button("Choose Folder…", action: controller.chooseRoot).disabled(controller.isRunning)
            Text(controller.rootURL?.path ?? "No folder selected").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Inspect Application", action: controller.inspectNative)
                .disabled(controller.isRunning || !controller.isReady || controller.rootURL == nil)
            Button("Inspect UI Resources", action: controller.inspectUI)
                .disabled(controller.isRunning || !controller.isReady || controller.rootURL == nil)
            Text("The folder must contain the workspace’s verified executable. Inspection uses a bounded captured tree.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct REAWorkbenchProcessControls: View {
    @Bindable var controller: REAWorkbenchController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare Programs").font(.headline).lumenNeverTruncates("Compare Programs")
            Button("Choose First Executable…") { controller.chooseExecutable(left: true) }.disabled(controller.isRunning)
            Text(controller.leftExecutable?.path ?? "No first executable").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Choose Second Executable…") { controller.chooseExecutable(left: false) }.disabled(controller.isRunning)
            Text(controller.rightExecutable?.path ?? "No second executable").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Choose Input Folder…", action: controller.chooseInputDirectory).disabled(controller.isRunning)
            Text(controller.inputDirectory?.path ?? "Empty input tree").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Arguments — one per line").font(.caption)
            TextEditor(text: $controller.argumentsText).font(.system(.body, design: .monospaced))
                .frame(height: 65).border(Color(nsColor: .separatorColor)).disabled(controller.isRunning)
            Text("Environment — NAME=value, one per line").font(.caption)
            TextEditor(text: $controller.environmentText).font(.system(.body, design: .monospaced))
                .frame(height: 65).border(Color(nsColor: .separatorColor)).disabled(controller.isRunning)
            TextField("Relative working directory", text: $controller.workingDirectory).disabled(controller.isRunning)
            Button("Run and Compare", action: controller.comparePrograms)
                .disabled(controller.isRunning || !controller.isReady || controller.leftExecutable == nil || controller.rightExecutable == nil)
            Text("Both programs receive the same immutable inputs. Captures include separate final standard output, standard error, and termination; execution is limited to ten seconds.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct REAWorkbenchHistory: View {
    let controller: REAWorkbenchController
    var body: some View {
        if !controller.history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved Evidence").font(.headline)
                ForEach(controller.history, id: \.evidenceID) { record in
                    Button { controller.showHistorical(record) } label: {
                        VStack(alignment: .leading) {
                            Text(record.operation == "nativeApplication" ? "Application" : record.operation == "uiResources" ? "UI Resources" : "Program Comparison")
                            Text(record.authority.snapshotID.uuidString.prefix(8)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).disabled(controller.isRunning)
                }
            }
        }
    }
}

private struct REAWorkbenchStatus: View {
    let status: String; let error: String?; let isRunning: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isRunning { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 3) {
                Text(status).font(.callout)
                if let error { Text(error).font(.caption).foregroundStyle(Color.lumen(.statusDanger)).textSelection(.enabled) }
            }
            Spacer()
        }.padding(Lumen.Space.s5)
    }
}
