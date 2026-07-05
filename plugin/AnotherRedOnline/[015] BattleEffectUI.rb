#===============================================================================
# Another Red Online — Battle effectiveness & stat-change HUD  [015]
#
# Two purely-cosmetic battle overlays. UNLIKE the rest of this plugin these are
# NOT gated on $arnet — they run in EVERY battle, single-player and online alike
# (the user asked for them in both).
#
#   (1) Move type-effectiveness hint
#         Singles: just the effectiveness SYMBOL, in each move box's top-right
#                  corner (no box, no phrase — barely intrudes on the menu).
#         Doubles: a tag (symbol + phrase) above each candidate target's data box
#                  during target selection (the Fight menu can't know which foe
#                  you'll pick, so the hint moves there — 더블배틀 효과 표시.png).
#       Only shown for damaging moves that can hit a foe. Status moves (weather,
#       self-buffs, stat moves, …) show nothing, per spec.
#
#         ×4   ☆ 효과가 매우 굉장함      ×0.5  △ 효과가 별로
#         ×2   ◎ 효과가 굉장함          ×0.25 ▽ 효과가 매우 별로
#         ×1   ○ 효과 있음              ×0    ✕ 효과 없음
#
#   (2) Stat-stage change popup
#         When a battler's stat stage changes, a "<stat> <triangles>" tag flashes
#         beside that battler for the duration of the StatUp/StatDown animation
#         (▲ red = net raised, ▼ blue = net lowered; count = |accumulated stage|).
#         Moves that change several stats at once (Quiver Dance, …) show one row
#         per stat inside a single box.
#         Ally tags hug the near side, foe tags the far side — see 능력치 변화.png.
#
# All of this only READS battle state and DRAWS: no RNG draw, no state mutation,
# so it stays lockstep-deterministic. Every tag anchors to the LIVE sprite / data
# box position, so the guest camera mirror ([012]) is handled for free — a tag
# lands on whichever side that battler is actually drawn on.
#
# Loads last (30th plugin), so Battle / Battle::Battler / Battle::Move and the DBK
# Battle::Scene::FightMenu already exist and our aliases wrap the final versions.
#===============================================================================

module ARNet
  # --- effectiveness tier -> [symbol, phrase, base color] ----------------------
  # `mult` is the 1.0-based multiplier from pbCalcTypeMod (0, .25, .5, 1, 2, 4).
  FX_COL_IMMUNE  = Color.new(184, 184, 184)
  FX_COL_RESIST  = Color.new(104, 168, 240)
  FX_COL_NEUTRAL = Color.new(248, 248, 248)
  FX_COL_SUPER   = Color.new(248, 96, 96)
  FX_COL_SHADOW  = Color.new(16, 16, 24)
  FX_COL_UP      = Color.new(240, 64, 64)    # raised stat  ▲ (red)
  FX_COL_DOWN    = Color.new(80, 128, 248)   # lowered stat ▼ (blue)

  def self.fx_effect_tier(mult)
    return nil if mult.nil?
    if    mult <= 0.0  then ["✕", "효과 없음",          FX_COL_IMMUNE]
    elsif mult < 0.375 then ["▽", "효과가 매우 별로",   FX_COL_RESIST]   # 0.25
    elsif mult < 0.75  then ["△", "효과가 별로",        FX_COL_RESIST]   # 0.5
    elsif mult < 1.5   then ["○", "효과 있음",          FX_COL_NEUTRAL]  # 1
    elsif mult < 3.0   then ["◎", "효과가 굉장함",      FX_COL_SUPER]    # 2
    else                    ["☆", "효과가 매우 굉장함", FX_COL_SUPER]    # 4
    end
  end

  # Type multiplier of `move` (as `user` would use it) against `target`, or nil
  # when no hint should be shown (non-damaging move, no/fainted target, error).
  def self.fx_move_mult(user, move, target)
    return nil unless user && move && target
    return nil if target.fainted?
    return nil unless move.damagingMove?
    mtype = (move.pbCalcType(user) rescue nil)
    mtype = move.type if mtype.nil?
    return nil if mtype.nil?
    raw = (move.pbCalcTypeMod(mtype, user, target) rescue nil)
    return nil if raw.nil?
    norm = (Effectiveness::NORMAL_EFFECTIVE_MULTIPLIER.to_f rescue 1.0)
    norm = 1.0 if norm <= 0
    raw.to_f / norm
  end

  # Turn a flat [stat, amount, stat, amount, ...] array (as stored on multi-stat
  # move classes) into popup rows [[stat_id, projected_stage], ...]. `base` is the
  # battler's stages BEFORE the move applies, so projected == final accumulated
  # stage even for stats the engine hasn't touched yet when the (single) StatUp/
  # StatDown animation fires. Zero-net rows are dropped.
  def self.fx_rows_from_array(battler, arr, is_raise)
    return [] unless battler && arr.is_a?(Array) && arr.length >= 2
    base = (battler.stages rescue {})
    rows = []
    i = 0
    while i + 1 < arr.length
      stat = arr[i]
      amt  = arr[i + 1]
      if (stat.is_a?(Symbol) || stat.is_a?(String)) && amt.is_a?(Integer)
        b = (base[stat] || 0)
        proj = is_raise ? b + amt.abs : b - amt.abs
        proj =  6 if proj >  6
        proj = -6 if proj < -6
        rows << [stat, proj] unless proj == 0
      end
      i += 2
    end
    rows
  end

  # --- floating tag sprite (target hints + stat popups) ------------------------
  # segments = [[text, color], ...] drawn left-to-right on a translucent bar.
  # Returns a Sprite (its private viewport rides along; fx_dispose frees both).
  FX_TAG_FONT = 20
  def self.fx_bar_sprite(segments, z: 250000)
    scratch = Bitmap.new(1, 1)
    (pbSetSystemFont(scratch) rescue nil)
    scratch.font.size = FX_TAG_FONT
    widths = segments.map { |txt, _| scratch.text_size(txt).width }
    scratch.dispose
    pad = 8
    w = [widths.inject(0, :+) + pad * 2, 2].max
    h = FX_TAG_FONT + pad
    vp = Viewport.new(0, 0, Graphics.width, Graphics.height)
    vp.z = z
    spr = Sprite.new(vp)
    spr.bitmap = Bitmap.new(w, h)
    bmp = spr.bitmap
    (pbSetSystemFont(bmp) rescue nil)
    bmp.font.size = FX_TAG_FONT
    bmp.fill_rect(0, 0, w, h, Color.new(24, 24, 48, 200))
    bmp.fill_rect(0, 0, w, 2, Color.new(96, 96, 160, 220))
    bmp.fill_rect(0, h - 2, w, 2, Color.new(8, 8, 24, 220))
    x = pad
    segments.each_with_index do |(txt, col), i|
      bw = widths[i] + 4
      bmp.font.color = FX_COL_SHADOW
      bmp.draw_text(x + 2, (pad / 2) + 2, bw, FX_TAG_FONT, txt)
      bmp.font.color = col
      bmp.draw_text(x, pad / 2, bw, FX_TAG_FONT, txt)
      x += widths[i]
    end
    spr.instance_variable_set(:@arnet_vp, vp)
    spr
  end

  # Like fx_bar_sprite but stacks several rows in ONE box: lines = [segments, ...].
  # Used so a move that changes multiple stats (e.g. Quiver Dance) shows one row
  # per stat inside a single wrapping bar.
  def self.fx_bars_sprite(lines, z: 250000)
    return fx_bar_sprite(lines[0], z: z) if lines.length == 1
    scratch = Bitmap.new(1, 1)
    (pbSetSystemFont(scratch) rescue nil)
    scratch.font.size = FX_TAG_FONT
    # Per-column max width so segments align vertically down the box — e.g. every
    # triangle starts at the same x even when the stat names differ in width
    # (특수공격/특수방어/스피드).
    ncol  = lines.map(&:length).max
    col_w = Array.new(ncol, 0)
    lines.each do |segs|
      segs.each_with_index do |(t, _), ci|
        tw = scratch.text_size(t).width
        col_w[ci] = tw if tw > col_w[ci]
      end
    end
    scratch.dispose
    pad   = 8
    row_h = FX_TAG_FONT + pad
    w = [col_w.inject(0, :+) + pad * 2, 2].max
    h = row_h * lines.length
    vp = Viewport.new(0, 0, Graphics.width, Graphics.height)
    vp.z = z
    spr = Sprite.new(vp)
    spr.bitmap = Bitmap.new(w, h)
    bmp = spr.bitmap
    (pbSetSystemFont(bmp) rescue nil)
    bmp.font.size = FX_TAG_FONT
    bmp.fill_rect(0, 0, w, h, Color.new(24, 24, 48, 200))
    bmp.fill_rect(0, 0, w, 2, Color.new(96, 96, 160, 220))
    bmp.fill_rect(0, h - 2, w, 2, Color.new(8, 8, 24, 220))
    lines.each_with_index do |segs, li|
      y0 = li * row_h + (pad / 2)
      segs.each_with_index do |(txt, col), ci|
        x = pad + col_w[0, ci].inject(0, :+)
        bmp.font.color = FX_COL_SHADOW
        bmp.draw_text(x + 2, y0 + 2, col_w[ci] + 4, FX_TAG_FONT, txt)
        bmp.font.color = col
        bmp.draw_text(x, y0, col_w[ci] + 4, FX_TAG_FONT, txt)
      end
    end
    spr.instance_variable_set(:@arnet_vp, vp)
    spr
  end

  def self.fx_dispose(tags)
    Array(tags).compact.each do |s|
      vp = (s.instance_variable_get(:@arnet_vp) rescue nil)
      s.bitmap.dispose if s.bitmap && !s.bitmap.disposed?
      s.dispose unless s.disposed?
      vp.dispose if vp && !vp.disposed?
    end
  end

  def self.fx_scene_sprites(battle)
    scene = (battle.scene rescue nil)
    return nil unless scene
    (scene.instance_variable_get(:@sprites) rescue nil)
  end

  # (1b) Doubles: a tag above each eligible foe's data box for the chosen move.
  def self.fx_target_labels(battle, user, move)
    return [] unless move && (move.damagingMove? rescue false)
    sprites = fx_scene_sprites(battle)
    return [] unless sprites
    tags = []
    foes = (battle.allOtherSideBattlers(user.index) rescue [])
    foes.each do |foe|
      next if foe.nil? || foe.fainted?
      tier = fx_effect_tier(fx_move_mult(user, move, foe))
      next if tier.nil?
      box = sprites["dataBox_#{foe.index}"]
      next if box.nil? || (box.disposed? rescue true)
      sym, phrase, col = tier
      spr = fx_bar_sprite([["#{sym} #{phrase}", col]])
      spr.ox = 0
      spr.oy = 0
      spr.x = [box.x + 6, 0].max
      spr.y = box.y - spr.bitmap.height - 2
      tags << spr
    end
    tags
  rescue
    fx_dispose(tags) if tags
    []
  end

  # (2) A "<stat> <triangles>" tag beside `battler`. `rows` is a list of
  # [stat_id, stage] where a nil stage means "read the live accumulated stage"
  # (single-stat path); a set stage is a precomputed projection (multi-stat
  # moves, whose later stats aren't applied yet when the animation fires). One
  # bar row per changing stat. Returned so the caller can dispose it after.
  def self.fx_stat_popup(battle, battler, rows)
    return nil unless battler && rows.is_a?(Array) && !rows.empty?
    lines = []
    rows.each do |stat, stage|
      next unless stat
      stage = (battler.stages[stat].to_i rescue 0) if stage.nil?
      next if stage == 0
      name = (GameData::Stat.get(stat).name rescue stat.to_s)
      up   = stage > 0
      tri  = (up ? "▲" : "▼") * [stage.abs, 6].min
      lines << [["#{name} ", FX_COL_NEUTRAL], [tri, up ? FX_COL_UP : FX_COL_DOWN]]
    end
    return nil if lines.empty?
    sprites = fx_scene_sprites(battle)
    return nil unless sprites
    spr_p = sprites["pokemon_#{battler.index}"]
    return nil if spr_p.nil? || (spr_p.disposed? rescue true) || spr_p.bitmap.nil?
    spr = fx_bars_sprite(lines)
    # Anchor to the live battler sprite (bottom-centre origin): tag sits at ~mid
    # height, hugging the sprite's near edge. on_left uses the ACTUAL screen x so
    # the guest mirror puts ally/foe tags on the correct visual side.
    mid_y = spr_p.y - ((spr_p.oy > 0 ? spr_p.oy : (spr_p.bitmap.height rescue 0)) / 2)
    on_left = spr_p.x < (Graphics.width / 2)
    spr.oy = spr.bitmap.height / 2
    spr.y  = mid_y
    if on_left
      spr.ox = spr.bitmap.width   # ally: grow left from the sprite centre
      spr.x  = spr_p.x
      # Clamp: ensure the left edge (x - ox) doesn't go off-screen
      spr.x  = spr.ox if spr.x - spr.ox < 0
    else
      spr.ox = 0                  # foe: grow right from the sprite centre
      spr.x  = spr_p.x
      # Clamp: ensure the right edge (x + width) doesn't go off-screen
      max_x  = Graphics.width - spr.bitmap.width
      spr.x  = max_x if spr.x > max_x
    end
    spr
  rescue
    nil
  end
end

#===============================================================================
# (1a) Singles: effectiveness SYMBOL only, in each move box's top-right corner.
#      No box, no phrase — just the glyph so it barely intrudes on the menu.
#===============================================================================
class Battle::Scene::FightMenu < Battle::Scene::MenuBase
  FX_SYM_FONT = 20   # the effectiveness glyph on its own reads fine this size
  FX_SYM_PADX = 6    # px in from the move box's right edge
  FX_SYM_PADY = 2    # px down from the move box's top edge

  alias_method :arnet_fx_orig_refreshButtonNames, :refreshButtonNames
  def refreshButtonNames
    arnet_fx_orig_refreshButtonNames
    arnet_fx_draw_move_effects
  rescue
    # never let a cosmetic overlay break the command menu
  end

  def arnet_fx_draw_move_effects
    return unless @battler && @overlay && @overlay.bitmap
    battle = (@battler.battle rescue nil)
    return unless battle && (battle.singleBattle? rescue false)
    foe = (@battler.pbDirectOpposing(true) rescue nil)
    return if foe.nil? || foe.fainted?
    moves = @battler.moves
    bmp = @overlay.bitmap
    old_size = bmp.font.size
    bmp.font.size = FX_SYM_FONT
    text_pos = []
    @buttons.each_with_index do |button, i|
      next if button.nil?
      next if !@visibility["button_#{i}"]
      move = moves[i]
      next if move.nil? || move.id.nil?
      tier = ARNet.fx_effect_tier(ARNet.fx_move_mult(@battler, move, foe))
      next if tier.nil?
      sym, _phrase, col = tier
      # Symbol only, right-aligned to the move box's top-right corner (no box).
      x = button.x - self.x + button.src_rect.width - FX_SYM_PADX
      y = button.y - self.y + FX_SYM_PADY
      text_pos.push([sym, x, y, :right, col, ARNet::FX_COL_SHADOW])
    end
    pbDrawTextPositions(bmp, text_pos) unless text_pos.empty?
    bmp.font.size = old_size
  end
end

#===============================================================================
# (1b) Doubles: wrap the BATTLE-level target picker to stash the current move,
#      then wrap SCENE-level pbChooseTarget to pass it to the TargetMenu.
#===============================================================================
class Battle
  alias_method :arnet_fx_orig_pbChooseTarget, :pbChooseTarget
  def pbChooseTarget(battler, move, *args, &blk)
    @arnet_fx_current_move = move
    begin
      arnet_fx_orig_pbChooseTarget(battler, move, *args, &blk)
    ensure
      @arnet_fx_current_move = nil
    end
  end
end

class Battle::Scene
  unless method_defined?(:arnet_fx_orig_pbChooseTarget)
    alias_method :arnet_fx_orig_pbChooseTarget, :pbChooseTarget
  end
  def pbChooseTarget(idxBattler, target_data, visibleSprites = nil)
    cw = @sprites["targetWindow"]
    if cw
      cw.instance_variable_set(:@arnet_fx_battler, @battle.battlers[idxBattler])
      cw.instance_variable_set(:@arnet_fx_move, @battle.instance_variable_get(:@arnet_fx_current_move))
      cw.instance_variable_set(:@arnet_fx_battle, @battle)
    end
    begin
      arnet_fx_orig_pbChooseTarget(idxBattler, target_data, visibleSprites)
    ensure
      if cw
        cw.instance_variable_set(:@arnet_fx_battler, nil)
        cw.instance_variable_set(:@arnet_fx_move, nil)
        cw.instance_variable_set(:@arnet_fx_battle, nil)
      end
    end
  end
end

class Battle::Scene::TargetMenu
  unless method_defined?(:arnet_fx_orig_refreshButtons)
    alias_method :arnet_fx_orig_refreshButtons, :refreshButtons
  end
  def refreshButtons
    arnet_fx_orig_refreshButtons
    arnet_fx_draw_symbols
  rescue
  end

  def arnet_fx_draw_symbols
    battler = @arnet_fx_battler
    move = @arnet_fx_move
    battle = @arnet_fx_battle
    return unless battler && move && battle && move.damagingMove?
    
    bmp = @overlay.bitmap
    old_size = bmp.font.size
    bmp.font.size = Battle::Scene::FightMenu::FX_SYM_FONT
    text_pos = []
    
    @buttons.each_with_index do |button, i|
      next if !button || nil_or_empty?(@texts[i])
      foe = battle.battlers[i]
      next if foe.nil? || foe.fainted?
      next if foe.index == battler.index
      
      tier = ARNet.fx_effect_tier(ARNet.fx_move_mult(battler, move, foe))
      next if tier.nil?
      sym, _phrase, col = tier
      
      x = button.x - self.x + button.src_rect.width - Battle::Scene::FightMenu::FX_SYM_PADX
      y = button.y - self.y + Battle::Scene::FightMenu::FX_SYM_PADY
      text_pos.push([sym, x, y, :right, col, ARNet::FX_COL_SHADOW])
    end
    pbDrawTextPositions(bmp, text_pos) unless text_pos.empty?
    bmp.font.size = old_size
  end
end

class Battle
  #-----------------------------------------------------------------------------
  # (2) Show the stat popup for the duration of the StatUp/StatDown animation.
  #     Prefer @arnet_fx_stats (full list from a multi-stat move, precomputed so
  #     every changed stat gets a row); fall back to the single stashed stat.
  #-----------------------------------------------------------------------------
  alias_method :arnet_fx_orig_pbCommonAnimation, :pbCommonAnimation
  def pbCommonAnimation(name, user = nil, targets = nil)
    tag = nil
    if user && (name == "StatUp" || name == "StatDown")
      rows = @arnet_fx_stats
      rows = [[@arnet_fx_stat, nil]] if (rows.nil? || rows.empty?) && @arnet_fx_stat
      tag = (ARNet.fx_stat_popup(self, user, rows) rescue nil) if rows && !rows.empty?
    end
    arnet_fx_orig_pbCommonAnimation(name, user, targets)
  ensure
    ARNet.fx_dispose([tag]) if tag
  end
end

#===============================================================================
# (2) Stash which stat is changing so pbCommonAnimation can label it. All four
#     entry points take `stat` first; wrap them uniformly and always restore.
#===============================================================================
class Battle::Battler
  [:pbRaiseStatStage, :pbRaiseStatStageByCause,
   :pbLowerStatStage, :pbLowerStatStageByCause].each do |m|
    alias_method "arnet_fx_orig_#{m}", m
    define_method(m) do |stat, *args, &blk|
      prev = (@battle.instance_variable_get(:@arnet_fx_stat) rescue nil)
      (@battle.instance_variable_set(:@arnet_fx_stat, stat) rescue nil)
      begin
        send("arnet_fx_orig_#{m}", stat, *args, &blk)
      ensure
        (@battle.instance_variable_set(:@arnet_fx_stat, prev) rescue nil)
      end
    end
  end
end

#===============================================================================
# (2) Multi-stat moves (e.g. Quiver Dance) loop pbRaiseStatStage but only play
#     the StatUp/StatDown animation ONCE, so the popup would otherwise show just
#     the first stat. Capture the WHOLE stat list from the move's @statUp/
#     @statDown BEFORE the effect runs (stages snapshot = correct projections)
#     and stash it as @arnet_fx_stats for pbCommonAnimation to render row-by-row.
#===============================================================================
if defined?(Battle::Move::MultiStatUpMove) &&
   Battle::Move::MultiStatUpMove.method_defined?(:pbEffectGeneral)
  class Battle::Move::MultiStatUpMove
    alias_method :arnet_fx_orig_pbEffectGeneral, :pbEffectGeneral
    def pbEffectGeneral(user)
      rows = (ARNet.fx_rows_from_array(user, (@statUp rescue nil), true) rescue [])
      prev = (@battle.instance_variable_get(:@arnet_fx_stats) rescue nil) unless rows.empty?
      (@battle.instance_variable_set(:@arnet_fx_stats, rows) rescue nil) unless rows.empty?
      begin
        arnet_fx_orig_pbEffectGeneral(user)
      ensure
        (@battle.instance_variable_set(:@arnet_fx_stats, prev) rescue nil) unless rows.empty?
      end
    end
  end
end

if defined?(Battle::Move::TargetMultiStatDownMove) &&
   Battle::Move::TargetMultiStatDownMove.method_defined?(:pbEffectAgainstTarget)
  class Battle::Move::TargetMultiStatDownMove
    alias_method :arnet_fx_orig_pbEffectAgainstTarget, :pbEffectAgainstTarget
    def pbEffectAgainstTarget(user, target)
      rows = (ARNet.fx_rows_from_array(target, (@statDown rescue nil), false) rescue [])
      prev = (@battle.instance_variable_get(:@arnet_fx_stats) rescue nil) unless rows.empty?
      (@battle.instance_variable_set(:@arnet_fx_stats, rows) rescue nil) unless rows.empty?
      begin
        arnet_fx_orig_pbEffectAgainstTarget(user, target)
      ensure
        (@battle.instance_variable_set(:@arnet_fx_stats, prev) rescue nil) unless rows.empty?
      end
    end
  end
end
