#import <Foundation/Foundation.h>
int main(void) {
    @autoreleasepool {
        NSXPCListener *listener = [NSXPCListener serviceListener];
        [listener resume];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
