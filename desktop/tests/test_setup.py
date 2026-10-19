import asyncio
import contextlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from backend.server import Backend
from backend.setup import run


class SetupTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.backend=Backend(self.root/'data',lambda _:None)
        self.env=patch.dict('os.environ',{'WAYPOINT_PROTECTION_FILE':str(self.root/'no-policy.json')})
        self.env.start()
        self.sequence=[]
        self.params={'deviceId':'test-phone','email':'example@example.invalid','password':'secret-not-for-logs','path':str(self.root/'app.ipa')}
        with zipfile.ZipFile(self.params['path'],'w') as archive:
            archive.writestr('Payload/Waypoint.app/Info.plist',plistlib.dumps({'CFBundleIdentifier':'com.locus.personal','CFBundleDisplayName':'Waypoint','CFBundleShortVersionString':'1.5.2','WaypointDesktopSetupVersion':1}))
        app=self.root/'signed.app';app.mkdir()
        (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.locus.personal.TESTTEAM'}))
        self.job={'id':'setup-test','logs':[],'status':'queued'}
        self.state={'trusted':True,'developerMode':True,'waypointInstalled':False,'localDevVPNInstalled':True,'device':{'name':'Test phone'}}

        async def native(method,params):
            self.sequence.append(method)
            if method=='account.login':return {'email':'example@example.invalid'}
            if method=='ipa.sign':return {'signedPath':str(app)}
            raise AssertionError(method)
        self.backend.native_call=native
        original_dispatch=self.backend.dispatch
        async def dispatch(method,params):
            if method=='pairing.createRemote':
                self.sequence.append('pair');return {'id':'pair-test'}
            if method=='pairing.install':
                self.sequence.append('transfer')
                self.assertEqual(params['bundleId'],'com.locus.personal.TESTTEAM')
                self.assertEqual(params['filename'],'waypoint-setup-pairing.plist')
                return {'ok':True}
            return await original_dispatch(method,params)
        self.backend.dispatch=dispatch
        @contextlib.asynccontextmanager
        async def device(*args,**kwargs):yield object()
        self.backend.device=device

    async def asyncTearDown(self):
        await self.backend.close();self.env.stop();self.temp.cleanup()

    def installer(self,fail=False):
        sequence=self.sequence
        class FakeInstaller:
            def __init__(self,*args):pass
            async def __aenter__(self):return self
            async def __aexit__(self,*args):pass
            async def install_from_local(self,path,handler):
                sequence.append('install')
                if fail:raise RuntimeError('Simulated installation failure')
                handler(100)
            async def get_apps(self,**kwargs):
                sequence.append('verify')
                return {'com.locus.personal.TESTTEAM':{}}
        return FakeInstaller

    async def test_full_flow_uses_signed_identity_and_never_persists_password(self):
        with patch('backend.setup.check',return_value=self.state),patch('pymobiledevice3.services.installation_proxy.InstallationProxyService',self.installer()):
            await run(self.backend,self.job,self.params)
        self.assertEqual(self.sequence,['account.login','ipa.sign','install','verify','pair','transfer'])
        self.assertEqual(self.job['status'],'succeeded')
        self.assertTrue(self.job['result']['pairingTransferred'])
        self.assertNotIn('password',self.params)
        self.assertNotIn(b'secret-not-for-logs',(self.root/'data/workspace.db').read_bytes())

    async def test_install_failure_never_changes_pairing(self):
        with patch('backend.setup.check',return_value=self.state),patch('pymobiledevice3.services.installation_proxy.InstallationProxyService',self.installer(fail=True)):
            await run(self.backend,self.job,self.params)
        self.assertEqual(self.job['status'],'failed')
        self.assertNotIn('pair',self.sequence)
        self.assertNotIn('transfer',self.sequence)

    async def test_existing_waypoint_stops_before_login_or_install(self):
        self.state['waypointInstalled']=True
        with patch('backend.setup.check',return_value=self.state):await run(self.backend,self.job,self.params)
        self.assertEqual(self.sequence,[])
        self.assertEqual(self.job['status'],'failed')

    async def test_developer_mode_never_restarts_or_changes_device(self):
        self.state['developerMode']=False
        with patch('backend.setup.check',return_value=self.state):await run(self.backend,self.job,self.params)
        self.assertEqual(self.sequence,[])
        self.assertIn('will not restart',self.job['stage'])

