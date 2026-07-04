import re
import os
import shutil

# -----------------------------------------------------------------------------
# Another Red — trainer EV/IV order fix
#
# The party data in Data/txt/trainer_parties.txt was authored in Showdown stat
# order  [HP, Atk, Def, SpAtk, SpDef, Spe],  but the Deluxe Battle Kit loader
# maps each array by GameData::Stat#pbs_order, i.e. it reads the array as
#   [HP, Atk, Def, Spe, SpAtk, SpDef]   (SPEED has pbs_order 3).
# So the 4th/5th/6th entries are scrambled.  We physically reorder every EV and
# IV array from Showdown order to the order the engine expects:
#
#   old index (Showdown):  [0, 1, 2, 3, 4, 5]  = HP Atk Def SpAtk SpDef Spe
#   new index (engine):    [0, 1, 2, 5, 3, 4]  = HP Atk Def Spe   SpAtk SpDef
#
# Example:  ev: [0,252,4,0,0,252]  ->  ev: [0,252,4,252,0,0]
#
# NOTE: this permutation is NOT idempotent (it is a 3-cycle on positions 3/4/5;
# running it three times returns to the original).  Run it exactly once.  A
# .bak backup of the original file is written next to it.
# -----------------------------------------------------------------------------

FILE_PATH = os.path.join(
    "tmp", "어나더 레드 올인원 패치",
    "Data", "txt", "trainer_parties.txt"
)

# Matches an `ev:` or `iv:` key followed by a bracket of exactly six integers.
# The word boundary + required ':' + 6-int bracket makes it impossible to hit
# species:/level:/moves:/item:/nature:/ability_index: etc.
ARRAY_RE = re.compile(
    r'\b(ev|iv)\s*:\s*\[\s*'
    r'(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)'
    r'\s*\]'
)


def reorder(m):
    key = m.group(1)
    a, b, c, d, e, f = m.group(2, 3, 4, 5, 6, 7)
    # Showdown [a,b,c,d,e,f] -> engine [a,b,c,f,d,e]  (indices 0,1,2,5,3,4)
    return f"{key}: [{a},{b},{c},{f},{d},{e}]"


def main():
    if not os.path.exists(FILE_PATH):
        print(f"ERROR: '{FILE_PATH}' not found.")
        return

    # Read raw bytes so CRLF line endings and (absent) BOM are preserved exactly.
    with open(FILE_PATH, "rb") as fh:
        raw = fh.read()
    text = raw.decode("utf-8")

    # Backup.
    backup_path = FILE_PATH + ".bak"
    shutil.copyfile(FILE_PATH, backup_path)
    print(f"[OK] backup written: {backup_path}")

    ev_count = len(re.findall(r'\bev\s*:\s*\[', text))
    iv_count = len(re.findall(r'\biv\s*:\s*\[', text))

    changed = []           # (before, after) for arrays whose values actually move
    total_matches = [0]

    def _sub(m):
        total_matches[0] += 1
        before = m.group(0)
        after = reorder(m)
        if before != after:
            changed.append((before, after))
        return after

    new_text = ARRAY_RE.sub(_sub, text)

    with open(FILE_PATH, "wb") as fh:
        fh.write(new_text.encode("utf-8"))

    print(f"[OK] ev: arrays found = {ev_count}, iv: arrays found = {iv_count}")
    print(f"[OK] total arrays reordered = {total_matches[0]}")
    print(f"[OK] arrays whose values actually changed = {len(changed)}")
    print(f"[OK] written in place: {FILE_PATH}")

    print("\n--- sample diffs (first 3 that changed) ---")
    for before, after in changed[:3]:
        print(f"  before: {before}")
        print(f"  after : {after}\n")


if __name__ == "__main__":
    main()
