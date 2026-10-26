#include "GhidraBlockPartition.hpp"
#include "GhidraArchitectureInternal.hpp"

#include <ghidra/libdecomp.hh>
#include <algorithm>
#include <optional>
#include <vector>

namespace macscope::native_decompiler::detail {

bool legacyPartitionRepresentable(
    const AnalysisRequestView& request,
    ghidra::Funcdata& function,
    ghidra::AddrSpace* codeSpace,
    std::span<const DecodedInstruction> decoded,
    const GhidraRequestCheckpoint& budget
) {
    const auto& graph = function.getBasicBlocks();
    if (graph.getSize() <= 0) return false;
    std::vector<const ghidra::BlockBasic*> blocks;
    for (ghidra::int4 i = 0; i < graph.getSize(); ++i) {
        budget.checkpoint();
        const auto* candidate = graph.getBlock(i);
        if (candidate == nullptr || candidate->getType() != ghidra::FlowBlock::t_basic) return false;
        const auto* block = static_cast<const ghidra::BlockBasic*>(candidate);
        if (block->beginOp() == block->endOp() || block->getStart().isInvalid() ||
            block->getStop().isInvalid() || block->getEntryAddr().isInvalid() ||
            block->getStart().getSpace() != codeSpace || block->getStop().getSpace() != codeSpace ||
            (block->getEntryAddr() != block->getStart() && !block->isEntryPoint())) return false;
        blocks.push_back(block);
    }
    std::sort(blocks.begin(), blocks.end(), [](const auto* lhs, const auto* rhs) {
        return lhs->getStart().getOffset() < rhs->getStart().getOffset();
    });
    if (blocks.empty() || blocks.front()->getStart().getOffset() != request.function.entryAddress) return false;
    std::size_t cursor = 0U;
    for (std::size_t i = 0; i < blocks.size(); ++i) {
        budget.checkpoint();
        const auto* block = blocks[i];
        const Address start = block->getStart().getOffset();
        const Address end = i + 1U < blocks.size() ? blocks[i + 1U]->getStart().getOffset() :
            request.function.endAddressExclusive;
        if (cursor >= decoded.size() || decoded[cursor].record.address != start || start >= end) return false;
        const auto first = cursor;
        while (cursor < decoded.size() && decoded[cursor].record.address < end) {
            budget.checkpoint();
            if (!block->contains(ghidra::Address(codeSpace, decoded[cursor].record.address))) return false;
            ++cursor;
        }
        if (cursor == first || decoded[cursor - 1U].endAddressExclusive != end ||
            block->getStop().getOffset() != decoded[cursor - 1U].record.address) return false;
        std::optional<Address> previous;
        for (auto op = block->beginOp(); op != block->endOp(); ++op) {
            budget.checkpoint();
            if (*op == nullptr || (*op)->getAddr().isInvalid() || (*op)->getAddr().getSpace() != codeSpace) return false;
            const Address address = (*op)->getAddr().getOffset();
            if (address < start || address >= end || (previous && address < *previous)) return false;
            previous = address;
        }
        const auto* last = block->lastOp();
        if (last->code() == ghidra::CPUI_BRANCH || last->code() == ghidra::CPUI_CBRANCH) {
            const auto* operand = last->numInput() > 0 ? last->getIn(0) : nullptr;
            if (operand == nullptr || !operand->isAnnotation() || operand->getSpace() != codeSpace) return false;
            const auto slot = last->code() == ghidra::CPUI_CBRANCH ? (last->isFallthruTrue() ? 0 : 1) : 0;
            if (slot >= block->sizeOut() || block->getOut(slot) == nullptr ||
                block->getOut(slot)->getStart().isInvalid() ||
                operand->getOffset() != block->getOut(slot)->getStart().getOffset()) return false;
        }
    }
    return cursor == decoded.size();
}

} // namespace macscope::native_decompiler::detail
