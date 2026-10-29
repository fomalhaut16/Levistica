import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('safari_workload', Path(__file__).parents[1]/'safari-workload.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
VIEW = {'width': 779, 'height': 687, 'dpr': 2}


class Driver:
    def __init__(self, path, count):
        self.path = path
        self.count = count
        keys = [str(n) for n in range(1, count+1)]
        self.state = {'kind': 'cross-site-documents', 'transport': 'same-origin-sse-v1',
                      'expected_tabs': count, 'loads': 0, 'run_id': 'synthetic-owned-fixture',
                      'urls': {k: f'http://document-{k}.localhost:12345/document/{k}' for k in keys},
                      'origins': {k: f'http://document-{k}.localhost:12345' for k in keys},
                      'document_hashes': {k: hashlib.sha256(('document '+k).encode()).hexdigest() for k in keys},
                      'stream_connections': {k: 0 for k in keys}, 'documents': {}}
        self.tabs = ['page-1']; self.selected = self.tabs[0]; self.urls = {}
        self.view = dict(VIEW); self.time = 100.0
        self.calls = []; self.health_calls = 0; self.adjustments = 0
        self.unready = None; self.mutate = None; self.new_type = 'tab'
        self.extra_handle = False; self.duplicate_handle = False
        self.wrong_final_selection = False; self.wrong_final_url = False
        self.frozen_view = False; self.healthy = True; self.request_seconds = 0
        self.save()

    def save(self): self.path.write_text(json.dumps(self.state))
    def sleep(self, seconds): self.time += seconds
    def health(self):
        self.health_calls += 1
        if not self.healthy: raise ValueError('ownership or foreground guard failed')

    def request(self, method, path, data):
        self.calls.append((method, path, copy.deepcopy(data)))
        self.time += self.request_seconds
        path = path.removeprefix('/session/owned-session')
        if method == 'GET' and path == '/window/handles':
            return self.tabs + (['extra-tab'] if self.extra_handle and self.state['loads']==self.count else [])
        if method == 'GET' and path == '/url':
            if self.wrong_final_url and self.state['loads']==self.count: return 'https://not-a-fixture.invalid/'
            return self.urls.get(self.selected, 'about:blank')
        if method == 'GET' and path == '/window':
            return self.tabs[0] if self.wrong_final_selection else self.selected
        if method == 'POST' and path == '/window/new':
            new = self.tabs[0] if self.duplicate_handle else f'page-{len(self.tabs)+1}'
            self.tabs.append(new)
            return {'type': self.new_type, 'handle': new}
        if method == 'POST' and path == '/window':
            self.selected = data['handle']; return None
        if method == 'GET' and path == '/window/rect': return {'width': self.view['width']+20, 'height': self.view['height']+90}
        if method == 'POST' and path == '/window/rect':
            self.adjustments += 1
            if not self.frozen_view: self.view.update(width=data['width']-20,height=data['height']-90)
            return None
        if method == 'POST' and path == '/execute/sync': return dict(self.view)
        if method == 'POST' and path == '/url':
            self.urls[self.selected] = data['url']
            key = data['url'].rsplit('/',1)[1]
            self.state['loads'] += 1; self.state['stream_connections'][key] += 1
            for doc in self.state['documents'].values(): doc['visibility'] = 'hidden'
            self.state['documents'][key] = {'complete':key!=self.unready,'seenVisible':True,'sections':240,
                'pulse':1,'origin':self.state['origins'][key],'instance':'instance-'+key,
                'visibility':'visible','reported_monotonic':self.time,**self.view}
            if self.state['loads']==self.count: self.state['ready_monotonic'] = self.time
            if self.mutate: self.mutate(self.state)
            self.save(); return None
        raise AssertionError('Unexpected browser operation: '+repr((method,path)))


class SafariWorkloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)/'state.json'

    def prepare(self, driver, **overrides):
        args = dict(count=driver.count, viewport=VIEW, expected_hashes=copy.deepcopy(driver.state['document_hashes']),
                    health=driver.health, clock=lambda:driver.time, sleep=driver.sleep)
        args.update(overrides)
        return s.prepare_tabs(driver.request, 'owned-session', self.path, **args)

    def test_twenty_and_fifty_use_one_load_per_tab_and_the_last_selection(self):
        for count in [20,50]:
            with self.subTest(count=count):
                d = Driver(self.path,count); result = self.prepare(d)
                self.assertEqual(result['viewport'],VIEW)
                self.assertEqual(len(set(result['handles'])),count)
                self.assertEqual(result['state']['loads'],count)
                self.assertEqual(result['state']['documents'][str(count)]['visibility'],'visible')
                self.assertEqual(sum(method=='POST' and path.endswith('/url') for method,path,_ in d.calls),count)
                self.assertTrue(all(v==1 for v in result['state']['stream_connections'].values()))
                self.assertGreater(d.health_calls,len(d.calls))
                self.assertFalse(any(path.endswith('/session') or method=='DELETE' for method,path,_ in d.calls))

    def test_calibration_is_done_before_any_document_is_loaded(self):
        d = Driver(self.path,20);d.view.update(width=800,height=600)
        self.prepare(d)
        self.assertEqual(d.adjustments,1)
        resize = next(i for i,c in enumerate(d.calls) if c[0]=='POST' and c[1].endswith('/window/rect'))
        load = next(i for i,c in enumerate(d.calls) if c[0]=='POST' and c[1].endswith('/url'))
        self.assertLess(resize,load)

    def test_no_navigation_when_peer_hashes_or_fresh_fixture_do_not_match(self):
        for change in ['hash','loaded','origin']:
            with self.subTest(change=change):
                d = Driver(self.path,50); hashes = dict(d.state['document_hashes'])
                if change=='hash': hashes['1']='f'*64
                if change=='loaded': d.state['loads']=1;d.save()
                if change=='origin': d.state['origins']['1']='https://not-a-fixture.invalid';d.save()
                with self.assertRaises(ValueError): self.prepare(d,expected_hashes=hashes)
                self.assertEqual(d.calls,[])

    def test_existing_nonblank_context_is_not_overwritten(self):
        d = Driver(self.path,20);d.urls[d.selected]='https://existing.invalid/'
        with self.assertRaises(ValueError): self.prepare(d)
        self.assertFalse(any(method=='POST' for method,_,_ in d.calls))

    def test_extra_initial_context_is_rejected_without_creating_or_loading(self):
        d = Driver(self.path,20);d.tabs.append('already-present')
        with self.assertRaises(ValueError):self.prepare(d)
        self.assertFalse(any(method=='POST' for method,_,_ in d.calls))

    def test_separate_windows_and_duplicate_handles_are_rejected(self):
        for case in ['window','duplicate']:
            with self.subTest(case=case):
                d = Driver(self.path,20)
                if case=='window':d.new_type='window'
                else:d.duplicate_handle=True
                with self.assertRaises(ValueError):self.prepare(d)
                self.assertEqual(d.state['loads'],0)

    def test_display_scale_mismatch_does_not_load_pages(self):
        d = Driver(self.path,20);d.view['dpr']=1
        with self.assertRaises(ValueError):self.prepare(d)
        self.assertEqual(d.state['loads'],0)

    def test_viewport_adjustments_are_bounded_without_loading_pages(self):
        d = Driver(self.path,20);d.view['height']=600;d.frozen_view=True
        with self.assertRaises(ValueError):self.prepare(d)
        self.assertEqual(d.adjustments,3);self.assertEqual(d.state['loads'],0)

    def test_guard_failure_stops_before_any_request(self):
        d = Driver(self.path,20);d.healthy=False
        with self.assertRaises(ValueError):self.prepare(d)
        self.assertEqual(d.calls,[])

    def test_unready_page_times_out_without_reload_or_later_navigation(self):
        d = Driver(self.path,50);d.unready='3'
        with self.assertRaises(TimeoutError):self.prepare(d)
        self.assertEqual(d.state['loads'],3)
        self.assertTrue(all(v<=1 for v in d.state['stream_connections'].values()))
        self.assertLessEqual(d.time,110.1)

    def test_global_deadline_also_bounds_slow_requests(self):
        d = Driver(self.path,50);d.request_seconds=.3
        with self.assertRaises(TimeoutError):self.prepare(d,max_seconds=.2)
        self.assertEqual(len(d.calls),1);self.assertEqual(d.state['loads'],0)

    def test_fixture_mutation_or_reconnection_is_not_retried(self):
        for case in ['hash','run','reconnect']:
            with self.subTest(case=case):
                d = Driver(self.path,20)
                def mutate(state):
                    if case=='hash':state['document_hashes']['1']='f'*64
                    elif case=='run':state['run_id']='different-run'
                    else:state['stream_connections']['1']=2
                d.mutate=mutate
                with self.assertRaises(ValueError):self.prepare(d)
                self.assertEqual(d.state['loads'],1)

    def test_changed_final_contexts_selection_or_location_are_rejected(self):
        for case in ['handles','selected','url']:
            with self.subTest(case=case):
                d = Driver(self.path,20)
                d.extra_handle=case=='handles';d.wrong_final_selection=case=='selected';d.wrong_final_url=case=='url'
                with self.assertRaises(ValueError):self.prepare(d)

    def test_fixture_mutation_during_final_driver_checks_is_rejected(self):
        for case in ['hash', 'run', 'reconnect']:
            with self.subTest(case=case):
                d = Driver(self.path,20)
                def request(method, path, data):
                    result = d.request(method, path, data)
                    if method=='GET' and path.endswith('/url') and d.state['loads']==d.count:
                        if case=='hash':d.state['document_hashes']['1']='f'*64
                        elif case=='run':d.state['run_id']='changed-after-final-navigation'
                        else:d.state['stream_connections']['1']=2
                        d.save()
                    return result
                with self.assertRaises(ValueError):
                    s.prepare_tabs(request,'owned-session',self.path,count=20,viewport=VIEW,
                                   expected_hashes=copy.deepcopy(d.state['document_hashes']),
                                   health=d.health,clock=lambda:d.time,sleep=d.sleep)

    def test_bad_count_viewport_and_session_never_contact_the_driver(self):
        d = Driver(self.path,20)
        for args in [{'count':100},{'count':True},{'viewport':{**VIEW,'dpr':float('nan')}},
                     {'viewport':{**VIEW,'width':True}},{'max_seconds':float('inf')}]:
            with self.subTest(args=args),self.assertRaises(ValueError):self.prepare(d,**args)
        with self.assertRaises(ValueError):
            s.prepare_tabs(d.request,'../foreign',self.path,count=20,viewport=VIEW,
                           expected_hashes=d.state['document_hashes'],health=d.health)
        self.assertEqual(d.calls,[])

    def test_state_symlink_and_oversized_file_are_rejected(self):
        d = Driver(self.path,20)
        source=self.path.with_suffix('.original');self.path.rename(source);self.path.symlink_to(source)
        with self.assertRaises(ValueError):self.prepare(d)
        self.path.unlink();self.path.write_bytes(b' '*(1024*1024+1))
        with self.assertRaises(ValueError):self.prepare(d)
        self.assertEqual(d.calls,[])


    def test_invalid_live_viewport_fails_before_loading(self):
        for bad in [0,-1,float('nan'),float('inf'),True]:
            with self.subTest(value=bad):
                d = Driver(self.path,20);d.view['width']=bad
                with self.assertRaises(ValueError):self.prepare(d)
                self.assertEqual(d.state['loads'],0)

    def test_earlier_tab_reconnection_stops_the_remaining_workload(self):
        d = Driver(self.path,50)
        def reconnect(state):
            if state['loads']==4:state['stream_connections']['1']=2
        d.mutate=reconnect
        with self.assertRaises(ValueError):self.prepare(d)
        self.assertEqual(d.state['loads'],4)


if __name__ == '__main__':unittest.main()
