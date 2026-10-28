import hashlib
import json
import shutil
import importlib.util
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('archive_startup', pathlib.Path(__file__).parents[1]/'verify-archive-startup.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class ArchiveStartupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name).resolve()
        self.addCleanup(patch.stopall)
        patch.object(s, 'ROOT', self.root).start()
        patch.object(s.bundle_rehearsal, 'ROOT', self.root).start()
        patch.object(s.screen, 'query_state', return_value={'screenState': 'unlocked'}).start()
        self.archive = self.root/'.local/archives/local-abcdefgh/Levistica.xcarchive'
        self.app = self.archive/'Products/Applications/Levistica.app'
        self.executable = self.app/'Contents/MacOS/Levistica'
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b'synthetic executable only')
        (self.app/'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'dev.fomalhaut16.Levistica',
            'CFBundleExecutable': 'Levistica',
            'LevisticaSourceState': 'clean', 'LevisticaSourceRevision': 'a'*40}))
        (self.root/'Levistica').mkdir()
        (self.root/'Levistica/Levistica.entitlements').write_bytes(plistlib.dumps({'sandbox': True}))
        self.process = {'pid': 123456, 'path': str(self.executable), 'started': 'fixture start',
                        'uid': os.getuid(), 'ephemeral': True}
        self.commands = []

    def run_command(self, command):
        self.commands.append(command)
        if 'rev-parse' in command:return b'b'*40
        if '--porcelain' in command:return b''
        return plistlib.dumps({'sandbox': True}) if '--entitlements' in command else b''

    def evidence(self):
        return __import__('json').loads(next((self.root/'.local/artifacts').glob('archive-startup.*/result.json')).read_text())

    def test_candidates_include_renamed_bundles_without_matching_bare_process_names(self):
        rows = b"""101 /Applications/Levistica.app/Contents/MacOS/Levistica
102 /Applications/Levistica Previous.app/Contents/MacOS/Levistica
103 /private/tmp/Installed.app/Contents/MacOS/Levistica
104 /usr/local/bin/Levistica
105 /Applications/Other.app/Contents/MacOS/Other
106 /Applications/Other.app/Contents/MacOS/Levistica Helper
"""
        with patch.object(s, 'run', return_value=rows):
            self.assertEqual(s.candidates(), [
                (101, '/Applications/Levistica.app/Contents/MacOS/Levistica'),
                (102, '/Applications/Levistica Previous.app/Contents/MacOS/Levistica'),
                (103, '/private/tmp/Installed.app/Contents/MacOS/Levistica')])

    def test_renamed_app_blocks_launch_without_identity_lookup_or_signal(self):
        def command(arguments):
            if arguments == ['/bin/ps', '-axo', 'pid=,comm=']:
                return b'777 /Applications/Levistica Previous.app/Contents/MacOS/Levistica\n'
            return self.run_command(arguments)
        with patch.object(s, 'run', side_effect=command), patch.object(s, 'identity') as identify, patch.object(s.os, 'kill') as kill:
            result = s.verify(self.archive)
        self.assertFalse(result['success'])
        self.assertFalse(any(arguments[0] == '/usr/bin/open' for arguments in self.commands))
        identify.assert_not_called()
        kill.assert_not_called()

    def test_success_launches_only_requested_archive_and_stops_only_verified_process(self):
        with patch.object(s, 'run', side_effect=self.run_command), patch.object(s, 'candidates', side_effect=[[], [(123456,str(self.executable))], [(123456,str(self.executable))]]), patch.object(s, 'identity', return_value=self.process), patch.object(s, 'stop_owned') as stop, patch.object(s.time, 'sleep'):
            result = s.verify(self.archive)
        self.assertTrue(result['success'])
        self.assertFalse(result['guiVerified'])
        self.assertFalse(result['profileMigrationTested'])
        stop.assert_called_once_with(self.process, self.executable)
        self.assertIn(['/usr/bin/open','-n','--env','LEVISTICA_EPHEMERAL=1',str(self.app)],self.commands)

    def test_existing_normal_app_blocks_open_and_is_never_signalled(self):
        with patch.object(s,'run',side_effect=self.run_command), patch.object(s,'candidates',return_value=[(7,'/normal/Levistica.app/Contents/MacOS/Levistica')]), patch.object(s,'stop_owned') as stop:
            self.assertFalse(s.verify(self.archive)['success'])
        self.assertFalse(any(command[0]=='/usr/bin/open' for command in self.commands))
        stop.assert_not_called()

    def test_wrong_path_or_missing_isolation_after_open_is_never_signalled(self):
        for path, ephemeral in [('/other/Levistica.app/Contents/MacOS/Levistica',True),(str(self.executable),False)]:
            process = dict(self.process, path=path, ephemeral=ephemeral)
            with self.subTest(path=path,ephemeral=ephemeral), patch.object(s,'run',side_effect=self.run_command), patch.object(s,'candidates',side_effect=[[],[(123456,path)]]), patch.object(s,'identity',return_value=process), patch.object(s,'stop_owned') as stop:
                self.assertFalse(s.verify(self.archive)['success'])
                stop.assert_not_called()

    def test_invalid_signature_blocks_launch(self):
        with patch.object(s,'run',side_effect=subprocess.CalledProcessError(1,['codesign'])), patch.object(s,'candidates') as listing:
            with self.assertRaises(subprocess.CalledProcessError):s.verify(self.archive)
            listing.assert_not_called()

    def test_external_and_symlink_archive_inputs_are_rejected(self):
        with self.assertRaises(ValueError):s.archive_bundle('/Applications/Levistica.app')
        linked = self.archive.parent.parent/'local-linkedxx'
        linked.symlink_to(self.archive.parent,target_is_directory=True)
        with self.assertRaises(ValueError):s.archive_bundle(linked/'Levistica.xcarchive')
        with self.assertRaises(ValueError):s.archive_bundle(self.archive/'..'/'Levistica.xcarchive')

    def test_changed_pid_identity_prevents_signal(self):
        with patch.object(s,'identity',return_value=dict(self.process,started='replacement')), patch.object(s.os,'kill') as kill:
            with self.assertRaises(ValueError):s.stop_owned(self.process,self.executable)
            kill.assert_not_called()

    def test_shutdown_uses_term_only_then_confirms_exit(self):
        with patch.object(s,'identity',return_value=self.process), patch.object(s,'candidates',return_value=[]), patch.object(s.os,'kill') as kill:
            s.stop_owned(self.process,self.executable)
            kill.assert_called_once_with(123456,s.signal.SIGTERM)

    def test_cleanup_failure_prevents_success_and_preserves_evidence(self):
        with patch.object(s,'run',side_effect=self.run_command), patch.object(s,'candidates',side_effect=[[],[(123456,str(self.executable))],[(123456,str(self.executable))]]), patch.object(s,'identity',return_value=self.process), patch.object(s,'stop_owned',side_effect=ValueError('private information must not be logged')), patch.object(s.time,'sleep'):
            self.assertFalse(s.verify(self.archive)['success'])
        result = self.evidence()
        self.assertTrue(result['manualInspectionRequired'])
        self.assertNotIn('private information', str(result))


    def make_package(self):
        folder = self.root / '.local/packages/local-abcdefgh'
        app = folder / 'unpacked/Levistica.app'
        shutil.copytree(self.app, app)
        info_path = app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['CFBundleShortVersionString'] = '0.1.0'
        info_path.write_bytes(plistlib.dumps(info))
        name = 'Levistica-0.1.0-local-aaaaaaa.zip'
        (folder / name).write_bytes(b'synthetic zip checksum fixture')
        data = {'success': True, 'scope': 'local-validation', 'roundtripVerified': True,
                'signatureVerified': True, 'sandbox': True, 'hardenedRuntime': True,
                'source': 'a'*40, 'version': '0.1.0', 'zipFile': name,
                'zipSHA256': hashlib.sha256((folder / name).read_bytes()).hexdigest(),
                'bundleTreeSHA256': s.bundle_rehearsal.tree_digest(app)}
        (folder / 'manifest.json').write_text(json.dumps(data))
        return folder, app, data

    def test_verified_package_uses_shared_ephemeral_start_and_exact_cleanup(self):
        folder, app, _ = self.make_package()
        exe = app / 'Contents/MacOS/Levistica'
        process = dict(self.process, path=str(exe))
        with patch.object(s, 'run', side_effect=self.run_command), \
             patch.object(s, 'candidates', side_effect=[[], [(123456, str(exe))], [(123456, str(exe))]]), \
             patch.object(s, 'identity', return_value=process), \
             patch.object(s, 'stop_owned') as stop, patch.object(s.time, 'sleep'):
            result = s.verify(folder, package=True)
        self.assertTrue(result['success'])
        self.assertEqual(result['artifactKind'], 'package')
        self.assertFalse(result['guiVerified'])
        self.assertIn(['/usr/bin/open', '-n', '--env', 'LEVISTICA_EPHEMERAL=1', str(app)], self.commands)
        stop.assert_called_once_with(process, exe)

    def test_changed_zip_blocks_package_launch(self):
        folder, _, data = self.make_package()
        (folder / data['zipFile']).write_bytes(b'changed')
        with patch.object(s, 'run') as run:
            with self.assertRaises(ValueError): s.verify(folder, package=True)
            run.assert_not_called()

    def test_changed_extracted_app_blocks_package_launch(self):
        folder, app, _ = self.make_package()
        (app / 'Contents/MacOS/Levistica').write_bytes(b'changed')
        with patch.object(s, 'run') as run:
            with self.assertRaises(ValueError): s.verify(folder, package=True)
            run.assert_not_called()

    def test_manifest_identity_must_match_extracted_app(self):
        folder, _, data = self.make_package()
        data['source'] = 'b'*40
        name = 'Levistica-0.1.0-local-bbbbbbb.zip'
        (folder / data['zipFile']).rename(folder / name)
        data['zipFile'] = name
        (folder / 'manifest.json').write_text(json.dumps(data))
        with self.assertRaises(ValueError): s.package_bundle(folder)

    def test_incomplete_or_non_boolean_manifest_is_rejected(self):
        folder, _, data = self.make_package()
        for value in [False, 1, 'true', None]:
            data['success'] = value
            (folder / 'manifest.json').write_text(json.dumps(data))
            with self.subTest(value=value), self.assertRaises(ValueError): s.package_bundle(folder)

    def test_linked_package_parent_and_manifest_are_rejected(self):
        folder, _, _ = self.make_package()
        manifest = folder / 'manifest.json'
        external = self.root / 'other-manifest'
        manifest.rename(external)
        manifest.symlink_to(external)
        with self.assertRaises(ValueError): s.package_bundle(folder)
        linked = self.root / '.local/packages/local-linkedxx'
        linked.symlink_to(folder, target_is_directory=True)
        with self.assertRaises(ValueError): s.package_bundle(linked)

    def test_manifest_cannot_choose_an_external_zip_filename(self):
        folder, _, data = self.make_package()
        data['zipFile'] = '../../../outside.zip'
        (folder / 'manifest.json').write_text(json.dumps(data))
        with self.assertRaises(ValueError): s.package_bundle(folder)

    def test_linked_unpacked_directory_is_rejected(self):
        folder, _, _ = self.make_package()
        external = self.root / 'other-unpacked'
        (folder / 'unpacked').rename(external)
        (folder / 'unpacked').symlink_to(external, target_is_directory=True)
        with self.assertRaises(ValueError): s.package_bundle(folder)

    def test_locked_or_unknown_screen_blocks_open_without_stopping_apps(self):
        for state in ['locked', 'unknown']:
            with self.subTest(state=state), patch.object(s.screen, 'query_state', return_value={'screenState': state}), \
                 patch.object(s, 'run', side_effect=self.run_command), patch.object(s, 'candidates') as listing, \
                 patch.object(s, 'stop_owned') as stop:
                self.commands.clear()
                result = s.verify(self.archive)
                self.assertFalse(result['success'])
                self.assertEqual(result['screenStateBeforeLaunch'], state)
                self.assertFalse(any(command[0] == '/usr/bin/open' for command in self.commands))
                listing.assert_not_called()
                stop.assert_not_called()
