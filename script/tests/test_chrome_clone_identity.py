import ctypes
import importlib.util
import pathlib
import re
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('chrome_clone_measure', pathlib.Path(__file__).parents[1] / 'measure-memory.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ChromeCloneIdentityTests(unittest.TestCase):
    def fixture(self, root):
        original = root / 'Chrome'
        original.write_bytes(b'controlled executable fixture')
        clone = root / 'code_sign_clone.Abc123' / 'Google Chrome.app.bundle/Contents/MacOS/Google Chrome'
        clone.parent.mkdir(parents=True)
        pattern = re.compile(re.escape(str(root)) + r'/code_sign_clone\.[A-Za-z0-9._-]{6}/Google Chrome\.app(?:\.bundle)?/Contents/MacOS/Google Chrome')
        return original, clone, pattern

    def test_actual_hardlink_is_canonicalized_and_distinct_copy_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            original, clone, pattern = self.fixture(pathlib.Path(temporary).resolve())
            clone.hardlink_to(original)
            with patch.object(m, 'CHROME_BINARY', original), patch.object(m, 'CHROME_CLONE_PATH', pattern):
                self.assertEqual(m.canonical_chrome_hardlink(str(clone)), str(original))
                clone.unlink(); clone.write_bytes(original.read_bytes())
                self.assertEqual(m.canonical_chrome_hardlink(str(clone)), str(clone))

    def test_symlink_missing_file_and_non_file_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            original, clone, pattern = self.fixture(pathlib.Path(temporary).resolve())
            with patch.object(m, 'CHROME_BINARY', original), patch.object(m, 'CHROME_CLONE_PATH', pattern):
                for kind in ['symlink', 'missing', 'directory']:
                    with self.subTest(kind=kind):
                        if kind == 'symlink':clone.symlink_to(original)
                        elif kind == 'directory':clone.mkdir()
                        if kind == 'missing':
                            with self.assertRaises(ValueError):m.canonical_chrome_hardlink(str(clone))
                        else:self.assertEqual(m.canonical_chrome_hardlink(str(clone)), str(clone))
                        if kind == 'symlink':clone.unlink()
                        elif kind == 'directory':clone.rmdir()

    def test_canonical_file_replacement_during_verification_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            original, clone, pattern = self.fixture(pathlib.Path(temporary).resolve())
            clone.hardlink_to(original)
            before, alias = original.stat(), clone.stat()
            replacement = original.with_name('replacement');replacement.write_bytes(original.read_bytes())
            after = replacement.stat()
            with patch.object(m, 'CHROME_BINARY', original), patch.object(m, 'CHROME_CLONE_PATH', pattern), \
                 patch.object(m.os, 'stat', side_effect=[before, alias, after]):
                with self.assertRaisesRegex(ValueError, 'changed during'):
                    m.canonical_chrome_hardlink(str(clone))

    def test_only_known_chrome_clone_shape_reaches_file_verification(self):
        valid = '/private/var/folders/aa/user/X/com.google.Chrome.code_sign_clone/code_sign_clone.Abc123/Google Chrome.app.bundle/Contents/MacOS/Google Chrome'
        invalid = ['/unrelated/app', str(m.CHROME_BINARY),
                   valid.replace('com.google.Chrome.', 'other.'),
                   valid.replace('Abc123', 'Abc1234'),
                   valid.replace('Google Chrome.app.bundle', 'Other.app'),
                   valid + '/extra', valid.replace('/X/', '/T/'),
                   valid.replace('Contents/MacOS/Google Chrome', 'Contents/MacOS/Google Chrome Helper')]
        for path in invalid:
            with self.subTest(path=path), patch.object(m.os, 'stat') as stat:
                self.assertEqual(m.canonical_chrome_hardlink(path), path)
                stat.assert_not_called()
        self.assertIsNotNone(m.CHROME_CLONE_PATH.fullmatch(valid))
        self.assertIsNotNone(m.CHROME_CLONE_PATH.fullmatch(valid.replace('.app.bundle', '.app')))

    def test_kernel_lookup_applies_verified_normalization_without_ps_fallback(self):
        raw = '/synthetic/kernel/path'
        def lookup(pid, buffer, size):
            ctypes.memmove(buffer, raw.encode() + b'\0', len(raw) + 1)
            return len(raw)
        with patch.object(m, '_pidpath_function', return_value=lookup), \
             patch.object(m, 'canonical_chrome_hardlink', return_value='/verified/executable') as normalize, \
             patch.object(m, 'run') as query:
            self.assertEqual(m.process_executable_path(123), '/verified/executable')
            normalize.assert_called_once_with(raw)
            query.assert_not_called()
        with patch.object(m, '_pidpath_function', return_value=lookup), \
             patch.object(m, 'canonical_chrome_hardlink', side_effect=ValueError('clone identity failed')):
            with self.assertRaisesRegex(ValueError, 'clone identity failed'):
                m.process_executable_path(123)


if __name__ == '__main__':
    unittest.main()
