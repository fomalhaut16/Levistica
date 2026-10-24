import importlib.util
import json
import os
import pathlib
import sqlite3
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('measurement_store', pathlib.Path(__file__).parents[1] / 'measurement-store.py')
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)


class MeasurementStoreTests(unittest.TestCase):
    def test_uuid_requires_canonical_nonzero_value(self):
        value = str(uuid.uuid4())
        self.assertEqual(store.identifier(value.upper()), value)
        for invalid in ['', 'not-uuid', '0' * 32, '00000000-0000-0000-0000-000000000000', value.replace('-', ''), ' ' + value]:
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                store.identifier(invalid)

    def test_owned_marker_is_private_and_removed_or_foreign_markers_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(store, 'BASE', pathlib.Path(temporary)):
            value = store.allocate()
            marker, path = store.owned(value)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            for changed in [{'removed': True}, {'bundleID': 'dev.fomalhaut16.Levistica'},
                            {'storeID': str(uuid.uuid4())}, {'version': 2}]:
                path.write_text(json.dumps({**marker, **changed}))
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    store.owned(value)

    def test_unregistered_identifier_and_linked_marker_cannot_be_used(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(store, 'BASE', pathlib.Path(temporary)):
            value = str(uuid.uuid4())
            with patch.object(store.subprocess, 'run') as run, self.assertRaises(FileNotFoundError):
                store.owned(value)
            run.assert_not_called()
            outside = pathlib.Path(temporary) / 'other.json'
            outside.write_text('{}')
            (pathlib.Path(temporary) / (value + '.json')).symlink_to(outside)
            with self.assertRaises(ValueError):
                store.owned(value)

    def test_only_selected_test_flags_are_extracted_from_process_environment(self):
        value = str(uuid.uuid4())
        text = 'app PRIVATE_TEST_VALUE=do-not-copy LEVISTICA_EPHEMERAL=1 ' + store.STORE_KEY + '=' + value
        with patch.object(store.subprocess, 'run', return_value=Mock(stdout=text)):
            flags = store.runtime_flags(123)
        self.assertEqual(flags, {'LEVISTICA_EPHEMERAL': '1', store.STORE_KEY: value})
        with patch.object(store.subprocess, 'run', return_value=Mock(stdout=text + ' ' + store.STORE_KEY + '=' + value)):
            with self.assertRaises(ValueError):
                store.runtime_flags(123)

    def test_sampling_records_actual_storage_mode_and_rejects_cleanup_or_unowned_store(self):
        flags = {'LEVISTICA_EPHEMERAL': '1'}
        self.assertIsNone(store.selection(flags)['storeID'])
        with tempfile.TemporaryDirectory() as temporary, patch.object(store, 'BASE', pathlib.Path(temporary)):
            value = store.allocate()
            self.assertEqual(store.selection({**flags, store.STORE_KEY: value})['storeID'], value)
            for invalid in [{}, {**flags, store.REQUEST_KEY: str(uuid.uuid4())},
                            {**flags, store.STORE_KEY: str(uuid.uuid4())}]:
                with self.subTest(flags=invalid), self.assertRaises((ValueError, FileNotFoundError)):
                    store.selection(invalid)

    def test_invalid_build_flags_are_rejected_before_process_access(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        environments = [
            {'LEVISTICA_MEASUREMENT_STORE_ID': str(uuid.uuid4())},
            {'LEVISTICA_MEASUREMENT_STORE_ID': ''},
            {'LEVISTICA_MEASUREMENT_CLEANUP_REQUEST': str(uuid.uuid4())},
            {store.METADATA_KEY: '1'},
            {store.METADATA_KEY: ''},
            {store.METADATA_KEY: 'true'},
            {'LEVISTICA_MEASUREMENT': '1', 'CONFIGURATION': 'Release', 'LEVISTICA_EPHEMERAL': '1',
             store.METADATA_KEY: '1'},
            {'LEVISTICA_MEASUREMENT': '1', 'CONFIGURATION': 'Release', 'LEVISTICA_EPHEMERAL': '1',
             'LEVISTICA_MEASUREMENT_STORE_ID': '00000000-0000-0000-0000-000000000000'}]
        for settings in environments:
            env = {k: v for k, v in os.environ.items() if not k.startswith('LEVISTICA_') and k != 'CONFIGURATION'}
            result = subprocess.run(['bash', str(root / 'script/build_and_run.sh'), '--build'],
                                    env={**env, **settings}, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('Built ', result.stdout)

    def test_metadata_mode_requires_owned_uuid_and_is_recorded_separately(self):
        flags = {'LEVISTICA_EPHEMERAL': '1'}
        with tempfile.TemporaryDirectory() as temporary, patch.object(store, 'BASE', pathlib.Path(temporary)):
            value = store.allocate()
            selected = {**flags, store.STORE_KEY: value}
            self.assertIn('memory-only', store.selection(selected)['mode'])
            self.assertIn('isolated browser metadata', store.selection({**selected, store.METADATA_KEY: '1'})['mode'])
            for invalid in [{**flags, store.METADATA_KEY: '1'}, {**selected, store.METADATA_KEY: ''},
                            {**selected, store.METADATA_KEY: 'true'}]:
                with self.subTest(flags=invalid), self.assertRaises(ValueError):
                    store.selection(invalid)

    def test_metadata_counts_use_read_only_owned_files_and_do_not_return_records(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(store, 'BASE', pathlib.Path(temporary) / 'markers'):
            value = store.allocate()
            folder = pathlib.Path(temporary) / 'LevisticaMeasurementProfiles' / value
            folder.mkdir(parents=True)
            for name, table in [('session.sqlite3', 'session_tabs'), ('history.sqlite3', 'history')]:
                with sqlite3.connect(folder / name) as connection:
                    connection.execute('CREATE TABLE ' + table + '(value TEXT)')
                    connection.execute('INSERT INTO ' + table + " VALUES ('synthetic-private-record')")
                    connection.execute('PRAGMA user_version=1')
            listing = 'p123\nn' + str(folder / 'session.sqlite3') + '\nn/unrelated/file\n'
            with patch.object(store.subprocess, 'run', return_value=Mock(stdout=listing)):
                result = store.metadata_snapshot(123, value)
            self.assertEqual(result, {'tabCount': 1, 'historyCount': 1, 'sessionSchema': 1, 'historySchema': 1})
            self.assertNotIn('synthetic-private-record', json.dumps(result))
            (folder / 'history.sqlite3').unlink()
            with patch.object(store.subprocess, 'run', return_value=Mock(stdout=listing)), self.assertRaises(ValueError):
                store.metadata_snapshot(123, value)
            self.assertFalse((folder / 'history.sqlite3').exists())

    def test_missing_or_ambiguous_metadata_database_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(store, 'BASE', pathlib.Path(temporary)):
            value = store.allocate()
            for listing in ['', 'n/a/LevisticaMeasurementProfiles/' + value + '/session.sqlite3\nn/b/LevisticaMeasurementProfiles/' + value + '/session.sqlite3\n']:
                with patch.object(store.subprocess, 'run', return_value=Mock(stdout=listing)), self.assertRaises(ValueError):
                    store.metadata_snapshot(123, value)


if __name__ == '__main__':
    unittest.main()
