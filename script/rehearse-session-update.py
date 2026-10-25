#!/usr/bin/env python3
"""Bounded revision upgrade/rollback with generated UUID-scoped metadata only.

Called by build_and_run.sh. This is not an installer, a cookie backup, or a
normal-profile restore tool. Retain all copies and the allocated test store.
"""
from contextlib import closing
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUNDLE_ID = 'dev.fomalhaut16.Levistica.measurement'


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'script' / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


bundles = module('session_update_bundles', 'rehearse-update.py')
stores = module('session_update_stores', 'measurement-store.py')


def real_path(path, base):
    path, base = pathlib.Path(path).absolute(), pathlib.Path(base).absolute()
    parts = path.relative_to(base).parts
    if '..' in parts:
        raise ValueError('Parent traversal is not accepted')
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ValueError('Linked paths are not accepted')
    return path


def baseline_path(value):
    base = ROOT / '.local/session-update-baselines'
    path = real_path(value, base)
    parts = path.relative_to(base).parts
    if len(parts) != 2 or not re.fullmatch('[0-9a-f]{40}', parts[0]) or parts[1] != 'Levistica.app':
        raise ValueError('Use a revision-named project Measurement baseline')
    return path


def read_session(path):
    with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=1)) as db:
        db.execute('PRAGMA query_only=ON')
        if db.execute('PRAGMA user_version').fetchone() != (3,) or db.execute('PRAGMA integrity_check').fetchone() != ('ok',):
            raise ValueError('An intact version-three fixture is required')
        rows = db.execute('SELECT id,position,title,url,may_reload,kind,is_kept,is_sleeping FROM session_tabs ORDER BY position').fetchall()
        meta = db.execute('SELECT selected_id,was_running FROM session_meta WHERE id=1').fetchone()
    return rows, meta


def metadata_digest(folder, deadline):
    # This fresh namespace contains browser metadata, never WebKit's website store.
    allowed = {'session.sqlite3', 'session.sqlite3.backup', 'browser-preferences.json'}
    entries = list(folder.iterdir())
    if not entries or len(entries) > 3 or any(p.name not in allowed or p.is_symlink() or not p.is_file() for p in entries):
        raise ValueError('Unexpected fixture files; no restore attempted')
    if sum(p.stat().st_size for p in entries) > 1024 * 1024:
        raise ValueError('Fixture exceeds one MiB')
    return {'treeSHA256': bundles.tree_digest(folder, deadline)}


class Trial:
    def __init__(self, baseline):
        self.baseline = baseline_path(baseline)
        self.new = real_path(ROOT / '.local/MeasurementDerivedData/Build/Products/Release/Levistica.app', ROOT)
        parent = real_path(ROOT / '.local/artifacts', ROOT)
        self.work = pathlib.Path(tempfile.mkdtemp(prefix='session-update.', dir=parent))
        self.work.chmod(0o700)
        self.deadline = time.monotonic() + 600
        self.active = None
        self.store_id = None
        self.marker_digest = None
        self.metadata_folder = None
        self.result = {'success': False, 'normalDataUsed': False, 'cookiesTested': False,
                       'distributionUpdateTested': False, 'checkpoints': []}

    def run(self, args):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError('Ten-minute trial limit reached')
        return subprocess.check_output(args, stderr=subprocess.PIPE, timeout=min(30, left))

    def apps(self):
        rows = []
        for line in self.run(['/bin/ps', '-axo', 'pid=,comm=']).decode().splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[1].endswith('/Contents/MacOS/Levistica'):
                rows.append((int(parts[0]), parts[1]))
        return rows

    def inspect(self, app):
        digest = bundles.tree_digest(app, self.deadline)
        self.run(['/usr/bin/codesign', '--verify', '--strict', str(app)])
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if (info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleExecutable') != 'Levistica'
                or info.get('LevisticaSourceState') != 'clean'
                or not re.fullmatch('[0-9a-f]{40}', str(info.get('LevisticaSourceRevision', '')))):
            raise ValueError('A clean isolated Measurement build is required')
        expected = plistlib.loads((ROOT / 'Levistica/Levistica.entitlements').read_bytes())
        actual = plistlib.loads(self.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)]))
        if actual != expected or actual.get('com.apple.security.get-task-allow') is True:
            raise ValueError('Unexpected Measurement permissions')
        if bundles.tree_digest(app, self.deadline) != digest:
            raise ValueError('Bundle changed during verification')
        return {'source': info['LevisticaSourceRevision'], 'treeSHA256': digest}

    def owned(self):
        marker, path = stores.owned(self.store_id)
        if hashlib.sha256(path.read_bytes()).hexdigest() != self.marker_digest:
            raise ValueError('Store ownership marker changed')
        return marker

    def identity(self, pid, app):
        self.owned()
        executable = str(app / 'Contents/MacOS/Levistica')
        value = {'pid': pid, 'path': self.run(['/bin/ps', '-p', str(pid), '-o', 'comm=']).decode().strip(),
                 'started': self.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=']).decode().strip(),
                 'uid': int(self.run(['/bin/ps', '-p', str(pid), '-o', 'uid=']).strip())}
        if (value['path'] != executable or not value['started'] or value['uid'] != os.getuid()
                or self.apps() != [(pid, executable)]
                or stores.runtime_flags(pid) != {stores.STORE_KEY: self.store_id, stores.METADATA_KEY: '1', 'LEVISTICA_EPHEMERAL': '1'}):
            raise ValueError('Unexpected process or missing isolation; no signal sent')
        return value

    def start(self, app, expected):
        if self.apps():
            raise ValueError('Existing application; no launch attempted')
        self.owned()
        if self.inspect(app) != expected:
            raise ValueError('Changed input bundle')
        self.arm_startup()
        self.run(['/usr/bin/open', '-n', '--env', 'LEVISTICA_EPHEMERAL=1', '--env',
                  stores.STORE_KEY + '=' + self.store_id, '--env', stores.METADATA_KEY + '=1', str(app)])
        limit = min(self.deadline, time.monotonic() + 15)
        while time.monotonic() < limit:
            found = self.apps()
            if found:
                if len(found) != 1:
                    raise ValueError('Unexpected additional application')
                value = self.identity(found[0][0], app)
                self.active = (app, value)
                return value['pid']
            time.sleep(.1)
        raise TimeoutError('Measurement launch did not complete')

    def stop(self):
        if self.active is None:
            return
        app, value = self.active
        if self.identity(value['pid'], app) != value:
            raise ValueError('Process changed; no signal sent')
        os.kill(value['pid'], signal.SIGTERM)
        limit = min(self.deadline, time.monotonic() + 10)
        while time.monotonic() < limit:
            if not self.apps():
                self.active = None
                return
            if self.identity(value['pid'], app) != value:
                raise ValueError('Shutdown identity changed')
            time.sleep(.1)
        raise TimeoutError('Shutdown did not finish; no force kill attempted')

    def folder(self, pid):
        suffix = '/LevisticaMeasurementProfiles/' + self.store_id + '/session.sqlite3'
        base = pathlib.Path.home() / 'Library/Containers' / BUNDLE_ID / 'Data/Library/Application Support/LevisticaMeasurementProfiles'
        limit = min(self.deadline, time.monotonic() + 15)
        while time.monotonic() < limit:
            self.identity(pid, self.active[0])
            try:
                lines = self.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), '-Fn']).decode().splitlines()
            except subprocess.CalledProcessError:
                lines = []
            paths = {pathlib.Path(line[1:]) for line in lines if line.startswith('n/') and line[1:].endswith(suffix)}
            if len(paths) > 1:
                raise ValueError('Owned session database is not uniquely open')
            if paths:
                path = paths.pop()
                real_path(path, base)
                if path.parent.parent != base or path.parent.name != self.store_id:
                    raise ValueError('Wrong metadata namespace')
                try:
                    rows, meta = read_session(path)
                    if rows and meta is not None and meta[1] == 1:
                        self.metadata_folder = path.parent
                        return path.parent
                except (sqlite3.Error, ValueError):
                    pass  # The process can exist before its first transaction commits.
            time.sleep(.1)
        raise TimeoutError('Owned metadata did not finish startup')

    def arm_startup(self):
        if self.metadata_folder is None:
            return  # The first bootstrap must create its database itself.
        self.owned()
        base = pathlib.Path.home() / 'Library/Containers' / BUNDLE_ID / 'Data/Library/Application Support/LevisticaMeasurementProfiles'
        folder = real_path(self.metadata_folder, base)
        if folder.parent != base or folder.name != self.store_id or self.apps():
            raise ValueError('Unowned or running metadata cannot be armed')
        metadata_digest(folder, self.deadline)
        rows, meta = read_session(folder / 'session.sqlite3')
        if not rows or len(rows) > 2 or any(row[3] is not None for row in rows) or meta is None:
            raise ValueError('Only this trial\'s blank-URL fixture can be armed')
        # An inherited was_running=1 would make an open file look like a completed
        # startup. Require the app to commit a fresh 0 -> 1 transition each time.
        with closing(sqlite3.connect(folder / 'session.sqlite3')) as db:
            db.execute('UPDATE session_meta SET was_running=0 WHERE id=1')
            db.commit()

    def copy(self, source, target):
        before = metadata_digest(source, self.deadline)
        shutil.copytree(source, target)
        if metadata_digest(target, self.deadline) != before or metadata_digest(source, self.deadline) != before:
            raise ValueError('Fixture snapshot changed')
        return before

    def verify_rows(self, folder, rows, selected):
        actual, meta = read_session(folder / 'session.sqlite3')
        if actual != rows or meta != (selected, 1):
            raise ValueError('Generated session did not survive startup')

    def execute(self):
        if sys.platform != 'darwin':
            raise ValueError('This rehearsal requires macOS/APFS')
        if self.apps():
            raise ValueError('Close existing Levistica before the trial')
        device = self.run(['/bin/df', '-P', str(self.work)]).decode().splitlines()[-1].split()[0]
        if not device.startswith('/dev/') or plistlib.loads(self.run(['/usr/sbin/diskutil', 'info', '-plist', device])).get('FilesystemType') != 'apfs':
            raise ValueError('This rehearsal requires a private APFS directory')
        old, new = self.inspect(self.baseline), self.inspect(self.new)
        if old['source'] == new['source'] or old['source'] != self.baseline.parent.name:
            raise ValueError('Two different verified revisions are required')
        self.result.update(baseline=old, candidate=new)
        installed, prepared = self.work / 'Installed.app', self.work / 'Prepared.app'
        for source, target, expected in [(self.baseline, installed, old), (self.new, prepared, new)]:
            self.run(['/usr/bin/ditto', str(source), str(target)])
            if self.inspect(target) != expected:
                raise ValueError('Private application copy failed verification')
        self.store_id = stores.allocate()
        _, marker = stores.owned(self.store_id)
        self.marker_digest = hashlib.sha256(marker.read_bytes()).hexdigest()
        pid = self.start(installed, old)
        folder = self.folder(pid)
        rows, _ = read_session(folder / 'session.sqlite3')
        if len(rows) != 1 or rows[0][3] is not None:
            raise ValueError('Bootstrap namespace is not blank')
        self.stop()
        metadata_digest(folder, self.deadline)
        rows = [(str(uuid.uuid4()).upper(), i, 'Synthetic baseline ' + str(i), None, 0, 'web', 0, 0) for i in range(2)]
        selected = rows[1][0]
        with closing(sqlite3.connect(folder / 'session.sqlite3')) as db:
            db.execute('DELETE FROM session_tabs')
            db.executemany('INSERT INTO session_tabs (id,position,title,url,may_reload,kind,is_kept,is_sleeping) VALUES (?,?,?,?,?,?,?,?)', rows)
            db.execute('UPDATE session_meta SET selected_id=?,was_running=0 WHERE id=1', (selected,))
            db.commit()
        preferences = folder / 'browser-preferences.json'
        old_preferences = b'{"version":1,"newTabURL":null}\n'
        preferences.write_bytes(old_preferences)
        preferences.chmod(0o600)
        pid = self.start(installed, old)
        if self.folder(pid) != folder:
            raise ValueError('Namespace changed')
        self.verify_rows(folder, rows, selected)
        self.stop()
        snapshot = self.work / 'BaselineData'
        baseline_data = self.copy(folder, snapshot)
        self.result['checkpoints'].append('old_revision_saved_generated_session_and_preferences')
        bundles.checked_exchange(installed, prepared, old, new, self.inspect, deadline=self.deadline)
        self.result['checkpoints'].append('private_application_copy_updated_and_signature_verified')
        pid = self.start(installed, new)
        if self.folder(pid) != folder:
            raise ValueError('Namespace changed after update')
        self.verify_rows(folder, rows, selected)
        self.stop()
        if preferences.read_bytes() != old_preferences:
            raise ValueError('Old preferences changed during update')
        self.result['checkpoints'].append('new_revision_preserved_old_session')
        changed = [tuple([*row[:2], 'Synthetic newer ' + str(i), *row[3:]]) for i, row in enumerate(rows)]
        with closing(sqlite3.connect(folder / 'session.sqlite3')) as db:
            db.executemany('UPDATE session_tabs SET title=? WHERE id=?', [(row[2], row[0]) for row in changed])
            db.commit()
        preferences.write_bytes(b'{"version":1,"newTabURL":null,"searchEngine":"google"}\n')
        pid = self.start(installed, new)
        if self.folder(pid) != folder:
            raise ValueError('Namespace changed after newer fixture')
        self.verify_rows(folder, changed, selected)
        self.stop()
        if json.loads(preferences.read_bytes()).get('searchEngine') != 'google':
            raise ValueError('Newer fixture preferences changed')
        newer_data = self.copy(folder, self.work / 'NewerData')
        restore = self.work / 'RestoreSlot'
        self.copy(snapshot, restore)
        self.owned()
        if self.apps():
            raise ValueError('Application appeared before restore')
        bundles.checked_exchange(installed, prepared, new, old, self.inspect, deadline=self.deadline)
        inspect = lambda p: metadata_digest(p, self.deadline)
        bundles.checked_exchange(folder, restore, newer_data, baseline_data, inspect, deadline=self.deadline)
        if preferences.read_bytes() != old_preferences or metadata_digest(snapshot, self.deadline) != baseline_data:
            raise ValueError('Old data pair was not restored')
        self.result['checkpoints'].append('old_snapshot_restored_and_newer_snapshot_retained')
        if self.inspect(installed) != old or metadata_digest(folder, self.deadline) != baseline_data:
            raise ValueError('Old application and data pair did not verify; no launch attempted')
        pid = self.start(installed, old)
        if self.folder(pid) != folder:
            raise ValueError('Rollback namespace changed')
        self.verify_rows(folder, rows, selected)
        self.stop()
        if (preferences.read_bytes() != old_preferences
                or metadata_digest(self.work / 'NewerData', self.deadline) != newer_data
                or self.inspect(self.baseline) != old or self.inspect(self.new) != new):
            raise ValueError('Retained data or source bundles changed')
        self.result['checkpoints'].append('old_revision_reopened_its_corresponding_session')
        self.result.update(success=True, generatedTabCount=2, externalPageURLs=0, applicationLaunchCount=5,
                           newerSnapshotRetained=True, sourceBundlesUnchanged=True, startupCommitRequired=True,
                           storeID=self.store_id)

    def finish(self):
        try:
            self.stop()
            remaining = len(self.apps())
            self.result['remainingAppCount'] = remaining
            if remaining:
                self.result.update(success=False, manualInspectionRequired=True)
        except (Exception, KeyboardInterrupt) as error:
            self.result.update(success=False, manualInspectionRequired=True, cleanupErrorType=type(error).__name__)
        self.result['elapsedSeconds'] = 600 - (self.deadline - time.monotonic())
        path = self.work / 'result.json'
        path.write_text(json.dumps(self.result, indent=2) + '\n')
        path.chmod(0o600)
        print('Session update evidence: ' + str(path), flush=True)


def main():
    if len(sys.argv) != 2:
        raise ValueError('One project Measurement baseline is required')
    trial = Trial(sys.argv[1])
    try:
        trial.execute()
    except (Exception, KeyboardInterrupt) as error:
        trial.result.update(success=False, errorType=type(error).__name__, manualInspectionRequired=True)
    finally:
        trial.finish()
    return 0 if trial.result['success'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as error:
        print('Session update rehearsal rejected (' + type(error).__name__ + ').')
        raise SystemExit(1) from None
