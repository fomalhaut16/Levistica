import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('observe_memory', pathlib.Path(__file__).parents[1] / 'observe-memory.py')
o = importlib.util.module_from_spec(spec)
spec.loader.exec_module(o)


def document():
    return {'unit': 'byte', 'bytes per unit': 1,
            'processes': [{'pid': 10, 'auxiliary': {'phys_footprint': 123}}], 'errors': []}


class ResourcePrivacyTests(unittest.TestCase):
    def test_numeric_values_and_numeric_permission_errors_are_preserved(self):
        doc = document()
        doc['errors'] = [{'pid': 11, 'errno': 1}]
        self.assertEqual(o.decode_rusage(json.dumps(doc), [10, 11]), doc)
        self.assertEqual(o.m.metrics(doc, [10, 11]), ({10: 123}, [11]))

    def test_unknown_content_at_every_level_is_rejected_without_echoing_it(self):
        for level in ('root', 'process', 'auxiliary', 'error'):
            doc = document()
            target = {'root': doc, 'process': doc['processes'][0], 'auxiliary': doc['processes'][0]['auxiliary']}.get(level)
            if level == 'error':
                doc['errors'] = [{'pid': 11, 'errno': 1}]
                target = doc['errors'][0]
            target['privateURL'] = 'https://private.invalid/secret'
            with self.subTest(level=level), self.assertRaises(ValueError) as caught:
                o.decode_rusage(json.dumps(doc), [10] if level != 'error' else [10, 11])
            self.assertNotIn('private.invalid', str(caught.exception))

    def test_wrong_units_values_duplicate_missing_and_unrequested_pids_fail(self):
        variants = []
        for key, value in [('unit', 'kilobyte'), ('bytes per unit', True), ('bytes per unit', 1024)]:
            doc = document(); doc[key] = value; variants.append(doc)
        for value in [True, -1, 1.5, '123', 2**64]:
            doc = document(); doc['processes'][0]['auxiliary']['phys_footprint'] = value; variants.append(doc)
        doc = document(); doc['processes'] *= 2; variants.append(doc)
        doc = document(); doc['processes'] = []; variants.append(doc)
        doc = document(); doc['processes'][0]['pid'] = 11; variants.append(doc)
        doc = document(); doc['errors'] = [{'pid': 10, 'errno': 1}]; variants.append(doc)
        for doc in variants:
            with self.subTest(doc=doc), self.assertRaises(ValueError):
                o.decode_rusage(json.dumps(doc), [10])
        for pids in [[], [10, 10], [True], [-1], [2**31]]:
            with self.subTest(pids=pids), self.assertRaises(ValueError):
                o.decode_rusage(json.dumps(document()), pids)

    def test_root_must_be_this_users_project_release_executable(self):
        target = pathlib.Path('/tmp/project/Release/Levistica.app/Contents/MacOS/Levistica')
        identity = {'executable': str(target), 'started': 'original'}
        with patch.object(o.m, 'BINARY', target), patch.object(o.m, 'identities', return_value={10: identity}), \
                patch.object(o.m, 'run', return_value=str(os.getuid())):
            self.assertEqual(o.root_identity(10), identity)
        for executable, uid in [(str(target), os.getuid()+1), ('/tmp/another/Levistica', os.getuid())]:
            with self.subTest(executable=executable), patch.object(o.m, 'BINARY', target), \
                    patch.object(o.m, 'identities', return_value={10: {**identity, 'executable': executable}}), \
                    patch.object(o.m, 'run', return_value=str(uid)), self.assertRaises(ValueError):
                o.root_identity(10)

    def test_binary_source_is_recorded_separately_but_must_be_clean_and_identified(self):
        info = {'CFBundleIdentifier': 'dev.fomalhaut16.Levistica', 'LevisticaSourceRevision': 'a'*40, 'LevisticaSourceState': 'clean'}
        self.assertEqual(o.checked_build(info), {'revision': 'a'*40, 'state': 'clean'})
        for key, value in [('CFBundleIdentifier', 'other'), ('LevisticaSourceRevision', 'unknown'), ('LevisticaSourceState', 'modified')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                o.checked_build({**info, key: value})


class CollectionTests(unittest.TestCase):
    identity = {'started': 'original', 'executable': '/tmp/Release/Levistica.app/Contents/MacOS/Levistica'}

    def snapshot(self):
        return {'identities': {10: self.identity}, 'services': [], 'exited_descendant_pids': []}

    def collect(self, response=None, snapshots=None):
        with patch.object(o.m, 'identities', return_value={10: self.identity}), \
                patch.object(o.m, 'snapshot', side_effect=snapshots or [self.snapshot(), self.snapshot()]), \
                patch.object(o.m, 'run', return_value=json.dumps(response or document())):
            return o.collect(10, self.identity, pathlib.Path('/tmp/helper'))

    def test_valid_sample_contains_only_aggregate_numeric_process_data(self):
        sample = self.collect()
        self.assertEqual(sample, {'valid': True, 'processes': [{'pid': 10, 'role': 'UI', 'physicalFootprintBytes': 123}], 'sumAttributedBytes': 123})
        self.assertNotIn('executable', json.dumps(sample))
        self.assertNotIn('/tmp', json.dumps(sample))

    def test_partial_resource_failure_does_not_become_a_zero_or_a_valid_total(self):
        doc = document(); doc['processes'] = []; doc['errors'] = [{'pid': 10, 'errno': 1}]
        sample = self.collect(response=doc)
        self.assertFalse(sample['valid'])
        self.assertEqual(sample['reason'], 'resource_unavailable')
        self.assertNotIn('sumAttributedBytes', sample)

    def test_service_change_invalidates_sample_without_dumping_domain_or_identity(self):
        after = self.snapshot(); after['services'] = [{'pid': 10, 'service': 'private-domain-marker'}]
        sample = self.collect(snapshots=[self.snapshot(), after])
        self.assertEqual(sample, {'valid': False, 'reason': 'attribution_changed'})

    def test_reused_root_pid_aborts_instead_of_following_the_new_process(self):
        with patch.object(o.m, 'identities', return_value={10: {**self.identity, 'started': 'replacement'}}):
            with self.assertRaises(o.RootChanged):
                o.collect(10, self.identity, pathlib.Path('/tmp/helper'))

    def test_failed_attribution_never_serializes_exception_text(self):
        with patch.object(o.m, 'identities', return_value={10: self.identity}), \
                patch.object(o.m, 'snapshot', side_effect=ValueError('private-url-and-environment')):
            sample = o.collect(10, self.identity, pathlib.Path('/tmp/helper'))
        self.assertEqual(sample['errorType'], 'ValueError')
        self.assertNotIn('private', json.dumps(sample))

    def test_exhausted_deadline_records_an_invalid_slot_without_another_root_query(self):
        ticks = iter([0, 26, 26])
        with patch.object(o.m, 'identities', side_effect=lambda _pids, query: query(['ps'])) as identities:
            sample = o.collect(10, self.identity, pathlib.Path('/tmp/helper'), clock=lambda: next(ticks))
        self.assertFalse(sample['valid'])
        self.assertEqual(sample['errorType'], 'TimeoutError')
        self.assertEqual(identities.call_count, 1)


class ScheduleTests(unittest.TestCase):
    def test_invalid_slots_are_not_retried_and_root_restart_ends_observation(self):
        now = [0.0]; calls = []; saves = []
        def take(_deadline):
            calls.append(now[0])
            if len(calls) == 3: raise o.RootChanged()
            return {'valid': len(calls) == 1}
        def sleep(seconds): now[0] += seconds
        rows, reason = o.schedule(5, 5, take, lambda rows, reason: saves.append((len(rows), reason)), lambda: False, clock=lambda: now[0], sleep=sleep)
        self.assertEqual(calls, [0, 5, 10])
        self.assertEqual([row['valid'] for row in rows], [True, False])
        self.assertEqual(reason, 'root_exited_or_changed')
        self.assertEqual(saves[-1], (2, reason))

    def test_slow_sample_does_not_create_a_burst_of_catchup_attempts(self):
        now = [0.0]; calls = []
        def take(_deadline):
            calls.append(now[0]); now[0] += 40; return {'valid': True}
        rows, reason = o.schedule(4, 5, take, lambda *_: None, lambda: False, clock=lambda: now[0], sleep=lambda s: None)
        self.assertEqual(calls, [0])
        self.assertEqual([row.get('reason') for row in rows], ['sample_deadline_exceeded', 'missed_schedule', 'missed_schedule', 'missed_schedule'])
        self.assertEqual(reason, 'completed')

    def test_progress_is_running_and_final_slot_interruption_is_not_completion(self):
        stop = [False]; states = []
        def take(_deadline):
            stop[0] = True
            return {'valid': True}
        rows, reason = o.schedule(1, 60, take, lambda rows, status: states.append(status), lambda: stop[0])
        self.assertEqual(len(rows), 1)
        self.assertEqual(states, ['running', 'interrupted'])
        self.assertEqual(reason, 'interrupted')

    def test_interruption_does_not_touch_the_application_or_attempt_more_samples(self):
        called = []
        rows, reason = o.schedule(5, 60, lambda: called.append(1), lambda *_: None, lambda: True)
        self.assertEqual((rows, reason, called), ([], 'interrupted', []))


@unittest.skipUnless(sys.platform == 'darwin', 'macOS libproc integration')
class NativeResourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helper, _ = o.prepare_helper()

    def test_own_process_has_a_physical_footprint_without_any_strings(self):
        pid = os.getpid()
        doc = o.decode_rusage(subprocess.check_output([str(self.helper), str(pid)], text=True), [pid])
        self.assertEqual(doc['errors'], [])
        self.assertGreater(doc['processes'][0]['auxiliary']['phys_footprint'], 0)

    def test_nonexistent_process_is_a_numeric_error_not_a_fake_zero(self):
        pid = 2**31-1
        doc = o.decode_rusage(subprocess.check_output([str(self.helper), str(pid)], text=True), [pid])
        self.assertEqual(doc['processes'], [])
        self.assertEqual(len(doc['errors']), 1)
        self.assertGreater(doc['errors'][0]['errno'], 0)

    def test_exited_child_is_unavailable_even_before_it_is_reaped(self):
        child = subprocess.Popen([sys.executable, '-c', 'pass'], stdout=subprocess.PIPE)
        try:
            child.stdout.read()
            state = subprocess.check_output(['/bin/ps', '-p', str(child.pid), '-o', 'stat='], text=True)
            self.assertTrue(state.strip().startswith('Z'))
            doc = o.decode_rusage(subprocess.check_output([str(self.helper), str(child.pid)], text=True), [child.pid])
            self.assertEqual(doc['processes'], [])
            self.assertEqual(len(doc['errors']), 1)
        finally:
            child.wait(timeout=5)
            child.stdout.close()

    def test_malformed_or_duplicate_input_emits_no_data(self):
        for args in [[], ['0'], ['-1'], ['123x'], ['10', '10'], [str(2**40)]]:
            with self.subTest(args=args):
                result = subprocess.run([str(self.helper), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')
