import AppKit
import SwiftUI
import XCTest
import LumenUI
import LumenTokens
@testable import MacScope

/// Offscreen PNG renders of new UI for visual review (never goldens, never compared).
/// Written to `MACSCOPE_UI_SHOTS_DIR` (pass it as `TEST_RUNNER_MACSCOPE_UI_SHOTS_DIR`), else to
/// a temporary directory; each test prints the paths it wrote.
@MainActor
enum UIReviewShots {
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["MACSCOPE_UI_SHOTS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("MacScopeUIShots-\(UUID().uuidString)", isDirectory: true)
    }

    /// Renders `view` at `size` in every DS snapshot variant and returns the written file URLs.
    @discardableResult
    static func write<V: View>(_ name: String, size: CGSize, variants: [DSSnapshot.Variant] = [
        DSSnapshot.Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .light),
        DSSnapshot.Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .dark),
    ], @ViewBuilder _ view: () -> V) throws -> [URL] {
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let subject = DSSnapshot.Subject(name: name, size: size, view: AnyView(view().lumenRendersOffscreen(true)))
        var written: [URL] = []
        for variant in variants {
            let png = try XCTUnwrap(DSSnapshot.png(of: subject, in: variant), "render failed for \(name)")
            let url = directory.appendingPathComponent("\(name)-\(variant.label).png")
            try png.write(to: url)
            written.append(url)
            print("UI review shot: \(url.path)")
        }
        return written
    }
}

final class LoaderCacheImagePickerShotTests: XCTestCase {
    private static let images = LoaderCacheImageOption.pickerOptions(from: [
        "/usr/lib/libSystem.B.dylib",
        "/usr/lib/libobjc.A.dylib",
        "/usr/lib/libc++.1.dylib",
        "/usr/lib/system/libsystem_kernel.dylib",
        "/usr/lib/system/libdispatch.dylib",
        "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
    ].enumerated().map { DyldCacheImage(address: 0x1_8000_0000 + UInt64($0.offset) * 0x10000, pathFileOffset: 0, path: $0.element) })

    @MainActor
    func testRenderCacheImagePickerForReview() throws {
        var model = LoaderOptionsModel(fileName: "dyld_shared_cache_arm64e",
                                       formatDescription: "dyld shared cache (arm64e) — 9 images",
                                       slices: [], cacheImages: Self.images)
        model.selectCacheImage(installName: "/usr/lib/libobjc.A.dylib")
        let store = WorkspaceStore(workspaceName: "Shots", snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
                                   engine: AnalysisEngine())
        let request = LoaderOptionsRequest(url: URL(fileURLWithPath: "/tmp/dyld_shared_cache_arm64e"), model: model)
        let sheet = try UIReviewShots.write("dyld-picker-sheet", size: CGSize(width: 560, height: 520)) {
            LoaderOptionsSheet(request: request, store: store)
        }
        // `LumenSourceList` scrolls, and a scroll view can't be drawn offscreen (the sheet render
        // above shows its frame empty). These renders draw the same rows with the same
        // `LumenListRow` the source list uses, unfiltered and filtered, so the rows can be reviewed.
        func rows(_ query: String) -> some View {
            VStack(alignment: .leading, spacing: Lumen.Space.s3) {
                LumenTextField("Filter by install name", text: .constant(query), monospaced: true)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(LoaderCacheImageOption.filter(model.cacheImages, query: query)) { image in
                        LumenListRow(image.fileName, detail: image.directory, systemImage: "shippingbox",
                                     isSelected: image.installName == model.selectedCacheImagePath, context: .sidebar)
                    }
                }
                .padding(Lumen.Space.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lumenSidebarBackground()
            }
            .padding(Lumen.Space.s4)
        }
        let all = try UIReviewShots.write("dyld-picker-rows", size: CGSize(width: 560, height: 470)) { rows("") }
        let filtered = try UIReviewShots.write("dyld-picker-rows-filtered", size: CGSize(width: 560, height: 170)) {
            rows("lib/system")
        }
        XCTAssertEqual(sheet.count + all.count + filtered.count, 6)
    }
}
