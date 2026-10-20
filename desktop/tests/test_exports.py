import hashlib
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
import zipfile

from backend.packages import checked_entries, pack_signed_bundle
from backend.server import Backend


def fixture(path):
    with zipfile.ZipFile(path,'w') as archive:
        archive.writestr('Payload/Demo.app/Info.plist',plistlib.dumps({
            'CFBundleIdentifier':'org.example.demo','CFBundleExecutable':'Demo'}))
        binary=zipfile.ZipInfo('Payload/Demo.app/Demo')
        binary.create_system=3;binary.external_attr=(stat.S_IFREG|0o755)<<16
        archive.writestr(binary,b'synthetic executable')


def link(archive,name,target):
    item=zipfile.ZipInfo('Payload/Demo.app/'+name)
    item.create_system=3;item.external_attr=(stat.S_IFLNK|0o777)<<16
    archive.writestr(item,target.encode())


class ArchiveLinkTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.source=self.root/'source.ipa';fixture(self.source)

    def tearDown(self):self.temp.cleanup()

    def test_composed_symlinks_cannot_escape(self):
        with zipfile.ZipFile(self.source,'a') as archive:
            link(archive,'a','..');link(archive,'b','a/../../..')
        with zipfile.ZipFile(self.source) as archive:
            with self.assertRaisesRegex(ValueError,'outside its package'):checked_entries(archive)

    def test_cyclic_symlinks_rejected(self):
        with zipfile.ZipFile(self.source,'a') as archive:
            link(archive,'a','b');link(archive,'b','a')
        with zipfile.ZipFile(self.source) as archive:
            with self.assertRaisesRegex(ValueError,'cyclic'):checked_entries(archive)

    def test_standard_versioned_framework_links_are_valid(self):
        with zipfile.ZipFile(self.source,'a') as archive:
            archive.writestr('Payload/Demo.app/F.framework/Versions/A/F',b'framework')
            link(archive,'F.framework/Versions/Current','A')
            link(archive,'F.framework/F','Versions/Current/F')
        with zipfile.ZipFile(self.source) as archive:self.assertEqual(len(checked_entries(archive)),5)

    def test_drive_relative_paths_and_symlink_targets_rejected(self):
        for target in ('C:outside','C:/outside'):
            path=self.root/'bad.ipa';fixture(path)
            with zipfile.ZipFile(path,'a') as archive:link(archive,'bad',target)
            with zipfile.ZipFile(path) as archive:
                with self.assertRaisesRegex(ValueError,'unsafe'):checked_entries(archive)

    def test_materialized_symlink_does_not_replace_destination(self):
        with zipfile.ZipFile(self.source,'a') as archive:link(archive,'alias','Demo')
        app=self.root/'Demo.app';app.mkdir()
        with zipfile.ZipFile(self.source) as archive:
            (app/'Info.plist').write_bytes(archive.read('Payload/Demo.app/Info.plist'))
        (app/'Demo').write_bytes(b'signed');(app/'alias').write_bytes(b'signed')
        destination=self.root/'existing.ipa';destination.write_bytes(b'preserve')
        with self.assertRaisesRegex(ValueError,'symbolic link'):
            pack_signed_bundle(app,self.source,destination)
        self.assertEqual(destination.read_bytes(),b'preserve')
        self.assertEqual(sorted(p.name for p in self.root.glob('*.ipa')),['existing.ipa','source.ipa'])


class ExportTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.source=self.root/'original.ipa';fixture(self.source)
        self.original=hashlib.sha256(self.source.read_bytes()).digest()
        self.backend=Backend(self.root/'state',emit=lambda _:None)

    async def asyncTearDown(self):
        await self.backend.close();self.temp.cleanup()

    async def test_export_is_offline_preserves_modes_and_cleans_workspaces(self):
        native_calls=[]
        async def native(method,params):
            native_calls.append(method)
            self.assertEqual(plistlib.loads(params['entitlementsXml'].encode()),{'get-task-allow':True})
            directory=self.backend.root/'native/exports/adhoc-fixture'
            app=directory/'Payload/Demo.app';app.mkdir(parents=True)
            with zipfile.ZipFile(params['path']) as archive:
                for name in ('Info.plist','Demo'):(app/name).write_bytes(archive.read('Payload/Demo.app/'+name))
            return {'workspace':str(directory),'signedPath':str(app),'verifiedBinaries':1}
        self.backend.native_call=native
        self.backend.device=lambda *_:self.fail('Offline export must not connect to a phone')
        with patch.object(self.backend,'require_device_writes',side_effect=AssertionError('No device writes')):
            result=await self.backend.dispatch('ipa.exportSigned',{
                'path':str(self.source),'destination':str(self.root/'export.ipa'),'entitlements':{'get-task-allow':True}})
        self.assertEqual(native_calls,['ipa.adhoc'])
        self.assertEqual(result['signatureMode'],'adhoc');self.assertFalse(result['appleProvisioned'])
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).digest(),self.original)
        self.assertEqual(list((self.backend.root/'native/exports').iterdir()),[])
        self.assertEqual(list((self.backend.root/'export-jobs').iterdir()),[])
        with zipfile.ZipFile(result['path']) as archive:
            self.assertEqual(stat.S_IMODE(archive.getinfo('Payload/Demo.app/Demo').external_attr>>16),0o755)

    async def test_failed_native_signing_preserves_existing_output(self):
        self.backend.native_call=AsyncMock(side_effect=RuntimeError('Signing failed'))
        output=self.root/'existing.ipa';output.write_bytes(b'keep output')
        with self.assertRaisesRegex(RuntimeError,'Signing failed'):
            await self.backend.dispatch('ipa.exportSigned',{'path':str(self.source),'destination':str(output)})
        self.assertEqual(output.read_bytes(),b'keep output')
        self.assertEqual(list((self.backend.root/'export-jobs').iterdir()),[])

    async def test_unexpected_native_path_is_never_removed(self):
        outside=self.root/'adhoc-outside';outside.mkdir();(outside/'keep').write_text('keep',encoding='utf-8')
        self.backend.native_call=AsyncMock(return_value={'workspace':str(outside),'signedPath':str(outside/'Demo.app')})
        with self.assertRaisesRegex(RuntimeError,'unexpected workspace'):
            await self.backend.dispatch('ipa.exportSigned',{'path':str(self.source),'destination':str(self.root/'out.ipa')})
        self.assertEqual((outside/'keep').read_text(encoding='utf-8'),'keep')

    async def test_source_cannot_be_export_destination(self):
        self.backend.native_call=AsyncMock()
        with self.assertRaisesRegex(ValueError,'different file'):
            await self.backend.dispatch('ipa.exportSigned',{'path':str(self.source),'destination':str(self.source)})
        self.backend.native_call.assert_not_called()

    async def test_unknown_install_mode_rejected_before_job_creation(self):
        with self.assertRaises(ValueError):
            await self.backend.dispatch('install.start',{'deviceId':'synthetic-phone','mode':'adhoc'})
        self.assertEqual(self.backend.records('jobs'),[])
