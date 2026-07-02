#===============================================================================
# Another Red Online — format choice + graphical open-sheet selection (Phase A)
#
#   ARNet.choose_format_ui      -> host picks the ruleset (single3 / full6).
#   ARNet.run_selection_ui(...) -> two team decks (mine = blue, opponent =
#     orange) built from reusable PokemonIconSprite icons, with the battle type +
#     countdown clock in the middle column and a confirm button. Bring N of 6 on
#     a clock that auto-confirms at 0.
#
# Picks are indices into the player's FULL 6-mon party (submit_team order, which
# party_to_data compacts); the launcher's _apply_picks maps them back. The picks
# array preserves SELECTION ORDER (first chosen leads), so it is NOT sorted — the
# order is the send-out order and is shown as a badge on each chosen mon.
#
# NOTE (staged rollout): double4 is intentionally NOT offered yet — the lockstep
# is singles-only until Phase B. Add it to choose_format_ui once doubles land.
#===============================================================================
module ARNet
  module_function

  def format_label(format)
    case format
    when FORMAT_SINGLE3 then _INTL("싱글 배틀")
    when FORMAT_DOUBLE4 then _INTL("더블 배틀")
    else _INTL("풀 배틀")
    end
  end

  # Host-only: choose the battle format. Returns a FORMAT_* constant, or nil if
  # the player cancelled (caller should abort matchmaking).
  def choose_format_ui
    opts = [
      [_INTL("싱글 배틀"), FORMAT_SINGLE3],
      [_INTL("더블 배틀"), FORMAT_DOUBLE4],
      [_INTL("취소"),      nil]
    ]
    idx = pbMessage(_INTL("대전 규칙을 선택하세요."),
                    opts.map { |o| o[0] }, opts.length)
    return nil if idx < 0 || idx >= opts.length
    opts[idx][1]
  end

  # Open-sheet graphical selection. Returns Array<Integer> (party indices in the
  # SELECTION ORDER chosen) of length picks_for(format). Times out after `secs`
  # -> auto-fills the remaining slots from the top.
  def run_selection_ui(format, my_party, peer_party, secs = 90, my_name = nil, peer_name = nil)
    n = picks_for(format)
    return (0...my_party.length).to_a unless needs_selection?(format)
    return (0...my_party.length).to_a if my_party.length <= n
    scene = ARNet::SelectionScene.new(format, my_party, peer_party || [],
                                      n, secs, my_name, peer_name)
    begin
      scene.run
    ensure
      scene.dispose
    end
  end

  #=============================================================================
  # Two-deck team preview + selection scene.
  #=============================================================================
  class SelectionScene
    WHITE   = Color.new(248, 248, 248)
    SHADOW  = Color.new(64, 64, 64)
    BLUE    = Color.new(48, 120, 216)
    BLUE_HD = Color.new(24, 72, 168)
    ORANGE  = Color.new(232, 128, 40)
    ORANGE_HD = Color.new(184, 88, 16)
    CENTERC = Color.new(32, 32, 48)
    HILITE  = Color.new(120, 196, 255)    # selected mon's background (bright)
    SEL     = Color.new(248, 208, 72)     # selected border (yellow)
    CURSOR  = Color.new(248, 248, 248)    # cursor border (white)
    BADGE   = Color.new(216, 56, 56)      # send-out order badge (red)
    MALE    = Color.new(64, 152, 248)
    FEMALE  = Color.new(248, 96, 120)
    ITEMBOX = Color.new(248, 208, 72)

    def initialize(format, my_party, peer_party, n, secs, my_name, peer_name)
      @format = format
      @mine   = my_party
      @peer   = peer_party
      @n      = n
      @secs   = secs
      @myname   = my_name   || (($player.name rescue nil) || _INTL("나"))
      @peername = peer_name || _INTL("상대")
      @picks  = []           # party indices, in selection (send-out) order
      @cursor = 0            # 0..5 = my mons, 6 = confirm button
      @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
      @viewport.z = 99999
      # Two layers: @overlay (panels/clock + selected-cell highlight, BEHIND
      # icons) and @fg (per-mon Lv / gender / item / order badge / borders,
      # ABOVE icons). Icons sit at z=100.
      @overlay = Sprite.new(@viewport)
      @overlay.z = 0
      @overlay.bitmap = Bitmap.new(Graphics.width, Graphics.height)
      pbSetSystemFont(@overlay.bitmap)
      @fg = Sprite.new(@viewport)
      @fg.z = 200
      @fg.bitmap = Bitmap.new(Graphics.width, Graphics.height)
      pbSetSystemFont(@fg.bitmap)
      _compute_layout
      _build_icons
      @last_remain = nil
      @waiting = false
      # Selection-screen BGM. [011] owns saving/restoring the field (PC/Center)
      # BGM across the whole online flow, so we only START our track here — the
      # scene stays alive (idle animations running) until the battle launches.
      pbBGMPlay(ARNet::SELECT_BGM, 80) rescue nil   # 80% volume
      redraw
    end

    #--- geometry -------------------------------------------------------------
    def _compute_layout
      w = Graphics.width; h = Graphics.height
      @m   = 6
      @pw  = ((w - 3 * @m) * 42) / 100
      @cw  = w - 2 * @pw - 3 * @m
      @lx  = @m
      @cx  = @m + @pw + @m
      @rx  = w - @m - @pw
      @py  = @m
      @ph  = h - 2 * @m
      @hdr = 26                                 # panel header height
      @cellw = @pw / 2
      @cellh = (@ph - @hdr) / 3
    end

    # Cell centre (icon anchor) for slot i (0..5) inside a panel at panelX.
    def _cell_center(panelX, i)
      col = i % 2
      row = i / 2
      cx = panelX + (col * @cellw) + (@cellw / 2)
      cy = @py + @hdr + (row * @cellh) + (@cellh / 2) - 6
      [cx, cy]
    end

    # Cell rect (x, y, w, h) inset for slot i inside a panel at panelX.
    def _cell_rect(panelX, i)
      col = i % 2; row = i / 2
      [panelX + col * @cellw + 2, @py + @hdr + row * @cellh + 2,
       @cellw - 4, @cellh - 4]
    end

    #--- icons (reusable animated sprites) ------------------------------------
    def _build_icons
      @myicons  = []
      @peericons = []
      @mine.each_with_index do |pk, i|
        s = PokemonIconSprite.new(pk, @viewport)
        s.setOffset(PictureOrigin::CENTER)
        cx, cy = _cell_center(@lx, i)
        s.x = cx; s.y = cy; s.z = 100
        @myicons << s
      end
      @peer.each_with_index do |pk, i|
        s = PokemonIconSprite.new(pk, @viewport)
        s.setOffset(PictureOrigin::CENTER)
        cx, cy = _cell_center(@rx, i)
        s.x = cx; s.y = cy; s.z = 100
        @peericons << s
      end
    end

    #--- drawing --------------------------------------------------------------
    def _panel(x, base, header, title, align_title_left)
      b = @overlay.bitmap
      b.fill_rect(x - 2, @py - 2, @pw + 4, @ph + 4, Color.new(16, 16, 16))   # border
      b.fill_rect(x, @py, @pw, @ph, base)
      b.fill_rect(x, @py, @pw, @hdr, header)
      tx = align_title_left ? x + 8 : x + @pw - 8
      pbDrawTextPositions(b, [[title, tx, @py + 1, align_title_left ? :left : :right,
                               WHITE, SHADOW, :outline]])
    end

    # Bright background behind each selected mon (drawn on @overlay, so it sits
    # BEHIND the icon — only the background lights up, not the icon).
    def _selected_bg
      b = @overlay.bitmap
      @picks.each do |i|
        rx, ry, rw, rh = _cell_rect(@lx, i)
        b.fill_rect(rx, ry, rw, rh, HILITE)
      end
    end

    def _slot_overlays(x, party, mine)
      b = @fg.bitmap
      party.each_with_index do |pk, i|
        next unless pk
        cx, cy = _cell_center(x, i)
        # Level is normalised to 50 at battle time, so always show Lv.50.
        pbDrawTextPositions(b, [[_INTL("Lv.50"), cx - 20, cy + 18, :left,
                                 WHITE, SHADOW, :outline]])
        g = _gender_symbol(pk)
        if g
          pbDrawTextPositions(b, [[g[0], cx + 24, cy + 18, :left, g[1], SHADOW, :outline]])
        end
        # held-item marker (yellow box with a blue bar across the middle, like
        # the reference sheet's item icon).
        if (pk.item rescue nil)
          b.fill_rect(cx + 20, cy - 14, 12, 12, Color.new(16, 16, 16))
          b.fill_rect(cx + 21, cy - 13, 10, 10, ITEMBOX)
          b.fill_rect(cx + 21, cy - 9,  10,  2, Color.new(48, 104, 216))
        end
        if mine
          # selection border + send-out order badge (top-left) on my chosen mons
          ord = @picks.index(i)
          if ord
            _cell_border(x, i, SEL, 3)
            _order_badge(x, i, ord + 1)
          end
        end
      end
      # cursor box on my panel
      if mine && @cursor < 6
        _cell_border(x, @cursor, CURSOR, 2)
      end
    end

    # Small numbered badge at the cell's top-left corner (send-out order).
    def _order_badge(x, i, num)
      b = @fg.bitmap
      rx, ry, _rw, _rh = _cell_rect(x, i)
      sz = 20
      b.fill_rect(rx, ry, sz, sz, Color.new(16, 16, 16))
      b.fill_rect(rx + 1, ry + 1, sz - 2, sz - 2, BADGE)
      pbDrawTextPositions(b, [[num.to_s, rx + sz / 2, ry - 2, :center,
                               WHITE, SHADOW, :outline]])
    end

    def _cell_border(x, i, color, th)
      b = @fg.bitmap
      rx, ry, rw, rh = _cell_rect(x, i)
      b.fill_rect(rx, ry, rw, th, color)
      b.fill_rect(rx, ry + rh - th, rw, th, color)
      b.fill_rect(rx, ry, th, rh, color)
      b.fill_rect(rx + rw - th, ry, th, rh, color)
    end

    def _gender_symbol(pk)
      return ["♂", MALE]   if (pk.male?   rescue false)
      return ["♀", FEMALE] if (pk.female? rescue false)
      nil
    end

    def _center(remain)
      b = @overlay.bitmap
      cxm = @cx + @cw / 2
      # battle type
      pbDrawTextPositions(b, [[ARNet.format_label(@format), cxm, @py + 30, :center,
                               WHITE, SHADOW, :outline]])
      # clock
      mm = remain / 60; ss = remain % 60
      pbDrawTextPositions(b, [
        [_INTL("남은 시간"), cxm, @py + @ph / 2 - 40, :center, WHITE, SHADOW, :outline],
        [sprintf("%d:%02d", mm, ss), cxm, @py + @ph / 2 - 14, :center,
         (remain <= 10 ? Color.new(248, 96, 96) : WHITE), SHADOW, :outline]
      ])
      # selection count
      pbDrawTextPositions(b, [[_INTL("선출 {1}/{2}", @picks.length, @n), cxm,
                               @py + @ph / 2 + 24, :center, WHITE, SHADOW, :outline]])
      # confirm button (cursor index 6)
      by = @py + @ph - 54
      ready = (@picks.length == @n)
      bcol = (@cursor == 6) ? Color.new(96, 200, 96) : (ready ? Color.new(56, 152, 56) : Color.new(96, 96, 96))
      b.fill_rect(@cx + 6, by, @cw - 12, 40, Color.new(16, 16, 16))
      b.fill_rect(@cx + 8, by + 2, @cw - 16, 36, bcol)
      pbDrawTextPositions(b, [[_INTL("확정"), cxm, by + 8, :center, WHITE, SHADOW, :outline]])
    end

    def redraw(remain = @secs)
      b = @overlay.bitmap
      b.clear
      @fg.bitmap.clear
      b.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(8, 8, 24))
      b.fill_rect(@cx, @py, @cw, @ph, CENTERC)
      _panel(@lx, BLUE,   BLUE_HD,   @myname,   true)
      _panel(@rx, ORANGE, ORANGE_HD, @peername, false)
      _selected_bg                        # bright cell backgrounds (behind icons)
      _center(remain)
      _slot_overlays(@lx, @mine, true)    # on @fg (above icons)
      _slot_overlays(@rx, @peer, false)
    end

    #--- input loop -----------------------------------------------------------
    def run
      start = System.uptime
      @sel_deadline = start + @secs   # 대기 화면에서도 같은 마감까지 카운트다운
      result = nil
      loop do
        remain = (@secs - (System.uptime - start)).ceil
        remain = 0 if remain < 0
        if remain <= 0
          i = 0
          while @picks.length < @n && i < @mine.length
            @picks << i if !@picks.include?(i) && @mine[i]
            i += 1
          end
          result = @picks.dup          # keep selection (send-out) order
          break
        end
        if remain != @last_remain
          @last_remain = remain
          redraw(remain)
        end
        (@myicons + @peericons).each(&:update)
        Graphics.update
        Input.update
        if Input.trigger?(Input::UP)
          _move(:up)
        elsif Input.trigger?(Input::DOWN)
          _move(:down)
        elsif Input.trigger?(Input::LEFT)
          _move(:left)
        elsif Input.trigger?(Input::RIGHT)
          _move(:right)
        elsif Input.trigger?(Input::USE)
          if @cursor == 6
            if @picks.length == @n
              pbPlayDecisionSE
              result = @picks.dup
              break
            else
              pbPlayBuzzerSE
            end
          else
            _toggle(@cursor)
          end
        elsif Input.trigger?(Input::ACTION)
          if @picks.length == @n   # quick-confirm shortcut
            pbPlayDecisionSE
            result = @picks.dup
            break
          else
            pbPlayBuzzerSE
          end
        end
      end
      result
    end

    #--- wait phase (after confirm, until both ready + battle launches) --------
    # Keep the two decks on screen with the chosen team highlighted and the mons'
    # idle animations running, showing a "waiting for opponent" banner in the
    # centre. [011] calls update_wait every polling-loop frame.
    def waiting?
      @waiting
    end

    def enter_wait
      @waiting = true
      @cursor  = 6            # drop the cell cursor
      @wait_last_remain = nil
      _redraw_wait(_wait_remain)
    end

    # 상대의 선출 종료까지 남은 시간(내 선출 시작 기준의 공유 마감 = 근사). 선출을
    # 확정해도 이 카운트다운은 계속 흘러 상대가 얼마나 남았는지 보여준다.
    def _wait_remain
      return @secs unless @sel_deadline
      r = (@sel_deadline - System.uptime).ceil
      r < 0 ? 0 : r
    end

    def update_wait
      return unless @waiting
      r = _wait_remain
      if r != @wait_last_remain     # 1초 단위로만 다시 그린다
        @wait_last_remain = r
        _redraw_wait(r)
      end
      (@myicons + @peericons).each(&:update)   # keep idle animations going
    end

    def _redraw_wait(remain = @secs)
      b = @overlay.bitmap
      b.clear
      @fg.bitmap.clear
      b.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(8, 8, 24))
      b.fill_rect(@cx, @py, @cw, @ph, CENTERC)
      _panel(@lx, BLUE,   BLUE_HD,   @myname,   true)
      _panel(@rx, ORANGE, ORANGE_HD, @peername, false)
      _selected_bg
      cxm = @cx + @cw / 2
      pbDrawTextPositions(b, [[ARNet.format_label(@format), cxm, @py + 30, :center,
                               WHITE, SHADOW, :outline]])
      pbDrawTextPositions(b, [
        [_INTL("상대의 선택을"),  cxm, @py + @ph / 2 - 40, :center, WHITE, SHADOW, :outline],
        [_INTL("기다리는 중..."), cxm, @py + @ph / 2 - 12, :center, WHITE, SHADOW, :outline]
      ])
      # 남은 시간(상대 선출 종료까지) — 확정 후에도 계속 표시.
      mm = remain / 60; ss = remain % 60
      tcolor = (remain <= 10) ? Color.new(248, 96, 96) : WHITE
      pbDrawTextPositions(b, [
        [_INTL("남은 시간"),               cxm, @py + @ph / 2 + 18, :center, WHITE,  SHADOW, :outline],
        [sprintf("%d:%02d", mm, ss),       cxm, @py + @ph / 2 + 42, :center, tcolor, SHADOW, :outline]
      ])
      _slot_overlays(@lx, @mine, true)
      _slot_overlays(@rx, @peer, false)
    end

    def _toggle(i)
      return pbPlayBuzzerSE if i >= @mine.length || @mine[i].nil?   # empty slot
      if @picks.include?(i)
        @picks.delete(i)             # re-numbers the rest automatically
        pbPlayCancelSE
      elsif @picks.length < @n
        @picks << i                  # appended -> next in send-out order
        pbPlayDecisionSE
      else
        pbPlayBuzzerSE
        return
      end
      redraw(@last_remain || @secs)
    end

    def _move(dir)
      old = @cursor
      if @cursor == 6
        @cursor = 4 if dir == :up || dir == :left
      else
        col = @cursor % 2; row = @cursor / 2
        case dir
        when :up    then @cursor -= 2 if row > 0
        when :down
          if row < 2 then @cursor += 2
          else @cursor = 6 end
        when :left  then @cursor -= 1 if col == 1
        when :right
          if col == 0 then @cursor += 1 else @cursor = 6 end
        end
      end
      if @cursor != old
        pbPlayCursorSE
        redraw(@last_remain || @secs)
      end
    end

    def dispose
      (@myicons  || []).each { |s| s.dispose rescue nil }
      (@peericons || []).each { |s| s.dispose rescue nil }
      @overlay.bitmap.dispose rescue nil
      @overlay.dispose rescue nil
      @fg.bitmap.dispose rescue nil
      @fg.dispose rescue nil
      @viewport.dispose rescue nil
    end
  end
end
