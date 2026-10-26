#pragma once

#include "MacScopeNativeDecompiler/OutputModel.hpp"

namespace macscope::native_decompiler::detail {

// Shared by the complete estimator and the native incremental publication meter.
// Charge no presence field when absent: legacy output-size receipts stay unchanged.
template <typename Meter>
void accountBlockPartition(Meter& meter, const BlockPartitionRecord& value) {
    meter.addRecord();
    meter.addScalar();
    meter.addText(value.entryBlockId);
    for (const auto& block : value.blocks) {
        meter.addRecord();
        meter.addText(block.blockId);
        meter.addScalar();
        meter.addScalar();
        for (const auto& range : block.sourceRanges) meter.addSourceRange(range);
    }
    for (const auto& instruction : value.instructions) {
        meter.addRecord();
        meter.addText(instruction.instructionId);
        meter.addText(instruction.disposition);
        for (const auto& span : instruction.spans) {
            meter.addRecord();
            meter.addText(span.blockId);
            meter.addScalar();
            meter.addScalar();
        }
    }
    for (const auto& edge : value.edges) {
        meter.addRecord();
        meter.addText(edge.edgeId);
        meter.addScalar();
        meter.addScalar();
        meter.addText(edge.transferKind);
    }
}

// Requires the ordinary identity, instruction, varnode, and operation checks
// first. Validates all block/ownership/edge-specific final-CFG invariants.
void validateBlockPartition(const AnalysisRequestView& request, const StructuredResult& result);

} // namespace macscope::native_decompiler::detail
