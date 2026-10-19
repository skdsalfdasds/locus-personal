import hashlib
import json
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
import zipfile

from backend.packages import inspect_ipa, prepare_ipa


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.ipa'
        with zipfile.ZipFile(self.source, 'w') as package:
            package.writestr('Payload/Demo.app/Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'org.example.demo', 'CFBundleExecutable': 'Demo',
                'CFBundleDisplayName': 'Demo', 'CFBundleShortVersionString': '1.0',
            }))
            package.writestr('Payload/Demo.app/PlugIns/Widget.appex/Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'org.example.demo.widget', 'CFBundleDisplayName': 'Widget',
            }))
            package.writestr('Payload/Demo.app/PlugIns/Other.appex/Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'org.example.demo.other',
            }))
            package.writestr('Payload/Demo.app/Demo', b'binary-content-preserved')
            package.writestr('Payload/Demo.app/_CodeSignature/CodeResources', b'old-signature')
            package.writestr('Payload/Demo.app/embedded.mobileprovision', b'old-profile')
        self.original = hashlib.sha256(self.source.read_bytes()).hexdigest()

    def tearDown(self):
        self.temp.cleanup()

    def test_customizations_preserve_original_and_rewrite_child_identity(self):
        destination = self.root / 'modified.ipa'
        result = prepare_ipa(str(self.source), str(destination), {
            'bundleId': 'com.example.changed', 'appName': 'Changed', 'version': '2.0',
            'fileSharing': True,
            'removeExtensions': ['Payload/Demo.app/PlugIns/Other.appex/'],
            'plistChanges': {'ExampleEnabled': True},
        })
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), self.original)
        self.assertFalse(result['signed'])
        with zipfile.ZipFile(destination) as package:
            info = plistlib.loads(package.read('Payload/Demo.app/Info.plist'))
            widget = plistlib.loads(package.read('Payload/Demo.app/PlugIns/Widget.appex/Info.plist'))
            self.assertEqual(info['CFBundleIdentifier'], 'com.example.changed')
            self.assertEqual(widget['CFBundleIdentifier'], 'com.example.changed.widget')
            self.assertTrue(info['UIFileSharingEnabled'])
            self.assertTrue(info['ExampleEnabled'])
            self.assertEqual(info['CFBundleDisplayName'], 'Changed')
            self.assertEqual(package.read('Payload/Demo.app/Demo'), b'binary-content-preserved')
            self.assertFalse(any('Other.appex' in name or '_CodeSignature' in name for name in package.namelist()))

    def test_failed_edit_does_not_replace_destination(self):
        destination = self.root / 'existing.ipa'
        destination.write_bytes(b'keep-existing-file')
        with self.assertRaises(ValueError):
            prepare_ipa(str(self.source), str(destination), {'plistChanges': '{broken'})
        self.assertEqual(destination.read_bytes(), b'keep-existing-file')
        self.assertEqual(sorted(p.name for p in self.root.glob('*.ipa')), ['existing.ipa', 'source.ipa'])

    def test_rejects_overwriting_source(self):
        with self.assertRaises(ValueError):
            prepare_ipa(str(self.source), str(self.source), {})
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), self.original)

    def test_rejects_zip_slip(self):
        with zipfile.ZipFile(self.source, 'a') as package:
            package.writestr('../../outside.txt', b'unsafe')
        with self.assertRaisesRegex(ValueError, 'unsafe file path'):
            inspect_ipa(self.source)

    def test_rejects_escaping_symlink(self):
        link = zipfile.ZipInfo('Payload/Demo.app/escape')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(self.source, 'a') as package:
            package.writestr(link, '../../../outside')
        with self.assertRaisesRegex(ValueError, 'symlink outside'):
            inspect_ipa(self.source)

    def test_rejects_duplicate_entries(self):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            with zipfile.ZipFile(self.source, 'a') as package:
                package.writestr('Payload/Demo.app/Demo', b'conflicting-content')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            inspect_ipa(self.source)
