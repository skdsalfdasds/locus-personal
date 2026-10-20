#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN
// Experimental test-runner interface. Never linked into the installed Waypoint app.
NSDictionary<NSString *, id> *WPSetDaemonLocation(CLLocation *location);
NS_ASSUME_NONNULL_END
