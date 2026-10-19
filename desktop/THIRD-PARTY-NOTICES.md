# Third-party components

Waypoint Desktop is distributed under GPL-3.0-or-later. Its Python device service
imports pymobiledevice3, which uses that license. The user interface and native
helper communicate with the device service through JSON over process pipes.

Main components:

| Component | License | Source |
| --- | --- | --- |
| pymobiledevice3 11.34.1 | GPL-3.0-or-later | https://github.com/doronz88/pymobiledevice3 |
| Apparition core and its vendored isideload | MIT | https://github.com/illixion/Apparition |
| idevice | MIT | https://github.com/jkcoxson/idevice |
| apple-codesign, used unmodified by the signer | MPL-2.0 | https://github.com/indygreg/apple-platform-rs |
| Electron | MIT and bundled Chromium/Node notices | https://github.com/electron/electron |
| React | MIT | https://github.com/facebook/react |
| Lucide icons | ISC | https://github.com/lucide-icons/lucide |
| Inter | OFL-1.1 | https://github.com/rsms/inter |
| LIEF | Apache-2.0 | https://github.com/lief-project/LIEF |
| Pillow | MIT-CMU | https://github.com/python-pillow/Pillow |
| cryptography | Apache-2.0 OR BSD-3-Clause | https://github.com/pyca/cryptography |
| keyring | MIT | https://github.com/jaraco/keyring |
| PyInstaller build tooling | GPL with the PyInstaller bootloader exception | https://github.com/pyinstaller/pyinstaller |

LocalDevVPN remains an independently installed App Store application. Its source
is at https://github.com/jkcoxson/LocalDevVPN. This project uses its documented URL
scheme; no LocalDevVPN binary is copied into Waypoint Desktop.

Sideloadly is a feature reference only. No proprietary Sideloadly code, anisette
plugin, binary, or branding is redistributed.

Exact Rust and JavaScript dependencies are pinned in Cargo.lock and
package-lock.json. Distribution builds must include their license notices and
the corresponding source for copyleft components. No signing credentials,
pairing records, developer account files, or phone data belong in a source archive.
