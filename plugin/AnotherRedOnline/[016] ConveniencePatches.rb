#===============================================================================
# Another Red Online — quality-of-life defaults ([016])
#
# Convenience tweaks that ship on by default with this mod. These are NOT gated
# on $arnet — they apply to the whole game (single-player and online alike),
# because the mod is baked into the game build. They are deterministic (identical
# on both peers) and touch only post-battle / field state, never the lockstep
# checksum, so they are safe for online battles.
#
# Implemented here:
#   1) Single-use held items (Focus Sash / berries / Gems …) are refunded after
#      battle instead of being permanently consumed.
#   2) The Summary stats page always shows each stat's EV, between the stat value
#      and its IV star rating (no toggle key required).
#   3) A "기술 배우기" (Relearn/Learn Move) command appears in the party menu,
#      directly below "도구", whenever the highlighted Pokémon can learn a move.
#   4) A Pokémon holding an Eviolite will not evolve (like an Everstone).
#===============================================================================

#-------------------------------------------------------------------------------
# 1) Keep single-use held items after battle.
#
# The engine already restores each party member's held item from
# @battle.initialItems at the end of battle (Battle#pbEndOfBattle). The only
# reason consumables (Focus Sash, berries, Gems, …) vanish is that
# Battler#pbConsumeItem clears that record for permanently-consumed items. We
# preserve the record so the item is refunded post-battle. The item is still
# gone for the remainder of THIS battle (self.item was already set to nil), so
# in-battle behaviour is unchanged.
#-------------------------------------------------------------------------------
class Battle::Battler
  unless method_defined?(:arnet_orig_pbConsumeItem)
    alias_method :arnet_orig_pbConsumeItem, :pbConsumeItem
  end

  def pbConsumeItem(*args)
    saved = self.initialItem
    ret   = arnet_orig_pbConsumeItem(*args)
    # If the consume cleared the "started the battle holding this" record,
    # restore it so pbEndOfBattle hands the item back afterwards.
    setInitialItem(saved) if saved && !self.initialItem
    ret
  end
end

#-------------------------------------------------------------------------------
# 4) Eviolite prevents evolution (mirrors the built-in Everstone behaviour).
#
# Every evolution path (level-up, item, trade, after-battle, event) funnels
# through Pokemon#check_evolution_internal, which already bails on Everstone.
# We add the same early-out for a held Eviolite. hasItem? safely returns false
# when the item isn't defined, so this is a no-op on builds without Eviolite.
#-------------------------------------------------------------------------------
class Pokemon
  unless method_defined?(:arnet_orig_check_evolution_internal)
    alias_method :arnet_orig_check_evolution_internal, :check_evolution_internal
  end

  def check_evolution_internal(&blk)
    return nil if hasItem?(:EVIOLITE)
    arnet_orig_check_evolution_internal(&blk)
  end
end

#-------------------------------------------------------------------------------
# 2) Always show EVs on the Summary stats page.
#
# The stats page (page_skills -> drawPageThree) draws, per stat: the name on the
# left, the actual stat value right-aligned at x=456, and — via the Enhanced
# Pokémon UI plugin — a vertical column of IV "star" icons at x=465. There is no
# free horizontal room between the value and the stars, so we shift the IV stars
# a little further right (x=495) and slot the EV number into the gap (x=490),
# giving the requested order: value / EV / IV stars.
#
# This file is baked into the plugin bundle that loads LAST, so this alias wraps
# the whole drawPageThree chain (base -> Dynamax -> Enhanced UI). By the time it
# runs the stars have already been drawn at x=465; we erase that strip and redraw
# them shifted. The stat value itself is left untouched so its nature-based
# colouring is preserved.
#-------------------------------------------------------------------------------
if defined?(PokemonSummary_Scene)
  class PokemonSummary_Scene
    # y of each stat row on the skills page (matches the base drawPageThree).
    ARNET_EV_STAT_Y = {
      :HP              => 82,
      :ATTACK          => 126,
      :DEFENSE         => 158,
      :SPECIAL_ATTACK  => 190,
      :SPECIAL_DEFENSE => 222,
      :SPEED           => 254
    }
    # Layout: stat value (right@408) | (416) EV (right@454) [IV star @456]
    ARNET_STAT_X = 408   # right edge of the (redrawn) stat value
    ARNET_SEP_X  = 416   # x position of the "|" separator
    ARNET_EV_X   = 454   # right edge of the EV number
    ARNET_STAR_X = 456   # left edge of the IV star column (flush with EV)

    unless method_defined?(:arnet_ev_orig_drawPageThree)
      alias_method :arnet_ev_orig_drawPageThree, :drawPageThree
    end

    def drawPageThree
      arnet_ev_orig_drawPageThree
      pkmn = @pokemon
      return if pkmn.nil? || pkmn.egg?
      overlay = @sprites["overlay"].bitmap
      return if overlay.nil? || overlay.disposed?

      show_stars = !defined?(Settings::SUMMARY_IV_RATINGS) || Settings::SUMMARY_IV_RATINGS

      # Wipe the stat-value + IV-star strip so we can redraw the layout.
      # HP row gets a wider wipe (original "xxx/xxx" text extends to ~x=365);
      # keep it above the HP bar (y=110) so the bar is preserved.
      overlay.fill_rect(350, 78, 162, 28, Color.new(0, 0, 0, 0))
      overlay.fill_rect(376, 106, 136, 168, Color.new(0, 0, 0, 0))

      base   = Color.new(64, 64, 64)
      shadow = Color.new(176, 176, 176)
      sep_col = Color.new(144, 144, 144)
      sep_shd = Color.new(200, 200, 200)

      # Collect stat values per row (HP = totalhp only, no current/total).
      stat_vals = {
        :HP      => pkmn.totalhp.to_s,
        :ATTACK  => pkmn.attack.to_s,  :DEFENSE => pkmn.defense.to_s,
        :SPECIAL_ATTACK => pkmn.spatk.to_s, :SPECIAL_DEFENSE => pkmn.spdef.to_s,
        :SPEED   => pkmn.speed.to_s
      }

      textpos = []
      GameData::Stat.each_main do |s|
        y = ARNET_EV_STAT_Y[s.id]
        next if y.nil?
        # Stat value (plain colour, no nature tinting)
        textpos.push([stat_vals[s.id], ARNET_STAT_X, y, :right, base, shadow])
        # "|" separator
        textpos.push(["|", ARNET_SEP_X, y, :left, sep_col, sep_shd])
        # EV value
        textpos.push([pkmn.ev[s.id].to_s, ARNET_EV_X, y, :right, base, shadow])
      end

      old_size = overlay.font.size
      overlay.font.size = 20
      pbDrawTextPositions(overlay, textpos)
      overlay.font.size = old_size

      # Redraw the IV stars flush with the EV column.
      pbDisplayIVRatings(pkmn, overlay, ARNET_STAR_X, 83) if show_stars
    end
  end
end

#-------------------------------------------------------------------------------
# 3) "기술 배우기" command in the party menu, below "도구".
#
# The party menu is assembled from :party_menu MenuHandlers (도구/:item has
# order 50), so we simply register another handler at order 55. It only appears
# when the highlighted Pokémon actually has a move to learn, and the pool scales
# with badge count exactly like the existing move tutor NPC — both are driven by
# pbGetRelearnableMoves, which the Ultimate Move Tutor plugin defines globally.
#-------------------------------------------------------------------------------
if defined?(MenuHandlers)
  MenuHandlers.add(:party_menu, :arnet_relearn, {
    "name"      => _INTL("기술 배우기"),
    "order"     => 55,
    "condition" => proc { |_screen, party, party_idx|
      pkmn = party[party_idx]
      next false if !pkmn || pkmn.egg?
      next pbGetRelearnableMoves(pkmn).length > 0
    },
    "effect"    => proc { |screen, party, party_idx|
      pbRelearnMoveScreen(party[party_idx])
      screen.pbRefreshSingle(party_idx)
      next false
    }
  })
end
