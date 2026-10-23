#!/usr/bin/env python3
"""Own UUID-scoped Measurement stores and verify cleanup receipts; never targets default storage."""
import argparse
import datetime
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / '.local/artifacts/measurement-stores'
APP = ROOT / '.local/MeasurementDerivedData/Build/Products/Release/Levistica.app'
RECEIPTS = pathlib.Path.home() / 'Library/Containers/dev.fomalhaut16.Levistica.measurement/Data/Library/Application Support/LevisticaMeasurementReceipts'
STORE_KEY = 'LEVISTICA_MEASUREMENT_STORE_ID'
REQUEST_KEY = 'LEVISTICA_MEASUREMENT_CLEANUP_REQUEST'
spec = importlib.util.spec_from_file_location('app_processes', ROOT / 'script/check-app-processes.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def identifier(value):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, TypeError, AttributeError):
        raise ValueError('A nonzero canonical UUID is required') from None
    if parsed.int == 0 or str(parsed) != value.lower():
        raise ValueError('A nonzero canonical UUID is required')
    return str(parsed)


def allocate():
    BASE.mkdir(parents=True, exist_ok=True)
    value = str(uuid.uuid4())
    marker = {'version': 1, 'storeID': value, 'bundleID': 'dev.fomalhaut16.Levistica.measurement',
              'removed': False, 'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    path = BASE / (value + '.json')
    with path.open('x') as file:
        path.chmod(0o600)
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


def check_receipt(receipt, store_id, request_id):
    if (receipt.get('version') != 1 or identifier(receipt.get('storeID')) != identifier(store_id)
            or identifier(receipt.get('requestID')) != identifier(request_id)
            or receipt.get('success') is not True
            or receipt.get('otherIdentifiersUnchanged') is not True
            or type(receipt.get('storeExisted')) is not bool):
        raise ValueError('Missing, unsuccessful or mismatched cleanup receipt')


def require_inactive():
    before = guard.check_snapshot(guard.run_ps(['-axo', 'pid=,comm=']), ROOT,
                                  guard.describe_process, os.getuid(), only='Measurement')
    if before:
        raise ValueError('Cleanup requires the page-hosting Measurement app to have exited')


def cleanup(value):
    marker, marker_path = owned(value)
    value = marker['storeID']
    require_inactive()
    with (APP / 'Contents/Info.plist').open('rb') as source:
        if plistlib.load(source).get('CFBundleIdentifier') != 'dev.fomalhaut16.Levistica.measurement':
            raise ValueError('Cleanup requires the isolated Measurement bundle')
    directory = pathlib.Path(tempfile.mkdtemp(prefix='cleanup.', dir=BASE))
    request = str(uuid.uuid4())
    receipt_path = directory / 'receipt.json'
    app_receipt = RECEIPTS / (request + '.json')
    if app_receipt.exists() or app_receipt.is_symlink():
        raise ValueError('Cleanup request already has a receipt')
    stderr_path = directory / 'app-stderr.log'
    for path in [receipt_path, stderr_path]:
        path.touch(mode=0o600)
    command = ['/usr/bin/open', '-n', '-g', '-j', '-W', '--stderr', str(stderr_path), '--env', 'LEVISTICA_EPHEMERAL=1',
               '--env', STORE_KEY + '=' + value, '--env', REQUEST_KEY + '=' + request, str(APP)]
    try:
        subprocess.run(command, check=True, capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        candidates = guard.check_snapshot(guard.run_ps(['-axo', 'pid=,comm=']), ROOT,
                                          guard.describe_process, os.getuid(), only='Measurement')
        for pid in candidates:
            started = guard.run_ps(['-p', str(pid), '-o', 'lstart='])
            flags = runtime_flags(pid)
            if (flags.get(STORE_KEY) == value and flags.get(REQUEST_KEY) == request
                    and started is not None and guard.run_ps(['-p', str(pid), '-o', 'lstart=']) == started):
                os.kill(pid, signal.SIGTERM)
        raise
    after = guard.check_snapshot(guard.run_ps(['-axo', 'pid=,comm=']), ROOT,
                                 guard.describe_process, os.getuid(), only='Measurement')
    if after:
        raise ValueError('Cleanup app did not exit')
    if app_receipt.is_symlink():
        raise ValueError('Cleanup receipt must not be a symbolic link')
    receipt = json.loads(app_receipt.read_text())
    check_receipt(receipt, value, request)
    receipt_path.write_text(json.dumps(receipt) + '\n')
    marker['removed'] = True
    marker['cleanupReceipt'] = str(receipt_path)
    marker['removedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    temporary = marker_path.with_suffix('.tmp')
    temporary.write_text(json.dumps(marker) + '\n')
    temporary.chmod(0o600)
    temporary.replace(marker_path)
    print(json.dumps({'storeID': value, 'removed': True, 'storeExisted': receipt['storeExisted'],
                      'receipt': str(receipt_path)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['allocate', 'validate', 'cleanup'])
    parser.add_argument('store_id', nargs='?')
    parser.add_argument('--require-inactive', action='store_true')
    args = parser.parse_args()
    if args.require_inactive and args.mode != 'validate':
        parser.error('require-inactive is only supported by validate')
    if args.mode == 'allocate':
        print(allocate())
    elif args.store_id is None:
        parser.error('A store ID is required')
    elif args.mode == 'validate':
        owned(args.store_id)
        if args.require_inactive:
            require_inactive()
    else:
        cleanup(args.store_id)


if __name__ == '__main__':
    main()
