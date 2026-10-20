# Waypoint Desktop

A desktop interface for installing Waypoint, signing IPAs, managing pairing
records, and viewing connected Apple devices.

This is a development build. The Windows runtime is self-contained: it bundles
Electron, Python, the device service, a native Rust signing/pairing helper, and
the unsigned Waypoint 1.5.2 package. Installing the desktop application does not
install anything on a phone. Phone setup starts only after an explicit action.

## Automatic Waypoint setup

1. Connect and unlock a supported iPhone.
2. The app checks computer trust, Developer Mode, and whether LocalDevVPN is installed.
3. Enter an Apple account and password, then select Install Waypoint.
4. Complete Apple's verification prompt if requested.
5. The app signs and installs Waypoint, creates remote pairing, and transfers the
   record into Waypoint's Documents folder.
6. Open Waypoint on the phone. It imports the staged record only when no saved
   pairing exists. Connect LocalDevVPN and approve the iOS VPN configuration.

Apple controls the required trust, Developer Mode, verification, and VPN approvals.
The desktop app does not bypass those prompts or restart the phone. A pre-existing
Waypoint installation is not replaced by automatic setup.

Windows currently defaults to the SideStore public Anisette v3 service listed in
https://github.com/SideStore/anisette-servers. It was reachable during development.
The URL is shown in the interface and can be changed. Password authentication is
handled by the local native engine against Apple; the Anisette provider supplies
verification data. macOS and Linux have an optional bundled local provider.

## Active phone protection

This laptop has a local policy protecting the user's existing active Waypoint
session. Setup, installation, pairing changes, wireless setting changes, and
uninstallation are blocked for that device. Read-only discovery does not alter
the phone's location or existing pairing.

The policy lives in the user's application data directory, outside source and
build artifacts. It is not copied into installers for other users. A malformed
policy blocks writes instead of silently disabling protection.

## Offline IPA export

The Sideload page can export a modified unsigned IPA or an ad-hoc signed IPA
without a connected phone or Apple account. Ad-hoc export supports an optional
JSON entitlement dictionary for the main executable. It preserves the source
IPA, strips Apple provisioning, verifies the generated code-directory hashes,
and publishes the output only after successful validation.

An ad-hoc signature does not authorize installation on a standard iPhone. Use
Apple-account or certificate/profile signing for normal installation. Custom
entitlements for those Apple-provisioned modes remain in development.

The offline verification fixture in scripts/verify-adhoc.py independently checks
the code-page and entitlement digests and rejects modified executable data.

## Managed installations and manual refresh

Successful sideloads are recorded with the signed bundle identifier and a private
copy of the input used for signing. Customizations are applied once before that
copy is saved, so a later refresh does not depend on the original download or
rename the app again. Embedded profile metadata supplies the expiration date;
unknown or malformed metadata is shown as unknown. Reading metadata does not
verify an Apple signature.

For Apple-account installs, Applications exposes Refresh while the same Apple
account is connected. The backend uses the stored device association, checks
source integrity, and rechecks protection before installation. Existing-signed
and certificate installs require their appropriate new signing material through
Sideload instead of promising to extend a fixed profile's expiration.

Refresh sources and signing workspaces stay on this computer. Cancellation waits
for an in-progress signer before removing its inputs, and never proceeds to
installation after cancellation. Automatic refresh and session restoration across
restart are still in development.

## Development

Requirements: Node.js, Python 3.13, Rust, and the platform's native C/C++ build tools.
The native dependencies are pinned to exact upstream commits in native/Cargo.toml.

    npm ci
    python -m venv .venv
    # Activate .venv, then:
    pip install -r backend/requirements.txt
    cargo build --release --manifest-path native/Cargo.toml
    npm run build
    npm run desktop

To assemble the runtime on the target operating system:

    python scripts/make-icons.py
    python scripts/build-runtime.py

Place a verified unsigned Waypoint 1.5.2-or-later IPA at runtime/apps/Waypoint.ipa.
Its Info.plist must declare WaypointDesktopSetupVersion=1 for automatic pairing.
Then use package:win, package:mac, or package:linux. Platform-native helpers must
be built on the corresponding target; a Windows helper is not a macOS binary.

## Verification

- TypeScript and Vite production build.
- Python package transformation, failure handling, setup orchestration, and
  protected-device tests using mocked transports.
- Electron navigation, light/dark appearance, no-icons assertion, and disabled
  device-write controls.
- Native helper compilation and read-only USB discovery on Windows.
- Frozen Python runtime and bundled IPA inspection on Windows.

Apple sign-in, code signing with a real account, a real new installation, and
pairing transfer have not been exercised end-to-end on an unprotected phone.
macOS and Linux binaries are not yet verified. See REQUIREMENTS.md for remaining
work; this build does not yet provide full Sideloadly/idevice_pair parity.

## Licensing

GPL-3.0-or-later; see LICENSE and THIRD-PARTY-NOTICES.md. No proprietary
Sideloadly binaries are included. LocalDevVPN is installed separately from the App
Store. Pairing and signing credentials stay out of the source distribution.
