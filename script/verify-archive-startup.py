#!/usr/bin/env python3
"""Bounded, ephemeral process-startup check, called by build_and_run.sh only.

No page inspection or profile migration; process survival is not GUI acceptance.
"""
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
# A user may rename the .app bundle; the executable suffix stays unchanged.
SUFFIX = '/Contents/MacOS/Levistica'
spec = importlib.util.spec_from_file_location('bundle_rehearsal', ROOT/'script/rehearse-update.py')
bundle_rehearsal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle_rehearsal)

screen_spec = importlib.util.spec_from_file_location('startup_ui_session', ROOT/'script/check-ui-session.py')
screen = importlib.util.module_from_spec(screen_spec)
screen_spec.loader.exec_module(screen)


def package_bundle(value):
    """Resolve only a previously verified private package, without extracting it."""
    folder = bundle_rehearsal.within_project(pathlib.Path(value))
    parts = folder.relative_to(ROOT / '.local/packages').parts
    if len(parts) != 1 or not re.fullmatch(r'local-[a-z0-9_]{8}', parts[0]):
        raise ValueError('Use a project local package directory')
    manifest = folder / 'manifest.json'
    if manifest.is_symlink() or not manifest.is_file() or manifest.stat().st_size > 32768:
        raise ValueError('A bounded, real package manifest is required')
    data = json.loads(manifest.read_text())
    if not isinstance(data, dict):
        raise ValueError('Invalid manifest object')
    for key in ['success', 'roundtripVerified', 'signatureVerified', 'sandbox', 'hardenedRuntime']:
        if data.get(key) is not True:
            raise ValueError('Package verification is incomplete')
    if data.get('scope') != 'local-validation':
        raise ValueError('Unexpected package scope')
    source = data.get('source')
    version = data.get('version')
    if (not isinstance(source, str) or not re.fullmatch('[0-9a-f]{40}', source)
            or not isinstance(version, str) or len(version) > 32
            or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version)):
        raise ValueError('Invalid package source or version')
    expected_name = f'Levistica-{version}-local-{source[:7]}.zip'
    if data.get('zipFile') != expected_name:
        raise ValueError('Package filename does not match its identity')
    archive = folder / expected_name
    if archive.is_symlink() or not archive.is_file() or archive.stat().st_size > 512 * 1024**2:
        raise ValueError('A bounded, real package ZIP is required')
    deadline = time.monotonic() + 10
    digest = hashlib.sha256()
    with archive.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            if time.monotonic() > deadline:
                raise TimeoutError('Package integrity check deadline exceeded')
            digest.update(chunk)
    if digest.hexdigest() != data.get('zipSHA256'):
        raise ValueError('Package ZIP changed')
    app = bundle_rehearsal.within_project(folder / 'unpacked/Levistica.app')
    if bundle_rehearsal.tree_digest(app, deadline) != data.get('bundleTreeSHA256'):
        raise ValueError('Extracted app changed')
    # The bounded tree check runs before enumerating the verified small bundle.
    for path in [folder / 'unpacked', app, *app.rglob('*')]:
        if path.is_symlink():
            raise ValueError('Linked extracted bundles are not accepted')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('LevisticaSourceRevision') != source or info.get('CFBundleShortVersionString') != version:
        raise ValueError('Extracted app identity differs from the manifest')
    return app


def installed_bundle(value):
    source = package_bundle(value)
    app = pathlib.Path.home() / 'Applications/Levistica.app'
    if any(path.is_symlink() for path in [app, *app.parents]):
        raise ValueError('Linked installation paths are not accepted')
    deadline = time.monotonic() + 10
    if bundle_rehearsal.tree_digest(app, deadline) != bundle_rehearsal.tree_digest(source, deadline):
        raise ValueError('Installed application differs from its verified package')
    return app


def archive_bundle(value):
    archive = pathlib.Path(value).absolute()
    parts = archive.relative_to(ROOT / '.local/archives').parts
    if len(parts) != 2 or not re.fullmatch(r'local-[A-Za-z0-9]{6,32}', parts[0]) or parts[1] != 'Levistica.xcarchive':
        raise ValueError('Use a project local archive')
    app = archive / 'Products/Applications/Levistica.app'
    current = ROOT
    for part in app.relative_to(ROOT).parts:
        current /= part
        if current.is_symlink():
            raise ValueError('Linked archive paths are not accepted')
    if not app.is_dir():
        raise ValueError('Archive app is missing')
    return app


def run(arguments):
    return subprocess.check_output(arguments, stderr=subprocess.PIPE, timeout=10)


def candidates():
    result = []
    for row in run(['/bin/ps', '-axo', 'pid=,comm=']).decode().splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and fields[1].endswith(SUFFIX):
            result.append((int(fields[0]), fields[1]))
    return result


def identity(pid):
    # Read the environment only in memory; never return or store the raw output.
    path = run(['/bin/ps', '-p', str(pid), '-o', 'comm=']).decode().strip()
    started = run(['/bin/ps', '-p', str(pid), '-o', 'lstart=']).decode().strip()
    uid = int(run(['/bin/ps', '-p', str(pid), '-o', 'uid=']).strip())
    command = run(['/bin/ps', 'eww', '-p', str(pid), '-o', 'command=']).decode()
    flags = re.findall(r'(?:^|\s)LEVISTICA_EPHEMERAL=([^\s]*)', command)
    return {'pid': pid, 'path': path, 'started': started, 'uid': uid, 'ephemeral': flags == ['1']}


def owned(value, executable):
    return (value['path'] == str(executable) and value['uid'] == os.getuid()
            and value['ephemeral'] is True and bool(value['started']))


def stop_owned(value, executable):
    # Never follow a replacement PID, changed path, or absent isolation flag.
    if not owned(value, executable) or identity(value['pid']) != value:
        raise ValueError('Archive process identity changed; no signal sent')
    os.kill(value['pid'], signal.SIGTERM)
    limit = time.monotonic() + 10
    while time.monotonic() < limit:
        if not any(pid == value['pid'] for pid, _ in candidates()):
            return
        if identity(value['pid']) != value:
            raise ValueError('Archive process identity changed during shutdown')
        time.sleep(.1)
    raise TimeoutError('Archive process did not exit; no force kill attempted')


def verify(value, *, package=False, installed=False):
    app = installed_bundle(value) if installed else package_bundle(value) if package else archive_bundle(value)
    executable = app / 'Contents/MacOS/Levistica'
    if executable.is_symlink() or not executable.is_file():
        raise ValueError('A real archive executable is required')
    bundle_digest = bundle_rehearsal.tree_digest(app, time.monotonic()+10)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != 'dev.fomalhaut16.Levistica'
            or info.get('CFBundleExecutable') != 'Levistica'
            or info.get('LevisticaSourceState') != 'clean'
            or not re.fullmatch('[0-9a-f]{40}', str(info.get('LevisticaSourceRevision', '')))):
        raise ValueError('Archive identity is not a clean normal Release')
    expected = plistlib.loads((ROOT / 'Levistica/Levistica.entitlements').read_bytes())
    if plistlib.loads(run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])) != expected:
        raise ValueError('Unexpected archive entitlements')
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    parent = ROOT / '.local/artifacts'
    if parent.is_symlink() or parent.parent.is_symlink():
        raise ValueError('Linked artifact parent is not accepted')
    parent.mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix='archive-startup.', dir=parent))
    record = {'success': False, 'guiVerified': False, 'profileMigrationTested': False,
              'source': info['LevisticaSourceRevision'], 'executableSHA256': digest,
              'artifactKind': 'installed' if installed else 'package' if package else 'archive'}
    process = None
    try:
        record['verificationRevision'] = run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).decode().strip()
        record['verificationDirty'] = bool(run(['git', '-C', str(ROOT), 'status', '--porcelain', '--untracked-files=normal']).strip())
        state = screen.query_state()['screenState']
        record['screenStateBeforeLaunch'] = state
        if state != 'unlocked':
            raise ValueError('An unlocked screen is required; no app launched')
        if candidates():
            raise ValueError('Close existing Levistica before this isolated check')
        run(['/usr/bin/open', '-n', '--env', 'LEVISTICA_EPHEMERAL=1', str(app)])
        limit = time.monotonic() + 10
        while time.monotonic() < limit:
            found = candidates()
            if found:
                if len(found) != 1 or found[0][1] != str(executable):
                    raise ValueError('Unexpected application launched; no signal sent')
                observed = identity(found[0][0])
                if not owned(observed, executable):
                    raise ValueError('Isolation could not be verified; no signal sent')
                process = observed
                break
            time.sleep(.1)
        if process is None:
            raise TimeoutError('Archive did not start')
        time.sleep(2)
        if identity(process['pid']) != process or candidates() != [(process['pid'], str(executable))]:
            raise ValueError('Process changed during startup observation')
        record['process'] = process
        record['survivedSeconds'] = 2
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        if hashlib.sha256(executable.read_bytes()).hexdigest() != digest:
            raise ValueError('Archive executable changed')
        if bundle_rehearsal.tree_digest(app, time.monotonic()+10) != bundle_digest:
            raise ValueError('Archive bundle changed')
        record['success'] = True
    except (Exception, KeyboardInterrupt) as error:
        record.update(errorType=type(error).__name__, manualInspectionRequired=True)
    finally:
        if process is not None:
            try:
                stop_owned(process, executable)
                record['ownedProcessStopped'] = True
            except (Exception, KeyboardInterrupt) as error:
                record.update(success=False, cleanupErrorType=type(error).__name__, manualInspectionRequired=True)
        (work/'result.json').write_text(json.dumps(record, indent=2)+'\n')
        print('Archive startup evidence: '+str(work/'result.json'))
    return record


if __name__ == '__main__':
    try:
        package_mode = len(sys.argv) == 3 and sys.argv[1] in ('--package', '--installed')
        installed_mode = package_mode and sys.argv[1] == '--installed'
        if len(sys.argv) != 2 and not package_mode:
            raise ValueError('One archive or explicit package path is required')
        value = sys.argv[2] if package_mode else sys.argv[1]
        raise SystemExit(0 if verify(value, package=package_mode, installed=installed_mode)['success'] else 1)
    except (ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        print('Archive startup rejected ('+type(error).__name__+').')
        raise SystemExit(1) from None
