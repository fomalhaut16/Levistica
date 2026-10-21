import copy
import http.client
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile
import threading
import unittest
import uuid


def module(filename, name):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).parents[1] / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


fixture = module('cross-site-fixture.py', 'cross_site_fixture')
measure = module('measure-memory.py', 'cross_site_measure')


class CrossSiteFixtureTests(unittest.TestCase):
    count = 5

    @unittest.skipUnless(shutil.which('node'), 'Node is only needed for generated JavaScript syntax checks')
    def test_generated_scripts_parse_without_running_page_code(self):
        for key in fixture.hosts(20):
            source = fixture.document(key).decode().split('<script>', 1)[1].split('</script>', 1)[0]
            result = subprocess.run(['node', '--check'], input=source, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.folder.name) / 'state.json'
        self.server = fixture.create_server(self.path, self.count)
        self.worker = threading.Thread(target=self.server.serve_forever)
        self.worker.start()
        self.origins = self.state()['origins']

    def tearDown(self):
        self.server.stopping.set()
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=5)
        self.folder.cleanup()

    def state(self):
        return json.loads(self.path.read_text())

    def report(self, key):
        return {'instance': str(uuid.uuid4()), 'pulse': 1, 'seenVisible': True, 'complete': True,
                'sections': 240, 'width': 779, 'height': 683, 'dpr': 2,
                'visibility': 'visible' if key == str(self.count) else 'hidden'}

    def request(self, method, path, key='1', data=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        fields = {'Host': f'{fixture.hosts(self.count)[key]}:{self.server.server_port}',
                  'Content-Type': 'application/json', 'Origin': self.origins[key]}
        fields.update(headers or {})
        connection.request(method, path, body=json.dumps(data) if data is not None else None, headers=fields)
        response = connection.getresponse()
        if path.startswith('/events/') and response.status == 200:
            body = response.readline() + response.readline()
        else:
            body = response.read()
        status = response.status
        connection.close()
        return status, body

    def ready(self):
        for key in fixture.hosts(self.count):
            self.assertEqual(self.request('GET', '/document/' + key, key)[0], 200)
            self.assertEqual(self.request('GET', '/events/' + key, key)[1], b'data: 1\n\n')
            self.assertEqual(self.request('POST', '/report/' + key, key, self.report(key))[0], 204)
        return self.state()

    def test_fixed_documents_use_assigned_hosts_and_one_loopback_listener(self):
        self.assertEqual(self.server.server_address[0], '127.0.0.1')
        for key in fixture.hosts(self.count):
            status, body = self.request('GET', '/document/' + key, key)
            self.assertEqual(status, 200)
            self.assertEqual(body, fixture.document(key))
            self.assertEqual(body.count(b'<section>'), 240)
            self.assertNotIn(b'BroadcastChannel', body)
        self.assertEqual(self.request('GET', '/document/1', '2')[0], 404)
        self.assertEqual(self.request('GET', '/document/1', headers={'Host': 'example.com'})[0], 404)
        self.assertEqual(self.state()['loads'], self.count)
        for path in ('/document/0', '/document/01', '/document/' + str(self.count + 1)):
            self.assertEqual(self.request('GET', path)[0], 404)

    def test_origin_content_and_field_validation_rejects_bad_reports(self):
        valid = self.report('1')
        for headers in ({'Origin': 'https://example.com'}, {'Content-Type': 'text/plain'}, {'Host': 'example.com'}):
            self.assertIn(self.request('POST', '/report/1', data=valid, headers=headers)[0], (400, 403))
        for key, value in [('instance', 'not-a-uuid'), ('width', float('nan')), ('height', 0),
                           ('dpr', True), ('pulse', -1), ('sections', 239), ('complete', 1)]:
            with self.subTest(key=key):
                self.assertEqual(self.request('POST', '/report/1', data={**valid, key: value})[0], 400)
        self.assertEqual(self.state()['documents'], {})

    def test_ready_requires_every_document_and_accepts_pulse_progress(self):
        state = self.ready()
        measure.check_fixture(state)
        for key in fixture.hosts(self.count):
            data = {k: v for k, v in state['documents'][key].items() if k not in ('origin', 'reported_monotonic')}
            data['pulse'] = 2
            self.assertEqual(self.request('POST', '/report/' + key, key, data)[0], 204)
        measure.check_fixture(self.state(), state)

    def test_measurement_rejects_stale_reloaded_reconnected_or_wrong_host_data(self):
        state = self.ready()
        for key, value in [('loads', self.count + 1), ('transport', 'other'), ('run_id', 'other'),
                           ('invalid_reason', 'changed')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                measure.check_fixture({**state, key: value}, state)
        for key, value in [('origin', self.origins['2']), ('pulse', 0),
                           ('seenVisible', False), ('reported_monotonic', 0), ('width', 800)]:
            changed = copy.deepcopy(state)
            changed['documents']['1'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                measure.check_fixture(changed, state)
        changed = copy.deepcopy(state)
        changed['urls']['1'] = changed['urls']['2']
        with self.assertRaises(ValueError):
            measure.check_fixture(changed)
        changed = copy.deepcopy(state)
        changed['documents']['1']['visibility'] = 'visible'
        changed['documents'][str(self.count)]['visibility'] = 'hidden'
        with self.assertRaises(ValueError):
            measure.check_fixture(changed)
        changed = copy.deepcopy(state)
        changed['stream_connections']['1'] = True
        with self.assertRaises(ValueError):
            measure.check_fixture(changed)
        self.assertEqual(self.request('GET', '/events/1')[0], 409)
        with self.assertRaises(ValueError):
            measure.check_fixture(self.state())

    def test_new_instance_is_permanently_marked_invalid(self):
        self.ready()
        self.assertEqual(self.request('POST', '/report/1', data=self.report('1'))[0], 204)
        with self.assertRaises(ValueError):
            measure.check_fixture(self.state())

    def test_count_is_bounded_and_cannot_change_during_sampling(self):
        state = self.ready()
        for count in (0, 1, 19, 21, True, 5.0, '20', None):
            with self.subTest(count=count), self.assertRaises(ValueError):
                fixture.hosts(count)
            with self.subTest(count=count), self.assertRaises(ValueError):
                measure.check_fixture({**state, 'expected_tabs': count})
        other = copy.deepcopy(state)
        other['expected_tabs'] = 20 if self.count == 5 else 5
        with self.assertRaises(ValueError):
            measure.check_fixture(other, state)
        if self.count == 20:
            with self.assertRaises(ValueError):
                measure.check_fixture({**state, 'kind': 'documents'})
            self.assertEqual(self.request('GET', '/document/20', '19')[0], 404)


class TwentyDocumentFixtureTests(CrossSiteFixtureTests):
    count = 20


if __name__ == '__main__':
    unittest.main()
