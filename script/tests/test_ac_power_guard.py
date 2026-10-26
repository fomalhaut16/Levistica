import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('power_measure', Path(__file__).parents[1] / 'measure-memory.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

AC = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=private-marker) 80%; charging\n"
BATTERY = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=private-marker) 80%; discharging\n"


class ACPowerGuardTests(unittest.TestCase):
    def test_only_explicit_power_header_is_accepted(self):
        self.assertEqual(m.parse_power_source(AC), 'ac')
        self.assertEqual(m.parse_power_source(BATTERY), 'battery')
        for text in ('', None, "Now drawing from 'UPS Power'", 'unknown\nAC Power', 'AC Power'):
            with self.subTest(text=text):
                self.assertEqual(m.parse_power_source(text), 'unknown')

    def test_observation_retains_only_source_phase_and_time(self):
        observations = []
        with patch.object(m, 'run', return_value=AC) as query:
            m.record_ac_power(observations, 'before_capture')
        query.assert_called_once_with(['/usr/bin/pmset', '-g', 'batt'], timeout=5)
        self.assertEqual(set(observations[0]), {'source', 'phase', 'time_utc'})
        self.assertNotIn('private-marker', json.dumps(observations))

    def test_failed_queries_and_unknown_sources_fail_closed(self):
        for outcome in (BATTERY, 'unknown', OSError('private-marker'),
                        subprocess.TimeoutExpired('pmset', 5)):
            observations = []
            with self.subTest(outcome=type(outcome).__name__), patch.object(m, 'run') as query:
                if isinstance(outcome, Exception):
                    query.side_effect = outcome
                else:
                    query.return_value = outcome
                with self.assertRaises(m.PowerConditionError) as error:
                    m.record_ac_power(observations, 'after_capture')
                self.assertEqual(len(observations), 1)
                self.assertNotIn('private-marker', str(error.exception))

    def test_initial_battery_blocks_target_inspection_and_capture(self):
        with patch('sys.argv', ['measure-memory.py', '--label', 'power-check', '--loaded-pages', '1',
                                '--require-ac-power']), patch.object(m, 'run', return_value=BATTERY) as query, \
                patch.object(m, 'find_app') as find, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                m.main()
        self.assertEqual(error.exception.code, 2)
        find.assert_not_called()
        self.assertEqual(query.call_count, 1)

    def collect(self, power_loss, required=True, stability=False):
        original_open = Path.open
        captures, power_calls = [], []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            profile = root / '.local/profile'
            profile.mkdir(parents=True)

            def query(args, **kwargs):
                if args[0] == '/usr/bin/pmset':
                    power_calls.append(args)
                    # Preflight, target boundary, legacy source metadata, then capture boundaries.
                    if power_loss in ('before', 'stability') and len(power_calls) >= 4:
                        return BATTERY
                    if power_loss == 'after' and captures:
                        return BATTERY
                    if power_loss == 'unknown-after' and captures:
                        raise OSError('private-marker')
                    return AC
                if args[0] == '/usr/bin/footprint':
                    captures.append(args)
                    Path(args[args.index('-j') + 1]).write_text(json.dumps({
                        'unit': 'bytes', 'bytes per unit': 1,
                        'processes': [{'pid': 100, 'auxiliary': {'phys_footprint': 30}}]}))
                    return ''
                return '' if args[:2] == ['git', 'status'] else 'synthetic\n'

            def open_file(path, *args, **kwargs):
                if str(path) == '/Applications/Google Chrome.app/Contents/Info.plist':
                    return io.BytesIO(plistlib.dumps({'CFBundleIdentifier': 'com.google.Chrome'}))
                return original_open(path, *args, **kwargs)

            snapshot = {'identities': {100: {'started': 'original', 'executable': '/synthetic/app'}},
                        'services': [], 'exited_descendant_pids': []}
            args = ['measure-memory.py', '--label', 'power-check', '--browser', 'chrome',
                    '--chrome-profile', str(profile), '--loaded-pages', '1', '--total-tabs', '1',
                    '--samples', '2', '--interval', '0']
            if required:
                args.append('--require-ac-power')
            if stability:
                ready = root / '.local/ready.json'
                ready.write_text(json.dumps({'ready_monotonic': 0}))
                args += ['--ready-file', str(ready), '--ready-delay', '0',
                         '--stable-attribution-seconds', '1', '--attribution-timeout', '5']
            def wait_for_stability(reader, check, *args, **kwargs):
                check()
                return reader(None)
            with patch('sys.argv', args), patch.object(m, 'ROOT', root), \
                    patch.object(m, 'find_app', return_value=100), \
                    patch.object(m, 'snapshot', return_value=snapshot), \
                    patch.object(m, 'run', side_effect=query), \
                    patch.object(m, 'check_fixture'), \
                    patch.object(m, 'wait_for_stable_attribution', side_effect=wait_for_stability), \
                    patch.object(Path, 'read_bytes', return_value=b'synthetic'), \
                    patch.object(Path, 'open', new=open_file), contextlib.redirect_stdout(io.StringIO()):
                code = m.main()
            result = json.loads(next((root / '.local/artifacts/memory').glob('*/result.json')).read_text())
        return code, result, captures

    def test_power_loss_before_capture_prevents_footprint_and_later_samples(self):
        code, result, captures = self.collect('before')
        self.assertEqual(code, 1)
        self.assertEqual(captures, [])
        self.assertEqual(len(result['samples']), 1)
        self.assertTrue(result['aborted_for_power_condition'])
        self.assertEqual(result['valid_sample_count'], 0)

    def test_power_loss_or_unknown_after_capture_discards_the_sample(self):
        for loss in ('after', 'unknown-after'):
            with self.subTest(loss=loss):
                code, result, captures = self.collect(loss)
                self.assertEqual(code, 1)
                self.assertEqual(len(captures), 1)
                self.assertEqual(len(result['samples']), 1)
                self.assertFalse(result['samples'][0]['valid'])
                self.assertIsNone(result['median_sum_attributed_bytes'])
                self.assertTrue(result['aborted_for_power_condition'])
                self.assertNotIn('private-marker', json.dumps(result))

    def test_power_loss_during_attribution_stability_prevents_capture(self):
        code, result, captures = self.collect('stability', stability=True)
        self.assertEqual(code, 1)
        self.assertEqual(captures, [])
        self.assertTrue(result['aborted_for_power_condition'])
        self.assertEqual(result['samples'][0]['power_checks'][0]['phase'], 'attribution_stability')

    def test_all_ac_boundaries_allow_both_samples(self):
        code, result, captures = self.collect(None)
        self.assertEqual(code, 0)
        self.assertEqual(len(captures), 2)
        self.assertEqual(result['valid_sample_count'], 2)
        self.assertFalse(result['aborted_for_power_condition'])
        self.assertTrue(all(x['source'] == 'ac'
                            for sample in result['samples'] for x in sample['power_checks']))

    def test_unrequested_guard_does_not_change_legacy_capture(self):
        code, result, captures = self.collect(None, required=False)
        self.assertEqual(code, 0)
        self.assertEqual(len(captures), 2)
        self.assertFalse(result['ac_power_required'])
        self.assertEqual(result['power_preparation_checks'], [])
        self.assertTrue(all('power_checks' not in s for s in result['samples']))


if __name__ == '__main__':
    unittest.main()
