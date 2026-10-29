import http.client
import importlib.util
import json
import pathlib
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('address_route_fixture', pathlib.Path(__file__).parents[1] / 'test-fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class AddressRouteFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = fixture.FixtureHTTPServer(('127.0.0.1', 0), fixture.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        self.server.address_route_event.set()
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()

    def request(self, method, path, body=None, origin=True):
        client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            headers = {'Origin': f'http://127.0.0.1:{self.server.server_port}'} if origin else {}
            client.request(method, path, body=body, headers=headers)
            response = client.getresponse()
            return response.status, response.read()
        finally:
            client.close()

    def test_route_changes_only_after_the_trigger_and_reset_clears_it(self):
        self.assertFalse(self.server.address_route_event.is_set())
        self.assertEqual(self.request('POST', '/address-route-trigger')[0], 204)
        self.assertTrue(self.server.address_route_event.is_set())
        status, body = self.request('GET', '/address-route-wait')
        self.assertEqual((status, json.loads(body)), (200, {'changed': True}))
        self.assertEqual(self.request('POST', '/address-route-reset')[0], 204)
        self.assertFalse(self.server.address_route_event.is_set())

    def test_an_incomplete_wait_reports_expiration_without_changing_state(self):
        with patch.object(self.server.address_route_event, 'wait', return_value=False) as wait:
            status, body = self.request('GET', '/address-route-wait')
        self.assertEqual((status, json.loads(body)), (200, {'changed': False}))
        wait.assert_called_once_with(timeout=30)
        self.assertFalse(self.server.address_route_event.is_set())

    def test_wrong_origin_or_nonempty_body_cannot_trigger_the_change(self):
        self.assertEqual(self.request('POST', '/address-route-trigger', origin=False)[0], 403)
        self.assertEqual(self.request('POST', '/address-route-trigger', body=b'not empty')[0], 400)
        self.assertFalse(self.server.address_route_event.is_set())

    def test_state_belongs_to_one_fixture_server(self):
        other = fixture.FixtureHTTPServer(('127.0.0.1', 0), fixture.Handler)
        self.addCleanup(other.server_close)
        self.server.address_route_event.set()
        self.assertFalse(other.address_route_event.is_set())

    def test_page_uses_the_bounded_wait_without_external_resources(self):
        status, body = self.request('GET', '/address-route')
        self.assertEqual(status, 200)
        self.assertIn(b"fetch('/address-route-wait'", body)
        self.assertIn(b"history.pushState({},'', '/address-route/changed')", body)
        self.assertNotIn(b'setTimeout', body)

    def test_search_history_fixture_accepts_get_query_parameters(self):
        status, body = self.request('GET', '/search-results?q=first+query')
        self.assertEqual(status, 200)
        self.assertIn(b'Search fixture results', body)
        self.assertIn(b'Result page', body)
        self.assertNotIn(b'Not found', body)
