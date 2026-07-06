#===============================================================================
# Another Red Online - Pokemon Champions balance patch ([018])
#
# Ports the Pokemon Champions "Regulation M-B" balance changes to OUR mod. Like
# [017], these are NOT gated on $arnet: they apply to the whole build (single-
# player AND online). Being baked into the shared build, every peer runs the
# identical logic, so the engine tweaks stay deterministic -> lockstep-safe.
#
# This bundle loads LAST (appended after DBK / Gen 9 Pack), so re-opening their
# classes here overrides the originals. Each engine tweak notes the source method
# it reproduces/wraps so it can be re-verified when the base game is updated.
#
# Excluded per request: New Mega Evolution Abilities, New Items.
# Source: Game8 "List of Changes | Pokemon Champions".
#
# --- DATA (mutated in GameData at load) --------------------------------------
#  Moves : power / accuracy / type / +Slicing flag / effect-chance edits, and
#          Freeze-Dry effect_chance -> 0 (removes its freeze; the Water super-
#          effectiveness lives in pbCalcTypeModSingle and is unaffected).
#  Learnsets : per-species move additions (-> @tutor_moves) and removals
#          (from @moves / @tutor_moves / @egg_moves).
# --- ENGINE (method overrides) -----------------------------------------------
#  * Paralysis full-paralysis chance 25% -> 12.5%   (pbTryUseMove)
#  * Freeze: 25%/turn thaw, guaranteed by the 3rd turn (pbTryUseMove + counter)
#  * Rest now sleeps one extra turn (HealUserFullyAndFallAsleep)
#  * Unseen Fist deals 1/4 damage when it hits through protection
#          (pbCalcDamageMultipliers)
#  * Toxic Thread lowers Speed by 2 stages (PoisonTargetLowerTargetSpeed1)
#  * Make It Rain lowers user's Sp. Atk by 2 stages
#          (AddMoneyGainedFromBattleLowerUserSpAtk1)
#  * Salt Cure residual damage halved: 1/8->1/16, 1/4->1/8 (Water/Steel)
#  * Rage Fist hit-count resets when the user switches out (pbInitEffects)
#  * Sudden Death (both clocks out) -> draw : handled in [014] BattleClock.rb
#===============================================================================

module ARNet
  module ChampionsBalance
    module_function

    # ----- move data patches -------------------------------------------------
    MOVE_POWER = {
      :APPLEACID => 90, :BEAKBLAST => 120, :BONERUSH => 30, :FIRELASH => 90,
      :FIRSTIMPRESSION => 100, :GRAVAPPLE => 90, :INFERNALPARADE => 65,
      :NIGHTDAZE => 90, :MOUNTAINGALE => 120, :PSYSHIELDBASH => 90,
      :SPIRITSHACKLE => 90, :TROPKICK => 85
    }
    MOVE_ACCURACY = { :CRABHAMMER => 95, :SYRUPBOMB => 90, :MAKEITRAIN => 95 }
    MOVE_TYPE     = { :GROWTH => :GRASS, :SNAPTRAP => :STEEL }
    MOVE_ADD_FLAGS = { :DRAGONCLAW => ["Slicing"], :SHADOWCLAW => ["Slicing"] }
    # Dire Claw 50->30, Moonblast 30->10, Iron Head 30->20, Freeze-Dry 10->0 (no freeze)
    MOVE_EFFECT_CHANCE = { :DIRECLAW => 30, :MOONBLAST => 10, :IRONHEAD => 20, :FREEZEDRY => 0 }

    # ----- learnset patches --------------------------------------------------
    LEARN_ADD = {
      # Regulation M-B buffs
      :SCEPTILE  => [:EARTHPOWER],
      :SWAMPERT  => [:WAVECRASH],
      :SCOLIPEDE => [:LEECHLIFE, :TRAILBLAZE],
      # From-previous buffs
      :BLASTOISE => [:SHELLSMASH],
      :LOPUNNY   => [:CLOSECOMBAT, :MACHPUNCH, :UTURN, :TRIPLEAXEL],
      :AEGISLASH => [:POLTERGEIST, :AIRSLASH],
      :ARMAROUGE => [:BURNUP],
      :CERULEDGE => [:BURNUP],
      :CHARIZARD => [:ROOST, :BEATUP],
      :TYRANITAR => [:SUPERPOWER, :IRONTAIL],
      :DRAGONITE => [:SUPERPOWER, :IRONTAIL],
      :SABLEYE   => [:PAYBACK],
      :SYLVEON   => [:MYSTICALFIRE, :SAFEGUARD],
      :WHIMSICOTT => [:ATTRACT, :SAFEGUARD],
      :HIPPOWDON => [:SUPERPOWER],
      :DRAGAPULT => [:BEATUP],
      :SCIZOR    => [:ROOST],
      :DRAMPA    => [:ROOST]
    }
    LEARN_REMOVE = {
      # Regulation M-B nerfs
      :GHOLDENGO  => [:THUNDERWAVE],
      :ANNIHILAPE => [:FINALGAMBIT],
      :METAGROSS  => [:HEAVYSLAM, :KNOCKOFF],
      :GRIMMSNARL => [:THUNDERWAVE],
      :SCRAFTY    => [:PARTINGSHOT],
      :OVERQWIL   => [:MORTALSPIN],
      :PYROAR     => [:EARTHPOWER],
      # From-previous nerfs
      :ARMAROUGE  => [:FUTURESIGHT],
      :CHARIZARD  => [:BLAZEKICK, :DUALWINGBEAT],
      :TYRANITAR  => [:SCALESHOT, :SCORCHINGSANDS],
      :DRAGONITE  => [:ENCORE, :DUALWINGBEAT, :VACUUMWAVE, :WHIRLPOOL],
      :SABLEYE    => [:PARTINGSHOT],
      :SYLVEON    => [:TAUNT, :IRONTAIL],
      :ARCHALUDON => [:BODYPRESS],
      :INCINEROAR => [:KNOCKOFF, :UTURN],
      :GENGAR     => [:ENCORE, :SHADOWSNEAK],
      :ROTOM      => [:PARTINGSHOT, :PARABOLICCHARGE],
      :MACHAMP    => [:FISSURE],
      :BLASTOISE  => [:SCALD],
      :GRENINJA   => [:NASTYPLOT],
      :MILOTIC    => [:CALMMIND],
      :GLISCOR    => [:TAUNT]
      # NOTE: Kangaskhan's removed move is blank in the source; omitted.
    }

    def apply_moves
      return unless defined?(GameData::Move) && GameData::Move.const_defined?(:DATA)
      data = GameData::Move::DATA
      MOVE_POWER.each { |id, v| m = data[id]; m.instance_variable_set(:@power, v) if m }
      MOVE_ACCURACY.each { |id, v| m = data[id]; m.instance_variable_set(:@accuracy, v) if m }
      MOVE_TYPE.each { |id, v| m = data[id]; m.instance_variable_set(:@type, v) if m }
      MOVE_EFFECT_CHANCE.each { |id, v| m = data[id]; m.instance_variable_set(:@effect_chance, v) if m }
      MOVE_ADD_FLAGS.each do |id, flags|
        m = data[id]; next unless m
        fl = (m.instance_variable_get(:@flags) || []).dup
        flags.each { |f| fl.push(f) unless fl.include?(f) }
        m.instance_variable_set(:@flags, fl)
      end
    rescue => e
      echoln("[Champions] apply_moves failed: #{e.message}") rescue nil
    end

    def apply_species
      return unless defined?(GameData::Species) && GameData::Species.const_defined?(:DATA)
      data = GameData::Species::DATA
      LEARN_REMOVE.each do |id, moves|
        s = data[id]; next unless s
        lv = s.instance_variable_get(:@moves)
        s.instance_variable_set(:@moves, lv.reject { |pair| moves.include?(pair[1]) }) if lv
        [:@tutor_moves, :@egg_moves].each do |iv|
          arr = s.instance_variable_get(iv)
          s.instance_variable_set(iv, arr.reject { |mv| moves.include?(mv) }) if arr
        end
      end
      LEARN_ADD.each do |id, moves|
        s = data[id]; next unless s
        tm = (s.instance_variable_get(:@tutor_moves) || []).dup
        moves.each { |mv| tm.push(mv) unless tm.include?(mv) }
        s.instance_variable_set(:@tutor_moves, tm)
      end
    rescue => e
      echoln("[Champions] apply_species failed: #{e.message}") rescue nil
    end

    # Whether the target has an active single-target protection this round
    # (used by Unseen Fist to apply reduced damage when it hits through).
    def target_protected?(target)
      return false unless target && target.respond_to?(:effects) && target.effects
      [:Protect, :KingsShield, :SpikyShield, :BanefulBunker, :Obstruct,
       :SilkTrap, :BurningBulwark, :MaxGuard].each do |sym|
        next unless PBEffects.const_defined?(sym)
        val = target.effects[PBEffects.const_get(sym)]
        return true if val && val != 0
      end
      false
    rescue
      false
    end
  end
end

#-------------------------------------------------------------------------------
# Data-load hooks: re-apply the data patches every time GameData is (re)loaded,
# and immediately if it was already loaded before this script ran. Mirrors the
# proven approach in [017].
#-------------------------------------------------------------------------------
if defined?(GameData::Move) && GameData::Move.respond_to?(:load)
  class << GameData::Move
    unless method_defined?(:__arnet_champ_orig_load) || private_method_defined?(:__arnet_champ_orig_load)
      alias_method :__arnet_champ_orig_load, :load
      def load
        __arnet_champ_orig_load
        ARNet::ChampionsBalance.apply_moves
      end
    end
  end
  ARNet::ChampionsBalance.apply_moves if GameData::Move.const_defined?(:DATA) &&
                                         !GameData::Move::DATA.empty?
end

if defined?(GameData::Species) && GameData::Species.respond_to?(:load)
  class << GameData::Species
    unless method_defined?(:__arnet_champ_orig_load_sp) || private_method_defined?(:__arnet_champ_orig_load_sp)
      alias_method :__arnet_champ_orig_load_sp, :load
      def load
        __arnet_champ_orig_load_sp
        ARNet::ChampionsBalance.apply_species
      end
    end
  end
  ARNet::ChampionsBalance.apply_species if GameData::Species.const_defined?(:DATA) &&
                                           !GameData::Species::DATA.empty?
end

#-------------------------------------------------------------------------------
# Engine: status-move-prevention tweaks (paralysis 12.5%, freeze 25% + guaranteed
# thaw by the 3rd turn). Reproduces Battle::Battler#pbTryUseMove
# (Scripts/168_Battler_UseMoveSuccessChecks.rb) verbatim with only those two
# edits, then slots it back where the base method lives. DBK Z-Power wraps
# pbTryUseMove and calls the base via its `zmove_pbTryUseMove` alias, so when that
# alias exists we redefine THAT (keeping DBK's wrapper intact); otherwise we
# redefine pbTryUseMove directly.
#-------------------------------------------------------------------------------
class Battle::Battler
    def arnet_champ_pbTryUseMove(choice, move, specialUsage, skipAccuracyCheck)
      # Check whether it's possible for self to use the given move
      # NOTE: Encore has already changed the move being used, no need to have a
      #       check for it here.
      if !pbCanChooseMove?(move, false, true, specialUsage)
        @lastMoveFailed = true
        return false
      end
      # Check whether it's possible for self to do anything at all
      if @effects[PBEffects::SkyDrop] >= 0   # Intentionally no message here
        PBDebug.log("[Move failed] #{pbThis} can't use #{move.name} because of being Sky Dropped")
        return false
      end
      if @effects[PBEffects::HyperBeam] > 0   # Intentionally before Truant
        PBDebug.log("[Move failed] #{pbThis} is recharging after using #{move.name}")
        @battle.pbDisplay(_INTL("\\j[{1},은,는] 휴식이 필요하다!", pbThis))
        @effects[PBEffects::Truant] = !@effects[PBEffects::Truant] if hasActiveAbility?(:TRUANT)
        return false
      end
      if choice[1] == -2   # Battle Palace
        PBDebug.log("[Move failed] #{pbThis} can't act in the Battle Palace somehow")
        @battle.pbDisplay(_INTL("\\j[{1},은,는] 싸우기 힘들어 보인다!", pbThis))
        return false
      end
      # Skip checking all applied effects that could make self fail doing something
      return true if skipAccuracyCheck
      # Check status problems and continue their effects/cure them
      case @status
      when :SLEEP
        self.statusCount -= 1
        if @statusCount <= 0
          pbCureStatus
        else
          pbContinueStatus
          if !move.usableWhenAsleep?   # Snore/Sleep Talk
            PBDebug.log("[Move failed] #{pbThis} is asleep")
            @lastMoveFailed = true
            return false
          end
        end
      when :FROZEN
        if !move.thawsUser?
          @arnet_champ_freeze = (@arnet_champ_freeze || 0) + 1
          if @battle.pbRandom(100) < 25 || @arnet_champ_freeze >= 3
            @arnet_champ_freeze = 0
            pbCureStatus
          else
            pbContinueStatus
            PBDebug.log("[Move failed] #{pbThis} is frozen")
            @lastMoveFailed = true
            return false
          end
        end
      end
      # Obedience check
      return false if !pbObedienceCheck?(choice)
      # Truant
      if hasActiveAbility?(:TRUANT)
        @effects[PBEffects::Truant] = !@effects[PBEffects::Truant]
        if !@effects[PBEffects::Truant]   # True means loafing, but was just inverted
          @battle.pbShowAbilitySplash(self)
          @battle.pbDisplay(_INTL("\\j[{1},은,는] 고개를 저었다!", pbThis))
          @lastMoveFailed = true
          @battle.pbHideAbilitySplash(self)
          PBDebug.log("[Move failed] #{pbThis} can't act because of #{abilityName}")
          return false
        end
      end
      # Flinching
      if @effects[PBEffects::Flinch]
        @battle.pbDisplay(_INTL("\\j[{1},은,는] 풀이 죽어 움직일 수 없다!", pbThis))
        PBDebug.log("[Move failed] #{pbThis} flinched")
        if abilityActive?
          Battle::AbilityEffects.triggerOnFlinch(self.ability, self, @battle)
        end
        @lastMoveFailed = true
        return false
      end
      # Confusion
      if @effects[PBEffects::Confusion] > 0
        @effects[PBEffects::Confusion] -= 1
        if @effects[PBEffects::Confusion] <= 0
          pbCureConfusion
          @battle.pbDisplay(_INTL("\\j[{1},은,는] 혼란에서 벗어났다!", pbThis))
        else
          @battle.pbCommonAnimation("Confusion", self)
          @battle.pbDisplay(_INTL("\\j[{1},은,는] 혼란에 빠졌다!", pbThis))
          threshold = (Settings::MECHANICS_GENERATION >= 7) ? 33 : 50   # % chance
          if @battle.pbRandom(100) < threshold
            pbConfusionDamage(_INTL("It hurt itself in its confusion!"))
            PBDebug.log("[Move failed] #{pbThis} hurt itself in its confusion")
            @lastMoveFailed = true
            return false
          end
        end
      end
      # Paralysis
      if @status == :PARALYSIS && @battle.pbRandom(1000) < 125   # Champions: 12.5%
        pbContinueStatus
        PBDebug.log("[Move failed] #{pbThis} is paralyzed")
        @lastMoveFailed = true
        return false
      end
      # Infatuation
      if @effects[PBEffects::Attract] >= 0
        @battle.pbCommonAnimation("Attract", self)
        @battle.pbDisplay(_INTL("\\j[{1},은,는] {2}에게 헤롱헤롱하다!", pbThis,
                                @battle.battlers[@effects[PBEffects::Attract]].pbThis(true)))
        if @battle.pbRandom(100) < 50
          @battle.pbDisplay(_INTL("\\j[{1},은,는] 사랑에 빠져있다!", pbThis))
          PBDebug.log("[Move failed] #{pbThis} is immobilized by love")
          @lastMoveFailed = true
          return false
        end
      end
      return true
    end

  if method_defined?(:zmove_pbTryUseMove)
    alias_method :zmove_pbTryUseMove, :arnet_champ_pbTryUseMove
  else
    alias_method :pbTryUseMove, :arnet_champ_pbTryUseMove
  end

  # Reset the freeze turn-counter whenever any status is cured, so a later freeze
  # starts fresh.
  unless method_defined?(:arnet_champ_pbCureStatus)
    alias_method :arnet_champ_pbCureStatus, :pbCureStatus
    def pbCureStatus(*args, &blk)
      @arnet_champ_freeze = 0
      arnet_champ_pbCureStatus(*args, &blk)
    end
  end

  # Rage Fist: clear the accumulated hit-count for a Pokemon as it takes the
  # field, i.e. its counter is reset each time it was switched out.
  unless method_defined?(:arnet_champ_pbInitEffects)
    alias_method :arnet_champ_pbInitEffects, :pbInitEffects
    def pbInitEffects(*args, &blk)
      arnet_champ_pbInitEffects(*args, &blk)
      begin
        if @battle.respond_to?(:rage_hit_count) && @battle.rage_hit_count
          @battle.rage_hit_count[@index & 1][@pokemonIndex] = 0
        end
      rescue
      end
    end
  end

  # Salt Cure: halve the residual damage (1/8 -> 1/16, and 1/4 -> 1/8 for
  # Water/Steel). The EOR handler plays pbCommonAnimation("SaltCure", battler)
  # immediately before dealing totalhp/fraction; we flag that battler and halve
  # the very next effect-damage it takes.
  unless method_defined?(:arnet_champ_pbTakeEffectDamage)
    alias_method :arnet_champ_pbTakeEffectDamage, :pbTakeEffectDamage
    def pbTakeEffectDamage(*args, &blk)
      if @arnet_champ_saltcure_halve
        @arnet_champ_saltcure_halve = false
        args[0] = [args[0] / 2, 1].max if args[0].is_a?(Integer)
      end
      arnet_champ_pbTakeEffectDamage(*args, &blk)
    end
  end
end

class Battle
  unless method_defined?(:arnet_champ_pbCommonAnimation)
    alias_method :arnet_champ_pbCommonAnimation, :pbCommonAnimation
    def pbCommonAnimation(*args, &blk)
      begin
        if args[0] == "SaltCure" && args[1]
          args[1].instance_variable_set(:@arnet_champ_saltcure_halve, true)
        end
      rescue
      end
      arnet_champ_pbCommonAnimation(*args, &blk)
    end
  end
end

#-------------------------------------------------------------------------------
# Engine: Unseen Fist now deals 1/4 damage when a contact move hits through the
# target's protection (instead of full damage). Wraps
# Battle::Move#pbCalcDamageMultipliers (Scripts/174_Move_UsageCalculations.rb).
#-------------------------------------------------------------------------------
class Battle::Move
  unless method_defined?(:arnet_champ_pbCalcDamageMultipliers)
    alias_method :arnet_champ_pbCalcDamageMultipliers, :pbCalcDamageMultipliers
    def pbCalcDamageMultipliers(user, target, numTargets, type, baseDmg, multipliers)
      arnet_champ_pbCalcDamageMultipliers(user, target, numTargets, type, baseDmg, multipliers)
      begin
        if user.hasActiveAbility?(:UNSEENFIST) && contactMove? &&
           ARNet::ChampionsBalance.target_protected?(target)
          multipliers[:final_damage_multiplier] *= 0.25
        end
      rescue
      end
    end
  end
end

#-------------------------------------------------------------------------------
# Engine: Rest sleeps for one extra turn (source line reproduced with 3 -> 4).
#-------------------------------------------------------------------------------
if defined?(Battle::Move::HealUserFullyAndFallAsleep)
  class Battle::Move::HealUserFullyAndFallAsleep
    def pbEffectGeneral(user)
      user.pbSleepSelf(_INTL("\\j[{1},은,는] 잠들어 회복했다!", user.pbThis), 4)
      super
    end
  end
end

#-------------------------------------------------------------------------------
# Engine: Toxic Thread lowers Speed by 2 stages (was 1).
#-------------------------------------------------------------------------------
if defined?(Battle::Move::PoisonTargetLowerTargetSpeed1)
  class Battle::Move::PoisonTargetLowerTargetSpeed1
    unless method_defined?(:arnet_champ_init)
      alias_method :arnet_champ_init, :initialize
      def initialize(*args)
        arnet_champ_init(*args)
        @statDown = [:SPEED, 2]
      end
    end
  end
end

#-------------------------------------------------------------------------------
# Engine: Make It Rain lowers the user's Sp. Atk by 2 stages (was 1).
#-------------------------------------------------------------------------------
if defined?(Battle::Move::AddMoneyGainedFromBattleLowerUserSpAtk1)
  class Battle::Move::AddMoneyGainedFromBattleLowerUserSpAtk1
    unless method_defined?(:arnet_champ_init)
      alias_method :arnet_champ_init, :initialize
      def initialize(*args)
        arnet_champ_init(*args)
        @statDown = [:SPECIAL_ATTACK, 2]
      end
    end
  end
end
