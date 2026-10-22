import copy
import hashlib
import http.client
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import uuid


def module(filename, name):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).parents[1] / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


measure = module('measure-memory.py', 'sleep_memory_measure')
fixture = module('cross-site-fixture.py', 'sleep_document_fixture')
contract = measure.sleep_contract()


def workload():
    keys = sorted(contract.KEYS)
    origins = {k: f'http://document-{k}.localhost:7777' for k in keys}
    return {'kind': 'sleep-documents', 'transport': 'same-origin-sse-lifecycle-v1',
            'expected_tabs': 5, 'run_id': 'synthetic-run', 'ready_monotonic': 99,
            'loads': 5, 'document_loads': dict.fromkeys(keys, 1),
            'stream_connections': dict.fromkeys(keys, 1), 'active_streams': dict.fromkeys(keys, 1),
            'origins': origins, 'urls': {k: origins[k] + '/document/' + k for k in keys},
            'document_hashes': {k: hashlib.sha256(k.encode()).hexdigest() for k in keys},
            'documents': {k: {'instance': str(uuid.uuid4()), 'pulse': 10, 'seenVisible': True,
                              'width': 799, 'height': 683, 'dpr': 2, 'sections': 240,
                              'visibility': 'visible' if k == '5' else 'hidden', 'complete': True,
                              'origin': origins[k], 'reported_monotonic': 99,
                              'firstVisibleReadyMS': 20} for k in keys}}


class SleepContractTests(unittest.TestCase):
    def setUp(self):
        state = workload()
        self.phase = {'kind': 'manual-sleep', 'ready_monotonic': 101,
                      'sleep_checkpoint': contract.capture(state, measure.check_fixture, now=100),
                      'sleeping_documents': [], 'memory_pressure_level': 1, 'workload': state}

    def sleeping(self):
        phase = copy.deepcopy(self.phase)
        phase['sleeping_documents'] = ['1', '2', '3', '4']
        phase['workload']['active_streams'].update(dict.fromkeys(phase['sleeping_documents'], 0))
        phase['workload']['documents']['5'].update(reported_monotonic=119, pulse=20)
        return phase

    def test_loaded_and_sleeping_contracts_and_live_pulse_progress(self):
        measure.check_fixture(self.phase, now=102)
        asleep = self.sleeping()
        measure.check_fixture(asleep, now=120)
        later = copy.deepcopy(asleep)
        later['workload']['documents']['5'].update(reported_monotonic=124, pulse=23)
        measure.check_fixture(later, asleep, now=125)

    def test_disposed_selected_page_can_retain_last_visible_report_but_cannot_report_again(self):
        asleep = self.sleeping()
        for key in asleep['sleeping_documents']:
            asleep['workload']['documents'][key]['visibility'] = 'visible'
        measure.check_fixture(asleep, now=120)
        changed = copy.deepcopy(asleep)
        changed['workload']['documents']['1']['visibility'] = 'hidden'
        with self.assertRaises(ValueError):
            measure.check_fixture(changed, asleep, now=120)

    def test_rejects_wrong_sleep_set_pressure_and_phase_time(self):
        for field, value in [('sleeping_documents', ['1']), ('sleeping_documents', ['1', '2', '3', '5']),
                             ('memory_pressure_level', True), ('memory_pressure_level', 2),
                             ('ready_monotonic', float('nan')), ('ready_monotonic', 130)]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                measure.check_fixture({**self.sleeping(), field: value}, now=120)

    def test_rejects_stale_active_pages_and_recent_or_resumed_sleeping_reports(self):
        asleep = self.sleeping()
        for key, field, value in [('5', 'reported_monotonic', 100), ('1', 'reported_monotonic', 115),
                                  ('1', 'instance', str(uuid.uuid4())), ('5', 'width', 800),
                                  ('5', 'visibility', 'hidden'), ('2', 'visibility', 'unknown'),
                                  ('5', 'pulse', 0), ('1', 'reported_monotonic', float('nan'))]:
            changed = copy.deepcopy(asleep)
            changed['workload']['documents'][key][field] = value
            with self.subTest(key=key, field=field), self.assertRaises(ValueError):
                measure.check_fixture(changed, now=120)
        changed = copy.deepcopy(asleep)
        changed['workload']['documents']['1']['reported_monotonic'] = 100
        with self.assertRaises(ValueError):
            measure.check_fixture(changed, asleep, now=120)

    def test_rejects_reconnect_reload_missing_identity_and_changed_phase(self):
        asleep = self.sleeping()
        for field, value in [('active_streams', {'1': 1}), ('stream_connections', {'1': 2}),
                             ('document_loads', {'1': 2}), ('active_streams', {'5': False})]:
            changed = copy.deepcopy(asleep)
            changed['workload'][field].update(value)
            with self.subTest(field=field), self.assertRaises(ValueError):
                measure.check_fixture(changed, now=120)
        for field, value in [('loads', 6), ('run_id', 'other'), ('documents', {}), ('invalid_reason', 'bad')]:
            changed = copy.deepcopy(asleep)
            changed['workload'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                measure.check_fixture(changed, now=120)
        changed = copy.deepcopy(asleep)
        changed['ready_monotonic'] = 102
        with self.assertRaises(ValueError):
            measure.check_fixture(changed, asleep, now=120)

    def test_capture_rejects_non_lifecycle_incomplete_and_wrong_count(self):
        for field, value in [('kind', 'cross-site-documents'), ('expected_tabs', 20),
                             ('active_streams', dict.fromkeys(contract.KEYS, 0))]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                contract.capture({**workload(), field: value}, measure.check_fixture, now=100)


class SleepFixtureTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node is only needed for generated JavaScript syntax checks')
    def test_lifecycle_javascript_parses_without_running_page_code(self):
        for key in sorted(contract.KEYS):
            source = fixture.document(key, lifecycle=True).decode().split('<script>', 1)[1].split('</script>', 1)[0]
            result = subprocess.run(['node', '--check'], input=source, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_stream_closes_and_resume_counts_new_document_and_instance(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'state.json'
            server = fixture.create_server(path, lifecycle=True)
            worker = threading.Thread(target=server.serve_forever)
            worker.start()
            def request(method, route, body=None):
                connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
                origin = f'http://document-1.localhost:{server.server_port}'
                connection.request(method, route, body=json.dumps(body) if body else None,
                                   headers={'Host': origin.removeprefix('http://'), 'Origin': origin,
                                            'Content-Type': 'application/json'})
                response = connection.getresponse()
                return connection, response
            try:
                previous = None
                for count in (1, 2):
                    connection, response = request('GET', '/document/1')
                    self.assertEqual(response.status, 200)
                    self.assertIn(b'firstVisibleReadyMS', response.read())
                    connection.close()
                    connection, response = request('GET', '/events/1')
                    self.assertEqual(response.readline(), b'data: 1\n')
                    self.assertEqual(json.loads(path.read_text())['active_streams']['1'], 1)
                    response.close()
                    connection.close()
                    deadline = time.monotonic() + 7
                    while json.loads(path.read_text())['active_streams']['1'] and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertEqual(json.loads(path.read_text())['active_streams']['1'], 0)
                    report = workload()['documents']['1']
                    report['firstVisibleReadyMS'] = 30
                    connection, response = request('POST', '/report/1', report)
                    self.assertEqual(response.status, 204)
                    response.read()
                    connection.close()
                    state = json.loads(path.read_text())
                    self.assertEqual(state['document_loads']['1'], count)
                    self.assertEqual(state['stream_connections']['1'], count)
                    self.assertNotEqual(state['documents']['1']['instance'], previous)
                    self.assertNotIn('invalid_reason', state)
                    previous = state['documents']['1']['instance']
            finally:
                server.stopping.set()
                server.shutdown()
                server.server_close()
                worker.join(timeout=5)

    def test_lifecycle_is_bounded_and_readiness_is_validated(self):
        with self.assertRaises(ValueError):
            fixture.create_server('/unused', count=20, lifecycle=True)
        for value in (None, True, -1, float('nan'), 600001):
            data = workload()['documents']['1']
            data['firstVisibleReadyMS'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                fixture.validated_report(data, lifecycle=True)
