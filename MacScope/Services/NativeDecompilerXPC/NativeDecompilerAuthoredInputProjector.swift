import CryptoKit
import Foundation

struct NativeDecompilerAuthoredInputProjector {
    static func project(
        workspace: WorkspaceSnapshot,
        imageSlot: ImageSlot,
        functionID: UUID,
        signatureAddresses: Set<UInt64>? = nil,
        appliedAddresses: Set<UInt64>? = nil
    ) -> NativeDecompilerSemanticInputState {
        do {
            var pass = NativeDecompilerAuthoredProjectionPass(
                workspace: workspace,
                imageSlot: imageSlot,
                functionID: functionID,
                signatureAddresses: signatureAddresses,
                appliedAddresses: appliedAddresses,
                contextPreview: false
            )
            return .valid(try pass.run())
        } catch let diagnostic as NativeAuthoredProjectionDiagnostic {
            return .invalid(diagnostic.qualified(to: imageSlot))
        } catch {
            return .invalid(
                .invalid(
                    id: .init(
                        code: "authoring-input-invalid",
                        imageSlot: imageSlot,
                        subject: "root"
                    )
                )
            )
        }
    }

    /// Structural subjects for context selection only. These placeholders have no semantic
    /// request identity and must never be serialized as a native authored request.
    static func contextCandidates(
        workspace: WorkspaceSnapshot,
        imageSlot: ImageSlot,
        functionID: UUID
    ) throws -> NativeDecompilerWireAuthoredInputs {
        var pass = NativeDecompilerAuthoredProjectionPass(
            workspace: workspace, imageSlot: imageSlot, functionID: functionID,
            signatureAddresses: nil, appliedAddresses: nil, contextPreview: true
        )
        return try pass.buildInputs()
    }
}

private struct NativeDecompilerAuthoredProjectionPass {
    private static let maximumNames = 4_096
    private static let maximumSignatures = 4_096
    private static let maximumParametersPerSignature = 256
    private static let maximumAppliedTypes = 4_096
    private static let maximumTypeDefinitions = 1_024
    private static let maximumAggregateMembers = 16_384
    private static let maximumSemanticNameBytes = 1_024
    private static let maximumCatalogTextBytes = 4_096
    private static let maximumCanonicalBytes = 1_048_576

    let workspace: WorkspaceSnapshot
    let imageSlot: ImageSlot
    let functionID: UUID
    let signatureAddresses: Set<UInt64>?
    let appliedAddresses: Set<UInt64>?
    let contextPreview: Bool

    mutating func run() throws -> NativeDecompilerAuthoredProjection {
        let authoredInputs = try buildInputs()
        let canonical: Data
        do {
            canonical = try NativeDecompilerWireCanonicalRequest
                .canonicalAuthoredInputBytes(authoredInputs)
        } catch let validation as NativeDecompilerWireAuthoredValidationError {
            throw mapCanonicalValidation(validation)
        }
        guard canonical.count <= Self.maximumCanonicalBytes else {
            throw bounds(code: "authored-canonical-bytes", subject: "root")
        }

        let digest = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
        return NativeDecompilerAuthoredProjection(
            authoredInputs: authoredInputs,
            canonicalIdentitySHA256: digest,
            canonicalByteCount: canonical.count
        )
    }

    mutating func buildInputs() throws -> NativeDecompilerWireAuthoredInputs {
        let binaries = workspace.binaries.filter { $0.slot == imageSlot }
        guard binaries.count == 1,
              let binary = binaries.first,
              let analysis = workspace.analysis(in: imageSlot),
              analysis.functions.filter({ $0.id == functionID }).count == 1
        else {
            throw invalid(code: "authoring-input-invalid", subject: "selection")
        }

        guard workspace.typeDefinitions.count <= Self.maximumTypeDefinitions else {
            throw bounds(code: "authored-type-definitions-count", subject: "type-catalog")
        }
        let orderedDefinitions = workspace.typeDefinitions.sorted(
            by: Self.sourceDefinitionPrecedes
        )
        for definition in orderedDefinitions {
            try validateCatalogText(definition.name, subject: "type-catalog")
        }

        let catalog = try NativeAuthoredCatalogIndex(definitions: orderedDefinitions)
        let overrides = workspace.overrides(in: imageSlot)
        let activeSignatureSources = activeSignatures(in: overrides, functions: analysis.functions)
        try validateAggregateMemberCount(
            definitions: orderedDefinitions,
            signatures: activeSignatureSources.map(\.signature)
        )

        let names = try projectNames(overrides: overrides, analysis: analysis)
        guard activeSignatureSources.count <= Self.maximumSignatures else {
            throw bounds(code: "authored-signatures-count", subject: "signatures")
        }
        let signatures: [NativeDecompilerWireAuthoredSignature]
        let appliedTypes: [NativeDecompilerWireAppliedType]
        let definitions: [NativeDecompilerWireAuthoredTypeDefinition]
        if contextPreview {
            signatures = activeSignatureSources.map { source in
                .init(functionAddress: .init(source.address), returnType: nil,
                      parameterListState: .unspecified, parameters: [],
                      variadicState: .unspecified, noReturnState: .unspecified)
            }
            let byName = Set(orderedDefinitions.map { NativeDecompilerExactUTF8Key($0.name) })
            appliedTypes = overrides.sorted(by: { $0.key < $1.key }).compactMap { address, override in
                guard let name = override.appliedTypeName,
                      byName.contains(NativeDecompilerExactUTF8Key(name)) else { return nil }
                return .init(address: .init(address), subjectKind: .memoryObject,
                             typeDefinitionName: name, byteCount: .init(1))
            }
            guard appliedTypes.count <= Self.maximumAppliedTypes else {
                throw bounds(code: "authored-applied-types-count", subject: "applied-types")
            }
            definitions = []
        } else {
            signatures = try projectSignatures(
                activeSignatureSources.filter { signatureAddresses?.contains($0.address) ?? true },
                catalog: catalog
            )
            let admittedOverrides = overrides.filter { address, _ in
                appliedAddresses?.contains(address) ?? true
            }
            // DP04 D2: a stack local typed with a catalog type (an accepted struct pointer)
            // brings that definition along, so the local-name projection can send its type.
            let functionStart = analysis.functions.first { $0.id == functionID }?.startAddress
            let localTypes = functionStart.map { start in
                workspace.stackLocalOverrides(forProcedureAt: start, in: imageSlot).values.compactMap { edit in
                    edit.normalized.typeName.flatMap {
                        try? NativeAuthoredTypeParserV1.parse($0, role: .parameter, catalog: catalog)
                    }
                }
            } ?? []
            definitions = try projectReferencedDefinitions(
                orderedDefinitions, signatures: signatures,
                overrides: admittedOverrides, catalog: catalog, localTypes: localTypes
            )
            var layoutResolver = NativeDecompilerAuthoredLayoutResolver(definitions: definitions)
            try layoutResolver.validateCompleteCatalog()
            appliedTypes = try projectAppliedTypes(
                overrides: admittedOverrides,
                binary: binary,
                analysis: analysis,
                definitions: orderedDefinitions,
                layoutResolver: &layoutResolver
            )
        }

        let authoredInputs = NativeDecompilerWireAuthoredInputs(
            schemaVersion: 1,
            names: names.sorted(by: Self.namePrecedes),
            signatures: signatures.sorted {
                $0.functionAddress.value < $1.functionAddress.value
            },
            appliedTypes: appliedTypes.sorted(by: Self.appliedTypePrecedes),
            typeDefinitions: definitions.sorted(by: Self.definitionPrecedes)
        )

        return authoredInputs
    }

    private func projectNames(
        overrides: [UInt64: AddressOverride],
        analysis: ImageAnalysis
    ) throws -> [NativeDecompilerWireAuthoredName] {
        let functionStarts = Dictionary(grouping: analysis.functions, by: \.startAddress)
        let liveInstructionStarts = Set(analysis.instructions.compactMap { instruction in
            instructionRemainsCode(
                instruction,
                overrides: overrides,
                codeDataRanges: analysis.codeDataRanges
            )
                ? instruction.address
                : nil
        })

        var projected: [NativeDecompilerWireAuthoredName] = []
        projected.reserveCapacity(overrides.count)
        for (address, override) in overrides.sorted(by: { $0.key < $1.key }) {
            guard let name = override.customName, !name.isEmpty else { continue }
            try validateSemanticText(name, subject: "authored-name")
            let subjectKind: NativeDecompilerWireAuthoredNameSubjectKind
            if functionStarts[address]?.count == 1 {
                subjectKind = .function
            } else if liveInstructionStarts.contains(address) {
                subjectKind = .label
            } else {
                subjectKind = .data
            }
            projected.append(
                .init(address: .init(address), subjectKind: subjectKind, name: name)
            )
        }
        guard projected.count <= Self.maximumNames else {
            throw bounds(code: "authored-names-count", subject: "names")
        }
        return projected
    }

    /// Where an authored signature's facts came from. The wire carries the same tags either
    /// way; the provenance keeps analysis-recovered no-return (HOP-1) distinct from a user
    /// override, and a user's explicit `noReturnState` always wins over the analysis.
    enum SignatureProvenance: Equatable {
        case userOverride
        /// A user signature whose unspecified no-return state was filled in by the analysis.
        case userOverrideWithAnalysisNoReturn(AnalysisNoReturnProvenance)
        case analysisNoReturn(AnalysisNoReturnProvenance)
    }

    struct ActiveSignature {
        let address: UInt64
        let signature: FunctionSignatureOverride
        let provenance: SignatureProvenance
    }

    func activeSignatures(
        in overrides: [UInt64: AddressOverride],
        functions: [FunctionSummary]
    ) -> [ActiveSignature] {
        let starts = Dictionary(grouping: functions, by: \.startAddress)
        var active: [UInt64: ActiveSignature] = [:]
        for (address, override) in overrides {
            guard starts[address]?.count == 1,
                  let signature = override.signature,
                  signature.hasAnalysisEffect
            else { continue }
            active[address] = ActiveSignature(address: address, signature: signature, provenance: .userOverride)
        }
        for (address, group) in starts {
            guard group.count == 1, let recovered = group[0].noReturnProvenance else { continue }
            if let user = active[address] {
                guard user.signature.noReturnState == .unspecified else { continue }
                var signature = user.signature
                signature.noReturnState = .noReturn
                active[address] = ActiveSignature(
                    address: address, signature: signature,
                    provenance: .userOverrideWithAnalysisNoReturn(recovered)
                )
            } else if overrides[address]?.signature?.noReturnState != .returns {
                active[address] = ActiveSignature(
                    address: address,
                    signature: FunctionSignatureOverride(noReturnState: .noReturn),
                    provenance: .analysisNoReturn(recovered)
                )
            }
        }
        return active.values.sorted { $0.address < $1.address }
    }

    private func projectSignatures(
        _ active: [ActiveSignature],
        catalog: NativeAuthoredCatalogIndex
    ) throws -> [NativeDecompilerWireAuthoredSignature] {
        guard active.count <= Self.maximumSignatures else {
            throw bounds(code: "authored-signatures-count", subject: "signatures")
        }

        return try active.map { source in
            let returnType: NativeDecompilerWireAuthoredType?
            if let authoredReturn = source.signature.returnType, !authoredReturn.isEmpty {
                returnType = try NativeAuthoredTypeParserV1.parse(
                    authoredReturn,
                    role: .returnType,
                    catalog: catalog
                )
            } else {
                returnType = nil
            }

            let parameterListState: NativeDecompilerWireAuthoredParameterListState
            let authoredParameters: [ArgOverride]
            switch source.signature.parameterList {
            case .unspecified:
                parameterListState = .unspecified
                authoredParameters = []
            case let .authoritative(parameters):
                parameterListState = .authoritative
                authoredParameters = parameters
            }
            guard authoredParameters.count <= Self.maximumParametersPerSignature else {
                throw bounds(code: "authored-parameters-count", subject: "signature")
            }
            let parameters = try authoredParameters.map { parameter in
                try validateSemanticText(parameter.name, subject: "signature")
                return NativeDecompilerWireAuthoredParameter(
                    name: parameter.name,
                    type: try NativeAuthoredTypeParserV1.parse(
                        parameter.type,
                        role: .parameter,
                        catalog: catalog
                    )
                )
            }

            let variadicState: NativeDecompilerWireAuthoredVariadicState = switch source.signature.variadicState {
            case .unspecified: .unspecified
            case .fixed: .fixed
            case .variadic: .variadic
            }
            let noReturnState: NativeDecompilerWireAuthoredNoReturnState = switch source.signature.noReturnState {
            case .unspecified: .unspecified
            case .returns: .returns
            case .noReturn: .noReturn
            }
            return .init(
                functionAddress: .init(source.address),
                returnType: returnType,
                parameterListState: parameterListState,
                parameters: parameters,
                variadicState: variadicState,
                noReturnState: noReturnState
            )
        }
    }

    private func projectDefinitions(
        _ definitions: [TypeDefinition],
        catalog: NativeAuthoredCatalogIndex
    ) throws -> [NativeDecompilerWireAuthoredTypeDefinition] {
        try definitions.map { definition in
            guard definition.vectorByteSize == nil, definition.enumValuesIncomplete != true else {
                throw unsupported(code: "authoring-input-unsupported", subject: "type-catalog")
            }
            switch definition.kind {
            case .struct, .union:
                let fields = try definition.fields.enumerated().map { index, field in
                    try projectRecordField(
                        field,
                        ownerKind: definition.kind,
                        index: index,
                        count: definition.fields.count,
                        catalog: catalog
                    )
                }
                return .record(
                    kind: definition.kind == .struct ? .struct : .union,
                    name: definition.name,
                    layoutRules: try wireLayoutRules(definition.layoutRules),
                    fields: fields
                )

            case .enum:
                guard definition.layoutRules == .default else {
                    throw unsupported(code: "authoring-input-unsupported", subject: "type-catalog")
                }
                let cases = try definition.fields.map { field in
                    guard fieldHasPlainCatalogShape(field),
                          !field.name.isEmpty,
                          let wideValue = Int64(field.type.trimmingCharacters(in: .whitespacesAndNewlines)),
                          let value = Int32(exactly: wideValue)
                    else {
                        throw unsupported(code: "authoring-input-unsupported", subject: "type-catalog")
                    }
                    try validateSemanticText(field.name, subject: "type-catalog")
                    return NativeDecompilerWireAuthoredEnumCase(name: field.name, value: value)
                }
                return .enumeration(
                    name: definition.name,
                    representation: .signed32,
                    cases: cases
                )

            case .typedef:
                guard definition.layoutRules == .default,
                      definition.fields.count == 1,
                      let field = definition.fields.first,
                      fieldHasNoTypedefMemberMetadata(field)
                else {
                    throw unsupported(code: "authoring-input-unsupported", subject: "type-catalog")
                }
                let target = try NativeAuthoredFieldStorageParserV1.parse(
                    field: field,
                    position: .init(ownerKind: .typedef, index: 0, count: 1),
                    catalog: catalog
                )
                return .typedef(name: definition.name, target: target)
            }
        }
    }

    /// Storage limits and catalog name checks apply to the entire captured revision above.
    /// Semantic admission applies to definitions reached by the candidate authored inputs
    /// captured for this image. Resolve each edge from the parsed wire shape, never display text.
    private func projectReferencedDefinitions(
        _ definitions: [TypeDefinition],
        signatures: [NativeDecompilerWireAuthoredSignature],
        overrides: [UInt64: AddressOverride],
        catalog: NativeAuthoredCatalogIndex,
        localTypes: [NativeDecompilerWireAuthoredType] = []
    ) throws -> [NativeDecompilerWireAuthoredTypeDefinition] {
        let byName = Dictionary(uniqueKeysWithValues: definitions.map {
            (NativeDecompilerExactUTF8Key($0.name), $0)
        })
        var pending: Set<NativeDecompilerExactUTF8Key> = []
        for signature in signatures {
            if let type = signature.returnType { collectReferences(in: type, into: &pending) }
            for parameter in signature.parameters {
                collectReferences(in: parameter.type, into: &pending)
            }
        }
        for type in localTypes { collectReferences(in: type, into: &pending) }
        for (_, override) in overrides {
            guard let name = override.appliedTypeName else { continue }
            let key = NativeDecompilerExactUTF8Key(name)
            if byName[key] != nil { pending.insert(key) }
        }

        var projected: [NativeDecompilerExactUTF8Key: NativeDecompilerWireAuthoredTypeDefinition] = [:]
        while let key = pending.min(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
            pending.remove(key)
            guard projected[key] == nil else { continue }
            guard let source = byName[key] else {
                throw invalid(code: "authored-type-grammar", subject: "authored-type")
            }
            let definition = try projectDefinitions([source], catalog: catalog)[0]
            projected[key] = definition
            var children: Set<NativeDecompilerExactUTF8Key> = []
            collectReferences(in: definition, into: &children)
            pending.formUnion(children.filter { projected[$0] == nil })
        }
        return projected.values.sorted(by: Self.definitionPrecedes)
    }

    private func collectReferences(
        in definition: NativeDecompilerWireAuthoredTypeDefinition,
        into names: inout Set<NativeDecompilerExactUTF8Key>
    ) {
        switch definition {
        case let .record(_, _, _, fields):
            for field in fields { collectReferences(in: field, into: &names) }
        case .enumeration:
            break
        case let .typedef(_, target):
            collectReferences(in: target, into: &names)
        }
    }

    private func collectReferences(
        in field: NativeDecompilerWireAuthoredRecordField,
        into names: inout Set<NativeDecompilerExactUTF8Key>
    ) {
        collectReferences(in: field.storage, into: &names)
        if let type = field.minimumAlignmentType { collectReferences(in: type, into: &names) }
    }

    private func collectReferences(
        in storage: NativeDecompilerWireAuthoredFieldStorage,
        into names: inout Set<NativeDecompilerExactUTF8Key>
    ) {
        switch storage {
        case let .value(type):
            collectReferences(in: type, into: &names)
        case let .fixedArray(element, _), let .flexibleArray(element):
            collectReferences(in: element, into: &names)
        case .opaquePointerCarrier:
            break
        case let .inlineAggregate(_, _, fields):
            for field in fields { collectReferences(in: field, into: &names) }
        }
    }

    private func collectReferences(
        in type: NativeDecompilerWireAuthoredType,
        into names: inout Set<NativeDecompilerExactUTF8Key>
    ) {
        switch type {
        case let .qualifiedValue(atom, _):
            if case let .named(_, name) = atom { names.insert(NativeDecompilerExactUTF8Key(name)) }
        case let .dataPointer(pointee, _, _):
            collectReferences(in: pointee, into: &names)
        }
    }

    private func projectRecordField(
        _ field: FieldDef,
        ownerKind: TypeKind,
        index: Int,
        count: Int,
        catalog: NativeAuthoredCatalogIndex
    ) throws -> NativeDecompilerWireAuthoredRecordField {
        if field.bitWidth == 0, !field.name.isEmpty {
            throw invalid(code: "authoring-input-invalid", subject: "type-layout")
        }
        if !field.name.isEmpty {
            try validateSemanticText(field.name, subject: "type-catalog")
        }
        let storage = try NativeAuthoredFieldStorageParserV1.parse(
            field: field,
            position: .init(ownerKind: ownerKind, index: index, count: count),
            catalog: catalog
        )
        let minimumAlignmentType = try field.minimumAlignmentType.map {
            try NativeAuthoredTypeParserV1.parse(
                $0,
                role: .minimumAlignmentType,
                catalog: catalog
            )
        }
        return .init(
            name: field.name,
            storage: storage,
            bitWidth: try field.bitWidth.map { value in
                guard value >= 0, let converted = UInt64(exactly: value) else {
                    throw invalid(code: "authoring-input-invalid", subject: "type-layout")
                }
                return .init(converted)
            },
            minimumAlignment: try field.minimumAlignment.map { value in
                guard value > 0, let converted = UInt64(exactly: value) else {
                    throw invalid(code: "authoring-input-invalid", subject: "type-layout")
                }
                return .init(converted)
            },
            minimumAlignmentType: minimumAlignmentType,
            promotesInlineFields: field.promotesInlineFields
        )
    }

    private func projectAppliedTypes(
        overrides: [UInt64: AddressOverride],
        binary: BinaryImage,
        analysis: ImageAnalysis,
        definitions: [TypeDefinition],
        layoutResolver: inout NativeDecompilerAuthoredLayoutResolver
    ) throws -> [NativeDecompilerWireAppliedType] {
        let definitionsByName = Dictionary(
            uniqueKeysWithValues: definitions.map { (NativeDecompilerExactUTF8Key($0.name), $0) }
        )
        let candidates = overrides.sorted(by: { $0.key < $1.key }).compactMap {
            address,
            override -> (UInt64, TypeDefinition)? in
            guard let name = override.appliedTypeName,
                  let definition = definitionsByName[NativeDecompilerExactUTF8Key(name)]
            else { return nil }
            return (address, definition)
        }
        guard candidates.count <= Self.maximumAppliedTypes else {
            throw bounds(code: "authored-applied-types-count", subject: "applied-types")
        }

        guard candidates.isEmpty
                || (binary.artifactIntegrityState == .verified && binary.preferredSegmentLayout != nil)
        else {
            throw invalid(code: "authoring-input-invalid", subject: "applied-type")
        }

        var projected: [NativeDecompilerWireAppliedType] = []
        projected.reserveCapacity(candidates.count)
        for (address, definition) in candidates {
            let metrics = try layoutResolver.metrics(forDefinitionNamed: definition.name)
            guard metrics.size > 0 else {
                throw invalid(code: "authoring-input-invalid", subject: "applied-type")
            }
            let (end, overflow) = address.addingReportingOverflow(metrics.size)
            guard !overflow, end > address,
                  let records = binary.preferredSegmentLayout?.records
            else {
                throw invalid(code: "authoring-input-invalid", subject: "applied-type")
            }
            let readableOwners = records.filter { record in
                guard record.initialProtections & 0x1 != 0 else { return false }
                let (recordEnd, recordOverflow) = record.preferredVMStart
                    .addingReportingOverflow(record.preferredVMSize)
                return !recordOverflow
                    && address >= record.preferredVMStart
                    && end <= recordEnd
            }
            guard readableOwners.count == 1,
                  !overlapsCode(
                      start: address,
                      end: end,
                      functions: analysis.functions,
                      instructions: analysis.instructions,
                      codeDataRanges: analysis.codeDataRanges,
                      overrides: overrides
                  )
            else {
                throw invalid(code: "authoring-input-invalid", subject: "applied-type")
            }
            projected.append(
                .init(
                    address: .init(address),
                    subjectKind: .memoryObject,
                    typeDefinitionName: definition.name,
                    byteCount: .init(metrics.size)
                )
            )
        }
        return projected
    }

    private func overlapsCode(
        start: UInt64,
        end: UInt64,
        functions: [FunctionSummary],
        instructions: [InstructionRow],
        codeDataRanges: [CodeDataRangeSummary],
        overrides: [UInt64: AddressOverride]
    ) -> Bool {
        for function in functions {
            guard function.endAddress > function.startAddress else { return true }
            if start < function.endAddress, function.startAddress < end { return true }
        }
        for instruction in instructions
        where instructionRemainsCode(
            instruction,
            overrides: overrides,
            codeDataRanges: codeDataRanges
        ) {
            let (instructionEnd, overflow) = instruction.address
                .addingReportingOverflow(instruction.byteWidth)
            if overflow { return true }
            if start < instructionEnd, instruction.address < end { return true }
        }
        return false
    }

    private func instructionRemainsCode(
        _ instruction: InstructionRow,
        overrides: [UInt64: AddressOverride],
        codeDataRanges: [CodeDataRangeSummary]
    ) -> Bool {
        if let override = overrides[instruction.address] {
            guard !override.isData,
                  !override.isUndefined,
                  override.dataShape?.isEmpty ?? true
            else { return false }
        }
        let (_, overflow) = instruction.address
            .addingReportingOverflow(instruction.byteWidth)
        guard !overflow else { return true }
        return !codeDataRanges.contains { $0.contains(instruction.address) }
    }

    private func validateAggregateMemberCount(
        definitions: [TypeDefinition],
        signatures: [FunctionSignatureOverride]
    ) throws {
        var count = 0
        for signature in signatures {
            let additional: Int = switch signature.parameterList {
            case .unspecified: 0
            case let .authoritative(parameters): parameters.count
            }
            let (next, overflow) = count.addingReportingOverflow(additional)
            guard !overflow, next <= Self.maximumAggregateMembers else {
                throw bounds(code: "authored-aggregate-members-count", subject: "type-catalog")
            }
            count = next
        }
        for definition in definitions {
            let additional: Int
            switch definition.kind {
            case .struct, .union:
                additional = try aggregateFieldCountIteratively(definition.fields)
            case .enum:
                additional = definition.fields.count
            case .typedef:
                additional = 0
            }
            let (next, overflow) = count.addingReportingOverflow(additional)
            guard !overflow, next <= Self.maximumAggregateMembers else {
                throw bounds(code: "authored-aggregate-members-count", subject: "type-catalog")
            }
            count = next
        }
    }

    private func aggregateFieldCountIteratively(_ rootFields: [FieldDef]) throws -> Int {
        var count = 0
        var pending: [FieldDef] = []
        pending.reserveCapacity(min(rootFields.count, Self.maximumAggregateMembers))
        for field in rootFields.reversed() {
            pending.append(field)
        }

        while let field = pending.popLast() {
            let (next, overflow) = count.addingReportingOverflow(1)
            guard !overflow, next <= Self.maximumAggregateMembers else {
                throw bounds(code: "authored-aggregate-members-count", subject: "type-catalog")
            }
            count = next
            for nested in field.inlineFields.reversed() {
                pending.append(nested)
            }
        }
        return count
    }

    private func wireLayoutRules(
        _ rules: AggregateLayoutRules
    ) throws -> NativeDecompilerWireAuthoredLayoutRules {
        func positive(_ value: Int?) throws -> NativeDecompilerWireUInt64? {
            guard let value else { return nil }
            guard value > 0, let converted = UInt64(exactly: value) else {
                throw invalid(code: "authoring-input-invalid", subject: "type-layout")
            }
            return .init(converted)
        }
        return try .init(
            isPacked: rules.isPacked,
            packAlignment: positive(rules.packAlignment),
            minimumAlignment: positive(rules.minimumAlignment)
        )
    }

    private func fieldHasPlainCatalogShape(_ field: FieldDef) -> Bool {
        (field.declaratorSemanticsV1 == nil || field.declaratorSemanticsV1 == .ordinary)
            && fieldHasNoRecordMetadata(field)
    }

    private func fieldHasNoRecordMetadata(_ field: FieldDef) -> Bool {
        field.bitWidth == nil
            && field.bitOffset == nil && field.isPacked != true
            && field.layoutIsUnknown != true && field.isAtomic != true
            && field.minimumAlignment == nil
            && field.minimumAlignmentType == nil
            && field.inlineAggregateKind == nil
            && field.inlineFields.isEmpty
            && field.inlineAggregateLayoutRules == .default
            && !field.promotesInlineFields
    }

    private func fieldHasNoTypedefMemberMetadata(_ field: FieldDef) -> Bool {
        field.bitWidth == nil
            && field.bitOffset == nil && field.isPacked != true
            && field.layoutIsUnknown != true && field.isAtomic != true
            && field.minimumAlignment == nil
            && field.minimumAlignmentType == nil
            && !field.promotesInlineFields
    }

    private func validateSemanticText(_ text: String, subject: String) throws {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f }) else {
            throw invalid(code: "authoring-input-invalid", subject: subject)
        }
        guard bytes.count <= Self.maximumSemanticNameBytes else {
            throw bounds(code: "authored-semantic-name-bytes", subject: subject)
        }
    }

    private func validateCatalogText(_ text: String, subject: String) throws {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f }) else {
            throw invalid(code: "authoring-input-invalid", subject: subject)
        }
        guard bytes.count <= Self.maximumCatalogTextBytes else {
            throw bounds(code: "authored-catalog-text-bytes", subject: subject)
        }
    }

    private func mapCanonicalValidation(
        _ validation: NativeDecompilerWireAuthoredValidationError
    ) -> NativeAuthoredProjectionDiagnostic {
        switch validation {
        case .tooManyNames:
            bounds(code: "authored-names-count", subject: "names")
        case .tooManySignatures:
            bounds(code: "authored-signatures-count", subject: "signatures")
        case .tooManyParameters:
            bounds(code: "authored-parameters-count", subject: "signature")
        case .tooManyAppliedTypes:
            bounds(code: "authored-applied-types-count", subject: "applied-types")
        case .tooManyTypeDefinitions:
            bounds(code: "authored-type-definitions-count", subject: "type-catalog")
        case .tooManyAggregateMembers:
            bounds(code: "authored-aggregate-members-count", subject: "type-catalog")
        case .semanticNameTooLong:
            bounds(code: "authored-semantic-name-bytes", subject: "root")
        case .catalogTextTooLong:
            bounds(code: "authored-catalog-text-bytes", subject: "type-catalog")
        case .canonicalAuthoredInputTooLarge:
            bounds(code: "authored-canonical-bytes", subject: "root")
        case .fixedArrayElementCountOutOfRange, .authoredDepthExceeded:
            bounds(code: "authored-field-storage-bounds", subject: "record-field")
        case .computedStorageTooLarge:
            bounds(code: "authoring-input-too-large", subject: "type-layout")
        default:
            invalid(code: "authoring-input-invalid", subject: "root")
        }
    }

    private static func namePrecedes(
        _ lhs: NativeDecompilerWireAuthoredName,
        _ rhs: NativeDecompilerWireAuthoredName
    ) -> Bool {
        if lhs.address.value != rhs.address.value { return lhs.address.value < rhs.address.value }
        if lhs.subjectKind.rawValue != rhs.subjectKind.rawValue {
            return lhs.subjectKind.rawValue < rhs.subjectKind.rawValue
        }
        return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
    }

    private static func appliedTypePrecedes(
        _ lhs: NativeDecompilerWireAppliedType,
        _ rhs: NativeDecompilerWireAppliedType
    ) -> Bool {
        if lhs.address.value != rhs.address.value { return lhs.address.value < rhs.address.value }
        if lhs.subjectKind.rawValue != rhs.subjectKind.rawValue {
            return lhs.subjectKind.rawValue < rhs.subjectKind.rawValue
        }
        return lhs.typeDefinitionName.utf8.lexicographicallyPrecedes(rhs.typeDefinitionName.utf8)
    }

    private static func definitionPrecedes(
        _ lhs: NativeDecompilerWireAuthoredTypeDefinition,
        _ rhs: NativeDecompilerWireAuthoredTypeDefinition
    ) -> Bool {
        let lhsName = Array(lhs.name.utf8)
        let rhsName = Array(rhs.name.utf8)
        if lhsName != rhsName { return lhsName.lexicographicallyPrecedes(rhsName) }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    private static func sourceDefinitionPrecedes(
        _ lhs: TypeDefinition,
        _ rhs: TypeDefinition
    ) -> Bool {
        let lhsName = Array(lhs.name.utf8)
        let rhsName = Array(rhs.name.utf8)
        if lhsName != rhsName { return lhsName.lexicographicallyPrecedes(rhsName) }
        return lhs.kind.rawValue.utf8.lexicographicallyPrecedes(rhs.kind.rawValue.utf8)
    }

    private func unsupported(code: String, subject: String) -> NativeAuthoredProjectionDiagnostic {
        .unsupported(id: .init(code: code, imageSlot: nil, subject: subject))
    }

    private func invalid(code: String, subject: String) -> NativeAuthoredProjectionDiagnostic {
        .invalid(id: .init(code: code, imageSlot: nil, subject: subject))
    }

    private func bounds(code: String, subject: String) -> NativeAuthoredProjectionDiagnostic {
        .bounds(id: .init(code: code, imageSlot: nil, subject: subject))
    }
}

private struct NativeDecompilerExactUTF8Key: Hashable {
    let bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8)
    }
}

private extension NativeAuthoredProjectionDiagnostic {
    func qualified(to imageSlot: ImageSlot) -> Self {
        func qualifiedIdentity(_ identity: Identity) -> Identity {
            .init(code: identity.code, imageSlot: imageSlot, subject: identity.subject)
        }
        switch self {
        case let .unsupported(id):
            return NativeAuthoredProjectionDiagnostic.unsupported(
                id: qualifiedIdentity(id)
            )
        case let .invalid(id):
            return NativeAuthoredProjectionDiagnostic.invalid(
                id: qualifiedIdentity(id)
            )
        case let .bounds(id):
            return NativeAuthoredProjectionDiagnostic.bounds(
                id: qualifiedIdentity(id)
            )
        }
    }
}

private struct NativeDecompilerAuthoredLayoutMetrics {
    let size: UInt64
    let alignment: UInt64
    let hasFlexibleTail: Bool
}

private struct NativeDecompilerAuthoredLayoutResolver {
    private static let maximumStorageBytes: UInt64 = 1_048_576

    private let definitionsByName: [NativeDecompilerExactUTF8Key: NativeDecompilerWireAuthoredTypeDefinition]
    private var cachedMetrics: [NativeDecompilerExactUTF8Key: NativeDecompilerAuthoredLayoutMetrics] = [:]

    init(definitions: [NativeDecompilerWireAuthoredTypeDefinition]) {
        definitionsByName = Dictionary(
            uniqueKeysWithValues: definitions.map {
                (NativeDecompilerExactUTF8Key($0.name), $0)
            }
        )
    }

    mutating func validateCompleteCatalog() throws {
        let names = definitionsByName.keys.sorted { lhs, rhs in
            lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
        }
        for name in names {
            var active: Set<NativeDecompilerExactUTF8Key> = []
            _ = try metrics(forDefinition: name, active: &active)
        }
    }

    mutating func metrics(
        forDefinitionNamed name: String
    ) throws -> NativeDecompilerAuthoredLayoutMetrics {
        var active: Set<NativeDecompilerExactUTF8Key> = []
        return try metrics(
            forDefinition: NativeDecompilerExactUTF8Key(name),
            active: &active
        )
    }

    private mutating func metrics(
        forDefinition key: NativeDecompilerExactUTF8Key,
        active: inout Set<NativeDecompilerExactUTF8Key>
    ) throws -> NativeDecompilerAuthoredLayoutMetrics {
        if let cached = cachedMetrics[key] { return cached }
        guard let definition = definitionsByName[key] else {
            throw invalidLayout()
        }
        guard active.insert(key).inserted else {
            throw unsupportedLayout()
        }
        defer { active.remove(key) }

        let result: NativeDecompilerAuthoredLayoutMetrics
        switch definition {
        case let .record(kind, _, rules, fields):
            result = try aggregateMetrics(
                kind: kind,
                rules: rules,
                fields: fields,
                active: &active
            )
        case .enumeration:
            result = .init(size: 4, alignment: 4, hasFlexibleTail: false)
        case let .typedef(_, target):
            result = try storageMetrics(target, active: &active)
        }
        cachedMetrics[key] = result
        return result
    }

    private mutating func aggregateMetrics(
        kind: NativeDecompilerWireAuthoredNamedKind,
        rules: NativeDecompilerWireAuthoredLayoutRules,
        fields: [NativeDecompilerWireAuthoredRecordField],
        active: inout Set<NativeDecompilerExactUTF8Key>
    ) throws -> NativeDecompilerAuthoredLayoutMetrics {
        guard kind == .struct || kind == .union else { throw invalidLayout() }
        try validateAlignment(rules.packAlignment?.value)
        try validateAlignment(rules.minimumAlignment?.value)
        switch kind {
        case .struct:
            return try structMetrics(rules: rules, fields: fields, active: &active)
        case .union:
            return try unionMetrics(rules: rules, fields: fields, active: &active)
        case .enum, .typedef:
            throw invalidLayout()
        }
    }

    private mutating func structMetrics(
        rules: NativeDecompilerWireAuthoredLayoutRules,
        fields: [NativeDecompilerWireAuthoredRecordField],
        active: inout Set<NativeDecompilerExactUTF8Key>
    ) throws -> NativeDecompilerAuthoredLayoutMetrics {
        var bitCursor: UInt64 = 0
        var maximumMemberAlignment: UInt64 = 1
        var carriesFlexibleTail = false
        var previousWasPositiveBitField = false

        for (index, field) in fields.enumerated() {
            if let bitWidth = field.bitWidth?.value {
                guard case let .value(type) = field.storage,
                      let capacity = try bitFieldCapacity(type, active: &active),
                      bitWidth <= capacity,
                      bitWidth != 0 || field.name.isEmpty
                else {
                    throw invalidLayout()
                }
                let natural = try typeMetrics(type, active: &active)
                guard !natural.hasFlexibleTail else { throw unsupportedLayout() }
                let alignment = try effectiveMemberAlignment(
                    natural: natural.alignment,
                    field: field,
                    rules: rules,
                    active: &active
                )

                if bitWidth == 0 {
                    let barrierAlignment = try uncappedMemberAlignment(
                        natural: natural.alignment,
                        field: field,
                        active: &active
                    )
                    let resetByte = try aligned(
                        try bytesCovering(bits: bitCursor),
                        to: barrierAlignment
                    )
                    bitCursor = try multiplied(resetByte, 8)
                    previousWasPositiveBitField = false
                    continue
                }

                if !field.name.isEmpty {
                    maximumMemberAlignment = max(maximumMemberAlignment, alignment)
                }
                let usesBitPrecisionPacking = rules.isPacked
                    || rules.packAlignment != nil
                if usesBitPrecisionPacking {
                    if !previousWasPositiveBitField {
                        let startByte = try aligned(
                            try bytesCovering(bits: bitCursor),
                            to: alignment
                        )
                        bitCursor = try multiplied(startByte, 8)
                    }
                    bitCursor = try added(bitCursor, bitWidth)
                    previousWasPositiveBitField = true
                    continue
                }
                let containerBits = try multiplied(natural.size, 8)
                var containerByte = alignedDown(bitCursor / 8, to: alignment)
                var containerStartBit = try multiplied(containerByte, 8)
                var containerEndBit = try added(containerStartBit, containerBits)
                let proposedEnd = try added(bitCursor, bitWidth)
                if proposedEnd > containerEndBit {
                    containerByte = try aligned(
                        try bytesCovering(bits: bitCursor),
                        to: alignment
                    )
                    containerStartBit = try multiplied(containerByte, 8)
                    containerEndBit = try added(containerStartBit, containerBits)
                    bitCursor = containerStartBit
                }
                guard try added(bitCursor, bitWidth) <= containerEndBit else {
                    throw invalidLayout()
                }
                bitCursor = try added(bitCursor, bitWidth)
                previousWasPositiveBitField = true
                continue
            }

            previousWasPositiveBitField = false
            let fieldMetrics = try storageMetrics(field.storage, active: &active)
            if fieldMetrics.hasFlexibleTail {
                guard index == fields.index(before: fields.endIndex) else {
                    throw unsupportedLayout()
                }
                carriesFlexibleTail = true
            }
            let alignment = try effectiveMemberAlignment(
                natural: fieldMetrics.alignment,
                field: field,
                rules: rules,
                active: &active
            )
            maximumMemberAlignment = max(maximumMemberAlignment, alignment)
            let byteOffset = try aligned(
                try bytesCovering(bits: bitCursor),
                to: alignment
            )
            let byteEnd = try added(byteOffset, fieldMetrics.size)
            try requireWithinStorageLimit(byteEnd)
            bitCursor = try multiplied(byteEnd, 8)
        }

        let aggregateAlignment = try effectiveAggregateAlignment(
            maximumMemberAlignment,
            rules: rules
        )
        let size = try aligned(
            try bytesCovering(bits: bitCursor),
            to: aggregateAlignment
        )
        try requireWithinStorageLimit(size)
        return .init(
            size: size,
            alignment: aggregateAlignment,
            hasFlexibleTail: carriesFlexibleTail
        )
    }

    private mutating func unionMetrics(
        rules: NativeDecompilerWireAuthoredLayoutRules,
        fields: [NativeDecompilerWireAuthoredRecordField],
        active: inout Set<NativeDecompilerExactUTF8Key>
    ) throws -> NativeDecompilerAuthoredLayoutMetrics {
        var maximumMemberSize: UInt64 = 0
        var maximumMemberAlignment: UInt64 = 1

        for field in fields {
            if let bitWidth = field.bitWidth?.value {
                guard case let .value(type) = field.storage,
                      let capacity = try bitFieldCapacity(type, active: &active),
                      bitWidth <= capacity,
                      bitWidth != 0 || field.name.isEmpty
                else {
                    throw invalidLayout()
                }
                let natural = try typeMetrics(type, active: &active)
                guard !natural.hasFlexibleTail else { throw unsupportedLayout() }
                let alignment = try effectiveMemberAlignment(
                    natural: natural.alignment,
                    field: field,
                    rules: rules,
                    active: &active
                )
                if bitWidth > 0 {
                    maximumMemberSize = max(
                        maximumMemberSize,
                        try bytesCovering(bits: bitWidth)
                    )
                }
                if !field.name.isEmpty {
                    maximumMemberAlignment = max(maximumMemberAlignment, alignment)
                }
                continue
            }

            let fieldMetrics = try storageMetrics(field.storage, active: &active)
            guard !fieldMetrics.hasFlexibleTail else { throw unsupportedLayout() }
            let alignment = try effectiveMemberAlignment(
                natural: fieldMetrics.alignment,
                field: field,
                rules: rules,
                active: &active
            )
            maximumMemberSize = max(maximumMemberSize, fieldMetrics.size)
            maximumMemberAlignment = max(maximumMemberAlignment, alignment)
        }

        let aggregateAlignment = try effectiveAggregateAlignment(
            maximumMemberAlignment,
            rules: rules
        )
        let size = try aligned(maximumMemberSize, to: aggregateAlignment)
        try requireWithinStorageLimit(size)
        return .init(size: size, alignment: aggregateAlignment, hasFlexibleTail: false)
    }

    private mutating func storageMetrics(
        _ storage: NativeDecompilerWireAuthoredFieldStorage,
        active: inout Set<NativeDecompilerExactUTF8Key>
    ) throws -> NativeDecompilerAuthoredLayoutMetrics {
        switch storage {
        case let .value(type):
            return try typeMetrics(type, active: &active)

        case let .fixedArray(element, count):
            guard count.value > 0 else { throw invalidLayout() }
            let elementMetrics = try storageMetrics(element, active: &active)
            guard !elementMetrics.hasFlexibleTail else { throw unsupportedLayout() }
            let size = try multiplied(elementMetrics.size, count.value)
            try requireWithinStorageLimit(size)
            return .init(
                size: size,
                alignment: elementMetrics.alignment,
                hasFlexibleTail: false
            )

        case let .flexibleArray(element):
            let elementMetrics = try storageMetrics(element, active: &active)
            guard !elementMetrics.hasFlexibleTail else { throw unsupportedLayout() }
            return .init(
                size: 0,
                alignment: elementMetrics.alignment,
                hasFlexibleTail: true
            )

        case .opaquePointerCarrier:
            return .init(size: 8, alignment: 8, hasFlexibleTail: false)

        case let .inlineAggregate(kind, rules, fields):
            return try aggregateMetrics(
                kind: kind,
                rules: rules,
                fields: fields,
                active: &active
            )
        }
    }

    private mutating func typeMetrics(
        _ type: NativeDecompilerWireAuthoredType,
        active: inout Set<NativeDecompilerExactUTF8Key>
    ) throws -> NativeDecompilerAuthoredLayoutMetrics {
        switch type {
        case let .qualifiedValue(atom, _):
            switch atom {
            case .void:
                throw invalidLayout()
            case let .scalar(kind):
                let size: UInt64 = switch kind {
                case .bool, .char, .signed8, .unsigned8: 1
                case .signed16, .unsigned16: 2
                case .signed32, .unsigned32, .float32: 4
                case .signed64, .unsigned64, .float64: 8
                }
                return .init(size: size, alignment: size, hasFlexibleTail: false)
            case let .darwinAlias(kind):
                let size: UInt64 = kind == .wcharT ? 4 : 8
                return .init(size: size, alignment: size, hasFlexibleTail: false)
            case let .named(kind, name):
                let key = NativeDecompilerExactUTF8Key(name)
                guard let definition = definitionsByName[key], definition.kind == wireDefinitionKind(kind) else {
                    throw invalidLayout()
                }
                return try metrics(forDefinition: key, active: &active)
            }

        case .dataPointer:
            return .init(size: 8, alignment: 8, hasFlexibleTail: false)
        }
    }

    private mutating func bitFieldCapacity(
        _ type: NativeDecompilerWireAuthoredType,
        active: inout Set<NativeDecompilerExactUTF8Key>
    ) throws -> UInt64? {
        switch type {
        case let .qualifiedValue(atom, _):
            switch atom {
            case .void:
                return nil
            case let .scalar(kind):
                switch kind {
                case .bool: return 1
                case .char, .signed8, .unsigned8: return 8
                case .signed16, .unsigned16: return 16
                case .signed32, .unsigned32: return 32
                case .signed64, .unsigned64: return 64
                case .float32, .float64: return nil
                }
            case let .darwinAlias(kind):
                return kind == .wcharT ? 32 : 64
            case let .named(kind, name):
                switch kind {
                case .enum:
                    return 32
                case .typedef:
                    let key = NativeDecompilerExactUTF8Key(name)
                    guard let definition = definitionsByName[key],
                          case let .typedef(_, target) = definition,
                          case let .value(targetType) = target
                    else { return nil }
                    guard active.insert(key).inserted else { throw unsupportedLayout() }
                    defer { active.remove(key) }
                    return try bitFieldCapacity(targetType, active: &active)
                case .struct, .union:
                    return nil
                }
            }
        case .dataPointer:
            return nil
        }
    }

    private mutating func effectiveMemberAlignment(
        natural: UInt64,
        field: NativeDecompilerWireAuthoredRecordField,
        rules: NativeDecompilerWireAuthoredLayoutRules,
        active: inout Set<NativeDecompilerExactUTF8Key>
    ) throws -> UInt64 {
        try validateAlignment(natural)
        var result: UInt64 = rules.isPacked ? 1 : natural
        if let numericMinimum = field.minimumAlignment?.value {
            try validateAlignment(numericMinimum)
            result = max(result, numericMinimum)
        }
        if let typeMinimum = field.minimumAlignmentType {
            let typeAlignment = try typeMetrics(typeMinimum, active: &active).alignment
            try validateAlignment(typeAlignment)
            result = max(result, typeAlignment)
        }
        if let pack = rules.packAlignment?.value {
            try validateAlignment(pack)
            result = min(result, pack)
        }
        try validateAlignment(result)
        return result
    }

    private mutating func uncappedMemberAlignment(
        natural: UInt64,
        field: NativeDecompilerWireAuthoredRecordField,
        active: inout Set<NativeDecompilerExactUTF8Key>
    ) throws -> UInt64 {
        try validateAlignment(natural)
        var result = natural
        if let numericMinimum = field.minimumAlignment?.value {
            try validateAlignment(numericMinimum)
            result = max(result, numericMinimum)
        }
        if let typeMinimum = field.minimumAlignmentType {
            let typeAlignment = try typeMetrics(typeMinimum, active: &active).alignment
            try validateAlignment(typeAlignment)
            result = max(result, typeAlignment)
        }
        try validateAlignment(result)
        return result
    }

    private func effectiveAggregateAlignment(
        _ maximumMemberAlignment: UInt64,
        rules: NativeDecompilerWireAuthoredLayoutRules
    ) throws -> UInt64 {
        var result = max(maximumMemberAlignment, 1)
        if let minimum = rules.minimumAlignment?.value {
            try validateAlignment(minimum)
            result = max(result, minimum)
        }
        try validateAlignment(result)
        return result
    }

    private func wireDefinitionKind(
        _ kind: NativeDecompilerWireAuthoredNamedKind
    ) -> NativeDecompilerWireAuthoredTypeDefinitionKind {
        switch kind {
        case .struct: .recordStruct
        case .union: .recordUnion
        case .enum: .enumeration
        case .typedef: .typedef
        }
    }

    private func validateAlignment(_ value: UInt64?) throws {
        guard let value else { return }
        guard value > 0, value <= Self.maximumStorageBytes else {
            throw boundsLayout()
        }
    }

    private func aligned(_ offset: UInt64, to alignment: UInt64) throws -> UInt64 {
        try validateAlignment(alignment)
        guard alignment > 1 else { return offset }
        let remainder = offset % alignment
        guard remainder != 0 else { return offset }
        return try added(offset, alignment - remainder)
    }

    private func alignedDown(_ offset: UInt64, to alignment: UInt64) -> UInt64 {
        guard alignment > 1 else { return offset }
        return offset - (offset % alignment)
    }

    private func bytesCovering(bits: UInt64) throws -> UInt64 {
        guard bits > 0 else { return 0 }
        return try added(bits, 7) / 8
    }

    private func added(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw boundsLayout() }
        return result
    }

    private func multiplied(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw boundsLayout() }
        return result
    }

    private func requireWithinStorageLimit(_ value: UInt64) throws {
        guard value <= Self.maximumStorageBytes else { throw boundsLayout() }
    }

    private func invalidLayout() -> NativeAuthoredProjectionDiagnostic {
        .invalid(
            id: .init(
                code: "authoring-input-invalid",
                imageSlot: nil,
                subject: "type-layout"
            )
        )
    }

    private func unsupportedLayout() -> NativeAuthoredProjectionDiagnostic {
        .unsupported(
            id: .init(
                code: "authoring-input-unsupported",
                imageSlot: nil,
                subject: "type-layout"
            )
        )
    }

    private func boundsLayout() -> NativeAuthoredProjectionDiagnostic {
        .bounds(
            id: .init(
                code: "authoring-input-too-large",
                imageSlot: nil,
                subject: "type-layout"
            )
        )
    }
}
