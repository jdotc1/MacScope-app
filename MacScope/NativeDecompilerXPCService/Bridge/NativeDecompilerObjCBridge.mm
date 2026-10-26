#import "NativeDecompilerObjCBridge.h"
#import "NativeDecompilerWireBridge.hpp"

#include "MacScopeNativeDecompiler/GhidraProvider.hpp"

#include <memory>
#include <mutex>
#include <string>
#import <os/log.h>

using namespace macscope::native_decompiler;
using namespace macscope::native_decompiler::xpc_bridge;

namespace {

// Never log native exception text: it can contain analyzed names or paths.
// A bounded fingerprint lets local diagnostics correlate fixed contract errors
// without exposing the exception's contents or changing the wire outcome.
void recordFailureFingerprint(const char *category, const char *text) noexcept {
    std::uint64_t fingerprint = 14695981039346656037ULL;
    for (std::size_t i = 0; text != nullptr && i < 1024 && text[i] != '\0'; ++i) {
        fingerprint ^= static_cast<unsigned char>(text[i]);
        fingerprint *= 1099511628211ULL;
    }
    os_log_error(OS_LOG_DEFAULT, "MacScope native failure category=%{public}s fingerprint=%{public}llx",
                 category, static_cast<unsigned long long>(fingerprint));
}

// The validated backend keeps only MacScope-shaped reason codes (see
// lastSuppressedProviderFailureReason), so the code is safe to log publicly and
// names the exact provider contract that rejected the request.
void recordSuppressedProviderReason() noexcept {
    const std::string_view reason = macscope::native_decompiler::lastSuppressedProviderFailureReason();
    if (reason.empty()) return;
    os_log_error(OS_LOG_DEFAULT, "MacScope native failure provider-reason=%{public}.*s",
                 static_cast<int>(reason.size()), reason.data());
}

struct BridgeState final {
    enum class Readiness : std::uint8_t { unprepared, ready, failed };

    std::mutex mutex;
    std::unique_ptr<StructuredDecompilerBackend> backend;
    Readiness readiness = Readiness::unprepared;
    std::size_t preparationAttempts = 0;
};

BridgeState& processBridgeState() {
    static BridgeState state;
    return state;
}

std::string internalMaterializationRoot() {
    NSURL *resources = NSBundle.mainBundle.resourceURL;
    NSURL *package = [resources URLByAppendingPathComponent:@"NativeDecompilerPackage"
                                                isDirectory:YES];
    NSString *path = package.path;
    if (path == nil || path.length == 0) {
        throw ContractError("native-package-resource-unavailable");
    }
    NSData *utf8 = [path dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (utf8 == nil || utf8.length == 0) {
        throw ContractError("native-package-resource-unavailable");
    }
    return {static_cast<const char *>(utf8.bytes), utf8.length};
}

NSData *stableFailure(NSUUID *requestID, WireFailureCode code, std::string detail = {}) noexcept {
    @try {
        try {
            return encodeFailureReply(requestID, code, std::move(detail));
        } catch (...) {
            NSDictionary *fallback = @{
                @"schemaVersion": @3,
                @"requestID": requestID.UUIDString,
                @"outcome": @"failure",
                @"failure": @{@"code": @"native-failure"},
            };
            NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:fallback
                                                                           format:NSPropertyListBinaryFormat_v1_0
                                                                          options:0
                                                                            error:nil];
            return encoded == nil ? [NSData data] : encoded;
        }
    } @catch (__unused NSException *exception) {
        return [NSData data];
    }
}

bool prepareLocked(BridgeState& state) noexcept {
    if (state.readiness == BridgeState::Readiness::ready) return true;
    if (state.readiness == BridgeState::Readiness::failed) return false;

    ++state.preparationAttempts;
    try {
        const auto configuration = makeGhidraBackendConfigurationForMaterialization(
            internalMaterializationRoot(), "AARCH64:LE:64:AppleSilicon", "default"
        );
        auto backend = makeGhidraBackend(configuration);
        const BackendAvailability availability = backend->availability();
        if (!availability.available) {
            state.readiness = BridgeState::Readiness::failed;
            return false;
        }
        state.backend = std::move(backend);
        state.readiness = BridgeState::Readiness::ready;
        return true;
    } catch (...) {
        state.backend.reset();
        state.readiness = BridgeState::Readiness::failed;
        return false;
    }
}

} // namespace

@implementation MSNativeDecompilerObjCBridge

- (instancetype)init {
    self = [super init];
    if (self != nil) _nativeState = &processBridgeState();
    return self;
}

- (void)dealloc {
    _nativeState = nullptr;
}

- (BOOL)prepare {
    auto *state = static_cast<BridgeState *>(_nativeState);
    std::lock_guard lock(state->mutex);
    return prepareLocked(*state);
}

- (NSData *)decompileRequestID:(NSUUID *)requestID
                       payload:(NSData *)payload
                  cancellation:(MSNativeDecompilerCancellationHandle *)cancellation {
    try {
        DecodedRequest decoded = decodeRequest(payload, requestID);
        if (cancellationWasRequested(cancellation)) {
            return stableFailure(requestID, WireFailureCode::cancelled);
        }

        auto *state = static_cast<BridgeState *>(_nativeState);
        std::lock_guard lock(state->mutex);
        if (cancellationWasRequested(cancellation)) {
            return stableFailure(requestID, WireFailureCode::cancelled);
        }
        // Startup preparation is the sole authority allowed to attest the
        // package and construct the process-global backend. Request handling
        // must never turn an omitted or failed startup gate into a lazy retry.
        if (state->readiness == BridgeState::Readiness::unprepared) {
            return stableFailure(requestID, WireFailureCode::unavailable);
        }
        if (state->readiness == BridgeState::Readiness::failed) {
            return stableFailure(requestID, WireFailureCode::packageVerificationFailed);
        }
        const BackendAvailability availability = state->backend->availability();
        if (!availability.available) {
            return stableFailure(requestID, WireFailureCode::unavailable);
        }
        StructuredResult result = state->backend->decompile(
            decoded.request, cancellationToken(cancellation)
        );
        if (cancellationWasRequested(cancellation)) {
            return stableFailure(requestID, WireFailureCode::cancelled);
        }
        return encodeSuccessReply(requestID, decoded.request, availability, result);
    } catch (const WireError& error) {
        recordFailureFingerprint("wire", error.what());
        // Wire errors carry fixed MacScope-authored messages (for example "native
        // opcode is not representable in the current wire schema"), so the reply
        // names the cause instead of a bare failure class.
        return stableFailure(requestID, error.code(), std::string(error.what()));
    } catch (const ContractError& error) {
        recordFailureFingerprint("contract", error.what());
        recordSuppressedProviderReason();
        if (cancellationWasRequested(cancellation)) {
            return stableFailure(requestID, WireFailureCode::cancelled);
        }
        if (std::string_view(error.what()) ==
            "native-provider-operation-opcode-unavailable") {
            return stableFailure(requestID, WireFailureCode::unavailable);
        }
        // The suppressed reason is a MacScope-shaped code (never third-party
        // text), so the reply carries it and Export All can name the cause.
        return stableFailure(requestID, WireFailureCode::nativeFailure,
                             std::string(macscope::native_decompiler::lastSuppressedProviderFailureReason()));
    } catch (const std::exception& error) {
        recordFailureFingerprint("exception", error.what());
        return stableFailure(requestID, WireFailureCode::nativeFailure);
    } catch (...) {
        return stableFailure(requestID, WireFailureCode::nativeFailure);
    }
}

@end

@implementation MSNativeDecompilerObjCBridge (Testing)

- (NSUInteger)preparationAttemptCountForTesting {
    auto *state = static_cast<BridgeState *>(_nativeState);
    std::lock_guard lock(state->mutex);
    return state->preparationAttempts;
}

@end
