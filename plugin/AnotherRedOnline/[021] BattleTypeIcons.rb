#===============================================================================
# Another Red Online — [021] Battle Type Icons
#-------------------------------------------------------------------------------
# Draws each battler's current type(s) on its battle databox (always visible),
# and refreshes them live whenever a battler's types change (Terastallization,
# Protean/변환자재, 의태, Reflect Type, Camouflage, Conversion, form changes...).
#
# Placement/sizing follow the "올인원 패치" (all-in-one patch): the icons sit at
# the TOP-RIGHT of the databox (base_x 220 ally / 210 foe, y = 0), drawn 15x15
# and stepping 17px to the left for extra types — this stays clear of the status
# condition icon (which lives by the HP bar).
#
# Icon graphic: the all-in-one patch uses "Graphics/UI/types_short" (28x28 cells,
# text-free). That file is not part of the base game here, so we prefer it when
# present and otherwise fall back to the Terastal crystal set (always shipped).
#
# PURE PRESENTATION: only blits icons onto the databox bitmap, never touches
# battle state or the RNG — safe for deterministic lockstep (no desync) and for
# the guest camera mirror ([012]); the databox is rendered per-side.
#===============================================================================

module ARTypeIcons
  ENABLED   = true
  MAX_TYPES = 3

  # Candidate icon sheets, in priority order: [path, cell_w, cell_h].
  # First one that resolves (pbResolveBitmap) is used.
  SHEETS = [
    ["Graphics/UI/types_short",                      28, 28],   # all-in-one icon
    ["Graphics/Plugins/Terastallization/tera_types", 32, 32]    # fallback crystals
  ]

  # On-databox draw geometry (matches the all-in-one patch).
  DRAW_W      = 15   # drawn icon width
  DRAW_H      = 15   # drawn icon height
  STEP_X      = 17   # leftward advance per additional type
  BASE_X_ALLY = 220  # rightmost icon x on the player's box (even index)
  BASE_X_FOE  = 210  # rightmost icon x on the opponent's box (odd index)
  BASE_Y      = 0    # top of the databox
end

#===============================================================================
# Databox: draw the type icons after every refresh (covers both the DBK styled
# path and the classic path — refresh is the common entry point).
#===============================================================================
class Battle::Scene::PokemonDataBox
  alias ar_typeicons_refresh refresh unless method_defined?(:ar_typeicons_refresh)
  def refresh
    ar_typeicons_refresh
    ar_draw_type_icons if ARTypeIcons::ENABLED
  end

  alias ar_typeicons_dispose dispose unless method_defined?(:ar_typeicons_dispose)
  def dispose
    if @ar_typebitmap
      @ar_typebitmap.dispose
      @ar_typebitmap = nil
    end
    ar_typeicons_dispose
  end

  # Resolve (and cache) the icon sheet: returns [bitmap, cell_w, cell_h] or nil.
  def ar_type_sheet
    if !@ar_typebitmap
      ARTypeIcons::SHEETS.each do |path, cw, ch|
        resolved = pbResolveBitmap(path)
        next if !resolved
        @ar_typebitmap = AnimatedBitmap.new(resolved)
        @ar_typecw = cw
        @ar_typech = ch
        break
      end
    end
    return nil if !@ar_typebitmap
    b = @ar_typebitmap.bitmap
    return nil if !b || b.disposed?
    [b, @ar_typecw, @ar_typech]
  end

  # Types to show for this box's battler (illusion / Tera aware).
  def ar_display_types
    b = @battler
    return [] if !b || !b.pokemon
    poke = b.respond_to?(:displayPokemon) ? b.displayPokemon : b.pokemon
    return [] if !poke
    illusion = b.effects[PBEffects::Illusion] && !b.pbOwnedByPlayer?
    if b.respond_to?(:tera?) && b.tera?
      types = illusion ? poke.types.clone : b.pbPreTeraTypes.clone
    elsif illusion
      types = poke.types.clone
      extra = b.effects[PBEffects::ExtraType]
      types.push(extra) if extra
    else
      types = b.pbTypes(true)
    end
    types.compact.first(ARTypeIcons::MAX_TYPES)
  end

  def ar_draw_type_icons
    bmp = self.bitmap
    return if !bmp || bmp.disposed?
    types = ar_display_types
    return if types.empty?
    sheet = ar_type_sheet
    return if !sheet
    src_bmp, cw, ch = sheet
    base_x = (@battler.index.even? ? ARTypeIcons::BASE_X_ALLY : ARTypeIcons::BASE_X_FOE)
    base_y = ARTypeIcons::BASE_Y
    # Draw right-to-left so the first type ends up rightmost (all-in-one order).
    types.reverse.each_with_index do |type, i|
      tdata = GameData::Type.try_get(type)
      next if !tdata
      row = tdata.icon_position
      next if (row + 1) * ch > src_bmp.height   # not present in this sheet
      src  = Rect.new(0, row * ch, cw, ch)
      dest = Rect.new(base_x - i * ARTypeIcons::STEP_X, base_y,
                      ARTypeIcons::DRAW_W, ARTypeIcons::DRAW_H)
      bmp.stretch_blt(dest, src_bmp, src)
    end
  end
end

#===============================================================================
# Battler: repaint this battler's databox whenever its types change.
#===============================================================================
class Battle::Battler
  def ar_refresh_type_box
    return if !@battle
    scene = @battle.scene
    scene.pbRefreshOne(@index) if scene.respond_to?(:pbRefreshOne)
  end

  if method_defined?(:pbChangeTypes)
    alias ar_typeicons_pbChangeTypes pbChangeTypes unless method_defined?(:ar_typeicons_pbChangeTypes)
    def pbChangeTypes(*args)
      ar_typeicons_pbChangeTypes(*args)
      ar_refresh_type_box
    end
  end

  if method_defined?(:pbResetTypes)
    alias ar_typeicons_pbResetTypes pbResetTypes unless method_defined?(:ar_typeicons_pbResetTypes)
    def pbResetTypes(*args)
      ar_typeicons_pbResetTypes(*args)
      ar_refresh_type_box
    end
  end
end
