#!/usr/bin/env python3
"""Describe an unlaunched, verified Profile bundle for the opt-in launch probe."""
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LAUNCH_METRIC = 'com.apple.dt.XCTMetric_ApplicationLaunch-ApplicationFirstFramePresentationResponsive.duration'


def validate_entitlements(entitlements):
    expected = {'com.apple.security.app-sandbox', 'com.apple.security.network.client',
                'com.apple.security.files.user-selected.read-write', 'com.apple.security.get-task-allow'}
    if set(entitlements) != expected or any(value is not True for value in entitlements.values()):
        raise ValueError('Only the existing Profile entitlement set is accepted')


def validate_metrics(value):
    if (not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict)
            or value[0].get('testIdentifier') != 'BrowserFlowTests/testProfileBlankWindowLaunchMetric()'):
        raise ValueError('Exactly the opt-in launch test is required')
    runs = value[0].get('testRuns')
    if not isinstance(runs, list) or len(runs) != 1 or not isinstance(runs[0], dict):
        raise ValueError('Exactly one test run is required')
    metrics = runs[0].get('metrics')
    if not isinstance(metrics, list):
        raise ValueError('No reported launch metrics')
    matches = [metric for metric in metrics if isinstance(metric, dict) and metric.get('identifier') == LAUNCH_METRIC]
    if len(matches) != 1 or matches[0].get('unitOfMeasurement') != 's':
        raise ValueError('The first-frame-and-responsive metric in seconds is required')
    samples = matches[0].get('measurements')
    if (not isinstance(samples, list) or len(samples) != 1
            or type(samples[0]) not in (int, float) or not math.isfinite(samples[0]) or samples[0] <= 0):
        raise ValueError('Exactly one positive finite measurement is required')
    return {'metricIdentifier': LAUNCH_METRIC, 'firstFrameResponsiveSeconds': samples[0],
            'measuredSamples': 1, 'warmupExcludedByXCTest': True, 'productAccepted': False}


def prepare(output):
    output = Path(output).absolute()
    if (output.name != 'profile-launch-workload.json'
            or output.parent.parent != ROOT / '.local/artifacts'
            or not output.parent.name.startswith('tests.')
            or output.resolve() != output or output.exists()):
        raise ValueError('A new project-owned test manifest is required')
    spec = importlib.util.spec_from_file_location('launch_process_guard', ROOT / 'script/check-app-processes.py')
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    snapshot = guard.run_ps(['-axo', 'pid=,comm='])
    if snapshot is None or guard.check_snapshot(snapshot, ROOT, guard.describe_process, os.getuid(), only='Profile'):
        raise ValueError('No existing Levistica is allowed before a launch probe')
    app = ROOT / '.local/ProfileDerivedData/Build/Products/Release/Levistica.app'
    executable = app / 'Contents/MacOS/Levistica'
    information = app / 'Contents/Info.plist'
    if app.resolve() != app or executable.resolve() != executable or information.resolve() != information:
        raise ValueError('Linked bundles are not accepted')
    info = plistlib.loads(information.read_bytes())
    source = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    if (info.get('CFBundleIdentifier') != 'dev.fomalhaut16.Levistica.profile'
            or info.get('LevisticaSourceRevision') != source
            or info.get('LevisticaSourceState') not in ('clean', 'modified')):
        raise ValueError('Canonical Profile identity is required')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                   check=True, capture_output=True, timeout=10)
    signed = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)],
                            check=True, capture_output=True, timeout=10)
    entitlements = plistlib.loads(signed.stdout)
    validate_entitlements(entitlements)
    value = {'kind': 'ProfileBlankLaunchProbeV1', 'appPath': str(app), 'executable': str(executable),
             'source': source, 'sourceState': info['LevisticaSourceState'],
             'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
             'maximumLaunches': 2, 'normalDataUsed': False}
    with output.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
    output.chmod(0o600)
    print('Prepared isolated Profile launch manifest; no app launched.')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--validate-metrics':
        path = Path(sys.argv[2]).absolute()
        if (path.name != 'launch-metrics.json' or path.parent.parent != ROOT / '.local/artifacts'
                or not path.parent.name.startswith('tests.') or path.resolve() != path):
            raise SystemExit('A project-owned launch metrics file is required')
        print(json.dumps(validate_metrics(json.loads(path.read_text())), indent=2))
    elif len(sys.argv) == 2:
        prepare(sys.argv[1])
    else:
        raise SystemExit('Usage: profile-launch-workload.py OUTPUT | --validate-metrics METRICS')
