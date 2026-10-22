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
