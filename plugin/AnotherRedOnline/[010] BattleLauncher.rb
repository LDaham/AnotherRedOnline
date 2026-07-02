#===============================================================================
# Another Red Online — online battle launcher (Phase 4, entry point)
#
# Builds the canonical battle from a :battle_ready info hash and runs it. Both
# peers construct the IDENTICAL battle object from the exchanged team JSON:
#   party1 (side0) = host team, party2 (side1) = guest team — on BOTH machines.
# This keeps battler indices (and therefore PRNG draw order / speed-tie breaks)
# identical, which is what makes the lockstep deterministic.
#
# The real $player is placed in the local human's own side slot so ownership/
# names read correctly locally; trainer identity does not affect the simulation
# or the checksum. `internalBattle=false` makes Pokédex registration a no-op, so
# the guest's side0 trainer being an NPCTrainer (no pokedex) never crashes, and
# online battles never touch the player's real dex/save.
#
# SCOPE (v1): SINGLES (full6 / single3). See BattleLockstep scope notes.
# Guest-side presentation is mirrored (guest views from side1's seat) — see [012];
# the sim stays canonical (side0=host) so the lockstep is unaffected.
# KNOWN REMAINING before real matches are fully correct:
#   - in-game shakedown of @player=NPCTrainer edge paths (run to win/loss text)
#   - mirror polish: send-out shadow zoom, trainer intro sprite, battle text names
# (faint/mid-battle forced replacement is now network-synced — see BattleLockstep.)
#===============================================================================
module ARNet
  module_function

  # info: the hash from Session#on_battle_ready. Returns [outcome, abort_reason].
  #   outcome (Essentials decision): 1=side0/host win, 2=side0 loss, 5=draw/no-contest.
  def start_online_battle(session, info)
    side    = info["side"]
    ruleset = info["ruleset"] || ARNet.default_ruleset

    # Rebuild BOTH teams from the exchanged JSON (identical objects on both peers),
    # mapped to canonical sides: side0 = host, side1 = guest.
    host_data,  host_picks  = (side == 0) ? [info["my_team"], info["my_picks"]] :
                                            [info["peer_team"], info["peer_picks"]]
    guest_data, guest_picks = (side == 0) ? [info["peer_team"], info["peer_picks"]] :
                                            [info["my_team"], info["my_picks"]]

    ok_h, host_full  = ARNet::Team.data_to_party(host_data, ruleset)
    ok_g, guest_full = ARNet::Team.data_to_party(guest_data, ruleset)
    raise "ARNet: team rebuild failed (#{host_full} / #{guest_full})" unless ok_h && ok_g

    host_party  = _apply_picks(host_full,  host_picks)
    guest_party = _apply_picks(guest_full, guest_picks)

    # Trainer objects. side0 = host (player slot), side1 = guest (OPPONENT slot).
    # CRITICAL: the opponent (side1) MUST be an NPCTrainer — pbEndOfBattle calls
    # win_text/lose_text on it, and the Player class has neither. So $player may
    # only ever occupy the side0 (player) slot, and only on the host machine.
    ttype     = $player.trainer_type
    host_name  = (side == 0) ? $player.name : (session.opponent_name || "Host")
    guest_name = (side == 0) ? (session.opponent_name || "Rival") : $player.name

    if side == 0   # I am the host → keep my real $player in the player slot.
      player_trainer = $player
    else           # I am the guest → the host side is a cosmetic NPCTrainer.
      player_trainer = NPCTrainer.new(host_name, ttype)
      player_trainer.party = host_party
    end
    foe_trainer = NPCTrainer.new(guest_name, ttype)   # side1 = always NPCTrainer
    foe_trainer.party = guest_party

    # Double battle reuses the engine's native 2v2. It is ONE trainer per side
    # controlling two Pokémon — the "double" comes solely from @sideSizes=[2,2]
    # (set via setBattleMode below), NOT from party1starts/party2starts.
    # ⚠️ party1starts is the per-TRAINER party offset array (where each trainer's
    # sub-party begins in the combined party), NOT "which battler slots start".
    # Setting it to [0,1] told the engine there were TWO trainers on the side
    # (trainer0 = party[0], trainer1 = party[1..]), which crashed pbEnsureParticipants
    # ("트레이너 2의 포켓몬이 들어갈 자리가 없습니다"). Leave it at the default [0]
    # (single trainer); setBattleMode("double") alone makes it a 2v2 double.
    dbl = (info["format"] == ARNet::FORMAT_DOUBLE4)

    scene  = BattleCreationHelperMethods.create_battle_scene
    battle = Battle.new(scene, host_party, guest_party, player_trainer, foe_trainer)
    battle.internalBattle   = false   # no Exp/dex/save side effects (battle-only)
    battle.expGain          = false
    battle.moneyGain        = false
    battle.disablePokeBalls = true
    battle.canRun           = false   # leaving is a forfeit, handled by the lockstep
    battle.canLose          = true    # losing must not black out / game over

    # Attach the network link (sets @arnet_side, seeds the shared PRNG) and run.
    link = ARNet::BattleLink.new(session)
    link.scene = scene   # let the frame-pumped wait tick idle animations (see [008])
    battle.arnet_attach(link)
    battle.arnet_ruleset = ruleset   # chess-clock config lives in the ruleset (see [014])

    # Backdrop: online battles have no map, so the backdrop defaults to "indoor1"
    # (or "" => black). Force a neutral arena via the battle-rule system — note
    # prepare_battle OVERWRITES battle.backdrop from battleRules["backdrop"], so a
    # direct assignment here would be clobbered; the rule is the supported path.
    # (Sim/checksum never touch the backdrop — pure presentation.)
    # Set side sizes on the battle DIRECTLY: setBattleRule only writes to
    # $PokemonTemp.battleRules, which our manual Battle.new never applies. Battle
    # #setBattleMode sets @sideSizes (=[2,2] for double) before pbStartBattle
    # builds the battler slots.
    battle.setBattleMode(dbl ? "double" : "single") if battle.respond_to?(:setBattleMode)
    setBattleRule("backdrop", ARNet::BATTLE_BACKDROP) if defined?(setBattleRule)
    BattleCreationHelperMethods.prepare_battle(battle)
    battle.backdrop = ARNet::BATTLE_BACKDROP if battle.backdrop.to_s.empty?   # safety net
    $game_temp.clear_battle_rules if $game_temp.respond_to?(:clear_battle_rules)

    # Guest (side1) views the battle mirrored so they see their own team in the
    # near seat. Simulation stays canonical; only presentation flips. See [012].
    # Battle BGM: we call battle.pbStartBattle directly, bypassing the overworld
    # encounter path (pbBattleAnimation) that normally starts the battle music, so
    # the field/PC (Pokémon Center) BGM would otherwise keep looping. Play the
    # arena track; the caller ([011]) restores the field BGM when the whole online
    # flow ends (selection played SELECT_BGM, this plays BATTLE_BGM).
    pbBGMPlay(ARNet::BATTLE_BGM, 80) rescue nil   # 80% volume

    outcome = nil
    # Trainer intro sprites: the local player always sees their OWN back sprite
    # near and the OPPONENT's front sprite far, on both host and guest. We use the
    # ACTUAL trainer types (exchanged in the handshake) with the engine's own
    # filename methods, so each sprite matches what that player really is. The
    # $arnet_online_intro flag gates [012]'s override (cleared => offline/core).
    $arnet_my_ttype  = ($player.trainer_type rescue nil)
    $arnet_opp_ttype = (session.opponent_trainer_type rescue nil)
    $arnet_online_intro = true
    $arnet_view_flip = (side == 1)
    begin
      pbSceneStandby { outcome = battle.pbStartBattle }
    ensure
      $arnet_view_flip    = false
      $arnet_online_intro = false
      $arnet_my_ttype     = nil
      $arnet_opp_ttype    = nil
    end
    [outcome, battle.arnet_abort_reason]
  end

  # Select & order the battle party from the full 6 using selection indices.
  # picks=nil (full6) => use all in original order.
  def _apply_picks(full, picks)
    return full unless picks
    picks.map { |i| full[i] }.compact
  end
end
