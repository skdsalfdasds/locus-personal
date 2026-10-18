# Personal Locus changes

This is a local MIT-licensed derivative of ChrisMack32/Locus. The original interface,
address autocomplete, favorites, joystick, map modes, road routing, and GPX import remain.

Added: 1–85 MPH control, route distance and estimated travel time, automatic route
preview for a selected pin or address, explicit Move and Teleport buttons, movement
pause/resume, live speed changes, and optional modest speed variation in Routes.

Playback uses actual segment distances rather than rounding every substep up to a
fixed distance. A tunnel failure keeps the route cursor in place and retries instead
of skipping ahead. After arrival or teleporting, the app resends its last position.
The last confirmed coordinate is saved locally and reapplied when the app opens.
Stop ends movement and holds the last confirmed position. Restore real location
clears the saved hold target and requests restoration of real GPS.

The app's existing silent audio and background-location facilities are now connected
to the movement session. This targets screen-locked use; it is not a guarantee of
continuous execution. A powered-off phone cannot run playback. Force quitting,
rebooting, iOS suspension, tunnel loss, and expired signing can interrupt it. Life360
has not been tested. GPX coordinates are imported, but imported GPX timestamps do
not control this version's playback; the MPH control does.

## Build without owning a Mac

The supplied GitHub Actions workflow uses a hosted macOS runner and Xcode 26.3.
Upload only this source repository, not its parent folder. No route addresses,
pairing records, Apple credentials, signing keys, or iAnyGo binaries are required
for the build. The resulting IPA is unsigned and must be signed/sideloaded locally.

1. Put this source in your own GitHub repository with Actions enabled.
2. Run Actions → Build personal Locus IPA → Run workflow.
3. Download the Locus-personal-unsigned artifact.
4. Sign and sideload Locus-personal-unsigned.ipa with a suitable local signing tool.
5. Import your own RPPairing file and use LocalDevVPN, as described in SETUP.md.

The workflow does not publish a release or upload Apple signing credentials.
This derivative uses bundle identifier `com.locus.personal` and version 1.4.0.
Public repositories with standard hosted runners have free Actions builds;
private repositories use the account's Actions allowance and may incur charges.

## Verification status

Version 1.4.0 (build 11) defaults to Automatic. Road-route distance divided by
MapKit calculateETA's traffic-aware expected travel time sets the average speed,
bounded to 0.1–85 MPH. Estimates refresh after about five minutes, with cached
speed retained during internet failures. This is an overall pace estimate, not
per-road traffic, posted speed limits, or traffic-light simulation.

Smooth speed variation replaces independent random samples with continuous
50-second and 19-second drift components, totaling up to 4% in either direction.
Upcoming bends within 60 meters lower the target by up to another 4%. Changes
are limited to 0.35 m/s² acceleration and 0.55 m/s² braking. The profile starts
at the selected average speed; it does not simulate accelerating from rest.
Turning variation off uses the selected average directly. Pauses and failed
location sends do not advance the movement clock or route cursor.

Draw route now displays numbered tap points, a path, instructions, Undo, Cancel,
and Use manual route. It joins tapped waypoints with straight segments, then
keeps that route for Move. Drawing and GPX switch Automatic to manual Drive,
retaining the user's manual MPH. Selecting Automatic rebuilds a road route.

Full Release build and native timing, speed-change limits, bends, ETA/cache
recovery, saved-state, hold confirmation, connection failure, and tunnel checks passed:
https://github.com/skdsalfdasds/locus-personal/actions/runs/39117427248
IPA archive integrity and version/build metadata passed local inspection.
Physical-iPhone UI, live Apple Maps traffic requests, and background behavior
with this release remain unverified.

Version 1.3.2 (build 10) trims the active route polyline from the last confirmed
position through the remaining waypoints. It uses playback's waypoint cursor so
crossings and loops cannot skip ahead. Pauses and failed sends retain the current
line; arrival or Stop removes it without redisplaying the full original preview.
The full source path remains available for GPX export.
Full iPhone Release build and all native checks, including route trimming and loops,
passed: https://github.com/skdsalfdasds/locus-personal/actions/runs/39115453966
Physical-device appearance remains unverified until the signed update is installed.

Version 1.3.1 (build 9) restores the standard MapKit blue location indicator during
route and joystick movement and initializes travel mode to Drive. Saved custom MPH
is retained. Walk/Run use walking directions; Bike/Drive currently use automobile
directions, with different preset speeds. Bike does not request bicycle-specific
routing. The extra simulated-location circle/annotation remains removed.

Version 1.3.0 (build 8) consolidates the map tray to speed/options, ETA, and contextual
movement actions. Travel modes, speed, variation, joystick, saved places, settings,
map styles, drawing, routes, and GPX remain reachable through Movement options,
More, and Map tools. Coordinates and detailed errors moved into Movement options.
Restore real location now requires an initial warning followed by a continuous
three-second hold with gradient progress, glow, and haptic feedback. Early release,
dragging outside, dismissing, or backgrounding cancels. A short-lived confirmation
permit is required by the session's restore API; a tap or accumulated partial holds
cannot issue one. Stop remains separate and never calls the clear API.
On send failure, route/hold intent is retained and retried. Fault-injected tests
exercise the actual Swift LocationEngine against a C test double and verify failed
sends, tunnel creation failure, and recovery never call location_simulation_clear.
This is not a guarantee against iOS resetting its override if the local VPN or
developer connection disappears; cellular/internet loss is separate from that tunnel.
Full Release build and all native checks passed:
https://github.com/skdsalfdasds/locus-personal/actions/runs/39114305504
Phone animation/gesture validation and real VPN-outage behavior remain pending.

Version 1.2.1 (build 7) adds seconds to ETA. Stop now cancels movement and persists
the last confirmed position as a hold; it does not call the simulation clear API.
The separate Restore real location action removes saved intent and requests a clear,
reconnecting without setting coordinates if necessary. A failed clear does not restart
hold maintenance automatically and reports retry/restart guidance.
Full Release build, ETA checks, and mid-route stop/hold/restore persistence checks passed:
https://github.com/skdsalfdasds/locus-personal/actions/runs/39113552370
Device validation of Stop and Restore real location remains pending.

Version 1.2.0 (build 6) removes the extra simulated-location annotation and hides
the MapKit location dot during route/joystick movement. A background location activity
session, lock-accessible pairing/audio files, audio route recovery, and common-mode
hold/retry timers improve operation while the screen is locked or another app is open.
The route and last confirmed cursor are saved separately; reopening resumes saved
progress without jumping ahead for time spent terminated. Arrival saves a persistent
hold target, including retry intent if initial reconnection fails. Restore real location clears it.
The full Release build, movement, tunnel, and saved-state checks passed:
https://github.com/skdsalfdasds/locus-personal/actions/runs/39113203387
Screen-lock, background duration, and Life360 behavior remain unverified on the phone.
Force quitting terminates active maintenance. Reopening restores intent; this cannot
guarantee a coordinate survives force quit, system suspension, restart, or power-off.

Version 1.1.1 (build 5) adds explicit action colors for readable disabled buttons
and a destination hint. VPN status now checks the configured developer endpoint
instead of guessing from interface addresses; active location-session status takes
precedence. A failed probe reports an unresponsive tunnel, not a disconnected VPN.
The full Release build, movement checks, and executable TCP reachability/closed-port/
cancellation checks passed: https://github.com/skdsalfdasds/locus-personal/actions/runs/39112327113
The revised interface and LocalDevVPN behavior still need physical-device verification.

The Windows laptop has no Xcode/iOS SDK. The hosted macOS build now completed
successfully with Xcode 26.3, including the executable movement timing checks.
The downloaded unsigned IPA passed archive and metadata inspection.
Build: https://github.com/skdsalfdasds/locus-personal/actions/runs/39109528693
The IPA is in outputs/Locus-personal-unsigned.ipa and still needs local signing.
No simulator or physical-iPhone behavior has been verified yet.

The workflow includes executable checks for MPH units, ETA, and segment pacing.
Device acceptance: address search and pin route previews; distance and ETA;
Move vs Teleport; speed changes while moving; pause/resume; screen-lock playback;
arrival hold; tunnel interruption/reconnection; Stop holding the current point;
Restore real location clearing the override.

Local checks completed: all 10 new/modified Swift files parse without syntax errors;
project/workflow YAML and resource plists parse; the build shell script passes Bash
syntax checking; git diff passes whitespace checks. These are not a Swift typecheck
or a physical-device test. See VERIFICATION.txt for the successful remote build and
the checks that still require an iPhone.
