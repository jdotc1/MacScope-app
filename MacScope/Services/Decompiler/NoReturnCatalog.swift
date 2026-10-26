import Foundation

/// Functions that never return to their caller, for function discovery (no fall-through
/// after a call) and decompilation (no code after the call).
///
/// Data and lookup only: discovery wiring consumes this catalog (HOP-1). Every entry carries
/// its provenance; consumers that require header-confirmed knowledge can ignore
/// `.extendedReference` entries. Deliberately absent: `objc_enumerationMutation` (not declared
/// noreturn; a custom mutation handler may return), `abort_with_reason`/`abort_with_payload`
/// (no public SDK declaration), and throwing `Never` functions (they can exit by throwing).
public enum NoReturnCatalog {
    public enum Family: String, Sendable, CaseIterable {
        case cLibrary, dispatchXPC, objcRuntime, cxxRuntime, swiftRuntime, swiftStdlib, extendedReference
    }

    public enum Provenance: String, Sendable, CaseIterable {
        /// Declared `__dead2`/`noreturn` (or an SDK `*_NORETURN` macro) in the macOS SDK headers.
        case appleSDKHeader
        /// Declared `SWIFT_NORETURN`/`[[noreturn]]` in the open-source Swift runtime headers.
        case swiftRuntimeHeader
        /// Exported by libswiftCore with a demangled return type of `Swift.Never`.
        case swiftCoreNeverExport
        /// Extended reference list; not confirmed against a header.
        case extendedReference
    }

    public struct Entry: Sendable, Hashable {
        /// Undecorated name: leading underscores removed (`__exit` -> `exit`, `_$ss…` -> `$ss…`).
        public let canonicalName: String
        public let family: Family
        public let provenance: Provenance

        init(_ canonicalName: String, _ family: Family, _ provenance: Provenance) {
            self.canonicalName = canonicalName
            self.family = family
            self.provenance = provenance
        }
    }

    public static let entries: [Entry] = [
        // C library: declared __dead2 / noreturn in the macOS SDK headers.
        .init("Exit", .cLibrary, .appleSDKHeader),
        .init("assert_rtn", .cLibrary, .appleSDKHeader),
        .init("eprintf", .cLibrary, .appleSDKHeader),
        .init("exit", .cLibrary, .appleSDKHeader),
        .init("longjmp", .cLibrary, .appleSDKHeader),
        .init("abort", .cLibrary, .appleSDKHeader),
        .init("err", .cLibrary, .appleSDKHeader),
        .init("errc", .cLibrary, .appleSDKHeader),
        .init("errx", .cLibrary, .appleSDKHeader),
        .init("pthread_exit", .cLibrary, .appleSDKHeader),
        .init("quick_exit", .cLibrary, .appleSDKHeader),
        .init("siglongjmp", .cLibrary, .appleSDKHeader),
        .init("verr", .cLibrary, .appleSDKHeader),
        .init("verrc", .cLibrary, .appleSDKHeader),
        .init("verrx", .cLibrary, .appleSDKHeader),
        // libdispatch / XPC: DISPATCH_NORETURN / XPC_NORETURN.
        .init("dispatch_main", .dispatchXPC, .appleSDKHeader),
        .init("xpc_main", .dispatchXPC, .appleSDKHeader),
        // Objective-C runtime: OBJC_NORETURN in <objc/objc-exception.h>.
        .init("objc_exception_throw", .objcRuntime, .appleSDKHeader),
        .init("objc_exception_rethrow", .objcRuntime, .appleSDKHeader),
        .init("objc_terminate", .objcRuntime, .appleSDKHeader),
        // C++ ABI: noreturn in <cxxabi.h>; std::terminate in <__exception/terminate.h>.
        .init("cxa_throw", .cxxRuntime, .appleSDKHeader),
        .init("cxa_rethrow", .cxxRuntime, .appleSDKHeader),
        .init("cxa_bad_cast", .cxxRuntime, .appleSDKHeader),
        .init("cxa_bad_typeid", .cxxRuntime, .appleSDKHeader),
        .init("cxa_call_terminate", .cxxRuntime, .appleSDKHeader),
        .init("cxa_deleted_virtual", .cxxRuntime, .appleSDKHeader),
        .init("cxa_pure_virtual", .cxxRuntime, .appleSDKHeader),
        .init("cxa_throw_bad_array_new_length", .cxxRuntime, .appleSDKHeader),
        .init("ZSt9terminatev", .cxxRuntime, .appleSDKHeader),
        // Swift runtime: SWIFT_NORETURN / [[noreturn]] in swiftlang/swift swift-6.3-RELEASE
        // include/swift/Runtime/{Error.h,Concurrency.h}; each is exported by the macOS SDK .tbd.
        .init("swift_unexpectedError", .swiftRuntime, .swiftRuntimeHeader),
        .init("swift_errorInMain", .swiftRuntime, .swiftRuntimeHeader),
        .init("swift_task_asyncMainDrainQueue", .swiftRuntime, .swiftRuntimeHeader),
        // Swift standard library: every non-throwing libswiftCore export whose demangled
        // signature returns Swift.Never (MacOSX SDK libswiftCore.tbd, Xcode Swift 6.4).
        // static (extension in Swift):Swift.Sequence< where A.Element == Swift.String>.+ infix(Swift.String, A) -> Swift.Never
        .init("$sSTsSS7ElementRtzrlE1poiys5NeverOSS_xtFZ", .swiftStdlib, .swiftCoreNeverExport),
        // static (extension in Swift):Swift.Sequence< where A.Element == Swift.String>.+ infix(A, Swift.String) -> Swift.Never
        .init("$sSTsSS7ElementRtzrlE1poiys5NeverOx_SStFZ", .swiftStdlib, .swiftCoreNeverExport),
        // Swift.fatalError(_: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> Swift.Never
        .init("$ss10fatalError_4file4lines5NeverOSSyXK_s12StaticStringVSutF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._assertionFailure(_: Swift.StaticString, _: Swift.StaticString, file: Swift.StaticString, line: Swift.UInt, flags: Swift.UInt32) -> Swift.Never
        .init("$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._assertionFailure(_: Swift.StaticString, _: Swift.String, file: Swift.StaticString, line: Swift.UInt, flags: Swift.UInt32) -> Swift.Never
        .init("$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_SSAHSus6UInt32VtF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._assertionFailure(_: Swift.StaticString, _: Swift.String, flags: Swift.UInt32) -> Swift.Never
        .init("$ss17_assertionFailure__5flagss5NeverOs12StaticStringV_SSs6UInt32VtF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._fatalErrorMessage(_: Swift.StaticString, _: Swift.StaticString, file: Swift.StaticString, line: Swift.UInt, flags: Swift.UInt32) -> Swift.Never
        .init("$ss18_fatalErrorMessage__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift.preconditionFailure(_: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> Swift.Never
        .init("$ss19preconditionFailure_4file4lines5NeverOSSyXK_s12StaticStringVSutF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._preconditionFailure(_: Swift.StaticString, file: Swift.StaticString, line: Swift.UInt) -> Swift.Never
        .init("$ss20_preconditionFailure_4file4lines5NeverOs12StaticStringV_AGSutF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift.unimplemented_utf8_32bit(_: Swift.String, file: Swift.StaticString, line: Swift.UInt) -> Swift.Never
        .init("$ss24unimplemented_utf8_32bit_4file4lines5NeverOSS_s12StaticStringVSutF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._conditionallyUnreachable() -> Swift.Never
        .init("$ss25_conditionallyUnreachables5NeverOyF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._debugPreconditionFailure(_: Swift.StaticString, file: Swift.StaticString, line: Swift.UInt) -> Swift.Never
        .init("$ss25_debugPreconditionFailure_4file4lines5NeverOs12StaticStringV_AGSutF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._internalInvariantFailure(_: Swift.StaticString, file: Swift.StaticString, line: Swift.UInt) -> Swift.Never
        .init("$ss25_internalInvariantFailure_4file4lines5NeverOs12StaticStringV_AGSutF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._unimplementedInitializer(className: Swift.StaticString, initName: Swift.StaticString, file: Swift.StaticString, line: Swift.UInt, column: Swift.UInt) -> Swift.Never
        .init("$ss25_unimplementedInitializer9className04initD04file4line6columns5NeverOs12StaticStringV_A2JS2utF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._diagnoseUnexpectedEnumCase<A>(type: A.Type) -> Swift.Never
        .init("$ss27_diagnoseUnexpectedEnumCase4types5NeverOxm_tlF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._diagnoseUnavailableCodeReached() -> Swift.Never
        .init("$ss31_diagnoseUnavailableCodeReacheds5NeverOyF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._diagnoseUnexpectedEnumCaseValue<A, B>(type: A.Type, rawValue: B) -> Swift.Never
        .init("$ss32_diagnoseUnexpectedEnumCaseValue4type03rawE0s5NeverOxm_q_tr0_lF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift.ELEMENT_TYPE_OF_SET_VIOLATES_HASHABLE_REQUIREMENTS(Any.Type) -> Swift.Never
        .init("$ss50ELEMENT_TYPE_OF_SET_VIOLATES_HASHABLE_REQUIREMENTSys5NeverOypXpF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift.KEY_TYPE_OF_DICTIONARY_VIOLATES_HASHABLE_REQUIREMENTS(Any.Type) -> Swift.Never
        .init("$ss53KEY_TYPE_OF_DICTIONARY_VIOLATES_HASHABLE_REQUIREMENTSys5NeverOypXpF", .swiftStdlib, .swiftCoreNeverExport),
        // Swift._abstract(file: Swift.StaticString, line: Swift.UInt) -> Swift.Never
        .init("$ss9_abstract4file4lines5NeverOs12StaticStringV_SutF", .swiftStdlib, .swiftCoreNeverExport),
        // Reference only: in the extended reference list but not confirmed by an Apple or
        // Swift header (Windows/MSVC/VB entries excluded).
        .init("stack_chk_fail", .extendedReference, .extendedReference),
        .init("stack_chk_fail_local", .extendedReference, .extendedReference),
        .init("stack_smash_handler", .extendedReference, .extendedReference),
        .init("xexit", .extendedReference, .extendedReference),
        .init("assert_func", .extendedReference, .extendedReference),
        .init("assert_fail", .extendedReference, .extendedReference),
        .init("Unwind_Resume", .extendedReference, .extendedReference),
        .init("Unwind_SjLj_Resume", .extendedReference, .extendedReference),
        .init("Unwind_Resume_or_Rethrow", .extendedReference, .extendedReference),
        .init("Unwind_SjLj_Resume_or_Rethrow", .extendedReference, .extendedReference),
        .init("panic", .extendedReference, .extendedReference),
        .init("longjmp_chk", .extendedReference, .extendedReference),
        .init("longjmperror", .extendedReference, .extendedReference),
        .init("cxa_end_cleanup", .extendedReference, .extendedReference),
        .init("cxa_call_unexpected", .extendedReference, .extendedReference),
        .init("libc_fatal", .extendedReference, .extendedReference),
        .init("ZSt10unexpectedv", .extendedReference, .extendedReference),
        .init("DVTAssertionFailureHandler", .extendedReference, .extendedReference),
        .init("android_log_assert", .extendedReference, .extendedReference),
    ]

    private static let entriesByName: [String: Entry] = {
        var map: [String: Entry] = [:]
        for entry in entries where map[entry.canonicalName] == nil {
            map[entry.canonicalName] = entry
        }
        return map
    }()

    /// Import-stub and pointer prefixes stripped before matching, longest first.
    static let importPrefixes = [
        "imp___la_symbol_ptr_", "imp___nl_symbol_ptr_", "imp___stubs_", "imp___got_",
        "__imp_", "j_",
    ]

    /// Reduces a symbol as it appears in a binary or listing to its catalog key: strips an
    /// import-stub prefix, a `@PLT`-style suffix and all leading underscores.
    public static func canonicalName(for symbol: String) -> String {
        var name = Substring(symbol.trimmingCharacters(in: .whitespaces))
        for prefix in importPrefixes where name.hasPrefix(prefix) {
            name = name.dropFirst(prefix.count)
            break
        }
        if let at = name.firstIndex(of: "@") {
            name = name[..<at]
        }
        while name.first == "_" {
            name = name.dropFirst()
        }
        return String(name)
    }

    public static func entry(for symbol: String) -> Entry? {
        entriesByName[canonicalName(for: symbol)]
    }

    /// True when `symbol` names a function known never to return. Pass
    /// `includingExtendedReference: false` to accept header-confirmed entries only.
    public static func isNoReturn(_ symbol: String, includingExtendedReference: Bool = true) -> Bool {
        guard let entry = entry(for: symbol) else { return false }
        return includingExtendedReference || entry.provenance != .extendedReference
    }
}

extension NoReturnCatalog {
    /// Knowledge-version identity of the no-return list. Bump `version` whenever an entry changes.
    static let knowledge = NavigatorKnowledgeDescriptor(
        id: "analysis.no-return-catalog",
        version: "1",
        applicability: .any
    )
}
