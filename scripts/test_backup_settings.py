#!/usr/bin/env python3
"""Tests for backup_settings.py. Run: python3 -m unittest discover -s scripts -p 'test_*.py'"""
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

os.environ["BACKUP_DIR"] = tempfile.mkdtemp()  # read when the script is imported
sys.path.insert(0, str(Path(__file__).parent))
import backup_settings  # noqa: E402

BACKUP = {"BackupTime": 1, "GameSettings": [{"Id": 1, "Name": "My server"}], "Motds": []}


class BackupTest(unittest.TestCase):

    def setUp(self):
        self.enterContext(mock.patch("backup_settings.log"))  # keeps the test output short
        for old_file in backup_settings.BACKUP_DIR.glob("*"):
            old_file.unlink()

    def files(self):
        return sorted(path.name for path in backup_settings.BACKUP_DIR.glob("servers-*.json"))

    def test_backup_is_saved_and_private(self):
        backup_settings.save(BACKUP)
        [name] = self.files()
        path = backup_settings.BACKUP_DIR / name
        self.assertEqual(json.loads(path.read_text()), BACKUP)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)  # contains the join passwords

    def test_nothing_is_saved_without_servers(self):
        backup_settings.save({"BackupTime": 1, "GameSettings": []})
        self.assertEqual(self.files(), [])

    def test_nothing_is_saved_when_only_the_time_changed(self):
        backup_settings.save(BACKUP)
        backup_settings.save(BACKUP | {"BackupTime": 2})
        self.assertEqual(len(self.files()), 1)

    def test_only_the_newest_files_are_kept(self):
        for day in (1, 2, 3):
            (backup_settings.BACKUP_DIR / f"servers-2026-01-0{day}-000000.json").write_text("{}")
        with mock.patch("backup_settings.BACKUP_KEEP", 2):
            backup_settings.save(BACKUP)
        files = self.files()
        self.assertEqual(len(files), 2)
        self.assertEqual(files[0], "servers-2026-01-03-000000.json")

    def test_damaged_newest_file_does_not_stop_backups(self):
        (backup_settings.BACKUP_DIR / "servers-2026-01-01-000000.json").write_text("{half")
        backup_settings.save(BACKUP)
        self.assertEqual(len(self.files()), 2)


if __name__ == "__main__":
    unittest.main()
