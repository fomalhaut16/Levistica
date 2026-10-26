import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ViewportProbeFlags(unittest.TestCase):
    def test_invalid_flags_stop_before_any_build_or_app_action(self):
        cases = [({}, '--build'), ({'CONFIGURATION': 'Release'}, '--build'),
                 ({'CONFIGURATION': 'Release', 'LEVISTICA_EPHEMERAL': '1'}, '--build'),
                 ({'CONFIGURATION': 'Release', 'LEVISTICA_EPHEMERAL': '1',
                   'LEVISTICA_MEASUREMENT': '1', 'LEVISTICA_PROFILE': '1'}, '--build'),
                 ({'CONFIGURATION': 'Release', 'LEVISTICA_EPHEMERAL': '1',
                   'LEVISTICA_MEASUREMENT': '1', 'LEVISTICA_MEASUREMENT_STORE_ID': 'synthetic'}, '--build'),
                 ({'CONFIGURATION': 'Release', 'LEVISTICA_EPHEMERAL': '1',
                   'LEVISTICA_MEASUREMENT': '1'}, '--archive-local')]
        for flags, mode in cases:
            env = {k: v for k, v in os.environ.items() if not k.startswith('LEVISTICA_') and k != 'CONFIGURATION'}
            env.update(LEVISTICA_VIEWPORT_PROBE='1', **flags)
            with self.subTest(flags=flags, mode=mode):
                result = subprocess.run(['bash', str(ROOT/'script/build_and_run.sh'), mode],
                                        env=env, capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode, 2)
                self.assertIn('VIEWPORT_PROBE', result.stderr)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
