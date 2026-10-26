import importlib.util
from pathlib import Path
import signal
import subprocess
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('measurement_deadline', Path(__file__).resolve().parents[1] / 'isolated-app-deadline.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class DeadlineSafetyTests(unittest.TestCase):
    def record(self):
        return {'pid': 12345, 'executable': m.EXPECTED, 'started': 'fixed start\n'}

    def test_other_variants_and_invalid_pid_cannot_be_signalled(self):
        for change in ({'pid': True}, {'pid': 0}, {'pid': -1}, {'started': ''},
                       {'executable': m.EXPECTED.replace('MeasurementDerivedData', 'DerivedData')}):
            send = Mock()
            with self.subTest(change=change), self.assertRaises(ValueError):
                m.expire({**self.record(), **change}, verify=Mock(), send=send)
            send.assert_not_called()

    def test_changed_ownership_is_not_a_reason_to_signal_a_replacement(self):
        send = Mock()
        self.assertEqual(m.expire(self.record(), verify=Mock(side_effect=ValueError()), send=send),
                         'identity_changed_no_signal')
        send.assert_not_called()

    def test_failed_system_read_never_sends_a_signal(self):
        send = Mock()
        result = m.expire(self.record(), verify=Mock(side_effect=subprocess.CalledProcessError(1, 'ps')), send=send)
        self.assertEqual(result, 'identity_changed_no_signal')
        send.assert_not_called()

    def test_changed_start_is_rejected_even_when_pid_matches(self):
        with patch.object(m.processes, 'run_ps', side_effect=['snapshot', 'different start']), \
             patch.object(m.processes, 'check_snapshot', return_value=[12345]):
            with self.assertRaises(ValueError): m.verify_owned(self.record())

    def test_other_app_or_replacement_pid_is_rejected(self):
        for found in ([], [12346], [12345, 12346]):
            with patch.object(m.processes, 'run_ps', return_value='snapshot'), \
                 patch.object(m.processes, 'check_snapshot', return_value=found):
                with self.assertRaises(ValueError): m.verify_owned(self.record())

    def test_deadline_uses_monotonic_time_and_signals_only_the_original_pid(self):
        now = [50.0]
        send, verify = Mock(), Mock()
        def wait(seconds):
            send.assert_not_called()
            now[0] += seconds
        result = m.monitor(self.record(), 3, verify=verify, send=send,
                           clock=lambda: now[0], wait=wait)
        self.assertEqual(result['status'], 'deadline_stop_requested')
        self.assertEqual(result['elapsedSeconds'], 3)
        send.assert_called_once_with(12345, signal.SIGTERM)
        self.assertGreaterEqual(verify.call_count, 2)

    def test_ownership_loss_before_deadline_ends_without_signal(self):
        send = Mock()
        result = m.monitor(self.record(), 3, verify=Mock(side_effect=[None, ValueError()]),
                           send=send, clock=lambda: 0, wait=Mock())
        self.assertEqual(result['status'], 'identity_changed_no_signal')
        send.assert_not_called()

    def test_only_the_complete_fixed_steady_workload_accepts_300_seconds(self):
        flags = dict(steadyPublicVideo=True, mixedPublicPages=True,
                     prepareMixedBeforePlayback=True, audiblePublicVideo=False)
        record = {**self.record(), **flags}
        now = [0.0]
        send = Mock()
        result = m.monitor(record, 300, verify=Mock(), send=send,
                           clock=lambda: now[0], wait=lambda seconds: now.__setitem__(0, now[0] + seconds))
        self.assertEqual(result['elapsedSeconds'], 300)
        send.assert_called_once_with(record['pid'], signal.SIGTERM)
        for key in flags:
            bad = {**record, key: None}
            with self.subTest(key=key), self.assertRaises(ValueError):
                m.monitor(bad, 300, verify=Mock(), send=Mock())
        for seconds in (180, 181, 299, 301, True):
            with self.subTest(seconds=seconds), self.assertRaises(ValueError):
                m.monitor(record, seconds, verify=Mock(), send=Mock())

    def test_startup_is_published_only_after_ownership_verification(self):
        now = [10.0]
        verify, started, send = Mock(), Mock(), Mock()
        def publish(value):
            verify.assert_called_once()
            send.assert_not_called()
            self.assertEqual(value, dict(status='monitoring', pid=12345,
                                         maximumSeconds=1, startedMonotonic=10.0))
            started(value)
        m.monitor(self.record(), 1, verify=verify, send=send, on_started=publish,
                  clock=lambda: now[0], wait=lambda seconds: now.__setitem__(0, now[0] + seconds))
        started.assert_called_once()
        for bad_seconds, bad_verify in [(181, Mock()), (1, Mock(side_effect=ValueError()))]:
            started = Mock()
            with self.assertRaises(ValueError):
                m.monitor(self.record(), bad_seconds, verify=bad_verify, send=Mock(), on_started=started)
            started.assert_not_called()

    def test_invalid_or_extended_lifetimes_are_rejected(self):
        for seconds in (0, 181, True, 1.5):
            with self.assertRaises(ValueError): m.monitor(self.record(), seconds, verify=Mock(), send=Mock())


if __name__ == '__main__': unittest.main()
