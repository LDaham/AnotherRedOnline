# -*- coding: utf-8 -*-
# Reproduce Battle::Battler#pbTryUseMove from decompiled source with Champions edits,
# emitting the method text verbatim (to avoid hand-transcribing Korean strings).
import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

SRC = 'decompiled/Scripts/168_Battler_UseMoveSuccessChecks.rb'
lines = open(SRC, encoding='utf-8').readlines()

# Find the method start/end (def pbTryUseMove ... matching end at same indent)
start = None
for i, l in enumerate(lines):
    if l.strip().startswith('def pbTryUseMove('):
        start = i
        indent = len(l) - len(l.lstrip())
        break
assert start is not None
end = None
for j in range(start + 1, len(lines)):
    l = lines[j]
    if l.strip() == 'end' and (len(l) - len(l.lstrip())) == indent:
        end = j
        break
assert end is not None

body = [lines[k].rstrip('\n') for k in range(start, end + 1)]
# drop fully-blank lines (decompiler double-spacing)
body = [b for b in body if b.strip() != '']

text = '\n'.join(body)

# --- Edit 1: freeze thaw 20% -> 25% + guaranteed thaw by 3rd turn ---
old_frozen = (
'      if !move.thawsUser?\n'
'        if @battle.pbRandom(100) < 20\n'
'          pbCureStatus\n'
'        else'
)
new_frozen = (
'      if !move.thawsUser?\n'
'        @arnet_champ_freeze = (@arnet_champ_freeze || 0) + 1\n'
'        if @battle.pbRandom(100) < 25 || @arnet_champ_freeze >= 3\n'
'          @arnet_champ_freeze = 0\n'
'          pbCureStatus\n'
'        else'
)
assert old_frozen in text, 'FROZEN block not matched'
text = text.replace(old_frozen, new_frozen)

# --- Edit 2: paralysis full-para 25% -> 12.5% ---
old_para = 'if @status == :PARALYSIS && @battle.pbRandom(100) < 25'
new_para = 'if @status == :PARALYSIS && @battle.pbRandom(1000) < 125   # Champions: 12.5%'
assert old_para in text, 'PARALYSIS line not matched'
text = text.replace(old_para, new_para)

open('tmp/_trymove_gen.rb', 'w', encoding='utf-8').write(text)
print(text)
