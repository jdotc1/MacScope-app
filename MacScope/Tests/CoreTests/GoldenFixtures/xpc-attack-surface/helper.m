#import <Foundation/Foundation.h>

@protocol FixtureControl
- (void)statusWithReply:(void (^)(NSString *))reply;
- (void)setMode:(NSString *)mode;
- (void)reset;
@end

@interface FixtureDelegate : NSObject <NSXPCListenerDelegate, FixtureControl>
@end
@implementation FixtureDelegate
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(FixtureControl)];
    connection.exportedObject = self;
    [connection resume];
    return YES;
}
- (void)statusWithReply:(void (^)(NSString *))reply { reply(@"ready"); }
- (void)setMode:(NSString *)mode { (void)mode; }
- (void)reset {}
@end
int main(void) {
    @autoreleasepool {
        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:@"com.example.fixture.control"];
        FixtureDelegate *delegate = [FixtureDelegate new];
        listener.delegate = delegate;
        [listener resume];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
