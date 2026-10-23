import importlib.util
import json
import pathlib
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('idle_workload', pathlib.Path(__file__).parents[1] / 'idle-workload.py')
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)


class SequentialWorkloadTests(unittest.TestCase):
    def files(self, directory):
        path = pathlib.Path(directory) / 'state.json'
        workload_path = pathlib.Path(directory) / 'workload.json'
        keys = [str(i) for i in range(1, 21)]
        state = {'kind': 'cross-site-documents', 'transport': 'same-origin-sse-v1',
                 'run_id': 'synthetic', 'expected_tabs': 20, 'loads': 0,
                 'urls': {k: f'http://document-{k}.localhost:12345/document/{k}' for k in keys},
                 'origins': {k: f'http://document-{k}.localhost:12345' for k in keys},
                 'document_hashes': dict.fromkeys(keys, 'a' * 64),
                 'stream_connections': dict.fromkeys(keys, 0), 'documents': {}}
        workload = {'variant': 'Measurement', 'pid': 123, 'started': 'synthetic start',
                    'executable': '/synthetic/Levistica.app/Contents/MacOS/Levistica',
                    'state': str(path.resolve()), 'urls': state['urls']}
        path.write_text(json.dumps(state))
        workload_path.write_text(json.dumps(workload))
        return state, workload, path, workload_path

    def report(self, state, key):
        state['loads'] += 1
        state['stream_connections'][key] = 1
        for document in state['documents'].values():
            document['visibility'] = 'hidden'
        state['documents'][key] = {'instance': 'instance-' + key, 'seenVisible': True, 'complete': True,
                                   'sections': 240, 'pulse': 1, 'width': 779, 'height': 683, 'dpr': 2,
                                   'origin': state['origins'][key], 'visibility': 'visible',
                                   'reported_monotonic': time.monotonic()}
        if len(state['documents']) == 20:
            state['ready_monotonic'] = time.monotonic()

    def test_all_twenty_urls_are_delivered_in_order_to_the_verified_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            state, workload, path, workload_path = self.files(temporary)
            order = []
            def opened(arguments, **_):
                key = arguments[-1].rsplit('/', 1)[-1]
                self.assertEqual(arguments[:3], ['/usr/bin/open', '-a', '/synthetic/Levistica.app'])
                order.append(int(key))
                self.report(state, key)
                path.write_text(json.dumps(state))
            with patch.object(idle, 'verify_application'), patch.object(idle, 'pressure'), \
                    patch.object(idle.subprocess, 'run', side_effect=opened):
                result = idle.deliver_sequential(path, workload_path)
            self.assertEqual(order, list(range(1, 21)))
            self.assertEqual(result['loads'], 20)
            self.assertTrue(all(d['seenVisible'] for d in result['documents'].values()))
            self.assertEqual(result['documents']['20']['visibility'], 'visible')

    def test_other_variant_or_mismatched_workload_is_rejected_before_delivery(self):
        for change in [{'variant': 'Profile'}, {'state': '/wrong/state.json'}, {'urls': {}}]:
            with tempfile.TemporaryDirectory() as temporary:
                state, workload, path, workload_path = self.files(temporary)
                workload_path.write_text(json.dumps({**workload, **change}))
                with patch.object(idle.subprocess, 'run') as run, self.assertRaises(ValueError):
                    idle.deliver_sequential(path, workload_path)
                run.assert_not_called()

    def test_reload_reconnection_or_fixture_replacement_aborts_without_more_urls(self):
        for change in ['reload', 'reconnect', 'fixture']:
            with tempfile.TemporaryDirectory() as temporary:
                state, workload, path, workload_path = self.files(temporary)
                def opened(arguments, **_):
                    self.report(state, '1')
                    if change == 'reload':
                        state['loads'] = 2
                    elif change == 'reconnect':
                        state['stream_connections']['1'] = 2
                    else:
                        state['run_id'] = 'replacement'
                    path.write_text(json.dumps(state))
                with patch.object(idle, 'verify_application'), patch.object(idle, 'pressure'), \
                        patch.object(idle.subprocess, 'run', side_effect=opened) as run, \
                        self.subTest(change=change), self.assertRaises(ValueError):
                    idle.deliver_sequential(path, workload_path)
                self.assertEqual(run.call_count, 1)

    def test_missing_visible_report_is_bounded_and_does_not_deliver_another_url(self):
        with tempfile.TemporaryDirectory() as temporary:
            state, workload, path, workload_path = self.files(temporary)
            with patch.object(idle, 'verify_application'), patch.object(idle, 'pressure'), \
                    patch.object(idle.subprocess, 'run') as run, patch.object(idle.time, 'sleep'), \
                    self.assertRaisesRegex(ValueError, 'ten seconds'):
                idle.deliver_sequential(path, workload_path)
            self.assertEqual(run.call_count, 1)

    def test_identity_or_pressure_failure_prevents_delivery(self):
        for method in ['verify_application', 'pressure']:
            with tempfile.TemporaryDirectory() as temporary:
                state, workload, path, workload_path = self.files(temporary)
                with patch.object(idle, 'verify_application'), patch.object(idle, 'pressure'):
                    with patch.object(idle, method, side_effect=ValueError('changed')), \
                            patch.object(idle.subprocess, 'run') as run, self.assertRaises(ValueError):
                        idle.deliver_sequential(path, workload_path)
                    run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
