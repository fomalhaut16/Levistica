import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ui_session', ROOT / 'script/check-ui-session.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class UISessionTests(unittest.TestCase):
    def parse(self, value):
        return m.parse_state(plistlib.dumps(value))

    def test_explicit_boolean_and_integer_values(self):
        for flag, expected in [(False, 'unlocked'), (True, 'locked'), (0, 'unlocked'), (1, 'locked')]:
            with self.subTest(flag=flag):
                self.assertEqual(self.parse([{'IOConsoleLocked': flag}])['screenState'], expected)

    def test_nested_or_multiple_flags_fail_safe(self):
        self.assertEqual(self.parse([{'children': [{'IOConsoleLocked': False}]}])['screenState'], 'unlocked')
        self.assertEqual(self.parse([{'IOConsoleLocked': False}, {'IOConsoleLocked': True}])['screenState'], 'locked')

    def test_missing_and_invalid_flags_never_imply_unlocked(self):
        for registry in [[], {}, [{'CGSSessionScreenIsLocked': False}], {'IOConsoleLocked': 'false'},
                         {'IOConsoleLocked': 2}, {'IOConsoleLocked': 0.0}]:
            with self.subTest(registry=registry):
                self.assertEqual(self.parse(registry)['screenState'], 'unknown')
        self.assertEqual(m.parse_state(b'not a plist')['screenState'], 'unknown')
        self.assertEqual(m.parse_state(b'<?xml version="1.0"?><plist><dict>')['screenState'], 'unknown')

    def test_private_registry_values_are_not_returned(self):
        marker = 'synthetic-private-marker'
        result = self.parse([{'IOConsoleLocked': False, 'UserName': marker, 'SerialNumber': marker}])
        self.assertNotIn(marker, json.dumps(result))
        self.assertEqual(set(result), {'screenState'})

    def test_query_uses_unfiltered_root_and_bounded_read(self):
        with patch.object(m.subprocess, 'run', return_value=Mock(returncode=0, stdout=plistlib.dumps([{'IOConsoleLocked': False}]))) as run:
            self.assertEqual(m.query_state()['screenState'], 'unlocked')
            self.assertEqual(run.call_args.args[0], ['/usr/sbin/ioreg', '-d1', '-l', '-a'])
            self.assertEqual(run.call_args.kwargs['timeout'], 5)
            self.assertTrue(run.call_args.kwargs['capture_output'])

    def test_failed_or_timed_out_query_is_unknown(self):
        with patch.object(m.subprocess, 'run', return_value=Mock(returncode=1, stdout=b'private')):
            self.assertEqual(m.query_state()['screenState'], 'unknown')
        for error in (OSError('private'), subprocess.TimeoutExpired('ioreg', 5)):
            with patch.object(m.subprocess, 'run', side_effect=error):
                self.assertEqual(m.query_state()['screenState'], 'unknown')

    def run_entry(self, mode):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'script').mkdir(); (root / 'bin').mkdir()
            shutil.copyfile(ROOT / 'script/test.sh', root / 'script/test.sh')
            fake_python = root / 'bin/python3'
            fake_python.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$PREFLIGHT_CALLS_FILE"\nexit 2\n')
            fake_python.chmod(0o700)
            builder = root / 'script/build_and_run.sh'
            builder.write_text('#!/bin/sh\ntouch "$BUILDER_MARKER_FILE"\n')
            builder.chmod(0o700)
            calls, marker = root / 'calls', root / 'build-called'
            env = {**os.environ, 'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'],
                   'PREFLIGHT_CALLS_FILE': str(calls), 'BUILDER_MARKER_FILE': str(marker)}
            for key in ('TEST_ONLY', 'LEVISTICA_MALLOC_STACKS'):
                env.pop(key, None)
            result = subprocess.run(['bash', str(root / 'script/test.sh'), mode], env=env,
                                    capture_output=True, text=True, timeout=5)
            return result.returncode, calls.read_text(), marker.exists()

    def test_ui_entry_stops_before_build_when_preflight_fails(self):
        for mode in ('--ui', '--all', '--public-pdf-ui', '--deadline-ui'):
            code, calls, built = self.run_entry(mode)
            self.assertEqual(code, 2)
            self.assertIn('/check-ui-session.py', calls)
            self.assertFalse(built)

    def test_unit_entry_does_not_require_an_unlocked_screen(self):
        _, calls, built = self.run_entry('--unit')
        self.assertTrue(built)
        self.assertNotIn('/check-ui-session.py', calls)


if __name__ == '__main__':
    unittest.main()
