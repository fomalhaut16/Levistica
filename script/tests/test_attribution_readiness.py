import contextlib
import copy
import importlib.util
import io
import json
import plistlib
import tempfile
import pathlib
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('readiness_measure', pathlib.Path(__file__).parents[1] / 'measure-memory.py')
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


class Clock:
    def __init__(self):
        self.now = 0

    def read(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def state(child=200, root_started='original'):
    return {'identities': {100: {'started': root_started, 'executable': '/synthetic/app'},
                           child: {'started': 'child', 'executable': '/synthetic/helper'}},
            'services': [{'pid': child, 'service': 'synthetic.service'}], 'exited_descendant_pids': []}


class AttributionReadinessTests(unittest.TestCase):
    def observe(self, reader, seconds=10, timeout=20, condition=None):
        self.clock = Clock()
        self.evidence = {}
        self.condition = condition or Mock()
        return measure.wait_for_stable_attribution(reader, self.condition, 100, seconds, timeout,
            self.evidence, interval=5, clock=self.clock.read, sleep=self.clock.sleep)

    def test_unchanged_attribution_requires_the_whole_window(self):
        reader = Mock(return_value=state())
        result = self.observe(reader)
        self.assertEqual(result, state())
        self.assertEqual(self.clock.now, 10)
        self.assertEqual(self.evidence['status'], 'ready')
        self.assertEqual(self.evidence['checks'], 3)
        self.assertEqual(self.evidence['changes'], [])
        self.assertEqual(self.condition.call_count, 3)
        self.assertEqual([c.args[0] for c in reader.call_args_list], [20, 20, 20])

    def test_child_change_restarts_only_the_window_and_is_recorded(self):
        reader = Mock(side_effect=[state(), state(201), state(201), state(201)])
        self.assertEqual(self.observe(reader), state(201))
        self.assertEqual(self.clock.now, 15)
        self.assertEqual(self.evidence['stable_seconds'], 10)
        self.assertEqual(self.evidence['changes'][0]['live_added'], [201])
        self.assertEqual(self.evidence['changes'][0]['live_removed'], [200])
        self.assertEqual([c.args[0] for c in reader.call_args_list], [20] * 4)

    def test_continued_churn_does_not_extend_the_deadline(self):
        reader = Mock(side_effect=[state(), state(201), state(), state(201)])
        with self.assertRaises(TimeoutError):
            self.observe(reader, timeout=15)
        self.assertEqual(self.clock.now, 15)
        self.assertEqual(self.evidence['status'], 'failed')
        self.assertEqual(self.evidence['checks'], 4)
        self.assertEqual(len(self.evidence['changes']), 3)

    def test_root_replacement_aborts_instead_of_becoming_a_new_baseline(self):
        reader = Mock(side_effect=[state(), state(root_started='replaced')])
        with self.assertRaisesRegex(ValueError, 'Root identity changed'):
            self.observe(reader)
        self.assertEqual(reader.call_count, 2)
        self.assertEqual(self.clock.now, 5)
        self.assertEqual(self.evidence['status'], 'failed')

    def test_unverifiable_snapshot_is_not_retried(self):
        reader = Mock(side_effect=ValueError('Unrecognized service row'))
        with self.assertRaisesRegex(ValueError, 'Unrecognized service row'):
            self.observe(reader)
        reader.assert_called_once()
        self.assertEqual(self.clock.now, 0)
        self.assertEqual(self.evidence['status'], 'failed')

    def test_fixture_failure_prevents_further_process_observation(self):
        reader = Mock(return_value=state())
        condition = Mock(side_effect=[None, ValueError('Fixture changed')])
        with self.assertRaisesRegex(ValueError, 'Fixture changed'):
            self.observe(reader, condition=condition)
        reader.assert_called_once()
        self.assertEqual(self.evidence['status'], 'failed')

    def test_late_successful_probe_cannot_pass_after_the_deadline(self):
        def reader(deadline):
            self.clock.now += 3
            return state()
        with self.assertRaises(TimeoutError):
            self.observe(reader, seconds=5, timeout=5)
        self.assertEqual(self.evidence['status'], 'failed')
        self.assertGreater(self.evidence['elapsed_seconds'], 5)

    def test_bad_bounds_do_not_access_processes(self):
        for seconds, timeout, interval in [(0, 10, 1), (121, 150, 5), (10, 9, 5), (10, 301, 5), (10, 20, 0)]:
            with self.subTest(seconds=seconds, timeout=timeout, interval=interval):
                reader = Mock()
                with self.assertRaises(ValueError):
                    measure.wait_for_stable_attribution(reader, Mock(), 100, seconds, timeout, {}, interval=interval)
                reader.assert_not_called()

    def test_readiness_cli_rejects_ordinary_browser_and_unbounded_options_before_os_access(self):
        options = [[], ['--browser', 'chrome'], ['--browser', 'chrome', '--ready-file', '/missing', '--attribution-timeout', '301']]
        for option in options:
            with self.subTest(option=option), patch('sys.argv', ['measure-memory.py', '--label', 'synthetic',
                    '--loaded-pages', '20', '--stable-attribution-seconds', '60', *option]), \
                    patch.object(measure, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    measure.main()
                self.assertEqual(result.exception.code, 2)
                run.assert_not_called()

    def test_snapshot_passes_remaining_time_to_domain_service_and_ps_queries(self):
        domain = 'pid/100 = {\n\toriginator = /synthetic/app\n\tcreator = Levistica[100]\n\tservices = {\n\t\t200 - synthetic.service\n\t}\n}'
        def query(args, timeout):
            if args[0] == '/bin/ps':
                return '100 Sat Oct 24 10:00:00 2026 /synthetic/app/executable\n200 Sat Oct 24 10:00:00 2026 /synthetic/helper\n'
            return domain if args[-1] == 'pid/100' else '\tdomain = pid/100\n\tpid = 200\n'
        with patch.object(measure.time, 'monotonic', return_value=10), patch.object(measure, 'run', side_effect=query) as run:
            result = measure.snapshot(100, pathlib.Path('/synthetic/app'), pathlib.Path('/synthetic/app/executable'), deadline=13)
        self.assertEqual(set(result['identities']), {100, 200})
        self.assertEqual(run.call_count, 3)
        self.assertTrue(all(c.kwargs['timeout'] == 3 for c in run.call_args_list))
        with patch.object(measure.time, 'monotonic', return_value=13), patch.object(measure, 'run') as run:
            with self.assertRaises(TimeoutError):
                measure.snapshot(100, deadline=13)
            run.assert_not_called()


    def test_collector_retains_readiness_failures_and_keeps_capture_checks(self):
        cases = [('unverifiable', [ValueError('Unverifiable attribution')], 0, False),
                 ('changed-before', [state(), state(), state(201)], 0, False),
                 ('changed-after', [state(), state(), state(), state(201)], 1, False),
                 ('stable', [state(), state(), state(), state()], 1, True)]
        original_open = pathlib.Path.open
        for label, snapshots, captures, valid in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary).resolve()
                profile = root / '.local/profile'
                profile.mkdir(parents=True)
                ready = root / '.local/fixture.json'
                ready.write_text(json.dumps({'ready_monotonic': 0}))
                clock = Clock()
                calls = []
                def fake_run(args):
                    calls.append(args)
                    if args[0] == '/usr/bin/footprint':
                        output = pathlib.Path(args[args.index('-j') + 1])
                        output.write_text(json.dumps({'bytes per unit': 1, 'unit': 'bytes',
                            'processes': [{'pid': 100, 'auxiliary': {'phys_footprint': 10}},
                                          {'pid': 200, 'auxiliary': {'phys_footprint': 20}}]}))
                        return ''
                    if args[:2] == ['git', 'status']:
                        return ''
                    return 'synthetic\n'
                def fake_open(path, *args, **kwargs):
                    if str(path) == '/Applications/Google Chrome.app/Contents/Info.plist':
                        return io.BytesIO(plistlib.dumps({'CFBundleIdentifier': 'synthetic.chrome'}))
                    return original_open(path, *args, **kwargs)
                arguments = ['measure-memory.py', '--label', label, '--browser', 'chrome',
                    '--chrome-profile', str(profile), '--ready-file', str(ready), '--ready-delay', '0',
                    '--loaded-pages', '5', '--total-tabs', '5', '--samples', '1',
                    '--stable-attribution-seconds', '1', '--attribution-timeout', '5']
                with patch('sys.argv', arguments), patch.object(measure, 'ROOT', root), \
                     patch.object(measure, 'run', side_effect=fake_run), \
                     patch.object(measure, 'find_app', return_value=100), \
                     patch.object(measure, 'snapshot', side_effect=snapshots), \
                     patch.object(measure, 'check_fixture'), \
                     patch.object(measure.time, 'monotonic', side_effect=clock.read), \
                     patch.object(measure.time, 'sleep', side_effect=clock.sleep), \
                     patch.object(pathlib.Path, 'read_bytes', return_value=b'synthetic'), \
                     patch.object(pathlib.Path, 'open', new=fake_open), \
                     contextlib.redirect_stdout(io.StringIO()):
                    result_code = measure.main()
                result = json.loads(next((root / '.local/artifacts/memory').glob('*/result.json')).read_text())
                sample = result['samples'][0]
                self.assertEqual(result_code, 0 if valid else 1)
                self.assertEqual(sample['valid'], valid)
                self.assertEqual(result['valid_sample_count'], int(valid))
                self.assertEqual(len([c for c in calls if c[0] == '/usr/bin/footprint']), captures)
                self.assertEqual(sample['attribution_readiness']['status'], 'failed' if label == 'unverifiable' else 'ready')
                if valid:
                    self.assertEqual(sample['sum_attributed_physical_footprints_bytes'], 30)
                    self.assertEqual(sample['capture_started_seconds_after_ready'], 1)
                    self.assertEqual(result['attribution_readiness_timeout_seconds'], 5)
                else:
                    self.assertIsNone(sample.get('sum_attributed_physical_footprints_bytes'))



if __name__ == '__main__':
    unittest.main()
