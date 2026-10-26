import Foundation

/// HOP-5: the on-disk format and loader for the offline-generated SDK call-signature pack.
///
/// The pack is produced OFFLINE by `Scripts/signatures/generate_sdk_signature_pack.py` (nothing
/// here parses headers), ships as the `SDKCallSignaturePack.json` resource of the app and the
/// analysis worker, and is consumed as data. Format, version 1 (UTF-8 JSON, one object):
///
/// ```json
/// { "format": "macscope.call-signature-pack", "formatVersion": 1,
///   "generator": { "tool": "…", "sdk": "MacOSX27.2.sdk" },
///   "entries": [ { "name": "write", "returns": "ssize_t",
///                  "params": [ { "type": "int", "name": "fd" }, … ],
///                  "variadic": false, "noReturn": false } ] }
/// ```
///
/// `name` is the undecorated C name (no leading `_`), the same key `CallSignatureCatalog` uses.
/// Optional, additive fields (absent in older packs; still format version 1): `generator.sdkVersion`;
/// per entry `format` (`{kind, formatIndex, firstArgIndex}`, 1-based as declared by the header's
/// `format` attribute, consumed by HOP-5c format-string variadic recovery in `MacIRBuilder`),
/// `callingConvention` (`c`, `c-variadic-stack`, `objc-dispatch`) and `family` (header family).
/// `noReturn` feeds HOP-1 discovery at provenance `sdkPack`, after `NoReturnCatalog`.
/// `variadic` is only the header's `...` flag; the format attribute is what lets a call site
/// recover its anonymous arguments (HOP-5c). Pack entries are appended AFTER the seeds, corpus
/// and runtime seeds, so a pack can add
/// signatures but never shadow a hand-verified one.
struct CallSignaturePack: Equatable, Sendable {
    static let formatIdentifier = "macscope.call-signature-pack"
    static let supportedFormatVersion = 1
    static let maximumBytes = 64 * 1_024 * 1_024
    static let maximumEntries = 200_000
    static let maximumParameters = 64

    struct Entry: Codable, Equatable, Sendable {
        struct Param: Codable, Equatable, Sendable {
            var type: String
            var name: String
            var sourceType: String? = nil
            var abiType: String? = nil
            var ownership: [String]? = nil
        }
        struct Format: Codable, Equatable, Sendable {
            /// The `format` attribute's archetype as clang prints it (`printf`, `NSString`, …).
            var kind: String
            /// 1-based index of the format-string parameter.
            var formatIndex: Int
            /// 1-based index of the first variadic argument (0 for a `va_list` consumer).
            var firstArgIndex: Int
        }
        var name: String
        var returns: String
        var params: [Param]
        var variadic: Bool
        var noReturn: Bool
        var format: Format? = nil
        var callingConvention: String? = nil
        var family: String? = nil
        // HOP-5d: original SDK spelling and semantic annotation evidence. ABI spellings
        // are compiler-resolved scalars; opaque pointer spellings remain intact.
        var sourceReturns: String? = nil
        var abiReturns: String? = nil
        var ownership: [String]? = nil
        var availability: [String]? = nil
        var headers: [String]? = nil

        var spec: CallSignatureSpec {
            CallSignatureSpec(canonicalName: name, returnType: abiReturns ?? returns,
                              parameters: params.map { .init(type: $0.abiType ?? $0.type, name: $0.name) },
                              isVariadic: variadic,
                              format: format.map {
                                  CallFormatAttribute(kind: $0.kind, formatIndex: $0.formatIndex,
                                                      firstArgIndex: $0.firstArgIndex)
                              })
        }
    }

    struct Generator: Codable, Equatable, Sendable {
        var tool: String
        var sdk: String
        var sdkVersion: String? = nil
        var provenanceManifest: String? = nil
    }

    enum LoadError: Error, Equatable {
        case tooLarge
        case malformed
        case unsupportedFormat(String, version: Int)
        case invalidEntry(index: Int)
        case duplicateEntry(String)
    }

    var generator: Generator
    var entries: [Entry]

    /// Every entry as a catalog spec, in pack order.
    var specs: [CallSignatureSpec] { entries.map(\.spec) }
    /// Names the pack marks as never returning, as written in the pack.
    var noReturnNames: Set<String> { Set(entries.filter(\.noReturn).map(\.name)) }
    /// The same names reduced to `NoReturnCatalog.canonicalName` keys (all leading `_` removed),
    /// which is how discovery matches symbols and import stubs.
    var noReturnCanonicalNames: Set<String> {
        Set(noReturnNames.map { NoReturnCatalog.canonicalName(for: $0) })
    }

    private struct File: Codable {
        var format: String
        var formatVersion: Int
        var generator: Generator
        var entries: [Entry]
    }

    /// Strict load: bounded size, exact format/version, every entry well formed, names unique.
    /// A pack that fails any check is rejected whole (the catalog then runs without it).
    static func load(_ data: Data) throws -> CallSignaturePack {
        guard data.count <= maximumBytes else { throw LoadError.tooLarge }
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch { throw LoadError.malformed }
        guard file.format == formatIdentifier, file.formatVersion == supportedFormatVersion else {
            throw LoadError.unsupportedFormat(file.format, version: file.formatVersion)
        }
        guard file.entries.count <= maximumEntries else { throw LoadError.tooLarge }
        var seen = Set<String>()
        for (index, entry) in file.entries.enumerated() {
            guard isIdentifier(entry.name), isTypeSpelling(entry.returns),
                  entry.abiReturns.map(isTypeSpelling) ?? true,
                  entry.params.count <= maximumParameters,
                  entry.params.allSatisfy({ isTypeSpelling($0.type) && ($0.abiType.map(isTypeSpelling) ?? true) }) else {
                throw LoadError.invalidEntry(index: index)
            }
            guard seen.insert(entry.name).inserted else { throw LoadError.duplicateEntry(entry.name) }
        }
        return CallSignaturePack(generator: file.generator, entries: file.entries)
    }

    private static func isTypeSpelling(_ spelling: String) -> Bool {
        !spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && spelling.utf8.count <= 4_096 && !spelling.contains("\0")
    }

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 256,
              first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            $0 == "_" || $0 == "$" || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
        }
    }
}

extension CallSignaturePack {
    static let bundledResourceName = "SDKCallSignaturePack"

    /// Loads the bundled pack from `bundle` (the app, the analysis worker, or the hosted test
    /// bundle's app). Nil when the resource is missing or fails the strict load; analysis then
    /// runs on the hand-written catalogs alone.
    static func loadBundled(from bundle: Bundle = .main) -> CallSignaturePack? {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? load(data)
    }

    /// The shipped SDK pack, loaded once per process at first use.
    static let bundled: CallSignaturePack? = loadBundled()

    /// HOP-1 no-return keys from the shipped pack (empty without one).
    static let bundledNoReturnCanonicalNames: Set<String> = bundled?.noReturnCanonicalNames ?? []
}

extension CallSignatureCatalog {
    /// Hand-verified signatures only: seeds, then the header-verified corpus, then runtime seeds.
    static var handWritten: [CallSignatureSpec] {
        seeds + CallSignatureCorpus.all + RuntimeSignatureSeeds.all + [
            // Apple Libc-1439.40.11 sys/OpenBSD/stack_protector.c:49.
            // This is a fixed zero-argument C runtime contract, not an
            // inference that every noreturn call is void or argument-free.
            CallSignatureSpec(canonicalName: "__stack_chk_fail", returnType: "void")
        ]
    }

    /// The hand-written catalog plus the shipped SDK pack at the lowest precedence.
    static func standardSpecs(bundledPack: CallSignaturePack? = CallSignaturePack.bundled) -> [CallSignatureSpec] {
        handWritten + (bundledPack?.specs ?? [])
    }

    /// The standard catalog plus another loaded pack below the shipped one.
    static func standard(adding pack: CallSignaturePack) -> CallSignatureCatalog {
        CallSignatureCatalog(standardSpecs() + pack.specs)
    }
}
