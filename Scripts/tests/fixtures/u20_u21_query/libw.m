typedef struct objc_object *id;
typedef struct objc_selector *SEL;
__attribute__((objc_root_class))
@interface Root { id isa; }
+ (id)alloc;
- (id)init;
@end
@interface Widget : Root
+ (id)sharedWidget;
- (int)render:(int)x;
- (void)close;
@end
@interface Gadget : Root
- (int)render:(int)x;
@end
extern int puts(const char *);
@implementation Root
+ (id)alloc { return 0; }
- (id)init { return self; }
@end
@implementation Widget
+ (id)sharedWidget { return [[Widget alloc] init]; }
- (int)render:(int)x { puts("widget render"); return x + 1; }
- (void)close { puts("closing"); }
@end
@implementation Gadget
- (int)render:(int)x { return x * 2; }
@end
int drive(id obj) { [obj close]; return [obj render:3]; }
