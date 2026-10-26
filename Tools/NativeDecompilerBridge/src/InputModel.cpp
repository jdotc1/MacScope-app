#include "MacScopeNativeDecompiler/InputModel.hpp"
#include "TextValidation.hpp"

#include <algorithm>
#include <compare>
#include <cctype>
#include <limits>
#include <set>
#include <tuple>
#include <type_traits>

namespace macscope::native_decompiler {
namespace {

constexpr std::size_t kMaximumRegions = 256;
constexpr std::size_t kMaximumRecords = 100'000;
constexpr std::size_t kMaximumTotalBytes = 64U * 1024U * 1024U;
constexpr std::size_t kMaximumAuthoredNames = 4'096;
constexpr std::size_t kMaximumAuthoredSignatures = 4'096;
constexpr std::size_t kMaximumAuthoredParameters = 256;
constexpr std::size_t kMaximumAuthoredAppliedTypes = 4'096;
constexpr std::size_t kMaximumAuthoredTypeDefinitions = 1'024;
constexpr std::size_t kMaximumAuthoredAggregateMembers = 16'384;
constexpr std::size_t kMaximumAuthoredDepth = 16;
constexpr std::uint64_t kMaximumFixedArrayElements = 1'048'576;
constexpr std::uint64_t kMaximumAuthoredStorageBytes = 1'048'576;

[[nodiscard]] std::string canonicalLowercaseHexWord(std::uint32_t value) {
    constexpr char digits[] = "0123456789abcdef";
    std::string encoded(8, '0');
    for (auto index = encoded.size(); index > 0; --index) {
        encoded[index - 1] = digits[value & 0x0fU];
        value >>= 4U;
    }
    return encoded;
}

[[nodiscard]] bool isCanonicalSha256(std::string_view value) {
    return value.size() == 64 && std::all_of(
        value.begin(),
        value.end(),
        [](unsigned char character) {
            return (character >= '0' && character <= '9') ||
                   (character >= 'a' && character <= 'f');
        }
    );
}

[[nodiscard]] Address checkedEnd(Address start, std::size_t size, std::string_view label) {
    if (size > std::numeric_limits<Address>::max() - start) {
        throw ContractError(std::string(label) + " range overflows the unsigned 64-bit address space");
    }
    return start + static_cast<Address>(size);
}

void requireBoundedText(std::string_view value, std::string_view label, std::size_t maximum = 4096) {
    if (value.empty() || value.size() > maximum) {
        throw ContractError(std::string(label) + " must be non-empty bounded text");
    }
    if (!detail::isValidUtf8(value)) {
        throw ContractError(std::string(label) + " must be valid UTF-8");
    }
    for (const unsigned char character : value) {
        if (character < 0x20U || character == 0x7fU) {
            throw ContractError(std::string(label) + " contains unsupported control text");
        }
    }
}

void validatePermissions(std::string_view permissions) {
    if (permissions.size() != 3 ||
        (permissions[0] != 'r' && permissions[0] != '-') ||
        (permissions[1] != 'w' && permissions[1] != '-') ||
        (permissions[2] != 'x' && permissions[2] != '-')) {
        throw ContractError("memory-region permissions must use rwx triplet syntax");
    }
}

template <typename Enumeration>
[[nodiscard]] constexpr auto authoredRawValue(Enumeration value) noexcept {
    return static_cast<std::underlying_type_t<Enumeration>>(value);
}

template <typename Enumeration>
[[nodiscard]] constexpr bool authoredEnumIsKnown(
    Enumeration value,
    Enumeration maximum
) noexcept {
    return authoredRawValue(value) <= authoredRawValue(maximum);
}

[[nodiscard]] bool exactUtf8BytesPrecede(std::string_view lhs, std::string_view rhs) {
    return std::lexicographical_compare(
        lhs.begin(),
        lhs.end(),
        rhs.begin(),
        rhs.end(),
        [](char lhsByte, char rhsByte) {
            return static_cast<unsigned char>(lhsByte) < static_cast<unsigned char>(rhsByte);
        }
    );
}

void requireAuthoredText(
    std::string_view value,
    std::string_view label,
    std::size_t maximum
) {
    requireBoundedText(value, label, maximum);
}

void validateAuthoredLayoutRules(const AuthoredLayoutRules& rules) {
    if ((rules.packAlignment && *rules.packAlignment == 0) ||
        (rules.minimumAlignment && *rules.minimumAlignment == 0)) {
        throw ContractError("authored layout alignment must be positive when present");
    }
}

void validateAuthoredRecordFieldShape(const AuthoredRecordField& field) {
    if (field.storage == nullptr) {
        throw ContractError("authored record field requires storage");
    }

    const auto* inlineAggregate = field.storage->tag == AuthoredFieldStorageTag::inlineAggregate
        ? std::get_if<AuthoredInlineAggregateStorage>(&field.storage->payload)
        : nullptr;
    const bool isSupportedInlineAggregate = inlineAggregate != nullptr &&
        (inlineAggregate->kind == AuthoredNamedKind::struct_ ||
         inlineAggregate->kind == AuthoredNamedKind::union_);

    if (field.promotesInlineFields) {
        if (!field.name.empty() || field.bitWidth.has_value() ||
            !isSupportedInlineAggregate) {
            throw ContractError(
                "authored inline-field promotion requires one anonymous non-bitfield inline struct/union"
            );
        }
    } else if (field.name.empty()) {
        if (!field.bitWidth.has_value() ||
            field.storage->tag != AuthoredFieldStorageTag::value) {
            throw ContractError(
                "empty authored record-field names require a value bitfield or promoted inline aggregate"
            );
        }
    } else {
        requireAuthoredText(field.name, "authored record-field name", 1'024);
    }

    if (field.bitWidth.has_value()) {
        if (field.storage->tag != AuthoredFieldStorageTag::value) {
            throw ContractError("authored bitfield storage must be a value");
        }
        if (*field.bitWidth == 0 && !field.name.empty()) {
            throw ContractError("zero-width authored bitfields must be unnamed");
        }
    }
}

[[nodiscard]] std::uint64_t checkedAuthoredStorageSum(
    std::uint64_t lhs,
    std::uint64_t rhs
) {
    if (rhs > kMaximumAuthoredStorageBytes - lhs) {
        throw ContractError("computed authored storage exceeds the fixed bound");
    }
    return lhs + rhs;
}

[[nodiscard]] std::uint64_t checkedAuthoredStorageProduct(
    std::uint64_t lhs,
    std::uint64_t rhs
) {
    if (lhs != 0 && rhs > kMaximumAuthoredStorageBytes / lhs) {
        throw ContractError("computed authored storage exceeds the fixed bound");
    }
    const auto product = lhs * rhs;
    if (product > kMaximumAuthoredStorageBytes) {
        throw ContractError("computed authored storage exceeds the fixed bound");
    }
    return product;
}

void requireAuthoredDepth(std::size_t depth) {
    if (depth > kMaximumAuthoredDepth) {
        throw ContractError("authored type/storage depth exceeds 16");
    }
}

[[nodiscard]] std::uint64_t validateAuthoredType(
    const AuthoredType& type,
    std::size_t depth,
    bool allowsVoid
);

[[nodiscard]] std::uint64_t validateAuthoredStorageImpl(
    const AuthoredFieldStorage& storage,
    std::size_t depth,
    std::size_t& aggregateMembers,
    bool permitsFlexibleArray,
    std::set<const AuthoredFieldStorage*>& activeStorages
);

void chargeAuthoredAggregateMembers(std::size_t count, std::size_t& aggregateMembers) {
    if (count > kMaximumAuthoredAggregateMembers - aggregateMembers) {
        throw ContractError("authored aggregate parameters, fields, and enum cases exceed 16384");
    }
    aggregateMembers += count;
}

[[nodiscard]] std::uint64_t authoredScalarSize(AuthoredScalarKind kind) {
    if (!authoredEnumIsKnown(kind, AuthoredScalarKind::float64)) {
        throw ContractError("unknown authored scalar tag");
    }
    switch (kind) {
    case AuthoredScalarKind::bool_:
    case AuthoredScalarKind::char_:
    case AuthoredScalarKind::signed8:
    case AuthoredScalarKind::unsigned8:
        return 1;
    case AuthoredScalarKind::signed16:
    case AuthoredScalarKind::unsigned16:
        return 2;
    case AuthoredScalarKind::signed32:
    case AuthoredScalarKind::unsigned32:
    case AuthoredScalarKind::float32:
        return 4;
    case AuthoredScalarKind::signed64:
    case AuthoredScalarKind::unsigned64:
    case AuthoredScalarKind::float64:
        return 8;
    }
    throw ContractError("unknown authored scalar tag");
}

[[nodiscard]] std::uint64_t validateAuthoredType(
    const AuthoredType& type,
    std::size_t depth,
    bool allowsVoid
) {
    requireAuthoredDepth(depth);
    if (!authoredEnumIsKnown(type.tag, AuthoredTypeTag::dataPointer)) {
        throw ContractError("unknown authored type tag");
    }

    switch (type.tag) {
    case AuthoredTypeTag::qualifiedValue: {
        const auto* qualified = std::get_if<AuthoredQualifiedValue>(&type.payload);
        if (qualified == nullptr) {
            throw ContractError("authored qualified-value tag/payload mismatch");
        }
        if ((qualified->qualifiers & ~std::uint8_t{0x03}) != 0) {
            throw ContractError("unknown or base-level authored qualifier bit");
        }
        const auto& atom = qualified->atom;
        if (!authoredEnumIsKnown(atom.tag, AuthoredAtomTag::named)) {
            throw ContractError("unknown authored atom tag");
        }
        switch (atom.tag) {
        case AuthoredAtomTag::void_:
            if (!std::holds_alternative<std::monostate>(atom.payload)) {
                throw ContractError("authored void atom tag/payload mismatch");
            }
            if (!allowsVoid) {
                throw ContractError("authored void is unsupported in a value position");
            }
            return 0;
        case AuthoredAtomTag::scalar: {
            const auto* kind = std::get_if<AuthoredScalarKind>(&atom.payload);
            if (kind == nullptr) {
                throw ContractError("authored scalar atom tag/payload mismatch");
            }
            return authoredScalarSize(*kind);
        }
        case AuthoredAtomTag::darwinAlias: {
            const auto* kind = std::get_if<AuthoredDarwinAliasKind>(&atom.payload);
            if (kind == nullptr || !authoredEnumIsKnown(*kind, AuthoredDarwinAliasKind::wcharT)) {
                throw ContractError("authored Darwin-alias atom tag/payload mismatch");
            }
            return *kind == AuthoredDarwinAliasKind::wcharT ? 4 : 8;
        }
        case AuthoredAtomTag::named: {
            const auto* named = std::get_if<AuthoredNamedAtom>(&atom.payload);
            if (named == nullptr || !authoredEnumIsKnown(named->kind, AuthoredNamedKind::typedef_)) {
                throw ContractError("authored named atom tag/payload mismatch");
            }
            requireAuthoredText(named->name, "authored catalog type name", 4'096);
            // Exact named-layout resolution belongs to prepared authority.
            return 0;
        }
        }
        break;
    }
    case AuthoredTypeTag::dataPointer: {
        const auto* pointer = std::get_if<AuthoredDataPointer>(&type.payload);
        if (pointer == nullptr) {
            throw ContractError("authored data-pointer tag/payload mismatch");
        }
        if (pointer->pointee == nullptr || pointer->indirectionLevel == 0 ||
            pointer->indirectionLevel > 8 ||
            pointer->pointerQualifiersByLevel.size() != pointer->indirectionLevel ||
            pointer->pointee->tag != AuthoredTypeTag::qualifiedValue) {
            throw ContractError("authored data-pointer shape is invalid");
        }
        for (const auto qualifiers : pointer->pointerQualifiersByLevel) {
            if ((qualifiers & ~std::uint8_t{0x07}) != 0) {
                throw ContractError("unknown authored pointer qualifier bit");
            }
        }
        (void)validateAuthoredType(*pointer->pointee, depth + 1, true);
        return 8;
    }
    }
    throw ContractError("unknown authored type tag");
}

[[nodiscard]] std::uint64_t validateAuthoredStorageImpl(
    const AuthoredFieldStorage& storage,
    std::size_t depth,
    std::size_t& aggregateMembers,
    bool permitsFlexibleArray,
    std::set<const AuthoredFieldStorage*>& activeStorages
) {
    requireAuthoredDepth(depth);
    if (!activeStorages.insert(&storage).second) {
        throw ContractError("cyclic active authored field storage is unsupported");
    }
    struct ActiveStorageGuard final {
        std::set<const AuthoredFieldStorage*>& activeStorages;
        const AuthoredFieldStorage* storage;
        ~ActiveStorageGuard() { activeStorages.erase(storage); }
    } activeStorageGuard{activeStorages, &storage};

    if (!authoredEnumIsKnown(storage.tag, AuthoredFieldStorageTag::inlineAggregate)) {
        throw ContractError("unknown authored field-storage tag");
    }
    switch (storage.tag) {
    case AuthoredFieldStorageTag::value: {
        const auto* value = std::get_if<AuthoredValueStorage>(&storage.payload);
        if (value == nullptr) {
            throw ContractError("authored value-storage tag/payload mismatch");
        }
        return validateAuthoredType(value->type, depth, false);
    }
    case AuthoredFieldStorageTag::fixedArray: {
        const auto* array = std::get_if<AuthoredFixedArrayStorage>(&storage.payload);
        if (array == nullptr || array->element == nullptr) {
            throw ContractError("authored fixed-array tag/payload mismatch");
        }
        if (array->count == 0 || array->count > kMaximumFixedArrayElements) {
            throw ContractError("authored fixed-array dimension is outside 1...1048576");
        }
        const auto elementSize = validateAuthoredStorageImpl(
            *array->element,
            depth + 1,
            aggregateMembers,
            false,
            activeStorages
        );
        return checkedAuthoredStorageProduct(elementSize, array->count);
    }
    case AuthoredFieldStorageTag::flexibleArray: {
        const auto* array = std::get_if<AuthoredFlexibleArrayStorage>(&storage.payload);
        if (array == nullptr || array->element == nullptr) {
            throw ContractError("authored flexible-array tag/payload mismatch");
        }
        if (!permitsFlexibleArray) {
            throw ContractError("authored flexible array must be the final field of a struct");
        }
        (void)validateAuthoredStorageImpl(
            *array->element,
            depth + 1,
            aggregateMembers,
            false,
            activeStorages
        );
        return 0;
    }
    case AuthoredFieldStorageTag::opaquePointerCarrier: {
        const auto* carrier = std::get_if<AuthoredOpaquePointerCarrierStorage>(&storage.payload);
        if (carrier == nullptr ||
            !authoredEnumIsKnown(carrier->kind, AuthoredOpaquePointerCarrierKind::pointerToArray)) {
            throw ContractError("authored opaque-carrier tag/payload mismatch");
        }
        return 8;
    }
    case AuthoredFieldStorageTag::inlineAggregate: {
        const auto* aggregate = std::get_if<AuthoredInlineAggregateStorage>(&storage.payload);
        if (aggregate == nullptr ||
            (aggregate->kind != AuthoredNamedKind::struct_ &&
             aggregate->kind != AuthoredNamedKind::union_)) {
            throw ContractError("authored inline-aggregate tag/payload mismatch");
        }
        validateAuthoredLayoutRules(aggregate->layoutRules);
        chargeAuthoredAggregateMembers(aggregate->fields.size(), aggregateMembers);
        std::uint64_t size = 0;
        for (std::size_t fieldIndex = 0; fieldIndex < aggregate->fields.size(); ++fieldIndex) {
            const auto& field = aggregate->fields[fieldIndex];
            validateAuthoredRecordFieldShape(field);
            const auto fieldSize = validateAuthoredStorageImpl(
                *field.storage,
                depth + 1,
                aggregateMembers,
                permitsFlexibleArray &&
                    aggregate->kind == AuthoredNamedKind::struct_ &&
                    fieldIndex + 1 == aggregate->fields.size(),
                activeStorages
            );
            if (field.minimumAlignment && *field.minimumAlignment == 0) {
                throw ContractError("authored field alignment must be positive when present");
            }
            if (field.minimumAlignmentType != nullptr) {
                (void)validateAuthoredType(*field.minimumAlignmentType, depth + 2, false);
            }
            size = aggregate->kind == AuthoredNamedKind::union_
                ? std::max(size, fieldSize)
                : checkedAuthoredStorageSum(size, fieldSize);
        }
        return size;
    }
    }
    throw ContractError("unknown authored field-storage tag");
}

[[nodiscard]] std::uint64_t validateAuthoredStorage(
    const AuthoredFieldStorage& storage,
    std::size_t depth,
    std::size_t& aggregateMembers,
    bool permitsFlexibleArray = false
) {
    std::set<const AuthoredFieldStorage*> activeStorages;
    return validateAuthoredStorageImpl(
        storage,
        depth,
        aggregateMembers,
        permitsFlexibleArray,
        activeStorages
    );
}

void validateAuthoredDefinition(
    const AuthoredTypeDefinition& definition,
    std::size_t& aggregateMembers
) {
    requireAuthoredText(definition.name, "authored type-definition name", 4'096);
    if (!authoredEnumIsKnown(definition.kind, AuthoredTypeDefinitionKind::typedef_)) {
        throw ContractError("unknown authored type-definition tag");
    }

    std::uint64_t computedSize = 0;
    switch (definition.kind) {
    case AuthoredTypeDefinitionKind::recordStruct:
    case AuthoredTypeDefinitionKind::recordUnion: {
        const auto* record = std::get_if<AuthoredRecordDefinition>(&definition.payload);
        const auto expectedKind = definition.kind == AuthoredTypeDefinitionKind::recordStruct
            ? AuthoredNamedKind::struct_
            : AuthoredNamedKind::union_;
        if (record == nullptr || record->kind != expectedKind) {
            throw ContractError("authored record-definition tag/payload mismatch");
        }
        validateAuthoredLayoutRules(record->layoutRules);
        chargeAuthoredAggregateMembers(record->fields.size(), aggregateMembers);
        for (std::size_t fieldIndex = 0; fieldIndex < record->fields.size(); ++fieldIndex) {
            const auto& field = record->fields[fieldIndex];
            validateAuthoredRecordFieldShape(field);
            const auto fieldSize = validateAuthoredStorage(
                *field.storage,
                0,
                aggregateMembers,
                expectedKind == AuthoredNamedKind::struct_ &&
                    fieldIndex + 1 == record->fields.size()
            );
            if (field.minimumAlignment && *field.minimumAlignment == 0) {
                throw ContractError("authored field alignment must be positive when present");
            }
            if (field.minimumAlignmentType != nullptr) {
                (void)validateAuthoredType(*field.minimumAlignmentType, 1, false);
            }
            computedSize = expectedKind == AuthoredNamedKind::union_
                ? std::max(computedSize, fieldSize)
                : checkedAuthoredStorageSum(computedSize, fieldSize);
        }
        break;
    }
    case AuthoredTypeDefinitionKind::enumeration: {
        const auto* enumeration = std::get_if<AuthoredEnumerationDefinition>(&definition.payload);
        if (enumeration == nullptr ||
            enumeration->representation != AuthoredEnumRepresentation::signed32) {
            throw ContractError("authored enumeration-definition tag/payload mismatch");
        }
        chargeAuthoredAggregateMembers(enumeration->cases.size(), aggregateMembers);
        for (const auto& enumCase : enumeration->cases) {
            requireAuthoredText(enumCase.name, "authored enum-case name", 1'024);
        }
        computedSize = 4;
        break;
    }
    case AuthoredTypeDefinitionKind::typedef_: {
        const auto* typeAlias = std::get_if<AuthoredTypedefDefinition>(&definition.payload);
        if (typeAlias == nullptr || typeAlias->target == nullptr) {
            throw ContractError("authored typedef tag/payload mismatch");
        }
        computedSize = validateAuthoredStorage(*typeAlias->target, 0, aggregateMembers);
        break;
    }
    }
    if (computedSize > kMaximumAuthoredStorageBytes) {
        throw ContractError("computed authored storage exceeds the fixed bound");
    }
}

} // namespace

AuthoredInputs canonicalizedAuthoredInputs(AuthoredInputs inputs) {
    if (inputs.schemaVersion < 1 || inputs.schemaVersion > 3) {
        throw ContractError("authored-input schema version is unsupported");
    }
    if (inputs.schemaVersion == 1 && !inputs.calleeSignatureHints.empty()) {
        throw ContractError("callee signature hints require authored-input schema v2");
    }
    if (inputs.schemaVersion < 3 && !inputs.localNames.empty()) {
        throw ContractError("local names require authored-input schema v3");
    }
    if (inputs.localNames.size() > kMaximumAuthoredNames) {
        throw ContractError("authored local name collection exceeds 4096");
    }
    {
        std::set<std::tuple<std::uint8_t, std::int32_t, std::string>> localKeys;
        for (const auto& local : inputs.localNames) {
            if (!authoredEnumIsKnown(local.storageKind, AuthoredLocalStorageKind::register_)) {
                throw ContractError("unknown authored local storage kind");
            }
            requireAuthoredText(local.name, "authored local name", 1'024);
            if (local.name.empty()) throw ContractError("authored local name is empty");
            if (local.storageKind == AuthoredLocalStorageKind::stack) {
                if (!local.registerName.empty() || local.byteSize == 0U || local.byteSize > 4'096U) {
                    throw ContractError("authored stack local has an invalid extent");
                }
            } else {
                const auto& reg = local.registerName;
                bool valid = local.stackOffset == 0 && local.byteSize == 0U && reg.size() >= 2U &&
                    reg.size() <= 3U && reg[0] == 'x' && (reg.size() == 2U || reg[1] != '0');
                for (std::size_t index = 1; valid && index < reg.size(); ++index) {
                    valid = reg[index] >= '0' && reg[index] <= '9';
                }
                if (!valid || std::stoi(reg.substr(1)) > 30) {
                    throw ContractError("authored register local names no x0...x30 register");
                }
            }
            if (!localKeys.insert({static_cast<std::uint8_t>(local.storageKind), local.stackOffset,
                                   local.registerName}).second) {
                throw ContractError("duplicate authored local semantic key");
            }
            if (local.type != nullptr) (void)validateAuthoredType(*local.type, 0, false);
        }
    }
    if (inputs.calleeSignatureHints.size() > kMaximumAuthoredSignatures) {
        throw ContractError("callee signature hint collection exceeds 4096");
    }
    if (inputs.names.size() > kMaximumAuthoredNames) {
        throw ContractError("authored name collection exceeds 4096");
    }
    if (inputs.signatures.size() > kMaximumAuthoredSignatures) {
        throw ContractError("authored signature collection exceeds 4096");
    }
    if (inputs.appliedTypes.size() > kMaximumAuthoredAppliedTypes) {
        throw ContractError("authored applied-type collection exceeds 4096");
    }
    if (inputs.typeDefinitions.size() > kMaximumAuthoredTypeDefinitions) {
        throw ContractError("authored type-definition collection exceeds 1024");
    }

    for (const auto& signature : inputs.signatures) {
        if (signature.parameters.size() > kMaximumAuthoredParameters) {
            throw ContractError("authored signature parameter collection exceeds 256");
        }
    }

    std::set<std::pair<Address, std::uint8_t>> nameKeys;
    for (const auto& name : inputs.names) {
        if (!authoredEnumIsKnown(name.subjectKind, AuthoredNameSubjectKind::data)) {
            throw ContractError("unknown authored name-subject tag");
        }
        requireAuthoredText(name.name, "authored semantic name", 1'024);
        if (!nameKeys.emplace(name.address, authoredRawValue(name.subjectKind)).second) {
            throw ContractError("duplicate authored name semantic key");
        }
    }

    std::set<Address> signatureKeys;
    std::size_t aggregateMembers = 0;
    for (const auto& signature : inputs.signatures) {
        if (!signatureKeys.insert(signature.functionAddress).second) {
            throw ContractError("duplicate authored signature semantic key");
        }
        if (!authoredEnumIsKnown(
                signature.parameterListState,
                AuthoredParameterListState::authoritative
            )) {
            throw ContractError("unknown authored parameter-list state");
        }
        if (!authoredEnumIsKnown(signature.variadicState, AuthoredVariadicState::variadic)) {
            throw ContractError("unknown authored variadic state");
        }
        if (!authoredEnumIsKnown(signature.noReturnState, AuthoredNoReturnState::noReturn)) {
            throw ContractError("unknown authored no-return state");
        }
        if (signature.parameterListState == AuthoredParameterListState::unspecified &&
            !signature.parameters.empty()) {
            throw ContractError("unspecified authored parameter list cannot contain parameters");
        }
        chargeAuthoredAggregateMembers(signature.parameters.size(), aggregateMembers);
        if (signature.returnType != nullptr) {
            (void)validateAuthoredType(*signature.returnType, 0, true);
        }
        for (const auto& parameter : signature.parameters) {
            requireAuthoredText(parameter.name, "authored parameter name", 1'024);
            if (parameter.storageRegister) {
                requireAuthoredText(*parameter.storageRegister, "authored parameter storage register", 1'024);
                if (std::any_of(parameter.storageRegister->begin(), parameter.storageRegister->end(),
                        [](unsigned char character) { return std::isspace(character) != 0; })) {
                    throw ContractError("authored parameter storage register contains whitespace");
                }
            }
            (void)validateAuthoredType(parameter.type, 0, false);
        }
    }

    std::set<Address> hintKeys;
    for (const auto& hint : inputs.calleeSignatureHints) {
        const auto& signature = hint.signature;
        if (signatureKeys.count(signature.functionAddress) != 0U ||
            !hintKeys.insert(signature.functionAddress).second) {
            throw ContractError("duplicate callee signature hint semantic key");
        }
        if (!authoredEnumIsKnown(hint.source, CalleeSignatureHintSource::swift)) {
            throw ContractError("unknown callee signature hint source");
        }
        requireAuthoredText(hint.name, "callee signature hint name", 1'024);
        if (signature.parameterListState != AuthoredParameterListState::authoritative) {
            throw ContractError("callee signature hint parameter list must be authoritative");
        }
        if (signature.parameters.size() > kMaximumAuthoredParameters) {
            throw ContractError("authored signature parameter collection exceeds 256");
        }
        if (!authoredEnumIsKnown(signature.variadicState, AuthoredVariadicState::variadic)) {
            throw ContractError("unknown authored variadic state");
        }
        if (!authoredEnumIsKnown(signature.noReturnState, AuthoredNoReturnState::noReturn)) {
            throw ContractError("unknown authored no-return state");
        }
        chargeAuthoredAggregateMembers(signature.parameters.size(), aggregateMembers);
        if (signature.returnType != nullptr) {
            (void)validateAuthoredType(*signature.returnType, 0, true);
        }
        for (const auto& parameter : signature.parameters) {
            requireAuthoredText(parameter.name, "authored parameter name", 1'024);
            if (parameter.storageRegister) {
                requireAuthoredText(*parameter.storageRegister, "authored parameter storage register", 1'024);
                if (std::any_of(parameter.storageRegister->begin(), parameter.storageRegister->end(),
                        [](unsigned char character) { return std::isspace(character) != 0; })) {
                    throw ContractError("authored parameter storage register contains whitespace");
                }
            }
            (void)validateAuthoredType(parameter.type, 0, false);
        }
    }

    std::set<std::pair<Address, std::uint8_t>> appliedTypeKeys;
    for (const auto& appliedType : inputs.appliedTypes) {
        if (appliedType.subjectKind != AuthoredAppliedTypeSubjectKind::memoryObject) {
            throw ContractError("unknown authored applied-type subject tag");
        }
        requireAuthoredText(
            appliedType.typeDefinitionName,
            "authored applied type-definition name",
            4'096
        );
        if (appliedType.byteCount == 0 ||
            appliedType.byteCount > kMaximumAuthoredStorageBytes) {
            throw ContractError("authored applied-object byte count is outside 1...1048576");
        }
        if (!appliedTypeKeys.emplace(
                appliedType.address,
                authoredRawValue(appliedType.subjectKind)
            ).second) {
            throw ContractError("duplicate authored applied-type semantic key");
        }
    }

    std::set<std::string> definitionKeys;
    for (const auto& definition : inputs.typeDefinitions) {
        if (!definitionKeys.insert(definition.name).second) {
            throw ContractError("duplicate authored type-definition name");
        }
        validateAuthoredDefinition(definition, aggregateMembers);
    }

    std::sort(inputs.names.begin(), inputs.names.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.address != rhs.address) return lhs.address < rhs.address;
        if (lhs.subjectKind != rhs.subjectKind) {
            return authoredRawValue(lhs.subjectKind) < authoredRawValue(rhs.subjectKind);
        }
        return exactUtf8BytesPrecede(lhs.name, rhs.name);
    });
    std::sort(
        inputs.signatures.begin(),
        inputs.signatures.end(),
        [](const auto& lhs, const auto& rhs) {
            return lhs.functionAddress < rhs.functionAddress;
        }
    );
    std::sort(
        inputs.calleeSignatureHints.begin(),
        inputs.calleeSignatureHints.end(),
        [](const auto& lhs, const auto& rhs) {
            return lhs.signature.functionAddress < rhs.signature.functionAddress;
        }
    );
    // Swift sorts by (storageKind, stackOffset, register) with byte-wise String order.
    std::sort(
        inputs.localNames.begin(),
        inputs.localNames.end(),
        [](const auto& lhs, const auto& rhs) {
            return std::make_tuple(static_cast<std::uint8_t>(lhs.storageKind), lhs.stackOffset, lhs.registerName) <
                std::make_tuple(static_cast<std::uint8_t>(rhs.storageKind), rhs.stackOffset, rhs.registerName);
        }
    );
    std::sort(
        inputs.appliedTypes.begin(),
        inputs.appliedTypes.end(),
        [](const auto& lhs, const auto& rhs) {
            if (lhs.address != rhs.address) return lhs.address < rhs.address;
            if (lhs.subjectKind != rhs.subjectKind) {
                return authoredRawValue(lhs.subjectKind) < authoredRawValue(rhs.subjectKind);
            }
            return exactUtf8BytesPrecede(lhs.typeDefinitionName, rhs.typeDefinitionName);
        }
    );
    std::sort(
        inputs.typeDefinitions.begin(),
        inputs.typeDefinitions.end(),
        [](const auto& lhs, const auto& rhs) {
            if (lhs.name != rhs.name) return exactUtf8BytesPrecede(lhs.name, rhs.name);
            return authoredRawValue(lhs.kind) < authoredRawValue(rhs.kind);
        }
    );
    return inputs;
}

AnalysisBudgets ProfiledAnalysisBudgets::analysisLimits() const noexcept {
    return AnalysisBudgets{
        maxCodeBytes,
        maxInstructions,
        maxOperations,
        maxOutputBytes,
        maxWallTimeMilliseconds,
    };
}

ProfiledAnalysisBudgets productAnalysisBudgetsV1() {
    return ProfiledAnalysisBudgets{
        "native-product-budget-v1",
        1'048'576,
        65'536,
        262'144,
        1'048'576,
        5'000,
    };
}

ProfiledAnalysisBudgets productAnalysisBudgetsV2() {
    auto profile = productAnalysisBudgetsV1();
    profile.profileId = "native-product-budget-v2";
    profile.maxOutputBytes = 8U * 1024U * 1024U;
    return profile;
}

ProfiledAnalysisBudgets productAnalysisBudgetsV3() {
    auto profile = productAnalysisBudgetsV1();
    profile.profileId = "native-product-budget-v3";
    profile.maxOutputBytes = 32U * 1024U * 1024U;
    return profile;
}

TargetProfile normalizeAppleMachOTarget(
    std::uint32_t rawCpuType,
    std::uint32_t rawCpuSubtype,
    std::string selectedSliceSha256,
    std::uint64_t selectedSliceByteCount
) {
    // Contract admission only; the native runtime still rejects this profile.
    if (rawCpuType == 0x0100'0007U && rawCpuSubtype == 3U) {
        if (!isCanonicalSha256(selectedSliceSha256)) {
            throw ContractError("selected-slice SHA-256 must be 64 lowercase hexadecimal characters");
        }
        if (selectedSliceByteCount == 0) {
            throw ContractError("selected-slice byte count must be positive");
        }
        return TargetProfile{
            canonicalLowercaseHexWord(rawCpuType), canonicalLowercaseHexWord(rawCpuSubtype),
            ArchitectureVariant::x86_64, "00000000", std::nullopt,
            std::move(selectedSliceSha256), selectedSliceByteCount,
            "apple-x86_64-sysv-v1", "x86:LE:64:default", "gcc",
            "5fd328d91f7f3a0f815136362f1fe60ba5749f1a72c2337b30c7b7765edf9deb",
            {TargetContextValue{"addrsize", 2}, TargetContextValue{"opsize", 1},
             TargetContextValue{"rexprefix", 0}, TargetContextValue{"longMode", 1}},
        };
    }
    constexpr std::uint32_t arm64CpuType = 0x0100'000cU;
    if (rawCpuType != arm64CpuType) {
        throw ContractError("unsupported raw Apple architecture");
    }

    ArchitectureVariant normalizedVariant;
    std::string recognizedCapabilityBits;
    std::optional<std::uint32_t> pointerAuthAbiVersion;
    switch (rawCpuSubtype) {
    case 0x0000'0000U:
        normalizedVariant = ArchitectureVariant::arm64;
        recognizedCapabilityBits = "00000000";
        break;
    case 0x8000'0000U:
        normalizedVariant = ArchitectureVariant::arm64;
        recognizedCapabilityBits = "80000000";
        break;
    case 0x0000'0002U:
        normalizedVariant = ArchitectureVariant::arm64e;
        recognizedCapabilityBits = "00000000";
        break;
    case 0x8000'0002U:
        normalizedVariant = ArchitectureVariant::arm64e;
        recognizedCapabilityBits = "80000000";
        pointerAuthAbiVersion = 0;
        break;
    default:
        throw ContractError("unsupported raw Apple architecture");
    }

    if (!isCanonicalSha256(selectedSliceSha256)) {
        throw ContractError("selected-slice SHA-256 must be 64 lowercase hexadecimal characters");
    }
    if (selectedSliceByteCount == 0) {
        throw ContractError("selected-slice byte count must be positive");
    }

    return TargetProfile{
        canonicalLowercaseHexWord(rawCpuType),
        canonicalLowercaseHexWord(rawCpuSubtype),
        normalizedVariant,
        std::move(recognizedCapabilityBits),
        pointerAuthAbiVersion,
        std::move(selectedSliceSha256),
        selectedSliceByteCount,
        "apple-aarch64-pac-visible-clobber-v1",
        "AARCH64:LE:64:AppleSilicon",
        "default",
        "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5",
        {
            TargetContextValue{"ShowPAC", 1},
            TargetContextValue{"PAC_clobber", 1},
            TargetContextValue{"ShowBTI", 0},
            TargetContextValue{"ShowMemTag", 0},
        },
    };
}

Address MemoryRegion::endAddressExclusive() const {
    return checkedEnd(startAddress, rawBytes.size(), "memory region");
}

bool MemoryRegion::readable() const noexcept { return permissions.size() == 3 && permissions[0] == 'r'; }
bool MemoryRegion::writable() const noexcept { return permissions.size() == 3 && permissions[1] == 'w'; }
bool MemoryRegion::executable() const noexcept { return permissions.size() == 3 && permissions[2] == 'x'; }

ByteProvider::ByteProvider(std::vector<MemoryRegion> regions) : regions_(std::move(regions)) {
    if (regions_.empty() || regions_.size() > kMaximumRegions) {
        throw ContractError("byte provider requires 1..256 memory regions");
    }
    std::sort(regions_.begin(), regions_.end(), [](const auto& lhs, const auto& rhs) {
        return std::tie(lhs.startAddress, lhs.name) < std::tie(rhs.startAddress, rhs.name);
    });

    std::size_t totalBytes = 0;
    Address previousEnd = 0;
    bool hasPrevious = false;
    std::vector<std::string> allPatchIds;
    for (const auto& region : regions_) {
        requireBoundedText(region.name, "memory-region name", 256);
        validatePermissions(region.permissions);
        if (region.rawBytes.empty() || region.effectiveBytes.empty()) {
            throw ContractError("memory regions must contain non-empty raw and effective byte views");
        }
        if (region.rawBytes.size() != region.effectiveBytes.size()) {
            throw ContractError("memory-region raw and effective byte views must have equal length");
        }
        if (region.rawBytes.size() > kMaximumTotalBytes - totalBytes) {
            throw ContractError("memory-region bytes exceed the fixed aggregate bound");
        }
        totalBytes += region.rawBytes.size();

        std::string previousPatchId;
        for (const auto& patchId : region.appliedPatchIds) {
            if (patchId.size() != 11 || !patchId.starts_with("patch") ||
                !std::all_of(patchId.begin() + 5, patchId.end(), [](unsigned char character) {
                    return character >= '0' && character <= '9';
                })) {
                throw ContractError("applied patch IDs must use canonical patchNNNNNN syntax");
            }
            if (!previousPatchId.empty() && patchId <= previousPatchId) {
                throw ContractError("applied patch IDs must be unique and strictly ordered per region");
            }
            previousPatchId = patchId;
            allPatchIds.push_back(patchId);
        }

        const Address end = region.endAddressExclusive();
        if (hasPrevious && region.startAddress < previousEnd) {
            throw ContractError("memory regions must not overlap");
        }
        previousEnd = end;
        hasPrevious = true;
    }
    std::sort(allPatchIds.begin(), allPatchIds.end());
    if (std::adjacent_find(allPatchIds.begin(), allPatchIds.end()) != allPatchIds.end()) {
        throw ContractError("applied patch IDs must be unique across the byte provider");
    }
}

const std::vector<MemoryRegion>& ByteProvider::regions() const noexcept { return regions_; }

std::vector<std::uint8_t> ByteProvider::readRaw(Address startAddress, std::size_t byteCount) const {
    return read(startAddress, byteCount, View::raw);
}

std::vector<std::uint8_t> ByteProvider::readEffective(Address startAddress, std::size_t byteCount) const {
    return read(startAddress, byteCount, View::effective);
}

std::vector<std::uint8_t> ByteProvider::read(
    Address startAddress,
    std::size_t byteCount,
    View view
) const {
    if (byteCount == 0) {
        return {};
    }
    const Address endAddress = checkedEnd(startAddress, byteCount, "requested memory");
    std::vector<std::uint8_t> output;
    output.reserve(byteCount);
    Address cursor = startAddress;

    for (const auto& region : regions_) {
        if (region.endAddressExclusive() <= cursor) {
            continue;
        }
        if (region.startAddress > cursor) {
            break;
        }
        if (!region.readable()) {
            throw ContractError("requested memory includes a non-readable region");
        }
        const Address takeEnd = std::min(endAddress, region.endAddressExclusive());
        const auto offset = static_cast<std::size_t>(cursor - region.startAddress);
        const auto count = static_cast<std::size_t>(takeEnd - cursor);
        const auto& source = view == View::raw ? region.rawBytes : region.effectiveBytes;
        output.insert(output.end(), source.begin() + static_cast<std::ptrdiff_t>(offset),
                      source.begin() + static_cast<std::ptrdiff_t>(offset + count));
        cursor = takeEnd;
        if (cursor == endAddress) {
            return output;
        }
    }
    throw ContractError("requested memory range is not fully mapped");
}

bool ByteProvider::contains(Address startAddress, std::size_t byteCount, bool requireExecutable) const {
    if (byteCount == 0) {
        return true;
    }
    Address endAddress = 0;
    try {
        endAddress = checkedEnd(startAddress, byteCount, "requested memory");
    } catch (const ContractError&) {
        return false;
    }
    Address cursor = startAddress;
    for (const auto& region : regions_) {
        if (region.endAddressExclusive() <= cursor) {
            continue;
        }
        if (region.startAddress > cursor || !region.readable() || (requireExecutable && !region.executable())) {
            return false;
        }
        cursor = std::min(endAddress, region.endAddressExclusive());
        if (cursor == endAddress) {
            return true;
        }
    }
    return false;
}

SymbolProvider::SymbolProvider(std::vector<SymbolRecord> symbols) : symbols_(std::move(symbols)) {
    if (symbols_.size() > kMaximumRecords) {
        throw ContractError("symbol collection exceeds the fixed bound");
    }
    for (const auto& symbol : symbols_) {
        requireBoundedText(symbol.imageId, "symbol image ID", 256);
        requireBoundedText(symbol.name, "symbol name", 1024);
        requireBoundedText(symbol.kind, "symbol kind", 256);
    }
    std::sort(symbols_.begin(), symbols_.end(), [](const auto& lhs, const auto& rhs) {
        return std::tie(lhs.address, lhs.kind, lhs.name, lhs.imageId) <
               std::tie(rhs.address, rhs.kind, rhs.name, rhs.imageId);
    });
    if (std::adjacent_find(symbols_.begin(), symbols_.end()) != symbols_.end()) {
        throw ContractError("duplicate symbol records are not permitted");
    }
}

const std::vector<SymbolRecord>& SymbolProvider::symbols() const noexcept { return symbols_; }

std::vector<SymbolRecord> SymbolProvider::exact(Address address) const {
    const auto lower = std::lower_bound(symbols_.begin(), symbols_.end(), address,
        [](const SymbolRecord& symbol, Address value) { return symbol.address < value; });
    const auto upper = std::upper_bound(lower, symbols_.end(), address,
        [](Address value, const SymbolRecord& symbol) { return value < symbol.address; });
    return {lower, upper};
}

std::optional<SymbolRecord> SymbolProvider::preferred(Address address) const {
    const auto candidates = exact(address);
    if (candidates.empty()) {
        return std::nullopt;
    }
    return candidates.front();
}

TypeHintProvider::TypeHintProvider(std::vector<TypeHintRecord> typeHints) : typeHints_(std::move(typeHints)) {
    if (typeHints_.size() > kMaximumRecords) {
        throw ContractError("type-hint collection exceeds the fixed bound");
    }
    for (const auto& hint : typeHints_) {
        requireBoundedText(hint.subjectKind, "type-hint subject kind", 256);
        requireBoundedText(hint.typeName, "type-hint name");
        requireBoundedText(hint.confidence, "type-hint confidence", 32);
        requireBoundedText(hint.source, "type-hint source", 256);
        if (hint.confidence != "asserted" && hint.confidence != "high" &&
            hint.confidence != "medium" && hint.confidence != "low") {
            throw ContractError("type-hint confidence is unsupported");
        }
    }
    std::sort(typeHints_.begin(), typeHints_.end(), [](const auto& lhs, const auto& rhs) {
        return std::tie(lhs.address, lhs.subjectKind, lhs.typeName, lhs.source, lhs.confidence) <
               std::tie(rhs.address, rhs.subjectKind, rhs.typeName, rhs.source, rhs.confidence);
    });
    if (std::adjacent_find(typeHints_.begin(), typeHints_.end()) != typeHints_.end()) {
        throw ContractError("duplicate type-hint records are not permitted");
    }
}

const std::vector<TypeHintRecord>& TypeHintProvider::typeHints() const noexcept { return typeHints_; }

std::vector<TypeHintRecord> TypeHintProvider::at(Address address) const {
    const auto lower = std::lower_bound(typeHints_.begin(), typeHints_.end(), address,
        [](const TypeHintRecord& hint, Address value) { return hint.address < value; });
    const auto upper = std::upper_bound(lower, typeHints_.end(), address,
        [](Address value, const TypeHintRecord& hint) { return value < hint.address; });
    return {lower, upper};
}

CancellationToken::CancellationToken(const std::atomic_bool* flag) noexcept : flag_(flag) {}

bool CancellationToken::isCancelled() const noexcept {
    return flag_ != nullptr && flag_->load(std::memory_order_relaxed);
}

void CancellationToken::throwIfCancelled() const {
    if (isCancelled()) {
        throw ContractError("analysis was cancelled");
    }
}

AnalysisRequestView::AnalysisRequestView(
    std::string requestIdValue,
    std::string requestSha256Value,
    std::string languageIdValue,
    std::string compilerSpecIdValue,
    ImageIdentity imageValue,
    FunctionIdentity functionValue,
    ByteProvider bytesValue,
    SymbolProvider symbolsValue,
    TypeHintProvider typeHintsValue,
    AnalysisBudgets budgetsValue,
    std::uint32_t schemaVersionValue
) : AnalysisRequestView(
    std::move(requestIdValue),
    std::move(requestSha256Value),
    std::move(languageIdValue),
    std::move(compilerSpecIdValue),
    std::move(imageValue),
    std::move(functionValue),
    std::move(bytesValue),
    std::move(symbolsValue),
    std::move(typeHintsValue),
    AuthoredInputs{},
    budgetsValue,
    schemaVersionValue
) {}

AnalysisRequestView::AnalysisRequestView(
    std::string requestIdValue,
    std::string requestSha256Value,
    std::string languageIdValue,
    std::string compilerSpecIdValue,
    ImageIdentity imageValue,
    FunctionIdentity functionValue,
    ByteProvider bytesValue,
    SymbolProvider symbolsValue,
    TypeHintProvider typeHintsValue,
    AuthoredInputs authoredInputsValue,
    AnalysisBudgets budgetsValue,
    std::uint32_t schemaVersionValue
) : requestId(std::move(requestIdValue)),
    requestSha256(std::move(requestSha256Value)),
    languageId(std::move(languageIdValue)),
    compilerSpecId(std::move(compilerSpecIdValue)),
    image(std::move(imageValue)),
    function(std::move(functionValue)),
    bytes(std::move(bytesValue)),
    symbols(std::move(symbolsValue)),
    typeHints(std::move(typeHintsValue)),
    authoredInputs(canonicalizedAuthoredInputs(std::move(authoredInputsValue))),
    budgets(budgetsValue),
    schemaVersion(schemaVersionValue) {
    requireBoundedText(requestId, "request ID", 256);
    if (requestSha256.size() != 64 || !std::all_of(requestSha256.begin(), requestSha256.end(), [](unsigned char c) {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        })) {
        throw ContractError("request SHA-256 must be 64 lowercase hexadecimal characters");
    }
    requireBoundedText(languageId, "language ID", 256);
    requireBoundedText(compilerSpecId, "compiler-spec ID", 256);
    requireBoundedText(image.imageId, "image ID", 256);
    requireBoundedText(image.uuid, "image UUID", 64);
    requireBoundedText(function.functionId, "function ID", 256);
    requireBoundedText(function.name, "function name", 1024);
    if (function.entryAddress >= function.endAddressExclusive) {
        throw ContractError("function extent must be non-empty and ordered");
    }
    if (budgets.maxCodeBytes == 0 || budgets.maxInstructions == 0 ||
        budgets.maxOperations == 0 || budgets.maxOutputBytes == 0 ||
        budgets.maxWallTimeMilliseconds == 0) {
        throw ContractError("analysis budgets must all be non-zero");
    }
    if (schemaVersion != 3U && schemaVersion != 4U) {
        throw ContractError("unsupported native request schema");
    }
    if (schemaVersion == 3U && !function.codeRanges.empty()) {
        throw ContractError("schema v3 cannot carry sparse function code ranges");
    }
    const auto ranges = function.codeRanges.empty()
        ? std::vector<FunctionIdentity::CodeRange>{{function.entryAddress, function.endAddressExclusive}}
        : function.codeRanges;
    if (schemaVersion == 4U && (function.codeRanges.empty() || ranges.size() > 64U ||
        ranges.front().startAddress != function.entryAddress ||
        ranges.back().endAddressExclusive != function.endAddressExclusive)) {
        throw ContractError("schema v4 function code ranges do not bind the function bounds");
    }
    // The wire adapter has already validated the exact sealed target tuple.
    // Legacy callers retain word alignment unless they select the closed x86 tuple.
    const bool x86SysV = languageId == "x86:LE:64:default" && compilerSpecId == "gcc";
    const Address codeAlignment = x86SysV ? 1U : 4U;
    std::size_t totalCodeBytes = 0;
    Address priorEnd = 0;
    for (const auto& range : ranges) {
        if (range.startAddress >= range.endAddressExclusive ||
            (schemaVersion == 4U &&
             (range.startAddress % codeAlignment != 0U || range.endAddressExclusive % codeAlignment != 0U ||
              (priorEnd != 0U && range.startAddress < priorEnd)))) {
            throw ContractError("function code ranges must be ordered nonoverlapping ARM64 words");
        }
        const Address rangeSize = range.endAddressExclusive - range.startAddress;
        if (rangeSize > std::numeric_limits<std::size_t>::max() ||
            rangeSize > budgets.maxCodeBytes - totalCodeBytes ||
            !bytes.contains(range.startAddress, static_cast<std::size_t>(rangeSize), true)) {
            throw ContractError("function code range must be mapped executable and within budget");
        }
        totalCodeBytes += static_cast<std::size_t>(rangeSize);
        priorEnd = range.endAddressExclusive;
    }
    for (const auto& symbol : symbols.symbols()) {
        if (symbol.imageId != image.imageId) {
            throw ContractError("symbol references a different image");
        }
    }
}

std::vector<std::uint8_t> AnalysisRequestView::functionBytes() const {
    return effectiveFunctionBytes();
}

std::vector<std::uint8_t> AnalysisRequestView::rawFunctionBytes() const {
    std::vector<std::uint8_t> result;
    const auto ranges = function.codeRanges.empty()
        ? std::vector<FunctionIdentity::CodeRange>{{function.entryAddress, function.endAddressExclusive}}
        : function.codeRanges;
    for (const auto& range : ranges) {
        auto part = bytes.readRaw(range.startAddress, static_cast<std::size_t>(range.endAddressExclusive - range.startAddress));
        result.insert(result.end(), part.begin(), part.end());
    }
    return result;
}

std::vector<std::uint8_t> AnalysisRequestView::effectiveFunctionBytes() const {
    std::vector<std::uint8_t> result;
    const auto ranges = function.codeRanges.empty()
        ? std::vector<FunctionIdentity::CodeRange>{{function.entryAddress, function.endAddressExclusive}}
        : function.codeRanges;
    for (const auto& range : ranges) {
        auto part = bytes.readEffective(range.startAddress, static_cast<std::size_t>(range.endAddressExclusive - range.startAddress));
        result.insert(result.end(), part.begin(), part.end());
    }
    return result;
}

} // namespace macscope::native_decompiler
