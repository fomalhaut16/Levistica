#!/usr/bin/env python3
"""Fixed-PID Measurement lifetime guard; no GUI calls, relaunch, or data cleanup."""
import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('deadline_processes', ROOT / 'script/check-app-processes.py')
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)
EXPECTED = str(ROOT / '.local/MeasurementDerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica')


def validate(record):
    if (type(record.get('pid')) is not int or record['pid'] <= 0
            or record.get('executable') != EXPECTED
            or not isinstance(record.get('started'), str) or not record['started'].strip()):
        raise ValueError('Expected the fixed canonical Measurement identity')


def verify_owned(record):
    validate(record)
    snapshot = processes.run_ps(['-axo', 'pid=,comm='])
    if snapshot is None:
        raise ValueError('Cannot enumerate owned apps')
    found = processes.check_snapshot(snapshot, ROOT, processes.describe_process, os.getuid(), only='Measurement')
    if found != [record['pid']]:
        raise ValueError('Owned app set changed')
    if processes.run_ps(['-p', str(record['pid']), '-o', 'lstart=']) != record['started']:
        raise ValueError('Owned process start changed')


def expire(record, verify=verify_owned, send=os.kill):
    """Recheck just before signalling; never search for a replacement PID."""
    validate(record)
    try:
        verify(record)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 'identity_changed_no_signal'
    try:
        send(record['pid'], signal.SIGTERM)
    except ProcessLookupError:
        return 'process_exited_no_signal'
    return 'deadline_stop_requested'


def validate_lifetime(record, seconds):
    steady = record.get('steadyPublicVideo') is True
    if steady:
        allowed = (seconds == 300 and type(seconds) is int
                   and record.get('mixedPublicPages') is True
                   and record.get('prepareMixedBeforePlayback') is True
                   and record.get('audiblePublicVideo') is False)
    else:
        allowed = type(seconds) is int and 1 <= seconds <= 180
    if not allowed:
        raise ValueError('Expected 1..180 seconds, or exactly 300 for the fixed steady public workload')


def monitor(record, seconds, verify=verify_owned, send=os.kill, clock=time.monotonic, wait=time.sleep,
            on_started=None):
    validate(record)
    validate_lifetime(record, seconds)
    # Establish ownership before starting the timer; monotonic time prevents clock edits extending it.
    verify(record)
    began = clock()
    if on_started is not None:
        on_started({"status": "monitoring", "pid": record["pid"],
                    "maximumSeconds": seconds, "startedMonotonic": began})
    deadline = began + seconds
    while True:
        remaining = deadline - clock()
        if remaining <= 0:
            return {'status': expire(record, verify, send), 'maximumSeconds': seconds,
                    'elapsedSeconds': round(clock() - began, 3), 'pid': record['pid']}
        wait(min(1, remaining))
        try:
            verify(record)
        except (OSError, ValueError, subprocess.SubprocessError):
            return {'status': 'identity_changed_no_signal', 'maximumSeconds': seconds,
                    'elapsedSeconds': round(clock() - began, 3), 'pid': record['pid']}


def prepare(output):
    snapshot = processes.run_ps(['-axo', 'pid=,comm='])
    if snapshot is None:
        raise ValueError('Cannot enumerate owned apps')
    found = processes.check_snapshot(snapshot, ROOT, processes.describe_process, os.getuid(), only='Measurement')
    if len(found) != 1:
        raise ValueError('Exactly one canonical Measurement is required')
    started = processes.run_ps(['-p', str(found[0]), '-o', 'lstart='])
    if not started:
        raise ValueError('Measurement exited before preparation')
    record = {'pid': found[0], 'executable': EXPECTED, 'started': started,
              'startedEpoch': datetime.datetime.strptime(' '.join(started.split()), '%a %b %d %H:%M:%S %Y').timestamp()}
    verify_owned(record)
    output.write_text(json.dumps(record, indent=2) + '\n')
    output.chmod(0o600)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest='mode', required=True)
    prepare_parser = modes.add_parser('prepare')
    prepare_parser.add_argument('output', type=Path)
    monitor_parser = modes.add_parser('monitor')
    monitor_parser.add_argument('workload', type=Path)
    monitor_parser.add_argument('result', type=Path)
    monitor_parser.add_argument('--seconds', type=int, default=180)
    monitor_parser.add_argument('--started', type=Path)
    args = parser.parse_args()
    if args.mode == 'prepare':
        prepare(args.output)
    else:
        record = json.loads(args.workload.read_text())
        def started(value):
            if args.started is not None:
                temporary = args.started.with_name(args.started.name + '.partial')
                temporary.write_text(json.dumps(value, indent=2) + '\n')
                temporary.chmod(0o600)
                temporary.replace(args.started)
        result = monitor(record, args.seconds, on_started=started)
        args.result.write_text(json.dumps(result, indent=2) + '\n')
        args.result.chmod(0o600)
        if result['status'] != 'deadline_stop_requested':
            raise SystemExit(1)
