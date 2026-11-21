#!/usr/bin/env python3
"""Milestone 3 real-home hygiene manifest & diff helper (Python stdlib only).

Records a manifest of `(path, size, mtime_ns, sha256)` before and after Milestone 3 runs across:
  - `~/Library/{Caches,Preferences,Application Support}` entries matching `scholaros` (case-insensitive)
  - `~/.claude*`, `~/.codex`, `~/.config/opencode` (excluding live agent session/daemon runtime state)

Subcommands:
  python3 -I Scripts/acceptance/m3_home_hygiene.py snapshot <home_dir> <manifest_json> [--scope all|library|clients]
  python3 -I Scripts/acceptance/m3_home_hygiene.py diff <home_dir> <before_json> <after_json> [--max-items 30]
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import stat
import sys
from typing import Any

MAX_HASH_FILE_BYTES = 8 * 1024 * 1024
DEFAULT_MAX_DIFF_ITEMS = 30

VOLATILE_SUBDIRS: dict[str, set[str]] = {
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
        # Claude Code 每个运行中的会话都会写 sessions/<pid>.json
        "sessions",
    },
    ".codex": {"sessions", "archived_sessions", "log", "logs", "tmp", "shell_snapshots", "sqlite"},
}
VOLATILE_FILENAMES: set[str] = {"history.jsonl", ".claude.json.lock"}
VOLATILE_SUFFIXES: tuple[str, ...] = (".sqlite", ".sqlite-wal", ".sqlite-shm", ".lock")


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _build_entry(path: str, st: os.stat_result) -> dict[str, Any]:
    mode = st.st_mode
    if stat.S_ISDIR(mode):
        # Directory mtime changes when ignored volatile children (e.g. .sqlite-shm or session files)
        # are created/removed inside it; track directory existence without directory mtime.
        return {
            "path": path,
            "kind": "dir",
            "size": None,
            "mtime_ns": None,
            "mode": None,
            "sha256": None,
        }
    if stat.S_ISLNK(mode):
        try:
            target = os.readlink(path)
            digest = "symlink:" + hashlib.sha256(target.encode("utf-8", errors="surrogateescape")).hexdigest()
        except OSError:
            digest = "UNREADABLE"
        return {
            "path": path,
            "kind": "symlink",
            "size": st.st_size,
            "mtime_ns": st.st_mtime_ns,
            "mode": mode,
            "sha256": digest,
        }
    if stat.S_ISREG(mode):
        if st.st_size <= MAX_HASH_FILE_BYTES:
            try:
                digest = _sha256_file(path)
            except OSError:
                digest = "UNREADABLE"
        else:
            digest = "SKIPPED_LARGE"
        return {
            "path": path,
            "kind": "file",
            "size": st.st_size,
            "mtime_ns": st.st_mtime_ns,
            "mode": mode,
            "sha256": digest,
        }
    return {
        "path": path,
        "kind": "other",
        "size": st.st_size,
        "mtime_ns": st.st_mtime_ns,
        "mode": mode,
        "sha256": None,
    }


def _stat_or_err_entry(path: str) -> dict[str, Any] | None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError:
        return {
            "path": path,
            "kind": "err",
            "size": None,
            "mtime_ns": None,
            "mode": None,
            "sha256": "ERR",
        }
    return _build_entry(path, st)


def _collect_library_scholaros(home: str, entries: list[dict[str, Any]]) -> None:
    for sub in ("Caches", "Preferences", "Application Support"):
        base = os.path.join(home, "Library", sub)
        if not os.path.isdir(base):
            continue
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        for name in names:
            if "scholaros" not in name.lower():
                continue
            p = os.path.join(base, name)
            top_entry = _stat_or_err_entry(p)
            if top_entry is None:
                continue
            entries.append(top_entry)
            if top_entry["kind"] == "dir":
                for root, dirs, files in os.walk(p):
                    kept_dirs: list[str] = []
                    for d in sorted(dirs):
                        dp = os.path.join(root, d)
                        de = _stat_or_err_entry(dp)
                        if de is None:
                            continue
                        entries.append(de)
                        if de["kind"] == "dir":
                            kept_dirs.append(d)
                    dirs[:] = kept_dirs
                    for fn in sorted(files):
                        fp = os.path.join(root, fn)
                        fe = _stat_or_err_entry(fp)
                        if fe is not None:
                            entries.append(fe)


def _is_volatile_top_target(base_name: str) -> bool:
    return (
        base_name in VOLATILE_FILENAMES
        or base_name.startswith(".claude.json.backup")
        or base_name.startswith(".claude.json.tmp")
    )


def _is_volatile_filename(filename: str) -> bool:
    return filename in VOLATILE_FILENAMES or filename.endswith(VOLATILE_SUFFIXES)


def _collect_client_configs(home: str, entries: list[dict[str, Any]]) -> None:
    targets = sorted(set(glob.glob(os.path.join(home, ".claude*")))) + [
        os.path.join(home, ".codex"),
        os.path.join(home, ".config", "opencode"),
    ]
    seen_targets: set[str] = set()
    for t in targets:
        norm_t = os.path.normpath(t)
        if norm_t in seen_targets:
            continue
        seen_targets.add(norm_t)
        rel_t = os.path.relpath(norm_t, home)
        base_t = os.path.basename(norm_t)
        if _is_volatile_top_target(base_t):
            continue
        if not os.path.lexists(norm_t):
            continue
        top_entry = _stat_or_err_entry(norm_t)
        if top_entry is None:
            continue
        entries.append(top_entry)
        if top_entry["kind"] == "dir":
            skip_top = VOLATILE_SUBDIRS.get(rel_t, set())
            for root, dirs, files in os.walk(norm_t):
                rel_r = os.path.relpath(root, home)
                candidates = [d for d in sorted(dirs) if not (rel_r == rel_t and d in skip_top)]
                kept_dirs: list[str] = []
                for d in candidates:
                    dp = os.path.join(root, d)
                    de = _stat_or_err_entry(dp)
                    if de is None:
                        continue
                    entries.append(de)
                    if de["kind"] == "dir":
                        kept_dirs.append(d)
                dirs[:] = kept_dirs
                for fn in sorted(files):
                    if _is_volatile_filename(fn):
                        continue
                    fp = os.path.join(root, fn)
                    fe = _stat_or_err_entry(fp)
                    if fe is not None:
                        entries.append(fe)


def format_home_path(path_str: str, home_dir: str) -> str:
    prefixes: list[str] = []
    for candidate in (home_dir, os.path.abspath(home_dir), os.path.realpath(home_dir)):
        norm = candidate.rstrip(os.sep)
        if norm and norm not in prefixes:
            prefixes.append(norm)
    for prefix in prefixes:
        if path_str == prefix:
            return "~"
        if path_str.startswith(prefix + os.sep):
            rel = path_str[len(prefix) + 1 :].replace(os.sep, "/")
            return f"~/{rel}"
    return path_str


def collect_manifest(home_dir: str, scope: str = "all") -> dict[str, Any]:
    if scope not in ("all", "library", "clients"):
        raise ValueError(f"Unsupported scope: {scope!r}")
    home = os.path.abspath(home_dir)
    entries: list[dict[str, Any]] = []
    if scope in ("all", "library"):
        _collect_library_scholaros(home, entries)
    if scope in ("all", "clients"):
        _collect_client_configs(home, entries)
    entries.sort(key=lambda item: item["path"])
    return {
        "schema": "scholaros.m3_home_hygiene/1",
        "home": home,
        "scope": scope,
        "entries": entries,
    }


def write_manifest(home_dir: str, manifest_path: str, scope: str = "all") -> dict[str, Any]:
    manifest = collect_manifest(home_dir, scope=scope)
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    return manifest


def load_manifest(manifest_path: str) -> dict[str, Any]:
    with open(manifest_path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _entry_signature(entry: dict[str, Any]) -> tuple[Any, ...]:
    return (
        entry.get("kind"),
        entry.get("size"),
        entry.get("mtime_ns"),
        entry.get("mode"),
        entry.get("sha256"),
    )


def diff_manifests(
    before: dict[str, Any],
    after: dict[str, Any],
    home_dir: str | None = None,
    max_items: int = DEFAULT_MAX_DIFF_ITEMS,
) -> dict[str, Any]:
    before_home = home_dir or before.get("home") or ""
    after_home = home_dir or after.get("home") or before_home

    before_map = {format_home_path(e["path"], before_home): e for e in before.get("entries", [])}
    after_map = {format_home_path(e["path"], after_home): e for e in after.get("entries", [])}

    added = sorted(p for p in after_map if p not in before_map)
    removed = sorted(p for p in before_map if p not in after_map)
    modified = sorted(
        p for p in before_map if p in after_map and _entry_signature(before_map[p]) != _entry_signature(after_map[p])
    )

    changes: list[tuple[str, str]] = (
        [("added", p) for p in added]
        + [("removed", p) for p in removed]
        + [("modified", p) for p in modified]
    )
    shown = changes[:max_items]
    lines = [f"  {kind}: {path}" for kind, path in shown]
    if len(changes) > max_items:
        lines.append(f"  ... ({len(changes) - max_items} more changed paths omitted; total={len(changes)})")

    return {
        "changed": bool(changes),
        "added": added,
        "removed": removed,
        "modified": modified,
        "total_changes": len(changes),
        "lines": lines,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Milestone 3 real-home hygiene manifest & diff helper.")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    p_snap = subparsers.add_parser("snapshot", help="Record a home hygiene manifest JSON file.")
    p_snap.add_argument("home_dir", help="Home directory to scan.")
    p_snap.add_argument("manifest_json", help="Output manifest JSON path.")
    p_snap.add_argument("--scope", choices=("all", "library", "clients"), default="all")

    p_diff = subparsers.add_parser("diff", help="Compare two home hygiene manifest JSON files.")
    p_diff.add_argument("home_dir", help="Home directory whose prefix is replaced with ~.")
    p_diff.add_argument("before_json", help="Before-run manifest JSON path.")
    p_diff.add_argument("after_json", help="After-run manifest JSON path.")
    p_diff.add_argument("--max-items", type=int, default=DEFAULT_MAX_DIFF_ITEMS)

    args = parser.parse_args(argv)
    if args.subcommand == "snapshot":
        write_manifest(args.home_dir, args.manifest_json, scope=args.scope)
        return 0

    before = load_manifest(args.before_json)
    after = load_manifest(args.after_json)
    result = diff_manifests(before, after, home_dir=args.home_dir, max_items=args.max_items)
    if not result["changed"]:
        return 0
    for line in result["lines"]:
        print(line)
    return 1


if __name__ == "__main__":
    sys.exit(main())
