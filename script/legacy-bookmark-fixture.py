#!/usr/bin/env python3
"""Seed a fresh Debug SessionTests UUID; verify only generated bookmark records."""
import json
import os
import pathlib
import sqlite3
import stat
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
SESSION_ROOT = (pathlib.Path.home() / 'Library/Containers/dev.fomalhaut16.Levistica.debug'
                / 'Data/Library/Application Support/Levistica/SessionTests')
ROWS = [
    ('11111111-1111-4111-8111-111111111111', 'https://example.invalid/legacy-one', 'Legacy bookmark one', 100.0),
    ('22222222-2222-4222-8222-222222222222', 'https://example.invalid/legacy-two', 'Legacy bookmark two', 200.0),
]
RENAMED = 'Migrated bookmark renamed'


def unlinked(path):
    if '..' in path.parts:
        raise ValueError('Path traversal is not allowed')
    for candidate in (path, *path.parents):
        if candidate.is_symlink():
            raise ValueError('Linked fixture paths are not allowed')
    return path


def regular(path):
    unlinked(path)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 1024 * 1024:
        raise ValueError('Unexpected fixture file')
    return path


def write_new(path, value):
    unlinked(path)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def prepare(manifest):
    unlinked(SESSION_ROOT)
    # Require an existing Debug container; do not manufacture another app's container.
    if not SESSION_ROOT.parent.is_dir():
        raise ValueError('Run the Debug app once to create its Application Support folder')
    SESSION_ROOT.mkdir(mode=0o700, exist_ok=True)
    session_id = str(uuid.uuid4()).upper()
    folder = SESSION_ROOT / session_id
    folder.mkdir(mode=0o700)  # No exist_ok: never overwrite an earlier test or profile.
    marker = {'sessionID': session_id, 'kind': 'generated-legacy-bookmarks-v1'}
    write_new(folder / 'legacy-fixture.json', marker)
    database = folder / 'bookmarks.sqlite3'
    fd = os.open(database, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(fd)
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE bookmarks (id TEXT PRIMARY KEY NOT NULL, url TEXT UNIQUE NOT NULL, title TEXT NOT NULL, created REAL NOT NULL)')
        connection.executemany('INSERT INTO bookmarks VALUES (?,?,?,?)', ROWS)
        connection.execute('PRAGMA user_version=1')
    write_new(manifest, marker)
    return marker


def inspect_database(path, version):
    regular(path)
    with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as connection:
        if connection.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise ValueError('Fixture integrity check failed')
        if connection.execute('PRAGMA user_version').fetchone()[0] != version:
            raise ValueError('Unexpected bookmark schema version')
        rows = connection.execute('SELECT id,url,title,created FROM bookmarks ORDER BY id').fetchall()
        if version == 2 and connection.execute('SELECT DISTINCT folder_path FROM bookmarks').fetchall() != [('[]',)]:
            raise ValueError('Migration changed empty folder paths')
    return rows


def verify(manifest):
    marker = json.loads(regular(manifest).read_text())
    session_id = marker.get('sessionID')
    if (str(uuid.UUID(session_id)).upper() != session_id or
            marker != {'sessionID': session_id, 'kind': 'generated-legacy-bookmarks-v1'}):
        raise ValueError('Invalid fixture manifest')
    folder = unlinked(SESSION_ROOT / session_id)
    if json.loads(regular(folder / 'legacy-fixture.json').read_text()) != marker:
        raise ValueError('Fixture ownership marker mismatch')
    expected = list(ROWS)
    expected[0] = (*expected[0][:2], RENAMED, expected[0][3])
    if inspect_database(folder / 'bookmarks.sqlite3', 2) != expected:
        raise ValueError('Migrated bookmarks or persisted rename do not match')
    backups = list(folder.glob('bookmarks-v1-*.sqlite3'))
    if len(backups) != 1 or inspect_database(backups[0], 1) != ROWS:
        raise ValueError('Expected one intact legacy backup across both launches')
    result = {'status': 'passed', 'sessionID': session_id, 'generatedRecords': 2,
              'currentSchema': 2, 'backupSchema': 1, 'backupCount': 1,
              'renamePersisted': True, 'normalDataUsed': False}
    write_new(manifest.with_name('legacy-bookmark-result.json'), result)
    return result


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('prepare', 'verify'):
        raise SystemExit('usage: legacy-bookmark-fixture.py prepare|verify MANIFEST')
    manifest = pathlib.Path(sys.argv[2]).absolute()
    unlinked(manifest)
    manifest.relative_to(ROOT / '.local/artifacts')
    result = prepare(manifest) if sys.argv[1] == 'prepare' else verify(manifest)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
