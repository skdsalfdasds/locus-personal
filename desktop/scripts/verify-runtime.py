"""Verify bundled executables on their actual OS. Never opens a device service."""
import asyncio
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


async def main():
    root = Path(__file__).resolve().parent.parent
    suffix = '.exe' if os.name == 'nt' else ''
    engine = root/'runtime'/('waypoint-engine'+suffix)
    backend = root/'runtime/waypoint-backend'/('waypoint-backend'+suffix)
    ipa = root/'runtime/apps/Waypoint.ipa'
    with tempfile.TemporaryDirectory() as state:
        policy=Path(state)/'protection.json'
        policy.write_text(json.dumps({'protectedDeviceIds':['synthetic-protected-phone']}),encoding='utf-8')
        env = dict(os.environ, WAYPOINT_DATA_DIR=state, WAYPOINT_NATIVE_DATA=state,
                   WAYPOINT_NATIVE_ENGINE=str(engine), WAYPOINT_BUNDLED_IPA=str(ipa),
                   WAYPOINT_PROTECTION_FILE=str(policy))
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
            return json.loads(await asyncio.wait_for(service.stdout.readline(),30))
        try:
            status = await call('system.status')
            assert status['result']['nativeReady']
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
        finally:
            service.stdin.close()
            await asyncio.wait_for(service.wait(),10)
            assert service.returncode == 0
    print('Native helper, frozen backend, bundled IPA, pairing import and protected-device guard verified on this platform.')


asyncio.run(main())
