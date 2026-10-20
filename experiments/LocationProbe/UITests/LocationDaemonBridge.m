#import "LocationDaemonBridge.h"

// Selector signatures verified against Appium's BSD-licensed WebDriverAgent,
// FBXCTestDaemonsProxy.m. This bridge is an independent implementation.
@interface NSObject (WaypointLocationDaemon)
+ (id)sharedSession;
- (BOOL)supportsLocationSimulation;
- (void)setSimulatedLocation:(CLLocation *)location completion:(void (^)(BOOL, NSError *))completion;
@end

NSDictionary<NSString *, id> *WPSetDaemonLocation(CLLocation *location) {
    Class type = NSClassFromString(@"XCTRunnerDaemonSession");
    if (type == Nil || ![type respondsToSelector:@selector(sharedSession)]) {
        return @{@"supported": @NO, @"accepted": @NO, @"reason": @"Test-runner daemon session is unavailable"};
    }
    id session = [(id)type sharedSession];
    if (![session respondsToSelector:@selector(supportsLocationSimulation)] ||
        ![session respondsToSelector:@selector(setSimulatedLocation:completion:)] ||
        ![session supportsLocationSimulation]) {
        return @{@"supported": @NO, @"accepted": @NO, @"reason": @"This runtime does not expose daemon location simulation"};
    }
    NSLock *lock = [NSLock new];
    __block BOOL finished = NO;
    __block BOOL accepted = NO;
    __block NSString *failure = nil;
    [session setSimulatedLocation:location completion:^(BOOL result, NSError *error) {
        [lock lock];
        accepted = result && error == nil;
        failure = error.localizedDescription;
        finished = YES;
        [lock unlock];
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while ([deadline timeIntervalSinceNow] > 0) {
        [lock lock];
        BOOL done = finished;
        [lock unlock];
        if (done) break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    [lock lock];
    NSDictionary *reply = @{@"supported": @YES, @"accepted": @(finished && accepted),
        @"reason": finished ? (failure ?: @"") : @"Daemon did not complete within ten seconds"};
    [lock unlock];
    return reply;
}
