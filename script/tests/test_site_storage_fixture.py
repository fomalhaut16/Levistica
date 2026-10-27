import http.client
import importlib.util
import json
from pathlib import Path
import threading
import unittest

spec = importlib.util.spec_from_file_location('site_storage_fixture', Path(__file__).parents[1] / 'site-storage-fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class SiteStorageFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = fixture.StorageServer()
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(2)

    def fetch(self, path, body=None, headers=None):
        c = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
        c.request('POST' if body is not None else 'GET', path, body, headers or {})
        r = c.getresponse()
        result = r.status, dict(r.getheaders()), r.read()
        c.close()
        return result

    def test_cookie_is_persistent_http_only_and_logout_expires_it(self):
        status, headers, page = self.fetch('/set')
        self.assertEqual(status, 200)
        self.assertIn('Max-Age=86400; HttpOnly; SameSite=Strict', headers['Set-Cookie'])
        self.assertIn(b'localStorage.setItem', page)
        self.assertIn(b'tx.oncomplete=resolve', page)
        self.assertIn(b'db.close()', page)
        self.assertIn('Max-Age=0', self.fetch('/clear')[1]['Set-Cookie'])
        self.assertNotIn('Set-Cookie', self.fetch('/check')[1])

    def test_reports_record_only_booleans_and_exact_server_cookie(self):
        body = json.dumps(dict(action='check', local=True, indexed=True, cookieVisible=False))
        headers = {'Origin': self.server.origin, 'Content-Type': 'application/json',
                   'Cookie': 'fixture=' + self.server.token + '-wrong'}
        self.assertEqual(self.fetch('/report', body, headers)[0], 200)
        self.assertFalse(self.server.reports[-1]['serverCookie'])
        headers['Cookie'] = 'fixture=' + self.server.token
        self.assertEqual(self.fetch('/report', body, headers)[0], 200)
        self.assertTrue(self.server.reports[-1]['serverCookie'])
        self.assertNotIn(self.server.token, json.dumps(self.server.reports))
        bad = json.dumps(dict(action='check', local=1, indexed=True, cookieVisible=False))
        self.assertEqual(self.fetch('/report', bad, headers)[0], 400)
        self.assertEqual(len(self.server.reports), 2)

    def test_rejects_foreign_hosts_origins_and_unbounded_reports(self):
        self.assertEqual(self.fetch('/set', headers={'Host': 'foreign.invalid'})[0], 403)
        body = json.dumps(dict(action='set', local=True, indexed=True, cookieVisible=False))
        headers = {'Origin': 'http://foreign.invalid', 'Content-Type': 'application/json'}
        self.assertEqual(self.fetch('/report', body, headers)[0], 403)
        headers['Origin'] = self.server.origin
        self.assertEqual(self.fetch('/report', 'x' * 513, headers)[0], 400)
        for _ in range(12):
            self.assertEqual(self.fetch('/report', body, headers)[0], 200)
        self.assertEqual(self.fetch('/report', body, headers)[0], 429)
