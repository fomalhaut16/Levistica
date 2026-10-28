import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('package_local', Path(__file__).parents[1] / 'package-local.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
EXECUTABLE = 'Levistica.app/Contents/MacOS/Levistica'


class ZipValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.zip = Path(self.temp.name) / 'app.zip'

    def archive(self, names):
        with zipfile.ZipFile(self.zip, 'w') as output:
            output.writestr(EXECUTABLE, b'executable')
            for name, mode in names:
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                output.writestr(info, b'' if name.endswith('/') else b'data')

    def test_app_with_platform_metadata(self):
        self.archive([('Levistica.app/Contents/', stat.S_IFDIR | 0o755),
                      ('__MACOSX/Levistica.app/Contents/._Info.plist', stat.S_IFREG | 0o600)])
        p.validate_zip(self.zip)

    def test_unsafe_names_types_and_aliases_rejected(self):
        cases = [('../escape', 0), ('/absolute', 0), ('Levistica.app/../escape', 0),
                 ('Levistica.app/a\\b', 0), ('Levistica.app/a:b', 0),
                 ('other/payload', 0), ('__MACOSX/other/._payload', 0),
                 ('__MACOSX/Levistica.app/payload', 0),
                 ('Levistica.app/link', stat.S_IFLNK | 0o777),
                 ('Levistica.app/device', stat.S_IFCHR | 0o600),
                 ('Levistica.app/setuid', stat.S_IFREG | 0o4755),
                 ('Levistica.app/wrong/', stat.S_IFREG | 0o600),
                 ('levistica.app/new', 0), ('Levistica.app/contents/new', 0),
                 ('Levistica.app/Contents', stat.S_IFREG | 0o600)]
        for entry in cases:
            with self.subTest(entry=entry):
                self.archive([entry])
                with self.assertRaises(ValueError):
                    p.validate_zip(self.zip)

    def test_unicode_alias_rejected(self):
        self.archive([('Levistica.app/caf\u00e9', 0), ('Levistica.app/cafe\u0301', 0)])
        with self.assertRaises(ValueError): p.validate_zip(self.zip)

    def test_missing_executable_rejected(self):
        with zipfile.ZipFile(self.zip, 'w') as output: output.writestr('Levistica.app/data', b'data')
        with self.assertRaises(ValueError): p.validate_zip(self.zip)

    def test_corrupt_payload_rejected(self):
        self.archive([])
        data = self.zip.read_bytes().replace(b'executable', b'executablX', 1)
        self.zip.write_bytes(data)
        with self.assertRaises((ValueError, zipfile.BadZipFile)): p.validate_zip(self.zip)

    def test_entry_limit_rejected(self):
        self.archive([(f'Levistica.app/data{i}', 0) for i in range(4002)])
        with self.assertRaises(ValueError): p.validate_zip(self.zip)


class PackagePipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.archive = self.root / '.local/archives/local-abcdef12/Levistica.xcarchive'
        self.app = self.archive / 'Products/Applications/Levistica.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/Levistica').write_bytes(b'executable')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.0'}))
        self.original = p.bundles.tree_digest(self.app)
        for target, name, value in [(p, 'ROOT', self.root), (p.bundles, 'ROOT', self.root),
                                    (p.sys, 'platform', 'darwin')]:
            patcher = patch.object(target, name, value)
            patcher.start(); self.addCleanup(patcher.stop)
        self.commands = []

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == '/usr/bin/ditto' and '-c' in command:
            with zipfile.ZipFile(command[-1], 'w') as output:
                for file in self.app.rglob('*'):
                    output.write(file, 'Levistica.app/' + str(file.relative_to(self.app)))
        elif command[0] == '/usr/bin/ditto':
            shutil.copytree(self.app, Path(command[-1]) / 'Levistica.app')
        elif command[:4] != ['/usr/bin/codesign', '--verify', '--deep', '--strict']:
            self.fail('Unexpected command or side effect: ' + repr(command))

    def invoke(self):
        with patch.object(p.security, 'check', return_value={'source': 'a'*40, 'sandbox': True,
                          'hardenedRuntime': True, 'adHocSignature': True}), \
             patch.object(p.subprocess, 'run', side_effect=self.run_command):
            return p.package(self.archive)

    def test_roundtrip_manifest_and_original_preserved_without_launch(self):
        result = self.invoke()
        self.assertTrue(result['roundtripVerified'])
        self.assertFalse(result['appLaunched'])
        self.assertFalse(result['published'])
        self.assertEqual(p.bundles.tree_digest(self.app), self.original)
        manifests = list((self.root / '.local/packages').glob('*/manifest.json'))
        self.assertEqual(len(manifests), 1)
        self.assertEqual(json.loads(manifests[0].read_text()), result)
        self.assertEqual(manifests[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(self.commands), 3)

    def test_roundtrip_failure_does_not_produce_completed_package(self):
        original_run = self.run_command
        def corrupt(command, **kwargs):
            original_run(command, **kwargs)
            if '-x' in command:
                (Path(command[-1]) / EXECUTABLE).write_bytes(b'changed')
        with patch.object(self, 'run_command', side_effect=corrupt):
            with self.assertRaises(ValueError): self.invoke()
        self.assertEqual(list(self.root.glob('.local/packages/*/manifest.json')), [])
        self.assertEqual(list(self.root.glob('.local/packages/*/Levistica-*.zip')), [])
        self.assertEqual(len(list(self.root.glob('.local/packages/*/failure.json'))), 1)
        self.assertEqual(p.bundles.tree_digest(self.app), self.original)

    def test_failed_signature_has_no_success_manifest(self):
        original_run = self.run_command
        def reject_signature(command, **kwargs):
            if command[0] == '/usr/bin/codesign':
                raise p.subprocess.CalledProcessError(1, command)
            original_run(command, **kwargs)
        with patch.object(self, 'run_command', side_effect=reject_signature):
            with self.assertRaises(p.subprocess.CalledProcessError): self.invoke()
        self.assertEqual(list(self.root.glob('.local/packages/*/manifest.json')), [])
        self.assertEqual(list(self.root.glob('.local/packages/*/Levistica-*.zip')), [])
        failure = json.loads(next(self.root.glob('.local/packages/*/failure.json')).read_text())
        self.assertEqual(failure['phase'], 'verify_roundtrip')

    def test_invalid_zip_is_rejected_before_extraction(self):
        with patch.object(p, 'validate_zip', side_effect=ValueError('injected invalid ZIP')):
            with self.assertRaises(ValueError): self.invoke()
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(list(self.root.glob('.local/packages/*/unpacked')), [])

    def test_symlinked_archive_parent_rejected(self):
        linked = self.root / 'linked'
        linked.symlink_to(self.root / '.local/archives', target_is_directory=True)
        self.archive = linked / 'local-abcdef12/Levistica.xcarchive'
        with self.assertRaises(ValueError): self.invoke()
        self.assertEqual(self.commands, [])

    def test_hardlink_rejected_before_any_external_command(self):
        os.link(self.app / 'Contents/MacOS/Levistica', self.root / 'hardlink')
        with self.assertRaises(ValueError): self.invoke()
        self.assertEqual(self.commands, [])

    def test_archive_outside_formal_directory_rejected(self):
        self.archive = self.root / 'Levistica.xcarchive'
        with self.assertRaises(ValueError): self.invoke()
        self.assertEqual(self.commands, [])


if __name__ == '__main__': unittest.main()
