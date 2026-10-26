import Foundation

/// A recovered Objective-C method (`-` instance or `+` class). `typeEncoding` is the runtime
/// method type-encoding string (return type, then self/SEL, then argument types); nil when the
/// binary did not carry it.
struct ObjCMethod: Hashable, Codable, Sendable {
    var selector: String
    var typeEncoding: String?
    var isClassMethod: Bool
    /// The method implementation (IMP) virtual address — the function body this selector dispatches
    /// to. nil when the binary did not carry it (e.g. an external/bound method). Used to seed
    /// function discovery: an IMP is a guaranteed entry point even when no static call targets it.
    var implementation: UInt64?

    init(selector: String, typeEncoding: String?, isClassMethod: Bool, implementation: UInt64? = nil) {
        self.selector = selector
        self.typeEncoding = typeEncoding
        self.isClassMethod = isClassMethod
        self.implementation = implementation
    }
}

/// A recovered instance variable. `typeEncoding` is the runtime type encoding (e.g. `@"NSString"`).
struct ObjCIvar: Hashable, Codable, Sendable {
    var name: String
    var typeEncoding: String?
    /// RX-02a: the static byte offset read through `ivar_t.offset` (the offset variable's
    /// link-time value; the non-fragile runtime may slide it). nil when the slot did not resolve.
    var offset: UInt64? = nil
    /// RX-02a: `ivar_t.size` in bytes; nil when absent (zero).
    var size: UInt64? = nil
}

/// A recovered declared property. `attributes` is the raw runtime attribute string
/// (e.g. `T@"NSString",&,N,V_title`).
struct ObjCProperty: Hashable, Codable, Sendable {
    var name: String
    var attributes: String
}

/// A recovered Objective-C class with the members needed to emit an `@interface`.
struct ObjCClass: Hashable, Codable, Sendable {
    var name: String
    var superclassName: String?
    var adoptedProtocols: [String]
    var classMethods: [ObjCMethod]
    var instanceMethods: [ObjCMethod]
    var ivars: [ObjCIvar]
    var properties: [ObjCProperty]
    /// RX-02a: the `class_t` virtual address this class was read from (its stable identity in
    /// the image). nil for a hand-built or older-build value.
    var address: UInt64? = nil
    /// RX-02a: `class_ro_t.instanceSize`. nil when unread.
    var instanceSize: UInt64? = nil
}

/// A recovered Objective-C category (`@interface Class (Name)`), from `__objc_catlist`. Categories on
/// a same-image class are merged into the class at link time, so these are typically categories on an
/// EXTERNAL class (e.g. extending NSString). `className` is the target class the category extends.
struct ObjCCategory: Hashable, Codable, Sendable {
    var name: String
    var className: String
    var classMethods: [ObjCMethod]
    var instanceMethods: [ObjCMethod]
    var adoptedProtocols: [String]
    var properties: [ObjCProperty]
    /// RX-02a: the `category_t` virtual address. nil for a hand-built or older-build value.
    var address: UInt64? = nil
}

/// RX-02a: what one `__objc_classrefs` slot names: the class's `class_t` address when the slot
/// is an in-image rebase, and its name when the loader resolved one (a bound import such as
/// `_OBJC_CLASS_$_NSObject`, or an in-image class symbol). At least one is non-nil.
struct ObjCClassReferenceTarget: Hashable, Codable, Sendable {
    var name: String?
    var classAddress: UInt64?

    /// The slot → target map a loader projects from the parsed `__objc_classrefs` references.
    /// A reference with neither an in-image target nor a name is dropped.
    static func projection(of references: [MachOObjectiveCReference]) -> [UInt64: ObjCClassReferenceTarget] {
        var result: [UInt64: ObjCClassReferenceTarget] = [:]
        for reference in references {
            let name = reference.resolvedName.flatMap { $0.isEmpty ? nil : $0 }
            let address = reference.targetAddress == 0 ? nil : reference.targetAddress
            guard name != nil || address != nil else { continue }
            result[reference.sourceAddress] = ObjCClassReferenceTarget(name: name, classAddress: address)
        }
        return result
    }
}

/// A compiler-emitted protocol object, including protocols never adopted by a local class.
struct ObjCProtocol: Hashable, Codable, Sendable {
    var name: String
    var address: UInt64
    var adoptedProtocols: [String]
    var requiredMethods: [ObjCMethod]
    var optionalMethods: [ObjCMethod]
    var properties: [ObjCProperty]
}
