#import <Foundation/Foundation.h>

@interface MSSignatureCandidateFixture : NSObject
- (NSString *)lookupIndex:(NSInteger)index error:(NSError **)error;
@end

@implementation MSSignatureCandidateFixture
- (NSString *)lookupIndex:(NSInteger)index error:(NSError **)error
{
    if (index < 0 && error != NULL) {
        *error = [NSError errorWithDomain:@"MSSignatureCandidateFixture"
                                     code:index
                                 userInfo:nil];
        return nil;
    }
    return [NSString stringWithFormat:@"%ld", (long)index];
}
@end
