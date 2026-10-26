#include "MacScopeNativeDecompiler/GhidraProvider.hpp"

#include "BlockPartition.hpp"
#include "BoundedUTF8StreamBuffer.hpp"
#include "GhidraArchitectureInternal.hpp"
#include "GhidraBlockPartition.hpp"
#include "GhidraPackageAttestation.hpp"
#include "GhidraRuntimeInternal.hpp"
#include "GhidraVariableIdentity.hpp"
#include "MacScopeNativeDecompiler/GhidraBuildIdentity.hpp"
#include "PcodeOpcodeVocabulary.hpp"
#include "DefinitionIdentity.hpp"

#include <ghidra/libdecomp.hh>
#include <ghidra/flow.hh>
#include <ghidra/context.hh>
#include <ghidra/loadimage.hh>
#include <ghidra/opbehavior.hh>
#include <ghidra/jumptable.hh>
#include <ghidra/printlanguage.hh>
#include <ghidra/xml.hh>

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <functional>
#include <filesystem>
#include <limits>
#include <map>
#include <memory>
#include <new>
#include <optional>
#include <ostream>
#include <set>
#include <sstream>
#include <string>
#include <string_view>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>
#if defined(__APPLE__)
#include <os/log.h>
#endif

namespace macscope::native_decompiler {

namespace detail {

enum class PacCompanionOpcode : std::uint8_t {
    other,
    copy,
    load,
    branchIndirect,
    callIndirect,
    return_,
};

struct PacCompanionOperation final {
    PacCompanionOpcode opcode = PacCompanionOpcode::other;
    std::optional<std::uintptr_t> output;
    std::vector<std::optional<std::uintptr_t>> inputs;
    bool exceptionReturn = false;
};

struct PacCompanionDescriptor final {
    std::string userOperationName;
    std::string mnemonic;
    std::size_t authenticationIndex = 0;
    std::vector<PacCompanionOperation> operations;
};

enum class PacCompanionKind : std::uint8_t {
    authenticatedMemoryAccess,
    authenticatedControlTransfer,
};

PacCompanionKind classifyPacCompanionShape(const PacCompanionDescriptor& descriptor) {
    if (descriptor.authenticationIndex >= descriptor.operations.size()) {
        throw ContractError("native-provider-pac-operation-index-invalid");
    }
    const auto& authentication = descriptor.operations[descriptor.authenticationIndex];
    if (authentication.opcode != PacCompanionOpcode::other ||
        authentication.inputs.size() != 3U || !authentication.inputs[1]) {
        throw ContractError("native-provider-pac-input-shape-invalid");
    }
    const auto authenticatedValue = *authentication.inputs[1];
    constexpr std::size_t maximumCopyAncestry = 64U;
    const auto consumesAuthenticatedTarget = [&](std::optional<std::uintptr_t> value) {
        std::unordered_set<std::uintptr_t> seen;
        for (std::size_t depth = 0; value && depth <= maximumCopyAncestry; ++depth) {
            if (*value == authenticatedValue) return true;
            if (!seen.insert(*value).second) return false;
            const auto definition = std::find_if(
                descriptor.operations.begin(), descriptor.operations.end(),
                [&](const PacCompanionOperation& operation) {
                    return operation.output == value;
                }
            );
            if (definition == descriptor.operations.end() ||
                definition->opcode != PacCompanionOpcode::copy ||
                definition->inputs.size() != 1U) {
                return false;
            }
            value = definition->inputs[0];
        }
        return false;
    };

    bool memory = false;
    bool control = false;
    bool exceptionReturnBeforeAuthentication = false;
    for (std::size_t index = 0; index < descriptor.operations.size(); ++index) {
        const auto& operation = descriptor.operations[index];
        if (index < descriptor.authenticationIndex && operation.exceptionReturn &&
            operation.output == authentication.inputs[1]) {
            exceptionReturnBeforeAuthentication = true;
        }
        if (index <= descriptor.authenticationIndex) continue;
        if (operation.opcode == PacCompanionOpcode::load && operation.inputs.size() == 2U &&
            operation.inputs[1] == authentication.inputs[1]) {
            memory = true;
        }
        if ((operation.opcode == PacCompanionOpcode::branchIndirect ||
             operation.opcode == PacCompanionOpcode::callIndirect ||
             operation.opcode == PacCompanionOpcode::return_) &&
            !operation.inputs.empty() && consumesAuthenticatedTarget(operation.inputs[0])) {
            control = true;
        }
    }

    const bool sealedReturn =
        (descriptor.mnemonic == "retaa" && descriptor.userOperationName == "AuthIA") ||
        (descriptor.mnemonic == "retab" && descriptor.userOperationName == "AuthIB");
    const bool sealedExceptionReturn =
        (descriptor.mnemonic == "eretaa" && descriptor.userOperationName == "AuthIA") ||
        (descriptor.mnemonic == "eretab" && descriptor.userOperationName == "AuthIB");
    if (sealedExceptionReturn) {
        if (!exceptionReturnBeforeAuthentication) {
            throw ContractError("native-provider-pac-exception-return-order-invalid");
        }
    }
    const bool sealedMnemonic = descriptor.mnemonic == "retaa" ||
        descriptor.mnemonic == "retab" || descriptor.mnemonic == "eretaa" ||
        descriptor.mnemonic == "eretab";
    if (sealedMnemonic && !sealedReturn && !sealedExceptionReturn) {
        throw ContractError("native-provider-pac-companion-value-mismatch");
    }
    if (!memory && !control) {
        throw ContractError("native-provider-pac-companion-value-mismatch");
    }
    if (memory && control) {
        throw ContractError("native-provider-pac-companion-shape-ambiguous");
    }
    return memory ? PacCompanionKind::authenticatedMemoryAccess
                  : PacCompanionKind::authenticatedControlTransfer;
}

} // namespace detail

namespace {

/// The target of an A64 B/BL at `at`: imm26 sign-extended and scaled, added with defined
/// unsigned wraparound (signed addition could overflow in the admitted UInt64 domain).
[[nodiscard]] Address a64BranchTarget(Address at, std::uint32_t encoding) noexcept {
    const auto imm26 = static_cast<std::uint64_t>(encoding & 0x03ffffffU);
    const auto scaled = imm26 << 2U;
    const auto displacement = (scaled & 0x08000000ULL) != 0U ? scaled | ~0x0fffffffULL : scaled;
    return static_cast<Address>(static_cast<std::uint64_t>(at) + displacement);
}

using detail::GhidraArchitecture;
using detail::GhidraExecutionLock;
using detail::GhidraPackageAttestation;
using detail::GhidraPackageAttestationExpectations;
using detail::GhidraRuntimeIdentity;
using detail::GhidraRuntimeLease;

constexpr std::string_view kBackendId = "ghidra-native-decompiler";

// CP4 exports the finalized CFG; no reduced-action decompilation retry exists.
constexpr std::string_view kAppleLanguageId = "AARCH64:LE:64:AppleSilicon";
constexpr std::string_view kAppleCompilerSpecId = "default";
constexpr std::string_view kAppleTargetProfileId =
    "apple-aarch64-pac-visible-clobber-v1";
constexpr std::string_view kAppleContextProfileSha256 =
    "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5";
constexpr std::array<std::string_view, 14> kRequiredPacUserOps = {
    "AuthIA", "AuthIB", "AuthDA", "AuthDB",
    "pacia", "pacib", "pacda", "pacdb",
    "paciza", "pacizb", "pacdza", "pacdzb",
    "pacga", "xpac",
};
constexpr std::size_t kMaximumAssemblyText = 4096U;
constexpr std::size_t kMaximumSpecialDescriptorText = 4096U;
constexpr std::size_t kMaximumTypeDescriptorText = 64U * 1024U;
constexpr std::size_t kMaximumPseudocodeText = 1024U * 1024U;
/// Token metadata never grows the result past the v2 output cap (8 MiB). Larger
/// budget profiles widen room for the structured graph only: a NEON kernel's tokens
/// at v3 doubled its encoded reply (7.4 -> 14.7 MB for libjpeg
/// `_jsimd_idct_islow_neon`) and timed out at the client on 906c03128.
constexpr std::size_t kMaximumTokenMetadataOutput = 8U * 1024U * 1024U;
constexpr std::string_view kTokenMetadataOmittedWarning = "native-pseudocode-token-metadata-omitted";

/// Request-local authored naming authority prepared before native flow
/// recovery. Type, signature, and applied-object records are prepared and
/// installed by their closed-AST paths before followFlow.
struct PreparedAuthoredAuthority final {
    std::string entryFunctionName;
    std::vector<std::pair<Address, std::string>> functions;
    std::vector<std::pair<Address, std::string>> labels;
    bool complete = false;
};

[[nodiscard]] PreparedAuthoredAuthority prepareAuthoredAuthority(
    const AnalysisRequestView& request,
    const CancellationToken& cancellation
) {
    cancellation.throwIfCancelled();
    PreparedAuthoredAuthority prepared{request.function.name, {}, {}, false};
    if (request.authoredInputs.schemaVersion < 1U || request.authoredInputs.schemaVersion > 3U) {
        throw ContractError("authoring-input-unsupported");
    }
    std::unordered_map<std::string, AuthoredNamedKind> definitionKinds;
    for (const auto& definition : request.authoredInputs.typeDefinitions) {
        AuthoredNamedKind kind;
        switch (definition.kind) {
        case AuthoredTypeDefinitionKind::recordStruct:
            kind = AuthoredNamedKind::struct_;
            break;
        case AuthoredTypeDefinitionKind::recordUnion:
            kind = AuthoredNamedKind::union_;
            break;
        case AuthoredTypeDefinitionKind::enumeration:
            kind = AuthoredNamedKind::enum_;
            break;
        case AuthoredTypeDefinitionKind::typedef_:
            kind = AuthoredNamedKind::typedef_;
            break;
        }
        if (!definitionKinds.emplace(definition.name, kind).second) {
            throw ContractError("authoring-input-unsupported");
        }
    }
    std::function<void(const AuthoredType&)> requireResolvedType;
    std::function<void(const AuthoredFieldStorage&)> requireResolvedStorage;
    requireResolvedType = [&](const AuthoredType& type) {
        if (type.tag == AuthoredTypeTag::dataPointer) {
            const auto* pointer = std::get_if<AuthoredDataPointer>(&type.payload);
            if (pointer == nullptr || pointer->pointee == nullptr) {
                throw ContractError("authoring-input-unsupported");
            }
            requireResolvedType(*pointer->pointee);
            return;
        }
        const auto* value = std::get_if<AuthoredQualifiedValue>(&type.payload);
        if (value == nullptr || value->atom.tag != AuthoredAtomTag::named) return;
        const auto* named = std::get_if<AuthoredNamedAtom>(&value->atom.payload);
        const auto resolved = named == nullptr ? definitionKinds.end() :
            definitionKinds.find(named->name);
        if (named == nullptr || resolved == definitionKinds.end() ||
            resolved->second != named->kind) {
            throw ContractError("authoring-input-unsupported");
        }
    };
    requireResolvedStorage = [&](const AuthoredFieldStorage& storage) {
        switch (storage.tag) {
        case AuthoredFieldStorageTag::value:
            requireResolvedType(std::get<AuthoredValueStorage>(storage.payload).type);
            break;
        case AuthoredFieldStorageTag::fixedArray:
            requireResolvedStorage(*std::get<AuthoredFixedArrayStorage>(storage.payload).element);
            break;
        case AuthoredFieldStorageTag::flexibleArray:
            requireResolvedStorage(*std::get<AuthoredFlexibleArrayStorage>(storage.payload).element);
            break;
        case AuthoredFieldStorageTag::opaquePointerCarrier:
            break;
        case AuthoredFieldStorageTag::inlineAggregate:
            for (const auto& field : std::get<AuthoredInlineAggregateStorage>(storage.payload).fields) {
                requireResolvedStorage(*field.storage);
                if (field.minimumAlignmentType) requireResolvedType(*field.minimumAlignmentType);
            }
            break;
        }
    };
    for (const auto& definition : request.authoredInputs.typeDefinitions) {
        if (const auto* record = std::get_if<AuthoredRecordDefinition>(&definition.payload)) {
            for (const auto& field : record->fields) {
                requireResolvedStorage(*field.storage);
                if (field.minimumAlignmentType) requireResolvedType(*field.minimumAlignmentType);
            }
        } else if (const auto* alias = std::get_if<AuthoredTypedefDefinition>(&definition.payload)) {
            requireResolvedStorage(*alias->target);
        }
    }
    for (const auto& signature : request.authoredInputs.signatures) {
        if (signature.returnType) requireResolvedType(*signature.returnType);
        for (const auto& parameter : signature.parameters) requireResolvedType(parameter.type);
    }
    for (const auto& hint : request.authoredInputs.calleeSignatureHints) {
        if (hint.signature.returnType) requireResolvedType(*hint.signature.returnType);
        for (const auto& parameter : hint.signature.parameters) requireResolvedType(parameter.type);
    }
    for (const auto& local : request.authoredInputs.localNames) {
        if (local.type) requireResolvedType(*local.type);
    }
    for (const auto& applied : request.authoredInputs.appliedTypes) {
        if (!definitionKinds.contains(applied.typeDefinitionName)) {
            throw ContractError("authoring-input-unsupported");
        }
    }
    for (const auto& name : request.authoredInputs.names) {
        cancellation.throwIfCancelled();
        const auto mapped = std::any_of(
            request.bytes.regions().begin(), request.bytes.regions().end(),
            [&](const MemoryRegion& region) {
                return region.readable() && !region.writable() &&
                    (name.subjectKind == AuthoredNameSubjectKind::data
                        ? !region.executable() : region.executable()) &&
                    name.address >= region.startAddress &&
                    name.address < region.endAddressExclusive() &&
                    (name.subjectKind != AuthoredNameSubjectKind::function ||
                     (name.address % 4U == 0U &&
                      region.endAddressExclusive() - name.address >= 4U));
            }
        );
        if (!mapped || name.name.empty()) {
            throw ContractError("authoring-input-unsupported");
        }
        switch (name.subjectKind) {
        case AuthoredNameSubjectKind::function:
            if (name.address == request.function.entryAddress) {
                prepared.entryFunctionName = name.name;
            } else {
                prepared.functions.emplace_back(name.address, name.name);
            }
            break;
        case AuthoredNameSubjectKind::label:
            prepared.labels.emplace_back(name.address, name.name);
            break;
        case AuthoredNameSubjectKind::data:
            // Installed together with applied objects to avoid creating a
            // competing one-byte symbol over an exact typed object.
            break;
        }
    }
    return prepared;
}

void installAuthoredAuthority(
    const PreparedAuthoredAuthority& prepared,
    ghidra::Scope& globalScope,
    ghidra::AddrSpace& codeSpace,
    const CancellationToken& cancellation,
    const std::shared_ptr<GhidraProviderObserver>& observer
) {
    if (prepared.complete) throw ContractError("authoring-input-unsupported");
    for (const auto& [address, name] : prepared.functions) {
        cancellation.throwIfCancelled();
        const ghidra::Address nativeAddress(&codeSpace, address);
        auto* symbol = globalScope.addFunction(nativeAddress, name);
        if (symbol == nullptr || symbol->getFunction() == nullptr ||
            symbol->getFunction()->getName() != name) {
            throw ContractError("authoring-input-unsupported");
        }
        if (observer && observer->authoredNameReadback) {
            observer->authoredNameReadback(address, symbol->getFunction()->getName(), true);
        }
    }
    for (const auto& [address, name] : prepared.labels) {
        cancellation.throwIfCancelled();
        const ghidra::Address nativeAddress(&codeSpace, address);
        const auto* label = globalScope.addCodeLabel(nativeAddress, name);
        if (label == nullptr || label->getName() != name) {
            throw ContractError("authoring-input-unsupported");
        }
        if (observer && observer->authoredNameReadback) {
            observer->authoredNameReadback(address, label->getName(), false);
        }
    }
}

using AuthoredQualifierRenderNames = std::unordered_map<ghidra::Datatype*, std::string>;

[[nodiscard]] std::string authoredRenderTypeName(
    ghidra::Datatype& type, const AuthoredQualifierRenderNames& names
) {
    if (const auto found = names.find(&type); found != names.end()) return found->second;
    if (!type.getDisplayName().empty()) return type.getDisplayName();
    if (type.getMetatype() == ghidra::TYPE_PTR && type.numDepend() == 1 && type.getDepend(0) != nullptr) {
        return authoredRenderTypeName(*type.getDepend(0), names) + " *";
    }
    return type.getName();
}

[[nodiscard]] ghidra::Datatype* resolveAuthoredCatalogType(
    const AuthoredType& type,
    ghidra::TypeFactory& factory,
    AuthoredQualifierRenderNames& renderNames
) {
    const auto applyQualifiers = [&](ghidra::Datatype* base, std::uint8_t qualifiers,
                                     std::string_view role) -> ghidra::Datatype* {
        if (base == nullptr || qualifiers == 0U) return base;
        std::uint64_t digest = 1469598103934665603ULL;
        const auto charge = [&](std::string_view text) {
            for (const unsigned char byte : text) {
                digest ^= byte;
                digest *= 1099511628211ULL;
            }
        };
        charge(role);
        charge(base->getName());
        charge(std::to_string(base->getSize()));
        charge(std::to_string(static_cast<unsigned>(base->getMetatype())));
        charge(std::to_string(qualifiers));
        const auto name = "__macscope_authored_qualifier_" + std::to_string(digest);
        auto* qualified = factory.findByName(name);
        if (qualified != nullptr) {
            if (qualified->getTypedef() != base) {
                throw ContractError("authoring-input-unsupported");
            }
        } else {
            qualified = factory.getTypedef(base, name, 0U, 0U);
        }
        std::string qualifierText;
        if ((qualifiers & static_cast<std::uint8_t>(AuthoredQualifier::constant)) != 0U) qualifierText += "const ";
        if ((qualifiers & static_cast<std::uint8_t>(AuthoredQualifier::volatile_)) != 0U) qualifierText += "volatile ";
        if ((qualifiers & static_cast<std::uint8_t>(AuthoredQualifier::restrict_)) != 0U) qualifierText += "restrict ";
        if (qualifierText.empty()) throw ContractError("authoring-input-unsupported");
        auto display = authoredRenderTypeName(*base, renderNames);
        if (role.starts_with("pointer:")) {
            qualifierText.pop_back();
            display += " " + qualifierText;
        } else {
            display = qualifierText + display;
        }
        renderNames.emplace(qualified, std::move(display));
        return qualified;
    };
    if (type.tag == AuthoredTypeTag::dataPointer) {
        const auto* pointer = std::get_if<AuthoredDataPointer>(&type.payload);
        if (pointer == nullptr || pointer->pointee == nullptr ||
            pointer->indirectionLevel == 0U ||
            pointer->indirectionLevel != pointer->pointerQualifiersByLevel.size()) {
            throw ContractError("authoring-input-unsupported");
        }
        auto* resolved = resolveAuthoredCatalogType(*pointer->pointee, factory, renderNames);
        for (std::uint64_t level = 0; level < pointer->indirectionLevel; ++level) {
            resolved = factory.getTypePointer(8, resolved, 8U, "");
            resolved = applyQualifiers(
                resolved,
                pointer->pointerQualifiersByLevel[static_cast<std::size_t>(level)],
                "pointer:" + std::to_string(level)
            );
        }
        return resolved;
    }
    if (type.tag != AuthoredTypeTag::qualifiedValue) {
        throw ContractError("authoring-input-unsupported");
    }
    const auto* qualified = std::get_if<AuthoredQualifiedValue>(&type.payload);
    if (qualified == nullptr) {
        throw ContractError("authoring-input-unsupported");
    }
    ghidra::Datatype* resolved = nullptr;
    if (qualified->atom.tag == AuthoredAtomTag::void_) {
        resolved = factory.getTypeVoid();
    } else if (qualified->atom.tag == AuthoredAtomTag::named) {
        const auto* named = std::get_if<AuthoredNamedAtom>(&qualified->atom.payload);
        if (named == nullptr || named->name.empty()) {
            throw ContractError("authoring-input-unsupported");
        }
        resolved = factory.findByName(named->name);
        if (resolved == nullptr) {
            throw ContractError("authoring-input-unsupported");
        }
        const auto metatype = resolved->getMetatype();
        const bool kindMatches =
            (named->kind == AuthoredNamedKind::struct_ && metatype == ghidra::TYPE_STRUCT) ||
            (named->kind == AuthoredNamedKind::union_ && metatype == ghidra::TYPE_UNION) ||
            (named->kind == AuthoredNamedKind::enum_ && resolved->isEnumType()) ||
            (named->kind == AuthoredNamedKind::typedef_ && resolved->getTypedef() != nullptr);
        if (!kindMatches) throw ContractError("authoring-input-unsupported");
    } else if (qualified->atom.tag == AuthoredAtomTag::darwinAlias) {
        const auto* alias = std::get_if<AuthoredDarwinAliasKind>(&qualified->atom.payload);
        if (alias == nullptr) {
            throw ContractError("authoring-input-unsupported");
        }
        ghidra::Datatype* base = nullptr;
        std::string aliasName;
        switch (*alias) {
        case AuthoredDarwinAliasKind::sizeT:
            base = factory.getBase(8, ghidra::TYPE_UINT); aliasName = "size_t"; break;
        case AuthoredDarwinAliasKind::ssizeT:
            base = factory.getBase(8, ghidra::TYPE_INT); aliasName = "ssize_t"; break;
        case AuthoredDarwinAliasKind::intptrT:
            base = factory.getBase(8, ghidra::TYPE_INT); aliasName = "intptr_t"; break;
        case AuthoredDarwinAliasKind::uintptrT:
            base = factory.getBase(8, ghidra::TYPE_UINT); aliasName = "uintptr_t"; break;
        case AuthoredDarwinAliasKind::ptrdiffT:
            base = factory.getBase(8, ghidra::TYPE_INT); aliasName = "ptrdiff_t"; break;
        case AuthoredDarwinAliasKind::wcharT:
            base = factory.getBase(4, ghidra::TYPE_INT); aliasName = "wchar_t"; break;
        }
        if (auto* existing = factory.findByName(aliasName); existing != nullptr) {
            if (existing->getTypedef() != base) {
                throw ContractError("authoring-input-unsupported");
            }
            resolved = existing;
        } else {
            resolved = factory.getTypedef(base, aliasName, 0U, 0U);
        }
    } else {
        const auto* scalar = std::get_if<AuthoredScalarKind>(&qualified->atom.payload);
        if (qualified->atom.tag != AuthoredAtomTag::scalar || scalar == nullptr) {
            throw ContractError("authoring-input-unsupported");
        }
        switch (*scalar) {
        case AuthoredScalarKind::bool_: resolved = factory.getBase(1, ghidra::TYPE_BOOL); break;
        case AuthoredScalarKind::char_: resolved = factory.getTypeChar(1); break;
        case AuthoredScalarKind::signed8: resolved = factory.getBase(1, ghidra::TYPE_INT); break;
        case AuthoredScalarKind::unsigned8: resolved = factory.getBase(1, ghidra::TYPE_UINT); break;
        case AuthoredScalarKind::signed16: resolved = factory.getBase(2, ghidra::TYPE_INT); break;
        case AuthoredScalarKind::unsigned16: resolved = factory.getBase(2, ghidra::TYPE_UINT); break;
        case AuthoredScalarKind::signed32: resolved = factory.getBase(4, ghidra::TYPE_INT); break;
        case AuthoredScalarKind::unsigned32: resolved = factory.getBase(4, ghidra::TYPE_UINT); break;
        case AuthoredScalarKind::signed64: resolved = factory.getBase(8, ghidra::TYPE_INT); break;
        case AuthoredScalarKind::unsigned64: resolved = factory.getBase(8, ghidra::TYPE_UINT); break;
        case AuthoredScalarKind::float32: resolved = factory.getBase(4, ghidra::TYPE_FLOAT); break;
        case AuthoredScalarKind::float64: resolved = factory.getBase(8, ghidra::TYPE_FLOAT); break;
        }
    }
    resolved = applyQualifiers(resolved, qualified->qualifiers, "value");
    if (resolved == nullptr) throw ContractError("authoring-input-unsupported");
    return resolved;
}

[[nodiscard]] std::uint64_t authoredStorageNameDigest(std::string_view value) {
    std::uint64_t digest = 1469598103934665603ULL;
    for (const unsigned char byte : value) {
        digest ^= byte;
        digest *= 1099511628211ULL;
    }
    return digest;
}

[[nodiscard]] ghidra::Datatype* resolveAuthoredFieldStorage(
    const AuthoredFieldStorage& storage,
    ghidra::TypeFactory& factory,
    bool permitsFlexibleArray,
    std::string_view identity,
    AuthoredQualifierRenderNames& renderNames
);

void installAuthoredRecordFields(
    const std::vector<AuthoredRecordField>& authoredFields,
    AuthoredNamedKind kind,
    const AuthoredLayoutRules& layout,
    ghidra::Datatype& aggregate,
    ghidra::TypeFactory& factory,
    bool permitsFlexibleArray,
    std::string_view identity,
    AuthoredQualifierRenderNames& renderNames
) {
    std::vector<ghidra::TypeField> fields;
    std::vector<ghidra::TypeBitField> bitFields;
    ghidra::int4 offset = 0;
    ghidra::int4 expectedSize = 0;
    for (std::size_t index = 0; index < authoredFields.size(); ++index) {
        const auto& authored = authoredFields[index];
        const bool fieldPermitsFlexible = permitsFlexibleArray && kind == AuthoredNamedKind::struct_ &&
            index + 1U == authoredFields.size();
        auto* type = resolveAuthoredFieldStorage(
            *authored.storage,
            factory,
            fieldPermitsFlexible,
            std::string(identity) + ".field." + std::to_string(index),
            renderNames
        );
        if (type == nullptr || type->getSize() < 0 ||
            (authored.minimumAlignment &&
             type->getAlignment() < static_cast<ghidra::int4>(*authored.minimumAlignment))) {
            throw ContractError("authoring-input-unsupported");
        }
        if (authored.bitWidth) {
            if (*authored.bitWidth == 0U || *authored.bitWidth >
                    static_cast<std::uint64_t>(type->getSize()) * 8U) {
                throw ContractError("authoring-input-unsupported");
            }
            bitFields.emplace_back(
                static_cast<ghidra::int4>(index),
                static_cast<ghidra::int4>(*authored.bitWidth),
                false,
                authored.name,
                type
            );
        } else {
            fields.emplace_back(
                static_cast<ghidra::int4>(index),
                kind == AuthoredNamedKind::union_ ? 0 : -1,
                authored.name,
                type
            );
        }
        if (kind == AuthoredNamedKind::union_) {
            expectedSize = std::max(expectedSize, type->getSize());
        } else {
            if (type->getSize() > std::numeric_limits<ghidra::int4>::max() - offset) {
                throw ContractError("authoring-input-unsupported");
            }
            offset += type->getSize();
            expectedSize = offset;
        }
    }
    if (kind == AuthoredNamedKind::struct_) {
        auto* structure = dynamic_cast<ghidra::TypeStruct*>(&aggregate);
        if (structure == nullptr) throw ContractError("authoring-input-unsupported");
        factory.assignRawFields(structure, fields, bitFields);
    } else {
        auto* unionType = dynamic_cast<ghidra::TypeUnion*>(&aggregate);
        if (unionType == nullptr || !bitFields.empty()) {
            throw ContractError("authoring-input-unsupported");
        }
        factory.assignRawFields(unionType, fields);
    }
    if (aggregate.getSize() != expectedSize ||
        (layout.isPacked && aggregate.getAlignment() >
            static_cast<ghidra::int4>(layout.packAlignment.value_or(1U))) ||
        (layout.packAlignment && aggregate.getAlignment() >
            static_cast<ghidra::int4>(*layout.packAlignment)) ||
        (layout.minimumAlignment && aggregate.getAlignment() <
            static_cast<ghidra::int4>(*layout.minimumAlignment))) {
        throw ContractError("authoring-input-unsupported");
    }
}

[[nodiscard]] ghidra::Datatype* resolveAuthoredFieldStorage(
    const AuthoredFieldStorage& storage,
    ghidra::TypeFactory& factory,
    bool permitsFlexibleArray,
    std::string_view identity,
    AuthoredQualifierRenderNames& renderNames
) {
    switch (storage.tag) {
    case AuthoredFieldStorageTag::value: {
        const auto* value = std::get_if<AuthoredValueStorage>(&storage.payload);
        if (value == nullptr) throw ContractError("authoring-input-unsupported");
        return resolveAuthoredCatalogType(value->type, factory, renderNames);
    }
    case AuthoredFieldStorageTag::fixedArray: {
        const auto* array = std::get_if<AuthoredFixedArrayStorage>(&storage.payload);
        if (array == nullptr || array->element == nullptr || array->count == 0U ||
            array->count > static_cast<std::uint64_t>(std::numeric_limits<ghidra::int4>::max())) {
            throw ContractError("authoring-input-unsupported");
        }
        auto* element = resolveAuthoredFieldStorage(
            *array->element, factory, false, std::string(identity) + ".element", renderNames
        );
        return factory.getTypeArray(static_cast<ghidra::int4>(array->count), element);
    }
    case AuthoredFieldStorageTag::flexibleArray: {
        const auto* array = std::get_if<AuthoredFlexibleArrayStorage>(&storage.payload);
        if (!permitsFlexibleArray || array == nullptr || array->element == nullptr) {
            throw ContractError("authoring-input-unsupported");
        }
        auto* element = resolveAuthoredFieldStorage(
            *array->element, factory, false, std::string(identity) + ".element", renderNames
        );
        return factory.getTypeArray(0, element);
    }
    case AuthoredFieldStorageTag::opaquePointerCarrier: {
        const auto* carrier = std::get_if<AuthoredOpaquePointerCarrierStorage>(&storage.payload);
        if (carrier == nullptr) throw ContractError("authoring-input-unsupported");
        ghidra::Datatype* target = nullptr;
        if (carrier->kind == AuthoredOpaquePointerCarrierKind::functionPointer) {
            target = factory.getTypeCode();
        } else if (carrier->kind == AuthoredOpaquePointerCarrierKind::pointerToArray) {
            target = factory.getTypeArray(1, factory.getBase(1, ghidra::TYPE_UINT));
        } else {
            throw ContractError("authoring-input-unsupported");
        }
        return factory.getTypePointer(
            8,
            target,
            8U,
            "__macscope_authored_carrier_" +
                std::to_string(authoredStorageNameDigest(identity))
        );
    }
    case AuthoredFieldStorageTag::inlineAggregate: {
        const auto* inlineAggregate = std::get_if<AuthoredInlineAggregateStorage>(&storage.payload);
        if (inlineAggregate == nullptr ||
            (inlineAggregate->kind != AuthoredNamedKind::struct_ &&
             inlineAggregate->kind != AuthoredNamedKind::union_)) {
            throw ContractError("authoring-input-unsupported");
        }
        const auto name = "__macscope_authored_inline_" +
            std::to_string(authoredStorageNameDigest(identity));
        ghidra::Datatype* aggregate = inlineAggregate->kind == AuthoredNamedKind::struct_
            ? static_cast<ghidra::Datatype*>(factory.getTypeStruct(name))
            : static_cast<ghidra::Datatype*>(factory.getTypeUnion(name));
        installAuthoredRecordFields(
            inlineAggregate->fields,
            inlineAggregate->kind,
            inlineAggregate->layoutRules,
            *aggregate,
            factory,
            permitsFlexibleArray,
            identity,
            renderNames
        );
        return aggregate;
    }
    }
    throw ContractError("authoring-input-unsupported");
}

[[nodiscard]] std::string authoredNativeTypeDescriptor(
    const ghidra::Datatype& type,
    std::size_t depth = 0U
) {
    if (depth > 32U) throw ContractError("authoring-input-unsupported");
    std::string descriptor = "name=" + type.getName() +
        ";size=" + std::to_string(type.getSize()) +
        ";align=" + std::to_string(type.getAlignment()) +
        ";meta=" + std::to_string(static_cast<unsigned>(type.getMetatype()));
    if (const auto* target = type.getTypedef(); target != nullptr) {
        descriptor += ";typedef={" + authoredNativeTypeDescriptor(*target, depth + 1U) + "}";
        return descriptor;
    }
    if (const auto* pointer = dynamic_cast<const ghidra::TypePointer*>(&type); pointer != nullptr) {
        descriptor += ";pointer={" +
            authoredNativeTypeDescriptor(*pointer->getPtrTo(), depth + 1U) + "}";
    } else if (const auto* array = dynamic_cast<const ghidra::TypeArray*>(&type); array != nullptr) {
        descriptor += ";array-count=" + std::to_string(array->numElements()) +
            ";element={" + authoredNativeTypeDescriptor(*array->getBase(), depth + 1U) + "}";
    } else if (const auto* structure = dynamic_cast<const ghidra::TypeStruct*>(&type);
               structure != nullptr) {
        for (auto field = structure->beginField(); field != structure->endField(); ++field) {
            descriptor += ";field=" + field->name + "@" + std::to_string(field->offset) +
                "{" + authoredNativeTypeDescriptor(*field->type, depth + 1U) + "}";
        }
        for (ghidra::int4 index = 0; index < structure->numBitFields(); ++index) {
            const auto& field = structure->getBitField(index);
            descriptor += ";bitfield=" + field.name + ":" +
                std::to_string(field.bits.numBits) + "@" +
                std::to_string(field.bits.byteOffset);
        }
    } else if (const auto* unionType = dynamic_cast<const ghidra::TypeUnion*>(&type);
               unionType != nullptr) {
        for (ghidra::int4 index = 0; index < unionType->numDepend(); ++index) {
            const auto* field = unionType->getField(index);
            descriptor += ";field=" + field->name + "@" + std::to_string(field->offset) +
                "{" + authoredNativeTypeDescriptor(*field->type, depth + 1U) + "}";
        }
    } else if (const auto* enumeration = dynamic_cast<const ghidra::TypeEnum*>(&type);
               enumeration != nullptr) {
        for (auto item = enumeration->beginEnum(); item != enumeration->endEnum(); ++item) {
            const auto value = static_cast<std::int32_t>(static_cast<std::uint32_t>(item->first));
            descriptor += ";enum=" + item->second + ":" + std::to_string(value);
        }
    }
    return descriptor;
}

void installAuthoredTypeCatalog(
    const AnalysisRequestView& request,
    detail::GhidraArchitecture& architecture,
    const CancellationToken& cancellation,
    const std::shared_ptr<GhidraProviderObserver>& observer,
    AuthoredQualifierRenderNames& renderNames
) {
    auto& factory = architecture.typeFactory();
    for (const auto& definition : request.authoredInputs.typeDefinitions) {
        cancellation.throwIfCancelled();
        switch (definition.kind) {
        case AuthoredTypeDefinitionKind::recordStruct:
            (void)factory.getTypeStruct(definition.name);
            break;
        case AuthoredTypeDefinitionKind::recordUnion:
            (void)factory.getTypeUnion(definition.name);
            break;
        case AuthoredTypeDefinitionKind::enumeration:
            (void)factory.getTypeEnum(definition.name);
            break;
        case AuthoredTypeDefinitionKind::typedef_:
            break;
        }
    }
    for (std::size_t index = 0; index < request.authoredInputs.typeDefinitions.size(); ++index) {
        if (observer && observer->authoredCheckpoint) {
            observer->authoredCheckpoint("catalog", index);
        }
        cancellation.throwIfCancelled();
        const auto& definition = request.authoredInputs.typeDefinitions[index];
        ghidra::Datatype* installed = nullptr;
        switch (definition.kind) {
        case AuthoredTypeDefinitionKind::recordStruct: {
            const auto* record = std::get_if<AuthoredRecordDefinition>(&definition.payload);
            if (record == nullptr || record->kind != AuthoredNamedKind::struct_) {
                throw ContractError("authoring-input-unsupported");
            }
            installed = factory.getTypeStruct(definition.name);
            if (!record->fields.empty()) {
                installAuthoredRecordFields(
                    record->fields,
                    record->kind,
                    record->layoutRules,
                    *installed,
                    factory,
                    true,
                    definition.name,
                    renderNames
                );
            }
            break;
        }
        case AuthoredTypeDefinitionKind::recordUnion: {
            const auto* record = std::get_if<AuthoredRecordDefinition>(&definition.payload);
            if (record == nullptr || record->kind != AuthoredNamedKind::union_) {
                throw ContractError("authoring-input-unsupported");
            }
            installed = factory.getTypeUnion(definition.name);
            if (!record->fields.empty()) {
                installAuthoredRecordFields(
                    record->fields,
                    record->kind,
                    record->layoutRules,
                    *installed,
                    factory,
                    false,
                    definition.name,
                    renderNames
                );
            }
            break;
        }
        case AuthoredTypeDefinitionKind::enumeration: {
            const auto* enumeration = std::get_if<AuthoredEnumerationDefinition>(&definition.payload);
            if (enumeration == nullptr ||
                enumeration->representation != AuthoredEnumRepresentation::signed32) {
                throw ContractError("authoring-input-unsupported");
            }
            auto* enumType = factory.getTypeEnum(definition.name);
            std::map<ghidra::uintb, std::string> values;
            for (const auto& enumCase : enumeration->cases) {
                const auto raw = static_cast<std::uint32_t>(enumCase.value);
                if (!values.emplace(static_cast<ghidra::uintb>(raw), enumCase.name).second) {
                    throw ContractError("authoring-input-unsupported");
                }
            }
            factory.setEnumValues(values, enumType);
            installed = enumType;
            break;
        }
        case AuthoredTypeDefinitionKind::typedef_: {
            const auto* alias = std::get_if<AuthoredTypedefDefinition>(&definition.payload);
            if (alias == nullptr || alias->target == nullptr) {
                throw ContractError("authoring-input-unsupported");
            }
            auto* target = resolveAuthoredFieldStorage(
                *alias->target,
                factory,
                false,
                definition.name + ".target",
                renderNames
            );
            installed = factory.getTypedef(target, definition.name, 0U, 0U);
            if (installed == nullptr || installed->getTypedef() != target) {
                throw ContractError("authoring-input-unsupported");
            }
            break;
        }
        }
        if (installed == nullptr || installed->getName() != definition.name ||
            factory.findByName(definition.name) != installed) {
            throw ContractError("authoring-input-unsupported");
        }
        if (observer && observer->authoredTypeReadback) {
            const auto descriptor = authoredNativeTypeDescriptor(*installed);
            observer->authoredTypeReadback(definition.name, descriptor);
        }
    }
}

void installAuthoredNonCodeObjects(
    const AnalysisRequestView& request,
    ghidra::Scope& globalScope,
    ghidra::AddrSpace& codeSpace,
    ghidra::TypeFactory& factory,
    ghidra::Funcdata& entryFunction,
    const CancellationToken& cancellation,
    const std::shared_ptr<GhidraProviderObserver>& observer
) {
    auto& prototype = entryFunction.getFuncProto();
    const auto parameterCountBefore = prototype.numParams();
    const auto* outputTypeBefore = prototype.getOutputType();
    const bool inputLockBefore = prototype.isInputLocked();
    const bool outputLockBefore = prototype.isOutputLocked();
    const bool variadicBefore = prototype.isDotdotdot();
    const bool noReturnBefore = prototype.isNoReturn();
    for (std::size_t index = 0; index < request.authoredInputs.appliedTypes.size(); ++index) {
        if (observer && observer->authoredCheckpoint) {
            observer->authoredCheckpoint("application", index);
        }
        cancellation.throwIfCancelled();
        const auto& applied = request.authoredInputs.appliedTypes[index];
        if (applied.subjectKind != AuthoredAppliedTypeSubjectKind::memoryObject ||
            applied.byteCount == 0U || applied.address > std::numeric_limits<Address>::max() - applied.byteCount ||
            (applied.address < request.function.endAddressExclusive &&
             applied.address + applied.byteCount > request.function.entryAddress)) {
            throw ContractError("authoring-input-unsupported");
        }
        const auto region = std::find_if(
            request.bytes.regions().begin(), request.bytes.regions().end(),
            [&](const MemoryRegion& candidate) {
                return candidate.readable() && !candidate.executable() && !candidate.writable() &&
                    applied.address >= candidate.startAddress &&
                    applied.address + applied.byteCount <= candidate.endAddressExclusive();
            }
        );
        auto* type = factory.findByName(applied.typeDefinitionName);
        if (region == request.bytes.regions().end() || type == nullptr ||
            static_cast<std::uint64_t>(type->getSize()) != applied.byteCount) {
            throw ContractError("authoring-input-unsupported");
        }
        const ghidra::Address address(&codeSpace, applied.address);
        const auto authoredName = std::find_if(
            request.authoredInputs.names.begin(), request.authoredInputs.names.end(),
            [&](const AuthoredName& name) {
                return name.subjectKind == AuthoredNameSubjectKind::data &&
                    name.address == applied.address;
            }
        );
        auto* entry = globalScope.addSymbol(
            authoredName == request.authoredInputs.names.end()
                ? "__macscope_authored_object_" + std::to_string(applied.address)
                : authoredName->name,
            type,
            address,
            ghidra::Address()
        );
        if (entry == nullptr || entry->getSymbol() == nullptr || entry->getAddr() != address ||
            entry->getSymbol()->getType() != type ||
            (authoredName != request.authoredInputs.names.end() &&
             entry->getSymbol()->getName() != authoredName->name) ||
            entry->getLast() != applied.address + applied.byteCount - 1U ||
            globalScope.queryFunction(address) != nullptr) {
            throw ContractError("authoring-input-unsupported");
        }
        if (observer && observer->authoredAppliedReadback) {
            observer->authoredAppliedReadback(
                applied.address,
                applied.byteCount,
                type->getName(),
                false
            );
        }
    }
    for (const auto& name : request.authoredInputs.names) {
        if (name.subjectKind != AuthoredNameSubjectKind::data) continue;
        cancellation.throwIfCancelled();
        const ghidra::Address address(&codeSpace, name.address);
        const auto applied = std::find_if(
            request.authoredInputs.appliedTypes.begin(), request.authoredInputs.appliedTypes.end(),
            [&](const AppliedType& object) {
                return name.address >= object.address &&
                    name.address - object.address < object.byteCount;
            }
        );
        // An interior name cannot silently rename an enclosing typed object.
        if (applied != request.authoredInputs.appliedTypes.end() &&
            name.address != applied->address) throw ContractError("authoring-input-unsupported");
        if (applied == request.authoredInputs.appliedTypes.end()) {
            auto* entry = globalScope.addSymbol(name.name, factory.getBase(1, ghidra::TYPE_UNKNOWN),
                                                address, ghidra::Address());
            if (entry == nullptr || entry->getSymbol() == nullptr ||
                entry->getAddr() != address || entry->getLast() != name.address ||
                entry->getSymbol()->getName() != name.name) {
                throw ContractError("authoring-input-unsupported");
            }
        }
        const auto* installed = globalScope.findContainer(address, 1, ghidra::Address());
        if (installed == nullptr || installed->getSymbol() == nullptr ||
            installed->getAddr() != address || installed->getSymbol()->getName() != name.name ||
            globalScope.queryFunction(address) != nullptr) {
            throw ContractError("authoring-input-unsupported");
        }
        if (observer && observer->authoredNameReadback) {
            observer->authoredNameReadback(name.address, installed->getSymbol()->getName(), false);
        }
    }
    if (prototype.numParams() != parameterCountBefore ||
        prototype.getOutputType() != outputTypeBefore ||
        prototype.isInputLocked() != inputLockBefore ||
        prototype.isOutputLocked() != outputLockBefore ||
        prototype.isDotdotdot() != variadicBefore ||
        prototype.isNoReturn() != noReturnBefore) {
        throw ContractError("authoring-input-unsupported");
    }
}

static void applyAuthoredParameterStorage(
    ghidra::FuncProto& prototype,
    const ghidra::PrototypePieces& pieces,
    const std::vector<AuthoredParameter>& parameters,
    const ghidra::Translate& translate
) {
    for (std::size_t index = 0; index < parameters.size(); ++index) {
        const auto& parameter = parameters[index];
        if (!parameter.storageRegister) continue;
        const ghidra::VarnodeData* reg = nullptr;
        try {
            reg = &translate.getRegister(*parameter.storageRegister);
        } catch (const ghidra::SleighError&) {
            throw ContractError("authoring-input-unsupported");
        } catch (const ghidra::LowlevelError&) {
            throw ContractError("authoring-input-unsupported");
        }
        ghidra::Datatype* type = pieces.intypes[index];
        if (static_cast<ghidra::int4>(reg->size) != type->getSize()) {
            throw ContractError("authoring-input-unsupported");
        }
        ghidra::ParameterPieces piece{};
        piece.addr = ghidra::Address(reg->space, reg->offset);
        piece.type = type;
        piece.flags = ghidra::ParameterPieces::typelock | ghidra::ParameterPieces::namelock;
        prototype.setParam(static_cast<ghidra::int4>(index), parameter.name, piece);
    }
    prototype.setInputLock(true);
}

/// Authored-input v2 callee hints: each becomes the callee's named, locked
/// prototype so its call sites carry typed arguments. An authored signature
/// (already installed) wins; a hint never touches the decompiled function.
void installCalleeSignatureHints(
    const AnalysisRequestView& request,
    ghidra::Funcdata& function,
    ghidra::Scope& globalScope,
    ghidra::AddrSpace& codeSpace,
    const CancellationToken& cancellation,
    AuthoredQualifierRenderNames& renderNames
) {
    auto& factory = *function.getArch()->types;
    for (const auto& hint : request.authoredInputs.calleeSignatureHints) {
        cancellation.throwIfCancelled();
        const auto& signature = hint.signature;
        if (signature.functionAddress == request.function.entryAddress) continue;
        const ghidra::Address address(&codeSpace, signature.functionAddress);
        auto* subject = globalScope.queryFunction(address);
        if (subject == nullptr) {
            auto* installed = globalScope.addFunction(address, hint.name);
            subject = installed == nullptr ? nullptr : installed->getFunction();
        }
        if (subject == nullptr) continue;
        auto& prototype = subject->getFuncProto();
        if (prototype.isInputLocked() || prototype.isOutputLocked()) continue;
        ghidra::PrototypePieces pieces{};
        prototype.getPieces(pieces);
        if (signature.returnType != nullptr) {
            pieces.outtype = resolveAuthoredCatalogType(*signature.returnType, factory, renderNames);
        }
        pieces.intypes.clear();
        pieces.innames.clear();
        for (const auto& parameter : signature.parameters) {
            pieces.intypes.push_back(resolveAuthoredCatalogType(parameter.type, factory, renderNames));
            pieces.innames.push_back(parameter.name);
        }
        // Each axis applies only when the hint states it, like an authored signature:
        // an unspecified variadic or return state leaves the prototype's own (#684).
        if (signature.variadicState == AuthoredVariadicState::variadic) {
            pieces.firstVarArgSlot = static_cast<ghidra::int4>(signature.parameters.size());
        } else if (signature.variadicState == AuthoredVariadicState::fixed) {
            pieces.firstVarArgSlot = -1;
        }
        prototype.setPieces(pieces);
        prototype.setOutputLock(signature.returnType != nullptr);
        prototype.setInputLock(true);
        applyAuthoredParameterStorage(
            prototype, pieces, signature.parameters, *function.getArch()->translate);
        if (signature.variadicState == AuthoredVariadicState::fixed) {
            prototype.setDotdotdot(false);
        } else if (signature.variadicState == AuthoredVariadicState::variadic) {
            prototype.setDotdotdot(true);
        }
        if (signature.noReturnState == AuthoredNoReturnState::returns) {
            prototype.setNoReturn(false);
        } else if (signature.noReturnState == AuthoredNoReturnState::noReturn) {
            prototype.setNoReturn(true);
        }
    }
}

/// Authored-input v3 stack locals (DP04 C1b): each becomes a name-locked local
/// symbol at its entry-SP offset before decompilation. A typed entry is type-locked
/// when the authored type has the slot's size; otherwise the slot is size-locked
/// (an undefined type of its width), which keeps the symbol through
/// `clearUnlocked` while letting the decompiler infer the type.
void installAuthoredStackLocals(
    const AnalysisRequestView& request,
    ghidra::Funcdata& function,
    const CancellationToken& cancellation,
    AuthoredQualifierRenderNames& renderNames
) {
    auto* stackSpace = function.getArch()->getStackSpace();
    auto* scope = function.getScopeLocal();
    if (stackSpace == nullptr || scope == nullptr) return;
    auto& factory = *function.getArch()->types;
    for (const auto& local : request.authoredInputs.localNames) {
        cancellation.throwIfCancelled();
        if (local.storageKind != AuthoredLocalStorageKind::stack) continue;
        ghidra::Datatype* type = local.type == nullptr ? nullptr
            : resolveAuthoredCatalogType(*local.type, factory, renderNames);
        if (type == nullptr || type->getSize() != static_cast<ghidra::int4>(local.byteSize)) {
            type = factory.getBase(static_cast<ghidra::int4>(local.byteSize), ghidra::TYPE_UNKNOWN);
        }
        const auto offset = static_cast<ghidra::uintb>(static_cast<ghidra::intb>(local.stackOffset));
        const ghidra::Address address(stackSpace, stackSpace->wrapOffset(offset));
        if (scope->findContainer(address, static_cast<ghidra::int4>(local.byteSize), ghidra::Address()) != nullptr) {
            continue;
        }
        auto* entry = scope->addSymbol(scope->makeNameUnique(local.name), type, address, ghidra::Address());
        if (entry == nullptr) continue;
        scope->setAttribute(entry->getSymbol(), ghidra::Varnode::namelock | ghidra::Varnode::typelock);
    }
}

/// Authored-input v3 register names: after decompilation, every variable whose
/// storage is the named GPR (its x or w view) takes the name; a second distinct
/// variable in the same register gets a unique suffix. Parameters and name-locked
/// symbols (signatures, authored stack locals) keep their names.
void applyAuthoredRegisterNames(const AnalysisRequestView& request, ghidra::Funcdata& function) {
    std::unordered_map<std::string, std::string> names;
    for (const auto& local : request.authoredInputs.localNames) {
        if (local.storageKind == AuthoredLocalStorageKind::register_) names[local.registerName] = local.name;
    }
    if (names.empty()) return;
    auto* scope = function.getScopeLocal();
    const auto* translate = function.getArch()->translate;
    if (scope == nullptr || translate == nullptr) return;
    std::set<const ghidra::HighVariable*> renamed;
    for (auto iterator = function.beginLoc(); iterator != function.endLoc(); ++iterator) {
        auto* varnode = *iterator;
        if (varnode == nullptr || varnode->isFree() || varnode->isAnnotation() ||
            varnode->getSpace()->getType() != ghidra::IPTR_PROCESSOR) continue;
        auto registerName = translate->getRegisterName(varnode->getSpace(), varnode->getOffset(), varnode->getSize());
        if (registerName.size() >= 2U && registerName[0] == 'w') registerName[0] = 'x';
        const auto found = names.find(registerName);
        if (found == names.end()) continue;
        ghidra::HighVariable* high = nullptr;
        try { high = varnode->getHigh(); } catch (const ghidra::LowlevelError&) { continue; }
        if (high == nullptr || high->isPersist() || renamed.contains(high)) continue;
        auto* symbol = high->getSymbol();
        if (symbol == nullptr || symbol->getScope() != scope || symbol->isNameLocked() ||
            symbol->getCategory() == ghidra::Symbol::function_parameter) continue;
        scope->renameSymbol(symbol, scope->makeNameUnique(found->second));
        renamed.insert(high);
    }
}

// Spell register storage with the translator, otherwise as space:0xoffset.
static std::string spellStorage(
    const ghidra::Translate& translate, const ghidra::Address& address, ghidra::int4 size
) {
    if (address.isInvalid()) return "invalid";
    const auto name = translate.getRegisterName(address.getSpace(), address.getOffset(), size);
    if (!name.empty()) return name;
    std::ostringstream storage;
    storage << address.getSpace()->getName() << ":0x" << std::hex << address.getOffset();
    return storage.str();
}

static GhidraProviderObserver::SignatureReadback authoredSignatureReadback(
    const ghidra::FuncProto& prototype, const ghidra::Translate& translate, bool afterAnalysis
) {
    GhidraProviderObserver::SignatureReadback readback;
    readback.afterAnalysis = afterAnalysis;
    readback.variadic = prototype.isDotdotdot();
    readback.noReturn = prototype.isNoReturn();
    readback.inputLocked = prototype.isInputLocked();
    readback.outputLocked = prototype.isOutputLocked();
    if (const auto* output = prototype.getOutputType(); output != nullptr) {
        readback.outputTypeName = output->getName();
        readback.outputTypeSize = output->getSize();
    }
    if (const auto* output = prototype.getOutput(); output != nullptr &&
        output->getType() != nullptr && output->getType()->getMetatype() != ghidra::TYPE_VOID) {
        readback.outputStorage = spellStorage(translate, output->getAddress(), output->getSize());
    }
    for (ghidra::int4 index = 0; index < prototype.numParams(); ++index) {
        const auto* parameter = prototype.getParam(index);
        if (parameter == nullptr || parameter->getType() == nullptr) {
            throw ContractError("authoring-input-unsupported");
        }
        readback.parameterStorage.push_back(spellStorage(translate, parameter->getAddress(), parameter->getSize()));
        readback.parameterNames.push_back(parameter->getName());
        readback.parameterTypeNames.push_back(parameter->getType()->getName());
        readback.parameterTypeSizes.push_back(parameter->getType()->getSize());
    }
    return readback;
}

void installAuthoredSignatureAxes(
    const AnalysisRequestView& request,
    ghidra::Funcdata& function,
    ghidra::Scope& globalScope,
    ghidra::AddrSpace& codeSpace,
    const CancellationToken& cancellation,
    const std::shared_ptr<GhidraProviderObserver>& observer,
    AuthoredQualifierRenderNames& renderNames
) {
    auto& factory = *function.getArch()->types;
    for (const auto& signature : request.authoredInputs.signatures) {
        cancellation.throwIfCancelled();
        if (signature.functionAddress % 4U != 0U ||
            !std::any_of(request.bytes.regions().begin(), request.bytes.regions().end(),
                [&](const MemoryRegion& region) {
                    return region.readable() && region.executable() && !region.writable() &&
                        signature.functionAddress >= region.startAddress &&
                        signature.functionAddress < region.endAddressExclusive() &&
                        region.endAddressExclusive() - signature.functionAddress >= 4U;
                }) ||
            (signature.parameterListState == AuthoredParameterListState::unspecified &&
             !signature.parameters.empty())) {
            throw ContractError("authoring-input-unsupported");
        }
        auto* subject = &function;
        if (signature.functionAddress != request.function.entryAddress) {
            const ghidra::Address address(&codeSpace, signature.functionAddress);
            subject = globalScope.queryFunction(address);
            if (subject == nullptr) {
                const auto symbol = request.symbols.preferred(signature.functionAddress);
                auto* installed = globalScope.addFunction(address,
                    symbol ? symbol->name : "__macscope_callee_" + std::to_string(signature.functionAddress));
                subject = installed == nullptr ? nullptr : installed->getFunction();
            }
            if (subject == nullptr) throw ContractError("authoring-input-unsupported");
        }
        auto& prototype = subject->getFuncProto();
        const bool authorsReturn = signature.returnType != nullptr;
        const bool authorsParameters =
            signature.parameterListState == AuthoredParameterListState::authoritative;
        if (authorsReturn || authorsParameters) {
            const bool priorInputLock = prototype.isInputLocked();
            const bool priorOutputLock = prototype.isOutputLocked();
            ghidra::PrototypePieces pieces{};
            prototype.getPieces(pieces);
            if (authorsReturn) {
                pieces.outtype = resolveAuthoredCatalogType(*signature.returnType, factory, renderNames);
            }
            if (authorsParameters) {
                pieces.intypes.clear();
                pieces.innames.clear();
                for (const auto& parameter : signature.parameters) {
                    pieces.intypes.push_back(resolveAuthoredCatalogType(parameter.type, factory, renderNames));
                    pieces.innames.push_back(parameter.name);
                }
            }
            prototype.setPieces(pieces);
            prototype.setOutputLock(authorsReturn || priorOutputLock);
            prototype.setInputLock(authorsParameters || priorInputLock);
            if (authorsParameters) {
                applyAuthoredParameterStorage(
                    prototype, pieces, signature.parameters, *function.getArch()->translate);
            }
        }
        if (authorsReturn) {
            if (prototype.getOutputType() !=
                    resolveAuthoredCatalogType(*signature.returnType, factory, renderNames) ||
                !prototype.isOutputLocked()) {
                throw ContractError("authoring-input-unsupported");
            }
        }
        if (authorsParameters) {
            if (prototype.numParams() != static_cast<ghidra::int4>(signature.parameters.size()) ||
                !prototype.isInputLocked()) {
                throw ContractError("authoring-input-unsupported");
            }
            for (std::size_t index = 0; index < signature.parameters.size(); ++index) {
                const auto* installed = prototype.getParam(static_cast<ghidra::int4>(index));
                if (installed == nullptr || installed->getName() != signature.parameters[index].name ||
                    installed->getType() != resolveAuthoredCatalogType(signature.parameters[index].type, factory, renderNames)) {
                    throw ContractError("authoring-input-unsupported");
                }
            }
        }
        if (signature.variadicState == AuthoredVariadicState::fixed) {
            prototype.setDotdotdot(false);
        } else if (signature.variadicState == AuthoredVariadicState::variadic) {
            prototype.setDotdotdot(true);
        }
        if (signature.noReturnState == AuthoredNoReturnState::returns) {
            prototype.setNoReturn(false);
        } else if (signature.noReturnState == AuthoredNoReturnState::noReturn) {
            prototype.setNoReturn(true);
        }
        if ((signature.variadicState == AuthoredVariadicState::fixed &&
             prototype.isDotdotdot()) ||
            (signature.variadicState == AuthoredVariadicState::variadic &&
             !prototype.isDotdotdot()) ||
            (signature.noReturnState == AuthoredNoReturnState::returns &&
             prototype.isNoReturn()) ||
            (signature.noReturnState == AuthoredNoReturnState::noReturn &&
             !prototype.isNoReturn())) {
            throw ContractError("authoring-input-unsupported");
        }
    }
    if (std::any_of(request.authoredInputs.signatures.begin(), request.authoredInputs.signatures.end(),
            [&](const AuthoredSignature& signature) {
                return signature.functionAddress == request.function.entryAddress;
            }) && observer &&
        observer->authoredSignatureReadback) {
        observer->authoredSignatureReadback(authoredSignatureReadback(
            function.getFuncProto(), *function.getArch()->translate, false));
    }
}

[[nodiscard]] std::string hex16(std::uint64_t value) {
    char digits[16];
    std::fill(std::begin(digits), std::end(digits), '0');
    char temporary[16];
    const auto converted = std::to_chars(std::begin(temporary), std::end(temporary), value, 16);
    if (converted.ec != std::errc{}) {
        throw ContractError("native-provider-identity-format-failed");
    }
    const auto length = static_cast<std::size_t>(converted.ptr - std::begin(temporary));
    std::copy(std::begin(temporary), converted.ptr, std::end(digits) - length);
    return {std::begin(digits), std::end(digits)};
}

[[nodiscard]] std::uint64_t fnv1a64(std::string_view value) {
    std::uint64_t digest = 1469598103934665603ULL;
    for (const unsigned char byte : value) {
        digest ^= byte;
        digest *= 1099511628211ULL;
    }
    return digest;
}

[[nodiscard]] std::string nativeTypeKind(ghidra::type_metatype metatype) {
    switch (metatype) {
    case ghidra::TYPE_VOID: return "void";
    case ghidra::TYPE_SPACEBASE: return "unknown";
    case ghidra::TYPE_UNKNOWN: return "unknown";
    case ghidra::TYPE_INT:
    case ghidra::TYPE_UINT: return "integer";
    case ghidra::TYPE_BOOL: return "boolean";
    case ghidra::TYPE_CODE: return "function";
    case ghidra::TYPE_FLOAT: return "floatingPoint";
    case ghidra::TYPE_PTR:
    case ghidra::TYPE_PTRREL: return "pointer";
    case ghidra::TYPE_ARRAY: return "array";
    case ghidra::TYPE_ENUM_UINT:
    case ghidra::TYPE_ENUM_INT: return "enumeration";
    case ghidra::TYPE_STRUCT: return "structure";
    case ghidra::TYPE_UNION: return "union";
    case ghidra::TYPE_PARTIALENUM:
    case ghidra::TYPE_PARTIALSTRUCT:
    case ghidra::TYPE_PARTIALUNION: return "unknown";
    }
    throw ContractError("native-provider-type-kind-unsupported");
}

void requireNativeText(std::string_view value, std::size_t maximum, bool allowEmpty) {
    if ((!allowEmpty && value.empty()) || value.size() > maximum) {
        throw ContractError("native-provider-text-invalid");
    }
    for (const unsigned char character : value) {
        if (character < 0x20U || character == 0x7fU) {
            throw ContractError("native-provider-text-invalid");
        }
    }
}

[[nodiscard]] std::string spaceKind(ghidra::spacetype type) {
    switch (type) {
    case ghidra::IPTR_CONSTANT: return "constant";
    case ghidra::IPTR_PROCESSOR: return "processor";
    case ghidra::IPTR_SPACEBASE: return "spacebase";
    case ghidra::IPTR_INTERNAL: return "unique";
    case ghidra::IPTR_FSPEC: return "fspec";
    case ghidra::IPTR_IOP: return "iop";
    case ghidra::IPTR_JOIN: return "join";
    }
    throw ContractError("native-provider-address-space-unsupported");
}

[[nodiscard]] SourceRange instructionRange(
    const AnalysisRequestView& request,
    Address start,
    Address end
) {
    return {request.image.imageId, start, end};
}

class CapturingAssemblyEmitter final : public ghidra::AssemblyEmit {
public:
    void dump(
        const ghidra::Address& address,
        const std::string& mnemonic,
        const std::string& body
    ) override {
        if (count_ != 0U || address.isInvalid()) {
            throw ContractError("native-provider-assembly-callback-invalid");
        }
        ++count_;
        address_ = static_cast<Address>(address.getOffset());
        mnemonic_ = mnemonic;
        body_ = body;
    }

    [[nodiscard]] std::size_t count() const noexcept { return count_; }
    [[nodiscard]] Address address() const noexcept { return address_; }
    [[nodiscard]] const std::string& mnemonic() const noexcept { return mnemonic_; }
    [[nodiscard]] const std::string& body() const noexcept { return body_; }

private:
    std::size_t count_ = 0U;
    Address address_ = 0;
    std::string mnemonic_;
    std::string body_;
};

struct BudgetGuard final : detail::GhidraRequestCheckpoint {
    BudgetGuard(const AnalysisRequestView& requestValue, const CancellationToken& cancellationValue)
        : request(requestValue), cancellation(cancellationValue), started(std::chrono::steady_clock::now()) {}

    void checkpoint() const override {
        cancellation.throwIfCancelled();
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started
        );
        if (elapsed.count() < 0 ||
            static_cast<std::uint64_t>(elapsed.count()) > request.budgets.maxWallTimeMilliseconds) {
            throw ContractError("native-provider-wall-time-budget-exceeded");
        }
    }

    const AnalysisRequestView& request;
    const CancellationToken& cancellation;
    std::chrono::steady_clock::time_point started;
};

using detail::DecodedInstruction;

[[nodiscard]] std::vector<DecodedInstruction> decodeInstructions(
    const AnalysisRequestView& request,
    const ghidra::Translate& translator,
    ghidra::AddrSpace* codeSpace,
    const BudgetGuard& budget
) {
    std::vector<DecodedInstruction> decoded;
    const auto codeRanges = request.function.codeRanges.empty()
        ? std::vector<FunctionIdentity::CodeRange>{{request.function.entryAddress, request.function.endAddressExclusive}}
        : request.function.codeRanges;
    for (const auto& codeRange : codeRanges) {
    Address cursor = codeRange.startAddress;
    while (cursor < codeRange.endAddressExclusive) {
        budget.checkpoint();
        if (decoded.size() >= request.budgets.maxInstructions) {
            throw ContractError("native-provider-instruction-budget-exceeded");
        }
        const ghidra::Address nativeAddress(codeSpace, cursor);
        const auto nativeLength = translator.instructionLength(nativeAddress);
        if (nativeLength <= 0 || nativeLength > 32) {
            throw ContractError("native-provider-instruction-length-invalid");
        }
        const auto length = static_cast<std::size_t>(nativeLength);
        if (length > codeRange.endAddressExclusive - cursor) {
            throw ContractError("native-provider-instruction-range-invalid");
        }
        const Address end = cursor + static_cast<Address>(length);

        CapturingAssemblyEmitter emitter;
        const auto emittedLength = translator.printAssembly(emitter, nativeAddress);
        if (emittedLength != nativeLength || emitter.count() != 1U || emitter.address() != cursor) {
            throw ContractError("native-provider-assembly-callback-invalid");
        }
        requireNativeText(emitter.mnemonic(), 256U, false);
        requireNativeText(emitter.body(), kMaximumAssemblyText, true);

        InstructionRecord instruction;
        instruction.id = "insn:" + hex16(cursor);
        instruction.address = cursor;
        instruction.bytes = request.bytes.readEffective(cursor, length);
        instruction.mnemonic = emitter.mnemonic();
        instruction.body = emitter.body();
        instruction.sourceRanges.push_back(instructionRange(request, cursor, end));
        decoded.push_back({std::move(instruction), end});
        cursor = end;
    }
    if (cursor != codeRange.endAddressExclusive) {
        throw ContractError("native-provider-instruction-coverage-incomplete");
    }
    }
    if (decoded.empty()) throw ContractError("native-provider-instruction-coverage-incomplete");
    return decoded;
}

class PacCompanionEmitter final : public ghidra::PcodeEmit {
public:
    PacCompanionEmitter(
        std::string userOperationName,
        std::string mnemonic,
        std::vector<std::string> userOperationNames
    ) : userOperationName_(std::move(userOperationName)),
        userOperationNames_(std::move(userOperationNames)) {
        descriptor.userOperationName = userOperationName_;
        descriptor.mnemonic = std::move(mnemonic);
    }

    void dump(
        const ghidra::Address&,
        ghidra::OpCode nativeOpcode,
        ghidra::VarnodeData* output,
        ghidra::VarnodeData* inputs,
        ghidra::int4 inputCount
    ) override {
        detail::PacCompanionOpcode opcode = detail::PacCompanionOpcode::other;
        switch (nativeOpcode) {
        case ghidra::CPUI_COPY: opcode = detail::PacCompanionOpcode::copy; break;
        case ghidra::CPUI_LOAD: opcode = detail::PacCompanionOpcode::load; break;
        case ghidra::CPUI_BRANCHIND:
            opcode = detail::PacCompanionOpcode::branchIndirect;
            break;
        case ghidra::CPUI_CALLIND:
            opcode = detail::PacCompanionOpcode::callIndirect;
            break;
        case ghidra::CPUI_RETURN: opcode = detail::PacCompanionOpcode::return_; break;
        default: break;
        }
        detail::PacCompanionOperation operation{
            .opcode = opcode,
            .output = output == nullptr ? std::nullopt : std::optional{idFor(*output)},
        };
        for (ghidra::int4 index = 0; index < inputCount; ++index) {
            operation.inputs.emplace_back(idFor(inputs[index]));
        }
        if (nativeOpcode == ghidra::CPUI_CALLOTHER && inputCount > 0 &&
            inputs[0].space != nullptr && inputs[0].space->getType() == ghidra::IPTR_CONSTANT &&
            inputs[0].offset < userOperationNames_.size()) {
            const auto& name = userOperationNames_[static_cast<std::size_t>(inputs[0].offset)];
            operation.exceptionReturn = name == "ExceptionReturn";
            if (name == userOperationName_) {
                descriptor.authenticationIndex = descriptor.operations.size();
                foundAuthentication_ = true;
            }
        }
        descriptor.operations.emplace_back(std::move(operation));
    }

    [[nodiscard]] detail::PacCompanionDescriptor finish() {
        if (!foundAuthentication_) {
            throw ContractError("native-provider-pac-operation-index-invalid");
        }
        return std::move(descriptor);
    }

    detail::PacCompanionDescriptor descriptor;

private:
    [[nodiscard]] std::uintptr_t idFor(const ghidra::VarnodeData& varnode) {
        const auto key = std::tuple{varnode.space, varnode.offset, varnode.size};
        const auto [iterator, inserted] = varnodeIds_.try_emplace(key, nextVarnodeId_);
        if (inserted) ++nextVarnodeId_;
        return iterator->second;
    }

    std::string userOperationName_;
    std::vector<std::string> userOperationNames_;
    std::map<std::tuple<ghidra::AddrSpace*, ghidra::uintb, ghidra::int4>, std::uintptr_t>
        varnodeIds_;
    std::uintptr_t nextVarnodeId_ = 1U;
    bool foundAuthentication_ = false;
};

[[nodiscard]] detail::PacCompanionDescriptor rawPacCompanionDescriptor(
    const ghidra::Translate& translator,
    ghidra::AddrSpace* codeSpace,
    const DecodedInstruction& instruction,
    std::string userOperationName
) {
    if (codeSpace == nullptr) {
        throw ContractError("native-provider-code-space-unavailable");
    }
    std::vector<std::string> userOperationNames;
    translator.getUserOpNames(userOperationNames);
    PacCompanionEmitter emitter(
        std::move(userOperationName),
        instruction.record.mnemonic,
        std::move(userOperationNames)
    );
    const auto length = translator.oneInstruction(
        emitter, ghidra::Address(codeSpace, instruction.record.address)
    );
    if (length <= 0 || instruction.record.address + static_cast<Address>(length) !=
            instruction.endAddressExclusive) {
        throw ContractError("native-provider-instruction-length-invalid");
    }
    return emitter.finish();
}

struct NativeOperation final {
    const ghidra::PcodeOp* operation = nullptr;
    std::string id;
    ghidra::OpCode opcode = ghidra::CPUI_MAX;
    std::string opcodeName;
    std::size_t blockIndex = 0U;
    std::size_t instructionIndex = 0U;
    std::uint64_t sequence = 0;
};

struct NativeBlock final {
    const ghidra::BlockBasic* block = nullptr;
    Address nativeEntryAddress = 0;
    BlockRecord record;
    std::vector<std::size_t> instructionIndices;
    std::vector<std::size_t> operationIndices;
    std::vector<std::optional<std::string>> incomingEdgeIds;
};

struct NativeCall final {
    const ghidra::FuncCallSpecs* specification = nullptr;
    std::optional<Address> targetAddress;
};

struct SemanticVarnode final {
    VarnodeRecord record;
    std::string rankedDescriptor;
};

struct RegionLeafSet final {
    std::vector<std::size_t> blockIndices;
};

class IncrementalOutputMeter final {
    using Diagnostics = OutputBudgetDiagnostics;
    using Category = Diagnostics::Category;
    using Failure = Diagnostics::Failure;
public:
    explicit IncrementalOutputMeter(std::size_t maximum) : maximum_(maximum) {
        add(16384U, Category::schemaReserve);
    }

    // Mirrors the output-size model v3 text charge in OutputModel.cpp: every
    // occurrence costs 8 bytes and each distinct text one 16-byte object plus
    // its content (1 byte per UTF-8 byte for ASCII, otherwise the maximum).
    // The final exact check requires used() to equal that estimate.
    void addText(std::string_view value) {
        add(8U, Category::textOccurrences);
        if (!seen_.emplace(value).second) return;
        add(16U, Category::distinctTextObjects);
        const bool ascii = std::all_of(value.begin(), value.end(), [](char byte) {
            return static_cast<unsigned char>(byte) < 0x80U;
        });
        addProduct(value.size(), ascii ? 1U : kMaximumEncodedBytesPerTextByte,
                   Category::distinctTextContent);
    }

    void addScalar() { add(32U, Category::scalars); }
    void addRecord() { add(48U, Category::records); }
    void addContainer() { add(16U, Category::containers); }

    void addProduct(std::size_t count, std::size_t width) {
        addProduct(count, width, Category::instructionBytes);
    }

    void requireAdditionalProduct(std::size_t count, std::size_t width) const {
        if (width != 0U && count > std::numeric_limits<std::size_t>::max() / width) {
            fail(Failure::productOverflow, Category::preflight, count, width, std::nullopt);
        }
        const auto value = count * width;
        if (value > maximum_ - std::min(used_, maximum_)) {
            fail(Failure::preflightExceedsLimit, Category::preflight, count, width, value);
        }
    }

    [[noreturn]] void failCumulativeCountOverflow(std::size_t count,
                                                  std::size_t increment) const {
        // These are the two operands of a count addition, not a byte product.
        fail(Failure::cumulativeCountOverflow, Category::preflight,
             count, increment, std::nullopt);
    }

    void addSourceRange(const SourceRange& range) {
        add(16U, Category::containers);
        addText(range.imageId);
        addText(hex16(range.startAddress));
        addText(hex16(range.endAddressExclusive));
    }

    [[nodiscard]] std::size_t used() const noexcept { return used_; }

private:
    [[noreturn]] void fail(Failure failure, Category category, std::size_t count,
                          std::size_t width, std::optional<std::size_t> value) const {
        auto diagnostics = diagnostics_;
        diagnostics.maximumBytes = maximum_;
        diagnostics.usedBytes = used_;
        diagnostics.failure = failure;
        diagnostics.attemptedCategory = category;
        diagnostics.attemptedCount = count;
        diagnostics.attemptedWidth = width;
        diagnostics.attemptedBytes = value;
        throw ContractError("native-provider-output-budget-exceeded", diagnostics);
    }

    void addProduct(std::size_t count, std::size_t width, Category category) {
        if (width != 0U && count > std::numeric_limits<std::size_t>::max() / width) {
            fail(Failure::productOverflow, category, count, width, std::nullopt);
        }
        add(count * width, category);
    }

    void add(std::size_t value, Category category) {
        if (value > maximum_ - std::min(used_, maximum_)) {
            fail(Failure::chargeExceedsLimit, category, value, 1U, value);
        }
        used_ += value;
        // A component cannot overflow: all components are nonnegative and
        // their sum is used_, whose original checked addition just succeeded.
        switch (category) {
        case Category::schemaReserve: diagnostics_.schemaReserveBytes += value; break;
        case Category::textOccurrences: diagnostics_.textOccurrenceBytes += value; break;
        case Category::distinctTextObjects: diagnostics_.distinctTextObjectBytes += value; break;
        case Category::distinctTextContent: diagnostics_.distinctTextContentBytes += value; break;
        case Category::scalars: diagnostics_.scalarBytes += value; break;
        case Category::records: diagnostics_.recordBytes += value; break;
        case Category::containers: diagnostics_.containerBytes += value; break;
        case Category::instructionBytes: diagnostics_.instructionByteBytes += value; break;
        case Category::preflight: break; // Preflights never call add().
        }
    }

    std::size_t maximum_ = 0U;
    std::size_t used_ = 0U;
    Diagnostics diagnostics_;
    std::unordered_set<std::string> seen_;
};

void validateOperationShape(
    const ghidra::PcodeOp& operation,
    const ghidra::TypeOp& type,
    ghidra::OpCode opcode
) {
    const auto arity = operation.numInput();
    const auto* output = operation.getOut();
    if (arity < 0) {
        throw ContractError("native-provider-operation-arity-invalid");
    }
    constexpr ghidra::uint4 evaluationMask = ghidra::PcodeOp::unary |
        ghidra::PcodeOp::binary | ghidra::PcodeOp::special | ghidra::PcodeOp::ternary;
    const auto evaluation = operation.getEvalType();
    if (evaluation != (type.getFlags() & evaluationMask)) {
        throw ContractError("native-provider-operation-evaluation-class-invalid");
    }
    switch (opcode) {
    case ghidra::CPUI_BRANCH:
        if (arity != 1 || output != nullptr) {
            throw ContractError("native-provider-branch-shape-invalid");
        }
        break;
    case ghidra::CPUI_CBRANCH:
        if (arity != 2 || output != nullptr) {
            throw ContractError("native-provider-conditional-shape-invalid");
        }
        break;
    case ghidra::CPUI_BRANCHIND:
        if (arity != 1 || output != nullptr) {
            throw ContractError("native-provider-indirect-branch-shape-invalid");
        }
        break;
    case ghidra::CPUI_LOAD:
        if (arity != 2 || output == nullptr) {
            throw ContractError("native-provider-load-shape-invalid");
        }
        break;
    case ghidra::CPUI_STORE:
        if (arity != 3 || output != nullptr) {
            throw ContractError("native-provider-store-shape-invalid");
        }
        break;
    case ghidra::CPUI_INDIRECT:
        if (arity != 2 || output == nullptr) {
            throw ContractError("native-provider-indirect-shape-invalid");
        }
        break;
    case ghidra::CPUI_CALL:
    case ghidra::CPUI_CALLIND:
        if (arity < 1) throw ContractError("native-provider-call-shape-invalid");
        break;
    case ghidra::CPUI_RETURN:
        if (output != nullptr) throw ContractError("native-provider-return-shape-invalid");
        break;
    case ghidra::CPUI_CALLOTHER:
        if (arity < 1 || operation.getIn(0) == nullptr ||
            !operation.getIn(0)->isConstant()) {
            throw ContractError("native-provider-user-operation-shape-invalid");
        }
        break;
    case ghidra::CPUI_CAST:
        // Ghidra classifies CAST as unary-special, so it never reaches the
        // functional default below; it is a legitimate one-input copy-like
        // operation emitted when a typed value meets a differently typed slot.
        if (arity != 1 || output == nullptr) {
            throw ContractError("native-provider-cast-shape-invalid");
        }
        break;
    case ghidra::CPUI_MULTIEQUAL:
        if (arity <= 0 || output == nullptr || operation.getParent() == nullptr ||
            arity != operation.getParent()->sizeIn()) {
            throw ContractError("native-provider-multiequal-shape-invalid");
        }
        break;
    default: {
        if (evaluation == ghidra::PcodeOp::unary) {
            if (arity != 1 || output == nullptr) {
                throw ContractError("native-provider-unary-operation-shape-invalid");
            }
        } else if (evaluation == ghidra::PcodeOp::binary) {
            if (arity != 2 || output == nullptr) {
                throw ContractError("native-provider-binary-operation-shape-invalid");
            }
        } else if (evaluation == ghidra::PcodeOp::ternary) {
            // The pinned native API deliberately classifies functional
            // operators with three or more inputs as "ternary (or higher)."
            if (arity < 3 || output == nullptr) {
                throw ContractError("native-provider-ternary-operation-shape-invalid");
            }
        } else {
            throw ContractError("native-provider-special-operation-unqualified");
        }
        break;
    }
    }
}

[[nodiscard]] std::optional<std::string> preferredCallableSymbol(
    const AnalysisRequestView& request,
    Address address
) {
    const auto authored = std::find_if(
        request.authoredInputs.names.begin(), request.authoredInputs.names.end(),
        [&](const AuthoredName& name) {
            return name.address == address &&
                name.subjectKind == AuthoredNameSubjectKind::function;
        }
    );
    if (authored != request.authoredInputs.names.end()) {
        return authored->name;
    }
    const auto exact = request.symbols.exact(address);
    const auto iterator = std::find_if(exact.begin(), exact.end(), [](const SymbolRecord& symbol) {
        return symbol.kind == "function";
    });
    if (iterator == exact.end()) {
        return std::nullopt;
    }
    return iterator->name;
}

[[nodiscard]] std::string ordinaryVarnodeRole(
    const ghidra::Varnode& varnode,
    const ghidra::Translate& translator
) {
    const auto type = varnode.getSpace()->getType();
    if (type == ghidra::IPTR_CONSTANT) return "constant";
    if (type == ghidra::IPTR_INTERNAL) return "unique";
    if (type == ghidra::IPTR_SPACEBASE) return "stack";
    if (type == ghidra::IPTR_FSPEC || type == ghidra::IPTR_IOP || varnode.isAnnotation()) {
        return "internal";
    }
    if (type == ghidra::IPTR_JOIN) return "join";
    const auto registerName = translator.getRegisterName(
        varnode.getSpace(), varnode.getOffset(), varnode.getSize()
    );
    if (!registerName.empty() || varnode.getSpace()->getName() == "register") return "register";
    return "memory";
}

[[nodiscard]] SsaValueRecord ssaValueFor(
    const ghidra::Varnode& varnode,
    const std::string& semanticVarnodeId,
    const std::unordered_map<const ghidra::PcodeOp*, std::string>& operationIds,
    const std::unordered_map<const ghidra::PcodeOp*, std::string>& phiIds
) {
    SsaValueRecord value;
    value.varnodeId = semanticVarnodeId;
    if (varnode.isAnnotation()) {
        value.id = "ssa:" + semanticVarnodeId + ":entry";
        value.kind = "annotation";
    } else if (varnode.isConstant()) {
        value.id = "ssa:" + semanticVarnodeId + ":entry";
        value.kind = "constant";
    } else if (varnode.isInput()) {
        value.id = "ssa:" + semanticVarnodeId + ":entry";
        value.kind = "functionEntry";
    } else if (const auto* definition = varnode.getDef(); definition != nullptr) {
        const auto iterator = operationIds.find(definition);
        if (iterator == operationIds.end()) {
            throw ContractError("native-provider-ssa-definition-unresolved");
        }
        // A native operation has exactly one output. Keep its location and
        // definition in their explicit fields instead of repeating them in IDs.
        if (definition->getOut() != &varnode) {
            throw ContractError("native-provider-ssa-definition-output-mismatch");
        }
        value.id = detail::definedSsaIdentity(iterator->second);
        const auto phi = phiIds.find(definition);
        if (phi != phiIds.end()) {
            value.kind = "phiResult";
            value.definingPhiId = phi->second;
        } else {
            value.kind = "operationResult";
            value.definingOperationId = iterator->second;
        }
    } else {
        throw ContractError("native-provider-ssa-input-unresolved");
    }
    return value;
}

struct NativeMarkupReference final {
    std::string kind;
    std::string id;
    std::vector<SourceRange> sourceRanges;
};

struct NativeMarkupIndex final {
    std::map<std::uint64_t, NativeMarkupReference> operations;
    std::map<std::uint64_t, NativeMarkupReference> varnodes;
    std::map<std::uint64_t, NativeMarkupReference> types;
    std::map<std::uint64_t, NativeMarkupReference> variables;
    std::map<std::int64_t, NativeMarkupReference> blocks;
};

struct NativeStructuredExport final {
    StructuredResult result;
    NativeMarkupIndex markup;
};

class NativeExportContext final {
public:
    NativeExportContext(
        const AnalysisRequestView& requestValue,
        ghidra::Funcdata& functionValue,
        const GhidraArchitecture& architectureValue,
        const BudgetGuard& budgetValue
    ) : request(requestValue),
        function(functionValue),
        architecture(architectureValue),
        budget(budgetValue),
        outputMeter(requestValue.budgets.maxOutputBytes) {
        if (architecture.translate == nullptr) {
            throw ContractError("native-provider-translator-unavailable");
        }
        architecture.translate->getUserOpNames(userOperationNames);
        if (userOperationNames.size() > 4096U) {
            throw ContractError("native-provider-user-operation-table-invalid");
        }
        for (const auto& name : userOperationNames) {
            budget.checkpoint();
            requireNativeText(name, 256U, false);
        }
        codeSpace = architecture.getDefaultCodeSpace();
        if (codeSpace == nullptr) {
            throw ContractError("native-provider-code-space-unavailable");
        }
        outputMeter.addText(request.requestId);
        outputMeter.addText(request.requestSha256);
        outputMeter.addText(request.image.imageId);
        outputMeter.addText(request.image.uuid);
        outputMeter.addScalar();
        outputMeter.addText(request.function.functionId);
        outputMeter.addText(request.function.name);
        outputMeter.addScalar();
        outputMeter.addScalar();
        for (std::size_t index = 0; index < request.function.codeRanges.size(); ++index) {
            outputMeter.addContainer();
            outputMeter.addScalar();
            outputMeter.addScalar();
        }
        const auto codeByteCount = request.effectiveFunctionBytes().size();
        if (codeByteCount == 0U || codeByteCount % 4U != 0U ||
            codeByteCount / 4U > std::numeric_limits<std::size_t>::max()) {
            throw ContractError("native-provider-instruction-coverage-invalid");
        }
        // Model-v3 lower bound: record48 + id8 + address32 + bytes20
        // + mnemonic8 + body8 + source-range16 + image8 + two addresses16.
        const auto minimumInstructionBytes = static_cast<std::size_t>(164U);
        outputMeter.requireAdditionalProduct(
            static_cast<std::size_t>(codeByteCount / 4U), minimumInstructionBytes
        );
        decoded = decodeInstructions(request, *architecture.translate, codeSpace, budget);
        for (const auto& instruction : decoded) {
            outputMeter.addRecord();
            outputMeter.addText(instruction.record.id);
            outputMeter.addScalar();
            outputMeter.addProduct(instruction.record.bytes.size(), 5U);
            outputMeter.addText(instruction.record.mnemonic);
            outputMeter.addText(instruction.record.body);
            for (const auto& range : instruction.record.sourceRanges) {
                outputMeter.addSourceRange(range);
            }
        }
        result.requestId = request.requestId;
        result.requestSha256 = request.requestSha256;
        result.image = request.image;
        result.function = request.function;
    }

    [[nodiscard]] NativeStructuredExport run() {
        const char* stage = "address-spaces";
        try {
        indexAddressSpaces();
        stage = "blocks";
        indexBlocks();
        stage = "operation-index";
        indexOperations();
        stage = "ownership";
        buildFinalOwnership();
        stage = "calls";
        indexCalls();
        stage = "varnodes";
        indexVarnodes();
        stage = "types";
        indexTypes();
        stage = "variables";
        indexVariables();
        stage = "phi-index";
        indexPhis();
        stage = "operations-ssa";
        emitOperationsAndSsa();
        stage = "edges";
        emitEdges();
        stage = "phis";
        emitPhis();
        stage = "regions";
        emitStructuredRegions();
        stage = "markup-index";
        auto markup = buildMarkupIndex();
        stage = "finish";
        finishResult();
        return {std::move(result), std::move(markup)};
        } catch (const ContractError& error) {
#if defined(__APPLE__)
            if (std::string_view(error.what()) == "native-provider-output-budget-exceeded") {
                // Static stage names and counts only: no user bytes, addresses,
                // symbols or request identities enter the diagnostic.
                os_log_error(OS_LOG_DEFAULT,
                    "MacScope native output-budget stage=%{public}s used=%{public}llu operations=%{public}llu varnodes=%{public}llu ssa=%{public}llu",
                    stage, static_cast<unsigned long long>(outputMeter.used()),
                    static_cast<unsigned long long>(nativeOperations.size()),
                    static_cast<unsigned long long>(varnodes.size()),
                    static_cast<unsigned long long>(ssaValues.size()));
            }
#else
            static_cast<void>(stage);
#endif
            throw;
        }
    }

private:
    [[nodiscard]] std::string userOperationNameFor(const ghidra::PcodeOp& operation) const {
        if (operation.code() != ghidra::CPUI_CALLOTHER || operation.numInput() < 1) {
            throw ContractError("native-provider-user-operation-shape-invalid");
        }
        const auto* selector = operation.getIn(0);
        if (isVolatileAccessOperation(operation)) {
            // pspec <volatile> ranges (AArch64 system registers 0x1000-0x2fff:
            // FPCR, FPSR, SVCR, ...) become builtin cRead/cWrite operations
            // whose ids sit outside the SLEIGH user-op table.
            const auto* builtin = architecture.userops.getOp(
                static_cast<ghidra::uint4>(selector->getOffset())
            );
            if (builtin == nullptr) {
                throw ContractError("native-provider-user-operation-identity-invalid");
            }
            requireNativeText(builtin->getName(), 256U, false);
            return builtin->getName();
        }
        if (selector == nullptr || !selector->isConstant() ||
            selector->getOffset() >= userOperationNames.size()) {
            throw ContractError("native-provider-user-operation-identity-invalid");
        }
        const auto& name = userOperationNames[static_cast<std::size_t>(selector->getOffset())];
        requireNativeText(name, 256U, false);
        return name;
    }

    [[nodiscard]] static bool isVolatileAccessOperation(const ghidra::PcodeOp& operation) noexcept {
        if (operation.code() != ghidra::CPUI_CALLOTHER || operation.numInput() < 2) return false;
        const auto* selector = operation.getIn(0);
        if (selector == nullptr || !selector->isConstant()) return false;
        const auto id = selector->getOffset();
        return id == ghidra::UserPcodeOp::BUILTIN_VOLATILE_READ ||
            id == ghidra::UserPcodeOp::BUILTIN_VOLATILE_WRITE;
    }

    [[nodiscard]] static bool isPacUserOperation(std::string_view name) noexcept {
        return std::find(kRequiredPacUserOps.begin(), kRequiredPacUserOps.end(), name) !=
            kRequiredPacUserOps.end();
    }

    [[nodiscard]] AuthenticationEffect authenticationEffectFor(
        const OperationRecord& operation,
        const SsaBindingRecord& binding,
        std::size_t nativeIndex
    ) const {
        if (!operation.userOperationName || !isPacUserOperation(*operation.userOperationName)) {
            return {};
        }
        if (operation.outputVarnodeId) {
            if (!binding.outputSsaValueId) {
                throw ContractError("native-provider-pac-output-ssa-missing");
            }
            return {
                AuthenticationEffectKind::transformedOutput,
                binding.outputSsaValueId,
            };
        }
        if (binding.outputSsaValueId) {
            throw ContractError("native-provider-pac-output-shape-invalid");
        }
        if (nativeIndex >= nativeOperations.size() ||
            nativeOperations[nativeIndex].operation == nullptr) {
            throw ContractError("native-provider-pac-operation-index-invalid");
        }
        const auto instructionIndex = nativeOperations[nativeIndex].instructionIndex;
        const auto& mnemonic = decoded[instructionIndex].record.mnemonic;
        if (mnemonic == "autibsp" && *operation.userOperationName == "AuthIB" &&
            operation.inputVarnodeIds.size() == 3U &&
            decoded[instructionIndex].record.bytes == std::vector<std::uint8_t>{0xffU, 0x23U, 0x03U, 0xd5U}) {
            return {AuthenticationEffectKind::standaloneAuthenticationWithoutTransformedOutput, std::nullopt};
        }
        const bool sealedMnemonic = mnemonic == "retaa" || mnemonic == "retab" ||
            mnemonic == "eretaa" || mnemonic == "eretab";
        detail::PacCompanionDescriptor descriptor{
            .userOperationName = *operation.userOperationName,
            .mnemonic = mnemonic,
        };
        if (sealedMnemonic) {
            descriptor = rawPacCompanionDescriptor(
                *architecture.translate,
                codeSpace,
                decoded[instructionIndex],
                *operation.userOperationName
            );
        } else {
            const auto varnodeId = [](const ghidra::Varnode* varnode)
                -> std::optional<std::uintptr_t> {
                if (varnode == nullptr) return std::nullopt;
                return reinterpret_cast<std::uintptr_t>(varnode);
            };
            for (std::size_t index = 0; index < nativeOperations.size(); ++index) {
                budget.checkpoint();
                const auto& candidate = nativeOperations[index];
                if (candidate.instructionIndex != nativeOperations[nativeIndex].instructionIndex) {
                    continue;
                }
                if (candidate.operation == nullptr) {
                    throw ContractError("native-provider-pac-companion-operation-invalid");
                }
                detail::PacCompanionOpcode opcode = detail::PacCompanionOpcode::other;
                switch (candidate.opcode) {
                case ghidra::CPUI_COPY: opcode = detail::PacCompanionOpcode::copy; break;
                case ghidra::CPUI_LOAD: opcode = detail::PacCompanionOpcode::load; break;
                case ghidra::CPUI_BRANCHIND:
                    opcode = detail::PacCompanionOpcode::branchIndirect;
                    break;
                case ghidra::CPUI_CALLIND:
                    opcode = detail::PacCompanionOpcode::callIndirect;
                    break;
                case ghidra::CPUI_RETURN:
                    opcode = detail::PacCompanionOpcode::return_;
                    break;
                default: break;
                }
                detail::PacCompanionOperation companion{
                    .opcode = opcode,
                    .output = varnodeId(candidate.operation->getOut()),
                };
                for (ghidra::int4 slot = 0; slot < candidate.operation->numInput(); ++slot) {
                    companion.inputs.emplace_back(varnodeId(candidate.operation->getIn(slot)));
                }
                if (candidate.opcode == ghidra::CPUI_CALLOTHER) {
                    companion.exceptionReturn =
                        userOperationNameFor(*candidate.operation) == "ExceptionReturn";
                }
                if (index == nativeIndex) {
                    descriptor.authenticationIndex = descriptor.operations.size();
                }
                descriptor.operations.emplace_back(std::move(companion));
            }
        }
        const auto companionKind = detail::classifyPacCompanionShape(descriptor);
        if (companionKind == detail::PacCompanionKind::authenticatedMemoryAccess &&
            (*operation.userOperationName == "AuthDA" ||
             *operation.userOperationName == "AuthDB")) {
            return {
                AuthenticationEffectKind::authenticatedMemoryAccessWithoutTransformedAddress,
                std::nullopt,
            };
        }
        if (companionKind == detail::PacCompanionKind::authenticatedControlTransfer &&
            (*operation.userOperationName == "AuthIA" ||
             *operation.userOperationName == "AuthIB" ||
             *operation.userOperationName == "AuthDA" ||
             *operation.userOperationName == "AuthDB")) {
            return {
                AuthenticationEffectKind::authenticatedControlTransferWithoutTransformedTarget,
                std::nullopt,
            };
        }
        throw ContractError("native-provider-pac-output-missing");
    }

    [[nodiscard]] NativeMarkupIndex buildMarkupIndex() const {
        NativeMarkupIndex index;
        for (const auto& operation : nativeOperations) {
            const auto time = operation.operation->getSeqNum().getTime();
            const auto address = operation.operation->getAddr().getOffset();
            if (!index.operations.emplace(
                    time,
                    NativeMarkupReference{
                        "operation",
                        operation.id,
                        {instructionRange(request, address, address + 4U)},
                    }
                ).second) {
                throw ContractError("native-provider-markup-operation-reference-duplicate");
            }
        }
        for (const auto& [native, semantic] : semanticVarnodes) {
            if (!index.varnodes.emplace(
                    native->getCreateIndex(),
                    NativeMarkupReference{"varnode", semantic.record.id, {}}
                ).second) {
                throw ContractError("native-provider-markup-varnode-reference-duplicate");
            }
        }
        // Markup names types by Ghidra's unsized id. When distinct exported types
        // share one (see typeIdFor), a token cannot say which it means, so those
        // type tokens stay unlinked instead of refusing the function.
        std::set<std::uint64_t> ambiguousTypeIds;
        for (const auto* type : nativeTypes) {
            const auto nativeId = type->getUnsizedId();
            if (nativeId == 0U || ambiguousTypeIds.contains(nativeId)) continue;
            const auto semantic = typeIds.find(type);
            if (semantic == typeIds.end()) {
                throw ContractError("native-provider-markup-type-reference-unresolved");
            }
            const auto [iterator, inserted] = index.types.emplace(
                nativeId,
                NativeMarkupReference{"type", semantic->second, {}}
            );
            if (!inserted && iterator->second.id != semantic->second) {
                index.types.erase(iterator);
                ambiguousTypeIds.insert(nativeId);
            }
        }
        std::set<std::uint64_t> ambiguousVariableSymbols;
        for (const auto& [id, variable] : variables) {
            static constexpr std::string_view prefix = "variable:symbol:";
            if (!id.starts_with(prefix)) continue;
            const auto suffix = std::string_view(id).substr(prefix.size());
            const auto delimiter = suffix.find(':');
            const auto encoded = suffix.substr(0, delimiter);
            std::uint64_t symbolId = 0U;
            const auto converted = std::from_chars(
                encoded.data(), encoded.data() + encoded.size(), symbolId, 16
            );
            if (converted.ec != std::errc{} || converted.ptr != encoded.data() + encoded.size()) {
                throw ContractError("native-provider-markup-symbol-reference-invalid");
            }
            if (ambiguousVariableSymbols.contains(symbolId)) continue;
            const auto [iterator, inserted] = index.variables.emplace(
                symbolId,
                NativeMarkupReference{"variable", variable.id, variable.liveRanges}
            );
            if (!inserted && iterator->second.id != variable.id) {
                index.variables.erase(iterator);
                ambiguousVariableSymbols.insert(symbolId);
            }
        }
        for (const auto& block : nativeBlocks) {
            if (!index.blocks.emplace(
                    block.block->getIndex(),
                    NativeMarkupReference{
                        "block",
                        block.record.id,
                        blockSourceRanges(blockIndices.at(block.block)),
                    }
                ).second) {
                throw ContractError("native-provider-markup-block-reference-duplicate");
            }
        }
        return index;
    }

    void appendBoundedDescriptor(std::string& descriptor, std::string_view fragment) {
        if (fragment.size() > kMaximumSpecialDescriptorText -
                std::min(descriptor.size(), kMaximumSpecialDescriptorText)) {
            throw ContractError("native-provider-special-descriptor-too-large");
        }
        descriptor.append(fragment);
    }

    void appendTypeDescriptor(std::string& descriptor, std::string_view fragment) const {
        if (fragment.size() > kMaximumTypeDescriptorText -
                std::min(descriptor.size(), kMaximumTypeDescriptorText)) {
            throw ContractError("native-provider-type-descriptor-too-large");
        }
        descriptor.append(std::to_string(fragment.size()));
        descriptor.push_back(':');
        descriptor.append(fragment);
        descriptor.push_back(';');
    }

    void appendTypeDescriptor(std::string& descriptor, std::int64_t value) const {
        appendTypeDescriptor(descriptor, std::to_string(value));
    }

    void describePrototype(
        const ghidra::FuncProto& prototype,
        std::vector<const ghidra::Datatype*>& active,
        std::string& descriptor
    ) {
        appendTypeDescriptor(descriptor, "prototype");
        appendTypeDescriptor(descriptor, prototype.hasModel() ? prototype.getModelName() : "");
        appendTypeDescriptor(descriptor, prototype.isDotdotdot() ? 1 : 0);
        appendTypeDescriptor(descriptor, prototype.hasInputErrors() ? 1 : 0);
        appendTypeDescriptor(descriptor, prototype.hasOutputErrors() ? 1 : 0);
        const auto* output = prototype.getOutputType();
        if (output == nullptr) {
            throw ContractError("native-provider-prototype-output-type-invalid");
        }
        describeNativeType(*output, active, descriptor);
        const auto parameterCount = prototype.numParams();
        if (parameterCount < 0 ||
            static_cast<std::size_t>(parameterCount) > request.budgets.maxOperations) {
            throw ContractError("native-provider-prototype-parameter-count-invalid");
        }
        appendTypeDescriptor(descriptor, static_cast<std::int64_t>(parameterCount));
        for (ghidra::int4 index = 0; index < parameterCount; ++index) {
            budget.checkpoint();
            const auto* parameter = prototype.getParam(index);
            const auto* type = parameter == nullptr ? nullptr : parameter->getType();
            if (type == nullptr) {
                throw ContractError("native-provider-prototype-parameter-type-invalid");
            }
            describeNativeType(*type, active, descriptor);
        }
    }

    void describeNativeType(
        const ghidra::Datatype& type,
        std::vector<const ghidra::Datatype*>& active,
        std::string& descriptor
    ) {
        budget.checkpoint();
        if (type.getId() != 0U) {
            // Always the id this type's record carries (assigned now if needed), so a
            // descriptor never names a raw native id that typeIdFor later disambiguates.
            appendTypeDescriptor(descriptor, "native");
            appendTypeDescriptor(descriptor, typeIdFor(type));
            return;
        }
        const auto cycle = std::find(active.begin(), active.end(), &type);
        if (cycle != active.end()) {
            appendTypeDescriptor(descriptor, "cycle");
            appendTypeDescriptor(
                descriptor,
                static_cast<std::int64_t>(std::distance(active.begin(), cycle))
            );
            return;
        }
        active.push_back(&type);
        appendTypeDescriptor(descriptor, nativeTypeKind(type.getMetatype()));
        appendTypeDescriptor(
            descriptor, static_cast<std::int64_t>(type.getMetatype())
        );
        appendTypeDescriptor(descriptor, static_cast<std::int64_t>(type.getSize()));
        appendTypeDescriptor(descriptor, type.getName());
        appendTypeDescriptor(descriptor, type.getDisplayName());
        appendTypeDescriptor(descriptor, type.isIncomplete() ? 1 : 0);

        const auto dependencyCount = type.numDepend();
        if (dependencyCount < 0 ||
            static_cast<std::size_t>(dependencyCount) > request.budgets.maxOperations) {
            throw ContractError("native-provider-type-dependency-count-invalid");
        }

        const auto describeRequiredDependency = [&](const ghidra::Datatype* dependency) {
            if (dependency == nullptr) {
                throw ContractError("native-provider-type-dependency-invalid");
            }
            describeNativeType(*dependency, active, descriptor);
        };

        if (type.getMetatype() == ghidra::TYPE_PTR ||
            type.getMetatype() == ghidra::TYPE_PTRREL) {
            if (dependencyCount != 1) {
                throw ContractError("native-provider-type-dependency-count-invalid");
            }
            const auto& pointer = static_cast<const ghidra::TypePointer&>(type);
            appendTypeDescriptor(descriptor, "pointee");
            describeRequiredDependency(pointer.getPtrTo());
            if (type.getMetatype() == ghidra::TYPE_PTRREL) {
                const auto& relative = static_cast<const ghidra::TypePointerRel&>(type);
                appendTypeDescriptor(descriptor, "relative-parent");
                describeRequiredDependency(relative.getParent());
                appendTypeDescriptor(
                    descriptor, static_cast<std::int64_t>(relative.getByteOffset())
                );
            }
        } else if (type.getMetatype() == ghidra::TYPE_ARRAY) {
            if (dependencyCount != 1) {
                throw ContractError("native-provider-type-dependency-count-invalid");
            }
            const auto& array = static_cast<const ghidra::TypeArray&>(type);
            appendTypeDescriptor(descriptor, static_cast<std::int64_t>(array.numElements()));
            appendTypeDescriptor(descriptor, "element");
            describeRequiredDependency(array.getBase());
        } else if (type.getMetatype() == ghidra::TYPE_STRUCT) {
            const auto& structure = static_cast<const ghidra::TypeStruct&>(type);
            appendTypeDescriptor(
                descriptor,
                static_cast<std::int64_t>(
                    std::distance(structure.beginField(), structure.endField())
                )
            );
            for (auto iterator = structure.beginField(); iterator != structure.endField(); ++iterator) {
                appendTypeDescriptor(descriptor, iterator->name);
                appendTypeDescriptor(descriptor, static_cast<std::int64_t>(iterator->offset));
                describeRequiredDependency(iterator->type);
            }
            appendTypeDescriptor(
                descriptor, static_cast<std::int64_t>(structure.numBitFields())
            );
            for (ghidra::int4 index = 0; index < structure.numBitFields(); ++index) {
                const auto& field = structure.getBitField(index);
                appendTypeDescriptor(descriptor, field.name);
                appendTypeDescriptor(descriptor, static_cast<std::int64_t>(field.bits.byteOffset));
                appendTypeDescriptor(descriptor, static_cast<std::int64_t>(field.bits.leastSigBit));
                appendTypeDescriptor(descriptor, static_cast<std::int64_t>(field.bits.numBits));
                describeRequiredDependency(field.type);
            }
        } else if (type.getMetatype() == ghidra::TYPE_UNION) {
            const auto& unionType = static_cast<const ghidra::TypeUnion&>(type);
            appendTypeDescriptor(
                descriptor, static_cast<std::int64_t>(unionType.numDepend())
            );
            for (ghidra::int4 index = 0; index < unionType.numDepend(); ++index) {
                const auto* field = unionType.getField(index);
                if (field == nullptr) {
                    throw ContractError("native-provider-type-field-invalid");
                }
                appendTypeDescriptor(descriptor, field->name);
                appendTypeDescriptor(descriptor, static_cast<std::int64_t>(field->offset));
                describeRequiredDependency(field->type);
            }
        } else if (type.getMetatype() == ghidra::TYPE_PARTIALENUM) {
            const auto& partial = static_cast<const ghidra::TypePartialEnum&>(type);
            appendTypeDescriptor(descriptor, static_cast<std::int64_t>(partial.getOffset()));
            describeRequiredDependency(partial.getParent());
        } else if (type.getMetatype() == ghidra::TYPE_PARTIALSTRUCT) {
            const auto& partial = static_cast<const ghidra::TypePartialStruct&>(type);
            appendTypeDescriptor(descriptor, static_cast<std::int64_t>(partial.getOffset()));
            describeRequiredDependency(partial.getParent());
        } else if (type.getMetatype() == ghidra::TYPE_PARTIALUNION) {
            const auto& partial = static_cast<const ghidra::TypePartialUnion&>(type);
            appendTypeDescriptor(descriptor, static_cast<std::int64_t>(partial.getOffset()));
            describeRequiredDependency(partial.getParentUnion());
        } else if (type.getMetatype() == ghidra::TYPE_CODE) {
            const auto* prototype = static_cast<const ghidra::TypeCode&>(type).getPrototype();
            if (prototype != nullptr) describePrototype(*prototype, active, descriptor);
        } else {
            appendTypeDescriptor(descriptor, static_cast<std::int64_t>(dependencyCount));
            for (ghidra::int4 index = 0; index < dependencyCount; ++index) {
                describeRequiredDependency(type.getDepend(index));
            }
        }
        active.pop_back();
    }

    [[nodiscard]] std::string typeIdFor(const ghidra::Datatype& type) {
        const auto existing = typeIds.find(&type);
        if (existing != typeIds.end()) return existing->second;
        std::string id;
        if (type.getId() != 0U) {
            // Ghidra can give distinct Datatypes one native id (e.g. pointers to two
            // different authored-qualifier typedefs). The first keeps the plain id;
            // later ones get a deterministic discovery-order suffix.
            auto& owners = nativeIdOwners[type.getId()];
            auto owner = std::find(owners.begin(), owners.end(), &type);
            if (owner == owners.end()) owner = owners.insert(owners.end(), &type);
            const auto ordinal = std::distance(owners.begin(), owner);
            id = "type:native:" + hex16(type.getId()) +
                (ordinal == 0 ? std::string() : "~" + std::to_string(ordinal));
        } else {
            std::vector<const ghidra::Datatype*> active;
            std::string descriptor;
            describeNativeType(type, active, descriptor);
            id = "type:anonymous:" + hex16(fnv1a64(descriptor));
        }
        requireNativeText(id, 256U, false);
        typeIds.emplace(&type, id);
        return id;
    }

    void collectNativeType(const ghidra::Datatype* type) {
        budget.checkpoint();
        if (type == nullptr) throw ContractError("native-provider-type-invalid");
        if (!nativeTypeSet.insert(type).second) return;
        if (nativeTypes.size() >= request.budgets.maxOperations) {
            throw ContractError("native-provider-type-count-exceeded");
        }
        nativeTypes.push_back(type);
        const auto dependencyCount = type->numDepend();
        if (dependencyCount < 0 ||
            static_cast<std::size_t>(dependencyCount) > request.budgets.maxOperations) {
            throw ContractError("native-provider-type-dependency-count-invalid");
        }
        for (ghidra::int4 index = 0; index < dependencyCount; ++index) {
            collectNativeType(type->getDepend(index));
        }
        if (type->getMetatype() == ghidra::TYPE_STRUCT) {
            const auto& structure = static_cast<const ghidra::TypeStruct&>(*type);
            for (ghidra::int4 index = 0; index < structure.numBitFields(); ++index) {
                collectNativeType(structure.getBitField(index).type);
            }
        }
        if (type->getMetatype() == ghidra::TYPE_CODE) {
            const auto* prototype = static_cast<const ghidra::TypeCode&>(*type).getPrototype();
            if (prototype != nullptr) collectPrototypeTypes(*prototype);
        }
    }

    void collectPrototypeTypes(const ghidra::FuncProto& prototype) {
        collectNativeType(prototype.getOutputType());
        const auto parameterCount = prototype.numParams();
        if (parameterCount < 0 ||
            static_cast<std::size_t>(parameterCount) > request.budgets.maxOperations) {
            throw ContractError("native-provider-prototype-parameter-count-invalid");
        }
        for (ghidra::int4 index = 0; index < parameterCount; ++index) {
            const auto* parameter = prototype.getParam(index);
            collectNativeType(parameter == nullptr ? nullptr : parameter->getType());
        }
    }

    void accountTypeRecord(const TypeRecord& record) {
        outputMeter.addRecord();
        outputMeter.addText(record.id);
        outputMeter.addText(record.kind);
        outputMeter.addText(record.name);
        outputMeter.addScalar();
        outputMeter.addScalar();
        if (record.pointeeTypeId) outputMeter.addText(*record.pointeeTypeId);
        if (record.returnTypeId) outputMeter.addText(*record.returnTypeId);
        outputMeter.addText(record.confidence);
        outputMeter.addText(record.provenance);
        for (const auto& parameter : record.parameterTypeIds) outputMeter.addText(parameter);
        for (const auto& field : record.fields) {
            outputMeter.addContainer();
            outputMeter.addText(field.name);
            outputMeter.addText(field.typeId);
            outputMeter.addScalar();
            outputMeter.addScalar();
        }
    }

    void insertTypeRecord(TypeRecord record) {
        const auto existing = types.find(record.id);
        if (existing != types.end()) {
            if (existing->second != record) {
                throw ContractError("native-provider-type-identity-collision");
            }
            return;
        }
        accountTypeRecord(record);
        types.emplace(record.id, std::move(record));
    }

    void appendPrototypeSignature(TypeRecord& record, const ghidra::FuncProto& prototype) {
        record.returnTypeId = typeIdFor(*prototype.getOutputType());
        const auto parameterCount = prototype.numParams();
        for (ghidra::int4 index = 0; index < parameterCount; ++index) {
            const auto* parameter = prototype.getParam(index);
            if (parameter == nullptr || parameter->getType() == nullptr) {
                throw ContractError("native-provider-prototype-parameter-type-invalid");
            }
            record.parameterTypeIds.push_back(typeIdFor(*parameter->getType()));
        }
    }

    [[nodiscard]] TypeRecord buildNativeTypeRecord(const ghidra::Datatype& type) {
        TypeRecord record;
        record.id = typeIdFor(type);
        record.kind = nativeTypeKind(type.getMetatype());
        record.name = type.getDisplayName().empty() ? type.getName() : type.getDisplayName();
        constexpr std::string_view authoredQualifierPrefix = "__macscope_authored_qualifier_";
        if (record.name.starts_with(authoredQualifierPrefix)) {
            const auto* underlying = type.getTypedef();
            if (underlying != nullptr) {
                record.name = underlying->getDisplayName().empty()
                    ? underlying->getName()
                    : underlying->getDisplayName();
            }
        }
        if (record.name.empty()) record.name = "anonymous-" + record.kind;
        requireNativeText(record.name, 4096U, false);
        if (type.getSize() > 0) record.byteSize = static_cast<std::uint64_t>(type.getSize());
        switch (type.getMetatype()) {
        case ghidra::TYPE_INT:
        case ghidra::TYPE_ENUM_INT:
            record.isSigned = true;
            break;
        case ghidra::TYPE_UINT:
        case ghidra::TYPE_ENUM_UINT:
        case ghidra::TYPE_UNKNOWN:
        case ghidra::TYPE_PARTIALENUM:
            record.isSigned = false;
            break;
        default:
            break;
        }
        record.confidence = type.isIncomplete() ? "low" : "high";
        record.provenance = type.isIncomplete()
            ? "native-ghidra-incomplete"
            : "native-ghidra-recovered";

        if (type.getMetatype() == ghidra::TYPE_PTR ||
            type.getMetatype() == ghidra::TYPE_PTRREL ||
            type.getMetatype() == ghidra::TYPE_ARRAY) {
            if (type.numDepend() != 1 || type.getDepend(0) == nullptr) {
                throw ContractError("native-provider-type-pointee-invalid");
            }
            record.pointeeTypeId = typeIdFor(*type.getDepend(0));
        }

        const auto appendField = [&](const ghidra::TypeField& field) {
            if (field.offset < 0 || field.name.empty() || field.type == nullptr ||
                field.type->getSize() <= 0) {
                throw ContractError("native-provider-type-field-invalid");
            }
            TypeFieldRecord exported;
            exported.name = field.name;
            exported.typeId = typeIdFor(*field.type);
            exported.bitOffset = static_cast<std::uint64_t>(field.offset) * 8U;
            exported.bitSize = static_cast<std::uint64_t>(field.type->getSize()) * 8U;
            record.fields.push_back(std::move(exported));
        };
        if (type.getMetatype() == ghidra::TYPE_STRUCT) {
            const auto& structure = static_cast<const ghidra::TypeStruct&>(type);
            for (auto iterator = structure.beginField(); iterator != structure.endField(); ++iterator) {
                appendField(*iterator);
            }
            for (ghidra::int4 index = 0; index < structure.numBitFields(); ++index) {
                const auto& field = structure.getBitField(index);
                if (field.name.empty() || field.type == nullptr || field.bits.byteOffset < 0 ||
                    field.bits.leastSigBit < 0 || field.bits.numBits <= 0) {
                    throw ContractError("native-provider-type-field-invalid");
                }
                TypeFieldRecord exported;
                exported.name = field.name;
                exported.typeId = typeIdFor(*field.type);
                exported.bitOffset = static_cast<std::uint64_t>(field.bits.byteOffset) * 8U +
                    static_cast<std::uint64_t>(field.bits.leastSigBit);
                exported.bitSize = static_cast<std::uint64_t>(field.bits.numBits);
                record.fields.push_back(std::move(exported));
            }
        } else if (type.getMetatype() == ghidra::TYPE_UNION) {
            const auto& unionType = static_cast<const ghidra::TypeUnion&>(type);
            for (ghidra::int4 index = 0; index < unionType.numDepend(); ++index) {
                const auto* field = unionType.getField(index);
                if (field == nullptr) throw ContractError("native-provider-type-field-invalid");
                appendField(*field);
            }
        } else if (type.getMetatype() == ghidra::TYPE_CODE) {
            const auto* prototype = static_cast<const ghidra::TypeCode&>(type).getPrototype();
            if (prototype != nullptr) appendPrototypeSignature(record, *prototype);
        }
        return record;
    }

    [[nodiscard]] std::string prototypeTypeIdFor(const ghidra::FuncProto& prototype) {
        const auto existing = prototypeTypeIds.find(&prototype);
        if (existing != prototypeTypeIds.end()) return existing->second;
        // Assign the signature's type ids first so the descriptor sees any
        // disambiguated native id (see typeIdFor).
        TypeRecord signature;
        appendPrototypeSignature(signature, prototype);
        std::vector<const ghidra::Datatype*> active;
        std::string descriptor;
        describePrototype(prototype, active, descriptor);
        TypeRecord record;
        record.id = "type:function:" + hex16(fnv1a64(descriptor));
        record.kind = "function";
        record.name = "function-prototype";
        record.confidence = prototype.hasInputErrors() || prototype.hasOutputErrors()
            ? "low"
            : "high";
        record.provenance = "native-ghidra-prototype";
        appendPrototypeSignature(record, prototype);
        const auto id = record.id;
        insertTypeRecord(std::move(record));
        prototypeTypeIds.emplace(&prototype, id);
        return id;
    }

    void collectVarnodeTypeCandidate(
        const ghidra::Varnode& native,
        std::map<std::string, std::string>& candidates,
        std::unordered_set<std::string>& conflicts
    ) {
        const auto* type = native.getType();
        if (type == nullptr) throw ContractError("native-provider-varnode-type-invalid");
        const auto id = typeIdFor(*type);
        const auto semanticIterator = semanticVarnodes.find(&native);
        if (semanticIterator == semanticVarnodes.end()) {
            throw ContractError("native-provider-varnode-type-owner-missing");
        }
        const auto& semanticId = semanticIterator->second.record.id;
        const auto [iterator, inserted] = candidates.emplace(semanticId, id);
        if (!inserted && iterator->second != id) conflicts.insert(semanticId);
    }

    void indexTypes() {
        collectPrototypeTypes(function.getFuncProto());
        for (const auto& info : nativeOperations) {
            budget.checkpoint();
            const auto& operation = *info.operation;
            if (const auto* output = operation.getOut(); output != nullptr) {
                collectNativeType(output->getType());
            }
            for (ghidra::int4 slot = 0; slot < operation.numInput(); ++slot) {
                const auto* input = operation.getIn(slot);
                collectNativeType(input == nullptr ? nullptr : input->getType());
            }
            const auto call = callsByOperation.find(&operation);
            if (call != callsByOperation.end()) collectPrototypeTypes(*call->second.specification);
        }

        for (const auto* type : nativeTypes) {
            static_cast<void>(typeIdFor(*type));
        }
        for (const auto* type : nativeTypes) {
            insertTypeRecord(buildNativeTypeRecord(*type));
        }
        static_cast<void>(prototypeTypeIdFor(function.getFuncProto()));
        for (const auto& info : nativeOperations) {
            const auto call = callsByOperation.find(info.operation);
            if (call != callsByOperation.end()) {
                static_cast<void>(prototypeTypeIdFor(*call->second.specification));
            }
        }
        std::map<std::string, std::string> varnodeTypeCandidates;
        std::unordered_set<std::string> varnodeTypeConflicts;
        for (const auto& info : nativeOperations) {
            const auto& operation = *info.operation;
            if (const auto* output = operation.getOut(); output != nullptr) {
                collectVarnodeTypeCandidate(
                    *output, varnodeTypeCandidates, varnodeTypeConflicts
                );
            }
            for (ghidra::int4 slot = 0; slot < operation.numInput(); ++slot) {
                const auto* input = operation.getIn(slot);
                if (input == nullptr) throw ContractError("native-provider-operation-input-invalid");
                collectVarnodeTypeCandidate(
                    *input, varnodeTypeCandidates, varnodeTypeConflicts
                );
            }
        }
        for (auto& [native, semantic] : semanticVarnodes) {
            static_cast<void>(native);
            const auto candidate = varnodeTypeCandidates.find(semantic.record.id);
            if (candidate != varnodeTypeCandidates.end() &&
                !varnodeTypeConflicts.contains(semantic.record.id)) {
                semantic.record.typeId = candidate->second;
            }
        }
        for (auto& [id, record] : varnodes) {
            const auto candidate = varnodeTypeCandidates.find(id);
            if (candidate != varnodeTypeCandidates.end() &&
                !varnodeTypeConflicts.contains(id)) {
                record.typeId = candidate->second;
                outputMeter.addText(candidate->second);
            }
        }
    }

    [[nodiscard]] std::optional<std::vector<SourceRange>> variableLiveRanges(
        const ghidra::HighVariable& high
    ) const {
        const auto coalesce = [](std::vector<SourceRange> ranges) {
            std::sort(ranges.begin(), ranges.end(), [](const SourceRange& lhs, const SourceRange& rhs) {
                return std::tie(lhs.startAddress, lhs.endAddressExclusive) <
                    std::tie(rhs.startAddress, rhs.endAddressExclusive);
            });
            std::vector<SourceRange> coalesced;
            for (const auto& range : ranges) {
                if (!coalesced.empty() &&
                    range.startAddress <= coalesced.back().endAddressExclusive) {
                    coalesced.back().endAddressExclusive = std::max(
                        coalesced.back().endAddressExclusive, range.endAddressExclusive
                    );
                } else {
                    coalesced.push_back(range);
                }
            }
            return coalesced;
        };
        const auto symbolUseLimits = [&]() -> std::optional<std::vector<SourceRange>> {
            const auto* entry = high.getSymbolEntry();
            if (entry == nullptr) return std::nullopt;
            std::vector<SourceRange> ranges;
            for (const auto& nativeRange : entry->getUseLimit()) {
                budget.checkpoint();
                if (nativeRange.getSpace() != codeSpace ||
                    nativeRange.getLast() == std::numeric_limits<ghidra::uintb>::max()) {
                    continue;
                }
                const auto codeRanges = request.function.codeRanges.empty()
                    ? std::vector<FunctionIdentity::CodeRange>{{request.function.entryAddress, request.function.endAddressExclusive}}
                    : request.function.codeRanges;
                for (const auto& codeRange : codeRanges) {
                    const auto start = std::max(codeRange.startAddress, static_cast<Address>(nativeRange.getFirst()));
                    const auto end = std::min(codeRange.endAddressExclusive, static_cast<Address>(nativeRange.getLast() + 1U));
                    if (start < end) ranges.push_back(instructionRange(request, start, end));
                }
            }
            if (ranges.empty()) return std::nullopt;
            return coalesce(std::move(ranges));
        };
        if (!high.hasCover()) return symbolUseLimits();
        std::vector<SourceRange> ranges;
        const auto& cover = high.getCover();
        const auto& graph = function.getBasicBlocks();
        for (auto iterator = cover.begin(); iterator != cover.end(); ++iterator) {
            budget.checkpoint();
            const auto blockIndex = iterator->first;
            if (blockIndex < 0) return symbolUseLimits();
            const auto* flowBlock = graph.getBlock(blockIndex);
            if (flowBlock == nullptr || flowBlock->getType() != ghidra::FlowBlock::t_basic) {
                return symbolUseLimits();
            }
            const auto* block = static_cast<const ghidra::BlockBasic*>(flowBlock);
            if (block == skippedEntryScaffold) {
                block = block->sizeOut() == 1
                    ? static_cast<const ghidra::BlockBasic*>(block->getOut(0))
                    : nullptr;
            }
            const auto exportedBlock = block == nullptr ? blockIndices.end() : blockIndices.find(block);
            if (exportedBlock == blockIndices.end()) return symbolUseLimits();
            const auto& blockRecord = nativeBlocks[exportedBlock->second].record;
            if (rewrittenPartition) {
                const auto& coverBlock = iterator->second;
                const auto& owner = nativeBlocks[exportedBlock->second];
                if (coverBlock.getStart() == nullptr &&
                    reinterpret_cast<std::uintptr_t>(coverBlock.getStop()) == 1U) {
                    const auto provenance = blockSourceRanges(exportedBlock->second);
                    ranges.insert(ranges.end(), provenance.begin(), provenance.end());
                } else {
                    for (const auto opIndex : owner.operationIndices) {
                        budget.checkpoint();
                        const auto& operation = nativeOperations[opIndex];
                        if (coverBlock.contain(operation.operation)) {
                            const auto& instruction = decoded[operation.instructionIndex];
                            ranges.push_back(instructionRange(request, instruction.record.address, instruction.endAddressExclusive));
                        }
                    }
                }
                continue;
            }


            const auto operationBoundary = [&](const ghidra::PcodeOp* operation, bool end) ->
                std::optional<Address> {
                if (operation == nullptr) return end
                    ? std::optional<Address>{blockRecord.endAddressExclusive}
                    : std::optional<Address>{blockRecord.startAddress};
                if (reinterpret_cast<std::uintptr_t>(operation) == 1U) {
                    return end
                        ? std::optional<Address>{blockRecord.endAddressExclusive}
                        : std::optional<Address>{blockRecord.startAddress};
                }
                if (reinterpret_cast<std::uintptr_t>(operation) == 2U) {
                    return blockRecord.startAddress;
                }
                const auto native = nativeOperationIndices.find(operation);
                if (native == nativeOperationIndices.end()) return std::nullopt;
                const auto& source = decoded[
                    nativeOperations[native->second].instructionIndex
                ].record.sourceRanges.front();
                return end ? source.endAddressExclusive : source.startAddress;
            };

            const auto start = operationBoundary(iterator->second.getStart(), false);
            const auto end = operationBoundary(iterator->second.getStop(), true);
            if (!start || !end || *start < blockRecord.startAddress || *start >= *end ||
                *end > blockRecord.endAddressExclusive) {
                return symbolUseLimits();
            }
            ranges.push_back(instructionRange(request, *start, *end));
        }
        if (ranges.empty()) return symbolUseLimits();
        return coalesce(std::move(ranges));
    }

    void accountVariableRecord(const VariableRecord& record) {
        outputMeter.addRecord();
        outputMeter.addText(record.id);
        outputMeter.addText(record.name);
        outputMeter.addText(record.role);
        if (record.typeId) outputMeter.addText(*record.typeId);
        for (const auto& storage : record.storageVarnodeIds) outputMeter.addText(storage);
        for (const auto& range : record.liveRanges) outputMeter.addSourceRange(range);
        outputMeter.addText(record.confidence);
        outputMeter.addText(record.provenance);
    }

    [[nodiscard]] std::optional<VariableRecord> buildVariableRecord(
        const ghidra::HighVariable& high
    ) {
        if (high.isConstant() || high.isImplied() || high.isSpacebase() ||
            high.isUnaffected() || high.isExtraOut() || high.isUnattached()) {
            return std::nullopt;
        }
        std::set<std::string> storageIds;
        for (ghidra::int4 index = 0; index < high.numInstances(); ++index) {
            budget.checkpoint();
            const auto* instance = high.getInstance(index);
            const auto semantic = instance == nullptr ? semanticVarnodes.end() :
                semanticVarnodes.find(instance);
            if (semantic != semanticVarnodes.end()) {
                storageIds.insert(semantic->second.record.id);
            }
        }
        if (storageIds.empty()) return std::nullopt;
        const auto* type = high.getType();
        if (type == nullptr) return std::nullopt;
        const auto typeId = typeIdFor(*type);
        if (!types.contains(typeId)) return std::nullopt;
        const auto liveRanges = variableLiveRanges(high);
        if (!liveRanges || liveRanges->empty()) return std::nullopt;

        VariableRecord record;
        const auto* symbol = high.getSymbol();
        if (symbol == nullptr || symbol->getId() == 0U) return std::nullopt;
        record.name = symbol->getDisplayName().empty()
            ? symbol->getName()
            : symbol->getDisplayName();
        if (record.name.empty()) return std::nullopt;
        requireNativeText(record.name, 1024U, false);

        record.id = detail::symbolVariableIdentity(symbol->getId(), high.getSymbolOffset());
        requireNativeText(record.id, 4096U, false);
        record.role = high.isInput() ||
            (symbol != nullptr && symbol->getCategory() == ghidra::Symbol::function_parameter)
            ? "parameter"
            : (high.isPersist() ? "global" : "local");
        record.typeId = typeId;
        record.storageVarnodeIds.assign(storageIds.begin(), storageIds.end());
        record.liveRanges = *liveRanges;
        record.confidence = high.isTypeLock() && high.isNameLock()
            ? "high"
            : ((high.isTypeLock() || high.isNameLock()) ? "medium" : "low");
        record.provenance = "native-ghidra-high-variable";
        return record;
    }

    void indexVariables() {
        if (!function.isHighOn()) {
            throw ContractError("native-provider-high-variables-unavailable");
        }
        detail::indexDistinctHighVariables(nativeOperations,
            [this](const ghidra::HighVariable& high) { return buildVariableRecord(high); },
            [this](VariableRecord record) {
                requireNativeText(record.id, 4096U, false);
                const auto existing = variables.find(record.id);
                if (existing != variables.end()) {
                    if (existing->second != record) {
                        throw ContractError("native-provider-variable-identity-collision");
                    }
                    return;
                }
                accountVariableRecord(record);
                variables.emplace(record.id, std::move(record));
            }, [this] { budget.checkpoint(); });
    }

    void indexAddressSpaces() {
        std::unordered_set<std::string> names;
        for (ghidra::int4 index = 0; index < architecture.numSpaces(); ++index) {
            budget.checkpoint();
            const auto* space = architecture.getSpace(index);
            if (space == nullptr || space->getAddrSize() == 0U || space->getAddrSize() > 32U) {
                throw ContractError("native-provider-address-space-invalid");
            }
            requireNativeText(space->getName(), 256U, false);
            if (!names.insert(space->getName()).second) {
                throw ContractError("native-provider-address-space-duplicate");
            }
            AddressSpaceRecord record;
            record.id = "space:" + space->getName();
            record.name = space->getName();
            record.kind = spaceKind(space->getType());
            record.addressSizeBytes = space->getAddrSize();
            record.isProcessorSpace = space->getType() == ghidra::IPTR_PROCESSOR;
            outputMeter.addRecord();
            outputMeter.addText(record.id);
            outputMeter.addText(record.name);
            outputMeter.addText(record.kind);
            outputMeter.addScalar();
            outputMeter.addScalar();
            if (!spaceIds.emplace(space, record.id).second) {
                throw ContractError("native-provider-address-space-identity-duplicate");
            }
            result.addressSpaces.push_back(std::move(record));
        }
    }

    void indexFinalBlocks() {
        const auto& graph = function.getBasicBlocks();
        const auto count = graph.getSize();
        if (count <= 0 || static_cast<std::size_t>(count) > request.budgets.maxOperations ||
            static_cast<std::size_t>(count) > std::numeric_limits<std::uint32_t>::max()) {
            throw ContractError("native-provider-final-block-count-invalid");
        }
        outputMeter.requireAdditionalProduct(static_cast<std::size_t>(count), 128U);
        std::unordered_set<const ghidra::FlowBlock*> all;
        const ghidra::BlockBasic* entry = nullptr;
        for (ghidra::int4 i = 0; i < count; ++i) {
            budget.checkpoint();
            const auto* flow = graph.getBlock(i);
            if (flow == nullptr || flow->getType() != ghidra::FlowBlock::t_basic || !all.insert(flow).second) {
                throw ContractError("native-provider-final-block-invalid");
            }
            const auto* block = static_cast<const ghidra::BlockBasic*>(flow);
            if (block->isEntryPoint()) {
                if (entry != nullptr) throw ContractError("native-provider-final-entry-duplicate");
                entry = block;
            }
        }
        if (entry == nullptr || graph.getStartBlock() != entry || entry->sizeIn() != 0 ||
            entry->getEntryAddr().isInvalid() || entry->getEntryAddr().getSpace() != codeSpace ||
            entry->getEntryAddr().getOffset() != request.function.entryAddress) {
            throw ContractError("native-provider-final-entry-invalid");
        }
        std::vector<const ghidra::FlowBlock*> traversal{entry};
        std::unordered_set<const ghidra::FlowBlock*> visited{entry};
        std::size_t memberships = 0U;
        for (std::size_t ordinal = 0; ordinal < traversal.size(); ++ordinal) {
            budget.checkpoint();
            const auto* block = static_cast<const ghidra::BlockBasic*>(traversal[ordinal]);
            const auto address = block->getEntryAddr();
            const auto start = block->getStart();
            const auto stop = block->getStop();
            if (address.isInvalid() || start.isInvalid() || stop.isInvalid() ||
                address.getSpace() != codeSpace || start.getSpace() != codeSpace || stop.getSpace() != codeSpace ||
                start.getOffset() < request.function.entryAddress || stop.getOffset() >= request.function.endAddressExclusive ||
                start.getOffset() > stop.getOffset() || block->sizeIn() < 0 || block->sizeOut() < 0 ||
                static_cast<std::size_t>(block->sizeIn()) > request.budgets.maxOperations ||
                static_cast<std::size_t>(block->sizeOut()) > request.budgets.maxOperations) {
                throw ContractError("native-provider-final-block-provenance-invalid");
            }
            NativeBlock info;
            info.block = block;
            info.nativeEntryAddress = address.getOffset();
            info.record.id = "block:cfg:" + hex16(static_cast<std::uint64_t>(ordinal));
            info.incomingEdgeIds.resize(static_cast<std::size_t>(block->sizeIn()));
            auto instruction = std::lower_bound(decoded.begin(), decoded.end(), start.getOffset(),
                [](const auto& value, Address target) { return value.record.address < target; });
            for (; instruction != decoded.end() && instruction->record.address <= stop.getOffset(); ++instruction) {
                budget.checkpoint();
                if (block->contains(ghidra::Address(codeSpace, instruction->record.address))) {
                    ++memberships;
                    outputMeter.requireAdditionalProduct(memberships, 128U);
                    info.instructionIndices.push_back(static_cast<std::size_t>(instruction - decoded.begin()));
                }
            }
            if (!blockIndices.emplace(block, ordinal).second) throw ContractError("native-provider-final-block-identity-duplicate");
            outputMeter.addRecord(); outputMeter.addText(info.record.id); outputMeter.addScalar(); outputMeter.addScalar();
            nativeBlocks.push_back(std::move(info));
            for (ghidra::int4 slot = 0; slot < block->sizeOut(); ++slot) {
                budget.checkpoint();
                const auto* target = block->getOut(slot);
                if (target == nullptr || !all.contains(target)) throw ContractError("native-provider-final-edge-target-invalid");
                if (visited.insert(target).second) traversal.push_back(target);
            }
        }
        if (visited.size() != all.size()) throw ContractError("native-provider-final-block-unreachable");
    }

    void buildFinalOwnership() {
        if (!rewrittenPartition) return;
        BlockPartitionRecord partition;
        partition.entryBlockId = nativeBlocks.front().record.id;
        partition.instructions.reserve(decoded.size());
        for (const auto& instruction : decoded) {
            partition.instructions.push_back({instruction.record.id, "eliminated", {}});
        }
        std::size_t memberships = 0U;
        for (std::size_t ordinal = 0; ordinal < nativeBlocks.size(); ++ordinal) {
            budget.checkpoint();
            auto& block = nativeBlocks[ordinal];
            std::map<std::size_t, std::uint32_t> counts;
            for (const auto operationIndex : block.operationIndices) {
                const auto instructionIndex = nativeOperations[operationIndex].instructionIndex;
                if (++counts[instructionIndex] == 0U) throw ContractError("native-provider-final-span-overflow");
                block.instructionIndices.push_back(instructionIndex);
            }
            std::sort(block.instructionIndices.begin(), block.instructionIndices.end());
            block.instructionIndices.erase(std::unique(block.instructionIndices.begin(), block.instructionIndices.end()),
                block.instructionIndices.end());
            if (block.instructionIndices.empty()) throw ContractError("native-provider-final-block-source-unresolved");
            BlockPartitionBlockRecord descriptor{block.record.id, static_cast<std::uint32_t>(ordinal), block.nativeEntryAddress, {}};
            for (const auto index : block.instructionIndices) {
                budget.checkpoint();
                outputMeter.requireAdditionalProduct(++memberships, 128U);
                const auto& instruction = decoded[index];
                auto& ownership = partition.instructions[index];
                ownership.disposition = "retained";
                const std::uint64_t first = ownership.spans.empty() ? 0U :
                    static_cast<std::uint64_t>(ownership.spans.back().firstOperationIndex) + ownership.spans.back().operationCount;
                const auto count = counts[index];
                if (first + count > std::numeric_limits<std::uint32_t>::max()) throw ContractError("native-provider-final-span-overflow");
                ownership.spans.push_back({block.record.id, static_cast<std::uint32_t>(first), count});
                if (!descriptor.sourceRanges.empty() && descriptor.sourceRanges.back().endAddressExclusive == instruction.record.address) {
                    descriptor.sourceRanges.back().endAddressExclusive = instruction.endAddressExclusive;
                } else {
                    descriptor.sourceRanges.push_back(instructionRange(request, instruction.record.address, instruction.endAddressExclusive));
                }
            }
            block.record.startAddress = descriptor.sourceRanges.front().startAddress;
            block.record.endAddressExclusive = descriptor.sourceRanges.back().endAddressExclusive;
            partition.blocks.push_back(std::move(descriptor));
        }
        result.blockPartition = std::move(partition);
    }

    [[nodiscard]] std::vector<SourceRange> blockSourceRanges(std::size_t index) const {
        if (result.blockPartition) return result.blockPartition->blocks.at(index).sourceRanges;
        const auto& block = nativeBlocks.at(index).record;
        if (request.function.codeRanges.empty()) {
            return {instructionRange(request, block.startAddress, block.endAddressExclusive)};
        }
        std::vector<SourceRange> ranges;
        for (const auto& code : request.function.codeRanges) {
            const auto start = std::max(block.startAddress, code.startAddress);
            const auto end = std::min(block.endAddressExclusive, code.endAddressExclusive);
            if (start < end) ranges.push_back(instructionRange(request, start, end));
        }
        return ranges;
    }

    static void coalesceProvenance(std::vector<SourceRange>& ranges) {
        std::sort(ranges.begin(), ranges.end(), [](const auto& lhs, const auto& rhs) {
            return std::tie(lhs.imageId, lhs.startAddress, lhs.endAddressExclusive) <
                std::tie(rhs.imageId, rhs.startAddress, rhs.endAddressExclusive);
        });
        std::vector<SourceRange> merged;
        for (const auto& range : ranges) {
            if (!merged.empty() && range.imageId == merged.back().imageId &&
                range.startAddress <= merged.back().endAddressExclusive) {
                merged.back().endAddressExclusive = std::max(merged.back().endAddressExclusive, range.endAddressExclusive);
            } else merged.push_back(range);
        }
        ranges = std::move(merged);
    }

    void indexBlocks() {
        rewrittenPartition = !detail::legacyPartitionRepresentable(request, function, codeSpace, decoded, budget);
        if (rewrittenPartition) { indexFinalBlocks(); return; }

        const auto& graph = function.getBasicBlocks();
        const auto graphSize = graph.getSize();
        const auto* graphStartBlock = graph.getStartBlock();
        if (graphSize <= 0 || graphStartBlock == nullptr) {
            throw ContractError("native-provider-basic-block-set-empty");
        }
        const auto graphSizeValue = static_cast<std::size_t>(graphSize);
        if ((graphSizeValue > decoded.size() && graphSizeValue - decoded.size() > 1U) ||
            (graphSizeValue > request.budgets.maxInstructions &&
             graphSizeValue - request.budgets.maxInstructions > 1U)) {
            throw ContractError("native-provider-basic-block-count-invalid");
        }
        nativeBlocks.reserve(graphSizeValue);
        const ghidra::FlowBlock* skippedEntrySuccessor = nullptr;
        for (ghidra::int4 index = 0; index < graphSize; ++index) {
            budget.checkpoint();
            const auto* flowBlock = graph.getBlock(index);
            if (flowBlock == nullptr || flowBlock->getType() != ghidra::FlowBlock::t_basic) {
                throw ContractError("native-provider-basic-block-invalid");
            }
            const auto* block = static_cast<const ghidra::BlockBasic*>(flowBlock);
            if (block->beginOp() == block->endOp()) {
                const auto entry = block->getEntryAddr();
                if (skippedEntryScaffold != nullptr || !block->isEntryPoint() ||
                    entry.isInvalid() || entry.getSpace() != codeSpace ||
                    entry.getOffset() != request.function.entryAddress || block->sizeIn() != 0 ||
                    block->sizeOut() != 1 || block->getOut(0) == nullptr) {
                    throw ContractError("native-provider-empty-basic-block-invalid");
                }
                skippedEntryScaffold = block;
                skippedEntrySuccessor = block->getOut(0);
                continue;
            }
            NativeBlock info;
            info.block = block;
            const auto entry = block->getEntryAddr();
            const auto rangeStart = block->getStart();
            const auto rangeStop = block->getStop();
            if (entry.isInvalid() || rangeStart.isInvalid() || rangeStop.isInvalid() ||
                entry.getSpace() != codeSpace || rangeStart.getSpace() != codeSpace ||
                rangeStop.getSpace() != codeSpace ||
                rangeStart.getOffset() < request.function.entryAddress ||
                rangeStart.getOffset() >= request.function.endAddressExclusive ||
                entry.getOffset() < rangeStart.getOffset() ||
                entry.getOffset() > rangeStop.getOffset()) {
                throw ContractError("native-provider-basic-block-entry-invalid");
            }
            info.nativeEntryAddress = static_cast<Address>(entry.getOffset());
            info.record.startAddress = static_cast<Address>(rangeStart.getOffset());
            nativeBlocks.push_back(std::move(info));
        }
        if (nativeBlocks.empty()) {
            throw ContractError("native-provider-basic-block-set-empty");
        }
        if (nativeBlocks.size() > decoded.size() ||
            nativeBlocks.size() > request.budgets.maxInstructions) {
            throw ContractError("native-provider-basic-block-count-invalid");
        }
        NativeBlock* entryBlock = nullptr;
        for (auto& info : nativeBlocks) {
            budget.checkpoint();
            const bool isScaffoldSuccessor = skippedEntrySuccessor != nullptr &&
                info.block == skippedEntrySuccessor;
            const bool isNativeEntry = info.block->isEntryPoint();
            if (isScaffoldSuccessor) {
                if (entryBlock != nullptr || isNativeEntry || info.block->sizeIn() <= 0) {
                    throw ContractError("native-provider-empty-entry-successor-invalid");
                }
                const auto reverseIndex = skippedEntryScaffold->getOutRevIndex(0);
                if (reverseIndex < 0 || reverseIndex >= info.block->sizeIn() ||
                    info.block->getIn(reverseIndex) != skippedEntryScaffold ||
                    info.block->getInRevIndex(reverseIndex) != 0) {
                    throw ContractError("native-provider-empty-entry-successor-invalid");
                }
                std::size_t scaffoldPredecessors = 0U;
                for (ghidra::int4 predecessorIndex = 0;
                     predecessorIndex < info.block->sizeIn(); ++predecessorIndex) {
                    budget.checkpoint();
                    const auto* predecessor = info.block->getIn(predecessorIndex);
                    if (predecessor == skippedEntryScaffold) {
                        ++scaffoldPredecessors;
                    } else if (predecessor == nullptr || std::none_of(
                            nativeBlocks.begin(), nativeBlocks.end(),
                            [predecessor](const NativeBlock& candidate) {
                                return candidate.block == predecessor;
                            })) {
                        throw ContractError("native-provider-empty-entry-successor-invalid");
                    }
                }
                if (scaffoldPredecessors != 1U) {
                    throw ContractError("native-provider-empty-entry-successor-invalid");
                }
                entryBlock = &info;
            } else if (isNativeEntry) {
                if (skippedEntryScaffold != nullptr || entryBlock != nullptr ||
                    info.block != graphStartBlock || info.block->sizeIn() != 0) {
                    throw ContractError("native-provider-entry-block-invalid");
                }
                entryBlock = &info;
            }
        }
        if (skippedEntryScaffold != nullptr && graphStartBlock != skippedEntryScaffold &&
            (entryBlock == nullptr || graphStartBlock != entryBlock->block)) {
            throw ContractError("native-provider-empty-entry-successor-invalid");
        }
        if (entryBlock == nullptr ||
            entryBlock->record.startAddress != request.function.entryAddress ||
            entryBlock->nativeEntryAddress < entryBlock->record.startAddress) {
            throw ContractError("native-provider-entry-block-invalid");
        }
        const auto* retainedEntryBlock = entryBlock->block;
        for (auto& info : nativeBlocks) {
            info.record.id = "block:" + hex16(info.record.startAddress);
            outputMeter.addRecord();
            outputMeter.addText(info.record.id);
            outputMeter.addScalar();
            outputMeter.addScalar();
        }
        std::sort(nativeBlocks.begin(), nativeBlocks.end(), [](const NativeBlock& lhs, const NativeBlock& rhs) {
            return std::tie(lhs.record.startAddress, lhs.record.id) <
                std::tie(rhs.record.startAddress, rhs.record.id);
        });
        if (nativeBlocks.front().block != retainedEntryBlock ||
            nativeBlocks.front().record.startAddress != request.function.entryAddress ||
            (skippedEntrySuccessor != nullptr &&
             nativeBlocks.front().block != skippedEntrySuccessor)) {
            throw ContractError("native-provider-entry-flow-invalid");
        }
        std::size_t instructionCursor = 0U;
        for (std::size_t index = 0; index < nativeBlocks.size(); ++index) {
            budget.checkpoint();
            auto& info = nativeBlocks[index];
            if (instructionCursor >= decoded.size() ||
                decoded[instructionCursor].record.address != info.record.startAddress ||
                (index != 0U && info.record.startAddress <=
                    nativeBlocks[index - 1U].record.startAddress)) {
                throw ContractError("native-provider-basic-block-entry-invalid");
            }
            const auto nextStart = index + 1U < nativeBlocks.size()
                ? nativeBlocks[index + 1U].record.startAddress
                : request.function.endAddressExclusive;
            while (instructionCursor < decoded.size() &&
                   decoded[instructionCursor].record.address < nextStart) {
                budget.checkpoint();
                const auto instructionAddress = decoded[instructionCursor].record.address;
                if (!info.block->contains(ghidra::Address(codeSpace, instructionAddress))) {
                    throw ContractError("native-provider-instruction-block-ownership-invalid");
                }
                info.instructionIndices.push_back(instructionCursor++);
            }
            if (info.instructionIndices.empty()) {
                throw ContractError("native-provider-basic-block-instruction-set-empty");
            }
            const auto lastIndex = info.instructionIndices.back();
            info.record.endAddressExclusive = decoded[lastIndex].endAddressExclusive;
            if (info.record.endAddressExclusive != nextStart ||
                info.block->getStart().isInvalid() || info.block->getStop().isInvalid() ||
                info.block->getStart().getSpace() != codeSpace ||
                info.block->getStop().getSpace() != codeSpace ||
                info.block->getStart().getOffset() != info.record.startAddress ||
                info.block->getStop().getOffset() != decoded[lastIndex].record.address) {
                throw ContractError("native-provider-basic-block-range-invalid");
            }
            if (!blockIndices.emplace(nativeBlocks[index].block, index).second) {
                throw ContractError("native-provider-basic-block-identity-duplicate");
            }
            const auto incomingCount = nativeBlocks[index].block->sizeIn();
            if (incomingCount < 0 ||
                static_cast<std::size_t>(incomingCount) > request.budgets.maxOperations) {
                throw ContractError("native-provider-basic-block-predecessor-count-invalid");
            }
            nativeBlocks[index].incomingEdgeIds.resize(
                static_cast<std::size_t>(incomingCount)
            );
        }
        if (instructionCursor != decoded.size()) {
            throw ContractError("native-provider-instruction-block-ownership-invalid");
        }
    }

    void indexOperations() {
        std::unordered_set<const ghidra::PcodeOp*> owned;
        std::size_t cumulativeInputReferences = 0U;
        for (std::size_t blockIndex = 0; blockIndex < nativeBlocks.size(); ++blockIndex) {
            auto& block = nativeBlocks[blockIndex];
            std::size_t previousInstructionIndex = 0U;
            bool hasPreviousInstruction = false;
            std::uint64_t sequence = 0U;
            for (auto iterator = block.block->beginOp(); iterator != block.block->endOp(); ++iterator) {
                budget.checkpoint();
                const auto* operation = *iterator;
                if (operation == nullptr || operation->isDead() || operation->getParent() != block.block ||
                    operation->getAddr().isInvalid() || operation->getAddr().getSpace() != codeSpace) {
                    throw ContractError("native-provider-operation-invalid");
                }
                const Address address = operation->getAddr().getOffset();
                const auto instructionIterator = std::lower_bound(
                    decoded.begin(), decoded.end(), address,
                    [](const DecodedInstruction& instruction, Address value) {
                        return instruction.record.address < value;
                    }
                );
                if (instructionIterator == decoded.end() || instructionIterator->record.address != address) {
                    throw ContractError("native-provider-operation-instruction-unresolved");
                }
                const auto instructionIndex = static_cast<std::size_t>(instructionIterator - decoded.begin());
                if (!rewrittenPartition && (!std::binary_search(
                        block.instructionIndices.begin(), block.instructionIndices.end(), instructionIndex
                    ) || (hasPreviousInstruction && instructionIndex < previousInstructionIndex))) {
                    throw ContractError("native-provider-operation-order-invalid");
                }
                previousInstructionIndex = instructionIndex;
                hasPreviousInstruction = true;
                if (nativeOperations.size() >= request.budgets.maxOperations) {
                    throw ContractError("native-provider-operation-budget-exceeded");
                }
                const auto* type = operation->getOpcode();
                if (type == nullptr) {
                    throw ContractError("native-provider-operation-opcode-invalid");
                }
                const auto opcode = type->getOpcode();
                const auto rawOpcode = static_cast<int>(opcode);
                const auto* canonicalName = detail::canonicalOpcodeName(opcode);
                const auto opcodeAdjudication = detail::adjudicatePcodeOpcode(
                    rawOpcode, canonicalName
                );
                if (opcodeAdjudication == detail::PcodeOpcodeAdjudication::invalid) {
                    throw ContractError("native-provider-operation-opcode-invalid");
                }
                // Canonical export name from the shared vocabulary. ghidra::get_opname() is
                // deliberately NOT used: in the pinned package its name table disagrees with the
                // OpCode enum for eleven opcodes (the six CPUI_FLOAT_* conversions lose their
                // FLOAT_ prefix; MULTIEQUAL/INDIRECT/PTRADD/PTRSUB return the sleigh-compiler
                // tokens BUILD/DELAY_SLOT/LABEL/CROSSBUILD). The wire codec rejects an
                // unrecognised name and fails the whole result, so an aliased name is a
                // result-destroying defect rather than a cosmetic one.
                if (opcodeAdjudication == detail::PcodeOpcodeAdjudication::unavailable) {
                    throw ContractError("native-provider-operation-opcode-unavailable");
                }
                std::string opcodeName(canonicalName);
                requireNativeText(opcodeName, 256U, false);
                validateOperationShape(*operation, *type, opcode);
                const auto inputCount = static_cast<std::size_t>(operation->numInput());
                if (inputCount > std::numeric_limits<std::size_t>::max() -
                        cumulativeInputReferences) {
                    outputMeter.failCumulativeCountOverflow(cumulativeInputReferences, inputCount);
                }
                cumulativeInputReferences += inputCount;
                outputMeter.requireAdditionalProduct(cumulativeInputReferences, 8U);
                const auto id = "op:" + hex16(address) + ":" +
                    hex16(operation->getSeqNum().getTime());
                outputMeter.addText(id);
                outputMeter.addText(id);
                if (!operationIds.emplace(operation, id).second || !owned.insert(operation).second) {
                    throw ContractError("native-provider-operation-identity-duplicate");
                }
                const auto operationIndex = nativeOperations.size();
                nativeOperations.push_back({
                    operation,
                    id,
                    opcode,
                    std::move(opcodeName),
                    blockIndex,
                    instructionIndex,
                    sequence++,
                });
                if (!nativeOperationIndices.emplace(operation, operationIndex).second) {
                    throw ContractError("native-provider-operation-identity-duplicate");
                }
                block.operationIndices.push_back(operationIndex);
                block.record.operationIds.push_back(id);
                decoded[instructionIndex].record.operationIds.push_back(id);
            }
            if (!rewrittenPartition && block.operationIndices.empty()) {
                throw ContractError("native-provider-basic-block-operation-set-empty");
            }
        }
        std::unordered_set<const ghidra::PcodeOp*> alive;
        for (auto iterator = function.beginOpAlive(); iterator != function.endOpAlive(); ++iterator) {
            budget.checkpoint();
            if (*iterator == nullptr || (*iterator)->isDead() || !alive.insert(*iterator).second) {
                throw ContractError("native-provider-operation-alive-set-invalid");
            }
            if (alive.size() > owned.size() || alive.size() > request.budgets.maxOperations) {
                throw ContractError("native-provider-operation-ownership-incomplete");
            }
        }
        if (alive != owned) {
            throw ContractError("native-provider-operation-ownership-incomplete");
        }
    }

    void indexCalls() {
        for (ghidra::int4 index = 0; index < function.numCalls(); ++index) {
            budget.checkpoint();
            const auto* specification = function.getCallSpecs(index);
            if (specification == nullptr || specification->getOp() == nullptr ||
                specification->getOp()->numInput() <= 0) {
                throw ContractError("native-provider-call-specification-invalid");
            }
            const auto* operation = specification->getOp();
            const auto operationIterator = nativeOperationIndices.find(operation);
            if (!operationIds.contains(operation) || operationIterator == nativeOperationIndices.end()) {
                throw ContractError("native-provider-call-specification-owner-invalid");
            }
            const auto opcode = nativeOperations[operationIterator->second].opcode;
            if (opcode != ghidra::CPUI_CALL && opcode != ghidra::CPUI_CALLIND) {
                throw ContractError("native-provider-call-specification-owner-invalid");
            }
            NativeCall call;
            call.specification = specification;
            if (opcode == ghidra::CPUI_CALL) {
                const auto& entry = specification->getEntryAddress();
                if (entry.isInvalid() || entry.getSpace() != codeSpace) {
                    throw ContractError("native-provider-direct-call-target-invalid");
                }
                call.targetAddress = static_cast<Address>(entry.getOffset());
            }
            if (!callsBySpecification.emplace(specification, call).second ||
                !callsByOperation.emplace(operation, call).second ||
                function.getCallSpecs(operation) != specification) {
                throw ContractError("native-provider-call-specification-identity-duplicate");
            }
        }
        for (const auto& operation : nativeOperations) {
            if ((operation.opcode == ghidra::CPUI_CALL ||
                 operation.opcode == ghidra::CPUI_CALLIND) &&
                !callsByOperation.contains(operation.operation)) {
                throw ContractError("native-provider-call-specification-missing");
            }
        }
    }

    [[nodiscard]] const NativeOperation& nativeOperationFor(
        const ghidra::PcodeOp& operation
    ) const {
        const auto iterator = nativeOperationIndices.find(&operation);
        if (iterator == nativeOperationIndices.end()) {
            throw ContractError("native-provider-operation-unresolved");
        }
        return nativeOperations[iterator->second];
    }

    [[nodiscard]] std::string joinDescriptor(const ghidra::Varnode& varnode) {
        auto* manager = varnode.getSpace()->getManager();
        if (manager == nullptr) {
            throw ContractError("native-provider-join-manager-unavailable");
        }
        const auto* join = manager->findJoin(varnode.getOffset());
        if (join == nullptr || join->numPieces() <= 0) {
            throw ContractError("native-provider-join-varnode-invalid");
        }
        const auto& unified = join->getUnified();
        if (unified.space != varnode.getSpace() || unified.size == 0U ||
            varnode.getOffset() < unified.offset ||
            varnode.getOffset() - unified.offset > unified.size ||
            static_cast<std::uint64_t>(varnode.getSize()) >
                static_cast<std::uint64_t>(unified.size) - (varnode.getOffset() - unified.offset)) {
            throw ContractError("native-provider-join-varnode-range-invalid");
        }
        std::string descriptor = "join";
        std::uint64_t totalSize = 0U;
        for (ghidra::int4 index = 0; index < join->numPieces(); ++index) {
            budget.checkpoint();
            const auto& piece = join->getPiece(index);
            const auto spaceIterator = spaceIds.find(piece.space);
            if (spaceIterator == spaceIds.end() || piece.size == 0U ||
                piece.offset > std::numeric_limits<std::uint64_t>::max() - piece.size) {
                throw ContractError("native-provider-join-piece-invalid");
            }
            const auto fragment = ":piece:" + spaceIterator->second + ":" +
                hex16(piece.offset) + ":" + std::to_string(piece.size);
            appendBoundedDescriptor(descriptor, fragment);
            if (piece.size > std::numeric_limits<std::uint64_t>::max() - totalSize) {
                throw ContractError("native-provider-join-piece-size-overflow");
            }
            totalSize += piece.size;
        }
        if (totalSize < unified.size) {
            throw ContractError("native-provider-join-piece-coverage-invalid");
        }
        const auto slice = ":slice:" + std::to_string(varnode.getOffset() - unified.offset) +
            ":" + std::to_string(varnode.getSize());
        appendBoundedDescriptor(descriptor, slice);
        return descriptor;
    }

    [[nodiscard]] SemanticVarnode describeVarnode(
        const ghidra::Varnode& varnode,
        const ghidra::PcodeOp& owner,
        std::optional<ghidra::int4> inputSlot
    ) {
        auto* space = varnode.getSpace();
        const auto spaceIterator = spaceIds.find(space);
        if (space == nullptr || spaceIterator == spaceIds.end() || varnode.getSize() <= 0 ||
            varnode.getSize() > 4096) {
            throw ContractError("native-provider-varnode-invalid");
        }
        SemanticVarnode semantic;
        semantic.record.addressSpaceId = spaceIterator->second;
        semantic.record.sizeBytes = static_cast<std::uint32_t>(varnode.getSize());

        const auto ownerOpcode = nativeOperationFor(owner).opcode;
        const bool isSpaceReference = inputSlot == 0 &&
            (ownerOpcode == ghidra::CPUI_LOAD || ownerOpcode == ghidra::CPUI_STORE);
        if (isSpaceReference) {
            if (!varnode.isConstant() || space->getType() != ghidra::IPTR_CONSTANT) {
                throw ContractError("native-provider-space-reference-invalid");
            }
            const auto* referencedSpace = varnode.getSpaceFromConst();
            const auto referenced = spaceIds.find(referencedSpace);
            if (referenced == spaceIds.end()) {
                throw ContractError("native-provider-space-reference-unresolved");
            }
            semantic.rankedDescriptor = "space-ref:" + referenced->second;
            semantic.record.role = "internal";
        } else if (space->getType() == ghidra::IPTR_IOP) {
            if (ownerOpcode != ghidra::CPUI_INDIRECT || inputSlot != 1) {
                throw ContractError("native-provider-iop-context-invalid");
            }
            const auto* referencedOperation = ghidra::PcodeOp::getOpFromConst(varnode.getAddr());
            const auto referenced = operationIds.find(referencedOperation);
            if (referenced == operationIds.end()) {
                throw ContractError("native-provider-iop-operation-unresolved");
            }
            semantic.rankedDescriptor = "iop:" + referenced->second;
            semantic.record.role = "internal";
        } else if (space->getType() == ghidra::IPTR_FSPEC) {
            if (ownerOpcode != ghidra::CPUI_CALL || inputSlot != 0) {
                throw ContractError("native-provider-fspec-context-invalid");
            }
            const auto* specification = ghidra::FuncCallSpecs::getFspecFromConst(varnode.getAddr());
            const auto specificationIterator = callsBySpecification.find(specification);
            const auto ownerIterator = callsByOperation.find(&owner);
            if (specificationIterator == callsBySpecification.end() ||
                ownerIterator == callsByOperation.end() || specificationIterator->first != ownerIterator->second.specification) {
                throw ContractError("native-provider-fspec-call-unresolved");
            }
            semantic.rankedDescriptor = "fspec:" + operationIds.at(&owner);
            if (specificationIterator->second.targetAddress) {
                semantic.rankedDescriptor += ":target:" +
                    hex16(*specificationIterator->second.targetAddress);
            } else {
                semantic.rankedDescriptor += ":indirect";
            }
            semantic.record.role = "internal";
        } else if (space->getType() == ghidra::IPTR_JOIN) {
            semantic.rankedDescriptor = joinDescriptor(varnode);
            semantic.record.role = "join";
        } else if (varnode.isAnnotation()) {
            // Two annotation forms are admitted: the code reference of a branch
            // or call (slot 0), and the volatile location named by a builtin
            // cRead/cWrite (slot 1), which Ghidra creates for pspec <volatile>
            // registers such as FPCR/FPSR/SVCR.
            const bool codeReference = inputSlot && *inputSlot == 0 && owner.isCodeRef() &&
                !varnode.getAddr().isInvalid() && varnode.getAddr().getSpace() == codeSpace;
            const bool volatileLocation = inputSlot && *inputSlot == 1 &&
                isVolatileAccessOperation(owner) && varnode.isVolatile() &&
                !varnode.getAddr().isInvalid() &&
                varnode.getSpace()->getType() == ghidra::IPTR_PROCESSOR &&
                varnode.getSpace() != codeSpace;
            const bool relativeCodeReference = rewrittenPartition && inputSlot == 0 &&
                (ownerOpcode == ghidra::CPUI_BRANCH || ownerOpcode == ghidra::CPUI_CBRANCH) &&
                varnode.isConstant() && space->getType() == ghidra::IPTR_CONSTANT;
            if (!codeReference && !volatileLocation && !relativeCodeReference) {
                throw ContractError("native-provider-annotation-context-invalid");
            }
            semantic.record.offset = varnode.getOffset();
            semantic.record.role = relativeCodeReference ? "constant" : "address";
            semantic.record.id = "varnode:" + space->getName() +
                (relativeCodeReference ? ":pcode-relative:" : ":address:") +
                hex16(varnode.getOffset()) + ":" + std::to_string(varnode.getSize());
        } else {
            if (space->getType() == ghidra::IPTR_FSPEC || space->getType() == ghidra::IPTR_IOP ||
                space->getType() == ghidra::IPTR_JOIN) {
                throw ContractError("native-provider-special-varnode-context-invalid");
            }
            semantic.record.offset = varnode.getOffset();
            semantic.record.role = ordinaryVarnodeRole(varnode, *architecture.translate);
            semantic.record.id = "varnode:" + space->getName() + ":" + hex16(varnode.getOffset()) +
                ":" + std::to_string(varnode.getSize()) + ":" + semantic.record.role;
            if (space->getType() == ghidra::IPTR_INTERNAL) {
                const auto* definition = varnode.getDef();
                if (definition == nullptr) {
                    semantic.record.id += ":entry";
                } else {
                    const auto definitionIterator = operationIds.find(definition);
                    if (definitionIterator == operationIds.end()) {
                        throw ContractError("native-provider-unique-definition-unresolved");
                    }
                    if (definition->getOut() != &varnode) {
                        throw ContractError("native-provider-unique-definition-output-mismatch");
                    }
                    semantic.record.id = detail::definedVarnodeIdentity(definitionIterator->second);
                }
            }
            const auto registerName = architecture.translate->getExactRegisterName(
                space, varnode.getOffset(), varnode.getSize()
            );
            if (!registerName.empty()) {
                requireNativeText(registerName, 256U, false);
                semantic.record.registerName = registerName;
            }
        }
        if (!semantic.rankedDescriptor.empty()) {
            requireNativeText(
                semantic.rankedDescriptor, kMaximumSpecialDescriptorText, false
            );
            semantic.record.id = "varnode:" + space->getName() + ":" + semantic.rankedDescriptor + ":" +
                std::to_string(varnode.getSize()) + ":" + semantic.record.role;
        }
        requireNativeText(semantic.record.id, kMaximumSpecialDescriptorText, false);
        return semantic;
    }

    void registerVarnode(
        const ghidra::Varnode& varnode,
        const ghidra::PcodeOp& owner,
        std::optional<ghidra::int4> inputSlot
    ) {
        auto semantic = describeVarnode(varnode, owner, inputSlot);
        const auto iterator = semanticVarnodes.find(&varnode);
        if (iterator != semanticVarnodes.end()) {
            if (iterator->second.record != semantic.record ||
                iterator->second.rankedDescriptor != semantic.rankedDescriptor) {
                throw ContractError("native-provider-varnode-context-conflict");
            }
            return;
        }
        if (!semantic.rankedDescriptor.empty()) {
            rankedDescriptors.insert(semantic.rankedDescriptor);
        }
        semanticVarnodes.emplace(&varnode, std::move(semantic));
    }

    void indexVarnodes() {
        for (const auto& info : nativeOperations) {
            budget.checkpoint();
            const auto& operation = *info.operation;
            if (const auto* output = operation.getOut(); output != nullptr) {
                if (output->getDef() != &operation) {
                    throw ContractError("native-provider-operation-output-definition-invalid");
                }
                registerVarnode(*output, operation, std::nullopt);
            }
            for (ghidra::int4 slot = 0; slot < operation.numInput(); ++slot) {
                budget.checkpoint();
                const auto* input = operation.getIn(slot);
                if (input == nullptr) {
                    throw ContractError("native-provider-operation-input-invalid");
                }
                if (!input->isHeritageKnown()) {
                    throw ContractError("native-provider-heritage-input-unknown");
                }
                const auto nativeUse = std::find(
                    input->beginDescend(), input->endDescend(), &operation
                );
                if (nativeUse == input->endDescend()) {
                    throw ContractError("native-provider-heritage-input-use-omitted");
                }
                registerVarnode(*input, operation, slot);
            }
        }
        validateNativeHeritage();
        std::uint64_t rank = 0U;
        std::map<std::string, std::uint64_t> ranks;
        for (const auto& descriptor : rankedDescriptors) {
            budget.checkpoint();
            ranks.emplace(descriptor, rank++);
        }
        for (auto& [native, semantic] : semanticVarnodes) {
            budget.checkpoint();
            static_cast<void>(native);
            if (!semantic.rankedDescriptor.empty()) {
                semantic.record.offset = ranks.at(semantic.rankedDescriptor);
            }
            const auto existing = varnodes.find(semantic.record.id);
            if (existing != varnodes.end()) {
                if (existing->second != semantic.record) {
                    throw ContractError("native-provider-varnode-identity-collision");
                }
                continue;
            }
            outputMeter.addRecord();
            outputMeter.addText(semantic.record.id);
            outputMeter.addText(semantic.record.addressSpaceId);
            outputMeter.addScalar();
            outputMeter.addScalar();
            outputMeter.addText(semantic.record.role);
            if (semantic.record.typeId) outputMeter.addText(*semantic.record.typeId);
            if (semantic.record.registerName) outputMeter.addText(*semantic.record.registerName);
            const auto [iterator, inserted] = varnodes.emplace(
                semantic.record.id, semantic.record
            );
            if (!inserted || iterator->second != semantic.record) {
                throw ContractError("native-provider-varnode-identity-collision");
            }
        }
    }

    void validateNativeHeritage() const {
        for (const auto& [native, semantic] : semanticVarnodes) {
            budget.checkpoint();
            static_cast<void>(semantic);
            if (native == nullptr) {
                throw ContractError("native-provider-heritage-descendant-invalid");
            }
            for (auto iterator = native->beginDescend();
                 iterator != native->endDescend(); ++iterator) {
                budget.checkpoint();
                const auto* descendant = *iterator;
                if (descendant == nullptr) {
                    throw ContractError("native-provider-heritage-descendant-invalid");
                }
                if (!operationIds.contains(descendant) ||
                    !nativeOperationIndices.contains(descendant)) {
                    throw ContractError("native-provider-heritage-descendant-unresolved");
                }
                bool hasMatchingInput = false;
                for (ghidra::int4 slot = 0; slot < descendant->numInput(); ++slot) {
                    budget.checkpoint();
                    if (descendant->getIn(slot) == native) {
                        hasMatchingInput = true;
                    }
                }
                if (!hasMatchingInput) {
                    throw ContractError("native-provider-heritage-descendant-input-unresolved");
                }
            }
        }
    }

    [[nodiscard]] const std::string& semanticVarnodeId(const ghidra::Varnode& varnode) const {
        const auto iterator = semanticVarnodes.find(&varnode);
        if (iterator == semanticVarnodes.end()) {
            throw ContractError("native-provider-varnode-unresolved");
        }
        return iterator->second.record.id;
    }

    void registerSsaValue(const SsaValueRecord& value) {
        const auto existing = ssaValues.find(value.id);
        if (existing != ssaValues.end()) {
            if (existing->second != value) {
                throw ContractError("native-provider-ssa-identity-collision");
            }
            return;
        }
        outputMeter.addRecord();
        outputMeter.addText(value.id);
        outputMeter.addText(value.varnodeId);
        outputMeter.addText(value.kind);
        if (value.definingOperationId) outputMeter.addText(*value.definingOperationId);
        if (value.definingPhiId) outputMeter.addText(*value.definingPhiId);
        ssaValues.emplace(value.id, value);
    }

    void indexPhis() {
        for (const auto& info : nativeOperations) {
            if (info.opcode != ghidra::CPUI_MULTIEQUAL) continue;
            budget.checkpoint();
            const auto& operation = *info.operation;
            const auto* output = operation.getOut();
            const auto* parent = operation.getParent();
            if (output == nullptr || parent == nullptr ||
                parent != nativeBlocks[info.blockIndex].block ||
                operation.numInput() < 2 || operation.numInput() != parent->sizeIn()) {
                throw ContractError("native-provider-phi-shape-invalid");
            }
            const auto id = detail::definedPhiIdentity(info.id);
            if (!phiIds.emplace(&operation, id).second) {
                throw ContractError("native-provider-phi-identity-duplicate");
            }
        }
    }

    void emitOperationsAndSsa() {
        for (std::size_t nativeIndex = 0; nativeIndex < nativeOperations.size(); ++nativeIndex) {
            const auto& info = nativeOperations[nativeIndex];
            budget.checkpoint();
            const auto& native = *info.operation;
            OperationRecord operation;
            operation.id = info.id;
            operation.blockId = nativeBlocks[info.blockIndex].record.id;
            operation.sequence = info.sequence;
            operation.opcode = info.opcodeName;
            operation.sourceRanges.push_back(decoded[info.instructionIndex].record.sourceRanges.front());
            if (info.opcode == ghidra::CPUI_CALLOTHER) {
                operation.userOperationName = userOperationNameFor(native);
            }
            outputMeter.addRecord();
            outputMeter.addText(operation.id);
            outputMeter.addText(operation.blockId);
            outputMeter.addScalar();
            outputMeter.addText(operation.opcode);
            outputMeter.addScalar();
            for (const auto& range : operation.sourceRanges) outputMeter.addSourceRange(range);
            outputMeter.addScalar();
            if (operation.userOperationName) outputMeter.addText(*operation.userOperationName);
            outputMeter.addScalar();
            outputMeter.addScalar();

            if (const auto* output = native.getOut(); output != nullptr) {
                operation.outputVarnodeId = semanticVarnodeId(*output);
                outputMeter.addText(*operation.outputVarnodeId);
            }
            for (ghidra::int4 slot = 0; slot < native.numInput(); ++slot) {
                budget.checkpoint();
                const auto* input = native.getIn(slot);
                if (input == nullptr) {
                    throw ContractError("native-provider-operation-input-invalid");
                }
                const auto& inputId = semanticVarnodeId(*input);
                outputMeter.addText(inputId);
                operation.inputVarnodeIds.push_back(inputId);
            }

            const auto callIterator = callsByOperation.find(&native);
            if (info.opcode == ghidra::CPUI_CALL || info.opcode == ghidra::CPUI_CALLIND) {
                if (callIterator == callsByOperation.end()) {
                    throw ContractError("native-provider-call-specification-missing");
                }
                CallRecord call;
                call.id = "call:" + operation.id;
                call.operationId = operation.id;
                const auto prototype = prototypeTypeIds.find(callIterator->second.specification);
                if (prototype == prototypeTypeIds.end()) {
                    throw ContractError("native-provider-call-prototype-type-missing");
                }
                call.prototypeTypeId = prototype->second;
                call.sourceRanges = operation.sourceRanges;
                if (info.opcode == ghidra::CPUI_CALL) {
                    call.kind = "direct";
                    operation.directTargetAddress = callIterator->second.targetAddress;
                    call.targetAddress = callIterator->second.targetAddress;
                    if (!call.targetAddress) {
                        throw ContractError("native-provider-direct-call-target-invalid");
                    }
                    if (const auto symbol = preferredCallableSymbol(
                            request, *call.targetAddress); symbol) {
                        call.targetSymbol = *symbol;
                    }
                } else {
                    call.kind = "indirect";
                }
                outputMeter.addRecord();
                outputMeter.addText(call.id);
                outputMeter.addText(call.operationId);
                outputMeter.addText(call.kind);
                outputMeter.addScalar();
                if (call.targetSymbol) outputMeter.addText(*call.targetSymbol);
                if (call.prototypeTypeId) outputMeter.addText(*call.prototypeTypeId);
                for (const auto& id : call.argumentVariableIds) outputMeter.addText(id);
                if (call.resultVariableId) outputMeter.addText(*call.resultVariableId);
                for (const auto& range : call.sourceRanges) outputMeter.addSourceRange(range);
                result.calls.push_back(std::move(call));
            } else if (info.opcode == ghidra::CPUI_BRANCH ||
                       info.opcode == ghidra::CPUI_CBRANCH) {
                const auto* target = native.getIn(0);
                if (target != nullptr && target->isAnnotation() && target->getSpace() == codeSpace) {
                    operation.directTargetAddress = static_cast<Address>(target->getOffset());
                } else if (!rewrittenPartition || target == nullptr || !target->isConstant()) {
                    throw ContractError("native-provider-direct-branch-target-invalid");
                }
                // A constant-space target is relative p-code flow, never a fabricated machine address.
            }

            SsaBindingRecord binding;
            binding.operationId = operation.id;
            outputMeter.addRecord();
            outputMeter.addText(binding.operationId);
            for (ghidra::int4 slot = 0; slot < native.numInput(); ++slot) {
                budget.checkpoint();
                const auto* input = native.getIn(slot);
                if (input == nullptr) {
                    throw ContractError("native-provider-operation-input-invalid");
                }
                const auto& semanticId = operation.inputVarnodeIds[static_cast<std::size_t>(slot)];
                auto value = ssaValueFor(*input, semanticId, operationIds, phiIds);
                const auto valueId = value.id;
                registerSsaValue(value);
                outputMeter.addText(valueId);
                binding.inputSsaValueIds.push_back(valueId);
            }
            if (const auto* output = native.getOut(); output != nullptr) {
                auto value = ssaValueFor(
                    *output, *operation.outputVarnodeId, operationIds, phiIds
                );
                const auto valueId = value.id;
                registerSsaValue(value);
                binding.outputSsaValueId = valueId;
                outputMeter.addText(valueId);
            }
            operation.authenticationEffect = authenticationEffectFor(
                operation, binding, nativeIndex
            );
            if (operation.authenticationEffect.outputSsaValueId) {
                outputMeter.addText(*operation.authenticationEffect.outputSsaValueId);
            }
            result.operations.push_back(std::move(operation));
            result.ssaBindings.push_back(std::move(binding));
        }
    }

    void appendEdge(
        std::size_t sourceIndex,
        const ghidra::FlowBlock* target,
        std::string kind,
        std::size_t ordinal,
        std::optional<std::string> operationId,
        ghidra::int4 nativeOutputSlot
    ) {
        const auto targetIterator = blockIndices.find(target);
        if (target == nullptr || targetIterator == blockIndices.end() ||
            nativeOutputSlot < 0 || nativeOutputSlot >= nativeBlocks[sourceIndex].block->sizeOut() ||
            nativeBlocks[sourceIndex].block->getOut(nativeOutputSlot) != target) {
            throw ContractError("native-provider-cfg-target-outside-request");
        }
        auto& source = nativeBlocks[sourceIndex];
        auto& destination = nativeBlocks[targetIterator->second];
        const auto nativeInputSlot = source.block->getOutRevIndex(nativeOutputSlot);
        if (nativeInputSlot < 0 || nativeInputSlot >= target->sizeIn() ||
            static_cast<std::size_t>(nativeInputSlot) >= destination.incomingEdgeIds.size() ||
            target->getIn(nativeInputSlot) != source.block ||
            target->getInRevIndex(nativeInputSlot) != nativeOutputSlot) {
            throw ContractError("native-provider-cfg-edge-reciprocity-invalid");
        }
        EdgeRecord edge;
        edge.sourceBlockId = source.record.id;
        edge.targetBlockId = destination.record.id;
        edge.targetAddress = rewrittenPartition ? destination.nativeEntryAddress : destination.record.startAddress;
        edge.kind = std::move(kind);
        edge.operationId = std::move(operationId);
        edge.id = "edge:" + edge.sourceBlockId + ":" + edge.kind + ":" +
            hex16(edge.targetAddress) + ":" + std::to_string(ordinal);
        auto& incomingEdgeId = destination.incomingEdgeIds[
            static_cast<std::size_t>(nativeInputSlot)
        ];
        if (incomingEdgeId) {
            throw ContractError("native-provider-cfg-incoming-edge-duplicate");
        }
        incomingEdgeId = edge.id;
        outputMeter.addRecord();
        outputMeter.addText(edge.id);
        outputMeter.addText(edge.sourceBlockId);
        if (edge.targetBlockId) outputMeter.addText(*edge.targetBlockId);
        outputMeter.addScalar();
        outputMeter.addText(edge.kind);
        if (edge.operationId) outputMeter.addText(*edge.operationId);
        outputMeter.addText(edge.id);
        outputMeter.addText(edge.id);
        source.record.successorEdgeIds.push_back(edge.id);
        destination.record.predecessorEdgeIds.push_back(edge.id);
        if (result.blockPartition) {
            std::string transfer = "splice";
            if (!source.operationIndices.empty()) {
                const auto index = source.operationIndices.back();
                const auto& native = nativeOperations[index];
                const auto& operation = result.operations[index];
                if (!edge.operationId || (native.opcode == ghidra::CPUI_CBRANCH &&
                        nativeOutputSlot != (native.operation->isFallthruTrue() ? 0 : 1))) {
                    transfer = "fallthrough";
                } else if (native.opcode == ghidra::CPUI_BRANCHIND) {
                    transfer = "indirect";
                } else if (operation.directTargetAddress) {
                    transfer = *operation.directTargetAddress == edge.targetAddress ? "direct" : "rewritten-direct";
                } else if (native.operation->numInput() > 0 && native.operation->getIn(0)->isConstant()) {
                    const bool sameInstruction = std::find(destination.instructionIndices.begin(),
                        destination.instructionIndices.end(), native.instructionIndex) != destination.instructionIndices.end();
                    transfer = sameInstruction ? "intra-instruction" : "rewritten-intra-instruction";
                } else throw ContractError("native-provider-final-edge-transfer-unresolved");
            }
            result.blockPartition->edges.push_back({edge.id, static_cast<std::uint32_t>(nativeOutputSlot),
                static_cast<std::uint32_t>(nativeInputSlot), std::move(transfer)});
        }
        result.edges.push_back(std::move(edge));
    }

    void emitSwitchEdges(
        std::size_t sourceIndex,
        const NativeOperation& terminatorInfo,
        const ghidra::PcodeOp& terminator
    ) {
        auto& source = nativeBlocks[sourceIndex];
        const auto outputCount = source.block->sizeOut();
        if (!source.block->isSwitchOut() || outputCount <= 0 ||
            static_cast<std::size_t>(outputCount) > nativeBlocks.size()) {
            throw ContractError("native-provider-switch-edges-invalid");
        }
        outputMeter.requireAdditionalProduct(static_cast<std::size_t>(outputCount), 64U);

        auto* table = function.findJumpTable(&terminator);
        if (table == nullptr || table->getIndirectOp() != &terminator ||
            table->getOpAddress() != terminator.getAddr()) {
            throw ContractError("native-provider-switch-table-unresolved");
        }
        std::size_t matchingTables = 0U;
        for (ghidra::int4 index = 0; index < function.numJumpTables(); ++index) {
            budget.checkpoint();
            const auto* candidate = function.getJumpTable(index);
            if (candidate != nullptr) {
                const bool sameOperation = candidate->getIndirectOp() == &terminator;
                const bool sameAddress = candidate->getOpAddress() == terminator.getAddr();
                if (!sameOperation && !sameAddress) {
                    continue;
                }
                if (!sameOperation || !sameAddress || candidate != table) {
                    throw ContractError("native-provider-switch-table-ambiguous");
                }
                ++matchingTables;
            }
        }
        const auto entryCount = table->numEntries();
        if (matchingTables != 1U || !table->isRecovered() || !table->isLabelled() ||
            table->isPartial() || entryCount <= 0 ||
            static_cast<std::size_t>(entryCount) > request.budgets.maxOperations) {
            throw ContractError("native-provider-switch-table-incomplete");
        }
        const auto defaultSlot = table->getDefaultBlock();
        if (defaultSlot < 0 || defaultSlot >= outputCount) {
            throw ContractError("native-provider-switch-default-invalid");
        }

        struct SwitchEdgeCandidate final {
            const ghidra::FlowBlock* target = nullptr;
            Address targetAddress = 0;
            std::string targetBlockId;
            std::vector<ghidra::uintb> labels;
            bool isDefault = false;
            ghidra::int4 nativeOutputSlot = -1;
        };
        std::vector<SwitchEdgeCandidate> cases;
        std::optional<SwitchEdgeCandidate> defaultEdge;
        std::vector<bool> visitedEntries(static_cast<std::size_t>(entryCount), false);
        std::unordered_set<const ghidra::FlowBlock*> visitedTargets;
        std::set<ghidra::uintb> visitedLabels;
        std::size_t visitedEntryCount = 0U;

        for (ghidra::int4 outputSlot = 0; outputSlot < outputCount; ++outputSlot) {
            budget.checkpoint();
            const auto* target = source.block->getOut(outputSlot);
            const auto targetIterator = blockIndices.find(target);
            const auto reverseIndex = source.block->getOutRevIndex(outputSlot);
            if (target == nullptr || targetIterator == blockIndices.end() ||
                !visitedTargets.insert(target).second || reverseIndex < 0 ||
                reverseIndex >= target->sizeIn() || target->getIn(reverseIndex) != source.block ||
                target->getInRevIndex(reverseIndex) != outputSlot) {
                throw ContractError("native-provider-switch-edge-reciprocity-invalid");
            }
            const bool isDefault = outputSlot == defaultSlot;
            if (source.block->isDefaultBranch(outputSlot) != isDefault) {
                throw ContractError("native-provider-switch-default-invalid");
            }
            const auto mappedCount = table->numIndicesByBlock(target);
            if (mappedCount <= 0 || mappedCount > entryCount) {
                throw ContractError("native-provider-switch-index-map-invalid");
            }
            SwitchEdgeCandidate edge;
            edge.target = target;
            edge.targetAddress = rewrittenPartition ? nativeBlocks[targetIterator->second].nativeEntryAddress :
                nativeBlocks[targetIterator->second].record.startAddress;
            edge.targetBlockId = nativeBlocks[targetIterator->second].record.id;
            edge.isDefault = isDefault;
            edge.nativeOutputSlot = outputSlot;
            edge.labels.reserve(static_cast<std::size_t>(mappedCount));
            for (ghidra::int4 mappedIndex = 0; mappedIndex < mappedCount; ++mappedIndex) {
                budget.checkpoint();
                const auto tableIndex = table->getIndexByBlock(target, mappedIndex);
                if (tableIndex < 0 || tableIndex >= entryCount ||
                    visitedEntries[static_cast<std::size_t>(tableIndex)]) {
                    throw ContractError("native-provider-switch-index-map-invalid");
                }
                const auto address = table->getAddressByIndex(tableIndex);
                if (address.isInvalid() || address.getSpace() != codeSpace ||
                    address.getOffset() != edge.targetAddress) {
                    throw ContractError("native-provider-switch-target-invalid");
                }
                const auto label = table->getLabelByIndex(tableIndex);
                // Table entries can target the default block with real case values
                // (byte tables in libjpeg's j12/j16 color converters); those labels are
                // legitimate. A non-default entry still needs its case label.
                if (!isDefault && label == ghidra::JumpValues::NO_LABEL) {
                    throw ContractError("native-provider-switch-case-label-invalid");
                }
                if (label != ghidra::JumpValues::NO_LABEL &&
                    !visitedLabels.insert(label).second) {
                    throw ContractError("native-provider-switch-case-label-duplicate");
                }
                visitedEntries[static_cast<std::size_t>(tableIndex)] = true;
                ++visitedEntryCount;
                edge.labels.push_back(label);
            }
            std::sort(edge.labels.begin(), edge.labels.end());
            if (isDefault) {
                if (defaultEdge) {
                    throw ContractError("native-provider-switch-default-invalid");
                }
                defaultEdge = std::move(edge);
            } else {
                cases.push_back(std::move(edge));
            }
        }
        if (visitedEntryCount != static_cast<std::size_t>(entryCount) ||
            std::find(visitedEntries.begin(), visitedEntries.end(), false) != visitedEntries.end() ||
            !defaultEdge || cases.size() + 1U != static_cast<std::size_t>(outputCount)) {
            throw ContractError("native-provider-switch-index-map-incomplete");
        }
        std::sort(cases.begin(), cases.end(), [](const SwitchEdgeCandidate& lhs,
                                                  const SwitchEdgeCandidate& rhs) {
            return std::tie(lhs.labels, lhs.targetAddress, lhs.targetBlockId) <
                std::tie(rhs.labels, rhs.targetAddress, rhs.targetBlockId);
        });
        for (std::size_t ordinal = 0; ordinal < cases.size(); ++ordinal) {
            appendEdge(sourceIndex, cases[ordinal].target, "switchCase", ordinal,
                       terminatorInfo.id, cases[ordinal].nativeOutputSlot);
        }
        appendEdge(sourceIndex, defaultEdge->target, "switchDefault", cases.size(),
                   terminatorInfo.id, defaultEdge->nativeOutputSlot);
        source.record.terminatorKind = "switch";
        outputMeter.addText(source.record.terminatorKind);
    }

    void emitEdges() {
        for (std::size_t blockIndex = 0; blockIndex < nativeBlocks.size(); ++blockIndex) {
            budget.checkpoint();
            auto& block = nativeBlocks[blockIndex];
            if (block.operationIndices.empty()) {
                if (!rewrittenPartition || block.block->sizeOut() > 1 || block.block->sizeOut() < 0) {
                    throw ContractError("native-provider-final-empty-terminator-invalid");
                }
                block.record.terminatorKind = block.block->sizeOut() == 0 ? "exit" : "splice";
                outputMeter.addText(block.record.terminatorKind);
                if (block.block->sizeOut() == 1) appendEdge(blockIndex, block.block->getOut(0), "splice", 0U, std::nullopt, 0);
                continue;
            }
            const auto& terminatorInfo = nativeOperations[block.operationIndices.back()];
            const auto* terminator = terminatorInfo.operation;
            if (block.block->lastOp() != terminator) {
                throw ContractError("native-provider-basic-block-terminator-invalid");
            }
            switch (terminatorInfo.opcode) {
            case ghidra::CPUI_RETURN:
                if (block.block->sizeOut() != 0) {
                    throw ContractError("native-provider-return-edge-invalid");
                }
                block.record.terminatorKind = "return";
                outputMeter.addText(block.record.terminatorKind);
                break;
            case ghidra::CPUI_CBRANCH: {
                if (block.block->sizeOut() != 2 || block.block->getFalseOut() == nullptr ||
                    block.block->getTrueOut() == nullptr) {
                    throw ContractError("native-provider-conditional-edges-invalid");
                }
                block.record.terminatorKind = "conditional";
                outputMeter.addText(block.record.terminatorKind);
                const auto* falseTarget = block.block->getFalseOut();
                const auto* trueTarget = block.block->getTrueOut();
                appendEdge(blockIndex, falseTarget, "false", 0U, terminatorInfo.id, 0);
                appendEdge(blockIndex, trueTarget, "true", 1U, terminatorInfo.id, 1);
                const auto& directTarget =
                    result.operations[block.operationIndices.back()].directTargetAddress;
                const auto* encodedTarget = terminator->isFallthruTrue()
                    ? falseTarget : trueTarget;
                const auto encodedBlock = blockIndices.find(encodedTarget);
                if (!rewrittenPartition && (!directTarget || encodedBlock == blockIndices.end() ||
                    *directTarget != nativeBlocks[encodedBlock->second].record.startAddress)) {
                    throw ContractError("native-provider-conditional-target-missing");
                }
                break;
            }
            case ghidra::CPUI_BRANCH:
                if (block.block->sizeOut() != 1 || block.block->getOut(0) == nullptr) {
                    throw ContractError("native-provider-branch-edge-invalid");
                }
                block.record.terminatorKind = "branch";
                outputMeter.addText(block.record.terminatorKind);
                appendEdge(
                    blockIndex, block.block->getOut(0), "branch", 0U, terminatorInfo.id, 0
                );
                if (!rewrittenPartition && (!result.operations[block.operationIndices.back()].directTargetAddress ||
                    *result.operations[block.operationIndices.back()].directTargetAddress !=
                        nativeBlocks[blockIndices.at(block.block->getOut(0))].record.startAddress)) {
                    throw ContractError("native-provider-branch-target-mismatch");
                }
                break;
            case ghidra::CPUI_BRANCHIND:
                emitSwitchEdges(blockIndex, terminatorInfo, *terminator);
                break;
            default:
                if (block.block->sizeOut() == 0) {
                    block.record.terminatorKind = "exit";
                    outputMeter.addText(block.record.terminatorKind);
                } else if (block.block->sizeOut() == 1 && block.block->getOut(0) != nullptr) {
                    block.record.terminatorKind = "fallthrough";
                    outputMeter.addText(block.record.terminatorKind);
                    appendEdge(
                        blockIndex, block.block->getOut(0), "fallthrough", 0U, std::nullopt, 0
                    );
                } else {
                    throw ContractError("native-provider-basic-block-edges-unsupported");
                }
                break;
            }
        }
    }

    void emitPhis() {
        for (std::size_t operationIndex = 0; operationIndex < nativeOperations.size();
             ++operationIndex) {
            const auto& info = nativeOperations[operationIndex];
            if (info.opcode != ghidra::CPUI_MULTIEQUAL) continue;
            budget.checkpoint();
            const auto& operation = *info.operation;
            const auto& block = nativeBlocks[info.blockIndex];
            if (operationIndex >= result.operations.size() ||
                operationIndex >= result.ssaBindings.size() ||
                result.operations[operationIndex].id != info.id ||
                result.ssaBindings[operationIndex].operationId != info.id ||
                static_cast<std::size_t>(operation.numInput()) != block.incomingEdgeIds.size()) {
                throw ContractError("native-provider-phi-binding-invalid");
            }
            const auto& binding = result.ssaBindings[operationIndex];
            const auto* output = operation.getOut();
            const auto phiId = phiIds.find(&operation);
            if (output == nullptr || !binding.outputSsaValueId ||
                binding.inputSsaValueIds.size() != block.incomingEdgeIds.size() ||
                phiId == phiIds.end()) {
                throw ContractError("native-provider-phi-binding-invalid");
            }

            PhiRecord phi;
            phi.id = phiId->second;
            phi.blockId = block.record.id;
            phi.varnodeId = semanticVarnodeId(*output);
            phi.outputSsaValueId = *binding.outputSsaValueId;
            outputMeter.addRecord();
            outputMeter.addText(phi.id);
            outputMeter.addText(phi.blockId);
            outputMeter.addText(phi.varnodeId);
            outputMeter.addText(phi.outputSsaValueId);

            for (ghidra::int4 slot = 0; slot < operation.numInput(); ++slot) {
                budget.checkpoint();
                const auto index = static_cast<std::size_t>(slot);
                outputMeter.addContainer();
                const auto* predecessor = block.block->getIn(slot);
                const auto predecessorIndex = blockIndices.find(predecessor);
                if (predecessor == skippedEntryScaffold &&
                    block.record.startAddress == request.function.entryAddress) {
                    PhiIncomingRecord incoming;
                    incoming.ssaValueId = binding.inputSsaValueIds[index];
                    outputMeter.addText(incoming.ssaValueId);
                    phi.incoming.push_back(std::move(incoming));
                    continue;
                }
                if (predecessor == nullptr || predecessorIndex == blockIndices.end() ||
                    !block.incomingEdgeIds[index]) {
                    throw ContractError("native-provider-phi-predecessor-unresolved");
                }
                const auto& edgeId = *block.incomingEdgeIds[index];
                const auto edge = std::find_if(
                    result.edges.begin(), result.edges.end(),
                    [&edgeId](const EdgeRecord& candidate) { return candidate.id == edgeId; }
                );
                const auto& sourceBlockId = nativeBlocks[predecessorIndex->second].record.id;
                if (edge == result.edges.end() || edge->sourceBlockId != sourceBlockId ||
                    !edge->targetBlockId || *edge->targetBlockId != phi.blockId) {
                    throw ContractError("native-provider-phi-edge-unresolved");
                }
                PhiIncomingRecord incoming;
                incoming.sourceBlockId = sourceBlockId;
                incoming.edgeId = edgeId;
                incoming.ssaValueId = binding.inputSsaValueIds[index];
                outputMeter.addText(sourceBlockId);
                outputMeter.addText(edgeId);
                outputMeter.addText(incoming.ssaValueId);
                phi.incoming.push_back(std::move(incoming));
            }
            result.phis.push_back(std::move(phi));
        }
    }

    [[nodiscard]] static std::string regionKind(const ghidra::FlowBlock& block) {
        switch (block.getType()) {
        case ghidra::FlowBlock::t_graph: return block.getParent() == nullptr ? "root" : "sequence";
        case ghidra::FlowBlock::t_ls: return "sequence";
        case ghidra::FlowBlock::t_condition: return "condition";
        case ghidra::FlowBlock::t_if: return "if";
        case ghidra::FlowBlock::t_whiledo: return "while";
        case ghidra::FlowBlock::t_dowhile: return "doWhile";
        case ghidra::FlowBlock::t_switch: return "switch";
        case ghidra::FlowBlock::t_infloop: return "infiniteLoop";
        case ghidra::FlowBlock::t_goto: return "goto";
        case ghidra::FlowBlock::t_multigoto: return "multiGoto";
        case ghidra::FlowBlock::t_basic:
        case ghidra::FlowBlock::t_copy:
        case ghidra::FlowBlock::t_plain:
            throw ContractError("native-provider-region-kind-invalid");
        }
        throw ContractError("native-provider-region-kind-invalid");
    }

    [[nodiscard]] static bool isGraphRegion(const ghidra::FlowBlock& block) {
        switch (block.getType()) {
        case ghidra::FlowBlock::t_graph:
        case ghidra::FlowBlock::t_ls:
        case ghidra::FlowBlock::t_condition:
        case ghidra::FlowBlock::t_if:
        case ghidra::FlowBlock::t_whiledo:
        case ghidra::FlowBlock::t_dowhile:
        case ghidra::FlowBlock::t_switch:
        case ghidra::FlowBlock::t_infloop:
        case ghidra::FlowBlock::t_goto:
        case ghidra::FlowBlock::t_multigoto:
            return true;
        case ghidra::FlowBlock::t_basic:
        case ghidra::FlowBlock::t_copy:
        case ghidra::FlowBlock::t_plain:
            return false;
        }
        return false;
    }

    [[nodiscard]] RegionLeafSet collectRegionLeaves(const ghidra::FlowBlock& block) const {
        RegionLeafSet leaves;
        const std::function<void(const ghidra::FlowBlock&)> visit =
            [&](const ghidra::FlowBlock& current) {
                budget.checkpoint();
                switch (current.getType()) {
                case ghidra::FlowBlock::t_basic: {
                    const auto* basic = static_cast<const ghidra::BlockBasic*>(&current);
                    const auto iterator = blockIndices.find(basic);
                    if (iterator == blockIndices.end()) {
                        if (basic->beginOp() == basic->endOp()) return;
                        throw ContractError("native-provider-region-basic-block-unresolved");
                    }
                    leaves.blockIndices.push_back(iterator->second);
                    break;
                }
                case ghidra::FlowBlock::t_copy: {
                    const auto* copied = current.subBlock(0);
                    if (copied == nullptr) {
                        throw ContractError("native-provider-region-copy-invalid");
                    }
                    visit(*copied);
                    break;
                }
                case ghidra::FlowBlock::t_graph:
                case ghidra::FlowBlock::t_ls:
                case ghidra::FlowBlock::t_condition:
                case ghidra::FlowBlock::t_if:
                case ghidra::FlowBlock::t_whiledo:
                case ghidra::FlowBlock::t_dowhile:
                case ghidra::FlowBlock::t_switch:
                case ghidra::FlowBlock::t_infloop:
                case ghidra::FlowBlock::t_goto:
                case ghidra::FlowBlock::t_multigoto: {
                    const auto& graph = static_cast<const ghidra::BlockGraph&>(current);
                    const auto size = graph.getSize();
                    if (size <= 0) {
                        throw ContractError("native-provider-region-children-empty");
                    }
                    for (ghidra::int4 index = 0; index < size; ++index) {
                        const auto* child = graph.getBlock(index);
                        if (child == nullptr) {
                            throw ContractError("native-provider-region-child-invalid");
                        }
                        visit(*child);
                    }
                    break;
                }
                case ghidra::FlowBlock::t_plain:
                    throw ContractError("native-provider-region-kind-invalid");
                }
            };
        visit(block);
        std::sort(leaves.blockIndices.begin(), leaves.blockIndices.end());
        leaves.blockIndices.erase(
            std::unique(leaves.blockIndices.begin(), leaves.blockIndices.end()),
            leaves.blockIndices.end()
        );
        if (leaves.blockIndices.empty()) {
            throw ContractError("native-provider-region-block-set-empty");
        }
        return leaves;
    }

    [[nodiscard]] std::string regionIdentity(
        std::string_view kind,
        const RegionLeafSet& leaves
    ) {
        std::uint64_t digest = 1469598103934665603ULL;
        const auto mix = [&digest](std::uint64_t value) {
            for (std::size_t byte = 0; byte < sizeof(value); ++byte) {
                digest ^= (value >> (byte * 8U)) & 0xffU;
                digest *= 1099511628211ULL;
            }
        };
        const auto first = nativeBlocks[leaves.blockIndices.front()].record.startAddress;
        const auto last = nativeBlocks[leaves.blockIndices.back()].record.startAddress;
        for (const auto blockIndex : leaves.blockIndices) {
            const auto& record = nativeBlocks[blockIndex].record;
            mix(record.startAddress);
            mix(record.endAddressExclusive);
            if (rewrittenPartition) mix(static_cast<std::uint64_t>(blockIndex));
        }
        std::string base = "region:";
        base.append(kind);
        base.push_back(':');
        base.append(hex16(first));
        base.push_back(':');
        base.append(hex16(last));
        base.push_back(':');
        base.append(hex16(static_cast<std::uint64_t>(leaves.blockIndices.size())));
        base.push_back(':');
        base.append(hex16(digest));
        auto& count = regionIdentityCounts[base];
        const auto ordinal = count++;
        if (ordinal == 0U) return base;
        base.push_back(':');
        base.append(hex16(static_cast<std::uint64_t>(ordinal)));
        return base;
    }

    void addRegionAccounting(const RegionRecord& region) {
        outputMeter.addRecord();
        outputMeter.addText(region.id);
        outputMeter.addText(region.kind);
        if (region.parentRegionId) outputMeter.addText(*region.parentRegionId);
        for (const auto& id : region.childRegionIds) outputMeter.addText(id);
        for (const auto& id : region.blockIds) outputMeter.addText(id);
        if (region.conditionOperationId) outputMeter.addText(*region.conditionOperationId);
        for (const auto& range : region.sourceRanges) outputMeter.addSourceRange(range);
    }

    [[nodiscard]] std::optional<std::string> emitStructuredRegion(
        const ghidra::FlowBlock& block,
        const std::optional<std::string>& parentId
    ) {
        budget.checkpoint();
        if (block.getType() == ghidra::FlowBlock::t_basic) return std::nullopt;
        if (block.getType() == ghidra::FlowBlock::t_copy) {
            const auto* copied = block.subBlock(0);
            if (copied == nullptr) throw ContractError("native-provider-region-copy-invalid");
            return emitStructuredRegion(*copied, parentId);
        }
        if (!isGraphRegion(block)) {
            throw ContractError("native-provider-region-kind-invalid");
        }

        const auto kind = regionKind(block);
        const auto leaves = collectRegionLeaves(block);
        RegionRecord region;
        region.kind = kind;
        region.parentRegionId = parentId;
        region.id = regionIdentity(kind, leaves);
        for (const auto blockIndex : leaves.blockIndices) {
            const auto& record = nativeBlocks[blockIndex].record;
            region.blockIds.push_back(record.id);
            const auto ranges = blockSourceRanges(blockIndex);
            region.sourceRanges.insert(region.sourceRanges.end(), ranges.begin(), ranges.end());
        }

        if (rewrittenPartition) coalesceProvenance(region.sourceRanges);
        const auto& graph = static_cast<const ghidra::BlockGraph&>(block);
        const auto size = graph.getSize();
        for (ghidra::int4 index = 0; index < size; ++index) {
            const auto* child = graph.getBlock(index);
            if (child == nullptr) {
                throw ContractError("native-provider-region-child-invalid");
            }
            const auto childId = emitStructuredRegion(*child, region.id);
            if (childId) region.childRegionIds.push_back(*childId);
        }

        if (!regionIds.insert(region.id).second) {
            throw ContractError("native-provider-region-identity-duplicate");
        }
        addRegionAccounting(region);
        result.regions.push_back(std::move(region));
        return result.regions.back().id;
    }

    void emitStructuredRegions() {
        const auto& structure = function.getStructure();
        const auto rootId = emitStructuredRegion(structure, std::nullopt);
        if (!rootId || result.regions.empty()) {
            throw ContractError("native-provider-region-root-missing");
        }
    }

    void finishResult() {
        for (auto& [id, type] : types) {
            static_cast<void>(id);
            result.types.push_back(std::move(type));
        }
        for (auto& instruction : decoded) {
            result.instructions.push_back(std::move(instruction.record));
        }
        for (auto& [id, varnode] : varnodes) {
            static_cast<void>(id);
            result.varnodes.push_back(std::move(varnode));
        }
        for (auto& [id, variable] : variables) {
            static_cast<void>(id);
            result.variables.push_back(std::move(variable));
        }
        for (auto& [id, value] : ssaValues) {
            static_cast<void>(id);
            result.ssaValues.push_back(std::move(value));
        }
        for (auto& block : nativeBlocks) {
            result.blocks.push_back(std::move(block.record));
        }
        outputMeter.addScalar();
        if (result.blockPartition) detail::accountBlockPartition(outputMeter, *result.blockPartition);
        canonicalizeStructuredResult(result);
        validateStructuredResult(request, result);
        const auto exactOutputBytes = structuredResultEncodedSizeUpperBound(
            result, [this] { budget.checkpoint(); }
        );
        if (outputMeter.used() != exactOutputBytes) {
            throw ContractError("native-provider-output-budget-accounting-mismatch");
        }
        if (exactOutputBytes > request.budgets.maxOutputBytes) {
            throw ContractError("native-provider-output-budget-exceeded");
        }
        budget.checkpoint();
    }

    const AnalysisRequestView& request;
    ghidra::Funcdata& function;
    const GhidraArchitecture& architecture;
    const BudgetGuard& budget;
    ghidra::AddrSpace* codeSpace = nullptr;
    std::vector<DecodedInstruction> decoded;
    StructuredResult result;
    std::unordered_map<const ghidra::AddrSpace*, std::string> spaceIds;
    std::vector<NativeBlock> nativeBlocks;
    bool rewrittenPartition = false;
    const ghidra::FlowBlock* skippedEntryScaffold = nullptr;
    std::unordered_map<const ghidra::FlowBlock*, std::size_t> blockIndices;
    std::vector<NativeOperation> nativeOperations;
    std::unordered_map<const ghidra::PcodeOp*, std::string> operationIds;
    std::unordered_map<const ghidra::PcodeOp*, std::string> phiIds;
    std::unordered_map<const ghidra::PcodeOp*, std::size_t> nativeOperationIndices;
    std::unordered_map<const ghidra::FuncCallSpecs*, NativeCall> callsBySpecification;
    std::unordered_map<const ghidra::PcodeOp*, NativeCall> callsByOperation;
    std::unordered_map<const ghidra::Varnode*, SemanticVarnode> semanticVarnodes;
    std::vector<const ghidra::Datatype*> nativeTypes;
    std::unordered_set<const ghidra::Datatype*> nativeTypeSet;
    std::unordered_map<const ghidra::Datatype*, std::string> typeIds;
    std::unordered_map<const ghidra::FuncProto*, std::string> prototypeTypeIds;
    std::unordered_map<std::uint64_t, std::vector<const ghidra::Datatype*>> nativeIdOwners;
    std::set<std::string> rankedDescriptors;
    std::map<std::string, std::size_t> regionIdentityCounts;
    std::unordered_set<std::string> regionIds;
    std::map<std::string, VarnodeRecord> varnodes;
    std::map<std::string, TypeRecord> types;
    std::map<std::string, VariableRecord> variables;
    std::map<std::string, SsaValueRecord> ssaValues;
    std::vector<std::string> userOperationNames;
    IncrementalOutputMeter outputMeter;
};

[[nodiscard]] NativeStructuredExport exportStructuredResult(
    const AnalysisRequestView& request,
    ghidra::Funcdata& function,
    const GhidraArchitecture& architecture,
    const BudgetGuard& budget
) {
    return NativeExportContext(
        request, function, architecture, budget
    ).run();
}

class PrintOutputStreamGuard final {
public:
    PrintOutputStreamGuard(ghidra::PrintLanguage& printerValue, std::ostream* previousValue)
        : printer(printerValue), previous(previousValue), previousMarkup(printerValue.emitsMarkup()) {}

    ~PrintOutputStreamGuard() {
        // A markup emitter binds a reference to its stream. Restore the prior
        // mode while the temporary stream is still alive, before restoring a
        // potentially null stream on the ordinary non-markup printer.
        if (printer.emitsMarkup() != previousMarkup) printer.setMarkup(previousMarkup);
        printer.setOutputStream(previous);
    }

    PrintOutputStreamGuard(const PrintOutputStreamGuard&) = delete;
    PrintOutputStreamGuard& operator=(const PrintOutputStreamGuard&) = delete;

private:
    ghidra::PrintLanguage& printer;
    std::ostream* previous;
    bool previousMarkup;
};

[[nodiscard]] std::optional<std::string_view> markupAttribute(
    const ghidra::Attributes& attributes,
    std::string_view name
) {
    for (ghidra::int4 index = 0; index < attributes.getLength(); ++index) {
        if (attributes.getLocalName(index) == name) {
            return attributes.getValue(index);
        }
    }
    return std::nullopt;
}

[[nodiscard]] std::uint64_t parseMarkupUnsigned(std::string_view value) {
    if (value.starts_with("0x")) value.remove_prefix(2U);
    if (value.empty()) throw ContractError("native-provider-pseudocode-markup-reference-invalid");
    std::uint64_t result = 0U;
    const auto converted = std::from_chars(
        value.data(), value.data() + value.size(), result, 16
    );
    if (converted.ec != std::errc{} || converted.ptr != value.data() + value.size()) {
        throw ContractError("native-provider-pseudocode-markup-reference-invalid");
    }
    return result;
}

[[nodiscard]] std::int64_t parseMarkupSigned(std::string_view value) {
    if (value.empty()) throw ContractError("native-provider-pseudocode-markup-reference-invalid");
    std::int64_t result = 0;
    const auto converted = std::from_chars(
        value.data(), value.data() + value.size(), result, 10
    );
    if (converted.ec != std::errc{} || converted.ptr != value.data() + value.size()) {
        throw ContractError("native-provider-pseudocode-markup-reference-invalid");
    }
    return result;
}

[[nodiscard]] std::string canonicalPseudocodeTokenKind(
    std::string_view name,
    std::string_view text,
    const std::optional<std::string>& color
) {
    if (name == "variable" || name == "funcname" || name == "field" ||
        name == "bitfield" || name == "label") {
        return "identifier";
    }
    if (name == "op") return "operation";
    if (name == "type") return "type";
    if (name == "comment") return "comment";
    if (name == "value") return "literal";
    if (name != "syntax") {
        throw ContractError("native-provider-pseudocode-token-kind-invalid");
    }

    if (std::all_of(text.begin(), text.end(), [](unsigned char byte) {
            return byte == ' ' || byte == '\t' || byte == '\n' || byte == '\r';
        })) {
        return "whitespace";
    }

    if (color == "0" || color == "keyword") return "keyword";
    if (color == "1" || color == "comment") return "comment";
    if (color == "2" || color == "type") return "type";
    if (color == "3" || color == "4" || color == "6" || color == "7" ||
        color == "funcname" || color == "variable" || color == "parameter" ||
        color == "global") {
        return "identifier";
    }
    if (color == "5" || color == "constant") return "literal";
    return "punctuation";
}

class PseudocodeMarkupPositionHandler final : public ghidra::ContentHandler {
public:
    PseudocodeMarkupPositionHandler(
        const AnalysisRequestView& requestValue,
        const BudgetGuard& budgetValue,
        const NativeMarkupIndex& indexValue,
        StructuredResult& resultValue
    )
        : request(requestValue), budget(budgetValue), index(indexValue), result(resultValue),
          accounted(result, [this] { budget.checkpoint(); }) {
        const auto ceiling = std::min<std::size_t>(request.budgets.maxOutputBytes, kMaximumTokenMetadataOutput);
        const auto available = ceiling - std::min(accounted.value(), ceiling);
        // The rendered document is the deliverable; token metadata is truncated
        // first (native-pseudocode-token-metadata-truncated). A 32 KiB reserve cut
        // large NEON kernels' text at ~32 KB on libjpeg (f1039db19).
        const auto reserve = std::min<std::size_t>(kMaximumPseudocodeText, available / 2U);
        tokenOutputLimit = ceiling - reserve;
    }

    [[nodiscard]] bool metadataTruncated() const noexcept { return tokenBudgetExhausted; }

    [[nodiscard]] bool isComplete() const {
        return error.empty() && rootSeen && documentEnded && frames.empty();
    }

    void setDocumentLocator(ghidra::Locator) override {}

    void startDocument() override {
        if (documentStarted) fail("native-provider-pseudocode-markup-format-invalid");
        documentStarted = true;
    }

    void endDocument() override {
        if (!documentStarted || !frames.empty()) {
            fail("native-provider-pseudocode-markup-format-invalid");
        }
        documentEnded = true;
    }

    void startPrefixMapping(const std::string&, const std::string&) override {}
    void endPrefixMapping(const std::string&) override {}

    void startElement(
        const std::string&,
        const std::string& localName,
        const std::string& qualifiedName,
        const ghidra::Attributes& attributes
    ) override {
        budget.checkpoint();
        const std::string name = localName.empty() ? qualifiedName : localName;
        if (!rootSeen) {
            if (name != "function" || !frames.empty()) {
                fail("native-provider-pseudocode-markup-root-invalid");
            }
            rootSeen = true;
        }

        Context context = frames.empty() ? Context{} : frames.back().context;
        resolveUnsigned(context, markupAttribute(attributes, "opref"), index.operations);
        resolveUnsigned(context, markupAttribute(attributes, "varref"), index.varnodes);
        resolveUnsigned(context, markupAttribute(attributes, "symref"), index.variables);
        if (const auto encodedBlock = markupAttribute(attributes, "blockref"); encodedBlock) {
            const auto block = index.blocks.find(parseMarkupSigned(*encodedBlock));
            if (block != index.blocks.end()) addReference(context, block->second);
        }
        if (name == "type" || name == "field" || name == "bitfield") {
            resolveUnsigned(context, markupAttribute(attributes, "id"), index.types);
        }

        if (name == "break") {
            const auto indent = markupAttribute(attributes, "indent");
            if (!indent) fail("native-provider-pseudocode-markup-format-invalid");
            const auto parsed = parseMarkupSigned(*indent);
            if (parsed < 0 || parsed >= std::numeric_limits<std::uint32_t>::max() ||
                line == std::numeric_limits<std::uint32_t>::max()) {
                fail("native-provider-pseudocode-token-position-invalid");
            }
            ++line;
            column = static_cast<std::uint32_t>(parsed) + 1U;
        }

        const bool isToken = tokenElements().contains(name);
        Frame frame{
            .name = name,
            .context = std::move(context),
            .isToken = isToken,
            .startLine = line,
            .startColumn = column,
        };
        if (isToken) {
            if (const auto encodedColor = markupAttribute(attributes, "color")) {
                frame.color = std::string(*encodedColor);
            }
        }
        frames.push_back(std::move(frame));
    }

    void endElement(
        const std::string&,
        const std::string& localName,
        const std::string& qualifiedName
    ) override {
        budget.checkpoint();
        const std::string_view name = localName.empty() ? qualifiedName : localName;
        if (frames.empty() || frames.back().name != name) {
            fail("native-provider-pseudocode-markup-format-invalid");
        }
        if (frames.back().isToken) appendToken(frames.back());
        frames.pop_back();
    }

    void characters(const char* text, ghidra::int4 start, ghidra::int4 length) override {
        budget.checkpoint();
        if (text == nullptr || start < 0 || length < 0) {
            fail("native-provider-pseudocode-markup-format-invalid");
        }
        const std::string_view content(text + start, static_cast<std::size_t>(length));
        if (!frames.empty() && frames.back().isToken) {
            if (frames.back().content.size() > 65536U ||
                content.size() > 65536U - frames.back().content.size()) {
                fail("native-provider-pseudocode-token-text-exceeded");
            }
            frames.back().content.append(content);
            advancePosition(content);
        }
    }

    void ignorableWhitespace(const char* text, ghidra::int4 start, ghidra::int4 length) override {
        characters(text, start, length);
    }

    void processingInstruction(const std::string&, const std::string&) override {}
    void setVersion(const std::string&) override {}
    void setEncoding(const std::string&) override {}
    void skippedEntity(const std::string&) override {
        fail("native-provider-pseudocode-markup-format-invalid");
    }
    void setError(const std::string& message) override { error = message; }

private:
    struct Context final {
        bool resolvable = true;
        std::vector<TokenEntityReference> references;
        std::vector<SourceRange> sourceRanges;
    };

    struct Frame final {
        std::string name;
        Context context;
        bool isToken = false;
        std::uint32_t startLine = 0U;
        std::uint32_t startColumn = 0U;
        std::optional<std::string> color;
        std::string content;
    };

    [[noreturn]] static void fail(std::string_view code) {
        throw ContractError(std::string(code));
    }

    [[nodiscard]] static const std::set<std::string_view>& tokenElements() {
        static const std::set<std::string_view> elements{
            "variable", "op", "funcname", "type", "field", "bitfield",
            "comment", "label", "value", "syntax",
        };
        return elements;
    }

    static void addReference(Context& context, const NativeMarkupReference& reference) {
        if (std::none_of(
                context.references.begin(), context.references.end(),
                [&reference](const TokenEntityReference& existing) {
                    return existing.kind == reference.kind && existing.id == reference.id;
                }
            )) {
            context.references.push_back({reference.kind, reference.id});
        }
        if (reference.kind == "operation") {
            context.sourceRanges.insert(
                context.sourceRanges.end(),
                reference.sourceRanges.begin(), reference.sourceRanges.end()
            );
        }
    }

    template <typename References>
    static void resolveUnsigned(
        Context& context,
        const std::optional<std::string_view>& encoded,
        const References& references
    ) {
        if (!encoded || !context.resolvable) return;
        const auto reference = references.find(parseMarkupUnsigned(*encoded));
        if (reference == references.end()) {
            context.resolvable = false;
            return;
        }
        addReference(context, reference->second);
    }

    void advancePosition(std::string_view content) {
        for (const unsigned char byte : content) {
            if (byte == '\n') {
                if (line == std::numeric_limits<std::uint32_t>::max()) {
                    fail("native-provider-pseudocode-token-position-invalid");
                }
                ++line;
                column = 1U;
            } else if (byte != '\r' && (byte & 0xc0U) != 0x80U) {
                if (column == std::numeric_limits<std::uint32_t>::max()) {
                    fail("native-provider-pseudocode-token-position-invalid");
                }
                ++column;
            }
        }
    }

    void appendToken(Frame& frame) {
        if (frame.content.empty()) return;
        requireNativeText(frame.content, 65536U, false);
        if (tokenBudgetExhausted) return;
        if (!frame.context.resolvable || frame.context.sourceRanges.empty()) return;

        std::sort(
            frame.context.references.begin(), frame.context.references.end(),
            [](const auto& lhs, const auto& rhs) {
                return std::tie(lhs.kind, lhs.id) < std::tie(rhs.kind, rhs.id);
            }
        );
        std::sort(
            frame.context.sourceRanges.begin(), frame.context.sourceRanges.end(),
            [](const auto& lhs, const auto& rhs) {
                return std::tie(lhs.imageId, lhs.startAddress, lhs.endAddressExclusive) <
                    std::tie(rhs.imageId, rhs.startAddress, rhs.endAddressExclusive);
            }
        );
        frame.context.sourceRanges.erase(
            std::unique(frame.context.sourceRanges.begin(), frame.context.sourceRanges.end()),
            frame.context.sourceRanges.end()
        );
        PseudocodeTokenRecord token{
            .id = "token:" + hex16(ordinal++),
            .text = frame.content,
            .kind = canonicalPseudocodeTokenKind(frame.name, frame.content, frame.color),
            .line = frame.startLine,
            .column = frame.startColumn,
            .sourceRanges = std::move(frame.context.sourceRanges),
            .entityReferences = std::move(frame.context.references),
        };
        if (accounted.addToken(token) > tokenOutputLimit) {
            // Keep a genuine prefix. Continue parsing the entire XML document
            // so malformed markup cannot be hidden by a presentation budget.
            tokenBudgetExhausted = true;
            return;
        }
        result.tokens.push_back(std::move(token));
    }

    const AnalysisRequestView& request;
    const BudgetGuard& budget;
    const NativeMarkupIndex& index;
    StructuredResult& result;
    std::vector<Frame> frames;
    std::string error;
    StructuredResultSizeAccumulator accounted;
    std::size_t tokenOutputLimit = 0U;
    bool tokenBudgetExhausted = false;
    std::uint32_t line = 1U;
    std::uint32_t column = 1U;
    std::uint64_t ordinal = 0U;
    bool documentStarted = false;
    bool documentEnded = false;
    bool rootSeen = false;
};

void attachPseudocodeTokens(
    const AnalysisRequestView& request,
    ghidra::Funcdata& function,
    GhidraArchitecture& architecture,
    const BudgetGuard& budget,
    const NativeMarkupIndex& index,
    StructuredResult& result
) {
    budget.checkpoint();
    if (architecture.print == nullptr) {
        throw ContractError("native-provider-print-language-unavailable");
    }
    const auto capacity = std::min(
        request.budgets.maxOutputBytes,
        kMaximumPseudocodeText * 4U
    );
    if (capacity == 0U) throw ContractError("native-provider-output-budget-exceeded");

    detail::BoundedUTF8StreamBuffer buffer(capacity);
    std::ostream output(&buffer);
    auto& printer = *architecture.print;
    PrintOutputStreamGuard streamGuard(printer, printer.getOutputStream());
    printer.setOutputStream(&output);
    printer.setMarkup(true);
    printer.setPackedOutput(false);
    printer.setMaxLineSize(120);
    printer.clear();
    const auto sourceRange = SourceRange{request.image.imageId, request.function.entryAddress,
        request.function.codeRanges.empty()
            ? request.function.endAddressExclusive
            : request.function.codeRanges.front().endAddressExclusive};
    // Token metadata is optional presentation: when it cannot fit, the row keeps its
    // complete graph and plain document instead of being refused.
    const auto omitTokens = [&] {
        result.tokens.clear();
        result.warnings.push_back({
            .code = std::string(kTokenMetadataOmittedWarning),
            .severity = "warning",
            .message = "Native token metadata did not fit the output bounds; the instruction and SSA graph and the "
                       "pseudocode text remain.",
            .sourceRanges = {sourceRange},
        });
        canonicalizeStructuredResult(result);
        validateStructuredResult(request, result);
    };
    printer.docFunction(&function);
    output.flush();
    if (!output.good() || buffer.overflowed()) {
        omitTokens();
        budget.checkpoint();
        return;
    }
    budget.checkpoint();

    const auto markup = buffer.text();
    if (markup.empty()) throw ContractError("native-provider-pseudocode-markup-output-empty");
    std::istringstream input(markup);
    PseudocodeMarkupPositionHandler positionHandler(request, budget, index, result);
    ghidra::int4 parseStatus = -1;
    try {
        parseStatus = ghidra::xml_parse(input, &positionHandler);
    } catch (const ContractError&) {
        throw;
    } catch (...) {
        throw ContractError("native-provider-pseudocode-markup-parse-invalid");
    }
    if (parseStatus != 0 || !positionHandler.isComplete()) {
        throw ContractError("native-provider-pseudocode-markup-parse-invalid");
    }
    const auto sizeCheckpoint = [&budget] { budget.checkpoint(); };
    if (result.tokens.empty()) {
        if (!positionHandler.metadataTruncated()) {
            throw ContractError("native-provider-pseudocode-token-output-empty");
        }
        omitTokens();
        budget.checkpoint();
        return;
    }
    if (positionHandler.metadataTruncated()) {
        result.warnings.push_back({
            .code = "native-pseudocode-token-metadata-truncated",
            .severity = "warning",
            .message = "Native token metadata was bounded; the instruction and SSA graph remains complete.",
            .sourceRanges = {{request.image.imageId, request.function.entryAddress,
                request.function.codeRanges.empty()
                    ? request.function.endAddressExclusive
                    : request.function.codeRanges.front().endAddressExclusive}},
        });
    }
    canonicalizeStructuredResult(result);
    validateStructuredResult(request, result);
    if (structuredResultEncodedSizeUpperBound(result, sizeCheckpoint) >
        request.budgets.maxOutputBytes) {
        throw ContractError("native-provider-output-budget-exceeded");
    }
    budget.checkpoint();
}

void attachPseudocodeDocument(
    const AnalysisRequestView& request,
    ghidra::Funcdata& function,
    GhidraArchitecture& architecture,
    const BudgetGuard& budget,
    StructuredResult& result
) {
    budget.checkpoint();
    if (architecture.print == nullptr) {
        throw ContractError("native-provider-print-language-unavailable");
    }

    const auto sizeCheckpoint = [&budget] { budget.checkpoint(); };
    const auto baseSize = structuredResultEncodedSizeUpperBound(result, sizeCheckpoint);
    StructuredResult accountingProbe;
    const auto documentAbsentSize = structuredResultEncodedSizeUpperBound(
        accountingProbe, sizeCheckpoint
    );
    accountingProbe.pseudocodeDocument = PseudocodeDocumentRecord{
        .text = "x",
        .language = "c",
        .isComplete = true,
        .isTruncated = false,
    };
    const auto oneByteDocumentSize = structuredResultEncodedSizeUpperBound(
        accountingProbe, sizeCheckpoint
    );
    // The probe's one ASCII byte is charged one byte; retained text may be
    // non-ASCII, so capacity divides by the per-byte maximum below.
    if (oneByteDocumentSize < documentAbsentSize ||
        oneByteDocumentSize - documentAbsentSize < 1U) {
        throw ContractError("native-provider-output-budget-accounting-mismatch");
    }
    const auto fixedDocumentOverhead = oneByteDocumentSize - documentAbsentSize - 1U;
    if (baseSize > request.budgets.maxOutputBytes ||
        fixedDocumentOverhead >= request.budgets.maxOutputBytes - baseSize) {
        throw ContractError("native-provider-output-budget-exceeded");
    }
    const auto availableEncodedBytes =
        request.budgets.maxOutputBytes - baseSize - fixedDocumentOverhead;
    // ASCII text is charged one byte per byte, so the buffer may hold every
    // available byte; non-ASCII text is cut below to its own charge.
    const auto capacity = std::min(availableEncodedBytes, kMaximumPseudocodeText);
    if (capacity == 0U) {
        throw ContractError("native-provider-output-budget-exceeded");
    }

    detail::BoundedUTF8StreamBuffer buffer(capacity);
    std::ostream output(&buffer);
    auto& printer = *architecture.print;
    PrintOutputStreamGuard streamGuard(printer, printer.getOutputStream());
    printer.setOutputStream(&output);
    printer.setMaxLineSize(120);
    printer.setMarkup(false);
    printer.clear();
    printer.docFunction(&function);
    output.flush();
    if (!output.good()) {
        throw ContractError("native-provider-pseudocode-output-failed");
    }
    budget.checkpoint();

    auto text = buffer.text();
    bool truncated = buffer.overflowed();
    const bool ascii = std::all_of(text.begin(), text.end(), [](char byte) {
        return static_cast<unsigned char>(byte) < 0x80U;
    });
    if (!ascii && text.size() > availableEncodedBytes / kMaximumEncodedBytesPerTextByte) {
        auto length = availableEncodedBytes / kMaximumEncodedBytesPerTextByte;
        while (length > 0U && (static_cast<unsigned char>(text[length]) & 0xC0U) == 0x80U) {
            --length;
        }
        text.resize(length);
        truncated = true;
    }
    if (text.empty()) {
        throw ContractError("native-provider-pseudocode-output-empty");
    }
    result.pseudocodeDocument = PseudocodeDocumentRecord{
        .text = std::move(text),
        .language = "c",
        .isComplete = !truncated,
        .isTruncated = truncated,
    };
    canonicalizeStructuredResult(result);
    validateStructuredResult(request, result);
    if (structuredResultEncodedSizeUpperBound(result, sizeCheckpoint) >
        request.budgets.maxOutputBytes) {
        throw ContractError("native-provider-output-budget-exceeded");
    }
    budget.checkpoint();
}

[[nodiscard]] GhidraPackageAttestationExpectations buildExpectations(
    const GhidraBackendConfiguration& configuration
) {
    namespace identity = detail::build_identity;
    if (identity::kRelocatableMaterialization) {
        const std::filesystem::path packageRoot(configuration.packageRoot);
        if (!packageRoot.is_absolute() || packageRoot.empty() ||
            packageRoot.lexically_normal() != packageRoot ||
            packageRoot.filename() != identity::kPackageRelativeRoot) {
            throw detail::GhidraPackageAttestationError(
                "package-attestation-configuration-mismatch"
            );
        }
        const auto materializationRoot = packageRoot.parent_path();
        const auto globalSpecRoot = packageRoot / identity::kGlobalSpecRelativeRoot;
        const auto processorSpecRoot = packageRoot / identity::kProcessorSpecRelativeRoot;
        if (materializationRoot.empty() ||
            std::filesystem::path(configuration.processorSpecRoot) != processorSpecRoot) {
            throw detail::GhidraPackageAttestationError(
                "package-attestation-configuration-mismatch"
            );
        }
        return {
            .materializationRoot = materializationRoot,
            .materializationManifestSha256 = std::string(identity::kManifestSha256),
            .packageTreeSha256 = std::string(identity::kClosedTreeSha256),
            .packageRoot = packageRoot,
            .globalProcessorSpecRoot = globalSpecRoot,
            .processorSpecRoot = processorSpecRoot,
        };
    }
    return {
        .materializationRoot = std::string(identity::kMaterializationRoot),
        .materializationManifestSha256 = std::string(identity::kManifestSha256),
        .packageTreeSha256 = std::string(identity::kClosedTreeSha256),
        .packageRoot = std::string(identity::kPackageRoot),
        .globalProcessorSpecRoot = std::string(identity::kGlobalSpecRoot),
        .processorSpecRoot = std::string(identity::kProcessorSpecRoot),
    };
}

class ReadinessCheckpoint final : public detail::GhidraRequestCheckpoint {
public:
    void checkpoint() const override {}
};

[[nodiscard]] TargetProfile sealedAppleRuntimeProfile(
    const GhidraPackageAttestation& attestation
) {
    return normalizeAppleMachOTarget(
        0x0100'000cU,
        0x8000'0002U,
        attestation.packageTreeSha256,
        1U
    );
}

[[nodiscard]] AnalysisRequestView makeReadinessProbeRequest() {
    constexpr Address entryAddress = 0x1000U;
    constexpr std::array<std::uint8_t, 4> nop = {0x1f, 0x20, 0x03, 0xd5};
    std::vector<std::uint8_t> bytes = {0xc0, 0x03, 0x5f, 0xd6};
    while (bytes.size() < 64U) {
        bytes.insert(bytes.end(), nop.begin(), nop.end());
    }
    return AnalysisRequestView(
        "request.native-apple-profile-readiness",
        std::string(64U, '0'),
        std::string(kAppleLanguageId),
        std::string(kAppleCompilerSpecId),
        ImageIdentity{
            "image.native-apple-profile-readiness",
            "00000000-0000-0000-0000-000000000000",
            entryAddress,
        },
        FunctionIdentity{
            "function.native-apple-profile-readiness",
            "_macscopeNativeProfileReadiness",
            entryAddress,
            entryAddress + 4U,
            {},
        },
        ByteProvider({
            MemoryRegion{
                "__text",
                entryAddress,
                "r-x",
                bytes,
                std::move(bytes),
                {},
            },
        }),
        SymbolProvider({}),
        TypeHintProvider({}),
        AnalysisBudgets{
            .maxCodeBytes = 64U,
            .maxInstructions = 1U,
            .maxOperations = 1U,
            .maxOutputBytes = 4'096U,
            .maxWallTimeMilliseconds = 1'000U,
        }
    );
}

void requireSelectedAppleProfile(
    const TargetProfile& selectedProfile,
    detail::GhidraReadinessFault fault
) {
    constexpr std::array<TargetContextValue, 4> expectedContext = {{
        TargetContextValue{"ShowPAC", 1},
        TargetContextValue{"PAC_clobber", 1},
        TargetContextValue{"ShowBTI", 0},
        TargetContextValue{"ShowMemTag", 0},
    }};
    if (fault == detail::GhidraReadinessFault::unexpectedSelectedProfile ||
        selectedProfile.profileId != kAppleTargetProfileId ||
        selectedProfile.languageId != kAppleLanguageId ||
        selectedProfile.compilerSpecId != kAppleCompilerSpecId ||
        selectedProfile.contextProfileSha256 != kAppleContextProfileSha256 ||
        selectedProfile.context != expectedContext) {
        throw ContractError("native-apple-profile-identity-mismatch");
    }
}

void requirePacUserOps(
    const GhidraArchitecture& architecture,
    detail::GhidraReadinessFault fault
) {
    architecture.requireProfileHookComplete();
    if (architecture.translate == nullptr) {
        throw ContractError("native-apple-profile-translator-unavailable");
    }
    std::vector<std::string> userOps;
    architecture.translate->getUserOpNames(userOps);
    if (fault == detail::GhidraReadinessFault::missingRequiredUserOp) {
        const auto found = std::find(userOps.begin(), userOps.end(), kRequiredPacUserOps.front());
        if (found != userOps.end()) {
            userOps.erase(found);
        }
    } else if (fault == detail::GhidraReadinessFault::duplicateRequiredUserOp) {
        userOps.emplace_back(kRequiredPacUserOps.front());
    }
    for (const auto required : kRequiredPacUserOps) {
        if (std::count(userOps.begin(), userOps.end(), required) != 1) {
            throw ContractError("native-apple-profile-userops-invalid");
        }
    }
}

[[nodiscard]] PreparedGhidraRuntimeIdentity prepareRuntimeIdentity(
    const GhidraPackageAttestation& attestation,
    const GhidraRuntimeLease& lease,
    const TargetProfile& selectedProfile,
    detail::GhidraReadinessFault fault
) {
    requireSelectedAppleProfile(selectedProfile, fault);
    detail::revalidateGhidraPackageDirectories(attestation);

    GhidraExecutionLock executionLock;
    ReadinessCheckpoint checkpoint;
    const CancellationToken cancellation;
    auto request = makeReadinessProbeRequest();
    std::ostringstream diagnosticStream;
    ghidra::DocumentStorage documentStorage;
    GhidraArchitecture architecture(
        request,
        cancellation,
        checkpoint,
        executionLock,
        lease.identity().targetId(),
        diagnosticStream,
        fault
    );
    if (fault == detail::GhidraReadinessFault::decodeBeforeHook) {
        architecture.requireProfileHookComplete();
    }
    architecture.initialize(documentStorage);
    architecture.requireProfileHookComplete();
    if (architecture.appliedContextProfile() != selectedProfile.context) {
        throw ContractError("native-apple-profile-context-mismatch");
    }
    requirePacUserOps(architecture, fault);

    namespace identity = detail::build_identity;
    return PreparedGhidraRuntimeIdentity{
        .backendId = std::string(kBackendId),
        .engineVersion = std::string(identity::kEngineVersion),
        .engineRevision = std::string(identity::kEngineRevision),
        .wrapperVersion = std::string(identity::kWrapperVersion),
        .wrapperRevision = std::string(identity::kWrapperRevision),
        .packageManifestSha256 = attestation.materializationManifestSha256,
        .packageTreeSha256 = attestation.packageTreeSha256,
        .languageId = selectedProfile.languageId,
        .compilerSpecId = selectedProfile.compilerSpecId,
        .targetProfileId = selectedProfile.profileId,
        .contextProfileSha256 = selectedProfile.contextProfileSha256,
    };
}

[[nodiscard]] BackendAvailability buildAvailability(
    PreparedGhidraRuntimeIdentity runtimeIdentity
) {
    namespace identity = detail::build_identity;
    if (identity::kGhidraVersion != "12.1.2" ||
        identity::kGhidraGitRevision != "c0f584bf229fffba61b36431f3ce30c0c3e4e682" ||
        identity::kWrapperVersion != "dcp05c-v1") {
        throw ContractError("native-provider-build-identity-mismatch");
    }
    BackendAvailability availability;
    availability.available = true;
    availability.identity.backendId = kBackendId;
    availability.identity.ghidraVersion = identity::kGhidraVersion;
    availability.identity.ghidraGitRevision = identity::kGhidraGitRevision;
    availability.identity.wrapperVersion = identity::kWrapperVersion;
    availability.identity.wrapperGitRevision = identity::kWrapperGitRevision;
    availability.capabilities.nativeDecompilerHeritage = true;
    availability.capabilities.completeRegisterSsa = true;
    availability.capabilities.recoveredVariables = true;
    availability.capabilities.recoveredTypes = true;
    availability.capabilities.imageQualifiedSourceRanges = true;
    availability.capabilities.structuredControlFlow = true;
    availability.capabilities.tokenizedPseudocode = true;
    availability.runtimeIdentity = std::move(runtimeIdentity);
    validateBackendAvailability(availability);
    return availability;
}

class GhidraNativeStructuredProvider final : public NativeStructuredProvider {
public:
    explicit GhidraNativeStructuredProvider(GhidraBackendConfiguration configuration)
        : configuration_(std::move(configuration)) {
        detail::validateGhidraLanguageAndCompiler(
            configuration_.languageId, configuration_.compilerSpecId
        );
        attestation_ = detail::attestGhidraPackage(
            configuration_, buildExpectations(configuration_)
        );
        lease_ = std::make_unique<GhidraRuntimeLease>(GhidraRuntimeIdentity{
            .materializationRoot = attestation_.materializationRoot.string(),
            .manifestSha256 = attestation_.materializationManifestSha256,
            .closedTreeSha256 = attestation_.packageTreeSha256,
            .packageRoot = attestation_.packageRoot.string(),
            .globalSpecRoot = attestation_.globalProcessorSpecRoot.string(),
            .processorSpecRoot = attestation_.processorSpecRoot.string(),
            .languageId = configuration_.languageId,
            .compilerSpecId = configuration_.compilerSpecId,
        });
        const auto selectedProfile = sealedAppleRuntimeProfile(attestation_);
        availability_ = buildAvailability(prepareRuntimeIdentity(
            attestation_,
            *lease_,
            selectedProfile,
            detail::GhidraReadinessFault::none
        ));
    }

    [[nodiscard]] BackendAvailability availability() const override { return availability_; }

    [[nodiscard]] StructuredResult produce(
        const AnalysisRequestView& request,
        const CancellationToken& cancellation
    ) override {
        cancellation.throwIfCancelled();
        if (request.languageId != configuration_.languageId ||
            request.compilerSpecId != configuration_.compilerSpecId) {
            throw ContractError("native-provider-request-configuration-mismatch");
        }
        BudgetGuard budget(request, cancellation);
        budget.checkpoint();

        return produceWithFullActions(request, cancellation, budget);
    }

private:
    [[nodiscard]] StructuredResult produceWithFullActions(
        const AnalysisRequestView& request,
        const CancellationToken& cancellation,
        BudgetGuard& budget
    ) {
        try {
            GhidraExecutionLock executionLock;
            detail::revalidateGhidraPackageDirectories(attestation_);
            std::ostringstream diagnosticStream;
            ghidra::DocumentStorage documentStorage;
            struct ArchitectureLifecycle final {
                std::shared_ptr<GhidraProviderObserver> observer;
                ~ArchitectureLifecycle() {
                    if (observer && observer->architectureDestroyed) {
                        observer->architectureDestroyed();
                    }
                }
            } lifecycle{configuration_.observer};
            GhidraArchitecture architecture(
                request,
                cancellation,
                budget,
                executionLock,
                lease_->identity().targetId(),
                diagnosticStream,
                detail::GhidraReadinessFault::none
            );
            if (configuration_.observer && configuration_.observer->architectureConstructed) {
                configuration_.observer->architectureConstructed();
            }
            architecture.initialize(documentStorage);
            architecture.requireProfileHookComplete();
            auto authoredAuthority = prepareAuthoredAuthority(request, cancellation);
            AuthoredQualifierRenderNames qualifierRenderNames;
            installAuthoredTypeCatalog(
                request, architecture, cancellation, configuration_.observer, qualifierRenderNames
            );
            architecture.flowoptions |= ghidra::FlowInfo::error_outofbounds |
                ghidra::FlowInfo::error_unimplemented |
                ghidra::FlowInfo::error_reinterpreted |
                ghidra::FlowInfo::error_toomanyinstructions;
            architecture.max_instructions = static_cast<ghidra::uint4>(std::min<std::size_t>(
                request.budgets.maxInstructions,
                std::numeric_limits<ghidra::uint4>::max()
            ));
            auto* codeSpace = architecture.getDefaultCodeSpace();
            if (codeSpace == nullptr) {
                throw ContractError("native-provider-code-space-unavailable");
            }
            const ghidra::Address entry(codeSpace, request.function.entryAddress);
            const ghidra::Address inclusiveEnd(
                codeSpace, request.function.endAddressExclusive - 1U
            );
            constexpr std::array<TargetContextValue, 4> requestContext = {{
                TargetContextValue{"ShowPAC", 1},
                TargetContextValue{"PAC_clobber", 1},
                TargetContextValue{"ShowBTI", 0},
                TargetContextValue{"ShowMemTag", 0},
            }};
            const auto codeRanges = request.function.codeRanges.empty()
                ? std::vector<FunctionIdentity::CodeRange>{{request.function.entryAddress, request.function.endAddressExclusive}}
                : request.function.codeRanges;
            for (const auto& codeRange : codeRanges) {
            Address address = codeRange.startAddress;
            while (address < codeRange.endAddressExclusive) {
                budget.checkpoint();
                const ghidra::Address instructionAddress(codeSpace, address);
                for (const auto& value : requestContext) {
                    architecture.context->setVariable(
                        value.name, instructionAddress, value.value
                    );
                    if (architecture.context->getVariable(value.name, instructionAddress) !=
                        value.value) {
                        throw ContractError("native-provider-request-context-mismatch");
                    }
                }
                if (codeRange.endAddressExclusive - address <= 4U) break;
                address += 4U;
            }
            }
            auto* globalScope = architecture.symboltab->getGlobalScope();
            if (globalScope == nullptr) {
                throw ContractError("native-provider-global-scope-unavailable");
            }
            installAuthoredAuthority(
                authoredAuthority,
                *globalScope,
                *codeSpace,
                cancellation,
                configuration_.observer
            );
            auto* functionSymbol = globalScope->addFunction(entry, authoredAuthority.entryFunctionName);
            if (functionSymbol == nullptr || functionSymbol->getFunction() == nullptr) {
                throw ContractError("native-provider-function-unavailable");
            }
            auto* function = functionSymbol->getFunction();
            if (configuration_.observer && configuration_.observer->authoredNameReadback) {
                configuration_.observer->authoredNameReadback(
                    request.function.entryAddress,
                    function->getName(),
                    true
                );
            }
            installAuthoredSignatureAxes(
                request, *function, *globalScope, *codeSpace, cancellation, configuration_.observer, qualifierRenderNames
            );
            installCalleeSignatureHints(
                request, *function, *globalScope, *codeSpace, cancellation, qualifierRenderNames
            );
            installAuthoredStackLocals(request, *function, cancellation, qualifierRenderNames);
            installAuthoredNonCodeObjects(
                request,
                *globalScope,
                *codeSpace,
                architecture.typeFactory(),
                *function,
                cancellation,
                configuration_.observer
            );
            cancellation.throwIfCancelled();
            authoredAuthority.complete = true;
            architecture.requireProfileHookComplete();
            if (!authoredAuthority.complete) {
                throw ContractError("authoring-input-unsupported");
            }
            // Direct BL targets, and B targets outside the function (tail calls),
            // print by the request's callable symbol instead of func_0x...; the
            // CallRecord already names them the same way (preferredCallableSymbol).
            for (const auto& codeRange : codeRanges) {
                for (Address address = codeRange.startAddress;
                     address + 4U <= codeRange.endAddressExclusive;
                     address += 4U) {
                    budget.checkpoint();
                    const auto word = request.bytes.readEffective(address, 4U);
                    const std::uint32_t encoding = static_cast<std::uint32_t>(word[0]) |
                        (static_cast<std::uint32_t>(word[1]) << 8U) |
                        (static_cast<std::uint32_t>(word[2]) << 16U) |
                        (static_cast<std::uint32_t>(word[3]) << 24U);
                    const bool isCall = (encoding & 0xfc000000U) == 0x94000000U;
                    if (!isCall && (encoding & 0xfc000000U) != 0x14000000U) continue;
                    const auto target = a64BranchTarget(address, encoding);
                    if (target >= request.function.entryAddress &&
                        target < request.function.endAddressExclusive) {
                        continue;
                    }
                    const ghidra::Address callee(codeSpace, target);
                    if (globalScope->queryFunction(callee) != nullptr) continue;
                    if (const auto name = preferredCallableSymbol(request, target); name) {
                        (void)globalScope->addFunction(callee, *name);
                    }
                }
            }
            // An unconditional A64 B whose target leaves the followed range is a
            // tail call (e.g. a 4-byte `b _target` thunk). Ghidra models it as
            // CALL + RETURN through a flow override; without one, error_outofbounds
            // refuses the whole function. Conditional branches out of range still
            // fail closed.
            for (const auto& codeRange : codeRanges) {
                for (Address address = codeRange.startAddress;
                     address + 4U <= codeRange.endAddressExclusive;
                     address += 4U) {
                    budget.checkpoint();
                    const auto word = request.bytes.readEffective(address, 4U);
                    const std::uint32_t encoding = static_cast<std::uint32_t>(word[0]) |
                        (static_cast<std::uint32_t>(word[1]) << 8U) |
                        (static_cast<std::uint32_t>(word[2]) << 16U) |
                        (static_cast<std::uint32_t>(word[3]) << 24U);
                    if ((encoding & 0xfc000000U) != 0x14000000U) continue;
                    const auto target = a64BranchTarget(address, encoding);
                    if (target >= request.function.entryAddress &&
                        target < request.function.endAddressExclusive) {
                        continue;
                    }
                    function->getOverride().insertFlowOverride(
                        ghidra::Address(codeSpace, address), ghidra::Override::CALL_RETURN
                    );
                }
            }
            // Admit an epilogue BR only immediately after a post-index SP restore:
            // LDP X29, X30, [SP], #imm or LDR X30, [SP], #imm, optionally followed by
            // exactly AUTIASP/AUTIBSP. No direct branch in any function code range
            // may enter after that restore through the BR (B/conditional/CB/TB, not BL).
            // Other X30 loads and intervening instructions do not prove a tail call.
            // A `br x16/x17` is a tail call only as a veneer/stub: the whole function is
            // adrp / ldr / add into that same register, then the branch. Elsewhere x16/x17
            // are ordinary intra-procedure registers and need the epilogue proof (#727).
            for (const auto& codeRange : codeRanges) {
                for (Address address = codeRange.startAddress;
                     address + 4U <= codeRange.endAddressExclusive;
                     address += 4U) {
                    budget.checkpoint();
                    const auto word = [&](Address at) {
                        const auto bytes = request.bytes.readEffective(at, 4U);
                        return static_cast<std::uint32_t>(bytes[0]) | (static_cast<std::uint32_t>(bytes[1]) << 8U) |
                            (static_cast<std::uint32_t>(bytes[2]) << 16U) | (static_cast<std::uint32_t>(bytes[3]) << 24U);
                    };
                    const auto encoding = word(address);
                    if ((encoding & 0xfffffc1fU) != 0xd61f0000U) continue; // BR Xn
                    const auto target = (encoding >> 5U) & 31U;
                    bool tailCall = false;
                    if ((target == 16U || target == 17U) && address >= request.function.entryAddress + 4U &&
                        address + 4U == request.function.endAddressExclusive &&
                        address - request.function.entryAddress <= 12U) {
                        tailCall = true;
                        for (Address at = request.function.entryAddress; tailCall && at < address; at += 4U) {
                            const auto prior = word(at);
                            const bool adrp = (prior & 0x9f000000U) == 0x90000000U && (prior & 31U) == target;
                            const bool loadOrAdd = ((prior & 0xffc00000U) == 0xf9400000U ||
                                                    (prior & 0xff800000U) == 0x91000000U) &&
                                (prior & 31U) == target && ((prior >> 5U) & 31U) == target;
                            tailCall = at == request.function.entryAddress ? adrp : loadOrAdd;
                        }
                    }
                    if (!tailCall && address - codeRange.startAddress >= 4U) {
                        const auto isFrameRestore = [](std::uint32_t prior) {
                            const bool pair = (prior & 0xffc00000U) == 0xa8c00000U &&
                                (prior & 31U) == 29U && ((prior >> 10U) & 31U) == 30U;
                            const bool single = (prior & 0xffe00c00U) == 0xf8400400U &&
                                (prior & 31U) == 30U;
                            return (pair || single) && ((prior >> 5U) & 31U) == 31U;
                        };
                        std::optional<Address> restore;
                        const auto prior = word(address - 4U);
                        if (isFrameRestore(prior)) {
                            restore = address - 4U;
                        } else if ((prior == 0xd50323bfU || prior == 0xd50323ffU) &&
                                   address - codeRange.startAddress >= 8U &&
                                   isFrameRestore(word(address - 8U))) {
                            restore = address - 8U;
                        }
                        if (restore) {
                            tailCall = true;
                            for (const auto& incomingRange : codeRanges) {
                                if (!tailCall) break;
                                for (Address at = incomingRange.startAddress;
                                     at + 4U <= incomingRange.endAddressExclusive; at += 4U) {
                                    budget.checkpoint();
                                    const auto branch = word(at);
                                    Address destination;
                                    if ((branch & 0xfc000000U) == 0x14000000U) { // B, not BL
                                        destination = a64BranchTarget(at, branch);
                                    } else {
                                        unsigned immediateBits;
                                        if ((branch & 0xff000010U) == 0x54000000U ||
                                            (branch & 0x7e000000U) == 0x34000000U) { // B.cond / CBZ / CBNZ
                                            immediateBits = 19U;
                                        } else if ((branch & 0x7e000000U) == 0x36000000U) { // TBZ / TBNZ
                                            immediateBits = 14U;
                                        } else {
                                            continue;
                                        }
                                        const auto immediateMask = (1U << immediateBits) - 1U;
                                        auto displacement = static_cast<std::uint64_t>(
                                            (branch >> 5U) & immediateMask) << 2U;
                                        // Sign-extend the scaled immediate without signed overflow.
                                        if ((displacement & (1ULL << (immediateBits + 1U))) != 0U) {
                                            displacement |= ~((1ULL << (immediateBits + 2U)) - 1ULL);
                                        }
                                        destination = static_cast<Address>(
                                            static_cast<std::uint64_t>(at) + displacement);
                                    }
                                    if (destination > *restore && destination <= address) {
                                        tailCall = false;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if (tailCall) {
                        function->getOverride().insertFlowOverride(
                            ghidra::Address(codeSpace, address), ghidra::Override::CALL_RETURN
                        );
                    }
                }
            }
            // A function whose last instruction is a direct BL (e.g. a final
            // `bl ___stack_chk_fail` or `bl _exit`) would otherwise fall through
            // into the next function, which error_outofbounds refuses. Flow stops at
            // THAT call only (CALL_RETURN override on the final instruction): the
            // callee prototype is never marked no-return, so earlier calls to the same
            // callee keep their continuations and an authored `.returns` stands (#674).
            if (request.function.endAddressExclusive - request.function.entryAddress >= 4U) {
                const Address last = request.function.endAddressExclusive - 4U;
                const auto word = request.bytes.readEffective(last, 4U);
                const std::uint32_t encoding = static_cast<std::uint32_t>(word[0]) |
                    (static_cast<std::uint32_t>(word[1]) << 8U) |
                    (static_cast<std::uint32_t>(word[2]) << 16U) |
                    (static_cast<std::uint32_t>(word[3]) << 24U);
                if ((encoding & 0xfc000000U) == 0x94000000U) {
                    function->getOverride().insertFlowOverride(
                        ghidra::Address(codeSpace, last), ghidra::Override::CALL_RETURN
                    );
                }
            }
            if (configuration_.observer && configuration_.observer->followFlowEntered) {
                configuration_.observer->followFlowEntered();
            }
            if (configuration_.observer && configuration_.observer->followFlowRange) {
                configuration_.observer->followFlowRange(
                    request.function.entryAddress,
                    request.function.endAddressExclusive
                );
            }
            try {
                function->followFlow(entry, inclusiveEnd);
            } catch (...) {
                architecture.throwIfUnavailableEffectiveByteRead();
                throw;
            }
            architecture.throwIfUnavailableEffectiveByteRead();
            budget.checkpoint();
            const std::string actionName = "decompile";
            auto* action = architecture.allacts.setCurrent(actionName);
            if (action == nullptr || architecture.allacts.getCurrentName() != actionName) {
                throw ContractError("native-provider-decompile-action-unavailable");
            }
            if (configuration_.observer && configuration_.observer->decompileActionEntered) {
                configuration_.observer->decompileActionEntered();
            }
            action->reset(*function);
            architecture.requireProfileHookComplete();
            ghidra::int4 actionResult = -1;
            try {
                actionResult = action->perform(*function);
            } catch (...) {
                architecture.throwIfUnavailableEffectiveByteRead();
                throw;
            }
            architecture.throwIfUnavailableEffectiveByteRead();
            budget.checkpoint();
            if (actionResult < 0 || !function->isProcComplete() ||
                function->hasUnimplemented() || function->hasBadData()) {
                throw ContractError("native-provider-decompile-incomplete");
            }
            applyAuthoredRegisterNames(request, *function);
            if (std::any_of(request.authoredInputs.signatures.begin(), request.authoredInputs.signatures.end(),
                    [&](const AuthoredSignature& signature) {
                        return signature.functionAddress == request.function.entryAddress;
                    }) && configuration_.observer &&
                configuration_.observer->authoredSignatureReadbackAfterAnalysis) {
                configuration_.observer->authoredSignatureReadbackAfterAnalysis(authoredSignatureReadback(
                    function->getFuncProto(), *function->getArch()->translate, true));
            }
            // Keep analysis and graph identities intact until export is finished.
            // Both printer paths then receive the same C qualifier spellings;
            // setName preserves native IDs and qualified typedef dependencies.
            const auto applyQualifierRenderNames = [&] {
                for (const auto& [type, displayName] : qualifierRenderNames) {
                    budget.checkpoint();
                    architecture.typeFactory().setName(type, displayName);
                }
            };
            if (request.documentOnly) {
                // Whole-image export needs the text only: skip the structured graph
                // (operations, SSA, types, tokens), whose encoding dominates large replies.
                StructuredResult document;
                document.requestId = request.requestId;
                document.requestSha256 = request.requestSha256;
                document.image = request.image;
                document.function = request.function;
                document.warnings.push_back({
                    .code = "native-structure-omitted",
                    .severity = "warning",
                    .message = "Document-only request: the structured graph was not exported.",
                    .sourceRanges = {{request.image.imageId, request.function.entryAddress,
                        request.function.codeRanges.empty()
                            ? request.function.endAddressExclusive
                            : request.function.codeRanges.front().endAddressExclusive}},
                });
                applyQualifierRenderNames();
                attachPseudocodeDocument(request, *function, architecture, budget, document);
                architecture.throwIfUnavailableEffectiveByteRead();
                return document;
            }
            StructuredResult result;
            const char* exportStage = "structured";
            try {
                auto nativeExport = exportStructuredResult(
                    request, *function, architecture, budget
                );
                result = std::move(nativeExport.result);
                applyQualifierRenderNames();
                exportStage = "tokens";
                attachPseudocodeTokens(
                    request, *function, architecture, budget, nativeExport.markup, result
                );
                exportStage = "document";
                attachPseudocodeDocument(request, *function, architecture, budget, result);
            } catch (const ContractError& error) {
#if defined(__APPLE__)
                if (std::string_view(error.what()) == "native-provider-output-budget-exceeded") {
                    os_log_error(OS_LOG_DEFAULT,
                        "MacScope native output-budget export=%{public}s operations=%{public}llu varnodes=%{public}llu ssa=%{public}llu tokens=%{public}llu",
                        exportStage, static_cast<unsigned long long>(result.operations.size()),
                        static_cast<unsigned long long>(result.varnodes.size()),
                        static_cast<unsigned long long>(result.ssaValues.size()),
                        static_cast<unsigned long long>(result.tokens.size()));
                }
#else
                static_cast<void>(exportStage);
#endif
                architecture.throwIfUnavailableEffectiveByteRead();
                throw;
            } catch (...) {
                architecture.throwIfUnavailableEffectiveByteRead();
                throw;
            }
            architecture.throwIfUnavailableEffectiveByteRead();
            return result;
        } catch (const ContractError&) {
            throw;
        } catch (const detail::GhidraPackageAttestationError& error) {
            throw ContractError(error.reasonCode());
        } catch (const ghidra::UnimplError&) {
            // error_unimplemented is set above: a SLEIGH constructor whose
            // semantics are `unimpl` aborts flow here. Keep it distinguishable
            // from other native faults so decode-only constructors are visible.
            throw ContractError("native-provider-unimplemented-instruction");
        } catch (const ghidra::BadDataError&) {
            throw ContractError("native-provider-bad-instruction-data");
        } catch (const ghidra::DataUnavailError&) {
            // The loader latch still takes precedence at the phase boundaries.
            // This handles other native reads without exposing native text.
            throw ContractError("native-provider-data-unavailable");
        } catch (const ghidra::DuplicateFunctionError&) {
            throw ContractError("native-provider-duplicate-function");
        } catch (const ghidra::RecovError&) {
            // Recoverable in Ghidra does not mean a retry is safe here.
            throw ContractError("native-provider-recoverable-analysis-error");
        } catch (const ghidra::ParseError&) {
            throw ContractError("native-provider-parse-error");
        } catch (const ghidra::SleighError&) {
            throw ContractError("native-provider-sleigh-error");
        } catch (const ghidra::ParamUnassignedError&) {
            throw ContractError("native-provider-parameter-assignment-error");
        } catch (const ghidra::EvaluationError&) {
            throw ContractError("native-provider-evaluation-error");
        } catch (const ghidra::JumptableThunkError&) {
            // Normal recovery consumes this internally. Preserve the class if
            // a future/native path lets it escape, without inferring a tail call.
            throw ContractError("native-provider-jumptable-thunk-error");
        } catch (const ghidra::LowlevelError& error) {
            if (error.explain == "Flow exceeded maximum allowable instructions") {
                throw ContractError("native-provider-instruction-budget-exceeded");
            }
            throw ContractError("native-provider-native-error");
        } catch (const ghidra::DecoderError&) {
            throw ContractError("native-provider-decoder-error");
        } catch (const std::bad_alloc&) {
            throw ContractError("native-provider-allocation-failed");
        } catch (const std::exception&) {
            throw ContractError("native-provider-execution-error");
        } catch (...) {
            throw ContractError("native-provider-unknown-error");
        }
    }

    GhidraBackendConfiguration configuration_;
    BackendAvailability availability_;
    GhidraPackageAttestation attestation_;
    std::unique_ptr<GhidraRuntimeLease> lease_;
};

} // namespace

namespace detail {

PreparedGhidraRuntimeIdentity prepareGhidraRuntimeIdentityForTesting(
    const GhidraBackendConfiguration& configuration,
    const TargetProfile& selectedProfile,
    GhidraReadinessFault fault
) {
    validateGhidraLanguageAndCompiler(
        configuration.languageId,
        configuration.compilerSpecId
    );
    try {
        auto attestation = attestGhidraPackage(
            configuration,
            buildExpectations(configuration)
        );
        GhidraRuntimeLease lease(GhidraRuntimeIdentity{
            .materializationRoot = attestation.materializationRoot.string(),
            .manifestSha256 = attestation.materializationManifestSha256,
            .closedTreeSha256 = attestation.packageTreeSha256,
            .packageRoot = attestation.packageRoot.string(),
            .globalSpecRoot = attestation.globalProcessorSpecRoot.string(),
            .processorSpecRoot = attestation.processorSpecRoot.string(),
            .languageId = configuration.languageId,
            .compilerSpecId = configuration.compilerSpecId,
        });
        return prepareRuntimeIdentity(attestation, lease, selectedProfile, fault);
    } catch (const GhidraPackageAttestationError& error) {
        throw ContractError(error.reasonCode());
    }
}

} // namespace detail

GhidraBackendConfiguration makeGhidraBackendConfigurationForMaterialization(
    std::string materializationRoot,
    std::string languageId,
    std::string compilerSpecId
) {
    namespace identity = detail::build_identity;
    const std::filesystem::path root(std::move(materializationRoot));
    if (!root.is_absolute() || root.empty() || root.lexically_normal() != root ||
        root == root.root_path()) {
        throw ContractError("native-provider-materialization-root-invalid");
    }
    const auto packageRoot = root / identity::kPackageRelativeRoot;
    return {
        .packageRoot = packageRoot.string(),
        .packageManifestSha256 = std::string(identity::kManifestSha256),
        .processorSpecRoot =
            (packageRoot / identity::kProcessorSpecRelativeRoot).string(),
        .languageId = std::move(languageId),
        .compilerSpecId = std::move(compilerSpecId),
    };
}

std::unique_ptr<NativeStructuredProvider> makeGhidraProvider(
    GhidraBackendConfiguration configuration
) {
    try {
        return std::make_unique<GhidraNativeStructuredProvider>(std::move(configuration));
    } catch (const detail::GhidraPackageAttestationError& error) {
        throw ContractError(error.reasonCode());
    }
}

} // namespace macscope::native_decompiler
