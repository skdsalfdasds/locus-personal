# Rich location interface probe

This is an isolated experiment, not an enabled Waypoint location backend. It uses
`XCTRunnerDaemonSession.setSimulatedLocation:completion:` with a full
`CLLocation` carrying speed, speed accuracy, and course. The separate host app
records the values delivered by its own CLLocationManager callbacks and actual
Core Motion activity. A setter succeeding does not prove speed was delivered.

Simulator evidence: run 39362218294 delivered live 0 -> 30 -> 0 m/s phases,
speed accuracy 0.100 and course 90 to an independent Core Location observer after
an independent live simctl movement control succeeded. Physical-device delivery,
runner lifecycle, and Life360 drive recognition are unverified.
There is no motion activity setter here. The test does not patch,
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

The daemon bridge uses private XCTest runtime selectors guarded for availability;
the earlier public proxy experiment worked at launch but ignored live updates in
that fixture. No WebDriverAgent code body or binary is copied into Waypoint.

## App-to-runner transport

`Locus/Engine/RichLocationRelay.swift` defines the sample format and an asynchronous
loopback client. The probe includes that exact client source. It is linked but
never instantiated by the production Waypoint app; existing DVT behavior remains.
The probe host's explicit buttons exercise the client while a separate XCTest
runner receives authenticated, bounded newline-JSON requests at 127.0.0.1:32777.
Each runner test generates a fresh 256-bit session credential, passes it only to
its host process, validates fields/freshness and dispatches to the daemon bridge.
No Apple password or pairing record is sent through this protocol. It exposes
no clear/restore operation; a client disconnect only closes its socket.

The next CI revision checks moving/stationary samples through the actual socket
and client, unauthorized-client rejection, and held position after server stop.
This does not yet solve production test-session activation, background/lock
behavior, signing the runner for an individual account, or automotive motion.
