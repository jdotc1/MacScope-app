import Foundation

/// Runtime call signatures that no public SDK header provides, registered into
/// `CallSignatureCatalog.standard` after the seeds and the header-verified corpus
/// (earlier entries win, so nothing here can shadow them). HOP-5 follow-up.
///
/// Swift runtime: generated from swiftlang/swift `swift-6.3-RELEASE`
/// (aa782beb23b8bd83bd16fca831532a05dd6cea39) `include/swift/Runtime/RuntimeFunctions.def`,
/// keeping only entries that use the plain C calling convention (`C_CC`), return a single
/// value, use argument types with a direct AAPCS64 mapping, and are exported by the macOS
/// SDK's Swift `.tbd` files (Xcode Swift 6.4). Excluded: `SwiftCC`, `SwiftDirectRR_CC` and
/// `SwiftAsyncCC` entries (their register assignment differs from C), multi-value returns
/// and SDK-unexported names. Pointer-typed IR values are spelled `void *`/`const void *`;
/// the parameter name carries the IR role (metadata, object, witnessTable, ...).
///
/// Objective-C register helpers: `objc_retain_xN`/`objc_release_xN` take the object in
/// register xN, not x0 (objc4-951.1 `runtime/objc-abi.h`: "These do not have the normal C
/// calling convention (except for _x0)"). Only the `_x0` forms are ordinary C signatures and
/// are registered here; consumers bind the others through `objcRegisterHelper(for:)`.
public enum RuntimeSignatureSeeds {
    /// Everything registered into the standard catalog.
    public static var all: [CallSignatureSpec] { swiftRuntime + objcRegisterHelperX0Specs }

    public static let swiftRuntime: [CallSignatureSpec] = [
        // RuntimeFunctions.def:84; IR RefCountedPtrTy()
        CallSignatureSpec(canonicalName: "swift_allocEmptyBox", returnType: "void *",
                          parameters: []),
        // RuntimeFunctions.def:92; IR RefCountedPtrTy(TypeMetadataPtrTy, SizeTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_allocObject", returnType: "void *",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2")]),
        // RuntimeFunctions.def:1049; IR TypeMetadataPtrTy(TypeContextDescriptorPtrTy, Int8PtrPtrTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_allocateGenericClassMetadata", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "descriptor"), .init(type: "void **", name: "pointer1"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:1074; IR TypeMetadataPtrTy(TypeContextDescriptorPtrTy, Int8PtrPtrTy, Int8PtrTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_allocateGenericValueMetadata", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "descriptor"), .init(type: "void **", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "size_t", name: "size")]),
        // RuntimeFunctions.def:765; IR VoidTy(OpaquePtrTy, OpaquePtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_arrayAssignWithCopyBackToFront", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:756; IR VoidTy(OpaquePtrTy, OpaquePtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_arrayAssignWithCopyFrontToBack", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:747; IR VoidTy(OpaquePtrTy, OpaquePtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_arrayAssignWithCopyNoAlias", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:774; IR VoidTy(OpaquePtrTy, OpaquePtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_arrayAssignWithTake", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:782; IR VoidTy(OpaquePtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_arrayDestroy", returnType: "void",
                          parameters: [.init(type: "void *", name: "value"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:711; IR VoidTy(OpaquePtrTy, OpaquePtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_arrayInitWithCopy", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:738; IR VoidTy(OpaquePtrTy, OpaquePtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_arrayInitWithTakeBackToFront", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:729; IR VoidTy(OpaquePtrTy, OpaquePtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_arrayInitWithTakeFrontToBack", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:720; IR VoidTy(OpaquePtrTy, OpaquePtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_arrayInitWithTakeNoAlias", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:1931; IR VoidTy(Int8PtrTy, PtrTy, SizeTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_beginAccess", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "size_t", name: "size"), .init(type: "void *", name: "pointer3")]),
        // RuntimeFunctions.def:431; IR VoidTy(BridgeObjectPtrTy)
        CallSignatureSpec(canonicalName: "swift_bridgeObjectRelease", returnType: "void",
                          parameters: [.init(type: "void *", name: "bridgeObject")]),
        // RuntimeFunctions.def:326; IR VoidTy(BridgeObjectPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_bridgeObjectRelease_n", returnType: "void",
                          parameters: [.init(type: "void *", name: "bridgeObject"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:422; IR BridgeObjectPtrTy(BridgeObjectPtrTy)
        CallSignatureSpec(canonicalName: "swift_bridgeObjectRetain", returnType: "void *",
                          parameters: [.init(type: "void *", name: "bridgeObject")]),
        // RuntimeFunctions.def:317; IR BridgeObjectPtrTy(BridgeObjectPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_bridgeObjectRetain_n", returnType: "void *",
                          parameters: [.init(type: "void *", name: "bridgeObject"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:3067; IR VoidTy(PtrTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_clearSensitive", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "size_t", name: "size")]),
        // RuntimeFunctions.def:1859; IR WitnessTablePtrTy(TypeMetadataPtrTy, ProtocolDescriptorPtrTy)
        CallSignatureSpec(canonicalName: "swift_conformsToProtocol", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "const void *", name: "protocol")]),
        // RuntimeFunctions.def:1868; IR WitnessTablePtrTy(TypeMetadataPtrTy, ProtocolDescriptorPtrTy)
        CallSignatureSpec(canonicalName: "swift_conformsToProtocol2", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "const void *", name: "protocol")]),
        // RuntimeFunctions.def:2206; IR VoidTy(Int8PtrTy, Int8PtrTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_copyKeyPathTrivialIndices", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "size_t", name: "size")]),
        // RuntimeFunctions.def:200; IR OpaquePtrTy(OpaquePtrTy, OpaquePtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_copyPOD", returnType: "void *",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2096; IR Int8PtrTy(SizeTy, Int64Ty)
        CallSignatureSpec(canonicalName: "swift_coroFrameAlloc", returnType: "void *",
                          parameters: [.init(type: "size_t", name: "size"), .init(type: "int64_t", name: "value")]),
        // RuntimeFunctions.def:1062; IR TypeMetadataPtrTy(TypeContextDescriptorPtrTy, Int8PtrPtrTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_allocateGenericClassMetadataWithLayoutString", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "descriptor"), .init(type: "void **", name: "pointer1"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:1088; IR TypeMetadataPtrTy(TypeContextDescriptorPtrTy, Int8PtrPtrTy, Int8PtrTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_cvw_allocateGenericValueMetadataWithLayoutString", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "descriptor"), .init(type: "void **", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "size_t", name: "size")]),
        // RuntimeFunctions.def:2799; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_assignWithCopy", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2859; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_assignWithCopyMultiPayloadEnumFN", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2809; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_assignWithTake", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2869; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_assignWithTakeMultiPayloadEnumFN", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2788; IR VoidTy(Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_destroy", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2849; IR VoidTy(Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_destroyMultiPayloadEnumFN", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2956; IR Int32Ty(Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_enumFn_getEnumTag", returnType: "int32_t",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2945; IR VoidTy(Int8PtrTy, Int32Ty, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_enumSimple_destructiveInjectEnumTag", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "int32_t", name: "value"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2933; IR Int32Ty(Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_enumSimple_getEnumTag", returnType: "int32_t",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:1578; IR VoidTy(TypeMetadataPtrTy, SizeTy, SizeTy, TypeMetadataPtrPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_initEnumMetadataMultiPayloadWithLayoutString", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "void **", name: "metadataArray")]),
        // RuntimeFunctions.def:1525; IR VoidTy(TypeMetadataPtrTy, SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_initEnumMetadataSingleCaseWithLayoutString", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata1"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata2")]),
        // RuntimeFunctions.def:1551; IR VoidTy(TypeMetadataPtrTy, SizeTy, TypeMetadataPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_cvw_initEnumMetadataSinglePayloadWithLayoutString", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata1"), .init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata2"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:1502; IR VoidTy(TypeMetadataPtrTy, SizeTy, SizeTy, PtrTy, Int8PtrTy, PtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_initStructMetadataWithLayoutString", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "void *", name: "pointer3")]),
        // RuntimeFunctions.def:2819; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_initWithCopy", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2879; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_initWithCopyMultiPayloadEnumFN", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2829; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_initWithTake", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2889; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_initWithTakeMultiPayloadEnumFN", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2839; IR Int8PtrTy(PtrTy, PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_initializeBufferWithCopyOfBuffer", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2899; IR Int8PtrTy(PtrTy, PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_initializeBufferWithCopyOfBufferMultiPayloadEnumFN", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:3013; IR VoidTy(Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_instantiateLayoutString", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2979; IR VoidTy(Int8PtrTy, Int32Ty, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_multiPayloadEnumGeneric_destructiveInjectEnumTag", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "int32_t", name: "value"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2967; IR Int32Ty(Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_multiPayloadEnumGeneric_getEnumTag", returnType: "int32_t",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:3002; IR VoidTy(Int8PtrTy, Int32Ty, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_singlePayloadEnumGeneric_destructiveInjectEnumTag", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "int32_t", name: "value"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2990; IR Int32Ty(Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_singlePayloadEnumGeneric_getEnumTag", returnType: "int32_t",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2922; IR VoidTy(Int8PtrTy, Int32Ty, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_singletonEnum_destructiveInjectEnumTag", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "int32_t", name: "value"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2910; IR Int32Ty(Int8PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_cvw_singletonEnum_getEnumTag", returnType: "int32_t",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:69; IR VoidTy(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_deallocBox", returnType: "void",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:143; IR VoidTy(RefCountedPtrTy, SizeTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_deallocClassInstance", returnType: "void",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2")]),
        // RuntimeFunctions.def:2142; IR VoidTy(ErrorPtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_deallocError", returnType: "void",
                          parameters: [.init(type: "void *", name: "error"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:126; IR VoidTy(RefCountedPtrTy, SizeTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_deallocObject", returnType: "void",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2")]),
        // RuntimeFunctions.def:151; IR VoidTy(RefCountedPtrTy, TypeMetadataPtrTy, SizeTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_deallocPartialClassInstance", returnType: "void",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2")]),
        // RuntimeFunctions.def:134; IR VoidTy(RefCountedPtrTy, SizeTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_deallocUninitializedObject", returnType: "void",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2")]),
        // RuntimeFunctions.def:2120; IR VoidTy()
        CallSignatureSpec(canonicalName: "swift_deletedMethodError", returnType: "void",
                          parameters: []),
        // RuntimeFunctions.def:1785; IR Int1Ty(OpaquePtrTy, OpaquePtrTy, TypeMetadataPtrTy, TypeMetadataPtrTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_dynamicCast", returnType: "bool",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "void *", name: "value2"), .init(type: "const void *", name: "metadata1"), .init(type: "const void *", name: "metadata2"), .init(type: "size_t", name: "size")]),
        // RuntimeFunctions.def:1693; IR Int8PtrTy(Int8PtrTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_dynamicCastClass", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:1701; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, Int8PtrTy, Int32Ty, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_dynamicCastClassUnconditional", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "void *", name: "pointer3"), .init(type: "int32_t", name: "value1"), .init(type: "int32_t", name: "value2")]),
        // RuntimeFunctions.def:1747; IR TypeMetadataPtrTy(TypeMetadataPtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_dynamicCastMetatype", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "metadata1"), .init(type: "const void *", name: "metadata2")]),
        // RuntimeFunctions.def:1850; IR ObjCPtrTy(TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_dynamicCastMetatypeToObjectConditional", returnType: "id",
                          parameters: [.init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:1841; IR ObjCPtrTy(TypeMetadataPtrTy, Int8PtrTy, Int32Ty, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_dynamicCastMetatypeToObjectUnconditional", returnType: "id",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "void *", name: "pointer"), .init(type: "int32_t", name: "value1"), .init(type: "int32_t", name: "value2")]),
        // RuntimeFunctions.def:1757; IR TypeMetadataPtrTy(TypeMetadataPtrTy, TypeMetadataPtrTy, Int8PtrTy, Int32Ty, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_dynamicCastMetatypeUnconditional", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "metadata1"), .init(type: "const void *", name: "metadata2"), .init(type: "void *", name: "pointer"), .init(type: "int32_t", name: "value1"), .init(type: "int32_t", name: "value2")]),
        // RuntimeFunctions.def:1710; IR Int8PtrTy(Int8PtrTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_dynamicCastObjCClass", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:1766; IR ObjCClassPtrTy(ObjCClassPtrTy, ObjCClassPtrTy)
        CallSignatureSpec(canonicalName: "swift_dynamicCastObjCClassMetatype", returnType: "void *",
                          parameters: [.init(type: "void *", name: "objcClass1"), .init(type: "void *", name: "objcClass2")]),
        // RuntimeFunctions.def:1776; IR ObjCClassPtrTy(ObjCClassPtrTy, ObjCClassPtrTy, Int8PtrTy, Int32Ty, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_dynamicCastObjCClassMetatypeUnconditional", returnType: "void *",
                          parameters: [.init(type: "void *", name: "objcClass1"), .init(type: "void *", name: "objcClass2"), .init(type: "void *", name: "pointer"), .init(type: "int32_t", name: "value1"), .init(type: "int32_t", name: "value2")]),
        // RuntimeFunctions.def:1720; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, Int8PtrTy, Int32Ty, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_dynamicCastObjCClassUnconditional", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "void *", name: "pointer3"), .init(type: "int32_t", name: "value1"), .init(type: "int32_t", name: "value2")]),
        // RuntimeFunctions.def:1832; IR ObjCPtrTy(ObjCPtrTy, SizeTy, Int8PtrPtrTy)
        CallSignatureSpec(canonicalName: "swift_dynamicCastObjCProtocolConditional", returnType: "id",
                          parameters: [.init(type: "id", name: "object"), .init(type: "size_t", name: "size"), .init(type: "void **", name: "pointer")]),
        // RuntimeFunctions.def:1821; IR ObjCPtrTy(ObjCPtrTy, SizeTy, Int8PtrPtrTy, Int8PtrTy, Int32Ty, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_dynamicCastObjCProtocolUnconditional", returnType: "id",
                          parameters: [.init(type: "id", name: "object"), .init(type: "size_t", name: "size"), .init(type: "void **", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "int32_t", name: "value1"), .init(type: "int32_t", name: "value2")]),
        // RuntimeFunctions.def:1809; IR TypeMetadataPtrTy(TypeMetadataPtrTy, SizeTy, Int8PtrPtrTy)
        CallSignatureSpec(canonicalName: "swift_dynamicCastTypeToObjCProtocolConditional", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size"), .init(type: "void **", name: "pointer")]),
        // RuntimeFunctions.def:1797; IR TypeMetadataPtrTy(TypeMetadataPtrTy, SizeTy, Int8PtrPtrTy, Int8PtrTy, Int32Ty, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_dynamicCastTypeToObjCProtocolUnconditional", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size"), .init(type: "void **", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "int32_t", name: "value1"), .init(type: "int32_t", name: "value2")]),
        // RuntimeFunctions.def:1728; IR Int8PtrTy(Int8PtrTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_dynamicCastUnknownClass", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:1738; IR Int8PtrTy(Int8PtrTy, Int8PtrTy, Int8PtrTy, Int32Ty, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_dynamicCastUnknownClassUnconditional", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "void *", name: "pointer3"), .init(type: "int32_t", name: "value1"), .init(type: "int32_t", name: "value2")]),
        // RuntimeFunctions.def:1939; IR VoidTy(PtrTy)
        CallSignatureSpec(canonicalName: "swift_endAccess", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer")]),
        // RuntimeFunctions.def:487; IR VoidTy(ErrorPtrTy)
        CallSignatureSpec(canonicalName: "swift_errorRelease", returnType: "void",
                          parameters: [.init(type: "void *", name: "error")]),
        // RuntimeFunctions.def:478; IR ErrorPtrTy(ErrorPtrTy)
        CallSignatureSpec(canonicalName: "swift_errorRetain", returnType: "void *",
                          parameters: [.init(type: "void *", name: "error")]),
        // RuntimeFunctions.def:1685; IR TypeMetadataPtrTy(OpaquePtrTy, TypeMetadataPtrTy, Int1Ty)
        CallSignatureSpec(canonicalName: "swift_getDynamicType", returnType: "const void *",
                          parameters: [.init(type: "void *", name: "value"), .init(type: "const void *", name: "metadata"), .init(type: "bool", name: "flag")]),
        // RuntimeFunctions.def:1588; IR Int32Ty(OpaquePtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getEnumCaseMultiPayload", returnType: "int32_t",
                          parameters: [.init(type: "void *", name: "value"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:1228; IR TypeMetadataPtrTy(TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getExistentialMetatypeMetadata", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:1351; IR TypeMetadataPtrTy(Int1Ty, TypeMetadataPtrTy, SizeTy, PtrTy)
        CallSignatureSpec(canonicalName: "swift_getExistentialTypeMetadata", returnType: "const void *",
                          parameters: [.init(type: "bool", name: "flag"), .init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size"), .init(type: "void *", name: "pointer")]),
        // RuntimeFunctions.def:1376; IR TypeMetadataPtrTy(Int8PtrTy, Int8PtrPtrTy)
        CallSignatureSpec(canonicalName: "swift_getExtendedExistentialTypeMetadata", returnType: "const void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void **", name: "pointer2")]),
        // RuntimeFunctions.def:1388; IR TypeMetadataPtrTy(Int8PtrTy, Int8PtrPtrTy)
        CallSignatureSpec(canonicalName: "swift_getExtendedExistentialTypeMetadata_unique", returnType: "const void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void **", name: "pointer2")]),
        // RuntimeFunctions.def:1364; IR TypeMetadataPtrTy(Int8PtrTy, Int8PtrPtrTy)
        CallSignatureSpec(canonicalName: "swift_getExtendedExistentialTypeShape", returnType: "const void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void **", name: "pointer2")]),
        // RuntimeFunctions.def:826; IR TypeMetadataPtrTy(SizeTy, SizeTy, PtrTy, PtrTy, TypeMetadataPtrTy, TypeMetadataPtrTy, Int32Ty, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getExtendedFunctionTypeMetadata", returnType: "const void *",
                          parameters: [.init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata1"), .init(type: "const void *", name: "metadata2"), .init(type: "int32_t", name: "value"), .init(type: "const void *", name: "metadata3")]),
        // RuntimeFunctions.def:1954; IR FunctionPtrTy(PtrTy, FunctionPtrTy)
        CallSignatureSpec(canonicalName: "swift_getFunctionReplacement", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "void *", name: "function")]),
        // RuntimeFunctions.def:793; IR TypeMetadataPtrTy(SizeTy, PtrTy, PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getFunctionTypeMetadata", returnType: "const void *",
                          parameters: [.init(type: "size_t", name: "size"), .init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:885; IR TypeMetadataPtrTy(SizeTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getFunctionTypeMetadata0", returnType: "const void *",
                          parameters: [.init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:896; IR TypeMetadataPtrTy(SizeTy, TypeMetadataPtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getFunctionTypeMetadata1", returnType: "const void *",
                          parameters: [.init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata1"), .init(type: "const void *", name: "metadata2")]),
        // RuntimeFunctions.def:908; IR TypeMetadataPtrTy(SizeTy, TypeMetadataPtrTy, TypeMetadataPtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getFunctionTypeMetadata2", returnType: "const void *",
                          parameters: [.init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata1"), .init(type: "const void *", name: "metadata2"), .init(type: "const void *", name: "metadata3")]),
        // RuntimeFunctions.def:921; IR TypeMetadataPtrTy(SizeTy, TypeMetadataPtrTy, TypeMetadataPtrTy, TypeMetadataPtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getFunctionTypeMetadata3", returnType: "const void *",
                          parameters: [.init(type: "size_t", name: "size"), .init(type: "const void *", name: "metadata1"), .init(type: "const void *", name: "metadata2"), .init(type: "const void *", name: "metadata3"), .init(type: "const void *", name: "metadata4")]),
        // RuntimeFunctions.def:808; IR TypeMetadataPtrTy(SizeTy, SizeTy, PtrTy, PtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getFunctionTypeMetadataDifferentiable", returnType: "const void *",
                          parameters: [.init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:849; IR TypeMetadataPtrTy(SizeTy, SizeTy, PtrTy, PtrTy, TypeMetadataPtrTy, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getFunctionTypeMetadataGlobalActor", returnType: "const void *",
                          parameters: [.init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "const void *", name: "metadata1"), .init(type: "const void *", name: "metadata2")]),
        // RuntimeFunctions.def:2214; IR ObjCClassPtrTy(ObjCClassPtrTy)
        CallSignatureSpec(canonicalName: "swift_getInitializedObjCClass", returnType: "void *",
                          parameters: [.init(type: "void *", name: "objcClass")]),
        // RuntimeFunctions.def:2200; IR RefCountedPtrTy(Int8PtrTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_getKeyPath", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:1219; IR TypeMetadataPtrTy(TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getMetatypeMetadata", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:2764; IR Int32Ty(OpaquePtrTy, Int32Ty, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getMultiPayloadEnumTagSinglePayload", returnType: "int32_t",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "int32_t", name: "value2"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:1245; IR ObjCClassPtrTy(TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_getObjCClassFromMetadata", returnType: "void *",
                          parameters: [.init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:1255; IR ObjCClassPtrTy(ObjCPtrTy)
        CallSignatureSpec(canonicalName: "swift_getObjCClassFromObject", returnType: "void *",
                          parameters: [.init(type: "id", name: "object")]),
        // RuntimeFunctions.def:1236; IR TypeMetadataPtrTy(ObjCClassPtrTy)
        CallSignatureSpec(canonicalName: "swift_getObjCClassMetadata", returnType: "const void *",
                          parameters: [.init(type: "void *", name: "objcClass")]),
        // RuntimeFunctions.def:1677; IR TypeMetadataPtrTy(ObjCPtrTy)
        CallSignatureSpec(canonicalName: "swift_getObjectType", returnType: "const void *",
                          parameters: [.init(type: "id", name: "object")]),
        // RuntimeFunctions.def:1946; IR FunctionPtrTy(PtrTy)
        CallSignatureSpec(canonicalName: "swift_getOrigOfReplaceable", returnType: "void *",
                          parameters: [.init(type: "void *", name: "pointer")]),
        // RuntimeFunctions.def:1111; IR WitnessTablePtrTy(ProtocolConformanceDescriptorPtrTy, TypeMetadataPtrTy, WitnessTablePtrPtrTy)
        CallSignatureSpec(canonicalName: "swift_getWitnessTable", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "conformance"), .init(type: "const void *", name: "metadata"), .init(type: "void **", name: "witnessTables")]),
        // RuntimeFunctions.def:1120; IR WitnessTablePtrTy(ProtocolConformanceDescriptorPtrTy, TypeMetadataPtrTy, WitnessTablePtrPtrTy)
        CallSignatureSpec(canonicalName: "swift_getWitnessTableRelative", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "conformance"), .init(type: "const void *", name: "metadata"), .init(type: "void **", name: "witnessTables")]),
        // RuntimeFunctions.def:1412; IR VoidTy(TypeMetadataPtrTy, SizeTy, SizeTy, PtrTy, PtrTy)
        CallSignatureSpec(canonicalName: "swift_initClassMetadata", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:1564; IR VoidTy(TypeMetadataPtrTy, SizeTy, SizeTy, PtrTy)
        CallSignatureSpec(canonicalName: "swift_initEnumMetadataMultiPayload", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "void *", name: "pointer")]),
        // RuntimeFunctions.def:1513; IR VoidTy(TypeMetadataPtrTy, SizeTy, Int8PtrPtrTy)
        CallSignatureSpec(canonicalName: "swift_initEnumMetadataSingleCase", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size"), .init(type: "void **", name: "pointer")]),
        // RuntimeFunctions.def:1538; IR VoidTy(TypeMetadataPtrTy, SizeTy, Int8PtrPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_initEnumMetadataSinglePayload", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size"), .init(type: "void **", name: "pointer"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:3026; IR VoidTy(TypeMetadataPtrTy, SizeTy, PtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_initRawStructMetadata", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size"), .init(type: "void *", name: "pointer"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:3040; IR VoidTy(TypeMetadataPtrTy, SizeTy, PtrTy, SizeTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_initRawStructMetadata2", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size1"), .init(type: "void *", name: "pointer"), .init(type: "size_t", name: "size2"), .init(type: "size_t", name: "size3")]),
        // RuntimeFunctions.def:101; IR RefCountedPtrTy(TypeMetadataPtrTy, RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_initStackObject", returnType: "void *",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:110; IR RefCountedPtrTy(TypeMetadataPtrTy, RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_initStaticObject", returnType: "void *",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:1488; IR VoidTy(TypeMetadataPtrTy, SizeTy, SizeTy, PtrTy, PtrTy)
        CallSignatureSpec(canonicalName: "swift_initStructMetadata", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:1962; IR VoidTy(TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_instantiateObjCClass", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:1877; IR Int1Ty(TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_isClassType", returnType: "bool",
                          parameters: [.init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:379; IR Int1Ty(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_isDeallocating", returnType: "bool",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:702; IR Int1Ty(RefCountedPtrTy, Int8PtrTy, Int32Ty, Int32Ty, Int32Ty, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_isEscapingClosureAtFileLocation", returnType: "bool",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "void *", name: "pointer"), .init(type: "int32_t", name: "value1"), .init(type: "int32_t", name: "value2"), .init(type: "int32_t", name: "value3"), .init(type: "int32_t", name: "value4")]),
        // RuntimeFunctions.def:1886; IR Int1Ty(TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_isOptionalType", returnType: "bool",
                          parameters: [.init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:648; IR Int1Ty(UnknownRefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_isUniquelyReferenced", returnType: "bool",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:618; IR Int1Ty(UnknownRefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_isUniquelyReferencedNonObjC", returnType: "bool",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:628; IR Int1Ty(UnknownRefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_isUniquelyReferencedNonObjC_nonNull", returnType: "bool",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:639; IR Int1Ty(BridgeObjectPtrTy)
        CallSignatureSpec(canonicalName: "swift_isUniquelyReferencedNonObjC_nonNull_bridgeObject", returnType: "bool",
                          parameters: [.init(type: "void *", name: "bridgeObject")]),
        // RuntimeFunctions.def:678; IR Int1Ty(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_isUniquelyReferenced_native", returnType: "bool",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:658; IR Int1Ty(UnknownRefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_isUniquelyReferenced_nonNull", returnType: "bool",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:669; IR Int1Ty(BridgeObjectPtrTy)
        CallSignatureSpec(canonicalName: "swift_isUniquelyReferenced_nonNull_bridgeObject", returnType: "bool",
                          parameters: [.init(type: "void *", name: "bridgeObject")]),
        // RuntimeFunctions.def:688; IR Int1Ty(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_isUniquelyReferenced_nonNull_native", returnType: "bool",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:1475; IR Int8PtrTy(TypeMetadataPtrTy, PtrTy, TypeContextDescriptorPtrTy)
        CallSignatureSpec(canonicalName: "swift_lookUpClassMethod", returnType: "void *",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "void *", name: "pointer"), .init(type: "const void *", name: "descriptor")]),
        // RuntimeFunctions.def:468; IR VoidTy(BridgeObjectPtrTy)
        CallSignatureSpec(canonicalName: "swift_nonatomic_bridgeObjectRelease", returnType: "void",
                          parameters: [.init(type: "void *", name: "bridgeObject")]),
        // RuntimeFunctions.def:344; IR VoidTy(BridgeObjectPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_nonatomic_bridgeObjectRelease_n", returnType: "void",
                          parameters: [.init(type: "void *", name: "bridgeObject"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:458; IR BridgeObjectPtrTy(BridgeObjectPtrTy)
        CallSignatureSpec(canonicalName: "swift_nonatomic_bridgeObjectRetain", returnType: "void *",
                          parameters: [.init(type: "void *", name: "bridgeObject")]),
        // RuntimeFunctions.def:335; IR BridgeObjectPtrTy(BridgeObjectPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_nonatomic_bridgeObjectRetain_n", returnType: "void *",
                          parameters: [.init(type: "void *", name: "bridgeObject"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:362; IR VoidTy(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_nonatomic_release", returnType: "void",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:273; IR VoidTy(RefCountedPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_nonatomic_release_n", returnType: "void",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:353; IR RefCountedPtrTy(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_nonatomic_retain", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:265; IR RefCountedPtrTy(RefCountedPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_nonatomic_retain_n", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:413; IR VoidTy(UnknownRefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_nonatomic_unknownObjectRelease", returnType: "void",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:308; IR VoidTy(RefCountedPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_nonatomic_unknownObjectRelease_n", returnType: "void",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:404; IR UnknownRefCountedPtrTy(UnknownRefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_nonatomic_unknownObjectRetain", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:299; IR RefCountedPtrTy(RefCountedPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_nonatomic_unknownObjectRetain_n", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:2223; IR VoidTy(ObjCPtrTy, ObjCSELTy, Int8PtrTy, SizeTy, SizeTy, SizeTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_objc_swift3ImplicitObjCEntrypoint", returnType: "void",
                          parameters: [.init(type: "id", name: "object"), .init(type: "SEL", name: "selector"), .init(type: "void *", name: "pointer1"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "size_t", name: "size3"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:1896; IR VoidTy(PtrTy, Int8PtrTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_once", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2"), .init(type: "void *", name: "pointer3")]),
        // RuntimeFunctions.def:77; IR OpaquePtrTy(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_projectBox", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:1916; IR VoidTy(RelativeAddressPtrTy, RelativeAddressPtrTy)
        CallSignatureSpec(canonicalName: "swift_registerProtocolConformances", returnType: "void",
                          parameters: [.init(type: "void *", name: "address1"), .init(type: "void *", name: "address2")]),
        // RuntimeFunctions.def:1906; IR VoidTy(ProtocolRecordPtrTy, ProtocolRecordPtrTy)
        CallSignatureSpec(canonicalName: "swift_registerProtocols", returnType: "void",
                          parameters: [.init(type: "const void *", name: "records1"), .init(type: "const void *", name: "records2")]),
        // RuntimeFunctions.def:1923; IR VoidTy(TypeMetadataRecordPtrTy, TypeMetadataRecordPtrTy)
        CallSignatureSpec(canonicalName: "swift_registerTypeMetadataRecords", returnType: "void",
                          parameters: [.init(type: "const void *", name: "records1"), .init(type: "const void *", name: "records2")]),
        // RuntimeFunctions.def:248; IR RefCountedPtrTy(RefCountedPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_release_n", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:1399; IR TypeMetadataPtrTy(TypeContextDescriptorPtrTy, Int8PtrTy)
        CallSignatureSpec(canonicalName: "swift_relocateClassMetadata", returnType: "const void *",
                          parameters: [.init(type: "const void *", name: "descriptor"), .init(type: "void *", name: "pointer")]),
        // RuntimeFunctions.def:240; IR RefCountedPtrTy(RefCountedPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_retain_n", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:256; IR VoidTy(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_setDeallocating", returnType: "void",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:160; IR Int8PtrTy(SizeTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_slowAlloc", returnType: "void *",
                          parameters: [.init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2")]),
        // RuntimeFunctions.def:168; IR VoidTy(Int8PtrTy, SizeTy, SizeTy)
        CallSignatureSpec(canonicalName: "swift_slowDealloc", returnType: "void",
                          parameters: [.init(type: "void *", name: "pointer"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2")]),
        // RuntimeFunctions.def:1632; IR VoidTy(OpaquePtrTy, TypeMetadataPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_storeEnumTagMultiPayload", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "const void *", name: "metadata"), .init(type: "int32_t", name: "value2")]),
        // RuntimeFunctions.def:2778; IR VoidTy(OpaquePtrTy, Int32Ty, Int32Ty, TypeMetadataPtrTy)
        CallSignatureSpec(canonicalName: "swift_storeMultiPayloadEnumTagSinglePayload", returnType: "void",
                          parameters: [.init(type: "void *", name: "value1"), .init(type: "int32_t", name: "value2"), .init(type: "int32_t", name: "value3"), .init(type: "const void *", name: "metadata")]),
        // RuntimeFunctions.def:371; IR RefCountedPtrTy(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_tryRetain", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object")]),
        // RuntimeFunctions.def:290; IR VoidTy(RefCountedPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_unknownObjectRelease_n", returnType: "void",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:281; IR RefCountedPtrTy(RefCountedPtrTy, Int32Ty)
        CallSignatureSpec(canonicalName: "swift_unknownObjectRetain_n", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object"), .init(type: "int32_t", name: "value")]),
        // RuntimeFunctions.def:1425; IR VoidTy(TypeMetadataPtrTy, SizeTy, SizeTy, PtrTy, PtrTy)
        CallSignatureSpec(canonicalName: "swift_updateClassMetadata", returnType: "void",
                          parameters: [.init(type: "const void *", name: "metadata"), .init(type: "size_t", name: "size1"), .init(type: "size_t", name: "size2"), .init(type: "void *", name: "pointer1"), .init(type: "void *", name: "pointer2")]),
        // RuntimeFunctions.def:118; IR VoidTy(RefCountedPtrTy)
        CallSignatureSpec(canonicalName: "swift_verifyEndOfLifetime", returnType: "void",
                          parameters: [.init(type: "void *", name: "object")]),
    ]

    /// `objc_retain_x0`/`objc_release_x0`: ordinary C signatures per objc-abi.h.
    static let objcRegisterHelperX0Specs: [CallSignatureSpec] = [
        CallSignatureSpec(canonicalName: "objc_retain_x0", returnType: "id",
                          parameters: [.init(type: "id", name: "object")]),
        CallSignatureSpec(canonicalName: "objc_release_x0", returnType: "void",
                          parameters: [.init(type: "id", name: "object")]),
    ]

    public struct ObjCRegisterHelper: Sendable, Hashable {
        public enum Operation: String, Sendable { case retain, release }
        public let canonicalName: String
        public let operation: Operation
        /// The general-purpose register holding the object (`xN`).
        public let objectRegister: String
        /// Declared result: `id` for retain (the object), nothing for release.
        public let returnType: String
    }

    /// Registers with an exported helper in libobjc (macOS SDK libobjc.tbd, objc4-951.1):
    /// x0-x15 and x19-x28. x16, x17, x18 and x29 have none.
    public static let objcHelperRegisters: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28]

    public static let objcRegisterHelpers: [ObjCRegisterHelper] = objcHelperRegisters.flatMap { n in
        [
            ObjCRegisterHelper(canonicalName: "objc_retain_x\(n)", operation: .retain,
                               objectRegister: "x\(n)", returnType: "id"),
            ObjCRegisterHelper(canonicalName: "objc_release_x\(n)", operation: .release,
                               objectRegister: "x\(n)", returnType: "void"),
        ]
    }

    private static let helpersByName: [String: ObjCRegisterHelper] =
        Dictionary(uniqueKeysWithValues: objcRegisterHelpers.map { ($0.canonicalName, $0) })

    /// Resolves `_objc_retain_x19`-style call targets (one leading underscore stripped, as in
    /// `CallSignatureCatalog`). Returns nil for every other symbol.
    public static func objcRegisterHelper(for target: String) -> ObjCRegisterHelper? {
        let symbol = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
        return helpersByName[canonical]
    }
}

extension RuntimeSignatureSeeds {
    /// Knowledge-version identity of the generated seeds: the generator version plus the exact
    /// sources named in the file header. Generated from the swift-6.3 runtime, so a slice built by
    /// swift tools outside 6.0–6.3 downgrades what these signatures support.
    static let knowledge = NavigatorKnowledgeDescriptor(
        id: "signatures.swift-runtime-seeds",
        version: "1;swift-6.3-RELEASE@aa782beb23b8bd83bd16fca831532a05dd6cea39;objc4-951.1",
        applicability: NavigatorApplicability(swiftTools: NavigatorVersionRange(minimum: "6.0", maximum: "6.3")),
        onOutOfRange: "downgrade"
    )
}
