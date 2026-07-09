# -*- coding: utf-8 -*-
"""
General-purpose Ruby Marshal (version 4.8) reader/writer for RGSS data files
(Map*.rxdata etc.). Unlike tools/plugin_baker.py's minimal reader, this one
preserves the FULL object graph — object links, symbol links, string encoding
ivars, user-defined blobs (Table/Tone/Color), RPG::* objects — so that a parsed
tree can be dumped back to BYTE-IDENTICAL output. That round-trip guarantee is
what makes surgical map edits (tools/patch_maps.py) safe.

Node model (Python):
  None / True / False / int (Fixnum)            -> immediate, not link-registered
  Sym(name)                                     -> symbol (own link table ';')
  RString(bytes, ivars)                         -> '"' or 'I"' string
  list                                          -> '[' array
  RHash(pairs, default)                         -> '{' / '}' hash
  RObject(cls, ivars)                           -> 'o' object with ivars
  RUser(cls, data:bytes)                        -> 'u' user-defined (_dump)
  RUserMarshal(cls, data:node)                  -> 'U' user (marshal_dump)
  RFloat(text:bytes)                            -> 'f'
  RBignum(sign, words)                          -> 'l'
  RRegexp(src:bytes, options:int)               -> '/'
  RExtended(mods:[Sym], inner)                  -> 'e'
  RUClass(name:Sym, inner)                      -> 'C' (subclass of builtin)
Everything except None/True/False/int/Sym is "link-registered" (Ruby TYPE_LINK).
"""

class Sym:
    __slots__ = ("n",)
    def __init__(self, n): self.n = n
    def __repr__(self): return ":" + self.n
    def __eq__(self, o): return isinstance(o, Sym) and o.n == self.n
    def __hash__(self): return hash(("Sym", self.n))

class RString:
    __slots__ = ("b", "ivars")
    def __init__(self, b, ivars=None): self.b = b; self.ivars = ivars or []
    def str(self):
        try: return self.b.decode("utf-8")
        except Exception: return self.b.decode("latin-1")
    def __repr__(self): return "R%r" % (self.str(),)

class RHash:
    __slots__ = ("pairs", "default")
    def __init__(self, pairs=None, default=None): self.pairs = pairs or []; self.default = default

class RObject:
    __slots__ = ("cls", "ivars")
    def __init__(self, cls, ivars=None): self.cls = cls; self.ivars = ivars or []
    def get(self, name):
        for k, v in self.ivars:
            if isinstance(k, Sym) and k.n == name: return v
        return None
    def set(self, name, val):
        for i, (k, v) in enumerate(self.ivars):
            if isinstance(k, Sym) and k.n == name:
                self.ivars[i] = (k, val); return
        self.ivars.append((Sym(name), val))
    def __repr__(self): return "<%s>" % (self.cls.n if isinstance(self.cls, Sym) else self.cls)

class RUser:
    __slots__ = ("cls", "data")
    def __init__(self, cls, data): self.cls = cls; self.data = data

class RUserMarshal:
    __slots__ = ("cls", "data")
    def __init__(self, cls, data): self.cls = cls; self.data = data

class RFloat:
    __slots__ = ("text",)
    def __init__(self, text): self.text = text

class RBignum:
    __slots__ = ("sign", "words")   # sign: b'+'/'-', words: bytes
    def __init__(self, sign, words): self.sign = sign; self.words = words

class RRegexp:
    __slots__ = ("src", "options")
    def __init__(self, src, options): self.src = src; self.options = options

class RExtended:
    __slots__ = ("mods", "inner")
    def __init__(self, mods, inner): self.mods = mods; self.inner = inner

class RUClass:
    __slots__ = ("name", "inner")
    def __init__(self, name, inner): self.name = name; self.inner = inner


# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------
class Reader:
    def __init__(self, data):
        self.d = data; self.i = 0
        self.syms = []      # symbol table (index -> Sym)
        self.objs = []      # object link table (index -> node)

    def byte(self):
        b = self.d[self.i]; self.i += 1; return b
    def sbyte(self):
        b = self.byte(); return b - 256 if b >= 128 else b
    def read(self, n):
        s = self.d[self.i:self.i + n]; self.i += n; return s

    def long(self):
        c = self.sbyte()
        if c == 0: return 0
        if c >= 5: return c - 5
        if c >= 1:
            n = 0
            for k in range(c): n |= self.byte() << (8 * k)
            return n
        if c <= -5: return c + 5
        n = -1
        for k in range(-c):
            n &= ~(0xff << (8 * k)); n |= self.byte() << (8 * k)
        return n

    def _sym(self):
        n = self.long(); s = Sym(self.read(n).decode("utf-8"))
        self.syms.append(s); return s

    def _ivars(self, count):
        out = []
        for _ in range(count):
            k = self.obj(); v = self.obj(); out.append((k, v))
        return out

    def obj(self):
        t = chr(self.byte())
        if t == '0': return None
        if t == 'T': return True
        if t == 'F': return False
        if t == 'i': return self.long()
        if t == ':': return self._sym()
        if t == ';': return self.syms[self.long()]
        if t == '@': return self.objs[self.long()]
        if t == '[':
            arr = []; self.objs.append(arr); n = self.long()
            for _ in range(n): arr.append(self.obj())
            return arr
        if t == '{' or t == '}':
            h = RHash(); self.objs.append(h); n = self.long()
            for _ in range(n):
                k = self.obj(); v = self.obj(); h.pairs.append((k, v))
            if t == '}': h.default = self.obj()
            return h
        if t == '"':
            n = self.long(); raw = self.read(n)
            s = RString(raw); self.objs.append(s); return s
        if t == 'I':
            # ivar-wrapped object; the inner object owns the link slot
            inner = self.obj()
            cnt = self.long()
            ivars = self._ivars(cnt)
            if isinstance(inner, RString):
                inner.ivars = ivars; return inner
            if isinstance(inner, (RObject,)):
                inner.ivars.extend(ivars); return inner
            if isinstance(inner, RRegexp):
                inner._ivars = ivars; return inner
            # generic fallback: wrap
            w = RObject(Sym("__IVAR__"), ivars); w.set("__inner__", inner)
            return w
        if t == 'o':
            o = RObject(None); self.objs.append(o)
            o.cls = self.obj(); cnt = self.long(); o.ivars = self._ivars(cnt)
            return o
        if t == 'u':
            cls = self.obj(); n = self.long(); data = self.read(n)
            u = RUser(cls, data); self.objs.append(u); return u
        if t == 'U':
            u = RUserMarshal(None, None); self.objs.append(u)
            u.cls = self.obj(); u.data = self.obj(); return u
        if t == 'f':
            n = self.long(); fl = RFloat(self.read(n)); self.objs.append(fl); return fl
        if t == 'l':
            sign = self.read(1); nwords = self.long(); words = self.read(nwords * 2)
            b = RBignum(sign, words); self.objs.append(b); return b
        if t == '/':
            n = self.long(); src = self.read(n); opt = self.byte()
            r = RRegexp(src, opt); self.objs.append(r); return r
        if t == 'e':
            mods = []
            # 'e' can stack; first read module symbol(s)
            mods.append(self.obj())
            inner = self.obj()
            ex = RExtended(mods, inner)
            return ex
        if t == 'C':
            name = self.obj(); inner = self.obj()
            c = RUClass(name, inner); return c
        raise ValueError("unhandled marshal type %r at %d" % (t, self.i - 1))


# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------
class Writer:
    def __init__(self):
        self.out = bytearray()
        self.syms = {}      # name -> index
        self.objs = {}      # id(node) -> index
        self._objn = 0

    def byte(self, b): self.out.append(b & 0xff)
    def raw(self, bs): self.out += bs

    def w_long(self, n):
        if n == 0: self.byte(0); return
        if 0 < n <= 122: self.byte(n + 5); return
        if -123 <= n < 0: self.byte((n - 5) & 0xff); return
        if n > 0:
            b = []
            x = n
            while x != 0:
                b.append(x & 0xff); x >>= 8
            self.byte(len(b)); self.raw(bytes(b)); return
        # negative multi-byte
        b = []
        x = n
        while x != -1 and x != 0:
            b.append(x & 0xff); x >>= 8
        if not b: b = [0xff]
        # ensure sign continuation: top byte must have high bit set for negatives
        if b[-1] & 0x80 == 0:
            b.append(0xff)
        self.byte((-len(b)) & 0xff); self.raw(bytes(b))

    def _reg_obj(self, node):
        self.objs[id(node)] = self._objn; self._objn += 1

    def w_sym(self, s):
        if s.n in self.syms:
            self.byte(ord(';')); self.w_long(self.syms[s.n]); return
        self.syms[s.n] = len(self.syms)
        self.byte(ord(':')); enc = s.n.encode("utf-8")
        self.w_long(len(enc)); self.raw(enc)

    def _link_if_seen(self, node):
        if id(node) in self.objs:
            self.byte(ord('@')); self.w_long(self.objs[id(node)]); return True
        return False

    def _w_ivars(self, ivars):
        self.w_long(len(ivars))
        for k, v in ivars:
            self.w(k); self.w(v)

    def w(self, node):
        if node is None: self.byte(ord('0')); return
        if node is True: self.byte(ord('T')); return
        if node is False: self.byte(ord('F')); return
        if isinstance(node, bool): return
        if isinstance(node, int):
            self.byte(ord('i')); self.w_long(node); return
        if isinstance(node, Sym):
            self.w_sym(node); return
        if isinstance(node, RString):
            if self._link_if_seen(node): return
            self._reg_obj(node)
            if node.ivars:
                self.byte(ord('I'))
                self.byte(ord('"')); self.w_long(len(node.b)); self.raw(node.b)
                self._w_ivars(node.ivars)
            else:
                self.byte(ord('"')); self.w_long(len(node.b)); self.raw(node.b)
            return
        if isinstance(node, list):
            if self._link_if_seen(node): return
            self._reg_obj(node)
            self.byte(ord('[')); self.w_long(len(node))
            for e in node: self.w(e)
            return
        if isinstance(node, RHash):
            if self._link_if_seen(node): return
            self._reg_obj(node)
            self.byte(ord('}') if node.default is not None else ord('{'))
            self.w_long(len(node.pairs))
            for k, v in node.pairs: self.w(k); self.w(v)
            if node.default is not None: self.w(node.default)
            return
        if isinstance(node, RObject):
            if self._link_if_seen(node): return
            self._reg_obj(node)
            self.byte(ord('o')); self.w(node.cls); self._w_ivars(node.ivars)
            return
        if isinstance(node, RUser):
            if self._link_if_seen(node): return
            self._reg_obj(node)
            self.byte(ord('u')); self.w(node.cls)
            self.w_long(len(node.data)); self.raw(node.data)
            return
        if isinstance(node, RUserMarshal):
            if self._link_if_seen(node): return
            self._reg_obj(node)
            self.byte(ord('U')); self.w(node.cls); self.w(node.data)
            return
        if isinstance(node, RFloat):
            if self._link_if_seen(node): return
            self._reg_obj(node)
            self.byte(ord('f')); self.w_long(len(node.text)); self.raw(node.text)
            return
        if isinstance(node, RBignum):
            if self._link_if_seen(node): return
            self._reg_obj(node)
            self.byte(ord('l')); self.raw(node.sign)
            self.w_long(len(node.words) // 2); self.raw(node.words)
            return
        if isinstance(node, RRegexp):
            if self._link_if_seen(node): return
            self._reg_obj(node)
            self.byte(ord('/')); self.w_long(len(node.src)); self.raw(node.src)
            self.byte(node.options)
            return
        if isinstance(node, RExtended):
            self.byte(ord('e')); self.w(node.mods[0]); self.w(node.inner); return
        if isinstance(node, RUClass):
            self.byte(ord('C')); self.w(node.name); self.w(node.inner); return
        raise ValueError("unhandled node type %r" % (type(node),))


def load(data):
    assert data[:2] == b"\x04\x08", "bad marshal header"
    return Reader(data[2:]).obj()

def dump(node):
    w = Writer(); w.w(node)
    return b"\x04\x08" + bytes(w.out)

def load_file(path):
    with open(path, "rb") as f: return load(f.read())

def dump_file(path, node):
    with open(path, "wb") as f: f.write(dump(node))
