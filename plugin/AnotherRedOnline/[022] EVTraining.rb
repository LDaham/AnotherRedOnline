#===============================================================================
# Another Red Online — [022] EV Training (Pokémon Champions-style SP allocator)
#-------------------------------------------------------------------------------
# Adds an EV-adjustment service reached from the Pokémon Center extra-service NPC
# (a "노력치 조정" choice injected below "미라클교환" by tools/patch_maps.py). The
# NPC's chosen branch runs the global method `pbEVTrainingService`, which lets the
# player pick a party Pokémon and redistribute its EVs. The same screen also lets
# the player change the Pokémon's NATURE, and previews every stat at the online
# battle basis (Lv50 / 6V) so the numbers match the actual match.
#
# Distribution follows Pokémon Champions' spec: a budget of 66 Stat Points (SP),
# max 32 SP per stat, where 1 SP = 8 EV. So a maxed stat = 256 EV and a full
# spread = 528 EV total — ABOVE the engine's 252/510 caps. The online integrity
# check ([005]) raises its ceilings to 256/528 (ONLINE_EV_STAT_LIMIT / _LIMIT) to
# match, so SP-trained teams stay valid in online battles. Both peers run this
# identical baked build, so the higher caps are deterministic (EVs are static
# data folded into the shared stat calc — no RNG, no desync).
#
# This is an ordinary single-player save edit (like a vitamin/EV trainer); it does
# NOT touch battle lockstep. Presentation only during the UI.
#===============================================================================

module AREVTrain
  SP_TOTAL   = 66    # Champions budget per Pokémon
  SP_PERSTAT = 32    # Champions per-stat cap
  EV_PER_SP  = 8     # 1 SP -> 8 EV

  # Online battle normalization ([005] TeamSerial): every mon is forced to Lv50
  # with all IVs = 31 (6V). The allocator's stat preview mirrors these so the
  # numbers shown match exactly what the Pokémon's stats will be in an online
  # battle (the player's real level/IVs are irrelevant to the match).
  BATTLE_LEVEL = 50
  BATTLE_IV    = 31

  # Display order matches the Champions screen: HP, Atk, Def, SpA, SpD, Spe.
  STATS  = [:HP, :ATTACK, :DEFENSE, :SPECIAL_ATTACK, :SPECIAL_DEFENSE, :SPEED]
  LABELS = ["HP", "공격", "방어", "특수공격", "특수방어", "스피드"]

  module_function

  # Nearest SP for an existing EV value, clamped to the per-stat cap.
  def ev_to_sp(ev)
    sp = (ev.to_i + EV_PER_SP / 2) / EV_PER_SP
    sp = SP_PERSTAT if sp > SP_PERSTAT
    sp = 0 if sp < 0
    sp
  end
end

#===============================================================================
# Raise the engine's EV caps to the Champions budget (256/stat, 528 total).
#
# A maxed SP spread here writes 256 EV into a stat, but vanilla Essentials caps a
# stat at Pokemon::EV_STAT_LIMIT (252) and the total at EV_LIMIT (510). When a
# Pokémon whose stat already holds 256 EV later gains EVs in an ordinary battle,
# pbGainEVsOne does `evYield.clamp(0, EV_STAT_LIMIT - pkmn.ev[s])` = clamp(0, -4),
# and Ruby's clamp raises "min argument must be smaller than max argument".
#
# The whole mod is Champions-based (single + online), and the online validator
# ([005]) already accepts 256/528, so aligning the engine caps to match is the
# consistent fix: every EV path (battle gain, vitamins, debug) now respects the
# same ceilings, and negative clamp maxima can no longer occur. Constants are
# static and identical on both peers, so this is deterministic (online battles
# don't gain EVs at all — internalBattle=false).
if defined?(Pokemon)
  if !Pokemon.const_defined?(:EV_STAT_LIMIT) || Pokemon::EV_STAT_LIMIT != AREVTrain::SP_PERSTAT * AREVTrain::EV_PER_SP
    Pokemon.send(:remove_const, :EV_STAT_LIMIT) if Pokemon.const_defined?(:EV_STAT_LIMIT)
    Pokemon.const_set(:EV_STAT_LIMIT, AREVTrain::SP_PERSTAT * AREVTrain::EV_PER_SP)   # 256
  end
  if !Pokemon.const_defined?(:EV_LIMIT) || Pokemon::EV_LIMIT != AREVTrain::SP_TOTAL * AREVTrain::EV_PER_SP
    Pokemon.send(:remove_const, :EV_LIMIT) if Pokemon.const_defined?(:EV_LIMIT)
    Pokemon.const_set(:EV_LIMIT, AREVTrain::SP_TOTAL * AREVTrain::EV_PER_SP)          # 528
  end
end

#===============================================================================
# Allocation scene — drawn on an overlay above the party screen.
#===============================================================================
class EVTrainingScene
  BASE   = Color.new(248, 248, 248)
  SHADOW = Color.new(40, 40, 72)
  SEL    = Color.new(128, 240, 128)
  PANEL  = Color.new(24, 24, 48, 232)
  DIM    = Color.new(0, 0, 0, 160)
  BARBG  = Color.new(48, 48, 80)
  BARFG  = Color.new(248, 200, 72)
  UPCOL  = Color.new(248, 96, 96)     # nature-raised stat (red)
  DNCOL  = Color.new(104, 152, 248)   # nature-lowered stat (blue)

  def initialize(pkmn)
    @pkmn = pkmn
    @sp = AREVTrain::STATS.map { |sid| AREVTrain.ev_to_sp((pkmn.ev[sid] || 0)) }
    trim_to_total!
    # Nature is editable too. Build the ordered id list and locate the current one.
    # NOTE: GameData::Nature.each in v21 yields directly (no enum_for), so it MUST
    # be called with a block — `.each.map` raises and would leave the list empty.
    @natures = []
    begin
      GameData::Nature.each { |n| @natures << n.id }
    rescue Exception
      @natures = []
    end
    cur = (pkmn.nature ? pkmn.nature.id : nil) rescue nil
    @nat_idx = (@natures.index(cur) || 0)
    @sel = 0                      # 0..STATS-1 = stat rows, STATS = nature row
    @rows = AREVTrain::STATS.length + 1
    @applied = false
  end

  def total;     @sp.inject(0) { |a, b| a + b }; end
  def remaining; AREVTrain::SP_TOTAL - total;     end
  def nature_row?; @sel == AREVTrain::STATS.length; end

  def current_nature_id;   @natures[@nat_idx]; end
  def current_nature_name
    id = current_nature_id
    return "-" unless id
    (GameData::Nature.get(id).name rescue id.to_s)
  end

  # { stat_id => :up / :down } for the currently selected nature (neutral omitted).
  def nature_mods
    res = {}
    id  = current_nature_id
    return res unless id
    nat = (GameData::Nature.get(id) rescue nil)
    return res unless nat && nat.respond_to?(:stat_changes) && nat.stat_changes
    nat.stat_changes.each do |sc|
      stat = sc[0]; val = sc[1].to_i
      next if val == 0
      res[stat] = (val > 0 ? :up : :down)
    end
    res
  rescue
    {}
  end

  # Pre-existing EVs could round above the 66 budget — shave the largest stats.
  def trim_to_total!
    guard = 0
    while total > AREVTrain::SP_TOTAL && guard < 999
      i = @sp.index(@sp.max)
      @sp[i] -= 1
      guard += 1
    end
  end

  def start
    @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
    @viewport.z = 99999
    @back = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
    @back.bitmap.fill_rect(0, 0, Graphics.width, Graphics.height, DIM)
    @overlay = BitmapSprite.new(Graphics.width, Graphics.height, @viewport)
    pbSetSystemFont(@overlay.bitmap)
    refresh
  end

  # Preview the actual stats these SP would produce, at the ONLINE battle basis
  # (Lv50, all IVs 31) with the currently selected nature — so the numbers shown
  # equal the mon's real in-battle stats. Uses a throwaway clone; iv/ev/nature are
  # reassigned to fresh values so the original save Pokémon is never mutated here.
  def preview_stats
    test = @pkmn.clone
    test.level = AREVTrain::BATTLE_LEVEL if test.respond_to?(:level=)
    iv = {}; ev = {}
    AREVTrain::STATS.each_with_index do |sid, i|
      iv[sid] = AREVTrain::BATTLE_IV
      ev[sid] = @sp[i] * AREVTrain::EV_PER_SP
    end
    test.iv = iv if test.respond_to?(:iv=)
    test.ev = ev
    test.nature = current_nature_id if current_nature_id && test.respond_to?(:nature=)
    test.calc_stats
    [test.totalhp, test.attack, test.defense, test.spatk, test.spdef, test.speed]
  rescue
    AREVTrain::STATS.map { 0 }
  end

  def refresh
    b = @overlay.bitmap
    b.clear
    w = Graphics.width; h = Graphics.height
    b.fill_rect(16, 16, w - 32, h - 32, PANEL)
    stats = preview_stats
    tp = []
    tp.push([_INTL("노력치 조정 — {1}  (Lv.50 기준)", @pkmn.name), 32, 22, 0, BASE, SHADOW])
    tp.push([_INTL("능력 포인트"), 32, 52, 0, BASE, SHADOW])
    tp.push([sprintf("%d / %d", total, AREVTrain::SP_TOTAL), w - 32, 52, 1, BASE, SHADOW])
    mods = nature_mods
    y = 88
    AREVTrain::STATS.each_with_index do |sid, i|
      col = (i == @sel) ? SEL : BASE
      # Stat value is tinted by the nature: raised = red, lowered = blue.
      vcol = case mods[sid]
             when :up   then UPCOL
             when :down then DNCOL
             else col
             end
      tp.push([AREVTrain::LABELS[i], 40, y, 0, col, SHADOW])
      tp.push([stats[i].to_s, 214, y, 1, vcol, SHADOW])
      bx = 232; bw = 168; bh = 16
      b.fill_rect(bx, y + 6, bw, bh, BARBG)
      fw = (bw * @sp[i] / AREVTrain::SP_PERSTAT.to_f).to_i
      b.fill_rect(bx, y + 6, fw, bh, BARFG) if fw > 0
      tp.push([@sp[i].to_s, bx + bw + 34, y, 1, col, SHADOW])
      y += 38
    end
    ncol = nature_row? ? SEL : BASE
    ntxt = nature_row? ? _INTL("◀ {1} ▶", current_nature_name) : current_nature_name
    tp.push([_INTL("성격"), 40, y + 6, 0, ncol, SHADOW])
    tp.push([ntxt, 214, y + 6, 0, ncol, SHADOW])
    tp.push([_INTL("좌우:조정/성격  상하:선택  L:최소 R:최대  A:결정 B:취소"),
             32, h - 40, 0, BASE, SHADOW])
    pbDrawTextPositions(b, tp)
  end

  def adjust(i, d)
    if d > 0
      return false if @sp[i] >= AREVTrain::SP_PERSTAT || remaining <= 0
      @sp[i] += 1
    else
      return false if @sp[i] <= 0
      @sp[i] -= 1
    end
    true
  end

  def run
    start
    loop do
      Graphics.update
      Input.update
      if Input.trigger?(Input::BACK)
        break
      elsif Input.trigger?(Input::USE)
        apply
        @applied = true
        pbPlayDecisionSE
        break
      elsif Input.trigger?(Input::UP)
        @sel = (@sel - 1) % @rows
        pbPlayCursorSE; refresh
      elsif Input.trigger?(Input::DOWN)
        @sel = (@sel + 1) % @rows
        pbPlayCursorSE; refresh
      elsif Input.repeat?(Input::LEFT)
        if nature_row?
          cycle_nature(-1); pbPlayCursorSE
        else
          pbPlayCursorSE if adjust(@sel, -1)
        end
        refresh
      elsif Input.repeat?(Input::RIGHT)
        if nature_row?
          cycle_nature(1); pbPlayCursorSE
        else
          pbPlayCursorSE if adjust(@sel, 1)
        end
        refresh
      elsif Input.trigger?(Input::JUMPDOWN)   # L = MIN (stat rows only)
        unless nature_row?
          @sp[@sel] = 0
          pbPlayDecisionSE
        end
        refresh
      elsif Input.trigger?(Input::JUMPUP)      # R = MAX (cap or remaining budget)
        unless nature_row?
          @sp[@sel] = [AREVTrain::SP_PERSTAT, @sp[@sel] + remaining].min
          pbPlayDecisionSE
        end
        refresh
      end
    end
    dispose
    @applied
  end

  def cycle_nature(d)
    return if @natures.empty?
    @nat_idx = (@nat_idx + d) % @natures.length
  end

  def apply
    AREVTrain::STATS.each_with_index do |sid, i|
      @pkmn.ev[sid] = @sp[i] * AREVTrain::EV_PER_SP
    end
    @pkmn.nature = current_nature_id if current_nature_id && @pkmn.respond_to?(:nature=)
    @pkmn.calc_stats
  end

  def dispose
    @overlay.dispose if @overlay
    @back.dispose    if @back
    @viewport.dispose if @viewport
  end
end

#===============================================================================
# Entry point (called from the injected NPC menu choice via an event Script cmd).
#===============================================================================
def pbEVTrainingService
  if !$player || !$player.party || $player.party.length == 0
    pbMessage(_INTL("포켓몬이 없습니다.")) rescue nil
    return
  end
  pbFadeOutIn {
    scene  = PokemonParty_Scene.new
    screen = PokemonPartyScreen.new(scene, $player.party)
    screen.pbStartScene(_INTL("노력치를 조정할 포켓몬을 고르세요."), false)
    loop do
      idx = screen.pbChoosePokemon
      break if idx < 0
      pkmn = $player.party[idx]
      if !pkmn || pkmn.egg?
        screen.pbDisplay(_INTL("고를 수 없는 포켓몬입니다."))
        next
      end
      applied = EVTrainingScene.new(pkmn).run
      (screen.pbHardRefresh rescue nil)
      screen.pbDisplay(_INTL("{1}의 노력치를 조정했습니다.", pkmn.name)) if applied
    end
    screen.pbEndScene
  }
end
