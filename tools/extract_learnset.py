# -*- coding: utf-8 -*-
import re, html, io, sys, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

SRC = 'tmp/List of Changes _ Pokemon Champions｜Game8.html'
t = open(SRC, encoding='utf-8').read()

def clean(x):
    return re.sub(r'\s+', ' ', html.unescape(re.sub('<[^>]+>', ' ', x)).replace('\xa0', ' ')).strip()

def parse_section(a, b, label):
    seg = t[a:b]
    print('==================', label)
    for tr in re.findall(r'<tr.*?</tr>', seg, re.S):
        # move names appear as link text or img alt; labels are plain text
        # Build a token stream: text tokens + img-alt tokens in order
        tokens = []
        pos = 0
        for m in re.finditer(r'<img[^>]*alt="([^"]*)"[^>]*>|(<a[^>]*>.*?</a>)', tr, re.S):
            if m.group(1) is not None:
                tokens.append(('IMG', m.group(1)))
            else:
                tokens.append(('A', clean(m.group(2))))
        # also get the full cleaned text for labels
        txt = clean(tr)
        # skip header row
        if txt.startswith('Pokemon') or not txt:
            continue
        imgs = [v for k, v in tokens if k == 'IMG' and v]
        links = [v for k, v in tokens if k == 'A' and v]
        print('ROW:', txt)
        if imgs:
            print('   IMGS:', imgs)
        if links:
            print('   LINKS:', links)

parse_section(117930, 146432, 'SPEC_BUFF')
parse_section(146432, 161085, 'SPEC_NERF')
