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
