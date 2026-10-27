#!/usr/bin/env python3
"""Read one owned incognito Chrome pilot through a private parent pipe. Never controls Chrome."""
import argparse
import ast
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import select
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
APP = Path('/Applications/Google Chrome.app')
BINARY = APP / 'Contents/MacOS/Google Chrome'
spec = importlib.util.spec_from_file_location('chrome_public_sampler', ROOT / 'script/public-memory-sample.py')
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)
m, observer = memory.m, memory.observer


def chrome_role(pid, root, snapshot):
    if pid == root:
        return 'UI'
    path = Path(snapshot['identities'][pid]['executable'])
    names = {'Google Chrome Helper (Renderer)': 'Renderer', 'Google Chrome Helper (GPU)': 'GPU',
             'Google Chrome Helper': 'Utility', 'chrome_crashpad_handler': 'Crashpad'}
    return names.get(path.name, 'Chrome helper') if path.resolve().is_relative_to(APP.resolve()) else 'Owned XPC helper'


def display_identity_counts(snapshot):
    """Discard mutable display strings; retain only counts for owned verified PIDs."""
    identities = snapshot['identities']
    text = m.run(['/bin/ps', '-p', ','.join(map(str, sorted(identities))), '-o', 'pid=,comm='], timeout=2)
    seen = set()
    mismatches = nonabsolute = 0
    for line in text.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            raise ValueError('Unrecognized ps identity row')
        pid = int(fields[0])
        if pid not in identities or pid in seen:
            raise ValueError('Unrecognized ps identity row')
        seen.add(pid)
        mismatches += fields[1] != identities[pid]['executable']
        nonabsolute += not Path(fields[1]).is_absolute()
    if seen != set(identities):
        raise ValueError('Display diagnostic identity set changed')
    return {'processCount': len(seen), 'displayDiffersFromKernelPath': mismatches,
            'displayIsNotAbsolutePath': nonabsolute}


def validate_observation(value, original=None):
    fields = {'target', 'frame', 'loader', 'elapsed', 'time', 'width', 'height', 'dpr',
              'videoWidth', 'videoHeight', 'muted', 'paused', 'rate', 'readyState', 'visible', 'loadedPages'}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError('Unexpected Chrome observation fields')
    for key in ('target', 'frame', 'loader'):
        if not isinstance(value[key], str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}', value[key]):
            raise ValueError('Invalid opaque CDP identity')
    for key in fields - {'target', 'frame', 'loader', 'muted', 'paused', 'visible'}:
        if type(value[key]) not in (int, float) or not 0 <= value[key] <= 1e12:
            raise ValueError('Invalid Chrome observation number')
    if ((value['width'], value['height'], value['dpr']) != (779, 683, 2)
            or (value['videoWidth'], value['videoHeight']) != (1280, 720)
            or value['muted'] is not True or value['paused'] is not False or value['visible'] is not True
            or value['rate'] != 1 or value['loadedPages'] != 4
            or type(value['readyState']) is not int or not 2 <= value['readyState'] <= 4):
        raise ValueError('Chrome playback conditions changed')
    if original is not None:
        if any(value[key] != original[key] for key in ('target', 'frame', 'loader')):
            raise ValueError('Chrome document identity changed')
        elapsed = (value['elapsed'] - original['elapsed']) / 1000
        if not 3 <= elapsed <= 20 or abs(value['time'] - original['time'] - elapsed) > 2:
            raise ValueError('Chrome playback interval did not match')


def validate_packet(packet, stage, run_id):
    fields = {'phase', 'runID', 'allFourTargetsAndLoadersRetained'} if stage == 'commit' else {'phase', 'runID', 'snapshot'}
    if (not isinstance(packet, dict) or set(packet) != fields
            or packet.get('phase') != stage or packet.get('runID') != run_id
            or (stage == 'commit' and packet.get('allFourTargetsAndLoadersRetained') is not True)):
        raise ValueError('Unexpected parent phase, fields or trial')


def failure_detail(error, root):
    text = str(error) if isinstance(error, ValueError) else ''
    fixed = {'Chrome owner changed': 'owner_changed',
             'Chrome belongs to another user': 'owner_user_changed',
             'Chrome profile or incognito mode changed': 'profile_changed',
             'Chrome listener ownership changed': 'listener_changed',
             'Controller source or Chrome version changed': 'source_or_version_changed',
             'Domain originator is not this checkout\'s app': 'domain_origin_changed',
             'Domain creator does not match the app PID': 'domain_creator_changed',
             'Service PID changed during attribution': 'service_changed_during_read',
             "Service is outside the app's PID domain": 'service_domain_changed',
             'Unrecognized ps identity row': 'process_identity_format',
             'Unrecognized process table': 'process_table_format',
             'Unexpected PID domain': 'domain_format',
             'Unrecognized service row; attribution unavailable': 'service_format',
             'Missing services section; attribution unavailable': 'services_missing',
             'Requires known AC power and normal memory pressure': 'power_or_pressure',
             'Root identity changed': 'root_identity_changed',
             'Attribution has not been stable for sixty seconds': 'attribution_not_settled',
             'Parent pipe closed or invalid packet': 'parent_pipe_closed'}
    if text in fixed:
        return {'reason': fixed[text]}
    prefix = 'Process identity set changed; missing PIDs: '
    if text.startswith(prefix) and re.fullmatch(r'[0-9]+(?:,[0-9]+)*', text[len(prefix):]):
        missing = []
        for value in text[len(prefix):].split(',')[:64]:
            pid = int(value)
            try:
                os.kill(pid, 0)
                exists = True
            except ProcessLookupError:
                exists = False
            except PermissionError:
                exists = None
            missing.append({'pid': pid, 'isRoot': pid == root, 'existsNow': exists})
        return {'reason': 'process_identity_set_changed', 'missingProcesses': missing}
    prefix = 'Unexpected Chrome descendant executable: '
    if text.startswith(prefix):
        try:
            paths = ast.literal_eval(text[len(prefix):])
            safe = [path if isinstance(path, str) and path.startswith(('/System/Library/', '/usr/'))
                    else '<non-system path>' for path in paths[:8]]
            return {'reason': 'unexpected_descendant', 'systemPaths': safe}
        except (ValueError, SyntaxError, TypeError):
            pass
    return {'reason': type(error).__name__}


def owner_directory(path):
    if (ROOT / '.local').is_symlink() or (ROOT / '.local/artifacts').is_symlink() or path.is_symlink():
        raise ValueError('Owner paths must be project-local regular files')
    path = path.resolve()
    if (path.name != 'memory-owner.json' or path.parent.parent != (ROOT / '.local/artifacts').resolve()
            or not path.parent.name.startswith('public-four-page-memory-chrome.')):
        raise ValueError('Owner file is outside a newly allocated trial')
    return path.parent


def owner_paths(path, owner):
    directory = owner_directory(path)
    if (Path(owner.get('profile', '')).is_symlink()
            or Path(owner.get('profile', '')).resolve() != directory / 'profile'
            or owner.get('executable') != str(BINARY)
            or type(owner.get('pid')) is not int or owner['pid'] <= 0
            or not isinstance(owner.get('started'), str) or not owner['started']
            or type(owner.get('port')) is not int or not 1 <= owner['port'] <= 65535
            or not isinstance(owner.get('runID'), str) or not re.fullmatch(r'[0-9a-f-]{36}', owner['runID'])):
        raise ValueError('Expected a newly owned Chrome pilot')
    return directory, Path(owner['profile']).resolve()


def run(path):
    owner_directory(path)
    owner = json.loads(path.read_text())
    directory, profile = owner_paths(path, owner)
    pid = owner['pid']
    info_path = APP / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    if owner.get('browserProduct') != 'Chrome/' + info['CFBundleShortVersionString']:
        raise ValueError('Chrome version is not bound to the controller')
    expected = {'started': owner['started'], 'executable': str(BINARY.resolve())}
    def verify():
        if m.identities([pid])[pid] != expected:
            raise ValueError('Chrome owner changed')
        if int(m.run(['/bin/ps', '-p', str(pid), '-o', 'uid=']).strip()) != os.getuid():
            raise ValueError('Chrome belongs to another user')
        args = m.run(['/bin/ps', '-ww', '-p', str(pid), '-o', 'args='])
        if not m.has_path_argument(args, '--user-data-dir=', profile) or not re.search(r'(?:^|\s)--incognito(?:\s|$)', args):
            raise ValueError('Chrome profile or incognito mode changed')
        listeners = m.run(['/usr/sbin/lsof', '-nP', '-iTCP:' + str(owner['port']), '-sTCP:LISTEN', '-Fp'])
        if {int(line[1:]) for line in listeners.splitlines() if re.fullmatch(r'p[0-9]+', line)} != {pid}:
            raise ValueError('Chrome listener ownership changed')
        if (m.run(['git', 'rev-parse', 'HEAD']).strip() != owner['sourceRevision']
                or m.run(['git', 'status', '--porcelain', '--untracked-files=normal']).strip()
                or plistlib.loads(info_path.read_bytes())['CFBundleShortVersionString'] != info['CFBundleShortVersionString']):
            raise ValueError('Controller source or Chrome version changed')
    verify()
    helper, helper_hash = observer.prepare_helper()
    def read_values(pids, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Capture deadline expired')
        return observer.decode_rusage(m.run([str(helper), *map(str, pids)], timeout=min(1, remaining)), pids)
    sampler = memory.Sampler(pid, lambda deadline: m.snapshot(pid, APP, BINARY, profile, deadline),
                             observer.system_context, read_values, role_for=chrome_role, content_role='Renderer')
    result = {'valid': False, 'validForComparison': False, 'failure': None, 'sourceRevision': owner['sourceRevision'],
              'browserProduct': owner['browserProduct'], 'observations': [], 'memorySamplesTaken': 0,
              'method': 'proc_pid_rusage RUSAGE_INFO_V4 physical footprint', 'helperSourceSHA256': helper_hash,
              'osVersion': m.run(['/usr/bin/sw_vers', '-productVersion']).strip(),
              'osBuild': m.run(['/usr/bin/sw_vers', '-buildVersion']).strip(),
              'architecture': m.run(['/usr/bin/uname', '-m']).strip(),
              'storage': 'new incognito profile; browser-owned cache files may exist',
              'scope': 'UI, verified PID-domain services, descendants and profile-matched Crashpad',
              'limits': ['Single pilot, not a browser comparison.', 'Shared memory can be charged multiple times.',
                         'Outside-domain shared services are excluded.', 'Controller observation overhead differs from native XCTest.']}
    deadline = time.monotonic() + 240
    def interrupted(*_):
        raise InterruptedError('Owned worker interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGALRM, interrupted)
    signal.alarm(240)
    before = None
    before_received = None
    stage = 'capture'
    try:
        print('{"ready":true}', flush=True)
        while time.monotonic() < deadline:
            verify()
            sampler.tick()
            if 'identityDisplayDiagnostic' not in result:
                result['identityDisplayDiagnostic'] = display_identity_counts(sampler.baseline)
                sampler.tick(force=True)
            if not select.select([sys.stdin], [], [], .5)[0]:
                continue
            line = sys.stdin.readline(4097)
            if not line or len(line) > 4096 or not line.endswith('\n'):
                raise ValueError('Parent pipe closed or invalid packet')
            packet = json.loads(line)
            validate_packet(packet, stage, owner['runID'])
            received = time.monotonic()
            if stage == 'capture':
                before = packet['snapshot']
                validate_observation(before)
                before_received = received
                sampler.capture()
                result['observations'].append(before)
                stage = 'after'
            elif stage == 'after':
                after = packet['snapshot']
                validate_observation(after, before)
                interval = received - before_received
                if not 3 <= interval <= 20 or abs(interval - (after['elapsed'] - before['elapsed']) / 1000) > 2:
                    raise ValueError('Receiver interval did not match')
                sampler.finish()
                result['observations'].append(after)
                stage = 'commit'
            else:
                if packet.get('allFourTargetsAndLoadersRetained') is not True:
                    raise ValueError('Parent did not confirm retained documents')
                sampler.finish()
                verify()
                result['valid'] = True
                print('{"ok":true}', flush=True)
                break
            verify()
            print('{"ok":true}', flush=True)
        if not result['valid']:
            raise TimeoutError('Worker lifetime expired')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        result['failure'] = 'capture_or_protocol_failed'
        result['failureStage'] = stage
        result['errorClass'] = type(error).__name__
        result['failureDetail'] = failure_detail(error, pid)
        print('{"ok":false}', flush=True)
    finally:
        signal.alarm(0)
        result['memorySamplesTaken'] = sampler.attempts
        result['sample'] = sampler.sample
        if result['valid']:
            result['sample'] = {**sampler.sample, 'valid': True}
        result['preparation'] = {'checks': sampler.checks, 'changes': sampler.changes,
                                 'lastSystemContext': sampler.last_context}
        output = directory / 'chrome-memory-result.json'
        output.write_text(json.dumps(result, indent=2) + '\n')
        output.chmod(0o600)
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('owner', type=Path)
    args = parser.parse_args()
    try:
        raise SystemExit(run(args.owner))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({'ready': False, 'startupFailure': type(error).__name__}), flush=True)
        raise SystemExit(1)
