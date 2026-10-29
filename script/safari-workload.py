#!/usr/bin/env python3
"""Prepare a fresh, externally owned Safari automation session for 20/50 pages.

The caller must verify the driver listener, Safari process and window ownership
inside health(), and bound every request. This module never discovers, launches,
quits or signals apps, changes permissions, or captures memory/screenshots.
"""
import importlib.util
import json
import math
from pathlib import Path
import re
import stat
import time

ROOT = Path(__file__).resolve().parent.parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'script' / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


idle = load('safari_workload_idle', 'idle-workload.py')
measure = load('safari_workload_measure', 'measure-memory.py')
COHORT = ('kind', 'transport', 'run_id', 'expected_tabs', 'urls', 'origins', 'document_hashes')


def read_state(path):
    path = Path(path)
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError('Fixture state must be a real regular file')
    with path.open('rb') as stream:
        data = stream.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise ValueError('Fixture state exceeds one MiB')
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError('Fixture state must be an object')
    return value


def handle(value):
    if (not isinstance(value, str) or not 0 < len(value) <= 256
            or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise ValueError('Invalid automation context handle')
    return value


def handles(value):
    if not isinstance(value, list):
        raise ValueError('Context handles must be a list')
    result = [handle(item) for item in value]
    if len(set(result)) != len(result):
        raise ValueError('Duplicate automation context handles')
    return result


def prepare_tabs(request, session, state_path, *, count, viewport, expected_hashes,
                 health, max_seconds=180, clock=time.monotonic, sleep=time.sleep):
    """Return validated fixture state, viewport and handles; never take RAM.

    Only fixed loopback/SSE fixture URLs are accepted. Hashes come from the peer
    cohort, not an arbitrary previously saved twenty-page result. Callers retain
    their own cleanup responsibility even if preparation fails part-way through.
    """
    idle.validate_count(count)
    if not isinstance(session, str) or re.fullmatch(r'[A-Za-z0-9-]{1,128}', session) is None:
        raise ValueError('Invalid automation session identifier')
    if (not isinstance(viewport, dict) or set(viewport) != {'width', 'height', 'dpr'}
            or any(type(viewport[k]) is not int or not 100 <= viewport[k] <= 4096 for k in ('width', 'height'))
            or type(viewport['dpr']) not in (int, float) or not math.isfinite(viewport['dpr'])
            or not .5 <= viewport['dpr'] <= 4):
        raise ValueError('Explicit bounded viewport and display scale are required')
    if type(max_seconds) not in (int, float) or not math.isfinite(max_seconds) or not 0 < max_seconds <= 300:
        raise ValueError('Preparation requires a bounded deadline')
    initial = read_state(state_path)
    idle.validate_state(initial, count=count)
    keys = {str(n) for n in range(1, count + 1)}
    if (not isinstance(expected_hashes, dict) or set(expected_hashes) != keys
            or any(not isinstance(x, str) or re.fullmatch('[0-9a-f]{64}', x) is None for x in expected_hashes.values())
            or initial.get('document_hashes') != expected_hashes
            or initial.get('origins') != {k: initial['urls'][k].rsplit('/document/', 1)[0] for k in keys}
            or not isinstance(initial.get('run_id'), str) or not initial['run_id']):
        raise ValueError('The peer document hashes or fresh fixture identity differ')
    endpoint = '/session/' + session
    deadline = clock() + max_seconds

    def check():
        if clock() >= deadline:
            raise TimeoutError('Safari workload preparation deadline exceeded')
        health()
        if clock() >= deadline:
            raise TimeoutError('Safari workload preparation deadline exceeded')

    def call(method, path, data=None):
        check()
        value = request(method, endpoint + path, data)
        check()
        return value

    def new_tab():
        value = call('POST', '/window/new', {'type': 'tab'})
        if not isinstance(value, dict) or value.get('type') != 'tab':
            raise ValueError('The driver must create tabs, not separate windows')
        new = handle(value.get('handle'))
        if new in active:
            raise ValueError('The driver reused an existing tab')
        active.append(new)

    active = handles(call('GET', '/window/handles'))
    if len(active) != 1 or call('GET', '/url') != 'about:blank':
        raise ValueError('Preparation requires one fresh about:blank automation tab')
    # Fit with the tab strip already visible, before loading any document.
    new_tab()
    call('POST', '/window', {'handle': active[0]})
    for attempt in range(4):
        rect = call('GET', '/window/rect')
        view = call('POST', '/execute/sync', {'script': 'return {width:innerWidth,height:innerHeight,dpr:devicePixelRatio};', 'args': []})
        if (not isinstance(view, dict) or set(view) != set(viewport)
                or any(type(x) not in (int, float) or not math.isfinite(x) for x in view.values())
                or any(not 0 < view[k] <= 8192 for k in ('width', 'height'))
                or view['dpr'] != viewport['dpr']):
            raise ValueError('Viewport or display scale cannot be matched')
        if view == viewport:
            break
        if attempt == 3:
            raise ValueError('Viewport did not converge within three adjustments')
        if not isinstance(rect, dict) or any(type(rect.get(k)) not in (int, float) or not math.isfinite(rect[k]) for k in ('width', 'height')):
            raise ValueError('Invalid automation window geometry')
        target = {k: rect[k] + viewport[k] - view[k] for k in ('width', 'height')}
        if any(not float(x).is_integer() or not 100 <= x <= 4096 for x in target.values()):
            raise ValueError('Adjusted window geometry is outside the fixed workload bounds')
        call('POST', '/window/rect', {k: int(v) for k, v in target.items()})

    for number in range(1, count + 1):
        key = str(number)
        if number > 2:
            new_tab()
        call('POST', '/window', {'handle': active[number - 1]})
        call('POST', '/url', {'url': initial['urls'][key]})
        ready_by = min(deadline, clock() + 10)
        while True:
            check()
            state = read_state(state_path)
            if any(state.get(k) != initial.get(k) for k in COHORT) or state.get('invalid_reason'):
                raise ValueError('The fixed fixture cohort changed during preparation')
            document = state.get('documents', {}).get(key, {})
            streams = state.get('stream_connections', {})
            if (not isinstance(streams, dict) or set(streams) != keys
                    or any(type(x) is not int or x not in (0, 1) for x in streams.values())
                    or any(streams[str(n)] != 1 for n in range(1, number))):
                raise ValueError('A fixture document reconnected or has invalid stream state')
            starts = streams[key]
            if (starts == 1 and document.get('complete') is True and document.get('seenVisible') is True
                    and type(document.get('pulse')) is int and document['pulse'] > 0):
                break
            remaining = ready_by - clock()
            if remaining <= 0:
                raise TimeoutError('A fixture tab did not visibly load before its deadline')
            sleep(min(.1, remaining))
    actual = handles(call('GET', '/window/handles'))
    if len(actual) != count or set(actual) != set(active) or call('GET', '/window') != active[-1]:
        raise ValueError('Automation tabs or selection changed')
    if call('GET', '/url') != initial['urls'][str(count)]:
        raise ValueError('The final selected tab is not the expected loopback document')
    check()
    final = read_state(state_path)
    idle.validate_state(final, completed=True, count=count)
    measure.check_fixture(final, now=clock())
    if any({k: d.get(k) for k in viewport} != viewport for d in final['documents'].values()):
        raise ValueError('Document viewports differ from the matched viewport')
    if any(final.get(k) != initial.get(k) for k in COHORT):
        raise ValueError('The final fixture cohort differs from the peer cohort')
    check()
    return {'state': final, 'viewport': dict(viewport), 'handles': active}
