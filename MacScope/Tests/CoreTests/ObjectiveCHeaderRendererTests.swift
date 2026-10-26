import XCTest
@testable import MacScope

/// The Objective-C `.h` generation core: a runtime-type-encoding decoder and a deterministic
/// `@interface` renderer, both pure and fully testable from synthetic models (the Mach-O class
/// parser that populates the model is a separate piece). Correctness-over-coverage: an
/// undecodable type falls back to `id` rather than emitting a wrong type.
final class ObjectiveCHeaderRendererTests: XCTestCase {

    // MARK: - Type-encoding decode (single type)

    func testDecodePrimitivesAndRuntimeTypes() {
        XCTAssertEqual(ObjCTypeEncoding.decode("v"), "void")
        XCTAssertEqual(ObjCTypeEncoding.decode("@"), "id")
        XCTAssertEqual(ObjCTypeEncoding.decode(":"), "SEL")
        XCTAssertEqual(ObjCTypeEncoding.decode("#"), "Class")
        XCTAssertEqual(ObjCTypeEncoding.decode("i"), "int")
        XCTAssertEqual(ObjCTypeEncoding.decode("Q"), "unsigned long long")
        XCTAssertEqual(ObjCTypeEncoding.decode("B"), "BOOL")
        XCTAssertEqual(ObjCTypeEncoding.decode("*"), "char *")
    }

    func testDecodeTypedObjectPointerAndStruct() {
        XCTAssertEqual(ObjCTypeEncoding.decode("@\"NSString\""), "NSString *")
        XCTAssertEqual(ObjCTypeEncoding.decode("^i"), "int *")
        XCTAssertEqual(ObjCTypeEncoding.decode("^@"), "id *")
        XCTAssertEqual(ObjCTypeEncoding.decode("{CGRect=dddd}"), "CGRect")
        XCTAssertEqual(ObjCTypeEncoding.decode("{CGRect=\"origin\"{CGPoint=dd}\"size\"{CGSize=dd}}"), "CGRect")
        // Const-qualified object pointer.
        XCTAssertEqual(ObjCTypeEncoding.decode("r*"), "const char *")
    }

    func testDecodeUnknownFallsBackToId() {
        XCTAssertEqual(ObjCTypeEncoding.decode("???"), "id")
        XCTAssertEqual(ObjCTypeEncoding.decode(""), "id")
    }

    // MARK: - Method signatures

    func testInstanceMethodWithArgs() {
        // return id, self(@) sel(:), then a CGRect and an int arg.
        let m = ObjCMethod(selector: "initWithFrame:style:", typeEncoding: "@40@0:8{CGRect=dddd}16i32", isClassMethod: false)
        XCTAssertEqual(ObjCTypeEncoding.methodSignature(m), "- (id)initWithFrame:(CGRect)arg0 style:(int)arg1;")
    }

    func testZeroArgClassMethod() {
        let m = ObjCMethod(selector: "alloc", typeEncoding: "@16@0:8", isClassMethod: true)
        XCTAssertEqual(ObjCTypeEncoding.methodSignature(m), "+ (id)alloc;")
    }

    func testMethodWithoutEncodingFallsBackToId() {
        let m = ObjCMethod(selector: "setThing:", typeEncoding: nil, isClassMethod: false)
        XCTAssertEqual(ObjCTypeEncoding.methodSignature(m), "- (id)setThing:(id)arg0;")
    }

    // MARK: - Full @interface render

    func testRenderInterface() {
        let cls = ObjCClass(
            name: "MyView",
            superclassName: "NSView",
            adoptedProtocols: ["NSCoding", "NSCopying"],
            classMethods: [ObjCMethod(selector: "alloc", typeEncoding: "@16@0:8", isClassMethod: true)],
            instanceMethods: [ObjCMethod(selector: "initWithFrame:", typeEncoding: "@24@0:8{CGRect=dddd}16", isClassMethod: false)],
            ivars: [ObjCIvar(name: "_title", typeEncoding: "@\"NSString\"")],
            properties: [ObjCProperty(name: "title", attributes: "T@\"NSString\",&,N,V_title")]
        )
        let header = ObjectiveCHeaderRenderer.render(classes: [cls])
        XCTAssertTrue(header.contains("@interface MyView : NSView <NSCoding, NSCopying>"), header)
        XCTAssertTrue(header.contains("NSString *_title;"), header)
        XCTAssertTrue(header.contains("+ (id)alloc;"), header)
        XCTAssertTrue(header.contains("- (id)initWithFrame:(CGRect)arg0;"), header)
        XCTAssertTrue(header.contains("@property") && header.contains("title;"), header)
        XCTAssertTrue(header.contains("@end"), header)
    }

    func testRootClassHasNoColonSuperclass() {
        let cls = ObjCClass(name: "NSObject", superclassName: nil, adoptedProtocols: [],
                            classMethods: [], instanceMethods: [], ivars: [], properties: [])
        let header = ObjectiveCHeaderRenderer.render(classes: [cls])
        XCTAssertTrue(header.contains("@interface NSObject\n") || header.contains("@interface NSObject "), header)
        XCTAssertFalse(header.contains("NSObject :"), header)
    }
}
