import asyncio
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock,Mock,patch

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

    async def test_native_deadline_stops_the_signer_and_invalidates_its_session(self):
        process=SimpleNamespace(returncode=None,stdin=SimpleNamespace(write=Mock(),drain=AsyncMock()))
        process.terminate=Mock(side_effect=lambda:setattr(process,'returncode',-15))
        process.kill=Mock();process.wait=AsyncMock(return_value=-15)
        self.backend.native=process;self.backend.ensure_native=AsyncMock()
        self.backend.account={'email':'test@example.invalid'}
        with patch('backend.server.NATIVE_TIMEOUT_SECONDS',0.01):
            with self.assertRaisesRegex(RuntimeError,'timed out'):
                await self.backend.native_call('ping',{})
        process.terminate.assert_called_once();self.assertIsNone(self.backend.account)
        self.assertEqual(self.backend.native_pending,{})

    async def test_timeout_from_retired_engine_cannot_kill_replacement(self):
        old=SimpleNamespace(returncode=None,stdin=SimpleNamespace(write=Mock(),drain=AsyncMock()),terminate=Mock())
        replacement=SimpleNamespace(returncode=0,terminate=Mock())
        self.backend.native=old;self.backend.ensure_native=AsyncMock()
        await self.backend.native_start_lock.acquire()
        try:
            with patch('backend.server.NATIVE_TIMEOUT_SECONDS',0.01):
                request=asyncio.create_task(self.backend.native_call('ping',{}))
                await asyncio.sleep(0.03)
                self.assertFalse(request.done())
                old.returncode=0;self.backend.native=replacement
                self.backend.account={'email':'new@example.invalid'}
                self.backend.native_start_lock.release()
                with self.assertRaisesRegex(RuntimeError,'timed out'):await request
            replacement.terminate.assert_not_called();old.terminate.assert_not_called()
            self.assertEqual(self.backend.account,{'email':'new@example.invalid'})
        finally:
            if self.backend.native_start_lock.locked():self.backend.native_start_lock.release()

    async def test_restart_waits_for_previous_pipe_readers(self):
        release=asyncio.Event()
        reader=asyncio.create_task(release.wait())
        self.backend.native_tasks.add(reader)
        reader.add_done_callback(self.backend.native_tasks.discard)
        old=SimpleNamespace(returncode=0)
        stream=asyncio.StreamReader();stream.feed_eof()
        errors=asyncio.StreamReader();errors.feed_eof()
        replacement=SimpleNamespace(returncode=0,stdout=stream,stderr=errors)
        self.backend.native=old
        with patch('backend.server.asyncio.create_subprocess_exec',new=AsyncMock(return_value=replacement)) as spawn:
            restart=asyncio.create_task(self.backend.ensure_native())
            await asyncio.sleep(0)
            spawn.assert_not_called()
            release.set();await restart
            spawn.assert_awaited_once()
            self.assertIs(self.backend.native,replacement)
