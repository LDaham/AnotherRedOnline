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
  # In a double battle BOTH of my Pokémon SHARE one per-turn clock (time_turn):
  # the countdown starts when the command phase opens and does NOT reset between
  # the first and second battler. So we start/stop the clock (open the HUD, then
  # deduct the bank) around the WHOLE command phase, not around each battler menu.
  #
  # [014] aliases the ALREADY-wrapped [009] pbCommandPhase (loaded earlier), so the
  # chain is: [014] pbCommandPhase -> [009] pbCommandPhase -> core.
  alias_method :arnet_clock_orig_command_phase, :pbCommandPhase
  def pbCommandPhase
    return arnet_clock_orig_command_phase unless arnet_clock_enabled?
    @arnet_clock_turn_start = System.uptime
    @arnet_clock_cap = [@arnet_ruleset["time_turn"].to_f, arnet_clock[:bank][@arnet_side]].min
    arnet_clock_hud_open
    begin
      arnet_clock_orig_command_phase
    ensure
      used = System.uptime - @arnet_clock_turn_start
      used = @arnet_clock_cap if used > @arnet_clock_cap
      used = 0 if used < 0
      side = @arnet_side
      arnet_clock[:bank][side] -= used
      if arnet_clock[:bank][side] <= 0
        arnet_clock[:bank][side] = 0
        arnet_clock[:out][side]  = true
      end
      @arnet_clock_turn_start = nil
      arnet_clock_hud_close
    end
  end

  # Per-battler menu wrapper: the shared clock is already running (started by the
  # command-phase wrapper above), so here we ONLY catch the cap being hit and
  # auto-pick for THIS battler. When the shared time is already spent, the frame
  # poll keeps firing ClockExpired, so each still-unchosen battler is auto-picked
  # in turn as the loop advances.
  alias_method :arnet_clock_orig_run_choice_menu, :arnet_run_choice_menu
  def arnet_run_choice_menu(idx, allowBack = false)
    return arnet_clock_orig_run_choice_menu(idx, allowBack) unless arnet_clock_enabled?
    begin
      arnet_clock_orig_run_choice_menu(idx, allowBack)
    rescue ARNet::ClockExpired
      arnet_auto_choose(idx)
      true
    end
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
    # 배틀 씬은 모든 UI를 z=99999 뷰포트에 그리고, 그 안의 배경 스프라이트가 화면
    # 전체를 불투명하게 덮는다. 뷰포트 없는 스프라이트는 그 배경 뒤로 완전히
    # 가려지므로, 더 높은 z의 전용 뷰포트를 만들어 그 위에 HUD를 얹는다.
    @arnet_clock_vp = Viewport.new(0, 0, Graphics.width, Graphics.height)
    @arnet_clock_vp.z = 100000
    # 창(윈도우스킨 박스) 대신 순수 스프라이트+비트맵에 숫자만 그린다. 굵은 큰
    # 글씨에 검은 외곽선을 둘러 어떤 배경 위에서도 잘 보이게 한다.
    s = Sprite.new(@arnet_clock_vp)
    s.bitmap = Bitmap.new(112, 56)
    # pbSetSystemFont은 전역(private) 메서드라 respond_to? 가드에 걸리지 않게 직접
    # 호출한다(폰트 미설정 시 mkxp 기본 비트맵으로는 글자가 렌더링되지 않음).
    pbSetSystemFont(s.bitmap)
    s.bitmap.font.size = 22
    s.bitmap.font.bold = false
    # 게임 화면 우상단에 배치(남은 초 숫자만 표시).
    s.x = Graphics.width - s.bitmap.width - 2
    s.y = 2
    @arnet_clock_hud = s
    arnet_clock_hud_update
  end

  def arnet_clock_hud_update
    return unless @arnet_clock_hud && @arnet_clock_turn_start
    turn_left = (@arnet_clock_cap - (System.uptime - @arnet_clock_turn_start)).ceil
    turn_left = 0 if turn_left < 0
    bmp = @arnet_clock_hud.bitmap
    bmp.clear
    txt = turn_left.to_s
    tw  = bmp.text_size(txt).width
    x   = bmp.width - tw - 6   # 우측 정렬
    y   = 4
    fill = (turn_left <= 5) ? Color.new(255, 80, 80) : Color.new(255, 255, 255)  # 5초 이하 경고색
    # 1px 검은 외곽선(8방향) 후 밝은 글씨를 위에 얹어 대비 확보.
    bmp.font.color = Color.new(0, 0, 0)
    (-1..1).each do |dx|
      (-1..1).each do |dy|
        next if dx == 0 && dy == 0
        bmp.draw_text(x + dx, y + dy, tw + 12, 44, txt)
      end
    end
    bmp.font.color = fill
    bmp.draw_text(x, y, tw + 12, 44, txt)
  end

  def arnet_clock_hud_close
    if @arnet_clock_hud
      @arnet_clock_hud.bitmap.dispose rescue nil
      @arnet_clock_hud.dispose rescue nil
      @arnet_clock_hud = nil
    end
    if @arnet_clock_vp
      @arnet_clock_vp.dispose rescue nil
      @arnet_clock_vp = nil
    end
  end

  def arnet_fmt_clock(secs)
    s = secs.to_i
    s = 0 if s < 0
    sprintf("%d:%02d", s / 60, s % 60)
  end
end
