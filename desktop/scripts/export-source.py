"""Export only reviewed source files, validating the entire selection first."""
from pathlib import Path
import argparse
import json
import os
import re
import shutil

ROOTS = {'backend':{'.py','.txt'}, 'src':{'.tsx','.ts','.css'}, 'electron':{'.cjs'},
         'scripts':{'.py','.cjs','.mjs'}, 'tests':{'.py','.cjs'}, 'assets/icons':{'.png','.ico','.icns'},
         'native/src':{'.rs'}}
FILES = ('package.json', 'package-lock.json', 'tsconfig.json', 'vite.config.ts', 'index.html',
         '.gitignore', 'LICENSE', 'README.md', 'REQUIREMENTS.md', 'THIRD-PARTY-NOTICES.md',
         'native/Cargo.toml', 'native/Cargo.lock')
FORBIDDEN = {'.tools', '.venv', '.data', 'outputs', 'runtime', 'node_modules', 'target', '__pycache__'}
BINARY = {'.png', '.ico', '.icns'}
SECRET = re.compile(r'gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')


def selection(source, identifiers=()):
    paths = []
    for folder, extensions in ROOTS.items():
        for path in (source/folder).rglob('*'):
            if not path.is_file() or '__pycache__' in path.parts or path.suffix in {'.pyc','.log'}:
                continue
            if path.suffix not in extensions:
                raise ValueError('Unexpected file type in source: '+str(path.relative_to(source)))
            paths.append(path)
    paths.extend(source/name for name in FILES)
    for path in paths:
        relative = path.relative_to(source)
        if not path.is_file() or FORBIDDEN.intersection(relative.parts):
            raise ValueError('Unexpected source path: ' + str(relative))
        if path.suffix not in BINARY:
            text = path.read_text(encoding='utf-8')
            if SECRET.search(text) or any(value in text for value in identifiers):
                raise ValueError('Sensitive content detected in ' + str(relative))
    return paths


def export(source, destination, identifiers=()):
    source, destination = source.resolve(), destination.resolve()
    if destination == source or destination.is_relative_to(source):
        raise ValueError('Export outside the working source tree.')
    paths = selection(source, identifiers)
    # No destination is created or partially updated if preflight validation fails.
    for path in paths:
        target = destination/path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    return len(paths)


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('destination', type=Path)
    args=parser.parse_args()
    source=Path(__file__).resolve().parent.parent
    identifiers=[]
    if os.name=='nt':
        policy=Path(os.environ['APPDATA'])/'Waypoint Desktop/device-protection.json'
        if policy.is_file():
            identifiers=json.loads(policy.read_text(encoding='utf-8'))['protectedDeviceIds']
    count=export(source,args.destination,identifiers)
    print('Validated and exported '+str(count)+' source files; private runtime data excluded.')
