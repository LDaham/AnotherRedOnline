#===============================================================================
# Another Red Online — engine / DBK bug fixes ([017])
#
# Fixes for base-game and Deluxe Battle Kit bugs that our mod inherits. These are
# NOT gated on $arnet: they apply to the whole build (single-player and online),
# and — being baked into the shared game build — they stay deterministic across
# both peers, so they are safe for lockstep online battles.
#
# This bundle loads LAST (appended after DBK), so re-opening a DBK class here
# overrides the buggy original. Each fix notes the source method it replaces so it
# can be re-verified when DBK is updated.
#
# Ported from the "어나더 레드 올인원 패치" fix list.
#
# Implemented here:
#   1) Water moves are no longer boosted (×1.5) in sun — they are correctly halved.
#   2) Mega Scizor / Mega Metagross base stats restored to their canonical values.
#===============================================================================

#-------------------------------------------------------------------------------
# 1) Sun weather vs. Water-type moves.
#
# DBK's Battle::Move#pbCalcDamageMults_Weather (Damage Calc Refactor) has a typo:
#
#     when :WATER
#       if @function_code = "IncreasePowerInSunWeather"   # '=' assignment!
#
# The single '=' is an assignment, not a comparison, so the condition is ALWAYS
# true: every Water move used in sun gets ×1.5 instead of the correct ×0.5, and
# @function_code is clobbered with "IncreasePowerInSunWeather" as a side effect.
# (The AI's simulation copy uses '==', which is why only real battles misbehave.)
#
# We redefine the method verbatim with the single '=' corrected to '=='. Only
# Hydro Steam ("IncreasePowerInSunWeather") is boosted in sun; all other Water
# moves are halved, exactly as intended.
#-------------------------------------------------------------------------------
if defined?(Battle::Move) && Battle::Move.method_defined?(:pbCalcDamageMults_Weather)
  class Battle::Move
    def pbCalcDamageMults_Weather(user, target, numTargets, type, baseDmg, multipliers)
      case user.effectiveWeather
      when :Sun, :HarshSun
        case type
        when :FIRE
          multipliers[:final_damage_multiplier] *= 1.5
        when :WATER
          if @function_code == "IncreasePowerInSunWeather"
            multipliers[:final_damage_multiplier] *= 1.5
          else
            multipliers[:final_damage_multiplier] /= 2
          end
        end
      when :Rain, :HeavyRain
        case type
        when :FIRE
          multipliers[:final_damage_multiplier] /= 2
        when :WATER
          multipliers[:final_damage_multiplier] *= 1.5
        end
      when :Sandstorm
        if target.pbHasType?(:ROCK) && specialMove? && @function_code != "UseTargetDefenseInsteadOfTargetSpDef"
          multipliers[:defense_multiplier] *= 1.5
        end
      when :Hail
        if defined?(Settings::HAIL_WEATHER_TYPE) && Settings::HAIL_WEATHER_TYPE > 0 &&
           target.pbHasType?(:ICE) && (physicalMove? || @function_code == "UseTargetDefenseInsteadOfTargetSpDef")
          multipliers[:defense_multiplier] *= 1.5
        end
      when :ShadowSky
        multipliers[:final_damage_multiplier] *= 1.5 if type == :SHADOW
      end
    end
  end
end

#-------------------------------------------------------------------------------
# 2) Mega Scizor / Mega Metagross base-stat corrections.
#
# Our species data has non-canonical base stats for these two real Mega forms:
#   Mega Scizor    (:SCIZOR_1)    was 70/150/140/100/75/65   (SpA/SpD/Spe rotated)
#   Mega Metagross (:METAGROSS_1) was 95/145/130/120/90/120
# We restore the official values:
#   Mega Scizor    -> 70/150/140/65/100/75
#   Mega Metagross -> 80/145/150/105/110/110
#
# GameData::Species entries are loaded from species.dat at boot (GameData.load_all,
# which runs in `main` AFTER all plugin scripts — including this one — are loaded).
# We alias the class's `load` so the correction is re-applied every time the data
# is (re)loaded, replacing @base_stats with a fresh hash (no frozen-in-place edit).
# This is baked into the shared build, so both peers see identical stats — safe for
# lockstep online battles. NOTE: base stats are NOT normalized online (only Lv/IV
# are), so this fix matters for online balance too.
#-------------------------------------------------------------------------------
if defined?(GameData::Species) && GameData::Species.respond_to?(:load)
  module ARRedMegaStatFix
    FIXES = {
      :SCIZOR_1    => { :HP => 70, :ATTACK => 150, :DEFENSE => 140,
                        :SPECIAL_ATTACK => 65,  :SPECIAL_DEFENSE => 100, :SPEED => 75 },
      :METAGROSS_1 => { :HP => 80, :ATTACK => 145, :DEFENSE => 150,
                        :SPECIAL_ATTACK => 105, :SPECIAL_DEFENSE => 110, :SPEED => 110 }
    }
    def self.apply
      FIXES.each do |id, stats|
        next unless GameData::Species::DATA.has_key?(id)
        GameData::Species::DATA[id].instance_variable_set(:@base_stats, stats.dup)
      end
    end
  end

  class << GameData::Species
    unless method_defined?(:__arred_orig_load) || private_method_defined?(:__arred_orig_load)
      alias_method :__arred_orig_load, :load
      def load
        __arred_orig_load
        ARRedMegaStatFix.apply
      end
    end
  end

  # If the data was already loaded before this script ran, patch it now too.
  ARRedMegaStatFix.apply if GameData::Species.const_defined?(:DATA) &&
                            !GameData::Species::DATA.empty?
end
