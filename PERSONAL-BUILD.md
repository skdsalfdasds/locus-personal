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
Stop clears the saved hold target and requests restoration of real GPS.

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
This derivative uses bundle identifier `com.locus.personal` and version 1.1.1.
Public repositories with standard hosted runners have free Actions builds;
private repositories use the account's Actions allowance and may incur charges.

## Verification status

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
arrival hold; tunnel interruption/reconnection; Stop restoring actual GPS.

Local checks completed: all 10 new/modified Swift files parse without syntax errors;
project/workflow YAML and resource plists parse; the build shell script passes Bash
syntax checking; git diff passes whitespace checks. These are not a Swift typecheck
or a physical-device test. See VERIFICATION.txt for the successful remote build and
the checks that still require an iPhone.
