"""Explicit setup workflow. Merely discovering a phone never starts this flow."""
from __future__ import annotations

import asyncio
from pathlib import Path
import os
import sys
import uuid
import shutil

from backend.packages import inspect_ipa
from backend.library import installation_metadata
from backend.installations import cleanup_extraction, extraction_cache, remember_install, settle_signing

VPN_STORE_URL = 'https://apps.apple.com/us/app/localdevvpn/id6755608044'
PAIRING_FILENAME = 'waypoint-setup-pairing.plist'


def bundled_ipa():
    if os.environ.get('WAYPOINT_BUNDLED_IPA'):
        return Path(os.environ['WAYPOINT_BUNDLED_IPA'])
    base = Path(sys.executable).parent if getattr(sys, 'frozen', False) else Path(__file__).resolve().parent.parent / 'runtime'
    return base / 'apps' / 'Waypoint.ipa'


async def check(backend, device_id):
    device = next((d for d in await backend.list_devices() if d['id'] == device_id), None)
    if device is None:
        raise ValueError('Connect an iPhone over USB and unlock it.')
    apps = await backend.list_apps(device_id) if device['trusted'] else []
    vpn = next((a for a in apps if a['name'].replace(' ', '').lower() == 'localdevvpn'), None)
    waypoint = next((a for a in apps if a['name'] in {'Waypoint', 'Locus'}), None)
    return {
        'device': device,
        'trusted': device['trusted'],
        'developerMode': device.get('developerMode') is True,
        'localDevVPNInstalled': vpn is not None,
        'waypointInstalled': waypoint is not None,
        'localDevVPNStoreURL': VPN_STORE_URL,
        'bundledPackage': str(bundled_ipa()) if bundled_ipa().is_file() else None,
        'protected': backend.is_protected(device_id),
        # There is no desktop API here to determine another app's live VPN state.
        'vpnConnected': None,
    }


async def run(backend, job, params):
    """Authenticate -> sign -> install -> pair -> transfer. Never launches an app."""
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    device_id = params['deviceId']
    unique=None;cache=None;owns_cache=False
    lock = backend.device_locks.setdefault(device_id.casefold(), asyncio.Lock())
    try:
        async with lock:
            backend.require_device_writes(device_id)
            backend.update_job(job, 'Checking device', progress=3)
            state = await check(backend, device_id)
            if not state['trusted']:
                raise ValueError('Unlock the iPhone and trust this computer before continuing. No app has been changed.')
            if not state['developerMode']:
                raise ValueError('Enable Settings → Privacy & Security → Developer Mode on the iPhone, complete its required restart, then run setup again. Waypoint Desktop will not restart your device.')
            if state['waypointInstalled'] and not params.get('replaceExisting'):
                raise ValueError('Waypoint is already installed. Setup will not replace a running app or its pairing. Use the Sideload page for an explicit update on an unprotected device.')

            path = Path(params.get('path') or bundled_ipa())
            package = inspect_ipa(path)
            if package['bundleId'] != 'com.locus.personal':
                raise ValueError('The automatic Waypoint flow requires an official Waypoint package. Use Sideload for another app.')
            if package.get('desktopSetupVersion', 0) < 1:
                raise ValueError('This Waypoint package predates automatic pairing import. Select version 1.5.2 or later.')

            if not backend.account:
                backend.update_job(job, 'Signing in to Apple', progress=12)
                login = {key: params[key] for key in ('email', 'password', 'anisetteUrl') if params.get(key)}
                try:
                    backend.account = await backend.native_call('account.login', login)
                finally:
                    login.pop('password', None)
                    params.pop('password', None)
            backend.require_device_writes(device_id)
            backend.update_job(job, 'Signing Waypoint', progress=27)
            inputs=backend.root/'prepared';inputs.mkdir(exist_ok=True)
            unique=inputs/(str(uuid.uuid4())+'.ipa')
            await asyncio.to_thread(shutil.copyfile,path,unique)
            cache=extraction_cache(unique.name)
            if cache.exists():raise RuntimeError('A signing workspace already exists. Retry setup.')
            owns_cache=True
            signed = await settle_signing(backend, {
                'path': str(unique), 'deviceId': device_id,
                'deviceName': state['device']['name'], 'mode': 'appleId',
            })
            signed_path = Path(signed['signedPath'])
            metadata=await asyncio.to_thread(installation_metadata,signed_path)
            actual_bundle_id=metadata['bundleId']

            backend.require_device_writes(device_id)
            backend.update_job(job, 'Installing Waypoint', progress=45)
            async with backend.device(device_id) as device:
                backend.require_device_writes(device_id)
                async with InstallationProxyService(device) as service:
                    backend.require_device_writes(device_id)
                    await service.install_from_local(signed_path, handler=lambda percent, *_:
                        backend.update_job(job, 'Installing Waypoint', progress=45 + min(100, max(0, percent)) * .3))
                    installed = await service.get_apps(application_type='User')
                    if actual_bundle_id not in installed:
                        raise RuntimeError('Installation finished without confirming Waypoint on the device. Pairing was not changed.')

            job['result']={'installed':True,'pairingTransferred':False,'bundleId':actual_bundle_id}
            if metadata['name']==actual_bundle_id:metadata['name']=package['name']
            if not metadata['version']:metadata['version']=package['version']
            entry=await remember_install(backend,device_id,metadata,unique,{'path':str(path),'mode':'appleId'})
            job['result']['libraryId']=entry['id']
            backend.require_device_writes(device_id)
            backend.update_job(job, 'Creating remote pairing', progress=80)
            record = await backend.dispatch('pairing.createRemote', {'deviceId': device_id})
            backend.update_job(job, 'Sending pairing to Waypoint', progress=92)
            await backend.dispatch('pairing.install', {
                'deviceId': device_id, 'pairingId': record['id'],
                'bundleId': actual_bundle_id, 'filename': PAIRING_FILENAME,
            })
            job['result'] = {
                **job.get('result',{}),
                'installed': True, 'pairingTransferred': True, 'bundleId': actual_bundle_id,
                'localDevVPNInstalled': state['localDevVPNInstalled'],
                'nextStep': 'Open Waypoint on the iPhone. It imports the staged pairing only if it has no saved pairing. Then connect LocalDevVPN and approve the iOS prompts.',
            }
            backend.update_job(job, 'Waypoint installed and pairing transferred', status='succeeded', progress=100)
    except asyncio.CancelledError:
        backend.update_job(job, 'Setup cancelled. Completed installation steps are retained; no app or pairing is removed.', status='cancelled')
    except Exception as error:
        from backend.server import clean_error
        backend.update_job(job, clean_error(error), status='failed')
    finally:
        from backend.server import clean_error
        params.pop('password', None)
        warnings=[]
        if owns_cache:
            try:await asyncio.to_thread(cleanup_extraction,cache)
            except (OSError,RuntimeError) as error:warnings.append(clean_error(error))
        if unique is not None:
            try:unique.unlink(missing_ok=True)
            except OSError as error:warnings.append(clean_error(error))
        if warnings:
            job.setdefault('result',{})['cleanupWarnings']=warnings
            backend.save_record('jobs',job)
        backend.jobs.pop(job['id'], None)
