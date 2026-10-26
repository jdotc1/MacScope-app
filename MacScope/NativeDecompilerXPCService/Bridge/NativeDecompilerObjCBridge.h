#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A request-scoped, monotonic cancellation flag. The bridge observes this
/// handle synchronously and never retains its native flag after returning.
@interface MSNativeDecompilerCancellationHandle : NSObject {
@private
    void *_nativeState;
}
- (void)cancel;
@end

/// Foundation-only adapter used by the XPC service. Package location and
/// native configuration are resolved inside the service process; callers can
/// supply only an opaque binary-plist request and its correlation UUID.
@interface MSNativeDecompilerObjCBridge : NSObject {
@private
    void *_nativeState;
}

/// Resolve, attest, and construct the native backend exactly once. Success and
/// failure are process-global for the service lifetime; later calls return the
/// latched result and never retry partially initialized native state.
- (BOOL)prepare;

- (NSData *)decompileRequestID:(NSUUID *)requestID
                       payload:(NSData *)payload
                  cancellation:(MSNativeDecompilerCancellationHandle *)cancellation;

@end

NS_ASSUME_NONNULL_END
