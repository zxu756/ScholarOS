#!/usr/bin/env python3
"""Unit tests for Scripts/acceptance/m3_home_hygiene.py (Python stdlib only)."""

from __future__ import annotations

import io
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import m3_home_hygiene as m3hh  # noqa: E402


def _seed_fake_home(home: pathlib.Path) -> None:
    (home / ".claude" / "sessions").mkdir(parents=True, exist_ok=True)
    (home / ".claude" / "projects" / "demo").mkdir(parents=True, exist_ok=True)
    (home / ".claude" / "settings.json").write_text('{"theme":"dark"}\n', encoding="utf-8")
    (home / ".claude" / "sessions" / "1.json").write_text('{"pid":1,"state":"running"}\n', encoding="utf-8")
    (home / ".claude" / "projects" / "demo" / "turn.jsonl").write_text('{"ok":true}\n', encoding="utf-8")
    (home / ".codex").mkdir(parents=True, exist_ok=True)
    (home / ".codex" / "config.toml").write_text('model = "gpt-5"\n', encoding="utf-8")
    (home / ".codex" / "state_5.sqlite-shm").write_bytes(b"\x00\x01")
    (home / ".config" / "opencode").mkdir(parents=True, exist_ok=True)
    (home / ".config" / "opencode" / "opencode.json").write_text("{}\n", encoding="utf-8")
    (home / "Library" / "Caches").mkdir(parents=True, exist_ok=True)
    (home / "Library" / "Preferences").mkdir(parents=True, exist_ok=True)
    (home / "Library" / "Application Support").mkdir(parents=True, exist_ok=True)


class M3HomeHygieneUnitTests(unittest.TestCase):
    def test_volatile_exclusions_only_add_claude_sessions(self) -> None:
        self.assertEqual(
            m3hh.VOLATILE_SUBDIRS,
            {
                ".claude": {
                    "projects",
                    "todos",
                    "statsig",
                    "debug",
                    "shell-snapshots",
                    "session-env",
                    "ide",
                    "telemetry",
                    "file-history",
                    "logs",
                    "cache",
                    "backups",
                    "sessions",
                },
                ".codex": {"sessions", "archived_sessions", "log", "logs", "tmp", "shell_snapshots", "sqlite"},
            },
        )
        self.assertEqual(m3hh.VOLATILE_FILENAMES, {"history.jsonl", ".claude.json.lock"})
        self.assertEqual(m3hh.VOLATILE_SUFFIXES, (".sqlite", ".sqlite-wal", ".sqlite-shm", ".lock"))

    def test_a_modifying_claude_sessions_file_reports_no_change(self) -> None:
        with tempfile.TemporaryDirectory() as fake_home_str, tempfile.TemporaryDirectory() as snap_dir_str:
            home = pathlib.Path(fake_home_str)
            snap_dir = pathlib.Path(snap_dir_str)
            _seed_fake_home(home)

            before_json = snap_dir / "before.json"
            after_json = snap_dir / "after.json"
            self.assertEqual(m3hh.main(["snapshot", str(home), str(before_json)]), 0)

            # Only touch .claude/sessions/1.json (and volatile .claude/projects + .codex/*.sqlite-shm)
            (home / ".claude" / "sessions" / "1.json").write_text(
                '{"pid":1,"state":"updated","turn":2}\n', encoding="utf-8"
            )
            (home / ".claude" / "projects" / "demo" / "turn.jsonl").write_text(
                '{"ok":true}\n{"ok":true}\n', encoding="utf-8"
            )
            (home / ".codex" / "state_5.sqlite-shm").write_bytes(b"\x00\x01\x02\x03")

            self.assertEqual(m3hh.main(["snapshot", str(home), str(after_json)]), 0)

            out_buf = io.StringIO()
            with redirect_stdout(out_buf):
                rc = m3hh.main(["diff", str(home), str(before_json), str(after_json)])
            self.assertEqual(rc, 0, f"Expected no change, but diff reported:\n{out_buf.getvalue()}")
            self.assertEqual(out_buf.getvalue(), "")

    def test_b_modifying_claude_settings_json_reports_change_and_tilde_path(self) -> None:
        with tempfile.TemporaryDirectory() as fake_home_str, tempfile.TemporaryDirectory() as snap_dir_str:
            home = pathlib.Path(fake_home_str)
            snap_dir = pathlib.Path(snap_dir_str)
            _seed_fake_home(home)

            before_json = snap_dir / "before.json"
            after_json = snap_dir / "after.json"
            m3hh.main(["snapshot", str(home), str(before_json)])

            (home / ".claude" / "settings.json").write_text('{"theme":"light","mcp":true}\n', encoding="utf-8")

            m3hh.main(["snapshot", str(home), str(after_json)])
            out_buf = io.StringIO()
            with redirect_stdout(out_buf):
                rc = m3hh.main(["diff", str(home), str(before_json), str(after_json)])
            output = out_buf.getvalue()
            self.assertEqual(rc, 1)
            self.assertIn("modified: ~/.claude/settings.json", output)
            self.assertNotIn(str(home), output)

    def test_c_creating_regular_file_in_codex_reports_change_and_tilde_path(self) -> None:
        with tempfile.TemporaryDirectory() as fake_home_str, tempfile.TemporaryDirectory() as snap_dir_str:
            home = pathlib.Path(fake_home_str)
            snap_dir = pathlib.Path(snap_dir_str)
            _seed_fake_home(home)

            before_json = snap_dir / "before.json"
            after_json = snap_dir / "after.json"
            m3hh.main(["snapshot", str(home), str(before_json)])

            (home / ".codex" / "extra_note.txt").write_text("unexpected write\n", encoding="utf-8")

            m3hh.main(["snapshot", str(home), str(after_json)])
            out_buf = io.StringIO()
            with redirect_stdout(out_buf):
                rc = m3hh.main(["diff", str(home), str(before_json), str(after_json)])
            output = out_buf.getvalue()
            self.assertEqual(rc, 1)
            self.assertIn("added: ~/.codex/extra_note.txt", output)
            self.assertNotIn(str(home), output)

    def test_removed_file_library_scholaros_and_30_item_cap(self) -> None:
        with tempfile.TemporaryDirectory() as fake_home_str, tempfile.TemporaryDirectory() as snap_dir_str:
            home = pathlib.Path(fake_home_str)
            snap_dir = pathlib.Path(snap_dir_str)
            _seed_fake_home(home)

            before_json = snap_dir / "before.json"
            after_json = snap_dir / "after.json"
            m3hh.main(["snapshot", str(home), str(before_json)])

            # Remove an existing client config file and add a ScholarOS cache file + 34 files (total > 30)
            (home / ".config" / "opencode" / "opencode.json").unlink()
            (home / "Library" / "Caches" / "ScholarOS").mkdir(parents=True, exist_ok=True)
            for idx in range(34):
                (home / ".config" / "opencode" / f"extra_{idx:02d}.json").write_text("{}\n", encoding="utf-8")

            m3hh.main(["snapshot", str(home), str(after_json)])
            res = m3hh.diff_manifests(
                m3hh.load_manifest(str(before_json)),
                m3hh.load_manifest(str(after_json)),
                home_dir=str(home),
                max_items=30,
            )
            self.assertTrue(res["changed"])
            self.assertIn("~/.config/opencode/opencode.json", res["removed"])
            self.assertIn("~/Library/Caches/ScholarOS", res["added"])
            self.assertEqual(res["total_changes"], 36)
            tilde_lines = [ln for ln in res["lines"] if "~/" in ln]
            self.assertEqual(len(tilde_lines), 30)
            self.assertTrue(res["lines"][-1].strip().startswith("..."))


if __name__ == "__main__":
    unittest.main()
