import Foundation
import CryptoKit
import XCTest
@testable import MacScope

final class DWARFFunctionSignatureTests: XCTestCase {
    func testReaderEmitsAuthoritativeMixedSignatureInSourceOrder() throws {
        let signatures = DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.typedSubprogram())
            .recoverSignatures()

        let signature = try XCTUnwrap(signatures[0x1234])
        XCTAssertEqual(signature.returnType, "Result")
        XCTAssertEqual(signature.variadicState, .fixed)
        XCTAssertEqual(signature.args.map(\.index), [0, 1])
        XCTAssertEqual(signature.args.map(\.name), ["scale", "values"])
        XCTAssertEqual(signature.args.map(\.type), ["double", "int*"])
        XCTAssertEqual(signature.args.map(\.provenance), [.debug, .debug])
        XCTAssertEqual(Set(signature.args.map(\.rowToken)).count, 2)
        XCTAssertTrue(signature.args.allSatisfy { !$0.rowToken.isEmpty })
        guard case .authoritative = signature.parameterList else {
            return XCTFail("DWARF must emit an authoritative parameter list")
        }
    }

    // MARK: - BUG-007: array DW_AT_upper_bound overflow

    /// `DW_AT_upper_bound == UInt64.max` made `arrayDimension` compute `upper + 1`
    /// and trap. `recoverSignatures()` runs on every imported dSYM, so the reader
    /// must degrade the unrepresentable bound to the unspecified dimension `[]`
    /// rather than aborting the process.
    func testArrayUpperBoundAtUInt64MaxDegradesToSentinelDimension() throws {
        let signatures = DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.arrayParameterSubprogram(upperBound: .max)
        ).recoverSignatures()

        let signature = try XCTUnwrap(signatures[0x7777])
        XCTAssertEqual(signature.args.map(\.type), ["int[]"],
                       "an unrepresentable bound renders as the unspecified dimension, not a trap")
    }

    /// An ordinary bound still renders the concrete count (upper_bound 9 → [10]),
    /// proving the overflow guard did not regress the normal path.
    func testArrayOrdinaryUpperBoundRendersConcreteCount() throws {
        let signatures = DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.arrayParameterSubprogram(upperBound: 9)
        ).recoverSignatures()

        let signature = try XCTUnwrap(signatures[0x7777])
        XCTAssertEqual(signature.args.map(\.type), ["int[10]"])
    }

    func testReaderDerivesDeterministicRowTokensFromFunctionAddressAndOrdinal() throws {
        let first = try XCTUnwrap(
            DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.typedSubprogram())
                .recoverSignatures()[0x1234]
        )
        let repeated = try XCTUnwrap(
            DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.typedSubprogram())
                .recoverSignatures()[0x1234]
        )
        let relocated = try XCTUnwrap(
            DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.typedSubprogram(address: 0x2234))
                .recoverSignatures()[0x2234]
        )

        XCTAssertEqual(first.args.map(\.rowToken), repeated.args.map(\.rowToken))
        XCTAssertNotEqual(first.args[0].rowToken, first.args[1].rowToken)
        XCTAssertNotEqual(first.args.map(\.rowToken), relocated.args.map(\.rowToken))
    }

    func testReaderUsesUndefinedForUnresolvableParameterType() throws {
        let signatures = DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.unresolvableParameterType())
            .recoverSignatures()

        let signature = try XCTUnwrap(signatures[0x5678])
        XCTAssertNil(signature.returnType)
        XCTAssertEqual(signature.variadicState, .fixed)
        XCTAssertEqual(signature.args.map(\.name), ["mystery"])
        XCTAssertEqual(signature.args.map(\.type), ["undefined"])
        XCTAssertEqual(signature.args.map(\.provenance), [.debug])
        guard case .authoritative = signature.parameterList else {
            return XCTFail("unsupported DWARF types must remain persisted in the authoritative list")
        }
    }

    func testReaderDetectsUnspecifiedParametersDIEAsVariadic() throws {
        let signatures = DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.variadicSubprogram())
            .recoverSignatures()

        let signature = try XCTUnwrap(signatures[0x9abc])
        XCTAssertEqual(signature.variadicState, .variadic)
        XCTAssertEqual(signature.args.map(\.index), [0])
        XCTAssertEqual(signature.args.map(\.name), ["format"])
        XCTAssertEqual(signature.args.map(\.type), ["char*"])
        XCTAssertEqual(signature.args.map(\.provenance), [.debug])
    }

    func testReaderKeepsNonPrototypedNoChildFunctionParameterListUnspecified() throws {
        let signature = try XCTUnwrap(
            DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.nonPrototypedReturnOnlySubprogram())
                .recoverSignatures()[0xabcd]
        )

        XCTAssertEqual(signature.returnType, "int")
        guard case .unspecified = signature.parameterList else {
            return XCTFail("a no-child DIE without positive prototype evidence must not declare (void)")
        }
        XCTAssertEqual(signature.variadicState, .unspecified)
    }

    func testReaderTreatsPrototypedNoChildFunctionAsExplicitVoid() throws {
        let signature = try XCTUnwrap(
            DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.prototypedVoidSubprogram())
                .recoverSignatures()[0xbcde]
        )

        guard case let .authoritative(rows) = signature.parameterList else {
            return XCTFail("DW_AT_prototyped is positive evidence for an empty fixed declaration")
        }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(signature.variadicState, .fixed)
    }

    func testReaderResolvesSpecificationSignatureEvidence() throws {
        let signature = try XCTUnwrap(
            DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.specificationBackedSubprogram())
                .recoverSignatures()[0xcdef]
        )

        XCTAssertEqual(signature.returnType, "int")
        XCTAssertEqual(signature.args.map(\.name), ["value"])
        XCTAssertEqual(signature.args.map(\.type), ["int"])
        XCTAssertEqual(signature.variadicState, .fixed)
    }

    func testReaderResolvesAbstractOriginAndPerParameterEvidence() throws {
        let signature = try XCTUnwrap(
            DWARFFunctionSignatureReader(sections: SyntheticSignatureDWARF.abstractOriginBackedSubprogram())
                .recoverSignatures()[0xdef0]
        )

        XCTAssertEqual(signature.returnType, "int")
        XCTAssertEqual(signature.args.map(\.name), ["value"])
        XCTAssertEqual(signature.args.map(\.type), ["int"])
        XCTAssertEqual(signature.variadicState, .fixed)
    }

    func testReaderMatchesDwarfdumpOracleForRealDSYM() throws {
        let built = try RealSignatureDSYM.build()
        let sections = try built.dwarfSections()
        let signatures = DWARFFunctionSignatureReader(sections: sections).recoverSignatures()
        let oracle = try DwarfdumpSignatureOracle.function(named: "helper_beta", in: built.dsymURL)

        let signature = try XCTUnwrap(signatures[oracle.address])
        XCTAssertEqual(signature.returnType, oracle.returnType)
        XCTAssertEqual(signature.args.map(\.name), oracle.parameters.map(\.name))
        XCTAssertEqual(signature.args.map(\.type), oracle.parameters.map(\.type))
        XCTAssertEqual(signature.args.map(\.index), Array(0..<oracle.parameters.count))
        XCTAssertEqual(signature.args.map(\.provenance), Array(repeating: .debug, count: oracle.parameters.count))
        XCTAssertEqual(signature.variadicState, .fixed)

        let imported = try DSYMImportService().importDebugSymbols(at: built.dsymURL, expectedUUID: built.uuid)
        let declaration = try XCTUnwrap(imported.signatureDeclarations[oracle.address])
        XCTAssertEqual(imported.matchedUUID.lowercased(), built.uuid.lowercased())
        XCTAssertEqual(imported.debugArtifactSeal?.uuid, UUID(uuidString: built.uuid))
        XCTAssertNotNil(imported.matchedSliceArchitecture)
        XCTAssertEqual(declaration.parameters.map(\.name), ["a", "b"])
        XCTAssertEqual(declaration.parameters.map(\.type), ["int", "int"])
        XCTAssertEqual(declaration.returnType, signature.returnType)
    }

    @MainActor
    func testStoreInjectsRecoveredSignatureOverrides() throws {
        let address: UInt64 = 0x1000_0400
        let snapshot = Self.snapshot(uuid: "77777777-7777-7777-7777-777777777777", functionAddress: address)
        let store = WorkspaceStore(workspaceName: "signature-dsym", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        let signature = FunctionSignatureOverride(
            returnType: "int",
            args: [
                ArgOverride(index: 0, name: "a", type: "int"),
                ArgOverride(index: 1, name: "b", type: "int")
            ]
        )

        let result = DSYMImportResult(
            functions: [DWARFFunctionSymbol(address: address, name: "helper_beta")],
            signatures: [address: signature],
            matchedUUID: "77777777-7777-7777-7777-777777777777",
            dwarfURL: URL(fileURLWithPath: "/tmp/x.dSYM/Contents/Resources/DWARF/x")
        )
        store.injectDebugSymbols(result)

        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.signature, signature)
        XCTAssertEqual(store.snapshot.displayName(at: address, default: "raw"), "helper_beta")
    }

    func testDeclarationRetainsRawParameterEvidence() throws {
        let recovery = DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.objectiveCSubprogram(artificial: false)
        ).recoverSignaturesAndDeclarations()
        let declaration = try XCTUnwrap(recovery.declarations[0x3456])
        XCTAssertEqual(declaration.returnType, "id")
        XCTAssertEqual(declaration.parameters.map(\.name), ["self", "_cmd", "value"])
        XCTAssertEqual(declaration.parameters.map(\.type), ["id", "SEL", "int"])
        XCTAssertEqual(declaration.parameters.map(\.isArtificial), [false, false, false])
        XCTAssertNil(declaration.explicitObjectiveCParameters(selectorArity: 1))
        XCTAssertEqual(recovery.signatures[0x3456]?.args.map(\.name), ["self", "_cmd", "value"])
    }

    func testDeclarationDropsArtificialImplicitParametersOnlyWithCompleteMapping() throws {
        let declaration = try XCTUnwrap(DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.objectiveCSubprogram(artificial: true)
        ).recoverSignaturesAndDeclarations().declarations[0x3456])
        XCTAssertEqual(declaration.parameters.map(\.isArtificial), [true, true, false])
        XCTAssertEqual(declaration.parameters.prefix(2).map(\.name), ["receiver", "selector"])
        XCTAssertEqual(declaration.explicitObjectiveCParameters(selectorArity: 1)?.map(\.type), ["int"])
        XCTAssertNil(declaration.explicitObjectiveCParameters(selectorArity: 2))
    }

    func testDeclarationRefusesUnprovenImplicitParameterMapping() {
        let parameters: [DWARFFunctionDeclaration.Parameter] = [
            .init(name: "self", type: "id", isArtificial: false),
            .init(name: "_cmd", type: "SEL", isArtificial: false),
            .init(name: "value", type: "int", isArtificial: false)
        ]
        let original = DWARFFunctionDeclaration(
            returnType: "id", parameters: parameters,
            hasAuthoritativeParameterList: true, isVariadic: false
        )
        for index in 0..<2 {
            var missingName = original
            missingName.parameters[index].name = nil
            XCTAssertNil(missingName.explicitObjectiveCParameters(selectorArity: 1))
            var missingType = original
            missingType.parameters[index].type = nil
            XCTAssertNil(missingType.explicitObjectiveCParameters(selectorArity: 1))
            var wrongType = original
            wrongType.parameters[index].type = "int"
            XCTAssertNil(wrongType.explicitObjectiveCParameters(selectorArity: 1))
        }
        var unknownList = original
        unknownList.hasAuthoritativeParameterList = false
        XCTAssertNil(unknownList.explicitObjectiveCParameters(selectorArity: 1))
        var variadic = original
        variadic.isVariadic = true
        XCTAssertNil(variadic.explicitObjectiveCParameters(selectorArity: 1))
        var extraImplicit = original
        extraImplicit.parameters[2].isArtificial = true
        XCTAssertNil(extraImplicit.explicitObjectiveCParameters(selectorArity: 1))
        var absent = original
        absent.parameters = []
        XCTAssertNil(absent.explicitObjectiveCParameters(selectorArity: 0))
    }

    func testDeclarationKeepsUnresolvedTypeUnknown() throws {
        let recovery = DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.unresolvableParameterType()
        ).recoverSignaturesAndDeclarations()
        let declaration = try XCTUnwrap(recovery.declarations[0x5678])
        XCTAssertNil(declaration.returnType)
        XCTAssertNil(declaration.parameters.first?.type)
        XCTAssertEqual(recovery.signatures[0x5678]?.args.first?.type, "undefined")
    }

    // MARK: - 349: direct-method refusal and artificial-only implicit proof

    func test349C19C21DirectDeclarationAndSpecificationShapesRefuse() throws {
        for (name, arity, isClass) in [("directZero", 0, false), ("directOne:", 1, false),
                                      ("directClass", 0, true)] {
            for inherited in [false, true] {
                let input = SyntheticSignatureDWARF.ObjC349(
                    selector: name, arity: arity, isClass: isClass, inherited: inherited,
                    sourceDirect: true)
                let recovery = DWARFFunctionSignatureReader(
                    sections: SyntheticSignatureDWARF.objc349([input])
                ).recoverSignaturesAndDeclarations()
                let declaration = try XCTUnwrap(recovery.declarations[0x3456])
                XCTAssertTrue(recovery.refusedAddresses.isEmpty)
                XCTAssertNotNil(recovery.signatures[0x3456])
                XCTAssertTrue(declaration.isObjectiveCDirect)
                XCTAssertTrue(declaration.hasAuthoritativeParameterList)
                XCTAssertFalse(declaration.isVariadic)
                XCTAssertEqual(declaration.parameters.count, arity + 2)
                XCTAssertEqual(declaration.parameters.prefix(2).map(\.isArtificial), [true, true])
                XCTAssertTrue(declaration.parameters.allSatisfy { $0.name == nil })
                XCTAssertEqual(declaration.parameters.first?.type, isClass ? "Class" : "id")
                XCTAssertNil(declaration.explicitObjectiveCParameters(selectorArity: arity))
            }
        }
    }

    func test349DirectEvidenceWinsAcrossEverySignatureSource() throws {
        let directEvidence: [(Bool?, Bool?)] = [(true, nil), (true, false),
                                                (nil, true), (false, true)]
        for abstractOrigin in [false, true] {
            for (source, definition) in directEvidence {
                let input = SyntheticSignatureDWARF.ObjC349(
                    inherited: true, abstractOrigin: abstractOrigin,
                    sourceDirect: source, definitionDirect: definition)
                let declaration = try XCTUnwrap(DWARFFunctionSignatureReader(
                    sections: SyntheticSignatureDWARF.objc349([input])
                ).recoverSignaturesAndDeclarations().declarations[0x3456])
                XCTAssertEqual(declaration.parameters.count, 3)
                XCTAssertTrue(declaration.isObjectiveCDirect)
                XCTAssertNil(declaration.explicitObjectiveCParameters(selectorArity: 1))
            }
        }
    }

    func test349C22ConcreteOnlyDirectDefinitionRefusesWithoutSynthesizingSelector() throws {
        let input = SyntheticSignatureDWARF.ObjC349(sourceDirect: true, concreteOnly: true)
        let declaration = try XCTUnwrap(DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.objc349([input])
        ).recoverSignaturesAndDeclarations().declarations[0x3456])
        XCTAssertTrue(declaration.isObjectiveCDirect)
        XCTAssertEqual(declaration.parameters.map(\.type), ["id", "int"])
        XCTAssertEqual(declaration.parameters.map(\.isArtificial), [true, false])
        XCTAssertNil(declaration.explicitObjectiveCParameters(selectorArity: 1))
    }

    func test349OrdinaryTypeOnlyDeclarationAndArtificialAccessorsPass() throws {
        for (name, arity, artificialSubprogram) in [("value:", 1, false),
                                                   ("value", 0, true), ("setValue:", 1, true)] {
            let input = SyntheticSignatureDWARF.ObjC349(
                selector: name, arity: arity, inherited: true,
                artificialSubprogram: artificialSubprogram)
            let declaration = try XCTUnwrap(DWARFFunctionSignatureReader(
                sections: SyntheticSignatureDWARF.objc349([input])
            ).recoverSignaturesAndDeclarations().declarations[0x3456])
            XCTAssertFalse(declaration.isObjectiveCDirect)
            XCTAssertEqual(declaration.parameters.count, arity + 2)
            XCTAssertEqual(declaration.parameters.prefix(2).map(\.isArtificial), [true, true])
            XCTAssertTrue(declaration.parameters.allSatisfy { $0.name == nil })
            let explicit = try XCTUnwrap(declaration.explicitObjectiveCParameters(selectorArity: arity))
            XCTAssertEqual(explicit.map(\.type), Array(repeating: "int", count: arity))
            XCTAssertEqual(explicit.map(\.isArtificial), Array(repeating: false, count: arity))
        }
    }

    func test349F03EachImplicitFlagIsRequiredRegardlessOfNamesAndTypes() throws {
        for flags in [[false, false], [true, false], [false, true], [true, true]] {
            let input = SyntheticSignatureDWARF.ObjC349(
                named: true, receiverArtificial: flags[0], selectorArtificial: flags[1])
            let declaration = try XCTUnwrap(DWARFFunctionSignatureReader(
                sections: SyntheticSignatureDWARF.objc349([input])
            ).recoverSignaturesAndDeclarations().declarations[0x3456])
            XCTAssertFalse(declaration.isObjectiveCDirect)
            XCTAssertTrue(declaration.hasAuthoritativeParameterList)
            XCTAssertFalse(declaration.isVariadic)
            XCTAssertEqual(declaration.parameters.map(\.name), ["self", "_cmd", "value"])
            XCTAssertEqual(declaration.parameters.map(\.type), ["id", "SEL", "int"])
            XCTAssertEqual(declaration.parameters.map(\.isArtificial), flags + [false])
            if flags == [true, true] {
                let explicit = try XCTUnwrap(declaration.explicitObjectiveCParameters(selectorArity: 1))
                XCTAssertEqual(explicit, [.init(name: "value", type: "int", isArtificial: false)])
            } else {
                XCTAssertNil(declaration.explicitObjectiveCParameters(selectorArity: 1))
            }
        }
    }

    func test349DirectAndOrdinaryDeclarationsConflictInBothCUOrders() throws {
        let ordinary = SyntheticSignatureDWARF.ObjC349()
        var direct = ordinary
        direct.sourceDirect = true
        let ordinaryRecovery = DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.objc349([ordinary])
        ).recoverSignaturesAndDeclarations()
        let directRecovery = DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.objc349([direct])
        ).recoverSignaturesAndDeclarations()
        let ordinaryDeclaration = try XCTUnwrap(ordinaryRecovery.declarations[0x3456])
        var directDeclaration = try XCTUnwrap(directRecovery.declarations[0x3456])
        XCTAssertFalse(ordinaryDeclaration.isObjectiveCDirect)
        XCTAssertTrue(directDeclaration.isObjectiveCDirect)
        XCTAssertEqual(ordinaryRecovery.signatures, directRecovery.signatures)
        directDeclaration.isObjectiveCDirect = false
        XCTAssertEqual(ordinaryDeclaration, directDeclaration)
        for units in [[ordinary, direct], [direct, ordinary]] {
            let recovery = DWARFFunctionSignatureReader(
                sections: SyntheticSignatureDWARF.objc349(units)
            ).recoverSignaturesAndDeclarations()
            XCTAssertEqual(recovery.declarations, [:])
            XCTAssertEqual(recovery.signatures, [:])
            XCTAssertEqual(recovery.refusedAddresses, [0x3456])
        }
    }

    // MARK: - 346: raw declaration agreement across all CUs and DIEs

    func testIdenticalDeclarationsAcrossTwoCUsDedupeExactRecovery() {
        let declaration = SyntheticSignatureDWARF.ConflictDeclaration()
        assert346Recovery([[declaration], [declaration]], accepted: true)
    }

    func testFixedAgainstVariadicDeclarationsRefuseBothCUOrders() {
        let fixed = SyntheticSignatureDWARF.ConflictDeclaration()
        var variadic = fixed
        variadic.isVariadic = true
        for declarations in [[fixed, variadic], [variadic, fixed]] {
            assert346Recovery(declarations.map { [$0] }, accepted: false)
        }
    }

    func testDifferentReturnTypesRefuseBothCUOrders() {
        let object = SyntheticSignatureDWARF.ConflictDeclaration()
        var integer = object
        integer.returnType = "int"
        for declarations in [[object, integer], [integer, object]] {
            assert346Recovery(declarations.map { [$0] }, accepted: false)
        }
    }

    func testSelfArtificialFlagAloneRefusesBothCUOrdersDespiteEqualProjection() {
        let named = SyntheticSignatureDWARF.ConflictDeclaration()
        var artificial = named
        artificial.selfIsArtificial = true
        // Names, types and every projected signature field are unchanged.
        for declarations in [[named, artificial], [artificial, named]] {
            assert346Recovery(declarations.map { [$0] }, accepted: false)
        }
    }

    func testThreeCUsWithOneConflictCannotResurrectDeclaration() {
        let fixed = SyntheticSignatureDWARF.ConflictDeclaration()
        var variadic = fixed
        variadic.isVariadic = true
        for declarations in [[fixed, fixed, variadic], [fixed, variadic, fixed],
                             [variadic, fixed, fixed]] {
            assert346Recovery(declarations.map { [$0] }, accepted: false)
        }
    }

    func testConflictsWithinOneCURefuseBothDIEOrders() {
        let fixed = SyntheticSignatureDWARF.ConflictDeclaration()
        var variadic = fixed
        variadic.isVariadic = true
        for declarations in [[fixed, variadic], [variadic, fixed]] {
            assert346Recovery([declarations], accepted: false)
        }
    }

    func testEmptyProjectionParticipatesInConflictBothCUOrders() {
        let complete = SyntheticSignatureDWARF.ConflictDeclaration()
        var empty = complete
        empty.empty = true
        for declarations in [[complete, empty], [empty, complete]] {
            assert346Recovery(declarations.map { [$0] }, accepted: false)
        }
    }

    func testIdenticalEmptyDeclarationsAreAbsentNotRefused() {
        var empty = SyntheticSignatureDWARF.ConflictDeclaration()
        empty.empty = true
        let recovery = DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.conflictingCompileUnits([[empty], [empty]])
        ).recoverSignaturesAndDeclarations()
        XCTAssertEqual(recovery.signatures, [:])
        XCTAssertEqual(recovery.declarations, [:])
        XCTAssertEqual(recovery.refusedAddresses, [])
    }

    func testConflictDoesNotRemoveIndependentAddress() {
        let fixed = SyntheticSignatureDWARF.ConflictDeclaration()
        var variadic = fixed
        variadic.isVariadic = true
        var independent = fixed
        independent.address = 0x4567
        let recovery = DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.conflictingCompileUnits(
                [[fixed, independent], [variadic]])
        ).recoverSignaturesAndDeclarations()
        XCTAssertEqual(recovery.signatures, [0x4567: Self.expected346Signature(address: 0x4567)])
        XCTAssertEqual(recovery.declarations, [0x4567: Self.expected346Declaration])
        XCTAssertEqual(recovery.refusedAddresses, [0x3456])
    }

    private func assert346Recovery(
        _ units: [[SyntheticSignatureDWARF.ConflictDeclaration]],
        accepted: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let recovery = DWARFFunctionSignatureReader(
            sections: SyntheticSignatureDWARF.conflictingCompileUnits(units)
        ).recoverSignaturesAndDeclarations()
        XCTAssertEqual(recovery.signatures,
                       accepted ? [0x3456: Self.expected346Signature(address: 0x3456)] : [:],
                       file: file, line: line)
        XCTAssertEqual(recovery.declarations,
                       accepted ? [0x3456: Self.expected346Declaration] : [:],
                       file: file, line: line)
        XCTAssertEqual(recovery.refusedAddresses, accepted ? [] : [0x3456], file: file, line: line)
    }

    private static var expected346Declaration: DWARFFunctionDeclaration {
        .init(returnType: "id", parameters: [
            .init(name: "self", type: "id", isArtificial: false),
            .init(name: "_cmd", type: "SEL", isArtificial: false),
            .init(name: "value", type: "int", isArtificial: false)
        ], hasAuthoritativeParameterList: true, isVariadic: false)
    }

    private static func expected346Signature(address: UInt64) -> FunctionSignatureOverride {
        let parameters = [("self", "id"), ("_cmd", "SEL"), ("value", "int")]
        let args = parameters.enumerated().map { index, parameter in
            // Assert the established row identity contract, not a second reader result.
            let evidence = "dwarf-parameter-row-v1|\(String(format: "%016llx", address))|\(index)"
            let suffix = SHA256.hash(data: Data(evidence.utf8)).prefix(16)
                .map { String(format: "%02x", $0) }.joined()
            return ArgOverride(rowToken: "debug-\(suffix)", name: parameter.0,
                               type: parameter.1, provenance: .debug)
        }
        return .init(returnType: "id", parameterList: .authoritative(args), variadicState: .fixed)
    }

    private static func snapshot(uuid: String, functionAddress: UInt64) -> WorkspaceSnapshot {
        var metadata = BinaryMetadataSummary.empty
        metadata.uuid = uuid
        return WorkspaceSnapshot(
            binaries: [BinaryImage(
                id: UUID(),
                name: "x",
                path: "/tmp/x",
                kind: "Mach-O executable",
                architecture: "arm64",
                metadata: metadata
            )],
            functions: [FunctionSummary(id: UUID(), name: "sub_\(String(functionAddress, radix: 16))", startAddress: functionAddress, endAddress: functionAddress + 4, confidence: 1)],
            instructions: [],
            xrefs: [],
            hexBytes: Data(),
            sections: [SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x1000_0000, size: 0x10000, fileOffset: 0, isExecutable: true)]
        )
    }
}

private enum SyntheticSignatureDWARF {
    struct ObjC349 {
        var selector = "value:"
        var arity = 1
        var isClass = false
        var inherited = false
        var abstractOrigin = false
        var sourceDirect: Bool? = nil
        var definitionDirect: Bool? = nil
        var concreteOnly = false
        var artificialSubprogram = false
        var named = false
        var receiverArtificial = true
        var selectorArtificial = true
    }

    /// Synthetic address-bearing declaration views and CU-local inherited views.
    /// The declaration-only view deliberately supplies low_pc so Recovery can key it;
    /// this is not a claim that an uninstantiated clang declaration has machine code.
    static func objc349(_ units: [ObjC349]) -> DWARFReader.Sections {
        var abbrev = typedAbbrev()
        _ = abbrev.popLast()
        // Source subprogram: name, type, artificial, prototyped, declaration;
        // four variants cover low_pc present/absent and direct present/absent.
        for hasDirect in [false, true] {
            for hasAddress in [false, true] {
                let code: UInt8 = 0x30 + (hasAddress ? 1 : 0) + (hasDirect ? 2 : 0)
                abbrev.append(contentsOf: [code, 0x2e, 0x01, 0x03, 0x08, 0x49, 0x13,
                                           0x34, 0x0c, 0x27, 0x19, 0x3c, 0x0c])
                if hasAddress { abbrev.append(contentsOf: [0x11, 0x01]) }
                // ULEB128(0x3fee) = ee 7f; DW_FORM_flag = 0c.
                if hasDirect { abbrev.append(contentsOf: [0xee, 0x7f, 0x0c]) }
                abbrev.append(contentsOf: [0x00, 0x00])
            }
        }
        for hasDirect in [false, true] {
            for origin in [false, true] {
                let code: UInt8 = 0x34 + (origin ? 1 : 0) + (hasDirect ? 2 : 0)
                abbrev.append(contentsOf: [code, 0x2e, 0x00, 0x11, 0x01,
                                           origin ? 0x31 : 0x47, 0x13])
                if hasDirect { abbrev.append(contentsOf: [0xee, 0x7f, 0x0c]) }
                abbrev.append(contentsOf: [0x00, 0x00])
            }
        }
        for named in [false, true] {
            abbrev.append(contentsOf: [named ? 0x39 : 0x38, 0x05, 0x00, 0x49, 0x13, 0x34, 0x0c])
            if named { abbrev.append(contentsOf: [0x03, 0x08]) }
            abbrev.append(contentsOf: [0x00, 0x00])
        }
        abbrev.append(0x00)
        var info = Data()
        for input in units {
            var builder = DIEBuilder()
            builder.append(0x01)
            builder.mark("source")
            let sourceCode: UInt8 = 0x30 + (input.inherited ? 0 : 1) + (input.sourceDirect == nil ? 0 : 2)
            builder.append(sourceCode)
            builder.appendCString("\(input.isClass ? "+" : "-")[Example \(input.selector)]")
            builder.appendRef4(to: "int")
            builder.append(input.artificialSubprogram ? 1 : 0)
            builder.append(input.concreteOnly ? 0 : 1)
            if !input.inherited { builder.appendU64(0x3456) }
            if let direct = input.sourceDirect { builder.append(direct ? 1 : 0) }
            var parameters = [("self", input.isClass ? "Class" : "id", input.receiverArtificial)]
            if !input.concreteOnly { parameters.append(("_cmd", "SEL", input.selectorArtificial)) }
            parameters += (0..<input.arity).map { _ in ("value", "int", false) }
            for (name, type, artificial) in parameters {
                builder.append(input.named ? 0x39 : 0x38)
                builder.appendRef4(to: type)
                builder.append(artificial ? 1 : 0)
                if input.named { builder.appendCString(name) }
            }
            builder.append(0x00)
            if input.inherited {
                let definitionCode: UInt8 = 0x34 + (input.abstractOrigin ? 1 : 0) + (input.definitionDirect == nil ? 0 : 2)
                builder.append(definitionCode)
                builder.appendU64(0x3456)
                builder.appendRef4(to: "source")
                if let direct = input.definitionDirect { builder.append(direct ? 1 : 0) }
            }
            for (name, size) in [("id", UInt8(8)), ("Class", UInt8(8)), ("SEL", UInt8(8)), ("int", UInt8(4))] {
                builder.mark(name)
                builder.append(0x04)
                builder.appendCString(name)
                builder.append(size)
            }
            builder.append(0x00)
            info.append(assembleInfo(abbrev: abbrev, die: builder.resolvedDIE()).debugInfo)
        }
        return DWARFReader.Sections(debugInfo: info, debugAbbrev: Data(abbrev))
    }


    struct ConflictDeclaration {
        var address: UInt64 = 0x3456
        var returnType = "id"
        var isVariadic = false
        var selfIsArtificial = false
        var empty = false
    }

    /// Each outer element is a complete DWARF v4 CU. References are CU-relative
    /// and every CU uses the same abbreviation table at offset zero.
    static func conflictingCompileUnits(_ units: [[ConflictDeclaration]]) -> DWARFReader.Sections {
        var abbrev = typedAbbrev()
        _ = abbrev.popLast()
        // Formal parameter: name/string, type/ref4, artificial/flag.
        abbrev.append(contentsOf: [0x22, 0x05, 0x00, 0x03, 0x08, 0x49, 0x13, 0x34, 0x0c, 0x00, 0x00])
        // Unspecified parameters: no attributes or children.
        abbrev.append(contentsOf: [0x23, 0x18, 0x00, 0x00, 0x00])
        // An incomplete subprogram with only low_pc and no children.
        abbrev.append(contentsOf: [0x24, 0x2e, 0x00, 0x11, 0x01, 0x00, 0x00])
        abbrev.append(0x00)
        var info = Data()
        for declarations in units {
            var builder = DIEBuilder()
            builder.append(0x01)
            for declaration in declarations {
                if declaration.empty {
                    builder.append(0x24)
                    builder.appendU64(declaration.address)
                    continue
                }
                builder.append(0x02)
                builder.appendU64(declaration.address)
                builder.appendCString("-[Example value:]")
                builder.appendRef4(to: declaration.returnType)
                for (name, type, artificial) in [
                    ("self", "id", declaration.selfIsArtificial),
                    ("_cmd", "SEL", false), ("value", "int", false)
                ] {
                    builder.append(0x22)
                    builder.appendCString(name)
                    builder.appendRef4(to: type)
                    builder.append(artificial ? 0x01 : 0x00)
                }
                if declaration.isVariadic { builder.append(0x23) }
                builder.append(0x00)
            }
            for (name, size) in [("id", UInt8(8)), ("SEL", UInt8(8)), ("int", UInt8(4))] {
                builder.mark(name)
                builder.append(0x04)
                builder.appendCString(name)
                builder.append(size)
            }
            builder.append(0x00)
            info.append(assembleInfo(abbrev: abbrev, die: builder.resolvedDIE()).debugInfo)
        }
        return DWARFReader.Sections(debugInfo: info, debugAbbrev: Data(abbrev))
    }

    static func objectiveCSubprogram(artificial: Bool) -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.append(0x01)
        builder.append(0x02)
        builder.appendU64(0x3456)
        builder.appendCString("-[Example value:]")
        builder.appendRef4(to: "object_type")
        for (name, type, implicit) in [
            (artificial ? "receiver" : "self", "object_type", true),
            (artificial ? "selector" : "_cmd", "selector_type", true),
            ("value", "integer_type", false)
        ] {
            builder.append(0x22)
            builder.appendCString(name)
            builder.appendRef4(to: type)
            builder.append(implicit && artificial ? 0x01 : 0x00)
        }
        builder.append(0x00)
        for (label, name, size) in [("object_type", "id", UInt8(8)),
                                    ("selector_type", "SEL", UInt8(8)),
                                    ("integer_type", "int", UInt8(4))] {
            builder.mark(label)
            builder.append(0x04)
            builder.appendCString(name)
            builder.append(size)
        }
        builder.append(0x00)
        var abbrev = typedAbbrev()
        _ = abbrev.popLast()
        // Formal parameter: name/string, type/ref4, artificial/flag.
        abbrev.append(contentsOf: [0x22, 0x05, 0x00, 0x03, 0x08, 0x49, 0x13, 0x34, 0x0c, 0x00, 0x00, 0x00])
        return assembleInfo(abbrev: abbrev, die: builder.resolvedDIE())
    }

    static func typedSubprogram(address: UInt64 = 0x1234) -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.mark("compile_unit")
        builder.append(0x01)

        builder.mark("function")
        builder.append(0x02)
        builder.appendU64(address)
        builder.appendCString("synthetic_typed")
        builder.appendRef4(to: "typedef_result")

        builder.mark("param_scale")
        builder.append(0x03)
        builder.appendCString("scale")
        builder.appendRef4(to: "base_double")

        builder.mark("param_values")
        builder.append(0x03)
        builder.appendCString("values")
        builder.appendRef4(to: "pointer_int")

        builder.append(0x00)

        builder.mark("base_int")
        builder.append(0x04)
        builder.appendCString("int")
        builder.append(0x04)

        builder.mark("base_double")
        builder.append(0x04)
        builder.appendCString("double")
        builder.append(0x08)

        builder.mark("pointer_int")
        builder.append(0x06)
        builder.appendRef4(to: "base_int")

        builder.mark("typedef_result")
        builder.append(0x07)
        builder.appendCString("Result")
        builder.appendRef4(to: "base_int")

        builder.append(0x00)

        return assembleInfo(abbrev: typedAbbrev(), die: builder.resolvedDIE())
    }

    static func unresolvableParameterType() -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.mark("compile_unit")
        builder.append(0x01)

        builder.mark("function")
        builder.append(0x08)
        builder.appendU64(0x5678)
        builder.appendCString("unresolved")

        builder.mark("parameter")
        builder.append(0x03)
        builder.appendCString("mystery")
        builder.appendU32(0xffff_ffff)

        builder.append(0x00)
        builder.append(0x00)

        return assembleInfo(abbrev: unresolvedAbbrev(), die: builder.resolvedDIE())
    }

    static func variadicSubprogram() -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.mark("compile_unit")
        builder.append(0x01)

        builder.mark("function")
        builder.append(0x09)
        builder.appendU64(0x9abc)
        builder.appendCString("variadic")

        builder.mark("parameter")
        builder.append(0x03)
        builder.appendCString("format")
        builder.appendRef4(to: "pointer_char")

        builder.append(0x0a)
        builder.append(0x00)

        builder.mark("base_char")
        builder.append(0x04)
        builder.appendCString("char")
        builder.append(0x01)

        builder.mark("pointer_char")
        builder.append(0x06)
        builder.appendRef4(to: "base_char")

        builder.append(0x00)

        return assembleInfo(abbrev: variadicAbbrev(), die: builder.resolvedDIE())
    }

    /// A subprogram with one array-typed parameter `int buf[upperBound + 1]`.
    /// `DW_AT_upper_bound` is emitted as `DW_FORM_data8`, so a caller can drive it
    /// to `UInt64.max` — the value that made `arrayDimension`'s `upper + 1` trap.
    static func arrayParameterSubprogram(upperBound: UInt64, address: UInt64 = 0x7777) -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.mark("compile_unit")
        builder.append(0x01)

        builder.mark("function")
        builder.append(0x02)
        builder.appendU64(address)
        builder.appendCString("with_array")
        builder.appendRef4(to: "base_int")

        builder.mark("param")
        builder.append(0x03)
        builder.appendCString("buf")
        builder.appendRef4(to: "array_of_int")

        builder.append(0x00) // end subprogram children

        builder.mark("base_int")
        builder.append(0x04)
        builder.appendCString("int")
        builder.append(0x04) // byte_size (data1)

        builder.mark("array_of_int")
        builder.append(0x20)
        builder.appendRef4(to: "base_int")

        builder.mark("subrange")
        builder.append(0x21)
        builder.appendU64(upperBound) // DW_AT_upper_bound (data8)

        builder.append(0x00) // end array_type children
        builder.append(0x00) // end compile_unit children

        return assembleInfo(abbrev: arrayAbbrev(), die: builder.resolvedDIE())
    }

    /// Abbrev table for `arrayParameterSubprogram`: compile_unit, subprogram,
    /// formal_parameter, base_type, plus array_type (code 0x20) and
    /// subrange_type (code 0x21) carrying `DW_AT_upper_bound` as `DW_FORM_data8`.
    private static func arrayAbbrev() -> [UInt8] {
        var abbrev: [UInt8] = []
        // 0x01 compile_unit (0x11), has children, no attrs
        abbrev.append(contentsOf: [0x01, 0x11, 0x01, 0x00, 0x00])
        // 0x02 subprogram (0x2e), has children: low_pc/addr, name/string, type/ref4
        abbrev.append(contentsOf: [0x02, 0x2e, 0x01, 0x11, 0x01, 0x03, 0x08, 0x49, 0x13, 0x00, 0x00])
        // 0x03 formal_parameter (0x05), no children: name/string, type/ref4
        abbrev.append(contentsOf: [0x03, 0x05, 0x00, 0x03, 0x08, 0x49, 0x13, 0x00, 0x00])
        // 0x04 base_type (0x24), no children: name/string, byte_size/data1
        abbrev.append(contentsOf: [0x04, 0x24, 0x00, 0x03, 0x08, 0x0b, 0x0b, 0x00, 0x00])
        // 0x20 array_type (0x01), has children: type/ref4
        abbrev.append(contentsOf: [0x20, 0x01, 0x01, 0x49, 0x13, 0x00, 0x00])
        // 0x21 subrange_type (0x21), no children: upper_bound(0x2f)/data8(0x07)
        abbrev.append(contentsOf: [0x21, 0x21, 0x00, 0x2f, 0x07, 0x00, 0x00])
        abbrev.append(0x00)
        return abbrev
    }

    static func nonPrototypedReturnOnlySubprogram() -> DWARFReader.Sections {
        return noChildSubprogram(address: 0xabcd, prototyped: false)
    }

    static func prototypedVoidSubprogram() -> DWARFReader.Sections {
        return noChildSubprogram(address: 0xbcde, prototyped: true)
    }

    static func specificationBackedSubprogram() -> DWARFReader.Sections {
        referencedSubprogram(address: 0xcdef, referenceAttribute: 0x47, concreteHasParameter: false)
    }

    static func abstractOriginBackedSubprogram() -> DWARFReader.Sections {
        referencedSubprogram(address: 0xdef0, referenceAttribute: 0x31, concreteHasParameter: true)
    }

    private static func noChildSubprogram(address: UInt64, prototyped: Bool) -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.mark("compile_unit")
        builder.append(0x01)
        builder.mark("function")
        builder.append(prototyped ? 0x0c : 0x0b)
        builder.appendU64(address)
        builder.appendCString(prototyped ? "explicit_void" : "old_style")
        if !prototyped { builder.appendRef4(to: "base_int") }
        builder.mark("base_int")
        builder.append(0x04)
        builder.appendCString("int")
        builder.append(0x04)
        builder.append(0x00)

        var abbrev = typedAbbrev()
        _ = abbrev.popLast()
        abbrev.append(0x0b)
        abbrev.append(0x2e)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x11, 0x01, 0x03, 0x08, 0x49, 0x13, 0x00, 0x00])
        abbrev.append(0x0c)
        abbrev.append(0x2e)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x11, 0x01, 0x03, 0x08, 0x27, 0x19, 0x00, 0x00])
        abbrev.append(0x00)
        return assembleInfo(abbrev: abbrev, die: builder.resolvedDIE())
    }

    private static func referencedSubprogram(
        address: UInt64,
        referenceAttribute: UInt8,
        concreteHasParameter: Bool
    ) -> DWARFReader.Sections {
        var builder = DIEBuilder()
        builder.mark("compile_unit")
        builder.append(0x01)
        builder.mark("abstract_function")
        builder.append(0x0d)
        builder.appendCString("referenced")
        builder.appendRef4(to: "base_int")
        builder.mark("abstract_parameter")
        builder.append(0x03)
        builder.appendCString("value")
        builder.appendRef4(to: "base_int")
        builder.append(0x00)
        builder.mark("concrete_function")
        builder.append(concreteHasParameter ? 0x0f : 0x0e)
        builder.appendU64(address)
        builder.appendRef4(to: "abstract_function")
        if concreteHasParameter {
            builder.append(0x10)
            builder.appendRef4(to: "abstract_parameter")
            builder.append(0x00)
        }
        builder.mark("base_int")
        builder.append(0x04)
        builder.appendCString("int")
        builder.append(0x04)
        builder.append(0x00)

        var abbrev = typedAbbrev()
        _ = abbrev.popLast()
        abbrev.append(0x0d)
        abbrev.append(0x2e)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x03, 0x08, 0x49, 0x13, 0x27, 0x19, 0x00, 0x00])
        abbrev.append(0x0e)
        abbrev.append(0x2e)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x11, 0x01, referenceAttribute, 0x13, 0x00, 0x00])
        abbrev.append(0x0f)
        abbrev.append(0x2e)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x11, 0x01, referenceAttribute, 0x13, 0x00, 0x00])
        abbrev.append(0x10)
        abbrev.append(0x05)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [referenceAttribute, 0x13, 0x00, 0x00])
        abbrev.append(0x00)
        return assembleInfo(abbrev: abbrev, die: builder.resolvedDIE())
    }

    private static func typedAbbrev() -> [UInt8] {
        var abbrev: [UInt8] = []

        abbrev.append(0x01)
        abbrev.append(0x11)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x02)
        abbrev.append(0x2e)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x11, 0x01])
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x03)
        abbrev.append(0x05)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x04)
        abbrev.append(0x24)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x0b, 0x0b])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x05)
        abbrev.append(0x26)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x06)
        abbrev.append(0x0f)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x07)
        abbrev.append(0x16)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x00)
        return abbrev
    }

    private static func unresolvedAbbrev() -> [UInt8] {
        var abbrev: [UInt8] = []
        abbrev.append(0x01)
        abbrev.append(0x11)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x08)
        abbrev.append(0x2e)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x11, 0x01])
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x03)
        abbrev.append(0x05)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x49, 0x13])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x00)
        return abbrev
    }

    private static func variadicAbbrev() -> [UInt8] {
        var abbrev = typedAbbrev()
        _ = abbrev.popLast()

        abbrev.append(0x09)
        abbrev.append(0x2e)
        abbrev.append(0x01)
        abbrev.append(contentsOf: [0x11, 0x01])
        abbrev.append(contentsOf: [0x03, 0x08])
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x0a)
        abbrev.append(0x18)
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x00, 0x00])

        abbrev.append(0x00)
        return abbrev
    }

    private static func assembleInfo(abbrev: [UInt8], die: [UInt8]) -> DWARFReader.Sections {
        var body: [UInt8] = []
        body.append(contentsOf: [0x04, 0x00])
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        body.append(0x08)
        body.append(contentsOf: die)

        var info: [UInt8] = []
        let unitLength = UInt32(body.count)
        for i in 0..<4 {
            info.append(UInt8((unitLength >> (8 * i)) & 0xff))
        }
        info.append(contentsOf: body)
        return DWARFReader.Sections(debugInfo: Data(info), debugAbbrev: Data(abbrev))
    }

    private struct DIEBuilder {
        private static let cuHeaderSize = 11
        private var bytes: [UInt8] = []
        private var labels: [String: Int] = [:]
        private var refPatches: [(position: Int, target: String)] = []

        mutating func mark(_ label: String) {
            labels[label] = Self.cuHeaderSize + bytes.count
        }

        mutating func append(_ byte: UInt8) {
            bytes.append(byte)
        }

        mutating func appendCString(_ string: String) {
            bytes.append(contentsOf: string.utf8)
            bytes.append(0x00)
        }

        mutating func appendU64(_ value: UInt64) {
            for i in 0..<8 {
                bytes.append(UInt8((value >> (8 * i)) & 0xff))
            }
        }

        mutating func appendU32(_ value: UInt32) {
            for i in 0..<4 {
                bytes.append(UInt8((value >> (8 * i)) & 0xff))
            }
        }

        mutating func appendRef4(to label: String) {
            refPatches.append((bytes.count, label))
            bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        }

        func resolvedDIE() -> [UInt8] {
            var result = bytes
            for patch in refPatches {
                let offset = UInt32(labels[patch.target] ?? Int.max)
                for i in 0..<4 {
                    result[patch.position + i] = UInt8((offset >> (8 * i)) & 0xff)
                }
            }
            return result
        }
    }
}

private enum DwarfdumpSignatureOracle {
    struct FunctionSignature {
        var address: UInt64
        var returnType: String?
        var parameters: [(name: String, type: String)]
    }

    static func function(named targetName: String, in dsymURL: URL) throws -> FunctionSignature {
        let dwarfdump = URL(fileURLWithPath: "/usr/bin/dwarfdump")
        guard FileManager.default.isExecutableFile(atPath: dwarfdump.path) else {
            throw XCTSkip("dwarfdump unavailable on this host")
        }
        let output = try ProcessRunner.run(dwarfdump, ["--debug-info", dsymURL.path])
        let parsed = parse(output: output)
        guard let match = parsed[targetName] else {
            throw XCTSkip("dwarfdump did not report \(targetName); got \(parsed.keys.sorted())")
        }
        return match
    }

    private static func parse(output: String) -> [String: FunctionSignature] {
        struct PartialParameter {
            var name: String?
            var type: String?
        }

        struct PartialFunction {
            var name: String?
            var address: UInt64?
            var returnType: String?
            var parameters: [PartialParameter] = []
        }

        var functions: [String: FunctionSignature] = [:]
        var currentFunction: PartialFunction?
        var currentParameter: PartialParameter?

        func finishParameter() {
            if let parameter = currentParameter {
                currentFunction?.parameters.append(parameter)
                currentParameter = nil
            }
        }

        func finishFunction() {
            finishParameter()
            guard let function = currentFunction,
                  let name = function.name,
                  let address = function.address else {
                currentFunction = nil
                return
            }
            functions[name] = FunctionSignature(
                address: address,
                returnType: function.returnType,
                parameters: function.parameters.enumerated().map { index, parameter in
                    (name: parameter.name ?? "arg\(index)",
                     type: parameter.type ?? "undefined")
                }
            )
            currentFunction = nil
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.contains("DW_TAG_subprogram") {
                finishFunction()
                currentFunction = PartialFunction()
                continue
            }
            guard currentFunction != nil else { continue }
            if line.contains("DW_TAG_formal_parameter") {
                finishParameter()
                currentParameter = PartialParameter()
                continue
            }
            if line.contains("DW_TAG_"), !line.contains("DW_TAG_formal_parameter") {
                finishFunction()
                continue
            }
            if line.contains("NULL") {
                finishParameter()
                continue
            }
            if line.contains("DW_AT_low_pc") {
                currentFunction?.address = firstHexValue(in: line)
            } else if line.contains("DW_AT_name"), let name = quotedValue(in: line) {
                if currentParameter != nil {
                    currentParameter?.name = name
                } else {
                    currentFunction?.name = name
                }
            } else if line.contains("DW_AT_type"), let type = quotedValue(in: line) {
                if currentParameter != nil {
                    currentParameter?.type = type
                } else {
                    currentFunction?.returnType = type
                }
            }
        }
        finishFunction()
        return functions
    }

    private static func quotedValue(in line: String) -> String? {
        guard let first = line.firstIndex(of: "\"") else { return nil }
        let afterFirst = line.index(after: first)
        guard let second = line[afterFirst...].firstIndex(of: "\"") else { return nil }
        return String(line[afterFirst..<second])
    }

    private static func firstHexValue(in line: String) -> UInt64? {
        guard let range = line.range(of: "0x") else { return nil }
        var index = range.upperBound
        var scalars = ""
        while index < line.endIndex {
            let character = line[index]
            guard character.isHexDigit else { break }
            scalars.append(character)
            index = line.index(after: index)
        }
        return UInt64(scalars, radix: 16)
    }
}

private struct RealSignatureDSYM {
    struct Built {
        var dsymURL: URL
        var binaryURL: URL
        var dwarfURL: URL
        var uuid: String

        func dwarfSections() throws -> DWARFReader.Sections {
            let bytes = try Data(contentsOf: dwarfURL)
            let machO = try MachOParser().parse(bytes, options: MachOParseOptions(
                recoverStringLiterals: false,
                recoverObjectiveCMetadata: false,
                recoverSwiftMetadata: false,
                parseCodeSignature: false
            ))

            var sections = DWARFReader.Sections()
            for section in machO.sections where section.segmentName == "__DWARF" {
                guard let data = Self.sliceSection(section, bytes: bytes) else { continue }
                switch section.sectionName {
                case "__debug_info":
                    sections.debugInfo = data
                case "__debug_abbrev":
                    sections.debugAbbrev = data
                case "__debug_str":
                    sections.debugStr = data
                case "__debug_str_offs", "__debug_str_offsets":
                    sections.debugStrOffsets = data
                case "__debug_addr":
                    sections.debugAddr = data
                default:
                    break
                }
            }
            return sections
        }

        private static func sliceSection(_ section: MachOSection, bytes: Data) -> Data? {
            guard section.size > 0, let size = Int(exactly: section.size) else { return nil }
            let start = Int(section.fileOffset)
            let (end, overflow) = start.addingReportingOverflow(size)
            guard !overflow, start <= end, end <= bytes.count else { return nil }
            let base = bytes.startIndex
            return bytes.subdata(in: (base + start)..<(base + end))
        }
    }

    static func build() throws -> Built {
        let clang = URL(fileURLWithPath: "/usr/bin/clang")
        let dsymutil = URL(fileURLWithPath: "/usr/bin/dsymutil")
        guard FileManager.default.isExecutableFile(atPath: clang.path),
              FileManager.default.isExecutableFile(atPath: dsymutil.path) else {
            throw XCTSkip("clang/dsymutil unavailable on this host")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-signature-dsym-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sourceURL = dir.appendingPathComponent("x.c")
        try """
        int helper_alpha(int a) { return a + 1; }
        int helper_beta(int a, int b) { return a * b; }
        int main(void) { return helper_alpha(2) + helper_beta(3, 4); }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let objectURL = dir.appendingPathComponent("x.o")
        let binaryURL = dir.appendingPathComponent("x")

        try ProcessRunner.run(clang, ["-g", "-O0", "-c", "-o", objectURL.path, sourceURL.path])
        try ProcessRunner.run(clang, ["-g", "-O0", "-o", binaryURL.path, objectURL.path])
        try ProcessRunner.run(dsymutil, [binaryURL.path])

        let dsymURL = dir.appendingPathComponent("x.dSYM", isDirectory: true)
        let dwarfURL = dsymURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("DWARF", isDirectory: true)
            .appendingPathComponent("x")
        guard FileManager.default.fileExists(atPath: dwarfURL.path) else {
            throw XCTSkip("dsymutil did not produce a dSYM DWARF file on this host")
        }

        let bytes = try Data(contentsOf: binaryURL)
        let machO = try MachOParser().parse(bytes, options: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false,
            parseCodeSignature: false
        ))
        guard let uuid = machO.uuid?.stringValue else {
            throw XCTSkip("the test binary has no LC_UUID on this host")
        }

        return Built(dsymURL: dsymURL, binaryURL: binaryURL, dwarfURL: dwarfURL, uuid: uuid)
    }
}

private enum ProcessRunner {
    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(tool.lastPathComponent) failed (\(process.terminationStatus)): \(output)")
        }
        return output
    }
}
