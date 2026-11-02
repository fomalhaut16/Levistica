#!/usr/bin/env python3
"""Describe an unlaunched, verified isolated Release bundle for the opt-in launch probe."""
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent
VARIANTS = {
    'Profile': ('dev.fomalhaut16.Levistica.profile', 'testProfileBlankWindowLaunchMetric'),
    'Measurement': ('dev.fomalhaut16.Levistica.measurement', 'testMeasurementBlankWindowLaunchMetric'),
}


def variant_facts(variant):
    if variant not in VARIANTS:
        raise ValueError('Only Profile and Measurement launch probes are supported')
    return VARIANTS[variant]


LAUNCH_METRIC = 'com.apple.dt.XCTMetric_ApplicationLaunch-ApplicationFirstFramePresentationResponsive.duration'


def validate_entitlements(entitlements, variant='Profile'):
    variant_facts(variant)
    expected = {'com.apple.security.app-sandbox', 'com.apple.security.network.client',
                'com.apple.security.files.user-selected.read-write'}
    if variant == 'Profile':
        expected.add('com.apple.security.get-task-allow')
    if set(entitlements) != expected or any(value is not True for value in entitlements.values()):
        raise ValueError('Only the existing entitlement set for the selected Release variant is accepted')


def validate_metrics(value, variant='Profile'):
    _, test = variant_facts(variant)
    if (not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict)
            or value[0].get('testIdentifier') != 'BrowserFlowTests/' + test + '()'):
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
    return {'variant': variant, 'metricIdentifier': LAUNCH_METRIC, 'firstFrameResponsiveSeconds': samples[0],
            'measuredSamples': 1, 'warmupExcludedByXCTest': True, 'productAccepted': False}


def prepare(output, variant='Profile'):
    bundle_identifier, _ = variant_facts(variant)
    output = Path(output).absolute()
    if (output.name != 'release-launch-workload.json'
            or output.parent.parent != ROOT / '.local/artifacts'
            or not output.parent.name.startswith('tests.')
            or output.resolve() != output or output.exists()):
        raise ValueError('A new project-owned test manifest is required')
    spec = importlib.util.spec_from_file_location('launch_process_guard', ROOT / 'script/check-app-processes.py')
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    snapshot = guard.run_ps(['-axo', 'pid=,comm='])
    if snapshot is None or guard.check_snapshot(snapshot, ROOT, guard.describe_process, os.getuid(), only=variant):
        raise ValueError('No existing Levistica is allowed before a launch probe')
    app = ROOT / f'.local/{variant}DerivedData/Build/Products/Release/Levistica.app'
    executable = app / 'Contents/MacOS/Levistica'
    information = app / 'Contents/Info.plist'
    if app.resolve() != app or executable.resolve() != executable or information.resolve() != information:
        raise ValueError('Linked bundles are not accepted')
    info = plistlib.loads(information.read_bytes())
    source = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    if (info.get('CFBundleIdentifier') != bundle_identifier
            or info.get('LevisticaSourceRevision') != source
            or info.get('LevisticaSourceState') not in ('clean', 'modified')):
        raise ValueError('Canonical isolated Release identity is required')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                   check=True, capture_output=True, timeout=10)
    signed = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)],
                            check=True, capture_output=True, timeout=10)
    entitlements = plistlib.loads(signed.stdout)
    validate_entitlements(entitlements, variant)
    value = {'kind': 'IsolatedReleaseBlankLaunchV1', 'variant': variant, 'appPath': str(app), 'executable': str(executable),
             'source': source, 'sourceState': info['LevisticaSourceState'],
             'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
             'maximumLaunches': 2, 'normalDataUsed': False}
    with output.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
    output.chmod(0o600)
    print('Prepared isolated Release launch manifest; no app launched.')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'validate-metrics'])
    parser.add_argument('--variant', choices=VARIANTS, required=True)
    parser.add_argument('path', type=Path)
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.path, args.variant)
    else:
        path = args.path.absolute()
        if (path.name != 'launch-metrics.json' or path.parent.parent != ROOT / '.local/artifacts'
                or not path.parent.name.startswith('tests.') or path.resolve() != path):
            raise SystemExit('A project-owned launch metrics file is required')
        print(json.dumps(validate_metrics(json.loads(path.read_text()), args.variant), indent=2))
