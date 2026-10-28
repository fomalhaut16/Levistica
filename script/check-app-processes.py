#!/usr/bin/env python3
"""Read-only preflight for this checkout's app executables, independent of process name."""
import os
import argparse
import pathlib
import plistlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def known_apps(root):
    return {
        str(root / '.local/DerivedData/Build/Products/Debug/Levistica.app/Contents/MacOS/Levistica'): 'dev.fomalhaut16.Levistica.debug',
        str(root / '.local/DerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica'): 'dev.fomalhaut16.Levistica',
        str(root / '.local/ProfileDerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica'): 'dev.fomalhaut16.Levistica.profile',
        str(root / '.local/MeasurementDerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica'): 'dev.fomalhaut16.Levistica.measurement',
        str(pathlib.Path.home() / 'Applications/Levistica.app/Contents/MacOS/Levistica'): 'dev.fomalhaut16.Levistica',
    }


def check_snapshot(snapshot, root, describe, uid, only=None):
    expected = known_apps(root)
    found = []
    for row in snapshot.splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) != 2 or fields[1] not in expected:
            continue
        pid = int(fields[0])
        identifier = expected[fields[1]]
        variant = ('Debug' if identifier.endswith('.debug') else
                   'Profile' if identifier.endswith('.profile') else
                   'Measurement' if identifier.endswith('.measurement') else 'Release')
        if only is not None and variant != only:
            raise ValueError(f'Unexpected {variant} app PID {pid} while only {only} is allowed; do not stop it automatically.')
        info = describe(pid, fields[1])
        if info is None:  # The process exited between the snapshot and inspection.
            continue
        if (info['path'] != fields[1] or info['name'] != 'Levistica'
                or info['uid'] != uid or info['identifier'] != expected[fields[1]]):
            raise ValueError(f'App identity mismatch for PID {pid}; do not stop or relaunch it until ownership is confirmed.')
        found.append(pid)
    return found


def run_ps(arguments):
    result = subprocess.run(['/bin/ps', *arguments], capture_output=True, text=True, timeout=10)
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return None
    result.check_returncode()
    return result.stdout


def describe_process(pid, expected_path):
    path = run_ps(['-p', str(pid), '-o', 'comm='])
    identity = run_ps(['-p', str(pid), '-o', 'uid=,ucomm='])
    if path is None or identity is None:
        return None
    fields = identity.strip().split(None, 1)
    if len(fields) != 2:
        raise ValueError(f'Cannot inspect app identity for PID {pid}')
    bundle = pathlib.Path(expected_path).parent.parent
    with (bundle / 'Info.plist').open('rb') as source:
        identifier = plistlib.load(source).get('CFBundleIdentifier')
    return {'path': path.strip(), 'uid': int(fields[0]), 'name': fields[1].strip(), 'identifier': identifier}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only', choices=['Debug', 'Release', 'Profile', 'Measurement'])
    args = parser.parse_args()
    snapshot = run_ps(['-axo', 'pid=,comm='])
    if snapshot is None:
        raise ValueError('Process enumeration failed')
    found = check_snapshot(snapshot, ROOT, describe_process, os.getuid(), only=args.only)
    print(f'App identity preflight: {len(found)} matching process(es).')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        print(f'App identity preflight failed: {error}', file=sys.stderr)
        sys.exit(1)
