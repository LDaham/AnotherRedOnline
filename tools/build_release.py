#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build a GitHub Release zip for "Another Red Online".

The zip is a drop-in OVERLAY: the player extracts it over their Another Red game
folder (the one containing Game.exe) and the mod is applied — no launcher, no
Python, no recompile, no network. It contains:

  Data/PluginScripts.rxdata   the fully-baked scripts (29 base-game plugins with
                              our online plugin appended as the 30th)
  Audio/BGM/*.ogg  (etc.)     our added assets, at their game-root-relative paths

Because PluginScripts.rxdata is shipped WHOLE, extracting simply replaces the
file with base+ours. That is correct whether the player has a clean game or an
older version of this mod already installed (no double-append, no stale base) —
as long as their base game is the same build we baked against (PWT_250821).

Usage:
    python tools/build_release.py            # re-bake, then zip (recommended)
    python tools/build_release.py --no-bake  # zip whatever is already baked

The zip lands in dist/ as AnotherRedOnline_v<meta Version>.zip. Bump the Version
in plugin/AnotherRedOnline/meta.txt AND the MOD_VERSION in "[001] ..." before a
release: peers reject each other on a version mismatch (prevents lockstep desync),
so the number in the zip name and in the handshake must move together.
"""
import os
import sys
import subprocess
import zipfile

HERE   = os.path.dirname(os.path.abspath(__file__))
ROOT   = os.path.dirname(HERE)
GAME   = os.path.join(ROOT, "tmp", "Pokemon Another Red_PWT_250821")
RXDATA = os.path.join(GAME, "Data", "PluginScripts.rxdata")
ASSETS = os.path.join(ROOT, "plugin", "AnotherRedOnline", "assets")
META   = os.path.join(ROOT, "plugin", "AnotherRedOnline", "meta.txt")
OUTDIR = os.path.join(ROOT, "dist")


def read_version():
    for line in open(META, encoding="utf-8"):
        if line.strip().lower().startswith("version"):
            return line.split("=", 1)[1].strip()
    raise SystemExit("Version not found in meta.txt")


def bake():
    """Restore the pristine 29-plugin base, then append our plugin, so the
    rxdata we zip is guaranteed to be exactly base+ours (never a double-append)."""
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    baker = os.path.join(HERE, "plugin_baker.py")
    for cmd in ("restore", "bake"):
        subprocess.run([sys.executable, baker, cmd], check=True, env=env)


def main():
    if "--no-bake" not in sys.argv:
        bake()

    if not os.path.exists(RXDATA):
        raise SystemExit("baked rxdata missing: %s" % RXDATA)

    ver = read_version()
    os.makedirs(OUTDIR, exist_ok=True)
    zpath = os.path.join(OUTDIR, "AnotherRedOnline_v%s.zip" % ver)

    entries = []
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        # 1) baked scripts -> Data/PluginScripts.rxdata
        z.write(RXDATA, "Data/PluginScripts.rxdata")
        entries.append("Data/PluginScripts.rxdata")
        # 2) assets: mirror plugin/.../assets/** onto the game root (strip
        #    the leading "assets/" so Audio/BGM/foo.ogg lands at Audio/BGM/foo.ogg)
        for dirpath, _dirs, files in os.walk(ASSETS):
            for f in files:
                full = os.path.join(dirpath, f)
                rel = os.path.relpath(full, ASSETS).replace(os.sep, "/")
                z.write(full, rel)
                entries.append(rel)

    print("built %s (%d bytes)" % (zpath, os.path.getsize(zpath)))
    for n in entries:
        print("   ", n)
    print("\nRelease it as a zip asset. Players extract it over their Another")
    print("Red folder (the one with Game.exe), choosing 'replace/merge'.")


if __name__ == "__main__":
    main()
