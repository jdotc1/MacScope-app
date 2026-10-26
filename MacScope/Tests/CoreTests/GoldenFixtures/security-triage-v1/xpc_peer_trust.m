#import <Foundation/Foundation.h>
#import <unistd.h>

@interface SEC1Connection : NSObject
- (int)processIdentifier;
- (id)auditToken;
- (void)setCodeSigningRequirement:(NSString *)requirement;
@end

@implementation SEC1Connection
- (int)processIdentifier { return getpid(); }
- (id)auditToken { return @"fixture-audit-token"; }
- (void)setCodeSigningRequirement:(NSString *)requirement { (void)requirement; }
@end

@interface SEC1PIDListener : NSObject
- (BOOL)listener:(id)listener shouldAcceptNewConnection:(SEC1Connection *)connection;
@end

@implementation SEC1PIDListener
- (BOOL)listener:(id)listener shouldAcceptNewConnection:(SEC1Connection *)connection {
    (void)listener;
    return connection.processIdentifier == getpid();
}
@end

@interface SEC1UnconditionalListener : NSObject
- (BOOL)listener:(id)listener shouldAcceptNewConnection:(SEC1Connection *)connection;
@end

@implementation SEC1UnconditionalListener
- (BOOL)listener:(id)listener shouldAcceptNewConnection:(SEC1Connection *)connection {
    (void)listener;
    (void)connection;
    return YES;
}
@end

@interface SEC1AuditTokenListener : NSObject
- (BOOL)listener:(id)listener shouldAcceptNewConnection:(SEC1Connection *)connection;
@end

@implementation SEC1AuditTokenListener
- (BOOL)listener:(id)listener shouldAcceptNewConnection:(SEC1Connection *)connection {
    (void)listener;
    return connection.auditToken != nil;
}
@end

@interface SEC1CodeSigningListener : NSObject
- (BOOL)listener:(id)listener shouldAcceptNewConnection:(SEC1Connection *)connection;
@end

@implementation SEC1CodeSigningListener
- (BOOL)listener:(id)listener shouldAcceptNewConnection:(SEC1Connection *)connection {
    (void)listener;
    [connection setCodeSigningRequirement:@"anchor apple generic"];
    return YES;
}
@end
