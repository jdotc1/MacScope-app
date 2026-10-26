#import <Foundation/Foundation.h>
int main(void) {
    @autoreleasepool {
        NSXPCListener *listener = [NSXPCListener anonymousListener];
        [listener resume];
    }
    return 0;
}
