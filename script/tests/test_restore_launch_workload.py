from contextlib import closing
import importlib.util
import json
import hashlib
import subprocess
import sys
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('restore_launch',ROOT/'script/restore-launch-workload.py')
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)

class RestoreLaunchTests(unittest.TestCase):
    def test_only_owned_test_paths_and_unlinked_files_are_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();parent=root/'.local/artifacts/tests.generated';parent.mkdir(parents=True)
            with mock.patch.object(s,'ROOT',root):
                good=parent/'release-launch-workload.json'
                self.assertEqual(s.run_file(good,good.name),good)
                for bad in [root/good.name,parent/'other.json',parent.parent/good.name]:
                    with self.subTest(path=bad),self.assertRaises(ValueError):s.run_file(bad,good.name)
                linked=root/'.local/artifacts/tests.linked';linked.symlink_to(parent,target_is_directory=True)
                with self.assertRaises(ValueError):s.run_file(linked/good.name,good.name)

    def test_only_measurement_container_and_real_namespace_are_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp).resolve();container=home/'Library/Containers'/s.BUNDLE
            namespace=container/'Data/Library/Application Support/LevisticaMeasurementProfiles';namespace.mkdir(parents=True)
            self.assertEqual(s.namespace(home),namespace)
            namespace.rmdir();outside=home/'outside';outside.mkdir();namespace.symlink_to(outside,target_is_directory=True)
            with self.assertRaises(ValueError):s.namespace(home)

    def test_any_levistica_checkout_blocks_preparation_without_a_signal(self):
        for path in ['/other/checkout/Levistica.app/Contents/MacOS/Levistica','/Users/test/Applications/Levistica.app/Contents/MacOS/Levistica']:
            with self.subTest(path=path),mock.patch.object(s.subprocess,'check_output',return_value=path+'\n'):
                with self.assertRaises(ValueError):s.assert_no_apps()
        with mock.patch.object(s.subprocess,'check_output',return_value='/Applications/Other.app/Other\n'):s.assert_no_apps()

    def test_server_rejects_nonloopback_or_extra_url_components(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();state=root/'.local/artifacts/tests.generated/restore-fixture-server.json';state.parent.mkdir(parents=True)
            with mock.patch.object(s,'ROOT',root):
                for url in ['https://127.0.0.1:1234','http://localhost:1234','http://127.0.0.1','http://127.0.0.1:1234/path','http://user@127.0.0.1:1234','http://127.0.0.1:1234?secret=1']:
                    state.write_text(json.dumps({'kind':'RestoreLaunchLoopbackV1','url':url}))
                    with self.subTest(url=url),self.assertRaises(ValueError):s.read_server(state)
                state.write_text(json.dumps({'kind':'RestoreLaunchLoopbackV1','url':'http://127.0.0.1:1234'}))
                self.assertEqual(s.read_server(state)['url'],'http://127.0.0.1:1234')

    def session(self,path):
        expected={'tabs':[{'id':'first','title':'first','url':'http://127.0.0.1:1234/restore-1'},
                          {'id':'second','title':'second','url':'http://127.0.0.1:1234/restore-2'}],'selectedID':'second'}
        with closing(sqlite3.connect(path)) as db:
            db.execute('CREATE TABLE session_tabs(id,title,url,may_reload,kind,is_kept,is_sleeping,position)')
            db.execute('CREATE TABLE session_meta(id,selected_id,was_running)')
            db.executemany('INSERT INTO session_tabs VALUES(?,?,?,1,"web",0,0,?)',[(t['id'],t['title'],t['url'],i) for i,t in enumerate(expected['tabs'])])
            db.execute('INSERT INTO session_meta VALUES(1,"second",0)');db.execute('PRAGMA user_version=3')
            db.commit()
        return expected

    def test_saved_order_selection_clean_exit_and_flags_must_match_without_mutation(self):
        for mutation in ['UPDATE session_tabs SET position=1-position','UPDATE session_meta SET selected_id="first"','UPDATE session_meta SET was_running=1','UPDATE session_tabs SET is_sleeping=1 WHERE id="first"','UPDATE session_tabs SET title="changed" WHERE id="second"','DELETE FROM session_tabs WHERE id="first"','PRAGMA user_version=4']:
            with self.subTest(mutation=mutation),tempfile.TemporaryDirectory() as temp:
                path=Path(temp).resolve()/'session.sqlite3';expected=self.session(path);before=path.read_bytes()
                self.assertEqual(s.verify_session(path,expected)['tabCount'],2);self.assertEqual(path.read_bytes(),before)
                with closing(sqlite3.connect(path)) as db:db.execute(mutation);db.commit()
                changed=path.read_bytes()
                with self.assertRaises(ValueError):s.verify_session(path,expected)
                self.assertEqual(path.read_bytes(),changed)

    def test_saved_metric_cannot_be_confused_with_blank_or_profile(self):
        value=[{'testIdentifier':'BrowserFlowTests/testMeasurementSavedWindowLaunchMetric()',
                'testRuns':[{'metrics':[{'identifier':s.launch.LAUNCH_METRIC,'unitOfMeasurement':'s','measurements':[.5]}]}]}]
        for count in (50,100):self.assertEqual(s.launch.validate_metrics(value,'Measurement',count)['restoredTabs'],count)
        for variant,count in [('Profile',50),('Measurement',1),('Measurement',True),('Measurement',0)]:
            with self.subTest(variant=variant,count=count),self.assertRaises(ValueError):s.launch.validate_metrics(value,variant,count)

class ProductionRestoreFixtureTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Production Swift store requires macOS')
    def test_production_store_generates_reopenable_sessions_and_refuses_overwrite(self):
        artifacts = ROOT / '.local/artifacts'
        artifacts.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='tests.restore-seed.', dir=artifacts) as temp:
            work = Path(temp).resolve()
            executable = work / 'seed'
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                '-strict-concurrency=complete', '-O', '-whole-module-optimization',
                '-module-cache-path', str(ROOT / '.local/ModuleCache'),
                str(ROOT / 'Levistica/Stores/SessionStore.swift'), str(ROOT / 'script/restore-session-fixture.swift'),
                '-o', str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr[:2000])
            for count in (50, 100):
                directory = work / f'restore-fixture-{count}'
                directory.mkdir()
                database = directory / 'session.sqlite3'
                generated = subprocess.run([str(executable), str(database), str(count), 'http://127.0.0.1:49152'],
                                           capture_output=True, text=True, timeout=10)
                self.assertEqual(generated.returncode, 0, generated.stderr)
                expected = json.loads(generated.stdout)
                self.assertEqual(s.verify_session(database, expected)['tabCount'], count)
                self.assertEqual(expected['selectedID'], expected['tabs'][count // 2]['id'])
                before = hashlib.sha256(database.read_bytes()).hexdigest()
                rejected = subprocess.run([str(executable), str(database), str(count), 'http://127.0.0.1:49152'],
                                          capture_output=True, text=True, timeout=10)
                self.assertEqual(rejected.returncode, 2)
                self.assertEqual(hashlib.sha256(database.read_bytes()).hexdigest(), before)

    @unittest.skipUnless(sys.platform == 'darwin', 'Production Swift store requires macOS')
    def test_prepare_stages_new_owned_uuid_without_replacing_existing_files(self):
        artifacts = ROOT / '.local/artifacts'
        artifacts.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='tests.restore-stage.', dir=artifacts) as temp:
            work = Path(temp).resolve()
            namespace = work / 'synthetic-container'
            namespace.mkdir()
            workload = work / 'release-launch-workload.json'
            workload.write_text(json.dumps({'kind':'IsolatedReleaseBlankLaunchV1','variant':'Measurement'}))
            state = work / 'restore-fixture-server.json'
            state.write_text(json.dumps({'kind':'RestoreLaunchLoopbackV1','url':'http://127.0.0.1:49152','requests':{}}))
            with mock.patch.object(s,'namespace',return_value=namespace),mock.patch.object(s,'assert_no_apps'):
                s.prepare(workload,50)
            prepared = json.loads(workload.read_text())
            database = namespace / prepared['storeID'] / 'session.sqlite3'
            self.assertEqual(s.verify_session(database,prepared['expectedSession'])['tabCount'],50)
            before = database.read_bytes()
            # A reused owned UUID must be refused before compilation or any write to its folder.
            second = work / 'other'
            second.mkdir()
            other = second / workload.name
            other.write_text(json.dumps({'kind':'IsolatedReleaseBlankLaunchV1','variant':'Measurement'}))
            (second / state.name).write_bytes(state.read_bytes())
            with mock.patch.object(s,'namespace',return_value=namespace),mock.patch.object(s,'assert_no_apps'), \
                 mock.patch.object(s,'run_file',side_effect=lambda path,name:Path(path)), \
                 mock.patch.object(s.stores,'allocate',return_value=prepared['storeID']):
                with self.assertRaisesRegex(ValueError,'must be new'):
                    s.prepare(other,50)
            self.assertEqual(database.read_bytes(),before)

if __name__=='__main__':unittest.main()
