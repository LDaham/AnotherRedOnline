#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Patch base-game CommonEvents.rxdata for "Another Red Online".

Currently a single fix: the "공중날기 택시" contact (common event #3) shows the
message

    도착하고 나서는 B버튼(X)를 연타해서 화면으로 나가줘!

before every region transfer, because the vanilla taxi left the Pokégear/pause
menus open on top of the frozen graphics (the player had to blindly mash B to
unwind to the map). Plugin [024] TaxiPhoneFix now auto-closes those menus, so the
transfer happens by itself — the "mash B" instruction is not only unnecessary but
actively wrong. This tool deletes those Show Text (code 101) commands.

Each such message is a STANDALONE single-line 101 (there are no 401 continuation
lines and the taxi CE uses no labels/jumps), so removing it is safe: the
interpreter walks the list sequentially and matches conditional blocks by indent,
not by absolute index. Removal is idempotent — running twice is a no-op.

Like patch_maps.py this edits the base rxdata IN PLACE inside the tmp game folder
so build_release.py can ship the patched Data/CommonEvents.rxdata in the zip.
CommonEvents.rxdata is base-game data (never committed); we only patch a copy at
build time.

Usage:
    PYTHONIOENCODING=utf-8 python tools/patch_common_events.py <Data dir> [--write]
    # no args -> operate on the baked test-game Data dir, dry-run unless --write
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rgss_marshal as rm

ROOT = os.path.dirname(HERE)
DEFAULT_DATA = os.path.join(ROOT, "tmp", "Pokemon Another Red 테스트 버전", "Data")

# The exact taxi "mash B to exit" instruction to strip (see module docstring).
BUTTON_MASH_TEXT = "도착하고 나서는 B버튼(X)를 연타해서 화면으로 나가줘!"


def common_events_path(data_dir):
    return os.path.join(data_dir, "CommonEvents.rxdata")


def _is_button_mash(cmd):
    if cmd.get("@code") != 101:
        return False
    params = cmd.get("@parameters") or []
    return (params
            and isinstance(params[0], rm.RString)
            and params[0].str() == BUTTON_MASH_TEXT)


def strip_button_mash(data):
    """Remove the taxi button-mash messages from every common event in `data`.
    Returns the number of commands removed (0 => already clean)."""
    removed = 0
    for ce in data:
        if ce is None:
            continue
        lst = ce.get("@list")
        if not lst:
            continue
        kept = [c for c in lst if not _is_button_mash(c)]
        if len(kept) != len(lst):
            removed += len(lst) - len(kept)
            ce.set("@list", kept)
    return removed


def apply(data_dir, write=False):
    """Load CommonEvents.rxdata from `data_dir`, strip the messages, and (if
    write) save it back in place. Returns the number of commands removed."""
    path = common_events_path(data_dir)
    data = rm.load_file(path)
    removed = strip_button_mash(data)
    if write and removed:
        rm.dump_file(path, data)
    return removed


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    write = "--write" in sys.argv
    data_dir = args[0] if args else DEFAULT_DATA
    path = common_events_path(data_dir)
    if not os.path.exists(path):
        raise SystemExit("CommonEvents.rxdata not found: %s" % path)
    removed = apply(data_dir, write=write)
    verb = "removed" if write else "would remove"
    print("%s %d taxi 'mash B' message(s) in %s" % (verb, removed, path))
    if not write and removed:
        print("(dry run — pass --write to apply)")


if __name__ == "__main__":
    main()
