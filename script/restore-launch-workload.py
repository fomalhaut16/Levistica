#!/usr/bin/env python3
"""Prepare and verify fresh UUID-owned saved sessions for isolated Measurement launch trials."""
import argparse
from contextlib import closing
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'dev.fomalhaut16.Levistica.measurement'


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'script' / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


stores = module('restore_launch_stores', 'measurement-store.py')
launch = module('restore_launch_bundle', 'release-launch-workload.py')


def unlinked(path):
    path = Path(path).absolute()
    if path.resolve() != path:
        raise ValueError('Symbolic links are not accepted')
    return path


def run_file(path, name):
    path = unlinked(path)
    if (path.name != name or path.parent.parent != ROOT / '.local/artifacts'
            or not path.parent.name.startswith('tests.')):
        raise ValueError('Expected a project-owned test artifact')
    return path


def read_server(path):
    value = json.loads(run_file(path, 'restore-fixture-server.json').read_text())
    parts = urlsplit(value['url'])
    if (value.get('kind') != 'RestoreLaunchLoopbackV1' or parts.scheme != 'http'
            or parts.hostname != '127.0.0.1' or parts.username or parts.password
            or parts.path or parts.query or parts.fragment or not parts.port):
        raise ValueError('Only the fixed loopback fixture is accepted')
    return value


def write_new(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
    path.chmod(0o600)


def namespace(home=None):
    home = Path.home() if home is None else Path(home)
    # This is the same fixed Measurement-only namespace used by session-update rehearsals.
    # Never inspect the OS-managed container metadata or accept a caller-supplied destination.
    container = unlinked(home / 'Library/Containers' / BUNDLE)
    folder = unlinked(container / 'Data/Library/Application Support/LevisticaMeasurementProfiles')
    if not folder.is_dir():
        raise ValueError('Measurement metadata namespace is unavailable; bootstrap separately first')
    return folder


def verify_session(database, expected):
    database = unlinked(database)
    with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=1)) as connection:
        connection.execute('PRAGMA query_only=ON')
        version = connection.execute('PRAGMA user_version').fetchone()[0]
        rows = connection.execute('SELECT id,title,url,may_reload,kind,is_kept,is_sleeping FROM session_tabs ORDER BY position').fetchall()
        meta = connection.execute('SELECT selected_id,was_running FROM session_meta WHERE id=1').fetchall()
    wanted = [(x['id'], x['title'], x['url'], 1, 'web', 0, 0) for x in expected['tabs']]
    if version != 3 or rows != wanted or meta != [(expected['selectedID'], 0)]:
        raise ValueError('Restored session order, selection, contents or clean-exit state differs')
    return {'tabCount': len(rows), 'schema': version, 'orderAndSelectionVerified': True, 'cleanExitVerified': True}


def assert_no_apps():
    snapshot = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True, timeout=10)
    if any(line.strip().endswith('/Levistica.app/Contents/MacOS/Levistica') for line in snapshot.splitlines()):
        raise ValueError('All Levistica processes must be closed; no process was stopped')


def prepare(path, count):
    if type(count) is not int or count not in (50, 100):
        raise ValueError('Only 50 or 100 saved tabs are accepted')
    path = run_file(path, 'release-launch-workload.json')
    value = json.loads(path.read_text())
    if value.get('kind') != 'IsolatedReleaseBlankLaunchV1' or value.get('variant') != 'Measurement':
        raise ValueError('A freshly verified Measurement bundle manifest is required')
    assert_no_apps()
    server = read_server(path.parent / 'restore-fixture-server.json')
    destination_root = namespace()
    identifier = stores.allocate()
    stores.owned(identifier)
    destination = unlinked(destination_root / identifier)
    if destination.exists() or destination.is_symlink():
        raise ValueError('Owned metadata directory must be new; nothing was replaced')
    generated = path.parent / 'restore-fixture-session'
    generated.mkdir(mode=0o700)
    executable = path.parent / 'seed-restore-session'
    with (path.parent / 'seed-restore-build.log').open('x') as log:
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
            '-strict-concurrency=complete', '-O', '-whole-module-optimization',
            '-module-cache-path', str(ROOT / '.local/ModuleCache'),
            str(ROOT / 'Levistica/Stores/SessionStore.swift'), str(ROOT / 'script/restore-session-fixture.swift'),
            '-o', str(executable)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    prepared = subprocess.run([str(executable), str(generated / 'session.sqlite3'), str(count), server['url']],
                              check=True, capture_output=True, text=True, timeout=10)
    expected = json.loads(prepared.stdout)
    verify_session(generated / 'session.sqlite3', expected)
    # The new owned UUID is installed once. Never replace an existing metadata directory.
    destination.mkdir(mode=0o700)
    for entry in generated.iterdir():
        if not entry.is_file() or entry.is_symlink() or entry.name != 'session.sqlite3':
            raise ValueError('Unexpected generated session file')
        with entry.open('rb') as source, (destination / entry.name).open('xb') as target:
            shutil.copyfileobj(source, target)
        (destination / entry.name).chmod(0o600)
    verify_session(destination / 'session.sqlite3', expected)
    value.update(kind='IsolatedReleaseSavedLaunchV1', restoreTabs=count, storeID=identifier,
                 sessionFolder=str(destination), expectedSession=expected,
                 storeSHA256=hashlib.sha256((ROOT / 'Levistica/Stores/SessionStore.swift').read_bytes()).hexdigest())
    temporary = path.with_suffix('.prepared')
    write_new(temporary, value)
    os.replace(temporary, path)
    print('Prepared a new Measurement-only saved session; no app launched.')


def verify(path):
    path = run_file(path, 'release-launch-workload.json')
    value = json.loads(path.read_text())
    if value.get('kind') != 'IsolatedReleaseSavedLaunchV1' or value.get('variant') != 'Measurement':
        raise ValueError('Only a saved Measurement workload can be verified')
    identifier = stores.identifier(value['storeID'])
    stores.owned(identifier)
    assert_no_apps()
    folder = unlinked(value['sessionFolder'])
    if folder != namespace() / identifier:
        raise ValueError('Saved session is outside its owned UUID')
    proof = verify_session(folder / 'session.sqlite3', value['expectedSession'])
    server = read_server(path.parent / 'restore-fixture-server.json')
    selected = value['expectedSession']['selectedIndex'] + 1
    counts = server.get('requests', {})
    if set(counts) != {str(selected)} or type(counts[str(selected)]) is not int or counts[str(selected)] < 1:
        raise ValueError('Only the selected restored page may load')
    write_new(path.parent / 'restore-launch-proof.json', dict(proof, selectedPageOnlyRequested=True,
              restoredTabs=value['restoreTabs'], normalDataUsed=False, ramSamples=0, productAccepted=False))


def serve(path):
    path = run_file(path, 'restore-fixture-server.json')
    if path.exists():
        raise ValueError('Server state must be new')
    state = {'kind': 'RestoreLaunchLoopbackV1', 'requests': {}}
    def save():
        temporary = path.with_suffix('.tmp')
        write_new(temporary, state)
        os.replace(temporary, path)
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            match = re.fullmatch(r'/restore-([1-9][0-9]?|100)', self.path)
            if not match:
                self.send_error(404)
                return
            number = int(match[1])
            state['requests'][str(number)] = state['requests'].get(str(number), 0) + 1
            save()
            title = f'Restore fixture {number:03d}'
            body = f'<!doctype html><meta charset="utf-8"><title>{title}</title><h1>{title}</h1>'.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)
    with http.server.HTTPServer(('127.0.0.1', 0), Handler) as server:
        server.timeout = .5
        state['url'] = 'http://127.0.0.1:' + str(server.server_port)
        save()
        end = time.monotonic() + 240
        while time.monotonic() < end:
            server.handle_request()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'verify', 'serve'])
    parser.add_argument('path', type=Path)
    parser.add_argument('--tabs', type=int, choices=[50, 100])
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.path, args.tabs)
    elif args.action == 'verify':
        verify(args.path)
    else:
        serve(args.path)
