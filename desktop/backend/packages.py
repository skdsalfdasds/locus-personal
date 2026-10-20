from __future__ import annotations
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import tempfile
import zipfile
from collections import deque

MAX_UNPACKED = 4 * 1024**3

def checked_entries(archive: zipfile.ZipFile):
    total = 0
    seen = set()
    entries=archive.infolist()
    links={}
    for entry in entries:
        path = PurePosixPath(entry.filename)
        if path.is_absolute() or '..' in path.parts or any(':' in part for part in path.parts) or '\\' in entry.filename or '\x00' in entry.filename:
            raise ValueError('The IPA contains an unsafe file path.')
        if entry.filename in seen:
            raise ValueError('The IPA contains duplicate file entries.')
        seen.add(entry.filename)
        total += entry.file_size
        if total > MAX_UNPACKED:
            raise ValueError('The unpacked IPA exceeds the 4 GB package limit.')
        if stat.S_ISLNK(entry.external_attr >> 16):
            target = archive.read(entry).decode('utf-8')
            if '\\' in target or '\x00' in target or any(':' in part for part in PurePosixPath(target).parts) or PurePosixPath(target).is_absolute():
                raise ValueError('The IPA contains an unsafe symlink target.')
            links[path.as_posix()]=target
            resolved = os.path.normpath(str(path.parent / target)).replace('\\', '/')
            if target.startswith('/') or resolved.startswith('../') or resolved == '..':
                raise ValueError('The IPA contains a symlink outside its package.')
    # Resolve the complete virtual link graph. Individually safe links can still
    # escape when a parent symlink changes the meaning of ".." in another link.
    for entry in entries:
        pending=deque(PurePosixPath(entry.filename).parts)
        resolved=[]
        followed=0
        while pending:
            part=pending.popleft()
            if part in {'','.'}:continue
            if part=='..':
                if not resolved:raise ValueError('The IPA contains a symlink outside its package.')
                resolved.pop();continue
            if not resolved and part.endswith(':'):
                raise ValueError('The IPA contains an unsafe drive-qualified path.')
            resolved.append(part)
            candidate='/'.join(resolved)
            if candidate in links:
                followed+=1
                if followed>40:raise ValueError('The IPA contains a cyclic or excessively nested symlink.')
                resolved.pop()
                pending.extendleft(reversed(PurePosixPath(links[candidate]).parts))
    return entries


def pack_signed_bundle(app, original_ipa, destination):
    app, destination=Path(app), Path(destination)
    if destination.resolve()==Path(original_ipa).resolve():
        raise ValueError('Export to a different file to preserve the source IPA.')
    with zipfile.ZipFile(original_ipa) as archive:
        original={entry.filename:entry for entry in checked_entries(archive)}
    prefix='Payload/'+app.name+'/'
    destination.parent.mkdir(parents=True,exist_ok=True)
    handle=tempfile.NamedTemporaryFile(dir=destination.parent,suffix='.ipa',delete=False)
    temporary=Path(handle.name);handle.close()
    try:
        with zipfile.ZipFile(temporary,'w',compression=zipfile.ZIP_DEFLATED) as archive:
            for folder, dirs, files in os.walk(app,followlinks=False):
                for name in [*dirs,*files]:
                    path=Path(folder)/name
                    relative=path.relative_to(app).as_posix()
                    stored=prefix+relative
                    old=original.get(stored)
                    if old and stat.S_ISLNK(old.external_attr>>16) and not path.is_symlink():
                        raise ValueError('The signing engine could not preserve a symbolic link on this platform.')
                    if path.is_symlink():
                        info=zipfile.ZipInfo(stored);info.create_system=3
                        info.external_attr=(stat.S_IFLNK|0o777)<<16
                        archive.writestr(info,os.readlink(path).encode('utf-8'))
                    elif path.is_file():
                        info=zipfile.ZipInfo(stored);info.create_system=3
                        info.external_attr=old.external_attr if old else (stat.S_IFREG|0o644)<<16
                        info.compress_type=zipfile.ZIP_DEFLATED
                        with path.open('rb') as source, archive.open(info,'w',force_zip64=True) as target:
                            shutil.copyfileobj(source,target,1024*1024)
        result=inspect_ipa(temporary)
        os.replace(temporary,destination)
        result.update(path=str(destination.resolve()),filename=destination.name,signatureMode='adhoc',appleProvisioned=False)
        return result
    finally:
        temporary.unlink(missing_ok=True)

def main_bundle(names):
    infos = [n for n in names if n.startswith('Payload/') and n.endswith('.app/Info.plist') and n.count('/') == 2]
    if len(infos) != 1:
        raise ValueError('Choose an IPA with exactly one main app in Payload.')
    return infos[0].removesuffix('Info.plist')

def inspect_ipa(path: str | Path):
    path = Path(path)
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    with zipfile.ZipFile(path) as archive:
        entries = list(checked_entries(archive))
        names = [entry.filename for entry in entries]
        bundle = main_bundle(names)
        info = plistlib.loads(archive.read(bundle + 'Info.plist'))
        desktop_setup = info.get('WaypointDesktopSetupVersion', 0)
        plugins = []
        for name in names:
            if name.startswith(bundle + 'PlugIns/') and name.endswith('.appex/Info.plist'):
                detail = plistlib.loads(archive.read(name))
                plugins.append({'path': name.removesuffix('Info.plist'), 'name': detail.get('CFBundleDisplayName', detail.get('CFBundleName', 'Extension')), 'bundleId': detail.get('CFBundleIdentifier', '')})
        icon = None
        candidates = [n for n in names if n.startswith(bundle) and '/' not in n[len(bundle):] and n.lower().endswith('.png') and ('icon' in n.lower())]
        if candidates:
            import base64
            data = archive.read(sorted(candidates, key=lambda x: ('180' in x, '120' in x, x), reverse=True)[0])
            if len(data) < 2_000_000:
                icon = 'data:image/png;base64,' + base64.b64encode(data).decode()
        return {'path': str(path.resolve()), 'filename': path.name, 'name': info.get('CFBundleDisplayName', info.get('CFBundleName', path.stem)), 'bundleId': info.get('CFBundleIdentifier', ''), 'version': info.get('CFBundleShortVersionString', ''), 'build': info.get('CFBundleVersion', ''), 'minimumOS': info.get('MinimumOSVersion', ''), 'size': path.stat().st_size, 'unpackedSize': sum(e.file_size for e in entries), 'extensions': plugins, 'icon': icon, 'signed': bundle + 'embedded.mobileprovision' in names, 'sha256': digest, 'desktopSetupVersion': desktop_setup}

def validate_bundle_id(value):
    import re
    if not isinstance(value, str) or len(value) > 255 or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', value):
        raise ValueError('Enter a bundle ID such as com.example.app.')
    return value

def prepare_ipa(source: str, destination: str, options: dict, progress=lambda *_: None):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Export to a different file to keep the original IPA intact.')
    if options.get('injections'):
        raise ValueError('Tweak injection is not implemented in this engine yet. The original IPA was not changed.')
    if options.get('entitlements'):
        raise ValueError('Custom entitlements must be applied by the signing engine; unsigned plist editing cannot grant them.')
    with zipfile.ZipFile(source) as archive:
        entries = list(checked_entries(archive))
        bundle = main_bundle([e.filename for e in entries])
        main_info = plistlib.loads(archive.read(bundle + 'Info.plist'))
        old_id = main_info.get('CFBundleIdentifier', '')
        new_id = validate_bundle_id(options['bundleId']) if options.get('bundleId') else old_id
        removed = options.get('removeExtensions', [])
        if any(not isinstance(p, str) or not p.startswith(bundle + 'PlugIns/') or not p.endswith('.appex/') or '..' in PurePosixPath(p).parts for p in removed):
            raise ValueError('Invalid extension selection.')
        replacements = {}
        if options.get('iconPath'):
            from PIL import Image
            with Image.open(options['iconPath']) as image:
                for size, suffix in [(120, '60@2x'), (180, '60@3x'), (152, '76@2x'), (167, '83.5@2x')]:
                    out = io.BytesIO()
                    image.convert('RGB').resize((size, size), Image.Resampling.LANCZOS).save(out, format='PNG')
                    replacements[bundle + f'WaypointIcon{suffix}.png'] = out.getvalue()
        destination.parent.mkdir(parents=True, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(dir=destination.parent, suffix='.ipa', delete=False)
        temporary = Path(handle.name)
        handle.close()
        try:
            with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as output:
                for index, entry in enumerate(entries):
                    if any(entry.filename.startswith(prefix) for prefix in removed):
                        continue
                    if options.get('removeAllExtensions') and entry.filename.startswith(bundle + 'PlugIns/'):
                        continue
                    # Editing invalidates old signatures. The signer creates fresh signatures.
                    if '/_CodeSignature/' in entry.filename or entry.filename == bundle + 'embedded.mobileprovision':
                        continue
                    data = archive.read(entry)
                    if entry.filename.startswith(bundle) and entry.filename.endswith('/Info.plist'):
                        info = plistlib.loads(data)
                        identity = info.get('CFBundleIdentifier', '')
                        if new_id != old_id and (identity == old_id or identity.startswith(old_id + '.')):
                            info['CFBundleIdentifier'] = new_id + identity[len(old_id):]
                        if entry.filename == bundle + 'Info.plist':
                            if options.get('appName'):
                                info['CFBundleDisplayName'] = options['appName']
                            if options.get('version'):
                                info['CFBundleShortVersionString'] = options['version']
                            if options.get('minimumOS'):
                                info['MinimumOSVersion'] = options['minimumOS']
                            if options.get('fileSharing'):
                                info.update(UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True)
                            if options.get('removeDeviceRestrictions'):
                                info.pop('UIRequiredDeviceCapabilities', None)
                                info['UIDeviceFamily'] = [1, 2]
                            custom = options.get('plistChanges', {})
                            if not isinstance(custom, dict):
                                raise ValueError('Info.plist changes must be a JSON object.')
                            protected = {'CFBundleExecutable', 'CFBundlePackageType', 'CFBundleIdentifier'}
                            if protected.intersection(custom):
                                raise ValueError('Executable, package type and bundle ID must use their dedicated controls.')
                            info.update(custom)
                            if replacements:
                                info.pop('CFBundleIconName', None)
                                icons = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['WaypointIcon60', 'WaypointIcon76', 'WaypointIcon83.5']}}
                                info['CFBundleIcons'] = icons
                                info['CFBundleIcons~ipad'] = icons
                        data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)
                    output.writestr(entry, data)
                    if index % 40 == 0:
                        progress('Preparing package', round(index / max(1, len(entries)) * 100))
                for filename, data in replacements.items():
                    output.writestr(filename, data)
            # Read it back before making the export visible.
            result = inspect_ipa(temporary)
            os.replace(temporary, destination)
            result.update(path=str(destination.resolve()), filename=destination.name, signed=False)
            return result
        finally:
            temporary.unlink(missing_ok=True)
