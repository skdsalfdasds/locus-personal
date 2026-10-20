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
| LIEF | Apache-2.0 | https://github.com/lief-project/LIEF |
| Pillow | MIT-CMU | https://github.com/python-pillow/Pillow |
| cryptography | Apache-2.0 OR BSD-3-Clause | https://github.com/pyca/cryptography |
| asn1crypto 1.5.1 | MIT | https://github.com/wbond/asn1crypto |
| keyring | MIT | https://github.com/jaraco/keyring |
| PyInstaller build tooling | GPL with the PyInstaller bootloader exception | https://github.com/pyinstaller/pyinstaller |

LocalDevVPN remains an independently installed App Store application. Its source
is at https://github.com/jkcoxson/LocalDevVPN. This project uses its documented URL
scheme; no LocalDevVPN binary is copied into Waypoint Desktop.

Pairing destination conventions are based on the MIT-licensed idevice_pair
project at https://github.com/jkcoxson/idevice_pair. No pairing records are copied
from that project or distributed with this application.

Sideloadly is a feature reference only. No proprietary Sideloadly code, anisette
plugin, binary, or branding is redistributed.

Exact Rust and JavaScript dependencies are pinned in Cargo.lock and
package-lock.json. Distribution builds must include their license notices and
the corresponding source for copyleft components. No signing credentials,
pairing records, developer account files, or phone data belong in a source archive.

The login and signing flow in native/src/signing_session.rs includes adaptations
from Apparition core. Its MIT notice follows:

Copyright (c) 2026 Illixion

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
