#===============================================================================
# Another Red Online — lockstep battle loop hook (Phase 4)
#
# Overrides the command phase so that, instead of "player side = local input,
# foe side = AI", we drive: MY session side = local input, OTHER side = received
# over the network. Both peers run the identical canonical battle (side0=host,
# side1=guest) with the shared seeded PRNG, so the attack/end-of-round phases run
# untouched and deterministically. End of each round we exchange a state checksum
# to catch any desync immediately.
#
# SCOPE (v1): SINGLES only (single3 — one active battler per side).
#   - Doubles (double4) needs multi-battler menu back-navigation + target sync. TODO.
#   - Battle mechanics (Mega/Tera/Dynamax/Z) are DISABLED online until their toggles
#     are transmitted — otherwise one peer megas and the other doesn't => desync.
#   - Bag items are disabled by ruleset.
#===============================================================================
class Battle
  attr_accessor :arnet, :arnet_side
  attr_reader   :arnet_abort_reason

  # Attach the network link to this battle: stores side, seeds the PRNG.
  def arnet_attach(link)
    @arnet      = link
    @arnet_side = link.side
    ARNet.attach_prng(self, link.seed)
  end

  def arnet_online?; !@arnet.nil?; end

  # Active battler indices on MY side (singles => one). side = index parity.
  def arnet_my_active_indices
    res = []
    @battlers.each_with_index do |b, i|
      res << i if b && (i % 2) == @arnet_side && pbCanShowCommands?(i)
    end
    res
  end

  #=============================================================================
  # Command phase override
  #=============================================================================
  alias_method :arnet_orig_pbCommandPhase, :pbCommandPhase
  def pbCommandPhase
    return arnet_orig_pbCommandPhase unless arnet_online?
    @command_phase = true
    @scene.pbBeginCommandPhase
    @battlers.each_with_index { |b, i| pbClearChoice(i) if b && pbCanShowCommands?(i) }
    2.times do |side|
      @megaEvolution[side].each_with_index { |m, i| @megaEvolution[side][i] = -1 if m && m >= 0 }
    end

    # 1) Local input for my side. In doubles the player may press Cancel on the
    # SECOND Pokémon to go back and redo the FIRST one's action (mirrors the core
    # command phase). Both Pokémon SHARE one per-turn clock — [014] starts it once
    # around the whole command phase, so the two decisions split the same time.
    indices = arnet_my_active_indices
    i = 0
    while i < indices.length
      idx = indices[i]
      result = arnet_run_choice_menu(idx, i > 0)   # allow "back" on every battler but the first
      case result
      when :back
        pbClearChoice(idx)                # drop this (uncommitted) choice
        i -= 1
        pbClearChoice(indices[i])         # re-open the previous battler's choice
        next
      when false
        @command_phase = false; return    # forfeit / abort already set @decision
      end
      if @decision != 0
        @command_phase = false; return
      end
      i += 1
    end

    # 2) Exchange choices with the peer
    unless arnet_exchange_choices
      @command_phase = false; return
    end
    @command_phase = false
  end

  # Trimmed single-battler command menu: Fight / Pokémon / Run(=forfeit).
  # Bag disabled (ruleset). Mega/etc. disabled online. Returns false on forfeit/abort.
  # Returns true (committed), false (forfeit/abort), or :back (Cancel pressed to
  # return to the previous battler — doubles only, when allowBack is true).
  def arnet_run_choice_menu(idx, allowBack = false)
    return true if @choices[idx][0] != :None || !pbCanShowCommands?(idx)
    # While the (blocking) selection menus run, the scene's per-frame update polls
    # the session (see arnet_menu_poll); if the peer forfeits/leaves mid-menu it
    # raises ARNet::PeerGone so we react immediately instead of only after the
    # local player commits an action.
    @arnet_in_menu = true
    begin
      loop do
        # firstAction = !allowBack: on the FIRST battler the 4th button is "Run"
        # (forfeit) and B does nothing; on later battlers it becomes "Cancel" and
        # B / Cancel returns -1, letting the player redo the previous choice.
        cmd = pbCommandMenu(idx, !allowBack)
        case cmd
        when -1  # Cancel => go back to the previous Pokémon (doubles)
          return :back if allowBack
          # first battler: nothing to go back to; just re-show the menu
        when 0   # Fight
          if pbFightMenu(idx)
            arnet_strip_mechanics(idx)
            return true
          end
        when 1   # Bag — disabled
          pbDisplay(_INTL("링크 대전에서는 가방을 사용할 수 없습니다."))
        when 2   # Pokémon
          return true if pbPartyMenu(idx)
        when 3   # Run => forfeit
          if pbConfirmMessage(_INTL("정말 기권하시겠습니까?"))
            arnet_do_forfeit
            return false
          end
        end
      end
    rescue ARNet::PeerGone
      arnet_handle_lost_peer   # shows the message + sets the outcome
      return false
    ensure
      @arnet_in_menu = false
    end
  end

  # Called every frame from Battle::Scene#pbFrameUpdate (see below). Only active
  # while a selection menu is up; pumps the session so an incoming forfeit/leave
  # is noticed at once, then bails out of the menu via ARNet::PeerGone.
  def arnet_menu_poll
    return unless arnet_online?
    return if @arnet_peer_gone_seen
    # Pump the session EVERY frame — during selection menus AND during turn
    # animations. Incoming choices/switches are buffered into inboxes by the link
    # (see [008] _on_msg), so pumping here never consumes what a later await needs;
    # it only lets a peer disconnect/forfeit be noticed the instant the relay
    # reports it, rather than after the whole turn's animation has played out.
    @arnet.session.update rescue nil
    return unless @arnet.forfeited || @arnet.peer_left
    if @arnet_in_menu
      raise ARNet::PeerGone            # rescued in arnet_run_choice_menu
    else
      # Detected outside a menu (mid-animation / idle): abort the battle at once so
      # the "disconnected/forfeited" notice appears immediately. BattleAbortedException
      # (< Exception, so `rescue => e` can't swallow it) unwinds to the core
      # pbStartBattle rescue, which tears the scene down cleanly. [011] shows the
      # post-battle notice from @arnet_abort_reason.
      @arnet_peer_gone_seen = true
      @arnet_abort_reason   = @arnet.forfeited ? :peer_forfeit : :disconnect
      raise BattleAbortedException
    end
  end

  # "상대의 선택을 기다리는 중..." 배너 — 블록된 동안(arnet_exchange_choices /
  # 선출 프리컬렉트) 화면이 방금 고른 상태로 얼어붙지 않게 한다. 별도 창을 겹쳐
  # 띄우지 않고, 전투 중 "상대 XX의 YY!"가 나오는 기존 배틀 메시지 창
  # (@scene.@sprites["messageWindow"])에 그대로 출력한다. 이전 텍스트/표시상태는
  # 저장해 두었다가 close에서 복구(다음 실제 메시지가 덮어쓰지만 안전하게).
  def arnet_waiting_hud_open
    return if @arnet_waiting_hud
    spr = (@scene.instance_variable_get(:@sprites) rescue nil)
    mw  = spr && spr["messageWindow"]
    return unless mw   # 메시지 창을 못 찾으면 배너 생략(대기 자체는 정상 동작)
    cmd = spr["commandWindow"]
    @arnet_waiting_saved = [mw.text, mw.visible, mw.letterbyletter,
                            (spr["messageBox"] ? spr["messageBox"].visible : nil),
                            (cmd ? cmd.visible : nil)]
    # 방금 고른 커맨드/파이트 창을 내리고 배틀 메시지 창을 정식 경로로 띄운다.
    # (visible만 켜면 커맨드 창에 가려 텍스트가 안 보인다 — pbShowWindow가 커맨드
    #  창을 숨기고 messageBox+messageWindow를 함께 표시한다.)
    begin; @scene.pbShowWindow(Battle::Scene::MESSAGE_BOX); rescue Exception; end
    mw.letterbyletter = false
    mw.text           = _INTL("상대의 선택을 기다리는 중...")
    mw.visible        = true
    @arnet_waiting_hud = mw   # 공유 창이므로 dispose하지 않는다(마커 용도)
  end

  def arnet_waiting_hud_close
    return unless @arnet_waiting_hud
    mw = @arnet_waiting_hud
    @arnet_waiting_hud = nil
    return unless @arnet_waiting_saved
    txt, vis, lbl, box, cmd_vis = @arnet_waiting_saved
    @arnet_waiting_saved = nil
    begin
      spr = (@scene.instance_variable_get(:@sprites) rescue nil)
      mw.letterbyletter = lbl
      mw.text           = txt
      mw.visible        = vis
      spr["messageBox"].visible = box if spr && spr["messageBox"] && !box.nil?
      spr["commandWindow"].visible = cmd_vis if spr && spr["commandWindow"] && !cmd_vis.nil?
    rescue Exception
    end
  end

  # Mechanics aren't synced in v1 — defensively clear any registered toggle so the
  # local sim matches the peer (who likewise won't trigger one).
  def arnet_strip_mechanics(idx)
    pbUnregisterMegaEvolution(idx) if respond_to?(:pbUnregisterMegaEvolution)
    %i[pbUnregisterTerastallize pbUnregisterDynamax pbUnregisterZMove pbUnregisterUltraBurst].each do |m|
      send(m, idx) if respond_to?(m)
    end
  end

  # Disable Mega availability online (button hidden) — see scope note.
  alias_method :arnet_orig_pbCanMegaEvolve?, :pbCanMegaEvolve?
  def pbCanMegaEvolve?(idxBattler)
    return false if arnet_online?
    arnet_orig_pbCanMegaEvolve?(idxBattler)
  end

  #=============================================================================
  # Choice exchange
  #=============================================================================
  def arnet_exchange_choices
    mine = arnet_my_active_indices.map { |i| ARNet::Choices.choice_to_h(@choices[i], @battlers[i], i) }
    clk  = respond_to?(:arnet_clock_payload) ? arnet_clock_payload : nil
    @arnet.send_choices(@turnCount, mine, clk)
    # Don't leave the screen frozen on the just-made move selection: show a
    # "waiting for opponent" banner while blocked on the peer's choices.
    arnet_waiting_hud_open
    begin
      opp = @arnet.await_choices(@turnCount)
    ensure
      arnet_waiting_hud_close
    end
    if opp.nil?
      return false if arnet_handle_lost_peer
    end
    arnet_apply_peer_clock if respond_to?(:arnet_apply_peer_clock)   # peer bank piggybacked on choices
    (opp || []).each do |h|
      idx = h["idx"]
      next unless idx.is_a?(Integer) && (idx % 2) != @arnet_side   # only foe-side choices
      ARNet::Choices.apply_choice(self, idx, h)
    end
    true
  end

  #=============================================================================
  # Forced replacement sync (faint at end of round, U-turn/Baton Pass, Eject etc.)
  #=============================================================================
  # pbSwitchInBetween is the single chokepoint for a HUMAN-chosen replacement:
  #   - pbEORSwitch opponent path calls it directly;
  #   - the owner path funnels through pbGetReplacementPokemonIndex -> here;
  #   - switching moves/abilities/items call pbGetReplacementPokemonIndex -> here.
  # The random=true forced-switch path (Roar/Whirlwind/Red Card) does NOT pass
  # through here — it draws pbRandom directly, so it stays deterministic untouched.
  #
  # Determinism: both peers run the identical deterministic switch loop, so the
  # Nth pbSwitchInBetween call refers to the same logical replacement on both.
  # We key the exchange on a monotonic sequence counter (robust even when the
  # same battler index needs replacing twice within one EOR resolution). The
  # returned value is a party index into pbParty(idxBattler); both peers hold the
  # identical canonical party for that side, so the index is directly portable.
  #
  # HIDDEN SIMULTANEOUS REPLACEMENT (both actives faint same turn): the core
  # pbEORSwitch chooses AND sends out battler 0 before battler 1 is chosen, so the
  # side-1 player would pick after SEEING the opponent's replacement (info leak).
  # We pre-collect every side's choice first (each player picks with nothing sent
  # out yet), cache them, then let the core run — pbSwitchInBetween just returns
  # the cached value, so no replacement is revealed until both are locked in.
  # See arnet_precollect_replacements below.
  alias_method :arnet_orig_pbSwitchInBetween, :pbSwitchInBetween
  def pbSwitchInBetween(idxBattler, checkLaxOnly = false, canCancel = false)
    return arnet_orig_pbSwitchInBetween(idxBattler, checkLaxOnly, canCancel) unless arnet_online?
    # Pre-collected (hidden simultaneous) choice — apply without re-prompting or
    # re-exchanging, so the core's recall/send-out happens after BOTH are chosen.
    if @arnet_replace_cache && @arnet_replace_cache.key?(idxBattler)
      return @arnet_replace_cache.delete(idxBattler)
    end
    arnet_exchange_one_replacement(idxBattler, checkLaxOnly, canCancel)
  end

  # The actual per-battler choice exchange (local prompt + broadcast, or await the
  # peer's choice). Used both by the pre-collect pass and by lone mid-turn switches
  # (U-turn / Baton Pass / Eject), where there is only one chooser and no leak.
  # Prompt the LOCAL human to choose a replacement for THEIR OWN battler.
  # We only reach here on the owner path ((idxBattler % 2) == @arnet_side), so the
  # battler always belongs to the local player — even though the engine's
  # pbSwitchInBetween would AI-auto-pick it: pbOwnedByPlayer? is true only for
  # side0, and the guest's own team is side1 (opposes? => false ownership). So we
  # bypass the ownership check and open the party screen directly. The picked index
  # is broadcast, so how the local player chooses never affects the shared sim.
  def arnet_local_pick_replacement(idxBattler, checkLaxOnly = false, canCancel = false)
    pbPartyScreen(idxBattler, checkLaxOnly, canCancel)
  end

  def arnet_exchange_one_replacement(idxBattler, checkLaxOnly = false, canCancel = false)
    @arnet_switch_seq ||= 0
    seq = (@arnet_switch_seq += 1)
    if (idxBattler % 2) == @arnet_side
      # My battler: pick locally (ALWAYS prompt the party screen), then broadcast.
      idxParty = arnet_local_pick_replacement(idxBattler, checkLaxOnly, canCancel)
      @arnet.send_switch(seq, idxBattler, idxParty)
      idxParty
    else
      # Opponent's battler: take the replacement from the wire (no local AI/prompt).
      # Show the "waiting for opponent" banner while their (hidden) pick is pending.
      arnet_waiting_hud_open
      begin
        idxParty = @arnet.await_switch(seq)
      ensure
        arnet_waiting_hud_close
      end
      if idxParty.nil?
        arnet_handle_lost_peer
        return arnet_fallback_replacement(idxBattler)   # battle is aborting; stay crash-safe
      end
      idxParty
    end
  end

  # Pre-collect the replacement for every fainted battler that pbEORSwitch will
  # fill this call, BEFORE any is sent out. Mirrors the core's own guards/condition
  # (pbJudge + pbCanChooseNonActive?) so both peers prompt for exactly the same set
  # in the same order (keeping the switch-seq aligned). Each choice is made blind
  # (nothing on the field yet) and cached; the core then consumes the cache.
  alias_method :arnet_orig_pbEORSwitch, :pbEORSwitch
  def pbEORSwitch(favorDraws = false)
    return arnet_orig_pbEORSwitch(favorDraws) unless arnet_online?
    arnet_precollect_replacements(favorDraws)
    arnet_orig_pbEORSwitch(favorDraws)
  ensure
    @arnet_replace_cache = nil
  end

  def arnet_precollect_replacements(favorDraws)
    return if @decision > 0 && !favorDraws
    return if @decision == 5 && favorDraws
    pbJudge
    return if @decision > 0
    # pbEORSwitch가 이번에 교체할 배틀러 집합/순서(인덱스 순)를 코어 가드 그대로
    # 미러링해 정하고, 각각에 안정적인 switch-seq를 부여한다(양 피어 동일). 그런 뒤
    # ①내 배틀러 교체를 전부 먼저 고르고 즉시 전송 → ②그 다음 상대 것 대기, 로 나눈다.
    # 이렇게 하면 양쪽이 "동시에" 고른다(이전엔 인덱스 순으로 인터리브해서
    # 호스트가 고르는 동안 게스트가 기다리고→게스트가 고르는 동안 호스트가 기다리는
    # 직렬 선택이었다). 캐시를 코어가 소비하기 전까지 아무것도 공개되지 않으므로
    # 동시기절 숨김 선출 특성은 그대로 유지된다.
    @arnet_switch_seq ||= 0
    # 기절 교체는 코어의 pbGetReplacementPokemonIndex와 동일하게 checkLaxOnly=true
    # (pbCanSwitchIn? 관대 판정)로 프롬프트한다. 소유자 판정(pbOwnedByPlayer?)에
    # 의존하지 않는다 — side1(게스트 자기 팀)은 opposes?라 항상 false여서, 그에
    # 기대면 게스트는 파티 화면 없이 AI 자동선택되어 버린다(#1 버그).
    todo = []
    @battlers.each do |b|
      next if !b || !b.fainted?
      idxBattler = b.index
      next unless pbCanChooseNonActive?(idxBattler)
      next if !pbOwnedByPlayer?(idxBattler) && b.wild?   # no wild online; stay safe
      todo << [idxBattler, (@arnet_switch_seq += 1)]
    end
    return if todo.empty?
    @arnet_replace_cache = {}
    # ① 내 배틀러: 로컬 선택(항상 파티 화면) 후 곧바로 브로드캐스트, 대기 없음.
    todo.each do |idxBattler, seq|
      next unless (idxBattler % 2) == @arnet_side
      idxParty = arnet_local_pick_replacement(idxBattler, true, false)
      @arnet.send_switch(seq, idxBattler, idxParty)
      @arnet_replace_cache[idxBattler] = idxParty
    end
    # ② 상대 배틀러: 동시에 고르고 있던 상대의 선택을 수신.
    waiting = todo.any? { |idxBattler, _s| (idxBattler % 2) != @arnet_side }
    arnet_waiting_hud_open if waiting
    begin
      todo.each do |idxBattler, seq|
        next if (idxBattler % 2) == @arnet_side
        idxParty = @arnet.await_switch(seq)
        if idxParty.nil?
          arnet_handle_lost_peer
          idxParty = arnet_fallback_replacement(idxBattler)   # 배틀 중단 중; 크래시 방지
        end
        @arnet_replace_cache[idxBattler] = idxParty
      end
    ensure
      arnet_waiting_hud_close if waiting
    end
  end

  # First legal switch-in for idxBattler, or -1. Only used when the peer vanished
  # mid-replacement (the battle is already being aborted), to avoid party[-1].
  def arnet_fallback_replacement(idxBattler)
    eachInTeamFromBattlerIndex(idxBattler) do |_pkmn, i|
      return i if pbCanSwitchIn?(idxBattler, i)
    end
    -1
  end

  #=============================================================================
  # End-of-round checksum (desync canary)
  #=============================================================================
  alias_method :arnet_orig_pbEndOfRoundPhase, :pbEndOfRoundPhase
  def pbEndOfRoundPhase
    arnet_orig_pbEndOfRoundPhase
    return unless arnet_online?
    return if @decision != 0   # battle ending; no further sync needed
    arnet_checksum_exchange
  end

  def arnet_checksum_exchange
    myhash = arnet_state_checksum
    @arnet.send_checksum(@turnCount, myhash)
    peerhash = @arnet.await_checksum(@turnCount)
    if peerhash.nil?
      arnet_handle_lost_peer; return
    end
    arnet_abort!(:desync) if peerhash != myhash
  end

  # Deterministic 16-hex digest of the simulation-relevant state. Includes the
  # PRNG internal state, so ANY divergent RNG draw is caught at the turn boundary.
  def arnet_state_checksum
    parts = []
    @battlers.each_with_index do |b, i|
      if b.nil?
        parts << "#{i}:_"
        next
      end
      stages = b.respond_to?(:stages) ? b.stages.to_a.sort_by { |k, _| k.to_s } : []
      moves  = b.moves.map { |m| [m.id, m.pp] }
      parts << [i, b.species, (b.respond_to?(:form) ? b.form : 0), b.hp, b.status,
                b.statusCount, stages, b.ability_id, b.item_id, moves].inspect
    end
    field = [(@field.weather rescue nil), (@field.terrain rescue nil),
             (@field.weatherDuration rescue nil), (@field.terrainDuration rescue nil)]
    parts << field.inspect
    parts << "prng:#{@arnet_prng ? @arnet_prng.state : 0}"
    parts << "turn:#{@turnCount}"
    Digest::SHA256.hexdigest(parts.join("|"))[0, 16]
  end

  #=============================================================================
  # Forfeit / abort
  #=============================================================================
  # decision: 1 = side0(host) wins, 2 = side0 loses, 5 = draw/no-contest.
  def arnet_set_loser(side_that_lost)
    @decision = (side_that_lost == 0) ? 2 : 1
  end

  def arnet_do_forfeit
    @arnet.send_forfeit
    arnet_set_loser(@arnet_side)
  end

  # Returns true if the peer is gone/forfeited (caller should stop the round).
  def arnet_handle_lost_peer
    @arnet_peer_gone_seen = true   # stop the per-frame poll from re-firing during teardown
    if @arnet.forfeited
      @arnet_abort_reason = :peer_forfeit   # [011]이 종료 후 확실히 알린다
      pbDisplay(_INTL("상대가 기권했습니다!")) rescue nil
      arnet_set_loser(1 - @arnet_side)   # peer (other side) loses
      return true
    end
    pbDisplay(_INTL("상대와의 연결이 끊어졌습니다.")) rescue nil
    arnet_abort!(:disconnect)   # sets @arnet_abort_reason = :disconnect
    true
  end

  def arnet_abort!(reason)
    @arnet_abort_reason = reason
    @decision = 5   # draw / no-contest — ends the battle loop cleanly
  end
end

#===============================================================================
# Per-frame session poll during selection menus.
#
# The DBK selection menus (pbCommandMenuEx / pbFightMenu / …) run their own
# blocking input loop and never check an external abort flag. They DO call
# pbUpdate -> pbFrameUpdate every frame, so we piggy-back the session poll there:
# Battle#arnet_menu_poll pumps the socket and raises ARNet::PeerGone if the peer
# vanished, which unwinds cleanly to arnet_run_choice_menu's rescue.
#===============================================================================
if defined?(Battle::Scene)
  class Battle::Scene
    unless method_defined?(:arnet_orig_pbFrameUpdate)
      alias_method :arnet_orig_pbFrameUpdate, :pbFrameUpdate
    end
    def pbFrameUpdate(cw = nil)
      arnet_orig_pbFrameUpdate(cw)
      @battle.arnet_menu_poll if @battle.respond_to?(:arnet_menu_poll)
    end
  end
end
