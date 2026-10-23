#!/usr/bin/env python3
"""Allocate owned UUID-scoped Measurement fixtures; retain their data for reproducible trials."""
import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / '.local/artifacts/measurement-stores'
STORE_KEY = 'LEVISTICA_MEASUREMENT_STORE_ID'
REQUEST_KEY = 'LEVISTICA_MEASUREMENT_CLEANUP_REQUEST'


def identifier(value):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, TypeError, AttributeError):
        raise ValueError('A nonzero canonical UUID is required') from None
    if parsed.int == 0 or str(parsed) != value.lower():
        raise ValueError('A nonzero canonical UUID is required')
    return str(parsed)


def allocate():
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    value = str(uuid.uuid4())
    marker = {'version': 1, 'storeID': value, 'bundleID': 'dev.fomalhaut16.Levistica.measurement',
              'removed': False, 'retained': True, 'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    path = BASE / (value + '.json')
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        file.write(json.dumps(marker) + '\n')
    return value


def owned(value):
    value = identifier(value)
    path = BASE / (value + '.json')
    if path.is_symlink():
        raise ValueError('Measurement store marker must not be a symbolic link')
    marker = json.loads(path.read_text())
    if (marker.get('version') != 1 or marker.get('storeID') != value
            or marker.get('bundleID') != 'dev.fomalhaut16.Levistica.measurement'
            or marker.get('removed') is not False):
        raise ValueError('Store was not allocated here or was already removed')
    return marker, path


def runtime_flags(pid):
    # Inspect only this verified PID; never print or retain its full environment.
    result = subprocess.run(['/bin/ps', 'eww', '-p', str(pid), '-o', 'command='],
                            check=True, capture_output=True, text=True, timeout=10)
    flags = {}
    for key in [STORE_KEY, REQUEST_KEY, 'LEVISTICA_EPHEMERAL']:
        values = re.findall(r'(?:^|\s)' + re.escape(key) + r'=([^\s]*)(?=\s|$)', result.stdout)
        if len(values) > 1:
            raise ValueError('Ambiguous Measurement process flag')
        if values:
            flags[key] = values[0]
    return flags


def selection(flags):
    if flags.get('LEVISTICA_EPHEMERAL') != '1' or REQUEST_KEY in flags:
        raise ValueError('Sampling requires a normal isolated Measurement launch, not cleanup')
    if STORE_KEY in flags:
        marker, _ = owned(flags[STORE_KEY])
        return {'mode': 'UUID-scoped persistent website data; memory-only browser metadata',
                'storeID': marker['storeID']}
    return {'mode': 'nonpersistent website data; memory-only browser metadata', 'storeID': None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['allocate', 'validate'])
    parser.add_argument('store_id', nargs='?')
    args = parser.parse_args()
    if args.mode == 'allocate':
        print(allocate())
    elif args.store_id is None:
        parser.error('A store ID is required')
    else:
        owned(args.store_id)


if __name__ == '__main__':
    main()
