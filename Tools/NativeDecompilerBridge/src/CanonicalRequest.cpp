#include "CanonicalRequest.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>

namespace macscope::native_decompiler {
namespace {

constexpr std::uint64_t kCanonicalStreamVersion = 2;
constexpr std::string_view kOperation = "decompile";
constexpr std::string_view kDocumentOperation = "decompile-document";
constexpr std::size_t kMaximumCanonicalAuthoredBytes = 1'048'576;
constexpr std::string_view kAuthoredDomain =
    "org.macscope.MacScope.native-authored-input.v1";
constexpr std::string_view kContextProfileDomain =
    "org.macscope.MacScope.native-context-profile.v1";
constexpr std::string_view kContextProfileId =
    "apple-aarch64-pac-visible-clobber-v1";
constexpr std::string_view kLanguageId = "AARCH64:LE:64:AppleSilicon";
constexpr std::string_view kCompilerSpecId = "default";

using Bytes = std::vector<std::uint8_t>;

[[nodiscard]] std::span<const std::uint8_t> byteSpan(std::string_view value) noexcept {
    return {
        reinterpret_cast<const std::uint8_t*>(value.data()),
        value.size(),
    };
}

void appendToken(Bytes& output, std::span<const std::uint8_t> value) {
    const auto length = std::to_string(value.size());
    output.insert(output.end(), length.begin(), length.end());
    output.push_back(static_cast<std::uint8_t>(':'));
    output.insert(output.end(), value.begin(), value.end());
    output.push_back(static_cast<std::uint8_t>('\n'));
}

void appendField(
    Bytes& output,
    std::string_view name,
    std::span<const std::uint8_t> value
) {
    appendToken(output, byteSpan(name));
    appendToken(output, value);
}

void appendTextField(Bytes& output, std::string_view name, std::string_view value) {
    appendField(output, name, byteSpan(value));
}

void appendDecimalField(Bytes& output, std::string_view name, std::uint64_t value) {
    const auto text = std::to_string(value);
    appendTextField(output, name, text);
}

void appendDecimalBooleanField(Bytes& output, std::string_view name, bool value) {
    appendDecimalField(output, name, value ? 1U : 0U);
}

[[nodiscard]] std::array<std::uint8_t, 8> bigEndianBytes(std::uint64_t value) noexcept {
    return {
        static_cast<std::uint8_t>(value >> 56U),
        static_cast<std::uint8_t>(value >> 48U),
        static_cast<std::uint8_t>(value >> 40U),
        static_cast<std::uint8_t>(value >> 32U),
        static_cast<std::uint8_t>(value >> 24U),
        static_cast<std::uint8_t>(value >> 16U),
        static_cast<std::uint8_t>(value >> 8U),
        static_cast<std::uint8_t>(value),
    };
}

[[nodiscard]] std::array<std::uint8_t, 4> bigEndianBytes(std::int32_t value) noexcept {
    const auto bits = static_cast<std::uint32_t>(value);
    return {
        static_cast<std::uint8_t>(bits >> 24U),
        static_cast<std::uint8_t>(bits >> 16U),
        static_cast<std::uint8_t>(bits >> 8U),
        static_cast<std::uint8_t>(bits),
    };
}

template <typename Enumeration>
[[nodiscard]] constexpr std::uint8_t rawByte(Enumeration value) noexcept {
    static_assert(std::is_enum_v<Enumeration>);
    return static_cast<std::uint8_t>(value);
}

[[nodiscard]] std::string indexedPrefix(std::string_view prefix, std::size_t index) {
    return std::string(prefix) + "[" + std::to_string(index) + "]";
}

class AuthoredWriter final {
public:
    void appendText(std::string_view name, std::string_view value) {
        appendChecked(name, byteSpan(value));
    }

    void appendUInt64(std::string_view name, std::uint64_t value) {
        const auto encoded = bigEndianBytes(value);
        appendChecked(name, encoded);
    }

    void appendInt32(std::string_view name, std::int32_t value) {
        const auto encoded = bigEndianBytes(value);
        appendChecked(name, encoded);
    }

    void appendByte(std::string_view name, std::uint8_t value) {
        appendChecked(name, std::span(&value, 1U));
    }

    void appendBoolean(std::string_view name, bool value) {
        appendByte(name, value ? 1U : 0U);
    }

    void appendOptionalUInt64(
        const std::optional<std::uint64_t>& value,
        std::string_view prefix
    ) {
        appendBoolean(std::string(prefix) + ".present", value.has_value());
        if (value.has_value()) {
            appendUInt64(std::string(prefix) + ".value", *value);
        }
    }

    [[nodiscard]] const Bytes& bytes() const noexcept { return bytes_; }
    [[nodiscard]] std::size_t size() const noexcept { return bytes_.size(); }

private:
    void appendChecked(std::string_view name, std::span<const std::uint8_t> value) {
        appendField(bytes_, name, value);
        if (bytes_.size() > kMaximumCanonicalAuthoredBytes) {
            throw ContractError("canonical authored input exceeds 1048576 bytes");
        }
    }

    Bytes bytes_;
};

void appendCanonicalType(
    AuthoredWriter& output,
    const AuthoredType& type,
    std::string_view prefix,
    std::uint64_t depth
);

void appendCanonicalStorage(
    AuthoredWriter& output,
    const AuthoredFieldStorage& storage,
    std::string_view prefix,
    std::uint64_t depth
);

void appendCanonicalLayoutRules(
    AuthoredWriter& output,
    const AuthoredLayoutRules& rules,
    std::string_view prefix
) {
    output.appendBoolean(std::string(prefix) + ".isPacked", rules.isPacked);
    output.appendOptionalUInt64(rules.packAlignment, std::string(prefix) + ".packAlignment");
    output.appendOptionalUInt64(
        rules.minimumAlignment,
        std::string(prefix) + ".minimumAlignment"
    );
}

void appendCanonicalRecordField(
    AuthoredWriter& output,
    const AuthoredRecordField& field,
    std::string_view prefix,
    std::uint64_t storageDepth
) {
    output.appendText(std::string(prefix) + ".name", field.name);
    appendCanonicalStorage(
        output,
        *field.storage,
        std::string(prefix) + ".storage",
        storageDepth
    );
    output.appendOptionalUInt64(field.bitWidth, std::string(prefix) + ".bitWidth");
    output.appendOptionalUInt64(
        field.minimumAlignment,
        std::string(prefix) + ".minimumAlignment"
    );
    output.appendBoolean(
        std::string(prefix) + ".minimumAlignmentType.present",
        field.minimumAlignmentType != nullptr
    );
    if (field.minimumAlignmentType != nullptr) {
        appendCanonicalType(
            output,
            *field.minimumAlignmentType,
            std::string(prefix) + ".minimumAlignmentType",
            storageDepth + 1U
        );
    }
    output.appendBoolean(
        std::string(prefix) + ".promotesInlineFields",
        field.promotesInlineFields
    );
}

void appendCanonicalType(
    AuthoredWriter& output,
    const AuthoredType& type,
    std::string_view prefix,
    std::uint64_t depth
) {
    output.appendByte(std::string(prefix) + ".tag", rawByte(type.tag));
    output.appendUInt64(std::string(prefix) + ".depth", depth);
    switch (type.tag) {
    case AuthoredTypeTag::qualifiedValue: {
        const auto& qualified = std::get<AuthoredQualifiedValue>(type.payload);
        output.appendByte(std::string(prefix) + ".atom.tag", rawByte(qualified.atom.tag));
        switch (qualified.atom.tag) {
        case AuthoredAtomTag::void_:
            break;
        case AuthoredAtomTag::scalar:
            output.appendByte(
                std::string(prefix) + ".atom.scalarKind",
                rawByte(std::get<AuthoredScalarKind>(qualified.atom.payload))
            );
            break;
        case AuthoredAtomTag::darwinAlias:
            output.appendByte(
                std::string(prefix) + ".atom.darwinAliasKind",
                rawByte(std::get<AuthoredDarwinAliasKind>(qualified.atom.payload))
            );
            break;
        case AuthoredAtomTag::named: {
            const auto& named = std::get<AuthoredNamedAtom>(qualified.atom.payload);
            output.appendByte(std::string(prefix) + ".atom.namedKind", rawByte(named.kind));
            output.appendText(std::string(prefix) + ".atom.name", named.name);
            break;
        }
        }
        output.appendByte(std::string(prefix) + ".qualifiers", qualified.qualifiers);
        break;
    }
    case AuthoredTypeTag::dataPointer: {
        const auto& pointer = std::get<AuthoredDataPointer>(type.payload);
        appendCanonicalType(
            output,
            *pointer.pointee,
            std::string(prefix) + ".pointee",
            depth + 1U
        );
        output.appendUInt64(
            std::string(prefix) + ".indirectionLevel",
            pointer.indirectionLevel
        );
        output.appendUInt64(
            std::string(prefix) + ".pointerQualifiers.count",
            pointer.pointerQualifiersByLevel.size()
        );
        for (std::size_t index = 0; index < pointer.pointerQualifiersByLevel.size(); ++index) {
            output.appendByte(
                indexedPrefix(std::string(prefix) + ".pointerQualifiers", index),
                pointer.pointerQualifiersByLevel[index]
            );
        }
        break;
    }
    }
}

void appendCanonicalStorage(
    AuthoredWriter& output,
    const AuthoredFieldStorage& storage,
    std::string_view prefix,
    std::uint64_t depth
) {
    output.appendByte(std::string(prefix) + ".tag", rawByte(storage.tag));
    output.appendUInt64(std::string(prefix) + ".depth", depth);
    switch (storage.tag) {
    case AuthoredFieldStorageTag::value: {
        const auto& value = std::get<AuthoredValueStorage>(storage.payload);
        appendCanonicalType(output, value.type, std::string(prefix) + ".type", depth);
        break;
    }
    case AuthoredFieldStorageTag::fixedArray: {
        const auto& array = std::get<AuthoredFixedArrayStorage>(storage.payload);
        output.appendUInt64(std::string(prefix) + ".count", array.count);
        appendCanonicalStorage(
            output,
            *array.element,
            std::string(prefix) + ".element",
            depth + 1U
        );
        break;
    }
    case AuthoredFieldStorageTag::flexibleArray: {
        const auto& array = std::get<AuthoredFlexibleArrayStorage>(storage.payload);
        appendCanonicalStorage(
            output,
            *array.element,
            std::string(prefix) + ".element",
            depth + 1U
        );
        break;
    }
    case AuthoredFieldStorageTag::opaquePointerCarrier: {
        const auto& carrier = std::get<AuthoredOpaquePointerCarrierStorage>(storage.payload);
        output.appendByte(std::string(prefix) + ".kind", rawByte(carrier.kind));
        break;
    }
    case AuthoredFieldStorageTag::inlineAggregate: {
        const auto& aggregate = std::get<AuthoredInlineAggregateStorage>(storage.payload);
        output.appendByte(std::string(prefix) + ".kind", rawByte(aggregate.kind));
        appendCanonicalLayoutRules(
            output,
            aggregate.layoutRules,
            std::string(prefix) + ".layoutRules"
        );
        output.appendUInt64(
            std::string(prefix) + ".fields.count",
            aggregate.fields.size()
        );
        for (std::size_t index = 0; index < aggregate.fields.size(); ++index) {
            appendCanonicalRecordField(
                output,
                aggregate.fields[index],
                indexedPrefix(std::string(prefix) + ".fields", index),
                depth + 1U
            );
        }
        break;
    }
    }
}

void appendCanonicalSignature(
    AuthoredWriter& output,
    const AuthoredSignature& signature,
    const std::string& itemPrefix
) {
    output.appendUInt64(itemPrefix + ".functionAddress", signature.functionAddress);
    output.appendBoolean(
        itemPrefix + ".returnType.present",
        signature.returnType != nullptr
    );
    if (signature.returnType != nullptr) {
        appendCanonicalType(
            output,
            *signature.returnType,
            itemPrefix + ".returnType",
            0
        );
    }
    output.appendByte(
        itemPrefix + ".parameterListState",
        rawByte(signature.parameterListState)
    );
    output.appendUInt64(itemPrefix + ".parameters.count", signature.parameters.size());
    for (std::size_t parameterIndex = 0;
         parameterIndex < signature.parameters.size();
         ++parameterIndex) {
        const auto parameterPrefix = indexedPrefix(
            itemPrefix + ".parameters",
            parameterIndex
        );
        const auto& parameter = signature.parameters[parameterIndex];
        output.appendText(parameterPrefix + ".name", parameter.name);
        appendCanonicalType(
            output,
            parameter.type,
            parameterPrefix + ".type",
            0
        );
        if (parameter.storageRegister) {
            output.appendText(parameterPrefix + ".storage", *parameter.storageRegister);
        }
    }
    output.appendByte(itemPrefix + ".variadicState", rawByte(signature.variadicState));
    output.appendByte(itemPrefix + ".noReturnState", rawByte(signature.noReturnState));
}

void appendCanonicalAuthoredFields(
    AuthoredWriter& output,
    const AuthoredInputs& inputs,
    std::string_view prefix
) {
    output.appendUInt64(std::string(prefix) + ".schemaVersion", inputs.schemaVersion);

    output.appendUInt64(std::string(prefix) + ".names.count", inputs.names.size());
    for (std::size_t index = 0; index < inputs.names.size(); ++index) {
        const auto itemPrefix = indexedPrefix(std::string(prefix) + ".names", index);
        const auto& name = inputs.names[index];
        output.appendUInt64(itemPrefix + ".address", name.address);
        output.appendByte(itemPrefix + ".subjectKind", rawByte(name.subjectKind));
        output.appendText(itemPrefix + ".name", name.name);
    }

    output.appendUInt64(
        std::string(prefix) + ".signatures.count",
        inputs.signatures.size()
    );
    for (std::size_t index = 0; index < inputs.signatures.size(); ++index) {
        appendCanonicalSignature(
            output,
            inputs.signatures[index],
            indexedPrefix(std::string(prefix) + ".signatures", index)
        );
    }

    output.appendUInt64(
        std::string(prefix) + ".appliedTypes.count",
        inputs.appliedTypes.size()
    );
    for (std::size_t index = 0; index < inputs.appliedTypes.size(); ++index) {
        const auto itemPrefix = indexedPrefix(std::string(prefix) + ".appliedTypes", index);
        const auto& appliedType = inputs.appliedTypes[index];
        output.appendUInt64(itemPrefix + ".address", appliedType.address);
        output.appendByte(itemPrefix + ".subjectKind", rawByte(appliedType.subjectKind));
        output.appendText(itemPrefix + ".typeDefinitionName", appliedType.typeDefinitionName);
        output.appendUInt64(itemPrefix + ".byteCount", appliedType.byteCount);
    }

    output.appendUInt64(
        std::string(prefix) + ".typeDefinitions.count",
        inputs.typeDefinitions.size()
    );
    for (std::size_t index = 0; index < inputs.typeDefinitions.size(); ++index) {
        const auto itemPrefix = indexedPrefix(
            std::string(prefix) + ".typeDefinitions",
            index
        );
        const auto& definition = inputs.typeDefinitions[index];
        output.appendByte(itemPrefix + ".kind", rawByte(definition.kind));
        output.appendText(itemPrefix + ".name", definition.name);
        switch (definition.kind) {
        case AuthoredTypeDefinitionKind::recordStruct:
        case AuthoredTypeDefinitionKind::recordUnion: {
            const auto& record = std::get<AuthoredRecordDefinition>(definition.payload);
            appendCanonicalLayoutRules(
                output,
                record.layoutRules,
                itemPrefix + ".layoutRules"
            );
            output.appendUInt64(itemPrefix + ".fields.count", record.fields.size());
            for (std::size_t fieldIndex = 0; fieldIndex < record.fields.size(); ++fieldIndex) {
                appendCanonicalRecordField(
                    output,
                    record.fields[fieldIndex],
                    indexedPrefix(itemPrefix + ".fields", fieldIndex),
                    0
                );
            }
            break;
        }
        case AuthoredTypeDefinitionKind::enumeration: {
            const auto& enumeration =
                std::get<AuthoredEnumerationDefinition>(definition.payload);
            output.appendByte(
                itemPrefix + ".representation",
                rawByte(enumeration.representation)
            );
            output.appendUInt64(itemPrefix + ".cases.count", enumeration.cases.size());
            for (std::size_t caseIndex = 0; caseIndex < enumeration.cases.size(); ++caseIndex) {
                const auto casePrefix = indexedPrefix(itemPrefix + ".cases", caseIndex);
                output.appendText(casePrefix + ".name", enumeration.cases[caseIndex].name);
                output.appendInt32(casePrefix + ".value", enumeration.cases[caseIndex].value);
            }
            break;
        }
        case AuthoredTypeDefinitionKind::typedef_: {
            const auto& typeAlias = std::get<AuthoredTypedefDefinition>(definition.payload);
            appendCanonicalStorage(output, *typeAlias.target, itemPrefix + ".target", 0);
            break;
        }
        }
    }
    // Authored-input schema v2 appends callee signature hints; v1 bytes are unchanged.
    if (inputs.schemaVersion >= 2U) {
        output.appendUInt64(
            std::string(prefix) + ".calleeSignatureHints.count",
            inputs.calleeSignatureHints.size()
        );
        for (std::size_t index = 0; index < inputs.calleeSignatureHints.size(); ++index) {
            const auto itemPrefix = indexedPrefix(
                std::string(prefix) + ".calleeSignatureHints",
                index
            );
            const auto& hint = inputs.calleeSignatureHints[index];
            output.appendText(itemPrefix + ".name", hint.name);
            output.appendByte(itemPrefix + ".source", rawByte(hint.source));
            appendCanonicalSignature(output, hint.signature, itemPrefix + ".signature");
        }
    }
    // Authored-input schema v3 appends local names; v1/v2 bytes are unchanged.
    if (inputs.schemaVersion >= 3U) {
        output.appendUInt64(std::string(prefix) + ".localNames.count", inputs.localNames.size());
        for (std::size_t index = 0; index < inputs.localNames.size(); ++index) {
            const auto itemPrefix = indexedPrefix(std::string(prefix) + ".localNames", index);
            const auto& local = inputs.localNames[index];
            output.appendByte(itemPrefix + ".storageKind", rawByte(local.storageKind));
            output.appendInt32(itemPrefix + ".stackOffset", local.stackOffset);
            output.appendUInt64(itemPrefix + ".byteSize", local.byteSize);
            output.appendText(itemPrefix + ".register", local.registerName);
            output.appendText(itemPrefix + ".name", local.name);
            output.appendBoolean(itemPrefix + ".type.present", local.type != nullptr);
            if (local.type != nullptr) appendCanonicalType(output, *local.type, itemPrefix + ".type", 0);
        }
    }
}

[[nodiscard]] bool exactBytesPrecede(std::string_view lhs, std::string_view rhs) {
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

[[nodiscard]] std::string_view normalizedVariantName(ArchitectureVariant variant) {
    switch (variant) {
    case ArchitectureVariant::arm64:
        return "arm64";
    case ArchitectureVariant::arm64e:
        return "arm64e";
    case ArchitectureVariant::x86_64:
        return "x86_64";
    }
    throw ContractError("unknown normalized architecture variant");
}

[[nodiscard]] std::string asciiLowercased(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        if (character >= 'A' && character <= 'Z') {
            return static_cast<char>(character - 'A' + 'a');
        }
        return static_cast<char>(character);
    });
    return value;
}

class Sha256 final {
public:
    void update(std::span<const std::uint8_t> input) {
        totalBytes_ += input.size();
        for (const auto byte : input) {
            block_[blockSize_++] = byte;
            if (blockSize_ == block_.size()) {
                transform();
                blockSize_ = 0;
            }
        }
    }

    [[nodiscard]] std::string finish() {
        const std::uint64_t bitCount = totalBytes_ * 8U;
        block_[blockSize_++] = 0x80U;
        if (blockSize_ > 56U) {
            std::fill(
                block_.begin() + static_cast<std::ptrdiff_t>(blockSize_),
                block_.end(),
                0U
            );
            transform();
            blockSize_ = 0;
        }
        std::fill(
            block_.begin() + static_cast<std::ptrdiff_t>(blockSize_),
            block_.begin() + 56,
            0U
        );
        for (std::size_t index = 0; index < 8U; ++index) {
            block_[63U - index] = static_cast<std::uint8_t>(bitCount >> (index * 8U));
        }
        transform();

        constexpr char hexadecimal[] = "0123456789abcdef";
        std::string result(64U, '0');
        for (std::size_t word = 0; word < state_.size(); ++word) {
            for (std::size_t byte = 0; byte < 4U; ++byte) {
                const auto value = static_cast<std::uint8_t>(
                    state_[word] >> ((3U - byte) * 8U)
                );
                result[(word * 8U) + (byte * 2U)] = hexadecimal[value >> 4U];
                result[(word * 8U) + (byte * 2U) + 1U] = hexadecimal[value & 0x0fU];
            }
        }
        return result;
    }

private:
    static constexpr std::array<std::uint32_t, 64> kRoundConstants = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
        0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
        0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
        0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
        0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
        0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
        0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
        0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
        0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
        0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
        0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
        0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
        0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
        0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
        0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
    };

    [[nodiscard]] static std::uint32_t rotateRight(
        std::uint32_t value,
        unsigned amount
    ) noexcept {
        return (value >> amount) | (value << (32U - amount));
    }

    void transform() {
        std::array<std::uint32_t, 64> schedule{};
        for (std::size_t index = 0; index < 16U; ++index) {
            const auto offset = index * 4U;
            schedule[index] = (static_cast<std::uint32_t>(block_[offset]) << 24U) |
                (static_cast<std::uint32_t>(block_[offset + 1U]) << 16U) |
                (static_cast<std::uint32_t>(block_[offset + 2U]) << 8U) |
                static_cast<std::uint32_t>(block_[offset + 3U]);
        }
        for (std::size_t index = 16U; index < schedule.size(); ++index) {
            const auto lower = schedule[index - 15U];
            const auto upper = schedule[index - 2U];
            const auto sigma0 = rotateRight(lower, 7U) ^
                rotateRight(lower, 18U) ^ (lower >> 3U);
            const auto sigma1 = rotateRight(upper, 17U) ^
                rotateRight(upper, 19U) ^ (upper >> 10U);
            schedule[index] = schedule[index - 16U] + sigma0 +
                schedule[index - 7U] + sigma1;
        }

        auto a = state_[0];
        auto b = state_[1];
        auto c = state_[2];
        auto d = state_[3];
        auto e = state_[4];
        auto f = state_[5];
        auto g = state_[6];
        auto h = state_[7];
        for (std::size_t index = 0; index < schedule.size(); ++index) {
            const auto sum1 = rotateRight(e, 6U) ^ rotateRight(e, 11U) ^
                rotateRight(e, 25U);
            const auto choose = (e & f) ^ (~e & g);
            const auto temporary1 = h + sum1 + choose +
                kRoundConstants[index] + schedule[index];
            const auto sum0 = rotateRight(a, 2U) ^ rotateRight(a, 13U) ^
                rotateRight(a, 22U);
            const auto majority = (a & b) ^ (a & c) ^ (b & c);
            const auto temporary2 = sum0 + majority;
            h = g;
            g = f;
            f = e;
            e = d + temporary1;
            d = c;
            c = b;
            b = a;
            a = temporary1 + temporary2;
        }
        state_[0] += a;
        state_[1] += b;
        state_[2] += c;
        state_[3] += d;
        state_[4] += e;
        state_[5] += f;
        state_[6] += g;
        state_[7] += h;
    }

    std::array<std::uint32_t, 8> state_ = {
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
    };
    std::array<std::uint8_t, 64> block_{};
    std::size_t blockSize_ = 0;
    std::uint64_t totalBytes_ = 0;
};

} // namespace

std::vector<std::uint8_t> canonicalRequestV2(const CanonicalRequestV2View& request) {
    const auto& target = request.target.get();
    const auto& image = request.image.get();
    const auto& function = request.function.get();
    const auto& bytes = request.bytes.get();
    const auto& symbols = request.symbols.get();
    const auto authoredInputs = canonicalizedAuthoredInputs(request.authoredInputs.get());
    const auto& budgets = request.budgets.get();

    AuthoredWriter authoredSection;
    authoredSection.appendText("domain", kAuthoredDomain);
    const auto authoredDomainFrameByteCount = authoredSection.size();
    appendCanonicalAuthoredFields(authoredSection, authoredInputs, "authoredInputs");

    Bytes output;
    appendDecimalField(output, "canonicalStreamVersion", kCanonicalStreamVersion);
    if (request.schemaVersion != 3U && request.schemaVersion != 4U) {
        throw ContractError("unsupported native canonical request schema");
    }
    appendDecimalField(output, "schemaVersion", request.schemaVersion);
    if (request.operation != kOperation && request.operation != kDocumentOperation) {
        throw ContractError("unsupported native canonical request operation");
    }
    appendTextField(output, "operation", request.operation);

    appendTextField(output, "target.rawCPUType", target.rawCpuType);
    appendTextField(output, "target.rawCPUSubtype", target.rawCpuSubtype);
    appendTextField(
        output,
        "target.normalizedVariant",
        normalizedVariantName(target.normalizedVariant)
    );
    appendTextField(
        output,
        "target.recognizedCapabilityBits",
        target.recognizedCapabilityBits
    );
    appendDecimalBooleanField(
        output,
        "target.pointerAuthABIVersion.present",
        target.pointerAuthAbiVersion.has_value()
    );
    if (target.pointerAuthAbiVersion.has_value()) {
        appendDecimalField(
            output,
            "target.pointerAuthABIVersion.value",
            *target.pointerAuthAbiVersion
        );
    }
    appendTextField(output, "target.selectedSliceSHA256", target.selectedSliceSha256);
    appendDecimalField(
        output,
        "target.selectedSliceByteCount",
        target.selectedSliceByteCount
    );
    appendTextField(output, "target.profileID", target.profileId);
    appendTextField(output, "target.languageID", target.languageId);
    appendTextField(output, "target.compilerSpecID", target.compilerSpecId);
    appendTextField(output, "target.contextProfileSHA256", target.contextProfileSha256);
    appendDecimalField(output, "target.context.count", target.context.size());
    for (std::size_t index = 0; index < target.context.size(); ++index) {
        const auto prefix = indexedPrefix("target.context", index);
        appendTextField(output, prefix + ".name", target.context[index].name);
        appendDecimalField(output, prefix + ".value", target.context[index].value);
    }

    appendTextField(output, "image.imageID", image.imageId);
    appendTextField(output, "image.uuid", asciiLowercased(image.uuid));
    appendDecimalField(
        output,
        "image.preferredLoadAddress",
        image.preferredLoadAddress
    );

    appendTextField(output, "function.functionID", function.functionId);
    appendTextField(output, "function.name", function.name);
    appendDecimalField(output, "function.entryAddress", function.entryAddress);
    appendDecimalField(
        output,
        "function.endAddressExclusive",
        function.endAddressExclusive
    );
    if (request.schemaVersion == 4U) {
        appendDecimalField(output, "function.codeRanges.count", function.codeRanges.size());
        for (std::size_t index = 0; index < function.codeRanges.size(); ++index) {
            const auto prefix = indexedPrefix("function.codeRanges", index);
            appendDecimalField(output, prefix + ".startAddress", function.codeRanges[index].startAddress);
            appendDecimalField(output, prefix + ".endAddressExclusive", function.codeRanges[index].endAddressExclusive);
        }
    } else if (!function.codeRanges.empty()) {
        throw ContractError("schema v3 canonical request cannot carry sparse function code ranges");
    }

    std::vector<std::reference_wrapper<const MemoryRegion>> regions;
    regions.reserve(bytes.regions().size());
    for (const auto& region : bytes.regions()) regions.emplace_back(std::cref(region));
    std::sort(regions.begin(), regions.end(), [](const auto& lhsReference, const auto& rhsReference) {
        const auto& lhs = lhsReference.get();
        const auto& rhs = rhsReference.get();
        if (lhs.startAddress != rhs.startAddress) return lhs.startAddress < rhs.startAddress;
        return exactBytesPrecede(lhs.name, rhs.name);
    });
    appendDecimalField(output, "memoryRegions.count", regions.size());
    for (std::size_t index = 0; index < regions.size(); ++index) {
        const auto prefix = indexedPrefix("memoryRegions", index);
        const auto& region = regions[index].get();
        appendTextField(output, prefix + ".name", region.name);
        appendDecimalField(output, prefix + ".startAddress", region.startAddress);
        appendTextField(output, prefix + ".permissions", region.permissions);
        appendField(output, prefix + ".rawBytes", region.rawBytes);
        appendField(output, prefix + ".effectiveBytes", region.effectiveBytes);
        appendDecimalField(
            output,
            prefix + ".appliedPatchIDs.count",
            region.appliedPatchIds.size()
        );
        for (std::size_t patchIndex = 0;
             patchIndex < region.appliedPatchIds.size();
             ++patchIndex) {
            appendTextField(
                output,
                indexedPrefix(prefix + ".appliedPatchIDs", patchIndex),
                region.appliedPatchIds[patchIndex]
            );
        }
    }

    std::vector<std::reference_wrapper<const SymbolRecord>> sortedSymbols;
    sortedSymbols.reserve(symbols.symbols().size());
    for (const auto& symbol : symbols.symbols()) sortedSymbols.emplace_back(std::cref(symbol));
    std::sort(
        sortedSymbols.begin(),
        sortedSymbols.end(),
        [](const auto& lhsReference, const auto& rhsReference) {
            const auto& lhs = lhsReference.get();
            const auto& rhs = rhsReference.get();
            if (lhs.address != rhs.address) return lhs.address < rhs.address;
            if (lhs.kind != rhs.kind) return exactBytesPrecede(lhs.kind, rhs.kind);
            if (lhs.name != rhs.name) return exactBytesPrecede(lhs.name, rhs.name);
            return exactBytesPrecede(lhs.imageId, rhs.imageId);
        }
    );
    appendDecimalField(output, "symbols.count", sortedSymbols.size());
    for (std::size_t index = 0; index < sortedSymbols.size(); ++index) {
        const auto prefix = indexedPrefix("symbols", index);
        const auto& symbol = sortedSymbols[index].get();
        appendTextField(output, prefix + ".imageID", symbol.imageId);
        appendDecimalField(output, prefix + ".address", symbol.address);
        appendTextField(output, prefix + ".name", symbol.name);
        appendTextField(output, prefix + ".kind", symbol.kind);
    }

    output.insert(
        output.end(),
        authoredSection.bytes().begin() +
            static_cast<std::ptrdiff_t>(authoredDomainFrameByteCount),
        authoredSection.bytes().end()
    );

    appendTextField(output, "budgets.profileID", budgets.profileId);
    appendDecimalField(output, "budgets.maxCodeBytes", budgets.maxCodeBytes);
    appendDecimalField(output, "budgets.maxInstructions", budgets.maxInstructions);
    appendDecimalField(output, "budgets.maxOperations", budgets.maxOperations);
    appendDecimalField(output, "budgets.maxOutputBytes", budgets.maxOutputBytes);
    appendDecimalField(
        output,
        "budgets.maxWallTimeMilliseconds",
        budgets.maxWallTimeMilliseconds
    );
    return output;
}

std::string canonicalRequestSha256V2(const CanonicalRequestV2View& request) {
    const auto bytes = canonicalRequestV2(request);
    Sha256 digest;
    digest.update(bytes);
    return digest.finish();
}

std::vector<std::uint8_t> canonicalContextProfileV1(ArchitectureVariant variant) {
    // Reject invalid enum values; no caller-supplied language or context is admitted.
    (void)normalizedVariantName(variant);
    const bool x86 = variant == ArchitectureVariant::x86_64;
    Bytes output;
    appendTextField(output, "domain", kContextProfileDomain);
    appendTextField(output, "profileID", x86 ? "apple-x86_64-sysv-v1" : kContextProfileId);
    appendTextField(output, "languageID", x86 ? "x86:LE:64:default" : kLanguageId);
    appendTextField(output, "compilerSpecID", x86 ? "gcc" : kCompilerSpecId);

    const std::array<std::pair<std::string_view, std::uint64_t>, 4> context = x86
        ? std::array<std::pair<std::string_view, std::uint64_t>, 4>{{
            {"addrsize", 2}, {"opsize", 1}, {"rexprefix", 0}, {"longMode", 1},
        }}
        : std::array<std::pair<std::string_view, std::uint64_t>, 4>{{
        {"ShowPAC", 1},
        {"PAC_clobber", 1},
        {"ShowBTI", 0},
        {"ShowMemTag", 0},
    }};
    appendDecimalField(output, "context.count", context.size());
    for (std::size_t index = 0; index < context.size(); ++index) {
        const auto prefix = indexedPrefix("context", index);
        appendTextField(output, prefix + ".name", context[index].first);
        appendDecimalField(output, prefix + ".value", context[index].second);
    }
    return output;
}

} // namespace macscope::native_decompiler
