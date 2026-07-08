# -*- coding: utf-8 -*-
import sys, os, json
sys.path.insert(0, os.path.dirname(__file__))
from plugin_baker import Reader, Sym, RObj

GAME = os.path.join('tmp', 'Pokemon Another Red 테스트 버전')

def load(fn):
    data = open(os.path.join(GAME, 'Data', fn), 'rb').read()
    return Reader(data[2:]).obj()

def S(x):
    return x.n if isinstance(x, Sym) else x

# ---- moves whose stats change: id -> what to inspect
MOVE_VALUE_IDS = [
    'APPLEACID','BEAKBLAST','BONERUSH','CRABHAMMER','DRAGONCLAW','FIRELASH',
    'FIRSTIMPRESSION','GRAVAPPLE','GROWTH','INFERNALPARADE','NIGHTDAZE',
    'MOUNTAINGALE','POLTERGEIST','PSYSHIELDBASH','SHADOWCLAW','SNAPTRAP',
    'SPIRITSHACKLE','SYRUPBOMB','TOXICTHREAD','TROPKICK',
    'DIRECLAW','FREEZEDRY','MOONBLAST','IRONHEAD','SALTCURE',
]
# moves referenced only inside learnsets (need to exist as valid ids)
LEARN_MOVE_IDS = [
    'MAKEITRAIN','THUNDERWAVE','RAGEFIST','FINALGAMBIT','HEAVYSLAM','KNOCKOFF',
    'PARTINGSHOT','MORTALSPIN','EARTHPOWER','WAVECRASH','LEECHLIFE','TRAILBLAZE',
    'SHELLSMASH','CLOSECOMBAT','MACHPUNCH','UTURN','TRIPLEAXEL','AIRSLASH',
    'BURNUP','FUTURESIGHT','ROOST','BEATUP','BLAZEKICK','DUALWINGBEAT',
    'SUPERPOWER','IRONTAIL','SCALESHOT','SCORCHINGSANDS','ENCORE','VACUUMWAVE',
    'WHIRLPOOL','PAYBACK','MYSTICALFIRE','SAFEGUARD','TAUNT','ATTRACT',
    'BODYPRESS','SHADOWSNEAK','PARABOLICCHARGE','FISSURE','SCALD','NASTYPLOT',
    'CALMMIND',
]
SPECIES_IDS = [
    'GHOLDENGO','ANNIHILAPE','METAGROSS','GRIMMSNARL','SCRAFTY','OVERQWIL',
    'PYROAR','SCEPTILE','SWAMPERT','SCOLIPEDE','BLASTOISE','LOPUNNY','AEGISLASH',
    'ARMAROUGE','CERULEDGE','CHARIZARD','TYRANITAR','DRAGONITE','SABLEYE',
    'SYLVEON','WHIMSICOTT','HIPPOWDON','DRAGAPULT','SCIZOR','DRAMPA',
    'ARCHALUDON','KANGASKHAN','INCINEROAR','GENGAR','ROTOM','MACHAMP',
    'GRENINJA','MILOTIC','GLISCOR','GARGANACL','SNEASLER',
]

def main():
    moves = load('moves.dat')
    species = load('species.dat')
    mkeys = {S(k) for k in moves.keys()}
    skeys = {S(k) for k in species.keys()}

    print('=== MOVE VALUE IDS ===')
    for mid in MOVE_VALUE_IDS:
        if mid not in mkeys:
            print(f'  MISSING {mid}')
            continue
        # find object (key may be Sym)
        obj = None
        for k, v in moves.items():
            if S(k) == mid:
                obj = v; break
        iv = obj.iv
        print(f'  {mid}: pow={iv.get("@power")} acc={iv.get("@accuracy")} '
              f'type={S(iv.get("@type"))} cat={iv.get("@category")} '
              f'ec={iv.get("@effect_chance")} fn={iv.get("@function_code")!r} '
              f'flags={[S(f) for f in (iv.get("@flags") or [])]}')

    print('=== LEARN MOVE IDS (existence) ===')
    miss = [m for m in LEARN_MOVE_IDS if m not in mkeys]
    print('  MISSING:', miss if miss else 'none')

    print('=== SPECIES IDS ===')
    smiss = [s for s in SPECIES_IDS if s not in skeys]
    print('  MISSING base species:', smiss if smiss else 'none')
    # list all form keys that start with these (e.g. BLASTOISE_1)
    forms = {}
    for k in skeys:
        base = k.split('_')[0]
        if base in SPECIES_IDS and '_' in k:
            forms.setdefault(base, []).append(k)
    print('  forms:', {k: sorted(v) for k, v in sorted(forms.items())})

if __name__ == '__main__':
    main()
