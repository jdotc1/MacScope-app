import Foundation
import XCTest
@testable import MacScope

final class REAAssetCatalogCaptureTests: XCTestCase {
    private func request() -> REAAssetCatalogCaptureRequest {
        .init(requestID:UUID(),sessionID:UUID(),captureID:UUID(),stageRootPath:TestWorkRoot.authorityPath("stage"),
            relativePath:"Contents/Resources/Assets.car",targetSHA256:String(repeating:"a",count:64),snapshotID:"snapshot",
            catalogSHA256:String(repeating:"b",count:64),catalogByteCount:123,toolSHA256:String(repeating:"c",count:64),runnerSHA256:String(repeating:"d",count:64))
    }
    func testAcceptedMetadataRequiresMatchingCleanupAndHash() throws {
        let request = request(), metadata = Data("[{\"Name\":\"sample\"}]".utf8)
        let terminal = MacScope.Phase2SourceExecutionTerminal(kind:.exited,status:0)
        let cleanup = MacScope.Phase2SourceExecutionCleanup(sessionID:request.sessionID,requestID:request.requestID,processIdentifier:123,
            observedProcessAbsent:true,outcome:terminal)
        let response = REAAssetCatalogCaptureResponse(request:request,receiptID:UUID(),metadata:metadata,
            metadataSHA256:REAAssetCatalogAuthority.digest(metadata),failure:nil,terminal:terminal,cleanup:cleanup,elapsedSeconds:1)
        XCTAssertTrue(response.isAccepted)
        let wrongCleanup = MacScope.Phase2SourceExecutionCleanup(sessionID:UUID(),requestID:request.requestID,processIdentifier:123,observedProcessAbsent:true,outcome:terminal)
        XCTAssertFalse(REAAssetCatalogCaptureResponse(request:request,receiptID:UUID(),metadata:metadata,metadataSHA256:response.metadataSHA256,
            failure:nil,terminal:terminal,cleanup:wrongCleanup,elapsedSeconds:1).isAccepted)
        XCTAssertFalse(REAAssetCatalogCaptureResponse(request:request,receiptID:UUID(),metadata:metadata,metadataSHA256:String(repeating:"0",count:64),
            failure:nil,terminal:terminal,cleanup:cleanup,elapsedSeconds:1).isAccepted)
        XCTAssertFalse(REAAssetCatalogCaptureResponse.rejected(request,"cancelled").isAccepted)
    }
    func testMetadataExpansionBudgetAndOrdinaryRecords() throws {
        XCTAssertNoThrow(try REAAssetCatalogAuthority.metadataJSON(Data("[{\"Name\":\"Asset\",\"Scale\":2}]".utf8)))
        let nested = String(repeating:"[",count:65) + "0" + String(repeating:"]",count:65)
        XCTAssertThrowsError(try REAAssetCatalogAuthority.metadataJSON(Data(nested.utf8)))
        XCTAssertThrowsError(try REAAssetCatalogAuthority.metadataJSON(Data("not-json".utf8)))
        XCTAssertThrowsError(try REAAssetCatalogAuthority.metadataJSON(Data(repeating:32,count:8_388_609)))
    }
    func testRequestAndCanonicalReceiptRoundTrip() throws {
        let request = request()
        XCTAssertTrue(request.isValid)
        let bytes = try REAAssetCatalogAuthority.encode(request)
        XCTAssertEqual(try JSONDecoder().decode(REAAssetCatalogCaptureRequest.self,from:bytes),request)
        let invalid = REAAssetCatalogCaptureRequest(requestID:request.requestID,sessionID:request.sessionID,captureID:request.captureID,
            stageRootPath:request.stageRootPath,relativePath:"../Assets.car",targetSHA256:request.targetSHA256,snapshotID:request.snapshotID,
            catalogSHA256:request.catalogSHA256,catalogByteCount:request.catalogByteCount,toolSHA256:request.toolSHA256,runnerSHA256:request.runnerSHA256)
        XCTAssertFalse(invalid.isValid)
    }
}
