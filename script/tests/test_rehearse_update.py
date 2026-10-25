import errno
import importlib.util
import pathlib
import tempfile
import unittest
import sys
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('rehearse_update',pathlib.Path(__file__).parents[1]/'rehearse-update.py')
r=importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class RehearsalTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=pathlib.Path(self.temporary.name).resolve()
        self.installed=self.root/'Installed.app';self.prepared=self.root/'Prepared.app'
        for path,payload in [(self.installed,'old payload'),(self.prepared,'new payload')]:
            path.mkdir();(path/'payload').write_text(payload)
        self.old={'treeSHA256':r.tree_digest(self.installed)}
        self.new={'treeSHA256':r.tree_digest(self.prepared)}
        self.sentinel=self.root/'synthetic-data';self.sentinel.write_text('untouched synthetic data')

    def inspect(self,path):return {'treeSHA256':r.tree_digest(path)}

    def exchange(self,a,b):
        # External atomic-exchange contract stub; the macOS tests exercise the real API.
        temporary=self.root/'swap-slot'
        a.rename(temporary);b.rename(a);temporary.rename(b)

    def apply(self,inspect=None,exchange=None):
        return r.checked_exchange(self.installed,self.prepared,self.old,self.new,
                                  inspect or self.inspect,exchange=exchange or self.exchange)

    def test_success_then_explicit_rollback_preserves_payloads_and_separate_data(self):
        self.apply()
        self.assertEqual(self.inspect(self.installed),self.new)
        self.assertEqual(self.inspect(self.prepared),self.old)
        r.checked_exchange(self.installed,self.prepared,self.new,self.old,self.inspect,exchange=self.exchange)
        self.assertEqual(self.inspect(self.installed),self.old)
        self.assertEqual(self.inspect(self.prepared),self.new)
        self.assertEqual(self.sentinel.read_text(),'untouched synthetic data')

    def test_changed_candidate_is_rejected_before_exchange(self):
        (self.prepared/'payload').write_text('corrupt')
        calls=[]
        with self.assertRaises(ValueError):self.apply(exchange=lambda *_:calls.append(1))
        self.assertEqual(calls,[])
        self.assertEqual(self.inspect(self.installed),self.old)

    def test_failed_exchange_keeps_known_original_slots(self):
        def fails(*_):raise OSError(errno.ENOSPC,'injected')
        with self.assertRaises(OSError):self.apply(exchange=fails)
        self.assertEqual(self.inspect(self.installed),self.old)
        self.assertEqual(self.inspect(self.prepared),self.new)

    def test_error_after_exchange_is_not_assumed_to_mean_nothing_changed(self):
        def changes_then_fails(a,b):
            self.exchange(a,b)
            raise OSError(errno.EIO,'injected after side effect')
        with self.assertRaises(r.RecoveryUncertain):self.apply(exchange=changes_then_fails)
        self.assertEqual(self.inspect(self.installed),self.new)
        self.assertEqual(self.inspect(self.prepared),self.old)

    def test_post_validation_failure_restores_original_slots(self):
        def rejects_new_at_destination(path):
            value=self.inspect(path)
            if path==self.installed and value==self.new:raise ValueError('injected post-check failure')
            return value
        with self.assertRaises(ValueError):self.apply(inspect=rejects_new_at_destination)
        self.assertEqual(self.inspect(self.installed),self.old)
        self.assertEqual(self.inspect(self.prepared),self.new)

    def test_rollback_failure_keeps_both_payloads_for_manual_inspection(self):
        calls=[]
        def fail_second(a,b):
            calls.append(1)
            if len(calls)>1:raise OSError(errno.EACCES,'injected rollback failure')
            self.exchange(a,b)
        def rejects_new(path):
            value=self.inspect(path)
            if path==self.installed and value==self.new:raise ValueError('injected post-check')
            return value
        with self.assertRaises(r.RecoveryUncertain):self.apply(inspect=rejects_new,exchange=fail_second)
        self.assertEqual(len(calls),2)
        self.assertEqual(self.inspect(self.installed),self.new)
        self.assertEqual(self.inspect(self.prepared),self.old)

    def test_unknown_post_swap_state_does_not_trigger_blind_rollback(self):
        calls=[]
        def damages_slot(a,b):
            calls.append(1);self.exchange(a,b);(a/'payload').write_text('unexpected third payload')
        with self.assertRaises(r.RecoveryUncertain):self.apply(exchange=damages_slot)
        self.assertEqual(len(calls),1)
        self.assertEqual(self.inspect(self.prepared),self.old)
        self.assertTrue(self.installed.exists())

    def test_external_absolute_and_dangling_links_and_special_files_are_rejected(self):
        for target in [str(self.root/'synthetic-data'),'../synthetic-data','missing']:
            link=self.prepared/'link';link.symlink_to(target)
            with self.subTest(target=target),self.assertRaises((ValueError,FileNotFoundError)):
                r.tree_digest(self.prepared)
            link.unlink()
        import os
        fifo=self.prepared/'fifo';os.mkfifo(fifo)
        with self.assertRaises(ValueError):r.tree_digest(self.prepared)

    def test_relative_internal_link_is_preserved_and_parent_escape_is_rejected(self):
        (self.prepared/'link').symlink_to('payload')
        self.assertIsInstance(r.tree_digest(self.prepared),str)
        with patch.object(r,'ROOT',self.root):
            self.assertEqual(r.within_project(self.installed),self.installed)
            with self.assertRaises(ValueError):r.within_project(self.root/'..'/'elsewhere')
            (self.root/'linked').symlink_to(self.prepared,target_is_directory=True)
            with self.assertRaises(ValueError):r.within_project(self.root/'linked')

    def test_rehearsal_does_not_offer_a_real_install_destination(self):
        with patch.object(sys,'platform','darwin'),patch.object(r,'ROOT',self.root):
            with self.assertRaises(ValueError):r.rehearse(pathlib.Path('/Applications/Levistica.app'))
        self.assertFalse((self.root/'.local').exists())


@unittest.skipUnless(sys.platform=='darwin','macOS atomic directory exchange')
class NativeExchangeTests(unittest.TestCase):
    def test_nonempty_directories_exchange_and_return_without_losing_either(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary).resolve();a=root/'old.app';b=root/'new.app'
            a.mkdir();b.mkdir();(a/'file').write_bytes(b'old');(b/'file').write_bytes(b'new')
            old,new=r.tree_digest(a),r.tree_digest(b)
            r.exchange_directories(a,b)
            self.assertEqual((r.tree_digest(a),r.tree_digest(b)),(new,old))
            r.exchange_directories(a,b)
            self.assertEqual((r.tree_digest(a),r.tree_digest(b)),(old,new))

    def test_missing_or_linked_slot_is_rejected_without_changing_existing_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary).resolve();a=root/'old.app';a.mkdir();(a/'file').write_text('old')
            old=r.tree_digest(a)
            with self.assertRaises((ValueError,OSError)):r.exchange_directories(a,root/'missing.app')
            link=root/'link.app';link.symlink_to(a,target_is_directory=True)
            with self.assertRaises(ValueError):r.exchange_directories(a,link)
            self.assertEqual(r.tree_digest(a),old)
