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

    def test_invalid_or_extended_lifetimes_are_rejected(self):
        for seconds in (0, 181, True, 1.5):
            with self.assertRaises(ValueError): m.monitor(self.record(), seconds, verify=Mock(), send=Mock())


if __name__ == '__main__': unittest.main()
