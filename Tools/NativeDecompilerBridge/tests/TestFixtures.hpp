#pragma once

#include "MacScopeNativeDecompiler/Backend.hpp"

#include <algorithm>
#include <string>
#include <vector>

namespace macscope::native_decompiler::test_fixtures {

inline AnalysisBudgets defaultBudgets() {
    return AnalysisBudgets{4096, 256, 4096, 1024 * 1024, 1000};
}

inline AnalysisRequestView makeRequest(AnalysisBudgets budgets = defaultBudgets()) {
    ByteProvider bytes({
        MemoryRegion{
            "__text",
            0x1000,
            "r-x",
            {0x00, 0x00, 0x80, 0xd2, 0xc0, 0x03, 0x5f, 0xd6},
            {0x20, 0x00, 0x80, 0xd2, 0xc0, 0x03, 0x5f, 0xd6},
            {"patch000000"},
        },
        MemoryRegion{
            "__const",
            0x2000,
            "r--",
            {0x01, 0x02, 0x03, 0x04},
            {0x01, 0x02, 0x03, 0x04},
            {},
        },
    });
    SymbolProvider symbols({
        SymbolRecord{"image.main", 0x1000, "_fixture", "function"},
        SymbolRecord{"image.main", 0x1000, "fixture_alias", "alias"},
    });
    TypeHintProvider types({
        TypeHintRecord{"function", 0x1000, "uint64_t fixture(void)", "asserted", "fixture"},
    });
    return AnalysisRequestView(
        "request.fixture",
        std::string(64, 'a'),
        "AARCH64:LE:64:AppleSilicon",
        "default",
        ImageIdentity{"image.main", "00000000-0000-0000-0000-000000000001", 0x1000},
        FunctionIdentity{"function.fixture", "_fixture", 0x1000, 0x1008, {}},
        std::move(bytes),
        std::move(symbols),
        std::move(types),
        budgets
    );
}

inline StructuredResult makeResult(const AnalysisRequestView& request) {
    StructuredResult result;
    result.requestId = request.requestId;
    result.requestSha256 = request.requestSha256;
    result.image = request.image;
    result.function = request.function;
    result.addressSpaces = {
        {"space.ram", "ram", "memory", 8, true},
        {"space.unique", "unique", "temporary", 8, true},
    };
    result.types = {
        TypeRecord{
            .id = "type.u64",
            .kind = "integer",
            .name = "uint64_t",
            .byteSize = 8,
            .isSigned = false,
            .pointeeTypeId = std::nullopt,
            .fields = {},
            .confidence = "high",
            .provenance = "contract-fixture",
            .returnTypeId = std::nullopt,
            .parameterTypeIds = {},
        },
    };
    result.instructions = {
        InstructionRecord{
            .id = "instruction.0",
            .address = 0x1000,
            .bytes = {0x20, 0x00, 0x80, 0xd2},
            .mnemonic = "mov",
            .body = "mov x0, #1",
            .operationIds = {"op.0"},
            .sourceRanges = {{request.image.imageId, 0x1000, 0x1004}},
        },
        InstructionRecord{
            .id = "instruction.1",
            .address = 0x1004,
            .bytes = {0xc0, 0x03, 0x5f, 0xd6},
            .mnemonic = "ret",
            .body = "ret",
            .operationIds = {"op.1"},
            .sourceRanges = {{request.image.imageId, 0x1004, 0x1008}},
        },
    };
    result.varnodes = {
        {"vn.constant.0", "space.unique", 0, 8, "constant", "type.u64", std::nullopt},
        {"vn.x0", "space.unique", 8, 8, "register", "type.u64", "x0"},
    };
    result.operations = {
        {"op.0", "block.0", 0, "COPY", "vn.x0", {"vn.constant.0"}, std::nullopt,
         {{request.image.imageId, 0x1000, 0x1004}}},
        {"op.1", "block.0", 1, "RETURN", std::nullopt, {"vn.x0"}, std::nullopt,
         {{request.image.imageId, 0x1004, 0x1008}}},
    };
    result.blocks = {
        {"block.0", 0x1000, 0x1008, {"op.0", "op.1"}, {}, {}, "return"},
    };
    result.ssaValues = {
        {"ssa.0", "vn.constant.0", "constant", std::nullopt, std::nullopt},
        {"ssa.1", "vn.x0", "operationResult", "op.0", std::nullopt},
    };
    result.ssaBindings = {
        {"op.0", {"ssa.0"}, "ssa.1"},
        {"op.1", {"ssa.1"}, std::nullopt},
    };
    result.memoryVersions = {
        {"memory.entry", "unknown", "functionEntry", std::nullopt, std::nullopt},
        {"memory.after-copy", "unknown", "operationResult", "op.0", std::nullopt},
    };
    result.memoryEffects = {
        {"memory-effect.0", "op.0", "write", "unknown", "memory.entry", "memory.after-copy"},
    };
    result.variables = {
        {"variable.return", "result", "returnValue", "type.u64", {"vn.x0"},
         {{request.image.imageId, 0x1000, 0x1008}}, "synthetic", "contract-fixture"},
    };
    result.regions = {
        {"region.root", "sequence", std::nullopt, {}, {"block.0"}, std::nullopt,
         {{request.image.imageId, 0x1000, 0x1008}}},
    };
    result.tokens = {
        {"token.0", "return", "keyword", 1, 1,
         {{request.image.imageId, 0x1004, 0x1008}}, { {"region", "region.root"} }},
        {"token.1", "1", "integerLiteral", 1, 8,
         {{request.image.imageId, 0x1000, 0x1004}}, { {"variable", "variable.return"} }},
    };
    return result;
}

inline BackendAvailability fullAvailability() {
    return BackendAvailability{
        .available = true,
        .reasonCode = "",
        .identity = BackendIdentity{
            .backendId = "fixture-native-provider",
            .ghidraVersion = "12.1.2",
            .ghidraGitRevision = std::string(40, 'b'),
            .wrapperVersion = "0.1.0",
            .wrapperGitRevision = std::string(40, 'c'),
        },
        .capabilities = BackendCapabilities{
            .nativeDecompilerHeritage = true,
            .completeRegisterSsa = true,
            .memorySsa = true,
            .recoveredVariables = true,
            .recoveredTypes = true,
            .structuredControlFlow = true,
            .tokenizedPseudocode = true,
            .imageQualifiedSourceRanges = true,
        },
        .runtimeIdentity = PreparedGhidraRuntimeIdentity{
            .backendId = "fixture-native-provider",
            .engineVersion = "12.1.2",
            .engineRevision = std::string(40, 'b'),
            .wrapperVersion = "0.1.0",
            .wrapperRevision = std::string(40, 'c'),
            .packageManifestSha256 = std::string(64, 'd'),
            .packageTreeSha256 = std::string(64, 'e'),
            .languageId = "AARCH64:LE:64:AppleSilicon",
            .compilerSpecId = "default",
            .targetProfileId = "apple-aarch64-pac-visible-clobber-v1",
            .contextProfileSha256 =
                "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5",
        },
    };
}

inline void reverseSetLikeCollections(StructuredResult& result) {
    std::reverse(result.instructions.begin(), result.instructions.end());
    std::reverse(result.addressSpaces.begin(), result.addressSpaces.end());
    std::reverse(result.types.begin(), result.types.end());
    std::reverse(result.varnodes.begin(), result.varnodes.end());
    std::reverse(result.operations.begin(), result.operations.end());
    std::reverse(result.blocks.begin(), result.blocks.end());
    std::reverse(result.edges.begin(), result.edges.end());
    std::reverse(result.ssaValues.begin(), result.ssaValues.end());
    std::reverse(result.ssaBindings.begin(), result.ssaBindings.end());
    std::reverse(result.phis.begin(), result.phis.end());
    std::reverse(result.memoryVersions.begin(), result.memoryVersions.end());
    std::reverse(result.memoryPhis.begin(), result.memoryPhis.end());
    std::reverse(result.memoryEffects.begin(), result.memoryEffects.end());
    std::reverse(result.variables.begin(), result.variables.end());
    std::reverse(result.calls.begin(), result.calls.end());
    std::reverse(result.regions.begin(), result.regions.end());
    std::reverse(result.tokens.begin(), result.tokens.end());
    std::reverse(result.warnings.begin(), result.warnings.end());
    for (auto& block : result.blocks) {
        std::reverse(block.predecessorEdgeIds.begin(), block.predecessorEdgeIds.end());
        std::reverse(block.successorEdgeIds.begin(), block.successorEdgeIds.end());
    }
    for (auto& instruction : result.instructions) {
        std::reverse(instruction.sourceRanges.begin(), instruction.sourceRanges.end());
    }
    for (auto& operation : result.operations) {
        std::reverse(operation.sourceRanges.begin(), operation.sourceRanges.end());
    }
    for (auto& variable : result.variables) {
        std::reverse(variable.storageVarnodeIds.begin(), variable.storageVarnodeIds.end());
        std::reverse(variable.liveRanges.begin(), variable.liveRanges.end());
    }
    for (auto& token : result.tokens) {
        std::reverse(token.sourceRanges.begin(), token.sourceRanges.end());
        std::reverse(token.entityReferences.begin(), token.entityReferences.end());
    }
}

inline std::string canonicalSummary(const StructuredResult& result) {
    std::string value;
    for (const auto& instruction : result.instructions) value += instruction.id + ";";
    value += "|";
    for (const auto& operation : result.operations) value += operation.id + ";";
    value += "|";
    for (const auto& block : result.blocks) {
        value += block.id + ":";
        for (const auto& operation : block.operationIds) value += operation + ",";
        value += ";";
    }
    value += "|";
    for (const auto& version : result.memoryVersions) value += version.id + ";";
    value += "|";
    for (const auto& token : result.tokens) value += token.id + ";";
    return value;
}

} // namespace macscope::native_decompiler::test_fixtures
