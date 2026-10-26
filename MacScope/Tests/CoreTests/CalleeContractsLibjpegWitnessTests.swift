import Foundation
import XCTest
@testable import MacScope

/// Explicit one-input diagnostic, never a count-based acceptance test or default suite workload.
final class CalleeContractsLibjpegWitnessTests: XCTestCase {
    // Stack-local read-only fence encloses setup, body and teardown. No shared
    // snapshot state is needed when suites or test instances execute in parallel.
    override func invokeTest() {
        let before = NSDictionary(dictionary:
            UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:])
        defer {
            let after = UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:]
            XCTAssertTrue(before.isEqual(to: after),
                          "Mode tests must not change the application preference domain")
        }
        super.invokeTest()
    }


    func testOutputMetricExtraction() throws {
        let sample = """
        unknown demo(undefined8 arg0, unknown_t *arg1, int known) {
            undefined4 local;
            unknown_t *pointer;
            int fine;
            x0 = (*x8_2)(arg0); // call
            resolved(arg0); /* via struct slot */
            if (fine) goto loc_10;
            goto loc_20;
        loc_10:
            /* warning: first */ // warning: unsupported instruction; goto fake;
            // diagnostic: unknown type
            const char *s = "(*fake)(); goto fake;";
            __unknown("mnemonic", "operands");
            __branch(0x10);
            __branch_register(x8);
            __compare(x0, x1); // sets condition flags
            __custom_op(x0);
            __adrp(x0, 0x1000);
            x0 = __custom_op(x1);
            const char *intrinsics = "__unknown(); __branch(); __branch_register(); __compare(); __custom_op();";
            // __unknown(); __branch(); __branch_register(); __compare(); __custom_op();
            /* __unknown(); __branch(); __branch_register(); __compare(); __custom_op(); */
            return unresolved_return_contract;
        loc_20:
            return unresolved_return_contract;
        }
        """
        let row = CalleeWitnessOutputMetrics.extract(name: "demo", start: 16, text: sample)
        XCTAssertEqual(row.counts, ["unresolvedReturnContractLines": 2, "unresolvedIndirectCalls": 1,
            "undefinedTypedLocals": 2, "undefinedTypedParams": 2, "gotos": 2, "labels": 2,
            "warnings": 2, "functionsRendered": 1, "functionsFailed": 0,
            "unmodeledInstructionLines": 1, "rawBranches": 1, "indirectBranches": 1,
            "flagCompareStatements": 1, "rawIntrinsicStatements": 5])
        XCTAssertEqual(row.warnings, ["warning": 1, "diagnostic": 1])
        XCTAssertEqual(row.observedTypes, Set(["undefined8", "undefined4", "unknown_t"]))
        let failed = CalleeWitnessOutputMetrics.extract(name: "failed", start: 32, text: "")
        let aggregate = CalleeWitnessOutputMetrics.aggregate([row, failed])
        let returns = try XCTUnwrap(aggregate["unresolvedReturnContractLines"] as? [String: Any])
        XCTAssertEqual(returns["count"] as? Int, 2)
        XCTAssertEqual(returns["functions"] as? Int, 1)
        XCTAssertEqual((returns["top20"] as? [[String: Any]])?.first?["name"] as? String, "demo")
        for (key, count) in [("unmodeledInstructionLines", 1), ("rawBranches", 1),
                             ("indirectBranches", 1), ("flagCompareStatements", 1), ("rawIntrinsicStatements", 5)] {
            let metric = try XCTUnwrap(aggregate[key] as? [String: Any])
            XCTAssertEqual(metric["count"] as? Int, count, key)
            XCTAssertEqual(metric["functions"] as? Int, 1, key)
            let top = try XCTUnwrap(metric["top20"] as? [[String: Any]])
            XCTAssertEqual(top.count, 1, key)
            XCTAssertEqual(top.first?["name"] as? String, "demo", key)
            XCTAssertEqual(top.first?["count"] as? Int, count, key)
        }
        XCTAssertEqual(failed.counts["functionsFailed"], 1)
    }

    func testDeadLabelCastAndMemberMetricsWithoutBinary() throws {
        let sample = """
        int demo() {
        L_keep:
            goto L_keep;
        L_prefix:
            goto L_prefix_extra;
        L_shared:
            x = *(uint64_t *)(p) + *(unsigned int **)(q);
            x = p->one + p->two;
            // *(char *)(p) -> also counted on the exact canonical text
            return x;
        }
        """
        let row = CalleeWitnessOutputMetrics.extract(name: "demo", start: 16, text: sample)
        XCTAssertEqual(row.rawTextCounts, ["deadLabels": 2, "rawCastDerefs": 3, "memberAccesses": 3])
        // A goto in another function cannot rescue L_shared; prefix matches cannot rescue L_prefix.
        let other = CalleeWitnessOutputMetrics.extract(name: "other", start: 32,
            text: "int other() {\nL_keep:\n goto L_shared;\n return 0;\n}")
        XCTAssertEqual(other.rawTextCounts, ["deadLabels": 1, "rawCastDerefs": 0, "memberAccesses": 0])
        let aggregate = CalleeWitnessOutputMetrics.aggregate([row, other])
        for (key, functions) in [("deadLabels", 2), ("rawCastDerefs", 1), ("memberAccesses", 1)] {
            let metric = try XCTUnwrap(aggregate[key] as? [String: Any])
            XCTAssertEqual(metric["count"] as? Int, 3, key)
            XCTAssertEqual(metric["functions"] as? Int, functions, key)
        }
    }

    @MainActor
    func testWitnessHeaderLoadingWithoutBinary() throws {
        // Synthetic export identities exercise the same admission path as the
        // witness without opening or analyzing the installed libjpeg dylib.
        var analysis = ImageAnalysis()
        let names = ["jpeg_read_header", "jinit_master_decompress"]
        for (index, name) in names.enumerated() {
            let address = UInt64(0x1000 + index * 0x1000)
            analysis.exports.append(ExportSummary(id: UUID(), name: "_" + name,
                address: address, source: "export trie", terminalFlags: 0))
            analysis.functions.append(FunctionSummary(id: UUID(), name: name,
                startAddress: address, endAddress: address + 4, confidence: 1))
        }
        let snapshot = WorkspaceSnapshot(binaries: [BinaryImage(id: UUID(),
            name: "synthetic", path: "/synthetic", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis])
        let loaded = try CalleeWitnessHeaders.load(into: snapshot)
        XCTAssertEqual(loaded.headerNames, ["jpeglib.h", "jmorecfg.h", "jpegint.h"])
        XCTAssertEqual(loaded.summary.importedPrototypeCount, 2)
        XCTAssertEqual(loaded.snapshot.importedPrototypes[.primary(0x1000)]?.args.first?.type,
                       "struct jpeg_decompress_struct *")
        XCTAssertEqual(loaded.snapshot.importedPrototypes[.primary(0x2000)]?.args.first?.type,
                       "struct jpeg_decompress_struct *")
        for name in ["jpeg_decompress_struct", "jpeg_decomp_master"] {
            let definition = try XCTUnwrap(loaded.snapshot.typeDefinitions.first { $0.name == name })
            XCTAssertEqual(definition.kind, .struct)
            XCTAssertFalse(definition.fields.isEmpty, name)
        }
    }

    @MainActor
    func testLibjpegWarmExportWitness() throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_LIBJPEG_WITNESS"] == "1" else {
            throw XCTSkip("Set MACSCOPE_LIBJPEG_WITNESS=1 for the explicitly authorized libjpeg witness")
        }
        let path = "/opt/homebrew/lib/libjpeg.8.dylib"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("libjpeg witness input is absent") }
        let destination = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACSCOPE_LIBJPEG_WITNESS_DESTINATION"]
            ?? TestWorkRoot.scratchURL("libjpeg-witness.json").path)
        // Refuse accidental replay of this once-only witness, preserving its original receipt.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "LibjpegWitness", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Witness receipt already exists; do not repeat unchanged input"])
        }
        let captureContracts = ProcessInfo.processInfo.environment["MACSCOPE_RETURN_CONTRACT_TABLE"] == "1"
        return try MacIRConfiguration.$returnContractOverride.withValue(captureContracts ? true : MacIRConfiguration.returnContractOverride) {
            let began = Date()
            let loadedPointers = CalleeWitnessLoadedPointers()
            let analyzedSnapshot = try AnalysisEngine(binaryEnrichment: { loadedPointers.capture($0) }).analyze(url: URL(fileURLWithPath: path))
            let loadedHeaders = try CalleeWitnessHeaders.load(into: analyzedSnapshot)
            let snapshot = loadedHeaders.snapshot
            let slot = snapshot.primarySlot
            let analysis = try XCTUnwrap(snapshot.analysis(in: slot))
            var poison: MacIRIndirectTargetResolution.PoisonReport?
            var builtFunctions: [MacIRFunction] = []
            let report = try XCTUnwrap(snapshot.imageWideIndirectCalls(in: slot, compute: true, inspectFunctions: { functions in
                builtFunctions = functions
                poison = MacIRIndirectTargetResolution.poisonReport(functions: functions,
                    functionStarts: Set(analysis.functions.map(\.startAddress)))
            }), "A complete, uncancelled report within the 4096-function cap is required")
            let diagnostics = try XCTUnwrap(poison)
            let options = DecompilerOptions(userDefaults: .standard)
            let service = DocumentExportService()
            var typedNotes = 0
            var unresolvedLines = 0
            var unresolvedFunctions = 0
            var moved: [String: Int] = ["x0": 0, "w0": 0]
            var movedFunctions: [[String: Any]] = []
            let marker = "return unresolved_return_contract;"
            var outputRows: [CalleeWitnessOutputMetrics.Row] = []
            var allPseudocode = ""
            let returnFacts = CalleeWitnessReturnFacts.build(analysis: analysis, functions: builtFunctions,
                                                            decodedPointers: loadedPointers.read())
            var returnBreakdown: [[String: Any]] = []
            var returnBuckets: [String: Int] = [:]
            for function in analysis.functions {
                let input = snapshot.pseudocodeRenderInput(selectedAddress: function.startAddress, in: slot)
                // This is the exact method called by renderAllPseudocodeBlock after selection.
                XCTAssertEqual(input.startAddress, function.startAddress)
                let text = service.pseudocodeText(for: input, options: options)
                outputRows.append(CalleeWitnessOutputMetrics.extract(name: function.name, start: function.startAddress, text: text))
                let headerName = function.name.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
                allPseudocode += "// FUNCTION name=\(headerName) start=0x\(String(function.startAddress, radix: 16))\n" + text + "\n\n"
                typedNotes += text.components(separatedBy: "/* via struct ").count - 1
                let lines = text.components(separatedBy: .newlines).filter { $0.contains(marker) }.count
                unresolvedLines += lines
                if lines > 0 {
                    unresolvedFunctions += 1
                    var facts = try XCTUnwrap(returnFacts[function.startAddress])
                    facts["count"] = lines
                    returnBreakdown.append(facts)
                    let bucket = "exported=\(facts["exported"] as? Bool == true);addressTaken=\(facts["addressTaken"] as? Bool == true);directCallers>0=\((facts["directCallers"] as? Int ?? 0) > 0);callersUsingX0>0=\((facts["callersUsingX0"] as? Int ?? 0) > 0)"
                    returnBuckets[bucket, default: 0] += 1
                }
                if let width = input.callerReturnWidth, lines == 0 {
                    var withoutCaller = input
                    withoutCaller.callerReturnWidth = nil
                    if service.pseudocodeText(for: withoutCaller, options: options).contains(marker) {
                        let key = width == .w0 ? "w0" : "x0"
                        moved[key, default: 0] += 1
                        movedFunctions.append(["start": function.startAddress, "name": function.name, "width": key])
                    }
                }
            }
            let typed = report.resolutions.filter { if case .type = $0.scope { return true }; return false }.count
            var histogram: [String: Int] = [:]
            for query in diagnostics.typedQueryRefusals { histogram[query.reason, default: 0] += 1 }
            var writerHistogram: [String: Int] = [:]
            for function in diagnostics.functions {
                if let reason = function.firstRejectingReason { writerHistogram[reason, default: 0] += 1 }
            }
            let imports = diagnostics.importPoisonWriterCounts.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(20).map { ["symbol": $0.key, "writerFunctions": $0.value] as [String: Any] }
            let poisonJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics))
            let names = Dictionary(analysis.functions.map { ($0.startAddress, $0.name) }, uniquingKeysWith: { first, _ in first })
            func identities(_ starts: [UInt64]) -> [[String: Any]] {
                starts.map { ["start": $0, "name": names[$0] ?? ""] }
            }
            let unknownClasses: [[String: Any]] = diagnostics.unknownIRByClass.map { row in
                ["operationKind": row.classification.operationKind, "kind": row.classification.kind,
                 "mnemonic": row.classification.mnemonic, "instructions": row.instructions,
                 "functions": row.functions, "first": row.first,
                 "soleBlockerFunctionCount": row.soleBlockerFunctions.count,
                 "soleBlockerFunctions": identities(row.soleBlockerFunctions),
                 "flipIfModeledCount": row.flipIfModeled.count,
                 "flipIfModeled": identities(row.flipIfModeled)]
            }
            var escapeGroups: [String: [MacIRIndirectTargetResolution.FunctionPoison]] = [:]
            for function in diagnostics.functions where function.hasEscapedFrameWrite {
                guard let site = function.firstFrameEscape else { continue }
                escapeGroups[site.shape + "\t" + site.mnemonic, default: []].append(function)
            }
            let escapeShapes: [[String: Any]] = escapeGroups.sorted {
                $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
            }.map { _, functions in
                let site = functions[0].firstFrameEscape!
                return ["shape": site.shape, "mnemonic": site.mnemonic, "functions": functions.count,
                    "frameLocalOnlyFunctions": functions.filter { !$0.hasNonFrameStore }.count,
                    "firstWriterRejectionFunctions": functions.filter { $0.firstRejectingReason == "escaped frame" }.count,
                    "sites": functions.map { function -> [String: Any] in
                        let escape = function.firstFrameEscape!
                        return ["functionStart": function.functionStart, "name": names[function.functionStart] ?? "",
                            "address": escape.address, "instructionIndex": escape.instructionIndex,
                            "frameLocalOnly": !function.hasNonFrameStore,
                            "firstWriterRejection": function.firstRejectingReason == "escaped frame"]
                    }]
            }
            var outputMetrics = CalleeWitnessOutputMetrics.aggregate(outputRows)
            // Match `grep -c 'goto 0x' pseudocode-all.txt`: count matching lines
            // in the exact dump, including any comments, once per line.
            outputMetrics["rawAddressGotos"] = ["count": allPseudocode.components(separatedBy: "\n")
                .filter { $0.contains("goto 0x") }.count]
            outputMetrics["totalGotos"] = outputMetrics["gotos"]
            let receipt: [String: Any] = [
                "schemaVersion": 5,
                "priorBaseline": ["revision": "6467045e07201680028099c917f548c7ec2ba413",
                    "headers": "none",
                    "dumpSha256": "a2d8342a0c304cf37b94685016175ce0b1d110b141f9cd1cf8192510e303d9ef"],
                "importedHeaders": loadedHeaders.headerNames,
                "headerImport": ["version": "libjpeg-turbo 3.2.0", "jpegLibVersion": 80,
                    "path": "WorkspaceStore.defineTypesFromCHeader",
                    "preprocessing": loadedHeaders.headerSet.preprocessingDescription,
                    "headerSet": loadedHeaders.headerSet.rawValue,
                    "parsedPrototypeCount": loadedHeaders.parsedPrototypeCount,
                    "skippedPrototypes": loadedHeaders.skippedPrototypes,
                    "importedPrototypeCount": loadedHeaders.summary.importedPrototypeCount,
                    "addedTypeCount": loadedHeaders.summary.addedNames.count,
                    "structDefinitionCount": snapshot.typeDefinitions.filter { $0.kind == .struct }.count,
                    "skippedPrototypeCount": loadedHeaders.summary.skippedPrototypeCount,
                    "diagnostics": loadedHeaders.summary.diagnostics],
                "outputMetrics": outputMetrics,
                "pseudocodeReceipt": "pseudocode-all.txt",
                "unresolvedReturnBreakdown": ["functions": returnBreakdown, "bucketCounts": returnBuckets,
                    "method": "Exports plus external-defined symbols; exact-start non-BL xrefs, ADR/ADRP+ADD, loader-decoded pointers, aligned raw data pointer candidates and ObjC method implementations. Raw candidates are not relocation-backed proof; loader limitations remain. directCallers counts unique BL sites; callersUsingX0 reuses C2 collect per isolated BL seed with original operations/CFG. Buckets partition functions by exported/addressTaken and positive directCallers/callersUsingX0."], "input": path, "functions": analysis.functions.count,
                "sourceHead": ProcessInfo.processInfo.environment["MACSCOPE_WITNESS_SOURCE_HEAD"] ?? "unrecorded",
                "completeWarmImageReport": true, "cancelled": Task.isCancelled,
                "renderPath": "DocumentExportService.pseudocodeText (canonical Export All per-function renderer)",
                "options": String(describing: options), "nativeSleighExport": false,
                "typedResolvedCallSites": typed, "renderedTypedNotes": typedNotes,
                "unresolvedReturnLines": unresolvedLines, "unresolvedReturnFunctions": unresolvedFunctions,
                "callerEvidenceMovedFunctions": moved, "movedFunctions": movedFunctions,
                "typedQueryRefusalHistogram": histogram, "writerFirstRejectionHistogram": writerHistogram,
                "top20ImportSymbolsByWriterFunctions": imports, "poisonReport": poisonJSON,
                "attribution": "C2 renderer-only ablation clears callerReturnWidth on the same snapshot; no binary reload. Import counts are distinct transitive writer functions per symbolic opaque callee, not additive first-reason counts.",
                "unknownIRByClass": unknownClasses, "top25UnknownIRByClass": Array(unknownClasses.prefix(25)),
                "escapedFrameByShape": escapeShapes, "top25EscapedFrameByShape": Array(escapeShapes.prefix(25)),
                "ranking": "Unknown classes: functions descending, instructions descending, operationKind/kind/mnemonic ascending. Escapes: functions descending, shape/mnemonic ascending. Complete tables and function/site lists are retained.",
                "whatIf": "Remove only one class's unsupported-write veto and rerun the greatest call-visibility fixpoint over the same facts. Retain closed control flow, frame escapes, SP tracking, stores and opaque calls. No-memory-effect alone does not prove control-flow closure or non-escape. flipIfModeled includes newly visible transitive callers. soleBlockerFunctions excludes every non-frame store and escaped frame write; other visibility blockers may remain.",
                "escapePopulation": "All functions with at least one candidate frame-local write vetoed by escape, including mixed writes. Each row separately counts frame-local-only functions and functions whose first writer rejection is escaped frame (the W1 population).",
                "seconds": Date().timeIntervalSince(began)
            ]
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try allPseudocode.write(to: destination.deletingLastPathComponent().appendingPathComponent("pseudocode-all.txt"), atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
            if captureContracts {
                let table = try XCTUnwrap(snapshot.returnContractTable(in: slot, compute: false))
                XCTAssertFalse(table.report.capExceeded)
                if let slots = snapshot.slotTypedPrototypeReport(in: slot, compute: false) {
                    try JSONEncoder().encode(slots.callProofRows).write(to: destination.deletingLastPathComponent()
                        .appendingPathComponent("typed-slot-call-proofs.json"), options: .withoutOverwriting)
                    try JSONEncoder().encode(slots.refusals).write(to: destination.deletingLastPathComponent()
                        .appendingPathComponent("typed-slot-refusals.json"), options: .withoutOverwriting)
                }
                let reportData = try JSONEncoder().encode(table.report)
                try reportData.write(to: destination.deletingLastPathComponent()
                    .appendingPathComponent("return-contract-report.json"), options: .withoutOverwriting)
                let evidence = table.entries.keys.sorted().map { start -> [String: Any] in
                    let entry = table.entries[start]!
                    return ["start": start, "kind": String(describing: entry.kind),
                        "tier": entry.tier.map { String($0.rawValue) } ?? "unresolved",
                        "evidence": entry.evidence.map { ["source": $0.source.rawValue,
                            "at": $0.at.map(String.init) ?? "", "detail": $0.detail] }]
                }
                try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                    .write(to: destination.deletingLastPathComponent().appendingPathComponent("return-contract-evidence.json"),
                        options: .withoutOverwriting)
                print("RETURN_CONTRACT_TABLE_REPORT \(String(decoding: reportData, as: UTF8.self))")
            }
            print("LIBJPEG_WITNESS_RECEIPT \(destination.path)")
        }
    }
}

/// Fixture-only preprocessing supplies the same explicit ABI8 configuration as
/// H1. The user-facing import method owns parsing, type installation, prototype
/// admission and cache invalidation; no production caller gains implicit headers.
@MainActor
enum CalleeWitnessHeaders {
    enum HeaderSet: String {
        case standard = "default"
        case full

        static func selected(environment: [String: String]) throws -> Self {
            guard let value = environment["MACSCOPE_LIBJPEG_HEADER_SET"] else { return .standard }
            guard let result = Self(rawValue: value) else {
                throw NSError(domain: "LibjpegWitnessHeaders", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown libjpeg header set: \(value)"])
            }
            return result
        }

        var headerNames: [String] {
            let original = ["jpeglib.h", "jmorecfg.h", "jpegint.h"]
            switch self {
            case .standard: return original
            case .full: return original + ["src/jdct.h", "src/jmemsys.h", "src/jdhuff.h",
                "src/jchuff.h", "simd/jsimd.h", "simd/jsimddct.h", "simd/jsimdint.h",
                "src/jinclude.h", "src/jsamplecomp.h", "simd/jsimdconst.h"]
            }
        }

        var preprocessingDescription: String {
            switch self {
            case .standard: return "clang -E -P; public-layout.c then jpegint.h"
            case .full: return "clang -E -P; fixture-target-config.h, public-layout.c, isolated jinclude guard, full declarations; ABI8/LP64/ARM64"
            }
        }

        var prelude: String {
            switch self {
            case .standard:
                return "#include \"public-layout.c\"\n#include \"jpegint.h\"\n"
            case .full:
                // jsamplecomp.h uses BITS_IN_JSAMPLE=8 for its 8-bit mappings.
                // Target-only SIMD/word-size macros are documented separately
                // in fixture-target-config.h; they are not inferred from headers.
                return """
                #include "fixture-target-config.h"
                #include "public-layout.c"
                #define __JINCLUDE_H__
                #include "jpegint.h"
                #include "src/jdct.h"
                #include "src/jmemsys.h"
                #include "src/jdhuff.h"
                #include "src/jchuff.h"
                #include "simd/jsimd.h"
                #include "simd/jsimddct.h"
                #include "simd/jsimdint.h"

                """
            }
        }
    }

    struct Loaded {
        let snapshot: WorkspaceSnapshot
        let summary: WorkspaceStore.CHeaderImportSummary
        let headerSet: HeaderSet
        let parsedPrototypeCount: Int
        var headerNames: [String] { headerSet.headerNames }
        var skippedPrototypes: [String] {
            summary.diagnostics.filter {
                $0.hasPrefix("Skipped function prototype ") || $0.hasPrefix("Skipped prototype ")
                    || $0.hasPrefix("Skipped incompatible exported prototypes ")
            }
        }
    }

    static func preprocessed(headerSet: HeaderSet) throws -> String {
        let fixture = TestSourceRoot.url.appendingPathComponent("MacScope/Tests/CoreTests/Fixtures/libjpeg-turbo-3.2.0")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-E", "-P", "-x", "c", "-DJPEG_INTERNAL_OPTIONS", "-I", fixture.path, "-"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(headerSet.prelude.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LibjpegWitnessHeaders", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Clang failed to preprocess the pinned libjpeg header fixtures"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func load(into snapshot: WorkspaceSnapshot, headerSet: HeaderSet? = nil,
                     preprocessedSource: String? = nil) throws -> Loaded {
        let selected = try headerSet ?? HeaderSet.selected(environment: ProcessInfo.processInfo.environment)
        let source = try preprocessedSource ?? preprocessed(headerSet: selected)
        let parsed = CTypeHeaderParser.parse(source)
        let store = WorkspaceStore(workspaceName: "Libjpeg witness header import", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil)
        let summary = store.defineTypesFromCHeader(source)
        return Loaded(snapshot: store.snapshot, summary: summary, headerSet: selected,
                      parsedPrototypeCount: parsed.prototypes.count)
    }
}

/// Text-only metrics for the exact canonical render. No second printer invocation.
enum CalleeWitnessOutputMetrics {
    static let returnMarker = "return unresolved_return_contract;"
    static let typeSpellings = ["undefined", "undefined1", "undefined2", "undefined4", "undefined8",
        "undefined16", "unknown", "unknown_t", "__unknown", "__unknown_type", "unresolved_type",
        "placeholder_type", "auto"]
    static let indirectPattern = #"\(\*[^()\n]+\)\s*\("#
    static let gotoPattern = #"\bgoto\s+[^;\n]+;"#
    static let labelPattern = #"(?m)^\s*([A-Za-z_][A-Za-z_0-9]*|0x[0-9a-fA-F]+):\s*$"#
    static let deadLabelPattern = #"(?m)^\s*(L_[A-Za-z0-9_]+):"#
    static let rawCastDerefPattern = #"\*\([A-Za-z_][A-Za-z0-9_ ]* \*+\)\("#
    static func deadLabels(_ text: String) -> Int {
        let ns = text as NSString
        return matches(deadLabelPattern, text).filter { match in
            let name = ns.substring(with: match.range(at: 1))
            return matches(#"\bgoto\s+"# + name + #"\b"#, text).isEmpty
        }.count
    }
    static func rawCastDerefs(_ text: String) -> Int { matches(rawCastDerefPattern, text).count }
    static func memberAccesses(_ text: String) -> Int { matches("->", text).count }
    static let statementPatterns = [
        "unmodeledInstructionLines": #"(?m)^[ \t]*\b__unknown\s*\("#,
        "rawBranches": #"(?m)^[ \t]*\b__branch\s*\("#,
        "indirectBranches": #"(?m)^[ \t]*\b__branch_register\s*\("#,
        "flagCompareStatements": #"(?m)^[ \t]*\b__compare\s*\("#,
        "rawIntrinsicStatements": #"(?m)^[ \t]*\b(__[a-z][a-z0-9_]*)\s*\("#
    ]
    static let excludedRawIntrinsics: Set<String> = ["__adrp"]
    static let warningKinds = ["warning", "diagnostic", "unsupported", "unresolved", "unknown", "failed", "error"]
    struct Row {
        let name: String
        let start: UInt64
        let counts: [String: Int]
        // Exact-text metrics are separate from the established lexed counts.
        let rawTextCounts: [String: Int]
        let warnings: [String: Int]
        let observedTypes: Set<String>
    }
    static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    // Mask strings and comments while preserving newlines; marker-looking prose is not code.
    static func lex(_ text: String) -> (code: String, comments: [String]) {
        let chars = Array(text)
        var code = "", comments: [Int: String] = [:], index = 0, line = 0
        while index < chars.count {
            if chars[index] == "/", index + 1 < chars.count,
               chars[index + 1] == "/" || chars[index + 1] == "*" {
                let block = chars[index + 1] == "*"
                code += "  "; index += 2
                while index < chars.count {
                    if block, index + 1 < chars.count, chars[index] == "*", chars[index + 1] == "/" {
                        code += "  "; index += 2; break
                    }
                    if !block && chars[index] == "\n" { break }
                    comments[line, default: ""].append(chars[index])
                    code.append(chars[index] == "\n" ? "\n" : " ")
                    if chars[index] == "\n" { line += 1 }
                    index += 1
                }
                comments[line, default: ""] += " "
            } else if chars[index] == "\"" || chars[index] == "'" {
                let quote = chars[index]
                code.append(" "); index += 1
                while index < chars.count {
                    let char = chars[index]
                    code.append(char == "\n" ? "\n" : " "); index += 1
                    if char == "\n" { line += 1 }
                    if char == "\\", index < chars.count {
                        code.append(chars[index] == "\n" ? "\n" : " ")
                        if chars[index] == "\n" { line += 1 }
                        index += 1
                    } else if char == quote { break }
                }
            } else {
                code.append(chars[index])
                if chars[index] == "\n" { line += 1 }
                index += 1
            }
        }
        return (code, comments.keys.sorted().map { comments[$0]! })
    }
    static func extract(name: String, start: UInt64, text: String) -> Row {
        let (code, comments) = lex(text)
        let ns = code as NSString
        let typePattern = "(?:" + typeSpellings.joined(separator: "|") + ")"
        let declaration = #"\b("# + typePattern + #")\b\s*(?:\*\s*)*[A-Za-z_][A-Za-z_0-9]*(?:\s*\[[^\]\n]*\])?\s*(?=[,);=])"#
        let brace = ns.range(of: "{").location
        var localCount = 0, paramCount = 0, observed = Set<String>()
        let signatureEnd = brace == NSNotFound ? 0 : brace
        let openParen = ns.range(of: "(").location
        for match in matches(declaration, code) {
            if match.range.location < signatureEnd && openParen != NSNotFound && match.range.location > openParen {
                paramCount += 1
            } else if match.range.location > signatureEnd { localCount += 1 }
            else { continue }
            observed.insert(ns.substring(with: match.range(at: 1)))
        }
        var warnings: [String: Int] = [:]
        // One diagnostic bucket per rendered comment line, in this documented priority order.
        for comment in comments {
            if let kind = warningKinds.first(where: { !matches("(?i)\\b" + $0 + "\\b", comment).isEmpty }) {
                warnings[kind, default: 0] += 1
            }
        }
        let complete = brace != NSNotFound && code.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}")
        var counts = [
            "unresolvedReturnContractLines": text.components(separatedBy: .newlines).filter { $0.contains(returnMarker) }.count,
            "unresolvedIndirectCalls": matches(indirectPattern, code).count,
            "undefinedTypedLocals": localCount, "undefinedTypedParams": paramCount,
            "gotos": matches(gotoPattern, code).count, "labels": matches(labelPattern, code).count,
            "warnings": warnings.values.reduce(0, +), "functionsRendered": complete ? 1 : 0,
            "functionsFailed": complete ? 0 : 1
        ]
        for (key, pattern) in statementPatterns {
            counts[key] = matches(pattern, code).filter { match in
                key != "rawIntrinsicStatements" || !excludedRawIntrinsics.contains(ns.substring(with: match.range(at: 1)))
            }.count
        }
        return Row(name: name, start: start, counts: counts,
            rawTextCounts: ["deadLabels": deadLabels(text), "rawCastDerefs": rawCastDerefs(text),
                            "memberAccesses": memberAccesses(text)],
            warnings: warnings, observedTypes: observed)
    }
    static func aggregate(_ rows: [Row]) -> [String: Any] {
        func metric(_ value: (Row) -> Int) -> [String: Any] {
            let nonzero = rows.filter { value($0) > 0 }
            let top = nonzero.sorted { value($0) == value($1) ? $0.start < $1.start : value($0) > value($1) }
            return ["count": rows.reduce(0) { $0 + value($1) }, "functions": nonzero.count,
                "top20": top.prefix(20).map { ["name": $0.name, "start": $0.start, "count": value($0)] as [String: Any] }]
        }
        var result: [String: Any] = [:]
        for key in ["unresolvedReturnContractLines", "unresolvedIndirectCalls", "undefinedTypedLocals",
                    "undefinedTypedParams", "gotos", "labels", "warnings", "functionsRendered", "functionsFailed"] + statementPatterns.keys.sorted() {
            result[key] = metric { $0.counts[key, default: 0] }
        }
        for key in ["deadLabels", "rawCastDerefs", "memberAccesses"] {
            result[key] = metric { $0.rawTextCounts[key, default: 0] }
        }
        result["warningKinds"] = Dictionary(uniqueKeysWithValues: warningKinds.map { kind in
            (kind, metric { $0.warnings[kind, default: 0] })
        })
        result["typeSpellingsCounted"] = typeSpellings
        result["typeSpellingsObserved"] = Array(rows.reduce(into: Set<String>()) { $0.formUnion($1.observedTypes) }).sorted()
        result["method"] = ["structuredResults": "Unavailable from canonical pseudocodeText; no rerender for metrics",
            "unresolvedReturnMarker": returnMarker, "unresolvedIndirectCallRegex": indirectPattern,
            "gotoRegex": gotoPattern, "labelRegex": labelPattern,
            "deadLabelRegex": deadLabelPattern, "rawCastDerefRegex": rawCastDerefPattern,
            "exactTextMetrics": "deadLabels, rawCastDerefs and memberAccesses use exact canonical text per function, then sum; deadLabels excludes names targeted by whole-word goto in that function; rawCastDerefs and -> count occurrences, not lines; no string/comment masking",
            "codeStatementRegexes": statementPatterns,
            "rawIntrinsicStatementsExcludedCallees": excludedRawIntrinsics.sorted(),
            "codeStatements": "Standalone calls at the start of a rendered code line after indentation; strings/comments masked; assignments and nested calls excluded",
            "types": "undefinedTypedLocals and undefinedTypedParams count only typeSpellingsCounted in signature parameters or body declarations; MacIR emits concrete integer types, so these metrics are expected to be zero",
            "warnings": "Comment diagnostics only: whole-word case-insensitive warning-kind markers; first matching kind in warningKindsPriority wins; ordinary source/metadata comments excluded. MacIR emits unmodeled operations as code, so this metric is expected to be zero",
            "functionFailure": "Empty/missing-body or missing-final-brace output; nonthrowing canonical renderer has no separate error status",
            "lexing": "Strings and comments masked for code metrics; unresolvedReturnContractLines retains the original full-line contains computation",
            "baseline": "U2 head only; existing C2 width ablation cannot represent github/main without U2"]
        result["warningKindsPriority"] = warningKinds
        return result
    }
}

private final class CalleeWitnessLoadedPointers: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: Set<UInt64> = []
    func capture(_ binary: LoadedBinary) -> LoadedBinary {
        lock.lock(); defer { lock.unlock() }
        targets.formUnion(binary.codePointerTargets)
        return binary
    }
    func read() -> Set<UInt64> { lock.lock(); defer { lock.unlock() }; return targets }
}

private enum CalleeWitnessReturnFacts {
    static func address(_ text: String) -> UInt64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }
    static func build(analysis: ImageAnalysis, functions: [MacIRFunction], decodedPointers: Set<UInt64>) -> [UInt64: [String: Any]] {
        let starts = Set(analysis.functions.map(\.startAddress))
        let exports = Set(analysis.exports.compactMap(\.address)).union(
            analysis.symbols.filter { $0.kind == "export" }.compactMap(\.address))
        let rawCalls = Dictionary(grouping: analysis.instructions.filter { $0.mnemonic.lowercased() == "bl" }, by: \.address)
        var direct: [UInt64: Int] = [:], using: [UInt64: Int] = [:]
        for rows in rawCalls.values where rows.count == 1 {
            if let target = address(rows[0].operands), starts.contains(target) { direct[target, default: 0] += 1 }
        }
        // Reuse C2's exact walk, isolating one seed without changing any operations or CFG.
        // All other calls remain boundaries; only their numeric target seed is hidden.
        for function in functions {
            for instruction in function.instructions where instruction.source.mnemonic == "bl" {
                guard let rows = rawCalls[instruction.source.address], rows.count == 1,
                      let target = address(rows[0].operands), starts.contains(target),
                      case .call = instruction.operation else { continue }
                var caller = function
                for index in caller.instructions.indices where caller.instructions[index].source.mnemonic == "bl" {
                    caller.instructions[index].source.operands = caller.instructions[index].source.address == instruction.source.address
                        ? rows[0].operands : ""
                }
                var inputs = [caller]
                if target != caller.startAddress {
                    inputs.append(MacIRFunction(name: "witness_target", startAddress: target, instructions: []))
                }
                if MacIRCallerReturnEvidence.collect(functions: inputs)[target] != nil { using[target, default: 0] += 1 }
            }
        }
        var sources: [UInt64: Set<String>] = [:]
        func record(_ target: UInt64, _ source: String) {
            if starts.contains(target) { sources[target, default: []].insert(source) }
        }
        for target in decodedPointers { record(target, "loaderDecodedPointer") }
        let mnemonics = Dictionary(analysis.instructions.map { ($0.address, $0.mnemonic.lowercased()) }, uniquingKeysWith: { a, _ in a })
        for ref in analysis.xrefs where ref.kind != XRefKind.call && mnemonics[ref.from] != "bl" { record(ref.to, "nonBLXref") }
        for ref in DataCrossReferenceResolver().resolve(instructions: analysis.instructions,
            stringAddresses: starts, selectorSlots: [], dataRanges: []) {
            if mnemonics[ref.from] == "adr" || mnemonics[ref.from] == "add" { record(ref.to, "adrOrAdrpAdd") }
        }
        for item in analysis.objcClasses {
            for method in item.classMethods + item.instanceMethods { if let target = method.implementation { record(target, "methodTable") } }
        }
        for item in analysis.objcCategories {
            for method in item.classMethods + item.instanceMethods { if let target = method.implementation { record(target, "methodTable") } }
        }
        for item in analysis.objcProtocols {
            for method in item.requiredMethods + item.optionalMethods { if let target = method.implementation { record(target, "methodTable") } }
        }
        // Exact-start raw pointer candidates, bounded to this witness's file-backed data sections.
        let bytes = analysis.imageBytes
        for section in analysis.sections where !section.isExecutable && !section.isZeroFill {
            guard section.fileOffset < UInt64(bytes.count) else { continue }
            let size = min(section.size, section.fileSize ?? section.size, UInt64(bytes.count) - section.fileOffset)
            guard size >= 8 else { continue }
            let first = Int((8 - section.address % 8) % 8)
            for offset in stride(from: first, through: Int(size) - 8, by: 8) {
                let base = Int(section.fileOffset) + offset
                var target: UInt64 = 0
                for index in 0..<8 { target |= UInt64(bytes[base + index]) << (index * 8) }
                record(target, "alignedRawDataPointerCandidate")
            }
        }
        return Dictionary(uniqueKeysWithValues: analysis.functions.map { function in
            (function.startAddress, ["name": function.name, "start": function.startAddress,
                "exported": exports.contains(function.startAddress), "addressTaken": sources[function.startAddress] != nil,
                "addressTakenSources": Array(sources[function.startAddress] ?? []).sorted(),
                "directCallers": direct[function.startAddress, default: 0],
                "callersUsingX0": using[function.startAddress, default: 0]] as [String: Any])
        })
    }
}
