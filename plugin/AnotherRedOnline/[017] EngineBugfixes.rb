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
#   3) Skill Swap message no longer shows literal "{2} {3}" placeholders.
#   4) Black/White Flute field messages translated to Korean (were English).
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

#-------------------------------------------------------------------------------
# 3) Skill Swap message shows literal "{2} {3}" placeholders.
#
# Base Battle::Move::UserTargetSwapAbilities#pbEffectAgainstTarget has two
# message branches with the SAME Korean text — which names both swapped
# Abilities via {2}/{3} — but the USE_ABILITY_SPLASH branch passes only {1}:
#
#     if Battle::Scene::USE_ABILITY_SPLASH
#       @battle.pbDisplay(_INTL("...자신의 {2}...상대의 {3}...맞바꿨다!", user.pbThis))
#     else
#       @battle.pbDisplay(_INTL("...", user.pbThis, target.abilityName, user.abilityName))
#     end
#
# (In vanilla English the splash branch uses a shorter "{1} swapped Abilities
# with its target!" string; the Korean translation reused the long text but kept
# the 1-argument call.) With USE_ABILITY_SPLASH on (DBK default), {2}/{3} stay
# unsubstituted and render as literal "{2} {3}" on screen.
#
# We redefine the method verbatim, collapsing both branches into a single
# pbDisplay that always passes all three arguments (the argument order matches
# the known-good `else` branch: after the swap, target.abilityName is the user's
# original Ability ("자신의 {2}") and user.abilityName is the target's original
# Ability ("상대의 {3}")).
#-------------------------------------------------------------------------------
class Battle::Move::UserTargetSwapAbilities < Battle::Move
  def pbEffectAgainstTarget(user, target)
    if user.opposes?(target)
      @battle.pbShowAbilitySplash(user, false, false)
      @battle.pbShowAbilitySplash(target, true, false)
    end
    oldUserAbil   = user.ability
    oldTargetAbil = target.ability
    user.ability   = oldTargetAbil
    target.ability = oldUserAbil
    if user.opposes?(target)
      @battle.pbReplaceAbilitySplash(user)
      @battle.pbReplaceAbilitySplash(target)
    end
    @battle.pbDisplay(_INTL("\\j[{1},은,는] 자신의 \\j[{2},을,를] 상대의 \\j[{3},과,와] 맞바꿨다!",
                            user.pbThis, target.abilityName, user.abilityName))
    if user.opposes?(target)
      @battle.pbHideAbilitySplash(user)
      @battle.pbHideAbilitySplash(target)
    end
    user.pbOnLosingAbility(oldUserAbil)
    target.pbOnLosingAbility(oldTargetAbil)
    user.pbTriggerAbilityOnGainingIt
    target.pbTriggerAbilityOnGainingIt
  end
end

#-------------------------------------------------------------------------------
# 4) Black/White Flute (검정/하양비드로) field messages left untranslated.
#
# Base ItemHandlers::UseInField for :BLACKFLUTE and :WHITEFLUTE (decompiled
# 264_Item_Effects.rb) still print English:
#   "Now you're more likely to encounter high-level Pokémon!"      (Black, level mode)
#   "The likelihood of encountering Pokémon decreased!"           (Black, rate mode)
#   "Now you're more likely to encounter low-level Pokémon!"       (White, level mode)
#   "The likelihood of encountering Pokémon increased!"           (White, rate mode)
#
# UseInField handlers are stored in a hash keyed by item id, so re-adding the
# same id here (this bundle loads last) overrides the base handler. We reproduce
# each handler verbatim with the four messages translated to Korean; the encounter
# logic (higher/lower_level_wild_pokemon, higher/lower_encounter_rate) is
# unchanged. Both branches are translated so the fix holds regardless of the
# Settings::FLUTES_CHANGE_WILD_ENCOUNTER_LEVELS value.
#-------------------------------------------------------------------------------
ItemHandlers::UseInField.add(:BLACKFLUTE, proc { |item|
  pbUseItemMessage(item)
  if Settings::FLUTES_CHANGE_WILD_ENCOUNTER_LEVELS
    pbMessage(_INTL("이제 레벨이 높은 야생 포켓몬이 잘 나타나게 되었다!"))
    $PokemonMap.higher_level_wild_pokemon = true
    $PokemonMap.lower_level_wild_pokemon = false
  else
    pbMessage(_INTL("야생 포켓몬이 잘 나타나지 않게 되었다!"))
    $PokemonMap.lower_encounter_rate = true
    $PokemonMap.higher_encounter_rate = false
  end
  next true
})

ItemHandlers::UseInField.add(:WHITEFLUTE, proc { |item|
  pbUseItemMessage(item)
  if Settings::FLUTES_CHANGE_WILD_ENCOUNTER_LEVELS
    pbMessage(_INTL("이제 레벨이 낮은 야생 포켓몬이 잘 나타나게 되었다!"))
    $PokemonMap.lower_level_wild_pokemon = true
    $PokemonMap.higher_level_wild_pokemon = false
  else
    pbMessage(_INTL("야생 포켓몬이 잘 나타나게 되었다!"))
    $PokemonMap.higher_encounter_rate = true
    $PokemonMap.lower_encounter_rate = false
  end
  next true
})
