# -*- coding: utf-8 -*-
import re, html, os, json

SRC = os.path.join('tmp', 'List of Changes _ Pokemon Champions｜Game8.html')

def clean(x):
    return re.sub(r'\s+', ' ', html.unescape(re.sub('<[^>]+>', ' ', x)).replace('\xa0', ' ')).strip()

SECTIONS = [
    ('MB_NERF', 77137, 84737),
    ('MB_BUFF', 84737, 87959),
    ('STATUS', 94846, 97613),
    ('MECHANIC', 97613, 98423),
    ('MOVES', 98423, 116731),
    ('ABILITY', 116731, 117857),
    ('SPEC_BUFF', 117930, 146432),
    ('SPEC_NERF', 146432, 161085),
]

def rows_in(t):
    out = []
    for tbl in re.finditer(r'<table.*?</table>', t, re.S):
        for r in re.findall(r'<tr.*?</tr>', tbl.group(0), re.S):
            cells = [clean(c) for c in re.findall(r'<t[dh].*?</t[dh]>', r, re.S)]
            cells = [c for c in cells if c]
            if cells:
                out.append(cells)
    return out

def main():
    t = open(SRC, encoding='utf-8').read()
    result = {}
    for name, a, b in SECTIONS:
        result[name] = rows_in(t[a:b])
    with open(os.path.join('tmp', '_changes.json'), 'w', encoding='utf-8') as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    for name, a, b in SECTIONS:
        print(name, '->', len(result[name]), 'rows')

if __name__ == '__main__':
    main()
