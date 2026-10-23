#!/usr/bin/env python3
"""Prepare an isolated twenty-tab test; optionally capture one footprint sample, never page content."""
import argparse
import signal
import sys
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


def application(variant):
    if variant not in ('Profile', 'Measurement'):
        raise ValueError('Only isolated Profile or Measurement is allowed')
    identifier = 'dev.fomalhaut16.Levistica.' + ('profile' if variant == 'Profile' else 'measurement')
    executable = next(path for path, value in processes.known_apps(ROOT).items() if value == identifier)
    return identifier, executable


def verify_application(workload):
    variant = workload.get('variant')
    _, expected = application(variant)
    snapshot = processes.run_ps(['-axo', 'pid=,comm='])
    if snapshot is None:
        raise ValueError('Process enumeration failed')
    pids = processes.check_snapshot(snapshot, ROOT, processes.describe_process, os.getuid(), only=variant)
    if (pids != [workload['pid']] or workload['executable'] != expected
            or processes.run_ps(['-p', str(workload['pid']), '-o', 'lstart=']) != workload['started']):
        raise ValueError('Isolated app identity changed; no URLs delivered')


def measurement_result(text):
    matches = [line.removeprefix('Local evidence: ') for line in text.splitlines() if line.startswith('Local evidence: ')]
    if len(matches) != 1:
        raise ValueError('Measurement did not publish exactly one result path')
    result = pathlib.Path(matches[0]).resolve()
    if result.name != 'result.json' or not result.is_relative_to(ROOT / '.local/artifacts/memory'):
        raise ValueError('Measurement result is outside the local evidence directory')
    return result


def run_capture(command):
    def interrupted(_signum, _frame):
        raise InterruptedError('Memory collector interrupted')
    previous_handler = signal.signal(signal.SIGTERM, interrupted)
    process = None
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        stdout, stderr = process.communicate(timeout=45)
        return process.returncode, stdout, stderr
    except BaseException:
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        raise
    finally:
        signal.signal(signal.SIGTERM, previous_handler)


def capture_memory(state_path, workload_path):
    workload = json.loads(workload_path.read_text())
    if workload.get('variant') != 'Measurement':
        raise ValueError('RAM capture requires the non-debuggable Measurement app')
    spec = importlib.util.spec_from_file_location('measure_memory', ROOT / 'script/measure-memory.py')
    measure = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(measure)
    deadline = time.monotonic() + 100
    baseline = None
    while time.monotonic() < deadline:
        verify_application(workload)
        pressure()
        state = json.loads(state_path.read_text())
        if (state.get('invalid_reason') or state.get('loads', 0) > 20
                or any(value > 1 for value in state.get('stream_connections', {}).values())):
            raise ValueError('Workload reloaded or reconnected before measurement readiness')
        try:
            validate_state(state, completed=True)
            measure.check_fixture(state)
        except ValueError:
            time.sleep(1)
            continue
        baseline = state
        break
    if baseline is None:
        raise ValueError('Twenty documents did not become ready within one hundred seconds')
    ready_at = time.monotonic()
    while time.monotonic() - ready_at < 60:
        verify_application(workload)
        pressure()
        measure.check_fixture(json.loads(state_path.read_text()), baseline)
        time.sleep(min(5, max(0, 60 - (time.monotonic() - ready_at))))
    verify_application(workload)
    measure.check_fixture(json.loads(state_path.read_text()), baseline)
    command = [sys.executable, str(ROOT / 'script/measure-memory.py'), '--browser', 'levistica-measurement',
               '--ready-file', str(state_path), '--ready-delay', '60', '--label', 'twenty-release-idle',
               '--total-tabs', '20', '--loaded-pages', '20', '--samples', '1', '--interval', '0']
    # The new process group contains only our read-only measurement tools.
    # Bound the whole collector as well as each tool's existing timeout.
    returncode, stdout, stderr = run_capture(command)
    log = state_path.with_name('memory-capture.log')
    log.write_text(stdout + stderr)
    log.chmod(0o600)
    result = measurement_result(stdout)
    document = json.loads(result.read_text())
    verify_application(workload)
    pressure()
    measure.check_fixture(json.loads(state_path.read_text()), baseline)
    if (returncode != 0 or document.get('browser') != 'levistica-measurement'
            or document.get('pid') != workload['pid'] or document.get('valid_sample_count') != 1
            or len(document.get('samples', [])) != 1 or document.get('loaded_pages') != 20
            or document.get('total_tabs') != 20):
        raise ValueError('The single RAM sample is missing, invalid, or belongs to another app')
    summary = {'result': str(result), 'pid': workload['pid'], 'minimumStableReadySeconds': 60,
               'secondsFromStableReadinessAtCompletion': time.monotonic() - ready_at,
               'comparisonAccepted': False, 'requiresSuccessfulUITrial': True}
    output = state_path.with_name('memory-capture.json')
    output.write_text(json.dumps(summary) + '\n')
    output.chmod(0o600)
    print('One isolated Release sample captured; UI outcome still required; no comparison conclusion.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'deliver', 'monitor', 'validate', 'capture'])
    parser.add_argument('state', type=pathlib.Path)
    parser.add_argument('output', nargs='?', type=pathlib.Path)
    parser.add_argument('--variant', choices=['Profile', 'Measurement'], default='Profile')
    args = parser.parse_args()
    if args.mode == 'monitor':
        monitor(args.state)
        return
    if args.mode == 'capture':
        if args.output is None:
            parser.error('capture requires the workload file')
        capture_memory(args.state, args.output)
        return
    state = json.loads(args.state.read_text())
    validate_state(state, completed=args.mode == 'validate')
    if args.mode == 'deliver':
        if args.output is None:
            parser.error('deliver requires the workload file')
        workload = json.loads(args.output.read_text())
        if workload['urls'] != state['urls']:
            raise ValueError('Workload does not match this fresh fixture')
        verify_application(workload)
        pressure()
        app = pathlib.Path(workload['executable']).parents[2]
        subprocess.run(['/usr/bin/open', '-a', str(app), *[state['urls'][str(n)] for n in range(1, 21)]],
                       check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        verify_application(workload)
        return
    if args.mode == 'validate':
        print('Twenty documents displayed without reload or reconnect; workload validation passed.')
        return
    if args.output is None:
        parser.error('prepare requires an output file')
    pressure()
    _, executable = application(args.variant)
    snapshot = processes.run_ps(['-axo', 'pid=,comm='])
    if snapshot is None:
        raise ValueError('Process enumeration failed')
    pids = processes.check_snapshot(snapshot, ROOT, processes.describe_process, os.getuid(), only=args.variant)
    if len(pids) != 1:
        raise ValueError('Exactly one verified isolated app process is required')
    started = processes.run_ps(['-p', str(pids[0]), '-o', 'lstart='])
    if not started:
        raise ValueError('Isolated app exited during preparation')
    args.output.write_text(json.dumps({'variant': args.variant, 'pid': pids[0], 'executable': executable, 'started': started, 'urls': state['urls'],
        'state': str(args.state.resolve()), 'health': str(args.state.with_name('idle-health.json').resolve())}) + '\n')
    args.output.chmod(0o600)


if __name__ == '__main__':
    main()
