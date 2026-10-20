import asyncio
import base64
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import AsyncMock,patch

from backend.accounts import preferences
from backend.server import Backend
from backend.sessions import SessionStore,SessionUnavailable,secure_backend,validate_session


def secret(email='synthetic@example.invalid',team='TEAMONE'):
    return {'version':1,'email':email,'token':'fixture-developer-token','adsid':'123456',
            'duration':3600,'expiry':1,'endpoint':'https://example.invalid','teamId':team}


def info(team='TEAMONE'):
    return {'email':'synthetic@example.invalid','team':{'id':team,'name':team,'kind':'Individual'},
            'teams':[{'id':item,'name':item,'kind':'Individual'} for item in ('TEAMONE','TEAMTWO')]}


class FakeVault:
    priority=5
    def __init__(self):self.values={};self.fail=False
    def get_password(self,service,account):
        if self.fail:raise RuntimeError('Vault locked')
        return self.values.get((service,account))
    def set_password(self,service,account,value):
        if self.fail:raise RuntimeError('Vault locked')
        self.values[(service,account)]=value
    def delete_password(self,service,account):
        if self.fail:raise RuntimeError('Vault locked')
        self.values.pop((service,account),None)


class EncryptedStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.vault=FakeVault();self.store=SessionStore(self.root,self.vault)
    def tearDown(self):self.temp.cleanup()

    def test_restart_round_trip_has_no_plaintext_token_on_disk_or_in_vault(self):
        value=secret();self.store.save(value)
        reopened=SessionStore(self.root,self.vault)
        self.assertEqual(reopened.load(),value)
        self.assertNotIn(value['token'].encode(),self.store.path.read_bytes())
        self.assertNotIn(value['email'].encode(),self.store.path.read_bytes())
        self.assertEqual(len(next(iter(self.vault.values.values()))),44)
        self.assertTrue(all(value['token'] not in stored for stored in self.vault.values.values()))
        if __import__('os').name!='nt':self.assertEqual(self.store.path.stat().st_mode&0o777,0o600)

    def test_large_token_uses_a_small_fixed_size_vault_key(self):
        value=secret();value['token']='x'*16000;self.store.save(value)
        self.assertEqual(self.store.load(),value)
        self.assertEqual(len(next(iter(self.vault.values.values()))),44)

    def test_tampered_ciphertext_and_missing_key_cannot_restore(self):
        self.store.save(secret());data=self.store.path.read_bytes()
        self.store.path.write_bytes(data[:-1]+bytes([data[-1]^1]))
        with self.assertRaises(SessionUnavailable):self.store.load()
        self.store.path.write_bytes(data);self.vault.values.clear()
        with self.assertRaises(SessionUnavailable):self.store.load()
        self.assertEqual(self.vault.values,{})

    def test_cache_copied_to_another_workspace_fails_even_with_the_same_key(self):
        self.store.save(secret())
        other=SessionStore(self.root/'other',self.vault);other.root.mkdir()
        shutil.copyfile(self.store.path,other.path)
        key=self.vault.values[(self.store.service,self.store.account)]
        self.vault.values[(other.service,other.account)]=key
        with self.assertRaises(SessionUnavailable):other.load()

    def test_failed_commit_preserves_previous_ciphertext_and_cleans_temporary_files(self):
        self.store.save(secret());before=self.store.path.read_bytes()
        with patch('backend.sessions.os.replace',side_effect=OSError('Synthetic write failure')):
            with self.assertRaises(SessionUnavailable):self.store.save(secret(team='TEAMTWO'))
        self.assertEqual(self.store.path.read_bytes(),before)
        self.assertEqual(list(self.root.glob('.session-*')),[])

    def test_locked_vault_never_creates_a_plaintext_fallback(self):
        self.vault.fail=True
        with self.assertRaises(SessionUnavailable):self.store.save(secret())
        self.assertFalse(self.store.path.exists());self.assertEqual(list(self.root.iterdir()),[])

    def test_forget_disables_restore_even_when_key_deletion_fails(self):
        self.store.save(secret());self.vault.fail=True
        with self.assertRaises(SessionUnavailable):self.store.forget()
        self.assertFalse(self.store.exists());self.assertIsNone(self.store.load())

    def test_passwords_and_unexpected_schema_fields_are_rejected_before_storage(self):
        for update in ({'password':'fixture-password'},{'version':True},{'adsid':'not-numeric'},
                       {'duration':-1},{'teamId':'bad/team'},{'expiry':True}):
            with self.assertRaises(SessionUnavailable):self.store.save({**secret(),**update})
        self.assertEqual(self.vault.values,{})

    def test_insecure_keyring_is_rejected_and_a_system_backend_in_a_chain_is_selected(self):
        with patch('keyring.get_keyring',return_value=FakeVault()):
            with self.assertRaises(SessionUnavailable):secure_backend()
        system=type('SystemVault',(FakeVault,),{'__module__':'keyring.backends.Windows'})()
        chain=type('Chainer',(),{'__module__':'keyring.backends.chainer','backends':[FakeVault(),system]})()
        with patch('keyring.get_keyring',return_value=chain):self.assertIs(secure_backend(),system)


class AccountSessionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.store=SessionStore(self.root,FakeVault());self.events=[]
        self.backend=Backend(self.root,self.events.append,session_store=self.store)
        self.calls=[];self.team='TEAMONE'
        async def native(method,params):
            self.calls.append((method,params))
            if method in ('account.login','account.restoreSession'):
                return {**info(self.team),'token':'must-not-reach-ui','password':'must-not-reach-ui'}
            if method=='account.exportSession':return secret(team=self.team)
            if method=='account.selectTeam':self.team=params['teamId'];return info(self.team)
            if method=='ipa.sign':return {'signedPath':'/synthetic.app'}
            raise AssertionError(method)
        self.backend.native_call=native
    async def asyncTearDown(self):await self.backend.close();self.temp.cleanup()

    async def test_login_remembers_without_exposing_export_or_password(self):
        result=await self.backend.dispatch('account.login',{'email':'synthetic@example.invalid','password':'fixture-password','rememberSession':True})
        status=await self.backend.dispatch('system.status',{})
        self.assertEqual(result,info())
        self.assertNotIn('fixture-developer-token',json.dumps(status))
        self.assertNotIn('must-not-reach-ui',json.dumps(status))
        self.assertNotIn('fixture-password',json.dumps(self.backend.settings()))
        self.assertTrue(status['session']['saved']);self.assertTrue(self.backend.settings()['sessionSaved'])
        self.assertEqual(self.store.load(),secret())
        self.assertEqual([call[0] for call in self.calls],['account.login','account.exportSession'])

    async def test_new_backend_restores_same_account_and_team_without_a_password(self):
        self.store.save(secret());preferences(self.backend,True,True)
        other=Backend(self.root,self.events.append,session_store=SessionStore(self.root,self.store.backend))
        other.native_call=AsyncMock(return_value=info())
        try:
            result=await other.dispatch('account.restore',{})
            self.assertEqual(result,info());self.assertTrue(other.session_state['restored'])
            args=other.native_call.call_args.args
            self.assertEqual(args[0],'account.restoreSession');self.assertEqual(args[1]['session'],secret())
            self.assertNotIn('password',args[1]['session'])
        finally:await other.close()

    async def test_network_restore_failure_keeps_encrypted_cache_and_has_no_device_calls(self):
        self.store.save(secret());preferences(self.backend,True,True)
        self.backend.native_call=AsyncMock(side_effect=RuntimeError('private fixture-developer-token'))
        self.backend.device=AsyncMock(side_effect=AssertionError('No phone operation during restore'))
        self.assertIsNone(await self.backend.dispatch('account.restore',{}))
        self.assertEqual(self.store.load(),secret());self.backend.device.assert_not_called()
        self.assertNotIn('fixture-developer-token',json.dumps(self.backend.session_state))

    async def test_failed_save_for_new_account_cannot_restore_previous_account(self):
        self.store.save(secret(email='old@example.invalid'));preferences(self.backend,True,True)
        with patch.object(self.store,'save',side_effect=RuntimeError('Locked')):
            await self.backend.dispatch('account.login',{'email':'synthetic@example.invalid','password':'fixture','rememberSession':True})
        self.assertFalse(self.backend.settings()['sessionSaved'])
        self.backend.account=None;self.calls.clear()
        self.assertIsNone(await self.backend.dispatch('account.restore',{}));self.assertEqual(self.calls,[])

    async def test_opt_out_and_logout_remove_saved_session_without_starting_a_native_engine(self):
        self.store.save(secret());preferences(self.backend,True,True)
        await self.backend.dispatch('account.login',{'email':'synthetic@example.invalid','password':'fixture','rememberSession':False})
        self.assertFalse(self.store.exists());self.assertFalse(self.backend.settings()['sessionSaved'])
        self.calls.clear()
        await self.backend.dispatch('account.logout',{})
        self.assertEqual(self.calls,[]);self.assertIsNone(self.backend.account)

    async def test_logout_cleanup_failure_still_disables_automatic_sign_in(self):
        self.store.save(secret());preferences(self.backend,True,True);self.backend.account=info()
        self.store.backend.fail=True
        reply=await self.backend.dispatch('account.logout',{})
        self.assertIn('warning',reply);self.assertIsNone(self.backend.account)
        self.assertFalse(self.backend.settings()['rememberSession']);self.assertFalse(self.store.exists())

    async def test_signing_blocks_team_change_and_returns_actual_signing_identity(self):
        self.backend.account=info();preferences(self.backend,False,False)
        started=asyncio.Event();release=asyncio.Event()
        original=self.backend.native_call
        async def native(method,params):
            if method=='ipa.sign':started.set();await release.wait()
            return await original(method,params)
        self.backend.native_call=native
        signed=asyncio.create_task(self.backend.sign_ipa({'deviceId':'synthetic-phone','mode':'appleId'}))
        await started.wait()
        selection=asyncio.create_task(self.backend.dispatch('account.selectTeam',{'teamId':'TEAMTWO'}))
        await asyncio.sleep(0)
        self.assertFalse(selection.done());self.assertEqual(self.team,'TEAMONE')
        release.set();result=await signed;await selection
        self.assertEqual(result['signingAccount'],{'email':'synthetic@example.invalid','teamId':'TEAMONE'})
        self.assertEqual(self.backend.account['team']['id'],'TEAMTWO')

    async def test_signing_rejects_mismatched_refresh_team_before_native_calls(self):
        self.backend.account=info('TEAMTWO')
        with self.assertRaisesRegex(ValueError,'developer team'):
            await self.backend.sign_ipa({'deviceId':'synthetic-phone','mode':'appleId','expectedTeamId':'TEAMONE'})
        self.assertEqual(self.calls,[])
