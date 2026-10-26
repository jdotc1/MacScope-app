#include "MacScopeNativeDecompiler/OutputModel.hpp"
#include "TextValidation.hpp"
#include "BlockPartition.hpp"

#include <algorithm>
#include <array>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <tuple>
#include <unordered_map>
#include <unordered_set>

namespace macscope::native_decompiler {
namespace {

constexpr std::size_t kMaximumTextBytes = 1U << 20U;

void requireBoundedText(
    std::string_view value,
    std::string_view label,
    std::size_t maximum = kMaximumTextBytes,
    bool allowEmpty = false,
    bool allowFormattingControls = false
) {
    if ((!allowEmpty && value.empty()) || value.size() > maximum) {
        throw ContractError(std::string(label) + " must be bounded text");
    }
    if (!detail::isValidUtf8(value)) {
        throw ContractError(std::string(label) + " must be valid UTF-8");
    }
    for (const unsigned char character : value) {
        if (character == 0U) {
            throw ContractError(std::string(label) + " contains an embedded NUL byte");
        }
        const bool permittedFormattingControl = allowFormattingControls &&
            (character == static_cast<unsigned char>('\t') ||
             character == static_cast<unsigned char>('\n') ||
             character == static_cast<unsigned char>('\r'));
        if ((character < 0x20U && !permittedFormattingControl) || character == 0x7fU) {
            throw ContractError(std::string(label) + " contains unsupported control text");
        }
    }
}

void validatePseudocodeDocument(const PseudocodeDocumentRecord& document) {
    requireBoundedText(
        document.text,
        "pseudocode document text",
        kMaximumTextBytes,
        false,
        true
    );
    if (document.text.find('\r') != std::string::npos) {
        throw ContractError("pseudocode document text must use LF line endings");
    }
    requireBoundedText(document.language, "pseudocode document language", 32);
    if (document.language != "c") {
        throw ContractError("pseudocode document language is unsupported");
    }
    if (document.isComplete == document.isTruncated) {
        throw ContractError("pseudocode document requires exactly one completeness state");
    }
}

[[nodiscard]] Address checkedEnd(Address start, std::size_t size, std::string_view label) {
    if (size > std::numeric_limits<Address>::max() - start) {
        throw ContractError(std::string(label) + " range overflows the unsigned 64-bit address space");
    }
    return start + static_cast<Address>(size);
}

[[nodiscard]] bool belongsToFunctionCode(
    const FunctionIdentity& function, Address start, Address end
) {
    if (start >= end) return false;
    if (function.codeRanges.empty()) {
        return start >= function.entryAddress && end <= function.endAddressExclusive;
    }
    Address cursor = start;
    for (const auto& range : function.codeRanges) {
        if (range.endAddressExclusive <= cursor) continue;
        if (range.startAddress > cursor) return false;
        cursor = std::min(end, range.endAddressExclusive);
        if (cursor == end) return true;
    }
    return false;
}

[[nodiscard]] bool instructionInsideFunctionRange(
    const FunctionIdentity& function, Address start, Address end
) {
    if (function.codeRanges.empty()) return belongsToFunctionCode(function, start, end);
    return std::any_of(function.codeRanges.begin(), function.codeRanges.end(),
        [=](const auto& range) {
            return start >= range.startAddress && end <= range.endAddressExclusive;
        });
}

[[nodiscard]] bool addressInsideFunctionCode(const FunctionIdentity& function, Address address) {
    if (function.codeRanges.empty()) {
        return address >= function.entryAddress && address < function.endAddressExclusive;
    }
    return std::any_of(function.codeRanges.begin(), function.codeRanges.end(),
        [=](const auto& range) {
            return address >= range.startAddress && address < range.endAddressExclusive;
        });
}

[[nodiscard]] bool basicBlockBoundsInsideFunction(
    const FunctionIdentity& function, Address start, Address end
) {
    if (belongsToFunctionCode(function, start, end)) return true;
    if (function.codeRanges.empty() || start >= end) return false;
    // A native basic block may branch across a sparse gap. Its extent is the
    // bounding interval; decoded instructions and their source ranges remain
    // individually confined to the admitted code ranges.
    return addressInsideFunctionCode(function, start) &&
        addressInsideFunctionCode(function, end - 1U);
}

template <typename Range, typename Key>
std::unordered_set<std::string> uniqueIds(const Range& values, Key key, std::string_view label) {
    std::unordered_set<std::string> result;
    result.reserve(values.size());
    for (const auto& value : values) {
        const std::string& id = std::invoke(key, value);
        requireBoundedText(id, std::string(label) + " ID", 1024);
        if (!result.insert(id).second) {
            throw ContractError(std::string(label) + " IDs must be unique");
        }
    }
    return result;
}

void requireReference(const std::unordered_set<std::string>& ids, const std::string& id, std::string_view label) {
    requireBoundedText(id, std::string(label) + " ID", 1024);
    if (!ids.contains(id)) {
        throw ContractError(std::string(label) + " references an unknown ID");
    }
}

void validateSourceRange(const AnalysisRequestView& request, const SourceRange& range, std::string_view label) {
    if (range.imageId != request.image.imageId) {
        throw ContractError(std::string(label) + " references a different image");
    }
    if (!belongsToFunctionCode(request.function, range.startAddress, range.endAddressExclusive)) {
        throw ContractError(std::string(label) + " must remain inside the requested function");
    }
}

template <typename Range, typename SourceSelector>
void validateSourceRanges(
    const AnalysisRequestView& request,
    const Range& values,
    SourceSelector selector,
    std::string_view label
) {
    for (const auto& value : values) {
        std::set<std::tuple<std::string, Address, Address>> seen;
        for (const auto& sourceRange : std::invoke(selector, value)) {
            validateSourceRange(request, sourceRange, label);
            if (!seen.emplace(
                    sourceRange.imageId,
                    sourceRange.startAddress,
                    sourceRange.endAddressExclusive
                ).second) {
                throw ContractError(std::string(label) + " contains a duplicate range");
            }
        }
    }
}

[[nodiscard]] bool sourceRangeLess(const SourceRange& lhs, const SourceRange& rhs) {
    return std::tie(lhs.imageId, lhs.startAddress, lhs.endAddressExclusive) <
           std::tie(rhs.imageId, rhs.startAddress, rhs.endAddressExclusive);
}

void canonicalizeSourceRanges(std::vector<SourceRange>& ranges) {
    std::sort(ranges.begin(), ranges.end(), sourceRangeLess);
}

template <typename T, typename Comparator>
void sortOnly(std::vector<T>& values, Comparator comparator) {
    std::sort(values.begin(), values.end(), comparator);
}

template <typename T>
void sortById(std::vector<T>& values) {
    std::sort(values.begin(), values.end(), [](const T& lhs, const T& rhs) { return lhs.id < rhs.id; });
}

constexpr std::size_t kSchemaReserveBytes = 16U * 1024U;
constexpr std::size_t kTextOccurrenceBytes = 8U;
constexpr std::size_t kRecordContainerBytes = 48U;
constexpr std::size_t kNestedContainerBytes = 16U;
constexpr std::size_t kTextObjectBytes = 16U;

class SizeEstimator final {
public:
    explicit SizeEstimator(std::function<void()> checkpoint)
        : checkpoint_(std::move(checkpoint)) {}

    void add(std::size_t value) {
        if (checkpoint_) checkpoint_();
        if (value > std::numeric_limits<std::size_t>::max() - total_) {
            total_ = std::numeric_limits<std::size_t>::max();
        } else {
            total_ += value;
        }
    }

    // native-output-size-v3 bounds the canonical binary plist, not JSON.
    // Under the existing 64 MiB transport/object-count bound, object references
    // and offsets need at most four bytes. Eight per occurrence covers both
    // dictionary key/value references (array elements need only one). Each
    // distinct text gets its content plus sixteen bytes for marker/length/offset.
    // The 16 KiB base reserves the closed codec's schema keys, finite mapped
    // enum spellings, root/image/function dictionaries and collection headers.
    // This requires the reply canonicalizer's exact primitive-object sharing.
    void addText(std::string_view value) {
        add(kTextOccurrenceBytes);
        if (seen_.emplace(value).second) addTextObject(value);
    }

    // Charges a text as its own object even if equal text was seen, without
    // recording it. Used for large presentation text whose fixed overhead is
    // derived from a standalone probe.
    void addUniqueText(std::string_view value) {
        add(kTextOccurrenceBytes);
        addTextObject(value);
    }

    void addProduct(std::size_t count, std::size_t width) {
        if (width != 0U && count > std::numeric_limits<std::size_t>::max() / width) {
            total_ = std::numeric_limits<std::size_t>::max();
        } else {
            add(count * width);
        }
    }

    template <typename T>
    void addScalar(const T&) {
        add(32U);
    }

    void addScalar() { add(32U); }
    // A record has at most three nested arrays. Forty-eight covers their
    // marker/length/offsets, its dictionary and its outer collection reference.
    // Field key/value references are charged by their text/scalar occurrences.
    void addRecord() { add(kRecordContainerBytes); }
    void addSourceRange(const SourceRange& range) {
        add(kNestedContainerBytes);
        addText(range.imageId);
        addText(sourceAddress(range.startAddress));
        addText(sourceAddress(range.endAddressExclusive));
    }
    void addPosition(std::uint32_t value) {
        add(8U);
        // The wire boxes line and column as UInt32. Its canonicalizer deduplicates
        // equal encoded integer objects; sixteen covers even an eight-byte
        // integer payload, marker and four-byte offset. Sharing with any other
        // scalar is deliberately not credited here.
        if (positions_.insert(value).second) add(16U);
    }

    [[nodiscard]] std::size_t value() const noexcept { return total_; }

private:
    static std::string sourceAddress(Address value) {
        // Exact native codec hexUInt64 representation: sixteen lowercase digits,
        // with no prefix. Source addresses share the same text-object pool.
        constexpr char digits[] = "0123456789abcdef";
        std::string text(16U, '0');
        for (std::size_t i = text.size(); i != 0U; --i) {
            text[i - 1U] = digits[value & 0xfU];
            value >>= 4U;
        }
        return text;
    }

    void addTextObject(std::string_view value) {
        add(kTextObjectBytes);
        const bool ascii = std::all_of(value.begin(), value.end(), [](char byte) {
            return static_cast<unsigned char>(byte) < 0x80U;
        });
        addProduct(value.size(), ascii ? 1U : kMaximumEncodedBytesPerTextByte);
    }

    std::function<void()> checkpoint_;
    std::unordered_set<std::string> seen_;
    std::unordered_set<std::uint32_t> positions_;
    std::size_t total_ = kSchemaReserveBytes;
};

void addSourceRanges(SizeEstimator& estimator, const std::vector<SourceRange>& ranges) {
    for (const auto& range : ranges) estimator.addSourceRange(range);
}

template <typename Range, typename Function>
void addRange(SizeEstimator& estimator, const Range& range, Function function) {
    estimator.addProduct(range.size(), kRecordContainerBytes);
    for (const auto& value : range) {
        std::invoke(function, estimator, value);
    }
}

[[nodiscard]] bool rangesOverlap(Address lhsStart, Address lhsEnd, Address rhsStart, Address rhsEnd) {
    return lhsStart < rhsEnd && rhsStart < lhsEnd;
}

} // namespace

StructuredResult canonicalizedStructuredResult(StructuredResult result) {
    if (result.blockPartition) {
        std::sort(result.blockPartition->edges.begin(), result.blockPartition->edges.end(),
            [](const auto& lhs, const auto& rhs) { return lhs.edgeId < rhs.edgeId; });
    }
    for (auto& type : result.types) {
        std::sort(type.fields.begin(), type.fields.end(), [](const TypeFieldRecord& lhs, const TypeFieldRecord& rhs) {
            return std::tie(lhs.bitOffset, lhs.name, lhs.typeId, lhs.bitSize) <
                   std::tie(rhs.bitOffset, rhs.name, rhs.typeId, rhs.bitSize);
        });
    }
    for (auto& instruction : result.instructions) {
        canonicalizeSourceRanges(instruction.sourceRanges);
    }
    for (auto& operation : result.operations) {
        canonicalizeSourceRanges(operation.sourceRanges);
    }
    for (auto& block : result.blocks) {
        sortOnly(block.predecessorEdgeIds, std::less<>{});
        sortOnly(block.successorEdgeIds, std::less<>{});
    }
    // Phi inputs are positional: Ghidra's MULTIEQUAL input slot identifies the
    // corresponding native predecessor slot. Preserve that order verbatim.
    for (auto& phi : result.memoryPhis) {
        std::sort(phi.incoming.begin(), phi.incoming.end(), [](const MemoryPhiIncomingRecord& lhs,
                                                               const MemoryPhiIncomingRecord& rhs) {
            return std::tie(lhs.sourceBlockId, lhs.edgeId, lhs.memoryVersionId) <
                   std::tie(rhs.sourceBlockId, rhs.edgeId, rhs.memoryVersionId);
        });
    }
    for (auto& variable : result.variables) {
        sortOnly(variable.storageVarnodeIds, std::less<>{});
        canonicalizeSourceRanges(variable.liveRanges);
    }
    for (auto& call : result.calls) {
        canonicalizeSourceRanges(call.sourceRanges);
    }
    for (auto& region : result.regions) {
        sortOnly(region.blockIds, std::less<>{});
        canonicalizeSourceRanges(region.sourceRanges);
    }
    for (auto& token : result.tokens) {
        canonicalizeSourceRanges(token.sourceRanges);
        std::sort(token.entityReferences.begin(), token.entityReferences.end(),
                  [](const TokenEntityReference& lhs, const TokenEntityReference& rhs) {
                      return std::tie(lhs.kind, lhs.id) < std::tie(rhs.kind, rhs.id);
                  });
    }
    for (auto& warning : result.warnings) {
        canonicalizeSourceRanges(warning.sourceRanges);
    }

    sortById(result.addressSpaces);
    sortById(result.types);
    std::sort(result.instructions.begin(), result.instructions.end(), [](const InstructionRecord& lhs,
                                                                        const InstructionRecord& rhs) {
        return std::tie(lhs.address, lhs.id) < std::tie(rhs.address, rhs.id);
    });
    sortById(result.varnodes);
    std::sort(result.operations.begin(), result.operations.end(), [](const OperationRecord& lhs,
                                                                    const OperationRecord& rhs) {
        return std::tie(lhs.blockId, lhs.sequence, lhs.id) < std::tie(rhs.blockId, rhs.sequence, rhs.id);
    });
    std::sort(result.blocks.begin(), result.blocks.end(), [](const BlockRecord& lhs, const BlockRecord& rhs) {
        return std::tie(lhs.startAddress, lhs.id) < std::tie(rhs.startAddress, rhs.id);
    });
    sortById(result.edges);
    sortById(result.ssaValues);
    std::sort(result.ssaBindings.begin(), result.ssaBindings.end(), [](const SsaBindingRecord& lhs,
                                                                      const SsaBindingRecord& rhs) {
        return lhs.operationId < rhs.operationId;
    });
    sortById(result.phis);
    sortById(result.memoryVersions);
    sortById(result.memoryPhis);
    sortById(result.memoryEffects);
    sortById(result.variables);
    sortById(result.calls);
    sortById(result.regions);
    std::sort(result.tokens.begin(), result.tokens.end(), [](const PseudocodeTokenRecord& lhs,
                                                            const PseudocodeTokenRecord& rhs) {
        return std::tie(lhs.line, lhs.column, lhs.id) < std::tie(rhs.line, rhs.column, rhs.id);
    });
    std::sort(result.warnings.begin(), result.warnings.end(), [](const DiagnosticRecord& lhs,
                                                                const DiagnosticRecord& rhs) {
        const auto lhsKey = std::tie(lhs.severity, lhs.code, lhs.message);
        const auto rhsKey = std::tie(rhs.severity, rhs.code, rhs.message);
        if (lhsKey != rhsKey) return lhsKey < rhsKey;
        return std::lexicographical_compare(
            lhs.sourceRanges.begin(), lhs.sourceRanges.end(),
            rhs.sourceRanges.begin(), rhs.sourceRanges.end(),
            sourceRangeLess
        );
    });
    return result;
}

void canonicalizeStructuredResult(StructuredResult& result) {
    result = canonicalizedStructuredResult(std::move(result));
}

namespace {

void addTokenRecord(SizeEstimator& size, const PseudocodeTokenRecord& value) {
    size.addText(value.id); size.addText(value.text); size.addText(value.kind);
    size.addPosition(value.line); size.addPosition(value.column);
    addSourceRanges(size, value.sourceRanges);
    for (const auto& reference : value.entityReferences) {
        size.add(kNestedContainerBytes);
        size.addText(reference.kind); size.addText(reference.id);
    }
}

void accumulateStructuredResult(SizeEstimator& estimator, const StructuredResult& result) {
    estimator.addText(result.requestId);
    estimator.addText(result.requestSha256);
    estimator.addText(result.image.imageId);
    estimator.addText(result.image.uuid);
    estimator.addScalar(result.image.preferredLoadAddress);
    estimator.addText(result.function.functionId);
    estimator.addText(result.function.name);
    estimator.addScalar(result.function.entryAddress);
    estimator.addScalar(result.function.endAddressExclusive);
    for (const auto& range : result.function.codeRanges) {
        estimator.add(kNestedContainerBytes);
        estimator.addScalar(range.startAddress);
        estimator.addScalar(range.endAddressExclusive);
    }

    addRange(estimator, result.addressSpaces, [](SizeEstimator& size, const AddressSpaceRecord& value) {
        size.addText(value.id); size.addText(value.name); size.addText(value.kind);
        size.addScalar(value.addressSizeBytes); size.addScalar(value.isProcessorSpace);
    });
    addRange(estimator, result.types, [](SizeEstimator& size, const TypeRecord& value) {
        size.addText(value.id); size.addText(value.kind); size.addText(value.name);
        size.addScalar(value.byteSize); size.addScalar(value.isSigned);
        if (value.pointeeTypeId) size.addText(*value.pointeeTypeId);
        if (value.returnTypeId) size.addText(*value.returnTypeId);
        size.addText(value.confidence); size.addText(value.provenance);
        for (const auto& parameter : value.parameterTypeIds) size.addText(parameter);
        for (const auto& field : value.fields) {
            size.add(kNestedContainerBytes);
            size.addText(field.name); size.addText(field.typeId);
            size.addScalar(field.bitOffset); size.addScalar(field.bitSize);
        }
    });
    addRange(estimator, result.instructions, [](SizeEstimator& size, const InstructionRecord& value) {
        size.addText(value.id); size.addScalar(value.address);
        // A byte array is commonly encoded as decimal integers with separators.
        // Reserve five bytes per element (three digits, comma, and structural
        // slack) so this remains a conservative publication bound.
        size.addProduct(value.bytes.size(), 5U);
        size.addText(value.mnemonic); size.addText(value.body);
        for (const auto& id : value.operationIds) size.addText(id);
        addSourceRanges(size, value.sourceRanges);
    });
    addRange(estimator, result.varnodes, [](SizeEstimator& size, const VarnodeRecord& value) {
        size.addText(value.id); size.addText(value.addressSpaceId); size.addScalar(value.offset);
        size.addScalar(value.sizeBytes); size.addText(value.role);
        if (value.typeId) size.addText(*value.typeId);
        if (value.registerName) size.addText(*value.registerName);
    });
    addRange(estimator, result.operations, [](SizeEstimator& size, const OperationRecord& value) {
        size.addText(value.id); size.addText(value.blockId); size.addScalar(value.sequence);
        size.addText(value.opcode);
        if (value.outputVarnodeId) size.addText(*value.outputVarnodeId);
        for (const auto& id : value.inputVarnodeIds) size.addText(id);
        size.addScalar(value.directTargetAddress);
        addSourceRanges(size, value.sourceRanges);
        size.addScalar(value.userOperationName.has_value());
        if (value.userOperationName) size.addText(*value.userOperationName);
        // These scalar charges also cover the nested authentication-effect
        // dictionary and its finite mapped kind; no semantic field is omitted.
        size.addScalar(value.authenticationEffect.kind);
        size.addScalar(value.authenticationEffect.outputSsaValueId.has_value());
        if (value.authenticationEffect.outputSsaValueId) {
            size.addText(*value.authenticationEffect.outputSsaValueId);
        }
    });
    addRange(estimator, result.blocks, [](SizeEstimator& size, const BlockRecord& value) {
        size.addText(value.id); size.addScalar(value.startAddress); size.addScalar(value.endAddressExclusive);
        for (const auto& id : value.operationIds) size.addText(id);
        for (const auto& id : value.predecessorEdgeIds) size.addText(id);
        for (const auto& id : value.successorEdgeIds) size.addText(id);
        size.addText(value.terminatorKind);
    });
    addRange(estimator, result.edges, [](SizeEstimator& size, const EdgeRecord& value) {
        size.addText(value.id); size.addText(value.sourceBlockId);
        if (value.targetBlockId) size.addText(*value.targetBlockId);
        size.addScalar(value.targetAddress); size.addText(value.kind);
        if (value.operationId) size.addText(*value.operationId);
    });
    addRange(estimator, result.ssaValues, [](SizeEstimator& size, const SsaValueRecord& value) {
        size.addText(value.id); size.addText(value.varnodeId); size.addText(value.kind);
        if (value.definingOperationId) size.addText(*value.definingOperationId);
        if (value.definingPhiId) size.addText(*value.definingPhiId);
    });
    addRange(estimator, result.ssaBindings, [](SizeEstimator& size, const SsaBindingRecord& value) {
        size.addText(value.operationId);
        for (const auto& id : value.inputSsaValueIds) size.addText(id);
        if (value.outputSsaValueId) size.addText(*value.outputSsaValueId);
    });
    addRange(estimator, result.phis, [](SizeEstimator& size, const PhiRecord& value) {
        size.addText(value.id); size.addText(value.blockId); size.addText(value.varnodeId);
        size.addText(value.outputSsaValueId);
        for (const auto& incoming : value.incoming) {
            size.add(kNestedContainerBytes);
            if (incoming.sourceBlockId) size.addText(*incoming.sourceBlockId);
            if (incoming.edgeId) size.addText(*incoming.edgeId);
            size.addText(incoming.ssaValueId);
        }
    });
    addRange(estimator, result.memoryVersions, [](SizeEstimator& size, const MemoryVersionRecord& value) {
        size.addText(value.id); size.addText(value.partition); size.addText(value.kind);
        if (value.definingOperationId) size.addText(*value.definingOperationId);
        if (value.definingMemoryPhiId) size.addText(*value.definingMemoryPhiId);
    });
    addRange(estimator, result.memoryPhis, [](SizeEstimator& size, const MemoryPhiRecord& value) {
        size.addText(value.id); size.addText(value.blockId); size.addText(value.partition);
        size.addText(value.outputMemoryVersionId);
        for (const auto& incoming : value.incoming) {
            size.add(kNestedContainerBytes);
            if (incoming.sourceBlockId) size.addText(*incoming.sourceBlockId);
            if (incoming.edgeId) size.addText(*incoming.edgeId);
            size.addText(incoming.memoryVersionId);
        }
    });
    addRange(estimator, result.memoryEffects, [](SizeEstimator& size, const MemoryEffectRecord& value) {
        size.addText(value.id); size.addText(value.operationId); size.addText(value.kind); size.addText(value.partition);
        if (value.inputMemoryVersionId) size.addText(*value.inputMemoryVersionId);
        if (value.outputMemoryVersionId) size.addText(*value.outputMemoryVersionId);
    });
    addRange(estimator, result.variables, [](SizeEstimator& size, const VariableRecord& value) {
        size.addText(value.id); size.addText(value.name); size.addText(value.role);
        if (value.typeId) size.addText(*value.typeId);
        for (const auto& id : value.storageVarnodeIds) size.addText(id);
        addSourceRanges(size, value.liveRanges);
        size.addText(value.confidence); size.addText(value.provenance);
    });
    addRange(estimator, result.calls, [](SizeEstimator& size, const CallRecord& value) {
        size.addText(value.id); size.addText(value.operationId); size.addText(value.kind);
        size.addScalar(value.targetAddress);
        if (value.targetSymbol) size.addText(*value.targetSymbol);
        if (value.prototypeTypeId) size.addText(*value.prototypeTypeId);
        for (const auto& id : value.argumentVariableIds) size.addText(id);
        if (value.resultVariableId) size.addText(*value.resultVariableId);
        addSourceRanges(size, value.sourceRanges);
    });
    addRange(estimator, result.regions, [](SizeEstimator& size, const RegionRecord& value) {
        size.addText(value.id); size.addText(value.kind);
        if (value.parentRegionId) size.addText(*value.parentRegionId);
        for (const auto& id : value.childRegionIds) size.addText(id);
        for (const auto& id : value.blockIds) size.addText(id);
        if (value.conditionOperationId) size.addText(*value.conditionOperationId);
        addSourceRanges(size, value.sourceRanges);
    });
    addRange(estimator, result.tokens, addTokenRecord);
    estimator.addScalar(result.pseudocodeDocument.has_value());
    if (result.pseudocodeDocument) {
        estimator.addUniqueText(result.pseudocodeDocument->text);
        estimator.addUniqueText(result.pseudocodeDocument->language);
        estimator.addScalar(result.pseudocodeDocument->isComplete);
        estimator.addScalar(result.pseudocodeDocument->isTruncated);
    }
    addRange(estimator, result.warnings, [](SizeEstimator& size, const DiagnosticRecord& value) {
        size.addText(value.code); size.addText(value.severity); size.addText(value.message);
        addSourceRanges(size, value.sourceRanges);
    });
    if (result.blockPartition) detail::accountBlockPartition(estimator, *result.blockPartition);
}

} // namespace

std::size_t estimatedStructuredResultBytes(
    const StructuredResult& result,
    std::function<void()> checkpoint
) {
    SizeEstimator estimator(std::move(checkpoint));
    accumulateStructuredResult(estimator, result);
    return estimator.value();
}

class StructuredResultSizeAccumulator::State final {
public:
    explicit State(std::function<void()> checkpoint) : estimator(std::move(checkpoint)) {}
    SizeEstimator estimator;
};

StructuredResultSizeAccumulator::StructuredResultSizeAccumulator(
    const StructuredResult& base,
    std::function<void()> checkpoint
)
    : state_(std::make_unique<State>(std::move(checkpoint))) {
    accumulateStructuredResult(state_->estimator, base);
}

StructuredResultSizeAccumulator::~StructuredResultSizeAccumulator() = default;

std::size_t StructuredResultSizeAccumulator::addToken(const PseudocodeTokenRecord& token) {
    state_->estimator.addRecord();
    addTokenRecord(state_->estimator, token);
    return state_->estimator.value();
}

std::size_t StructuredResultSizeAccumulator::value() const noexcept {
    return state_->estimator.value();
}

std::size_t structuredResultEncodedSizeUpperBound(
    const StructuredResult& result,
    std::function<void()> checkpoint
) {
    return estimatedStructuredResultBytes(result, std::move(checkpoint));
}

void validateStructuredResult(const AnalysisRequestView& request, const StructuredResult& result) {
    if (result.requestId != request.requestId || result.requestSha256 != request.requestSha256) {
        throw ContractError("structured result does not bind to the exact request");
    }
    if (result.image != request.image) {
        throw ContractError("structured result image identity differs from the request");
    }
    if (result.function != request.function) {
        throw ContractError("structured result function identity differs from the request");
    }
    if (result.pseudocodeDocument) {
        validatePseudocodeDocument(*result.pseudocodeDocument);
    }
    if (request.documentOnly) {
        if (!result.pseudocodeDocument) {
            throw ContractError("document-only result requires a pseudocode document");
        }
        if (!result.addressSpaces.empty() || !result.types.empty() || !result.instructions.empty() ||
            !result.varnodes.empty() || !result.operations.empty() || !result.blocks.empty() ||
            !result.edges.empty() || !result.ssaValues.empty() || !result.ssaBindings.empty() ||
            !result.phis.empty() || !result.memoryVersions.empty() || !result.memoryPhis.empty() ||
            !result.memoryEffects.empty() || !result.variables.empty() || !result.calls.empty() ||
            !result.regions.empty() || !result.tokens.empty() || result.blockPartition) {
            throw ContractError("document-only result carries structured-graph records");
        }
        return;
    }

    const auto addressSpaceIds = uniqueIds(result.addressSpaces, &AddressSpaceRecord::id, "address-space");
    const auto typeIds = uniqueIds(result.types, &TypeRecord::id, "type");
    const auto instructionIds = uniqueIds(result.instructions, &InstructionRecord::id, "instruction");
    const auto varnodeIds = uniqueIds(result.varnodes, &VarnodeRecord::id, "varnode");
    const auto operationIds = uniqueIds(result.operations, &OperationRecord::id, "operation");
    const auto blockIds = uniqueIds(result.blocks, &BlockRecord::id, "block");
    const auto edgeIds = uniqueIds(result.edges, &EdgeRecord::id, "edge");
    const auto ssaValueIds = uniqueIds(result.ssaValues, &SsaValueRecord::id, "SSA value");
    const auto phiIds = uniqueIds(result.phis, &PhiRecord::id, "phi");
    const auto memoryVersionIds = uniqueIds(result.memoryVersions, &MemoryVersionRecord::id, "memory version");
    const auto memoryPhiIds = uniqueIds(result.memoryPhis, &MemoryPhiRecord::id, "memory phi");
    const auto memoryEffectIds = uniqueIds(result.memoryEffects, &MemoryEffectRecord::id, "memory effect");
    const auto variableIds = uniqueIds(result.variables, &VariableRecord::id, "variable");
    const auto callIds = uniqueIds(result.calls, &CallRecord::id, "call");
    const auto regionIds = uniqueIds(result.regions, &RegionRecord::id, "region");
    const auto tokenIds = uniqueIds(result.tokens, &PseudocodeTokenRecord::id, "token");
    (void)instructionIds;
    (void)memoryEffectIds;
    (void)callIds;
    (void)tokenIds;

    if (result.instructions.empty()) {
        throw ContractError("structured result requires at least one decoded instruction");
    }
    if (result.blocks.empty()) {
        throw ContractError("structured result requires at least one basic block");
    }

    for (const auto& space : result.addressSpaces) {
        requireBoundedText(space.name, "address-space name", 256);
        requireBoundedText(space.kind, "address-space kind", 256);
        if (space.addressSizeBytes == 0 || space.addressSizeBytes > 32) {
            throw ContractError("address-space width must be between 1 and 32 bytes");
        }
    }

    for (const auto& type : result.types) {
        requireBoundedText(type.kind, "type kind", 256);
        requireBoundedText(type.name, "type name", 4096);
        requireBoundedText(type.confidence, "type confidence", 256);
        requireBoundedText(type.provenance, "type provenance", 4096);
        if (type.byteSize && *type.byteSize == 0) {
            throw ContractError("type byte size must be non-zero when present");
        }
        if (type.pointeeTypeId) requireReference(typeIds, *type.pointeeTypeId, "type pointee");
        std::set<std::tuple<std::string, std::string, std::uint64_t, std::uint64_t>> fieldKeys;
        for (const auto& field : type.fields) {
            requireReference(typeIds, field.typeId, "type field");
            requireBoundedText(field.name, "type-field name", 1024);
            if (field.bitSize == 0) throw ContractError("type fields require a non-zero bit size");
            if (!fieldKeys.emplace(field.name, field.typeId, field.bitOffset, field.bitSize).second) {
                throw ContractError("type fields must be unique");
            }
            if (type.byteSize) {
                if (*type.byteSize > std::numeric_limits<std::uint64_t>::max() / 8U ||
                    field.bitOffset > (*type.byteSize * 8U) ||
                    field.bitSize > (*type.byteSize * 8U) - field.bitOffset) {
                    throw ContractError("type field exceeds the containing type size");
                }
            }
        }
        if (type.returnTypeId) requireReference(typeIds, *type.returnTypeId, "function return type");
        for (const auto& id : type.parameterTypeIds) requireReference(typeIds, id, "function parameter type");
    }

    std::unordered_map<std::string, const InstructionRecord*> instructionsById;
    std::unordered_map<std::string, std::string> operationInstructionOwner;
    std::vector<std::pair<Address, Address>> instructionExtents;
    for (const auto& instruction : result.instructions) {
        instructionsById.emplace(instruction.id, &instruction);
        requireBoundedText(instruction.mnemonic, "instruction mnemonic", 256);
        requireBoundedText(instruction.body, "instruction body", 4096, true, true);
        if (instruction.bytes.empty() || instruction.bytes.size() > 32) {
            throw ContractError("instruction byte width must be between 1 and 32 bytes");
        }
        const Address end = checkedEnd(instruction.address, instruction.bytes.size(), "instruction");
        if (!instructionInsideFunctionRange(request.function, instruction.address, end)) {
            throw ContractError("instruction extent must remain inside the requested function");
        }
        instructionExtents.emplace_back(instruction.address, end);
        if (request.bytes.readEffective(instruction.address, instruction.bytes.size()) != instruction.bytes) {
            throw ContractError("instruction bytes differ from the caller-owned effective image");
        }
        if (instruction.sourceRanges.empty()) {
            throw ContractError("every instruction requires an image-qualified source range");
        }
        bool hasExactRange = false;
        std::unordered_set<std::string> localOperationIds;
        for (const auto& range : instruction.sourceRanges) {
            validateSourceRange(request, range, "instruction source range");
            hasExactRange = hasExactRange ||
                (range.startAddress == instruction.address && range.endAddressExclusive == end);
        }
        if (!hasExactRange) {
            throw ContractError("instruction source ranges must include its exact effective-byte extent");
        }
        for (const auto& operationId : instruction.operationIds) {
            requireReference(operationIds, operationId, "instruction operation");
            if (!localOperationIds.insert(operationId).second ||
                !operationInstructionOwner.emplace(operationId, instruction.id).second) {
                throw ContractError("each operation must be owned by exactly one instruction");
            }
        }
    }
    if (operationInstructionOwner.size() != result.operations.size()) {
        throw ContractError("every operation must be owned by an instruction");
    }
    std::sort(instructionExtents.begin(), instructionExtents.end());
    const auto codeRanges = request.function.codeRanges.empty()
        ? std::vector<FunctionIdentity::CodeRange>{{request.function.entryAddress, request.function.endAddressExclusive}}
        : request.function.codeRanges;
    std::size_t instructionIndex = 0;
    for (const auto& range : codeRanges) {
        Address cursor = range.startAddress;
        while (instructionIndex < instructionExtents.size() && instructionExtents[instructionIndex].first < range.endAddressExclusive) {
            if (instructionExtents[instructionIndex].first != cursor) {
                throw ContractError("decoded instructions must exactly cover each function code range");
            }
            cursor = instructionExtents[instructionIndex].second;
            ++instructionIndex;
        }
        if (cursor != range.endAddressExclusive) {
            throw ContractError("decoded instructions must exactly cover each function code range");
        }
    }
    if (instructionIndex != instructionExtents.size()) {
        throw ContractError("decoded instructions escaped function code ranges");
    }

    // A constant-space offset is the constant's value, not a storage address,
    // and spacebase (stack) offsets wrap: `sub x9, x9, #8` carries the constant
    // 0xfffffffffffffff8 and a saved x30 lives at stack offset -8. Neither has a
    // storage extent that can overflow, so only the other kinds are range-checked.
    std::unordered_set<std::string> wrappingOffsetSpaceIds;
    for (const auto& space : result.addressSpaces) {
        if (space.kind == "constant" || space.kind == "spacebase") {
            wrappingOffsetSpaceIds.insert(space.id);
        }
    }
    for (const auto& varnode : result.varnodes) {
        requireReference(addressSpaceIds, varnode.addressSpaceId, "varnode");
        requireBoundedText(varnode.role, "varnode role", 256);
        if (varnode.sizeBytes == 0 || varnode.sizeBytes > 4096) {
            throw ContractError("varnode sizes must be between 1 and 4096 bytes");
        }
        if (!wrappingOffsetSpaceIds.contains(varnode.addressSpaceId)) {
            (void)checkedEnd(varnode.offset, varnode.sizeBytes, "varnode storage");
        }
        if (varnode.typeId) requireReference(typeIds, *varnode.typeId, "varnode type");
        if (varnode.registerName) requireBoundedText(*varnode.registerName, "register name", 256);
    }

    std::unordered_map<std::string, const OperationRecord*> operationsById;
    std::map<std::pair<std::string, std::uint64_t>, std::string> sequenceOwners;
    for (const auto& operation : result.operations) {
        operationsById.emplace(operation.id, &operation);
        requireReference(blockIds, operation.blockId, "operation block");
        requireBoundedText(operation.opcode, "operation opcode", 256);
        const bool isCallOther = operation.opcode == "CALLOTHER";
        if (isCallOther != operation.userOperationName.has_value()) {
            throw ContractError("CALLOTHER operations require exactly one user-operation name");
        }
        if (operation.userOperationName) {
            requireBoundedText(*operation.userOperationName, "user-operation name", 256);
        }
        const auto requireOutputlessEffect = [&] {
            if (operation.outputVarnodeId ||
                operation.authenticationEffect.outputSsaValueId) {
                throw ContractError("outputless authentication effects cannot carry an output");
            }
        };
        switch (operation.authenticationEffect.kind) {
        case AuthenticationEffectKind::none:
            if (operation.authenticationEffect.outputSsaValueId) {
                throw ContractError("none authentication effect cannot carry an output SSA value");
            }
            break;
        case AuthenticationEffectKind::transformedOutput:
            if (!isCallOther || !operation.outputVarnodeId ||
                !operation.authenticationEffect.outputSsaValueId) {
                throw ContractError("transformed authentication effect requires CALLOTHER output evidence");
            }
            break;
        case AuthenticationEffectKind::authenticatedMemoryAccessWithoutTransformedAddress:
            if (!isCallOther ||
                (operation.userOperationName != "AuthDA" &&
                 operation.userOperationName != "AuthDB")) {
                throw ContractError("memory authentication effect requires an AuthD user operation");
            }
            requireOutputlessEffect();
            break;
        case AuthenticationEffectKind::authenticatedControlTransferWithoutTransformedTarget:
            if (!isCallOther ||
                (operation.userOperationName != "AuthIA" &&
                 operation.userOperationName != "AuthIB" &&
                 operation.userOperationName != "AuthDA" &&
                 operation.userOperationName != "AuthDB")) {
                throw ContractError("control authentication effect requires an Auth user operation");
            }
            requireOutputlessEffect();
            break;
        case AuthenticationEffectKind::standaloneAuthenticationWithoutTransformedOutput: {
            const auto* instruction = instructionsById.at(operationInstructionOwner.at(operation.id));
            const std::vector<std::uint8_t> autibsp{0xffU, 0x23U, 0x03U, 0xd5U};
            if (!isCallOther || operation.userOperationName != "AuthIB" ||
                operation.inputVarnodeIds.size() != 3U || instruction->mnemonic != "autibsp" ||
                instruction->bytes != autibsp) {
                throw ContractError("standalone authentication requires exact outputless autibsp evidence");
            }
            requireOutputlessEffect();
            break;
        }
        default:
            throw ContractError("authentication effect kind is unsupported");
        }
        constexpr std::array<std::string_view, 14> pacNames = {
            "AuthIA", "AuthIB", "AuthDA", "AuthDB",
            "pacia", "pacib", "pacda", "pacdb",
            "paciza", "pacizb", "pacdza", "pacdzb",
            "pacga", "xpac",
        };
        const bool isPacOperation = operation.userOperationName &&
            std::find(pacNames.begin(), pacNames.end(), *operation.userOperationName) !=
                pacNames.end();
        if (isPacOperation && operation.authenticationEffect.kind == AuthenticationEffectKind::none) {
            throw ContractError("PAC user operations require an authentication effect");
        }
        if (!isPacOperation && operation.authenticationEffect.kind != AuthenticationEffectKind::none) {
            throw ContractError("authentication effects require an attested PAC user operation");
        }
        if (!sequenceOwners.emplace(std::make_pair(operation.blockId, operation.sequence), operation.id).second) {
            throw ContractError("operation sequence numbers must be unique within a block");
        }
        if (operation.outputVarnodeId) requireReference(varnodeIds, *operation.outputVarnodeId, "operation output");
        for (const auto& id : operation.inputVarnodeIds) requireReference(varnodeIds, id, "operation input");
        if (operation.sourceRanges.empty()) {
            throw ContractError("every operation requires at least one image-qualified source range");
        }
        const auto* instruction = instructionsById.at(operationInstructionOwner.at(operation.id));
        const Address instructionEnd = instruction->address + static_cast<Address>(instruction->bytes.size());
        bool associated = false;
        for (const auto& range : operation.sourceRanges) {
            validateSourceRange(request, range, "operation source range");
            associated = associated || rangesOverlap(
                range.startAddress,
                range.endAddressExclusive,
                instruction->address,
                instructionEnd
            );
        }
        if (!associated) {
            throw ContractError("operation source ranges do not overlap the owning instruction");
        }
    }

    if (!result.blockPartition) {
    for (const auto& instruction : result.instructions) {
        std::optional<std::string> instructionBlockId;
        std::uint64_t previousSequence = 0;
        bool hasPreviousSequence = false;
        for (const auto& operationId : instruction.operationIds) {
            const auto* operation = operationsById.at(operationId);
            if (instructionBlockId && *instructionBlockId != operation->blockId) {
                throw ContractError("one machine instruction cannot own operations in multiple basic blocks");
            }
            instructionBlockId = operation->blockId;
            if (hasPreviousSequence && operation->sequence <= previousSequence) {
                throw ContractError("instruction operations must preserve increasing semantic order");
            }
            previousSequence = operation->sequence;
            hasPreviousSequence = true;
        }
    }

    }

    std::set<Address> instructionBoundaries{request.function.endAddressExclusive};
    for (const auto& range : request.function.codeRanges) instructionBoundaries.insert(range.endAddressExclusive);
    std::vector<const InstructionRecord*> instructionsByAddress;
    instructionsByAddress.reserve(result.instructions.size());
    for (const auto& instruction : result.instructions) {
        instructionBoundaries.insert(instruction.address);
        instructionsByAddress.push_back(&instruction);
    }
    std::sort(instructionsByAddress.begin(), instructionsByAddress.end(), [](const auto* lhs, const auto* rhs) {
        return std::tie(lhs->address, lhs->id) < std::tie(rhs->address, rhs->id);
    });

    std::unordered_map<std::string, const BlockRecord*> blocksById;
    if (result.blockPartition) {
        detail::validateBlockPartition(request, result);
        for (const auto& block : result.blocks) blocksById.emplace(block.id, &block);
    } else {
    std::unordered_map<std::string, std::string> operationBlockOwner;
    std::vector<std::pair<Address, Address>> blockExtents;
    bool hasEntryBlock = false;
    for (const auto& block : result.blocks) {
        blocksById.emplace(block.id, &block);
        requireBoundedText(block.terminatorKind, "block terminator kind", 256);
        if (block.operationIds.empty() || block.terminatorKind == "splice") {
            throw ContractError("legacy basic blocks require operations and cannot splice");
        }
        if (!basicBlockBoundsInsideFunction(request.function, block.startAddress, block.endAddressExclusive)) {
            throw ContractError("basic-block extent must remain inside the requested function");
        }
        if (!instructionBoundaries.contains(block.startAddress) ||
            !instructionBoundaries.contains(block.endAddressExclusive)) {
            throw ContractError("basic-block extents must align to decoded instruction boundaries");
        }
        hasEntryBlock = hasEntryBlock || block.startAddress == request.function.entryAddress;
        blockExtents.emplace_back(block.startAddress, block.endAddressExclusive);
        std::uint64_t previousSequence = 0;
        bool hasPreviousSequence = false;
        for (const auto& id : block.operationIds) {
            requireReference(operationIds, id, "basic block operation");
            const auto* operation = operationsById.at(id);
            if (operation->blockId != block.id || !operationBlockOwner.emplace(id, block.id).second) {
                throw ContractError("operation/block ownership is inconsistent");
            }
            const auto* instruction = instructionsById.at(operationInstructionOwner.at(id));
            const Address instructionEnd = checkedEnd(
                instruction->address,
                instruction->bytes.size(),
                "basic-block instruction"
            );
            if (instruction->address < block.startAddress || instructionEnd > block.endAddressExclusive) {
                throw ContractError("basic-block operations must be owned by instructions inside the block extent");
            }
            if (hasPreviousSequence && operation->sequence <= previousSequence) {
                throw ContractError("basic-block operations must be ordered by increasing sequence");
            }
            previousSequence = operation->sequence;
            hasPreviousSequence = true;
        }
        for (const auto& id : block.predecessorEdgeIds) requireReference(edgeIds, id, "basic block predecessor");
        for (const auto& id : block.successorEdgeIds) requireReference(edgeIds, id, "basic block successor");
    }
    if (!hasEntryBlock) throw ContractError("structured result requires a basic block at the function entry");
    if (operationBlockOwner.size() != result.operations.size()) {
        throw ContractError("every operation must be listed by exactly one basic block");
    }
    for (const auto& operation : result.operations) {
        const auto* instruction = instructionsById.at(operationInstructionOwner.at(operation.id));
        const auto* block = blocksById.at(operation.blockId);
        const Address instructionEnd = instruction->address + static_cast<Address>(instruction->bytes.size());
        if (instruction->address < block->startAddress || instructionEnd > block->endAddressExclusive) {
            throw ContractError("an operation's owning instruction must remain inside its basic block");
        }
    }
    std::sort(blockExtents.begin(), blockExtents.end());
    for (std::size_t index = 1; index < blockExtents.size(); ++index) {
        if (blockExtents[index].first < blockExtents[index - 1].second) {
            throw ContractError("basic-block extents must not overlap");
        }
    }

    std::vector<const BlockRecord*> blocksByAddress;
    blocksByAddress.reserve(result.blocks.size());
    for (const auto& block : result.blocks) blocksByAddress.push_back(&block);
    std::sort(blocksByAddress.begin(), blocksByAddress.end(), [](const auto* lhs, const auto* rhs) {
        return std::tie(lhs->startAddress, lhs->id) < std::tie(rhs->startAddress, rhs->id);
    });

    std::unordered_map<std::string, std::size_t> instructionCountByBlock;
    std::unordered_map<std::string, std::vector<std::string>> expectedOperationsByBlock;
    std::size_t blockIndex = 0;
    for (const auto* instruction : instructionsByAddress) {
        const Address instructionEnd = checkedEnd(
            instruction->address,
            instruction->bytes.size(),
            "instruction/basic-block ownership"
        );
        while (blockIndex < blocksByAddress.size() &&
               blocksByAddress[blockIndex]->endAddressExclusive <= instruction->address) {
            ++blockIndex;
        }
        if (blockIndex == blocksByAddress.size() ||
            instruction->address < blocksByAddress[blockIndex]->startAddress ||
            instructionEnd > blocksByAddress[blockIndex]->endAddressExclusive) {
            throw ContractError("every decoded instruction must belong to exactly one basic block");
        }
        const auto& blockId = blocksByAddress[blockIndex]->id;
        ++instructionCountByBlock[blockId];
        auto& expected = expectedOperationsByBlock[blockId];
        expected.insert(expected.end(), instruction->operationIds.begin(), instruction->operationIds.end());
    }
    for (const auto& block : result.blocks) {
        if (!instructionCountByBlock.contains(block.id)) {
            throw ContractError("every basic block must contain at least one decoded instruction");
        }
        if (expectedOperationsByBlock[block.id] != block.operationIds) {
            throw ContractError("basic-block operation order must match machine-instruction order");
        }
    }

    }

    std::unordered_map<std::string, const EdgeRecord*> edgesById;
    for (const auto& edge : result.edges) {
        edgesById.emplace(edge.id, &edge);
        requireReference(blockIds, edge.sourceBlockId, "edge source");
        requireBoundedText(edge.kind, "edge kind", 256);
        if (!result.blockPartition && edge.kind == "splice") {
            throw ContractError("legacy edges cannot splice");
        }
        if (edge.targetBlockId) {
            requireReference(blockIds, *edge.targetBlockId, "edge target");
            if (!result.blockPartition && blocksById.at(*edge.targetBlockId)->startAddress != edge.targetAddress) {
                throw ContractError("internal edge target address differs from target-block start");
            }
        } else if (addressInsideFunctionCode(request.function, edge.targetAddress)) {
            throw ContractError("an edge targeting the requested function must identify its target block");
        }
        if (edge.operationId) {
            requireReference(operationIds, *edge.operationId, "edge operation");
            const auto* sourceBlock = blocksById.at(edge.sourceBlockId);
            if (operationsById.at(*edge.operationId)->blockId != edge.sourceBlockId) {
                throw ContractError("edge operation must belong to its source block");
            }
            if (sourceBlock->operationIds.empty() || sourceBlock->operationIds.back() != *edge.operationId) {
                throw ContractError("edge operations must identify the final operation of the source block");
            }
        }
    }
    for (const auto& block : result.blocks) {
        std::unordered_set<std::string> predecessorSet(block.predecessorEdgeIds.begin(), block.predecessorEdgeIds.end());
        std::unordered_set<std::string> successorSet(block.successorEdgeIds.begin(), block.successorEdgeIds.end());
        if (predecessorSet.size() != block.predecessorEdgeIds.size() ||
            successorSet.size() != block.successorEdgeIds.size()) {
            throw ContractError("block edge adjacency IDs must be unique");
        }
        for (const auto& edgeId : block.predecessorEdgeIds) {
            const auto* edge = edgesById.at(edgeId);
            if (!edge->targetBlockId || *edge->targetBlockId != block.id) {
                throw ContractError("basic-block predecessor adjacency is inconsistent");
            }
        }
        for (const auto& edgeId : block.successorEdgeIds) {
            if (edgesById.at(edgeId)->sourceBlockId != block.id) {
                throw ContractError("basic-block successor adjacency is inconsistent");
            }
        }
    }
    for (const auto& edge : result.edges) {
        const auto* source = blocksById.at(edge.sourceBlockId);
        if (std::find(source->successorEdgeIds.begin(), source->successorEdgeIds.end(), edge.id) ==
            source->successorEdgeIds.end()) {
            throw ContractError("every edge must appear in its source block successor list");
        }
        if (edge.targetBlockId) {
            const auto* target = blocksById.at(*edge.targetBlockId);
            if (std::find(target->predecessorEdgeIds.begin(), target->predecessorEdgeIds.end(), edge.id) ==
                target->predecessorEdgeIds.end()) {
                throw ContractError("every internal edge must appear in its target block predecessor list");
            }
        }
    }

    const auto isEntryBlock = [&](const std::string& blockId) {
        return result.blockPartition ? blockId == result.blockPartition->entryBlockId :
            blocksById.at(blockId)->startAddress == request.function.entryAddress;
    };

    const auto expectedIncomingPaths = [&](const std::string& blockId) {
        std::set<std::pair<std::optional<std::string>, std::optional<std::string>>> paths;
        const auto* block = blocksById.at(blockId);
        if (isEntryBlock(blockId)) {
            paths.emplace(std::nullopt, std::nullopt);
        }
        for (const auto& edgeId : block->predecessorEdgeIds) {
            paths.emplace(edgesById.at(edgeId)->sourceBlockId, edgeId);
        }
        return paths;
    };

    std::unordered_map<std::string, const SsaValueRecord*> ssaValuesById;
    for (const auto& value : result.ssaValues) {
        ssaValuesById.emplace(value.id, &value);
        requireReference(varnodeIds, value.varnodeId, "SSA value varnode");
        requireBoundedText(value.kind, "SSA value kind", 256);
        const bool hasOperation = value.definingOperationId.has_value();
        const bool hasPhi = value.definingPhiId.has_value();
        if (hasOperation && hasPhi) throw ContractError("SSA values cannot have operation and phi definitions");
        if (hasOperation) requireReference(operationIds, *value.definingOperationId, "SSA defining operation");
        if (hasPhi) requireReference(phiIds, *value.definingPhiId, "SSA defining phi");
    }

    std::unordered_map<std::string, const PhiRecord*> phisById;
    for (const auto& phi : result.phis) {
        phisById.emplace(phi.id, &phi);
    }

    std::unordered_map<std::string, const SsaBindingRecord*> bindingsByOperation;
    std::unordered_set<std::string> definedSsaValueIds;
    std::unordered_set<std::string> matchedPhiIds;
    for (const auto& binding : result.ssaBindings) {
        requireReference(operationIds, binding.operationId, "SSA binding operation");
        if (!bindingsByOperation.emplace(binding.operationId, &binding).second) {
            throw ContractError("every operation requires exactly one SSA binding");
        }
        const auto* operation = operationsById.at(binding.operationId);
        if (binding.inputSsaValueIds.size() != operation->inputVarnodeIds.size()) {
            throw ContractError("SSA binding input count differs from operation input count");
        }
        for (std::size_t index = 0; index < binding.inputSsaValueIds.size(); ++index) {
            const auto& valueId = binding.inputSsaValueIds[index];
            requireReference(ssaValueIds, valueId, "SSA binding input");
            if (ssaValuesById.at(valueId)->varnodeId != operation->inputVarnodeIds[index]) {
                throw ContractError("SSA input varnode differs from the corresponding operation input");
            }
        }
        if (binding.outputSsaValueId) {
            requireReference(ssaValueIds, *binding.outputSsaValueId, "SSA binding output");
            const auto* value = ssaValuesById.at(*binding.outputSsaValueId);
            if (!operation->outputVarnodeId || value->varnodeId != *operation->outputVarnodeId) {
                throw ContractError("SSA binding output varnode differs from the operation output");
            }
            if (operation->opcode == "MULTIEQUAL") {
                if (value->definingOperationId || !value->definingPhiId) {
                    throw ContractError("MULTIEQUAL output must be defined by a phi");
                }
                const auto phi = phisById.find(*value->definingPhiId);
                if (phi == phisById.end() || phi->second->outputSsaValueId != value->id ||
                    phi->second->blockId != operation->blockId ||
                    phi->second->varnodeId != *operation->outputVarnodeId ||
                    !matchedPhiIds.insert(phi->second->id).second) {
                    throw ContractError("MULTIEQUAL output phi is inconsistent");
                }
                if (phi->second->incoming.size() != binding.inputSsaValueIds.size() ||
                    !std::equal(
                        phi->second->incoming.begin(), phi->second->incoming.end(),
                        binding.inputSsaValueIds.begin(), binding.inputSsaValueIds.end(),
                        [](const PhiIncomingRecord& incoming, const std::string& inputId) {
                            return incoming.ssaValueId == inputId;
                        }
                    )) {
                    throw ContractError("MULTIEQUAL phi inputs differ from its operation binding");
                }
            } else {
                if (value->definingOperationId != binding.operationId || value->definingPhiId) {
                    throw ContractError("SSA output does not match the operation output definition");
                }
                if (!definedSsaValueIds.insert(*binding.outputSsaValueId).second) {
                    throw ContractError("SSA values may have only one binding or phi definition");
                }
            }
        } else if (operation->outputVarnodeId) {
            throw ContractError("operations with outputs require an output SSA value");
        }
        if (operation->authenticationEffect.kind == AuthenticationEffectKind::transformedOutput &&
            operation->authenticationEffect.outputSsaValueId != binding.outputSsaValueId) {
            throw ContractError("transformed authentication effect must bind the operation output SSA value");
        }
    }
    if (bindingsByOperation.size() != result.operations.size()) {
        throw ContractError("every operation requires exactly one SSA binding");
    }

    for (const auto& phi : result.phis) {
        requireReference(blockIds, phi.blockId, "phi block");
        requireReference(varnodeIds, phi.varnodeId, "phi varnode");
        requireReference(ssaValueIds, phi.outputSsaValueId, "phi output");
        const auto* output = ssaValuesById.at(phi.outputSsaValueId);
        if (output->varnodeId != phi.varnodeId || output->definingPhiId != phi.id) {
            throw ContractError("phi output SSA value is inconsistent");
        }
        if (!definedSsaValueIds.insert(phi.outputSsaValueId).second) {
            throw ContractError("SSA values may have only one binding or phi definition");
        }
        if (phi.incoming.size() < 2) throw ContractError("phi nodes require at least two incoming values");
        std::set<std::pair<std::optional<std::string>, std::optional<std::string>>> incomingPaths;
        for (const auto& incoming : phi.incoming) {
            requireReference(ssaValueIds, incoming.ssaValueId, "phi incoming SSA value");
            if (incoming.sourceBlockId.has_value() != incoming.edgeId.has_value()) {
                throw ContractError("phi incoming source block and edge must be present together");
            }
            if (incoming.sourceBlockId) {
                requireReference(blockIds, *incoming.sourceBlockId, "phi source block");
                requireReference(edgeIds, *incoming.edgeId, "phi edge");
                const auto* edge = edgesById.at(*incoming.edgeId);
                if (edge->sourceBlockId != *incoming.sourceBlockId || !edge->targetBlockId ||
                    *edge->targetBlockId != phi.blockId) {
                    throw ContractError("phi incoming edge does not connect its source to the phi block");
                }
            } else if (!isEntryBlock(phi.blockId)) {
                throw ContractError("only entry-block phis may use a function-entry incoming value");
            }
            if (!incomingPaths.emplace(incoming.sourceBlockId, incoming.edgeId).second) {
                throw ContractError("phi incoming paths must be unique");
            }
        }
        if (incomingPaths != expectedIncomingPaths(phi.blockId)) {
            throw ContractError("phi incoming paths must exactly match basic-block predecessors");
        }
    }
    for (const auto& value : result.ssaValues) {
        if ((value.definingOperationId || value.definingPhiId) && !definedSsaValueIds.contains(value.id)) {
            throw ContractError("defined SSA values must be published by their binding or phi");
        }
    }

    std::unordered_map<std::string, const MemoryVersionRecord*> memoryVersionsById;
    for (const auto& version : result.memoryVersions) {
        memoryVersionsById.emplace(version.id, &version);
        requireBoundedText(version.partition, "memory partition", 256);
        requireBoundedText(version.kind, "memory-version kind", 256);
        const bool hasOperation = version.definingOperationId.has_value();
        const bool hasPhi = version.definingMemoryPhiId.has_value();
        if (hasOperation && hasPhi) throw ContractError("memory versions cannot have operation and phi definitions");
        if (hasOperation) requireReference(operationIds, *version.definingOperationId, "memory defining operation");
        if (hasPhi) requireReference(memoryPhiIds, *version.definingMemoryPhiId, "memory defining phi");
    }
    std::unordered_set<std::string> definedMemoryVersionIds;
    for (const auto& phi : result.memoryPhis) {
        requireReference(blockIds, phi.blockId, "memory phi block");
        requireReference(memoryVersionIds, phi.outputMemoryVersionId, "memory phi output");
        requireBoundedText(phi.partition, "memory-phi partition", 256);
        const auto* output = memoryVersionsById.at(phi.outputMemoryVersionId);
        if (output->partition != phi.partition || output->definingMemoryPhiId != phi.id) {
            throw ContractError("memory phi output is inconsistent");
        }
        if (!definedMemoryVersionIds.insert(phi.outputMemoryVersionId).second) {
            throw ContractError("memory versions may have only one effect or phi definition");
        }
        if (phi.incoming.size() < 2) throw ContractError("memory phis require at least two incoming versions");
        std::set<std::pair<std::optional<std::string>, std::optional<std::string>>> incomingPaths;
        for (const auto& incoming : phi.incoming) {
            requireReference(memoryVersionIds, incoming.memoryVersionId, "memory phi incoming");
            if (memoryVersionsById.at(incoming.memoryVersionId)->partition != phi.partition) {
                throw ContractError("memory phi incoming partition is inconsistent");
            }
            if (incoming.sourceBlockId.has_value() != incoming.edgeId.has_value()) {
                throw ContractError("memory phi source block and edge must be present together");
            }
            if (incoming.sourceBlockId) {
                requireReference(blockIds, *incoming.sourceBlockId, "memory phi source block");
                requireReference(edgeIds, *incoming.edgeId, "memory phi edge");
                const auto* edge = edgesById.at(*incoming.edgeId);
                if (edge->sourceBlockId != *incoming.sourceBlockId || !edge->targetBlockId ||
                    *edge->targetBlockId != phi.blockId) {
                    throw ContractError("memory phi incoming edge is inconsistent");
                }
            } else if (!isEntryBlock(phi.blockId)) {
                throw ContractError("only entry-block memory phis may use a function-entry incoming value");
            }
            if (!incomingPaths.emplace(incoming.sourceBlockId, incoming.edgeId).second) {
                throw ContractError("memory phi incoming paths must be unique");
            }
        }
        if (incomingPaths != expectedIncomingPaths(phi.blockId)) {
            throw ContractError("memory phi incoming paths must exactly match basic-block predecessors");
        }
    }
    for (const auto& effect : result.memoryEffects) {
        requireReference(operationIds, effect.operationId, "memory-effect operation");
        requireBoundedText(effect.kind, "memory-effect kind", 256);
        requireBoundedText(effect.partition, "memory-effect partition", 256);
        if (effect.inputMemoryVersionId) {
            requireReference(memoryVersionIds, *effect.inputMemoryVersionId, "memory-effect input");
            if (memoryVersionsById.at(*effect.inputMemoryVersionId)->partition != effect.partition) {
                throw ContractError("memory-effect input partition is inconsistent");
            }
        }
        if (effect.outputMemoryVersionId) {
            requireReference(memoryVersionIds, *effect.outputMemoryVersionId, "memory-effect output");
            if (!definedMemoryVersionIds.insert(*effect.outputMemoryVersionId).second) {
                throw ContractError("memory versions may have only one effect or phi definition");
            }
            const auto* output = memoryVersionsById.at(*effect.outputMemoryVersionId);
            if (output->partition != effect.partition || output->definingOperationId != effect.operationId) {
                throw ContractError("memory-effect output definition is inconsistent");
            }
        }
        if (!effect.inputMemoryVersionId && !effect.outputMemoryVersionId) {
            throw ContractError("memory effects require an input or output memory version");
        }
    }
    for (const auto& version : result.memoryVersions) {
        if ((version.definingOperationId || version.definingMemoryPhiId) &&
            !definedMemoryVersionIds.contains(version.id)) {
            throw ContractError("defined memory versions must be published by their effect or phi");
        }
    }

    for (const auto& variable : result.variables) {
        requireBoundedText(variable.name, "variable name", 1024);
        requireBoundedText(variable.role, "variable role", 256);
        requireBoundedText(variable.confidence, "variable confidence", 256);
        requireBoundedText(variable.provenance, "variable provenance", 4096);
        if (variable.typeId) requireReference(typeIds, *variable.typeId, "variable type");
        std::unordered_set<std::string> storageIds;
        for (const auto& id : variable.storageVarnodeIds) {
            requireReference(varnodeIds, id, "variable storage");
            if (!storageIds.insert(id).second) throw ContractError("variable storage IDs must be unique");
        }
    }

    std::unordered_map<std::string, std::size_t> callsByOperation;
    for (const auto& call : result.calls) {
        requireReference(operationIds, call.operationId, "call operation");
        requireBoundedText(call.kind, "call kind", 256);
        const auto* operation = operationsById.at(call.operationId);
        if (operation->opcode != "CALL" && operation->opcode != "CALLIND") {
            throw ContractError("call records must reference CALL or CALLIND operations");
        }
        if (++callsByOperation[call.operationId] != 1) throw ContractError("call operations require one call record");
        if (operation->directTargetAddress && call.targetAddress != operation->directTargetAddress) {
            throw ContractError("direct call target differs from the operation target");
        }
        if (call.targetSymbol) requireBoundedText(*call.targetSymbol, "call target symbol", 4096);
        if (call.prototypeTypeId) requireReference(typeIds, *call.prototypeTypeId, "call prototype");
        for (const auto& id : call.argumentVariableIds) requireReference(variableIds, id, "call argument variable");
        if (call.resultVariableId) requireReference(variableIds, *call.resultVariableId, "call result variable");
    }
    for (const auto& operation : result.operations) {
        if ((operation.opcode == "CALL" || operation.opcode == "CALLIND") && !callsByOperation.contains(operation.id)) {
            throw ContractError("every CALL or CALLIND operation requires a call record");
        }
    }

    std::unordered_map<std::string, const RegionRecord*> regionsById;
    for (const auto& region : result.regions) {
        regionsById.emplace(region.id, &region);
        requireBoundedText(region.kind, "region kind", 256);
        if (region.parentRegionId) requireReference(regionIds, *region.parentRegionId, "region parent");
        std::unordered_set<std::string> childIds;
        for (const auto& id : region.childRegionIds) {
            requireReference(regionIds, id, "region child");
            if (!childIds.insert(id).second) throw ContractError("region child IDs must be unique");
        }
        std::unordered_set<std::string> regionBlockIds;
        for (const auto& id : region.blockIds) {
            requireReference(blockIds, id, "region block");
            if (!regionBlockIds.insert(id).second) throw ContractError("region block IDs must be unique");
        }
        if (region.conditionOperationId) requireReference(operationIds, *region.conditionOperationId, "region condition");
    }
    for (const auto& region : result.regions) {
        for (const auto& childId : region.childRegionIds) {
            const auto* child = regionsById.at(childId);
            if (child->parentRegionId != region.id) {
                throw ContractError("region parent/child relationship is not reciprocal");
            }
        }
        if (region.parentRegionId) {
            const auto* parent = regionsById.at(*region.parentRegionId);
            if (std::find(parent->childRegionIds.begin(), parent->childRegionIds.end(), region.id) ==
                parent->childRegionIds.end()) {
                throw ContractError("region child/parent relationship is not reciprocal");
            }
        }
        std::unordered_set<std::string> ancestry;
        const RegionRecord* cursor = &region;
        while (cursor->parentRegionId) {
            if (!ancestry.insert(cursor->id).second) throw ContractError("region hierarchy contains a cycle");
            cursor = regionsById.at(*cursor->parentRegionId);
        }
    }

    for (const auto& token : result.tokens) {
        requireBoundedText(token.text, "pseudocode token text", 65536, false, true);
        requireBoundedText(token.kind, "pseudocode token kind", 256);
        if (token.line == 0 || token.column == 0) {
            throw ContractError("pseudocode token positions are one-based");
        }
        std::set<std::pair<std::string, std::string>> tokenReferences;
        for (const auto& reference : token.entityReferences) {
            if (!tokenReferences.emplace(reference.kind, reference.id).second) {
                throw ContractError("token entity references must be unique");
            }
            const std::unordered_set<std::string>* ids = nullptr;
            if (reference.kind == "type") ids = &typeIds;
            else if (reference.kind == "varnode") ids = &varnodeIds;
            else if (reference.kind == "operation") ids = &operationIds;
            else if (reference.kind == "block") ids = &blockIds;
            else if (reference.kind == "variable") ids = &variableIds;
            else if (reference.kind == "call") ids = &callIds;
            else if (reference.kind == "region") ids = &regionIds;
            else if (reference.kind == "instruction") ids = &instructionIds;
            else throw ContractError("token entity reference kind is unsupported");
            requireReference(*ids, reference.id, "token entity");
        }
    }

    using DiagnosticRangeKey = std::tuple<std::string, Address, Address>;
    using DiagnosticKey = std::tuple<std::string, std::string, std::string, std::vector<DiagnosticRangeKey>>;
    std::set<DiagnosticKey> diagnosticKeys;
    for (const auto& warning : result.warnings) {
        requireBoundedText(warning.code, "diagnostic code", 256);
        requireBoundedText(warning.severity, "diagnostic severity", 64);
        requireBoundedText(warning.message, "diagnostic message", 65536, false, true);
        std::vector<DiagnosticRangeKey> ranges;
        ranges.reserve(warning.sourceRanges.size());
        for (const auto& range : warning.sourceRanges) {
            ranges.emplace_back(range.imageId, range.startAddress, range.endAddressExclusive);
        }
        std::sort(ranges.begin(), ranges.end());
        if (!diagnosticKeys.emplace(warning.code, warning.severity, warning.message, std::move(ranges)).second) {
            throw ContractError("diagnostic records must be unique");
        }
    }

    validateSourceRanges(request, result.instructions, &InstructionRecord::sourceRanges, "instruction source range");
    validateSourceRanges(request, result.operations, &OperationRecord::sourceRanges, "operation source range");
    validateSourceRanges(request, result.variables, &VariableRecord::liveRanges, "variable live range");
    validateSourceRanges(request, result.calls, &CallRecord::sourceRanges, "call source range");
    validateSourceRanges(request, result.regions, &RegionRecord::sourceRanges, "region source range");
    validateSourceRanges(request, result.tokens, &PseudocodeTokenRecord::sourceRanges, "token source range");
    validateSourceRanges(request, result.warnings, &DiagnosticRecord::sourceRanges, "warning source range");
}

} // namespace macscope::native_decompiler
