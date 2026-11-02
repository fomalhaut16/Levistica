import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseLaunchFlagsTests(unittest.TestCase):
    def test_caller_cannot_override_launch_selection_or_storage(self):
        cases = [({'TEST_ONLY': 'LevisticaUITests'}, 'does not accept TEST_ONLY'),
                 ({'LEVISTICA_MALLOC_STACKS': '1'}, 'MALLOC_STACKS requires'),
                 ({'CONFIGURATION': 'Release'}, 'owns its build'),
                 ({'LEVISTICA_PROFILE': '1'}, 'owns its build'),
                 ({'LEVISTICA_MEASUREMENT': '1'}, 'owns its build'),
                 ({'LEVISTICA_SESSION_TEST_ID': 'synthetic'}, 'owns its build'),
                 ({'LEVISTICA_MEASUREMENT_STORE_ID': 'synthetic'}, 'owns its build'),
                 ({'LEVISTICA_MEASUREMENT_PERSIST_METADATA': '1'}, 'owns its build'),
                 ({'LEVISTICA_MEASUREMENT_CLEANUP_REQUEST': ''}, 'owns its build')]
        for mode in ['--profile-launch-ui', '--measurement-launch-ui']:
            self.check_rejected_overrides(mode, cases)

    def check_rejected_overrides(self, mode, cases):
        for flags, error in cases:
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith('LEVISTICA_') and k not in ('TEST_ONLY', 'CONFIGURATION')}
            env.update(flags)
            with self.subTest(flags=flags):
                result = subprocess.run(['bash', str(ROOT / 'script/test.sh'), mode],
                                        env=env, capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 2)
                self.assertIn(error, result.stderr)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
