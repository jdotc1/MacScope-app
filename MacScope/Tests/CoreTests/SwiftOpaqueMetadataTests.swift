import Foundation
import XCTest
@testable import MacScope

final class SwiftOpaqueMetadataTests: XCTestCase {
    func testOpaqueUnderlyingTypeAndParent() {
        var image = ImageBuilder()
        let moduleName = image.cstring("Example")
        let typeName = image.cstring("Si")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0)
        let moduleNameSlot = image.relSlot()
        let opaque = image.count
        image.u32(0x10004)
        let parentSlot = image.relSlot()
        let underlyingSlot = image.relSlot()
        let typeref = image.opaqueSymbolicReference(to: opaque)
        image.patchRel(moduleNameSlot, moduleName); image.patchRel(parentSlot, module)
        image.patchRel(underlyingSlot, typeName)
        let parser = image.opaqueParser(typeref: typeref)
        let report = parser.parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.records.first?.descriptorAddress, UInt64(opaque))
        XCTAssertEqual(report.records.first?.parentQualifiedName, "Example")
        XCTAssertEqual(report.records.first?.underlyingTypes.first?.mangledTypeName, "Si")
        XCTAssertEqual(report.records.first?.underlyingTypes.first?.typeName, "Swift.Int")
        XCTAssertEqual(report.records.first?.requirementCount, 0)
        XCTAssertTrue(parser.parseTypes().isEmpty)
    }

    func testOpaqueGenericRequirementsPrecedeUnderlyingNames() {
        var image = ImageBuilder()
        let name = image.cstring("Si")
        let parameter = image.cstring("x")
        image.align(4)
        let opaque = image.count
        image.u32(0x10084); image.u32(0)
        image.u16(1); image.u16(1); image.u16(1); image.u16(0)
        image.byte(0x80)
        image.align(4)
        image.u32(1)
        let requirementParameter = image.relSlot()
        let requirementType = image.relSlot()
        let underlying = image.relSlot()
        image.patchRel(requirementParameter, parameter); image.patchRel(requirementType, name)
        image.patchRel(underlying, name)
        let typeref = image.opaqueSymbolicReference(to: opaque)
        let report = image.opaqueParser(typeref: typeref).parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.first?.requirementCount, 1)
        XCTAssertEqual(report.records.first?.underlyingTypes.first?.mangledTypeName, "Si")
    }

    func testTruncatedOpaqueUnderlyingPointerIsDiagnosed() {
        var image = ImageBuilder()
        let typeref = image.count
        image.byte(1); let reference = image.relSlot(); image.byte(0)
        image.align(4)
        let opaque = image.count
        image.u32(0x10004); image.u32(0)
        image.patchRel(reference, opaque)
        let report = image.opaqueParser(typeref: typeref, typerefSize: 6).parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertTrue(report.diagnostics.contains { $0.message.contains("underlying") })
    }

    func testUnsupportedOpaqueGenericObjectsAreDiagnosed() {
        var image = ImageBuilder()
        image.align(4)
        let opaque = image.count
        image.u32(0x10084); image.u32(0)
        image.u16(0); image.u16(0); image.u16(0); image.u16(1)
        let typeref = image.opaqueSymbolicReference(to: opaque)
        let report = image.opaqueParser(typeref: typeref).parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertTrue(report.diagnostics.contains { $0.message.contains("Unsupported opaque generic") })
    }

    func testTypes2ReportsRawFlagsAndQualifiedName() {
        var image = ImageBuilder()
        let name = image.cstring("Example")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0); let nameSlot = image.relSlot()
        image.patchRel(nameSlot, name)
        let array = image.relSlot(); image.patchRel(array, module)
        let parser = image.opaqueParser(extra: [.init(name: "__swift5_types2", address: UInt64(array), fileOffset: UInt64(array), size: 4)])
        let report = parser.parseTypes2TargetsReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.first?.descriptorAddress, UInt64(module))
        XCTAssertEqual(report.records.first?.kind, 0)
        XCTAssertEqual(report.records.first?.flags, 0)
        XCTAssertEqual(report.records.first?.qualifiedName, "Example")
    }

    func testTruncatedTypes2EntryIsDiagnosed() {
        var image = ImageBuilder()
        image.byte(1); image.byte(2)
        let parser = image.opaqueParser(extra: [.init(name: "__swift5_types2", address: 0, fileOffset: 0, size: 2)])
        XCTAssertTrue(parser.parseTypes2TargetsReport().records.isEmpty)
        XCTAssertEqual(parser.parseTypes2TargetsReport().diagnostics.count, 1)
    }

    func testAccessorReferenceDiagnosesUnresolvedDescriptorDiscovery() {
        var image = ImageBuilder()
        let accessor = image.count
        image.u32(0xd65f03c0)
        let typeref = image.count
        image.byte(0x09)
        let reference = image.relSlot()
        image.byte(0)
        image.patchRel(reference, accessor)
        let report = image.opaqueParser(typeref: typeref).parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.accessorReferenceAddresses, [UInt64(reference)])
        XCTAssertEqual(report.diagnostics.count, 1)
        XCTAssertTrue(report.diagnostics[0].message.contains("Accessor function"))
    }

    func testStructuralDiscoveryRequiresValidParentAndTypeReferenceSection() {
        var image = ImageBuilder()
        let moduleName = image.cstring("Example")
        let underlying = image.cstring("Si")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0); let moduleNameSlot = image.relSlot()
        image.patchRel(moduleNameSlot, moduleName)
        let descriptor = image.count
        image.u32(0x10044); let parentSlot = image.relSlot(); let typeSlot = image.relSlot()
        image.patchRel(parentSlot, module); image.patchRel(typeSlot, underlying)
        let falseCandidate = image.count
        image.u32(0x10144); let invalidParent = image.relSlot(); let invalidType = image.relSlot()
        image.patchRel(invalidParent, module); image.patchRel(invalidType, underlying)
        let parser = image.opaqueParser(extra: [
            .init(name: "__swift5_typeref", address: UInt64(underlying), fileOffset: UInt64(underlying), size: 3)
        ])
        let report = parser.parseOpaqueTypeDescriptorsReport()
        XCTAssertEqual(report.structuralDescriptorAddresses, [UInt64(descriptor)])
        XCTAssertEqual(report.records.map(\.descriptorAddress), [UInt64(descriptor)])
        XCTAssertFalse(report.structuralDescriptorAddresses.contains(UInt64(falseCandidate)))
        XCTAssertTrue(report.callSiteDescriptorAddresses.isEmpty)
        // A valid-looking descriptor whose underlying name lives elsewhere is rejected.
        let outside = image.opaqueParser().parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(outside.structuralDescriptorAddresses.isEmpty)
    }

    func testStructuralDiscoveryContinuesPastOverlappingShortSection() {
        var image = ImageBuilder()
        let moduleName = image.cstring("Example")
        let underlying = image.cstring("Si")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0); let nameSlot = image.relSlot()
        image.patchRel(nameSlot, moduleName)
        let descriptor = image.count
        image.u32(0x10004); let parentSlot = image.relSlot(); let typeSlot = image.relSlot()
        image.patchRel(parentSlot, module); image.patchRel(typeSlot, underlying)
        let parser = SwiftMetadataParser(data: Data(image.data), sections: [
            .init(name: "__swift5_typeref", address: UInt64(underlying), fileOffset: UInt64(underlying), size: 3),
            .init(name: "__data", address: UInt64(descriptor), fileOffset: UInt64(descriptor), size: 1),
            .init(name: "__constg_swiftt", address: 0, fileOffset: 0, size: UInt64(image.count), segmentName: "__TEXT")
        ])
        let report = parser.parseOpaqueTypeDescriptorsReport()
        XCTAssertEqual(underlying, 8)
        XCTAssertEqual(descriptor, 24)
        XCTAssertEqual(report.records.map(\.descriptorAddress), [UInt64(descriptor)])
        XCTAssertEqual(report.structuralDescriptorAddresses, [UInt64(descriptor)])
        XCTAssertTrue(report.diagnostics.isEmpty)
    }

    func testStructuralAcceptanceRecoversAfterFailedOverlappingSymbolicAttempt() {
        var image = ImageBuilder()
        let moduleName = image.cstring("Example")
        let underlying = image.cstring("Si")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0); let nameSlot = image.relSlot()
        image.patchRel(nameSlot, moduleName)
        let descriptor = image.count
        image.u32(0x10004); let parentSlot = image.relSlot(); let typeSlot = image.relSlot()
        image.patchRel(parentSlot, module); image.patchRel(typeSlot, underlying)
        let reference = image.opaqueSymbolicReference(to: descriptor)
        let parser = SwiftMetadataParser(data: Data(image.data), sections: [
            .init(name: "__swift5_typeref", address: UInt64(underlying), fileOffset: UInt64(underlying), size: 3),
            .init(name: "__data", address: UInt64(descriptor), fileOffset: UInt64(descriptor), size: 1),
            .init(name: "__swift5_typeref", address: UInt64(reference), fileOffset: UInt64(reference), size: 6),
            .init(name: "__constg_swiftt", address: 0, fileOffset: 0, size: UInt64(image.count), segmentName: "__TEXT")
        ])
        let report = parser.parseOpaqueTypeDescriptorsReport()
        XCTAssertEqual(report.records.map(\.descriptorAddress), [UInt64(descriptor)])
        XCTAssertEqual(report.structuralDescriptorAddresses, [UInt64(descriptor)])
        XCTAssertEqual(report.descriptorAddresses, [UInt64(descriptor)])
        XCTAssertEqual(report.symbolicReferenceKinds, [4])
        XCTAssertEqual(report.diagnostics.filter { $0.message == "Truncated opaque context header" }.count, 1)
    }

    func testUnreadableStructuralWordsAreCapped() {
        let image = ImageBuilder()
        let parser = SwiftMetadataParser(data: Data(image.data), sections: [
            .init(name: "__const", address: 0, fileOffset: 0,
                  size: UInt64(SwiftMetadataParser.Limits.maxTypes + 2) * 4, segmentName: "__TEXT")
        ])
        let report = parser.parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.diagnostics.filter { $0.message == "Truncated opaque descriptor section" }.count, SwiftMetadataParser.Limits.maxTypes)
        XCTAssertEqual(report.diagnostics.filter { $0.grade == .walkCapped }.count, 1)
        XCTAssertTrue(report.diagnostics.contains { $0.message == "Opaque unreadable structural words reached maxTypes cap" })
    }

    func testNonOpaqueSymbolicKindsRetainFileBoundedReporting() {
        for kind in [UInt32(0), 1, 16, 17, 18, 31] {
            var image = ImageBuilder()
            let target = image.count
            image.u32(kind)
            let reference = image.opaqueSymbolicReference(to: target)
            let parser = SwiftMetadataParser(data: Data(image.data), sections: [
                .init(name: "__data", address: UInt64(target), fileOffset: UInt64(target), size: 1),
                .init(name: "__swift5_typeref", address: UInt64(reference), fileOffset: UInt64(reference), size: 6)
            ])
            let report = parser.parseOpaqueTypeDescriptorsReport()
            XCTAssertEqual(report.symbolicReferenceKinds, [kind])
            XCTAssertTrue(report.records.isEmpty)
            XCTAssertTrue(report.descriptorAddresses.isEmpty)
            XCTAssertTrue(report.diagnostics.isEmpty)
        }
    }

    func testUnderlyingSlotCannotUseUnmappedFileBytes() {
        var image = ImageBuilder()
        let moduleName = image.cstring("Example")
        let underlying = image.cstring("Si")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0); let nameSlot = image.relSlot()
        image.patchRel(nameSlot, moduleName)
        let descriptor = image.count
        image.u32(0x10004); let parentSlot = image.relSlot(); let typeSlot = image.relSlot()
        image.patchRel(parentSlot, module); image.patchRel(typeSlot, underlying)
        let parser = SwiftMetadataParser(data: Data(image.data), sections: [
            .init(name: "__swift5_typeref", address: UInt64(underlying), fileOffset: UInt64(underlying), size: 3),
            .init(name: "__cstring", address: 0, fileOffset: 0, size: UInt64(descriptor)),
            .init(name: "__constg_swiftt", address: UInt64(descriptor), fileOffset: UInt64(descriptor), size: 9, segmentName: "__TEXT")
        ])
        let report = parser.parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertTrue(report.structuralDescriptorAddresses.isEmpty)
    }

    func testDescriptorReadsStayInTheirOriginalSection() {
        var image = ImageBuilder()
        let moduleName = image.cstring("Example")
        let underlying = image.cstring("Si")
        let parameter = image.cstring("x")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0); let moduleNameSlot = image.relSlot()
        image.patchRel(moduleNameSlot, moduleName)
        let descriptor = image.count
        image.u32(0x10084); let parent = image.relSlot()
        image.u16(1); image.u16(1); image.u16(1); image.u16(0)
        image.byte(0x80); image.align(4)
        image.u32(1); let parameterSlot = image.relSlot(); let requirementSlot = image.relSlot()
        let underlyingSlot = image.relSlot()
        let descriptorSize = image.count - descriptor
        image.patchRel(parent, module); image.patchRel(parameterSlot, parameter)
        image.patchRel(requirementSlot, underlying); image.patchRel(underlyingSlot, underlying)
        let reference = image.opaqueSymbolicReference(to: descriptor)
        // All physical bytes exist. Even mapped adjacent bytes cannot complete the descriptor.
        // Covers flags, parent, generic header, parameter, alignment, requirement and type slot.
        for size in 1...descriptorSize {
            let parser = SwiftMetadataParser(data: Data(image.data), sections: [
                .init(name: "__cstring", address: 0, fileOffset: 0, size: UInt64(descriptor)),
                .init(name: "__constg_swiftt", address: UInt64(descriptor), fileOffset: UInt64(descriptor), size: UInt64(size), segmentName: "__TEXT"),
                .init(name: "__swift5_typeref", address: UInt64(reference), fileOffset: UInt64(reference), size: 6),
                .init(name: "__const", address: UInt64(descriptor + size), fileOffset: UInt64(descriptor + size), size: UInt64(descriptorSize - size), segmentName: "__DATA")
            ])
            let report = parser.parseOpaqueTypeDescriptorsReport()
            if size == descriptorSize {
                XCTAssertEqual(report.records.map(\.descriptorAddress), [UInt64(descriptor)])
                XCTAssertTrue(report.diagnostics.isEmpty)
            } else {
                XCTAssertTrue(report.records.isEmpty, "descriptor section size \(size)")
            }
        }
    }

    func testStructuralDiscoveryRejectsZeroUnderlyingTypes() {
        var image = ImageBuilder()
        let moduleName = image.cstring("Example")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0); let moduleNameSlot = image.relSlot()
        image.patchRel(moduleNameSlot, moduleName)
        let descriptor = image.count
        image.u32(4); let parent = image.relSlot(); image.patchRel(parent, module)
        let report = image.opaqueParser().parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertTrue(report.structuralDescriptorAddresses.isEmpty)
        XCTAssertFalse(report.descriptorAddresses.contains(UInt64(descriptor)))
        XCTAssertTrue(report.diagnostics.isEmpty)
    }

    func testStructuralDiscoveryDrainsTransitiveRequirementRoots() {
        var image = ImageBuilder()
        let moduleName = image.cstring("Example")
        let underlying = image.cstring("Si")
        let parameter = image.cstring("x")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0); let moduleNameSlot = image.relSlot()
        image.patchRel(moduleNameSlot, moduleName)
        let outer = image.count
        image.u32(0x10084); let outerParent = image.relSlot()
        image.u16(1); image.u16(1); image.u16(1); image.u16(0)
        image.byte(0x80); image.align(4)
        image.u32(1); let outerParameter = image.relSlot(); let outerRequirement = image.relSlot()
        let outerUnderlying = image.relSlot()
        let outerEnd = image.count
        let inner = image.count
        image.u32(0x10084); let innerParent = image.relSlot()
        image.u16(1); image.u16(1); image.u16(1); image.u16(0)
        image.byte(0x80); image.align(4)
        image.u32(1); let innerParameter = image.relSlot(); let innerRequirement = image.relSlot()
        let innerUnderlying = image.relSlot()
        let leaf = image.count
        image.u32(0x10004); let leafParent = image.relSlot(); let leafUnderlying = image.relSlot()
        let dataEnd = image.count
        let innerReference = image.opaqueSymbolicReference(to: inner)
        let leafReference = image.opaqueSymbolicReference(to: leaf)
        for slot in [outerParent, innerParent, leafParent] { image.patchRel(slot, module) }
        for slot in [outerUnderlying, innerUnderlying, leafUnderlying] { image.patchRel(slot, underlying) }
        for slot in [outerParameter, innerParameter] { image.patchRel(slot, parameter) }
        image.patchRel(outerRequirement, innerReference); image.patchRel(innerRequirement, leafReference)
        let parser = SwiftMetadataParser(data: Data(image.data), sections: [
            .init(name: "__swift5_typeref", address: UInt64(underlying), fileOffset: UInt64(underlying), size: 3),
            .init(name: "__cstring", address: 0, fileOffset: 0, size: UInt64(outer)),
            .init(name: "__constg_swiftt", address: UInt64(outer), fileOffset: UInt64(outer), size: UInt64(outerEnd - outer), segmentName: "__TEXT"),
            .init(name: "__const", address: UInt64(inner), fileOffset: UInt64(inner), size: UInt64(dataEnd - inner), segmentName: "__DATA"),
            .init(name: "__cstring", address: UInt64(dataEnd), fileOffset: UInt64(dataEnd), size: UInt64(image.count - dataEnd))
        ])
        let report = parser.parseOpaqueTypeDescriptorsReport()
        XCTAssertEqual(report.structuralDescriptorAddresses, [UInt64(outer)])
        XCTAssertEqual(report.records.map(\.descriptorAddress), [UInt64(outer), UInt64(inner), UInt64(leaf)])
        XCTAssertEqual(report.descriptorAddresses, [UInt64(outer), UInt64(inner), UInt64(leaf)])
        XCTAssertTrue(report.diagnostics.isEmpty)
    }

    func testStructuralRootEnqueueCapIsDiagnosed() {
        var image = ImageBuilder()
        let typeReferences = image.count
        for _ in 0..<(SwiftMetadataParser.Limits.maxTypes - 1) { _ = image.cstring("Si") }
        let typeReferencesEnd = image.count
        let moduleName = image.cstring("Example")
        let parameter = image.cstring("x")
        image.align(4)
        let module = image.count
        image.u32(0); image.u32(0); let nameSlot = image.relSlot()
        image.patchRel(nameSlot, moduleName)
        let outer = image.count
        image.u32(0x10084); let parentSlot = image.relSlot()
        image.u16(1); image.u16(1); image.u16(1); image.u16(0)
        image.byte(0x80); image.align(4)
        image.u32(1); let parameterSlot = image.relSlot(); let requirementSlot = image.relSlot()
        let typeSlot = image.relSlot()
        let outerEnd = image.count
        let inner = image.count
        image.u32(0x10004); let innerParent = image.relSlot(); let innerType = image.relSlot()
        let innerEnd = image.count
        let reference = image.opaqueSymbolicReference(to: inner)
        image.patchRel(parentSlot, module); image.patchRel(innerParent, module)
        image.patchRel(parameterSlot, parameter); image.patchRel(requirementSlot, reference)
        image.patchRel(typeSlot, typeReferences); image.patchRel(innerType, typeReferences)
        let parser = SwiftMetadataParser(data: Data(image.data), sections: [
            .init(name: "__swift5_typeref", address: 0, fileOffset: 0, size: UInt64(typeReferencesEnd)),
            .init(name: "__cstring", address: UInt64(typeReferencesEnd), fileOffset: UInt64(typeReferencesEnd), size: UInt64(outer - typeReferencesEnd)),
            .init(name: "__constg_swiftt", address: UInt64(outer), fileOffset: UInt64(outer), size: UInt64(outerEnd - outer), segmentName: "__TEXT"),
            .init(name: "__const", address: UInt64(inner), fileOffset: UInt64(inner), size: UInt64(innerEnd - inner), segmentName: "__DATA"),
            .init(name: "__cstring", address: UInt64(reference), fileOffset: UInt64(reference), size: 6)
        ])
        let report = parser.parseOpaqueTypeDescriptorsReport()
        XCTAssertEqual(report.records.map(\.descriptorAddress), [UInt64(outer)])
        XCTAssertEqual(report.structuralDescriptorAddresses, [UInt64(outer)])
        XCTAssertFalse(report.descriptorAddresses.contains(UInt64(inner)))
        XCTAssertEqual(report.diagnostics.filter { $0.grade == .walkCapped }.count, 1)
        XCTAssertTrue(report.diagnostics.contains { $0.message == "Opaque mangled-name walk reached maxTypes cap" })
    }

    func testRuntimeCallsUseSignatureSpecificDescriptorRegisters() {
        for (symbol, argument) in [("_swift_getOpaqueTypeMetadata2", 2), ("_swift_getOpaqueTypeConformance2", 1)] {
            var image = ImageBuilder()
            let moduleName = image.cstring("Example")
            let underlying = image.cstring("Si")
            image.align(4)
            let module = image.count
            image.u32(0); image.u32(0); let moduleNameSlot = image.relSlot()
            image.patchRel(moduleNameSlot, moduleName)
            let descriptor = image.count
            image.u32(0x10044); let parent = image.relSlot(); let type = image.relSlot()
            image.patchRel(parent, module); image.patchRel(type, underlying)
            let got = image.count
            image.u32(0); image.u32(0)
            let stub = image.count
            image.u32(0x58000010 | (UInt32(((got - stub) / 4) & 0x7ffff) << 5))
            image.u32(0xd61f0200) // BR x16
            let code = image.count
            let delta = UInt32(bitPattern: Int32(descriptor - code)) & 0x1fffff
            image.u32(0x10000000 | (delta & 3) << 29 | (delta >> 2) << 5 | UInt32(argument))
            image.u32(0x94000000 | (UInt32(bitPattern: Int32((stub - code - 4) / 4)) & 0x03ffffff))
            image.u32(0xd65f03c0)
            let sections: [SwiftMetadataParser.Section] = [
                .init(name: "__constg_swiftt", address: 0, fileOffset: 0, size: UInt64(code)),
                .init(name: "__stubs", address: UInt64(stub), fileOffset: UInt64(stub), size: 8),
                .init(name: "__text", address: UInt64(code), fileOffset: UInt64(code), size: 12)
            ]
            let parser = SwiftMetadataParser(data: Data(image.data), sections: sections, bindNames: [UInt64(got): symbol])
            let report = parser.parseOpaqueTypeDescriptorsReport()
            XCTAssertEqual(report.callSiteDescriptorAddresses, [UInt64(descriptor)], symbol)
            XCTAssertTrue(report.structuralDescriptorAddresses.isEmpty)
            XCTAssertEqual(report.records.count, 1)
            XCTAssertTrue(report.diagnostics.isEmpty)
        }
    }

    func testRuntimeCallDoesNotCarryAddressAcrossUnknownInstruction() {
        var image = ImageBuilder()
        let code = image.count
        image.u32(0x10000002) // ADR x2, pc
        image.u32(0xd503203f) // Unknown instruction clears facts.
        image.u32(0x58000010 | (UInt32(3) << 5)) // LDR x16, bound slot
        image.u32(0xd63f0200) // BLR x16
        image.u32(0xd65f03c0)
        let got = image.count
        image.u32(0); image.u32(0)
        let parser = SwiftMetadataParser(data: Data(image.data), sections: [
            .init(name: "__text", address: UInt64(code), fileOffset: UInt64(code), size: 20),
            .init(name: "__got", address: UInt64(got), fileOffset: UInt64(got), size: 8)
        ], bindNames: [UInt64(got): "_swift_getOpaqueTypeMetadata2"])
        let report = parser.parseOpaqueTypeDescriptorsReport()
        XCTAssertTrue(report.callSiteDescriptorAddresses.isEmpty)
        XCTAssertTrue(report.diagnostics.contains { $0.address == UInt64(code + 12) && $0.message.contains("x2") })
    }

    func testOpaqueFieldReferencePreservesNominalOutput() {
        var image = ImageBuilder()
        let name = image.cstring("Container")
        let fieldName = image.cstring("value")
        let underlyingName = image.cstring("Si")
        image.align(4)
        let opaque = image.count
        image.u32(0x10004); image.u32(0); let underlying = image.relSlot()
        image.patchRel(underlying, underlyingName)
        let reference = image.opaqueSymbolicReference(to: opaque)
        image.align(4)
        let fields = image.count
        image.u32(0); image.u32(0); image.u16(0); image.u16(12); image.u32(1)
        image.u32(0); let fieldType = image.relSlot(); let fieldNameSlot = image.relSlot()
        image.patchRel(fieldType, reference); image.patchRel(fieldNameSlot, fieldName)
        let nominal = image.count
        image.u32(17); image.u32(0); let nameSlot = image.relSlot(); image.u32(0); let fieldsSlot = image.relSlot()
        image.u32(1); image.u32(0)
        image.patchRel(nameSlot, name); image.patchRel(fieldsSlot, fields)
        let types = image.relSlot(); image.patchRel(types, nominal)
        let parser = image.opaqueParser(extra: [
            .init(name: "__swift5_types", address: UInt64(types), fileOffset: UInt64(types), size: 4),
            .init(name: "__swift5_fieldmd", address: UInt64(fields), fileOffset: UInt64(fields), size: 28)
        ])
        let before = parser.parseTypes()
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(parser.parseOpaqueTypeDescriptors().count, 1)
        XCTAssertEqual(parser.parseTypes(), before)
    }
}

private extension ImageBuilder {
    mutating func opaqueSymbolicReference(to descriptor: Int) -> Int {
        let start = count; byte(1); let field = relSlot(); byte(0); patchRel(field, descriptor); return start
    }
    func opaqueParser(typeref: Int? = nil, typerefSize: Int = 6, extra: [SwiftMetadataParser.Section] = []) -> SwiftMetadataParser {
        var sections = extra
        if let typeref { sections.append(.init(name: "__swift5_typeref", address: UInt64(typeref), fileOffset: UInt64(typeref), size: UInt64(typerefSize))) }
        sections.append(.init(name: "__constg_swiftt", address: 0, fileOffset: 0, size: UInt64(data.count)))
        return SwiftMetadataParser(data: Data(data), sections: sections)
    }
}
