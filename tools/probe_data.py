# -*- coding: utf-8 -*-
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from plugin_baker import Reader, Sym, RObj

GAME = os.path.join('tmp', 'Pokemon Another Red_PWT_250821')

def load(fn):
    data = open(os.path.join(GAME, 'Data', fn), 'rb').read()
    assert data[:2] == b'\x04\x08', 'bad marshal header'
    return Reader(data[2:]).obj()

def main():
    for fn in ['moves.dat', 'species.dat']:
        top = load(fn)
        print('===', fn, '=> type', type(top).__name__, 'len',
              len(top) if hasattr(top, '__len__') else '?')
        if isinstance(top, dict):
            k = next(iter(top)); v = top[k]
            print('  sample key', repr(k), 'val', type(v).__name__)
            if isinstance(v, RObj):
                print('  ivars:', sorted(v.iv.keys()))

if __name__ == '__main__':
    main()
