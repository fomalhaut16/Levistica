import importlib.util
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('profile_launch_workload', ROOT / 'script/profile-launch-workload.py')
workload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workload)


class ProfileLaunchWorkloadTests(unittest.TestCase):
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
