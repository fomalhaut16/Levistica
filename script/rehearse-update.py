#!/usr/bin/env python3
"""Rehearse signed-bundle replacement on private copies; never install or launch.

Only project Release/archive inputs are accepted. There is no destination/apply
option. Real profiles are not copied; application/schema compatibility is untested.
"""
import argparse
import ctypes
import errno
import hashlib
import itertools
import json
import os
import pathlib
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent


class RecoveryUncertain(Exception):
    """Keep both slots and untouched reference copies for inspection."""


def within_project(path):
    path = pathlib.Path(path).absolute()
    parts = path.relative_to(ROOT).parts
    if '..' in parts:
        raise ValueError('Parent traversal is not accepted')
    current = ROOT
    for part in parts:
        current /= part
        if current.is_symlink():
            raise ValueError('Linked input/output parents are not accepted')
    return path


def tree_digest(app, deadline=None):
    app = pathlib.Path(app)
    if app.is_symlink() or not app.is_dir():
        raise ValueError('A real bundle directory is required')
    entries = list(itertools.islice(app.rglob('*'), 2001))
    if len(entries) > 2000:
        raise ValueError('Bundle exceeds this rehearsal file limit')
    digest = hashlib.sha256()
    total = 0
    for path in [app, *sorted(entries)]:
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError('Rehearsal deadline reached')
        mode = path.lstat().st_mode
        relative = str(path.relative_to(app))
        digest.update(json.dumps([relative, stat.S_IMODE(mode)]).encode())
        if stat.S_ISLNK(mode):
            target = os.readlink(path)
            if pathlib.Path(target).is_absolute() or not path.resolve(strict=True).is_relative_to(app.resolve()):
                raise ValueError('Bundle links must stay inside the bundle')
            digest.update(b'link' + os.fsencode(target))
        elif stat.S_ISREG(mode):
            expected_size = path.stat().st_size
            total += expected_size
            if total > 256 * 1024**2:
                raise ValueError('Bundle exceeds this rehearsal byte limit')
            digest.update(json.dumps(['file', expected_size]).encode())
            observed_size = 0
            with path.open('rb') as file:
                for chunk in iter(lambda: file.read(1024*1024), b''):
                    if deadline is not None and time.monotonic() >= deadline:
                        raise TimeoutError('Rehearsal deadline reached')
                    observed_size += len(chunk)
                    if observed_size > expected_size:
                        raise ValueError('Bundle changed or exceeded its byte limit')
                    digest.update(chunk)
            if observed_size != expected_size or path.stat().st_size != expected_size:
                raise ValueError('Bundle changed during hashing')
        elif stat.S_ISDIR(mode):
            digest.update(b'directory')
        else:
            raise ValueError('Special files are not accepted')
    return digest.hexdigest()


def exchange_directories(first, second):
    """macOS public renameatx_np: no delete/rename fallback on failure."""
    if sys.platform != 'darwin':
        raise OSError(errno.ENOTSUP, 'macOS atomic exchange is required')
    first, second = pathlib.Path(first), pathlib.Path(second)
    if first.is_symlink() or second.is_symlink() or not first.is_dir() or not second.is_dir():
        raise ValueError('Exchange requires two real directories')
    if first.stat().st_dev != second.stat().st_dev:
        raise OSError(errno.EXDEV, 'Exchange requires one filesystem')
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    rename = library.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # SDK <sys/fcntl.h>: AT_FDCWD=-2; <sys/stdio.h>: SWAP=2, NOFOLLOW_ANY=16.
    if rename(-2, os.fsencode(first), -2, os.fsencode(second), 0x2 | 0x10) != 0:
        raise OSError(ctypes.get_errno(), 'Atomic directory exchange failed')


def checked_exchange(installed, prepared, old, new, inspect, exchange=exchange_directories, deadline=None):
    """The caller supplies only copies inside this invocation's private directory."""
    if inspect(installed) != old or inspect(prepared) != new:
        raise ValueError('The prepared slots changed before exchange')
    # A failed syscall has no rename/delete fallback. Untouched references remain.
    try:
        exchange(installed, prepared)
    except (Exception, KeyboardInterrupt):
        try:
            unchanged = (tree_digest(installed, deadline) == old['treeSHA256']
                         and tree_digest(prepared, deadline) == new['treeSHA256'])
        except Exception:
            unchanged = False
        if not unchanged:
            raise RecoveryUncertain('Failed exchange left an unknown state; all copies retained') from None
        raise
    try:
        if tree_digest(installed, deadline) != new['treeSHA256'] or tree_digest(prepared, deadline) != old['treeSHA256']:
            raise RecoveryUncertain('Exchange did not leave the two expected payloads')
        if inspect(installed) != new or inspect(prepared) != old:
            raise ValueError('Post-exchange validation failed')
    except (Exception, KeyboardInterrupt) as error:
        # Never blindly exchange paths after an unknown state or a damaged payload.
        try:
            proven = (tree_digest(installed, deadline) == new['treeSHA256']
                      and tree_digest(prepared, deadline) == old['treeSHA256'])
        except Exception:
            proven = False
        if not proven:
            raise RecoveryUncertain('State is unknown; all copies retained') from None
        try:
            exchange(installed, prepared)
            if tree_digest(installed, deadline) != old['treeSHA256'] or tree_digest(prepared, deadline) != new['treeSHA256']:
                raise RecoveryUncertain('Rollback payloads could not be verified')
        except Exception:
            raise RecoveryUncertain('Rollback failed; all copies retained') from None
        raise ValueError('Post-check failed; original slots restored') from error


def rehearse(archive):
    if sys.platform != 'darwin':
        raise ValueError('This rehearsal requires macOS/APFS')
    archive = within_project(archive)
    parts = archive.relative_to(ROOT / '.local/archives').parts
    if len(parts) != 2 or not re.fullmatch(r'local-[A-Za-z0-9]{6,32}', parts[0]) or parts[1] != 'Levistica.xcarchive':
        raise ValueError('Use a project --archive-local artifact')
    baseline = within_project(ROOT / '.local/DerivedData/Build/Products/Release/Levistica.app')
    candidate = within_project(archive / 'Products/Applications/Levistica.app')
    parent = within_project(ROOT / '.local/artifacts')
    parent.mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix='bundle-update-rehearsal.', dir=parent))
    work.chmod(0o700)
    print('Private rehearsal directory: '+str(work), flush=True)
    deadline = time.monotonic() + 120
    record = {'success': False, 'archiveLaunched': False, 'normalDataCopied': False,
              'schemaMigrationPerformed': False, 'checkpoints': []}
    def run(command):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Rehearsal deadline reached')
        return subprocess.check_output(command, stderr=subprocess.PIPE, timeout=min(20, remaining))
    expected_entitlements = plistlib.loads((ROOT / 'Levistica/Levistica.entitlements').read_bytes())
    def inspect(app):
        digest = tree_digest(app, deadline)  # Reject unsafe links before invoking tools.
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if (info.get('CFBundleIdentifier') != 'dev.fomalhaut16.Levistica'
                or info.get('LevisticaSourceState') != 'clean'
                or not re.fullmatch('[0-9a-f]{40}', str(info.get('LevisticaSourceRevision', '')))
                or any(not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', str(info.get(key, '')))
                       for key in ('CFBundleVersion', 'CFBundleShortVersionString'))):
            raise ValueError('Unexpected bundle identity or source')
        entitlements = plistlib.loads(run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)]))
        if entitlements != expected_entitlements or entitlements.get('com.apple.security.get-task-allow') is True:
            raise ValueError('Unexpected bundle permissions')
        if tree_digest(app, deadline) != digest:
            raise ValueError('Bundle changed during inspection')
        return {'source': info['LevisticaSourceRevision'], 'version': info['CFBundleShortVersionString'],
                'build': info['CFBundleVersion'], 'treeSHA256': digest}
    def copy(source, destination, expected):
        run(['/usr/bin/ditto', str(source), str(destination)])
        if inspect(destination) != expected:
            raise ValueError('Copy failed validation')
    try:
        record['rehearsalRevision'] = run(['git','-C',str(ROOT),'rev-parse','HEAD']).decode().strip()
        record['rehearsalDirty'] = bool(run(['git','-C',str(ROOT),'status','--porcelain','--untracked-files=normal']).strip())
        device = run(['/bin/df', '-P', str(work)]).decode().splitlines()[-1].split()[0]
        if not device.startswith('/dev/'):
            raise ValueError('Unsupported rehearsal device')
        fs = plistlib.loads(run(['/usr/sbin/diskutil', 'info', '-plist', device])).get('FilesystemType')
        record['filesystem'] = fs
        if fs != 'apfs':
            raise ValueError('This rehearsal is limited to APFS')
        old, new = inspect(baseline), inspect(candidate)
        record.update(baseline=old, candidate=new, differentSignedBuilds=old != new,
                      versionChanged=(old['version'],old['build']) != (new['version'],new['build']))
        installed, prepared = work/'Installed.app', work/'Prepared.app'
        # These reference copies never participate in exchange or rollback.
        copy(baseline, work/'ReferenceOld.app', old)
        copy(candidate, work/'ReferenceNew.app', new)
        copy(baseline, installed, old)
        copy(candidate, prepared, new)
        sentinel = work/'synthetic-data.json'
        sentinel.write_text('{"fixture":"generated only","value":7}\n')
        sentinel_hash = hashlib.sha256(sentinel.read_bytes()).hexdigest()
        checked_exchange(installed, prepared, old, new, inspect, deadline=deadline)
        record['checkpoints'].append('updated_bundle_verified')
        checked_exchange(installed, prepared, new, old, inspect, deadline=deadline)
        record['checkpoints'].append('original_bundle_restored')
        broken = work/'Broken.app'
        copy(candidate, broken, new)
        info_path = broken/'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes()); info['CFBundleVersion'] = '999'
        info_path.write_bytes(plistlib.dumps(info))
        try:
            checked_exchange(installed, broken, old, new, inspect, deadline=deadline)
        except (ValueError, subprocess.SubprocessError):
            if inspect(installed) != old:
                raise RecoveryUncertain('Original changed after rejected candidate')
        else:
            raise ValueError('Corrupt candidate was not rejected')
        record['checkpoints'].append('corrupt_candidate_rejected_without_replacement')
        try:
            exchange_directories(installed, work/'Absent.app')
        except (OSError, ValueError):
            if inspect(installed) != old:
                raise RecoveryUncertain('Original changed after failed exchange')
        else:
            raise ValueError('Missing slot was not rejected')
        record['checkpoints'].append('missing_slot_rejected_without_replacement')
        if (hashlib.sha256(sentinel.read_bytes()).hexdigest() != sentinel_hash
                or inspect(baseline) != old or inspect(candidate) != new
                or inspect(work/'ReferenceOld.app') != old or inspect(work/'ReferenceNew.app') != new):
            raise ValueError('An untouched source/reference or synthetic data changed')
        record.update(success=True, syntheticDataUnchanged=True, sourceBundlesUnchanged=True,
                      elapsedSeconds=120-(deadline-time.monotonic()))
    except (Exception, KeyboardInterrupt) as error:
        # Never include command stderr or arbitrary bundle strings in the report.
        record.update(errorType=type(error).__name__, manualInspectionRequired=isinstance(error,(RecoveryUncertain,KeyboardInterrupt)))
    finally:
        record['elapsedSeconds'] = 120-(deadline-time.monotonic())
        result = work/'result.json'
        temporary = work/'result.partial.json'
        temporary.write_text(json.dumps(record, indent=2)+'\n'); temporary.chmod(0o600)
        os.replace(temporary,result)
    return result, record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=pathlib.Path, required=True)
    args = parser.parse_args()
    result, record = rehearse(args.archive)
    print('Private rehearsal evidence: '+str(result))
    print(json.dumps({key:record.get(key) for key in ('success','errorType','versionChanged','checkpoints','elapsedSeconds')}))
    return 0 if record['success'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError,OSError) as error:
        print('Rehearsal rejected ('+type(error).__name__+'); no application was installed or launched.')
        raise SystemExit(1) from None
