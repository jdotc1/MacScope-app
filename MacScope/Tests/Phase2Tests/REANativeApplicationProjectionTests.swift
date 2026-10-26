import Foundation
import XCTest
@testable import MacScope

final class REANativeApplicationProjectionTests: XCTestCase {
    private func words(_ values: [UInt32]) -> Data {
        var result = Data()
        for value in values { var le = value.littleEndian; withUnsafeBytes(of: &le) { result.append(contentsOf: $0) } }
        return result
    }
    private func stringCommand(_ command: UInt32, _ value: String, dylib: Bool = false, flags: UInt32? = nil) -> Data {
        let prefix: UInt32 = dylib ? (flags == nil ? 24 : 28) : 12
        let length = (Int(prefix) + value.utf8.count + 1 + 7) & ~7
        var header: [UInt32] = [command, UInt32(length), prefix]
        if dylib { header += [flags == nil ? 0 : 0x1a741800, 0x10000, 0x10000]; if let flags { header.append(flags) } }
        var result = words(header); result.append(contentsOf: value.utf8)
        result.append(Data(repeating: 0, count: length - result.count)); return result
    }
    private func image(_ commands: [Data]) throws -> (MachOFile, UInt64) {
        let payload = commands.reduce(into: Data()) { $0.append($1) }
        var data = words([0xfeedfacf, 0x0100000c, 0, 2, UInt32(commands.count), UInt32(payload.count), 0, 0]); data.append(payload)
        return (try MachOParser().parse(data), UInt64(data.count))
    }
    func testAllPlatformsOrderedPathsEnvironmentIDAndAlternateFlags() throws {
        let commands = [words([0x32,24,1,0,0,0]), words([0x32,24,6,0,0,0]),
            stringCommand(0x8000001c,"@loader_path/first"), stringCommand(0x8000001c,"@loader_path/second"),
            stringCommand(0x27,"DYLD_LIBRARY_PATH=/outside"), stringCommand(0x0d,"@rpath/root",dylib:true),
            stringCommand(0xc,"@rpath/dep",dylib:true,flags:0x0f), stringCommand(0x20,"lazy",dylib:true)]
        let (machO,size) = try image(commands)
        let projected = REANativeApplicationProjection.sliceFacts(path:"Root", machO:machO, physicalFileSize:size, selectedSliceSize:nil)
        guard case .parsed(let slices) = projected.facts, let slice = slices.first else { return XCTFail("Expected captured slice") }
        XCTAssertEqual(slice.platforms,[1,6]); XCTAssertEqual(slice.rpaths,["@loader_path/first","@loader_path/second"])
        XCTAssertEqual(slice.install_name,"@rpath/root"); XCTAssertEqual(slice.dyld_environment,["DYLD_LIBRARY_PATH=/outside"])
        XCTAssertTrue(slice.dependencies[0].weak); XCTAssertTrue(slice.dependencies[0].reexport)
        XCTAssertTrue(slice.dependencies[0].upward); XCTAssertTrue(slice.dependencies[0].delayed_init)
        XCTAssertEqual(slice.dependencies[1].command,"LC_LAZY_LOAD_DYLIB")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(slice)) as? [String:Any])
        XCTAssertTrue(object["fat_cpu_type"] is NSNull)
    }
    func testUnknownFlagsRemainRawAndProjectionUnavailable() throws {
        let (machO,size) = try image([stringCommand(0xc,"unknown",dylib:true,flags:0x80)])
        XCTAssertEqual(machO.dylibs.first?.useFlags,0x80)
        guard case .unsupported = REANativeApplicationProjection.sliceFacts(path:"Root",machO:machO,physicalFileSize:size,selectedSliceSize:nil).facts else { return XCTFail("Unknown loader flags must not be hidden") }
    }
    func testIndependentHelperRootsAndSymlinkTargetsRemainCaptured() throws {
        let entries = [REANativeEntry(path:"Main",kind:.file), REANativeEntry(path:"Helpers/Worker",kind:.file), REANativeEntry(path:"Link",kind:.symlink,target:"../../outside")]
        let input = try REANativeApplicationProjection.project(subject:.init(name:"App.app",format:"directory"),entries:entries,images:[],roots:["Main","Helpers/Worker"],inventoryComplete:true)
        XCTAssertEqual(input.roots,["Main","Helpers/Worker"]); XCTAssertEqual(input.entries[2].target,"../../outside")
        XCTAssertThrowsError(try REANativeApplicationProjection.project(subject:input.subject,entries:entries,images:[],roots:input.roots,inventoryComplete:false))
    }
    func testUnsafeInventoryPathsAndLargeSliceRejectWithoutPrecisionLoss() throws {
        XCTAssertFalse(REANativeApplicationProjection.validPath("a/../b"))
        XCTAssertFalse(REANativeApplicationProjection.validPath("a//b"))
        var (machO,_) = try image([]); machO.selectedSliceOffset = 9_007_199_254_740_992
        guard case .unsupported = REANativeApplicationProjection.sliceFacts(path:"Root",machO:machO,physicalFileSize:UInt64.max,selectedSliceSize:32).facts else { return XCTFail("Unsafe numeric identity") }
    }
}
