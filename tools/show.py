# -*- coding: utf-8 -*-
# Print non-blank lines of a file with original line numbers, optional range/grep.
import sys, re, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
path = sys.argv[1]
a = int(sys.argv[2]) if len(sys.argv) > 2 else 1
b = int(sys.argv[3]) if len(sys.argv) > 3 else 10**9
pat = sys.argv[4] if len(sys.argv) > 4 else None
rx = re.compile(pat) if pat else None
for i, line in enumerate(open(path, encoding='utf-8'), 1):
    if i < a or i > b:
        continue
    s = line.rstrip('\n')
    if s.strip() == '':
        continue
    if rx and not rx.search(s):
        continue
    print(f'{i}:{s}')
