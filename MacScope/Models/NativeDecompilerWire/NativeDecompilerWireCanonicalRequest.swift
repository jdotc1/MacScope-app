import CryptoKit
import Foundation

enum NativeDecompilerWireCanonicalRequest {
    static let streamVersion: UInt64 = 2

    private static let authoredDomain = "org.macscope.MacScope.native-authored-input.v1"
    private static let contextProfileDomain =
        "org.macscope.MacScope.native-context-profile.v1"

    private static let maximumNames = 4_096
    private static let maximumSignatures = 4_096
    private static let maximumParametersPerSignature = 256
    private static let maximumAppliedTypes = 4_096
    private static let maximumTypeDefinitions = 1_024
    private static let maximumAggregateMembers = 16_384
    private static let maximumAuthoredDepth: UInt64 = 16
    private static let maximumFixedArrayElements: UInt64 = 1_048_576
    private static let maximumComputedStorageBytes: UInt64 = 1_048_576
    private static let maximumCanonicalAuthoredBytes = 1_048_576
    private static let maximumSemanticNameBytes = 1_024
    private static let maximumCatalogTextBytes = 4_096

    static func canonicalAuthoredInputBytes(
        _ authoredInputs: NativeDecompilerWireAuthoredInputs
    ) throws -> Data {
        try canonicalAuthoredSection(authoredInputs).bytes
    }

    static func preimage(
        schemaVersion: UInt32,
        operation: NativeDecompilerWireRequestOperation,
        target: NativeDecompilerWireTarget,
        image: NativeDecompilerWireImageIdentity,
        function: NativeDecompilerWireFunctionIdentity,
        memoryRegions: [NativeDecompilerWireMemoryRegion],
        symbols: [NativeDecompilerWireSymbolRecord],
        authoredInputs: NativeDecompilerWireAuthoredInputs,
        budgets: NativeDecompilerProfiledAnalysisBudgets
    ) throws -> Data {
        let authoredSection = try canonicalAuthoredSection(authoredInputs)
        let sortedRegions = memoryRegions.sorted {
            if $0.startAddress.value != $1.startAddress.value {
                return $0.startAddress.value < $1.startAddress.value
            }
            return textBytes($0.name).lexicographicallyPrecedes(textBytes($1.name))
        }
        let sortedSymbols = symbols.sorted(by: symbolPrecedes)

        var output = Data()
        appendGlobalDecimalField("canonicalStreamVersion", streamVersion, to: &output)
        appendGlobalDecimalField("schemaVersion", UInt64(schemaVersion), to: &output)
        appendGlobalTextField("operation", operation.rawValue, to: &output)

        appendGlobalTextField("target.rawCPUType", target.rawCPUType, to: &output)
        appendGlobalTextField("target.rawCPUSubtype", target.rawCPUSubtype, to: &output)
        appendGlobalTextField(
            "target.normalizedVariant",
            target.normalizedVariant.rawValue,
            to: &output
        )
        appendGlobalTextField(
            "target.recognizedCapabilityBits",
            target.recognizedCapabilityBits,
            to: &output
        )
        appendGlobalBooleanField(
            "target.pointerAuthABIVersion.present",
            target.pointerAuthABIVersion != nil,
            to: &output
        )
        if let pointerAuthABIVersion = target.pointerAuthABIVersion {
            appendGlobalDecimalField(
                "target.pointerAuthABIVersion.value",
                UInt64(pointerAuthABIVersion),
                to: &output
            )
        }
        appendGlobalTextField(
            "target.selectedSliceSHA256",
            target.selectedSliceSHA256,
            to: &output
        )
        appendGlobalDecimalField(
            "target.selectedSliceByteCount",
            target.selectedSliceByteCount.value,
            to: &output
        )
        appendGlobalTextField("target.profileID", target.profileID, to: &output)
        appendGlobalTextField("target.languageID", target.languageID, to: &output)
        appendGlobalTextField("target.compilerSpecID", target.compilerSpecID, to: &output)
        appendGlobalTextField(
            "target.contextProfileSHA256",
            target.contextProfileSHA256,
            to: &output
        )
        appendGlobalDecimalField("target.context.count", UInt64(target.context.count), to: &output)
        for (index, context) in target.context.enumerated() {
            let prefix = "target.context[\(index)]"
            appendGlobalTextField("\(prefix).name", context.name, to: &output)
            appendGlobalDecimalField("\(prefix).value", UInt64(context.value), to: &output)
        }

        appendGlobalTextField("image.imageID", image.imageID, to: &output)
        appendGlobalTextField("image.uuid", image.uuid.uuidString.lowercased(), to: &output)
        appendGlobalDecimalField(
            "image.preferredLoadAddress",
            image.preferredLoadAddress.value,
            to: &output
        )

        appendGlobalTextField("function.functionID", function.functionID, to: &output)
        appendGlobalTextField("function.name", function.name, to: &output)
        appendGlobalDecimalField(
            "function.entryAddress",
            function.entryAddress.value,
            to: &output
        )
        appendGlobalDecimalField(
            "function.endAddressExclusive",
            function.endAddressExclusive.value,
            to: &output
        )
        if schemaVersion >= NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion {
            let ranges = function.codeRanges ?? []
            appendGlobalDecimalField("function.codeRanges.count", UInt64(ranges.count), to: &output)
            for (index, range) in ranges.enumerated() {
                let prefix = "function.codeRanges[\(index)]"
                appendGlobalDecimalField("\(prefix).startAddress", range.startAddress.value, to: &output)
                appendGlobalDecimalField("\(prefix).endAddressExclusive", range.endAddressExclusive.value, to: &output)
            }
        }

        appendGlobalDecimalField("memoryRegions.count", UInt64(sortedRegions.count), to: &output)
        for (index, region) in sortedRegions.enumerated() {
            let prefix = "memoryRegions[\(index)]"
            appendGlobalTextField("\(prefix).name", region.name, to: &output)
            appendGlobalDecimalField(
                "\(prefix).startAddress",
                region.startAddress.value,
                to: &output
            )
            appendGlobalTextField("\(prefix).permissions", region.permissions.rawValue, to: &output)
            appendGlobalField("\(prefix).rawBytes", region.rawBytes, to: &output)
            appendGlobalField("\(prefix).effectiveBytes", region.effectiveBytes, to: &output)
            appendGlobalDecimalField(
                "\(prefix).appliedPatchIDs.count",
                UInt64(region.appliedPatchIDs.count),
                to: &output
            )
            for (patchIndex, patchID) in region.appliedPatchIDs.enumerated() {
                appendGlobalTextField(
                    "\(prefix).appliedPatchIDs[\(patchIndex)]",
                    patchID,
                    to: &output
                )
            }
        }

        appendGlobalDecimalField("symbols.count", UInt64(sortedSymbols.count), to: &output)
        for (index, symbol) in sortedSymbols.enumerated() {
            let prefix = "symbols[\(index)]"
            appendGlobalTextField("\(prefix).imageID", symbol.imageID, to: &output)
            appendGlobalDecimalField("\(prefix).address", symbol.address.value, to: &output)
            appendGlobalTextField("\(prefix).name", symbol.name, to: &output)
            appendGlobalTextField("\(prefix).kind", symbol.kind.rawValue, to: &output)
        }

        output.append(authoredSection.bytes.dropFirst(authoredSection.domainFrameByteCount))

        appendGlobalTextField("budgets.profileID", budgets.profileID, to: &output)
        appendGlobalDecimalField("budgets.maxCodeBytes", UInt64(budgets.maxCodeBytes), to: &output)
        appendGlobalDecimalField(
            "budgets.maxInstructions",
            UInt64(budgets.maxInstructions),
            to: &output
        )
        appendGlobalDecimalField(
            "budgets.maxOperations",
            UInt64(budgets.maxOperations),
            to: &output
        )
        appendGlobalDecimalField(
            "budgets.maxOutputBytes",
            UInt64(budgets.maxOutputBytes),
            to: &output
        )
        appendGlobalDecimalField(
            "budgets.maxWallTimeMilliseconds",
            budgets.maxWallTimeMilliseconds.value,
            to: &output
        )
        return output
    }

    static func sha256(
        schemaVersion: UInt32,
        operation: NativeDecompilerWireRequestOperation,
        target: NativeDecompilerWireTarget,
        image: NativeDecompilerWireImageIdentity,
        function: NativeDecompilerWireFunctionIdentity,
        memoryRegions: [NativeDecompilerWireMemoryRegion],
        symbols: [NativeDecompilerWireSymbolRecord],
        authoredInputs: NativeDecompilerWireAuthoredInputs,
        budgets: NativeDecompilerProfiledAnalysisBudgets
    ) throws -> String {
        let bytes = try preimage(
            schemaVersion: schemaVersion,
            operation: operation,
            target: target,
            image: image,
            function: function,
            memoryRegions: memoryRegions,
            symbols: symbols,
            authoredInputs: authoredInputs,
            budgets: budgets
        )
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func contextProfilePreimage(
        variant: NativeDecompilerWireArchitectureVariant = .arm64
    ) -> Data {
        let x86 = variant == .x86_64
        var output = Data()
        appendGlobalTextField("domain", contextProfileDomain, to: &output)
        appendGlobalTextField(
            "profileID",
            x86 ? "apple-x86_64-sysv-v1" : "apple-aarch64-pac-visible-clobber-v1",
            to: &output
        )
        appendGlobalTextField("languageID", x86 ? "x86:LE:64:default" : "AARCH64:LE:64:AppleSilicon", to: &output)
        appendGlobalTextField("compilerSpecID", x86 ? "gcc" : "default", to: &output)
        let context: [(String, UInt64)] = x86 ? [
            ("addrsize", 2), ("opsize", 1), ("rexprefix", 0), ("longMode", 1),
        ] : [
            ("ShowPAC", 1),
            ("PAC_clobber", 1),
            ("ShowBTI", 0),
            ("ShowMemTag", 0),
        ]
        appendGlobalDecimalField("context.count", UInt64(context.count), to: &output)
        for (index, value) in context.enumerated() {
            appendGlobalTextField("context[\(index)].name", value.0, to: &output)
            appendGlobalDecimalField("context[\(index)].value", value.1, to: &output)
        }
        return output
    }

    private static func canonicalAuthoredSection(
        _ authoredInputs: NativeDecompilerWireAuthoredInputs
    ) throws -> (bytes: Data, domainFrameByteCount: Int) {
        let canonicalInputs = try validatedAndSortedAuthoredInputs(authoredInputs)
        var output = Data()
        try appendCanonicalField("domain", textBytes(authoredDomain), to: &output)
        let domainFrameByteCount = output.count
        try appendCanonicalAuthoredFields(
            canonicalInputs,
            prefix: "authoredInputs",
            to: &output
        )
        return (output, domainFrameByteCount)
    }

    /// This is the sole authored-tree traversal. Task 4 extends this type and
    /// calls this writer from the whole-request stream after validation.
    private static func appendCanonicalAuthoredFields(
        _ authoredInputs: NativeDecompilerWireAuthoredInputs,
        prefix: String,
        to output: inout Data
    ) throws {
        try appendUInt64Field(
            "\(prefix).schemaVersion",
            UInt64(authoredInputs.schemaVersion),
            to: &output
        )

        try appendCountField("\(prefix).names.count", authoredInputs.names.count, to: &output)
        for (index, name) in authoredInputs.names.enumerated() {
            let itemPrefix = "\(prefix).names[\(index)]"
            try appendUInt64Field("\(itemPrefix).address", name.address.value, to: &output)
            try appendByteField("\(itemPrefix).subjectKind", name.subjectKind.rawValue, to: &output)
            try appendTextField("\(itemPrefix).name", name.name, to: &output)
        }

        try appendCountField(
            "\(prefix).signatures.count",
            authoredInputs.signatures.count,
            to: &output
        )
        for (index, signature) in authoredInputs.signatures.enumerated() {
            try appendCanonicalSignature(signature, itemPrefix: "\(prefix).signatures[\(index)]", to: &output)
        }

        try appendCountField(
            "\(prefix).appliedTypes.count",
            authoredInputs.appliedTypes.count,
            to: &output
        )
        for (index, appliedType) in authoredInputs.appliedTypes.enumerated() {
            let itemPrefix = "\(prefix).appliedTypes[\(index)]"
            try appendUInt64Field("\(itemPrefix).address", appliedType.address.value, to: &output)
            try appendByteField(
                "\(itemPrefix).subjectKind",
                appliedType.subjectKind.rawValue,
                to: &output
            )
            try appendTextField(
                "\(itemPrefix).typeDefinitionName",
                appliedType.typeDefinitionName,
                to: &output
            )
            try appendUInt64Field("\(itemPrefix).byteCount", appliedType.byteCount.value, to: &output)
        }

        try appendCountField(
            "\(prefix).typeDefinitions.count",
            authoredInputs.typeDefinitions.count,
            to: &output
        )
        for (index, definition) in authoredInputs.typeDefinitions.enumerated() {
            let itemPrefix = "\(prefix).typeDefinitions[\(index)]"
            try appendByteField("\(itemPrefix).kind", definition.kind.rawValue, to: &output)
            try appendTextField("\(itemPrefix).name", definition.name, to: &output)
            switch definition {
            case let .record(_, _, layoutRules, fields):
                try appendCanonicalLayoutRules(
                    layoutRules,
                    prefix: "\(itemPrefix).layoutRules",
                    to: &output
                )
                try appendCountField("\(itemPrefix).fields.count", fields.count, to: &output)
                for (fieldIndex, field) in fields.enumerated() {
                    try appendCanonicalRecordField(
                        field,
                        prefix: "\(itemPrefix).fields[\(fieldIndex)]",
                        storageDepth: 0,
                        to: &output
                    )
                }
            case let .enumeration(_, representation, cases):
                try appendByteField(
                    "\(itemPrefix).representation",
                    representation.rawValue,
                    to: &output
                )
                try appendCountField("\(itemPrefix).cases.count", cases.count, to: &output)
                for (caseIndex, enumCase) in cases.enumerated() {
                    let casePrefix = "\(itemPrefix).cases[\(caseIndex)]"
                    try appendTextField("\(casePrefix).name", enumCase.name, to: &output)
                    try appendInt32Field("\(casePrefix).value", enumCase.value, to: &output)
                }
            case let .typedef(_, target):
                try appendCanonicalStorage(target, prefix: "\(itemPrefix).target", depth: 0, to: &output)
            }
        }

        // Authored-input schema v2 appends callee signature hints; v1 bytes are unchanged.
        if authoredInputs.schemaVersion >= NativeDecompilerWireAuthoredInputs.calleeHintSchemaVersion {
            try appendCountField(
                "\(prefix).calleeSignatureHints.count",
                authoredInputs.calleeSignatureHints.count,
                to: &output
            )
            for (index, hint) in authoredInputs.calleeSignatureHints.enumerated() {
                let itemPrefix = "\(prefix).calleeSignatureHints[\(index)]"
                try appendTextField("\(itemPrefix).name", hint.name, to: &output)
                try appendByteField("\(itemPrefix).source", hint.source.rawValue, to: &output)
                try appendCanonicalSignature(hint.signature, itemPrefix: "\(itemPrefix).signature", to: &output)
            }
        }
        // Authored-input schema v3 appends local names; v1/v2 bytes are unchanged.
        if authoredInputs.schemaVersion >= NativeDecompilerWireAuthoredInputs.localNameSchemaVersion {
            try appendCountField("\(prefix).localNames.count", authoredInputs.localNames.count, to: &output)
            for (index, local) in authoredInputs.localNames.enumerated() {
                let itemPrefix = "\(prefix).localNames[\(index)]"
                try appendByteField("\(itemPrefix).storageKind", local.storageKind.rawValue, to: &output)
                try appendInt32Field("\(itemPrefix).stackOffset", local.stackOffset, to: &output)
                try appendUInt64Field("\(itemPrefix).byteSize", UInt64(local.byteSize), to: &output)
                try appendTextField("\(itemPrefix).register", local.register, to: &output)
                try appendTextField("\(itemPrefix).name", local.name, to: &output)
                try appendPresenceField("\(itemPrefix).type.present", local.type != nil, to: &output)
                if let type = local.type {
                    try appendCanonicalType(type, prefix: "\(itemPrefix).type", depth: 0, to: &output)
                }
            }
        }
    }

    private static func appendCanonicalSignature(
        _ signature: NativeDecompilerWireAuthoredSignature,
        itemPrefix: String,
        to output: inout Data
    ) throws {
        try appendUInt64Field(
            "\(itemPrefix).functionAddress",
            signature.functionAddress.value,
            to: &output
        )
        try appendPresenceField(
            "\(itemPrefix).returnType.present",
            signature.returnType != nil,
            to: &output
        )
        if let returnType = signature.returnType {
            try appendCanonicalType(returnType, prefix: "\(itemPrefix).returnType", depth: 0, to: &output)
        }
        try appendByteField(
            "\(itemPrefix).parameterListState",
            signature.parameterListState.rawValue,
            to: &output
        )
        try appendCountField(
            "\(itemPrefix).parameters.count",
            signature.parameters.count,
            to: &output
        )
        for (parameterIndex, parameter) in signature.parameters.enumerated() {
            let parameterPrefix = "\(itemPrefix).parameters[\(parameterIndex)]"
            try appendTextField("\(parameterPrefix).name", parameter.name, to: &output)
            try appendCanonicalType(
                parameter.type,
                prefix: "\(parameterPrefix).type",
                depth: 0,
                to: &output
            )
            if let storage = parameter.storageRegister {
                try appendTextField("\(parameterPrefix).storage", storage, to: &output)
            }
        }
        try appendByteField(
            "\(itemPrefix).variadicState",
            signature.variadicState.rawValue,
            to: &output
        )
        try appendByteField(
            "\(itemPrefix).noReturnState",
            signature.noReturnState.rawValue,
            to: &output
        )
    }


    private static func appendCanonicalType(
        _ type: NativeDecompilerWireAuthoredType,
        prefix: String,
        depth: UInt64,
        to output: inout Data
    ) throws {
        try appendByteField("\(prefix).tag", type.tag.rawValue, to: &output)
        try appendUInt64Field("\(prefix).depth", depth, to: &output)
        switch type {
        case let .qualifiedValue(atom, qualifiers):
            try appendByteField("\(prefix).atom.tag", atom.tag.rawValue, to: &output)
            switch atom {
            case .void:
                break
            case let .scalar(kind):
                try appendByteField("\(prefix).atom.scalarKind", kind.rawValue, to: &output)
            case let .darwinAlias(kind):
                try appendByteField("\(prefix).atom.darwinAliasKind", kind.rawValue, to: &output)
            case let .named(kind, name):
                try appendByteField("\(prefix).atom.namedKind", kind.rawValue, to: &output)
                try appendTextField("\(prefix).atom.name", name, to: &output)
            }
            try appendByteField("\(prefix).qualifiers", qualifiers.rawValue, to: &output)
        case let .dataPointer(pointee, indirectionLevel, pointerQualifiersByLevel):
            try appendCanonicalType(
                pointee,
                prefix: "\(prefix).pointee",
                depth: depth + 1,
                to: &output
            )
            try appendUInt64Field(
                "\(prefix).indirectionLevel",
                indirectionLevel.value,
                to: &output
            )
            try appendCountField(
                "\(prefix).pointerQualifiers.count",
                pointerQualifiersByLevel.count,
                to: &output
            )
            for (index, qualifiers) in pointerQualifiersByLevel.enumerated() {
                try appendByteField(
                    "\(prefix).pointerQualifiers[\(index)]",
                    qualifiers.rawValue,
                    to: &output
                )
            }
        }
    }

    private static func appendCanonicalStorage(
        _ storage: NativeDecompilerWireAuthoredFieldStorage,
        prefix: String,
        depth: UInt64,
        to output: inout Data
    ) throws {
        try appendByteField("\(prefix).tag", storage.tag.rawValue, to: &output)
        try appendUInt64Field("\(prefix).depth", depth, to: &output)
        switch storage {
        case let .value(type):
            try appendCanonicalType(type, prefix: "\(prefix).type", depth: depth, to: &output)
        case let .fixedArray(element, count):
            try appendUInt64Field("\(prefix).count", count.value, to: &output)
            try appendCanonicalStorage(
                element,
                prefix: "\(prefix).element",
                depth: depth + 1,
                to: &output
            )
        case let .flexibleArray(element):
            try appendCanonicalStorage(
                element,
                prefix: "\(prefix).element",
                depth: depth + 1,
                to: &output
            )
        case let .opaquePointerCarrier(kind):
            try appendByteField("\(prefix).kind", kind.rawValue, to: &output)
        case let .inlineAggregate(kind, layoutRules, fields):
            try appendByteField("\(prefix).kind", kind.rawValue, to: &output)
            try appendCanonicalLayoutRules(
                layoutRules,
                prefix: "\(prefix).layoutRules",
                to: &output
            )
            try appendCountField("\(prefix).fields.count", fields.count, to: &output)
            for (index, field) in fields.enumerated() {
                try appendCanonicalRecordField(
                    field,
                    prefix: "\(prefix).fields[\(index)]",
                    storageDepth: depth + 1,
                    to: &output
                )
            }
        }
    }

    private static func appendCanonicalRecordField(
        _ field: NativeDecompilerWireAuthoredRecordField,
        prefix: String,
        storageDepth: UInt64,
        to output: inout Data
    ) throws {
        try appendTextField("\(prefix).name", field.name, to: &output)
        try appendCanonicalStorage(
            field.storage,
            prefix: "\(prefix).storage",
            depth: storageDepth,
            to: &output
        )
        try appendOptionalUInt64(
            field.bitWidth,
            prefix: "\(prefix).bitWidth",
            to: &output
        )
        try appendOptionalUInt64(
            field.minimumAlignment,
            prefix: "\(prefix).minimumAlignment",
            to: &output
        )
        try appendPresenceField(
            "\(prefix).minimumAlignmentType.present",
            field.minimumAlignmentType != nil,
            to: &output
        )
        if let minimumAlignmentType = field.minimumAlignmentType {
            try appendCanonicalType(
                minimumAlignmentType,
                prefix: "\(prefix).minimumAlignmentType",
                depth: storageDepth + 1,
                to: &output
            )
        }
        try appendBooleanField(
            "\(prefix).promotesInlineFields",
            field.promotesInlineFields,
            to: &output
        )
    }

    private static func appendCanonicalLayoutRules(
        _ layoutRules: NativeDecompilerWireAuthoredLayoutRules,
        prefix: String,
        to output: inout Data
    ) throws {
        try appendBooleanField("\(prefix).isPacked", layoutRules.isPacked, to: &output)
        try appendOptionalUInt64(
            layoutRules.packAlignment,
            prefix: "\(prefix).packAlignment",
            to: &output
        )
        try appendOptionalUInt64(
            layoutRules.minimumAlignment,
            prefix: "\(prefix).minimumAlignment",
            to: &output
        )
    }

    private static func validatedAndSortedAuthoredInputs(
        _ inputs: NativeDecompilerWireAuthoredInputs
    ) throws -> NativeDecompilerWireAuthoredInputs {
        guard (1...NativeDecompilerWireAuthoredInputs.localNameSchemaVersion).contains(inputs.schemaVersion),
            inputs.schemaVersion != 1 || inputs.calleeSignatureHints.isEmpty,
            inputs.schemaVersion >= NativeDecompilerWireAuthoredInputs.localNameSchemaVersion
                || inputs.localNames.isEmpty else {
            throw NativeDecompilerWireAuthoredValidationError.unsupportedSchemaVersion
        }
        guard inputs.localNames.count <= maximumNames else {
            throw NativeDecompilerWireAuthoredValidationError.tooManyNames
        }
        var localKeys = Set<String>()
        for local in inputs.localNames {
            try validateText(local.name, maximum: maximumSemanticNameBytes, tooLong: .semanticNameTooLong)
            guard !local.name.isEmpty else { throw NativeDecompilerWireAuthoredValidationError.invalidText }
            switch local.storageKind {
            case .stack:
                guard local.register.isEmpty, (1...4_096).contains(local.byteSize) else {
                    throw NativeDecompilerWireAuthoredValidationError.invalidTaggedPayload
                }
            case .register:
                guard local.stackOffset == 0, local.byteSize == 0,
                      Self.isAuthoredLocalRegister(local.register) else {
                    throw NativeDecompilerWireAuthoredValidationError.invalidTaggedPayload
                }
            }
            guard localKeys.insert("\(local.storageKind.rawValue):\(local.stackOffset):\(local.register)").inserted else {
                throw NativeDecompilerWireAuthoredValidationError.duplicateName
            }
            if let type = local.type { try validateType(type, depth: 0, allowsVoidValue: false) }
        }
        guard inputs.calleeSignatureHints.count <= maximumSignatures else {
            throw NativeDecompilerWireAuthoredValidationError.tooManySignatures
        }
        guard inputs.names.count <= maximumNames else {
            throw NativeDecompilerWireAuthoredValidationError.tooManyNames
        }
        guard inputs.signatures.count <= maximumSignatures else {
            throw NativeDecompilerWireAuthoredValidationError.tooManySignatures
        }
        guard inputs.appliedTypes.count <= maximumAppliedTypes else {
            throw NativeDecompilerWireAuthoredValidationError.tooManyAppliedTypes
        }
        guard inputs.typeDefinitions.count <= maximumTypeDefinitions else {
            throw NativeDecompilerWireAuthoredValidationError.tooManyTypeDefinitions
        }

        for signature in inputs.signatures where signature.parameters.count > maximumParametersPerSignature {
            throw NativeDecompilerWireAuthoredValidationError.tooManyParameters
        }

        for hint in inputs.calleeSignatureHints
            where hint.signature.parameters.count > maximumParametersPerSignature {
            throw NativeDecompilerWireAuthoredValidationError.tooManyParameters
        }
        var aggregateMembers = inputs.signatures.reduce(0) { $0 + $1.parameters.count }
            + inputs.calleeSignatureHints.reduce(0) { $0 + $1.signature.parameters.count }
        guard aggregateMembers <= maximumAggregateMembers else {
            throw NativeDecompilerWireAuthoredValidationError.tooManyAggregateMembers
        }
        for definition in inputs.typeDefinitions {
            switch definition {
            case let .record(_, _, _, fields):
                aggregateMembers = try addingAggregateMembers(
                    aggregateMembers,
                    count: try aggregateFieldCount(fields, storageDepth: 0)
                )
            case let .enumeration(_, _, cases):
                aggregateMembers = try addingAggregateMembers(aggregateMembers, count: cases.count)
            case let .typedef(_, target):
                aggregateMembers = try addingAggregateMembers(
                    aggregateMembers,
                    count: try aggregateFieldCount(in: target, depth: 0)
                )
            }
        }
        guard aggregateMembers <= maximumAggregateMembers else {
            throw NativeDecompilerWireAuthoredValidationError.tooManyAggregateMembers
        }

        var nameKeys = Set<NameKey>()
        for name in inputs.names {
            let key = NameKey(address: name.address.value, subjectKind: name.subjectKind.rawValue)
            guard nameKeys.insert(key).inserted else {
                throw NativeDecompilerWireAuthoredValidationError.duplicateName
            }
        }
        var signatureKeys = Set<UInt64>()
        for signature in inputs.signatures {
            guard signatureKeys.insert(signature.functionAddress.value).inserted else {
                throw NativeDecompilerWireAuthoredValidationError.duplicateSignature
            }
        }
        var hintKeys = Set<UInt64>()
        for hint in inputs.calleeSignatureHints {
            guard !signatureKeys.contains(hint.signature.functionAddress.value),
                  hintKeys.insert(hint.signature.functionAddress.value).inserted else {
                throw NativeDecompilerWireAuthoredValidationError.duplicateSignature
            }
        }
        var appliedKeys = Set<AppliedTypeKey>()
        for appliedType in inputs.appliedTypes {
            let key = AppliedTypeKey(
                address: appliedType.address.value,
                subjectKind: appliedType.subjectKind.rawValue
            )
            guard appliedKeys.insert(key).inserted else {
                throw NativeDecompilerWireAuthoredValidationError.duplicateAppliedType
            }
        }
        var definitionKeys = Set<Data>()
        for definition in inputs.typeDefinitions {
            guard definitionKeys.insert(textBytes(definition.name)).inserted else {
                throw NativeDecompilerWireAuthoredValidationError.duplicateTypeDefinition
            }
        }

        for name in inputs.names {
            try validateText(name.name, maximum: maximumSemanticNameBytes, tooLong: .semanticNameTooLong)
        }
        for signature in inputs.signatures {
            guard signature.parameterListState != .unspecified || signature.parameters.isEmpty else {
                throw NativeDecompilerWireAuthoredValidationError.invalidTaggedPayload
            }
            if let returnType = signature.returnType {
                try validateType(returnType, depth: 0, allowsVoidValue: true)
            }
            for parameter in signature.parameters {
                try validateText(
                    parameter.name,
                    maximum: maximumSemanticNameBytes,
                    tooLong: .semanticNameTooLong
                )
                try validateType(parameter.type, depth: 0, allowsVoidValue: false)
                try validateParameterStorage(parameter.storageRegister)
            }
        }
        for hint in inputs.calleeSignatureHints {
            try validateText(hint.name, maximum: maximumSemanticNameBytes, tooLong: .semanticNameTooLong)
            guard hint.signature.parameterListState == .authoritative else {
                throw NativeDecompilerWireAuthoredValidationError.invalidTaggedPayload
            }
            if let returnType = hint.signature.returnType {
                try validateType(returnType, depth: 0, allowsVoidValue: true)
            }
            for parameter in hint.signature.parameters {
                try validateText(parameter.name, maximum: maximumSemanticNameBytes, tooLong: .semanticNameTooLong)
                try validateType(parameter.type, depth: 0, allowsVoidValue: false)
                try validateParameterStorage(parameter.storageRegister)
            }
        }
        for appliedType in inputs.appliedTypes {
            try validateText(
                appliedType.typeDefinitionName,
                maximum: maximumCatalogTextBytes,
                tooLong: .catalogTextTooLong
            )
            guard appliedType.byteCount.value > 0 else {
                throw NativeDecompilerWireAuthoredValidationError.invalidNumericValue
            }
            guard appliedType.byteCount.value <= maximumComputedStorageBytes else {
                throw NativeDecompilerWireAuthoredValidationError.computedStorageTooLarge
            }
        }
        for definition in inputs.typeDefinitions {
            try validateDefinition(definition)
        }

        return NativeDecompilerWireAuthoredInputs(
            schemaVersion: inputs.schemaVersion,
            names: inputs.names.sorted(by: authoredNamePrecedes),
            signatures: inputs.signatures.sorted {
                $0.functionAddress.value < $1.functionAddress.value
            },
            appliedTypes: inputs.appliedTypes.sorted(by: appliedTypePrecedes),
            typeDefinitions: inputs.typeDefinitions.sorted(by: definitionPrecedes),
            calleeSignatureHints: inputs.calleeSignatureHints.sorted {
                $0.signature.functionAddress.value < $1.signature.functionAddress.value
            },
            localNames: inputs.localNames.sorted {
                ($0.storageKind.rawValue, $0.stackOffset, $0.register) < ($1.storageKind.rawValue, $1.stackOffset, $1.register)
            }
        )
    }

    /// `x0`…`x30`, lowercase.
    static func isAuthoredLocalRegister(_ register: String) -> Bool {
        guard register.hasPrefix("x"), let index = Int(register.dropFirst()), (0...30).contains(index) else { return false }
        return register == "x\(index)"
    }

    private static func aggregateFieldCount(
        _ fields: [NativeDecompilerWireAuthoredRecordField],
        storageDepth: UInt64
    ) throws -> Int {
        guard storageDepth <= maximumAuthoredDepth else {
            throw NativeDecompilerWireAuthoredValidationError.authoredDepthExceeded
        }
        var total = fields.count
        for field in fields {
            total = try addingAggregateMembers(
                total,
                count: try aggregateFieldCount(in: field.storage, depth: storageDepth)
            )
        }
        return total
    }

    private static func aggregateFieldCount(
        in storage: NativeDecompilerWireAuthoredFieldStorage,
        depth: UInt64
    ) throws -> Int {
        guard depth <= maximumAuthoredDepth else {
            throw NativeDecompilerWireAuthoredValidationError.authoredDepthExceeded
        }
        switch storage {
        case .value, .opaquePointerCarrier:
            return 0
        case let .fixedArray(element, _), let .flexibleArray(element):
            return try aggregateFieldCount(in: element, depth: depth + 1)
        case let .inlineAggregate(_, _, fields):
            return try aggregateFieldCount(fields, storageDepth: depth + 1)
        }
    }

    private static func addingAggregateMembers(_ lhs: Int, count rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum <= maximumAggregateMembers else {
            throw NativeDecompilerWireAuthoredValidationError.tooManyAggregateMembers
        }
        return sum
    }

    private static func validateDefinition(
        _ definition: NativeDecompilerWireAuthoredTypeDefinition
    ) throws {
        try validateText(
            definition.name,
            maximum: maximumCatalogTextBytes,
            tooLong: .catalogTextTooLong
        )
        let computedSize: UInt64
        switch definition {
        case let .record(kind, _, layoutRules, fields):
            guard kind == .`struct` || kind == .union else {
                throw NativeDecompilerWireAuthoredValidationError.invalidTaggedPayload
            }
            try validateLayoutRules(layoutRules)
            for (index, field) in fields.enumerated() {
                try validateRecordField(
                    field,
                    storageDepth: 0,
                    permitsFlexibleArray: kind == .`struct` && index == fields.index(before: fields.endIndex)
                )
            }
            let sizes = try fields.map { try computedStorageSize($0.storage, depth: 0) }
            computedSize = kind == .union ? (sizes.max() ?? 0) : try checkedSum(sizes)
        case let .enumeration(_, representation, cases):
            guard representation == .signed32 else {
                throw NativeDecompilerWireAuthoredValidationError.invalidTaggedPayload
            }
            for enumCase in cases {
                try validateText(
                    enumCase.name,
                    maximum: maximumSemanticNameBytes,
                    tooLong: .semanticNameTooLong
                )
            }
            computedSize = 4
        case let .typedef(_, target):
            try validateStorage(target, depth: 0, permitsFlexibleArray: false)
            computedSize = try computedStorageSize(target, depth: 0)
        }
        guard computedSize <= maximumComputedStorageBytes else {
            throw NativeDecompilerWireAuthoredValidationError.computedStorageTooLarge
        }
    }

    private static func validateRecordField(
        _ field: NativeDecompilerWireAuthoredRecordField,
        storageDepth: UInt64,
        permitsFlexibleArray: Bool
    ) throws {
        if field.promotesInlineFields {
            guard field.name.isEmpty,
                  field.bitWidth == nil,
                  case let .inlineAggregate(kind, _, _) = field.storage,
                  kind == .`struct` || kind == .union
            else {
                throw NativeDecompilerWireAuthoredValidationError.invalidFieldStorage
            }
        } else if field.name.isEmpty {
            guard field.bitWidth != nil, case .value = field.storage else {
                throw NativeDecompilerWireAuthoredValidationError.invalidFieldStorage
            }
        } else {
            try validateText(
                field.name,
                maximum: maximumSemanticNameBytes,
                tooLong: .semanticNameTooLong
            )
        }

        if let bitWidth = field.bitWidth {
            guard case .value = field.storage else {
                throw NativeDecompilerWireAuthoredValidationError.invalidFieldStorage
            }
            if bitWidth.value == 0, !field.name.isEmpty {
                throw NativeDecompilerWireAuthoredValidationError.invalidNumericValue
            }
        }
        try validateStorage(field.storage, depth: storageDepth, permitsFlexibleArray: permitsFlexibleArray)
        if let minimumAlignment = field.minimumAlignment, minimumAlignment.value == 0 {
            throw NativeDecompilerWireAuthoredValidationError.invalidNumericValue
        }
        if let minimumAlignmentType = field.minimumAlignmentType {
            try validateType(minimumAlignmentType, depth: storageDepth + 1, allowsVoidValue: false)
        }
    }

    private static func validateLayoutRules(
        _ layoutRules: NativeDecompilerWireAuthoredLayoutRules
    ) throws {
        if let packAlignment = layoutRules.packAlignment, packAlignment.value == 0 {
            throw NativeDecompilerWireAuthoredValidationError.invalidNumericValue
        }
        if let minimumAlignment = layoutRules.minimumAlignment, minimumAlignment.value == 0 {
            throw NativeDecompilerWireAuthoredValidationError.invalidNumericValue
        }
    }

    private static func validateStorage(
        _ storage: NativeDecompilerWireAuthoredFieldStorage,
        depth: UInt64,
        permitsFlexibleArray: Bool
    ) throws {
        guard depth <= maximumAuthoredDepth else {
            throw NativeDecompilerWireAuthoredValidationError.authoredDepthExceeded
        }
        switch storage {
        case let .value(type):
            try validateType(type, depth: depth, allowsVoidValue: false)
        case let .fixedArray(element, count):
            guard count.value > 0, count.value <= maximumFixedArrayElements else {
                throw NativeDecompilerWireAuthoredValidationError.fixedArrayElementCountOutOfRange
            }
            try validateStorage(element, depth: depth + 1, permitsFlexibleArray: false)
        case let .flexibleArray(element):
            guard permitsFlexibleArray else {
                throw NativeDecompilerWireAuthoredValidationError.invalidFieldStorage
            }
            try validateStorage(element, depth: depth + 1, permitsFlexibleArray: false)
        case .opaquePointerCarrier:
            break
        case let .inlineAggregate(kind, layoutRules, fields):
            guard kind == .`struct` || kind == .union else {
                throw NativeDecompilerWireAuthoredValidationError.invalidFieldStorage
            }
            try validateLayoutRules(layoutRules)
            for (index, field) in fields.enumerated() {
                try validateRecordField(
                    field,
                    storageDepth: depth + 1,
                    permitsFlexibleArray: permitsFlexibleArray
                        && kind == .`struct`
                        && index == fields.index(before: fields.endIndex)
                )
            }
        }
    }

    private static func validateType(
        _ type: NativeDecompilerWireAuthoredType,
        depth: UInt64,
        allowsVoidValue: Bool
    ) throws {
        guard depth <= maximumAuthoredDepth else {
            throw NativeDecompilerWireAuthoredValidationError.authoredDepthExceeded
        }
        switch type {
        case let .qualifiedValue(atom, qualifiers):
            guard qualifiers.rawValue & ~UInt8(0x03) == 0 else {
                throw NativeDecompilerWireAuthoredValidationError.unknownQualifierBits
            }
            switch atom {
            case .void:
                guard allowsVoidValue else {
                    throw NativeDecompilerWireAuthoredValidationError.invalidTaggedPayload
                }
            case .scalar, .darwinAlias:
                break
            case let .named(_, name):
                try validateText(
                    name,
                    maximum: maximumCatalogTextBytes,
                    tooLong: .catalogTextTooLong
                )
            }
        case let .dataPointer(pointee, indirectionLevel, pointerQualifiersByLevel):
            guard (1...8).contains(indirectionLevel.value),
                  UInt64(pointerQualifiersByLevel.count) == indirectionLevel.value
            else {
                throw NativeDecompilerWireAuthoredValidationError.invalidPointer
            }
            guard case .qualifiedValue = pointee else {
                throw NativeDecompilerWireAuthoredValidationError.invalidPointer
            }
            for qualifiers in pointerQualifiersByLevel where qualifiers.rawValue & ~UInt8(0x07) != 0 {
                throw NativeDecompilerWireAuthoredValidationError.unknownQualifierBits
            }
            try validateType(pointee, depth: depth + 1, allowsVoidValue: true)
        }
    }

    private static func computedStorageSize(
        _ storage: NativeDecompilerWireAuthoredFieldStorage,
        depth: UInt64
    ) throws -> UInt64 {
        guard depth <= maximumAuthoredDepth else {
            throw NativeDecompilerWireAuthoredValidationError.authoredDepthExceeded
        }
        switch storage {
        case let .value(type):
            return computedTypeSize(type)
        case let .fixedArray(element, count):
            let elementSize = try computedStorageSize(element, depth: depth + 1)
            return try checkedProduct(elementSize, count.value)
        case .flexibleArray:
            return 0
        case .opaquePointerCarrier:
            return 8
        case let .inlineAggregate(kind, _, fields):
            let sizes = try fields.map { try computedStorageSize($0.storage, depth: depth + 1) }
            return kind == .union ? (sizes.max() ?? 0) : try checkedSum(sizes)
        }
    }

    private static func computedTypeSize(_ type: NativeDecompilerWireAuthoredType) -> UInt64 {
        switch type {
        case let .qualifiedValue(atom, _):
            switch atom {
            case .void:
                return 0
            case let .scalar(kind):
                switch kind {
                case .bool, .char, .signed8, .unsigned8: return 1
                case .signed16, .unsigned16: return 2
                case .signed32, .unsigned32, .float32: return 4
                case .signed64, .unsigned64, .float64: return 8
                }
            case let .darwinAlias(kind):
                return kind == .wcharT ? 4 : 8
            case .named:
                // Exact named-layout resolution occurs in prepared authority.
                // The DTO bound still accounts for every explicit array byte.
                return 0
            }
        case .dataPointer:
            return 8
        }
    }

    private static func checkedProduct(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow, product <= maximumComputedStorageBytes else {
            throw NativeDecompilerWireAuthoredValidationError.computedStorageTooLarge
        }
        return product
    }

    private static func checkedSum(_ values: [UInt64]) throws -> UInt64 {
        var sum: UInt64 = 0
        for value in values {
            let (next, overflow) = sum.addingReportingOverflow(value)
            guard !overflow, next <= maximumComputedStorageBytes else {
                throw NativeDecompilerWireAuthoredValidationError.computedStorageTooLarge
            }
            sum = next
        }
        return sum
    }

    private static func validateParameterStorage(_ storage: String?) throws {
        guard let storage else { return }
        try validateText(storage, maximum: 1_024, tooLong: .invalidText)
        guard !storage.unicodeScalars.contains(where: { $0.properties.isWhitespace }) else {
            throw NativeDecompilerWireAuthoredValidationError.invalidText
        }
    }

    private static func validateText(
        _ text: String,
        maximum: Int,
        tooLong: NativeDecompilerWireAuthoredValidationError
    ) throws {
        let bytes = textBytes(text)
        guard !bytes.isEmpty else {
            throw NativeDecompilerWireAuthoredValidationError.invalidText
        }
        guard bytes.count <= maximum else { throw tooLong }
        guard !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f }) else {
            throw NativeDecompilerWireAuthoredValidationError.invalidText
        }
    }

    private static func authoredNamePrecedes(
        _ lhs: NativeDecompilerWireAuthoredName,
        _ rhs: NativeDecompilerWireAuthoredName
    ) -> Bool {
        if lhs.address.value != rhs.address.value { return lhs.address.value < rhs.address.value }
        if lhs.subjectKind.rawValue != rhs.subjectKind.rawValue {
            return lhs.subjectKind.rawValue < rhs.subjectKind.rawValue
        }
        return textBytes(lhs.name).lexicographicallyPrecedes(textBytes(rhs.name))
    }

    private static func appliedTypePrecedes(
        _ lhs: NativeDecompilerWireAppliedType,
        _ rhs: NativeDecompilerWireAppliedType
    ) -> Bool {
        if lhs.address.value != rhs.address.value { return lhs.address.value < rhs.address.value }
        if lhs.subjectKind.rawValue != rhs.subjectKind.rawValue {
            return lhs.subjectKind.rawValue < rhs.subjectKind.rawValue
        }
        return textBytes(lhs.typeDefinitionName).lexicographicallyPrecedes(
            textBytes(rhs.typeDefinitionName)
        )
    }

    private static func definitionPrecedes(
        _ lhs: NativeDecompilerWireAuthoredTypeDefinition,
        _ rhs: NativeDecompilerWireAuthoredTypeDefinition
    ) -> Bool {
        let lhsName = textBytes(lhs.name)
        let rhsName = textBytes(rhs.name)
        if lhsName != rhsName { return lhsName.lexicographicallyPrecedes(rhsName) }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    private static func symbolPrecedes(
        _ lhs: NativeDecompilerWireSymbolRecord,
        _ rhs: NativeDecompilerWireSymbolRecord
    ) -> Bool {
        if lhs.address.value != rhs.address.value { return lhs.address.value < rhs.address.value }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        let lhsName = textBytes(lhs.name)
        let rhsName = textBytes(rhs.name)
        if lhsName != rhsName { return lhsName.lexicographicallyPrecedes(rhsName) }
        return textBytes(lhs.imageID).lexicographicallyPrecedes(textBytes(rhs.imageID))
    }

    private static func appendOptionalUInt64(
        _ value: NativeDecompilerWireUInt64?,
        prefix: String,
        to output: inout Data
    ) throws {
        try appendPresenceField("\(prefix).present", value != nil, to: &output)
        if let value {
            try appendUInt64Field("\(prefix).value", value.value, to: &output)
        }
    }

    private static func appendCountField(_ name: String, _ count: Int, to output: inout Data) throws {
        try appendUInt64Field(name, UInt64(count), to: &output)
    }

    private static func appendUInt64Field(_ name: String, _ value: UInt64, to output: inout Data) throws {
        try appendCanonicalField(name, uint64Bytes(value), to: &output)
    }

    private static func appendInt32Field(_ name: String, _ value: Int32, to output: inout Data) throws {
        try appendCanonicalField(name, int32Bytes(value), to: &output)
    }

    private static func appendByteField(_ name: String, _ value: UInt8, to output: inout Data) throws {
        try appendCanonicalField(name, Data([value]), to: &output)
    }

    private static func appendBooleanField(_ name: String, _ value: Bool, to output: inout Data) throws {
        try appendByteField(name, value ? 1 : 0, to: &output)
    }

    private static func appendPresenceField(_ name: String, _ value: Bool, to output: inout Data) throws {
        try appendBooleanField(name, value, to: &output)
    }

    private static func appendTextField(_ name: String, _ value: String, to output: inout Data) throws {
        try appendCanonicalField(name, textBytes(value), to: &output)
    }

    private static func appendCanonicalField(_ name: String, _ value: Data, to output: inout Data) throws {
        appendToken(textBytes(name), to: &output)
        appendToken(value, to: &output)
        guard output.count <= maximumCanonicalAuthoredBytes else {
            throw NativeDecompilerWireAuthoredValidationError.canonicalAuthoredInputTooLarge
        }
    }

    private static func appendGlobalField(_ name: String, _ value: Data, to output: inout Data) {
        appendToken(textBytes(name), to: &output)
        appendToken(value, to: &output)
    }

    private static func appendGlobalTextField(
        _ name: String,
        _ value: String,
        to output: inout Data
    ) {
        appendGlobalField(name, textBytes(value), to: &output)
    }

    private static func appendGlobalDecimalField(
        _ name: String,
        _ value: UInt64,
        to output: inout Data
    ) {
        appendGlobalTextField(name, String(value), to: &output)
    }

    private static func appendGlobalBooleanField(
        _ name: String,
        _ value: Bool,
        to output: inout Data
    ) {
        appendGlobalDecimalField(name, value ? 1 : 0, to: &output)
    }

    private static func appendToken(_ bytes: Data, to output: inout Data) {
        output.append(contentsOf: String(bytes.count).utf8)
        output.append(0x3a)
        output.append(bytes)
        output.append(0x0a)
    }

    private static func textBytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    private static func uint64Bytes(_ value: UInt64) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 56),
            UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40),
            UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    private static func int32Bytes(_ value: Int32) -> Data {
        let bits = UInt32(bitPattern: value)
        return Data([
            UInt8(truncatingIfNeeded: bits >> 24),
            UInt8(truncatingIfNeeded: bits >> 16),
            UInt8(truncatingIfNeeded: bits >> 8),
            UInt8(truncatingIfNeeded: bits),
        ])
    }

    private struct NameKey: Hashable {
        let address: UInt64
        let subjectKind: UInt8
    }

    private struct AppliedTypeKey: Hashable {
        let address: UInt64
        let subjectKind: UInt8
    }
}
