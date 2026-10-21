#!/usr/bin/env python3
"""Launch/stop only Chrome instances created here with a fresh project-local profile."""
import argparse
import importlib.util
import json
import pathlib
import signal
import subprocess
import tempfile
import time

spec = importlib.util.spec_from_file_location('measure_memory', pathlib.Path(__file__).with_name('measure-memory.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
app = pathlib.Path('/Applications/Google Chrome.app')
binary = app / 'Contents/MacOS/Google Chrome'
base = m.ROOT / '.local/artifacts/comparison'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['start', 'stop'])
parser.add_argument('--url')
parser.add_argument('--profile', type=pathlib.Path)
parser.add_argument('--width', type=int, default=1100)
parser.add_argument('--height', type=int, default=770)
parser.add_argument('--tabs', type=int, choices=[1, 5], default=1)
parser.add_argument('--ready-file', type=pathlib.Path)
args = parser.parse_args()
if args.action == 'start':
    import re
    if not args.url or not re.fullmatch(r'http://127\.0\.0\.1:\d+/(document|video)', args.url):
        parser.error('Only the loopback memory fixture URL is allowed')
    if not 420 <= args.height <= 1500 or not 420 <= args.width <= 3000:
        parser.error('Window dimensions outside supported diagnostic range')
    if args.tabs == 5 and not args.url.endswith('/document'):
        parser.error('Five tabs require the document-set fixture')
    if args.tabs == 5 and (not args.ready_file or not args.ready_file.resolve().is_relative_to(m.ROOT / '.local')):
        parser.error('Five tabs require a fixture ready-file inside this checkout .local')
    urls = [args.url + '/' + str(i) for i in range(1, 6)] if args.tabs == 5 else [args.url]
    base.mkdir(parents=True, exist_ok=True)
    profile = pathlib.Path(tempfile.mkdtemp(prefix='chrome-trial.', dir=base))
    subprocess.run(['open', '-n', str(app), '--args', '--user-data-dir=' + str(profile),
                    '--no-first-run', '--no-default-browser-check',
                    f'--window-size={args.width},{args.height}', urls[0]], check=True)
    for attempt in range(50):
        try:
            pid = m.find_app(binary, profile)
            break
        except ValueError:
            time.sleep(0.2)
    else:
        raise SystemExit('Chrome did not launch with the isolated profile')
    marker = {'pid': pid, 'identity': m.identities([pid])[pid], 'profile': str(profile)}
    (profile / 'levistica-benchmark.json').write_text(json.dumps(marker, indent=2) + '\n')
    if args.tabs == 5:
        for index, url in enumerate(urls, start=1):
            if index > 1:
                if m.find_app(binary, profile) != pid or m.identities([pid])[pid] != marker['identity']:
                    raise SystemExit('Isolated Chrome identity changed; refusing to send another URL')
                # Chromium forwards this command line only to the matching user-data-dir.
                # This avoids selecting or sending UI events to the user's normal Chrome.
                subprocess.run(['open', '-n', str(app), '--args', '--user-data-dir=' + str(profile), url], check=True)
            for attempt in range(100):
                state = json.loads(args.ready_file.read_text())
                if state.get('url') != args.url or state.get('kind') != 'documents':
                    raise SystemExit('The fixture ready-file does not match the requested workload')
                report = state.get('documents', {}).get(str(index), {})
                if report.get('seenVisible') is True and report.get('complete') is True:
                    break
                time.sleep(0.2)
            else:
                raise SystemExit('A synthetic tab was not visibly loaded; isolated profile marker preserved')
    print(json.dumps(marker))
else:
    if not args.profile:
        parser.error('Stopping requires --profile from the start result')
    profile = args.profile.resolve()
    if profile.parent != base or not profile.name.startswith('chrome-trial.'):
        parser.error('Refusing to stop a non-experiment profile')
    marker = json.loads((profile / 'levistica-benchmark.json').read_text())
    pid = m.find_app(binary, profile)
    if pid != marker['pid'] or m.identities([pid])[pid] != marker['identity']:
        raise SystemExit('Chrome process identity changed; refusing to stop')
    # Never use application name, bundle ID, process group, or the user's Chrome profile.
    import os
    os.kill(pid, signal.SIGTERM)
    for attempt in range(50):
        try:
            m.identities([pid])
        except (ValueError, subprocess.SubprocessError):
            print('Stopped only the isolated comparison instance')
            break
        time.sleep(0.2)
    else:
        raise SystemExit('Comparison Chrome is still running; no force-kill attempted')
