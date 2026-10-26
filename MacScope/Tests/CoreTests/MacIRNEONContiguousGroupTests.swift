import XCTest
@testable import MacScope

/// Source-only native obligation. Portable main exercises actual decoder,
/// builder, metadata erasure, typed preflight and group payload consumer.
final class MacIRNEONContiguousGroupTests: XCTestCase {
    func testWrappedByteBlocksAndCompositeIdentity() throws {
        let f=try XCTUnwrap(MacIRNEONContiguousGroup(effect:.load,activeBytes:8,baseRegister:"x9",
            oldBase:.register(name:"x9",version:0),vectors:[31,0,1,2].map { .register(name:"v\($0)",version:1) },
            baseDestination:.register(name:"x9",version:1),frameSequence:0,firstByteSequence:0))
        XCTAssertEqual(f.byteCount,32);XCTAssertEqual(f.effectCount,5);XCTAssertEqual(f.fixedPostDelta,32)
        XCTAssertEqual(f.orderedBytes[8].vector,1);XCTAssertEqual(f.orderedBytes[8].lane,0)
        XCTAssertEqual(f.orderedBytes[31].vector,3);XCTAssertEqual(f.orderedBytes[31].lane,7)
        let s=MacIRSourceSpan(address:0x1000,byteText:"",mnemonic:"erased",operands:"",comment:nil)
        let ids=(0..<f.effectCount).map { ordinal in
            MacIRInstruction(source:s,operation:f.operation(ordinal),memoryAccess:ordinal<4 ? .init(byteWidth:8):nil,
                neonContiguousGroup:.init(frame:f,ordinal:ordinal)).id
        }
        XCTAssertEqual(Set(ids).count,5);XCTAssertTrue(ids.allSatisfy { $0.sourceAddress==0x1000 })
        XCTAssertEqual(ids.map(\.effectOrdinal),[0,1,2,3,4])
    }
    func testArgumentOutsideArgumentRegistersRefusesWithoutTrap() {
        XCTAssertNil(MacIRNEONContiguousGroup(effect:.load,activeBytes:16,baseRegister:"x8",
            oldBase:.argument(bindingID:.gpr(0)),vectors:[.register(name:"v0",version:1)],baseDestination:nil,frameSequence:0,firstByteSequence:0))
    }
}
