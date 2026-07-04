# -*- coding: utf-8 -*-
"""
plugin_baker.py — Safely append the AnotherRedOnline plugin into an existing
Pokemon Essentials `Data/PluginScripts.rxdata` WITHOUT recompiling (and thus
wiping) the other plugins already baked in.

The rxdata is `Marshal.dump(scripts)` where
    scripts = [ [name, meta_hash, [[filename, Zlib.deflate(content)], ...]], ... ]

Strategy: surgically append one self-contained element to the top-level array
(increment the array's count-long, leave every existing byte untouched, append
our element at EOF). Our element is encoded with full symbols / no back-refs,
which Ruby's Marshal.load accepts.

Includes a minimal Ruby-Marshal reader used ONLY to validate:
  - that we can faithfully parse the REAL file (proves the codec matches Ruby),
  - that the final appended file re-parses with our plugin recoverable.

Usage:
  python plugin_baker.py inspect        # parse & list existing plugins
  python plugin_baker.py bake           # validate + backup + write
"""
import sys, os, zlib, io

GAME = r"d:\Code\AnotherRedMulti\tmp\Pokemon Another Red_PWT_250821"
RXDATA = os.path.join(GAME, "Data", "PluginScripts.rxdata")
SRC = r"d:\Code\AnotherRedMulti\plugin\AnotherRedOnline"

PLUGIN_NAME = "Another Red Online"
META = {  # mirrors readMeta() output for our meta.txt (minus :scripts/:dir)
    "name": "Another Red Online",
    "version": "0.1.0",
    "essentials": ["21.1"],     # ESSENTIALS -> array
    "credits": ["AnotherRedMulti"],  # CREDITS -> array
}

# ---------------------------------------------------------------------------
# Symbol wrapper so symbols are distinct from strings as hash keys
# ---------------------------------------------------------------------------
class Sym:
    __slots__ = ("n",)
    def __init__(self, n): self.n = n
    def __eq__(self, o): return isinstance(o, Sym) and o.n == self.n
    def __hash__(self): return hash(("sym", self.n))
    def __repr__(self): return ":" + self.n

class RObj:
    """A decoded Ruby object: class-name Sym + ivar dict (or user-marshal data)."""
    def __init__(self):
        self.cls = None; self.iv = {}; self.data = None
    def __repr__(self):
        c = self.cls.n if isinstance(self.cls, Sym) else self.cls
        return "<%s %s>" % (c, sorted(self.iv))

# ---------------------------------------------------------------------------
# Minimal Marshal reader (subset: nil/true/false, int, symbol+symlink, array,
# hash, string, ivar-wrapped string, object link)
# ---------------------------------------------------------------------------
class Reader:
    def __init__(self, data):
        self.d = data; self.i = 0
        self.syms = []; self.objs = []
    def byte(self):
        b = self.d[self.i]; self.i += 1; return b
    def sbyte(self):
        b = self.byte()
        return b - 256 if b >= 128 else b
    def read(self, n):
        s = self.d[self.i:self.i+n]; self.i += n; return s
    def long(self):
        c = self.sbyte()
        if c == 0: return 0
        if c >= 5: return c - 5
        if c >= 1:
            n = 0
            for k in range(c): n |= self.byte() << (8*k)
            return n
        if c <= -5: return c + 5
        n = -1
        for k in range(-c):
            n &= ~(0xff << (8*k)); n |= self.byte() << (8*k)
        return n
    def obj(self):
        t = self.byte()
        ch = chr(t)
        if ch == '0': return None
        if ch == 'T': return True
        if ch == 'F': return False
        if ch == 'i': return self.long()
        if ch == ':':
            n = self.long(); s = self.read(n).decode('utf-8'); self.syms.append(s); return Sym(s)
        if ch == ';':
            return Sym(self.syms[self.long()])
        if ch == '@':
            return self.objs[self.long()]
        if ch == '[':
            arr = []; self.objs.append(arr); n = self.long()
            for _ in range(n): arr.append(self.obj())
            return arr
        if ch == '{':
            h = {}; self.objs.append(h); n = self.long()
            for _ in range(n):
                k = self.obj(); v = self.obj(); h[k] = v
            return h
        if ch == '"':
            n = self.long(); raw = self.read(n); self.objs.append(raw); return raw  # bytes
        if ch == 'l':
            sign = chr(self.byte())            # '+' or '-'
            nwords = self.long()               # number of 16-bit words
            n = 0
            for k in range(nwords):
                n |= self.byte() << (16*k)
                n |= self.byte() << (16*k + 8)
            return -n if sign == '-' else n
        if ch == 'f':
            n = self.long(); raw = self.read(n)
            try:
                return float(raw.decode('ascii'))
            except Exception:
                return raw
        if ch == 'I':
            base = self.obj()  # usually a '"' string (registered already)
            niv = self.long(); utf8 = False
            for _ in range(niv):
                k = self.obj(); v = self.obj()
                if isinstance(k, Sym) and k.n == 'E' and v is True: utf8 = True
            if isinstance(base, (bytes, bytearray)) and utf8:
                return base.decode('utf-8')
            return base
        if ch == 'o':
            o = RObj(); self.objs.append(o)
            o.cls = self.obj()                 # class name symbol
            niv = self.long()
            for _ in range(niv):
                k = self.obj(); v = self.obj()
                o.iv[k.n if isinstance(k, Sym) else k] = v
            return o
        if ch == 'e':                          # extended object: module then obj
            self.obj(); return self.obj()
        if ch == 'u':                          # user-defined (_load): class sym + raw bytes
            o = RObj(); self.objs.append(o)
            o.cls = self.obj(); n = self.long(); o.data = self.read(n); return o
        if ch == 'U':                          # user-marshal: class sym, then data
            o = RObj(); self.objs.append(o)
            o.cls = self.obj(); o.data = self.obj(); return o
        if ch == 'C':                          # subclass of builtin: sym, then obj
            self.obj(); return self.obj()
        if ch == '/':                          # regexp: string + options byte
            n = self.long(); raw = self.read(n); self.byte(); self.objs.append(raw); return raw
        raise ValueError("unhandled marshal type %r at %d" % (ch, self.i-1))

def parse_file(path):
    data = open(path, 'rb').read()
    assert data[0:2] == b'\x04\x08', "bad marshal header"
    r = Reader(data[2:])
    top = r.obj()
    return data, top

# ---------------------------------------------------------------------------
# Minimal Marshal writer (full symbols, no back-refs — valid on load)
# ---------------------------------------------------------------------------
def w_long(n):
    if n == 0: return b'\x00'
    if 0 < n <= 122: return bytes([n+5])
    if -123 <= n < 0: return bytes([(n-5) & 0xff])
    if n > 0:
        out = bytearray()
        v = n
        while v: out.append(v & 0xff); v >>= 8
        return bytes([len(out)]) + bytes(out)
    raise ValueError("neg multibyte not needed")

def w_sym(name):
    b = name.encode('utf-8')
    return b':' + w_long(len(b)) + b

def w_utf8(s):
    b = s.encode('utf-8')
    return b'I"' + w_long(len(b)) + b + w_long(1) + w_sym('E') + b'T'

def w_bin(b):
    return b'"' + w_long(len(b)) + b

def w_arr(items):
    out = b'[' + w_long(len(items))
    for it in items: out += it
    return out

def w_hash(pairs):
    out = b'{' + w_long(len(pairs))
    for k, v in pairs: out += k + v
    return out

def build_element(src=SRC, name=PLUGIN_NAME, meta=META):
    files = sorted(f for f in os.listdir(src) if f.lower().endswith('.rb'))
    file_entries = []
    raw_map = {}
    for fn in files:
        content = open(os.path.join(src, fn), 'rb').read()
        deflated = zlib.compress(content, 9)
        raw_map[fn] = content
        file_entries.append(w_arr([w_utf8(fn), w_bin(deflated)]))
    files_arr = w_arr(file_entries)
    meta_pairs = [
        (w_sym('name'),       w_utf8(meta['name'])),
        (w_sym('version'),    w_utf8(meta['version'])),
        (w_sym('essentials'), w_arr([w_utf8(v) for v in meta['essentials']])),
        (w_sym('credits'),    w_arr([w_utf8(v) for v in meta['credits']])),
    ]
    meta_hash = w_hash(meta_pairs)
    element = w_arr([w_utf8(name), meta_hash, files_arr])
    return element, files, raw_map

# ---------------------------------------------------------------------------
def summarize(top):
    print("top-level: array of %d plugins" % len(top))
    for el in top:
        name = el[0]
        meta = el[1]
        scripts = el[2]
        ess = meta.get(Sym('essentials'))
        print("  - %-32s scripts=%-3d essentials=%s" % (str(name), len(scripts), ess))

def cmd_inspect():
    data, top = parse_file(RXDATA)
    print("file size: %d bytes" % len(data))
    summarize(top)
    # show count-long codec faithfulness
    assert data[2] == ord('['), "top is not array"
    r = Reader(data[3:])
    cnt = r.long()
    consumed = r.i
    reenc = w_long(cnt)
    print("array count = %d ; count-long bytes original=%s reenc=%s match=%s"
          % (cnt, data[3:3+consumed].hex(), reenc.hex(), data[3:3+consumed] == reenc))

def deploy_assets():
    """Copy the mod's bundled assets into the game folder. These ship WITH the mod
    (they are NOT part of the base game) -- e.g. the online battle BGM
    Audio/BGM/Arena Battle.ogg. Mirrors SRC/assets/** into GAME/**."""
    import shutil
    adir = os.path.join(SRC, "assets")
    if not os.path.isdir(adir):
        return
    n = 0
    for root, _dirs, files in os.walk(adir):
        rel = os.path.relpath(root, adir)
        dst_dir = GAME if rel == "." else os.path.join(GAME, rel)
        os.makedirs(dst_dir, exist_ok=True)
        for f in files:
            shutil.copy2(os.path.join(root, f), os.path.join(dst_dir, f))
            n += 1
    print("deployed %d asset file(s) from %s" % (n, adir))

def cmd_bake(src=SRC, name=PLUGIN_NAME, meta=META):
    data, top = parse_file(RXDATA)
    n_before = len(top)
    print("parsed OK: %d plugins before" % n_before)
    # already present?
    for el in top:
        if str(el[0]) == name:
            print("ERROR: '%s' already present; aborting (run after restoring backup)." % name)
            return 1
    # decode count + re-encode check
    assert data[0:2] == b'\x04\x08' and data[2] == ord('[')
    r = Reader(data[3:]); cnt = r.long(); clen = r.i
    assert cnt == n_before, "count mismatch %d vs %d" % (cnt, n_before)
    assert w_long(cnt) == data[3:3+clen], "count-long codec mismatch"
    # build element + writer self-test through reader
    element, files, raw_map = build_element(src, name, meta)
    rr = Reader(element); el = rr.obj()
    assert str(el[0]) == name, "self-test name"
    assert rr.i == len(element), "self-test trailing bytes"
    sc = el[2]
    assert len(sc) == len(files), "self-test script count"
    for (fn_b, defl) in sc:
        fn = fn_b if isinstance(fn_b, str) else fn_b.decode()
        assert zlib.decompress(defl) == raw_map[fn], "inflate mismatch %s" % fn
    print("writer self-test OK: %d scripts, names=%s" % (len(sc), files))
    # surgical append
    new_count = w_long(cnt + 1)
    out = data[0:3] + new_count + data[3+clen:] + element
    # validate FINAL by full re-parse with our (Ruby-faithful) reader
    assert out[0:2] == b'\x04\x08'
    fr = Reader(out[2:]); ftop = fr.obj()
    assert fr.i == len(out[2:]), "final trailing bytes: parsed %d of %d" % (fr.i, len(out[2:]))
    assert len(ftop) == n_before + 1, "final count"
    last = ftop[-1]
    assert str(last[0]) == name, "final last name"
    for (fn_b, defl) in last[2]:
        fn = fn_b if isinstance(fn_b, str) else fn_b.decode()
        assert zlib.decompress(defl) == raw_map[fn], "final inflate %s" % fn
    print("final re-parse OK: %d plugins, last='%s'" % (len(ftop), str(last[0])))
    # backup + write
    bak = RXDATA + ".bak"
    if not os.path.exists(bak):
        open(bak, 'wb').write(data)
        print("backup written: %s" % bak)
    else:
        print("backup already exists (kept): %s" % bak)
    open(RXDATA, 'wb').write(out)
    print("WROTE %s (%d -> %d bytes, %d -> %d plugins)"
          % (RXDATA, len(data), len(out), n_before, n_before + 1))
    deploy_assets()
    return 0

def cmd_restore():
    bak = RXDATA + ".bak"
    if not os.path.exists(bak):
        print("no backup at %s" % bak); return 1
    data = open(bak, 'rb').read()
    open(RXDATA, 'wb').write(data)
    _, top = parse_file(RXDATA)
    print("restored %s from backup (%d bytes, %d plugins)" % (RXDATA, len(data), len(top)))
    return 0

def cmd_bakeprobe():
    src = r"d:\Code\AnotherRedMulti\tools\probe_plugin"
    meta = {"name": "ARNet Probe", "version": "0.0.1",
            "essentials": ["21.1"], "credits": ["probe"]}
    return cmd_bake(src, "ARNet Probe", meta)

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "inspect"
    table = {"inspect": cmd_inspect, "bake": cmd_bake,
             "restore": cmd_restore, "bakeprobe": cmd_bakeprobe}
    sys.exit(table.get(cmd, cmd_inspect)() or 0)
