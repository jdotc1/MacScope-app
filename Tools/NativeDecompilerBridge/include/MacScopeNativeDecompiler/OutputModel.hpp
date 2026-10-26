#pragma once

#include "MacScopeNativeDecompiler/InputModel.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace macscope::native_decompiler {

struct SourceRange final {
    std::string imageId;
    Address startAddress = 0;
    Address endAddressExclusive = 0;

    bool operator==(const SourceRange&) const = default;
};

struct AddressSpaceRecord final {
    std::string id;
    std::string name;
    std::string kind;
    std::uint32_t addressSizeBytes = 0;
    bool isProcessorSpace = false;

    bool operator==(const AddressSpaceRecord&) const = default;
};

struct TypeFieldRecord final {
    std::string name;
    std::string typeId;
    std::uint64_t bitOffset = 0;
    std::uint64_t bitSize = 0;

    bool operator==(const TypeFieldRecord&) const = default;
};

struct TypeRecord final {
    std::string id;
    std::string kind;
    std::string name;
    std::optional<std::uint64_t> byteSize;
    std::optional<bool> isSigned;
    std::optional<std::string> pointeeTypeId;
    std::vector<TypeFieldRecord> fields;
    std::string confidence;
    std::string provenance;
    std::optional<std::string> returnTypeId;
    std::vector<std::string> parameterTypeIds;

    bool operator==(const TypeRecord&) const = default;
};

/// One decoded machine instruction from the effective byte view. Operations
/// use legacy semantic p-code order unless blockPartition is present. In that
/// mode, operations are grouped by ascending final block ordinal, with native
/// block-local order retained within each ownership span. Instruction bytes
/// must match the caller-owned effective memory exactly.
struct InstructionRecord final {
    std::string id;
    Address address = 0;
    std::vector<std::uint8_t> bytes;
    std::string mnemonic;
    std::string body;
    std::vector<std::string> operationIds;
    std::vector<SourceRange> sourceRanges;

    bool operator==(const InstructionRecord&) const = default;
};

struct VarnodeRecord final {
    std::string id;
    std::string addressSpaceId;
    std::uint64_t offset = 0;
    std::uint32_t sizeBytes = 0;
    std::string role;
    std::optional<std::string> typeId;
    std::optional<std::string> registerName;

    bool operator==(const VarnodeRecord&) const = default;
};

enum class AuthenticationEffectKind : std::uint8_t {
    none = 0,
    transformedOutput,
    authenticatedMemoryAccessWithoutTransformedAddress,
    authenticatedControlTransferWithoutTransformedTarget,
    standaloneAuthenticationWithoutTransformedOutput,
};

struct AuthenticationEffect final {
    AuthenticationEffectKind kind = AuthenticationEffectKind::none;
    std::optional<std::string> outputSsaValueId;

    bool operator==(const AuthenticationEffect&) const = default;
};

struct OperationRecord final {
    std::string id;
    std::string blockId;
    std::uint64_t sequence = 0;
    std::string opcode;
    std::optional<std::string> outputVarnodeId;
    std::vector<std::string> inputVarnodeIds;
    std::optional<Address> directTargetAddress;
    std::vector<SourceRange> sourceRanges;
    std::optional<std::string> userOperationName;
    AuthenticationEffect authenticationEffect;

    bool operator==(const OperationRecord&) const = default;
};

struct BlockRecord final {
    std::string id;
    Address startAddress = 0;
    Address endAddressExclusive = 0;
    std::vector<std::string> operationIds;
    std::vector<std::string> predecessorEdgeIds;
    std::vector<std::string> successorEdgeIds;
    std::string terminatorKind;

    bool operator==(const BlockRecord&) const = default;
};

struct EdgeRecord final {
    std::string id;
    std::string sourceBlockId;
    std::optional<std::string> targetBlockId;
    Address targetAddress = 0;
    std::string kind;
    std::optional<std::string> operationId;

    bool operator==(const EdgeRecord&) const = default;
};

/// Version-1 final-CFG metadata. Absent metadata means the legacy address partition.
/// Spans index InstructionRecord::operationIds, not global operation sequence numbers.
struct InstructionBlockSpanRecord final {
    std::string blockId;
    std::uint32_t firstOperationIndex = 0;
    std::uint32_t operationCount = 0;
    bool operator==(const InstructionBlockSpanRecord&) const = default;
};

struct InstructionOwnershipRecord final {
    std::string instructionId;
    std::string disposition;
    std::vector<InstructionBlockSpanRecord> spans;
    bool operator==(const InstructionOwnershipRecord&) const = default;
};

struct BlockPartitionBlockRecord final {
    std::string blockId;
    std::uint32_t ordinal = 0;
    Address entryAddress = 0;
    std::vector<SourceRange> sourceRanges;
    bool operator==(const BlockPartitionBlockRecord&) const = default;
};

struct BlockPartitionEdgeRecord final {
    std::string edgeId;
    std::uint32_t sourceSlot = 0;
    std::uint32_t targetSlot = 0;
    std::string transferKind;
    bool operator==(const BlockPartitionEdgeRecord&) const = default;
};

struct BlockPartitionRecord final {
    std::uint32_t version = 1;
    std::string entryBlockId;
    std::vector<BlockPartitionBlockRecord> blocks;
    std::vector<InstructionOwnershipRecord> instructions;
    std::vector<BlockPartitionEdgeRecord> edges;
    bool operator==(const BlockPartitionRecord&) const = default;
};

struct SsaValueRecord final {
    std::string id;
    std::string varnodeId;
    std::string kind;
    std::optional<std::string> definingOperationId;
    std::optional<std::string> definingPhiId;

    bool operator==(const SsaValueRecord&) const = default;
};

struct SsaBindingRecord final {
    std::string operationId;
    std::vector<std::string> inputSsaValueIds;
    std::optional<std::string> outputSsaValueId;

    bool operator==(const SsaBindingRecord&) const = default;
};

struct PhiIncomingRecord final {
    std::optional<std::string> sourceBlockId;
    std::optional<std::string> edgeId;
    std::string ssaValueId;

    bool operator==(const PhiIncomingRecord&) const = default;
};

struct PhiRecord final {
    std::string id;
    std::string blockId;
    std::string varnodeId;
    std::string outputSsaValueId;
    std::vector<PhiIncomingRecord> incoming;

    bool operator==(const PhiRecord&) const = default;
};

struct MemoryVersionRecord final {
    std::string id;
    std::string partition;
    std::string kind;
    std::optional<std::string> definingOperationId;
    std::optional<std::string> definingMemoryPhiId;

    bool operator==(const MemoryVersionRecord&) const = default;
};

struct MemoryPhiIncomingRecord final {
    std::optional<std::string> sourceBlockId;
    std::optional<std::string> edgeId;
    std::string memoryVersionId;

    bool operator==(const MemoryPhiIncomingRecord&) const = default;
};

struct MemoryPhiRecord final {
    std::string id;
    std::string blockId;
    std::string partition;
    std::string outputMemoryVersionId;
    std::vector<MemoryPhiIncomingRecord> incoming;

    bool operator==(const MemoryPhiRecord&) const = default;
};

struct MemoryEffectRecord final {
    std::string id;
    std::string operationId;
    std::string kind;
    std::string partition;
    std::optional<std::string> inputMemoryVersionId;
    std::optional<std::string> outputMemoryVersionId;

    bool operator==(const MemoryEffectRecord&) const = default;
};

struct VariableRecord final {
    std::string id;
    std::string name;
    std::string role;
    std::optional<std::string> typeId;
    std::vector<std::string> storageVarnodeIds;
    std::vector<SourceRange> liveRanges;
    std::string confidence;
    std::string provenance;

    bool operator==(const VariableRecord&) const = default;
};

struct CallRecord final {
    std::string id;
    std::string operationId;
    std::string kind;
    std::optional<Address> targetAddress;
    std::optional<std::string> targetSymbol;
    std::optional<std::string> prototypeTypeId;
    std::vector<std::string> argumentVariableIds;
    std::optional<std::string> resultVariableId;
    std::vector<SourceRange> sourceRanges;

    bool operator==(const CallRecord&) const = default;
};

struct RegionRecord final {
    std::string id;
    std::string kind;
    std::optional<std::string> parentRegionId;
    std::vector<std::string> childRegionIds;
    std::vector<std::string> blockIds;
    std::optional<std::string> conditionOperationId;
    std::vector<SourceRange> sourceRanges;

    bool operator==(const RegionRecord&) const = default;
};

struct TokenEntityReference final {
    std::string kind;
    std::string id;

    bool operator==(const TokenEntityReference&) const = default;
};

struct PseudocodeTokenRecord final {
    std::string id;
    std::string text;
    std::string kind;
    std::uint32_t line = 0;
    std::uint32_t column = 0;
    std::vector<SourceRange> sourceRanges;
    std::vector<TokenEntityReference> entityReferences;

    bool operator==(const PseudocodeTokenRecord&) const = default;
};

/// Bounded provider-rendered presentation. This is independently useful when
/// token, entity, type, variable, or full-SSA records are unavailable and must
/// never be reparsed to fabricate those structured semantics.
struct PseudocodeDocumentRecord final {
    std::string text;
    std::string language;
    bool isComplete = false;
    bool isTruncated = false;

    bool operator==(const PseudocodeDocumentRecord&) const = default;
};

struct DiagnosticRecord final {
    std::string code;
    std::string severity;
    std::string message;
    std::vector<SourceRange> sourceRanges;

    bool operator==(const DiagnosticRecord&) const = default;
};

struct StructuredResult final {
    std::string requestId;
    std::string requestSha256;
    ImageIdentity image;
    FunctionIdentity function;
    std::vector<AddressSpaceRecord> addressSpaces;
    std::vector<TypeRecord> types;
    std::vector<InstructionRecord> instructions;
    std::vector<VarnodeRecord> varnodes;
    std::vector<OperationRecord> operations;
    std::vector<BlockRecord> blocks;
    std::vector<EdgeRecord> edges;
    std::vector<SsaValueRecord> ssaValues;
    std::vector<SsaBindingRecord> ssaBindings;
    std::vector<PhiRecord> phis;
    std::vector<MemoryVersionRecord> memoryVersions;
    std::vector<MemoryPhiRecord> memoryPhis;
    std::vector<MemoryEffectRecord> memoryEffects;
    std::vector<VariableRecord> variables;
    std::vector<CallRecord> calls;
    std::vector<RegionRecord> regions;
    std::vector<PseudocodeTokenRecord> tokens;
    std::optional<PseudocodeDocumentRecord> pseudocodeDocument;
    std::vector<DiagnosticRecord> warnings;
    std::optional<BlockPartitionRecord> blockPartition;

    bool operator==(const StructuredResult&) const = default;
};

/// The boundary must use reply schema 4 for final-CFG metadata or standalone
/// authentication; schema 3 remains valid for unchanged legacy results. Request
/// schema and canonical request hashing are independent and remain unchanged.
[[nodiscard]] std::uint32_t requiredWireReplySchemaVersion(const StructuredResult& result) noexcept;

/// Return a private canonical copy. Lists whose order carries semantics (for
/// example operation inputs, function parameters, call arguments, region
/// children, and pseudocode token positions) retain that semantic order.
[[nodiscard]] StructuredResult canonicalizedStructuredResult(StructuredResult result);

/// In-place convenience wrapper used by qualification and adapter code.
void canonicalizeStructuredResult(StructuredResult& result);

/// Largest encoded size charged per UTF-8 byte of text (UTF-16 storage of
/// non-ASCII text in the binary property-list reply). ASCII text costs one.
inline constexpr std::size_t kMaximumEncodedBytesPerTextByte = 2U;

/// Deterministic upper bound for the encoded structured result in the
/// canonical binary property-list reply (output-size model v3). The closed
/// native codec shares exact primitive string/integer objects; strings and
/// UInt32 token positions are charged once per distinct object plus references.
/// Source ranges charge their exact sixteen-digit address texts. A 16 KiB
/// schema reserve and explicit record/nested-container charges cover structure;
/// general scalar charges remain conservative and do not credit sharing.
/// Four-byte references/offsets suffice under the existing 64 MiB transport
/// ceiling and bounded object counts. This is a publication-size bound only:
/// the actual request/output byte limits still apply, and no ISA semantics,
/// records or budgets are relaxed. Requires integer-sharing codec v3 support.
[[nodiscard]] std::size_t estimatedStructuredResultBytes(
    const StructuredResult& result,
    std::function<void()> checkpoint = {}
);

/// Compatibility name that makes the conservative nature of the estimate
/// explicit at call sites.
[[nodiscard]] std::size_t structuredResultEncodedSizeUpperBound(
    const StructuredResult& result,
    std::function<void()> checkpoint = {}
);

/// Incremental form of estimatedStructuredResultBytes for appending
/// pseudocode tokens to a partially built result. The estimate depends only on
/// the multiset of records, so value() after adding every token equals the
/// estimate of the result that contains them.
class StructuredResultSizeAccumulator final {
public:
    explicit StructuredResultSizeAccumulator(
        const StructuredResult& base,
        std::function<void()> checkpoint = {}
    );
    ~StructuredResultSizeAccumulator();
    StructuredResultSizeAccumulator(const StructuredResultSizeAccumulator&) = delete;
    StructuredResultSizeAccumulator& operator=(const StructuredResultSizeAccumulator&) = delete;

    /// Charges one appended token and returns the new total.
    std::size_t addToken(const PseudocodeTokenRecord& token);
    [[nodiscard]] std::size_t value() const noexcept;

private:
    class State;
    std::unique_ptr<State> state_;
};

void validateStructuredResult(const AnalysisRequestView& request, const StructuredResult& result);

} // namespace macscope::native_decompiler
