"""Verify bundled executables on their actual OS. Never opens a device service."""
import asyncio
from contextlib import closing
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sqlite3
import tempfile
import hashlib


async def main():
    root = Path(__file__).resolve().parent.parent
    suffix = '.exe' if os.name == 'nt' else ''
    engine = root/'runtime'/('waypoint-engine'+suffix)
    backend = root/'runtime/waypoint-backend'/('waypoint-backend'+suffix)
    ipa = root/'runtime/apps/Waypoint.ipa'
    if os.name=='nt':
        libraries=list((root/'runtime').glob('vcruntime140*.dll'))
        assert libraries,'Native helper VC runtime is missing'
        for library in libraries:
            bundled=backend.parent/'_internal'/library.name
            assert hashlib.sha256(library.read_bytes()).digest()==hashlib.sha256(bundled.read_bytes()).digest()
    with tempfile.TemporaryDirectory() as state:
        policy=Path(state)/'protection.json'
        policy.write_text(json.dumps({'protectedDeviceIds':['synthetic-protected-phone']}),encoding='utf-8')
        env = dict(os.environ, WAYPOINT_DATA_DIR=state, WAYPOINT_NATIVE_DATA=state,
                   WAYPOINT_NATIVE_ENGINE=str(engine), WAYPOINT_BUNDLED_IPA=str(ipa),
                   WAYPOINT_PROTECTION_FILE=str(policy))
        with closing(sqlite3.connect(Path(state)/'workspace.db')) as previous:
            previous.execute('CREATE TABLE jobs (id TEXT PRIMARY KEY, data TEXT NOT NULL)')
            previous.execute('INSERT INTO jobs VALUES (?,?)',('synthetic-interrupted',json.dumps({
                'id':'synthetic-interrupted','status':'running','logs':[],
                'progress':40,'result':{'installed':True}})))
            previous.commit()
        ping = subprocess.run([str(engine)], input='{"id":"ping","method":"ping","params":{}}\n{"id":"validation-api","method":"pairing.validate","params":{}}\n',
                              capture_output=True, text=True, env=env, timeout=30, check=True)
        replies = {message['id']:message for line in ping.stdout.splitlines() if line.startswith('{')
                   for message in [json.loads(line)]}
        assert replies['ping']['result']['engine'] == 'waypoint-native'
        assert replies['validation-api']['error']['message'] == 'Missing deviceId'
        service = await asyncio.create_subprocess_exec(str(backend),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, env=env)
        async def call(method, params=None):
            service.stdin.write((json.dumps({'id':method,'method':method,'params':params or {}})+'\n').encode())
            await service.stdin.drain()
            while True:
                message=json.loads(await asyncio.wait_for(service.stdout.readline(),60))
                if message.get('id')==method:return message
        try:
            status = await call('system.status')
            assert status['result']['nativeReady']
            recovered=await call('jobs.list')
            assert recovered['result'][0]['status']=='interrupted'
            assert recovered['result'][0]['result']['installed'] is True
            duplicate=await asyncio.create_subprocess_exec(str(backend),stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,env=env)
            try:
                _,failure=await asyncio.wait_for(duplicate.communicate(),15)
            except asyncio.TimeoutError:
                duplicate.kill();await duplicate.wait()
                raise AssertionError('A second frozen service did not reject the busy workspace') from None
            assert duplicate.returncode!=0
            assert b'already using this workspace' in failure
            package = await call('ipa.inspect', {'path':str(ipa)})
            assert package['result']['desktopSetupVersion'] == 1
            assert package['result']['bundleId'] == 'com.locus.personal'
            from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
            key=Ed25519PrivateKey.generate()
            fixture=Path(state)/'synthetic-record.plist'
            fixture.write_bytes(plistlib.dumps({'private_key':key.private_bytes_raw(),
                'public_key':key.public_key().public_bytes_raw(),'identifier':'runtime-test'}))
            imported=await call('pairing.import',{'path':str(fixture)})
            assert imported['result']['source']=='imported'
            blocked=await call('pairing.validate',{'pairingId':imported['result']['id'],
                                                'deviceId':'synthetic-protected-phone'})
            assert blocked['error']['type']=='PermissionError'
            source_hash=hashlib.sha256(ipa.read_bytes()).digest()
            exported_path=Path(state)/'adhoc-export.ipa'
            exported=await call('ipa.exportSigned',{'path':str(ipa),'destination':str(exported_path),
                'entitlements':{'get-task-allow':True}})
            assert exported['result']['signatureMode']=='adhoc'
            assert exported['result']['verifiedBinaries']>0
            assert not exported['result']['appleProvisioned']
            assert hashlib.sha256(ipa.read_bytes()).digest()==source_hash
            subprocess.run([os.sys.executable,str(root/'scripts/verify-adhoc.py'),str(exported_path),
                            '--expect-task-allow'],check=True,timeout=30)
        finally:
            service.stdin.close()
            await asyncio.wait_for(service.wait(),10)
            assert service.returncode == 0
    print('Native helper, frozen backend, workspace ownership/recovery, offline ad-hoc export, pairing import and protected-device guard verified on this platform.')


asyncio.run(main())
