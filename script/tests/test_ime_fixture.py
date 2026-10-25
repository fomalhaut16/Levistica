import copy
import http.client
import importlib.util
import json
import pathlib
import threading
import unittest

spec = importlib.util.spec_from_file_location('ime_fixture_test', pathlib.Path(__file__).parents[1] / 'test-fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def metadata():
    return {'events': [{'control': 'ime-editor', 'type': 'keydown', 'trusted': True,
                        'enter': True, 'isComposing': False, 'processKey': True}],
            'fields': [{'control': name, 'sends': 0, 'lastLength': 0, 'currentLength': 5}
                       for name in ('ime-input', 'ime-textarea', 'ime-editor')]}


class IMEMetadataTests(unittest.TestCase):
    def test_accepts_categories_and_counts_without_input_text(self):
        value = metadata()
        self.assertEqual(fixture.ime_metadata(json.dumps(value)), value)

    def test_text_unknown_fields_and_invalid_types_are_rejected(self):
        for target, key, value in [('event', 'data', 'PRIVATE-TEXT'), ('event', 'key', 'PRIVATE-TEXT'),
                                   ('event', 'trusted', 'true'), ('field', 'text', 'PRIVATE-TEXT'),
                                   ('field', 'currentLength', True), ('field', 'lastLength', -1)]:
            data = metadata()
            data['events' if target == 'event' else 'fields'][0][key] = value
            with self.subTest(target=target, key=key):
                self.assertIsNone(fixture.ime_metadata(json.dumps(data)))
        for data in [[], {}, {'events': [], 'fields': []}]:
            self.assertIsNone(fixture.ime_metadata(json.dumps(data)))

    def test_unknown_controls_duplicate_fields_and_excess_events_are_rejected(self):
        for change in ('control', 'duplicate', 'events'):
            data = metadata()
            if change == 'control':data['events'][0]['control'] = 'another-control'
            elif change == 'duplicate':data['fields'][1] = copy.deepcopy(data['fields'][0])
            else:data['events'] *= 241
            self.assertIsNone(fixture.ime_metadata(json.dumps(data)))


class IMEHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = fixture.FixtureHTTPServer(('127.0.0.1', 0), fixture.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.thread.join(timeout=2); cls.server.server_close()

    def request(self, method, body=None, origin=True):
        client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            headers = {'Origin': f'http://127.0.0.1:{self.server.server_port}'} if origin else {}
            client.request(method, '/ime-result', body=body, headers=headers)
            response = client.getresponse()
            return response.status, response.read()
        finally:
            client.close()

    def test_round_trip_returns_only_validated_metadata(self):
        data = metadata()
        self.assertEqual(self.request('POST', json.dumps(data))[0], 204)
        status, body = self.request('GET')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {'status': 'recorded', 'result': data})

    def test_wrong_origin_malformed_or_large_body_cannot_store_text(self):
        before = copy.deepcopy(self.server.ime_result)
        for body, origin, expected in [(json.dumps(metadata()), False, 403), ('not json', True, 400),
                                        ('x' * 65537, True, 413), (json.dumps({'text': 'PRIVATE-TEXT'}), True, 400)]:
            status, response = self.request('POST', body, origin=origin)
            self.assertEqual(status, expected)
            self.assertNotIn(b'PRIVATE-TEXT', response)
            self.assertEqual(self.server.ime_result, before)
