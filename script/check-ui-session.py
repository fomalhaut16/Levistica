#!/usr/bin/env python3
"""Read console lock state only; never change settings or claim automation permission."""
import argparse
import json
import plistlib
import subprocess
from xml.parsers.expat import ExpatError


def parse_state(blob):
    try:
        registry = plistlib.loads(blob)
    except (ValueError, plistlib.InvalidFileException, ExpatError):
        return {'screenState': 'unknown', 'reason': 'invalid_registry_data'}
    flags, invalid = [], False

    def walk(value):
        nonlocal invalid
        if isinstance(value, dict):
            for key, item in value.items():
                if key == 'IOConsoleLocked':
                    if type(item) in (bool, int) and item in (0, 1):
                        flags.append(bool(item))
                    else:
                        invalid = True
                else:
                    walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(registry)
    if invalid or not flags:
        return {'screenState': 'unknown', 'reason': 'missing_or_invalid_lock_flag'}
    return {'screenState': 'locked' if any(flags) else 'unlocked'}


def query_state():
    try:
        result = subprocess.run(['/usr/sbin/ioreg', '-d1', '-l', '-a'], capture_output=True, timeout=5)
        if result.returncode:
            return {'screenState': 'unknown', 'reason': 'registry_query_failed'}
        return parse_state(result.stdout)
    except (OSError, subprocess.SubprocessError):
        return {'screenState': 'unknown', 'reason': 'registry_query_unavailable'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    state = query_state()
    # An unlocked desktop does not establish XCTest authorization or UI readiness.
    state['automationPermissionVerified'] = False
    if args.json:
        print(json.dumps(state, sort_keys=True))
    elif state['screenState'] == 'unlocked':
        print('UI preflight: screen unlocked; XCTest authorization is not verified.')
    elif state['screenState'] == 'locked':
        print('UI preflight: screen locked. Unlock the Mac; no UI test has started.')
    else:
        print('UI preflight: screen state unavailable; no UI test has started.')
    raise SystemExit({'unlocked': 0, 'locked': 2, 'unknown': 3}[state['screenState']])


if __name__ == '__main__':
    main()
