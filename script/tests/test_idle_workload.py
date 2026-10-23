import importlib.util
import pathlib
import unittest
from unittest.mock import patch

path = pathlib.Path(__file__).resolve().parents[1] / 'idle-workload.py'
spec = importlib.util.spec_from_file_location('idle_workload', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IdleWorkloadTests(unittest.TestCase):
    def state(self, completed=False):
        keys = [str(n) for n in range(1, 21)]
        return {'kind': 'cross-site-documents', 'transport': 'same-origin-sse-v1',
                'expected_tabs': 20, 'loads': 20 if completed else 0,
                'urls': {key: f'http://document-{key}.localhost:12345/document/{key}' for key in keys},
                'stream_connections': {key: 1 if completed else 0 for key in keys},
                'documents': {key: {'complete': True, 'seenVisible': True, 'sections': 240, 'pulse': 1}
                              for key in keys} if completed else {}}

    def test_preparation_requires_an_untouched_twenty_host_fixture(self):
        module.validate_state(self.state())
        with self.assertRaises(ValueError):
            module.validate_state(self.state(True))

    def test_completion_does_not_claim_background_report_freshness(self):
        state = self.state(True)
        for document in state['documents'].values():
            document['reported_monotonic'] = 0
        module.validate_state(state, completed=True)

    def test_reloads_reconnections_and_fixture_failures_are_rejected(self):
        for key, value in [('loads', 21), ('expected_tabs', 5), ('invalid_reason', 'Changed instance')]:
            state = self.state(True)
            state[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate_state(state, completed=True)
        state = self.state(True)
        state['stream_connections']['1'] = 2
        with self.assertRaises(ValueError):
            module.validate_state(state, completed=True)

    def test_misdirected_urls_are_rejected(self):
        for url in ['https://example.com/document/1', 'http://document-2.localhost:12345/document/1',
                    'http://user:secret@document-1.localhost:12345/document/1',
                    'http://document-1.localhost:54321/document/1',
                    'http://document-1.localhost:12345/document/1?unexpected=1']:
            state = self.state()
            state['urls']['1'] = url
            with self.subTest(url=url), self.assertRaises(ValueError):
                module.validate_state(state)

    def test_incomplete_documents_are_rejected(self):
        for key, value in [('seenVisible', False), ('complete', False), ('sections', 239), ('pulse', 0)]:
            state = self.state(True)
            state['documents']['20'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate_state(state, completed=True)

    def test_pressure_changes_and_read_errors_fail_closed(self):
        with patch.object(module.subprocess, 'check_output', return_value='1\n'):
            self.assertEqual(module.pressure(), 1)
        with patch.object(module.subprocess, 'check_output', return_value='2\n'):
            with self.assertRaises(ValueError):
                module.pressure()
        with patch.object(module.subprocess, 'check_output', side_effect=OSError('synthetic error')):
            with self.assertRaises(OSError):
                module.pressure()


if __name__ == '__main__':
    unittest.main()
