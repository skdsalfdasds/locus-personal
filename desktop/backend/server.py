from __future__ import annotations
import asyncio
import contextlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sqlite3
import sys
import uuid

from backend.packages import inspect_ipa, prepare_ipa, pack_signed_bundle

NATIVE_TIMEOUT_SECONDS=900

def now():
    return datetime.now(timezone.utc).isoformat()

def data_root():
    if os.environ.get('WAYPOINT_DATA_DIR'):
        return Path(os.environ['WAYPOINT_DATA_DIR'])
    if sys.platform == 'win32':
        return Path(os.environ['APPDATA']) / 'Waypoint Desktop'
    if sys.platform == 'darwin':
        return Path.home() / 'Library/Application Support/Waypoint Desktop'
    return Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'waypoint-desktop'

def clean_error(error):
    text = str(error)
    text = re.sub(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', '[account]', text, flags=re.I)
    return text[:2000]

def protection_file():
    if os.environ.get('WAYPOINT_PROTECTION_FILE'):
        return Path(os.environ['WAYPOINT_PROTECTION_FILE'])
    if sys.platform == 'win32':
        return Path(os.environ['APPDATA']) / 'Waypoint Desktop' / 'device-protection.json'
    return data_root() / 'device-protection.json'

class Backend:
    def __init__(self, root=None, emit=None):
        self.root = Path(root) if root else data_root()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.emit = emit or (lambda value: print(json.dumps(value, default=str), flush=True))
        self.db = sqlite3.connect(self.root / 'workspace.db')
        self.db.execute('CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY, data TEXT NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, data TEXT NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS library (id TEXT PRIMARY KEY, data TEXT NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS pairings (id TEXT PRIMARY KEY, data TEXT NOT NULL)')
        self.jobs = {}
        self.device_locks = {}
        self.native = None
        self.native_pending = {}
        self.native_prompts = {}
        self.account = None
        self.native_start_lock = asyncio.Lock()
        self.native_tasks = set()

    def is_protected(self, device_id):
        try:
            policy = json.loads(protection_file().read_text(encoding='utf-8'))
            identifiers = policy.get('protectedDeviceIds') if isinstance(policy,dict) else None
            if not isinstance(identifiers,list) or any(not isinstance(value,str) or not re.fullmatch(r'[A-Za-z0-9-]{1,128}',value) for value in identifiers):
                return True
            return isinstance(device_id,str) and device_id.casefold() in {value.casefold() for value in identifiers}
        except FileNotFoundError:
            return False
        except (ValueError, OSError):
            # A damaged protection policy must never silently enable device writes.
            return True

    def require_device_writes(self, device_id):
        if not isinstance(device_id, str) or not device_id or len(device_id)>128 or not re.fullmatch(r'[A-Za-z0-9-]+',device_id):
            raise ValueError('Select an explicit device before making changes.')
        if self.is_protected(device_id):
            raise PermissionError('This device is protected to preserve its active Waypoint location session. Installation, pairing changes, settings changes and app removal are blocked.')

    async def close(self):
        tasks = list(self.jobs.values())
        for task in tasks:
            if not task.cancelling():task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if self.native and self.native.returncode is None:
            self.native.stdin.close()
            try:
                await asyncio.wait_for(self.native.wait(), 3)
            except asyncio.TimeoutError:
                self.native.terminate()
                await self.native.wait()
        await asyncio.gather(*self.native_tasks, return_exceptions=True)
        self.db.close()

    def records(self, table):
        assert table in {'jobs', 'library', 'pairings'}
        return [json.loads(row[0]) for row in self.db.execute(f'SELECT data FROM {table} ORDER BY rowid DESC')]

    def save_record(self, table, data):
        assert table in {'jobs', 'library', 'pairings'}
        self.db.execute(f'INSERT OR REPLACE INTO {table} VALUES (?,?)', (data['id'], json.dumps(data)))
        self.db.commit()

    def recover_jobs(self):
        # Called only on service startup while holding WorkspaceLease. A crash
        # during upload has an unknown device outcome; never retry it silently.
        for job in self.records('jobs'):
            if job.get('status') not in {'queued','running'}:continue
            job.update(status='interrupted',progress=None,ended=now(),
                       stage='Interrupted when the device service stopped. Check the device before retrying.')
            job.setdefault('logs',[]).append({'time':now(),'message':job['stage']})
            self.save_record('jobs',job)

    def native_path(self):
        if os.environ.get('WAYPOINT_NATIVE_ENGINE'):
            return Path(os.environ['WAYPOINT_NATIVE_ENGINE'])
        base = Path(__file__).resolve().parent.parent
        name = 'waypoint-engine.exe' if os.name == 'nt' else 'waypoint-engine'
        candidates = [base/'runtime'/name, base/'native/target/release'/name, base/'native/target/debug'/name]
        return next((p for p in candidates if p.exists()), candidates[0])

    async def ensure_native(self):
        async with self.native_start_lock:
            await self.start_native()

    async def start_native(self):
        if self.native and self.native.returncode is None:
            return
        engine = self.native_path()
        if not engine.is_file():
            raise RuntimeError('The native signing engine is not built yet. Device discovery and IPA editing are available.')
        env = dict(os.environ, WAYPOINT_NATIVE_DATA=str(self.root / 'native'))
        self.native_prompts.clear()
        self.native = await asyncio.create_subprocess_exec(str(engine), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env)
        for coroutine in (self.read_native(), self.drain_native_errors()):
            task = asyncio.create_task(coroutine)
            self.native_tasks.add(task)
            task.add_done_callback(self.native_tasks.discard)

    async def read_native(self):
        while line := await self.native.stdout.readline():
            try:
                message = json.loads(line)
                if 'id' in message:
                    for prompt_id,prompt in list(self.native_prompts.items()):
                        if prompt.get('requestId')==message['id']:
                            self.native_prompts.pop(prompt_id,None)
                            self.emit({'event':'promptClosed','promptId':prompt_id})
                    future = self.native_pending.pop(message['id'],None)
                    if future and not future.done():
                        if 'error' in message:
                            future.set_exception(RuntimeError(message['error']['message']))
                        else:
                            future.set_result(message['result'])
                elif 'event' in message:
                    if message['event']=='prompt' and type(message.get('promptId')) is int:
                        self.native_prompts[message['promptId']]=message
                    self.emit(message)
            except (ValueError, KeyError):
                continue
        for future in self.native_pending.values():
            if not future.done():
                future.set_exception(RuntimeError('The native engine exited. Reopen the operation to try again.'))
        self.native_pending.clear()
        for prompt_id in self.native_prompts:
            self.emit({'event':'promptClosed','promptId':prompt_id})
        self.native_prompts.clear()
        self.account=None

    async def drain_native_errors(self):
        # Native diagnostics may contain account context. Do not forward raw stderr.
        while await self.native.stderr.readline():
            pass

    async def native_call(self, method, params):
        if method in {'pairing.createRemote', 'pairing.validate', 'ipa.sign'}:
            self.require_device_writes(params.get('deviceId'))
        await self.ensure_native()
        identifier = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        self.native_pending[identifier] = future
        self.native.stdin.write((json.dumps({'id': identifier, 'method': method, 'params': params})+'\n').encode())
        await self.native.stdin.drain()
        try:
            return await asyncio.wait_for(future, NATIVE_TIMEOUT_SECONDS)
        except asyncio.TimeoutError:
            # A signer that exceeded its deadline must stop before its caller
            # cleans up input files. Its in-memory Apple session is no longer live.
            async with self.native_start_lock:
                process=self.native
                if process and process.returncode is None:
                    process.terminate()
                    try:await asyncio.wait_for(process.wait(),3)
                    except asyncio.TimeoutError:
                        process.kill();await process.wait()
                await asyncio.gather(*list(self.native_tasks),return_exceptions=True)
                self.account=None
            raise RuntimeError('The native signing operation timed out. Sign in again before retrying.') from None
        finally:
            self.native_pending.pop(identifier, None)

    @contextlib.asynccontextmanager
    async def device(self, device_id, autopair=True):
        from pymobiledevice3.lockdown import create_using_usbmux
        async with await create_using_usbmux(serial=device_id, autopair=autopair and not self.is_protected(device_id)) as client:
            yield client

    async def list_devices(self):
        from pymobiledevice3.usbmux import list_devices
        result = []
        found = await list_devices()
        for device in found:
            serial = device.serial
            if any(d['id'] == serial for d in result):
                continue
            item = {'id': serial, 'name': 'Apple device', 'transport': device.connection_type, 'trusted': False, 'protected':self.is_protected(serial)}
            try:
                async with self.device(serial, autopair=False) as client:
                    values = client.all_values
                    item.update(name=values.get('DeviceName', 'Apple device'), model=values.get('ProductType',''), osVersion=values.get('ProductVersion',''), trusted=True)
                    item['developerMode'] = await client.get_value(domain='com.apple.security.mac.amfi', key='DeveloperModeStatus')
                    item['wirelessDebugging'] = await client.get_value(domain='com.apple.mobile.wireless_lockdown', key='EnableWifiDebugging')
            except Exception as error:
                item['issue'] = clean_error(error)
            result.append(item)
        return result

    async def list_apps(self, device_id):
        from pymobiledevice3.services.installation_proxy import InstallationProxyService
        async with self.device(device_id) as device:
            async with InstallationProxyService(device) as service:
                apps = await service.get_apps(application_type='User')
        managed = {}
        for item in self.records('library'):
            if str(item.get('deviceId','')).casefold()==device_id.casefold():
                managed.setdefault(item.get('bundleId'),item)
        result = []
        for bundle, info in apps.items():
            result.append({'bundleId':bundle,'name':info.get('CFBundleDisplayName',info.get('CFBundleName',bundle)), 'version':info.get('CFBundleShortVersionString',''), 'fileSharing': bool(info.get('UIFileSharingEnabled')), 'managed': bundle in managed, 'expires':managed.get(bundle,{}).get('expires'), 'managedId':managed.get(bundle,{}).get('id'), 'refreshable':bool(managed.get(bundle,{}).get('refreshable')), 'sourceAvailable':bool(managed.get(bundle,{}).get('sourcePath') and Path(managed[bundle]['sourcePath']).is_file()), 'deviceId':device_id})
        return sorted(result, key=lambda x: x['name'].lower())

    def settings(self):
        row=self.db.execute('SELECT data FROM settings WHERE id=1').fetchone()
        return {'theme':'light','hideSensitive':True,'autoRefresh':False,'refreshHours':24, 'anisetteUrl':'https://ani.sidestore.io' if sys.platform=='win32' else '','startAtLogin':False, **(json.loads(row[0]) if row else {})}

    async def dispatch(self, method, p):
        if not isinstance(p, dict):
            raise ValueError('Request parameters must be an object.')
        if method in {'install.start','setup.start','app.uninstall','pairing.createRemote','pairing.createLockdown','pairing.install','pairing.validate','device.enableWireless','ipa.sign'}:
            self.require_device_writes(p.get('deviceId'))
        if method == 'system.status':
            return {'version':'0.1.0','platform':sys.platform,'architecture':platform.machine(),'nativeReady':self.native_path().is_file(),'nativePath':str(self.native_path()),'account':self.account,'dataDirectory':str(self.root),'settings':self.settings()}
        if method == 'settings.get': return self.settings()
        if method == 'settings.save':
            allowed={'theme','hideSensitive','autoRefresh','refreshHours','anisetteUrl','startAtLogin'}
            updated={**self.settings(),**{k:v for k,v in p.items() if k in allowed}}
            if updated['theme'] not in {'light','dark','system'}: raise ValueError('Invalid theme')
            self.db.execute('INSERT OR REPLACE INTO settings VALUES (1,?)',(json.dumps(updated),));self.db.commit()
            return updated
        if method == 'devices.list':
            try:
                return await asyncio.wait_for(self.list_devices(),10)
            except asyncio.TimeoutError:
                raise RuntimeError('Apple device discovery timed out. Check the Apple device service and USB connection.') from None
        if method == 'apps.list': return await self.list_apps(p['deviceId'])
        if method == 'library.list': return self.records('library')
        if method == 'jobs.list': return self.records('jobs')
        if method == 'jobs.cancel':
            task=self.jobs.get(p['jobId'])
            if task and not task.cancelling():task.cancel()
            return {'ok':True}
        if method == 'pairings.list': return self.records('pairings')
        if method == 'pairing.inspect':
            from backend.pairings import read_record
            _, info = await asyncio.to_thread(read_record, p['path'])
            return info
        if method == 'pairing.import':
            from backend.pairings import device_id, read_record, save_private
            raw, info = await asyncio.to_thread(read_record, p['path'])
            selected = p.get('deviceId') or info['embeddedDeviceId']
            if selected:
                device_id(selected)
            if info['embeddedDeviceId'] and selected and info['embeddedDeviceId'].casefold()!=selected.casefold():
                raise ValueError('This Lockdown record belongs to a different device.')
            existing = next((r for r in self.records('pairings') if r.get('fingerprint')==info['fingerprint'] and r.get('deviceId')==selected), None)
            if existing:
                return {**existing, 'alreadyImported':True}
            identifier = str(uuid.uuid4())
            path = await asyncio.to_thread(save_private,self.root/'pairings',identifier+'.plist',raw)
            item = {**info,'id':identifier,'deviceId':selected,'path':str(path),'created':now(),
                    'source':'imported','bindingVerified':False}
            self.save_record('pairings',item)
            return item
        if method == 'pairing.destinations':
            from backend.pairings import destinations
            return destinations(p['kind'], await self.list_apps(p['deviceId']))
        if method == 'pairing.validate':
            item = next(r for r in self.records('pairings') if r['id']==p['pairingId'])
            if item.get('deviceId') and item['deviceId'].casefold()!=p['deviceId'].casefold():
                raise ValueError('This record is associated with a different device.')
            # A local format check never substitutes for successful authentication.
            from backend.pairings import read_record
            await asyncio.to_thread(read_record,item['path'])
            await self.native_call('pairing.validate',{'path':item['path'],'kind':item['kind'],'deviceId':p['deviceId']})
            item.update(deviceId=p['deviceId'],bindingVerified=True,lastValidated=now())
            self.save_record('pairings',item)
            return item
        if method == 'setup.check':
            from backend.setup import check
            return await check(self, p['deviceId'])
        if method == 'setup.start':
            from backend.setup import run
            job={'id':str(uuid.uuid4()),'name':'Set up Waypoint','status':'queued','stage':'Waiting','progress':0,'started':now(),'deviceId':p['deviceId'],'logs':[]}
            self.save_record('jobs',job)
            self.jobs[job['id']]=asyncio.create_task(run(self,job,dict(p)))
            return job
        if method == 'ipa.inspect':
            from backend.library import installation_metadata
            package=await asyncio.to_thread(inspect_ipa,p['path'])
            metadata=await asyncio.to_thread(installation_metadata,p['path'])
            return {**package,**{key:metadata[key] for key in ('expires','profileStatus','profileSignatureVerified')}}
        if method == 'ipa.prepare':
            return await asyncio.to_thread(prepare_ipa,p['path'],p['destination'],p.get('options',{}))
        if method == 'ipa.exportSigned':
            import plistlib
            import tempfile
            if Path(p['path']).resolve()==Path(p['destination']).resolve():
                raise ValueError('Export to a different file to preserve the source IPA.')
            entitlements=p.get('entitlements')
            if entitlements is not None and not isinstance(entitlements,dict):
                raise ValueError('Custom entitlements must be a JSON object.')
            xml=plistlib.dumps(entitlements).decode() if entitlements is not None else None
            directory=self.root/'export-jobs';directory.mkdir(exist_ok=True)
            with tempfile.TemporaryDirectory(dir=directory) as work:
                prepared=await asyncio.to_thread(prepare_ipa,p['path'],str(Path(work)/(str(uuid.uuid4())+'.ipa')),p.get('options',{}))
                signed=await self.native_call('ipa.adhoc',{'path':prepared['path'],'entitlementsXml':xml})
                base=(self.root/'native/exports').resolve()
                workspace=Path(signed['workspace']).resolve()
                app=Path(signed['signedPath']).resolve()
                if workspace.parent!=base or not re.fullmatch(r'adhoc-[A-Za-z0-9]+',workspace.name) or not app.is_relative_to(workspace):
                    raise RuntimeError('The signing engine returned an unexpected workspace.')
                try:
                    result=await asyncio.to_thread(pack_signed_bundle,app,prepared['path'],p['destination'])
                    result['verifiedBinaries']=signed['verifiedBinaries']
                    return result
                finally:
                    # Resolved and bounded above before recursive removal.
                    await asyncio.to_thread(shutil.rmtree,workspace)
        if method == 'pairing.export':
            item=next(item for item in self.records('pairings') if item['id']==p['pairingId'])
            shutil.copy2(item['path'],p['destination']);return {'path':p['destination']}
        if method == 'pairing.createLockdown':
            import plistlib
            async with self.device(p['deviceId']) as device:
                record={**device.pair_record,'UDID':p['deviceId']}
            directory=self.root/'pairings';directory.mkdir(exist_ok=True,mode=0o700)
            path=directory/(str(uuid.uuid4())+'.mobiledevicepairing')
            path.write_bytes(plistlib.dumps(record))
            if os.name!='nt':path.chmod(0o600)
            item={'id':str(uuid.uuid4()),'deviceId':p['deviceId'],'kind':'lockdown','path':str(path),'created':now(),'source':'created','bindingVerified':True}
            self.save_record('pairings',item);return item
        if method == 'pairing.createRemote':
            record=await self.native_call(method,p)
            item={**record,'id':str(uuid.uuid4()),'created':now(),'source':'created','bindingVerified':True}
            self.save_record('pairings',item);return item
        if method == 'pairing.install':
            from pymobiledevice3.services.house_arrest import HouseArrestService
            from backend.pairings import destination_path
            record=next(item for item in self.records('pairings') if item['id']==p['pairingId'])
            filename=p.get('filename','pairingFile.plist')
            remote_path=destination_path(filename)
            if record.get('source')=='imported' and not record.get('bindingVerified'):
                raise ValueError('Validate this imported record against the selected device before transferring it.')
            if record['deviceId'] != p['deviceId']:
                raise ValueError('This pairing record belongs to a different device.')
            async with self.device(p['deviceId']) as device:
                async with await HouseArrestService.create(device,p['bundleId'],documents_only=True) as service:
                    parent=str(Path(remote_path).parent).replace('\\','/')
                    if parent!='/Documents' and not await service.isdir(parent):
                        await service.makedirs(parent)
                    await service.set_file_contents(remote_path,Path(record['path']).read_bytes())
            return {'ok':True}
        if method == 'device.enableWireless':
            async with self.device(p['deviceId']) as device:
                await device.set_value(value=bool(p['enabled']),domain='com.apple.mobile.wireless_lockdown',key='EnableWifiDebugging')
            return {'ok':True}
        if method == 'account.login':
            self.account=await self.native_call(method,p)
            return self.account
        if method == 'prompt.reply':
            from backend.prompts import verification_answer
            identifier=p.get('promptId')
            prompt=self.native_prompts.get(identifier) if type(identifier) is int else None
            if not prompt or not self.native or self.native.returncode is not None:
                raise ValueError('This verification prompt has ended. Start sign-in again.')
            answer=verification_answer(prompt,p.get('answer'))
            self.native_prompts.pop(identifier,None)
            self.native.stdin.write((json.dumps({'method':method,'params':{'promptId':identifier,'answer':answer}})+'\n').encode());await self.native.stdin.drain()
            return {'ok':True}
        if method in {'account.logout','account.certificates','account.appIds','identity.import','profile.import','ipa.sign'}:
            result=await self.native_call(method,p)
            if method=='account.logout':self.account=None
            return result
        if method=='app.refresh':
            item=next((entry for entry in self.records('library') if entry['id']==p.get('libraryId')),None)
            if item is None:raise ValueError('This app is not in the managed library.')
            self.require_device_writes(item['deviceId'])
            if not item.get('refreshable') or item.get('signingMode')!='appleId':
                raise ValueError('This installation requires a new IPA or provisioning profile through Sideload.')
            if not item.get('sourcePath') or not Path(item['sourcePath']).is_file():
                raise ValueError('The saved refresh source is missing. Select the IPA again through Sideload.')
            if not self.account:raise ValueError('Sign in to Apple before refreshing this app.')
            if item.get('accountEmail') and str(self.account.get('email','')).casefold()!=item['accountEmail'].casefold():
                raise ValueError('Sign in with the Apple account used for this installation.')
            return await self.dispatch('install.start',{
                'deviceId':item['deviceId'],'path':item['sourcePath'],'mode':'appleId',
                'name':'Refresh '+item.get('name','app'),'expectedSourceSha256':item['sourceSha256'],
                'originalPath':item.get('originalPath')})
        if method=='install.start':
            if p.get('mode','appleId') not in {'appleId','certificate','existing'}:
                raise ValueError('Choose Apple account, certificate or an existing signature for installation.')
            if p.get('mode') == 'existing' and p.get('options'):
                raise ValueError('Customizing an IPA invalidates its signature. Choose Apple account or Certificate signing before installing.')
            job={'id':str(uuid.uuid4()),'name':p.get('name','Install app'),'status':'queued','stage':'Waiting','progress':None,'started':now(),'deviceId':p.get('deviceId'),'logs':[]}
            self.save_record('jobs',job)
            self.jobs[job['id']]=asyncio.create_task(self.install(job,p))
            return job
        if method=='app.uninstall':
            if p.get('confirmation')!=p.get('bundleId'): raise ValueError('Confirm the exact app before uninstalling.')
            from pymobiledevice3.services.installation_proxy import InstallationProxyService
            async with self.device(p['deviceId']) as device:
                async with InstallationProxyService(device) as service: await service.uninstall(p['bundleId'])
            return {'ok':True}
        raise ValueError('This operation is not implemented: '+method)

    def update_job(self,job,stage,status='running',progress=None):
        job.update(stage=stage,status=status,progress=progress)
        job['logs'].append({'time':now(),'message':stage})
        self.save_record('jobs',job);self.emit({'event':'job','job':job})

    async def install(self,job,p):
        from backend.installations import run
        await run(self,job,p)

    async def serve(self):
        async def respond(request):
            try:
                result=await self.dispatch(request['method'],request.get('params',{}))
                self.emit({'id':request.get('id'),'result':result})
            except Exception as error:
                self.emit({'id':request.get('id'),'error':{'message':clean_error(error),'type':type(error).__name__}})
        tasks=set()
        while line:=await asyncio.to_thread(sys.stdin.readline):
            try:request=json.loads(line)
            except ValueError:continue
            task=asyncio.create_task(respond(request));tasks.add(task);task.add_done_callback(tasks.discard)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await self.close()

def main():
    import logging
    from backend.workspace import WorkspaceLease
    logging.basicConfig(level=logging.ERROR,stream=sys.stderr)
    with WorkspaceLease(data_root()):
        service=Backend()
        service.recover_jobs()
        asyncio.run(service.serve())


if __name__=='__main__':
    main()
