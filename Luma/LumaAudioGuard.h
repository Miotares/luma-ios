#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs an AVFoundation operation that may raise an Objective-C NSException — e.g. AVAudioEngine /
/// AVAudioPlayerNode assertions like "required condition is false: _engine->IsRunning()" or
/// "player started when in a disconnected state", which fire during audio route changes (wired
/// headset plug, car Bluetooth). Those are Obj-C NSExceptions, NOT Swift errors, so Swift
/// try?/do-catch cannot catch them and they abort the app. This wrapper catches them so the Swift
/// caller can recover (rebuild the graph / stay paused) instead of crashing.
@interface LumaAudioGuard : NSObject

/// Runs `block`. Returns YES if it completed normally, NO if it raised an NSException (swallowed).
+ (BOOL)attempt:(void (NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END
