import copy
import importlib.util
import pathlib
import unittest
import tempfile

path = pathlib.Path(__file__).resolve().parents[1] / 'profile-workload.py'
spec = importlib.util.spec_from_file_location('profile_workload', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProfileWorkloadTests(unittest.TestCase):
    def state(self, completed=False):
        return {'kind': 'sleep-documents', 'expected_tabs': 5,
                'transport': 'same-origin-sse-lifecycle-v1',
                'loads': 13 if completed else 0,
                'document_loads': {str(n): (3 if n < 5 else 1) if completed else 0 for n in range(1, 6)},
                'documents': {str(n): {'complete': True, 'seenVisible': True, 'sections': 240} for n in range(1, 6)}}

    def test_accepts_only_fresh_fixture_for_preparation(self):
        module.validate_state(self.state())
        with self.assertRaises(ValueError):
            module.validate_state(self.state(True))

    def test_exact_two_cycles_preserve_fifth_document(self):
        state = self.state(True)
        module.validate_state(state, completed=True)
        changed = copy.deepcopy(state)
        changed['document_loads']['4'] = 2
        changed['document_loads']['5'] = 2
        with self.assertRaises(ValueError):
            module.validate_state(changed, completed=True)

    def test_rejects_invalid_or_unready_documents(self):
        for key, value in [('invalid_reason', 'failure'), ('kind', 'documents'), ('expected_tabs', 20), ('loads', 14)]:
            state = self.state(True)
            state[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate_state(state, completed=True)
        state = self.state(True)
        state['documents']['2']['seenVisible'] = False
        with self.assertRaises(ValueError):
            module.validate_state(state, completed=True)


class SnapshotCompletenessTests(unittest.TestCase):
    def test_requires_all_four_pairs_of_nonempty_snapshots(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            for stage in ('loaded-five', 'sleep-1', 'sleep-2', 'resumed-two'):
                for tool in ('vmmap', 'malloc_history'):
                    (root / f'{stage}-{tool}.txt').write_text('synthetic tool output')
            self.assertEqual(len(module.validate_snapshots(root)), 8)
            (root / 'sleep-2-malloc_history.txt').unlink()
            with self.assertRaises(FileNotFoundError):
                module.validate_snapshots(root)

    def test_rejects_empty_and_oversized_snapshots(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            file = root / 'loaded-five-vmmap.txt'
            file.touch()
            with self.assertRaises(ValueError):
                module.validate_snapshots(root)
            with file.open('wb') as output:
                output.truncate(8 * 1024 * 1024 + 1)
            with self.assertRaises(ValueError):
                module.validate_snapshots(root)


class CollectorBoundaryTests(unittest.TestCase):
    def test_rejects_page_origin_wrong_token_and_request_body(self):
        headers = {'Host': '127.0.0.1:1234', 'X-Levistica-Diagnostic': 'private-token'}
        self.assertTrue(module.request_is_valid(headers, '127.0.0.1:1234', 'private-token'))
        for key, value in [('Origin', 'http://document-1.localhost'),
                           ('X-Levistica-Diagnostic', 'wrong'), ('X-Levistica-Diagnostic', '非ASCII'),
                           ('Host', 'localhost:1234'),
                           ('Content-Length', '1'), ('Transfer-Encoding', 'chunked')]:
            with self.subTest(key=key):
                changed = dict(headers)
                changed[key] = value
                self.assertFalse(module.request_is_valid(changed, '127.0.0.1:1234', 'private-token'))

    def test_only_fixed_order_can_invoke_fixed_commands(self):
        import http.client
        import threading
        calls = []
        server = module.create_collector(1234, lambda: None,
                                         lambda stage, tool, args: calls.append((stage, tool, args)) or {'bytes': 1})
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
        headers = {'X-Levistica-Diagnostic': server.token}
        try:
            connection.request('POST', '/snapshot/sleep-1', headers=headers)
            response = connection.getresponse()
            self.assertEqual(response.status, 409)
            response.read()
            self.assertEqual(calls, [])
            for stage in module.STAGES:
                connection.request('POST', '/snapshot/' + stage, headers=headers)
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                response.read()
            self.assertEqual(len(calls), 8)
            self.assertEqual(calls[0], ('loaded-five', 'vmmap', ['-summary', '1234']))
            self.assertEqual(calls[1], ('loaded-five', 'malloc_history', ['1234', '-callTree', '.*[8m+]']))
            connection.request('POST', '/snapshot/loaded-five', headers=headers)
            response = connection.getresponse()
            self.assertEqual(response.status, 409)
            response.read()
            self.assertEqual(len(calls), 8)
        finally:
            connection.close()
            server.shutdown()
            worker.join(timeout=5)
            server.server_close()

    def test_failed_identity_never_invokes_a_tool(self):
        import http.client
        import threading
        from unittest.mock import Mock
        capture = Mock()
        verify = Mock(side_effect=ValueError('identity changed'))
        server = module.create_collector(1234, verify, capture)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
        try:
            connection.request('POST', '/snapshot/loaded-five', headers={'X-Levistica-Diagnostic': server.token})
            response = connection.getresponse()
            self.assertEqual(response.status, 500)
            response.read()
            capture.assert_not_called()
            self.assertEqual(server.failure, 'identity changed')
        finally:
            connection.close()
            server.shutdown()
            worker.join(timeout=5)
            server.server_close()
