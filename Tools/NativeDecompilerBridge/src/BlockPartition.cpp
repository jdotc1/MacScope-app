#include "BlockPartition.hpp"

#include <algorithm>
#include <iomanip>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <string_view>
#include <unordered_map>
#include <unordered_set>

namespace macscope::native_decompiler {

std::uint32_t requiredWireReplySchemaVersion(const StructuredResult& result) noexcept {
    if (!result.function.codeRanges.empty()) return 4U;
    if (result.blockPartition) return 4U;
    for (const auto& operation : result.operations) {
        if (operation.authenticationEffect.kind ==
            AuthenticationEffectKind::standaloneAuthenticationWithoutTransformedOutput) return 4U;
    }
    return 3U;
}

namespace detail {
namespace {
void require(bool condition, std::string_view reason) {
    if (!condition) throw ContractError(std::string(reason));
}

std::string canonicalBlockId(std::size_t ordinal) {
    std::ostringstream stream;
    stream << "block:cfg:" << std::hex << std::setfill('0') << std::setw(16) << ordinal;
    return stream.str();
}

std::vector<SourceRange> coalescedMembershipRanges(
    const AnalysisRequestView& request,
    const std::vector<const InstructionRecord*>& members
) {
    std::vector<SourceRange> ranges;
    for (const auto* instruction : members) {
        const Address end = instruction->address + static_cast<Address>(instruction->bytes.size());
        if (!ranges.empty() && ranges.back().endAddressExclusive == instruction->address) {
            ranges.back().endAddressExclusive = end;
        } else {
            ranges.push_back({request.image.imageId, instruction->address, end});
        }
    }
    return ranges;
}
} // namespace

void validateBlockPartition(const AnalysisRequestView& request, const StructuredResult& result) {
    if (!result.blockPartition) return;
    const auto& partition = *result.blockPartition;
    constexpr auto u32max = std::numeric_limits<std::uint32_t>::max();
    require(partition.version == 1U, "block-partition-version-unsupported");
    require(!result.blocks.empty() && result.blocks.size() <= u32max &&
        result.edges.size() <= u32max && result.instructions.size() <= u32max &&
        result.operations.size() <= u32max &&
        partition.blocks.size() == result.blocks.size() &&
        partition.instructions.size() == result.instructions.size() &&
        partition.edges.size() == result.edges.size(), "block-partition-cardinality-invalid");
    require(estimatedStructuredResultBytes(result) <= request.budgets.maxOutputBytes,
        "block-partition-output-budget-exceeded");

    std::unordered_map<std::string, const BlockRecord*> blocks;
    std::unordered_map<std::string, const OperationRecord*> operations;
    std::unordered_map<std::string, const EdgeRecord*> edges;
    std::unordered_map<std::string, const VarnodeRecord*> varnodes;
    std::unordered_map<std::string, const AddressSpaceRecord*> spaces;
    for (const auto& block : result.blocks) blocks.emplace(block.id, &block);
    for (const auto& operation : result.operations) operations.emplace(operation.id, &operation);
    for (const auto& edge : result.edges) edges.emplace(edge.id, &edge);
    for (const auto& varnode : result.varnodes) varnodes.emplace(varnode.id, &varnode);
    for (const auto& space : result.addressSpaces) spaces.emplace(space.id, &space);

    std::unordered_map<std::string, const BlockPartitionBlockRecord*> descriptors;
    for (std::size_t ordinal = 0; ordinal < partition.blocks.size(); ++ordinal) {
        const auto& descriptor = partition.blocks[ordinal];
        require(descriptor.ordinal == ordinal && descriptor.blockId == canonicalBlockId(ordinal) &&
            blocks.contains(descriptor.blockId) &&
            descriptors.emplace(descriptor.blockId, &descriptor).second,
            "block-partition-block-identity-invalid");
    }
    require(partition.entryBlockId == partition.blocks.front().blockId &&
        partition.blocks.front().entryAddress == request.function.entryAddress,
        "block-partition-entry-invalid");

    std::unordered_map<std::string, const InstructionRecord*> operationInstructions;
    std::unordered_map<std::string, std::vector<const InstructionRecord*>> members;
    std::unordered_map<std::string, std::set<std::string>> instructionBlocks;
    std::set<Address> boundaries;
    for (std::size_t i = 0; i < result.instructions.size(); ++i) {
        const auto& instruction = result.instructions[i];
        const auto& ownership = partition.instructions[i];
        require(ownership.instructionId == instruction.id &&
            (i == 0U || result.instructions[i - 1U].address < instruction.address),
            "block-partition-instruction-order-invalid");
        boundaries.insert(instruction.address);
        for (const auto& id : instruction.operationIds) operationInstructions.emplace(id, &instruction);
        if (ownership.disposition == "eliminated") {
            require(ownership.spans.empty() && instruction.operationIds.empty(),
                "block-partition-eliminated-instruction-invalid");
            continue;
        }
        require(ownership.disposition == "retained" && !ownership.spans.empty() &&
            ownership.spans.size() <= partition.blocks.size(), "block-partition-disposition-invalid");
        std::size_t cursor = 0U;
        std::optional<std::uint32_t> previousOrdinal;
        for (const auto& span : ownership.spans) {
            const auto found = descriptors.find(span.blockId);
            require(found != descriptors.end(), "block-partition-span-block-invalid");
            const auto ordinal = found->second->ordinal;
            require((!previousOrdinal || *previousOrdinal < ordinal) &&
                span.firstOperationIndex == cursor && cursor <= instruction.operationIds.size() &&
                span.operationCount <= instruction.operationIds.size() - cursor,
                "block-partition-span-order-invalid");
            previousOrdinal = ordinal;
            std::optional<std::uint64_t> previousSequence;
            for (std::size_t j = 0; j < span.operationCount; ++j) {
                const auto op = operations.find(instruction.operationIds[cursor + j]);
                require(op != operations.end() && op->second->blockId == span.blockId &&
                    (!previousSequence || *previousSequence < op->second->sequence),
                    "block-partition-span-operation-invalid");
                previousSequence = op->second->sequence;
            }
            cursor += span.operationCount;
            members[span.blockId].push_back(&instruction);
            instructionBlocks[instruction.id].insert(span.blockId);
        }
        require(cursor == instruction.operationIds.size(), "block-partition-span-coverage-invalid");
    }

    std::unordered_set<std::string> ownedOperations;
    for (const auto& block : result.blocks) {
        const auto* descriptor = descriptors.at(block.id);
        const auto ranges = coalescedMembershipRanges(request, members[block.id]);
        require(!ranges.empty() && descriptor->sourceRanges == ranges &&
            block.startAddress == ranges.front().startAddress &&
            block.endAddressExclusive == ranges.back().endAddressExclusive &&
            boundaries.contains(descriptor->entryAddress) &&
            std::any_of(ranges.begin(), ranges.end(), [&](const SourceRange& range) {
                return descriptor->entryAddress >= range.startAddress &&
                    descriptor->entryAddress < range.endAddressExclusive;
            }), "block-partition-source-provenance-invalid");
        for (std::size_t sequence = 0; sequence < block.operationIds.size(); ++sequence) {
            const auto op = operations.find(block.operationIds[sequence]);
            require(op != operations.end() && op->second->blockId == block.id &&
                op->second->sequence == sequence && ownedOperations.insert(op->first).second,
                "block-partition-operation-ownership-invalid");
        }
    }
    require(ownedOperations.size() == result.operations.size(),
        "block-partition-operation-coverage-invalid");

    std::unordered_map<std::string, const BlockPartitionEdgeRecord*> edgeMetadata;
    std::unordered_map<std::string, std::map<std::uint32_t, const EdgeRecord*>> outgoing, incoming;
    for (std::size_t i = 0; i < partition.edges.size(); ++i) {
        const auto& metadata = partition.edges[i];
        const auto found = edges.find(metadata.edgeId);
        require(found != edges.end() && (i == 0U || partition.edges[i - 1U].edgeId < metadata.edgeId) &&
            edgeMetadata.emplace(metadata.edgeId, &metadata).second,
            "block-partition-edge-identity-invalid");
        const auto& edge = *found->second;
        require(blocks.contains(edge.sourceBlockId) && edge.targetBlockId &&
            blocks.contains(*edge.targetBlockId) &&
            edge.targetAddress == descriptors.at(*edge.targetBlockId)->entryAddress,
            "block-partition-edge-target-invalid");
        require(metadata.sourceSlot < blocks.at(edge.sourceBlockId)->successorEdgeIds.size() &&
            metadata.targetSlot < blocks.at(*edge.targetBlockId)->predecessorEdgeIds.size() &&
            outgoing[edge.sourceBlockId].emplace(metadata.sourceSlot, &edge).second &&
            incoming[*edge.targetBlockId].emplace(metadata.targetSlot, &edge).second,
            "block-partition-edge-slot-invalid");
        const auto& kind = metadata.transferKind;
        require(kind == "direct" || kind == "rewritten-direct" || kind == "intra-instruction" ||
            kind == "rewritten-intra-instruction" || kind == "fallthrough" || kind == "indirect" || kind == "splice",
            "block-partition-transfer-kind-invalid");
    }
    for (const auto& block : result.blocks) {
        require(outgoing[block.id].size() == block.successorEdgeIds.size() &&
            incoming[block.id].size() == block.predecessorEdgeIds.size(),
            "block-partition-adjacency-cardinality-invalid");
        std::set<std::string> outs, ins;
        for (const auto& [slot, edge] : outgoing[block.id]) { (void)slot; outs.insert(edge->id); }
        for (const auto& [slot, edge] : incoming[block.id]) { (void)slot; ins.insert(edge->id); }
        require(outs == std::set<std::string>(block.successorEdgeIds.begin(), block.successorEdgeIds.end()) &&
            ins == std::set<std::string>(block.predecessorEdgeIds.begin(), block.predecessorEdgeIds.end()),
            "block-partition-adjacency-invalid");
    }
    require(incoming[partition.entryBlockId].empty(), "block-partition-entry-predecessor-invalid");
    std::vector<std::string> traversal{partition.entryBlockId};
    std::unordered_set<std::string> visited{partition.entryBlockId};
    for (std::size_t i = 0; i < traversal.size(); ++i) {
        require(descriptors.at(traversal[i])->ordinal == i, "block-partition-traversal-order-invalid");
        for (const auto& [slot, edge] : outgoing[traversal[i]]) {
            (void)slot;
            if (visited.insert(*edge->targetBlockId).second) traversal.push_back(*edge->targetBlockId);
        }
    }
    require(traversal.size() == blocks.size(), "block-partition-unreachable-block");

    for (const auto& block : result.blocks) {
        const auto& successors = outgoing[block.id];
        const OperationRecord* last = block.operationIds.empty() ? nullptr : operations.at(block.operationIds.back());
        const auto checkEdge = [&](const EdgeRecord& edge, std::string_view kind,
                                   std::string_view transfer, bool operationRequired) {
            require(edge.kind == kind && edgeMetadata.at(edge.id)->transferKind == transfer &&
                (operationRequired ? (last != nullptr && edge.operationId == last->id) : !edge.operationId),
                "block-partition-terminator-edge-invalid");
        };
        const auto checkDirect = [&](const EdgeRecord& edge) {
            require(last != nullptr && edge.operationId == last->id && !last->inputVarnodeIds.empty(),
                "block-partition-direct-operation-invalid");
            const auto& kind = edgeMetadata.at(edge.id)->transferKind;
            if (kind == "intra-instruction" || kind == "rewritten-intra-instruction") {
                const auto* operand = varnodes.at(last->inputVarnodeIds.front());
                require(!last->directTargetAddress && spaces.at(operand->addressSpaceId)->kind == "constant" &&
                    instructionBlocks.at(operationInstructions.at(last->id)->id).contains(*edge.targetBlockId) ==
                        (kind == "intra-instruction"),
                    "block-partition-relative-target-invalid");
            } else {
                require(last->directTargetAddress && boundaries.contains(*last->directTargetAddress) &&
                    ((kind == "direct" && *last->directTargetAddress == edge.targetAddress) ||
                     (kind == "rewritten-direct" && *last->directTargetAddress != edge.targetAddress)),
                    "block-partition-direct-target-invalid");
            }
        };
        if (last == nullptr) {
            require((successors.empty() && block.terminatorKind == "exit") ||
                (successors.size() == 1U && block.terminatorKind == "splice"),
                "block-partition-empty-terminator-invalid");
            for (const auto& [slot, edge] : successors) { (void)slot; checkEdge(*edge, "splice", "splice", false); }
        } else if (last->opcode == "RETURN") {
            require(successors.empty() && block.terminatorKind == "return", "block-partition-return-invalid");
        } else if (last->opcode == "BRANCH") {
            require(successors.size() == 1U && block.terminatorKind == "branch" &&
                successors.at(0U)->kind == "branch", "block-partition-branch-invalid");
            checkDirect(*successors.at(0U));
        } else if (last->opcode == "CBRANCH") {
            require(successors.size() == 2U && block.terminatorKind == "conditional" &&
                successors.at(0U)->kind == "false" && successors.at(1U)->kind == "true",
                "block-partition-conditional-invalid");
            std::size_t fallthroughCount = 0U;
            for (const auto& [slot, edge] : successors) {
                (void)slot;
                require(edge->operationId == last->id, "block-partition-conditional-operation-invalid");
                if (edgeMetadata.at(edge->id)->transferKind == "fallthrough") ++fallthroughCount;
                else checkDirect(*edge);
            }
            require(fallthroughCount == 1U, "block-partition-conditional-fallthrough-invalid");
        } else if (last->opcode == "BRANCHIND") {
            require(!successors.empty() && block.terminatorKind == "switch", "block-partition-switch-invalid");
            std::size_t defaults = 0U;
            for (const auto& [slot, edge] : successors) {
                (void)slot;
                require(edge->kind == "switchCase" || edge->kind == "switchDefault", "block-partition-switch-edge-invalid");
                if (edge->kind == "switchDefault") ++defaults;
                checkEdge(*edge, edge->kind, "indirect", true);
            }
            require(defaults == 1U, "block-partition-switch-default-invalid");
        } else {
            require((successors.empty() && block.terminatorKind == "exit") ||
                (successors.size() == 1U && block.terminatorKind == "fallthrough"),
                "block-partition-fallthrough-invalid");
            for (const auto& [slot, edge] : successors) { (void)slot; checkEdge(*edge, "fallthrough", "fallthrough", false); }
        }
    }
    // MULTIEQUAL input slots are native predecessor slots, not sorted edge IDs.
    for (const auto& phi : result.phis) {
        require(blocks.contains(phi.blockId) && phi.incoming.size() == incoming[phi.blockId].size(),
            "block-partition-phi-cardinality-invalid");
        for (std::size_t slot = 0; slot < phi.incoming.size(); ++slot) {
            const auto& value = phi.incoming[slot];
            const auto* edge = incoming[phi.blockId].at(static_cast<std::uint32_t>(slot));
            require(value.edgeId == edge->id && value.sourceBlockId == edge->sourceBlockId,
                "block-partition-phi-slot-invalid");
        }
    }
}
} // namespace detail
} // namespace macscope::native_decompiler
