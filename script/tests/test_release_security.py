"""Regression guards for normal Release inspection using synthetic metadata only."""
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_security', Path(__file__).parents[1] / 'check-release-security.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ReleaseSecurityTests(unittest.TestCase):
    def setUp(self):
        self.info = {'CFBundleIdentifier': r.BUNDLE_ID, 'CFBundleExecutable': 'Levistica',
                     'LevisticaSourceState': 'clean', 'LevisticaSourceRevision': 'a' * 40,
                     'NSAppTransportSecurity': {'NSAllowsArbitraryLoadsInWebContent': True}}
        self.entitlements = dict.fromkeys(r.REQUIRED, True)
        self.signature = 'Identifier=' + r.BUNDLE_ID + '\nCodeDirectory v=20500 size=123 flags=0x10002(adhoc,runtime)\n'
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        p = patch.object(r, 'ROOT', self.root)
        p.start(); self.addCleanup(p.stop)
        self.app = self.root / '.local/DerivedData/Build/Products/Release/Levistica.app'

    def validate(self):
        return r.validate(self.info, self.entitlements, self.signature)

    def test_normal_local_signature_reports_only_bounded_facts(self):
        report = self.validate()
        self.assertTrue(report['sandbox'] and report['hardenedRuntime'])
        self.assertFalse(report['notarizationVerified'] or report['chromeEquivalent'])
        self.assertNotIn('entitlements', report)
        self.assertNotIn('signature', report)
        self.assertEqual(report['source'], 'a' * 40)

    def test_developer_id_flags_are_accepted_without_claiming_notarization(self):
        self.signature = self.signature.replace('0x10002(adhoc,runtime)', '0x10000(runtime)')
        result = self.validate()
        self.assertFalse(result['adHocSignature'] or result['notarizationVerified'])

    def test_debug_profile_measurement_or_uncommitted_builds_are_refused(self):
        for key, value in [('CFBundleIdentifier', r.BUNDLE_ID + '.debug'),
                           ('CFBundleIdentifier', r.BUNDLE_ID + '.profile'),
                           ('CFBundleIdentifier', r.BUNDLE_ID + '.measurement'),
                           ('CFBundleExecutable', 'Other'), ('LevisticaSourceState', 'dirty'),
                           ('LevisticaSourceRevision', 'abc')]:
            with self.subTest(key=key, value=value):
                changed = dict(self.info, **{key: value})
                with self.assertRaises(ValueError): r.validate(changed, self.entitlements, self.signature)

    def test_sandbox_and_resource_permissions_require_boolean_true(self):
        for key in r.REQUIRED:
            for value in [False, 1, 'true', None]:
                with self.subTest(key=key, value=value):
                    changed = dict(self.entitlements, **{key: value})
                    with self.assertRaises(ValueError): r.validate(self.info, changed, self.signature)
            changed = dict(self.entitlements); del changed[key]
            with self.assertRaises(ValueError): r.validate(self.info, changed, self.signature)

    def test_debug_access_and_each_runtime_exception_fail_closed(self):
        for key in r.FORBIDDEN:
            for value in [True, 1, 'false', None]:
                with self.subTest(key=key, value=value):
                    with self.assertRaises(ValueError): r.validate(self.info, dict(self.entitlements, **{key: value}), self.signature)
            r.validate(self.info, dict(self.entitlements, **{key: False}), self.signature)
        with self.assertRaises(ValueError):
            r.validate(self.info, dict(self.entitlements, **{'com.apple.security.files.all': True}), self.signature)

    def test_ats_exceptions_and_general_bypass_are_refused(self):
        for ats in [True, [], {'NSAllowsArbitraryLoads': True}, {'NSExceptionDomains': {}},
                    {'NSAllowsArbitraryLoadsInWebContent': 1}]:
            with self.subTest(ats=ats):
                with self.assertRaises(ValueError): r.validate(dict(self.info, NSAppTransportSecurity=ats), self.entitlements, self.signature)
        for ats in [{}, {'NSAllowsArbitraryLoadsInWebContent': False}]:
            report = r.validate(dict(self.info, NSAppTransportSecurity=ats), self.entitlements, self.signature)
            self.assertFalse(report['webHTTPPermitted'])

    def test_flags_in_a_path_cannot_substitute_for_code_directory_runtime(self):
        for signature in [self.signature.replace('0x10002', '0x2'),
                          self.signature.replace('CodeDirectory', 'Executable=/tmp/CodeDirectory'),
                          'Executable=/tmp/flags=0x10000\nIdentifier=' + r.BUNDLE_ID,
                          self.signature + self.signature,
                          self.signature.replace(r.BUNDLE_ID, 'other')]:
            with self.subTest(signature=signature):
                with self.assertRaises(ValueError): r.validate(self.info, self.entitlements, signature)

    def test_malformed_metadata_is_a_controlled_rejection(self):
        for info, entitlements, signature in [(None, {}, ''), ([], {}, ''), (self.info, [], ''),
                                               (self.info, {}, b'bytes')]:
            with self.assertRaises(ValueError): r.validate(info, entitlements, signature)

    def test_only_local_normal_release_and_named_archive_paths_are_allowed(self):
        self.assertEqual(r.checked_app(self.app), self.app)
        archive = self.root / '.local/archives/local-ABC123/Levistica.xcarchive/Products/Applications/Levistica.app'
        self.assertEqual(r.checked_app(archive), archive)
        for path in [self.app.parent.parent / 'Debug/Levistica.app', self.root / 'Levistica.app',
                     Path('/Applications/Levistica.app'),
                     self.root / '.local/archives/local-ABC123/other/Products/Applications/Levistica.app',
                     self.root / '.local/archives/local-x/Levistica.xcarchive/Products/Applications/Levistica.app']:
            with self.subTest(path=path):
                with self.assertRaises(ValueError): r.checked_app(path)

    def test_linked_bundle_parent_is_refused_before_codesign(self):
        (self.root / '.local').symlink_to(self.root / 'unrelated', target_is_directory=True)
        with patch.object(r.subprocess, 'run') as run:
            with self.assertRaises(ValueError): r.check(self.app)
            run.assert_not_called()

    def test_linked_contents_or_executable_are_refused_before_codesign(self):
        for part in ['Contents', 'Contents/MacOS', 'Contents/Info.plist', 'Contents/MacOS/Levistica']:
            with self.subTest(part=part), tempfile.TemporaryDirectory(dir=self.root) as folder:
                root = Path(folder)
                app = root / '.local/DerivedData/Build/Products/Release/Levistica.app'
                target = app / part
                target.parent.mkdir(parents=True)
                target.symlink_to(root / 'outside')
                with patch.object(r, 'ROOT', root), patch.object(r.subprocess, 'run') as run:
                    with self.assertRaises(ValueError): r.check(app)
                    run.assert_not_called()

    def make_bundle(self):
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        (self.app / 'Contents/MacOS/Levistica').write_bytes(b'synthetic')

    def test_inspection_verifies_signature_before_reading_entitlements(self):
        self.make_bundle()
        responses = [subprocess.CompletedProcess([], 0, b'', b''),
                     subprocess.CompletedProcess([], 0, '', self.signature),
                     subprocess.CompletedProcess([], 0, plistlib.dumps(self.entitlements), b'')]
        with patch.object(r.subprocess, 'run', side_effect=responses) as run:
            self.assertTrue(r.check(self.app)['sandbox'])
            self.assertEqual(run.call_args_list[0].args[0][1:4], ['--verify', '--deep', '--strict'])
            self.assertEqual(run.call_count, 3)

    def test_failed_signature_and_timeout_stop_inspection(self):
        self.make_bundle()
        for error in [subprocess.CalledProcessError(1, 'codesign', stderr=b'private identity'),
                      subprocess.TimeoutExpired('codesign', 15)]:
            with patch.object(r.subprocess, 'run', side_effect=error) as run:
                with self.assertRaises(subprocess.SubprocessError): r.check(self.app)
                self.assertEqual(run.call_count, 1)

    def test_cli_failure_does_not_export_raw_signing_metadata(self):
        with patch.object(r.sys, 'argv', ['check-release-security.py']), \
             patch.object(r, 'check', side_effect=ValueError('private identity')), \
             patch('sys.stderr', new_callable=io.StringIO) as error, \
             patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(r.main(), 1)
            self.assertNotIn('private identity', error.getvalue())
            self.assertEqual(output.getvalue(), '')


if __name__ == '__main__':
    unittest.main()
