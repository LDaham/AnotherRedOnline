#===============================================================================
# Another Red Online — guest-side visual mirror (camera flip)
#
# The simulation is CANONICAL on both peers (side0 = host, side1 = guest) so the
# lockstep stays deterministic. The guest must SEE the battle from side1's seat:
# their own Pokémon at the bottom (back sprite) and the host's at the top (front
# sprite). This flips only the *presentation* when $arnet_view_flip is set
# (BattleLauncher sets it true for the guest, around pbStartBattle).
#
# The engine has NO single "view" chokepoint — it derives "which side is mine?"
# from `opposes?` / index parity in MANY places (sprites, data boxes, messages,
# send-out choreography, move-animation mirroring). We CANNOT flip `opposes?`
# itself: it is ONE method (Battle#opposes?(a,b=0)) shared with the deterministic
# simulation (targeting, spread moves, speed order) — flipping it desyncs. So we
# override each PRESENTATION site individually, all routed through ONE predicate:
#
#   ARNet.render_own?(index) -> should this battler render as the LOCAL/near side
#   ARNet.pres_index(index)  -> the seat index used for position/parity presentation
#
# Everything here is display-only (strings, sprite choice, animation direction);
# none of it is hashed into the turn checksum, so it can't affect determinism.
#
# DONE (verified in-game): pokemon back/front + position, HP-box side, message
# perspective, move-animation mirror, HP-box slide direction, send-out direction.
# trainer intro sprites: now gender-correct + local-perspective on both peers
# (section 1b) — near seat = own back sprite (own gender), far seat = opponent's
# front sprite (their gender). RESIDUAL GAP: the 5-frame throw-arm animation stays
# bound to the canonical key (player_N=throw), so the guest's near-seat throw
# motion is still slightly off; the static picture + orientation are correct.
#===============================================================================
module ARNet
  def self.view_flip?; $arnet_view_flip ? true : false; end

  # Trainer intro sprite files, local perspective, from the ACTUAL trainer types
  # (exchanged in the handshake) rather than a hand-guessed gender->file map — the
  # engine's own filename methods are the ground truth, so the sprite matches what
  # each player really is (and respects the local player's outfit). Own side = the
  # local player's BACK sprite; opponent = the peer's FRONT sprite.
  def self.own_back_sprite_file
    tt = $arnet_my_ttype || ($player && $player.trainer_type)
    GameData::TrainerType.player_back_sprite_filename(tt)
  end

  def self.opp_front_sprite_file
    tt  = $arnet_opp_ttype
    sym = tt.is_a?(String) ? tt.to_sym : tt
    sym = nil unless sym && (GameData::TrainerType.try_get(sym) rescue nil)
    sym ||= ($player && $player.trainer_type)   # fallback: both peers are this game's players
    GameData::TrainerType.front_sprite_filename(sym)
  end

  # Under the guest's flipped view, battler index N is presented in seat N^1.
  # $arnet_suppress_flip temporarily disables the seat flip so a full-screen
  # overlay (the gimmick transformation cinematics, section 7c) can use
  # pbBattlerPosition as a FIXED screen anchor that stays identical on both peers.
  def self.pres_index(i); ($arnet_view_flip && !$arnet_suppress_flip) ? (i ^ 1) : i; end

  # True if index `i` should render as the LOCAL/near side (bottom seat, back
  # sprite, own data box, player-style send-out, no "opposing" text prefix).
  # Engine-native convention: even index = near/player side.
  def self.render_own?(i); pres_index(i).even?; end

  # Presentation "is this battler on the FAR (opponent) seat, from the viewer?".
  # Canonically this is Battler#opposes? (player-relative, side0=near); the guest's
  # flipped view inverts it. Used by the Substitute-doll animations, which derive
  # slide direction / front-vs-back doll from opposes? — display-only, so safe.
  def self.pres_far?(battler); $arnet_view_flip ? !battler.opposes? : battler.opposes?; end

  # Delegates everything to the real battler but reports a flipped `index`, so a
  # data box (and its appear/disappear animation) built from it renders on the
  # opposite side while still reading the correct HP/name/level/etc.
  class MirrorBattler
    def initialize(battler); @arnet_b = battler; end
    def index;              @arnet_b.index ^ 1; end
    # opposes? drives the data box's in-box icon POSITIONS (shiny star, primal /
    # mega icon, owned pokéball) — see draw_shiny_icon/draw_special_form_icon/
    # draw_owned_icon, which place them via `@battler.opposes?`. Those must follow
    # the FLIPPED seat like everything else in the box, but the engine's opposes?
    # reads the real @index, so delegating it (method_missing) leaves the icons on
    # the canonical side (guest sees their own shiny star on the foe box, etc.).
    # Compute it from OUR flipped index instead. Display-only; never hashed.
    def opposes?(other = 0)
      other = other.index if other.respond_to?(:index)
      (index & 1) != (other.to_i & 1)
    end
    def __real__;           @arnet_b; end
    def is_a?(k);           @arnet_b.is_a?(k); end
    def kind_of?(k);        @arnet_b.kind_of?(k); end
    def instance_of?(k);    @arnet_b.instance_of?(k); end
    def class;              @arnet_b.class; end
    def ==(o);              @arnet_b == (o.is_a?(MirrorBattler) ? o.__real__ : o); end
    def respond_to_missing?(m, inc = false); @arnet_b.respond_to?(m, inc); end
    def method_missing(m, *a, &blk); @arnet_b.send(m, *a, &blk); end
  end
end

if defined?(Battle::Scene)
  class Battle::Scene
    #--- 1) Positions: the single place every "where does index N sit?" resolves -
    class << self
      unless method_defined?(:arnet_orig_pbBattlerPosition) || respond_to?(:arnet_orig_pbBattlerPosition)
        alias_method :arnet_orig_pbBattlerPosition, :pbBattlerPosition
        alias_method :arnet_orig_pbTrainerPosition, :pbTrainerPosition
      end
      def pbBattlerPosition(index, sideSize = 1)
        arnet_orig_pbBattlerPosition(ARNet.pres_index(index), sideSize)
      end
      def pbTrainerPosition(side, index = 0, sideSize = 1)
        arnet_orig_pbTrainerPosition(ARNet.pres_index(side), index, sideSize)
      end
    end

    #--- 1b) Trainer intro sprites: correct character + local perspective. Online
    # battles show the LOCAL player's OWN trainer (back sprite) in the near seat and
    # the OPPONENT's trainer (front sprite) in the far seat — on BOTH host and
    # guest. We use the ACTUAL trainer types (the local $player's, and the peer's
    # exchanged in the handshake) via the engine's own filename methods, so each
    # sprite matches what that player really is (no gender guessing). The engine
    # keys these sprites CANONICALLY (player_N thrown/faded as side0, trainer_N
    # faded as side1), so we KEEP the key tied to the calling method but choose the
    # sprite TYPE + bitmap from the FINAL on-screen seat (near vs far, already
    # flipped by pbTrainerPosition), mirroring like every other element. Gated by
    # $arnet_online_intro ([010]); cleared => offline, defer to the core verbatim.
    # (The 5-frame throw-arm animation on the guest's near sprite is the residual
    # trainer-intro gap; the static picture — character + orientation — is correct.)
    unless method_defined?(:arnet_orig_pbCreateTrainerBackSprite)
      alias_method :arnet_orig_pbCreateTrainerBackSprite,  :pbCreateTrainerBackSprite
      alias_method :arnet_orig_pbCreateTrainerFrontSprite, :pbCreateTrainerFrontSprite
    end

    def pbCreateTrainerBackSprite(idxTrainer, trainerType, numTrainers = 1)
      return arnet_orig_pbCreateTrainerBackSprite(idxTrainer, trainerType, numTrainers) unless $arnet_online_intro
      arnet_build_trainer_sprite("player_#{idxTrainer + 1}", 0, idxTrainer, numTrainers)
    end

    def pbCreateTrainerFrontSprite(idxTrainer, trainerType, numTrainers = 1)
      return arnet_orig_pbCreateTrainerFrontSprite(idxTrainer, trainerType, numTrainers) unless $arnet_online_intro
      arnet_build_trainer_sprite("trainer_#{idxTrainer + 1}", 1, idxTrainer, numTrainers)
    end

    # key: engine-canonical sprite key (fade/throw target — keep it bound to the
    # calling method). canonSide: 0 for the back method, 1 for the front method.
    # We derive near/far from the flipped seat so it's right on host AND guest.
    def arnet_build_trainer_sprite(key, canonSide, idxTrainer, numTrainers)
      own  = ARNet.render_own?(canonSide)   # true => near/bottom seat (local player)
      file = own ? ARNet.own_back_sprite_file : ARNet.opp_front_sprite_file
      spriteX, spriteY = Battle::Scene.pbTrainerPosition(canonSide, idxTrainer, numTrainers)
      trainer = pbAddSprite(key, spriteX, spriteY, file, @viewport)
      return if !trainer.bitmap
      if own
        # near seat: back sprite (own gender), possibly a 5-frame throw sheet.
        trainer.z = 80 + idxTrainer
        if trainer.bitmap.width > trainer.bitmap.height * 2
          trainer.src_rect.x     = 0
          trainer.src_rect.width = trainer.bitmap.width / 5
        end
      else
        # far seat: opponent's front sprite (their gender), static single frame.
        trainer.z = 7 + idxTrainer
      end
      trainer.ox = trainer.src_rect.width / 2
      trainer.oy = trainer.bitmap.height
    end

    #--- 6) Move animations: flip the user's parity fed to the anim picker so the
    # OppMove/Move variant AND the left/right mirror match the guest's view. The
    # real user/target sprites are untouched (looked up by their true index in
    # pbAnimationCore), so only the animation's facing/side flips. ----------------
    unless method_defined?(:arnet_orig_pbFindMoveAnimation)
      alias_method :arnet_orig_pbFindMoveAnimation, :pbFindMoveAnimation
      alias_method :arnet_orig_pbSendOutBattlers,   :pbSendOutBattlers
    end
    def pbFindMoveAnimation(moveID, idxUser, hitNum)
      idxUser ^= 1 if $arnet_view_flip
      arnet_orig_pbFindMoveAnimation(moveID, idxUser, hitNum)
    end

    #--- 7) Send-out choreography: which side throws the ball / where the mon
    # appears from is chosen by @battle.opposes?(idx). We can't flip opposes?
    # (sim), so we reimplement this leaf Scene method with the two presentation
    # decisions inverted for the guest. (Trainer-throw hand may look off — that's
    # the known trainer-sprite gap; ball/appear DIRECTION is what this fixes.) ----
    def pbSendOutBattlers(sendOuts, startBattle = false)
      return arnet_orig_pbSendOutBattlers(sendOuts, startBattle) unless $arnet_view_flip
      return if sendOuts.length == 0
      while inPartyAnimation?
        pbUpdate
      end
      @briefMessage = false
      # NOTE: do NOT flip the fade. PlayerFade hides partyBar_0 and TrainerFade
      # hides partyBar_1; flipping it leaves the actually-sent side's lineup bar
      # on screen forever. Keep it tied to the real side (only the per-battler
      # send-out animation below is flipped, for correct appear direction).
      if @battle.opposes?(sendOuts[0][0])
        fadeAnim = Animation::TrainerFade.new(@sprites, @viewport, startBattle)
      else
        fadeAnim = Animation::PlayerFade.new(@sprites, @viewport, startBattle)
      end
      sendOutAnims = []
      sendOuts.each_with_index do |b, i|
        pkmn = @battle.battlers[b[0]].effects[PBEffects::Illusion] || b[1]
        pbChangePokemon(b[0], pkmn)
        pbRefresh
        if !@battle.opposes?(b[0])   # flipped
          sendOutAnim = Animation::PokeballTrainerSendOut.new(
            @sprites, @viewport, @battle.pbGetOwnerIndexFromBattlerIndex(b[0]) + 1,
            @battle.battlers[b[0]], startBattle, i
          )
        else
          sendOutAnim = Animation::PokeballPlayerSendOut.new(
            @sprites, @viewport, @battle.pbGetOwnerIndexFromBattlerIndex(b[0]) + 1,
            @battle.battlers[b[0]], startBattle, i
          )
        end
        dataBoxAnim = Animation::DataBoxAppear.new(@sprites, @viewport, b[0])
        sendOutAnims.push([sendOutAnim, dataBoxAnim, false])
      end
      loop do
        fadeAnim.update
        sendOutAnims.each do |a|
          next if a[2]
          a[0].update
          a[1].update if a[0].animDone?
          a[2] = true if a[1].animDone?
        end
        pbUpdate
        break if !inPartyAnimation? && sendOutAnims.none? { |a| !a[2] }
      end
      fadeAnim.dispose
      sendOutAnims.each do |a|
        a[0].dispose
        a[1].dispose
      end
      sendOuts.each do |b|
        next if !@battle.showAnims || !@battle.battlers[b[0]].shiny?
        if Settings::SUPER_SHINY && @battle.battlers[b[0]].super_shiny?
          pbCommonAnimation("SuperShiny", @battle.battlers[b[0]])
        else
          pbCommonAnimation("Shiny", @battle.battlers[b[0]])
        end
      end
    end
  end
end

#--- 7b) Own-mon ball throw direction on the flipped view. PokeballPlayerSendOut
# tracks the thrower's hand via @sprites["player_#{idxTrainer}"]. On the guest
# view the seat roles are swapped by [012]'s trainer-sprite builder — "player_N"
# holds the OPPONENT's far (right) sprite and "trainer_N" holds our own near
# (left) sprite — so the ball was thrown from the far side, flying right→left.
# Swap the two keys just for createProcesses so the throw originates from our own
# near sprite (left→right). PokeballTrainerSendOut needs no fix: it makes the ball
# appear at the flip-aware battler position and never tracks a trainer sprite. ---
if defined?(Battle::Scene::Animation::PokeballPlayerSendOut)
  class Battle::Scene::Animation::PokeballPlayerSendOut
    unless method_defined?(:arnet_orig_psendout_cp)
      alias_method :arnet_orig_psendout_cp, :createProcesses
    end
    def createProcesses
      return arnet_orig_psendout_cp unless $arnet_view_flip
      pk = "player_#{@idxTrainer}"
      tk = "trainer_#{@idxTrainer}"
      @sprites[pk], @sprites[tk] = @sprites[tk], @sprites[pk]
      begin
        arnet_orig_psendout_cp
      ensure
        @sprites[pk], @sprites[tk] = @sprites[tk], @sprites[pk]
      end
    end
  end
end

#--- 7c) Gimmick transformation cinematics (Mega / Primal / Dynamax / Terastal /
# Z-Move / Ultra Burst). Each of these full-screen overlays builds its OWN sprites
# and anchors the transforming Pokémon at a FIXED screen spot via
# `Battle::Scene.pbBattlerPosition(1, 1)` (dxSetPokemon / dxSetPokemonWithOutline),
# intended to be dead-center regardless of who transforms. But [012] overrides that
# class method to flip seats for the guest, so on the GUEST the anchor slides to the
# opposite side and the whole cinematic appears off-center (host is fine). The rest
# of the cinematic is drawn at center_x already. Fix: SUPPRESS the seat flip for the
# duration of the cinematic's construction (its createProcesses, which computes the
# anchor, runs inside initialize via super). With the flip suppressed the anchor is
# canonical on both peers, so the cinematic renders identically — dead-center — for
# host and guest. Display-only (never hashed); the flag is restored in an ensure so
# nothing else is affected. ----------------------------------------------------
ARNET_GIMMICK_ANIMS = %w[BattlerMegaEvolve BattlerPrimalReversion BattlerDynamax
                         BattlerDynamaxWild BattlerTerastallize BattlerZMove
                         BattlerUltraBurst].freeze
if defined?(Battle::Scene::Animation)
  ARNET_GIMMICK_ANIMS.each do |cname|
    next unless Battle::Scene::Animation.const_defined?(cname)
    klass = Battle::Scene::Animation.const_get(cname)
    # Only wrap classes that define their own initialize (all of these do).
    next unless klass.instance_method(:initialize).owner == klass
    next if klass.method_defined?(:arnet_orig_gimmick_init) ||
            klass.private_method_defined?(:arnet_orig_gimmick_init)
    klass.send(:alias_method, :arnet_orig_gimmick_init, :initialize)
    klass.send(:define_method, :initialize) do |*args, &blk|
      prev = $arnet_suppress_flip
      $arnet_suppress_flip = true
      begin
        arnet_orig_gimmick_init(*args, &blk)
      ensure
        $arnet_suppress_flip = prev
      end
    end
  end
end

#--- 2) Pokémon battler sprite: flip facing + the non-positional parity bits ----
if defined?(Battle::Scene::BattlerSprite)
  class Battle::Scene::BattlerSprite
    unless method_defined?(:arnet_orig_setPokemonBitmap)
      alias_method :arnet_orig_setPokemonBitmap, :setPokemonBitmap
      alias_method :arnet_orig_pbSetPosition,    :pbSetPosition
    end

    # `back` arrives computed from the canonical side; invert it so the guest
    # sees their own mon's back and the host's front.
    def setPokemonBitmap(pkmn, battler, back = false)
      back = !back if $arnet_view_flip
      arnet_orig_setPokemonBitmap(pkmn, battler, back)
    end

    # Position comes from the (already-flipping) class method; only z-order and
    # the front/back sprite metrics need the local parity flip.
    def pbSetPosition
      return arnet_orig_pbSetPosition unless $arnet_view_flip
      return if !@_iconBitmap
      pbSetOrigin
      di = ARNet.pres_index(@index)
      if di.even?
        self.z = 50 + (5 * di / 2)
      else
        self.z = 50 - (5 * (di + 1) / 2)
      end
      p = Battle::Scene.pbBattlerPosition(@index, @sideSize)   # class method flips
      @spriteX = p[0]
      @spriteY = p[1]
      if @substitute
        side = di.even? ? 0 : 1
        @spriteY += Settings::SUBSTITUTE_DOLL_METRICS[side]
      else
        @pkmn.species_data.apply_metrics_to_sprite(self, di)
      end
    end
  end
end

#--- 3) Shadow sprite: facing/mirror/angle/metrics derive from @index parity ----
if defined?(Battle::Scene::BattlerShadowSprite)
  class Battle::Scene::BattlerShadowSprite
    unless method_defined?(:arnet_orig_shadow_setPokemonBitmap)
      alias_method :arnet_orig_shadow_setPokemonBitmap, :setPokemonBitmap
    end
    def setPokemonBitmap(pkmn, battler, sprite)
      if $arnet_view_flip && @index
        @index ^= 1
        begin
          arnet_orig_shadow_setPokemonBitmap(pkmn, battler, sprite)
        ensure
          @index ^= 1
        end
      else
        arnet_orig_shadow_setPokemonBitmap(pkmn, battler, sprite)
      end
    end
  end
end

#--- 4) Data boxes: flip the whole box by feeding it an index-flipped battler ---
# This proxy also makes the appear/disappear slide direction (Section 8) correct,
# since those read box.battler.index.
if defined?(Battle::Scene::PokemonDataBox)
  class Battle::Scene::PokemonDataBox
    unless method_defined?(:arnet_orig_databox_initialize)
      alias_method :arnet_orig_databox_initialize, :initialize
    end
    def initialize(battler, sideSize, viewport = nil)
      battler = ARNet::MirrorBattler.new(battler) if $arnet_view_flip
      arnet_orig_databox_initialize(battler, sideSize, viewport)
    end
  end
end

#--- 5) Message perspective: "The opposing X" is player-relative. DISPLAY strings
# only (never hashed into the checksum), so safe to flip on the guest. ----------
if defined?(Battle::Battler)
  class Battle::Battler
    unless method_defined?(:arnet_orig_pbThis)
      alias_method :arnet_orig_pbThis,         :pbThis
      alias_method :arnet_orig_pbTeam,         :pbTeam
      alias_method :arnet_orig_pbOpposingTeam, :pbOpposingTeam
    end
    def pbThis(lowerCase = false)
      return arnet_orig_pbThis(lowerCase) unless $arnet_view_flip
      return name if ARNet.render_own?(index)
      lowerCase ? _INTL("the opposing {1}", name) : _INTL("The opposing {1}", name)
    end
    def pbTeam(lowerCase = false)
      return arnet_orig_pbTeam(lowerCase) unless $arnet_view_flip
      return (lowerCase ? _INTL("your team") : _INTL("Your team")) if ARNet.render_own?(index)
      lowerCase ? _INTL("the opposing team") : _INTL("The opposing team")
    end
    def pbOpposingTeam(lowerCase = false)
      return arnet_orig_pbOpposingTeam(lowerCase) unless $arnet_view_flip
      return (lowerCase ? _INTL("the opposing team") : _INTL("The opposing team")) if ARNet.render_own?(index)
      lowerCase ? _INTL("your team") : _INTL("Your team")
    end
  end
end

if defined?(Battle)
  class Battle
    unless method_defined?(:arnet_orig_pbThisEx)
      alias_method :arnet_orig_pbThisEx,             :pbThisEx
      alias_method :arnet_orig_pbMessagesOnReplace,   :pbMessagesOnReplace
      alias_method :arnet_orig_pbMessageOnRecall,     :pbMessageOnRecall
      alias_method :arnet_orig_pbStartBattleSendOut,  :pbStartBattleSendOut
    end
    def pbThisEx(idxBattler, idxParty)
      return arnet_orig_pbThisEx(idxBattler, idxParty) unless $arnet_view_flip
      party = pbParty(idxBattler)
      return party[idxParty].name if ARNet.render_own?(idxBattler)
      _INTL("The opposing {1}", party[idxParty].name)
    end

    # Switch-in message ("You're in charge, X!" vs "{owner} sent out X!"). Base
    # keys on pbOwnedByPlayer?; we swap the perspective for the guest. Original
    # wording preserved verbatim (display-only, not hashed).
    def pbMessagesOnReplace(idxBattler, idxParty)
      return arnet_orig_pbMessagesOnReplace(idxBattler, idxParty) unless arnet_online?
      party = pbParty(idxBattler)
      newPkmnName = party[idxParty].name
      # Illusion: the OWNER always sees their Pokémon's TRUE name; only the OPPONENT
      # sees the disguise (the last-in-team name the engine shows for Illusion). The
      # sprite still leads disguised — only the send-out text reveals the real name.
      if !ARNet.render_own?(idxBattler) &&
         party[idxParty].ability == :ILLUSION && !pbCheckGlobalAbility(:NEUTRALIZINGGAS)
        new_index = pbLastInTeam(idxBattler)
        newPkmnName = party[new_index].name if new_index >= 0 && new_index != idxParty
      end
      if ARNet.render_own?(idxBattler)
        opposing = @battlers[idxBattler].pbDirectOpposing
        if opposing.fainted? || opposing.hp == opposing.totalhp
          pbDisplayBrief(_INTL("You're in charge, {1}!", newPkmnName))
        elsif opposing.hp >= opposing.totalhp / 2
          pbDisplayBrief(_INTL("Go for it, {1}!", newPkmnName))
        elsif opposing.hp >= opposing.totalhp / 4
          pbDisplayBrief(_INTL("Just a little more! Hang in there, {1}!", newPkmnName))
        else
          pbDisplayBrief(_INTL("Your opponent's weak! Get 'em, {1}!", newPkmnName))
        end
      else
        owner = pbGetOwnerFromBattlerIndex(idxBattler)
        pbDisplayBrief(_INTL("\\j[{1},은,는] \\j[{2},을,를] 내보냈다!", owner.full_name, newPkmnName))
      end
    end

    # Recall message ("Come back!" vs "{owner} withdrew X!").
    def pbMessageOnRecall(battler)
      return arnet_orig_pbMessageOnRecall(battler) unless $arnet_view_flip
      if ARNet.render_own?(battler.index)
        if battler.hp <= battler.totalhp / 4
          pbDisplayBrief(_INTL("Good job, {1}! Come back!", battler.name))
        elsif battler.hp <= battler.totalhp / 2
          pbDisplayBrief(_INTL("OK, {1}! Come back!", battler.name))
        elsif battler.turnCount >= 5
          pbDisplayBrief(_INTL("{1}, that's enough! Come back!", battler.name))
        elsif battler.turnCount >= 2
          pbDisplayBrief(_INTL("{1}, come back!", battler.name))
        else
          pbDisplayBrief(_INTL("{1}, switch out! Come back!", battler.name))
        end
      else
        owner = pbGetOwnerName(battler.index)
        pbDisplayBrief(_INTL("\\j[{1},이,가] \\j[{2},을,를] 넣었다!", owner, battler.name))
      end
    end

    # First send-out at battle start. The engine keys the phrasing on raw side
    # (side 0 = "가랏! X!", side 1 = "{owner} 내보냈다!"), which is inverted for the
    # guest (whose own team is side 1). Rebuild the messages keyed on ACTUAL
    # ownership so each player sees "가랏!" for their own mon and "내보냈다!" for the
    # opponent's; choreography (opponent first) and pbSendOut animation are kept.
    def pbStartBattleSendOut(sendOuts)
      return arnet_orig_pbStartBattleSendOut(sendOuts) unless arnet_online?
      # "Want to battle" line — always the OPPONENT from the local view (the engine
      # uses @opponent; for the guest that side is side 0 = the host, i.e. @player).
      challengers = $arnet_view_flip ? @player : @opponent
      case challengers.length
      when 1
        pbDisplayPaused(_INTL("\\j[{1},이,가] 승부를 걸어왔다!", challengers[0].full_name))
      when 2
        pbDisplayPaused(_INTL("\\j[{1},과,와] \\j[{2},이,가] 승부를 걸어왔다!",
                              challengers[0].full_name, challengers[1].full_name))
      when 3
        pbDisplayPaused(_INTL("{1}, {2}, 그리고 \\j[{3},이,가] 승부를 걸어왔다!",
                              challengers[0].full_name, challengers[1].full_name,
                              challengers[2].full_name))
      end
      # Opposing side (from our view) appears first, then ours — same as the engine.
      [1, 0].each do |side|
        msg = ""
        toSendOut = []
        trainers = (side == 0) ? @player : @opponent
        trainers.each_with_index do |t, i|
          sent = sendOuts[side][i]
          next if sent.nil? || sent.empty?
          msg += "\n" if msg.length > 0
          if ARNet.render_own?(sent[0])   # our own Pokémon: the owner always sees the
            # TRUE name (even a lead disguised by Illusion). Engine's exact keys, so the
            # guest's line still matches the host's wording.
            names = sent.map { |idx| @battlers[idx].pokemon.name }
            case names.length
            when 1 then msg += _INTL("Go! {1}!", names[0])
            when 2 then msg += _INTL("Go! {1} and {2}!", names[0], names[1])
            when 3 then msg += _INTL("Go! {1}, {2} and {3}!", names[0], names[1], names[2])
            end
          else                            # opponent's Pokémon: show the Illusion disguise
            names = sent.map { |idx| @battlers[idx].name }
            case names.length
            when 1 then msg += _INTL("\\j[{1},은,는] \\j[{2},을,를] 내보냈다!", t.full_name, names[0])
            when 2 then msg += _INTL("\\j[{1},은,는] \\j[{2},과,와] \\j[{3},을,를] 내보냈다!",
                                     t.full_name, names[0], names[1])
            when 3 then msg += _INTL("\\j[{1},은,는] \\j[{2},과,와] \\j[{3},과,와] \\j[{4},을,를] 내보냈다!",
                                     t.full_name, names[0], names[1], names[2])
            end
          end
          toSendOut.concat(sent)
        end
        pbDisplayBrief(msg) if msg.length > 0
        animSendOuts = []
        toSendOut.each { |idxBattler| animSendOuts.push([idxBattler, @battlers[idxBattler].pokemon]) }
        pbSendOut(animSendOuts, true)
      end
    end
  end
end

#--- 8) Data box slide direction: the individual DataBoxAppear/Disappear derive
# left/right from @idxBox (the RAW index), so they don't flip for the guest. The
# *All variants already use box.battler.index — which is our flipped MirrorBattler
# — so we mirror that here: drive the direction from sprite.battler.index. -------
if defined?(Battle::Scene::Animation::DataBoxAppear)
  class Battle::Scene::Animation::DataBoxAppear
    unless method_defined?(:arnet_orig_dbappear_cp)
      alias_method :arnet_orig_dbappear_cp, :createProcesses
    end
    def createProcesses
      return arnet_orig_dbappear_cp unless $arnet_view_flip
      sprite = @sprites["dataBox_#{@idxBox}"]
      return if !sprite
      vertical = !sprite.is_a?(Battle::Scene::SafariDataBox) && sprite.style &&
                 GameData::DataboxStyle.get(sprite.style).vertical_anim
      if vertical
        return arnet_orig_dbappear_cp   # vertical: no left/right, already correct
      end
      dir = (sprite.battler.index.even?) ? 1 : -1   # battler = flipped proxy
      box = addSprite(sprite)
      box.setVisible(0, true) if !sprite.battler.fainted?
      box.setDelta(0, dir * Graphics.width / 2, 0)
      box.moveDelta(0, 8, -dir * Graphics.width / 2, 0)
    end
  end
end

if defined?(Battle::Scene::Animation::DataBoxDisappear)
  class Battle::Scene::Animation::DataBoxDisappear
    unless method_defined?(:arnet_orig_dbdisappear_cp)
      alias_method :arnet_orig_dbdisappear_cp, :createProcesses
    end
    def createProcesses
      return arnet_orig_dbdisappear_cp unless $arnet_view_flip
      sprite = @sprites["dataBox_#{@idxBox}"]
      return if !sprite
      vertical = !sprite.is_a?(Battle::Scene::SafariDataBox) && sprite.style &&
                 GameData::DataboxStyle.get(sprite.style).vertical_anim
      if vertical
        return arnet_orig_dbdisappear_cp
      end
      dir = (sprite.battler.index.even?) ? 1 : -1
      box = addSprite(sprite)
      box.moveDelta(0, 8, dir * Graphics.width / 2, 0)
      box.setVisible(8, false)
    end
  end
end

#--- 9) Substitute doll (DBK Animated Pokémon System): the doll's front/back
# sprite, vertical offset AND left/right slide direction are all derived from
# `@battler.opposes?` (player-relative, canonical). Under the guest's flipped
# view those come out reversed (doll leaves/enters on the wrong side). We
# reimplement the three doll animations with every opposes?-derived presentation
# routed through ARNet.pres_far? (and metrics through pres_index), matching the
# main battler sprite. Display-only; never hashed. When not flipped we defer to
# the original verbatim. -------------------------------------------------------
if defined?(Battle::Scene::Animation::SubstituteAppear)
  class Battle::Scene::Animation::SubstituteAppear
    unless method_defined?(:arnet_orig_subappear_cp)
      alias_method :arnet_orig_subappear_cp, :createProcesses
    end
    def initialize(sprites, viewport, battler)
      @battler  = battler
      @filename = "Graphics/Pokemon/substitute"
      @filename += "_back" if !ARNet.pres_far?(@battler)
      super(sprites, viewport)
    end
    def createProcesses
      return arnet_orig_subappear_cp unless $arnet_view_flip
      delay = 0
      batSprite = @sprites["pokemon_#{@battler.index}"]
      return if batSprite.substitute
      pos = Battle::Scene.pbBattlerPosition(batSprite.index, batSprite.sideSize)
      offset = ARNet.pres_far?(@battler) ? Settings::SUBSTITUTE_DOLL_METRICS[1] : Settings::SUBSTITUTE_DOLL_METRICS[0]
      substitute = addNewSprite(pos[0], pos[1] + offset - 128, @filename, PictureOrigin::BOTTOM)
      substitute.setZ(delay, batSprite.z)
      substitute.setOpacity(delay, 0)
      shadow = addSprite(@sprites["shadow_#{@battler.index}"], PictureOrigin::CENTER)
      shadow.setVisible(delay, false)
      battler = addSprite(batSprite, PictureOrigin::BOTTOM)
      dir = ARNet.pres_far?(@battler) ? Graphics.width / 2 : -Graphics.width / 2
      battler.moveDelta(delay, 6, dir, 0)
      battler.setSE(delay, "GUI party switch")
      delay = battler.totalDuration
      substitute.moveDelta(delay, 6, 0, 128)
      substitute.moveOpacity(delay, 6, 255)
      substitute.setSE(delay + 4, "Anim/Substitute")
      delay = substitute.totalDuration
      4.times do |i|
        off = (i < 2) ? 50 : 20
        off = -off if i.even?
        duration = 4 - i
        substitute.moveDelta(delay, duration, 0, off)
        delay = substitute.totalDuration
      end
    end
  end
end

if defined?(Battle::Scene::Animation::SubstituteSwapIn)
  class Battle::Scene::Animation::SubstituteSwapIn
    unless method_defined?(:arnet_orig_subswapin_cp)
      alias_method :arnet_orig_subswapin_cp, :createProcesses
    end
    def initialize(sprites, viewport, battler)
      @battler  = battler
      @filename = "Graphics/Pokemon/substitute"
      @filename += "_back" if !ARNet.pres_far?(@battler)
      super(sprites, viewport)
    end
    def createProcesses
      return arnet_orig_subswapin_cp unless $arnet_view_flip
      delay = 0
      batSprite = @sprites["pokemon_#{@battler.index}"]
      return if batSprite.substitute
      pos = Battle::Scene.pbBattlerPosition(batSprite.index, batSprite.sideSize)
      offset = ARNet.pres_far?(@battler) ? Settings::SUBSTITUTE_DOLL_METRICS[1] : Settings::SUBSTITUTE_DOLL_METRICS[0]
      substitute = addNewSprite(pos[0], pos[1] + offset, @filename, PictureOrigin::BOTTOM)
      sprite = @pictureEx.length - 1
      dir = ARNet.pres_far?(@battler) ? Graphics.width / 2 : -Graphics.width / 2
      substitute.setXY(delay, @pictureSprites[sprite].x + dir, @pictureSprites[sprite].y)
      substitute.setZ(delay, batSprite.z)
      substitute.setVisible(delay, false)
      shadow = addSprite(@sprites["shadow_#{@battler.index}"], PictureOrigin::CENTER)
      shadow.setVisible(delay, false)
      battler = addSprite(batSprite, PictureOrigin::BOTTOM)
      battler.moveDelta(delay, 6, dir, 0)
      battler.setSE(delay, "GUI party switch")
      delay = battler.totalDuration
      battler.setVisible(delay, false)
      substitute.setVisible(delay, true)
      substitute.moveDelta(delay, 6, -dir, 0)
    end
  end
end

if defined?(Battle::Scene::Animation::SubstituteSwapOut)
  class Battle::Scene::Animation::SubstituteSwapOut
    unless method_defined?(:arnet_orig_subswapout_cp)
      alias_method :arnet_orig_subswapout_cp, :createProcesses
    end
    # (no @filename in initialize — the real Pokémon sprite is rebuilt here — so
    # only createProcesses needs the presentation flip.)
    def createProcesses
      return arnet_orig_subswapout_cp unless $arnet_view_flip
      delay = 0
      batSprite = @sprites["pokemon_#{@battler.index}"]
      return if !batSprite.substitute
      pos = Battle::Scene.pbBattlerPosition(batSprite.index, batSprite.sideSize)
      pokemon = addPokeSprite(@pkmn, !ARNet.pres_far?(@battler), PictureOrigin::BOTTOM)
      sprite = @pictureEx.length - 1
      @pictureSprites[sprite].x = pos[0]
      @pictureSprites[sprite].y = pos[1]
      metrics_data = GameData::SpeciesMetrics.get_species_form(@pkmn.species, @pkmn.form, @pkmn.female?)
      metrics_data.apply_metrics_to_sprite(@pictureSprites[sprite], ARNet.pres_index(batSprite.index))
      dir = ARNet.pres_far?(@battler) ? Graphics.width / 2 : -Graphics.width / 2
      pokemon.setXY(delay, @pictureSprites[sprite].x + dir, @pictureSprites[sprite].y)
      pokemon.setZ(delay, batSprite.z)
      pokemon.setVisible(delay, false)
      shadow = addSprite(@sprites["shadow_#{@battler.index}"], PictureOrigin::CENTER)
      shadow.setVisible(delay, false)
      battler = addSprite(batSprite, PictureOrigin::BOTTOM)
      if @broken
        battler.moveOpacity(delay, 8, 0)
      else
        battler.moveDelta(delay, 6, dir, 0)
        battler.setSE(delay, "GUI party switch")
      end
      delay = battler.totalDuration
      battler.setVisible(delay, false)
      battler.setOpacity(delay, 255)
      pokemon.setVisible(delay, true)
      pokemon.moveDelta(delay, 6, -dir, 0)
    end
  end
end

#--- 10) Ability splash bar (Intimidate, Levitate, Drizzle, Sturdy, Trace…): the
# scene picks `abilityBar_#{battler.index % 2}` and its slide direction from the
# battler's side, so the guest sees every ability pop up on the WRONG side (own
# abilities on the foe bar and vice-versa). This fires constantly in-battle. Same
# trick as the data boxes: hand the scene an index-flipped MirrorBattler so the
# side (bar choice + direction + alignment) mirrors, while name/ability/etc. still
# read correctly via delegation. Guard against double-wrap: the original
# pbShowAbilitySplash calls pbHideAbilitySplash internally (which re-enters this
# override) — respond_to?(:__real__) is true only for an already-wrapped proxy. -
if defined?(Battle::Scene) && Battle::Scene.method_defined?(:pbShowAbilitySplash)
  class Battle::Scene
    unless method_defined?(:arnet_orig_pbShowAbilitySplash)
      alias_method :arnet_orig_pbShowAbilitySplash,    :pbShowAbilitySplash
      alias_method :arnet_orig_pbHideAbilitySplash,    :pbHideAbilitySplash
      alias_method :arnet_orig_pbReplaceAbilitySplash, :pbReplaceAbilitySplash
    end
    def arnet_mirror_battler(battler)
      return battler unless $arnet_view_flip
      return battler if battler.respond_to?(:__real__)   # already a proxy
      ARNet::MirrorBattler.new(battler)
    end
    def pbShowAbilitySplash(battler)
      arnet_orig_pbShowAbilitySplash(arnet_mirror_battler(battler))
    end
    def pbHideAbilitySplash(battler)
      arnet_orig_pbHideAbilitySplash(arnet_mirror_battler(battler))
    end
    def pbReplaceAbilitySplash(battler)
      arnet_orig_pbReplaceAbilitySplash(arnet_mirror_battler(battler))
    end
  end
end

#--- 11) Party lineup bar (the remaining-Poké-Ball count that slides in at battle
# start AND on every mid-battle switch): LineupAppear derives the bar/ball
# sprite POSITIONS and slide DIRECTION from @side, so the guest sees their own
# count in the far (foe) seat. We must NOT change which partyBar_#{side} sprite a
# side uses — that key is hard-wired to the fade that hides it (PlayerFade->bar0,
# TrainerFade->bar1, opacity->0 regardless of fullAnim), and decoupling it is what
# caused the earlier "lineup never disappears" regression. So we keep the sprite
# KEY canonical (@side) and flip only the POSITION + slide direction via
# pres_index. Fades stay matched => the bar always disappears; only its seat
# mirrors. ---------------------------------------------------------------------
if defined?(Battle::Scene::Animation::LineupAppear)
  class Battle::Scene::Animation::LineupAppear
    unless method_defined?(:arnet_orig_lineup_resetgfx)
      alias_method :arnet_orig_lineup_resetgfx, :resetGraphics
      alias_method :arnet_orig_lineup_cp,       :createProcesses
    end
    def resetGraphics(sprites)
      return arnet_orig_lineup_resetgfx(sprites) unless $arnet_view_flip
      bar = sprites["partyBar_#{@side}"]     # KEY stays canonical (fade match)
      ps  = ARNet.pres_index(@side)          # POSITION uses the mirrored seat
      case ps
      when 0   # near/player seat (bottom-right)
        barX  = Graphics.width - BAR_DISPLAY_WIDTH
        barY  = Graphics.height - 142
        ballX = barX + 44
        ballY = barY - 30
      when 1   # far/opposing seat (top-left)
        barX  = BAR_DISPLAY_WIDTH
        barY  = 114
        ballX = barX - 44 - 30
        ballY = barY - 30
        barX -= bar.bitmap.width
      end
      ballXdiff = 32 * (1 - (2 * ps))
      bar.x       = barX
      bar.y       = barY
      bar.opacity = 255
      bar.visible = false
      Battle::Scene::NUM_BALLS.times do |i|
        ball = sprites["partyBall_#{@side}_#{i}"]
        ball.x       = ballX
        ball.y       = ballY
        ball.opacity = 255
        ball.visible = false
        ballX += ballXdiff
      end
    end
    def createProcesses
      return arnet_orig_lineup_cp unless $arnet_view_flip
      bar = addSprite(@sprites["partyBar_#{@side}"])
      bar.setVisible(0, true)
      dir = (ARNet.pres_index(@side) == 0) ? 1 : -1   # slide from the mirrored seat
      bar.setDelta(0, dir * Graphics.width / 2, 0)
      bar.moveDelta(0, 8, -dir * Graphics.width / 2, 0)
      delay = bar.totalDuration
      Battle::Scene::NUM_BALLS.times do |i|
        createBall(i, (@fullAnim) ? delay + (i * 2) : 0, dir)   # createBall: key @side, dir mirrored
      end
    end
  end
end

#--- 12) Trainer/lineup fade-out slide DIRECTION. Canonically PlayerFade slides
# player_N off to the LEFT and TrainerFade slides trainer_N off to the RIGHT. On
# the guest those keys hold the OPPONENT (far) and the LOCAL player (near)
# respectively, so both slide the wrong way. We keep the sprite KEYS canonical
# (the fade<->bar coupling that guarantees the lineup disappears must not change —
# see section 11) and only NEGATE the horizontal deltas when flipped, so from the
# local seat the opponent always exits RIGHT and the local player exits LEFT.
# Opacity fades are untouched. When not flipped we defer to the core verbatim.
if defined?(Battle::Scene::Animation::PlayerFade)
  class Battle::Scene::Animation::PlayerFade
    unless method_defined?(:arnet_orig_playerfade_cp)
      alias_method :arnet_orig_playerfade_cp, :createProcesses
    end
    def createProcesses
      return arnet_orig_playerfade_cp unless $arnet_view_flip
      i = 1
      while @sprites["player_#{i}"]
        pl = @sprites["player_#{i}"]
        i += 1
        next if !pl.visible || pl.x < 0
        trainer = addSprite(pl, PictureOrigin::BOTTOM)
        trainer.moveDelta(0, 16, Graphics.width / 2, 0)   # flipped: exit RIGHT
        if pl.bitmap && !pl.bitmap.disposed? && pl.bitmap.width >= pl.bitmap.height * 2
          size = pl.src_rect.width
          trainer.setSrc(0, size, 0)
          trainer.setSrc(5, size * 2, 0)
          trainer.setSrc(7, size * 3, 0)
          trainer.setSrc(9, size * 4, 0)
        end
        trainer.setVisible(16, false)
      end
      delay = 3
      if @sprites["partyBar_0"]&.visible
        partyBar = addSprite(@sprites["partyBar_0"])
        partyBar.moveDelta(delay, 16, Graphics.width / 4, 0) if @fullAnim
        partyBar.moveOpacity(delay, 12, 0)
        partyBar.setVisible(delay + 12, false)
        partyBar.setOpacity(delay + 12, 255)
      end
      Battle::Scene::NUM_BALLS.times do |j|
        next if !@sprites["partyBall_0_#{j}"] || !@sprites["partyBall_0_#{j}"].visible
        partyBall = addSprite(@sprites["partyBall_0_#{j}"])
        partyBall.moveDelta(delay + (2 * j), 16, Graphics.width, 0) if @fullAnim
        partyBall.moveOpacity(delay, 12, 0)
        partyBall.setVisible(delay + 12, false)
        partyBall.setOpacity(delay + 12, 255)
      end
    end
  end
end

if defined?(Battle::Scene::Animation::TrainerFade)
  class Battle::Scene::Animation::TrainerFade
    unless method_defined?(:arnet_orig_trainerfade_cp)
      alias_method :arnet_orig_trainerfade_cp, :createProcesses
    end
    def createProcesses
      return arnet_orig_trainerfade_cp unless $arnet_view_flip
      i = 1
      while @sprites["trainer_#{i}"]
        trSprite = @sprites["trainer_#{i}"]
        i += 1
        next if !trSprite.visible || trSprite.x > Graphics.width
        trainer = addSprite(trSprite, PictureOrigin::BOTTOM)
        trainer.moveDelta(0, 16, -Graphics.width / 2, 0)   # flipped: exit LEFT
        trainer.setVisible(16, false)
      end
      delay = 3
      if @sprites["partyBar_1"]&.visible
        partyBar = addSprite(@sprites["partyBar_1"])
        partyBar.moveDelta(delay, 16, -Graphics.width / 4, 0) if @fullAnim
        partyBar.moveOpacity(delay, 12, 0)
        partyBar.setVisible(delay + 12, false)
        partyBar.setOpacity(delay + 12, 255)
      end
      Battle::Scene::NUM_BALLS.times do |j|
        next if !@sprites["partyBall_1_#{j}"] || !@sprites["partyBall_1_#{j}"].visible
        partyBall = addSprite(@sprites["partyBall_1_#{j}"])
        partyBall.moveDelta(delay + (2 * j), 16, -Graphics.width, 0) if @fullAnim
        partyBall.moveOpacity(delay, 12, 0)
        partyBall.setVisible(delay + 12, false)
        partyBall.setOpacity(delay + 12, 255)
      end
    end
  end
end

#--- 9) End-of-battle result perspective + clean WIN/LOSE banner ----------------
# pbEndOfBattle prints the win/lose text AND plays the victory/defeat cue from
# side0's (host's) point of view, so the guest would otherwise see the HOST's
# result ("호스트와 게스트에게 동일하게 표시됨"). The simulation is canonical, so we
# flip PRESENTATION only: for the guest we invert @decision (win<->lose) and swap
# the @player/@opponent trainer arrays around the core call, then restore.
#   - The core cleanup (item restore, party loop) reads the side0/side1 arrays
#     directly (pbParty, @initialItems/@usedInBattle), NOT these trainer objects,
#     so the swap changes ONLY the displayed names/lose_text/win_text and which
#     result fanfare pbEndBattle plays.
#   - pbGainMoney/pbLoseMoney are no-ops here (@internalBattle=false, moneyGain=false).
#   - Draw (@decision==5) is symmetric, so it is left unchanged.
# For ONLINE battles we also (a) SILENCE the trainer sprite + "…" win/lose speech
# ($arnet_end_quiet gates pbDisplayPaused/pbShowOpponent below — the NPC-trainer
# speech is meaningless in PvP) and (b) show a clean WIN/LOSE/DRAW banner instead,
# skipped only when the link dropped (:disconnect/:desync).
if defined?(Battle)
  class Battle
    unless method_defined?(:arnet_orig_pbEndOfBattle)
      alias_method :arnet_orig_pbEndOfBattle, :pbEndOfBattle
    end
    def pbEndOfBattle
      return arnet_orig_pbEndOfBattle unless (arnet_online? rescue @arnet)
      if $arnet_view_flip
        canonical = @decision
        @decision = 2 if canonical == 1   # host win  -> guest lost
        @decision = 1 if canonical == 2   # host lost -> guest won
        saved_player, saved_opponent = @player, @opponent
        @player, @opponent = @opponent, @player   # local player = side1 (self)
        local = @decision
        begin
          $arnet_end_quiet = true
          arnet_orig_pbEndOfBattle
        ensure
          $arnet_end_quiet = false
          @decision = canonical
          @player   = saved_player
          @opponent = saved_opponent
        end
        (ARNet.show_battle_result(self, local) rescue nil)
        return @decision
      else
        local = @decision                 # host: side0 view is already local
        begin
          $arnet_end_quiet = true
          ret = arnet_orig_pbEndOfBattle
        ensure
          $arnet_end_quiet = false
        end
        (ARNet.show_battle_result(self, local) rescue nil)
        return ret
      end
    end
  end

  # Silence the NPC-trainer end-of-battle speech + sprite for online battles only
  # (gated on $arnet_end_quiet, set solely around the pbEndOfBattle core above).
  class Battle
    unless method_defined?(:arnet_orig_pbDisplayPaused)
      alias_method :arnet_orig_pbDisplayPaused, :pbDisplayPaused
    end
    def pbDisplayPaused(*args, &blk)
      return if $arnet_end_quiet
      arnet_orig_pbDisplayPaused(*args, &blk)
    end
  end
  if defined?(Battle::Scene) && Battle::Scene.method_defined?(:pbShowOpponent)
    class Battle::Scene
      unless method_defined?(:arnet_orig_pbShowOpponent)
        alias_method :arnet_orig_pbShowOpponent, :pbShowOpponent
      end
      def pbShowOpponent(*args, &blk)
        return if $arnet_end_quiet
        arnet_orig_pbShowOpponent(*args, &blk)
      end
    end
  end
end

#--- 9b) TargetMenu button mirror (doubles): swap row/col for the guest ----------
# The TargetMenu places even-index buttons on the BOTTOM row (player side) and
# odd-index buttons on the TOP row (opponent side). The guest's battler sprites
# and data boxes are already mirrored (section 1–8), but the target-selection
# buttons are NOT — so the guest sees their own Pokémon buttons on the wrong row.
# We patch initialize (Y+X positions) and refreshButtons (button colour type) to
# swap even↔odd presentation when $arnet_view_flip is set. Display-only; the
# canonical indices used for targeting are unchanged.
if defined?(Battle::Scene::TargetMenu)
  class Battle::Scene::TargetMenu
    unless method_defined?(:arnet_orig_target_init)
      alias_method :arnet_orig_target_init, :initialize
    end
    def initialize(viewport, z, sideSizes)
      arnet_orig_target_init(viewport, z, sideSizes)
      return unless $arnet_view_flip
      # Reposition every button: swap the row (top↔bottom) and mirror the
      # horizontal order within each side so the leftmost mon from the guest's
      # perspective stays on the left.
      @buttons.each_with_index do |button, i|
        next unless button
        numButtons = @sideSizes[i % 2]
        # --- Y: swap top/bottom row ---
        # Original: button.y = self.y + 6 + (BUTTON_HEIGHT - 4) * ((i + 1) % 2)
        # Mirrored: flip the row selector ((i+1)%2 → i%2)
        button.y = self.y + 6 + (BUTTON_HEIGHT - 4) * (i % 2)
        # --- X: mirror horizontal order ---
        # Original inc:  even → i/2,  odd → numButtons-1-(i/2)
        # Mirrored inc:  even → numButtons-1-(i/2),  odd → i/2
        inc = (i.even?) ? numButtons - 1 - (i / 2) : i / 2
        if @smallButtons
          base_x = self.x + 170 - [0, 82, 166][numButtons - 1]
        else
          base_x = self.x + 138 - [0, 116][numButtons - 1]
        end
        button.x = base_x + (button.src_rect.width - 4) * inc
      end
    end

    unless method_defined?(:arnet_orig_refreshButtons)
      alias_method :arnet_orig_refreshButtons, :refreshButtons
    end
    def refreshButtons
      arnet_orig_refreshButtons
      return unless $arnet_view_flip
      # Fix button colour type: the base refreshButtons uses (i.even?) to pick
      # player(1) vs opponent(2) colour. Under the flipped view the roles are
      # swapped, so we redo the src_rect.y calculation with (i.odd?) instead.
      @buttons.each_with_index do |button, i|
        next unless button
        buttonType = 0
        if @texts[i]
          buttonType = (i.odd?) ? 1 : 2   # swapped from original (i.even?)
        end
        buttonType = (2 * buttonType) + ((@smallButtons) ? 1 : 0)
        button.src_rect.y = buttonType * BUTTON_HEIGHT
      end
      # Redraw text overlay since button positions differ from default.
      @overlay.bitmap.clear
      textpos = []
      @buttons.each_with_index do |button, i|
        next if !button || nil_or_empty?(@texts[i])
        x = button.x - self.x + (button.src_rect.width / 2)
        y = button.y - self.y + 14
        textpos.push([@texts[i], x, y, :center, TEXT_BASE_COLOR, TEXT_SHADOW_COLOR])
      end
      pbDrawTextPositions(@overlay.bitmap, textpos)
    end
  end
end

#--- 10) Target selection (doubles): up/down is cross-side -----------------------
# The guest's view is mirrored top<->bottom, so the core chooser's UP/DOWN branch
# (which jumps to the OPPOSING side) feels inverted: from the guest's own row at
# the bottom, pressing UP should target the opponents on top. We copy the core
# chooser verbatim EXCEPT that one UP/DOWN branch, which we swap for the guest.
# Left/Right (same-side) and the highlight (follows the already-mirrored sprites)
# are unchanged. Display-only; the chosen target index is canonical and hashed as
# usual, so determinism is unaffected. Gated on $arnet_view_flip (guest only).
if defined?(Battle::Scene)
  class Battle::Scene
    unless method_defined?(:arnet_orig_pbChooseTarget)
      alias_method :arnet_orig_pbChooseTarget, :pbChooseTarget
    end
    def pbChooseTarget(idxBattler, target_data, visibleSprites = nil)
      unless $arnet_view_flip
        return arnet_orig_pbChooseTarget(idxBattler, target_data, visibleSprites)
      end
      pbShowWindow(TARGET_BOX)
      cw = @sprites["targetWindow"]
      texts = pbCreateTargetTexts(idxBattler, target_data)
      mode = (target_data.num_targets == 1) ? 0 : 1
      cw.setDetails(texts, mode)
      cw.index = pbFirstTarget(idxBattler, target_data)
      pbSelectBattler((mode == 0) ? cw.index : texts, 2)
      pbFadeInAndShow(@sprites, visibleSprites) if visibleSprites
      ret = -1
      loop do
        oldIndex = cw.index
        pbUpdate(cw)
        if mode == 0   # Choosing just one target, can change index
          if Input.trigger?(Input::LEFT) || Input.trigger?(Input::RIGHT)
            inc = (cw.index.even?) ? -2 : 2
            inc *= -1 if Input.trigger?(Input::RIGHT)
            indexLength = @battle.sideSizes[cw.index % 2] * 2
            newIndex = cw.index
            loop do
              newIndex += inc
              break if newIndex < 0 || newIndex >= indexLength
              next if texts[newIndex].nil?
              cw.index = newIndex
              break
            end
          elsif (Input.trigger?(Input::DOWN) && cw.index.even?) ||
                (Input.trigger?(Input::UP)   && cw.index.odd?)   # UP/DOWN swapped for the mirrored view
            tryIndex = @battle.pbGetOpposingIndicesInOrder(cw.index)
            tryIndex.each do |idxBattlerTry|
              next if texts[idxBattlerTry].nil?
              cw.index = idxBattlerTry
              break
            end
          end
          if cw.index != oldIndex
            pbPlayCursorSE
            pbSelectBattler(cw.index, 2)
          end
        end
        if Input.trigger?(Input::USE)     # Confirm
          ret = cw.index
          pbPlayDecisionSE
          break
        elsif Input.trigger?(Input::BACK)   # Cancel
          ret = -1
          pbPlayCancelSE
          break
        end
      end
      pbSelectBattler(-1)
      return ret
    end
  end
end

#--- 11) Clean WIN / LOSE / DRAW banner ----------------------------------------
# Shown at the very end of an online battle (from pbEndOfBattle above), replacing
# the NPC-trainer speech/sprite. `decision` is already in the LOCAL player's
# perspective (host = canonical, guest = flipped). Skipped when the link dropped
# (:disconnect / :desync) — those end via a separate notice in [011].
module ARNet
  module_function

  def show_battle_result(battle, decision)
    reason = (battle.instance_variable_get(:@arnet_abort_reason) rescue nil)
    return if reason == :disconnect || reason == :desync
    case decision
    when 1 then _result_banner(_INTL("WIN!"),  Color.new(255, 216, 64),  Color.new(120, 72, 0))
    when 2 then _result_banner(_INTL("LOSE"),  Color.new(128, 176, 255), Color.new(24, 40, 88))
    when 5 then _result_banner(_INTL("DRAW"),  Color.new(216, 216, 216), Color.new(56, 56, 56))
    end
  rescue
    nil
  end

  def _result_banner(text, color, shadow)
    vp  = Viewport.new(0, 0, Graphics.width, Graphics.height)
    vp.z = 999_999
    spr = Sprite.new(vp)
    spr.bitmap = Bitmap.new(Graphics.width, Graphics.height)
    b = spr.bitmap
    (pbSetSystemFont(b) rescue nil)
    cx = Graphics.width / 2
    cy = Graphics.height / 2
    band = 132
    # Opaque black over the WHOLE screen first, so the overworld map (the player
    # standing in the Pokémon Center with the nurse NPC) isn't visible behind the
    # result — just a clean black backdrop.
    b.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(0, 0, 0, 255))
    b.fill_rect(0, cy - band / 2, Graphics.width, band, Color.new(0, 0, 0, 255))
    b.fill_rect(0, cy - band / 2,        Graphics.width, 3, color)
    b.fill_rect(0, cy + band / 2 - 3,    Graphics.width, 3, color)
    b.font.size = 72
    pbDrawTextPositions(b, [[text, cx, cy - 44, :center, color, shadow, :outline]])
    frames = 0
    loop do
      Graphics.update
      Input.update
      frames += 1
      break if frames > 150   # ~2.5s at 60fps
      break if frames > 24 && (Input.trigger?(Input::USE) || Input.trigger?(Input::BACK))
    end
  ensure
    (spr.bitmap.dispose rescue nil)
    (spr.dispose rescue nil)
    (vp.dispose rescue nil)
  end
end
