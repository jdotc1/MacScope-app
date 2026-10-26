#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <stdio.h>

@interface WS15OracleTarget : NSObject
- (id)zero;
- (id)one:(id)value;
- (id)first:(id)first second:(id)second;
- (id)mixed:(double)value object:(id)object;
@end

@implementation WS15OracleTarget
- (id)zero {
    return self;
}

- (id)one:(id)value {
    return value;
}

- (id)first:(id)first second:(id)second {
    (void)first;
    return second;
}

- (id)mixed:(double)value object:(id)object {
    return value == 37.25 ? object : nil;
}
@end

typedef id (*WS15TypedSend0)(id, SEL);
typedef id (*WS15TypedSend1)(id, SEL, id);
typedef id (*WS15TypedSend2)(id, SEL, id, id);

__attribute__((noinline, used, visibility("default")))
id ws15_canonical_zero(SEL selector, id receiver) {
    return ((WS15TypedSend0)(void *)objc_msgSend)(receiver, selector);
}

__attribute__((noinline, used, visibility("default")))
id ws15_canonical_one(id value, id receiver, SEL selector) {
    return ((WS15TypedSend1)(void *)objc_msgSend)(receiver, selector, value);
}

__attribute__((noinline, used, visibility("default")))
id ws15_canonical_two(id first, id receiver, id second, SEL selector) {
    return ((WS15TypedSend2)(void *)objc_msgSend)(receiver, selector, first, second);
}

__attribute__((noinline, used, visibility("default")))
id ws15_normal_zero(id decoy, WS15OracleTarget *receiver) {
    (void)decoy;
    return [receiver zero];
}

__attribute__((noinline, used, visibility("default")))
id ws15_normal_one(id value, WS15OracleTarget *receiver) {
    return [receiver one:value];
}

__attribute__((noinline, used, visibility("default")))
id ws15_normal_two(id second, WS15OracleTarget *receiver, id first) {
    return [receiver first:first second:second];
}

__attribute__((noinline, used, visibility("default")))
id ws15_normal_mixed(
    double decoy,
    id object,
    WS15OracleTarget *receiver,
    double value
) {
    (void)decoy;
    return [receiver mixed:value object:object];
}

int main(void) {
    @autoreleasepool {
        WS15OracleTarget *target = [WS15OracleTarget new];
        NSObject *first = [NSObject new];
        NSObject *second = [NSObject new];

        if (ws15_normal_zero(first, target) != target) {
            return 10;
        }
        if (ws15_normal_one(first, target) != first) {
            return 11;
        }
        if (ws15_normal_two(second, target, first) != second) {
            return 12;
        }
        if (ws15_normal_mixed(-1.0, first, target, 37.25) != first) {
            return 13;
        }
        if (ws15_canonical_zero(@selector(zero), target) != target) {
            return 20;
        }
        if (ws15_canonical_one(first, target, @selector(one:)) != first) {
            return 21;
        }
        if (ws15_canonical_two(
                first,
                target,
                second,
                @selector(first:second:)
            ) != second) {
            return 22;
        }

        puts("objc-call-argument-sentinels-ok");
    }
    return 0;
}
