#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace macscope::native_decompiler {

using Address = std::uint64_t;

/// Numeric-only diagnostics for the accepted prefix of native output accounting.
/// All category totals are weighted bytes, not object counts or raw UTF-8 sizes.
/// Their sum equals usedBytes; the rejected charge/preflight is not included.
struct OutputBudgetDiagnostics final {
    enum class Failure { chargeExceedsLimit, preflightExceedsLimit, productOverflow,
                         cumulativeCountOverflow };
    enum class Category { schemaReserve, textOccurrences, distinctTextObjects,
                          distinctTextContent, scalars, records, containers,
                          instructionBytes, preflight };
    std::size_t maximumBytes = 0U;
    std::size_t usedBytes = 0U;
    std::size_t schemaReserveBytes = 0U;
    std::size_t textOccurrenceBytes = 0U;
    std::size_t distinctTextObjectBytes = 0U;
    std::size_t distinctTextContentBytes = 0U;
    std::size_t scalarBytes = 0U;
    std::size_t recordBytes = 0U;
    std::size_t containerBytes = 0U;
    std::size_t instructionByteBytes = 0U;
    Failure failure = Failure::chargeExceedsLimit;
    Category attemptedCategory = Category::schemaReserve;
    std::size_t attemptedCount = 0U;
    std::size_t attemptedWidth = 0U;
    // Absent for overflow; never substitute a wrapped or saturated product.
    std::optional<std::size_t> attemptedBytes;
};

class ContractError final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
    ContractError(const char* message, OutputBudgetDiagnostics diagnostics)
        : std::runtime_error(message), outputBudgetDiagnostics_(diagnostics) {}

    [[nodiscard]] const std::optional<OutputBudgetDiagnostics>&
    outputBudgetDiagnostics() const noexcept { return outputBudgetDiagnostics_; }

private:
    std::optional<OutputBudgetDiagnostics> outputBudgetDiagnostics_;
};

/// A caller-owned mapped region with immutable provenance bytes and the derived
/// effective bytes that a native analysis backend is permitted to consume.
/// `appliedPatchIds` names the already-validated DCP-03B2 relocation/fixup
/// records that contributed to the effective view. The bridge never opens or
/// reparses the source Mach-O to derive either byte sequence.
struct MemoryRegion final {
    std::string name;
    Address startAddress = 0;
    std::string permissions;
    std::vector<std::uint8_t> rawBytes;
    std::vector<std::uint8_t> effectiveBytes;
    std::vector<std::string> appliedPatchIds;

    [[nodiscard]] Address endAddressExclusive() const;
    [[nodiscard]] bool readable() const noexcept;
    [[nodiscard]] bool writable() const noexcept;
    [[nodiscard]] bool executable() const noexcept;
};

class ByteProvider final {
public:
    explicit ByteProvider(std::vector<MemoryRegion> regions);

    [[nodiscard]] const std::vector<MemoryRegion>& regions() const noexcept;

    /// Read the immutable caller-supplied bytes retained only for provenance,
    /// source hashing, and independent verification.
    [[nodiscard]] std::vector<std::uint8_t> readRaw(Address startAddress, std::size_t byteCount) const;

    /// Read the independently derived effective bytes. Native disassembly,
    /// lifting, and decompilation adapters must use this view.
    [[nodiscard]] std::vector<std::uint8_t> readEffective(Address startAddress, std::size_t byteCount) const;

    [[nodiscard]] bool contains(Address startAddress, std::size_t byteCount, bool requireExecutable) const;

private:
    enum class View { raw, effective };
    [[nodiscard]] std::vector<std::uint8_t> read(
        Address startAddress,
        std::size_t byteCount,
        View view
    ) const;

    std::vector<MemoryRegion> regions_;
};

struct SymbolRecord final {
    std::string imageId;
    Address address = 0;
    std::string name;
    std::string kind;

    auto operator<=>(const SymbolRecord&) const = default;
};

class SymbolProvider final {
public:
    explicit SymbolProvider(std::vector<SymbolRecord> symbols);

    [[nodiscard]] const std::vector<SymbolRecord>& symbols() const noexcept;
    [[nodiscard]] std::vector<SymbolRecord> exact(Address address) const;
    [[nodiscard]] std::optional<SymbolRecord> preferred(Address address) const;

private:
    std::vector<SymbolRecord> symbols_;
};

struct TypeHintRecord final {
    std::string subjectKind;
    Address address = 0;
    std::string typeName;
    std::string confidence;
    std::string source;

    auto operator<=>(const TypeHintRecord&) const = default;
};

class TypeHintProvider final {
public:
    explicit TypeHintProvider(std::vector<TypeHintRecord> typeHints);

    [[nodiscard]] const std::vector<TypeHintRecord>& typeHints() const noexcept;
    [[nodiscard]] std::vector<TypeHintRecord> at(Address address) const;

private:
    std::vector<TypeHintRecord> typeHints_;
};

struct ImageIdentity final {
    std::string imageId;
    std::string uuid;
    Address preferredLoadAddress = 0;

    bool operator==(const ImageIdentity&) const = default;
};

struct FunctionIdentity final {
    struct CodeRange final {
        Address startAddress = 0;
        Address endAddressExclusive = 0;

        bool operator==(const CodeRange&) const = default;
    };

    std::string functionId;
    std::string name;
    Address entryAddress = 0;
    Address endAddressExclusive = 0;
    std::vector<CodeRange> codeRanges;

    bool operator==(const FunctionIdentity&) const = default;
};

struct AnalysisBudgets final {
    std::size_t maxCodeBytes = 0;
    std::size_t maxInstructions = 0;
    std::size_t maxOperations = 0;
    std::size_t maxOutputBytes = 0;
    std::uint64_t maxWallTimeMilliseconds = 0;
};

/// Strong value for the frozen production budget profile carried by schema v3.
struct ProfiledAnalysisBudgets final {
    std::string profileId;
    std::size_t maxCodeBytes = 0;
    std::size_t maxInstructions = 0;
    std::size_t maxOperations = 0;
    std::size_t maxOutputBytes = 0;
    std::uint64_t maxWallTimeMilliseconds = 0;

    [[nodiscard]] AnalysisBudgets analysisLimits() const noexcept;
};

[[nodiscard]] ProfiledAnalysisBudgets productAnalysisBudgetsV1();

/// Opt-in profile: 8 MiB output headroom for measured libjpeg NEON exports.
/// Other limits remain v1; selecting this profile must be explicit on both sides.
[[nodiscard]] ProfiledAnalysisBudgets productAnalysisBudgetsV2();

/// Product default: 32 MiB output (under the 64 MiB transport ceiling) for
/// functions whose varnode stage exceeds v2. Other limits remain v1.
[[nodiscard]] ProfiledAnalysisBudgets productAnalysisBudgetsV3();

enum class ArchitectureVariant : std::uint8_t {
    arm64 = 0,
    arm64e = 1,
    x86_64 = 2,
};

struct TargetContextValue final {
    std::string name;
    std::uint32_t value = 0;

    bool operator==(const TargetContextValue&) const = default;
};

struct TargetProfile final {
    std::string rawCpuType;
    std::string rawCpuSubtype;
    ArchitectureVariant normalizedVariant = ArchitectureVariant::arm64;
    std::string recognizedCapabilityBits;
    std::optional<std::uint32_t> pointerAuthAbiVersion;
    std::string selectedSliceSha256;
    std::uint64_t selectedSliceByteCount = 0;
    std::string profileId;
    std::string languageId;
    std::string compilerSpecId;
    std::string contextProfileSha256;
    std::array<TargetContextValue, 4> context{};
};

[[nodiscard]] TargetProfile normalizeAppleMachOTarget(
    std::uint32_t rawCpuType,
    std::uint32_t rawCpuSubtype,
    std::string selectedSliceSha256,
    std::uint64_t selectedSliceByteCount
);

enum class AuthoredTypeTag : std::uint8_t {
    qualifiedValue = 0,
    dataPointer = 1,
};

enum class AuthoredAtomTag : std::uint8_t {
    void_ = 0,
    scalar = 1,
    darwinAlias = 2,
    named = 3,
};

enum class AuthoredScalarKind : std::uint8_t {
    bool_ = 0,
    char_ = 1,
    signed8 = 2,
    unsigned8 = 3,
    signed16 = 4,
    unsigned16 = 5,
    signed32 = 6,
    unsigned32 = 7,
    signed64 = 8,
    unsigned64 = 9,
    float32 = 10,
    float64 = 11,
};

enum class AuthoredDarwinAliasKind : std::uint8_t {
    sizeT = 0,
    ssizeT = 1,
    intptrT = 2,
    uintptrT = 3,
    ptrdiffT = 4,
    wcharT = 5,
};

enum class AuthoredNamedKind : std::uint8_t {
    struct_ = 0,
    union_ = 1,
    enum_ = 2,
    typedef_ = 3,
};

enum class AuthoredTypeDefinitionKind : std::uint8_t {
    recordStruct = 0,
    recordUnion = 1,
    enumeration = 2,
    typedef_ = 3,
};

enum class AuthoredNameSubjectKind : std::uint8_t {
    function = 0,
    label = 1,
    data = 2,
};

enum class AuthoredAppliedTypeSubjectKind : std::uint8_t {
    memoryObject = 0,
};

enum class AuthoredParameterListState : std::uint8_t {
    unspecified = 0,
    authoritative = 1,
};

enum class AuthoredVariadicState : std::uint8_t {
    unspecified = 0,
    fixed = 1,
    variadic = 2,
};

enum class AuthoredNoReturnState : std::uint8_t {
    unspecified = 0,
    returns = 1,
    noReturn = 2,
};

enum class AuthoredFieldStorageTag : std::uint8_t {
    value = 0,
    fixedArray = 1,
    flexibleArray = 2,
    opaquePointerCarrier = 3,
    inlineAggregate = 4,
};

enum class AuthoredOpaquePointerCarrierKind : std::uint8_t {
    functionPointer = 0,
    pointerToArray = 1,
};

enum class AuthoredEnumRepresentation : std::uint8_t {
    signed32 = 0,
};

enum class AuthoredQualifier : std::uint8_t {
    constant = 0x01,
    volatile_ = 0x02,
    restrict_ = 0x04,
};

struct AuthoredType;
struct AuthoredFieldStorage;

struct AuthoredNamedAtom final {
    AuthoredNamedKind kind = AuthoredNamedKind::struct_;
    std::string name;
};

using AuthoredAtomPayload = std::variant<
    std::monostate,
    AuthoredScalarKind,
    AuthoredDarwinAliasKind,
    AuthoredNamedAtom
>;

struct AuthoredAtom final {
    AuthoredAtomTag tag = AuthoredAtomTag::void_;
    AuthoredAtomPayload payload;
};

struct AuthoredQualifiedValue final {
    AuthoredAtom atom;
    std::uint8_t qualifiers = 0;
};

struct AuthoredDataPointer final {
    std::shared_ptr<AuthoredType> pointee;
    std::uint64_t indirectionLevel = 0;
    std::vector<std::uint8_t> pointerQualifiersByLevel;
};

using AuthoredTypePayload = std::variant<AuthoredQualifiedValue, AuthoredDataPointer>;

struct AuthoredType final {
    AuthoredTypeTag tag = AuthoredTypeTag::qualifiedValue;
    AuthoredTypePayload payload;
};

struct AuthoredLayoutRules final {
    bool isPacked = false;
    std::optional<std::uint64_t> packAlignment;
    std::optional<std::uint64_t> minimumAlignment;
};

struct AuthoredRecordField final {
    std::string name;
    std::shared_ptr<AuthoredFieldStorage> storage;
    std::optional<std::uint64_t> bitWidth;
    std::optional<std::uint64_t> minimumAlignment;
    std::shared_ptr<AuthoredType> minimumAlignmentType;
    bool promotesInlineFields = false;
};

struct AuthoredValueStorage final {
    AuthoredType type;
};

struct AuthoredFixedArrayStorage final {
    std::shared_ptr<AuthoredFieldStorage> element;
    std::uint64_t count = 0;
};

struct AuthoredFlexibleArrayStorage final {
    std::shared_ptr<AuthoredFieldStorage> element;
};

struct AuthoredOpaquePointerCarrierStorage final {
    AuthoredOpaquePointerCarrierKind kind = AuthoredOpaquePointerCarrierKind::functionPointer;
};

struct AuthoredInlineAggregateStorage final {
    AuthoredNamedKind kind = AuthoredNamedKind::struct_;
    AuthoredLayoutRules layoutRules;
    std::vector<AuthoredRecordField> fields;
};

using AuthoredFieldStoragePayload = std::variant<
    AuthoredValueStorage,
    AuthoredFixedArrayStorage,
    AuthoredFlexibleArrayStorage,
    AuthoredOpaquePointerCarrierStorage,
    AuthoredInlineAggregateStorage
>;

struct AuthoredFieldStorage final {
    AuthoredFieldStorageTag tag = AuthoredFieldStorageTag::value;
    AuthoredFieldStoragePayload payload;
};

struct AuthoredEnumCase final {
    std::string name;
    std::int32_t value = 0;
};

struct AuthoredRecordDefinition final {
    AuthoredNamedKind kind = AuthoredNamedKind::struct_;
    AuthoredLayoutRules layoutRules;
    std::vector<AuthoredRecordField> fields;
};

struct AuthoredEnumerationDefinition final {
    AuthoredEnumRepresentation representation = AuthoredEnumRepresentation::signed32;
    std::vector<AuthoredEnumCase> cases;
};

struct AuthoredTypedefDefinition final {
    std::shared_ptr<AuthoredFieldStorage> target;
};

using AuthoredTypeDefinitionPayload = std::variant<
    AuthoredRecordDefinition,
    AuthoredEnumerationDefinition,
    AuthoredTypedefDefinition
>;

struct AuthoredTypeDefinition final {
    AuthoredTypeDefinitionKind kind = AuthoredTypeDefinitionKind::recordStruct;
    std::string name;
    AuthoredTypeDefinitionPayload payload;
};

struct AuthoredName final {
    Address address = 0;
    AuthoredNameSubjectKind subjectKind = AuthoredNameSubjectKind::function;
    std::string name;
};

struct AuthoredParameter final {
    std::string name;
    AuthoredType type;
    std::optional<std::string> storageRegister = std::nullopt; // SLEIGH register name, e.g. "x20".
};

struct AuthoredSignature final {
    Address functionAddress = 0;
    std::shared_ptr<AuthoredType> returnType;
    AuthoredParameterListState parameterListState = AuthoredParameterListState::unspecified;
    std::vector<AuthoredParameter> parameters;
    AuthoredVariadicState variadicState = AuthoredVariadicState::unspecified;
    AuthoredNoReturnState noReturnState = AuthoredNoReturnState::unspecified;
};

/// Authored-input schema v2: a known prototype for a direct callee, from debug
/// info, a user-authored by-name signature, the SDK call-signature pack, or the
/// callee's own Swift symbol, which also fixes context registers. The
/// bridge installs it as the callee's named, locked prototype so call sites show
/// its arguments; it never changes the decompiled function's own signature.
enum class CalleeSignatureHintSource : std::uint8_t {
    debug = 0,
    authored = 1,
    sdk = 2,
    recovered = 3,
    swift = 4,
};

struct CalleeSignatureHint final {
    std::string name;
    CalleeSignatureHintSource source = CalleeSignatureHintSource::sdk;
    AuthoredSignature signature;
};

/// Authored-input schema v3 (DP04 C1b): a user-authored name, and optional type,
/// for one local of the decompiled function. A stack entry becomes a name-locked
/// (type-locked when typed) local symbol at its entry-SP offset; a register entry
/// renames every variable the function keeps in that GPR.
enum class AuthoredLocalStorageKind : std::uint8_t {
    stack = 0,
    register_ = 1,
};

struct AuthoredLocalName final {
    AuthoredLocalStorageKind storageKind = AuthoredLocalStorageKind::stack;
    std::int32_t stackOffset = 0;
    std::uint32_t byteSize = 0;
    std::string registerName;
    std::string name;
    std::shared_ptr<AuthoredType> type;
};

struct AppliedType final {
    Address address = 0;
    AuthoredAppliedTypeSubjectKind subjectKind = AuthoredAppliedTypeSubjectKind::memoryObject;
    std::string typeDefinitionName;
    std::uint64_t byteCount = 0;
};

struct AuthoredInputs final {
    std::uint32_t schemaVersion = 1;
    std::vector<AuthoredName> names;
    std::vector<AuthoredSignature> signatures;
    std::vector<AppliedType> appliedTypes;
    std::vector<AuthoredTypeDefinition> typeDefinitions;
    /// Schema v2 only; empty in v1.
    std::vector<CalleeSignatureHint> calleeSignatureHints;
    /// Schema v3 only; empty in v1 and v2.
    std::vector<AuthoredLocalName> localNames;
};

[[nodiscard]] AuthoredInputs canonicalizedAuthoredInputs(AuthoredInputs inputs);

class CancellationToken final {
public:
    CancellationToken() = default;
    explicit CancellationToken(const std::atomic_bool* flag) noexcept;

    [[nodiscard]] bool isCancelled() const noexcept;
    void throwIfCancelled() const;

private:
    const std::atomic_bool* flag_ = nullptr;
};

struct AnalysisRequestView final {
    std::string requestId;
    std::string requestSha256;
    std::string languageId;
    std::string compilerSpecId;
    ImageIdentity image;
    FunctionIdentity function;
    ByteProvider bytes;
    SymbolProvider symbols;
    TypeHintProvider typeHints;
    AuthoredInputs authoredInputs;
    AnalysisBudgets budgets;
    std::uint32_t schemaVersion = 3;
    /// Operation `decompile-document`: the reply carries only the pseudocode document
    /// (and warnings); every structured-graph collection is empty. Whole-image export
    /// uses it, so a huge function's graph never has to be encoded and transferred.
    bool documentOnly = false;

    AnalysisRequestView(
        std::string requestId,
        std::string requestSha256,
        std::string languageId,
        std::string compilerSpecId,
        ImageIdentity image,
        FunctionIdentity function,
        ByteProvider bytes,
        SymbolProvider symbols,
        TypeHintProvider typeHints,
        AnalysisBudgets budgets,
        std::uint32_t schemaVersion = 3
    );

    AnalysisRequestView(
        std::string requestId,
        std::string requestSha256,
        std::string languageId,
        std::string compilerSpecId,
        ImageIdentity image,
        FunctionIdentity function,
        ByteProvider bytes,
        SymbolProvider symbols,
        TypeHintProvider typeHints,
        AuthoredInputs authoredInputs,
        AnalysisBudgets budgets,
        std::uint32_t schemaVersion = 3
    );

    /// Compatibility name for backend consumers. This intentionally returns
    /// the effective analysis view, never the raw provenance view.
    [[nodiscard]] std::vector<std::uint8_t> functionBytes() const;
    [[nodiscard]] std::vector<std::uint8_t> rawFunctionBytes() const;
    [[nodiscard]] std::vector<std::uint8_t> effectiveFunctionBytes() const;
};

} // namespace macscope::native_decompiler
