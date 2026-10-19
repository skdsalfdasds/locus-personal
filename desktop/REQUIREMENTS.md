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
| Real Apple account login and 2FA | Native engine compiles; interactive UI implemented; live account verification outstanding |
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
| Free/paid Apple signing | Native engine integrated; live accounts, team selection, limits UI outstanding |
| Certificate/profile signing | Native engine integrated; live signing/installation verification outstanding |
| Normal install of already-signed IPA | Implemented; rejects unsigned customization in this mode |
| Modified unsigned IPA export | Implemented and tested |
| Ad-hoc signing/export | Outstanding |
| Custom entitlements | Outstanding |
| Multiple dylib/framework/bundle/deb injections | Outstanding |
| Substrate/Substitute support | Outstanding |
| Keep signing sessions across restart | Outstanding; password is not saved |
| Account and certificate management | Read-only listing integrated; explicit revoke/delete UI outstanding |
| Automatic app refresh daemon and Wi-Fi renewal | Outstanding |
| Refresh expiry detection and recovery | Managed library started; full renewal and expiry handling outstanding |
| JIT for eligible iOS versions | Outstanding |
| Apple TV and Apple Silicon Mac installation | Outstanding |
| Install progress and logs | Implemented; real signing stage refinement and system log viewer outstanding |
| Privacy/identifier hiding | Implemented |
| Desktop URI installation scheme | Outstanding |
| Remote and Lockdown pairing creation | Implemented; native remote creation not executed on protected phone |
| Pairing import/export | Export implemented; import outstanding |
| Pairing live validation | Outstanding |
| Known-app pairing destinations | Core filenames implemented; full LiveContainer/subfolder handling outstanding |
| mDNS discovery, Apple TV PIN, iOS 27 host PIN | Outstanding |
| Wireless debugging control | Implemented behind protection guard; not invoked on protected phone |
| Windows one-click desktop installer | Build prepared; final packaged smoke test required |
| macOS and Linux installers | Build configuration present; target-specific builds/testing outstanding |
| License/source distribution completeness | Core notices prepared; full bundled dependency/source inventory outstanding before public release |
| Rich speed location interface investigation | Isolated XCTest probe compiles successfully in macOS CI; not installed or run on the protected phone |
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
