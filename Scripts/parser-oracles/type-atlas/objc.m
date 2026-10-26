#import <Foundation/Foundation.h>
@protocol Pinger <NSObject>
- (void)ping;
@end
@interface Widget : NSObject <Pinger> @end
@implementation Widget
- (void)ping {}
@end
@interface Child : Widget @end
@implementation Child @end
@interface NSString (OracleExtras)
- (int)oracleValue;
@end
@implementation NSString (OracleExtras)
- (int)oracleValue { return 7; }
@end
int main(void) { [[Child new] ping]; return [@"oracle" oracleValue]; }
