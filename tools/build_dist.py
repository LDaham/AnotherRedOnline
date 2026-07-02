# -*- coding: utf-8 -*-
"""build_dist.py — produce the client UPDATE PAYLOAD under dist/ from the plugin
source, so the .bat/PowerShell launcher on each user's machine can pull the latest
mod straight from GitHub raw and apply it WITHOUT Python, without recompiling, and
without touching the base game's other plugins.

Output (all committed so raw.githubusercontent serves them):
  dist/element.bin      the marshaled plugin element (base-agnostic append target)
  dist/assets/**        bundled game assets (BGM, ...) mirrored from plugin assets/
  dist/manifest.json    { version, plugin, element{sha256}, assets[{path,sha256}] }

The launcher appends element.bin onto the user's pristine PluginScripts.rxdata
(exactly like plugin_baker's surgical append) and copies assets into the game dir.

Release flow:
  1. bump Version in plugin/AnotherRedOnline/meta.txt  (and MOD_VERSION in [001])
  2. python tools/build_dist.py
  3. commit dist/ + push   ->  every launcher picks it up on next game start
"""
import os, sys, json, hashlib, shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plugin_baker as pb

ROOT       = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST       = os.path.join(ROOT, "dist")
ASSETS_SRC = os.path.join(pb.SRC, "assets")


def read_meta_version():
    """Single source of truth = meta.txt 'Version = x.y.z' (fallback to baker META)."""
    ver = pb.META["version"]
    meta = os.path.join(pb.SRC, "meta.txt")
    if os.path.isfile(meta):
        for line in open(meta, encoding="utf-8"):
            if line.strip().lower().startswith("version"):
                ver = line.split("=", 1)[1].strip()
    return ver


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def main():
    version = read_meta_version()
    # keep the baker's META version aligned so a local bake matches the manifest
    meta = dict(pb.META); meta["version"] = version
    element, files, _raw = pb.build_element(pb.SRC, pb.PLUGIN_NAME, meta)

    if os.path.isdir(DIST):
        shutil.rmtree(DIST)
    os.makedirs(DIST)
    open(os.path.join(DIST, "element.bin"), "wb").write(element)

    assets = []
    if os.path.isdir(ASSETS_SRC):
        for root, _dirs, fs in os.walk(ASSETS_SRC):
            for fn in fs:
                full = os.path.join(root, fn)
                rel  = os.path.relpath(full, ASSETS_SRC).replace("\\", "/")
                data = open(full, "rb").read()
                dst  = os.path.join(DIST, "assets", *rel.split("/"))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(full, dst)
                assets.append({"path": rel, "sha256": sha256_bytes(data)})

    manifest = {
        "version": version,
        "plugin":  pb.PLUGIN_NAME,
        "element": {"path": "element.bin",
                    "sha256": sha256_bytes(element),
                    "scripts": files},
        "assets":  sorted(assets, key=lambda a: a["path"]),
    }
    with open(os.path.join(DIST, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    print("dist built: version=%s, element=%d bytes (%d scripts), %d asset(s)"
          % (version, len(element), len(files), len(assets)))


if __name__ == "__main__":
    main()
