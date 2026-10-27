import importlib.util
import pathlib
import tempfile
import json
import copy
import os
import subprocess
import unittest
from unittest.mock import patch, Mock

path = pathlib.Path(__file__).resolve().parents[1] / 'idle-workload.py'
spec = importlib.util.spec_from_file_location('idle_workload', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IdleWorkloadTests(unittest.TestCase):
    def state(self, completed=False, count=20):
        keys = [str(n) for n in range(1, count + 1)]
        return {'kind': 'cross-site-documents', 'transport': 'same-origin-sse-v1',
                'expected_tabs': count, 'loads': count if completed else 0,
                'urls': {key: f'http://document-{key}.localhost:12345/document/{key}' for key in keys},
                'stream_connections': {key: 1 if completed else 0 for key in keys},
                'documents': {key: {'complete': True, 'seenVisible': True, 'sections': 240, 'pulse': 1}
                              for key in keys} if completed else {}}

    def sample_result(self):
        return {'browser': 'levistica-measurement', 'pid': 123, 'valid_sample_count': 1,
                'loaded_pages': 20, 'total_tabs': 20,
                'samples': [{'valid': True, 'identity_stable': True, 'missing_pids': [],
                             'tool_errors': [], 'sum_attributed_physical_footprints_bytes': 12345}]}

    def test_sample_result_rejects_wrong_target_counts_and_process_failure(self):
        original = self.sample_result()
        module.validate_sample_result(original, 123, 0)
        for key, value in [('browser', 'levistica'), ('pid', 124), ('valid_sample_count', 0),
                           ('loaded_pages', 19), ('total_tabs', 21), ('samples', []), ('samples', None)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate_sample_result({**original, key: value}, 123, 0)
        with self.assertRaises(ValueError):
            module.validate_sample_result(original, 123, 1)

    def test_success_count_cannot_override_invalid_or_incomplete_sample(self):
        for key, value in [('valid', False), ('valid', 1), ('identity_stable', False),
                           ('missing_pids', [124]), ('tool_errors', ['synthetic']),
                           ('sum_attributed_physical_footprints_bytes', None),
                           ('sum_attributed_physical_footprints_bytes', -1),
                           ('sum_attributed_physical_footprints_bytes', True)]:
            document = copy.deepcopy(self.sample_result())
            document['samples'][0][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                module.validate_sample_result(document, 123, 0)
        document = self.sample_result()
        document['samples'] = [None]
        with self.assertRaises(ValueError):
            module.validate_sample_result(document, 123, 0)

    def test_collector_timeout_terminates_only_its_new_process_group(self):
        process = Mock(pid=4321)
        process.communicate.side_effect = subprocess.TimeoutExpired('synthetic', 45)
        with patch.object(module.subprocess, 'Popen', return_value=process) as spawn, \
                patch.object(module.os, 'killpg') as kill, \
                patch.object(module.signal, 'signal', return_value='previous') as handler:
            with self.assertRaises(subprocess.TimeoutExpired):
                module.run_capture(['synthetic-command'])
            self.assertTrue(spawn.call_args.kwargs['start_new_session'])
            kill.assert_called_once_with(4321, module.signal.SIGTERM)
            process.wait.assert_called_once_with(timeout=5)
            self.assertEqual(handler.call_args.args, (module.signal.SIGTERM, 'previous'))

    def test_failed_collector_spawn_restores_handler_without_signalling(self):
        with patch.object(module.subprocess, 'Popen', side_effect=OSError('synthetic')), \
                patch.object(module.os, 'killpg') as kill, \
                patch.object(module.signal, 'signal', return_value='previous') as handler:
            with self.assertRaises(OSError):
                module.run_capture(['synthetic-command'])
            kill.assert_not_called()
            self.assertEqual(handler.call_args.args, (module.signal.SIGTERM, 'previous'))

    def test_result_path_must_be_unique_and_stay_in_local_memory_evidence(self):
        path = module.ROOT / '.local/artifacts/memory/synthetic/result.json'
        self.assertEqual(module.measurement_result(f'Local evidence: {path}\n'), path)
        for output in ['', f'Local evidence: {path}\nLocal evidence: {path}\n',
                       'Local evidence: /outside/result.json\n',
                       f'Local evidence: {module.ROOT}/.local/artifacts/memory/other.json\n']:
            with self.subTest(output=output), self.assertRaises(ValueError):
                module.measurement_result(output)

    def test_ram_capture_refuses_profile_and_normal_apps_before_inspecting_processes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / 'workload.json'
            for variant in ['Profile', 'Release', None]:
                path.write_text(json.dumps({'variant': variant}))
                with patch.object(module, 'verify_application') as verify:
                    with self.subTest(variant=variant), self.assertRaises(ValueError):
                        module.capture_memory(pathlib.Path(temporary) / 'absent-state.json', path)
                    verify.assert_not_called()

    def test_memory_mode_rejects_test_override_and_stack_logging_before_building(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        for settings in [{'TEST_ONLY': 'LevisticaTests'}, {'LEVISTICA_MALLOC_STACKS': '1'}]:
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith('LEVISTICA_') and key not in ('CONFIGURATION', 'TEST_ONLY')}
            result = subprocess.run(['bash', str(root / 'script/test.sh'), '--measure-idle-ui'],
                                    env={**env, **settings}, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertNotIn('Built ', result.stdout)

    def test_fifty_requires_explicit_count_and_matching_complete_documents(self):
        fresh = self.state(count=50)
        module.validate_state(fresh, count=50)
        completed = self.state(True, count=50)
        module.validate_state(completed, completed=True, count=50)
        with self.assertRaises(ValueError):
            module.validate_state(fresh)
        for count in (True, 50.0, '50', 100, 0, None):
            with self.subTest(count=count), self.assertRaises(ValueError):
                module.validate_state(fresh, count=count)
        for key, value in [('expected_tabs', 50.0), ('loads', False)]:
            bad = copy.deepcopy(fresh)
            bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate_state(bad, count=50)
        bad = copy.deepcopy(fresh)
        bad['stream_connections']['50'] = False
        with self.assertRaises(ValueError): module.validate_state(bad, count=50)
        for change in ('missing-last', 'reconnect-last', 'incomplete-last', 'wrong-host'):
            state = copy.deepcopy(completed)
            if change == 'missing-last': del state['documents']['50']
            elif change == 'reconnect-last': state['stream_connections']['50'] = 2
            elif change == 'incomplete-last': state['documents']['50']['complete'] = False
            else: state['urls']['50'] = 'http://document-51.localhost:12345/document/50'
            with self.subTest(change=change), self.assertRaises(ValueError):
                module.validate_state(state, completed=True, count=50)

    def test_fifty_marker_cannot_use_twenty_capture_or_implicit_delivery(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_path = pathlib.Path(temporary) / 'state.json'
            state = self.state(count=50)
            state_path.write_text(json.dumps(state))
            marker = pathlib.Path(temporary) / 'workload.json'
            workload = {'variant': 'Measurement', 'expected_tabs': 50, 'urls': state['urls'],
                        'state': str(state_path.resolve())}
            marker.write_text(json.dumps(workload))
            with patch.object(module, 'verify_application') as verify, patch.object(module, 'run_capture') as capture:
                with self.assertRaises(ValueError): module.capture_memory(state_path, marker)
                with self.assertRaises(ValueError): module.deliver_sequential(state_path, marker)
                verify.assert_not_called()
                capture.assert_not_called()
            for count in (20, 50.0, True, '50', None):
                workload['expected_tabs'] = count
                marker.write_text(json.dumps(workload))
                with self.subTest(count=count), patch.object(module, 'verify_application') as verify:
                    with self.assertRaises(ValueError): module.deliver_sequential(state_path, marker, count=50)
                    verify.assert_not_called()

    def test_expired_fifty_preparation_sends_no_next_url(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_path = pathlib.Path(temporary) / 'state.json'
            state = self.state(count=50)
            state_path.write_text(json.dumps(state))
            marker = pathlib.Path(temporary) / 'workload.json'
            marker.write_text(json.dumps({'variant': 'Measurement', 'expected_tabs': 50,
                                          'urls': state['urls'], 'state': str(state_path.resolve())}))
            with patch.object(module, 'verify_application'), patch.object(module.subprocess, 'run') as send, \
                    patch.object(module.time, 'monotonic', side_effect=[0, 181]):
                with self.assertRaisesRegex(ValueError, 'bounded time'):
                    module.deliver_sequential(state_path, marker, count=50)
                send.assert_not_called()

    def test_fifty_cli_rejects_profile_bulk_capture_and_monitor_before_io(self):
        for mode, variant in [('prepare', 'Profile'), ('deliver', 'Measurement'),
                              ('capture', 'Measurement'), ('monitor', 'Measurement')]:
            result = subprocess.run([module.sys.executable, str(path), mode, '/absent-fixture.json',
                                     '--count', '50', '--variant', variant], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('Fifty documents require', result.stderr)

    def test_preparation_requires_an_untouched_twenty_host_fixture(self):
        module.validate_state(self.state())
        with self.assertRaises(ValueError):
            module.validate_state(self.state(True))

    def test_completion_does_not_claim_background_report_freshness(self):
        state = self.state(True)
        for document in state['documents'].values():
            document['reported_monotonic'] = 0
        module.validate_state(state, completed=True)

    def test_reloads_reconnections_and_fixture_failures_are_rejected(self):
        for key, value in [('loads', 21), ('expected_tabs', 5), ('invalid_reason', 'Changed instance')]:
            state = self.state(True)
            state[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate_state(state, completed=True)
        state = self.state(True)
        state['stream_connections']['1'] = 2
        with self.assertRaises(ValueError):
            module.validate_state(state, completed=True)

    def test_misdirected_urls_are_rejected(self):
        for url in ['https://example.com/document/1', 'http://document-2.localhost:12345/document/1',
                    'http://user:secret@document-1.localhost:12345/document/1',
                    'http://document-1.localhost:54321/document/1',
                    'http://document-1.localhost:12345/document/1?unexpected=1']:
            state = self.state()
            state['urls']['1'] = url
            with self.subTest(url=url), self.assertRaises(ValueError):
                module.validate_state(state)

    def test_incomplete_documents_are_rejected(self):
        for key, value in [('seenVisible', False), ('complete', False), ('sections', 239), ('pulse', 0)]:
            state = self.state(True)
            state['documents']['20'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate_state(state, completed=True)

    def test_pressure_changes_and_read_errors_fail_closed(self):
        with patch.object(module.subprocess, 'check_output', return_value='1\n'):
            self.assertEqual(module.pressure(), 1)
        with patch.object(module.subprocess, 'check_output', return_value='2\n'):
            with self.assertRaises(ValueError):
                module.pressure()

        with patch.object(module.subprocess, 'check_output', side_effect=OSError('synthetic error')):
            with self.assertRaises(OSError):
                module.pressure()

    def test_profile_pid_start_time_and_path_must_match(self):
        executable = '/synthetic/Levistica.app/Contents/MacOS/Levistica'
        original = {'variant': 'Profile', 'pid': 123, 'executable': executable, 'started': 'original start'}
        for changed in [{}, {'pid': 124}, {'executable': '/different/Levistica'}, {'started': 'reused PID'}]:
            workload = {**original, **changed}
            with patch.object(module.processes, 'run_ps', side_effect=['synthetic snapshot', 'original start']), \
                    patch.object(module.processes, 'check_snapshot', return_value=[123]), \
                    patch.object(module.processes, 'known_apps', return_value={executable: 'dev.fomalhaut16.Levistica.profile'}):
                if changed:
                    with self.subTest(changed=changed), self.assertRaises(ValueError):
                        module.verify_application(workload)
                else:
                    module.verify_application(workload)

    def test_measurement_identity_checks_use_only_the_isolated_release(self):
        _, executable = module.application('Measurement')
        workload = {'variant': 'Measurement', 'pid': 123, 'executable': executable, 'started': 'original start'}
        with patch.object(module.processes, 'run_ps', side_effect=['synthetic snapshot', 'original start']), \
                patch.object(module.processes, 'check_snapshot', return_value=[123]) as check:
            module.verify_application(workload)
            self.assertEqual(check.call_args.kwargs['only'], 'Measurement')
        for variant in [None, 'Release', 'Debug', 'Other']:
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                module.verify_application({**workload, 'variant': variant})
        with patch.object(module.processes, 'run_ps', return_value='synthetic snapshot'), \
                patch.object(module.processes, 'check_snapshot', return_value=[124]):
            with self.assertRaises(ValueError):
                module.verify_application(workload)

    def test_release_idle_mode_rejects_unsafe_overrides_before_building(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        for settings in [{'TEST_ONLY': 'LevisticaTests'}, {'LEVISTICA_MALLOC_STACKS': '1'}]:
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith('LEVISTICA_') and key not in ('CONFIGURATION', 'TEST_ONLY')}
            result = subprocess.run(['bash', str(root / 'script/test.sh'), '--release-idle-ui'],
                                    env={**env, **settings}, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertNotIn('Built ', result.stdout)

    def test_idle_mode_rejects_test_override_and_stack_logging_before_building(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        for settings in [{'TEST_ONLY': 'LevisticaTests'}, {'LEVISTICA_MALLOC_STACKS': '1'}]:
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith('LEVISTICA_') and key not in ('CONFIGURATION', 'TEST_ONLY')}
            result = subprocess.run(['bash', str(root / 'script/test.sh'), '--idle-ui'],
                                    env={**env, **settings}, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertNotIn('Built ', result.stdout)


if __name__ == '__main__':
    unittest.main()
