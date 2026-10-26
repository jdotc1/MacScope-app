import XCTest
@testable import MacScope

final class ApplicationImageGraphTests: XCTestCase {
    func testGraphIncludesLoadedWorkspaceImages() {
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/App.app/Contents/MacOS/Main", slot: .primary),
                binary(name: "Helper", path: "/tmp/App.app/Contents/MacOS/Helper", slot: ImageSlot(rawValue: 2))
            ],
            analyses: [:]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.nodes.map(\.id), ["workspace:0", "workspace:2"])
        XCTAssertEqual(graph.nodes.map(\.displayName), ["Main", "Helper"])
        XCTAssertTrue(graph.edges.isEmpty)
    }

    func testDeclaredDependencyEdgeResolvesExactLoadedImagePath() {
        let frameworkPath = "/tmp/App.app/Contents/Frameworks/F.framework/F"
        let frameworkSlot = ImageSlot(rawValue: 1)
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/App.app/Contents/MacOS/Main", slot: .primary),
                binary(name: "F", path: "/tmp/source/F.framework/F", resolvedExecutablePath: frameworkPath, slot: frameworkSlot)
            ],
            analyses: [
                .primary: analysis(dependencies: [
                    dependency(path: frameworkPath, kind: "required", ordinal: 1)
                ]),
                frameworkSlot: ImageAnalysis()
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges[0].fromSlot, .primary)
        XCTAssertEqual(graph.edges[0].toNodeID, "workspace:1")
        XCTAssertEqual(graph.edges[0].rawPath, frameworkPath)
        XCTAssertEqual(graph.edges[0].loadKind, "required")
        XCTAssertEqual(graph.edges[0].resolution, .resolvedWorkspaceImage(frameworkSlot))
    }

    func testSystemAbsoluteDependencyBecomesExternalSystemNode() {
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/Main", slot: .primary)
            ],
            analyses: [
                .primary: analysis(dependencies: [
                    dependency(path: "/usr/lib/libSystem.B.dylib", kind: "required", ordinal: 1),
                    dependency(path: "/System/Library/Frameworks/AppKit.framework/AppKit", kind: "required", ordinal: 2)
                ])
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.edges.map(\.resolution), [
            .external("/usr/lib/libSystem.B.dylib"),
            .external("/System/Library/Frameworks/AppKit.framework/AppKit")
        ])
        XCTAssertTrue(graph.nodes.contains {
            $0.id == "external-system:/usr/lib/libSystem.B.dylib"
                && $0.kind == .externalSystemImage
        })
        XCTAssertTrue(graph.nodes.contains {
            $0.id == "external-system:/System/Library/Frameworks/AppKit.framework/AppKit"
                && $0.kind == .externalSystemImage
        })
    }

    func testTokenizedDependencyRemainsUnresolvedInV0() {
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/Main", slot: .primary)
            ],
            analyses: [
                .primary: analysis(dependencies: [
                    dependency(path: "@rpath/Foo.framework/Foo", kind: "required", ordinal: 1),
                    dependency(path: "@loader_path/../Frameworks/Bar.framework/Bar", kind: "weak", ordinal: 2)
                ])
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.edges.map(\.resolution), [
            .unresolved("@rpath/Foo.framework/Foo"),
            .unresolved("@loader_path/../Frameworks/Bar.framework/Bar")
        ])
        XCTAssertEqual(
            graph.nodes.filter {
                if case .unresolvedDependency = $0.kind { return true }
                return false
            }.map(\.id),
            [
                "unresolved:0:1:@rpath/Foo.framework/Foo",
                "unresolved:0:2:@loader_path/../Frameworks/Bar.framework/Bar"
            ]
        )
    }

    func testWeakAndReexportKindsArePreserved() {
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/Main", slot: .primary)
            ],
            analyses: [
                .primary: analysis(dependencies: [
                    dependency(path: "/tmp/Weak.dylib", kind: "weak", ordinal: 2),
                    dependency(path: "/tmp/Reexport.dylib", kind: "reexport", ordinal: 1)
                ])
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.edges.map(\.ordinal), [1, 2])
        XCTAssertEqual(graph.edges.map(\.loadKind), ["reexport", "weak"])
        XCTAssertEqual(graph.edges.map(\.resolution), [
            .external("/tmp/Reexport.dylib"),
            .external("/tmp/Weak.dylib")
        ])
    }

    func testDuplicateLoadedDependencyPathRemainsUnresolvedInsteadOfChoosingWrongSlot() {
        let duplicatePath = "/tmp/App.app/Contents/Frameworks/Duplicate.framework/Duplicate"
        let firstSlot = ImageSlot(rawValue: 1)
        let secondSlot = ImageSlot(rawValue: 2)
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/App.app/Contents/MacOS/Main", slot: .primary),
                binary(name: "CopyA", path: duplicatePath, slot: firstSlot),
                binary(name: "CopyB", path: duplicatePath, slot: secondSlot)
            ],
            analyses: [
                .primary: analysis(dependencies: [
                    dependency(path: duplicatePath, kind: "required", ordinal: 1)
                ]),
                firstSlot: ImageAnalysis(),
                secondSlot: ImageAnalysis()
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges[0].resolution, .unresolved(duplicatePath))
        XCTAssertEqual(graph.edges[0].toNodeID, "unresolved:0:1:\(duplicatePath)")
    }

    func testResolvedExecutablePathCollisionRemainsUnresolved() {
        let executablePath = "/tmp/App.app/Contents/Frameworks/F.framework/F"
        let firstSlot = ImageSlot(rawValue: 1)
        let secondSlot = ImageSlot(rawValue: 2)
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/App.app/Contents/MacOS/Main", slot: .primary),
                binary(name: "SourceA", path: "/tmp/source-a/F", resolvedExecutablePath: executablePath, slot: firstSlot),
                binary(name: "SourceB", path: "/tmp/source-b/F", resolvedExecutablePath: executablePath, slot: secondSlot)
            ],
            analyses: [
                .primary: analysis(dependencies: [
                    dependency(path: executablePath, kind: "required", ordinal: 1)
                ]),
                firstSlot: ImageAnalysis(),
                secondSlot: ImageAnalysis()
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges[0].resolution, .unresolved(executablePath))
        XCTAssertEqual(graph.edges[0].toNodeID, "unresolved:0:1:\(executablePath)")
    }

    func testPathAndResolvedExecutableCrossCollisionRemainsUnresolved() {
        let sharedPath = "/tmp/App.app/Contents/Frameworks/F.framework/F"
        let resolvedSlot = ImageSlot(rawValue: 1)
        let directPathSlot = ImageSlot(rawValue: 2)
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/App.app/Contents/MacOS/Main", slot: .primary),
                binary(name: "Resolved", path: "/tmp/source/F", resolvedExecutablePath: sharedPath, slot: resolvedSlot),
                binary(name: "Direct", path: sharedPath, slot: directPathSlot)
            ],
            analyses: [
                .primary: analysis(dependencies: [
                    dependency(path: sharedPath, kind: "required", ordinal: 1)
                ]),
                resolvedSlot: ImageAnalysis(),
                directPathSlot: ImageAnalysis()
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges[0].resolution, .unresolved(sharedPath))
        XCTAssertEqual(graph.edges[0].toNodeID, "unresolved:0:1:\(sharedPath)")
    }

    func testGraphOmitsDependencyEdgesForImagesWithoutMachOMetadataWithoutFailing() {
        let slot = ImageSlot(rawValue: 1)
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/Main", slot: .primary),
                binary(name: "Data", path: "/tmp/Data", kind: "data", slot: slot)
            ],
            analyses: [
                .primary: ImageAnalysis(),
                slot: ImageAnalysis()
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.nodes.map(\.id), ["workspace:0", "workspace:1"])
        XCTAssertTrue(graph.edges.isEmpty)
    }

    func testDependencyOrderingUsesStableLexicalPathTieBreak() {
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/Main", slot: .primary)
            ],
            analyses: [
                .primary: analysis(dependencies: [
                    dependency(path: "/tmp/z.dylib", kind: "required", ordinal: 1),
                    dependency(path: "/tmp/a.dylib", kind: "required", ordinal: 1)
                ])
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)

        XCTAssertEqual(graph.edges.map(\.rawPath), ["/tmp/a.dylib", "/tmp/z.dylib"])
    }

    func testGraphPresentationSummarizesResolvedExternalAndUnresolvedDetails() {
        let frameworkPath = "/tmp/App.app/Contents/Frameworks/F.framework/F"
        let frameworkSlot = ImageSlot(rawValue: 1)
        let snapshot = makeSnapshot(
            binaries: [
                binary(name: "Main", path: "/tmp/App.app/Contents/MacOS/Main", slot: .primary),
                binary(name: "F", path: "/tmp/source/F.framework/F", resolvedExecutablePath: frameworkPath, slot: frameworkSlot)
            ],
            analyses: [
                .primary: analysis(dependencies: [
                    dependency(path: frameworkPath, kind: "required", ordinal: 1),
                    dependency(path: "/usr/lib/libSystem.B.dylib", kind: "required", ordinal: 2),
                    dependency(path: "@rpath/Missing.framework/Missing", kind: "weak", ordinal: 3)
                ]),
                frameworkSlot: ImageAnalysis()
            ]
        )

        let graph = ApplicationImageGraphBuilder().build(from: snapshot)
        let presentation = ApplicationImageGraphPresentation(graph: graph)

        XCTAssertEqual(presentation.summaryText, "4 image nodes, 3 declared dependencies")
        XCTAssertEqual(
            presentation.resolutionRows.map { "\($0.value) \($0.label)" },
            ["1 resolved", "1 external", "1 unresolved"]
        )
        XCTAssertEqual(
            presentation.workspaceRows.map { "\($0.title): \($0.edgeSummary)" },
            ["Main: 3 outgoing", "F: 0 outgoing"]
        )
        XCTAssertEqual(
            presentation.edgeRows.map(\.resolutionTitle),
            ["resolved in workspace", "external", "unresolved"]
        )
        XCTAssertEqual(presentation.edgeRows[0].sourceTitle, "Main")
        XCTAssertEqual(presentation.edgeRows[0].targetTitle, "F")
        XCTAssertEqual(presentation.unresolvedRows.count, 1)
        XCTAssertEqual(
            presentation.unresolvedRows[0].sourceToTarget,
            "Main → @rpath/Missing.framework/Missing"
        )
        XCTAssertEqual(
            presentation.unresolvedRows[0].reason,
            "Tokenized loader path; v0 does not resolve @rpath/@loader_path."
        )
    }

    private func makeSnapshot(
        binaries: [BinaryImage],
        analyses: [ImageSlot: ImageAnalysis]
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(binaries: binaries, analysisBySlot: analyses)
    }

    private func binary(
        name: String,
        path: String,
        kind: String = "Mach-O executable",
        resolvedExecutablePath: String? = nil,
        slot: ImageSlot
    ) -> BinaryImage {
        BinaryImage(
            id: UUID(),
            name: name,
            path: path,
            kind: kind,
            architecture: "arm64",
            resolvedExecutablePath: resolvedExecutablePath,
            slot: slot
        )
    }

    private func analysis(
        dependencies: [MachOLoadMetadata.DependentDylib]
    ) -> ImageAnalysis {
        var result = ImageAnalysis()
        result.machOMetadata = MachOLoadMetadata(
            codeSignature: nil,
            importedSymbols: [],
            dependentDylibs: dependencies
        )
        return result
    }

    private func dependency(
        path: String,
        kind: String,
        ordinal: Int
    ) -> MachOLoadMetadata.DependentDylib {
        MachOLoadMetadata.DependentDylib(
            path: path,
            kind: kind,
            currentVersion: "1.0.0",
            compatibilityVersion: "1.0.0",
            ordinal: ordinal
        )
    }
}
