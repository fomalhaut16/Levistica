#!/usr/bin/env python3
"""Allocate owned UUID-scoped Measurement fixtures; retain their data for reproducible trials."""
import argparse
from contextlib import closing
import datetime
import json
import os
import pathlib
import re
import sqlite3
import subprocess
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / '.local/artifacts/measurement-stores'
STORE_KEY = 'LEVISTICA_MEASUREMENT_STORE_ID'
METADATA_KEY = 'LEVISTICA_MEASUREMENT_PERSIST_METADATA'
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
    for key in [STORE_KEY, METADATA_KEY, REQUEST_KEY, 'LEVISTICA_EPHEMERAL']:
        values = re.findall(r'(?:^|\s)' + re.escape(key) + r'=([^\s]*)(?=\s|$)', result.stdout)
        if len(values) > 1:
            raise ValueError('Ambiguous Measurement process flag')
        if values:
            flags[key] = values[0]
    return flags


def selection(flags):
    if flags.get('LEVISTICA_EPHEMERAL') != '1' or REQUEST_KEY in flags:
        raise ValueError('Sampling requires a normal isolated Measurement launch, not cleanup')
    metadata = flags.get(METADATA_KEY, '0')
    if metadata not in ('0', '1') or (metadata == '1' and STORE_KEY not in flags):
        raise ValueError('Persistent metadata requires an owned named store')
    if STORE_KEY in flags:
        marker, _ = owned(flags[STORE_KEY])
        mode = ('UUID-scoped persistent website data and isolated browser metadata' if metadata == '1'
                else 'UUID-scoped persistent website data; memory-only browser metadata')
        return {'mode': mode, 'metadataPersistent': metadata == '1',
                'storeID': marker['storeID']}
    return {'mode': 'nonpersistent website data; memory-only browser metadata', 'metadataPersistent': False, 'storeID': None}


def metadata_snapshot(pid, store_id):
    """Read counts only from the verified app's owned UUID-scoped SQLite files."""
    marker, _ = owned(store_id)
    suffix = '/LevisticaMeasurementProfiles/' + marker['storeID'] + '/session.sqlite3'
    listing = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), '-Fn'],
                             check=True, capture_output=True, text=True, timeout=10)
    candidates = {pathlib.Path(line[1:]) for line in listing.stdout.splitlines()
                  if line.startswith('n/') and line[1:].endswith(suffix)}
    if len(candidates) != 1:
        raise ValueError('Owned measurement session database is not uniquely open')
    session = candidates.pop()
    history = session.with_name('history.sqlite3')
    if any(path.is_symlink() for path in (session.parent.parent, session.parent, session, history)):
        raise ValueError('Measurement metadata must not use symbolic links')
    try:
        with closing(sqlite3.connect(session.as_uri() + '?mode=ro', uri=True, timeout=1)) as connection:
            connection.execute('PRAGMA query_only=ON')
            tabs = connection.execute('SELECT count(*) FROM session_tabs').fetchone()[0]
            session_version = connection.execute('PRAGMA user_version').fetchone()[0]
        with closing(sqlite3.connect(history.as_uri() + '?mode=ro', uri=True, timeout=1)) as connection:
            connection.execute('PRAGMA query_only=ON')
            entries = connection.execute('SELECT count(*) FROM history').fetchone()[0]
            history_version = connection.execute('PRAGMA user_version').fetchone()[0]
    except sqlite3.Error:
        raise ValueError('Owned measurement metadata could not be read') from None
    return {'tabCount': tabs, 'historyCount': entries, 'sessionSchema': session_version,
            'historySchema': history_version}


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
