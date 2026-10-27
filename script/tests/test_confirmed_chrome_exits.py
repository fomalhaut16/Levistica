import importlib.util
import pathlib
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('confirmed_exit_test', pathlib.Path(__file__).parents[1] / 'measure-memory.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ConfirmedChromeExitTests(unittest.TestCase):
    def test_only_all_demonstrably_absent_owned_children_are_classified(self):
        error = m.ProcessIdentitySetChanged({2, 3})
        with patch.object(m.os, 'kill', side_effect=ProcessLookupError) as exists:
            with self.assertRaises(m.ConfirmedExitedChromeDescendants) as caught:
                m.classify_chrome_child_exit(error, 1, {1, 2, 3}, [])
        self.assertEqual(caught.exception.pids, (2, 3))
        self.assertEqual({c.args for c in exists.call_args_list}, {(2, 0), (3, 0)})

    def test_root_services_and_unowned_missing_pids_are_never_reclassified(self):
        for missing, services in [({1}, []), ({9}, []), ({2}, [{'pid': 2}]), (set(), [])]:
            error = m.ProcessIdentitySetChanged(missing)
            with self.subTest(missing=missing, services=services), patch.object(m.os, 'kill') as exists:
                with self.assertRaises(m.ProcessIdentitySetChanged) as caught:
                    m.classify_chrome_child_exit(error, 1, {1, 2}, services)
                self.assertIs(caught.exception, error)
                exists.assert_not_called()

    def test_present_reused_zombie_or_unverifiable_pids_remain_failures(self):
        for effect in [None, PermissionError]:
            error = m.ProcessIdentitySetChanged({2})
            with self.subTest(effect=effect), patch.object(m.os, 'kill', side_effect=effect):
                with self.assertRaises(m.ProcessIdentitySetChanged) as caught:
                    m.classify_chrome_child_exit(error, 1, {1, 2}, [])
                self.assertIs(caught.exception, error)

    def test_only_kernel_missing_process_errors_can_be_confirmed(self):
        for errno, has_pid, qualifies in [(2, True, True), (3, True, True), (13, True, False), (2, False, False)]:
            error = OSError(errno, 'fixed kernel failure')
            if has_pid: error.process_id = 2
            with self.subTest(errno=errno, has_pid=has_pid), patch.object(m.os, 'kill', side_effect=ProcessLookupError) as exists:
                if qualifies:
                    with self.assertRaises(m.ConfirmedExitedChromeDescendants):
                        m.classify_chrome_child_exit(error, 1, {1, 2}, [])
                else:
                    with self.assertRaises(OSError) as caught:
                        m.classify_chrome_child_exit(error, 1, {1, 2}, [])
                    self.assertIs(caught.exception, error)
                    exists.assert_not_called()

    def test_unknown_path_and_signing_failures_are_not_exits(self):
        error = ValueError('Signing identity changed')
        with patch.object(m.os, 'kill') as exists:
            with self.assertRaises(ValueError) as caught:
                m.classify_chrome_child_exit(error, 1, {1, 2}, [])
            self.assertIs(caught.exception, error)
            exists.assert_not_called()

    def test_snapshot_never_returns_a_partial_set_when_a_child_disappears(self):
        app = pathlib.Path('/synthetic/Chrome.app')
        domain = 'pid/100 = {\n\toriginator = /synthetic/Chrome.app\n\tcreator = Google Chrome[100]\n\tservices = {\n\t}\n}'
        def query(args):
            if args[0] == '/bin/launchctl': return domain
            if '-axo' in args: return '100 1 S Chrome\n200 100 S Renderer\n'
            return '--user-data-dir=/owned-profile'
        full = {100: {'started': 'root', 'executable': str(app / 'Contents/MacOS/Chrome')},
                200: {'started': 'child', 'executable': str(app / 'Contents/Renderer')}}
        for effects in [[m.ProcessIdentitySetChanged({200})], [full, m.ProcessIdentitySetChanged({200})]]:
            with self.subTest(stage=len(effects)), patch.object(m, 'run', side_effect=query), \
                 patch.object(m, 'identities', side_effect=effects), patch.object(m.os, 'kill', side_effect=ProcessLookupError):
                with self.assertRaises(m.ConfirmedExitedChromeDescendants):
                    m.snapshot(100, app, app / 'Contents/MacOS/Chrome', pathlib.Path('/owned-profile'))
