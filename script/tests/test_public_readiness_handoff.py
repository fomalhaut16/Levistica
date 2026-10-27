import http.client
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('public_handoff', Path(__file__).parents[1] / 'public-readiness-handoff.py')
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


def snapshot(phase='before'):
    return {'phase': phase, 'pid': 123, 'instance': 'bba2085c-bab0-432e-8f30-54b64dd84765',
            'revision': 1, 'documentElapsed': 10000 if phase == 'before' else 14000,
            'mediaTime': 30 if phase == 'before' else 34, 'width': 779, 'height': 683,
            'videoWidth': 1280, 'videoHeight': 720, 'dpr': 2, 'muted': True, 'paused': False,
            'playbackRate': 1, 'loadedPages': 4, 'readyState': 4}


class HandoffValidationTests(unittest.TestCase):
    def test_pair_must_keep_native_identity_and_live_progress(self):
        before, after = snapshot(), snapshot('after')
        handoff.validate_snapshot(before)
        handoff.validate_snapshot(after, before)
        for key, value in [('instance', 'e52f839f-4030-4a30-91b6-38f4a78af0e3'),
                           ('revision', 2), ('pid', 124), ('phase', 'before'),
                           ('documentElapsed', 9000), ('documentElapsed', 40000),
                           ('mediaTime', 30), ('mediaTime', 80), ('paused', True),
                           ('muted', False), ('width', 700), ('videoHeight', 480),
                           ('loadedPages', 3), ('playbackRate', 2), ('readyState', 0)]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                handoff.validate_snapshot({**after, key: value}, before)

    def test_only_the_numeric_allowlist_can_be_retained(self):
        for changed in [{'url': 'private'}, {'token': 'private'}, {'title': 'private'},
                        {'mediaTime': float('nan')}, {'documentElapsed': float('inf')},
                        {'mediaTime': 10 ** 1000},
                        {'pid': True}, {'revision': 1.0}, {'instance': 'not-uuid'},
                        {'muted': 1}, {'paused': 0}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                handoff.validate_snapshot({**snapshot(), **changed})


class HandoffHTTPTests(unittest.TestCase):
    def setUp(self):
        self.now = 100
        self.verify_count = 0
        self.fail_at = None
        def verify():
            self.verify_count += 1
            if self.verify_count == self.fail_at:
                raise ValueError('simulated owner change')
        self.server = handoff.create_server(123, verify, clock=lambda: self.now)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())

    def post(self, value=None, extra=None, path='/public-readiness'):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        headers = {'Content-Type': 'application/json', 'X-Levistica-Diagnostic': self.server.token}
        headers.update(extra or {})
        try:
            connection.request('POST', path, json.dumps(value if value is not None else snapshot()), headers)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_pair_authenticates_twice_and_never_claims_ram(self):
        self.assertEqual(self.post()[0], 200)
        self.now = 104
        status, body = self.post(snapshot('after'))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {'success': True, 'memorySamplesTaken': 0, 'readyForRAM': False})
        self.assertEqual(self.verify_count, 4)
        self.assertEqual(len(self.server.records), 2)
        self.assertEqual(self.post(snapshot('after'))[0], 409)

    def test_browser_origin_wrong_host_token_and_path_cannot_notify(self):
        for extra, path in [({'Origin': 'https://example.invalid'}, '/public-readiness'),
                            ({'Host': 'example.invalid'}, '/public-readiness'),
                            ({'X-Levistica-Diagnostic': 'not-this-run'}, '/public-readiness'),
                            ({'Content-Type': 'text/plain'}, '/public-readiness'),
                            ({}, '/other')]:
            with self.subTest(extra=extra, path=path):
                self.assertEqual(self.post(extra=extra, path=path)[0], 403)
        self.assertEqual(self.verify_count, 0)
        self.assertEqual(self.server.records, [])

    def test_reversed_phase_is_rejected_and_cannot_be_retried(self):
        self.assertEqual(self.post(snapshot('after'))[0], 409)
        self.assertEqual(self.post()[0], 409)
        self.assertEqual(self.server.records, [])

    def test_elapsed_client_clock_does_not_replace_receiver_time(self):
        self.assertEqual(self.post()[0], 200)
        self.now = 101
        self.assertEqual(self.post(snapshot('after'))[0], 409)
        self.assertEqual(len(self.server.records), 1)

    def test_owner_change_before_or_after_read_prevents_acceptance(self):
        for fail_at in [1, 2]:
            self.verify_count = 0
            self.fail_at = fail_at
            self.server.failure = None
            self.assertEqual(self.post()[0], 409)
            self.assertEqual(self.server.records, [])

    def test_observation_for_another_pid_is_rejected(self):
        self.assertEqual(self.post({**snapshot(), 'pid': 999})[0], 409)
        self.assertEqual(self.server.records, [])

    def memory_server(self, fail_finish=False):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        sampler = SimpleNamespace(attempts=0, finished=False)
        def capture():
            sampler.attempts += 1
        def finish():
            if fail_finish:
                raise ValueError('simulated changed attribution')
            sampler.finished = True
        sampler.capture, sampler.finish = capture, finish
        self.server = handoff.create_server(123, lambda: None, clock=lambda: self.now, sampler=sampler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return sampler

    def test_explicit_sampling_runs_once_between_the_two_authenticated_observations(self):
        sampler = self.memory_server()
        self.assertEqual(self.post(extra={'X-Levistica-Diagnostic': 'wrong'})[0], 403)
        self.assertEqual(sampler.attempts, 0)
        status, body = self.post()
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['memorySamplesTaken'], 1)
        self.now = 104
        self.assertEqual(self.post(snapshot('after'))[0], 200)
        self.assertTrue(sampler.finished)
        self.assertEqual(sampler.attempts, 1)
        self.assertEqual(self.post(snapshot('after'))[0], 409)

    def test_failed_post_capture_check_cannot_complete_the_pair(self):
        sampler = self.memory_server(fail_finish=True)
        self.assertEqual(self.post()[0], 200)
        self.now = 104
        self.assertEqual(self.post(snapshot('after'))[0], 409)
        self.assertEqual(len(self.server.records), 1)
        self.assertEqual(sampler.attempts, 1)
        self.assertEqual(self.server.failure, 'observation_rejected')


class ReceiverShutdownTests(unittest.TestCase):
    def test_parent_termination_preserves_a_zero_sample_failure_record(self):
        child_code = '''
import importlib.util, pathlib, plistlib, sys
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('receiver',sys.argv[1]);h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
info=plistlib.dumps({'LevisticaSourceRevision':'c'*40,'LevisticaSourceState':'clean'})
def query(args,**kwargs):return 'c'*40 if args[1]=='rev-parse' else ''
with patch.object(h.guard,'validate'),patch.object(h.guard,'validate_lifetime'),patch.object(h.guard,'verify_owned'),patch.object(h.subprocess,'check_output',side_effect=query),patch.object(pathlib.Path,'read_bytes',return_value=info):
    h.serve(pathlib.Path(sys.argv[2]))
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            workload = path / 'workload.json'
            workload.write_text(json.dumps({'pid': 123, 'dryRunPublicHandoff': True,
                'executable': '/fake/Levistica.app/Contents/MacOS/Levistica'}))
            child = subprocess.Popen([sys.executable, '-c', child_code,
                                      str(Path(handoff.__file__)), str(workload)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not (path / 'public-handoff.json').exists() and time.monotonic() < deadline:
                    self.assertIsNone(child.poll())
                    time.sleep(.02)
                self.assertTrue((path / 'public-handoff.json').exists())
                child.terminate()
                child.wait(timeout=5)
                result = json.loads((path / 'public-handoff-result.json').read_text())
                self.assertFalse(result['success'])
                self.assertEqual(result['failure'], 'receiver_interrupted')
                self.assertEqual(result['memorySamplesTaken'], 0)
                self.assertEqual(result['records'], [])
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
