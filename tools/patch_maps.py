# -*- coding: utf-8 -*-
"""
Inject a "노력치 조정" (EV training) option into the Pokémon Center extra-service
NPC menu across every map, right below "미라클교환".

The NPC menu is an inline RPG Maker "Show Choices" (event command code 102) baked
into each Pokémon Center map's event, so there is no script hook — we edit the map
events directly. Uses tools/rgss_marshal.py (byte-identical round-trip verified)
so untouched parts of the map are preserved exactly.

Selecting the new option runs the global script method `pbEVTrainingService`
(defined in plugin [022] EVTraining.rb).

Idempotent: a map already carrying "노력치 조정" is skipped.

Usage:
  PYTHONIOENCODING=utf-8 python tools/patch_maps.py apply   [GAME_DATA_DIR]
  PYTHONIOENCODING=utf-8 python tools/patch_maps.py check    [GAME_DATA_DIR]   # dry-run report
"""
import os, sys, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rgss_marshal as rm

DEFAULT_GAME = r"tmp/Pokemon Another Red 테스트 버전/Data"
EC_CLASS   = "RPG::EventCommand"
ANCHOR     = "미라클교환"      # insert directly below this choice
CANCEL     = "취소"
NEW_LABEL  = "노력치 조정"
SERVICE    = "pbEVTrainingService"

# 무브 리마인더("기술 배우기") 분기 간소화: 해당 When 분기 본문을 통째로 지우고
# pbMoveRelearnService([027]) 한 줄 호출로 대체 → 초기 확인/안내/가르치기 확인 등
# 모든 프롬프트 제거. 라벨은 게임 상태에 따라 두 가지로 나타난다.
RELEARN_LABELS  = ("기술 떠올리기", "기술 배우기")
RELEARN_SERVICE = "pbMoveRelearnService"


def mkstr(text):
    return rm.RString(text.encode("utf-8"), [])

def mkcmd(code, indent, params):
    # ivar order mirrors the game's own commands: [@parameters, @indent, @code]
    return rm.RObject(rm.Sym(EC_CLASS), [
        (rm.Sym("@parameters"), params),
        (rm.Sym("@indent"), indent),
        (rm.Sym("@code"), code),
    ])

def _choices_of(cmd):
    """If cmd is a Show-Choices (102) menu holding the anchor, return its choice
    array (list of RString), else None."""
    if cmd.get("@code") != 102:
        return None
    params = cmd.get("@parameters") or []
    if not params or not isinstance(params[0], list):
        return None
    arr = params[0]
    labels = [x.str() for x in arr if isinstance(x, rm.RString)]
    if ANCHOR in labels and CANCEL in labels:
        return arr
    return None


def patch_list(lst):
    """Patch one event page command list in place. Returns True if modified."""
    modified = False
    i = 0
    while i < len(lst):
        cmd = lst[i]
        arr = _choices_of(cmd)
        if arr is None:
            i += 1
            continue
        labels = [x.str() if isinstance(x, rm.RString) else None for x in arr]
        if NEW_LABEL in labels:          # already patched
            i += 1
            continue

        base = cmd.get("@indent")
        params = cmd.get("@parameters")
        mi = labels.index(ANCHOR)
        new_index = mi + 1               # 0-based slot for the new choice

        # 1) choice array: insert the new label right after the anchor
        arr.insert(new_index, mkstr(NEW_LABEL))

        # 2) cancel index (params[1], 1-based): shift if it pointed at/after the slot
        cancel = params[1]
        if isinstance(cancel, int) and cancel > 0 and (cancel - 1) >= new_index:
            params[1] = cancel + 1

        # 3) find this choices block's own closing 404 (first 404 at base indent)
        end = None
        for j in range(i + 1, len(lst)):
            c = lst[j]
            if c.get("@indent") == base and c.get("@code") == 404:
                end = j
                break
        if end is None:
            end = len(lst)

        # 4) renumber the block's own When (402) branches whose index >= new_index;
        #    remember where the first shifted branch (the anchor's successor, i.e.
        #    the CANCEL branch) sits so we insert the new branch just before it.
        insert_at = end                  # fallback: right before the closing 404
        first_shift = None
        for j in range(i + 1, end):
            c = lst[j]
            if c.get("@indent") == base and c.get("@code") == 402:
                cp = c.get("@parameters")
                if isinstance(cp[0], int) and cp[0] >= new_index:
                    if first_shift is None:
                        first_shift = j
                    cp[0] = cp[0] + 1
        if first_shift is not None:
            insert_at = first_shift

        # 5) build + splice the new When branch:
        #      When[new_index] "노력치 조정"  ->  @>Script: pbEVTrainingService
        block = [
            mkcmd(402, base, [new_index, mkstr(NEW_LABEL)]),
            mkcmd(355, base + 1, [mkstr(SERVICE)]),
            mkcmd(0,   base + 1, []),
        ]
        lst[insert_at:insert_at] = block
        modified = True
        i = end + len(block) + 1
    return modified


def _relearn_already(lst, when_i, base):
    """When-branch body already replaced by our single Script call?"""
    j = when_i + 1
    if j < len(lst):
        c = lst[j]
        if c.get("@code") == 355 and c.get("@indent") == base + 1:
            p = c.get("@parameters") or []
            if p and isinstance(p[0], rm.RString) and p[0].str() == RELEARN_SERVICE:
                return True
    return False


def patch_relearn_list(lst):
    """Replace the move-reminder When branch body/bodies with one Script call to
    pbMoveRelearnService. Only acts inside a list that holds the service menu.
    Idempotent. Returns True if modified."""
    if not any(_choices_of(c) is not None for c in lst):
        return False
    modified = False
    i = 0
    while i < len(lst):
        c = lst[i]
        if c.get("@code") == 402:
            p = c.get("@parameters") or []
            label = p[1].str() if len(p) > 1 and isinstance(p[1], rm.RString) else None
            base = c.get("@indent")
            if label in RELEARN_LABELS and not _relearn_already(lst, i, base):
                # body = commands strictly inside this When (indent > base), up to
                # the next When/WhenCancel/EndChoices at this indent.
                end = i + 1
                while end < len(lst) and lst[end].get("@indent") > base:
                    end += 1
                block = [
                    mkcmd(355, base + 1, [mkstr(RELEARN_SERVICE)]),
                    mkcmd(0,   base + 1, []),
                ]
                lst[i + 1:end] = block
                modified = True
                i = i + 1 + len(block)
                continue
        i += 1
    return modified


def patch_map_node(node):
    if not isinstance(node, rm.RObject):   # e.g. MapInfos.rxdata is a Hash
        return 0
    events = node.get("@events")
    if events is None:
        return 0
    n = 0
    for _eid, ev in events.pairs:
        for pg in ev.get("@pages") or []:
            lst = pg.get("@list")
            if not lst:
                continue
            m1 = patch_list(lst)            # "노력치 조정" 주입
            m2 = patch_relearn_list(lst)    # "기술 배우기" 분기 간소화
            if m1 or m2:
                n += 1
    return n


def map_has_service(node):
    if not isinstance(node, rm.RObject):
        return False
    events = node.get("@events")
    if events is None:
        return False
    for _eid, ev in events.pairs:
        for pg in ev.get("@pages") or []:
            lst = pg.get("@list")
            if not lst:
                continue
            for c in lst:
                if _choices_of(c) is not None:
                    return True
    return False


def service_map_paths(game_data_dir=DEFAULT_GAME):
    """Map*.rxdata files that carry the extra-service NPC menu (patched or not) —
    i.e. exactly the maps a release must ship so the injected choice reaches the
    player."""
    out = []
    for p in sorted(glob.glob(os.path.join(game_data_dir, "Map*.rxdata"))):
        try:
            node = rm.load(open(p, "rb").read())
        except Exception:
            continue
        if map_has_service(node):
            out.append(p)
    return out


def apply_all(game_data_dir=DEFAULT_GAME, write=True):
    """Patch every service map in place. Idempotent. Returns (touched, total)
    where touched = [(basename, branches), ...]."""
    touched = []
    total = 0
    for p in sorted(glob.glob(os.path.join(game_data_dir, "Map*.rxdata"))):
        raw = open(p, "rb").read()
        node = rm.load(raw)
        n = patch_map_node(node)
        if n == 0:
            continue
        total += n
        touched.append((os.path.basename(p), n))
        if write:
            out = rm.dump(node)
            rm.load(out)              # sanity: re-parse must succeed
            open(p, "wb").write(out)
    return touched, total


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    game = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_GAME
    touched, total = apply_all(game, write=(mode == "apply"))
    print("mode=%s  maps_with_service=%d  branches_patched=%d" % (mode, len(touched), total))
    for name, n in touched:
        print("  %-16s x%d" % (name, n))
    if mode != "apply":
        print("(dry-run; pass 'apply' to write)")


if __name__ == "__main__":
    main()
