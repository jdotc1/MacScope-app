#include "CanonicalRequest.hpp"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <concepts>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace macscope::native_decompiler;

namespace {

constexpr std::string_view kGoldenPreimageHex = R"HEX(
32323a63616e6f6e6963616c53747265616d56657273696f6e0a313a320a31333a736368656d6156657273696f6e0a313a330a393a6f706572617469
6f6e0a393a6465636f6d70696c650a31373a7461726765742e726177435055547970650a383a30313030303030630a32303a7461726765742e726177
435055537562747970650a383a38303030303030320a32343a7461726765742e6e6f726d616c697a656456617269616e740a363a61726d3634650a33
313a7461726765742e7265636f676e697a65644361706162696c697479426974730a383a38303030303030300a33363a7461726765742e706f696e74
65724175746841424956657273696f6e2e70726573656e740a313a310a33343a7461726765742e706f696e7465724175746841424956657273696f6e
2e76616c75650a313a300a32363a7461726765742e73656c6563746564536c6963655348413235360a36343a61616161616161616161616161616161
6161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161610a32393a7461726765742e73
656c6563746564536c69636542797465436f756e740a313a340a31363a7461726765742e70726f66696c6549440a33363a6170706c652d6161726368
36342d7061632d76697369626c652d636c6f626265722d76310a31373a7461726765742e6c616e677561676549440a32363a414152434836343a4c45
3a36343a4170706c6553696c69636f6e0a32313a7461726765742e636f6d70696c65725370656349440a373a64656661756c740a32373a7461726765
742e636f6e7465787450726f66696c655348413235360a36343a36616134356561393230366639363763303935643137356230356336633064373938
3063643135613037303238323664376162333865346664333763386361350a32303a7461726765742e636f6e746578742e636f756e740a313a340a32
323a7461726765742e636f6e746578745b305d2e6e616d650a373a53686f775041430a32333a7461726765742e636f6e746578745b305d2e76616c75
650a313a310a32323a7461726765742e636f6e746578745b315d2e6e616d650a31313a5041435f636c6f626265720a32333a7461726765742e636f6e
746578745b315d2e76616c75650a313a310a32323a7461726765742e636f6e746578745b325d2e6e616d650a373a53686f774254490a32333a746172
6765742e636f6e746578745b325d2e76616c75650a313a300a32323a7461726765742e636f6e746578745b335d2e6e616d650a31303a53686f774d65
6d5461670a32333a7461726765742e636f6e746578745b335d2e76616c75650a313a300a31333a696d6167652e696d61676549440a31303a696d6167
652e6d61696e0a31303a696d6167652e757569640a33363a61616161616161612d626262622d636363632d646464642d656565656565656565656565
0a32363a696d6167652e7072656665727265644c6f6164416464726573730a31303a343239343936373239360a31393a66756e6374696f6e2e66756e
6374696f6e49440a31343a66756e6374696f6e2e656e7472790a31333a66756e6374696f6e2e6e616d650a353a656e7472790a32313a66756e637469
6f6e2e656e747279416464726573730a31303a343239343937313339320a32383a66756e6374696f6e2e656e64416464726573734578636c75736976
650a31303a343239343937313339360a31393a6d656d6f7279526567696f6e732e636f756e740a313a310a32313a6d656d6f7279526567696f6e735b
305d2e6e616d650a363a5f5f746578740a32393a6d656d6f7279526567696f6e735b305d2e7374617274416464726573730a31303a34323934393731
3339320a32383a6d656d6f7279526567696f6e735b305d2e7065726d697373696f6e730a333a722d780a32353a6d656d6f7279526567696f6e735b30
5d2e72617742797465730a343a000000000a33313a6d656d6f7279526567696f6e735b305d2e65666665637469766542797465730a343a1f2003d50a
33383a6d656d6f7279526567696f6e735b305d2e6170706c69656450617463684944732e636f756e740a313a310a33353a6d656d6f7279526567696f
6e735b305d2e6170706c69656450617463684944735b305d0a31313a70617463683030303030310a31333a73796d626f6c732e636f756e740a313a31
0a31383a73796d626f6c735b305d2e696d61676549440a31303a696d6167652e6d61696e0a31383a73796d626f6c735b305d2e616464726573730a31
303a343239343937313339320a31353a73796d626f6c735b305d2e6e616d650a363a5f656e7472790a31353a73796d626f6c735b305d2e6b696e640a
383a66756e6374696f6e0a32383a617574686f726564496e707574732e736368656d6156657273696f6e0a383a00000000000000010a32363a617574
686f726564496e707574732e6e616d65732e636f756e740a383a00000000000000010a33313a617574686f726564496e707574732e6e616d65735b30
5d2e616464726573730a383a00000001000010000a33353a617574686f726564496e707574732e6e616d65735b305d2e7375626a6563744b696e640a
313a000a32383a617574686f726564496e707574732e6e616d65735b305d2e6e616d650a353a656e7472790a33313a617574686f726564496e707574
732e7369676e6174757265732e636f756e740a383a00000000000000010a34343a617574686f726564496e707574732e7369676e6174757265735b30
5d2e66756e6374696f6e416464726573730a383a00000001000010000a34373a617574686f726564496e707574732e7369676e6174757265735b305d
2e72657475726e547970652e70726573656e740a313a010a34333a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475
726e547970652e7461670a313a010a34353a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e6465
7074680a383a00000000000000000a35313a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e706f
696e7465652e7461670a313a000a35333a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e706f69
6e7465652e64657074680a383a00000000000000010a35363a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e
547970652e706f696e7465652e61746f6d2e7461670a313a030a36323a617574686f726564496e707574732e7369676e6174757265735b305d2e7265
7475726e547970652e706f696e7465652e61746f6d2e6e616d65644b696e640a313a000a35373a617574686f726564496e707574732e7369676e6174
757265735b305d2e72657475726e547970652e706f696e7465652e61746f6d2e6e616d650a363a5061636b65740a35383a617574686f726564496e70
7574732e7369676e6174757265735b305d2e72657475726e547970652e706f696e7465652e7175616c6966696572730a313a010a35363a617574686f
726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e696e646972656374696f6e4c6576656c0a383a000000000000
00010a36333a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e547970652e706f696e7465725175616c696669
6572732e636f756e740a383a00000000000000010a36303a617574686f726564496e707574732e7369676e6174757265735b305d2e72657475726e54
7970652e706f696e7465725175616c6966696572735b305d0a313a060a34373a617574686f726564496e707574732e7369676e6174757265735b305d
2e706172616d657465724c69737453746174650a313a010a34353a617574686f726564496e707574732e7369676e6174757265735b305d2e70617261
6d65746572732e636f756e740a383a00000000000000010a34373a617574686f726564496e707574732e7369676e6174757265735b305d2e70617261
6d65746572735b305d2e6e616d650a353a76616c75650a35313a617574686f726564496e707574732e7369676e6174757265735b305d2e706172616d
65746572735b305d2e747970652e7461670a313a000a35333a617574686f726564496e707574732e7369676e6174757265735b305d2e706172616d65
746572735b305d2e747970652e64657074680a383a00000000000000000a35363a617574686f726564496e707574732e7369676e6174757265735b30
5d2e706172616d65746572735b305d2e747970652e61746f6d2e7461670a313a010a36333a617574686f726564496e707574732e7369676e61747572
65735b305d2e706172616d65746572735b305d2e747970652e61746f6d2e7363616c61724b696e640a313a070a35383a617574686f726564496e7075
74732e7369676e6174757265735b305d2e706172616d65746572735b305d2e747970652e7175616c6966696572730a313a000a34323a617574686f72
6564496e707574732e7369676e6174757265735b305d2e766172696164696353746174650a313a010a34323a617574686f726564496e707574732e73
69676e6174757265735b305d2e6e6f52657475726e53746174650a313a010a33333a617574686f726564496e707574732e6170706c69656454797065
732e636f756e740a383a00000000000000010a33383a617574686f726564496e707574732e6170706c69656454797065735b305d2e61646472657373
0a383a00000001000020000a34323a617574686f726564496e707574732e6170706c69656454797065735b305d2e7375626a6563744b696e640a313a
000a34393a617574686f726564496e707574732e6170706c69656454797065735b305d2e74797065446566696e6974696f6e4e616d650a363a506163
6b65740a34303a617574686f726564496e707574732e6170706c69656454797065735b305d2e62797465436f756e740a383a00000000000000100a33
363a617574686f726564496e707574732e74797065446566696e6974696f6e732e636f756e740a383a00000000000000010a33383a617574686f7265
64496e707574732e74797065446566696e6974696f6e735b305d2e6b696e640a313a000a33383a617574686f726564496e707574732e747970654465
66696e6974696f6e735b305d2e6e616d650a363a5061636b65740a35343a617574686f726564496e707574732e74797065446566696e6974696f6e73
5b305d2e6c61796f757452756c65732e69735061636b65640a313a000a36373a617574686f726564496e707574732e74797065446566696e6974696f
6e735b305d2e6c61796f757452756c65732e7061636b416c69676e6d656e742e70726573656e740a313a010a36353a617574686f726564496e707574
732e74797065446566696e6974696f6e735b305d2e6c61796f757452756c65732e7061636b416c69676e6d656e742e76616c75650a383a0000000000
0000080a37303a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6c61796f757452756c65732e6d696e696d756d
416c69676e6d656e742e70726573656e740a313a000a34363a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e66
69656c64732e636f756e740a383a00000000000000010a34383a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e
6669656c64735b305d2e6e616d650a383a68616e646c6572730a35353a617574686f726564496e707574732e74797065446566696e6974696f6e735b
305d2e6669656c64735b305d2e73746f726167652e7461670a313a010a35373a617574686f726564496e707574732e74797065446566696e6974696f
6e735b305d2e6669656c64735b305d2e73746f726167652e64657074680a383a00000000000000000a35373a617574686f726564496e707574732e74
797065446566696e6974696f6e735b305d2e6669656c64735b305d2e73746f726167652e636f756e740a383a00000000000000020a36333a61757468
6f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e73746f726167652e656c656d656e742e7461670a
313a030a36353a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e73746f726167652e65
6c656d656e742e64657074680a383a00000000000000010a36343a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d
2e6669656c64735b305d2e73746f726167652e656c656d656e742e6b696e640a313a010a36303a617574686f726564496e707574732e747970654465
66696e6974696f6e735b305d2e6669656c64735b305d2e62697457696474682e70726573656e740a313a000a36383a617574686f726564496e707574
732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d656e742e70726573656e740a313a010a
36363a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d
656e742e76616c75650a383a00000000000000080a37323a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669
656c64735b305d2e6d696e696d756d416c69676e6d656e74547970652e70726573656e740a313a010a36383a617574686f726564496e707574732e74
797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d656e74547970652e7461670a313a000a37303a
617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d656e74
547970652e64657074680a383a00000000000000010a37333a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e66
69656c64735b305d2e6d696e696d756d416c69676e6d656e74547970652e61746f6d2e7461670a313a010a38303a617574686f726564496e70757473
2e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d696e696d756d416c69676e6d656e74547970652e61746f6d2e7363616c
61724b696e640a313a070a37353a617574686f726564496e707574732e74797065446566696e6974696f6e735b305d2e6669656c64735b305d2e6d69
6e696d756d416c69676e6d656e74547970652e7175616c6966696572730a313a000a36343a617574686f726564496e707574732e7479706544656669
6e6974696f6e735b305d2e6669656c64735b305d2e70726f6d6f746573496e6c696e654669656c64730a313a000a31373a627564676574732e70726f
66696c6549440a32343a6e61746976652d70726f647563742d6275646765742d76310a32303a627564676574732e6d6178436f646542797465730a37
3a313034383537360a32333a627564676574732e6d6178496e737472756374696f6e730a353a36353533360a32313a627564676574732e6d61784f70
65726174696f6e730a363a3236323134340a32323a627564676574732e6d61784f757470757442797465730a373a313034383537360a33313a627564
676574732e6d617857616c6c54696d654d696c6c697365636f6e64730a343a353030300a

)HEX";
constexpr std::string_view kGoldenDigest =
    "c8e8824e8c389be6f640b875fe303668449a3898bfd8db34acbd32440da28a81";
constexpr std::string_view kContextProfilePreimageHex = R"HEX(
363a646f6d61696e0a34393a636f6d2e6a656666636f6f6e65792e4d616353636f70652e6e61746976652d636f6e746578742d70726f66696c652e76
310a393a70726f66696c6549440a33363a6170706c652d616172636836342d7061632d76697369626c652d636c6f626265722d76310a31303a6c616e
677561676549440a32363a414152434836343a4c453a36343a4170706c6553696c69636f6e0a31343a636f6d70696c65725370656349440a373a6465
6661756c740a31333a636f6e746578742e636f756e740a313a340a31353a636f6e746578745b305d2e6e616d650a373a53686f775041430a31363a63
6f6e746578745b305d2e76616c75650a313a310a31353a636f6e746578745b315d2e6e616d650a31313a5041435f636c6f626265720a31363a636f6e
746578745b315d2e76616c75650a313a310a31353a636f6e746578745b325d2e6e616d650a373a53686f774254490a31363a636f6e746578745b325d
2e76616c75650a313a300a31353a636f6e746578745b335d2e6e616d650a31303a53686f774d656d5461670a31363a636f6e746578745b335d2e7661
6c75650a313a300a

)HEX";
constexpr std::string_view kContextProfileDigest =
    "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5";
constexpr std::size_t kMaximumCanonicalAuthoredBytes = 1'048'576;

int failures = 0;

void check(bool condition, std::string_view message) {
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}
template <typename Function>
void expectContractError(Function&& function, std::string_view message) {
    try {
        std::forward<Function>(function)();
        ++failures;
        std::cerr << "FAIL: expected ContractError: " << message << '\n';
    } catch (const ContractError&) {
    }
}

std::vector<std::uint8_t> decodeHex(std::string_view text) {
    auto nibble = [](char value) -> std::uint8_t {
        if (value >= '0' && value <= '9') return static_cast<std::uint8_t>(value - '0');
        if (value >= 'a' && value <= 'f') return static_cast<std::uint8_t>(value - 'a' + 10);
        if (value >= 'A' && value <= 'F') return static_cast<std::uint8_t>(value - 'A' + 10);
        throw std::runtime_error("invalid frozen hexadecimal literal");
    };
    std::vector<std::uint8_t> output;
    std::optional<std::uint8_t> upper;
    for (const char character : text) {
        if (std::isspace(static_cast<unsigned char>(character)) != 0) continue;
        const auto value = nibble(character);
        if (!upper) upper = value;
        else {
            output.push_back(static_cast<std::uint8_t>((*upper << 4U) | value));
            upper.reset();
        }
    }
    if (upper) throw std::runtime_error("odd frozen hexadecimal literal");
    return output;
}

std::string sha256Hex(std::span<const std::uint8_t> bytes) {
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
    if (bytes.size() > std::numeric_limits<CC_LONG>::max()) {
        throw std::runtime_error("test SHA-256 input exceeds CommonCrypto bound");
    }
    (void)CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest.data());
    constexpr char digits[] = "0123456789abcdef";
    std::string output(digest.size() * 2U, '0');
    for (std::size_t index = 0; index < digest.size(); ++index) {
        output[index * 2U] = digits[digest[index] >> 4U];
        output[index * 2U + 1U] = digits[digest[index] & 0x0fU];
    }
    return output;
}

AuthoredType scalarType(AuthoredScalarKind kind, std::uint8_t qualifiers = 0) {
    return {
        AuthoredTypeTag::qualifiedValue,
        AuthoredQualifiedValue{
            AuthoredAtom{AuthoredAtomTag::scalar, AuthoredAtomPayload{kind}},
            qualifiers,
        },
    };
}

AuthoredType namedPacketPointer() {
    auto pointee = AuthoredType{
        AuthoredTypeTag::qualifiedValue,
        AuthoredQualifiedValue{
            AuthoredAtom{
                AuthoredAtomTag::named,
                AuthoredAtomPayload{AuthoredNamedAtom{AuthoredNamedKind::struct_, "Packet"}},
            },
            static_cast<std::uint8_t>(AuthoredQualifier::constant),
        },
    };
    return {
        AuthoredTypeTag::dataPointer,
        AuthoredDataPointer{
            std::make_shared<AuthoredType>(std::move(pointee)),
            1,
            {static_cast<std::uint8_t>(
                static_cast<std::uint8_t>(AuthoredQualifier::volatile_) |
                static_cast<std::uint8_t>(AuthoredQualifier::restrict_)
            )},
        },
    };
}

AuthoredInputs nonemptyAuthoredInputs() {
    const auto scalar = scalarType(AuthoredScalarKind::unsigned32);
    auto carrier = AuthoredFieldStorage{
        AuthoredFieldStorageTag::opaquePointerCarrier,
        AuthoredOpaquePointerCarrierStorage{AuthoredOpaquePointerCarrierKind::pointerToArray},
    };
    auto fixedCarrier = AuthoredFieldStorage{
        AuthoredFieldStorageTag::fixedArray,
        AuthoredFixedArrayStorage{
            std::make_shared<AuthoredFieldStorage>(std::move(carrier)),
            2,
        },
    };
    auto field = AuthoredRecordField{
        "handlers",
        std::make_shared<AuthoredFieldStorage>(std::move(fixedCarrier)),
        std::nullopt,
        8,
        std::make_shared<AuthoredType>(scalar),
        false,
    };

    AuthoredInputs inputs;
    inputs.schemaVersion = 1;
    inputs.names = {{0x1'0000'1000ULL, AuthoredNameSubjectKind::function, "entry"}};
    inputs.signatures = {{
        0x1'0000'1000ULL,
        std::make_shared<AuthoredType>(namedPacketPointer()),
        AuthoredParameterListState::authoritative,
        {AuthoredParameter{"value", scalar}},
        AuthoredVariadicState::fixed,
        AuthoredNoReturnState::returns,
    }};
    inputs.appliedTypes = {{
        0x1'0000'2000ULL,
        AuthoredAppliedTypeSubjectKind::memoryObject,
        "Packet",
        16,
    }};
    inputs.typeDefinitions = {{
        AuthoredTypeDefinitionKind::recordStruct,
        "Packet",
        AuthoredRecordDefinition{
            AuthoredNamedKind::struct_,
            AuthoredLayoutRules{false, 8, std::nullopt},
            {std::move(field)},
        },
    }};
    return canonicalizedAuthoredInputs(std::move(inputs));
}

struct Fixture final {
    TargetProfile target;
    ImageIdentity image;
    FunctionIdentity function;
    ByteProvider bytes;
    SymbolProvider symbols;
    AuthoredInputs authoredInputs;
    ProfiledAnalysisBudgets budgets;
};

Fixture makeFixture(
    std::optional<AuthoredInputs> authoredInputs = std::nullopt,
    std::size_t memoryByteCount = 4
) {
    std::vector<std::uint8_t> raw(memoryByteCount, 0);
    std::vector<std::uint8_t> effective(memoryByteCount, 0);
    if (memoryByteCount == 4) effective = {0x1f, 0x20, 0x03, 0xd5};
    else {
        std::fill(raw.begin(), raw.end(), 0xa5);
        std::fill(effective.begin(), effective.end(), 0x5a);
    }
    return {
        normalizeAppleMachOTarget(
            0x0100'000cU,
            0x8000'0002U,
            std::string(64, 'a'),
            4
        ),
        {"image.main", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 0x1'0000'0000ULL},
        {"function.entry", "entry", 0x1'0000'1000ULL, 0x1'0000'1004ULL},
        ByteProvider({{
            "__text",
            0x1'0000'1000ULL,
            "r-x",
            std::move(raw),
            std::move(effective),
            {"patch000001"},
        }}),
        SymbolProvider({{"image.main", 0x1'0000'1000ULL, "_entry", "function"}}),
        authoredInputs ? canonicalizedAuthoredInputs(std::move(*authoredInputs))
                       : nonemptyAuthoredInputs(),
        productAnalysisBudgetsV1(),
    };
}

CanonicalRequestV2View view(const Fixture& fixture) {
    return {
        std::cref(fixture.target),
        std::cref(fixture.image),
        std::cref(fixture.function),
        std::cref(fixture.bytes),
        std::cref(fixture.symbols),
        std::cref(fixture.authoredInputs),
        std::cref(fixture.budgets),
    };
}

std::size_t tokenByteCount(std::size_t payloadByteCount) {
    return std::to_string(payloadByteCount).size() + 1U + payloadByteCount + 1U;
}

std::size_t fieldByteCount(std::string_view name, std::size_t valueByteCount) {
    return tokenByteCount(name.size()) + tokenByteCount(valueByteCount);
}

std::size_t expectedNamesOnlyCanonicalByteCount(const std::vector<std::size_t>& lengths) {
    std::size_t count = fieldByteCount(
        "domain",
        std::string_view("org.macscope.MacScope.native-authored-input.v1").size()
    );
    count += fieldByteCount("authoredInputs.schemaVersion", 8);
    count += fieldByteCount("authoredInputs.names.count", 8);
    for (std::size_t index = 0; index < lengths.size(); ++index) {
        const auto prefix = "authoredInputs.names[" + std::to_string(index) + "]";
        count += fieldByteCount(prefix + ".address", 8);
        count += fieldByteCount(prefix + ".subjectKind", 1);
        count += fieldByteCount(prefix + ".name", lengths[index]);
    }
    count += fieldByteCount("authoredInputs.signatures.count", 8);
    count += fieldByteCount("authoredInputs.appliedTypes.count", 8);
    count += fieldByteCount("authoredInputs.typeDefinitions.count", 8);
    return count;
}

std::vector<std::size_t> nameLengthsForCanonicalByteCount(std::size_t target) {
    constexpr std::size_t minimumLength = 1;
    constexpr std::size_t maximumLength = 1'024;
    const auto minimumToken = tokenByteCount(minimumLength);
    const auto maximumDelta = tokenByteCount(maximumLength) - minimumToken;
    std::unordered_map<std::size_t, std::size_t> deltaToLength;
    for (std::size_t length = minimumLength; length <= maximumLength; ++length) {
        deltaToLength[tokenByteCount(length) - minimumToken] = length;
    }

    for (std::size_t nameCount = 2; nameCount <= 4'096; ++nameCount) {
        const std::vector<std::size_t> zeroLengths(nameCount, 0);
        const auto fixedSize =
            expectedNamesOnlyCanonicalByteCount(zeroLengths) -
            nameCount * tokenByteCount(0);
        if (target < fixedSize) continue;
        const auto required = target - fixedSize;
        const auto minimum = nameCount * minimumToken;
        const auto maximum = nameCount * tokenByteCount(maximumLength);
        if (required < minimum || required > maximum) continue;

        std::vector<std::size_t> lengths(nameCount, minimumLength);
        auto remaining = required - minimum;
        const auto filled = std::min(nameCount - 2, remaining / maximumDelta);
        std::fill_n(lengths.begin(), filled, maximumLength);
        remaining -= filled * maximumDelta;
        for (std::size_t first = minimumLength; first <= maximumLength; ++first) {
            const auto firstDelta = tokenByteCount(first) - minimumToken;
            if (firstDelta > remaining) break;
            const auto second = deltaToLength.find(remaining - firstDelta);
            if (second == deltaToLength.end()) continue;
            lengths[filled] = first;
            lengths[filled + 1] = second->second;
            if (expectedNamesOnlyCanonicalByteCount(lengths) == target) return lengths;
        }
    }
    throw std::runtime_error("unable to construct exact authored canonical byte count");
}

AuthoredInputs namesOnlyInputs(const std::vector<std::size_t>& lengths) {
    AuthoredInputs inputs;
    inputs.schemaVersion = 1;
    for (std::size_t index = 0; index < lengths.size(); ++index) {
        inputs.names.push_back({
            static_cast<Address>(index),
            AuthoredNameSubjectKind::function,
            std::string(lengths[index], 'n'),
        });
    }
    return canonicalizedAuthoredInputs(std::move(inputs));
}

std::size_t authoredPrefixOffset(std::span<const std::uint8_t> bytes) {
    std::size_t cursor = 0;
    while (cursor < bytes.size()) {
        const auto fieldStart = cursor;
        auto readToken = [&]() -> std::span<const std::uint8_t> {
            const auto lengthStart = cursor;
            while (cursor < bytes.size() && bytes[cursor] != ':') ++cursor;
            if (cursor == bytes.size()) throw std::runtime_error("malformed canonical token");
            const std::string lengthText(
                reinterpret_cast<const char*>(bytes.data() + lengthStart),
                cursor - lengthStart
            );
            const auto length = static_cast<std::size_t>(std::stoull(lengthText));
            ++cursor;
            if (length > bytes.size() - cursor) throw std::runtime_error("truncated token");
            const auto result = bytes.subspan(cursor, length);
            cursor += length;
            if (cursor == bytes.size() || bytes[cursor] != '\n') {
                throw std::runtime_error("missing token terminator");
            }
            ++cursor;
            return result;
        };
        const auto nameBytes = readToken();
        (void)readToken();
        const std::string_view name(
            reinterpret_cast<const char*>(nameBytes.data()),
            nameBytes.size()
        );
        if (name.starts_with("authoredInputs.")) return fieldStart;
    }
    throw std::runtime_error("authored section missing");
}

void testCanonicalRequestV2GoldenPreimage() {
    const auto fixture = makeFixture();
    check(
        canonicalRequestV2(view(fixture)) == decodeHex(kGoldenPreimageHex),
        "native request preimage matches frozen cross-language bytes"
    );
}

void testCanonicalRequestParameterStorage() {
    auto fixture = makeFixture();
    const auto withoutStorage = canonicalRequestV2(view(fixture));
    check(withoutStorage == decodeHex(kGoldenPreimageHex),
          "absent parameter storage preserves the frozen preimage");
    const auto baselineDigest = canonicalRequestSha256V2(view(fixture));
    fixture.authoredInputs.signatures.front().parameters.front().storageRegister = "w20";
    fixture.authoredInputs = canonicalizedAuthoredInputs(std::move(fixture.authoredInputs));
    const auto withStorage = canonicalRequestV2(view(fixture));
    const std::string text(withStorage.begin(), withStorage.end());
    check(text.find("authoredInputs.signatures[0].parameters[0].storage") != std::string::npos &&
              text.find("3:w20\n") != std::string::npos,
          "present parameter storage is preserved and included in the preimage");
    check(canonicalRequestSha256V2(view(fixture)) != baselineDigest,
          "parameter storage changes the request digest");
    for (const auto* invalid : {"", "x 20", "x20\t", "\nx20", "x20\r", "x20\v", "x20\f"}) {
        auto malformed = fixture.authoredInputs;
        malformed.signatures.front().parameters.front().storageRegister = invalid;
        expectContractError([&] { (void)canonicalizedAuthoredInputs(std::move(malformed)); },
                            "empty or whitespace-containing parameter storage is rejected");
    }
}

void testCanonicalRequestV2GoldenDigest() {
    const auto fixture = makeFixture();
    check(
        canonicalRequestSha256V2(view(fixture)) == kGoldenDigest,
        "native request SHA-256 matches frozen cross-language digest"
    );
}

void testCanonicalRequestV2SingleFieldSensitivity() {
    const auto fixture = makeFixture();
    const auto baseline = canonicalRequestSha256V2(view(fixture));

    auto targetChanged = fixture;
    targetChanged.target.rawCpuSubtype = "80000000";
    check(canonicalRequestSha256V2(view(targetChanged)) != baseline, "target leaf");

    auto imageChanged = fixture;
    imageChanged.image.imageId += ".changed";
    check(canonicalRequestSha256V2(view(imageChanged)) != baseline, "image leaf");

    auto functionChanged = fixture;
    functionChanged.function.name += ".changed";
    check(canonicalRequestSha256V2(view(functionChanged)) != baseline, "function leaf");

    auto bytesChanged = fixture;
    auto changedRegions = bytesChanged.bytes.regions();
    changedRegions[0].rawBytes[0] = 1;
    bytesChanged.bytes = ByteProvider(std::move(changedRegions));
    check(canonicalRequestSha256V2(view(bytesChanged)) != baseline, "raw-byte leaf");

    auto symbolsChanged = fixture;
    auto changedSymbols = symbolsChanged.symbols.symbols();
    changedSymbols[0].name += ".changed";
    symbolsChanged.symbols = SymbolProvider(std::move(changedSymbols));
    check(canonicalRequestSha256V2(view(symbolsChanged)) != baseline, "symbol leaf");

    auto authoredChanged = fixture;
    authoredChanged.authoredInputs.names[0].name += "X";
    check(canonicalRequestSha256V2(view(authoredChanged)) != baseline, "authored leaf");

    auto budgetChanged = fixture;
    ++budgetChanged.budgets.maxOperations;
    check(canonicalRequestSha256V2(view(budgetChanged)) != baseline, "profiled budget leaf");
}

void testCanonicalRequestV2ExcludesCorrelationAndDigest() {
    const auto fixture = makeFixture();
    const std::string requestIdA = "11111111-2222-3333-4444-555555555555";
    const std::string requestIdB = "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb";
    const std::string digestA(64, '0');
    const std::string digestB(64, 'f');
    check(requestIdA != requestIdB && digestA != digestB, "envelope values differ");
    check(
        canonicalRequestV2(view(fixture)) == canonicalRequestV2(view(fixture)),
        "semantic view structurally excludes correlation and self-digest"
    );
}

void testCanonicalContextProfileV1GoldenDigest() {
    const auto actual = canonicalContextProfileV1();
    check(actual == decodeHex(kContextProfilePreimageHex), "context preimage bytes");
    check(sha256Hex(actual) == kContextProfileDigest, "context SHA-256");
}

void testCanonicalRequestV2AuthoredByteMeterIsPrefixIndependent() {
    auto exactLengths = nameLengthsForCanonicalByteCount(kMaximumCanonicalAuthoredBytes);
    const auto exactInputs = namesOnlyInputs(exactLengths);
    const auto exactFixture = makeFixture(exactInputs, 600'000);
    const auto preimage = canonicalRequestV2(view(exactFixture));
    check(
        authoredPrefixOffset(preimage) > kMaximumCanonicalAuthoredBytes,
        "pre-authored physical prefix exceeds one MiB"
    );

    const auto adjustable = std::find_if(
        exactLengths.begin(),
        exactLengths.end(),
        [](std::size_t length) {
            return length < 1'024 &&
                tokenByteCount(length + 1) == tokenByteCount(length) + 1;
        }
    );
    if (adjustable == exactLengths.end()) {
        check(false, "exact authored fixture has adjustable name");
        return;
    }
    ++*adjustable;
    const auto plusOneFixture = makeFixture(namesOnlyInputs(exactLengths), 600'000);
    expectContractError(
        [&] { (void)canonicalRequestV2(view(plusOneFixture)); },
        "logical authored section rejects exact-limit plus one"
    );
}

void testCanonicalRequestV2RequiresProfiledTargetView() {
    using TargetReference = decltype(CanonicalRequestV2View::target);
    using BudgetReference = decltype(CanonicalRequestV2View::budgets);
    static_assert(std::same_as<TargetReference, std::reference_wrapper<const TargetProfile>>);
    static_assert(
        std::same_as<BudgetReference, std::reference_wrapper<const ProfiledAnalysisBudgets>>
    );
    static_assert(!std::is_default_constructible_v<CanonicalRequestV2View>);
    static_assert(
        !std::is_constructible_v<
            CanonicalRequestV2View,
            std::reference_wrapper<const ImageIdentity>,
            std::reference_wrapper<const FunctionIdentity>,
            std::reference_wrapper<const ByteProvider>,
            std::reference_wrapper<const SymbolProvider>,
            std::reference_wrapper<const AuthoredInputs>
        >
    );

    const auto fixture = makeFixture();
    check(!canonicalRequestV2(view(fixture)).empty(), "profiled target view canonicalizes");
}

void testSparseCodeRangesBindSchemaV4WithoutChangingV3() {
    auto fixture = makeFixture();
    const auto originalV3 = canonicalRequestSha256V2(view(fixture));
    fixture.function.codeRanges = {
        {fixture.function.entryAddress, fixture.function.entryAddress + 4U},
        {fixture.function.entryAddress + 4U, fixture.function.endAddressExclusive},
    };
    auto sparseView = view(fixture);
    sparseView.schemaVersion = 4U;
    const auto sparseDigest = canonicalRequestSha256V2(sparseView);
    check(sparseDigest != originalV3, "sparse v4 range partition changes canonical digest");
    fixture.function.codeRanges = {
        {fixture.function.entryAddress, fixture.function.endAddressExclusive},
    };
    check(canonicalRequestSha256V2(sparseView) != sparseDigest,
          "v4 range boundaries are canonical request authority");
    expectContractError([&] { (void)canonicalRequestV2(view(fixture)); },
                        "v3 cannot silently carry sparse code ranges");
    fixture.function.codeRanges.clear();
    check(canonicalRequestSha256V2(view(fixture)) == originalV3,
          "v3 digest remains byte-identical without sparse ranges");
}

} // namespace

// Authored-input v2 callee signature hint; the same digest is frozen in
// NativeDecompilerWireCanonicalRequestTests.calleeHintGoldenDigest (Swift).
constexpr std::string_view kCalleeHintGoldenDigest =
    "edee0ad39290c6ac2ff6fa65805d3f90b859bea5e512d337a526b6acef0c5d8c";

void testCanonicalRequestCalleeHintGoldenDigest() {
    AuthoredType voidValue;
    voidValue.tag = AuthoredTypeTag::qualifiedValue;
    voidValue.payload = AuthoredQualifiedValue{};
    AuthoredDataPointer pointer;
    pointer.pointee = std::make_shared<AuthoredType>(voidValue);
    pointer.indirectionLevel = 1;
    pointer.pointerQualifiersByLevel = {0U};
    AuthoredType voidPointer;
    voidPointer.tag = AuthoredTypeTag::dataPointer;
    voidPointer.payload = std::move(pointer);
    AuthoredQualifiedValue sizeValue;
    sizeValue.atom.tag = AuthoredAtomTag::darwinAlias;
    sizeValue.atom.payload = AuthoredDarwinAliasKind::sizeT;
    AuthoredType sizeType;
    sizeType.tag = AuthoredTypeTag::qualifiedValue;
    sizeType.payload = std::move(sizeValue);

    CalleeSignatureHint hint;
    hint.name = "_malloc";
    hint.source = CalleeSignatureHintSource::sdk;
    hint.signature.functionAddress = 0x1'0000'2000ULL;
    hint.signature.returnType = std::make_shared<AuthoredType>(std::move(voidPointer));
    hint.signature.parameterListState = AuthoredParameterListState::authoritative;
    hint.signature.parameters = {AuthoredParameter{"size", std::move(sizeType)}};
    hint.signature.variadicState = AuthoredVariadicState::fixed;
    AuthoredInputs inputs;
    inputs.schemaVersion = 2;
    inputs.calleeSignatureHints.push_back(std::move(hint));
    const auto fixture = makeFixture(std::move(inputs));
    check(canonicalRequestSha256V2(view(fixture)) == kCalleeHintGoldenDigest,
          "authored-input v2 callee hint digest matches the frozen cross-language digest");
}

// Authored-input v3 local names; the same digest is frozen in
// NativeDecompilerWireCanonicalRequestTests.localNameGoldenDigest (Swift).
constexpr std::string_view kLocalNameGoldenDigest =
    "876a784d4f673367ce9e1c584628167f42d4cd21f521377257655909cce77c48";

void testCanonicalRequestLocalNameGoldenDigest() {
    AuthoredQualifiedValue unsignedValue;
    unsignedValue.atom.tag = AuthoredAtomTag::scalar;
    unsignedValue.atom.payload = AuthoredScalarKind::unsigned64;
    AuthoredType unsignedType;
    unsignedType.tag = AuthoredTypeTag::qualifiedValue;
    unsignedType.payload = std::move(unsignedValue);
    AuthoredInputs inputs;
    inputs.schemaVersion = 3;
    inputs.localNames.push_back({AuthoredLocalStorageKind::register_, 0, 0U, "x19", "total", nullptr});
    inputs.localNames.push_back({AuthoredLocalStorageKind::stack, -24, 8U, "", "count",
                                 std::make_shared<AuthoredType>(std::move(unsignedType))});
    const auto fixture = makeFixture(canonicalizedAuthoredInputs(std::move(inputs)));
    const auto digest = canonicalRequestSha256V2(view(fixture));
    check(digest == kLocalNameGoldenDigest,
          "authored-input v3 local name digest matches the frozen cross-language digest: " + digest);
}

void testCanonicalRequestBindsTheDocumentOperation() {
    const auto fixture = makeFixture();
    auto documentView = view(fixture);
    documentView.operation = "decompile-document";
    check(canonicalRequestSha256V2(documentView) != canonicalRequestSha256V2(view(fixture)),
          "decompile-document is bound into the request digest");
    auto unknown = view(fixture);
    unknown.operation = "disassemble";
    bool rejected = false;
    try { (void)canonicalRequestSha256V2(unknown); } catch (const ContractError&) { rejected = true; }
    check(rejected, "an unknown operation is rejected");
}

// Shared with NativeDecompilerX86TargetContractTests. The focused mode emits
// production canonical bytes so Swift compares the two implementations directly.
Fixture makeX86ContractFixture() {
    const std::vector<std::uint8_t> code = {0x90, 0x90, 0xc3, 0x90, 0x90, 0x90, 0x90, 0xc3};
    return {
        normalizeAppleMachOTarget(0x0100'0007U, 3U, std::string(64, 'a'), 16),
        {"image.main", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 0x1000},
        {"function.entry", "entry", 0x1001, 0x1008, {{0x1001, 0x1003}, {0x1006, 0x1008}}},
        ByteProvider({{"__text", 0x1000, "r-x", code, code, {}}}),
        SymbolProvider({}), AuthoredInputs{}, productAnalysisBudgetsV1(),
    };
}

void testSealedX86CanonicalIdentity() {
    auto fixture = makeX86ContractFixture();
    auto request = view(fixture);
    request.schemaVersion = 4;
    const auto context = canonicalContextProfileV1(ArchitectureVariant::x86_64);
    check(sha256Hex(context) == fixture.target.contextProfileSha256,
          "x86 context preimage matches sealed digest");
    const auto digest = canonicalRequestSha256V2(request);
    fixture.target.selectedSliceSha256 = std::string(64, 'b');
    check(canonicalRequestSha256V2(request) != digest, "x86 selected slice binds identity");
    fixture.target = normalizeAppleMachOTarget(0x0100'000cU, 0U, std::string(64, 'a'), 16);
    check(canonicalRequestSha256V2(request) != digest, "same bytes under A64 bind different identity");
    expectContractError([] {
        (void)canonicalContextProfileV1(static_cast<ArchitectureVariant>(255));
    }, "unknown context profile rejected");
}

std::string x86ContractHex(const std::vector<std::uint8_t>& bytes) {
    constexpr char hex[] = "0123456789abcdef";
    std::string output;
    output.reserve(bytes.size() * 2);
    for (const auto byte : bytes) {
        output.push_back(hex[byte >> 4]);
        output.push_back(hex[byte & 15]);
    }
    return output;
}

int main(int argc, char** argv) {
    testSealedX86CanonicalIdentity();
    if (argc == 2 && std::string_view(argv[1]) == "--x86-contract") {
        if (failures != 0) return EXIT_FAILURE;
        const auto fixture = makeX86ContractFixture();
        auto request = view(fixture);
        request.schemaVersion = 4;
        std::cout << "context=" << x86ContractHex(canonicalContextProfileV1(ArchitectureVariant::x86_64)) << '\n'
                  << "request=" << x86ContractHex(canonicalRequestV2(request)) << '\n'
                  << "digest=" << canonicalRequestSha256V2(request) << '\n';
        return EXIT_SUCCESS;
    }

    testCanonicalRequestBindsTheDocumentOperation();
    testCanonicalRequestV2GoldenPreimage();
    testCanonicalRequestV2GoldenDigest();
    testCanonicalRequestParameterStorage();
    testCanonicalRequestCalleeHintGoldenDigest();
    testCanonicalRequestLocalNameGoldenDigest();
    testCanonicalRequestV2SingleFieldSensitivity();
    testCanonicalRequestV2ExcludesCorrelationAndDigest();
    testCanonicalContextProfileV1GoldenDigest();
    testCanonicalRequestV2AuthoredByteMeterIsPrefixIndependent();
    testCanonicalRequestV2RequiresProfiledTargetView();
    testSparseCodeRangesBindSchemaV4WithoutChangingV3();

    if (failures != 0) {
        std::cerr << failures << " canonical-request test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "MacScope native canonical-request tests passed\n";
    return EXIT_SUCCESS;
}
