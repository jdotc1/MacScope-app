import SwiftUI
import LumenTokens
import LumenUI

/// An immutable report with session-local thread selection; no crash data enters the workspace.
struct CrashReportView: View {
    let report: CrashReport
    let context: CrashReportImageContext?
    let imageName: String?
    let onNavigate: (UInt64) -> Bool
    var rendersOffscreen = false
    @State private var selectedThreadID: Int?
    @State private var navigationMessage: String?

    private var selectedThread: CrashReportThread? {
        report.threads.first { $0.id == selectedThreadID }
            ?? report.threads.first { $0.triggered }
            ?? report.threads.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                HStack {
                    Text(report.processName).font(.title2.weight(.semibold))
                    Spacer()
                    LumenBadge("Read only", systemImage: "doc.text")
                }
                Text(report.exceptionSummary).font(.body).textSelection(.enabled)
                Text(imageName.map { "Open image: \($0) · UUID-matched frames can navigate" }
                     ?? "Open this report from an image workspace to resolve its frames.")
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
            }
            Divider()
            if rendersOffscreen {
                threadButtons
            } else {
                ScrollView(.horizontal) { threadButtons }
            }
            if let thread = selectedThread {
                HStack {
                    Text(thread.name ?? "Thread \(thread.id)").font(.body.weight(.semibold))
                    if thread.triggered { Text("Crashed").foregroundStyle(Color.lumen(.statusDanger)) }
                    Spacer()
                    Text("\(thread.frames.count) frames").foregroundStyle(.secondary)
                }
                if rendersOffscreen {
                    VStack(alignment: .leading, spacing: Lumen.Space.s3) {
                        frameRows(thread)
                    }
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Lumen.Space.s3) {
                            frameRows(thread)
                        }
                    }
                }
            } else {
                Text("No thread frames were recorded.").foregroundStyle(.secondary)
                Spacer()
            }
            if let navigationMessage {
                Text(navigationMessage).font(.caption).foregroundStyle(Color.lumen(.statusWarning))
            }
        }
        .padding(Lumen.Space.s6)
        .workbenchPaneBackground(.debugger)
        .frame(minWidth: AppLayout.crashReportMinimumWidth, minHeight: AppLayout.crashReportMinimumHeight)
    }

    private var threadButtons: some View {
        HStack(spacing: Lumen.Space.s3) {
            ForEach(report.threads) { thread in
                Button {
                    selectedThreadID = thread.id
                    navigationMessage = nil
                } label: {
                    HStack(spacing: Lumen.Space.s2) {
                        if thread.triggered { Image(systemName: "exclamationmark.circle.fill") }
                        Text("Thread \(thread.id)")
                    }
                    .padding(.horizontal, Lumen.Space.s4)
                    .padding(.vertical, Lumen.Space.s3)
                    .background(thread.id == selectedThread?.id ? Color.lumen(.bgSelected) : Color.clear,
                                in: RoundedRectangle(cornerRadius: Lumen.Radius.sm))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func frameRows(_ thread: CrashReportThread) -> some View {
        ForEach(thread.frames) { frame in
            CrashReportFrameRow(frame: frame, report: report, context: context) { address in
                navigationMessage = onNavigate(address) ? nil : "The open image changed or this address is no longer available. Reopen the report from that workspace."
            }
        }
    }
}

private struct CrashReportFrameRow: View {
    let frame: CrashReportFrame
    let report: CrashReport
    let context: CrashReportImageContext?
    let onNavigate: (UInt64) -> Void

    var body: some View {
        let resolved = report.resolve(frame, against: context)
        let image = frame.imageIndex.flatMap { report.images.indices.contains($0) ? report.images[$0].name : nil }
        Button {
            if let address = resolved.address { onNavigate(address) }
        } label: {
            HStack(alignment: .top, spacing: Lumen.Space.s4) {
                Text("\(frame.id)").monospacedDigit().foregroundStyle(.secondary).frame(width: AppLayout.crashReportFrameNumberWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                    Text(resolved.symbol ?? frame.reportedSymbol ?? "Unresolved frame")
                        .font(.system(.body, design: .monospaced))
                    HStack(spacing: Lumen.Space.s3) {
                        Text(image ?? "Unknown image")
                        if let offset = frame.imageOffset { Text("+ \(offset.hexAddress)").monospaced() }
                        if resolved.symbol == nil, frame.reportedSymbol != nil { Text("Reported symbol") }
                    }
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
                    if let diagnostic = resolved.diagnostic {
                        Text(diagnostic).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Lumen.Space.s3)
                if let address = resolved.address {
                    Text(address.hexAddress).monospaced().foregroundStyle(Color.accentColor)
                    Image(systemName: "arrow.up.right")
                }
            }
            .padding(Lumen.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lumen(.bgInset), in: RoundedRectangle(cornerRadius: Lumen.Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolved.address == nil)
    }
}
