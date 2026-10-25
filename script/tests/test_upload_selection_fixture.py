import http.client
import http.server
import importlib.util
import json
import pathlib
import threading
import unittest

spec = importlib.util.spec_from_file_location('upload_fixture', pathlib.Path(__file__).parents[1]/'test-fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class UploadSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), fixture.Handler)
        cls.server.fixture_failure_url = 'http://127.0.0.1:1'
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.worker.join(timeout=2); cls.server.server_close()

    def payload(self, kind):
        return {'kind': kind, 'files': [
            {'name': 'a.txt', 'path': 'SelectedFolder/a.txt' if kind=='folder' else '', 'text':'synthetic A\n'},
            {'name': 'b.txt', 'path': 'SelectedFolder/nested/b.txt' if kind=='folder' else '', 'text':'synthetic B\n'}]}

    def request(self, body, origin=None):
        connection=http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        self.addCleanup(connection.close)
        headers={'Content-Type':'application/json','Origin':origin or f'http://127.0.0.1:{self.server.server_port}'}
        connection.request('POST','/upload-selection',body,headers)
        response=connection.getresponse()
        return response.status,response.read()

    def test_both_exact_generated_selections_are_accepted_independent_of_order(self):
        for kind in ['files','folder']:
            payload=self.payload(kind);payload['files'].reverse()
            self.assertEqual(self.request(json.dumps(payload)),(200,b'Selected synthetic files received'))

    def test_extra_missing_or_changed_file_cannot_be_reported_as_success(self):
        for change in ['extra','missing','bytes','path','duplicate']:
            payload=self.payload('folder')
            if change=='extra':payload['files'].append({'name':'private.txt','path':'../private.txt','text':'synthetic outside'})
            elif change=='missing':payload['files'].pop()
            elif change=='bytes':payload['files'][0]['text']='unexpected synthetic data'
            elif change=='path':payload['files'][0]['path']='OtherFolder/a.txt'
            else:payload['files'][1]=payload['files'][0]
            status,body=self.request(json.dumps(payload))
            self.assertEqual((status,body),(400,b'Unexpected synthetic selection'))
            self.assertNotIn(b'private',body)

    def test_wrong_origin_is_rejected(self):
        self.assertEqual(self.request(json.dumps(self.payload('files')),'https://other.invalid')[0],403)

    def test_oversized_and_malformed_input_never_echoes_the_input(self):
        self.assertEqual(self.request(b'x'*8193)[0],413)
        for body in [b'invalid synthetic JSON',b'[]',b'{"kind":"folder","files":[1,2]}']:
            self.assertEqual(self.request(body),(400,b'Unexpected synthetic selection'))

    def test_page_has_independent_file_and_folder_controls(self):
        connection=http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        self.addCleanup(connection.close)
        connection.request('GET','/upload-selection')
        response=connection.getresponse();body=response.read()
        self.assertEqual(response.status,200)
        for text in [b'Multiple attachments',b'Folder attachment',b'webkitdirectory',b'webkitRelativePath']:
            self.assertIn(text,body)
