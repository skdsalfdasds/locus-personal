import asyncio
import contextlib
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zipfile

from asn1crypto import cms
from backend.installations import cleanup_extraction, extraction_cache
from backend.library import installation_metadata, profile_expiration
from backend.server import Backend


def profile(expires):
    # Metadata-only CMS fixture, deliberately not an Apple trust/signature test.
    payload=plistlib.dumps({'ExpirationDate':expires.replace(tzinfo=None)})
    return cms.ContentInfo({'content_type':'signed_data','content':{
        'version':'v1','digest_algorithms':[],
        'encap_content_info':{'content_type':'data','content':payload},'signer_infos':[]}}).dump()


def ipa(path,expires):
    with zipfile.ZipFile(path,'w') as archive:
        archive.writestr('Payload/Demo.app/Info.plist',plistlib.dumps({
            'CFBundleIdentifier':'org.example.demo','CFBundleExecutable':'Demo',
            'CFBundleDisplayName':'Demo','CFBundleShortVersionString':'1.0'}))
        archive.writestr('Payload/Demo.app/Demo',b'synthetic-binary')
        archive.writestr('Payload/Demo.app/embedded.mobileprovision',profile(expires))


class ProfileMetadataTests(unittest.TestCase):
    def test_cms_date_is_read_as_utc_without_claiming_signature_validation(self):
        expiry=datetime(2030,1,2,3,4,5,tzinfo=timezone.utc)
        self.assertEqual(profile_expiration(profile(expiry)),expiry)

    def test_invalid_or_non_cms_data_cannot_invent_expiration(self):
        for value in (b'broken',plistlib.dumps({'ExpirationDate':datetime(2030,1,1)})):
            with self.assertRaises(ValueError):profile_expiration(value)

    def test_real_cms_signature_envelope_is_decoded_without_apple_trust_claim(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes,serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives.serialization import pkcs7
        key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        name=x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME,'Synthetic profile metadata fixture')])
        start=datetime(2020,1,1,tzinfo=timezone.utc);expiry=datetime(2030,1,2,tzinfo=timezone.utc)
        cert=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(1).not_valid_before(start).not_valid_after(expiry).sign(key,hashes.SHA256())
        data=plistlib.dumps({'ExpirationDate':expiry.replace(tzinfo=None)})
        envelope=pkcs7.PKCS7SignatureBuilder().set_data(data).add_signer(cert,key,hashes.SHA256()).sign(serialization.Encoding.DER,[pkcs7.PKCS7Options.Binary])
        self.assertEqual(profile_expiration(envelope),expiry)

    def test_earliest_nested_profile_deadline_is_used(self):
        with tempfile.TemporaryDirectory() as work:
            path=Path(work)/'app.ipa';main=datetime(2030,1,10,tzinfo=timezone.utc)
            earlier=main-timedelta(days=3);ipa(path,main)
            with zipfile.ZipFile(path,'a') as archive:
                archive.writestr('Payload/Demo.app/PlugIns/Test.appex/embedded.mobileprovision',profile(earlier))
            result=installation_metadata(path)
            self.assertEqual(result['expires'],earlier.isoformat())
            self.assertFalse(result['profileSignatureVerified'])

    def test_malformed_nested_profile_makes_the_deadline_unknown(self):
        with tempfile.TemporaryDirectory() as work:
            path=Path(work)/'app.ipa';ipa(path,datetime(2030,1,10,tzinfo=timezone.utc))
            with zipfile.ZipFile(path,'a') as archive:
                archive.writestr('Payload/Demo.app/PlugIns/Test.appex/embedded.mobileprovision',b'broken')
            self.assertIsNone(installation_metadata(path)['expires'])

    def test_oversized_nested_profile_cannot_be_ignored_when_reporting_expiry(self):
        with tempfile.TemporaryDirectory() as work:
            path=Path(work)/'app.ipa';ipa(path,datetime(2030,1,10,tzinfo=timezone.utc))
            with zipfile.ZipFile(path,'a') as archive:
                archive.writestr('Payload/Demo.app/PlugIns/Test.appex/embedded.mobileprovision',b'x'*1025)
            with patch('backend.library.PROFILE_LIMIT',1024):
                self.assertIsNone(installation_metadata(path)['expires'])


class InstallTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.policy=self.root/'policy.json';self.policy.write_text('{"protectedDeviceIds":[]}',encoding='utf-8')
        self.cache_base=self.root/'native-cache';self.cache_base.mkdir()
        self.environment=patch.dict('os.environ',{'WAYPOINT_PROTECTION_FILE':str(self.policy)})
        self.environment.start()
        self.temp_path=patch('backend.installations.tempfile.gettempdir',return_value=str(self.cache_base))
        self.temp_path.start()
        self.backend=Backend(self.root/'state',lambda _:None)
        self.backend.account={'email':'test@example.invalid'}
        self.source=self.root/'original.ipa';self.expiry=datetime(2030,1,2,tzinfo=timezone.utc)
        ipa(self.source,self.expiry);self.original=self.source.read_bytes()
        self.installed=[];self.native_calls=[];self.device_calls=[]
        self.flip_after_signing=False;self.flip_on_connect=False;self.sign_failure=False
        self.started=None;self.release=None;self.sign_input_existed=False
        self.params={'deviceId':'synthetic-phone','path':str(self.source),'mode':'appleId'}

        async def native(method,params):
            self.native_calls.append(method)
            if method!='ipa.sign':raise AssertionError(method)
            source=Path(params['path']);directory=extraction_cache(source.name)
            directory.mkdir()
            with zipfile.ZipFile(source) as archive:archive.extractall(directory)
            app=directory/'Payload/Demo.app'
            info=plistlib.loads((app/'Info.plist').read_bytes())
            info['CFBundleIdentifier']+='.'+'TESTTEAM'
            (app/'Info.plist').write_bytes(plistlib.dumps(info))
            (app/'embedded.mobileprovision').write_bytes(profile(self.expiry))
            if self.started:
                self.started.set();await self.release.wait()
                self.sign_input_existed=source.is_file()
            if self.flip_after_signing:self.protect()
            if self.sign_failure:raise RuntimeError('Synthetic signing failure')
            return {'signedPath':str(app)}
        self.backend.native_call=native

        @contextlib.asynccontextmanager
        async def device(identifier):
            self.device_calls.append(identifier)
            if self.flip_on_connect:self.protect()
            yield object()
        self.backend.device=device
        owner=self
        class Service:
            def __init__(self,*_):pass
            async def __aenter__(self):return self
            async def __aexit__(self,*_):pass
            async def install_from_local(self,path,handler):
                owner.installed.append(installation_metadata(path)['bundleId']);handler(100)
        self.service=patch('pymobiledevice3.services.installation_proxy.InstallationProxyService',Service)
        self.service.start()

    async def asyncTearDown(self):
        if self.release:self.release.set()
        await self.backend.close()
        self.service.stop();self.temp_path.stop();self.environment.stop();self.temp.cleanup()

    def protect(self):
        self.policy.write_text('{"protectedDeviceIds":["synthetic-phone"]}',encoding='utf-8')

    async def install(self,params=None):
        job=await self.backend.dispatch('install.start',params or self.params)
        task=self.backend.jobs[job['id']];await task
        return next(item for item in self.backend.records('jobs') if item['id']==job['id'])

    def assert_clean(self):
        self.assertEqual(list(self.cache_base.iterdir()),[])
        folder=self.backend.root/'install-workspaces'
        if folder.exists():self.assertEqual(list(folder.iterdir()),[])
        self.assertEqual(self.source.read_bytes(),self.original)

    async def test_actual_signed_identity_and_deadline_are_saved_with_private_source(self):
        result=await self.install({**self.params,'options':{'appName':'Custom'},'password':'never-store-this'})
        self.assertEqual(result['status'],'succeeded')
        entries=self.backend.records('library');self.assertEqual(len(entries),1)
        entry=entries[0]
        self.assertEqual(entry['bundleId'],'org.example.demo.TESTTEAM')
        self.assertEqual(entry['expires'],self.expiry.isoformat())
        self.assertTrue(entry['refreshable']);self.assertNotIn('never-store-this',json.dumps(entries))
        source=Path(entry['sourcePath'])
        with zipfile.ZipFile(source) as archive:
            info=plistlib.loads(archive.read('Payload/Demo.app/Info.plist'))
            self.assertEqual(info['CFBundleIdentifier'],'org.example.demo')
            self.assertEqual(info['CFBundleDisplayName'],'Custom')
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),entry['sourceSha256'])
        self.assert_clean()

    async def test_saved_source_refreshes_after_original_is_removed_without_duplicate_entries(self):
        await self.install();entry=self.backend.records('library')[0]
        self.source.unlink();self.expiry+=timedelta(days=7)
        job=await self.backend.dispatch('app.refresh',{'libraryId':entry['id']})
        await self.backend.jobs[job['id']]
        entries=self.backend.records('library')
        self.assertEqual(len(entries),1);self.assertEqual(entries[0]['id'],entry['id'])
        self.assertEqual(entries[0]['bundleId'],'org.example.demo.TESTTEAM')
        self.assertEqual(entries[0]['expires'],self.expiry.isoformat())
        self.assertEqual(self.installed,['org.example.demo.TESTTEAM']*2)

    async def test_refresh_rejects_a_different_apple_account(self):
        await self.install();entry=self.backend.records('library')[0]
        self.backend.account={'email':'different@example.invalid'}
        with self.assertRaisesRegex(ValueError,'Apple account used'):
            await self.backend.dispatch('app.refresh',{'libraryId':entry['id']})
        self.assertEqual(len(self.installed),1)

    async def test_refresh_uses_the_stored_device_and_cannot_bypass_its_protection(self):
        await self.install();entry=self.backend.records('library')[0];self.protect()
        with self.assertRaises(PermissionError):
            await self.backend.dispatch('app.refresh',{'libraryId':entry['id'],'deviceId':'unprotected-other-phone'})
        self.assertEqual(len(self.installed),1)

    async def test_modified_cached_ipa_cannot_reach_signing_or_installation(self):
        await self.install();entry=self.backend.records('library')[0]
        Path(entry['sourcePath']).write_bytes(b'tampered cached input')
        job=await self.backend.dispatch('app.refresh',{'libraryId':entry['id']})
        await self.backend.jobs[job['id']]
        result=self.backend.records('jobs')[0]
        self.assertEqual(result['status'],'failed');self.assertIn('source has changed',result['stage'])
        self.assertEqual(len(self.native_calls),1);self.assertEqual(len(self.installed),1)

    async def test_local_cache_failure_does_not_claim_the_phone_install_failed(self):
        with patch('backend.installations.cache_source',side_effect=OSError('Synthetic cache failure')):
            result=await self.install()
        self.assertEqual(result['status'],'succeeded');self.assertTrue(result['result']['installed'])
        self.assertFalse(result['result']['refreshSourceSaved'])
        entry=self.backend.records('library')[0];self.assertFalse(entry['refreshable'])
        self.assertIsNone(entry['sourcePath']);self.assert_clean()

    async def test_protection_changed_while_queued_stops_before_signing(self):
        lock=self.backend.device_locks.setdefault('synthetic-phone',asyncio.Lock());await lock.acquire()
        job=await self.backend.dispatch('install.start',self.params);task=self.backend.jobs[job['id']]
        self.protect();lock.release();await task
        self.assertEqual(self.native_calls,[]);self.assertEqual(self.device_calls,[])
        self.assertEqual(self.backend.records('jobs')[0]['status'],'failed');self.assert_clean()

    async def test_protection_changed_after_signing_stops_before_device_connection(self):
        self.flip_after_signing=True;result=await self.install()
        self.assertEqual(result['status'],'failed');self.assertEqual(self.device_calls,[])
        self.assertEqual(self.installed,[]);self.assert_clean()

    async def test_protection_changed_on_connect_stops_before_installation(self):
        self.flip_on_connect=True;result=await self.install()
        self.assertEqual(result['status'],'failed');self.assertEqual(self.installed,[])
        self.assertEqual(self.backend.records('library'),[]);self.assert_clean()

    async def test_cancel_waits_for_signer_before_removing_its_files_and_never_installs(self):
        self.started=asyncio.Event();self.release=asyncio.Event()
        job=await self.backend.dispatch('install.start',self.params);task=self.backend.jobs[job['id']]
        await self.started.wait()
        await self.backend.dispatch('jobs.cancel',{'jobId':job['id']})
        await self.backend.dispatch('jobs.cancel',{'jobId':job['id']})
        self.release.set();await task
        self.assertTrue(self.sign_input_existed);self.assertEqual(self.installed,[])
        self.assertEqual(self.backend.records('jobs')[0]['status'],'cancelled');self.assert_clean()

    async def test_signing_failure_cleans_owned_inputs_without_installing(self):
        self.sign_failure=True;result=await self.install()
        self.assertEqual(result['status'],'failed');self.assertEqual(self.installed,[]);self.assert_clean()

    async def test_existing_signature_is_tracked_but_cannot_be_renewed_with_no_identity(self):
        result=await self.install({**self.params,'mode':'existing'})
        self.assertEqual(result['status'],'succeeded');self.assertEqual(self.native_calls,[])
        entry=self.backend.records('library')[0];self.assertFalse(entry['refreshable'])
        with self.assertRaises(ValueError):await self.backend.dispatch('app.refresh',{'libraryId':entry['id']})
        self.assert_clean()

    async def test_cleanup_cannot_remove_an_unexpected_directory(self):
        outside=self.root/(str(uuid.uuid4())+'.ipa_extracted');outside.mkdir()
        (outside/'keep').write_text('preserve',encoding='utf-8')
        with self.assertRaises(RuntimeError):cleanup_extraction(outside)
        self.assertTrue((outside/'keep').exists())
