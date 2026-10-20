import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import AsyncMock

from backend.server import Backend
from backend.workspace import WorkspaceLease


class WorkspaceTests(unittest.TestCase):
    def test_production_entrypoint_checks_lock_before_opening_workspace(self):
        with tempfile.TemporaryDirectory() as root:
            with WorkspaceLease(root):
                result=subprocess.run([sys.executable,'-m','backend.entry'],input='',capture_output=True,text=True,
                    env={**os.environ,'WAYPOINT_DATA_DIR':root},timeout=10)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('already using this workspace',result.stderr)
                self.assertFalse((Path(root)/'workspace.db').exists())

    def test_second_process_cannot_open_the_same_workspace(self):
        code = '''
import sys
from backend.workspace import WorkspaceLease
try:
    with WorkspaceLease(sys.argv[1]):print('acquired')
except RuntimeError:
    print('busy')
    sys.exit(3)
'''
        with tempfile.TemporaryDirectory() as root:
            with WorkspaceLease(root):
                result = subprocess.run([sys.executable,'-c',code,root],capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,3,result.stderr)
                self.assertEqual(result.stdout.strip(),'busy')
            result = subprocess.run([sys.executable,'-c',code,root],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout.strip(),'acquired')

    def test_os_releases_the_lease_after_process_death(self):
        code = '''
import sys
from backend.workspace import WorkspaceLease
with WorkspaceLease(sys.argv[1]):
    print('ready',flush=True)
    sys.stdin.readline()
'''
        with tempfile.TemporaryDirectory() as root:
            child = subprocess.Popen([sys.executable,'-c',code,root],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                self.assertEqual(child.stdout.readline().strip(),'ready')
                with self.assertRaises(RuntimeError):
                    with WorkspaceLease(root):pass
                child.kill()
                child.wait(timeout=10)
                # Windows can report process exit just before kernel handle
                # cleanup releases its byte-range locks. Verify eventual release
                # rather than assuming both notifications are synchronous.
                deadline=time.monotonic()+2
                while True:
                    try:
                        with WorkspaceLease(root):pass
                        break
                    except RuntimeError:
                        if time.monotonic()>=deadline:raise
                        time.sleep(0.01)
                self.assertTrue((Path(root)/'workspace.lock').is_file())
            finally:
                if child.poll() is None:child.kill()
                child.communicate(timeout=10)

    def test_other_workspace_can_be_opened_independently(self):
        with tempfile.TemporaryDirectory() as root:
            with WorkspaceLease(Path(root)/'first'), WorkspaceLease(Path(root)/'second'):pass


class RecoveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_production_entrypoint_recovers_before_replying(self):
        with tempfile.TemporaryDirectory() as root:
            first=Backend(root,lambda _:None)
            first.save_record('jobs',{'id':'unfinished','status':'running','logs':[],'progress':37})
            await first.close()
            result=subprocess.run([sys.executable,'-m','backend.entry'],
                input=json.dumps({'id':'check','method':'jobs.list','params':{}})+'\n',
                capture_output=True,text=True,env={**os.environ,'WAYPOINT_DATA_DIR':root},timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            messages=[json.loads(line) for line in result.stdout.splitlines()]
            reply=next(item for item in messages if item.get('id')=='check')
            self.assertEqual(reply['result'][0]['status'],'interrupted')
            self.assertIsNone(reply['result'][0]['progress'])

    async def test_restart_preserves_outcome_and_does_not_retry_device_work(self):
        with tempfile.TemporaryDirectory() as root:
            first = Backend(root,lambda _:None)
            for status in ('queued','running','succeeded','failed','cancelled','interrupted'):
                first.save_record('jobs',{'id':status,'status':status,'logs':[],'progress':50,
                    'result':{'installed':status=='running','bundleId':'org.example.synthetic'}})
            await first.close()
            with WorkspaceLease(root):
                restarted = Backend(root,lambda _:None)
                restarted.device=AsyncMock(side_effect=AssertionError('Recovery cannot touch a phone'))
                restarted.native_call=AsyncMock(side_effect=AssertionError('Recovery cannot start signing'))
                try:
                    restarted.recover_jobs()
                    records={item['id']:item for item in restarted.records('jobs')}
                    for identifier in ('queued','running'):
                        record=records[identifier]
                        self.assertEqual(record['status'],'interrupted')
                        self.assertIsNone(record['progress'])
                        self.assertIn('Check the device',record['stage'])
                        self.assertEqual(len(record['logs']),1)
                        self.assertIn('ended',record)
                    self.assertTrue(records['running']['result']['installed'])
                    for identifier in ('succeeded','failed','cancelled','interrupted'):
                        self.assertEqual(records[identifier]['status'],identifier)
                        self.assertEqual(records[identifier]['logs'],[])
                    restarted.recover_jobs()
                    self.assertEqual(len(next(item for item in restarted.records('jobs') if item['id']=='running')['logs']),1)
                    restarted.device.assert_not_called();restarted.native_call.assert_not_called()
                    self.assertEqual(restarted.jobs,{})
                finally:await restarted.close()
