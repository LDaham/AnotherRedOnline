#===============================================================================
# Another Red Online — per-battle chess clock (Phase C)
#
# Each player owns a time bank (default 7 min) that ticks ONLY while their move
# selection menu is open (not during animations). Per turn the selection is
# capped (default 45 s); hitting the cap auto-picks a move. Running the bank to
# zero flags the player "timed out": at that turn's END they lose. If BOTH time
# out on the same turn, the winner is judged deterministically:
#   (1) more surviving Pokémon  ->  (2) higher summed HP ratio  ->  (3) higher
#   summed HP  ->  otherwise a draw.
#
# Determinism: each peer authoritatively ticks only ITS OWN bank (from real
# elapsed selection time) and piggybacks its remaining bank on the choices
# message ([008]/[009]); the peer trusts that value. The auto-picked move is just
# a normal transmitted choice, so the lockstep sim stays identical on both sides.
# The tiebreak reads only shared battle state, so both peers reach the same call.
#
# Config comes from the ruleset (see [001] default_ruleset / [010] wires it):
#   time_bank (total per player), time_turn (per-turn cap). time_select (team
#   preview) is enforced separately by the selection UI ([013]).
#===============================================================================
module ARNet
  # Raised out of the (blocking) selection menu when the per-turn / bank time is
  # spent, so we can auto-pick and move on. Caught in the clock's menu wrapper.
  class ClockExpired < StandardError; end
end

class Battle
  attr_accessor :arnet_ruleset

  def arnet_clock_enabled?
    arnet_online? && @arnet_ruleset && @arnet_ruleset["time_bank"]
  end

  # Lazy synced state. bank[side] = remaining seconds, out[side] = timed out.
  def arnet_clock
    @arnet_clock ||= begin
      b = @arnet_ruleset["time_bank"].to_f
      { bank: [b, b], out: [false, false] }
    end
  end

  #--- payload exchanged with the peer (piggybacked on the choices message) -----
  def arnet_clock_payload
    return nil unless arnet_clock_enabled?
    { "bank" => arnet_clock[:bank][@arnet_side], "out" => arnet_clock[:out][@arnet_side] }
  end

  def arnet_apply_peer_clock
    return unless arnet_clock_enabled?
    clk = @arnet.peer_clock
    return unless clk
    ps = 1 - @arnet_side
    arnet_clock[:bank][ps] = clk["bank"].to_f if clk["bank"]
    arnet_clock[:out][ps]  = !!clk["out"]
  end

  #--- selection timing + auto-pick --------------------------------------------
  # Wrap the per-battler command menu: start the turn clock, let the frame poll
  # (arnet_menu_poll below) raise ClockExpired at the cap, then deduct the time
  # actually spent from the bank.
  alias_method :arnet_clock_orig_run_choice_menu, :arnet_run_choice_menu
  def arnet_run_choice_menu(idx)
    return arnet_clock_orig_run_choice_menu(idx) unless arnet_clock_enabled?
    @arnet_clock_turn_start = System.uptime
    @arnet_clock_cap = [@arnet_ruleset["time_turn"].to_f, arnet_clock[:bank][@arnet_side]].min
    arnet_clock_hud_open
    ok = true
    timed_out = false
    begin
      ok = arnet_clock_orig_run_choice_menu(idx)
    rescue ARNet::ClockExpired
      timed_out = true
      arnet_auto_choose(idx)
      ok = true
    ensure
      used = System.uptime - @arnet_clock_turn_start
      used = @arnet_clock_cap if timed_out || used > @arnet_clock_cap
      side = @arnet_side
      arnet_clock[:bank][side] -= used
      if arnet_clock[:bank][side] <= 0
        arnet_clock[:bank][side] = 0
        arnet_clock[:out][side]  = true
      end
      @arnet_clock_turn_start = nil
      arnet_clock_hud_close
    end
    ok
  end

  # Called every frame during a selection menu (chained from [009]'s poll via the
  # scene's pbFrameUpdate). Ticks the HUD and fires ClockExpired at the cap.
  alias_method :arnet_clock_orig_menu_poll, :arnet_menu_poll
  def arnet_menu_poll
    arnet_clock_orig_menu_poll   # forfeit/leave check first (may raise PeerGone)
    return unless arnet_clock_enabled? && @arnet_in_menu && @arnet_clock_turn_start
    arnet_clock_hud_update
    raise ARNet::ClockExpired if (System.uptime - @arnet_clock_turn_start) >= @arnet_clock_cap
  end

  # Auto-pick on timeout: first usable move (top-left preference), else Struggle.
  def arnet_auto_choose(idx)
    battler = @battlers[idx]
    return true if !battler || battler.fainted?
    chosen = -1
    battler.moves.each_with_index do |m, i|
      next unless m && m.id
      if pbCanChooseMove?(idx, i, false)
        chosen = i
        break
      end
    end
    if chosen >= 0
      pbRegisterMove(idx, chosen, false)
      pbRegisterTarget(idx, -1)
    else
      pbAutoChooseMove(idx, false)   # no usable move -> Struggle
    end
    arnet_strip_mechanics(idx) if respond_to?(:arnet_strip_mechanics)
    true
  end

  #--- end-of-round timeout judgment -------------------------------------------
  # Runs after [009]'s pbEndOfRoundPhase (core + checksum). If either bank is
  # spent, decide the battle here (deterministic on both peers).
  alias_method :arnet_clock_orig_eor, :pbEndOfRoundPhase
  def pbEndOfRoundPhase
    arnet_clock_orig_eor
    arnet_clock_endcheck
  end

  def arnet_clock_endcheck
    return unless arnet_clock_enabled?
    return if @decision != 0
    o0 = arnet_clock[:out][0]
    o1 = arnet_clock[:out][1]
    return unless o0 || o1
    if o0 && o1
      @decision = arnet_clock_tiebreak
      pbDisplay(_INTL("양쪽 모두 제한 시간을 모두 사용했습니다!")) rescue nil
    elsif o0
      @decision = 2   # side0 (host) spent -> host loses
      pbDisplay(_INTL("제한 시간을 모두 사용했습니다!")) rescue nil
    else
      @decision = 1   # side1 (guest) spent -> host wins
      pbDisplay(_INTL("제한 시간을 모두 사용했습니다!")) rescue nil
    end
  end

  # decision: 1 = side0 wins, 2 = side0 loses, 5 = draw.
  def arnet_clock_tiebreak
    a = arnet_side_survivors(0)
    b = arnet_side_survivors(1)
    return 1 if a[:count] > b[:count]
    return 2 if a[:count] < b[:count]
    # HP ratio via integer cross-multiply (avoid float divergence):
    lhs = a[:hp] * b[:maxhp]
    rhs = b[:hp] * a[:maxhp]
    return 1 if lhs > rhs
    return 2 if lhs < rhs
    return 1 if a[:hp] > b[:hp]
    return 2 if a[:hp] < b[:hp]
    5   # draw
  end

  def arnet_side_survivors(side)
    count = 0; hp = 0; maxhp = 0
    (pbParty(side) || []).each do |pk|
      next unless pk
      hp    += pk.hp
      maxhp += pk.totalhp
      count += 1 if pk.hp > 0
    end
    { count: count, hp: hp, maxhp: maxhp }
  end

  #--- on-screen clock HUD (shown only while selecting; the bank only ticks then)
  def arnet_clock_hud_open
    return if @arnet_clock_hud
    w = Window_AdvancedTextPokemon.new("")
    w.letterbyletter = false
    w.z      = 99990
    w.width  = 80
    w.height = 64
    # 게임 화면 우상단에 배치(남은 초 숫자만 표시).
    w.x      = Graphics.width - w.width
    w.y      = 0
    @arnet_clock_hud = w
    arnet_clock_hud_update
  end

  def arnet_clock_hud_update
    return unless @arnet_clock_hud && @arnet_clock_turn_start
    turn_left = (@arnet_clock_cap - (System.uptime - @arnet_clock_turn_start)).ceil
    turn_left = 0 if turn_left < 0
    @arnet_clock_hud.text = turn_left.to_s   # 숫자만
  end

  def arnet_clock_hud_close
    return unless @arnet_clock_hud
    @arnet_clock_hud.dispose rescue nil
    @arnet_clock_hud = nil
  end

  def arnet_fmt_clock(secs)
    s = secs.to_i
    s = 0 if s < 0
    sprintf("%d:%02d", s / 60, s % 60)
  end
end
