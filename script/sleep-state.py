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
        if (any(doc.get(k) != prior.get(k) for k in ('instance', 'origin', 'width', 'height', 'dpr', 'firstVisibleReadyMS'))
                or doc.get('seenVisible') is not True or doc.get('complete') is not True
                or type(doc.get('sections')) is not int or doc['sections'] != 240
                or type(doc.get('pulse')) is not int or doc['pulse'] < prior['pulse']
                or doc.get('visibility') != ('visible' if key == '5' else 'hidden')):
            raise ValueError('Document instance, selection, or viewport changed')
        reported = doc.get('reported_monotonic')
        if type(reported) not in (int, float) or not math.isfinite(reported) or not captured - 15 <= reported <= now:
            raise ValueError('Invalid document report time')
        asleep = key in sleeping
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
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('memory_measurement', pathlib.Path(__file__).with_name('measure-memory.py'))
    measure = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(measure)
    checkpoint = capture(json.loads(args.state.read_text()), measure.check_fixture)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as file:
        json.dump(checkpoint, file, indent=2)
        file.write('\n')
    print(args.output)


if __name__ == '__main__':
    main()
