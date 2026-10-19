from pathlib import Path
import tempfile
import unittest

from backend.server import Backend, clean_error


class BackendTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.events = []
        self.backend = Backend(self.temp.name, self.events.append)

    async def asyncTearDown(self):
        await self.backend.close()
        self.temp.cleanup()

    async def test_settings_survive_restart(self):
        settings = await self.backend.dispatch('settings.save', {'theme': 'dark', 'notASetting': 'ignored'})
        self.assertEqual(settings['theme'], 'dark')
        self.assertNotIn('notASetting', settings)
        self.assertFalse(settings['autoRefresh'])
        other = Backend(self.temp.name, self.events.append)
        try:
            self.assertEqual(other.settings()['theme'], 'dark')
        finally:
            await other.close()

    async def test_existing_signatures_cannot_be_installed_after_edit(self):
        with self.assertRaisesRegex(ValueError, 'invalidates its signature'):
            await self.backend.dispatch('install.start', {'deviceId':'test-phone','mode': 'existing', 'options': {'appName': 'Changed'}})
        self.assertEqual(self.backend.records('jobs'), [])

    async def test_uninstall_requires_explicit_confirmation(self):
        with self.assertRaisesRegex(ValueError, 'Confirm the exact app'):
            await self.backend.dispatch('app.uninstall', {'deviceId':'test-phone','bundleId': 'org.example.app', 'confirmation': 'other'})

    async def test_error_redacts_account(self):
        self.assertNotIn('person@example.com', clean_error(RuntimeError('Account person@example.com failed')))

    async def test_job_metadata_persists_without_credentials(self):
        job = {'id': 'sample', 'logs': [], 'status': 'queued'}
        self.backend.update_job(job, 'Uploading')
        other = Backend(self.temp.name, self.events.append)
        try:
            self.assertEqual(other.records('jobs')[0]['stage'], 'Uploading')
            self.assertEqual(len(self.events), 1)
        finally:
            await other.close()
