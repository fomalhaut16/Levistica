import importlib.util
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('measure_updater_test', pathlib.Path(__file__).parents[1] / 'measure-memory.py')
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


class ChromeUpdaterIdentityTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.home = pathlib.Path(self.folder.name)
        self.app = self.home / 'Chrome.app'
        self.path = self.home / 'Library/Application Support/Google/GoogleUpdater/157.0.8089.0/GoogleUpdater.app/Contents/MacOS/GoogleUpdater'
        self.path.parent.mkdir(parents=True)
        self.path.write_bytes(b'synthetic signed-code fixture')
        self.bundle = self.path.parents[2]
        self.info = self.bundle / 'Contents/Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.google.GoogleUpdater', 'CFBundleExecutable': 'GoogleUpdater'}))
        self.home_patch = patch.object(pathlib.Path, 'home', return_value=self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)
        self.metadata = [{'Identifier': 'com.google.Chrome', 'TeamIdentifier': 'GOOGLETEAM'},
                         {'Identifier': 'com.google.GoogleUpdater', 'TeamIdentifier': 'GOOGLETEAM'}]

    def test_only_the_exact_per_user_signed_updater_is_accepted(self):
        query = Mock(return_value='')
        with patch.object(measure, 'signing_metadata', side_effect=self.metadata):
            result = measure.chrome_updater_identity(self.path, self.app, query)
        self.assertEqual(result['role'], 'Chrome-started updater')
        self.assertEqual(result['codeFileStamp'], measure.code_file_stamp(self.path))
        self.assertEqual([call.args[0][-1] for call in query.call_args_list], [str(self.app / 'Contents/MacOS/Google Chrome'), str(self.bundle)])
        self.assertTrue(all(call.args[0][-3:-1] == ['-R', '=anchor apple generic'] for call in query.call_args_list))
        self.assertIn('--ignore-resources', query.call_args_list[0].args[0])
        self.assertNotIn('--ignore-resources', query.call_args_list[1].args[0])
        self.assertIn('--strict', query.call_args_list[1].args[0])

    def test_similar_names_or_locations_are_not_signature_candidates(self):
        for candidate in [self.home / 'GoogleUpdater', self.path.with_name('OtherUpdater'),
                          self.home / 'Library/Application Support/Google/GoogleUpdaterElse/157.0.8089.0/GoogleUpdater.app/Contents/MacOS/GoogleUpdater',
                          self.home / 'Library/Application Support/Google/GoogleUpdater/not-a-version/GoogleUpdater.app/Contents/MacOS/GoogleUpdater']:
            with self.subTest(candidate=candidate), patch.object(measure, 'signing_metadata') as signing:
                query = Mock()
                self.assertIsNone(measure.chrome_updater_identity(candidate, self.app, query))
                query.assert_not_called()
                signing.assert_not_called()

    def test_an_invalid_signature_aborts_instead_of_including_the_pid(self):
        query = Mock(side_effect=subprocess.CalledProcessError(1, 'codesign', stderr='private path'))
        with self.assertRaises(subprocess.CalledProcessError), patch.object(measure, 'signing_metadata') as signing:
            measure.chrome_updater_identity(self.path, self.app, query)
        signing.assert_not_called()

    def test_another_team_or_signing_identifier_is_rejected(self):
        for changed in [{'TeamIdentifier': 'OTHERTEAM'}, {'Identifier': 'com.google.other'}]:
            with self.subTest(changed=changed), patch.object(measure, 'signing_metadata', side_effect=[self.metadata[0], {**self.metadata[1], **changed}]):
                with self.assertRaisesRegex(ValueError, 'signing identity changed'):
                    measure.chrome_updater_identity(self.path, self.app, Mock(return_value=''))

    def test_changed_bundle_identity_and_linked_payload_are_rejected(self):
        self.info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'not.google', 'CFBundleExecutable': 'GoogleUpdater'}))
        query = Mock()
        with self.assertRaisesRegex(ValueError, 'bundle identity changed'):
            measure.chrome_updater_identity(self.path, self.app, query)
        query.assert_not_called()
        actual = self.path.with_name('real-payload')
        self.path.rename(actual)
        self.path.symlink_to(actual.name)
        self.assertIsNone(measure.chrome_updater_identity(self.path, self.app, query))
        query.assert_not_called()

    def test_payload_change_during_signing_does_not_pass(self):
        def changed(_):
            self.path.write_bytes(b'changed payload with a different length')
            return ''
        with patch.object(measure, 'signing_metadata', side_effect=self.metadata):
            with self.assertRaisesRegex(ValueError, 'payload changed'):
                measure.chrome_updater_identity(self.path, self.app, changed)

    def test_signing_metadata_discards_paths_and_rejects_incomplete_output(self):
        for text, valid in [('private path\nIdentifier=com.google.Chrome\nTeamIdentifier=GOOGLETEAM\n', True),
                            ('Identifier=com.google.Chrome\nTeamIdentifier=not set\n', False)]:
            with patch.object(measure.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', text)):
                if valid:
                    self.assertEqual(measure.signing_metadata(self.app), self.metadata[0])
                else:
                    with self.assertRaises(ValueError):
                        measure.signing_metadata(self.app)

    def test_snapshot_requires_owned_ancestry_uid_and_retains_the_verified_file_stamp(self):
        app = pathlib.Path('/synthetic/Chrome.app')
        paths = {100: str(app / 'Contents/MacOS/Chrome'), 200: str(app / 'Contents/Renderer'), 300: str(self.path)}
        domain = 'pid/100 = {\n\toriginator = /synthetic/Chrome.app\n\tcreator = Google Chrome[100]\n\tservices = {\n\t}\n}'
        stamp = measure.code_file_stamp(self.path)
        for same_user in [True, False]:
            def query(args):
                if args[0] == '/bin/launchctl':return domain
                if '-axo' in args:return '100 1 S Chrome\n200 100 S Renderer\n300 100 S Updater\n'
                selected = [int(x) for x in args[args.index('-p')+1].split(',')]
                if args[-1]=='args=':return '--user-data-dir=/synthetic/profile'
                if args[-1]=='uid=':return str(measure.os.getuid() if same_user else measure.os.getuid()+1)
                return ''.join(f'{pid} Tue Oct 27 10:00:00 2026\n' for pid in selected)
            with self.subTest(same_user=same_user), patch.object(measure, 'run', side_effect=query), \
                 patch.object(measure, 'process_executable_path', side_effect=paths.__getitem__), \
                 patch.object(measure, 'chrome_updater_identity', return_value={'role':'Chrome-started updater','codeFileStamp':stamp}) as verified:
                if same_user:
                    result = measure.snapshot(100, app, pathlib.Path(paths[100]), pathlib.Path('/synthetic/profile'))
                    self.assertEqual(set(result['identities']), {100,200,300})
                    self.assertEqual(result['identities'][300]['codeFileStamp'], stamp)
                    self.assertEqual(result['chrome_external_roles'], {300:'Chrome-started updater'})
                    verified.assert_called_once_with(pathlib.Path(paths[300]), app, unittest.mock.ANY, None)
                else:
                    with self.assertRaisesRegex(ValueError, 'another user'):
                        measure.snapshot(100, app, pathlib.Path(paths[100]), pathlib.Path('/synthetic/profile'))
