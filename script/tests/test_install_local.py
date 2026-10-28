import errno
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('install_local', Path(__file__).parents[1] / 'install-local.py')
i = importlib.util.module_from_spec(spec)
spec.loader.exec_module(i)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.app = self.root / 'package/unpacked/Levistica.app'
        self.app.mkdir(parents=True)
        (self.app / 'payload').write_bytes(b'synthetic app content')
        self.directory = self.root / 'Applications'
        self.directory.mkdir()
        self.destination = self.directory / 'Levistica.app'
        self.facts = {'source': 'a'*40, 'sandbox': True, 'hardenedRuntime': True, 'adHocSignature': True}
        self.commands = []
        for target, name, value in [(i, 'ROOT', self.root), (i.startup.bundle_rehearsal, 'ROOT', self.root),
                                     (i.sys, 'platform', 'darwin')]:
            patcher = patch.object(target, name, value)
            patcher.start(); self.addCleanup(patcher.stop)

    def copy(self, command, **kwargs):
        self.commands.append(command)
        self.assertEqual(command[0], '/usr/bin/ditto')
        shutil.copytree(command[1], command[2])

    def promote(self, source, destination):
        # The real macOS exclusive primitive is tested separately below.
        if os.path.lexists(destination): raise FileExistsError(errno.EEXIST, 'existing')
        source.rename(destination)

    def invoke(self, promote=None, inspect=None, candidates=None, copy=None):
        with patch.object(i.startup, 'package_bundle', return_value=self.app), \
             patch.object(i, 'applications_directory', return_value=self.directory), \
             patch.object(i, 'inspect', side_effect=inspect or (lambda _: self.facts)), \
             patch.object(i.startup, 'candidates', side_effect=candidates or (lambda: [])), \
             patch.object(i.subprocess, 'run', side_effect=copy or self.copy), \
             patch.object(i, 'promote_new', side_effect=promote or self.promote):
            return i.install(self.root / 'package')

    def test_first_install_preserves_source_and_does_not_launch(self):
        result = self.invoke()
        self.assertTrue(result['success'])
        self.assertFalse(result['existingAppReplaced'])
        self.assertFalse(result['appLaunched'])
        self.assertEqual((self.destination / 'payload').read_bytes(), b'synthetic app content')
        self.assertEqual((self.app / 'payload').read_bytes(), b'synthetic app content')
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(list(self.directory.glob('.Levistica-install-*')), [])
        evidence = next(self.root.glob('.local/artifacts/local-install.*/result.json'))
        self.assertEqual(evidence.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(evidence.read_text()), result)

    def test_existing_destination_and_broken_symlink_are_never_replaced(self):
        for kind in ['directory', 'broken-link']:
            with self.subTest(kind=kind):
                if kind == 'directory': self.destination.mkdir()
                else: self.destination.symlink_to(self.root / 'missing')
                with self.assertRaises(ValueError): self.invoke()
                self.assertTrue(os.path.lexists(self.destination))
                self.assertEqual(self.commands, [])
                if kind == 'directory': self.destination.rmdir()
                else: self.destination.unlink()

    def test_running_app_prevents_copy_without_stopping_it(self):
        with self.assertRaises(ValueError): self.invoke(candidates=lambda: [(123, '/synthetic/app')])
        self.assertEqual(self.commands, [])
        self.assertFalse(self.destination.exists())

    def test_process_appearing_before_promotion_keeps_prepared_copy(self):
        calls = iter([[], [(123, '/synthetic/app')]])
        result = self.invoke(candidates=lambda: next(calls))
        self.assertFalse(result['success'])
        self.assertFalse(self.destination.exists())
        self.assertTrue(Path(result['preparedDirectory']).is_dir())

    def test_racing_destination_wins_and_has_no_fallback_replacement(self):
        def race(source, destination):
            destination.mkdir()
            (destination / 'keep').write_text('existing content')
            raise FileExistsError(errno.EEXIST, 'injected race')
        result = self.invoke(promote=race)
        self.assertFalse(result['success'])
        self.assertEqual((self.destination / 'keep').read_text(), 'existing content')
        self.assertEqual(len(list(self.directory.glob('.Levistica-install-*/Levistica.app'))), 1)

    def test_damaged_copy_never_reaches_destination(self):
        def corrupt(command, **kwargs):
            self.copy(command, **kwargs)
            (Path(command[-1]) / 'payload').write_bytes(b'damaged')
        result = self.invoke(copy=corrupt)
        self.assertFalse(result['success'])
        self.assertFalse(self.destination.exists())
        self.assertEqual((self.app / 'payload').read_bytes(), b'synthetic app content')

    def test_failed_prepared_signature_never_promotes(self):
        def check(path):
            if path != self.app: raise ValueError('private metadata must not be logged')
            return self.facts
        result = self.invoke(inspect=check)
        self.assertFalse(result['success'])
        self.assertFalse(self.destination.exists())
        self.assertNotIn('private metadata', str(result))

    def test_post_install_verification_failure_retains_destination_for_inspection(self):
        def check(path):
            if path == self.destination: raise ValueError('injected post-check failure')
            return self.facts
        result = self.invoke(inspect=check)
        self.assertFalse(result['success'])
        self.assertTrue(result['manualInspectionRequired'])
        self.assertTrue(self.destination.is_dir())
        self.assertEqual(result['phase'], 'verify_installed')

    def test_unsupported_rename_retains_prepared_app_without_fallback(self):
        def fail(*_): raise OSError(errno.ENOTSUP, 'injected unsupported rename')
        result = self.invoke(promote=fail)
        self.assertFalse(result['success'])
        self.assertFalse(self.destination.exists())
        self.assertTrue((Path(result['preparedDirectory']) / 'Levistica.app').is_dir())

    def test_user_applications_rejects_shared_or_linked_parent(self):
        home = self.root / 'home'; home.mkdir()
        applications = home / 'Applications'; applications.mkdir()
        with patch.object(i.Path, 'home', return_value=home):
            self.assertEqual(i.applications_directory(), applications)
            applications.chmod(0o777)
            with self.assertRaises(ValueError): i.applications_directory()
            applications.rmdir()
            applications.symlink_to(self.directory, target_is_directory=True)
            with self.assertRaises(ValueError): i.applications_directory()


@unittest.skipUnless(sys.platform == 'darwin', 'Real exclusive rename requires macOS')
class ExclusivePromotionTests(unittest.TestCase):
    def test_existing_empty_directory_is_not_replaced_then_absent_target_is_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / 'prepared'; source.mkdir(); (source / 'keep').write_text('new')
            target = root / 'installed'; target.mkdir()
            with self.assertRaises(OSError): i.promote_new(source, target)
            self.assertTrue(source.is_dir())
            self.assertEqual(list(target.iterdir()), [])
            target.rmdir()
            i.promote_new(source, target)
            self.assertFalse(source.exists())
            self.assertEqual((target / 'keep').read_text(), 'new')

    def test_symlink_parent_is_not_followed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / 'prepared'; source.mkdir()
            actual = root / 'actual'; actual.mkdir()
            linked = root / 'linked'; linked.symlink_to(actual, target_is_directory=True)
            with self.assertRaises(OSError): i.promote_new(source, linked / 'installed')
            self.assertTrue(source.is_dir())
            self.assertEqual(list(actual.iterdir()), [])
