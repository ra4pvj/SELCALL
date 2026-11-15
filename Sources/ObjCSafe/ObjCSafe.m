#import "ObjCSafe.h"

@implementation ObjCSafe
+ (nullable NSString *)run:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e.reason ?: e.name;
    }
}
@end
