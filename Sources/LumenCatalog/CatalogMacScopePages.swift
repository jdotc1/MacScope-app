import SwiftUI
import LumenTokens
import LumenUI

// The pieces chosen for MacScope's debugger, editor, sheets and settings live.

private typealias C = LumenToken.Code

struct DebuggerPage: View {
    @State private var frame: Int? = 0
    @State private var console = [
        LumenConsoleLine(.command, "breakpoint set -n compute"),
        LumenConsoleLine(.output, "Breakpoint 1: Sample`compute(_:) + 12 at main.swift:42"),
        LumenConsoleLine(.stop, "Stopped: thread 1, breakpoint 1.1"),
    ]
    @State private var input = ""
    @State private var armed = [true, true, false]
    @State private var expression = "x0 + 1"
    @State private var newWatch = ""
    @State private var watches = [LumenWatch(id: "1", expression: "count", value: "42", type: "Int"),
                                  LumenWatch(id: "2", expression: "missingVar", error: "not in scope")]
    @State private var hexSelection: Range<Int>? = 16..<21
    @State private var format = "Hex"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Debugger", summary: "MacScope’s debugger, deck by deck: the stack, registers, console, breakpoints, memory, expressions, watches and variables.")
            LumenSectionHeader("Stack and registers")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { stack; registers }
                VStack(alignment: .leading, spacing: 16) { stack; registers }
            }
            LumenSectionHeader("Console and breakpoints")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { consoleView; breakpoints }
                VStack(alignment: .leading, spacing: 16) { consoleView; breakpoints }
            }
            LumenSectionHeader("Memory")
            LumenHexDump(Array("Hello, MacScope! This is memory at the stack pointer.".utf8) + [0, 0, 0x1b, 0x0a],
                         baseAddress: 0x16fdff280, selection: $hexSelection)
                .lumenCard(padding: 8)
            LumenSectionHeader("Expressions and watches")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { commands; watchList }
                VStack(alignment: .leading, spacing: 16) { commands; watchList }
            }
            LumenSectionHeader("Variables")
            LumenVariableTree([
                LumenVariableSection("Locals", variables: [
                    LumenVariable(id: "self", name: "self", type: "Parser", value: "0x600003a1c000", disclosure: .expanded),
                    LumenVariable(id: "count", depth: 1, name: "count", type: "Int", value: "42", changed: true),
                    LumenVariable(id: "header", depth: 1, name: "header", type: "UnsafePointer<Header>", value: "0x16fdff2a8", disclosure: .collapsed),
                    LumenVariable(id: "cache", name: "cache", type: "Cache?", value: "couldn’t read memory", disclosure: .failed),
                ]),
                LumenVariableSection("Arguments", variables: [], emptyMessage: "No arguments."),
            ])
            .frame(maxWidth: 420)
        }
    }

    private var stack: some View {
        LumenStackFrameList([
            LumenStackFrame(index: 0, function: "compute(_:)", address: 0x100003f50, location: "main.swift:42"),
            LumenStackFrame(index: 1, function: "run()", address: 0x100004120, location: "main.swift:17"),
            LumenStackFrame(index: 2, function: "start", address: 0x18c2a0274, location: "dyld", isSystem: true),
        ], selection: $frame)
        .frame(width: 300)
    }

    private var registers: some View {
        VStack(alignment: .leading, spacing: 8) {
            LumenModeSwitcher(selection: $format, options: ["Hex", "Dec", "Signed", "Float"], style: .pill, title: { $0 })
            LumenRegisterGrid([
                LumenRegister("x0", value: "0x0000000000000001", changed: true),
                LumenRegister("sp", value: "0x000000016fdff280", role: "stack", changed: true),
                LumenRegister("lr", value: "0x0000000100004144", role: "link"),
                LumenRegister("pc", value: "0x0000000100003f50", role: "program"),
            ])
        }
        .frame(maxWidth: 380)
    }

    private var consoleView: some View {
        LumenConsole(lines: console, input: $input) { command in
            console.append(LumenConsoleLine(.command, command))
            console.append(LumenConsoleLine(.output, "(demo) \(command)"))
        }
        .frame(width: 340, height: 200)
        .lumenCard(padding: 0)
    }

    private var breakpoints: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(zip(["compute(_:)", "-[NSView layout]", "parse_header"],
                              ["Sample · main.swift:42", "AppKit · waiting for image", "libparse.dylib"])).indices, id: \.self) { i in
                LumenBreakpointRow(isEnabled: $armed[i], locator: ["compute(_:)", "-[NSView layout]", "parse_header"][i],
                                   scope: ["Sample · main.swift:42", "AppKit · waiting for image", "libparse.dylib"][i],
                                   status: armed[i] ? (i == 1 ? "Pending" : "Armed") : "Off",
                                   tone: armed[i] ? (i == 1 ? .statusWarning : .statusSuccess) : .fgTertiary, hits: i == 0 ? 3 : 0) {
                    LumenReferenceRow("0x100003f5c", kind: "resolved") {}
                }
            }
        }
        .frame(width: 320)
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 8) {
            LumenCommandField("expr", parts: [LumenCommandPart($expression, prompt: "Expression")], actionTitle: "Evaluate") {}
            LumenEvaluationResult("2", type: "unsigned long")
        }
        .frame(width: 320)
    }

    private var watchList: some View {
        LumenWatchList(watches, newExpression: $newWatch, limit: 16, caution: "Evaluating can run code.",
                       onEvaluate: {}, onAdd: { watches.append(LumenWatch(id: UUID().uuidString, expression: $0)) },
                       onRemove: { id in watches.removeAll { $0.id == id } })
            .frame(width: 320)
    }
}

struct EditorPage: View {
    @Environment(\.lumenPalette) private var palette
    @State private var source = "Native"
    @State private var selectedString = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Editor", summary: "MacScope’s editor panes: the pseudocode strip and gutter, the disassembly listing with branch lanes, graph blocks, the strings navigator and the inspector’s summary card.")
            LumenSectionHeader("Pseudocode")
            VStack(spacing: 0) {
                LumenStatusStrip(status: LumenStripStatus("Ready", tone: .statusSuccess), chips: [LumenStripChip("Truncated")],
                                 actions: [LumenBarAction("Refresh", systemImage: "arrow.clockwise") {}]) {
                    LumenModeSwitcher(selection: $source, options: ["Native", "MacScope", "Compare"], style: .pill, title: { $0 })
                }
                LumenCodeListing([
                    [LumenCodeRun("int64_t", C.type), LumenCodeRun(" "), LumenCodeRun("compute", C.function), LumenCodeRun("(int64_t a1)")],
                    [LumenCodeRun("{", C.punctuation)],
                    [LumenCodeRun("  "), LumenCodeRun("if", C.keyword), LumenCodeRun(" ( a1 < "), LumenCodeRun("0", C.number), LumenCodeRun(" )")],
                    [LumenCodeRun("    "), LumenCodeRun("return", C.keyword), LumenCodeRun(" "), LumenCodeRun("-1", C.number), LumenCodeRun(";")],
                    [LumenCodeRun("}", C.punctuation)],
                ], currentLine: 3)
            }
            .frame(maxWidth: 460).lumenCard(padding: 0)
            LumenSectionHeader("Disassembly")
            listing.frame(maxWidth: 460).lumenCard(padding: 0)
            LumenSectionHeader("Graph")
            HStack(spacing: 14) {
                LumenGraphNode("Entry", detail: "0x100003f50–3f64", systemImage: "lumen.entryPoint", hue: .hueGreen, count: 6)
                LumenGraphNode("Block 2", detail: "0x100003f68–3f7c", count: 4, state: .selected)
                LumenGraphNode("Exit", detail: "0x100003f88–3f90", systemImage: "arrow.uturn.left", hue: .hueOrange, count: 3)
            }
            .frame(maxWidth: 460).frame(height: 62)
            HStack(spacing: 12) {
                ForEach(LumenGraphEdgeKind.allCases, id: \.self) { kind in
                    // Every key shows its line (solid or dashed, in its color); lettered kinds add their badge.
                    HStack(spacing: 4) {
                        Path { $0.move(to: CGPoint(x: 0, y: 7)); $0.addLine(to: CGPoint(x: 18, y: 7)) }
                            .stroke(Color.lumen(kind.token), style: StrokeStyle(lineWidth: kind.lineWidth(isSelected: false), dash: kind.dash))
                            .frame(width: 18, height: 14)
                            .accessibilityHidden(true)
                        LumenGraphEdgeBadge(kind)
                        Text(kind.title).font(.caption)
                    }
                }
            }
            LumenSectionHeader("Strings and inspector")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { strings; inspector }
                VStack(alignment: .leading, spacing: 16) { strings; inspector }
            }
        }
    }

    private var strings: some View {
                VStack(spacing: 2) {
                    ForEach(Array(["Hello, MacScope!", "%s: invalid header (%d)\\n", "/usr/lib/libSystem.B.dylib"].enumerated()), id: \.offset) { i, text in
                        LumenStringRow(text, address: 0x100008000 + UInt64(i * 0x11), section: "__cstring", length: text.count,
                                       isSelected: i == selectedString)
                            .onTapGesture { selectedString = i }
                    }
                }
                .padding(8).frame(width: 260).lumenSidebarBackground().clipShape(.rect(cornerRadius: 8))
    }

    private var inspector: some View {
                VStack(spacing: 0) {
                    LumenInspectorSummary(kind: "Instruction", title: "0x100003f60", link: "compute(_:)", detail: "+16 · __TEXT,__text",
                                          stats: [LumenStat("callers", count: 3), LumenStat("blocks", count: 4), LumenStat("bytes", count: 64)],
                                          onOpenLink: {})
                    VStack(spacing: 2) {
                        LumenReferenceRow("main+24", kind: "call") {}
                        LumenReferenceRow("0x100004200", kind: "data") {}
                    }.padding(.horizontal, 16).padding(.bottom, 10)
                }
                .frame(width: 280).background(palette[.inspectorBackground], in: .rect(cornerRadius: 8))
    }

    private var listing: some View {
        let rows: [(String, String, String, LumenListingRowState)] = [
            ("100003f50", "cbz", "x1, loc_3f80", .init()),
            ("100003f60", "add", "x19, x19, x0", .init(isProgramCounter: true, isInCurrentBlock: true)),
            ("100003f64", "subs", "x2, x2, #1", .init(isInCurrentBlock: true)),
            ("100003f68", "b.ne", "loc_3f60", .init(isSelected: true, isInCurrentBlock: true)),
            ("100003f80", "mov", "x0, #-1", .init(tag: .orange)),
        ]
        return HStack(spacing: 0) {
            LumenBranchLanes([LumenBranchLane(fromRow: 0, toRow: 4), LumenBranchLane(fromRow: 3, toRow: 1, isHighlighted: true)],
                             rowHeight: 20, rowCount: rows.count, rowStates: rows.map(\.3))
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Group { if rows[i].3.isProgramCounter { LumenProgramCounterMarker() } else { Color.clear } }.frame(width: 12)
                        Text(rows[i].0).foregroundStyle(palette[C.lineNumber])
                        Text(rows[i].1).fontWeight(.semibold).foregroundStyle(palette[rows[i].1.hasPrefix("b") || rows[i].1 == "cbz" ? C.keyword : C.type])
                            .frame(width: 36, alignment: .leading)
                        Text(rows[i].2)
                        Spacer()
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(height: 20)
                    .lumenListingRow(rows[i].3, drawsLeadingMarks: false)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct SheetsPage: View {
    @State private var showsSheet = false
    @State private var pid: Int32? = 4312
    @State private var density = "Regular"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Sheets & Settings", summary: "A sheet’s frame with its footer status, the attach list, and a rich settings pane whose rows explain themselves.")
            LumenSectionHeader("Sheet")
            Button("Show the Attach Sheet") { showsSheet = true }
                .sheet(isPresented: $showsSheet) {
                    LumenSheet("Attach to Process", subtitle: "Processes you can debug", systemImage: "arrow.down.to.line", hue: .hueTeal,
                               status: LumenSheetStatus("Attaching asks for permission once.", tone: .neutral),
                               onCancel: { showsSheet = false },
                               primary: LumenBarAction("Attach", isEnabled: pid != nil) { showsSheet = false }) {
                        processes
                    }
                    .frame(width: 460, height: 360)
                }
            processes.frame(width: 360)
            LumenSectionHeader("Rich settings")
            VStack(alignment: .leading, spacing: 12) {
                LumenSettingsHeader("Appearance", systemImage: "paintpalette", hue: .hueViolet, summary: "Theme, accent, density and the listing font.")
                LumenFormSection("Layout") {
                    LumenSettingsRow("Density", description: "Row height in lists and listings.") {
                        LumenModeSwitcher(selection: $density, options: ["Compact", "Regular"], style: .pill, title: { $0 })
                    }
                    LumenSettingsRow("Show instruction bytes", description: "The raw bytes beside each instruction.") {
                        Toggle("Show instruction bytes", isOn: .constant(false)).toggleStyle(.switch)
                    }
                }
            }
            .frame(maxWidth: 480)
        }
    }

    private var processes: some View {
        LumenProcessList([
            LumenProcess(pid: 4312, name: "Sample", path: "~/Projects/Sample/Build/Sample.app", user: "dev"),
            LumenProcess(pid: 811, name: "Safari", path: "/Applications/Safari.app", user: "dev", systemImage: "safari", hue: .hueTeal),
            LumenProcess(pid: 98, name: "launchd", path: "/sbin/launchd", user: "root", isPrivileged: true, systemImage: "lock", hue: .hueGraphite),
        ], selection: $pid)
    }
}
