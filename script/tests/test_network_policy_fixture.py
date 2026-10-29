import http.client
import importlib.util
import json
from pathlib import Path
import threading
import unittest

spec = importlib.util.spec_from_file_location('network_policy_fixture', Path(__file__).parents[1]/'test-fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class NetworkPolicyFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = fixture.FixtureHTTPServer(('127.0.0.1', 0), fixture.Handler)
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.addCleanup(self.close)

    def close(self):
        self.server.shutdown()
        self.worker.join(timeout=2)
        self.server.server_close()

    def request(self, path, headers=None):
        client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            client.request('GET', path, headers=headers or {})
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            client.close()

    def test_cors_cases_differ_only_in_permission_with_present_matching_headers(self):
        for allowed in [True, False]:
            with self.subTest(allowed=allowed):
                path = '/network-policy-cors-allowed' if allowed else '/network-policy-cors-denied'
                status, headers, body = self.request(path)
                self.assertEqual(status, 200)
                self.assertEqual(body, b'synthetic cross-origin response')
                self.assertEqual(headers['Content-Type'], 'text/plain')
                self.assertEqual(headers['Content-Length'], str(len(body)))
                self.assertEqual(headers['Cache-Control'], 'no-store')
                self.assertNotIn('Access-Control-Expose-Headers', headers)
                self.assertEqual(headers.get('Access-Control-Allow-Origin'),
                                 f'http://127.0.0.1:{self.server.server_port}' if allowed else None)

    def test_referrer_echo_uses_request_header_and_does_not_set_cookies(self):
        for referer in ['', f'http://127.0.0.1:{self.server.server_port}/network-policy']:
            with self.subTest(referer=referer):
                status, headers, body = self.request('/network-policy-referrer', {'Referer': referer})
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body), {'referer': referer})
                self.assertEqual(headers['Content-Length'], str(len(body)))
                self.assertEqual(headers['Content-Type'], 'application/json')
                self.assertNotIn('Set-Cookie', headers)

    def test_image_reports_only_a_referrer_class_and_never_reflects_the_header(self):
        origin = f'http://127.0.0.1:{self.server.server_port}'
        for referer, width in [('',1),(origin+'/',2),(origin+'/network-policy',3),('https://unrelated.invalid/synthetic',4)]:
            with self.subTest(width=width):
                status, headers, body = self.request('/network-policy-image?case=synthetic', {'Referer':referer})
                self.assertEqual(status, 200)
                self.assertEqual(headers['Content-Type'], 'image/svg+xml')
                self.assertEqual(headers['Content-Length'], str(len(body)))
                self.assertIn(f'width="{width}"'.encode(), body)
                self.assertNotIn(b'127.0.0.1',body)
                self.assertNotIn(b'unrelated.invalid',body)
