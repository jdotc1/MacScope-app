import XCTest
@testable import MacScope

final class ELFArchiveLoaderTests: XCTestCase {
    func testRouterRejectsThinArchiveWithTypedThinArchiveError() throws {
        let url = try temporaryFile(data: Data("!<thin>\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try BinaryLoaderRouter().load(at: url)) { error in
            XCTAssertEqual(
                error as? ELFArchiveLoadError,
                .parse(.thinArchiveUnsupported)
            )
        }
    }

    func testOrdinaryAndBSDLongNamesResolveWithoutPathTraversal() throws {
        let archive = makeArchive([
            ("normal.o/", makeMinimalELF()),
            ("#1/14", Data("../nested/evil".utf8) + makeMinimalELF()),
        ])
        let catalog = try ELFArchiveParser.parse(archive)
        XCTAssertEqual(catalog.members.map(\.name), ["normal.o", "evil"])
        XCTAssertTrue(catalog.members.allSatisfy(\.isELF))
    }

    func testBSDLongNamedSymbolTableMemberIsExcluded() throws {
        let specialName = Data("__.SYMDEF SORTED".utf8)
        let archive = makeArchive([
            ("#1/\(specialName.count)", specialName + Data("index".utf8)),
            ("real.o/", makeMinimalELF()),
        ])

        let catalog = try ELFArchiveParser.parse(archive)
        XCTAssertEqual(catalog.members.map(\.name), ["real.o"])
        XCTAssertEqual(catalog.members.map(\.index), [0])
        XCTAssertEqual(catalog.members.map(\.archiveHeaderIndex), [1])
    }

    func testGNULongNameTableAndReferenceResolve() throws {
        let longNames = Data("very-long-object-name.o/\n".utf8)
        let archive = makeArchive([
            ("//", longNames),
            ("/0", makeMinimalELF()),
        ])
        let catalog = try ELFArchiveParser.parse(archive)
        XCTAssertEqual(catalog.members.count, 1)
        XCTAssertEqual(catalog.members[0].name, "very-long-object-name.o")
    }

    func testGNUReferenceBeforeTableHasDeterministicSourceOrder() throws {
        let archive = makeArchive([
            ("first.o/", makeMinimalELF()),
            ("/0", makeMinimalELF()),
            ("//", Data("second-long-name.o/\n".utf8)),
            ("last.o/", makeMinimalELF()),
        ])

        let catalog = try ELFArchiveParser.parse(archive)
        XCTAssertEqual(catalog.members.map(\.name), [
            "first.o", "second-long-name.o", "last.o",
        ])
        XCTAssertEqual(catalog.members.map(\.archiveHeaderIndex), [0, 1, 3])
    }

    func testDuplicateGNULongNameTablesAreRejected() {
        let archive = makeArchive([
            ("//", Data("first.o/\n".utf8)),
            ("//", Data("second.o/\n".utf8)),
            ("/0", makeMinimalELF()),
        ])

        XCTAssertThrowsError(try ELFArchiveParser.parse(archive)) { error in
            XCTAssertEqual(
                error as? ELFArchiveParseError,
                .malformed("duplicate GNU long-name table")
            )
        }
    }

    func testGNUOffsetIntoMiddleOfNameIsRejected() {
        let archive = makeArchive([
            ("//", Data("first-long-name.o/\n".utf8)),
            ("/3", makeMinimalELF()),
        ])

        XCTAssertThrowsError(try ELFArchiveParser.parse(archive)) { error in
            XCTAssertEqual(
                error as? ELFArchiveParseError,
                .malformed("GNU long-name offset is not an entry boundary")
            )
        }
    }

    func testDuplicateSanitizedNamesRetainDistinctStableIndices() throws {
        let firstName = Data("one/repeated.o".utf8)
        let secondName = Data("two/repeated.o".utf8)
        let archive = makeArchive([
            ("#1/\(firstName.count)", firstName + makeMinimalELF()),
            ("#1/\(secondName.count)", secondName + makeMinimalELF()),
        ])

        let catalog = try ELFArchiveParser.parse(archive)
        XCTAssertEqual(catalog.members.map(\.name), ["repeated.o", "repeated.o"])
        XCTAssertEqual(catalog.members.map(\.index), [0, 1])
        XCTAssertEqual(catalog.members.map(\.archiveHeaderIndex), [0, 1])
    }

    func testOverflowingDecimalMemberSizeFailsClosed() {
        var archive = Data("!<arch>\n".utf8)
        archive.append(contentsOf: archiveHeader(
            name: "overflow.o/",
            sizeText: "9999999999"
        ).utf8)

        XCTAssertThrowsError(try ELFArchiveParser.parse(archive)) { error in
            XCTAssertEqual(
                error as? ELFArchiveParseError,
                .boundExceeded("member byte count at header 0")
            )
        }
    }

    func testMissingOddMemberPaddingFailsClosed() {
        var archive = makeArchive([("odd.txt/", Data([0x41]))])
        archive.removeLast()

        XCTAssertThrowsError(try ELFArchiveParser.parse(archive)) { error in
            XCTAssertEqual(
                error as? ELFArchiveParseError,
                .truncated("member alignment")
            )
        }
    }

    func testConfiguredArchiveAndMemberBudgetsFailClosed() {
        let archive = makeArchive([("a.o/", Data(repeating: 0, count: 8))])

        XCTAssertThrowsError(try ELFArchiveParser.parse(
            archive,
            limits: .init(maximumArchiveBytes: archive.count - 1)
        )) { error in
            XCTAssertEqual(error as? ELFArchiveParseError, .boundExceeded("archive byte count"))
        }
        XCTAssertThrowsError(try ELFArchiveParser.parse(
            archive,
            limits: .init(maximumMemberBytes: 7)
        )) { error in
            XCTAssertEqual(
                error as? ELFArchiveParseError,
                .boundExceeded("member byte count at header 0")
            )
        }
        XCTAssertThrowsError(try ELFArchiveParser.parse(
            archive,
            limits: .init(maximumAggregateMemberBytes: 7)
        )) { error in
            XCTAssertEqual(error as? ELFArchiveParseError, .boundExceeded("aggregate member bytes"))
        }
    }

    func testConfiguredMemberNameAndLongNameTableBudgetsFailClosed() {
        let bsdName = Data("long-name.o".utf8)
        let bsdArchive = makeArchive([
            ("#1/\(bsdName.count)", bsdName + Data([0])),
        ])
        XCTAssertThrowsError(try ELFArchiveParser.parse(
            bsdArchive,
            limits: .init(maximumNameBytes: bsdName.count - 1)
        ))

        let table = Data("long-name.o/\n".utf8)
        let gnuArchive = makeArchive([("//", table), ("/0", Data([0]))])
        XCTAssertThrowsError(try ELFArchiveParser.parse(
            gnuArchive,
            limits: .init(maximumLongNameTableBytes: table.count - 1)
        )) { error in
            XCTAssertEqual(error as? ELFArchiveParseError, .boundExceeded("GNU long-name table"))
        }
    }

    func testConfiguredMemberCountBudgetIncludesSpecialMembers() {
        let archive = makeArchive([
            ("/", Data("symbol-index".utf8)),
            ("one.o/", makeMinimalELF()),
        ])

        XCTAssertThrowsError(try ELFArchiveParser.parse(
            archive,
            limits: .init(maximumMembers: 1)
        )) { error in
            XCTAssertEqual(error as? ELFArchiveParseError, .boundExceeded("member count"))
        }
    }

    func testParserCancellationStopsCatalogScan() {
        let archive = makeArchive([
            ("one.o/", makeMinimalELF()),
            ("two.o/", makeMinimalELF()),
        ])
        var polls = 0

        XCTAssertThrowsError(try ELFArchiveParser.parse(
            archive,
            shouldCancel: {
                polls += 1
                return polls > 1
            }
        )) { error in
            XCTAssertEqual(error as? ELFArchiveParseError, .cancelled)
        }
    }

    func testParserCancellationInterruptsLargeMemberHashing() {
        var largeELF = makeMinimalELF()
        largeELF.append(Data(repeating: 0xa5, count: 512 * 1024))
        let archive = makeArchive([("large.o/", largeELF)])
        var polls = 0

        XCTAssertThrowsError(try ELFArchiveParser.parse(
            archive,
            shouldCancel: {
                polls += 1
                // Header scan and ordinary-member resolution consume the first two polls. The
                // fourth poll is the second 64-KiB member-hash chunk, proving hashing cooperates.
                return polls > 3
            }
        )) { error in
            XCTAssertEqual(error as? ELFArchiveParseError, .cancelled)
        }
        XCTAssertEqual(polls, 4)
    }

    func testParserCancellationInterruptsLargeContainerHashing() {
        let archive = makeArchive([(
            "large.txt/",
            Data(repeating: 0x5a, count: 512 * 1024)
        )])
        var polls = 0

        XCTAssertThrowsError(try ELFArchiveParser.parse(
            archive,
            shouldCancel: {
                polls += 1
                // A non-ELF member has no member digest. After header scan and member
                // resolution, the fourth poll is the second 64-KiB container-hash chunk.
                return polls > 3
            }
        )) { error in
            XCTAssertEqual(error as? ELFArchiveParseError, .cancelled)
        }
        XCTAssertEqual(polls, 4)
    }

    func testLoaderThreadsAnalysisCancellationIntoArchiveParser() throws {
        let url = try temporaryFile(data: makeArchive([
            ("one.o/", makeMinimalELF()),
            ("two.o/", makeMinimalELF()),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = ArchiveCancellationCounter(cancelAfterPoll: 1)
        let token = AnalysisCancellationToken { counter.isCancelled }

        XCTAssertThrowsError(try ELFArchiveBinaryLoader().load(at: url, cancellation: token)) {
            XCTAssertTrue($0 is AnalysisCancelled)
        }
    }

    func testSingleELFMemberAutoLoadsAndPreservesOuterPathAuthority() throws {
        let archive = makeArchive([
            ("note.txt/", Data("not elf".utf8)),
            ("only.o/", makeMinimalELF()),
        ])
        let url = try temporaryFile(data: archive)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try ELFArchiveBinaryLoader().load(at: url)
        XCTAssertEqual(loaded.name, "only.o")
        XCTAssertEqual(loaded.path, url.path)
        XCTAssertEqual(loaded.resolvedExecutablePath, url.path)
    }

    func testMultipleELFMembersRequireExplicitOrdinaryMemberSelection() throws {
        let archive = makeArchive([
            ("note.txt/", Data("not elf".utf8)),
            ("a.o/", makeMinimalELF()),
            ("b.o/", makeMinimalELF()),
        ])
        let url = try temporaryFile(data: archive)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ELFArchiveBinaryLoader().load(at: url)) { error in
            guard case ELFArchiveLoadError.selectionRequired(let options) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(options.map(\.index), [1, 2])
            XCTAssertEqual(options.map(\.name), ["a.o", "b.o"])
        }

        let options = try ELFArchiveBinaryLoader().catalog(at: url)
        let selected = try ELFArchiveBinaryLoader(selection: .init(
            container: try XCTUnwrap(options.first).containerIdentity,
            member: try XCTUnwrap(options.first(where: { $0.index == 2 })?.identity)
        )).load(at: url)
        XCTAssertEqual(selected.name, "b.o")
        XCTAssertEqual(selected.path, url.path)
    }

    func testSameIndexReplacementAndArchiveReorderingFailClosed() throws {
        let original = makeArchive([
            ("a.o/", makeMinimalELF(marker: 0x11)),
            ("b.o/", makeMinimalELF(marker: 0x22)),
        ])
        let url = try temporaryFile(data: original)
        defer { try? FileManager.default.removeItem(at: url) }

        let catalog = try ELFArchiveBinaryLoader().catalog(at: url)
        let chosen = try XCTUnwrap(catalog.first(where: { $0.index == 1 }))
        let selection = ELFArchiveMemberSelection(
            container: chosen.containerIdentity,
            member: chosen.identity
        )

        try makeArchive([
            ("a.o/", makeMinimalELF(marker: 0x11)),
            ("b.o/", makeMinimalELF(marker: 0x33)),
        ]).write(to: url)
        XCTAssertThrowsError(try ELFArchiveBinaryLoader(selection: selection).load(at: url)) {
            XCTAssertEqual($0 as? ELFArchiveLoadError, .containerIdentityMismatch)
        }

        try makeArchive([
            ("b.o/", makeMinimalELF(marker: 0x22)),
            ("a.o/", makeMinimalELF(marker: 0x11)),
        ]).write(to: url)
        XCTAssertThrowsError(try ELFArchiveBinaryLoader(selection: selection).load(at: url)) {
            XCTAssertEqual($0 as? ELFArchiveLoadError, .containerIdentityMismatch)
        }
    }

    func testMutationOfUnselectedMemberStillInvalidatesContainerSelection() throws {
        let url = try temporaryFile(data: makeArchive([
            ("a.o/", makeMinimalELF(marker: 0x11)),
            ("b.o/", makeMinimalELF(marker: 0x22)),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }
        let chosen = try XCTUnwrap(
            ELFArchiveBinaryLoader().catalog(at: url).first(where: { $0.index == 1 })
        )
        let selection = ELFArchiveMemberSelection(
            container: chosen.containerIdentity,
            member: chosen.identity
        )

        // Same selected member, same index and same offsets; only another member changed.
        try makeArchive([
            ("a.o/", makeMinimalELF(marker: 0x33)),
            ("b.o/", makeMinimalELF(marker: 0x22)),
        ]).write(to: url)
        XCTAssertThrowsError(try ELFArchiveBinaryLoader(selection: selection).load(at: url)) {
            XCTAssertEqual($0 as? ELFArchiveLoadError, .containerIdentityMismatch)
        }
    }

    func testInconsistentMemberIdentityIsRejectedEvenForCurrentContainer() throws {
        let url = try temporaryFile(data: makeArchive([
            ("a.o/", makeMinimalELF(marker: 0x11)),
            ("b.o/", makeMinimalELF(marker: 0x22)),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }
        let chosen = try XCTUnwrap(
            ELFArchiveBinaryLoader().catalog(at: url).first(where: { $0.index == 1 })
        )
        let forged = ELFArchiveMemberIdentity(
            index: chosen.identity.index,
            archiveHeaderIndex: chosen.identity.archiveHeaderIndex,
            name: chosen.identity.name,
            payloadOffset: chosen.identity.payloadOffset,
            byteCount: chosen.identity.byteCount,
            sha256: String(repeating: "0", count: 64)
        )

        XCTAssertThrowsError(try ELFArchiveBinaryLoader(selection: .init(
            container: chosen.containerIdentity,
            member: forged
        )).load(at: url)) {
            XCTAssertEqual($0 as? ELFArchiveLoadError, .memberIdentityMismatch)
        }
    }

    func testArchiveCatalogComputesExactContainerAndMemberHashesFromReadBytes() throws {
        let archive = makeArchive([("only.o/", makeMinimalELF(marker: 0x44))])
        let url = try temporaryFile(data: archive)
        defer { try? FileManager.default.removeItem(at: url) }

        let option = try XCTUnwrap(ELFArchiveBinaryLoader().catalog(at: url).first)
        XCTAssertEqual(option.containerIdentity.byteCount, archive.count)
        XCTAssertEqual(option.containerIdentity.sha256.count, 64)
        XCTAssertEqual(option.identity.sha256.count, 64)
        XCTAssertNotEqual(option.containerIdentity.sha256, option.identity.sha256)
    }

    func testArchiveSnapshotRejectsSourceGrowthDuringDescriptorRead() throws {
        var largeELF = makeMinimalELF()
        largeELF.append(Data(repeating: 0x5a, count: 512 * 1024))
        let url = try temporaryFile(data: makeArchive([("large.o/", largeELF)]))
        defer { try? FileManager.default.removeItem(at: url) }
        let mutation = ArchiveSnapshotGrowthMutation(url: url)

        XCTAssertThrowsError(try ELFArchiveBinaryLoader(
            snapshotReadObserver: mutation.observe(byteCount:)
        ).load(at: url)) { error in
            XCTAssertEqual(error as? ELFArchiveLoadError, .sourceChangedDuringRead)
        }
        XCTAssertTrue(mutation.didMutate)
    }

    func testArchiveSnapshotRejectsStableHardLinkedInput() throws {
        let url = try temporaryFile(data: makeArchive([
            ("only.o/", makeMinimalELF(marker: 0x90)),
        ]))
        let aliasURL = url.deletingLastPathComponent()
            .appendingPathComponent("macscope-elf-archive-hardlink-\(UUID().uuidString).a")
        defer {
            try? FileManager.default.removeItem(at: aliasURL)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.linkItem(at: url, to: aliasURL)

        XCTAssertThrowsError(try ELFArchiveBinaryLoader().load(at: url)) { error in
            XCTAssertEqual(error as? ELFArchiveLoadError, .multiplyLinkedSource)
        }
        XCTAssertThrowsError(try ELFArchiveBinaryLoader().catalog(at: aliasURL)) { error in
            XCTAssertEqual(error as? ELFArchiveLoadError, .multiplyLinkedSource)
        }
    }

    func testAnalysisEngineCarriesExactArchiveSelectionWithoutFabricatingMemberPath() throws {
        let url = try temporaryFile(data: makeArchive([
            ("a.o/", makeMinimalELF(marker: 0xc3)),
            ("b.o/", makeMinimalELF(marker: 0x90)),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }
        let option = try XCTUnwrap(
            ELFArchiveBinaryLoader().catalog(at: url).first(where: { $0.index == 0 })
        )
        let selection = ELFArchiveMemberSelection(
            container: option.containerIdentity,
            member: option.identity
        )

        let snapshot = try AnalysisEngine().analyze(
            url: url,
            selection: BinaryLoadSelection(elfArchiveMember: selection)
        )

        XCTAssertEqual(snapshot.binaries.first?.path, url.path)
        XCTAssertEqual(snapshot.binaries.first?.elfArchiveMemberIdentity, selection)
        XCTAssertNil(snapshot.binaries.first?.selectedSliceIndex)
        XCTAssertEqual(snapshot.imageBytes.count, option.byteCount)
    }

    func testLoaderOptionsRequireNilInitialChoiceForMultipleArchiveMembers() throws {
        let archive = makeArchive([
            ("duplicate.o/", makeMinimalELF(marker: 0x11)),
            ("duplicate.o/", makeMinimalELF(marker: 0x22)),
        ])
        let url = try temporaryFile(data: archive)
        defer { try? FileManager.default.removeItem(at: url) }

        var model = LoaderOptionsInspector().inspect(url: url)
        XCTAssertTrue(model.requiresChoice)
        XCTAssertTrue(model.isELFArchive)
        XCTAssertNil(model.selectedArchiveMemberIndex)
        XCTAssertNil(model.binaryLoadSelectionForLoad.elfArchiveMember)

        model.selectArchiveMember(index: 1)
        XCTAssertEqual(model.selectedArchiveMember?.index, 1)
        XCTAssertEqual(model.binaryLoadSelectionForLoad.elfArchiveMember?.member.index, 1)
    }

    @MainActor
    func testArchivePickerInspectionRunsOffMainActor() async {
        let harness = ArchivePickerInspectionHarness()
        let inspector = LoaderOptionsInspector { url, shouldCancel in
            harness.inspect(url: url, shouldCancel: shouldCancel)
        }
        let store = makeArchiveInspectionStore(inspector: inspector)
        let url = URL(fileURLWithPath: "/tmp/off-main-inspection.a")

        store.beginImport(url: url)
        await Task.detached { harness.waitUntilEntered(url) }.value

        XCTAssertEqual(
            harness.didRunOnMainThread(url),
            false,
            "mapping, parsing, and hashing an archive for the picker must not hold the main actor"
        )
        harness.release(url)
        await store.awaitPendingLoaderOptionsInspection()
        XCTAssertEqual(store.loaderOptionsRequest?.url, url)
    }

    @MainActor
    func testSupersededArchiveInspectionCannotPublishStalePicker() async {
        let harness = ArchivePickerInspectionHarness()
        let inspector = LoaderOptionsInspector { url, shouldCancel in
            harness.inspect(url: url, shouldCancel: shouldCancel)
        }
        let store = makeArchiveInspectionStore(inspector: inspector)
        let staleURL = URL(fileURLWithPath: "/tmp/stale-inspection.a")
        let currentURL = URL(fileURLWithPath: "/tmp/current-inspection.a")

        store.beginImport(url: staleURL)
        await Task.detached { harness.waitUntilEntered(staleURL) }.value
        store.beginImport(url: currentURL)
        await Task.detached { harness.waitUntilEntered(currentURL) }.value

        harness.release(currentURL)
        await store.awaitPendingLoaderOptionsInspection()
        XCTAssertEqual(store.loaderOptionsRequest?.url, currentURL)

        // The first operation observes cancellation and completes after the current picker has
        // published. Its stale result must remain inert.
        await Task.detached { harness.waitUntilFinished(staleURL) }.value
        await Task.yield()
        XCTAssertEqual(store.loaderOptionsRequest?.url, currentURL)
    }

    @MainActor
    func testCancelledArchiveInspectionCannotPublishPickerOrStartLoad() async {
        let harness = ArchivePickerInspectionHarness()
        let inspector = LoaderOptionsInspector { url, shouldCancel in
            harness.inspect(url: url, shouldCancel: shouldCancel)
        }
        let store = makeArchiveInspectionStore(inspector: inspector)
        let url = URL(fileURLWithPath: "/tmp/cancelled-inspection.a")

        store.beginImport(url: url)
        await Task.detached { harness.waitUntilEntered(url) }.value
        store.cancelLoaderOptions()

        await Task.detached { harness.waitUntilFinished(url) }.value
        await Task.yield()
        XCTAssertNil(store.loaderOptionsRequest)
        XCTAssertTrue(store.snapshot.binaries.isEmpty)
        XCTAssertFalse(store.isImporting)
    }

    func testWireCodecRoundTripsExactArchiveMemberSelection() throws {
        let container = ELFArchiveContainerIdentity(byteCount: 512, sha256: String(repeating: "a", count: 64))
        let member = ELFArchiveMemberIdentity(
            index: 3,
            archiveHeaderIndex: 7,
            name: "same.o",
            payloadOffset: 128,
            byteCount: 256,
            sha256: String(repeating: "b", count: 64)
        )
        let expected = BinaryLoadSelection(
            elfArchiveMember: ELFArchiveMemberSelection(container: container, member: member)
        )
        let codec = PayloadWireCodec()
        let requestID = UUID()
        let data = codec.encodeRequest(
            url: URL(fileURLWithPath: "/tmp/library.a"),
            selection: expected,
            overrides: [:],
            requestID: requestID
        )

        let decoded = try codec.decodeRequest(data)
        XCTAssertEqual(decoded.selection, expected)
        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.url.path, "/tmp/library.a")
    }

    func testDualSliceAndArchiveSelectorsAreRejectedAtTypedConstructionAndWireDecode() throws {
        let container = ELFArchiveContainerIdentity(
            byteCount: 512,
            sha256: String(repeating: "a", count: 64)
        )
        let member = ELFArchiveMemberIdentity(
            index: 0,
            archiveHeaderIndex: 0,
            name: "member.o",
            payloadOffset: 68,
            byteCount: 256,
            sha256: String(repeating: "b", count: 64)
        )
        let archiveSelection = ELFArchiveMemberSelection(container: container, member: member)

        XCTAssertThrowsError(try BinaryLoadSelection(
            validatingRequestedMachOSliceIndex: 1,
            elfArchiveMember: archiveSelection
        )) {
            XCTAssertEqual($0 as? BinaryLoadSelectionError, .conflictingSelectors)
        }

        let codec = PayloadWireCodec()
        let validArchiveWire = codec.encodeRequest(
            url: URL(fileURLWithPath: "/tmp/library.a"),
            selection: BinaryLoadSelection(elfArchiveMember: archiveSelection),
            overrides: [:],
            requestID: UUID()
        )
        var mutatedEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validArchiveWire) as? [String: Any]
        )
        mutatedEnvelope["requestedSliceIndex"] = 1
        let dualSelectorWire = try JSONSerialization.data(withJSONObject: mutatedEnvelope)

        XCTAssertThrowsError(try codec.decodeRequest(dualSelectorWire)) {
            XCTAssertEqual($0 as? BinaryLoadSelectionError, .conflictingSelectors)
        }
    }

    func testBadMemberTerminatorFailsClosed() {
        var archive = makeArchive([("a.o/", makeMinimalELF())])
        archive[8 + 58] = 0
        XCTAssertThrowsError(try ELFArchiveParser.parse(archive))
    }

    private func makeArchive(_ members: [(String, Data)]) -> Data {
        var result = Data("!<arch>\n".utf8)
        for (name, payload) in members {
            let header = archiveHeader(name: name, sizeText: String(payload.count))
            XCTAssertEqual(header.utf8.count, 60)
            result.append(contentsOf: header.utf8)
            result.append(payload)
            if payload.count.isMultiple(of: 2) == false { result.append(0x0a) }
        }
        return result
    }

    private func archiveHeader(name: String, sizeText: String) -> String {
        name.padding(toLength: 16, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 12, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "100644".padding(toLength: 8, withPad: " ", startingAt: 0)
            + sizeText.padding(toLength: 10, withPad: " ", startingAt: 0)
            + "`\n"
    }

    /// A sectionless ET_EXEC ELF64 with one executable PT_LOAD; sufficient to exercise archive
    /// routing without duplicating the full section-table fixtures. Sectionless ET_REL is
    /// intentionally invalid: ordinary relocatable archive members use the section-table path.
    private func makeMinimalELF(marker: UInt8 = 0xc3) -> Data {
        var data = Data(repeating: 0, count: 0x1004)
        data.replaceSubrange(0..<16, with: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 8))
        data.writeLE(UInt16(2), at: 16)
        data.writeLE(UInt16(62), at: 18)
        data.writeLE(UInt32(1), at: 20)
        data.writeLE(UInt64(0x1000), at: 24)
        data.writeLE(UInt64(64), at: 32)
        data.writeLE(UInt64(0), at: 40)
        data.writeLE(UInt16(64), at: 52)
        data.writeLE(UInt16(56), at: 54)
        data.writeLE(UInt16(1), at: 56)
        data.writeLE(UInt32(1), at: 64)
        data.writeLE(UInt32(5), at: 68)
        data.writeLE(UInt64(0x1000), at: 72)
        data.writeLE(UInt64(0x1000), at: 80)
        data.writeLE(UInt64(0x1000), at: 88)
        data.writeLE(UInt64(4), at: 96)
        data.writeLE(UInt64(4), at: 104)
        data.writeLE(UInt64(0x1000), at: 112)
        data.replaceSubrange(0x1000..<0x1004, with: [marker, 0, 0, 0])
        return data
    }

    private func temporaryFile(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-elf-archive-\(UUID().uuidString).a")
        try data.write(to: url)
        return url
    }

    @MainActor
    private func makeArchiveInspectionStore(inspector: LoaderOptionsInspector) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "archive-inspection",
            snapshot: WorkspaceSnapshot(
                binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil,
            loaderOptionsInspector: inspector
        )
    }
}

private final class ArchivePickerInspectionHarness: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered: Set<URL> = []
    private var finished: Set<URL> = []
    private var released: Set<URL> = []
    private var mainThreadResults: [URL: Bool] = [:]

    func inspect(
        url: URL,
        shouldCancel: LoaderOptionsInspector.CancellationCheck
    ) -> LoaderOptionsModel {
        condition.lock()
        entered.insert(url)
        mainThreadResults[url] = Thread.isMainThread
        condition.broadcast()
        while !released.contains(url), !shouldCancel() {
            _ = condition.wait(until: Date().addingTimeInterval(0.01))
        }
        finished.insert(url)
        condition.broadcast()
        condition.unlock()
        return Self.model(fileName: url.lastPathComponent)
    }

    func waitUntilEntered(_ url: URL) {
        condition.lock()
        defer { condition.unlock() }
        while !entered.contains(url) { condition.wait() }
    }

    func waitUntilFinished(_ url: URL) {
        condition.lock()
        defer { condition.unlock() }
        while !finished.contains(url) { condition.wait() }
    }

    func release(_ url: URL) {
        condition.lock()
        released.insert(url)
        condition.broadcast()
        condition.unlock()
    }

    func didRunOnMainThread(_ url: URL) -> Bool? {
        condition.lock()
        defer { condition.unlock() }
        return mainThreadResults[url]
    }

    private static func model(fileName: String) -> LoaderOptionsModel {
        let container = ELFArchiveContainerIdentity(
            byteCount: 256,
            sha256: String(repeating: "a", count: 64)
        )
        let members = (0..<2).map { index in
            ELFArchiveMemberSummary(
                containerIdentity: container,
                identity: ELFArchiveMemberIdentity(
                    index: index,
                    archiveHeaderIndex: index,
                    name: "member-\(index).o",
                    payloadOffset: 68 + index * 64,
                    byteCount: 4,
                    sha256: String(repeating: index == 0 ? "b" : "c", count: 64)
                )
            )
        }
        return LoaderOptionsModel(
            fileName: fileName,
            formatDescription: "Unix archive — 2 ELF members",
            slices: [],
            archiveMembers: members
        )
    }
}

private final class ArchiveCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterPoll: Int
    private var polls = 0

    init(cancelAfterPoll: Int) {
        self.cancelAfterPoll = cancelAfterPoll
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        polls += 1
        return polls > cancelAfterPoll
    }
}

private final class ArchiveSnapshotGrowthMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var hasMutated = false

    init(url: URL) {
        self.url = url
    }

    func observe(byteCount: Int) {
        guard byteCount >= 64 * 1024 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !hasMutated else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x7f]))
            try handle.synchronize()
            hasMutated = true
        } catch {
            return
        }
    }

    var didMutate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasMutated
    }
}

private extension Data {
    mutating func writeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        let width = MemoryLayout<T>.size
        let bytes = (0..<width).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
        replaceSubrange(offset..<(offset + width), with: bytes)
    }
}
