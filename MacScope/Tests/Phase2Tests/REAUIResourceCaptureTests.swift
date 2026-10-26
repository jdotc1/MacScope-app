import Foundation
import XCTest
@testable import MacScope

final class REAUIResourceCaptureTests: XCTestCase {
    func testNibBytesRemainExactAndKeyedJSONPreservesReferences() throws {
        let bytes = Data("NIBArchive captured payload".utf8)
        XCTAssertEqual(try REAUIResourceCapture.decodedArchive(bytes).bytes, bytes)
        let archive: [String:Any] = ["$archiver":"NSKeyedArchiver", "$objects":["$null", ["$class":["CF$UID":2]], ["$classname":"NSView"]], "$top":["root":["CF$UID":1]]]
        let plist = try PropertyListSerialization.data(fromPropertyList: archive, format:.binary, options:0)
        let captured = try REAUIResourceCapture.decodedArchive(plist)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:captured.bytes) as? [String:Any])
        XCTAssertEqual(object["$archiver"] as? String,"NSKeyedArchiver")
        XCTAssertEqual((object["$top"] as? [String:[String:Int]])?["root"]?["CF$UID"],1)
    }
    func testUnsupportedArchivesDoNotInventJSONValues() throws {
        let ordinary = try PropertyListSerialization.data(fromPropertyList:["hello":"world"],format:.binary,options:0)
        XCTAssertThrowsError(try REAUIResourceCapture.decodedArchive(ordinary))
        let archive: [String:Any] = ["$archiver":"NSKeyedArchiver", "$objects":[Data([1,2,3])], "$top":["root":["CF$UID":0]]]
        let unsupported = try PropertyListSerialization.data(fromPropertyList:archive,format:.binary,options:0)
        XCTAssertThrowsError(try REAUIResourceCapture.decodedArchive(unsupported))
    }
    func testCaptureBindsImageAndReportsMalformedAndSymlinkOmissions() throws {
        let root = TestWorkRoot.authority.appendingPathComponent("rea-ui-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("NIBArchive actual captured bytes".utf8).write(to:root.appendingPathComponent("Main.nib"))
        try Data("not a nib".utf8).write(to:root.appendingPathComponent("Malformed.nib"))
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("Outside.nib").path,withDestinationPath:"/does-not-exist-outside-tree")
        let image = LoadedBinary(name:"Main",path:"Main",isBundle:false,cpuType:0x0100000c,
            fileTypeName:"Mach-O executable",architectureDisplayName:"arm64",
            metadata:.init(uuid:nil,platformName:nil,minimumOSVersion:nil,sdkVersion:nil,buildTools:[]),
            bytes:Data([1,2,3]),sliceOffset:0,sections:[],executableTextSection:nil,entryPointAddress:nil,
            symbols:[],imports:[],indirectSymbols:[],exports:[],stringLiterals:[],functionStarts:[],objcSelectors:[:])
        let batch = try REAUIResourceCapture.acquire(rootURL:root,selectedImage:image,snapshotID:"snapshot")
        XCTAssertEqual(batch.documents.count,1); XCTAssertEqual(batch.omittedDocuments,2)
        XCTAssertEqual(batch.documents.first?.snapshotID,"snapshot")
        XCTAssertEqual(batch.documents.first?.targetSHA256,try REAUIResourceProjection.selectedSliceSHA256(image))
        XCTAssertFalse(batch.catalogMetadataAvailable)
        XCTAssertEqual(batch.originalArchiveSHA256ByPath.count,2)
    }
}
