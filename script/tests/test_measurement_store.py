import copy
import importlib.util
import json
import os
import pathlib
import plistlib
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

    def test_unregistered_identifier_and_linked_marker_cannot_be_cleaned(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(store, 'BASE', pathlib.Path(temporary)):
            value = str(uuid.uuid4())
            with patch.object(store.subprocess, 'run') as run, self.assertRaises(FileNotFoundError):
                store.cleanup(value)
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

    def test_cleanup_receipt_requires_matching_ids_success_and_other_stores_unchanged(self):
        value, request = str(uuid.uuid4()), str(uuid.uuid4())
        receipt = {'version': 1, 'storeID': value.upper(), 'requestID': request.upper(),
                   'success': True, 'otherIdentifiersUnchanged': True, 'storeExisted': True}
        store.check_receipt(receipt, value, request)
        for key, invalid in [('storeID', str(uuid.uuid4())), ('requestID', str(uuid.uuid4())),
                             ('success', False), ('success', 1), ('otherIdentifiersUnchanged', False),
                             ('storeExisted', None), ('version', 2)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                store.check_receipt({**receipt, key: invalid}, value, request)

    def test_active_page_host_prevents_cleanup_without_launching_or_signalling(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(store, 'BASE', pathlib.Path(temporary)):
            value = store.allocate()
            with patch.object(store.guard, 'run_ps', return_value='synthetic'), \
                    patch.object(store.guard, 'check_snapshot', return_value=[123]), \
                    patch.object(store.subprocess, 'run') as run, patch.object(store.os, 'kill') as kill:
                with self.assertRaises(ValueError):
                    store.cleanup(value)
                run.assert_not_called()
                kill.assert_not_called()

    def test_successful_receipt_marks_only_the_owned_store_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary); app = base / 'Measurement.app'
            (app / 'Contents').mkdir(parents=True)
            with (app / 'Contents/Info.plist').open('wb') as file:
                plistlib.dump({'CFBundleIdentifier': 'dev.fomalhaut16.Levistica.measurement'}, file)
            with patch.object(store, 'BASE', base), patch.object(store, 'APP', app), patch.object(store, 'RECEIPTS', base / 'receipts'):
                value = store.allocate()
                other = store.allocate()
                def opened(command, **_):
                    request = next(v.split('=', 1)[1] for v in command if v.startswith(store.REQUEST_KEY + '='))
                    store.RECEIPTS.mkdir(exist_ok=True)
                    receipt_path = store.RECEIPTS / (request + '.json')
                    receipt_path.write_text(json.dumps({'version': 1, 'storeID': value, 'requestID': request,
                        'success': True, 'otherIdentifiersUnchanged': True, 'storeExisted': True}))
                with patch.object(store.guard, 'run_ps', return_value='synthetic'), \
                        patch.object(store.guard, 'check_snapshot', return_value=[]), \
                        patch.object(store.subprocess, 'run', side_effect=opened), patch('builtins.print'):
                    store.cleanup(value)
                self.assertTrue(json.loads((base / (value + '.json')).read_text())['removed'])
                self.assertFalse(store.owned(other)[0]['removed'])
                with self.assertRaises(ValueError):
                    store.owned(value)

    def test_invalid_build_flags_are_rejected_before_process_access(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        environments = [
            {'LEVISTICA_MEASUREMENT_STORE_ID': str(uuid.uuid4())},
            {'LEVISTICA_MEASUREMENT_STORE_ID': ''},
            {'LEVISTICA_MEASUREMENT_CLEANUP_REQUEST': str(uuid.uuid4())},
            {'LEVISTICA_MEASUREMENT': '1', 'CONFIGURATION': 'Release', 'LEVISTICA_EPHEMERAL': '1',
             'LEVISTICA_MEASUREMENT_STORE_ID': '00000000-0000-0000-0000-000000000000'}]
        for settings in environments:
            env = {k: v for k, v in os.environ.items() if not k.startswith('LEVISTICA_') and k != 'CONFIGURATION'}
            result = subprocess.run(['bash', str(root / 'script/build_and_run.sh'), '--build'],
                                    env={**env, **settings}, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('Built ', result.stdout)


if __name__ == '__main__':
    unittest.main()
