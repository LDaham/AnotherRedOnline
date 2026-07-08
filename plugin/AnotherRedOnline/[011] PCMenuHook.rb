#===============================================================================
# Another Red Online — PC 메뉴 "온라인 대전" 진입점
#
# 기존 PC(박스) 메뉴에 항목 하나를 끼워넣는다(코어 스크립트 무수정 — MenuHandlers).
# 메뉴 순서: Someone's PC(10) / [player]'s PC(20) / 명예의 전당(40) /
#            ★온라인 대전(50)★ / Log off(100)
#
# 호스트는 빈칸 확인 → 방 코드 발급(화면 표시), 게스트는 그 코드를 입력해 입장.
# 페어링되면 ARNet.start_online_battle 로 락스텝 배틀 시작.
#===============================================================================
# 방 코드는 대문자만 쓴다. 코어 텍스트 입력창의 문자 삽입을 가로채, 우리 흐름에서
# $arnet_force_upcase 가 켜져 있을 때만 입력 문자를 실시간으로 대문자로 바꾼다
# (게스트가 소문자를 쳐도 화면에 바로 대문자로 보임). 다른 텍스트 입력(닉네임 등)은
# 플래그가 꺼져 있어 영향 없음.
class Window_TextEntry
  unless method_defined?(:arnet_orig_insert)
    alias_method :arnet_orig_insert, :insert
    def insert(ch)
      ch = ch.upcase if $arnet_force_upcase && ch.is_a?(String)
      arnet_orig_insert(ch)
    end
  end
end

module ARNet
  # 예외를 파일(arnet_err.txt, mkxp 쓰기 디렉터리=%APPDATA%\Pokemon Another Red\)에
  # 남기고 화면에도 표시. 인게임 디버깅용 — 필드에서 크래시로 게임이 죽는 것을 방지.
  def self.log_exception(where, e)
    begin
      bt = (e.respond_to?(:backtrace) && e.backtrace) ? e.backtrace.join("\n") : "(no backtrace)"
      File.open("arnet_err.txt", "ab") do |f|
        f.write("[#{where}] #{e.class}: #{e.message}\n#{bt}\n\n")
      end
    rescue Exception
    end
    begin
      pbMessage(_INTL("오류({1}): {2}\n{3}", where, e.class.to_s, e.message.to_s))
    rescue Exception
    end
  end

  # PC 메뉴에서 호출되는 인게임 온라인 대전 흐름.
  # 비차단 폴링 루프(프레임마다 Graphics/Input.update) — RGSS 단일 스레드 프리즈 방지.
  def self.online_battle_menu
    if !$player || $player.party.nil? || $player.party.empty?
      pbMessage(_INTL("대전에 내보낼 포켓몬이 없습니다."))
      return
    end

    # 진입 메뉴: 방 만들기 / 방 참가 / 랜덤 매칭.
    mode = pbMessage(_INTL("온라인 대전 방식을 선택하세요."),
                     [_INTL("방 만들기"), _INTL("방 참가"),
                      _INTL("랜덤 매칭"), _INTL("취소")], 4)
    return if mode < 0 || mode == 3

    host_mode = (mode == 0)   # true=방 코드 발급, false=참가 or 랜덤
    quick     = (mode == 2)   # 랜덤(퀵) 매칭
    code      = ""
    format    = ARNet::FORMAT_SINGLE3

    # 온라인 규칙 위반 팀(못 배우는 기술 등)은 매칭 큐 진입 전에 막는다.
    # 상대도 수신 시 재검증하므로 이건 안내용이고, 실제 차단은 [003] 수신 검증이다.
    bad = ARNet::Team.first_illegal($player.party)
    if bad
      pkmn, reason = bad
      detail = case reason
        when /\Aillegal move (\S+)/
          mv = GameData::Move.try_get($1.to_sym)
          _INTL("{1}은(는) {2}을(를) 배울 수 없습니다.", pkmn.name, (mv ? mv.name : $1))
        when /\Aillegal ability/ then _INTL("{1}의 특성이 올바르지 않습니다.", pkmn.name)
        when /\Aev /             then _INTL("{1}의 노력치가 규칙을 벗어났습니다.", pkmn.name)
        when /\Aduplicate species/ then _INTL("같은 종류의 포켓몬을 중복해서 넣을 수 없습니다. ({1})", pkmn.name)
        when /\Aduplicate item/    then _INTL("같은 도구는 하나만 지닐 수 있습니다. ({1})", pkmn.name)
        else _INTL("{1}의 구성이 규칙에 맞지 않습니다.", pkmn.name)
      end
      pbMessage(_INTL("이 팀으로는 온라인 대전에 참가할 수 없습니다.\n{1}", detail))
      return
    end

    if mode == 1
      # 방 참가: 상대 방 코드 입력(실시간 대문자 변환).
      begin
        $arnet_force_upcase = true
        code = pbMessageFreeText(_INTL("상대의 방 코드를 입력하세요."), "", false, 8)
      ensure
        $arnet_force_upcase = false
      end
      return if code.nil? || code.strip.empty?   # 취소 / 빈칸
      code = code.strip.upcase
    else
      # 방 만들기 또는 랜덤 매칭: 대전 포맷을 먼저 선택한다.
      # (랜덤은 같은 포맷 큐끼리만 매칭 — 서버 큐 키에 format 포함)
      format = ARNet.choose_format_ui
      return if format.nil?   # 포맷 선택에서 취소
    end
    s = nil
    pending_info = nil
    do_select = false          # set when the peer's team arrives (selection formats)
    aborted = false
    fail_msg = nil
    msgwin = nil
    sel_scene = nil            # graphical selection scene; kept alive through the
                               #   "waiting for opponent" phase until the battle starts
    field_bgm = nil            # PC/Center BGM to restore when the whole flow ends
    last_status = nil          # declared here so on_ready's closure updates THIS var
    # 상태 텍스트는 콜백에서 갱신만 하고, 실제 표시는 폴링 루프에서 한다.
    # ★중요: 핸드셰이크 동안 s.update가 매 프레임 돌아야 하므로 여기서 블로킹
    #   pbMessage를 쓰면 안 된다(방 코드 표시 중 네트워크가 멈춰 시작이 지연됨).
    status = if quick
               _INTL("매칭 상대를 찾는 중...")
             elsif host_mode
               _INTL("방을 만드는 중...")
             else
               _INTL("방에 입장하는 중...")
             end
   begin
    # 온라인 대전은 항상 1.0배(실시간)로 진행 — 플레이어별 Delta Speed Up 배속 설정을
    # 무시하고 System.uptime이 실시간을 반환하게 한다(배틀 애니 속도 + 체스클록/선출
    # 카운트다운 모두 실시간). 종료 시 ensure에서 반드시 해제. 자세한 건 [000b] 참고.
    $arnet_no_speedup = true
    msgwin = pbCreateMessageWindow
    msgwin.text = status
    s = ARNet::Session.new(ARNet::DEFAULT_HOST, ARNet::DEFAULT_PORT,
                           name: $player.name, gender: ($player.gender rescue 0),
                           trainer_type: ($player.trainer_type rescue nil))

    s.on_room_created = proc { |c|
      status = _INTL("방 코드: {1}\n상대가 코드를 입력해 입장하면 자동으로 시작됩니다.\n(취소 키로 중단)", c)
    }
    s.on_queued = proc { |_fmt|
      status = _INTL("매칭 상대를 찾는 중...\n(취소 키로 중단)")
    }
    s.on_ready = proc { |_side, _seed|
      status = _INTL("상대와 연결됨. 팀을 교환하는 중...")
      # The host's previous status (room code) grew the window to 3 lines. If the
      # peer's team arrives in the same s.update as this callback, the loop's
      # resize is skipped before do_select disposes the window, so this 1-line
      # message would render tiny at the top of the tall box. Resize + set it here
      # so it's shown correctly regardless of timing.
      if msgwin
        pbBottomLeftLines(msgwin, 2)
        msgwin.text = status
        last_status = status
      end
      s.submit_team(ARNet::Team.party_to_data($player.party))
    }
    # Peer team arrived — run the open-sheet selection UI from the polling loop
    # (NOT here: this callback runs inside s.update, and the UI blocks frames).
    s.on_peer_team = proc { |_peer_data| do_select = true }
    s.on_battle_ready = proc { |info| pending_info = info }
    s.on_peer_left = proc { |_r| aborted = true; fail_msg = _INTL("상대와의 연결이 끊겼습니다.") }

    started = false
    last_status = nil
    field_bgm = ($game_system.getPlayingBGM rescue nil)   # PC/Center music, restored on exit
    loop do
      s.update
      if s.phase == :idle && !started
        started = true
        if quick
          s.start_quick_match(format)
        elsif host_mode
          s.create_room(format)
        else
          s.join_room(code)
        end
      end
      if do_select
        do_select = false
        if ARNet.needs_selection?(s.format)
          # Take down the handshake window while the full-screen selection UI runs.
          begin; pbDisposeMessageWindow(msgwin); rescue Exception; end
          msgwin = nil
          secs  = ((s.ruleset && s.ruleset["time_select"]) || 90).to_i
          # picks index into the SAME order sent via submit_team (party_to_data
          # compacts), so select against the compacted party. Keep the scene ALIVE
          # after confirming: it switches to a "waiting for opponent" view (decks +
          # idle animations) and stays until the battle launches (below).
          n = ARNet.picks_for(s.format)
          mine = $player.party.compact
          if mine.length <= n
            picks = (0...mine.length).to_a
            status = _INTL("상대의 선출을 기다리는 중...")
            msgwin = pbCreateMessageWindow
            last_status = nil
            s.submit_selection(picks)
          else
            sel_scene = ARNet::SelectionScene.new(s.format, mine, s.peer_party, n,
                                                  secs, $player.name, s.opponent_name)
            # Blocking select → wait → (re-select) loop. run/wait_for_battle pump
            # the session every frame so a peer disconnect aborts BOTH sides at
            # once, and BACK during the wait un-confirms (timer keeps running).
            loop do
              picks = sel_scene.run(s)
              break if picks == :aborted                # peer dropped mid-select
              s.submit_selection(picks)
              w = sel_scene.wait_for_battle(s)
              break if w == :ready || w == :aborted     # battle starting / peer gone
              s.retract_selection                       # BACK → re-open selection
            end
            # sel_scene stays alive (decks on screen) until pending_info launches
            # the battle below, or the ensure block disposes it on abort.
          end
        end
      end
      if pending_info
        if sel_scene; sel_scene.dispose; sel_scene = nil; end
        begin; pbDisposeMessageWindow(msgwin); rescue Exception; end
        msgwin = nil
        result = ARNet.start_online_battle(s, pending_info)   # 블로킹: 배틀이 끝날 때까지
        # 배틀 도중 상대가 기권/이탈(연결 끊김)하면 그 사실을 확실히 알린다
        # (인배틀 pbDisplay가 종료 연출에 묻힐 수 있어 종료 후 한 번 더 안내).
        reason = result.is_a?(Array) ? result[1] : nil
        case reason
        when :peer_forfeit
          pbMessage(_INTL("상대가 기권했습니다!"))
        when :disconnect
          pbMessage(_INTL("상대와의 연결이 끊어져 대전이 중단되었습니다."))
        when :desync
          pbMessage(_INTL("동기화 오류로 대전이 중단되었습니다."))
        end
        break
      end
      if s.phase == :error
        # 게스트가 없는/잘못된 방 코드를 입력한 경우(server: no_room / self)는
        # 기술적 오류가 아니라 입력 실수이므로 알기 쉬운 문구로 안내한다.
        fail_msg = if !host_mode && (s.error_code == "no_room" || s.error_code == "self")
          _INTL("잘못된 코드입니다.")
        elsif s.error_code == "outdated"
          _INTL("사용 중인 버전이 오래되어 서버에 접속할 수 없습니다.\n최신 버전으로 업데이트한 뒤 다시 시도하세요.")
        elsif s.error_code == "build_blocked"
          _INTL("허용되지 않은 빌드입니다.\n변조되지 않은 정식 배포판으로 다시 시도하세요.")
        elsif s.error_code == "version"
          _INTL("모드 버전이 상대와 다릅니다.\n최신 버전으로 업데이트한 뒤 다시 시도하세요.")
        elsif s.error_code == "build"
          _INTL("모드 파일이 상대와 일치하지 않습니다.\n변조되지 않은 정식 배포판으로 다시 시도하세요.")
        elsif s.error_code == "bad_team"
          _INTL("내 팀이 대전 규칙에 맞지 않아 대전이 취소되었습니다.\n팀을 확인해 주세요.")
        elsif s.error_code == "peer_bad_team"
          _INTL("상대의 팀이 대전 규칙에 맞지 않아 대전이 취소되었습니다.")
        else
          _INTL("연결 오류: {1}", s.error.to_s)
        end
        break
      end
      break if aborted || s.phase == :closed
      if msgwin && status != last_status
        # Size the window to the actual line count. pbCreateMessageWindow fixes it
        # at 2 lines; the host's room-code status is 3 lines, which gets crammed
        # into the shorter box and renders undersized. Resize before setting text.
        lines = status.to_s.count("\n") + 1
        pbBottomLeftLines(msgwin, [lines, 2].max)
        msgwin.text = status
        last_status = status
      end
      msgwin.update if msgwin
      Graphics.update
      Input.update
      if Input.trigger?(Input::BACK)
        fail_msg = _INTL("취소했습니다.")
        break
      end
    end
    if fail_msg
      # 상태 창(방 코드/대기 안내)을 먼저 닫고 나서 안내 메시지를 띄운다. 그대로
      # pbMessage를 부르면 새 메시지 창이 기존 상태 창 위에 겹쳐 표시된다.
      begin; pbDisposeMessageWindow(msgwin); rescue Exception; end
      msgwin = nil
      pbMessage(fail_msg)
    end
   rescue SystemExit, Interrupt
    raise   # let engine-level shutdown/reset propagate (don't mask window close)
   rescue Exception => e
    ARNet.log_exception("online_battle_menu", e)
   ensure
    $arnet_no_speedup = false   # 온라인 종료 → 게임 기본 배속(Delta Speed Up) 복구
    begin; sel_scene.dispose if sel_scene; rescue Exception; end
    begin; pbDisposeMessageWindow(msgwin) if msgwin; rescue Exception; end
    # Restore the PC/Center BGM for the whole flow (selection played SELECT_BGM,
    # the battle played BATTLE_BGM; neither restores, so do it once here).
    ($game_system.bgm_play(field_bgm) rescue nil) if field_bgm
    begin; s.close if s; rescue Exception; end
   end
  end
end

MenuHandlers.add(:pc_menu, :online_battle, {
  "name"   => _INTL("온라인 대전"),
  "order"  => 50,
  "effect" => proc { |_menu|
    begin
      pbMessage("\\se[PC access]" + _INTL("온라인 대전 서버에 접속합니다..."))
      ARNet.online_battle_menu
    rescue SystemExit, Interrupt
      raise   # let engine-level shutdown/reset propagate
    rescue Exception => e
      ARNet.log_exception("pc_menu_effect", e)
    end
    next false   # 배틀 종료 후 PC 메뉴로 복귀
  }
})
