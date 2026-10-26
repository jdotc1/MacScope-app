#pragma once

#import "NativeDecompilerObjCBridge.h"

#include "MacScopeNativeDecompiler/Backend.hpp"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>

namespace macscope::native_decompiler::xpc_bridge {

enum class WireFailureCode : std::uint8_t {
    malformedRequest,
    invalidRequest,
    nativeFailure,
    packageVerificationFailed,
    busy,
    cancelled,
    timedOut,
    unavailable,
    unsupportedSchemaVersion,
    requestIDMismatch,
    unsupportedCompiler,
    requestTooLarge,
    responseTooLarge,
};

class WireError final : public std::runtime_error {
public:
    WireError(WireFailureCode code, std::string message);

    [[nodiscard]] WireFailureCode code() const noexcept;

private:
    WireFailureCode code_;
};

struct DecodedRequest final {
    AnalysisRequestView request;
};

[[nodiscard]] DecodedRequest decodeRequest(NSData *payload, NSUUID *expectedRequestID);

void validateBinaryPropertyListKeysForTesting(NSData *payload);

[[nodiscard]] NSData *encodeSuccessReply(
    NSUUID *requestID,
    const AnalysisRequestView& request,
    const BackendAvailability& availability,
    const StructuredResult& result
);

[[nodiscard]] NSData *encodeFailureReply(
    NSUUID *requestID,
    WireFailureCode code,
    std::string detail = {}
);

/// Encodes a synthetic, non-publishable fixture through the production result
/// mapping functions so both language implementations can exhaustively prove
/// their frozen enum and optional-field contract.
[[nodiscard]] NSData *encodeMappingCoverageFixtureForTesting();

[[nodiscard]] bool cancellationWasRequested(
    MSNativeDecompilerCancellationHandle *handle
) noexcept;

[[nodiscard]] CancellationToken cancellationToken(
    MSNativeDecompilerCancellationHandle *handle
) noexcept;

} // namespace macscope::native_decompiler::xpc_bridge

@interface MSNativeDecompilerObjCBridge (Testing)
- (NSUInteger)preparationAttemptCountForTesting;
@end
