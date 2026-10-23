import importlib.util
import pathlib
import os
import subprocess
import unittest
from unittest.mock import patch

path = pathlib.Path(__file__).resolve().parents[1] / 'idle-workload.py'
spec = importlib.util.spec_from_file_location('idle_workload', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IdleWorkloadTests(unittest.TestCase):
    def state(self, completed=False):
        keys = [str(n) for n in range(1, 21)]
        return {'kind': 'cross-site-documents', 'transport': 'same-origin-sse-v1',
                'expected_tabs': 20, 'loads': 20 if completed else 0,
                'urls': {key: f'http://document-{key}.localhost:12345/document/{key}' for key in keys},
                'stream_connections': {key: 1 if completed else 0 for key in keys},
                'documents': {key: {'complete': True, 'seenVisible': True, 'sections': 240, 'pulse': 1}
                              for key in keys} if completed else {}}

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
