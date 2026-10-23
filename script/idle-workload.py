#!/usr/bin/env python3
"""Prepare an isolated twenty-tab revisit test; never collects RAM or page content."""
import argparse
import importlib.util
import json
import os
import pathlib
import subprocess
import time
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('app_processes', ROOT / 'script/check-app-processes.py')
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)


def validate_state(state, completed=False):
    keys = {str(n) for n in range(1, 21)}
    if (state.get('kind') != 'cross-site-documents' or state.get('expected_tabs') != 20
            or state.get('transport') != 'same-origin-sse-v1' or state.get('invalid_reason')
            or state.get('loads') != (20 if completed else 0)
            or set(state.get('urls', {})) != keys):
        raise ValueError('Expected a fresh or completed twenty-host fixture')
    ports = set()
    for key, value in state['urls'].items():
        url = urllib.parse.urlsplit(value)
        if (url.scheme != 'http' or url.hostname != f'document-{key}.localhost'
                or url.path != f'/document/{key}' or url.username is not None
                or url.password is not None or url.query or url.fragment or not url.port):
            raise ValueError('Unexpected fixture URL')
        ports.add(url.port)
    if len(ports) != 1:
        raise ValueError('Fixture ports must match')
    expected = {key: 1 if completed else 0 for key in keys}
    if state.get('stream_connections') != expected:
        raise ValueError('Unexpected stream starts; do not retry automatically')
    if completed:
        documents = state.get('documents', {})
        if set(documents) != keys or not all(d.get('complete') and d.get('seenVisible')
                and d.get('sections') == 240 and d.get('pulse', 0) > 0 for d in documents.values()):
            raise ValueError('Every document must have been displayed')
    elif state.get('documents'):
        raise ValueError('Preparation requires untouched documents')


def pressure():
    value = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level'],
                                    text=True, stderr=subprocess.PIPE, timeout=3).strip()
    if value != '1':
        raise ValueError('Memory pressure differs from the required starting level')
    return 1


def monitor(output):
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline:
        record = {'checkedAt': time.time(), 'ok': False}
        try:
            record['level'] = pressure()
            record['ok'] = True
        except (OSError, ValueError, subprocess.SubprocessError):
            record['reason'] = 'Pressure changed or could not be read'
        temporary = output.with_suffix('.tmp')
        temporary.write_text(json.dumps(record) + '\n')
        temporary.chmod(0o600)
        temporary.replace(output)
        if not record['ok']:
            return
        time.sleep(5)


def verify_profile(workload):
    snapshot = processes.run_ps(['-axo', 'pid=,comm='])
    if snapshot is None:
        raise ValueError('Process enumeration failed')
    pids = processes.check_snapshot(snapshot, ROOT, processes.describe_process, os.getuid(), only='Profile')
    expected = next(path for path, identifier in processes.known_apps(ROOT).items() if identifier.endswith('.profile'))
    if (pids != [workload['pid']] or workload['executable'] != expected
            or processes.run_ps(['-p', str(workload['pid']), '-o', 'lstart=']) != workload['started']):
        raise ValueError('Profile identity changed; no URLs delivered')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'deliver', 'monitor', 'validate'])
    parser.add_argument('state', type=pathlib.Path)
    parser.add_argument('output', nargs='?', type=pathlib.Path)
    args = parser.parse_args()
    if args.mode == 'monitor':
        monitor(args.state)
        return
    state = json.loads(args.state.read_text())
    validate_state(state, completed=args.mode == 'validate')
    if args.mode == 'deliver':
        if args.output is None:
            parser.error('deliver requires the workload file')
        workload = json.loads(args.output.read_text())
        if workload['urls'] != state['urls']:
            raise ValueError('Workload does not match this fresh fixture')
        verify_profile(workload)
        pressure()
        app = pathlib.Path(workload['executable']).parents[2]
        subprocess.run(['/usr/bin/open', '-a', str(app), *[state['urls'][str(n)] for n in range(1, 21)]],
                       check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        verify_profile(workload)
        return
    if args.mode == 'validate':
        print('Twenty documents displayed without reload or reconnect; no RAM measurement.')
        return
    if args.output is None:
        parser.error('prepare requires an output file')
    pressure()
    snapshot = processes.run_ps(['-axo', 'pid=,comm='])
    if snapshot is None:
        raise ValueError('Process enumeration failed')
    pids = processes.check_snapshot(snapshot, ROOT, processes.describe_process, os.getuid(), only='Profile')
    if len(pids) != 1:
        raise ValueError('Exactly one verified Profile process is required')
    executable = next(path for path, identifier in processes.known_apps(ROOT).items() if identifier.endswith('.profile'))
    started = processes.run_ps(['-p', str(pids[0]), '-o', 'lstart='])
    if not started:
        raise ValueError('Profile exited during preparation')
    args.output.write_text(json.dumps({'pid': pids[0], 'executable': executable, 'started': started, 'urls': state['urls'],
        'state': str(args.state.resolve()), 'health': str(args.state.with_name('idle-health.json').resolve())}) + '\n')
    args.output.chmod(0o600)


if __name__ == '__main__':
    main()
