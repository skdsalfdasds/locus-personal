# Rich location interface probe

This is an isolated experiment, not a new Waypoint location backend. It uses
`XCUIDevice.shared.location = XCUILocation(location: sample)` with a full
`CLLocation` carrying speed, speed accuracy, and course. The separate host app
records the values delivered by its own CLLocationManager callbacks and actual
Core Motion activity. A setter succeeding does not prove speed was delivered.

Status: source prepared; physical-device delivery and Life360 drive recognition
are unverified. There is no motion activity setter here. The test does not patch,
inject into, or launch Life360.

## Build and run

The `Build location interface probe` GitHub Actions workflow compiles two unsigned
IPAs using a standard macOS runner. The host and XCTest runner must both be signed
for the phone before installation. An active developer test session is required;
this is not a regular background iOS application.

After signing and installing both apps, use pymobiledevice3's developer DVT
`xcuitest` command with the *actual signed runner bundle ID*. If signing changed
the host bundle ID, pass `--env WAYPOINT_PROBE_HOST_BUNDLE_ID=<actual-host-id>`.
A working developer tunnel and Developer Mode are required.

Do not start the probe during an important existing location session. It changes
the system location to a synthetic coordinate near Apple Park for about 20 seconds.
It issues no explicit clear command, but XCTest may clean up its simulation when
the test ends. It cannot promise to preserve a previous override.

The host's Documents/location-observations.jsonl is local and can contain real
location data before or after the simulation. Do not upload that file or pairing
records. Read the cruise phase's independently observed `speed`, `speedAccuracy`,
`course`, and `simulatedBySoftware`; then compare automotive activity separately.

Sources:
- https://developer.apple.com/documentation/xcuiautomation/xcuilocation
- https://developer.apple.com/documentation/corelocation/cllocation
- https://developer.apple.com/documentation/coremotion/cmmotionactivity/automotive
- https://github.com/appium/WebDriverAgent/blob/master/WebDriverAgentLib/Utilities/FBXCTestDaemonsProxy.m

The probe uses Apple's public XCTest API directly; it does not copy WebDriverAgent.
