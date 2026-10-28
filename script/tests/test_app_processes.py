import importlib.util
import pathlib
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location('app_processes', pathlib.Path(__file__).parents[1] / 'check-app-processes.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class AppProcessIdentityTests(unittest.TestCase):
    root = pathlib.Path('/synthetic/Levistica')

    def snapshot(self, variant='Release', pid=42, root=None):
        root = root or self.root
        paths = guard.known_apps(root)
        path = next(p for p, identifier in paths.items()
                    if identifier == {'Debug': 'dev.fomalhaut16.Levistica.debug',
                                      'Release': 'dev.fomalhaut16.Levistica',
                                      'Profile': 'dev.fomalhaut16.Levistica.profile',
                                      'Measurement': 'dev.fomalhaut16.Levistica.measurement'}[variant])
        return f'{pid} {path}\n', {'path': path, 'uid': 501, 'name': 'Levistica', 'identifier': paths[path]}

    def test_each_owned_variant_is_recognized_by_path(self):
        for variant in ['Debug', 'Release', 'Profile', 'Measurement']:
            with self.subTest(variant=variant):
                snapshot, identity = self.snapshot(variant)
                self.assertEqual(guard.check_snapshot(snapshot, self.root, lambda *_: identity, 501, only=variant), [42])

    def test_renamed_process_at_owned_executable_is_rejected(self):
        snapshot, identity = self.snapshot()
        identity['name'] = 'Instruments'
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            guard.check_snapshot(snapshot, self.root, lambda *_: identity, 501)

    def test_another_checkout_is_not_inspected_or_targeted(self):
        snapshot, _ = self.snapshot(root=pathlib.Path('/other/Levistica'))
        describe = Mock()
        self.assertEqual(guard.check_snapshot(snapshot, self.root, describe, 501), [])
        describe.assert_not_called()

    def test_changed_path_after_snapshot_is_rejected(self):
        snapshot, identity = self.snapshot()
        identity['path'] = '/unrelated/application'
        with self.assertRaises(ValueError):
            guard.check_snapshot(snapshot, self.root, lambda *_: identity, 501)

    def test_wrong_owner_or_bundle_identifier_is_rejected(self):
        for key, value in [('uid', 0), ('identifier', 'com.apple.dt.Instruments')]:
            with self.subTest(key=key):
                snapshot, identity = self.snapshot()
                identity[key] = value
                with self.assertRaises(ValueError):
                    guard.check_snapshot(snapshot, self.root, lambda *_: identity, 501)

    def test_process_that_exited_before_inspection_is_ignored(self):
        snapshot, _ = self.snapshot()
        self.assertEqual(guard.check_snapshot(snapshot, self.root, lambda *_: None, 501), [])

    def test_inspection_failure_is_not_treated_as_absence(self):
        snapshot, _ = self.snapshot()
        with self.assertRaises(PermissionError):
            guard.check_snapshot(snapshot, self.root, Mock(side_effect=PermissionError('denied')), 501)

    def test_checkout_path_with_spaces_is_preserved(self):
        root = pathlib.Path('/synthetic/My Browser')
        snapshot, identity = self.snapshot(root=root)
        self.assertEqual(guard.check_snapshot(snapshot, root, lambda *_: identity, 501), [42])

    def test_measurement_check_rejects_normal_release_or_profile(self):
        for other in ['Release', 'Profile']:
            measured, measured_identity = self.snapshot('Measurement', pid=40)
            unexpected, unexpected_identity = self.snapshot(other, pid=42)
            identities = {40: measured_identity, 42: unexpected_identity}
            with self.subTest(other=other), self.assertRaisesRegex(ValueError, f'Unexpected {other}'):
                guard.check_snapshot(measured + unexpected, self.root, lambda pid, _: identities[pid], 501, only='Measurement')

    def test_normal_release_is_not_allowed_in_profile_only_check(self):
        profile, profile_identity = self.snapshot('Profile', pid=41)
        normal, normal_identity = self.snapshot('Release', pid=42)
        identities = {41: profile_identity, 42: normal_identity}
        with self.assertRaisesRegex(ValueError, 'Unexpected Release'):
            guard.check_snapshot(profile + normal, self.root, lambda pid, _: identities[pid], 501, only='Profile')


    def test_installed_app_is_recognized_and_blocks_isolated_variants(self):
        path = str(pathlib.Path.home() / 'Applications/Levistica.app/Contents/MacOS/Levistica')
        snapshot = f'43 {path}\n'
        identity = {'path': path, 'uid': 501, 'name': 'Levistica', 'identifier': 'dev.fomalhaut16.Levistica'}
        self.assertEqual(guard.check_snapshot(snapshot, self.root, lambda *_: identity, 501), [43])
        for variant in ['Debug', 'Profile', 'Measurement']:
            with self.subTest(variant=variant), self.assertRaisesRegex(ValueError, 'Unexpected Release'):
                guard.check_snapshot(snapshot, self.root, Mock(), 501, only=variant)

    def test_installed_app_still_requires_matching_owner_and_bundle(self):
        path = str(pathlib.Path.home() / 'Applications/Levistica.app/Contents/MacOS/Levistica')
        identity = {'path': path, 'uid': 0, 'name': 'Levistica', 'identifier': 'dev.fomalhaut16.Levistica'}
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            guard.check_snapshot(f'43 {path}\n', self.root, lambda *_: identity, 501)


    def test_build_preflight_refuses_installed_release_even_without_variant_filter(self):
        path = str(pathlib.Path.home() / 'Applications/Levistica.app/Contents/MacOS/Levistica')
        identity = {'path': path, 'uid': 501, 'name': 'Levistica', 'identifier': 'dev.fomalhaut16.Levistica'}
        with self.assertRaisesRegex(ValueError, 'close it before rebuilding'):
            guard.check_snapshot(f'43 {path}\n', self.root, lambda *_: identity, 501, reject_installed=True)


if __name__ == '__main__':
    unittest.main()
