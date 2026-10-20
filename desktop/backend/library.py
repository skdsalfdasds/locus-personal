"""Local installation records and refresh inputs. Never opens a device service."""
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import zipfile

from asn1crypto import cms
from backend.packages import checked_entries, main_bundle


def profile_expiration(data):
    """Read CMS payload metadata, not a claim that the CMS signature is trusted."""
    if len(data)>16*1024*1024:raise ValueError('Provisioning metadata exceeds the size limit.')
    container=cms.ContentInfo.load(data,strict=True)
    if container['content_type'].native!='signed_data':raise ValueError('Not a signed provisioning container.')
    payload=container['content']['encap_content_info']['content'].native
    if not isinstance(payload,bytes):raise ValueError('Provisioning metadata has no payload.')
    info=plistlib.loads(payload)
    expiry=info.get('ExpirationDate') if isinstance(info,dict) else None
    if not isinstance(expiry,datetime):raise ValueError('Provisioning metadata has no expiration date.')
    return expiry.replace(tzinfo=timezone.utc) if expiry.tzinfo is None else expiry.astimezone(timezone.utc)


def installation_metadata(path):
    path=Path(path)
    if path.is_dir():
        info=plistlib.loads((path/'Info.plist').read_bytes())
        profiles=[p for p in path.rglob('embedded.mobileprovision')
                  if p.is_file() and not p.is_symlink() and p.resolve().is_relative_to(path.resolve())]
        main_profile=path/'embedded.mobileprovision'
        profile_data=[(p==main_profile,p.read_bytes()) for p in profiles if p.stat().st_size<=16*1024*1024]
    else:
        with zipfile.ZipFile(path) as archive:
            entries=checked_entries(archive);prefix=main_bundle([item.filename for item in entries])
            info=plistlib.loads(archive.read(prefix+'Info.plist'))
            profile_data=[(item.filename==prefix+'embedded.mobileprovision',archive.read(item))
                for item in entries if item.filename.startswith(prefix) and item.filename.endswith('/embedded.mobileprovision')
                and item.file_size<=16*1024*1024]
    bundle=info.get('CFBundleIdentifier')
    if not isinstance(bundle,str) or not bundle:raise ValueError('The signed app has no bundle identifier.')
    dates=[];main_expiry=None;invalid=False
    for main,data in profile_data:
        try:
            expiry=profile_expiration(data);dates.append(expiry)
            if main:main_expiry=expiry
        except (ValueError,TypeError,KeyError,IndexError,OverflowError):invalid=True
    # Unknown/malformed profiles must not become an invented seven-day deadline.
    expires=min(dates).isoformat() if main_expiry is not None and not invalid else None
    return {'bundleId':bundle,'name':info.get('CFBundleDisplayName',info.get('CFBundleName',bundle)),
            'version':str(info.get('CFBundleShortVersionString','')),'expires':expires,
            'profileStatus':'metadata-read' if expires else 'unknown',
            'profileSignatureVerified':False}


def cache_source(root,source):
    """Publish an immutable, content-addressed local source for later refreshes."""
    source=Path(source)
    with source.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
    directory=Path(root)/'library-sources';directory.mkdir(exist_ok=True,mode=0o700)
    destination=directory/(digest+'.ipa')
    if destination.is_file():
        with destination.open('rb') as stream:
            if hashlib.file_digest(stream,'sha256').hexdigest()==digest:
                return str(destination),digest
    with tempfile.NamedTemporaryFile(dir=directory,suffix='.ipa',delete=False) as handle:
        temporary=Path(handle.name)
    try:
        shutil.copyfile(source,temporary)
        with temporary.open('rb') as stream:
            if hashlib.file_digest(stream,'sha256').hexdigest()!=digest:
                raise ValueError('The refresh source changed while it was being saved.')
        os.replace(temporary,destination)
    finally:temporary.unlink(missing_ok=True)
    return str(destination),digest
