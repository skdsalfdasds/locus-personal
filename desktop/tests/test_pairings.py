import contextlib
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, rsa
from cryptography.x509.oid import NameOID

from backend.pairings import inspect_bytes, destination_path, destinations
from backend.server import Backend


def remote_record():
    key = ed25519.Ed25519PrivateKey.generate()
    return {'private_key': key.private_bytes_raw(), 'public_key': key.public_key().public_bytes_raw(),
            'identifier': 'test-host-identity', 'alt_irk': b'0' * 16}


def lockdown_record():
    result = {'HostID': 'TEST-HOST', 'SystemBUID': 'TEST-SYSTEM', 'UDID': 'test-phone'}
    for name in ('Host', 'Root', 'Device'):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Synthetic ' + name)])
        now = datetime.now(timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                       .public_key(key.public_key()).serial_number(x509.random_serial_number())
                       .not_valid_before(now-timedelta(days=1)).not_valid_after(now+timedelta(days=1))
                       .sign(key, hashes.SHA256()))
        result[name+'Certificate'] = certificate.public_bytes(serialization.Encoding.PEM)
        if name != 'Device':
            result[name+'PrivateKey'] = key.private_bytes(serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return result


class PairingFormatTests(unittest.TestCase):
    def test_remote_xml_and_binary_have_same_fingerprint(self):
        record = remote_record()
        xml = inspect_bytes(plistlib.dumps(record))
        binary = inspect_bytes(plistlib.dumps(record, fmt=plistlib.FMT_BINARY))
        self.assertEqual(xml, binary)
        self.assertEqual(xml['kind'], 'remote')
        self.assertNotIn('private_key', xml)
        self.assertNotIn('identifier', xml)

    def test_mismatched_remote_key_rejected(self):
        record = remote_record()
        record['public_key'] = remote_record()['public_key']
        with self.assertRaisesRegex(ValueError, 'does not match'):
            inspect_bytes(plistlib.dumps(record))

    def test_invalid_wireless_identity_rejected(self):
        record = remote_record(); record['alt_irk'] = b'short'
        with self.assertRaisesRegex(ValueError, 'alt_irk'):
            inspect_bytes(plistlib.dumps(record))

    def test_lockdown_keys_and_device_binding(self):
        record = lockdown_record()
        result = inspect_bytes(plistlib.dumps(record))
        self.assertEqual(result['kind'], 'lockdown')
        self.assertEqual(result['embeddedDeviceId'], 'test-phone')
        record['HostPrivateKey'] = record['RootPrivateKey']
        with self.assertRaisesRegex(ValueError, 'matching private keys'):
            inspect_bytes(plistlib.dumps(record))

    def test_rejects_generic_plist_and_oversized_file(self):
        for data in (b'', b'x'*(1024*1024+1), plistlib.dumps({'not': 'pairing'})):
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                inspect_bytes(data)

    def test_subfolders_are_fixed_destinations_not_arbitrary_paths(self):
        self.assertEqual(destination_path('SideStore/Documents/ALTPairingFile.mobiledevicepairing'),
                         '/Documents/SideStore/Documents/ALTPairingFile.mobiledevicepairing')
        for name in ('../Library/pairing.plist', '/tmp/file', 'Documents/../../Library/key', 'pairingFile.plist/../other'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                destination_path(name)

    def test_all_known_app_destinations_and_file_sharing_filter(self):
        apps = [{'bundleId': str(i), 'name': name, 'fileSharing': True}
                for i, name in enumerate(['LiveContainer', 'Waypoint', 'SideStore', 'Auto Capture', 'Unknown'])]
        apps.append({'bundleId':'private','name':'Private','fileSharing':False})
        result = {item['name']:item for item in destinations('remote', apps)}
        self.assertNotIn('Private', result)
        self.assertEqual(result['LiveContainer']['recommendedPath'], 'SideStore/Documents/ALTPairingFile.mobiledevicepairing')
        self.assertEqual(result['Waypoint']['recommendedPath'], 'waypoint-setup-pairing.plist')
        self.assertEqual(result['Auto Capture']['recommendedPath'], 'rpPairingFile.plist')
        self.assertIsNone(result['Unknown']['recommendedPath'])


class PairingBackendTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.backend = Backend(self.root/'data', lambda _:None)
        self.policy = self.root/'policy.json'
        self.policy.write_text(json.dumps({'protectedDeviceIds':['protected-phone']}))
        self.env = patch.dict('os.environ', {'WAYPOINT_PROTECTION_FILE':str(self.policy)})
        self.env.start()
        self.source = self.root/'record.plist'
        self.raw = plistlib.dumps(remote_record())
        self.source.write_bytes(self.raw)
        self.backend.native_call = AsyncMock(return_value={'valid': True})
        self.backend.device = AsyncMock(side_effect=AssertionError('No phone access expected'))

    async def asyncTearDown(self):
        await self.backend.close(); self.env.stop(); self.temp.cleanup()

    async def test_import_is_local_private_and_unverified_until_authentication(self):
        record = await self.backend.dispatch('pairing.import', {'path':str(self.source)})
        self.assertIsNone(record['deviceId'])
        self.assertFalse(record['bindingVerified'])
        self.assertEqual(Path(record['path']).read_bytes(), self.raw)
        self.assertEqual(self.source.read_bytes(), self.raw)
        self.assertEqual(len(self.backend.records('pairings')), 1)
        self.backend.device.assert_not_called()
        self.backend.native_call.assert_not_called()
        self.assertNotIn('private_key', json.dumps(record))
        # The same file in binary form does not create another saved record.
        binary = self.root/'binary.plist'
        binary.write_bytes(plistlib.dumps(plistlib.loads(self.raw), fmt=plistlib.FMT_BINARY))
        duplicate = await self.backend.dispatch('pairing.import', {'path':str(binary)})
        self.assertEqual(record['id'], duplicate['id'])
        self.assertTrue(duplicate['alreadyImported'])

    async def test_validation_binds_only_after_native_success(self):
        record = await self.backend.dispatch('pairing.import', {'path':str(self.source)})
        params = {'pairingId':record['id'], 'deviceId':'test-phone'}
        self.backend.native_call.side_effect = RuntimeError('Device rejected the record')
        with self.assertRaises(RuntimeError):
            await self.backend.dispatch('pairing.validate', params)
        self.assertFalse(self.backend.records('pairings')[0]['bindingVerified'])
        self.backend.native_call.side_effect = None
        verified = await self.backend.dispatch('pairing.validate', params)
        self.assertTrue(verified['bindingVerified'])
        self.assertEqual(verified['deviceId'], 'test-phone')
        self.assertIn('lastValidated', verified)
        self.assertEqual(self.source.read_bytes(), self.raw)

    async def test_protected_device_never_reaches_validation_transport(self):
        record = await self.backend.dispatch('pairing.import', {'path':str(self.source)})
        with self.assertRaises(PermissionError):
            await self.backend.dispatch('pairing.validate', {'pairingId':record['id'], 'deviceId':'protected-phone'})
        self.backend.native_call.assert_not_called()

    async def test_unverified_import_cannot_be_transferred(self):
        record = await self.backend.dispatch('pairing.import', {'path':str(self.source), 'deviceId':'test-phone'})
        with self.assertRaisesRegex(ValueError, 'Validate this imported'):
            await self.backend.dispatch('pairing.install', {'pairingId':record['id'], 'deviceId':'test-phone','bundleId':'test.app'})
        self.backend.device.assert_not_called()

    async def test_lockdown_device_mismatch_stops_before_storage(self):
        self.source.write_bytes(plistlib.dumps(lockdown_record()))
        with self.assertRaisesRegex(ValueError, 'different device'):
            await self.backend.dispatch('pairing.import', {'path':str(self.source), 'deviceId':'wrong-phone'})
        self.assertEqual(self.backend.records('pairings'), [])

    async def test_livecontainer_transfer_creates_only_its_documents_subdirectory(self):
        record = await self.backend.dispatch('pairing.import', {'path':str(self.source), 'deviceId':'test-phone'})
        await self.backend.dispatch('pairing.validate', {'pairingId':record['id'], 'deviceId':'test-phone'})
        @contextlib.asynccontextmanager
        async def device(*args, **kwargs):
            yield object()
        self.backend.device = device
        service = AsyncMock()
        service.__aenter__.return_value = service
        service.isdir.return_value = False
        create = AsyncMock(return_value=service)
        with patch('pymobiledevice3.services.house_arrest.HouseArrestService.create',create):
            await self.backend.dispatch('pairing.install', {
                'pairingId':record['id'], 'deviceId':'test-phone','bundleId':'example.livecontainer',
                'filename':'SideStore/Documents/ALTPairingFile.mobiledevicepairing'})
        service.makedirs.assert_awaited_once_with('/Documents/SideStore/Documents')
        service.set_file_contents.assert_awaited_once_with(
            '/Documents/SideStore/Documents/ALTPairingFile.mobiledevicepairing', self.raw)
        self.assertTrue(create.call_args.kwargs['documents_only'])

    async def test_validated_record_cannot_be_moved_to_another_device(self):
        record = await self.backend.dispatch('pairing.import', {'path':str(self.source), 'deviceId':'test-phone'})
        await self.backend.dispatch('pairing.validate', {'pairingId':record['id'], 'deviceId':'test-phone'})
        self.backend.native_call.reset_mock()
        with self.assertRaisesRegex(ValueError, 'different device'):
            await self.backend.dispatch('pairing.validate', {'pairingId':record['id'], 'deviceId':'different-phone'})
        self.backend.native_call.assert_not_called()
