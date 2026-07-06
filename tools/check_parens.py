# -*- coding: utf-8 -*-
import io, sys, re
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
path = sys.argv[1] if len(sys.argv) > 1 else 'plugin/AnotherRedOnline/[018] ChampionsBalance.rb'
txt = open(path, encoding='utf-8').read()
out = []
for l in txt.split('\n'):
    if l.lstrip().startswith('#'):
        continue
    out.append(l)
code = '\n'.join(out)
code = re.sub(r'"(?:\\.|[^"\\])*"', '""', code)
code = re.sub(r"'(?:\\.|[^'\\])*'", "''", code)
print('file:', path)
print('paren diff after string-strip:', code.count('(') - code.count(')'))
print('brace diff:', code.count('{') - code.count('}'))
print('brack diff:', code.count('[') - code.count(']'))
defs = len(re.findall(r'(?m)^\s*def\s', code))
print('def count:', defs)
