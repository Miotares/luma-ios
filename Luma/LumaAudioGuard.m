#import "LumaAudioGuard.h"

@implementation LumaAudioGuard

+ (BOOL)attempt:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[LumaAudioGuard] caught AVFoundation exception: %@ — %@", exception.name, exception.reason);
        return NO;
    }
}

@end
