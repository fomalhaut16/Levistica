"""Reject unsafe profiling requests before stopping apps or invoking Xcode."""
import os
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ProfileBuildSafetyTests(unittest.TestCase):
    def rejected(self, **settings):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith('LEVISTICA_') and key != 'CONFIGURATION'}
        environment.update(settings)
        result = subprocess.run(['bash', str(ROOT / 'script/build_and_run.sh'), '--build'],
                                env=environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn('Built ', result.stdout)
        return result.stderr

    def test_profile_cannot_use_debug_or_an_unspecified_configuration(self):
        for configuration in [None, 'Debug']:
            with self.subTest(configuration=configuration):
                settings = dict(LEVISTICA_PROFILE='1', LEVISTICA_EPHEMERAL='1')
                if configuration is not None:
                    settings['CONFIGURATION'] = configuration
                self.assertIn('PROFILE requires Release', self.rejected(**settings))

    def test_profile_requires_explicit_ephemeral_data(self):
        for ephemeral in [None, '0', 'true']:
            with self.subTest(ephemeral=ephemeral):
                settings = dict(LEVISTICA_PROFILE='1', CONFIGURATION='Release')
                if ephemeral is not None:
                    settings['LEVISTICA_EPHEMERAL'] = ephemeral
                self.assertIn('EPHEMERAL=1', self.rejected(**settings))

    def test_profile_rejects_persistent_session_test_override(self):
        self.assertIn('no SESSION_TEST_ID', self.rejected(
            LEVISTICA_PROFILE='1', CONFIGURATION='Release', LEVISTICA_EPHEMERAL='1',
            LEVISTICA_SESSION_TEST_ID='b52d2f59-88ef-4d84-9ea1-931d419114f0'))

    def test_profile_rejects_unrecognized_opt_in(self):
        self.assertIn('must be 0 or 1', self.rejected(
            LEVISTICA_PROFILE='true', CONFIGURATION='Release', LEVISTICA_EPHEMERAL='1'))


if __name__ == '__main__':
    unittest.main()
