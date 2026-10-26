#import <Foundation/Foundation.h>

@interface Animal : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSInteger legs;
- (NSString *)describe;
- (NSInteger)legsTimes:(NSInteger)factor;
@end

@implementation Animal
- (NSString *)describe {
    return [NSString stringWithFormat:@"%@ has %ld legs", self.name, (long)self.legs];
}
- (NSInteger)legsTimes:(NSInteger)factor { return self.legs * factor; }
@end

@interface Animal (Sounds)
- (NSString *)sound;
@end

@implementation Animal (Sounds)
- (NSString *)sound { return @"generic"; }
@end

NSInteger addNumbers(NSInteger a, NSInteger b) { return a + b; }
NSString *joinNames(NSArray<NSString *> *names) { return [names componentsJoinedByString:@", "]; }
void runBlock(void (^block)(NSInteger)) { block(42); }
