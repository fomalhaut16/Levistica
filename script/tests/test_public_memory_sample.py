import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('public_memory_test', Path(__file__).parents[1] / 'public-memory-sample.py')
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)


class SamplingTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.state = {'identities': {1: {'executable': 'app', 'started': 'first'},
                                     2: {'executable': 'web', 'started': 'second'}},
                      'services': [{'pid': 2, 'service': 'com.apple.WebKit.WebContent.test'}],
                      'exited_descendant_pids': []}
        self.context = {'available': True, 'powerSource': 'ac', 'memoryPressureLevel': 1}
        self.calls = 0
        def values(pids, deadline):
            self.calls += 1
            return {'unit': 'byte', 'bytes per unit': 1, 'errors': [],
                    'processes': [{'pid': pid, 'auxiliary': {'phys_footprint': pid * 100}} for pid in pids]}
        self.sampler = memory.Sampler(1, lambda deadline: copy.deepcopy(self.state),
                                      lambda deadline: dict(self.context), values, clock=lambda: self.now)

    def settle(self, until):
        self.sampler.tick()
        while self.now < until:
            self.now += 5
            self.sampler.tick()

    def test_sixty_second_window_resets_on_service_changes_and_captures_once(self):
        self.sampler.tick()
        self.now = 30
        self.state['identities'][3] = {'executable': 'gpu', 'started': 'third'}
        self.state['services'].append({'pid': 3, 'service': 'com.apple.WebKit.GPU.test'})
        self.sampler.tick()
        self.settle(85)
        self.now = 89
        with self.assertRaises(ValueError):
            self.sampler.capture()
        self.assertEqual(self.calls, 0)
        self.now = 90
        self.sampler.capture()
        self.assertEqual(self.calls, 1)
        self.assertEqual(self.sampler.sample['sumAttributedPhysicalFootprintsBytes'], 600)
        self.assertEqual([p['role'] for p in self.sampler.sample['processes']], ['UI', 'WebContent', 'GPU'])
        self.assertFalse(self.sampler.sample['valid'])
        with self.assertRaises(ValueError):
            self.sampler.capture()
        self.assertEqual(self.calls, 1)

    def test_missing_power_pressure_or_context_prevents_capture(self):
        for changed in [{'available': False}, {'powerSource': 'battery'},
                        {'powerSource': 'unknown'}, {'memoryPressureLevel': 2},
                        {'memoryPressureLevel': True}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                memory.require_context({**self.context, **changed})
        self.sampler.tick()
        self.now = 60
        self.context['powerSource'] = 'battery'
        with self.assertRaises(ValueError):
            self.sampler.capture()
        self.assertEqual(self.calls, 0)

    def test_root_replacement_aborts_instead_of_resetting_the_window(self):
        self.sampler.tick()
        self.now = 60
        self.state['identities'][1]['started'] = 'replacement'
        with self.assertRaises(ValueError):
            self.sampler.capture()
        self.assertEqual(self.calls, 0)

    def test_late_capture_and_missing_pid_never_become_a_provisional_sample(self):
        self.settle(60)
        def late(pids, deadline):
            self.now += 4
            return {'unit': 'byte', 'bytes per unit': 1, 'errors': [], 'processes': []}
        self.sampler.read_values = late
        with self.assertRaises(ValueError):
            self.sampler.capture()
        self.assertEqual(self.sampler.attempts, 1)
        self.assertIsNone(self.sampler.sample)

    def test_membership_change_after_capture_invalidates_the_handoff(self):
        self.settle(60)
        self.sampler.capture()
        self.state['services'] = []
        with self.assertRaises(ValueError):
            self.sampler.finish()
        self.assertFalse(self.sampler.sample['valid'])

    def test_long_observation_gap_does_not_count_as_stability(self):
        self.sampler.tick()
        self.now = 60
        with self.assertRaises(ValueError):
            self.sampler.capture()
        self.assertEqual(self.calls, 0)

    def test_ui_only_attribution_is_not_a_browser_sample(self):
        self.state['identities'].pop(2)
        self.state['services'] = []
        self.settle(60)
        with self.assertRaises(ValueError):
            self.sampler.capture()
        self.assertEqual(self.calls, 0)

    def chrome_sampler(self):
        self.sampler.content_role = 'Renderer'
        self.sampler.role_for = lambda pid, root, state: 'UI' if pid == root else 'Renderer'

    def test_confirmed_exit_discards_preparation_and_requires_sixty_new_seconds(self):
        self.chrome_sampler()
        self.settle(60)
        original = self.sampler.read_attribution
        self.now = 65
        self.sampler.read_attribution = lambda deadline: (_ for _ in ()).throw(memory.m.ConfirmedExitedChromeDescendants([2]))
        self.sampler.tick()
        self.assertIsNone(self.sampler.baseline)
        self.assertIsNone(self.sampler.stable_since)
        self.assertEqual(self.calls, 0)
        self.assertEqual(len(self.sampler.confirmed_exits), 1)
        self.sampler.read_attribution = original
        self.now = 70
        self.settle(125)
        with self.assertRaises(ValueError): self.sampler.capture()
        self.assertEqual(self.calls, 0)
        self.now = 130
        self.sampler.capture()
        self.assertEqual(self.calls, 1)
        self.assertEqual(self.sampler.sample['stableAttributionSeconds'], 60)

    def test_root_identity_survives_a_discarded_chrome_preparation(self):
        self.chrome_sampler()
        self.sampler.tick()
        original = self.sampler.read_attribution
        self.now = 5
        self.sampler.read_attribution = lambda deadline: (_ for _ in ()).throw(memory.m.ConfirmedExitedChromeDescendants([2]))
        self.sampler.tick()
        self.state['identities'][1]['started'] = 'reused PID'
        self.now = 10
        self.sampler.read_attribution = original
        with self.assertRaisesRegex(ValueError, 'Root identity changed'): self.sampler.tick()
        self.assertEqual(self.calls, 0)

    def test_native_and_unclassified_failures_still_abort(self):
        for error, chrome in [(memory.m.ConfirmedExitedChromeDescendants([2]), False), (ValueError('unverified domain'), True)]:
            with self.subTest(chrome=chrome):
                self.sampler.content_role = 'Renderer' if chrome else 'WebContent'
                self.sampler.read_attribution = lambda deadline: (_ for _ in ()).throw(error)
                with self.assertRaises(type(error)): self.sampler.tick(force=True)
                self.assertEqual(self.sampler.confirmed_exits, [])
                self.assertEqual(self.calls, 0)

    def test_an_empty_or_root_exit_tag_cannot_reset_preparation(self):
        self.chrome_sampler()
        for pids in [[], [1]]:
            with self.subTest(pids=pids):
                self.sampler.read_attribution = lambda deadline: (_ for _ in ()).throw(memory.m.ConfirmedExitedChromeDescendants(pids))
                with self.assertRaises(memory.m.ConfirmedExitedChromeDescendants): self.sampler.tick(force=True)
                self.assertEqual(self.sampler.confirmed_exits, [])
                self.assertEqual(self.calls, 0)

    def test_confirmed_exit_during_capture_is_not_retried_or_omitted(self):
        self.chrome_sampler()
        self.settle(60)
        self.sampler.read_attribution = lambda deadline: (_ for _ in ()).throw(memory.m.ConfirmedExitedChromeDescendants([2]))
        with self.assertRaises(memory.m.ConfirmedExitedChromeDescendants): self.sampler.capture()
        self.assertEqual(self.calls, 0)
        self.assertEqual(self.sampler.confirmed_exits, [])

    def test_exit_after_numeric_read_invalidates_the_only_attempt(self):
        self.chrome_sampler()
        self.settle(60)
        original = self.sampler.read_values
        def values(pids, deadline):
            result = original(pids, deadline)
            self.sampler.read_attribution = lambda deadline: (_ for _ in ()).throw(memory.m.ConfirmedExitedChromeDescendants([2]))
            return result
        self.sampler.read_values = values
        with self.assertRaises(memory.m.ConfirmedExitedChromeDescendants): self.sampler.capture()
        self.assertEqual(self.calls, 1)
        self.assertEqual(self.sampler.attempts, 1)
        self.assertIsNone(self.sampler.sample)
        with self.assertRaises(ValueError): self.sampler.capture()
        self.assertEqual(self.calls, 1)

    def test_confirmed_exit_after_provisional_capture_aborts_finalization(self):
        self.chrome_sampler()
        self.settle(60)
        self.sampler.capture()
        self.now = 65
        self.sampler.read_attribution = lambda deadline: (_ for _ in ()).throw(memory.m.ConfirmedExitedChromeDescendants([2]))
        with self.assertRaises(memory.m.ConfirmedExitedChromeDescendants): self.sampler.tick()
        with self.assertRaises(memory.m.ConfirmedExitedChromeDescendants): self.sampler.finish()
        self.assertFalse(self.sampler.sample['valid'])
        self.assertEqual(self.sampler.confirmed_exits, [])

    def test_explicit_chrome_roles_share_the_same_sampling_checks(self):
        previous = self.sampler
        self.sampler = memory.Sampler(1, previous.read_attribution, previous.read_context,
                                     previous.read_values, clock=lambda: self.now,
                                     role_for=lambda pid, root, state: 'UI' if pid == root else 'Renderer',
                                     content_role='Renderer')
        self.settle(60)
        self.sampler.capture()
        self.assertEqual([row['role'] for row in self.sampler.sample['processes']], ['UI', 'Renderer'])
        self.assertEqual(self.sampler.sample['sumAttributedPhysicalFootprintsBytes'], 300)
        self.assertFalse(self.sampler.sample['valid'])


class FinalizationTests(unittest.TestCase):
    def fixture(self):
        before = {'phase': 'before', 'pid': 1, 'instance': 'bba2085c-bab0-432e-8f30-54b64dd84765',
                  'revision': 1, 'documentElapsed': 10000, 'mediaTime': 30, 'width': 779, 'height': 683,
                  'videoWidth': 1280, 'videoHeight': 720, 'dpr': 2, 'muted': True, 'paused': False,
                  'playbackRate': 1, 'loadedPages': 4, 'readyState': 4}
        context = {'available': True, 'powerSource': 'ac', 'memoryPressureLevel': 1}
        sample = {'valid': False, 'capturedMonotonic': 101, 'completedMonotonic': 102,
                  'stableAttributionSeconds': 65, 'systemBefore': context, 'systemAfter': context,
                  'processes': [{'pid': 1, 'role': 'UI', 'physicalFootprintBytes': 100},
                                {'pid': 2, 'role': 'WebContent', 'physicalFootprintBytes': 200}],
                  'sumAttributedPhysicalFootprintsBytes': 300}
        return {'success': True, 'failure': None, 'memorySamplesTaken': 1, 'sourceRevision': 'c' * 40,
                'records': [{'receivedMonotonic': 100, 'snapshot': before},
                            {'receivedMonotonic': 104, 'snapshot': {**before, 'phase': 'after',
                             'documentElapsed': 14000, 'mediaTime': 34}}],
                'provisionalMemorySample': sample, 'memoryProvenance': {'method': 'test'}}

    def finalize(self, result, summary=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            workload = {'samplePublicMemory': True, 'dryRunPublicHandoff': False, 'pid': 1,
                        'executable': str(memory.ROOT / '.local/MeasurementDerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica'),
                        'started': 'test-start',
                        'steadyPublicVideo': True, 'mixedPublicPages': True,
                        'prepareMixedBeforePlayback': True, 'audiblePublicVideo': False}
            summary = summary if summary is not None else dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
            for name, value in [('public-handoff-result.json', result), ('test-summary.json', summary),
                                ('deadline-workload.json', workload)]:
                (path / name).write_text(json.dumps(value))
            with patch.object(memory.m, 'run', return_value='c' * 40):
                return memory.finalize(path)

    def test_only_complete_ui_trial_promotes_the_provisional_value(self):
        result = self.fixture()
        output = self.finalize(result)
        self.assertTrue(output['valid'])
        self.assertFalse(output['validForComparison'])
        self.assertFalse(result['provisionalMemorySample']['valid'])
        for summary in [dict(totalTestCount=0, passedTests=0, failedTests=0, skippedTests=0),
                        dict(totalTestCount=1, passedTests=0, failedTests=1, skippedTests=0),
                        dict(totalTestCount=1, passedTests=0, failedTests=0, skippedTests=1)]:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                self.finalize(result, summary)

    def test_capture_outside_observations_wrong_source_or_total_is_rejected(self):
        for key, value in [('capturedMonotonic', 99), ('completedMonotonic', 105),
                           ('stableAttributionSeconds', 59), ('sumAttributedPhysicalFootprintsBytes', 101)]:
            result = self.fixture()
            result['provisionalMemorySample'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.finalize(result)
        result = self.fixture()
        result['sourceRevision'] = 'd' * 40
        with self.assertRaises(ValueError):
            self.finalize(result)

    def test_document_replacement_or_failed_handoff_never_publishes_a_sample(self):
        result = self.fixture()
        result['records'][1]['snapshot']['revision'] = 2
        with self.assertRaises(ValueError):
            self.finalize(result)
        result = self.fixture()
        result['success'] = False
        with self.assertRaises(ValueError):
            self.finalize(result)


if __name__ == '__main__':
    unittest.main()
