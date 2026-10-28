import copy
import errno
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('comparison_chrome', pathlib.Path(__file__).parents[1] / 'comparison-chrome.py')
chrome = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chrome)


class ComparisonChromeTests(unittest.TestCase):
    def state(self, count=20):
        keys = [str(i) for i in range(1, count + 1)]
        return {'kind': 'cross-site-documents', 'transport': 'same-origin-sse-v1',
                'run_id': 'synthetic', 'expected_tabs': count, 'loads': 0,
                'urls': {k: f'http://document-{k}.localhost:12345/document/{k}' for k in keys},
                'origins': {k: f'http://document-{k}.localhost:12345' for k in keys},
                'document_hashes': dict.fromkeys(keys, 'a' * 64),
                'stream_connections': dict.fromkeys(keys, 0), 'documents': {}}

    def urls(self, state, first=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            path = root / '.local/state.json'
            path.parent.mkdir()
            path.write_text(json.dumps(state))
            with patch.object(chrome.m, 'ROOT', root):
                return chrome.workload_urls(first or state['urls']['1'], state['expected_tabs'], path)

    def test_fresh_five_twenty_and_fifty_cross_site_sets_are_accepted(self):
        for count in [5, 20, 50]:
            with self.subTest(count=count):
                state = self.state(count)
                self.assertEqual(self.urls(state), [state['urls'][str(n)] for n in range(1, count + 1)])

    def test_fifty_requires_typed_counters_and_the_last_assigned_origin(self):
        for value in [True, 50.0, '50', 100, None]:
            with self.subTest(count=value), self.assertRaises(ValueError):
                chrome.workload_urls('http://127.0.0.1:12345/document', value)
        for field, value in [('loads', False), ('expected_tabs', 50.0)]:
            state = self.state(50)
            state[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): self.urls(state)
        for field, value in [('urls', 'http://document-51.localhost:12345/document/50'),
                             ('origins', 'http://document-1.localhost:12345'),
                             ('document_hashes', 'invalid'), ('stream_connections', False)]:
            state = self.state(50)
            state[field]['50'] = value
            with self.subTest(field=field), self.assertRaises(ValueError): self.urls(state)

    def test_expired_preparation_does_not_forward_another_url(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = self.state(50)
            ready = pathlib.Path(temporary) / 'state.json'
            ready.write_text(json.dumps(state))
            with patch.object(chrome.time, 'monotonic', side_effect=[0, 181]), \
                    patch.object(chrome.subprocess, 'run') as send, \
                    patch.object(chrome, 'verified_marker') as verify:
                with self.assertRaisesRegex(ValueError, 'bounded time'):
                    chrome.prepare_tabs({'profile': temporary}, list(state['urls'].values()), ready)
                send.assert_not_called()
                verify.assert_not_called()

    def test_reloaded_reconnected_or_used_sets_are_rejected(self):
        for key, value in [('loads', 1), ('invalid_reason', 'synthetic'),
                           ('documents', {'1': {'complete': True}}), ('run_id', ''),
                           ('transport', 'other')]:
            state = self.state()
            state[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.urls(state)
        state = self.state()
        state['stream_connections']['1'] = 1
        with self.assertRaises(ValueError):
            self.urls(state)

    def test_non_fixture_urls_and_mismatched_origins_ports_or_hashes_are_rejected(self):
        for url in ['https://example.com/document/1', 'http://document-1.localhost:12345/document/1?q=x',
                    'http://user:secret@document-1.localhost:12345/document/1',
                    'http://document-1.localhost:23456/document/1',
                    'http://document-2.localhost:12345/document/1']:
            state = self.state()
            state['urls']['1'] = url
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.urls(state)
        for field in ['origins', 'document_hashes']:
            state = self.state()
            state[field]['1'] = 'unexpected'
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.urls(state)
        with self.assertRaises(ValueError):
            self.urls(self.state(), first='http://document-2.localhost:12345/document/2')

    def test_single_page_and_existing_five_page_contracts_remain_supported(self):
        self.assertEqual(chrome.workload_urls('http://127.0.0.1:12345/video', 1),
                         ['http://127.0.0.1:12345/video'])
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve(); path = root / '.local/state.json'
            path.parent.mkdir()
            path.write_text(json.dumps({'kind': 'documents', 'url': 'http://127.0.0.1:12345/document', 'loads': 0}))
            with patch.object(chrome.m, 'ROOT', root):
                self.assertEqual(len(chrome.workload_urls('http://127.0.0.1:12345/document', 5, path)), 5)
        for count in [0, 2, 100]:
            with self.assertRaises(ValueError):
                chrome.workload_urls('http://127.0.0.1:12345/document', count)

    def test_fixture_file_outside_local_directory_is_rejected_without_reading(self):
        with self.assertRaises(ValueError):
            chrome.workload_urls('http://document-1.localhost:12345/document/1', 20, pathlib.Path('/outside/missing.json'))

    def test_pressure_changes_or_read_errors_fail_closed(self):
        with patch.object(chrome.m, 'run', return_value='1\n'):
            chrome.pressure_normal()
        with patch.object(chrome.m, 'run', return_value='2\n'):
            with self.assertRaises(ValueError):
                chrome.pressure_normal()
        with patch.object(chrome.m, 'run', side_effect=OSError('synthetic')):
            with self.assertRaises(OSError):
                chrome.pressure_normal()

    def test_normal_profile_is_never_signalled(self):
        with patch.object(chrome.os, 'kill') as kill:
            with self.assertRaises(ValueError):
                chrome.stop(pathlib.Path('/normal/Chrome'))
            kill.assert_not_called()

    def test_stop_signals_only_the_verified_experiment_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary).resolve()
            profile = base / 'chrome-trial.synthetic'; profile.mkdir()
            identity = {'started': 'original start', 'executable': str(chrome.binary)}
            marker = {'pid': 123, 'profile': str(profile), 'identity': identity}
            (profile / 'levistica-benchmark.json').write_text(json.dumps(marker))
            with patch.object(chrome, 'base', base), patch.object(chrome.m, 'find_app', return_value=123), \
                    patch.object(chrome.m, 'identities', side_effect=[{123: identity}, {123: identity}, ValueError('exited')]), \
                    patch.object(chrome.m, 'run', return_value='chrome --user-data-dir=' + str(profile)), \
                    patch.object(chrome.os, 'kill') as kill:
                chrome.stop(profile)
                kill.assert_called_once_with(123, chrome.signal.SIGTERM)

    def test_kernel_disappearance_after_sigterm_completes_without_another_signal(self):
        profile = pathlib.Path('/synthetic-owned-profile')
        identity = {'started': 'original start', 'executable': str(chrome.binary)}
        marker = {'pid': 123, 'profile': str(profile), 'identity': identity}
        with patch.object(chrome, 'verified_marker', return_value=marker), \
                patch.object(chrome.m, 'identities', side_effect=ProcessLookupError('exited')), \
                patch.object(chrome.os, 'kill') as kill:
            chrome.stop(profile)
            kill.assert_called_once_with(123, chrome.signal.SIGTERM)
        with patch.object(chrome, 'verified_marker', side_effect=ProcessLookupError('gone before verification')), \
                patch.object(chrome.os, 'kill') as kill:
            with self.assertRaises(ProcessLookupError):
                chrome.stop(profile)
            kill.assert_not_called()

    def normal_marker(self):
        return {'pid': 123, 'profile': '/synthetic-owned-profile',
                'identity': {'started': 'Wed Oct 28 10:30:00 2026', 'executable': str(chrome.binary)}}

    def test_normal_quit_requires_ownership_before_requesting_appkit(self):
        with patch.object(chrome.m, 'run') as request, patch.object(chrome.os, 'kill') as kill:
            with self.assertRaises(ValueError):
                chrome.quit_normally(pathlib.Path('/normal/Chrome'))
            request.assert_not_called()
            kill.assert_not_called()

    def test_normal_quit_targets_only_original_app_and_waits_for_confirmed_exit(self):
        marker = self.normal_marker()
        with patch.object(chrome, 'verified_marker', return_value=marker), \
                patch.object(chrome.m, 'run', return_value='requested\n') as request, \
                patch.object(chrome, 'original_root_exited', side_effect=[False, True]), \
                patch.object(chrome.time, 'sleep'), patch.object(chrome.os, 'kill') as kill:
            chrome.quit_normally(pathlib.Path(marker['profile']))
            args = request.call_args.args[0]
            self.assertEqual(args[:4], ['/usr/bin/osascript', '-l', 'JavaScript', '-e'])
            self.assertEqual(args[5:7], ['123', str(chrome.binary)])
            self.assertIn('application.launchDate', args[4])
            self.assertIn('com.google.Chrome', args[4])
            self.assertNotIn('forceTerminate', args[4])
            kill.assert_not_called()

    def test_normal_quit_refusal_or_timeout_never_falls_back_to_a_signal(self):
        marker = self.normal_marker()
        for output in ['refused', 'requested']:
            with self.subTest(output=output), patch.object(chrome, 'verified_marker', return_value=marker), \
                    patch.object(chrome.m, 'run', return_value=output), \
                    patch.object(chrome.time, 'monotonic', side_effect=[0, 0, 11]), \
                    patch.object(chrome.time, 'sleep'), \
                    patch.object(chrome, 'original_root_exited', return_value=False), \
                    patch.object(chrome.os, 'kill') as kill:
                with self.assertRaises((ValueError, TimeoutError)):
                    chrome.quit_normally(pathlib.Path(marker['profile']))
                kill.assert_not_called()

    def disappearing_path(self, pid=123, code=errno.ESRCH):
        error = ProcessLookupError(code, 'synthetic disappearing executable')
        error.process_id = pid
        return error

    def test_normal_quit_rechecks_transient_original_path_loss_without_a_second_request(self):
        marker = self.normal_marker()
        with patch.object(chrome, 'verified_marker', return_value=marker), \
                patch.object(chrome.m, 'run', return_value='requested') as request, \
                patch.object(chrome, 'original_root_exited', side_effect=[self.disappearing_path(), True]) as probe, \
                patch.object(chrome.time, 'sleep'), patch.object(chrome.os, 'kill') as kill:
            chrome.quit_normally(pathlib.Path(marker['profile']))
            request.assert_called_once()
            self.assertEqual(probe.call_count, 2)
            kill.assert_not_called()

    def test_missing_path_without_proven_exit_still_times_out_without_signals(self):
        marker = self.normal_marker()
        with patch.object(chrome, 'verified_marker', return_value=marker), \
                patch.object(chrome.m, 'run', return_value='requested') as request, \
                patch.object(chrome, 'original_root_exited', side_effect=self.disappearing_path()), \
                patch.object(chrome.time, 'monotonic', side_effect=[0, 0, 11]), \
                patch.object(chrome.time, 'sleep'), patch.object(chrome.os, 'kill') as kill:
            with self.assertRaises(TimeoutError): chrome.quit_normally(pathlib.Path(marker['profile']))
            request.assert_called_once()
            kill.assert_not_called()

    def test_exit_wait_does_not_retry_unrelated_missing_paths_or_permission_and_identity_errors(self):
        marker = self.normal_marker()
        errors = [self.disappearing_path(456), self.disappearing_path(code=errno.EPERM),
                  ProcessLookupError('no PID context'), PermissionError('synthetic denied'),
                  ValueError('synthetic changed identity')]
        for error in errors:
            with self.subTest(error=type(error).__name__), \
                    patch.object(chrome, 'verified_marker', return_value=marker), \
                    patch.object(chrome.m, 'run', return_value='requested') as request, \
                    patch.object(chrome, 'original_root_exited', side_effect=error) as probe, \
                    patch.object(chrome.time, 'sleep') as wait, patch.object(chrome.os, 'kill') as kill:
                with self.assertRaises(type(error)): chrome.quit_normally(pathlib.Path(marker['profile']))
                request.assert_called_once()
                probe.assert_called_once()
                wait.assert_not_called()
                kill.assert_not_called()

    def test_initial_missing_identity_is_never_retried_or_sent_a_quit_request(self):
        with patch.object(chrome, 'verified_marker', side_effect=self.disappearing_path()), \
                patch.object(chrome.m, 'run') as request, patch.object(chrome.time, 'sleep') as wait:
            with self.assertRaises(ProcessLookupError): chrome.quit_normally(pathlib.Path('/synthetic'))
            request.assert_not_called()
            wait.assert_not_called()

    def test_normal_quit_handles_exit_race_but_not_permission_uncertainty(self):
        marker = self.normal_marker()
        present = chrome.subprocess.CompletedProcess([], 0, '123\n', '')
        absent = chrome.subprocess.CompletedProcess([], 1, '', '')
        denied = chrome.subprocess.CompletedProcess([], 2, '', 'denied')
        with patch.object(chrome.subprocess, 'run', side_effect=[present, absent]), \
                patch.object(chrome.m, 'identities', side_effect=ProcessLookupError('exited')), \
                patch.object(chrome.os, 'kill', side_effect=ProcessLookupError('gone')):
            self.assertTrue(chrome.original_root_exited(marker))
        with patch.object(chrome.subprocess, 'run', return_value=denied), \
                patch.object(chrome.m, 'identities') as identity:
            with self.assertRaises(ValueError):
                chrome.original_root_exited(marker)
            identity.assert_not_called()
        with patch.object(chrome.subprocess, 'run', return_value=present), \
                patch.object(chrome.m, 'identities', return_value={123: {'started': 'replacement PID'}}):
            self.assertTrue(chrome.original_root_exited(marker))

    def test_same_birth_path_change_and_empty_listing_are_not_confirmed_exits(self):
        marker = self.normal_marker()
        present = chrome.subprocess.CompletedProcess([], 0, '123\n', '')
        absent = chrome.subprocess.CompletedProcess([], 1, '', '')
        changed = {**marker['identity'], 'executable': '/different/executable'}
        with patch.object(chrome.subprocess, 'run', return_value=present), \
                patch.object(chrome.m, 'identities', return_value={123: changed}):
            with self.assertRaises(ValueError):
                chrome.original_root_exited(marker)
        with patch.object(chrome.subprocess, 'run', return_value=absent), \
                patch.object(chrome.os, 'kill', return_value=None) as probe:
            with self.assertRaises(ValueError):
                chrome.original_root_exited(marker)
            probe.assert_called_once_with(123, 0)

    def test_verification_targets_recorded_pid_even_during_another_forwarder(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary).resolve()
            profile = base / 'chrome-trial.synthetic'; profile.mkdir()
            identity = {'started': 'original start', 'executable': str(chrome.binary)}
            marker = {'pid': 123, 'profile': str(profile), 'identity': identity}
            (profile / 'levistica-benchmark.json').write_text(json.dumps(marker))
            with patch.object(chrome, 'base', base), \
                    patch.object(chrome.m, 'find_app', side_effect=ValueError('ambiguous roots')) as discover, \
                    patch.object(chrome.m, 'identities', return_value={123: identity}), \
                    patch.object(chrome.m, 'run', return_value='chrome --user-data-dir=' + str(profile)):
                self.assertEqual(chrome.verified_marker(profile), marker)
                discover.assert_not_called()
            with patch.object(chrome, 'base', base), \
                    patch.object(chrome.m, 'identities', return_value={123: identity}), \
                    patch.object(chrome.m, 'run', return_value='chrome --user-data-dir=' + str(profile) + '-other'):
                with self.assertRaises(ValueError):
                    chrome.verified_marker(profile)

    def test_reused_pid_changed_profile_or_start_time_never_receives_a_signal(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary).resolve()
            profile = base / 'chrome-trial.synthetic'; profile.mkdir()
            identity = {'started': 'original start', 'executable': str(chrome.binary)}
            original = {'pid': 123, 'profile': str(profile), 'identity': identity}
            for marker_change, pid, identity_change in [
                ({'pid': 124}, 123, {}), ({'profile': '/normal/Chrome'}, 123, {}),
                ({}, 123, {'started': 'reused PID'}), ({}, 124, {})]:
                (profile / 'levistica-benchmark.json').write_text(json.dumps({**original, **marker_change}))
                with patch.object(chrome, 'base', base), patch.object(chrome.m, 'find_app', return_value=pid), \
                        patch.object(chrome.m, 'identities', return_value={pid: {**identity, **identity_change}}), \
                        patch.object(chrome.os, 'kill') as kill:
                    with self.subTest(change=marker_change, pid=pid, identity_change=identity_change), self.assertRaises(ValueError):
                        chrome.stop(profile)
                    kill.assert_not_called()

    def test_changed_identity_blocks_forwarding_more_urls(self):
        state = self.state(5)
        with patch.object(chrome, 'pressure_normal'), patch.object(chrome, 'verified_marker', side_effect=ValueError('changed')), \
                patch.object(pathlib.Path, 'read_text', return_value=json.dumps(state)), \
                patch.object(chrome.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                chrome.prepare_tabs({'profile': '/synthetic'}, list(state['urls'].values()), pathlib.Path('/state'))
            run.assert_not_called()

    def test_replaced_marker_cannot_change_the_original_preparation_process(self):
        state = self.state(5)
        original = {'profile': '/synthetic', 'pid': 123, 'identity': {'started': 'original'}}
        replacement = {**original, 'pid': 124}
        with patch.object(chrome, 'pressure_normal'), \
                patch.object(chrome, 'verified_marker', return_value=replacement), \
                patch.object(pathlib.Path, 'read_text', return_value=json.dumps(state)), \
                patch.object(chrome.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                chrome.prepare_tabs(original, list(state['urls'].values()), pathlib.Path('/state'))
            run.assert_not_called()

    def test_all_forwarded_urls_are_bound_to_the_experiment_profile(self):
        initial = self.state(5)
        reports = []
        for n in range(1, 6):
            state = copy.deepcopy(initial)
            state['loads'] = n
            state['documents'][str(n)] = {'complete': True, 'seenVisible': True, 'pulse': 1}
            reports.append(json.dumps(state))
        marker = {'profile': '/synthetic/chrome-trial.test', 'pid': 123, 'identity': {'started': 'original'}}
        with patch.object(chrome, 'pressure_normal'), patch.object(chrome, 'verified_marker', return_value=marker), \
                patch.object(pathlib.Path, 'read_text', side_effect=[json.dumps(initial), *reports, reports[-1]]), \
                patch.object(pathlib.Path, 'write_text'), patch.object(chrome.subprocess, 'run') as run, \
                patch.object(chrome.m, 'check_fixture'):
            chrome.prepare_tabs(marker, list(initial['urls'].values()), pathlib.Path('/state'))
            self.assertEqual(run.call_count, 4)
            for call in run.call_args_list:
                self.assertIn('--user-data-dir=/synthetic/chrome-trial.test', call.args[0])
                self.assertTrue(call.args[0][-1].startswith('http://document-'))
                self.assertEqual(call.kwargs['timeout'], 10)


if __name__ == '__main__':
    unittest.main()
