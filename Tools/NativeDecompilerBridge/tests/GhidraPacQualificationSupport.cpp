#include "GhidraPacQualificationSupport.hpp"

#include "GhidraArchitectureInternal.hpp"
#include "GhidraRuntimeInternal.hpp"
#include "PcodeOpcodeVocabulary.hpp"

#include <ghidra/opcodes.hh>
#include <ghidra/translate.hh>
#include <ghidra/xml.hh>

#include <array>
#include <sstream>
#include <string>
#include <utility>

namespace macscope::native_decompiler::detail {
namespace {

class QualificationCheckpoint final : public GhidraRequestCheckpoint {
public:
    void checkpoint() const override {}
};

[[nodiscard]] std::string varnodeSignature(const ghidra::VarnodeData& varnode) {
    std::ostringstream stream;
    stream << (varnode.space == nullptr ? "null" : varnode.space->getName())
           << ':' << varnode.offset << ':' << varnode.size;
    return stream.str();
}

class QualificationEmitter final : public ghidra::PcodeEmit {
public:
    explicit QualificationEmitter(std::vector<std::string> userOperationNamesValue)
        : userOperationNames(std::move(userOperationNamesValue)) {}

    void dump(
        const ghidra::Address&,
        ghidra::OpCode opcode,
        ghidra::VarnodeData* output,
        ghidra::VarnodeData* inputs,
        ghidra::int4 inputCount
    ) override {
        const auto rawOpcode = static_cast<int>(opcode);
        const auto* canonicalName = canonicalOpcodeName(opcode);
        if (adjudicatePcodeOpcode(rawOpcode, canonicalName) !=
            PcodeOpcodeAdjudication::representable) {
            throw ContractError("qualification-operation-opcode-unavailable");
        }
        std::string operation(canonicalName);
        if (opcode == ghidra::CPUI_CALLOTHER && inputCount > 0 &&
            inputs[0].space != nullptr && inputs[0].space->getType() == ghidra::IPTR_CONSTANT &&
            inputs[0].offset < userOperationNames.size()) {
            operation = userOperationNames[static_cast<std::size_t>(inputs[0].offset)];
        }
        operations.emplace_back(std::move(operation));

        std::string signature = output == nullptr ? "-" : varnodeSignature(*output);
        for (ghidra::int4 index = 0; index < inputCount; ++index) {
            signature += '>';
            signature += varnodeSignature(inputs[index]);
        }
        dataflow.emplace_back(std::move(signature));
    }

    std::vector<std::string> operations;
    std::vector<std::string> dataflow;

private:
    std::vector<std::string> userOperationNames;
};

struct TranslationObservation final {
    std::vector<std::string> operations;
    std::vector<std::string> dataflow;
};

[[nodiscard]] TranslationObservation observeTranslation(
    const AnalysisRequestView& request,
    const TargetProfile& target,
    bool hidden
) {
    GhidraExecutionLock executionLock;
    QualificationCheckpoint checkpoint;
    const CancellationToken cancellation;
    std::ostringstream diagnostics;
    ghidra::DocumentStorage storage;
    GhidraArchitecture architecture(
        request,
        cancellation,
        checkpoint,
        executionLock,
        request.languageId + ':' + request.compilerSpecId,
        diagnostics,
        GhidraReadinessFault::none
    );
    architecture.initialize(storage);
    auto* codeSpace = architecture.getDefaultCodeSpace();
    if (codeSpace == nullptr || architecture.context == nullptr || architecture.translate == nullptr) {
        throw ContractError("native-pac-qualification-architecture-unavailable");
    }

    auto context = target.context;
    if (hidden) {
        context[0].value = 0;
        context[1].value = 0;
    }
    for (Address address = request.function.entryAddress;
         address < request.function.endAddressExclusive;
         address += 4U) {
        const ghidra::Address instructionAddress(codeSpace, address);
        for (const auto& value : context) {
            architecture.context->setVariable(value.name, instructionAddress, value.value);
        }
    }

    std::vector<std::string> userOperationNames;
    architecture.translate->getUserOpNames(userOperationNames);
    QualificationEmitter emitter(std::move(userOperationNames));
    for (Address address = request.function.entryAddress;
         address < request.function.endAddressExclusive;
         address += 4U) {
        architecture.translate->oneInstruction(emitter, ghidra::Address(codeSpace, address));
    }
    return {std::move(emitter.operations), std::move(emitter.dataflow)};
}

} // namespace

PacQualificationObservation observeHiddenPacProfileForTesting(
    const AnalysisRequestView& request,
    std::uint32_t rawCpuSubtype
) {
    auto target = normalizeAppleMachOTarget(
        0x0100'000cU,
        rawCpuSubtype,
        std::string(64U, 'c'),
        request.functionBytes().size()
    );
    auto visible = observeTranslation(request, target, false);
    auto hidden = observeTranslation(request, target, true);
    return {
        .target = std::move(target),
        .visibleOperations = std::move(visible.operations),
        .visibleDataflow = std::move(visible.dataflow),
        .hiddenOperations = std::move(hidden.operations),
        .hiddenDataflow = std::move(hidden.dataflow),
    };
}

} // namespace macscope::native_decompiler::detail
