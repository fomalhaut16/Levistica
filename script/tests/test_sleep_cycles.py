import copy
import unittest
import uuid

from test_sleep_state import contract, measure, workload


class SleepCycleTests(unittest.TestCase):
    def history(self, count):
        state = workload()
        history = None
        for cycle in range(1, count + 1):
            now = 100 + 200 * (cycle - 1)
            if cycle > 1:
                for key in ['1', '2', '3', '4']:
                    state['documents'][key].update(instance=str(uuid.uuid4()), pulse=1,
                                                   firstVisibleReadyMS=30 + cycle)
            for key in contract.KEYS:
                state['documents'][key]['reported_monotonic'] = now - 1
                state['documents'][key]['pulse'] += 10
            state['loads'] = 4 * cycle + 1
            state['document_loads'].update({k: cycle for k in ['1', '2', '3', '4']})
            state['stream_connections'].update({k: cycle for k in ['1', '2', '3', '4']})
            history = contract.capture_cycle(state, measure.check_fixture, history, now=now)
        return history

    def phase(self, cycle):
        checkpoint = self.history(cycle)
        now = checkpoint['history'][-1]['captured_monotonic'] + 20
        state = copy.deepcopy(checkpoint['history'][-1]['state'])
        state['active_streams'].update(dict.fromkeys(['1', '2', '3', '4'], 0))
        for key in ['1', '2', '3', '4']:
            state['documents'][key]['visibility'] = 'visible'
        state['documents']['5'].update(reported_monotonic=now - 1, pulse=10000)
        return {'kind': 'manual-sleep-cycle', 'ready_monotonic': now - 1,
                'cycle_checkpoint': checkpoint, 'memory_pressure_level': 1, 'workload': state}, now

    def test_five_cycles_preserve_retained_document_and_allow_new_resumed_instances(self):
        for cycle in range(1, 6):
            phase, now = self.phase(cycle)
            measure.check_fixture(phase, now=now)
            later = copy.deepcopy(phase)
            later['workload']['documents']['5'].update(reported_monotonic=now + 4, pulse=10001)
            measure.check_fixture(later, phase, now=now + 5)

    def test_cycle_capture_rejects_a_sixth_cycle(self):
        history = self.history(5)
        with self.assertRaises(ValueError):
            contract.capture_cycle(history['history'][-1]['state'], measure.check_fixture,
                                   history, now=1100)

    def test_rejects_skipped_reload_reconnect_and_invalid_counter_types(self):
        phase, now = self.phase(3)
        for field, key, value in [('document_loads', '1', 2), ('stream_connections', '1', 4),
                                  ('active_streams', '1', 1), ('document_loads', '5', True)]:
            changed = copy.deepcopy(phase)
            changed['workload'][field][key] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                measure.check_fixture(changed, now=now)

    def test_history_rejects_reused_instance_retained_page_reload_and_viewport_change(self):
        history = self.history(3)
        last = history['history'][-1]
        previous = history['history'][-2]
        for key, field, value in [('1', 'instance', previous['state']['documents']['1']['instance']),
                                  ('5', 'instance', str(uuid.uuid4())), ('1', 'width', 800),
                                  ('5', 'firstVisibleReadyMS', 99), ('5', 'pulse', 0)]:
            changed = copy.deepcopy(history)
            changed['history'][-1]['state']['documents'][key][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                contract.cycle_history(changed, measure.check_fixture, last['captured_monotonic'])
        changed = copy.deepcopy(history)
        changed['history'][-1]['captured_monotonic'] = previous['captured_monotonic']
        with self.assertRaises(ValueError):
            contract.cycle_history(changed, measure.check_fixture, last['captured_monotonic'])

    def test_sampling_rejects_changed_history_quiet_page_report_and_stale_retained_page(self):
        phase, now = self.phase(2)
        changed = copy.deepcopy(phase)
        changed['cycle_checkpoint']['history'][0]['state']['documents']['1']['firstVisibleReadyMS'] += 1
        with self.assertRaises(ValueError):
            measure.check_fixture(changed, phase, now=now)
        for key, value in [('1', now - 10), ('5', now - 16)]:
            changed = copy.deepcopy(phase)
            changed['workload']['documents'][key]['reported_monotonic'] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                measure.check_fixture(changed, phase, now=now)

    def test_cycle_checkpoint_does_not_relax_single_cycle_contract(self):
        phase, now = self.phase(2)
        state = phase['cycle_checkpoint']['history'][-1]['state']
        with self.assertRaises(ValueError):
            contract.capture(state, measure.check_fixture, now=now)
        changed = copy.deepcopy(phase)
        changed['cycle_checkpoint']['history'] = []
        with self.assertRaises(ValueError):
            measure.check_fixture(changed, now=now)
