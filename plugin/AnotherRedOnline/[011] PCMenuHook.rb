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

    code = pbMessageFreeText(
      _INTL("상대의 방 코드를 입력하세요.\n새 방을 만들려면 빈칸으로 두고 확인하세요."),
      "", false, 8)
    host_mode = (code.nil? || code.strip.empty?)
    code = code.to_s.strip.upcase

    # Host chooses the ruleset up front; the guest inherits it from the room.
    format = ARNet::FORMAT_FULL6
    if host_mode
      format = ARNet.choose_format_ui
      return if format.nil?   # cancelled at the format picker
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
    # 상태 텍스트는 콜백에서 갱신만 하고, 실제 표시는 폴링 루프에서 한다.
    # ★중요: 핸드셰이크 동안 s.update가 매 프레임 돌아야 하므로 여기서 블로킹
    #   pbMessage를 쓰면 안 된다(방 코드 표시 중 네트워크가 멈춰 시작이 지연됨).
    status = host_mode ? _INTL("방을 만드는 중...") : _INTL("방에 입장하는 중...")
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
    s.on_ready = proc { |_side, _seed|
      status = _INTL("상대와 연결됨. 팀을 교환하는 중...")
      s.submit_team(ARNet::Team.party_to_data($player.party))
    }
    # Peer team arrived — run the open-sheet selection UI from the polling loop
    # (NOT here: this callback runs inside s.update, and the UI blocks frames).
    s.on_peer_team = proc { |_peer_data| do_select = true }
    s.on_battle_ready = proc { |info| pending_info = info }
    s.on_peer_left = proc { |_r| aborted = true; fail_msg = _INTL("상대가 나갔습니다.") }

    started = false
    last_status = nil
    field_bgm = ($game_system.getPlayingBGM rescue nil)   # PC/Center music, restored on exit
    loop do
      s.update
      if s.phase == :idle && !started
        started = true
        host_mode ? s.create_room(format) : s.join_room(code)
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
          else
            sel_scene = ARNet::SelectionScene.new(s.format, mine, s.peer_party, n,
                                                  secs, $player.name, s.opponent_name)
            picks = sel_scene.run
            sel_scene.enter_wait   # keep decks/animations on screen until battle
          end
          s.submit_selection(picks)
        end
      end
      sel_scene.update_wait if sel_scene   # keep idle animations running while waiting
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
        elsif s.error_code == "version"
          _INTL("모드 버전이 상대와 다릅니다.\n최신 버전으로 업데이트한 뒤 다시 시도하세요.")
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
