#pragma once

#include <ghidra/libdecomp.hh>

#include <algorithm>
#include <array>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

namespace macscope::native_decompiler::detail {

inline std::string symbolVariableIdentity(std::uint64_t symbol, std::int64_t offset) {
    std::array<char, 16> encoded{};
    encoded.fill('0');
    std::array<char, 16> digits{};
    const auto converted = std::to_chars(digits.data(), digits.data() + digits.size(), symbol, 16);
    const auto count = static_cast<std::size_t>(converted.ptr - digits.data());
    std::copy_n(digits.data(), count, encoded.data() + encoded.size() - count);
    auto identity = "variable:symbol:" + std::string(encoded.data(), encoded.size());
    if (offset >= 0) identity.append(":" + std::to_string(offset));
    return identity;
}

inline std::string highVariableIdentity(
    std::string_view symbolIdentity,
    std::string_view firstOperation,
    std::optional<std::size_t> inputSlot
) {
    auto identity = std::string(symbolIdentity) + ":high:" + std::string(firstOperation);
    identity.append(inputSlot ? ":in:" + std::to_string(*inputSlot) : ":out");
    return identity;
}

// One symbol/offset may describe several actual native HighVariables. Native
// operation order and input/output roles give each one an unambiguous first
// witness within this function. Pointers are used only in the transient seen
// set; no pointer, traversal counter, hash or guessed alias enters an ID.
// Keep old IDs for symbols with one native high; qualify every member of a
// colliding group before emitting it, independent of record equality.
template <typename Operations, typename Build, typename Emit, typename Checkpoint>
void indexDistinctHighVariables(
    const Operations& operations, Build build, Emit emit, Checkpoint checkpoint
) {
    struct Witness final {
        const ghidra::HighVariable* high;
        std::string operation;
        std::optional<std::size_t> inputSlot;
        std::optional<std::string> symbolIdentity;
    };
    std::vector<Witness> highs;
    std::unordered_set<const ghidra::HighVariable*> seen;
    std::map<std::string, std::size_t> symbolCounts;
    const auto consider = [&](const ghidra::Varnode* varnode, const std::string& operation,
                              std::optional<std::size_t> slot) {
        if (varnode == nullptr || varnode->isAnnotation() || varnode->isConstant() ||
            varnode->isImplied() || varnode->isSpacebase() || varnode->isUnaffected()) return;
        const auto* high = varnode->getHigh();
        if (high == nullptr || !seen.insert(high).second) return;
        std::optional<std::string> identity;
        const auto* symbol = high->getSymbol();
        if (symbol != nullptr && symbol->getId() != 0U) {
            identity = symbolVariableIdentity(symbol->getId(), high->getSymbolOffset());
            ++symbolCounts[*identity];
        }
        highs.push_back({high, operation, slot, std::move(identity)});
    };
    for (const auto& info : operations) {
        checkpoint();
        consider(info.operation->getOut(), info.id, std::nullopt);
        for (ghidra::int4 slot = 0; slot < info.operation->numInput(); ++slot) {
            consider(info.operation->getIn(slot), info.id, static_cast<std::size_t>(slot));
        }
    }
    for (const auto& witness : highs) {
        checkpoint();
        if (auto record = build(*witness.high); record) {
            if (witness.symbolIdentity && symbolCounts.at(*witness.symbolIdentity) > 1U) {
                record->id = highVariableIdentity(record->id, witness.operation, witness.inputSlot);
            }
            emit(std::move(*record));
        }
    }
}

} // namespace macscope::native_decompiler::detail
