import Foundation

/// Walks the Objective-C class structures in a 64-bit Mach-O image
/// (`__objc_classlist` → `class_t` → `class_ro_t`), recovering class names and superclass names.
///
/// Pointer fields are resolved through the supplied chained-fixup maps first — modern arm64e/arm64
/// binaries store fixup *entries* in those fields rather than raw vmaddrs, so reading the raw word
/// would yield garbage. When no fixup covers a location (older non-PIE images), the raw
/// little-endian pointer is read directly. Correctness-over-coverage: a structurally implausible
/// class (no `class_ro_t`, empty name) is skipped rather than guessed.
///
/// DYLD-CACHE images (`cachePointerBase`/`cacheReadBytes` set): pointers use the
/// `DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE` rebase encoding (decoded to `base + (raw & 0x3FFFFFFFF)`),
/// shared strings (class names etc. in `__OBJC_RO`) are fetched on demand via `cacheReadBytes`, and
/// relative-direct method-list selectors are offsets from the shared selector base (`__objc_scoffs`).
/// Covered: class/superclass/protocol/category names, ivars, properties, direct method selectors,
/// preoptimized list-of-lists method lists, and cache method type-encodings.
struct ObjCClassParser {

    /// The minimum a section lookup needs: where a VM range lives in the file.
    struct Section: Hashable, Sendable {
        var address: UInt64
        var fileOffset: UInt64
        var size: UInt64
        var name: String
    }

    var data: Data
    var sections: [Section]
    /// Location vmaddr → resolved in-image target vmaddr (chained-fixup REBASEs).
    var rebaseTargets: [UInt64: UInt64]
    /// Location vmaddr → bound symbol name (chained-fixup BINDs, e.g. an external superclass).
    var bindNames: [UInt64: String]
    /// For a dyld-cache-projected image: the cache base used to decode
    /// `DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE` rebase pointers (`target = base + (raw & 0x3FFFFFFFF)`).
    /// nil for an ordinary on-disk Mach-O, where raw pointer words are used as-is.
    var cachePointerBase: UInt64? = nil
    /// For a dyld-cache-projected image: reads up to `count` bytes at any cache VM address (clamped
    /// to the containing mapping) via the multi-file cache reader. The per-image projection omits the
    /// SHARED regions (class-name/selector strings live in the 123 MB shared `__OBJC_RO`), so a string
    /// or struct outside the projected sections is fetched from the whole cache through this. nil for
    /// an ordinary Mach-O.
    var cacheReadBytes: ((UInt64, Int) -> [UInt8]?)? = nil

    /// `DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE` rebase: the low 34 bits are the runtime offset from the
    /// cache base; the high bits hold auth/next metadata that we ignore (only the target matters).
    private static let cacheRuntimeOffsetMask: UInt64 = 0x3_FFFF_FFFF
    /// `method_list_t` flag `relativeMethodSelectorsAreDirect`: when set (with the small-list flag),
    /// each small `method_t.name` is an UNSIGNED offset from a selector-string base rather than a
    /// field-relative delta. In a dyld cache that base is the shared selector pool (__objc_scoffs[1]).
    private static let relativeSelectorsAreDirectFlag: UInt32 = 0x4000_0000
    /// Bounds total work while walking an UNTRUSTED cache image's ObjC structures (the whole-cache
    /// reader removes the natural file-size bound, so list counts × class counts could otherwise
    /// fan out into billions of reads). Reached only for cache images (`budget != nil`).
    static let cacheParseWorkCap = 5_000_000

    /// A shared, decrementing work budget for an untrusted cache-image ObjC walk. nil for an
    /// ordinary on-disk Mach-O (which is naturally bounded by file size). A class so the single
    /// budget is shared across the immutable parser's `parseClasses()` + `parseCategories()` calls.
    final class ParseBudget {
        private var remaining: Int
        init(_ cap: Int) { remaining = cap }
        /// Returns false once the budget is exhausted; callers then stop emitting/iterating.
        func charge() -> Bool {
            if remaining <= 0 { return false }
            remaining -= 1
            return true
        }
    }
    /// Set (non-nil) only for cache images; bounds the untrusted walk's total work.
    var parseBudget: ParseBudget? = nil
    /// Location vmaddrs a chained fixup covers but that resolve to neither an in-image target
    /// nor an exact bound symbol (an unresolved import, or a bind with a nonzero addend). The
    /// slot holds chain bits, not an address, so resolution abstains instead of reading it raw.
    var abstainedPointerSlots: Set<UInt64> = []
    /// Optional sink for graded read failures: an unreadable method entry skips that method
    /// ("Cannot read method definition"); an unreadable protocol definition abandons the rest of
    /// that protocol list ("Cannot read protocol definition … - abort"). nil = no recording.
    var diagnosticLog: MetadataParseDiagnosticLog? = nil

    // 64-bit ABI field offsets. (`class_t.isa` is at offset 0, i.e. the class address itself.)
    private enum ClassT { static let superclass: UInt64 = 8; static let data: UInt64 = 32 }
    private enum ClassRO {
        static let instanceSize: UInt64 = 8
        static let name: UInt64 = 24
        static let baseMethods: UInt64 = 32
        static let baseProtocols: UInt64 = 40
        static let ivars: UInt64 = 48
        static let baseProperties: UInt64 = 64
    }
    /// Shared `entsize_list_tt` header (method/ivar/property lists): entsize_and_flags@0, count@4.
    private enum EntsizeList { static let count: UInt64 = 4; static let entries: UInt64 = 8 }
    /// 64-bit `category_t` field offsets (name@0, cls@8, then the four member-list pointers).
    private enum CategoryT {
        static let name: UInt64 = 0
        static let cls: UInt64 = 8
        static let instanceMethods: UInt64 = 16
        static let classMethods: UInt64 = 24
        static let protocols: UInt64 = 32
        static let instanceProperties: UInt64 = 40
    }

    private static let maxClasses = 1 << 16
    private static let maxStringLength = 4096
    private static let maxMembersPerList = 1 << 16
    private static let maxMethodSubLists = 512
    private static let maxProtocolsPerClass = 1 << 12
    /// `method_list_t.entsize_and_flags`: high bit marks a relative (small) list; the low 16 bits
    /// are the entry size. A small entry is three int32s (12 bytes); a big entry, three pointers (24).
    private static let smallMethodListFlag: UInt32 = 0x8000_0000
    private static let smallMethodEntrySize: UInt64 = 12
    private static let bigMethodEntrySize: UInt64 = 24
    private static let ivarEntrySize: UInt64 = 32
    private static let propertyEntrySize: UInt64 = 16
    /// `class_t.data` packs FAST flags in its low 3 bits; the `class_ro_t` pointer is the rest. The
    /// same low-bit masking applies to a `class_ro_t` member-list pointer (PointerUnion tag bits).
    private static let fastDataMask: UInt64 = ~UInt64(0x7)

    func parseClasses() -> [ObjCClass] {
        guard let classlist = sections.first(where: { $0.name == "__objc_classlist" }) else { return [] }
        let bytes = [UInt8](data)
        let count = min(Int(classlist.size / 8), Self.maxClasses)
        var classes: [ObjCClass] = []
        for index in 0..<count {
            guard parseBudget?.charge() != false else { break }
            let entryAddress = classlist.address &+ UInt64(index * 8)
            guard let entry = resolvePointer(at: entryAddress, bytes: bytes),
                  let classAddress = entry.target, classAddress != 0 else { continue }
            if let cls = parseClass(at: classAddress, bytes: bytes) { classes.append(cls) }
        }
        return classes
    }

    /// protocol_t's fixed 64-bit prefix: isa, name, inherited protocols, four method
    /// lists, instance properties, size and flags. Never interpret the reserved IMP as code.
    func parseProtocols() -> [ObjCProtocol] {
        guard let section = sections.first(where: { $0.name == "__objc_protolist" }) else { return [] }
        let bytes = [UInt8](data)
        let count = Int(min(section.size / 8, UInt64(Self.maxClasses)))
        var result: [ObjCProtocol] = []
        var seen = Set<UInt64>()
        for index in 0..<count {
            guard parseBudget?.charge() != false else { break }
            let (slot, overflow) = section.address.addingReportingOverflow(UInt64(index) * 8)
            guard !overflow, let address = resolvePointer(at: slot, bytes: bytes)?.target,
                  address != 0, address <= UInt64.max - 72, seen.insert(address).inserted,
                  let size = readUInt32(at: address + 64, bytes: bytes), size >= 72,
                  readUInt32(at: address + 68, bytes: bytes) != nil,
                  let nameAddress = resolvePointer(at: address + 8, bytes: bytes)?.target,
                  let name = cString(at: nameAddress, bytes: bytes), !name.isEmpty else { continue }
            func methodList(_ offset: UInt64, classMethod: Bool) -> [ObjCMethod] {
                methods(fromList: resolvePointer(at: address + offset, bytes: bytes)?.target ?? 0,
                        isClassMethod: classMethod, bytes: bytes).map {
                    var method = $0
                    method.implementation = nil
                    return method
                }
            }
            result.append(ObjCProtocol(
                name: name, address: address,
                adoptedProtocols: protocolNames(fromListAddress: resolvePointer(at: address + 16, bytes: bytes)?.target ?? 0, bytes: bytes),
                requiredMethods: methodList(24, classMethod: false) + methodList(32, classMethod: true),
                optionalMethods: methodList(40, classMethod: false) + methodList(48, classMethod: true),
                properties: propertyList(fromListAddress: resolvePointer(at: address + 56, bytes: bytes)?.target ?? 0, bytes: bytes)
            ))
        }
        return result
    }

    /// Walks `__objc_catlist` → `category_t`, recovering categories (typically on EXTERNAL classes,
    /// since same-image categories are merged into the class at link time). Reuses the class-walk
    /// machinery (method/protocol/property list helpers, bind-resolved target class).
    func parseCategories() -> [ObjCCategory] {
        guard let catlist = sections.first(where: { $0.name == "__objc_catlist" }) else { return [] }
        let bytes = [UInt8](data)
        let count = min(Int(catlist.size / 8), Self.maxClasses)
        var categories: [ObjCCategory] = []
        for index in 0..<count {
            guard parseBudget?.charge() != false else { break }
            let entryAddress = catlist.address &+ UInt64(index * 8)
            guard let entry = resolvePointer(at: entryAddress, bytes: bytes),
                  let categoryAddress = entry.target, categoryAddress != 0 else { continue }
            if let category = parseCategory(at: categoryAddress, bytes: bytes) { categories.append(category) }
        }
        return categories
    }

    private func parseCategory(at categoryAddress: UInt64, bytes: [UInt8]) -> ObjCCategory? {
        guard let nameField = resolvePointer(at: categoryAddress &+ CategoryT.name, bytes: bytes),
              let nameAddress = nameField.target, nameAddress != 0,
              let name = cString(at: nameAddress, bytes: bytes), !name.isEmpty,
              let className = categoryClassName(at: categoryAddress &+ CategoryT.cls, bytes: bytes) else { return nil }
        let protocolsListAddress = resolvePointer(at: categoryAddress &+ CategoryT.protocols, bytes: bytes)?.target ?? 0
        return ObjCCategory(
            name: name,
            className: className,
            classMethods: methods(fromList: memberListAddress(inReadOnly: categoryAddress, at: CategoryT.classMethods, bytes: bytes),
                                  isClassMethod: true, bytes: bytes),
            instanceMethods: methods(fromList: memberListAddress(inReadOnly: categoryAddress, at: CategoryT.instanceMethods, bytes: bytes),
                                     isClassMethod: false, bytes: bytes),
            adoptedProtocols: protocolNames(fromListAddress: protocolsListAddress, bytes: bytes),
            properties: propertyList(fromListAddress: memberListAddress(inReadOnly: categoryAddress, at: CategoryT.instanceProperties, bytes: bytes),
                                     bytes: bytes),
            address: categoryAddress
        )
    }

    /// The category's target class (`category_t.cls`). An external class is a BIND to
    /// `_OBJC_CLASS_$_<name>` (the common case — same-image categories are merged away); an in-image
    /// class is followed through `class_t` → `class_ro_t.name`. Mirrors `superclassName`.
    private func categoryClassName(at fieldAddress: UInt64, bytes: [UInt8]) -> String? {
        guard let field = resolvePointer(at: fieldAddress, bytes: bytes) else { return nil }
        if let bound = field.boundName { return Self.normalizeClassSymbol(bound) }
        guard let target = field.target, target != 0,
              let roAddress = classReadOnlyAddress(ofClassAt: target, bytes: bytes) else { return nil }
        return className(fromReadOnly: roAddress, bytes: bytes)
    }

    // MARK: - Class walk

    private func parseClass(at classAddress: UInt64, bytes: [UInt8]) -> ObjCClass? {
        guard let roAddress = classReadOnlyAddress(ofClassAt: classAddress, bytes: bytes),
              let name = className(fromReadOnly: roAddress, bytes: bytes), !name.isEmpty else { return nil }
        return ObjCClass(
            name: name,
            superclassName: superclassName(ofClassAt: classAddress, bytes: bytes),
            adoptedProtocols: protocols(inReadOnly: roAddress, bytes: bytes),
            classMethods: classMethods(ofClassAt: classAddress, bytes: bytes),
            instanceMethods: methods(inReadOnly: roAddress, isClassMethod: false, bytes: bytes),
            ivars: ivars(inReadOnly: roAddress, bytes: bytes),
            properties: properties(inReadOnly: roAddress, bytes: bytes),
            address: classAddress,
            instanceSize: readUInt32(at: roAddress &+ ClassRO.instanceSize, bytes: bytes).map(UInt64.init)
        )
    }

    // MARK: - Method walk

    /// Instance (`-`) methods come from the class's own `class_ro_t.baseMethods`.
    private func methods(inReadOnly readOnlyAddress: UInt64, isClassMethod: Bool, bytes: [UInt8]) -> [ObjCMethod] {
        methods(fromList: memberListAddress(inReadOnly: readOnlyAddress, at: ClassRO.baseMethods, bytes: bytes),
                isClassMethod: isClassMethod, bytes: bytes)
    }

    /// Class (`+`) methods live in the METACLASS's `class_ro_t.baseMethods`. Reached by a single
    /// `isa` hop (class → metaclass); never recursed further, which alone avoids the isa cycle.
    /// A metaclass that resolves to a BIND (external, e.g. the root metaclass) yields no methods.
    private func classMethods(ofClassAt classAddress: UInt64, bytes: [UInt8]) -> [ObjCMethod] {
        guard let isa = resolvePointer(at: classAddress, bytes: bytes),
              isa.boundName == nil, let metaclassAddress = isa.target, metaclassAddress != 0,
              let metaReadOnly = classReadOnlyAddress(ofClassAt: metaclassAddress, bytes: bytes) else { return [] }
        return methods(inReadOnly: metaReadOnly, isClassMethod: true, bytes: bytes)
    }

    /// Resolves a `class_ro_t` member-list pointer (methods/ivars/properties) and masks the low
    /// PointerUnion tag bits. For ivar/property lists the mask is a no-op (they are plain pointers);
    /// for `baseMethods` it strips the relative-list tag.
    private func memberListAddress(inReadOnly readOnlyAddress: UInt64, at fieldOffset: UInt64, bytes: [UInt8]) -> UInt64 {
        guard let field = resolvePointer(at: readOnlyAddress &+ fieldOffset, bytes: bytes),
              let pointer = field.target else { return 0 }
        return pointer & Self.fastDataMask
    }

    /// Walks a `method_list_t`: relative/small (12-byte int32 triple), absolute/big (24-byte
    /// pointer triple), or a cache-only preoptimized list-of-lists.
    private func methods(
        fromList listAddress: UInt64,
        isClassMethod: Bool,
        bytes: [UInt8],
        allowListOfLists: Bool = true
    ) -> [ObjCMethod] {
        guard listAddress != 0, let entsizeAndFlags = readUInt32(at: listAddress, bytes: bytes) else { return [] }
        if allowListOfLists,
           cachePointerBase != nil,
           UInt64(entsizeAndFlags & 0xFFFC) == 8 {
            return relativeListListMethods(at: listAddress, isClassMethod: isClassMethod, bytes: bytes)
        }

        let isSmall = (entsizeAndFlags & Self.smallMethodListFlag) != 0
        let entrySize = isSmall ? Self.smallMethodEntrySize : Self.bigMethodEntrySize
        // For a dyld-cache image, a small list with `relativeMethodSelectorsAreDirect` (the normal
        // case for cached classes) encodes each `name` as an UNSIGNED offset from the SHARED
        // selector-string base (__objc_scoffs[1]) — NOT a field-relative delta, which would resolve
        // into __text and yield garbage.
        let selectorBase: UInt64? = (isSmall && (entsizeAndFlags & Self.relativeSelectorsAreDirectFlag) != 0)
            ? cacheSelectorStringBase(bytes: bytes)
            : nil
        return entsizeListEntries(at: listAddress, expectedEntrySize: entrySize, bytes: bytes).compactMap { entry in
            let method = isSmall
                ? parseSmallMethod(at: entry, isClassMethod: isClassMethod, selectorBase: selectorBase, bytes: bytes)
                : parseBigMethod(at: entry, isClassMethod: isClassMethod, bytes: bytes)
            // Item-grade failure: one unreadable method entry is skipped; the list continues.
            if method == nil {
                diagnosticLog?.record(.skippedItem, at: entry, "Cannot read method definition at \(Self.hex(entry))")
            }
            return method
        }
    }

    /// Cache preoptimized `relative_list_list_t`: 8-byte entries whose low 16 bits are an image index
    /// and high 48 bits are a signed offset from the entry address to an ordinary method list.
    private func relativeListListMethods(at listAddress: UInt64, isClassMethod: Bool, bytes: [UInt8]) -> [ObjCMethod] {
        guard let rawCount = readUInt32(at: listAddress &+ EntsizeList.count, bytes: bytes) else { return [] }
        let count = min(Int(rawCount), Self.maxMethodSubLists)
        var methods: [ObjCMethod] = []
        for index in 0..<count {
            guard parseBudget?.charge() != false else { break }
            let (stride, mul) = UInt64(index).multipliedReportingOverflow(by: 8)
            let (afterHeader, add1) = listAddress.addingReportingOverflow(EntsizeList.entries)
            let (entryAddress, add2) = afterHeader.addingReportingOverflow(stride)
            if mul || add1 || add2 { break }
            guard let word = readUInt64(at: entryAddress, bytes: bytes) else { continue }
            _ = word & 0xFFFF // imageIndex: not needed for this static multi-file cache reader.
            let rawOffset = word >> 16
            var offset = Int64(rawOffset)
            if (rawOffset & (UInt64(1) << 47)) != 0 { offset -= Int64(1) << 48 }
            let target = entryAddress &+ UInt64(bitPattern: offset)
            // Hard depth bound: a nested entsize-8 target is parsed as a normal list and rejected,
            // rather than recursing through another list-of-lists level.
            methods.append(contentsOf: self.methods(fromList: target, isClassMethod: isClassMethod,
                                                    bytes: bytes, allowListOfLists: false))
        }
        return methods
    }

    /// For a cache image, the shared selector-string base: `__objc_scoffs[1]` (the second uintptr in
    /// the section, a cache-rebase pointer), cache-pointer-decoded. nil for an ordinary Mach-O or
    /// when the section is absent. Cheap (one 8-byte read) — recomputed per relative method list.
    private func cacheSelectorStringBase(bytes: [UInt8]) -> UInt64? {
        guard let base = cachePointerBase,
              let scoffs = sections.first(where: { $0.name == "__objc_scoffs" }), scoffs.size >= 16,
              let raw = readUInt64(at: scoffs.address &+ 8, bytes: bytes), raw != 0 else { return nil }
        return base &+ (raw & Self.cacheRuntimeOffsetMask)
    }

    /// A recovered selector must be a printable, space-free ASCII string (ObjC selectors are
    /// identifiers + `:`). This is the safety net that guarantees a mis-decoded method NEVER surfaces
    /// a control-byte/garbage selector in the class-dump output.
    private static func isPlausibleSelector(_ selector: String) -> Bool {
        !selector.isEmpty && selector.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }

    /// A cache type string is surfaced only when it looks like an ObjC `@encode` string. This is a
    /// garbage backstop; the base choice is validated separately against the live ObjC runtime oracle.
    /// A METHOD encoding always interleaves argument-frame offsets ("v16@0:8" is the minimal form),
    /// so a digit is required — a mis-based offset that lands on a selector string ("thin…Range:")
    /// starts with a valid type byte and is printable, but carries no digits (measured on the
    /// macOS 26 cache, whose method-types base differs from the verified macOS 27 layout).
    private static func isPlausibleTypeEncoding(_ typeEncoding: String) -> Bool {
        guard let first = typeEncoding.utf8.first else { return false }
        let validLeadingBytes = Set("@#:vBcsilqCISLQfdDbj^[{(*?rnNoORVDATt".utf8)
        return ((first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")) || validLeadingBytes.contains(first))
            && typeEncoding.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e }
            && typeEncoding.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 })
    }

    /// Returns the addresses of each entry in an `entsize_list_tt` (methods/ivars/properties),
    /// validating the header's entry size and bounding the walk with overflow-safe addressing.
    /// Methods retain their concrete size/flag contract. Property and ivar lists have no size
    /// flag bits and may append fields to the known prefix; advance by their declared stride.
    private func entsizeListEntries(at listAddress: UInt64, expectedEntrySize: UInt64,
                                   allowsExtendedEntries: Bool = false, bytes: [UInt8]) -> [UInt64] {
        let (countAddress, headerOverflow) = listAddress.addingReportingOverflow(EntsizeList.count)
        guard listAddress != 0, !headerOverflow,
              let entsizeAndFlags = readUInt32(at: listAddress, bytes: bytes),
              let rawCount = readUInt32(at: countAddress, bytes: bytes) else { return [] }
        let entrySize = UInt64(allowsExtendedEntries ? entsizeAndFlags : entsizeAndFlags & 0xFFFC)
        guard allowsExtendedEntries ? entrySize >= expectedEntrySize : entrySize == expectedEntrySize else { return [] }

        let count = min(Int(rawCount), Self.maxMembersPerList)
        if allowsExtendedEntries && entrySize > expectedEntrySize && count > 0 {
            // Do not accept a readable first prefix as proof that an oversized declared list fits.
            // This check uses projected section/file bounds without allocating the declared extent.
            let (entriesSize, mul) = UInt64(count).multipliedReportingOverflow(by: entrySize)
            let (listSize, add) = entriesSize.addingReportingOverflow(EntsizeList.entries)
            guard !mul, !add, sections.contains(where: { section in
                guard listAddress >= section.address else { return false }
                let delta = listAddress - section.address
                guard delta <= section.size, listSize <= section.size - delta else { return false }
                let (offset, overflow) = section.fileOffset.addingReportingOverflow(delta)
                return !overflow && offset <= UInt64(bytes.count) && listSize <= UInt64(bytes.count) - offset
            }) else { return [] }
        }
        var addresses: [UInt64] = []
        for index in 0..<count {
            guard parseBudget?.charge() != false else { break }
            // Overflow-safe entry addressing: a malformed list address/entsize (a fixup target can
            // resolve near UInt64.max) must not trap Swift's checked arithmetic.
            let (stride, mul) = UInt64(index).multipliedReportingOverflow(by: entrySize)
            let (afterHeader, add1) = listAddress.addingReportingOverflow(EntsizeList.entries)
            let (entryAddress, add2) = afterHeader.addingReportingOverflow(stride)
            if mul || add1 || add2 { break }
            addresses.append(entryAddress)
        }
        return addresses
    }

    // MARK: - Ivar / property / protocol walk

    /// Instance variables from `class_ro_t.ivars` (`ivar_t`: offset@0 (pointer to the int32 offset
    /// variable), name@8, type@16, alignment@24, size@28; entsize 32).
    private func ivars(inReadOnly readOnlyAddress: UInt64, bytes: [UInt8]) -> [ObjCIvar] {
        let listAddress = memberListAddress(inReadOnly: readOnlyAddress, at: ClassRO.ivars, bytes: bytes)
        return entsizeListEntries(at: listAddress, expectedEntrySize: Self.ivarEntrySize, allowsExtendedEntries: true, bytes: bytes).compactMap { entry in
            guard let nameField = resolvePointer(at: entry &+ 8, bytes: bytes),
                  let nameAddress = nameField.target, nameAddress != 0,
                  let name = cString(at: nameAddress, bytes: bytes) else { return nil }
            let typeAddress = resolvePointer(at: entry &+ 16, bytes: bytes)?.target
            let typeEncoding = typeAddress.flatMap { $0 == 0 ? nil : cString(at: $0, bytes: bytes) }
            // RX-02a: the static offset (the offset variable's link-time value) and the size.
            let offsetVariable = resolvePointer(at: entry, bytes: bytes)?.target
            let offset = offsetVariable.flatMap { $0 == 0 ? nil : readUInt32(at: $0, bytes: bytes) }.map(UInt64.init)
            let size = readUInt32(at: entry &+ 28, bytes: bytes).flatMap { $0 == 0 ? nil : UInt64($0) }
            return ObjCIvar(name: name, typeEncoding: typeEncoding, offset: offset, size: size)
        }
    }

    /// Declared properties from `class_ro_t.baseProperties` (`property_t`: name@0, attributes@8; entsize 16).
    private func properties(inReadOnly readOnlyAddress: UInt64, bytes: [UInt8]) -> [ObjCProperty] {
        propertyList(fromListAddress: memberListAddress(inReadOnly: readOnlyAddress, at: ClassRO.baseProperties, bytes: bytes),
                     bytes: bytes)
    }

    /// Walks a `property_list_t` (`entsize_list_tt` of `property_t`) at `listAddress` directly —
    /// shared by class `baseProperties` and a category's instanceProperties field.
    private func propertyList(fromListAddress listAddress: UInt64, bytes: [UInt8]) -> [ObjCProperty] {
        return entsizeListEntries(at: listAddress, expectedEntrySize: Self.propertyEntrySize, allowsExtendedEntries: true, bytes: bytes).compactMap { entry in
            guard let nameField = resolvePointer(at: entry, bytes: bytes),
                  let nameAddress = nameField.target, nameAddress != 0,
                  let name = cString(at: nameAddress, bytes: bytes) else { return nil }
            let attributesAddress = resolvePointer(at: entry &+ 8, bytes: bytes)?.target
            let attributes = attributesAddress.flatMap { $0 == 0 ? nil : cString(at: $0, bytes: bytes) } ?? ""
            return ObjCProperty(name: name, attributes: attributes)
        }
    }

    /// Adopted protocol names from `class_ro_t.baseProtocols`. Unlike the member lists this is NOT
    /// an `entsize_list_tt`: `protocol_list_t` is a uintptr `count`@0 followed by `count` 8-byte
    /// pointers to `protocol_t`, whose name is at offset 8. An entry that resolves to a BIND is an
    /// externally-defined protocol — recover its name from the `_OBJC_PROTOCOL_$_…` symbol.
    private func protocols(inReadOnly readOnlyAddress: UInt64, bytes: [UInt8]) -> [String] {
        guard let listField = resolvePointer(at: readOnlyAddress &+ ClassRO.baseProtocols, bytes: bytes),
              let listAddress = listField.target else { return [] }
        return protocolNames(fromListAddress: listAddress, bytes: bytes)
    }

    /// Walks a `protocol_list_t` at `listAddress` directly — shared by class `baseProtocols` and a
    /// category's protocols field (both are the same uintptr-count-then-pointers layout).
    private func protocolNames(fromListAddress listAddress: UInt64, bytes: [UInt8]) -> [String] {
        guard listAddress != 0,
              let rawCount = readUInt64(at: listAddress, bytes: bytes), rawCount > 0 else { return [] }
        let count = Int(min(rawCount, UInt64(Self.maxProtocolsPerClass)))
        var names: [String] = []
        for index in 0..<count {
            guard parseBudget?.charge() != false else { break }
            let (offset, mul) = UInt64(index).multipliedReportingOverflow(by: 8)
            let (afterCount, add1) = listAddress.addingReportingOverflow(8) // entries follow the 8-byte count
            let (slotAddress, add2) = afterCount.addingReportingOverflow(offset)
            if mul || add1 || add2 { break }
            // An abstained slot is an unresolved import, not a damaged definition: skip that one.
            if abstainedPointerSlots.contains(slotAddress) { continue }
            guard let entry = resolvePointer(at: slotAddress, bytes: bytes) else {
                abandonProtocolList(at: slotAddress, remaining: count - index)
                break
            }
            if let bound = entry.boundName { names.append(Self.normalizeProtocolSymbol(bound)); continue }
            guard let protocolAddress = entry.target, protocolAddress != 0 else { continue }
            // List-grade failure: a protocol_t that cannot be read means the list itself is not
            // trustworthy, so the rest of it is abandoned rather than read as more garbage.
            guard let nameField = resolvePointer(at: protocolAddress &+ 8, bytes: bytes),
                  let nameAddress = nameField.target, nameAddress != 0,
                  let name = cString(at: nameAddress, bytes: bytes), !name.isEmpty else {
                abandonProtocolList(at: protocolAddress, remaining: count - index)
                break
            }
            names.append(name)
        }
        return names
    }

    private func abandonProtocolList(at address: UInt64, remaining: Int) {
        diagnosticLog?.record(.abandonedList, at: address,
                              "Cannot read protocol definition at \(Self.hex(address)) - abort (\(remaining) entries abandoned)")
    }

    private static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

    /// Relative/small `method_t`: name/types/imp are signed int32 offsets, each relative to the
    /// address of THAT field. `name` resolves to a selector reference (selref) slot in most images,
    /// occasionally straight to the string; `types` is always a direct cstring. `imp` is not surfaced.
    private func parseSmallMethod(at entryAddress: UInt64, isClassMethod: Bool, selectorBase: UInt64?, bytes: [UInt8]) -> ObjCMethod? {
        guard let nameDelta = readUInt32(at: entryAddress, bytes: bytes),
              let typesDelta = readUInt32(at: entryAddress &+ 4, bytes: bytes) else { return nil }
        let selector: String?
        if let selectorBase {
            // Cache direct selectors: `name` is an UNSIGNED offset from the shared selector base.
            selector = cString(at: selectorBase &+ UInt64(nameDelta), bytes: bytes)
        } else {
            selector = selectorString(fromNameTarget: relativeTarget(fieldAddress: entryAddress, delta: nameDelta), bytes: bytes)
        }
        guard let selector, Self.isPlausibleSelector(selector) else { return nil }
        // For an on-disk method, decode `types` as a signed field-relative pointer. For a cache
        // direct-selector method, the type string is an unsigned offset from the selector string base;
        // this base was verified against the live ObjC runtime oracle in this handoff's RESULT.md.
        let typeEncoding: String?
        let implementation: UInt64?
        if let selectorBase {
            if typesDelta == 0 {
                typeEncoding = nil
            } else if let candidate = cString(at: selectorBase &+ UInt64(typesDelta), bytes: bytes),
                      Self.isPlausibleTypeEncoding(candidate) {
                typeEncoding = candidate
            } else {
                typeEncoding = nil
            }
            implementation = nil
        } else {
            // A zero `types` delta means the field points at itself — i.e. no encoding. Surface nil
            // rather than reading the raw delta bytes back as a (garbage) string.
            typeEncoding = typesDelta == 0
                ? nil
                : cString(at: relativeTarget(fieldAddress: entryAddress &+ 4, delta: typesDelta), bytes: bytes)
            // The IMP is the third relative field (+8); a zero delta (points at itself) means no IMP.
            let impDelta = readUInt32(at: entryAddress &+ 8, bytes: bytes)
            implementation = (impDelta == nil || impDelta == 0)
                ? nil
                : relativeTarget(fieldAddress: entryAddress &+ 8, delta: impDelta!)
        }
        return ObjCMethod(selector: selector, typeEncoding: typeEncoding,
                          isClassMethod: isClassMethod, implementation: implementation)
    }

    /// Absolute/big `method_t`: name (SEL→cstring), types (char*→cstring), imp — each an 8-byte
    /// pointer (fixup-resolved). `name` points straight at the selector string (no selref hop).
    private func parseBigMethod(at entryAddress: UInt64, isClassMethod: Bool, bytes: [UInt8]) -> ObjCMethod? {
        guard let nameField = resolvePointer(at: entryAddress, bytes: bytes),
              let nameAddress = nameField.target, nameAddress != 0,
              let selector = cString(at: nameAddress, bytes: bytes), Self.isPlausibleSelector(selector) else { return nil }
        let typesAddress = resolvePointer(at: entryAddress &+ 8, bytes: bytes)?.target
        let typeEncoding = typesAddress.flatMap { cString(at: $0, bytes: bytes) }
        // The IMP is the third 8-byte pointer (+16), fixup-resolved (arm64e auth pointers included).
        let impField = resolvePointer(at: entryAddress &+ 16, bytes: bytes)
        let implementation = impField?.boundName == nil ? impField?.target.flatMap { $0 == 0 ? nil : $0 } : nil
        return ObjCMethod(selector: selector, typeEncoding: typeEncoding,
                          isClassMethod: isClassMethod, implementation: implementation)
    }

    /// `fieldAddress + sign_extend(int32)` — the relative-pointer rule. Sign extension is mandatory:
    /// offsets routinely point backward (into __TEXT below the list).
    private func relativeTarget(fieldAddress: UInt64, delta: UInt32) -> UInt64 {
        UInt64(bitPattern: Int64(bitPattern: fieldAddress) &+ Int64(Int32(bitPattern: delta)))
    }

    /// Ordinary compact methods point to a selector pointer slot; that slot need not reside in
    /// `__objc_selrefs`. Resolve it through the same fixup authority as other pointer fields.
    /// Retain direct-string compatibility only when indirection cannot recover a valid selector.
    private func selectorString(fromNameTarget nameTarget: UInt64, bytes: [UInt8]) -> String? {
        if let slot = resolvePointer(at: nameTarget, bytes: bytes),
           let stringAddress = slot.target, stringAddress != 0,
           let selector = cString(at: stringAddress, bytes: bytes), Self.isPlausibleSelector(selector) {
            return selector
        }
        // A known pointer slot must never become a string when its fixup is unresolved or absent.
        guard !isSelectorReference(nameTarget), rebaseTargets[nameTarget] == nil,
              bindNames[nameTarget] == nil, !abstainedPointerSlots.contains(nameTarget) else { return nil }
        return cString(at: nameTarget, bytes: bytes)
    }

    private func isSelectorReference(_ vmaddr: UInt64) -> Bool {
        // `vmaddr - address < size` (not `vmaddr < address + size`): `vmaddr` is attacker-controlled
        // (a relative name target), and `address + size` from a raw header would trap on overflow.
        sections.contains { $0.name == "__objc_selrefs" && vmaddr >= $0.address && vmaddr - $0.address < $0.size }
    }

    /// Reads `count` (≤8) little-endian bytes at `vmaddr` as a `UInt64` — from the projected image's
    /// local sections (NO intermediate allocation; the hot on-disk path) or, for a cache image, from
    /// the whole cache via `cacheReadBytes`. Returns nil when neither covers it or fewer than `count`
    /// bytes are available.
    private func leScalar(_ count: Int, at vmaddr: UInt64, bytes localBytes: [UInt8]) -> UInt64? {
        if let offset = fileOffset(of: vmaddr), offset >= 0, count <= localBytes.count, offset <= localBytes.count - count {
            var value: UInt64 = 0
            for i in 0..<count { value |= UInt64(localBytes[offset + i]) << (8 * i) }
            return value
        }
        if let cacheReadBytes {
            guard parseBudget?.charge() != false else { return nil }
            if let chunk = cacheReadBytes(vmaddr, count), chunk.count >= count {
                var value: UInt64 = 0
                for i in 0..<count { value |= UInt64(chunk[i]) << (8 * i) }
                return value
            }
        }
        return nil
    }

    private func readUInt32(at vmaddr: UInt64, bytes: [UInt8]) -> UInt32? {
        leScalar(4, at: vmaddr, bytes: bytes).map { UInt32(truncatingIfNeeded: $0) }
    }

    /// Reads a raw little-endian 64-bit scalar (e.g. a `protocol_list_t` count) — NOT a pointer, so
    /// it bypasses the fixup maps and the cache-pointer decode.
    private func readUInt64(at vmaddr: UInt64, bytes: [UInt8]) -> UInt64? {
        leScalar(8, at: vmaddr, bytes: bytes)
    }

    private func superclassName(ofClassAt classAddress: UInt64, bytes: [UInt8]) -> String? {
        guard let field = resolvePointer(at: classAddress &+ ClassT.superclass, bytes: bytes) else { return nil }
        if let bound = field.boundName { return Self.normalizeClassSymbol(bound) }
        guard let target = field.target, target != 0 else { return nil } // null superclass → root class
        guard let roAddress = classReadOnlyAddress(ofClassAt: target, bytes: bytes) else { return nil }
        return className(fromReadOnly: roAddress, bytes: bytes)
    }

    /// Resolves `class_t.data` and masks off the FAST flag bits to yield the `class_ro_t` vmaddr.
    private func classReadOnlyAddress(ofClassAt classAddress: UInt64, bytes: [UInt8]) -> UInt64? {
        guard let field = resolvePointer(at: classAddress &+ ClassT.data, bytes: bytes),
              let bits = field.target, bits != 0 else { return nil }
        return bits & Self.fastDataMask
    }

    private func className(fromReadOnly readOnlyAddress: UInt64, bytes: [UInt8]) -> String? {
        guard let field = resolvePointer(at: readOnlyAddress &+ ClassRO.name, bytes: bytes),
              let namePointer = field.target, namePointer != 0 else { return nil }
        return cString(at: namePointer, bytes: bytes)
    }

    // MARK: - Pointer + string + offset resolution

    private struct ResolvedPointer { var target: UInt64?; var boundName: String? }

    private func resolvePointer(at vmaddr: UInt64, bytes: [UInt8]) -> ResolvedPointer? {
        if let target = rebaseTargets[vmaddr] { return ResolvedPointer(target: target, boundName: nil) }
        if let name = bindNames[vmaddr] { return ResolvedPointer(target: nil, boundName: name) }
        if abstainedPointerSlots.contains(vmaddr) { return nil }
        guard let value = leScalar(8, at: vmaddr, bytes: bytes) else { return nil }
        if let base = cachePointerBase {
            // DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE rebase: target = base + low-34-bit runtime offset.
            // Preserve a genuine null (e.g. a root class's null superclass) rather than mapping it to
            // the cache base.
            let target = value == 0 ? 0 : base &+ (value & Self.cacheRuntimeOffsetMask)
            return ResolvedPointer(target: target, boundName: nil)
        }
        return ResolvedPointer(target: value, boundName: nil)
    }

    private func cString(at vmaddr: UInt64, bytes localBytes: [UInt8]) -> String? {
        // Local sections first (the common path + every ordinary Mach-O).
        if let start = fileOffset(of: vmaddr), start >= 0, start < localBytes.count {
            var scalars: [UInt8] = []
            var offset = start
            while offset < localBytes.count, localBytes[offset] != 0, scalars.count < Self.maxStringLength {
                scalars.append(localBytes[offset]); offset += 1
            }
            return scalars.isEmpty ? nil : String(decoding: scalars, as: UTF8.self)
        }
        // Cache image: the string lives in a shared region (e.g. __OBJC_RO) not projected locally.
        if let cacheReadBytes {
            guard parseBudget?.charge() != false else { return nil }
            if let chunk = cacheReadBytes(vmaddr, Self.maxStringLength) {
                var scalars: [UInt8] = []
                for byte in chunk { if byte == 0 { break }; scalars.append(byte) }
                return scalars.isEmpty ? nil : String(decoding: scalars, as: UTF8.self)
            }
        }
        return nil
    }

    private func fileOffset(of vmaddr: UInt64) -> Int? {
        for section in sections {
            guard vmaddr >= section.address else { continue }
            let delta = vmaddr - section.address            // safe: vmaddr >= section.address
            guard delta < section.size else { continue }     // avoids a trapping `address + size`
            let (resolved, overflow) = section.fileOffset.addingReportingOverflow(delta)
            guard !overflow, resolved <= UInt64(Int.max) else { return nil }
            return Int(resolved)
        }
        return nil
    }

    static func normalizeClassSymbol(_ symbol: String) -> String {
        for prefix in ["_OBJC_CLASS_$_", "_OBJC_METACLASS_$_", ".objc_class_name_"] where symbol.hasPrefix(prefix) {
            return String(symbol.dropFirst(prefix.count))
        }
        return symbol
    }

    static func normalizeProtocolSymbol(_ symbol: String) -> String {
        let prefix = "_OBJC_PROTOCOL_$_"
        return symbol.hasPrefix(prefix) ? String(symbol.dropFirst(prefix.count)) : symbol
    }
}
