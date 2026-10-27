import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('chrome_memory_tests', Path(__file__).parents[1] / 'public-chrome-memory.py')
chrome = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chrome)


def observation():
    return dict(target='target-1', frame='frame-1', loader='loader-1', elapsed=10000, time=30,
                width=779, height=683, dpr=2, videoWidth=1280, videoHeight=720,
                muted=True, paused=False, rate=1, readyState=4, visible=True, loadedPages=4)


class ChromeMemoryTests(unittest.TestCase):
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
