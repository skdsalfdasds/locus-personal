# Completion criteria and current evidence

The requested goal includes all Sideloadly and idevice_pair functionality on
Windows, macOS, and Linux, plus investigating richer iOS location interfaces.
Do not mark the goal complete based on a working dashboard or Windows prototype.

Statuses below distinguish implemented code from verification on a physical device.

| Requirement | Current state |
| --- | --- |
| Clean professional UI, no decorative icons | Implemented; Electron navigation and no-SVG/image checks pass |
| Purposeful animation | Page/dialog transitions, progressive stages, animated progress bar; reduced-motion support |
| One setup flow: Apple login → sign → install → pair → transfer | Implemented; orchestration tests pass using mocked transports |
| Real Apple account login and 2FA | Native engine integrated; six-digit code, resend, trusted-device delivery and trusted-number SMS controls implemented. Backend validates single-use active challenges and closes expired prompts; live account verification remains outstanding |
| USB discovery and device metadata | Verified read-only on Windows with iPhone 16e / iOS 26.5.2 |
| Wireless discovery via Apple device service | Implemented through usbmux; independent Wi-Fi verification outstanding |
| Read-only Developer Mode detection | Implemented and verified before phone disconnection |
| Developer Mode onboarding | Instructions implemented; no automatic restart |
| LocalDevVPN onboarding | Installed-app detection, App Store link, existing iOS deep-link support |
| Automatic first-launch pairing import in Waypoint | 1.5.2 source compiles in macOS CI; existing saved pairing never replaced |
| Preserve current active phone session | Local policy enforced before device writes; unit tests fail closed |
| IPA drag-and-drop and inspection | Implemented and tested |
| Name, bundle ID, version, minimum OS changes | Implemented; package transformation tests pass |
| Custom app image | Implemented via package editor; physical icon appearance unverified |
| File sharing, device metadata restrictions | Implemented; source binary preserved; device behavior unverified |
| Remove selected/all plugins | Implemented; package tests pass |
| Edit Info.plist | Implemented; protected identity/executable keys enforced |
| Free/paid Apple signing | Native engine integrated; developer-team selection and identity-preserving refresh guards implemented. Live account signing and full account-limit management UI remain outstanding |
| Certificate/profile signing | Native engine integrated; live signing/installation verification outstanding |
| Normal install of already-signed IPA | Implemented; rejects unsigned customization in this mode |
| Modified unsigned IPA export | Implemented and tested |
| Ad-hoc signing/export | Implemented offline; actual Waypoint export independently verified across 1,861 code pages, tamper rejection and source preservation; frozen Windows runtime passed the same checks |
| Custom entitlements | Main executable supported for ad-hoc export, including verified entitlement seal; Apple-account/certificate customization remains outstanding |
| Multiple dylib/framework/bundle/deb injections | Outstanding |
| Substrate/Substitute support | Outstanding |
| Keep signing sessions across restart | Implemented password-free native token restoration, encrypted local cache with key in a system credential store, asynchronous startup, reconnect and sign-out. Native/Python mocked lifecycle tests pass; real Apple restoration and actual OS-vault interaction remain unverified |
| Account and certificate management | Read-only listing integrated; explicit revoke/delete UI outstanding |
| Automatic app refresh daemon and Wi-Fi renewal | Outstanding |
| Refresh expiry detection and recovery | Installs save actual signed identity, signing-account/team snapshot, private refresh input and earliest readable profile expiry. Manual refresh checks original identity/source integrity, including after waiting for the signing lock. Interrupted operations retain known outcomes and never auto-retry. Automatic scheduling and physical renewal remain outstanding |
| JIT for eligible iOS versions | Outstanding |
| Apple TV and Apple Silicon Mac installation | Outstanding |
| Install progress and logs | Implemented; real signing stage refinement and system log viewer outstanding |
| Privacy/identifier hiding | Implemented |
| Desktop URI installation scheme | Outstanding |
| Remote and Lockdown pairing creation | Implemented; native remote creation not executed on protected phone |
| Pairing import/export | XML/binary import and export implemented; key consistency, deduplication and device association tested without hardware |
| Pairing live validation | Native remote/Lockdown authentication implemented and compiled; failed authentication cannot bind a record; not run on protected phone |
| Known-app pairing destinations | Full upstream destination list plus Waypoint and LiveContainer subfolder path implemented; mocked transfer contract tested |
| mDNS discovery, Apple TV PIN, iOS 27 host PIN | Outstanding |
| Wireless debugging control | Implemented behind protection guard; not invoked on protected phone |
| Windows one-click desktop installer | Packaged preview built and launched; frozen runtime, pairing import and write protection verified |
| macOS and Linux installers | All four targets passed through actual assembled-app checks in runs 39360546983, 39362574205 and 39364465591 (including verification controls). New session persistence/team-selection revision needs its next packaged run |
| License/source distribution completeness | Core notices prepared; full bundled dependency/source inventory outstanding before public release |
| Rich speed location interface investigation | Simulator run 39365186326 passed direct daemon and app-to-runner socket delivery, speed/course/accuracy, invalid-credential rejection, held coordinate after socket-server stop and field/freshness boundary checks. The exact shared client source compiles into Waypoint but is not enabled in its production flow. Production activation, physical delivery, runner lifecycle and Life360 classification remain unverified. No physical probe has run |
| Life360 recognizes simulated driving activity | Unverified. No supported Core Motion automotive setter identified; coordinate speed alone does not prove drive recognition |

## Protected-phone constraint

Do not test real installation, pairing, VPN changes, location simulation, app
launch/termination, or reboot against the user's current phone. No current
location setting or installed Waypoint app may be altered.

## Evidence

- Isolated location-probe build: https://github.com/skdsalfdasds/locus-personal/actions/runs/39323608589
- Waypoint 1.5.2 build and existing movement tests: https://github.com/skdsalfdasds/locus-personal/actions/runs/39324349511
- Desktop source tests are local in tests/; do not mistake mocked orchestration
  for successful physical installation or Life360 drive recognition.
- Desktop platform build: https://github.com/skdsalfdasds/locus-personal/actions/runs/39341388486
- Current simulator launch-order experiment: https://github.com/skdsalfdasds/locus-personal/actions/runs/39348961613
- Revised cross-platform build: https://github.com/skdsalfdasds/locus-personal/actions/runs/39347865988
- Backend tests and desktop navigation/offline-export/manual-refresh/interruption/SMS/session controls pass locally. Native validation
  compiles in release mode. Frozen Windows backend import and protection checks
  use synthetic records and never open a phone service.
