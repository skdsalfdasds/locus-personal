"""Build on the target OS. The result includes its own Python and native engine."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
runtime = root / 'runtime'
runtime.mkdir(exist_ok=True)
name = 'waypoint-engine.exe' if sys.platform == 'win32' else 'waypoint-engine'
engine = root / 'native/target/release' / name
if not engine.is_file():
    raise SystemExit('Build the native engine first: cargo build --release --manifest-path native/Cargo.toml')
subprocess.run([
    sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir',
    '--console', '--name', 'waypoint-backend', '--paths', str(root),
    '--distpath', str(runtime), '--workpath', str(root/'.data/pyinstaller'),
    '--specpath', str(root/'.data'),
    '--collect-submodules', 'pymobiledevice3', '--collect-data', 'pymobiledevice3',
    '--collect-data', 'developer_disk_image', '--hidden-import', 'PIL.Image',
    '--hidden-import', 'cryptography', '--hidden-import', 'keyring',
    str(root/'backend/entry.py'),
], check=True, cwd=root)
shutil.copy2(engine, runtime/name)
if sys.platform != 'win32':
    (runtime/name).chmod(0o755)
print('Runtime ready:', runtime)
