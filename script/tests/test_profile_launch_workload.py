import importlib.util
import copy
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('profile_launch_workload', ROOT / 'script/profile-launch-workload.py')
workload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workload)


class ProfileLaunchWorkloadTests(unittest.TestCase):
    def metrics(self):
        return [{'testIdentifier': 'BrowserFlowTests/testProfileBlankWindowLaunchMetric()',
                 'testRuns': [{'metrics': [{'identifier': workload.LAUNCH_METRIC,
                                           'unitOfMeasurement': 's', 'measurements': [0.9]}]}]}]

    def test_only_reported_first_frame_responsive_metric_is_accepted(self):
        result = workload.validate_metrics(self.metrics())
        self.assertEqual(result['firstFrameResponsiveSeconds'], 0.9)
        self.assertEqual(result['measuredSamples'], 1)
        self.assertFalse(result['productAccepted'])

    def test_other_metrics_units_counts_or_invalid_samples_are_rejected(self):
        for samples in [[], [0.1, 0.2], [0], [-1], [True], [float('nan')], [float('inf')]]:
            value = self.metrics()
            value[0]['testRuns'][0]['metrics'][0]['measurements'] = samples
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                workload.validate_metrics(value)
        for key, replacement in [('identifier', 'com.apple.dt.XCTMetric_Clock.duration'),
                                 ('unitOfMeasurement', 'ms')]:
            value = self.metrics()
            value[0]['testRuns'][0]['metrics'][0][key] = replacement
            with self.subTest(key=key), self.assertRaises(ValueError):
                workload.validate_metrics(value)
        value = self.metrics()
        value[0]['testRuns'][0]['metrics'] *= 2
        with self.assertRaises(ValueError):
            workload.validate_metrics(value)
        for value in [{}, [], self.metrics() * 2,
                      [{'testIdentifier': 'Other/test()', 'testRuns': []}]]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                workload.validate_metrics(copy.deepcopy(value))

    def baseline(self):
        value = plistlib.loads((ROOT / 'Levistica/Levistica.entitlements').read_bytes())
        value['com.apple.security.get-task-allow'] = True
        return value

    def test_current_authorized_profile_is_accepted(self):
        workload.validate_entitlements(self.baseline())

    def test_additional_privileges_or_missing_sandbox_are_rejected(self):
        for key in ['com.apple.security.cs.allow-jit', 'com.apple.security.cs.disable-library-validation',
                    'com.apple.security.network.server']:
            value = self.baseline()
            value[key] = True
            with self.subTest(key=key), self.assertRaises(ValueError):
                workload.validate_entitlements(value)
        for key in self.baseline():
            for replacement in [False, 1]:
                value = self.baseline()
                value[key] = replacement
                with self.subTest(key=key, replacement=replacement), self.assertRaises(ValueError):
                    workload.validate_entitlements(value)
        value = self.baseline()
        del value['com.apple.security.app-sandbox']
        with self.assertRaises(ValueError):
            workload.validate_entitlements(value)


if __name__ == '__main__':
    unittest.main()
