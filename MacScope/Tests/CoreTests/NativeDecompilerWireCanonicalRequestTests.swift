import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerWireCanonicalRequestTests: XCTestCase {
    func testGoldenV2PreimageAndDigestMatchFrozenBytes() throws {
        let fixture = try makeFixture()
        let actualPreimage = try preimage(for: fixture)

        XCTAssertEqual(actualPreimage, try data(hex: Self.goldenPreimageHex))
        XCTAssertEqual(try digest(for: fixture), Self.goldenDigest)
    }

    func testCorrelationUUIDDoesNotAffectCanonicalDigest() throws {
        let fixture = try makeFixture()
        let changed = replacing(
            fixture,
            requestID: UUID(uuidString: "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb")!
        )

        XCTAssertEqual(try digest(for: fixture), try digest(for: changed))
    }

    func testRequestSHAFieldDoesNotEnterItsOwnPreimage() throws {
        let fixture = try makeFixture()
        let changed = replacing(
            fixture,
            requestSHA256: String(repeating: "f", count: 64)
        )

        XCTAssertEqual(try preimage(for: fixture), try preimage(for: changed))
        XCTAssertEqual(try digest(for: fixture), try digest(for: changed))
    }

    func testEveryTargetContextAndAuthoredLeafChangesDigest() throws {
        let fixture = try makeFixture()
        let baseline = try digest(for: fixture)

        let targetMutations = try targetLeafMutations(fixture.target)
        XCTAssertEqual(targetMutations.count, 20)
        for (label, target) in targetMutations {
            XCTAssertNotEqual(
                try digest(for: replacing(fixture, target: target)),
                baseline,
                "target leaf \(label) must participate in request identity"
            )
        }

        let authoredMutations = try authoredLeafMutations(fixture.authoredInputs)
        XCTAssertEqual(authoredMutations.count, 38)
        for (label, authoredInputs) in authoredMutations {
            XCTAssertNotEqual(
                try digest(for: replacing(fixture, authoredInputs: authoredInputs)),
                baseline,
                "authored leaf \(label) must participate in request identity"
            )
        }
    }

    func testRawTargetHexIsPreservedAsExactUTF8() throws {
        let fixture = try makeFixture()
        let fields = try canonicalFields(try preimage(for: fixture))

        XCTAssertEqual(try textField("target.rawCPUType", in: fields), "0100000c")
        XCTAssertEqual(try textField("target.rawCPUSubtype", in: fields), "80000002")
        XCTAssertEqual(
            try dataField("target.rawCPUSubtype", in: fields),
            Data("80000002".utf8),
            "fixed-width lowercase hexadecimal is identity-bearing UTF-8, not a numeric word"
        )
    }

    func testAuthoredLeavesUseFrozenDepthFirstOrder() throws {
        let fields = try canonicalFields(try preimage(for: makeFixture()))
        let names = fields.map(\.name)
        let expectedSubsequence = [
            "authoredInputs.signatures[0].returnType.tag",
            "authoredInputs.signatures[0].returnType.depth",
            "authoredInputs.signatures[0].returnType.pointee.tag",
            "authoredInputs.signatures[0].returnType.pointee.depth",
            "authoredInputs.signatures[0].returnType.pointee.atom.tag",
            "authoredInputs.signatures[0].returnType.pointee.atom.namedKind",
            "authoredInputs.signatures[0].returnType.pointee.atom.name",
            "authoredInputs.signatures[0].returnType.pointee.qualifiers",
            "authoredInputs.signatures[0].returnType.indirectionLevel",
            "authoredInputs.signatures[0].returnType.pointerQualifiers.count",
            "authoredInputs.signatures[0].returnType.pointerQualifiers[0]",
            "authoredInputs.typeDefinitions[0].fields[0].storage.tag",
            "authoredInputs.typeDefinitions[0].fields[0].storage.depth",
            "authoredInputs.typeDefinitions[0].fields[0].storage.count",
            "authoredInputs.typeDefinitions[0].fields[0].storage.element.tag",
            "authoredInputs.typeDefinitions[0].fields[0].storage.element.depth",
            "authoredInputs.typeDefinitions[0].fields[0].storage.element.kind",
        ]

        XCTAssertEqual(names.filter(expectedSubsequence.contains), expectedSubsequence)
    }

    func testWholeRequestAndStandaloneAuthoredIdentityUseOneLeafWriter() throws {
        let fixture = try makeFixture()
        let wholeFields = try canonicalFields(try preimage(for: fixture))
            .filter { $0.name.hasPrefix("authoredInputs.") }
        let standaloneFields = try canonicalFields(
            NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                fixture.authoredInputs
            )
        ).filter { $0.name.hasPrefix("authoredInputs.") }

        XCTAssertEqual(wholeFields, standaloneFields)
    }

    func testContextProfileDigestMatchesFrozenSHA256() throws {
        let preimage = NativeDecompilerWireCanonicalRequest.contextProfilePreimage()
        XCTAssertEqual(preimage, try data(hex: Self.contextProfilePreimageHex))
        XCTAssertEqual(
            sha256Hex(preimage),
            "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
        )
    }

    func testAuthoredByteMeterIsIndependentOfFullRequestPrefixAndCountsStandaloneDomainExactlyOnce() throws {
        let exactInputs = namesOnlyInputs(
            nameLengths: try nameLengthsForCanonicalByteCount(1_048_576)
        )
        XCTAssertEqual(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(exactInputs).count,
            1_048_576
        )

        let largeBytes = Data(repeating: 0xa5, count: 600_000)
        let fixture = replacing(
            try makeFixture(authoredInputs: exactInputs),
            memoryRegions: [
                .init(
                    name: "__text",
                    startAddress: .init(0x1_0000_1000),
                    permissions: .readExecute,
                    rawBytes: largeBytes,
                    effectiveBytes: Data(repeating: 0x5a, count: 600_000),
                    appliedPatchIDs: ["patch000001"]
                ),
            ]
        )
        let wholePreimage = try preimage(for: fixture)
        let wholeFields = try canonicalFields(wholePreimage)
        let physicalPreAuthoredPrefixBytes = wholeFields
            .prefix { !$0.name.hasPrefix("authoredInputs.") }
            .reduce(0) { partial, field in
                partial + canonicalFieldByteCount(field.name, valueByteCount: field.value.count)
            }
        XCTAssertGreaterThan(physicalPreAuthoredPrefixBytes, 1_048_576)
        XCTAssertFalse(
            wholePreimage.isEmpty,
            "whole-request prefix bytes must not be charged to the logical authored section"
        )

        var plusOneLengths = try nameLengthsForCanonicalByteCount(1_048_576)
        let adjustableIndex = try XCTUnwrap(plusOneLengths.firstIndex {
            $0 < 1_024 && canonicalTokenByteCount($0 + 1) == canonicalTokenByteCount($0) + 1
        })
        plusOneLengths[adjustableIndex] += 1
        let plusOneInputs = namesOnlyInputs(nameLengths: plusOneLengths)
        XCTAssertThrowsError(
            try NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(plusOneInputs)
        ) { error in
            XCTAssertEqual(
                error as? NativeDecompilerWireAuthoredValidationError,
                .canonicalAuthoredInputTooLarge
            )
        }
        XCTAssertThrowsError(
            try preimage(for: replacing(fixture, authoredInputs: plusOneInputs))
        ) { error in
            XCTAssertEqual(
                error as? NativeDecompilerWireAuthoredValidationError,
                .canonicalAuthoredInputTooLarge
            )
        }
    }

    func testCanonicalV2SignatureRequiresTargetAndProfiledBudget() throws {
        let fixture = try makeFixture()
        let canonicalizer: (
            UInt32,
            NativeDecompilerWireRequestOperation,
            NativeDecompilerWireTarget,
            NativeDecompilerWireImageIdentity,
            NativeDecompilerWireFunctionIdentity,
            [NativeDecompilerWireMemoryRegion],
            [NativeDecompilerWireSymbolRecord],
            NativeDecompilerWireAuthoredInputs,
            NativeDecompilerProfiledAnalysisBudgets
        ) throws -> Data = NativeDecompilerWireCanonicalRequest.preimage

        XCTAssertFalse(try canonicalizer(
            fixture.schemaVersion,
            fixture.operation,
            fixture.target,
            fixture.image,
            fixture.function,
            fixture.memoryRegions,
            fixture.symbols,
            fixture.authoredInputs,
            fixture.budgets
        ).isEmpty)
    }
}

private extension NativeDecompilerWireCanonicalRequestTests {
    struct Fixture {
        let schemaVersion: UInt32
        let requestID: UUID
        let requestSHA256: String
        let operation: NativeDecompilerWireRequestOperation
        let target: NativeDecompilerWireTarget
        let image: NativeDecompilerWireImageIdentity
        let function: NativeDecompilerWireFunctionIdentity
        let memoryRegions: [NativeDecompilerWireMemoryRegion]
        let symbols: [NativeDecompilerWireSymbolRecord]
        let authoredInputs: NativeDecompilerWireAuthoredInputs
        let budgets: NativeDecompilerProfiledAnalysisBudgets
    }

    struct CanonicalField: Equatable {
        let name: String
        let value: Data
    }

    static let goldenPreimageHex = """
        32323a63616e6f6e6963616c53747265616d56657273696f6e0a313a320a31333a736368656d6156657273696f6e0a313a330a393a6f706572617469
        6f6e0a393a6465636f6d70696c650a31373a7461726765742e726177435055547970650a383a30313030303030630a32303a7461726765742e726177
        435055537562747970650a383a38303030303030320a32343a7461726765742e6e6f726d616c697a656456617269616e740a363a61726d3634650a33
        313a7461726765742e7265636f676e697a65644361706162696c697479426974730a383a38303030303030300a33363a7461726765742e706f696e74
        65724175746841424956657273696f6e2e70726573656e740a313a310a33343a7461726765742e706f696e7465724175746841424956657273696f6e
        2e76616c75650a313a300a32363a7461726765742e73656c6563746564536c6963655348413235360a36343a61616161616161616161616161616161
        6161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161610a32393a7461726765742e73
        656c6563746564536c69636542797465436f756e740a313a340a31363a7461726765742e70726f66696c6549440a33363a6170706c652d6161726368
        36342d7061632d76697369626c652d636c6f626265722d76310a31373a7461726765742e6c616e677561676549440a32363a414152434836343a4c45
        3a36343a4170706c6553696c69636f6e0a32313a7461726765742e636f6d70696c65725370656349440a373a64656661756c740a32373a7461726765
        742e636f6e7465787450726f66696c655348413235360a36343a36616134356561393230366639363763303935643137356230356336633064373938
        3063643135613037303238323664376162333865346664333763386361350a32303a7461726765742e636f6e746578742e636f756e740a313a340a32
        323a7461726765742e636f6e746578745b305d2e6e616d650a373a53686f775041430a32333a7461726765742e636f6e746578745b305d2e76616c75
        650a313a310a32323a7461726765742e636f6e746578745b315d2e6e616d650a31313a5041435f636c6f626265720a32333a7461726765742e636f6e
        746578745b315d2e76616c75650a313a310a32323a7461726765742e636f6e746578745b325d2e6e616d650a373a53686f774254490a32333a746172
        6765742e636f6e746578745b325d2e76616c75650a313a300a32323a7461726765742e636f6e746578745b335d2e6e616d650a31303a53686f774d65
        6d5461670a32333a7461726765742e636f6e746578745b335d2e76616c75650a313a300a31333a696d6167652e696d61676549440a31303a696d6167
        652e6d61696e0a31303a696d6167652e757569640a33363a61616161616161612d626262622d636363632d646464642d656565656565656565656565
        0a32363a696d6167652e7072656665727265644c6f6164416464726573730a31303a343239343936373239360a31393a66756e6374696f6e2e66756e
        6374696f6e49440a31343a66756e6374696f6e2e656e7472790a31333a66756e6374696f6e2e6e616d650a353a656e7472790a32313a66756e637469
        6f6e2e656e747279416464726573730a31303a343239343937313339320a32383a66756e6374696f6e2e656e64416464726573734578636c75736976
        650a31303a343239343937313339360a31393a6d656d6f7279526567696f6e732e636f756e740a313a310a32313a6d656d6f7279526567696f6e735b
        305d2e6e616d650a363a5f5f746578740a32393a6d656d6f7279526567696f6e735b305d2e7374617274416464726573730a31303a34323934393731
        3339320a32383a6d656d6f7279526567696f6e735b305d2e7065726d697373696f6e730a333a722d780a32353a6d656d6f7279526567696f6e735b30
        5d2e72617742797465730a343a000000000a33313a6d656d6f7279526567696f6e735b305d2e65666665637469766542797465730a343a1f2003d50a
        33383a6d656d6f7279526567696f6e735b305d2e6170706c69656450617463684944732e636f756e740a313a310a33353a6d656d6f7279526567696f
        6e735b305d2e6170706c69656450617463684944735b305d0a31313a70617463683030303030310a31333a73796d626f6c732e636f756e740a313a31
        0a31383a73796d626f6c735b305d2e696d61676549440a31303a696d6167652e6d61696e0a31383a73796d626f6c735b305d2e616464726573730a31
        303a343239343937313339320a31353a73796d626f6c735b305d2e6e616d650a363a5f656e7472790a31353a73796d626f6c735b305d2e6b696e640a
        383a66756e6374696f6e0a32383a617574686f726564496e707574732e736368656d6156657273696f6e0a383a00000000000000010a32363a617574
        686f726564496e707574732e6e616d65732e636f756e740a383a00000000000000010a33313a617574686f726564496e707574732e6e616d65735b30
        5d2e616464726573730a383a00000001000010000a33353a617574686f726564496e707574732e6e616d65735b305d2e7375626a6563744b696e640a
        313a000a32383a617574686f726564496e707574732e6e616d65735b305d2e6e616d650a353a656e7472790a33313a617574686f726564496e707574
        732e7369676e6174757265732e636f756e740a383a00000000000000010a34343a617574686f726564496e707574732e7369676e6174757265735b30
        5d2e66756e6374696f6e416464726573730a383a00000001000010000a34373a617574686f726564496e707574732e7369676e6174757265735b305d
        2e72657475726e547970652e70726573656e740a313a010a34333a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475
        726e547970652e7461670a313a010a34353a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e6465
        7074680a383a00000000000000000a35313a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e706f
        696e7465652e7461670a313a000a35333a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e706f69
        6e7465652e64657074680a383a00000000000000010a35363a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e
        547970652e706f696e7465652e61746f6d2e7461670a313a030a36323a617574686f726564496e707574732e7369676e6174757265735b305d2e7265
        7475726e547970652e706f696e7465652e61746f6d2e6e616d65644b696e640a313a000a35373a617574686f726564496e707574732e7369676e6174
        757265735b305d2e72657475726e547970652e706f696e7465652e61746f6d2e6e616d650a363a5061636b65740a35383a617574686f726564496e70
        7574732e7369676e6174757265735b305d2e72657475726e547970652e706f696e7465652e7175616c6966696572730a313a010a35363a617574686f
        726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e696e646972656374696f6e4c6576656c0a383a000000000000
        00010a36333a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e706f696e7465725175616c696669
        6572732e636f756e740a383a00000000000000010a36303a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e54
        7970652e706f696e7465725175616c6966696572735b305d0a313a060a34373a617574686f726564496e707574732e7369676e6174757265735b305d
        2e706172616d657465724c69737453746174650a313a010a34353a617574686f726564496e707574732e7369676e6174757265735b305d2e70617261
        6d65746572732e636f756e740a383a00000000000000010a34373a617574686f726564496e707574732e7369676e6174757265735b305d2e70617261
        6d65746572735b305d2e6e616d650a353a76616c75650a35313a617574686f726564496e707574732e7369676e6174757265735b305d2e706172616d
        65746572735b305d2e747970652e7461670a313a000a35333a617574686f726564496e707574732e7369676e6174757265735b305d2e706172616d65
        746572735b305d2e747970652e64657074680a383a00000000000000000a35363a617574686f726564496e707574732e7369676e6174757265735b30
        5d2e706172616d65746572735b305d2e747970652e61746f6d2e7461670a313a010a36333a617574686f726564496e707574732e7369676e61747572
        65735b305d2e706172616d65746572735b305d2e747970652e61746f6d2e7363616c61724b696e640a313a070a35383a617574686f726564496e7075
        74732e7369676e6174757265735b305d2e706172616d65746572735b305d2e747970652e7175616c6966696572730a313a000a34323a617574686f72
        6564496e707574732e7369676e6174757265735b305d2e766172696164696353746174650a313a010a34323a617574686f726564496e707574732e73
        69676e6174757265735b305d2e6e6f52657475726e53746174650a313a010a33333a617574686f726564496e707574732e6170706c69656454797065
        732e636f756e740a383a00000000000000010a33383a617574686f726564496e707574732e6170706c69656454797065735b305d2e61646472657373
        0a383a00000001000020000a34323a617574686f726564496e707574732e6170706c69656454797065735b305d2e7375626a6563744b696e640a313a
        000a34393a617574686f726564496e707574732e6170706c69656454797065735b305d2e74797065446566696e6974696f6e4e616d650a363a506163
        6b65740a34303a617574686f726564496e707574732e6170706c69656454797065735b305d2e62797465436f756e740a383a00000000000000100a33
        363a617574686f726564496e707574732e74797065446566696e6974696f6e732e636f756e740a383a00000000000000010a33383a617574686f7265
        64496e707574732e74797065446566696e6974696f6e735b305d2e6b696e640a313a000a33383a617574686f726564496e707574732e747970654465
        66696e6974696f6e735b305d2e6e616d650a363a5061636b65740a35343a617574686f726564496e707574732e74797065446566696e6974696f6e73
        5b305d2e6c61796f757452756c65732e69735061636b65640a313a000a36373a617574686f726564496e707574732e74797065446566696e6974696f
        6e735b305d2e6c61796f757452756c65732e7061636b416c69676e6d656e742e70726573656e740a313a010a36353a617574686f726564496e707574
        732e74797065446566696e6974696f6e735b305d2e6c61796f757452756c65732e7061636b416c69676e6d656e742e76616c75650a383a0000000000
        0000080a37303a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6c61796f757452756c65732e6d696e696d756d
        416c69676e6d656e742e70726573656e740a313a000a34363a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e66
        69656c64732e636f756e740a383a00000000000000010a34383a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e
        6669656c64735b305d2e6e616d650a383a68616e646c6572730a35353a617574686f726564496e707574732e74797065446566696e6974696f6e735b
        305d2e6669656c64735b305d2e73746f726167652e7461670a313a010a35373a617574686f726564496e707574732e74797065446566696e6974696f
        6e735b305d2e6669656c64735b305d2e73746f726167652e64657074680a383a00000000000000000a35373a617574686f726564496e707574732e74
        797065446566696e6974696f6e735b305d2e6669656c64735b305d2e73746f726167652e636f756e740a383a00000000000000020a36333a61757468
        6f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e73746f726167652e656c656d656e742e7461670a
        313a030a36353a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e73746f726167652e65
        6c656d656e742e64657074680a383a00000000000000010a36343a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d
        2e6669656c64735b305d2e73746f726167652e656c656d656e742e6b696e640a313a010a36303a617574686f726564496e707574732e747970654465
        66696e6974696f6e735b305d2e6669656c64735b305d2e62697457696474682e70726573656e740a313a000a36383a617574686f726564496e707574
        732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d656e742e70726573656e740a313a010a
        36363a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d
        656e742e76616c75650a383a00000000000000080a37323a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669
        656c64735b305d2e6d696e696d756d416c69676e6d656e74547970652e70726573656e740a313a010a36383a617574686f726564496e707574732e74
        797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d656e74547970652e7461670a313a000a37303a
        617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d656e74
        547970652e64657074680a383a00000000000000010a37333a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e66
        69656c64735b305d2e6d696e696d756d416c69676e6d656e74547970652e61746f6d2e7461670a313a010a38303a617574686f726564496e70757473
        2e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d656e74547970652e61746f6d2e7363616c
        61724b696e640a313a070a37353a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d69
        6e696d756d416c69676e6d656e74547970652e7175616c6966696572730a313a000a36343a617574686f726564496e707574732e7479706544656669
        6e6974696f6e735b305d2e6669656c64735b305d2e70726f6d6f746573496e6c696e654669656c64730a313a000a31373a627564676574732e70726f
        66696c6549440a32343a6e61746976652d70726f647563742d6275646765742d76310a32303a627564676574732e6d6178436f646542797465730a37
        3a313034383537360a32333a627564676574732e6d6178496e737472756374696f6e730a353a36353533360a32313a627564676574732e6d61784f70
        65726174696f6e730a363a3236323134340a32323a627564676574732e6d61784f757470757442797465730a373a313034383537360a33313a627564
        676574732e6d617857616c6c54696d654d696c6c697365636f6e64730a343a353030300a
        """
    static let goldenDigest =
        "c8e8824e8c389be6f640b875fe303668449a3898bfd8db34acbd32440da28a81"
    static let contextProfilePreimageHex = """
        363a646f6d61696e0a34393a636f6d2e6a656666636f6f6e65792e4d616353636f70652e6e61746976652d636f6e746578742d70726f66696c652e76
        310a393a70726f66696c6549440a33363a6170706c652d616172636836342d7061632d76697369626c652d636c6f626265722d76310a31303a6c616e
        677561676549440a32363a414152434836343a4c453a36343a4170706c6553696c69636f6e0a31343a636f6d70696c65725370656349440a373a6465
        6661756c740a31333a636f6e746578742e636f756e740a313a340a31353a636f6e746578745b305d2e6e616d650a373a53686f775041430a31363a63
        6f6e746578745b305d2e76616c75650a313a310a31353a636f6e746578745b315d2e6e616d650a31313a5041435f636c6f626265720a31363a636f6e
        746578745b315d2e76616c75650a313a310a31353a636f6e746578745b325d2e6e616d650a373a53686f774254490a31363a636f6e746578745b325d
        2e76616c75650a313a300a31353a636f6e746578745b335d2e6e616d650a31303a53686f774d656d5461670a31363a636f6e746578745b335d2e7661
        6c75650a313a300a
        """

    var emptyLayoutRules: NativeDecompilerWireAuthoredLayoutRules {
        .init(isPacked: false, packAlignment: nil, minimumAlignment: nil)
    }

    func makeFixture(
        authoredInputs: NativeDecompilerWireAuthoredInputs? = nil
    ) throws -> Fixture {
        let target = try NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_000c,
            rawCPUSubtype: 0x8000_0002,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 4
        )
        return Fixture(
            schemaVersion: 3,
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            requestSHA256: String(repeating: "0", count: 64),
            operation: .decompile,
            target: target,
            image: .init(
                imageID: "image.main",
                uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                preferredLoadAddress: .init(0x1_0000_0000)
            ),
            function: .init(
                functionID: "function.entry",
                name: "entry",
                entryAddress: .init(0x1_0000_1000),
                endAddressExclusive: .init(0x1_0000_1004)
            ),
            memoryRegions: [
                .init(
                    name: "__text",
                    startAddress: .init(0x1_0000_1000),
                    permissions: .readExecute,
                    rawBytes: Data([0x00, 0x00, 0x00, 0x00]),
                    effectiveBytes: Data([0x1f, 0x20, 0x03, 0xd5]),
                    appliedPatchIDs: ["patch000001"]
                ),
            ],
            symbols: [
                .init(
                    imageID: "image.main",
                    address: .init(0x1_0000_1000),
                    name: "_entry",
                    kind: .function
                ),
            ],
            authoredInputs: authoredInputs ?? nonemptyAuthoredInputs(),
            budgets: NativeDecompilerProductBudgetProfile.v1
        )
    }

    func nonemptyAuthoredInputs() -> NativeDecompilerWireAuthoredInputs {
        let namedPacket = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .named(kind: .`struct`, name: "Packet"),
            qualifiers: [.constant]
        )
        let pointer = NativeDecompilerWireAuthoredType.dataPointer(
            pointee: namedPacket,
            indirectionLevel: .init(1),
            pointerQualifiersByLevel: [[.volatile, .restrict]]
        )
        let scalar = NativeDecompilerWireAuthoredType.qualifiedValue(
            atom: .scalar(.unsigned32),
            qualifiers: []
        )
        let fixedCarrier = NativeDecompilerWireAuthoredFieldStorage.fixedArray(
            element: .opaquePointerCarrier(kind: .pointerToArray),
            count: .init(2)
        )
        return .init(
            schemaVersion: 1,
            names: [
                .init(address: .init(0x1_0000_1000), subjectKind: .function, name: "entry"),
            ],
            signatures: [
                .init(
                    functionAddress: .init(0x1_0000_1000),
                    returnType: pointer,
                    parameterListState: .authoritative,
                    parameters: [.init(name: "value", type: scalar)],
                    variadicState: .fixed,
                    noReturnState: .returns
                ),
            ],
            appliedTypes: [
                .init(
                    address: .init(0x1_0000_2000),
                    subjectKind: .memoryObject,
                    typeDefinitionName: "Packet",
                    byteCount: .init(16)
                ),
            ],
            typeDefinitions: [
                .record(
                    kind: .`struct`,
                    name: "Packet",
                    layoutRules: .init(
                        isPacked: false,
                        packAlignment: .init(8),
                        minimumAlignment: nil
                    ),
                    fields: [
                        .init(
                            name: "handlers",
                            storage: fixedCarrier,
                            bitWidth: nil,
                            minimumAlignment: .init(8),
                            minimumAlignmentType: scalar,
                            promotesInlineFields: false
                        ),
                    ]
                ),
            ]
        )
    }

    func preimage(for fixture: Fixture) throws -> Data {
        try NativeDecompilerWireCanonicalRequest.preimage(
            schemaVersion: fixture.schemaVersion,
            operation: fixture.operation,
            target: fixture.target,
            image: fixture.image,
            function: fixture.function,
            memoryRegions: fixture.memoryRegions,
            symbols: fixture.symbols,
            authoredInputs: fixture.authoredInputs,
            budgets: fixture.budgets
        )
    }

    func digest(for fixture: Fixture) throws -> String {
        try NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: fixture.schemaVersion,
            operation: fixture.operation,
            target: fixture.target,
            image: fixture.image,
            function: fixture.function,
            memoryRegions: fixture.memoryRegions,
            symbols: fixture.symbols,
            authoredInputs: fixture.authoredInputs,
            budgets: fixture.budgets
        )
    }

    func replacing(
        _ fixture: Fixture,
        requestID: UUID? = nil,
        requestSHA256: String? = nil,
        target: NativeDecompilerWireTarget? = nil,
        image: NativeDecompilerWireImageIdentity? = nil,
        memoryRegions: [NativeDecompilerWireMemoryRegion]? = nil,
        authoredInputs: NativeDecompilerWireAuthoredInputs? = nil
    ) -> Fixture {
        Fixture(
            schemaVersion: fixture.schemaVersion,
            requestID: requestID ?? fixture.requestID,
            requestSHA256: requestSHA256 ?? fixture.requestSHA256,
            operation: fixture.operation,
            target: target ?? fixture.target,
            image: image ?? fixture.image,
            function: fixture.function,
            memoryRegions: memoryRegions ?? fixture.memoryRegions,
            symbols: fixture.symbols,
            authoredInputs: authoredInputs ?? fixture.authoredInputs,
            budgets: fixture.budgets
        )
    }

    func targetLeafMutations(
        _ target: NativeDecompilerWireTarget
    ) throws -> [(String, NativeDecompilerWireTarget)] {
        let otherVariant: NativeDecompilerWireArchitectureVariant =
            target.normalizedVariant == .arm64 ? .arm64e : .arm64
        var mutations: [(String, NativeDecompilerWireTarget)] = []
        func add(
            _ label: String,
            rawCPUType: String? = nil,
            rawCPUSubtype: String? = nil,
            normalizedVariant: NativeDecompilerWireArchitectureVariant? = nil,
            recognizedCapabilityBits: String? = nil,
            pointerAuthABIVersion: UInt32?? = nil,
            selectedSliceSHA256: String? = nil,
            selectedSliceByteCount: NativeDecompilerWireUInt64? = nil,
            profileID: String? = nil,
            languageID: String? = nil,
            compilerSpecID: String? = nil,
            contextProfileSHA256: String? = nil,
            context: [NativeDecompilerWireTargetContextValue]? = nil
        ) {
            mutations.append((label, .init(
                rawCPUType: rawCPUType ?? target.rawCPUType,
                rawCPUSubtype: rawCPUSubtype ?? target.rawCPUSubtype,
                normalizedVariant: normalizedVariant ?? target.normalizedVariant,
                recognizedCapabilityBits: recognizedCapabilityBits ?? target.recognizedCapabilityBits,
                pointerAuthABIVersion: pointerAuthABIVersion ?? target.pointerAuthABIVersion,
                selectedSliceSHA256: selectedSliceSHA256 ?? target.selectedSliceSHA256,
                selectedSliceByteCount: selectedSliceByteCount ?? target.selectedSliceByteCount,
                profileID: profileID ?? target.profileID,
                languageID: languageID ?? target.languageID,
                compilerSpecID: compilerSpecID ?? target.compilerSpecID,
                contextProfileSHA256: contextProfileSHA256 ?? target.contextProfileSHA256,
                context: context ?? target.context
            )))
        }

        add("rawCPUType", rawCPUType: "0100000d")
        add("rawCPUSubtype", rawCPUSubtype: "80000000")
        add("normalizedVariant", normalizedVariant: otherVariant)
        add("recognizedCapabilityBits", recognizedCapabilityBits: "00000000")
        add("pointerAuthABIVersion.presence", pointerAuthABIVersion: .some(nil))
        add("pointerAuthABIVersion.value", pointerAuthABIVersion: .some(1))
        add("selectedSliceSHA256", selectedSliceSHA256: String(repeating: "b", count: 64))
        add("selectedSliceByteCount", selectedSliceByteCount: .init(5))
        add("profileID", profileID: target.profileID + ".changed")
        add("languageID", languageID: target.languageID + ".changed")
        add("compilerSpecID", compilerSpecID: "changed")
        add("contextProfileSHA256", contextProfileSHA256: String(repeating: "c", count: 64))
        for index in target.context.indices {
            var renamed = target.context
            renamed[index] = .init(name: renamed[index].name + "X", value: renamed[index].value)
            add("context[\(index)].name", context: renamed)
            var revalued = target.context
            revalued[index] = .init(name: revalued[index].name, value: revalued[index].value ^ 1)
            add("context[\(index)].value", context: revalued)
        }
        return mutations
    }

    func authoredLeafMutations(
        _ inputs: NativeDecompilerWireAuthoredInputs
    ) throws -> [(String, NativeDecompilerWireAuthoredInputs)] {
        var mutations: [(String, NativeDecompilerWireAuthoredInputs)] = []
        func add(_ label: String, _ replacement: NativeDecompilerWireAuthoredInputs) {
            mutations.append((label, replacement))
        }

        let baseName = inputs.names[0]
        add("names.count", replacing(inputs, names: []))
        add("name.address", replacing(inputs, names: [
            .init(
                address: .init(baseName.address.value + 1),
                subjectKind: baseName.subjectKind,
                name: baseName.name
            ),
        ]))
        add("name.subjectKind", replacing(inputs, names: [
            .init(address: baseName.address, subjectKind: .label, name: baseName.name),
        ]))
        add("name.name", replacing(inputs, names: [
            .init(address: baseName.address, subjectKind: baseName.subjectKind, name: "entryX"),
        ]))

        let signature = inputs.signatures[0]
        let returnType = try XCTUnwrap(signature.returnType)
        guard case let .dataPointer(pointee, indirectionLevel, pointerQualifiers) = returnType,
              case let .qualifiedValue(returnAtom, returnQualifiers) = pointee,
              case let .named(returnKind, returnName) = returnAtom
        else {
            throw NSError(domain: "NativeDecompilerCanonicalTest", code: 4)
        }
        let parameter = signature.parameters[0]
        guard case let .qualifiedValue(parameterAtom, parameterQualifiers) = parameter.type,
              case let .scalar(parameterScalar) = parameterAtom
        else {
            throw NSError(domain: "NativeDecompilerCanonicalTest", code: 5)
        }
        add("signatures.count", replacing(inputs, signatures: []))
        add("signature.functionAddress", replacing(inputs, signatures: [
            replacing(signature, functionAddress: .init(signature.functionAddress.value + 1)),
        ]))
        add("returnType.present", replacing(inputs, signatures: [
            replacing(signature, returnType: .some(nil)),
        ]))
        add("returnType.pointee.namedKind", replacing(inputs, signatures: [
            replacing(signature, returnType: .some(.dataPointer(
                pointee: .qualifiedValue(
                    atom: .named(kind: returnKind == .`struct` ? .union : .`struct`, name: returnName),
                    qualifiers: returnQualifiers
                ),
                indirectionLevel: indirectionLevel,
                pointerQualifiersByLevel: pointerQualifiers
            )))
        ]))
        add("returnType.pointee.name", replacing(inputs, signatures: [
            replacing(signature, returnType: .some(.dataPointer(
                pointee: .qualifiedValue(
                    atom: .named(kind: returnKind, name: returnName + "X"),
                    qualifiers: returnQualifiers
                ),
                indirectionLevel: indirectionLevel,
                pointerQualifiersByLevel: pointerQualifiers
            )))
        ]))
        add("returnType.pointee.qualifiers", replacing(inputs, signatures: [
            replacing(signature, returnType: .some(.dataPointer(
                pointee: .qualifiedValue(atom: returnAtom, qualifiers: .volatile),
                indirectionLevel: indirectionLevel,
                pointerQualifiersByLevel: pointerQualifiers
            )))
        ]))
        add("returnType.pointerQualifiers[0]", replacing(inputs, signatures: [
            replacing(signature, returnType: .some(.dataPointer(
                pointee: pointee,
                indirectionLevel: indirectionLevel,
                pointerQualifiersByLevel: [.constant]
            )))
        ]))
        add("parameterListState", replacing(inputs, signatures: [
            replacing(signature, parameterListState: .unspecified, parameters: [])
        ]))
        add("parameters.count", replacing(inputs, signatures: [
            replacing(signature, parameters: [])
        ]))
        add("parameter.name", replacing(inputs, signatures: [
            replacing(signature, parameters: [
                .init(name: parameter.name + "X", type: parameter.type),
            ])
        ]))
        add("parameter.type.scalarKind", replacing(inputs, signatures: [
            replacing(signature, parameters: [
                .init(
                    name: parameter.name,
                    type: .qualifiedValue(atom: .scalar(.signed32), qualifiers: parameterQualifiers)
                ),
            ])
        ]))
        add("parameter.type.qualifiers", replacing(inputs, signatures: [
            replacing(signature, parameters: [
                .init(
                    name: parameter.name,
                    type: .qualifiedValue(atom: .scalar(parameterScalar), qualifiers: .constant)
                ),
            ])
        ]))
        add("variadicState", replacing(inputs, signatures: [
            replacing(signature, variadicState: .variadic)
        ]))
        add("noReturnState", replacing(inputs, signatures: [
            replacing(signature, noReturnState: .noReturn)
        ]))

        let appliedType = inputs.appliedTypes[0]
        add("appliedTypes.count", replacing(inputs, appliedTypes: []))
        add("appliedType.address", replacing(inputs, appliedTypes: [
            .init(
                address: .init(appliedType.address.value + 1),
                subjectKind: appliedType.subjectKind,
                typeDefinitionName: appliedType.typeDefinitionName,
                byteCount: appliedType.byteCount
            ),
        ]))
        add("appliedType.typeDefinitionName", replacing(inputs, appliedTypes: [
            .init(
                address: appliedType.address,
                subjectKind: appliedType.subjectKind,
                typeDefinitionName: appliedType.typeDefinitionName + "X",
                byteCount: appliedType.byteCount
            ),
        ]))
        add("appliedType.byteCount", replacing(inputs, appliedTypes: [
            .init(
                address: appliedType.address,
                subjectKind: appliedType.subjectKind,
                typeDefinitionName: appliedType.typeDefinitionName,
                byteCount: .init(appliedType.byteCount.value + 1)
            ),
        ]))

        let definition = inputs.typeDefinitions[0]
        guard case let .record(definitionKind, definitionName, layoutRules, fields) = definition,
              let field = fields.first,
              case let .fixedArray(element, elementCount) = field.storage,
              case let .opaquePointerCarrier(carrierKind) = element,
              let minimumAlignment = field.minimumAlignment,
              let minimumAlignmentType = field.minimumAlignmentType,
              case let .qualifiedValue(minimumAtom, minimumQualifiers) = minimumAlignmentType,
              case let .scalar(minimumScalar) = minimumAtom
        else {
            throw NSError(domain: "NativeDecompilerCanonicalTest", code: 6)
        }
        func record(
            kind: NativeDecompilerWireAuthoredNamedKind = .`struct`,
            name: String = "Packet",
            rules: NativeDecompilerWireAuthoredLayoutRules,
            fields replacementFields: [NativeDecompilerWireAuthoredRecordField]
        ) -> NativeDecompilerWireAuthoredTypeDefinition {
            .record(kind: kind, name: name, layoutRules: rules, fields: replacementFields)
        }
        func replacingField(
            name: String? = nil,
            storage: NativeDecompilerWireAuthoredFieldStorage? = nil,
            minimumAlignment: NativeDecompilerWireUInt64?? = nil,
            minimumAlignmentType: NativeDecompilerWireAuthoredType?? = nil
        ) -> NativeDecompilerWireAuthoredRecordField {
            .init(
                name: name ?? field.name,
                storage: storage ?? field.storage,
                bitWidth: field.bitWidth,
                minimumAlignment: minimumAlignment ?? field.minimumAlignment,
                minimumAlignmentType: minimumAlignmentType ?? field.minimumAlignmentType,
                promotesInlineFields: field.promotesInlineFields
            )
        }
        add("typeDefinitions.count", replacing(inputs, typeDefinitions: []))
        add("definition.kind", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind == .`struct` ? .union : .`struct`,
                name: definitionName,
                rules: layoutRules,
                fields: fields
            ),
        ]))
        add("definition.name", replacing(inputs, typeDefinitions: [
            record(kind: definitionKind, name: definitionName + "X", rules: layoutRules, fields: fields),
        ]))
        add("layoutRules.isPacked", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: .init(
                    isPacked: !layoutRules.isPacked,
                    packAlignment: layoutRules.packAlignment,
                    minimumAlignment: layoutRules.minimumAlignment
                ),
                fields: fields
            ),
        ]))
        add("layoutRules.packAlignment.present", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: .init(
                    isPacked: layoutRules.isPacked,
                    packAlignment: nil,
                    minimumAlignment: layoutRules.minimumAlignment
                ),
                fields: fields
            ),
        ]))
        add("layoutRules.packAlignment.value", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: .init(
                    isPacked: layoutRules.isPacked,
                    packAlignment: .init(4),
                    minimumAlignment: layoutRules.minimumAlignment
                ),
                fields: fields
            ),
        ]))
        add("layoutRules.minimumAlignment.present", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: .init(
                    isPacked: layoutRules.isPacked,
                    packAlignment: layoutRules.packAlignment,
                    minimumAlignment: .init(16)
                ),
                fields: fields
            ),
        ]))
        add("fields.count", replacing(inputs, typeDefinitions: [
            record(kind: definitionKind, name: definitionName, rules: layoutRules, fields: []),
        ]))
        add("field.name", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: layoutRules,
                fields: [replacingField(name: field.name + "X")]
            ),
        ]))
        add("field.storage.count", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: layoutRules,
                fields: [replacingField(storage: .fixedArray(element: element, count: .init(elementCount.value + 1)))]
            ),
        ]))
        add("field.storage.element.kind", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: layoutRules,
                fields: [replacingField(storage: .fixedArray(
                    element: .opaquePointerCarrier(
                        kind: carrierKind == .functionPointer ? .pointerToArray : .functionPointer
                    ),
                    count: elementCount
                ))]
            ),
        ]))
        add("field.minimumAlignment.present", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: layoutRules,
                fields: [replacingField(minimumAlignment: .some(nil))]
            ),
        ]))
        add("field.minimumAlignment.value", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: layoutRules,
                fields: [replacingField(minimumAlignment: .some(.init(minimumAlignment.value + 1)))]
            ),
        ]))
        add("field.minimumAlignmentType.present", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: layoutRules,
                fields: [replacingField(minimumAlignmentType: .some(nil))]
            ),
        ]))
        add("field.minimumAlignmentType.scalarKind", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: layoutRules,
                fields: [replacingField(minimumAlignmentType: .some(.qualifiedValue(
                    atom: .scalar(minimumScalar == .unsigned32 ? .signed32 : .unsigned32),
                    qualifiers: minimumQualifiers
                )))]
            ),
        ]))
        add("field.minimumAlignmentType.qualifiers", replacing(inputs, typeDefinitions: [
            record(
                kind: definitionKind,
                name: definitionName,
                rules: layoutRules,
                fields: [replacingField(minimumAlignmentType: .some(.qualifiedValue(
                    atom: minimumAtom,
                    qualifiers: .constant
                )))]
            ),
        ]))
        return mutations
    }

    func replacing(
        _ inputs: NativeDecompilerWireAuthoredInputs,
        names: [NativeDecompilerWireAuthoredName]? = nil,
        signatures: [NativeDecompilerWireAuthoredSignature]? = nil,
        appliedTypes: [NativeDecompilerWireAppliedType]? = nil,
        typeDefinitions: [NativeDecompilerWireAuthoredTypeDefinition]? = nil
    ) -> NativeDecompilerWireAuthoredInputs {
        return .init(
            schemaVersion: inputs.schemaVersion,
            names: names ?? inputs.names,
            signatures: signatures ?? inputs.signatures,
            appliedTypes: appliedTypes ?? inputs.appliedTypes,
            typeDefinitions: typeDefinitions ?? inputs.typeDefinitions
        )
    }

    func replacing(
        _ signature: NativeDecompilerWireAuthoredSignature,
        functionAddress: NativeDecompilerWireUInt64? = nil,
        returnType: NativeDecompilerWireAuthoredType?? = nil,
        parameterListState: NativeDecompilerWireAuthoredParameterListState? = nil,
        parameters: [NativeDecompilerWireAuthoredParameter]? = nil,
        variadicState: NativeDecompilerWireAuthoredVariadicState? = nil,
        noReturnState: NativeDecompilerWireAuthoredNoReturnState? = nil
    ) -> NativeDecompilerWireAuthoredSignature {
        .init(
            functionAddress: functionAddress ?? signature.functionAddress,
            returnType: returnType ?? signature.returnType,
            parameterListState: parameterListState ?? signature.parameterListState,
            parameters: parameters ?? signature.parameters,
            variadicState: variadicState ?? signature.variadicState,
            noReturnState: noReturnState ?? signature.noReturnState
        )
    }

    func canonicalFields(_ data: Data) throws -> [CanonicalField] {
        var cursor = data.startIndex
        var fields: [CanonicalField] = []
        while cursor < data.endIndex {
            let nameBytes = try readToken(data, cursor: &cursor)
            let value = try readToken(data, cursor: &cursor)
            fields.append(.init(
                name: try XCTUnwrap(String(data: nameBytes, encoding: .utf8)),
                value: value
            ))
        }
        return fields
    }

    func readToken(_ data: Data, cursor: inout Data.Index) throws -> Data {
        let colon = try XCTUnwrap(data[cursor...].firstIndex(of: 0x3a))
        let lengthText = try XCTUnwrap(String(data: data[cursor..<colon], encoding: .utf8))
        let length = try XCTUnwrap(Int(lengthText))
        let valueStart = data.index(after: colon)
        let valueEnd = try XCTUnwrap(data.index(valueStart, offsetBy: length, limitedBy: data.endIndex))
        XCTAssertLessThan(valueEnd, data.endIndex)
        XCTAssertEqual(data[valueEnd], 0x0a)
        cursor = data.index(after: valueEnd)
        return data[valueStart..<valueEnd]
    }

    func dataField(_ name: String, in fields: [CanonicalField]) throws -> Data {
        try XCTUnwrap(fields.first { $0.name == name }?.value)
    }

    func textField(_ name: String, in fields: [CanonicalField]) throws -> String {
        try XCTUnwrap(String(data: dataField(name, in: fields), encoding: .utf8))
    }

    func data(hex: String) throws -> Data {
        let compact = hex.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else {
            throw NSError(domain: "NativeDecompilerCanonicalTest", code: 1)
        }
        var output = Data()
        output.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                throw NSError(domain: "NativeDecompilerCanonicalTest", code: 2)
            }
            output.append(byte)
            index = next
        }
        return output
    }

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func canonicalTokenByteCount(_ payloadByteCount: Int) -> Int {
        String(payloadByteCount).utf8.count + 1 + payloadByteCount + 1
    }

    func canonicalFieldByteCount(_ name: String, valueByteCount: Int) -> Int {
        canonicalTokenByteCount(name.utf8.count) + canonicalTokenByteCount(valueByteCount)
    }

    func expectedNamesOnlyCanonicalByteCount(_ nameLengths: [Int]) -> Int {
        var count = canonicalFieldByteCount(
            "domain",
            valueByteCount: "org.macscope.MacScope.native-authored-input.v1".utf8.count
        )
        count += canonicalFieldByteCount("authoredInputs.schemaVersion", valueByteCount: 8)
        count += canonicalFieldByteCount("authoredInputs.names.count", valueByteCount: 8)
        for (index, nameLength) in nameLengths.enumerated() {
            let prefix = "authoredInputs.names[\(index)]"
            count += canonicalFieldByteCount("\(prefix).address", valueByteCount: 8)
            count += canonicalFieldByteCount("\(prefix).subjectKind", valueByteCount: 1)
            count += canonicalFieldByteCount("\(prefix).name", valueByteCount: nameLength)
        }
        count += canonicalFieldByteCount("authoredInputs.signatures.count", valueByteCount: 8)
        count += canonicalFieldByteCount("authoredInputs.appliedTypes.count", valueByteCount: 8)
        count += canonicalFieldByteCount("authoredInputs.typeDefinitions.count", valueByteCount: 8)
        return count
    }

    func namesOnlyInputs(nameLengths: [Int]) -> NativeDecompilerWireAuthoredInputs {
        .init(
            schemaVersion: 1,
            names: nameLengths.enumerated().map { index, length in
                .init(
                    address: .init(UInt64(index)),
                    subjectKind: .function,
                    name: String(repeating: "n", count: length)
                )
            },
            signatures: [],
            appliedTypes: [],
            typeDefinitions: []
        )
    }

    func nameLengthsForCanonicalByteCount(_ target: Int) throws -> [Int] {
        let minimumLength = 1
        let maximumLength = 1_024
        let minimumToken = canonicalTokenByteCount(minimumLength)
        let maximumToken = canonicalTokenByteCount(maximumLength)
        let maximumDelta = maximumToken - minimumToken
        let deltaToLength = Dictionary(uniqueKeysWithValues: (minimumLength...maximumLength).map {
            (canonicalTokenByteCount($0) - minimumToken, $0)
        })

        for nameCount in 2...4_096 {
            let zeroValueSize = expectedNamesOnlyCanonicalByteCount(
                Array(repeating: 0, count: nameCount)
            )
            let fixedSize = zeroValueSize - nameCount * canonicalTokenByteCount(0)
            let requiredValueTokens = target - fixedSize
            let minimumValueTokens = nameCount * minimumToken
            let maximumValueTokens = nameCount * maximumToken
            guard requiredValueTokens >= minimumValueTokens,
                  requiredValueTokens <= maximumValueTokens
            else { continue }

            var lengths = Array(repeating: minimumLength, count: nameCount)
            var remainingDelta = requiredValueTokens - minimumValueTokens
            let maximumFilled = min(nameCount - 2, remainingDelta / maximumDelta)
            if maximumFilled > 0 {
                for index in 0..<maximumFilled {
                    lengths[index] = maximumLength
                }
                remainingDelta -= maximumFilled * maximumDelta
            }
            var foundPair: (Int, Int)?
            for firstLength in minimumLength...maximumLength {
                let firstDelta = canonicalTokenByteCount(firstLength) - minimumToken
                guard firstDelta <= remainingDelta else { break }
                if let secondLength = deltaToLength[remainingDelta - firstDelta] {
                    foundPair = (firstLength, secondLength)
                    break
                }
            }
            guard let foundPair else { continue }
            lengths[maximumFilled] = foundPair.0
            lengths[maximumFilled + 1] = foundPair.1
            if expectedNamesOnlyCanonicalByteCount(lengths) == target {
                return lengths
            }
        }
        throw NSError(domain: "NativeDecompilerCanonicalTest", code: 3)
    }
}

/// Authored-input v2 callee signature hints: wire shape, canonical identity shared
/// with the C++ bridge (CanonicalRequestTests.cpp `kCalleeHintGoldenDigest`), and
/// the snapshot builder's callee discovery.
extension NativeDecompilerWireCanonicalRequestTests {
    static let calleeHintGoldenDigest =
        "edee0ad39290c6ac2ff6fa65805d3f90b859bea5e512d337a526b6acef0c5d8c"

    static func mallocHint(address: UInt64 = 0x1_0000_2000) -> NativeDecompilerWireCalleeSignatureHint {
        .init(
            name: "_malloc",
            source: .sdk,
            signature: .init(
                functionAddress: .init(address),
                returnType: .dataPointer(
                    pointee: .qualifiedValue(atom: .void, qualifiers: []),
                    indirectionLevel: .init(1),
                    pointerQualifiersByLevel: [[]]
                ),
                parameterListState: .authoritative,
                parameters: [.init(name: "size", type: .qualifiedValue(atom: .darwinAlias(.sizeT), qualifiers: []))],
                variadicState: .fixed,
                noReturnState: .unspecified
            )
        )
    }

    static func hintedInputs(schemaVersion: UInt32 = 2) -> NativeDecompilerWireAuthoredInputs {
        .init(schemaVersion: schemaVersion, names: [], signatures: [], appliedTypes: [], typeDefinitions: [],
              calleeSignatureHints: [mallocHint()])
    }

    func testCalleeHintV2DigestMatchesCrossLanguageGolden() throws {
        XCTAssertEqual(try digest(for: makeFixture(authoredInputs: Self.hintedInputs())),
                       Self.calleeHintGoldenDigest)
    }

    func testAuthoredV1RejectsCalleeHints() throws {
        XCTAssertThrowsError(try digest(for: makeFixture(authoredInputs: Self.hintedInputs(schemaVersion: 1))))
    }

    func testCalleeHintsChangeDigestAndV2WithoutHintsDiffersFromV1() throws {
        let empty = NativeDecompilerWireAuthoredInputs.empty
        let v2Empty = NativeDecompilerWireAuthoredInputs(schemaVersion: 2, names: [], signatures: [],
                                                         appliedTypes: [], typeDefinitions: [])
        let digests = try [empty, v2Empty, Self.hintedInputs()].map { try digest(for: makeFixture(authoredInputs: $0)) }
        XCTAssertEqual(Set(digests).count, 3)
    }

    func testAuthoredInputsCodecKeepsV1KeysAndRoundTripsV2() throws {
        let encoder = PropertyListEncoder()
        let v1 = try PropertyListSerialization.propertyList(
            from: encoder.encode(NativeDecompilerWireAuthoredInputs.empty), format: nil) as? [String: Any]
        XCTAssertNil(v1?["calleeSignatureHints"], "v1 authored inputs keep their exact key set")
        let v2 = Self.hintedInputs()
        let decoded = try PropertyListDecoder().decode(NativeDecompilerWireAuthoredInputs.self,
                                                       from: encoder.encode(v2))
        XCTAssertEqual(decoded, v2)
    }

    func testRecoveredCalleeBudgetCountsDeclinedAttempts() {
        assertRecoveredCalleeAttemptBudget(mixedResults: false)
    }

    func testRecoveredCalleeBudgetCountsMixedAttempts() {
        assertRecoveredCalleeAttemptBudget(mixedResults: true)
    }

    private func assertRecoveredCalleeAttemptBudget(
        mixedResults: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        let cap = NativeDecompilerSnapshotBuilder.maximumRecoveredCalleeHints
        XCTAssertEqual(cap, 32, file: file, line: line)
        let entry: UInt64 = 0x1_0000_1000
        let targets = (0..<(cap + 9)).map { entry + 0x1000 + UInt64($0 * 4) }
        let words: [UInt32] = targets.enumerated().map { index, target in
            let callAddress = entry + UInt64(index * 4)
            return 0x9400_0000 | UInt32((target - callAddress) / 4)
        }
        let bytes = Data(words.flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) }
        })
        let region = NativeDecompilerWireMemoryRegion(
            name: "__text", startAddress: .init(entry), permissions: .readExecute,
            rawBytes: bytes, effectiveBytes: bytes, appliedPatchIDs: [])
        var analysis = ImageAnalysis()
        analysis.symbols = targets.enumerated().map { index, target in
            let name = index == targets.count - 1 ? "_budget_sdk" : "_budget_callee_\(index)"
            return SymbolSummary(id: UUID(), name: name, address: target, kind: "function",
                                 libraryName: nil, rawLinkageName: name)
        }
        let catalog = CallSignatureCatalog([
            CallSignatureSpec(canonicalName: "budget_sdk", returnType: "void", parameters: []),
        ])
        var attempts: [UInt64] = []
        var accepted: [UInt64] = []
        let inputs = NativeDecompilerSnapshotBuilder.withCalleeSignatureHints(
            .empty, functionRegions: [region], functionRange: entry ..< entry + UInt64(bytes.count),
            analysis: analysis, overrides: [:], catalog: catalog,
            recoveredParameters: { target in
                attempts.append(target)
                guard mixedResults else { return nil }
                switch attempts.count % 3 {
                case 0:
                    accepted.append(target)
                    return [(name: "value", type: "int")]
                case 1:
                    return nil
                default:
                    // Non-nil recovery can still be rejected by wire type admission.
                    return [(name: "value", type: "struct MissingBudgetType")]
                }
            })
        XCTAssertEqual(attempts.count, cap, file: file, line: line)
        XCTAssertEqual(attempts, Array(targets.prefix(cap)), file: file, line: line)
        let recovered = inputs.calleeSignatureHints.filter { $0.source == .recovered }
        XCTAssertEqual(recovered.map { $0.signature.functionAddress.value }, accepted, file: file, line: line)
        XCTAssertEqual(recovered.count, mixedResults ? cap / 3 : 0, file: file, line: line)
        XCTAssertEqual(inputs.calleeSignatureHints.last?.source, .sdk, file: file, line: line)
        XCTAssertEqual(inputs.calleeSignatureHints.last?.signature.functionAddress.value, targets.last,
                       "Budget exhaustion must not suppress later catalog hints", file: file, line: line)
    }

    func testSnapshotBuilderHintsDirectAndTailCalleesFromCatalog() {
        let entry: UInt64 = 0x1_0000_1000
        // mov x0, #0x40; bl +0x20 (_malloc); b +0x40 (tail call to _free); bl +0x10 (unknown)
        let words: [UInt32] = [0xd280_0800, 0x9400_0008, 0x1400_0010, 0x9400_0004]
        let bytes = Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } })
        let region = NativeDecompilerWireMemoryRegion(
            name: "__text", startAddress: .init(entry), permissions: .readExecute,
            rawBytes: bytes, effectiveBytes: bytes, appliedPatchIDs: [])
        let range = entry ..< entry + UInt64(bytes.count)
        XCTAssertEqual(NativeDecompilerSnapshotBuilder.directCalleeAddresses(in: [region], functionRange: range),
                       [entry + 0x24, entry + 0x48, entry + 0x1c])
        var analysis = ImageAnalysis()
        analysis.symbols = [
            SymbolSummary(id: UUID(), name: "_malloc", address: entry + 0x24, kind: "function",
                          libraryName: nil, rawLinkageName: "_malloc"),
            SymbolSummary(id: UUID(), name: "_free", address: entry + 0x48, kind: "function",
                          libraryName: nil, rawLinkageName: "_free"),
        ]
        let catalog = CallSignatureCatalog([
            CallSignatureSpec(canonicalName: "malloc", returnType: "void *",
                              parameters: [.init(type: "size_t", name: "size")]),
            CallSignatureSpec(canonicalName: "free", returnType: "void",
                              parameters: [.init(type: "void *", name: "ptr")]),
        ])
        let inputs = NativeDecompilerSnapshotBuilder.withCalleeSignatureHints(
            .empty, functionRegions: [region], functionRange: range, analysis: analysis,
            overrides: [:], catalog: catalog)
        XCTAssertEqual(inputs.schemaVersion, 2)
        XCTAssertEqual(inputs.calleeSignatureHints.map(\.name), ["_malloc", "_free"])
        XCTAssertEqual(inputs.calleeSignatureHints.first, Self.mallocHint(address: entry + 0x24))
        // Recovered arity is the lowest-priority source: an in-image callee with no
        // debug/authored/SDK signature gets a hint from its own body when confident.
        let calleeStart = entry + 0x1c
        func row(_ offset: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            .init(address: calleeStart + offset, bytes: "", mnemonic: mnemonic, operands: operands,
                  hasBreakpoint: false, comment: nil)
        }
        let calleeRows = [row(0, "ldr", "x8, [x0]"), row(4, "add", "x0, x8, x1"), row(8, "ret", "")]
        let functions = [calleeStart: [FunctionSummary(id: UUID(), name: "_combine", startAddress: calleeStart,
                                                       endAddress: calleeStart + 12, confidence: 1)]]
        let recovered = NativeDecompilerSnapshotBuilder.recoveredCalleeParameters(
            target: calleeStart, functionsByStart: functions, instructions: calleeRows)
        XCTAssertEqual(recovered?.count, 2)
        var named = analysis
        named.symbols.append(SymbolSummary(id: UUID(), name: "_combine", address: calleeStart, kind: "function",
                                           libraryName: nil, rawLinkageName: "_combine"))
        let withRecovered = NativeDecompilerSnapshotBuilder.withCalleeSignatureHints(
            .empty, functionRegions: [region], functionRange: range, analysis: named,
            overrides: [:], catalog: catalog,
            recoveredParameters: { target in
                NativeDecompilerSnapshotBuilder.recoveredCalleeParameters(
                    target: target, functionsByStart: functions, instructions: calleeRows)
            })
        XCTAssertEqual(withRecovered.calleeSignatureHints.map(\.name), ["_combine", "_malloc", "_free"])
        XCTAssertEqual(withRecovered.calleeSignatureHints.first?.source, .recovered)
        XCTAssertEqual(withRecovered.calleeSignatureHints.first?.signature.parameters.count, 2)
        XCTAssertNil(withRecovered.calleeSignatureHints.first?.signature.returnType, "return stays unlocked")
        XCTAssertEqual(withRecovered.calleeSignatureHints.dropFirst().map(\.source), [.sdk, .sdk],
                       "recovered never shadows the SDK catalog")
        // A callee whose inputs live in SIMD registers is not a confident integer arity.
        let simdRows = [row(0, "fadd", "d0, d0, d1"), row(4, "ret", "")]
        XCTAssertNil(NativeDecompilerSnapshotBuilder.recoveredCalleeParameters(
            target: calleeStart, functionsByStart: functions, instructions: simdRows))
        // No hinted callee keeps the v1 request bytes.
        let none = NativeDecompilerSnapshotBuilder.withCalleeSignatureHints(
            .empty, functionRegions: [region], functionRange: range, analysis: ImageAnalysis(),
            overrides: [:], catalog: catalog)
        XCTAssertEqual(none, .empty)
    }
}

/// DP04 C1b, authored-input v3 local names: wire shape, canonical identity shared
/// with the C++ bridge (CanonicalRequestTests.cpp `kLocalNameGoldenDigest`), and the
/// snapshot builder's projection of stack local and register edits.
extension NativeDecompilerWireCanonicalRequestTests {
    static let localNameGoldenDigest = "876a784d4f673367ce9e1c584628167f42d4cd21f521377257655909cce77c48"

    static func localNamedInputs(schemaVersion: UInt32 = 3) -> NativeDecompilerWireAuthoredInputs {
        .init(schemaVersion: schemaVersion, names: [], signatures: [], appliedTypes: [], typeDefinitions: [],
              calleeSignatureHints: [], localNames: [
                  .init(storageKind: .register, stackOffset: 0, byteSize: 0, register: "x19", name: "total", type: nil),
                  .init(storageKind: .stack, stackOffset: -24, byteSize: 8, register: "", name: "count",
                        type: .qualifiedValue(atom: .scalar(.unsigned64), qualifiers: [])),
              ])
    }

    func testLocalNameV3DigestMatchesCrossLanguageGolden() throws {
        XCTAssertEqual(try digest(for: makeFixture(authoredInputs: Self.localNamedInputs())),
                       Self.localNameGoldenDigest)
    }

    func testAuthoredV1AndV2RejectLocalNames() throws {
        XCTAssertThrowsError(try digest(for: makeFixture(authoredInputs: Self.localNamedInputs(schemaVersion: 1))))
        XCTAssertThrowsError(try digest(for: makeFixture(authoredInputs: Self.localNamedInputs(schemaVersion: 2))))
    }

    func testAuthoredInputsCodecKeepsV2KeysAndRoundTripsV3() throws {
        let encoder = PropertyListEncoder()
        let v2 = try PropertyListSerialization.propertyList(
            from: encoder.encode(Self.hintedInputs()), format: nil) as? [String: Any]
        XCTAssertNil(v2?["localNames"], "v2 authored inputs keep their exact key set")
        let v3 = Self.localNamedInputs()
        XCTAssertEqual(try PropertyListDecoder().decode(NativeDecompilerWireAuthoredInputs.self,
                                                        from: encoder.encode(v3)), v3)
    }

    private static func localNameStorage(_ accesses: [(String, String)]) -> [MacIRStackStorage] {
        let program = [("sub", "sp, sp, #32")] + accesses + [("add", "sp, sp, #32"), ("ret", "")]
        let rows = program.enumerated().map { index, pair in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                           operands: pair.1, hasBreakpoint: false, comment: nil)
        }
        return MacIRBuilder().buildFunction(name: "locals", startAddress: 0x1000,
                                            instructions: rows).localVariables.compactMap(\.stackStorage)
    }

    func testStackStorageRecoveryRefusesUnknownUnalignedAndIncompleteCode() {
        let words: [UInt32] = [0xd10083ff, 0xf90007e0, 0x910083ff, 0xd65f03c0]
        func bytes(_ words: [UInt32]) -> Data {
            Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
        }
        func region(_ bytes: Data, start: UInt64) -> NativeDecompilerWireMemoryRegion {
            .init(name: "__text", startAddress: .init(start), permissions: .readExecute,
                  rawBytes: bytes, effectiveBytes: bytes, appliedPatchIDs: [])
        }
        let valid = region(bytes(words), start: 0x1000)
        XCTAssertEqual(NativeDecompilerSnapshotBuilder.recoveredStackStorage(
            functionRegions: [valid], functionRange: 0x1000..<0x1010,
            maximumInstructions: 4).map(\.authoringKey), ["-24:-16"])
        XCTAssertEqual(ARM64Decoder().decode(bytes([0]), baseAddress: 0x1008).first?.mnemonic, "unknown")
        let unknown = region(bytes(Array(words.prefix(2)) + [0] + Array(words.suffix(2))), start: 0x1000)
        XCTAssertTrue(NativeDecompilerSnapshotBuilder.recoveredStackStorage(
            functionRegions: [unknown], functionRange: 0x1000..<0x1014, maximumInstructions: 5).isEmpty)
        XCTAssertTrue(NativeDecompilerSnapshotBuilder.recoveredStackStorage(
            functionRegions: [region(bytes(words), start: 0x1001)],
            functionRange: 0x1001..<0x1011, maximumInstructions: 4).isEmpty)
        XCTAssertTrue(NativeDecompilerSnapshotBuilder.recoveredStackStorage(
            functionRegions: [region(bytes(Array(words.prefix(2))), start: 0x1000),
                              region(bytes(Array(words.suffix(1))), start: 0x100c)],
            functionRange: 0x1000..<0x1010, maximumInstructions: 4).isEmpty)
        XCTAssertTrue(NativeDecompilerSnapshotBuilder.recoveredStackStorage(
            functionRegions: [valid], functionRange: 0x1000..<0x1010, maximumInstructions: 3).isEmpty)
    }

    func testSnapshotBuilderRefusesAmbiguousAndUnrecoveredStackBindingsOnly() throws {
        let wide = Self.localNameStorage([("str", "x0, [sp, #8]")])
        let narrow = Self.localNameStorage([("str", "w0, [sp, #8]")])
        let disjoint = Self.localNameStorage([("str", "w1, [sp, #20]")])
        XCTAssertEqual(wide.map(\.authoringKey), ["-24:-16"])
        XCTAssertEqual(narrow.map(\.authoringKey), ["-24:-20"])
        XCTAssertEqual(disjoint.map(\.authoringKey), ["-12:-8"])
        let edits = ["-24:-16": StackLocalOverride(name: "wide"),
                     "-24:-20": StackLocalOverride(name: "narrow"),
                     "-12:-8": StackLocalOverride(name: "flag")]
        // Different-width overlap, duplicate live identities, and an unedited
        // overlapping local all refuse the affected binding, keeping other edits.
        for storage in [wide + narrow + disjoint, wide + wide + disjoint] {
            let inputs = NativeDecompilerSnapshotBuilder.withAuthoredLocalNames(
                .empty, stackLocals: edits, registerNames: ["x19": "total"], liveStackStorage: storage)
            XCTAssertEqual(inputs.localNames.map(\.name), ["flag", "total"])
            XCTAssertNoThrow(try digest(for: makeFixture(authoredInputs: inputs)))
        }
        let uneditedOverlap = NativeDecompilerSnapshotBuilder.withAuthoredLocalNames(
            .empty, stackLocals: ["-24:-16": StackLocalOverride(name: "wide")], registerNames: [:],
            liveStackStorage: wide + narrow)
        XCTAssertTrue(uneditedOverlap.localNames.isEmpty)
        let missingAuthority = NativeDecompilerSnapshotBuilder.withAuthoredLocalNames(
            .empty, stackLocals: edits, registerNames: ["x19": "total"])
        XCTAssertEqual(missingAuthority.localNames.map(\.name), ["total"])
        XCTAssertNoThrow(try digest(for: makeFixture(authoredInputs: missingAuthority)))
    }

    func testSnapshotBuilderProjectsStackLocalAndRegisterNames() {
        let inputs = NativeDecompilerSnapshotBuilder.withAuthoredLocalNames(
            Self.hintedInputs(),
            stackLocals: [
                "-24:-16": StackLocalOverride(name: "count", typeName: "uint64_t"),
                "-12:-8": StackLocalOverride(name: "flag", typeName: "struct Unknown *"),
                "-4:0": StackLocalOverride(typeName: "int32_t"),
            ],
            registerNames: ["w19": "total", "q0": "vector", "x20": "not valid"],
            liveStackStorage: Self.localNameStorage([
                ("str", "x0, [sp, #8]"), ("str", "w1, [sp, #20]"), ("str", "w2, [sp, #28]"),
            ])
        )
        XCTAssertEqual(inputs.schemaVersion, 3)
        XCTAssertEqual(inputs.calleeSignatureHints, Self.hintedInputs().calleeSignatureHints, "v2 hints are kept")
        XCTAssertEqual(inputs.localNames, [
            .init(storageKind: .stack, stackOffset: -12, byteSize: 4, register: "", name: "flag", type: nil),
            .init(storageKind: .stack, stackOffset: -24, byteSize: 8, register: "", name: "count",
                  type: .qualifiedValue(atom: .scalar(.unsigned64), qualifiers: [])),
            .init(storageKind: .stack, stackOffset: -4, byteSize: 4, register: "", name: "local_4",
                  type: .qualifiedValue(atom: .scalar(.signed32), qualifiers: [])),
            .init(storageKind: .register, stackOffset: 0, byteSize: 0, register: "x19", name: "total", type: nil),
        ], "an uncarried catalog type sends no native type; a type-only edit keeps Ghidra's default name; invalid registers/names drop")
        XCTAssertNoThrow(try digest(for: makeFixture(authoredInputs: inputs)))
        XCTAssertEqual(NativeDecompilerSnapshotBuilder.withAuthoredLocalNames(.empty, stackLocals: [:], registerNames: [:]),
                       .empty, "no edit keeps the v1 request bytes")
    }
}

/// `decompile-document` is bound into the request digest, so a document-only request and its
/// full counterpart never share a reply or a validated-cache entry.
extension NativeDecompilerWireCanonicalRequestTests {
    func testDocumentOperationIsBoundIntoTheDigestAndBinding() throws {
        let fixture = try makeFixture()
        let full = try digest(for: fixture)
        let documentSHA = try NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: fixture.schemaVersion, operation: .decompileDocument,
            target: fixture.target, image: fixture.image, function: fixture.function,
            memoryRegions: fixture.memoryRegions, symbols: fixture.symbols,
            authoredInputs: fixture.authoredInputs, budgets: fixture.budgets)
        XCTAssertEqual(fixture.operation, .decompile)
        XCTAssertNotEqual(documentSHA, full)
        let body = NativeDecompilerWireRequest(
            requestID: fixture.requestID, requestSHA256: documentSHA, target: fixture.target,
            image: fixture.image, function: fixture.function, memoryRegions: fixture.memoryRegions,
            symbols: fixture.symbols, authoredInputs: fixture.authoredInputs, budgets: fixture.budgets.wireValue)
        let envelope = NativeDecompilerWireRequestEnvelope(
            schemaVersion: fixture.schemaVersion, requestID: fixture.requestID, operation: .decompileDocument,
            body: body)
        XCTAssertEqual(NativeDecompilerWireExpectedRequestBinding(request: envelope).operation, .decompileDocument)
        // The Swift codec accepts the document operation and checks its digest.
        let codec = NativeDecompilerWireCodec()
        XCTAssertEqual(try codec.decodeRequest(try codec.encodeRequest(envelope, matching: fixture.requestID),
                                               matching: fixture.requestID), envelope)
    }
}

extension NativeDecompilerWireCanonicalRequestTests {
    /// DP12 #684: an override's variadic and return states reach the hint unchanged; an
    /// unspecified variadic axis is not asserted fixed, and an explicit `.returns` survives.
    func testOverrideHintKeepsTriStateVariadicAndReturnAxes() {
        let entry: UInt64 = 0x1_0000_1000
        let words: [UInt32] = [0x9400_0008, 0xd65f_03c0] // bl +0x20; ret
        let bytes = Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } })
        let region = NativeDecompilerWireMemoryRegion(
            name: "__text", startAddress: .init(entry), permissions: .readExecute,
            rawBytes: bytes, effectiveBytes: bytes, appliedPatchIDs: [])
        var analysis = ImageAnalysis()
        analysis.symbols = [SymbolSummary(id: UUID(), name: "_report", address: entry + 0x20, kind: "function",
                                          libraryName: nil, rawLinkageName: "_report")]
        var override = FunctionSignatureOverride(args: [ArgOverride(index: 0, name: "code", type: "int")])
        override.variadicState = .unspecified
        override.noReturnState = .returns
        let inputs = NativeDecompilerSnapshotBuilder.withCalleeSignatureHints(
            .empty, functionRegions: [region], functionRange: entry ..< entry + 8, analysis: analysis,
            overrides: [entry + 0x20: override], catalog: CallSignatureCatalog([]))
        let signature = inputs.calleeSignatureHints.first?.signature
        XCTAssertEqual(signature?.parameterListState, .authoritative)
        XCTAssertEqual(signature?.variadicState, .unspecified)
        XCTAssertEqual(signature?.noReturnState, .returns)
    }
}

extension NativeDecompilerWireCanonicalRequestTests {
    func testParameterStorageLeafMirrorsBridgeCanonicalRequest() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(try digest(for: fixture), Self.goldenDigest)
        let signature = fixture.authoredInputs.signatures[0]
        let parameter = signature.parameters[0]
        let changed = replacing(fixture.authoredInputs, signatures: [replacing(signature, parameters: [
            .init(name: parameter.name, type: parameter.type, storageRegister: "w20"),
        ])])
        let bytes = try preimage(for: replacing(fixture, authoredInputs: changed))
        XCTAssertEqual(try textField("authoredInputs.signatures[0].parameters[0].storage",
                                     in: canonicalFields(bytes)), "w20")
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("3:w20\n"))
        XCTAssertNotEqual(try digest(for: replacing(fixture, authoredInputs: changed)), Self.goldenDigest)
    }

    func testAuthoredParameterStorageRoundTripsAndValidates() throws {
        let type = NativeDecompilerWireAuthoredType.qualifiedValue(atom: .scalar(.signed64), qualifiers: [])
        let encoder = PropertyListEncoder()
        let absent = NativeDecompilerWireAuthoredParameter(name: "value", type: type)
        let plist = try PropertyListSerialization.propertyList(from: encoder.encode(absent), format: nil)
        XCTAssertNil((plist as? [String: Any])?["storageRegister"])
        let stored = NativeDecompilerWireAuthoredParameter(name: "value", type: type, storageRegister: "x20")
        XCTAssertEqual(try PropertyListDecoder().decode(NativeDecompilerWireAuthoredParameter.self,
                                                        from: encoder.encode(stored)), stored)
        let fixture = try makeFixture()
        for storage in ["", "x 20", "x20\t", "x20\u{2003}", String(repeating: "x", count: 1_025)] {
            let signature = replacing(fixture.authoredInputs.signatures[0], parameters: [
                .init(name: "value", type: type, storageRegister: storage),
            ])
            let authored = replacing(fixture.authoredInputs, signatures: [signature])
            XCTAssertThrowsError(try digest(for: replacing(fixture, authoredInputs: authored)), storage)
            let hinted = NativeDecompilerWireAuthoredInputs(
                schemaVersion: 2, names: [], signatures: [], appliedTypes: [], typeDefinitions: [],
                calleeSignatureHints: [.init(name: "callee", source: .swift, signature: signature)])
            XCTAssertThrowsError(try digest(for: makeFixture(authoredInputs: hinted)), storage)
        }
        for storage in ["x20", String(repeating: "x", count: 1_024)] {
            let signature = replacing(fixture.authoredInputs.signatures[0], parameters: [
                .init(name: "value", type: type, storageRegister: storage),
            ])
            XCTAssertNoThrow(try digest(for: replacing(fixture, authoredInputs:
                replacing(fixture.authoredInputs, signatures: [signature]))))
            XCTAssertNoThrow(try digest(for: makeFixture(authoredInputs: .init(
                schemaVersion: 2, names: [], signatures: [], appliedTypes: [], typeDefinitions: [],
                calleeSignatureHints: [.init(name: "callee", source: .swift, signature: signature)]))))
        }
    }

    func testSwiftConventionHintRules() throws {
        let types = try NativeAuthoredCatalogIndex(definitions: [])
        let rows: [(String, [String]?, [String])] = [
            ("$s4Main3FooC3barSiyKF", ["x20"], ["ERROR_REGISTER_UNMODELED"]),
            ("$s4Main3FooV3baryyFZ", [], []),
            ("$s4Main3FooC3barSiyYaKF", ["x20", "x22"], []),
            ("$s15CedarValidation5typedyS2iYaAA7TroubleOYKF", nil, ["TYPED_THROWS_LAYOUT"]),
            ("$s4Main3FooC3baryS2iF", ["", "x20"], []),
            ("$s4Main3FooC3baryS2iYaF", ["", "x20", "x22"], []),
            ("$s4Main3FooC3baryySSF", nil, ["STORAGE_AGGREGATE_H03"]),
            ("$s4Main3FooC3baryySJF", nil, ["PARAMETER_TYPE_UNMAPPED"]),
            ("$s4Main3FooC3baryycyF", nil, ["RESULT_TYPE_UNMAPPED"]),
            ("$s15CedarValidation10nestedHostyS2icSSF9incrementL_yS2iFTA", nil, ["WRAPPER_UNMODELED"]),
            ("$s4Main3FooC3baryyFTj", nil, ["WRAPPER_UNMODELED"]),
            ("$s4Main3FooV3baryyxlFZ", nil, ["STORAGE_GENERIC_H07"]),
            ("$s4Main3FooCACycfC", nil, ["STORAGE_AGGREGATE_H03"]),
            ("$s4Main3FooV3baryyFTu", nil, ["ASYNC_FUNCTION_POINTER_IS_DATA"]),
        ]
        for (index, row) in rows.enumerated() {
            let demangled = try XCTUnwrap(SwiftDemangler.demangleWithFacts(row.0), row.0)
            XCTAssertNotNil(demangled.facts, row.0)
            let result = NativeDecompilerSnapshotBuilder.swiftConventionHint(name: row.0, address: 0x1000, types: types)
            XCTAssertEqual(result.abstentions, row.2, "row \(index + 1): \(demangled.rendered)")
            guard let storage = row.1 else {
                XCTAssertNil(result.hint, row.0)
                continue
            }
            let hint = try XCTUnwrap(result.hint, row.0)
            XCTAssertEqual(hint.source, .swift)
            XCTAssertEqual(hint.signature.parameterListState, .authoritative)
            XCTAssertEqual(hint.signature.variadicState, .fixed)
            XCTAssertEqual(hint.signature.noReturnState, .unspecified)
            XCTAssertEqual(hint.signature.parameters.map { $0.storageRegister ?? "" }, storage, row.0)
            let returnSpelling = index == 1 ? "void" : "int64_t"
            XCTAssertEqual(hint.signature.returnType,
                           try NativeAuthoredTypeParserV1.parse(returnSpelling, role: .returnType, catalog: types))
            for parameter in hint.signature.parameters {
                let spelling = parameter.storageRegister == nil ? "int64_t" : "void *"
                XCTAssertEqual(parameter.type,
                               try NativeAuthoredTypeParserV1.parse(spelling, role: .parameter, catalog: types))
                if parameter.storageRegister == "x20" { XCTAssertEqual(parameter.name, "self") }
                if parameter.storageRegister == "x22" { XCTAssertEqual(parameter.name, "asyncContext") }
            }
        }
        for (name, params, result) in [
            ("$s4Main3FooC3baryS2iF", ["Swift.Int"], "Swift.Int"),
            ("$s4Main3FooC3baryS2iYaF", ["Swift.Int"], "Swift.Int"),
            ("$s4Main3FooC3baryySSF", ["Swift.String"], "()"),
            ("$s4Main3FooC3baryySJF", ["Swift.Character"], "()"),
            ("$s4Main3FooC3baryycyF", [], "() -> ()"),
        ] {
            let parsed = try XCTUnwrap(SwiftDemangler.demangleWithFacts(name))
            XCTAssertEqual(parsed.parameterTypes, params, name)
            XCTAssertEqual(parsed.resultType, result, name)
        }
        XCTAssertEqual(SwiftDemangler.demangleWithFacts(rows[7].0)?.facts?.hasNonScalarParameter, false)
        XCTAssertEqual(SwiftDemangler.demangleWithFacts(rows[8].0)?.facts?.hasNonScalarReturn, false)
    }

    func testSnapshotBuilderEmitsSwiftConventionHints() throws {
        let entry: UInt64 = 0x1_0000_1000
        let symbols = ["$s4Main3FooC3barSiyKF", "_catalog", "$s4Main3FooV3baryyFZ",
                       "$s4Main3FooC3baryS2iF", "$s4Main3FooC3baryySSF",
                       "$s15CedarValidation10nestedHostyS2icSSF9incrementL_yS2iFTA"]
        let targets = symbols.indices.map { entry + 0x1000 + UInt64($0 * 4) }
        func build(_ names: [String], overrides: [UInt64: FunctionSignatureOverride] = [:],
                   recover: @escaping (UInt64) -> [(name: String, type: String)]?) -> NativeDecompilerWireAuthoredInputs {
            let addresses = names.indices.map { entry + 0x1000 + UInt64($0 * 4) }
            let words = addresses.enumerated().map { index, target in
                UInt32(0x9400_0000) | UInt32((target - entry - UInt64(index * 4)) / 4)
            }
            let bytes = Data(words.flatMap { word in
                (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) }
            })
            let region = NativeDecompilerWireMemoryRegion(name: "__text", startAddress: .init(entry),
                permissions: .readExecute, rawBytes: bytes, effectiveBytes: bytes, appliedPatchIDs: [])
            var analysis = ImageAnalysis()
            analysis.symbols = zip(names, addresses).map { name, address in
                SymbolSummary(id: UUID(), name: name, address: address, kind: "function",
                              libraryName: nil, rawLinkageName: name)
            }
            return NativeDecompilerSnapshotBuilder.withCalleeSignatureHints(
                .empty, functionRegions: [region], functionRange: entry ..< entry + UInt64(bytes.count),
                analysis: analysis, overrides: overrides,
                catalog: CallSignatureCatalog([CallSignatureSpec(canonicalName: "catalog", returnType: "void", parameters: [])]),
                recoveredParameters: recover)
        }
        var attempts: [UInt64] = []
        let inputs = build(symbols) { address in
            attempts.append(address)
            return [(name: "recovered", type: "int64_t")]
        }
        XCTAssertEqual(inputs.calleeSignatureHints.map(\.source), [.swift, .sdk, .swift, .swift, .recovered, .recovered])
        XCTAssertEqual(attempts, Array(targets.suffix(2)))
        let signature = FunctionSignatureOverride(returnType: "void", parameterList: .authoritative([]))
        let overridden = build(symbols, overrides: [targets[0]: signature, targets[1]: signature]) { _ in nil }
        XCTAssertEqual(overridden.calleeSignatureHints.prefix(2).map(\.source), [.authored, .authored])
        let cap = NativeDecompilerSnapshotBuilder.maximumCalleeSignatureHints
        var recoveryCount = 0
        let capped = build(Array(repeating: symbols[0], count: cap + 1)) { _ in recoveryCount += 1; return nil }
        XCTAssertEqual(capped.calleeSignatureHints.count, cap)
        XCTAssertEqual(recoveryCount, 0)
        let budgeted = build(Array(repeating: symbols[0], count: cap - 40)
                             + (0..<40).map { "_unknown_\($0)" }) { _ in
            recoveryCount += 1
            return [(name: "value", type: "int64_t")]
        }
        XCTAssertEqual(recoveryCount, NativeDecompilerSnapshotBuilder.maximumRecoveredCalleeHints)
        XCTAssertEqual(budgeted.calleeSignatureHints.filter { $0.source == .recovered }.count,
                       NativeDecompilerSnapshotBuilder.maximumRecoveredCalleeHints)
    }
}
