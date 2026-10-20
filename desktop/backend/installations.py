"""Installation lifecycle. Device transports are only reached after protection checks."""
import asyncio
import contextlib
import hashlib
from datetime import datetime, timezone
from pathlib import Path
import re
import shutil
import tempfile
import uuid

from backend.library import cache_source, installation_metadata
from backend.packages import inspect_ipa, prepare_ipa


def extraction_cache(filename):
    # Upstream Application::new extracts filename.ipa under the OS temp folder.
    # Only our newly generated UUID filenames qualify for cleanup.
    if not re.fullmatch(r'[0-9a-f-]{36}\.ipa',filename):
        raise ValueError('Invalid signing workspace name.')
    base=Path(tempfile.gettempdir()).resolve()
    return base/(filename+'_extracted')


def cleanup_extraction(candidate):
    if candidate is None or not candidate.exists():return
    base=Path(tempfile.gettempdir()).resolve()
    resolved=candidate.resolve()
    if resolved.parent!=base or resolved!=candidate or candidate.is_symlink():
        raise RuntimeError('Refusing to remove an unexpected signing workspace.')
    if not re.fullmatch(r'[0-9a-f-]{36}\.ipa_extracted',resolved.name):
        raise RuntimeError('Refusing to remove an unowned signing workspace.')
    shutil.rmtree(resolved)


async def remember_install(backend,device_id,metadata,source,params):
    from backend.server import clean_error
    matching=[entry for entry in backend.records('library')
              if str(entry.get('deviceId','')).casefold()==device_id.casefold()
              and entry.get('bundleId')==metadata['bundleId']]
    entry={**(matching[0] if matching else {}),**metadata,
           'id':matching[0]['id'] if matching else str(uuid.uuid4()),
           'deviceId':device_id,'installed':datetime.now(timezone.utc).isoformat(),
           'signingMode':params.get('mode','appleId'),'originalPath':params.get('originalPath',params.get('path'))}
    for key in ('identityId','profileId'):
        entry.pop(key,None)
        if params.get(key):entry[key]=params[key]
    entry['accountEmail']=(backend.account or {}).get('email') if entry['signingMode']=='appleId' else None
    try:
        entry['sourcePath'],entry['sourceSha256']=await asyncio.to_thread(cache_source,backend.root,source)
        entry.pop('sourceError',None)
    except (OSError,ValueError) as error:
        entry.update(sourcePath=None,sourceSha256=None,sourceError=clean_error(error))
    entry['refreshable']=entry['signingMode']=='appleId' and bool(entry.get('sourceSha256'))
    backend.save_record('library',entry)
    # A reinstall updates one managed entry instead of accumulating stale copies.
    for duplicate in matching[1:]:
        backend.db.execute('DELETE FROM library WHERE id=?',(duplicate['id'],))
    backend.db.commit()
    return entry


async def settle_signing(backend,params):
    # Cancelling the UI job must not remove files while the signer still owns
    # them. Finish this local operation, then propagate cancellation before any
    # installation. Repeated cancellation requests are coalesced by Backend.
    signing=asyncio.create_task(backend.native_call('ipa.sign',params))
    try:return await asyncio.shield(signing)
    except asyncio.CancelledError:
        with contextlib.suppress(Exception):await signing
        raise


async def run(backend,job,params):
    from backend.server import clean_error
    device_id=params['deviceId'];cache=None;owns_cache=False
    lock=backend.device_locks.setdefault(device_id,asyncio.Lock())
    try:
        async with lock:
            backend.require_device_writes(device_id)
            workspaces=backend.root/'install-workspaces';workspaces.mkdir(exist_ok=True)
            with tempfile.TemporaryDirectory(dir=workspaces,prefix='install-',ignore_cleanup_errors=True) as workspace:
                original=Path(workspace)/(str(uuid.uuid4())+'.ipa')
                await asyncio.to_thread(shutil.copyfile,params['path'],original)
                if params.get('expectedSourceSha256'):
                    with original.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
                    if digest!=params['expectedSourceSha256']:
                        raise ValueError('The saved refresh source has changed. Select the original IPA again.')
                await asyncio.to_thread(inspect_ipa,original)
                source=original
                options=params.get('options',{})
                if options:
                    backend.update_job(job,'Preparing app')
                    source=Path(workspace)/(str(uuid.uuid4())+'.ipa')
                    await asyncio.to_thread(prepare_ipa,str(original),str(source),options)
                path=source
                if params.get('mode','appleId')!='existing':
                    cache=extraction_cache(source.name)
                    if cache.exists():raise RuntimeError('A signing workspace already exists. Retry with a new workspace.')
                    owns_cache=True
                    backend.require_device_writes(device_id)
                    backend.update_job(job,'Signing with your selected identity')
                    signed=await settle_signing(backend,{**params,'path':str(source)})
                    path=Path(signed['signedPath'])
                metadata=await asyncio.to_thread(installation_metadata,path)
                backend.require_device_writes(device_id)
                backend.update_job(job,'Uploading and installing')
                from pymobiledevice3.services.installation_proxy import InstallationProxyService
                async with backend.device(device_id) as device:
                    backend.require_device_writes(device_id)
                    async with InstallationProxyService(device) as service:
                        backend.require_device_writes(device_id)
                        await service.install_from_local(path,handler=lambda percent,*_:backend.update_job(job,'Installing app',progress=percent))
                job['result']={'installed':True,'bundleId':metadata['bundleId']}
                entry=await remember_install(backend,device_id,metadata,source,params)
                job['result']['libraryId']=entry['id']
                job['result']['refreshSourceSaved']=bool(entry.get('sourcePath'))
                stage='Installed successfully' if entry.get('sourcePath') else 'Installed; refresh source could not be saved'
                backend.update_job(job,stage,status='succeeded',progress=100)
    except asyncio.CancelledError:
        backend.update_job(job,'Cancelled; an interrupted device installation may require retrying',status='cancelled')
    except Exception as error:
        prefix='App installed; local tracking failed: ' if job.get('result',{}).get('installed') else ''
        backend.update_job(job,prefix+clean_error(error),status='failed')
    finally:
        if owns_cache:
            try:await asyncio.to_thread(cleanup_extraction,cache)
            except (OSError,RuntimeError) as error:
                job.setdefault('result',{})['cleanupWarning']=clean_error(error)
                backend.save_record('jobs',job)
        backend.jobs.pop(job['id'],None)
