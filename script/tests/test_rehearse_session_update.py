"""Generated metadata and stubbed launches only; never use user profiles."""
import importlib.util
import json
import os
import pathlib
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('session_update_test', ROOT / 'script/rehearse-session-update.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class SessionUpdateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name).resolve()
        self.addCleanup(patch.stopall)
        patch.object(s, 'ROOT', self.root).start()
        (self.root / '.local/artifacts').mkdir(parents=True)
        self.baseline = self.root / '.local/session-update-baselines' / ('a' * 40) / 'Levistica.app'
        self.baseline.mkdir(parents=True)
        self.trial = s.Trial(self.baseline)

    def data(self):
        folder = self.root / 'generated-metadata'
        folder.mkdir(mode=0o700)
        (folder / 'session.sqlite3').write_bytes(b'synthetic')
        return folder

    def test_baseline_path_rejects_other_projects_links_and_traversal(self):
        for path in [self.root / 'Levistica.app', self.baseline / '..' / 'Levistica.app']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                s.baseline_path(path)
        linked = self.baseline.parent.parent / ('b' * 40)
        linked.symlink_to(self.baseline.parent, target_is_directory=True)
        with self.assertRaises(ValueError):
            s.baseline_path(linked / 'Levistica.app')

    def test_metadata_digest_rejects_links_unknown_files_and_sqlite_sidecars(self):
        folder = self.data()
        for name in ['history.sqlite3', 'session.sqlite3-wal', 'session.sqlite3-journal']:
            path = folder / name
            path.write_bytes(b'generated')
            with self.subTest(name=name), self.assertRaises(ValueError):
                s.metadata_digest(folder, self.trial.deadline)
            path.unlink()
        (folder / 'browser-preferences.json').symlink_to(folder / 'session.sqlite3')
        with self.assertRaises(ValueError):
            s.metadata_digest(folder, self.trial.deadline)

    def test_metadata_digest_rejects_oversized_fixtures_and_detects_changes(self):
        folder = self.data()
        first = s.metadata_digest(folder, self.trial.deadline)
        (folder / 'session.sqlite3').write_bytes(b'changed synthetic')
        self.assertNotEqual(s.metadata_digest(folder, self.trial.deadline), first)
        (folder / 'session.sqlite3').write_bytes(bytes(1024 * 1024 + 1))
        with self.assertRaises(ValueError):
            s.metadata_digest(folder, self.trial.deadline)

    def test_source_mutation_during_copy_is_rejected(self):
        folder = self.data()
        original = shutil.copytree
        def copy(source, target):
            original(source, target)
            (source / 'session.sqlite3').write_bytes(b'changed during snapshot')
        with patch.object(s.shutil, 'copytree', side_effect=copy), self.assertRaises(ValueError):
            self.trial.copy(folder, self.root / 'snapshot')

    def test_existing_app_blocks_inspection_allocation_and_launch(self):
        with patch.object(s.sys, 'platform', 'darwin'), patch.object(self.trial, 'apps', return_value=[(8, '/renamed.app/Contents/MacOS/Levistica')]), patch.object(self.trial, 'inspect') as inspect, patch.object(s.stores, 'allocate') as allocate, patch.object(s.os, 'kill') as kill:
            with self.assertRaises(ValueError):
                self.trial.execute()
            inspect.assert_not_called()
            allocate.assert_not_called()
            kill.assert_not_called()

    def test_normal_bundle_identity_is_rejected_even_with_valid_signature(self):
        (self.root / 'Levistica').mkdir()
        (self.root / 'Levistica/Levistica.entitlements').write_bytes(plistlib.dumps({'sandbox': True}))
        (self.baseline / 'Contents').mkdir()
        (self.baseline / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'dev.fomalhaut16.Levistica', 'CFBundleExecutable': 'Levistica',
            'LevisticaSourceRevision': 'a' * 40, 'LevisticaSourceState': 'clean'}))
        with patch.object(self.trial, 'run', return_value=b''), self.assertRaises(ValueError):
            self.trial.inspect(self.baseline)

    def test_changed_identity_is_never_signalled(self):
        value = {'pid': 123456, 'path': 'synthetic', 'started': 'original', 'uid': os.getuid()}
        self.trial.active = (self.baseline, value)
        with patch.object(self.trial, 'identity', return_value=dict(value, started='replacement')), patch.object(s.os, 'kill') as kill:
            with self.assertRaises(ValueError):
                self.trial.stop()
            kill.assert_not_called()

    def test_missing_isolation_flags_are_rejected(self):
        self.trial.store_id = 'synthetic store'
        path = str(self.baseline / 'Contents/MacOS/Levistica')
        def command(args):
            return (str(os.getuid()) if args[-1] == 'uid=' else 'fixture start' if args[-1] == 'lstart=' else path).encode()
        with patch.object(self.trial, 'owned'), patch.object(self.trial, 'run', side_effect=command), patch.object(self.trial, 'apps', return_value=[(3, path)]), patch.object(s.stores, 'runtime_flags', return_value={}), self.assertRaises(ValueError):
            self.trial.identity(3, self.baseline)

    def test_each_start_requires_a_new_app_commit_before_metadata_is_ready(self):
        trial = self.trial
        home = self.root / 'synthetic-home'
        trial.store_id = 'generated-uuid'
        folder = home / 'Library/Containers' / s.BUNDLE_ID / 'Data/Library/Application Support/LevisticaMeasurementProfiles' / trial.store_id
        folder.mkdir(parents=True)
        trial.metadata_folder = folder
        with sqlite3.connect(folder / 'session.sqlite3') as db:
            db.execute('CREATE TABLE session_tabs (id TEXT,position INTEGER,title TEXT,url TEXT,may_reload INTEGER,kind TEXT,is_kept INTEGER,is_sleeping INTEGER)')
            db.execute('CREATE TABLE session_meta (id INTEGER,selected_id TEXT,was_running INTEGER)')
            db.execute("INSERT INTO session_tabs VALUES ('generated',0,'Generated',NULL,0,'web',0,0)")
            db.execute("INSERT INTO session_meta VALUES (1,'generated',1)")
            db.execute('PRAGMA user_version=3')
        trial.active = (self.baseline, {'pid': 3})
        calls = []
        def listing(args):
            calls.append(args)
            if len(calls) == 2:
                with sqlite3.connect(folder / 'session.sqlite3') as db:
                    db.execute('UPDATE session_meta SET was_running=1')
            return ('n' + str(folder / 'session.sqlite3') + '\n').encode()
        with patch.object(s.pathlib.Path, 'home', return_value=home), patch.object(trial, 'owned'), patch.object(trial, 'apps', return_value=[]), patch.object(trial, 'identity'), patch.object(trial, 'run', side_effect=listing), patch.object(s.time, 'sleep'):
            trial.arm_startup()
            self.assertEqual(s.read_session(folder / 'session.sqlite3')[1], ('generated', 0))
            self.assertEqual(trial.folder(3), folder)
        self.assertEqual(len(calls), 2)
        self.assertEqual(s.read_session(folder / 'session.sqlite3')[1], ('generated', 1))

    def test_timeout_rejects_commands_and_cleanup_keeps_unknown_process(self):
        self.trial.deadline = time.monotonic() - 1
        with patch.object(s.subprocess, 'check_output') as command, self.assertRaises(TimeoutError):
            self.trial.run(['synthetic command'])
        command.assert_not_called()
        with patch.object(self.trial, 'apps', return_value=[(3, 'unknown')]), patch.object(s.os, 'kill') as kill:
            self.trial.finish()
        self.assertFalse(self.trial.result['success'])
        self.assertTrue(self.trial.result['manualInspectionRequired'])
        kill.assert_not_called()

    def launch_fixture(self):
        executable = self.baseline / 'Contents/MacOS/Levistica'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'synthetic executable; never executed')
        self.trial.store_id = 'generated-owned-uuid'
        child = Mock(pid=3)
        child.poll.return_value = None
        value = {'pid':3,'path':str(executable),'started':'original','uid':os.getuid()}
        return executable, child, value

    def test_start_uses_verified_executable_exact_child_and_filtered_environment(self):
        executable, child, value = self.launch_fixture()
        inherited = {'SAFE':'synthetic','LEVISTICA_EPHEMERAL':'0',s.stores.STORE_KEY:'unowned',
                     s.stores.REQUEST_KEY:'cleanup','LEVISTICA_MALLOC_STACKS':'1','LEVISTICA_SESSION_TEST_ID':'unrelated'}
        with patch.dict(s.os.environ,inherited,clear=True), patch.object(self.trial,'apps',side_effect=[[],[(3,str(executable))]]), patch.object(self.trial,'owned'), patch.object(self.trial,'inspect',return_value={'source':'verified'}), patch.object(self.trial,'arm_startup'), patch.object(self.trial,'identity',return_value=value) as identity, patch.object(s.subprocess,'Popen',return_value=child) as launch:
            self.assertEqual(self.trial.start(self.baseline,{'source':'verified'}),3)
        args, kwargs = launch.call_args
        self.assertEqual(args,([str(executable)],))
        self.assertEqual(kwargs['env'],{'SAFE':'synthetic','LEVISTICA_EPHEMERAL':'1',s.stores.STORE_KEY:'generated-owned-uuid',s.stores.METADATA_KEY:'1'})
        self.assertEqual(kwargs['stdout'],s.subprocess.DEVNULL)
        self.assertEqual(kwargs['stderr'],s.subprocess.DEVNULL)
        identity.assert_called_once_with(3,self.baseline,exclusive=False)
        self.assertEqual(self.trial.result['requestedPIDs'],[3])

    def test_foreign_inventory_pid_is_not_adopted_and_only_child_is_cleaned(self):
        executable, child, value = self.launch_fixture()
        foreign=(99,'/foreign/Levistica.app/Contents/MacOS/Levistica')
        def stopped(pid, signal):
            self.assertEqual(pid,3)
            child.poll.return_value=0
        with patch.object(self.trial,'apps',side_effect=[[],[foreign],[foreign]]), patch.object(self.trial,'owned'), patch.object(self.trial,'inspect',return_value={'source':'verified'}), patch.object(self.trial,'arm_startup'), patch.object(self.trial,'identity',return_value=value) as identity, patch.object(s.subprocess,'Popen',return_value=child), patch.object(s.os,'kill',side_effect=stopped) as kill:
            with self.assertRaises(ValueError):self.trial.start(self.baseline,{'source':'verified'})
            self.trial.finish()
        self.assertEqual(identity.call_args_list[0].args[0],3)
        kill.assert_called_once_with(3,s.signal.SIGTERM)
        self.assertEqual(self.trial.result['remainingAppCount'],1)
        self.assertTrue(self.trial.result['manualInspectionRequired'])

    def test_early_child_exit_and_expired_launch_do_not_adopt_another_process(self):
        executable, child, value=self.launch_fixture()
        child.poll.return_value=1
        with patch.object(self.trial,'apps',return_value=[]), patch.object(self.trial,'owned'), patch.object(self.trial,'inspect',return_value={}), patch.object(self.trial,'arm_startup'), patch.object(self.trial,'identity') as identity, patch.object(s.subprocess,'Popen',return_value=child), self.assertRaises(ValueError):
            self.trial.start(self.baseline,{})
        identity.assert_not_called()
        self.trial.deadline=s.time.monotonic()-1
        with patch.object(self.trial,'apps',return_value=[]), patch.object(self.trial,'owned'), patch.object(self.trial,'inspect',return_value={}), patch.object(self.trial,'arm_startup') as arm, patch.object(s.subprocess,'Popen') as launch, self.assertRaises(TimeoutError):
            self.trial.start(self.baseline,{})
        launch.assert_not_called();arm.assert_not_called()

    def test_interrupted_startup_can_clean_its_verified_child_after_main_deadline(self):
        executable, child, value=self.launch_fixture()
        self.trial.launcher=child;self.trial.launch_app=self.baseline
        self.trial.deadline=s.time.monotonic()-1
        def stopped(pid, signal):child.poll.return_value=0
        with patch.object(self.trial,'identity',return_value=value), patch.object(s.os,'kill',side_effect=stopped) as kill, patch.object(self.trial,'apps',return_value=[]):self.trial.finish()
        kill.assert_called_once_with(3,s.signal.SIGTERM)
        self.assertEqual(self.trial.result['remainingAppCount'],0)
        self.assertIsNone(self.trial.active)

    def test_shutdown_polls_original_child_when_exit_metadata_disappears(self):
        executable, child, value=self.launch_fixture()
        self.trial.launcher=child;self.trial.launch_app=self.baseline
        self.trial.active=(self.baseline,value)
        child.poll.side_effect=[None,None,None,0]
        with patch.object(self.trial,'identity',side_effect=[value,ValueError('exiting metadata')]) as identity, patch.object(s.os,'kill') as kill, patch.object(s.time,'sleep'):
            self.trial.stop()
        identity.assert_called_once_with(3,self.baseline,exclusive=False)
        kill.assert_called_once_with(3,s.signal.SIGTERM)
        self.assertIsNone(self.trial.active)

    def test_changed_requested_child_or_bundle_is_never_adopted(self):
        executable, child, value=self.launch_fixture()
        with patch.object(self.trial,'apps',side_effect=[[],[(3,str(executable))]]), patch.object(self.trial,'owned'), patch.object(self.trial,'inspect',side_effect=[{}, {'changed':True}]), patch.object(self.trial,'arm_startup'), patch.object(self.trial,'identity',return_value=value), patch.object(s.subprocess,'Popen',return_value=child), self.assertRaises(ValueError):
            self.trial.start(self.baseline,{})
        self.trial.active=None
        with patch.object(self.trial,'identity',return_value=dict(value,pid=99)), patch.object(s.os,'kill') as kill, self.assertRaises(ValueError):self.trial.stop()
        kill.assert_not_called()

    def test_generated_pair_is_restored_with_the_old_revision_and_newer_data_retained(self):
        self.exercise_pair()

    def test_recovery_pointer_database_and_backup_return_together(self):
        self.exercise_pair(recovered=True)

    def test_failed_recovered_pair_restore_does_not_launch_the_old_app(self):
        self.exercise_pair(fail_data_exchange=True, recovered=True)

    def test_failed_data_exchange_retains_newer_data_and_does_not_launch_old_revision(self):
        self.exercise_pair(fail_data_exchange=True)

    def exercise_pair(self, fail_data_exchange=False, recovered=False):
        trial = self.trial
        trial.recovered = recovered
        (self.baseline / 'generated-revision').write_text('a' * 40)
        trial.new.mkdir(parents=True)
        (trial.new / 'generated-revision').write_text('b' * 40)
        def inspect(app):
            return {'source': (app / 'generated-revision').read_text(),
                    'treeSHA256': s.bundles.tree_digest(app, trial.deadline)}
        folder = self.root / 'owned-generated-metadata'
        folder.mkdir(mode=0o700)
        with sqlite3.connect(folder / 'session.sqlite3') as db:
            db.execute('CREATE TABLE session_tabs (id TEXT,position INTEGER,title TEXT,url TEXT,may_reload INTEGER,kind TEXT,is_kept INTEGER,is_sleeping INTEGER)')
            db.execute('CREATE TABLE session_meta (id INTEGER,selected_id TEXT,was_running INTEGER)')
            db.execute("INSERT INTO session_tabs VALUES ('initial',0,'Blank',NULL,0,'web',0,0)")
            db.execute("INSERT INTO session_meta VALUES (1,'initial',1)")
            db.execute('PRAGMA user_version=3')
        marker = self.root / 'generated-marker.json'
        marker.write_text('{"generated":true}')
        starts = []
        def start(app, expected):
            starts.append(expected['source'])
            with sqlite3.connect(s.session_file(folder)) as db:
                db.execute('UPDATE session_meta SET was_running=1')
            return 123456
        def command(args):
            if args[0] == '/usr/bin/ditto':
                shutil.copytree(args[1], args[2])
                return b''
            return b'/dev/generated /fixture\n' if args[0] == '/bin/df' else plistlib.dumps({'FilesystemType': 'apfs'})
        def exchange(a, b):
            temporary = a.with_name('test-exchange-slot')
            a.rename(temporary); b.rename(a); temporary.rename(b)
        original = s.bundles.checked_exchange
        def checked(a, b, old, new, inspect, deadline):
            if fail_data_exchange and a == folder:
                raise OSError('Synthetic data-exchange failure')
            return original(a, b, old, new, inspect, exchange=exchange, deadline=deadline)
        with patch.object(s.sys, 'platform', 'darwin'), patch.object(trial, 'apps', return_value=[]), patch.object(trial, 'run', side_effect=command), patch.object(trial, 'inspect', side_effect=inspect), patch.object(s.stores, 'allocate', return_value='generated-uuid'), patch.object(s.stores, 'owned', return_value=({}, marker)), patch.object(trial, 'owned'), patch.object(trial, 'start', side_effect=start), patch.object(trial, 'stop'), patch.object(trial, 'folder', return_value=folder), patch.object(s.bundles, 'checked_exchange', side_effect=checked):
            if fail_data_exchange:
                with self.assertRaises(OSError):
                    trial.execute()
                self.assertFalse(trial.result['success'])
                self.assertEqual(starts, ['a' * 40, 'a' * 40, 'b' * 40, 'b' * 40])
                rows, _ = s.read_session(s.session_file(folder))
                self.assertEqual([r[2] for r in rows], ['Synthetic newer 0', 'Synthetic newer 1'])
                self.assertTrue(s.session_file(trial.work / 'BaselineData').exists())
                self.assertTrue(s.session_file(trial.work / 'NewerData').exists())
                return
            trial.execute()
        self.assertTrue(trial.result['success'])
        self.assertEqual(starts, ['a' * 40, 'a' * 40, 'b' * 40, 'b' * 40, 'a' * 40])
        rows, _ = s.read_session(s.session_file(folder))
        self.assertEqual([r[2] for r in rows], ['Synthetic baseline 0', 'Synthetic baseline 1'])
        newer, _ = s.read_session(s.session_file(trial.work / 'NewerData'))
        self.assertEqual([r[2] for r in newer], ['Synthetic newer 0', 'Synthetic newer 1'])
        self.assertEqual(json.loads((folder / 'browser-preferences.json').read_bytes()), {'version': 1, 'newTabURL': None})
        self.assertEqual(json.loads((trial.work / 'NewerData/browser-preferences.json').read_bytes())['searchEngine'], 'google')
        if recovered:
            old_name = s.session_file(trial.work / 'BaselineData').name
            new_name = s.session_file(trial.work / 'NewerData').name
            self.assertNotEqual(old_name, new_name)
            self.assertEqual(s.session_file(folder).name, old_name)
            self.assertEqual(s.read_session(folder / (old_name + '.backup'))[1][1], 0)

    def test_pointer_rejects_unsupported_values_links_missing_targets_and_paths(self):
        folder = self.data()
        pointer = folder / 'current-session.json'
        name = 'recovered-session-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.sqlite3'
        target = folder / name
        target.write_bytes(b'generated recovery database')
        pointer.write_text(json.dumps({'version': 1, 'fileName': name}))
        self.assertEqual(s.session_file(folder), target)
        for value in [{'version': 2, 'fileName': name}, {'version': True, 'fileName': name},
                      {'version': 1, 'fileName': '../outside.sqlite3'}, {'version': 1, 'fileName': name, 'extra': 1}, []]:
            pointer.write_text(json.dumps(value))
            with self.subTest(value=value), self.assertRaises(ValueError):
                s.session_file(folder)
        pointer.write_text(json.dumps({'version': 1, 'fileName': name}))
        target.unlink()
        with self.assertRaises(ValueError):s.session_file(folder)
        target.symlink_to(folder / 'session.sqlite3')
        with self.assertRaises(ValueError):s.session_file(folder)
        pointer.unlink()
        pointer.symlink_to(folder / 'session.sqlite3')
        with self.assertRaises(ValueError):s.session_file(folder)

    def test_snapshot_rejects_an_unselected_recovery_database(self):
        folder = self.data()
        name = 'recovered-session-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.sqlite3'
        (folder / name).write_bytes(b'generated')
        (folder / 'current-session.json').write_text(json.dumps({'version': 1, 'fileName': name}))
        (folder / (name + '.backup')).write_bytes(b'generated backup')
        s.metadata_digest(folder, self.trial.deadline)
        (folder / 'recovered-session-FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE.sqlite3').write_bytes(b'unselected')
        with self.assertRaises(ValueError):s.metadata_digest(folder, self.trial.deadline)


class SessionUpdateEntryTests(unittest.TestCase):
    def test_shell_entry_requires_isolation_and_does_not_build_or_stop(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            record = root / 'called.txt'
            python = root / 'python3'
            python.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$SESSION_UPDATE_TEST_RECORD"\n')
            python.chmod(0o700)
            env = {k: v for k, v in os.environ.items() if not k.startswith('LEVISTICA_') and k != 'CONFIGURATION'}
            env.update(PATH=str(root) + os.pathsep + env.get('PATH', ''), CONFIGURATION='Release', LEVISTICA_EPHEMERAL='1', LEVISTICA_MEASUREMENT='1', SESSION_UPDATE_TEST_RECORD=str(record))
            args = ['bash', str(ROOT / 'script/build_and_run.sh'), '--rehearse-session-update', '/generated/baseline']
            result = subprocess.run(args, env=env, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(record.read_text().splitlines(), [str(ROOT / 'script/rehearse-session-update.py'), '/generated/baseline'])
            result = subprocess.run(args + ['--recovered'], env=env, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(record.read_text().splitlines()[-1], '--recovered')
            record.unlink()
            result = subprocess.run(args + ['--unknown'], env=env, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(record.exists())
            for key, value in [('LEVISTICA_EPHEMERAL', '0'), ('LEVISTICA_MEASUREMENT', '0'), ('LEVISTICA_PROFILE', '1'), ('LEVISTICA_MEASUREMENT_STORE_ID', 'caller-store'), ('LEVISTICA_MEASUREMENT_PERSIST_METADATA', '1'), ('LEVISTICA_MEASUREMENT_CLEANUP_REQUEST', '')]:
                record.unlink(missing_ok=True)
                result = subprocess.run(args, env={**env, key: value}, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 2, key)
                self.assertFalse(record.exists(), key)
