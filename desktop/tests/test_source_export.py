import importlib.util
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('source_export',Path(__file__).resolve().parent.parent/'scripts/export-source.py')
exporter=importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class SourceExportTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.source=self.root/'source'
        self.destination=self.root/'export'
        for name in exporter.FILES:
            path=self.source/name;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text('placeholder\n',encoding='utf-8')
        self.sample=self.source/'src/sample.ts'
        self.sample.parent.mkdir(parents=True,exist_ok=True)
        self.sample.write_text('export const value = 1;\n',encoding='utf-8')

    def tearDown(self):
        self.temp.cleanup()

    def test_validation_failure_does_not_create_partial_destination(self):
        self.sample.write_bytes(b'export const text = "\x85";\n')
        with self.assertRaises(UnicodeDecodeError):
            exporter.export(self.source,self.destination)
        self.assertFalse(self.destination.exists())

    def test_private_runtime_directories_are_not_exported(self):
        for name in ('runtime/secret.plist','.data/pairing.plist','.tools/key.pem','outputs/report.txt'):
            path=self.source/name;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text('not for publication',encoding='utf-8')
        exporter.export(self.source,self.destination)
        for name in ('runtime','.data','.tools','outputs'):
            self.assertFalse((self.destination/name).exists())
        self.assertTrue((self.destination/'src/sample.ts').is_file())

    def test_pairing_file_in_source_directory_is_rejected(self):
        path=self.source/'backend/private.plist';path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text('<plist/>',encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'Unexpected file type'):
            exporter.export(self.source,self.destination)
        self.assertFalse(self.destination.exists())

    def test_protected_identifier_blocks_export(self):
        self.sample.write_text('const id = "private-test-identifier";',encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'Sensitive content'):
            exporter.export(self.source,self.destination,['private-test-identifier'])
        self.assertFalse(self.destination.exists())

    def test_cannot_export_into_source_and_recurse(self):
        with self.assertRaises(ValueError):
            exporter.export(self.source,self.source/'nested')
