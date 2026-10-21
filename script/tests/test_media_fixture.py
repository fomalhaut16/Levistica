import copy
import importlib.util
import pathlib
import unittest


def module(filename, name):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).parents[1] / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


media = module('media-fixture.py', 'media_fixture')
measure = module('measure-memory.py', 'media_measure')


class MediaFixtureTests(unittest.TestCase):
    def fixture(self):
        return {'kind': 'video', 'media_sha256': 'synthetic', 'media_bytes': 100,
                'document_sha256': 'page', 'loads': 1, 'url': 'http://127.0.0.1:1/video',
                'ready_monotonic': 10, 'last_report_monotonic': 99.5, 'last_progress_monotonic': 99.5,
                'playback': {'width': 779, 'height': 683, 'dpr': 2, 'visibility': 'visible',
                             'paused': False, 'ended': False, 'readyState': 4, 'muted': True,
                             'playbackRate': 1, 'videoWidth': 1280, 'videoHeight': 720}}

    def test_byte_ranges_support_seek_suffix_and_end_clamping(self):
        for header, expected in [(None, (0, 99)), ('bytes=0-1', (0, 1)),
                                 ('bytes=80-', (80, 99)), ('bytes=-10', (90, 99)),
                                 ('bytes=80-200', (80, 99))]:
            self.assertEqual(media.byte_range(header, 100), expected)
        for header in ['bytes=100-', 'bytes=2-1', 'bytes=-0', 'bytes=-', 'bytes=0-1,3-4']:
            with self.assertRaises(ValueError):
                media.byte_range(header, 100)

    def test_advancing_reports_preserve_fixed_workload_identity(self):
        original = self.fixture()
        current = copy.deepcopy(original)
        current['last_report_monotonic'] = 100
        current['playback']['frames'] = 3000
        measure.check_fixture(current, original, now=100)

    def test_stale_paused_hidden_rate_or_viewport_changes_are_rejected(self):
        original = self.fixture()
        cases = [('last_report_monotonic', 90), ('last_progress_monotonic', 90),
                 ('loads', 2), ('media_sha256', 'different')]
        for key, value in cases:
            current = copy.deepcopy(original)
            current[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                measure.check_fixture(current, original, now=100)
        for key, value in [('paused', True), ('visibility', 'hidden'), ('playbackRate', 2),
                           ('videoWidth', 1920), ('width', 1000), ('ended', True)]:
            current = copy.deepcopy(original)
            current['playback'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                measure.check_fixture(current, original, now=100)

    def test_document_fixture_still_requires_exact_identity(self):
        original = {'ready_monotonic': 10, 'viewport': {'sections': 240, 'visibility': 'visible'}}
        measure.check_fixture(original, original)
        with self.assertRaises(ValueError):
            measure.check_fixture({**original, 'loads': 2}, original)
