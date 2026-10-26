#include "MacScopeNativeDecompiler/Backend.hpp"
#include "MacScopeNativeDecompiler/InputModel.hpp"
#include "MacScopeNativeDecompiler/OutputModel.hpp"
#include "TestFixtures.hpp"

#include <atomic>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <memory>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

using namespace macscope::native_decompiler;

namespace {

int failures = 0;

void check(bool condition, const char* message) {
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

template <typename Function>
void expectContractError(Function function, const char* message) {
    try {
        function();
        ++failures;
        std::cerr << "FAIL: expected ContractError: " << message << '\n';
    } catch (const ContractError&) {
    }
}

template <typename Function>
void expectAccepted(Function function, const char* message) {
    try {
        function();
    } catch (const ContractError& error) {
        ++failures;
        std::cerr << "FAIL: expected accepted contract: " << message
                  << " (" << error.what() << ")\n";
    }
}

template <typename Enumeration>
constexpr auto rawValue(Enumeration value) {
    return static_cast<std::underlying_type_t<Enumeration>>(value);
}

AuthoredType scalarType(
    AuthoredScalarKind kind = AuthoredScalarKind::unsigned8,
    std::uint8_t qualifiers = 0
) {
    return AuthoredType{
        AuthoredTypeTag::qualifiedValue,
        AuthoredQualifiedValue{
            AuthoredAtom{AuthoredAtomTag::scalar, AuthoredAtomPayload{kind}},
            qualifiers,
        },
    };
}

AuthoredType namedType(AuthoredNamedKind kind, std::string name, std::uint8_t qualifiers = 0) {
    return AuthoredType{
        AuthoredTypeTag::qualifiedValue,
        AuthoredQualifiedValue{
            AuthoredAtom{
                AuthoredAtomTag::named,
                AuthoredAtomPayload{AuthoredNamedAtom{kind, std::move(name)}},
            },
            qualifiers,
        },
    };
}

AuthoredType pointerType(
    AuthoredType pointee,
    std::vector<std::uint8_t> qualifierLevels = {0}
) {
    return AuthoredType{
        AuthoredTypeTag::dataPointer,
        AuthoredDataPointer{
            std::make_shared<AuthoredType>(std::move(pointee)),
            qualifierLevels.size(),
            std::move(qualifierLevels),
        },
    };
}

AuthoredFieldStorage valueStorage(AuthoredType type = scalarType()) {
    return AuthoredFieldStorage{
        AuthoredFieldStorageTag::value,
        AuthoredValueStorage{std::move(type)},
    };
}

AuthoredFieldStorage fixedArrayStorage(AuthoredFieldStorage element, std::uint64_t count) {
    return AuthoredFieldStorage{
        AuthoredFieldStorageTag::fixedArray,
        AuthoredFixedArrayStorage{
            std::make_shared<AuthoredFieldStorage>(std::move(element)),
            count,
        },
    };
}

AuthoredFieldStorage flexibleArrayStorage(AuthoredFieldStorage element = valueStorage()) {
    return AuthoredFieldStorage{
        AuthoredFieldStorageTag::flexibleArray,
        AuthoredFlexibleArrayStorage{
            std::make_shared<AuthoredFieldStorage>(std::move(element)),
        },
    };
}

AuthoredFieldStorage nestedStorage(std::size_t nestedLevels) {
    auto storage = valueStorage();
    for (std::size_t index = 0; index < nestedLevels; ++index) {
        storage = fixedArrayStorage(std::move(storage), 1);
    }
    return storage;
}

AuthoredRecordField recordField(std::string name, AuthoredFieldStorage storage) {
    return AuthoredRecordField{
        std::move(name),
        std::make_shared<AuthoredFieldStorage>(std::move(storage)),
        std::nullopt,
        std::nullopt,
        nullptr,
        false,
    };
}

AuthoredTypeDefinition typedefDefinition(std::string name, AuthoredFieldStorage target) {
    return AuthoredTypeDefinition{
        AuthoredTypeDefinitionKind::typedef_,
        std::move(name),
        AuthoredTypedefDefinition{
            std::make_shared<AuthoredFieldStorage>(std::move(target)),
        },
    };
}

AuthoredTypeDefinition recordDefinition(
    std::string name,
    std::vector<AuthoredRecordField> fields,
    AuthoredNamedKind kind = AuthoredNamedKind::struct_
) {
    const auto definitionKind = kind == AuthoredNamedKind::union_
        ? AuthoredTypeDefinitionKind::recordUnion
        : AuthoredTypeDefinitionKind::recordStruct;
    return AuthoredTypeDefinition{
        definitionKind,
        std::move(name),
        AuthoredRecordDefinition{
            kind,
            AuthoredLayoutRules{},
            std::move(fields),
        },
    };
}

AuthoredTypeDefinition enumerationDefinition(
    std::string name,
    std::vector<AuthoredEnumCase> cases
) {
    return AuthoredTypeDefinition{
        AuthoredTypeDefinitionKind::enumeration,
        std::move(name),
        AuthoredEnumerationDefinition{
            AuthoredEnumRepresentation::signed32,
            std::move(cases),
        },
    };
}

AuthoredSignature signature(Address address, AuthoredNoReturnState noReturnState) {
    return AuthoredSignature{
        address,
        nullptr,
        AuthoredParameterListState::unspecified,
        {},
        AuthoredVariadicState::unspecified,
        noReturnState,
    };
}

AuthoredFieldStorage inlineAggregateStorage(
    AuthoredNamedKind kind,
    std::vector<AuthoredRecordField> fields,
    AuthoredLayoutRules layoutRules = {}
) {
    return AuthoredFieldStorage{
        AuthoredFieldStorageTag::inlineAggregate,
        AuthoredInlineAggregateStorage{
            kind,
            std::move(layoutRules),
            std::move(fields),
        },
    };
}

void testAuthoredTagRegistry() {
    check(rawValue(AuthoredTypeTag::qualifiedValue) == 0, "qualified-value tag is frozen");
    check(rawValue(AuthoredTypeTag::dataPointer) == 1, "data-pointer tag is frozen");

    check(rawValue(AuthoredAtomTag::void_) == 0, "void atom tag is frozen");
    check(rawValue(AuthoredAtomTag::scalar) == 1, "scalar atom tag is frozen");
    check(rawValue(AuthoredAtomTag::darwinAlias) == 2, "Darwin-alias atom tag is frozen");
    check(rawValue(AuthoredAtomTag::named) == 3, "named atom tag is frozen");

    check(rawValue(AuthoredScalarKind::bool_) == 0, "bool scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::char_) == 1, "char scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::signed8) == 2, "signed8 scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::unsigned8) == 3, "unsigned8 scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::signed16) == 4, "signed16 scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::unsigned16) == 5, "unsigned16 scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::signed32) == 6, "signed32 scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::unsigned32) == 7, "unsigned32 scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::signed64) == 8, "signed64 scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::unsigned64) == 9, "unsigned64 scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::float32) == 10, "float32 scalar tag is frozen");
    check(rawValue(AuthoredScalarKind::float64) == 11, "float64 scalar tag is frozen");

    check(rawValue(AuthoredDarwinAliasKind::sizeT) == 0, "size_t alias tag is frozen");
    check(rawValue(AuthoredDarwinAliasKind::ssizeT) == 1, "ssize_t alias tag is frozen");
    check(rawValue(AuthoredDarwinAliasKind::intptrT) == 2, "intptr_t alias tag is frozen");
    check(rawValue(AuthoredDarwinAliasKind::uintptrT) == 3, "uintptr_t alias tag is frozen");
    check(rawValue(AuthoredDarwinAliasKind::ptrdiffT) == 4, "ptrdiff_t alias tag is frozen");
    check(rawValue(AuthoredDarwinAliasKind::wcharT) == 5, "wchar_t alias tag is frozen");

    check(rawValue(AuthoredNamedKind::struct_) == 0, "struct named-kind tag is frozen");
    check(rawValue(AuthoredNamedKind::union_) == 1, "union named-kind tag is frozen");
    check(rawValue(AuthoredNamedKind::enum_) == 2, "enum named-kind tag is frozen");
    check(rawValue(AuthoredNamedKind::typedef_) == 3, "typedef named-kind tag is frozen");
    check(rawValue(AuthoredTypeDefinitionKind::recordStruct) == 0, "record-struct definition tag is frozen");
    check(rawValue(AuthoredTypeDefinitionKind::recordUnion) == 1, "record-union definition tag is frozen");
    check(rawValue(AuthoredTypeDefinitionKind::enumeration) == 2, "enumeration definition tag is frozen");
    check(rawValue(AuthoredTypeDefinitionKind::typedef_) == 3, "typedef definition tag is frozen");

    check(rawValue(AuthoredNameSubjectKind::function) == 0, "function name-subject tag is frozen");
    check(rawValue(AuthoredNameSubjectKind::label) == 1, "label name-subject tag is frozen");
    check(rawValue(AuthoredNameSubjectKind::data) == 2, "data name-subject tag is frozen");
    check(rawValue(AuthoredAppliedTypeSubjectKind::memoryObject) == 0, "memory-object subject tag is frozen");
    check(rawValue(AuthoredParameterListState::unspecified) == 0, "unspecified parameter-list tag is frozen");
    check(rawValue(AuthoredParameterListState::authoritative) == 1, "authoritative parameter-list tag is frozen");
    check(rawValue(AuthoredVariadicState::unspecified) == 0, "unspecified variadic tag is frozen");
    check(rawValue(AuthoredVariadicState::fixed) == 1, "fixed variadic tag is frozen");
    check(rawValue(AuthoredVariadicState::variadic) == 2, "variadic tag is frozen");

    check(rawValue(AuthoredFieldStorageTag::value) == 0, "value storage tag is frozen");
    check(rawValue(AuthoredFieldStorageTag::fixedArray) == 1, "fixed-array storage tag is frozen");
    check(rawValue(AuthoredFieldStorageTag::flexibleArray) == 2, "flexible-array storage tag is frozen");
    check(rawValue(AuthoredFieldStorageTag::opaquePointerCarrier) == 3, "opaque-carrier storage tag is frozen");
    check(rawValue(AuthoredFieldStorageTag::inlineAggregate) == 4, "inline-aggregate storage tag is frozen");
    check(rawValue(AuthoredOpaquePointerCarrierKind::functionPointer) == 0, "function-pointer carrier tag is frozen");
    check(rawValue(AuthoredOpaquePointerCarrierKind::pointerToArray) == 1, "pointer-to-array carrier tag is frozen");
    check(rawValue(AuthoredEnumRepresentation::signed32) == 0, "signed32 enum representation is frozen");
    check(rawValue(AuthoredQualifier::constant) == 0x01, "const qualifier bit is frozen");
    check(rawValue(AuthoredQualifier::volatile_) == 0x02, "volatile qualifier bit is frozen");
    check(rawValue(AuthoredQualifier::restrict_) == 0x04, "restrict qualifier bit is frozen");

    AuthoredInputs valid;
    valid.signatures = {
        AuthoredSignature{
            0x1000,
            std::make_shared<AuthoredType>(pointerType(
                namedType(AuthoredNamedKind::struct_, "Packet", 0x03),
                {0x01, 0x06, 0x07}
            )),
            AuthoredParameterListState::authoritative,
            {AuthoredParameter{"value", scalarType(AuthoredScalarKind::signed32)}},
            AuthoredVariadicState::fixed,
            AuthoredNoReturnState::returns,
        },
    };
    valid.typeDefinitions = {
        recordDefinition("Packet", {
            recordField("value", valueStorage()),
            recordField("fixed", fixedArrayStorage(valueStorage(), 4)),
            recordField("callback", AuthoredFieldStorage{
                AuthoredFieldStorageTag::opaquePointerCarrier,
                AuthoredOpaquePointerCarrierStorage{
                    AuthoredOpaquePointerCarrierKind::functionPointer,
                },
            }),
            recordField("inline", AuthoredFieldStorage{
                AuthoredFieldStorageTag::inlineAggregate,
                AuthoredInlineAggregateStorage{
                    AuthoredNamedKind::union_,
                    AuthoredLayoutRules{},
                    {recordField("nested", valueStorage())},
                },
            }),
            recordField("tail", flexibleArrayStorage()),
        }),
    };
    (void)canonicalizedAuthoredInputs(std::move(valid));

    AuthoredInputs nonfinalFlexibleArray;
    nonfinalFlexibleArray.typeDefinitions = {
        recordDefinition("Nonfinal", {
            recordField("tail", flexibleArrayStorage()),
            recordField("afterTail", valueStorage()),
        }),
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(nonfinalFlexibleArray)); },
        "nonfinal struct flexible-array field"
    );

    AuthoredInputs unionFlexibleArray;
    unionFlexibleArray.typeDefinitions = {
        recordDefinition(
            "UnionFlexible",
            {recordField("tail", flexibleArrayStorage())},
            AuthoredNamedKind::union_
        ),
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(unionFlexibleArray)); },
        "union flexible-array field"
    );

    AuthoredInputs unknownQualifier;
    unknownQualifier.signatures = {
        AuthoredSignature{
            0x1000,
            std::make_shared<AuthoredType>(scalarType(AuthoredScalarKind::signed32, 0x08)),
            AuthoredParameterListState::unspecified,
            {},
            AuthoredVariadicState::unspecified,
            AuthoredNoReturnState::unspecified,
        },
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(unknownQualifier)); },
        "unknown authored qualifier bit"
    );

    AuthoredInputs mismatchedTag;
    auto mismatched = scalarType();
    mismatched.tag = AuthoredTypeTag::dataPointer;
    mismatchedTag.signatures = {
        AuthoredSignature{
            0x1000,
            std::make_shared<AuthoredType>(std::move(mismatched)),
            AuthoredParameterListState::unspecified,
            {},
            AuthoredVariadicState::unspecified,
            AuthoredNoReturnState::unspecified,
        },
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(mismatchedTag)); },
        "authored type tag/payload mismatch"
    );

    AuthoredInputs unknownTag;
    auto type = scalarType();
    type.tag = static_cast<AuthoredTypeTag>(2);
    unknownTag.signatures = {
        AuthoredSignature{
            0x1000,
            std::make_shared<AuthoredType>(std::move(type)),
            AuthoredParameterListState::unspecified,
            {},
            AuthoredVariadicState::unspecified,
            AuthoredNoReturnState::unspecified,
        },
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(unknownTag)); },
        "unknown authored type tag"
    );
}

void testAuthoredNoReturnTriState() {
    check(rawValue(AuthoredNoReturnState::unspecified) == 0, "unspecified no-return tag is frozen");
    check(rawValue(AuthoredNoReturnState::returns) == 1, "returns no-return tag is frozen");
    check(rawValue(AuthoredNoReturnState::noReturn) == 2, "no-return tag is frozen");

    for (const auto state : {
             AuthoredNoReturnState::unspecified,
             AuthoredNoReturnState::returns,
             AuthoredNoReturnState::noReturn,
         }) {
        AuthoredInputs inputs;
        inputs.signatures = {signature(0x1000, state)};
        const auto validated = canonicalizedAuthoredInputs(std::move(inputs));
        check(validated.signatures.front().noReturnState == state, "no-return tri-state is retained");
    }

    AuthoredInputs unknown;
    unknown.signatures = {signature(0x1000, static_cast<AuthoredNoReturnState>(3))};
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(unknown)); },
        "unknown no-return state"
    );
}

void testAuthoredOrderingAndDuplicateKeys() {
    AuthoredInputs inputs;
    inputs.names = {
        {0x30, AuthoredNameSubjectKind::data, "zData"},
        {0x10, AuthoredNameSubjectKind::label, "aLabel"},
        {0x10, AuthoredNameSubjectKind::function, "zFunction"},
    };
    inputs.signatures = {
        signature(0x30, AuthoredNoReturnState::noReturn),
        AuthoredSignature{
            0x10,
            std::make_shared<AuthoredType>(pointerType(scalarType(), {0x01, 0x06})),
            AuthoredParameterListState::authoritative,
            {
                AuthoredParameter{"second", scalarType(AuthoredScalarKind::unsigned64)},
                AuthoredParameter{"first", scalarType(AuthoredScalarKind::signed16)},
            },
            AuthoredVariadicState::fixed,
            AuthoredNoReturnState::returns,
        },
    };
    inputs.appliedTypes = {
        {0x40, AuthoredAppliedTypeSubjectKind::memoryObject, "Zulu", 8},
        {0x20, AuthoredAppliedTypeSubjectKind::memoryObject, "Alpha", 4},
    };
    inputs.typeDefinitions = {
        typedefDefinition("Zulu", valueStorage()),
        recordDefinition("Alpha", {
            recordField("second", valueStorage(AuthoredType{
                AuthoredTypeTag::qualifiedValue,
                AuthoredQualifiedValue{
                    AuthoredAtom{
                        AuthoredAtomTag::darwinAlias,
                        AuthoredAtomPayload{AuthoredDarwinAliasKind::uintptrT},
                    },
                    0,
                },
            })),
            recordField("first", valueStorage()),
        }),
        enumerationDefinition("State", {
            AuthoredEnumCase{"second", 2},
            AuthoredEnumCase{"first", 1},
        }),
    };

    const auto validated = canonicalizedAuthoredInputs(inputs);
    check(validated.names[0].address == 0x10 &&
          validated.names[0].subjectKind == AuthoredNameSubjectKind::function,
          "authored names use frozen semantic order");
    check(validated.names[1].subjectKind == AuthoredNameSubjectKind::label,
          "authored name subject tag participates in sorting");
    check(validated.signatures[0].functionAddress == 0x10,
          "authored signatures sort by function address");
    check(validated.signatures[0].parameters[0].name == "second" &&
          validated.signatures[0].parameters[1].name == "first",
          "authored parameter order is preserved");
    const auto& pointer = std::get<AuthoredDataPointer>(validated.signatures[0].returnType->payload);
    check(pointer.pointerQualifiersByLevel == std::vector<std::uint8_t>({0x01, 0x06}),
          "pointer qualifier-level order is preserved");
    check(validated.appliedTypes[0].address == 0x20,
          "applied authored types use frozen semantic order");
    check(validated.typeDefinitions[0].name == "Alpha" &&
          validated.typeDefinitions[1].name == "State" &&
          validated.typeDefinitions[2].name == "Zulu",
          "authored type definitions sort by exact name bytes");
    const auto& record = std::get<AuthoredRecordDefinition>(validated.typeDefinitions[0].payload);
    check(record.fields[0].name == "second" && record.fields[1].name == "first",
          "record field order is preserved");
    const auto& enumeration = std::get<AuthoredEnumerationDefinition>(validated.typeDefinitions[1].payload);
    check(enumeration.cases[0].name == "second" && enumeration.cases[1].name == "first",
          "enum case order is preserved");

    auto duplicateNames = inputs;
    duplicateNames.names.push_back({0x10, AuthoredNameSubjectKind::function, "duplicate"});
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(duplicateNames)); },
        "duplicate authored name key"
    );
    auto duplicateSignatures = inputs;
    duplicateSignatures.signatures.push_back(signature(0x10, AuthoredNoReturnState::unspecified));
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(duplicateSignatures)); },
        "duplicate authored signature key"
    );
    auto duplicateApplied = inputs;
    duplicateApplied.appliedTypes.push_back(
        {0x20, AuthoredAppliedTypeSubjectKind::memoryObject, "Zulu", 8}
    );
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(duplicateApplied)); },
        "duplicate authored applied-type key"
    );
    auto duplicateDefinitions = inputs;
    duplicateDefinitions.typeDefinitions.push_back(typedefDefinition("Alpha", valueStorage()));
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(duplicateDefinitions)); },
        "duplicate authored definition name"
    );
}

void testAuthoredDepthAndCollectionBounds() {
    AuthoredInputs depthSixteen;
    depthSixteen.typeDefinitions = {typedefDefinition("Nested", nestedStorage(16))};
    (void)canonicalizedAuthoredInputs(std::move(depthSixteen));

    AuthoredInputs depthSeventeen;
    depthSeventeen.typeDefinitions = {typedefDefinition("Nested", nestedStorage(17))};
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(depthSeventeen)); },
        "authored depth seventeen"
    );

    AuthoredInputs names;
    names.names.reserve(4'097);
    for (std::size_t index = 0; index < 4'096; ++index) {
        names.names.push_back({index, AuthoredNameSubjectKind::function, "n"});
    }
    (void)canonicalizedAuthoredInputs(names);
    names.names.push_back({4'096, AuthoredNameSubjectKind::function, "n"});
    expectContractError([&] { (void)canonicalizedAuthoredInputs(names); }, "4,097 authored names");

    AuthoredInputs signatures;
    signatures.signatures.reserve(4'097);
    for (std::size_t index = 0; index < 4'096; ++index) {
        signatures.signatures.push_back(signature(index, AuthoredNoReturnState::unspecified));
    }
    (void)canonicalizedAuthoredInputs(signatures);
    signatures.signatures.push_back(signature(4'096, AuthoredNoReturnState::unspecified));
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(signatures); },
        "4,097 authored signatures"
    );

    AuthoredInputs parameters;
    auto parameterSignature = signature(0x1000, AuthoredNoReturnState::unspecified);
    parameterSignature.parameterListState = AuthoredParameterListState::authoritative;
    parameterSignature.parameters.assign(
        256,
        AuthoredParameter{"p", scalarType(AuthoredScalarKind::signed32)}
    );
    parameters.signatures = {parameterSignature};
    (void)canonicalizedAuthoredInputs(parameters);
    parameters.signatures[0].parameters.push_back(
        AuthoredParameter{"overflow", scalarType(AuthoredScalarKind::signed32)}
    );
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(parameters); },
        "257 authored parameters"
    );

    AuthoredInputs applied;
    applied.appliedTypes.reserve(4'097);
    for (std::size_t index = 0; index < 4'096; ++index) {
        applied.appliedTypes.push_back(
            {index, AuthoredAppliedTypeSubjectKind::memoryObject, "T", 1}
        );
    }
    (void)canonicalizedAuthoredInputs(applied);
    applied.appliedTypes.push_back(
        {4'096, AuthoredAppliedTypeSubjectKind::memoryObject, "T", 1}
    );
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(applied); },
        "4,097 applied authored types"
    );

    AuthoredInputs definitions;
    definitions.typeDefinitions.reserve(1'025);
    for (std::size_t index = 0; index < 1'024; ++index) {
        definitions.typeDefinitions.push_back(
            typedefDefinition("T" + std::to_string(index), valueStorage())
        );
    }
    (void)canonicalizedAuthoredInputs(definitions);
    definitions.typeDefinitions.push_back(typedefDefinition("overflow", valueStorage()));
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(definitions); },
        "1,025 authored type definitions"
    );

    std::vector<AuthoredRecordField> fields;
    fields.reserve(16'385);
    for (std::size_t index = 0; index < 16'384; ++index) {
        fields.push_back(recordField("f" + std::to_string(index), valueStorage()));
    }
    AuthoredInputs aggregate;
    aggregate.typeDefinitions = {recordDefinition("Maximum", fields)};
    (void)canonicalizedAuthoredInputs(aggregate);
    fields.push_back(recordField("overflow", valueStorage()));
    aggregate.typeDefinitions = {recordDefinition("Maximum", std::move(fields))};
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(aggregate); },
        "16,385 shared aggregate members"
    );
}

void testAuthoredCheckedStorageBounds() {
    AuthoredInputs maximumDimension;
    maximumDimension.typeDefinitions = {
        typedefDefinition("Maximum", fixedArrayStorage(valueStorage(), 1'048'576)),
    };
    (void)canonicalizedAuthoredInputs(maximumDimension);
    maximumDimension.typeDefinitions = {
        typedefDefinition("Overflow", fixedArrayStorage(valueStorage(), 1'048'577)),
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(maximumDimension); },
        "fixed-array dimension maximum plus one"
    );

    AuthoredInputs maximumStorage;
    maximumStorage.typeDefinitions = {
        typedefDefinition(
            "Maximum",
            fixedArrayStorage(valueStorage(scalarType(AuthoredScalarKind::unsigned64)), 131'072)
        ),
    };
    (void)canonicalizedAuthoredInputs(maximumStorage);
    maximumStorage.typeDefinitions = {
        typedefDefinition(
            "Overflow",
            fixedArrayStorage(valueStorage(scalarType(AuthoredScalarKind::unsigned64)), 131'073)
        ),
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(maximumStorage); },
        "computed authored storage maximum plus one"
    );

    AuthoredInputs appliedByteCount;
    appliedByteCount.appliedTypes = {
        {0x2000, AuthoredAppliedTypeSubjectKind::memoryObject, "T", 1'048'576},
    };
    (void)canonicalizedAuthoredInputs(appliedByteCount);
    appliedByteCount.appliedTypes[0].byteCount = 1'048'577;
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(appliedByteCount); },
        "applied authored byte count maximum plus one"
    );

    AuthoredInputs semanticText;
    semanticText.names = {
        {0x1000, AuthoredNameSubjectKind::function, std::string(1'024, 'n')},
    };
    (void)canonicalizedAuthoredInputs(semanticText);
    semanticText.names[0].name.push_back('n');
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(semanticText); },
        "semantic-name UTF-8 maximum plus one"
    );

    AuthoredInputs catalogText;
    catalogText.signatures = {
        AuthoredSignature{
            0x1000,
            std::make_shared<AuthoredType>(
                namedType(AuthoredNamedKind::typedef_, std::string(4'096, 'T'))
            ),
            AuthoredParameterListState::unspecified,
            {},
            AuthoredVariadicState::unspecified,
            AuthoredNoReturnState::unspecified,
        },
    };
    (void)canonicalizedAuthoredInputs(catalogText);
    auto& named = std::get<AuthoredNamedAtom>(
        std::get<AuthoredQualifiedValue>(catalogText.signatures[0].returnType->payload).atom.payload
    );
    named.name.push_back('T');
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(catalogText); },
        "catalog-text UTF-8 maximum plus one"
    );

    AuthoredInputs pointerQualifiers;
    pointerQualifiers.signatures = {
        AuthoredSignature{
            0x1000,
            std::make_shared<AuthoredType>(pointerType(scalarType(), {0x01, 0x02})),
            AuthoredParameterListState::unspecified,
            {},
            AuthoredVariadicState::unspecified,
            AuthoredNoReturnState::unspecified,
        },
    };
    (void)canonicalizedAuthoredInputs(pointerQualifiers);
    std::get<AuthoredDataPointer>(pointerQualifiers.signatures[0].returnType->payload)
        .pointerQualifiersByLevel.pop_back();
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(pointerQualifiers); },
        "pointer qualifier level count mismatch"
    );
}

void testAuthoredNestedFlexibleArrayPlacement() {
    const auto inlineStructWithFlexibleTail = [] {
        return inlineAggregateStorage(
            AuthoredNamedKind::struct_,
            {
                recordField("prefix", valueStorage()),
                recordField("tail", flexibleArrayStorage()),
            }
        );
    };

    AuthoredInputs validFinalStructFlexibleArray;
    validFinalStructFlexibleArray.typeDefinitions = {
        recordDefinition(
            "ValidFlexible",
            {
                recordField("prefix", valueStorage()),
                recordField("tail", flexibleArrayStorage()),
            }
        ),
    };
    (void)canonicalizedAuthoredInputs(std::move(validFinalStructFlexibleArray));

    AuthoredInputs validFinalNestedFlexibleArray;
    validFinalNestedFlexibleArray.typeDefinitions = {
        recordDefinition(
            "ValidFinalNestedFlexible",
            {
                recordField("prefix", valueStorage()),
                recordField("nested", inlineStructWithFlexibleTail()),
            }
        ),
    };
    (void)canonicalizedAuthoredInputs(std::move(validFinalNestedFlexibleArray));

    AuthoredInputs arrayOfFlexibleAggregate;
    arrayOfFlexibleAggregate.typeDefinitions = {
        typedefDefinition(
            "ArrayOfFlexibleAggregate",
            fixedArrayStorage(inlineStructWithFlexibleTail(), 2)
        ),
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(arrayOfFlexibleAggregate)); },
        "fixed array containing an inline aggregate with a flexible tail"
    );

    AuthoredInputs unionContainingFlexibleAggregate;
    unionContainingFlexibleAggregate.typeDefinitions = {
        recordDefinition(
            "UnionContainingFlexibleAggregate",
            {recordField("nested", inlineStructWithFlexibleTail())},
            AuthoredNamedKind::union_
        ),
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(unionContainingFlexibleAggregate)); },
        "union containing an inline aggregate with a flexible tail"
    );

    AuthoredInputs nonfinalFlexibleAggregate;
    nonfinalFlexibleAggregate.typeDefinitions = {
        recordDefinition(
            "NonfinalFlexibleAggregate",
            {
                recordField("nested", inlineStructWithFlexibleTail()),
                recordField("afterNested", valueStorage()),
            }
        ),
    };
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(nonfinalFlexibleAggregate)); },
        "nonfinal struct field containing an inline aggregate with a flexible tail"
    );
}

void testAuthoredParameterListShape() {
    auto explicitVoid = signature(0x6000, AuthoredNoReturnState::unspecified);
    explicitVoid.parameterListState = AuthoredParameterListState::authoritative;
    AuthoredInputs valid;
    valid.signatures = {explicitVoid};
    (void)canonicalizedAuthoredInputs(std::move(valid));

    auto contradictory = signature(0x6000, AuthoredNoReturnState::unspecified);
    contradictory.parameters = {
        AuthoredParameter{"ignored", scalarType(AuthoredScalarKind::signed32)},
    };
    AuthoredInputs invalid;
    invalid.signatures = {std::move(contradictory)};
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(std::move(invalid)); },
        "unspecified parameter-list state with nonempty parameters"
    );
}

void testAuthoredRecordFieldShapes() {
    const auto inputsForField = [](AuthoredRecordField field) {
        AuthoredInputs inputs;
        inputs.typeDefinitions = {
            recordDefinition("FieldShape", {std::move(field)}),
        };
        return inputs;
    };

    auto unnamedZeroWidth = recordField("", valueStorage(scalarType(AuthoredScalarKind::unsigned32)));
    unnamedZeroWidth.bitWidth = 0;
    expectAccepted(
        [&] {
            const auto validated = canonicalizedAuthoredInputs(inputsForField(unnamedZeroWidth));
            const auto& record = std::get<AuthoredRecordDefinition>(
                validated.typeDefinitions.front().payload
            );
            check(record.fields.front().name.empty(), "unnamed zero-width bitfield name is preserved");
            check(
                record.fields.front().bitWidth == std::optional<std::uint64_t>{0},
                "unnamed zero-width bitfield width is preserved"
            );
        },
        "unnamed zero-width bitfield"
    );

    auto unnamedPositiveWidth =
        recordField("", valueStorage(scalarType(AuthoredScalarKind::unsigned32)));
    unnamedPositiveWidth.bitWidth = 3;
    expectAccepted(
        [&] {
            const auto validated = canonicalizedAuthoredInputs(inputsForField(unnamedPositiveWidth));
            const auto& record = std::get<AuthoredRecordDefinition>(
                validated.typeDefinitions.front().payload
            );
            check(
                record.fields.front().bitWidth == std::optional<std::uint64_t>{3},
                "unnamed positive-width bitfield is preserved"
            );
        },
        "unnamed positive-width bitfield"
    );

    auto anonymousPromoted = recordField(
        "",
        inlineAggregateStorage(
            AuthoredNamedKind::struct_,
            {recordField("member", valueStorage())}
        )
    );
    anonymousPromoted.promotesInlineFields = true;
    expectAccepted(
        [&] {
            const auto validated = canonicalizedAuthoredInputs(inputsForField(anonymousPromoted));
            const auto& record = std::get<AuthoredRecordDefinition>(
                validated.typeDefinitions.front().payload
            );
            check(
                record.fields.front().promotesInlineFields,
                "anonymous promoted inline aggregate flag is preserved"
            );
        },
        "anonymous promoted inline aggregate"
    );

    auto namedZeroWidth = recordField(
        "named",
        valueStorage(scalarType(AuthoredScalarKind::unsigned32))
    );
    namedZeroWidth.bitWidth = 0;
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(inputsForField(namedZeroWidth)); },
        "named zero-width bitfield"
    );

    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(inputsForField(recordField("", valueStorage()))); },
        "empty ordinary record-field name"
    );

    auto namedPromotedInline = recordField(
        "named",
        inlineAggregateStorage(
            AuthoredNamedKind::union_,
            {recordField("member", valueStorage())}
        )
    );
    namedPromotedInline.promotesInlineFields = true;
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(inputsForField(namedPromotedInline)); },
        "named inline aggregate cannot promote fields"
    );

    auto promotedNonInline = recordField("named", valueStorage());
    promotedNonInline.promotesInlineFields = true;
    expectContractError(
        [&] { (void)canonicalizedAuthoredInputs(inputsForField(promotedNonInline)); },
        "non-inline storage cannot promote fields"
    );
}

void testAppleMachOTargetAcceptedVectors() {
    struct AcceptedVector final {
        std::uint32_t rawSubtype;
        ArchitectureVariant variant;
        const char* recognizedCapabilityBits;
        std::optional<std::uint32_t> pointerAuthAbiVersion;
    };
    const std::vector<AcceptedVector> accepted = {
        {0x0000'0000U, ArchitectureVariant::arm64, "00000000", std::nullopt},
        {0x8000'0000U, ArchitectureVariant::arm64, "80000000", std::nullopt},
        {0x0000'0002U, ArchitectureVariant::arm64e, "00000000", std::nullopt},
        {0x8000'0002U, ArchitectureVariant::arm64e, "80000000", 0U},
    };

    for (const auto& vector : accepted) {
        const auto target = normalizeAppleMachOTarget(
            0x0100'000cU,
            vector.rawSubtype,
            std::string(64, 'a'),
            4'096
        );
        check(target.rawCpuType == "0100000c", "raw CPU type uses canonical lowercase hex");
        check(
            target.rawCpuSubtype == [&] {
                constexpr char digits[] = "0123456789abcdef";
                std::string encoded(8, '0');
                auto value = vector.rawSubtype;
                for (auto index = encoded.size(); index > 0; --index) {
                    encoded[index - 1] = digits[value & 0x0fU];
                    value >>= 4U;
                }
                return encoded;
            }(),
            "raw CPU subtype uses canonical lowercase hex"
        );
        check(target.normalizedVariant == vector.variant, "architecture variant is normalized");
        check(
            target.recognizedCapabilityBits == vector.recognizedCapabilityBits,
            "recognized capability bits are preserved"
        );
        check(
            target.pointerAuthAbiVersion == vector.pointerAuthAbiVersion,
            "pointer-auth ABI version presence is preserved"
        );
        check(target.selectedSliceSha256 == std::string(64, 'a'), "selected slice SHA is retained");
        check(target.selectedSliceByteCount == 4'096, "selected slice byte count is retained");
        check(
            target.profileId == "apple-aarch64-pac-visible-clobber-v1",
            "target profile ID is frozen"
        );
        check(
            target.languageId == "AARCH64:LE:64:AppleSilicon",
            "Apple-Silicon language is frozen"
        );
        check(target.compilerSpecId == "default", "compiler specification is frozen");
    }
}

void testAppleMachOTargetRejectedVectors() {
    const std::vector<std::uint32_t> rejectedSubtypes = {
        0x0000'0001U,
        0x7000'0000U,
        0x1000'0002U,
        0x2000'0002U,
        0x3000'0002U,
        0x4000'0002U,
        0x5000'0002U,
        0x6000'0002U,
        0x7000'0002U,
        0x9000'0002U,
        0xa000'0002U,
        0xb000'0002U,
        0xc000'0002U,
        0xd000'0002U,
        0xe000'0002U,
        0xf000'0002U,
        0x8000'0003U,
        0xffff'ffffU,
    };
    for (const auto rawSubtype : rejectedSubtypes) {
        expectContractError(
            [rawSubtype] {
                (void)normalizeAppleMachOTarget(
                    0x0100'000cU,
                    rawSubtype,
                    std::string(64, 'a'),
                    4'096
                );
            },
            "unsupported raw ARM64 subtype"
        );
    }
    expectContractError(
        [] {
            (void)normalizeAppleMachOTarget(
                0x0000'000cU,
                0,
                std::string(64, 'a'),
                4'096
            );
        },
        "non-ARM64 raw CPU type"
    );
}

void testSealedContextProfileIdentity() {
    const auto target = normalizeAppleMachOTarget(
        0x0100'000cU,
        0x8000'0002U,
        std::string(64, 'a'),
        4'096
    );
    check(
        target.contextProfileSha256 ==
            "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5",
        "sealed context profile SHA is frozen"
    );
    check(target.context.size() == 4, "sealed context contains exactly four values");
    check(
        target.context[0] == TargetContextValue{"ShowPAC", 1} &&
        target.context[1] == TargetContextValue{"PAC_clobber", 1} &&
        target.context[2] == TargetContextValue{"ShowBTI", 0} &&
        target.context[3] == TargetContextValue{"ShowMemTag", 0},
        "sealed context names, values, and order are frozen"
    );
}

void testProductBudgetProfileV1() {
    const auto profiled = productAnalysisBudgetsV1();
    check(profiled.profileId == "native-product-budget-v1", "product budget profile ID is frozen");
    check(profiled.maxCodeBytes == 1'048'576, "product code-byte budget is frozen");
    check(profiled.maxInstructions == 65'536, "product instruction budget is frozen");
    check(profiled.maxOperations == 262'144, "product operation budget is frozen");
    check(profiled.maxOutputBytes == 1'048'576, "product output-byte budget is frozen");
    check(profiled.maxWallTimeMilliseconds == 5'000, "product wall-time budget is frozen");

    const auto limits = profiled.analysisLimits();
    check(limits.maxCodeBytes == profiled.maxCodeBytes, "code-byte projection is exact");
    check(
        limits.maxInstructions == profiled.maxInstructions,
        "instruction projection is exact"
    );
    check(limits.maxOperations == profiled.maxOperations, "operation projection is exact");
    check(limits.maxOutputBytes == profiled.maxOutputBytes, "output projection is exact");
    check(
        limits.maxWallTimeMilliseconds == profiled.maxWallTimeMilliseconds,
        "wall-time projection is exact"
    );
}

void testTargetRejectsInvalidSelectedSliceEvidence() {
    for (const auto& invalidDigest : {
             std::string(63, 'a'),
             std::string(65, 'a'),
             std::string(64, 'A'),
             std::string(64, 'g'),
         }) {
        expectContractError(
            [&invalidDigest] {
                (void)normalizeAppleMachOTarget(
                    0x0100'000cU,
                    0,
                    invalidDigest,
                    1
                );
            },
            "invalid selected-slice SHA"
        );
    }
    expectContractError(
        [] {
            (void)normalizeAppleMachOTarget(
                0x0100'000cU,
                0,
                std::string(64, 'a'),
                0
            );
        },
        "zero selected-slice byte count"
    );
}

void testSealedX86TargetContract() {
    const auto target = normalizeAppleMachOTarget(0x0100'0007U, 3U, std::string(64, 'a'), 16);
    check(target.rawCpuType == "01000007" && target.rawCpuSubtype == "00000003",
          "x86 raw architecture is canonical");
    check(target.normalizedVariant == ArchitectureVariant::x86_64 &&
          target.recognizedCapabilityBits == "00000000" && !target.pointerAuthAbiVersion,
          "x86 has no capability bits or pointer authentication");
    check(target.profileId == "apple-x86_64-sysv-v1" &&
          target.languageId == "x86:LE:64:default" && target.compilerSpecId == "gcc",
          "x86 admits only the sealed SysV tuple");
    check(target.contextProfileSha256 ==
          "5fd328d91f7f3a0f815136362f1fe60ba5749f1a72c2337b30c7b7765edf9deb",
          "x86 context has its own frozen digest");
    check(target.context == std::array<TargetContextValue, 4>{{
        {"addrsize", 2}, {"opsize", 1}, {"rexprefix", 0}, {"longMode", 1},
    }}, "x86 context order and initial values are sealed");
    for (const auto subtype : {0U, 2U, 8U, 0x8000'0003U, 0x0100'0003U, 0xffff'ffffU}) {
        expectContractError([&] {
            (void)normalizeAppleMachOTarget(0x0100'0007U, subtype, std::string(64, 'a'), 16);
        }, "unknown x86 subtype or capability rejected");
    }
    expectContractError([] {
        (void)normalizeAppleMachOTarget(7U, 3U, std::string(64, 'a'), 16);
    }, "i386 remains excluded");
    expectContractError([] {
        (void)normalizeAppleMachOTarget(0x0100'0007U, 3U, std::string(64, 'A'), 16);
    }, "x86 selected-slice digest must be canonical");
    expectContractError([] {
        (void)normalizeAppleMachOTarget(0x0100'0007U, 3U, std::string(64, 'a'), 0);
    }, "x86 selected-slice byte count must be positive");

    const auto makeRequest = [](std::string language, std::string compiler,
                                FunctionIdentity function, std::size_t codeBudget = 4) {
        const std::vector<std::uint8_t> code = {0x90, 0x90, 0xc3, 0x90, 0x90, 0x90, 0x90, 0xc3};
        auto budgets = productAnalysisBudgetsV1().analysisLimits();
        budgets.maxCodeBytes = codeBudget;
        return AnalysisRequestView(
            "x86-contract", std::string(64, 'a'), std::move(language), std::move(compiler),
            {"image.main", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 0x1000},
            std::move(function), ByteProvider({{"__text", 0x1000, "r-x", code, code, {}}}),
            SymbolProvider({}), TypeHintProvider({}), budgets, 4
        );
    };
    const FunctionIdentity sparse{
        "function.entry", "entry", 0x1001, 0x1008, {{0x1001, 0x1003}, {0x1006, 0x1008}},
    };
    expectAccepted([&] {
        const auto request = makeRequest(target.languageId, target.compilerSpecId, sparse);
        check(request.functionBytes() == std::vector<std::uint8_t>({0x90, 0xc3, 0x90, 0xc3}),
              "sparse x86 ranges preserve byte ownership");
    }, "byte-aligned x86 sparse ranges accepted");
    expectContractError([&] {
        (void)makeRequest("AARCH64:LE:64:AppleSilicon", "default", sparse);
    }, "A64 misalignment stays rejected");
    expectContractError([&] {
        (void)makeRequest(target.languageId, "clangwindows", sparse);
    }, "Windows compiler cannot use SysV byte alignment");
    expectContractError([&] {
        (void)makeRequest(target.languageId, target.compilerSpecId, sparse, 3);
    }, "x86 aggregate code budget remains enforced");
    auto invalid = sparse;
    invalid.codeRanges = {{0x1001, 0x1007}, {0x1006, 0x1008}};
    expectContractError([&] {
        (void)makeRequest(target.languageId, target.compilerSpecId, invalid, 8);
    }, "x86 overlapping ranges stay rejected");
    invalid = sparse;
    invalid.endAddressExclusive = 0x1009;
    invalid.codeRanges.back().endAddressExclusive = 0x1009;
    expectContractError([&] {
        (void)makeRequest(target.languageId, target.compilerSpecId, invalid, 8);
    }, "x86 unmapped code stays rejected");
    expectContractError([&] {
        (void)makeGhidraBackend({
            "/unmaterialized", std::string(64, '0'), "/unmaterialized/specs",
            target.languageId, target.compilerSpecId,
        });
    }, "x86 runtime remains unavailable before resource admission");
}

} // namespace

int main(int argc, char** argv) {
    testSealedX86TargetContract();
    if (argc == 2 && std::string_view(argv[1]) == "--x86-contract") {
        if (failures != 0) return EXIT_FAILURE;
        std::cout << "x86 target contract: PASS (bounded contract matrix)\n";
        return EXIT_SUCCESS;
    }

    testAuthoredTagRegistry();
    testAuthoredNoReturnTriState();
    testAuthoredOrderingAndDuplicateKeys();
    testAuthoredDepthAndCollectionBounds();
    testAuthoredCheckedStorageBounds();
    testAuthoredNestedFlexibleArrayPlacement();
    testAuthoredParameterListShape();
    testAuthoredRecordFieldShapes();
    testAppleMachOTargetAcceptedVectors();
    testAppleMachOTargetRejectedVectors();
    testSealedContextProfileIdentity();
    testProductBudgetProfileV1();
    testTargetRejectsInvalidSelectedSliceEvidence();

    const auto request = test_fixtures::makeRequest();
    check(request.functionBytes().size() == 8, "function bytes are read from effective caller-owned regions");
    check(request.functionBytes() == request.effectiveFunctionBytes(), "compatibility function bytes use effective view");
    check(request.rawFunctionBytes()[0] == 0x00, "raw function bytes retain provenance input");
    check(request.effectiveFunctionBytes()[0] == 0x20, "effective function bytes contain applied patch output");
    check(request.bytes.regions()[0].appliedPatchIds == std::vector<std::string>{"patch000000"},
          "applied patch identities are retained");
    check(request.symbols.exact(0x1000).size() == 2, "all exact symbols are retained");
    check(request.symbols.preferred(0x1000)->kind == "alias", "symbol preference is deterministic");
    check(request.typeHints.at(0x1000).size() == 1, "type hints are address-indexed");
    check(!request.bytes.contains(0x2000, 4, true), "non-executable data is not accepted as code");

    expectContractError([] {
        ByteProvider invalid({
            MemoryRegion{"a", 0x1000, "r-x", {1, 2, 3, 4}, {1, 2, 3, 4}, {}},
            MemoryRegion{"b", 0x1002, "r-x", {5, 6, 7, 8}, {5, 6, 7, 8}, {}},
        });
        (void)invalid;
    }, "overlapping regions");

    expectContractError([&request] {
        (void)request.bytes.readEffective(0x1004, 8);
    }, "unmapped read");

    expectContractError([] {
        ByteProvider invalid({
            MemoryRegion{"mismatched", 0x3000, "r-x", {1, 2, 3, 4}, {1, 2, 3}, {}},
        });
        (void)invalid;
    }, "raw/effective size mismatch");

    expectContractError([] {
        ByteProvider invalid({
            MemoryRegion{"bad-patch", 0x3000, "r-x", {1, 2, 3, 4}, {1, 2, 3, 4}, {"patch1"}},
        });
        (void)invalid;
    }, "noncanonical patch ID");

    expectContractError([] {
        ByteProvider invalid({
            MemoryRegion{std::string("\xc3\x28", 2), 0x3000, "r-x", {1, 2, 3, 4}, {1, 2, 3, 4}, {}},
        });
        (void)invalid;
    }, "invalid UTF-8 input text");

    expectContractError([] {
        ByteProvider invalid({
            MemoryRegion{
                "unordered-patches",
                0x3000,
                "r-x",
                {1, 2, 3, 4},
                {1, 2, 3, 4},
                {"patch000001", "patch000000"},
            },
        });
        (void)invalid;
    }, "unordered patch IDs");

    expectContractError([] {
        ByteProvider invalid({
            MemoryRegion{"a", 0x3000, "r-x", {1, 2, 3, 4}, {1, 2, 3, 4}, {"patch000000"}},
            MemoryRegion{"b", 0x4000, "r--", {5, 6, 7, 8}, {5, 6, 7, 8}, {"patch000000"}},
        });
        (void)invalid;
    }, "duplicate patch ID across regions");

    std::atomic_bool cancelled = true;
    expectContractError([&cancelled] {
        CancellationToken token(&cancelled);
        token.throwIfCancelled();
    }, "cancellation");

    expectContractError([] {
        (void)test_fixtures::makeRequest(AnalysisBudgets{4096, 0, 4096, 1024 * 1024, 1000});
    }, "zero analysis budget");

    auto result = test_fixtures::makeResult(request);
    validateStructuredResult(request, result);

    const PseudocodeDocumentRecord completeDocument{
        "uint64_t fixture(void) {\n\treturn 1;\n}\n",
        "c",
        true,
        false,
    };
    result.pseudocodeDocument = completeDocument;
    validateStructuredResult(request, result);
    const auto canonicalDocumentResult = canonicalizedStructuredResult(result);
    check(
        canonicalDocumentResult.pseudocodeDocument == completeDocument,
        "canonicalization preserves native pseudocode presentation bytes and metadata"
    );

    auto invalidDocument = result;
    invalidDocument.pseudocodeDocument->text.clear();
    expectContractError(
        [&] { validateStructuredResult(request, invalidDocument); },
        "empty pseudocode presentation"
    );

    invalidDocument = result;
    invalidDocument.pseudocodeDocument->language = "swift";
    expectContractError(
        [&] { validateStructuredResult(request, invalidDocument); },
        "unsupported pseudocode presentation language"
    );

    invalidDocument = result;
    invalidDocument.pseudocodeDocument->text = std::string("return ") + std::string("\xc3\x28", 2);
    expectContractError(
        [&] { validateStructuredResult(request, invalidDocument); },
        "invalid UTF-8 pseudocode presentation"
    );

    invalidDocument = result;
    invalidDocument.pseudocodeDocument->text = "return 1;\r\n";
    expectContractError(
        [&] { validateStructuredResult(request, invalidDocument); },
        "CR pseudocode presentation line ending"
    );

    invalidDocument = result;
    invalidDocument.pseudocodeDocument->text = std::string("return") + '\0' + "1;";
    expectContractError(
        [&] { validateStructuredResult(request, invalidDocument); },
        "embedded NUL in pseudocode presentation"
    );

    invalidDocument = result;
    invalidDocument.pseudocodeDocument->text = std::string("return") + static_cast<char>(0x1b) + "1;";
    expectContractError(
        [&] { validateStructuredResult(request, invalidDocument); },
        "unsupported pseudocode presentation control text"
    );

    invalidDocument = result;
    invalidDocument.pseudocodeDocument->isComplete = true;
    invalidDocument.pseudocodeDocument->isTruncated = true;
    expectContractError(
        [&] { validateStructuredResult(request, invalidDocument); },
        "contradictory pseudocode presentation completeness"
    );

    invalidDocument = result;
    invalidDocument.pseudocodeDocument->isComplete = false;
    invalidDocument.pseudocodeDocument->isTruncated = false;
    expectContractError(
        [&] { validateStructuredResult(request, invalidDocument); },
        "missing pseudocode presentation completeness"
    );

    auto tampered = result;
    tampered.instructions[0].sourceRanges[0].endAddressExclusive = 0x1003;
    expectContractError([&] { validateStructuredResult(request, tampered); }, "instruction exact source range");

    tampered = result;
    tampered.operations[0].sourceRanges[0].imageId = "other.image";
    expectContractError([&] { validateStructuredResult(request, tampered); }, "foreign source image");

    tampered = result;
    tampered.ssaBindings.pop_back();
    expectContractError([&] { validateStructuredResult(request, tampered); }, "missing SSA binding");

    tampered = result;
    tampered.tokens[0].entityReferences[0].id = "region.missing";
    expectContractError([&] { validateStructuredResult(request, tampered); }, "unknown token entity");

    tampered = result;
    tampered.memoryEffects[0].outputMemoryVersionId = "memory.missing";
    expectContractError([&] { validateStructuredResult(request, tampered); }, "unknown memory version");

    tampered = result;
    tampered.instructions[0].bytes.resize(2);
    tampered.instructions[0].sourceRanges[0].endAddressExclusive = 0x1002;
    expectContractError([&] { validateStructuredResult(request, tampered); }, "instruction coverage gap");

    tampered = result;
    tampered.instructions[0].sourceRanges.push_back(tampered.instructions[0].sourceRanges[0]);
    expectContractError([&] { validateStructuredResult(request, tampered); }, "duplicate source range");

    tampered = result;
    tampered.ssaValues.push_back({"ssa.orphan", "vn.x0", "operationResult", "op.0", std::nullopt});
    expectContractError([&] { validateStructuredResult(request, tampered); }, "orphaned SSA definition");

    tampered = result;
    tampered.memoryVersions.push_back(
        {"memory.orphan", "unknown", "operationResult", "op.0", std::nullopt}
    );
    expectContractError([&] { validateStructuredResult(request, tampered); }, "orphaned memory definition");

    tampered = result;
    tampered.edges.push_back(
        {"edge.unresolved-internal", "block.0", std::nullopt, 0x1004, "branch", "op.1"}
    );
    tampered.blocks[0].successorEdgeIds.push_back("edge.unresolved-internal");
    expectContractError([&] { validateStructuredResult(request, tampered); }, "unresolved internal edge target");

    // §4.73: ordinary code carries 64-bit constants in [-8, -1] (`sub x9, x9, #8`)
    // and stack slots at negative offsets (saved x30 at -8). Their offsets wrap,
    // so the storage-overflow check applies only to non-wrapping spaces.
    for (const std::string_view kind : {"constant", "spacebase"}) {
        tampered = result;
        tampered.addressSpaces.push_back({"space.wrapping", "wrapping", std::string(kind), 8, false});
        for (auto& varnode : tampered.varnodes) {
            if (varnode.id == "vn.constant.0") {
                varnode.addressSpaceId = "space.wrapping";
                varnode.offset = 0xffff'ffff'ffff'fff8ULL;
            }
        }
        validateStructuredResult(request, tampered);
    }
    tampered = result;
    for (auto& varnode : tampered.varnodes) {
        if (varnode.id == "vn.constant.0") varnode.offset = 0xffff'ffff'ffff'fff8ULL;
    }
    expectContractError(
        [&] { validateStructuredResult(request, tampered); },
        "storage varnode range overflow in a non-wrapping space"
    );

    auto sixtyFourCharacterRevision = test_fixtures::fullAvailability();
    sixtyFourCharacterRevision.identity.ghidraGitRevision = std::string(64, 'd');
    sixtyFourCharacterRevision.identity.wrapperGitRevision = std::string(64, 'e');
    sixtyFourCharacterRevision.runtimeIdentity->engineRevision = std::string(64, 'd');
    sixtyFourCharacterRevision.runtimeIdentity->wrapperRevision = std::string(64, 'e');
    validateBackendAvailability(sixtyFourCharacterRevision);

    auto missingRuntimeIdentity = test_fixtures::fullAvailability();
    missingRuntimeIdentity.runtimeIdentity.reset();
    expectContractError(
        [&] { validateBackendAvailability(missingRuntimeIdentity); },
        "available backend missing its prepared runtime identity"
    );

    auto invalidRuntimeIdentity = test_fixtures::fullAvailability();
    invalidRuntimeIdentity.runtimeIdentity->packageTreeSha256 = "not-a-sha256";
    expectContractError(
        [&] { validateBackendAvailability(invalidRuntimeIdentity); },
        "prepared runtime identity with an invalid package-tree digest"
    );

    auto invalidAvailability = BackendAvailability{};
    invalidAvailability.reasonCode = "Invalid Reason";
    expectContractError(
        [&] { validateBackendAvailability(invalidAvailability); },
        "unavailable reason-code slug"
    );

    invalidAvailability.reasonCode = "fixture-unavailable";
    invalidAvailability.runtimeIdentity =
        test_fixtures::fullAvailability().runtimeIdentity;
    expectContractError(
        [&] { validateBackendAvailability(invalidAvailability); },
        "unavailable backend claiming a prepared runtime identity"
    );

    invalidAvailability.runtimeIdentity.reset();
    invalidAvailability.identity.ghidraVersion = "12.1.2";
    expectContractError(
        [&] { validateBackendAvailability(invalidAvailability); },
        "unavailable versioned identity"
    );

    expectContractError([] {
        (void)makeGhidraBackend({
            "relative/package",
            std::string(64, '0'),
            "relative/package/specs",
            "AARCH64:LE:64:AppleSilicon",
            "default",
        });
    }, "relative native package root");

    expectContractError([] {
        (void)makeGhidraBackend({
            "/governed/package",
            std::string(64, '0'),
            "/other/specs",
            "AARCH64:LE:64:AppleSilicon",
            "default",
        });
    }, "processor specifications outside package root");

    expectContractError([] {
        (void)makeGhidraBackend({
            "/governed/package",
            std::string(64, '0'),
            "/governed/package",
            "AARCH64:LE:64:AppleSilicon",
            "default",
        });
    }, "processor specifications equal package root");

    expectContractError([] {
        (void)makeGhidraBackend({
            "/governed/package",
            "not-a-sha256",
            "/governed/package/specs",
            "AARCH64:LE:64:AppleSilicon",
            "default",
        });
    }, "invalid native package digest");

    expectContractError([] {
        (void)makeGhidraBackend({
            "/governed/package",
            std::string(64, '0'),
            "/governed/package/specs",
            "x86:LE:64:default",
            "default",
        });
    }, "unsupported native language");

#if !defined(MACSCOPE_ENABLE_GHIDRA_PROVIDER)
    auto backend = makeGhidraBackend({
        "/unmaterialized",
        std::string(64, '0'),
        "/unmaterialized/Ghidra/Processors/AARCH64",
        "AARCH64:LE:64:AppleSilicon",
        "default",
    });
    const auto availability = backend->availability();
    validateBackendAvailability(availability);
    check(!availability.available, "DCP-03B4 backend remains unavailable until native adapter linkage");
    check(availability.identity.ghidraVersion.empty(),
          "unlinked backend does not claim a Ghidra version");
    check(!availability.runtimeIdentity.has_value(),
          "unlinked backend does not claim a prepared runtime identity");
    check(!availability.capabilities.nativeDecompilerHeritage, "no false native heritage capability");
    check(!availability.capabilities.completeRegisterSsa, "no false register SSA capability");
    check(!availability.capabilities.memorySsa, "no false MemorySSA capability");
    check(!availability.capabilities.recoveredVariables, "no false variable-recovery capability");
    check(!availability.capabilities.recoveredTypes, "no false type-recovery capability");
    check(!availability.capabilities.structuredControlFlow, "no false structured-control-flow capability");
    check(!availability.capabilities.tokenizedPseudocode, "no false token capability");
    check(!availability.capabilities.imageQualifiedSourceRanges, "no false source-range capability");
    expectContractError([&] { (void)backend->decompile(request, CancellationToken{}); }, "unavailable backend");
#endif

    expectContractError([] {
        (void)makeGhidraBackend({
            "/unmaterialized",
            "not-a-sha256",
            "/unmaterialized/specs",
            "AARCH64:LE:64:AppleSilicon",
            "default",
        });
    }, "invalid native package manifest identity");

    expectContractError([] {
        (void)makeGhidraBackend({
            "/unmaterialized",
            std::string(64, '0'),
            "/unmaterialized/specs",
            "AARCH64:LE:64:AppleSilicon",
            "unapproved",
        });
    }, "unapproved compiler specification");

    if (failures != 0) {
        std::cerr << failures << " contract test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "MacScope native-decompiler contract tests passed\n";
    return EXIT_SUCCESS;
}
