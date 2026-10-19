import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from backend.server import Backend


class ProtectionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.policy = Path(self.temp.name) / 'device-protection.json'
        self.policy.write_text(json.dumps({'protectedDeviceIds': ['protected-phone']}))
        self.env = patch.dict('os.environ', {'WAYPOINT_PROTECTION_FILE': str(self.policy)})
        self.env.start()
        self.backend = Backend(Path(self.temp.name) / 'data', lambda _: None)
        self.backend.ensure_native = AsyncMock(side_effect=AssertionError('Native engine must not be reached'))

    async def asyncTearDown(self):
        await self.backend.close()
        self.env.stop()
        self.temp.cleanup()

    async def test_all_device_writes_block_before_any_transport(self):
        methods = ['setup.start', 'install.start', 'app.uninstall', 'pairing.createRemote',
                   'pairing.createLockdown', 'pairing.install', 'pairing.validate', 'device.enableWireless', 'ipa.sign']
        for method in methods:
            with self.subTest(method=method), self.assertRaisesRegex(PermissionError, 'active Waypoint'):
                await self.backend.dispatch(method, {'deviceId': 'protected-phone'})
        self.backend.ensure_native.assert_not_called()
        self.assertEqual(self.backend.records('jobs'), [])

    async def test_native_entrypoint_also_blocks_writes(self):
        for method in ('pairing.createRemote', 'pairing.validate', 'ipa.sign'):
            with self.subTest(method=method), self.assertRaises(PermissionError):
                await self.backend.native_call(method, {'deviceId': 'protected-phone'})
        self.backend.ensure_native.assert_not_called()

    async def test_broken_policy_fails_closed(self):
        self.policy.write_text('{broken')
        with self.assertRaises(PermissionError):
            self.backend.require_device_writes('any-phone')

    async def test_wrong_policy_schema_fails_closed(self):
        for policy in ({}, [], {'protectedDeviceIds':None}, {'protectedDeviceIds':'protected-phone'},
                       {'protectedDeviceIds':[None]}, {'protectedDeviceIds':['../invalid']}):
            with self.subTest(policy=policy), self.assertRaises(PermissionError):
                self.policy.write_text(json.dumps(policy))
                self.backend.require_device_writes('any-phone')

    async def test_policy_identifier_case_cannot_bypass_protection(self):
        with self.assertRaises(PermissionError):
            self.backend.require_device_writes('PROTECTED-PHONE')

    async def test_other_device_not_protected(self):
        self.backend.require_device_writes('another-phone')

    async def test_write_cannot_fall_back_to_first_connected_device(self):
        for missing in (None, '', '../phone'):
            with self.subTest(device=missing), self.assertRaises(ValueError):
                await self.backend.dispatch('install.start', {'deviceId':missing})
