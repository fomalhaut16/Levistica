import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('chrome_memory_tests', Path(__file__).parents[1] / 'public-chrome-memory.py')
chrome = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chrome)


def observation():
    return dict(target='target-1', frame='frame-1', loader='loader-1', elapsed=10000, time=30,
                width=779, height=683, dpr=2, videoWidth=1280, videoHeight=720,
                muted=True, paused=False, rate=1, readyState=4, visible=True, loadedPages=4)


class ChromeMemoryTests(unittest.TestCase):
    def test_kernel_failure_reports_numeric_pid_errno_and_existence_only(self):
        error = OSError(2, 'private untrusted message')
        error.process_id = 456
        with patch.object(chrome.os, 'kill', side_effect=ProcessLookupError):
            result = chrome.failure_detail(error, 123)
        self.assertEqual(result, {'reason': 'kernel_executable_lookup_failed', 'pid': 456,
                                 'isRoot': False, 'errno': 2, 'existsNow': False})
        self.assertNotIn('private', str(result))

    def test_display_diagnostic_retains_counts_and_discards_mutable_labels(self):
        snapshot = {'identities': {10: {'executable': '/app/root'}, 20: {'executable': '/app/renderer'}}}
        with patch.object(chrome.m, 'run', return_value='10 /app/root\n20 mutable private label\n'):
            self.assertEqual(chrome.display_identity_counts(snapshot), {
                'processCount': 2, 'displayDiffersFromKernelPath': 1, 'displayIsNotAbsolutePath': 1})
        for output in ['10 /app/root\n', '10 /app/root\n10 duplicate\n', '30 foreign\n']:
            with patch.object(chrome.m, 'run', return_value=output), self.assertRaises(ValueError):
                chrome.display_identity_counts(snapshot)

    def test_failure_details_confirm_vanished_children_without_copying_messages(self):
        with patch.object(chrome.os, 'kill', side_effect=ProcessLookupError):
            result = chrome.failure_detail(ValueError('Process identity set changed; missing PIDs: 456'), 123)
        self.assertEqual(result, {'reason': 'process_identity_set_changed',
                                 'missingProcesses': [{'pid': 456, 'isRoot': False, 'existsNow': False}]})
        self.assertEqual(chrome.failure_detail(ValueError('private account or URL'), 123), {'reason': 'ValueError'})

    def test_unexpected_system_helpers_are_visible_but_user_paths_are_redacted(self):
        result = chrome.failure_detail(ValueError("Unexpected Chrome descendant executable: ['/usr/bin/helper', '/Users/private/name']"), 123)
        self.assertEqual(result, {'reason': 'unexpected_descendant',
                                 'systemPaths': ['/usr/bin/helper', '<non-system path>']})

    def test_only_the_expected_trial_and_phase_can_reach_capture(self):
        packet = {'phase': 'capture', 'runID': 'current', 'snapshot': observation()}
        chrome.validate_packet(packet, 'capture', 'current')
        for changed in [{'runID': 'old'}, {'phase': 'after'}, {'url': 'private'}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                chrome.validate_packet({**packet, **changed}, 'capture', 'current')

    def test_commit_requires_explicit_retained_document_confirmation(self):
        packet = {'phase': 'commit', 'runID': 'current', 'allFourTargetsAndLoadersRetained': True}
        chrome.validate_packet(packet, 'commit', 'current')
        for changed in [{'allFourTargetsAndLoadersRetained': False}, {'allFourTargetsAndLoadersRetained': 1},
                        {'snapshot': observation()}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                chrome.validate_packet({**packet, **changed}, 'commit', 'current')

    def test_opaque_cdp_identity_is_retained_without_native_uuid_conversion(self):
        before = observation()
        after = {**before, 'elapsed': 14000, 'time': 34}
        chrome.validate_observation(before)
        chrome.validate_observation(after, before)
        for key, value in [('target', 'other'), ('frame', 'other'), ('loader', 'other'),
                           ('elapsed', 9000), ('time', 80), ('paused', True), ('visible', False),
                           ('width', 1000), ('videoHeight', 480), ('loadedPages', 3),
                           ('readyState', True), ('time', float('nan')), ('time', 10 ** 1000)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                chrome.validate_observation({**after, key: value}, before)

    def test_unknown_strings_and_fields_cannot_enter_an_observation(self):
        for value in [{**observation(), 'url': 'private'}, {**observation(), 'loader': 'line\nbreak'},
                      {**observation(), 'target': 'x' * 129}, {**observation(), 'muted': 1}]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                chrome.validate_observation(value)

    def test_renderer_role_requires_an_owned_application_path(self):
        paths = {1: {'executable': str(chrome.BINARY)},
                 2: {'executable': str(chrome.APP / 'Contents/Helpers/Google Chrome Helper (Renderer)')},
                 3: {'executable': '/outside/Google Chrome Helper (Renderer)'},
                 4: {'executable': str(chrome.APP / 'Contents/Helpers/Google Chrome Helper (GPU)')}}
        state = {'identities': paths}
        self.assertEqual(chrome.chrome_role(1, 1, state), 'UI')
        self.assertEqual(chrome.chrome_role(2, 1, state), 'Renderer')
        self.assertEqual(chrome.chrome_role(3, 1, state), 'Owned XPC helper')
        self.assertEqual(chrome.chrome_role(4, 1, state), 'GPU')

    def test_only_project_local_fresh_profile_paths_are_accepted(self):
        root = chrome.ROOT / '.local/artifacts/public-four-page-memory-chrome.test'
        owner = dict(pid=123, executable=str(chrome.BINARY), started='birth', port=12345,
                     runID='01234567-89ab-cdef-0123-456789abcdef', profile=str(root / 'profile'))
        self.assertEqual(chrome.owner_paths(root / 'memory-owner.json', owner)[1], root / 'profile')
        for changed in [{'profile': '/outside/profile'}, {'pid': True}, {'port': 0},
                        {'executable': '/outside/Chrome'}, {'started': ''}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                chrome.owner_paths(root / 'memory-owner.json', {**owner, **changed})
        with self.assertRaises(ValueError):
            chrome.owner_paths(chrome.ROOT / 'memory-owner.json', owner)


if __name__ == '__main__':
    unittest.main()
