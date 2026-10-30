"""Exercise generated fixtures in temporary directories, never real app containers."""
import importlib.util
import json
import pathlib
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('legacy_bookmarks', pathlib.Path(__file__).resolve().parents[1] / 'legacy-bookmark-fixture.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class LegacyBookmarkFixtureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name).resolve()
        self.sessions = self.root / 'DebugSupport/Levistica/SessionTests'
        self.sessions.parent.mkdir(parents=True)
        patcher = patch.object(s, 'SESSION_ROOT', self.sessions)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.manifest = self.root / 'manifest.json'

    def prepare(self):
        marker = s.prepare(self.manifest)
        self.folder = self.sessions / marker['sessionID']
        return marker

    def migrate(self):
        database = self.folder / 'bookmarks.sqlite3'
        backup = self.folder / 'bookmarks-v1-generated.sqlite3'
        with sqlite3.connect(database) as connection, sqlite3.connect(backup) as destination:
            connection.backup(destination)
            connection.execute("ALTER TABLE bookmarks ADD COLUMN folder_path TEXT NOT NULL DEFAULT '[]'")
            connection.execute('PRAGMA user_version=2')
            connection.execute('UPDATE bookmarks SET title=? WHERE id=?', (s.RENAMED, s.ROWS[0][0]))

    def test_fresh_legacy_records_and_private_permissions(self):
        self.prepare()
        self.assertEqual(s.inspect_database(self.folder / 'bookmarks.sqlite3', 1), s.ROWS)
        self.assertEqual(self.folder.stat().st_mode & 0o777, 0o700)
        for path in [self.manifest, self.folder / 'bookmarks.sqlite3', self.folder / 'legacy-fixture.json']:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_generated_migration_and_backup_are_both_verified(self):
        self.prepare(); self.migrate()
        result = s.verify(self.manifest)
        self.assertTrue(result['renamePersisted'])
        self.assertFalse(result['normalDataUsed'])

    def test_unmigrated_or_unedited_records_cannot_pass(self):
        self.prepare()
        with self.assertRaises(ValueError):
            s.verify(self.manifest)
        self.migrate()
        with sqlite3.connect(self.folder / 'bookmarks.sqlite3') as connection:
            connection.execute('UPDATE bookmarks SET title=? WHERE id=?', (s.ROWS[0][2], s.ROWS[0][0]))
        with self.assertRaises(ValueError):
            s.verify(self.manifest)

    def test_modified_or_multiple_backups_cannot_pass(self):
        self.prepare(); self.migrate()
        backup = self.folder / 'bookmarks-v1-generated.sqlite3'
        with sqlite3.connect(backup) as connection:
            connection.execute('DELETE FROM bookmarks')
        with self.assertRaises(ValueError):
            s.verify(self.manifest)

    def test_duplicate_backup_cannot_pass(self):
        self.prepare(); self.migrate()
        (self.folder / 'bookmarks-v1-extra.sqlite3').write_bytes((self.folder / 'bookmarks-v1-generated.sqlite3').read_bytes())
        with self.assertRaises(ValueError):
            s.verify(self.manifest)

    def test_foreign_or_non_uuid_marker_is_rejected(self):
        marker = self.prepare(); self.migrate()
        for value in [{'sessionID': '../../foreign', 'kind': marker['kind']}, {**marker, 'kind': 'other'}]:
            self.manifest.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                s.verify(self.manifest)
        self.manifest.write_text(json.dumps(marker))
        (self.folder / 'legacy-fixture.json').write_text('{}')
        with self.assertRaises(ValueError):
            s.verify(self.manifest)

    def test_symlinked_database_marker_and_parent_are_rejected(self):
        self.prepare(); self.migrate()
        for name in ['bookmarks.sqlite3', 'legacy-fixture.json']:
            path = self.folder / name
            target = self.root / name
            path.rename(target)
            path.symlink_to(target)
            with self.subTest(name=name), self.assertRaises(ValueError):
                s.verify(self.manifest)
            path.unlink(); target.rename(path)
        linked = self.root / 'linked'
        linked.symlink_to(self.sessions)
        with patch.object(s, 'SESSION_ROOT', linked), self.assertRaises(ValueError):
            s.prepare(self.root / 'other.json')

    def test_collision_never_overwrites_existing_fixture(self):
        marker = self.prepare()
        database = self.folder / 'bookmarks.sqlite3'
        before = database.read_bytes()
        with patch.object(s.uuid, 'uuid4', return_value=marker['sessionID']), self.assertRaises(FileExistsError):
            s.prepare(self.root / 'other.json')
        self.assertEqual(database.read_bytes(), before)

    def test_path_traversal_is_rejected_before_read_or_write(self):
        with self.assertRaises(ValueError):
            s.prepare(self.root / 'child/../manifest.json')
        self.assertFalse(self.manifest.exists())

    def test_missing_debug_support_never_creates_container(self):
        with patch.object(s, 'SESSION_ROOT', self.root / 'missing/SessionTests'), self.assertRaises(ValueError):
            s.prepare(self.manifest)
        self.assertFalse((self.root / 'missing').exists())


if __name__ == '__main__':
    unittest.main()
