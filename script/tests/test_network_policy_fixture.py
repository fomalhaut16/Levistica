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

    def request(self, path, headers=None, method='GET', body=None):
        client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            client.request(method, path, body=body, headers=headers or {})
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

    def test_csp_form_source_declares_policy_and_allows_only_its_synthetic_script(self):
        for policy, allowed in [('self', "'self'"), ('none', "'none'"), ('cross', f'http://localhost:{self.server.server_port}')]:
            status, headers, body = self.request(f'/csp-form-source?token={"a"*32}&policy={policy}&cross=1')
            self.assertEqual(status, 200)
            self.assertEqual(headers['Content-Security-Policy'],
                             "default-src 'none'; script-src 'nonce-levistica-synthetic'; form-action " + allowed)
            self.assertIn(b'<script nonce="levistica-synthetic">', body)
            self.assertIn(b'securitypolicyviolation', body)
            self.assertIn(f'action="http://localhost:{self.server.server_port}/csp-form-arrival?token={"a"*32}"'.encode(), body)
            self.assertNotIn('Set-Cookie', headers)

    def test_csp_form_count_is_per_server_and_token_and_counts_only_arrival_requests(self):
        first, other = 'a'*32, 'b'*32
        for token in (first, other):
            status, headers, body = self.request('/csp-form-count?token='+token)
            self.assertEqual(json.loads(body), {'requests':0})
        self.request('/csp-form-source?token='+first+'&policy=self&cross=0')
        self.assertEqual(json.loads(self.request('/csp-form-count?token='+first)[2]), {'requests':0})
        status, headers, body = self.request('/csp-form-arrival?token='+first)
        self.assertEqual(status,200)
        self.assertIn(b'status:"arrived"',body)
        self.assertEqual(json.loads(self.request('/csp-form-count?token='+first)[2]), {'requests':1})
        self.assertEqual(json.loads(self.request('/csp-form-count?token='+other)[2]), {'requests':0})

    def test_csp_form_routes_reject_malformed_token_policy_and_destination(self):
        for path in ['/csp-form-count', '/csp-form-arrival?token=personal-text',
                     '/csp-form-source?token='+('a'*32)+'&policy=unsafe&cross=0',
                     '/csp-form-source?token='+('a'*32)+'&policy=self&cross=external']:
            self.assertEqual(self.request(path)[0],400)

    def test_csp_form_post_counts_only_the_fixed_synthetic_body(self):
        token = 'c'*32
        path = '/csp-form-arrival?token='+token
        self.assertEqual(self.request(path, method='POST', body='token='+token)[0],200)
        self.assertEqual(json.loads(self.request('/csp-form-count?token='+token)[2]), {'requests':1})
        self.assertEqual(self.request(path, method='POST', body='unexpected')[0],400)
        self.assertEqual(json.loads(self.request('/csp-form-count?token='+token)[2]), {'requests':1})

    def test_csp_worker_bootstrap_is_nonce_allowed_under_a_restrictive_default(self):
        for kind in ('dedicated','shared'):
            for policy in ('self','none'):
                status,headers,body=self.request(f'/csp-worker-source?token={"d"*32}&kind={kind}&policy={policy}')
                self.assertEqual(status,200)
                self.assertEqual(headers['Content-Security-Policy'],
                    "default-src 'none'; script-src 'nonce-levistica-worker'; worker-src '"+policy+"'")
                self.assertIn(b'<script nonce="levistica-worker">',body)
                self.assertIn(b'securitypolicyviolation',body)
                self.assertIn(b'status:"unsupported"',body)
                self.assertNotIn('Set-Cookie',headers)

    def test_csp_worker_script_requests_are_counted_per_kind_and_token(self):
        for kind in ('dedicated','shared'):
            path=f'/csp-worker-count?token={"e"*32}&kind={kind}'
            self.assertEqual(json.loads(self.request(path)[2]),{'requests':0})
            status,headers,body=self.request(f'/csp-worker-script?token={"e"*32}&kind={kind}')
            self.assertEqual(status,200)
            self.assertEqual(headers['Content-Type'],'application/javascript')
            self.assertEqual(headers['Content-Length'],str(len(body)))
            self.assertIn(b'postMessage("ready")',body)
            self.assertEqual(json.loads(self.request(path)[2]),{'requests':1})
        self.assertEqual(json.loads(self.request('/csp-worker-count?token='+('f'*32)+'&kind=shared')[2]),{'requests':0})

    def test_csp_worker_routes_reject_invalid_token_kind_and_policy(self):
        for path in ['/csp-worker-source', '/csp-worker-script?token=untrusted&kind=dedicated',
                     '/csp-worker-count?token='+('a'*32)+'&kind=unknown',
                     '/csp-worker-source?token='+('a'*32)+'&kind=shared&policy=unsafe']:
            self.assertEqual(self.request(path)[0],400)
