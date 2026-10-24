#!/usr/bin/env python3
"""Bounded, numeric-only observation of an already-running project Release app.

Never launches, controls or stops an application. No page or profile data is read.
This observes an unclassified workload; it does not establish comparison conditions.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('measure_memory', ROOT / 'script/measure-memory.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class RootChanged(Exception):
    pass


def decode_rusage(text, pids):
    """Fail closed before any unrecognised helper output reaches disk."""
    if (not 1 <= len(pids) <= 512 or any(type(pid) is not int or not 0 < pid <= 2**31-1 for pid in pids)
            or len(set(pids)) != len(pids)):
        raise ValueError('Invalid requested PID set')
    document = json.loads(text)
    if (not isinstance(document, dict) or set(document) != {'unit', 'bytes per unit', 'processes', 'errors'}
            or document['unit'] != 'byte' or type(document['bytes per unit']) is not int
            or document['bytes per unit'] != 1
            or not isinstance(document['processes'], list) or not isinstance(document['errors'], list)):
        raise ValueError('Unrecognised resource schema')
    expected = set(pids)
    seen = set()
    processes, errors = [], []
    for item in document['processes']:
        if (not isinstance(item, dict) or set(item) != {'pid', 'auxiliary'}
                or not isinstance(item['auxiliary'], dict) or set(item['auxiliary']) != {'phys_footprint'}):
            raise ValueError('Unrecognised resource row')
        pid, value = item['pid'], item['auxiliary']['phys_footprint']
        if type(pid) is not int or pid not in expected or pid in seen or type(value) is not int or not 0 <= value < 2**64:
            raise ValueError('Invalid resource value')
        seen.add(pid)
        processes.append({'pid': pid, 'auxiliary': {'phys_footprint': value}})
    for item in document['errors']:
        if not isinstance(item, dict) or set(item) != {'pid', 'errno'}:
            raise ValueError('Unrecognised resource error')
        pid, code = item['pid'], item['errno']
        if type(pid) is not int or pid not in expected or pid in seen or type(code) is not int or not 0 < code <= 2**31-1:
            raise ValueError('Invalid resource error')
        seen.add(pid)
        errors.append({'pid': pid, 'errno': code})
    if seen != expected:
        raise ValueError('Incomplete resource response')
    return {'unit': 'byte', 'bytes per unit': 1, 'processes': processes, 'errors': errors}


def prepare_helper():
    source = ROOT / 'script/proc-rusage.c'
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    directory = ROOT / '.local/tools'
    if (ROOT / '.local').is_symlink() or directory.is_symlink():
        raise ValueError('Helper directory must be local')
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / ('proc-rusage-' + digest[:20])
    if binary.is_symlink():
        raise ValueError('Helper must not be a symbolic link')
    if not binary.exists():
        with tempfile.TemporaryDirectory(prefix='proc-rusage-build.', dir=directory) as temporary:
            candidate = pathlib.Path(temporary) / 'proc-rusage'
            m.run(['/usr/bin/xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                   str(source), '-o', str(candidate)])
            candidate.chmod(0o700)
            os.replace(candidate, binary)
    return binary, digest


def root_identity(pid):
    identity = m.identities([pid])[pid]
    if (pathlib.Path(identity['executable']).resolve() != m.BINARY.resolve()
            or int(m.run(['/bin/ps', '-p', str(pid), '-o', 'uid=']).strip()) != os.getuid()):
        raise ValueError('Not this user\'s project Release app')
    return identity


def checked_build(info):
    revision, state = info.get('LevisticaSourceRevision'), info.get('LevisticaSourceState')
    if (info.get('CFBundleIdentifier') != 'dev.fomalhaut16.Levistica'
            or not isinstance(revision, str) or not re.fullmatch('[0-9a-f]{40}', revision) or state != 'clean'):
        raise ValueError('Application build source is unavailable')
    # Observation records the running binary independently of the collector checkout.
    return {'revision': revision, 'state': state}


def collect(pid, identity, helper, clock=time.monotonic, deadline=None):
    deadline = min(clock() + 25, deadline) if deadline is not None else clock() + 25
    phase = 'root'
    def query(command):
        remaining = deadline - clock()
        if remaining <= 0:
            raise TimeoutError('Sample deadline exceeded')
        return m.run(command, timeout=min(10, remaining))
    def same_root():
        try:
            current = m.identities([pid], query=query).get(pid)
        except (ValueError, subprocess.CalledProcessError):
            raise RootChanged() from None
        if current != identity:
            raise RootChanged()
    try:
        same_root()
        phase = 'attribution_before'
        before = m.snapshot(pid, deadline=deadline)
        if before['identities'].get(pid) != identity:
            raise RootChanged()
        pids = sorted(before['identities'])
        phase = 'resource_values'
        document = decode_rusage(query([str(helper), *map(str, pids)]), pids)
        phase = 'attribution_after'
        after = m.snapshot(pid, deadline=deadline)
        same_root()
        stable, _ = m.attribution_change(before, after)
        if not stable:
            return {'valid': False, 'reason': 'attribution_changed'}
        if document['errors']:
            return {'valid': False, 'reason': 'resource_unavailable', 'errors': document['errors']}
        values, missing = m.metrics(document, pids)
        if missing:
            return {'valid': False, 'reason': 'resource_missing'}
        return {'valid': True, 'processes': [{'pid': p, 'role': m.role(p, pid, before['services']),
                    'physicalFootprintBytes': values[p]} for p in pids],
                'sumAttributedBytes': sum(values.values())}
    except RootChanged:
        raise
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Domain text, paths, stderr and exception messages never enter the record.
        if clock() < deadline:
            same_root()
        return {'valid': False, 'reason': 'sample_failed', 'phase': phase, 'errorType': type(error).__name__}


def schedule(samples, interval, take, save, stopped, clock=time.monotonic, sleep=time.sleep):
    started = clock()
    rows = []
    reason = 'completed'
    for index in range(samples):
        due = started + index * interval
        while not stopped() and clock() < due:
            sleep(min(1, due - clock()))
        if stopped():
            reason = 'interrupted'
            break
        if clock() - due >= 25:
            value = {'valid': False, 'reason': 'missed_schedule'}
        else:
            try:
                value = take(due + 25)
                if clock() > due + 25:
                    value = {'valid': False, 'reason': 'sample_deadline_exceeded'}
            except RootChanged:
                reason = 'root_exited_or_changed'
                break
        rows.append({'index': index + 1, 'elapsedSeconds': clock() - started, **value})
        save(rows, 'running')
    if stopped():
        reason = 'interrupted'
    save(rows, reason)
    return rows, reason


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--samples', type=int, default=5)
    parser.add_argument('--interval', type=float, default=60)
    parser.add_argument('--label', default='session-observation')
    args = parser.parse_args()
    if (not 0 < args.pid <= 2**31-1 or not 1 <= args.samples <= 120 or not 5 <= args.interval <= 600
            or (args.samples - 1) * args.interval + 25 > 7200
            or not re.fullmatch('[a-z0-9][a-z0-9-]{0,63}', args.label)):
        parser.error('Invalid PID, bounded schedule, or non-private label')
    import plistlib
    helper, digest = prepare_helper()
    identity = root_identity(args.pid)
    m.run(['/usr/bin/codesign', '--verify', '--strict', str(m.APP)])
    info_path = m.APP / 'Contents/Info.plist'
    original_info = info_path.read_bytes()
    build = checked_build(plistlib.loads(original_info))
    parent = ROOT / '.local/artifacts/observations'
    if parent.is_symlink() or not parent.resolve().is_relative_to((ROOT / '.local').resolve()):
        raise ValueError('Observation output must be local')
    parent.mkdir(parents=True, exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix=args.label + '.', dir=parent))
    output.chmod(0o700)
    record = {'schema': 1, 'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'pid': args.pid, 'rootStarted': identity['started'], 'applicationBuild': build,
              'collectorRevision': m.run(['git', 'rev-parse', 'HEAD']).strip(),
              'collectorDirty': bool(m.run(['git', 'status', '--porcelain', '--untracked-files=normal']).strip()),
              'metric': 'proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint', 'helperSourceSHA256': digest,
              'helperBinarySHA256': hashlib.sha256(helper.read_bytes()).hexdigest(),
              'plannedSamples': args.samples, 'intervalSeconds': args.interval,
              'workload': 'unclassified; tab and loaded-page counts are unknown',
              'limits': ['Not a controlled comparison or a performance acceptance result.',
                         'Build revision comes from signed bundle metadata, not an independently inspected process image.',
                         'Attributed process sums may double-count shared memory; not exclusive RAM.',
                         'Services outside the verified PID domain are excluded.'], 'samples': []}
    stopping = [False]
    previous = {}
    def stop(_signal, _frame):
        stopping[0] = True
    for signum in (signal.SIGINT, signal.SIGTERM):
        previous[signum] = signal.signal(signum, stop)
    def save(rows, reason):
        record.update(samples=rows, endReason=reason,
                      validSamples=sum(row['valid'] for row in rows))
        path = output / 'result.json'
        temporary = output / 'result.partial.json'
        temporary.write_text(json.dumps(record, indent=2) + '\n')
        temporary.chmod(0o600)
        os.replace(temporary, path)
    def take(deadline):
        try:
            current_info = info_path.read_bytes()
        except OSError:
            raise RootChanged() from None
        if current_info != original_info:
            raise RootChanged()
        return collect(args.pid, identity, helper, deadline=deadline)
    try:
        rows, reason = schedule(args.samples, args.interval, take, save, lambda: stopping[0])
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    print('Local aggregate observation: ' + str(output / 'result.json'))
    print(f"Valid observations: {sum(row['valid'] for row in rows)}/{args.samples}; {reason}")
    return 0 if reason == 'completed' and len(rows) == args.samples and all(row['valid'] for row in rows) else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('Observation failed (' + type(error).__name__ + '); no application was controlled.')
        raise SystemExit(1) from None
