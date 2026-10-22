#!/usr/bin/env python3
"""Fail-closed contract for five loaded pages versus four manually sleeping pages.

This checks synthetic server evidence. The operator must separately record the
app's five total tabs and loaded-page count; stream closure alone is not app sleep.
"""
import argparse
import copy
import importlib.util
import json
import math
import pathlib
import time

KEYS = {str(i) for i in range(1, 6)}
FIXED = ('kind', 'transport', 'run_id', 'expected_tabs', 'document_hashes', 'urls',
         'origins', 'ready_monotonic')


def loaded_contract(state, checker, now):
    if state.get('kind') != 'sleep-documents' or state.get('transport') != 'same-origin-sse-lifecycle-v1':
        raise ValueError('A lifecycle fixture is required')
    converted = {**state, 'kind': 'cross-site-documents', 'transport': 'same-origin-sse-v1'}
    if type(state.get('expected_tabs')) is not int or state['expected_tabs'] != 5:
        raise ValueError('Exactly five documents are required')
    ready = state.get('ready_monotonic')
    if type(ready) not in (int, float) or not math.isfinite(ready) or not 0 < ready <= now:
        raise ValueError('Invalid workload readiness time')
    checker(converted, now=now)
    for field in ('document_loads', 'active_streams'):
        values = state.get(field, {})
        if set(values) != KEYS or any(type(v) is not int or v != 1 for v in values.values()):
            raise ValueError('Every document must be loaded and connected once')
    for doc in state['documents'].values():
        value = doc.get('firstVisibleReadyMS')
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 600000:
            raise ValueError('Visible readiness timing is missing')


def capture(state, checker, now=None):
    now = time.monotonic() if now is None else now
    if type(now) not in (int, float) or not math.isfinite(now) or now <= 0:
        raise ValueError('Invalid capture time')
    loaded_contract(state, checker, now)
    return {'schema': 1, 'captured_monotonic': now, 'state': copy.deepcopy(state)}


def cycle_counts(state, cycle):
    if type(cycle) is not int or not 1 <= cycle <= 5:
        raise ValueError('Only five sleep cycles are supported')
    expected = {key: (1 if key == '5' else cycle) for key in KEYS}
    if type(state.get('loads')) is not int or state['loads'] != 4 * cycle + 1:
        raise ValueError('Unexpected cycle load count')
    for field in ('document_loads', 'stream_connections'):
        values = state.get(field, {})
        if set(values) != KEYS or any(type(v) is not int for v in values.values()) or values != expected:
            raise ValueError('Unexpected cycle document or connection counts')


def normalized_cycle(state, cycle):
    # Check actual cumulative counters before adapting to the single-cycle contract.
    cycle_counts(state, cycle)
    return {**state, 'loads': 5, 'document_loads': dict.fromkeys(KEYS, 1),
            'stream_connections': dict.fromkeys(KEYS, 1)}


def cycle_history(checkpoint, checker, now):
    if checkpoint.get('schema') != 1 or checkpoint.get('kind') != 'sleep-cycle-checkpoint':
        raise ValueError('Invalid cycle checkpoint')
    history = checkpoint.get('history')
    if not isinstance(history, list) or not 1 <= len(history) <= 5:
        raise ValueError('Invalid cycle history length')
    prior = None
    for cycle, entry in enumerate(history, 1):
        captured = entry.get('captured_monotonic')
        if type(captured) not in (int, float) or not math.isfinite(captured) or not 0 < captured <= now:
            raise ValueError('Invalid cycle capture time')
        state = entry.get('state', {})
        loaded_contract(normalized_cycle(state, cycle), checker, captured)
        if prior is not None:
            previous = prior['state']
            if captured <= prior['captured_monotonic'] or any(state.get(k) != previous.get(k) for k in FIXED):
                raise ValueError('Cycle identity or order changed')
            for key in KEYS:
                old, new = previous['documents'][key], state['documents'][key]
                if any(old.get(k) != new.get(k) for k in ('origin', 'width', 'height', 'dpr', 'visibility')):
                    raise ValueError('Cycle viewport or selection changed')
                if key == '5':
                    if (new['instance'] != old['instance'] or new['pulse'] < old['pulse']
                            or new['firstVisibleReadyMS'] != old['firstVisibleReadyMS']):
                        raise ValueError('The retained document changed')
                elif new['instance'] == old['instance']:
                    raise ValueError('A resumed document must have a new instance')
        prior = entry
    return history


def capture_cycle(state, checker, previous=None, now=None):
    now = time.monotonic() if now is None else now
    if type(now) not in (int, float) or not math.isfinite(now) or now <= 0:
        raise ValueError('Invalid cycle capture time')
    history = copy.deepcopy(cycle_history(previous, checker, now)) if previous is not None else []
    result = {'schema': 1, 'kind': 'sleep-cycle-checkpoint',
              'history': history + [{'captured_monotonic': now, 'state': copy.deepcopy(state)}]}
    cycle_history(result, checker, now)
    return result


def check_cycle(current, original, checker, now=None):
    now = time.monotonic() if now is None else now
    if current.get('kind') != 'manual-sleep-cycle':
        raise ValueError('Invalid cycle phase kind')
    checkpoint = current.get('cycle_checkpoint', {})
    history = cycle_history(checkpoint, checker, now)
    if original is not None and checkpoint != original.get('cycle_checkpoint'):
        raise ValueError('Cycle history changed during sampling')

    def adapted(phase):
        last = phase['cycle_checkpoint']['history'][-1]
        number = len(phase['cycle_checkpoint']['history'])
        return {'kind': 'manual-sleep', 'ready_monotonic': phase.get('ready_monotonic'),
                'memory_pressure_level': phase.get('memory_pressure_level'),
                'sleeping_documents': ['1', '2', '3', '4'],
                'sleep_checkpoint': {'schema': 1, 'captured_monotonic': last['captured_monotonic'],
                                     'state': normalized_cycle(last['state'], number)},
                'workload': normalized_cycle(phase.get('workload', {}), number)}

    check(adapted(current), adapted(original) if original is not None else None, checker, now=now)


def check(current, original, checker, now=None):
    now = time.monotonic() if now is None else now
    ready = current.get('ready_monotonic')
    if (current.get('kind') != 'manual-sleep' or type(ready) not in (int, float)
            or not math.isfinite(ready) or not 0 < ready <= now):
        raise ValueError('Invalid sleep phase time')
    checkpoint = current.get('sleep_checkpoint', {})
    captured = checkpoint.get('captured_monotonic')
    if (checkpoint.get('schema') != 1 or type(captured) not in (int, float)
            or not math.isfinite(captured) or not 0 < captured <= now):
        raise ValueError('Invalid sleep checkpoint time')
    baseline = checkpoint.get('state', {})
    loaded_contract(baseline, checker, captured)
    sleeping = current.get('sleeping_documents')
    if sleeping not in ([], ['1', '2', '3', '4']):
        raise ValueError('Only zero or four sleeping documents are supported')
    if current.get('memory_pressure_level') != 1 or type(current['memory_pressure_level']) is not int:
        raise ValueError('Memory pressure must remain at level one')
    state = current.get('workload', {})
    if any(state.get(k) != baseline.get(k) for k in FIXED) or state.get('invalid_reason'):
        raise ValueError('Sleep workload identity changed')
    if type(state.get('loads')) is not int or state['loads'] != 5:
        raise ValueError('A document was reloaded')
    docs = state.get('documents', {})
    if set(docs) != KEYS:
        raise ValueError('A document is missing')
    for field in ('document_loads', 'stream_connections', 'active_streams'):
        values = state.get(field, {})
        if set(values) != KEYS or any(type(v) is not int for v in values.values()):
            raise ValueError('Invalid stream or document counters')
    for key, doc in docs.items():
        prior = baseline['documents'][key]
        # Disposal of a foreground page need not deliver a final hidden report.
        # Its last visibility is historical; closed streams and silence are required.
        asleep = key in sleeping
        if (any(doc.get(k) != prior.get(k) for k in ('instance', 'origin', 'width', 'height', 'dpr', 'firstVisibleReadyMS'))
                or doc.get('seenVisible') is not True or doc.get('complete') is not True
                or type(doc.get('sections')) is not int or doc['sections'] != 240
                or type(doc.get('pulse')) is not int or doc['pulse'] < prior['pulse']
                or (asleep and doc.get('visibility') not in ('visible', 'hidden'))
                or (not asleep and doc.get('visibility') != ('visible' if key == '5' else 'hidden'))):
            raise ValueError('Document instance, selection, or viewport changed')
        reported = doc.get('reported_monotonic')
        if type(reported) not in (int, float) or not math.isfinite(reported) or not captured - 15 <= reported <= now:
            raise ValueError('Invalid document report time')
        if (state['document_loads'][key] != 1 or state['stream_connections'][key] != 1
                or state['active_streams'][key] != (0 if asleep else 1)):
            raise ValueError('Document reloaded, reconnected, or stream state mismatches sleep')
        age = now - reported
        if (asleep and age < 10) or (not asleep and age > 15):
            raise ValueError('Sleeping reports must be quiet; loaded reports must be fresh')
        if original is not None and asleep and doc != original['workload']['documents'][key]:
            raise ValueError('A sleeping document reported again')
        if original is not None and doc['pulse'] < original['workload']['documents'][key]['pulse']:
            raise ValueError('Document pulse moved backwards')
    if original is not None and any(current.get(k) != original.get(k) for k in
                                    ('sleep_checkpoint', 'sleeping_documents', 'ready_monotonic')):
        raise ValueError('Sleep phase changed during sampling')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--cycle', action='store_true', help='Capture an all-loaded checkpoint for cycles 1..5')
    parser.add_argument('--previous-cycle', type=pathlib.Path, help='Previous cycle checkpoint; requires cycle')
    args = parser.parse_args()
    if args.previous_cycle and not args.cycle:
        parser.error('previous-cycle requires cycle')
    spec = importlib.util.spec_from_file_location('memory_measurement', pathlib.Path(__file__).with_name('measure-memory.py'))
    measure = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(measure)
    state = json.loads(args.state.read_text())
    if args.cycle:
        previous = json.loads(args.previous_cycle.read_text()) if args.previous_cycle else None
        checkpoint = capture_cycle(state, measure.check_fixture, previous)
    else:
        checkpoint = capture(state, measure.check_fixture)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as file:
        json.dump(checkpoint, file, indent=2)
        file.write('\n')
    print(args.output)


if __name__ == '__main__':
    main()
