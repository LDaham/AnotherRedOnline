#===============================================================================
# Another Red Online — protocol constants & helpers
# Wire format mirrors server/protocol.js. See PROTOCOL.md.
#===============================================================================
# NOTE: `json` and `securerandom` are NOT shippable in this mkxp-z build
# (no pure-Ruby stdlib). They are provided by [000] NetBundle.rb, which loads
# first. `digest` is a native ext and loads fine.
require 'digest'

module ARNet
  PROTO       = 1
  # Mod version — MUST match plugin/AnotherRedOnline/meta.txt (and the update
  # manifest built by tools/build_dist.py). Peers exchange this in the handshake
  # and refuse to battle across different mod versions: differing battle logic
  # would desync mid-match. The .bat launcher keeps everyone on the latest, so a
  # mismatch should be rare — bump this together with meta.txt on every release.
  MOD_VERSION = "0.1.0"
  MAX_FRAME   = 64 * 1024
  DEFAULT_PORT = 8787
  # 배포한 VPS 릴레이의 공인 IP(또는 도메인). 서버를 띄운 뒤 이 한 줄만 바꾸면 된다.
  # 로컬 테스트는 "127.0.0.1". 배포 절차는 프로젝트 루트 DEPLOY.md 참고.
  DEFAULT_HOST = "217.142.253.174"   # Oracle Cloud Always Free 릴레이

  # Battle backdrop for online matches (no map => must be set explicitly, else
  # black). Must be a Graphics/Battlebacks/<name>_bg set. See [010] BattleLauncher.
  # "pwt" = Pokémon World Tournament stadium (platforms baked into _bg; no
  # separate _base0/_base1 — the engine just skips the platform sprites).
  BATTLE_BACKDROP = "pwt"

  # Battle BGM for online matches. Online battles bypass the overworld encounter
  # path (pbBattleAnimation), so no battle music is played and whatever was
  # playing (PC/Center BGM) keeps looping — [010] plays this explicitly instead.
  # File must exist as Audio/BGM/<name>.ogg in the game folder.
  # NOTE: audio must be Ogg VORBIS (this mkxp-z build does NOT decode Ogg Opus —
  # Opus files load without error but play silent). Both online BGMs ship as mod
  # assets (plugin/.../assets/Audio/BGM), deployed by the baker.
  BATTLE_BGM = "Arena Battle"

  # BGM for the team-selection screen ([013] SelectionScene). Same Vorbis rule.
  SELECT_BGM = "Team Select"

  # Battle formats
  FORMAT_SINGLE3 = "single3"   # pick 3 of 6, single
  FORMAT_DOUBLE4 = "double4"   # pick 4 of 6, double
  FORMAT_FULL6   = "full6"     # all 6, single

  def self.default_ruleset
    {
      "level_cap"      => 50,    # all mons normalized to Lv50 (battle-only)
      "iv_flat"        => 31,    # all IVs forced to 31 / 6V (battle-only)
      "item_clause"    => false,
      "sleep_clause"   => true,
      "species_clause" => true,
      "bag_items"      => false,
      # Chess-clock time controls (seconds). time_bank = per-player total that
      # only ticks during turn selection; time_select = one-off team-preview
      # selection budget; time_turn = per-turn cap (auto-picks a move at 0).
      "time_bank"      => 420,   # 7 min total thinking time per player
      "time_select"    => 90,    # team selection (bring 3/4) budget
      "time_turn"      => 45,    # per-turn selection cap
      "banlist"        => []
    }
  end

  # Number of Pokémon each player brings into battle for a format.
  def self.picks_for(format)
    case format
    when FORMAT_SINGLE3 then 3
    when FORMAT_DOUBLE4 then 4
    else 6
    end
  end

  # Whether a format has a team-preview selection step (pick a subset of 6).
  def self.needs_selection?(format)
    format != FORMAT_FULL6
  end

  # 32-byte random nonce as hex (used for seed derivation + side decision).
  def self.new_nonce
    SecureRandom.hex(32)
  end

  # Deterministic 64-bit battle seed from both peers' nonces.
  # seed = SHA256( min(a,b) || max(a,b) )[0,16] -> integer
  def self.derive_seed(nonce_a, nonce_b)
    lo, hi = [nonce_a, nonce_b].sort
    digest = Digest::SHA256.hexdigest(lo + hi)
    digest[0, 16].to_i(16)
  end

  # Canonical side: smaller nonce = host = side 0.
  # Returns 0 if my_nonce is host, else 1.
  def self.my_side(my_nonce, peer_nonce)
    (my_nonce <= peer_nonce) ? 0 : 1
  end

  # Hash of the agreed ruleset for handshake validation.
  def self.ruleset_hash(ruleset)
    Digest::SHA256.hexdigest(JSON.generate(ruleset))[0, 16]
  end
end
