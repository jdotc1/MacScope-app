#include <stdint.h>

#if defined(__clang__)
#define MACSCOPE_EXPORT __attribute__((visibility("default"), noinline, used))
#else
#define MACSCOPE_EXPORT
#endif

__attribute__((objc_root_class))
@interface MacScopeDCPObject
- (int64_t)combine:(int64_t)first with:(int64_t)second;
@end

@implementation MacScopeDCPObject
- (int64_t)combine:(int64_t)first with:(int64_t)second {
    return (first * INT64_C(3)) + second;
}
@end

MACSCOPE_EXPORT int64_t macscope_fixture_objc_dispatch(
    MacScopeDCPObject *receiver,
    int64_t first,
    int64_t second
) {
    const int64_t result = [receiver combine:first with:second];
    return result ^ INT64_C(0x5a);
}
