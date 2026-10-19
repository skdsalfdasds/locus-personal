"""Verify bundled executables on their actual OS. Never opens a device service."""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import tempfile


async def main():
    root = Path(__file__).resolve().parent.parent
    suffix = '.exe' if os.name == 'nt' else ''
    engine = root/'runtime'/('waypoint-engine'+suffix)
    backend = root/'runtime/waypoint-backend'/('waypoint-backend'+suffix)
    ipa = root/'runtime/apps/Waypoint.ipa'
    with tempfile.TemporaryDirectory() as state:
        env = dict(os.environ, WAYPOINT_DATA_DIR=state, WAYPOINT_NATIVE_DATA=state,
                   WAYPOINT_NATIVE_ENGINE=str(engine), WAYPOINT_BUNDLED_IPA=str(ipa))
        ping = subprocess.run([str(engine)], input='{"id":"ping","method":"ping","params":{}}\n',
                              capture_output=True, text=True, env=env, timeout=30, check=True)
        reply = next(json.loads(line) for line in ping.stdout.splitlines() if line.startswith('{'))
        assert reply['result']['engine'] == 'waypoint-native'
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
        finally:
            service.stdin.close()
            await asyncio.wait_for(service.wait(),10)
            assert service.returncode == 0
    print('Native helper, frozen backend, and bundled IPA verified on this platform.')


asyncio.run(main())
