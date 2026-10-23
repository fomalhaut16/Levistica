#!/usr/bin/env python3
"""Launch/stop only Chrome instances created here with a fresh project-local profile."""
import argparse
import importlib.util
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse

spec = importlib.util.spec_from_file_location('measure_memory', pathlib.Path(__file__).with_name('measure-memory.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
app = pathlib.Path('/Applications/Google Chrome.app')
binary = app / 'Contents/MacOS/Google Chrome'
base = m.ROOT / '.local/artifacts/comparison'


def workload_urls(url, tabs, ready_file=None):
    if tabs not in (1, 5, 20):
        raise ValueError('Only one, five, or twenty fixture tabs are supported')
    if tabs == 1:
        if not url or not re.fullmatch(r'http://127\.0\.0\.1:\d+/(document|video)', url):
            raise ValueError('Only the loopback memory fixture URL is allowed')
        return [url]
    if ready_file is None or not ready_file.resolve().is_relative_to(m.ROOT / '.local'):
        raise ValueError('Multiple tabs require a fixture ready-file inside this checkout .local')
    state = json.loads(ready_file.read_text())
    if tabs == 5 and re.fullmatch(r'http://127\.0\.0\.1:\d+/document', url or ''):
        if state.get('kind') != 'documents' or state.get('url') != url or state.get('loads') != 0:
            raise ValueError('Five same-origin tabs require a fresh document-set fixture')
        return [url + '/' + str(i) for i in range(1, 6)]
    keys = {str(i) for i in range(1, tabs + 1)}
    if (state.get('kind') != 'cross-site-documents' or state.get('transport') != 'same-origin-sse-v1'
            or state.get('expected_tabs') != tabs or state.get('loads') != 0 or state.get('documents')
            or state.get('invalid_reason') or not state.get('run_id')
            or set(state.get('urls', {})) != keys or set(state.get('origins', {})) != keys
            or set(state.get('document_hashes', {})) != keys
            or state.get('stream_connections') != dict.fromkeys(keys, 0)):
        raise ValueError('Cross-site tabs require a fresh matching fixture')
    ports = set()
    for key in keys:
        parts = urllib.parse.urlsplit(state['urls'][key])
        if (parts.scheme != 'http' or parts.hostname != f'document-{key}.localhost'
                or not parts.port or parts.path != '/document/' + key
                or parts.username is not None or parts.password is not None or parts.query or parts.fragment
                or state['origins'][key] != f'http://document-{key}.localhost:{parts.port}'
                or not re.fullmatch(r'[0-9a-f]{64}', state['document_hashes'][key])):
            raise ValueError('Unexpected cross-site fixture URL, origin or hash')
        ports.add(parts.port)
    if len(ports) != 1 or url != state['urls']['1']:
        raise ValueError('Fixture ports must match and the first document must be requested')
    return [state['urls'][str(i)] for i in range(1, tabs + 1)]


def verified_marker(profile):
    profile = profile.resolve()
    if profile.parent != base.resolve() or not profile.name.startswith('chrome-trial.'):
        raise ValueError('Refusing a non-experiment profile')
    marker_path = profile / 'levistica-benchmark.json'
    if marker_path.is_symlink():
        raise ValueError('Experiment marker must not be a symbolic link')
    marker = json.loads(marker_path.read_text())
    if marker.get('profile') != str(profile):
        raise ValueError('Experiment marker belongs to another profile')
    pid = marker.get('pid')
    if type(pid) is not int or pid <= 0:
        raise ValueError('Invalid experiment PID')
    identity = m.identities([pid]).get(pid)
    if identity != marker['identity'] or identity.get('executable') != str(binary):
        raise ValueError('Chrome process identity changed; refusing to operate')
    arguments = m.run(['/bin/ps', '-p', str(pid), '-o', 'args='])
    if (not m.has_path_argument(arguments, '--user-data-dir=', profile)
            or m.identities([pid]).get(pid) != identity):
        raise ValueError('Chrome profile or identity changed; refusing to operate')
    return marker


def launch(url, width, height):
    if not 420 <= height <= 1500 or not 420 <= width <= 3000:
        raise ValueError('Window dimensions outside supported diagnostic range')
    base.mkdir(parents=True, exist_ok=True)
    profile = pathlib.Path(tempfile.mkdtemp(prefix='chrome-trial.', dir=base)).resolve()
    subprocess.run(['/usr/bin/open', '-n', str(app), '--args', '--user-data-dir=' + str(profile),
                    '--no-first-run', '--no-default-browser-check',
                    f'--window-size={width},{height}', url], check=True, timeout=10)
    for _ in range(50):
        try:
            pid = m.find_app(binary, profile)
            break
        except ValueError:
            time.sleep(0.2)
    else:
        raise ValueError('Chrome did not launch with the isolated profile: ' + str(profile))
    marker = {'pid': pid, 'identity': m.identities([pid])[pid], 'profile': str(profile)}
    path = profile / 'levistica-benchmark.json'
    path.write_text(json.dumps(marker, indent=2) + '\n')
    path.chmod(0o600)
    return marker


def pressure_normal():
    if m.run(['/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level']).strip() != '1':
        raise ValueError('Memory pressure differs from the required starting level')


def prepare_tabs(marker, urls, ready_file):
    profile = pathlib.Path(marker['profile'])
    initial = json.loads(ready_file.read_text())
    cross_site = initial.get('kind') == 'cross-site-documents'
    deadline = time.monotonic() + 180
    def verify_original():
        current = verified_marker(profile)
        if current['pid'] != marker['pid'] or current['identity'] != marker['identity']:
            raise ValueError('The original preparation process changed; no more URLs delivered')
    for index, url in enumerate(urls, start=1):
        pressure_normal()
        verify_original()
        if index > 1:
            # Forward only to the explicitly matching user-data-dir; no UI events.
            subprocess.run(['/usr/bin/open', '-n', str(app), '--args', '--user-data-dir=' + str(profile), url],
                           check=True, timeout=10)
            verify_original()
        for _ in range(100):
            if time.monotonic() >= deadline:
                raise ValueError('Document preparation exceeded its bounded time')
            state = json.loads(ready_file.read_text())
            fixed = ('kind', 'run_id', 'urls', 'origins', 'document_hashes', 'expected_tabs') if cross_site else ('kind', 'url', 'document_hashes')
            if any(state.get(key) != initial.get(key) for key in fixed) or state.get('invalid_reason'):
                raise ValueError('The fixture identity changed during preparation')
            if cross_site and (state.get('loads', 0) > index
                               or any(value > 1 for value in state['stream_connections'].values())):
                raise ValueError('A document reloaded or reconnected during preparation')
            report = state.get('documents', {}).get(str(index), {})
            if (report.get('seenVisible') is True and report.get('complete') is True
                    and (not cross_site or report.get('pulse', 0) > 0)):
                break
            time.sleep(0.2)
        else:
            raise ValueError('A synthetic tab was not visibly loaded')
    verify_original()
    state = json.loads(ready_file.read_text())
    m.check_fixture(state)
    pressure_normal()
    marker['prepared_tabs'] = len(urls)
    marker['visit_order'] = list(range(1, len(urls) + 1))
    marker['prepared_monotonic'] = time.monotonic()
    (profile / 'levistica-benchmark.json').write_text(json.dumps(marker, indent=2) + '\n')
    return state


def stop(profile):
    marker = verified_marker(profile)
    pid = marker['pid']
    # Never signal by application name, bundle ID or process group.
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        try:
            identity = m.identities([pid])[pid]
        except (ValueError, subprocess.SubprocessError):
            return
        if identity != marker['identity']:
            return  # Original process exited; never signal a reused PID.
        time.sleep(0.2)
    raise ValueError('Comparison Chrome is still running; no force-kill attempted')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'stop'])
    parser.add_argument('--url')
    parser.add_argument('--profile', type=pathlib.Path)
    parser.add_argument('--width', type=int, default=1100)
    parser.add_argument('--height', type=int, default=770)
    parser.add_argument('--tabs', type=int, choices=[1, 5, 20], default=1)
    parser.add_argument('--ready-file', type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.action == 'stop':
            if args.profile is None:
                parser.error('Stopping requires --profile from the start result')
            stop(args.profile)
            print('Stopped only the isolated comparison instance')
            return
        urls = workload_urls(args.url, args.tabs, args.ready_file)
        marker = launch(urls[0], args.width, args.height)
        try:
            if len(urls) > 1:
                prepare_tabs(marker, urls, args.ready_file)
        except Exception:
            print('Isolated profile marker preserved: ' + marker['profile'], file=sys.stderr)
            raise
        print(json.dumps(marker))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
