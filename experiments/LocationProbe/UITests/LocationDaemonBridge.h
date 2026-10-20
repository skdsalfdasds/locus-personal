#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// Experimental test-runner interface. Never linked into the installed Waypoint app.
NSDictionary<NSString *, id> *WPSetDaemonLocation(CLLocation *location);
