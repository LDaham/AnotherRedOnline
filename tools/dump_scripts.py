"""Dump base Scripts.rxdata (and optionally PluginScripts) to per-script .rb files
for diffing our build against the all-in-one patch. Usage:

  python tools/dump_scripts.py <Scripts.rxdata> <outdir>

Each script is written as NNN__<sanitized name>.rb (NNN = load order index).
Also prints a name->index map so reordered scripts can still be matched by name.
"""
import sys, os, re, zlib
sys.path.insert(0, os.path.dirname(__file__))
import plugin_baker as pb


def san(s):
    return re.sub(r'[^A-Za-z0-9_.\- ]', '_', s)[:80].strip() or 'unnamed'


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    _, top = pb.parse_file(src)
    for idx, entry in enumerate(top):
        # entry = [id, name, zlib_code]  (name may be bytes or str)
        name = entry[1]
        if isinstance(name, (bytes, bytearray)):
            name = name.decode('utf-8', 'replace')
        code = entry[2]
        if not isinstance(code, (bytes, bytearray)):
            continue  # metadata entry
        try:
            txt = zlib.decompress(code).decode('utf-8', 'replace')
        except Exception:
            txt = zlib.decompress(code).decode('latin-1', 'replace')
        fn = '%03d__%s.rb' % (idx, san(name))
        with open(os.path.join(out, fn), 'w', encoding='utf-8') as f:
            f.write(txt)
    print('wrote %d scripts to %s' % (len(top), out))


if __name__ == '__main__':
    main()
