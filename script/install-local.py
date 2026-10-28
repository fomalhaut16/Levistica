#!/usr/bin/env python3
"""Install a verified local package into the user's Applications, without launch.

First installation only. Existing destinations are never replaced or removed.
"""
import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'script' / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


startup = load('install_startup', 'verify-archive-startup.py')
security = load('install_security', 'check-release-security.py')


def applications_directory():
    directory = Path.home() / 'Applications'
    for path in [directory, *directory.parents]:
        if path.is_symlink():
            raise ValueError('Linked installation parents are not accepted')
    if directory.exists():
        value = directory.stat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid() or value.st_mode & 0o022:
            raise ValueError('Applications must be a real user-owned, non-shared directory')
    else:
        directory.mkdir(mode=0o755)
    return directory


def promote_new(source, destination):
    # Public SDK sys/stdio.h: RENAME_EXCL=4, RENAME_NOFOLLOW_ANY=16.
    # No check-then-rename or replacement fallback: a racing destination wins.
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x4 | 0x10) != 0:
        raise OSError(ctypes.get_errno(), 'Exclusive installation rename failed')


def inspect(app):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                   check=True, capture_output=True, timeout=15)
    signature = subprocess.run(['/usr/bin/codesign', '-dvv', str(app)],
                               check=True, capture_output=True, text=True, timeout=10).stderr
    entitlements = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)],
                                  check=True, capture_output=True, timeout=10).stdout
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    return security.validate(info, plistlib.loads(entitlements), signature)


def install(value):
    if sys.platform != 'darwin':
        raise ValueError('Local installation requires macOS')
    app = startup.package_bundle(value)
    original = startup.bundle_rehearsal.tree_digest(app, time.monotonic() + 10)
    facts = inspect(app)
    directory = applications_directory()
    destination = directory / 'Levistica.app'
    if os.path.lexists(destination):
        raise ValueError('Existing Levistica.app is retained; replacement is not supported')
    if startup.candidates():
        raise ValueError('Existing Levistica prevents installation; no process stopped')
    evidence_parent = startup.bundle_rehearsal.within_project(ROOT / '.local/artifacts')
    evidence_parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='local-install.', dir=evidence_parent))
    work.chmod(0o700)
    stage = None
    record = {'success': False, 'source': facts['source'], 'destination': str(destination),
              'appLaunched': False, 'normalDataUsed': False, 'existingAppReplaced': False,
              'notarizationVerified': False, 'phase': 'prepare'}
    try:
        stage = Path(tempfile.mkdtemp(prefix='.Levistica-install-', dir=directory))
        stage.chmod(0o700)
        prepared = stage / 'Levistica.app'
        record['phase'] = 'copy'
        subprocess.run(['/usr/bin/ditto', str(app), str(prepared)],
                       check=True, capture_output=True, timeout=30)
        record['phase'] = 'verify_copy'
        if (startup.bundle_rehearsal.tree_digest(prepared, time.monotonic() + 10) != original
                or startup.bundle_rehearsal.tree_digest(app, time.monotonic() + 10) != original
                or inspect(prepared) != facts):
            raise ValueError('Prepared or original application changed')
        record['phase'] = 'promote'
        if applications_directory() != directory or startup.candidates():
            raise ValueError('Installation conditions changed; prepared copy retained')
        promote_new(prepared, destination)
        record['phase'] = 'verify_installed'
        if (startup.bundle_rehearsal.tree_digest(destination, time.monotonic() + 10) != original
                or inspect(destination) != facts):
            raise ValueError('Installed application could not be verified')
        record.update(success=True, phase='complete', bundleTreeSHA256=original,
                      sandbox=facts['sandbox'], hardenedRuntime=facts['hardenedRuntime'],
                      adHocSignature=facts['adHocSignature'])
        stage.rmdir()
    except (Exception, KeyboardInterrupt) as error:
        # Never delete a destination or blindly retry an uncertain promotion.
        record.update(success=False, errorType=type(error).__name__, manualInspectionRequired=True)
        if stage is not None:
            record['preparedDirectory'] = str(stage)
    finally:
        descriptor = os.open(work / 'result.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            json.dump(record, output, indent=2)
            output.write('\n')
        print('Local installation evidence: ' + str(work / 'result.json'))
    if record['success']:
        print('Installed app: ' + str(destination))
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    args = parser.parse_args()
    try:
        return 0 if install(args.package)['success'] else 1
    except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException):
        print('Local installation rejected; existing apps were not replaced or launched.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
